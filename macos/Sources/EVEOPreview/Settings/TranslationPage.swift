// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「翻译」页（docs/macos/design-intel-translate.md 第 10 节）。内容依次是：
// 1. 开关「显示翻译浮窗」与状态行；暂停或等待时附「立即重试」；聊天日志有错误时附说明。
// 2. 频道列表（列出内置频道）。
// 3. 目标语言、「同时显示原文」、「只显示翻译过的消息」。
// 4. 模型服务：预设、接口地址、模型名、API Key（保存、删除）、「测试」。
// 5. 浮窗的外观与位置。
// 6. 译文缓存的条数与「清空缓存」；页尾的隐私与费用说明。
// 控件的读写与动作在 SettingsViewModel+Translation.swift。翻译的状态、Key 与缓存条数不是视图模型的存储属性，
// body 里读一次 model.chatRevision，状态变化时页面随之重绘。Key 的输入与测试结果是本页的临时状态，不进配置。

import SwiftUI
import EVEOPreviewCore

/// 「翻译」页。
struct TranslationPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    /// Key 输入框里的草稿；保存后清空，不写进配置。
    @State private var keyDraft = ""
    /// Key 的保存或删除失败时的说明。
    @State private var keyError: String?
    /// 测试是否在进行。
    @State private var isTesting = false
    /// 测试的结果文字与是否成功。
    @State private var testResult: (text: String, succeeded: Bool)?

    var body: some View {
        // 读一次版本号：翻译状态、Key 与缓存条数变化时重绘。
        let _ = model.chatRevision
        let strings = L10n.translation
        Form {
            // 第 1 组：总开关与状态行。
            Section {
                Toggle(strings.enableToggle, isOn: model.translationBinding(\.enabled))
                statusRow(strings)
            } header: {
                PageHeader(title: L10n.settings.pageTranslation, subtitle: strings.pageSubtitle)
            }
            // 第 2 组：翻译频道，「从日志添加」里另列 4 个内置频道。
            Section {
                ChannelListEditor(channels: model.translationBinding(\.channels), discovered: model.discoveredChannels,
                                  includesBuiltIns: true, onRefresh: { model.refreshDiscoveredChannels() },
                                  autoRefresh: model.profile.translation.enabled && model.isWatchingChatLogs)
            } footer: {
                Text(strings.channelsHelp).foregroundStyle(.secondary)
            }
            // 第 3 组：目标语言与显示。
            Section(strings.targetHeader) {
                Picker(strings.targetLanguage, selection: model.translationBinding(\.targetLanguage)) {
                    Text(strings.targetFollowUI).tag(TranslationTarget.ui)
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        if let target = TranslationTarget(rawValue: language.rawValue) {
                            Text(language.autonym).tag(target)
                        }
                    }
                }
                Toggle(strings.showOriginal, isOn: model.translationBinding(\.showOriginal))
                Toggle(strings.foreignOnly, isOn: model.translationBinding(\.foreignOnly))
            }
            // 第 4 组：模型服务。
            Section(strings.modelHeader) {
                providerRow(strings)
                endpointRows(strings)
                keyRows(strings)
                testRow(strings)
            }
            // 第 5 组：浮窗的外观与位置（共用视图，WP-A）。
            OverlaySettingsSection(settings: model.translationBinding(\.overlay), kind: .translation,
                                   screens: model.coordinator.screens)
            // 第 6 组：译文缓存与页尾说明。
            Section {
                LabeledContent(strings.cacheHeader) {
                    HStack {
                        Text(strings.cacheCount(model.translationCacheCount)).foregroundStyle(.secondary)
                        Button(strings.clearCache) { model.clearTranslationCache() }
                            .disabled(model.translationCacheCount == 0)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.privacyNote)
                    Text(strings.costNote)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// 状态行；暂停或等待时附「立即重试」，聊天日志有错误时附说明。
    @ViewBuilder
    private func statusRow(_ strings: any TranslationStrings) -> some View {
        LabeledContent(strings.statusLabel) {
            HStack {
                Text(model.translationStatusText)
                    .foregroundStyle(model.translationNeedsAttention ? .orange : .secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                if model.translationNeedsAttention {
                    Button(strings.retryNow) { model.retryTranslation() }
                }
            }
        }
        if let problem = model.translationChatLogProblem {
            NoticeBanner(text: problem + "\n" + L10n.settings.chatLogHelp)
        }
    }

    /// 预设的下拉。换预设时清掉自定义的地址与模型名，测试结果也清掉。
    private func providerRow(_ strings: any TranslationStrings) -> some View {
        let selection = Binding<TranslationProviderID>(
            get: { model.translationEndpoint.provider },
            set: { id in
                model.selectTranslationProvider(id)
                keyDraft = ""
                keyError = nil
                testResult = nil
            })
        return Picker(strings.provider, selection: selection) {
            ForEach(TranslationProviders.presets, id: \.id) { preset in
                Text(model.translationProviderName(preset.id)).tag(preset.id)
            }
        }
    }

    /// 接口地址与模型名：占位文字是预设值，回车或失去焦点时提交；地址不能用时在下面显示原因。
    @ViewBuilder
    private func endpointRows(_ strings: any TranslationStrings) -> some View {
        let preset = model.translationPreset
        let endpoint = model.translationEndpoint
        LabeledContent(strings.baseURL) {
            CommitTextField(placeholder: preset.baseURL, text: endpoint.baseURL) { model.commitTranslationBaseURL($0) }
                .multilineTextAlignment(.trailing)
        }
        if let issue = model.translationEndpointIssueText {
            Text(issue).font(.callout).foregroundStyle(.orange)
        }
        LabeledContent(strings.model) {
            CommitTextField(placeholder: preset.model, text: endpoint.model) { model.commitTranslationModel($0) }
                .multilineTextAlignment(.trailing)
        }
    }

    /// API Key：密文输入框与「保存」「删除 Key」；不用 Key 的预设只显示一句说明。
    @ViewBuilder
    private func keyRows(_ strings: any TranslationStrings) -> some View {
        if model.translationKeyNotUsed {
            LabeledContent(strings.apiKey) {
                Text(strings.keyNotRequired).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent(strings.apiKey) {
                HStack {
                    SecureField(strings.apiKeyPlaceholder, text: $keyDraft)
                        .labelsHidden()
                        .onSubmit { saveKey() }
                    Button(strings.saveKey) { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(strings.deleteKey) { keyError = model.deleteTranslationKey() }
                        .disabled(model.translationKeyStored == false)
                }
            }
            if model.translationKeyStored == true {
                Label(strings.apiKeyStored, systemImage: "checkmark.seal").foregroundStyle(.secondary)
            }
            if model.translationPreset.id == .custom {
                Text(strings.keyOptional).font(.callout).foregroundStyle(.secondary)
            }
            if let keyError {
                Text(keyError).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    /// 「测试」按钮与结果。
    private func testRow(_ strings: any TranslationStrings) -> some View {
        LabeledContent {
            Button(isTesting ? strings.testing : strings.test) { runTest() }
                .disabled(isTesting)
        } label: {
            if let testResult {
                Text(testResult.text)
                    .foregroundStyle(testResult.succeeded ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
            } else {
                Text(verbatim: "")
            }
        }
    }

    /// 保存 Key：成功后清空输入框。
    private func saveKey() {
        let draft = keyDraft
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyError = model.saveTranslationKey(draft)
        if keyError == nil { keyDraft = "" }
    }

    /// 发一次测试样例。
    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await model.testTranslation()
            testResult = result
            isTesting = false
        }
    }
}
