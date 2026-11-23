// SPDX-License-Identifier: GPL-3.0-or-later
//
// 循环组与全局热键的配置模型，对应 macOS 的 Model/CycleGroup.swift（架构文档 5.2 节）。
// 热键以字符串保存，解析失败的字符串原样保留，由设置窗口报告。

config_struct! {
    /// 一个循环组：一组有顺序的角色，配前进与后退热键。
    pub struct CycleGroup via CycleGroupRaw {
        /// 循环组的 id（UUID 字符串），在一个配置方案内唯一；缺失时为空串，由校验补上。
        req id: String = String::new(), "id";
        /// 显示名称。
        req name: String = String::new(), "name";
        /// 前进热键，每项是一条热键字符串，如 `ctrl+F13`。
        req forward_hotkeys: Vec<String> = Vec::new(), "forwardHotkeys";
        /// 后退热键，每项是一条热键字符串。
        req backward_hotkeys: Vec<String> = Vec::new(), "backwardHotkeys";
        /// 成员角色名，按循环顺序。重复项由校验去掉，只保留第一次出现的位置。
        req members: Vec<String> = Vec::new(), "members";
    }
}

/// 「全部隐藏」的默认热键：三个修饰键一起按不容易误触，明确写成全局生效。
///
/// macOS 写作 ⌃⌥⌘H；Windows 版的写法随 M2c 的热键解析确定（`cmd` 对应 `win`，见架构文档 5.5 节）。
pub const DEFAULT_TOGGLE_HIDE_ALL: &str = "ctrl+opt+cmd+H@global";

config_struct! {
    /// 与循环组无关的全局热键，每项都是热键字符串数组，可以绑定多个组合。
    pub struct GeneralHotkeys via GeneralHotkeysRaw {
        /// 切换「全部隐藏」。
        req toggle_hide_all: Vec<String> = Vec::new(), "toggleHideAll";
        /// 最小化全部客户端。
        req minimize_all: Vec<String> = Vec::new(), "minimizeAll";
        /// 在登录客户端之间循环（按 PID 升序）。
        req cycle_login_clients: Vec<String> = Vec::new(), "cycleLoginClients";
    }
}

impl GeneralHotkeys {
    /// 新建配置方案时使用的全局热键：只给「全部隐藏」绑定默认热键，其余不绑定。
    ///
    /// 与 `default()` 的「都不绑定」分开：解码缺键、手工构造时仍是空列表，只有新建的方案带默认值。
    pub fn new_profile_defaults() -> Self {
        Self {
            toggle_hide_all: vec![DEFAULT_TOGGLE_HIDE_ALL.to_owned()],
            ..Self::default()
        }
    }
}
