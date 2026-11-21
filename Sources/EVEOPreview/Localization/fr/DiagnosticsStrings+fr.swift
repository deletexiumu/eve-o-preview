// SPDX-License-Identifier: GPL-3.0-or-later
//
// 诊断域的法文文字（v1.1 设计 11.4 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 11.3 节的词表：rapport、rapport de plantage、journal、marqueur（脱敏后的占位符）；
// 菜单项「报告问题…」用 « Signaler un problème… »，GitHub 的 issue 保留英文词（法语开发者的通行说法）。
// 法文的 0 与 1 用单数，由 replacements 处理。

import Foundation

/// 诊断域的法文文字。
struct DiagnosticsStringsFR: DiagnosticsStrings {
    // MARK: 菜单栏菜单
    var menuReportProblem: String { "Signaler un problème…" }
    var menuCrashPending: String { "EVE-O Preview a quitté inopinément — Signaler…" }

    // MARK: 「通用」页的诊断一组
    var sectionHeader: String { "Diagnostic" }
    var verboseLoggingToggle: String { "Journalisation détaillée" }
    var verboseLoggingHelp: String {
        "Écrit plus de détails dans le fichier journal. Activez-la avant de reproduire un problème."
    }
    var logLocationLabel: String { "Fichiers journaux" }
    var showLogsButton: String { "Afficher les journaux dans le Finder" }
    var reportButton: String { "Signaler un problème…" }

    // MARK: 报告窗口的说明
    var windowTitle: String { "Signaler un problème" }
    var intro: String {
        "Un fichier zip contenant les éléments ci-dessous va être créé. Rien n'est envoyé automatiquement : "
            + "vous joignez vous-même le fichier à une issue GitHub."
    }
    var crashIntro: String {
        "EVE-O Preview a quitté inopinément la dernière fois. Un rapport aide à en corriger la cause."
    }
    var redactionNote: String {
        "Votre nom d'utilisateur macOS, le nom de l'ordinateur et les noms de vos personnages EVE "
            + "sont remplacés par des marqueurs."
    }

    // MARK: 报告窗口的文件列表与预览
    var itemsHeader: String { "Contenu du rapport" }
    var itemSummary: String { "Résumé de l'environnement" }
    var itemConfig: String { "Réglages (sans noms)" }
    var itemLog: String { "Journal de l'app" }
    func itemCrash(_ number: Int) -> String { "Rapport de plantage \(number)" }
    var itemManifest: String { "Liste des fichiers" }
    var previewTruncated: String { "Seul le début est affiché. Le rapport contient le fichier entier." }
    // 0 remplacement、1 remplacement、2 remplacements。
    func replacements(_ count: Int) -> String {
        abs(count) < 2 ? "\(count) remplacement" : "\(count) remplacements"
    }
    var collecting: String { "Collecte…" }

    // MARK: 报告窗口的按钮
    var createAndOpenButton: String { "Créer le rapport et ouvrir GitHub" }
    var createOnlyButton: String { "Créer le rapport seulement" }
    var cancelButton: String { "Annuler" }
    var notNowButton: String { "Plus tard" }
    var dontReportButton: String { "Ne pas signaler" }

    // MARK: 完成页
    var doneTitle: String { "Rapport créé" }
    var doneHelp: String {
        "Le Finder affiche le fichier zip. Faites-le glisser dans la page de l'issue dans votre navigateur, "
            + "décrivez ce qui s'est passé, puis envoyez."
    }
    var revealButton: String { "Afficher dans le Finder" }
    var openIssueButton: String { "Rouvrir GitHub" }
    var closeButton: String { "Fermer" }

    // MARK: 错误
    // reason 是系统给的说明，不翻译。
    func createFailed(_ reason: String) -> String { "Impossible de créer le rapport : \(reason)" }
}
