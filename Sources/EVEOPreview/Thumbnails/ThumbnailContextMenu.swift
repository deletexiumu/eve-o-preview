// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图的右键菜单（架构文档 2.1 节第 4 项）：最小化、全部最小化、跳过循环、隐藏、恢复默认尺寸，
// 捕获被用户停止时多一项「恢复捕获」。菜单只描述动作，执行交给协调器。
// 文件里另有 ClosureMenuItem：用闭包代替 target/action 的菜单项，菜单栏菜单也用它。

import AppKit

/// 用闭包响应点击的菜单项。
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    /// 建一个菜单项。
    ///
    /// - Parameters:
    ///   - title: 显示的文字。
    ///   - isEnabled: 是否可点；为 false 时置灰。
    ///   - isChecked: 是否在左侧打勾。
    ///   - handler: 点击时在主线程调用。
    init(_ title: String, isEnabled: Bool = true, isChecked: Bool = false,
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
        state = isChecked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("不支持从 nib 创建")
    }

    @MainActor @objc private func fire() {
        handler()
    }
}

/// 缩略图右键菜单的构建。
@MainActor
enum ThumbnailContextMenu {
    /// 菜单可以触发的动作。
    enum Action {
        case minimize, minimizeAll, toggleSkip, hide, resetSize, resumeCapture, openSettings
    }

    /// 构建菜单所需的状态。
    struct Model {
        /// 是否有辅助功能权限；没有时最小化项置灰。
        var canMinimize: Bool
        /// 角色名；登录与未知客户端为 nil，按角色的项置灰。
        var characterName: String?
        /// 是否已被跳过（打勾）。
        var isSkipped: Bool
        /// 是否有自定义尺寸；没有时「恢复默认尺寸」置灰。
        var hasCustomSize: Bool
        /// 捕获是否被用户停止；是时多一项「恢复捕获」。
        var isCaptureStopped: Bool
    }

    /// 构建菜单。NSMenu 的自动启用要关掉，否则 isEnabled 会被 AppKit 覆盖。
    static func make(_ model: Model, perform: @escaping @MainActor (Action) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isCharacter = model.characterName != nil
        let minimizeTitle = model.canMinimize
            ? L10n.thumbnail.minimize
            : L10n.thumbnail.unavailable(L10n.thumbnail.minimize, reason: L10n.thumbnail.needsAccessibility)
        menu.addItem(ClosureMenuItem(minimizeTitle, isEnabled: model.canMinimize) { perform(.minimize) })
        menu.addItem(ClosureMenuItem(L10n.thumbnail.minimizeAll, isEnabled: model.canMinimize) { perform(.minimizeAll) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L10n.thumbnail.skipCycle, isEnabled: isCharacter,
                                     isChecked: model.isSkipped) { perform(.toggleSkip) })
        menu.addItem(ClosureMenuItem(L10n.thumbnail.hide, isEnabled: isCharacter) { perform(.hide) })
        menu.addItem(ClosureMenuItem(L10n.thumbnail.resetSize, isEnabled: model.hasCustomSize) { perform(.resetSize) })
        if model.isCaptureStopped {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L10n.thumbnail.resumeCapture) { perform(.resumeCapture) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L10n.thumbnail.settings) { perform(.openSettings) })
        return menu
    }
}
