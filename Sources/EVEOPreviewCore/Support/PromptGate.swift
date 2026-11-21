// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口出现的时机（v1.1 设计 4.5 节）。用户可能在玩 EVE：应用自己弹出的窗口抢走键盘焦点时，
// 按键会落到窗口上。所以自动弹出的窗口在前台是 EVE 客户端时推迟，用户点出来的窗口不受限制。

import Foundation

/// 判断现在能不能弹出窗口。
public enum PromptGate {
    /// 现在能不能自己弹出窗口。用户点出来的窗口总是可以；自动的窗口在前台是 EVE 客户端时不可以。
    ///
    /// 前台是本应用（`.selfApp`）或其他应用（`.other`）时，自动的窗口也可以弹出。
    public static func canPresent(frontmost: FrontmostContext, userInitiated: Bool) -> Bool {
        if userInitiated { return true }
        switch frontmost {
        case .client: return false
        case .selfApp, .other: return true
        }
    }
}
