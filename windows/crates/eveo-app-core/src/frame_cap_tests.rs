// SPDX-License-Identifier: GPL-3.0-or-later
//
// 限帧控制器的用例：用假的驱动函数（内存里的一份「驱动现状」）走一遍打开、改帧数、关闭与失败。
// 驱动函数是普通函数指针，不能捕获变量，所以假驱动的状态放在静态的 Mutex 里；
// 用到它的场景都在同一个用例里按顺序跑，免得并行的用例互相改。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use eveo_core::frame_cap::{OWN_PROFILE_NAME, Step};

use super::*;

/// 假驱动的现状。
static FAKE: Mutex<DriverState> = Mutex::new(DriverState {
    profile: None,
    user_fps: None,
});

/// 假驱动：按计划改内存里的现状。
fn fake_driver(planner: &mut dyn FnMut(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32> {
    let mut state = FAKE.lock().expect("假驱动");
    let plan = planner(&state);
    for step in &plan.steps {
        match step {
            Step::CreateOwnProfile => state.profile = Some(OWN_PROFILE_NAME.to_owned()),
            Step::SetFps(fps) => state.user_fps = Some(*fps),
            Step::DeleteFps => state.user_fps = None,
            Step::DeleteOwnProfile => *state = DriverState::default(),
        }
    }
    Ok((plan, state.clone()))
}

/// 没有 NVIDIA 的驱动函数。
fn no_nvidia(_: &mut dyn FnMut(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32> {
    Err(eveo_core::frame_cap::NVAPI_LIBRARY_NOT_FOUND)
}

/// 要管理员权限的驱动函数。
fn needs_admin(_: &mut dyn FnMut(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32> {
    Err(eveo_core::frame_cap::NVAPI_INVALID_USER_PRIVILEGE)
}

/// 每个用例一个临时的记录文件位置。
fn record_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("eveo-frame-cap-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir.join("frame-cap.json")
}

/// 一直 tick 到后台的同步全部跑完（最多 5 秒）。
fn settle(controller: &mut FrameCapController) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while controller.running.is_some() && Instant::now() < deadline {
        controller.tick();
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(controller.running.is_none(), "同步没有跑完");
}

/// 打开、改帧数、关闭：驱动与记录文件都跟着变，关闭后整个还原。
#[test]
fn enable_change_and_disable() {
    let path = record_path("flow");
    let mut controller = FrameCapController::new(fake_driver, &path);
    assert_eq!(controller.status(), FrameCapStatus::Checking);

    // 启动时关闭：只检测，驱动不变，没有记录。
    controller.sync(None);
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::Ready);
    assert!(load_record(&path).is_none());

    // 打开：新建自己的配置文件，记下记录。
    controller.sync(Some(60));
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::Applied(60));
    assert!(load_record(&path).expect("记录").created_profile);

    // 同一个值不再碰驱动；改帧数时跑着又改：只同步最后的值。
    controller.sync(Some(60));
    assert!(controller.running.is_none());
    controller.sync(Some(45));
    controller.sync(Some(30));
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::Applied(30));
    assert_eq!(FAKE.lock().expect("假驱动").user_fps, Some(30));

    // 关闭：删掉自己的配置文件与记录。
    controller.sync(None);
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::Ready);
    assert_eq!(*FAKE.lock().expect("假驱动"), DriverState::default());
    assert!(load_record(&path).is_none());
}

/// 不是 NVIDIA：状态变成「不是 NVIDIA」，之后不再去碰驱动。
#[test]
fn not_nvidia_stops_trying() {
    let mut controller = FrameCapController::new(no_nvidia, record_path("none"));
    controller.sync(None);
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::NotNvidia);
    controller.sync(Some(60));
    assert!(controller.running.is_none());
}

/// 要管理员权限：状态说明这一点；用户改了值会重试，同一个值不重试。
#[test]
fn needs_admin_retries_only_on_change() {
    let mut controller = FrameCapController::new(needs_admin, record_path("admin"));
    controller.sync(Some(60));
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::NeedsAdmin);
    controller.sync(Some(60));
    assert!(controller.running.is_none());
    controller.sync(Some(50));
    assert!(controller.running.is_some());
    settle(&mut controller);
}

/// 记录文件：写下再读回；None 删掉文件，文件不在时也算成功。
#[test]
fn record_file_round_trip() {
    let path = record_path("record");
    let record = OwnershipRecord {
        profile: "EVE Online".into(),
        created_profile: false,
        original_fps: Some(144),
        applied_fps: 60,
    };
    save_record(&path, Some(&record)).expect("写");
    assert_eq!(load_record(&path), Some(record));
    save_record(&path, None).expect("删");
    assert!(load_record(&path).is_none());
    save_record(&path, None).expect("再删");
}
