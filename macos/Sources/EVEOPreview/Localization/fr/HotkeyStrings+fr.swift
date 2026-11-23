// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的法文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：热键 raccourci，循环组 groupe de cycle，缩略图 vignette，客户端 client，
// 鼠标按键 bouton de souris，辅助功能 Accessibilité（macOS 法文版的官方名称），作用范围 portée。
// 键名（Control、Option、Command、Esc、Delete、F1–F20）与英文一致，不改写成法文键盘上的叫法。
// 法文普遍比英文长；热键问题显示在按钮左侧的同一行，所以那几条尽量写短。

import Foundation

/// 热键域的法文实现。
struct HotkeyStringsFR: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String {
        "Groupes de cycle et raccourcis. Chaque raccourci a une seule portée : Global (y compris dans EVE) ou Seulement dans EVE."
    }
    var cycleGroupsHeader: String { "Groupes de cycle" }
    var addGroup: String { "Nouveau groupe de cycle" }
    var noGroups: String { "Aucun groupe de cycle pour l'instant." }
    var groupName: String { "Nom" }
    var deleteGroup: String { "Supprimer le groupe" }
    // 方向与设置域的 forward / backward（Suivant / Précédent）一致。
    var forwardHotkeys: String { "Raccourcis « suivant »" }
    var backwardHotkeys: String { "Raccourcis « précédent »" }
    var noMembers: String { "Aucun membre pour l'instant." }
    var addMember: String { "Ajouter un membre" }
    func newGroupName(_ index: Int) -> String { "Groupe \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "Raccourcis des personnages" }
    // 与英文一样避开「全局」：Global 已是作用范围的名称。
    var globalHotkeysHeader: String { "Raccourcis généraux" }
    var hotkeyToggleHideAll: String { "Afficher ou masquer toutes les vignettes" }
    var hotkeyMinimizeAll: String { "Réduire tous les clients" }
    var hotkeyCycleLogin: String { "Parcourir les clients sur l'écran de connexion" }
    var hotkeyRulesHint: String {
        "Les raccourcis clavier nécessitent Control, Option ou Command, sauf F1–F20 et les chiffres du pavé "
            + "numérique. Les boutons central et latéraux de la souris peuvent être utilisés seuls ; "
            + "le clic n'est pas transmis au jeu."
    }
    var mouseHotkeyHint: String {
        "Les raccourcis souris nécessitent l'autorisation Accessibilité. Un bouton de souris réglé sur "
            + "« Global » est intercepté dans toutes les apps. Supprimez d'abord les autres attributions "
            + "de ce bouton dans le jeu ou dans le logiciel de votre souris."
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "Portée par défaut des raccourcis" }
    var scopeGlobal: String { "Global" }
    var scopeGame: String { "Seulement dans EVE" }
    var scopeGlobalOption: String { "Global : fonctionne dans toutes les apps, y compris EVE" }
    var scopeGameOption: String {
        "Seulement dans EVE : fonctionne uniquement quand une fenêtre EVE est au premier plan"
    }
    var defaultScopeFooter: String {
        "Chaque raccourci a une seule portée, jamais les deux. L'étiquette à droite de chaque raccourci indique la portée qu'il utilise réellement. Cliquez dessus pour choisir pour ce raccourci Global, Seulement dans EVE ou la valeur par défaut choisie ici."
    }
    func scopeFollowDefault(_ current: String) -> String { "Par défaut (\(current))" }
    func scopeMenuHelp(_ resolved: String) -> String { "Portée : \(resolved). Cliquez pour la modifier pour ce raccourci." }
    var menuHotkeysOnlyInEVE: String { "Raccourcis seulement dans EVE" }

    // MARK: 录制器

    var addHotkey: String { "+ Ajouter" }
    var recordingPrompt: String {
        "Appuyez sur des touches ou un bouton latéral de souris (pointeur dans cette fenêtre)…"
    }
    var recorderHelp: String {
        "Cliquez, puis appuyez sur une combinaison de touches ou sur le bouton central ou latéral de la souris. "
            + "Esc annule, Delete efface."
    }
    var removeHotkey: String { "Supprimer ce raccourci" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "Non reconnu" }
    var hotkeyMissingModifier: String { "Modificateur requis" }
    var hotkeyReserved: String { "Réservé par macOS" }
    var hotkeyAccessibilityRequired: String { "Accessibilité requise" }
    var hotkeyEventTapUnavailable: String { "Souris non surveillable" }
    func hotkeyDuplicate(_ other: String) -> String { "Déjà utilisé par \(other)" }
    // status 是 Carbon 的错误码，原样显示。
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "Échec de l'enregistrement (\(status))" }
}
