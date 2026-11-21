// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「预警」页（docs/design-intel-translate.md 第 10 节）。
// WP-0 的骨架：只有页标题。开关、频道列表、我的位置、参考星系、显示设置与浮窗设置归 WP-B；
// 页内文字属于预警域 L10n.intel（WP-B），页名取 L10n.settings.pageIntel。
// 位置、核对与翻译的状态不是视图模型的存储属性，SwiftUI 观察不到：WP-B 的页面应在 body 里读一次
// `model.chatRevision`，两个功能的状态变化时页面随之重绘。

import SwiftUI

/// 「预警」页。
struct IntelPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                EmptyView()
            } header: {
                PageHeader(title: L10n.settings.pageIntel)
            }
        }
        .formStyle(.grouped)
    }
}
