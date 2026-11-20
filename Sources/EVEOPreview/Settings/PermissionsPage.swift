// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「权限」页（架构文档 4.4 节、7.4 节）：屏幕录制与辅助功能两项权限的状态、
// 请求按钮、系统设置跳转与「重新启动」按钮。页可见时每秒重新查询一次权限
// （辅助功能授权后立即生效；屏幕录制通常要重启应用才生效）。
// 辅助功能的说明写明鼠标按键热键也依赖它：没有这项权限时事件监听建不成，鼠标热键全部不生效（反馈文档 6.6 节）。

import SwiftUI
import EVEOPreviewCore

/// 「权限」页。
struct PermissionsPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                PermissionRow(title: L10n.settings.screenRecording, detail: L10n.settings.screenRecordingDetail,
                              granted: model.permissions.screenRecording,
                              request: model.requestScreenRecording,
                              open: { model.openSystemSettings(.screenRecording) })
                PermissionRow(title: L10n.settings.accessibility, detail: L10n.settings.accessibilityDetail,
                              granted: model.permissions.accessibility,
                              request: model.requestAccessibility,
                              open: { model.openSystemSettings(.accessibility) })
            } header: {
                PageHeader(title: L10n.settings.pagePermissions, subtitle: L10n.settings.permissionsSubtitle)
            }
            // 屏幕录制授权后，当前进程通常仍拿不到画面，要以新实例重新启动。
            Section {
                LabeledContent(L10n.settings.relaunchHint) {
                    Button(L10n.settings.relaunch) { model.relaunch() }
                }
                // ad-hoc 签名每次构建身份都变，授权随之失效（架构文档 9.2 节）。
                Text(L10n.settings.signingHint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 页可见时每秒查询一次权限，离开页面时任务自动取消。
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// 一项权限的行：状态图标、名称、用途说明、请求与跳转按钮。
private struct PermissionRow: View {
    /// 权限名称。
    let title: String
    /// 用途说明：缺了这项权限哪些功能不可用（见架构文档 4.4 节的权限矩阵）。
    let detail: String
    /// 是否已授权。
    let granted: Bool
    /// 请求授权。屏幕录制第一次请求时系统弹窗，之后只能去系统设置里打开。
    let request: () -> Void
    /// 打开系统设置的对应面板。
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Text(granted ? L10n.settings.granted : L10n.settings.notGranted)
                        .font(.caption)
                        .foregroundStyle(granted ? Color.green : Color.red)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing) {
                // 已授权时请求按钮置灰；跳转按钮始终可用，便于用户撤销授权。
                Button(L10n.settings.request, action: request).disabled(granted)
                Button(L10n.settings.openSystemSettings, action: open)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
