// SPDX-License-Identifier: GPL-3.0-or-later
//
// 把应用图标（app.rc 里的 assets/app.ico）编进 exe 的资源。
// 只在 Windows 主机上为 Windows 目标编译资源：需要 Windows SDK 的 rc.exe。在 Linux 上交叉做 clippy 检查时跳过，
// 那时不产出可运行的 exe，缺图标没有关系。

//! eveo-app 的构建脚本。

fn main() {
    println!("cargo:rerun-if-changed=app.rc");
    println!("cargo:rerun-if-changed=assets/app.ico");
    let target_windows = std::env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "windows");
    let host_windows = std::env::var("HOST").is_ok_and(|host| host.contains("windows"));
    if target_windows && host_windows {
        // 编译失败（缺 SDK）时直接报错：Windows 上构建出没有图标的 exe 不应悄悄通过。
        embed_resource::compile("app.rc", embed_resource::NONE)
            .manifest_optional()
            .expect("编译 app.rc");
    }
}
