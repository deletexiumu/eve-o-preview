// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「客户端」页（架构文档 7.4 节）：在线客户端与配置里出现过的角色。
// 每个角色一行：在线状态、角色名、高亮颜色、显示缩略图开关，各列在不同长度的角色名之间对齐。
// 顶部是「全部隐藏」开关、它的快捷键（键盘组合或修饰键加鼠标按键）与快捷键的生效范围。
// 登录界面的客户端没有角色名，不能按角色设置，只列出来供核对。

import SwiftUI
import EVEOPreviewCore

/// 「客户端」页。
struct ClientsPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            hideAllSection
            charactersSection
            if !model.loginClients.isEmpty {
                loginSection
            }
        }
        .formStyle(.grouped)
    }

    /// 「全部隐藏」开关、快捷键与生效范围。
    ///
    /// 开关是会话状态，不写进配置，重启后恢复显示；快捷键与「切换与热键」页的同一项是同一份配置。
    private var hideAllSection: some View {
        let slot = HotkeySlot.toggleHideAll
        let list = model.hotkeys(for: slot)
        // 全部快捷键的范围一致时取它；还没有快捷键时按全局显示（新录的一条也写成全局）；不一致时不选中任何一项。
        let common = model.commonHotkeyScope(for: slot) ?? (list.isEmpty ? .global : nil)
        return Section {
            Toggle(L10n.settings.hideAllThumbnails, isOn: model.hideAllBinding)
            LabeledContent(L10n.settings.hideAllHotkeyLabel) {
                // 逐行的范围菜单关掉，由下面的分段选择统一设置；新录的一条跟随当前范围，默认全局。
                HotkeyListEditor(model: model, slot: slot, showsScopeMenu: false, newHotkeyScope: common ?? .global)
            }
            Picker(L10n.settings.hideAllScopeLabel, selection: Binding<HotkeyScope?>(
                get: { common },
                set: { scope in if let scope { model.setScopeOfAllHotkeys(scope, for: slot) } })) {
                Text(L10n.hotkeys.scopeGlobal).tag(HotkeyScope?.some(.global))
                Text(L10n.hotkeys.scopeGame).tag(HotkeyScope?.some(.game))
            }
            .pickerStyle(.segmented)
            // 没有快捷键时没有可改的范围。
            .disabled(list.isEmpty)
        } header: {
            PageHeader(title: L10n.settings.pageClients, subtitle: L10n.settings.clientsSubtitle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.settings.hideAllHotkeyFooter)
                // 有鼠标快捷键时提醒权限与吞掉按键（与「切换与热键」页的说明相同）。
                if list.contains(where: { HotkeySpec(string: $0)?.hotkey.isMouse == true }) {
                    Text(L10n.hotkeys.mouseHotkeyHint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// 角色列表；没有任何角色时显示一行说明。
    private var charactersSection: some View {
        Section {
            let names = model.characterNames
            if names.isEmpty {
                Text(L10n.settings.noCharacters).foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in
                    CharacterRow(model: model, name: name, isOnline: model.onlineCharacters.contains(name))
                }
            }
        } header: {
            Text(L10n.settings.charactersHeader)
        } footer: {
            Text(L10n.settings.charactersFooter).foregroundStyle(.secondary)
        }
    }

    /// 在线的登录与未知客户端。
    private var loginSection: some View {
        Section(L10n.settings.loginClientsHeader) {
            // 显示名是 `EVE` 或 `EVE (<pid>)`，与缩略图标题一致。
            ForEach(model.loginClients) { client in
                Label(TitleParser.title(for: client.identity, pid: client.pid), systemImage: "person.crop.circle.badge.questionmark")
            }
        }
    }
}

/// 一个角色的行。
///
/// 列从左到右：在线状态、角色名、高亮颜色、「显示缩略图」文字与开关。角色名占满剩余宽度，
/// 其余各列宽度固定并靠右，所以不论角色名多长，各行的颜色块、「默认」与开关都上下对齐。
private struct CharacterRow: View {
    /// 颜色列的宽度：放得下颜色块加「默认」或「重置」按钮（各语言里最长的是俄语的「Сбросить」）。
    static let colorColumnWidth: CGFloat = 140

    /// 视图模型。
    let model: SettingsViewModel
    /// 角色名（区分大小写，与配置里的键一致）。
    let name: String
    /// 角色当前是否有客户端在线。
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 在线状态：绿点在线，灰点离线。
            Circle()
                .fill(isOnline ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .help(isOnline ? L10n.settings.online : L10n.settings.offline)
            // 角色名占满剩余宽度，把后面的各列推到右侧；过长时截掉中间，悬停显示全名。
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(name)
            // 按角色的高亮颜色；为空时用「预览与布局」页的全局颜色。固定列宽，颜色块在各行同一位置。
            OptionalHexColorPicker(hex: model.highlightColor(name), fallback: model.profile.overlay.highlightColor)
                .frame(width: Self.colorColumnWidth, alignment: .leading)
                .help(L10n.settings.highlightColorHelp)
            // 文字与开关分开放：带标签的开关在分组表单里会把文字与开关拉开到两端，各行的文字位置就不一致了。
            Text(L10n.settings.showThumbnail)
                .lineLimit(1)
                .fixedSize()
            // 关掉即加入隐藏名单（持久化），与会话内的「全部隐藏」不同。
            Toggle(L10n.settings.showThumbnail, isOn: model.showsThumbnail(name))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
