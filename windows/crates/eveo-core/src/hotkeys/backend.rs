// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键后端用到的纯规则，对应 macOS 的 Hotkeys/HotkeyBackendRules.swift，换成 Windows 的接口约束（架构文档 4.4 节）：
// `RegisterHotKey` 的编号编码，以及低级鼠标钩子的定期重装节奏。平台层调这里，规则本身可以直接单元测试。

//! 热键注册编号与鼠标钩子重装的规则。

/// `RegisterHotKey` 的编号：高 2 位是代数，低 14 位是绑定 id。
///
/// 应用可用的编号是 0x0000～0xBFFF。规划每次都从 1 起重新编号；`WM_HOTKEY` 先排进消息队列、
/// 重新注册之后才分发时，旧编号会对上新规划里别的动作。带上代数后，处理消息时能认出并丢弃上一代的事件。
/// 编号上限决定代数只能取 0、1、2 三个值，循环使用；队列里不会积压三代之前的消息。
pub mod hotkey_id {
    /// 绑定 id 占低 14 位。
    pub const BINDING_ID_MASK: u32 = 0x3FFF;
    /// 代数的个数：0、1、2。
    pub const GENERATIONS: u32 = 3;

    /// 把代数与绑定 id 编成一个编号。绑定 id 为 0 或大于 `BINDING_ID_MASK` 时返回 `None`；代数按 3 取余。
    pub fn encode(generation: u32, binding_id: u32) -> Option<i32> {
        if binding_id == 0 || binding_id > BINDING_ID_MASK {
            return None;
        }
        i32::try_from((generation % GENERATIONS) << 14 | binding_id).ok()
    }

    /// 从编号里取出代数与绑定 id；不在 0x0000～0xBFFF 内时返回 `None`。
    pub fn decode(raw: i32) -> Option<(u32, u32)> {
        let raw = u32::try_from(raw).ok().filter(|&r| r <= 0xBFFF)?;
        Some((raw >> 14, raw & BINDING_ID_MASK))
    }

    /// 下一代的代数：加 1，到 2 之后回到 0。
    pub fn next_generation(after: u32) -> u32 {
        (after % GENERATIONS + 1) % GENERATIONS
    }
}

/// 低级鼠标钩子的定期重装。
///
/// 钩子回调超时后系统会不加通知地摘掉钩子，所以有鼠标绑定时每隔 `INTERVAL` 秒重装一次（先装新的再卸旧的）。
pub mod mouse_hook_refresh {
    /// 两次重装之间隔多少秒。
    pub const INTERVAL: f64 = 30.0;

    /// 此刻是否该重装。
    ///
    /// - `installed_at`：当前钩子装上的时刻（单调时钟的秒数）；没有装钩子时为 `None`，不重装。
    /// - `is_suspended`：热键暂停期间（录制热键、应用退出）不重装。
    pub fn is_due(installed_at: Option<f64>, now: f64, is_suspended: bool) -> bool {
        match installed_at {
            Some(at) if !is_suspended => now - at >= INTERVAL,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 编号在应用可用的范围内，能解回原值。
    #[test]
    fn hotkey_id_round_trips() {
        assert_eq!(hotkey_id::encode(0, 1), Some(1));
        assert_eq!(hotkey_id::encode(2, 0x3FFF), Some(0xBFFF));
        assert_eq!(hotkey_id::encode(5, 7), hotkey_id::encode(2, 7));
        assert_eq!(hotkey_id::encode(0, 0), None);
        assert_eq!(hotkey_id::encode(0, 0x4000), None);
        assert_eq!(hotkey_id::decode(0x8005), Some((2, 5)));
        assert_eq!(hotkey_id::decode(0xC000), None);
        assert_eq!(hotkey_id::decode(-1), None);
        assert_eq!(hotkey_id::next_generation(2), 0);
        assert_eq!(hotkey_id::next_generation(0), 1);
    }

    /// 重装节奏：没装、暂停时不重装，满 30 秒才重装。
    #[test]
    fn mouse_hook_refresh_timing() {
        assert!(!mouse_hook_refresh::is_due(None, 100.0, false));
        assert!(!mouse_hook_refresh::is_due(Some(80.0), 100.0, false));
        assert!(mouse_hook_refresh::is_due(Some(70.0), 100.0, false));
        assert!(!mouse_hook_refresh::is_due(Some(70.0), 100.0, true));
    }
}
