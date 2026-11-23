// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「配置方案」页（架构文档 7.4 节）：列表、切换、新建、克隆、改名、删除，
// 以及「在访达中显示配置文件」。名称规则由 Core 的 ProfileEditor 判断：
// 去掉首尾空白后 1～64 字，不区分大小写唯一。最后一个配置方案不能删除。

import SwiftUI
import EVEOPreviewCore

/// 「配置方案」页。
struct ProfilesPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    /// 名称输入框对应的操作。
    private enum NamePrompt: Identifiable {
        /// 新建：名称不能与任何现有方案重复。
        case add
        /// 克隆：关联值是源方案，新方案插在它后面。
        case clone(Profile)
        /// 改名：关联值是被改名的方案，比较重名时排除它自己。
        case rename(Profile)

        /// sheet(item:) 需要稳定的 id；同一种操作针对不同方案时 id 不同，保证内容刷新。

        var id: String {
            switch self {
            case .add: return "add"
            case .clone(let p): return "clone-\(p.id)"
            case .rename(let p): return "rename-\(p.id)"
            }
        }
    }

    /// 正在显示的名称输入框；nil 表示没有。
    @State private var prompt: NamePrompt?
    /// 等待确认删除的方案；非 nil 时弹出确认框。删除不可撤销，所以不直接删。
    @State private var pendingDelete: Profile?

    var body: some View {
        Form {
            Section {
                ForEach(model.config.profiles) { profile in
                    row(profile)
                }
            } header: {
                PageHeader(title: L10n.settings.pageProfiles, subtitle: L10n.settings.profilesSubtitle)
            }
            Section {
                Button(L10n.settings.newProfile) { prompt = .add }
                LabeledContent(L10n.settings.configFile) {
                    Button(L10n.settings.revealConfig) { model.revealConfigFile() }
                }
                Text(model.configFileURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        // 名称输入用 sheet 而不用 alert：alert 里的按钮不能按输入内容置灰，sheet 可以实时校验。
        .sheet(item: $prompt) { prompt in
            ProfileNameSheet(title: title(for: prompt), initial: initialName(for: prompt),
                             validate: { validate($0, for: prompt) },
                             onConfirm: { confirm($0, for: prompt) })
        }
        // 删除前确认；确认框关闭（取消）时清掉待删项。
        .confirmationDialog(L10n.settings.deleteProfileConfirm(pendingDelete?.name ?? ""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(L10n.settings.delete, role: .destructive) {
                if let profile = pendingDelete { model.deleteProfile(profile.id) }
                pendingDelete = nil
            }
        }
    }

    /// 一个配置方案的行：名称、当前标记、操作按钮。
    private func row(_ profile: Profile) -> some View {
        let isActive = profile.id == model.config.activeProfileID
        return HStack {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(profile.name)
            if isActive {
                Text(L10n.settings.activeBadge).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // 当前方案不显示「切换」；最后一个方案不能删除（Core 的 ProfileEditor 也会拒绝）。
            if !isActive {
                Button(L10n.settings.switchTo) { model.switchProfile(profile.id) }
            }
            Button(L10n.settings.rename) { prompt = .rename(profile) }
            Button(L10n.settings.clone) { prompt = .clone(profile) }
            Button(L10n.settings.delete, role: .destructive) { pendingDelete = profile }
                .disabled(model.config.profiles.count <= 1)
        }
        .controlSize(.small)
    }

    /// 输入框的标题。
    private func title(for prompt: NamePrompt) -> String {
        switch prompt {
        case .add: return L10n.settings.newProfile
        case .clone(let p): return L10n.settings.cloneTitle(p.name)
        case .rename(let p): return L10n.settings.renameTitle(p.name)
        }
    }

    /// 输入框的初始文字：克隆时给一个建议名，改名时给原名。
    private func initialName(for prompt: NamePrompt) -> String {
        switch prompt {
        case .add: return ""
        case .clone(let p): return L10n.settings.copyName(p.name)
        case .rename(let p): return p.name
        }
    }

    /// 名称是否可用。
    private func validate(_ name: String, for prompt: NamePrompt) -> Bool {
        if case .rename(let p) = prompt { return model.isValidProfileName(name, excluding: p.id) }
        return model.isValidProfileName(name, excluding: nil)
    }

    /// 执行操作。
    private func confirm(_ name: String, for prompt: NamePrompt) {
        switch prompt {
        case .add: model.addProfile(named: name)
        case .clone(let p): model.cloneProfile(p.id, as: name)
        case .rename(let p): model.renameProfile(p.id, to: name)
        }
    }
}

/// 输入配置方案名称的小窗口。名称不可用时确定按钮置灰并显示规则。
private struct ProfileNameSheet: View {
    /// 窗口标题。
    let title: String
    /// 输入框的初始文字。
    let initial: String
    /// 名称校验，规则由 Core 的 ProfileEditor 决定。
    let validate: (String) -> Bool
    /// 确定后的回调，参数是输入的名称（首尾空白由 ProfileEditor 去掉）。
    let onConfirm: (String) -> Void

    /// 输入中的名称，出现时用 initial 填充。
    @State private var name = ""
    /// 关闭 sheet 的环境动作。
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let isValid = validate(name)
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(L10n.settings.profileName, text: $name)
                .frame(width: 280)
                .onSubmit { if isValid { finish() } }
            // 合法时放一个空格占位，避免提示出现与消失时窗口高度跳动。
            Text(isValid ? " " : L10n.settings.profileNameRule).font(.caption).foregroundStyle(.red)
            HStack {
                Spacer()
                Button(L10n.settings.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.settings.confirm) { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .onAppear { name = initial }
    }

    /// 提交并关闭。
    private func finish() {
        onConfirm(name)
        dismiss()
    }
}
