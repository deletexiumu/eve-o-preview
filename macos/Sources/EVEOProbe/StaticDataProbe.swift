// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 staticdata 命令（docs/design-intel-translate.md 9.5 节）：打印数据文件的查找过程与来源、SDE 版本、
// 各类记录的数量、解码耗时，以及一次 15 跳跳数表的耗时。
// 跳数表在这里用 EVEStaticData.neighbors 做一次广度优先：正式的跳数规则（JumpGraph）归 WP-B，探针不依赖它。
// 只打印游戏的公开数据（数量与耗时），不读聊天日志。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// staticdata 命令的实现。
@MainActor enum StaticDataProbe {
    /// 跳数表的上限。
    static let jumpLimit = 15
    /// 计算跳数表的出发星系：Jita（30000142）。
    static let originID = 30_000_142

    /// 执行 staticdata 命令，返回进程退出码：读到数据为 0，缺失或无效为 1。
    static func run(_ args: [String]) async -> Int32 {
        guard args.isEmpty else { return Probe.usage() }
        let provider = BundleStaticDataProvider()
        print("查找顺序：")
        for candidate in provider.candidates() {
            let exists = FileManager.default.fileExists(atPath: candidate.url.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: candidate.url.path)[.size] as? Int) ?? nil
            print("  \(candidate.source)：\(exists ? "存在，\(size ?? 0) 字节" : "不存在")  \(candidate.url.path)")
        }
        let started = ContinuousClock.now
        let result = await provider.load()
        let loadMilliseconds = Probe.milliseconds(since: started)
        switch result {
        case .missing:
            print("结果：missing（没有任何数据文件）")
            return 1
        case .invalid(let error):
            print("结果：invalid（\(error)）")
            return 1
        case .loaded(let data, let source):
            print("结果：loaded，来源 \(source)，读取并解码耗时 \(loadMilliseconds) 毫秒")
            summarize(data)
            return 0
        }
    }

    /// 打印各类记录的数量与一次跳数表的耗时。
    private static func summarize(_ data: EVEStaticData) {
        let known = data.systems.filter { $0.kind == .known }.count
        let wormholes = data.systems.count - known
        let ships = data.ships.filter { $0.groupID != nil }.count
        let groups = data.ships.count - ships
        let jumpPairs = data.systems.reduce(0) { $0 + data.neighbors(of: $1.id).count } / 2
        print("SDE 版本 \(data.sdeBuild)")
        print("星系 \(data.systems.count)（已知空间 \(known)，虫洞 \(wormholes)），星门连接 \(jumpPairs) 对，"
              + "舰船 \(ships)，舰船分组 \(groups)")
        let localized = data.systems.filter { $0.localized["zh"] != nil }.count
        print("有中文译名的星系 \(localized) 个")
        guard let origin = data.system(id: originID) else {
            print("找不到出发星系 \(originID)，跳过跳数表")
            return
        }
        let started = ContinuousClock.now
        let table = distances(from: origin.id, limit: jumpLimit, data: data)
        print("从 \(origin.name) 出发的 \(jumpLimit) 跳跳数表：\(table.count) 个星系，"
              + "耗时 \(Probe.milliseconds(since: started)) 毫秒")
        if let named = data.system(named: "  jita* ") {
            print("system(named:) 自检：\(named.name)，显示安全等级 \(named.displaySecurity.map { String($0) } ?? "nil")")
        }
    }

    /// 广度优先：limit 跳以内每个星系的跳数，含出发星系（0）。
    private static func distances(from origin: Int, limit: Int, data: EVEStaticData) -> [Int: Int] {
        var table = [origin: 0]
        var frontier = [origin]
        for depth in 1...max(1, limit) {
            var next: [Int] = []
            for system in frontier {
                for neighbor in data.neighbors(of: system) where table[neighbor] == nil {
                    table[neighbor] = depth
                    next.append(neighbor)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return table
    }
}
