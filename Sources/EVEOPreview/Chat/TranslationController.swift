// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译功能的控制器（docs/design-intel-translate.md 7.6 节、7.7 节、7.10 节）：持有翻译队列、译文缓存、
// 内存里的 Key 与一个发送任务，产出翻译浮窗的内容。由 ChatFeatureController 通过 ChatFeedConsumer 调用。
// WP-0 的骨架：不翻译，内容只有标题，status 总是 off。规则、钥匙串、缓存与设置界面用的方法归 WP-C。
// 初始化方法 init(services:) 由 ChatFeatureController 调用，签名在 WP-0 冻结；status 被问题报告读取。

import EVEOPreviewCore
import EVEOPreviewPlatform

/// 翻译功能的控制器。全部方法在主线程调用。
@MainActor final class TranslationController: ChatFeedConsumer {
    /// 对应翻译浮窗。
    let kind: OverlayKind = .translation
    /// 内容或状态变了时调用。
    var onChange: (@MainActor () -> Void)?
    /// 翻译队列的状态，问题报告与「翻译」页读它。骨架总是 off。
    private(set) var status: TranslationStatus = .off
    /// 平台服务：模型传输、钥匙串与译文缓存。
    private let services: PlatformServices
    /// 最近一次的上下文。
    private var context: ChatFeedContext?

    /// 用平台服务建控制器。
    init(services: PlatformServices) {
        self.services = services
    }

    /// 记下新的上下文。
    func update(context: ChatFeedContext) {
        self.context = context
    }

    /// 骨架：不处理事件。
    func ingest(_ events: [ChatLogEvent]) {}

    /// 骨架：只有标题，没有状态行与消息。
    func content(now: Double) -> OverlayContent {
        let character = context?.activeCharacter
        let title = character.map { "\(L10n.settings.pageTranslation) · \($0)" } ?? L10n.settings.pageTranslation
        return OverlayContent(contextKey: "translation:" + (character ?? ""), title: title, status: nil, lines: [])
    }

    /// 翻译不按时间刷新（9.2 节）。
    func nextRefresh(now: Double) -> Double? { nil }

    /// 骨架：没有缓冲。
    func clear(character: String?) {}

    /// 骨架：没有要停的任务。
    func stop() {}
}
