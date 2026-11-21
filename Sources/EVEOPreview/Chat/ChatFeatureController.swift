// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与翻译的总控（docs/design-intel-translate.md 9.2 节）：
// - 请求：当前配置方案的 intel.enabled 或 translation.enabled 为真时启动聊天日志跟踪，都为假时停止。
//   channels 是已启用功能的频道的并集；followsLocation 取 intel.enabled；backfillSeconds 取
//   「预警启用时的 windowMinutes × 60」与「翻译启用时的 600」里较大的一个。
// - 请求变了时：先清空两个功能全部角色的缓冲，再交给跟踪服务；跟踪服务重建后补读，缓冲由补读填回。
//   判断「变了」用 ChatLogRequest.requiresRestart：日志目录、频道、是否跟踪位置或已打开的功能变了才重建
//   （翻译的频道全在预警里时，打开翻译也要重建，补读填回翻译的缓冲）。只有 backfillSeconds
//   （随「保留最近」变）变了时不重建、不清空，也不调 start（跟踪服务对任何不同的请求都会重建并重新补读）：
//   预警缓冲在每次刷新时按新的 windowMinutes 修剪（IntelFeedController.content），翻译缓冲不受它影响（审查 m6）。
// - 星图数据：第一次有功能启用时读一次，结果留到应用退出。
// - 分发：消息交给「已启用、且频道列表里有一项与它匹配」的功能，两个都匹配时各给一份；位置线索只给预警。
// - 任何影响内容的变化之后，对两个功能各调一次 update(context:)。
// - 按时间的刷新：对可见的浮窗取 nextRefresh 里最早的时刻，到时对这些浮窗调 onContentChanged。
// 时钟：日志时间与「多久以前」用墙上时钟（Date）；浮窗的隐藏延迟用单调时钟，由协调器管。
// 系统日志里不写角色名、频道名、说话人与正文。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 预警与翻译的总控。全部方法在主线程调用。
@MainActor final class ChatFeatureController {
    /// 预警功能。
    let intel: IntelFeedController
    /// 翻译功能。
    let translation: TranslationController
    /// 聊天日志跟踪服务的最新状态。
    private(set) var chatLogStatus: ChatLogStatus = .stopped
    /// 星图数据；还没读、缺失或无效时为 nil。
    private(set) var staticData: EVEStaticData?
    /// 给问题报告与设置界面：`build-<版本号>`、`missing`、`invalid`、`notLoaded`。
    private(set) var staticDataState = "notLoaded"
    /// 某个浮窗的内容变了，由协调器设置。
    var onContentChanged: (@MainActor (OverlayKind) -> Void)?
    /// 状态变了（聊天日志、星图数据、翻译），设置窗口据此刷新。
    var onStatusChanged: (@MainActor () -> Void)?
    /// 每次调 onStatusChanged 前加 1。设置窗口的视图模型复制它：页面读到它就会在两个功能的状态变化时重绘，
    /// 两个功能的只读属性（位置、翻译状态、缓存条数）不是视图模型的存储属性，SwiftUI 观察不到。
    private(set) var statusRevision = 0

    /// 平台服务。
    private let services: PlatformServices
    /// 是否为演示模式（只用于日志）。
    private let isFakeMode: Bool
    /// 最近一次的完整配置；start 之前为 nil。
    private var config: AppConfig?
    /// 活动角色。
    private var activeCharacter: String?
    /// 可见的浮窗；只有它们参与按时间的刷新。
    private var visibleKinds: Set<OverlayKind> = []
    /// 最近一次交给跟踪服务的请求；nil 表示没有在跟踪。
    private var currentRequest: ChatLogRequest?
    /// 是否已开始读星图数据。
    private var staticDataRequested = false
    /// 按时间刷新的任务。
    private var refreshTask: Task<Void, Never>?
    /// `stop()` 已调用，之后的回调都直接返回。
    private var isStopped = false
    private let log = AppLog.logger("Chat")

    /// 用平台服务、状态的持有者建总控；调用 `start(config:)` 后才开始工作。
    init(services: PlatformServices, state: StateController, isFakeMode: Bool) {
        self.services = services
        self.isFakeMode = isFakeMode
        intel = IntelFeedController(state: state, resolver: services.pilotNames,
                                    cacheStore: services.pilotNameCache)
        translation = TranslationController(services: services)
    }

    /// 两个功能，按浮窗种类的顺序。
    private var consumers: [any ChatFeedConsumer] { [intel, translation] }

    /// 墙上时钟的秒数。
    private var wallClock: Double { Date().timeIntervalSince1970 }

    // MARK: - 生命周期

    /// 接上跟踪服务与两个功能的回调，按配置启动。
    func start(config: AppConfig) {
        services.chatLog.onEvents = { [weak self] events in self?.eventsArrived(events) }
        services.chatLog.onStatusChange = { [weak self] status in self?.statusChanged(status) }
        chatLogStatus = services.chatLog.status
        for consumer in consumers {
            let kind = consumer.kind
            consumer.onChange = { [weak self] in self?.consumerChanged(kind) }
        }
        apply(config)
    }

    /// 配置变化后调用。
    func configDidChange(old: AppConfig, new: AppConfig) {
        apply(new)
    }

    /// 界面语言变了：两个功能的文字都要换，内容各刷新一次。
    func languageDidChange() {
        guard !isStopped else { return }
        updateConsumers()
        notifyAllContent()
    }

    /// 活动角色变了：两个浮窗立即换成新角色的内容。
    func setActiveCharacter(_ name: String?) {
        guard !isStopped, name != activeCharacter else { return }
        activeCharacter = name
        updateConsumers()
        notifyAllContent()
    }

    /// 记下可见的浮窗，重新安排按时间的刷新。
    func setVisibleKinds(_ kinds: Set<OverlayKind>) {
        guard kinds != visibleKinds else { return }
        visibleKinds = kinds
        scheduleRefresh()
    }

    /// 某个浮窗当前的内容。
    func content(for kind: OverlayKind) -> OverlayContent {
        consumer(for: kind).content(now: wallClock)
    }

    /// 清空活动角色在某个浮窗里的缓冲（浮窗右键菜单的「清空列表」）。没有活动角色时不做任何事。
    func clear(_ kind: OverlayKind) {
        guard let activeCharacter else { return }
        consumer(for: kind).clear(character: activeCharacter)
        onContentChanged?(kind)
    }

    /// 列出日志目录里最近的频道，给设置界面的「从日志添加」用。
    func discoverChannels() async -> [DiscoveredChannel] {
        await services.chatLog.discoverChannels(logDirectory: config?.general.eveLogDirectory)
    }

    /// 停止跟踪与两个功能。应用退出时调用。
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        refreshTask?.cancel()
        refreshTask = nil
        services.chatLog.stop()
        currentRequest = nil
        for consumer in consumers { consumer.stop() }
    }

    // MARK: - 配置

    /// 按配置算出请求；请求变了时清空缓冲再交给跟踪服务。然后更新两个功能的上下文。
    private func apply(_ newConfig: AppConfig) {
        guard !isStopped else { return }
        config = newConfig
        // 先把新上下文交给两个功能，再启动跟踪：跟踪服务可能在 start 里就上报事件（如假服务的位置线索）。
        updateConsumers()
        let request = ChatFeatureController.request(for: newConfig)
        let restart = ChatLogRequest.requiresRestart(from: currentRequest, to: request)
        currentRequest = request
        if restart {
            // 先清空缓冲：跟踪服务重建后会补读最近的内容，不清空会出现重复的消息。
            // 翻译的缓存与位置记录不清（由各功能自己保管）。
            for consumer in consumers { consumer.clear(character: nil) }
            if let request {
                let seconds = Int(request.backfillSeconds)
                log.info("聊天日志跟踪：\(request.channels.count) 个频道，位置线索 \(request.followsLocation)，补读 \(seconds) 秒")
                services.chatLog.start(request)
            } else {
                services.chatLog.stop()
            }
        }
        if request != nil { loadStaticDataIfNeeded() }
        notifyAllContent()
    }

    /// 由配置算出跟踪请求；两个功能都没开时为 nil。
    static func request(for config: AppConfig) -> ChatLogRequest? {
        let profile = config.activeProfile
        let intel = profile.intel
        let translation = profile.translation
        guard intel.enabled || translation.enabled else { return nil }
        var channels: [ChannelRef] = []
        for channel in (intel.enabled ? intel.channels : []) + (translation.enabled ? translation.channels : [])
        where !channels.contains(channel) {
            channels.append(channel)
        }
        let backfill = max(intel.enabled ? Double(intel.windowMinutes) * 60 : 0, translation.enabled ? 600 : 0)
        var features: Set<OverlayKind> = []
        if intel.enabled { features.insert(.intel) }
        if translation.enabled { features.insert(.translation) }
        return ChatLogRequest(logDirectory: config.general.eveLogDirectory, channels: channels,
                              followsLocation: intel.enabled, backfillSeconds: backfill, enabledFeatures: features)
    }

    /// 第一次有功能启用时读一次星图数据，结果留到应用退出。
    private func loadStaticDataIfNeeded() {
        guard !staticDataRequested else { return }
        staticDataRequested = true
        let provider = services.staticData
        Task { [weak self] in
            let result = await provider.load()
            self?.staticDataLoaded(result)
        }
    }

    /// 星图数据读完：记下结果，更新两个功能，刷新浮窗与设置窗口。
    private func staticDataLoaded(_ result: StaticDataLoadResult) {
        guard !isStopped else { return }
        switch result {
        case .loaded(let data, let source):
            staticData = data
            staticDataState = "build-\(data.sdeBuild)"
            log.info("星图数据已读入：来源 \(source, privacy: .public)，SDE 版本 \(data.sdeBuild)")
        case .missing:
            staticDataState = "missing"
            log.notice("没有星图数据文件")
        case .invalid(let error):
            staticDataState = "invalid"
            // 只写错误的种类：unreadable 的说明来自系统，可能含主目录路径（审查 nit b）。
            log.error("星图数据无效：\(error.logName, privacy: .public)")
        }
        updateConsumers()
        notifyStatus()
        notifyAllContent()
    }

    // MARK: - 跟踪服务的回调

    /// 一批事件：按频道分给两个功能，各自保持日志里的顺序。
    private func eventsArrived(_ events: [ChatLogEvent]) {
        guard !isStopped, let profile = config?.activeProfile else { return }
        var intelEvents: [ChatLogEvent] = []
        var translationEvents: [ChatLogEvent] = []
        for event in events {
            switch event {
            case .message(let message):
                if ChatFeatureController.accepts(message, enabled: profile.intel.enabled,
                                                 channels: profile.intel.channels) {
                    intelEvents.append(event)
                }
                if ChatFeatureController.accepts(message, enabled: profile.translation.enabled,
                                                 channels: profile.translation.channels) {
                    translationEvents.append(event)
                }
            case .locationHint:
                if profile.intel.enabled { intelEvents.append(event) }
            }
        }
        if !intelEvents.isEmpty { intel.ingest(intelEvents) }
        if !translationEvents.isEmpty { translation.ingest(translationEvents) }
    }

    /// 消息是否属于某个功能：功能已启用，且频道列表里有一项与它匹配。
    static func accepts(_ message: ChatMessage, enabled: Bool, channels: [ChannelRef]) -> Bool {
        enabled && channels.contains { $0.matches(channelID: message.channelID, channelName: message.channelName) }
    }

    /// 跟踪服务的状态变了：记下，更新两个功能，刷新浮窗的状态行与设置窗口。
    private func statusChanged(_ status: ChatLogStatus) {
        guard !isStopped, status != chatLogStatus else { return }
        chatLogStatus = status
        updateConsumers()
        notifyStatus()
        notifyAllContent()
    }

    /// 某个功能的内容或状态变了：刷新它的浮窗与设置窗口，重新安排按时间的刷新。
    private func consumerChanged(_ kind: OverlayKind) {
        guard !isStopped else { return }
        onContentChanged?(kind)
        notifyStatus()
        scheduleRefresh()
    }

    // MARK: - 内部

    /// 某个种类对应的功能。
    private func consumer(for kind: OverlayKind) -> any ChatFeedConsumer {
        switch kind {
        case .intel: return intel
        case .translation: return translation
        }
    }

    /// 用当前状态对两个功能各调一次 `update(context:)`。
    private func updateConsumers() {
        guard let config else { return }
        let context = ChatFeedContext(profile: config.activeProfile, general: config.general,
                                      staticData: staticData, activeCharacter: activeCharacter,
                                      chatLogStatus: chatLogStatus)
        for consumer in consumers { consumer.update(context: context) }
    }

    /// 状态变了：版本号加 1，再通知设置窗口。
    private func notifyStatus() {
        statusRevision &+= 1
        onStatusChanged?()
    }

    /// 两个浮窗的内容都可能变了。协调器只刷新可见的浮窗。
    private func notifyAllContent() {
        for kind in OverlayKind.allCases { onContentChanged?(kind) }
        scheduleRefresh()
    }

    /// 对可见的浮窗取 nextRefresh 里最早的时刻，用一个任务睡到那时，然后刷新这些浮窗并重新安排。
    /// 没有可见的浮窗、或都不用按时间刷新时不安排。
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        guard !isStopped else { return }
        let now = wallClock
        let deadlines = visibleKinds.compactMap { consumer(for: $0).nextRefresh(now: now) }
        guard let deadline = deadlines.min() else { return }
        let delay = max(0.05, deadline - now)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            for kind in self.visibleKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                self.onContentChanged?(kind)
            }
            self.scheduleRefresh()
        }
    }
}
