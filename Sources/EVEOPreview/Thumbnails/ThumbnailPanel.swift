// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图面板（架构文档 7.3 节）：无边框、不抢焦点、出现在所有空间的 NSPanel。
// 点击面板不会激活本应用，所以点缩略图切换客户端时，前台直接从一个客户端换到另一个。

import AppKit

/// 缩略图面板。
final class ThumbnailPanel: NSPanel {
    /// 用 AppKit 坐标的 frame 建面板。
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        // 显示 Dock 图标时，应用可被 Dock 菜单的「隐藏」或其他应用的「隐藏其他」（Option+Cmd+H）隐藏；缩略图不跟着隐藏。
        canHide = false
        hasShadow = false
        isMovable = false
        // 面板由 ThumbnailPanelController 持有；不设为 false 时 close() 会额外释放一次。
        isReleasedWhenClosed = false
        backgroundColor = .black
        animationBehavior = .none
        // 收鼠标移动事件：停在边缘带上时内容视图据此显示缩放光标（v1.2.1）。
        acceptsMouseMovedEvents = true
        level = .floating
    }

    /// 有客户端原生全屏时「缩略图置顶」用的层级：比状态栏层级（25）高一级。全屏客户端的窗口在 layer 25，
    /// `.floating`（3）会被它盖住（v1.1.1 实测）。只在全屏时用：它也盖过 Dock、菜单栏与系统对话框。
    static let fullScreenLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// 面板永远不成为 key 窗口，键盘焦点留在原来的应用。
    override var canBecomeKey: Bool { false }

    /// 面板永远不成为 main 窗口。
    override var canBecomeMain: Bool { false }
}
