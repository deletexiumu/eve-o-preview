// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的值类型的用例（docs/design-intel-translate.md 6.10 节、14.1 节）。名字都是虚构的。

import Foundation
import Testing
import EVEOPreviewCore

/// 比较键、缓存条目的编码与状态代号。
struct PilotLookupModelsTests {
    /// key(for:)：去掉首尾空白，连续的空白（含制表符与换行）并成一个空格，转成小写。
    @Test(arguments: [
        ("Brenn Ostvar", "brenn ostvar"),
        ("  Brenn   Ostvar  ", "brenn ostvar"),
        ("BRENN\tOSTVAR\n", "brenn ostvar"),
        ("Tyra  Kelloway Jr", "tyra kelloway jr"),
        ("Ölrik Ström", "ölrik ström"),
        ("x", "x"),
        ("   ", ""),
        ("", ""),
    ])
    func comparisonKey(_ name: String, _ expected: String) {
        #expect(PilotLookupAnswer.key(for: name) == expected)
    }

    /// 同一个名字的不同写法得到同一个键。
    @Test func keyIsStable() {
        let key = PilotLookupAnswer.key(for: "Brenn Ostvar")
        #expect(PilotLookupAnswer.key(for: " brenn  OSTVAR") == key)
        #expect(PilotLookupAnswer.key(for: key) == key)
    }

    /// PilotLookupAnswer 的错误额度默认是 nil。
    @Test func answerDefaults() {
        let answer = PilotLookupAnswer(outcomes: ["brenn ostvar": .matched(characterID: 90_000_001, name: "Brenn Ostvar")])
        #expect(answer.errorLimitRemain == nil && answer.errorLimitReset == nil)
        #expect(answer.outcomes["brenn ostvar"] == .matched(characterID: 90_000_001, name: "Brenn Ostvar"))
        #expect(PilotLookupAnswer(outcomes: [:], errorLimitRemain: 99, errorLimitReset: 30).errorLimitReset == 30)
    }

    /// PilotNameCacheEntry 往返一致，JSON 的键是 key、characterID、name、time（pilot-names.json 的格式）。
    @Test func cacheEntryRoundTrip() throws {
        let entry = PilotNameCacheEntry(key: "tyra kelloway", characterID: 2_100_000_042, name: "Tyra Kelloway",
                                        time: 1_795_000_000.5)
        let data = try JSONEncoder().encode([entry])
        #expect(try JSONDecoder().decode([PilotNameCacheEntry].self, from: data) == [entry])
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(Set(objects[0].keys) == ["key", "characterID", "name", "time"])
        #expect(objects[0]["characterID"] as? Int == 2_100_000_042)
    }

    /// PilotLookupStatus.code 的 4 个值；waiting 不带时刻。
    @Test func statusCodes() {
        #expect(PilotLookupStatus.off.code == "off")
        #expect(PilotLookupStatus.idle.code == "idle")
        #expect(PilotLookupStatus.resolving.code == "resolving")
        #expect(PilotLookupStatus.waiting(until: 1_795_000_060).code == "waiting")
        #expect(PilotLookupStatus.waiting(until: 1) != PilotLookupStatus.waiting(until: 2))
    }

    /// 失败的各种原因可以比较，关联值不同时不相等。
    @Test func failureEquality() {
        #expect(PilotLookupFailure.rateLimited(retryAfter: 60) == .rateLimited(retryAfter: 60))
        #expect(PilotLookupFailure.server(status: 503) != .server(status: 502))
        #expect(PilotLookupFailure.rejected(status: 400) != .server(status: 400))
        #expect(PilotLookupFailure.network("timeout") != .malformedAnswer)
    }
}
