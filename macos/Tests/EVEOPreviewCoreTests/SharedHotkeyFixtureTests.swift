// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键的一致性测试：读 shared/fixtures/hotkey/cases.json，逐组断言（docs/windows/architecture.md 5.4 节）。
// Windows 端的对应测试是 windows/crates/eveo-core/tests/shared_hotkey.rs。
// 期望值是一个对象且带 `macos`、`windows` 两个键时，两端的结果不同，这里取 `macos`。

import Foundation
import Testing
import EVEOPreviewCore

/// 与 Windows 版共用的热键解析、规划、鼠标热键匹配与一次性默认值用例。
struct SharedHotkeyFixtureTests {
    /// 一个用例：JSON 对象。
    private typealias Case = [String: Any]

    /// 读用例文件。本文件在 macos/Tests/EVEOPreviewCoreTests，往上 4 级是仓库根目录。
    private static func load() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("shared").appendingPathComponent("fixtures")
            .appendingPathComponent("hotkey").appendingPathComponent("cases.json")
        let data = try #require(try? Data(contentsOf: url), "找不到 \(url.path)")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "cases.json 格式不对")
    }

    /// 读一组用例，组不存在或为空时记一个问题。
    private static func group(_ all: [String: Any], _ key: String) -> [Case] {
        let cases = all[key] as? [Case] ?? []
        if cases.isEmpty { Issue.record("缺少 \(key)") }
        return cases
    }

    /// 本平台的期望值：分平台写的取 `macos`，否则原样。
    private static func expected(_ value: Any?) -> Any? {
        if let object = value as? [String: Any], object.keys.contains("macos"), object.keys.contains("windows") {
            return object["macos"]
        }
        return value
    }

    /// 用例的名字。
    private static func name(_ item: Case) -> String {
        item["name"] as? String ?? "?"
    }

    /// 把一个 JSON 对象解码成 Codable 值。
    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 动作写成用例里的字符串。
    private static func actionName(_ action: HotkeyAction) -> String {
        switch action {
        case .cycle(let groupID, let direction):
            return "cycle:\(groupID):\(direction == .forward ? "forward" : "backward")"
        case .activateCharacter(let name): return "character:\(name)"
        case .cycleLoginClients: return "cycleLoginClients"
        case .toggleHideAll: return "toggleHideAll"
        case .minimizeAll: return "minimizeAll"
        }
    }

    /// 拒绝原因写成用例里的字符串。
    private static func reasonName(_ reason: HotkeyRejection) -> String {
        switch reason {
        case .missingModifier: return "missingModifier"
        case .systemReserved: return "systemReserved"
        }
    }

    /// 规划结果写成与用例相同的形状，便于整体比较。
    private static func planObject(_ plan: HotkeyPlan) -> NSDictionary {
        let bindings: [[String: Any]] = plan.bindings.map {
            ["id": Int($0.id), "hotkey": $0.hotkey.stringValue(), "action": actionName($0.action),
             "scope": $0.scope.rawValue]
        }
        let issues: [[String: Any]] = plan.issues.map { issue in
            switch issue {
            case .unparsable(let text, let action):
                return ["kind": "unparsable", "text": text, "action": actionName(action)]
            case .duplicate(let hotkey, let kept, let dropped):
                return ["kind": "duplicate", "hotkey": hotkey.stringValue(), "kept": actionName(kept),
                        "dropped": actionName(dropped)]
            case .rejected(let hotkey, let action, let reason):
                return ["kind": "rejected", "hotkey": hotkey.stringValue(), "action": actionName(action),
                        "reason": reasonName(reason)]
            }
        }
        return ["bindings": bindings, "issues": issues] as NSDictionary
    }

    /// 解析：规范写法或解析失败，规范写法能解析回同一个结果。
    @Test func parse() throws {
        for item in Self.group(try Self.load(), "parse") {
            let input = item["input"] as? String ?? ""
            let got = HotkeySpec(string: input)?.stringValue()
            let want = Self.expected(item["expect"]) as? String
            #expect(got == want, "\(Self.name(item))：\(input.debugDescription)")
            if let got {
                #expect(HotkeySpec(string: got)?.stringValue() == got, "\(Self.name(item))")
            }
        }
    }

    /// 规划：绑定与问题。
    @Test func plan() throws {
        for item in Self.group(try Self.load(), "plan") {
            let profile = try Self.decode(Profile.self, item["profile"])
            let got = Self.planObject(HotkeyPlanner.plan(for: profile))
            let want = Self.expected(item["expect"]) as? NSDictionary
            #expect(want != nil && got.isEqual(want), "\(Self.name(item))：得到 \(got)")
        }
    }

    /// 用例里的热键字符串 → 按钮号与修饰键。
    private static func mouse(_ value: Any?) -> (button: Int, modifiers: HotkeyModifiers)? {
        guard let text = value as? String, let hotkey = HotkeySpec(string: text)?.hotkey,
              let button = hotkey.mouseButton else { return nil }
        return (button, hotkey.modifiers)
    }

    /// 鼠标匹配器：逐步执行并核对决定、截止时刻与监听状态。
    @Test func mouseMatcher() throws {
        for item in Self.group(try Self.load(), "mouseMatcher") {
            var matcher = MouseHotkeyMatcher()
            for (index, step) in (item["steps"] as? [Case] ?? []).enumerated() {
                let at = "\(Self.name(item)) 第 \(index + 1) 步"
                switch step["op"] as? String {
                case "bindings":
                    let bindings = (step["bindings"] as? [Case] ?? []).compactMap { entry -> MouseHotkeyMatcher.Binding? in
                        guard let id = (entry["id"] as? NSNumber)?.uint32Value, let parsed = Self.mouse(entry["hotkey"]),
                              let scope = (entry["scope"] as? String).flatMap(HotkeyScope.init(rawValue:)) else {
                            Issue.record("\(at)：绑定格式不对")
                            return nil
                        }
                        return .init(id: id, button: parsed.button, modifiers: parsed.modifiers, scope: scope)
                    }
                    matcher.replaceBindings(bindings)
                case "frontmost": matcher.setGameFrontmost(step["value"] as? Bool ?? false)
                case "suspended": matcher.setSuspended(step["value"] as? Bool ?? false)
                case "hookRemoved": matcher.tapWasDisabled()
                case "refresh":
                    let now = (step["now"] as? NSNumber)?.doubleValue ?? 0
                    let got = matcher.refreshReleaseDeadline(now: now)
                    #expect(got == (step["expect"] as? NSNumber)?.doubleValue, "\(at)")
                case "check":
                    #expect(matcher.shouldListen == step["shouldListen"] as? Bool, "\(at)")
                    #expect(matcher.hasActiveBinding == step["hasActiveBinding"] as? Bool, "\(at)")
                case let op?:
                    let kinds: [String: MouseButtonEventKind] = ["down": .down, "up": .up, "dragged": .dragged]
                    guard let kind = kinds[op], let parsed = Self.mouse(step["hotkey"]) else {
                        Issue.record("\(at)：不认识的步骤 \(op)")
                        continue
                    }
                    let got: String
                    switch matcher.handle(kind, button: parsed.button, modifiers: parsed.modifiers) {
                    case .pass: got = "pass"
                    case .swallow: got = "swallow"
                    case .fire(let id): got = "fire:\(id)"
                    }
                    #expect(got == step["expect"] as? String, "\(at)")
                case nil:
                    Issue.record("\(at)：缺少 op")
                }
            }
        }
    }

    /// 一次性默认值：待补的项与补后的结果。
    @Test func oneTimeDefaults() throws {
        let groups = try Self.load()["oneTimeDefaults"] as? [String: Any] ?? [:]
        for item in Self.group(groups, "pending") {
            let got = OneTimeDefaults.pending(applied: item["applied"] as? [String] ?? [])
            #expect(got == item["expect"] as? [String], "\(Self.name(item))")
        }
        for item in Self.group(groups, "apply") {
            let profiles = try Self.decode([Profile].self, item["profiles"])
            let config = AppConfig(activeProfileID: profiles.first?.id ?? "", profiles: profiles)
            let result = OneTimeDefaults.apply(item["ids"] as? [String] ?? [], to: config)
            let want = Self.expected(item["expect"]) as? [Case] ?? []
            #expect(result.profiles.count == want.count, "\(Self.name(item))")
            for (profile, expectation) in zip(result.profiles, want) {
                let at = "\(Self.name(item)) / \(profile.id)"
                #expect(profile.hotkeys.toggleHideAll == expectation["toggleHideAll"] as? [String], "\(at)")
                if let enabled = expectation["highlightEnabled"] as? Bool {
                    #expect(profile.overlay.highlightEnabled == enabled, "\(at)")
                }
                if let color = expectation["highlightColor"] as? String {
                    #expect(profile.overlay.highlightColor == color, "\(at)")
                }
            }
        }
    }
}
