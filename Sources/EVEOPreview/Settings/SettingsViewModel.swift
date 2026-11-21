// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的视图模型（架构文档 7.4 节）。读写 ConfigController：开关与滑块改动后立即生效并保存
// （保存由 ConfigController 延迟 0.5 秒合并），文本框在提交时生效（由 FormComponents 的 CommitTextField 保证）。
// 运行时状态（在线客户端、热键规划、注册失败、权限）由协调器在每次重算后推送过来。
//
// 本文件是状态与绑定；配置方案、循环组、热键、权限等动作在 SettingsViewModel+Actions.swift。

import AppKit
import SwiftUI
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 设置窗口的视图模型。
@MainActor
@Observable
final class SettingsViewModel {
    /// 协调器。
    @ObservationIgnored let coordinator: AppCoordinator

    /// 当前显示的页。
    var page: SettingsPage = .clients
    /// 当前配置的副本，随 ConfigController 的变化更新。
    private(set) var config: AppConfig
    /// 在线客户端。
    private(set) var clients: [EVEClient] = []
    /// 当前生效的热键规划。
    private(set) var hotkeyPlan = HotkeyPlan(bindings: [], issues: [])
    /// 热键注册失败项。
    private(set) var hotkeyFailures: [HotkeyRegistrationFailure] = []
    /// 权限状态。
    private(set) var permissions: PermissionStatus = .denied
    /// 「全部隐藏」开关。
    private(set) var hideAll = false
    /// 游戏日志跟踪服务的状态，「提醒」页的状态行用它（反馈文档 7.11 节）。
    private(set) var combatLogStatus: CombatLogStatus = .stopped
    /// 聊天日志跟踪服务的状态，「预警」页与「翻译」页的状态行用它（docs/design-intel-translate.md 第 10 节）。
    private(set) var chatLogStatus: ChatLogStatus = .stopped
    /// 日志目录里最近出现过的频道，「从日志添加」菜单用它；由 `refreshDiscoveredChannels()` 更新。
    private(set) var discoveredChannels: [DiscoveredChannel] = []
    /// 星图数据的状态：`build-<版本号>`、`missing`、`invalid`、`notLoaded`。
    private(set) var staticDataState = "notLoaded"
    /// 预警与翻译状态的版本号（`ChatFeatureController.statusRevision` 的副本）。「预警」页与「翻译」页读它，
    /// 两个功能的位置、翻译状态与缓存条数变化时随之重绘。
    private(set) var chatRevision = 0
    /// 正在录制热键的录制器数量；大于 0 时全局热键处于暂停状态。
    @ObservationIgnored var recordingCount = 0

    /// 用协调器建视图模型，并订阅配置与运行时状态的变化。
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        config = coordinator.config.config
        coordinator.config.addObserver { [weak self] _, new in self?.config = new }
        coordinator.addRuntimeObserver { [weak self] in self?.refreshRuntime() }
        refreshRuntime()
    }

    /// 从协调器拉取运行时状态。只在值变化时赋值，避免无谓的界面刷新（协调器每秒都会推送）。
    func refreshRuntime() {
        let source = coordinator
        if clients != source.registry.clients { clients = source.registry.clients }
        if hotkeyPlan != source.hotkeyPlan { hotkeyPlan = source.hotkeyPlan }
        if hotkeyFailures != source.hotkeyFailures { hotkeyFailures = source.hotkeyFailures }
        if permissions != source.permissions { permissions = source.permissions }
        if hideAll != source.session.hideAll { hideAll = source.session.hideAll }
        if combatLogStatus != source.combatLogStatus { combatLogStatus = source.combatLogStatus }
        if chatLogStatus != source.chat.chatLogStatus { chatLogStatus = source.chat.chatLogStatus }
        if staticDataState != source.chat.staticDataState { staticDataState = source.chat.staticDataState }
        if chatRevision != source.chat.statusRevision { chatRevision = source.chat.statusRevision }
    }

    /// 聊天日志跟踪服务正在读日志目录。这时列出频道不会再弹「文稿」权限提示，频道列表可以自动刷新。
    var isWatchingChatLogs: Bool {
        if case .watching = chatLogStatus { return true }
        return false
    }

    /// 重新列出日志目录里最近的频道。第一次调用时才读目录，系统的「文稿」权限提示出现在这一步之后。
    func refreshDiscoveredChannels() {
        let chat = coordinator.chat
        Task { [weak self] in
            let channels = await chat.discoverChannels()
            guard let self, self.discoveredChannels != channels else { return }
            self.discoveredChannels = channels
        }
    }

    /// 窗口打开时刷新一次状态。
    func windowDidOpen() {
        refreshRuntime()
    }

    /// 窗口关闭：录制器已由窗口控制器取消；计数仍不为 0 时（不应发生）兜底恢复全局热键。
    func windowDidClose() {
        if recordingCount > 0 {
            recordingCount = 0
            coordinator.resumeHotkeys()
        }
    }

    // MARK: - 只读信息

    /// 当前配置方案。
    var profile: Profile { config.activeProfile }
    /// 是否为演示模式。
    var isFakeMode: Bool { coordinator.isFakeMode }
    /// 配置文件的位置。
    var configFileURL: URL { coordinator.config.fileURL }

    /// 读配置时的问题说明；没有问题时为 nil。读失败时本次会话不写盘，提示要醒目。
    var configNotice: String? {
        if let error = coordinator.config.loadError {
            switch error {
            case .newerSchema(let found, let supported):
                return L10n.settings.newerSchemaNotice(found: found, supported: supported)
            case .ioFailure(let operation, let path, let reason):
                // Core 只给出步骤、路径与系统说明，文字由界面语言拼出（不显示 Core 的技术说明）。
                return L10n.settings.loadFailedNotice(L10n.settings.configFileFailure(operation, path: path,
                                                                                      reason: reason))
            case .encodingFailure:
                // load() 不会抛它（损坏的文件被隔离）；万一出现，只显示通用说明，技术细节在日志里。
                return L10n.settings.loadFailedNotice(L10n.settings.configContentInvalid)
            }
        }
        for warning in coordinator.config.warnings {
            if case .corruptFileQuarantined(let path) = warning {
                return L10n.settings.quarantinedNotice(path)
            }
        }
        return nil
    }

    // MARK: - 绑定

    /// 当前配置方案某个字段的绑定。写入立即生效并安排保存。
    func binding<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding(get: { self.profile[keyPath: keyPath] },
                set: { value in self.updateProfile { $0[keyPath: keyPath] = value } })
    }

    /// 全局设置某个字段的绑定。
    func generalBinding<Value>(_ keyPath: WritableKeyPath<GeneralSettings, Value>) -> Binding<Value> {
        Binding(get: { self.config.general[keyPath: keyPath] },
                set: { value in self.coordinator.config.update { $0.general[keyPath: keyPath] = value } })
    }

    /// 「全部隐藏」的绑定（会话状态，不持久化）。
    var hideAllBinding: Binding<Bool> {
        Binding(get: { self.hideAll }, set: { value in
            self.coordinator.setHideAll(value)
            self.hideAll = value
        })
    }

    /// 修改当前配置方案。
    func updateProfile(_ body: (inout Profile) -> Void) {
        coordinator.config.updateActiveProfile(body)
    }

    // MARK: - 角色

    /// 在线的角色名。
    var onlineCharacters: Set<String> {
        Set(clients.compactMap(\.characterName))
    }

    /// 在线的登录与未知客户端。
    var loginClients: [EVEClient] {
        clients.filter { $0.characterName == nil }
    }

    /// 全部已知角色：在线的，加上当前配置方案里出现过的，按名称排序。
    var characterNames: [String] {
        let p = profile
        var names = onlineCharacters
        names.formUnion(p.layouts.keys)
        names.formUnion(p.hiddenCharacters)
        names.formUnion(p.highlightColors.keys)
        names.formUnion(p.characterHotkeys.keys)
        names.formUnion(p.cycleGroups.flatMap(\.members))
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 某个角色的「显示缩略图」开关（与隐藏名单相反）。
    func showsThumbnail(_ name: String) -> Binding<Bool> {
        Binding(get: { !self.profile.hiddenCharacters.contains(name) }, set: { shown in
            self.updateProfile { profile in
                profile.hiddenCharacters.removeAll { $0 == name }
                if !shown { profile.hiddenCharacters.append(name) }
            }
        })
    }

    /// 某个角色的高亮颜色；nil 表示用全局高亮颜色。
    func highlightColor(_ name: String) -> Binding<String?> {
        Binding(get: { self.profile.highlightColors[name] },
                set: { hex in self.updateProfile { $0.highlightColors[name] = hex } })
    }

    /// 「统一全部缩略图尺寸」：清掉各角色的尺寸记录，位置保留。
    func unifyThumbnailSizes() {
        updateProfile { profile in
            for name in profile.layouts.keys {
                profile.layouts[name]?.width = nil
                profile.layouts[name]?.height = nil
            }
        }
    }
}
