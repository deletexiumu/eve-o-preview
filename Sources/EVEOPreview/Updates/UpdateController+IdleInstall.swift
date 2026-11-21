// SPDX-License-Identifier: GPL-3.0-or-later
//
// 空闲时自动安装（v1.1 设计第 19 节，用户在手工测试后提出）：「自动安装更新」打开、更新已下载好
// （`.readyToInstall`）时，每 20 秒看一次是否空闲，连续 3 次空闲（约 1 分钟）就安装并重新启动，
// 与用户点「重新启动以更新到 <版本>」走同一条路径（`restartToInstall`）。
//
// 空闲的条件，全部成立才算：
// - 没有 EVE 客户端窗口（`registry.clients` 为空）；
// - 系统里没有 bundle id 为 `com.ccpgames.eveonline` 的进程。只看窗口列表不够：缺权限时窗口可能读不全；
// - 本应用没有打开的普通窗口（设置、更新、问题报告）：用户正在用的窗口不该被重启关掉。
//
// 连续 3 次的要求是为了不在用户重开客户端的间隙里抢着重启。任一次不空闲，计数清零。
// 阶段离开 `.readyToInstall`（用户已点安装、关掉开关、出错）后，下一次检查时停止。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

extension UpdateController {
    /// 两次空闲检查的间隔。
    static let idleCheckInterval: Duration = .seconds(20)
    /// 连续空闲多少次才安装。
    static let idleChecksRequired = 3

    /// 开始（或重新开始）空闲检查。进入 `.readyToInstall` 时调用。
    func startIdleInstallWatch() {
        idleInstallTask?.cancel()
        idleInstallTask = Task { [weak self] in
            var idleCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: UpdateController.idleCheckInterval)
                guard !Task.isCancelled, let self, self.shouldKeepIdleWatch else { return }
                idleCount = self.isIdleForInstall ? idleCount + 1 : 0
                guard idleCount >= UpdateController.idleChecksRequired else { continue }
                self.log.info("没有 EVE 客户端在运行，自动安装更新并重新启动")
                self.restartToInstall()
                return
            }
        }
    }

    /// 是否还要继续检查：仍在等待安装，两个开关都打开。
    private var shouldKeepIdleWatch: Bool {
        guard case .readyToInstall = phase else { return false }
        return general.checkForUpdates && general.autoInstallUpdates
    }

    /// 现在是否空闲，条件见文件头。
    private var isIdleForInstall: Bool {
        guard coordinator.registry.clients.isEmpty else { return false }
        let eveRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == CGWindowProvider.eveBundleIdentifier && !$0.isTerminated
        }
        guard !eveRunning else { return false }
        // 菜单栏图标与缩略图都是无标题栏的窗口，只看带标题栏、可见的窗口。
        return !NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }
}
