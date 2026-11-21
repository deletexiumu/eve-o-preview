// SPDX-License-Identifier: GPL-3.0-or-later
//
// 权限查询与引导（架构文档 4.4 节、6.6 节）。
// 屏幕录制授权后通常要重启应用才生效；辅助功能授权后立即生效。
// 两项权限都按代码签名识别应用，ad-hoc 签名每次构建后要重新授权（见 9.2 节）。

import AppKit
import ApplicationServices
import EVEOPreviewCore
import os

/// 基于 CoreGraphics 与 AX 接口的权限服务。
@MainActor public final class SystemPermissionService: PermissionService {
    /// 系统设置「屏幕与系统录音」面板的链接。
    public static let screenRecordingSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    /// 系统设置「辅助功能」面板的链接。
    public static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// 系统设置「文件与文件夹」面板的链接（反馈文档 7.9 节）。
    public static let filesAndFoldersSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// 日志。
    private let log = PlatformLog.logger("Permissions")

    /// 建一个权限服务。
    public init() {}

    /// 当前两项权限的状态。两个查询都不弹窗。
    public func status() -> PermissionStatus {
        PermissionStatus(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }

    /// 请求屏幕录制权限，返回调用时是否已授权。未授权时系统弹出提示（每个应用通常只弹一次）。
    @discardableResult public func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 请求辅助功能权限，未授权时弹出系统提示。
    public func requestAccessibility() {
        // 全局常量 kAXTrustedCheckOptionPrompt 在 Swift 6 下不能直接引用（非 Sendable 的全局变量），
        // 所以直接写它的字符串值。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开系统设置的对应面板。
    public func openSystemSettings(_ pane: PermissionPane) {
        let url: URL
        switch pane {
        case .screenRecording: url = SystemPermissionService.screenRecordingSettingsURL
        case .accessibility: url = SystemPermissionService.accessibilitySettingsURL
        case .filesAndFolders: url = SystemPermissionService.filesAndFoldersSettingsURL
        }
        NSWorkspace.shared.open(url)
    }

    /// 新实例的启动参数：后面跟旧实例的 PID。新实例据此先等旧实例退出，再做单实例检查（见 main.swift）。
    public static let relaunchedFromArgument = "--relaunched-from"

    /// 以新实例重新打开本应用，然后退出当前进程。
    ///
    /// 新实例带 `--relaunched-from <本进程 PID>` 启动；否则它的单实例检查会看到还没退出的旧实例，
    /// 新实例退出自己，结果两个实例都没了。环境变量里以 `EVEO_` 开头的调试开关原样传给新实例。
    /// 只在作为 `.app` 运行时有效；用 `swift run` 直接运行可执行文件时没有包，只记日志不退出。
    public func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            log.error("不是从 .app 运行，不能重新启动")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // 新实例与旧实例会短暂并存，所以要求系统另开一个实例，而不是激活旧实例。
        configuration.createsNewApplicationInstance = true
        // 不把新实例带到前台：空闲时自动更新后的重新启动不该抢走焦点。要显示窗口时，
        // 设置窗口等界面会自己激活应用。
        configuration.activates = false
        configuration.arguments = [SystemPermissionService.relaunchedFromArgument, String(getpid())]
        // 只在确有调试开关时才设：正式使用时没有 EVEO_ 变量，不改动新实例的环境。
        let debugEnvironment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("EVEO_") }
        if !debugEnvironment.isEmpty { configuration.environment = debugEnvironment }
        // 回调由 LaunchServices 在后台队列调用。本类是 @MainActor，不写 @Sendable 时闭包会被推断为主线程隔离，
        // Swift 6 运行时检查到不在主线程就终止进程：新实例已启动，旧实例却以崩溃退出（v1.1 手工测试发现）。
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { @Sendable [log] _, error in
            if let error {
                log.error("重新启动失败：\(error.localizedDescription, privacy: .public)")
                return
            }
            // 不用 DispatchQueue.main.async：在主队列任务里调 terminate 会死锁，见 `SessionTracker.installSignalSources`。
            RunLoop.main.perform {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }
}
