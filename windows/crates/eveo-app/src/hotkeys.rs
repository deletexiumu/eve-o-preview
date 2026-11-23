// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键服务（架构文档 4.4 节）：把协调器给的绑定注册到系统。
// - 键盘绑定用 RegisterHotKey，编号带代数（`hotkey_id`）。整份绑定替换时换一代，队列里上一代的
//   WM_HOTKEY 解码后代数对不上，直接丢弃，不会对上新规划里别的动作。
// - 作用范围是 game 的键盘热键只在前台是 EVE 客户端时注册，否则别的程序收不到这个组合。
//   前台变化时只增删这些热键，不换代。
// - 鼠标绑定交给低级鼠标钩子的匹配器；有鼠标绑定时才装钩子，没有时拆掉，平时不拦截任何鼠标事件。

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use eveo_core::hotkeys::activation::is_active;
use eveo_core::hotkeys::backend::hotkey_id;
use eveo_core::hotkeys::{HotkeyBinding, HotkeyTrigger, MouseBinding, MouseHotkeyMatcher};
use eveo_platform_win::hotkey::HotkeyWindow;
use eveo_platform_win::mouse_hook::{MouseHook, SharedMatcher};

/// 已注册到系统的热键与鼠标钩子。
pub struct HotkeyService {
    /// 接收 WM_HOTKEY 与鼠标热键消息的窗口。
    window: HotkeyWindow,
    /// 当前代数。
    generation: u32,
    /// 当前绑定（协调器的规划）。
    bindings: Vec<HotkeyBinding>,
    /// 已注册的键盘热键编号（含代数）。
    registered: HashSet<i32>,
    /// 前台是否是 EVE 客户端。
    game_foreground: bool,
    /// 鼠标钩子的匹配器，与钩子线程共享。
    matcher: SharedMatcher,
    /// 鼠标钩子；没有鼠标绑定时为 `None`。
    mouse_hook: Option<MouseHook>,
}

impl HotkeyService {
    /// 用已建好的热键窗口建服务。窗口的处理函数由调用方设置。
    pub fn new(window: HotkeyWindow) -> Self {
        Self {
            window,
            generation: 0,
            bindings: Vec::new(),
            registered: HashSet::new(),
            game_foreground: false,
            matcher: Arc::new(Mutex::new(MouseHotkeyMatcher::new())),
            mouse_hook: None,
        }
    }

    /// 设热键窗口的处理函数：键盘热键与鼠标热键的触发都经它送出。
    pub fn set_handler(&self, handler: impl FnMut(eveo_platform_win::hotkey::HotkeyMessage) + 'static) {
        self.window.set_handler(handler);
    }

    /// 用新的绑定替换全部热键：换一代，注销全部键盘热键再按前台重新注册，替换鼠标绑定。
    pub fn replace(&mut self, bindings: Vec<HotkeyBinding>) {
        // 先换代再注册：之后到达的 WM_HOTKEY 如果带着上一代的编号，decode 会认出并丢弃。
        self.generation = hotkey_id::next_generation(self.generation);
        self.window.unregister_all();
        self.registered.clear();
        self.bindings = bindings;
        self.sync_keyboard();
        let mouse: Vec<MouseBinding> = self
            .bindings
            .iter()
            .filter_map(|b| match b.hotkey.trigger {
                HotkeyTrigger::MouseButton(button) => Some(MouseBinding {
                    id: b.id,
                    button,
                    modifiers: b.hotkey.modifiers,
                    scope: b.scope,
                }),
                HotkeyTrigger::Key(_) => None,
            })
            .collect();
        // 匹配器先换绑定再决定钩子的去留：钩子线程随时可能读匹配器。
        let has_mouse = !mouse.is_empty();
        lock(&self.matcher).replace_bindings(mouse);
        self.sync_mouse_hook(has_mouse);
    }

    /// 前台是否是 EVE 客户端变了：增删作用范围是 game 的键盘热键，并告诉鼠标匹配器。
    pub fn set_game_foreground(&mut self, game: bool) {
        if game == self.game_foreground {
            return;
        }
        self.game_foreground = game;
        lock(&self.matcher).set_game_frontmost(game);
        self.sync_keyboard();
    }

    /// 把 WM_HOTKEY 里的编号换回绑定 id；上一代的编号返回 `None`。
    pub fn decode(&self, raw: i32) -> Option<u32> {
        let (generation, id) = hotkey_id::decode(raw)?;
        (generation == self.generation).then_some(id)
    }

    /// 让已注册的键盘热键与「此刻应启用的绑定」一致：多的注销，少的注册。
    fn sync_keyboard(&mut self) {
        let mut wanted: Vec<(i32, &HotkeyBinding, u8)> = Vec::new();
        for binding in &self.bindings {
            let HotkeyTrigger::Key(key) = binding.hotkey.trigger else {
                continue;
            };
            if !is_active(binding.scope, self.game_foreground, false) {
                continue;
            }
            if let Some(raw) = hotkey_id::encode(self.generation, binding.id) {
                wanted.push((raw, binding, key));
            }
        }
        let wanted_ids: HashSet<i32> = wanted.iter().map(|(raw, _, _)| *raw).collect();
        for raw in self
            .registered
            .iter()
            .copied()
            .filter(|r| !wanted_ids.contains(r))
            .collect::<Vec<_>>()
        {
            self.window.unregister(raw);
            self.registered.remove(&raw);
        }
        for (raw, binding, key) in wanted {
            if self.registered.contains(&raw) {
                continue;
            }
            // 被别的程序占用或系统拒绝时跳过这一个，其余热键照常注册。
            // 冲突提示要等设置窗口的热键页（它在热键旁标出冲突），届时把失败项交给设置窗口。
            if self.window.register(raw, binding.hotkey.modifiers, key).is_ok() {
                self.registered.insert(raw);
            }
        }
    }

    /// 有鼠标绑定时保证钩子在运行，没有时拆掉。
    fn sync_mouse_hook(&mut self, needed: bool) {
        match (needed, self.mouse_hook.is_some()) {
            (true, false) => {
                // 装不上（极少见）时鼠标热键不可用，键盘热键不受影响。
                self.mouse_hook = MouseHook::start(Arc::clone(&self.matcher), self.window.hwnd()).ok();
            }
            (false, true) => self.mouse_hook = None,
            _ => {}
        }
    }
}

/// 锁住匹配器。钩子线程恐慌导致锁中毒时仍取出数据：匹配器的状态总是完整的。
fn lock(matcher: &SharedMatcher) -> std::sync::MutexGuard<'_, MouseHotkeyMatcher> {
    matcher.lock().unwrap_or_else(|e| e.into_inner())
}
