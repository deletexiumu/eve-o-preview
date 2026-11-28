// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域文字的补充：内置频道 ID 到本地化名字的对应，各语言共用。
// 协议与各语言的文字由 shared/l10n 生成（Generated/OverlayStrings.swift）。

import Foundation
import EVEOPreviewCore

extension OverlayStrings {
    /// 内置频道的显示名：按 ChannelRef 的 ID（local、corp、alliance、fleet）取本地化的名字；其他 ID 返回 nil。
    func builtInName(id: String?) -> String? {
        switch id?.lowercased() {
        case "local": return builtInLocal
        case "corp": return builtInCorp
        case "alliance": return builtInAlliance
        case "fleet": return builtInFleet
        default: return nil
        }
    }

    /// 频道在界面上显示的名字：内置频道用本地化的名字，其余用频道名，名字为空时退回 ID。
    func displayName(for channel: ChannelRef) -> String {
        if channel.isBuiltIn, let name = builtInName(id: channel.id) { return name }
        let name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (channel.id ?? "") : name
    }
}
