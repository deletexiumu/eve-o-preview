// SPDX-License-Identifier: GPL-3.0-or-later
//
// NVIDIA 驱动限帧的控制器：把配置里的「限制 EVE 客户端帧率」同步到驱动，并给设置页一个状态。
// 规则在 eveo_core::frame_cap，读写驱动的函数由可执行文件交进来（平台层的 nvidia::apply），这里只管调度：
// - 启动时同步一次（顺带检测是不是 NVIDIA）；配置里想要的帧数变了再同步一次。
// - 每次同步在一个短命的后台线程里做（载入驱动配置库要几十到几百毫秒，不能卡住界面），结果经通道交回，
//   在主循环的定时器里取走。同一时刻只跑一个；跑着时又变了，记下最后想要的值，跑完再同步一次。
// - 还原记录（frame-cap.json）只在后台线程里读写，同步是串行的，不会两个线程同时改。
// - 想要的值没变就不再同步：配置每次变化（拖动缩略图等）都会调到这里，失败后不会反复去碰驱动；
//   用户拨一下开关或改帧数就会重试。
// - 配置变化时推迟 DEBOUNCE 再同步（sync_later）：在帧数框里打字时每个键都会改配置，打「450」会先后得到
//   4（夹成 10）、45、450。驱动每保存一次，正在运行的客户端都会重新读设置（真机上看到画面闪成灰色），
//   所以只写停下来之后的最终值。启动时的同步不用等。
// 这个模块不依赖 windows crate，用假的驱动函数在 Linux 上测试。

//! NVIDIA 驱动限帧的控制器。

use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use eveo_core::frame_cap::{self, DriverState, FrameCapStatus, OwnershipRecord, Plan};

use crate::log::Logger;

/// 配置变化后等多久再写驱动：用户停止输入后约 1 秒。
pub const DEBOUNCE: Duration = Duration::from_millis(1000);

/// 限帧的日志。
const LOG: Logger = Logger::new("FrameCap");

/// 读写驱动的函数：在一个驱动会话里读现状、按交进来的规则求出计划、执行并保存，返回计划与操作后的现状；
/// 失败时返回 NVAPI 的状态码。由可执行文件用平台层的 `nvidia::apply` 包一层交进来。
pub type DriverFn = fn(&mut dyn FnMut(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32>;

/// 一次同步的结果，从后台线程交回。
struct Outcome {
    /// 这次同步想要的帧数。
    desired: Option<u32>,
    /// 成功时是执行过的步骤数与操作后的现状，失败时是状态码。
    result: Result<(usize, DriverState), i32>,
}

/// 限帧的控制器，由应用持有，在主线程上调用。
pub struct FrameCapController {
    /// 读写驱动的函数。
    driver: DriverFn,
    /// 还原记录的位置。
    record_path: PathBuf,
    /// 设置页上显示的状态。
    status: FrameCapStatus,
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
    /// 建控制器。状态从「检测中」开始，第一次同步完成后才知道是不是 NVIDIA。
    pub fn new(driver: DriverFn, record_path: impl Into<PathBuf>) -> Self {
        Self {
            driver,
            record_path: record_path.into(),
            status: FrameCapStatus::Checking,
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
        // 已知不是 NVIDIA：不再去碰驱动（只在启动时检测一次）。
        if self.status == FrameCapStatus::NotNvidia {
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
        let driver = self.driver;
        let path = self.record_path.clone();
        let spawned = thread::Builder::new()
            .name("eveo-frame-cap".into())
            .spawn(move || {
                let result = run_sync(driver, &path, desired);
                // 主线程已经不在（应用正在退出）时发送失败，丢掉即可。
                let _ = sender.send(Outcome { desired, result });
            });
        match spawned {
            Ok(_) => self.running = Some(receiver),
            Err(error) => {
                LOG.error(format_args!("建不了限帧的后台线程：{error}"));
                self.status = FrameCapStatus::Failed(-1);
            }
        }
    }

    /// 在主循环的定时器里调用：到期的推迟同步发出去，取走跑完的同步；状态变了时返回 true（调用方刷新设置页）。
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
            // 线程没发结果就结束了（panic 时进程直接结束，不应出现）：按失败处理。
            Err(TryRecvError::Disconnected) => Outcome {
                desired: self.requested.flatten(),
                result: Err(-1),
            },
        };
        self.running = None;
        let before = self.status;
        self.status = match &outcome.result {
            Ok((steps, after)) => {
                log_success(outcome.desired, *steps, after);
                FrameCapStatus::after_success(outcome.desired, after)
            }
            Err(code) => {
                let status = FrameCapStatus::from_error(*code);
                log_failure(status, *code);
                status
            }
        };
        // 跑着时又变了：接着同步最后想要的值。不是 NVIDIA 时 sync 不会再碰驱动。
        if let Some(next) = self.queued.take() {
            self.sync(next);
        }
        self.status != before
    }
}

/// 后台线程里的一次同步：读记录、在驱动会话里按规则改、写回记录。返回执行过的步骤数与操作后的现状。
fn run_sync(driver: DriverFn, record_path: &Path, desired: Option<u32>) -> Result<(usize, DriverState), i32> {
    let record = load_record(record_path);
    let mut planner = |state: &DriverState| match desired {
        Some(fps) => frame_cap::plan_enable(state, record.as_ref(), fps),
        None => frame_cap::plan_disable(state, record.as_ref()),
    };
    let (plan, after) = driver(&mut planner)?;
    // 驱动已经改好了，记录写不下来时只记日志：下次关闭时可能还原不了，但不影响限帧本身。
    if let Err(error) = save_record(record_path, plan.record.as_ref()) {
        LOG.error(format_args!("写限帧的还原记录失败：{error}"));
    }
    Ok((plan.steps.len(), after))
}

/// 成功的日志：写了驱动时记一条 info，只是核对时不记（启动时每次都会核对）。
fn log_success(desired: Option<u32>, steps: usize, after: &DriverState) {
    if steps == 0 {
        return;
    }
    match desired {
        Some(fps) => LOG.info(format_args!(
            "已在 NVIDIA 驱动里把 exefile.exe 限为 {fps} 帧（配置文件：{}）",
            after.profile.as_deref().unwrap_or("-")
        )),
        None => LOG.info("已还原 NVIDIA 驱动里 exefile.exe 的帧数设置"),
    }
}

/// 失败的日志：不是 NVIDIA 是正常情况，只记 info；其余记 error。
fn log_failure(status: FrameCapStatus, code: i32) {
    match status {
        FrameCapStatus::NotNvidia => LOG.info(format_args!("没有 NVIDIA 驱动（NVAPI {code}），限帧不可用")),
        FrameCapStatus::NeedsAdmin => LOG.error("NVIDIA 驱动要求管理员权限，限帧没有改成功"),
        _ => LOG.error(format_args!("更改 NVIDIA 驱动的限帧失败：NVAPI {code}")),
    }
}

/// 读还原记录；文件不存在或内容不对时为 `None`。
pub fn load_record(path: &Path) -> Option<OwnershipRecord> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| OwnershipRecord::decode(&bytes))
}

/// 写还原记录（原子写入）；`None` 时删掉文件，文件本来就不在也算成功。
pub fn save_record(path: &Path, record: Option<&OwnershipRecord>) -> io::Result<()> {
    match record {
        Some(record) => crate::atomic_file::write_atomic(path, &record.encode(), "frame-cap"),
        None => match std::fs::remove_file(path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        },
    }
}

#[cfg(test)]
#[path = "frame_cap_tests.rs"]
mod tests;
