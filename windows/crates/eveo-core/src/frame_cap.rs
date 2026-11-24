// SPDX-License-Identifier: GPL-3.0-or-later
//
// 用 NVIDIA 驱动给 EVE 客户端限帧的规则。Windows 独有，macOS 版没有这一项。
//
// 背景：多开时 EVE 会把不在前台的客户端降到每秒几帧，切过去时从几帧一下子跳到不限帧，画面会顿一下。
// 把所有客户端都限在 60 帧左右能把这个跳变压小，也省显卡。精确限帧要注入客户端，有违反用户协议的风险，
// 所以不注入，改为写显卡驱动的「按程序设置」：NVIDIA 驱动配置库（DRS）里 exefile.exe 所在的驱动配置文件
// 的「最大帧速率」（设置项 FRL_FPS，0 表示不限）。这和用户在 NVIDIA 控制面板「程序设置」里手动设置是一回事，
// 对所有 exefile.exe 生效，包括前台的客户端。AMD 与 Intel 没有可以调用的同类接口，界面上置灰。
//
// 这里只有纯规则：打开与关闭时驱动里要做哪几步、要记下什么才能还原。读写驱动在平台层（eveo-platform-win 的
// nvidia 模块），执行与记录的读写在应用层。
//
// 还原的约定：
// - 第一次打开时记下「接手前」的样子（ownership record）：exefile.exe 在哪个驱动配置文件里、那里原来有没有
//   用户自己设的帧数、配置文件是不是我们新建的。记录存在本应用的数据目录，不在驱动里。
// - 驱动里没有登记 exefile.exe 时新建一个名为 OWN_PROFILE_NAME 的配置文件并把 exefile.exe 加进去；关闭时整个删掉。
// - 关闭时只在驱动里的值仍是我们写的值时才还原：用户之后在 NVIDIA 控制面板里自己改过，就尊重用户的改动，只丢掉记录。
// - 记录在、驱动里 exefile.exe 却换了配置文件（驱动更新后归入了新的预置配置文件）时，按新配置文件重新接手。

//! NVIDIA 驱动限帧（exefile.exe 的「最大帧速率」）的规则。

use serde::{Deserialize, Serialize};

/// EVE 客户端的映像名。驱动按文件名匹配程序，与路径无关，多个安装目录都能覆盖到。
pub const EXE_NAME: &str = "exefile.exe";
/// 驱动里没有登记 exefile.exe 时新建的配置文件名。名字里带本应用的名字，用户在 NVIDIA 控制面板里认得出来。
pub const OWN_PROFILE_NAME: &str = "EVE-O Preview - EVE Online";
/// 帧数的范围。下限 10：再低客户端几乎没法操作；上限 1000：驱动接受的最大值是 1023，取整到 1000。
pub const FPS_RANGE: (i64, i64) = (10, 1000);
/// 默认帧数：60，对应常见显示器的刷新率，也是用户提的默认值。
pub const DEFAULT_FPS: i64 = 60;

config_struct! {
    /// 「限制 EVE 客户端帧率」的设置，放在配置的 general.frameCap。Windows 独有：键缺失时为 `None`，
    /// 等同于关闭、帧数取默认值；这样不写这个键的配置文件（包括 macOS 的）与以前完全一样。
    pub struct FrameCapSettings via FrameCapSettingsRaw {
        /// 是否打开，默认关闭：改驱动设置是本机范围的改动，要用户自己打开。
        req enabled: bool = false, "enabled";
        /// 帧数上限，默认 60，范围见 [`FPS_RANGE`]，越界时由配置校验夹到边界。
        req fps: i64 = DEFAULT_FPS, "fps";
    }
}

impl FrameCapSettings {
    /// 要写进驱动的帧数：打开时是夹到范围内的帧数，关闭时为 `None`。
    pub fn desired_fps(&self) -> Option<u32> {
        self.enabled.then(|| clamp_fps(self.fps))
    }
}

/// 把帧数夹到 [`FPS_RANGE`] 内并转成驱动用的无符号数。
pub fn clamp_fps(fps: i64) -> u32 {
    // 夹过之后一定在 10..=1000 内，转换不会失败；万一失败（不应出现）取默认值。
    u32::try_from(fps.clamp(FPS_RANGE.0, FPS_RANGE.1)).unwrap_or(DEFAULT_FPS as u32)
}

/// 驱动里 exefile.exe 的现状，由平台层读出。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DriverState {
    /// exefile.exe 所在的驱动配置文件名；`None` 表示驱动里没有登记 exefile.exe。
    pub profile: Option<String>,
    /// 那个配置文件上用户设的帧数（值来自这个配置文件本身，而不是预置值或全局设置）；没有设时为 `None`。
    pub user_fps: Option<u32>,
}

/// 接手前的样子与我们写下的值，存在本应用的数据目录，关闭时据此还原。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnershipRecord {
    /// 写入的驱动配置文件名。
    pub profile: String,
    /// 配置文件是不是我们新建的；是的话关闭时整个删掉。
    pub created_profile: bool,
    /// 接手前那个配置文件上用户设的帧数；没有设时为 `None`，关闭时删掉我们的值。
    pub original_fps: Option<u32>,
    /// 我们最后写下的帧数，用来判断用户之后有没有在 NVIDIA 控制面板里自己改过。
    pub applied_fps: u32,
}

impl OwnershipRecord {
    /// 从记录文件的内容解出记录；内容不对时当作没有记录（只会少还原一次，不影响使用）。
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        serde_json::from_slice(bytes).ok()
    }

    /// 编码成记录文件的内容：缩进两格，末尾换行。
    pub fn encode(&self) -> Vec<u8> {
        // 结构里只有字符串、布尔与数字，序列化不会失败；万一失败就写空对象（下次读出来当作没有记录）。
        let mut bytes = serde_json::to_vec_pretty(self).unwrap_or_else(|_| b"{}".to_vec());
        bytes.push(b'\n');
        bytes
    }
}

/// 在驱动里要做的一步。平台层在同一个驱动会话里按顺序执行，全部成功后一次保存。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// 新建 [`OWN_PROFILE_NAME`] 配置文件并把 exefile.exe 加进去。
    CreateOwnProfile,
    /// 在 exefile.exe 所在的配置文件上设帧数。
    SetFps(u32),
    /// 删掉 exefile.exe 所在配置文件上的帧数设置（回到预置值或全局设置）。
    DeleteFps,
    /// 删掉我们新建的 [`OWN_PROFILE_NAME`] 配置文件。
    DeleteOwnProfile,
}

/// 一次操作的计划：驱动里的几步，以及全部成功后的记录（`None` 表示删掉记录文件）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// 按顺序执行的步骤；为空时不用打开驱动会话写入。
    pub steps: Vec<Step>,
    /// 成功后的记录。
    pub record: Option<OwnershipRecord>,
}

/// 打开（或改了帧数、启动时核对）：让驱动里 exefile.exe 的帧数等于 `fps`。
///
/// 驱动里的值已经是 `fps` 时不写驱动，只更新记录。已有记录且配置文件没变时沿用记录里接手前的样子，
/// 免得把我们自己写的值当成「原来的值」。
pub fn plan_enable(state: &DriverState, record: Option<&OwnershipRecord>, fps: u32) -> Plan {
    let Some(profile) = &state.profile else {
        // 驱动里没有登记 exefile.exe：新建自己的配置文件。即使有旧记录（例如用户手动删了配置文件），
        // 新建的配置文件里原来也没有值，按新建处理。
        return Plan {
            steps: vec![Step::CreateOwnProfile, Step::SetFps(fps)],
            record: Some(OwnershipRecord {
                profile: OWN_PROFILE_NAME.to_owned(),
                created_profile: true,
                original_fps: None,
                applied_fps: fps,
            }),
        };
    };
    // 同一个配置文件上的旧记录：保留接手前的样子；否则以驱动的现状作为接手前的样子。
    let base = match record {
        Some(r) if &r.profile == profile => r.clone(),
        _ => OwnershipRecord {
            profile: profile.clone(),
            // exefile.exe 已经在这个配置文件里，但名字是我们的：上次的记录丢了，仍按新建处理，关闭时删掉。
            created_profile: profile == OWN_PROFILE_NAME,
            original_fps: state.user_fps,
            applied_fps: fps,
        },
    };
    let steps = if state.user_fps == Some(fps) {
        Vec::new()
    } else {
        vec![Step::SetFps(fps)]
    };
    Plan {
        steps,
        record: Some(OwnershipRecord {
            applied_fps: fps,
            ..base
        }),
    }
}

/// 关闭：按记录还原。没有记录时什么都不做（从没打开过，或已经还原过）。
pub fn plan_disable(state: &DriverState, record: Option<&OwnershipRecord>) -> Plan {
    let nothing = Plan {
        steps: Vec::new(),
        record: None,
    };
    let Some(record) = record else {
        return nothing;
    };
    // exefile.exe 已经不在记录的配置文件里（用户删了配置文件或驱动更新改了归属），
    // 或者用户之后在 NVIDIA 控制面板里自己改了帧数：都不动驱动，只丢掉记录。
    if state.profile.as_deref() != Some(record.profile.as_str()) || state.user_fps != Some(record.applied_fps)
    {
        return nothing;
    }
    let step = if record.created_profile {
        Step::DeleteOwnProfile
    } else {
        match record.original_fps {
            Some(fps) => Step::SetFps(fps),
            None => Step::DeleteFps,
        }
    };
    Plan {
        steps: vec![step],
        record: None,
    }
}

/// 设置页上这一项的状态，由应用层按检测与写入的结果求出。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameCapStatus {
    /// 正在检测显卡驱动（启动后的第一秒左右）。
    Checking,
    /// 没有 NVIDIA 驱动（AMD、Intel 显卡，或驱动没装好）：开关置灰。
    NotNvidia,
    /// 驱动可用，当前没有限帧（或刚还原）。
    Ready,
    /// 驱动里已经设好了帧数。
    Applied(u32),
    /// 驱动要求管理员权限才能写入。
    NeedsAdmin,
    /// 其他错误，带 NVAPI 的状态码。
    Failed(i32),
}

impl FrameCapStatus {
    /// 开关能不能拨：检测中与不是 NVIDIA 时不能。
    pub fn is_available(self) -> bool {
        !matches!(self, Self::Checking | Self::NotNvidia)
    }
}

#[cfg(test)]
#[path = "frame_cap_tests.rs"]
mod tests;
