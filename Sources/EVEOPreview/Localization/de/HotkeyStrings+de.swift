// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的德文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：热键 Hotkey，循环组 Wechselgruppe，缩略图 Miniatur，客户端 Client，
// 鼠标按键 Maustaste，辅助功能 Bedienungshilfen（macOS 德文版的官方名称），修饰键 Sondertaste；
// 作用范围 Bereich，全局 Überall，仅游戏内 Nur in EVE（第 13 节的术语）。
// 键名用 macOS 德文的叫法：Control（⌃）、Wahltaste（⌥）、Befehlstaste（⌘），括号里附符号便于对照。
// 德文普遍比英文长；热键问题显示在按钮左侧的同一行，所以那几条尽量写短。

import Foundation

/// 热键域的德文实现。
struct HotkeyStringsDE: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String {
        "Wechselgruppen und Hotkeys. Jeder Hotkey hat genau einen Bereich: Überall (auch in EVE) oder Nur in EVE."
    }
    var cycleGroupsHeader: String { "Wechselgruppen" }
    var addGroup: String { "Neue Wechselgruppe" }
    var noGroups: String { "Noch keine Wechselgruppen." }
    var groupName: String { "Name" }
    var deleteGroup: String { "Gruppe löschen" }
    var forwardHotkeys: String { "Hotkeys vorwärts" }
    var backwardHotkeys: String { "Hotkeys rückwärts" }
    var noMembers: String { "Noch keine Mitglieder." }
    var addMember: String { "Mitglied hinzufügen" }
    func newGroupName(_ index: Int) -> String { "Gruppe \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "Charakter-Hotkeys" }
    // 「通用热键」写 Allgemeine Hotkeys，不用 global，避免与作用范围「Überall」混淆。
    var globalHotkeysHeader: String { "Allgemeine Hotkeys" }
    var hotkeyToggleHideAll: String { "Alle Miniaturen ein-/ausblenden" }
    var hotkeyMinimizeAll: String { "Alle Clients minimieren" }
    var hotkeyCycleLogin: String { "Clients am Anmeldebildschirm durchschalten" }
    var hotkeyRulesHint: String {
        "Tastatur-Hotkeys brauchen Control (⌃), Wahltaste (⌥) oder Befehlstaste (⌘), außer F1–F20 und Ziffern "
            + "des Ziffernblocks. Mittlere und seitliche Maustasten gehen auch allein; der Klick wird nicht "
            + "an das Spiel weitergegeben."
    }
    var mouseHotkeyHint: String {
        "Maus-Hotkeys brauchen die Berechtigung „Bedienungshilfen“. Eine Maustaste mit Bereich „Überall“ wird "
            + "in jeder App abgefangen. Andere Belegungen der Taste im Spiel oder in der Maussoftware "
            + "vorher entfernen."
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "Standardbereich für Hotkeys" }
    var scopeGlobal: String { "Überall" }
    var scopeGame: String { "Nur in EVE" }
    var scopeGlobalOption: String { "Überall: wirkt in jeder App, auch in EVE" }
    var scopeGameOption: String { "Nur in EVE: wirkt nur, solange ein EVE-Fenster im Vordergrund ist" }
    var defaultScopeFooter: String {
        "Jeder Hotkey hat genau einen Bereich, nie beide zugleich. Die Markierung rechts neben jedem Hotkey zeigt den tatsächlich verwendeten Bereich. Ein Klick darauf stellt diesen einen Hotkey auf Überall, Nur in EVE oder den hier gewählten Standard."
    }
    // 「跟随默认」：Standard 后面的括号里是当前默认范围的名称。
    func scopeFollowDefault(_ current: String) -> String { "Standard (\(current))" }
    func scopeMenuHelp(_ resolved: String) -> String { "Bereich: \(resolved). Zum Ändern für diesen Hotkey klicken." }
    var menuHotkeysOnlyInEVE: String { "Hotkeys nur in EVE" }

    // MARK: 录制器

    var addHotkey: String { "+ Hinzufügen" }
    var recordingPrompt: String { "Tasten oder seitliche Maustaste drücken (Zeiger in diesem Fenster) …" }
    // Delete 键（kVK_Delete）在德文键盘上没有统一的字样，直接写符号 ⌫。
    var recorderHelp: String {
        "Klicken, dann eine Tastenkombination oder die mittlere bzw. eine seitliche Maustaste drücken. "
            + "Esc bricht ab, ⌫ löscht."
    }
    var removeHotkey: String { "Diesen Hotkey entfernen" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "Nicht erkannt" }
    var hotkeyMissingModifier: String { "Sondertaste fehlt" }
    var hotkeyReserved: String { "Von macOS reserviert" }
    var hotkeyAccessibilityRequired: String { "Bedienungshilfen nötig" }
    var hotkeyEventTapUnavailable: String { "Maus nicht überwachbar" }
    func hotkeyDuplicate(_ other: String) -> String { "Bereits belegt: \(other)" }
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "Registrierung fehlgeschlagen (\(status))" }
}
