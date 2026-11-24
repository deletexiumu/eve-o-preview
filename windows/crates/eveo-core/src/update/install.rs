// SPDX-License-Identifier: GPL-3.0-or-later
//
// 替换 exe 与回滚的规则（docs/windows/architecture.md 6.3 节第 5、6 条）。文件操作在平台层，这里只决定做什么。
//
// 便携版的 exe 放在用户自己选的文件夹里，安装就是在同一个文件夹里换掉这个文件：
// 1. 旧版把新 exe 写成 `EVE-O Preview.exe.new`；
// 2. 把正在运行的自己改名为 `EVE-O Preview.exe.old`（Windows 允许给运行中的 exe 改名，但不允许删除或覆盖）；
// 3. 把 `.new` 改名为 `EVE-O Preview.exe`；第 3 步失败时把 `.old` 改回来，什么都没变；
// 4. 在 state.json 记下「待确认的替换」（新版本、旧版本、时刻），带 `--after-update <旧进程编号>` 启动新 exe，自己退出。
//
// 新版启动后按 `on_launch` 的结论处理：
// - 第一次启动：记下启动时刻，运行满 30 秒（或在此之前正常退出）就确认：记一条成功的安装记录，删除 `.old`；
// - 已经启动过一次却没有确认（崩溃了、被结束了）：回滚，把自己改名为 `.failed`、`.old` 改回 exe，启动旧版后退出，
//   记一条失败的安装记录（`launchFailed`）。旧版下次启动时删除 `.failed`；
// - 记录里的版本不是正在运行的版本（替换没完成、或用户自己启动了别的副本）：丢掉记录，不回滚。
// 回滚只做一次：旧版启动时没有待确认的替换，不会再来回换。

//! 替换 exe 与回滚的规则。

use super::version::SemanticVersion;

/// 新版运行多久算启动成功（秒）。
pub const CONFIRM_DELAY: f64 = 30.0;
/// 新 exe 先写成的文件名后缀。
pub const STAGED_SUFFIX: &str = ".new";
/// 换下来的旧 exe 的文件名后缀。
pub const OLD_SUFFIX: &str = ".old";
/// 回滚时换下来的新 exe 的文件名后缀。
pub const FAILED_SUFFIX: &str = ".failed";
/// 新进程的命令行参数：后面跟旧进程的编号，新进程先等旧进程退出，再做单实例检查。
pub const AFTER_UPDATE_ARG: &str = "--after-update";
/// 回滚失败时安装记录里的错误名。
pub const LAUNCH_FAILED_CODE: &str = "launchFailed";

/// 待确认的替换：旧版换好 exe、启动新版之前写进 state.json。
#[derive(Debug, Clone, PartialEq)]
pub struct PendingSwap {
    /// 换上的版本。
    pub version: String,
    /// 换下的版本。
    pub from_version: String,
    /// 替换的时刻。
    pub at: f64,
    /// 新版第一次启动的时刻；还没启动过时是 None。
    pub launched_at: Option<f64>,
}

/// 一次安装的结果，与 macOS 的 `InstallRecord` 字段相同。
#[derive(Debug, Clone, PartialEq)]
pub struct InstallRecord {
    /// 要装的版本。
    pub version: String,
    /// 安装前的版本。
    pub from_version: String,
    /// 安装（或回滚）的时刻。
    pub at: f64,
    /// 是否成功。
    pub succeeded: bool,
    /// 失败时的错误名，如 `checksumMismatch`、`launchFailed`。
    pub error_code: Option<String>,
}

/// 启动时对待确认的替换要做的事。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchDecision {
    /// 没有待确认的替换：照常启动，顺便删掉遗留的 `.old`、`.new`、`.failed`。
    Normal,
    /// 新版第一次启动：记下启动时刻，等满 `CONFIRM_DELAY` 或正常退出时确认。
    AwaitConfirmation,
    /// 新版上次启动后没有确认：回滚到旧版。
    RollBack,
    /// 记录与正在运行的版本对不上：丢掉记录，照常启动。
    Abandon,
}

/// 启动时的结论。running 是正在运行的构建标签（没有时用版本号）。
///
/// 「启动过一次」靠 launched_at 判断：新版第一次启动时立即写下它，之后崩溃、被结束或断电，
/// 下一次启动看到它还在，就知道上一次没有走到确认。正常退出也会确认，所以只有异常结束才会回滚。
pub fn on_launch(pending: Option<&PendingSwap>, running: &str) -> LaunchDecision {
    let Some(pending) = pending else {
        return LaunchDecision::Normal;
    };
    // 按语义化版本比较（忽略构建元数据），`0.9.1` 与 `0.9.1+abc` 算同一个版本。
    let same = match (
        SemanticVersion::parse(&pending.version),
        SemanticVersion::parse(running),
    ) {
        (Some(expected), Some(actual)) => expected == actual,
        _ => false,
    };
    match (same, pending.launched_at) {
        (false, _) => LaunchDecision::Abandon,
        (true, None) => LaunchDecision::AwaitConfirmation,
        (true, Some(_)) => LaunchDecision::RollBack,
    }
}

/// 确认成功时的安装记录。
pub fn confirmed(pending: &PendingSwap, now: f64) -> InstallRecord {
    InstallRecord {
        version: pending.version.clone(),
        from_version: pending.from_version.clone(),
        at: now,
        succeeded: true,
        error_code: None,
    }
}

/// 回滚时的安装记录。
pub fn rolled_back(pending: &PendingSwap, now: f64) -> InstallRecord {
    InstallRecord {
        version: pending.version.clone(),
        from_version: pending.from_version.clone(),
        at: now,
        succeeded: false,
        error_code: Some(LAUNCH_FAILED_CODE.to_owned()),
    }
}

/// 从命令行参数里取 `--after-update <进程编号>`；没有或编号不是数字时返回 None。
pub fn after_update_pid<I, S>(args: I) -> Option<u32>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut args = args.into_iter();
    // 找到参数名之后，紧跟的那一个就是编号；参数名出现在最后时没有编号。
    while let Some(arg) = args.next() {
        if arg.as_ref() == AFTER_UPDATE_ARG {
            return args.next()?.as_ref().parse().ok();
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 换上 0.9.1、换下 0.9.0 的记录。
    fn pending(launched_at: Option<f64>) -> PendingSwap {
        PendingSwap {
            version: "0.9.1".into(),
            from_version: "0.9.0".into(),
            at: 100.0,
            launched_at,
        }
    }

    /// 四种结论：没有记录、第一次启动、启动过没确认、版本对不上。
    #[test]
    fn launch_decisions() {
        assert_eq!(on_launch(None, "0.9.1"), LaunchDecision::Normal);
        assert_eq!(
            on_launch(Some(&pending(None)), "0.9.1"),
            LaunchDecision::AwaitConfirmation
        );
        // 构建元数据不影响比较。
        assert_eq!(
            on_launch(Some(&pending(None)), "0.9.1+ci.5"),
            LaunchDecision::AwaitConfirmation
        );
        assert_eq!(
            on_launch(Some(&pending(Some(130.0))), "0.9.1"),
            LaunchDecision::RollBack
        );
        // 旧版自己启动了（替换没完成），或版本号写坏了：丢掉记录。
        assert_eq!(on_launch(Some(&pending(None)), "0.9.0"), LaunchDecision::Abandon);
        assert_eq!(
            on_launch(Some(&pending(Some(130.0))), "0.9.0"),
            LaunchDecision::Abandon
        );
        assert_eq!(on_launch(Some(&pending(None)), "debug"), LaunchDecision::Abandon);
    }

    /// 成功与回滚的安装记录。
    #[test]
    fn records() {
        let ok = confirmed(&pending(Some(130.0)), 160.0);
        assert!(ok.succeeded && ok.error_code.is_none());
        assert_eq!(
            (ok.version.as_str(), ok.from_version.as_str(), ok.at),
            ("0.9.1", "0.9.0", 160.0)
        );
        let failed = rolled_back(&pending(Some(130.0)), 200.0);
        assert!(!failed.succeeded);
        assert_eq!(failed.error_code.as_deref(), Some("launchFailed"));
    }

    /// 命令行参数：取紧跟在参数名后面的编号。
    #[test]
    fn after_update_argument() {
        assert_eq!(
            after_update_pid(["app.exe", "--after-update", "4242"]),
            Some(4242)
        );
        assert_eq!(
            after_update_pid(["app.exe", "--x", "--after-update", "7", "--y"]),
            Some(7)
        );
        assert_eq!(after_update_pid(["app.exe"]), None);
        assert_eq!(after_update_pid(["app.exe", "--after-update"]), None);
        assert_eq!(after_update_pid(["app.exe", "--after-update", "abc"]), None);
    }

    /// 错误名与 macOS 的写法相同。
    #[test]
    fn error_codes() {
        use crate::update::models::UpdateError;
        assert_eq!(UpdateError::ChecksumMismatch.code(), "checksumMismatch");
        assert_eq!(UpdateError::ReplaceFailed(5).code(), "replaceFailed");
        assert_eq!(UpdateError::ArchiveInvalid("x".into()).code(), "archiveInvalid");
    }
}
