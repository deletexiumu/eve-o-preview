// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页与「翻译」页共用的频道列表（docs/design-intel-translate.md 第 10 节）。放在页的 Form 里，自成一组：
// - 已选频道的列表，每行有名称与「移除」按钮；内置频道显示本地化的名字（本地、军团、联盟、舰队）。
// - 「从日志添加」菜单：列出 discovered 里还没选的频道（名称与「N 个角色」）；includesBuiltIns 为真时另列
//   4 个内置频道；末尾是「刷新」。日志里种类是本地、军团、联盟、舰队的频道不在发现列表里出现：
//   这 4 种按 ID 匹配（5.3 节），用内置频道的项添加。
// - 「按名称添加」输入框：回车时加一项只有名字的频道（游戏里看到的名字，大小写不同的视为同一个）。
// - 已有 16 项（IntelSettings.maxChannels）时两个入口置灰。
// - 页第一次出现时调一次 onRefresh，让视图模型重新列出日志里的频道。
// 文字取自 L10n.overlay。

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

    /// 「按名称添加」输入框的草稿。
    @State private var draft = ""
    /// 这个编辑器出现后是否已经刷新过一次。
    @State private var didRefresh = false

    /// 用绑定、发现的频道、是否列出内置频道与刷新动作建编辑器。
    init(channels: Binding<[ChannelRef]>, discovered: [DiscoveredChannel],
         includesBuiltIns: Bool, onRefresh: @escaping () -> Void) {
        _channels = channels
        self.discovered = discovered
        self.includesBuiltIns = includesBuiltIns
        self.onRefresh = onRefresh
    }

    var body: some View {
        let strings = L10n.overlay
        let isFull = channels.count >= IntelSettings.maxChannels
        Section {
            if channels.isEmpty {
                Text(strings.noChannels).foregroundStyle(.secondary)
            }
            ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                LabeledContent(displayName(channel, strings: strings)) {
                    Button(strings.removeChannel) { remove(at: index) }
                        .controlSize(.small)
                }
            }
            HStack {
                Menu(strings.addFromLogs) { addMenu(strings) }
                    .fixedSize()
                    .disabled(isFull)
                TextField(strings.addByNamePlaceholder, text: $draft)
                    .labelsHidden()
                    .onSubmit { addByName() }
                    .disabled(isFull)
            }
        } header: {
            Text(strings.channelsHeader)
        }
        .onAppear {
            guard !didRefresh else { return }
            didRefresh = true
            onRefresh()
        }
    }

    /// 「从日志添加」菜单的内容：发现的频道、内置频道、刷新。
    @ViewBuilder
    private func addMenu(_ strings: any OverlayStrings) -> some View {
        let fromLogs = discovered.filter { !ChannelListEditor.builtInKinds.contains($0.kind) }
        if fromLogs.isEmpty {
            Button(strings.noDiscoveredChannels) {}
                .disabled(true)
        }
        ForEach(fromLogs.filter { !isSelected($0.ref) }) { channel in
            Button("\(channel.name) — \(strings.channelListeners(channel.listeners))") { add(channel.ref) }
        }
        if includesBuiltIns {
            Divider()
            ForEach(ChannelRef.builtIns.filter { !isSelected($0) }, id: \.self) { channel in
                Button(displayName(channel, strings: strings)) { add(channel) }
            }
        }
        Divider()
        Button(strings.refreshChannels) { onRefresh() }
    }

    // MARK: - 规则

    /// 内置频道对应的日志种类：它们按 ID 匹配，不从发现列表里添加。
    private static let builtInKinds: Set<ChatChannelKind> = [.local, .corp, .alliance, .fleet]

    /// 列表里显示的名字：内置频道取本地化的名字，名字为空时显示 ID。
    private func displayName(_ channel: ChannelRef, strings: any OverlayStrings) -> String {
        if channel.isBuiltIn, let name = strings.builtInName(id: channel.id) { return name }
        let name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (channel.id ?? "") : name
    }

    /// 是否已选：ID 相同，或两边有一边没有 ID 而名字不区分大小写相同。
    private func isSelected(_ candidate: ChannelRef) -> Bool {
        channels.contains { existing in
            if let a = existing.id, let b = candidate.id { return a.lowercased() == b.lowercased() }
            return existing.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }

    /// 加一项；已选或已满时不加。
    private func add(_ channel: ChannelRef) {
        guard channels.count < IntelSettings.maxChannels, !isSelected(channel) else { return }
        channels.append(channel)
    }

    /// 按名称加一项只有名字的频道，然后清空草稿。
    private func addByName() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        add(ChannelRef(name: name))
        draft = ""
    }

    /// 移除一项。
    private func remove(at index: Int) {
        guard channels.indices.contains(index) else { return }
        channels.remove(at: index)
    }
}
