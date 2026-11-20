// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键按作用范围启用与停用的规则，以及鼠标热键的匹配与吞掉规则（反馈文档 6.5 节、6.6 节）。
// 规则是纯逻辑，放在 Core 里便于单元测试；平台层的 SystemHotkeyRegistrar 与 MouseEventTap 只负责
// 调系统接口，判断都交给这里。本文件只 import Foundation，不碰 CoreGraphics。

import Foundation

/// 热键是否应启用的规则。
public enum HotkeyActivation {
    /// 一条绑定此刻是否应启用：没有暂停，且作用范围是 `global`，或作用范围是 `game` 且前台是 EVE 客户端。
    public static func isActive(scope: HotkeyScope, isGameFrontmost: Bool, isSuspended: Bool) -> Bool {
        guard !isSuspended else { return false }
        switch scope {
        case .global: return true
        case .game: return isGameFrontmost
        }
    }
}

/// 鼠标事件的种类。只有中键与侧键（CGEvent 的 otherMouse*）会送到匹配器。
public enum MouseButtonEventKind: Sendable, Equatable {
    /// 按下（otherMouseDown）。
    case down
    /// 按住移动（otherMouseDragged）。
    case dragged
    /// 松开（otherMouseUp）。
    case up
}

/// 匹配器对一个鼠标事件的决定。
public enum MouseHotkeyDecision: Sendable, Equatable {
    /// 放行，事件照常传给前台应用。
    case pass
    /// 吞掉，不触发热键（已吞掉的按下之后的拖动与松开）。
    case swallow
    /// 吞掉并触发关联值所指的绑定。
    case fire(UInt32)
}

/// 鼠标热键的匹配状态：绑定表、前台状态、暂停状态与「按下已被吞掉」的按钮号。
///
/// 规则（反馈文档 6.6 节的表）：
/// - 按下：先把按钮号移出 `swallowedButtons`。没有暂停，且有绑定的按钮号与修饰键完全相同、作用范围此刻生效时，
///   把按钮号放进 `swallowedButtons` 并触发；否则放行。
/// - 松开：按钮号在 `swallowedButtons` 里时移出并吞掉，否则放行。不看松开时的修饰键、前台与暂停状态。
/// - 拖动：按钮号在 `swallowedButtons` 里时吞掉，否则放行。
/// - 一次按下被吞掉，它的拖动与松开也要吞掉，否则前台应用会收到一个没有按下的松开。所以替换绑定表、
///   前台变化、暂停都不清空 `swallowedButtons`；只要还有按钮按着，监听就保持打开（见 `shouldListen`）。
/// - 只因还按着按钮而开着的监听，最多再开 `releaseTimeout` 秒（见 `refreshReleaseDeadline(now:)`），
///   到期清空，松开事件丢了也不会让监听一直开着。监听被系统关掉、被拆除时也整个清空：期间的松开收不到。
public struct MouseHotkeyMatcher: Sendable, Equatable {
    /// 一条鼠标绑定。
    public struct Binding: Sendable, Hashable {
        /// 绑定编号，触发时回传。
        public var id: UInt32
        /// CGEvent 的按钮号，2～31。
        public var button: Int
        /// 修饰键，要与事件的修饰键完全相同。
        public var modifiers: HotkeyModifiers
        /// 已解析的作用范围。
        public var scope: HotkeyScope

        /// 用编号、按钮号、修饰键与作用范围建一条绑定。
        public init(id: UInt32, button: Int, modifiers: HotkeyModifiers, scope: HotkeyScope) {
            self.id = id
            self.button = button
            self.modifiers = modifiers
            self.scope = scope
        }
    }

    /// 只因还按着按钮而开着的监听，最多再开多少秒。到期后放弃等松开，
    /// 避免松开事件丢失时监听一直开着。
    public static let releaseTimeout: Double = 10

    /// 当前的鼠标绑定，按规划的顺序；同一按钮号与修饰键有多条时第一条生效。
    public private(set) var bindings: [Binding] = []
    /// 前台是不是 EVE 客户端。
    public private(set) var isGameFrontmost = false
    /// 是否暂停（录制热键期间、应用退出期间）。
    public private(set) var isSuspended = false
    /// 按下已被吞掉、还没收到松开的按钮号。
    public private(set) var swallowedButtons: Set<Int> = []
    /// 监听只因还按着按钮而开着时的截止时刻（单调时钟的秒）；不在这种状态时为 nil。
    public private(set) var releaseDeadline: Double?

    /// 建一个空的匹配器：没有绑定，前台不是游戏，没有暂停。
    public init() {}

    /// 是否存在此刻生效的绑定：没有暂停，且作用范围此刻生效。
    public var hasActiveBinding: Bool {
        bindings.contains {
            HotkeyActivation.isActive(scope: $0.scope, isGameFrontmost: isGameFrontmost, isSuspended: isSuspended)
        }
    }

    /// 事件监听此刻应否打开：存在此刻生效的绑定，或者还有已吞掉按下、没等到松开的按钮。
    ///
    /// 只有 `game` 范围的绑定时，离开游戏且没有按钮按着，监听是关的，其他应用里的鼠标事件不经过本应用。
    public var shouldListen: Bool {
        hasActiveBinding || !swallowedButtons.isEmpty
    }

    /// 替换绑定表。`swallowedButtons` 保留：已吞掉的按下，它的松开照样吞掉。
    public mutating func replaceBindings(_ bindings: [Binding]) {
        self.bindings = bindings
    }

    /// 更新前台状态。`swallowedButtons` 保留。
    public mutating func setGameFrontmost(_ isFrontmost: Bool) {
        isGameFrontmost = isFrontmost
    }

    /// 更新暂停状态。暂停期间新的按下一律放行；暂停前已吞掉的按下，它的松开照样吞掉。
    public mutating func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }

    /// 监听被系统关掉（超时或用户输入）或被拆除时调用：期间的松开事件可能丢了，清空 `swallowedButtons`。
    public mutating func tapWasDisabled() {
        swallowedButtons.removeAll()
        releaseDeadline = nil
    }

    /// 整理「只因按着按钮而开着」的截止时刻，返回调用方下一次应检查的时刻；nil 表示不用再检查。
    ///
    /// - 有生效的绑定，或者没有按钮按着：不在这种状态，清掉截止时刻。
    /// - 刚进入这种状态：截止时刻记为 now 加 `releaseTimeout`。计时从这一刻开始，不从按下开始，
    ///   所以绑定一直生效时，按住多久都不会被提前放弃。
    /// - 已到截止时刻：清空 `swallowedButtons`，之后监听可以关闭。
    public mutating func refreshReleaseDeadline(now: Double) -> Double? {
        guard !hasActiveBinding, !swallowedButtons.isEmpty else {
            releaseDeadline = nil
            return nil
        }
        guard let deadline = releaseDeadline else {
            releaseDeadline = now + Self.releaseTimeout
            return releaseDeadline
        }
        guard now < deadline else {
            tapWasDisabled()
            return nil
        }
        return deadline
    }

    /// 判断一个事件。modifiers 只应含 Command、Option、Control、Shift 四种，其余位由调用方去掉。
    public mutating func handle(_ kind: MouseButtonEventKind, button: Int, modifiers: HotkeyModifiers)
        -> MouseHotkeyDecision {
        switch kind {
        case .down:
            // 先移出：上一次点击的松开可能没收到，不能让它影响这一次。
            swallowedButtons.remove(button)
            guard !isSuspended, let match = bindings.first(where: { binding in
                binding.button == button && binding.modifiers == modifiers
                    && HotkeyActivation.isActive(scope: binding.scope, isGameFrontmost: isGameFrontmost,
                                                 isSuspended: isSuspended)
            }) else { return .pass }
            swallowedButtons.insert(button)
            return .fire(match.id)
        case .up:
            return swallowedButtons.remove(button) != nil ? .swallow : .pass
        case .dragged:
            return swallowedButtons.contains(button) ? .swallow : .pass
        }
    }
}
