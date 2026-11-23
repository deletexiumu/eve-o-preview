// SPDX-License-Identifier: GPL-3.0-or-later
//
// `state.json` 的持有者（v1.1 设计 3.3 节、4.4 节）。应用自己记下的状态（检查时刻、跳过的版本、待报告的崩溃等）
// 只经这里写入：每次修改后立即以原子方式写盘，写盘失败只记日志。
//
// 与 `ConfigController` 的区别：不延迟写盘（每天只改几次），不通知观察者（读的人在用到时读 `state`），
// 读失败时不停写（状态丢了只是多检查一次更新）。
//
// 文件位置：环境变量 `EVEO_STATE_DIR` 可以指定目录，供测试用；演示模式用 `state-fake.json` 与 `session-fake.json`。

import Foundation
import EVEOPreviewCore

/// 应用状态的持有者。全部方法在主线程调用。
@MainActor final class StateController {
    /// 当前状态。
    private(set) var state: AppState
    /// 状态的存储。
    private let store: any StateStore
    private let log = AppLog.logger("State")

    /// 从存储读入状态。文件不存在或读不懂时是默认状态（`StateStore.load()` 不抛错）。
    init(store: any StateStore) {
        self.store = store
        state = store.load()
    }

    /// 修改状态并立即以原子方式写盘；写盘失败只记日志。
    ///
    /// 内容没有变化时不写盘。
    func update(_ body: (inout AppState) -> Void) {
        var draft = state
        body(&draft)
        guard draft != state else { return }
        state = draft
        do {
            try store.save(draft)
        } catch {
            log.error("写状态文件失败：\(String(describing: error), privacy: .public)")
        }
    }
}

extension StateController {
    /// `Application Support` 下与状态有关的文件的位置，`state.json` 与 `session.json` 共用这条规则。
    ///
    /// - 环境变量 `EVEO_STATE_DIR` 不为空时，放在它指定的目录里（`~` 会展开）。
    /// - 否则放在 `~/Library/Application Support/EVE-O Preview/`（与 `JSONStateStore.defaultFileURL()` 同目录）。
    /// - 演示模式在基名后加 `-fake`，如 `state-fake.json`，不碰正式运行的记录。
    ///
    /// - Parameters:
    ///   - baseName: 不带扩展名的文件名，如 `state`、`session`。
    ///   - isFakeMode: 是否为演示模式（`EVEO_FAKE=1`）。
    static func fileURL(baseName: String, isFakeMode: Bool) -> URL {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["EVEO_STATE_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            directory = JSONStateStore.defaultFileURL().deletingLastPathComponent()
        }
        let name = isFakeMode ? "\(baseName)-fake.json" : "\(baseName).json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
