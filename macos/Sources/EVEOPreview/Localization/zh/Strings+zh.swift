// SPDX-License-Identifier: GPL-3.0-or-later
//
// 中文（简体）界面文字。沿用 v1 的中文文字；第一轮反馈新增边框、通用页与「关于」页的一句说明。
// 成员顺序与协议（Strings.swift、SettingsStrings.swift）一致，每条的用途见协议里的注释。
// 用词按反馈文档 5.5 节的词表与架构文档第 13 节的术语表：「配置方案」指 profile，「配置文件」指 config.json。

import Foundation
import EVEOPreviewCore

// MARK: - 菜单栏

/// 菜单栏菜单，中文。
struct MenuStringsZH: MenuStrings {
    var showAll: String { "显示全部缩略图" }
    var hideAll: String { "隐藏全部缩略图" }
    var profiles: String { "配置方案" }
    var minimizeAll: String { "全部最小化" }
    var settings: String { "设置…" }
    var quit: String { "退出 EVE-O Preview" }
    var permissionsMissing: String { "缺少权限，点此查看…" }
    var fakeMode: String { "演示模式（假客户端）" }
    var noClients: String { "没有发现 EVE 客户端" }
    func resumeCapture(_ title: String) -> String { "恢复捕获：\(title)" }
    func clientCount(_ count: Int) -> String { "\(count) 个客户端" }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，中文。用 macOS 简体中文的菜单名（如「拷贝」而不是「复制」）。
struct EditMenuStringsZH: EditMenuStrings {
    var title: String { "编辑" }
    var undo: String { "撤销" }
    var redo: String { "重做" }
    var cut: String { "剪切" }
    var copy: String { "拷贝" }
    var paste: String { "粘贴" }
    var selectAll: String { "全选" }
    var closeWindow: String { "关闭窗口" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，中文。
struct ThumbnailStringsZH: ThumbnailStrings {
    var minimize: String { "最小化" }
    var minimizeAll: String { "全部最小化" }
    var skipCycle: String { "跳过循环" }
    var hide: String { "隐藏此缩略图" }
    var resetSize: String { "恢复默认尺寸" }
    var resumeCapture: String { "恢复捕获" }
    var needsAccessibility: String { "需要辅助功能权限" }
    func unavailable(_ item: String, reason: String) -> String { "\(item)（\(reason)）" }
    var settings: String { "设置…" }
    // 占位文字。
    var waiting: String { "等待画面…" }
    var needsScreenRecording: String { "缺少屏幕录制权限" }
    var captureStopped: String { "捕获已停止，右键菜单可恢复" }
    var minimized: String { "已最小化" }
}

// MARK: - 设置窗口

/// 设置窗口，中文。单位写中文：「点」「秒」「毫秒」。
struct SettingsStringsZH: SettingsStrings {
    // 窗口与通用。
    var windowTitle: String { "EVE-O Preview 设置" }
    var points: String { "点" }
    var reset: String { "恢复" }
    var defaultColor: String { "默认" }
    var cancel: String { "取消" }
    var confirm: String { "确定" }
    var delete: String { "删除" }
    var online: String { "在线" }
    var offline: String { "离线" }
    var forward: String { "前进" }
    var backward: String { "后退" }
    func seconds(_ value: Double) -> String { String(format: "%.1f 秒", value) }
    func fps(_ value: Double) -> String { String(format: "%.0f 帧每秒", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f 毫秒", value) }
    var fakeModeNotice: String { "演示模式：缩略图来自假客户端，切换与最小化只改演示数据，不影响真实窗口。" }
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "配置文件的版本是 \(found)，本版本只支持到 \(supported)。现在使用默认设置运行，本次的改动不会保存。"
    }
    func loadFailedNotice(_ message: String) -> String {
        "读取配置文件失败（\(message)）。现在使用默认设置运行，本次的改动不会保存。"
    }
    func quarantinedNotice(_ path: String) -> String { "配置文件已损坏，原文件已改名为 \(path)，现在使用默认设置。" }
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "读取 \(path) 失败：\(reason)"
        case .write: return "写入 \(path) 失败：\(reason)"
        case .quarantine: return "隔离损坏的配置文件 \(path) 失败：\(reason)"
        case .backup: return "把旧版本配置备份到 \(path) 失败：\(reason)"
        }
    }
    var configContentInvalid: String { "文件内容不是有效的配置" }

    // 页名称。
    var pageClients: String { "客户端" }
    var pagePreviews: String { "预览与布局" }
    var pageSwitching: String { "切换与热键" }
    var pageAlerts: String { "提醒" }
    var pageProfiles: String { "配置方案" }
    var pageGeneral: String { "通用" }
    var pagePermissions: String { "权限" }
    var pageAbout: String { "关于" }

    // 客户端页。
    var clientsSubtitle: String { "在线客户端与配置里出现过的角色。" }
    var hideAllThumbnails: String { "隐藏全部缩略图" }
    var hideAllHotkeyLabel: String { "快捷键" }
    var hideAllScopeLabel: String { "生效范围" }
    var hideAllHotkeyFooter: String { "可以是修饰键加普通键（如 ⌃⌥⌘H），也可以是修饰键加鼠标中键或侧键。上面的全部快捷键统一按这里选的一种范围生效。" }
    var charactersHeader: String { "角色" }
    var charactersFooter: String { "颜色是该角色作为活动客户端时的高亮边框颜色；「默认」表示使用全局高亮颜色。" }
    var noCharacters: String { "还没有发现任何角色。启动 EVE 并选择角色后会出现在这里。" }
    var loginClientsHeader: String { "登录界面的客户端" }
    var showThumbnail: String { "显示缩略图" }
    var highlightColorHelp: String { "活动时的高亮颜色" }

    // 预览与布局页。
    var previewsSubtitle: String { "缩略图的尺寸、外观与行为。改动立即生效。" }
    var defaultSize: String { "默认尺寸" }
    var minimumSize: String { "最小尺寸" }
    var maximumSize: String { "最大尺寸" }
    var unifySizes: String { "统一全部缩略图尺寸" }
    var appearanceHeader: String { "外观" }
    var opacity: String { "透明度" }
    var showTitle: String { "显示角色名" }
    var titleFontSize: String { "标题字号" }
    var titleColor: String { "标题颜色" }
    var borderEnabled: String { "显示边框" }
    var borderColor: String { "边框颜色" }
    var borderThickness: String { "边框粗细" }
    var highlightEnabled: String { "高亮活动客户端" }
    var highlightColor: String { "高亮颜色" }
    var highlightThickness: String { "高亮粗细" }
    var zoomHeader: String { "悬停放大" }
    var zoomEnabled: String { "鼠标悬停时放大" }
    var zoomFactor: String { "放大倍数" }
    var zoomAnchor: String { "锚点" }
    var behaviorHeader: String { "行为" }
    var alwaysOnTop: String { "缩略图置顶" }
    var hideActiveClient: String { "隐藏活动客户端的缩略图" }
    var hideWhenNotEVE: String { "离开 EVE 时隐藏缩略图" }
    var hideDelay: String { "隐藏延迟" }
    var layoutHeader: String { "布局" }
    var snapEnabled: String { "拖动时吸附" }
    var lockAspectRatio: String { "缩放时保持宽高比" }
    var lockLayout: String { "锁定布局" }
    var gestureHint: String {
        "右键拖动或 Option+左键拖动可移动缩略图；鼠标移到边缘（光标变为双向箭头）后直接用左键拖动即可缩放；拖动时按住 Shift 不吸附。"
    }
    var captureHeader: String { "捕获与位置" }
    var frameRate: String { "帧率" }
    var titleBarCrop: String { "裁掉标题栏" }
    var pollInterval: String { "窗口检测间隔" }
    var loginPositionX: String { "登录缩略图位置 X" }
    var loginPositionY: String { "登录缩略图位置 Y" }
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "左上"
        case .n: return "上"
        case .ne: return "右上"
        case .w: return "左"
        case .center: return "中心"
        case .e: return "右"
        case .sw: return "左下"
        case .s: return "下"
        case .se: return "右下"
        }
    }

    // 配置方案页。
    var profilesSubtitle: String { "每个配置方案是一套完整的设置、布局与循环组。" }
    var activeBadge: String { "当前" }
    var switchTo: String { "切换" }
    var rename: String { "改名" }
    var clone: String { "克隆" }
    var newProfile: String { "新建配置方案" }
    var configFile: String { "配置文件" }
    var revealConfig: String { "在访达中显示" }
    var profileName: String { "配置方案名称" }
    var profileNameRule: String { "名称应为 1～64 个字，且不与其他配置方案重名（不区分大小写）。" }
    func deleteProfileConfirm(_ name: String) -> String { "删除配置方案「\(name)」？此操作不能撤销。" }
    func cloneTitle(_ name: String) -> String { "克隆「\(name)」" }
    func renameTitle(_ name: String) -> String { "给「\(name)」改名" }
    func copyName(_ name: String) -> String { "\(name) 副本" }

    // 通用页。
    var generalSubtitle: String { "对全部配置方案生效的设置。" }
    var interfaceLanguage: String { "界面语言" }
    var followSystem: String { "跟随系统" }
    var machineTranslationNote: String { "部分译文由机器生成，欢迎指正。" }
    var showDockIcon: String { "在 Dock 中显示图标" }
    var showDockIconHelp: String { "关掉后只在菜单栏显示图标。" }

    // 权限页。
    var permissionsSubtitle: String { "两项权限都在「系统设置 > 隐私与安全性」里授予。" }
    var screenRecording: String { "屏幕录制" }
    var screenRecordingDetail: String { "用来捕获客户端画面与读取窗口标题。授权后通常要重新启动本应用才生效。" }
    var accessibility: String { "辅助功能" }
    var accessibilityDetail: String { "用来还原、提升与最小化客户端窗口，鼠标按键热键也依赖它。授权后立即生效。" }
    var granted: String { "已授权" }
    var notGranted: String { "未授权" }
    var request: String { "请求授权" }
    var openSystemSettings: String { "打开系统设置" }
    var relaunchHint: String { "授权屏幕录制后重新启动" }
    var relaunch: String { "重新启动" }
    var signingHint: String {
        "系统按代码签名记录授权。使用 ad-hoc 签名时，每次重新构建都要重新授权；README 说明了如何改用自签名证书。"
    }

    // 关于页。
    var version: String { "版本" }
    var devVersion: String { "开发版" }
    var aboutSubtitle: String { "EVE Online 多开客户端的实时缩略图与快速切换（macOS 原生版）。" }
    var aboutSummary: String { "每个客户端一个实时缩略图，点击切换，支持循环组热键与多套配置方案。" }
    var upstreamHeader: String { "上游项目与许可证" }
    var upstreamText: String { "本应用按 EveOPlus/eve-o-preview 的功能在 macOS 上重新实现，没有移植其源码。" }
    var licenseText: String { "本应用与上游一样以 GNU 通用公共许可证第 3 版（GPL-3.0）发布。" }
    var disclaimerHeader: String { "说明" }
    var focusOnlyText: String { "本工具只切换窗口焦点，不向多个客户端广播输入，不读取或修改游戏内存。" }
    var gameLogText: String { "战斗提醒只读取 EVE 客户端自己写出的游戏日志文件，不读游戏内存、不改文件、不发送输入。" }
    var networkText: String { "EVE-O Preview 只在检查和下载更新时访问 GitHub，可在「通用」页关闭。问题报告不会自动发送。" }
    var eveIPText: String { "EVE Online 及相关标志是 CCP ehf. 的商标。本项目与 CCP 没有关联，也未获其认可。" }
}

// MARK: - 预警与翻译（docs/design-intel-translate.md 第 11 节）
// 用词按 11 节的词表：浮窗、预警、频道、聊天日志、模型服务。

/// 菜单栏的两个浮窗开关，中文。
extension MenuStringsZH {
    var showIntelOverlay: String { "显示预警浮窗" }
    var showTranslationOverlay: String { "显示翻译浮窗" }
}

/// 两个新页的页名、关于页的说明与聊天日志的状态，中文。
extension SettingsStringsZH {
    var pageIntel: String { "预警" }
    var pageTranslation: String { "翻译" }
    var aboutChatLogsNote: String {
        "预警与翻译只读聊天日志和游戏日志。翻译会把聊天内容发给你选择的模型服务。打开「联网核对人名」时，预警消息里连在一起的人名会发给 CCP 的 ESI 接口。"
    }
    var chatLogStatusStopped: String { "未启用" }
    func chatLogStatusWatching(directory: String, files: Int) -> String {
        "监视中：\(directory)，跟踪 \(files) 个日志文件"
    }
    func chatLogStatusDirectoryNotFound(_ path: String) -> String { "找不到聊天日志目录：\(path)" }
    func chatLogStatusAccessDenied(_ path: String) -> String { "没有读取权限：\(path)" }
    var chatLogHelp: String {
        "EVE 客户端应开启把聊天记录写入文件的设置。日志目录在「提醒」页里设置。"
    }
}
