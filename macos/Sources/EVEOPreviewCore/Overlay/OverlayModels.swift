// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的内容模型（docs/macos/design-intel-translate.md 8.2 节）。预警与翻译各自把消息排成 OverlayContent，
// 浮窗面板只认这里的类型，不知道预警与翻译的区别。样式到颜色、字重的对应在 App 的 Overlays/OverlayStyle.swift。

import Foundation

/// 浮窗的种类：一种面板，两个实例。
public enum OverlayKind: String, Sendable, Equatable, Hashable, CaseIterable {
    /// 预警浮窗。
    case intel
    /// 翻译浮窗。
    case translation
}

/// 一段文字的样式（8.4 节的表）。
public enum OverlaySpanStyle: Sendable, Equatable {
    /// 普通文字、暗色文字、说话人、频道名。
    case plain, dim, speaker, channel
    /// 时间：不足 120 秒、不足 300 秒、更早。
    case ageFresh, ageRecent, ageOld
    /// 星系的安全等级：高安、低安、零安、未知或虫洞。
    case systemHigh, systemLow, systemNull, systemUnknown
    /// 跳数：高亮距离以内、两倍以内、更远、算不出。
    case jumpsNear, jumpsMid, jumpsFar, jumpsUnknown
    /// 舰船、人名、数量、安全、未见。
    case ship, pilot, count, clear, noVisual
    /// 译文、翻译中、未翻译。
    case translated, pending, failed
}

/// 一段带样式的文字。
public struct OverlaySpan: Sendable, Equatable {
    /// 文字。
    public var text: String
    /// 样式。
    public var style: OverlaySpanStyle

    /// 用文字与样式建一段。
    public init(_ text: String, _ style: OverlaySpanStyle) {
        self.text = text
        self.style = style
    }
}

/// 一行的强调背景。
public enum OverlayEmphasis: Sendable, Equatable {
    /// 没有背景。
    case none
    /// 敌对在高亮距离以内（红色背景）。
    case alert
    /// 报告安全（绿色背景）。
    case clear
}

/// 右键「在浏览器中打开」的一项（6.9 节、8.7 节）。浮窗只显示 title，点击时 url 是 https 才打开。
public struct OverlayLink: Sendable, Equatable {
    /// 菜单项的文字。
    public var title: String
    /// https 地址。
    public var url: String

    /// 用文字与地址建一项。
    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// 浮窗里的一行（一条消息），至多两行文字。
public struct OverlayLine: Sendable, Equatable, Identifiable {
    /// 消息的编号，在一个浮窗内唯一且递增；浮窗按它对齐新旧列表。
    public var id: UInt64
    /// 第一行。
    public var primary: [OverlaySpan]
    /// 第二行，字号小一级；空数组表示没有。
    public var secondary: [OverlaySpan]
    /// 强调背景。
    public var emphasis: OverlayEmphasis
    /// 右键「复制」时放进剪贴板的文字。
    public var copyText: String
    /// 右键「在浏览器中打开」的各项；空数组表示没有，菜单里不出现这一项（6.9 节）。
    public var links: [OverlayLink]

    /// 用各字段建一行。
    public init(id: UInt64, primary: [OverlaySpan], secondary: [OverlaySpan] = [],
                emphasis: OverlayEmphasis = .none, copyText: String, links: [OverlayLink] = []) {
        self.id = id
        self.primary = primary
        self.secondary = secondary
        self.emphasis = emphasis
        self.copyText = copyText
        self.links = links
    }
}

/// 状态行的级别。
public enum OverlayStatusLevel: Sendable, Equatable {
    /// 说明（白色，半透明）。
    case info
    /// 提醒（黄色）。
    case warning
    /// 错误（红色）。
    case error
}

/// 浮窗标题下的状态行。
public struct OverlayStatus: Sendable, Equatable {
    /// 文字，至多显示 2 行。
    public var text: String
    /// 级别。
    public var level: OverlayStatusLevel

    /// 用文字与级别建状态行。
    public init(_ text: String, _ level: OverlayStatusLevel) {
        self.text = text
        self.level = level
    }
}

/// 一个浮窗要显示的全部内容。
public struct OverlayContent: Sendable, Equatable {
    /// 换了角色就换一个值，浮窗据此整表重载并回到底部。
    public var contextKey: String
    /// 标题行。
    public var title: String
    /// 标题行右侧频道切换按钮的文字；nil 时不显示按钮（预警浮窗没有这一项）。
    public var channelLabel: String?
    /// 状态行；nil 时不显示。
    public var status: OverlayStatus?
    /// 各行，旧的在前，最新的在最后。
    public var lines: [OverlayLine]

    /// 用各字段建内容。channelLabel 不给时为 nil。
    public init(contextKey: String, title: String, channelLabel: String? = nil, status: OverlayStatus?,
                lines: [OverlayLine]) {
        self.contextKey = contextKey
        self.title = title
        self.channelLabel = channelLabel
        self.status = status
        self.lines = lines
    }
}
