// SPDX-License-Identifier: GPL-3.0-or-later
//
// 显示器信息（架构文档 4.6 节）：每块显示器的范围、工作区（去掉任务栏）与缩放系数（DPI ÷ 96），
// 坐标是物理像素的全局坐标，原点在主显示器左上角。进程要声明 PerMonitorV2，否则这里拿到的是缩放后的值。

//! 显示器枚举。

use eveo_core::geometry::ScreenInfo;
use windows::Win32::Foundation::{LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForMonitor, MDT_EFFECTIVE_DPI,
    SetProcessDpiAwarenessContext,
};
use windows::Win32::UI::WindowsAndMessaging::MONITORINFOF_PRIMARY;
use windows::core::BOOL;

use crate::discovery::to_rect;

/// 全部显示器，按系统枚举的顺序。
pub fn screens() -> Vec<ScreenInfo> {
    let mut monitors: Vec<HMONITOR> = Vec::new();
    // SAFETY: lparam 指向 monitors，回调只在 EnumDisplayMonitors 返回前同步调用。
    let _ = unsafe { EnumDisplayMonitors(None, None, Some(collect), LPARAM((&raw mut monitors) as isize)) };
    monitors.into_iter().filter_map(describe).collect()
}

/// EnumDisplayMonitors 的回调。
unsafe extern "system" fn collect(monitor: HMONITOR, _dc: HDC, _rect: *mut RECT, lparam: LPARAM) -> BOOL {
    // SAFETY: lparam 是 screens 传来的 &mut Vec<HMONITOR>，枚举结束前一直有效。
    let monitors = unsafe { &mut *(lparam.0 as *mut Vec<HMONITOR>) };
    monitors.push(monitor);
    true.into()
}

/// 读一块显示器的信息。
fn describe(monitor: HMONITOR) -> Option<ScreenInfo> {
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    // SAFETY: info 的 cbSize 已填好。
    if !unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool() {
        return None;
    }
    let (mut dpi_x, mut dpi_y) = (96u32, 96u32);
    // SAFETY: 两个输出位置有效；失败时保持 96。
    let _ = unsafe { GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) };
    let scale = f64::from(dpi_x) / 96.0;
    Some(ScreenInfo {
        frame: to_rect(info.rcMonitor),
        visible_frame: to_rect(info.rcWork),
        scale,
        // 全局坐标是物理像素，配置里的尺寸按这块屏幕的缩放换算（与 macOS 的点一致）。
        size_scale: scale,
        is_main: info.dwFlags & MONITORINFOF_PRIMARY != 0,
    })
}

/// 把本进程设为 PerMonitorV2。正式的应用在清单里声明，探针与测试程序在启动时调用一次；
/// 已经设过（或清单里声明过）时系统返回失败，这里忽略。
pub fn enable_per_monitor_dpi() {
    // SAFETY: 只改本进程的 DPI 感知方式。
    let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
}
