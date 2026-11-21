// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「翻译」页（docs/design-intel-translate.md 第 10 节）。
// WP-0 的骨架：只有页标题。开关、频道列表、目标语言、模型服务、API Key、测试、浮窗与缓存归 WP-C；
// 页内文字属于翻译域 L10n.translation（WP-C），页名取 L10n.settings.pageTranslation。
// 位置、核对与翻译的状态不是视图模型的存储属性，SwiftUI 观察不到：WP-C 的页面应在 body 里读一次
// `model.chatRevision`，两个功能的状态变化时页面随之重绘。

import SwiftUI

/// 「翻译」页。
struct TranslationPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                EmptyView()
            } header: {
                PageHeader(title: L10n.settings.pageTranslation)
            }
        }
        .formStyle(.grouped)
    }
}
