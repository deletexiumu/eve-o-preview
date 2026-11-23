// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「环境检查」页的数据（架构文档 4.1、4.2 节）。页上两部分刷新的时机不同：
// - 权限：客户端随时启动、退出，应用每处理一批事件就填一次（只是比较几个值，不碰系统）。
// - 日志目录：要读磁盘，只在打开设置窗口、配置变化与「重新检查」时查一次。
// 这里只有与平台无关的部分：日志目录的推算与子文件夹的检查用标准库，管理员权限由应用从平台层取来。

//! 「环境检查」页。

use std::path::Path;

use slint::ComponentHandle;

use crate::{EnvironmentModel, SettingsWindow};

/// 预警与翻译读的子文件夹。
pub const CHATLOGS: &str = "Chatlogs";
/// 受击提醒读的子文件夹。
pub const GAMELOGS: &str = "Gamelogs";

/// 日志目录的检查结果。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LogFolders {
    /// 用到的日志目录（logs 那一级）。
    pub root: String,
    /// 目录在不在。
    pub root_found: bool,
    /// Chatlogs 在不在。
    pub chatlogs_found: bool,
    /// Gamelogs 在不在。
    pub gamelogs_found: bool,
}

/// 用到的日志目录：设置了就用设置的，否则用自动查找的位置。
///
/// 用户常把 Chatlogs 或 Gamelogs 本身填进来（「提醒」页的说明写的是 logs 文件夹，但很容易选深一级），
/// 这时取它的上一级，两个子文件夹都从 logs 那一级找。按字符串处理而不用 `Path`：
/// 配置里是 Windows 路径，在 Linux 上跑测试时 `Path` 不认反斜杠。
pub fn log_root(configured: Option<&str>, automatic: &str) -> String {
    let path = configured
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .unwrap_or(automatic);
    // 去掉末尾的分隔符，再看最后一段是不是两个子文件夹之一（Windows 的文件名不分大小写）。
    let trimmed = path.trim_end_matches(['\\', '/']);
    if let Some(split) = trimmed.rfind(['\\', '/']) {
        let last = &trimmed[split + 1..];
        if last.eq_ignore_ascii_case(CHATLOGS) || last.eq_ignore_ascii_case(GAMELOGS) {
            return trimmed[..split].to_owned();
        }
    }
    trimmed.to_owned()
}

/// 读磁盘，看日志目录与两个子文件夹在不在。读不到（没有权限、网络盘断开）按不在处理。
pub fn check_log_folders(root: &str) -> LogFolders {
    let base = Path::new(root);
    LogFolders {
        root: root.to_owned(),
        root_found: base.is_dir(),
        chatlogs_found: base.join(CHATLOGS).is_dir(),
        gamelogs_found: base.join(GAMELOGS).is_dir(),
    }
}

/// 填权限部分。`elevated_clients` 是以管理员运行的客户端显示的名字（登录界面的客户端是「EVE」）。
pub fn show_privileges(ui: &SettingsWindow, self_elevated: bool, elevated_clients: &[String]) {
    let model = ui.global::<EnvironmentModel>();
    model.set_self_elevated(self_elevated);
    // 个数放得进 i32：同时开的客户端不会有几十亿个。
    model.set_elevated_count(elevated_clients.len() as i32);
    // 名字用界面语言的列表分隔符连起来（中文「、」，英文「, 」）；Slint 没有连接字符串数组的函数。
    let separator = eveo_l10n::settings(crate::language()).list_separator();
    let names = elevated_clients.join(separator);
    // 没变时不重写：这个函数每批事件调一次。
    if model.get_elevated_names() != names.as_str() {
        model.set_elevated_names(names.into());
    }
}

/// 填日志目录部分。`checked_time` 是这次检查的本地时间（时:分:秒），显示在「重新检查」旁边。
pub fn show_logs(ui: &SettingsWindow, logs: &LogFolders, checked_time: &str) {
    let model = ui.global::<EnvironmentModel>();
    model.set_checked_time(checked_time.into());
    model.set_log_directory(logs.root.as_str().into());
    model.set_log_found(logs.root_found);
    model.set_chatlogs_found(logs.chatlogs_found);
    model.set_gamelogs_found(logs.gamelogs_found);
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// 日志目录：设置的优先，空白算没设置；填成子文件夹时取上一级；末尾的分隔符去掉。
    #[test]
    fn log_root_choice() {
        let automatic = r"C:\Users\a\Documents\EVE\logs";
        assert_eq!(log_root(None, automatic), automatic);
        assert_eq!(log_root(Some("   "), automatic), automatic);
        assert_eq!(log_root(Some(r"D:\EVE\logs\"), automatic), r"D:\EVE\logs");
        // 子文件夹不分大小写，正反斜杠都认。
        assert_eq!(log_root(Some(r"D:\EVE\logs\gamelogs"), automatic), r"D:\EVE\logs");
        assert_eq!(log_root(Some("D:/EVE/logs/Chatlogs/"), automatic), "D:/EVE/logs");
        // 名字只是以 Gamelogs 结尾的别的文件夹不算。
        assert_eq!(log_root(Some(r"D:\MyGamelogs"), automatic), r"D:\MyGamelogs");
    }

    /// 子文件夹的检查读真实的磁盘：在临时目录里建一个 logs，只放 Chatlogs。
    #[test]
    fn folders_on_disk() {
        // 目录名带进程号，并行跑测试的几个进程互不干扰。
        let root = std::env::temp_dir().join(format!("eveo-env-test-{}", std::process::id()));
        std::fs::create_dir_all(root.join(CHATLOGS)).unwrap();
        let found = check_log_folders(root.to_str().unwrap());
        assert!(found.root_found && found.chatlogs_found && !found.gamelogs_found);
        std::fs::remove_dir_all(&root).unwrap();
        let missing = check_log_folders(root.to_str().unwrap());
        assert!(!missing.root_found && !missing.chatlogs_found);
    }

    /// 页上的值：名字按语言的分隔符连起来，个数与开关对得上。
    pub(crate) fn check_page(ui: &SettingsWindow) {
        let model = ui.global::<EnvironmentModel>();
        show_privileges(ui, false, &["Alpha".to_owned(), "EVE".to_owned()]);
        assert_eq!(model.get_elevated_count(), 2);
        let separator = eveo_l10n::settings(crate::language()).list_separator();
        assert_eq!(
            model.get_elevated_names(),
            format!("Alpha{separator}EVE").as_str()
        );
        assert!(!model.get_self_elevated());
        show_privileges(ui, true, &[]);
        assert_eq!(model.get_elevated_count(), 0);
        assert_eq!(model.get_elevated_names(), "");
        let logs = LogFolders {
            root: r"D:\EVE\logs".to_owned(),
            root_found: true,
            chatlogs_found: false,
            gamelogs_found: true,
        };
        show_logs(ui, &logs, "22:51:03");
        assert_eq!(model.get_log_directory(), r"D:\EVE\logs");
        assert_eq!(model.get_checked_time(), "22:51:03");
        assert!(model.get_log_found() && !model.get_chatlogs_found() && model.get_gamelogs_found());
    }
}
