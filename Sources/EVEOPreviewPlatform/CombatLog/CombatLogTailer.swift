// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的跟踪逻辑（反馈文档 7.3 节、7.4 节、7.7 节）。全部状态只在自己的串行队列（utility）上访问，
// 结果用 DispatchQueue.main.async 交回主线程。
// - 目录：取候选里第一个能列出的目录。都不存在时状态是 directoryNotFound，被系统拒绝时是 accessDenied，
//   两种情况每 10 秒重查一次。目录用 O_EVTONLY 打开，事件源监听 write、delete、rename。
// - 扫描：启动时一次；目录事件到达后 200 毫秒一次（期间的事件合并）；每 30 秒一次作保险。
//   只看 48 小时内修改过的 .txt；按文件头的收听者取每个角色文件名最大的文件，至多 16 个。
// - 读取：文件的 write、extend 事件到达后 100 毫秒读一次（期间的写入合并）；有被跟踪的文件时
//   每 2 秒查一次长度作保险。一次读取里每个文件至多产生两条受击事件（CombatAlertRules.events）。
//   从头读起的文件（启动后新建、或晚跟踪），接入时已有的内容丢掉时间早于接入时刻减 5 秒的行（CombatLogReplayGuard）。
// - stop()：取消全部事件源与定时器，关闭全部描述符。
// 只读日志文件，不写、不改、不删 EVE 目录下的任何内容。系统日志里的角色名、文件名与路径按 .private 记录。

import Dispatch
import Foundation
import os
import EVEOPreviewCore

/// 游戏日志的跟踪服务。可在任意线程调用 `start()` 与 `stop()`；回调在主线程执行。
///
/// 可变状态只在 `queue` 上读写（串行队列保证互斥），所以标为 `@unchecked Sendable`。
public final class CombatLogTailer: @unchecked Sendable {
    /// 一次读取由什么引起。
    public enum ReadTrigger: String, Sendable {
        /// 文件的 write 或 extend 事件（kqueue）。
        case fileEvent
        /// 每 2 秒查长度的保险。
        case safetyNet
        /// 上一次读取达到 1 MiB 上限后的续读，或新文件开始跟踪时的首次读取。
        case continuation
    }

    /// 一行的诊断记录，只供探针使用（V13）。
    public struct LineRecord: Sendable {
        /// 文件头里的收听者。只在内存里使用，探针不打印。
        public var listener: String
        /// 收到这一行的时刻（1970 年以来的秒数）。
        public var receivedAt: Double
        /// 日志行里的时间（UTC，1970 年以来的秒数）。
        public var logTime: Double?
        /// 归类结果。
        public var line: CombatLogLine
        /// 这次读取由什么引起。
        public var trigger: ReadTrigger
    }

    /// 扫描的时间参数（秒）。
    static let rescanDebounce = 0.2
    static let rescanInterval = 30.0
    static let readDebounce = 0.1
    static let safetyInterval = 2.0
    static let retryInterval = 10.0

    private let candidates: [String]
    private let queue = DispatchQueue(label: "io.github.deletexiumu.eveopreview.combatlog", qos: .utility)
    private let onEvents: @MainActor @Sendable ([CombatLogEvent]) -> Void
    private let onStatus: @MainActor @Sendable (CombatLogStatus) -> Void
    private let onLines: (@MainActor @Sendable ([LineRecord]) -> Void)?
    private let log = Logger(subsystem: PlatformLog.subsystem, category: "CombatLog")

    // 以下状态只在 queue 上访问。
    /// `stop()` 之后为真，所有排队中的回调到这里直接返回。
    private var stopped = false
    /// `start()` 的时刻，用来判断文件是启动前已有的还是启动后新建的。
    private var startedAt: Double = 0
    /// 正在监视的目录；nil 表示还没找到或已断开。
    private var directory: String?
    /// 目录事件源（write、delete、rename）。
    private var directorySource: DispatchSourceFileSystemObject?
    /// 正在跟踪的文件，键是文件名。
    private var files: [String: TailedLogFile] = [:]
    /// 文件头的探测结果，按文件名缓存：收听者与编码；收听者为 nil 表示忽略（登录界面阶段的文件）。
    private var headerCache: [String: (listener: String?, encoding: LogTextEncoding?)] = [:]
    /// 文件头还没写完的文件，保险定时器到点时重新扫描。
    private var pendingHeaders: Set<String> = []
    /// 跟踪过的文件名。只有第一次跟踪时可能从头读起；之后再跟踪（目录被拒绝后恢复、目录重新出现）
    /// 一律从末尾读起，否则启动后才建的文件会把已经提醒过的历史行再提醒一次。
    /// 停止监视目录时不清空，扫描时只保留目录里还在的文件名，大小随目录变化。
    private var everFollowed: Set<String> = []
    /// 已排定一次延迟扫描（200 毫秒内的目录事件合并成一次）。
    private var rescanScheduled = false
    /// 30 秒的扫描定时器，目录事件丢失时的保险。
    private var rescanTimer: DispatchSourceTimer?
    /// 2 秒的长度检查定时器，只在有被跟踪的文件或等文件头的文件时运行。
    private var safetyTimer: DispatchSourceTimer?
    /// 10 秒的目录重查定时器，目录不存在或被拒绝时运行。
    private var retryTimer: DispatchSourceTimer?
    /// 当前对外报告的状态；只在变化时才回调，避免重复通知主线程。
    private var status: CombatLogStatus = .stopped

    /// 建跟踪服务，调用 `start()` 后才开始工作。
    ///
    /// - Parameters:
    ///   - candidates: 按优先顺序排列的候选目录（`CombatLogDirectory.candidates`）。
    ///   - onEvents: 一批受击事件，在主线程调用。
    ///   - onStatus: 状态变化，在主线程调用。
    ///   - onLines: 每次读取解析出的全部行，在主线程调用。只供探针诊断，应用传 nil。
    public init(candidates: [String],
                onEvents: @escaping @MainActor @Sendable ([CombatLogEvent]) -> Void,
                onStatus: @escaping @MainActor @Sendable (CombatLogStatus) -> Void,
                onLines: (@MainActor @Sendable ([LineRecord]) -> Void)? = nil) {
        self.candidates = candidates
        self.onEvents = onEvents
        self.onStatus = onStatus
        self.onLines = onLines
    }

    /// 开始跟踪：记下启动时刻，查找目录。
    public func start() {
        queue.async {
            guard !self.stopped else { return }
            self.startedAt = Date().timeIntervalSince1970
            self.resolveDirectory()
        }
    }

    /// 停止跟踪：取消全部事件源与定时器，关闭全部描述符。之后不再回调。
    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.detachDirectory()
            self.cancelTimer(&self.retryTimer)
            self.setStatus(.stopped)
        }
    }

    // MARK: - 目录

    /// 取候选里第一个能列出的目录并开始监视；都不行时设状态并每 10 秒重查。
    private func resolveDirectory() {
        guard !stopped else { return }
        for path in candidates {
            switch GameLogFileSystem.list(path) {
            case .entries(let names):
                attach(path, names: names)
                return
            case .denied:
                log.notice("列游戏日志目录被拒绝：\(path, privacy: .private)")
                enterRetry(.accessDenied(path: path))
                return
            case .missing:
                continue
            }
        }
        enterRetry(.directoryNotFound(path: candidates.first ?? ""))
    }

    /// 进入重查状态：设状态，启动 10 秒的重查定时器。
    private func enterRetry(_ newStatus: CombatLogStatus) {
        setStatus(newStatus)
        guard retryTimer == nil else { return }
        retryTimer = makeTimer(interval: CombatLogTailer.retryInterval) { tailer in tailer.resolveDirectory() }
    }

    /// 开始监视一个目录：挂目录事件源、启动 30 秒的扫描定时器，并立即扫描一次。
    private func attach(_ path: String, names: [String]) {
        cancelTimer(&retryTimer)
        directory = path
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                self.directoryEvent(source.data)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            directorySource = source
        }
        rescanTimer = makeTimer(interval: CombatLogTailer.rescanInterval) { tailer in tailer.rescan() }
        log.info("开始监视游戏日志目录：\(path, privacy: .private)")
        rescan(names: names)
    }

    /// 目录事件：目录本身被删或改名时重新查找，否则 200 毫秒后扫描。
    private func directoryEvent(_ mask: DispatchSource.FileSystemEvent) {
        guard !stopped else { return }
        if mask.contains(.delete) || mask.contains(.rename) {
            log.notice("游戏日志目录被删除或改名，重新查找")
            detachDirectory()
            resolveDirectory()
        } else {
            scheduleRescan()
        }
    }

    /// 停止监视当前目录：关闭全部文件与目录事件源，停掉扫描与保险定时器。
    private func detachDirectory() {
        for file in files.values { file.close() }
        files = [:]
        headerCache = [:]
        pendingHeaders = []
        directorySource?.cancel()
        directorySource = nil
        directory = nil
        cancelTimer(&rescanTimer)
        cancelTimer(&safetyTimer)
    }

    // MARK: - 扫描

    /// 排一次 200 毫秒后的扫描，期间的多次请求合并。
    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        queue.asyncAfter(deadline: .now() + CombatLogTailer.rescanDebounce) { [weak self] in
            guard let self else { return }
            self.rescanScheduled = false
            self.rescan()
        }
    }

    /// 重新列目录并扫描。目录不见了或被拒绝时转入重查。
    private func rescan() {
        guard !stopped, let directory else { return }
        switch GameLogFileSystem.list(directory) {
        case .entries(let names):
            rescan(names: names)
        case .denied:
            detachDirectory()
            enterRetry(.accessDenied(path: directory))
        case .missing:
            detachDirectory()
            resolveDirectory()
        }
    }

    /// 按目录条目决定跟踪哪些文件（7.3 节的扫描规则）。
    private func rescan(names: [String]) {
        guard !stopped, let directory else { return }
        let now = Date().timeIntervalSince1970
        var candidates: [CombatLogDirectory.Candidate] = []
        var createdAt: [String: Double] = [:]
        var pending: Set<String> = []
        var present: Set<String> = []
        for name in names where CombatLogDirectory.isLogFileName(name) {
            present.insert(name)
            let path = directory + "/" + name
            guard let info = GameLogFileSystem.info(path),
                  CombatLogDirectory.isRecent(modifiedAt: info.modifiedAt, now: now) else { continue }
            if headerCache[name] == nil {
                switch GameLogFileSystem.probeHeader(path) {
                case .complete(let listener, let encoding):
                    headerCache[name] = (listener, encoding)
                case .incomplete:
                    pending.insert(name)
                case .unreadable:
                    break
                }
            }
            guard let listener = headerCache[name]?.listener else { continue }
            candidates.append(CombatLogDirectory.Candidate(name: name, listener: listener))
            createdAt[name] = info.createdAt
        }
        // 已不在目录里的文件不再缓存，缓存的大小随目录变化而不是一直增长。
        headerCache = headerCache.filter { present.contains($0.key) }
        everFollowed.formIntersection(present)
        pendingHeaders = pending
        let selected = Set(CombatLogDirectory.selectFollowed(candidates))
        for (name, file) in files where !selected.contains(name) {
            file.close()
            files[name] = nil
        }
        for name in selected where files[name] == nil {
            follow(name, in: directory, createdAt: createdAt[name])
        }
        updateSafetyTimer()
        setStatus(.watching(directory: directory, followedFiles: files.count))
    }

    /// 开始跟踪一个文件。启动后才建的文件从头读起，并立即读一次已有的内容。
    private func follow(_ name: String, in directory: String, createdAt: Double?) {
        guard let cached = headerCache[name], let listener = cached.listener else { return }
        let startAtEnd = everFollowed.contains(name)
            || CombatLogDirectory.startsAtEnd(createdAt: createdAt, tailerStartedAt: startedAt)
        let file = TailedLogFile(path: directory + "/" + name, name: name, listener: listener,
                                 startAtEnd: startAtEnd, encoding: cached.encoding,
                                 attachedAt: Date().timeIntervalSince1970, queue: queue) { [weak self] mask in
            self?.fileEvent(name, mask: mask)
        }
        guard let file else {
            log.notice("打不开游戏日志文件：\(name, privacy: .private)")
            return
        }
        files[name] = file
        everFollowed.insert(name)
        log.info("开始跟踪：\(name, privacy: .private)，角色 \(listener, privacy: .private)，从\(startAtEnd ? "末尾" : "开头")读起")
        if !startAtEnd {
            scheduleRead(name, trigger: .continuation, delay: 0)
        }
    }

    // MARK: - 读取

    /// 文件事件：被删或改名时停止跟踪并扫描，否则排一次读取。
    private func fileEvent(_ name: String, mask: DispatchSource.FileSystemEvent) {
        guard !stopped, let file = files[name] else { return }
        if mask.contains(.delete) || mask.contains(.rename) {
            file.close()
            files[name] = nil
            scheduleRescan()
        } else {
            scheduleRead(name, trigger: .fileEvent, delay: CombatLogTailer.readDebounce)
        }
    }

    /// 排一次读取。已排定时不重复排，这段时间内的多次写入合并成一次读取。
    private func scheduleRead(_ name: String, trigger: ReadTrigger, delay: Double) {
        guard let file = files[name], !file.readScheduled else { return }
        file.readScheduled = true
        file.pendingTrigger = trigger
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.performRead(name) }
    }

    /// 读一个文件新增的内容，归类后上报受击事件。还有剩余时立即再排一次。
    private func performRead(_ name: String) {
        guard !stopped, let file = files[name], !file.isClosed else { return }
        file.readScheduled = false
        let trigger = file.pendingTrigger
        let result = file.readNewLines()
        if !result.lines.isEmpty {
            report(result.lines, from: file, trigger: trigger)
        }
        // 读取出错时 hasMore 为 false，不立即重读；2 秒的保险定时器看到长度与偏移量不同，会再排一次。
        if result.hasMore {
            scheduleRead(name, trigger: .continuation, delay: 0)
        }
    }

    /// 解析各行，按 7.7 节合并成事件交给主线程；有诊断回调时同时交出每一行。
    private func report(_ lines: [String], from file: TailedLogFile, trigger: ReadTrigger) {
        let parsed = lines.compactMap { line in CombatLogParser.parse(line).map { (line, $0) } }
        let events = CombatAlertRules.events(for: file.listener, kinds: parsed.map(\.1.kind))
        if !events.isEmpty {
            let handler = onEvents
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(events) } }
        }
        if let onLines, !parsed.isEmpty {
            let now = Date().timeIntervalSince1970
            let records = parsed.map { raw, line in
                LineRecord(listener: file.listener, receivedAt: now, logTime: CombatLogParser.logTime(raw),
                           line: line, trigger: trigger)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { onLines(records) } }
        }
    }

    /// 保险：每 2 秒查一次每个文件的长度，与已读偏移量不同就排一次读取；有文件头没写完的文件时重新扫描。
    private func safetyTick() {
        guard !stopped else { return }
        for (name, file) in files {
            if let size = file.currentSize(), size != file.offset {
                scheduleRead(name, trigger: .safetyNet, delay: 0)
            }
        }
        if !pendingHeaders.isEmpty { scheduleRescan() }
    }

    /// 有被跟踪的文件或等文件头的文件时运行保险定时器，否则停掉（空闲时没有唤醒）。
    private func updateSafetyTimer() {
        let needed = !files.isEmpty || !pendingHeaders.isEmpty
        if needed, safetyTimer == nil {
            safetyTimer = makeTimer(interval: CombatLogTailer.safetyInterval) { tailer in tailer.safetyTick() }
        } else if !needed {
            cancelTimer(&safetyTimer)
        }
    }

    // MARK: - 工具

    /// 状态变了时交给主线程。
    private func setStatus(_ newStatus: CombatLogStatus) {
        guard newStatus != status else { return }
        status = newStatus
        let handler = onStatus
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(newStatus) } }
    }

    /// 建一个在 queue 上重复触发的定时器。留 10% 的容差，让系统合并唤醒。
    private func makeTimer(interval: Double, _ body: @escaping @Sendable (CombatLogTailer) -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(Int(interval * 100)))
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
