// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「预警」页（docs/macos/design-intel-translate.md 第 10 节）。内容依次是：
// 1. 开关「显示预警浮窗」与聊天日志的状态行；没有访问权限时附说明与「打开系统设置」按钮。
// 2. 频道列表（ChannelListEditor，不列内置频道）。
// 3. 我的位置：每个在线角色一行，位置文字、星系输入框（回车提交，查不到时行下提示）与「清除」按钮。
// 4. 参考星系：输入框，查不到时行下提示。
// 5. 显示：保留最近（5～120 分钟，步长 5）、最多计算（1～30 跳）、高亮距离（0～30 跳）、显示原文。
// 6. 人名核对（6.9 节增补）：开关「联网核对人名（ESI）」、说明、状态行；人名缓存的条数与「清空人名缓存」。
// 7. 浮窗设置（OverlaySettingsSection）。
// 8. 页尾：星图数据的 SDE 版本与说明文字。
// 位置、核对状态与缓存条数不是视图模型的存储属性，SwiftUI 观察不到；body 里读一次 model.chatRevision，
// 两个功能的状态变化时页面随之重绘。控件的读写在 SettingsViewModel+Intel.swift，文字取自 L10n.intel。

import SwiftUI
import EVEOPreviewCore

/// 「预警」页。
struct IntelPage: View {
    /// 视图模型。
    let model: SettingsViewModel
    /// 手动输入的星系名查不到的角色，行下显示提示。
    @State private var notFoundCharacters: Set<String> = []

    var body: some View {
        // 读一次版本号：位置、核对状态与缓存条数变化时重绘（见文件头）。
        let _ = model.chatRevision
        // 每次求值时取一次文字表：切换界面语言后视图重建，自然取到新语言。
        let strings = L10n.intel
        Form {
            Section {
                Toggle(strings.enableToggle, isOn: model.intelBinding(\.enabled))
                statusRow(strings)
            } header: {
                PageHeader(title: L10n.settings.pageIntel, subtitle: strings.pageSubtitle)
            } footer: {
                Text(L10n.settings.chatLogHelp).foregroundStyle(.secondary)
            }
            Section {
                ChannelListEditor(channels: model.intelBinding(\.channels), discovered: model.discoveredChannels,
                                  includesBuiltIns: false, onRefresh: { model.refreshDiscoveredChannels() },
                                  autoRefresh: model.profile.intel.enabled && model.isWatchingChatLogs)
            } footer: {
                Text(strings.channelsHelp).foregroundStyle(.secondary)
            }
            locationSection(strings)
            referenceSection(strings)
            displaySection(strings)
            pilotSection(strings)
            OverlaySettingsSection(settings: model.intelBinding(\.overlay), kind: .intel,
                                   screens: model.coordinator.screens)
            Section {
                LabeledContent(strings.staticDataLabel) {
                    Text(model.staticDataText).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } footer: {
                Text(strings.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// 状态行；没有访问权限时多一条说明与「打开系统设置」按钮（文字复用「提醒」页的两条）。
    @ViewBuilder
    private func statusRow(_ strings: any IntelStrings) -> some View {
        LabeledContent(strings.statusLabel) {
            Text(model.intelStatusText)
                .foregroundStyle(model.chatLogAccessDenied ? .orange : .secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        if model.chatLogAccessDenied {
            NoticeBanner(text: L10n.combat.accessDeniedHelp)
            Button(L10n.combat.openSystemSettings) { model.openFilesAndFoldersSettings() }
        }
    }

    /// 我的位置：每个在线角色一行。
    private func locationSection(_ strings: any IntelStrings) -> some View {
        Section {
            if model.intelCharacters.isEmpty {
                Text(strings.noOnlineCharacters).foregroundStyle(.secondary)
            }
            ForEach(model.intelCharacters, id: \.self) { character in
                locationRow(character, strings: strings)
            }
        } header: {
            Text(strings.locationHeader)
        } footer: {
            Text(strings.locationHelp).foregroundStyle(.secondary)
        }
    }

    /// 一个角色的位置：名字与位置文字，下面是星系输入框与「清除」按钮。
    private func locationRow(_ character: String, strings: any IntelStrings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(character) {
                Text(model.intelLocationText(for: character)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                // 只在回车、或改过草稿后失去焦点时提交；找到星系后清空输入框（审查 m5）。
                SubmitTextField(placeholder: strings.systemPlaceholder) { text in
                    let found = model.setIntelLocation(character: character, systemName: text)
                    if found {
                        notFoundCharacters.remove(character)
                    } else {
                        notFoundCharacters.insert(character)
                    }
                    return found
                }
                Button(strings.clearLocation) {
                    notFoundCharacters.remove(character)
                    model.clearIntelLocation(character: character)
                }
                .disabled(!model.hasIntelLocation(character))
            }
            if notFoundCharacters.contains(character) {
                Text(strings.systemNotFound).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// 参考星系：输入框，查不到时行下提示。
    private func referenceSection(_ strings: any IntelStrings) -> some View {
        Section {
            LabeledContent(strings.referenceSystem) {
                CommitTextField(placeholder: strings.systemPlaceholder, text: model.referenceSystemText) { text in
                    model.commitReferenceSystem(text)
                }
                .frame(maxWidth: 220)
            }
            if model.referenceSystemNotFound {
                Text(strings.systemNotFound).font(.caption).foregroundStyle(.orange)
            }
        } footer: {
            Text(strings.referenceSystemHelp).foregroundStyle(.secondary)
        }
    }

    /// 显示：保留最近、最多计算、高亮距离与「显示原文」。
    private func displaySection(_ strings: any IntelStrings) -> some View {
        Section {
            stepper(strings.windowMinutes, value: model.intelBinding(\.windowMinutes),
                    range: IntelSettings.windowMinutesRange, step: 5, format: { strings.minutes($0) })
            stepper(strings.maxJumps, value: model.intelBinding(\.maxJumps),
                    range: IntelSettings.maxJumpsRange, step: 1, format: { strings.jumpsUnit($0) })
            stepper(strings.alertJumps, value: model.intelBinding(\.alertJumps),
                    range: IntelSettings.alertJumpsRange, step: 1, format: { strings.jumpsUnit($0) })
            Toggle(strings.showOriginal, isOn: model.intelBinding(\.showOriginal))
        } header: {
            Text(strings.displayHeader)
        } footer: {
            Text(strings.alertJumpsHelp).foregroundStyle(.secondary)
        }
    }

    /// 人名核对：开关、说明与状态；人名缓存的条数与「清空人名缓存」按钮。
    private func pilotSection(_ strings: any IntelStrings) -> some View {
        Section {
            Toggle(strings.resolvePilotsToggle, isOn: model.intelBinding(\.resolvePilotNames))
            Text(strings.resolvePilotsHelp).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.profile.intel.resolvePilotNames, let status = model.pilotLookupStatusText {
                LabeledContent(strings.pilotLookupLabel) {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                Button(strings.clearPilotCache) { model.clearPilotCache() }
            } label: {
                Text(model.pilotCacheText ?? "").foregroundStyle(.secondary)
            }
        }
    }

    /// 带单位文字的整数步进器（单位文字随数量变化，如俄语的复数）。
    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int,
                         format: @escaping (Int) -> String) -> some View {
        Stepper(value: value, in: range, step: step) {
            LabeledContent(label) {
                Text(format(value.wrappedValue)).monospacedDigit()
            }
        }
    }
}
