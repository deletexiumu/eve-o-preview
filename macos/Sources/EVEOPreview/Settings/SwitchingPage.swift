// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「切换与热键」页（架构文档 7.4 节）：
// - 循环组：新建、改名、删除；成员顺序（从已知角色添加、上下移动、删除）；前进与后退热键。
// - 每角色直达热键。
// - 通用热键：全部隐藏、全部最小化、登录客户端循环。
// - 页首：热键的默认作用范围（反馈文档 6.8 节），没有后缀的热键跟随它；用单选按钮，表明只能选一种。
// 每条热键旁显示它的问题（无法解析、重复、被拒绝、不能生效）与作用范围菜单，
// 问题来自协调器当前生效的热键规划与注册器的失败项。

import SwiftUI
import EVEOPreviewCore

/// 「切换与热键」页。
struct SwitchingPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                // 默认作用范围：单选按钮，写入当前配置方案的 hotkeyDefaultScope。
                // 不用分段控件：分段控件像两个可以同时打开的开关，让人以为一个热键能在两种范围里都设置。
                // 单选按钮一眼看出只能选一项，选项文字再讲清「全局」也包括游戏内。
                ScopeRadioPicker(label: L10n.hotkeys.defaultScopeLabel,
                                 selection: model.binding(\.hotkeyDefaultScope))
            } header: {
                PageHeader(title: L10n.settings.pageSwitching, subtitle: L10n.hotkeys.switchingSubtitle)
            } footer: {
                // 说明每个热键只有一种范围，以及热键旁的标记可以单独修改它。
                // 默认范围单独一组，说明紧贴在它下面，不与循环组混在一起。
                Text(L10n.hotkeys.defaultScopeFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(L10n.hotkeys.cycleGroupsHeader) {
                    Button(L10n.hotkeys.addGroup) { model.addCycleGroup() }
                }
                if model.profile.cycleGroups.isEmpty {
                    Text(L10n.hotkeys.noGroups).foregroundStyle(.secondary)
                }
            }
            // 每个循环组单独一组，组标题是循环组名称。
            ForEach(model.profile.cycleGroups) { group in
                CycleGroupSection(model: model, group: group)
            }
            characterSection
            globalSection
        }
        .formStyle(.grouped)
    }

    /// 每角色直达热键。
    private var characterSection: some View {
        Section(L10n.hotkeys.characterHotkeysHeader) {
            // 列出全部已知角色（含离线的），离线角色的热键也照常注册，角色上线后即可用。
            let names = model.characterNames
            if names.isEmpty {
                Text(L10n.settings.noCharacters).foregroundStyle(.secondary)
            }
            ForEach(names, id: \.self) { name in
                LabeledContent(name) {
                    HotkeyListEditor(model: model, slot: .character(name))
                }
            }
        }
    }

    /// 通用热键（全部隐藏、全部最小化、登录客户端循环）与热键规则的说明。
    private var globalSection: some View {
        Section(L10n.hotkeys.globalHotkeysHeader) {
            LabeledContent(L10n.hotkeys.hotkeyToggleHideAll) {
                HotkeyListEditor(model: model, slot: .toggleHideAll)
            }
            LabeledContent(L10n.hotkeys.hotkeyMinimizeAll) {
                HotkeyListEditor(model: model, slot: .minimizeAll)
            }
            LabeledContent(L10n.hotkeys.hotkeyCycleLogin) {
                HotkeyListEditor(model: model, slot: .cycleLoginClients)
            }
            // 热键规则的说明与 Core 的 HotkeyPlanner 一致（键盘热键缺修饰键、系统保留会被拒绝；鼠标按键不限）。
            Text(L10n.hotkeys.hotkeyRulesHint).font(.caption).foregroundStyle(.secondary)
            // 鼠标热键的权限与吞掉按键的提醒（风险 R8、R9）。
            Text(L10n.hotkeys.mouseHotkeyHint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 一个循环组的编辑区：名称、热键、成员。
private struct CycleGroupSection: View {
    /// 视图模型。
    let model: SettingsViewModel
    /// 要编辑的循环组（当前配置里的值，修改经视图模型按 id 写回）。
    let group: CycleGroup

    var body: some View {
        Section {
            LabeledContent(L10n.hotkeys.groupName) {
                HStack {
                    // 名称在提交时写入；全是空白的名称不接受，保留原名。
                    CommitTextField(placeholder: L10n.hotkeys.groupName, text: group.name) { name in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { model.updateCycleGroup(group.id) { $0.name = trimmed } }
                    }
                    .frame(maxWidth: 220)
                    Button(L10n.hotkeys.deleteGroup, role: .destructive) { model.deleteCycleGroup(group.id) }
                }
            }
            LabeledContent(L10n.hotkeys.forwardHotkeys) {
                HotkeyListEditor(model: model, slot: .cycleForward(groupID: group.id))
            }
            LabeledContent(L10n.hotkeys.backwardHotkeys) {
                HotkeyListEditor(model: model, slot: .cycleBackward(groupID: group.id))
            }
            membersList
            addMemberMenu
        } header: {
            Text(group.name)
        }
    }

    /// 成员列表：序号、名称、上移、下移、删除。
    @ViewBuilder private var membersList: some View {
        if group.members.isEmpty {
            Text(L10n.hotkeys.noMembers).foregroundStyle(.secondary)
        }
        // 按位置标识每一行：校验已去掉重复成员（5.4 节），但上移下移时名称与位置的对应会变，按位置更稳妥。
        ForEach(Array(group.members.enumerated()), id: \.offset) { index, name in
            HStack {
                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                Text(name)
                Spacer()
                Button { model.moveMember(in: group.id, at: index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                Button { model.moveMember(in: group.id, at: index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == group.members.count - 1)
                Button {
                    // 按钮闭包捕获的是渲染时的位置；列表已在别处变短时不越界。
                    model.updateCycleGroup(group.id) { group in
                        if group.members.indices.contains(index) { group.members.remove(at: index) }
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
            }
            // 无边框按钮：Form 的一行里有多个按钮时，默认样式会让整行响应点击。
            .buttonStyle(.borderless)
        }
    }

    /// 「添加成员」菜单：列出不在组里的已知角色，在线的排在前面。
    private var addMemberMenu: some View {
        let online = model.onlineCharacters
        let candidates = model.characterNames.filter { !group.members.contains($0) }
            .sorted { online.contains($0) && !online.contains($1) }
        // 只能从已知角色里选：成员名要与窗口标题里的角色名完全一致（区分大小写），手输容易出错。
        return Menu(L10n.hotkeys.addMember) {
            ForEach(candidates, id: \.self) { name in
                // 在线角色名后加一个圆点。
                Button(online.contains(name) ? "\(name) ●" : name) {
                    model.updateCycleGroup(group.id) { $0.members.append(name) }
                }
            }
        }
        .disabled(candidates.isEmpty)
        .fixedSize()
    }
}
