// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警功能的控制器（docs/design-intel-translate.md 6.8 节）：持有位置记录、预警缓冲与跳数表的缓存，
// 产出预警浮窗的内容。由 ChatFeatureController 通过 ChatFeedConsumer 调用。
// 6.9 节、6.10 节增补：经 ESI 核对人名，持有核对服务与人名缓存的存储；排队、发送与缓存归 WP-B，
// 写在 IntelFeedController+PilotLookup.swift，要用的存储属性（缓存、队列、发送任务）由 WP-B 加在本文件里。
// WP-0 的骨架：不解析消息，内容只有标题，不发核对请求。规则、手动位置与设置界面用的只读属性归 WP-B。
// 初始化方法 init(state:resolver:cacheStore:) 与只读属性 pilotLookupStatus 由 ChatFeatureController
// 与问题报告调用，签名在 WP-0 冻结。

import EVEOPreviewCore

/// 预警功能的控制器。全部方法在主线程调用。
@MainActor final class IntelFeedController: ChatFeedConsumer {
    /// 对应预警浮窗。
    let kind: OverlayKind = .intel
    /// 内容或状态变了时调用。
    var onChange: (@MainActor () -> Void)?
    /// `state.json` 的持有者：手动位置存在 `chat.manualLocations`。
    private let state: StateController
    /// 向 ESI 核对人名的服务（6.10 节）。不设为 private，WP-B 的扩展文件要用。
    let resolver: any PilotNameResolver
    /// 人名缓存文件的存储（6.10 节）。不设为 private，WP-B 的扩展文件要用。
    let cacheStore: any PilotNameCacheStore
    /// 最近一次的上下文。
    private var context: ChatFeedContext?

    /// 用状态的持有者、核对服务与人名缓存的存储建控制器。
    init(state: StateController, resolver: any PilotNameResolver, cacheStore: any PilotNameCacheStore) {
        self.state = state
        self.resolver = resolver
        self.cacheStore = cacheStore
    }

    /// 人名核对的状态，给问题报告与「预警」页（6.10 节）。预警或「联网核对人名」关着时是 `.off`。
    /// 骨架总是 `.off`。
    var pilotLookupStatus: PilotLookupStatus { .off }

    /// 记下新的上下文。
    func update(context: ChatFeedContext) {
        self.context = context
    }

    /// 骨架：不处理事件。
    func ingest(_ events: [ChatLogEvent]) {}

    /// 骨架：只有标题，没有状态行与消息。
    func content(now: Double) -> OverlayContent {
        let character = context?.activeCharacter
        let title = character.map { "\(L10n.settings.pageIntel) · \($0)" } ?? L10n.settings.pageIntel
        return OverlayContent(contextKey: "intel:" + (character ?? ""), title: title, status: nil, lines: [])
    }

    /// 骨架：不按时间刷新。
    func nextRefresh(now: Double) -> Double? { nil }

    /// 骨架：没有缓冲。
    func clear(character: String?) {}

    /// 骨架：没有要停的任务。
    func stop() {}
}
