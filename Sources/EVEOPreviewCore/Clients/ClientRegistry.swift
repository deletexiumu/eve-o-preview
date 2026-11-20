// SPDX-License-Identifier: GPL-3.0-or-later
//
// 客户端登记（架构文档 5.3 节）。保存上一轮的客户端列表，按窗口 ID 与新一轮的主窗口比较，
// 得出新增、移除、改名、更新 4 类差异。

import Foundation

/// 已发现客户端的登记表。
public struct ClientRegistry: Sendable {
    /// 当前的客户端，按首次发现的顺序；改名与更新不改变位置。
    public private(set) var clients: [EVEClient]

    /// 建一个空的登记表。
    public init() {
        clients = []
    }

    /// 用新一轮的主窗口更新登记表，返回差异。
    ///
    /// - 新 ID 进 `added`，追加到 `clients` 末尾，按输入顺序。
    /// - 消失的 ID 进 `removed`，按原登记顺序。
    /// - 同一 ID 的身份变了进 `renamed`；身份没变、其他字段变了进 `updated`；都没变的不记。
    /// - 窗口 ID 被另一个 PID 复用时，视为旧客户端移除、新客户端新增，新客户端排到末尾。
    ///
    /// - Parameter mainWindows: `ClientWindowSelector.mainWindows` 的结果；同一 ID 出现多次时只取第一个。
    @discardableResult
    public mutating func update(with mainWindows: [WindowInfo]) -> RegistryDiff {
        var incoming: [WindowID: EVEClient] = [:]
        var incomingOrder: [WindowID] = []
        for window in mainWindows where incoming[window.windowID] == nil {
            incoming[window.windowID] = EVEClient(window: window)
            incomingOrder.append(window.windowID)
        }

        var diff = RegistryDiff()
        var kept: [EVEClient] = []
        var keptIDs = Set<WindowID>()
        for old in clients {
            // 窗口不在了，或 ID 被别的进程复用：都按移除处理。
            guard let new = incoming[old.id], new.pid == old.pid else {
                diff.removed.append(old)
                continue
            }
            if new.identity != old.identity {
                diff.renamed.append(ClientChange(before: old, after: new))
            } else if new != old {
                diff.updated.append(ClientChange(before: old, after: new))
            }
            kept.append(new)
            keptIDs.insert(new.id)
        }
        for id in incomingOrder where !keptIDs.contains(id) {
            if let client = incoming[id] {
                diff.added.append(client)
                kept.append(client)
            }
        }
        clients = kept
        return diff
    }

    /// 按窗口 ID 查找客户端。
    public func client(withID id: WindowID) -> EVEClient? {
        clients.first { $0.id == id }
    }

    /// 按 PID 查找客户端。每个进程只有一个主窗口，所以至多一个。
    public func client(withPID pid: Int32) -> EVEClient? {
        clients.first { $0.pid == pid }
    }

    /// 按角色名查找客户端（区分大小写）。同名的多个客户端取首次发现的那个。
    public func client(named name: String) -> EVEClient? {
        clients.first { $0.characterName == name }
    }
}
