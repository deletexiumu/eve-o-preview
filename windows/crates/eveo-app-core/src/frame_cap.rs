// SPDX-License-Identifier: GPL-3.0-or-later
//
// 驱动限帧的控制器：把配置里的「限制 EVE 客户端帧率」同步到显卡驱动，并给设置页一个状态与显卡厂商。
// 规则在 eveo_core::frame_cap，同步函数由可执行文件交进来（先试 NVIDIA，再在子进程里试 AMD 与 Intel），
// 这里只管调度：
// - 启动时同步一次（顺带检测是哪家显卡）；配置里想要的帧数变了再同步一次。
// - 每次同步在一个短命的后台线程里做（载入驱动库要几十到几百毫秒，AMD、Intel 还要起子进程，不能卡住界面），
//   结果经通道交回，在主循环的定时器里取走。同一时刻只跑一个；跑着时又变了，记下最后想要的值，跑完再同步一次。
// - 还原记录只在后台线程（或子进程）里读写，同步是串行的，不会两处同时改。
// - 想要的值没变就不再同步：配置每次变化（拖动缩略图等）都会调到这里，失败后不会反复去碰驱动；
//   用户拨一下开关或改帧数就会重试。
// - 配置变化时推迟 DEBOUNCE 再同步（sync_later）：在帧数框里打字时每个键都会改配置，打「450」会先后得到
//   4（夹成 10）、45、450。驱动每保存一次，正在运行的客户端都会重新读设置（真机上看到画面闪成灰色），
//   所以只写停下来之后的最终值。启动时的同步不用等。
// 另外放着两种显卡的「一次同步」（读记录、按规则改驱动、写记录）与子进程报告的解读，都不依赖 windows crate，
// 用假的驱动在 Linux 上测试。

//! 驱动限帧的控制器与一次同步的做法。

use std::io;
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use eveo_core::frame_cap::value::{self, CapValue, ValueBackend, ValueRecord};
use eveo_core::frame_cap::{
    self, DriverState, FrameCapStatus, OwnershipRecord, Plan, SyncError, SyncReport, Synced, Vendor,
};

use crate::log::Logger;

/// 配置变化后等多久再写驱动：用户停止输入后约 1 秒。
pub const DEBOUNCE: Duration = Duration::from_millis(1000);

/// 限帧的日志。
const LOG: Logger = Logger::new("FrameCap");

/// 一次同步：参数是想要的帧数（关闭时为 `None`），返回用的是哪家显卡与结果。在后台线程里调用。
pub type SyncFn = Arc<dyn Fn(Option<u32>) -> SyncReport + Send + Sync>;

/// 读写 NVIDIA 驱动的函数：在一个驱动会话里读现状、按交进来的规则求出计划、执行并保存，返回计划与操作后的现状；
/// 失败时返回 NVAPI 的状态码。由可执行文件用平台层的 `nvidia::apply` 包一层交进来。
pub type DriverFn = fn(&mut dyn FnMut(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32>;

/// 一次同步的结果，从后台线程交回。
struct Outcome {
    /// 这次同步想要的帧数。
    desired: Option<u32>,
    /// 报告。
    report: SyncReport,
}

/// 限帧的控制器，由应用持有，在主线程上调用。
pub struct FrameCapController {
    /// 一次同步。
    sync_fn: SyncFn,
    /// 设置页上显示的状态。
    status: FrameCapStatus,
    /// 最近一次同步用的是哪家显卡；还没检测完或没有能用的显卡时为 `None`。
    vendor: Option<Vendor>,
    /// 正在跑的同步。
    running: Option<Receiver<Outcome>>,
    /// 最近一次发起同步时想要的值；`None` 表示还没同步过。
    requested: Option<Option<u32>>,
    /// 跑着时又变了的、最后想要的值。
    queued: Option<Option<u32>>,
    /// 推迟同步的值与到期时刻（见 sync_later）。
    deferred: Option<(Option<u32>, Instant)>,
}

impl FrameCapController {
    /// 建控制器。状态从「检测中」开始，第一次同步完成后才知道是哪家显卡。
    pub fn new(sync_fn: impl Fn(Option<u32>) -> SyncReport + Send + Sync + 'static) -> Self {
        Self {
            sync_fn: Arc::new(sync_fn),
            status: FrameCapStatus::Checking,
            vendor: None,
            running: None,
            requested: None,
            queued: None,
            deferred: None,
        }
    }

    /// 设置页上显示的状态。
    pub fn status(&self) -> FrameCapStatus {
        self.status
    }

    /// 最近一次同步用的是哪家显卡。
    pub fn vendor(&self) -> Option<Vendor> {
        self.vendor
    }

    /// 让驱动跟上配置：`desired` 是想要的帧数（关闭时为 `None`）。与上一次想要的值相同时什么都不做；
    /// 正在同步时记下来，等这次跑完再同步。
    pub fn sync(&mut self, desired: Option<u32>) {
        if self.running.is_some() {
            // 跑着的那次正好是这个值时不用再排队。
            self.queued = (self.requested != Some(desired)).then_some(desired);
            return;
        }
        if self.requested == Some(desired) {
            return;
        }
        // 已知没有能用的显卡驱动：不再去碰驱动（只在启动时检测一次）。
        if self.status == FrameCapStatus::Unsupported {
            self.requested = Some(desired);
            return;
        }
        self.start(desired);
    }

    /// 推迟到 `now + DEBOUNCE` 再同步：期间又调用时以最后一次的值与时刻为准。值与上一次想要的相同时取消推迟。
    pub fn sync_later(&mut self, desired: Option<u32>, now: Instant) {
        if self.deferred.is_none() && self.running.is_none() && self.requested == Some(desired) {
            return;
        }
        self.deferred = Some((desired, now + DEBOUNCE));
    }

    /// 在后台线程里同步一次。线程建不起来（系统资源耗尽）时按失败处理。
    fn start(&mut self, desired: Option<u32>) {
        self.requested = Some(desired);
        let (sender, receiver) = mpsc::channel();
        let sync_fn = Arc::clone(&self.sync_fn);
        let spawned = thread::Builder::new()
            .name("eveo-frame-cap".into())
            .spawn(move || {
                let report = sync_fn(desired);
                // 主线程已经不在（应用正在退出）时发送失败，丢掉即可。
                let _ = sender.send(Outcome { desired, report });
            });
        match spawned {
            Ok(_) => self.running = Some(receiver),
            Err(error) => {
                LOG.error(format_args!("建不了限帧的后台线程：{error}"));
                self.status = FrameCapStatus::Failed(-1);
            }
        }
    }

    /// 在主循环的定时器里调用：到期的推迟同步发出去，取走跑完的同步；状态或厂商变了时返回 true（调用方刷新设置页）。
    pub fn tick(&mut self, now: Instant) -> bool {
        if let Some((desired, due)) = self.deferred
            && now >= due
        {
            self.deferred = None;
            self.sync(desired);
        }
        let Some(receiver) = &self.running else {
            return false;
        };
        let outcome = match receiver.try_recv() {
            Ok(outcome) => outcome,
            Err(TryRecvError::Empty) => return false,
            // 线程没发结果就结束了（panic 时进程直接结束，不应出现）：按失败处理，厂商沿用上一次的。
            Err(TryRecvError::Disconnected) => Outcome {
                desired: self.requested.flatten(),
                report: SyncReport {
                    vendor: self.vendor,
                    result: Err(SyncError::Failed(-1)),
                },
            },
        };
        self.running = None;
        let before = (self.status, self.vendor);
        log_outcome(&outcome);
        self.status = FrameCapStatus::from_result(&outcome.report.result);
        self.vendor = outcome.report.vendor;
        // 跑着时又变了：接着同步最后想要的值。没有能用的显卡驱动时 sync 不会再碰驱动。
        if let Some(next) = self.queued.take() {
            self.sync(next);
        }
        (self.status, self.vendor) != before
    }
}

/// 厂商的名字，用在日志里。
fn vendor_name(vendor: Option<Vendor>) -> &'static str {
    match vendor {
        Some(Vendor::Nvidia) => "NVIDIA",
        Some(Vendor::Amd) => "AMD",
        Some(Vendor::Intel) => "Intel",
        None => "显卡",
    }
}

/// 一次同步的日志：写了驱动时记一条 info，只是核对时不记（启动时每次都会核对）；没有能用的显卡只记 info，其余失败记 error。
fn log_outcome(outcome: &Outcome) {
    let name = vendor_name(outcome.report.vendor);
    match outcome.report.result {
        Ok(Synced { steps: 0, .. }) => {}
        Ok(Synced {
            applied: Some(fps), ..
        }) => LOG.info(format_args!("已在 {name} 驱动里把 EVE 客户端限为 {fps} 帧")),
        Ok(_) => LOG.info(format_args!("已还原 {name} 驱动里的帧数设置")),
        Err(SyncError::Unsupported) => LOG.info("没有能用的显卡驱动（NVIDIA、AMD、Intel），限帧不可用"),
        Err(SyncError::NeedsAdmin) => LOG.error(format_args!("{name} 驱动要求管理员权限，限帧没有改成功")),
        Err(SyncError::Failed(code)) => LOG.error(format_args!(
            "更改 {name} 驱动的限帧失败：错误码 {code}（想要 {:?}）",
            outcome.desired
        )),
    }
}

/// NVIDIA 的一次同步：读记录、在驱动会话里按规则改、写回记录。
pub fn run_nvidia(driver: DriverFn, record_path: &Path, desired: Option<u32>) -> Result<Synced, SyncError> {
    let record = load_record(record_path);
    let mut planner = |state: &DriverState| match desired {
        Some(fps) => frame_cap::plan_enable(state, record.as_ref(), fps),
        None => frame_cap::plan_disable(state, record.as_ref()),
    };
    let (plan, after) = driver(&mut planner).map_err(frame_cap::nvapi_error)?;
    // 驱动已经改好了，记录写不下来时只记日志：下次关闭时可能还原不了，但不影响限帧本身。
    if let Err(error) = save_record(record_path, plan.record.as_ref()) {
        LOG.error(format_args!("写限帧的还原记录失败：{error}"));
    }
    frame_cap::nvidia_synced(desired, plan.steps.len(), &after)
}

/// AMD 或 Intel 的一次同步：读记录与驱动现状、按规则写驱动、读回核对、写回记录。帧数先夹到驱动的范围内，
/// 设置页上显示的是实际写下的值。
pub fn run_value(
    backend: &mut dyn ValueBackend,
    record_path: &Path,
    desired: Option<u32>,
) -> Result<Synced, SyncError> {
    let record = load_value_record(record_path);
    let target = backend.target().to_owned();
    let current = backend.read()?;
    let wanted = desired.map(|fps| value::clamp_to_range(fps, backend.range()));
    let plan = match wanted {
        Some(fps) => value::plan_value_enable(&target, current, record.as_ref(), fps),
        None => value::plan_value_disable(&target, current, record.as_ref()),
    };
    let after = match plan.write {
        Some(write) => {
            backend.write(write)?;
            backend.read()?
        }
        None => current,
    };
    if let Err(error) = save_value_record(record_path, plan.record.as_ref()) {
        LOG.error(format_args!("写限帧的还原记录失败：{error}"));
    }
    let steps = usize::from(plan.write.is_some());
    match wanted {
        // 读回的不是写下的值（驱动没接受）：按失败处理，免得设置页显示「已设好」。
        Some(fps) if after != CapValue::on(fps) => Err(SyncError::Failed(-1)),
        Some(fps) => Ok(Synced {
            steps,
            applied: Some(fps),
        }),
        None => Ok(Synced { steps, applied: None }),
    }
}

/// 解读子进程的输出：能解出报告就用报告；解不出（子进程崩溃或被结束）时按失败处理，
/// 错误码取退出码（没有退出码时为 -1），厂商未知。
pub fn helper_report(stdout: &[u8], exit_code: Option<i32>) -> SyncReport {
    SyncReport::decode(&String::from_utf8_lossy(stdout)).unwrap_or(SyncReport {
        vendor: None,
        result: Err(SyncError::Failed(
            exit_code.filter(|&code| code != 0).unwrap_or(-1),
        )),
    })
}

/// 读 NVIDIA 的还原记录；文件不存在或内容不对时为 `None`。
pub fn load_record(path: &Path) -> Option<OwnershipRecord> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| OwnershipRecord::decode(&bytes))
}

/// 写 NVIDIA 的还原记录（原子写入）；`None` 时删掉文件，文件本来就不在也算成功。
pub fn save_record(path: &Path, record: Option<&OwnershipRecord>) -> io::Result<()> {
    save_bytes(path, record.map(OwnershipRecord::encode))
}

/// 读 AMD、Intel 的还原记录；文件不存在或内容不对时为 `None`。
pub fn load_value_record(path: &Path) -> Option<ValueRecord> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| ValueRecord::decode(&bytes))
}

/// 写 AMD、Intel 的还原记录，规则同 [`save_record`]。
pub fn save_value_record(path: &Path, record: Option<&ValueRecord>) -> io::Result<()> {
    save_bytes(path, record.map(ValueRecord::encode))
}

/// 原子写入记录文件；`None` 时删掉文件，文件本来就不在也算成功。
fn save_bytes(path: &Path, bytes: Option<Vec<u8>>) -> io::Result<()> {
    match bytes {
        Some(bytes) => crate::atomic_file::write_atomic(path, &bytes, "frame-cap"),
        None => match std::fs::remove_file(path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        },
    }
}

#[cfg(test)]
#[path = "frame_cap_tests.rs"]
mod tests;
