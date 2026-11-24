// SPDX-License-Identifier: GPL-3.0-or-later
//
// 把应用图标与版本信息编进 exe 的资源。
// - 图标：app.rc 里的 assets/app.ico（编号 1，托盘也从这里加载）。
// - 版本信息（VERSIONINFO）：文件版本与产品版本取 Cargo 的版本号；字符串表另有 BuildLabel，
//   取环境变量 EVEO_BUILD_LABEL（打包时给出，如 `0.9.1-ci.42`），没有时与版本号相同。
//   自动更新解出新 exe 后读这两项，核对它就是要装的版本（eveo_platform_win::update::exe_version）。
// 做法：读 app.rc，把图标的相对路径换成绝对路径，再接上生成的 VERSIONINFO，写到 OUT_DIR 里编译。
// 只在 Windows 主机上为 Windows 目标编译资源：需要 Windows SDK 的 rc.exe。在 Linux 上交叉做 clippy 检查时跳过，
// 那时不产出可运行的 exe，缺资源没有关系。

//! eveo-app 的构建脚本。

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=app.rc");
    println!("cargo:rerun-if-changed=assets/app.ico");
    println!("cargo:rerun-if-env-changed=EVEO_BUILD_LABEL");
    let version = std::env::var("CARGO_PKG_VERSION").expect("CARGO_PKG_VERSION");
    let label = std::env::var("EVEO_BUILD_LABEL")
        .ok()
        .filter(|label| !label.is_empty())
        .unwrap_or_else(|| version.clone());
    // 标签写进资源脚本的字符串里，也会被拿去比较版本：只收语义化版本用到的字符，引号与反斜杠会弄坏脚本。
    assert!(
        label
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b)),
        "EVEO_BUILD_LABEL 只能含字母、数字与 . - +"
    );
    let target_windows = std::env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "windows");
    let host_windows = std::env::var("HOST").is_ok_and(|host| host.contains("windows"));
    if target_windows && host_windows {
        let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
        let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
        let script = resource_script(&manifest_dir, &version, &label);
        let generated = out_dir.join("app.rc");
        std::fs::write(&generated, script).expect("写生成的 app.rc");
        // 编译失败（缺 SDK）时直接报错：Windows 上构建出没有图标的 exe 不应悄悄通过。
        embed_resource::compile(&generated, embed_resource::NONE)
            .manifest_optional()
            .expect("编译 app.rc");
    }
}

/// 生成的资源脚本：app.rc 的内容（图标换成绝对路径）加 VERSIONINFO。
fn resource_script(manifest_dir: &Path, version: &str, label: &str) -> String {
    let source = std::fs::read_to_string(manifest_dir.join("app.rc")).expect("读 app.rc");
    // 资源脚本的字符串里反斜杠要写两个。
    let icon = manifest_dir.join("assets").join("app.ico");
    let icon = icon.display().to_string().replace('\\', "\\\\");
    let source = source.replace("\"assets/app.ico\"", &format!("\"{icon}\""));
    // 数字版本只取主、次、修订号（预发布标识写不进 FILEVERSION），第四段为 0。
    let numbers: Vec<u16> = version
        .split(['-', '+'])
        .next()
        .unwrap_or_default()
        .split('.')
        .map(|part| part.parse().unwrap_or(0))
        .chain(std::iter::repeat(0))
        .take(4)
        .collect();
    let numeric = format!("{},{},{},{}", numbers[0], numbers[1], numbers[2], numbers[3]);
    // 040904B0：美国英语、Unicode；Translation 与字符串表的分组一致，读的一方按 Translation 找字符串表。
    format!(
        r#"{source}
1 VERSIONINFO
FILEVERSION {numeric}
PRODUCTVERSION {numeric}
FILEOS 0x40004
FILETYPE 0x1
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "CompanyName", "EVE-O Preview contributors"
            VALUE "FileDescription", "EVE-O Preview"
            VALUE "FileVersion", "{version}"
            VALUE "InternalName", "eveo-app"
            VALUE "LegalCopyright", "GPL-3.0-or-later"
            VALUE "OriginalFilename", "EVE-O Preview.exe"
            VALUE "ProductName", "EVE-O Preview"
            VALUE "ProductVersion", "{version}"
            VALUE "BuildLabel", "{label}"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"#
    )
}
