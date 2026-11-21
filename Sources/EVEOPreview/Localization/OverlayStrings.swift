// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域的界面文字（docs/design-intel-translate.md 第 11 节，28 条）：两个浮窗的列表说明与右键菜单，
// 以及「预警」「翻译」两页共用的浮窗设置与频道列表。
// 每种语言一个不含存储属性的结构体实现本协议（Localization/<语言>/OverlayStrings+<语言>.swift），
// 漏了一条时结构体不满足协议，编译不过。带参数的文字写成函数，各语言自己拼接（俄语的复数由俄语实现处理）。
// 访问方式是 L10n.overlay；只被 WP-A 的文件使用（浮窗、ChannelListEditor、OverlaySettingsSection）。

import Foundation

/// 浮窗与两页共用设置控件的文字。
protocol OverlayStrings: Sendable {
    // MARK: 浮窗的列表
    /// 新消息条：离开底部后新到了几条。
    func newMessages(_ count: Int) -> String
    /// 没有活动角色时列表位置的说明。
    var noActiveCharacter: String { get }
    /// 有活动角色但还没有消息时的说明。
    var emptyList: String { get }

    // MARK: 浮窗的右键菜单
    /// 滚动到最新。
    var menuScrollToLatest: String { get }
    /// 复制光标下的那一条。
    var menuCopyLine: String { get }
    /// 「在浏览器中打开」子菜单（6.9 节增补）。
    var menuOpenInBrowser: String { get }
    /// 清空活动角色在这个浮窗里的列表。
    var menuClear: String { get }
    /// 锁定布局（带勾选）。
    var menuLockLayout: String { get }
    /// 恢复默认位置与尺寸。
    var menuResetFrame: String { get }
    /// 隐藏此浮窗（关掉这个功能）。
    var menuHide: String { get }
    /// 打开设置窗口的对应页。
    var menuOpenSettings: String { get }

    // MARK: 浮窗设置（OverlaySettingsSection）
    /// 一组的标题。
    var overlayHeader: String { get }
    /// 背景不透明度。
    var opacity: String { get }
    /// 字号。
    var fontSize: String { get }
    /// 「恢复默认位置」按钮。
    var resetFrame: String { get }
    /// 手势说明。
    var gestureHelp: String { get }
    /// 「位置」一行的标签（X、Y 两个数字框），v1.2.1。
    var positionLabel: String { get }
    /// 「尺寸」一行的标签（宽、高两个数字框），v1.2.1。
    var sizeLabel: String { get }
    /// 位置与尺寸的说明：坐标原点、单位、尺寸上下限与拉回屏幕的规则，v1.2.1。
    var frameHelp: String { get }

    // MARK: 频道列表（ChannelListEditor）
    /// 一组的标题。
    var channelsHeader: String { get }
    /// 「从日志添加」菜单。
    var addFromLogs: String { get }
    /// 「按名称添加」输入框的占位文字。
    var addByNamePlaceholder: String { get }
    /// 「移除」按钮。
    var removeChannel: String { get }
    /// 列表为空时的说明。
    var noChannels: String { get }
    /// 菜单末尾的「刷新」。
    var refreshChannels: String { get }
    /// 日志里没有最近的聊天日志时，菜单里置灰的一项。
    var noDiscoveredChannels: String { get }
    /// 菜单项里频道名后面的「N 个角色」。
    func channelListeners(_ count: Int) -> String
    /// 内置频道：本地。
    var builtInLocal: String { get }
    /// 内置频道：军团。
    var builtInCorp: String { get }
    /// 内置频道：联盟。
    var builtInAlliance: String { get }
    /// 内置频道：舰队。
    var builtInFleet: String { get }
}

extension OverlayStrings {
    /// 内置频道的显示名：按 ChannelRef 的 ID（local、corp、alliance、fleet）取本地化的名字；其他 ID 返回 nil。
    func builtInName(id: String?) -> String? {
        switch id?.lowercased() {
        case "local": return builtInLocal
        case "corp": return builtInCorp
        case "alliance": return builtInAlliance
        case "fleet": return builtInFleet
        default: return nil
        }
    }
}

extension L10n {
    /// 浮窗域的文字。`switch` 不写 `default`：以后加语言时编译器会指出这里要补。
    static var overlay: any OverlayStrings {
        switch L10n.language {
        case .en: return OverlayStringsEN()
        case .zh: return OverlayStringsZH()
        case .ru: return OverlayStringsRU()
        case .ja: return OverlayStringsJA()
        case .ko: return OverlayStringsKO()
        case .fr: return OverlayStringsFR()
        case .de: return OverlayStringsDE()
        case .es: return OverlayStringsES()
        }
    }
}
