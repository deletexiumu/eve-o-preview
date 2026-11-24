// SPDX-License-Identifier: GPL-3.0-or-later
//
// 最小的 HTTPS 客户端（WinHTTP 同步调用），给 ESI 人名核对、翻译与自动更新用。对应 macOS 用 .ephemeral 的 URLSession：
// - 默认只发 https；调用方明确允许时也发 http（翻译服务的本机地址，如 Ollama，是否本机由调用方先检查）。
// - 系统代理按「自动」取（WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY，Windows 8.1 起支持；不支持时退回默认代理）。
// - 不跟随重定向（3xx 原样交回，调用方按「请求有问题」处理）、不用 Cookie、不读写缓存（WINHTTP_FLAG_REFRESH）。
// - TLS 1.2 与 1.3；系统不支持 1.3 时只用 1.2。
// - 解析、连接、发送、接收各一个超时，都取调用方给的秒数。
// - 答复头的名字转成小写，与 macOS 的 lowercasedHeaders 相同；只有调用方要正文的状态码才读正文，
//   读到上限加 1 字节就停，超大的答复不进内存。
// 这里是阻塞调用，只在后台线程里用。请求体与答复都可能含消息正文（人名），这里不写日志。

//! WinHTTP 的同步 HTTPS 请求。

use std::collections::HashMap;
use std::ffi::c_void;

use windows::Win32::Foundation::ERROR_INSUFFICIENT_BUFFER;
use windows::Win32::Networking::WinHttp::{
    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_DISABLE_COOKIES,
    WINHTTP_DISABLE_REDIRECTS, WINHTTP_FLAG_REFRESH, WINHTTP_FLAG_SECURE,
    WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2, WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3, WINHTTP_OPTION_DISABLE_FEATURE,
    WINHTTP_OPTION_REDIRECT_POLICY, WINHTTP_OPTION_REDIRECT_POLICY_NEVER, WINHTTP_OPTION_SECURE_PROTOCOLS,
    WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_QUERY_STATUS_CODE, WinHttpCloseHandle,
    WinHttpConnect, WinHttpOpen, WinHttpOpenRequest, WinHttpQueryDataAvailable, WinHttpQueryHeaders,
    WinHttpReadData, WinHttpReceiveResponse, WinHttpSendRequest, WinHttpSetOption, WinHttpSetTimeouts,
};
use windows::core::{HSTRING, PCWSTR};

/// 一次请求。
#[derive(Debug, Clone)]
pub struct HttpRequest<'a> {
    /// 方法，如 `POST`。
    pub method: &'a str,
    /// 完整的地址，https；allows_http 为真时也可以是 http。
    pub url: &'a str,
    /// 请求头；User-Agent 交给 WinHttpOpen，其余作为附加请求头发出。
    pub headers: &'a [(&'a str, String)],
    /// 请求体；空表示没有。
    pub body: &'a [u8],
    /// 每一步的超时秒数。
    pub timeout_seconds: f64,
    /// 正文的上限，超过时报错。
    pub max_response_bytes: usize,
    /// 哪些状态码要读正文（例如 ESI 只读 200 的正文）。
    pub reads_body: fn(u16) -> bool,
    /// 是否允许明文 http。只有翻译服务的本机或局域网地址用它；ESI 总是 false。
    pub allows_http: bool,
}

/// 一次答复。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// HTTP 状态码。
    pub status: u16,
    /// 答复头，名字是小写；同名的头只留最后一个。
    pub headers: HashMap<String, String>,
    /// 正文；没读正文时为空。
    pub body: Vec<u8>,
}

/// 请求失败的原因：给日志的简短英文说明，不含地址以外的请求内容。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HttpError {
    /// 地址不是 https、或写法不对。
    InvalidUrl,
    /// 连不上、超时、TLS 失败等；关联值是简短说明。
    Network(String),
    /// 正文超过上限。
    TooLarge,
    /// 调用方在读正文时要求停下（stream 的回调返回 false）。
    Cancelled,
}

impl HttpError {
    /// 给日志与 PilotLookupFailure::Network 用的简短说明。
    pub fn describe(&self) -> String {
        match self {
            Self::InvalidUrl => "invalid url".to_owned(),
            Self::Network(reason) => reason.clone(),
            Self::TooLarge => "response too large".to_owned(),
            Self::Cancelled => "cancelled".to_owned(),
        }
    }
}

/// 地址拆出的三部分。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UrlParts {
    /// 主机名。
    pub host: String,
    /// 端口；没写时 443。
    pub port: u16,
    /// 路径加查询串，至少是 `/`。
    pub path: String,
    /// 是否走 TLS（https）。
    pub secure: bool,
}

/// 拆地址：接受 `https://主机[:端口][/路径]`，allows_http 为真时也接受 `http://`（默认端口 80）；
/// 不接受用户名密码。IPv6 字面量写在方括号里（`http://[::1]:11434/v1`），交给 WinHTTP 时去掉方括号。
/// 地址来自本模块的固定地址（ESI）或已经检查过的翻译接口，不处理百分号编码。
pub(crate) fn split_url(url: &str, allows_http: bool) -> Option<UrlParts> {
    let (rest, secure) = match url.strip_prefix("https://") {
        Some(rest) => (rest, true),
        None if allows_http => (url.strip_prefix("http://")?, false),
        None => return None,
    };
    let default_port = if secure { 443 } else { 80 };
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    // 带 @ 的写法（user:pass@host）一律不接受：这里从不发凭据。
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, port) = if let Some(bracketed) = authority.strip_prefix('[') {
        // IPv6：方括号里是地址，后面只能是空或 `:端口`。
        let (host, after) = bracketed.split_once(']')?;
        let port = match after {
            "" => default_port,
            _ => after.strip_prefix(':')?.parse().ok()?,
        };
        (host, port)
    } else {
        match authority.rsplit_once(':') {
            Some((host, port)) => (host, port.parse().ok()?),
            None => (authority, default_port),
        }
    };
    if host.is_empty() {
        return None;
    }
    Some(UrlParts {
        host: host.to_owned(),
        port,
        path: path.to_owned(),
        secure,
    })
}

/// 把原始答复头（`HTTP/1.1 200 OK\r\nName: value\r\n...`）解析成小写名字到值的表。第一行是状态行，跳过。
/// 值里可以有冒号（如日期 `Date: Mon, 01 Jan 2026 00:00:00 GMT`），所以只按第一个冒号切。
pub(crate) fn parse_headers(raw: &str) -> HashMap<String, String> {
    raw.split("\r\n")
        .skip(1)
        .filter_map(|line| line.split_once(':'))
        .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_owned()))
        .filter(|(name, _)| !name.is_empty())
        .collect()
}

/// WinHTTP 的句柄，离开作用域时关闭。
struct Handle(*mut c_void);

impl Handle {
    /// 接管一个句柄；空指针表示调用失败，返回 None。
    fn new(raw: *mut c_void) -> Option<Self> {
        (!raw.is_null()).then_some(Self(raw))
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: 句柄由 WinHttpOpen、WinHttpConnect 或 WinHttpOpenRequest 返回且不为空，只在这里关闭一次。
        // 子句柄（请求）先于父句柄（连接、会话）离开作用域，关闭顺序由变量的声明顺序保证。
        unsafe {
            let _ = WinHttpCloseHandle(self.0);
        }
    }
}

/// 发一次请求并等答复。阻塞，只在后台线程里调用。
///
/// 步骤：拆地址 → 打开会话（User-Agent、代理、超时、TLS 版本）→ 连接主机 → 打开请求（关重定向与 Cookie）
/// → 发请求头与请求体 → 等答复 → 取状态码与答复头 → 按需读正文。
/// 任何一步失败都返回 Network，说明里带上失败的步骤名，便于从日志里看出卡在哪一步。
/// 三个句柄按会话、连接、请求的顺序声明，离开函数时按相反顺序关闭。
pub fn send(request: &HttpRequest<'_>) -> Result<HttpResponse, HttpError> {
    let opened = open(request)?;
    // 不读正文的状态码（如 ESI 的 4xx、5xx）直接关句柄，正文留在连接里由 WinHTTP 丢弃。
    let body = if (request.reads_body)(opened.status) {
        read_body(&opened.request, request.max_response_bytes)?
    } else {
        Vec::new()
    };
    Ok(HttpResponse {
        status: opened.status,
        headers: opened.headers,
        body,
    })
}

/// 与 send 相同，但正文不攒在一起：每读到一段就交给 on_chunk，适合下载更新包时显示进度。
///
/// on_chunk 返回 false 时立即停下，返回 Cancelled（用户点了取消）。正文总长超过 max_response_bytes 时返回 TooLarge。
/// 取消的反应时间取决于下一段数据何时到达：网络很慢时最长要等一个超时（调用方给的秒数）。
/// 返回的 HttpResponse 里正文为空；不读正文的状态码不调用 on_chunk。
pub fn stream(
    request: &HttpRequest<'_>,
    on_chunk: &mut dyn FnMut(&[u8]) -> bool,
) -> Result<HttpResponse, HttpError> {
    let opened = open(request)?;
    if (request.reads_body)(opened.status) {
        read_chunks(&opened.request, request.max_response_bytes, on_chunk)?;
    }
    Ok(HttpResponse {
        status: opened.status,
        headers: opened.headers,
        body: Vec::new(),
    })
}

/// 已收到答复头的请求：三个句柄要活到正文读完。字段按声明顺序丢弃，请求先于连接、连接先于会话关闭。
struct Opened {
    /// 请求句柄。
    request: Handle,
    /// 连接句柄。
    _connection: Handle,
    /// 会话句柄。
    _session: Handle,
    /// HTTP 状态码。
    status: u16,
    /// 小写名字的答复头。
    headers: HashMap<String, String>,
}

/// 发请求并收答复头，正文留给调用方读。步骤见 send 的说明。
fn open(request: &HttpRequest<'_>) -> Result<Opened, HttpError> {
    let parts = split_url(request.url, request.allows_http).ok_or(HttpError::InvalidUrl)?;
    // WinHTTP 的 User-Agent 只能在打开会话时给；附加请求头里再写一遍会出现两个，所以单独取出来。
    let user_agent = request
        .headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("User-Agent"))
        .map_or_else(String::new, |(_, value)| value.clone());
    // 附加请求头：`名字: 值\r\n` 连起来，不含 User-Agent（已交给会话）。
    let extra: String = request
        .headers
        .iter()
        .filter(|(name, _)| !name.eq_ignore_ascii_case("User-Agent"))
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect();
    // WinHttpSendRequest 要 UTF-16；传切片时长度由切片给出，不需要结尾的 NUL。
    let extra_wide: Vec<u16> = extra.encode_utf16().collect();
    // 超时夹到 1 秒～10 分钟：0 在 WinHTTP 里表示「不限」，不能让一份坏参数变成永远等下去。
    let timeout_ms = (request.timeout_seconds * 1_000.0).clamp(1_000.0, 600_000.0) as i32;

    let session = open_session(&user_agent).ok_or_else(|| last_error("open"))?;
    // SAFETY: session 是刚打开的会话句柄；四个超时都是正数毫秒。
    unsafe { WinHttpSetTimeouts(session.0, timeout_ms, timeout_ms, timeout_ms, timeout_ms) }
        .map_err(|e| network("timeouts", &e))?;
    // TLS 版本设在会话上，之后在这个会话里开的连接都沿用。
    set_secure_protocols(&session);

    let host = HSTRING::from(parts.host.as_str());
    // SAFETY: session 有效；host 在调用期间有效（以 NUL 结尾的 UTF-16）。
    let connection = Handle::new(unsafe { WinHttpConnect(session.0, &host, parts.port, 0) })
        .ok_or_else(|| last_error("connect"))?;
    let method = HSTRING::from(request.method);
    let path = HSTRING::from(parts.path.as_str());
    // SAFETY: connection 有效；方法与路径在调用期间有效；版本、来源与可接受类型传空表示默认值。
    let handle = Handle::new(unsafe {
        WinHttpOpenRequest(
            connection.0,
            &method,
            &path,
            PCWSTR::null(),
            PCWSTR::null(),
            std::ptr::null(),
            // http 地址不加 SECURE（不走 TLS）；不读写缓存对两者都适用。
            if parts.secure {
                WINHTTP_FLAG_SECURE | WINHTTP_FLAG_REFRESH
            } else {
                WINHTTP_FLAG_REFRESH
            },
        )
    })
    .ok_or_else(|| last_error("open request"))?;
    // 两道保险都关掉重定向：策略设成「从不」，再关掉重定向功能本身。ESI 正常不会重定向，
    // 一旦重定向说明请求被代理或劫持改写，交回 3xx 由调用方当作「请求有问题」比跟过去更安全。
    set_u32_option(
        &handle,
        WINHTTP_OPTION_REDIRECT_POLICY,
        WINHTTP_OPTION_REDIRECT_POLICY_NEVER,
    );
    set_u32_option(
        &handle,
        WINHTTP_OPTION_DISABLE_FEATURE,
        WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS,
    );

    // 请求体一次发完：总长度与这次发出的长度相同，之后不再调用 WinHttpWriteData。
    let body_len =
        u32::try_from(request.body.len()).map_err(|_| HttpError::Network("body too large".into()))?;
    let body_ptr = (!request.body.is_empty()).then(|| request.body.as_ptr().cast::<c_void>());
    let headers = (!extra_wide.is_empty()).then_some(extra_wide.as_slice());
    // SAFETY: handle 有效；附加请求头与请求体在调用期间有效，长度如实给出；同步调用不用上下文值。
    unsafe { WinHttpSendRequest(handle.0, headers, body_ptr, body_len, body_len, 0) }
        .map_err(|e| network("send", &e))?;
    // SAFETY: handle 有效，请求已发出；保留参数必须为空。
    unsafe { WinHttpReceiveResponse(handle.0, std::ptr::null_mut()) }.map_err(|e| network("receive", &e))?;

    // 状态码取不到说明答复不完整，按网络错误处理；答复头取不到时只是少了限流信息，照常往下走。
    let status = query_status(&handle)?;
    let headers = parse_headers(&query_raw_headers(&handle));
    Ok(Opened {
        request: handle,
        _connection: connection,
        _session: session,
        status,
        headers,
    })
}

/// 打开会话：先用自动代理，不支持时（Windows 8 以前）用默认代理。
/// 自动代理会按系统设置读 PAC 脚本或 WPAD，与浏览器的行为一致；用户在系统里设了代理时也能连上 ESI。
fn open_session(user_agent: &str) -> Option<Handle> {
    let agent = HSTRING::from(user_agent);
    // SAFETY: agent 在调用期间有效；代理名与例外传空表示按访问类型取；同步模式（flags 为 0）。
    let automatic = unsafe {
        WinHttpOpen(
            &agent,
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            PCWSTR::null(),
            PCWSTR::null(),
            0,
        )
    };
    Handle::new(automatic).or_else(|| {
        // SAFETY: 同上，只换访问类型。
        Handle::new(unsafe {
            WinHttpOpen(
                &agent,
                WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                PCWSTR::null(),
                PCWSTR::null(),
                0,
            )
        })
    })
}

/// 只用 TLS 1.2 与 1.3；系统不认 1.3 时只用 1.2；都设不上时用系统默认（仍会协商出可用的版本）。
fn set_secure_protocols(session: &Handle) {
    let both = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
    if !set_u32_option(session, WINHTTP_OPTION_SECURE_PROTOCOLS, both) {
        set_u32_option(
            session,
            WINHTTP_OPTION_SECURE_PROTOCOLS,
            WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2,
        );
    }
}

/// 设一个 32 位整数的选项，返回是否成功。设不上的选项都不是必需的，失败时照常发请求。
fn set_u32_option(handle: &Handle, option: u32, value: u32) -> bool {
    let bytes = value.to_ne_bytes();
    // SAFETY: handle 有效；缓冲区是 4 字节的整数，调用期间有效，长度如实给出。
    unsafe { WinHttpSetOption(Some(handle.0.cast_const()), option, Some(&bytes)) }.is_ok()
}

/// 状态码。
fn query_status(handle: &Handle) -> Result<u16, HttpError> {
    let mut status: u32 = 0;
    let mut length = std::mem::size_of::<u32>() as u32;
    // SAFETY: handle 有效且已收到答复；缓冲区是一个 u32，长度如实给出；不按名字查、不用序号。
    unsafe {
        WinHttpQueryHeaders(
            handle.0,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            PCWSTR::null(),
            Some((&raw mut status).cast::<c_void>()),
            &mut length,
            std::ptr::null_mut(),
        )
    }
    .map_err(|e| network("status", &e))?;
    u16::try_from(status).map_err(|_| HttpError::Network("bad status".into()))
}

/// 原始答复头；取不到时为空（调用方按「没有这些头」处理）。
/// 先问需要多大的缓冲区，再按这个大小取一次；两次之间答复头不会变。
fn query_raw_headers(handle: &Handle) -> String {
    let mut length: u32 = 0;
    // SAFETY: 先不给缓冲区，只问需要的字节数；预期以 ERROR_INSUFFICIENT_BUFFER 失败并写回 length。
    let probe = unsafe {
        WinHttpQueryHeaders(
            handle.0,
            WINHTTP_QUERY_RAW_HEADERS_CRLF,
            PCWSTR::null(),
            None,
            &mut length,
            std::ptr::null_mut(),
        )
    };
    match probe {
        Err(e) if e.code() == ERROR_INSUFFICIENT_BUFFER.to_hresult() && length > 0 => {}
        _ => return String::new(),
    }
    // length 是字节数，缓冲区按 UTF-16 的个数分配，向上取整。
    let mut buffer = vec![0u16; (length as usize).div_ceil(2)];
    // SAFETY: 缓冲区按上一步给出的字节数分配，调用期间有效；length 是缓冲区的字节数。
    let filled = unsafe {
        WinHttpQueryHeaders(
            handle.0,
            WINHTTP_QUERY_RAW_HEADERS_CRLF,
            PCWSTR::null(),
            Some(buffer.as_mut_ptr().cast::<c_void>()),
            &mut length,
            std::ptr::null_mut(),
        )
    };
    if filled.is_err() {
        return String::new();
    }
    // 成功时 length 是不含结尾 NUL 的字节数。
    buffer.truncate(length as usize / 2);
    String::from_utf16_lossy(&buffer)
}

/// 读完整的正文，超过上限时报 TooLarge。
fn read_body(handle: &Handle, limit: usize) -> Result<Vec<u8>, HttpError> {
    let mut body = Vec::new();
    // 攒在一起的回调从不要求停下，所以这里不会出现 Cancelled。
    read_chunks(handle, limit, &mut |chunk| {
        body.extend_from_slice(chunk);
        true
    })?;
    Ok(body)
}

/// 一段一段读正文交给 on_chunk；总长超过上限时报 TooLarge，on_chunk 返回 false 时报 Cancelled。
/// 每轮先问「现在有多少字节可读」，再按这个数读（最多 64 KiB）；可读为 0 表示正文读完。
/// 超过上限的那一段不交给 on_chunk，不会把一个异常大的答复整个读进内存。
fn read_chunks(
    handle: &Handle,
    limit: usize,
    on_chunk: &mut dyn FnMut(&[u8]) -> bool,
) -> Result<(), HttpError> {
    // 每段的上限：可读的字节数可能很大（整个缓冲区），分段读能让进度与取消更及时。
    const CHUNK: u32 = 64 * 1024;
    let mut buffer = vec![0u8; CHUNK as usize];
    let mut total = 0usize;
    loop {
        let mut available: u32 = 0;
        // SAFETY: handle 有效且已收到答复；available 是一个 u32 的输出参数。
        unsafe { WinHttpQueryDataAvailable(handle.0, &mut available) }.map_err(|e| network("read", &e))?;
        if available == 0 {
            return Ok(());
        }
        let wanted = available.min(CHUNK);
        let mut read: u32 = 0;
        // SAFETY: 缓冲区有 CHUNK 个字节，wanted 不超过它，调用期间有效；read 是输出参数。
        unsafe { WinHttpReadData(handle.0, buffer.as_mut_ptr().cast::<c_void>(), wanted, &mut read) }
            .map_err(|e| network("read", &e))?;
        if read == 0 {
            return Ok(());
        }
        total += read as usize;
        if total > limit {
            return Err(HttpError::TooLarge);
        }
        // 实际读到的可能少于要的字节数，只交出读到的部分。
        if !on_chunk(&buffer[..read as usize]) {
            return Err(HttpError::Cancelled);
        }
    }
}

/// 刚失败的调用的错误（空句柄的情形）。
fn last_error(step: &str) -> HttpError {
    network(step, &windows::core::Error::from_thread())
}

/// 把 WinHTTP 的错误换成简短说明：常见的几种写成文字，其余写错误码。
fn network(step: &str, error: &windows::core::Error) -> HttpError {
    // WinHTTP 的错误码在 12000～12999，HRESULT 的低 16 位就是它。
    let code = (error.code().0 as u32) & 0xFFFF;
    let reason = match code {
        12002 => "timeout".to_owned(),
        12007 => "name not resolved".to_owned(),
        12029 => "cannot connect".to_owned(),
        12030 => "connection aborted".to_owned(),
        12175 => "secure channel failure".to_owned(),
        _ => format!("winhttp error {code}"),
    };
    HttpError::Network(format!("{step}: {reason}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// https 地址拆成主机、端口与路径；不是 https、带凭据或没有主机时不接受。
    #[test]
    fn splits_urls() {
        let esi = split_url("https://esi.evetech.net/universe/ids", false).unwrap();
        assert_eq!(
            esi,
            UrlParts {
                host: "esi.evetech.net".into(),
                port: 443,
                path: "/universe/ids".into(),
                secure: true,
            }
        );
        let custom = split_url("https://example.test:8443", false).unwrap();
        assert_eq!((custom.port, custom.path.as_str()), (8443, "/"));
        let query = split_url("https://example.test/a?b=1", false).unwrap();
        assert_eq!(query.path, "/a?b=1");
        // 不允许 http 时（ESI）拒绝明文地址。
        assert_eq!(split_url("http://esi.evetech.net/", false), None);
        assert_eq!(split_url("https://user:pass@example.test/", false), None);
        assert_eq!(split_url("https:///path", false), None);
        assert_eq!(split_url("https://example.test:port/", false), None);
    }

    /// 允许 http 时（翻译服务的本机地址）：默认端口 80；IPv6 字面量去掉方括号；方括号后面只能跟端口。
    #[test]
    fn splits_local_http_urls() {
        let ollama = split_url("http://127.0.0.1:11434/v1/chat/completions", true).unwrap();
        assert_eq!(
            (ollama.host.as_str(), ollama.port, ollama.secure),
            ("127.0.0.1", 11434, false)
        );
        assert_eq!(ollama.path, "/v1/chat/completions");
        assert_eq!(split_url("http://nas/v1", true).unwrap().port, 80);
        let v6 = split_url("http://[::1]:11434/v1", true).unwrap();
        assert_eq!((v6.host.as_str(), v6.port), ("::1", 11434));
        assert_eq!(split_url("https://[fe80::1]/v1", true).unwrap().port, 443);
        assert_eq!(split_url("http://[::1]x/v1", true), None);
        assert_eq!(split_url("ftp://example.test/", true), None);
    }

    /// 答复头：跳过状态行，名字转小写，值去掉两端空白，没有冒号的行忽略。
    #[test]
    fn parses_headers() {
        let raw = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\nX-Esi-Error-Limit-Remain:  98 \r\nbroken\r\n\r\n";
        let headers = parse_headers(raw);
        assert_eq!(headers.get("retry-after").map(String::as_str), Some("30"));
        assert_eq!(
            headers.get("x-esi-error-limit-remain").map(String::as_str),
            Some("98")
        );
        assert_eq!(headers.len(), 2);
    }
}
