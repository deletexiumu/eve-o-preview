// SPDX-License-Identifier: GPL-3.0-or-later
//
// 规划器对原生全屏客户端的处理（v1.1.1）：不裁标题栏；置顶时标出要盖过全屏窗口。

import Testing
import EVEOPreviewCore

/// 原生全屏客户端。
struct ThumbnailPlannerFullScreenTests {
    /// 全屏客户端：窗口范围不含菜单栏那一条，比屏幕矮（实测 1728×1084，屏幕 1728×1117）。
    private func fullScreenClient(_ isFullScreen: Bool?) -> EVEClient {
        var client = Fixtures.character(Fixtures.pilotAlpha, id: 1, pid: Fixtures.pidA)
        client.windowFrame = ScreenRect(x: 0, y: 33, width: 1728, height: 1084)
        client.isFullScreen = isFullScreen
        return client
    }

    /// 两个角色都有布局记录，避免自动排位干扰断言。
    private func plan(_ clients: [EVEClient], alwaysOnTop: Bool = true) -> ThumbnailPlan {
        var profile = Profile(name: "T")
        profile.layouts = [Fixtures.pilotAlpha: ThumbnailLayout(x: 100, y: 100),
                           Fixtures.pilotBravo: ThumbnailLayout(x: 600, y: 100)]
        profile.behavior.alwaysOnTop = alwaysOnTop
        return ThumbnailPlanner.plan(Fixtures.plannerInput(clients: clients, profile: profile, frontmost: .other,
                                                           session: SessionState(), permissions: .granted,
                                                           captureStates: nil))
    }

    /// 全屏客户端不裁标题栏；同样尺寸但不知道是否全屏时照常裁（窗口模式的最大化窗口有标题栏）。
    @Test func fullScreenIsNotCropped() {
        #expect(plan([fullScreenClient(true)]).presentations[0].contentsRect == .full)
        #expect(plan([fullScreenClient(nil)]).presentations[0].contentsRect != .full)
        #expect(plan([fullScreenClient(false)]).presentations[0].contentsRect != .full)
    }

    /// 有任一客户端全屏且置顶时，全部面板都标为要盖过全屏窗口；没有全屏客户端或不置顶时不标。
    @Test func overFullScreenFlag() {
        let other = Fixtures.character(Fixtures.pilotBravo, id: 2, pid: Fixtures.pidB)
        let mixed = plan([fullScreenClient(true), other])
        #expect(mixed.presentations.map(\.isOverFullScreen) == [true, true])
        #expect(plan([fullScreenClient(false), other]).presentations.allSatisfy { !$0.isOverFullScreen })
        #expect(plan([fullScreenClient(true), other], alwaysOnTop: false).presentations.allSatisfy { !$0.isOverFullScreen })
    }
}
