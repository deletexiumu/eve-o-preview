// SPDX-License-Identifier: GPL-3.0-or-later
//
// 自动更新在后台线程里做的三件事（docs/windows/architecture.md 6.3 节第 1～5 条）：检查、下载与核对、替换 exe。
// 每件事是一个阻塞函数，由 updates.rs 在新线程里调用，结果经通道交回主线程，再交给状态机
// （eveo_app_core::update::machine）。这里不碰界面，也不写 state.json。
//
// 检查：取 Release 列表（带 If-None-Match），200 时解析，304 时说「没变」，403/429 时按限流的头算出可以再试的时刻。
// 下载与核对，顺序与 macOS 相同，先验证再相信任何内容：
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
use eveo_core::update::models::{InstallBlocker, ReleaseInfo, RunningApp, UpdateError};
use eveo_core::update::parser::{MAX_LIST_BYTES, parse_list, rate_limit};
use eveo_core::update::policy::{self, StagedExe};
use eveo_platform_win::http::{self, HttpError, HttpRequest};
use eveo_platform_win::update as platform;

/// 每一步网络操作的超时（秒）。下载大文件时是「两段数据之间」的超时，不是总时长。
const TIMEOUT_SECONDS: f64 = 30.0;
/// 压缩包与解出的 exe 的上限：现在的 exe 约 20 MB，留足余量，又不至于让异常的答复占满内存。
const MAX_ARCHIVE_BYTES: usize = 128 * 1024 * 1024;
/// 磁盘满的系统错误码（ERROR_DISK_FULL）与「空间不足」（ERROR_HANDLE_DISK_FULL）。
const DISK_FULL_CODES: [i32; 2] = [112, 39];

/// 请求头：User-Agent 只有应用名与版本；GitHub 的 API 版本头让答复格式固定。
fn headers(etag: Option<&str>) -> Vec<(&'static str, String)> {
    let mut headers = vec![
        (
            "User-Agent",
            format!("EVE-O-Preview/{} (Windows)", env!("CARGO_PKG_VERSION")),
        ),
        ("Accept", "application/vnd.github+json".to_owned()),
        ("X-GitHub-Api-Version", "2022-11-28".to_owned()),
    ];
    if let Some(etag) = etag {
        headers.push(("If-None-Match", etag.to_owned()));
    }
    headers
}

/// 墙上时钟的秒数。
fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// 检查：取 Release 列表并解析。
pub(super) fn check(feed: &UpdateFeed, etag: Option<&str>) -> CheckOutcome {
    let headers = headers(etag);
    let request = HttpRequest {
        method: "GET",
        url: &feed.list_url,
        headers: &headers,
        body: &[],
        timeout_seconds: TIMEOUT_SECONDS,
        max_response_bytes: MAX_LIST_BYTES,
        reads_body: |status| status == 200,
        // 测试地址可以是本机的 http（UpdateFeed::resolve 已核对过是回环地址）。
        allows_http: feed.is_test_feed,
    };
    let response = match http::send(&request) {
        Ok(response) => response,
        // 列表超过上限（正常不到 100 KB）只可能是答复异常：按格式错误处理，不当成网络问题反复重试。
        Err(HttpError::TooLarge) => {
            return CheckOutcome::Failed(UpdateError::MalformedFeed("release list too large".into()));
        }
        // 其余的错误（断网、超时、证书不对）都是网络错误：自动检查时不提示，下一次醒来再试。
        Err(error) => return CheckOutcome::Failed(UpdateError::Network(error.describe())),
    };
    match response.status {
        200 => match parse_list(&response.body, feed) {
            Ok(list) => CheckOutcome::List(list, response.headers.get("etag").cloned()),
            Err(error) => CheckOutcome::Failed(error),
        },
        // 304：列表与上次相同（ETag 相同），状态机用 state.json 里缓存的发布信息继续判断。
        304 => CheckOutcome::NotModified,
        status => {
            // 答复头的名字已经是小写；rate_limit 按小写的名字查。
            let header = |name: &str| response.headers.get(name).map(String::as_str);
            match rate_limit(status, header, now()) {
                Some(until) => CheckOutcome::RateLimited(Some(until)),
                None => CheckOutcome::Failed(UpdateError::HttpStatus(status)),
            }
        }
    }
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
    platform::download(
        &context.feed,
        &asset.download_url,
        &headers(None),
        max,
        TIMEOUT_SECONDS,
        &mut |_, _| !context.cancel.load(Ordering::Relaxed),
    )
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
    let zip = platform::download(
        &context.feed,
        &asset.download_url,
        &headers(None),
        MAX_ARCHIVE_BYTES,
        TIMEOUT_SECONDS,
        &mut |received, total| {
            // 答复没带 Content-Length 时用发布列表里附件的大小，进度条照样能显示比例。
            let total = total.or(asset.size);
            on_progress(Progress { received, total });
            !cancel.load(Ordering::Relaxed)
        },
    )?;
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
