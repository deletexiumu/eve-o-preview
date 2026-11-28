// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的聊天日志服务（docs/macos/design-intel-translate.md 9.5 节）：EVEO_FAKE=1 时使用，不读任何文件。
// - 开始跟踪后，请求要读位置线索时给每个假角色发一条 Local 的切换消息（LocationLineParser 认得的形式），
//   之后每 4 秒给一个假角色发一条消息，按角色轮流，消息按表轮流。
// - 消息表 12 条：中英文的情报，英、俄、日文的闲聊。说话人与频道名都是虚构的；星系与舰船名是游戏的公开数据。
// - 频道是 intel.Demo 与 chat.Demo，discoverChannels 返回这两个频道，Channel ID 与消息里的一致。
//   假服务不按请求的频道过滤，由 ChatFeatureController 按频道分发。
// - 状态是 watching(directory: "fake", followedFiles: 假角色数)。请求变了时重新开始。
// - 覆盖情况：每个假角色都有两个演示频道的「文件」，所以浮窗不会出现「没有日志文件」的提示。

import Foundation
import EVEOPreviewCore

/// 演示模式的聊天日志服务。全部方法在主线程调用。
@MainActor
final class FakeChatLogMonitor: ChatLogMonitor {
    /// 两条假消息之间的间隔。
    static let interval: Duration = .seconds(4)
    /// 演示用的预警频道。
    static let intelChannel = ChannelRef(name: "intel.Demo", id: "player_00000000000000000000000000de0001")
    /// 演示用的闲聊频道。
    static let chatChannel = ChannelRef(name: "chat.Demo", id: "player_00000000000000000000000000de0002")

    /// 一条假消息：是否在预警频道、说话人、正文。
    private struct Sample {
        var isIntel: Bool
        var speaker: String
        var text: String
    }

    /// 12 条固定的消息。连续两个空格是情报里条目之间的分隔（C14）。
    private static let samples: [Sample] = [
        Sample(isIntel: true, speaker: "Demo Scout Alpha", text: "1DQ1-A  Ardent Fakename  Sabre"),
        Sample(isIntel: false, speaker: "Demo Pilot Echo", text: "anyone up for a roam later?"),
        Sample(isIntel: true, speaker: "Demo Scout Bravo", text: "T5ZI-S  +3  Crow  Rapier"),
        Sample(isIntel: false, speaker: "Demo Pilot Ivanov", text: "кто-нибудь видел их флот?"),
        Sample(isIntel: true, speaker: "Demo Scout Alpha", text: "HED-GP clr"),
        Sample(isIntel: false, speaker: "Demo Pilot Sakura", text: "こんばんは、今日もよろしく"),
        Sample(isIntel: true, speaker: "Demo Scout Bravo", text: "1DQ1-A  Sabre  Stabber  Machariel  5"),
        Sample(isIntel: false, speaker: "Demo Pilot Echo", text: "o7 fleet forming in 10"),
        Sample(isIntel: true, speaker: "Demo Scout Charlie", text: "吉他  2个  剑齿虎级"),
        Sample(isIntel: false, speaker: "Demo Pilot Ivanov", text: "спасибо, я уже в доке"),
        Sample(isIntel: true, speaker: "Demo Scout Charlie", text: "T5ZI-S 红 3 黑鸦级 nv"),
        Sample(isIntel: false, speaker: "Demo Pilot Sakura", text: "ゲートでキャンプされています"),
    ]

    /// 给假角色轮流用的起始星系。
    private static let startSystems = ["Jita", "Perimeter", "New Caldari", "Amarr"]

    /// 一批事件。
    var onEvents: (@MainActor ([ChatLogEvent]) -> Void)?
    /// 状态变化的回调。
    var onStatusChange: (@MainActor (ChatLogStatus) -> Void)?
    /// 当前状态。
    private(set) var status: ChatLogStatus = .stopped
    /// 覆盖情况变化的回调。
    var onFollowedChannelsChange: (@MainActor ([FollowedChatChannel]?) -> Void)?
    /// 每个假角色都有两个演示频道；没有在运行时为 nil。
    private(set) var followedChannels: [FollowedChatChannel]?
    /// 假世界，从中取假角色名。
    private let world: FakeWorld
    /// 当前的请求；nil 表示没有在运行。
    private var request: ChatLogRequest?
    /// 发假事件的任务。
    private var task: Task<Void, Never>?
    /// 下一条消息在表里的序号。
    private var nextSample = 0
    /// 下一个收到消息的角色的序号。
    private var nextCharacter = 0

    /// 用假世界建服务，暂不发事件。
    init(world: FakeWorld) {
        self.world = world
    }

    /// 开始「跟踪」：请求与上次相同时不做任何事，不同时重新开始（先发位置线索，再每 4 秒一条消息）。
    func start(_ request: ChatLogRequest) {
        if task != nil, self.request == request { return }
        task?.cancel()
        self.request = request
        let names = characterNames()
        update(.watching(directory: "fake", followedFiles: names.count))
        updateFollowed(names)
        let followsLocation = request.followsLocation
        task = Task { [weak self] in
            // 推迟到下一轮主线程再发，调用方在 start 之后才处理事件。
            await Task.yield()
            if followsLocation { self?.emitLocations() }
            while !Task.isCancelled {
                try? await Task.sleep(for: FakeChatLogMonitor.interval)
                guard !Task.isCancelled else { return }
                self?.emitMessage()
            }
        }
    }

    /// 停止，状态变成 `stopped`。
    func stop() {
        task?.cancel()
        task = nil
        request = nil
        update(.stopped)
        followedChannels = nil
        onFollowedChannelsChange?(nil)
    }

    /// 返回两个演示频道。
    func discoverChannels(logDirectory: String?) async -> [DiscoveredChannel] {
        let now = Date().timeIntervalSince1970
        let names = Set(characterNames().map { $0.lowercased() }).sorted()
        return [FakeChatLogMonitor.intelChannel, FakeChatLogMonitor.chatChannel].map { ref in
            DiscoveredChannel(id: ref.id ?? ref.name, name: ref.name, kind: .player, listeners: names.count,
                              lastModified: now, listenerNames: names)
        }
    }

    // MARK: - 假事件

    /// 给每个假角色发一条 Local 的切换消息作位置线索。
    private func emitLocations() {
        let now = Date().timeIntervalSince1970
        let events = characterNames().enumerated().map { index, name in
            let system = FakeChatLogMonitor.startSystems[index % FakeChatLogMonitor.startSystems.count]
            return ChatLogEvent.locationHint(LocationHint(character: name, time: now, source: .localChannel,
                                                          text: "Channel changed to Local : \(system)",
                                                          isBackfill: false))
        }
        if !events.isEmpty { onEvents?(events) }
    }

    /// 给下一个假角色发表里的下一条消息。
    private func emitMessage() {
        let names = characterNames()
        update(.watching(directory: "fake", followedFiles: names.count))
        updateFollowed(names)
        guard !names.isEmpty else { return }
        let name = names[nextCharacter % names.count]
        let sample = FakeChatLogMonitor.samples[nextSample % FakeChatLogMonitor.samples.count]
        nextCharacter += 1
        nextSample += 1
        let channel = sample.isIntel ? FakeChatLogMonitor.intelChannel : FakeChatLogMonitor.chatChannel
        let message = ChatMessage(listener: name, channelID: channel.id ?? channel.name, channelName: channel.name,
                                  time: Date().timeIntervalSince1970, speaker: sample.speaker, text: sample.text,
                                  isBackfill: false)
        onEvents?([.message(message)])
    }

    /// 已登录的假角色名，按名称排序。登录界面的假客户端没有角色名，不参与。
    private func characterNames() -> [String] {
        world.snapshot().compactMap { TitleParser.identity(fromTitle: $0.title).characterName }.sorted()
    }

    /// 按假角色算出覆盖情况（每人两个演示频道），变了时通知。
    private func updateFollowed(_ names: [String]) {
        let followed = names.flatMap { name in
            [FakeChatLogMonitor.intelChannel, FakeChatLogMonitor.chatChannel].map { ref in
                FollowedChatChannel(listener: name, channelID: ref.id ?? ref.name, channelName: ref.name)
            }
        }
        guard followed != followedChannels else { return }
        followedChannels = followed
        onFollowedChannelsChange?(followed)
    }

    /// 记下新状态，变了时通知。
    private func update(_ newStatus: ChatLogStatus) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
