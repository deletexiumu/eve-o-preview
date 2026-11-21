// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗面板（docs/design-intel-translate.md 8.3 节）：设置与 ThumbnailPanel 相同，只有背景不同。
// - 无边框、不抢焦点（nonactivatingPanel，永不成为 key 与 main 窗口），出现在所有空间与全屏客户端之上的辅助层。
// - 背景透明，由内容视图的图层画（只有背景随不透明度变，文字始终不透明）。
// - 重写 sendEvent：鼠标按键事件先交给 OverlayInteraction（移动、缩放、菜单、新消息条），它不处理的再走 super。
//   滚轮事件不拦截，由列表照常滚动（V28 的实测留给手工验证）。
// - 显示用 orderFrontRegardless，不激活本应用。

import AppKit

/// 浮窗面板。
final class InfoOverlayPanel: NSPanel {
    /// 鼠标手势的处理者；nil 时事件全部照常分发。
    var interaction: OverlayInteraction?

    /// 用 AppKit 坐标的 frame 建面板。
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        // 显示 Dock 图标时，应用可被「隐藏」；浮窗与缩略图一样不跟着隐藏。
        canHide = false
        hasShadow = false
        isMovable = false
        // 面板由 InfoOverlayController 持有；不设为 false 时 close() 会额外释放一次。
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        level = .floating
    }

    /// 面板永远不成为 key 窗口，键盘焦点留在游戏里。
    override var canBecomeKey: Bool { false }

    /// 面板永远不成为 main 窗口。
    override var canBecomeMain: Bool { false }

    /// 鼠标按键事件先交给手势处理者；滚轮与其他事件照常分发。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            if let interaction, interaction.handle(event) { return }
        default:
            break
        }
        super.sendEvent(event)
    }
}
