// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「切换与热键」页与配置之间的转换，对应 macOS 的 SettingsViewModel+Actions 里热键与循环组的部分。
// - show_switching：按配置、在线客户端、热键规划的问题与注册失败项填页面。与「客户端」页一样每次事件后刷新，
//   所以逐项比较、只换变了的部分，录制按钮与下拉框不会在用户操作时被重建。
// - SwitchingEdit：页面上的一次改动；apply_switching_edit 把它作用到配置方案上。
// 热键的位置（Slot）与页面上的字符串标识互相转换，格式见 switching.slint 的文件头。
// 录制到的热键怎么写进配置（反馈文档 6.8 节）：重录保留原来的作用范围；新录的鼠标热键写成 `@game`，
// 免得全局吞掉浏览器的后退键；键盘热键不写后缀，跟随默认范围。同一列表里已有同一个组合时不再追加。

//! 「切换与热键」页的绑定。

use std::rc::Rc;

use eveo_core::config::new_id;
use eveo_core::hotkeys::{
    Hotkey, HotkeyAction, HotkeyIssue, HotkeyPlan, HotkeyRejection, HotkeyScope, HotkeySpec,
};
use eveo_core::model::{CycleGroup, EveClient, Profile};
use eveo_core::switching::CycleDirection;
use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

use crate::bind::character_names;
use crate::language;
use crate::{CycleGroupData, HotkeyRow, HotkeySlotData, MemberRow, SettingsWindow, SwitchingModel};

/// 热键在配置里的位置。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Slot {
    /// 循环组的前进或后退热键（循环组 id、方向）。
    Cycle(String, CycleDirection),
    /// 某个角色的直达热键。
    Character(String),
    /// 「全部隐藏」。
    ToggleHideAll,
    /// 「全部最小化」。
    MinimizeAll,
    /// 在登录客户端之间循环。
    CycleLoginClients,
}

impl Slot {
    /// 页面上的标识。
    pub fn key(&self) -> String {
        match self {
            // 循环组按 id 而不是名称标识：名称可以重复，也可以在录制期间被改掉。
            Self::Cycle(id, CycleDirection::Forward) => format!("group:{id}:forward"),
            Self::Cycle(id, CycleDirection::Backward) => format!("group:{id}:backward"),
            // 角色名原样放在冒号后面，解析时只切前缀，名字里有冒号也没关系。
            Self::Character(name) => format!("character:{name}"),
            Self::ToggleHideAll => "toggleHideAll".to_owned(),
            Self::MinimizeAll => "minimizeAll".to_owned(),
            Self::CycleLoginClients => "cycleLoginClients".to_owned(),
        }
    }

    /// 由页面上的标识解析。角色名里可以有冒号，所以只切第一个冒号。
    pub fn parse(key: &str) -> Option<Self> {
        match key {
            "toggleHideAll" => return Some(Self::ToggleHideAll),
            "minimizeAll" => return Some(Self::MinimizeAll),
            "cycleLoginClients" => return Some(Self::CycleLoginClients),
            _ => {}
        }
        if let Some(name) = key.strip_prefix("character:") {
            return Some(Self::Character(name.to_owned()));
        }
        // 循环组 id 是 UUID，不含冒号；方向在最后一个冒号之后。
        let rest = key.strip_prefix("group:")?;
        let (id, direction) = rest.rsplit_once(':')?;
        let direction = match direction {
            "forward" => CycleDirection::Forward,
            "backward" => CycleDirection::Backward,
            _ => return None,
        };
        Some(Self::Cycle(id.to_owned(), direction))
    }

    /// 这个位置的热键触发的动作，用来在热键规划的问题里找到属于它的那些。
    pub fn action(&self) -> HotkeyAction {
        match self {
            Self::Cycle(id, direction) => HotkeyAction::Cycle {
                group_id: id.clone(),
                direction: *direction,
            },
            Self::Character(name) => HotkeyAction::ActivateCharacter(name.clone()),
            Self::ToggleHideAll => HotkeyAction::ToggleHideAll,
            Self::MinimizeAll => HotkeyAction::MinimizeAll,
            Self::CycleLoginClients => HotkeyAction::CycleLoginClients,
        }
    }
}

/// 某个位置当前的热键列表；位置不存在（循环组已删）时为空。
pub fn hotkeys(profile: &Profile, slot: &Slot) -> Vec<String> {
    match slot {
        // 循环组已删时读出空列表，录制结果写回时也找不到组，两边一致。
        Slot::Cycle(id, direction) => profile
            .cycle_groups
            .iter()
            .find(|g| &g.id == id)
            .map(|g| match direction {
                CycleDirection::Forward => g.forward_hotkeys.clone(),
                CycleDirection::Backward => g.backward_hotkeys.clone(),
            })
            .unwrap_or_default(),
        // 角色没有直达热键时配置里没有这个键，读出空列表。
        Slot::Character(name) => profile.character_hotkeys.get(name).cloned().unwrap_or_default(),
        Slot::ToggleHideAll => profile.hotkeys.toggle_hide_all.clone(),
        Slot::MinimizeAll => profile.hotkeys.minimize_all.clone(),
        Slot::CycleLoginClients => profile.hotkeys.cycle_login_clients.clone(),
    }
}

/// 替换某个位置的热键列表。角色的列表清空时删掉这一项，配置里不留空数组。
pub fn set_hotkeys(profile: &mut Profile, slot: &Slot, list: Vec<String>) {
    match slot {
        Slot::Cycle(id, direction) => {
            if let Some(group) = profile.cycle_groups.iter_mut().find(|g| &g.id == id) {
                match direction {
                    CycleDirection::Forward => group.forward_hotkeys = list,
                    CycleDirection::Backward => group.backward_hotkeys = list,
                }
            }
        }
        Slot::Character(name) => {
            if list.is_empty() {
                profile.character_hotkeys.remove(name);
            } else {
                profile.character_hotkeys.insert(name.clone(), list);
            }
        }
        Slot::ToggleHideAll => profile.hotkeys.toggle_hide_all = list,
        Slot::MinimizeAll => profile.hotkeys.minimize_all = list,
        Slot::CycleLoginClients => profile.hotkeys.cycle_login_clients = list,
    }
}

/// 「切换与热键」页上的一次改动。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SwitchingEdit {
    /// 默认作用范围。
    DefaultScope(HotkeyScope),
    /// 新建循环组；id 由调用方生成，测试里可以固定。
    AddGroup(String),
    /// 改名；全是空白的名称不接受。
    RenameGroup {
        /// 循环组 id。
        id: String,
        /// 新名称。
        name: String,
    },
    /// 删除循环组。
    DeleteGroup(String),
    /// 添加成员。已在组里的不重复添加。
    AddMember {
        /// 循环组 id。
        id: String,
        /// 角色名。
        name: String,
    },
    /// 移动成员：`delta` 为 -1 上移、1 下移，越界时不动。
    MoveMember {
        /// 循环组 id。
        id: String,
        /// 成员的位置。
        index: usize,
        /// 移动的步数。
        delta: i32,
    },
    /// 移除成员。
    RemoveMember {
        /// 循环组 id。
        id: String,
        /// 成员的位置。
        index: usize,
    },
    /// 录到一个热键：`text` 为空表示新增一行，否则替换这一行。
    Recorded {
        /// 位置。
        slot: Slot,
        /// 被替换的原文；新增时为空串。
        text: String,
        /// 录到的组合。
        hotkey: Hotkey,
    },
    /// 移除一条热键（移除按钮，或录制时单按 Backspace / Delete）。
    RemoveHotkey {
        /// 位置。
        slot: Slot,
        /// 原文。
        text: String,
    },
    /// 改一条热键的作用范围；`None` 表示跟随默认。
    SetScope {
        /// 位置。
        slot: Slot,
        /// 原文。
        text: String,
        /// 新的作用范围。
        scope: Option<HotkeyScope>,
    },
}

/// 新建循环组的 id：大写 UUID，与 macOS 相同。
/// 放在这里而不是让页面生成：Slint 没有生成 UUID 的办法，应用在回调里调用它。
pub fn new_group_id() -> String {
    new_id()
}

/// 把一次改动作用到配置方案上。找不到对象（循环组已删、原文已不在列表里）时什么也不做。
pub fn apply_switching_edit(profile: &mut Profile, edit: &SwitchingEdit) {
    match edit {
        // 默认范围只影响没写后缀的热键；已经单独设了范围的不动。
        SwitchingEdit::DefaultScope(scope) => profile.hotkey_default_scope = *scope,
        SwitchingEdit::AddGroup(id) => {
            // 默认名称带序号，新建几个也分得清；用户随后可以改名。
            let index = profile.cycle_groups.len() as i64 + 1;
            let name = eveo_l10n::hotkeys(language()).new_group_name(index);
            profile.cycle_groups.push(CycleGroup {
                id: id.clone(),
                name,
                ..CycleGroup::default()
            });
        }
        // 名称去掉首尾空白；全是空白时保留原名（同 macOS），输入框随后的刷新会显示原名。
        SwitchingEdit::RenameGroup { id, name } => {
            let trimmed = name.trim();
            if let (false, Some(group)) = (trimmed.is_empty(), group_mut(profile, id)) {
                group.name = trimmed.to_owned();
            }
        }
        // 删除循环组连同它的热键一起删；正在录这个组的热键时，录到的结果找不到组，什么也不做。
        SwitchingEdit::DeleteGroup(id) => profile.cycle_groups.retain(|g| &g.id != id),
        // 成员名区分大小写，与窗口标题里的角色名一致；已在组里的不重复添加（校验也会去重）。
        SwitchingEdit::AddMember { id, name } => {
            if let Some(group) = group_mut(profile, id).filter(|g| !g.members.contains(name)) {
                group.members.push(name.clone());
            }
        }
        // 上移下移是与相邻的成员交换；位置来自渲染时，越界（列表已在别处变短）时不动。
        SwitchingEdit::MoveMember { id, index, delta } => {
            if let Some(group) = group_mut(profile, id) {
                let target = index.checked_add_signed(*delta as isize);
                if let Some(target) =
                    target.filter(|t| *t < group.members.len() && *index < group.members.len())
                {
                    group.members.swap(*index, target);
                }
            }
        }
        SwitchingEdit::RemoveMember { id, index } => {
            // 位置来自渲染时；列表已在别处变短时不越界。
            if let Some(group) = group_mut(profile, id).filter(|g| *index < g.members.len()) {
                group.members.remove(*index);
            }
        }
        // 录到的组合：原文为空是新增，否则替换原文所在的一行；原文已不在列表里（录制期间被删）时不写回。
        SwitchingEdit::Recorded { slot, text, hotkey } => {
            let mut list = hotkeys(profile, slot);
            if text.is_empty() {
                // 新增：同一列表里已有这个组合（不论作用范围）时不再追加。
                if !list
                    .iter()
                    .any(|t| HotkeySpec::parse(t).is_some_and(|s| s.hotkey == *hotkey))
                {
                    list.push(recorded_text(*hotkey, None));
                }
            } else if let Some(index) = list.iter().position(|t| t == text) {
                list[index] = recorded_text(*hotkey, Some(text));
            }
            set_hotkeys(profile, slot, list);
        }
        // 按原文找行；同一列表里有重复的原文（手改配置）时只删第一条。
        SwitchingEdit::RemoveHotkey { slot, text } => {
            let mut list = hotkeys(profile, slot);
            if let Some(index) = list.iter().position(|t| t == text) {
                list.remove(index);
                set_hotkeys(profile, slot, list);
            }
        }
        // 解析不了的一条没有范围可改，原样保留；改完写成规范写法（带或不带后缀）。
        SwitchingEdit::SetScope { slot, text, scope } => {
            let mut list = hotkeys(profile, slot);
            let spec = list.iter().position(|t| t == text).zip(HotkeySpec::parse(text));
            if let Some((index, mut spec)) = spec {
                spec.scope = *scope;
                list[index] = spec.to_string();
                set_hotkeys(profile, slot, list);
            }
        }
    }
}

/// 录到的热键要写进配置的字符串：重录保留原来的作用范围；原来没有后缀（或新增）而录到鼠标按键时写 `@game`。
pub fn recorded_text(hotkey: Hotkey, replacing: Option<&str>) -> String {
    // 原来的后缀优先：用户特意设过的范围，重录时不该被默认规则改掉。
    let old_scope = replacing.and_then(HotkeySpec::parse).and_then(|s| s.scope);
    // 鼠标按键默认仅游戏内：全局的鼠标绑定会在所有程序里吞掉这个按键（浏览器的后退键就失效了）。
    let scope = old_scope.or(hotkey.is_mouse().then_some(HotkeyScope::Game));
    HotkeySpec { hotkey, scope }.to_string()
}

/// 按 id 找循环组。
/// 找不到（已被删除）时返回 `None`，各项改动随之什么也不做。
fn group_mut<'a>(profile: &'a mut Profile, id: &str) -> Option<&'a mut CycleGroup> {
    profile.cycle_groups.iter_mut().find(|g| g.id == id)
}

/// 页面需要的、配置之外的状态。
pub struct SwitchingState<'a> {
    /// 当前在线的客户端。
    pub clients: &'a [EveClient],
    /// 协调器当前的热键规划，用来标出重复、被拒绝与解析不了的热键。
    pub plan: &'a HotkeyPlan,
    /// 向系统注册失败的热键（被别的程序占用等），按动作与组合。
    pub failed: &'a [(HotkeyAction, Hotkey)],
    /// 正在录制的位置与原文（新增时原文为空串）。
    pub recording: Option<(Slot, String)>,
}

/// 按配置与状态填「切换与热键」页。
pub fn show_switching(ui: &SettingsWindow, profile: &Profile, state: &SwitchingState<'_>) {
    let model = ui.global::<SwitchingModel>();
    // 单选的下标：0 全局，1 仅游戏内，与 switching.slint 的顺序一致。
    model.set_default_scope(match profile.hotkey_default_scope {
        HotkeyScope::Global => 0,
        HotkeyScope::Game => 1,
    });
    // 录制状态写成「位置|原文」，页面上每个按钮自己比较，决定是否显示「按下组合键…」。
    let recording = state
        .recording
        .as_ref()
        .map(|(slot, text)| format!("{}|{text}", slot.key()))
        .unwrap_or_default();
    model.set_recording(recording.into());

    // 已知角色与「客户端」页的列表相同：在线的加上配置里出现过的。
    let names = character_names(profile, state.clients);
    let online: Vec<&str> = state
        .clients
        .iter()
        .filter_map(EveClient::character_name)
        .collect();
    // 下面三处都要建热键卡片的数据，参数相同的部分先绑定好。
    let slot_data = |slot: Slot, title: &str| slot_data(profile, state, slot, title);
    let (hotkeys, settings) = (eveo_l10n::hotkeys(language()), eveo_l10n::settings(language()));

    // 循环组：每组的名称、两组热键、成员与可添加的角色。
    let groups: Vec<CycleGroupData> = profile
        .cycle_groups
        .iter()
        .map(|group| {
            // 成员按配置里的顺序，在线状态看当前的客户端。
            let members: Vec<MemberRow> = group
                .members
                .iter()
                .map(|name| MemberRow {
                    name: name.as_str().into(),
                    online: online.contains(&name.as_str()),
                })
                .collect();
            // 候选：不在组里的已知角色，在线的排前面并带圆点；第一项是下拉框的提示文字。
            // 排序是稳定的：在线与离线两部分内部仍按名称排序。
            let mut candidates: Vec<&String> = names.iter().filter(|n| !group.members.contains(n)).collect();
            candidates.sort_by_key(|n| !online.contains(&n.as_str()));
            let candidates: Vec<SharedString> = std::iter::once(SharedString::from(hotkeys.add_member()))
                .chain(candidates.into_iter().map(|n| {
                    if online.contains(&n.as_str()) {
                        format!("{n} ●").into()
                    } else {
                        n.as_str().into()
                    }
                }))
                .collect();
            CycleGroupData {
                id: group.id.as_str().into(),
                name: group.name.as_str().into(),
                saved_name: group.name.as_str().into(),
                forward: slot_data(
                    Slot::Cycle(group.id.clone(), CycleDirection::Forward),
                    settings.forward(),
                ),
                backward: slot_data(
                    Slot::Cycle(group.id.clone(), CycleDirection::Backward),
                    settings.backward(),
                ),
                members: model_of(members),
                candidates: model_of(candidates),
            }
        })
        .collect();
    // 同一位置还是同一个组、配置里的名称也没变时，保留输入框里的文字（可能正在改名）。
    let current = model.get_groups();
    let groups: Vec<CycleGroupData> = groups
        .into_iter()
        .enumerate()
        .map(|(index, mut group)| {
            if let Some(old) = current.row_data(index)
                && old.id == group.id
                && old.saved_name == group.saved_name
            {
                group.name = old.name;
            }
            group
        })
        .collect();
    sync_rows(&current, groups, same_group, |rows| model.set_groups(rows));

    // 角色直达热键：全部已知角色（含离线的），离线角色的热键也照常注册，上线后即可用。
    // 卡片标题就是角色名；没有热键的角色也列出来，方便直接添加。
    let characters: Vec<HotkeySlotData> = names
        .iter()
        .map(|name| slot_data(Slot::Character(name.clone()), name))
        .collect();
    sync_rows(&model.get_characters(), characters, same_slot, |rows| {
        model.set_characters(rows)
    });

    // 通用热键固定三项，顺序与 macOS 相同。
    let general = vec![
        slot_data(Slot::ToggleHideAll, hotkeys.hotkey_toggle_hide_all()),
        slot_data(Slot::MinimizeAll, hotkeys.hotkey_minimize_all()),
        slot_data(Slot::CycleLoginClients, hotkeys.hotkey_cycle_login()),
    ];
    sync_rows(&model.get_general(), general, same_slot, |rows| {
        model.set_general(rows)
    });
}

/// 一个位置的热键卡片数据。
fn slot_data(profile: &Profile, state: &SwitchingState<'_>, slot: Slot, title: &str) -> HotkeySlotData {
    // 这个位置对应的动作：热键规划的问题与注册失败项都按动作记，按它筛出属于这一行的。
    let action = slot.action();
    let rows: Vec<HotkeyRow> = hotkeys(profile, &slot)
        .into_iter()
        .map(|text| {
            // 解析失败的一行仍然显示（原文），让用户能重录或移除。
            let spec = HotkeySpec::parse(&text);
            // 范围下拉框的下标：-1 表示解析不了、不显示下拉框；0 跟随默认；1 全局；2 仅游戏内。
            let scope = match spec.map(|s| s.scope) {
                None => -1,
                Some(None) => 0,
                Some(Some(HotkeyScope::Global)) => 1,
                Some(Some(HotkeyScope::Game)) => 2,
            };
            // 组装一行：界面写法、问题提示、原文与范围。
            HotkeyRow {
                label: spec
                    .map_or_else(|| text.clone(), |s| s.hotkey.display_string())
                    .into(),
                problem: problem(profile, state, &action, &text).unwrap_or_default().into(),
                text: text.into(),
                scope,
            }
        })
        .collect();
    // 位置标识随卡片一起交给页面，按钮的回调原样传回。
    HotkeySlotData {
        slot: slot.key().into(),
        title: title.into(),
        rows: model_of(rows),
    }
}

/// 一条热键的问题提示，对应 macOS 的 hotkeyProblem：解析不了、与别的动作重复、被拒绝、注册失败。
fn problem(
    profile: &Profile,
    state: &SwitchingState<'_>,
    action: &HotkeyAction,
    text: &str,
) -> Option<String> {
    // 先看能不能解析：解析不了的一条不会进规划，也就没有别的问题可报。
    let strings = eveo_l10n::hotkeys(language());
    let Some(hotkey) = HotkeySpec::parse(text).map(|s| s.hotkey) else {
        return Some(strings.hotkey_unparsable().to_owned());
    };
    // 规划里的问题按遍历顺序排列；同一条热键只报第一个相关的问题。
    for issue in &state.plan.issues {
        match issue {
            HotkeyIssue::Duplicate {
                hotkey: duplicated,
                kept,
                dropped,
            } if *duplicated == hotkey && dropped == action => {
                return Some(strings.hotkey_duplicate(&describe(profile, kept)));
            }
            HotkeyIssue::Rejected {
                hotkey: rejected,
                action: owner,
                reason,
            } if *rejected == hotkey && owner == action => {
                return Some(
                    match reason {
                        HotkeyRejection::MissingModifier => strings.hotkey_missing_modifier(),
                        HotkeyRejection::SystemReserved => strings.hotkey_reserved(),
                        HotkeyRejection::UnsupportedMouseButton => strings.hotkey_unsupported_mouse_button(),
                    }
                    .to_owned(),
                );
            }
            _ => {}
        }
    }
    // 最后看注册失败：规划认为没问题，但系统不让注册（多半被别的程序占用）。
    state
        .failed
        .iter()
        .any(|(a, h)| a == action && *h == hotkey)
        .then(|| strings.hotkey_in_use().to_owned())
}

/// 动作的界面名称，用在「与某某重复」里。
/// 循环组的动作写成「组名 · 方向」，组已删时退回组 id。
fn describe(profile: &Profile, action: &HotkeyAction) -> String {
    let (hotkeys, settings) = (eveo_l10n::hotkeys(language()), eveo_l10n::settings(language()));
    match action {
        HotkeyAction::ToggleHideAll => hotkeys.hotkey_toggle_hide_all().to_owned(),
        HotkeyAction::MinimizeAll => hotkeys.hotkey_minimize_all().to_owned(),
        HotkeyAction::CycleLoginClients => hotkeys.hotkey_cycle_login().to_owned(),
        HotkeyAction::ActivateCharacter(name) => name.clone(),
        HotkeyAction::Cycle { group_id, direction } => {
            let name = profile
                .cycle_groups
                .iter()
                .find(|g| &g.id == group_id)
                .map_or(group_id.as_str(), |g| g.name.as_str());
            let direction = match direction {
                CycleDirection::Forward => settings.forward(),
                CycleDirection::Backward => settings.backward(),
            };
            format!("{name} · {direction}")
        }
    }
}

/// 列表包成 Slint 的模型。
/// 用 VecModel：之后刷新时能取回它逐行替换（见 sync_rows）。
fn model_of<T: Clone + 'static>(rows: Vec<T>) -> ModelRc<T> {
    ModelRc::from(Rc::new(VecModel::from(rows)))
}

/// 让模型与新的行一致。行数相同时只替换内容变了的行（其余卡片不碰，输入框与下拉框不受打扰），
/// 行数不同时整份换掉。嵌套的模型按内容比较（`same`），模型本身只能按指针比较。
fn sync_rows<T: Clone + 'static>(
    current: &ModelRc<T>,
    rows: Vec<T>,
    same: fn(&T, &T) -> bool,
    replace: impl FnOnce(ModelRc<T>),
) {
    match current.as_any().downcast_ref::<VecModel<T>>() {
        // 行数相同：大概率只是某一行的内容变了（例如加了一条热键），逐行比较，只改变了的。
        Some(vec) if vec.row_count() == rows.len() => {
            for (index, row) in rows.into_iter().enumerate() {
                if vec.row_data(index).is_none_or(|old| !same(&old, &row)) {
                    vec.set_row_data(index, row);
                }
            }
        }
        // 行数变了（新角色上线、新建或删除循环组）：整份换掉，卡片随之重建。
        _ => replace(model_of(rows)),
    }
}

/// 两个热键位置的内容相同。
/// 行（HotkeyRow）是普通结构，直接按值比较。
fn same_slot(a: &HotkeySlotData, b: &HotkeySlotData) -> bool {
    a.slot == b.slot && a.title == b.title && a.rows.iter().eq(b.rows.iter())
}

/// 两个循环组的内容相同。
/// 名称与配置里的名称都要比较：输入框里的文字也是页面状态的一部分。
fn same_group(a: &CycleGroupData, b: &CycleGroupData) -> bool {
    a.id == b.id
        && a.name == b.name
        && a.saved_name == b.saved_name
        && same_slot(&a.forward, &b.forward)
        && same_slot(&a.backward, &b.backward)
        && a.members.iter().eq(b.members.iter())
        && a.candidates.iter().eq(b.candidates.iter())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use eveo_core::hotkeys::HotkeyModifiers;

    /// 一个带循环组与直达热键的配置方案。
    /// 三个成员的循环组，前进热键 Ctrl+F13；Alpha 的直达热键里有一条与之重复，还有一条缺修饰键。
    fn sample() -> Profile {
        let mut profile = Profile::make_new("p1", "Main");
        profile.cycle_groups.push(CycleGroup {
            id: "G1".to_owned(),
            name: "Fleet".to_owned(),
            forward_hotkeys: vec!["ctrl+F13".to_owned()],
            backward_hotkeys: vec![],
            members: vec!["Alpha".to_owned(), "Bravo".to_owned(), "Charlie".to_owned()],
        });
        profile
            .character_hotkeys
            .insert("Alpha".to_owned(), vec!["ctrl+F13".to_owned(), "K".to_owned()]);
        profile
    }

    /// 位置标识来回不变；角色名里的冒号不影响解析。
    #[test]
    fn slot_keys_round_trip() {
        let slots = [
            Slot::Cycle("G1".to_owned(), CycleDirection::Forward),
            Slot::Cycle("G1".to_owned(), CycleDirection::Backward),
            Slot::Character("A:B".to_owned()),
            Slot::ToggleHideAll,
            Slot::MinimizeAll,
            Slot::CycleLoginClients,
        ];
        // 每种位置都能由标识还原，页面回调传回来的字符串不会对错位置。
        for slot in slots {
            assert_eq!(Slot::parse(&slot.key()), Some(slot));
        }
        // 未知的方向与未知的标识都解析失败，回调丢弃这次操作。
        assert_eq!(Slot::parse("group:G1:sideways"), None);
        assert_eq!(Slot::parse("nothing"), None);
    }

    /// 循环组：新建带序号的名称，空白名称不接受，成员不重复、移动不越界、删除位置越界时不动。
    #[test]
    fn group_edits() {
        let mut profile = sample();
        // 已有一个组，新建的名称序号是 2；名称按界面语言。
        crate::language::set_for_test(eveo_core::model::AppLanguage::Zh);
        apply_switching_edit(&mut profile, &SwitchingEdit::AddGroup("G2".to_owned()));
        assert_eq!(profile.cycle_groups[1].name, "循环组 2");
        let rename = |name: &str| SwitchingEdit::RenameGroup {
            id: "G2".to_owned(),
            name: name.to_owned(),
        };
        // 全是空白：保留原名；带空白的名称去掉首尾空白。
        apply_switching_edit(&mut profile, &rename("   "));
        assert_eq!(profile.cycle_groups[1].name, "循环组 2");
        apply_switching_edit(&mut profile, &rename("  Scouts "));
        assert_eq!(profile.cycle_groups[1].name, "Scouts");
        apply_switching_edit(&mut profile, &SwitchingEdit::DeleteGroup("G2".to_owned()));
        assert_eq!(profile.cycle_groups.len(), 1);

        let add = SwitchingEdit::AddMember {
            id: "G1".to_owned(),
            name: "Alpha".to_owned(),
        };
        // Alpha 已在组里：不重复添加。
        apply_switching_edit(&mut profile, &add);
        assert_eq!(profile.cycle_groups[0].members.len(), 3);
        let moving = |index, delta| SwitchingEdit::MoveMember {
            id: "G1".to_owned(),
            index,
            delta,
        };
        // Alpha 下移一位；最后一位再下移、第一位再上移都不动。
        apply_switching_edit(&mut profile, &moving(0, 1));
        apply_switching_edit(&mut profile, &moving(2, 1));
        apply_switching_edit(&mut profile, &moving(0, -1));
        assert_eq!(profile.cycle_groups[0].members, ["Bravo", "Alpha", "Charlie"]);
        let remove = |index| SwitchingEdit::RemoveMember {
            id: "G1".to_owned(),
            index,
        };
        // 越界的位置不动，正常的位置删掉。
        apply_switching_edit(&mut profile, &remove(5));
        apply_switching_edit(&mut profile, &remove(1));
        assert_eq!(profile.cycle_groups[0].members, ["Bravo", "Charlie"]);
    }

    /// 热键：新增不重复、重录保留范围、鼠标默认仅游戏内、改范围、移除；角色的空列表删掉键。
    #[test]
    fn hotkey_edits() {
        let mut profile = sample();
        // Alpha 已有 Ctrl+F13 与 K 两条直达热键。
        let slot = Slot::Character("Alpha".to_owned());
        // 0x7D 是 VK_F14。
        let f14 = Hotkey::key(0x7D, HotkeyModifiers::CONTROL);
        let recorded = |text: &str, hotkey| SwitchingEdit::Recorded {
            slot: slot.clone(),
            text: text.to_owned(),
            hotkey,
        };
        // 已有 Ctrl+F13：再录一次不追加。
        let f13 = HotkeySpec::parse("ctrl+F13").unwrap().hotkey;
        apply_switching_edit(&mut profile, &recorded("", f13));
        assert_eq!(hotkeys(&profile, &slot), ["ctrl+F13", "K"]);
        // 新录的侧键写成 @game。
        // 按钮号 3 是第一个侧键，写作 Mouse4。
        let side = Hotkey::mouse(3, HotkeyModifiers::NONE).unwrap();
        apply_switching_edit(&mut profile, &recorded("", side));
        assert_eq!(hotkeys(&profile, &slot)[2], "Mouse4@game");
        // 改范围后重录：保留改过的范围。
        apply_switching_edit(
            &mut profile,
            &SwitchingEdit::SetScope {
                slot: slot.clone(),
                text: "K".to_owned(),
                scope: Some(HotkeyScope::Global),
            },
        );
        assert_eq!(hotkeys(&profile, &slot)[1], "K@global");
        apply_switching_edit(&mut profile, &recorded("K@global", f14));
        assert_eq!(hotkeys(&profile, &slot)[1], "ctrl+F14@global");
        // 全部移除后角色的键也删掉。
        // 逐条移除；最后一条移除后，角色的键从配置里删掉，不留空数组。
        for text in hotkeys(&profile, &slot) {
            apply_switching_edit(
                &mut profile,
                &SwitchingEdit::RemoveHotkey {
                    slot: slot.clone(),
                    text,
                },
            );
        }
        assert!(!profile.character_hotkeys.contains_key("Alpha"));
        // 删掉的循环组：改动什么也不做。
        // 不存在的循环组：写入被忽略，读出为空。
        let gone = Slot::Cycle("nope".to_owned(), CycleDirection::Forward);
        set_hotkeys(&mut profile, &gone, vec!["F1".to_owned()]);
        assert!(hotkeys(&profile, &gone).is_empty());
    }

    /// 页面内容：行的界面写法与范围、问题提示（重复、缺修饰键、注册失败）与录制状态。由 bind 的 Slint 用例调用。
    pub(crate) fn check_page(ui: &SettingsWindow) {
        let profile = sample();
        let plan = eveo_core::hotkeys::planner::plan(&profile);
        let k = HotkeySpec::parse("K").unwrap().hotkey;
        // 假装 K 注册失败，核对它与「缺修饰键」同时存在时报哪一个。
        let failed = [(HotkeyAction::ActivateCharacter("Alpha".to_owned()), k)];
        let state = SwitchingState {
            clients: &[],
            plan: &plan,
            failed: &failed,
            recording: Some((Slot::ToggleHideAll, String::new())),
        };
        show_switching(ui, &profile, &state);
        let model = ui.global::<SwitchingModel>();
        // 正在给「全部隐藏」新增一条。
        assert_eq!(model.get_recording(), "toggleHideAll|");
        let groups: Vec<CycleGroupData> = model.get_groups().iter().collect();
        assert_eq!(groups.len(), 1);
        let forward: Vec<HotkeyRow> = groups[0].forward.rows.iter().collect();
        assert_eq!(forward[0].label, "Ctrl+F13");
        assert_eq!(forward[0].scope, 0);
        assert!(forward[0].problem.is_empty());
        // 候选：组里已有三个成员，已知角色也只有这三个，只剩提示文字。
        assert_eq!(groups[0].candidates.row_count(), 1);
        let characters: Vec<HotkeySlotData> = model.get_characters().iter().collect();
        let alpha = characters.iter().find(|c| c.title == "Alpha").unwrap();
        let rows: Vec<HotkeyRow> = alpha.rows.iter().collect();
        // Alpha 的 Ctrl+F13 与循环组的前进重复（循环组先出现，先生效）。
        // 界面语言是默认的英文。
        assert!(rows[0].problem.contains("Fleet · Forward"), "{}", rows[0].problem);
        // 单独的 K 缺修饰键，被拒绝；拒绝的提示优先于注册失败。
        assert!(rows[1].problem.contains("modifier"), "{}", rows[1].problem);
        assert_eq!(model.get_general().row_count(), 3);

        // 改名中的输入框：配置里的名称没变时，刷新保留输入。
        let current = model.get_groups();
        // 模拟用户在名称输入框里删掉了几个字（双向绑定写回模型的效果）。
        let mut group = current.row_data(0).unwrap();
        group.name = "Fle".into();
        current.set_row_data(0, group);
        show_switching(ui, &profile, &state);
        assert_eq!(model.get_groups().row_data(0).unwrap().name, "Fle");
    }
}
