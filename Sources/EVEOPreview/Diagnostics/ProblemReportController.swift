// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的流程（v1.1 设计 6.3 节、7.1 节）。三个入口打开同一个报告窗口：菜单栏菜单的「报告问题…」、
// 「通用」页的同名按钮（手动情境），以及检测到崩溃后的提示（崩溃情境）。
// 用户确认之前不写任何文件，不打开浏览器。
//
// WP-0 只建骨架：方法都不做事；WP-2 实现（窗口在 ProblemReportWindowController.swift 等 WP-2 的文件里）。

import Foundation
import EVEOPreviewCore

/// 报告窗口的情境。
enum ProblemReportContext: Sendable, Equatable {
    /// 用户从菜单或设置窗口打开。
    case manual
    /// 检测到上一次运行崩溃。
    case crash(PendingCrash)
}

/// 问题报告的控制器。全部方法在主线程调用。
@MainActor final class ProblemReportController {
    /// 协调器：取运行时摘要、配置与平台服务，亮起菜单栏的圆点。协调器与本控制器同生命周期，所以不持有强引用。
    unowned let coordinator: AppCoordinator
    /// 启动时读到的运行环境。
    let environment: AppEnvironment
    /// state.json 的持有者：`pendingCrash` 与 `dismissedSessionIDs`。
    let state: StateController

    /// 建控制器。由 AppDelegate 在建好协调器之后调用。
    init(coordinator: AppCoordinator, environment: AppEnvironment, state: StateController) {
        self.coordinator = coordinator
        self.environment = environment
        self.state = state
    }

    /// 用户从菜单或设置窗口打开。
    ///
    /// 骨架：不做事（WP-2 实现）。
    func showReportWindow(context: ProblemReportContext) {}

    /// 检测到崩溃后调用：亮起菜单栏的提示，并在不打断游戏时显示报告窗口。
    ///
    /// 骨架：不做事（WP-2 实现）。
    func crashDetected(_ crash: PendingCrash) {}

    /// 用户选「不报告」：记下会话编号，清掉 `pendingCrash` 与圆点。
    ///
    /// 骨架：不做事（WP-2 实现）。
    func dismissPendingCrash() {}
}
