// SPDX-License-Identifier: GPL-3.0-or-later
//
// 英文界面文字，默认语言。沿用 v1 的英文文字；第一轮反馈新增边框、通用页与「关于」页的一句说明。
// 成员顺序与协议（Strings.swift、SettingsStrings.swift）一致，每条的用途见协议里的注释。
// 其他语言的文件按同样的顺序排列，便于逐行对照。

import Foundation
import EVEOPreviewCore

// MARK: - 菜单栏

/// 菜单栏菜单，英文。
struct MenuStringsEN: MenuStrings {
    var showAll: String { "Show All Thumbnails" }
    var hideAll: String { "Hide All Thumbnails" }
    var profiles: String { "Profiles" }
    var minimizeAll: String { "Minimize All Clients" }
    var settings: String { "Settings…" }
    var quit: String { "Quit EVE-O Preview" }
    var permissionsMissing: String { "Permissions Missing…" }
    var fakeMode: String { "Demo Mode (Fake Clients)" }
    var noClients: String { "No EVE Clients Found" }
    func resumeCapture(_ title: String) -> String { "Resume Capture: \(title)" }
    // 英文只区分单数与复数。
    func clientCount(_ count: Int) -> String { count == 1 ? "1 client" : "\(count) clients" }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，英文。
struct EditMenuStringsEN: EditMenuStrings {
    var title: String { "Edit" }
    var undo: String { "Undo" }
    var redo: String { "Redo" }
    var cut: String { "Cut" }
    var copy: String { "Copy" }
    var paste: String { "Paste" }
    var selectAll: String { "Select All" }
    var closeWindow: String { "Close Window" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，英文。
struct ThumbnailStringsEN: ThumbnailStrings {
    var minimize: String { "Minimize" }
    var minimizeAll: String { "Minimize All" }
    var skipCycle: String { "Skip in Cycle" }
    var hide: String { "Hide This Thumbnail" }
    var resetSize: String { "Reset to Default Size" }
    var resumeCapture: String { "Resume Capture" }
    var needsAccessibility: String { "Requires Accessibility" }
    func unavailable(_ item: String, reason: String) -> String { "\(item) (\(reason))" }
    var settings: String { "Settings…" }
    // 占位文字。
    var waiting: String { "Waiting for frames…" }
    var needsScreenRecording: String { "Screen Recording permission required" }
    var captureStopped: String { "Capture stopped. Right-click to resume." }
    var minimized: String { "Minimized" }
}

// MARK: - 设置窗口

/// 设置窗口，英文。单位用缩写（pt、s、fps、ms）。
struct SettingsStringsEN: SettingsStrings {
    // 窗口与通用。
    var windowTitle: String { "EVE-O Preview Settings" }
    var points: String { "pt" }
    var reset: String { "Reset" }
    var defaultColor: String { "Default" }
    var cancel: String { "Cancel" }
    var confirm: String { "OK" }
    var delete: String { "Delete" }
    var online: String { "Online" }
    var offline: String { "Offline" }
    var forward: String { "Forward" }
    var backward: String { "Backward" }
    func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
    func fps(_ value: Double) -> String { String(format: "%.0f fps", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
    var fakeModeNotice: String {
        "Demo mode: thumbnails come from fake clients. Switching and minimizing only change demo data."
    }
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "The config file is version \(found); this build supports up to \(supported). "
            + "Running with defaults; changes will not be saved."
    }
    func loadFailedNotice(_ message: String) -> String {
        "Could not read the config file (\(message)). Running with defaults; changes will not be saved."
    }
    func quarantinedNotice(_ path: String) -> String {
        "The config file was corrupt and has been moved to \(path). Using defaults."
    }
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "reading \(path) failed: \(reason)"
        case .write: return "writing \(path) failed: \(reason)"
        case .quarantine: return "moving the corrupt file \(path) aside failed: \(reason)"
        case .backup: return "backing up the old config to \(path) failed: \(reason)"
        }
    }
    var configContentInvalid: String { "the file content is not a valid config" }

    // 页名称。
    var pageClients: String { "Clients" }
    var pagePreviews: String { "Previews & Layout" }
    var pageSwitching: String { "Switching & Hotkeys" }
    var pageAlerts: String { "Alerts" }
    var pageProfiles: String { "Profiles" }
    var pageGeneral: String { "General" }
    var pagePermissions: String { "Permissions" }
    var pageAbout: String { "About" }

    // 客户端页。
    var clientsSubtitle: String { "Running clients and characters known to this profile." }
    var hideAllThumbnails: String { "Hide all thumbnails" }
    var hideAllHotkeyLabel: String { "Hotkey" }
    var hideAllScopeLabel: String { "Scope" }
    var hideAllHotkeyFooter: String {
        "Use a modifier combination with a key (such as ⌃⌥⌘H), or with the middle or a side mouse button. All hotkeys above use the one scope chosen here."
    }
    var charactersHeader: String { "Characters" }
    var charactersFooter: String { "The color is used for the highlight border when this character is active." }
    var noCharacters: String { "No characters yet. Start EVE and log in a character." }
    var loginClientsHeader: String { "Clients at the login screen" }
    var showThumbnail: String { "Show thumbnail" }
    var highlightColorHelp: String { "Highlight color when active" }

    // 预览与布局页。
    var previewsSubtitle: String { "Thumbnail size, appearance and behavior. Changes apply immediately." }
    var defaultSize: String { "Default size" }
    var minimumSize: String { "Minimum size" }
    var maximumSize: String { "Maximum size" }
    var unifySizes: String { "Reset all thumbnails to default size" }
    var appearanceHeader: String { "Appearance" }
    var opacity: String { "Opacity" }
    var showTitle: String { "Show character name" }
    var titleFontSize: String { "Title font size" }
    var titleColor: String { "Title color" }
    var borderEnabled: String { "Show border" }
    var borderColor: String { "Border color" }
    var borderThickness: String { "Border thickness" }
    var highlightEnabled: String { "Highlight active client" }
    var highlightColor: String { "Highlight color" }
    var highlightThickness: String { "Highlight thickness" }
    var zoomHeader: String { "Zoom on Hover" }
    var zoomEnabled: String { "Zoom when hovering" }
    var zoomFactor: String { "Zoom factor" }
    var zoomAnchor: String { "Anchor" }
    var behaviorHeader: String { "Behavior" }
    var alwaysOnTop: String { "Keep thumbnails on top" }
    var hideActiveClient: String { "Hide the active client's thumbnail" }
    var hideWhenNotEVE: String { "Hide thumbnails when EVE is not in front" }
    var hideDelay: String { "Hide delay" }
    var layoutHeader: String { "Layout" }
    var snapEnabled: String { "Snap while dragging" }
    var lockAspectRatio: String { "Keep aspect ratio when resizing" }
    var lockLayout: String { "Lock layout" }
    var gestureHint: String {
        "Right-drag or Option-drag to move; move the pointer to an edge and left-drag to resize; hold Shift to bypass snapping."
    }
    var captureHeader: String { "Capture & Position" }
    var frameRate: String { "Frame rate" }
    var titleBarCrop: String { "Title bar crop" }
    var pollInterval: String { "Window polling interval" }
    var loginPositionX: String { "Login thumbnail X" }
    var loginPositionY: String { "Login thumbnail Y" }
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "Top left"
        case .n: return "Top"
        case .ne: return "Top right"
        case .w: return "Left"
        case .center: return "Center"
        case .e: return "Right"
        case .sw: return "Bottom left"
        case .s: return "Bottom"
        case .se: return "Bottom right"
        }
    }

    // 配置方案页。
    var profilesSubtitle: String { "Each profile is a full set of settings, layouts and cycle groups." }
    var activeBadge: String { "Active" }
    var switchTo: String { "Switch" }
    var rename: String { "Rename" }
    var clone: String { "Duplicate" }
    var newProfile: String { "New Profile" }
    var configFile: String { "Config file" }
    var revealConfig: String { "Show in Finder" }
    var profileName: String { "Profile name" }
    var profileNameRule: String { "Use 1–64 characters, unique among profiles (case-insensitive)." }
    func deleteProfileConfirm(_ name: String) -> String { "Delete profile “\(name)”? This cannot be undone." }
    func cloneTitle(_ name: String) -> String { "Duplicate “\(name)”" }
    func renameTitle(_ name: String) -> String { "Rename “\(name)”" }
    func copyName(_ name: String) -> String { "\(name) Copy" }

    // 通用页。
    var generalSubtitle: String { "Settings shared by all profiles." }
    var interfaceLanguage: String { "Interface language" }
    var followSystem: String { "Follow System" }
    var machineTranslationNote: String { "Some translations are machine-generated. Corrections are welcome." }
    var showDockIcon: String { "Show icon in Dock" }
    var showDockIconHelp: String { "When off, EVE-O Preview shows only its menu bar icon." }

    // 权限页。
    var permissionsSubtitle: String { "Both permissions are granted in System Settings > Privacy & Security." }
    var screenRecording: String { "Screen Recording" }
    var screenRecordingDetail: String {
        "Needed to capture client windows and read titles. Usually takes effect after relaunching."
    }
    var accessibility: String { "Accessibility" }
    var accessibilityDetail: String {
        "Needed to restore, raise and minimize client windows, and for mouse-button hotkeys. Takes effect immediately."
    }
    var granted: String { "Granted" }
    var notGranted: String { "Not granted" }
    var request: String { "Request" }
    var openSystemSettings: String { "Open System Settings" }
    var relaunchHint: String { "Relaunch after granting Screen Recording" }
    var relaunch: String { "Relaunch" }
    var signingHint: String {
        "macOS records permissions by code signature. Ad-hoc builds need re-granting after every rebuild; "
            + "see the README for a self-signed certificate."
    }

    // 关于页。
    var version: String { "Version" }
    var devVersion: String { "Development build" }
    var aboutSubtitle: String { "Live thumbnails and fast switching for multiple EVE Online clients, native on macOS." }
    var aboutSummary: String {
        "One live thumbnail per client, click to switch, cycle-group hotkeys and multiple profiles."
    }
    var upstreamHeader: String { "Upstream & License" }
    var upstreamText: String { "This app re-implements the features of EveOPlus/eve-o-preview natively for macOS." }
    var licenseText: String { "Like upstream, it is released under the GNU General Public License v3.0." }
    var disclaimerHeader: String { "Notes" }
    var focusOnlyText: String {
        "This tool only switches window focus. It never broadcasts input to multiple clients "
            + "and never reads or modifies game memory."
    }
    var gameLogText: String {
        "Combat alerts only read the game log files that the EVE client writes. "
            + "They never read game memory, modify files or send input."
    }
    var networkText: String {
        "EVE-O Preview contacts GitHub only to check for and download updates; you can turn this off under General. "
            + "Problem reports are never sent automatically."
    }
    var eveIPText: String {
        "EVE Online and related logos are trademarks of CCP ehf. "
            + "This project is not affiliated with or endorsed by CCP."
    }
}

// MARK: - 预警与翻译（docs/macos/design-intel-translate.md 第 11 节）
// 用词按 11 节的词表：浮窗、预警、频道、聊天日志、模型服务。

/// 菜单栏的两个浮窗开关，英文。
extension MenuStringsEN {
    var showIntelOverlay: String { "Show Intel Overlay" }
    var showTranslationOverlay: String { "Show Translation Overlay" }
}

/// 两个新页的页名、关于页的说明与聊天日志的状态，英文。
extension SettingsStringsEN {
    var pageIntel: String { "Intel" }
    var pageTranslation: String { "Translation" }
    var aboutChatLogsNote: String {
        "Intel and translation only read chat logs and game logs. Translation sends chat text to the model service you choose. When online name checking is on, pilot names that run together in intel messages are sent to CCP's ESI API."
    }
    var chatLogStatusStopped: String { "Off" }
    func chatLogStatusWatching(directory: String, files: Int) -> String {
        "Watching \(directory), following \(files == 1 ? "1 log file" : "\(files) log files")"
    }
    func chatLogStatusDirectoryNotFound(_ path: String) -> String { "Chat log folder not found: \(path)" }
    func chatLogStatusAccessDenied(_ path: String) -> String { "No permission to read \(path)" }
    var chatLogHelp: String {
        "The EVE client must be set to log chat to file. The log folder is set on the Alerts page."
    }
}
