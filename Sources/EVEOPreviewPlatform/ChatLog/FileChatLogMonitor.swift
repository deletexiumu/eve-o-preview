// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志跟踪服务的主线程外壳（docs/design-intel-translate.md 5.4 节，做法同 FileCombatLogMonitor）。
// 把 ChatLogTailer 在自己的串行队列上读到的事件与状态切回主线程，交给 onEvents 与 onStatusChange。
// - start(_:)：请求与上次相同且正在跟踪时不做任何事；不同时停掉旧的跟踪服务，按新请求重建并重新补读。
// - stop()：停掉跟踪服务，状态变成 stopped。
// WP-0 的空实现：不读任何文件，状态保持 stopped，discoverChannels 返回空数组。读取部分归 WP-A。

import Foundation
import EVEOPreviewCore

/// 基于文件事件的聊天日志跟踪服务。全部方法在主线程调用。
@MainActor public final class FileChatLogMonitor: ChatLogMonitor {
    /// 一批事件，在主线程调用。
    public var onEvents: (@MainActor ([ChatLogEvent]) -> Void)?
    /// 状态变化时在主线程调用。
    public var onStatusChange: (@MainActor (ChatLogStatus) -> Void)?
    /// 当前状态。
    public private(set) var status: ChatLogStatus = .stopped
    /// 最近一次的请求；nil 表示没有在跟踪。
    private var request: ChatLogRequest?

    /// 建一个跟踪服务，暂不跟踪。
    public init() {}

    /// 开始跟踪。WP-0 的空实现只记下请求。
    public func start(_ request: ChatLogRequest) {
        self.request = request
    }

    /// 停止跟踪，状态变成 `stopped`。
    public func stop() {
        request = nil
        update(.stopped)
    }

    /// 列出最近 14 天出现过的频道。WP-0 的空实现返回空数组。
    public func discoverChannels(logDirectory: String?) async -> [DiscoveredChannel] {
        []
    }

    /// 记下新状态，变了时通知。
    private func update(_ newStatus: ChatLogStatus) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
