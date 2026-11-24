// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的收集与写出，对应 macOS 的 ProblemReportBuilder.swift 与 ReportArchiver.swift（v1.1 设计 7.1、7.2 节）：
// - collect：在后台线程里读日志与 WER 报告，连同主线程取好的 summary.md 与 config-summary.json，
//   每个文件都经 Redactor 处理，得到预览项。全部在内存里，用户确认之前不写任何文件。
// - write_archive：把勾选的项加上 manifest.json 写成 `Reports\<名字>.zip`（里面是同名的文件夹），
//   然后只留最新的 3 个报告：只删名字以 `EVE-O-Preview-diagnostics-` 开头、以 `.zip` 结尾的文件。
// 压缩包里的文件：
// | 文件 | 内容 | 上限 |
// | summary.md | 环境报告 | |
// | config-summary.json | 配置摘要（不含名字） | |
// | logs/eve-o-preview.log、logs/eve-o-preview.N.log | 应用日志，从最新的起取 | 合计 2 MiB，超出的只留末尾 |
// | crash/crash-1.wer～crash-3.wer | WER 报告目录里的 Report.wer，按从新到旧编号，不沿用原目录名 | 最多 3 个，每个 1 MiB |
// | manifest.json | 文件清单、大小与替换次数、生成时刻、版本 | |
// WER 的小型转储（.mdmp）不进报告：太大，而且含进程内存，脱敏管不到。

//! 问题报告的收集与压缩包。

pub mod zip;

use std::fs;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use eveo_core::diagnostics::crash::{MAX_REPORTS, WerReport, select_reports};
use eveo_core::diagnostics::redactor::{RedactionCounts, RedactionTerms, Redactor};
use eveo_core::diagnostics::summary::{DiagnosticsBundlePlanner, DiagnosticsManifest, ManifestEntry};
use eveo_core::logging::rotating::LogFileLayout;

use crate::atomic_file::write_atomic;
use crate::session::wer_reports;

/// 每个崩溃报告最多读多少字节：1 MiB。
pub const MAX_CRASH_REPORT_BYTES: u64 = 1_048_576;
/// 手动情境下取最近几天的崩溃报告。
pub const RECENT_CRASH_DAYS: f64 = 7.0;
/// Reports 目录里留几个报告。
pub const KEEP_ARCHIVES: usize = 3;
/// 清单文件在压缩包里的路径。
pub const MANIFEST_PATH: &str = "manifest.json";

/// 预览项的种类，决定列表里显示的名称。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemKind {
    /// summary.md，不能取消勾选。
    Summary,
    /// config-summary.json。
    Config,
    /// 一个日志文件。
    Log,
    /// 第 N 个崩溃报告（从 1 起）。
    Crash(usize),
}

/// 一个预览项：脱敏后的文字与替换次数。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportItem {
    /// 种类。
    pub kind: ItemKind,
    /// 压缩包里（文件夹之下）的相对路径，如 `logs/eve-o-preview.log`。
    pub path: String,
    /// 脱敏后的文字。
    pub text: String,
    /// 替换次数。
    pub counts: RedactionCounts,
    /// 是否勾选（写进压缩包）。summary.md 总是勾选。
    pub included: bool,
}

impl ReportItem {
    /// 能否取消勾选：只有 summary.md 不能。
    pub fn optional(&self) -> bool {
        self.kind != ItemKind::Summary
    }
}

/// 崩溃报告从哪来。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CrashSource {
    /// 崩溃情境：上一次运行时找到的 WER 报告目录名（PendingCrash 里记的）。
    Named(Vec<String>),
    /// 手动情境：最近 7 天里本应用的报告。
    Recent,
}

/// 收集需要的输入。summary.md 与 config-summary.json 由应用在主线程上先写好（未脱敏）。
#[derive(Debug, Clone)]
pub struct CollectRequest {
    /// summary.md 的全文。
    pub summary: String,
    /// config-summary.json 的全文。
    pub config_summary: String,
    /// 日志文件的位置。
    pub logs: LogFileLayout,
    /// 崩溃报告从哪来。
    pub crashes: CrashSource,
    /// WER 的报告目录（ReportArchive、ReportQueue 等）。
    pub wer_dirs: Vec<PathBuf>,
    /// 本应用的可执行文件名，用来认出自己的 WER 报告。
    pub executable: String,
    /// 现在的时刻（1970 年以来的秒数）。
    pub now: f64,
    /// 脱敏的词表。
    pub terms: RedactionTerms,
}

/// 读文件、脱敏，得到预览项：summary.md、config-summary.json、日志（最新的在前）、崩溃报告。
/// 读不了的日志或报告跳过（不中断整个报告）。
pub fn collect(request: &CollectRequest) -> Vec<ReportItem> {
    // 词表只建一次：建的时候要做规范化与分桶，几个文件共用。
    let redactor = Redactor::new(&request.terms);
    // 每个文件都经同一个脱敏器；替换次数随项保存，预览与清单都要用。
    let item = |kind, path: String, raw: &str| {
        let (text, counts) = redactor.redact(raw);
        ReportItem {
            kind,
            path,
            text,
            counts,
            included: true,
        }
    };
    let mut items = vec![
        item(ItemKind::Summary, "summary.md".to_owned(), &request.summary),
        item(
            ItemKind::Config,
            "config-summary.json".to_owned(),
            &request.config_summary,
        ),
    ];
    // 日志：按 2 MiB 的预算从最新的文件起取。
    let sizes: Vec<(String, u64)> = request
        .logs
        .existing()
        .iter()
        .filter_map(|path| {
            let name = path.file_name()?.to_string_lossy().into_owned();
            Some((name, fs::metadata(path).ok()?.len()))
        })
        .collect();
    for (name, tail) in DiagnosticsBundlePlanner::log_slices(&sizes) {
        let path = request.logs.directory.join(&name);
        if let Ok(text) = read_tail(&path, tail) {
            items.push(item(ItemKind::Log, format!("logs/{name}"), &text));
        }
    }
    // 崩溃报告：按从新到旧编号，文件名不沿用原目录名（目录名里有应用名与哈希，无用）。
    let reports = crash_report_files(request);
    for (index, path) in reports.iter().enumerate() {
        if let Ok(text) = read_report(path) {
            let number = index + 1;
            items.push(item(
                ItemKind::Crash(number),
                format!("crash/crash-{number}.wer"),
                &text,
            ));
        }
    }
    items
}

/// 要带上的崩溃报告的 Report.wer 位置，最新的在前，最多 3 个。
fn crash_report_files(request: &CollectRequest) -> Vec<PathBuf> {
    let names: Vec<String> = match &request.crashes {
        CrashSource::Named(names) => names.iter().take(MAX_REPORTS).cloned().collect(),
        CrashSource::Recent => {
            let candidates: Vec<WerReport> =
                request.wer_dirs.iter().flat_map(|dir| wer_reports(dir)).collect();
            let since = request.now - RECENT_CRASH_DAYS * 86_400.0;
            select_reports(&candidates, &request.executable, since, request.now)
                .into_iter()
                .map(|report| report.name)
                .collect()
        }
    };
    // 同名的目录可能在 ReportQueue 与 ReportArchive 之一，取第一个有 Report.wer 的。
    names
        .iter()
        .filter_map(|name| {
            request
                .wer_dirs
                .iter()
                .map(|dir| dir.join(name).join("Report.wer"))
                .find(|path| path.is_file())
        })
        .collect()
}

/// 读文件末尾的 bytes 个字节。没从开头读时丢掉第一个换行之前的半行；不是合法 UTF-8 的字节换成替换字符。
fn read_tail(path: &Path, bytes: u64) -> io::Result<String> {
    // 日志可能正被写着：长度取打开时的，之后追加的不读。
    let mut file = fs::File::open(path)?;
    let length = file.metadata()?.len();
    let start = length.saturating_sub(bytes);
    file.seek(SeekFrom::Start(start))?;
    let mut buffer = Vec::new();
    file.take(bytes).read_to_end(&mut buffer)?;
    let text = String::from_utf8_lossy(&buffer).into_owned();
    if start == 0 {
        return Ok(text);
    }
    Ok(match text.find('\n') {
        Some(newline) => text[newline + 1..].to_owned(),
        None => text,
    })
}

/// 读一个 Report.wer 的开头 1 MiB。WER 写的是带 BOM 的 UTF-16LE；没有 BOM 时按 UTF-8 读。
fn read_report(path: &Path) -> io::Result<String> {
    let mut buffer = Vec::new();
    fs::File::open(path)?
        .take(MAX_CRASH_REPORT_BYTES)
        .read_to_end(&mut buffer)?;
    Ok(decode_report(&buffer))
}

/// Report.wer 的字节转成文字。
fn decode_report(bytes: &[u8]) -> String {
    match bytes {
        [0xFF, 0xFE, rest @ ..] => {
            // 截在 1 MiB 处时最后可能剩半个码元，as_chunks 把它留在余下的部分，丢掉。
            // 截断也可能落在代理对中间，from_utf16_lossy 把落单的半个换成替换字符。
            let units: Vec<u16> = rest
                .as_chunks::<2>()
                .0
                .iter()
                .map(|pair| u16::from_le_bytes(*pair))
                .collect();
            String::from_utf16_lossy(&units)
        }
        _ => String::from_utf8_lossy(bytes).into_owned(),
    }
}

/// 清单的元数据：版本、构建类别、生成时刻与情境。
#[derive(Debug, Clone, PartialEq)]
pub struct ManifestInfo {
    /// 应用版本。
    pub app_version: String,
    /// 构建类别。
    pub build_label: String,
    /// 生成时刻（1970 年以来的秒数）。
    pub generated_at: f64,
    /// 是否为崩溃情境。
    pub crash: bool,
}

/// manifest.json 的全文：列出勾选的项。
pub fn manifest_text(items: &[ReportItem], info: &ManifestInfo) -> String {
    let manifest = DiagnosticsManifest {
        app_version: info.app_version.clone(),
        build_label: info.build_label.clone(),
        generated_at: info.generated_at,
        context: if info.crash { "crash" } else { "manual" }.to_owned(),
        files: items
            .iter()
            .filter(|item| item.included)
            .map(|item| ManifestEntry {
                path: item.path.clone(),
                bytes: item.text.len(),
                replacements: item.counts,
            })
            .collect(),
    };
    manifest.to_json()
}

/// 把勾选的项加上 manifest.json 写成 `<dir>\<name>.zip`，返回它的位置；然后只留最新的 3 个报告。
/// 压缩包里的路径是 `<name>/<相对路径>`，解压后是一个同名文件夹。
pub fn write_archive(
    dir: &Path,
    name: &str,
    items: &[ReportItem],
    info: &ManifestInfo,
    time: zip::DosTime,
) -> io::Result<PathBuf> {
    // summary.md 不能取消勾选，即使 included 被误改成假也写进去。
    let mut files: Vec<(String, Vec<u8>)> = items
        .iter()
        .filter(|item| item.included || !item.optional())
        .map(|item| (format!("{name}/{}", item.path), item.text.as_bytes().to_vec()))
        .collect();
    files.push((
        format!("{name}/{MANIFEST_PATH}"),
        manifest_text(items, info).into_bytes(),
    ));
    let mut bytes = Vec::new();
    zip::write_zip(&mut bytes, &files, time)?;
    // 先写临时文件再改名：写到一半失败时不会留下打不开的 zip（目录不存在时 write_atomic 会建）。
    let path = dir.join(format!("{name}.zip"));
    write_atomic(&path, &bytes, "report")?;
    prune_archives(dir, KEEP_ARCHIVES);
    Ok(path)
}

/// 只留最新的 keep 个报告。名字里的时间戳是 UTC 的 `yyyyMMdd-HHmmss`，按名字排序就是按时间排序。
/// 只动名字以前缀开头、以 `.zip` 结尾的文件；删不掉的忽略。
fn prune_archives(dir: &Path, keep: usize) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|t| t.is_file()))
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with(DiagnosticsBundlePlanner::ARCHIVE_PREFIX) && name.ends_with(".zip"))
        .collect();
    // 新写的那个名字最大，总在保留之列。
    names.sort();
    let excess = names.len().saturating_sub(keep);
    for name in &names[..excess] {
        let _ = fs::remove_file(dir.join(name));
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
