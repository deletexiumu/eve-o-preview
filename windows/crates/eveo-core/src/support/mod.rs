// SPDX-License-Identifier: GPL-3.0-or-later
//
// 各模块共用的小工具，对应 macOS 的 Support/：字符串枚举与宽松解码、配置结构的声明宏、
// 十六进制颜色、CRC-32、与 Foundation 对齐的文本处理、UTC 时间与 ISO 8601。

//! 共用的小工具。

#[macro_use]
mod config_struct;
#[macro_use]
mod string_enum;
pub mod crc;
pub mod hex_color;
pub mod text;
pub mod time;

pub use string_enum::{Lenient, Strict, StringEnum};
