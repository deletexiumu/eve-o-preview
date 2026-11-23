// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的文字协议（反馈文档 5.3 节）。「切换与热键」页的文字属于热键域（`HotkeyStrings`，WP-2），
// 「提醒」页的文字属于战斗提醒域（`CombatStrings`，WP-3），都不在这里。
//
// 按页分组，组内顺序与页面上从上到下的顺序一致。翻译时注意：
// - 侧栏只有 200 点宽，放图标后约剩 140 点，页名称宜短（俄文尤其）。
// - 表单行的标签在左、控件在右，标签过长会把控件挤到下一行。
// - 系统权限与系统设置里的名称，用 macOS 在该语言下的官方叫法。

import Foundation
import EVEOPreviewCore

/// 设置窗口的文字。
protocol SettingsStrings: Sendable {
    // MARK: 窗口与通用

    /// 设置窗口的标题。
    var windowTitle: String { get }
    /// 长度单位「点」，接在数字后面（如「28 点」）。
    var points: String { get }
    /// 把按角色的颜色恢复成默认值的按钮。
    var reset: String { get }
    /// 颜色没有单独设置、使用全局颜色时的说明。
    var defaultColor: String { get }
    /// 对话框的取消按钮。
    var cancel: String { get }
    /// 对话框的确定按钮。
    var confirm: String { get }
    /// 删除按钮。
    var delete: String { get }
    /// 角色在线的标记。
    var online: String { get }
    /// 角色离线的标记。
    var offline: String { get }
    /// 循环方向：前进。
    var forward: String { get }
    /// 循环方向：后退。
    var backward: String { get }
    /// 秒数，保留 1 位小数，如「2.5 秒」。用在隐藏延迟的滑块旁。
    func seconds(_ value: Double) -> String
    /// 帧率，取整，如「10 帧每秒」。用在帧率的滑块旁。
    func fps(_ value: Double) -> String
    /// 毫秒数，取整，如「500 毫秒」。用在窗口检测间隔的滑块旁。
    func milliseconds(_ value: Double) -> String
    /// 演示模式下各页顶部的提示条。
    var fakeModeNotice: String { get }
    /// 配置文件来自更新的版本，本次以默认设置运行且不保存。
    func newerSchemaNotice(found: Int, supported: Int) -> String
    /// 读配置文件失败，括号里是系统给的错误说明。
    func loadFailedNotice(_ message: String) -> String
    /// 损坏的配置文件已被改名隔离，参数是改名后的路径。
    func quarantinedNotice(_ path: String) -> String
    /// 读写配置文件某一步失败的说明，放进 `loadFailedNotice` 的括号里。reason 是系统给的说明。
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String
    /// 配置文件内容不能解析的通用说明，放进 `loadFailedNotice` 的括号里。
    var configContentInvalid: String { get }

    // MARK: 页名称
    // 侧栏与每页顶部的标题共用。

    /// 客户端页。
    var pageClients: String { get }
    /// 预览与布局页。
    var pagePreviews: String { get }
    /// 切换与热键页（页内文字属于热键域，页名留在这里，侧栏统一取）。
    var pageSwitching: String { get }
    /// 提醒页（页内文字属于战斗提醒域）。
    var pageAlerts: String { get }
    /// 预警页（页内文字属于预警域 `IntelStrings`；页名留在这里，侧栏统一取）。
    var pageIntel: String { get }
    /// 翻译页（页内文字属于翻译域 `TranslationStrings`）。
    var pageTranslation: String { get }
    /// 配置方案页。
    var pageProfiles: String { get }
    /// 通用页：界面语言。
    var pageGeneral: String { get }
    /// 权限页。
    var pagePermissions: String { get }
    /// 关于页。
    var pageAbout: String { get }

    // MARK: 客户端页
    // 「全部隐藏」是会话开关；「显示缩略图」是按角色的持久化开关，两者文字要区分开。

    /// 页标题下的说明。
    var clientsSubtitle: String { get }
    /// 「全部隐藏」开关。
    var hideAllThumbnails: String { get }
    /// 「全部隐藏」的快捷键一行的标题。
    var hideAllHotkeyLabel: String { get }
    /// 「全部隐藏」快捷键的生效范围（全局或仅游戏内）一行的标题。
    var hideAllScopeLabel: String { get }
    /// 「全部隐藏」一组下方的说明：快捷键可以是键盘组合或修饰键加鼠标按键，范围作用于这一组全部快捷键。
    var hideAllHotkeyFooter: String { get }
    /// 角色列表的组标题。
    var charactersHeader: String { get }
    /// 角色列表下方的说明：每行的颜色是该角色活动时的高亮颜色。
    var charactersFooter: String { get }
    /// 还没有任何角色时的说明。
    var noCharacters: String { get }
    /// 停在登录界面、还没有角色名的客户端的组标题。
    var loginClientsHeader: String { get }
    /// 按角色的「显示缩略图」开关。
    var showThumbnail: String { get }
    /// 角色颜色按钮的悬停说明。
    var highlightColorHelp: String { get }

    // MARK: 预览与布局页
    // 名称与配置字段一一对应（见架构文档 5.2 节），新增字段时在这里补一条。

    /// 页标题下的说明。
    var previewsSubtitle: String { get }
    /// 缩略图的默认尺寸（宽 × 高）。
    var defaultSize: String { get }
    /// 缩略图的最小尺寸。
    var minimumSize: String { get }
    /// 缩略图的最大尺寸。
    var maximumSize: String { get }
    /// 清掉各缩略图的自定义尺寸、全部回到默认尺寸的按钮。
    var unifySizes: String { get }
    /// 「外观」组的标题。
    var appearanceHeader: String { get }
    /// 未悬停时缩略图的不透明度。
    var opacity: String { get }
    /// 是否在缩略图左上角显示角色名。
    var showTitle: String { get }
    /// 角色名的字号。
    var titleFontSize: String { get }
    /// 角色名的颜色。
    var titleColor: String { get }
    /// 每个缩略图都有的中性色边框的开关（第一轮反馈 F1）。
    var borderEnabled: String { get }
    /// 边框的颜色。
    var borderColor: String { get }
    /// 边框的粗细，单位是点。
    var borderThickness: String { get }
    /// 活动客户端高亮边框的开关。
    var highlightEnabled: String { get }
    /// 高亮边框的颜色（全局，客户端页可以按角色覆盖）。
    var highlightColor: String { get }
    /// 高亮边框的粗细。
    var highlightThickness: String { get }
    /// 「悬停放大」组的标题。
    var zoomHeader: String { get }
    /// 鼠标悬停时放大缩略图的开关。
    var zoomEnabled: String { get }
    /// 放大倍数。
    var zoomFactor: String { get }
    /// 放大时保持不动的那个点（锚点）。
    var zoomAnchor: String { get }
    /// 「行为」组的标题。
    var behaviorHeader: String { get }
    /// 缩略图置于其他窗口之上。
    var alwaysOnTop: String { get }
    /// 隐藏当前活动客户端自己的缩略图。
    var hideActiveClient: String { get }
    /// 前台应用不是 EVE 时隐藏全部缩略图。
    var hideWhenNotEVE: String { get }
    /// 上一条的隐藏延迟。
    var hideDelay: String { get }
    /// 「布局」组的标题。
    var layoutHeader: String { get }
    /// 拖动时吸附到屏幕边缘与其他缩略图。
    var snapEnabled: String { get }
    /// 缩放时保持宽高比。
    var lockAspectRatio: String { get }
    /// 锁定布局：禁止移动与缩放。
    var lockLayout: String { get }
    /// 鼠标手势的说明（小字）。
    var gestureHint: String { get }
    /// 「捕获与位置」组的标题。
    var captureHeader: String { get }
    /// 捕获帧率。
    var frameRate: String { get }
    /// 从画面顶部裁掉的标题栏高度。
    var titleBarCrop: String { get }
    /// 检测窗口变化的轮询间隔。
    var pollInterval: String { get }
    /// 登录界面客户端的缩略图起始位置的 X 坐标。
    var loginPositionX: String { get }
    /// 同上，Y 坐标。
    var loginPositionY: String { get }
    /// 悬停放大锚点的名称（九宫格的 9 个位置）。
    func anchorName(_ anchor: ZoomAnchor) -> String

    // MARK: 配置方案页
    // 术语按架构文档第 13 节：「配置方案」指 profile，「配置文件」专指 config.json。

    /// 页标题下的说明。
    var profilesSubtitle: String { get }
    /// 当前配置方案旁的标记。
    var activeBadge: String { get }
    /// 切换到这个配置方案的按钮。
    var switchTo: String { get }
    /// 改名按钮。
    var rename: String { get }
    /// 克隆按钮。
    var clone: String { get }
    /// 新建配置方案的按钮。
    var newProfile: String { get }
    /// 配置文件路径一行的标签。
    var configFile: String { get }
    /// 在访达中显示配置文件的按钮（「访达」即 Finder，用该语言下 macOS 的叫法）。
    var revealConfig: String { get }
    /// 名称输入框的占位文字。
    var profileName: String { get }
    /// 名称规则的说明。
    var profileNameRule: String { get }
    /// 删除前的确认，参数是配置方案名称。
    func deleteProfileConfirm(_ name: String) -> String
    /// 克隆对话框的标题。
    func cloneTitle(_ name: String) -> String
    /// 改名对话框的标题。
    func renameTitle(_ name: String) -> String
    /// 克隆时建议的新名称，如「主号 副本」。
    func copyName(_ name: String) -> String

    // MARK: 通用页
    // 语言选项本身用各语言的自称（AppLanguage.autonym），不翻译；这里只有标签与说明。

    /// 页标题下的说明。
    var generalSubtitle: String { get }
    /// 语言选择器的标签。
    var interfaceLanguage: String { get }
    /// 语言选项「跟随系统」。
    var followSystem: String { get }
    /// 语言选择下方的说明：部分译文由机器生成，欢迎指正（反馈文档 5.2 节）。
    var machineTranslationNote: String { get }
    /// 「通用」页：「在 Dock 中显示图标」开关（v1.1）。
    var showDockIcon: String { get }
    /// 开关下方的说明。
    var showDockIconHelp: String { get }

    // MARK: 权限页
    // 每项权限写清缺了它哪些功能不可用，与架构文档 4.4 节的权限矩阵一致。

    /// 页标题下的说明：两项权限在系统设置的哪里授予。
    var permissionsSubtitle: String { get }
    /// 屏幕录制权限的名称。
    var screenRecording: String { get }
    /// 屏幕录制权限的用途。
    var screenRecordingDetail: String { get }
    /// 辅助功能权限的名称。
    var accessibility: String { get }
    /// 辅助功能权限的用途，含鼠标按键热键（反馈文档 6.6 节）。
    var accessibilityDetail: String { get }
    /// 已授权。
    var granted: String { get }
    /// 未授权。
    var notGranted: String { get }
    /// 请求授权的按钮。
    var request: String { get }
    /// 打开系统设置的按钮。
    var openSystemSettings: String { get }
    /// 「重新启动」一行的标签。
    var relaunchHint: String { get }
    /// 重新启动本应用的按钮。
    var relaunch: String { get }
    /// 代码签名与授权的说明（小字）。
    var signingHint: String { get }

    // MARK: 关于页
    // 上游归属、许可证与「只切换焦点、不广播输入」的说明是发布时的必备内容（架构文档 7.4 节、R7）。

    /// 版本一行的标签。
    var version: String { get }
    /// 没有 Info.plist（`swift run`）时显示的版本。
    var devVersion: String { get }
    /// 应用名下方的一句话介绍。
    var aboutSubtitle: String { get }
    /// 功能概述。
    var aboutSummary: String { get }
    /// 「上游项目与许可证」组的标题。
    var upstreamHeader: String { get }
    /// 与上游项目的关系。
    var upstreamText: String { get }
    /// 许可证说明。
    var licenseText: String { get }
    /// 「说明」组的标题。
    var disclaimerHeader: String { get }
    /// 只切换焦点、不广播输入、不碰游戏内存。
    var focusOnlyText: String { get }
    /// 战斗提醒只读游戏日志（反馈文档 R17）。
    var gameLogText: String { get }
    /// 联网说明：只在检查和下载更新时访问 GitHub，可在「通用」页关闭；问题报告不会自动发送（v1.1 设计 10.1 节）。
    /// 「通用」用该语言下通用页的页名（`pageGeneral`）。
    var networkText: String { get }
    /// CCP 的商标声明。
    var eveIPText: String { get }
    /// 预警与翻译只读聊天日志和游戏日志；翻译会把聊天内容发给用户选择的模型服务（R32、R38）；
    /// 打开「联网核对人名」时，连在一起的人名会发给 CCP 的 ESI 接口（6.9 节）。
    var aboutChatLogsNote: String { get }

    // MARK: 聊天日志的状态（预警页、翻译页与两个浮窗的状态行共用）
    // 放在设置域而不是某一个功能的域里，因为两个并行的工作包都用到（docs/macos/design-intel-translate.md 第 11 节）。

    /// 两个功能都没开、没有在读聊天日志。
    var chatLogStatusStopped: String { get }
    /// 正在监视聊天日志目录，跟踪 files 个文件。
    func chatLogStatusWatching(directory: String, files: Int) -> String
    /// 找不到聊天日志目录。
    func chatLogStatusDirectoryNotFound(_ path: String) -> String
    /// 没有读取聊天日志目录的权限。
    func chatLogStatusAccessDenied(_ path: String) -> String
    /// 说明：EVE 客户端要开启把聊天写入文件的设置；日志目录在「提醒」页设置（用该语言的提醒页页名）。
    var chatLogHelp: String { get }
}
