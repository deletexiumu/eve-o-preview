// SPDX-License-Identifier: GPL-3.0-or-later
//
// 真机核对 NVIDIA 驱动限帧（`eveo-probe nvidia`）：不开应用，直接走应用用的同一套规则与驱动读写，
// 看驱动里 exefile.exe 的「最大帧速率」能不能读、能不能写、关闭后能不能还原，以及要不要管理员权限。
//
// - `nvidia status`：打印 exefile.exe 所在的驱动配置文件与用户设的帧数；不是 NVIDIA 时打印状态码。
// - `nvidia enable <帧数> --record <文件>`：按 eveo_core::frame_cap::plan_enable 写驱动，记录写到文件。
// - `nvidia disable --record <文件>`：按记录还原，成功后删掉记录文件。
// 每条命令都打印执行的步骤与操作后的现状；失败时打印 NVAPI 状态码并以 1 退出（-137 表示要管理员权限）。

//! 真机核对 NVIDIA 驱动限帧。

use std::path::Path;

use eveo_core::frame_cap::{self, OwnershipRecord};
use eveo_platform_win::nvidia;

use crate::option;

/// 入口：`nvidia status | enable <帧数> --record <文件> | disable --record <文件>`。
pub fn run(args: &[String]) -> i32 {
    let usage = || {
        eprintln!("用法：eveo-probe nvidia status | enable <帧数> --record <文件> | disable --record <文件>");
        2
    };
    match args.first().map(String::as_str) {
        Some("status") => status(),
        Some("enable") => {
            let (Some(fps), Some(record)) = (
                args.get(1).and_then(|v| v.parse::<i64>().ok()),
                option(args, "--record"),
            ) else {
                return usage();
            };
            change(Path::new(record), Some(frame_cap::clamp_fps(fps)))
        }
        Some("disable") => match option(args, "--record") {
            Some(record) => change(Path::new(record), None),
            None => usage(),
        },
        _ => usage(),
    }
}

/// 打印现状。
fn status() -> i32 {
    match nvidia::read_state() {
        Ok(state) => {
            println!("profile={:?} user_fps={:?}", state.profile, state.user_fps);
            0
        }
        Err(code) => report_error(code),
    }
}

/// 打开（`fps` 有值）或关闭：读记录、按规则求计划、执行，再写回或删掉记录。
fn change(record_path: &Path, fps: Option<u32>) -> i32 {
    let record = std::fs::read(record_path)
        .ok()
        .and_then(|bytes| OwnershipRecord::decode(&bytes));
    println!("记录：{record:?}");
    let result = nvidia::apply(|state| {
        println!(
            "操作前：profile={:?} user_fps={:?}",
            state.profile, state.user_fps
        );
        match fps {
            Some(fps) => frame_cap::plan_enable(state, record.as_ref(), fps),
            None => frame_cap::plan_disable(state, record.as_ref()),
        }
    });
    let (plan, after) = match result {
        Ok(done) => done,
        Err(code) => return report_error(code),
    };
    println!("步骤：{:?}", plan.steps);
    println!(
        "操作后：profile={:?} user_fps={:?}",
        after.profile, after.user_fps
    );
    // 记录跟着计划走：有记录就写，没有就删。
    let written = match &plan.record {
        Some(record) => std::fs::write(record_path, record.encode()),
        None => std::fs::remove_file(record_path).or_else(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                Ok(())
            } else {
                Err(e)
            }
        }),
    };
    if let Err(error) = written {
        eprintln!("写记录失败：{error}");
        return 1;
    }
    0
}

/// 打印失败的原因，返回退出码 1。
fn report_error(code: i32) -> i32 {
    let reason = if nvidia::is_not_nvidia(code) {
        "不是 NVIDIA 显卡或驱动"
    } else if code == nvidia::INVALID_USER_PRIVILEGE {
        "要管理员权限"
    } else {
        "其他错误"
    };
    eprintln!("NVAPI 状态码 {code}：{reason}");
    1
}
