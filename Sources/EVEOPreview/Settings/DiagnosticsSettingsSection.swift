// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「通用」页的「诊断」一组（v1.1 设计 11.2 节）：「详细日志」开关与说明、日志文件的位置与
// 「在访达中显示日志」按钮、「报告问题…」按钮。控制器经 `model.coordinator.problemReport` 取得。
//
// 「详细日志」把 `general.logLevel` 在 info 与 debug 之间切换；改动立即生效由协调器的
// `diagnosticsSettingsDidChange` 负责（WP-1）。日志目录的规则见 `ProblemReportBuilder.logDirectory()`。

import SwiftUI
import EVEOPreviewCore

/// 「通用」页的诊断一组。
struct DiagnosticsSettingsSection: View {
    /// 设置窗口的视图模型。
    let model: SettingsViewModel

    var body: some View {
        Section {
            Toggle(isOn: verboseBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.diagnostics.verboseLoggingToggle)
                    Text(L10n.diagnostics.verboseLoggingHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent(L10n.diagnostics.logLocationLabel) {
                Text(DiagnosticsSettingsSection.displayPath(ProblemReportBuilder.logDirectory()))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.diagnostics.showLogsButton) { revealLogs() }
                Spacer()
                Button(L10n.diagnostics.reportButton) {
                    model.coordinator.problemReport?.showReportWindow(context: .manual)
                }
            }
        } header: {
            Text(L10n.diagnostics.sectionHeader)
        }
    }

    /// 「详细日志」开关：debug 为开，info 为关。
    private var verboseBinding: Binding<Bool> {
        let level = model.generalBinding(\.logLevel)
        return Binding(get: { level.wrappedValue == .debug },
                       set: { on in level.wrappedValue = on ? .debug : .info })
    }

    /// 在访达里显示日志：有当前日志文件时选中它，否则选中目录；目录还不存在时显示上一级目录。
    private func revealLogs() {
        let directory = ProblemReportBuilder.logDirectory()
        let current = LogFileLayout(directory: directory).currentURL
        let fileManager = FileManager.default
        let target: URL
        if fileManager.fileExists(atPath: current.path) {
            target = current
        } else if fileManager.fileExists(atPath: directory.path) {
            target = directory
        } else {
            target = directory.deletingLastPathComponent()
        }
        model.coordinator.services.diagnostics.revealInFinder(target)
    }

    /// 路径的显示：主目录写成 `~`。
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
