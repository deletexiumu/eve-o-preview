// SPDX-License-Identifier: GPL-3.0-or-later
//
// 用 L10n.intel 实现 Core 的 IntelLineFormatting（docs/macos/design-intel-translate.md 6.7 节）：预警浮窗每一行里的
// 时间、跳数、数量与用语。每次调用时取当前界面语言的文字，切换语言后下一次刷新即是新语言。
// 状态行的「多久以前」也用它的 age(seconds:)。

import EVEOPreviewCore

/// 预警行的界面文字。
struct IntelLineFormatter: IntelLineFormatting {
    /// 多久以前：不足 60 秒写秒数，其余写分钟数（向下取整）。
    func age(seconds: Int) -> String {
        let strings = L10n.intel
        return seconds < 60 ? strings.ageSeconds(max(0, seconds)) : strings.ageMinutes(seconds / 60)
    }

    /// 跳数：0 跳写「本星系」，超过上限、没有星门与出发点未知各有写法。
    func jumps(_ distance: JumpDistance) -> String {
        let strings = L10n.intel
        switch distance {
        case .jumps(0): return strings.jumpsHere
        case .jumps(let count): return strings.jumps(count)
        case .beyond(let limit): return strings.jumpsBeyond(limit)
        case .unreachable: return strings.jumpsUnreachable
        case .unknownOrigin: return strings.jumpsUnknown
        }
    }

    /// 数量：写明的是「×N」，推断的是「约 ×N」。
    func count(_ value: Int, isExplicit: Bool) -> String {
        isExplicit ? L10n.intel.count(value) : L10n.intel.countInferred(value)
    }

    /// 「安全」。
    var clear: String { L10n.intel.clear }

    /// 「未见」。
    var noVisual: String { L10n.intel.noVisual }
}
