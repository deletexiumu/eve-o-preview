// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警功能的控制器（docs/design-intel-translate.md 6.8 节）：持有位置记录、预警缓冲与跳数表的缓存，
// 产出预警浮窗的内容。由 ChatFeatureController 通过 ChatFeedConsumer 调用，全部方法在主线程。
// 6.9 节、6.10 节增补：经 ESI 核对人名。排队、发送与缓存写在 IntelFeedController+PilotLookup.swift，
// 要用的存储属性（缓存、队列、发送任务）放在本文件里，不设为 private。
//
// - update(context:)：每次配置、语言、活动角色、聊天日志状态或星图数据变化都会调用，应便宜且可重复调用。
//   各种触发都与上一次的上下文比较得出：星图数据第一次到达时重新解析缓冲并补上早到的位置线索；
//   参考星系按 6.2 节换成 ID；人名核对的开关、活动角色变化时补排要查的名字。不在这里调 onChange（调用方会刷新）。
// - ingest(_:)：位置线索交给 LocationTracker（星图数据还没到时先存起来，至多 200 条）；消息解析后进缓冲。
// - content(now:)：取活动角色的消息逐条生成一行；跳数表按「出发星系、maxJumps、SDE 版本」缓存。
// - clear(character:)：只清缓冲，不动位置记录与人名缓存（请求变了时调用方对全部角色调一次）。
// 系统日志里不写角色名、说话人、正文与人名。

import Foundation
import EVEOPreviewCore

/// 预警功能的控制器。全部方法在主线程调用。
@MainActor final class IntelFeedController: ChatFeedConsumer {
    /// 星图数据到达之前至多存几条位置线索。
    static let maxPendingHints = 200

    /// 对应预警浮窗。
    let kind: OverlayKind = .intel
    /// 内容或状态变了时调用。
    var onChange: (@MainActor () -> Void)?
    /// `state.json` 的持有者：手动位置存在 `chat.manualLocations`。
    private let state: StateController
    /// 向 ESI 核对人名的服务（6.10 节）。不设为 private，扩展文件要用。
    let resolver: any PilotNameResolver
    /// 人名缓存文件的存储（6.10 节）。不设为 private，扩展文件要用。
    let cacheStore: any PilotNameCacheStore
    /// 最近一次的上下文。扩展文件要读，所以只把写设为 private。
    private(set) var context: ChatFeedContext?

    /// 各角色的位置。
    private var tracker: LocationTracker
    /// 预警缓冲。
    private(set) var feed = IntelFeed()
    /// 星图数据到达之前收到的位置线索。
    private var pendingHints: [LocationHint] = []
    /// 缓冲里的消息是用哪个 SDE 版本的星图数据解析的；nil 表示还没有星图数据。
    private var parsedBuild: Int?
    /// 跳数表的缓存。
    private var jumpCache: (origin: Int, maxJumps: Int, build: Int, table: [Int: Int])?
    /// `stop()` 已调用。
    private(set) var isStopped = false
    let log = AppLog.logger("Intel")

    // MARK: 人名核对的状态（IntelFeedController+PilotLookup.swift 使用）

    /// 人名缓存；文件读完之前是空的。
    var pilotCache = PilotNameCache(now: 0)
    /// 待查与在途的名字。
    var lookupQueue = PilotLookupQueue()
    /// 发送任务；没有待查的名字时结束，下次排进名字时再起。
    var sendTask: Task<Void, Never>?
    /// 发送任务的代号：开关关掉或停止时加 1，旧任务的结果到达后直接丢掉。
    var lookupGeneration = 0
    /// 人名缓存文件的读取进度。
    var cacheLoadState = PilotCacheLoadState.notLoaded
    /// 「清空人名缓存」的次数：文件还没读完时清空，读完的结果不再用。
    var cacheClearCount = 0
    /// 上次存盘的时刻（墙上时钟）。
    var lastCacheSave = 0.0
    /// 最近一次后台写缓存文件的任务；下一次写入等它完成，旧的快照不会盖掉新的。
    var cacheWriteTask: Task<Void, Never>?
    /// 上一次 update 时人名核对是否开着。
    var lookupWasEnabled = false

    /// 用状态的持有者、核对服务与人名缓存的存储建控制器。手动位置从 state.json 恢复。
    init(state: StateController, resolver: any PilotNameResolver, cacheStore: any PilotNameCacheStore) {
        self.state = state
        self.resolver = resolver
        self.cacheStore = cacheStore
        tracker = LocationTracker(manual: state.state.chat.manualLocations)
    }

    /// 墙上时钟的秒数。
    var wallClock: Double { Date().timeIntervalSince1970 }

    // MARK: - ChatFeedConsumer

    /// 记下新的上下文，并按与上一次的差别处理星图数据、参考星系与人名核对。
    func update(context: ChatFeedContext) {
        guard !isStopped else { return }
        let previous = self.context
        self.context = context
        var dataArrived = false
        if let data = context.staticData, data.sdeBuild != parsedBuild {
            parsedBuild = data.sdeBuild
            dataArrived = true
            feed.reparse { IntelParser.parse($0.text, data: data) }
            jumpCache = nil
            replayPendingHints(data)
        }
        let reference = context.profile.intel.referenceSystem
        tracker.referenceSystemID = reference.flatMap { context.staticData?.system(named: $0)?.id }
        updatePilotLookup(previous: previous, dataArrived: dataArrived)
    }

    /// 位置线索交给位置记录；消息解析后进缓冲，活动角色的新情报排进人名核对。有变化时调 onChange。
    func ingest(_ events: [ChatLogEvent]) {
        guard !isStopped else { return }
        let data = context?.staticData
        var changed = false
        var activeBackfill = false
        for event in events {
            switch event {
            case .locationHint(let hint):
                if let data {
                    if apply(hint, data: data) { changed = true }
                } else {
                    pendingHints.append(hint)
                    if pendingHints.count > Self.maxPendingHints {
                        pendingHints.removeFirst(pendingHints.count - Self.maxPendingHints)
                    }
                }
            case .message(let message):
                let report = data.map { IntelParser.parse(message.text, data: $0) } ?? IntelReport.plain(message.text)
                feed.append(message, report: report)
                changed = true
                guard isActiveListener(message.listener) else { continue }
                if message.isBackfill {
                    activeBackfill = true
                } else {
                    enqueueLookups(for: report)
                }
            }
        }
        if activeBackfill { enqueueBackfillLookups() }
        if changed { onChange?() }
    }

    /// 浮窗的内容：活动角色的各条消息，标题与状态行。
    func content(now: Double) -> OverlayContent {
        let settings = context?.profile.intel ?? IntelSettings()
        feed.prune(olderThan: now - Double(settings.windowMinutes) * 60)
        let active = context?.activeCharacter
        let title = active.map { L10n.intel.overlayTitle($0) } ?? L10n.settings.pageIntel
        let items = active.map { feed.items(for: $0) } ?? []
        let formatter = IntelLineFormatter()
        let lines: [OverlayLine]
        if let data = context?.staticData {
            let origin = tracker.origin(for: active)
            let presentation = IntelPresentationContext(
                origin: origin, distances: distances(from: origin, maxJumps: settings.maxJumps, data: data),
                settings: settings, language: L10n.language, now: now, pilots: pilotDirectory)
            lines = items.map { IntelPresenter.line($0, context: presentation, data: data, formatter: formatter) }
        } else {
            lines = items.map { IntelPresenter.plainLine($0, now: now, formatter: formatter) }
        }
        return OverlayContent(contextKey: "intel:" + (active ?? ""), title: title,
                              status: statusLine(now: now, formatter: formatter), lines: lines)
    }

    /// 下一次按时间刷新：消息的年龄文字与过期清理；状态行显示位置的「多久以前」时至少每分钟一次。
    func nextRefresh(now: Double) -> Double? {
        guard let active = context?.activeCharacter else { return nil }
        let next = IntelPresenter.nextRefresh(items: feed.items(for: active), now: now)
        if context?.staticData != nil, case .character = tracker.origin(for: active) {
            return min(next ?? .infinity, now + 60)
        }
        return next
    }

    /// 清空某个角色的缓冲；character 为 nil 时清空全部。位置记录与人名缓存不动。
    func clear(character: String?) {
        if let character {
            feed.removeItems(for: character)
        } else {
            feed.removeAll()
        }
    }

    /// 停止：取消发送任务，人名缓存有改动时存盘。
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stopPilotLookup()
    }

    // MARK: - 设置界面用

    /// 各角色的位置。
    var locations: [String: CharacterLocation] { tracker.locations }

    /// 星图数据的 SDE 版本；没有星图数据时为 nil。
    var staticDataBuild: Int? { context?.staticData?.sdeBuild }

    /// 手动设置某个角色的位置。星系名查不到（或没有星图数据）时返回假；找到时写入并保存到 state.json。
    @discardableResult
    func setManualLocation(character: String, systemName: String) -> Bool {
        guard let data = context?.staticData, let system = data.system(named: systemName) else { return false }
        if tracker.setManual(character: character, systemID: system.id, now: wallClock) {
            saveManualLocations()
            onChange?()
        }
        return true
    }

    /// 清除某个角色的位置记录（任何来源），并更新 state.json。
    func clearManualLocation(character: String) {
        guard tracker.setManual(character: character, systemID: nil, now: wallClock) else { return }
        saveManualLocations()
        onChange?()
    }

    // MARK: - 内部

    /// 收听者是不是活动角色（先原样比较，再不区分大小写比较）。
    func isActiveListener(_ listener: String) -> Bool {
        guard let active = context?.activeCharacter else { return false }
        return CharacterNameMatch.match(active, in: [listener]) != nil
    }

    /// 应用一条位置线索；手动位置被覆盖时更新 state.json。返回位置是否变了。
    private func apply(_ hint: LocationHint, data: EVEStaticData) -> Bool {
        let manualBefore = tracker.manualLocations
        let changed = tracker.apply(hint, data: data)
        if tracker.manualLocations != manualBefore { saveManualLocations() }
        return changed
    }

    /// 星图数据到达后，补上之前存起来的位置线索。
    private func replayPendingHints(_ data: EVEStaticData) {
        guard !pendingHints.isEmpty else { return }
        let hints = pendingHints
        pendingHints.removeAll()
        for hint in hints { _ = apply(hint, data: data) }
    }

    /// 把手动位置写进 state.json。
    private func saveManualLocations() {
        let manual = tracker.manualLocations
        state.update { $0.chat.manualLocations = manual }
    }

    /// 从出发点算出的跳数表；出发点未知时为 nil。按出发星系、maxJumps 与 SDE 版本缓存。
    private func distances(from origin: LocationOrigin, maxJumps: Int, data: EVEStaticData) -> [Int: Int]? {
        guard let originID = origin.systemID else { return nil }
        if let cached = jumpCache, cached.origin == originID, cached.maxJumps == maxJumps,
           cached.build == data.sdeBuild {
            return cached.table
        }
        let table = JumpGraph.distances(from: originID, maxJumps: maxJumps, in: data)
        jumpCache = (originID, maxJumps, data.sdeBuild, table)
        return table
    }

    /// 浮窗的状态行，按 6.8 节的表取第一个成立的。
    private func statusLine(now: Double, formatter: IntelLineFormatter) -> OverlayStatus? {
        guard let context else { return nil }
        switch context.chatLogStatus {
        case .accessDenied(let path):
            return OverlayStatus(L10n.settings.chatLogStatusAccessDenied(path), .error)
        case .directoryNotFound(let path):
            return OverlayStatus(L10n.settings.chatLogStatusDirectoryNotFound(path), .error)
        case .stopped, .watching:
            break
        }
        let strings = L10n.intel
        guard let data = context.staticData else { return OverlayStatus(strings.statusNoStaticData, .warning) }
        if context.profile.intel.channels.isEmpty { return OverlayStatus(strings.statusNoChannels, .info) }
        let language = L10n.language
        switch tracker.origin(for: context.activeCharacter) {
        case .unknown:
            return OverlayStatus(strings.statusLocationUnknown, .warning)
        case .reference(let systemID):
            let name = data.system(id: systemID)?.name(in: language) ?? String(systemID)
            return OverlayStatus(strings.statusUsingReference(name), .info)
        case .character(let location):
            let name = data.system(id: location.systemID)?.name(in: language) ?? String(location.systemID)
            let age = formatter.age(seconds: Self.wholeSeconds(now - location.time))
            return OverlayStatus(strings.statusLocation(system: name, source: Self.sourceText(location.source),
                                                        age: age), .info)
        }
    }

    /// 位置来源的文字。
    static func sourceText(_ source: LocationSource) -> String {
        switch source {
        case .gameLog: L10n.intel.sourceGameLog
        case .localChannel: L10n.intel.sourceLocal
        case .manual: L10n.intel.sourceManual
        }
    }

    /// 秒数取整，负数与非有限值记 0。
    static func wholeSeconds(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value, 1e9))
    }
}
