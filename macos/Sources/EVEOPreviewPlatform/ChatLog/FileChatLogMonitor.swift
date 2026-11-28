// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志跟踪服务的主线程外壳（docs/macos/design-intel-translate.md 5.4 节，做法同 FileCombatLogMonitor）。
// 把 ChatLogTailer 在自己的串行队列上读到的事件与状态切回主线程，交给 onEvents 与 onStatusChange。
// - start(_:)：请求与上次相同且正在跟踪时不做任何事；不同时停掉旧的跟踪服务，按新请求重建并重新补读。
// - stop()：停掉跟踪服务，状态变成 stopped。
// - 每建一个跟踪服务，代号加 1。旧服务排在主线程队列里的回调带着旧代号，到达时直接丢弃，
//   所以请求变了之后，旧服务迟到的事件不会混进新的缓冲。
// - discoverChannels：列出聊天日志目录里最近 24 小时出现过的频道（5.3 节），在 ChatChannelDiscovery 自己的
//   串行队列上执行，未跟踪时也能调用。文件头按文件名缓存，私聊频道与文件头不完整的文件不列出。

import Dispatch
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
    /// followedChannels 变化时在主线程调用。
    public var onFollowedChannelsChange: (@MainActor ([FollowedChatChannel]?) -> Void)?
    /// 正在跟踪的聊天日志文件的收听者与频道；新的跟踪服务还没扫描完或没有在跟踪时为 nil。
    public private(set) var followedChannels: [FollowedChatChannel]?
    /// 最近一次的请求；nil 表示没有在跟踪。
    private var request: ChatLogRequest?
    /// 当前的跟踪服务；nil 表示没有在跟踪。
    private var tailer: ChatLogTailer?
    /// 跟踪服务的代号，每次启动、停止时加 1，用来丢弃旧服务的迟到回调。
    private var generation = 0
    /// 用户的主目录，用来展开 `~` 与拼默认路径。
    private let homeDirectory: String
    /// 频道发现，带文件头的缓存。
    private let discovery = ChatChannelDiscovery()

    /// 建一个跟踪服务，暂不跟踪。
    public init() {
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// 开始跟踪。请求与上次相同时不做任何事，不同时停掉旧的跟踪服务，按新请求重建并重新补读。
    public func start(_ request: ChatLogRequest) {
        if tailer != nil, self.request == request { return }
        tailer?.stop()
        generation += 1
        let current = generation
        self.request = request
        let tailer = ChatLogTailer(
            request: request, homeDirectory: homeDirectory,
            onEvents: { [weak self] events in
                guard let self, self.generation == current else { return }
                self.onEvents?(events)
            },
            onStatus: { [weak self] status in
                guard let self, self.generation == current else { return }
                self.update(status)
            },
            onFollowed: { [weak self] followed in
                guard let self, self.generation == current else { return }
                self.updateFollowed(followed)
            })
        self.tailer = tailer
        // 新的跟踪服务从头扫描，旧的覆盖情况作废。
        updateFollowed(nil)
        tailer.start()
    }

    /// 停止跟踪，关闭全部文件描述符，状态变成 `stopped`。
    public func stop() {
        request = nil
        if let tailer {
            tailer.stop()
            self.tailer = nil
            generation += 1
        }
        update(.stopped)
        updateFollowed(nil)
    }

    /// 列出最近 24 小时出现过的频道，按最后修改时间从新到旧排序。
    public func discoverChannels(logDirectory: String?) async -> [DiscoveredChannel] {
        let candidates = ChatLogDirectory.candidates(configured: logDirectory, homeDirectory: homeDirectory)
        return await discovery.discover(candidates: candidates)
    }

    /// 记下新的覆盖情况，变了时通知。
    private func updateFollowed(_ followed: [FollowedChatChannel]?) {
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

/// 设置界面「从日志添加」与翻译浮窗切换频道用的频道发现。状态只在自己的串行队列上访问，所以标为 `@unchecked Sendable`。
final class ChatChannelDiscovery: @unchecked Sendable {
    /// 只列这么多秒以内修改过的文件：24 小时，避免过早的旧频道干扰选择。
    static let windowSeconds = 86_400.0

    private let queue = DispatchQueue(label: "io.github.deletexiumu.eveopreview.chatlog.discovery", qos: .utility)
    /// 完整的文件头，按文件名缓存。只在 queue 上访问。
    private var headers: [String: ChatLogHeader] = [:]

    /// 在自己的队列上扫描，结果交回调用方。
    func discover(candidates: [String]) async -> [DiscoveredChannel] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.scan(candidates)) }
        }
    }

    /// 一个频道的累计结果。
    private struct Entry {
        var name: String
        var kind: ChatChannelKind
        var listeners: Set<String>
        var lastModified: Double
    }

    /// 取第一个能列出的候选目录，按 Channel ID 合并最近 24 小时的文件。名字取最近修改的那个文件的。
    private func scan(_ candidates: [String]) -> [DiscoveredChannel] {
        guard let (directory, names) = firstListing(candidates) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - ChatChannelDiscovery.windowSeconds
        var entries: [String: Entry] = [:]
        var present: Set<String> = []
        for name in names {
            guard let fileName = ChatLogDirectory.parseFileName(name) else { continue }
            present.insert(name)
            let path = directory + "/" + name
            guard let info = GameLogFileSystem.info(path), info.modifiedAt >= cutoff,
                  let header = header(for: name, path: path), let id = header.channelID,
                  header.kind != .privateChat else { continue }
            var entry = entries[id] ?? Entry(name: header.channelName ?? fileName.channel, kind: header.kind,
                                             listeners: [], lastModified: info.modifiedAt)
            if let listener = header.listener { entry.listeners.insert(listener.lowercased()) }
            if info.modifiedAt >= entry.lastModified {
                entry.lastModified = info.modifiedAt
                entry.name = header.channelName ?? fileName.channel
            }
            entries[id] = entry
        }
        headers = headers.filter { present.contains($0.key) }
        return entries.map { id, entry in
            DiscoveredChannel(id: id, name: entry.name, kind: entry.kind, listeners: entry.listeners.count,
                              lastModified: entry.lastModified, listenerNames: entry.listeners.sorted())
        }.sorted { $0.lastModified != $1.lastModified ? $0.lastModified > $1.lastModified : $0.id < $1.id }
    }

    /// 第一个能列出的候选目录与它的条目；都不行时为 nil。
    private func firstListing(_ candidates: [String]) -> (String, [String])? {
        for path in candidates {
            switch GameLogFileSystem.list(path) {
            case .entries(let names): return (path, names)
            case .denied: return nil
            case .missing: continue
            }
        }
        return nil
    }

    /// 文件头：有缓存时用缓存，否则读一次；不完整的不缓存，也不列出。
    private func header(for name: String, path: String) -> ChatLogHeader? {
        if let cached = headers[name] { return cached }
        guard case .complete(let header) = LogTailReader.probeChatHeader(path) else { return nil }
        headers[name] = header
        return header
    }
}
