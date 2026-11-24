// SPDX-License-Identifier: GPL-3.0-or-later
//
// 生成自动更新的签名密钥（docs/windows/packaging.md 第 3 节）。在维护者自己的电脑上运行一次：
//
//     cd windows && cargo run -q -p eveo-core --example update_signing_key -- <私钥文件>
//
// - 从系统的随机数源（/dev/urandom；Windows 上用 BCryptGenRandom 太麻烦，这个工具只在 macOS 与 Linux 上用）
//   读 32 字节作为 ed25519 的私钥种子，写成 64 位十六进制到给定的文件，权限 600。文件已存在时拒绝覆盖，
//   免得把已经在用的私钥冲掉（换私钥意味着旧版本再也验不过新包）。
// - 公钥的 64 位十六进制打印到标准输出：它要提交到 windows/packaging/update-public-key.txt，打进正式构建。
// - 私钥文件的内容（一行十六进制）放进仓库的 Actions secret `WINDOWS_UPDATE_SIGNING_KEY`，并离线备份；
//   放好之后删掉本机的文件。私钥不能提交、不能发到聊天里、不能写进日志。

//! 生成自动更新的 ed25519 签名密钥。

use std::io::{Read, Write};

use ed25519_dalek::SigningKey;

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("用法：cargo run -q -p eveo-core --example update_signing_key -- <私钥文件>");
        std::process::exit(2);
    };
    // 种子来自系统的随机数源；读不满 32 字节时退出，不用弱随机数凑合。
    let mut seed = [0u8; 32];
    if let Err(error) = std::fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut seed)) {
        eprintln!("读系统随机数失败：{error}");
        std::process::exit(1);
    }
    let key = SigningKey::from_bytes(&seed);
    let hex = |bytes: &[u8]| bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    // create_new：文件已存在时失败，不覆盖已有的私钥。
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // 只有本人能读写。
        options.mode(0o600);
    }
    let written = options
        .open(&path)
        .and_then(|mut file| writeln!(file, "{}", hex(&seed)));
    if let Err(error) = written {
        eprintln!("写私钥文件失败（已存在时不会覆盖）：{error}");
        std::process::exit(1);
    }
    // 标准输出只有公钥，方便直接重定向到 update-public-key.txt。
    println!("{}", hex(&key.verifying_key().to_bytes()));
}
