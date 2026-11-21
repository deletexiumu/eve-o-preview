// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警域的法文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与 WP-0 的法文文字一致：renseignement（预警）、overlay（浮窗）、canal（频道）、journal de discussion
// （聊天日志）；跳是 saut，敌对是 hostile，星图数据是 données de carte，ESI 不翻译。
// 开关名与 settings.aboutChatLogsNote 里的 vérification des noms en ligne 一致。

import Foundation

/// 法语的单复数：0 与 1 用单数，其余用复数。
private func intelFrenchPlural(_ count: Int, singular: String, plural: String) -> String {
    abs(count) < 2 ? singular : plural
}

/// 预警域的法文文字。
struct IntelStringsFR: IntelStrings {
    // MARK: 页头、开关与频道
    var pageSubtitle: String {
        "Lit les journaux des canaux de renseignement et indique où sont les hostiles, combien, avec quels vaisseaux et à quelle distance."
    }
    var enableToggle: String { "Afficher l’overlay de renseignement" }
    var statusLabel: String { "État" }
    var channelsHelp: String { "Choisissez les canaux où les hostiles sont signalés." }

    // MARK: 我的位置
    var locationHeader: String { "Ma position" }
    var locationHelp: String {
        "La position provient des sauts enregistrés dans le journal de jeu et du journal du canal Local. "
            + "Saisissez-la ici si aucun des deux n’est disponible."
    }
    var locationUnknown: String { "Inconnue" }
    func locationValue(system: String, source: String, age: String) -> String {
        "\(system) (\(source), il y a \(age))"
    }
    var sourceGameLog: String { "journal de jeu" }
    var sourceLocal: String { "canal Local" }
    var sourceManual: String { "manuelle" }
    var systemPlaceholder: String { "Saisissez un nom de système puis appuyez sur Retour" }
    var clearLocation: String { "Effacer" }
    var systemNotFound: String { "Système introuvable" }
    var noOnlineCharacters: String { "Aucun personnage en ligne" }
    var referenceSystem: String { "Système de référence" }
    var referenceSystemHelp: String {
        "Les sauts sont comptés depuis le système de référence quand la position d’un personnage est inconnue."
    }

    // MARK: 显示
    var displayHeader: String { "Affichage" }
    var windowMinutes: String { "Conserver les dernières" }
    func minutes(_ count: Int) -> String { "\(count) min" }
    var maxJumps: String { "Compter jusqu’à" }
    func jumpsUnit(_ count: Int) -> String { "\(count) \(intelFrenchPlural(count, singular: "saut", plural: "sauts"))" }
    var alertJumps: String { "Surligner dans un rayon de" }
    var alertJumpsHelp: String {
        "Les signalements à ce nombre de sauts ou moins sont surlignés. Mettez 0 pour désactiver le surlignage."
    }
    var showOriginal: String { "Afficher le texte original" }

    // MARK: 星图数据与页尾
    var staticDataLabel: String { "Données de carte" }
    func staticDataBuild(_ build: Int) -> String { "Version SDE \(build)" }
    var staticDataMissing: String { "Données de carte absentes : systèmes et vaisseaux non reconnus" }
    var footnote: String {
        "Cette fonction lit uniquement les journaux de discussion et de jeu et n’envoie aucune saisie au jeu. "
            + "Les noms de pilotes et les effectifs sont déduits du format des messages et peuvent être faux. "
            + "La vérification en ligne indique seulement qu’un personnage porte ce nom, "
            + "pas que le message parle de ce personnage."
    }

    // MARK: 浮窗的标题与状态行
    func overlayTitle(_ character: String) -> String { "Renseignement · \(character)" }
    var statusNoStaticData: String { "Données de carte absentes" }
    var statusNoChannels: String { "Aucun canal de renseignement choisi" }
    var statusLocationUnknown: String { "Position inconnue ; clic droit pour ouvrir les réglages" }
    func statusUsingReference(_ system: String) -> String { "Position inconnue ; calcul depuis \(system)" }
    func statusLocation(system: String, source: String, age: String) -> String {
        "Position : \(system) (\(source), il y a \(age))"
    }

    // MARK: 浮窗每一行
    func ageSeconds(_ count: Int) -> String { "\(count) s" }
    func ageMinutes(_ count: Int) -> String { "\(count) min" }
    func jumps(_ count: Int) -> String { "\(count) s." }
    var jumpsHere: String { "ici" }
    func jumpsBeyond(_ limit: Int) -> String { ">\(limit) s." }
    var jumpsUnreachable: String { "sans portail" }
    var jumpsUnknown: String { "?" }
    func count(_ value: Int) -> String { "×\(value)" }
    func countInferred(_ value: Int) -> String { "~×\(value)" }
    var clear: String { "clair" }
    var noVisual: String { "non visible" }

    // MARK: 人名核对
    var resolvePilotsToggle: String { "Vérification des noms en ligne (ESI)" }
    var resolvePilotsHelp: String {
        "Quand plusieurs noms avec des espaces se suivent, demande à l’API ESI de CCP à quels personnages ils "
            + "correspondent. Seuls ces mots sont envoyés, pas l’auteur du message, le nom du canal ni les noms de "
            + "vos personnages. Les noms d’un seul mot ne sont pas vérifiés."
    }
    var pilotLookupLabel: String { "Vérification des noms" }
    func pilotLookupIdle(_ count: Int) -> String {
        "Prêt, \(count) \(intelFrenchPlural(count, singular: "nom enregistré", plural: "noms enregistrés"))"
    }
    var pilotLookupResolving: String { "Vérification en cours" }
    func pilotLookupWaiting(_ seconds: Int) -> String { "ESI indisponible ; nouvel essai dans \(seconds) s" }
    var clearPilotCache: String { "Vider le cache des noms" }
    func pilotCacheCount(_ count: Int) -> String {
        "\(count) \(intelFrenchPlural(count, singular: "nom enregistré", plural: "noms enregistrés"))"
    }
}
