// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 chatlog 命令（docs/macos/design-intel-translate.md 9.5 节）：打印选中的聊天日志目录、各候选文件的频道种类、
// 编码与文件头是否完整，消息行、系统消息与位置线索的数量；另统计游戏日志里的 (None) 行与认得出目的星系的行。
// 带 --follow 时用 ChatLogTailer 跟踪（请求是日志里出现过的全部频道，并读位置线索），逐条打印事件的种类、
// 是否补读，以及日志时间与收到时刻的差。
// 隐私：聊天日志的文件名以频道名开头，探针只打印频道种类与文件名里的时间戳；不打印角色名、频道名、说话人、
// 消息与星系名。只读，不写 EVE 目录。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// chatlog 命令的实现。
@MainActor enum ChatLogProbe {
    /// 一类行的计数，键是固定的英文标签。
    private typealias Counts = [String: Int]

    /// 执行 chatlog 命令，返回进程退出码：0 成功，1 没有可用的目录，2 参数不对。
    static func run(_ args: [String]) async -> Int32 {
        // 参数：可选的目录（与配置里的 eveLogDirectory 同规则），可选的 --follow 秒数。
        var configured: String?
        var followSeconds: Double?
        var index = 0
        while index < args.count {
            if args[index] == "--follow", index + 1 < args.count, let seconds = Double(args[index + 1]) {
                followSeconds = seconds
                index += 2
            } else if !args[index].hasPrefix("--"), configured == nil {
                configured = args[index]
                index += 1
            } else {
                return Probe.usage()
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let chatCandidates = ChatLogDirectory.candidates(configured: configured, homeDirectory: home)
        guard let directory = chooseDirectory(chatCandidates, label: "聊天日志") else { return 1 }
        summarizeChat(directory: directory)
        let gameCandidates = ChatLogDirectory.gameLogCandidates(configured: configured, homeDirectory: home)
        if let gameDirectory = chooseDirectory(gameCandidates, label: "游戏日志") {
            summarizeGame(directory: gameDirectory)
        }
        // 频道发现与设置界面「从日志添加」走同一段代码，只打印各种类的个数。
        let channels = await FileChatLogMonitor().discoverChannels(logDirectory: configured)
        let byKind = Dictionary(grouping: channels, by: \.kind.rawValue).mapValues(\.count)
        print("最近 14 天的频道 \(channels.count) 个：" + describe(byKind, order: kindOrder))
        if let followSeconds {
            await follow(configured: configured, channels: channels.map(\.ref), seconds: followSeconds)
        }
        return 0
    }

    /// 频道种类的打印顺序。
    private static let kindOrder = ChatChannelKind.allKinds.map(\.rawValue)

    // MARK: - 目录

    /// 打印每个候选目录的状态，返回第一个能列出的目录。
    private static func chooseDirectory(_ candidates: [String], label: String) -> String? {
        for path in candidates {
            switch GameLogFileSystem.list(path) {
            case .entries:
                print("\(label)目录：\(path)")
                return path
            case .denied:
                print("\(label)目录被系统拒绝（accessDenied）：\(path)")
                return nil
            case .missing:
                print("\(label)候选目录不存在：\(path)")
            }
        }
        print("\(label)：没有可用的目录（directoryNotFound）")
        return nil
    }

    // MARK: - 聊天日志

    /// 打印每个聊天日志文件的种类、编码、文件头与各类行数，以及跟踪服务会选中多少个文件。
    private static func summarizeChat(directory: String) {
        guard case .entries(let names) = GameLogFileSystem.list(directory) else { return }
        let now = Date().timeIntervalSince1970
        var totals: Counts = [:]
        var files = 0
        var recentFiles = 0
        var candidates: [ChatLogDirectory.Candidate] = []
        print("48 小时内修改过的文件（种类 时间戳 字节数 编码 文件头；各类行数）：")
        for name in names.sorted() {
            guard let fileName = ChatLogDirectory.parseFileName(name) else { continue }
            let path = directory + "/" + name
            guard let info = GameLogFileSystem.info(path), let data = FileManager.default.contents(atPath: path) else {
                continue
            }
            files += 1
            // 整读一遍做统计，探针不在意耗时；补一个换行，让没有换行符的最后一行也被切出来。
            var framer = LogLineFramer()
            var lines = framer.append(data)
            lines += framer.append(Data(framer.encoding == .utf8 ? [0x0A] : [0x0A, 0x00]))
            let header = ChatLogParser.parseHeader(Array(lines.prefix(ChatLogParser.maxHeaderLines)))
            let counts = countChat(lines, kind: header.kind)
            counts.forEach { totals[$0.key, default: 0] += $0.value }
            // 只列 48 小时内修改过的文件，与跟踪服务的扫描规则一致；更早的只计入总数。
            guard now - info.modifiedAt <= ChatLogDirectory.recentSeconds else { continue }
            recentFiles += 1
            let encoding = framer.encoding.map { "\($0)" } ?? "未知"
            let headerText = header.isComplete
                ? "文件头完整（收听者\(header.listener == nil ? "无" : "有")，Channel ID\(header.channelID == nil ? "无" : "有")）"
                : "文件头不完整"
            print("  \(header.kind.rawValue) \(fileName.stamp) \(info.size) \(encoding) \(headerText)；"
                  + describe(counts, order: chatOrder))
            if let listener = header.listener, let id = header.channelID, header.kind != .privateChat {
                candidates.append(ChatLogDirectory.Candidate(name: name, stamp: fileName.stamp, listener: listener,
                                                             channelID: id))
            }
        }
        print("聊天日志 \(files) 个，48 小时内修改过的 \(recentFiles) 个")
        print("全部聊天日志的行数：" + describe(totals, order: chatOrder))
        // 与跟踪服务相同的取舍：每个（收听者，频道 ID）最新的一个，至多 48 个。
        let listeners = Set(candidates.map(\.listener)).count
        let selected = ChatLogDirectory.selectFollowed(candidates)
        print("把全部频道都选上时，跟踪服务会选中 \(selected.count) 个文件（收听者 \(listeners) 个）")
    }

    /// 判断空行时去掉的字符：空白、换行与行首的 BOM。
    private static let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// 聊天日志各类行的打印顺序。
    private static let chatOrder = ["message", "emptyMessage", "system", "locationHint", "unparsed"]

    /// 统计一个聊天日志文件的各类行：消息、正文为空的消息、系统消息、能取出星系名的 Local 系统消息、其他行。
    private static func countChat(_ lines: [String], kind: ChatChannelKind) -> Counts {
        var counts: Counts = [:]
        for raw in lines {
            guard let line = ChatLogParser.parseLine(raw) else {
                if !raw.trimmingCharacters(in: blank).isEmpty {
                    counts["unparsed", default: 0] += 1
                }
                continue
            }
            if line.isSystem {
                counts["system", default: 0] += 1
                if kind == .local, LocationLineParser.systemName(fromLocalSystemLine: line.text) != nil {
                    counts["locationHint", default: 0] += 1
                }
            } else {
                counts[line.text.isEmpty ? "emptyMessage" : "message", default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - 游戏日志

    /// 统计 48 小时内的游戏日志里类别是 None 的行，以及按 5.6 节的句式认得出目的星系的行。
    private static func summarizeGame(directory: String) {
        guard case .entries(let names) = GameLogFileSystem.list(directory) else { return }
        let now = Date().timeIntervalSince1970
        var totals: Counts = [:]
        var recentFiles = 0
        for name in names where CombatLogDirectory.isLogFileName(name) {
            let path = directory + "/" + name
            guard let info = GameLogFileSystem.info(path), CombatLogDirectory.isRecent(modifiedAt: info.modifiedAt, now: now),
                  let data = FileManager.default.contents(atPath: path) else { continue }
            recentFiles += 1
            // 游戏日志是 UTF-8（L4），补一个 0A 切出最后一行。
            var framer = LogLineFramer()
            var lines = framer.append(data)
            lines += framer.append(Data([0x0A]))
            for line in lines {
                guard let note = LocationLineParser.gameNote(line) else { continue }
                totals["none", default: 0] += 1
                if LocationLineParser.systemName(fromGameNote: note.text) != nil {
                    totals["destination", default: 0] += 1
                }
            }
        }
        print("游戏日志：48 小时内修改过的 \(recentFiles) 个；" + describe(totals, order: ["none", "destination"]))
    }

    // MARK: - 打印

    /// 按固定顺序打印计数；顺序外的键排在最后。没有任何计数时打印「无」。
    private static func describe(_ counts: Counts, order: [String]) -> String {
        let keys = order.filter { counts[$0] != nil } + counts.keys.filter { !order.contains($0) }.sorted()
        let text = keys.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: "，")
        return text.isEmpty ? "无" : text
    }
}

// MARK: - 跟踪（--follow）

extension ChatLogProbe {
    /// 用 ChatLogTailer 跟踪若干秒，逐条打印事件的种类、是否补读与延迟。
    fileprivate static func follow(configured: String?, channels: [ChannelRef], seconds: Double) async {
        print("跟踪 \(seconds) 秒：频道 \(channels.count) 个，读位置线索，补读 600 秒内的消息。")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let request = ChatLogRequest(logDirectory: configured, channels: channels, followsLocation: true,
                                     backfillSeconds: 600)
        // 回调都在主线程执行，计数放进主线程隔离的对象里，跟踪结束后汇总。
        // 回调在主线程执行；等待期间主线程空闲，跟踪服务交回的回调在这里依次执行。
        let box = ChatFollowCounters()
        let tailer = ChatLogTailer(
            request: request, homeDirectory: home,
            onEvents: { events in
                let now = Date().timeIntervalSince1970
                box.batches += 1
                for event in events {
                    let (label, time, backfill) = describe(event)
                    box.counts[label + (backfill ? "（补读）" : ""), default: 0] += 1
                    if !backfill { box.delays.append(now - time) }
                    print(String(format: "  [%@] %@%@ 日志时间差 %.1f 秒", clock(), label, backfill ? " 补读" : "",
                                 now - time))
                }
            },
            onStatus: { status in print("  [\(clock())] 状态 \(describe(status))") })
        tailer.start()
        try? await Task.sleep(for: .seconds(seconds))
        tailer.stop()
        let summary = box.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，")
        print("跟踪结束：\(box.batches) 批，\(summary.isEmpty ? "没有事件" : summary)")
        if !box.delays.isEmpty {
            // 日志时间是整秒，延迟的精度约 1 秒。
            let sorted = box.delays.sorted()
            print(String(format: "新内容的延迟（收到时刻减日志时间）：最小 %.2f 秒，中位 %.2f 秒，最大 %.2f 秒",
                         sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1]))
        }
    }

    /// 事件的种类标签、日志时间与是否补读。不含名字与正文。
    private static func describe(_ event: ChatLogEvent) -> (String, Double, Bool) {
        switch event {
        case .message(let message):
            return ("message/" + ChatLogParser.channelKind(id: message.channelID).rawValue, message.time,
                    message.isBackfill)
        case .locationHint(let hint):
            return ("locationHint/" + hint.source.rawValue, hint.time, hint.isBackfill)
        }
    }

    /// 状态的描述：目录路径是本机路径，可以打印；不含频道与角色。
    private static func describe(_ status: ChatLogStatus) -> String {
        switch status {
        case .stopped: return "stopped"
        case .watching(let directory, let files): return "watching \(directory)，\(files) 个文件"
        case .directoryNotFound(let path): return "directoryNotFound \(path)"
        case .accessDenied(let path): return "accessDenied \(path)"
        }
    }

    /// 当前本地时刻，精确到毫秒。
    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

/// 跟踪期间的计数。只在主线程读写。
@MainActor private final class ChatFollowCounters: Sendable {
    /// 收到的批数。
    var batches = 0
    /// 各类事件的条数，键是种类标签（补读的另计）。
    var counts: [String: Int] = [:]
    /// 新内容的延迟（收到时刻减日志时间），单位是秒。
    var delays: [Double] = []
}

extension ChatChannelKind {
    /// 全部种类，按打印顺序。ChatChannelKind 没有声明 CaseIterable（WP-0 的类型），探针自己列。
    fileprivate static let allKinds: [ChatChannelKind] = [.local, .corp, .alliance, .fleet, .player, .privateChat, .other]
}
