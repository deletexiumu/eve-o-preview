// SPDX-License-Identifier: GPL-3.0-or-later
//
// 服务预设与接口设置的解析，对应 macOS 的 TranslationProviders.swift（设计文档 7.3 节）。
// - 预设的地址、模型名与是否要 Key 在 model::TranslationProviderId::preset 里（与「翻译」页共用），
//   这里补上接口种类：只有 Anthropic 用 Messages API，其余都是 OpenAI 兼容接口。
// - resolve：设置与预设合并，检查地址的格式与明文 HTTP 的限制。
// - is_local_host：http 地址只允许本机与局域网（7.11 节）。
// - credential_account：API Key 在凭据管理器里每个预设一项，名字与 macOS 钥匙串的账户名相同（7.7 节）。
//
// 与 macOS 的差别：macOS 用 URLComponents 拆地址，这里手写一个只认 `协议://主机[:端口][/路径]` 的拆法，
// 带用户名、查询串、片段、空白或控制字符的地址一律当成解不开。IP 地址用标准库按严格的写法解析；
// 标准库不认前导零（010.0.0.1），这类写法落到「带点的主机名」一支，不算本机，只会更保守。

//! 服务预设的接口种类与接口设置的解析。

use std::net::{Ipv4Addr, Ipv6Addr};

use super::{ApiKind, Endpoint, EndpointIssue};
use crate::model::{TranslationEndpointSettings, TranslationProviderId};
use crate::support::StringEnum;

/// 预设的接口种类。
pub fn api_kind(provider: TranslationProviderId) -> ApiKind {
    match provider {
        TranslationProviderId::Anthropic => ApiKind::Anthropic,
        _ => ApiKind::OpenAiCompatible,
    }
}

/// 合并设置与预设，得到可用的接口；不能用时给出原因。
///
/// 规则（7.3 节）：
/// 1. 地址取设置值，为空时取预设地址；模型同理。地址为空是 MissingBaseUrl，模型为空是 MissingModel。
/// 2. 地址应能解析，协议是 http 或 https，有主机，不带用户名、密码、查询串与片段，否则是 InvalidUrl。
/// 3. 协议是 http 而主机不是本机或局域网时是 InsecureRemoteHttp。
///
/// 接口种类与是否要 Key 随预设，改了地址也不变。
pub fn resolve(settings: &TranslationEndpointSettings) -> Result<Endpoint, EndpointIssue> {
    let preset = settings.provider.preset();
    let custom_base = trimmed_base_url(&settings.base_url);
    let base = if custom_base.is_empty() {
        trimmed_base_url(preset.base_url)
    } else {
        custom_base
    };
    let custom_model = settings.model.trim();
    let model = if custom_model.is_empty() {
        preset.model
    } else {
        custom_model
    };
    if base.is_empty() {
        return Err(EndpointIssue::MissingBaseUrl);
    }
    if model.is_empty() {
        return Err(EndpointIssue::MissingModel);
    }
    let parts = split_url(base).ok_or(EndpointIssue::InvalidUrl)?;
    if parts.scheme == "http" && !is_local_host(parts.host) {
        return Err(EndpointIssue::InsecureRemoteHttp);
    }
    Ok(Endpoint {
        provider: settings.provider,
        kind: api_kind(settings.provider),
        base_url: base.to_owned(),
        path: parts.path.to_owned(),
        model: model.to_owned(),
        requires_key: preset.requires_key,
    })
}

/// 去掉首尾空白与末尾的全部 `/`。
fn trimmed_base_url(text: &str) -> &str {
    text.trim().trim_end_matches('/')
}

/// 拆开的地址。
struct UrlParts<'a> {
    /// 小写的协议，只会是 http 或 https。
    scheme: String,
    /// 主机，IPv6 带着方括号。
    host: &'a str,
    /// 路径，以 `/` 开头或为空。
    path: &'a str,
}

/// 把 `协议://主机[:端口][/路径]` 拆开；不是这种写法，或协议不是 http、https 时为 None。
///
/// 含空白、控制字符、`?`、`#`、`\` 的地址不认；主机部分含 `@`（用户名与密码）时不认；端口只能是数字。
fn split_url(text: &str) -> Option<UrlParts<'_>> {
    if text
        .chars()
        .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '?' | '#' | '\\'))
    {
        return None;
    }
    let (scheme, rest) = text.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    // 主机部分到第一个 `/` 为止，后面都是路径。
    let (authority, path) = rest.find('/').map_or((rest, ""), |i| rest.split_at(i));
    if authority.contains('@') {
        return None;
    }
    let host = if authority.starts_with('[') {
        // IPv6：方括号里的是地址，后面只能是空或 `:端口`。
        let close = authority.find(']')?;
        port_is_valid(&authority[close + 1..]).then_some(&authority[..=close])?
    } else {
        match authority.rsplit_once(':') {
            Some((host, port)) => port.chars().all(|c| c.is_ascii_digit()).then_some(host)?,
            None => authority,
        }
    };
    if host.is_empty() || host == "[]" {
        return None;
    }
    Some(UrlParts { scheme, host, path })
}

/// 主机后面的部分是否为空或 `:数字`（`:` 后为空也算，与 URLComponents 相同）。
fn port_is_valid(text: &str) -> bool {
    text.is_empty()
        || text
            .strip_prefix(':')
            .is_some_and(|port| port.chars().all(|c| c.is_ascii_digit()))
}

/// http 地址的主机是否算本机或局域网（7.3 节第 4 条）。
///
/// 算：`localhost`；以 `.local` 结尾；不含 `.` 且不是 IP 的主机名；IPv4 的 127/8、10/8、172.16/12、192.168/16、
/// 169.254/16；IPv6 的 `::1`、fc00::/7、fe80::/10，以及映射到上述 IPv4 的 `::ffff:a.b.c.d`。
/// 全是数字或 `0x` 开头的十六进制「主机名」可能被系统当成 IP 解释（如 2130706433），一律不算。
/// 先把表意句点 `。`、全角句点 `．` 与半角句点 `｡` 换成 `.`：IDNA 把它们当成 `.`，`evil。com` 实际连的是
/// evil.com。不带点的主机名只认 ASCII 字母、数字与 `-`，其余字符（含 `%`）都不算。
pub fn is_local_host(host: &str) -> bool {
    let mut name = host.to_lowercase().replace(['。', '．', '｡'], ".");
    if name.len() >= 2 && name.starts_with('[') && name.ends_with(']') {
        name = name[1..name.len() - 1].to_owned();
    }
    // IPv6 的地址可带区域（fe80::1%en0），比较前去掉。只对 IPv6 去：别的主机名里的 `%` 不当成区域的分隔。
    if name.contains(':')
        && let Some(percent) = name.find('%')
    {
        name.truncate(percent);
    }
    if name.ends_with('.') {
        name.pop();
    }
    if name.is_empty() {
        return false;
    }
    if name.contains(':') {
        return name.parse::<Ipv6Addr>().is_ok_and(is_local_ipv6);
    }
    if let Ok(address) = name.parse::<Ipv4Addr>() {
        return is_local_ipv4(address);
    }
    if name == "localhost" || name.ends_with(".local") {
        return true;
    }
    if name.contains('.') {
        return false;
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return false;
    }
    // 不带点的主机名：排除可能被当成数字地址的写法。
    if name.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let is_hex = name
        .strip_prefix("0x")
        .is_some_and(|digits| digits.chars().all(|c| c.is_ascii_hexdigit()));
    !is_hex
}

/// IPv4 的回环、私有与链路本地网段。
fn is_local_ipv4(address: Ipv4Addr) -> bool {
    let [first, second, ..] = address.octets();
    match (first, second) {
        (127, _) | (10, _) | (192, 168) | (169, 254) => true,
        (172, second) => (16..=31).contains(&second),
        _ => false,
    }
}

/// IPv6 的回环、唯一本地（fc00::/7）与链路本地（fe80::/10）；映射的 IPv4 按 IPv4 的规则。
fn is_local_ipv6(address: Ipv6Addr) -> bool {
    let bytes = address.octets();
    if address == Ipv6Addr::LOCALHOST {
        return true;
    }
    if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) {
        return true;
    }
    address.to_ipv4_mapped().is_some_and(is_local_ipv4)
}

/// API Key 在凭据管理器里的名字（不含应用前缀），如 `apikey.deepseek`。
pub fn credential_account(provider: TranslationProviderId) -> String {
    format!("apikey.{}", provider.raw())
}
