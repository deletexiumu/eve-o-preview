// SPDX-License-Identifier: GPL-3.0-or-later
//
// 客户端窗口发现（架构文档 4.1 节）：枚举顶层窗口，按进程映像名与窗口类名筛出客户端，
// 换成 Core 的 WindowInfo，再交给 Core 的 ClientWindowSelector 挑主窗口、ClientRegistry 登记。
// 标题用 InternalGetWindowText：它不给对方进程发消息，客户端卡住时也不会阻塞。

//! 顶层窗口枚举与客户端筛选。

use std::collections::HashMap;

use eveo_core::geometry::ScreenRect;
use eveo_core::model::WindowInfo;
use eveo_core::support::text::eq_ignore_case;
use windows::Win32::Foundation::{HWND, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MONITOR_DEFAULTTONULL, MONITORINFO, MonitorFromWindow};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetWindowRect, GetWindowThreadProcessId, InternalGetWindowText, IsIconic,
    IsWindowVisible,
};
use windows::core::BOOL;

use crate::process::{ProcessInfo, process_info};
use crate::text::from_wide;
use crate::window_id;

/// 一个顶层窗口的原始信息。
#[derive(Debug, Clone, PartialEq)]
pub struct TopLevelWindow {
    /// 窗口句柄的数值。
    pub hwnd: u64,
    /// 所属进程。
    pub pid: u32,
    /// 窗口类名。
    pub class_name: String,
    /// 标题；空标题为 `None`。
    pub title: Option<String>,
    /// 窗口矩形（含边框），物理像素的全局坐标。
    pub frame: ScreenRect,
    /// 是否可见（WS_VISIBLE）。
    pub is_visible: bool,
    /// 是否最小化。
    pub is_minimized: bool,
    /// 窗口是否正好盖满所在的显示器。
    pub is_full_screen: bool,
}

/// 客户端的判定条件：进程映像名与窗口类名，都不区分大小写；列表为空表示不限制。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientFilter {
    /// 进程映像名，如 `exefile.exe`。
    pub process_names: Vec<String>,
    /// 窗口类名，如 `trinityWindow`（待实测 W1）。
    pub class_names: Vec<String>,
}

impl Default for ClientFilter {
    fn default() -> Self {
        Self {
            process_names: vec!["exefile.exe".to_owned()],
            class_names: vec!["trinityWindow".to_owned()],
        }
    }
}

/// 枚举全部顶层窗口，按 Z 序从前到后。
pub fn top_level_windows() -> Vec<TopLevelWindow> {
    let mut handles: Vec<HWND> = Vec::new();
    // SAFETY: lparam 指向 handles，回调只在 EnumWindows 返回前同步调用。
    let _ = unsafe { EnumWindows(Some(collect), LPARAM((&raw mut handles) as isize)) };
    handles.into_iter().map(describe).collect()
}

/// EnumWindows 的回调：把句柄放进 lparam 指向的数组。
unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
    // SAFETY: lparam 是 top_level_windows 传来的 &mut Vec<HWND>，EnumWindows 返回前一直有效。
    let handles = unsafe { &mut *(lparam.0 as *mut Vec<HWND>) };
    handles.push(hwnd);
    true.into()
}

/// 读一个窗口的信息。
fn describe(hwnd: HWND) -> TopLevelWindow {
    let mut pid = 0u32;
    // SAFETY: pid 是有效的输出位置。
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    let mut class = [0u16; 256];
    // SAFETY: 缓冲区在调用期间有效，长度由切片给出。
    let class_len = unsafe { GetClassNameW(hwnd, &mut class) };
    let mut title = [0u16; 512];
    // SAFETY: 同上；InternalGetWindowText 不向对方进程发消息。
    let title_len = unsafe { InternalGetWindowText(hwnd, &mut title) };
    let mut rect = RECT::default();
    // SAFETY: rect 是有效的输出位置；失败时保持全 0。
    let _ = unsafe { GetWindowRect(hwnd, &mut rect) };
    let frame = to_rect(rect);
    let title = (title_len > 0).then(|| from_wide(&title, title_len as usize));
    TopLevelWindow {
        hwnd: window_id(hwnd).0,
        pid,
        class_name: from_wide(&class, class_len.max(0) as usize),
        title,
        frame,
        // SAFETY: 只读窗口状态。
        is_visible: unsafe { IsWindowVisible(hwnd) }.as_bool(),
        // SAFETY: 只读窗口状态。
        is_minimized: unsafe { IsIconic(hwnd) }.as_bool(),
        is_full_screen: covers_monitor(hwnd, rect),
    }
}

/// 窗口矩形是否与所在显示器的范围相同。
fn covers_monitor(hwnd: HWND, rect: RECT) -> bool {
    // SAFETY: 只读；窗口不在任何显示器上时返回空句柄。
    let monitor = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL) };
    if monitor.is_invalid() {
        return false;
    }
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    // SAFETY: info 的 cbSize 已填好。
    unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool() && info.rcMonitor == rect
}

/// RECT → Core 的矩形。
pub(crate) fn to_rect(rect: RECT) -> ScreenRect {
    ScreenRect::new(
        f64::from(rect.left),
        f64::from(rect.top),
        f64::from(rect.right - rect.left),
        f64::from(rect.bottom - rect.top),
    )
}

/// 一个候选客户端窗口：Core 的窗口信息，加上判定时用到的进程与类名。
#[derive(Debug, Clone, PartialEq)]
pub struct CandidateWindow {
    /// 交给 Core 的窗口信息。
    pub window: WindowInfo,
    /// 窗口类名。
    pub class_name: String,
    /// 所属进程的信息。
    pub process: ProcessInfo,
}

/// 筛出客户端的候选窗口：可见、进程名与类名符合条件。主窗口的挑选交给 Core。
pub fn candidate_windows(filter: &ClientFilter) -> Vec<CandidateWindow> {
    let mut processes: HashMap<u32, Option<ProcessInfo>> = HashMap::new();
    let mut result = Vec::new();
    for window in top_level_windows() {
        if !window.is_visible || !matches(&filter.class_names, &window.class_name) {
            continue;
        }
        let process = processes
            .entry(window.pid)
            .or_insert_with(|| process_info(window.pid));
        let Some(process) = process.clone() else {
            continue;
        };
        if !matches(&filter.process_names, &process.image_name) {
            continue;
        }
        result.push(CandidateWindow {
            window: WindowInfo {
                window_id: eveo_core::model::WindowId(window.hwnd),
                pid: window.pid,
                title: window.title,
                frame: window.frame,
                is_on_screen: !window.is_minimized,
                is_minimized: Some(window.is_minimized),
                is_full_screen: Some(window.is_full_screen),
            },
            class_name: window.class_name,
            process,
        });
    }
    result
}

/// 名称是否在列表里（不区分大小写）；列表为空时都算符合。
fn matches(allowed: &[String], name: &str) -> bool {
    allowed.is_empty() || allowed.iter().any(|a| eq_ignore_case(a, name))
}
