// SPDX-License-Identifier: GPL-3.0-or-later
//
// 从更新包（zip）里取出应用的 exe，并核对它是不是给本机的（docs/windows/architecture.md 6.2、6.3 节）。
//
// 更新包由本项目的 CI 生成，在这里解包之前已经核对过 ed25519 签名与 SHA-256，所以只需读懂我们自己会写出的 zip：
// - 从末尾找「中央目录结束」记录，再按中央目录找到名字正好是 `EVE-O Preview.exe` 的项（在根目录，不在子文件夹）；
// - 压缩方式只认存储（0）与 deflate（8）；加密、ZIP64、分卷都按坏包处理；
// - 解出的大小要等于目录里写的大小，CRC-32 要相符，大小不超过调用方给的上限。
// PE 头的机器类型用来核对架构：x64 的包不应装到 ARM64 的原生构建上（反之亦然）。

//! 更新包的解包与 PE 头。

use super::models::UpdateError;
use crate::support::crc::crc32;

/// 更新包里应用 exe 的名字。
pub const EXE_NAME: &str = "EVE-O Preview.exe";

/// 「中央目录结束」记录的签名。
const END_SIGNATURE: u32 = 0x0605_4b50;
/// 中央目录每一项的签名。
const CENTRAL_SIGNATURE: u32 = 0x0201_4b50;
/// 本地文件头的签名。
const LOCAL_SIGNATURE: u32 = 0x0403_4b50;
/// 「中央目录结束」记录不含注释时的长度。
const END_LENGTH: usize = 22;
/// 注释最长 65,535 字节，所以结束记录一定在最后这么多字节里。
const END_SEARCH: usize = END_LENGTH + 65_535;

/// 从 data 的 offset 处读小端 u16；越界时返回 None。
fn u16_at(data: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(offset..offset + 2)?.try_into().ok()?))
}

/// 从 data 的 offset 处读小端 u32；越界时返回 None。
fn u32_at(data: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(offset..offset + 4)?.try_into().ok()?))
}

/// 建一个 `ArchiveInvalid`。
fn invalid(reason: &str) -> UpdateError {
    UpdateError::ArchiveInvalid(reason.to_owned())
}

/// 中央目录里一项的要素。
struct Entry {
    /// 通用标志位。
    flags: u16,
    /// 压缩方式。
    method: u16,
    /// CRC-32。
    crc: u32,
    /// 压缩后的大小。
    compressed: usize,
    /// 解压后的大小。
    size: usize,
    /// 本地文件头的位置。
    local_offset: usize,
}

/// 取出名字为 name 的项的内容。解压后的大小超过 max_size 时也按坏包处理。
pub fn extract(archive: &[u8], name: &str, max_size: usize) -> Result<Vec<u8>, UpdateError> {
    let entry = find_entry(archive, name)?;
    if entry.flags & 1 != 0 {
        return Err(invalid("encrypted entry"));
    }
    if entry.size > max_size {
        return Err(invalid("entry too large"));
    }
    // 本地文件头：名字与扩展字段的长度可以与中央目录不同，数据从它们之后开始。
    let local = entry.local_offset;
    if u32_at(archive, local) != Some(LOCAL_SIGNATURE) {
        return Err(invalid("bad local header"));
    }
    let name_length = usize::from(u16_at(archive, local + 26).ok_or_else(|| invalid("truncated"))?);
    let extra_length = usize::from(u16_at(archive, local + 28).ok_or_else(|| invalid("truncated"))?);
    let start = local + 30 + name_length + extra_length;
    let data = archive
        .get(start..start + entry.compressed)
        .ok_or_else(|| invalid("truncated data"))?;
    let content = match entry.method {
        0 => data.to_vec(),
        8 => miniz_oxide::inflate::decompress_to_vec_with_limit(data, entry.size)
            .map_err(|_| invalid("inflate failed"))?,
        _ => return Err(invalid("unsupported compression")),
    };
    if content.len() != entry.size {
        return Err(invalid("size mismatch"));
    }
    if crc32(&content) != entry.crc {
        return Err(invalid("crc mismatch"));
    }
    Ok(content)
}

/// 在中央目录里找名字正好是 name 的项。
fn find_entry(archive: &[u8], name: &str) -> Result<Entry, UpdateError> {
    // 从后往前找结束记录：注释里也可能出现签名的字节，取最靠后、且注释长度对得上的那个。
    let search_start = archive.len().saturating_sub(END_SEARCH);
    let end = (search_start..=archive.len().saturating_sub(END_LENGTH))
        .rev()
        .find(|&at| {
            u32_at(archive, at) == Some(END_SIGNATURE)
                && u16_at(archive, at + 20)
                    .is_some_and(|comment| at + END_LENGTH + usize::from(comment) == archive.len())
        })
        .ok_or_else(|| invalid("no end of central directory"))?;
    let count = u16_at(archive, end + 10).ok_or_else(|| invalid("truncated"))?;
    let directory = u32_at(archive, end + 16).ok_or_else(|| invalid("truncated"))?;
    // ZIP64 用 0xFFFF 与 0xFFFFFFFF 表示「看 ZIP64 记录」；我们的包远小于 4 GiB，不会用到。
    if count == u16::MAX || directory == u32::MAX {
        return Err(invalid("zip64 not supported"));
    }
    let mut at = directory as usize;
    for _ in 0..count {
        if u32_at(archive, at) != Some(CENTRAL_SIGNATURE) {
            return Err(invalid("bad central directory"));
        }
        let field = |offset: usize| u32_at(archive, at + offset).ok_or_else(|| invalid("truncated"));
        let short = |offset: usize| u16_at(archive, at + offset).ok_or_else(|| invalid("truncated"));
        let name_length = usize::from(short(28)?);
        let extra_length = usize::from(short(30)?);
        let comment_length = usize::from(short(32)?);
        let entry_name = archive
            .get(at + 46..at + 46 + name_length)
            .ok_or_else(|| invalid("truncated"))?;
        if entry_name == name.as_bytes() {
            return Ok(Entry {
                flags: short(8)?,
                method: short(10)?,
                crc: field(16)?,
                compressed: field(20)? as usize,
                size: field(24)? as usize,
                local_offset: field(42)? as usize,
            });
        }
        at += 46 + name_length + extra_length + comment_length;
    }
    Err(UpdateError::ArchiveInvalid(format!("{name} not in archive")))
}

/// PE 头的机器类型（如 x64 的 0x8664、ARM64 的 0xAA64）；不是 PE 文件时返回 None。
pub fn pe_machine(exe: &[u8]) -> Option<u16> {
    // DOS 头以 `MZ` 开头，0x3C 处是 PE 头的位置；PE 头以 `PE\0\0` 开头，紧跟机器类型。
    if exe.get(..2)? != b"MZ" {
        return None;
    }
    let pe = u32_at(exe, 0x3C)? as usize;
    if exe.get(pe..pe + 4)? != b"PE\0\0" {
        return None;
    }
    u16_at(exe, pe + 4)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用的 zip：每项是（名字，内容，是否用 deflate），可以带注释。
    fn zip(entries: &[(&str, &[u8], bool)], comment: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut central = Vec::new();
        for (name, content, deflate) in entries {
            let stored = if *deflate {
                miniz_oxide::deflate::compress_to_vec(content, 6)
            } else {
                content.to_vec()
            };
            let method: u16 = if *deflate { 8 } else { 0 };
            let offset = out.len() as u32;
            // 本地文件头（30 字节）+ 名字 + 数据；扩展字段为空。
            let mut header = Vec::new();
            header.extend_from_slice(&LOCAL_SIGNATURE.to_le_bytes());
            header.extend_from_slice(&[20, 0, 0, 0]);
            header.extend_from_slice(&method.to_le_bytes());
            header.extend_from_slice(&[0; 4]);
            header.extend_from_slice(&crc32(content).to_le_bytes());
            header.extend_from_slice(&(stored.len() as u32).to_le_bytes());
            header.extend_from_slice(&(content.len() as u32).to_le_bytes());
            header.extend_from_slice(&(name.len() as u16).to_le_bytes());
            header.extend_from_slice(&[0, 0]);
            out.extend_from_slice(&header);
            out.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&stored);
            // 中央目录的一项（46 字节）+ 名字。
            central.extend_from_slice(&CENTRAL_SIGNATURE.to_le_bytes());
            central.extend_from_slice(&[20, 0, 20, 0, 0, 0]);
            central.extend_from_slice(&method.to_le_bytes());
            central.extend_from_slice(&[0; 4]);
            central.extend_from_slice(&crc32(content).to_le_bytes());
            central.extend_from_slice(&(stored.len() as u32).to_le_bytes());
            central.extend_from_slice(&(content.len() as u32).to_le_bytes());
            central.extend_from_slice(&(name.len() as u16).to_le_bytes());
            central.extend_from_slice(&[0; 12]);
            central.extend_from_slice(&offset.to_le_bytes());
            central.extend_from_slice(name.as_bytes());
        }
        let directory = out.len() as u32;
        out.extend_from_slice(&central);
        // 结束记录：项数（本卷与总数）、目录大小与位置、注释。
        out.extend_from_slice(&END_SIGNATURE.to_le_bytes());
        out.extend_from_slice(&[0; 4]);
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(central.len() as u32).to_le_bytes());
        out.extend_from_slice(&directory.to_le_bytes());
        out.extend_from_slice(&(comment.len() as u16).to_le_bytes());
        out.extend_from_slice(comment);
        out
    }

    /// 存储与 deflate 两种方式都能取出；别的项与子文件夹里的同名项不算。
    #[test]
    fn extracts_entry() {
        let exe = b"MZ fake exe contents ".repeat(100);
        for deflate in [false, true] {
            let archive = zip(
                &[
                    ("LICENSE.txt", b"GPL", false),
                    ("sub/EVE-O Preview.exe", b"wrong", false),
                    (EXE_NAME, &exe, deflate),
                ],
                b"",
            );
            assert_eq!(extract(&archive, EXE_NAME, 1 << 20).unwrap(), exe);
        }
    }

    /// 带注释（注释里还有结束记录的签名字节）也能找到结束记录。
    #[test]
    fn comment_with_signature() {
        let mut comment = END_SIGNATURE.to_le_bytes().to_vec();
        comment.extend_from_slice(b" trailing comment");
        let archive = zip(&[(EXE_NAME, b"content", true)], &comment);
        assert_eq!(extract(&archive, EXE_NAME, 100).unwrap(), b"content");
    }

    /// 坏包：没有这一项、超过上限、CRC 不符、截断、不是 zip。
    #[test]
    fn rejects_bad_archives() {
        let archive = zip(&[(EXE_NAME, b"content", false)], b"");
        let reason = |result: Result<Vec<u8>, UpdateError>| match result {
            Err(UpdateError::ArchiveInvalid(reason)) => reason,
            other => panic!("应是 ArchiveInvalid：{other:?}"),
        };
        assert_eq!(
            reason(extract(&archive, "other.exe", 100)),
            "other.exe not in archive"
        );
        assert_eq!(reason(extract(&archive, EXE_NAME, 3)), "entry too large");
        // 改掉数据里的一个字节（本地头 30 字节 + 名字之后是数据）：CRC 不符。
        let mut corrupted = archive.clone();
        corrupted[30 + EXE_NAME.len()] ^= 0xFF;
        assert_eq!(reason(extract(&corrupted, EXE_NAME, 100)), "crc mismatch");
        assert_eq!(
            reason(extract(&archive[..10], EXE_NAME, 100)),
            "no end of central directory"
        );
        assert_eq!(
            reason(extract(b"not a zip at all, definitely not", EXE_NAME, 100)),
            "no end of central directory"
        );
        // 加密标志：中央目录那一项的标志位在本地头、名字与数据之后的第 8 个字节。
        let mut encrypted = archive.clone();
        let central = 30 + EXE_NAME.len() + b"content".len();
        encrypted[central + 8] |= 1;
        assert_eq!(reason(extract(&encrypted, EXE_NAME, 100)), "encrypted entry");
    }

    /// PE 头的机器类型：x64 与 ARM64；不是 PE 文件时是 None。
    #[test]
    fn pe_machines() {
        let mut exe = vec![0u8; 0x100];
        exe[..2].copy_from_slice(b"MZ");
        exe[0x3C..0x40].copy_from_slice(&0x80u32.to_le_bytes());
        exe[0x80..0x84].copy_from_slice(b"PE\0\0");
        exe[0x84..0x86].copy_from_slice(&0x8664u16.to_le_bytes());
        assert_eq!(pe_machine(&exe), Some(0x8664));
        exe[0x84..0x86].copy_from_slice(&0xAA64u16.to_le_bytes());
        assert_eq!(pe_machine(&exe), Some(0xAA64));
        exe[0x80] = b'X';
        assert_eq!(pe_machine(&exe), None);
        assert_eq!(pe_machine(b"MZ"), None);
        assert_eq!(pe_machine(b"ELF"), None);
    }
}
