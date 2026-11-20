// SPDX-License-Identifier: GPL-3.0-or-later
//
// EVE-O Preview 应用入口（架构文档 7.1 节）。
// 建 NSApplication，设 AppDelegate，激活策略为 .accessory（只有菜单栏图标，没有 Dock 图标）。
// 发布包的 Info.plist 同时写了 LSUIElement；用 `swift run` 运行时没有 Info.plist，靠这里的设置。

import AppKit

MainActor.assumeIsolated {
    // 先建 NSApplication：它向系统登记本进程，旧实例的 openApplication 回调要等登记完成才返回，
    // 旧实例收到回调后才开始退出。如果在这之前就等旧实例退出，两边会互相等到超时。
    let app = NSApplication.shared
    // 「重新启动」打开的新实例先等旧实例退出（见 InstanceGuard）。
    let previousInstance = InstanceGuard.waitForPreviousInstance()
    // 同一 bundle id 的实例已在运行时退出自己。`swift run` 时没有 bundle id，跳过检查。
    if InstanceGuard.anotherInstanceIsRunning(excluding: previousInstance) {
        AppLog.logger("App").info("已有实例在运行，退出")
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
