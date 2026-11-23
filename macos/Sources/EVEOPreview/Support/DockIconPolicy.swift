// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dock 图标的开关（v1.1 设计第 19 节）：`general.showDockIcon` 为真时激活策略用 `.regular`，
// 应用出现在 Dock 与 Cmd+Tab 里；为假时用 `.accessory`，只有菜单栏图标。
//
// Info.plist 仍写 LSUIElement，进程以 `.accessory` 启动，读完配置后才切到 `.regular`。
// 这样关掉开关的用户启动时 Dock 里不会闪一下图标；打开开关的用户图标晚出现片刻。
// 切换时应用可能失去激活，设置窗口会退到其他应用后面，所以原来有前台窗口时重新激活并放回最前。

import AppKit

/// 按配置设置激活策略。
@MainActor
enum DockIconPolicy {
    /// 开关对应的激活策略。
    static func policy(showDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showDockIcon ? .regular : .accessory
    }

    /// 按开关设置激活策略；策略没变时什么也不做。
    ///
    /// - Parameter showDockIcon: 是否在 Dock 里显示图标。
    static func apply(showDockIcon: Bool) {
        let target = policy(showDockIcon: showDockIcon)
        guard NSApp.activationPolicy() != target else { return }
        // 记下切换前的前台窗口：只有它存在时才需要放回最前。
        let keyWindow = NSApp.isActive ? NSApp.keyWindow : nil
        NSApp.setActivationPolicy(target)
        AppLog.logger("App").info("Dock 图标：\(showDockIcon ? "显示" : "不显示", privacy: .public)")
        guard let keyWindow else { return }
        // 等这一轮事件处理完再激活：策略切换在系统那边是异步生效的，立即激活有时不起作用。
        DispatchQueue.main.async {
            NSApp.activate()
            keyWindow.makeKeyAndOrderFront(nil)
        }
    }
}
