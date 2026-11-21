// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域的西班牙文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与菜单栏一致：superposición、canal、«Bloquear disposición»。西班牙文只区分单数与复数。

import Foundation

/// 浮窗与两页共用设置控件的西班牙文文字。
struct OverlayStringsES: OverlayStrings {
    // MARK: 浮窗的列表
    func newMessages(_ count: Int) -> String { count == 1 ? "1 nuevo" : "\(count) nuevos" }
    var noActiveCharacter: String { "No hay ningún personaje en la ventana actual" }
    var emptyList: String { "Todavía no hay mensajes" }

    // MARK: 浮窗的右键菜单
    var menuScrollToLatest: String { "Desplazar a lo más reciente" }
    var menuCopyLine: String { "Copiar esta línea" }
    var menuOpenInBrowser: String { "Abrir en el navegador" }
    var menuClear: String { "Vaciar lista" }
    var menuLockLayout: String { "Bloquear disposición" }
    var menuResetFrame: String { "Restablecer posición y tamaño" }
    var menuHide: String { "Ocultar esta superposición" }
    var menuOpenSettings: String { "Abrir ajustes…" }

    // MARK: 浮窗设置
    var overlayHeader: String { "Superposición" }
    var opacity: String { "Opacidad del fondo" }
    var fontSize: String { "Tamaño de letra" }
    var resetFrame: String { "Restablecer posición" }
    var gestureHelp: String { "Arrastra con el botón derecho, o con Opción y el botón izquierdo, para mover la superposición; arrastra un borde para cambiar el tamaño; desplázate para recorrer la lista." }

    // MARK: 频道列表
    var channelsHeader: String { "Canales" }
    var addFromLogs: String { "Añadir desde los registros" }
    var addByNamePlaceholder: String { "Escribe el nombre de un canal y pulsa Retorno" }
    var removeChannel: String { "Quitar" }
    var noChannels: String { "Todavía no hay canales" }
    var refreshChannels: String { "Actualizar" }
    var noDiscoveredChannels: String { "No se encontraron registros de chat recientes" }
    func channelListeners(_ count: Int) -> String { count == 1 ? "1 personaje" : "\(count) personajes" }

    // MARK: 内置频道
    var builtInLocal: String { "Local" }
    var builtInCorp: String { "Corporación" }
    var builtInAlliance: String { "Alianza" }
    var builtInFleet: String { "Flota" }
}
