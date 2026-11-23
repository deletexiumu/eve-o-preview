// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一个动作的热键列表（反馈文档 6.8 节，从 HotkeyRecorderView.swift 拆出）。
// 每一行：问题提示、录制按钮、作用范围菜单（图标加范围名称）、删除按钮；末尾一个「添加」按钮。
// 行的读写用 HotkeySpec：显示时用热键的界面写法，保存时用规范写法（带作用范围后缀）。
// 新录制的鼠标热键写成 `@game`，重新录制保留原来的作用范围，规则在 SettingsViewModel.recordedHotkeyText。
// 回调都在提交的时刻重新读列表，按这一行的文字找位置（SettingsViewModel.editHotkey），
// 不用视图建立时记下的列表与位置：录制期间删掉别的行，旧列表会把删掉的行写回来。

import SwiftUI
import EVEOPreviewCore

/// 一个动作的热键列表。
struct HotkeyListEditor: View {
    /// 视图模型。
    let model: SettingsViewModel
    /// 热键在配置里的位置。
    let slot: HotkeySlot
    /// 每一行是否显示作用范围菜单。「客户端」页用一个统一的范围选择代替逐行的菜单，传 false。
    var showsScopeMenu = true
    /// 新添加的一行写成的作用范围；nil 时按 `SettingsViewModel.recordedHotkeyText` 的规则
    /// （键盘不写后缀、鼠标写 `@game`）。「客户端」页传它统一的范围，新录的一行与其余各行一致。
    var newHotkeyScope: HotkeyScope?

    var body: some View {
        let list = model.hotkeys(for: slot)
        VStack(alignment: .trailing, spacing: 4) {
            // 按文字标识每一行：删掉上面的行时，正在录制的那一行身份不变，录制状态（@State）留在原行上，
            // 不会挪到相邻的行。手改配置可能出现重复文字，所以标识里再带上它是第几次出现。
            ForEach(Self.rowIDs(list), id: \.id) { entry in
                row(text: entry.text)
            }
            HotkeyRecorderView(model: model, text: nil) { outcome in
                // 「添加」只接受录到的组合；同一列表里已有这个热键时不再追加（不论作用范围）。
                // 追加到提交时刻的列表上。
                let current = model.hotkeys(for: slot)
                if case .recorded(let hotkey) = outcome, !model.hotkeyList(current, contains: hotkey) {
                    // 指定了统一的作用范围时直接写成这个范围，否则按默认规则。
                    let text = newHotkeyScope.map { HotkeySpec(hotkey: hotkey, scope: $0).stringValue() }
                        ?? model.recordedHotkeyText(hotkey, replacing: nil)
                    model.setHotkeys(current + [text], for: slot)
                }
            }
        }
    }

    /// 每一行的标识与文字。标识是文字加上它在列表里第几次出现，同一列表里不重复。
    private static func rowIDs(_ list: [String]) -> [(id: String, text: String)] {
        var seen: [String: Int] = [:]
        return list.map { text in
            let occurrence = seen[text, default: 0]
            seen[text] = occurrence + 1
            return (id: "\(occurrence)|\(text)", text: text)
        }
    }

    /// 已有的一条热键：问题提示、录制按钮（重录即替换）、作用范围菜单、删除按钮。
    private func row(text: String) -> some View {
        HStack(spacing: 6) {
            if let problem = model.hotkeyProblem(text, slot: slot) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HotkeyRecorderView(model: model, text: text) { outcome in
                switch outcome {
                case .recorded(let hotkey):
                    // 重录保留原来的后缀；原来没有后缀而页面指定了统一范围时写成那个范围，
                    // 不让鼠标按键的 `@game` 规则悄悄改掉页面上选的范围。
                    let oldScope = HotkeySpec(string: text)?.scope
                    let replacement = newHotkeyScope.map { HotkeySpec(hotkey: hotkey, scope: oldScope ?? $0).stringValue() }
                        ?? model.recordedHotkeyText(hotkey, replacing: text)
                    model.editHotkey(text, in: slot) { list, index in list[index] = replacement }
                case .cleared:
                    model.editHotkey(text, in: slot) { list, index in list.remove(at: index) }
                case .cancelled:
                    return
                }
            }
            // 解析不了的一条没有作用范围可改，只能重录或删除；关掉逐行菜单时由页面统一选择范围。
            if showsScopeMenu, let spec = HotkeySpec(string: text) {
                HotkeyScopeMenu(model: model, spec: spec) { scope in
                    model.setHotkeyScope(scope, of: text, for: slot)
                }
            }
            Button {
                model.editHotkey(text, in: slot) { list, index in list.remove(at: index) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.hotkeys.removeHotkey)
        }
    }
}

/// 一条热键的作用范围菜单：「跟随默认（当前：…）」「全局」「仅游戏内」，当前选项打勾。
/// 菜单按钮同时显示图标与范围名称（全局是地球，仅游戏内是手柄），不用点开就能看出这一条实际的范围；
/// 早先只有图标，用户认不出手柄图标代表什么。
private struct HotkeyScopeMenu: View {
    /// 视图模型，用来取默认作用范围与名称。
    let model: SettingsViewModel
    /// 这一条的解析结果。
    let spec: HotkeySpec
    /// 选了某一项时调用；nil 表示跟随默认。
    let onSelect: (HotkeyScope?) -> Void

    var body: some View {
        let defaultScope = model.profile.hotkeyDefaultScope
        let resolved = spec.resolvedScope(profileDefault: defaultScope)
        Menu {
            Picker(selection: Binding(get: { spec.scope }, set: { onSelect($0) })) {
                Text(L10n.hotkeys.scopeFollowDefault(model.scopeName(defaultScope))).tag(HotkeyScope?.none)
                Text(L10n.hotkeys.scopeGlobal).tag(HotkeyScope?.some(.global))
                Text(L10n.hotkeys.scopeGame).tag(HotkeyScope?.some(.game))
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.scopeName(resolved), systemImage: resolved == .game ? "gamecontroller" : "globe")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        // 显示下拉箭头，表明这是可以点开修改的菜单，不只是一个标记。
        .menuIndicator(.visible)
        .fixedSize()
        .help(L10n.hotkeys.scopeMenuHelp(model.scopeName(resolved)))
    }
}
