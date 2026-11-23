// SPDX-License-Identifier: GPL-3.0-or-later
//
// 编译 .slint 文件。样式固定为 fluent（Windows 11 的观感），不随构建机器变化。

//! eveo-ui 的构建脚本。

fn main() {
    let config = slint_build::CompilerConfiguration::new().with_style("fluent".into());
    slint_build::compile_with_config("ui/settings.slint", config).expect("编译 ui/settings.slint");
}
