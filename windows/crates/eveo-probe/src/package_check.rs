// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布包的自检（`eveo-probe package-check`，docs/windows/packaging.md 第 2 节）：发布前在 CI 的 Windows 运行器上，
// 用应用自己的代码核对刚打好的 zip，保证已安装的旧版本能装上它。
//
// 核对的内容与应用安装前做的相同：
// 1. 用 eveo_core::update::archive::extract 取出 `EVE-O Preview.exe`（存储或 deflate、CRC 相符）；
// 2. zip 里正好是发布契约规定的三个文件（exe、LICENSE.txt、README.txt），都在根目录；
// 3. 解出的 exe 的版本资源：ProductVersion 与 BuildLabel 都等于要发布的版本；
// 4. PE 头的机器类型是 x64（发布包只有 x64）；
// 5. 有内置的更新公钥时（--public-key），exe 里能找到它（正式构建一定带着公钥，否则装上之后再也不能自动更新）。
// 任何一项不符时打印原因并以 1 退出。

//! 发布包的自检。

use std::path::Path;

use eveo_core::update::archive::{self, EXE_NAME};

use crate::option;

/// 发布包里应有的文件。
const EXPECTED_ENTRIES: [&str; 3] = [EXE_NAME, "LICENSE.txt", "README.txt"];
/// x64 的机器类型。
const X64: u16 = 0x8664;
/// 解出的 exe 的上限：与应用的下载上限相同。
const MAX_EXE: usize = 128 * 1024 * 1024;

/// 入口：`package-check --zip <路径> --version <版本> [--public-key <64 位十六进制>]`。
pub fn run(args: &[String]) -> i32 {
    let (Some(zip), Some(version)) = (option(args, "--zip"), option(args, "--version")) else {
        eprintln!("用法：eveo-probe package-check --zip <路径> --version <版本> [--public-key <十六进制>]");
        return 2;
    };
    match check(Path::new(zip), version, option(args, "--public-key")) {
        Ok(()) => {
            println!("发布包核对通过：{version}");
            0
        }
        Err(problem) => {
            eprintln!("发布包核对失败：{problem}");
            1
        }
    }
}

/// 逐项核对；返回第一个问题。
fn check(zip: &Path, version: &str, public_key: Option<&str>) -> Result<(), String> {
    let data = std::fs::read(zip).map_err(|e| format!("读不了 zip：{e}"))?;
    let mut names = entry_names(&data).ok_or("zip 的中央目录读不了")?;
    names.sort();
    let mut expected: Vec<String> = EXPECTED_ENTRIES.iter().map(|s| (*s).to_owned()).collect();
    expected.sort();
    if names != expected {
        return Err(format!("zip 里的文件是 {names:?}，应为 {expected:?}"));
    }
    let exe = archive::extract(&data, EXE_NAME, MAX_EXE).map_err(|e| format!("解不出 exe：{e:?}"))?;
    if archive::pe_machine(&exe) != Some(X64) {
        return Err("exe 不是 x64".into());
    }
    // 版本资源要从文件读：写到临时目录，读完删掉。
    let temp = std::env::temp_dir().join(format!("eveo-package-check-{}.exe", std::process::id()));
    std::fs::write(&temp, &exe).map_err(|e| format!("写临时文件失败：{e}"))?;
    let info = eveo_platform_win::update::exe_version(&temp);
    let _ = std::fs::remove_file(&temp);
    if info.product_version.as_deref() != Some(version) || info.build_label.as_deref() != Some(version) {
        return Err(format!(
            "exe 的版本资源是 ProductVersion={:?}、BuildLabel={:?}，应为 {version}",
            info.product_version, info.build_label
        ));
    }
    // 公钥以十六进制文字编进 exe（option_env! 的字符串常量），直接在字节里找。
    if let Some(key) = public_key {
        let key = key.trim().to_ascii_lowercase();
        if key.len() != 64
            || !exe
                .windows(key.len())
                .any(|w| w.eq_ignore_ascii_case(key.as_bytes()))
        {
            return Err("exe 里没有找到更新公钥".into());
        }
    }
    Ok(())
}

/// 中央目录里各项的名字。只读我们自己的打包脚本写出的 zip：找到目录结束记录，按项数逐个读。
fn entry_names(data: &[u8]) -> Option<Vec<String>> {
    let u16_at = |at: usize| Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?));
    let u32_at = |at: usize| Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?));
    // 目录结束记录在末尾（打包脚本不写注释，但仍向前找，容忍注释）。
    let end = (0..=data.len().checked_sub(22)?)
        .rev()
        .find(|&at| u32_at(at) == Some(0x0605_4b50))?;
    let count = usize::from(u16_at(end + 10)?);
    let mut at = usize::try_from(u32_at(end + 16)?).ok()?;
    let mut names = Vec::with_capacity(count);
    for _ in 0..count {
        if u32_at(at)? != 0x0201_4b50 {
            return None;
        }
        let name_len = usize::from(u16_at(at + 28)?);
        let extra_len = usize::from(u16_at(at + 30)?);
        let comment_len = usize::from(u16_at(at + 32)?);
        let name = data.get(at + 46..at + 46 + name_len)?;
        names.push(String::from_utf8_lossy(name).into_owned());
        at += 46 + name_len + extra_len + comment_len;
    }
    Some(names)
}
