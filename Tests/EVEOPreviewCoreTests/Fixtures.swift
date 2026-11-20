// SPDX-License-Identifier: GPL-3.0-or-later
//
// 测试用的样例数据。E6 窗口列表按 2026-11-20 在目标机器上实测的形态构造：
// 每个 EVE 进程有 1 个带标题的 1728×1018 主窗口，另有无标题的 1728×33 与 500×500 辅助窗口。

import Foundation
import EVEOPreviewCore

/// 测试共用的样例数据与构造函数。
enum Fixtures {
    // MARK: - 角色与进程

    /// 3 个在线角色的名字，含空格的名字用来检查按原文区分。
    static let pilotAlpha = "Pilot Alpha"
    static let pilotBravo = "bravo pilot"
    static let pilotCharlie = "charlie pilot"

    /// 3 个客户端进程的 PID。
    static let pidA: Int32 = 4101
    static let pidB: Int32 = 4188
    static let pidC: Int32 = 4252

    /// 主窗口尺寸（点）。
    static let mainWindowSize = ScreenSize(width: 1728, height: 1018)

    // MARK: - E6 窗口列表

    /// E6 的真实窗口列表：3 个进程共 16 个 layer 0 窗口，只有 3 个是主窗口。
    /// 辅助窗口的 ID 有的比主窗口小，用来确认选择规则不是简单地取最小 ID。
    static let e6Windows: [WindowInfo] = [
        // 进程 A：主窗口加 3 个 1728×33 与 1 个 500×500 辅助窗口。
        window(9001, pidA, nil, x: 0, y: 33, w: 1728, h: 33),
        window(9002, pidA, "EVE - \(pilotAlpha)", x: 0, y: 33, w: 1728, h: 1018),
        window(9003, pidA, nil, x: 0, y: 1018, w: 1728, h: 33),
        window(9004, pidA, nil, x: 614, y: 292, w: 500, h: 500),
        window(9005, pidA, nil, x: 0, y: 0, w: 1728, h: 33),
        // 进程 B：主窗口加 3 个 1728×33 与 2 个 500×500 辅助窗口。
        window(9101, pidB, nil, x: 40, y: 60, w: 500, h: 500),
        window(9102, pidB, nil, x: 40, y: 60, w: 1728, h: 33),
        window(9103, pidB, "EVE - \(pilotBravo)", x: 40, y: 60, w: 1728, h: 1018),
        window(9104, pidB, nil, x: 40, y: 1045, w: 1728, h: 33),
        window(9105, pidB, nil, x: 300, y: 300, w: 500, h: 500),
        window(9106, pidB, nil, x: 40, y: 27, w: 1728, h: 33),
        // 进程 C：主窗口加 3 个 1728×33 与 1 个 500×500 辅助窗口。
        window(9201, pidC, "EVE - \(pilotCharlie)", x: 80, y: 90, w: 1728, h: 1018),
        window(9202, pidC, nil, x: 80, y: 90, w: 1728, h: 33),
        window(9203, pidC, nil, x: 80, y: 1075, w: 1728, h: 33),
        window(9204, pidC, nil, x: 694, y: 349, w: 500, h: 500),
        window(9205, pidC, nil, x: 80, y: 57, w: 1728, h: 33),
    ]

    /// 构造一个候选窗口，默认在屏、最小化状态未知。
    static func window(_ id: UInt32, _ pid: Int32, _ title: String?, x: Double, y: Double, w: Double, h: Double,
                       onScreen: Bool = true, minimized: Bool? = nil) -> WindowInfo {
        WindowInfo(windowID: WindowID(rawValue: id), pid: pid, title: title,
                   frame: ScreenRect(x: x, y: y, width: w, height: h), isOnScreen: onScreen, isMinimized: minimized)
    }

    // MARK: - 客户端

    /// 构造一个客户端，主窗口默认是 1728×1018。
    static func client(_ id: UInt32, pid: Int32, _ identity: ClientIdentity,
                       frame: ScreenRect = ScreenRect(x: 0, y: 33, width: 1728, height: 1018),
                       minimized: Bool? = false) -> EVEClient {
        EVEClient(id: WindowID(rawValue: id), pid: pid, identity: identity, windowFrame: frame,
                  isOnScreen: true, isMinimized: minimized)
    }

    /// 构造一个角色客户端。
    static func character(_ name: String, id: UInt32, pid: Int32) -> EVEClient {
        client(id, pid: pid, .character(name))
    }

    // MARK: - 屏幕

    /// 主屏：1728×1117 点，Retina（scale 2），菜单栏高 33 点。
    static let mainScreen = ScreenInfo(
        frame: ScreenRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: ScreenRect(x: 0, y: 33, width: 1728, height: 1084),
        scale: 2, isMain: true)

    /// 副屏：在主屏左侧，x 为负数，1920×1080 点，scale 1。
    static let leftScreen = ScreenInfo(
        frame: ScreenRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: ScreenRect(x: -1920, y: 0, width: 1920, height: 1080),
        scale: 1, isMain: false)

    // MARK: - 规划器

    /// 默认的规划器输入：前台是其他应用，权限齐全，捕获都在运行，只有主屏。
    /// screens 可改成多屏，用来检查 scale 与「所在屏幕」的取法。
    static func plannerInput(clients: [EVEClient], profile: Profile = Profile(name: "Test"),
                             frontmost: FrontmostContext = .other, session: SessionState = SessionState(),
                             permissions: PermissionStatus = .granted,
                             captureStates: [WindowID: CaptureState]? = nil, now: Double = 100,
                             screens: [ScreenInfo] = [mainScreen]) -> PlannerInput {
        let states = captureStates ?? Dictionary(uniqueKeysWithValues: clients.map { ($0.id, CaptureState.running) })
        return PlannerInput(clients: clients, frontmost: frontmost, profile: profile, session: session,
                            screens: screens, permissions: permissions, captureStates: states, now: now)
    }
}
