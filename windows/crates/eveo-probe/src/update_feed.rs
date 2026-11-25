// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本机测试更新源（`eveo-probe update-feed`）：在真机上走完整的自动更新流程（检查 → 下载 → 验签 → 核对 →
// 替换 → 重新启动 → 确认或回滚），不碰 GitHub，也不需要正式的签名私钥。
//
// 做的事：
// 1. 把给定的 exe 以 `EVE-O Preview.exe` 的名字打进一个 zip（存储方式，不压缩），文件名按发布脚本的规则；
// 2. 每次运行现生成一把一次性的 ed25519 密钥（只在内存里，进程结束即丢），给 `SHA256SUMS.txt` 签名，
//    公钥的十六进制打印到标准输出并写进 `public_key.txt`，交给应用的环境变量 EVEO_UPDATE_TEST_PUBLIC_KEY；
// 3. 写一份更新清单 `update-manifest.json`（docs/update-manifest.md 的格式，用同一把一次性密钥签名，
//    latest.windows 是给定的版本），文件的地址与发布页都指向本机同一个端口；
// 4. 在 127.0.0.1 上提供这些文件，直到时限到了。每个请求打印一行（方法、路径、状态、字节数）。
//
// 清单带 ETag，带 If-None-Match 且相同时回 304（1.5.0 起应用不再发这个头）。`--rate-kib` 限制 zip 的速度，
// 用来看进度条与测试取消。这是测试工具：只监听回环地址，只提供目录里那几个文件，别的路径一律 404。

//! 本机测试更新源。

use std::collections::hash_map::RandomState;
use std::fs;
use std::hash::{BuildHasher, Hasher};
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ed25519_dalek::{Signer, SigningKey};
use eveo_core::support::crc::crc32;
use eveo_core::update::checksums::sha256_hex;
use eveo_core::update::feed::{CHECKSUMS_NAME, SIGNATURE_NAME, archive_name};
use eveo_core::update::manifest::{MANIFEST_NAME, SIGNING_PREFIX};

use crate::option;

/// zip 里 exe 的名字（与 eveo_core::update::archive::EXE_NAME 相同）。
const EXE_NAME: &str = "EVE-O Preview.exe";
/// 清单的文件名（应用的测试地址指向它）。
const LIST_NAME: &str = MANIFEST_NAME;
/// 清单的 ETag（内容在一次运行里不变）。
const LIST_ETAG: &str = "\"eveo-test-feed\"";
/// 默认运行多久（秒）。
const DEFAULT_SECONDS: u64 = 1800;
/// 限速时每次发送的块大小。
const CHUNK: usize = 64 * 1024;

/// 入口：`update-feed --exe <路径> --version <版本> --dir <目录> --port <端口> [--rate-kib <KiB/s>] [--seconds <秒>]`。
pub fn run(args: &[String]) -> i32 {
    let (Some(exe), Some(version), Some(dir), Some(port)) = (
        option(args, "--exe"),
        option(args, "--version"),
        option(args, "--dir"),
        option(args, "--port").and_then(|p| p.parse::<u16>().ok()),
    ) else {
        eprintln!(
            "用法：eveo-probe update-feed --exe <路径> --version <版本> --dir <目录> --port <端口> [--rate-kib <KiB/s>] [--seconds <秒>]"
        );
        return 2;
    };
    // 速率与时限都可选：不限速时 zip 一次发完；时限到了监听退出，RC 会话结束后不会留下一直开着的端口。
    let rate = option(args, "--rate-kib").and_then(|r| r.parse::<u64>().ok());
    let seconds = option(args, "--seconds")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(DEFAULT_SECONDS);
    let dir = PathBuf::from(dir);
    match prepare(Path::new(exe), version, &dir, port) {
        Ok(public_key) => println!("public_key={public_key}"),
        Err(error) => {
            eprintln!("准备测试源失败：{error}");
            return 1;
        }
    }
    println!("feed=http://127.0.0.1:{port}/{LIST_NAME}");
    serve(&dir, port, rate, Duration::from_secs(seconds));
    0
}

/// 标准 base64（带填充），给清单的信封用。
fn base64(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        // 三个字节拼成 24 位，切成四个 6 位；不足三个字节时用 `=` 补齐。
        let bytes = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let value = (u32::from(bytes[0]) << 16) | (u32::from(bytes[1]) << 8) | u32::from(bytes[2]);
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(char::from(ALPHABET[((value >> (18 - 6 * index)) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// 写 zip、校验和、签名与清单，返回公钥的十六进制。
fn prepare(exe: &Path, version: &str, dir: &Path, port: u16) -> std::io::Result<String> {
    fs::create_dir_all(dir)?;
    let exe_bytes = fs::read(exe)?;
    let zip_name = archive_name(version);
    // 用存储方式：测试只关心流程，不压缩让 zip 与 exe 一样大，下载进度也更容易观察。
    let zip = stored_zip(EXE_NAME, &exe_bytes);
    fs::write(dir.join(&zip_name), &zip)?;
    // 校验和文件与 sha256sum 的文本模式输出相同：十六进制、两个空格、文件名。
    let sums = format!("{}  {zip_name}\n", sha256_hex(&zip));
    fs::write(dir.join(CHECKSUMS_NAME), &sums)?;
    let key = SigningKey::from_bytes(&random_seed());
    // 签名文件用原始的 64 字节（应用也接受 base64，发布脚本用那一种）。
    fs::write(dir.join(SIGNATURE_NAME), key.sign(sums.as_bytes()).to_bytes())?;
    let public_key = hex(&key.verifying_key().to_bytes());
    fs::write(dir.join("public_key.txt"), &public_key)?;
    // 文件与发布页必须与清单同源（应用在测试地址下只接受同源的地址，重定向也只跟同源），
    // 所以都写成同一个端口下的路径。大小与 SHA-256 与实际文件一致：应用会逐一核对。
    let base = format!("http://127.0.0.1:{port}");
    let signature_bytes = fs::read(dir.join(SIGNATURE_NAME))?;
    let file = |name: &str, data: &[u8]| {
        serde_json::json!({
            "name": name,
            "size": data.len(),
            "sha256": sha256_hex(data),
            "urls": [format!("{base}/{name}")],
        })
    };
    // 说明不写语言标记，应用按「没有本语言的块时用全文」显示。序号取现在的秒数：每次运行都比上一次大。
    let sequence = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let payload = serde_json::json!({
        "schema": 1,
        "sequence": sequence,
        "generatedAt": "2026-11-25T00:00:00Z",
        "latest": {
            "windows": {
                "version": version,
                "tag": format!("v{version}"),
                "pageURL": format!("{base}/release"),
                "files": [
                    file(&zip_name, &zip),
                    file(CHECKSUMS_NAME, sums.as_bytes()),
                    file(SIGNATURE_NAME, &signature_bytes),
                ],
            }
        },
        "releases": [{
            "version": version,
            "platforms": ["windows"],
            "notes": format!("## Test build {version}\n\n- Served by eveo-probe update-feed.\n- Signed with a one-time test key."),
        }],
    });
    let payload = serde_json::to_vec(&payload)?;
    // 签名的消息是前缀接上正文，与发布流程相同。
    let mut message = SIGNING_PREFIX.to_vec();
    message.extend_from_slice(&payload);
    let envelope = serde_json::json!({
        "format": 1,
        "payload": base64(&payload),
        "signature": base64(&key.sign(&message).to_bytes()),
    });
    fs::write(dir.join(LIST_NAME), serde_json::to_vec(&envelope)?)?;
    Ok(public_key)
}

/// 一次性密钥的种子：四个 RandomState 的哈希值拼成 32 字节。
///
/// RandomState 的密钥来自系统的随机数（每个线程取一次，之后递增），对一把只活几十分钟、
/// 只给本机测试源用的密钥足够；这样不用为测试工具引入随机数的依赖。
fn random_seed() -> [u8; 32] {
    let mut seed = [0u8; 32];
    for (index, chunk) in seed.chunks_mut(8).enumerate() {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_usize(index);
        hasher.write_u128(Instant::now().elapsed().as_nanos());
        chunk.copy_from_slice(&hasher.finish().to_le_bytes());
    }
    seed
}

/// 小写十六进制。
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// 只含一个文件的 zip（存储方式）：本地文件头、数据、中央目录与目录结尾记录。
fn stored_zip(name: &str, data: &[u8]) -> Vec<u8> {
    let crc = crc32(data);
    // 测试用的 exe 远小于 4 GiB，不需要 ZIP64；万一超出就截断成上限，应用会当坏包拒绝。
    let size = u32::try_from(data.len()).unwrap_or(u32::MAX);
    let name_len = u16::try_from(name.len()).unwrap_or(u16::MAX);
    let mut out = Vec::with_capacity(data.len() + 200);
    // 本地文件头：签名、需要的版本 20、标志 0、方式 0（存储）、时间日期 0、CRC、两个大小、名字长度、扩展长度 0。
    out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
    for value in [20u16, 0, 0, 0, 0] {
        out.extend_from_slice(&value.to_le_bytes());
    }
    for value in [crc, size, size] {
        out.extend_from_slice(&value.to_le_bytes());
    }
    out.extend_from_slice(&name_len.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(name.as_bytes());
    out.extend_from_slice(data);
    let directory_at = u32::try_from(out.len()).unwrap_or(u32::MAX);
    // 中央目录项：签名、制作版本 20、需要的版本 20、标志、方式、时间、日期、CRC、两个大小、名字长度、
    // 扩展、注释、磁盘号、内部属性（各 0），外部属性 0，本地文件头的位置 0。
    out.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
    for value in [20u16, 20, 0, 0, 0, 0] {
        out.extend_from_slice(&value.to_le_bytes());
    }
    for value in [crc, size, size] {
        out.extend_from_slice(&value.to_le_bytes());
    }
    out.extend_from_slice(&name_len.to_le_bytes());
    for value in [0u16, 0, 0, 0] {
        out.extend_from_slice(&value.to_le_bytes());
    }
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(name.as_bytes());
    let directory_size = u32::try_from(out.len()).unwrap_or(u32::MAX) - directory_at;
    // 目录结尾：签名、两个磁盘号 0、两个项数 1、目录大小、目录位置、注释长度 0。
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    for value in [0u16, 0, 1, 1] {
        out.extend_from_slice(&value.to_le_bytes());
    }
    out.extend_from_slice(&directory_size.to_le_bytes());
    out.extend_from_slice(&directory_at.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

/// 提供目录里的文件，直到时限到了。每个连接一个线程（下载 zip 时不挡住别的请求）。
fn serve(dir: &Path, port: u16, rate: Option<u64>, limit: Duration) {
    // 只绑回环地址：同一局域网的其他机器连不上，测试源不会意外地对外提供文件。
    // 端口被占用时直接报错退出，由调用方换一个端口重试。
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("监听 127.0.0.1:{port} 失败：{error}");
            return;
        }
    };
    // 非阻塞地等连接，好在时限到了时退出。
    // 每 50 毫秒看一次有没有新连接，代价可以忽略；测试源最多跑半小时。
    let _ = listener.set_nonblocking(true);
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        match listener.accept() {
            Ok((stream, _)) => {
                let dir = dir.to_path_buf();
                std::thread::spawn(move || handle(stream, &dir, rate));
            }
            Err(_) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
    println!("时限到了，测试源退出");
}

/// 处理一个请求：只认 GET 与目录里那几个文件名。
fn handle(stream: TcpStream, dir: &Path, rate: Option<u64>) {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    // 请求很小（一行请求行加几行头），按行读即可；读超时防止半开的连接让线程一直挂着。
    let mut reader = BufReader::new(&stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() {
        return;
    }
    // 读完请求头，记下 If-None-Match。
    let mut if_none_match = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" || line == "\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.trim().eq_ignore_ascii_case("if-none-match")
        {
            if_none_match = Some(value.trim().to_owned());
        }
    }
    let mut parts = request_line.split_whitespace();
    let (method, path) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    let name = path.trim_start_matches('/');
    // 只提供这几个名字：不拼任意路径，`..` 之类根本不会碰到文件系统。
    let allowed = [LIST_NAME, CHECKSUMS_NAME, SIGNATURE_NAME].contains(&name)
        || (name.starts_with("EVE-O-Preview-")
            && name.ends_with("-windows-x64.zip")
            && !name.contains(['/', '\\']));
    let mut stream = stream;
    // 发布页（release）只是一段固定的 HTML：失败时应用会提供「打开发布页」，点了能看到浏览器打开它即可。
    let (status, body) = if method != "GET" {
        (405, Vec::new())
    } else if name == "release" {
        (
            200,
            b"<html><body>EVE-O Preview test release</body></html>".to_vec(),
        )
    } else if !allowed {
        (404, Vec::new())
    } else if name == LIST_NAME && if_none_match.as_deref() == Some(LIST_ETAG) {
        (304, Vec::new())
    } else {
        match fs::read(dir.join(name)) {
            Ok(bytes) => (200, bytes),
            Err(_) => (404, Vec::new()),
        }
    };
    let reason = match status {
        200 => "OK",
        304 => "Not Modified",
        404 => "Not Found",
        _ => "Method Not Allowed",
    };
    let mut head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    if name == LIST_NAME {
        head.push_str(&format!(
            "ETag: {LIST_ETAG}\r\nContent-Type: application/json\r\n"
        ));
    }
    head.push_str("\r\n");
    // 每个请求一行日志：测试时据此核对应用发了哪些请求、顺序对不对（先列表，再校验和与签名，最后 zip）。
    println!("{method} {path} -> {status} ({} 字节)", body.len());
    if stream.write_all(head.as_bytes()).is_err() {
        return;
    }
    // zip 限速：每块之后按速率睡一会儿；客户端取消（断开）时写失败，提前结束。
    // 只限 zip：列表、校验和与签名都很小，限速只会拖慢测试，没有可观察的东西。
    let throttle = rate.filter(|_| name.ends_with(".zip")).filter(|&kib| kib > 0);
    match throttle {
        Some(kib) => {
            let pause = Duration::from_secs_f64(CHUNK as f64 / (kib as f64 * 1024.0));
            for chunk in body.chunks(CHUNK) {
                if stream.write_all(chunk).is_err() {
                    println!("{path}：客户端断开");
                    return;
                }
                std::thread::sleep(pause);
            }
        }
        None => {
            let _ = stream.write_all(&body);
        }
    }
    let _ = stream.flush();
}

#[cfg(test)]
mod tests {
    use eveo_core::update::checksums::base64_decode;

    use super::base64;

    /// 编码后能被应用的解码还原，长度不是 3 的倍数时也一样。
    #[test]
    fn base64_round_trip() {
        for data in [
            &b""[..],
            b"a",
            b"ab",
            b"abc",
            b"abcd",
            &[0xff, 0x00, 0x7f, 0x80, 0x01],
        ] {
            assert_eq!(base64_decode(&base64(data)).as_deref(), Some(data));
        }
        assert_eq!(base64(b"hi"), "aGk=");
    }
}
