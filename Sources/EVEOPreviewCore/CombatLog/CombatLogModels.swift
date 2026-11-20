// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志与战斗提醒的值类型（反馈文档 7.2 节）。解析器、跟踪服务与协调器共用。
// 只读日志文件，不写、不改、不删 EVE 目录下的任何内容。

import Foundation

/// 一行游戏日志的归类结果。
public enum CombatLineKind: Sendable, Equatable {
    /// 本角色受到伤害，关联值是伤害数字（可能为 0）。
    case incomingDamage(amount: Int)
    /// 本角色造成伤害，关联值是伤害数字。
    case outgoingDamage(amount: Int)
    /// 对方攻击本角色但没有命中。
    case incomingMiss
    /// 本角色的攻击没有命中。
    case outgoingMiss
    /// combat 类别的其他消息，或判断不了方向的伤害行。
    case otherCombat
    /// 其他类别（hint、notify 等）。
    case other
}

/// 解析后的一行游戏日志。
public struct CombatLogLine: Sendable, Equatable {
    /// 类别，小写，如 `combat`。
    public var category: String
    /// 归类结果。
    public var kind: CombatLineKind

    /// 用类别与归类结果建一行。
    public init(category: String, kind: CombatLineKind) {
        self.category = category
        self.kind = kind
    }
}

/// 交给协调器的一条受击事件。
public struct CombatLogEvent: Sendable, Equatable {
    /// 日志文件头里的收听者（角色名）。
    public var character: String
    /// 受击的种类，只会是 `incomingDamage` 或 `incomingMiss`。
    public var kind: CombatLineKind

    /// 用角色名与受击种类建一条事件。
    public init(character: String, kind: CombatLineKind) {
        self.character = character
        self.kind = kind
    }
}

/// 游戏日志跟踪服务的状态，显示在「提醒」页的状态行。
public enum CombatLogStatus: Sendable, Equatable {
    /// 没有在跟踪（功能关闭或已停止）。
    case stopped
    /// 正在跟踪：所在目录与跟踪的文件数。
    case watching(directory: String, followedFiles: Int)
    /// 候选目录都不存在，关联值是第一个候选路径。
    case directoryNotFound(path: String)
    /// 列目录被系统拒绝（缺「文件与文件夹」权限）。
    case accessDenied(path: String)
}
