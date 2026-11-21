// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页与「翻译」页共用的频道列表（docs/design-intel-translate.md 第 10 节）：已选频道的列表与「移除」按钮，
// 「从日志添加」菜单（列出日志里发现的频道，翻译页另列 4 个内置频道），「按名称添加」输入框，至多 16 项。
// 页第一次出现时调一次 onRefresh。
// WP-0 的骨架：只有签名，不显示任何控件。实现与文字（L10n.overlay）归 WP-A。

import SwiftUI
import EVEOPreviewCore

/// 频道列表的编辑器。
struct ChannelListEditor: View {
    /// 绑定的频道列表（intel.channels 或 translation.channels）。
    @Binding var channels: [ChannelRef]
    /// 日志里发现的频道。
    let discovered: [DiscoveredChannel]
    /// 「从日志添加」菜单里是否列出内置频道（本地、军团、联盟、舰队）。
    let includesBuiltIns: Bool
    /// 请求重新列出日志里的频道。
    let onRefresh: () -> Void

    /// 用绑定、发现的频道、是否列出内置频道与刷新动作建编辑器。
    init(channels: Binding<[ChannelRef]>, discovered: [DiscoveredChannel],
         includesBuiltIns: Bool, onRefresh: @escaping () -> Void) {
        _channels = channels
        self.discovered = discovered
        self.includesBuiltIns = includesBuiltIns
        self.onRefresh = onRefresh
    }

    var body: some View {
        EmptyView()
    }
}
