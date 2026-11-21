// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警缓冲的测试（docs/design-intel-translate.md 6.5 节、14.1 节）。收听者与说话人都是虚构的。

import Testing
import Foundation
@testable import EVEOPreviewCore

/// 测试里建消息的辅助。
enum IntelTestMessages {
    /// 一条预警频道的消息。
    static func message(_ text: String, listener: String = "Kael Doran", time: Double = 1_000,
                        speaker: String = "Mira Voss", isBackfill: Bool = false) -> ChatMessage {
        ChatMessage(listener: listener, channelID: "player_00", channelName: "intel.Demo", time: time,
                    speaker: speaker, text: text, isBackfill: isBackfill)
    }
}

@Suite struct IntelFeedTests {
    /// 按收听者分开；编号从 1 起递增。
    @Test func separatesListeners() {
        var feed = IntelFeed()
        let first = feed.append(IntelTestMessages.message("a", listener: "Kael Doran"), report: .plain("a"))
        let second = feed.append(IntelTestMessages.message("b", listener: "Mira Voss"), report: .plain("b"))
        #expect(first == 1 && second == 2)
        #expect(feed.items(for: "Kael Doran").map(\.message.text) == ["a"])
        #expect(feed.items(for: "Mira Voss").map(\.message.text) == ["b"])
        #expect(feed.items(for: "Tarn Vex").isEmpty)
    }

    /// 收听者先原样比较，再不区分大小写比较。
    @Test func caseInsensitiveFallback() {
        var feed = IntelFeed()
        feed.append(IntelTestMessages.message("a", listener: "Kael Doran"), report: .plain("a"))
        feed.append(IntelTestMessages.message("b", listener: "KAEL DORAN"), report: .plain("b"))
        // 第二条找到了原样不同、不区分大小写相同的键，放进同一份。
        #expect(feed.items(for: "kael doran").count == 2)
        let removed = feed.removeItems(for: "kael DORAN")
        #expect(removed)
        #expect(feed.count == 0)
    }

    /// 超过容量时丢最早的。
    @Test func capacity() {
        var feed = IntelFeed()
        for index in 0..<(IntelFeed.capacityPerCharacter + 5) {
            feed.append(IntelTestMessages.message("\(index)", time: Double(index)), report: .plain("\(index)"))
        }
        let items = feed.items(for: "Kael Doran")
        #expect(items.count == IntelFeed.capacityPerCharacter)
        #expect(items.first?.message.text == "5")
    }

    /// 按到达顺序排列：晚到的较早消息追加在末尾，已有条目的位置与编号不变（浮窗按编号对齐行，只追加不重排）。
    @Test func keepsArrivalOrder() {
        var feed = IntelFeed()
        let late = feed.append(IntelTestMessages.message("late", time: 200), report: .plain("late"))
        let early = feed.append(IntelTestMessages.message("early", time: 100), report: .plain("early"))
        feed.append(IntelTestMessages.message("same", time: 200), report: .plain("same"))
        let items = feed.items(for: "Kael Doran")
        #expect(items.map(\.message.text) == ["late", "early", "same"])
        #expect(items.map(\.id).prefix(2) == [late, early])
        // prune 仍按时间丢：早于 cutoff 的那条去掉，其余顺序不变。
        feed.prune(olderThan: 150)
        #expect(feed.items(for: "Kael Doran").map(\.message.text) == ["late", "same"])
    }

    /// prune 丢掉早于 cutoff 的消息，返回有没有丢。
    @Test func prune() {
        var feed = IntelFeed()
        feed.append(IntelTestMessages.message("old", time: 10), report: .plain("old"))
        feed.append(IntelTestMessages.message("new", time: 100), report: .plain("new"))
        let first = feed.prune(olderThan: 50)
        #expect(first)
        #expect(feed.items(for: "Kael Doran").map(\.message.text) == ["new"])
        let again = feed.prune(olderThan: 50)
        #expect(!again)
        let all = feed.prune(olderThan: 1_000)
        #expect(all)
        #expect(feed.count == 0)
    }

    /// reparse 换掉解析结果，编号不变；removeAll 清空全部。
    @Test func reparseAndRemoveAll() {
        var feed = IntelFeed()
        let id = feed.append(IntelTestMessages.message("Jita"), report: .plain("Jita"))
        feed.reparse { _ in IntelReport(segments: [], systemIDs: [1]) }
        #expect(feed.items(for: "Kael Doran").first?.id == id)
        #expect(feed.items(for: "Kael Doran").first?.report.isIntelLike == true)
        feed.removeAll()
        #expect(feed.count == 0)
        let next = feed.append(IntelTestMessages.message("x"), report: .plain("x"))
        #expect(next == id + 1)
    }
}
