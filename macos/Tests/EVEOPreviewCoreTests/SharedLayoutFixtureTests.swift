// SPDX-License-Identifier: GPL-3.0-or-later
//
// 布局的一致性测试：读 shared/fixtures/layout/cases.json，逐组断言（docs/windows/architecture.md 5.4 节）。
// Windows 端的对应测试是 windows/crates/eveo-core/tests/shared_layout.rs。
// 用例里矩形写成 [x, y, 宽, 高]，尺寸 [宽, 高]，点 [x, y]。

import Foundation
import Testing
import EVEOPreviewCore

/// 与 Windows 版共用的吸附、边缘判断、尺寸夹取、拉回屏幕、基准位置、放大与裁剪用例。
struct SharedLayoutFixtureTests {
    /// 一个用例：JSON 对象。
    private typealias Case = [String: Any]

    /// 读用例文件。本文件在 macos/Tests/EVEOPreviewCoreTests，往上 4 级是仓库根目录。
    private static func load() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("shared").appendingPathComponent("fixtures")
            .appendingPathComponent("layout").appendingPathComponent("cases.json")
        let data = try #require(try? Data(contentsOf: url), "找不到 \(url.path)")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "cases.json 格式不对")
    }

    /// 读一组用例，组不存在或为空时记一个问题。
    private static func group(_ all: [String: Any], _ key: String) -> [Case] {
        let cases = all[key] as? [Case] ?? []
        if cases.isEmpty { Issue.record("缺少 \(key)") }
        return cases
    }

    /// 数字；null 或缺失时为 nil。
    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// 数字数组。
    private static func numbers(_ value: Any?) -> [Double] {
        (value as? [NSNumber] ?? []).map(\.doubleValue)
    }

    /// [x, y, 宽, 高] → 矩形。
    private static func rect(_ value: Any?) -> ScreenRect {
        let n = numbers(value) + [0, 0, 0, 0]
        return ScreenRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// [宽, 高] → 尺寸。
    private static func size(_ value: Any?) -> ScreenSize {
        let n = numbers(value) + [0, 0]
        return ScreenSize(width: n[0], height: n[1])
    }

    /// [x, y] → 点。
    private static func point(_ value: Any?) -> ScreenPoint {
        let n = numbers(value) + [0, 0]
        return ScreenPoint(x: n[0], y: n[1])
    }

    /// 屏幕列表。
    private static func screens(_ value: Any?) -> [ScreenInfo] {
        (value as? [Case] ?? []).map { item in
            ScreenInfo(frame: rect(item["frame"]), visibleFrame: rect(item["visibleFrame"]),
                       scale: number(item["scale"]) ?? 1, isMain: item["isMain"] as? Bool ?? false)
        }
    }

    /// 吸附目标。
    private static func targets(_ value: Any?) -> SnapTargets {
        let item = value as? Case ?? [:]
        return SnapTargets(neighbors: (item["neighbors"] as? [Any] ?? []).map { rect($0) },
                           screens: (item["screens"] as? [Any] ?? []).map { rect($0) })
    }

    /// 边的名字列表 → 边集合。
    private static func edges(_ value: Any?) -> ResizeEdges {
        var result: ResizeEdges = []
        for name in value as? [String] ?? [] {
            switch name {
            case "left": result.insert(.left)
            case "right": result.insert(.right)
            case "top": result.insert(.top)
            case "bottom": result.insert(.bottom)
            default: Issue.record("不认识的边 \(name)")
            }
        }
        return result
    }

    /// 用例名。
    private static func name(_ item: Case) -> String {
        item["name"] as? String ?? "?"
    }

    /// 比较吸附结果。
    private static func checkSnap(_ item: Case, _ result: SnapResult) {
        let expected = item["expected"] as? Case ?? [:]
        #expect(result.rect == rect(expected["rect"]), "\(name(item))")
        #expect(result.snappedX == number(expected["snappedX"]), "\(name(item))：snappedX")
        #expect(result.snappedY == number(expected["snappedY"]), "\(name(item))：snappedY")
    }

    /// 移动吸附与缩放吸附。
    @Test func snapCases() throws {
        let all = try Self.load()
        for item in Self.group(all, "snapMove") {
            let result = SnapEngine.snapMove(proposed: Self.rect(item["proposed"]), targets: Self.targets(item["targets"]),
                                             threshold: Self.number(item["threshold"]) ?? 8)
            Self.checkSnap(item, result)
        }
        for item in Self.group(all, "snapResize") {
            let result = SnapEngine.snapResize(proposed: Self.rect(item["proposed"]),
                                               movingEdges: Self.edges(item["movingEdges"]),
                                               targets: Self.targets(item["targets"]),
                                               threshold: Self.number(item["threshold"]) ?? 8,
                                               minimum: Self.size(item["minimum"]), maximum: Self.size(item["maximum"]),
                                               aspectRatio: Self.number(item["aspectRatio"]))
            Self.checkSnap(item, result)
        }
    }

    /// 缩放边的判断与不带修饰键的边缘带。
    @Test func edgeCases() throws {
        let all = try Self.load()
        for item in Self.group(all, "resizeEdges") {
            let actual = SnapEngine.resizeEdges(at: Self.point(item["point"]), in: Self.rect(item["rect"]),
                                                margin: Self.number(item["margin"]) ?? 0)
            #expect(actual == Self.edges(item["expected"]), "\(Self.name(item))")
        }
        for item in Self.group(all, "edgeGrip") {
            let actual = EdgeGrip.edges(at: Self.point(item["point"]), in: Self.rect(item["rect"]))
            #expect(actual == Self.edges(item["expected"]), "\(Self.name(item))")
        }
    }

    /// 尺寸夹取、拉回屏幕、放大与裁剪。
    @Test func sizeAndScreenCases() throws {
        let all = try Self.load()
        for item in Self.group(all, "clampSize") {
            let actual = LayoutResolver.clampSize(Self.size(item["size"]), settings: ThumbnailSettings(),
                                                  aspectRatio: Self.number(item["aspectRatio"]))
            #expect(actual == Self.size(item["expected"]), "\(Self.name(item))")
        }
        for item in Self.group(all, "clampToScreens") {
            let actual = LayoutResolver.clampToScreens(Self.rect(item["rect"]), screens: Self.screens(item["screens"]),
                                                       minimumVisible: Self.number(item["minimumVisible"]) ?? 32)
            #expect(actual == Self.rect(item["expected"]), "\(Self.name(item))")
        }
        for item in Self.group(all, "zoom") {
            let anchor = try #require(ZoomAnchor(rawValue: item["anchor"] as? String ?? ""), "\(Self.name(item))")
            let actual = ZoomMath.zoomedFrame(base: Self.rect(item["base"]), factor: (item["factor"] as? Int) ?? 1,
                                              anchor: anchor)
            #expect(actual == Self.rect(item["expected"]), "\(Self.name(item))")
        }
        for item in Self.group(all, "crop") {
            let r = CaptureMath.contentsRect(sourceSize: Self.size(item["sourceSize"]),
                                             titleBarCropHeight: Self.number(item["cropHeight"]) ?? 0)
            #expect([r.x, r.y, r.width, r.height] == Self.numbers(item["expected"]), "\(Self.name(item))")
        }
    }

    /// 缩略图的基准 frame。
    @Test func resolveFrameCases() throws {
        let all = try Self.load()
        for item in Self.group(all, "resolveFrame") {
            let identityObject = item["identity"] as? Case ?? [:]
            let identity: ClientIdentity
            switch identityObject["kind"] as? String {
            case "character": identity = .character(identityObject["name"] as? String ?? "")
            case "login": identity = .login
            default: identity = .unknown
            }
            let client = EVEClient(id: WindowID(rawValue: 1), pid: 10, identity: identity,
                                   windowFrame: ScreenRect(x: 0, y: 33, width: 1728, height: 1018),
                                   isOnScreen: true, isMinimized: false)
            let layoutData = try JSONSerialization.data(withJSONObject: item["layouts"] ?? [String: Any]())
            let layouts = try JSONDecoder().decode([String: ThumbnailLayout].self, from: layoutData)
            let profile = Profile(name: "T", layouts: layouts)
            let occupied = (item["occupied"] as? [Any] ?? []).map { Self.rect($0) }
            let result = LayoutResolver.frame(for: client, loginIndex: item["loginIndex"] as? Int ?? 0,
                                              profile: profile, screens: Self.screens(item["screens"]),
                                              occupied: occupied)
            let expected = item["expected"] as? Case ?? [:]
            #expect(result.frame == Self.rect(expected["frame"]), "\(Self.name(item))")
            #expect(result.isAutoPlaced == (expected["isAutoPlaced"] as? Bool), "\(Self.name(item))")
        }
    }
}
