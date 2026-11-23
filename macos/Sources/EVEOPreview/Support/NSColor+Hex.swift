// SPDX-License-Identifier: GPL-3.0-or-later
//
// `#RRGGBB` 字符串与 NSColor、SwiftUI Color 之间的换算。
// 解析与格式化的规则由 Core 的 HexColor 决定，这里只做类型转换。

import AppKit
import SwiftUI
import EVEOPreviewCore

extension NSColor {
    /// 由 `#RRGGBB` 建 sRGB 颜色；字符串不合法时返回 nil。
    ///
    /// - Parameters:
    ///   - hex: 颜色字符串，规则见 `HexColor.components`。
    ///   - alpha: 不透明度，0～1。
    convenience init?(hex: String, alpha: CGFloat = 1) {
        guard let c = HexColor.components(hex) else { return nil }
        self.init(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: alpha)
    }

    /// 转成 `#RRGGBB`。颜色无法换算到 sRGB 时返回 nil；alpha 被丢弃。
    var hexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return HexColor.string(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                               blue: Double(srgb.blueComponent))
    }
}

extension Color {
    /// 由 `#RRGGBB` 建 SwiftUI 颜色；字符串不合法时用 `fallback`。
    init(hex: String, fallback: Color = .white) {
        if let color = NSColor(hex: hex) {
            self.init(nsColor: color)
        } else {
            self = fallback
        }
    }

    /// 转成 `#RRGGBB`；无法换算时返回 nil。
    var hexString: String? {
        NSColor(self).hexString
    }
}
