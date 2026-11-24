// SPDX-License-Identifier: GPL-3.0-or-later
//
// 只存储、不压缩的 zip 写出器。macOS 用系统的 ditto 打包；Windows 没有现成的命令行工具可靠地做这件事
// （PowerShell 的 Compress-Archive 慢且依赖执行策略），报告只有几 MiB 的文字，不压缩也不大，
// 所以按 PKWARE 的 APPNOTE 直接写：每个文件一个本地头加数据，最后是中央目录与目录尾。
// - 文件名用 UTF-8，置通用标志的第 11 位，资源管理器与 7-Zip 都按 UTF-8 读。
// - 时间写成 DOS 格式，用调用方给的年月日时分秒（应用给本地时间）。
// - 报告远小于 4 GiB，不写 ZIP64；超出时返回错误。

//! 只存储的 zip 写出器。

use std::io::{self, Write};

/// 通用标志：文件名是 UTF-8。
const FLAG_UTF8: u16 = 1 << 11;
/// 需要的版本 2.0（目录项与 CRC 都要求 2.0）。
const VERSION: u16 = 20;

/// DOS 格式的时间：年（1980～2107）、月、日、时、分、秒。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DosTime {
    /// 年。
    pub year: u16,
    /// 月，1～12。
    pub month: u16,
    /// 日，1～31。
    pub day: u16,
    /// 时，0～23。
    pub hour: u16,
    /// 分，0～59。
    pub minute: u16,
    /// 秒，0～59（DOS 格式只存偶数秒）。
    pub second: u16,
}

impl DosTime {
    /// 时间与日期两个 16 位字段。年份超出范围时夹到 1980～2107。
    fn fields(self) -> (u16, u16) {
        // 年从 1980 起算，占 7 位；秒只有 5 位，存的是秒数的一半。
        let year = self.year.clamp(1980, 2107) - 1980;
        let time = (self.hour << 11) | (self.minute << 5) | (self.second / 2);
        let date = (year << 9) | (self.month << 5) | self.day;
        (time, date)
    }
}

/// 一个文件的中央目录项要用的信息。
struct Entry {
    /// 压缩包里的路径。
    name: String,
    /// 数据的 CRC-32。
    crc: u32,
    /// 数据的字节数。
    size: u32,
    /// 本地头在压缩包里的偏移。
    offset: u32,
}

/// 把 files（压缩包里的路径与内容）写成一个 zip，路径用 `/` 分隔。
pub fn write_zip(out: &mut impl Write, files: &[(String, Vec<u8>)], time: DosTime) -> io::Result<()> {
    // 全部文件用同一个时间：报告是一次生成的。
    let (dos_time, dos_date) = time.fields();
    let too_large = || io::Error::new(io::ErrorKind::InvalidInput, "zip 超过 4 GiB");
    let mut entries = Vec::with_capacity(files.len());
    let mut offset: u64 = 0;
    // 本地头与数据。
    for (name, data) in files {
        let size = u32::try_from(data.len()).map_err(|_| too_large())?;
        let entry = Entry {
            name: name.clone(),
            crc: crc32(data),
            size,
            offset: u32::try_from(offset).map_err(|_| too_large())?,
        };
        let mut header = Vec::with_capacity(30 + name.len());
        put32(&mut header, 0x0403_4b50);
        put16(&mut header, VERSION);
        put16(&mut header, FLAG_UTF8);
        put16(&mut header, 0); // 方法 0：只存储。
        put16(&mut header, dos_time);
        put16(&mut header, dos_date);
        put32(&mut header, entry.crc);
        put32(&mut header, size); // 压缩后的大小与原大小相同。
        put32(&mut header, size);
        put16(&mut header, name_len(name)?);
        put16(&mut header, 0); // 没有扩展字段。
        header.extend_from_slice(name.as_bytes());
        out.write_all(&header)?;
        out.write_all(data)?;
        offset += header.len() as u64 + data.len() as u64;
        entries.push(entry);
    }
    // 中央目录：每个文件一项，内容与本地头重复，另加本地头的偏移；解压工具从这里找文件。
    let directory_offset = u32::try_from(offset).map_err(|_| too_large())?;
    let mut directory = Vec::new();
    for entry in &entries {
        put32(&mut directory, 0x0201_4b50);
        put16(&mut directory, VERSION); // 制作者的版本（高字节 0：MS-DOS 的属性）。
        put16(&mut directory, VERSION);
        put16(&mut directory, FLAG_UTF8);
        put16(&mut directory, 0);
        put16(&mut directory, dos_time);
        put16(&mut directory, dos_date);
        put32(&mut directory, entry.crc);
        put32(&mut directory, entry.size);
        put32(&mut directory, entry.size);
        put16(&mut directory, name_len(&entry.name)?);
        put16(&mut directory, 0); // 扩展字段长度。
        put16(&mut directory, 0); // 注释长度。
        put16(&mut directory, 0); // 起始盘号。
        put16(&mut directory, 0); // 内部属性。
        put32(&mut directory, 0); // 外部属性。
        put32(&mut directory, entry.offset);
        directory.extend_from_slice(entry.name.as_bytes());
    }
    let count = u16::try_from(entries.len()).map_err(|_| too_large())?;
    let directory_size = u32::try_from(directory.len()).map_err(|_| too_large())?;
    // 目录尾：单盘，没有注释。
    put32(&mut directory, 0x0605_4b50);
    put16(&mut directory, 0);
    put16(&mut directory, 0);
    put16(&mut directory, count);
    put16(&mut directory, count);
    put32(&mut directory, directory_size);
    put32(&mut directory, directory_offset);
    put16(&mut directory, 0);
    out.write_all(&directory)
}

/// 文件名的字节数；超过 65535 时报错。
fn name_len(name: &str) -> io::Result<u16> {
    u16::try_from(name.len()).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "文件名过长"))
}

/// 追加一个小端的 16 位数。
fn put16(buffer: &mut Vec<u8>, value: u16) {
    buffer.extend_from_slice(&value.to_le_bytes());
}

/// 追加一个小端的 32 位数。
fn put32(buffer: &mut Vec<u8>, value: u32) {
    buffer.extend_from_slice(&value.to_le_bytes());
}

/// CRC-32 与 Core 共用一份实现（更新包的解包也要核对它）。
pub use eveo_core::support::crc::crc32;

#[cfg(test)]
mod tests {
    use super::*;

    /// CRC-32 的标准校验值。
    #[test]
    fn crc_check_value() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b""), 0);
    }

    /// 写出的结构：本地头、数据、中央目录与目录尾的签名与偏移都对得上。
    #[test]
    fn writes_structure() {
        let files = vec![
            ("r/summary.md".to_owned(), b"hello".to_vec()),
            ("r/logs/中文.log".to_owned(), Vec::new()),
        ];
        let time = DosTime {
            year: 2026,
            month: 11,
            day: 24,
            hour: 13,
            minute: 5,
            second: 7,
        };
        // 一个有内容的文件，一个空文件（中文名，检验 UTF-8 文件名）。
        let mut zip = Vec::new();
        write_zip(&mut zip, &files, time).unwrap();
        let u16_at = |i: usize| u16::from_le_bytes([zip[i], zip[i + 1]]);
        let u32_at = |i: usize| u32::from_le_bytes([zip[i], zip[i + 1], zip[i + 2], zip[i + 3]]);
        // 第一个本地头。
        assert_eq!(u32_at(0), 0x0403_4b50);
        assert_eq!(u16_at(6), FLAG_UTF8);
        assert_eq!(u32_at(14), crc32(b"hello"));
        assert_eq!(&zip[30..42], b"r/summary.md");
        assert_eq!(&zip[42..47], b"hello");
        // 目录尾在最后 22 字节：两项，中央目录的偏移指向它的签名。
        let end = zip.len() - 22;
        assert_eq!(u32_at(end), 0x0605_4b50);
        assert_eq!(u16_at(end + 10), 2);
        let directory = u32_at(end + 16) as usize;
        assert_eq!(u32_at(directory), 0x0201_4b50);
        assert_eq!(directory + u32_at(end + 12) as usize, end);
        // 第二个文件的本地头偏移写在第二个目录项里。
        let second = directory + 46 + "r/summary.md".len();
        assert_eq!(u32_at(u32_at(second + 42) as usize), 0x0403_4b50);
        // 时间：13:05:06（秒按 2 取整），日期 2026-11-24。
        assert_eq!(u16_at(10), (13 << 11) | (5 << 5) | 3);
        assert_eq!(u16_at(12), (46 << 9) | (11 << 5) | 24);
    }
}
