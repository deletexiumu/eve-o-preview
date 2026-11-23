// SPDX-License-Identifier: GPL-3.0-or-later
//
// `#RRGGBB` 颜色字符串的解析，对应 macOS 的 HexColor。界面层用它换算颜色，配置校验用它判断颜色是否合法。

//! 十六进制颜色解析。

use crate::support::text;

/// 解析 `#RRGGBB`，返回 0～1 的红、绿、蓝分量。
///
/// 不区分大小写，允许首尾空白（不含换行），`#` 可以省略。长度不是 6 位或含非十六进制字符时返回 `None`；
/// 不支持 3 位缩写与带透明度的 8 位写法。
pub fn components(text: &str) -> Option<(f64, f64, f64)> {
    let trimmed = text::trim_whitespace(text);
    let hex = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if hex.chars().count() != 6 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let value = u32::from_str_radix(hex, 16).ok()?;
    let channel = |shift: u32| f64::from((value >> shift) & 0xFF) / 255.0;
    Some((channel(16), channel(8), channel(0)))
}

/// 是否是合法的 `#RRGGBB`。
pub fn is_valid(text: &str) -> bool {
    components(text).is_some()
}

/// 把 0～1 的分量格式化为大写的 `#RRGGBB`；越界的分量先夹到 0～1，非有限值按 0 处理。
pub fn string(red: f64, green: f64, blue: f64) -> String {
    let byte = |v: f64| {
        let v = if v.is_finite() { v } else { 0.0 };
        (v.clamp(0.0, 1.0) * 255.0).round() as u8
    };
    format!("#{:02X}{:02X}{:02X}", byte(red), byte(green), byte(blue))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 合法与非法的写法。
    #[test]
    fn parsing() {
        assert_eq!(components("#FFFFFF"), Some((1.0, 1.0, 1.0)));
        assert_eq!(components(" adff2f "), Some((173.0 / 255.0, 1.0, 47.0 / 255.0)));
        assert!(components("#FFF").is_none());
        assert!(components("#FFFFFF80").is_none());
        assert!(components("#GGGGGG").is_none());
        assert!(components("#FFFFFF\n").is_none());
        assert!(components("").is_none());
    }

    /// 格式化：夹取与四舍五入。
    #[test]
    fn formatting() {
        assert_eq!(string(1.0, 0.0, 0.5), "#FF0080");
        assert_eq!(string(2.0, -1.0, f64::NAN), "#FF0000");
    }
}
