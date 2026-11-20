// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的英文文字。沿用 v1 的英文，新增的是鼠标热键与作用范围的文字（反馈文档 6.8 节）。
// 「Global hotkeys」一节改称「General hotkeys」：「Global」已用作作用范围的名称，避免同一个词两个意思。

import Foundation

/// 热键域的英文实现。
struct HotkeyStringsEN: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String { "Cycle groups and hotkeys. Each hotkey works everywhere or only in EVE." }
    var cycleGroupsHeader: String { "Cycle groups" }
    var addGroup: String { "New Cycle Group" }
    var noGroups: String { "No cycle groups yet." }
    var groupName: String { "Name" }
    var deleteGroup: String { "Delete Group" }
    var forwardHotkeys: String { "Forward hotkeys" }
    var backwardHotkeys: String { "Backward hotkeys" }
    var noMembers: String { "No members yet." }
    var addMember: String { "Add Member" }
    func newGroupName(_ index: Int) -> String { "Group \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "Character hotkeys" }
    var globalHotkeysHeader: String { "General hotkeys" }
    var hotkeyToggleHideAll: String { "Show or hide all thumbnails" }
    var hotkeyMinimizeAll: String { "Minimize all clients" }
    var hotkeyCycleLogin: String { "Cycle login-screen clients" }
    var hotkeyRulesHint: String {
        "Keyboard hotkeys need Control, Option or Command, except F1–F20 and keypad digits. "
            + "Middle and side mouse buttons can be used alone; the click is not passed to the game."
    }
    var mouseHotkeyHint: String {
        "Mouse hotkeys need Accessibility permission. A mouse button set to Global is swallowed in every app. "
            + "Remove other bindings of the button in the game or in your mouse software first."
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "Default hotkey scope" }
    var scopeGlobal: String { "Global" }
    var scopeGame: String { "Only in EVE" }
    func scopeFollowDefault(_ current: String) -> String { "Use Default (\(current))" }
    func scopeMenuHelp(_ resolved: String) -> String { "Scope: \(resolved)" }
    var menuHotkeysOnlyInEVE: String { "Hotkeys Only in EVE" }

    // MARK: 录制器

    var addHotkey: String { "+ Add" }
    var recordingPrompt: String { "Press keys or a mouse side button (pointer in this window)…" }
    var recorderHelp: String {
        "Click, then press a key combination or a middle or side mouse button. Esc cancels, Delete clears."
    }
    var removeHotkey: String { "Remove this hotkey" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "Unrecognized" }
    var hotkeyMissingModifier: String { "Needs a modifier" }
    var hotkeyReserved: String { "Reserved by macOS" }
    var hotkeyAccessibilityRequired: String { "Needs Accessibility" }
    var hotkeyEventTapUnavailable: String { "Can't monitor the mouse" }
    func hotkeyDuplicate(_ other: String) -> String { "Already used by \(other)" }
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "Registration failed (\(status))" }
}
