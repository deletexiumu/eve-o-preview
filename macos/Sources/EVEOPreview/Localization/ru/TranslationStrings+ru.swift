// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的俄文文字（docs/macos/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按第 11 节的词表：оверлей（浮窗）、канал（频道）、сервис модели（模型服务）、кэш переводов（译文缓存）；
// 钥匙串用 macOS 俄文界面的官方名称「Связка ключей」。条数的复数按俄语的三种形式。

import Foundation

/// 俄语名词的复数形式：1、21… 用 one；2～4、22～24… 用 few；其余用 many。
private func translationRussianPlural(_ count: Int, one: String, few: String, many: String) -> String {
    let lastTwo = abs(count) % 100
    let last = abs(count) % 10
    if (11...14).contains(lastTwo) { return many }
    if last == 1 { return one }
    if (2...4).contains(last) { return few }
    return many
}

/// 翻译域的俄文文字。
struct TranslationStringsRU: TranslationStrings {
    // MARK: 页头与状态
    var pageSubtitle: String { "Переводит сообщения на других языках из выбранных каналов." }
    var enableToggle: String { "Показывать оверлей перевода" }
    var statusLabel: String { "Состояние" }
    var statusOff: String { "Выключено" }
    var statusIdle: String { "Готово" }
    var statusTranslating: String { "Перевод…" }
    func statusWaiting(seconds: Int, reason: String) -> String { "Повтор через \(seconds) с: \(reason)" }
    func statusBlocked(_ reason: String) -> String { "Приостановлено: \(reason)" }
    var retryNow: String { "Повторить сейчас" }

    // MARK: 失败的原因
    var failureMissingBaseURL: String { "Не указан адрес API" }
    var failureMissingModel: String { "Не указано имя модели" }
    var failureInvalidURL: String { "Неверный адрес API" }
    var failureInsecureHTTP: String { "Адреса http допускаются только для этого Mac и локальной сети" }
    var failureMissingKey: String { "Не указан ключ API" }
    var failureKeychain: String {
        "Не удалось прочитать ключ из связки ключей; сохраните его снова на странице «Перевод»"
    }
    func failureUnauthorized(status: Int) -> String { "Ключ отклонён (HTTP \(status))" }
    var failureNotFound: String { "Неверный адрес API или имя модели (HTTP 404)" }
    var failureBalance: String { "Недостаточно средств на счёте (HTTP 402)" }
    func failureRejected(status: Int, message: String) -> String {
        message.isEmpty ? "Запрос отклонён (HTTP \(status))" : "Запрос отклонён (HTTP \(status)): \(message)"
    }
    var failureRateLimited: String { "Слишком много запросов или исчерпана квота (HTTP 429)" }
    func failureServer(status: Int) -> String { "Ошибка сервиса модели (HTTP \(status))" }
    var failureNetwork: String { "Нет связи с сервисом модели" }
    var failureMalformed: String { "Модель ответила не в ожидаемом формате" }
    var failureRefused: String { "Модель отказалась переводить эти сообщения" }
    var failureTruncated: String { "Ответ модели обрезан" }

    // MARK: 频道与目标语言
    var channelsHelp: String { "Выберите каналы для перевода." }
    var targetHeader: String { "Язык перевода" }
    var targetLanguage: String { "Переводить на" }
    var targetFollowUI: String { "Как язык интерфейса" }
    var showOriginal: String { "Показывать и исходный текст" }
    var foreignOnly: String { "Показывать только переведённые сообщения" }

    // MARK: 模型服务
    var modelHeader: String { "Модель" }
    var provider: String { "Сервис" }
    var providerCustom: String { "Другой (совместимый с OpenAI)" }
    var baseURL: String { "Адрес API" }
    var model: String { "Имя модели" }
    var apiKey: String { "Ключ API" }
    var apiKeyStored: String { "Сохранён в связке ключей" }
    var apiKeyPlaceholder: String { "Вставьте ключ и нажмите «Сохранить»" }
    var saveKey: String { "Сохранить" }
    var deleteKey: String { "Удалить ключ" }
    var keyNotRequired: String { "Этому сервису ключ не нужен" }
    var keyOptional: String { "Укажите ключ, если сервис его требует; иначе оставьте поле пустым." }
    func keychainError(status: Int32) -> String { "Ошибка связки ключей (\(status))" }
    var test: String { "Проверить" }
    var testing: String { "Проверка…" }
    func testSucceeded(_ text: String) -> String { "Успешно: \(text)" }
    func testFailed(_ reason: String) -> String { "Ошибка: \(reason)" }

    // MARK: 缓存与说明
    var cacheHeader: String { "Кэш переводов" }
    func cacheCount(_ count: Int) -> String {
        "\(count) " + translationRussianPlural(count, one: "запись", few: "записи", many: "записей")
    }
    var clearCache: String { "Очистить кэш" }
    var privacyNote: String {
        "Текст сообщений из этих каналов отправляется выбранному вами сервису модели. "
            + "Ключ хранится только в связке ключей этого Mac и отправляется только этому сервису."
    }
    var costNote: String {
        "Переводятся только сообщения, полученные персонажем активного клиента. Одинаковые фразы переводятся один раз."
    }

    // MARK: 浮窗
    func overlayTitle(_ character: String) -> String { "Перевод · \(character)" }
    var statusNoChannels: String { "Каналы для перевода не выбраны" }
    func statusNoLogFiles(_ channels: [String]) -> String {
        "За последние 48 часов EVE не записала журнал чата \(channels.joined(separator: ", ")) для этого персонажа"
    }
    func statusNoLogFilesBuiltIn(_ channels: [String]) -> String {
        "EVE не пишет журнал \(channels.joined(separator: ", ")): клиент не на английском может пропускать системные каналы, переключите EVE на English"
    }
    var pending: String { "перевод…" }
    var failed: String { "не переведено" }
}
