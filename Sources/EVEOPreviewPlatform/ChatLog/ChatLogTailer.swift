// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的跟踪逻辑（docs/design-intel-translate.md 5.4～5.6 节）。与 CombatLogTailer 并列，不改后者。
// 全部状态只在自己的串行队列（utility）上访问，结果用 DispatchQueue.main.async 交回主线程。
// - 两个目录：Chatlogs（聊天日志）与 Gamelogs（游戏日志，只在 followsLocation 为真时读，取位置线索）。
//   各取候选里第一个能列出的目录，用 O_EVTONLY 挂目录事件源。状态只反映聊天日志目录：
//   不存在是 directoryNotFound，被系统拒绝是 accessDenied；任一目录不可用时每 10 秒重查。
// - 扫描：启动时一次；目录事件到达后 200 毫秒一次；每 30 秒一次作保险。
//   聊天日志按 5.4 节的 6 条规则取文件，至多 48 个；游戏日志每个收听者取文件名最大的一个，至多 16 个。
// - 起点：启动前已有的文件先补读再读新增；启动后才建的文件从 0 读起；同一个跟踪服务里再次跟踪的文件从末尾读起。
//   请求变了时由 FileChatLogMonitor 建一个新的跟踪服务，全部文件重新定起点。
// - 补读：聊天日志读末尾至多 512 KiB，丢掉早于 backfillSeconds 的行；Local 文件另回读最后一条系统消息；
//   游戏日志回读末尾 2 MiB 里最后 20 条 (None) 行。一次扫描里补读的事件按时间排好，合成一批上报，
//   浮窗的第一次内容更新就带着补读的内容（8.5 节）。
// - 读取：文件事件到达后 100 毫秒读一次；有被跟踪的文件时每 2 秒查一次长度作保险。一次读取的事件合成一批。
// - 上报（5.5 节）：非系统消息在频道匹配时上报 .message，正文为空的不报；Local 文件的系统消息在 followsLocation
//   为真时上报 .locationHint；游戏日志的 (None) 行上报 .locationHint。其他系统消息丢弃。只上报原文，不查星图数据。
// 只读日志文件，不写、不改、不删 EVE 目录下的任何内容。系统日志里的角色名、频道名、文件名与路径按 .private 记录，
// 说话人与正文不写进任何日志。

import Dispatch
import Foundation
import os
import EVEOPreviewCore

/// 聊天日志的跟踪服务。可在任意线程调用 `start()` 与 `stop()`；回调在主线程执行。
///
/// 可变状态只在 `queue` 上读写（串行队列保证互斥），所以标为 `@unchecked Sendable`。
public final class ChatLogTailer: @unchecked Sendable {
    /// 扫描与读取的时间参数（秒）。
    static let rescanDebounce = 0.2
    static let rescanInterval = 30.0
    static let readDebounce = 0.1
    static let safetyInterval = 2.0
    static let retryInterval = 10.0
    /// 聊天日志补读的字节数：512 KiB。
    static let backfillBytes: Int64 = 524_288

    /// 被监视的一个目录。
    private final class Watch {
        /// 聊天日志目录或游戏日志目录。
        let isChat: Bool
        /// 按优先顺序排列的候选目录。
        let candidates: [String]
        /// 正在监视的目录；nil 表示还没找到或已断开。
        var path: String?
        /// 目录事件源。
        var source: DispatchSourceFileSystemObject?
        /// 已排定一次延迟扫描（200 毫秒内的目录事件合并成一次）。
        var rescanScheduled = false
        /// 这一侧的文件键的前缀。
        var prefix: String { isChat ? "chat/" : "game/" }

        /// 用种类与候选目录建，暂不监视。
        init(isChat: Bool, candidates: [String]) {
            self.isChat = isChat
            self.candidates = candidates
        }
    }

    private let request: ChatLogRequest
    private let queue = DispatchQueue(label: "io.github.deletexiumu.eveopreview.chatlog", qos: .utility)
    private let onEvents: @MainActor @Sendable ([ChatLogEvent]) -> Void
    private let onStatus: @MainActor @Sendable (ChatLogStatus) -> Void
    /// 跟踪的聊天日志文件的收听者与频道变了时调用；nil 表示调用方不关心。
    private let onFollowed: (@MainActor @Sendable ([FollowedChatChannel]) -> Void)?
    private let log = PlatformLog.logger("ChatLog")

    // 以下状态只在 queue 上访问。
    /// `stop()` 之后为真，所有排队中的回调到这里直接返回。
    private var stopped = false
    /// `start()` 的时刻，用来判断文件是启动前已有的还是启动后新建的。
    private var startedAt: Double = 0
    /// 聊天日志目录。
    private let chat: Watch
    /// 游戏日志目录；followsLocation 为假时为 nil。
    private let game: Watch?
    /// 正在跟踪的文件，键是 `chat/` 或 `game/` 加文件名。
    private var files: [String: FollowedLogFile] = [:]
    /// 聊天日志的文件头，按文件名缓存；只缓存完整的文件头。
    private var chatHeaders: [String: ChatLogHeader] = [:]
    /// 游戏日志的收听者与编码，按文件名缓存；收听者为 nil 表示忽略（登录界面阶段的文件）。
    private var gameHeaders: [String: (listener: String?, encoding: LogTextEncoding?)] = [:]
    /// 文件头还没写完的文件的键，保险定时器到点时重新扫描。
    private var pendingHeaders: Set<String> = []
    /// 跟踪过的文件的键。再次跟踪时从末尾读起，不再补读，免得重复上报。只保留目录里还在的文件。
    private var everFollowed: Set<String> = []
    /// 这一轮操作里补读到的事件，操作结束时按时间排好合成一批上报。
    private var backfill: [ChatLogEvent] = []
    /// 30 秒的扫描定时器。
    private var rescanTimer: DispatchSourceTimer?
    /// 2 秒的长度检查定时器，只在有被跟踪的文件或等文件头的文件时运行。
    private var safetyTimer: DispatchSourceTimer?
    /// 10 秒的目录重查定时器，有目录不可用时运行。
    private var retryTimer: DispatchSourceTimer?
    /// 当前对外报告的状态；只在变化时才回调。
    private var status: ChatLogStatus = .stopped
    /// 最近一次上报的覆盖情况；nil 表示还没上报过。只在变化时才回调。
    private var reportedFollowed: [FollowedChatChannel]?

    /// 建跟踪服务，调用 `start()` 后才开始工作。
    ///
    /// - Parameters:
    ///   - request: 跟踪请求：日志目录、频道、是否读位置线索、补读的秒数。
    ///   - homeDirectory: 用户的主目录，用来展开 `~` 与拼默认路径。
    ///   - onEvents: 一批事件，按日志里的先后顺序，在主线程调用。
    ///   - onStatus: 状态变化，在主线程调用。
    ///   - onFollowed: 跟踪的聊天日志文件的收听者与频道变了，在主线程调用；可不给。
    public init(request: ChatLogRequest, homeDirectory: String,
                onEvents: @escaping @MainActor @Sendable ([ChatLogEvent]) -> Void,
                onStatus: @escaping @MainActor @Sendable (ChatLogStatus) -> Void,
                onFollowed: (@MainActor @Sendable ([FollowedChatChannel]) -> Void)? = nil) {
        self.request = request
        self.onEvents = onEvents
        self.onStatus = onStatus
        self.onFollowed = onFollowed
        chat = Watch(isChat: true, candidates: ChatLogDirectory.candidates(configured: request.logDirectory,
                                                                           homeDirectory: homeDirectory))
        game = request.followsLocation
            ? Watch(isChat: false, candidates: ChatLogDirectory.gameLogCandidates(configured: request.logDirectory,
                                                                                  homeDirectory: homeDirectory))
            : nil
    }

    /// 开始跟踪：记下启动时刻，查找两个目录，补读的事件合成一批上报。
    public func start() {
        queue.async {
            guard !self.stopped else { return }
            self.startedAt = Date().timeIntervalSince1970
            self.rescanTimer = self.makeTimer(interval: ChatLogTailer.rescanInterval) { $0.rescanAll() }
            self.resolve(self.chat)
            if let game = self.game { self.resolve(game) }
            self.flushBackfill()
        }
    }

    /// 停止跟踪：取消全部事件源与定时器，关闭全部描述符。之后不再回调。
    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.detach(self.chat)
            if let game = self.game { self.detach(game) }
            self.cancelTimer(&self.rescanTimer)
            self.cancelTimer(&self.retryTimer)
            self.backfill = []
            self.setStatus(.stopped)
        }
    }

    // MARK: - 目录

    /// 取候选里第一个能列出的目录并开始监视；不行时（聊天日志目录）设状态，并启动 10 秒的重查。
    private func resolve(_ watch: Watch) {
        guard !stopped else { return }
        defer { updateRetryTimer() }
        for path in watch.candidates {
            switch GameLogFileSystem.list(path) {
            case .entries(let names):
                attach(watch, path: path, names: names)
                return
            case .denied:
                log.notice("列日志目录被拒绝：\(path, privacy: .private)")
                if watch.isChat { setStatus(.accessDenied(path: path)) }
                return
            case .missing:
                continue
            }
        }
        if watch.isChat { setStatus(.directoryNotFound(path: watch.candidates.first ?? "")) }
    }

    /// 有目录不可用时运行 10 秒的重查定时器，否则停掉。
    private func updateRetryTimer() {
        // 游戏日志目录只在读位置线索时需要；它不可用时也重查，但不改对外的状态。
        let needed = !stopped && (chat.path == nil || (game != nil && game?.path == nil))
        if needed, retryTimer == nil {
            retryTimer = makeTimer(interval: ChatLogTailer.retryInterval) { tailer in
                if tailer.chat.path == nil { tailer.resolve(tailer.chat) }
                if let game = tailer.game, game.path == nil { tailer.resolve(game) }
                tailer.flushBackfill()
            }
        } else if !needed {
            cancelTimer(&retryTimer)
        }
    }

    /// 开始监视一个目录：挂目录事件源，并立即扫描一次。
    private func attach(_ watch: Watch, path: String, names: [String]) {
        watch.path = path
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            let isChat = watch.isChat
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, let watch = isChat ? self.chat : self.game else { return }
                self.directoryEvent(watch, mask: source.data)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watch.source = source
        }
        log.info("开始监视\(watch.isChat ? "聊天" : "游戏")日志目录：\(path, privacy: .private)")
        rescan(watch, names: names)
    }

    /// 目录事件：目录本身被删或改名时重新查找，否则 200 毫秒后扫描。
    private func directoryEvent(_ watch: Watch, mask: DispatchSource.FileSystemEvent) {
        guard !stopped else { return }
        if mask.contains(.delete) || mask.contains(.rename) {
            log.notice("日志目录被删除或改名，重新查找")
            detach(watch)
            resolve(watch)
            flushBackfill()
        } else {
            scheduleRescan(watch)
        }
    }

    /// 停止监视一个目录：关闭这一侧的全部文件与目录事件源。
    private func detach(_ watch: Watch) {
        for (key, file) in files where key.hasPrefix(watch.prefix) {
            file.close()
            files[key] = nil
        }
        if watch.isChat { chatHeaders = [:] } else { gameHeaders = [:] }
        pendingHeaders = pendingHeaders.filter { !$0.hasPrefix(watch.prefix) }
        watch.source?.cancel()
        watch.source = nil
        watch.path = nil
        updateSafetyTimer()
    }

    // MARK: - 扫描

    /// 排一次 200 毫秒后的扫描，期间的多次请求合并。
    private func scheduleRescan(_ watch: Watch) {
        guard !watch.rescanScheduled else { return }
        watch.rescanScheduled = true
        // 闭包只捕获可发送的值，到点时按种类取回目录。
        let isChat = watch.isChat
        queue.asyncAfter(deadline: .now() + ChatLogTailer.rescanDebounce) { [weak self] in
            guard let self, !self.stopped, let watch = isChat ? self.chat : self.game else { return }
            watch.rescanScheduled = false
            self.rescan(watch)
            self.flushBackfill()
        }
    }

    /// 30 秒的保险：两个已找到的目录各扫描一次。
    private func rescanAll() {
        for watch in [chat, game].compactMap({ $0 }) where watch.path != nil {
            rescan(watch)
        }
        flushBackfill()
    }

    /// 重新列目录并扫描。目录不见了时重新查找，被拒绝时转入重查。
    private func rescan(_ watch: Watch) {
        guard !stopped, let path = watch.path else { return }
        switch GameLogFileSystem.list(path) {
        case .entries(let names):
            rescan(watch, names: names)
        case .denied:
            detach(watch)
            if watch.isChat { setStatus(.accessDenied(path: path)) }
            updateRetryTimer()
        case .missing:
            detach(watch)
            resolve(watch)
        }
    }

    /// 按目录条目决定跟踪哪些文件，然后更新保险定时器与状态。
    private func rescan(_ watch: Watch, names: [String]) {
        guard !stopped, let path = watch.path else { return }
        if watch.isChat {
            rescanChat(path, names: names)
        } else {
            rescanGame(path, names: names)
        }
        updateSafetyTimer()
        // 状态只反映聊天日志目录；文件数含两种日志。聊天日志目录还没找到时保持原来的状态。
        if let chatPath = chat.path {
            setStatus(.watching(directory: chatPath, followedFiles: files.count))
        }
    }

    /// 聊天日志的扫描（5.4 节的 6 条规则）。
    private func rescanChat(_ directory: String, names: [String]) {
        let now = Date().timeIntervalSince1970
        var candidates: [ChatLogDirectory.Candidate] = []
        var createdAt: [String: Double] = [:]
        var present: Set<String> = []
        var pending: Set<String> = []
        for name in names {
            // 规则 1：文件名合法，48 小时内修改过。
            guard let fileName = ChatLogDirectory.parseFileName(name) else { continue }
            present.insert(name)
            let path = directory + "/" + name
            guard let info = GameLogFileSystem.info(path), now - info.modifiedAt <= ChatLogDirectory.recentSeconds else {
                continue
            }
            // 规则 2：读文件头并按文件名缓存；不完整的不缓存，2 秒后的保险到点时重读。
            if chatHeaders[name] == nil {
                switch LogTailReader.probeChatHeader(path) {
                case .complete(let header): chatHeaders[name] = header
                case .incomplete: pending.insert("chat/" + name)
                case .unreadable: break
                }
            }
            // 规则 3、4：要有收听者与 Channel ID，不是私聊；与请求的频道匹配，或是读位置线索用的 Local。
            guard let header = chatHeaders[name], let listener = header.listener, let id = header.channelID,
                  header.kind != .privateChat,
                  isRequested(header) || (request.followsLocation && header.kind == .local) else { continue }
            candidates.append(ChatLogDirectory.Candidate(name: name, stamp: fileName.stamp, listener: listener,
                                                         channelID: id))
            createdAt[name] = info.createdAt
        }
        // 已不在目录里的文件不再缓存，缓存的大小随目录变化。
        chatHeaders = chatHeaders.filter { present.contains($0.key) }
        everFollowed = everFollowed.filter { !$0.hasPrefix("chat/") || present.contains(String($0.dropFirst(5))) }
        pendingHeaders = pendingHeaders.filter { !$0.hasPrefix("chat/") }.union(pending)
        // 规则 5、6：每个（收听者，频道 ID）最新的一个，至多 48 个；不再被选中的停止跟踪。
        let selected = Set(ChatLogDirectory.selectFollowed(candidates))
        for (key, file) in files where key.hasPrefix("chat/") && !selected.contains(file.name) {
            file.close()
            files[key] = nil
        }
        for name in selected where files["chat/" + name] == nil {
            guard let header = chatHeaders[name] else { continue }
            followChat(name, path: directory + "/" + name, header: header, createdAt: createdAt[name])
        }
        // 用 48 个上限之前的候选：被上限挤掉的文件仍然存在，提示「EVE 没有写日志」不对。
        // 第一次上报前若还有文件头没写完的文件，先不报，免得启动时闪一下提示（2 秒后的保险会再扫描）。
        if pending.isEmpty || reportedFollowed != nil { reportFollowed(candidates) }
    }

    /// 把候选文件（48 小时内、频道匹配）的收听者与频道交给主线程（去重、排序后与上次相同时不交）。
    /// 没被选中或没打开成功的文件也算：文件在，提示「没有日志文件」反而误导。
    private func reportFollowed(_ candidates: [ChatLogDirectory.Candidate]) {
        guard let onFollowed else { return }
        var seen: Set<FollowedChatChannel> = []
        for candidate in candidates {
            seen.insert(FollowedChatChannel(listener: candidate.listener, channelID: candidate.channelID,
                                            channelName: chatHeaders[candidate.name]?.channelName))
        }
        // 排序让结果稳定，只在内容真的变了时回调。
        let followed = seen.sorted {
            ($0.listener, $0.channelID, $0.channelName ?? "") < ($1.listener, $1.channelID, $1.channelName ?? "")
        }
        guard followed != reportedFollowed else { return }
        reportedFollowed = followed
        DispatchQueue.main.async { MainActor.assumeIsolated { onFollowed(followed) } }
    }

    /// 游戏日志的扫描：48 小时内修改过、有收听者的文件，每个收听者取文件名最大的一个，至多 16 个。
    private func rescanGame(_ directory: String, names: [String]) {
        let now = Date().timeIntervalSince1970
        var candidates: [CombatLogDirectory.Candidate] = []
        var createdAt: [String: Double] = [:]
        var present: Set<String> = []
        var pending: Set<String> = []
        for name in names where CombatLogDirectory.isLogFileName(name) {
            present.insert(name)
            let path = directory + "/" + name
            guard let info = GameLogFileSystem.info(path),
                  CombatLogDirectory.isRecent(modifiedAt: info.modifiedAt, now: now) else { continue }
            if gameHeaders[name] == nil {
                switch GameLogFileSystem.probeHeader(path) {
                case .complete(let listener, let encoding): gameHeaders[name] = (listener, encoding)
                case .incomplete: pending.insert("game/" + name)
                case .unreadable: break
                }
            }
            guard let listener = gameHeaders[name]?.listener else { continue }
            candidates.append(CombatLogDirectory.Candidate(name: name, listener: listener))
            createdAt[name] = info.createdAt
        }
        gameHeaders = gameHeaders.filter { present.contains($0.key) }
        everFollowed = everFollowed.filter { !$0.hasPrefix("game/") || present.contains(String($0.dropFirst(5))) }
        pendingHeaders = pendingHeaders.filter { !$0.hasPrefix("game/") }.union(pending)
        // 与战斗提醒相同的取舍规则（反馈文档 7.3 节）：每个收听者取文件名最大的一个，至多 16 个。
        let selected = Set(CombatLogDirectory.selectFollowed(candidates))
        for (key, file) in files where key.hasPrefix("game/") && !selected.contains(file.name) {
            file.close()
            files[key] = nil
        }
        for name in selected where files["game/" + name] == nil {
            guard let header = gameHeaders[name], let listener = header.listener else { continue }
            followGame(name, path: directory + "/" + name, listener: listener,
                       encoding: header.encoding ?? .utf8, createdAt: createdAt[name])
        }
    }

    /// 文件头里的频道是否与请求的某个频道匹配（5.3 节）。
    private func isRequested(_ header: ChatLogHeader) -> Bool {
        request.channels.contains { $0.matches(channelID: header.channelID, channelName: header.channelName) }
    }

    // MARK: - 开始跟踪

    /// 一个文件的起点：再次跟踪、启动前已有、启动后新建。
    private enum StartPoint { case refollow, preExisting, created }

    /// 判断起点，并把键记进 everFollowed。
    private func startPoint(for key: String, createdAt: Double?) -> StartPoint {
        defer { everFollowed.insert(key) }
        if everFollowed.contains(key) { return .refollow }
        return CombatLogDirectory.startsAtEnd(createdAt: createdAt, tailerStartedAt: startedAt) ? .preExisting : .created
    }

    /// 开始跟踪一个聊天日志文件，按起点补读或从头读。
    private func followChat(_ name: String, path: String, header: ChatLogHeader, createdAt: Double?) {
        guard let listener = header.listener else { return }
        let key = "chat/" + name
        let requested = isRequested(header)
        let role = FollowedLogFile.Role.chat(header: header, kind: header.kind, isRequested: requested)
        guard let file = openFile(path, key: key, name: name, listener: listener, role: role,
                                  encoding: .utf16LittleEndian), let end = size(of: file) else { return }
        switch startPoint(for: key, createdAt: createdAt) {
        case .refollow:
            file.seek(to: end, dropsFirstLine: false)
        case .created:
            file.seek(to: 0, dropsFirstLine: false)
            scheduleRead(key, delay: 0)
        case .preExisting:
            // 先回读位置线索：不按时间过滤，取 Local 文件里最近的一条系统消息（5.6 节来源一）。
            if header.kind == .local, request.followsLocation,
               let line = LogTailReader.lastLocalSystemLine(file.fd, end: end) {
                backfill.append(.locationHint(LocationHint(character: listener, time: line.time, source: .localChannel,
                                                           text: line.text, isBackfill: true)))
            }
            if requested {
                backfillMessages(file, end: end)
            } else {
                file.seek(to: end, dropsFirstLine: false)
            }
        }
        log.info("开始跟踪聊天日志：\(name, privacy: .private)，种类 \(header.kind.rawValue, privacy: .public)")
    }

    /// 补读聊天日志末尾至多 512 KiB 的消息（5.4 节「补读的做法」），之后从 end 读新增内容。
    ///
    /// 系统消息不在这里上报位置线索：Local 文件的线索由回读给出，避免重复。
    private func backfillMessages(_ file: FollowedLogFile, end: Int64) {
        let start = ChatLogDirectory.backfillStart(fileSize: end, maxBytes: ChatLogTailer.backfillBytes)
        file.seek(to: start, dropsFirstLine: true)
        var lines: [String] = []
        // 512 KiB 小于一次读取的上限，通常一轮就读完；读到 end 为止，end 之后的内容留给之后的读取。
        while true {
            let result = file.readLines(upTo: end)
            lines += result.lines
            if !result.hasMore { break }
        }
        // 日志里的时间是 UTC（EVE 时间），与墙上时钟同一基准。
        let cutoff = Date().timeIntervalSince1970 - request.backfillSeconds
        for raw in lines {
            guard let line = ChatLogParser.parseLine(raw), !line.isSystem, line.time >= cutoff,
                  let event = message(line, in: file, isBackfill: true) else { continue }
            backfill.append(event)
        }
    }

    /// 开始跟踪一个游戏日志文件。启动前已有的文件回读最后 20 条 (None) 行（5.6 节来源二）。
    private func followGame(_ name: String, path: String, listener: String, encoding: LogTextEncoding,
                            createdAt: Double?) {
        let key = "game/" + name
        guard let file = openFile(path, key: key, name: name, listener: listener, role: .game, encoding: encoding),
              let end = size(of: file) else { return }
        switch startPoint(for: key, createdAt: createdAt) {
        case .refollow:
            file.seek(to: end, dropsFirstLine: false)
        case .created:
            file.seek(to: 0, dropsFirstLine: false)
            scheduleRead(key, delay: 0)
        case .preExisting:
            for note in LogTailReader.lastGameNotes(file.fd, end: end, encoding: encoding) {
                backfill.append(.locationHint(LocationHint(character: listener, time: note.time, source: .gameLog,
                                                           text: note.text, isBackfill: true)))
            }
            file.seek(to: end, dropsFirstLine: false)
        }
        log.info("开始跟踪游戏日志：\(name, privacy: .private)")
    }

    /// 打开文件并登记；打不开时记日志并返回 nil。
    private func openFile(_ path: String, key: String, name: String, listener: String, role: FollowedLogFile.Role,
                      encoding: LogTextEncoding) -> FollowedLogFile? {
        let file = FollowedLogFile(path: path, key: key, name: name, listener: listener, role: role,
                                   encoding: encoding, queue: queue) { [weak self] mask in
            self?.fileEvent(key, mask: mask)
        }
        guard let file else {
            log.notice("打不开日志文件：\(name, privacy: .private)")
            return nil
        }
        files[key] = file
        return file
    }

    /// 刚打开的文件的长度；读不到时关闭并注销它，免得它停在偏移量 0、把旧内容当成新内容读出来。
    private func size(of file: FollowedLogFile) -> Int64? {
        if let size = file.currentSize() { return size }
        file.close()
        files[file.key] = nil
        return nil
    }

    // MARK: - 读取

    /// 文件事件：被删或改名时停止跟踪并扫描，否则排一次读取。
    private func fileEvent(_ key: String, mask: DispatchSource.FileSystemEvent) {
        guard !stopped, let file = files[key] else { return }
        if mask.contains(.delete) || mask.contains(.rename) {
            file.close()
            files[key] = nil
            if let watch = key.hasPrefix("chat/") ? chat : game { scheduleRescan(watch) }
        } else {
            scheduleRead(key, delay: ChatLogTailer.readDebounce)
        }
    }

    /// 排一次读取。已排定时不重复排，这段时间内的多次写入合并成一次读取。
    private func scheduleRead(_ key: String, delay: Double) {
        guard let file = files[key], !file.readScheduled else { return }
        file.readScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.performRead(key) }
    }

    /// 读一个文件新增的内容，一次读取的事件合成一批上报。还有剩余时立即再排一次。
    private func performRead(_ key: String) {
        guard !stopped, let file = files[key], !file.isClosed else { return }
        file.readScheduled = false
        let result = file.readLines()
        emit(result.lines.compactMap { event(from: $0, in: file) })
        // 读取出错时 hasMore 为 false，不立即重读；2 秒的保险定时器看到长度与偏移量不同，会再排一次。
        if result.hasMore { scheduleRead(key, delay: 0) }
    }

    /// 把一行新内容转成事件（5.5 节）；不上报的行返回 nil。
    private func event(from raw: String, in file: FollowedLogFile) -> ChatLogEvent? {
        switch file.role {
        case .chat(_, let kind, _):
            // 文件头的各行与不是「[ 时间 ] 说话人 > 正文」形式的行在这里被丢掉。
            guard let line = ChatLogParser.parseLine(raw) else { return nil }
            guard line.isSystem else { return message(line, in: file, isBackfill: false) }
            guard kind == .local, request.followsLocation else { return nil }
            return .locationHint(LocationHint(character: file.listener, time: line.time, source: .localChannel,
                                              text: line.text, isBackfill: false))
        case .game:
            guard let note = LocationLineParser.gameNote(raw) else { return nil }
            return .locationHint(LocationHint(character: file.listener, time: note.time, source: .gameLog,
                                              text: note.text, isBackfill: false))
        }
    }

    /// 一条非系统消息：频道与请求匹配、正文不空时才上报。
    private func message(_ line: ChatLine, in file: FollowedLogFile, isBackfill: Bool) -> ChatLogEvent? {
        guard case .chat(let header, _, let requested) = file.role, requested, !line.text.isEmpty,
              let id = header.channelID else { return nil }
        return .message(ChatMessage(listener: file.listener, channelID: id, channelName: header.channelName ?? id,
                                    time: line.time, speaker: line.speaker, text: line.text, isBackfill: isBackfill))
    }

    /// 保险：每 2 秒查一次每个文件的长度，与已读偏移量不同就排一次读取；有文件头没写完的文件时重新扫描。
    private func safetyTick() {
        guard !stopped else { return }
        for (key, file) in files {
            if let size = file.currentSize(), size != file.offset { scheduleRead(key, delay: 0) }
        }
        if pendingHeaders.contains(where: { $0.hasPrefix("chat/") }) { scheduleRescan(chat) }
        if let game, pendingHeaders.contains(where: { $0.hasPrefix("game/") }) { scheduleRescan(game) }
    }

    /// 有被跟踪的文件或等文件头的文件时运行保险定时器，否则停掉（空闲时没有唤醒）。
    private func updateSafetyTimer() {
        let needed = !stopped && (!files.isEmpty || !pendingHeaders.isEmpty)
        if needed, safetyTimer == nil {
            safetyTimer = makeTimer(interval: ChatLogTailer.safetyInterval) { $0.safetyTick() }
        } else if !needed {
            cancelTimer(&safetyTimer)
        }
    }

    // MARK: - 上报

    /// 把这一轮补读到的事件按时间排好（时间相同的保持原顺序），合成一批交给主线程。
    private func flushBackfill() {
        guard !stopped, !backfill.isEmpty else { return }
        let sorted = backfill.enumerated().sorted { a, b in
            let (ta, tb) = (Self.time(of: a.element), Self.time(of: b.element))
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
        backfill = []
        emit(sorted)
    }

    /// 事件里的日志时间。
    private static func time(of event: ChatLogEvent) -> Double {
        switch event {
        case .message(let message): return message.time
        case .locationHint(let hint): return hint.time
        }
    }

    /// 一批事件交给主线程；空批次不交。
    private func emit(_ events: [ChatLogEvent]) {
        guard !events.isEmpty else { return }
        let handler = onEvents
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(events) } }
    }

    /// 状态变了时交给主线程。
    private func setStatus(_ newStatus: ChatLogStatus) {
        guard newStatus != status else { return }
        status = newStatus
        let handler = onStatus
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(newStatus) } }
    }

    // MARK: - 定时器

    /// 建一个在 queue 上重复触发的定时器。留 10% 的容差，让系统合并唤醒。
    private func makeTimer(interval: Double, _ body: @escaping @Sendable (ChatLogTailer) -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            body(self)
        }
        timer.resume()
        return timer
    }

    /// 取消一个定时器并清空引用。
    private func cancelTimer(_ timer: inout DispatchSourceTimer?) {
        timer?.cancel()
        timer = nil
    }
}
