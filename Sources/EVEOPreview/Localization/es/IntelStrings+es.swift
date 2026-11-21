// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警域的西班牙文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与 WP-0 的西班牙文文字一致：inteligencia（预警）、superposición（浮窗）、canal（频道）、registro de chat
// （聊天日志）；跳是 salto，敌对是 hostil，星图数据是 datos del mapa，ESI 不翻译。
// 开关名与 settings.aboutChatLogsNote 里的 comprobación de nombres en línea 一致。

import Foundation

/// 预警域的西班牙文文字。
struct IntelStringsES: IntelStrings {
    // MARK: 页头、开关与频道
    var pageSubtitle: String {
        "Lee los registros de los canales de inteligencia y muestra dónde están los hostiles, cuántos son, en qué naves y a qué distancia."
    }
    var enableToggle: String { "Mostrar superposición de inteligencia" }
    var statusLabel: String { "Estado" }
    var channelsHelp: String { "Elige los canales donde se informa de hostiles." }

    // MARK: 我的位置
    var locationHeader: String { "Mi ubicación" }
    var locationHelp: String {
        "La ubicación se obtiene de los saltos registrados en el registro del juego y del registro del canal Local. "
            + "Si no hay ninguno de los dos, escríbela aquí."
    }
    var locationUnknown: String { "Desconocida" }
    func locationValue(system: String, source: String, age: String) -> String { "\(system) (\(source), hace \(age))" }
    var sourceGameLog: String { "registro del juego" }
    var sourceLocal: String { "canal Local" }
    var sourceManual: String { "manual" }
    var systemPlaceholder: String { "Escribe el nombre de un sistema y pulsa Retorno" }
    var clearLocation: String { "Borrar" }
    var systemNotFound: String { "No se encuentra el sistema" }
    var noOnlineCharacters: String { "No hay personajes conectados" }
    var referenceSystem: String { "Sistema de referencia" }
    var referenceSystemHelp: String {
        "Cuando no se conoce la ubicación de un personaje, los saltos se cuentan desde el sistema de referencia."
    }

    // MARK: 显示
    var displayHeader: String { "Visualización" }
    var windowMinutes: String { "Conservar los últimos" }
    func minutes(_ count: Int) -> String { "\(count) min" }
    var maxJumps: String { "Contar hasta" }
    func jumpsUnit(_ count: Int) -> String { count == 1 ? "1 salto" : "\(count) saltos" }
    var alertJumps: String { "Resaltar a menos de" }
    var alertJumpsHelp: String {
        "Se resaltan los informes a este número de saltos o menos. Pon 0 para no resaltar."
    }
    var showOriginal: String { "Mostrar el texto original" }

    // MARK: 星图数据与页尾
    var staticDataLabel: String { "Datos del mapa" }
    func staticDataBuild(_ build: Int) -> String { "Versión de SDE \(build)" }
    var staticDataMissing: String { "Faltan los datos del mapa; no se reconocen sistemas ni naves" }
    var footnote: String {
        "Esta función solo lee los registros de chat y del juego y no envía ninguna entrada al juego. "
            + "Los nombres de pilotos y las cantidades se deducen del formato del mensaje y pueden ser erróneos. "
            + "La comprobación en línea solo indica que existe un personaje con ese nombre, "
            + "no que el mensaje se refiera a ese personaje."
    }

    // MARK: 浮窗的标题与状态行
    func overlayTitle(_ character: String) -> String { "Inteligencia · \(character)" }
    var statusNoStaticData: String { "Faltan los datos del mapa" }
    var statusNoChannels: String { "No hay canales de inteligencia" }
    var statusLocationUnknown: String { "Ubicación desconocida; haz clic derecho para abrir los ajustes" }
    func statusUsingReference(_ system: String) -> String { "Ubicación desconocida; contando desde \(system)" }
    func statusLocation(system: String, source: String, age: String) -> String {
        "Ubicación: \(system) (\(source), hace \(age))"
    }

    // MARK: 浮窗每一行
    func ageSeconds(_ count: Int) -> String { "\(count) s" }
    func ageMinutes(_ count: Int) -> String { "\(count) min" }
    func jumps(_ count: Int) -> String { "\(count) s." }
    var jumpsHere: String { "aquí" }
    func jumpsBeyond(_ limit: Int) -> String { ">\(limit) s." }
    var jumpsUnreachable: String { "sin portales" }
    var jumpsUnknown: String { "?" }
    func count(_ value: Int) -> String { "×\(value)" }
    func countInferred(_ value: Int) -> String { "~×\(value)" }
    var clear: String { "despejado" }
    var noVisual: String { "sin visual" }

    // MARK: 人名核对
    var resolvePilotsToggle: String { "Comprobación de nombres en línea (ESI)" }
    var resolvePilotsHelp: String {
        "Cuando varios nombres con espacios aparecen seguidos, pregunta a la API ESI de CCP a qué personajes "
            + "corresponden. Solo se envían esas palabras, no el autor, el nombre del canal ni los nombres de tus "
            + "personajes. Los nombres de una sola palabra no se consultan."
    }
    var pilotLookupLabel: String { "Comprobación de nombres" }
    func pilotLookupIdle(_ count: Int) -> String {
        count == 1 ? "Listo, 1 nombre guardado" : "Listo, \(count) nombres guardados"
    }
    var pilotLookupResolving: String { "Comprobando" }
    func pilotLookupWaiting(_ seconds: Int) -> String { "ESI no disponible; reintento en \(seconds) s" }
    var clearPilotCache: String { "Vaciar caché de nombres" }
    func pilotCacheCount(_ count: Int) -> String {
        count == 1 ? "1 nombre guardado" : "\(count) nombres guardados"
    }
}
