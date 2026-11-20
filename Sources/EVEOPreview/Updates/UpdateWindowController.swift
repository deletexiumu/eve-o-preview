// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新窗口（v1.1 设计 8.6 节）：宽 560 点、高 480 点，显示新版本、发布说明与按钮。
// 用户点出来的窗口激活本应用；自动弹出的窗口经 `DeferredPresenter`，只 `orderFrontRegardless()`，不抢焦点（4.5 节）。
//
// WP-0 只建骨架：`show` 不做事；WP-4 实现（视图在 UpdateView.swift、ReleaseNotesView.swift）。

import AppKit

/// 更新窗口的控制器。全部方法在主线程调用。
@MainActor final class UpdateWindowController {
    /// 更新功能的控制器，窗口按它的状态显示。
    let controller: UpdateController

    /// 建窗口控制器。窗口在第一次 `show` 时才建。
    init(controller: UpdateController) {
        self.controller = controller
    }

    /// 显示更新窗口。userInitiated 为真时激活本应用并成为 key 窗口；为假时不激活。窗口已显示时不重复弹出。
    ///
    /// 骨架：不做事（WP-4 实现）。
    func show(userInitiated: Bool) {}
}
