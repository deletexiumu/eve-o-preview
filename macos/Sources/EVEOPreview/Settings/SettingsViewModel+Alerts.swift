// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口视图模型的「提醒」页部分（反馈文档 7.11 节）：战斗提醒设置的绑定、日志目录的选择与复原、
// 状态行的文字、「测试闪烁」与「打开系统设置」。设置的写入立即生效并安排保存（与其他页相同）。

import AppKit
import SwiftUI
import EVEOPreviewCore

extension SettingsViewModel {
    /// 当前配置方案的战斗提醒设置某个字段的绑定。
    func combatBinding<Value>(_ keyPath: WritableKeyPath<CombatAlertSettings, Value>) -> Binding<Value> {
        let base: WritableKeyPath<Profile, CombatAlertSettings> = \.combatAlert
        return binding(base.appending(path: keyPath))
    }

    /// 实际使用的日志目录的显示文字：没有指定时显示自动查找的第一个候选并标注「自动」。
    var logDirectoryDisplay: String {
        if let configured = config.general.eveLogDirectory {
            return configured
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let automatic = CombatLogDirectory.candidates(configured: nil, homeDirectory: home).first ?? ""
        return automatic + " " + L10n.combat.automaticSuffix
    }

    /// 是否指定了日志目录（「使用自动位置」按钮只在指定时可用）。
    var hasCustomLogDirectory: Bool {
        config.general.eveLogDirectory != nil
    }

    /// 状态行的文字。
    var combatStatusText: String {
        let strings = L10n.combat
        switch combatLogStatus {
        case .stopped:
            return strings.statusStopped
        case .watching(let directory, let files):
            return strings.statusWatching(directory: directory, files: files)
        case .directoryNotFound(let path):
            return strings.statusDirectoryNotFound(path)
        case .accessDenied(let path):
            return strings.statusAccessDenied(path)
        }
    }

    /// 状态是否为「没有访问权限」，是时显示说明与「打开系统设置」按钮。
    var combatAccessDenied: Bool {
        if case .accessDenied = combatLogStatus { return true }
        return false
    }

    /// 用 NSOpenPanel 选择日志目录。用户可选 logs 目录或 Gamelogs 目录（7.3 节）。
    func chooseLogDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = L10n.combat.chooseDirectoryMessage
        panel.prompt = L10n.combat.chooseDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "…."))
        if let current = config.general.eveLogDirectory {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.config.update { $0.general.eveLogDirectory = url.path }
    }

    /// 改回自动查找日志目录。
    func useAutomaticLogDirectory() {
        coordinator.config.update { $0.general.eveLogDirectory = nil }
    }

    /// 让全部缩略图闪烁一次（不要求功能已打开）。
    func testCombatAlert() {
        coordinator.testCombatAlert()
    }

    /// 打开系统设置的「文件与文件夹」页。
    func openFilesAndFoldersSettings() {
        coordinator.services.permissions.openSystemSettings(.filesAndFolders)
    }
}
