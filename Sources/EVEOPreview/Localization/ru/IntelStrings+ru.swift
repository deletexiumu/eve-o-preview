// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警域的俄文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与 WP-0 的俄文文字一致：разведка（预警）、оверлей（浮窗）、канал（频道）、журнал чата（聊天日志）；
// 跳是 прыжок，敌对是 враждебный，星图数据是 данные карты，ESI 不翻译。
// 「联网核对人名」与 settings.aboutChatLogsNote 里的 онлайн-проверка имён 一致。

import Foundation

/// 俄语的数词变格：1 用 one，2～4 用 few，其余用 many（11～14 用 many）。
private func intelRussianPlural(_ count: Int, one: String, few: String, many: String) -> String {
    let lastTwo = abs(count) % 100
    let last = abs(count) % 10
    if (11...14).contains(lastTwo) { return many }
    if last == 1 { return one }
    if (2...4).contains(last) { return few }
    return many
}

/// 预警域的俄文文字。
struct IntelStringsRU: IntelStrings {
    // MARK: 页头、开关与频道
    var pageSubtitle: String {
        "Читает журналы каналов разведки и показывает, где враги, сколько их, на каких кораблях и как далеко."
    }
    var enableToggle: String { "Показывать оверлей разведки" }
    var statusLabel: String { "Состояние" }
    var channelsHelp: String { "Выберите каналы, в которых сообщают о врагах." }

    // MARK: 我的位置
    var locationHeader: String { "Моё местоположение" }
    var locationHelp: String {
        "Местоположение берётся из записей о прыжках в игровом журнале и из журнала канала «Местный». "
            + "Если нет ни того, ни другого, укажите его здесь."
    }
    var locationUnknown: String { "Неизвестно" }
    func locationValue(system: String, source: String, age: String) -> String { "\(system) (\(source), \(age) назад)" }
    var sourceGameLog: String { "игровой журнал" }
    var sourceLocal: String { "канал «Местный»" }
    var sourceManual: String { "вручную" }
    var systemPlaceholder: String { "Введите название системы и нажмите Return" }
    var clearLocation: String { "Очистить" }
    var systemNotFound: String { "Система не найдена" }
    var noOnlineCharacters: String { "Нет персонажей в сети" }
    var referenceSystem: String { "Опорная система" }
    var referenceSystemHelp: String {
        "Если местоположение персонажа неизвестно, прыжки считаются от опорной системы."
    }

    // MARK: 显示
    var displayHeader: String { "Отображение" }
    var windowMinutes: String { "Хранить последние" }
    func minutes(_ count: Int) -> String { "\(count) мин" }
    var maxJumps: String { "Считать до" }
    func jumpsUnit(_ count: Int) -> String {
        "\(count) \(intelRussianPlural(count, one: "прыжка", few: "прыжков", many: "прыжков"))"
    }
    var alertJumps: String { "Подсвечивать в пределах" }
    var alertJumpsHelp: String {
        "Сообщения в пределах этого числа прыжков подсвечиваются. Значение 0 отключает подсветку."
    }
    var showOriginal: String { "Показывать исходный текст" }

    // MARK: 星图数据与页尾
    var staticDataLabel: String { "Данные карты" }
    func staticDataBuild(_ build: Int) -> String { "Сборка SDE \(build)" }
    var staticDataMissing: String { "Нет данных карты: системы и корабли не распознаются" }
    var footnote: String {
        "Эта функция только читает журналы чата и игровые журналы и не отправляет в игру никакого ввода. "
            + "Имена пилотов и численность определяются по формату сообщения и могут быть неверны. "
            + "Онлайн-проверка лишь показывает, что персонаж с таким именем существует, "
            + "но не гарантирует, что в сообщении речь именно о нём."
    }

    // MARK: 浮窗的标题与状态行
    func overlayTitle(_ character: String) -> String { "Разведка · \(character)" }
    var statusNoStaticData: String { "Нет данных карты" }
    var statusNoChannels: String { "Каналы разведки не выбраны" }
    var statusLocationUnknown: String { "Местоположение неизвестно; откройте настройки правой кнопкой" }
    func statusUsingReference(_ system: String) -> String { "Местоположение неизвестно; отсчёт от \(system)" }
    func statusLocation(system: String, source: String, age: String) -> String {
        "Местоположение: \(system) (\(source), \(age) назад)"
    }

    // MARK: 浮窗每一行
    func ageSeconds(_ count: Int) -> String { "\(count) с" }
    func ageMinutes(_ count: Int) -> String { "\(count) мин" }
    func jumps(_ count: Int) -> String { "\(count) пр." }
    var jumpsHere: String { "здесь" }
    func jumpsBeyond(_ limit: Int) -> String { ">\(limit) пр." }
    var jumpsUnreachable: String { "нет врат" }
    var jumpsUnknown: String { "?" }
    func count(_ value: Int) -> String { "×\(value)" }
    func countInferred(_ value: Int) -> String { "~×\(value)" }
    var clear: String { "чисто" }
    var noVisual: String { "не видно" }

    // MARK: 人名核对
    var resolvePilotsToggle: String { "Онлайн-проверка имён (ESI)" }
    var resolvePilotsHelp: String {
        "Когда несколько имён с пробелами идут подряд, приложение спрашивает у ESI API компании CCP, "
            + "каким персонажам они принадлежат. Отправляются только эти слова, без автора сообщения, "
            + "названия канала и имён ваших персонажей. Имена из одного слова не проверяются."
    }
    var pilotLookupLabel: String { "Проверка имён" }
    func pilotLookupIdle(_ count: Int) -> String {
        "Готово, сохранено \(count) \(intelRussianPlural(count, one: "имя", few: "имени", many: "имён"))"
    }
    var pilotLookupResolving: String { "Проверка" }
    func pilotLookupWaiting(_ seconds: Int) -> String { "ESI недоступен; повтор через \(seconds) с" }
    var clearPilotCache: String { "Очистить кэш имён" }
    func pilotCacheCount(_ count: Int) -> String {
        "Сохранено \(count) \(intelRussianPlural(count, one: "имя", few: "имени", many: "имён"))"
    }
}
