// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键录制器的真机检查：录制器的低级钩子必须在专用线程上，调用线程（应用里是主线程）忙的时候也不丢键。
// 真机上主线程忙着刷新设置页、缩略图时，装在主线程上的钩子回调来不及返回，组合键（Ctrl+Shift+J 等）
// 整批消失，录制一直停在「按下组合键…」。这里复现那种情形：开始录制后用 SendInput 送一个组合键，
// 然后本线程睡一秒、完全不取消息（比系统的低级钩子时限长），再取结果。钩子在专用线程上时结果照样在；
// 钩子装在本线程上时，回调要等本线程取消息才被调用，早已超时。
// 只用 Ctrl 与 Shift：Alt 会让前台的假客户端进入菜单状态，Win 会弹开始菜单。

//! `eveo-probe ci` 的热键录制检查。

use std::time::{Duration, Instant};

use eveo_core::hotkeys::{Hotkey, HotkeyModifiers};
use eveo_platform_win::recorder::{HotkeyRecorder, RecordOutcome};
use serde_json::json;

use super::{Report, send_chord};

/// Ctrl 与 Shift 的虚拟键码。
const VK_CONTROL: u16 = 0x11;
const VK_SHIFT: u16 = 0x10;
/// J 键与 Esc 键的虚拟键码。
const VK_J: u8 = 0x4A;
const VK_ESCAPE: u8 = 0x1B;

/// 送组合键后本线程不取消息的时长。系统的低级钩子时限（LowLevelHooksTimeout）最长 1 秒，取到 1 秒。
const BUSY: Duration = Duration::from_millis(1000);

/// 送完按键、本线程忙过之后，再等结果的最长时间（钩子线程正常时几毫秒内就有结果）。
const SETTLE: Duration = Duration::from_millis(500);

/// 依次录几个组合：每个都开新的录制器，送按键，本线程忙一秒后核对结果。
pub(super) fn check(report: &mut Report) {
    let cases: [(&str, &[u16], u8, RecordOutcome); 3] = [
        (
            "录制 Ctrl+Shift+J：调用线程忙时也录得到",
            &[VK_CONTROL, VK_SHIFT],
            VK_J,
            RecordOutcome::Recorded(Hotkey::key(
                VK_J,
                HotkeyModifiers::CONTROL | HotkeyModifiers::SHIFT,
            )),
        ),
        (
            "录制 Ctrl+J：调用线程忙时也录得到",
            &[VK_CONTROL],
            VK_J,
            RecordOutcome::Recorded(Hotkey::key(VK_J, HotkeyModifiers::CONTROL)),
        ),
        ("录制时单按 Esc 取消", &[], VK_ESCAPE, RecordOutcome::Cancelled),
    ];
    for (name, modifiers, key, expected) in cases {
        let outcome = record_once(modifiers, key);
        report.check(
            name,
            outcome.as_ref().is_ok_and(|o| *o == Some(expected)),
            true,
            json!({"outcome": format!("{outcome:?}"), "expected": format!("{expected:?}")}),
        );
    }
}

/// 开一个录制器，送一次组合键，本线程睡 `BUSY` 不取消息，再在 `SETTLE` 内取结果。
/// 录制器装不上时返回错误；到时没有结果时返回 `Ok(None)`。
fn record_once(modifiers: &[u16], key: u8) -> Result<Option<RecordOutcome>, String> {
    let recorder = HotkeyRecorder::start()?;
    send_chord(modifiers, key);
    // 模拟忙碌的主线程：既不睡在消息循环里，也不取任何消息。
    std::thread::sleep(BUSY);
    let deadline = Instant::now() + SETTLE;
    loop {
        if let Some(outcome) = recorder.take_outcome() {
            return Ok(Some(outcome));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
