// SPDX-License-Identifier: GPL-3.0-or-later
//
// PromptGate 的用例（v1.1 设计 4.5 节、14.1 节）：3 种前台与是否由用户发起的 6 种组合。

import Testing
import EVEOPreviewCore

/// 窗口能否弹出。
struct PromptGateTests {
    /// 用户点出来的窗口在任何前台下都能弹出。
    @Test(arguments: [FrontmostContext.client(pid: 90_001), .selfApp, .other])
    func userInitiatedAlwaysAllowed(frontmost: FrontmostContext) {
        #expect(PromptGate.canPresent(frontmost: frontmost, userInitiated: true))
    }

    /// 自动的窗口在前台是 EVE 客户端时不弹出。
    @Test func automaticBlockedWhenClientFrontmost() {
        #expect(!PromptGate.canPresent(frontmost: .client(pid: 90_001), userInitiated: false))
    }

    /// 自动的窗口在前台是本应用或其他应用时可以弹出。
    @Test(arguments: [FrontmostContext.selfApp, .other])
    func automaticAllowedOtherwise(frontmost: FrontmostContext) {
        #expect(PromptGate.canPresent(frontmost: frontmost, userInitiated: false))
    }
}
