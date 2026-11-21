// SPDX-License-Identifier: GPL-3.0-or-later
//
// 法文界面文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见协议里的注释（Strings.swift、SettingsStrings.swift）。
//
// 用词的依据：
// - 反馈文档 5.5 节的词表，法文取：缩略图 vignette、客户端 client、配置方案 profil、
//   循环组 groupe de cycle、边框 bordure、高亮 surbrillance、热键 raccourci。
// - EVE 法文客户端与法语玩家的叫法：角色是 personnage，登录界面是 écran de connexion。
// - macOS 法文的官方名称：「编辑」菜单各项取 AppKit 的 MenuCommands.loctable（Édition、Rétablir 等）；
//   「设置…」菜单项写 Réglages…（macOS 13 起的叫法）；权限名取系统设置
//   （Enregistrement de l'écran、Accessibilité），「系统设置 > 隐私与安全性」是
//   Réglages Système > Confidentialité et sécurité，访达写 le Finder，菜单栏写 barre des menus。
// - 「最小化」写 réduire（Windows 与游戏玩家的通行说法）；macOS 菜单里的 « Placer dans le Dock »
//   指收进 Dock，用在 EVE 客户端上不够直白。
// - 应用写 app（Apple 法文文档的写法），版本写 version。
//
// 排版约定（全文一致）：
// - 引号用法文书名号 « »，内侧各留一个普通空格，如 « Documents »。
// - 冒号、分号、问号、感叹号前留一个普通空格（法文排版规则；不用不换行空格，便于比对）。
// - 小数点写逗号（如「2,5 s」），单位用法文缩写：pt（点）、s（秒）、i/s（帧每秒）、ms（毫秒）。
// 法文普遍比英文长约两成；侧栏的页名称只有约 140 点宽，所以「预览与布局」「切换与热键」两页各用一个词。

import Foundation
import EVEOPreviewCore

/// 法文的单复数：0 与 1 用单数，2 及以上用复数（与英文不同，法文的 0 是单数）。
private func frenchPlural(_ count: Int, singular: String, plural: String) -> String {
    abs(count) < 2 ? singular : plural
}

// MARK: - 菜单栏

/// 菜单栏菜单，法文。
struct MenuStringsFR: MenuStrings {
    // 菜单项以动词不定式开头（Afficher、Masquer、Réduire），符合 macOS 法文菜单的写法。
    var showAll: String { "Afficher toutes les vignettes" }
    var hideAll: String { "Masquer toutes les vignettes" }
    var profiles: String { "Profils" }
    var minimizeAll: String { "Réduire tous les clients" }
    var settings: String { "Réglages…" }
    var quit: String { "Quitter EVE-O Preview" }
    var permissionsMissing: String { "Autorisations manquantes…" }
    var fakeMode: String { "Mode démo (clients fictifs)" }
    var noClients: String { "Aucun client EVE trouvé" }
    func resumeCapture(_ title: String) -> String { "Reprendre la capture : \(title)" }
    // 0 client、1 client、2 clients。
    func clientCount(_ count: Int) -> String {
        "\(count) " + frenchPlural(count, singular: "client", plural: "clients")
    }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，法文。全部取 macOS 法文的菜单名。
struct EditMenuStringsFR: EditMenuStrings {
    var title: String { "Édition" }
    // Annuler 在 macOS 法文里既是「撤销」也是对话框的「取消」，与系统一致，不另作区分。
    var undo: String { "Annuler" }
    var redo: String { "Rétablir" }
    var cut: String { "Couper" }
    var copy: String { "Copier" }
    var paste: String { "Coller" }
    var selectAll: String { "Tout sélectionner" }
    var closeWindow: String { "Fermer la fenêtre" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，法文。
struct ThumbnailStringsFR: ThumbnailStrings {
    // 右键菜单：动词不定式，与菜单栏菜单一致。
    var minimize: String { "Réduire" }
    var minimizeAll: String { "Tout réduire" }
    var skipCycle: String { "Ignorer dans le cycle" }
    var hide: String { "Masquer cette vignette" }
    var resetSize: String { "Rétablir la taille par défaut" }
    var resumeCapture: String { "Reprendre la capture" }
    // 既接在不可用的菜单项后面（「Réduire (Accessibilité requise)」），也用在热键问题提示里，所以写成名词短语。
    var needsAccessibility: String { "Accessibilité requise" }
    func unavailable(_ item: String, reason: String) -> String { "\(item) (\(reason))" }
    var settings: String { "Réglages…" }
    // 占位文字：缩略图很小，尽量短。
    var waiting: String { "En attente d'images…" }
    var needsScreenRecording: String { "Autorisation « Enregistrement de l'écran » requise" }
    var captureStopped: String { "Capture arrêtée. Clic droit pour reprendre." }
    var minimized: String { "Réduit" }
}

// MARK: - 设置窗口

/// 设置窗口，法文。单位用法文缩写：pt（点）、s（秒）、i/s（images par seconde，帧每秒）、ms（毫秒）。
struct SettingsStringsFR: SettingsStrings {
    // 窗口与通用。
    var windowTitle: String { "Réglages d'EVE-O Preview" }
    var points: String { "pt" }
    var reset: String { "Réinitialiser" }
    var defaultColor: String { "Par défaut" }
    var cancel: String { "Annuler" }
    var confirm: String { "OK" }
    var delete: String { "Supprimer" }
    var online: String { "En ligne" }
    var offline: String { "Hors ligne" }
    // 循环方向接在循环组名后面（如「Groupe 1 · Suivant」），所以用「下一个 / 上一个」。
    var forward: String { "Suivant" }
    var backward: String { "Précédent" }
    /// 法文的小数点是逗号（如「1,5 s」），用 fr 区域的数字格式，不用 `String(format:)` 的英文小数点。
    func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr"))) + " s"
    }
    func fps(_ value: Double) -> String { String(format: "%.0f i/s", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
    var fakeModeNotice: String { "Mode démo : les vignettes proviennent de clients fictifs. Basculer et réduire ne modifient que les données de démo." }
    // 「schema 版本」译作「格式」，避免与应用自己的版本号混淆。
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "Le fichier de configuration est au format \(found) ; cette version gère jusqu'au format \(supported). "
            + "Réglages par défaut utilisés ; les modifications ne seront pas enregistrées."
    }
    func loadFailedNotice(_ message: String) -> String {
        "Impossible de lire le fichier de configuration (\(message)). "
            + "Réglages par défaut utilisés ; les modifications ne seront pas enregistrées."
    }
    func quarantinedNotice(_ path: String) -> String {
        "Le fichier de configuration était corrompu et a été déplacé vers \(path). Réglages par défaut utilisés."
    }
    // 放进 loadFailedNotice 的括号里，所以小写开头。
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "échec de la lecture de \(path) : \(reason)"
        case .write: return "échec de l'écriture de \(path) : \(reason)"
        case .quarantine: return "échec de la mise à l'écart du fichier corrompu \(path) : \(reason)"
        case .backup: return "échec de la sauvegarde de l'ancienne configuration vers \(path) : \(reason)"
        }
    }
    var configContentInvalid: String { "le contenu du fichier n'est pas une configuration valide" }

    // 页名称：侧栏窄，「预览与布局」写 Vignettes，「切换与热键」写 Raccourcis（循环组本身也靠热键驱动）。
    var pageClients: String { "Clients" }
    var pagePreviews: String { "Vignettes" }
    var pageSwitching: String { "Raccourcis" }
    var pageAlerts: String { "Alertes" }
    var pageProfiles: String { "Profils" }
    var pageGeneral: String { "Général" }
    var pagePermissions: String { "Autorisations" }
    var pageAbout: String { "À propos" }

    // 客户端页。
    // 「全部隐藏」是会话开关，「显示缩略图」是按角色的持久化开关：分别写 Masquer toutes les vignettes 与 Afficher la vignette。
    var clientsSubtitle: String { "Clients en cours d'exécution et personnages connus de ce profil." }
    var hideAllThumbnails: String { "Masquer toutes les vignettes" }
    var hideAllHotkeyLabel: String { "Raccourci" }
    var hideAllScopeLabel: String { "Portée" }
    // 修饰键与鼠标按键的符号（⌃⌥⌘H）原样保留。
    var hideAllHotkeyFooter: String {
        "Utilisez des touches de modification avec une touche (comme ⌃⌥⌘H), ou avec le bouton central ou un bouton latéral de la souris. Tous les raccourcis ci-dessus utilisent la portée unique choisie ici."
    }
    var charactersHeader: String { "Personnages" }
    var charactersFooter: String { "Cette couleur sert à la bordure de surbrillance quand le personnage est actif." }
    var noCharacters: String { "Aucun personnage pour l'instant. Lancez EVE et connectez un personnage." }
    var loginClientsHeader: String { "Clients sur l'écran de connexion" }
    var showThumbnail: String { "Afficher la vignette" }
    var highlightColorHelp: String { "Couleur de surbrillance quand le personnage est actif" }

    // 预览与布局页。表单行的标签在左，控件在右，标签尽量短。
    var previewsSubtitle: String { "Taille, apparence et comportement des vignettes. Les modifications s'appliquent immédiatement." }
    var defaultSize: String { "Taille par défaut" }
    var minimumSize: String { "Taille minimale" }
    var maximumSize: String { "Taille maximale" }
    var unifySizes: String { "Remettre toutes les vignettes à la taille par défaut" }
    // border 统一写 bordure，highlight 统一写 surbrillance，两者不混用。
    var appearanceHeader: String { "Apparence" }
    var opacity: String { "Opacité" }
    var showTitle: String { "Afficher le nom du personnage" }
    var titleFontSize: String { "Taille de police du nom" }
    var titleColor: String { "Couleur du nom" }
    var borderEnabled: String { "Afficher la bordure" }
    var borderColor: String { "Couleur de la bordure" }
    var borderThickness: String { "Épaisseur de la bordure" }
    var highlightEnabled: String { "Mettre en surbrillance le client actif" }
    var highlightColor: String { "Couleur de surbrillance" }
    var highlightThickness: String { "Épaisseur de surbrillance" }
    var zoomHeader: String { "Zoom au survol" }
    var zoomEnabled: String { "Zoomer au survol" }
    var zoomFactor: String { "Facteur de zoom" }
    var zoomAnchor: String { "Point d'ancrage" }
    // 「前台」写 au premier plan，与 macOS 法文的说法一致。
    var behaviorHeader: String { "Comportement" }
    var alwaysOnTop: String { "Garder les vignettes au premier plan" }
    var hideActiveClient: String { "Masquer la vignette du client actif" }
    var hideWhenNotEVE: String { "Masquer les vignettes quand EVE n'est pas au premier plan" }
    var hideDelay: String { "Délai de masquage" }
    var layoutHeader: String { "Disposition" }
    // 「吸附」写 aimanter（macOS 法文与常见软件的说法）。
    var snapEnabled: String { "Aimanter pendant le déplacement" }
    var lockAspectRatio: String { "Conserver les proportions au redimensionnement" }
    var lockLayout: String { "Verrouiller la disposition" }
    // 键名 Option、Shift 与英文一致，不改写成 Maj。
    var gestureHint: String {
        "Faites glisser avec le bouton droit ou avec Option pour déplacer ; faites glisser un bord pour "
            + "redimensionner ; maintenez Shift pour désactiver l'aimantation."
    }
    // 坐标标签用冒号分隔，与其他语言的写法一致。
    var captureHeader: String { "Capture et position" }
    var frameRate: String { "Fréquence d'images" }
    var titleBarCrop: String { "Rognage de la barre de titre" }
    var pollInterval: String { "Intervalle d'analyse des fenêtres" }
    var loginPositionX: String { "Vignette de connexion : X" }
    var loginPositionY: String { "Vignette de connexion : Y" }
    // 九宫格的 9 个位置。
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "En haut à gauche"
        case .n: return "En haut"
        case .ne: return "En haut à droite"
        case .w: return "À gauche"
        case .center: return "Au centre"
        case .e: return "À droite"
        case .sw: return "En bas à gauche"
        case .s: return "En bas"
        case .se: return "En bas à droite"
        }
    }

    // 配置方案页。「配置方案」写 profil，「配置文件」写 fichier de configuration（架构文档第 13 节）。
    var profilesSubtitle: String {
        "Chaque profil est un ensemble complet de réglages, de dispositions et de groupes de cycle."
    }
    var activeBadge: String { "Actif" }
    var switchTo: String { "Activer" }
    var rename: String { "Renommer" }
    var clone: String { "Dupliquer" }
    var newProfile: String { "Nouveau profil" }
    var configFile: String { "Fichier de configuration" }
    var revealConfig: String { "Afficher dans le Finder" }
    var profileName: String { "Nom du profil" }
    var profileNameRule: String { "De 1 à 64 caractères, unique parmi les profils (sans tenir compte de la casse)." }
    func deleteProfileConfirm(_ name: String) -> String { "Supprimer le profil « \(name) » ? Cette action est irréversible." }
    // 对话框标题与确认文字里的名称用书名号括起来。
    func cloneTitle(_ name: String) -> String { "Dupliquer « \(name) »" }
    func renameTitle(_ name: String) -> String { "Renommer « \(name) »" }
    // 与 macOS 法文版访达复制文件时的命名一致：「名称 copie」。
    func copyName(_ name: String) -> String { "\(name) copie" }

    // 通用页。
    // 语言选项本身用各语言的自称（AppLanguage.autonym），不翻译；「跟随系统」写 Selon le système。
    var generalSubtitle: String { "Réglages communs à tous les profils." }
    var interfaceLanguage: String { "Langue de l'interface" }
    var followSystem: String { "Selon le système" }
    var machineTranslationNote: String { "Certaines traductions sont générées automatiquement. Les corrections sont les bienvenues." }
    var showDockIcon: String { "Afficher l'icône dans le Dock" }
    var showDockIconHelp: String { "Si cette option est désactivée, EVE-O Preview n'affiche que son icône dans la barre des menus." }

    // 权限页。权限名与系统设置的路径取 macOS 法文版的官方叫法。
    var permissionsSubtitle: String { "Les deux autorisations s'accordent dans Réglages Système > Confidentialité et sécurité." }
    var screenRecording: String { "Enregistrement de l'écran" }
    var screenRecordingDetail: String {
        "Nécessaire pour capturer les fenêtres des clients et lire leurs titres. "
            + "Prend généralement effet après une relance."
    }
    var accessibility: String { "Accessibilité" }
    var accessibilityDetail: String {
        "Nécessaire pour restaurer, mettre au premier plan et réduire les fenêtres des clients, "
            + "ainsi que pour les raccourcis de boutons de souris. Prend effet immédiatement."
    }
    var granted: String { "Autorisé" }
    var notGranted: String { "Non autorisé" }
    var request: String { "Demander" }
    var openSystemSettings: String { "Ouvrir Réglages Système" }
    // 「重新启动」写 relancer（重新打开应用的说法），与更新域自动重启的 redémarrer 区分。
    var relaunchHint: String { "Relancer après avoir accordé « Enregistrement de l'écran »" }
    var relaunch: String { "Relancer" }
    // build、ad hoc 保留英文（法语开发者的通行说法），README 也是这样写。
    var signingHint: String {
        "macOS associe les autorisations à la signature du code. Les builds signées ad hoc doivent être "
            + "réautorisées après chaque recompilation ; le README explique comment utiliser un certificat auto-signé."
    }

    // 关于页。「上游项目」写 projet d'origine。
    var version: String { "Version" }
    var devVersion: String { "Version de développement" }
    var aboutSubtitle: String {
        "Vignettes en direct et bascule rapide entre plusieurs clients EVE Online, en natif sur macOS."
    }
    var aboutSummary: String {
        "Une vignette en direct par client, bascule d'un clic, raccourcis de groupes de cycle "
            + "et plusieurs profils."
    }
    var upstreamHeader: String { "Projet d'origine et licence" }
    var upstreamText: String {
        "Cette app réimplémente en natif pour macOS les fonctionnalités d'EveOPlus/eve-o-preview."
    }
    // 许可证名称 GNU General Public License v3.0 是正式名称，不翻译。
    var licenseText: String {
        "Comme le projet d'origine, elle est publiée sous la GNU General Public License v3.0."
    }
    var disclaimerHeader: String { "Remarques" }
    var focusOnlyText: String {
        "Cet outil ne fait que changer le focus des fenêtres. Il ne diffuse jamais d'entrées vers plusieurs "
            + "clients et ne lit ni ne modifie jamais la mémoire du jeu."
    }
    var gameLogText: String {
        "Les alertes de combat lisent uniquement les journaux de jeu écrits par le client EVE. "
            + "Elles ne lisent jamais la mémoire du jeu, ne modifient aucun fichier et n'envoient aucune entrée."
    }
    // 「通用」用通用页的页名 Général（pageGeneral）。
    var networkText: String {
        "EVE-O Preview ne contacte GitHub que pour rechercher et télécharger les mises à jour ; "
            + "vous pouvez le désactiver dans « Général ». "
            + "Les rapports de problème ne sont jamais envoyés automatiquement."
    }
    var eveIPText: String {
        "EVE Online et les logos associés sont des marques de CCP ehf. "
            + "Ce projet n'est ni affilié à CCP ni approuvé par CCP."
    }
}
