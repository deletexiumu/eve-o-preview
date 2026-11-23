// SPDX-License-Identifier: GPL-3.0-or-later
//
// 会话标记的编码与上一次运行的归类（v1.1 设计 6.1 节）。
//
// 归类规则，按顺序取第一个成立的：
//
// | 上一次的标记 | 上一个进程还在 | 结果 |
// | --- | --- | --- |
// | 没有，或 markerVersion 不是 1 | 任意 | noRecord |
// | endedCleanly 为真 | 任意 | clean |
// | endedCleanly 为假 | 是 | stillRunning |
// | endedCleanly 为假 | 否 | abnormal |
//
// 编码与 state.json 一致：日期是 ISO 8601 字符串（精确到秒），键按字母排序。
// 秒以下的部分在编码时丢掉；标记里的时刻只用来划定崩溃报告的时间窗口（前后各留 5 秒），不需要更精确。

import Foundation

/// 会话标记的规则。
public enum SessionMarkerRules {
    /// 当前的标记格式版本。
    public static let currentVersion = 1

    /// 解码 `session.json` 的内容。不是合法 JSON 或结构不符时返回 nil。
    ///
    /// 不检查 `markerVersion`：版本不认识的标记由 `outcome` 归为 `noRecord`。
    public static func decode(_ data: Data) -> SessionMarker? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMarker.self, from: data)
    }

    /// 编码会话标记，供原子写入 `session.json`。
    public static func encode(_ marker: SessionMarker) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 只含字符串、整数、布尔值与日期的结构体编码不会失败；万一失败，写一个空对象，下次读到时归为 noRecord。
        return (try? encoder.encode(marker)) ?? Data("{}".utf8)
    }

    /// 按 6.1 节的规则表归类上一次运行。
    ///
    /// - Parameters:
    ///   - previous: 上一次留下的标记；没有或读不懂时是 nil。
    ///   - isPreviousProcessAlive: 标记里的进程是否仍在运行，且是本应用（不是 PID 被复用的别的进程）。
    public static func outcome(previous: SessionMarker?, isPreviousProcessAlive: Bool) -> PreviousRunOutcome {
        guard let previous, previous.markerVersion == currentVersion else { return .noRecord }
        if previous.endedCleanly { return .clean }
        return isPreviousProcessAlive ? .stillRunning(previous) : .abnormal(previous)
    }
}
