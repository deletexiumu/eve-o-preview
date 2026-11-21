// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的聊天日志服务（docs/design-intel-translate.md 9.5 节）：EVEO_FAKE=1 时使用，不读任何文件。
// 完整的版本（启动后给每个假角色发一条位置线索，之后每 4 秒发一条消息，频道是 intel.Demo 与 chat.Demo）归 WP-A。
// WP-0 的骨架：不发事件；开始跟踪后状态是 watching(directory: "fake", followedFiles: 0)，discoverChannels 返回空数组。

import EVEOPreviewCore

/// 演示模式的聊天日志服务。全部方法在主线程调用。
@MainActor
final class FakeChatLogMonitor: ChatLogMonitor {
    /// 一批事件。骨架不发事件。
    var onEvents: (@MainActor ([ChatLogEvent]) -> Void)?
    /// 状态变化的回调。
    var onStatusChange: (@MainActor (ChatLogStatus) -> Void)?
    /// 当前状态。
    private(set) var status: ChatLogStatus = .stopped
    /// 假世界，WP-A 从中取假角色名。
    private let world: FakeWorld

    /// 用假世界建服务，暂不发事件。
    init(world: FakeWorld) {
        self.world = world
    }

    /// 开始「跟踪」：骨架只改状态。
    func start(_ request: ChatLogRequest) {
        update(.watching(directory: "fake", followedFiles: 0))
    }

    /// 停止，状态变成 `stopped`。
    func stop() {
        update(.stopped)
    }

    /// 骨架返回空数组。
    func discoverChannels(logDirectory: String?) async -> [DiscoveredChannel] {
        []
    }

    /// 记下新状态，变了时通知。
    private func update(_ newStatus: ChatLogStatus) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
