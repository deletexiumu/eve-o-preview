// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面截图工具：把设置窗口按明暗两套、首屏与整页两种高度画成 PNG。
// 用法：eveo-ui-shot --out <目录> [--scale 1.5] [--font Inter]

//! `eveo-ui-shot`。

use std::path::PathBuf;

use eveo_ui::screenshot::{ShotOptions, settings_png};

/// 取命令行里某个选项的值。
fn option(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(out) = option(&args, "--out").map(PathBuf::from) else {
        eprintln!("用法：eveo-ui-shot --out <目录> [--scale 1.5] [--font Inter]");
        std::process::exit(2);
    };
    // 默认 1.5 倍，对应常见的 150% 缩放，图片看得清楚。
    let scale = option(&args, "--scale")
        .and_then(|s| s.parse().ok())
        .unwrap_or(1.5);
    // Linux 上没有 Segoe UI，截图时传 --font Inter；中日韩文字由系统字体回退补上。
    let font = option(&args, "--font").unwrap_or_else(|| "Segoe UI Variable Text".into());
    if let Err(error) = std::fs::create_dir_all(&out) {
        eprintln!("建不了 {}：{error}", out.display());
        std::process::exit(2);
    }
    // 「预览与布局」页：首屏（窗口默认大小）与整页（内容全部展开）各一张，明暗两套；「客户端」页明暗各一张；「切换与热键」页整页一张、暗色首屏一张。
    let shots = [
        ("settings-previews-light.png", false, 1, (1040, 760)),
        ("settings-previews-dark.png", true, 1, (1040, 760)),
        ("settings-previews-light-full.png", false, 1, (1040, 1560)),
        ("settings-previews-dark-full.png", true, 1, (1040, 1560)),
        ("settings-clients-light.png", false, 0, (1040, 760)),
        ("settings-clients-dark.png", true, 0, (1040, 760)),
        ("settings-switching-light-full.png", false, 2, (1040, 1500)),
        ("settings-switching-dark.png", true, 2, (1040, 760)),
    ];
    // 逐张渲染；任何一张失败就以非零码退出，CI 能发现。
    for (name, dark, page, size) in shots {
        let options = ShotOptions {
            dark,
            size,
            scale,
            font: font.clone(),
            page,
        };
        match settings_png(&options)
            .and_then(|png| std::fs::write(out.join(name), png).map_err(|e| e.to_string()))
        {
            Ok(()) => println!("{}", out.join(name).display()),
            Err(error) => {
                eprintln!("{name}：{error}");
                std::process::exit(1);
            }
        }
    }
}
