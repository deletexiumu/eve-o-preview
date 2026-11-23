// SPDX-License-Identifier: GPL-3.0-or-later
//
// ClientWindowSelector 的用例（架构文档 5.3 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 主窗口选择：E6 真实列表、无标题按尺寸、全是小窗口、并列取舍。
struct ClientWindowSelectorTests {
    /// E6 的 16 个窗口里选出 3 个带标题的主窗口，按 PID 升序。
    @Test func e6ListSelectsThreeMainWindows() {
        let selected = ClientWindowSelector.mainWindows(from: Fixtures.e6Windows)
        #expect(selected.map(\.windowID.rawValue) == [9002, 9103, 9201])
        #expect(selected.map(\.pid) == [Fixtures.pidA, Fixtures.pidB, Fixtures.pidC])
        #expect(selected.allSatisfy { $0.frame.size == Fixtures.mainWindowSize })
    }

    /// 输入顺序打乱后结果不变。
    @Test func orderIndependent() {
        let selected = ClientWindowSelector.mainWindows(from: Fixtures.e6Windows.reversed())
        #expect(selected.map(\.windowID.rawValue) == [9002, 9103, 9201])
    }

    /// 没有权限时标题全为 nil：按尺寸选出 1728×1018，排除 500×500（面积大于 640×360 但宽度不够）。
    @Test func untitledFallsBackToSize() {
        let untitled = Fixtures.e6Windows.map { window -> WindowInfo in
            var copy = window
            copy.title = nil
            return copy
        }
        let selected = ClientWindowSelector.mainWindows(from: untitled)
        #expect(selected.map(\.windowID.rawValue) == [9002, 9103, 9201])
    }

    /// 某个进程只有小窗口时，该进程本轮不产生客户端。
    @Test func allSmallWindowsProduceNothing() {
        let windows = [
            Fixtures.window(1, 10, nil, x: 0, y: 0, w: 1728, h: 33),
            Fixtures.window(2, 10, nil, x: 0, y: 0, w: 500, h: 500),
            Fixtures.window(3, 10, nil, x: 0, y: 0, w: 639, h: 2000),
        ]
        #expect(ClientWindowSelector.mainWindows(from: windows).isEmpty)
    }

    /// 恰好 640×360 的无标题窗口可以作为主窗口。
    @Test func exactMinimumSizeAccepted() {
        let windows = [Fixtures.window(5, 10, nil, x: 0, y: 0, w: 640, h: 360)]
        #expect(ClientWindowSelector.mainWindows(from: windows).map(\.windowID.rawValue) == [5])
    }

    /// 带标题的窗口优先于更大的无标题窗口；登录标题也算。
    @Test func titledBeatsLargerUntitled() {
        let windows = [
            Fixtures.window(1, 10, nil, x: 0, y: 0, w: 3000, h: 2000),
            Fixtures.window(2, 10, "EVE", x: 0, y: 0, w: 1024, h: 768),
        ]
        #expect(ClientWindowSelector.mainWindows(from: windows).map(\.windowID.rawValue) == [2])
    }

    /// 多个候选时取面积最大的；面积相同取窗口 ID 最小的。
    @Test func tieBreaking() {
        let bigger = [
            Fixtures.window(7, 10, "EVE", x: 0, y: 0, w: 800, h: 600),
            Fixtures.window(8, 10, "EVE", x: 0, y: 0, w: 1728, h: 1018),
        ]
        #expect(ClientWindowSelector.mainWindows(from: bigger).map(\.windowID.rawValue) == [8])
        let equal = [
            Fixtures.window(12, 10, nil, x: 0, y: 0, w: 1000, h: 700),
            Fixtures.window(11, 10, nil, x: 50, y: 50, w: 1000, h: 700),
        ]
        #expect(ClientWindowSelector.mainWindows(from: equal).map(\.windowID.rawValue) == [11])
    }

    /// 标题无法识别的窗口不算带标题，按尺寸规则处理。
    @Test func unknownTitleTreatedAsUntitled() {
        let windows = [Fixtures.window(1, 10, "Something", x: 0, y: 0, w: 1728, h: 1018)]
        #expect(ClientWindowSelector.mainWindows(from: windows).map(\.windowID.rawValue) == [1])
        let small = [Fixtures.window(1, 10, "Something", x: 0, y: 0, w: 500, h: 500)]
        #expect(ClientWindowSelector.mainWindows(from: small).isEmpty)
    }
}
