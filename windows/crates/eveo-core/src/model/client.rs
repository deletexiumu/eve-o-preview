// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口与客户端模型，对应 macOS 的 Model/ClientModels.swift（架构文档 5.1 节）。
// 运行时用窗口 ID 标识客户端，持久化用角色名；登录界面的客户端标题都是 `EVE`，不能按标题区分。
// 与 macOS 的差异：窗口 ID 在 Windows 上是 HWND 的数值，PID 是无符号的 32 位整数。

use crate::clients::title;
use crate::geometry::ScreenRect;

/// 进程 ID。Windows 的 PID 是 `DWORD`，macOS 的是 `pid_t`；两端的取值都放得进 `u32`。
pub type Pid = u32;

/// 窗口 ID。Windows 上是 HWND 的数值，macOS 上是 `CGWindowID`。
///
/// 同一窗口在存活期间 ID 不变；窗口销毁后 ID 可能被系统复用给别的窗口。
/// 实现了 `Ord`，供「并列时取 ID 最小的窗口」一类规则使用。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WindowId(pub u64);

/// 平台层上报的一个候选窗口（某个 EVE 进程的一个顶层窗口）。
#[derive(Debug, Clone, PartialEq)]
pub struct WindowInfo {
    /// 窗口 ID。
    pub window_id: WindowId,
    /// 所属进程的 PID。
    pub pid: Pid,
    /// 窗口标题；`None` 表示读不到，空串由平台层记为 `None`。
    pub title: Option<String>,
    /// 窗口在全局屏幕坐标中的范围。
    pub frame: ScreenRect,
    /// 窗口当前是否在屏幕上（被隐藏、在别的虚拟桌面或已最小化时为假）。
    pub is_on_screen: bool,
    /// 是否已最小化；`None` 表示状态未知。
    pub is_minimized: Option<bool>,
    /// 是否是全屏窗口；`None` 表示不知道。
    pub is_full_screen: Option<bool>,
}

/// 客户端的身份，由窗口标题解析而来（见 [`crate::clients::title`]）。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ClientIdentity {
    /// 已选角色的客户端，关联值是角色名（区分大小写，用作持久化的键）。
    Character(String),
    /// 停在登录界面、标题是 `EVE` 的客户端。
    Login,
    /// 标题读不到或无法识别的客户端，按登录客户端的方式摆放。
    Unknown,
}

impl ClientIdentity {
    /// 角色名；登录与未知客户端返回 `None`。
    pub fn character_name(&self) -> Option<&str> {
        match self {
            ClientIdentity::Character(name) => Some(name),
            ClientIdentity::Login | ClientIdentity::Unknown => None,
        }
    }
}

/// 一个已发现的 EVE 客户端：一个进程及其主窗口。
#[derive(Debug, Clone, PartialEq)]
pub struct EveClient {
    /// 主窗口的窗口 ID，运行时的唯一标识。
    pub id: WindowId,
    /// 进程 PID。
    pub pid: Pid,
    /// 由标题解析出的身份。
    pub identity: ClientIdentity,
    /// 主窗口的范围，全局屏幕坐标。
    pub window_frame: ScreenRect,
    /// 主窗口是否在屏幕上。
    pub is_on_screen: bool,
    /// 是否已最小化；`None` 表示状态未知。
    pub is_minimized: Option<bool>,
    /// 主窗口是否是全屏；`None` 表示不知道。
    pub is_full_screen: Option<bool>,
}

impl EveClient {
    /// 由主窗口建客户端，身份经 [`title::identity`] 解析。
    pub fn from_window(window: &WindowInfo) -> Self {
        Self {
            id: window.window_id,
            pid: window.pid,
            identity: title::identity(window.title.as_deref()),
            window_frame: window.frame,
            is_on_screen: window.is_on_screen,
            is_minimized: window.is_minimized,
            is_full_screen: window.is_full_screen,
        }
    }

    /// 角色名；登录与未知客户端返回 `None`。
    pub fn character_name(&self) -> Option<&str> {
        self.identity.character_name()
    }

    /// 缩略图上显示的标题，见 [`title::display_title`]。
    pub fn display_title(&self) -> String {
        title::display_title(&self.identity, self.pid)
    }
}

/// 同一窗口 ID 在两次轮询之间的变化。
#[derive(Debug, Clone, PartialEq)]
pub struct ClientChange {
    /// 变化前的客户端。
    pub before: EveClient,
    /// 变化后的客户端。
    pub after: EveClient,
}

/// [`crate::clients::ClientRegistry::update`] 的结果：按窗口 ID 比较得出的差异。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct RegistryDiff {
    /// 新出现的客户端，按输入顺序。
    pub added: Vec<EveClient>,
    /// 消失的客户端，按原登记顺序。
    pub removed: Vec<EveClient>,
    /// 身份变了的客户端（例如登录后标题从 `EVE` 变成 `EVE - <角色名>`）。
    pub renamed: Vec<ClientChange>,
    /// 身份没变，只有位置、尺寸、在屏或最小化状态变了的客户端。
    pub updated: Vec<ClientChange>,
}

impl RegistryDiff {
    /// 4 类差异都为空时为真。
    pub fn is_empty(&self) -> bool {
        self.added.is_empty() && self.removed.is_empty() && self.renamed.is_empty() && self.updated.is_empty()
    }
}
