// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的法文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按第 11 节的词表：superposition（浮窗）、canal（频道）、service de modèle（模型服务）；
// 钥匙串用 macOS 法文界面的官方名称「trousseau」。

import Foundation

/// 翻译域的法文文字。
struct TranslationStringsFR: TranslationStrings {
    // MARK: 页头与状态
    var pageSubtitle: String { "Traduit les messages en d'autres langues des canaux choisis." }
    var enableToggle: String { "Afficher la superposition de traduction" }
    var statusLabel: String { "État" }
    var statusOff: String { "Désactivé" }
    var statusIdle: String { "Prêt" }
    var statusTranslating: String { "Traduction en cours" }
    func statusWaiting(seconds: Int, reason: String) -> String { "Nouvel essai dans \(seconds) s : \(reason)" }
    func statusBlocked(_ reason: String) -> String { "En pause : \(reason)" }
    var retryNow: String { "Réessayer maintenant" }

    // MARK: 失败的原因
    var failureMissingBaseURL: String { "Aucune adresse d'API indiquée" }
    var failureMissingModel: String { "Aucun nom de modèle indiqué" }
    var failureInvalidURL: String { "L'adresse d'API n'est pas valide" }
    var failureInsecureHTTP: String { "Les adresses http ne sont autorisées que pour ce Mac ou le réseau local" }
    var failureMissingKey: String { "Aucune clé d'API indiquée" }
    var failureKeychain: String {
        "Impossible de lire la clé dans le trousseau ; enregistrez-la de nouveau dans la page Traduction"
    }
    func failureUnauthorized(status: Int) -> String { "La clé a été refusée (HTTP \(status))" }
    var failureNotFound: String { "Adresse d'API ou nom de modèle incorrect (HTTP 404)" }
    var failureBalance: String { "Solde insuffisant (HTTP 402)" }
    func failureRejected(status: Int, message: String) -> String {
        message.isEmpty ? "Requête refusée (HTTP \(status))" : "Requête refusée (HTTP \(status)) : \(message)"
    }
    var failureRateLimited: String { "Trop de requêtes ou quota épuisé (HTTP 429)" }
    func failureServer(status: Int) -> String { "Erreur du service de modèle (HTTP \(status))" }
    var failureNetwork: String { "Impossible de joindre le service de modèle" }
    var failureMalformed: String { "Le modèle n'a pas répondu au format attendu" }
    var failureRefused: String { "Le modèle a refusé ces messages" }
    var failureTruncated: String { "La réponse du modèle a été tronquée" }

    // MARK: 频道与目标语言
    var channelsHelp: String { "Choisissez les canaux à traduire." }
    var targetHeader: String { "Langue cible" }
    var targetLanguage: String { "Traduire en" }
    var targetFollowUI: String { "Langue de l'interface" }
    var showOriginal: String { "Afficher aussi le texte original" }
    var foreignOnly: String { "N'afficher que les messages traduits" }

    // MARK: 模型服务
    var modelHeader: String { "Modèle" }
    var provider: String { "Service" }
    var providerCustom: String { "Autre (compatible OpenAI)" }
    var baseURL: String { "Adresse d'API" }
    var model: String { "Nom du modèle" }
    var apiKey: String { "Clé d'API" }
    var apiKeyStored: String { "Enregistrée dans le trousseau" }
    var apiKeyPlaceholder: String { "Collez la clé, puis cliquez sur Enregistrer" }
    var saveKey: String { "Enregistrer" }
    var deleteKey: String { "Supprimer la clé" }
    var keyNotRequired: String { "Ce service ne demande pas de clé" }
    var keyOptional: String { "Indiquez une clé si le service en demande une ; sinon laissez vide." }
    func keychainError(status: Int32) -> String { "Échec de l'opération sur le trousseau (\(status))" }
    var test: String { "Tester" }
    var testing: String { "Test en cours…" }
    func testSucceeded(_ text: String) -> String { "Réussi : \(text)" }
    func testFailed(_ reason: String) -> String { "Échec : \(reason)" }

    // MARK: 缓存与说明
    var cacheHeader: String { "Cache des traductions" }
    func cacheCount(_ count: Int) -> String { count <= 1 ? "\(count) entrée" : "\(count) entrées" }
    var clearCache: String { "Vider le cache" }
    var privacyNote: String {
        "Le texte des messages de ces canaux est envoyé au service de modèle que vous choisissez. "
            + "La clé est conservée uniquement dans le trousseau de ce Mac et envoyée uniquement à ce service."
    }
    var costNote: String {
        "Seuls les messages reçus par le personnage du client actif sont traduits. "
            + "Les phrases identiques ne sont traduites qu'une fois."
    }

    // MARK: 浮窗
    func overlayTitle(_ character: String) -> String { "Traduction · \(character)" }
    var statusNoChannels: String { "Aucun canal de traduction défini" }
    func statusNoLogFiles(_ channels: [String]) -> String {
        "EVE n'a écrit aucun journal de discussion \(channels.joined(separator: ", ")) pour ce personnage depuis 48 h"
    }
    func statusNoLogFilesBuiltIn(_ channels: [String]) -> String {
        "EVE n'écrit pas de journal \(channels.joined(separator: ", ")) : un client non anglais peut ignorer les canaux système, passez EVE en English"
    }
    var pending: String { "traduction…" }
    var failed: String { "non traduit" }
}
