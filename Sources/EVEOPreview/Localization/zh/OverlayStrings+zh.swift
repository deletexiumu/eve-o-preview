// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域的中文文字（docs/design-intel-translate.md 第 11 节）。
// 用词与菜单栏的「显示预警浮窗」「显示翻译浮窗」一致：浮窗、频道、锁定布局。

import Foundation

/// 浮窗与两页共用设置控件的中文文字。
struct OverlayStringsZH: OverlayStrings {
    // MARK: 浮窗的列表
    func newMessages(_ count: Int) -> String { "\(count) 条新消息" }
    var noActiveCharacter: String { "当前窗口没有角色" }
    var emptyList: String { "还没有消息" }

    // MARK: 浮窗的右键菜单
    var menuScrollToLatest: String { "滚动到最新" }
    var menuCopyLine: String { "复制这一条" }
    var menuOpenInBrowser: String { "在浏览器中打开" }
    var menuClear: String { "清空列表" }
    var menuLockLayout: String { "锁定布局" }
    var menuResetFrame: String { "恢复默认位置与尺寸" }
    var menuHide: String { "隐藏此浮窗" }
    var menuOpenSettings: String { "打开设置…" }

    // MARK: 浮窗设置
    var overlayHeader: String { "浮窗" }
    var opacity: String { "背景不透明度" }
    var fontSize: String { "字号" }
    var resetFrame: String { "恢复默认位置" }
    var gestureHelp: String { "右键拖动或按住 Option 用左键拖动可移动浮窗，从边缘拖动可缩放，滚轮可滚动列表。" }

    // MARK: 频道列表
    var channelsHeader: String { "频道" }
    var addFromLogs: String { "从日志添加" }
    var addByNamePlaceholder: String { "输入频道名称后按回车" }
    var removeChannel: String { "移除" }
    var noChannels: String { "还没有频道" }
    var refreshChannels: String { "刷新" }
    var noDiscoveredChannels: String { "日志目录里没有最近的聊天日志" }
    func channelListeners(_ count: Int) -> String { "\(count) 个角色" }

    // MARK: 内置频道
    var builtInLocal: String { "本地" }
    var builtInCorp: String { "军团" }
    var builtInAlliance: String { "联盟" }
    var builtInFleet: String { "舰队" }
}
