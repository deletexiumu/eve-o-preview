// SPDX-License-Identifier: GPL-3.0-or-later
//
// 由配置方案得出要注册的热键绑定（架构文档 5.5 节、6.5 节，反馈文档 6.3 节）。
// 配置内部的重复与系统保留组合在这里去掉，不会送到注册器。
// 每条字符串按 HotkeySpec 解析：作用范围后缀覆盖配置方案的 hotkeyDefaultScope。

import Foundation

/// 热键触发后要执行的动作。
public enum HotkeyAction: Sendable, Hashable {
    /// 在循环组里前进或后退。
    case cycle(groupID: String, direction: CycleDirection)
    /// 切到指定角色的客户端。
    case activateCharacter(String)
    /// 在登录客户端之间循环（前进方向）。
    case cycleLoginClients
    /// 切换「全部隐藏」。
    case toggleHideAll
    /// 最小化全部客户端。
    case minimizeAll
}

/// 一条要注册的热键绑定。
public struct HotkeyBinding: Sendable, Hashable, Identifiable {
    /// 绑定编号，从 1 起。键盘绑定作为 Carbon `EventHotKeyID.id` 使用，鼠标绑定由事件监听回传。
    public var id: UInt32
    /// 热键。
    public var hotkey: Hotkey
    /// 动作。
    public var action: HotkeyAction
    /// 已解析的作用范围（后缀或配置方案的默认值）。
    public var scope: HotkeyScope

    /// 用编号、热键、动作与作用范围建一条绑定。
    public init(id: UInt32, hotkey: Hotkey, action: HotkeyAction, scope: HotkeyScope = .global) {
        self.id = id
        self.hotkey = hotkey
        self.action = action
        self.scope = scope
    }
}

/// 热键被拒绝的原因。
public enum HotkeyRejection: Sendable, Equatable {
    /// 没有 ctrl、opt、cmd 之一，且键不是 F1～F20 或 Num0～Num9。
    case missingModifier
    /// 系统保留的组合，如 cmd+Tab。
    case systemReserved
}

/// 规划热键时发现的问题，由设置窗口显示在对应热键旁。
public enum HotkeyIssue: Sendable, Equatable {
    /// 字符串无法解析，原文保留在配置里。
    case unparsable(text: String, action: HotkeyAction)
    /// 同一个热键出现多次；先出现的生效，后出现的被丢弃。
    case duplicate(hotkey: Hotkey, kept: HotkeyAction, dropped: HotkeyAction)
    /// 热键被拒绝。
    case rejected(hotkey: Hotkey, action: HotkeyAction, reason: HotkeyRejection)
}

/// `HotkeyPlanner.plan` 的结果。
public struct HotkeyPlan: Sendable, Equatable {
    /// 要注册的绑定，按遍历顺序，id 从 1 起连续。
    public var bindings: [HotkeyBinding]
    /// 发现的问题，按遍历顺序。
    public var issues: [HotkeyIssue]

    /// 用绑定与问题建一个结果。
    public init(bindings: [HotkeyBinding], issues: [HotkeyIssue]) {
        self.bindings = bindings
        self.issues = issues
    }

    /// 按 id 查找绑定。
    public func binding(withID id: UInt32) -> HotkeyBinding? {
        bindings.first { $0.id == id }
    }
}

/// 热键规划。
public enum HotkeyPlanner {
    /// 由配置方案得出要注册的绑定与问题。
    ///
    /// - 遍历顺序：`hotkeys.toggleHideAll`、`minimizeAll`、`cycleLoginClients`，然后按 `cycleGroups`
    ///   的顺序（每组先前进后后退），最后是按角色名排序的 `characterHotkeys`
    ///   （Swift 字符串的默认顺序，即按 Unicode 码位，大写字母排在小写字母之前）。
    /// - 每条字符串依次检查：`HotkeySpec` 无法解析记 `unparsable`；键盘触发键是系统保留记
    ///   `rejected(systemReserved)`、缺修饰键记 `rejected(missingModifier)`（鼠标触发键跳过这两项）；
    ///   与已接受的热键相同记 `duplicate`，只比较触发键与修饰键，不比较作用范围。
    /// - 通过检查的绑定按遍历顺序从 1 起连续编号；被拒绝或重复的不占编号。
    /// - 绑定的作用范围取后缀，没有后缀时取 `profile.hotkeyDefaultScope`。
    public static func plan(for profile: Profile) -> HotkeyPlan {
        var builder = PlanBuilder(defaultScope: profile.hotkeyDefaultScope)
        builder.add(profile.hotkeys.toggleHideAll, action: .toggleHideAll)
        builder.add(profile.hotkeys.minimizeAll, action: .minimizeAll)
        builder.add(profile.hotkeys.cycleLoginClients, action: .cycleLoginClients)
        for group in profile.cycleGroups {
            builder.add(group.forwardHotkeys, action: .cycle(groupID: group.id, direction: .forward))
            builder.add(group.backwardHotkeys, action: .cycle(groupID: group.id, direction: .backward))
        }
        for name in profile.characterHotkeys.keys.sorted() {
            builder.add(profile.characterHotkeys[name] ?? [], action: .activateCharacter(name))
        }
        return HotkeyPlan(bindings: builder.bindings, issues: builder.issues)
    }

    /// 检查热键是否被拒绝；可以注册时返回 nil。鼠标触发键不检查，没有修饰键也接受。
    public static func rejection(for hotkey: Hotkey) -> HotkeyRejection? {
        guard let keyCode = hotkey.keyCode else { return nil }
        if isSystemReserved(hotkey) { return .systemReserved }
        let required: HotkeyModifiers = [.control, .option, .command]
        if hotkey.modifiers.isDisjoint(with: required)
            && !KeyCodeTable.isFunctionKey(keyCode) && !KeyCodeTable.isKeypadDigit(keyCode) {
            return .missingModifier
        }
        return nil
    }

    /// 系统保留的键：与 cmd 或 cmd+shift 组合时由系统处理（事实 E10：注册不会失败，只能靠名单拦截）。
    private static let reservedKeyNames = ["Tab", "Space", "Q", "W", "H", "M", "Grave"]

    /// 是否为 cmd+键 或 cmd+shift+键，且键在保留名单里。
    private static func isSystemReserved(_ hotkey: Hotkey) -> Bool {
        guard hotkey.modifiers == [.command] || hotkey.modifiers == [.command, .shift] else { return false }
        return reservedKeyNames.contains { KeyCodeTable.keyCode(for: $0) == hotkey.keyCode }
    }
}

/// 逐条累积绑定与问题的辅助类型。
private struct PlanBuilder {
    /// 配置方案的默认作用范围，没有后缀的热键取它。
    let defaultScope: HotkeyScope
    /// 已接受的绑定。
    var bindings: [HotkeyBinding] = []
    /// 发现的问题。
    var issues: [HotkeyIssue] = []
    /// 已接受的热键 → 它的动作，用于判断重复。键是 Hotkey，不含作用范围。
    private var owners: [Hotkey: HotkeyAction] = [:]

    /// 用配置方案的默认作用范围建一个累积器。
    init(defaultScope: HotkeyScope) {
        self.defaultScope = defaultScope
    }

    /// 处理一个动作的全部热键字符串。
    mutating func add(_ texts: [String], action: HotkeyAction) {
        for text in texts {
            guard let spec = HotkeySpec(string: text) else {
                issues.append(.unparsable(text: text, action: action))
                continue
            }
            let hotkey = spec.hotkey
            if let reason = HotkeyPlanner.rejection(for: hotkey) {
                issues.append(.rejected(hotkey: hotkey, action: action, reason: reason))
                continue
            }
            if let kept = owners[hotkey] {
                issues.append(.duplicate(hotkey: hotkey, kept: kept, dropped: action))
                continue
            }
            owners[hotkey] = action
            bindings.append(HotkeyBinding(id: UInt32(bindings.count + 1), hotkey: hotkey, action: action,
                                          scope: spec.resolvedScope(profileDefault: defaultScope)))
        }
    }
}
