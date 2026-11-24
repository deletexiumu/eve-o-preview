// SPDX-License-Identifier: GPL-3.0-or-later
//
// 自动更新在 Windows 上的部分（docs/windows/architecture.md 6.3 节）：下载、读 exe 的版本资源、替换与回滚 exe、
// 等旧进程退出、启动新进程。做什么、按什么顺序由 eveo_core::update（规则）与应用层的更新控制器决定，这里只做事。
//
// 下载：
// - 用 http::stream 分段读，回调里报进度、查取消；总长超过上限时停下（DownloadTooLarge）。
// - 自己跟重定向（最多 5 次）：WinHTTP 的自动重定向在 http.rs 里关掉了，这里按 UpdateFeed::redirect_target
//   决定跟不跟：正式地址下只跟到 https，测试地址下只跟同源。附件的真伪由签名保证，下载这一步只管不退回明文。
// - 只有 200 读正文；其余状态码返回 HttpStatus。
//
// 替换（规则与文件名见 eveo_core::update::install）：std::fs::rename 在 Windows 上是 MoveFileExW（同一卷内改名），
// 运行中的 exe 可以改名但不能覆盖或删除，所以先把自己改名为 `.old` 再放新文件。
// 所有失败都换成系统错误码交回，由调用方写日志；日志里不写路径（路径里有用户名）。

//! 自动更新的下载与 exe 替换。

use std::ffi::c_void;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use eveo_core::update::feed::UpdateFeed;
use eveo_core::update::install::{FAILED_SUFFIX, OLD_SUFFIX, STAGED_SUFFIX};
use eveo_core::update::models::UpdateError;
use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
use windows::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject};
use windows::core::HSTRING;

use crate::http::{self, HttpError, HttpRequest};

/// 最多跟几次重定向。GitHub 的附件只有一次（到存放文件的主机）。
pub const MAX_REDIRECTS: usize = 5;
/// 版本资源里放构建标签的字符串名（app.rc 里写入，见 eveo-app 的 build.rs）。
pub const BUILD_LABEL_KEY: &str = "BuildLabel";

/// 下载一个附件。url 要先经过 feed.accepts 的核对；headers 里放 User-Agent 等请求头。
/// on_progress 收到（已收到的字节数，答复头里的总长），返回 false 表示用户取消。
pub fn download(
    feed: &UpdateFeed,
    url: &str,
    headers: &[(&str, String)],
    max_bytes: usize,
    timeout_seconds: f64,
    on_progress: &mut dyn FnMut(u64, Option<u64>) -> bool,
) -> Result<Vec<u8>, UpdateError> {
    if !feed.accepts(url) {
        return Err(UpdateError::Network("asset url rejected".into()));
    }
    let mut current = url.to_owned();
    // 第 0 次是原地址，之后每次重定向加一；跟满 MAX_REDIRECTS 次还在重定向就放弃。
    for _ in 0..=MAX_REDIRECTS {
        let request = HttpRequest {
            method: "GET",
            url: &current,
            headers,
            body: &[],
            timeout_seconds,
            max_response_bytes: max_bytes,
            reads_body: |status| status == 200,
            // 测试地址可以是本机的 http；正式地址与它的重定向都只走 https（redirect_target 已保证）。
            allows_http: feed.is_test_feed,
        };
        let mut body = Vec::new();
        let mut total = None;
        let response = http::stream(&request, &mut |chunk| {
            body.extend_from_slice(chunk);
            on_progress(body.len() as u64, total)
        });
        let response = response.map_err(|error| match error {
            HttpError::TooLarge => UpdateError::DownloadTooLarge,
            HttpError::Cancelled => UpdateError::Cancelled,
            other => UpdateError::Network(other.describe()),
        })?;
        match response.status {
            200 => {
                // 总长只用来显示进度；读完之后再报一次，让进度条走满。
                total = response
                    .headers
                    .get("content-length")
                    .and_then(|v| v.trim().parse().ok());
                on_progress(body.len() as u64, total.or(Some(body.len() as u64)));
                return Ok(body);
            }
            301 | 302 | 303 | 307 | 308 => {
                let location = response.headers.get("location").map(String::as_str).unwrap_or("");
                current = feed
                    .redirect_target(&current, location)
                    .ok_or_else(|| UpdateError::Network("redirect rejected".into()))?;
            }
            status => return Err(UpdateError::HttpStatus(status)),
        }
    }
    Err(UpdateError::Network("too many redirects".into()))
}

/// exe 的版本资源里的产品版本与构建标签。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExeVersion {
    /// `ProductVersion`，如 `0.9.1`。
    pub product_version: Option<String>,
    /// `BuildLabel`，如 `0.9.1` 或 `0.9.1-ci.42`。
    pub build_label: Option<String>,
}

/// 读 exe 的版本资源；文件没有版本资源时两个字段都是 None。
pub fn exe_version(path: &Path) -> ExeVersion {
    let none = ExeVersion {
        product_version: None,
        build_label: None,
    };
    let name = HSTRING::from(path);
    // SAFETY: name 在调用期间有效（以 NUL 结尾的 UTF-16）；不需要句柄输出。
    let size = unsafe { GetFileVersionInfoSizeW(&name, None) };
    if size == 0 {
        return none;
    }
    let mut block = vec![0u8; size as usize];
    // SAFETY: 缓冲区有 size 个字节，调用期间有效，长度如实给出。
    if unsafe { GetFileVersionInfoW(&name, None, size, block.as_mut_ptr().cast::<c_void>()) }.is_err() {
        return none;
    }
    // 字符串表按「语言 + 代码页」分组；取版本资源自己声明的第一组，没有时用美国英语 + Unicode。
    let table = query(&block, "\\VarFileInfo\\Translation")
        .filter(|bytes| bytes.len() >= 4)
        .map_or_else(
            || "040904B0".to_owned(),
            |bytes| {
                let language = u16::from_le_bytes([bytes[0], bytes[1]]);
                let codepage = u16::from_le_bytes([bytes[2], bytes[3]]);
                format!("{language:04X}{codepage:04X}")
            },
        );
    let text = |key: &str| {
        let bytes = query(&block, &format!("\\StringFileInfo\\{table}\\{key}"))?;
        // 字符串值是 UTF-16，长度按字符数给出且含结尾的 NUL，去掉 NUL 与两侧空白。
        let units: Vec<u16> = bytes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_le_bytes(*pair))
            .collect();
        let value = String::from_utf16_lossy(&units);
        let value = value.trim_end_matches('\0').trim();
        (!value.is_empty()).then(|| value.to_owned())
    };
    ExeVersion {
        product_version: text("ProductVersion"),
        build_label: text(BUILD_LABEL_KEY),
    }
}

/// 在版本资源里按路径取一个值的字节；找不到时返回 None。
fn query(block: &[u8], sub_block: &str) -> Option<Vec<u8>> {
    let path = HSTRING::from(sub_block);
    let mut pointer: *mut c_void = std::ptr::null_mut();
    let mut length: u32 = 0;
    // SAFETY: block 是 GetFileVersionInfoW 填好的版本资源，调用期间有效；输出的指针指向 block 内部。
    let found = unsafe { VerQueryValueW(block.as_ptr().cast::<c_void>(), &path, &mut pointer, &mut length) };
    if !found.as_bool() || pointer.is_null() {
        return None;
    }
    // 字符串值的 length 是 UTF-16 的个数，其余值是字节数；以 `\StringFileInfo` 开头的就是字符串。
    let bytes = if sub_block.starts_with("\\StringFileInfo") {
        length as usize * 2
    } else {
        length as usize
    };
    // 防御：指针应在 block 之内，算出的长度不应越过 block 的末尾。
    let start = (pointer as usize).checked_sub(block.as_ptr() as usize)?;
    block.get(start..start.checked_add(bytes)?).map(<[u8]>::to_vec)
}

/// 在 exe 的文件名后面加后缀，如 `EVE-O Preview.exe` → `EVE-O Preview.exe.old`。
pub fn sibling(exe: &Path, suffix: &str) -> PathBuf {
    let mut name = exe.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// io::Error 换成系统错误码；没有错误码时是 0。
fn code(error: &io::Error) -> u32 {
    error.raw_os_error().map_or(0, |code| code as u32)
}

/// exe 所在的文件夹能否写入：试着建一个临时文件再删掉。Program Files 之类的位置不可写，只能提示新版本。
///
/// 只看权限位不够：受控文件夹访问（Windows 安全中心的防勒索功能）与网络盘的权限都要真的写一次才知道。
pub fn folder_writable(exe: &Path) -> bool {
    let probe = sibling(exe, ".write-test");
    // create_new：同名文件已存在时失败，不会覆盖别人的文件。
    let created = fs::OpenOptions::new().write(true).create_new(true).open(&probe);
    match created {
        Ok(file) => {
            drop(file);
            let _ = fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// 换上新 exe：写成 `.new`、自己改名为 `.old`、`.new` 改名为 exe。失败时尽量恢复原样，返回系统错误码。
///
/// 三个文件都在 exe 所在的文件夹里，改名不跨卷，每一步都是原子的；任何时刻文件夹里都有一个能运行的版本：
/// - 写 `.new` 失败（磁盘满、被杀毒软件锁住）：exe 没动；
/// - 第一次改名失败：exe 没动，删掉 `.new`；
/// - 第二次改名失败：exe 已经是 `.old`，改回来；改回也失败时，用户手动把 `.old` 改名就能恢复（极少见）。
///
/// 常见的错误码：5（拒绝访问，多半是杀毒软件或权限）、32（被占用）、112（磁盘满）。
pub fn replace_exe(exe: &Path, new_exe: &[u8]) -> Result<(), u32> {
    let staged = sibling(exe, STAGED_SUFFIX);
    let old = sibling(exe, OLD_SUFFIX);
    // 上一次留下的 `.new` 与 `.old`（例如确认之前就关机）先删掉；删不掉时后面的改名会报错。
    let _ = fs::remove_file(&staged);
    let _ = fs::remove_file(&old);
    write_synced(&staged, new_exe).map_err(|e| {
        let _ = fs::remove_file(&staged);
        code(&e)
    })?;
    if let Err(e) = fs::rename(exe, &old) {
        let _ = fs::remove_file(&staged);
        return Err(code(&e));
    }
    if let Err(e) = fs::rename(&staged, exe) {
        // 新文件放不上：把自己改回来，什么都没变。
        let _ = fs::rename(&old, exe);
        let _ = fs::remove_file(&staged);
        return Err(code(&e));
    }
    Ok(())
}

/// 写文件并刷到磁盘：改名之前内容必须已经落盘，断电时不会换上半个 exe。
fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = fs::OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// 回滚：自己（新版）改名为 `.failed`，`.old` 改回 exe。失败时尽量恢复原样，返回系统错误码。
///
/// 调用者是正在运行的新版，所以第一步是给运行中的自己改名，这是 Windows 允许的；
/// `.failed` 要等本进程退出后才能删除，由旧版下次启动时的 clean_up 删掉。
/// 没有 `.old`（被用户或杀毒软件删了）时返回 2（找不到文件），调用方照常运行新版。
pub fn roll_back(exe: &Path) -> Result<(), u32> {
    let old = sibling(exe, OLD_SUFFIX);
    let failed = sibling(exe, FAILED_SUFFIX);
    // 没有 `.old` 就没有可回的版本，什么都不动。
    if !old.exists() {
        return Err(2);
    }
    let _ = fs::remove_file(&failed);
    fs::rename(exe, &failed).map_err(|e| code(&e))?;
    if let Err(e) = fs::rename(&old, exe) {
        let _ = fs::rename(&failed, exe);
        return Err(code(&e));
    }
    Ok(())
}

/// 删掉遗留的 `.new`、`.old`、`.failed`。正在运行的副本删不掉，下次启动再删；返回删掉了几个。
pub fn clean_up(exe: &Path) -> usize {
    [STAGED_SUFFIX, OLD_SUFFIX, FAILED_SUFFIX]
        .iter()
        .filter(|suffix| fs::remove_file(sibling(exe, suffix)).is_ok())
        .count()
}

/// 启动 exe（带参数），返回新进程的编号。
///
/// 不等新进程，也不保留它的句柄（Child 丢弃时不会结束进程）。新进程从 exe 所在的位置启动，
/// 工作目录沿用本进程的；应用不依赖工作目录（配置在 %APPDATA%），所以没有影响。
pub fn launch(exe: &Path, args: &[String]) -> Result<u32, u32> {
    std::process::Command::new(exe)
        .args(args)
        .spawn()
        .map(|child| child.id())
        .map_err(|e| code(&e))
}

/// 等某个进程退出，最多等 timeout_ms 毫秒；进程已经不在（打不开）也算退出。返回是否已退出。
///
/// 进程编号会被系统复用：旧进程早已退出、编号又分给了别的进程时，这里会白等到超时（最多 15 秒），
/// 不会出错。只要 SYNCHRONIZE 权限，普通用户对自己的进程总能拿到。
pub fn wait_for_exit(pid: u32, timeout_ms: u32) -> bool {
    // SAFETY: 只要等待的权限；pid 不存在时返回错误。
    let Ok(handle) = (unsafe { OpenProcess(PROCESS_SYNCHRONIZE, false, pid) }) else {
        return true;
    };
    // SAFETY: handle 是刚打开的进程句柄。
    let exited = unsafe { WaitForSingleObject(handle, timeout_ms) } == WAIT_OBJECT_0;
    // SAFETY: handle 由 OpenProcess 返回，只关闭一次。
    let _ = unsafe { CloseHandle(handle) };
    exited
}
