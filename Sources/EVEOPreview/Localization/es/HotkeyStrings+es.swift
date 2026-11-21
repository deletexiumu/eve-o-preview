// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的西班牙文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：热键 atajo（含鼠标按键，所以不写「atajo de teclado」），循环组 grupo de ciclo，
// 缩略图 miniatura，客户端 cliente，鼠标按键 botón del ratón，辅助功能 Accesibilidad（macOS 西班牙文的官方名称）。
// 作用范围写 ámbito，「全局」写 Global，「仅游戏内」写 Solo en EVE（第 13 节的术语）。
// 修饰键用 macOS 西班牙文的键名 Control、Opción、Comando；删除键写 Eliminar。
// 热键问题显示在按钮左侧的同一行，所以那几条尽量写短。

import Foundation

/// 热键域的西班牙文实现。
struct HotkeyStringsES: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String { "Grupos de ciclo y atajos. Cada atajo funciona en todas partes o solo en EVE." }
    var cycleGroupsHeader: String { "Grupos de ciclo" }
    var addGroup: String { "Nuevo grupo de ciclo" }
    var noGroups: String { "Aún no hay grupos de ciclo." }
    var groupName: String { "Nombre" }
    var deleteGroup: String { "Eliminar grupo" }
    var forwardHotkeys: String { "Atajos hacia delante" }
    var backwardHotkeys: String { "Atajos hacia atrás" }
    var noMembers: String { "Aún no hay miembros." }
    var addMember: String { "Añadir miembro" }
    func newGroupName(_ index: Int) -> String { "Grupo \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "Atajos de personaje" }
    var globalHotkeysHeader: String { "Atajos generales" }
    var hotkeyToggleHideAll: String { "Mostrar u ocultar todas las miniaturas" }
    var hotkeyMinimizeAll: String { "Minimizar todos los clientes" }
    var hotkeyCycleLogin: String { "Recorrer clientes en inicio de sesión" }
    var hotkeyRulesHint: String {
        "Los atajos de teclado necesitan Control, Opción o Comando, salvo F1–F20 y los números del teclado numérico. "
            + "Los botones central y laterales del ratón pueden usarse solos; el clic no llega al juego."
    }
    var mouseHotkeyHint: String {
        "Los atajos de ratón necesitan el permiso “Accesibilidad”. Un botón del ratón con ámbito “Global” "
            + "se intercepta en todas las apps. Quita antes otras asignaciones del botón en el juego "
            + "o en el software del ratón."
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "Ámbito predeterminado de los atajos" }
    var scopeGlobal: String { "Global" }
    var scopeGame: String { "Solo en EVE" }
    func scopeFollowDefault(_ current: String) -> String { "Usar predeterminado (\(current))" }
    func scopeMenuHelp(_ resolved: String) -> String { "Ámbito: \(resolved)" }
    var menuHotkeysOnlyInEVE: String { "Atajos solo en EVE" }

    // MARK: 录制器

    var addHotkey: String { "+ Añadir" }
    var recordingPrompt: String { "Pulsa teclas o un botón lateral del ratón (puntero en esta ventana)…" }
    var recorderHelp: String {
        "Haz clic y pulsa una combinación de teclas o el botón central o uno lateral del ratón. "
            + "Esc cancela y Eliminar borra."
    }
    var removeHotkey: String { "Eliminar este atajo" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "No reconocido" }
    var hotkeyMissingModifier: String { "Falta un modificador" }
    var hotkeyReserved: String { "Reservado por macOS" }
    var hotkeyAccessibilityRequired: String { "Requiere Accesibilidad" }
    var hotkeyEventTapUnavailable: String { "No se puede vigilar el ratón" }
    func hotkeyDuplicate(_ other: String) -> String { "Ya lo usa: \(other)" }
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "Error de registro (\(status))" }
}
