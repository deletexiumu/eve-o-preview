// SPDX-License-Identifier: GPL-3.0-or-later
//
// 循环组与全局热键的配置模型（架构文档 5.2 节）。
// 热键以字符串保存（语法见 5.5 节），解析失败的字符串原样保留，由设置窗口报告。

import Foundation

/// 一个循环组：一组有顺序的角色，配前进与后退热键。
public struct CycleGroup: Sendable, Equatable, Codable, Identifiable {
    /// 循环组的 id（UUID 字符串），在一个配置方案内唯一。
    public var id: String
    /// 显示名称。
    public var name: String
    /// 前进热键，每项是一条热键字符串，如 `ctrl+F13`。
    public var forwardHotkeys: [String]
    /// 后退热键，每项是一条热键字符串。
    public var backwardHotkeys: [String]
    /// 成员角色名，按循环顺序。重复项由 `ConfigValidator` 去掉，只保留第一次出现的位置（5.4 节）。
    public var members: [String]

    /// 用各字段建一个循环组；id 默认生成新的 UUID。
    public init(id: String = UUID().uuidString, name: String, forwardHotkeys: [String] = [],
                backwardHotkeys: [String] = [], members: [String] = []) {
        self.id = id
        self.name = name
        self.forwardHotkeys = forwardHotkeys
        self.backwardHotkeys = backwardHotkeys
        self.members = members
    }

    /// 解码时缺失的键取默认值：id 为空串（由 `ConfigValidator` 补上 UUID），其余为空。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        forwardHotkeys = try c.decodeIfPresent([String].self, forKey: .forwardHotkeys) ?? []
        backwardHotkeys = try c.decodeIfPresent([String].self, forKey: .backwardHotkeys) ?? []
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
    }
}

/// 与循环组无关的全局热键，每项都是热键字符串数组，可以绑定多个组合。
public struct GeneralHotkeys: Sendable, Equatable, Codable {
    /// 切换「全部隐藏」。
    public var toggleHideAll: [String]
    /// 最小化全部客户端。
    public var minimizeAll: [String]
    /// 在登录客户端之间循环（按 PID 升序）。
    public var cycleLoginClients: [String]

    /// 「全部隐藏」的默认热键：⌃⌥⌘H，明确写成全局生效。
    /// 三个修饰键一起按不容易误触，也很少与游戏或其他应用的快捷键冲突。
    public static let defaultToggleHideAll = "ctrl+opt+cmd+H@global"

    /// 新建配置方案时使用的全局热键：只给「全部隐藏」绑定默认热键，其余不绑定。
    /// 与 `init()` 的「都不绑定」分开：解码缺键、手工构造时仍是空列表，只有新建的方案带默认值。
    public static let newProfileDefaults = GeneralHotkeys(toggleHideAll: [defaultToggleHideAll])

    /// 用各字段建全局热键，默认都不绑定。
    public init(toggleHideAll: [String] = [], minimizeAll: [String] = [], cycleLoginClients: [String] = []) {
        self.toggleHideAll = toggleHideAll
        self.minimizeAll = minimizeAll
        self.cycleLoginClients = cycleLoginClients
    }

    /// 解码时缺失的键取空数组。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toggleHideAll = try c.decodeIfPresent([String].self, forKey: .toggleHideAll) ?? []
        minimizeAll = try c.decodeIfPresent([String].self, forKey: .minimizeAll) ?? []
        cycleLoginClients = try c.decodeIfPresent([String].self, forKey: .cycleLoginClients) ?? []
    }
}
