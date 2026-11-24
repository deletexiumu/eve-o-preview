// SPDX-License-Identifier: GPL-3.0-or-later
//
// AMD、Intel 驱动限帧的子进程。应用自己以 `--frame-cap-helper <帧数|off>` 再启动一次，在这个子进程里加载
// AMD 的 ADLX 或 Intel 的 IGCL、选显卡、按规则改驱动、写还原记录，最后往标准输出写一行 JSON 报告就退出。
//
// 为什么要另起进程：这两家的调用是按头文件写的，开发时手边没有这两种显卡，没有实测过。驱动库里的崩溃
// （访问违例）在进程内没法拦住，放在主程序里一旦出错，AMD、Intel 用户每次启动都会闪退。放在子进程里，
// 崩溃只是子进程退出，主程序拿退出码当错误码显示在设置页上，用户可以照着反馈。NVIDIA 已经实测，仍在进程内做。
//
// 子进程不开窗口、不走单实例检查（在 main 里最先判断），30 秒内没结束就结束它（驱动卡住时不让后台线程一直等）。
// 手动排查时可以在 PowerShell 里运行 `& "EVE-O Preview.exe" --frame-cap-helper off | Out-String` 看报告：
// off 只检测与还原，不会打开限帧。

//! AMD、Intel 驱动限帧的子进程：起子进程、子进程里的同步。

use std::io::{Read, Write};
use std::os::windows::process::CommandExt;
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

use eveo_app_core::frame_cap::{helper_report, run_value};
use eveo_app_core::paths::DataPaths;
use eveo_core::frame_cap::value::choose_vendor;
use eveo_core::frame_cap::{SyncError, SyncReport, Vendor};
use eveo_platform_win::amd::Amd;
use eveo_platform_win::intel::Intel;

/// 子进程的命令行开关。
const ARG: &str = "--frame-cap-helper";
/// 子进程最多跑多久。
const TIMEOUT: Duration = Duration::from_secs(30);
/// 不给子进程开控制台窗口（CREATE_NO_WINDOW）。应用是 windows 子系统，本来也不会开，这里只是保险。
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 命令行是子进程的开关时在这里同步并返回退出码；否则返回 `None`，照常启动应用。
pub fn run_if_requested() -> Option<ExitCode> {
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() != Some(ARG) {
        return None;
    }
    // 帧数解不出（off 或其他）时按关闭处理：只检测与还原，不会误开限帧。
    let desired = args.next().and_then(|arg| arg.parse::<u32>().ok());
    let paths = DataPaths::from_env().unwrap_or_else(|| DataPaths::new(".", None));
    let report = sync(desired, &paths);
    // 没有标准输出（手动双击运行）时写不出去，忽略即可。
    let _ = writeln!(std::io::stdout(), "{}", report.encode());
    Some(ExitCode::SUCCESS)
}

/// 子进程里的一次同步：打开 AMD 与 Intel，选一家（独显优先），按规则改驱动。
fn sync(desired: Option<u32>, paths: &DataPaths) -> SyncReport {
    let amd = Amd::open();
    let intel = Intel::open();
    let choice = choose_vendor(
        amd.as_ref().ok().map(Amd::kind),
        intel.as_ref().ok().map(Intel::kind),
    );
    match (choice, amd, intel) {
        (Some(Vendor::Amd), Ok(mut amd), _) => SyncReport {
            vendor: Some(Vendor::Amd),
            result: run_value(&mut amd, &paths.frame_cap_record_file(Vendor::Amd), desired),
        },
        (Some(Vendor::Intel), _, Ok(mut intel)) => SyncReport {
            vendor: Some(Vendor::Intel),
            result: run_value(&mut intel, &paths.frame_cap_record_file(Vendor::Intel), desired),
        },
        // 两家都不能用：其中一家是出错（而不只是没有这家显卡）时报那个错，用户能看到错误码并反馈。
        (_, amd, intel) => match (amd.err(), intel.err()) {
            (Some(error @ (SyncError::NeedsAdmin | SyncError::Failed(_))), _) => SyncReport {
                vendor: Some(Vendor::Amd),
                result: Err(error),
            },
            (_, Some(error @ (SyncError::NeedsAdmin | SyncError::Failed(_)))) => SyncReport {
                vendor: Some(Vendor::Intel),
                result: Err(error),
            },
            _ => SyncReport {
                vendor: None,
                result: Err(SyncError::Unsupported),
            },
        },
    }
}

/// 在主程序的后台线程里调用：起子进程同步一次，等它结束并解读报告。起不来、崩溃或超时都按失败处理。
pub fn spawn(desired: Option<u32>) -> SyncReport {
    let failed = |code| SyncReport {
        vendor: None,
        result: Err(SyncError::Failed(code)),
    };
    let Ok(exe) = std::env::current_exe() else {
        return failed(-1);
    };
    let child = Command::new(exe)
        .arg(ARG)
        .arg(desired.map_or_else(|| "off".to_owned(), |fps| fps.to_string()))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
    let Ok(mut child) = child else {
        return failed(-1);
    };
    // 报告只有一行，但仍在另一个线程里读，免得子进程写满管道时双方互等。
    let stdout = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(mut stdout) = stdout {
            let _ = stdout.read_to_end(&mut bytes);
        }
        bytes
    });
    let deadline = Instant::now() + TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            // 超时或查不了状态：结束子进程，按失败处理。
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let bytes = reader.join().unwrap_or_default();
    helper_report(&bytes, status.and_then(|status| status.code()))
}
