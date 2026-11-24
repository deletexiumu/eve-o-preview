// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「统一全部缩略图尺寸」的规则（设置窗口「预览与布局」页的两个按钮），与 Windows 版
// eveo-ui/src/bind.rs 的 unify_sizes 一致：
// - 按默认尺寸：清掉各角色记录里的宽高，缩略图回到 thumbnail.defaultSize。
// - 按活动客户端：各角色的宽高都抄活动客户端（高亮的那个）的记录。用户调好一个缩略图后，
//   切到它的客户端（或它本来就是活动的），一键让其余缩略图都跟它一样大。
// 两种都只改尺寸、不改位置，也不删记录：记录里还有位置。

/// 统一到哪个尺寸。
public enum ThumbnailSizeTarget: Sendable, Equatable {
    /// 全部改回默认尺寸。
    case defaultSize
    /// 全部改成这个角色的缩略图尺寸。
    case character(String)
}

extension Profile {
    /// 统一各角色缩略图的尺寸，位置不变。
    ///
    /// `.character` 的角色没单独调过大小（宽高为 nil）时，结果与改回默认尺寸相同；
    /// 配置里没有它的记录时什么也不改，免得误把全部缩略图改回默认尺寸。
    /// 抄的是配置里的逻辑尺寸，各缩略图按自己所在屏幕显示，不同屏幕上看起来一样大。
    public mutating func unifyThumbnailSizes(to target: ThumbnailSizeTarget) {
        let width: Double?
        let height: Double?
        switch target {
        case .defaultSize:
            (width, height) = (nil, nil)
        case .character(let name):
            // 没有来源记录：保持原样。
            guard let source = layouts[name] else { return }
            (width, height) = (source.width, source.height)
        }
        // 只改尺寸，键不变；遍历键的副本，边遍历边改字典的值是安全的。
        for name in Array(layouts.keys) {
            layouts[name]?.width = width
            layouts[name]?.height = height
        }
    }
}
