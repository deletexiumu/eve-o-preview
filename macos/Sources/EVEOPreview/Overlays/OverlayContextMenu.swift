// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的右键菜单（docs/macos/design-intel-translate.md 8.7 节的表）：
// 滚动到最新、复制这一条、在浏览器中打开（子菜单，6.9 节增补）、清空列表、锁定布局、恢复默认位置与尺寸、
// 隐藏此浮窗、打开设置…。
// - 「复制这一条」与「在浏览器中打开」由菜单自己处理：前者把 copyText 放进剪贴板，后者只打开能解析且协议是 https 的地址，
//   用 NSWorkspace.shared.open（浏览器会到前台，这是用户点菜单的结果）。不经过 InfoOverlayDelegate，
//   OverlayMenuAction 不加新值。面板不知道链接指向哪个网站。
// - 光标下没有行时「复制这一条」置灰；那一行没有 links 时不显示「在浏览器中打开」。
// - 「滚动到最新」交给面板，其余各项交给委托（协调器）改配置。

import AppKit
import EVEOPreviewCore

/// 浮窗右键菜单的构建。
@MainActor
enum OverlayContextMenu {
    /// 菜单交给调用方的动作。
    enum Action {
        /// 滚到底部，由面板处理。
        case scrollToLatest
        /// 交给委托的动作。
        case delegate(OverlayMenuAction)
    }

    /// 构建菜单所需的状态。
    struct Model {
        /// 布局是否已锁定（「锁定布局」打勾）。
        var isLocked: Bool
        /// 光标下的那一行；不在某一行上时为 nil。
        var line: OverlayLine?
    }

    /// 构建菜单。NSMenu 的自动启用要关掉，否则 isEnabled 会被 AppKit 覆盖。
    static func make(_ model: Model, perform: @escaping @MainActor (Action) -> Void) -> NSMenu {
        let strings = L10n.overlay
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(strings.menuScrollToLatest) { perform(.scrollToLatest) })
        let copyText = model.line?.copyText
        menu.addItem(ClosureMenuItem(strings.menuCopyLine, isEnabled: copyText != nil) {
            if let copyText { copy(copyText) }
        })
        if let links = model.line?.links, !links.isEmpty {
            menu.addItem(browserItem(title: strings.menuOpenInBrowser, links: links))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(strings.menuClear) { perform(.delegate(.clear)) })
        menu.addItem(ClosureMenuItem(strings.menuLockLayout, isChecked: model.isLocked) {
            perform(.delegate(.toggleLock))
        })
        menu.addItem(ClosureMenuItem(strings.menuResetFrame) { perform(.delegate(.resetFrame)) })
        menu.addItem(ClosureMenuItem(strings.menuHide) { perform(.delegate(.hide)) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(strings.menuOpenSettings) { perform(.delegate(.openSettings)) })
        return menu
    }

    /// 「在浏览器中打开」与它的子菜单：每个链接一项，文字是 title。地址不是 https 的项置灰。
    private static func browserItem(title: String, links: [OverlayLink]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for link in links {
            let url = browserURL(link)
            submenu.addItem(ClosureMenuItem(link.title, isEnabled: url != nil) {
                if let url { NSWorkspace.shared.open(url) }
            })
        }
        item.submenu = submenu
        return item
    }

    /// 链接的地址：能解析、协议是 https、有主机名时返回 URL，否则返回 nil（不打开）。
    static func browserURL(_ link: OverlayLink) -> URL? {
        guard let url = URL(string: link.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 把文字放进剪贴板。
    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
