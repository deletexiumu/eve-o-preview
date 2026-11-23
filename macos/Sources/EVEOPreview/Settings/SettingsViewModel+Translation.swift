// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口视图模型的「翻译」页部分（docs/macos/design-intel-translate.md 第 10 节）：翻译设置与接口设置的绑定、
// 状态行的文字、Key 的保存与删除、测试、立即重试、译文缓存的条数与清空。
// 翻译的状态、Key 是否已保存与缓存条数是 TranslationController 的只读属性，不是视图模型的存储属性，
// SwiftUI 观察不到：页面在 body 里读 `chatRevision`，控制器每次通知变化时它加 1，页面随之重绘。
// 成员都以 translation 开头：「预警」页的扩展（WP-B）在同一个类型上并行添加成员，前缀避免重名。

import SwiftUI
import EVEOPreviewCore

extension SettingsViewModel {
    /// 翻译功能的控制器。
    var translationController: TranslationController { coordinator.chat.translation }

    /// 当前配置方案的翻译设置某个字段的绑定。
    func translationBinding<Value>(_ keyPath: WritableKeyPath<TranslationSettings, Value>) -> Binding<Value> {
        let base: WritableKeyPath<Profile, TranslationSettings> = \.translation
        return binding(base.appending(path: keyPath))
    }

    /// 模型服务的接口设置（全局）某个字段的绑定。
    func endpointBinding<Value>(_ keyPath: WritableKeyPath<TranslationEndpointSettings, Value>) -> Binding<Value> {
        let base: WritableKeyPath<GeneralSettings, TranslationEndpointSettings> = \.translationEndpoint
        return generalBinding(base.appending(path: keyPath))
    }

    /// 当前的接口设置。
    var translationEndpoint: TranslationEndpointSettings { config.general.translationEndpoint }

    /// 当前选中的预设。
    var translationPreset: TranslationProviderPreset { TranslationProviders.preset(translationEndpoint.provider) }

    /// 预设在下拉里的名字：自定义一项用界面文字，其余用不翻译的服务名。
    func translationProviderName(_ id: TranslationProviderID) -> String {
        id == .custom ? L10n.translation.providerCustom : TranslationProviders.preset(id).displayName
    }

    /// 换预设：同时清掉自定义的地址与模型名，新预设用自己的默认值。
    func selectTranslationProvider(_ id: TranslationProviderID) {
        guard id != translationEndpoint.provider else { return }
        coordinator.config.update { config in
            config.general.translationEndpoint = TranslationEndpointSettings(provider: id)
        }
    }

    /// 提交接口地址：去掉首尾空白。
    func commitTranslationBaseURL(_ text: String) {
        endpointBinding(\.baseURL).wrappedValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提交模型名：去掉首尾空白。
    func commitTranslationModel(_ text: String) {
        endpointBinding(\.model).wrappedValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 接口设置不能用时的原因（显示在接口地址下面）；能用时为 nil。
    var translationEndpointIssueText: String? {
        if case .failure(let issue) = TranslationProviders.resolve(translationEndpoint) {
            return L10n.translation.issueText(issue)
        }
        return nil
    }

    /// 目标语言求值后的结果（跟随界面语言时取当前界面语言）。
    var translationTarget: AppLanguage { profile.translation.targetLanguage.resolved(ui: L10n.language) }

    // MARK: - 状态

    /// 状态行的文字。
    var translationStatusText: String {
        L10n.translation.statusText(translationController.status, now: Date().timeIntervalSince1970)
    }

    /// 状态是不是暂停或等待：是时显示「立即重试」按钮，文字用醒目的颜色。
    var translationNeedsAttention: Bool {
        switch translationController.status {
        case .blocked, .waiting: return true
        case .off, .idle, .translating: return false
        }
    }

    /// 聊天日志的错误说明（找不到目录或没有权限）；没有错误时为 nil。
    var translationChatLogProblem: String? {
        switch chatLogStatus {
        case .directoryNotFound(let path): return L10n.settings.chatLogStatusDirectoryNotFound(path)
        case .accessDenied(let path): return L10n.settings.chatLogStatusAccessDenied(path)
        case .stopped, .watching: return nil
        }
    }

    /// 用户点「立即重试」。
    func retryTranslation() {
        translationController.retry()
    }

    // MARK: - Key

    /// 当前预设的 Key 是否已在钥匙串里；没读过时为 nil（不为了显示这一行去读钥匙串）。
    var translationKeyStored: Bool? {
        translationController.isKeyStored(for: translationEndpoint.provider)
    }

    /// 当前预设是否根本不用 Key（Ollama）：这时不显示 Key 的输入框。
    var translationKeyNotUsed: Bool {
        let preset = translationPreset
        return !preset.requiresKey && preset.id != .custom
    }

    /// 保存 Key；成功时为 nil，失败时是说明文字。
    func saveTranslationKey(_ key: String) -> String? {
        guard let error = translationController.saveKey(key, for: translationEndpoint.provider) else { return nil }
        return Self.translationKeychainText(error)
    }

    /// 删除 Key；成功时为 nil，失败时是说明文字。
    func deleteTranslationKey() -> String? {
        guard let error = translationController.deleteKey(for: translationEndpoint.provider) else { return nil }
        return Self.translationKeychainText(error)
    }

    /// 钥匙串失败的文字。
    private static func translationKeychainText(_ error: SecretStoreError) -> String {
        switch error {
        case .failed(let status): return L10n.translation.keychainError(status: status)
        }
    }

    /// 用当前的设置发一次测试样例，返回要显示在按钮旁的文字与是否成功。
    func testTranslation() async -> (text: String, succeeded: Bool) {
        let strings = L10n.translation
        switch await translationController.test(endpoint: translationEndpoint, target: translationTarget) {
        case .success(let text): return (strings.testSucceeded(text), true)
        case .failure(let failure): return (strings.testFailed(strings.failureText(failure)), false)
        }
    }

    // MARK: - 译文缓存

    /// 译文缓存的条数。
    var translationCacheCount: Int { translationController.cacheCount }

    /// 清空译文缓存。
    func clearTranslationCache() {
        translationController.clearCache()
    }
}
