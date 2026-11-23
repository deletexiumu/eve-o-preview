// SPDX-License-Identifier: GPL-3.0-or-later
//
// HotkeyActivation 与 MouseHotkeyMatcher 的用例（反馈文档 6.5 节、6.6 节）：
// 按作用范围启用、事件监听的开关、按下与松开的吞掉规则、swallowedButtons 的清空时机。

import Testing
import EVEOPreviewCore

/// 热键按作用范围启用的规则。
struct HotkeyActivationTests {
    /// global 在没有暂停时总是启用；game 只在前台是游戏时启用；暂停时都不启用。
    @Test func isActive() {
        #expect(HotkeyActivation.isActive(scope: .global, isGameFrontmost: false, isSuspended: false))
        #expect(HotkeyActivation.isActive(scope: .global, isGameFrontmost: true, isSuspended: false))
        #expect(!HotkeyActivation.isActive(scope: .game, isGameFrontmost: false, isSuspended: false))
        #expect(HotkeyActivation.isActive(scope: .game, isGameFrontmost: true, isSuspended: false))
        for scope in HotkeyScope.allCases {
            #expect(!HotkeyActivation.isActive(scope: scope, isGameFrontmost: true, isSuspended: true))
        }
    }
}

/// 鼠标热键的匹配器。
struct MouseHotkeyMatcherTests {
    /// 建一条鼠标绑定。
    private func binding(_ id: UInt32, button: Int, _ modifiers: HotkeyModifiers = [],
                         scope: HotkeyScope = .global) -> MouseHotkeyMatcher.Binding {
        MouseHotkeyMatcher.Binding(id: id, button: button, modifiers: modifiers, scope: scope)
    }

    /// 按下匹配：触发并吞掉；之后的拖动与松开都吞掉；松开后集合清空。
    @Test func swallowDownDragUp() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(7, button: 3)])
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(7))
        #expect(matcher.swallowedButtons == [3])
        #expect(matcher.handle(.dragged, button: 3, modifiers: []) == .swallow)
        // 松开时按住了修饰键也吞掉：只看 swallowedButtons。
        #expect(matcher.handle(.up, button: 3, modifiers: .shift) == .swallow)
        #expect(matcher.swallowedButtons.isEmpty)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .pass)
    }

    /// 没匹配的按下放行，它的拖动与松开也放行。
    @Test func unmatchedPasses() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3)])
        #expect(matcher.handle(.down, button: 4, modifiers: []) == .pass)
        #expect(matcher.handle(.dragged, button: 4, modifiers: []) == .pass)
        #expect(matcher.handle(.up, button: 4, modifiers: []) == .pass)
        #expect(matcher.handle(.dragged, button: 2, modifiers: []) == .pass)
    }

    /// 修饰键要完全相同：绑定是 Mouse4 时按住 Shift 不触发；绑定是 ctrl+Mouse3 时单按中键不触发。
    @Test func modifiersMustMatchExactly() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3), binding(2, button: 2, .control)])
        #expect(matcher.handle(.down, button: 3, modifiers: .shift) == .pass)
        #expect(matcher.handle(.up, button: 3, modifiers: .shift) == .pass)
        #expect(matcher.handle(.down, button: 2, modifiers: []) == .pass)
        #expect(matcher.handle(.up, button: 2, modifiers: []) == .pass)
        #expect(matcher.handle(.down, button: 2, modifiers: [.control, .shift]) == .pass)
        #expect(matcher.handle(.down, button: 2, modifiers: .control) == .fire(2))
    }

    /// 同一按钮号与修饰键有多条时第一条生效；不同修饰键各自匹配。
    @Test func firstBindingWins() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(5, button: 4), binding(6, button: 4), binding(8, button: 4, .option)])
        #expect(matcher.handle(.down, button: 4, modifiers: []) == .fire(5))
        #expect(matcher.handle(.down, button: 4, modifiers: .option) == .fire(8))
    }

    /// game 范围的绑定只在前台是游戏时匹配；global 范围的总是匹配。
    @Test func scopeAndFrontmost() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3, scope: .game), binding(2, button: 4, scope: .global)])
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .pass)
        #expect(matcher.handle(.down, button: 4, modifiers: []) == .fire(2))
        matcher.setGameFrontmost(true)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
    }

    /// 暂停时按下一律放行，不触发。
    @Test func suspendedPasses() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3)])
        matcher.setSuspended(true)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .pass)
        matcher.setSuspended(false)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
    }

    /// 监听的开关：没有绑定时关；只有 game 绑定时随前台开关；有 global 绑定时常开；暂停时关。
    @Test func shouldListen() {
        var matcher = MouseHotkeyMatcher()
        #expect(!matcher.shouldListen)
        matcher.replaceBindings([binding(1, button: 3, scope: .game)])
        #expect(!matcher.shouldListen)
        matcher.setGameFrontmost(true)
        #expect(matcher.shouldListen)
        matcher.setGameFrontmost(false)
        matcher.replaceBindings([binding(1, button: 3, scope: .game), binding(2, button: 4)])
        #expect(matcher.shouldListen)
        matcher.setSuspended(true)
        #expect(!matcher.shouldListen)
    }

    /// 每次按下先移出这个按钮号：上一次的松开丢了，这次没匹配的点击照常放行松开。
    @Test func downClearsStaleButton() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3, scope: .game)])
        matcher.setGameFrontmost(true)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        // 松开没收到。下一次按下带了修饰键，不匹配：应放行，它的松开也放行。
        #expect(matcher.handle(.down, button: 3, modifiers: .shift) == .pass)
        #expect(matcher.handle(.up, button: 3, modifiers: .shift) == .pass)
    }

    /// 绑定表被替换、离开游戏、暂停都不清空 swallowedButtons，监听因此保持打开，松开照样吞掉；
    /// 只有监听被系统关掉或被拆除（tapWasDisabled）时整个清空。
    @Test func swallowedButtonsKeptUntilRelease() {
        var matcher = MouseHotkeyMatcher()
        let game = [binding(1, button: 3, scope: .game)]
        matcher.replaceBindings(game)
        matcher.setGameFrontmost(true)

        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        matcher.replaceBindings([binding(9, button: 4)])
        #expect(matcher.swallowedButtons == [3])
        #expect(matcher.handle(.dragged, button: 3, modifiers: []) == .swallow)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)

        matcher.replaceBindings(game)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        matcher.setGameFrontmost(false)
        #expect(!matcher.hasActiveBinding)
        #expect(matcher.shouldListen)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
        #expect(!matcher.shouldListen)

        matcher.setGameFrontmost(true)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        matcher.setSuspended(true)
        #expect(matcher.shouldListen)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
        #expect(!matcher.shouldListen)

        matcher.setSuspended(false)
        _ = matcher.handle(.down, button: 3, modifiers: [])
        matcher.tapWasDisabled()
        #expect(matcher.swallowedButtons.isEmpty)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .pass)
    }

    /// 只因按着按钮而开着时，截止时刻从进入这种状态时算起，到期后清空；有生效的绑定时不计时。
    @Test func releaseDeadline() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3, scope: .game)])
        matcher.setGameFrontmost(true)
        _ = matcher.handle(.down, button: 3, modifiers: [])
        // 绑定仍生效：不计时，按住多久都不放弃。
        #expect(matcher.refreshReleaseDeadline(now: 100) == nil)
        #expect(matcher.refreshReleaseDeadline(now: 500) == nil)
        // 离开游戏：从这一刻起计时。
        matcher.setGameFrontmost(false)
        let deadline = matcher.refreshReleaseDeadline(now: 1000)
        #expect(deadline == 1000 + MouseHotkeyMatcher.releaseTimeout)
        // 再次检查不推后截止时刻。
        #expect(matcher.refreshReleaseDeadline(now: 1005) == deadline)
        #expect(matcher.swallowedButtons == [3])
        // 到期：清空，监听可以关闭。
        #expect(matcher.refreshReleaseDeadline(now: 1010) == nil)
        #expect(matcher.swallowedButtons.isEmpty)
        #expect(!matcher.shouldListen)
        #expect(matcher.releaseDeadline == nil)
    }

    /// 截止前松开：截止时刻清掉；再次进入这种状态时重新计时。
    @Test func releaseDeadlineResetAfterRelease() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3)])
        _ = matcher.handle(.down, button: 3, modifiers: [])
        matcher.setSuspended(true)
        #expect(matcher.refreshReleaseDeadline(now: 10) == 20)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
        #expect(matcher.refreshReleaseDeadline(now: 12) == nil)
        #expect(matcher.releaseDeadline == nil)
        matcher.setSuspended(false)
        _ = matcher.handle(.down, button: 3, modifiers: [])
        matcher.setSuspended(true)
        #expect(matcher.refreshReleaseDeadline(now: 50) == 60)
    }

    /// 离开游戏后仍有 global 绑定让监听开着时，已吞掉的按下的松开照样吞掉。
    @Test func releaseStillSwallowedWhileListening() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3, scope: .game), binding(2, button: 4)])
        matcher.setGameFrontmost(true)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        matcher.setGameFrontmost(false)
        #expect(matcher.shouldListen)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
    }
}
