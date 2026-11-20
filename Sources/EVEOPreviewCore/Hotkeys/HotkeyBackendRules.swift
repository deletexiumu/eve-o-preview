// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键后端用到的两条纯规则（反馈文档 6.5 节）：Carbon 热键编号的编码，以及鼠标事件监听不可用时的重试节奏。
// 平台层的 CarbonHotkeyRegistrar 与 SystemHotkeyRegistrar 调这里，规则本身不碰系统接口，可以直接单元测试。

import Foundation

/// Carbon 热键编号（`EventHotKeyID.id`）的编码：高 8 位是代数，低 24 位是绑定 id。
///
/// `HotkeyPlanner` 每次规划都从 1 起重新编号。热键事件先排进主线程的事件队列，`replaceAll` 之后才分发时，
/// 旧编号会对上新规划里别的动作。带上代数后，事件处理器能认出并丢弃上一代的事件。
public enum CarbonHotkeyID {
    /// 绑定 id 占低 24 位。
    public static let bindingIDMask: UInt32 = 0x00FF_FFFF
    /// 代数的取值是 0～255，循环使用。
    public static let generationMask: UInt32 = 0xFF

    /// 把代数与绑定 id 编成一个编号。绑定 id 大于 `bindingIDMask` 时编码不下，返回 nil；代数只取低 8 位。
    public static func encode(generation: UInt32, bindingID: UInt32) -> UInt32? {
        guard bindingID <= bindingIDMask else { return nil }
        return (generation & generationMask) << 24 | bindingID
    }

    /// 从编号里取出代数与绑定 id。
    public static func decode(_ rawID: UInt32) -> (generation: UInt32, bindingID: UInt32) {
        (rawID >> 24, rawID & bindingIDMask)
    }

    /// 下一代的代数：加 1，到 255 之后回到 0。
    public static func nextGeneration(after generation: UInt32) -> UInt32 {
        (generation &+ 1) & generationMask
    }
}

/// 鼠标事件监听不可用（`eventTapUnavailable`）时的重试规则。
///
/// 系统没建出监听或关掉后打不开，可能只是一时的。巡检每隔 `interval` 秒重新建一次监听，
/// 不必等规划或辅助功能权限变化。没有辅助功能权限（`accessibilityRequired`）不在这里重试：
/// 协调器发现权限变化后会重新调 `replaceAll`。
public enum MouseTapRetry {
    /// 两次重试之间至少隔多少秒。
    public static let interval: Double = 10

    /// 此刻是否该重试。
    ///
    /// - Parameters:
    ///   - failedAt: 最近一次确认监听不可用的时刻（单调时钟的秒数）；监听可用或失败原因不是「不可用」时为 nil。
    ///   - now: 当前时刻，与 `failedAt` 同一时钟。
    ///   - isSuspended: 热键是否暂停（录制热键期间、应用退出期间）。暂停期间不重试。
    public static func isDue(failedAt: Double?, now: Double, isSuspended: Bool) -> Bool {
        guard let failedAt, !isSuspended else { return false }
        return now - failedAt >= interval
    }
}
