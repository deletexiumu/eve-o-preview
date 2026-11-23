// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面截图工具：把设置窗口按明暗两套、首屏与整页两种高度画成 PNG。
// 用法：eveo-ui-shot --out <目录> [--scale 1.5] [--font Inter] [--lang zh]
// --lang 是界面语言的代码（en、zh、ru、ja、ko、fr、de、es），默认 zh；文件名加上语言代码。

//! `eveo-ui-shot`。

use std::path::PathBuf;

use eveo_core::model::AppLanguage;
use eveo_core::support::StringEnum;
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
        eprintln!("用法：eveo-ui-shot --out <目录> [--scale 1.5] [--font Inter] [--lang zh]");
        std::process::exit(2);
    };
    // 默认 1.5 倍，对应常见的 150% 缩放，图片看得清楚。
    let scale = option(&args, "--scale")
        .and_then(|s| s.parse().ok())
        .unwrap_or(1.5);
    // Linux 上没有 Segoe UI，截图时传 --font Inter；中日韩文字由系统字体回退补上。
    let font = option(&args, "--font").unwrap_or_else(|| "Segoe UI Variable Text".into());
    let code = option(&args, "--lang").unwrap_or_else(|| "zh".into());
    let Some(language) = AppLanguage::from_raw(&code) else {
        eprintln!("不认识的语言代码 {code}");
        std::process::exit(2);
    };
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
        ("settings-profiles-light.png", false, 6, (1040, 760)),
        ("settings-profiles-dark.png", true, 6, (1040, 760)),
        ("settings-alerts-light-full.png", false, 3, (1040, 1100)),
        ("settings-alerts-dark.png", true, 3, (1040, 760)),
        ("settings-intel-light-full.png", false, 4, (1040, 1700)),
        ("settings-intel-dark.png", true, 4, (1040, 760)),
        ("settings-translation-light-full.png", false, 5, (1040, 1700)),
        ("settings-translation-dark.png", true, 5, (1040, 760)),
        ("settings-general-light.png", false, 7, (1040, 760)),
        ("settings-general-dark.png", true, 7, (1040, 760)),
        ("settings-environment-light.png", false, 9, (1040, 900)),
        ("settings-environment-dark.png", true, 9, (1040, 760)),
        ("settings-about-light.png", false, 8, (1040, 900)),
        ("settings-about-dark.png", true, 8, (1040, 760)),
    ];
    // 逐张渲染；任何一张失败就以非零码退出，CI 能发现。
    for (name, dark, page, size) in shots {
        let options = ShotOptions {
            dark,
            size,
            scale,
            font: font.clone(),
            page,
            language,
        };
        // 文件名加上语言代码：settings-general-light.png → settings-general-light.zh.png。
        let name = name.replace(".png", &format!(".{code}.png"));
        match settings_png(&options)
            .and_then(|png| std::fs::write(out.join(&name), png).map_err(|e| e.to_string()))
        {
            Ok(()) => println!("{}", out.join(&name).display()),
            Err(error) => {
                eprintln!("{name}：{error}");
                std::process::exit(1);
            }
        }
    }
}
