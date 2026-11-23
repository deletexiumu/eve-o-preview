// SPDX-License-Identifier: GPL-3.0-or-later
//
// EVEOProbe：在真实 EVE 客户端上验证平台层的命令行探针（架构文档 6.7 节）。
// 从终端运行，权限记在终端应用名下。探针允许用 print 输出到终端（架构文档第 8 节的例外）。
//
// 命令：
//   list                                   候选窗口、主窗口、身份、前台与 V8 的比较
//   activate <pid> [--only 手段] [--restore] 走一遍 6.4 节的步骤，打印每一步的结果和耗时
//   bench <轮数> [--only 手段]              在全部客户端间轮流激活，统计成功率，最后还原原来的前台应用
//   minimize <pid> [保持秒数]               最小化，保持若干秒（默认 2）后再激活还原
//   capture <windowID> <秒数> --out 路径 [--width 像素] [--fps 帧率] [--watchdog]
//                                          起一条流，每秒打印帧数与各状态计数，结束时把最后一帧存成 PNG
//   reconcile <windowID>                   按脚本走一遍对账：改规格、隐藏到停流、恢复、窗口消失
//   hotkey [秒数]                          注册 ctrl+shift+F13 与 opt+F13，打印触发记录（默认 15 秒）
//   mousetap [秒数] [--swallow 按钮号]      建鼠标事件监听，打印中键与侧键事件（反馈文档 6.9 节，MouseTapProbe.swift）
//   gamelog [目录] [--follow 秒数]          游戏日志目录的解析统计，可跟踪新增内容（反馈文档 7.12 节，GameLogProbe.swift）
//   update feed [地址] | verify <新应用> <基准应用> | prepare <地址>
//                                          更新的检查、签名核对与下载（v1.1 设计 9.6 节，UpdateProbe.swift）
//   staticdata                             星图数据的来源、版本、数量与耗时（docs/design-intel-translate.md 9.5 节）
//   chatlog [目录] [--follow 秒数]          聊天日志目录的解析统计（WP-A，ChatLogProbe.swift）
//   intel [目录]                           预警解析的统计（WP-B，IntelProbe.swift）
//   translate [--provider …] [--model …] [--base-url …] [--target …]
//                                          向模型服务发一次测试请求（WP-C，TranslateProbe.swift；会产生费用）
// 「手段」用逗号分隔：appkit、ax、private，例如 --only appkit,ax。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 探针的共用对象与工具函数。
@MainActor enum Probe {
    /// 共用的 AX 执行者与观察者，与 `PlatformServices.makeLive()` 的组装方式相同。
    static let ax = AXWorker()
    static let workspace = SystemWorkspaceObserver()
    static let windows = CGWindowProvider(ax: ax)

    /// 解析命令并执行，返回进程退出码。
    static func run(_ arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        switch command {
        case "list": return await list()
        case "activate": return await activate(rest)
        case "bench": return await bench(rest)
        case "minimize": return await minimize(rest)
        case "capture": return await CaptureProbe.run(rest)
        case "reconcile": return await CaptureProbe.reconcileScript(rest)
        case "hotkey": return await hotkey(rest)
        case "mousetap": return await MouseTapProbe.run(rest)
        case "gamelog": return await GameLogProbe.run(rest)
        case "update": return await UpdateProbe.run(rest)
        case "staticdata": return await StaticDataProbe.run(rest)
        case "chatlog": return await ChatLogProbe.run(rest)
        case "intel": return await IntelProbe.run(rest)
        case "translate": return await TranslateProbe.run(rest)
        default: return usage()
        }
    }

    /// 打印用法，返回退出码 2。
    static func usage() -> Int32 {
        print("""
        用法：EVEOProbe list | activate <pid> [--only appkit,ax,private] | bench <轮数> [--only …]
              | minimize <pid> [保持秒数] | capture <windowID> <秒数> --out 路径 [--width 像素] [--fps 帧率] [--watchdog]
              | reconcile <windowID> | hotkey [秒数] | mousetap [秒数] [--swallow 按钮号]
              | gamelog [目录] [--follow 秒数]
              | update feed [地址] | update verify <新应用> <基准应用> | update prepare <地址>
              | staticdata | chatlog [目录] [--follow 秒数] | intel [目录]
              | translate [--provider 编号] [--model 模型] [--base-url 地址] [--target 语言]
        """)
        return 2
    }

    // MARK: - list

    /// 打印候选窗口、选出的主窗口、解析出的身份、当前前台。
    static func list() async -> Int32 {
        let permissions = SystemPermissionService().status()
        print("权限：屏幕录制 \(permissions.screenRecording)，辅助功能 \(permissions.accessibility)")
        let started = ContinuousClock.now
        let candidates = await windows.candidateWindows()
        print("候选窗口 \(candidates.count) 个，耗时 \(milliseconds(since: started)) 毫秒")
        for window in candidates {
            print("  wid \(window.windowID.rawValue) pid \(window.pid) \(describe(window.frame)) "
                  + "onScreen \(window.isOnScreen) minimized \(String(describing: window.isMinimized)) "
                  + "title \(window.title ?? "nil")")
        }
        let mains = ClientWindowSelector.mainWindows(from: candidates)
        print("主窗口 \(mains.count) 个：")
        for window in mains {
            print("  wid \(window.windowID.rawValue) pid \(window.pid) 身份 \(TitleParser.identity(fromTitle: window.title))")
        }
        await printFrontmost(pids: mains.map(\.pid))
        // 第二次调用测热路径的耗时：App 每秒轮询一次，看的是这个数。
        let warm = ContinuousClock.now
        _ = await windows.candidateWindows()
        print("第二次 candidateWindows 耗时 \(milliseconds(since: warm)) 毫秒")
        // 拆开看耗时：CGWindowList 一次，AX 每个进程一次。
        let cgStart = ContinuousClock.now
        _ = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
        print("  其中 CGWindowListCopyWindowInfo 约 \(milliseconds(since: cgStart)) 毫秒")
        for pid in mains.map(\.pid) {
            let axStart = ContinuousClock.now
            _ = await ax.windowStates(pid: pid)
            print("  AX windowStates pid \(pid) 约 \(milliseconds(since: axStart)) 毫秒")
        }
        for screen in workspace.screens() {
            print("屏幕 frame \(describe(screen.frame)) visibleFrame \(describe(screen.visibleFrame)) "
                  + "scale \(screen.scale) isMain \(screen.isMain)")
        }
        let live = PlatformServices.makeLive()
        print("makeLive()：\(type(of: live.windows))、\(type(of: live.workspace))、\(type(of: live.activator))、"
              + "\(type(of: live.hotkeys))、\(type(of: live.permissions))、\(type(of: live.capture))")
        return 0
    }

    /// 打印前台判断与 V8 的三种办法的比较：对象相等、AX 的 frontmost 属性、CG 屏上窗口的叠放顺序。
    static func printFrontmost(pids: [Int32]) async {
        let front = NSWorkspace.shared.frontmostApplication
        print("frontmostApplication：\(front?.bundleIdentifier ?? "nil") pid \(front?.processIdentifier ?? 0)"
              + "；最上层 layer 0 窗口的 PID \(topmostWindowOwner().map(String.init) ?? "nil")")
        print("frontmost(among:) = \(workspace.frontmost(among: pids))")
        for pid in pids {
            let byEquality = NSRunningApplication(processIdentifier: pid).map { $0 == front } ?? false
            let byAX = await ax.isFrontmost(pid: pid)
            print("  pid \(pid)：== frontmostApplication \(byEquality)，AX frontmost \(String(describing: byAX))")
        }
    }

    /// 屏上最上层的 layer 0 窗口所属的 PID。3 个客户端叠在同一位置，叠放顺序就是真实的前台。
    static func topmostWindowOwner() -> Int32? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let entry = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        return (entry?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    /// 三种前台信号的一行摘要：`==`、AX、CG 叠放顺序是否都指向 pid。
    static func frontSignals(pid: Int32) async -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let byEquality = NSRunningApplication(processIdentifier: pid).map { $0 == front } ?? false
        let byAX = await ax.isFrontmost(pid: pid)
        let byCG = topmostWindowOwner() == pid
        return "==:\(byEquality) AX:\(byAX.map(String.init) ?? "nil") CG:\(byCG)"
    }

    // MARK: - activate / bench

    /// 解析 `--only` 参数；没有时返回全部手段。
    static func mechanisms(from args: [String]) -> SystemWindowActivator.Mechanisms {
        guard let index = args.firstIndex(of: "--only"), index + 1 < args.count else { return .all }
        var result: SystemWindowActivator.Mechanisms = []
        for name in args[index + 1].split(separator: ",") {
            switch name {
            case "appkit": result.insert(.appKit)
            case "ax": result.insert(.accessibility)
            case "private": result.insert(.privateFallback)
            default: print("未知手段 \(name)，忽略")
            }
        }
        return result
    }

    /// 按 PID 找客户端的主窗口，组成激活目标。
    static func target(pid: Int32) async -> ClientTarget? {
        let mains = ClientWindowSelector.mainWindows(from: await windows.candidateWindows())
        return mains.first { $0.pid == pid }.map { EVEClient(window: $0).target }
    }

    /// 激活一次并打印每一步。
    static func activate(_ args: [String]) async -> Int32 {
        guard let pid = args.first.flatMap(Int32.init) else { return usage() }
        guard let target = await target(pid: pid) else {
            print("找不到 pid \(pid) 的主窗口")
            return 1
        }
        let original = await originalFrontmost()
        // 打印工作区事件，核对 PID 为 -1 的 EVE 应用是否也触发 didActivateApplicationNotification。
        let eventStart = ContinuousClock.now
        workspace.start { event in
            print("  事件 \(event)，第 \(milliseconds(since: eventStart)) 毫秒")
        }
        let activator = SystemWindowActivator(ax: ax, workspace: workspace, mechanisms: mechanisms(from: args))
        let started = ContinuousClock.now
        let outcome = await activator.activate(target)
        print("结果：\(outcome)，总耗时 \(milliseconds(since: started)) 毫秒")
        for entry in activator.lastTrace {
            print(String(format: "  %7.1f ms  %@  %@", entry.elapsedMilliseconds, entry.step, entry.detail))
        }
        try? await Task.sleep(for: .milliseconds(300))
        print("300 毫秒后：")
        await printFrontmost(pids: [pid])
        if args.contains("--restore") { await restore(original) }
        return 0
    }

    /// 在全部客户端间轮流激活 rounds 轮，统计成功率与到前台的耗时，最后还原原来的前台应用。
    static func bench(_ args: [String]) async -> Int32 {
        guard let rounds = args.first.flatMap(Int.init), rounds > 0 else { return usage() }
        let mains = ClientWindowSelector.mainWindows(from: await windows.candidateWindows())
        guard !mains.isEmpty else { return 1 }
        let original = await originalFrontmost()
        let activator = SystemWindowActivator(ax: ax, workspace: workspace, mechanisms: mechanisms(from: args))
        var tally: [String: Int] = [:]
        var times: [Double] = []
        for round in 0..<rounds {
            let target = EVEClient(window: mains[round % mains.count]).target
            let started = ContinuousClock.now
            let outcome = await activator.activate(target)
            let elapsed = milliseconds(since: started)
            let steps = activator.lastTrace.map(\.step).joined(separator: ">")
            let immediate = await frontSignals(pid: target.pid)
            try? await Task.sleep(for: .milliseconds(500))
            let late = await frontSignals(pid: target.pid)
            print("第 \(round + 1) 次 pid \(target.pid)：\(outcome)，\(elapsed) 毫秒，步骤 \(steps)；"
                  + "结束时 [\(immediate)]，500 毫秒后 [\(late)]")
            tally["\(outcome)", default: 0] += 1
            times.append(elapsed)
        }
        print("汇总：\(tally)；耗时 最小 \(times.min() ?? 0) 中位 \(times.sorted()[times.count / 2]) 最大 \(times.max() ?? 0) 毫秒")
        await restore(original)
        return 0
    }

    /// 记下测试前的前台进程 PID。EVE 的 processIdentifier 是 -1（E5），所以客户端在前台时按客户端的 PID 记。
    static func originalFrontmost() async -> Int32? {
        let pids = Set(await windows.candidateWindows().map(\.pid)).sorted()
        let front = NSWorkspace.shared.frontmostApplication
        let result: Int32?
        if case .client(let pid) = workspace.frontmost(among: pids) {
            result = pid
        } else {
            let pid = front?.processIdentifier ?? -1
            result = pid > 0 ? pid : nil
        }
        print("测试前的前台：\(front?.bundleIdentifier ?? "nil") → pid \(result.map(String.init) ?? "nil")")
        return result
    }

    /// 把前台还给测试前的进程。只用 AppKit 与私有接口，不用 AX：AX 会提升或还原对方的窗口，改动用户的桌面。
    static func restore(_ pid: Int32?) async {
        guard let pid else { return }
        let activator = SystemWindowActivator(ax: ax, workspace: workspace, mechanisms: [.appKit, .privateFallback])
        let outcome = await activator.activate(ClientTarget(pid: pid, windowID: WindowID(rawValue: 0), title: nil))
        print("还原前台到 pid \(pid)：\(outcome)，\(activator.lastTrace.map(\.step).joined(separator: ">"))")
    }

    // MARK: - minimize

    /// 最小化，保持若干秒后再激活还原，打印前后的 AX 与 CG 状态。
    static func minimize(_ args: [String]) async -> Int32 {
        guard let pid = args.first.flatMap(Int32.init) else { return usage() }
        let hold = args.dropFirst().first.flatMap(Double.init) ?? 2
        guard let target = await target(pid: pid) else {
            print("找不到 pid \(pid) 的主窗口")
            return 1
        }
        let original = await originalFrontmost()
        let activator = SystemWindowActivator(ax: ax, workspace: workspace)
        let result = await activator.minimize(target)
        print("最小化：\(result)")
        try? await Task.sleep(for: .milliseconds(Int(hold * 1000)))
        await printWindowState(pid: pid)
        let outcome = await activator.activate(target)
        print("还原：\(outcome)")
        for entry in activator.lastTrace {
            print(String(format: "  %7.1f ms  %@  %@", entry.elapsedMilliseconds, entry.step, entry.detail))
        }
        try? await Task.sleep(for: .milliseconds(500))
        await printWindowState(pid: pid)
        await restore(original)
        return 0
    }

    /// 打印该 PID 主窗口的在屏与最小化状态。
    static func printWindowState(pid: Int32) async {
        let mains = ClientWindowSelector.mainWindows(from: await windows.candidateWindows())
        for window in mains where window.pid == pid {
            print("  wid \(window.windowID.rawValue) onScreen \(window.isOnScreen) "
                  + "minimized \(String(describing: window.isMinimized)) \(describe(window.frame))")
        }
    }

    // MARK: - hotkey

    /// 注册两个热键，打印注册结果与触发记录，到时退出。
    static func hotkey(_ args: [String]) async -> Int32 {
        let seconds = args.first.flatMap(Double.init) ?? 15
        // 用 App 实际使用的注册器（第一轮反馈起是 SystemHotkeyRegistrar），探针与应用走同一条路径。
        let registrar = SystemHotkeyRegistrar()
        let texts = ["ctrl+shift+F13", "opt+F13"]
        var bindings: [HotkeyBinding] = []
        for (index, text) in texts.enumerated() {
            guard let hotkey = Hotkey(string: text) else { continue }
            bindings.append(HotkeyBinding(id: UInt32(index + 1), hotkey: hotkey, action: .toggleHideAll))
        }
        let started = ContinuousClock.now
        registrar.onHotkey = { id in
            let name = bindings.first { $0.id == id }?.hotkey.stringValue() ?? "?"
            print("触发：id \(id) \(name)，第 \(milliseconds(since: started)) 毫秒")
        }
        let failures = registrar.replaceAll(with: bindings)
        for binding in bindings {
            let failure = failures.first { $0.binding.id == binding.id }
            print("注册 \(binding.hotkey.stringValue())：\(failure.map { "失败 \($0.reason)" } ?? "成功 (noErr)")")
        }
        print("等待 \(Int(seconds)) 秒，请按热键……")
        try? await Task.sleep(for: .seconds(seconds))
        registrar.replaceAll(with: [])
        print("结束")
        return 0
    }

    // MARK: - 工具

    /// 从 start 到现在的毫秒数，保留 1 位小数。
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        let value = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return (value * 10).rounded() / 10
    }

    /// 矩形的简短写法。
    static func describe(_ rect: ScreenRect) -> String {
        "(\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))×\(Int(rect.height)))"
    }
}

// 入口：建 NSApplication 让主线程跑事件循环（Carbon 热键与前台通知都依赖它），
// 命令在主 actor 的任务里执行，完成后退出。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    let code = await Probe.run(CommandLine.arguments)
    exit(code)
}
application.run()
