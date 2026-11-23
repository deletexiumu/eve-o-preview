// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的西班牙文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与协议一致，每条的用途见 UpdateStrings.swift。
// 用词按 v1.1 设计 11.3 节的词表：actualización、Buscar actualizaciones…（macOS 西班牙文的说法）、
// notas de la versión、Instalar actualización、Omitir esta versión、Más tarde、firma；
// 缩略图 miniatura（反馈文档 5.5 节）。release 写 versión，「发布页」写 página de la versión。
// 「重新启动」与权限页一致写 Reiniciar；「应用程序」文件夹写 “Aplicaciones”（macOS 西班牙文的名称）。
// 限流时刻可能带日期，所以不写「a las」，写 después de。本域的文字不带数量，不用处理复数。

import Foundation

/// 更新域的西班牙文实现。
struct UpdateStringsES: UpdateStrings {
    // MARK: 菜单栏菜单

    var menuCheckForUpdates: String { "Buscar actualizaciones…" }
    // 菜单项以省略号结尾，表示点了会打开窗口。
    func menuUpdateAvailable(_ version: String) -> String { "Actualización disponible: \(version)…" }
    func menuRestartToUpdate(_ version: String) -> String { "Reiniciar para actualizar a \(version)" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "Actualizaciones" }
    var autoCheckToggle: String { "Buscar actualizaciones automáticamente" }
    var autoCheckHelp: String { "Se conecta a GitHub una vez al día. No se envían datos personales." }
    var autoInstallToggle: String { "Instalar actualizaciones automáticamente" }
    var autoInstallHelp: String {
        "Descarga en segundo plano. Instala y reinicia cuando no se ha ejecutado ningún cliente de EVE "
            + "durante un minuto, o instala al salir de EVE-O Preview."
    }
    // 「通用」页表单行的标签，宜短。
    var currentVersionLabel: String { "Versión actual" }
    var lastCheckedLabel: String { "Última comprobación" }
    var lastCheckedNever: String { "Nunca" }
    var checkNowButton: String { "Comprobar ahora" }

    // MARK: 状态行

    var statusChecking: String { "Comprobando…" }
    // 应用名按阳性处理（el programa），形容词写 actualizado。
    var statusUpToDate: String { "EVE-O Preview está actualizado." }
    func statusAvailable(_ version: String) -> String { "La versión \(version) está disponible." }
    func statusReady(_ version: String) -> String {
        "La versión \(version) se ha descargado. Se instalará cuando no haya ningún cliente de EVE "
            + "en ejecución o al salir."
    }
    func statusRateLimited(_ time: String) -> String {
        "GitHub está limitando las solicitudes. Vuelve a intentarlo después de \(time)."
    }
    var statusRateLimitedLater: String { "GitHub está limitando las solicitudes. Vuelve a intentarlo más tarde." }
    var statusUnavailable: String { "Las actualizaciones no están disponibles en esta compilación." }

    // MARK: 更新窗口

    var windowTitle: String { "Actualización de software" }
    func headline(_ version: String) -> String { "EVE-O Preview \(version) está disponible" }
    func currentVersionLine(_ version: String) -> String { "Tienes la versión \(version)." }
    var releaseNotesHeader: String { "Novedades" }
    func versionNotesTitle(_ version: String) -> String { "Versión \(version)" }
    var earlierVersionsOnReleasePage: String { "Los cambios de versiones anteriores están en la página de versiones." }
    var installButton: String { "Instalar actualización" }
    var installHelp: String {
        "La app se reinicia tras la instalación. Las miniaturas desaparecen unos segundos."
    }
    // 按钮文字取 macOS 软件更新的西班牙文说法。
    var skipButton: String { "Omitir esta versión" }
    var laterButton: String { "Más tarde" }
    var openReleasePageButton: String { "Abrir página de la versión" }
    var cancelButton: String { "Cancelar" }
    var closeButton: String { "Cerrar" }
    var retryButton: String { "Reintentar" }
    // 两个大小已按界面语言格式化；总大小未知时只显示已下载的大小。
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "Descargando… \(received) de \($0)" } ?? "Descargando… \(received)"
    }
    var progressVerifying: String { "Verificando…" }
    var progressInstalling: String { "Instalando…" }
    var progressRelaunching: String { "Reiniciando…" }
    // feed 写 canal。
    var testFeedBadge: String { "Canal de prueba" }
    var notifyOnlyIntro: String { "Esta copia no puede actualizarse sola." }
    var currentVersionUnchanged: String { "Tu versión actual no ha cambiado." }
    var reopenManually: String { "La actualización está instalada. Sal de EVE-O Preview y vuelve a abrirlo." }

    // MARK: 不能自动安装的原因

    // 每条是一整句，跟在 notifyOnlyIntro 后面显示。
    var blockerTranslocated: String {
        "macOS está ejecutando la app desde una ubicación temporal de solo lectura. "
            + "Muévela a la carpeta “Aplicaciones” y vuelve a abrirla."
    }
    var blockerUnsupportedVolume: String {
        "La app está en un disco sin formato APFS, por lo que no se pueden instalar actualizaciones desde la app. "
            + "Descarga la nueva versión desde la página de la versión."
    }
    var blockerReadOnlyVolume: String {
        "La app está en un disco de solo lectura. Cópiala primero a la carpeta “Aplicaciones”."
    }
    var blockerLocationNotWritable: String { "No tienes permiso para modificar la carpeta que contiene la app." }
    var blockerAdHocSignature: String {
        "Esta compilación no tiene una firma estable, así que no se puede verificar una nueva versión con ella."
    }
    var blockerDevelopmentSignature: String { "Esta es una compilación de desarrollo firmada localmente." }
    var blockerUnsigned: String { "Esta compilación no está firmada." }

    // MARK: 错误

    // 错误说明都是完整的句子，以句号结尾。
    var errorNetwork: String { "No se ha podido conectar con GitHub. Comprueba tu conexión a internet." }
    func errorHTTPStatus(_ code: Int) -> String { "GitHub respondió con un error (\(code))." }
    var errorMalformedFeed: String { "No se ha podido leer la información de la versión." }
    var errorAssetMissing: String { "Esta versión no incluye un instalador para actualizaciones automáticas." }
    var errorDiskSpace: String { "No hay suficiente espacio libre en el disco para la descarga." }
    var errorChecksum: String { "La descarga no coincide con su suma de comprobación y se ha descartado." }
    var errorDiskImage: String { "No se ha podido abrir la imagen de disco descargada." }
    var errorVerification: String { "No se ha podido verificar la nueva versión, así que no se ha instalado." }
    func errorUnsupportedSystem(_ minimum: String) -> String { "Esta versión requiere macOS \(minimum) o posterior." }
    var errorSwapFailed: String { "No se ha podido sustituir la app." }
}
