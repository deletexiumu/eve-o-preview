// SPDX-License-Identifier: GPL-3.0-or-later
//
// CarbonHotkeyID 与 MouseTapRetry 的用例（反馈文档 6.5 节）：
// Carbon 热键编号的编码与解码、代数的循环，以及鼠标事件监听不可用时的重试时机。

import Testing
import EVEOPreviewCore

/// Carbon 热键编号的编码。
struct CarbonHotkeyIDTests {
    /// 编码后再解码，得到原来的代数与绑定 id；高 8 位是代数，低 24 位是绑定 id。
    @Test func roundTrip() throws {
        for (generation, bindingID) in [(0, 1), (1, 1), (7, 42), (255, 0x00FF_FFFF)] as [(UInt32, UInt32)] {
            let raw = try #require(CarbonHotkeyID.encode(generation: generation, bindingID: bindingID))
            #expect(raw == generation << 24 | bindingID)
            let decoded = CarbonHotkeyID.decode(raw)
            #expect(decoded.generation == generation)
            #expect(decoded.bindingID == bindingID)
        }
    }

    /// 绑定 id 超出低 24 位时编码不下，返回 nil。
    @Test func rejectsOversizedBindingID() {
        #expect(CarbonHotkeyID.encode(generation: 0, bindingID: 0x0100_0000) == nil)
        #expect(CarbonHotkeyID.encode(generation: 3, bindingID: .max) == nil)
    }

    /// 代数只取低 8 位，不会挤进绑定 id 的位。
    @Test func generationIsMaskedTo8Bits() {
        #expect(CarbonHotkeyID.encode(generation: 0x1_05, bindingID: 9) == 0x05_00_0009)
    }

    /// 同一个绑定 id 在相邻两代的编号不同，旧一代的事件能被认出来。
    @Test func adjacentGenerationsDiffer() {
        let old = CarbonHotkeyID.encode(generation: 4, bindingID: 1)
        let new = CarbonHotkeyID.encode(generation: CarbonHotkeyID.nextGeneration(after: 4), bindingID: 1)
        #expect(old != new)
    }

    /// 代数加 1，到 255 之后回到 0。
    @Test func nextGenerationWraps() {
        #expect(CarbonHotkeyID.nextGeneration(after: 0) == 1)
        #expect(CarbonHotkeyID.nextGeneration(after: 254) == 255)
        #expect(CarbonHotkeyID.nextGeneration(after: 255) == 0)
    }
}

/// 鼠标事件监听不可用时的重试时机。
struct MouseTapRetryTests {
    /// 没有记下失败时刻（监听可用，或失败原因是没有权限）时不重试。
    @Test func noFailureNoRetry() {
        #expect(!MouseTapRetry.isDue(failedAt: nil, now: 1_000, isSuspended: false))
    }

    /// 距失败不满间隔时不重试，满间隔（含边界）时重试。
    @Test func waitsForInterval() {
        let failedAt = 100.0
        #expect(!MouseTapRetry.isDue(failedAt: failedAt, now: failedAt, isSuspended: false))
        #expect(!MouseTapRetry.isDue(failedAt: failedAt, now: failedAt + MouseTapRetry.interval - 0.01,
                                     isSuspended: false))
        #expect(MouseTapRetry.isDue(failedAt: failedAt, now: failedAt + MouseTapRetry.interval, isSuspended: false))
        #expect(MouseTapRetry.isDue(failedAt: failedAt, now: failedAt + 60, isSuspended: false))
    }

    /// 暂停期间（录制热键、应用退出）不重试，恢复后照常。
    @Test func suspendedNoRetry() {
        #expect(!MouseTapRetry.isDue(failedAt: 0, now: 600, isSuspended: true))
        #expect(MouseTapRetry.isDue(failedAt: 0, now: 600, isSuspended: false))
    }
}
