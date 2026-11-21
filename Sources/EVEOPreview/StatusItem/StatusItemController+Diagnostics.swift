// SPDX-License-Identifier: GPL-3.0-or-later
//
// 菜单栏菜单的诊断部分（v1.1 设计 11.1 节）：
// - 顶部的提示项：「EVE-O Preview 上次意外退出 — 报告…」（`crashPending`），点开崩溃情境的报告窗口。
// - 工具项：「报告问题…」，点开手动情境的报告窗口。

import AppKit

extension StatusItemController {
    /// 菜单顶部的诊断提示项，没有时返回空数组。
    func diagnosticsAttentionItems() -> [NSMenuItem] {
        guard coordinator.attention.contains(.crashPending), coordinator.problemReport != nil else { return [] }
        return [ClosureMenuItem(L10n.diagnostics.menuCrashPending) { [weak coordinator] in
            coordinator?.problemReport?.showPendingCrashReport()
        }]
    }

    /// 「报告问题…」所在的工具项。
    func diagnosticsMenuItems() -> [NSMenuItem] {
        guard coordinator.problemReport != nil else { return [] }
        return [ClosureMenuItem(L10n.diagnostics.menuReportProblem) { [weak coordinator] in
            coordinator?.problemReport?.showReportWindow(context: .manual)
        }]
    }
}
