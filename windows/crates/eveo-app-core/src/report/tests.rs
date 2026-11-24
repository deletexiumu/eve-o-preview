// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的收集与写出的用例：日志的取舍与半行、WER 报告的编码与编号、勾选、清单与只留 3 个报告。

use super::*;

/// 测试用的临时目录，用完删掉。
struct TempDir(PathBuf);

impl TempDir {
    /// 新建一个空目录。
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("eveo-report-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    /// 删掉整个目录。
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// UTF-16LE 加 BOM 的字节，模拟 WER 写的 Report.wer。
fn utf16(text: &str) -> Vec<u8> {
    let mut bytes = vec![0xFF, 0xFE];
    bytes.extend(text.encode_utf16().flat_map(u16::to_le_bytes));
    bytes
}

/// 一个收集请求：两个日志文件、两个 WER 目录。
fn request(root: &Path, crashes: CrashSource) -> CollectRequest {
    // 日志：当前文件含用户名，归档文件没有。
    let logs = root.join("logs");
    fs::create_dir_all(&logs).unwrap();
    fs::write(logs.join("eve-o-preview.log"), "new line by cookie\n").unwrap();
    fs::write(logs.join("eve-o-preview.1.log"), "old line\n").unwrap();
    // WER：本应用的两个报告分在两个目录里，另有一个别的程序的报告。
    let queue = root.join("ReportQueue");
    let archive = root.join("ReportArchive");
    for (dir, name, text) in [
        (
            &queue,
            "AppCrash_eve-o-preview.e_abc",
            "Sig[0].Value=eve-o-preview.exe\r\nUser=cookie",
        ),
        (&archive, "AppCrash_eve-o-preview.e_def", "older"),
        (&archive, "AppCrash_other.exe_123", "not ours"),
    ] {
        fs::create_dir_all(dir.join(name)).unwrap();
        fs::write(dir.join(name).join("Report.wer"), utf16(text)).unwrap();
    }
    CollectRequest {
        summary: "# summary on COOKIE-PC".to_owned(),
        config_summary: "{}".to_owned(),
        logs: LogFileLayout::in_dir(logs),
        crashes,
        wer_dirs: vec![queue, archive],
        executable: "eve-o-preview.exe".to_owned(),
        now: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs_f64(),
        terms: RedactionTerms {
            user_names: vec!["cookie".to_owned()],
            host_names: vec!["COOKIE-PC".to_owned()],
            ..RedactionTerms::default()
        },
    }
}

/// 崩溃情境：summary、config、两个日志（最新的在前）、指名的一个 WER 报告；内容都脱敏。
#[test]
fn collects_named_crash() {
    let dir = TempDir::new("named");
    let named = CrashSource::Named(vec![
        "AppCrash_eve-o-preview.e_abc".to_owned(),
        "missing".to_owned(),
    ]);
    let items = collect(&request(&dir.0, named));
    let paths: Vec<&str> = items.iter().map(|i| i.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "summary.md",
            "config-summary.json",
            "logs/eve-o-preview.log",
            "logs/eve-o-preview.1.log",
            "crash/crash-1.wer"
        ]
    );
    // 不存在的报告名跳过；每项都脱敏过。
    assert_eq!(items[0].text, "# summary on [host]");
    assert!(!items[0].optional() && items[1].optional());
    assert_eq!(items[2].text, "new line by [user]\n");
    assert_eq!(items[4].kind, ItemKind::Crash(1));
    assert!(items[4].text.contains("User=[user]"));
    assert_eq!(items[4].counts.user, 1);
}

/// 手动情境：取最近 7 天里本应用的报告（两个，不含别的程序的）。
#[test]
fn collects_recent_crashes() {
    let dir = TempDir::new("recent");
    let items = collect(&request(&dir.0, CrashSource::Recent));
    let crashes = items
        .iter()
        .filter(|i| matches!(i.kind, ItemKind::Crash(_)))
        .count();
    assert_eq!(crashes, 2);
    assert!(items.iter().all(|i| !i.text.contains("not ours")));
}

/// 日志的末尾：没从开头读时丢掉半行。
#[test]
fn reads_tail_without_partial_line() {
    let dir = TempDir::new("tail");
    let path = dir.0.join("a.log");
    fs::write(&path, "first line\nsecond line\nthird\n").unwrap();
    assert_eq!(read_tail(&path, 100).unwrap(), "first line\nsecond line\nthird\n");
    // 末尾 15 字节从 second line 的中间开始，那半行丢掉。
    assert_eq!(read_tail(&path, 15).unwrap(), "third\n");
}

/// WER 报告：UTF-16LE 加 BOM 与 UTF-8 都能读；截断时剩的半个码元丢掉。
#[test]
fn decodes_reports() {
    assert_eq!(decode_report(&utf16("Sig=1")), "Sig=1");
    assert_eq!(decode_report(b"plain"), "plain");
    // 多出一个字节（半个码元）时丢掉。
    let mut odd = utf16("ab");
    odd.push(0x41);
    assert_eq!(decode_report(&odd), "ab");
}

/// 写出：取消勾选的项不进压缩包，清单只列勾选的；Reports 里只留最新的 3 个，别的文件不动。
#[test]
fn writes_archive_and_prunes() {
    let dir = TempDir::new("write");
    let mut items = collect(&request(&dir.0, CrashSource::Recent));
    items[1].included = false;
    let reports = dir.0.join("Reports");
    fs::create_dir_all(&reports).unwrap();
    // 三个旧报告加上新写的一个，超出一个；别的 zip 不是报告，不动。
    for old in ["20200101-000000", "20200102-000000", "20200103-000000"] {
        fs::write(reports.join(format!("EVE-O-Preview-diagnostics-{old}.zip")), b"x").unwrap();
    }
    fs::write(reports.join("keep-me.zip"), b"x").unwrap();
    let info = ManifestInfo {
        app_version: "0.9.0".to_owned(),
        build_label: "release".to_owned(),
        generated_at: 1_763_697_906.0,
        crash: false,
    };
    let time = zip::DosTime {
        year: 2026,
        month: 11,
        day: 24,
        hour: 0,
        minute: 0,
        second: 0,
    };
    let name = "EVE-O-Preview-diagnostics-20261124-000000";
    let path = write_archive(&reports, name, &items, &info, time).unwrap();
    // 只存储不压缩，路径与内容都能在字节里直接找到。
    let bytes = fs::read(&path).unwrap();
    let contains = |needle: &str| bytes.windows(needle.len()).any(|w| w == needle.as_bytes());
    assert!(contains(&format!("{name}/summary.md")));
    assert!(contains(&format!("{name}/manifest.json")));
    assert!(!contains("config-summary.json"));
    // 清单里只有勾选的项。
    let manifest = manifest_text(&items, &info);
    assert!(manifest.contains("\"manual\"") && !manifest.contains("config-summary"));
    // 最旧的一个被删掉。
    let mut left: Vec<String> = fs::read_dir(&reports)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(
        left,
        [
            "EVE-O-Preview-diagnostics-20200102-000000.zip",
            "EVE-O-Preview-diagnostics-20200103-000000.zip",
            &format!("{name}.zip"),
            "keep-me.zip"
        ]
    );
}
