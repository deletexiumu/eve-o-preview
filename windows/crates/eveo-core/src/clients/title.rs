// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口标题与客户端身份的互相换算，对应 macOS 的 Clients/TitleParser.swift（架构文档 5.3 节）。
// EVE 客户端登录前标题是 `EVE`，选角色后变成 `EVE - <角色名>`。Windows 与 macOS 的标题格式相同。
// 用例在 shared/fixtures/title，两端的一致性测试读同一份。

//! 窗口标题解析。

use crate::model::{ClientIdentity, Pid};
use crate::support::text;

/// 登录界面客户端的标题。
pub const LOGIN_TITLE: &str = "EVE";
/// 角色客户端标题的前缀，后面紧跟角色名。
pub const CHARACTER_PREFIX: &str = "EVE - ";

/// 由窗口标题得出客户端身份。
///
/// - 去掉首尾空白后等于 `EVE`（不区分大小写）：[`ClientIdentity::Login`]。
/// - 以 `EVE - ` 开头（区分大小写）且后面非空：[`ClientIdentity::Character`]。
///   角色名本身可以含 ` - `，只去掉第一个前缀；角色名两端的空白也去掉（换行不算，与 macOS 相同）。
/// - `None`、空串、`EVE - ` 后面为空和其他标题：[`ClientIdentity::Unknown`]。
pub fn identity(title: Option<&str>) -> ClientIdentity {
    let Some(title) = title else {
        return ClientIdentity::Unknown;
    };
    let trimmed = text::trim_whitespace_and_newlines(title);
    if text::eq_ignore_case(trimmed, LOGIN_TITLE) {
        return ClientIdentity::Login;
    }
    let Some(rest) = trimmed.strip_prefix(CHARACTER_PREFIX) else {
        return ClientIdentity::Unknown;
    };
    let name = text::trim_whitespace(rest);
    if name.is_empty() {
        ClientIdentity::Unknown
    } else {
        ClientIdentity::Character(name.to_owned())
    }
}

/// 缩略图上显示的标题：角色返回角色名，登录返回 `EVE`，未知返回 `EVE (<pid>)`。
pub fn display_title(identity: &ClientIdentity, pid: Pid) -> String {
    match identity {
        ClientIdentity::Character(name) => name.clone(),
        ClientIdentity::Login => LOGIN_TITLE.to_owned(),
        ClientIdentity::Unknown => format!("{LOGIN_TITLE} ({pid})"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 角色名中间的 ` - ` 保留，只去掉第一个前缀。
    #[test]
    fn keeps_inner_separator() {
        assert_eq!(
            identity(Some("EVE - A - B")),
            ClientIdentity::Character("A - B".into())
        );
    }

    /// 角色名首尾的空格去掉，但换行不去（标题首尾的换行已在第一步去掉）。
    #[test]
    fn trims_name_spaces_only() {
        assert_eq!(
            identity(Some("EVE -   Pilot  ")),
            ClientIdentity::Character("Pilot".into())
        );
        assert_eq!(
            identity(Some("EVE - \nPilot")),
            ClientIdentity::Character("\nPilot".into())
        );
    }

    /// 读不到标题时是未知客户端，显示名带 PID。
    #[test]
    fn missing_title_is_unknown() {
        assert_eq!(identity(None), ClientIdentity::Unknown);
        assert_eq!(display_title(&ClientIdentity::Unknown, 42), "EVE (42)");
    }
}
