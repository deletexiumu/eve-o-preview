// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 mousetap 命令（反馈文档 6.9 节）：打印辅助功能权限，建与 MouseEventTap 相同的事件监听，
// 在给定秒数内打印每个中键、侧键事件的类型、按钮号与修饰键；带 --swallow 时吞掉指定按钮。
// 运行时要用户按鼠标按键配合，应和用户约好时间，不在用户游戏时自行运行。
//
// 不带 --swallow 时全部事件放行，不影响用户的鼠标，可用来只核对「事件监听能不能建成」（V9）。
// MouseEventTap 只在 Platform 内部使用，探针不能直接调它，所以这里按同样的参数单独建一个监听：
// 会话级、插在最前面、能改动事件流（.defaultTap），事件掩码只含 otherMouseDown、otherMouseUp、otherMouseDragged。
// 之后再用 SystemHotkeyRegistrar 建一条不会被按到的鼠标绑定（ctrl+opt+shift+cmd+Mouse32），
// 核对应用自己的路径也能建成、开关、拆除与重建。这条绑定实际不会被按到，所以不吞任何点击。

import AppKit
import ApplicationServices
import EVEOPreviewCore
import EVEOPreviewPlatform
import os

/// mousetap 命令的实现。
@MainActor enum MouseTapProbe {
    /// 执行 mousetap 命令，返回进程退出码。
    ///
    /// 用法：`mousetap [秒数] [--swallow 按钮号]`，秒数默认 20，按钮号 2～31。
    static func run(_ args: [String]) async -> Int32 {
        guard let options = parse(args) else {
            print("用法：EVEOProbe mousetap [秒数] [--swallow 按钮号（2～31）]")
            return 2
        }
        // 第 1 步：权限。只读查询，不弹任何系统提示。
        let trusted = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        let post = CGPreflightPostEventAccess()
        print("辅助功能 AXIsProcessTrusted：\(trusted)")
        print("输入监控 CGPreflightListenEventAccess：\(listen)")
        print("发送事件 CGPreflightPostEventAccess：\(post)")

        // 第 2 步：建事件监听。没有辅助功能权限时也尝试，结果本身就是 V9 的证据。
        let context = ProbeTapContext(swallowButton: options.swallow)
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: probeTapCallback, userInfo: pointer) else {
            print("事件监听：tapCreate 返回 nil，没有建成")
            return 1
        }
        context.port.withLockUnchecked { $0 = PortBox(port: port) }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        // 探针的主线程一直在跑 NSApplication 的事件循环，监听直接挂在主线程的运行循环上。
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        print("事件监听：已建成，tapIsEnabled = \(CGEvent.tapIsEnabled(tap: port))")
        if let button = options.swallow {
            print("吞掉按钮号 \(button) 的按下、拖动与松开；其余放行")
        } else {
            print("全部事件放行（只听不吞）")
        }

        // 第 3 步：在给定秒数内打印事件。
        print("等待 \(Int(options.seconds)) 秒，请按中键或侧键……")
        try? await Task.sleep(for: .seconds(options.seconds))

        // 拆掉监听：先关，再从运行循环移除，最后作废端口。
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
        context.port.withLock { $0 = PortBox(port: nil) }
        print("事件监听：已拆除，共收到 \(context.eventCount.withLock { $0 }) 个事件")

        // 第 4 步：应用自己的路径。绑定 ctrl+opt+shift+cmd+Mouse32，实际不会被按到，所以不吞任何点击。
        checkAppPath()
        return 0
    }

    /// 应用路径用的注册器。它的 Carbon 事件处理器持有非持有指针，所以放在静态属性里活到进程结束。
    private static var appPathRegistrar: SystemHotkeyRegistrar?

    /// 用 SystemHotkeyRegistrar 建一条不会被按到的鼠标绑定，走一遍暂停、恢复、前台切换、拆除与重建，
    /// 每一步打印返回的失败项。线程是否按时结束看系统日志里 MouseTap 类别的记录。
    private static func checkAppPath() {
        let registrar = appPathRegistrar ?? SystemHotkeyRegistrar()
        appPathRegistrar = registrar
        guard let hotkey = Hotkey(mouseButton: Hotkey.mouseButtonRange.upperBound,
                                  modifiers: [.control, .option, .shift, .command]) else { return }
        let global = HotkeyBinding(id: 1, hotkey: hotkey, action: .toggleHideAll, scope: .global)
        let game = HotkeyBinding(id: 1, hotkey: hotkey, action: .toggleHideAll, scope: .game)
        let steps: [(String, () -> [HotkeyRegistrationFailure])] = [
            ("replaceAll(\(hotkey.stringValue())@global)", { registrar.replaceAll(with: [global]) }),
            ("suspend + resume", { registrar.suspend(); return registrar.resume() }),
            ("replaceAll([])，拆除", { registrar.replaceAll(with: []) }),
            ("replaceAll(\(hotkey.stringValue())@game)，重建", { registrar.replaceAll(with: [game]) }),
            ("setGameFrontmost(true)", { registrar.setGameFrontmost(true) }),
            ("setGameFrontmost(false)", { registrar.setGameFrontmost(false) }),
            ("replaceAll([])，拆除", { registrar.replaceAll(with: []) }),
        ]
        for (name, step) in steps {
            let failures = step()
            let summary = failures.isEmpty ? "无失败项" : failures.map { "\($0.reason)" }.joined(separator: "、")
            print("应用路径 \(name)：\(summary)")
        }
    }

    /// 命令行参数。
    private struct Options {
        /// 监听的秒数。
        var seconds: Double = 20
        /// 要吞掉的按钮号；nil 表示全部放行。
        var swallow: Int?
    }

    /// 解析参数；格式不对时返回 nil。
    private static func parse(_ args: [String]) -> Options? {
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--swallow" {
                guard index + 1 < args.count, let button = Int(args[index + 1]),
                      Hotkey.mouseButtonRange.contains(button) else { return nil }
                options.swallow = button
                index += 2
            } else if let seconds = Double(arg), seconds > 0 {
                options.seconds = seconds
                index += 1
            } else {
                return nil
            }
        }
        return options
    }
}

/// CoreFoundation 端口的盒子。端口不是 Sendable，只在持锁时读写。
private struct PortBox: @unchecked Sendable {
    var port: CFMachPort?
}

/// 回调用到的状态。回调在主线程上被调用，但它是 C 函数，不能声明隔离，所以状态都放在锁里。
private final class ProbeTapContext: Sendable {
    /// 要吞掉的按钮号。
    let swallowButton: Int?
    /// 按下已被吞掉、还没松开的按钮号。
    let swallowed = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
    /// 事件监听的端口，重新打开监听时用。
    let port = OSAllocatedUnfairLock<PortBox>(initialState: PortBox())
    /// 收到的事件数。
    let eventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// 开始时刻，打印相对时间用。
    let started = ContinuousClock.now

    init(swallowButton: Int?) {
        self.swallowButton = swallowButton
    }

    /// 处理一个事件，返回 true 表示吞掉。
    func handle(type: CGEventType, button: Int, flags: CGEventFlags) -> Bool {
        eventCount.withLock { $0 += 1 }
        let swallow: Bool
        switch type {
        case .otherMouseDown:
            swallow = button == swallowButton
            swallowed.withLock { set in
                set.remove(button)
                if swallow { set.insert(button) }
            }
        case .otherMouseUp:
            swallow = swallowed.withLock { $0.remove(button) != nil }
        case .otherMouseDragged:
            swallow = swallowed.withLock { $0.contains(button) }
        default:
            swallow = false
        }
        let elapsed = ContinuousClock.now - started
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        print("第 \(ms) 毫秒 \(Self.name(of: type)) 按钮号 \(button)（Mouse\(button + 1)）"
              + " 修饰键 \(Self.describe(flags))\(swallow ? " → 吞掉" : "")")
        return swallow
    }

    /// 事件类型的简短名字。
    static func name(of type: CGEventType) -> String {
        switch type {
        case .otherMouseDown: return "按下"
        case .otherMouseUp: return "松开"
        case .otherMouseDragged: return "拖动"
        default: return "类型 \(type.rawValue)"
        }
    }

    /// 修饰键的写法：只看 Command、Option、Control、Shift 四位。
    static func describe(_ flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("opt") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskCommand) { parts.append("cmd") }
        return parts.isEmpty ? "无" : parts.joined(separator: "+")
    }
}

/// 探针事件监听的 C 回调。userInfo 是 ProbeTapContext 的非持有指针，它活到 run 返回。
private func probeTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<ProbeTapContext>.fromOpaque(userInfo).takeUnretainedValue()
    // 系统因超时或用户输入关掉监听时，重新打开并放行这个事件。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("监听被系统关闭（类型 \(type.rawValue)），重新打开")
        context.swallowed.withLock { $0.removeAll() }
        if let port = context.port.withLockUnchecked({ $0.port }) { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
    let swallow = context.handle(type: type, button: button, flags: event.flags)
    return swallow ? nil : Unmanaged.passUnretained(event)
}
