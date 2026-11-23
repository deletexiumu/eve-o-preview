// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志跟踪服务的主线程外壳（反馈文档 7.1 节、7.4 节）。把 CombatLogTailer 在自己的串行队列上
// 读到的受击事件与状态切回主线程，交给 onEvents 与 onStatusChange。
// - start(directory:)：目录与上次相同且正在跟踪时不做任何事；不同时停掉旧的跟踪服务，用新目录重建。
// - stop()：停掉跟踪服务，状态变成 stopped。
// 每建一个跟踪服务，代号加 1。旧服务排在主线程队列里、还没执行的回调带着旧代号，到达时直接丢弃，
// 所以停止或切换目录之后，迟到的状态不会盖掉新的状态。

import Foundation
import EVEOPreviewCore

/// 基于文件事件的游戏日志跟踪服务。全部方法在主线程调用。
@MainActor public final class FileCombatLogMonitor: CombatLogMonitor {
    /// 一批受击事件，在主线程调用。
    public var onEvents: (@MainActor ([CombatLogEvent]) -> Void)?
    /// 状态变化时在主线程调用。
    public var onStatusChange: (@MainActor (CombatLogStatus) -> Void)?
    /// 当前状态。
    public private(set) var status: CombatLogStatus = .stopped

    /// 当前的跟踪服务；nil 表示没有在跟踪。
    private var tailer: CombatLogTailer?
    /// 当前跟踪服务对应的配置目录（nil 表示自动查找）。
    private var directory: String?
    /// 跟踪服务的代号，每次启动、停止时加 1，用来丢弃旧服务的迟到回调。
    private var generation = 0
    /// 用户的主目录，用来展开 `~` 与拼默认路径。
    private let homeDirectory: String

    /// 建一个跟踪服务，暂不跟踪。
    public init() {
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// 开始跟踪。directory 为 nil 时自动查找。目录与上次相同时不做任何事，不同时切换目录。
    public func start(directory: String?) {
        if tailer != nil, self.directory == directory { return }
        tailer?.stop()
        generation += 1
        let current = generation
        self.directory = directory
        let candidates = CombatLogDirectory.candidates(configured: directory, homeDirectory: homeDirectory)
        let tailer = CombatLogTailer(
            candidates: candidates,
            onEvents: { [weak self] events in
                guard let self, self.generation == current else { return }
                self.onEvents?(events)
            },
            onStatus: { [weak self] status in
                guard let self, self.generation == current else { return }
                self.update(status)
            })
        self.tailer = tailer
        tailer.start()
    }

    /// 停止跟踪，关闭全部文件描述符，状态变成 `stopped`。
    public func stop() {
        guard let tailer else { return }
        tailer.stop()
        self.tailer = nil
        generation += 1
        update(.stopped)
    }

    /// 记下新状态，变了时通知。
    private func update(_ newStatus: CombatLogStatus) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
