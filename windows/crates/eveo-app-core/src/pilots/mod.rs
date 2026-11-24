// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对服务，对应 macOS 的 IntelFeedController+PilotLookup.swift（设计文档 6.10 节）：缓存、排队与发送。
// 规则（缓存期限、节流、退避）都在 eveo-core::intel::pilots，这里只把它们与线程、文件、时钟接起来：
// - 何时排（由预警控制器调用）：功能与「联网核对人名」都开着、且缓存文件已读完时才排。
//   - 新消息：enqueue_report，取 segmenter::candidates 里缓存没有结果的名字。
//   - 补排：enqueue_backfill，从活动角色最新的消息往前收集，满 500 个为止。时机：缓存文件读完、
//     切换角色、开关从关变成开、星图数据到达后重新解析（tick 与 set_enabled 的返回值会提示）。
// - 发送：一个长期的后台线程按顺序执行请求（同一时刻至多一个在途）。tick 在应用的定时器里调用：
//   收结果、存进缓存，能取下一批时交给后台线程。开关关掉时清空队列并把代号加 1，迟到的结果丢掉；缓存留着。
// - 缓存文件：第一次启用时在后台读一次；有改动且距上次存盘满 30 秒时交给写入线程存一次；
//   shutdown 时等写入线程写完，再同步存最后一次，旧快照不会盖掉新的。
// 发请求的函数（Resolver）由可执行文件交进来（WinHTTP 实现），这样这里不依赖 windows crate，
// 在 Linux 上用假的 Resolver 测试。名字是消息正文的一部分，这里不写日志。

//! 人名核对服务：缓存文件、排队与后台发送。

pub mod store;

#[cfg(test)]
mod tests;

use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread::{self, JoinHandle};

use eveo_core::intel::IntelReport;
use eveo_core::intel::pilots::cache::PilotNameCache;
use eveo_core::intel::pilots::queue::PilotLookupQueue;
use eveo_core::intel::pilots::segmenter::{PilotDirectory, candidates};
use eveo_core::intel::pilots::{
    PilotLookupAnswer, PilotLookupFailure, PilotLookupStatus, PilotNameCacheEntry, key,
};

pub use store::PilotNameStore;

/// 一次补排至多收集几个名字（一个请求的上限）。
pub const BACKFILL_LOOKUP_LIMIT: usize = 500;
/// 两次存盘至少隔几秒：核对结果一批批到达，每批都写文件没有必要。
pub const CACHE_SAVE_INTERVAL: f64 = 30.0;

/// 发一次核对请求：names 是去重后的 1～500 个名字。在后台线程里调用，可以阻塞（WinHTTP 的同步调用）。
pub type Resolver = Box<dyn FnMut(&[String]) -> Result<PilotLookupAnswer, PilotLookupFailure> + Send>;

/// 后台线程交回的一次结果：代号与结果。
type Outcome = (u64, Result<PilotLookupAnswer, PilotLookupFailure>);

/// 缓存文件的读取进度。
enum LoadState {
    /// 还没开始读。
    NotLoaded,
    /// 后台线程在读；关联值是结果的接收端与开始读时的清空次数。
    Loading(Receiver<Vec<PilotNameCacheEntry>>, u64),
    /// 已读完（或读失败后从空缓存开始）。
    Loaded,
}

/// 发请求的后台线程。
struct Worker {
    /// 交给线程的一批：代号与名字。
    requests: Sender<(u64, Vec<String>)>,
    /// 线程交回的结果。
    outcomes: Receiver<Outcome>,
}

/// 写缓存文件的后台线程：各次写入排成一串，后一次等前一次写完。
struct Writer {
    /// 要写的快照。
    snapshots: Sender<Vec<PilotNameCacheEntry>>,
    /// 线程句柄，shutdown 时等它写完。
    handle: JoinHandle<()>,
}

/// tick 的结果，告诉控制器要做什么。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PilotTick {
    /// 核对结果或状态变了：浮窗与「预警」页要刷新。
    pub changed: bool,
    /// 缓存文件刚读完：控制器应调用一次 enqueue_backfill。
    pub wants_backfill: bool,
}

/// 人名核对服务。只在应用的主线程上使用。
pub struct PilotLookupService {
    /// 缓存文件。
    store: PilotNameStore,
    /// 结果缓存。
    cache: PilotNameCache,
    /// 排队与节流。
    queue: PilotLookupQueue,
    /// 缓存文件的读取进度。
    load: LoadState,
    /// 功能与「联网核对人名」都开着。
    enabled: bool,
    /// 代号：开关关掉时加 1，之前发出的请求的结果被丢掉。
    generation: u64,
    /// 还没交给后台线程的发请求函数；第一次发请求时连同线程一起建。
    resolver: Option<Resolver>,
    /// 发请求的后台线程。
    worker: Option<Worker>,
    /// 写文件的后台线程。
    writer: Option<Writer>,
    /// 上一次存盘的时刻（墙上时钟）。
    last_save: f64,
    /// 清空缓存的次数：读文件的过程中用户清空过时，读到的旧条目不再用。
    clear_count: u64,
    /// 开关关着时借出的空目录。
    empty: PilotDirectory,
}

impl PilotLookupService {
    /// 用缓存文件与发请求的函数建服务。这时不读文件、不建线程，第一次启用时才读。
    pub fn new(store: PilotNameStore, resolver: Resolver) -> Self {
        Self {
            store,
            cache: PilotNameCache::default(),
            queue: PilotLookupQueue::default(),
            load: LoadState::NotLoaded,
            enabled: false,
            generation: 0,
            resolver: Some(resolver),
            worker: None,
            writer: None,
            last_save: f64::NEG_INFINITY,
            clear_count: 0,
            empty: PilotDirectory::default(),
        }
    }

    /// 改开关（预警的 enabled 与 resolve_pilot_names 都为真时为开）。返回是否应补排一次：
    /// 缓存已读完、开关刚从关变成开时为真。第一次打开时开始在后台读缓存文件，读完后由 tick 提示补排。
    pub fn set_enabled(&mut self, enabled: bool, now: f64) -> bool {
        let was_enabled = self.enabled;
        self.enabled = enabled;
        if !enabled {
            if was_enabled {
                // 关掉：清空待查与在途，迟到的结果丢掉；有改动就存一次（不等 30 秒）。
                self.queue.remove_all();
                self.generation += 1;
                self.save_if_due(now, true);
            }
            return false;
        }
        // 打开：缓存文件读完后才排（否则可能把缓存里已有的名字再查一遍）。
        match self.load {
            LoadState::NotLoaded => {
                self.start_loading();
                false
            }
            LoadState::Loading(..) => false,
            LoadState::Loaded => !was_enabled,
        }
    }

    /// 新消息：排进它的候选名字里缓存没有结果（或已过期）的。不是情报的消息不排。
    pub fn enqueue_report(&mut self, report: &IntelReport, now: f64) {
        if !self.can_enqueue() || !report.is_intel_like() {
            return;
        }
        // 一个词的人名段没有候选名字，不会发出去：单个词就是一个人，不必查。
        let names: Vec<String> = candidates(report)
            .into_iter()
            .filter(|name| self.cache.needs_lookup(name, now))
            .collect();
        if !names.is_empty() {
            self.queue.enqueue(&names, now);
        }
    }

    /// 补排：reports 是活动角色在缓冲里的消息，从最新到最旧；收集要查的名字，满 500 个为止。
    pub fn enqueue_backfill<'a>(&mut self, reports: impl IntoIterator<Item = &'a IntelReport>, now: f64) {
        if !self.can_enqueue() {
            return;
        }
        // 同一个名字在几条消息里出现时只排一次；队列本身也会去重，这里先去重是为了让 500 的上限按不同的名字算。
        let mut seen = std::collections::HashSet::new();
        let mut names = Vec::new();
        'collect: for report in reports.into_iter().filter(|r| r.is_intel_like()) {
            for name in candidates(report) {
                if !self.cache.needs_lookup(&name, now) || !seen.insert(key(&name)) {
                    continue;
                }
                names.push(name);
                if names.len() >= BACKFILL_LOOKUP_LIMIT {
                    break 'collect;
                }
            }
        }
        if !names.is_empty() {
            self.queue.enqueue(&names, now);
        }
    }

    /// 在应用的定时器里调用：收缓存文件与核对结果，能取下一批时交给后台线程。
    pub fn tick(&mut self, now: f64) -> PilotTick {
        // 1. 缓存文件刚读完：要刷新（已保存的角色名可以显示了），也要补排一次。
        let wants_backfill = self.poll_loading(now);
        let mut result = PilotTick {
            changed: wants_backfill,
            wants_backfill,
        };
        // 2. 收后台线程交回的结果。
        result.changed |= self.drain_outcomes(now);
        // 3. 能取下一批时交给后台线程；防抖、间隔与等待都由队列判断。
        if self.enabled
            && matches!(self.load, LoadState::Loaded)
            && let Some(batch) = self.queue.take_batch(now)
        {
            self.send(batch, now);
            // 状态从空闲或等待变成在途。
            result.changed = true;
        }
        result
    }

    /// 下一次 tick 有事可做的时刻（墙上时钟）；没有待查的名字或有一批在途时为 None。
    /// 应用的定时器本来就在跑，这只用来在空闲时放慢定时器。
    pub fn next_attempt(&self) -> Option<f64> {
        if self.enabled {
            self.queue.next_attempt()
        } else {
            None
        }
    }

    /// 给显示用的核对结果；开关关着时是空目录，显示回到解析器的推断。
    pub fn directory(&self) -> &PilotDirectory {
        if self.enabled {
            self.cache.directory()
        } else {
            &self.empty
        }
    }

    /// 核对的状态，给「预警」页与问题报告；开关关着时是 Off。
    pub fn status(&self) -> PilotLookupStatus {
        if self.enabled {
            self.queue.status()
        } else {
            PilotLookupStatus::Off
        }
    }

    /// 已保存的角色名个数。缓存文件还没读完时是 0（「预警」页据 is_cache_loaded 决定显不显示）。
    pub fn matched_count(&self) -> usize {
        self.cache.matched_count()
    }

    /// 缓存文件是否已读完。
    pub fn is_cache_loaded(&self) -> bool {
        matches!(self.load, LoadState::Loaded)
    }

    /// 清空内存与文件里的人名缓存。文件还没读完时，读完的结果不再用。
    pub fn clear(&mut self, now: f64) {
        // 记一次清空：如果文件还在后台读，读到的旧条目到时会被丢掉。
        self.clear_count += 1;
        self.cache.remove_all();
        self.last_save = now;
        let entries = self.cache.snapshot(now);
        self.write_async(entries);
    }

    /// 退出前调用：丢掉在途的结果，等写入线程写完，缓存有改动时同步存最后一次。
    pub fn shutdown(&mut self, now: f64) -> std::io::Result<()> {
        // 丢掉发请求的线程：它可能正卡在一个 10 秒的请求里，不等它；结果反正不要了。
        self.generation += 1;
        self.worker = None;
        // 关掉写入线程的发送端，线程写完排着的快照后自己结束；等它结束，免得它稍后用旧快照盖掉下面的最后一次。
        if let Some(writer) = self.writer.take() {
            drop(writer.snapshots);
            let _ = writer.handle.join();
        }
        if !self.cache.is_dirty() {
            return Ok(());
        }
        let entries = self.cache.snapshot(now);
        self.store.save(&entries)
    }

    /// 能不能排：开关开着且缓存文件已读完（没读完时排的名字可能缓存里已有）。
    fn can_enqueue(&self) -> bool {
        self.enabled && matches!(self.load, LoadState::Loaded)
    }

    /// 在后台线程读缓存文件。读文件很快，但放在后台免得启动时卡一下界面。
    fn start_loading(&mut self) {
        let (sender, receiver) = mpsc::channel();
        let store = self.store.clone();
        let spawned = thread::Builder::new()
            .name("eveo-pilot-cache-load".into())
            .spawn(move || {
                let _ = sender.send(store.load());
            });
        self.load = match spawned {
            Ok(_) => LoadState::Loading(receiver, self.clear_count),
            // 建不了线程（极少见）时直接在这里读。
            Err(_) => {
                self.cache = PilotNameCache::new(&self.store.load(), 0.0);
                LoadState::Loaded
            }
        };
    }

    /// 收读文件的结果；刚读完时返回 true（要补排）。
    fn poll_loading(&mut self, now: f64) -> bool {
        let LoadState::Loading(receiver, clear_count) = &self.load else {
            return false;
        };
        let entries = match receiver.try_recv() {
            Ok(entries) => entries,
            Err(TryRecvError::Empty) => return false,
            // 读文件的线程意外退出：从空缓存开始。
            Err(TryRecvError::Disconnected) => Vec::new(),
        };
        // 读的过程中用户清空过缓存时，文件里的旧条目不再用。
        let usable: &[PilotNameCacheEntry] = if *clear_count == self.clear_count {
            &entries
        } else {
            &[]
        };
        self.cache = PilotNameCache::new(usable, now);
        self.load = LoadState::Loaded;
        true
    }

    /// 收后台线程交回的结果，存进缓存；有结果时返回 true。代号不对的（开关关过）丢掉。
    fn drain_outcomes(&mut self, now: f64) -> bool {
        // 还没发过请求时没有线程，也就没有结果。
        let Some(worker) = &self.worker else {
            return false;
        };
        // 先全部收下再处理：处理时要改 self，不能同时借着 worker。
        let outcomes: Vec<Outcome> = worker.outcomes.try_iter().collect();
        let mut changed = false;
        for (generation, outcome) in outcomes {
            if generation != self.generation {
                continue;
            }
            changed = true;
            match outcome {
                // 成功：队列离开在途（错误额度低时进入等待），结果进缓存，满 30 秒存一次盘。
                Ok(answer) => {
                    self.queue.complete(&answer, now);
                    self.cache.store(&answer.outcomes, now);
                    self.save_if_due(now, false);
                }
                // 失败：按种类决定这一批回不回到待查、等多久；缓存不变。
                Err(failure) => self.queue.fail(&failure, now),
            }
        }
        changed
    }

    /// 把一批交给后台线程；线程还没建时先建。建不了线程时按网络失败处理（30 秒后重试）。
    fn send(&mut self, batch: Vec<String>, now: f64) {
        // 第一次发请求时才建线程：大多数用户不开预警，不必为它常驻一个线程。
        if self.worker.is_none() {
            self.worker = self.resolver.take().and_then(spawn_worker);
        }
        let sent = self
            .worker
            .as_ref()
            .is_some_and(|worker| worker.requests.send((self.generation, batch)).is_ok());
        if !sent {
            // 线程不在了（发请求的函数 panic 等）：这一批记为失败、放回待查。发请求的函数已随线程丢失，
            // 之后每一批都会这样失败，但有退避（最长 10 分钟一次），不会反复刷屏。
            self.worker = None;
            let failure = PilotLookupFailure::Network("lookup worker unavailable".into());
            self.queue.fail(&failure, now);
        }
    }

    /// 缓存有改动、且距上次存盘满 30 秒（或 force）时，交给写入线程存一次。
    fn save_if_due(&mut self, now: f64, force: bool) {
        if !self.cache.is_dirty() || !(force || now - self.last_save >= CACHE_SAVE_INTERVAL) {
            return;
        }
        self.last_save = now;
        let entries = self.cache.snapshot(now);
        self.write_async(entries);
    }

    /// 交给写入线程写文件；线程还没建时先建，建不了时在这里同步写。
    fn write_async(&mut self, entries: Vec<PilotNameCacheEntry>) {
        // 写入线程同样按需建；之后一直留着，直到 shutdown。
        if self.writer.is_none() {
            self.writer = spawn_writer(self.store.clone());
        }
        // 发送失败（线程已退出）时取回快照，在这里同步写，不丢这次改动。
        let entries = match &self.writer {
            Some(writer) => match writer.snapshots.send(entries) {
                Ok(()) => return,
                Err(mpsc::SendError(entries)) => entries,
            },
            None => entries,
        };
        let _ = self.store.save(&entries);
    }
}

/// 建发请求的后台线程。线程在请求的发送端被丢掉后结束；不 join：一个请求可能要等 10 秒超时，
/// 退出时不必等它（结果反正会被丢掉）。
fn spawn_worker(mut resolver: Resolver) -> Option<Worker> {
    let (request_sender, request_receiver) = mpsc::channel::<(u64, Vec<String>)>();
    let (outcome_sender, outcome_receiver) = mpsc::channel::<Outcome>();
    thread::Builder::new()
        .name("eveo-pilot-lookup".into())
        .spawn(move || {
            for (generation, names) in request_receiver {
                let outcome = resolver(&names);
                if outcome_sender.send((generation, outcome)).is_err() {
                    break;
                }
            }
        })
        .ok()?;
    Some(Worker {
        requests: request_sender,
        outcomes: outcome_receiver,
    })
}

/// 建写文件的后台线程：按顺序写每个快照；排着好几个时只写最新的一个（旧的没有意义）。
fn spawn_writer(store: PilotNameStore) -> Option<Writer> {
    let (sender, receiver) = mpsc::channel::<Vec<PilotNameCacheEntry>>();
    let handle = thread::Builder::new()
        .name("eveo-pilot-cache-save".into())
        .spawn(move || {
            while let Ok(mut entries) = receiver.recv() {
                // 跳过已经过时的快照，只写排在最后的。
                while let Ok(newer) = receiver.try_recv() {
                    entries = newer;
                }
                let _ = store.save(&entries);
            }
        })
        .ok()?;
    Some(Writer {
        snapshots: sender,
        handle,
    })
}
