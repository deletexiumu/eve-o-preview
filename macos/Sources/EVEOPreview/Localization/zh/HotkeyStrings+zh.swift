// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的中文文字。沿用 v1 的中文，新增的是鼠标热键与作用范围的文字（反馈文档 6.8 节）。
// 「全局热键」一节改称「通用热键」：「全局」已用作作用范围的名称，避免同一个词两个意思。
// 默认作用范围一行按第 13 节的术语写「作用范围」，不写 6.8 节草稿里的「生效范围」。

import Foundation

/// 热键域的中文实现。
struct HotkeyStringsZH: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String { "循环组与热键。每个热键只按一种范围生效：全局（包括游戏内）或仅游戏内。" }
    var cycleGroupsHeader: String { "循环组" }
    var addGroup: String { "新建循环组" }
    var noGroups: String { "还没有循环组。" }
    var groupName: String { "名称" }
    var deleteGroup: String { "删除循环组" }
    var forwardHotkeys: String { "前进热键" }
    var backwardHotkeys: String { "后退热键" }
    var noMembers: String { "还没有成员。" }
    var addMember: String { "添加成员" }
    func newGroupName(_ index: Int) -> String { "循环组 \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "角色直达热键" }
    var globalHotkeysHeader: String { "通用热键" }
    var hotkeyToggleHideAll: String { "显示或隐藏全部缩略图" }
    var hotkeyMinimizeAll: String { "全部最小化" }
    var hotkeyCycleLogin: String { "登录客户端之间循环" }
    var hotkeyRulesHint: String {
        "键盘热键应包含 Ctrl、Option 或 Command 之一，F1～F20 与小键盘数字可以单独使用；"
            + "鼠标的中键与侧键可以单独使用，触发时这次点击不会传给游戏。"
    }
    var mouseHotkeyHint: String {
        "鼠标热键需要辅助功能权限。作用范围是全局的鼠标热键会在所有应用里吞掉这个按键。"
            + "请先在游戏或鼠标软件里取消这个按键的其他绑定。"
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "热键的默认生效范围" }
    var scopeGlobal: String { "全局" }
    var scopeGame: String { "仅游戏内" }
    var scopeGlobalOption: String { "全局：在任何应用里都生效（包括游戏内）" }
    var scopeGameOption: String { "仅游戏内：只在 EVE 窗口位于前台时生效" }
    var defaultScopeFooter: String { "每个热键只按一种范围生效，不会两种同时生效。热键右侧的标记显示它实际的范围，点它可以把这一个热键单独改为全局、仅游戏内，或跟随这里的默认。" }
    func scopeFollowDefault(_ current: String) -> String { "跟随默认（当前：\(current)）" }
    func scopeMenuHelp(_ resolved: String) -> String { "生效范围：\(resolved)。点击可单独修改这个热键。" }
    var menuHotkeysOnlyInEVE: String { "热键只在 EVE 内生效" }

    // MARK: 录制器

    var addHotkey: String { "+ 添加" }
    var recordingPrompt: String { "按下组合键或鼠标侧键（指针停在本窗口内）…" }
    var recorderHelp: String { "点击后按下组合键，或鼠标的中键、侧键；Esc 取消，Delete 清除。" }
    var removeHotkey: String { "删除这个热键" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "无法识别" }
    var hotkeyMissingModifier: String { "缺少修饰键" }
    var hotkeyReserved: String { "系统保留" }
    var hotkeyAccessibilityRequired: String { "需要辅助功能权限" }
    var hotkeyEventTapUnavailable: String { "无法监听鼠标" }
    func hotkeyDuplicate(_ other: String) -> String { "与「\(other)」重复，未生效" }
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "注册失败（\(status)）" }
}
