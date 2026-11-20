// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的界面文字（反馈文档 5.3 节）：「切换与热键」页、录制器、热键问题提示、作用范围，
// 以及菜单栏菜单里「热键只在 EVE 内生效」一项。
// 每种语言在 Localization/<语言>/HotkeyStrings+<语言>.swift 里各有一个结构体实现本协议；
// 漏了一条时结构体不满足协议，编译不过。带参数的文字写成函数，各语言自己拼接，不用格式串。
// 用词按反馈文档 5.5 节的词表；「作用范围」「全局」「仅游戏内」按第 13 节的术语。

import Foundation

/// 热键域的全部文字。
protocol HotkeyStrings: Sendable {
    // MARK: 切换与热键页：页首与循环组

    /// 页首的副标题。
    var switchingSubtitle: String { get }
    /// 循环组一节的标签。
    var cycleGroupsHeader: String { get }
    /// 「新建循环组」按钮。
    var addGroup: String { get }
    /// 没有循环组时的说明。
    var noGroups: String { get }
    /// 循环组名称一行的标签与占位文字。
    var groupName: String { get }
    /// 「删除循环组」按钮。
    var deleteGroup: String { get }
    /// 前进热键一行的标签。
    var forwardHotkeys: String { get }
    /// 后退热键一行的标签。
    var backwardHotkeys: String { get }
    /// 循环组没有成员时的说明。
    var noMembers: String { get }
    /// 「添加成员」菜单。
    var addMember: String { get }
    /// 新循环组的默认名称，参数是序号。
    func newGroupName(_ index: Int) -> String

    // MARK: 切换与热键页：角色热键与通用热键

    /// 角色直达热键一节的标题。
    var characterHotkeysHeader: String { get }
    /// 全部隐藏、全部最小化、登录客户端循环三项所在一节的标题。
    var globalHotkeysHeader: String { get }
    /// 「显示或隐藏全部缩略图」一行的标签。
    var hotkeyToggleHideAll: String { get }
    /// 「全部最小化」一行的标签。
    var hotkeyMinimizeAll: String { get }
    /// 「登录客户端之间循环」一行的标签。
    var hotkeyCycleLogin: String { get }
    /// 热键规则的说明：键盘热键的修饰键要求，鼠标按键可以单独使用、触发时点击不传给游戏。
    var hotkeyRulesHint: String { get }
    /// 鼠标热键的说明：需要辅助功能权限，全局范围的鼠标热键在所有应用里吞掉按键，先取消别处的绑定。
    var mouseHotkeyHint: String { get }

    // MARK: 作用范围

    /// 页首「热键的默认作用范围」一行的标签。
    var defaultScopeLabel: String { get }
    /// 作用范围 global 的名称。
    var scopeGlobal: String { get }
    /// 作用范围 game 的名称。
    var scopeGame: String { get }
    /// 每行作用范围菜单的第 1 项「跟随默认」，参数是当前默认范围的名称。
    func scopeFollowDefault(_ current: String) -> String
    /// 作用范围菜单的提示文字，参数是这一行已解析的作用范围名称。
    func scopeMenuHelp(_ resolved: String) -> String
    /// 菜单栏菜单的一项：勾选时当前配置方案的默认作用范围是 game。
    var menuHotkeysOnlyInEVE: String { get }

    // MARK: 录制器

    /// 「添加」按钮。
    var addHotkey: String { get }
    /// 录制中按钮上的提示。
    var recordingPrompt: String { get }
    /// 录制按钮的提示文字。
    var recorderHelp: String { get }
    /// 删除按钮的提示文字。
    var removeHotkey: String { get }

    // MARK: 热键问题（显示在热键按钮左侧的同一行里，要短）

    /// 字符串无法解析。
    var hotkeyUnparsable: String { get }
    /// 键盘热键缺修饰键。
    var hotkeyMissingModifier: String { get }
    /// 系统保留的组合。
    var hotkeyReserved: String { get }
    /// 鼠标热键：没有辅助功能权限。
    var hotkeyAccessibilityRequired: String { get }
    /// 鼠标热键：有权限，但系统没有建出事件监听。
    var hotkeyEventTapUnavailable: String { get }
    /// 与另一个动作重复，参数是那个动作的名称。
    func hotkeyDuplicate(_ other: String) -> String
    /// Carbon 注册失败，参数是错误码。
    func hotkeyRegistrationFailed(_ status: Int32) -> String
}

extension L10n {
    /// 热键域的文字，按当前界面语言取。每次访问都重新取，切换语言后下次访问即是新语言。
    ///
    /// `switch` 不写 `default`：以后加语言时编译器会指出这里要补。
    static var hotkeys: any HotkeyStrings {
        switch L10n.language {
        case .en: return HotkeyStringsEN()
        case .zh: return HotkeyStringsZH()
        case .ru: return HotkeyStringsRU()
        case .ja: return HotkeyStringsJA()
        case .ko: return HotkeyStringsKO()
        }
    }
}
