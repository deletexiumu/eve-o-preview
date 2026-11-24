// SPDX-License-Identifier: GPL-3.0-or-later
//
// AMD 与 Intel 驱动限帧的规则，以及三家显卡共用的同步结果。NVIDIA 的规则（驱动配置文件）在上一级模块。
//
// 两家驱动都只有「一个值」可改，没有 NVIDIA 那样的配置文件：
// - AMD（ADLX 的帧率目标控制，即 AMD Software 里的 Frame Rate Target Control）：是整块显卡的全局设置，
//   没有按程序的接口，打开后所有游戏都会被限帧。界面上用红字讲明。
// - Intel（IGCL 的 3D 特性 FRAME_LIMIT）：可以只给 exefile.exe 设，与 NVIDIA 一样只影响 EVE。
// 所以规则统一成：读出「开没开、多少帧」（CapValue），打开时记下接手前的值，关闭时只在驱动里仍是我们写的值时还原。
// 记录里带「写到了哪块显卡」（target），换了显卡（或显卡的编号变了）时不去动另一块显卡的设置。
//
// 选哪家：机器上可能同时有几家显卡（常见的是 Intel 核显加 NVIDIA 或 AMD 独显）。NVIDIA 先试（已经实测过），
// 没有 NVIDIA 时在 AMD 与 Intel 之间优先独显，其次核显：游戏一般跑在独显上，限核显没有用。

//! AMD、Intel 驱动限帧的规则，与三家共用的同步结果。

use serde::{Deserialize, Serialize};

/// 显卡厂商，决定设置页上的说明文字与还原记录放在哪个文件。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Vendor {
    /// NVIDIA：驱动配置文件里 exefile.exe 的「最大帧速率」。
    Nvidia,
    /// AMD：整块显卡的「帧率目标控制」，对所有游戏生效。
    Amd,
    /// Intel：exefile.exe 的帧数上限。
    Intel,
}

/// 显卡是核显还是独显，选厂商时独显优先。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpuKind {
    /// 集成在处理器里的显卡。
    Integrated,
    /// 独立显卡（含外接显卡）。
    Discrete,
}

/// 没有 NVIDIA 时在 AMD 与 Intel 之间选一家：独显优先，同为独显或同为核显时 AMD 优先（AMD 核显的
/// 机器通常没有 Intel 显卡，这条只是让结果确定）。参数是各家能用的那块显卡的种类，不能用时为 `None`。
pub fn choose_vendor(amd: Option<GpuKind>, intel: Option<GpuKind>) -> Option<Vendor> {
    match (amd, intel) {
        (Some(GpuKind::Discrete), _) => Some(Vendor::Amd),
        (_, Some(GpuKind::Discrete)) => Some(Vendor::Intel),
        (Some(_), _) => Some(Vendor::Amd),
        (None, Some(_)) => Some(Vendor::Intel),
        (None, None) => None,
    }
}

/// 驱动里的限帧设置：开没开、多少帧。关着时帧数也照样记下来，还原时一起写回。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct CapValue {
    /// 限帧是否打开。
    pub enabled: bool,
    /// 帧数上限。
    pub fps: u32,
}

impl CapValue {
    /// 打开并限为 `fps` 帧。
    pub fn on(fps: u32) -> Self {
        Self { enabled: true, fps }
    }
}

/// AMD、Intel 的还原记录，存在本应用的数据目录（每家一个文件）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValueRecord {
    /// 写到了哪块显卡（平台层给出的标识，例如 AMD 的显卡编号、Intel 的适配器名）。
    pub target: String,
    /// 接手前驱动里的值，关闭时写回。
    pub original: CapValue,
    /// 我们最后写下的帧数，用来判断用户之后有没有在显卡软件里自己改过。
    pub applied_fps: u32,
}

impl ValueRecord {
    /// 从记录文件的内容解出记录；内容不对时当作没有记录。
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        serde_json::from_slice(bytes).ok()
    }

    /// 编码成记录文件的内容：缩进两格，末尾换行。
    pub fn encode(&self) -> Vec<u8> {
        // 只有字符串、布尔与数字，序列化不会失败；万一失败就写空对象（下次读出来当作没有记录）。
        let mut bytes = serde_json::to_vec_pretty(self).unwrap_or_else(|_| b"{}".to_vec());
        bytes.push(b'\n');
        bytes
    }
}

/// 一次操作的计划：要写进驱动的值（`None` 表示不写），以及成功后的记录（`None` 表示删掉记录文件）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValuePlan {
    /// 要写的值。
    pub write: Option<CapValue>,
    /// 成功后的记录。
    pub record: Option<ValueRecord>,
}

/// 打开（或改了帧数、启动时核对）：让 `target` 显卡上的限帧等于 `fps`。
///
/// 已有同一块显卡的记录时沿用记录里接手前的值，免得把我们自己写的值当成「原来的值」；驱动里已经是想要的值时不写。
pub fn plan_value_enable(
    target: &str,
    current: CapValue,
    record: Option<&ValueRecord>,
    fps: u32,
) -> ValuePlan {
    let original = match record {
        Some(r) if r.target == target => r.original,
        _ => current,
    };
    let wanted = CapValue::on(fps);
    ValuePlan {
        write: (current != wanted).then_some(wanted),
        record: Some(ValueRecord {
            target: target.to_owned(),
            original,
            applied_fps: fps,
        }),
    }
}

/// 关闭：按记录还原。没有记录、记录的是另一块显卡、或用户之后在显卡软件里自己改过时，都不动驱动，只丢掉记录。
pub fn plan_value_disable(target: &str, current: CapValue, record: Option<&ValueRecord>) -> ValuePlan {
    let write = record
        .filter(|r| r.target == target && current == CapValue::on(r.applied_fps))
        .map(|r| r.original);
    ValuePlan { write, record: None }
}

/// 把帧数夹到驱动给出的范围内（驱动的范围比配置的 10～1000 窄，例如 AMD 一般是 30～300）。
/// 范围不合理（下限大于上限，驱动返回了怪值）时不夹。
pub fn clamp_to_range(fps: u32, range: (u32, u32)) -> u32 {
    if range.0 <= range.1 {
        fps.clamp(range.0, range.1)
    } else {
        fps
    }
}

/// AMD 或 Intel 驱动里已经打开的一个会话，由平台层实现，应用层按上面的规则读写。
pub trait ValueBackend {
    /// 这块显卡的标识，写进还原记录。
    fn target(&self) -> &str;
    /// 驱动接受的帧数范围（含两端）。
    fn range(&self) -> (u32, u32);
    /// 读驱动里现在的值。
    fn read(&mut self) -> Result<CapValue, SyncError>;
    /// 把值写进驱动。
    fn write(&mut self, value: CapValue) -> Result<(), SyncError>;
}

/// 一次同步失败的原因，三家共用。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncError {
    /// 没有能用的显卡驱动（没有这家的驱动库、没有这家的显卡、驱动太旧或不支持限帧）。
    Unsupported,
    /// 驱动要求管理员权限才能写入。
    NeedsAdmin,
    /// 其他错误，带驱动的错误码（NVAPI、ADLX 或 IGCL 的状态码；子进程异常结束时是它的退出码）。
    Failed(i32),
}

/// 一次同步成功的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Synced {
    /// 写了驱动几步；为 0 时只是核对（启动时每次都会核对），不记日志。
    pub steps: usize,
    /// 驱动里现在的帧数上限；不限帧（或刚还原）时为 `None`。可能因为驱动的范围与想要的不同。
    pub applied: Option<u32>,
}

/// 一次同步的报告：用的是哪家显卡（没有能用的显卡、或子进程没报出来时为 `None`）与结果。
/// AMD、Intel 在子进程里同步，报告编成一行 JSON 交回。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncReport {
    /// 显卡厂商。
    pub vendor: Option<Vendor>,
    /// 结果。
    pub result: Result<Synced, SyncError>,
}

impl SyncReport {
    /// 编码成一行 JSON（不带换行）。
    pub fn encode(&self) -> String {
        // 只有枚举、数字与可空值，序列化不会失败；万一失败交回空串，读的一方按失败处理。
        serde_json::to_string(self).unwrap_or_default()
    }

    /// 从子进程的输出里解出报告：取最后一个非空行；解不出时为 `None`。
    pub fn decode(text: &str) -> Option<Self> {
        let line = text.lines().rev().find(|line| !line.trim().is_empty())?;
        serde_json::from_str(line.trim()).ok()
    }
}

#[cfg(test)]
#[path = "frame_cap_value_tests.rs"]
mod tests;
