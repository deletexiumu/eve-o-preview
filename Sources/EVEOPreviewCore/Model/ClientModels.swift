// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口与客户端模型（架构文档 5.1 节）。运行时用窗口 ID 标识客户端，
// 持久化用角色名；登录界面的客户端标题都是 `EVE`，不能按标题区分。

import Foundation

/// 窗口 ID，对应 `CGWindowID`。
///
/// 同一窗口在存活期间 ID 不变；窗口销毁后 ID 可能被系统复用给别的窗口。
public struct WindowID: Sendable, Hashable, Codable, RawRepresentable {
    /// `CGWindowID` 的原始值。
    public let rawValue: UInt32

    /// 用 `CGWindowID` 的原始值建一个窗口 ID。
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

extension WindowID: Comparable {
    /// 按原始值比较，供「并列时取 ID 最小的窗口」一类规则使用。
    public static func < (lhs: WindowID, rhs: WindowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 平台层上报的一个候选窗口（某个 EVE 进程的一个 layer 0 窗口）。
public struct WindowInfo: Sendable, Hashable {
    /// 窗口 ID。
    public var windowID: WindowID
    /// 所属进程的 PID，取自 `kCGWindowOwnerPID`。
    public var pid: Int32
    /// 窗口标题；nil 表示读不到（缺屏幕录制与辅助功能权限），空串由平台层记为 nil。
    public var title: String?
    /// 窗口在全局屏幕坐标中的范围，单位是点。
    public var frame: ScreenRect
    /// 窗口当前是否在屏幕上（在别的空间或已最小化时为假）。
    public var isOnScreen: Bool
    /// 是否已最小化；nil 表示没有辅助功能权限，状态未知。
    public var isMinimized: Bool?
    /// 是否是原生全屏窗口（AX 的 `AXFullScreen`，v1.1.1）；nil 表示不知道。
    public var isFullScreen: Bool?

    /// 用平台层读到的各字段建一个候选窗口。
    public init(windowID: WindowID, pid: Int32, title: String?, frame: ScreenRect,
                isOnScreen: Bool, isMinimized: Bool?, isFullScreen: Bool? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
    }
}

/// 客户端的身份，由窗口标题解析而来（见 `TitleParser`）。
public enum ClientIdentity: Sendable, Hashable {
    /// 已选角色的客户端，关联值是角色名（区分大小写，用作持久化的键）。
    case character(String)
    /// 停在登录界面、标题是 `EVE` 的客户端。
    case login
    /// 标题读不到或无法识别的客户端，按登录客户端的方式摆放。
    case unknown
}

extension ClientIdentity {
    /// 角色名；登录与未知客户端返回 nil。
    public var characterName: String? {
        if case .character(let name) = self { return name }
        return nil
    }
}

/// 一个已发现的 EVE 客户端：一个进程及其主窗口。
public struct EVEClient: Sendable, Hashable, Identifiable {
    /// 主窗口的窗口 ID，运行时的唯一标识。
    public var id: WindowID
    /// 进程 PID。
    public var pid: Int32
    /// 由标题解析出的身份。
    public var identity: ClientIdentity
    /// 主窗口的范围，全局屏幕坐标，单位是点。
    public var windowFrame: ScreenRect
    /// 主窗口是否在屏幕上。
    public var isOnScreen: Bool
    /// 是否已最小化；nil 表示状态未知（没有辅助功能权限）。
    public var isMinimized: Bool?
    /// 主窗口是否是原生全屏（v1.1.1）；nil 表示不知道。
    public var isFullScreen: Bool?

    /// 用各字段建一个客户端。
    public init(id: WindowID, pid: Int32, identity: ClientIdentity, windowFrame: ScreenRect,
                isOnScreen: Bool, isMinimized: Bool?, isFullScreen: Bool? = nil) {
        self.id = id
        self.pid = pid
        self.identity = identity
        self.windowFrame = windowFrame
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
    }

    /// 由主窗口建客户端，身份经 `TitleParser.identity(fromTitle:)` 解析。
    public init(window: WindowInfo) {
        self.init(id: window.windowID, pid: window.pid,
                  identity: TitleParser.identity(fromTitle: window.title),
                  windowFrame: window.frame, isOnScreen: window.isOnScreen,
                  isMinimized: window.isMinimized, isFullScreen: window.isFullScreen)
    }

    /// 角色名；登录与未知客户端返回 nil。
    public var characterName: String? { identity.characterName }

    /// 切换或最小化时交给 `WindowActivator` 的目标描述。
    ///
    /// 角色客户端的标题是 `EVE - <角色名>`，登录客户端是 `EVE`，供 AX 侧按标题匹配窗口；
    /// 未知客户端的显示名 `EVE (<pid>)` 不是真实标题，所以给 nil，不按标题匹配。
    public var target: ClientTarget {
        let title: String?
        switch identity {
        case .character(let name): title = TitleParser.characterPrefix + name
        case .login: title = TitleParser.loginTitle
        case .unknown: title = nil
        }
        return ClientTarget(pid: pid, windowID: id, title: title)
    }
}

/// 交给 `WindowActivator` 的切换目标。
public struct ClientTarget: Sendable, Hashable {
    /// 目标进程的 PID。
    public var pid: Int32
    /// 目标主窗口的窗口 ID。
    public var windowID: WindowID
    /// 窗口标题，供一个进程有多个 AX 窗口时按标题匹配；nil 表示不按标题匹配。
    public var title: String?

    /// 用 PID、窗口 ID 与标题建一个目标。
    public init(pid: Int32, windowID: WindowID, title: String?) {
        self.pid = pid
        self.windowID = windowID
        self.title = title
    }
}

/// 同一窗口 ID 在两次轮询之间的变化。
public struct ClientChange: Sendable, Hashable {
    /// 变化前的客户端。
    public var before: EVEClient
    /// 变化后的客户端。
    public var after: EVEClient

    /// 用变化前后的客户端建一条变化记录。
    public init(before: EVEClient, after: EVEClient) {
        self.before = before
        self.after = after
    }
}

/// `ClientRegistry.update(with:)` 的结果：按窗口 ID 比较得出的差异。
public struct RegistryDiff: Sendable, Equatable {
    /// 新出现的客户端，按输入顺序。
    public var added: [EVEClient]
    /// 消失的客户端，按原登记顺序。
    public var removed: [EVEClient]
    /// 身份变了的客户端（例如登录后标题从 `EVE` 变成 `EVE - <角色名>`）。
    public var renamed: [ClientChange]
    /// 身份没变，只有位置、尺寸、在屏或最小化状态变了的客户端。
    public var updated: [ClientChange]

    /// 用 4 类差异建一个结果，默认全空。
    public init(added: [EVEClient] = [], removed: [EVEClient] = [],
                renamed: [ClientChange] = [], updated: [ClientChange] = []) {
        self.added = added
        self.removed = removed
        self.renamed = renamed
        self.updated = updated
    }

    /// 4 类差异都为空时为真。
    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && renamed.isEmpty && updated.isEmpty
    }
}
