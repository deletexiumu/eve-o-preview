// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「通用」页的「更新」一组（v1.1 设计 11.2 节）：「自动检查更新」与「自动安装更新」两个开关与说明、
// 当前版本、上次检查的时刻、状态行、「立即检查」按钮。控制器经 `model.coordinator.updates` 取得；
// 它是 `@Observable`，阶段变化时本视图自己刷新。开关写 `general.checkForUpdates` 与 `general.autoInstallUpdates`。
//
// - 「自动安装更新」在 `capability` 不是 `.canInstall` 或「自动检查更新」关闭时置灰（3.1 节：置灰时不改值）。
//   置灰的原因是不能安装时，在开关下方写明原因；原因是另一个开关关着时不另写。
// - 更新功能整个停用（不是从 .app 运行）时，状态行写「这个构建不能使用更新功能」，「立即检查」置灰。
// - 检查、下载、核对、安装进行中时「立即检查」置灰。

import SwiftUI
import EVEOPreviewCore

/// 「通用」页的更新一组。
struct UpdateSettingsSection: View {
    /// 设置窗口的视图模型。
    let model: SettingsViewModel

    var body: some View {
        // 控制器由 AppDelegate 在建设置窗口之后赋值；页面显示时已经有了，这里仍按可能为空处理。
        if let updates = model.coordinator.updates {
            UpdateSettingsContent(model: model, updates: updates)
        }
    }
}

/// 更新一组的内容。
private struct UpdateSettingsContent: View {
    /// 设置窗口的视图模型：读写两个开关。
    let model: SettingsViewModel
    /// 更新功能的控制器：能力、阶段与上次检查的时刻。
    let updates: UpdateController

    var body: some View {
        let strings = L10n.updates
        let general = model.config.general
        Section(strings.sectionHeader) {
            toggleRow(strings.autoCheckToggle, help: strings.autoCheckHelp, isOn: model.generalBinding(\.checkForUpdates))
            toggleRow(strings.autoInstallToggle, help: strings.autoInstallHelp,
                      isOn: model.generalBinding(\.autoInstallUpdates))
                .disabled(updates.capability != .canInstall || !general.checkForUpdates)
            if case .notifyOnly(let blocker) = updates.capability {
                Text(strings.blocker(blocker)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent(strings.currentVersionLabel, value: versionText)
            LabeledContent(strings.lastCheckedLabel, value: lastCheckedText(strings))
            LabeledContent {
                Button(strings.checkNowButton) { updates.checkNow(userInitiated: true) }
                    .disabled(!canCheckNow)
            } label: {
                statusLine(strings)
            }
        }
    }

    /// 开关与它下方的说明。
    private func toggleRow(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 当前版本：显示构建标签（PR 构建如 `1.1.0-pr.12.abc1234`），有提交号且标签里没有时附在后面。
    /// 不是从 .app 运行时显示「开发版」。
    private var versionText: String {
        let environment = updates.environment
        guard environment.bundlePath != nil else { return L10n.settings.devVersion }
        guard let commit = environment.buildCommit, !environment.buildLabel.contains(commit) else {
            return environment.buildLabel
        }
        return "\(environment.buildLabel) (\(commit))"
    }

    /// 上次检查的时刻，按界面语言格式化；从来没有时是「从未检查」。
    private func lastCheckedText(_ strings: any UpdateStrings) -> String {
        var date = updates.lastCheckAt
        if case .upToDate(let checkedAt) = updates.phase, date.map({ $0 < checkedAt }) ?? true { date = checkedAt }
        return date.map(UpdateTextFormat.dateTime) ?? strings.lastCheckedNever
    }

    /// 「立即检查」是否可点：更新功能可用，且没有进行中的检查、下载或安装。
    private var canCheckNow: Bool {
        guard updates.capability != .unavailable else { return false }
        switch updates.phase {
        case .checking, .downloading, .verifying, .installing, .relaunching: return false
        case .idle, .upToDate, .available, .readyToInstall, .failed: return true
        }
    }

    /// 状态行；空闲时不显示文字。
    @ViewBuilder
    private func statusLine(_ strings: any UpdateStrings) -> some View {
        if let text = statusText(strings) {
            HStack(spacing: 6) {
                if isBusy { ProgressView().controlSize(.small) }
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(verbatim: "")
        }
    }

    /// 检查、下载、核对、安装、重新启动进行中。
    private var isBusy: Bool {
        switch updates.phase {
        case .checking, .downloading, .verifying, .installing, .relaunching: return true
        case .idle, .upToDate, .available, .readyToInstall, .failed: return false
        }
    }

    /// 状态行的文字：停用时说明停用；否则按阶段。`cancelled` 与空闲时没有文字。
    private func statusText(_ strings: any UpdateStrings) -> String? {
        guard updates.capability != .unavailable else { return strings.statusUnavailable }
        switch updates.phase {
        case .idle: return nil
        case .checking: return strings.statusChecking
        case .upToDate: return strings.statusUpToDate
        case .available(let release): return strings.statusAvailable(release.version)
        case .downloading(_, let progress):
            return strings.progressDownloading(received: UpdateTextFormat.bytes(progress.receivedBytes),
                                               total: progress.totalBytes.map(UpdateTextFormat.bytes))
        case .verifying: return strings.progressVerifying
        case .readyToInstall(let release): return strings.statusReady(release.version)
        case .installing: return strings.progressInstalling
        case .relaunching: return strings.progressRelaunching
        case .failed(let error, _): return strings.error(error)
        }
    }
}
