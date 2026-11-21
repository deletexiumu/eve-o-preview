// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 intel 命令（docs/design-intel-translate.md 9.5 节）：`intel [目录] [--resolve-sample] [--resolve]`。
// 用真实的星图数据解析最近 48 小时的玩家频道日志，打印消息数、认作情报的条数、有星系、舰船、数量、人名的条数、
// 各情报用语的条数与跳数的分布；6.9 节增补：人名段的个数、只有一个词的个数、两个词以上的个数与候选名字的个数。
// - 跳数的出发点：读同一时段的游戏日志（跳跃与离站记录）与 Local 聊天日志的系统消息，经 LocationTracker 得到每个
//   收听者最后的位置，再按消息的收听者算。只是给出跳数的分布，不按消息的时刻回放位置。
// - --resolve-sample：向 ESI 发一个请求，内容是 3 个编造的名字（含 ' 与 -），打印状态、耗时、错误额度与各类结果的个数。
// - --resolve：把日志里的候选名字发给 ESI（每两批之间隔 2 秒），打印请求数、查到、有歧义、没查到的个数，
//   以及人数变了的消息条数。会把用户日志里的人名发给 CCP，实现方不自行运行，由主会话在用户同意后运行。
// 同一条消息会写进每个收听者的文件（C11），统计前按（时间，说话人，正文）去重。
// 探针不打印角色名、频道名、说话人与消息内容，只打印个数；全程只读日志目录。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// intel 命令的实现。
@MainActor enum IntelProbe {
    /// 编造的 3 个名字，给 --resolve-sample 用。
    static let sampleNames = ["Brenn Ostvar", "Tyra O'Kelloway", "Kael Doran-Vex"]

    /// 一条去重后的消息与它的收听者。
    struct Entry {
        var listener: String
        var text: String
    }

    /// 执行 intel 命令，返回进程退出码：成功 0，参数不对 2，缺少数据或目录 1。
    static func run(_ args: [String]) async -> Int32 {
        var directory: String?
        var sample = false
        var resolve = false
        for arg in args {
            switch arg {
            case "--resolve-sample": sample = true
            case "--resolve": resolve = true
            default:
                guard !arg.hasPrefix("--"), directory == nil else { return Probe.usage() }
                directory = (arg as NSString).expandingTildeInPath
            }
        }
        if sample { await resolveSample() }
        guard case .loaded(let data, let source) = await BundleStaticDataProvider().load() else {
            print("没有可用的星图数据，先运行 staticdata 检查")
            return 1
        }
        print("星图数据：来源 \(source)，SDE 版本 \(data.sdeBuild)")
        let home = NSHomeDirectory()
        let candidates = ChatLogDirectory.candidates(configured: directory, homeDirectory: home)
        guard let chatDirectory = candidates.first(where: { isDirectory($0) }) else {
            print("找不到聊天日志目录（试过 \(candidates.count) 个候选）")
            return 1
        }
        let (entries, tracker) = readLogs(chatDirectory: chatDirectory, configured: directory, home: home, data: data)
        let reports = entries.map { IntelParser.parse($0.text, data: data) }
        summarize(entries, reports: reports, tracker: tracker, data: data)
        if resolve { await resolveAll(reports) }
        return 0
    }

    // MARK: - 读日志

    /// 读最近 48 小时的玩家频道消息（去重），以及游戏日志与 Local 日志里的位置线索。
    private static func readLogs(chatDirectory: String, configured: String?, home: String,
                                 data: EVEStaticData) -> ([Entry], LocationTracker) {
        let cutoff = Date().timeIntervalSince1970 - ChatLogDirectory.recentSeconds
        var entries: [Entry] = []
        var seen: Set<String> = []
        var hints: [LocationHint] = []
        var playerFiles = 0
        var localFiles = 0
        for name in recentFiles(in: chatDirectory, since: cutoff) where ChatLogDirectory.parseFileName(name) != nil {
            guard let text = readUTF16(chatDirectory + "/" + name) else { continue }
            let lines = text.components(separatedBy: .newlines)
            let header = ChatLogParser.parseHeader(Array(lines.prefix(ChatLogParser.maxHeaderLines)))
            guard header.isComplete, let listener = header.listener else { continue }
            switch header.kind {
            case .player:
                playerFiles += 1
                for line in lines {
                    guard let parsed = ChatLogParser.parseLine(line), !parsed.isSystem, !parsed.text.isEmpty else {
                        continue
                    }
                    guard seen.insert("\(parsed.time)|\(parsed.speaker)|\(parsed.text)").inserted else { continue }
                    entries.append(Entry(listener: listener, text: parsed.text))
                }
            case .local:
                localFiles += 1
                for line in lines {
                    guard let parsed = ChatLogParser.parseLine(line), parsed.isSystem else { continue }
                    hints.append(LocationHint(character: listener, time: parsed.time, source: .localChannel,
                                              text: parsed.text, isBackfill: false))
                }
            default:
                continue
            }
        }
        var gameConfigured = configured
        if let configured, (configured as NSString).lastPathComponent.lowercased() == "chatlogs" {
            gameConfigured = ((configured as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("Gamelogs")
        }
        var gameFiles = 0
        let gameCandidates = CombatLogDirectory.candidates(configured: gameConfigured, homeDirectory: home)
        if let gameDirectory = gameCandidates.first(where: { isDirectory($0) }) {
            for name in recentFiles(in: gameDirectory, since: cutoff) where name.lowercased().hasSuffix(".txt") {
                guard let text = try? String(contentsOfFile: gameDirectory + "/" + name, encoding: .utf8) else {
                    continue
                }
                let lines = text.components(separatedBy: .newlines)
                guard let listener = CombatLogHeaderParser.parse(Array(lines.prefix(12))).listener else { continue }
                gameFiles += 1
                for line in lines {
                    guard let note = LocationLineParser.gameNote(line) else { continue }
                    hints.append(LocationHint(character: listener, time: note.time, source: .gameLog,
                                              text: note.text, isBackfill: false))
                }
            }
        }
        var tracker = LocationTracker()
        var located = 0
        for hint in hints.sorted(by: { $0.time < $1.time }) where tracker.apply(hint, data: data) { located += 1 }
        print("玩家频道文件 \(playerFiles) 个，Local 文件 \(localFiles) 个，游戏日志 \(gameFiles) 个")
        print("位置线索 \(hints.count) 条，改变位置 \(located) 次，有位置的收听者 \(tracker.locations.count) 个")
        return (entries, tracker)
    }

    /// 目录里修改时间不早于 since 的文件名，按名字排序。
    private static func recentFiles(in directory: String, since: Double) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { name in
            let attributes = try? manager.attributesOfItem(atPath: directory + "/" + name)
            guard let modified = attributes?[.modificationDate] as? Date else { return false }
            return modified.timeIntervalSince1970 >= since
        }
        .sorted()
    }

    /// 按 UTF-16 小端读一个聊天日志文件（C2）。
    private static func readUTF16(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf16)
    }

    /// 路径是否为已存在的目录。
    nonisolated private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    // MARK: - 统计

    /// 打印各项条数。
    private static func summarize(_ entries: [Entry], reports: [IntelReport], tracker: LocationTracker,
                                  data: EVEStaticData) {
        let settings = IntelSettings()
        var counters: [String: Int] = [:]
        var tables: [Int: [Int: Int]] = [:]
        var candidateKeys: Set<String> = []
        for (entry, report) in zip(entries, reports) {
            func bump(_ key: String, _ condition: Bool = true) { if condition { counters[key, default: 0] += 1 } }
            bump("intel", report.isIntelLike)
            bump("systems", !report.systemIDs.isEmpty)
            bump("ships", !report.ships.isEmpty)
            bump("count", (report.hostileCount ?? 0) > 0)
            bump("countExplicit", (report.hostileCount ?? 0) > 0 && report.countIsExplicit)
            bump("clear", report.isClear)
            bump("noVisual", report.isNoVisual)
            bump("pilots", !report.pilots.isEmpty)
            let runs = PilotSegmenter.runs(in: report)
            counters["runs", default: 0] += runs.count
            counters["singleRuns", default: 0] += runs.filter { $0.count == 1 }.count
            counters["multiRuns", default: 0] += runs.filter { $0.count >= 2 }.count
            let candidates = report.isIntelLike ? PilotSegmenter.candidates(in: report) : []
            bump("withCandidates", !candidates.isEmpty)
            for name in candidates { candidateKeys.insert(PilotLookupAnswer.key(for: name)) }
            guard !report.systemIDs.isEmpty else { continue }
            let origin = tracker.origin(for: entry.listener).systemID
            let table = origin.map { id in
                tables[id] ?? { let built = JumpGraph.distances(from: id, maxJumps: settings.maxJumps, in: data)
                                tables[id] = built
                                return built }()
            }
            let distances = report.systemIDs.map {
                JumpGraph.distance(to: $0, table: table, maxJumps: settings.maxJumps, in: data)
            }
            let known = distances.compactMap { distance -> Int? in
                if case .jumps(let jumps) = distance { return jumps }
                return nil
            }
            bump("jumpsKnown", !known.isEmpty)
            bump("jumpsAlert", known.contains { $0 <= settings.alertJumps })
            bump("jumpsBeyond", known.isEmpty && distances.contains(.beyond(limit: settings.maxJumps)))
            bump("jumpsUnreachable", known.isEmpty && distances.contains(.unreachable))
            bump("jumpsUnknownOrigin", table == nil)
        }
        let value = { (key: String) in counters[key] ?? 0 }
        print("消息（去重后）\(entries.count) 条，认作情报 \(value("intel")) 条")
        print("有星系 \(value("systems")) 条，有舰船 \(value("ships")) 条，有敌对数量 \(value("count")) 条"
              + "（写明 \(value("countExplicit")) 条），推断出人名 \(value("pilots")) 条")
        print("情报用语：clear \(value("clear")) 条，no visual \(value("noVisual")) 条")
        print("跳数（\(settings.maxJumps) 跳以内）：算出 \(value("jumpsKnown")) 条，其中 \(settings.alertJumps) 跳以内 "
              + "\(value("jumpsAlert")) 条；超出上限 \(value("jumpsBeyond")) 条，无星门 \(value("jumpsUnreachable")) 条，"
              + "收听者位置未知 \(value("jumpsUnknownOrigin")) 条")
        print("人名段 \(value("runs")) 个：一个词 \(value("singleRuns")) 个（不查），两个词以上 \(value("multiRuns")) 个；"
              + "有候选名字的情报 \(value("withCandidates")) 条，候选名字 \(candidateKeys.count) 个（去重）")
    }

    // MARK: - ESI

    /// --resolve-sample：发一个请求，内容是 3 个编造的名字。
    private static func resolveSample() async {
        guard let names = ESINameWire.batches(sampleNames).first else { return }
        let started = ContinuousClock.now
        let result = await ESIPilotNameResolver().resolve(names)
        let milliseconds = Probe.milliseconds(since: started)
        switch result {
        case .success(let answer):
            let tally = tally(answer.outcomes.values)
            print("--resolve-sample：状态码 200，耗时 \(milliseconds) 毫秒，错误额度 "
                  + "\(answer.errorLimitRemain.map(String.init) ?? "-")（\(answer.errorLimitReset.map(String.init) ?? "-") 秒后重置），"
                  + "查到 \(tally.matched)，有歧义 \(tally.ambiguous)，没查到 \(tally.notFound)")
        case .failure(let failure):
            print("--resolve-sample：失败 \(failure)，耗时 \(milliseconds) 毫秒")
        }
    }

    /// --resolve：把日志里情报的候选名字发给 ESI，统计结果与人数变了的消息条数。
    private static func resolveAll(_ reports: [IntelReport]) async {
        let names = reports.filter(\.isIntelLike).flatMap { PilotSegmenter.candidates(in: $0) }
        let batches = ESINameWire.batches(names)
        let resolver = ESIPilotNameResolver()
        var outcomes: [String: PilotLookupOutcome] = [:]
        var failures = 0
        // rejected 说明请求的写法有错，之后的批次不再发，避免继续扣错误额度。
        requests: for (index, batch) in batches.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(PilotLookupQueue.minimumInterval)) }
            switch await resolver.resolve(batch) {
            case .success(let answer): outcomes.merge(answer.outcomes) { _, new in new }
            case .failure(let failure):
                failures += 1
                print("第 \(index + 1) 个请求失败：\(failure)")
                if case .rejected = failure { break requests }
            }
        }
        let tally = tally(outcomes.values)
        let directory = PilotDirectory(outcomes)
        let changed = reports.filter { report in
            report.isIntelLike && !report.pilots.isEmpty
                && PilotSegmenter.resolve(report, directory: directory).hostileCount != report.hostileCount
        }.count
        print("--resolve：请求 \(batches.count) 个（失败 \(failures) 个），名字 \(outcomes.count) 个："
              + "查到 \(tally.matched)，有歧义 \(tally.ambiguous)，没查到 \(tally.notFound)；人数变了的消息 \(changed) 条")
    }

    /// 各类结果的个数。
    private static func tally<S: Sequence>(_ outcomes: S) -> (matched: Int, ambiguous: Int, notFound: Int)
        where S.Element == PilotLookupOutcome {
        var result = (matched: 0, ambiguous: 0, notFound: 0)
        for outcome in outcomes {
            switch outcome {
            case .matched: result.matched += 1
            case .ambiguous: result.ambiguous += 1
            case .notFound: result.notFound += 1
            }
        }
        return result
    }
}
