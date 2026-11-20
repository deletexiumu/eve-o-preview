// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的界面语言部分（反馈文档 5.4 节）。configDidChange 每次都调用 languageSettingDidChange。
// general.language 变了时，按新选项求出界面语言并设置；语言确实变了才通知界面刷新：
// - onLanguageChanged（AppDelegate 设置）重设设置窗口的标题、重建主菜单；
// - setNeedsReplan() 让缩略图的占位文字按新语言重设。
// 设置窗口的页内容不在这里处理：SettingsRootView 以 general.language 为身份，配置一变就重建。
// 菜单栏菜单与缩略图右键菜单每次打开时新建，也不用处理。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 配置变化后调用，参数是变化前后的完整配置。只在 `general.language` 变了时动作。
    ///
    /// 选项变了而界面语言没变（如从 `en` 改成「跟随系统」，系统语言恰好是英文），不通知刷新。
    func languageSettingDidChange(old: AppConfig, new: AppConfig) {
        guard old.general.language != new.general.language else { return }
        let language = L10n.resolve(new.general.language)
        guard L10n.setLanguage(language) else { return }
        log.info("界面语言切换为 \(language.rawValue, privacy: .public)")
        onLanguageChanged?()
        setNeedsReplan()
    }
}
