// SPDX-License-Identifier: GPL-3.0-or-later
//
// UTF-16 与 Rust 字符串的转换。Win32 的 W 系列接口都收发以 0 结尾的 UTF-16。

//! 宽字符串转换。

/// 转成以 0 结尾的 UTF-16。
pub(crate) fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 取缓冲区里前 len 个 UTF-16 单元转成字符串；非法的代理对换成替换字符。
pub(crate) fn from_wide(buffer: &[u16], len: usize) -> String {
    String::from_utf16_lossy(&buffer[..len.min(buffer.len())])
}
