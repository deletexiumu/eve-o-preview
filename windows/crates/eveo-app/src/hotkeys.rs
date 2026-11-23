// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键服务（架构文档 4.4 节）：把协调器给的绑定注册到系统。
// - 键盘绑定用 RegisterHotKey，编号带代数（`hotkey_id`）。整份绑定替换时换一代，队列里上一代的
//   WM_HOTKEY 解码后代数对不上，直接丢弃，不会对上新规划里别的动作。
// - 作用范围是 game 的键盘热键只在前台是 EVE 客户端时注册，否则别的程序收不到这个组合。
//   前台变化时只增删这些热键，不换代。
// - 鼠标绑定交给低级鼠标钩子的匹配器；有鼠标绑定时才装钩子，没有时拆掉，平时不拦截任何鼠标事件。
// - 设置窗口录制热键时暂停：注销全部键盘热键、让匹配器放行，录完再恢复，按下的组合不会被自己的热键吞掉。
// - 注册失败（被别的程序占用）的绑定记下来，设置窗口在对应热键旁提示；下次成功注册时清掉。

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use eveo_core::hotkeys::activation::is_active;
use eveo_core::hotkeys::backend::hotkey_id;
use eveo_core::hotkeys::{
    Hotkey, HotkeyAction, HotkeyBinding, HotkeyTrigger, MouseBinding, MouseHotkeyMatcher,
};
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
    /// 是否暂停（设置窗口正在录制热键）。
    suspended: bool,
    /// 注册失败的绑定 id。
    failed: HashSet<u32>,
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
            suspended: false,
            failed: HashSet::new(),
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
        // 绑定 id 随规划重排，旧的失败记录对不上新的绑定，清掉后按这次注册的结果重记。
        self.failed.clear();
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

    /// 暂停或恢复全部热键（录制热键期间暂停）。
    /// 暂停时键盘热键全部注销（不换代，恢复时按原编号重新注册），鼠标匹配器放行全部按键；
    /// 录制器另外用钩子吞掉按下的组合，两层都在，录制时不会触发任何热键。
    pub fn set_suspended(&mut self, suspended: bool) {
        if suspended == self.suspended {
            return;
        }
        self.suspended = suspended;
        lock(&self.matcher).set_suspended(suspended);
        self.sync_keyboard();
    }

    /// 注册失败的热键，按动作与组合，给设置窗口的问题提示用。
    /// 只含当前一代里注册失败、之后也没注册成功的绑定；作用范围是 game 的热键只在 EVE 在前台时注册，
    /// 所以它们的失败要等切到游戏后才知道。
    pub fn failures(&self) -> Vec<(HotkeyAction, Hotkey)> {
        self.bindings
            .iter()
            .filter(|b| self.failed.contains(&b.id))
            .map(|b| (b.action.clone(), b.hotkey))
            .collect()
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
            if !is_active(binding.scope, self.game_foreground, self.suspended) {
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
            // 被别的程序占用或系统拒绝时跳过这一个，其余热键照常注册；失败的记下，设置窗口在热键旁提示。
            // 注册结果按绑定 id 记：同一个组合换了动作（id 变了）时，旧的失败记录不会挂到新动作上。
            if self.window.register(raw, binding.hotkey.modifiers, key).is_ok() {
                self.registered.insert(raw);
                self.failed.remove(&binding.id);
            } else {
                self.failed.insert(binding.id);
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
