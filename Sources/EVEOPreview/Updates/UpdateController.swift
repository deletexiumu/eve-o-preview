// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新的检查、提示与安装流程（v1.1 设计 8.5、8.6、9.5 节）。更新窗口与「通用」页按 `phase` 与 `capability` 显示；
// 本类是 `@Observable`，状态变化时 SwiftUI 视图自己刷新。
//
// WP-0 只建骨架：不检查、不下载，`capability` 保持 `.unavailable`；WP-3 实现（下载与安装在 UpdateController+Install.swift）。
// 骨架带一个界面调试入口（13.1 节第 4 项），WP-3 实现时保留：
// `EVEO_FAKE=1` 且设了 `EVEO_UPDATE_UI_STATE` 时，`start()` 把 `phase` 直接设成对应的样例值，取值是
// `available`、`notifyonly`、`downloading`、`ready`、`failed`、`uptodate`（样例在 FakeUpdateService.swift）。
// 这时 `checkNow` 只重新显示更新窗口，不改样例。WP-4 靠它在 WP-3 完成之前做界面。

import Foundation
import Observation
import EVEOPreviewCore

/// 更新功能的控制器。全部方法在主线程调用。
@MainActor @Observable final class UpdateController {
    /// 界面阶段。
    private(set) var phase: UpdatePhase = .idle
    /// 这个构建能否自动安装。`start()` 算出；之前是 `.unavailable`。
    private(set) var capability: InstallCapability = .unavailable
    /// 最近一次得到服务器答复的时刻，「通用」页显示它。
    private(set) var lastCheckAt: Date?
    /// 检查地址（正式地址或 `EVEO_UPDATE_FEED_URL` 的测试地址）。
    let feed: UpdateFeed
    /// 启动时读到的运行环境。
    let environment: AppEnvironment
    /// 请求显示更新窗口。参数为真表示用户点出来的，可以激活本应用。
    @ObservationIgnored var presentWindow: (@MainActor (_ userInitiated: Bool) -> Void)?

    /// 协调器：取平台服务与配置，亮起菜单栏的圆点。协调器与本控制器同生命周期，所以不持有强引用。
    @ObservationIgnored unowned let coordinator: AppCoordinator
    /// state.json 的持有者。
    @ObservationIgnored let state: StateController
    /// `EVEO_UPDATE_UI_STATE` 的取值（已转成小写）；不在演示模式或没设时是 nil。
    @ObservationIgnored let debugUIState: String?

    /// 建控制器。由 AppDelegate 在建好协调器之后调用；调用 `start()` 后才开始工作。
    init(coordinator: AppCoordinator, environment: AppEnvironment, state: StateController) {
        self.coordinator = coordinator
        self.environment = environment
        self.state = state
        let variables = ProcessInfo.processInfo.environment
        feed = UpdateFeed.resolve(override: variables["EVEO_UPDATE_FEED_URL"])
        lastCheckAt = state.state.updates.lastCheckAt
        debugUIState = coordinator.isFakeMode ? variables["EVEO_UPDATE_UI_STATE"]?.lowercased() : nil
    }

    /// 算出 `capability`，清理残留文件，恢复上次的状态，并开始定时检查。
    ///
    /// 骨架：只处理 `EVEO_UPDATE_UI_STATE` 的调试入口（WP-3 实现其余部分）。
    func start() {
        guard let name = debugUIState, let sample = FakeUpdateService.samplePhase(named: name) else { return }
        phase = sample.phase
        capability = sample.capability
        switch sample.phase {
        case .available: coordinator.setAttention(.updateAvailable, on: true)
        case .readyToInstall: coordinator.setAttention(.updateReady, on: true)
        default: break
        }
    }

    /// 立即检查一次。用户发起时不看间隔。
    ///
    /// 骨架：调试入口打开时只重新显示更新窗口；否则不做事（WP-3 实现）。
    func checkNow(userInitiated: Bool) {
        guard debugUIState != nil else { return }
        presentWindow?(userInitiated)
    }

    /// 下载、校验、安装并重新启动。
    ///
    /// 骨架：不做事（WP-3 实现）。
    func install() {}

    /// 取消进行中的下载或核对。
    ///
    /// 骨架：不做事（WP-3 实现）。
    func cancel() {}

    /// 跳过当前提示的版本：只影响自动检查。
    ///
    /// 骨架：不做事（WP-3 实现）。
    func skipThisVersion() {}

    /// 关窗口，保留圆点与菜单项，下次自动检查时再提示。
    ///
    /// 骨架：不做事（WP-3 实现）。
    func remindLater() {}

    /// 用默认浏览器打开当前版本的发布页。
    ///
    /// 骨架：不做事（WP-3 实现）。
    func openReleasePage() {}

    /// 自动安装已下载好时，由菜单项「重新启动以更新到 <版本>」调用。
    ///
    /// 骨架：不做事（WP-3 实现）。
    func restartToInstall() {}

    /// 退出前调用：自动安装已下载好时安装，不重新启动。最多等 timeout。
    ///
    /// 骨架：立即返回（WP-3 实现）。
    func installOnQuitIfReady(timeout: Duration) async {}
}
