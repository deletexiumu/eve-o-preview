// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的西班牙文文字（反馈文档 5.3 节、7.11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：alerta de combate、registro del juego、miniatura；系统权限用 macOS 西班牙文界面的
// 「Archivos y carpetas」，「文稿」文件夹是 “Documentos”，系统设置是 Ajustes del Sistema。
// 「闪烁」写 parpadeo / parpadear。西班牙文的复数只分单复数，与英文相同。

import Foundation

/// 「提醒」页的西班牙文文字。
struct CombatStringsES: CombatStrings {
    // MARK: 页头
    var pageSubtitle: String { "La miniatura de un personaje parpadea cuando lo atacan." }

    // MARK: 开关与状态行
    // 状态行显示目录全路径，文字保持短。
    var enableToggle: String { "Hacer parpadear la miniatura al atacar a un personaje" }
    var statusLabel: String { "Estado" }
    var statusStopped: String { "Desactivado" }
    func statusWatching(directory: String, files: Int) -> String {
        "Vigilando \(files == 1 ? "1 archivo de registro" : "\(files) archivos de registro") en \(directory)"
    }
    func statusDirectoryNotFound(_ path: String) -> String {
        "No se encuentra la carpeta de registros del juego: \(path)"
    }
    func statusAccessDenied(_ path: String) -> String { "Sin permiso para leer \(path)" }
    // 系统设置的路径不加引号；单独提到的文件夹名加弯引号。
    var accessDeniedHelp: String {
        "Permite que EVE-O Preview acceda a la carpeta “Documentos” en "
            + "Ajustes del Sistema > Privacidad y seguridad > Archivos y carpetas."
    }
    var openSystemSettings: String { "Abrir Ajustes del Sistema…" }

    // MARK: 日志目录
    var logDirectoryHeader: String { "Registros del juego" }
    var logDirectoryLabel: String { "Carpeta" }
    var automaticSuffix: String { "(automático)" }
    var chooseDirectory: String { "Elegir…" }
    var useAutomaticLocation: String { "Usar ubicación automática" }
    // 文件夹名 logs、Gamelogs 是磁盘上的名字，不翻译。
    var chooseDirectoryMessage: String { "Elige la carpeta “logs” o “Gamelogs” de EVE." }

    // MARK: 闪烁的外观
    var appearanceHeader: String { "Parpadeo" }
    var flashColor: String { "Color del parpadeo" }
    var duration: String { "Duración" }
    /// 西班牙文的小数点是逗号（如「3,5 s」）：把共用函数给出的英文小数点换成逗号。
    func seconds(_ value: Double) -> String {
        let number = combatSecondsNumber(value).replacingOccurrences(of: ".", with: ",")
        return "\(number) s"
    }
    var style: String { "Estilo" }
    var styleBorder: String { "Borde" }
    var styleWash: String { "Tinte" }
    var styleBoth: String { "Ambos" }

    // MARK: 触发条件
    var triggersHeader: String { "Condiciones" }
    var includeMisses: String { "Avisar también de los ataques fallidos" }
    var minimumDamage: String { "Daño mínimo" }
    var minimumDamageHelp: String {
        "Se ignoran los impactos por debajo de esta cantidad. Los fallos dependen de la opción anterior."
    }

    // MARK: 测试与说明
    var testFlash: String { "Probar parpadeo" }
    var testFlashHelp: String { "Hace parpadear todas las miniaturas una vez, aunque la alerta esté desactivada." }
    var footnote: String {
        "El cliente de EVE debe estar configurado para guardar los mensajes del juego en archivos de registro. "
            + "Esta función solo lee los registros del juego y nunca envía ninguna entrada al juego."
    }
}
