// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一致性测试：读 shared/fixtures 里与 Windows 版共用的用例，逐个断言（docs/windows/architecture.md 5.4 节）。
// Windows 端的对应测试是 windows/crates/eveo-core/tests/shared_fixtures.rs。
// 改规则时先改用例，两端的这组测试会同时提醒另一端跟上。

import Foundation
import Testing
import EVEOPreviewCore

/// 与 Windows 版共用的标题、循环、主窗口挑选用例。
struct SharedFixtureTests {
    /// 读 shared/fixtures 下的一个 JSON 文件。本文件在 macos/Tests/EVEOPreviewCoreTests，往上 4 级是仓库根目录。
    private static func load<T: Decodable>(_ relative: String, as type: T.Type) throws -> T {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("shared").appendingPathComponent("fixtures")
            .appendingPathComponent(relative)
        let data = try #require(try? Data(contentsOf: url), "找不到 \(url.path)")
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// JSON 里的方向写法换成 `CycleDirection`。
    private static func direction(_ raw: String) throws -> CycleDirection {
        switch raw {
        case "forward": return .forward
        case "backward": return .backward
        default: throw FixtureError.unknownValue(raw)
        }
    }

    /// 用例里出现了不认识的取值。
    private enum FixtureError: Error {
        case unknownValue(String)
    }

    // MARK: - 标题

    /// title/cases.json 的顶层。
    private struct TitleFile: Decodable {
        let cases: [TitleCase]
    }

    /// 一个标题用例：标题与 PID，期望的身份与显示标题。
    private struct TitleCase: Decodable {
        let name: String
        let title: String?
        let pid: Int32
        let expected: Expected

        /// `kind` 是 character、login 或 unknown；只有 character 带 `name`。
        struct Expected: Decodable {
            let kind: String
            let name: String?
            let displayTitle: String
        }
    }

    /// 窗口标题 → 身份与显示标题。
    @Test func titleCases() throws {
        let file = try Self.load("title/cases.json", as: TitleFile.self)
        #expect(!file.cases.isEmpty)
        for item in file.cases {
            let expected: ClientIdentity
            switch item.expected.kind {
            case "character": expected = .character(try #require(item.expected.name))
            case "login": expected = .login
            case "unknown": expected = .unknown
            default: throw FixtureError.unknownValue(item.expected.kind)
            }
            let actual = TitleParser.identity(fromTitle: item.title)
            #expect(actual == expected, "\(item.name)")
            #expect(TitleParser.title(for: actual, pid: item.pid) == item.expected.displayTitle, "\(item.name)")
        }
    }

    // MARK: - 循环

    /// cycle/cases.json 的顶层：循环组与登录客户端两组。
    private struct CycleFile: Decodable {
        let group: [GroupCase]
        let login: [LoginCase]
    }

    /// 一个循环组用例。
    private struct GroupCase: Decodable {
        let name: String
        let members: [String]
        let direction: String
        let active: String?
        let running: [String]
        let skipped: [String]
        let expected: String?
    }

    /// 一个登录客户端循环用例。
    private struct LoginCase: Decodable {
        let name: String
        let pids: [Int32]
        let activePID: Int32?
        let direction: String
        let expected: Int32?
    }

    /// 循环组与登录客户端的下一个目标。
    @Test func cycleCases() throws {
        let file = try Self.load("cycle/cases.json", as: CycleFile.self)
        #expect(!file.group.isEmpty && !file.login.isEmpty)
        for item in file.group {
            let actual = CycleEngine.next(in: item.members, direction: try Self.direction(item.direction),
                                          active: item.active, running: Set(item.running),
                                          skipped: Set(item.skipped))
            #expect(actual == item.expected, "\(item.name)")
        }
        for item in file.login {
            let actual = CycleEngine.nextLoginClient(pids: item.pids, activePID: item.activePID,
                                                     direction: try Self.direction(item.direction))
            #expect(actual == item.expected, "\(item.name)")
        }
    }

    // MARK: - 主窗口挑选

    /// clients/main-windows.json 的顶层。
    private struct SelectorFile: Decodable {
        let cases: [SelectorCase]
    }

    /// 一个主窗口挑选用例：候选窗口与期望选出的窗口 ID（按 PID 升序）。
    private struct SelectorCase: Decodable {
        let name: String
        let windows: [FixtureWindow]
        let expected: [UInt32]
    }

    /// 用例里的一个候选窗口；`title` 为 nil 表示读不到标题。
    private struct FixtureWindow: Decodable {
        let id: UInt32
        let pid: Int32
        let title: String?
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        /// 换成 Core 的候选窗口，默认在屏、最小化状态未知。
        var windowInfo: WindowInfo {
            WindowInfo(windowID: WindowID(rawValue: id), pid: pid, title: title,
                       frame: ScreenRect(x: x, y: y, width: width, height: height),
                       isOnScreen: true, isMinimized: nil)
        }
    }

    /// 一批候选窗口 → 每个进程的主窗口。
    @Test func mainWindowCases() throws {
        let file = try Self.load("clients/main-windows.json", as: SelectorFile.self)
        #expect(!file.cases.isEmpty)
        for item in file.cases {
            let selected = ClientWindowSelector.mainWindows(from: item.windows.map(\.windowInfo))
            #expect(selected.map(\.windowID.rawValue) == item.expected, "\(item.name)")
        }
    }
}
