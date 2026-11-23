// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 gamelog 命令（反馈文档 7.12 节）：打印选中的游戏日志目录、每个候选文件的编码与是否有收听者、
// 各种 CombatLineKind 的行数，以及跟踪服务会选中哪些文件、它们的收听者对应哪个在线客户端（按 PID 显示）。
// 带 --follow 时用 CombatLogTailer 跟踪，逐行打印收到的时刻、种类、读取的起因（文件事件或 2 秒保险），
// 以及日志行时间与收到时刻的差（V13）。
// 探针不打印角色名与日志行的内容；文件只显示文件名开头的时间部分，不显示数字后缀。只读，不写 EVE 目录。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// gamelog 命令的实现。
@MainActor enum GameLogProbe {
    /// 一个日志文件的统计。
    private struct FileReport {
        var name: String
        var info: GameLogFileSystem.FileInfo
        var header: GameLogFileSystem.HeaderProbe
        var counts: [String: Int]
        var recent: Bool
    }

    /// 执行 gamelog 命令，返回进程退出码。
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
        let candidates = CombatLogDirectory.candidates(configured: configured, homeDirectory: home)
        let directory = chooseDirectory(candidates)
        let clients = await liveCharacters()
        print("在线客户端 \(clients.count) 个（PID）：\(clients.map { String($0.pid) }.joined(separator: "、"))")
        if let directory {
            summarize(directory: directory, clients: clients)
        }
        // 目录暂时不可用时仍可跟踪：用来观察跟踪服务每 10 秒重查、目录出现或获准后自动恢复。
        if let followSeconds {
            await follow(candidates: candidates, seconds: followSeconds, clients: clients)
        }
        return directory == nil ? 1 : 0
    }

    // MARK: - 目录与在线客户端

    /// 打印每个候选目录的状态，返回第一个能列出的目录。
    private static func chooseDirectory(_ candidates: [String]) -> String? {
        for path in candidates {
            switch GameLogFileSystem.list(path) {
            case .entries:
                print("选中目录：\(path)")
                return path
            case .denied:
                print("候选目录被系统拒绝（accessDenied）：\(path)")
                return nil
            case .missing:
                print("候选目录不存在：\(path)")
            }
        }
        print("没有可用的目录（directoryNotFound）")
        return nil
    }

    /// 在线的角色客户端：PID 与角色名。角色名只在内存里用来匹配收听者，不打印。
    private static func liveCharacters() async -> [(pid: Int32, name: String)] {
        let mains = ClientWindowSelector.mainWindows(from: await Probe.windows.candidateWindows())
        return mains.compactMap { window in
            TitleParser.identity(fromTitle: window.title).characterName.map { (window.pid, $0) }
        }
    }

    /// 按 7.5 节的比较办法找收听者对应的在线客户端：先按原样比较，再不区分大小写。
    private static func matchPID(_ listener: String, _ clients: [(pid: Int32, name: String)]) -> Int32? {
        if let exact = clients.first(where: { $0.name == listener }) { return exact.pid }
        return clients.first { $0.name.caseInsensitiveCompare(listener) == .orderedSame }?.pid
    }

    /// 文件名开头的时间部分（`yyyyMMdd_HHmmss`），不含可能识别角色的数字后缀。
    private static func shortName(_ name: String) -> String {
        String(name.prefix(15))
    }

    // MARK: - 统计

    /// 打印每个文件的编码、收听者有无、行数分类，以及跟踪服务会选中的文件。
    private static func summarize(directory: String, clients: [(pid: Int32, name: String)]) {
        guard case .entries(let names) = GameLogFileSystem.list(directory) else { return }
        let now = Date().timeIntervalSince1970
        var reports: [FileReport] = []
        var totals: [String: Int] = [:]
        // 文件名以 UTC 时间开头，按名称排序即按时间排序（L2）。每个文件整读一遍做统计，探针不在意耗时。
        for name in names.sorted() where CombatLogDirectory.isLogFileName(name) {
            let path = directory + "/" + name
            guard let info = GameLogFileSystem.info(path) else { continue }
            let counts = countKinds(path)
            counts.forEach { totals[$0.key, default: 0] += $0.value }
            reports.append(FileReport(name: name, info: info, header: GameLogFileSystem.probeHeader(path),
                                      counts: counts,
                                      recent: CombatLogDirectory.isRecent(modifiedAt: info.modifiedAt, now: now)))
        }
        print("日志文件 \(reports.count) 个，48 小时内修改过的 \(reports.filter(\.recent).count) 个")
        print("全部文件的行数：" + describe(totals))
        print("48 小时内的文件：")
        var candidates: [CombatLogDirectory.Candidate] = []
        for report in reports where report.recent {
            print("  \(shortName(report.name)) \(report.info.size) 字节 " + describe(report.header, clients: clients)
                  + "；" + describe(report.counts))
            if case .complete(let listener?, _) = report.header {
                candidates.append(CombatLogDirectory.Candidate(name: report.name, listener: listener))
            }
        }
        // 与跟踪服务相同的取舍规则：每个收听者取文件名最大的文件，至多 16 个。
        let selected = CombatLogDirectory.selectFollowed(candidates)
        print("跟踪服务会选中 \(selected.count) 个文件：")
        for name in selected {
            let listener = candidates.first { $0.name == name }?.listener ?? ""
            let pid = matchPID(listener, clients).map { "对应在线客户端 pid \($0)" } ?? "收听者不在线"
            print("  \(shortName(name)) → \(pid)")
        }
        let matched = Set(selected.compactMap { name in
            candidates.first { $0.name == name }.flatMap { matchPID($0.listener, clients) }
        })
        print("在线客户端有对应文件的：\(matched.count) / \(clients.count)")
    }

    /// 读整个文件并统计各类行数。`unparsed` 是不以「[ 时间 ] (类别)」开头的行（多行条目的后续行、文件头）。
    private static func countKinds(_ path: String) -> [String: Int] {
        guard let data = FileManager.default.contents(atPath: path) else { return ["unreadable": 1] }
        var framer = LogLineFramer()
        var lines = framer.append(data)
        lines += framer.append(Data([0x0A]))     // 最后一行可能没有换行符
        var counts: [String: Int] = [:]
        for line in lines {
            let key = CombatLogParser.parse(line).map { label($0.kind) } ?? "unparsed"
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// 归类结果的简称，不含伤害数字。
    private static func label(_ kind: CombatLineKind) -> String {
        switch kind {
        case .incomingDamage: return "incomingDamage"
        case .outgoingDamage: return "outgoingDamage"
        case .incomingMiss: return "incomingMiss"
        case .outgoingMiss: return "outgoingMiss"
        case .otherCombat: return "otherCombat"
        case .other: return "other"
        }
    }

    /// 按固定顺序打印各类行数。
    private static func describe(_ counts: [String: Int]) -> String {
        let order = ["incomingDamage", "outgoingDamage", "incomingMiss", "outgoingMiss", "otherCombat", "other",
                     "unparsed", "unreadable"]
        return order.compactMap { key in counts[key].map { "\(key) \($0)" } }.joined(separator: "，")
    }

    /// 文件头的描述：编码与收听者有无（含是否对应在线客户端），不含名字。
    private static func describe(_ header: GameLogFileSystem.HeaderProbe,
                                 clients: [(pid: Int32, name: String)]) -> String {
        switch header {
        case .complete(let listener, let encoding):
            let enc = encoding.map { "\($0)" } ?? "未知"
            guard let listener else { return "编码 \(enc)，没有收听者" }
            let pid = matchPID(listener, clients).map { "pid \($0)" } ?? "不在线"
            return "编码 \(enc)，有收听者（\(pid)）"
        case .incomplete:
            return "文件头未写完"
        case .unreadable:
            return "读不了"
        }
    }
}

// MARK: - 跟踪（--follow）

extension GameLogProbe {
    /// 用 CombatLogTailer 跟踪若干秒，逐行打印收到的时刻、种类、读取的起因与延迟（V13）。
    fileprivate static func follow(candidates: [String], seconds: Double,
                                   clients: [(pid: Int32, name: String)]) async {
        print("跟踪 \(NumberFormatter.localizedString(from: NSNumber(value: seconds), number: .decimal)) 秒；"
              + "启动前已有的文件只读新增内容。")
        let pids = Dictionary(clients.map { ($0.name, $0.pid) }, uniquingKeysWith: { first, _ in first })
        // 收听者到显示文字：在线时显示 PID，否则显示「离线角色」，不打印名字。
        let who: @MainActor @Sendable (String) -> String = { listener in
            if let pid = pids[listener] { return "pid \(pid)" }
            let lower = listener.lowercased()
            return pids.first { $0.key.lowercased() == lower }.map { "pid \($0.value)" } ?? "离线角色"
        }
        // 回调都在主线程执行，计数放进主线程隔离的对象里，跟踪结束后汇总。
        let box = FollowCounters()
        let tailer = CombatLogTailer(
            candidates: candidates,
            onEvents: { events in
                for event in events {
                    box.events += 1
                    print("  [\(clock())] 事件 \(who(event.character)) \(describeEvent(event.kind))")
                }
            },
            onStatus: { status in print("  [\(clock())] 状态 \(status)") },
            onLines: { records in
                for record in records {
                    box.lines += 1
                    box.byTrigger[record.trigger, default: 0] += 1
                    let delay = record.logTime.map { record.receivedAt - $0 }
                    if let delay { box.delays.append(delay) }
                    let delayText = delay.map { String(format: "%.2f 秒", $0) } ?? "未知"
                    print("  [\(clock())] 行 \(who(record.listener)) \(record.line.category) "
                          + "\(label(record.line.kind)) 起因 \(record.trigger.rawValue) 延迟 \(delayText)")
                }
            })
        // 等待期间主线程空闲，跟踪服务交回主线程的回调在这里依次执行。
        tailer.start()
        try? await Task.sleep(for: .seconds(seconds))
        tailer.stop()
        let triggers = box.byTrigger.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: "，")
        print("跟踪结束：收到 \(box.lines) 行（\(triggers.isEmpty ? "无" : triggers)），受击事件 \(box.events) 条")
        if !box.delays.isEmpty {
            // 日志时间是整秒，延迟的精度约 1 秒。
            let sorted = box.delays.sorted()
            print(String(format: "延迟（收到时刻减日志时间）：最小 %.2f 秒，中位 %.2f 秒，最大 %.2f 秒",
                         sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1]))
        }
    }

    /// 当前本地时刻，精确到毫秒。
    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    /// 受击事件的描述，含伤害数字。
    private static func describeEvent(_ kind: CombatLineKind) -> String {
        if case .incomingDamage(let amount) = kind { return "incomingDamage \(amount)" }
        return label(kind)
    }
}

/// 跟踪期间的计数。只在主线程读写。
@MainActor private final class FollowCounters: Sendable {
    var lines = 0
    var events = 0
    var byTrigger: [CombatLogTailer.ReadTrigger: Int] = [:]
    var delays: [Double] = []
}
