// SPDX-License-Identifier: GPL-3.0-or-later
//
// 诊断域的西班牙文文字（v1.1 设计 11.4 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 11.3 节的词表：informe、informe de fallo、registro、marcador（占位符）；
// 菜单项「报告问题…」用 “Informar de un problema…”，GitHub 的 issue 保留原词（GitHub 界面没有西班牙文）。
// 西班牙文的复数只分单复数，由 replacements 处理。

import Foundation

/// 诊断域的西班牙文文字。
struct DiagnosticsStringsES: DiagnosticsStrings {
    // MARK: 菜单栏菜单
    var menuReportProblem: String { "Informar de un problema…" }
    var menuCrashPending: String { "EVE-O Preview se cerró inesperadamente — Informar…" }

    // MARK: 「通用」页的诊断一组
    var sectionHeader: String { "Diagnóstico" }
    var verboseLoggingToggle: String { "Registro detallado" }
    var verboseLoggingHelp: String {
        "Escribe más detalles en el archivo de registro. Actívalo antes de reproducir un problema."
    }
    var logLocationLabel: String { "Archivos de registro" }
    var showLogsButton: String { "Mostrar registros en Finder" }
    var reportButton: String { "Informar de un problema…" }

    // MARK: 报告窗口的说明
    var windowTitle: String { "Informar de un problema" }
    var intro: String {
        "Se creará un archivo zip con los elementos siguientes. No se envía nada automáticamente: "
            + "eres tú quien adjunta el archivo a un issue de GitHub."
    }
    var crashIntro: String {
        "EVE-O Preview se cerró inesperadamente la última vez. Un informe ayuda a corregir la causa."
    }
    var redactionNote: String {
        "Tu nombre de usuario de macOS, el nombre del ordenador y los nombres de los personajes de EVE "
            + "se sustituyen por marcadores."
    }

    // MARK: 报告窗口的文件列表与预览
    var itemsHeader: String { "Incluido en el informe" }
    var itemSummary: String { "Resumen del entorno" }
    var itemConfig: String { "Resumen de ajustes (sin nombres)" }
    var itemLog: String { "Registro de la app" }
    func itemCrash(_ number: Int) -> String { "Informe de fallo \(number)" }
    var itemManifest: String { "Lista de archivos" }
    var previewTruncated: String { "Solo se muestra la primera parte. El informe contiene el archivo completo." }
    // 1 sustitución，0 / 2 sustituciones。
    func replacements(_ count: Int) -> String { count == 1 ? "1 sustitución" : "\(count) sustituciones" }
    var collecting: String { "Recopilando…" }

    // MARK: 报告窗口的按钮
    var createAndOpenButton: String { "Crear informe y abrir GitHub" }
    var createOnlyButton: String { "Solo crear informe" }
    var cancelButton: String { "Cancelar" }
    var notNowButton: String { "Ahora no" }
    var dontReportButton: String { "No informar" }

    // MARK: 完成页
    var doneTitle: String { "Informe creado" }
    var doneHelp: String {
        "Finder muestra el archivo zip. Arrástralo a la página del issue en tu navegador, "
            + "describe lo ocurrido y envíalo."
    }
    var revealButton: String { "Mostrar en Finder" }
    var openIssueButton: String { "Volver a abrir GitHub" }
    var closeButton: String { "Cerrar" }

    // MARK: 错误
    // reason 是系统给的说明，不翻译。
    func createFailed(_ reason: String) -> String { "No se ha podido crear el informe: \(reason)" }
}
