// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗位置与尺寸在设置页手工填写的用例（v1.2.1）：OverlayPlanner.resolvedFrame 与 editedFrame。

import Testing
import EVEOPreviewCore

/// 设置页显示的 frame 与手工修改后的 frame。
struct OverlayFrameEditTests {
    /// 测试用的屏幕。
    private let screens = [Fixtures.mainScreen]

    /// 没保存过时显示默认位置；保存过时显示收进屏幕后的 frame，与规划器一致。
    @Test func resolvedFrameMatchesPlanner() {
        #expect(OverlayPlanner.resolvedFrame(nil, kind: .intel, screens: screens)
                == OverlayPlanner.defaultFrame(kind: .intel, screens: screens))
        let saved = ScreenRect(x: 5000, y: 300, width: 300, height: 200)
        #expect(OverlayPlanner.resolvedFrame(saved, kind: .translation, screens: screens)
                == OverlayPlanner.clampedFrame(saved, screens: screens))
    }

    /// 从默认位置改一个字段：只改这个字段，其余三个保持默认位置的值；数值取整。
    @Test func editKeepsOtherFields() throws {
        let base = OverlayPlanner.defaultFrame(kind: .intel, screens: screens)
        let edited = try #require(OverlayPlanner.editedFrame(base, field: .x, value: 200.4, screens: screens))
        #expect(edited == ScreenRect(x: 200, y: base.y, width: base.width, height: base.height))
        let taller = try #require(OverlayPlanner.editedFrame(base, field: .height, value: 400, screens: screens))
        #expect(taller == ScreenRect(x: base.x, y: base.y, width: base.width, height: 400))
    }

    /// 尺寸夹到 220×120～900×900。
    @Test func editClampsSize() throws {
        let base = ScreenRect(x: 100, y: 100, width: 300, height: 200)
        #expect(try #require(OverlayPlanner.editedFrame(base, field: .width, value: 50, screens: screens)).width == 220)
        #expect(try #require(OverlayPlanner.editedFrame(base, field: .width, value: 5000, screens: screens)).width == 900)
        #expect(try #require(OverlayPlanner.editedFrame(base, field: .height, value: 10, screens: screens)).height == 120)
    }

    /// 移出屏幕的位置被拉回；不是有限值时返回 nil，不写配置。
    @Test func editPullsBackAndRejectsNonFinite() throws {
        let base = ScreenRect(x: 100, y: 100, width: 300, height: 200)
        let far = try #require(OverlayPlanner.editedFrame(base, field: .x, value: 9000, screens: screens))
        #expect(far.x == 1728 - 40)
        #expect(OverlayPlanner.editedFrame(base, field: .y, value: .nan, screens: screens) == nil)
        #expect(OverlayPlanner.editedFrame(base, field: .width, value: .infinity, screens: screens) == nil)
    }
}
