// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的德文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按第 11 节的词表：Overlay（浮窗）、Kanal（频道）、Modelldienst（模型服务）；
// 钥匙串用 macOS 德文界面的官方名称「Schlüsselbund」。

import Foundation

/// 翻译域的德文文字。
struct TranslationStringsDE: TranslationStrings {
    // MARK: 页头与状态
    var pageSubtitle: String { "Übersetzt Nachrichten in anderen Sprachen aus den gewählten Kanälen." }
    var enableToggle: String { "Übersetzungs-Overlay anzeigen" }
    var statusLabel: String { "Status" }
    var statusOff: String { "Aus" }
    var statusIdle: String { "Bereit" }
    var statusTranslating: String { "Übersetzt" }
    func statusWaiting(seconds: Int, reason: String) -> String { "Neuer Versuch in \(seconds) s: \(reason)" }
    func statusBlocked(_ reason: String) -> String { "Angehalten: \(reason)" }
    var retryNow: String { "Jetzt erneut versuchen" }

    // MARK: 失败的原因
    var failureMissingBaseURL: String { "Keine API-Adresse angegeben" }
    var failureMissingModel: String { "Kein Modellname angegeben" }
    var failureInvalidURL: String { "Die API-Adresse ist ungültig" }
    var failureInsecureHTTP: String { "http-Adressen sind nur für diesen Mac oder das lokale Netzwerk erlaubt" }
    var failureMissingKey: String { "Kein API-Schlüssel angegeben" }
    var failureKeychain: String {
        "Der Schlüssel kann nicht aus dem Schlüsselbund gelesen werden; speichere ihn auf der Seite „Übersetzung“ erneut"
    }
    func failureUnauthorized(status: Int) -> String { "Der Schlüssel wurde abgelehnt (HTTP \(status))" }
    var failureNotFound: String { "Falsche API-Adresse oder falscher Modellname (HTTP 404)" }
    var failureBalance: String { "Guthaben reicht nicht aus (HTTP 402)" }
    func failureRejected(status: Int, message: String) -> String {
        message.isEmpty ? "Anfrage abgelehnt (HTTP \(status))" : "Anfrage abgelehnt (HTTP \(status)): \(message)"
    }
    var failureRateLimited: String { "Zu viele Anfragen oder Kontingent aufgebraucht (HTTP 429)" }
    func failureServer(status: Int) -> String { "Fehler des Modelldienstes (HTTP \(status))" }
    var failureNetwork: String { "Der Modelldienst ist nicht erreichbar" }
    var failureMalformed: String { "Das Modell hat nicht im erwarteten Format geantwortet" }
    var failureRefused: String { "Das Modell hat diese Nachrichten abgelehnt" }
    var failureTruncated: String { "Die Antwort des Modells wurde abgeschnitten" }

    // MARK: 频道与目标语言
    var channelsHelp: String { "Wähle die Kanäle, die übersetzt werden sollen." }
    var targetHeader: String { "Zielsprache" }
    var targetLanguage: String { "Übersetzen in" }
    var targetFollowUI: String { "Wie die Sprache der Oberfläche" }
    var showOriginal: String { "Auch den Originaltext anzeigen" }
    var foreignOnly: String { "Nur übersetzte Nachrichten anzeigen" }

    // MARK: 模型服务
    var modelHeader: String { "Modell" }
    var provider: String { "Dienst" }
    var providerCustom: String { "Andere (OpenAI-kompatibel)" }
    var baseURL: String { "API-Adresse" }
    var model: String { "Modellname" }
    var apiKey: String { "API-Schlüssel" }
    var apiKeyStored: String { "Im Schlüsselbund gespeichert" }
    var apiKeyPlaceholder: String { "Schlüssel einfügen und auf „Speichern“ klicken" }
    var saveKey: String { "Speichern" }
    var deleteKey: String { "Schlüssel löschen" }
    var keyNotRequired: String { "Dieser Dienst braucht keinen Schlüssel" }
    var keyOptional: String { "Gib einen Schlüssel ein, wenn der Dienst einen verlangt; sonst leer lassen." }
    func keychainError(status: Int32) -> String { "Schlüsselbund-Vorgang fehlgeschlagen (\(status))" }
    var test: String { "Testen" }
    var testing: String { "Wird getestet …" }
    func testSucceeded(_ text: String) -> String { "Erfolgreich: \(text)" }
    func testFailed(_ reason: String) -> String { "Fehlgeschlagen: \(reason)" }

    // MARK: 缓存与说明
    var cacheHeader: String { "Übersetzungs-Cache" }
    func cacheCount(_ count: Int) -> String { count == 1 ? "1 Eintrag" : "\(count) Einträge" }
    var clearCache: String { "Cache leeren" }
    var privacyNote: String {
        "Der Nachrichtentext aus diesen Kanälen wird an den gewählten Modelldienst gesendet. "
            + "Der Schlüssel wird nur im Schlüsselbund dieses Mac gespeichert und nur an diesen Dienst gesendet."
    }
    var costNote: String {
        "Nur Nachrichten, die der Charakter des aktiven Clients empfängt, werden übersetzt. "
            + "Gleiche Sätze werden nur einmal übersetzt."
    }

    // MARK: 浮窗
    func overlayTitle(_ character: String) -> String { "Übersetzung · \(character)" }
    var statusNoChannels: String { "Keine Übersetzungskanäle festgelegt" }
    var pending: String { "wird übersetzt …" }
    var failed: String { "nicht übersetzt" }
}
