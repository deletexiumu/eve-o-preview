// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的俄文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：热键 горячая клавиша，循环组 группа переключения，缩略图 миниатюра，
// 客户端 клиент，鼠标按键 кнопка мыши，辅助功能 Универсальный доступ（macOS 俄文版的官方名称）。
// 俄文普遍比英文长；热键问题显示在按钮左侧的同一行，所以那几条尽量写短。

import Foundation

/// 热键域的俄文实现。
struct HotkeyStringsRU: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String {
        "Группы переключения и горячие клавиши. Каждая клавиша работает везде или только в EVE."
    }
    var cycleGroupsHeader: String { "Группы переключения" }
    var addGroup: String { "Новая группа переключения" }
    var noGroups: String { "Групп переключения пока нет." }
    var groupName: String { "Название" }
    var deleteGroup: String { "Удалить группу" }
    var forwardHotkeys: String { "Клавиши «вперёд»" }
    var backwardHotkeys: String { "Клавиши «назад»" }
    var noMembers: String { "Участников пока нет." }
    var addMember: String { "Добавить участника" }
    func newGroupName(_ index: Int) -> String { "Группа \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "Клавиши персонажей" }
    var globalHotkeysHeader: String { "Общие горячие клавиши" }
    var hotkeyToggleHideAll: String { "Показать или скрыть все миниатюры" }
    var hotkeyMinimizeAll: String { "Свернуть все клиенты" }
    var hotkeyCycleLogin: String { "Переключение клиентов на экране входа" }
    var hotkeyRulesHint: String {
        "Клавиатурной горячей клавише нужен Control, Option или Command; F1–F20 и цифры цифрового блока "
            + "можно использовать отдельно. Среднюю и боковые кнопки мыши можно использовать отдельно; "
            + "нажатие не передаётся в игру."
    }
    var mouseHotkeyHint: String {
        "Для кнопок мыши нужно разрешение «Универсальный доступ». Кнопка мыши с областью «Везде» "
            + "перехватывается во всех приложениях. Сначала снимите другие назначения этой кнопки в игре "
            + "или в программе мыши."
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "Область действия по умолчанию" }
    var scopeGlobal: String { "Везде" }
    var scopeGame: String { "Только в EVE" }
    func scopeFollowDefault(_ current: String) -> String { "По умолчанию (сейчас: \(current))" }
    func scopeMenuHelp(_ resolved: String) -> String { "Область действия: \(resolved)" }
    var menuHotkeysOnlyInEVE: String { "Горячие клавиши только в EVE" }

    // MARK: 录制器

    var addHotkey: String { "+ Добавить" }
    var recordingPrompt: String { "Нажмите клавиши или боковую кнопку мыши (указатель в этом окне)…" }
    var recorderHelp: String {
        "Нажмите, затем сочетание клавиш или среднюю либо боковую кнопку мыши. Esc — отмена, Delete — очистить."
    }
    var removeHotkey: String { "Удалить эту горячую клавишу" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "Не распознано" }
    var hotkeyMissingModifier: String { "Нужен модификатор" }
    var hotkeyReserved: String { "Занято macOS" }
    var hotkeyAccessibilityRequired: String { "Нужен «Универсальный доступ»" }
    var hotkeyEventTapUnavailable: String { "Нет доступа к мыши" }
    func hotkeyDuplicate(_ other: String) -> String { "Уже занято: \(other)" }
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "Ошибка регистрации (\(status))" }
}
