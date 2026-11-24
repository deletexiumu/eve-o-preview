// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新包的核对（docs/windows/architecture.md 6.2、6.3 节）：`SHA256SUMS.txt` 的解析（规则移植 macOS 的 ChecksumList）、
// 它的 ed25519 签名的核对，以及 SHA-256 的计算。
//
// 校验和文件是 `sha256sum` 的输出：每行 64 位十六进制、分隔、文件名。分隔是两个空格（文本模式）或一个空格加 `*`
// （二进制模式）。空行与 `#` 开头的行跳过，行尾的回车去掉；十六进制不区分大小写，结果转成小写；
// 文件名是分隔之后到行尾的全部内容，可以含空格，含 `/` 或 `\` 时这一行无效。任何一行无效，或同一个文件名
// 出现两个不同的值，整个文件无效；相同的重复行可以接受。
//
// 签名文件 `SHA256SUMS.txt.sig` 是对校验和文件原始字节的 ed25519 签名：64 字节的原始签名，或它的 base64
// （一行，结尾可以有换行），发布脚本用后一种。核对用严格模式（拒绝可塑的签名与弱公钥）。
// 公钥由调用方给出：正式构建内置在应用里，测试地址下可以用环境变量另给一把测试公钥。

//! 校验和文件、签名与 SHA-256。

use std::collections::HashMap;

use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

use super::models::UpdateError;

/// 一个 SHA-256 的十六进制位数。
const DIGEST_LENGTH: usize = 64;
/// 校验和文件的大小上限：64 KiB。
pub const MAX_CHECKSUMS_BYTES: usize = 65_536;
/// 签名文件的大小上限：1 KiB（base64 的签名约 90 字节）。
pub const MAX_SIGNATURE_BYTES: usize = 1_024;

/// 解析整个校验和文件，返回「文件名 → 小写十六进制」。文件无效时返回 `ChecksumListInvalid`。
pub fn parse(text: &str) -> Result<HashMap<String, String>, UpdateError> {
    let mut result = HashMap::new();
    for raw in text.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (name, digest) = entry(line).ok_or(UpdateError::ChecksumListInvalid)?;
        if result.get(&name).is_some_and(|existing| existing != &digest) {
            return Err(UpdateError::ChecksumListInvalid);
        }
        result.insert(name, digest);
    }
    Ok(result)
}

/// 按文件名完全相等查找期望的 SHA-256。文件无效时返回 `ChecksumListInvalid`，找不到时返回 `ChecksumEntryMissing`。
pub fn expected_hash(file_name: &str, text: &str) -> Result<String, UpdateError> {
    parse(text)?
        .remove(file_name)
        .ok_or_else(|| UpdateError::ChecksumEntryMissing(file_name.to_owned()))
}

/// 解析一行，返回（文件名，小写十六进制）；格式不对时返回 None。
fn entry(line: &str) -> Option<(String, String)> {
    // 64 位十六进制 + 2 个分隔字符 + 至少 1 个字符的文件名；前 66 个字节都应是 ASCII。
    let digest = line.get(..DIGEST_LENGTH)?;
    if !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let separator = line.get(DIGEST_LENGTH..DIGEST_LENGTH + 2)?;
    if separator != "  " && separator != " *" {
        return None;
    }
    let name = &line[DIGEST_LENGTH + 2..];
    if name.is_empty() || name.contains(['/', '\\']) {
        return None;
    }
    Some((name.to_owned(), digest.to_ascii_lowercase()))
}

/// 核对校验和文件的签名。public_key 是 32 字节的 ed25519 公钥；signature 是签名文件的内容。
/// 签名文件格式不对、公钥无效或签名不符时返回 `SignatureInvalid`。
pub fn verify_signature(
    checksums: &[u8],
    signature: &[u8],
    public_key: &[u8; 32],
) -> Result<(), UpdateError> {
    // 三步都失败时报同一个错误：签名文件坏了、公钥坏了与签名不符，对用户来说都是「这个更新包不可信」。
    let bytes = signature_bytes(signature).ok_or(UpdateError::SignatureInvalid)?;
    let key = VerifyingKey::from_bytes(public_key).map_err(|_| UpdateError::SignatureInvalid)?;
    key.verify_strict(checksums, &Signature::from_bytes(&bytes))
        .map_err(|_| UpdateError::SignatureInvalid)
}

/// 签名文件的 64 字节：原始的 64 字节，或去掉首尾空白后的 base64（标准字母表，带填充）。
fn signature_bytes(content: &[u8]) -> Option<[u8; 64]> {
    if content.len() > MAX_SIGNATURE_BYTES {
        return None;
    }
    // 正好 64 字节时按原始签名；base64 的签名是 88 个字符，不会与它混淆。
    if let Ok(raw) = <[u8; 64]>::try_from(content) {
        return Some(raw);
    }
    let text = std::str::from_utf8(content).ok()?.trim();
    base64_decode(text)?.try_into().ok()
}

/// 标准 base64（`A–Z a–z 0–9 + /`，`=` 填充）的解码；长度不是 4 的倍数或有别的字符时返回 None。
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    /// 一个字符的 6 位值。
    fn value(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some(u32::from(c - b'A')),
            b'a'..=b'z' => Some(u32::from(c - b'a') + 26),
            b'0'..=b'9' => Some(u32::from(c - b'0') + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes = text.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let chunks = bytes.len() / 4;
    for (index, chunk) in bytes.chunks(4).enumerate() {
        // 只有最后一组可以带填充：`xx==` 解出 1 字节，`xxx=` 解出 2 字节。
        let padding = chunk.iter().rev().take_while(|&&c| c == b'=').count();
        if padding > 2 || (padding > 0 && index + 1 != chunks) {
            return None;
        }
        // 4 个字符（去掉填充）拼成最多 24 位，再按填充个数左移补齐。
        let mut group = 0u32;
        for &c in &chunk[..4 - padding] {
            group = (group << 6) | value(c)?;
        }
        group <<= 6 * padding as u32;
        let decoded = [(group >> 16) as u8, (group >> 8) as u8, group as u8];
        out.extend_from_slice(&decoded[..3 - padding]);
    }
    Some(out)
}

/// 增量计算 SHA-256（下载时边收边算）。
#[derive(Default)]
pub struct Sha256Hasher(Sha256);

impl Sha256Hasher {
    /// 加入一段数据。
    pub fn update(&mut self, data: &[u8]) {
        self.0.update(data);
    }

    /// 结束并返回小写十六进制。
    pub fn finish_hex(self) -> String {
        self.0.finalize().iter().map(|b| format!("{b:02x}")).collect()
    }
}

/// 一段数据的 SHA-256，小写十六进制。
pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256Hasher::default();
    hasher.update(data);
    hasher.finish_hex()
}

/// 64 位十六进制的公钥换成 32 字节；格式不对时返回 None。环境变量里的测试公钥用它解析。
pub fn public_key_from_hex(text: &str) -> Option<[u8; 32]> {
    let text = text.trim();
    if text.len() != 64 || !text.is_ascii() {
        return None;
    }
    let mut key = [0u8; 32];
    for (index, byte) in key.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).ok()?;
    }
    Some(key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    /// 发布脚本生成的校验和文件的格式（文本模式，两个空格）。
    const SAMPLE: &str = "00cbbd0ddbda2762798f7009838ed34ca1f12b93965813c7df22943bc62166d1  EVE-O-Preview-0.9.0-windows-x64.zip\n\
407f3ae627dafcf01abdcc6632da77b6a2ab73d22077e5c494a90c66329b5fb9  eve-o-preview-0.9.0-windows-source.zip\n";

    /// 用 c 重复填满的 64 位十六进制。
    fn digest(c: char) -> String {
        c.to_string().repeat(64)
    }

    /// 两种分隔、CRLF、大写十六进制、注释与空行、带空格的文件名都能解析。
    #[test]
    fn parses_variants() {
        let (a, b) = (digest('a'), digest('b'));
        // 注释行、空行、CRLF 的行尾、二进制模式的 `*` 与大写十六进制混在一个文件里。
        let text = format!("# comment\n\n{a}  one.zip\r\n{} *two.zip\n", b.to_uppercase());
        let entries = parse(&text).expect("有效");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries["one.zip"], a);
        assert_eq!(entries["two.zip"], b);
        assert_eq!(
            parse(&format!("{a}  EVE-O Preview 0.9.0.zip")).unwrap()["EVE-O Preview 0.9.0.zip"],
            a
        );
        assert!(parse("").expect("空文件有效").is_empty());
    }

    /// 无效的行使整个文件无效；同名不同值无效，同名同值可以。
    #[test]
    fn rejects_invalid_lines() {
        let a = digest('a');
        // 每一种坏行：少一位、非十六进制、一个空格、制表符、没有文件名、含路径分隔符、不是校验和、多字节字符。
        for line in [
            format!("{}  x.zip", &a[..63]),
            format!("{}g  x.zip", &a[..63]),
            format!("{a} x.zip"),
            format!("{a}\tx.zip"),
            format!("{a}  "),
            format!("{a}  dir/x.zip"),
            format!("{a}  dir\\x.zip"),
            "junk".to_owned(),
            format!("é{}  x.zip", &a[..62]),
        ] {
            assert_eq!(
                parse(&format!("{a}  ok.zip\n{line}\n")),
                Err(UpdateError::ChecksumListInvalid),
                "{line}"
            );
        }
        let b = digest('b');
        assert_eq!(
            parse(&format!("{a}  x.zip\n{b}  x.zip\n")),
            Err(UpdateError::ChecksumListInvalid)
        );
        assert_eq!(
            parse(&format!("{a}  x.zip\n{} *x.zip\n", a.to_uppercase()))
                .unwrap()
                .len(),
            1
        );
    }

    /// 按文件名完全相等查找，找不到时报缺的文件名。
    #[test]
    fn expected_hash_lookup() {
        assert_eq!(
            expected_hash("EVE-O-Preview-0.9.0-windows-x64.zip", SAMPLE).unwrap(),
            "00cbbd0ddbda2762798f7009838ed34ca1f12b93965813c7df22943bc62166d1"
        );
        assert_eq!(
            expected_hash("eve-o-preview-0.9.0-windows-x64.zip", SAMPLE),
            Err(UpdateError::ChecksumEntryMissing(
                "eve-o-preview-0.9.0-windows-x64.zip".into()
            ))
        );
        assert_eq!(expected_hash("x", "junk"), Err(UpdateError::ChecksumListInvalid));
    }

    /// 签名：原始 64 字节与 base64 都能核对；改一个字节、换公钥、坏的签名文件都不通过。
    #[test]
    fn signatures() {
        // 固定的测试私钥，不是任何发布用的密钥。
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let public = signing.verifying_key().to_bytes();
        let signature = signing.sign(SAMPLE.as_bytes()).to_bytes();
        assert_eq!(verify_signature(SAMPLE.as_bytes(), &signature, &public), Ok(()));
        let encoded = format!("{}\n", base64_encode(&signature));
        assert_eq!(
            verify_signature(SAMPLE.as_bytes(), encoded.as_bytes(), &public),
            Ok(())
        );
        // 校验和文件改一个比特、或换一把公钥，都不通过。
        let mut tampered = SAMPLE.as_bytes().to_vec();
        tampered[0] ^= 1;
        assert_eq!(
            verify_signature(&tampered, &signature, &public),
            Err(UpdateError::SignatureInvalid)
        );
        let other = SigningKey::from_bytes(&[8u8; 32]).verifying_key().to_bytes();
        assert_eq!(
            verify_signature(SAMPLE.as_bytes(), &signature, &other),
            Err(UpdateError::SignatureInvalid)
        );
        // 签名文件本身坏了：不是 base64、空、少一个字节、超过大小上限。
        for bad in [&b"not base64!"[..], &b""[..], &signature[..63], &[b'A'; 2000][..]] {
            assert_eq!(
                verify_signature(SAMPLE.as_bytes(), bad, &public),
                Err(UpdateError::SignatureInvalid)
            );
        }
    }

    /// base64 的解码：各种填充；非法字符、中间的填充、长度不对时失败。
    #[test]
    fn base64() {
        // RFC 4648 的例子：没有填充、一个 `=`、两个 `=`；`+` 与 `/` 的值。
        assert_eq!(base64_decode("TWFu").unwrap(), b"Man");
        assert_eq!(base64_decode("TWE=").unwrap(), b"Ma");
        assert_eq!(base64_decode("TQ==").unwrap(), b"M");
        assert_eq!(base64_decode("+/+/").unwrap(), [0xfb, 0xff, 0xbf]);
        for bad in ["", "TWF", "TQ=A", "TQ==TWFu", "T===", "TW-u", "TW u"] {
            assert!(base64_decode(bad).is_none(), "{bad}");
        }
        // 0～255 全部字节编码再解码，原样还原。
        let all: Vec<u8> = (0..=255).collect();
        assert_eq!(base64_decode(&base64_encode(&all)).unwrap(), all);
    }

    /// SHA-256 的已知值；分段计算与一次计算相同；十六进制公钥的解析。
    #[test]
    fn sha256_and_key() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let mut hasher = Sha256Hasher::default();
        hasher.update(b"a");
        hasher.update(b"bc");
        assert_eq!(hasher.finish_hex(), sha256_hex(b"abc"));
        // 公钥的十六进制允许大写与首尾空白；长度或字符不对时失败。
        let key = [0xabu8; 32];
        let hex: String = key.iter().map(|b| format!("{b:02X}")).collect();
        assert_eq!(public_key_from_hex(&format!(" {hex}\n")), Some(key));
        assert_eq!(public_key_from_hex(&hex[..62]), None);
        assert_eq!(public_key_from_hex(&"zz".repeat(32)), None);
    }

    /// 测试用的 base64 编码（标准字母表，带填充）。
    fn base64_encode(data: &[u8]) -> String {
        const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        // 每 3 个字节拼成 24 位，切成 4 个 6 位；不足 3 个字节的最后一组用 `=` 补齐。
        for chunk in data.chunks(3) {
            let group =
                chunk.iter().fold(0u32, |acc, &b| (acc << 8) | u32::from(b)) << (8 * (3 - chunk.len()));
            for index in 0..4 {
                if index <= chunk.len() {
                    out.push(ALPHABET[(group >> (18 - 6 * index)) as usize & 63] as char);
                } else {
                    out.push('=');
                }
            }
        }
        out
    }
}
