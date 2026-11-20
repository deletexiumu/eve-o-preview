// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的英文文字（反馈文档 5.3 节、7.11 节）。用词按 5.5 节的词表：combat alert、game log、thumbnail。
// 系统权限的名称用 macOS 英文界面的官方说法「Files and Folders」。

import Foundation

/// 「提醒」页的英文文字。
struct CombatStringsEN: CombatStrings {
    // MARK: 页头
    var pageSubtitle: String { "Flash a character's thumbnail when it comes under attack." }

    // MARK: 开关与状态行
    // 状态行显示目录全路径，文字保持短。
    var enableToggle: String { "Flash thumbnail when a character is attacked" }
    var statusLabel: String { "Status" }
    var statusStopped: String { "Off" }
    func statusWatching(directory: String, files: Int) -> String {
        "Watching \(files == 1 ? "1 log file" : "\(files) log files") in \(directory)"
    }
    func statusDirectoryNotFound(_ path: String) -> String { "Game log folder not found: \(path)" }
    func statusAccessDenied(_ path: String) -> String { "No permission to read \(path)" }
    var accessDeniedHelp: String {
        "Allow EVE-O Preview to access the Documents folder in System Settings > Privacy & Security > Files and Folders."
    }
    var openSystemSettings: String { "Open System Settings…" }

    // MARK: 日志目录
    var logDirectoryHeader: String { "Game logs" }
    var logDirectoryLabel: String { "Folder" }
    var automaticSuffix: String { "(automatic)" }
    var chooseDirectory: String { "Choose…" }
    var useAutomaticLocation: String { "Use Automatic Location" }
    var chooseDirectoryMessage: String { "Choose the EVE \"logs\" or \"Gamelogs\" folder." }

    // MARK: 闪烁的外观
    var appearanceHeader: String { "Flash" }
    var flashColor: String { "Flash color" }
    var duration: String { "Duration" }
    func seconds(_ value: Double) -> String { "\(combatSecondsNumber(value)) s" }
    var style: String { "Style" }
    var styleBorder: String { "Border" }
    var styleWash: String { "Tint" }
    var styleBoth: String { "Both" }

    // MARK: 触发条件
    var triggersHeader: String { "Triggers" }
    var includeMisses: String { "Also alert on attacks that miss" }
    var minimumDamage: String { "Minimum damage" }
    var minimumDamageHelp: String { "Hits below this amount are ignored. Misses follow the switch above." }

    // MARK: 测试与说明
    var testFlash: String { "Test Flash" }
    var testFlashHelp: String { "Flashes every thumbnail once, even when the alert is off." }
    var footnote: String {
        "The EVE client must be set to write game messages to log files. "
            + "This feature only reads the game logs and never sends any input to the game."
    }
}
