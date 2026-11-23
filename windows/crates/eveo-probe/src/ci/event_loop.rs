// SPDX-License-Identifier: GPL-3.0-or-later
//
// W7（架构文档 3.4 节、第 9 节）：应用的主循环是 Slint 的事件循环（底层是 winit 的 Win32 消息循环），
// 原生的热键窗口、DWM 缩略图窗口、WinEvent 钩子与低级鼠标钩子的通知都要在这个循环里照常工作。
// 这里开一个 Slint 窗口，在事件循环里用定时器分几步：注册键盘热键、装鼠标钩子、建缩略图、
// 用 SendInput 触发热键与 Ctrl+中键、激活一个假客户端，等处理函数收到触发后退出循环，再核对：
// 热键与鼠标热键的消息经窗口过程送到处理函数、前台事件进了队列、缩略图在循环里注册成功。
// 顺带记录 Slint 窗口能否取到句柄并设上 Mica 背景（R5，只作参考：服务器版系统可能没有 Mica）。

//! `eveo-probe ci` 的事件循环共存检查。

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use eveo_core::geometry::ScreenRect;
use eveo_core::hotkeys::backend::hotkey_id;
use eveo_core::hotkeys::{Hotkey, HotkeyModifiers, HotkeyScope, MouseBinding, MouseHotkeyMatcher};
use eveo_core::model::{EveClient, WindowId};
use eveo_platform_win::activation;
use eveo_platform_win::events::{WindowEvent, WindowEventHooks};
use eveo_platform_win::hotkey::{HotkeyMessage, HotkeyWindow};
use eveo_platform_win::mouse_hook::MouseHook;
use eveo_platform_win::thumbnail::ThumbnailWindow;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde_json::json;
use slint::ComponentHandle;
use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Dwm::{DWMSBT_MAINWINDOW, DWMWA_SYSTEMBACKDROP_TYPE, DwmSetWindowAttribute};
use windows::Win32::UI::Input::KeyboardAndMouse::{MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP};

use super::{Report, key_input, mouse_input, send_with_modifiers};

slint::slint! {
    #[edition = "1.19"]
    export component ProbeWindow inherits Window {
        title: "EVE-O Preview 探针";
        width: 360px;
        height: 120px;
        Text {
            text: "事件循环共存检查 · 日本語 · 한국어";
            font-size: 16px;
        }
    }
}

/// 事件循环里收集到的结果。
#[derive(Default)]
struct Outcome {
    keyboard: Option<i32>,
    mouse: Option<u32>,
    thumbnail: Option<String>,
    activation: Option<bool>,
    mica: Option<Result<(), String>>,
    timed_out: bool,
}

/// 在 Slint 的事件循环里跑一遍原生窗口、热键与钩子，核对它们共存正常。
pub(super) fn check(clients: &[EveClient], hooks: &WindowEventHooks, report: &mut Report) {
    let Some(target) = clients.get(1).map(|c| c.id) else {
        return;
    };
    let window = match ProbeWindow::new() {
        Ok(window) => window,
        Err(error) => {
            report.check("建 Slint 窗口", false, true, json!({"error": error.to_string()}));
            return;
        }
    };
    if let Err(error) = window.show() {
        report.check(
            "显示 Slint 窗口",
            false,
            true,
            json!({"error": error.to_string()}),
        );
        return;
    }
    hooks.drain();

    let outcome = Rc::new(RefCell::new(Outcome::default()));
    // 原生对象要活过事件循环，放在循环外，由定时器第一步填进来。
    let natives: Rc<RefCell<Vec<Box<dyn std::any::Any>>>> = Rc::new(RefCell::new(Vec::new()));
    let started = Instant::now();
    let step = Rc::new(RefCell::new(0_u32));
    let timer = slint::Timer::default();
    {
        let outcome = Rc::clone(&outcome);
        let natives = Rc::clone(&natives);
        let weak = window.as_weak();
        timer.start(
            slint::TimerMode::Repeated,
            Duration::from_millis(100),
            move || {
                let mut current = step.borrow_mut();
                match *current {
                    0 => {
                        // winit 在事件循环开始后才真正建窗口，句柄要在循环里取。
                        outcome.borrow_mut().mica = weak.upgrade().map(|w| mica(&w));
                        start_natives(target, &outcome, &mut natives.borrow_mut());
                        *current = 1;
                    }
                    1 => {
                        trigger(target, &outcome);
                        *current = 2;
                    }
                    _ => {
                        let done = {
                            let o = outcome.borrow();
                            o.keyboard.is_some() && o.mouse.is_some()
                        };
                        if done || started.elapsed() > Duration::from_secs(6) {
                            outcome.borrow_mut().timed_out = !done;
                            let _ = slint::quit_event_loop();
                        }
                    }
                }
            },
        );
    }
    let run = slint::run_event_loop();
    timer.stop();
    let _ = window.hide();
    natives.borrow_mut().clear();
    let events = hooks.drain();

    let outcome = outcome.borrow();
    let expected_id = hotkey_id::encode(2, 1).unwrap_or(0);
    report.check(
        "Slint 事件循环里键盘热键经窗口过程送到处理函数",
        run.is_ok() && outcome.keyboard == Some(expected_id),
        true,
        json!({"received": outcome.keyboard, "expected": expected_id, "timedOut": outcome.timed_out,
               "run": run.err().map(|e| e.to_string())}),
    );
    report.check(
        "Slint 事件循环里鼠标热键经窗口过程送到处理函数",
        outcome.mouse == Some(9),
        true,
        json!({"received": outcome.mouse}),
    );
    report.check(
        "Slint 事件循环里 DWM 缩略图注册成功",
        outcome.thumbnail.is_none(),
        true,
        json!({"error": outcome.thumbnail}),
    );
    let foreground = events.contains(&WindowEvent::Foreground(target));
    report.check(
        "Slint 事件循环里收到 WinEvent 前台事件",
        outcome.activation == Some(true) && foreground,
        true,
        json!({"activated": outcome.activation, "foregroundEvent": foreground, "eventCount": events.len()}),
    );
    let mica = outcome.mica.clone().unwrap_or_else(|| Err("窗口已释放".into()));
    report.check(
        "Slint 窗口设 Mica 背景",
        mica.is_ok(),
        false,
        json!({"result": mica.err()}),
    );
}

/// 第一步：在事件循环里建热键窗口（带处理函数）、注册热键、装鼠标钩子、建缩略图。
fn start_natives(
    target: WindowId,
    outcome: &Rc<RefCell<Outcome>>,
    natives: &mut Vec<Box<dyn std::any::Any>>,
) {
    let Ok(mut window) = HotkeyWindow::create() else {
        return;
    };
    let sink = Rc::clone(outcome);
    window.set_handler(move |message| {
        let mut o = sink.borrow_mut();
        match message {
            HotkeyMessage::Keyboard(id) => o.keyboard = Some(id),
            HotkeyMessage::Mouse(id) => o.mouse = Some(id),
        }
    });
    if let (Some(hotkey), Some(id)) = (Hotkey::parse("ctrl+shift+F14"), hotkey_id::encode(2, 1))
        && let Some(key) = hotkey.key_code()
    {
        let _ = window.register(id, hotkey.modifiers, key);
    }
    let mut matcher = MouseHotkeyMatcher::new();
    matcher.replace_bindings(vec![MouseBinding {
        id: 9,
        button: 2,
        modifiers: HotkeyModifiers::CONTROL,
        scope: HotkeyScope::Global,
    }]);
    if let Ok(hook) = MouseHook::start(Arc::new(Mutex::new(matcher)), window.hwnd()) {
        natives.push(Box::new(hook));
    }
    natives.push(Box::new(window));
    let frame = ScreenRect::new(40.0, 500.0, 192.0, 108.0);
    match ThumbnailWindow::create(frame, true).and_then(|mut t| {
        t.register(target)?;
        t.set_appearance(2, true, 255)?;
        Ok(t)
    }) {
        Ok(thumbnail) => natives.push(Box::new(thumbnail)),
        Err(error) => outcome.borrow_mut().thumbnail = Some(error.message()),
    }
}

/// 第二步：激活目标客户端，再用 SendInput 触发键盘热键与 Ctrl+中键。
fn trigger(target: WindowId, outcome: &Rc<RefCell<Outcome>>) {
    let activated = activation::activate(target).succeeded();
    outcome.borrow_mut().activation = Some(activated);
    const VK_CONTROL: u16 = 0x11;
    const VK_SHIFT: u16 = 0x10;
    const VK_F14: u16 = 0x7D;
    send_with_modifiers(
        &[VK_CONTROL, VK_SHIFT],
        [key_input(VK_F14, false), key_input(VK_F14, true)],
    );
    send_with_modifiers(
        &[VK_CONTROL],
        [
            mouse_input(MOUSEEVENTF_MIDDLEDOWN, 0),
            mouse_input(MOUSEEVENTF_MIDDLEUP, 0),
        ],
    );
}

/// 取 Slint 窗口的句柄，设 Mica 背景。返回系统的错误信息。
fn mica(window: &ProbeWindow) -> Result<(), String> {
    let slint_window = window.window();
    let handle = slint_window.window_handle();
    let raw = handle
        .window_handle()
        .map_err(|e| format!("取不到窗口句柄：{e}"))?;
    let RawWindowHandle::Win32(win32) = raw.as_raw() else {
        return Err("不是 Win32 窗口".into());
    };
    let hwnd = HWND(win32.hwnd.get() as *mut core::ffi::c_void);
    let value = DWMSBT_MAINWINDOW;
    // SAFETY: 句柄来自 Slint 的活动窗口；value 在调用期间有效，大小如实给出。
    unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            (&raw const value).cast(),
            size_of_val(&value) as u32,
        )
    }
    .map_err(|e| e.message())
}
