// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的法文文字（反馈文档 5.3 节、7.11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：alerte de combat、journal de jeu、vignette；「闪烁」写 clignoter / clignotement。
// 系统权限用 macOS 法文界面的「Fichiers et dossiers」，「文稿」文件夹写 « Documents »。
// 法文的 0 与 1 用单数，由 fileCount 处理；秒数的小数点写逗号。

import Foundation

/// 「提醒」页的法文文字。
struct CombatStringsFR: CombatStrings {
    // MARK: 页头
    var pageSubtitle: String { "Fait clignoter la vignette d'un personnage quand il est attaqué." }

    // MARK: 开关与状态行
    // 状态行显示目录全路径，文字保持短。
    var enableToggle: String { "Faire clignoter la vignette quand un personnage est attaqué" }
    var statusLabel: String { "État" }
    var statusStopped: String { "Désactivé" }
    func statusWatching(directory: String, files: Int) -> String {
        "Surveillance de \(fileCount(files)) dans \(directory)"
    }
    func statusDirectoryNotFound(_ path: String) -> String { "Dossier des journaux de jeu introuvable : \(path)" }
    func statusAccessDenied(_ path: String) -> String { "Lecture non autorisée : \(path)" }
    var accessDeniedHelp: String {
        "Autorisez EVE-O Preview à accéder au dossier « Documents » dans "
            + "Réglages Système > Confidentialité et sécurité > Fichiers et dossiers."
    }
    var openSystemSettings: String { "Ouvrir Réglages Système…" }

    // MARK: 日志目录
    // 文件夹名 logs、Gamelogs 是磁盘上的真实名称，不翻译。
    var logDirectoryHeader: String { "Journaux de jeu" }
    var logDirectoryLabel: String { "Dossier" }
    var automaticSuffix: String { "(automatique)" }
    var chooseDirectory: String { "Choisir…" }
    var useAutomaticLocation: String { "Utiliser l'emplacement automatique" }
    var chooseDirectoryMessage: String { "Choisissez le dossier « logs » ou « Gamelogs » d'EVE." }

    // MARK: 闪烁的外观
    var appearanceHeader: String { "Clignotement" }
    var flashColor: String { "Couleur du clignotement" }
    var duration: String { "Durée" }
    /// 数字部分由各语言共用的 `combatSecondsNumber` 给出（英文小数点），法文把小数点换成逗号，如「2,5 s」。
    func seconds(_ value: Double) -> String {
        "\(combatSecondsNumber(value).replacingOccurrences(of: ".", with: ",")) s"
    }
    var style: String { "Style" }
    var styleBorder: String { "Bordure" }
    var styleWash: String { "Teinte" }
    var styleBoth: String { "Les deux" }

    // MARK: 触发条件
    var triggersHeader: String { "Déclencheurs" }
    var includeMisses: String { "Alerter aussi pour les attaques manquées" }
    var minimumDamage: String { "Dégâts minimum" }
    var minimumDamageHelp: String {
        "Les coups en dessous de cette valeur sont ignorés. Les attaques manquées suivent l'option ci-dessus."
    }

    // MARK: 测试与说明
    var testFlash: String { "Tester le clignotement" }
    var testFlashHelp: String { "Fait clignoter chaque vignette une fois, même si l'alerte est désactivée." }
    var footnote: String {
        "Le client EVE doit être réglé pour enregistrer les messages du jeu dans des fichiers journaux. "
            + "Cette fonction lit uniquement les journaux de jeu et n'envoie jamais aucune entrée au jeu."
    }

    /// 「N 个日志文件」：0 与 1 用单数 fichier journal，2 及以上用复数 fichiers journaux。
    private func fileCount(_ n: Int) -> String {
        abs(n) < 2 ? "\(n) fichier journal" : "\(n) fichiers journaux"
    }
}
