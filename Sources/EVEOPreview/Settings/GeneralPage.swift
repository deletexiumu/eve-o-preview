// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「通用」页（反馈文档 5.1 节、5.2 节）：界面语言的选择，以及「部分译文由机器生成，欢迎指正」的说明。
//
// 选项依次是 English、中文、Русский、日本語、한국어，最后是「跟随系统」。前 5 项用各语言的自称
// （AppLanguage.autonym），不随界面语言变化，这样选错语言后仍认得出自己的语言。
// 选择写入 `general.language`，对全部配置方案生效；协调器在配置变化时切换界面语言，不用重启（5.4 节）。
//
// v1.1：语言一组里另有「在 Dock 中显示图标」开关（设计第 19 节），写 `general.showDockIcon`。
// v1.1（v1.1 设计 11.2 节）：语言一组之后是「更新」与「诊断」两组，分别在
// UpdateSettingsSection.swift 与 DiagnosticsSettingsSection.swift 里，本页只放两行。

import SwiftUI
import EVEOPreviewCore

/// 「通用」页。
struct GeneralPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker(L10n.settings.interfaceLanguage, selection: model.generalBinding(\.language)) {
                    ForEach(LanguagePreference.allCases, id: \.self) { option in
                        Text(GeneralPage.label(for: option)).tag(option)
                    }
                }
                Text(L10n.settings.machineTranslationNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: model.generalBinding(\.showDockIcon)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.settings.showDockIcon)
                        Text(L10n.settings.showDockIconHelp).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                PageHeader(title: L10n.settings.pageGeneral, subtitle: L10n.settings.generalSubtitle)
            }
            UpdateSettingsSection(model: model)
            DiagnosticsSettingsSection(model: model)
        }
        .formStyle(.grouped)
    }

    /// 语言选项的显示名：具体语言用自称，「跟随系统」用当前界面语言的说法。
    static func label(for option: LanguagePreference) -> String {
        switch option {
        case .en: return AppLanguage.en.autonym
        case .zh: return AppLanguage.zh.autonym
        case .ru: return AppLanguage.ru.autonym
        case .ja: return AppLanguage.ja.autonym
        case .ko: return AppLanguage.ko.autonym
        case .system: return L10n.settings.followSystem
        }
    }
}
