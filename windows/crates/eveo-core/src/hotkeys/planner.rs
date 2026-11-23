// SPDX-License-Identifier: GPL-3.0-or-later
//
// 由配置方案得出要注册的热键绑定，对应 macOS 的 Hotkeys/HotkeyPlanner.swift（架构文档 4.4 节）。
// 遍历顺序、去重与编号与 macOS 相同；拒绝规则换成 Windows 的：系统保留的组合不同，
// 鼠标只能检测中键与两个侧键。用例在 shared/fixtures/hotkey，两端不同的地方在用例里分平台写明。

//! 热键规划。

use std::collections::HashMap;

use super::{Hotkey, HotkeyModifiers, HotkeyScope, HotkeySpec, WINDOWS_MOUSE_BUTTONS, key_code};
use crate::model::Profile;
use crate::switching::CycleDirection;

/// 热键触发后要执行的动作。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum HotkeyAction {
    /// 在循环组里前进或后退。
    Cycle {
        /// 循环组的 id。
        group_id: String,
        /// 方向。
        direction: CycleDirection,
    },
    /// 切到指定角色的客户端。
    ActivateCharacter(String),
    /// 在登录客户端之间循环（前进方向）。
    CycleLoginClients,
    /// 切换「全部隐藏」。
    ToggleHideAll,
    /// 最小化全部客户端。
    MinimizeAll,
}

/// 一条要注册的热键绑定。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HotkeyBinding {
    /// 绑定编号，从 1 起。键盘绑定编进 `RegisterHotKey` 的 id（见 `HotkeyId`），鼠标绑定由钩子回传。
    pub id: u32,
    /// 热键。
    pub hotkey: Hotkey,
    /// 动作。
    pub action: HotkeyAction,
    /// 已解析的作用范围（后缀或配置方案的默认值）。
    pub scope: HotkeyScope,
}

/// 热键被拒绝的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HotkeyRejection {
    /// 没有 Ctrl、Alt、Win 之一，且键不是 F1～F20 或 Num0～Num9。
    MissingModifier,
    /// 系统保留的组合，如 Alt+Tab、Win+L、单独的 F12。
    SystemReserved,
    /// Windows 检测不到的鼠标按键：只支持 Mouse3（中键）、Mouse4、Mouse5（侧键）。macOS 没有这一项。
    UnsupportedMouseButton,
}

/// 规划热键时发现的问题，由设置窗口显示在对应热键旁。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HotkeyIssue {
    /// 字符串无法解析，原文保留在配置里。
    Unparsable {
        /// 原文。
        text: String,
        /// 所属的动作。
        action: HotkeyAction,
    },
    /// 同一个热键出现多次；先出现的生效，后出现的被丢弃。
    Duplicate {
        /// 重复的热键。
        hotkey: Hotkey,
        /// 生效的动作。
        kept: HotkeyAction,
        /// 被丢弃的动作。
        dropped: HotkeyAction,
    },
    /// 热键被拒绝。
    Rejected {
        /// 被拒绝的热键。
        hotkey: Hotkey,
        /// 所属的动作。
        action: HotkeyAction,
        /// 原因。
        reason: HotkeyRejection,
    },
}

/// `plan` 的结果。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HotkeyPlan {
    /// 要注册的绑定，按遍历顺序，id 从 1 起连续。
    pub bindings: Vec<HotkeyBinding>,
    /// 发现的问题，按遍历顺序。
    pub issues: Vec<HotkeyIssue>,
}

impl HotkeyPlan {
    /// 按 id 查找绑定。
    pub fn binding(&self, id: u32) -> Option<&HotkeyBinding> {
        self.bindings.iter().find(|b| b.id == id)
    }
}

/// 由配置方案得出要注册的绑定与问题。
///
/// - 遍历顺序：`hotkeys.toggleHideAll`、`minimizeAll`、`cycleLoginClients`，然后按 `cycleGroups`
///   的顺序（每组先前进后后退），最后是按角色名排序的 `characterHotkeys`（按 Unicode 码位，同 macOS）。
/// - 每条字符串依次检查：无法解析记 `Unparsable`；被拒绝记 `Rejected`（见 `rejection`）；
///   与已接受的热键相同记 `Duplicate`，只比较触发键与修饰键，不比较作用范围。
/// - 通过检查的绑定按遍历顺序从 1 起连续编号；被拒绝或重复的不占编号。
/// - 绑定的作用范围取后缀，没有后缀时取 `profile.hotkey_default_scope`。
pub fn plan(profile: &Profile) -> HotkeyPlan {
    let mut builder = PlanBuilder::new(profile.hotkey_default_scope);
    builder.add(&profile.hotkeys.toggle_hide_all, &HotkeyAction::ToggleHideAll);
    builder.add(&profile.hotkeys.minimize_all, &HotkeyAction::MinimizeAll);
    builder.add(
        &profile.hotkeys.cycle_login_clients,
        &HotkeyAction::CycleLoginClients,
    );
    for group in &profile.cycle_groups {
        for (texts, direction) in [
            (&group.forward_hotkeys, CycleDirection::Forward),
            (&group.backward_hotkeys, CycleDirection::Backward),
        ] {
            let action = HotkeyAction::Cycle {
                group_id: group.id.clone(),
                direction,
            };
            builder.add(texts, &action);
        }
    }
    for (name, texts) in &profile.character_hotkeys {
        builder.add(texts, &HotkeyAction::ActivateCharacter(name.clone()));
    }
    builder.plan
}

/// 检查热键是否被拒绝；可以注册时返回 `None`。
///
/// - 鼠标触发键：只看按钮 Windows 能不能检测；没有修饰键也接受（中键、侧键单独绑定是常见用法）。
/// - 键盘触发键：先查系统保留，再查修饰键（同 macOS 的顺序）。
pub fn rejection(hotkey: &Hotkey) -> Option<HotkeyRejection> {
    let Some(code) = hotkey.key_code() else {
        let supported = hotkey
            .mouse_button()
            .is_some_and(|b| WINDOWS_MOUSE_BUTTONS.contains(&b));
        return (!supported).then_some(HotkeyRejection::UnsupportedMouseButton);
    };
    if is_system_reserved(code, hotkey.modifiers) {
        return Some(HotkeyRejection::SystemReserved);
    }
    let required = HotkeyModifiers::CONTROL | HotkeyModifiers::ALT | HotkeyModifiers::WIN;
    if hotkey.modifiers.is_disjoint(required)
        && !key_code::is_function_key(code)
        && !key_code::is_keypad_digit(code)
    {
        return Some(HotkeyRejection::MissingModifier);
    }
    None
}

/// 系统保留、又不会让 `RegisterHotKey` 报错的组合。
///
/// 被资源管理器占用的 Win 组合（Win+D、Win+Tab 等）注册时会返回 `ERROR_HOTKEY_ALREADY_REGISTERED`，
/// 由设置页按冲突显示，不在这里列。这里只拦截两类：注册能成功、但会抢走系统基本操作的组合
/// （Alt+Tab、Alt+F4、Alt+Esc、Alt+Space、Ctrl+Esc，带不带 Shift 都算），以及系统另行处理、
/// 注册了也收不到的组合（含 Win 的 L 用于锁屏；单独的 F12 或 Shift+F12 留给调试器）。
fn is_system_reserved(code: u8, modifiers: HotkeyModifiers) -> bool {
    use HotkeyModifiers as M;
    let named = |name: &str| key_code::key_code(name) == Some(code);
    let with_optional_shift = |base: HotkeyModifiers| modifiers == base || modifiers == base | M::SHIFT;
    if with_optional_shift(M::ALT) && ["Tab", "Escape", "F4", "Space"].into_iter().any(named) {
        return true;
    }
    if with_optional_shift(M::CONTROL) && named("Escape") {
        return true;
    }
    if modifiers.contains(M::WIN) && named("L") {
        return true;
    }
    with_optional_shift(M::NONE) && named("F12")
}

/// 逐条累积绑定与问题。
struct PlanBuilder {
    /// 配置方案的默认作用范围，没有后缀的热键取它。
    default_scope: HotkeyScope,
    /// 累积的结果。
    plan: HotkeyPlan,
    /// 已接受的热键 → 它的动作，用于判断重复。键是 Hotkey，不含作用范围。
    owners: HashMap<Hotkey, HotkeyAction>,
}

impl PlanBuilder {
    /// 用配置方案的默认作用范围建一个累积器。
    fn new(default_scope: HotkeyScope) -> Self {
        Self {
            default_scope,
            plan: HotkeyPlan::default(),
            owners: HashMap::new(),
        }
    }

    /// 处理一个动作的全部热键字符串。
    fn add(&mut self, texts: &[String], action: &HotkeyAction) {
        for text in texts {
            let Some(spec) = HotkeySpec::parse(text) else {
                self.plan.issues.push(HotkeyIssue::Unparsable {
                    text: text.clone(),
                    action: action.clone(),
                });
                continue;
            };
            let hotkey = spec.hotkey;
            if let Some(reason) = rejection(&hotkey) {
                self.plan.issues.push(HotkeyIssue::Rejected {
                    hotkey,
                    action: action.clone(),
                    reason,
                });
                continue;
            }
            if let Some(kept) = self.owners.get(&hotkey) {
                self.plan.issues.push(HotkeyIssue::Duplicate {
                    hotkey,
                    kept: kept.clone(),
                    dropped: action.clone(),
                });
                continue;
            }
            self.owners.insert(hotkey, action.clone());
            let id = u32::try_from(self.plan.bindings.len() + 1).unwrap_or(u32::MAX);
            self.plan.bindings.push(HotkeyBinding {
                id,
                hotkey,
                action: action.clone(),
                scope: spec.resolved_scope(self.default_scope),
            });
        }
    }
}
