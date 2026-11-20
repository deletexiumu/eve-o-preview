// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口标题与客户端身份的互相换算（架构文档 5.3 节）。
// EVE 客户端登录前标题是 `EVE`，选角色后变成 `EVE - <角色名>`。

import Foundation

/// 窗口标题解析。
public enum TitleParser {
    /// 登录界面客户端的标题。
    public static let loginTitle = "EVE"
    /// 角色客户端标题的前缀，后面紧跟角色名。
    public static let characterPrefix = "EVE - "

    /// 由窗口标题得出客户端身份。
    ///
    /// - 去掉首尾空白后等于 `EVE`（不区分大小写）：`.login`。
    /// - 以 `EVE - ` 开头（区分大小写）且后面非空：`.character(后面的部分)`。
    ///   角色名本身可以含 ` - `，只去掉第一个前缀；角色名两端的空白也去掉。
    /// - `nil`、空串、`EVE - ` 后面为空和其他标题：`.unknown`。
    public static func identity(fromTitle title: String?) -> ClientIdentity {
        guard let title else { return .unknown }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(loginTitle) == .orderedSame {
            return .login
        }
        guard trimmed.hasPrefix(characterPrefix) else { return .unknown }
        let name = trimmed.dropFirst(characterPrefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? .unknown : .character(name)
    }

    /// 缩略图上显示的标题：角色返回角色名，登录返回 `EVE`，未知返回 `EVE (<pid>)`。
    public static func title(for identity: ClientIdentity, pid: Int32) -> String {
        switch identity {
        case .character(let name): return name
        case .login: return loginTitle
        case .unknown: return "\(loginTitle) (\(pid))"
        }
    }
}
