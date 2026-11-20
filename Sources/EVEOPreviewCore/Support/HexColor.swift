// SPDX-License-Identifier: GPL-3.0-or-later
//
// `#RRGGBB` 颜色字符串的解析。App 用它换算成 NSColor，ConfigValidator 用它判断颜色是否合法。

import Foundation

/// 十六进制颜色解析。
public enum HexColor {
    /// 解析 `#RRGGBB`，返回 0～1 的红、绿、蓝分量。
    ///
    /// 不区分大小写，允许首尾空白，`#` 可以省略。长度不是 6 位或含非十六进制字符时返回 nil；
    /// 不支持 3 位缩写与带透明度的 8 位写法。
    public static func components(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = Substring(text.trimmingCharacters(in: .whitespaces))
        if hex.hasPrefix("#") { hex = hex.dropFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else {
            return nil
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return (red, green, blue)
    }

    /// 把 0～1 的分量格式化为大写的 `#RRGGBB`；越界的分量先夹到 0～1。
    public static func string(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int {
            Int((min(max(value.isFinite ? value : 0, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
