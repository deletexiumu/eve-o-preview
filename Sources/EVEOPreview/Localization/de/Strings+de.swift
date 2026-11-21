// SPDX-License-Identifier: GPL-3.0-or-later
//
// 德文界面文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见协议里的注释（Strings.swift、SettingsStrings.swift）。
//
// 用词的依据：
// - 反馈文档 5.5 节的词表，德文取：缩略图 Miniatur（macOS「预览」应用的叫法）、客户端 Client、
//   配置方案 Profil、循环组 Wechselgruppe、边框 Rahmen、高亮 Hervorhebung、热键 Hotkey（德文游戏玩家的通行说法，
//   也能涵盖鼠标按键，比 Tastaturkurzbefehl 合适）。
// - EVE 德文客户端的叫法：角色是 Charakter，登录界面是 Anmeldebildschirm。
// - macOS 德文的官方名称：「编辑」菜单各项取 AppKit 的 MenuCommands.loctable；权限名取系统设置
//   （Bildschirmaufnahme、Bedienungshilfen），「系统设置 > 隐私与安全性」是
//   „Systemeinstellungen“ > „Datenschutz & Sicherheit“，「在访达中显示」是 „Im Finder zeigen“，
//   修饰键叫 Sondertasten，Option 键叫 Wahltaste（⌥），Shift 键叫 Umschalttaste（⇧）。
// - 「最小化」写 minimieren（Windows 与游戏玩家的通行说法）；macOS 菜单里的 „Im Dock ablegen“ 不适合指 EVE 客户端。
// - 文体：按钮与标签用名词或动词不定式，说明文字尽量用无人称或不定式句，全篇不用 du，也不用 Sie。
// - 引号用德文的 „…“；省略号前按 macOS 德文的写法加空格（如 „Einstellungen …“）。
// - 德文的小数点是逗号（如「2,5 s」）。
// 德文普遍比英文长；侧栏的页名称只有约 140 点宽，所以用单个词（如 „Miniaturen“、„Umschalten“）。

import Foundation
import EVEOPreviewCore

// MARK: - 菜单栏

/// 菜单栏菜单，德文。
struct MenuStringsDE: MenuStrings {
    var showAll: String { "Alle Miniaturen einblenden" }
    var hideAll: String { "Alle Miniaturen ausblenden" }
    var profiles: String { "Profile" }
    var minimizeAll: String { "Alle Clients minimieren" }
    // 打开窗口的菜单项以「空格 + 省略号」结尾，与 macOS 德文菜单一致。
    var settings: String { "Einstellungen …" }
    var quit: String { "EVE-O Preview beenden" }
    var permissionsMissing: String { "Fehlende Berechtigungen …" }
    // 「假客户端」译作 simuliert（模拟的），比 gefälscht（伪造的）中性。
    var fakeMode: String { "Demomodus (simulierte Clients)" }
    var noClients: String { "Keine EVE-Clients gefunden" }
    func resumeCapture(_ title: String) -> String { "Aufnahme fortsetzen: \(title)" }
    // 德文与英文一样只区分单数与复数：1 Client、2 Clients。
    func clientCount(_ count: Int) -> String { count == 1 ? "1 Client" : "\(count) Clients" }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，德文。全部取 macOS 德文的菜单名。
struct EditMenuStringsDE: EditMenuStrings {
    var title: String { "Bearbeiten" }
    var undo: String { "Widerrufen" }
    var redo: String { "Wiederholen" }
    var cut: String { "Ausschneiden" }
    var copy: String { "Kopieren" }
    // macOS 德文的「粘贴」是 Einsetzen，不是 Einfügen。
    var paste: String { "Einsetzen" }
    var selectAll: String { "Alles auswählen" }
    var closeWindow: String { "Fenster schließen" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，德文。
struct ThumbnailStringsDE: ThumbnailStrings {
    var minimize: String { "Minimieren" }
    var minimizeAll: String { "Alle minimieren" }
    var skipCycle: String { "Beim Wechseln überspringen" }
    var hide: String { "Diese Miniatur ausblenden" }
    var resetSize: String { "Standardgröße wiederherstellen" }
    var resumeCapture: String { "Aufnahme fortsetzen" }
    // 接在不可用的菜单项后面，如「Minimieren (Bedienungshilfen erforderlich)」。
    var needsAccessibility: String { "Bedienungshilfen erforderlich" }
    func unavailable(_ item: String, reason: String) -> String { "\(item) (\(reason))" }
    var settings: String { "Einstellungen …" }
    // 占位文字：缩略图很小，尽量短。
    var waiting: String { "Warten auf Bilder …" }
    var needsScreenRecording: String { "Berechtigung „Bildschirmaufnahme“ erforderlich" }
    // 「右键恢复」用不定式句，避免称呼用户。
    var captureStopped: String { "Aufnahme gestoppt. Zum Fortsetzen rechtsklicken." }
    var minimized: String { "Minimiert" }
}

// MARK: - 设置窗口

/// 设置窗口，德文。单位用缩写：pt（点）、s（秒）、fps（帧每秒）、ms（毫秒）。
struct SettingsStringsDE: SettingsStrings {
    // 窗口与通用。
    // 用破折号连接应用名，避免德文复合词里夹着带空格的应用名。
    var windowTitle: String { "EVE-O Preview – Einstellungen" }
    var points: String { "pt" }
    var reset: String { "Zurücksetzen" }
    var defaultColor: String { "Standard" }
    var cancel: String { "Abbrechen" }
    var confirm: String { "OK" }
    var delete: String { "Löschen" }
    var online: String { "Online" }
    var offline: String { "Offline" }
    var forward: String { "Vorwärts" }
    var backward: String { "Rückwärts" }
    /// 德文的小数点是逗号（如「1,5 s」），用 de 区域的数字格式，不用 `String(format:)` 的英文小数点。
    func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "de"))) + " s"
    }
    // 帧率与毫秒取整，没有小数点，可以直接用格式串。
    func fps(_ value: Double) -> String { String(format: "%.0f fps", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
    var fakeModeNotice: String {
        "Demomodus: Die Miniaturen stammen von simulierten Clients. Wechseln und Minimieren ändern nur Demodaten."
    }
    // 「保存」按 macOS 德文的习惯写 sichern。
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "Die Konfigurationsdatei hat Version \(found); dieser Build unterstützt höchstens Version \(supported). "
            + "Es gelten die Standardwerte; Änderungen werden nicht gesichert."
    }
    func loadFailedNotice(_ message: String) -> String {
        "Die Konfigurationsdatei konnte nicht gelesen werden (\(message)). "
            + "Es gelten die Standardwerte; Änderungen werden nicht gesichert."
    }
    func quarantinedNotice(_ path: String) -> String {
        "Die Konfigurationsdatei war beschädigt und wurde nach \(path) verschoben. Es gelten die Standardwerte."
    }
    // 放进 loadFailedNotice 的括号里；德文的名词化动词（Lesen、Schreiben）本来就大写。
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "Lesen von \(path) fehlgeschlagen: \(reason)"
        case .write: return "Schreiben von \(path) fehlgeschlagen: \(reason)"
        case .quarantine: return "Verschieben der beschädigten Datei \(path) fehlgeschlagen: \(reason)"
        case .backup: return "Backup der alten Konfiguration unter \(path) fehlgeschlagen: \(reason)"
        }
    }
    var configContentInvalid: String { "der Dateiinhalt ist keine gültige Konfiguration" }

    // 页名称：侧栏窄，用单个词。「关于」按 macOS 德文系统设置的写法用 Info。
    var pageClients: String { "Clients" }
    var pagePreviews: String { "Miniaturen" }
    var pageSwitching: String { "Umschalten" }
    var pageAlerts: String { "Warnungen" }
    var pageProfiles: String { "Profile" }
    var pageGeneral: String { "Allgemein" }
    var pagePermissions: String { "Berechtigungen" }
    var pageAbout: String { "Info" }

    // 客户端页。
    var clientsSubtitle: String { "Laufende Clients und die diesem Profil bekannten Charaktere." }
    // 会话开关「全部隐藏」用 ausblenden，与按角色的「显示缩略图」（anzeigen）区分开。
    var hideAllThumbnails: String { "Alle Miniaturen ausblenden" }
    var hideAllHotkeyLabel: String { "Hotkey" }
    // 「作用范围」写 Bereich，与热键域的 scopeMenuHelp 一致。
    var hideAllScopeLabel: String { "Bereich" }
    var hideAllHotkeyFooter: String {
        "Möglich ist eine Kombination aus Sondertasten mit einer Taste (etwa ⌃⌥⌘H) oder mit der mittleren bzw. einer seitlichen Maustaste. Alle Hotkeys oben gelten in dem einen hier gewählten Bereich."
    }
    var charactersHeader: String { "Charaktere" }
    var charactersFooter: String { "Diese Farbe hat der Hervorhebungsrahmen, wenn der Charakter aktiv ist." }
    var noCharacters: String { "Noch keine Charaktere. EVE starten und mit einem Charakter einloggen." }
    var loginClientsHeader: String { "Clients am Anmeldebildschirm" }
    var showThumbnail: String { "Miniatur anzeigen" }
    var highlightColorHelp: String { "Hervorhebungsfarbe, wenn aktiv" }

    // 预览与布局页。
    var previewsSubtitle: String { "Größe, Darstellung und Verhalten der Miniaturen. Änderungen gelten sofort." }
    var defaultSize: String { "Standardgröße" }
    var minimumSize: String { "Mindestgröße" }
    var maximumSize: String { "Maximalgröße" }
    var unifySizes: String { "Alle Miniaturen auf Standardgröße zurücksetzen" }
    var appearanceHeader: String { "Darstellung" }
    // 「不透明度」取 macOS 德文的 Deckkraft。
    var opacity: String { "Deckkraft" }
    var showTitle: String { "Charaktername anzeigen" }
    var titleFontSize: String { "Schriftgröße des Namens" }
    var titleColor: String { "Farbe des Namens" }
    var borderEnabled: String { "Rahmen anzeigen" }
    var borderColor: String { "Rahmenfarbe" }
    var borderThickness: String { "Rahmenstärke" }
    var highlightEnabled: String { "Aktiven Client hervorheben" }
    var highlightColor: String { "Hervorhebungsfarbe" }
    var highlightThickness: String { "Hervorhebungsstärke" }
    // 「悬停」译作 Überfahren（鼠标移到上方），macOS 德文帮助里的说法。
    var zoomHeader: String { "Zoom beim Überfahren" }
    var zoomEnabled: String { "Beim Überfahren vergrößern" }
    var zoomFactor: String { "Zoomfaktor" }
    var zoomAnchor: String { "Ankerpunkt" }
    var behaviorHeader: String { "Verhalten" }
    var alwaysOnTop: String { "Miniaturen im Vordergrund halten" }
    var hideActiveClient: String { "Miniatur des aktiven Clients ausblenden" }
    var hideWhenNotEVE: String { "Miniaturen ausblenden, wenn EVE nicht aktiv ist" }
    var hideDelay: String { "Ausblendverzögerung" }
    var layoutHeader: String { "Layout" }
    var snapEnabled: String { "Beim Ziehen einrasten" }
    var lockAspectRatio: String { "Seitenverhältnis beim Skalieren beibehalten" }
    var lockLayout: String { "Layout sperren" }
    // 键名用 macOS 德文的叫法，括号里附符号，方便与键盘对照。
    var gestureHint: String {
        "Zum Bewegen mit der rechten Maustaste oder mit gedrückter Wahltaste (⌥) ziehen; zum Skalieren den Zeiger "
            + "an den Rand bewegen und mit der linken Maustaste ziehen. Mit gedrückter Umschalttaste (⇧) wird nicht eingerastet."
    }
    var captureHeader: String { "Aufnahme & Position" }
    var frameRate: String { "Bildrate" }
    // 标签右边是滑块，写成动作短语，说明裁掉的是标题栏。
    var titleBarCrop: String { "Titelleiste abschneiden" }
    var pollInterval: String { "Abfrageintervall für Fenster" }
    var loginPositionX: String { "Anmelde-Miniatur X" }
    var loginPositionY: String { "Anmelde-Miniatur Y" }
    // 九宫格的 9 个位置；德文习惯先说上下、再说左右。
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "Oben links"
        case .n: return "Oben"
        case .ne: return "Oben rechts"
        case .w: return "Links"
        case .center: return "Mitte"
        case .e: return "Rechts"
        case .sw: return "Unten links"
        case .s: return "Unten"
        case .se: return "Unten rechts"
        }
    }

    // 配置方案页。
    var profilesSubtitle: String { "Jedes Profil ist ein vollständiger Satz aus Einstellungen, Layouts und Wechselgruppen." }
    var activeBadge: String { "Aktiv" }
    var switchTo: String { "Wechseln" }
    var rename: String { "Umbenennen" }
    var clone: String { "Duplizieren" }
    var newProfile: String { "Neues Profil" }
    var configFile: String { "Konfigurationsdatei" }
    var revealConfig: String { "Im Finder zeigen" }
    var profileName: String { "Profilname" }
    var profileNameRule: String { "1–64 Zeichen, eindeutig unter allen Profilen (Groß-/Kleinschreibung zählt nicht)." }
    func deleteProfileConfirm(_ name: String) -> String {
        "Profil „\(name)“ löschen? Dies kann nicht widerrufen werden."
    }
    func cloneTitle(_ name: String) -> String { "„\(name)“ duplizieren" }
    func renameTitle(_ name: String) -> String { "„\(name)“ umbenennen" }
    // 与 macOS 德文访达复制文件时的命名一致：「名称 Kopie」。
    func copyName(_ name: String) -> String { "\(name) Kopie" }

    // 通用页。
    var generalSubtitle: String { "Einstellungen für alle Profile." }
    var interfaceLanguage: String { "Sprache" }
    // 语言选项「跟随系统」写成 Systemsprache，在菜单里比 „Wie System“ 清楚。
    var followSystem: String { "Systemsprache" }
    var machineTranslationNote: String { "Einige Übersetzungen sind maschinell erstellt. Korrekturen sind willkommen." }
    var showDockIcon: String { "Symbol im Dock anzeigen" }
    var showDockIconHelp: String { "Wenn deaktiviert, erscheint EVE-O Preview nur in der Menüleiste." }

    // 权限页。
    var permissionsSubtitle: String {
        "Beide Berechtigungen werden unter „Systemeinstellungen“ > „Datenschutz & Sicherheit“ erteilt."
    }
    // 权限名与 macOS 德文系统设置里的写法完全一致，便于照着查找。
    var screenRecording: String { "Bildschirmaufnahme" }
    var screenRecordingDetail: String {
        "Nötig, um Client-Fenster aufzunehmen und Titel zu lesen. Wirkt meist erst nach einem Neustart."
    }
    var accessibility: String { "Bedienungshilfen" }
    var accessibilityDetail: String {
        "Nötig, um Client-Fenster wiederherzustellen, nach vorne zu holen und zu minimieren, "
            + "sowie für Maustasten-Hotkeys. Wirkt sofort."
    }
    var granted: String { "Erteilt" }
    var notGranted: String { "Nicht erteilt" }
    var request: String { "Anfordern" }
    var openSystemSettings: String { "Systemeinstellungen öffnen" }
    // 「重新启动」写 neu starten，与更新窗口一致。
    var relaunchHint: String { "Nach Erteilen von „Bildschirmaufnahme“ neu starten" }
    var relaunch: String { "Neu starten" }
    var signingHint: String {
        "macOS speichert Berechtigungen anhand der Codesignatur. Ad-hoc-Builds müssen nach jedem Neubau "
            + "erneut freigegeben werden; zu einem selbstsignierten Zertifikat siehe README."
    }

    // 关于页。
    var version: String { "Version" }
    // `swift run` 时没有版本号，显示「开发构建」；Build 保留英文，德文开发者通用。
    var devVersion: String { "Entwicklungs-Build" }
    var aboutSubtitle: String {
        "Live-Miniaturen und schnelles Wechseln für mehrere EVE Online-Clients, nativ für macOS."
    }
    var aboutSummary: String {
        "Eine Live-Miniatur pro Client, Wechseln per Klick, Hotkeys für Wechselgruppen und mehrere Profile."
    }
    // 「上游」译作 Ursprungsprojekt（原始项目），比直译的 Upstream 好懂。
    var upstreamHeader: String { "Ursprungsprojekt & Lizenz" }
    var upstreamText: String { "Diese App setzt die Funktionen von EveOPlus/eve-o-preview nativ für macOS neu um." }
    var licenseText: String { "Wie das Ursprungsprojekt steht sie unter der GNU General Public License v3.0." }
    var disclaimerHeader: String { "Hinweise" }
    var focusOnlyText: String {
        "Dieses Tool wechselt nur den Fensterfokus. Es sendet nie Eingaben an mehrere Clients gleichzeitig "
            + "und liest oder verändert nie den Spielspeicher."
    }
    var gameLogText: String {
        "Kampfwarnungen lesen nur die Spielprotokolle, die der EVE-Client schreibt. "
            + "Sie lesen nie den Spielspeicher, ändern keine Dateien und senden keine Eingaben."
    }
    // 「通用」用通用页的页名 Allgemein（pageGeneral）。
    var networkText: String {
        "EVE-O Preview kontaktiert GitHub nur, um nach Updates zu suchen und sie zu laden; abschaltbar unter "
            + "„Allgemein“. Problemberichte werden nie automatisch gesendet."
    }
    // 商标声明照英文原意翻译，不增删。
    var eveIPText: String {
        "EVE Online und zugehörige Logos sind Marken von CCP ehf. "
            + "Dieses Projekt steht in keiner Verbindung zu CCP und wird nicht von CCP unterstützt."
    }
}

// MARK: - 预警与翻译（docs/design-intel-translate.md 第 11 节）
// 机器生成、待母语者审校的译文，用词按 11 节的词表：浮窗、预警、频道、聊天日志、模型服务。

/// 菜单栏的两个浮窗开关，德文。
extension MenuStringsDE {
    var showIntelOverlay: String { "Aufklärungs-Overlay anzeigen" }
    var showTranslationOverlay: String { "Übersetzungs-Overlay anzeigen" }
}

/// 两个新页的页名、关于页的说明与聊天日志的状态，德文。
extension SettingsStringsDE {
    var pageIntel: String { "Aufklärung" }
    var pageTranslation: String { "Übersetzung" }
    var aboutChatLogsNote: String {
        "Aufklärung und Übersetzung lesen nur Chatprotokolle und Spielprotokolle. Die Übersetzung sendet Chattext an den von dir gewählten Modelldienst. Wenn die Online-Namensprüfung aktiv ist, werden zusammenhängende Pilotennamen aus Aufklärungsmeldungen an die ESI-API von CCP gesendet."
    }
    var chatLogStatusStopped: String { "Aus" }
    func chatLogStatusWatching(directory: String, files: Int) -> String {
        "Überwacht \(files == 1 ? "1 Protokolldatei" : "\(files) Protokolldateien") in \(directory)"
    }
    func chatLogStatusDirectoryNotFound(_ path: String) -> String { "Ordner der Chatprotokolle nicht gefunden: \(path)" }
    func chatLogStatusAccessDenied(_ path: String) -> String { "Keine Leseberechtigung für \(path)" }
    var chatLogHelp: String {
        "Im EVE-Client muss das Protokollieren des Chats in eine Datei aktiviert sein. Der Protokollordner wird auf der Seite „Warnungen“ festgelegt."
    }
}
