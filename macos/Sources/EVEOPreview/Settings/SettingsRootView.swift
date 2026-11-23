// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的根视图（架构文档 7.4 节）：左侧是 10 个页的列表，右侧是当前页。
// 两栏用 HStack 排列，原因见 body 里的说明。
// 配置读取有问题或处于演示模式时，在页的上方显示提示条。
// 界面语言变了以后整个视图树按新的语言键重建（反馈文档 5.4 节），见 body 末尾的 `.id`。

import SwiftUI

/// 设置窗口的根视图。
struct SettingsRootView: View {
    /// 视图模型。
    @Bindable var model: SettingsViewModel

    var body: some View {
        // 不用 NavigationSplitView：它在 AppKit 里是 NSSplitView 的包装，放进 NSHostingController 后
        // 按内容的高度定自己的高度（实测 About 页时高 1318 点，窗口内容区只有 620 点），再居中放置，
        // 结果两栏的上半部分都在窗口外：侧栏看起来是空的，页面顶部被裁掉。
        // 普通 HStack 按窗口给的尺寸布局，页内容（grouped 样式的 Form）在自己的滚动视图里滚动。
        HStack(spacing: 0) {
            // 侧栏：10 个页，顺序见 SettingsPage 的说明（docs/design-intel-translate.md 第 10 节）。
            List(SettingsPage.allCases, selection: selection) { page in
                Label(page.title, systemImage: page.systemImage).tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: SettingsRootView.sidebarWidth)
            Divider()
            // 右侧：提示条在上，页内容在下，页内容自己滚动。
            VStack(spacing: 0) {
                notices
                pageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 文字取自 L10n，SwiftUI 观察不到它的变化；语言选项变了就换一个身份，强制重建整棵视图树。
        // 键挂在根上而不只是内容区：侧栏的页名称与演示模式的提示条也要换语言。
        // 选中的页存在视图模型里，重建后不变；录制到一半的热键由 HotkeyRecorderView 的 onDisappear 取消。
        .id(model.config.general.language)
    }

    /// 侧栏宽度，单位是点。最长的页名（中文「切换与热键」、英文「Switching & Hotkeys」）加图标能放下。
    static let sidebarWidth: CGFloat = 200

    /// 列表的选中项。List 的单选要求可选值，这里把 nil 视为不变。
    private var selection: Binding<SettingsPage?> {
        Binding(get: { model.page }, set: { page in
            if let page { model.page = page }
        })
    }

    /// 页上方的提示条：配置读取问题、演示模式。
    @ViewBuilder private var notices: some View {
        if let notice = model.configNotice {
            NoticeBanner(text: notice).padding([.horizontal, .top])
        }
        // 演示模式下明确告诉用户：这里的切换与最小化不影响真实窗口。
        if model.isFakeMode {
            NoticeBanner(text: L10n.settings.fakeModeNotice, systemImage: "theatermasks.fill", tint: .blue)
                .padding([.horizontal, .top])
        }
    }

    /// 当前页的内容。
    @ViewBuilder private var pageContent: some View {
        // 每个页只拿视图模型；页之间没有直接依赖。
        switch model.page {
        case .clients: ClientsPage(model: model)
        case .previews: PreviewsPage(model: model)
        case .switching: SwitchingPage(model: model)
        case .alerts: AlertsPage(model: model)
        case .intel: IntelPage(model: model)
        case .translation: TranslationPage(model: model)
        case .profiles: ProfilesPage(model: model)
        case .general: GeneralPage(model: model)
        case .permissions: PermissionsPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

extension SettingsPage {
    /// 页名称。
    var title: String {
        switch self {
        case .clients: return L10n.settings.pageClients
        case .previews: return L10n.settings.pagePreviews
        case .switching: return L10n.settings.pageSwitching
        case .alerts: return L10n.settings.pageAlerts
        case .intel: return L10n.settings.pageIntel
        case .translation: return L10n.settings.pageTranslation
        case .profiles: return L10n.settings.pageProfiles
        case .general: return L10n.settings.pageGeneral
        case .permissions: return L10n.settings.pagePermissions
        case .about: return L10n.settings.pageAbout
        }
    }

    /// 页图标（SF Symbols 名称）。
    var systemImage: String {
        switch self {
        case .clients: return "person.2"
        case .previews: return "rectangle.3.group"
        case .switching: return "keyboard"
        case .alerts: return "bell.badge"
        case .intel: return "dot.radiowaves.left.and.right"
        case .translation: return "character.bubble"
        case .profiles: return "square.stack.3d.up"
        case .general: return "gearshape"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}
