// SPDX-License-Identifier: GPL-3.0-or-later
//
// 自动更新在后台线程里做的三件事（docs/windows/architecture.md 6.3 节第 1～5 条）：检查、下载与核对、替换 exe。
// 每件事是一个阻塞函数，由 updates.rs 在新线程里调用，结果经通道交回主线程，再交给状态机
// （eveo_app_core::update::machine）。这里不碰界面，也不写 state.json。
//
// 检查（docs/update-manifest.md 第 4 节）：按顺序试清单的源（R2 在前、GitHub 在后），下载、验签、解析；
// 正式地址下序号比记下的更小时当作这个源失败。第一个成功的源给出发布列表；都失败时交回最后一个源的错误。
// 下载与核对，顺序与 macOS 相同，先验证再相信任何内容。每个文件按清单里的顺序试各个地址（R2 在前），
// 网络错误、状态码不对或 SHA-256 与清单不符时换下一个地址：
// 1. 下载 SHA256SUMS.txt 与 .sig（都很小），用内置（或测试）公钥验 ed25519 签名；
// 2. 下载 zip（显示进度、可取消），算 SHA-256，与签过名的校验和文件里的值比较；
// 3. 解出 exe，写进更新缓存目录，读它的版本资源与 PE 头，交给 Core 的 policy::validate 核对版本与架构；
// 4. 任何一步失败都删掉写了一半的文件，返回对应的 UpdateError。
// 替换：读回缓存里的 exe、核对 SHA-256、确认文件夹可写，再交给平台层的 replace_exe。
//
// 日志只写版本号、字节数与错误名，不写地址里的路径以外的东西，也不写本机路径（路径里有用户名）。

//! 自动更新的后台任务。

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use eveo_app_core::update::machine::{CheckOutcome, Progress};
use eveo_app_core::update::state::PreparedUpdate;
use eveo_core::update::archive::{self, EXE_NAME};
use eveo_core::update::checksums::{
    self, MAX_CHECKSUMS_BYTES, MAX_SIGNATURE_BYTES, expected_hash, sha256_hex, verify_signature,
};
use eveo_core::update::feed::{CHECKSUMS_NAME, SIGNATURE_NAME, UpdateFeed, archive_name};
use eveo_core::update::install::PendingSwap;
use eveo_core::update::manifest::{self, MAX_MANIFEST_BYTES, OWN_PLATFORM};
use eveo_core::update::models::ReleaseAsset;
use eveo_core::update::models::{InstallBlocker, ReleaseInfo, RunningApp, UpdateError};
use eveo_core::update::policy::{self, StagedExe};
use eveo_platform_win::update as platform;

/// 每一步网络操作的超时（秒）。下载大文件时是「两段数据之间」的超时，不是总时长。
const TIMEOUT_SECONDS: f64 = 30.0;
/// 取清单的超时（秒）：清单很小，一个源卡住时早点换下一个。
const MANIFEST_TIMEOUT_SECONDS: f64 = 15.0;
/// 压缩包与解出的 exe 的上限：现在的 exe 约 20 MB，留足余量，又不至于让异常的答复占满内存。
const MAX_ARCHIVE_BYTES: usize = 128 * 1024 * 1024;
/// 磁盘满的系统错误码（ERROR_DISK_FULL）与「空间不足」（ERROR_HANDLE_DISK_FULL）。
const DISK_FULL_CODES: [i32; 2] = [112, 39];

/// 请求头：User-Agent 只有应用名与版本；`Cache-Control: no-cache` 让 CDN 与代理不给旧的清单。
fn headers() -> Vec<(&'static str, String)> {
    vec![
        (
            "User-Agent",
            format!("EVE-O-Preview/{} (Windows)", env!("CARGO_PKG_VERSION")),
        ),
        ("Cache-Control", "no-cache".to_owned()),
    ]
}

/// 墙上时钟的秒数。
fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// 检查：按顺序试清单的源。成功时交回发布列表与清单的序号（测试地址下不交序号，不写进记录）。
///
/// public_key 为 None 时不验签（本机构建，只能提示）；min_sequence 是记下的最大序号，更小的清单不收。
pub(super) fn check(
    feed: &UpdateFeed,
    public_key: Option<[u8; 32]>,
    min_sequence: Option<u64>,
) -> (CheckOutcome, Option<u64>) {
    let mut last_error = UpdateError::Network("no manifest source".into());
    for url in &feed.manifest_urls {
        match fetch_manifest(feed, url, public_key.as_ref()) {
            // 序号更小：可能是 CDN 还缓存着旧清单，或旧清单被重放。换下一个源。
            Ok(found) if !feed.is_test_feed && min_sequence.is_some_and(|min| found.sequence < min) => {
                last_error = UpdateError::MalformedFeed("stale manifest".into());
            }
            Ok(found) => {
                let sequence = (!feed.is_test_feed).then_some(found.sequence);
                return (
                    CheckOutcome::List(found.release_list(OWN_PLATFORM), None),
                    sequence,
                );
            }
            Err(error) => last_error = error,
        }
    }
    (CheckOutcome::Failed(last_error), None)
}

/// 从一个源下载清单并验签、解析。下载与附件用同一个函数（只跟 https 的重定向，测试地址下只跟同源）。
fn fetch_manifest(
    feed: &UpdateFeed,
    url: &str,
    public_key: Option<&[u8; 32]>,
) -> Result<manifest::Manifest, UpdateError> {
    let data = platform::download(
        feed,
        url,
        &headers(),
        MAX_MANIFEST_BYTES,
        MANIFEST_TIMEOUT_SECONDS,
        &mut |_, _| true,
    )
    // 清单超过上限只可能是答复异常：按格式错误处理，换下一个源。
    .map_err(|error| match error {
        UpdateError::DownloadTooLarge => UpdateError::MalformedFeed("manifest too large".into()),
        other => other,
    })?;
    manifest::open(&data, public_key, feed, OWN_PLATFORM)
}

/// 下载与核对需要的东西。
pub(super) struct PrepareContext {
    /// 检查地址（附件地址的核对、重定向的规则）。
    pub feed: UpdateFeed,
    /// 验签用的公钥。
    pub public_key: [u8; 32],
    /// 正在运行的应用（核对新 exe 比它新）。
    pub running: RunningApp,
    /// 更新缓存目录。
    pub cache_dir: PathBuf,
    /// 正在运行的 exe（取它的机器类型）；不知道时按 x64 比较。
    pub own_exe: Option<PathBuf>,
    /// 用户点了取消。
    pub cancel: Arc<AtomicBool>,
}

/// 按清单里的顺序试一个附件的各个地址，交回第一个下载成功、且与清单里的 SHA-256 相符（有的话）的内容。
///
/// 取消立即返回，不再试别的地址；其余错误换下一个地址，都失败时交回最后一个错误。
/// on_progress 收到（已收到的字节数，总长），返回 false 表示取消；换地址时进度从 0 重新开始。
fn download_asset(
    context: &PrepareContext,
    asset: &ReleaseAsset,
    max: usize,
    on_progress: &mut dyn FnMut(u64, Option<u64>) -> bool,
) -> Result<Vec<u8>, UpdateError> {
    let mut last_error = UpdateError::AssetMissing(asset.name.clone());
    for url in asset.urls() {
        let result = platform::download(&context.feed, url, &headers(), max, TIMEOUT_SECONDS, on_progress);
        match result {
            Ok(data)
                if asset
                    .sha256
                    .as_ref()
                    .is_none_or(|expected| sha256_hex(&data) == *expected) =>
            {
                return Ok(data);
            }
            // 与清单不符：这个地址上的文件坏了或被换了，换下一个地址。
            Ok(_) => last_error = UpdateError::ChecksumMismatch,
            Err(UpdateError::Cancelled) => return Err(UpdateError::Cancelled),
            Err(error) => last_error = error,
        }
    }
    Err(last_error)
}

/// 下载一个小附件（校验和文件、签名），不显示进度。
fn download_small(
    context: &PrepareContext,
    release: &ReleaseInfo,
    name: &str,
    max: usize,
) -> Result<Vec<u8>, UpdateError> {
    let asset = release
        .asset(name)
        .ok_or_else(|| UpdateError::AssetMissing(name.to_owned()))?;
    download_asset(context, asset, max, &mut |_, _| {
        !context.cancel.load(Ordering::Relaxed)
    })
}

/// 下载、核对并解出新 exe。on_progress 收到下载 zip 的进度。
pub(super) fn prepare(
    context: &PrepareContext,
    release: &ReleaseInfo,
    on_progress: &mut dyn FnMut(Progress),
) -> Result<PreparedUpdate, UpdateError> {
    // 1. 校验和文件与签名：先验签，签名不对时连 zip 都不下载。
    let sums = download_small(context, release, CHECKSUMS_NAME, MAX_CHECKSUMS_BYTES)?;
    let signature = download_small(context, release, SIGNATURE_NAME, MAX_SIGNATURE_BYTES)?;
    verify_signature(&sums, &signature, &context.public_key)?;
    // 签名验过之后，校验和文件的内容才可信；按 zip 的文件名在里面找它的 SHA-256。
    let sums_text = String::from_utf8(sums).map_err(|_| UpdateError::ChecksumListInvalid)?;
    let zip_name = archive_name(&release.version);
    let expected = expected_hash(&zip_name, &sums_text)?;
    // 2. zip：边下载边报进度；完成后算 SHA-256（内存里的整份数据）。
    let asset = release
        .asset(&zip_name)
        .ok_or_else(|| UpdateError::AssetMissing(zip_name.clone()))?;
    let cancel = Arc::clone(&context.cancel);
    let zip = download_asset(context, asset, MAX_ARCHIVE_BYTES, &mut |received, total| {
        // 答复没带 Content-Length 时用发布列表里附件的大小，进度条照样能显示比例。
        let total = total.or(asset.size);
        on_progress(Progress { received, total });
        !cancel.load(Ordering::Relaxed)
    })?;
    // 下载的数据整份在内存里（上限 128 MB），算完哈希再解包：哈希不对时一个字节都不解。
    if sha256_hex(&zip) != expected {
        return Err(UpdateError::ChecksumMismatch);
    }
    // 3. 解出 exe，写进缓存目录，读版本资源，交给 Core 核对。
    let exe = archive::extract(&zip, EXE_NAME, MAX_ARCHIVE_BYTES)?;
    drop(zip);
    let path = staged_path(&context.cache_dir, &release.version);
    write_staged(&path, &exe)?;
    // 版本资源要从文件读（GetFileVersionInfoW 只收路径），所以先写盘再核对；核对失败时删掉。
    // 架构比较的是 PE 头的机器类型：x64 的应用不能换成 ARM64 的 exe，反之亦然。
    let version = platform::exe_version(&path);
    let staged = StagedExe {
        version: version.product_version,
        build_label: version.build_label,
        architecture_matches: archive::pe_machine(&exe) == own_machine(context.own_exe.as_deref()),
    };
    if let Err(error) = policy::validate(&staged, &release.version, &context.running) {
        let _ = fs::remove_file(&path);
        return Err(error);
    }
    // 记下新 exe 的 SHA-256：替换前再读回核对一次，防止下载之后缓存里的文件被换掉或损坏。
    Ok(PreparedUpdate {
        version: release.version.clone(),
        exe_path: path.to_string_lossy().into_owned(),
        sha256: sha256_hex(&exe),
    })
}

/// 缓存目录里新 exe 的文件名：`EVE-O Preview-<版本>.exe`。版本号来自 tag，只含语义化版本的字符。
fn staged_path(cache_dir: &Path, version: &str) -> PathBuf {
    // 防御：版本号里不该有路径分隔符，万一有就换掉，文件一定落在缓存目录里。
    let safe: String = version
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || ".-+".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    cache_dir.join(format!("EVE-O Preview-{safe}.exe"))
}

/// 写新 exe：先删掉同名的旧文件，写完刷到磁盘。磁盘满时报 InsufficientDiskSpace。
fn write_staged(path: &Path, bytes: &[u8]) -> Result<(), UpdateError> {
    let failed = |error: std::io::Error| {
        let _ = fs::remove_file(path);
        match error.raw_os_error() {
            Some(code) if DISK_FULL_CODES.contains(&code) => UpdateError::InsufficientDiskSpace,
            _ => UpdateError::ArchiveInvalid(format!("write failed ({:?})", error.kind())),
        }
    };
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(failed)?;
    }
    let _ = fs::remove_file(path);
    fs::write(path, bytes).map_err(failed)?;
    Ok(())
}

/// 正在运行的 exe 的机器类型：读它开头的 4 KiB（PE 头一定在里面）。读不到时按 x64（发布包只有 x64）。
fn own_machine(own_exe: Option<&Path>) -> Option<u16> {
    /// x64 的机器类型。
    const X64: u16 = 0x8664;
    let head = own_exe.and_then(|path| {
        use std::io::Read;
        let mut buffer = vec![0u8; 4096];
        let mut file = fs::File::open(path).ok()?;
        let read = file.read(&mut buffer).ok()?;
        buffer.truncate(read);
        Some(buffer)
    });
    head.as_deref().and_then(archive::pe_machine).or(Some(X64))
}

/// 路径是否在目录之下（按规范化后的路径比较）。state.json 里的路径删或读之前都要过这一关。
pub(super) fn is_inside(path: &Path, dir: &Path) -> bool {
    match (fs::canonicalize(path), fs::canonicalize(dir)) {
        // 规范化会解开 `..` 与符号链接，所以 `cache\..\other.exe` 这类路径过不了这一关。
        // 任何一边不存在都算不在里面：不存在的文件没有可删的，也没有可读的。
        (Ok(path), Ok(dir)) => path.starts_with(&dir) && path != dir,
        _ => false,
    }
}

/// 替换 exe：读回缓存里的新 exe、核对 SHA-256、确认文件夹可写，再换文件。成功时返回待确认的记录。
pub(super) fn install(
    prepared: &PreparedUpdate,
    cache_dir: &Path,
    own_exe: &Path,
    running_label: &str,
) -> Result<PendingSwap, UpdateError> {
    let path = Path::new(&prepared.exe_path);
    if !is_inside(path, cache_dir) {
        return Err(UpdateError::ArchiveInvalid("staged exe outside cache".into()));
    }
    // 从下载到安装之间可能隔了几小时（等空闲或等退出），这期间文件可能被杀毒软件隔离或被用户删掉。
    let bytes = fs::read(path).map_err(|_| UpdateError::ArchiveInvalid("staged exe missing".into()))?;
    if sha256_hex(&bytes) != prepared.sha256 {
        return Err(UpdateError::ChecksumMismatch);
    }
    // 下载之后用户可能把 exe 挪到了不可写的位置（或权限变了）：这时只能提示。
    if !platform::folder_writable(own_exe) {
        return Err(UpdateError::Blocked(InstallBlocker::LocationNotWritable));
    }
    // 替换本身（写 .new、改名 .old、改名就位）在平台层，失败时它已把文件还原，这里只转交错误码。
    platform::replace_exe(own_exe, &bytes).map_err(UpdateError::ReplaceFailed)?;
    Ok(PendingSwap {
        version: prepared.version.clone(),
        from_version: running_label.to_owned(),
        at: now(),
        launched_at: None,
    })
}

/// 解析公钥：64 位十六进制。给测试地址用的环境变量与内置的公钥都用它。
pub(super) fn parse_public_key(text: &str) -> Option<[u8; 32]> {
    checksums::public_key_from_hex(text.trim())
}
