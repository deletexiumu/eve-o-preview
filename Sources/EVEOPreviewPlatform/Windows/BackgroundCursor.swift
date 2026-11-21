// SPDX-License-Identifier: GPL-3.0-or-later
//
// 让本应用在后台时也能改鼠标光标（v1.2.1，缩略图与浮窗的边缘缩放光标）。
// 本应用几乎从不在前台：点缩略图不会激活本应用，前台一直是游戏。系统默认不让后台应用改光标，
// 鼠标停在缩略图边缘时 NSCursor.set() 不生效，用户看不出边缘能拖。
// 这里用 CoreGraphics/SkyLight 的私有接口 CGSSetConnectionProperty 给本进程的连接打开
// 「SetsCursorInBackground」属性。与 PrivateActivation 一样：符号经 dlsym 运行时查找，找不到时只记日志、
// 不崩溃，拖边缩放本身照常可用，只是没有光标提示。以后要移除时删掉本文件与 AppDelegate 里的一处调用即可。

import CoreFoundation
import Darwin

/// 后台改光标的私有接口封装。
public enum BackgroundCursor {
    /// `CGSMainConnectionID() -> CGSConnectionID`（SkyLight 里叫 `SLSMainConnectionID`）。
    private typealias MainConnectionFunction = @convention(c) () -> Int32
    /// `CGSSetConnectionProperty(cid, targetCID, key, value) -> CGError`。
    private typealias SetPropertyFunction =
        @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// SkyLight 框架的路径；CoreGraphics 里查不到时到这里找 SLS 前缀的同名函数。
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    /// 运行时查到的两个函数；任一查不到时为 nil。只在首次使用时查找一次。
    private static let functions: (MainConnectionFunction, SetPropertyFunction)? = {
        // RTLD_DEFAULT（值为 -2）：在已加载的全部映像里查找；CoreGraphics 已被 AppKit 加载。
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        if let main = dlsym(defaultHandle, "CGSMainConnectionID"),
           let set = dlsym(defaultHandle, "CGSSetConnectionProperty") {
            return (unsafeBitCast(main, to: MainConnectionFunction.self),
                    unsafeBitCast(set, to: SetPropertyFunction.self))
        }
        guard let skyLight = dlopen(skyLightPath, RTLD_LAZY),
              let main = dlsym(skyLight, "SLSMainConnectionID"),
              let set = dlsym(skyLight, "SLSSetConnectionProperty") else { return nil }
        return (unsafeBitCast(main, to: MainConnectionFunction.self),
                unsafeBitCast(set, to: SetPropertyFunction.self))
    }()

    /// 打开「后台也能改光标」。启动时调用一次即可；返回是否成功（失败时已记日志）。
    @discardableResult
    public static func enable() -> Bool {
        let log = PlatformLog.logger("BackgroundCursor")
        guard let (mainConnection, setProperty) = functions else {
            log.error("私有接口符号查找失败，后台时不显示缩放光标")
            return false
        }
        let connection = mainConnection()
        let status = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        guard status == 0 else {
            log.error("打开后台光标失败，CGError \(status)")
            return false
        }
        log.info("已打开后台光标")
        return true
    }
}
