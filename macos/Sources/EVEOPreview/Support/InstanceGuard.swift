// SPDX-License-Identifier: GPL-3.0-or-later
//
// 单实例检查与「重新启动」的交接（架构文档 6.6 节、7.1 节）。
//
// 权限页的「重新启动」由旧实例以新实例打开自己的包，再退出旧实例。旧实例退出要先写配置、停捕获，
// 最长约 2.5 秒；新实例启动时旧实例往往还在，单实例检查会看到它而退出新实例，结果两个实例都没了。
// 所以旧实例给新实例传 `--relaunched-from <旧实例 PID>`，新实例先等旧实例退出（有上限），
// 再做单实例检查，并且检查时不把这个 PID 算作「另一个实例」。

import AppKit
import EVEOPreviewPlatform

/// 单实例检查。
@MainActor
enum InstanceGuard {
    /// 等旧实例退出的上限。要大于旧实例退出流程的超时（AppDelegate.terminateTimeout），留出余量。
    static let previousInstanceWait: Duration = .seconds(8)
    /// 轮询旧实例是否退出的间隔，单位是秒。
    static let pollIntervalSeconds = 0.05

    /// 从启动参数里取旧实例的 PID；没有这个参数或值不是正整数时返回 nil。
    static func relaunchedFromPID(arguments: [String] = CommandLine.arguments) -> pid_t? {
        guard let index = arguments.firstIndex(of: SystemPermissionService.relaunchedFromArgument),
              index + 1 < arguments.count, let pid = pid_t(arguments[index + 1]), pid > 0 else { return nil }
        return pid
    }

    /// 如果本实例是「重新启动」打开的，等旧实例退出，返回要在单实例检查里排除的 PID。
    ///
    /// 只在那个 PID 确实是同一 bundle id 的应用时才等待并排除；其他情况（参数是伪造的、
    /// PID 已被别的进程复用）返回 nil，按普通启动处理。等到上限仍未退出时也排除它，
    /// 旧实例随后会自己退出。
    static func waitForPreviousInstance() -> pid_t? {
        guard let pid = relaunchedFromPID(), let bundleID = Bundle.main.bundleIdentifier else { return nil }
        guard let previous = NSRunningApplication(processIdentifier: pid),
              previous.bundleIdentifier == bundleID else {
            // 取不到说明旧实例已经退出，或者 PID 不属于本应用；两种情况都不用等。
            return nil
        }
        let log = AppLog.logger("App")
        let clock = ContinuousClock()
        let deadline = clock.now + previousInstanceWait
        // 启动阶段还没有界面，直接阻塞主线程轮询即可。
        while isAlive(pid), clock.now < deadline {
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
        if isAlive(pid) {
            log.error("旧实例 PID \(pid) 在等待上限内没有退出，不再等待")
        } else {
            log.info("旧实例 PID \(pid) 已退出")
        }
        return pid
    }

    /// 同一 bundle id 的其他实例是否在运行。没有 bundle id（`swift run`）时返回 false。
    ///
    /// - Parameter excluded: 不算作「其他实例」的 PID（正在退出的旧实例）。
    static func anotherInstanceIsRunning(excluding excluded: pid_t?) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        // 按对象比较而不按 PID：NSRunningApplication 的 PID 在某些进程上读出 -1（架构文档 E5）。
        let current = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { app in
            app != current && !app.isTerminated && (excluded == nil || app.processIdentifier != excluded)
        }
    }

    /// 进程是否还在。`kill(pid, 0)` 不发信号，只检查进程是否存在；没有权限（EPERM）也说明进程在。
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
