// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的中文文字（反馈文档 5.3 节、7.11 节）。用词按 5.5 节的词表与 13 节的术语：
// 战斗提醒、游戏日志、缩略图、受击、闪烁；系统权限用 macOS 中文界面的官方名称「文件与文件夹」。

import Foundation

/// 「提醒」页的中文文字。
struct CombatStringsZH: CombatStrings {
    // MARK: 页头
    var pageSubtitle: String { "角色被攻击时，让它的缩略图闪烁。" }

    // MARK: 开关与状态行
    var enableToggle: String { "角色被攻击时闪烁缩略图" }
    var statusLabel: String { "状态" }
    var statusStopped: String { "未启用" }
    func statusWatching(directory: String, files: Int) -> String { "监视中：\(directory)，跟踪 \(files) 个日志文件" }
    func statusDirectoryNotFound(_ path: String) -> String { "找不到游戏日志目录：\(path)" }
    func statusAccessDenied(_ path: String) -> String { "没有读取权限：\(path)" }
    var accessDeniedHelp: String {
        "请在「系统设置 > 隐私与安全性 > 文件与文件夹」里允许 EVE-O Preview 访问「文稿」文件夹。"
    }
    var openSystemSettings: String { "打开系统设置…" }

    // MARK: 日志目录
    var logDirectoryHeader: String { "游戏日志" }
    var logDirectoryLabel: String { "目录" }
    var automaticSuffix: String { "（自动）" }
    var chooseDirectory: String { "选择…" }
    var useAutomaticLocation: String { "使用自动位置" }
    var chooseDirectoryMessage: String { "选择 EVE 的 logs 或 Gamelogs 文件夹。" }

    // MARK: 闪烁的外观
    var appearanceHeader: String { "闪烁" }
    var flashColor: String { "闪烁颜色" }
    var duration: String { "持续时间" }
    func seconds(_ value: Double) -> String { "\(combatSecondsNumber(value)) 秒" }
    var style: String { "样式" }
    var styleBorder: String { "边框" }
    var styleWash: String { "底色" }
    var styleBoth: String { "两者" }

    // MARK: 触发条件
    var triggersHeader: String { "触发条件" }
    var includeMisses: String { "未命中的攻击也提醒" }
    var minimumDamage: String { "最小伤害" }
    var minimumDamageHelp: String { "低于这个数值的伤害不提醒。未命中按上面的开关处理。" }

    // MARK: 测试与说明
    var testFlash: String { "测试闪烁" }
    var testFlashHelp: String { "让全部缩略图闪烁一次，功能关闭时也可以用。" }
    var footnote: String {
        "EVE 客户端应开启把游戏消息写入日志文件的设置。本功能只读游戏日志，不向游戏发送任何输入。"
    }
}
