// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置的一致性测试：读 shared/fixtures/config/cases.json，逐个走「解码 → 迁移 → 校验 → 编码」，
// 与期望结果比较（docs/windows/architecture.md 5.4 节）。Windows 端的对应测试是
// windows/crates/eveo-core/tests/shared_config.rs。
// 期望里的 `<uuid>` 匹配任意大写 UUID，`<absent>` 表示这个键不应写出；`match` 为 subset 时只比较期望里出现的键。

import Foundation
import Testing
import EVEOPreviewCore

/// 与 Windows 版共用的配置用例。
struct SharedConfigFixtureTests {
    /// 读用例文件。本文件在 macos/Tests/EVEOPreviewCoreTests，往上 4 级是仓库根目录。
    private static func loadCases() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("shared").appendingPathComponent("fixtures")
            .appendingPathComponent("config").appendingPathComponent("cases.json")
        let data = try #require(try? Data(contentsOf: url), "找不到 \(url.path)")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object?["cases"] as? [[String: Any]], "cases.json 格式不对")
    }

    /// 用例的输入：`inputText` 是原始文字（用于不合法的 JSON），否则把 `input` 写成 JSON。
    private static func inputData(_ item: [String: Any]) throws -> Data {
        if let text = item["inputText"] as? String { return Data(text.utf8) }
        let input = try #require(item["input"], "用例缺 input")
        return try JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])
    }

    /// 是否是布尔值（JSONSerialization 把布尔值也读成 NSNumber）。
    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// 按期望比较实际的 JSON；`exact` 为真时对象的键必须完全相同。一致时返回 nil，否则返回出错位置与原因。
    private static func mismatch(_ expected: Any, _ actual: Any?, exact: Bool, path: String) -> String? {
        if let marker = expected as? String, marker == "<absent>" {
            return actual == nil ? nil : "\(path)：期望没有这个键"
        }
        guard let actual else { return "\(path)：缺少这个键" }
        if let marker = expected as? String, marker == "<uuid>" {
            guard let text = actual as? String, UUID(uuidString: text) != nil, text == text.uppercased() else {
                return "\(path)：不是大写的 UUID"
            }
            return nil
        }
        if let object = expected as? [String: Any] {
            guard let other = actual as? [String: Any] else { return "\(path)：期望对象" }
            if exact {
                let extra = other.keys.filter { object[$0] == nil }.sorted()
                if !extra.isEmpty { return "\(path)：多出的键 \(extra)" }
            }
            for key in object.keys.sorted() {
                if let found = mismatch(object[key] ?? NSNull(), other[key], exact: exact, path: "\(path).\(key)") {
                    return found
                }
            }
            return nil
        }
        if let list = expected as? [Any] {
            guard let other = actual as? [Any] else { return "\(path)：期望数组" }
            guard list.count == other.count else { return "\(path)：期望 \(list.count) 项，实际 \(other.count) 项" }
            for (index, pair) in zip(list, other).enumerated() {
                if let found = mismatch(pair.0, pair.1, exact: exact, path: "\(path)[\(index)]") { return found }
            }
            return nil
        }
        if let number = expected as? NSNumber {
            // 数字按数值比较（384 与 384.0 相同），布尔值只与布尔值相等。
            guard let other = actual as? NSNumber, isBool(number) == isBool(other),
                  number.doubleValue == other.doubleValue else { return "\(path)：期望 \(number)，实际 \(actual)" }
            return nil
        }
        if let text = expected as? String {
            return (actual as? String) == text ? nil : "\(path)：期望 \(text)，实际 \(actual)"
        }
        return expected is NSNull && actual is NSNull ? nil : "\(path)：类型不同"
    }

    /// 逐个用例比较。
    @Test func configCases() throws {
        let cases = try Self.loadCases()
        #expect(!cases.isEmpty)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let expected = try #require(item["expected"] as? [String: Any], "\(name)：缺 expected")
            let outcome = expected["outcome"] as? String
            let data = try Self.inputData(item)

            let decoded: (config: AppConfig, migratedFrom: Int?)
            do {
                decoded = try ConfigMigrator.decode(data)
            } catch {
                switch error {
                case .newerSchema(let found, _):
                    #expect(outcome == "newerSchema", "\(name)")
                    #expect((expected["found"] as? NSNumber)?.int64Value == Int64(found), "\(name)：found")
                case .encodingFailure:
                    #expect(outcome == "corrupt", "\(name)")
                case .ioFailure:
                    Issue.record("\(name)：不应出现读写错误")
                }
                continue
            }
            #expect(outcome == "ok", "\(name)")
            guard outcome == "ok" else { continue }

            let expectedMigration = (expected["migratedFrom"] as? NSNumber)?.intValue
            #expect(decoded.migratedFrom == expectedMigration, "\(name)：migratedFrom")
            let normalized = ConfigValidator.normalized(decoded.config)
            #expect(normalized.clamped == (expected["clamped"] as? [String] ?? []), "\(name)：clamped")

            let encoded = try JSONEncoder().encode(normalized.config)
            let actual = try JSONSerialization.jsonObject(with: encoded)
            let exact = (expected["match"] as? String) == "exact"
            let problem = Self.mismatch(expected["config"] ?? NSNull(), actual, exact: exact, path: "config")
            #expect(problem == nil, "\(name)：\(problem ?? "")")

            // 校验后的配置再校验一次应当不变（幂等）。
            let again = ConfigValidator.normalized(try ConfigMigrator.decode(encoded).config)
            #expect(again.clamped.isEmpty, "\(name)：第二次校验又改了 \(again.clamped)")
        }
    }
}
