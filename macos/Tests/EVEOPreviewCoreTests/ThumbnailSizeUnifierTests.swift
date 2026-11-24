// SPDX-License-Identifier: GPL-3.0-or-later
//
// Profile.unifyThumbnailSizes 的用例（「预览与布局」页的统一尺寸），与 Windows 版 bind.rs 的用例对应。

import Testing
import EVEOPreviewCore

/// 统一尺寸：按默认尺寸、按活动客户端、来源没调过大小、来源不存在。
struct ThumbnailSizeUnifierTests {
    /// Aria 调过大小，Kade 没调过（宽高为 nil），Lin 调成另一个大小；三条的位置各不相同。
    private func profile() -> Profile {
        var profile = Profile(id: "p", name: "Main")
        profile.layouts = [
            "Aria": ThumbnailLayout(x: 10, y: 20, width: 500, height: 280),
            "Kade": ThumbnailLayout(x: 600, y: 20),
            "Lin": ThumbnailLayout(x: 1200, y: 20, width: 320, height: 180),
        ]
        return profile
    }

    /// 按默认尺寸：只清宽高，位置不动。
    @Test func toDefaultKeepsPositions() {
        var profile = profile()
        profile.unifyThumbnailSizes(to: .defaultSize)
        #expect(profile.layouts["Aria"] == ThumbnailLayout(x: 10, y: 20))
        #expect(profile.layouts["Lin"] == ThumbnailLayout(x: 1200, y: 20))
    }

    /// 按活动客户端：全部抄它的宽高，位置不动；它自己不变。
    @Test func toCharacterCopiesItsSize() {
        var profile = profile()
        profile.unifyThumbnailSizes(to: .character("Aria"))
        #expect(profile.layouts["Aria"] == ThumbnailLayout(x: 10, y: 20, width: 500, height: 280))
        #expect(profile.layouts["Kade"] == ThumbnailLayout(x: 600, y: 20, width: 500, height: 280))
        #expect(profile.layouts["Lin"] == ThumbnailLayout(x: 1200, y: 20, width: 500, height: 280))
    }

    /// 活动客户端没调过大小：等于全部改回默认尺寸。
    @Test func toUnsizedCharacterMeansDefault() {
        var profile = profile()
        profile.unifyThumbnailSizes(to: .character("Kade"))
        for layout in profile.layouts.values {
            #expect(layout.width == nil && layout.height == nil)
        }
    }

    /// 配置里没有那个角色的记录：什么也不改。
    @Test func toUnknownCharacterIsNoop() {
        var profile = profile()
        let before = profile
        profile.unifyThumbnailSizes(to: .character("Nobody"))
        #expect(profile == before)
    }
}
