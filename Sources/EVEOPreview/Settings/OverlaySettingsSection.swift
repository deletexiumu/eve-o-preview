// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页与「翻译」页共用的浮窗设置（docs/design-intel-translate.md 第 10 节）：背景不透明度（0.2～1.0，
// 步长 0.05）、字号（10～24）、「恢复默认位置」按钮与手势说明。
// WP-0 的骨架：只有签名，不显示任何控件。实现与文字（L10n.overlay）归 WP-A。

import SwiftUI
import EVEOPreviewCore

/// 浮窗设置的一组控件。
struct OverlaySettingsSection: View {
    /// 绑定的浮窗设置（intel.overlay 或 translation.overlay）。
    @Binding var settings: OverlayPanelSettings

    /// 用绑定建这一组控件。
    init(settings: Binding<OverlayPanelSettings>) {
        _settings = settings
    }

    var body: some View {
        EmptyView()
    }
}
