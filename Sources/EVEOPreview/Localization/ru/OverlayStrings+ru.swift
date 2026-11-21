// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域的俄文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与菜单栏一致：оверлей、канал、«Закрепить расположение»。俄文的复数有 3 种形式，由 plural 处理。

import Foundation

/// 浮窗与两页共用设置控件的俄文文字。
struct OverlayStringsRU: OverlayStrings {
    // MARK: 浮窗的列表
    func newMessages(_ count: Int) -> String { plural(count, "новое сообщение", "новых сообщения", "новых сообщений") }
    var noActiveCharacter: String { "В текущем окне нет персонажа" }
    var emptyList: String { "Сообщений пока нет" }

    // MARK: 浮窗的右键菜单
    var menuScrollToLatest: String { "Прокрутить к последним" }
    var menuCopyLine: String { "Копировать эту строку" }
    var menuOpenInBrowser: String { "Открыть в браузере" }
    var menuClear: String { "Очистить список" }
    var menuLockLayout: String { "Закрепить расположение" }
    var menuResetFrame: String { "Вернуть положение и размер по умолчанию" }
    var menuHide: String { "Скрыть этот оверлей" }
    var menuOpenSettings: String { "Открыть настройки…" }

    // MARK: 浮窗设置
    var overlayHeader: String { "Оверлей" }
    var opacity: String { "Непрозрачность фона" }
    var fontSize: String { "Размер шрифта" }
    var resetFrame: String { "Вернуть положение по умолчанию" }
    var gestureHelp: String { "Перетаскивайте правой кнопкой или левой с Option, чтобы переместить оверлей; тяните за край, чтобы изменить размер; прокручивайте колесом, чтобы листать список." }

    // MARK: 频道列表
    var channelsHeader: String { "Каналы" }
    var addFromLogs: String { "Добавить из журналов" }
    var addByNamePlaceholder: String { "Введите название канала и нажмите Return" }
    var removeChannel: String { "Удалить" }
    var noChannels: String { "Каналов пока нет" }
    var refreshChannels: String { "Обновить" }
    var noDiscoveredChannels: String { "Недавних журналов чата не найдено" }
    func channelListeners(_ count: Int) -> String { plural(count, "персонаж", "персонажа", "персонажей") }

    // MARK: 内置频道
    var builtInLocal: String { "Локал" }
    var builtInCorp: String { "Корпорация" }
    var builtInAlliance: String { "Альянс" }
    var builtInFleet: String { "Флот" }

    // MARK: 复数
    /// 俄文的 3 种复数形式：1、21、31… 用 one；2～4、22～24… 用 few；其余用 many。
    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1, mod100 != 11 { return "\(n) \(one)" }
        if (2...4).contains(mod10), !(12...14).contains(mod100) { return "\(n) \(few)" }
        return "\(n) \(many)"
    }
}
