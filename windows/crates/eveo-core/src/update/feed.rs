// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新检查的地址与附件地址的核对（docs/windows/architecture.md 6.2、6.3 节，规则移植 macOS 的 UpdateFeed）。
//
// Windows 版与 macOS 版发在同一个仓库里，`releases/latest` 永远指向 macOS 版，所以 Windows 只取 Release 列表
// （每页 100 个），在里面找 tag 以 `win-v` 开头的项。一次请求同时得到最新版与中间版本的发布说明。
//
// 测试地址：环境变量 `EVEO_UPDATE_FEED_URL` 指向一个 Release 列表的 JSON。只接受 https，或主机是
// 127.0.0.1、localhost、::1 的 http；不符合时用正式地址。测试地址下附件与发布页应与它同源。
//
// 正式地址下，附件与发布页的地址同时满足：
// - 原文以 `https://github.com/deletexiumu/eve-o-preview/releases/` 开头，不含反斜杠、`%2e`、`%2f`、`%5c`（不分大小写）；
// - 没有用户名、密码与端口（前缀已经保证主机之后紧跟 `/`）；
// - 路径里没有 `.` 或 `..` 段。
// Windows 版从改名之后才开始发布，不接受旧仓库名 `eve-o-preview-macos`。

//! 更新检查的地址。

/// 正式的 Release 列表地址。每页个数与 `history::PAGE_SIZE` 一致，由用例核对。
pub const PRODUCTION_LIST_URL: &str =
    "https://api.github.com/repos/deletexiumu/eve-o-preview/releases?per_page=100";
/// 正式地址下，附件与发布页的地址应以它开头。
pub const PRODUCTION_ASSET_PREFIX: &str = "https://github.com/deletexiumu/eve-o-preview/releases/";
/// 发布页列表：检查失败、不能自动安装时打开它。
pub const RELEASES_PAGE_URL: &str = "https://github.com/deletexiumu/eve-o-preview/releases";
/// Windows 版的 tag 前缀；macOS 版的 tag 是 `v*`。
pub const TAG_PREFIX: &str = "win-v";
/// 校验和文件的附件名。
pub const CHECKSUMS_NAME: &str = "SHA256SUMS.txt";
/// 校验和文件的 ed25519 签名的附件名。
pub const SIGNATURE_NAME: &str = "SHA256SUMS.txt.sig";

/// 一个版本的应用压缩包的附件名，如 `EVE-O-Preview-0.9.0-windows-x64.zip`。
pub fn archive_name(version: &str) -> String {
    format!("EVE-O-Preview-{version}-windows-x64.zip")
}

/// tag 去掉 `win-v` 前缀后的版本文字；不是 Windows 的 tag 时返回 None。
pub fn version_text(tag: &str) -> Option<&str> {
    // 只认小写的前缀：发布脚本只打这一种写法，别的写法多半是误打的 tag。
    tag.strip_prefix(TAG_PREFIX)
}

/// 更新检查的地址。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateFeed {
    /// Release 列表的地址。
    pub list_url: String,
    /// 是否是环境变量指定的测试地址。
    pub is_test_feed: bool,
}

impl UpdateFeed {
    /// 正式地址。
    pub fn production() -> Self {
        Self {
            list_url: PRODUCTION_LIST_URL.to_owned(),
            is_test_feed: false,
        }
    }

    /// override 是环境变量 EVEO_UPDATE_FEED_URL 的值。为空或不符合条件时用正式地址；
    /// 是否记日志由调用方比较 override 与结果决定。
    pub fn resolve(override_url: Option<&str>) -> Self {
        let Some(text) = override_url.filter(|text| !text.is_empty()) else {
            return Self::production();
        };
        match Origin::parse(text) {
            Some(origin) if origin.scheme == "https" || (origin.scheme == "http" && origin.is_loopback()) => {
                Self {
                    list_url: text.to_owned(),
                    is_test_feed: true,
                }
            }
            _ => Self::production(),
        }
    }

    /// 附件与发布页的地址是否可用。规则见本文件开头。
    pub fn accepts(&self, url: &str) -> bool {
        if !self.is_test_feed {
            return is_production_asset(url);
        }
        match (Origin::parse(url), Origin::parse(&self.list_url)) {
            (Some(candidate), Some(own)) => candidate == own,
            _ => false,
        }
    }
}

/// 正式地址下的规则，见本文件开头。先查原文：解码之后再查就晚了。
fn is_production_asset(url: &str) -> bool {
    let Some(rest) = url.strip_prefix(PRODUCTION_ASSET_PREFIX) else {
        return false;
    };
    // 编码的点与斜杠在服务器那边可能被解码成 `..` 或新的路径段，原文里一律不收。
    let lowered = url.to_ascii_lowercase();
    if url.contains('\\') || ["%2e", "%2f", "%5c"].iter().any(|bad| lowered.contains(bad)) {
        return false;
    }
    // 路径到 `?` 或 `#` 为止；前缀之后的各段都不能是 `.` 或 `..`。
    let path = rest.split(['?', '#']).next().unwrap_or_default();
    !path.split('/').any(|segment| segment == "." || segment == "..")
}

/// 地址的源：协议、主机与端口，都已规范化。
#[derive(Debug, Clone, PartialEq, Eq)]
struct Origin {
    /// 小写的协议。
    scheme: String,
    /// 小写的主机，IPv6 地址去掉方括号。
    host: String,
    /// 端口；地址里省略时取协议的默认端口（http 80，https 443），其他协议是 None。
    port: Option<u16>,
}

impl Origin {
    /// 从地址取源；没有协议或主机、端口不是数字时返回 None。用户名与密码不参与比较。
    fn parse(url: &str) -> Option<Self> {
        // 只认 `协议://主机…` 的写法；没有 `//` 的地址（如 `file:` 的某些写法、相对地址）不算。
        let (scheme, rest) = url.split_once("://")?;
        if scheme.is_empty()
            || !scheme
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"+-.".contains(&b))
        {
            return None;
        }
        let scheme = scheme.to_ascii_lowercase();
        // 主机部分到第一个 `/`、`?` 或 `#` 为止；`@` 之前是用户信息。
        let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
        let host_port = authority.rsplit_once('@').map_or(authority, |(_, tail)| tail);
        let (host, port_text) = if let Some(inner) = host_port.strip_prefix('[') {
            // IPv6：`[::1]:8080`。
            let (host, tail) = inner.split_once(']')?;
            (host, tail.strip_prefix(':'))
        } else {
            match host_port.rsplit_once(':') {
                Some((host, port)) => (host, Some(port)),
                None => (host_port, None),
            }
        };
        if host.is_empty() {
            return None;
        }
        // 写了端口就要是 0～65535 的数字；没写时取协议的默认端口，同源比较时与显式的默认端口相同。
        let port = match port_text {
            Some(text) => Some(text.parse().ok()?),
            None => match scheme.as_str() {
                "http" => Some(80),
                "https" => Some(443),
                _ => None,
            },
        };
        Some(Self {
            scheme,
            host: host.to_ascii_lowercase(),
            port,
        })
    }

    /// 主机是不是本机回环地址。
    fn is_loopback(&self) -> bool {
        ["127.0.0.1", "localhost", "::1"].contains(&self.host.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 本地测试地址。
    fn test_feed() -> UpdateFeed {
        UpdateFeed::resolve(Some("http://127.0.0.1:8123/releases.json"))
    }

    /// 没有覆盖、为空、或不合格时用正式地址；https 与回环 http 是测试地址。
    #[test]
    fn resolves_override() {
        assert_eq!(UpdateFeed::resolve(None), UpdateFeed::production());
        assert_eq!(UpdateFeed::resolve(Some("")), UpdateFeed::production());
        for bad in [
            "http://example.com/releases.json",
            "ftp://127.0.0.1/releases.json",
            "file:///C:/feed.json",
            "not a url",
            "http://:80/x",
        ] {
            assert_eq!(UpdateFeed::resolve(Some(bad)), UpdateFeed::production(), "{bad}");
        }
        for good in [
            "https://example.com/feed.json",
            "http://localhost:8123/releases.json",
            "http://[::1]:8123/releases.json",
            "HTTP://LOCALHOST/releases.json",
        ] {
            let feed = UpdateFeed::resolve(Some(good));
            assert!(feed.is_test_feed, "{good}");
            assert_eq!(feed.list_url, good);
        }
    }

    /// 正式地址下，本仓库的 Release 地址通过；别的仓库、主机、协议、端口、用户信息、点段与编码都不通过。
    #[test]
    fn production_rules() {
        let feed = UpdateFeed::production();
        let good = [
            "https://github.com/deletexiumu/eve-o-preview/releases/download/win-v0.9.0/EVE-O-Preview-0.9.0-windows-x64.zip",
            "https://github.com/deletexiumu/eve-o-preview/releases/tag/win-v0.9.0",
        ];
        for url in good {
            assert!(feed.accepts(url), "{url}");
        }
        let bad = [
            "https://github.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.0.0",
            "https://github.com/deletexiumu/eve-o-preview-fork/releases/x",
            "https://github.com/someone/eve-o-preview/releases/x",
            "http://github.com/deletexiumu/eve-o-preview/releases/x",
            "https://github.com:8443/deletexiumu/eve-o-preview/releases/x",
            "https://user@github.com/deletexiumu/eve-o-preview/releases/x",
            "https://evil.example/deletexiumu/eve-o-preview/releases/x",
            "https://github.com/deletexiumu/eve-o-preview/releases/../../../evil/repo/releases/x",
            "https://github.com/deletexiumu/eve-o-preview/releases/./x",
            "https://github.com/deletexiumu/eve-o-preview/releases/%2E%2E/x",
            "https://github.com/deletexiumu/eve-o-preview/releases/a%2fb",
            "https://github.com/deletexiumu/eve-o-preview/releases/a%5Cb",
            "https://github.com/deletexiumu/eve-o-preview/releases/a\\b",
            "https://github.com/deletexiumu/eve-o-preview/releasesx",
        ];
        for url in bad {
            assert!(!feed.accepts(url), "{url}");
        }
    }

    /// 测试地址下只看同源：协议、主机、端口都相同（省略的端口按默认端口）。
    #[test]
    fn test_feed_same_origin() {
        let feed = test_feed();
        assert!(feed.accepts("http://127.0.0.1:8123/EVE-O-Preview-0.9.1-windows-x64.zip"));
        assert!(!feed.accepts("http://localhost:8123/x.zip"));
        assert!(!feed.accepts("http://127.0.0.1:8124/x.zip"));
        assert!(!feed.accepts("https://127.0.0.1:8123/x.zip"));
        let https = UpdateFeed::resolve(Some("https://example.com/feed.json"));
        assert!(https.accepts("https://EXAMPLE.com:443/a.zip"));
        assert!(!https.accepts("https://example.org/a.zip"));
        let v6 = UpdateFeed::resolve(Some("http://[::1]:8123/releases.json"));
        assert!(v6.accepts("http://[::1]:8123/a.zip"));
    }

    /// 附件名与 tag 前缀。
    #[test]
    fn names() {
        assert_eq!(archive_name("0.9.0"), "EVE-O-Preview-0.9.0-windows-x64.zip");
        assert_eq!(version_text("win-v0.9.0-beta.1"), Some("0.9.0-beta.1"));
        assert_eq!(version_text("v1.3.1"), None);
        assert_eq!(version_text("Win-v0.9.0"), None);
        assert!(PRODUCTION_LIST_URL.ends_with(&format!("per_page={}", crate::update::history::PAGE_SIZE)));
    }
}
