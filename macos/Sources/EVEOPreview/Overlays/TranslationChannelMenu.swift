// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗标题栏的频道切换菜单：
// - 第一组：4 个内置频道（本地、军团、联盟、舰队），按 ID 匹配；
// - 第二组：最近 24 小时从日志里发现的频道（活动角色排前面，按活跃时间倒序，至多 15 项）；
// - 如果当前已选里还有不在前两组里的自定义频道，单独补列在后面并打勾；
// - 末尾：「打开设置…」，方便用户在设置页配置多频道或模型参数。
// 点击任意频道项都会单选切换成只翻译该频道，避免为不看的频道多花模型调用费用。

import AppKit
import EVEOPreviewCore

/// 翻译浮窗频道切换菜单的构建。
@MainActor
enum TranslationChannelMenu {
    /// 菜单交给调用方的动作。
    enum Action {
        /// 单选切换到这个频道。
        case select(ChannelRef)
        /// 打开设置窗口的「翻译」页。
        case openSettings
    }

    /// 构建菜单所需的状态。
    struct Model {
        /// 当前已选的翻译频道。
        var selected: [ChannelRef]
        /// 最近 24 小时从日志里发现的频道。
        var discovered: [DiscoveredChannel]
        /// 活动角色名；非空时它的频道优先排在前面。
        var activeCharacter: String?
    }

    /// 构建频道切换菜单。关掉 autoenablesItems，让置灰提示项保持不可点。
    static func make(_ model: Model, perform: @escaping @MainActor (Action) -> Void) -> NSMenu {
        let strings = L10n.overlay
        let sections = TranslationChannelSwitcher.sections(
            selected: model.selected,
            discovered: model.discovered,
            activeCharacter: model.activeCharacter
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: strings.menuBuiltInChannelsHeader))
        for channel in sections.builtIns {
            let checked = TranslationChannelSwitcher.isSelected(channel, in: model.selected)
            menu.addItem(ClosureMenuItem(strings.displayName(for: channel), isChecked: checked) {
                perform(.select(channel))
            })
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: strings.menuRecentChannelsHeader))
        if sections.recent.isEmpty {
            menu.addItem(ClosureMenuItem(strings.noDiscoveredChannels, isEnabled: false) {})
        } else {
            for channel in sections.recent {
                let ref = channel.ref
                let checked = TranslationChannelSwitcher.isSelected(ref, in: model.selected)
                menu.addItem(ClosureMenuItem(channel.name, isChecked: checked) {
                    perform(.select(ref))
                })
            }
        }
        if !sections.customSelected.isEmpty {
            menu.addItem(.separator())
            for channel in sections.customSelected {
                menu.addItem(ClosureMenuItem(strings.displayName(for: channel), isChecked: true) {
                    perform(.select(channel))
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(strings.menuOpenSettings) { perform(.openSettings) })
        return menu
    }
}
