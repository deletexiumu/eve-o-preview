// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的法文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见 UpdateStrings.swift。
// 用词按 v1.1 设计 11.3 节的词表：mise à jour、Rechercher les mises à jour…（macOS 法文版的说法）、
// Nouveautés（发布说明）、Installer la mise à jour、Ignorer cette version、Plus tard、signature；
// 窗口标题取 macOS 法文版的 « Mise à jour de logiciels »；缩略图 vignette（反馈文档 5.5 节）。
// 「重新启动」写 redémarrer；「应用程序」文件夹写 Applications（macOS 法文版的名称）。
// 英文的 build 不好直译，按语境写 cette version 或 cette copie de l'app。
// 本域的文字不带数量，不用处理复数。

import Foundation

/// 更新域的法文实现。
struct UpdateStringsFR: UpdateStrings {
    // MARK: 菜单栏菜单

    // 以省略号结尾的菜单项会打开窗口（macOS 的约定）。
    var menuCheckForUpdates: String { "Rechercher les mises à jour…" }
    func menuUpdateAvailable(_ version: String) -> String { "Mise à jour disponible : \(version)…" }
    func menuRestartToUpdate(_ version: String) -> String { "Redémarrer pour passer à la version \(version)" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "Mises à jour" }
    var autoCheckToggle: String { "Rechercher automatiquement les mises à jour" }
    var autoCheckHelp: String { "Contacte GitHub une fois par jour. Aucune donnée personnelle n'est envoyée." }
    var autoInstallToggle: String { "Installer automatiquement les mises à jour" }
    var autoInstallHelp: String { "Télécharge en arrière-plan. Installe et redémarre quand aucun client EVE n'a tourné depuis une minute, ou installe quand vous quittez EVE-O Preview." }
    var currentVersionLabel: String { "Version actuelle" }
    var lastCheckedLabel: String { "Dernière vérification" }
    var lastCheckedNever: String { "Jamais" }
    var checkNowButton: String { "Rechercher maintenant" }

    // MARK: 状态行

    // 状态行除进度外都是完整的句子，以句号结尾。
    var statusChecking: String { "Recherche…" }
    var statusUpToDate: String { "EVE-O Preview est à jour." }
    func statusAvailable(_ version: String) -> String { "La version \(version) est disponible." }
    func statusReady(_ version: String) -> String { "La version \(version) est téléchargée. Elle sera installée quand aucun client EVE ne sera ouvert, ou quand vous quitterez l'app." }
    // time 已按 fr 区域格式化（如「14:05」或带日期）。
    func statusRateLimited(_ time: String) -> String { "GitHub limite les requêtes. Réessayez après \(time)." }
    var statusRateLimitedLater: String { "GitHub limite les requêtes. Réessayez plus tard." }
    var statusUnavailable: String { "Les mises à jour ne sont pas disponibles dans cette version." }

    // MARK: 更新窗口

    var windowTitle: String { "Mise à jour de logiciels" }
    func headline(_ version: String) -> String { "EVE-O Preview \(version) est disponible" }
    func currentVersionLine(_ version: String) -> String { "Vous avez la version \(version)." }
    var releaseNotesHeader: String { "Nouveautés" }
    func versionNotesTitle(_ version: String) -> String { "Version \(version)" }
    var earlierVersionsOnReleasePage: String { "Les changements des versions précédentes sont sur la page des versions." }
    // 按钮用动词不定式（Installer、Ignorer、Ouvrir），与 macOS 法文按钮的写法一致。
    var installButton: String { "Installer la mise à jour" }
    var installHelp: String { "L'app redémarre après l'installation. Les vignettes disparaissent quelques secondes." }
    var skipButton: String { "Ignorer cette version" }
    var laterButton: String { "Plus tard" }
    var openReleasePageButton: String { "Ouvrir la page de la version" }
    var cancelButton: String { "Annuler" }
    var closeButton: String { "Fermer" }
    var retryButton: String { "Réessayer" }
    // 两个大小已按 fr 区域格式化（如「1,2 Mo」）；总大小未知时只写已下载的大小。
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "Téléchargement… \(received) sur \($0)" } ?? "Téléchargement… \(received)"
    }
    var progressVerifying: String { "Vérification…" }
    var progressInstalling: String { "Installation…" }
    var progressRelaunching: String { "Redémarrage…" }
    var testFeedBadge: String { "Flux de test" }
    var notifyOnlyIntro: String { "Cette copie ne peut pas se mettre à jour elle-même." }
    var currentVersionUnchanged: String { "Votre version actuelle n'a pas été modifiée." }
    var reopenManually: String { "La mise à jour est installée. Quittez EVE-O Preview, puis rouvrez-la." }

    // MARK: 不能自动安装的原因
    // 顺序与英文文件一致（unsupportedVolume 在 readOnlyVolume 前面）。

    // 每条都是完整的句子，说明原因并尽量给出下一步。
    var blockerTranslocated: String {
        "macOS exécute l'app depuis un emplacement temporaire en lecture seule. "
            + "Déplacez-la dans le dossier Applications, puis rouvrez-la."
    }
    var blockerUnsupportedVolume: String {
        "L'app se trouve sur un disque qui n'est pas au format APFS ; les mises à jour ne peuvent donc pas "
            + "être installées depuis l'app. Téléchargez la nouvelle version depuis la page de la version."
    }
    var blockerReadOnlyVolume: String {
        "L'app se trouve sur un disque en lecture seule. Copiez-la d'abord dans le dossier Applications."
    }
    var blockerLocationNotWritable: String {
        "Vous n'avez pas l'autorisation de modifier le dossier qui contient l'app."
    }
    var blockerAdHocSignature: String {
        "Cette copie de l'app n'a pas de signature stable ; une nouvelle version ne peut donc pas être vérifiée."
    }
    var blockerDevelopmentSignature: String { "Il s'agit d'une version de développement signée localement." }
    var blockerUnsigned: String { "Cette copie de l'app n'est pas signée." }

    // MARK: 错误

    // 「无法……」统一写 Impossible de …，与 macOS 法文的错误提示一致。
    var errorNetwork: String { "Impossible de joindre GitHub. Vérifiez votre connexion Internet." }
    // code 是 HTTP 状态码，原样显示。
    func errorHTTPStatus(_ code: Int) -> String { "GitHub a répondu par une erreur (\(code))." }
    var errorMalformedFeed: String { "Impossible de lire les informations de la version." }
    var errorAssetMissing: String {
        "Cette version ne contient pas de programme d'installation pour les mises à jour automatiques."
    }
    var errorDiskSpace: String { "Espace disque insuffisant pour le téléchargement." }
    var errorChecksum: String {
        "Le téléchargement ne correspond pas à sa somme de contrôle et a été supprimé."
    }
    var errorDiskImage: String { "Impossible d'ouvrir l'image disque téléchargée." }
    var errorVerification: String {
        "La nouvelle version n'a pas pu être vérifiée ; elle n'a donc pas été installée."
    }
    func errorUnsupportedSystem(_ minimum: String) -> String {
        "Cette version nécessite macOS \(minimum) ou une version ultérieure."
    }
    var errorSwapFailed: String { "Impossible de remplacer l'app." }
}
