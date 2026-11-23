// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗的格式器（docs/macos/design-intel-translate.md 7.10 节）：用 L10n.translation 实现 Core 的
// TranslationLineFormatting。时间是日志里的 EVE 时间（UTC）HH:mm，与游戏聊天窗口显示的一致。
// 两个状态词在建格式器时按当前界面语言取一次；控制器每次产出内容时新建一个，切换语言后自然换成新语言。

import Foundation
import EVEOPreviewCore

/// 翻译浮窗的格式器。
struct TranslationLineFormatter: TranslationLineFormatting {
    /// 「翻译中…」。
    let pending: String
    /// 「未翻译」。
    let failed: String

    /// 按当前界面语言建格式器。
    init(strings: any TranslationStrings = L10n.translation) {
        pending = strings.pending
        failed = strings.failed
    }

    /// EVE 时间（UTC）的 HH:mm。只用整数运算，不依赖时区与 DateFormatter。
    func time(_ utc: Double) -> String {
        guard utc.isFinite, abs(utc) < 1e15 else { return "--:--" }
        let seconds = Int(utc.rounded(.down))
        let ofDay = ((seconds % 86_400) + 86_400) % 86_400
        return String(format: "%02d:%02d", ofDay / 3_600, (ofDay % 3_600) / 60)
    }
}
