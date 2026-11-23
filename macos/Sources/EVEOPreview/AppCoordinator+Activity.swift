// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的后台活动（App Nap）部分。
//
// 本应用大多数时间在后台：前台是游戏。macOS 会给长时间不在前台、窗口也被挡住的应用开 App Nap，
// 降低计时器精度与进程优先级。战斗提醒靠计时器读游戏日志，鼠标热键靠事件监听线程及时回调，
// 被 App Nap 拖慢后提醒会晚到，事件监听还可能因回调超时被系统关掉（tapDisabledByTimeout）。
// 所以在「战斗提醒已开启」或「鼠标事件监听在用」时，向系统声明一项后台活动；两者都不需要时结束它。
//
// 选项用 `.userInitiatedAllowingIdleSystemSleep`：
// - 它包含 App Nap 豁免，计时器与优先级不被压低。
// - 它允许系统空闲睡眠：玩家离开时 Mac 照常睡眠，本应用不阻止。
// - 它同时关掉 sudden termination 与 automatic termination：活动期间系统不会静默结束本进程，
//   注销或关机时照常走 `applicationShouldTerminate` 的退出流程。本应用常驻菜单栏，本来就不希望被自动结束。
// - 不用 `.latencyCritical`：那是给音视频这类毫秒级的工作用的，耗电更多；
//   本应用的需求是百毫秒到秒级（日志 2 秒兜底轮询、热键触发 0.5 秒内有效），用不着。

import EVEOPreviewCore
import Foundation

extension AppCoordinator {
    /// 此刻是否需要后台活动：没有退出，且战斗提醒、预警或翻译已开启，或鼠标事件监听在用。
    ///
    /// 「鼠标事件监听在用」按热键规划判断：有鼠标绑定，且鼠标绑定都没有注册失败
    /// （没有辅助功能权限、监听不可用时监听已拆除，不需要防 App Nap）。
    private var needsBackgroundActivity: Bool {
        guard !isStopped else { return false }
        if profile.combatAlert.enabled { return true }
        // 预警与翻译：聊天日志的读取与翻译的定时都不应被 App Nap 拖慢（docs/macos/design-intel-translate.md 9.3 节）。
        if profile.intel.enabled || profile.translation.enabled { return true }
        let hasMouseBindings = hotkeyPlan.bindings.contains { $0.hotkey.isMouse }
        let mouseFailed = hotkeyFailures.contains { $0.binding.hotkey.isMouse }
        return hasMouseBindings && !mouseFailed
    }

    /// 按当前状态开始或结束后台活动。已是目标状态时不动，可以随时调用。
    func updateBackgroundActivity() {
        let needed = needsBackgroundActivity
        if needed, backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "EVE-O Preview: combat alerts, chat overlays and mouse hotkeys need timely timers")
            log.info("开始后台活动，防止 App Nap")
        } else if !needed, let activity = backgroundActivity {
            ProcessInfo.processInfo.endActivity(activity)
            backgroundActivity = nil
            log.info("结束后台活动")
        }
    }
}
