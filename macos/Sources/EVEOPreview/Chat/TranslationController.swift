// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译功能的控制器（docs/design-intel-translate.md 7.6 节、7.7 节、7.8 节、7.10 节）：持有翻译队列、译文缓存、
// 内存里的 Key 与一个发送任务，产出翻译浮窗的内容。由 ChatFeatureController 通过 ChatFeedConsumer 调用；
// 「翻译」页经 SettingsViewModel+Translation.swift 调用本文件末尾的设置接口。
//
// 规则：
// - 消息进入时的阶段：系统消息不进入；不用模型的是 skipped；缓存命中按 TranslationRules.resultPhase 是 done
//   或 skipped(.sameLanguage)；活动角色的非补读消息是 pending；其余是 off。补读到活动角色的消息后调一次 activate，
//   至多 20 条交给模型。模型的结果也按 resultPhase 换成阶段（队列的 complete 带上目标语言）。
// - 目标语言变了、或星图数据第一次读到时，把缓冲里的消息按新条件重新判断；重新判断时不把旧消息直接排进队列，
//   只按 activate 的规则排最近的 20 条，不为整个缓冲重新付费。
// - 钥匙串只在 3 个时机读（7.7 节）：开关打开或预设变了（不弹窗）；用户点「保存」（写入后留在内存）；
//   用户点「测试」或「立即重试」且内存里没有值（允许弹窗）。之后只用内存里的值。
// - 一批在途时同一时刻不发第二批。设置、Key 或目标语言变了时，在途的请求变成「旧请求」：它的结果仍按发出时的
//   目标语言存进缓存，目标语言没变时也填给仍在等的消息，但不改队列的状态。
// - 译文缓存在启动后于后台读取；读完之前不存盘，读完后与内存里的条目合并。有改动时满 30 秒存一次，停止时同步存一次。
// - 活动角色在所选的每个翻译频道都没有被跟踪的日志文件时，状态行提示 EVE 没有写日志（ChatLogCoverage）。
// - 日志只写条数、状态码与失败的种类，不写 Key、请求头、接口地址、模型名、聊天内容、角色名与服务给的说明。
// 时刻用墙上时钟的秒数，与日志里的消息时间同一个时钟。
// 初始化方法 init(services:) 与只读属性 status 的签名在 WP-0 冻结。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 翻译功能的控制器。全部方法在主线程调用。
@MainActor final class TranslationController: ChatFeedConsumer {
    /// 对应翻译浮窗。
    let kind: OverlayKind = .translation
    /// 内容或状态变了时调用。
    var onChange: (@MainActor () -> Void)?
    /// 翻译的状态，问题报告与「翻译」页读它。功能关着时是 off。
    private(set) var status: TranslationStatus = .off

    /// 内存里的 Key 的状态。
    private enum KeyState: Equatable {
        /// 还没读过。
        case unknown
        /// 读到的值。
        case value(String)
        /// 钥匙串里没有。
        case missing
        /// 有，但读取要用户确认或失败了。
        case unavailable
    }

    /// 平台服务：模型传输、钥匙串与译文缓存。
    private let services: PlatformServices
    /// 最近一次的上下文。
    private var context: ChatFeedContext?
    /// 缓冲与队列。
    private var queue = TranslationQueue()
    /// 译文缓存。
    private var cache = TranslationCache()
    /// 缓存文件是否已读完；读完之前不存盘。
    private var cacheLoaded = false
    /// 读完之前用户清空了缓存：读到的条目丢掉。
    private var discardLoadedCache = false
    /// 下一次存盘的任务。
    private var cacheSaveTask: Task<Void, Never>?
    /// 上次存盘的时刻。
    private var lastCacheSave = 0.0
    /// 最近一次后台写入的任务；下一次写入等它完成。
    private var cacheWriteTask: Task<Void, Never>?
    /// Key 的状态与它属于哪个预设。
    private var key: KeyState = .unknown
    private var keyProvider: TranslationProviderID?
    /// 在途的请求；旧请求不占这个位置。
    private var sendTask: Task<Void, Never>?
    /// 请求的代次：设置、Key 或目标语言变了时加 1，之前发出的请求成为旧请求。
    private var generation = 0
    /// 按时间再试的任务（防抖与等待到期）。
    private var timerTask: Task<Void, Never>?
    /// 上一次的开关、目标语言、接口设置、活动角色与「有没有星图数据」，用于比较变化。
    private var lastEnabled = false
    private var target: AppLanguage?
    private var lastEndpoint: TranslationEndpointSettings?
    private var lastActive: String?
    private var hadStaticData = false
    /// `stop()` 已调用。
    private var isStopped = false
    private let log = AppLog.logger("Translation")

    /// 用平台服务建控制器，并在后台读译文缓存文件。
    init(services: PlatformServices) {
        self.services = services
        let store = services.translationCache
        Task { [weak self] in
            let entries = await Task.detached(priority: .utility) { store.load() }.value
            self?.cacheDidLoad(entries)
        }
    }

    /// 墙上时钟的秒数。
    private var wallClock: Double { Date().timeIntervalSince1970 }

    /// 当前配置方案的翻译设置。
    private var settings: TranslationSettings { context?.profile.translation ?? TranslationSettings() }

    /// 功能是否打开。
    private var isEnabled: Bool { !isStopped && settings.enabled }

    // MARK: - ChatFeedConsumer

    /// 配置、星图数据、活动角色、聊天日志状态或界面语言变了。每次配置变化都会调用，只做比较与少量更新。
    func update(context: ChatFeedContext) {
        guard !isStopped else { return }
        self.context = context
        let now = wallClock
        guard context.profile.translation.enabled else {
            if lastEnabled {
                lastEnabled = false
                abandonInFlight(cancel: true)
                timerTask?.cancel()
                timerTask = nil
            }
            refreshStatus()
            return
        }
        let endpoint = context.general.translationEndpoint
        let newTarget = context.profile.translation.targetLanguage.resolved(ui: L10n.language)
        let turnedOn = !lastEnabled
        lastEnabled = true
        if turnedOn || keyProvider != endpoint.provider { loadKey(for: endpoint.provider, interactive: false) }
        if turnedOn || endpoint != lastEndpoint {
            // 开关刚打开或接口设置变了：清掉暂停，旧请求的结果不再改状态。
            if lastEndpoint != nil || turnedOn { abandonInFlight(cancel: false) }
            queue.reset(now: now)
        }
        lastEndpoint = endpoint
        let gotStaticData = !hadStaticData && context.staticData != nil
        hadStaticData = context.staticData != nil
        let targetChanged = target != nil && target != newTarget
        target = newTarget
        if targetChanged || gotStaticData { reclassify(now: now) }
        if context.activeCharacter != lastActive {
            lastActive = context.activeCharacter
            queue.activate(listener: context.activeCharacter, now: now)
        }
        pump()
    }

    /// 属于翻译的事件，按日志里的先后顺序。系统消息不进入；补读到活动角色的消息后排最近的 20 条。
    func ingest(_ events: [ChatLogEvent]) {
        guard isEnabled else { return }
        let now = wallClock
        var activeBackfill = false
        for case .message(let message) in events {
            if ChatLogParser.systemSpeakers.contains(message.speaker) { continue }
            queue.append(message, phase: phase(for: message, allowPending: true), now: now)
            if message.isBackfill && isActive(message.listener) { activeBackfill = true }
        }
        if activeBackfill { queue.activate(listener: context?.activeCharacter, now: now) }
        refreshStatus()
        onChange?()
        pump()
    }

    /// 浮窗的内容：标题、状态行与活动角色的各条。
    func content(now: Double) -> OverlayContent {
        let strings = L10n.translation
        let character = context?.activeCharacter
        let title = character.map { strings.overlayTitle($0) } ?? L10n.settings.pageTranslation
        let formatter = TranslationLineFormatter(strings: strings)
        let current = settings
        let lines = character.map { name in
            queue.items(for: name).compactMap { TranslationPresenter.line($0, settings: current, formatter: formatter) }
        } ?? []
        return OverlayContent(contextKey: "translation:" + (character ?? ""), title: title,
                              status: statusLine(strings, now: now), lines: lines)
    }

    /// 翻译不按时间刷新（9.2 节）。
    func nextRefresh(now: Double) -> Double? { nil }

    /// 清空某个角色（nil 表示全部）的缓冲。缓存与暂停的原因都不变。
    func clear(character: String?) {
        queue.removeItems(listener: character)
        refreshStatus()
    }

    /// 停止：取消在途的请求与定时，同步存一次缓存。应用退出时调用。
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        abandonInFlight(cancel: true)
        timerTask?.cancel()
        timerTask = nil
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        if cacheLoaded && cache.isDirty {
            do {
                try services.translationCache.save(cache.snapshot())
            } catch {
                log.error("译文缓存存盘失败：\(String(describing: type(of: error)), privacy: .public)")
            }
        }
        status = .off
    }

    // MARK: - 判断与排队

    /// 一条消息进入时的阶段。allowPending 为假时（重新判断旧消息），没有缓存的消息一律是 off。
    private func phase(for message: ChatMessage, allowPending: Bool) -> TranslationPhase {
        let target = target ?? L10n.language
        let data = context?.staticData
        let matches = data?.matcher.matches(in: message.text) ?? []
        let report = data == nil ? IntelReport.plain(message.text) : IntelParser.parse(message.text, matches: matches)
        let line = ChatLine(time: message.time, speaker: message.speaker, text: message.text, isSystem: false)
        if let reason = TranslationRules.skipReason(for: line, report: report, target: target) {
            var rendered: String?
            if reason == .termsOnly {
                let text = TranslationRules.renderTerms(message.text, matches: matches, target: target)
                rendered = text == message.text ? nil : text
            }
            return .skipped(reason, rendered: rendered)
        }
        if let hit = cache.value(for: message.text, target: target) {
            return TranslationRules.resultPhase(hit, original: message.text, target: target)
        }
        return allowPending && !message.isBackfill && isActive(message.listener) ? .pending : .off
    }

    /// 按当前的目标语言与星图数据重新判断缓冲里的全部消息。暂停的原因保留。
    private func reclassify(now: Double) {
        let items = queue.allItems()
        let previous = queue.status
        abandonInFlight(cancel: false)
        queue.removeAll()
        for item in items { queue.append(item.message, phase: phase(for: item.message, allowPending: false), now: now) }
        queue.activate(listener: context?.activeCharacter, now: now)
        if case .blocked(let failure) = previous { queue.fail(failure, batch: [], now: now) }
    }

    /// 收听者是不是活动角色（先原样、再不区分大小写）。
    private func isActive(_ listener: String) -> Bool {
        guard let active = context?.activeCharacter else { return false }
        return CharacterNameMatch.match(listener, in: [active]) != nil
    }

    // MARK: - 发送

    /// 检查设置与 Key，能发时取一批发出；不能发时安排下一次检查。
    private func pump() {
        guard isEnabled, let context else {
            refreshStatus()
            return
        }
        timerTask?.cancel()
        timerTask = nil
        let now = wallClock
        defer { notifyIfStatusChanged() }
        // 缓存里已有的句子不论队列是否暂停、有没有在途的一批，都先填上。
        if fillPendingFromCache() { onChange?() }
        if case .blocked = queue.status { return }
        let endpoint: TranslationEndpoint
        switch TranslationProviders.resolve(context.general.translationEndpoint) {
        case .failure(let issue):
            queue.fail(.notConfigured(issue), batch: [], now: now)
            return
        case .success(let resolved):
            endpoint = resolved
        }
        var apiKey: String?
        if case .value(let value) = key, keyProvider == endpoint.provider { apiKey = value }
        if endpoint.requiresKey && apiKey == nil {
            queue.fail(key == .unavailable ? .keychainUnavailable : .missingKey, batch: [], now: now)
            return
        }
        guard sendTask == nil else { return }
        guard let batch = queue.takeBatch(now: now) else {
            scheduleTimer(now: now)
            return
        }
        send(batch, endpoint: endpoint, apiKey: apiKey)
    }

    /// 发请求之前，先用缓存填上活动角色排队中的消息，返回是否填了。
    ///
    /// 同一条消息会写进每个收听角色的文件（C11）。活动角色那一份翻译完时，其他角色的副本还是 off，
    /// 切换客户端后 activate 把它们排进队列；这里先查缓存，已翻译过的句子不再付费。
    /// 填的方式是一批「不在途」的结果：队列只改这些消息与缓存键相同的 pending 消息，不改状态。
    private func fillPendingFromCache() -> Bool {
        guard let active = context?.activeCharacter, let target else { return false }
        var hits: [UInt64: TranslatedText] = [:]
        var hitItems: [TranslationItem] = []
        for item in queue.items(for: active) where item.phase == .pending {
            guard let value = cache.value(for: item.message.text, target: target) else { continue }
            hits[item.id] = value
            hitItems.append(item)
        }
        guard !hitItems.isEmpty else { return false }
        queue.complete(hits, batch: hitItems, target: target)
        return true
    }

    /// 发出一批。结果回到主线程由 `finish` 处理。
    private func send(_ batch: [TranslationItem], endpoint: TranslationEndpoint, apiKey: String?) {
        let target = target ?? L10n.language
        let data = context?.staticData
        let pins = TranslationPrompt.mergedPins(batch.map { item in
            let matches = data?.matcher.matches(in: item.message.text) ?? []
            return TranslationPrompt.pins(text: item.message.text, matches: matches, target: target)
        })
        let content = TranslationPrompt.content(items: batch, pins: pins, target: target)
        let request = TranslationWire.request(endpoint: endpoint, apiKey: apiKey, content: content)
        let transport = services.translationTransport
        let kind = endpoint.kind
        generation += 1
        let sentGeneration = generation
        log.info("翻译：发送一批 \(batch.count) 条，钉住 \(pins.count) 个术语")
        sendTask = Task { [weak self] in
            let started = Date()
            let result = await transport.send(request)
            self?.finish(result, batch: batch, content: content, kind: kind, target: target,
                         generation: sentGeneration, started: started)
        }
    }

    /// 一批的结果：存缓存，改队列，再看能不能发下一批。
    private func finish(_ result: Result<TranslationHTTPResponse, TranslationTransportError>, batch: [TranslationItem],
                        content: TranslationPromptContent, kind: TranslationAPIKind, target: AppLanguage,
                        generation sentGeneration: Int, started: Date) {
        let isCurrent = sentGeneration == generation
        if isCurrent { sendTask = nil }
        guard !isStopped else { return }
        let now = wallClock
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        switch Self.outcome(result, content: content, kind: kind) {
        case .success(let results):
            for item in batch {
                if let value = results[item.id] { cache.store(value, for: item.message.text, target: target) }
            }
            scheduleCacheSave()
            // 目标语言变了时缓冲里已是新的条目，旧译文只进缓存，不填给它们。
            if target == self.target { queue.complete(results, batch: batch, target: target) }
            let suffix = isCurrent ? "" : "（旧请求）"
            log.info("翻译：收到 \(results.count)/\(batch.count) 条，耗时 \(milliseconds) 毫秒\(suffix, privacy: .public)")
        case .failure(let failure):
            if isCurrent { queue.fail(failure, batch: batch, now: now) }
            log.notice("翻译失败：\(Self.logName(failure), privacy: .public)，耗时 \(milliseconds) 毫秒")
        }
        refreshStatus()
        onChange?()
        pump()
    }

    /// 答复换成译文或失败。
    private static func outcome(_ result: Result<TranslationHTTPResponse, TranslationTransportError>,
                                content: TranslationPromptContent,
                                kind: TranslationAPIKind) -> Result<[UInt64: TranslatedText], TranslationFailure> {
        switch result {
        case .failure(let error):
            return .failure(TranslationWire.failure(for: error))
        case .success(let response):
            do {
                let text = try TranslationWire.answer(from: response, kind: kind)
                return .success(try TranslationWire.parse(text, ids: content.ids))
            } catch {
                return .failure(error)
            }
        }
    }

    /// 让在途的请求变成旧请求；cancel 为真时同时取消它（关掉功能或停止时）。
    private func abandonInFlight(cancel: Bool) {
        if cancel { sendTask?.cancel() }
        sendTask = nil
        generation += 1
    }

    /// 按队列给出的时刻再检查一次。
    private func scheduleTimer(now: Double) {
        guard let at = queue.nextAttempt(now: now) else { return }
        let delay = max(0.05, at - now)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timerTask = nil
            self.pump()
        }
    }

    // MARK: - 状态

    /// 按开关与队列算出状态，返回是否变了。
    @discardableResult
    private func refreshStatus() -> Bool {
        let newStatus: TranslationStatus = isEnabled ? queue.status : .off
        guard newStatus != status else { return false }
        status = newStatus
        return true
    }

    /// 状态变了时通知浮窗与设置窗口。
    private func notifyIfStatusChanged() {
        if refreshStatus() { onChange?() }
    }

    /// 浮窗的状态行：聊天日志的错误；没有翻译频道；暂停（error）；活动角色在所选频道都没有日志文件（warning）；
    /// 等待重试（warning）；其余不显示。
    private func statusLine(_ strings: any TranslationStrings, now: Double) -> OverlayStatus? {
        switch context?.chatLogStatus {
        case .directoryNotFound(let path)?:
            return OverlayStatus(L10n.settings.chatLogStatusDirectoryNotFound(path), .error)
        case .accessDenied(let path)?:
            return OverlayStatus(L10n.settings.chatLogStatusAccessDenied(path), .error)
        default:
            break
        }
        if settings.channels.isEmpty { return OverlayStatus(strings.statusNoChannels, .info) }
        if case .blocked = status { return OverlayStatus(strings.statusText(status, now: now), .error) }
        // EVE 没有为这些频道写日志时，浮窗只会是「还没有消息」，用户会以为翻译坏了（2026-11 的反馈）。
        if let names = missingLogChannelNames() {
            // 缺的里有内置频道时，多半是客户端语言不是英文（EVE Mac 版此时不写系统频道的日志），提示里给出办法。
            let builtIn = settings.channels.contains(where: \.isBuiltIn)
            let text = builtIn ? strings.statusNoLogFilesBuiltIn(names) : strings.statusNoLogFiles(names)
            return OverlayStatus(text, .warning)
        }
        if case .waiting = status { return OverlayStatus(strings.statusText(status, now: now), .warning) }
        return nil
    }

    /// 活动角色在所选的每个翻译频道都没有被跟踪的日志文件时，返回这些频道的显示名；否则为 nil。
    /// 跟踪服务还没扫描完、没有活动角色时也是 nil。
    private func missingLogChannelNames() -> [String]? {
        guard let context, let character = context.activeCharacter else { return nil }
        let channels = settings.channels
        guard ChatLogCoverage.lacksAllLogs(for: character, channels: channels,
                                           followed: context.followedChannels) else { return nil }
        let overlay = L10n.overlay
        return channels.map { channel in
            // 内置频道显示本地化的名字，与设置里的频道列表一致；名字为空时显示 ID。
            if channel.isBuiltIn, let name = overlay.builtInName(id: channel.id) { return name }
            let name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? (channel.id ?? "") : name
        }
    }

    /// 失败在日志里的名字：只有种类与状态码，没有服务给的说明与系统的网络说明之外的内容。
    private static func logName(_ failure: TranslationFailure) -> String {
        switch failure {
        case .notConfigured: return "notConfigured"
        case .missingKey: return "missingKey"
        case .keychainUnavailable: return "keychainUnavailable"
        case .unauthorized(let status): return "unauthorized(\(status))"
        case .notFound: return "notFound"
        case .insufficientBalance: return "insufficientBalance"
        case .rejected(let status, _): return "rejected(\(status))"
        case .rateLimited(let seconds): return "rateLimited(\(seconds.map { "\(Int($0))s" } ?? "no retry-after"))"
        case .server(let status): return "server(\(status))"
        case .network(let reason): return "network(\(reason))"
        case .malformedAnswer: return "malformedAnswer"
        case .refused: return "refused"
        case .truncated: return "truncated"
        }
    }

    // MARK: - 钥匙串

    /// 这个预设要不要读 Key：要 Key 的预设与自定义接口（可选）读，其余不读。
    private static func usesKey(_ provider: TranslationProviderID) -> Bool {
        provider == .custom || TranslationProviders.preset(provider).requiresKey
    }

    /// 读一次 Key，结果留在内存里。只在 7.7 节的 3 个时机调用。
    private func loadKey(for provider: TranslationProviderID, interactive: Bool) {
        keyProvider = provider
        guard Self.usesKey(provider) else {
            key = .missing
            return
        }
        switch services.secrets.read(account: TranslationProviders.keychainAccount(for: provider),
                                     allowsInteraction: interactive) {
        case .value(let value):
            key = value.isEmpty ? .missing : .value(value)
        case .missing:
            key = .missing
        case .interactionRequired:
            key = .unavailable
            log.notice("钥匙串：读取 Key 需要用户确认，本次没有弹窗")
        case .failed(let code):
            key = .unavailable
            log.notice("钥匙串：读取 Key 失败（\(code)）")
        }
    }

    // MARK: - 译文缓存

    /// 缓存文件读完：与内存里的条目合并；之后有改动时才存盘。
    private func cacheDidLoad(_ entries: [TranslationCacheEntry]) {
        guard !isStopped else { return }
        if !discardLoadedCache { cache.merge(older: entries) }
        cacheLoaded = true
        log.info("译文缓存：读入 \(entries.count) 条")
        scheduleCacheSave()
        onChange?()
    }

    /// 有改动时，距上次存盘满 30 秒存一次。
    private func scheduleCacheSave() {
        guard cacheLoaded, cache.isDirty, cacheSaveTask == nil, !isStopped else { return }
        let delay = max(0, lastCacheSave + 30 - wallClock)
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.cacheSaveTask = nil
            self.saveCacheNow()
        }
    }

    /// 在后台任务里存一次盘。各次写入排成一串：后一次等前一次写完，旧的快照不会盖掉新的。
    private func saveCacheNow() {
        guard cacheLoaded, !isStopped else { return }
        let entries = cache.snapshot()
        lastCacheSave = wallClock
        let store = services.translationCache
        let log = self.log
        let previous = cacheWriteTask
        cacheWriteTask = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try store.save(entries)
            } catch {
                log.error("译文缓存存盘失败：\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    // MARK: - 设置界面用的接口

    /// 译文缓存的条数。
    var cacheCount: Int { cache.count }

    /// 清空译文缓存并存盘（文件变成空的）。
    func clearCache() {
        cache.removeAll()
        if cacheLoaded {
            cacheSaveTask?.cancel()
            cacheSaveTask = nil
            saveCacheNow()
        } else {
            discardLoadedCache = true
        }
        log.info("译文缓存已清空")
        onChange?()
    }

    /// 某个预设的 Key 是否已在钥匙串里：读过且有值或要确认时为真，读过且没有时为假，没读过时为 nil。
    func isKeyStored(for provider: TranslationProviderID) -> Bool? {
        guard keyProvider == provider else { return nil }
        switch key {
        case .value, .unavailable: return true
        case .missing: return false
        case .unknown: return nil
        }
    }

    /// 用户点「保存」：写进钥匙串并留在内存里，清掉暂停后重试。返回钥匙串的失败。
    func saveKey(_ rawKey: String, for provider: TranslationProviderID) -> SecretStoreError? {
        let value = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        do {
            try services.secrets.write(value, account: TranslationProviders.keychainAccount(for: provider))
        } catch {
            log.notice("钥匙串：保存 Key 失败")
            return error
        }
        keyProvider = provider
        key = .value(value)
        log.info("钥匙串：已保存 Key")
        restart()
        return nil
    }

    /// 用户点「删除 Key」：从钥匙串删掉，内存里也清掉。
    func deleteKey(for provider: TranslationProviderID) -> SecretStoreError? {
        do {
            try services.secrets.delete(account: TranslationProviders.keychainAccount(for: provider))
        } catch {
            return error
        }
        keyProvider = provider
        key = .missing
        log.info("钥匙串：已删除 Key")
        restart()
        return nil
    }

    /// 用户点「立即重试」：内存里没有 Key 时允许弹窗读一次，清掉暂停，失败的消息重新排队。
    func retry() {
        guard let provider = context?.general.translationEndpoint.provider else { return }
        if Self.usesKey(provider), keyProvider != provider || !isKeyValue { loadKey(for: provider, interactive: true) }
        restart()
    }

    /// 用户点「测试」：用给出的接口设置与当前的 Key 发一次固定样例，返回译文或失败。
    /// 内存里没有这个预设的 Key 时允许弹窗读一次。测试不改队列的状态。
    func test(endpoint settings: TranslationEndpointSettings, target: AppLanguage) async
        -> Result<String, TranslationFailure> {
        let endpoint: TranslationEndpoint
        switch TranslationProviders.resolve(settings) {
        case .failure(let issue): return .failure(.notConfigured(issue))
        case .success(let resolved): endpoint = resolved
        }
        if Self.usesKey(endpoint.provider), keyProvider != endpoint.provider || !isKeyValue {
            loadKey(for: endpoint.provider, interactive: true)
            // 这次读到了 Key，而队列正因为没有 Key 暂停着：解除暂停，浮窗不必等用户再点「立即重试」。
            if isKeyValue, endpoint.provider == context?.general.translationEndpoint.provider,
               queue.status == .blocked(.missingKey) || queue.status == .blocked(.keychainUnavailable) {
                restart()
            }
            onChange?()
        }
        var apiKey: String?
        if case .value(let value) = key, keyProvider == endpoint.provider { apiKey = value }
        if endpoint.requiresKey && apiKey == nil {
            return .failure(key == .unavailable ? .keychainUnavailable : .missingKey)
        }
        let content = TranslationPrompt.testContent(target: target)
        let request = TranslationWire.request(endpoint: endpoint, apiKey: apiKey, content: content)
        let response = await services.translationTransport.send(request)
        let outcome = Self.outcome(response, content: content, kind: endpoint.kind)
        switch outcome {
        case .success(let results):
            guard let text = results.values.first?.text else { return .failure(.malformedAnswer) }
            log.info("翻译测试：成功")
            return .success(text)
        case .failure(let failure):
            log.notice("翻译测试失败：\(Self.logName(failure), privacy: .public)")
            return .failure(failure)
        }
    }

    /// 内存里是否有 Key 的值。
    private var isKeyValue: Bool {
        if case .value = key { return true }
        return false
    }

    /// Key 变了或用户要求重试：旧请求不再改状态，清掉暂停，失败的消息重新排队，然后马上检查一次。
    private func restart() {
        abandonInFlight(cancel: false)
        queue.reset(now: wallClock)
        pump()
        onChange?()
    }
}
