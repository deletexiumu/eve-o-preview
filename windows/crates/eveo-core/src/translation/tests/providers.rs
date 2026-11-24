// SPDX-License-Identifier: GPL-3.0-or-later
//
// 服务预设与接口设置的解析：除 custom 外每个预设都能解析；空串回到预设值；带用户名、查询串的地址是 InvalidUrl；
// 公网的 http 是 InsecureRemoteHttp；is_local_host 对每一类各一例，另有反例与表意句点。

use crate::model::{TranslationEndpointSettings, TranslationProviderId};
use crate::support::StringEnum;
use crate::translation::providers::{api_kind, credential_account, is_local_host, resolve};
use crate::translation::{ApiKind, EndpointIssue};

/// 用预设、地址与模型名建设置。
fn settings(provider: TranslationProviderId, base_url: &str, model: &str) -> TranslationEndpointSettings {
    TranslationEndpointSettings {
        provider,
        base_url: base_url.to_owned(),
        model: model.to_owned(),
    }
}

/// 除 custom 外，每个预设用默认设置都能解析；custom 缺地址。
#[test]
fn every_preset_resolves() {
    // 按枚举的声明顺序逐个检查，新加预设时这里自动覆盖。
    for &provider in TranslationProviderId::ALL {
        if provider == TranslationProviderId::Custom {
            continue;
        }
        let preset = provider.preset();
        let endpoint = resolve(&settings(provider, "", "")).expect("预设应能解析");
        assert_eq!(endpoint.base_url, preset.base_url);
        assert_eq!(endpoint.model, preset.model);
        assert_eq!(endpoint.kind, api_kind(provider));
        assert_eq!(endpoint.requires_key, preset.requires_key);
    }
    assert_eq!(api_kind(TranslationProviderId::Anthropic), ApiKind::Anthropic);
    assert!(!TranslationProviderId::Ollama.preset().requires_key);
    assert_eq!(
        resolve(&settings(TranslationProviderId::Custom, "", "")),
        Err(EndpointIssue::MissingBaseUrl)
    );
}

/// 空串与空白回到预设值；自定义的地址去掉末尾的 `/`；Anthropic 改了地址仍是 Anthropic 接口。
#[test]
fn empty_values_fall_back_to_preset() {
    // 只有空白的地址与模型名当作没填。
    let resolved = resolve(&settings(TranslationProviderId::DeepSeek, "  ", " ")).unwrap();
    assert_eq!(resolved.base_url, "https://api.deepseek.com");
    assert_eq!(resolved.model, TranslationProviderId::DeepSeek.preset().model);
    assert_eq!(resolved.path, "");

    // 走代理的 Anthropic：地址换了，接口种类不变；末尾多余的 `/` 全部去掉。
    let proxy = settings(
        TranslationProviderId::Anthropic,
        "https://proxy.example.com/v1//",
        "my-model",
    );
    let custom = resolve(&proxy).unwrap();
    assert_eq!(custom.base_url, "https://proxy.example.com/v1");
    assert_eq!(custom.path, "/v1");
    assert_eq!(custom.kind, ApiKind::Anthropic);
    assert_eq!(custom.model, "my-model");
}

/// custom 有地址没有模型时是 MissingModel。
#[test]
fn custom_needs_model() {
    let custom = settings(TranslationProviderId::Custom, "https://llm.example.com/v1", "");
    assert_eq!(resolve(&custom), Err(EndpointIssue::MissingModel));
}

/// 带用户名、密码、查询串、片段，协议不对、没有主机或端口不是数字时是 InvalidUrl。
#[test]
fn invalid_urls() {
    // 每一种都应拒绝：用户名、密码、查询串与片段可能把 Key 送到别处，其余是写错的地址。
    for text in [
        "https://user:pw@api.example.com",
        "https://user@api.example.com",
        "https://api.example.com/v1?x=1",
        "https://api.example.com/v1#frag",
        "ftp://api.example.com",
        "api.example.com",
        "https://",
        "not a url",
        "https://api.example.com:80a/v1",
        "https://[::1/v1",
    ] {
        let custom = settings(TranslationProviderId::Custom, text, "m");
        assert_eq!(resolve(&custom), Err(EndpointIssue::InvalidUrl), "{text}");
    }
}

/// 公网的 http 被拒绝；本机与局域网的 http 可用；协议不区分大小写。
#[test]
fn insecure_remote_http() {
    // 公网明文 http 会把 Key 与聊天内容暴露在网络上，不允许。
    let remote = settings(TranslationProviderId::Custom, "http://api.example.com/v1", "m");
    assert_eq!(resolve(&remote), Err(EndpointIssue::InsecureRemoteHttp));
    // 局域网 IP、带方括号的 IPv6 回环、大写协议名的本机地址都可用。
    for base in [
        "http://192.168.1.20:8080/v1",
        "http://[::1]:11434/v1",
        "HTTP://localhost/v1",
    ] {
        assert!(
            resolve(&settings(TranslationProviderId::Custom, base, "m")).is_ok(),
            "{base}"
        );
    }
}

/// is_local_host 的每一类各一例。
#[test]
fn local_host_categories() {
    for host in [
        "localhost",
        "LOCALHOST",
        "studio.local",
        "nas",
        "127.0.0.1",
        "127.8.9.10",
        "10.1.2.3",
        "172.16.0.1",
        "172.31.255.255",
        "192.168.0.5",
        "169.254.10.10",
        "::1",
        "[::1]",
        "fd12:3456::1",
        "fc00::1",
        "fe80::1",
        // 带区域的链路本地地址：区域部分比较前去掉。
        "fe80::1%en0",
        // 映射到私有 IPv4 的 IPv6 地址按 IPv4 的规则。
        "::ffff:192.168.1.1",
    ] {
        assert!(is_local_host(host), "{host}");
    }
}

/// 反例：172.32.0.1 不在 172.16/12 里；example.com 是公网域名；另有公网 IP 与像数字地址的主机名。
#[test]
fn remote_hosts() {
    for host in [
        "172.32.0.1",
        "example.com",
        "8.8.8.8",
        "172.15.0.1",
        "2001:db8::1",
        "::ffff:8.8.8.8",
        // 十进制写的 127.0.0.1：有的系统会当成 IP，不算本机，以免绕过检查。
        "2130706433",
        // 十六进制写的 127.0.0.1，同上。
        "0x7f000001",
        "",
        "fe00::1",
    ] {
        assert!(!is_local_host(host), "{host}");
    }
}

/// 表意句点等 IDNA 里等同于 `.` 的字符先换成 `.` 再判断；百分号编码的写法与非 ASCII 的无点主机名都不算。
#[test]
fn ideographic_dots_are_not_local() {
    for host in [
        "evil。com",
        // 看起来没有点、实际会按域名解析的写法，都不算本机。
        "evil．com",
        "evil｡com",
        "evil%E3%80%82com",
        "evil%2ecom",
        "家里的电脑",
    ] {
        assert!(!is_local_host(host), "{host}");
    }
    // 换成 `.` 后仍是本机或局域网的写法照常算。
    // 末尾的表意句点换成 `.` 后去掉，剩下无点主机名 nas。
    assert!(is_local_host("nas。"));
    assert!(is_local_host("studio。local"));
    // 这些地址能拆开，但主机不算本机，所以是明文 http 的问题而不是格式问题。
    for url in [
        "http://evil。com/v1",
        "http://evil%E3%80%82com/v1",
        "http://evil．com:8080/v1",
    ] {
        let custom = settings(TranslationProviderId::Custom, url, "m");
        assert_eq!(resolve(&custom), Err(EndpointIssue::InsecureRemoteHttp), "{url}");
    }
}

/// 凭据管理器里的名字与 macOS 钥匙串的账户名相同。
#[test]
fn credential_accounts() {
    assert_eq!(
        // 每个预设一项 Key，换预设时各自保留。
        credential_account(TranslationProviderId::DeepSeek),
        "apikey.deepseek"
    );
    assert_eq!(
        credential_account(TranslationProviderId::Custom),
        format!("apikey.{}", TranslationProviderId::Custom.raw())
    );
}
