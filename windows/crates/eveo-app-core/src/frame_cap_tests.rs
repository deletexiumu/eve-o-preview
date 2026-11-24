// SPDX-License-Identifier: GPL-3.0-or-later
//
// 限帧控制器与一次同步的用例：用假的驱动（内存里的一份「驱动现状」）走一遍打开、改帧数、关闭与失败。
// NVIDIA 的驱动函数是普通函数指针，不能捕获变量，所以假驱动的状态放在静态的 Mutex 里；
// 用到它的场景都在同一个用例里按顺序跑，免得并行的用例互相改。AMD、Intel 的假驱动是普通结构体。

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use eveo_core::frame_cap::{OWN_PROFILE_NAME, Step};

use super::*;

/// 假 NVIDIA 驱动的现状。
static FAKE: Mutex<DriverState> = Mutex::new(DriverState {
    profile: None,
    user_fps: None,
});

/// 假 NVIDIA 驱动：按计划改内存里的现状。
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

/// 每个用例一个临时的记录文件位置。
fn record_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("eveo-frame-cap-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir.join("frame-cap.json")
}

/// 用假 NVIDIA 驱动同步的控制器。
fn nvidia_controller(path: PathBuf) -> FrameCapController {
    FrameCapController::new(move |desired| SyncReport {
        vendor: Some(Vendor::Nvidia),
        result: run_nvidia(fake_driver, &path, desired),
    })
}

/// 总是返回同一个结果的控制器。
fn fixed(vendor: Option<Vendor>, error: SyncError) -> FrameCapController {
    FrameCapController::new(move |_| SyncReport {
        vendor,
        result: Err(error),
    })
}

/// 一直 tick 到后台的同步全部跑完（最多 5 秒）。
fn settle(controller: &mut FrameCapController) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while controller.running.is_some() && Instant::now() < deadline {
        controller.tick(Instant::now());
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(controller.running.is_none(), "同步没有跑完");
}

/// NVIDIA 打开、改帧数、关闭：驱动与记录文件都跟着变，关闭后整个还原。
#[test]
fn enable_change_and_disable() {
    let path = record_path("flow");
    let mut controller = nvidia_controller(path.clone());
    assert_eq!(controller.status(), FrameCapStatus::Checking);
    assert_eq!(controller.vendor(), None);

    // 启动时关闭：只检测，驱动不变，没有记录。
    controller.sync(None);
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::Ready);
    assert_eq!(controller.vendor(), Some(Vendor::Nvidia));
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

/// 没有能用的显卡：状态变成「不支持」，之后不再去碰驱动。
#[test]
fn unsupported_stops_trying() {
    let mut controller = fixed(None, SyncError::Unsupported);
    controller.sync(None);
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::Unsupported);
    controller.sync(Some(60));
    assert!(controller.running.is_none());
}

/// 要管理员权限：状态说明这一点；用户改了值会重试，同一个值不重试。
#[test]
fn needs_admin_retries_only_on_change() {
    let mut controller = fixed(Some(Vendor::Amd), SyncError::NeedsAdmin);
    controller.sync(Some(60));
    settle(&mut controller);
    assert_eq!(controller.status(), FrameCapStatus::NeedsAdmin);
    assert_eq!(controller.vendor(), Some(Vendor::Amd));
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

/// 推迟同步：期间多次改动只写最后的值；到期之前不碰驱动。
#[test]
fn sync_later_writes_only_final_value() {
    let mut controller = fixed(Some(Vendor::Nvidia), SyncError::NeedsAdmin);
    let start = Instant::now();
    controller.sync_later(Some(10), start);
    controller.sync_later(Some(45), start + Duration::from_millis(200));
    controller.sync_later(Some(450), start + Duration::from_millis(400));
    controller.tick(start + Duration::from_millis(900));
    assert!(controller.running.is_none());
    controller.tick(start + Duration::from_millis(1400));
    assert!(controller.running.is_some());
    assert_eq!(controller.requested, Some(Some(450)));
    settle(&mut controller);
    // 与上一次想要的值相同：不再推迟。
    controller.sync_later(Some(450), start);
    assert!(controller.deferred.is_none());
}

/// 假的 AMD、Intel 驱动：一块显卡上的一个值，可以设成读回别的值（驱动没接受）。
struct FakeValue {
    /// 驱动里的值。
    value: CapValue,
    /// 驱动接受的范围。
    range: (u32, u32),
    /// 为真时写入不生效。
    ignore_writes: bool,
    /// 写了几次。
    writes: usize,
}

impl ValueBackend for FakeValue {
    fn target(&self) -> &str {
        "gpu-1"
    }

    fn range(&self) -> (u32, u32) {
        self.range
    }

    fn read(&mut self) -> Result<CapValue, SyncError> {
        Ok(self.value)
    }

    fn write(&mut self, value: CapValue) -> Result<(), SyncError> {
        self.writes += 1;
        if !self.ignore_writes {
            self.value = value;
        }
        Ok(())
    }
}

/// AMD、Intel：打开时夹到驱动的范围并记下原值，核对时不写，关闭时写回原值并删掉记录。
#[test]
fn value_backend_enable_check_and_disable() {
    let path = record_path("value");
    let original = CapValue {
        enabled: false,
        fps: 144,
    };
    let mut fake = FakeValue {
        value: original,
        range: (30, 300),
        ignore_writes: false,
        writes: 0,
    };
    let on = run_value(&mut fake, &path, Some(10)).expect("打开");
    assert_eq!(
        on,
        Synced {
            steps: 1,
            applied: Some(30)
        }
    );
    assert_eq!(fake.value, CapValue::on(30));
    assert_eq!(load_value_record(&path).expect("记录").original, original);

    let check = run_value(&mut fake, &path, Some(10)).expect("核对");
    assert_eq!(check.steps, 0);
    assert_eq!(fake.writes, 1);

    let off = run_value(&mut fake, &path, None).expect("关闭");
    assert_eq!(
        off,
        Synced {
            steps: 1,
            applied: None
        }
    );
    assert_eq!(fake.value, original);
    assert!(load_value_record(&path).is_none());
}

/// 驱动没接受写下的值：按失败处理。
#[test]
fn value_backend_rejected_write_is_failure() {
    let mut fake = FakeValue {
        value: CapValue::default(),
        range: (30, 300),
        ignore_writes: true,
        writes: 0,
    };
    let result = run_value(&mut fake, &record_path("rejected"), Some(60));
    assert_eq!(result, Err(SyncError::Failed(-1)));
}

/// 子进程的报告：解得出时照用；崩溃时用退出码，正常退出却没有报告时为 -1。
#[test]
fn helper_report_falls_back_to_exit_code() {
    let report = SyncReport {
        vendor: Some(Vendor::Intel),
        result: Ok(Synced {
            steps: 0,
            applied: None,
        }),
    };
    assert_eq!(helper_report(report.encode().as_bytes(), Some(0)), report);
    let crashed = helper_report(b"", Some(-1_073_741_819));
    assert_eq!(crashed.vendor, None);
    assert_eq!(crashed.result, Err(SyncError::Failed(-1_073_741_819)));
    assert_eq!(
        helper_report(b"garbage", Some(0)).result,
        Err(SyncError::Failed(-1))
    );
    assert_eq!(helper_report(b"", None).result, Err(SyncError::Failed(-1)));
}
