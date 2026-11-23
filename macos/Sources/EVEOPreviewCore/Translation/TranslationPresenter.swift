// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗的一行（docs/macos/design-intel-translate.md 7.10 节）：
// | 阶段                              | 第一行                                   | 第二行                     |
// | done                              | 时间、频道、说话人、译文（translated）    | showOriginal 时是原文（dim）|
// | skipped，rendered 有值            | 时间、频道、说话人、rendered（plain）     | showOriginal 时是原文（dim）|
// | skipped 无 rendered；off          | 时间、频道、说话人、原文（plain）         | 无                         |
// | pending、inFlight                 | 同上，后面加「翻译中…」（pending）        | 无                         |
// | failed                            | 同上，后面加「未翻译」（failed）          | 无                         |
// 频道名只在翻译频道多于一个时显示。foreignOnly 为真时，已是目标语言与空消息不显示。
// 时间与两个状态词由 App 的格式器给出（界面语言），Core 不含界面文字。

import Foundation

/// 翻译浮窗的格式器：时间与两个状态词。
public protocol TranslationLineFormatting: Sendable {
    /// EVE 时间（UTC）的 HH:mm。
    func time(_ utc: Double) -> String
    /// 「翻译中…」。
    var pending: String { get }
    /// 「未翻译」。
    var failed: String { get }
}

/// 翻译条目到浮窗行的转换。
public enum TranslationPresenter {
    /// 一条的显示；foreignOnly 隐藏的条目返回 nil。
    public static func line(_ item: TranslationItem, settings: TranslationSettings,
                            formatter: any TranslationLineFormatting) -> OverlayLine? {
        let message = item.message
        if settings.foreignOnly, case .skipped(let reason, _) = item.phase,
           reason == .sameLanguage || reason == .empty {
            return nil
        }
        var primary: [OverlaySpan] = [OverlaySpan(formatter.time(message.time), .dim), OverlaySpan(" ", .plain)]
        if settings.channels.count > 1 {
            primary.append(OverlaySpan("[\(message.channelName)]", .channel))
            primary.append(OverlaySpan(" ", .plain))
        }
        primary.append(OverlaySpan(message.speaker, .speaker))
        primary.append(OverlaySpan(": ", .dim))

        var secondary: [OverlaySpan] = []
        var translation: String?
        let original = OverlaySpan(message.text, .dim)
        switch item.phase {
        case .done(let text, _):
            primary.append(OverlaySpan(text, .translated))
            translation = text
            if settings.showOriginal { secondary = [original] }
        case .skipped(_, let rendered?):
            primary.append(OverlaySpan(rendered, .plain))
            translation = rendered
            if settings.showOriginal { secondary = [original] }
        case .skipped(_, nil), .off:
            primary.append(OverlaySpan(message.text, .plain))
        case .pending, .inFlight:
            primary.append(OverlaySpan(message.text, .plain))
            primary.append(OverlaySpan(" " + formatter.pending, .pending))
        case .failed:
            primary.append(OverlaySpan(message.text, .plain))
            primary.append(OverlaySpan(" " + formatter.failed, .failed))
        }
        var copyText = "\(message.speaker): \(message.text)"
        if let translation { copyText += "\n" + translation }
        return OverlayLine(id: item.id, primary: primary, secondary: secondary, copyText: copyText)
    }
}
