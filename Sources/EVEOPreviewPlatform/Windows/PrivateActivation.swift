// SPDX-License-Identifier: GPL-3.0-or-later
//
// 激活的私有接口后备（架构文档 6.4 节，用户已同意，见第 12 节 Q2）。
// 公开接口核对仍不在前台时，用 SkyLight 的 _SLPSSetFrontProcessWithOptions 把目标进程设为前台。
// 符号经 dlsym 运行时查找，找不到时返回 symbolMissing，不崩溃。
// 后备只放在本文件，以后要移除时删掉本文件与激活器里的一处调用即可。

import ApplicationServices
import Darwin
import os

/// 私有接口后备的调用结果。
public enum PrivateActivationResult: Sendable, Equatable {
    /// 调用已发出且返回成功（是否真的到了前台由调用方另行核对）。
    case requested
    /// 符号查找失败（系统版本变了或框架被移除），跳过这一步。
    case symbolMissing
    /// `GetProcessForPID` 失败，关联值是 `OSStatus`。
    case processLookupFailed(Int32)
    /// `_SLPSSetFrontProcessWithOptions` 返回错误，关联值是 `CGError` 的原始值。
    case callFailed(Int32)
}

/// SkyLight 私有接口的封装。
public enum PrivateActivation {
    /// `kCPSUserGenerated`：按用户操作触发的前台切换处理，系统不会因协作式激活而拒绝。
    static let userGeneratedMode: UInt32 = 0x200

    /// `GetProcessForPID(pid_t, ProcessSerialNumber *) -> OSStatus`。
    /// 公开但已弃用的 Carbon 接口；经 dlsym 调用，避免编译期的弃用警告。
    private typealias GetProcessForPIDFunction =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    /// `_SLPSSetFrontProcessWithOptions(ProcessSerialNumber *, CGWindowID, uint32_t) -> CGError`。
    private typealias SetFrontProcessFunction =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32

    /// SkyLight 框架的路径。
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    /// 运行时查到的两个函数；任一为 nil 时整个后备不可用。只在首次使用时查找一次。
    /// C 函数指针是 Sendable，查到后不再改变，跨线程读取安全。
    private static let functions: (GetProcessForPIDFunction, SetFrontProcessFunction)? = {
        // RTLD_DEFAULT（值为 -2）：在已加载的全部映像里查找；ApplicationServices 已被 AppKit 加载。
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let getPSN = dlsym(defaultHandle, "GetProcessForPID"),
              let skyLight = dlopen(skyLightPath, RTLD_LAZY),
              let setFront = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions") else {
            PlatformLog.logger("PrivateActivation")
                .error("私有接口符号查找失败，后备不可用")
            return nil
        }
        return (unsafeBitCast(getPSN, to: GetProcessForPIDFunction.self),
                unsafeBitCast(setFront, to: SetFrontProcessFunction.self))
    }()

    /// 把目标进程设为前台，并指定要提到前面的窗口。
    ///
    /// - Parameters:
    ///   - pid: 目标进程的真实 PID（取自 `kCGWindowOwnerPID`）。
    ///   - windowID: 目标窗口的 `CGWindowID`；传 0 表示不指定窗口。
    public static func bringToFront(pid: Int32, windowID: UInt32) -> PrivateActivationResult {
        guard let (getProcessForPID, setFrontProcess) = functions else { return .symbolMissing }
        var psn = ProcessSerialNumber()
        let lookup = getProcessForPID(pid, &psn)
        guard lookup == noErr else { return .processLookupFailed(lookup) }
        let status = setFrontProcess(&psn, windowID, userGeneratedMode)
        return status == 0 ? .requested : .callFailed(status)
    }
}

// MARK: - 切到其他空间里的窗口（v1.1.1，全屏客户端）

/// EVE 用原生全屏时，每个客户端在自己的全屏空间里。AX 的窗口列表只含当前空间的窗口，
/// 点另一个客户端的缩略图时 AX 找不到它，只设前台进程也不会切换空间。实测（2026-11-21，macOS 27）
/// 三步合起来才会切过去：`_SLPSSetFrontProcessWithOptions` 指定窗口、`SLPSPostEventRecordTo`
/// 把它设为关键窗口、用 `_AXUIElementCreateWithRemoteToken` 拿到它的 AX 元素再 `AXRaise`。
/// 做法与 alt-tab-macos 相同。符号都经 dlsym 查找，找不到时返回 nil 或 symbolMissing，不崩溃。
extension PrivateActivation {
    /// `SLPSPostEventRecordTo(ProcessSerialNumber *, uint8_t *) -> CGError`。
    private typealias PostEventRecordFunction =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    /// `_AXUIElementCreateWithRemoteToken(CFDataRef) -> AXUIElementRef`（返回的元素归调用方所有）。
    private typealias RemoteTokenFunction = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    /// `_AXUIElementGetWindow(AXUIElementRef, CGWindowID *) -> AXError`。
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    /// 远程令牌里元素编号的搜索上限。实测 EVE 主窗口的编号是两位数。
    static let remoteElementSearchLimit: UInt64 = 1000

    /// 运行时查到的三个函数。
    private static let spaceFunctions: (PostEventRecordFunction, RemoteTokenFunction, GetWindowFunction)? = {
        // AX 的两个符号在 HIServices 里；显式打开它，不依赖调用时它是否已被加载。
        let hiServices = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let axHandle = dlopen(hiServices, RTLD_LAZY),
              let post = dlsym(skyLight, "SLPSPostEventRecordTo"),
              let remote = dlsym(axHandle, "_AXUIElementCreateWithRemoteToken"),
              let getWindow = dlsym(axHandle, "_AXUIElementGetWindow") else {
            PlatformLog.logger("PrivateActivation").error("切换空间用的私有接口符号查找失败")
            return nil
        }
        return (unsafeBitCast(post, to: PostEventRecordFunction.self),
                unsafeBitCast(remote, to: RemoteTokenFunction.self),
                unsafeBitCast(getWindow, to: GetWindowFunction.self))
    }()

    /// 把目标窗口设为关键窗口：向目标进程发两条窗口服务器事件记录（字节布局同 alt-tab-macos）。
    public static func makeKeyWindow(pid: Int32, windowID: UInt32) -> PrivateActivationResult {
        guard let (getProcessForPID, _) = functions, let (post, _, _) = spaceFunctions else { return .symbolMissing }
        var psn = ProcessSerialNumber()
        let lookup = getProcessForPID(pid, &psn)
        guard lookup == noErr else { return .processLookupFailed(lookup) }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { raw in
            for index in 0..<4 { bytes[0x3c + index] = raw[index] }
        }
        for index in 0..<0x10 { bytes[0x20 + index] = 0xff }
        for kind: UInt8 in [0x01, 0x02] {
            bytes[0x08] = kind
            let status = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
            if status != 0 { return .callFailed(status) }
        }
        return .requested
    }

    /// 用远程令牌找出 `windowID` 对应的 AX 窗口元素；窗口在其他空间时 AX 窗口列表里没有它，只能这样取。
    /// 令牌 20 字节：PID、0、`coco`、元素编号。先试 `hint`，再从 0 起逐个尝试，最多 `remoteElementSearchLimit` 个。
    /// 每试一个编号是一次进程间消息，EVE 上实测约 22 毫秒，主窗口编号是 42，从 0 找要 1 秒左右，
    /// 所以调用方应记住找到的编号作为下次的提示。应在 AXWorker 上调用（AX 调用不占主线程）。
    ///
    /// - Parameters:
    ///   - deadline: 查找的截止时刻；到点还没找到就放弃，免得窗口已关闭时逐个试完（最坏约 22 秒）堵住 AXWorker。
    ///   - shouldContinue: 每试一个编号前调用；返回假时放弃（请求已被新的激活取代）。
    /// - Returns: 窗口元素与它的编号；找不到或放弃时返回 nil。
    static func remoteWindowElement(pid: Int32, windowID: UInt32, hint: UInt64?, deadline: ContinuousClock.Instant,
                                    shouldContinue: () -> Bool) -> (AXUIElement, UInt64)? {
        guard let (_, createWithToken, getWindow) = spaceFunctions else { return nil }
        var token = Data(count: 20)
        let order = (hint.map { [$0] } ?? []) + Array(0..<remoteElementSearchLimit).filter { $0 != hint }
        for elementID in order {
            guard ContinuousClock.now < deadline, shouldContinue() else { return nil }
            token.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
                raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
                raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
                raw.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
            }
            guard let element = createWithToken(token as CFData)?.takeRetainedValue() else { continue }
            var found: UInt32 = 0
            if getWindow(element, &found) == .success, found == windowID { return (element, elementID) }
        }
        return nil
    }
}
