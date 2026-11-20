// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的俄文文字（反馈文档 5.3 节、7.11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：боевое оповещение、игровой журнал、миниатюра；系统权限用 macOS 俄文界面的
// 「Файлы и папки」。俄文的复数有 3 种形式，由 fileCount 处理。

import Foundation

/// 「提醒」页的俄文文字。
struct CombatStringsRU: CombatStrings {
    // MARK: 页头
    var pageSubtitle: String { "Миниатюра персонажа мигает, когда его атакуют." }

    // MARK: 开关与状态行
    var enableToggle: String { "Мигать миниатюрой при атаке на персонажа" }
    var statusLabel: String { "Состояние" }
    var statusStopped: String { "Выключено" }
    func statusWatching(directory: String, files: Int) -> String {
        "Отслеживается \(fileCount(files)) в \(directory)"
    }
    func statusDirectoryNotFound(_ path: String) -> String { "Папка игровых журналов не найдена: \(path)" }
    func statusAccessDenied(_ path: String) -> String { "Нет доступа к \(path)" }
    var accessDeniedHelp: String {
        "Разрешите EVE-O Preview доступ к папке «Документы» в разделе "
            + "«Системные настройки > Конфиденциальность и безопасность > Файлы и папки»."
    }
    var openSystemSettings: String { "Открыть Системные настройки…" }

    // MARK: 日志目录
    var logDirectoryHeader: String { "Игровые журналы" }
    var logDirectoryLabel: String { "Папка" }
    var automaticSuffix: String { "(автоматически)" }
    var chooseDirectory: String { "Выбрать…" }
    var useAutomaticLocation: String { "Определять автоматически" }
    var chooseDirectoryMessage: String { "Выберите папку EVE «logs» или «Gamelogs»." }

    // MARK: 闪烁的外观
    var appearanceHeader: String { "Мигание" }
    var flashColor: String { "Цвет мигания" }
    var duration: String { "Длительность" }
    func seconds(_ value: Double) -> String { "\(combatSecondsNumber(value)) с" }
    var style: String { "Стиль" }
    var styleBorder: String { "Рамка" }
    var styleWash: String { "Заливка" }
    var styleBoth: String { "Оба" }

    // MARK: 触发条件
    var triggersHeader: String { "Условия" }
    var includeMisses: String { "Оповещать и о промахах противника" }
    var minimumDamage: String { "Минимальный урон" }
    var minimumDamageHelp: String { "Урон меньше этого значения не вызывает оповещения. Промахи — по переключателю выше." }

    // MARK: 测试与说明
    var testFlash: String { "Проверить мигание" }
    var testFlashHelp: String { "Все миниатюры мигнут один раз, даже если оповещение выключено." }
    var footnote: String {
        "В клиенте EVE должна быть включена запись игровых сообщений в файлы журналов. "
            + "Эта функция только читает игровые журналы и ничего не отправляет в игру."
    }

    /// 「N 个日志文件」的三种复数形式：1 файл、2～4 файла、5 файлов（11～14 也用 файлов）。
    private func fileCount(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1, mod100 != 11 { return "\(n) файл журнала" }
        if (2...4).contains(mod10), !(12...14).contains(mod100) { return "\(n) файла журнала" }
        return "\(n) файлов журнала"
    }
}
