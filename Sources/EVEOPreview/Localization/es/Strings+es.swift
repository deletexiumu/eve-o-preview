// SPDX-License-Identifier: GPL-3.0-or-later
//
// 西班牙文界面文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见协议里的注释（Strings.swift、SettingsStrings.swift）。
//
// 用词的依据：
// - 反馈文档 5.5 节的词表：miniatura（缩略图）、cliente、perfil（配置方案）、grupo de ciclo（循环组）、
//   borde（边框）、resaltado（高亮）、atajo（热键，含鼠标按键，所以不写「atajo de teclado」）。
// - EVE 的叫法：角色是 personaje，登录界面是 pantalla de inicio de sesión。
// - macOS 西班牙文（西班牙）的官方名称：「编辑」菜单各项取 AppKit 的 MenuCommands.loctable；
//   「设置…」是 Ajustes…，「系统设置 > 隐私与安全性」是 Ajustes del Sistema > Privacidad y seguridad，
//   权限名是 Grabación de pantalla、Accesibilidad，菜单栏是 barra de menús，访达保留 Finder。
// - 修饰键用 macOS 西班牙文的键名：Opción、Mayúsculas、Control、Comando；键符号（⌃⌥⌘）不变。
// - 语气按 Apple 西班牙文的习惯：对用户用 tú 的命令式（如 Abre、Haz clic），不用 usted。
// - 引号用 Apple 西班牙文的弯引号 “…”，与其他西班牙文文件一致。
// - 「应用」写 app（Apple 西班牙文的写法），release 写 versión。
// 西班牙文普遍比英文长；侧栏的页名称只有约 140 点宽，所以「预览与布局」写 “Miniaturas” 一个词。

import Foundation
import EVEOPreviewCore

// MARK: - 菜单栏

/// 菜单栏菜单，西班牙文。
struct MenuStringsES: MenuStrings {
    // 菜单项用不定式（Mostrar、Ocultar、Minimizar），与 macOS 西班牙文菜单一致。
    var showAll: String { "Mostrar todas las miniaturas" }
    var hideAll: String { "Ocultar todas las miniaturas" }
    var profiles: String { "Perfiles" }
    var minimizeAll: String { "Minimizar todos los clientes" }
    var settings: String { "Ajustes…" }
    // 「退出」按 macOS 的说法写 Salir de + 应用名。
    var quit: String { "Salir de EVE-O Preview" }
    var permissionsMissing: String { "Faltan permisos…" }
    var fakeMode: String { "Modo de demostración (clientes ficticios)" }
    var noClients: String { "No se han encontrado clientes de EVE" }
    func resumeCapture(_ title: String) -> String { "Reanudar captura: \(title)" }
    // 西班牙文与英文一样只区分单数与复数：1 cliente，0 clientes，2 clientes。
    func clientCount(_ count: Int) -> String { count == 1 ? "1 cliente" : "\(count) clientes" }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，西班牙文。全部取 macOS 西班牙文的菜单名。
struct EditMenuStringsES: EditMenuStrings {
    var title: String { "Edición" }
    var undo: String { "Deshacer" }
    var redo: String { "Rehacer" }
    var cut: String { "Cortar" }
    var copy: String { "Copiar" }
    var paste: String { "Pegar" }
    var selectAll: String { "Seleccionar todo" }
    var closeWindow: String { "Cerrar ventana" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，西班牙文。
struct ThumbnailStringsES: ThumbnailStrings {
    // 右键菜单。「最小化全部」省略宾语 clientes，菜单宽度有限。
    var minimize: String { "Minimizar" }
    var minimizeAll: String { "Minimizar todos" }
    var skipCycle: String { "Omitir en el ciclo" }
    var hide: String { "Ocultar esta miniatura" }
    // 「恢复默认尺寸」用 Restablecer（macOS 西班牙文「恢复默认」的说法）。
    var resetSize: String { "Restablecer tamaño predeterminado" }
    var resumeCapture: String { "Reanudar captura" }
    var needsAccessibility: String { "Requiere Accesibilidad" }
    // 括号用半角加空格，与英文相同。
    func unavailable(_ item: String, reason: String) -> String { "\(item) (\(reason))" }
    var settings: String { "Ajustes…" }
    // 占位文字：缩略图很小，尽量短。「右键」写 clic derecho，玩家更熟悉这个说法。
    var waiting: String { "Esperando imagen…" }
    var needsScreenRecording: String { "Se necesita el permiso “Grabación de pantalla”" }
    var captureStopped: String { "Captura detenida. Haz clic derecho para reanudarla." }
    var minimized: String { "Minimizado" }
}

// MARK: - 设置窗口

/// 设置窗口，西班牙文。单位用缩写：pt（点）、s（秒）、fps（帧每秒）、ms（毫秒），与英文相同。
struct SettingsStringsES: SettingsStrings {
    // 窗口与通用。
    var windowTitle: String { "Ajustes de EVE-O Preview" }
    var points: String { "pt" }
    var reset: String { "Restablecer" }
    var defaultColor: String { "Por defecto" }
    var cancel: String { "Cancelar" }
    // 确定按钮用 Apple 西班牙文的 Aceptar。
    var confirm: String { "Aceptar" }
    var delete: String { "Eliminar" }
    // 在线/离线标记用阳性形容词，指 personaje。
    var online: String { "Conectado" }
    var offline: String { "Desconectado" }
    var forward: String { "Adelante" }
    var backward: String { "Atrás" }
    /// 西班牙文的小数点是逗号（如「1,5 s」），用 es 区域的数字格式，不用 `String(format:)` 的英文小数点。
    func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "es"))) + " s"
    }
    // 帧率与毫秒取整，没有小数点，直接用格式串。
    func fps(_ value: Double) -> String { String(format: "%.0f fps", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
    // 以下几条是各页顶部的提示条，可以写成完整的句子。
    var fakeModeNotice: String {
        "Modo de demostración: las miniaturas proceden de clientes ficticios. "
            + "Cambiar y minimizar solo afecta a los datos de demostración."
    }
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "El archivo de configuración es de la versión \(found); esta compilación admite hasta la \(supported). "
            + "Se usan los valores predeterminados; los cambios no se guardarán."
    }
    func loadFailedNotice(_ message: String) -> String {
        "No se ha podido leer el archivo de configuración (\(message)). "
            + "Se usan los valores predeterminados; los cambios no se guardarán."
    }
    func quarantinedNotice(_ path: String) -> String {
        "El archivo de configuración estaba dañado y se ha movido a \(path). Se usan los valores predeterminados."
    }
    // 放进 loadFailedNotice 的括号里，所以首字母小写。
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "no se ha podido leer \(path): \(reason)"
        case .write: return "no se ha podido escribir \(path): \(reason)"
        case .quarantine: return "no se ha podido apartar el archivo dañado \(path): \(reason)"
        case .backup: return "no se ha podido guardar una copia de la configuración anterior en \(path): \(reason)"
        }
    }
    var configContentInvalid: String { "el contenido del archivo no es una configuración válida" }

    // 页名称：侧栏窄，尽量短。「切换与热键」写 Cambio y atajos。
    var pageClients: String { "Clientes" }
    var pagePreviews: String { "Miniaturas" }
    var pageSwitching: String { "Cambio y atajos" }
    var pageAlerts: String { "Alertas" }
    var pageProfiles: String { "Perfiles" }
    var pageGeneral: String { "General" }
    var pagePermissions: String { "Permisos" }
    // 「关于」页按 macOS 的说法写 Acerca de。
    var pageAbout: String { "Acerca de" }

    // 客户端页。「作用范围」写 Ámbito，与热键域的 defaultScopeLabel 一致。
    var clientsSubtitle: String { "Clientes en ejecución y personajes conocidos por este perfil." }
    var hideAllThumbnails: String { "Ocultar todas las miniaturas" }
    var hideAllHotkeyLabel: String { "Atajo" }
    var hideAllScopeLabel: String { "Ámbito" }
    // 修饰键用键符号举例，符号本身不翻译。
    var hideAllHotkeyFooter: String {
        "Usa una combinación de teclas modificadoras con una tecla (como ⌃⌥⌘H) o con el botón central o un botón lateral del ratón. Todos los atajos de arriba usan el único ámbito elegido aquí."
    }
    var charactersHeader: String { "Personajes" }
    var charactersFooter: String { "El color se usa para el borde de resaltado cuando este personaje está activo." }
    // 「登录」写 iniciar sesión，与登录界面的叫法一致。
    var noCharacters: String { "Aún no hay personajes. Abre EVE e inicia sesión con un personaje." }
    var loginClientsHeader: String { "Clientes en la pantalla de inicio de sesión" }
    var showThumbnail: String { "Mostrar miniatura" }
    var highlightColorHelp: String { "Color de resaltado cuando está activo" }

    // 预览与布局页。「标题」指角色名，所以字号与颜色两行写 nombre，不写 título。
    var previewsSubtitle: String {
        "Tamaño, aspecto y comportamiento de las miniaturas. Los cambios se aplican al instante."
    }
    var defaultSize: String { "Tamaño predeterminado" }
    var minimumSize: String { "Tamaño mínimo" }
    var maximumSize: String { "Tamaño máximo" }
    var unifySizes: String { "Restablecer todas las miniaturas al tamaño predeterminado" }
    var appearanceHeader: String { "Aspecto" }
    var opacity: String { "Opacidad" }
    var showTitle: String { "Mostrar nombre del personaje" }
    var titleFontSize: String { "Tamaño de letra del nombre" }
    var titleColor: String { "Color del nombre" }
    var borderEnabled: String { "Mostrar borde" }
    var borderColor: String { "Color del borde" }
    var borderThickness: String { "Grosor del borde" }
    var highlightEnabled: String { "Resaltar el cliente activo" }
    var highlightColor: String { "Color de resaltado" }
    var highlightThickness: String { "Grosor del resaltado" }
    // 组标题与开关区分开：标题用 Zoom，开关用动词 Ampliar。
    var zoomHeader: String { "Zoom al pasar el puntero" }
    var zoomEnabled: String { "Ampliar al pasar el puntero" }
    var zoomFactor: String { "Factor de zoom" }
    var zoomAnchor: String { "Punto de anclaje" }
    var behaviorHeader: String { "Comportamiento" }
    // 「置顶」写 en primer plano，与下面「前台」是同一个说法。
    var alwaysOnTop: String { "Mantener las miniaturas en primer plano" }
    var hideActiveClient: String { "Ocultar la miniatura del cliente activo" }
    var hideWhenNotEVE: String { "Ocultar las miniaturas si EVE no está en primer plano" }
    var hideDelay: String { "Retardo al ocultar" }
    var layoutHeader: String { "Disposición" }
    // 「吸附」写 ajustar（macOS 西班牙文窗口排列的说法），gestureHint 里也一样。
    var snapEnabled: String { "Ajustar al arrastrar" }
    var lockAspectRatio: String { "Mantener la proporción al redimensionar" }
    var lockLayout: String { "Bloquear disposición" }
    var gestureHint: String {
        "Arrastra con el botón derecho o con Opción para mover; arrastra un borde para redimensionar; "
            + "mantén pulsada la tecla Mayúsculas para no ajustar."
    }
    // 这一组的控件是滑块，标签可以稍长。
    var captureHeader: String { "Captura y posición" }
    var frameRate: String { "Frecuencia de fotogramas" }
    var titleBarCrop: String { "Recorte de la barra de título" }
    var pollInterval: String { "Intervalo de sondeo de ventanas" }
    var loginPositionX: String { "Miniatura de inicio de sesión: X" }
    var loginPositionY: String { "Miniatura de inicio de sesión: Y" }
    // 九宫格的位置用 Apple 西班牙文的方位说法（arriba / abajo + a la izquierda / a la derecha）。
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "Arriba a la izquierda"
        case .n: return "Arriba"
        case .ne: return "Arriba a la derecha"
        case .w: return "Izquierda"
        case .center: return "Centro"
        case .e: return "Derecha"
        case .sw: return "Abajo a la izquierda"
        case .s: return "Abajo"
        case .se: return "Abajo a la derecha"
        }
    }

    // 配置方案页。克隆的建议名称按访达西班牙文的习惯写「名称 copia」。
    var profilesSubtitle: String {
        "Cada perfil es un conjunto completo de ajustes, disposiciones y grupos de ciclo."
    }
    // 徽标与按钮用单个词。
    var activeBadge: String { "Activo" }
    var switchTo: String { "Cambiar" }
    var rename: String { "Renombrar" }
    var clone: String { "Duplicar" }
    var newProfile: String { "Nuevo perfil" }
    var configFile: String { "Archivo de configuración" }
    var revealConfig: String { "Mostrar en Finder" }
    var profileName: String { "Nombre del perfil" }
    var profileNameRule: String {
        "Entre 1 y 64 caracteres, distinto del de otros perfiles (sin distinguir mayúsculas)."
    }
    func deleteProfileConfirm(_ name: String) -> String {
        "¿Eliminar el perfil “\(name)”? Esta acción no se puede deshacer."
    }
    func cloneTitle(_ name: String) -> String { "Duplicar “\(name)”" }
    func renameTitle(_ name: String) -> String { "Renombrar “\(name)”" }
    // 名称后不加括号，与访达复制文件时的命名一致。
    func copyName(_ name: String) -> String { "\(name) copia" }

    // 通用页。
    var generalSubtitle: String { "Ajustes comunes a todos los perfiles." }
    var interfaceLanguage: String { "Idioma de la interfaz" }
    // 「跟随系统」写 Según el sistema，简短，放得进弹出菜单。
    var followSystem: String { "Según el sistema" }
    var machineTranslationNote: String { "Algunas traducciones son automáticas. Se agradecen las correcciones." }
    // Dock 与菜单栏用 macOS 西班牙文的叫法：el Dock、la barra de menús。
    var showDockIcon: String { "Mostrar icono en el Dock" }
    var showDockIconHelp: String { "Si se desactiva, EVE-O Preview solo muestra su icono en la barra de menús." }

    // 权限页。系统设置的路径不加引号，与 Apple 西班牙文的说明文字一致；单独提到的权限名加引号。
    // 两项权限的名称与 macOS 西班牙文「隐私与安全性」里的条目名一致。
    var permissionsSubtitle: String {
        "Ambos permisos se conceden en Ajustes del Sistema > Privacidad y seguridad."
    }
    var screenRecording: String { "Grabación de pantalla" }
    var screenRecordingDetail: String {
        "Necesario para capturar las ventanas de los clientes y leer sus títulos. "
            + "Suele surtir efecto tras reiniciar la app."
    }
    var accessibility: String { "Accesibilidad" }
    var accessibilityDetail: String {
        "Necesario para restaurar, traer al frente y minimizar las ventanas de los clientes, "
            + "y para los atajos con botones del ratón. Surte efecto al instante."
    }
    // 授权状态用阳性过去分词，指 permiso。
    var granted: String { "Concedido" }
    var notGranted: String { "No concedido" }
    var request: String { "Solicitar" }
    var openSystemSettings: String { "Abrir Ajustes del Sistema" }
    var relaunchHint: String { "Reinicia tras conceder “Grabación de pantalla”" }
    var relaunch: String { "Reiniciar" }
    // ad hoc 是签名方式的术语，按西班牙文写法不加连字符。
    var signingHint: String {
        "macOS registra los permisos según la firma del código. Las compilaciones con firma ad hoc "
            + "deben volver a autorizarse tras cada compilación; consulta el README para usar un certificado autofirmado."
    }

    // 关于页。上游项目写 proyecto original；许可证名称保留英文原名。
    // 版本号由界面另外拼接，这里只是标签。
    var version: String { "Versión" }
    var devVersion: String { "Compilación de desarrollo" }
    // en directo（实时）是西班牙的说法。
    var aboutSubtitle: String {
        "Miniaturas en directo y cambio rápido entre varios clientes de EVE Online, nativo en macOS."
    }
    var aboutSummary: String {
        "Una miniatura en directo por cliente, cambio con un clic, atajos de grupos de ciclo y varios perfiles."
    }
    var upstreamHeader: String { "Proyecto original y licencia" }
    var upstreamText: String {
        "Esta app reimplementa de forma nativa para macOS las funciones de EveOPlus/eve-o-preview."
    }
    var licenseText: String {
        "Al igual que el proyecto original, se publica bajo la GNU General Public License v3.0."
    }
    var disclaimerHeader: String { "Notas" }
    // 以下几条是发布必备的声明，忠实于英文原意，不做删减。
    var focusOnlyText: String {
        "Esta herramienta solo cambia el foco de las ventanas. Nunca reenvía la entrada a varios clientes "
            + "ni lee o modifica la memoria del juego."
    }
    var gameLogText: String {
        "Las alertas de combate solo leen los archivos de registro que escribe el cliente de EVE. "
            + "Nunca leen la memoria del juego, modifican archivos ni envían entradas."
    }
    // 「通用」与 pageGeneral 一致。
    var networkText: String {
        "EVE-O Preview solo se conecta a GitHub para buscar y descargar actualizaciones; "
            + "puedes desactivarlo en General. Los informes de problemas nunca se envían automáticamente."
    }
    var eveIPText: String {
        "EVE Online y los logotipos relacionados son marcas comerciales de CCP ehf. "
            + "Este proyecto no está afiliado a CCP ni cuenta con su respaldo."
    }
}
