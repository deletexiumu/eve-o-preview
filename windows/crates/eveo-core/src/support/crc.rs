// SPDX-License-Identifier: GPL-3.0-or-later
//
// CRC-32（zip 用的那种）：问题报告写 zip 时算，更新包解包时核对。

//! CRC-32。

/// CRC-32（IEEE 802.3，多项式 0xEDB88320），逐字节查表。
pub fn crc32(data: &[u8]) -> u32 {
    // 表只有 256 项，每次现算也只要几微秒；调用很少（写一份报告、解一个更新包），不必缓存。
    let mut table = [0u32; 256];
    for (i, slot) in table.iter_mut().enumerate() {
        let mut c = i as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
        }
        *slot = c;
    }
    // 初值全 1、结果取反，是 zip 与以太网共用的约定。
    let mut crc = 0xFFFF_FFFF_u32;
    for &byte in data {
        crc = table[((crc ^ u32::from(byte)) & 0xFF) as usize] ^ (crc >> 8);
    }
    !crc
}
