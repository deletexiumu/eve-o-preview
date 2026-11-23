// SPDX-License-Identifier: GPL-3.0-or-later
//
// 平台服务的组装点（架构文档 6.1 节）。App 只通过这里拿到各协议的实现。
// WP-C 的 FakeServices 用公开的成员初始化方法自行组装。
// 预警与翻译加了聊天日志、星图数据、模型传输、钥匙串与译文缓存 5 个服务（docs/macos/design-intel-translate.md 7.2 节）。
// v1.1 加了问题报告与更新两个服务（v1.1 设计 4.3 节）；日志入口 `PlatformLog` 搬到了 Logging/LogChannel.swift。

import Foundation
import EVEOPreviewCore

/// 全部平台服务的集合。
@MainActor public struct PlatformServices {
    /// 窗口枚举。
    public let windows: any WindowProvider
    /// 前台应用与屏幕的观察者。
    public let workspace: any WorkspaceObserver
    /// 窗口切换与最小化。
    public let activator: any WindowActivator
    /// 全局热键注册器。
    public let hotkeys: any HotkeyRegistrar
    /// 权限查询与引导。
    public let permissions: any PermissionService
    /// 捕获服务。
    public let capture: any CaptureService
    /// 游戏日志的跟踪服务（第一轮反馈新增，反馈文档 7.2 节）。
    public let combatLog: any CombatLogMonitor
    /// 问题报告用到的系统接口：系统信息、崩溃报告、压缩包、访达与浏览器（v1.1 设计 7.2 节）。
    public let diagnostics: any DiagnosticsService
    /// 更新的检查、下载与安装（v1.1 设计 8.4 节）。
    public let updates: any UpdateService
    /// 聊天日志的跟踪服务（docs/macos/design-intel-translate.md 5.2 节）。
    public let chatLog: any ChatLogMonitor
    /// 星图数据的提供者（4.4 节）。
    public let staticData: any StaticDataProvider
    /// 模型服务的 HTTP 传输（7.4 节）。
    public let translationTransport: any TranslationTransport
    /// 钥匙串里的 API Key（7.7 节）。
    public let secrets: any SecretStore
    /// 译文缓存文件（7.8 节）。
    public let translationCache: any TranslationCacheStore
    /// 向 ESI 核对人名（6.10 节）。
    public let pilotNames: any PilotNameResolver
    /// 人名缓存文件（6.10 节）。
    public let pilotNameCache: any PilotNameCacheStore

    /// 用各服务的实现组装。真实环境用 `makeLive()`；界面开发与测试可传入假实现。
    public init(windows: any WindowProvider, workspace: any WorkspaceObserver, activator: any WindowActivator,
                hotkeys: any HotkeyRegistrar, permissions: any PermissionService, capture: any CaptureService,
                combatLog: any CombatLogMonitor, diagnostics: any DiagnosticsService, updates: any UpdateService,
                chatLog: any ChatLogMonitor, staticData: any StaticDataProvider,
                translationTransport: any TranslationTransport, secrets: any SecretStore,
                translationCache: any TranslationCacheStore, pilotNames: any PilotNameResolver,
                pilotNameCache: any PilotNameCacheStore) {
        self.windows = windows
        self.workspace = workspace
        self.activator = activator
        self.hotkeys = hotkeys
        self.permissions = permissions
        self.capture = capture
        self.combatLog = combatLog
        self.diagnostics = diagnostics
        self.updates = updates
        self.chatLog = chatLog
        self.staticData = staticData
        self.translationTransport = translationTransport
        self.secrets = secrets
        self.translationCache = translationCache
        self.pilotNames = pilotNames
        self.pilotNameCache = pilotNameCache
    }

    /// 组装基于 AppKit、ScreenCaptureKit、AX、Carbon 与事件监听的真实实现。
    ///
    /// 窗口枚举与激活器共用一个 `AXWorker`，AX 调用因此在同一个 actor 上串行，
    /// 不会有两个调用同时等待同一个卡住的客户端。
    public static func makeLive() -> PlatformServices {
        let ax = AXWorker()
        let workspace = SystemWorkspaceObserver()
        return PlatformServices(windows: CGWindowProvider(ax: ax),
                                workspace: workspace,
                                activator: SystemWindowActivator(ax: ax, workspace: workspace),
                                hotkeys: SystemHotkeyRegistrar(),
                                permissions: SystemPermissionService(),
                                capture: SCKCaptureService(),
                                combatLog: FileCombatLogMonitor(),
                                diagnostics: SystemDiagnosticsService(),
                                updates: SystemUpdateService(),
                                chatLog: FileChatLogMonitor(),
                                staticData: BundleStaticDataProvider(),
                                translationTransport: URLSessionTranslationTransport(),
                                secrets: KeychainSecretStore(),
                                translationCache: FileTranslationCacheStore(),
                                pilotNames: ESIPilotNameResolver(),
                                pilotNameCache: FilePilotNameCacheStore())
    }
}
