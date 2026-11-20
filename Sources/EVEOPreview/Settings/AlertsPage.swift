// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「提醒」页（反馈文档 7.11 节）。内容依次是：
// 1. 开关「角色被攻击时闪烁缩略图」与状态行；没有访问权限时附说明与「打开系统设置」按钮。
// 2. 日志目录：路径、「选择…」、「使用自动位置」。
// 3. 闪烁颜色、持续时间（1～10 秒，步长 0.5）、样式（边框、底色、两者）。
// 4. 「未命中的攻击也提醒」、最小伤害（1～100,000）。
// 5. 「测试闪烁」按钮与页尾说明。
// 控件的读写与动作在 SettingsViewModel+Alerts.swift。文字全部取自 L10n.combat。

import SwiftUI
import EVEOPreviewCore

/// 「提醒」页。
struct AlertsPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        // 每次求值时取一次文字表：切换界面语言后视图重建，自然取到新语言。
        let strings = L10n.combat
        Form {
            // 第 1 组：总开关与状态行。打开开关后才第一次读日志目录，系统的权限提示出现在这一步之后。
            Section {
                Toggle(strings.enableToggle, isOn: model.combatBinding(\.enabled))
                statusRow(strings)
            } header: {
                PageHeader(title: L10n.settings.pageAlerts, subtitle: strings.pageSubtitle)
            }
            // 第 2 组：日志目录。没有指定时自动查找，见 CombatLogDirectory.candidates。
            Section(strings.logDirectoryHeader) {
                directoryRow(strings)
            }
            // 第 3 组：闪烁的外观。颜色与样式改动后下一次重算即生效，正在闪的缩略图立即换色。
            Section(strings.appearanceHeader) {
                HexColorPicker(label: strings.flashColor, hex: model.combatBinding(\.color))
                SliderRow(label: strings.duration, value: model.combatBinding(\.durationSeconds),
                          range: CombatAlertSettings.durationRange, step: 0.5,
                          format: { strings.seconds($0) })
                // 分段选择：边框、底色、两者，对应 CombatAlertStyle 的三个值。
                Picker(strings.style, selection: model.combatBinding(\.style)) {
                    Text(strings.styleBorder).tag(CombatAlertStyle.border)
                    Text(strings.styleWash).tag(CombatAlertStyle.wash)
                    Text(strings.styleBoth).tag(CombatAlertStyle.both)
                }
                .pickerStyle(.segmented)
            }
            // 第 4 组：触发条件，规则见 CombatAlertRules.triggers。
            Section {
                Toggle(strings.includeMisses, isOn: model.combatBinding(\.includeMisses))
                minimumDamageRow(strings)
            } header: {
                Text(strings.triggersHeader)
            } footer: {
                Text(strings.minimumDamageHelp).foregroundStyle(.secondary)
            }
            // 第 5 组：「测试闪烁」与页尾说明。测试不要求开关已打开。
            Section {
                LabeledContent {
                    Button(strings.testFlash) { model.testCombatAlert() }
                } label: {
                    Text(strings.testFlashHelp).foregroundStyle(.secondary)
                }
            } footer: {
                Text(strings.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// 状态行；没有访问权限时多一行说明与「打开系统设置」按钮。
    @ViewBuilder
    private func statusRow(_ strings: any CombatStrings) -> some View {
        LabeledContent(strings.statusLabel) {
            // 状态文字含目录全路径，允许选中复制，便于用户核对。
            Text(model.combatStatusText)
                .foregroundStyle(model.combatAccessDenied ? .orange : .secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        if model.combatAccessDenied {
            NoticeBanner(text: strings.accessDeniedHelp)
            Button(strings.openSystemSettings) { model.openFilesAndFoldersSettings() }
        }
    }

    /// 日志目录：路径与两个按钮。
    private func directoryRow(_ strings: any CombatStrings) -> some View {
        LabeledContent(strings.logDirectoryLabel) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(model.logDirectoryDisplay)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button(strings.chooseDirectory) { model.chooseLogDirectory() }
                    Button(strings.useAutomaticLocation) { model.useAutomaticLogDirectory() }
                        .disabled(!model.hasCustomLogDirectory)
                }
            }
        }
    }

    /// 最小伤害：步进器加数字框，范围 1～100,000。
    private func minimumDamageRow(_ strings: any CombatStrings) -> some View {
        let value = model.combatBinding(\.minimumDamage)
        let range = CombatAlertSettings.minimumDamageRange
        return LabeledContent(strings.minimumDamage) {
            HStack(spacing: 6) {
                // 数字框只在回车或失去焦点时写入；超出范围的输入夹到范围内，无法解析时保持原值。
                CommitTextField(placeholder: "", text: String(value.wrappedValue)) { text in
                    if let number = Int(text.trimmingCharacters(in: .whitespaces)) {
                        value.wrappedValue = min(max(number, range.lowerBound), range.upperBound)
                    }
                }
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
                Stepper("", value: value, in: range).labelsHidden()
            }
        }
    }
}
