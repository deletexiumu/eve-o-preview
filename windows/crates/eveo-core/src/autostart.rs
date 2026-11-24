// SPDX-License-Identifier: GPL-3.0-or-later
//
// 开机启动的规则（docs/windows/architecture.md 4.10 节）。Windows 独有，macOS 版没有这一项。
//
// 做法：在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下写一个字符串值，内容是带引号的 exe 路径
// 加 `--background`（启动时不弹设置窗口，安静地回到托盘）。不需要管理员权限，卸载时删掉这个值即可。
//
// 用户在任务管理器的「启动应用」里禁用启动项时，Run 下的值还在，系统另在
// `HKCU\...\Explorer\StartupApproved\Run` 下写一个同名的二进制值：第一个字节是偶数（02、06）表示启用，
// 奇数（03、07）表示禁用；值不存在等于启用。这时设置页显示开关为关，并说明「已在任务管理器里禁用」；
// 用户在本应用里重新打开开关时，删掉这个禁用标记并重写 Run 下的值。
//
// 修复：用户把整个文件夹挪了位置之后，Run 里记的 exe 已经不存在，下次登录什么也启动不了。应用启动时
// 发现这种情况（并且自己是以正式文件名运行的）就把值改成自己的路径。登记的 exe 还在时不动，
// 免得两份副本（例如测试版与正式版）互相改来改去。
//
// 这里只有纯规则：命令行的拼装与解析、状态的判断、要不要修复。读写注册表在平台层（eveo-platform-win）。

//! 开机启动的命令行与状态。

/// Run 下的值名。调试构建用另一个名字，测试时不会改掉正式版的启动项。
pub const VALUE_NAME: &str = "EVE-O Preview";
/// 调试构建的值名。
pub const DEBUG_VALUE_NAME: &str = "EVE-O Preview (Debug)";
/// 开机启动时带的参数：不弹设置窗口。
pub const BACKGROUND_ARG: &str = "--background";

/// 开机启动的状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutostartState {
    /// 没有登记。
    Off,
    /// 已登记，系统也允许。
    On,
    /// 已登记，但用户在任务管理器里禁用了。
    DisabledBySystem,
}

/// 写进 Run 的命令行：带引号的 exe 路径加 `--background`。路径里有空格（`EVE-O Preview.exe` 本身就有）
/// 也能被正确拆开；Windows 的路径里不会有引号，不需要转义。
pub fn command_line(exe: &str) -> String {
    format!("\"{exe}\" {BACKGROUND_ARG}")
}

/// 从 Run 的命令行里取出 exe 路径：带引号时取引号里的内容，不带引号时取到第一个空格为止。
/// 空串或引号不成对时返回 None。
pub fn exe_from_command(command: &str) -> Option<&str> {
    let command = command.trim();
    let path = match command.strip_prefix('"') {
        Some(rest) => &rest[..rest.find('"')?],
        // 不带引号的写法是用户或别的工具改的；按 Windows 拆命令行的习惯取第一个空格之前。
        None => command.split(' ').next()?,
    };
    (!path.is_empty()).then_some(path)
}

/// StartupApproved 下的二进制值是否表示启用：第一个字节是偶数时启用。值不存在或是空的也算启用
/// （没在任务管理器里改过的启动项本来就没有这个值）。
pub fn approved(data: Option<&[u8]>) -> bool {
    data.and_then(|bytes| bytes.first())
        .is_none_or(|first| first % 2 == 0)
}

/// 由 Run 下的值与 StartupApproved 下的值算出状态。
pub fn state(command: Option<&str>, approval: Option<&[u8]>) -> AutostartState {
    match command {
        // 空的值等于没有登记：登录时系统什么也启动不了。
        None => AutostartState::Off,
        Some(text) if text.trim().is_empty() => AutostartState::Off,
        Some(_) if !approved(approval) => AutostartState::DisabledBySystem,
        Some(_) => AutostartState::On,
    }
}

/// 启动时是否要把登记的路径改成自己的：登记了、登记的 exe 已不存在、自己是以正式文件名运行的，
/// 而且登记的路径与自己的不同（不区分大小写，Windows 的路径不区分）。
pub fn needs_repair(command: Option<&str>, registered_exists: bool, own_exe: Option<&str>) -> bool {
    let (Some(command), Some(own)) = (command, own_exe) else {
        return false;
    };
    // 解析不了的值也修：它启动不了任何东西，而用户当初是想开机启动的。
    let differs = exe_from_command(command).is_none_or(|registered| !registered.eq_ignore_ascii_case(own));
    differs && !registered_exists
}

#[cfg(test)]
mod tests {
    //! 命令行的拼装与解析、状态与修复的判断。

    use super::*;

    /// 拼出的命令行能原样解析回路径，路径里的空格不影响。
    #[test]
    fn command_round_trip() {
        let exe = r"C:\Games\EVE-O Preview\EVE-O Preview.exe";
        let command = command_line(exe);
        assert_eq!(command, format!("\"{exe}\" --background"));
        assert_eq!(exe_from_command(&command), Some(exe));
        // 不带引号的写法取第一个空格之前；引号不成对与空串返回 None。
        assert_eq!(
            exe_from_command(r"C:\Tools\eveo.exe --background"),
            Some(r"C:\Tools\eveo.exe")
        );
        assert_eq!(exe_from_command("\"C:\\broken.exe --background"), None);
        assert_eq!(exe_from_command("   "), None);
        assert_eq!(exe_from_command("\"\" --background"), None);
    }

    /// StartupApproved：偶数启用、奇数禁用、没有或空的算启用。
    #[test]
    fn approval_bytes() {
        assert!(approved(None));
        assert!(approved(Some(&[])));
        assert!(approved(Some(&[0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])));
        assert!(approved(Some(&[0x06])));
        assert!(!approved(Some(&[0x03, 0x11, 0x22])));
        assert!(!approved(Some(&[0x07])));
    }

    /// 状态：没有登记、空值、启用与被系统禁用。
    #[test]
    fn states() {
        let command = command_line(r"C:\EVE-O Preview.exe");
        assert_eq!(state(None, None), AutostartState::Off);
        assert_eq!(state(Some(" "), Some(&[0x03])), AutostartState::Off);
        assert_eq!(state(Some(&command), None), AutostartState::On);
        assert_eq!(state(Some(&command), Some(&[0x02])), AutostartState::On);
        assert_eq!(
            state(Some(&command), Some(&[0x03])),
            AutostartState::DisabledBySystem
        );
    }

    /// 修复只在登记的 exe 不在、自己有正式路径、而且两者不同时进行。
    #[test]
    fn repair_rules() {
        let old = command_line(r"C:\Old\EVE-O Preview.exe");
        let own = Some(r"D:\New\EVE-O Preview.exe");
        assert!(needs_repair(Some(&old), false, own));
        // 登记的 exe 还在：可能是另一份副本，不动。
        assert!(!needs_repair(Some(&old), true, own));
        // 没登记、或自己不是以正式文件名运行：不动。
        assert!(!needs_repair(None, false, own));
        assert!(!needs_repair(Some(&old), false, None));
        // 登记的就是自己（大小写不同）：不用修。
        let same = command_line(r"d:\new\eve-o preview.exe");
        assert!(!needs_repair(Some(&same), false, own));
        // 解析不了的值：修。
        assert!(needs_repair(Some("\"broken"), false, own));
    }
}
