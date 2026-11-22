// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的西班牙文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按第 11 节的词表：superposición（浮窗）、canal（频道）、servicio de modelo（模型服务）；
// 钥匙串用 macOS 西班牙文界面的官方名称「llavero」。

import Foundation

/// 翻译域的西班牙文文字。
struct TranslationStringsES: TranslationStrings {
    // MARK: 页头与状态
    var pageSubtitle: String { "Traduce los mensajes en otros idiomas de los canales elegidos." }
    var enableToggle: String { "Mostrar superposición de traducción" }
    var statusLabel: String { "Estado" }
    var statusOff: String { "Desactivado" }
    var statusIdle: String { "Listo" }
    var statusTranslating: String { "Traduciendo" }
    func statusWaiting(seconds: Int, reason: String) -> String { "Reintento en \(seconds) s: \(reason)" }
    func statusBlocked(_ reason: String) -> String { "En pausa: \(reason)" }
    var retryNow: String { "Reintentar ahora" }

    // MARK: 失败的原因
    var failureMissingBaseURL: String { "No se ha indicado la dirección de la API" }
    var failureMissingModel: String { "No se ha indicado el nombre del modelo" }
    var failureInvalidURL: String { "La dirección de la API no es válida" }
    var failureInsecureHTTP: String { "Las direcciones http solo se permiten para este Mac o la red local" }
    var failureMissingKey: String { "No se ha indicado la clave de API" }
    var failureKeychain: String {
        "No se puede leer la clave del llavero; guárdala de nuevo en la página Traducción"
    }
    func failureUnauthorized(status: Int) -> String { "La clave fue rechazada (HTTP \(status))" }
    var failureNotFound: String { "Dirección de la API o nombre del modelo incorrecto (HTTP 404)" }
    var failureBalance: String { "Saldo insuficiente (HTTP 402)" }
    func failureRejected(status: Int, message: String) -> String {
        message.isEmpty ? "Solicitud rechazada (HTTP \(status))" : "Solicitud rechazada (HTTP \(status)): \(message)"
    }
    var failureRateLimited: String { "Demasiadas solicitudes o cuota agotada (HTTP 429)" }
    func failureServer(status: Int) -> String { "Error del servicio de modelo (HTTP \(status))" }
    var failureNetwork: String { "No se puede conectar con el servicio de modelo" }
    var failureMalformed: String { "El modelo no respondió en el formato esperado" }
    var failureRefused: String { "El modelo rechazó estos mensajes" }
    var failureTruncated: String { "La respuesta del modelo quedó cortada" }

    // MARK: 频道与目标语言
    var channelsHelp: String { "Elige los canales que se traducirán." }
    var targetHeader: String { "Idioma de destino" }
    var targetLanguage: String { "Traducir al" }
    var targetFollowUI: String { "Igual que el idioma de la interfaz" }
    var showOriginal: String { "Mostrar también el texto original" }
    var foreignOnly: String { "Mostrar solo los mensajes traducidos" }

    // MARK: 模型服务
    var modelHeader: String { "Modelo" }
    var provider: String { "Servicio" }
    var providerCustom: String { "Otro (compatible con OpenAI)" }
    var baseURL: String { "Dirección de la API" }
    var model: String { "Nombre del modelo" }
    var apiKey: String { "Clave de API" }
    var apiKeyStored: String { "Guardada en el llavero" }
    var apiKeyPlaceholder: String { "Pega la clave y haz clic en Guardar" }
    var saveKey: String { "Guardar" }
    var deleteKey: String { "Eliminar clave" }
    var keyNotRequired: String { "Este servicio no necesita clave" }
    var keyOptional: String { "Escribe una clave si el servicio la pide; si no, déjalo vacío." }
    func keychainError(status: Int32) -> String { "Falló la operación del llavero (\(status))" }
    var test: String { "Probar" }
    var testing: String { "Probando…" }
    func testSucceeded(_ text: String) -> String { "Correcto: \(text)" }
    func testFailed(_ reason: String) -> String { "Error: \(reason)" }

    // MARK: 缓存与说明
    var cacheHeader: String { "Caché de traducciones" }
    func cacheCount(_ count: Int) -> String { count == 1 ? "1 entrada" : "\(count) entradas" }
    var clearCache: String { "Vaciar caché" }
    var privacyNote: String {
        "El texto de los mensajes de estos canales se envía al servicio de modelo que elijas. "
            + "La clave se guarda solo en el llavero de este Mac y solo se envía a ese servicio."
    }
    var costNote: String {
        "Solo se traducen los mensajes que recibe el personaje del cliente activo. Las frases idénticas se traducen una vez."
    }

    // MARK: 浮窗
    func overlayTitle(_ character: String) -> String { "Traducción · \(character)" }
    var statusNoChannels: String { "No hay canales de traducción" }
    func statusNoLogFiles(_ channels: [String]) -> String {
        "EVE no ha escrito ningún registro de chat de \(channels.joined(separator: ", ")) de este personaje en las últimas 48 horas"
    }
    var pending: String { "traduciendo…" }
    var failed: String { "sin traducir" }
}
