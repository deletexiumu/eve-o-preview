// SPDX-License-Identifier: GPL-3.0-or-later
//
// 菜单与缩略图三个域的协议（反馈文档 5.3 节）：菜单栏菜单、主菜单的「编辑」菜单、缩略图的右键菜单与占位文字。
// 不带参数的文字是只读属性，带参数的文字是函数；带参数的文字不用格式串，各语言在函数里自己拼接。
// 每条文字的注释写明它出现在界面的哪里，供翻译时判断长度与语气。

import Foundation

/// 菜单栏菜单的文字。菜单每次打开时重建，语言切换后不用另外刷新。
protocol MenuStrings: Sendable {
    /// 「全部隐藏」打开时显示的菜单项：显示全部缩略图。
    var showAll: String { get }
    /// 「全部隐藏」关闭时显示的菜单项：隐藏全部缩略图。
    var hideAll: String { get }
    /// 「配置方案」子菜单的标题。
    var profiles: String { get }
    /// 把全部 EVE 客户端窗口最小化的菜单项。
    var minimizeAll: String { get }
    /// 打开设置窗口的菜单项，以省略号结尾（macOS 的约定：点了会打开窗口）。
    var settings: String { get }
    /// 退出本应用的菜单项。
    var quit: String { get }
    /// 缺少系统权限时出现的菜单项，点击后打开设置窗口的权限页。
    var permissionsMissing: String { get }
    /// 演示模式下菜单顶部的提示行（不可点击）。
    var fakeMode: String { get }
    /// 没有发现任何 EVE 客户端时菜单顶部的提示行。
    var noClients: String { get }
    /// 「恢复捕获」菜单项，后面接客户端的窗口标题。
    func resumeCapture(_ title: String) -> String
    /// 菜单顶部的客户端数量，如「3 个客户端」。俄语按数字选复数形式。
    func clientCount(_ count: Int) -> String
    /// 带勾选的菜单项：显示预警浮窗（docs/macos/design-intel-translate.md 第 10 节、第 11 节）。
    var showIntelOverlay: String { get }
    /// 带勾选的菜单项：显示翻译浮窗。
    var showTranslationOverlay: String { get }
}

/// 主菜单「编辑」菜单的文字。应用没有 Dock 图标，菜单栏上看不到这个菜单，
/// 但设置窗口的文本框要靠它响应 Cmd+C、Cmd+V 等快捷键。语言切换后由 AppDelegate 重建。
/// 译文取 macOS 自己在该语言下的菜单名（AppKit 的 MenuCommands.loctable）。
protocol EditMenuStrings: Sendable {
    /// 菜单标题「编辑」。
    var title: String { get }
    /// 撤销。
    var undo: String { get }
    /// 重做。
    var redo: String { get }
    /// 剪切。
    var cut: String { get }
    /// 拷贝。
    var copy: String { get }
    /// 粘贴。
    var paste: String { get }
    /// 全选。
    var selectAll: String { get }
    /// 关闭窗口（Cmd+W）。
    var closeWindow: String { get }
}

/// 缩略图的右键菜单与占位文字。右键菜单每次打开时新建；占位文字在每次重算时重新设置。
protocol ThumbnailStrings: Sendable {
    // 右键菜单。

    /// 最小化这个客户端的窗口。
    var minimize: String { get }
    /// 最小化全部客户端的窗口。
    var minimizeAll: String { get }
    /// 循环切换时跳过这个角色（勾选项，只在本次运行有效）。
    var skipCycle: String { get }
    /// 隐藏这个角色的缩略图（对应客户端页的「显示缩略图」开关）。
    var hide: String { get }
    /// 恢复默认尺寸。
    var resetSize: String { get }
    /// 捕获停止后重新开始捕获。
    var resumeCapture: String { get }
    /// 缺少辅助功能权限的说明，接在不可用的菜单项后面，也用在热键问题提示里。
    var needsAccessibility: String { get }
    /// 菜单项不可用时在后面附上原因，如「最小化（需要辅助功能权限）」。括号写法随语言：中日文用全角括号，其他语言用半角括号加空格。
    func unavailable(_ item: String, reason: String) -> String
    /// 打开设置窗口。
    var settings: String { get }

    // 占位文字：显示在缩略图中间，缩略图默认只有 384×216 点，宜短。

    /// 已建捕获会话，还没收到第一帧。
    var waiting: String { get }
    /// 没有屏幕录制权限，拿不到画面。
    var needsScreenRecording: String { get }
    /// 捕获出错停止，提示用户用右键菜单恢复。
    var captureStopped: String { get }
    /// 客户端窗口已最小化。
    var minimized: String { get }
}
