// SPDX-License-Identifier: GPL-3.0-or-later
//
// LayoutResolver 的用例（架构文档 5.4 节、10.2 节）。
// 主屏可用区域是 (0, 33, 1728, 1084)，默认缩略图 384×216。

import Testing
import EVEOPreviewCore

/// 布局计算：有记录、自动排位、登录层叠、尺寸夹取、宽高比、屏幕外拉回、负坐标副屏。
struct LayoutResolverTests {
    private let screens = [Fixtures.mainScreen]
    private let pilotA = Fixtures.character("Pilot Alpha", id: 1, pid: 10)

    /// 用给定布局建一个配置方案。
    private func profile(_ layouts: [String: ThumbnailLayout] = [:]) -> Profile {
        Profile(name: "T", layouts: layouts)
    }

    /// 有记录：用记录的位置，宽高为 nil 时用默认尺寸。
    @Test func recordedLayout() {
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0,
                                          profile: profile(["Pilot Alpha": ThumbnailLayout(x: 100, y: 200)]),
                                          screens: screens, occupied: [])
        #expect(result == ResolvedLayout(frame: ScreenRect(x: 100, y: 200, width: 384, height: 216), isAutoPlaced: false))
    }

    /// 有记录且尺寸越界：夹到最小与最大尺寸之间。
    @Test func recordedSizeIsClamped() {
        let layout = ThumbnailLayout(x: 100, y: 200, width: 1000, height: 100)
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(["Pilot Alpha": layout]),
                                          screens: screens, occupied: [])
        #expect(result.frame.size == ScreenSize(width: 960, height: 108))
    }

    /// 无记录：从主屏可用区域左上角起，边距 16 点。
    @Test func autoPlacementFirstCell() {
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(), screens: screens, occupied: [])
        #expect(result == ResolvedLayout(frame: ScreenRect(x: 16, y: 49, width: 384, height: 216), isAutoPlaced: true))
    }

    /// 无记录：跳过被占用的格子，向下排，间距 8 点；一列排满后换下一列。
    @Test func autoPlacementSkipsOccupiedAndWraps() {
        let cell = { (x: Double, y: Double) in ScreenRect(x: x, y: y, width: 384, height: 216) }
        let second = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(), screens: screens,
                                          occupied: [cell(16, 49)])
        #expect(second.frame == cell(16, 273))
        // 一列能放 4 个（49、273、497、721），第 5 个换到 x = 16 + 384 + 8 = 408。
        let column = [49.0, 273, 497, 721].map { cell(16, $0) }
        let wrapped = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(), screens: screens,
                                           occupied: column)
        #expect(wrapped.frame == cell(408, 49))
    }

    /// 屏幕排满时叠放在第一个格子。
    @Test func autoPlacementFullScreenFallsBack() {
        let everything = [ScreenRect(x: 0, y: 0, width: 1728, height: 1117)]
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(), screens: screens,
                                          occupied: everything)
        #expect(result.frame.origin == ScreenPoint(x: 16, y: 49))
        #expect(result.isAutoPlaced)
    }

    /// 登录客户端：loginPosition 加 24 × 序号的层叠偏移，不自动排位。
    @Test func loginCascade() {
        let login = Fixtures.client(5, pid: 50, .login)
        let unknown = Fixtures.client(6, pid: 60, .unknown)
        let first = LayoutResolver.frame(for: login, loginIndex: 0, profile: profile(), screens: screens, occupied: [])
        #expect(first == ResolvedLayout(frame: ScreenRect(x: 5, y: 40, width: 384, height: 216), isAutoPlaced: false))
        let third = LayoutResolver.frame(for: unknown, loginIndex: 2, profile: profile(), screens: screens, occupied: [])
        #expect(third.frame.origin == ScreenPoint(x: 53, y: 88))
    }

    /// 尺寸夹取：不带宽高比时宽高各自夹取。
    @Test func clampSizeWithoutRatio() {
        let settings = ThumbnailSettings()
        #expect(LayoutResolver.clampSize(ScreenSize(width: 10, height: 10000), settings: settings, aspectRatio: nil)
            == ScreenSize(width: 192, height: 540))
    }

    /// 尺寸夹取：带宽高比时按宽算高，高越界时按高的边界算宽。
    @Test func clampSizeWithRatio() {
        let settings = ThumbnailSettings()
        #expect(LayoutResolver.clampSize(ScreenSize(width: 400, height: 400), settings: settings, aspectRatio: 2)
            == ScreenSize(width: 400, height: 200))
        #expect(LayoutResolver.clampSize(ScreenSize(width: 900, height: 100), settings: settings, aspectRatio: 1)
            == ScreenSize(width: 540, height: 540))
        #expect(LayoutResolver.clampSize(ScreenSize(width: 200, height: 100), settings: settings, aspectRatio: 4)
            == ScreenSize(width: 432, height: 108))
    }

    /// 屏幕外的记录被拉回最近屏幕的可用区域内，尺寸不变。
    @Test func offscreenIsPulledBack() {
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0,
                                          profile: profile(["Pilot Alpha": ThumbnailLayout(x: 5000, y: 5000)]),
                                          screens: screens, occupied: [])
        #expect(result.frame == ScreenRect(x: 1344, y: 901, width: 384, height: 216))
    }

    /// 负坐标的副屏：缩略图在副屏上时保持原位；副屏拔掉后拉回主屏。
    @Test func negativeCoordinateSecondaryScreen() {
        let layout = ["Pilot Alpha": ThumbnailLayout(x: -1500, y: 100)]
        let both = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(layout),
                                        screens: [Fixtures.mainScreen, Fixtures.leftScreen], occupied: [])
        #expect(both.frame.origin == ScreenPoint(x: -1500, y: 100))
        let mainOnly = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(layout), screens: screens,
                                            occupied: [])
        #expect(mainOnly.frame.origin == ScreenPoint(x: 0, y: 100))
    }

    /// 露出不足 32 点时拉回，露出 32 点以上时不动。
    @Test func minimumVisibleThreshold() {
        let barely = ScreenRect(x: -352, y: 100, width: 384, height: 216)   // 露出 32 点
        #expect(LayoutResolver.clampToScreens(barely, screens: screens, minimumVisible: 32) == barely)
        let hidden = ScreenRect(x: -360, y: 100, width: 384, height: 216)   // 露出 24 点
        #expect(LayoutResolver.clampToScreens(hidden, screens: screens, minimumVisible: 32).x == 0)
        // 没有屏幕信息时原样返回。
        #expect(LayoutResolver.clampToScreens(hidden, screens: [], minimumVisible: 32) == hidden)
    }
}
