// SPDX-License-Identifier: GPL-3.0-or-later
//
// 假客户端的窗口与消息循环。客户区颜色记在窗口的用户数据里，WM_PAINT 时整块填充。

//! 假客户端的实现。

use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, HBRUSH, PAINTSTRUCT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext};
use windows::Win32::UI::WindowsAndMessaging::{
    AdjustWindowRectEx, CS_HREDRAW, CS_VREDRAW, CreateWindowExW, DefWindowProcW, DispatchMessageW,
    GWLP_USERDATA, GetMessageW, GetWindowLongPtrW, IDC_ARROW, LoadCursorW, MSG, PostQuitMessage,
    RegisterClassExW, SW_SHOW, SetWindowLongPtrW, ShowWindow, TranslateMessage, WINDOW_EX_STYLE, WM_DESTROY,
    WM_PAINT, WNDCLASSEXW, WS_OVERLAPPEDWINDOW,
};
use windows::core::PCWSTR;

/// 解析好的参数。
struct Options {
    title: String,
    class: String,
    color: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

/// 解析参数；未知参数或格式不对时报错。
fn parse(args: Vec<String>) -> Result<Options, String> {
    let mut options = Options {
        title: "EVE".into(),
        class: "trinityWindow".into(),
        color: 0x80_8080,
        x: 100,
        y: 100,
        width: 1280,
        height: 720,
    };
    let mut iter = args.into_iter();
    while let Some(flag) = iter.next() {
        let value = iter.next().ok_or_else(|| format!("{flag} 缺少值"))?;
        let number = |v: &str| v.parse::<i32>().map_err(|_| format!("{flag} 不是整数：{v}"));
        match flag.as_str() {
            "--title" => options.title = value,
            "--class" => options.class = value,
            "--color" => {
                options.color = u32::from_str_radix(value.trim_start_matches('#'), 16)
                    .map_err(|_| format!("--color 不是 RRGGBB：{value}"))?;
            }
            "--x" => options.x = number(&value)?,
            "--y" => options.y = number(&value)?,
            "--width" => options.width = number(&value)?,
            "--height" => options.height = number(&value)?,
            _ => return Err(format!("不认识的参数 {flag}")),
        }
    }
    Ok(options)
}

/// 以 0 结尾的 UTF-16。
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 建窗口并运行消息循环，直到窗口关闭。
pub fn run(args: Vec<String>) -> Result<(), String> {
    let options = parse(args)?;
    // SAFETY: 只改本进程的 DPI 感知方式，让窗口大小按物理像素计。
    let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    let class_name = wide(&options.class);
    let title = wide(&options.title);
    // SAFETY: 取本 exe 的模块句柄。
    let instance = unsafe { GetModuleHandleW(None) }.map_err(|e| e.message())?;
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(window_proc),
        hInstance: instance.into(),
        // SAFETY: 加载系统预置的箭头光标。
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW) }.map_err(|e| e.message())?,
        lpszClassName: PCWSTR(class_name.as_ptr()),
        ..Default::default()
    };
    // SAFETY: class 里的指针指向本函数内的缓冲区，调用期间有效。
    if unsafe { RegisterClassExW(&class) } == 0 {
        return Err("RegisterClassExW 失败".into());
    }
    // 参数给的是客户区大小，换算成含边框的窗口大小。
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: options.width,
        bottom: options.height,
    };
    // SAFETY: rect 是有效的输入输出位置。
    unsafe { AdjustWindowRectEx(&mut rect, WS_OVERLAPPEDWINDOW, false, WINDOW_EX_STYLE(0)) }
        .map_err(|e| e.message())?;
    // SAFETY: 缓冲区在调用期间有效。
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            PCWSTR(class_name.as_ptr()),
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW,
            options.x,
            options.y,
            rect.right - rect.left,
            rect.bottom - rect.top,
            None,
            None,
            Some(instance.into()),
            None,
        )
    }
    .map_err(|e| e.message())?;
    // 颜色存成 COLORREF（0x00BBGGRR）。
    let (r, g, b) = (
        (options.color >> 16) & 0xFF,
        (options.color >> 8) & 0xFF,
        options.color & 0xFF,
    );
    // SAFETY: 窗口属于本线程；用户数据只存一个整数。
    unsafe {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (b << 16 | g << 8 | r) as isize);
        let _ = ShowWindow(hwnd, SW_SHOW);
    }
    let mut msg = MSG::default();
    // SAFETY: 标准的消息循环；GetMessageW 在 WM_QUIT 时返回 0，出错时返回 -1。
    unsafe {
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    Ok(())
}

/// 窗口过程：WM_PAINT 时把客户区涂成参数给的颜色，窗口销毁时退出。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_PAINT => {
            let mut paint = PAINTSTRUCT::default();
            // SAFETY: 在 WM_PAINT 里成对调用 BeginPaint 与 EndPaint；画刷用完即删。
            unsafe {
                let dc = BeginPaint(hwnd, &mut paint);
                let color = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as u32;
                let brush: HBRUSH = CreateSolidBrush(COLORREF(color));
                FillRect(dc, &paint.rcPaint, brush);
                let _ = DeleteObject(brush.into());
                let _ = EndPaint(hwnd, &paint);
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            // SAFETY: 结束本线程的消息循环。
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        // SAFETY: 参数原样转交。
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}
