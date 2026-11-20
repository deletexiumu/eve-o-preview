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
            Logger(subsystem: PlatformLog.subsystem, category: "PrivateActivation")
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
