// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「客户端」页（架构文档 7.4 节）：在线客户端与配置里出现过的角色。
// 每个角色一行：在线状态、显示缩略图开关、高亮颜色；顶部是「全部隐藏」开关。
// 登录界面的客户端没有角色名，不能按角色设置，只列出来供核对。

import SwiftUI
import EVEOPreviewCore

/// 「客户端」页。
struct ClientsPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            // 「全部隐藏」是会话状态，不写进配置，重启后恢复显示。
            Section {
                Toggle(L10n.settings.hideAllThumbnails, isOn: model.hideAllBinding)
            } header: {
                PageHeader(title: L10n.settings.pageClients, subtitle: L10n.settings.clientsSubtitle)
            }
            charactersSection
            if !model.loginClients.isEmpty {
                loginSection
            }
        }
        .formStyle(.grouped)
    }

    /// 角色列表；没有任何角色时显示一行说明。
    private var charactersSection: some View {
        Section {
            let names = model.characterNames
            if names.isEmpty {
                Text(L10n.settings.noCharacters).foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in
                    CharacterRow(model: model, name: name, isOnline: model.onlineCharacters.contains(name))
                }
            }
        } header: {
            Text(L10n.settings.charactersHeader)
        } footer: {
            Text(L10n.settings.charactersFooter).foregroundStyle(.secondary)
        }
    }

    /// 在线的登录与未知客户端。
    private var loginSection: some View {
        Section(L10n.settings.loginClientsHeader) {
            // 显示名是 `EVE` 或 `EVE (<pid>)`，与缩略图标题一致。
            ForEach(model.loginClients) { client in
                Label(TitleParser.title(for: client.identity, pid: client.pid), systemImage: "person.crop.circle.badge.questionmark")
            }
        }
    }
}

/// 一个角色的行。
private struct CharacterRow: View {
    /// 视图模型。
    let model: SettingsViewModel
    /// 角色名（区分大小写，与配置里的键一致）。
    let name: String
    /// 角色当前是否有客户端在线。
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 在线状态：绿点在线，灰点离线。
            Circle()
                .fill(isOnline ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .help(isOnline ? L10n.settings.online : L10n.settings.offline)
            Text(name)
            Spacer()
            // 按角色的高亮颜色；为空时用「预览与布局」页的全局颜色。
            OptionalHexColorPicker(hex: model.highlightColor(name), fallback: model.profile.overlay.highlightColor)
                .help(L10n.settings.highlightColorHelp)
            // 关掉即加入隐藏名单（持久化），与会话内的「全部隐藏」不同。
            Toggle(L10n.settings.showThumbnail, isOn: model.showsThumbnail(name))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
