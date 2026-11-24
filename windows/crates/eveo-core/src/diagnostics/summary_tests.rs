// SPDX-License-Identifier: GPL-3.0-or-later
//
// 摘要、环境报告、日志取舍与文件清单的用例，对应 macOS 的 DiagnosticsSummaryTests（v1.1 设计 7.2 节）。

use super::*;
use crate::diagnostics::redactor::character_names;
use crate::model::{ChannelRef, CycleGroup, Profile, ThumbnailLayout};

/// 两个配置方案，名字、频道、参考星系与接口地址都是不该进报告的文字。
fn config() -> AppConfig {
    let mut main = Profile::make_new("p1", "Secret Profile");
    main.layouts.insert("Alpha".into(), ThumbnailLayout::default());
    main.hidden_characters.push("Bravo".into());
    main.highlight_colors.insert("Charlie".into(), "#FF0000".into());
    main.character_hotkeys.insert("echo".into(), vec!["F2".into()]);
    main.character_hotkeys.insert("Delta".into(), vec!["F1".into()]);
    main.cycle_groups.push(CycleGroup {
        name: "Secret Group".into(),
        members: vec!["Delta".into(), "Alpha".into()],
        forward_hotkeys: vec!["F5".into()],
        ..CycleGroup::default()
    });
    main.intel.channels.push(ChannelRef::new("Secret Intel", None));
    main.intel.reference_system = Some("Jita".into());
    main.translation
        .channels
        .push(ChannelRef::new("Secret Chat", None));
    // 第二个配置方案不是当前方案：它的名字不进摘要，角色名仍要收集。
    let mut other = Profile::make_new("p2", "Other");
    other.hidden_characters = vec!["Foxtrot".into(), " ".into()];
    let mut config = AppConfig {
        active_profile_id: "p1".into(),
        profiles: vec![main, other],
        ..AppConfig::default()
    };
    // 自定的日志目录与接口地址只该以「是否自定」出现。
    config.general.eve_log_directory = Some(r"C:\Users\cookie\Documents\EVE\logs".into());
    config.general.translation_endpoint.base_url = "https://secret.example/v1".into();
    config
}

/// 配置摘要只有数量、开关与热键；名字、频道、星系、路径与接口地址都不出现。
#[test]
fn config_summary_has_no_names() {
    // 在整段 JSON 文本里找，任何一处漏出都算失败。
    let summary = config_summary(&config(), None, &["valuesClamped".to_owned()]);
    let text = pretty_json(&summary);
    for secret in [
        "Secret", "Alpha", "Bravo", "Charlie", "Delta", "echo", "Jita", "cookie", "example", "Other",
    ] {
        assert!(!text.contains(secret), "{secret} 出现在摘要里：{text}");
    }
    assert_eq!(summary["profileCount"], 2);
    assert_eq!(summary["warnings"][0], "valuesClamped");
    assert_eq!(summary["general"]["eveLogDirectory"], "custom");
    // 数量与开关照实写出。
    let profile = &summary["activeProfile"];
    assert_eq!(profile["layoutCount"], 1);
    assert_eq!(profile["characterHotkeyCount"], 2);
    // 角色热键按名字排序（不区分大小写）：Delta 在 echo 前。
    assert_eq!(profile["characterHotkeys"], json!([["F1"], ["F2"]]));
    assert_eq!(profile["cycleGroups"][0]["memberCount"], 2);
    assert_eq!(profile["intel"]["channelCount"], 1);
    assert_eq!(profile["intel"]["hasReferenceSystem"], true);
    assert_eq!(profile["translation"]["hasCustomBaseURL"], true);
    assert!(profile["thumbnail"].is_object());
}

/// 角色名的收集：全部配置方案的各处加上在线角色，去重、去空白并排序。
#[test]
fn collects_character_names() {
    // 排序区分大小写（大写字母在前），与 macOS 的 sorted() 相同。
    let names = character_names(&config(), &["Golf".to_owned(), "Alpha".to_owned()]);
    assert_eq!(
        names,
        ["Alpha", "Bravo", "Charlie", "Delta", "Foxtrot", "Golf", "echo"]
    );
}

/// 环境报告：summary.md 的各节与 Issue 的行（`/` 换成 `-`）。
#[test]
fn environment_report() {
    let report = EnvironmentReport {
        app: AppEnvironment {
            version: "0.9.0".into(),
            build_label: "release".into(),
            commit: None,
            install_location: "localAppData".into(),
            location_writable: true,
        },
        system: SystemInfo {
            os_name: "Windows 11 Pro".into(),
            os_display_version: "24H2".into(),
            os_build: "26100.2314".into(),
            architecture: "x86_64".into(),
            emulated: true,
            physical_memory_bytes: 17_179_869_184,
            gpus: vec!["GPU A/B".into()],
            ..SystemInfo::default()
        },
        runtime: RuntimeSummary {
            thumbnail_states: BTreeMap::from([("shown".into(), 2), ("failed".into(), 1)]),
            ..RuntimeSummary::default()
        },
    };
    // summary.md 里系统、架构、内存与计数表的写法。
    let markdown = report.markdown(1_763_697_906.0);
    assert!(markdown.contains("Generated: 2025-11-21T04:05:06Z"));
    assert!(markdown.contains("- Windows: Windows 11 Pro 24H2 (build 26100.2314)"));
    assert!(markdown.contains("- Architecture: x86_64 (emulated on ARM64)"));
    assert!(markdown.contains("- Memory: 16.0 GiB"));
    assert!(markdown.contains("- Thumbnails: failed 1, shown 2"));
    assert!(markdown.contains("- Hotkey failures: none"));
    assert!(markdown.contains("- Commit: unknown"));
    // Issue 的行：最重要的版本在第一行；`/` 换成 `-`。
    let lines = report.issue_lines();
    assert_eq!(lines[0], "- EVE-O Preview: 0.9.0 (build release)");
    assert!(lines.iter().any(|l| l == "- GPU: GPU A-B"));
}

/// 日志的取舍：从最新的起取，合计不超过 2 MiB；超出的只留末尾，之后的不取，空文件跳过。
#[test]
fn log_slices() {
    let mib = 1_048_576;
    let files = vec![
        ("a.log".to_owned(), 0),
        ("b.log".to_owned(), mib),
        ("c.log".to_owned(), mib + 10),
        ("d.log".to_owned(), 5),
    ];
    // a 是空文件跳过；b 全取；c 只取末尾 1 MiB 凑满 2 MiB；d 更旧，不取。
    let slices = DiagnosticsBundlePlanner::log_slices(&files);
    assert_eq!(slices, [("b.log".to_owned(), mib), ("c.log".to_owned(), mib)]);
    assert!(DiagnosticsBundlePlanner::log_slices(&[]).is_empty());
}

/// 压缩包的名字按 UTC。
#[test]
fn archive_name() {
    assert_eq!(
        DiagnosticsBundlePlanner::archive_name(1_763_697_906.9),
        "EVE-O-Preview-diagnostics-20251121-040506"
    );
}

/// 文件清单的键名与 macOS 相同。
#[test]
fn manifest_json() {
    let manifest = DiagnosticsManifest {
        app_version: "0.9.0".into(),
        build_label: "release".into(),
        generated_at: 1_763_697_906.0,
        context: "crash".into(),
        files: vec![ManifestEntry {
            path: "summary.md".into(),
            bytes: 10,
            replacements: RedactionCounts {
                user: 1,
                ..RedactionCounts::default()
            },
        }],
    };
    // 解析回来比较，不比较缩进与键序。
    let value: Value = serde_json::from_str(&manifest.to_json()).unwrap();
    assert_eq!(value["generatedAt"], "2025-11-21T04:05:06Z");
    assert_eq!(value["files"][0]["replacements"]["user"], 1);
    assert_eq!(value["context"], "crash");
}
