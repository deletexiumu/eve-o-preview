// SPDX-License-Identifier: GPL-3.0-or-later
//
// 全局的日志入口，对应 macOS 的 LogChannel.swift（PlatformLog）与 FileLogSink.swift（docs/macos/design-v1.1.md 5.1～5.3 节）：
// - 各模块用 `Logger::new("Capture")` 这样的常量写日志，方法名与 macOS 相同：debug、info、notice、error、fault。
// - 启动时 `install` 一次，交进日志目录（%LOCALAPPDATA%\EVE-O Preview\logs）。没装时（单元测试、重复启动后自己退出的实例）
//   什么也不写。Windows 版没有系统日志可写，文件就是唯一的去处。
// - 低于最低级别（`general.logLevel`，默认 info）的记录不写；debug 的文字在不写时不求值，所以 debug 接收闭包。
// - 一把 Mutex 保护带轮转的文件与限速器，在调用线程上同步写入，不经过队列：崩溃前最后一条已经交给了系统。
//   行的格式化（时间、转义、截短）在锁外做，锁内只有限速判断与写入。
// - 限速：桶空时丢弃并计数，恢复后先写一行 `… dropped N lines`。
// - 连续 3 次写入失败后停止写文件（没有别的地方可报，就安静地停下）。
// - panic 时由 `install_panic_hook` 装的钩子写一条 fault（位置与消息，用户目录换成 %USERPROFILE%），再刷一次。
// 隐私：调用方不把角色名、窗口标题、消息正文、API Key 放进文字（设计 5.4 节）；路径用 `redact` 去掉用户名。

//! 全局的日志入口与文件输出。

use std::fmt::Display;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use eveo_core::logging::LogLevel;
use eveo_core::logging::format::LogRecord;
use eveo_core::logging::rate::{Admission, LogRateLimiter};
use eveo_core::logging::rotating::{LogFileLayout, LogRotationPolicy, RotatingLogFile};
use eveo_core::support::StringEnum;

/// 连续失败多少次后停止写文件。
const MAX_CONSECUTIVE_FAILURES: u32 = 3;

/// 一个模块的日志入口。复制成本为零，可以写成常量。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Logger {
    /// 模块名，写在方括号里。
    category: &'static str,
}

impl Logger {
    /// 模块 category 的日志入口。
    pub const fn new(category: &'static str) -> Self {
        Self { category }
    }

    /// 排查问题时才看的细节。不写时 text 不求值。
    pub fn debug<T: Display>(&self, text: impl FnOnce() -> T) {
        if enabled(LogLevel::Debug) {
            write(LogLevel::Debug, self.category, &text().to_string());
        }
    }

    /// 启动、退出、客户端增减、设置变化等。
    pub fn info(&self, text: impl Display) {
        self.log(LogLevel::Info, text);
    }

    /// 不常见但不是错误的情况。
    pub fn notice(&self, text: impl Display) {
        self.log(LogLevel::Notice, text);
    }

    /// 操作失败，功能受影响。
    pub fn error(&self, text: impl Display) {
        self.log(LogLevel::Error, text);
    }

    /// 程序自身的错误。
    pub fn fault(&self, text: impl Display) {
        self.log(LogLevel::Fault, text);
    }

    /// 达到最低级别时格式化并写入。
    fn log(&self, level: LogLevel, text: impl Display) {
        if enabled(level) {
            write(level, self.category, &text.to_string());
        }
    }
}

/// 文件输出：带轮转的文件、限速与失败计数，都在锁内用。
#[derive(Debug)]
pub struct FileLogSink {
    /// 带轮转的文件。
    file: RotatingLogFile,
    /// 限速器。
    limiter: LogRateLimiter,
    /// 连续失败的次数。
    consecutive_failures: u32,
    /// 已停止写文件。
    stopped: bool,
}

impl FileLogSink {
    /// 建文件输出。不碰磁盘，第一条记录到来时才建目录、打开文件。
    pub fn new(layout: LogFileLayout, policy: LogRotationPolicy) -> Self {
        Self {
            file: RotatingLogFile::new(layout, policy),
            limiter: LogRateLimiter::default(),
            consecutive_failures: 0,
            stopped: false,
        }
    }

    /// 写一行已格式化的记录。uptime 是单调时钟秒数（限速用），time 是墙上时间（说明丢弃的那一行用）。
    pub fn write_line(&mut self, line: &str, time: f64, uptime: f64) {
        if self.stopped {
            return;
        }
        let dropped = match self.limiter.admit(uptime) {
            Admission::Drop => return,
            Admission::Write => None,
            Admission::WriteAfterDropping(count) => Some(LogRecord {
                time,
                level: LogLevel::Notice,
                category: "Log".to_owned(),
                text: format!("… dropped {count} lines"),
            }),
        };
        let result = dropped
            .map_or(Ok(()), |notice| self.file.append(&notice.line()))
            .and_then(|()| self.file.append(line));
        if result.is_ok() {
            self.consecutive_failures = 0;
            return;
        }
        self.consecutive_failures += 1;
        if self.consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
            self.stopped = true;
            self.file.close();
        }
    }

    /// 是否已因连续失败停止写文件。
    pub fn is_stopped(&self) -> bool {
        self.stopped
    }
}

/// 装上的文件输出；没装时为 None。
static SINK: Mutex<Option<FileLogSink>> = Mutex::new(None);
/// 装上了文件输出（锁外的快速判断，没装时连格式化都省掉）。
static INSTALLED: AtomicBool = AtomicBool::new(false);
/// 最低级别在 `LogLevel::ALL` 里的位置；默认 info。
static MINIMUM: AtomicUsize = AtomicUsize::new(1);
/// 进程里第一次用到日志的时刻，限速用的单调时钟从这里算。
static START: OnceLock<Instant> = OnceLock::new();

/// 取锁；别的线程在锁内 panic 过时照常用里面的状态（日志不应因此全部失效）。
fn sink() -> MutexGuard<'static, Option<FileLogSink>> {
    SINK.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// 装上写到 directory 的文件输出（取代之前装的）。不碰磁盘，第一条记录时才建目录。
pub fn install(directory: &Path) {
    START.get_or_init(Instant::now);
    let layout = LogFileLayout::in_dir(directory);
    *sink() = Some(FileLogSink::new(layout, LogRotationPolicy::default()));
    INSTALLED.store(true, Ordering::Release);
}

/// 设最低级别：低于它的记录不写。
pub fn set_minimum_level(level: LogLevel) {
    let rank = LogLevel::ALL.iter().position(|&l| l == level).unwrap_or(1);
    MINIMUM.store(rank, Ordering::Relaxed);
}

/// 当前的最低级别。
pub fn minimum_level() -> LogLevel {
    LogLevel::ALL
        .get(MINIMUM.load(Ordering::Relaxed))
        .copied()
        .unwrap_or(LogLevel::Info)
}

/// level 的记录会不会写：装了文件输出，且不低于最低级别。
pub fn enabled(level: LogLevel) -> bool {
    INSTALLED.load(Ordering::Acquire) && level >= minimum_level()
}

/// 写入是不经缓冲的，返回时已交给系统，所以没有要冲刷的数据；取一次锁，保证别的线程上正在写的那条已经写完。
pub fn flush() {
    drop(sink());
}

/// 在不能等锁的地方（结构化异常的过滤器）写一条 fault：锁被占着时放弃这一条，不会卡住。
pub fn try_fault(category: &str, text: &str) {
    if !enabled(LogLevel::Fault) {
        return;
    }
    let line = record(LogLevel::Fault, category, text).line();
    if let Ok(mut guard) = SINK.try_lock()
        && let Some(sink) = guard.as_mut()
    {
        let (time, uptime) = clock();
        sink.write_line(&line, time, uptime);
    }
}

/// 现在的墙上时间与限速用的单调时钟秒数。
fn clock() -> (f64, f64) {
    let time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    let uptime = START.get_or_init(Instant::now).elapsed().as_secs_f64();
    (time, uptime)
}

/// 一条现在时刻的记录。
fn record(level: LogLevel, category: &str, text: &str) -> LogRecord {
    LogRecord {
        time: clock().0,
        level,
        category: category.to_owned(),
        text: text.to_owned(),
    }
}

/// 格式化一条记录（锁外），再在锁内写入。
fn write(level: LogLevel, category: &str, text: &str) {
    let line = record(level, category, text).line();
    let (time, uptime) = clock();
    if let Some(sink) = sink().as_mut() {
        sink.write_line(&line, time, uptime);
    }
}

/// 把文字里的用户目录换成 `%USERPROFILE%`（路径里有 Windows 用户名，常常就是真名）。
/// 用户目录取环境变量 USERPROFILE，没有时原样返回。不区分大小写比较（Windows 路径不分大小写）。
pub fn redact(text: &str) -> String {
    let profile = std::env::var("USERPROFILE").unwrap_or_default();
    redact_profile(text, &profile)
}

/// `redact` 的实现：profile 是用户目录。
fn redact_profile(text: &str, profile: &str) -> String {
    let profile = profile.trim_end_matches(['\\', '/']);
    // 太短的值（如 `C:`）换掉反而误伤。
    if profile.chars().count() < 4 {
        return text.to_owned();
    }
    let lower_text = text.to_lowercase();
    let lower_profile = profile.to_lowercase();
    // 小写后字节长度变了（少见的大小写映射）时不敢按位置替换，退回到区分大小写的替换。
    if lower_text.len() != text.len() || lower_profile.len() != profile.len() {
        return text.replace(profile, "%USERPROFILE%");
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = 0;
    for (start, _) in lower_text.match_indices(&lower_profile) {
        if start < rest {
            continue;
        }
        out.push_str(&text[rest..start]);
        out.push_str("%USERPROFILE%");
        rest = start + profile.len();
    }
    out.push_str(&text[rest..]);
    out
}

/// 装 panic 钩子：先写一条 fault（线程名、位置、消息，去掉用户目录），再交给原来的钩子。
pub fn install_panic_hook() {
    const LOG: Logger = Logger::new("Fault");
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let payload = info.payload();
        let message = payload
            .downcast_ref::<&str>()
            .map(|s| (*s).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "<非文字的 panic>".to_owned());
        let location = info
            .location()
            .map_or_else(String::new, |l| format!("{}:{}", l.file(), l.line()));
        let thread = std::thread::current();
        let thread = thread.name().unwrap_or("<未命名>");
        LOG.fault(redact(&format!("panic 于线程 {thread}，{location}：{message}")));
        flush();
        previous(info);
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 文件输出：限速后先写一行丢弃的条数；连续 3 次失败后停止。
    #[test]
    fn sink_rate_limit_and_failures() {
        let dir = std::env::temp_dir().join(format!("eveo-sink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let layout = LogFileLayout::in_dir(&dir);
        let mut sink = FileLogSink::new(layout.clone(), LogRotationPolicy::default());
        sink.limiter = LogRateLimiter::new(2, 1.0);
        for index in 0..5 {
            sink.write_line(&format!("line {index}"), 0.0, 0.0);
        }
        // 一秒后补回一个令牌：先写丢弃说明，再写这一行。
        sink.write_line("after", 0.0, 1.0);
        let text = std::fs::read_to_string(layout.current()).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[..2], ["line 0", "line 1"]);
        assert!(
            lines[2].ends_with("NOTICE [Log] … dropped 3 lines"),
            "{}",
            lines[2]
        );
        assert_eq!(lines[3], "after");
        let _ = std::fs::remove_dir_all(&dir);

        // 目录的位置被一个文件占着：建目录总是失败，3 次后停止。
        let blocker = std::env::temp_dir().join(format!("eveo-sink-blocker-{}", std::process::id()));
        std::fs::write(&blocker, b"x").unwrap();
        let mut broken = FileLogSink::new(
            LogFileLayout::in_dir(blocker.join("logs")),
            LogRotationPolicy::default(),
        );
        for uptime in 0..3 {
            assert!(!broken.is_stopped());
            broken.write_line("x", 0.0, f64::from(uptime));
        }
        assert!(broken.is_stopped());
        let _ = std::fs::remove_file(&blocker);
    }

    /// 用户目录换成 %USERPROFILE%，不区分大小写；太短的值不换。
    #[test]
    fn redacts_user_profile() {
        let profile = r"C:\Users\Alice\";
        assert_eq!(
            redact_profile(r"打不开 c:\users\alice\AppData\x.json 与 C:\Users\Alice", profile),
            r"打不开 %USERPROFILE%\AppData\x.json 与 %USERPROFILE%"
        );
        assert_eq!(redact_profile(r"C:\x", "C:"), r"C:\x");
        assert_eq!(redact_profile("无路径", ""), "无路径");
    }

    /// 级别：默认 info；没装文件输出时都不写。
    #[test]
    fn levels() {
        assert_eq!(minimum_level(), LogLevel::Info);
        assert!(!enabled(LogLevel::Fault), "没装时不写");
        set_minimum_level(LogLevel::Debug);
        assert_eq!(minimum_level(), LogLevel::Debug);
        set_minimum_level(LogLevel::Info);
        // 没装时 debug 的闭包不求值。
        Logger::new("Test").debug(|| -> String { panic!("不应求值") });
    }
}
