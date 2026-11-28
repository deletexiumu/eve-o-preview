// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图规划的一致性测试：读 shared/fixtures/planner/cases.json，逐例断言（docs/windows/architecture.md 5.4 节）。
// Windows 端的对应测试是 windows/crates/eveo-core/tests/shared_planner.rs。
// 每个呈现只比较用例里写出的字段；`visible` 对应这里要捕获的窗口（Windows 是要保持注册的 DWM 缩略图）。
// 两端画面的来源不同，用例里的画面都按正常处理：这里给全部权限，全部窗口的捕获都在出帧。

import Foundation
import Testing
import EVEOPreviewCore

/// 与 Windows 版共用的布局两遍定位、可见性、外观、提醒与定时重算用例。
struct SharedPlannerFixtureTests {
    /// 一个用例：JSON 对象。
    private typealias Case = [String: Any]

    /// 读用例文件。本文件在 macos/Tests/EVEOPreviewCoreTests，往上 4 级是仓库根目录。
    private static func load() throws -> [Case] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("shared").appendingPathComponent("fixtures")
            .appendingPathComponent("planner").appendingPathComponent("cases.json")
        let data = try #require(try? Data(contentsOf: url), "找不到 \(url.path)")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "cases.json 格式不对")
        let cases = object["cases"] as? [Case] ?? []
        #expect(!cases.isEmpty, "缺少 cases")
        return cases
    }

    /// [x, y, 宽, 高] → 矩形。
    private static func rect(_ value: Any?) -> ScreenRect {
        let n = (value as? [NSNumber] ?? []).map(\.doubleValue) + [0, 0, 0, 0]
        return ScreenRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// 窗口编号。
    private static func window(_ value: Any?) -> WindowID {
        WindowID(rawValue: (value as? NSNumber)?.uint32Value ?? 0)
    }

    /// 客户端。
    private static func client(_ item: Case) -> EVEClient {
        let identity = item["identity"] as? Case ?? [:]
        let parsed: ClientIdentity
        switch identity["kind"] as? String {
        case "character": parsed = .character(identity["name"] as? String ?? "")
        case "login": parsed = .login
        default: parsed = .unknown
        }
        return EVEClient(id: window(item["id"]), pid: (item["pid"] as? NSNumber)?.int32Value ?? 0, identity: parsed,
                         windowFrame: rect(item["frame"]), isOnScreen: true,
                         isMinimized: item["isMinimized"] as? Bool ?? false, isFullScreen: item["isFullScreen"] as? Bool)
    }

    /// 前台：`{"client": pid}`、`"selfApp"` 或 `"other"`。
    private static func frontmost(_ value: Any?) -> FrontmostContext {
        if let object = value as? Case, let pid = (object["client"] as? NSNumber)?.int32Value { return .client(pid: pid) }
        return value as? String == "selfApp" ? .selfApp : .other
    }

    /// 会话状态，缺的键取默认值。
    private static func session(_ item: Case) -> SessionState {
        var alerts: [WindowID: CombatAlertWindow] = [:]
        for (key, value) in item["combatAlerts"] as? Case ?? [:] {
            let alert = value as? Case ?? [:]
            alerts[WindowID(rawValue: UInt32(key) ?? 0)] = CombatAlertWindow(
                startedAt: (alert["startedAt"] as? NSNumber)?.doubleValue ?? 0,
                until: (alert["until"] as? NSNumber)?.doubleValue ?? 0)
        }
        return SessionState(
            hideAll: item["hideAll"] as? Bool ?? false,
            skippedCharacters: Set(item["skippedCharacters"] as? [String] ?? []),
            hoveredWindow: item["hoveredWindow"].map { window($0) },
            interactingWindows: Set((item["interactingWindows"] as? [Any] ?? []).map { window($0) }),
            lastEVEContextAt: (item["lastEVEContextAt"] as? NSNumber)?.doubleValue ?? 0,
            lastActivePID: (item["lastActivePID"] as? NSNumber)?.int32Value,
            combatAlerts: alerts)
    }

    /// 呈现写成用例里的字段；nil 写成 NSNull。
    private static func fields(_ p: ThumbnailPresentation) -> [String: Any] {
        let placeholder: String
        switch p.placeholder {
        case .none: placeholder = "none"
        case .minimized: placeholder = "minimized"
        case .waitingForFrame: placeholder = "waitingForFrame"
        case .needsScreenRecording: placeholder = "needsScreenRecording"
        case .captureStopped: placeholder = "captureStopped"
        }
        let alert: Any = p.alert.map { ["color": $0.color, "style": $0.style.rawValue] as [String: Any] } ?? NSNull()
        return [
            "frame": [p.frame.x, p.frame.y, p.frame.width, p.frame.height], "isVisible": p.isVisible,
            "title": p.title, "showsTitle": p.showsTitle, "titleFontSize": p.titleFontSize,
            "titleColor": p.titleColor, "opacity": p.opacity,
            "highlightColor": p.highlightColor ?? NSNull(), "highlightThickness": p.highlightThickness,
            "borderColor": p.borderColor ?? NSNull(), "borderThickness": p.borderThickness, "alert": alert,
            "isActive": p.isActive, "isLocked": p.isLocked, "isSkipped": p.isSkipped, "isAlwaysOnTop": p.isAlwaysOnTop,
            "isOverFullScreen": p.isOverFullScreen, "isZoomed": p.isZoomed, "placeholder": placeholder,
        ]
    }

    /// 两个 JSON 值相等，数字按数值比较。
    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        (lhs as AnyObject?)?.isEqual(rhs) ?? (rhs == nil)
    }

    /// 逐例规划并核对写出的字段。
    @Test func plannerCases() throws {
        for item in try Self.load() {
            let name = item["name"] as? String ?? "?"
            let clients = (item["clients"] as? [Case] ?? []).map { Self.client($0) }
            let profileData = try JSONSerialization.data(withJSONObject: item["profile"] ?? [String: Any]())
            let profile = try JSONDecoder().decode(Profile.self, from: profileData)
            let screens = (item["screens"] as? [Case] ?? []).map { screen in
                ScreenInfo(frame: Self.rect(screen["frame"]), visibleFrame: Self.rect(screen["visibleFrame"]),
                           scale: (screen["scale"] as? NSNumber)?.doubleValue ?? 1,
                           isMain: screen["isMain"] as? Bool ?? false)
            }
            let states = Dictionary(uniqueKeysWithValues: clients.map { ($0.id, CaptureState.running) })
            let input = PlannerInput(clients: clients, frontmost: Self.frontmost(item["frontmost"]), profile: profile,
                                     session: Self.session(item["session"] as? Case ?? [:]), screens: screens,
                                     permissions: .granted, captureStates: states,
                                     now: (item["now"] as? NSNumber)?.doubleValue ?? 0)
            let plan = ThumbnailPlanner.plan(input)
            let expect = item["expect"] as? Case ?? [:]
            let wanted = expect["presentations"] as? [Case] ?? []
            #expect(plan.presentations.count == wanted.count, "\(name)")
            for (index, (got, want)) in zip(plan.presentations, wanted).enumerated() {
                let actual = Self.fields(got)
                for (key, value) in want {
                    #expect(Self.same(actual[key], value), "\(name) 第 \(index + 1) 个 \(key)：得到 \(actual[key] ?? "nil")")
                }
            }
            if let layouts = expect["layoutsToPersist"] {
                let data = try JSONEncoder().encode(plan.layoutsToPersist)
                let actual = try JSONSerialization.jsonObject(with: data)
                #expect(Self.same(actual, layouts), "\(name) layoutsToPersist：得到 \(actual)")
            }
            if let visible = expect["visible"] {
                let actual = clients.filter { plan.captures[$0.id] != nil }.map { Int($0.id.rawValue) }
                #expect(Self.same(actual, visible), "\(name) visible：得到 \(actual)")
            }
            if let wake = expect["nextWakeAt"] {
                let actual: Any = plan.nextWakeAt.map { $0 as Any } ?? NSNull()
                #expect(Self.same(actual, wake),"\(name) nextWakeAt：得到 \(String(describing: plan.nextWakeAt))")
            }
        }
    }
}
