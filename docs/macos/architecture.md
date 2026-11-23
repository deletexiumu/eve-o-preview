# EVE-O Preview for macOS 架构设计

本文是 macOS 原生版 EVE-O Preview 的实现依据。实现方照本文写代码，不靠猜测补全。
本项目按上游 [EveOPlus/eve-o-preview](https://github.com/EveOPlus/eve-o-preview)（GPL-3.0）的功能重新实现，不移植 C# 代码。
文中的 Swift 片段只有类型与协议签名，已在 2026 年 11 月 20 日用 Swift 6.0.3 的 Swift 6 语言模式编译通过。
v1 试用后的第一轮反馈（缩略图边框、多语言、鼠标按键热键与热键作用范围、战斗提醒）的设计在 [design-feedback-round1.md](design-feedback-round1.md)，下称「反馈文档」。本文已同步改动后的类型签名、默认值和范围表，规则与流程的细节以反馈文档为准。
v1.1（文件日志与异常退出检测、问题报告、更新检查与应用内安装）的设计在 [design-v1.1.md](design-v1.1.md)，下称「v1.1 设计」。本文各节只加一句增量说明与指向，类型、流程与文件清单以 v1.1 设计为准。
预警浮窗与聊天翻译浮窗（读聊天日志、星图数据、模型服务与钥匙串、可复用的浮窗面板）的设计在 [design-intel-translate.md](design-intel-translate.md)。本文没有同步它的类型与范围表，这两项功能的类型、流程、文件清单与工作包以那份文档为准。

## 1 已核实的环境事实

下表的事实于 2026-11-20 在目标机器上实测（macOS 27，Apple Silicon，3 个 EVE 客户端在线，探针进程已有屏幕录制与辅助功能权限）。

| 编号 | 事实 | 对设计的影响 |
| --- | --- | --- |
| E1 | 只有 Command Line Tools：Swift 6.0.3，SDK MacOSX15.2，没有 Xcode | 只用 SwiftPM；`.app` 由脚本组装；不用资源目录、xib、asset catalog |
| E2 | `import Testing` 可用，`XCTest` 不可用 | 测试只写 swift-testing，只测 Core |
| E3 | SwiftUI、`@Observable`、`NSHostingController` 在 CLT 下能编译 | 设置窗口用 SwiftUI |
| E4 | EVE 客户端的 bundle id 是 `com.ccpgames.eveonline`，每个客户端一个进程；启动器是 `com.ccpgames.eve-online-launcher` | 按 bundle id 过滤，启动器自然被排除 |
| E5 | `NSRunningApplication.processIdentifier` 对 3 个 EVE 进程都返回 -1；`NSRunningApplication(processIdentifier: 真实PID)` 能取到对象，对象之间可用 `==` 区分 | 不从 `NSRunningApplication` 读 PID。PID 一律取自 `CGWindowList` 的 `kCGWindowOwnerPID` |
| E6 | 每个 EVE 进程在 `CGWindowList` 里有 5～6 个 layer 0 窗口：1 个主窗口（标题 `EVE - <角色名>`，1728×1018），其余是无标题的 1728×33 和 500×500 辅助窗口 | Core 提供主窗口选择规则（5.3 节） |
| E7 | 每个 EVE 进程在 AX 里只有 1 个窗口（`AXStandardWindow`，支持 `AXRaise`，`kAXMinimizedAttribute` 可读） | AX 侧按 PID 取唯一窗口，不依赖私有接口 `_AXUIElementGetWindow` |
| E8 | `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` 一次耗时 108 毫秒（系统共 424 个窗口） | 不拿它做轮询，只在出现新窗口 ID 时调用 |
| E9 | `SCStream`、`SCShareableContent` 不是 `Sendable`。`@MainActor` 类里直接 `await` 它们的方法会报错，加 `@preconcurrency import ScreenCaptureKit` 后通过 | Platform 的捕获文件统一用 `@preconcurrency import` |
| E10 | 同一进程重复注册同一热键，`RegisterEventHotKey` 返回 -9878（`eventHotKeyExistsErr`）；注册 Cmd+Tab、Cmd+Space、只带 Option 的组合都返回 `noErr` | 系统保留组合靠 Core 的名单拦截，不能靠注册结果判断 |
| E11 | 钥匙串里没有代码签名身份 | 默认 ad-hoc 签名；脚本接受 `SIGN_IDENTITY` |

未实测、留给实现阶段核实的行为列在第 11 节。

## 2 产品范围

### 2.1 v1 范围

v1.1 在本节范围之外新增 3 项：文件日志与问题报告（v1.1 设计第 5～7 节）、更新检查（第 8 节）、应用内安装（第 9 节）。

1. 客户端发现：自动找到 EVE 客户端窗口，客户端启动、退出、登录后改名时更新。
2. 实时缩略图：每个客户端一条 ScreenCaptureKit 流，尺寸和帧率可配置。
3. 缩略图面板：无边框、不抢焦点、出现在所有空间，可设置是否置顶。
4. 切换：左键点缩略图切到对应客户端；Ctrl+点击最小化；右键菜单提供最小化、全部最小化、跳过循环、隐藏、恢复默认尺寸。
5. 叠层：角色名标题、每个缩略图的边框、活动客户端高亮边框（可按角色设颜色）、跳过循环标记。
6. 悬停放大（9 个锚点）与透明度。
7. 可见性：隐藏活动客户端的缩略图；前台不是 EVE 时隐藏（带延迟）；按角色隐藏；全部隐藏。
8. 布局：拖动移动、拖动缩放，吸附到其他缩略图和屏幕边缘，可锁定布局。
9. 每个角色保存位置与尺寸，登录界面的客户端使用单独的起始位置。
10. 循环组：前进与后退全局热键、临时跳过；每角色直达热键；登录客户端循环热键；全部隐藏与全部最小化热键。
11. 配置方案（profile）：新建、克隆、改名、删除、切换。
12. 菜单栏图标，代替 Windows 托盘。
13. 设置窗口：客户端、预览与布局、切换与热键、提醒、配置方案、通用、权限、关于，共 8 页。
14. 权限引导：显示屏幕录制与辅助功能的状态，提供系统设置的跳转链接。

第一轮反馈（2026-11-20 定）在 v1 之上增加 4 项，设计见反馈文档：

15. 边框：每个缩略图默认带一圈中性色边框，可关闭，颜色与粗细可调。
16. 界面语言：英文（默认）、中文、俄文、日文、韩文，可跟随系统，切换后立即生效。
17. 热键：可绑定鼠标的中键与侧键；每条热键可设为全局生效或只在前台是 EVE 客户端时生效。
18. 战斗提醒：读游戏日志，角色受击时它的缩略图闪烁。

### 2.2 推迟到 v1 之后

| 功能 | 推迟原因 |
| --- | --- |
| 区域（Regions）与拖放停靠 | 界面工作量大，依赖稳定的布局与吸附，先交付单个缩略图的布局 |
| 多选、成组移动缩放、撤销 | 同上，属于布局的增强 |
| 吸附参考线 | 只是视觉反馈，吸附本身在 v1 |
| 按活动角色切换的多套缩略图布局、记住游戏窗口位置 | 使用面窄，会让配置结构变复杂 |
| 切换时最小化非活动客户端、优先客户端 | macOS 下窗口最小化后的捕获行为未核实（V4），先不做自动最小化 |
| 预览其他应用 | 发现规则已按 bundle id 参数化，留出扩展点 |
| 角色头像（ESI）、循环组纳入登录客户端 | 依赖账号识别与网络请求 |
| Ctrl+Shift+点击回到上一个非 EVE 应用、热键松开触发 | 次要手势 |
| 导入 Windows 版的配置文件、登录时启动 | 见第 12 节 |

### 2.3 不移植

| 上游功能 | 原因 |
| --- | --- |
| 帧率限制、选择性静音（Robin 注入） | 靠向 Windows 进程注入 DLL 实现，macOS 没有对应的公开机制 |
| CPU 亲和性 | 依赖 Windows CPU Sets；Apple Silicon 没有按进程指定核心的公开接口 |
| 战斗日志增强（Augments）里的伤害数字、DPS、维修量、星系叠层，以及 FC 静态数据 | 独立的大型子系统，不属于「预览与切换」。其中的受击闪烁已在第一轮反馈中另行实现（反馈文档第 7 节） |
| 主题、Legacy 界面、自定义右键菜单样式 | Avalonia 界面专属，macOS 版跟随系统外观 |
| 根证书信任、.NET 运行时说明 | Windows 分发专属 |
| 兼容捕获模式（`PrintWindow`） | ScreenCaptureKit 是唯一的捕获后端 |
| 低级键盘钩子输入模式、诊断直通 | 键盘用 Carbon 热键，不装键盘钩子。鼠标按键热键用只监听中键与侧键的事件监听（反馈文档 6.6 节） |

## 3 总体架构

### 3.1 模块

v1.1 起，三个模块各增加日志、诊断与更新的部分，职责划分见 v1.1 设计 4.1 节：纯规则（版本比较、脱敏、发布说明选取等）在 Core，文件、网络、签名核对与磁盘映像在 Platform，窗口与控制器在 App。

```text
EVEOPreview（可执行，AppKit + SwiftUI）
   ├── EVEOPreviewPlatform（AppKit、ScreenCaptureKit、ApplicationServices、Carbon）
   │        └── EVEOPreviewCore
   └── EVEOPreviewCore（只 import Foundation）
EVEOProbe（可执行，命令行探针）── EVEOPreviewPlatform
EVEOPreviewCoreTests（swift-testing）── EVEOPreviewCore
```

| 目标 | 职责 | 约束 |
| --- | --- | --- |
| `EVEOPreviewCore` | 数据模型、配置读写与迁移、标题解析、客户端登记、布局与吸附、循环顺序、热键解析与规划、可见性规则、缩略图规划器、游戏日志解析与提醒规则、只含值类型的平台协议 | 只 `import Foundation`，不引用 AppKit、CoreGraphics 类型、ScreenCaptureKit |
| `EVEOPreviewPlatform` | 窗口枚举、捕获、窗口激活、热键注册（键盘与鼠标）、游戏日志跟踪、权限、前台应用观察、坐标换算 | 实现 Core 的协议；另外定义带 `IOSurface` 的捕获协议 |
| `EVEOPreview` | 应用生命周期、协调器、缩略图面板、菜单栏、设置窗口 | 只通过协议使用 Platform，由 `PlatformServices.makeLive()` 取得实现 |
| `EVEOProbe` | 命令行探针，在真实客户端上验证 Platform | 不进发布包 |

`Package.swift` 用 `swift-tools-version: 6.0`，`platforms: [.macOS(.v14)]`，`swiftLanguageModes: [.v6]`，没有第三方依赖，没有资源文件。

### 3.2 线程与隔离

v1.1 新增两处隔离的例外：`FileLogSink` 用锁保护，可从任意线程写日志；更新的下载、哈希、挂载与签名核对在后台任务里执行，结果回到主线程（v1.1 设计 4.3 节）。

- Core 的模型都是 `Sendable` 值类型，纯函数没有隔离要求。
- Platform 的服务和 App 的全部类型都是 `@MainActor`，只有 5 处例外：
  - `CGWindowProvider` 是 `actor`，`CGWindowList` 查询不占主线程。
  - `AXWorker` 是 `actor`。AX 调用是同步的进程间调用，客户端卡住时会阻塞调用方，所以不放在主线程。启动时对 `AXUIElementCreateSystemWide()` 设一次 `AXUIElementSetMessagingTimeout(_, 0.25)`，对全部 AX 元素生效（只对应用元素设置时，窗口元素的调用仍用系统默认超时）。
  - `StreamOutputHandler` 在自己的串行队列上接收帧，用 `OSAllocatedUnfairLock` 保护「最新一帧」槽位，再切回主线程。
  - `MouseEventTap` 的事件回调在一条专用线程上运行，用 `OSAllocatedUnfairLock` 保护绑定表与前台状态，触发后切回主线程（反馈文档 6.6 节）。
  - `CombatLogTailer` 的全部状态只在自己的串行队列上访问，结果切回主线程（反馈文档 7.4 节）。
- Carbon 热键回调在主线程触发，回调里用 `MainActor.assumeIsolated` 进入主 actor。

### 3.3 数据流

协调器 `AppCoordinator` 持有全部运行时状态。任何事件都只做一件事：更新状态，然后请求一次重算。

```text
事件（轮询结果、前台变化、配置变化、悬停、定时唤醒、捕获状态变化、受击事件）
   → AppCoordinator 更新状态
   → ThumbnailPlanner.plan(PlannerInput)（Core 纯函数）
   → ThumbnailPlan
        ├── presentations → ThumbnailWindowManager 按差异更新面板
        ├── captures      → CaptureService.reconcile
        ├── layoutsToPersist → ConfigController 写入当前配置方案
        └── nextWakeAt    → 安排一次定时重算（用于隐藏延迟与提醒到期）
```

重算在同一个主循环回合内合并成一次。拖动缩略图时，面板位置由交互控制器直接改，不经过规划器和配置保存；松开鼠标时才提交一次（做法同上游，避免高频事件写配置）。

## 4 关键设计决定

### 4.1 身份

- 运行时用窗口 ID（`CGWindowID`）标识客户端，同时记录 PID。登录界面的客户端标题都是 `EVE`，所以运行时不按标题区分。
- 持久化用角色名，即标题去掉 `EVE - ` 前缀后的部分。布局、隐藏名单、高亮颜色、循环组成员、角色热键都以角色名为键，区分大小写。
- 登录界面的客户端和标题未知的客户端没有持久化键，使用 `loginPosition` 加层叠偏移。
- AX 侧按 PID 找窗口（E7）。一个进程出现多个 AX 窗口时，先按标题匹配，再取第一个 `AXStandardWindow`。

### 4.2 坐标

- Core 只有一种坐标：全局屏幕坐标，单位是点，原点在主屏左上角，y 轴向下。它与 `CGWindowList`、AX、ScreenCaptureKit 的窗口坐标一致。
- 配置文件里的位置和尺寸都用这种坐标，键名是 `x`、`y`、`width`、`height`。不用 `CGRect` 的默认 Codable 输出。
- AppKit 的 `NSWindow.frame` 以主屏左下角为原点。换算只在 `Platform/Geometry/CoordinateConversion.swift` 一处做，其他文件不自己翻转 y 轴。
- 像素只出现在捕获规格里：`像素 = 点 × 所在屏幕的 scale`。

### 4.3 前台跟踪

上游靠定时器轮询前台窗口。macOS 版用 `NSWorkspace.didActivateApplicationNotification` 触发，每次轮询再核对一次。
因为 E5，前台应用不能按 PID 读取。`WorkspaceObserver.frontmost(among:)` 的做法是：对每个已知客户端 PID 取 `NSRunningApplication(processIdentifier:)`，与 `NSWorkspace.shared.frontmostApplication` 用 `==` 比较。
`==` 在「按 PID 取到的对象」与「`runningApplications` 里的对象」之间已实测有效（E5）；与 `frontmostApplication` 的比较没有实测，因为探针运行时前台不是 EVE（V8）。备选办法是读每个客户端应用元素的 `kAXFrontmostAttribute`，这个属性已实测可读，但依赖辅助功能权限。
前台是本应用（设置窗口）时返回 `.selfApp`，按「仍在 EVE 环境内」处理，否则打开设置窗口会让缩略图隐藏。

### 4.4 权限矩阵

Info.plist 里没有屏幕录制或辅助功能的用途说明键，系统弹窗的文字由系统提供。两项权限都按代码签名识别应用（见 9.2 节）。

| 屏幕录制 | 辅助功能 | 发现与标题 | 缩略图画面 | 切换 | 最小化与还原 |
| --- | --- | --- | --- | --- | --- |
| 有 | 有 | 完整 | 实时 | 完整 | 可用 |
| 有 | 无 | 完整（标题来自 `kCGWindowName`） | 实时 | 只激活进程；窗口已最小化时不能还原 | 不可用，菜单项置灰 |
| 无 | 有 | 完整（标题来自 AX） | 占位画面，提示缺少屏幕录制权限 | 完整 | 可用 |
| 无 | 无 | 能发现窗口，标题未知，显示为 `EVE (PID)`；全部按登录客户端处理 | 占位画面 | 只激活进程 | 不可用 |

- 屏幕录制：`CGPreflightScreenCaptureAccess()` 查询，`CGRequestScreenCaptureAccess()` 请求。授权后通常要重启应用才生效，权限页提供「重新启动」按钮。
- 辅助功能：`AXIsProcessTrusted()` 查询，授权后立即生效。权限页可见时每秒查询一次。
- 第 1 行已实测，其余 3 行来自平台文档，由 V1 核实。
- 鼠标按键热键依赖辅助功能权限；没有这项权限时键盘热键照常工作（反馈文档 6.6 节）。
- 战斗提醒读「文稿」下的游戏日志，受系统的「文件与文件夹」权限管。它只影响战斗提醒，不列入上表（反馈文档 7.9 节）。

### 4.5 手势

左键按下立即切换，不等松开，所以移动和缩放不能用普通的左键拖动。

| 操作 | 手势 |
| --- | --- |
| 切换到该客户端 | 左键按下（不带修饰键）；按在边缘带上时改为松开时切换 |
| 最小化该客户端 | Ctrl+左键按下 |
| 打开菜单 | 右键按下并松开，期间移动不到 4 点 |
| 移动 | 右键拖动，或 Option+左键拖动，移动超过 4 点后开始 |
| 缩放 | 同移动的手势，起点落在边缘 12 点范围内时改为缩放那条边或那个角 |
| 缩放（v1.2.1） | 不带修饰键的左键从边缘 6 点的边缘带拖动，角区 14 点（`EdgeGrip`）；鼠标停在边缘带上时显示缩放光标 |
| 临时绕过吸附 | 拖动时按住 Shift；缩放时 Shift 同时保持宽高比 |

v1.2.1 起，不带修饰键的左键按在边缘带上时先不切换：拖动超过 4 点就缩放，没拖动就在松开时切换。登录客户端与 `lockLayout` 打开时没有边缘带。本应用几乎不在前台，系统默认不让后台应用改光标，所以启动时用私有接口 `CGSSetConnectionProperty` 打开 `SetsCursorInBackground`（`BackgroundCursor`，失败时只是没有光标提示）。

`lockLayout` 打开时忽略移动和缩放，切换、最小化、菜单照常。Ctrl+左键在 macOS 上的惯例是右键，这里由视图自己处理 `mouseDown`，不设置 `NSView.menu`。

## 5 Core 契约

约定：每个 `public struct` 都写显式的 `public init`（下文省略）。JSON 键名与属性名相同。所有模型的 `init(from:)` 用 `decodeIfPresent`，缺失的键取默认值。
默认值沿用上游；没有上游对应项或与上游不同的，在 5.2 节的注释里标「新增」或「改动」。

### 5.1 几何与运行时模型

```swift
// [Core] Geometry/ScreenGeometry.swift、Model/ClientModels.swift、Model/RuntimeModels.swift
/// 全局屏幕坐标：单位是点，原点在主屏左上角，y 轴向下。
public struct ScreenPoint: Sendable, Hashable, Codable { public var x: Double; public var y: Double }
public struct ScreenSize: Sendable, Hashable, Codable { public var width: Double; public var height: Double }
public struct ScreenRect: Sendable, Hashable, Codable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
}
/// 归一化矩形（0～1），用于 CALayer.contentsRect。
public struct UnitRect: Sendable, Hashable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
}
public struct ScreenInfo: Sendable, Hashable {
    public var frame: ScreenRect; public var visibleFrame: ScreenRect
    public var scale: Double; public var isMain: Bool
}

// Model/ClientModels.swift
public struct WindowID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: UInt32
    public init(rawValue: UInt32)
}
/// 平台层上报的一个候选窗口。title 为 nil 表示读不到（缺权限）。
public struct WindowInfo: Sendable, Hashable {
    public var windowID: WindowID; public var pid: Int32; public var title: String?
    public var frame: ScreenRect; public var isOnScreen: Bool
    public var isMinimized: Bool?          // nil：没有辅助功能权限，状态未知
}
public enum ClientIdentity: Sendable, Hashable { case character(String); case login; case unknown }
public struct EVEClient: Sendable, Hashable, Identifiable {
    public var id: WindowID; public var pid: Int32; public var identity: ClientIdentity
    public var windowFrame: ScreenRect; public var isOnScreen: Bool; public var isMinimized: Bool?
}
public struct ClientTarget: Sendable, Hashable {
    public var pid: Int32; public var windowID: WindowID; public var title: String?
}
public struct ClientChange: Sendable, Hashable { public var before: EVEClient; public var after: EVEClient }
public struct RegistryDiff: Sendable, Equatable {
    public var added: [EVEClient]; public var removed: [EVEClient]
    public var renamed: [ClientChange]     // identity 变了
    public var updated: [ClientChange]     // 只有位置、尺寸、在屏或最小化状态变了
}

// Model/RuntimeModels.swift
public enum FrontmostContext: Sendable, Equatable { case client(pid: Int32); case selfApp; case other }
public struct PermissionStatus: Sendable, Equatable {
    public var screenRecording: Bool; public var accessibility: Bool
}
public struct CaptureSpec: Sendable, Hashable {
    public var pixelWidth: Int; public var pixelHeight: Int; public var framesPerSecond: Int
}
public enum CaptureState: Sendable, Equatable {
    case idle, starting, running
    case retrying(attempt: Int, delay: Double)
    case stoppedByUser, permissionDenied, windowGone
}
/// 不持久化的会话状态。时间用单调时钟的秒数。
public struct SessionState: Sendable, Equatable {
    public var hideAll: Bool
    public var skippedCharacters: Set<String>   // 切换配置方案或重启后清空
    public var hoveredWindow: WindowID?
    public var interactingWindows: Set<WindowID> // 正在拖动的缩略图，规划器不改它们的 frame
    public var lastEVEContextAt: Double          // 最近一次前台是 EVE 或本应用的时刻
    public var lastActivePID: Int32?             // 最近一次处于前台的客户端
    public var combatAlerts: [WindowID: CombatAlertWindow]   // 未到期的战斗提醒，见反馈文档 7.7 节
}
public struct CombatAlertWindow: Sendable, Equatable { public var startedAt: Double; public var until: Double }
```

### 5.2 配置模型

v1.1 起 `GeneralSettings` 新增 3 个键：`checkForUpdates`（默认开）、`autoInstallUpdates`（默认关）、`logLevel`。`schemaVersion` 仍是 1，旧版本读到新键时忽略。跳过的版本、上次检查时间、ETag、待报告的崩溃等运行记录不放在配置里，放在单独的状态文件 `state.json` 与会话标记 `session.json`，见 v1.1 设计第 3 节。

配置文件是 `~/Library/Application Support/EVE-O Preview/config.json`，一个文件装下全部配置方案，`schemaVersion` 当前是 1。

```swift
// [Core] Model/AppConfig.swift 与 Model/Profile.swift
public struct AppConfig: Sendable, Equatable, Codable {
    public var schemaVersion: Int           // 1
    public var activeProfileID: String
    public var profiles: [Profile]          // 至少 1 个
    public var general: GeneralSettings
}
public struct GeneralSettings: Sendable, Equatable, Codable {
    public var pollIntervalMs: Int          // 新增。默认 1000，范围 300～2000
    public var onboardingCompleted: Bool    // 新增。默认 false
    public var language: LanguagePreference // 第一轮反馈新增。默认 .en
    public var eveLogDirectory: String?     // 第一轮反馈新增。默认 nil，表示自动查找
}
public struct Profile: Sendable, Equatable, Codable, Identifiable {
    public var id: String                   // UUID 字符串
    public var name: String                 // 去掉首尾空白后 1～64 字，不区分大小写唯一
    public var thumbnail: ThumbnailSettings
    public var overlay: OverlaySettings
    public var behavior: BehaviorSettings
    public var capture: CaptureSettings
    public var layouts: [String: ThumbnailLayout]    // 键：角色名
    public var loginPosition: ScreenPoint            // 改动。默认 (5, 40)；上游是 (5, 5)，macOS 顶部有菜单栏
    public var hiddenCharacters: [String]
    public var highlightColors: [String: String]     // 角色名 → "#RRGGBB"
    public var cycleGroups: [CycleGroup]
    public var characterHotkeys: [String: [String]]  // 角色名 → 热键字符串
    public var hotkeys: GeneralHotkeys
    public var hotkeyDefaultScope: HotkeyScope       // 第一轮反馈新增。默认 .global
    public var combatAlert: CombatAlertSettings      // 第一轮反馈新增，见反馈文档 3.1 节
}
public struct ThumbnailSettings: Sendable, Equatable, Codable {
    public var defaultSize: ScreenSize      // 384×216
    public var minimumSize: ScreenSize      // 192×108
    public var maximumSize: ScreenSize      // 960×540
    public var opacity: Double              // 0.5，范围 0.2～1.0
    public var zoomEnabled: Bool            // false
    public var zoomFactor: Int              // 2，范围 2～10
    public var zoomAnchor: ZoomAnchor       // nw
    public var snapEnabled: Bool            // true
    public var lockAspectRatio: Bool        // false
}
public enum ZoomAnchor: String, Sendable, Codable, CaseIterable { case nw, n, ne, w, center, e, sw, s, se }
public struct OverlaySettings: Sendable, Equatable, Codable {
    public var showTitle: Bool              // true
    public var titleFontSize: Double        // 新增。12，范围 8～36
    public var titleColor: String           // "#FFFFFF"
    public var highlightEnabled: Bool       // false
    public var highlightColor: String       // "#ADFF2F"
    public var highlightThickness: Int      // 3，范围 1～6
    public var borderEnabled: Bool          // 第一轮反馈新增。true
    public var borderColor: String          // 第一轮反馈新增。"#C0C0C0"
    public var borderThickness: Int         // 第一轮反馈新增。2，范围 1～6
}
public struct BehaviorSettings: Sendable, Equatable, Codable {
    public var alwaysOnTop: Bool                  // true
    public var hideActiveClientThumbnail: Bool    // false
    public var hideWhenEVENotFrontmost: Bool      // false
    public var hideDelaySeconds: Double           // 1.0，范围 0～10
    public var lockLayout: Bool                   // 新增。false
}
public struct CaptureSettings: Sendable, Equatable, Codable {
    public var frameRate: Int               // 新增。15，范围 1～60
    public var titleBarCropHeight: Double   // 新增。28，范围 0～60，单位是点；0 表示不裁
}
public struct ThumbnailLayout: Sendable, Equatable, Codable {
    public var x: Double; public var y: Double
    public var width: Double?; public var height: Double?   // nil：用 defaultSize
}
public struct CycleGroup: Sendable, Equatable, Codable, Identifiable {
    public var id: String; public var name: String
    public var forwardHotkeys: [String]; public var backwardHotkeys: [String]
    public var members: [String]            // 角色名，按循环顺序
}
public struct GeneralHotkeys: Sendable, Equatable, Codable {
    public var toggleHideAll: [String]; public var minimizeAll: [String]; public var cycleLoginClients: [String]
}
```

热键在配置里存字符串（语法见 5.5 节），解析失败的字符串原样保留，在设置窗口里报告。
第一轮反馈新增的键、默认值与范围列在反馈文档 3.1 节。新增的键都有默认值，`schemaVersion` 仍是 1。`AppLanguage`、`LanguagePreference`、`CombatAlertSettings`、`HotkeyScope` 的定义也在反馈文档。
以字符串为原始值的新枚举键用 `LenientDecoding` 解码，遇到不认识的值取默认值，不让整个文件被当成损坏文件（反馈文档 3.2 节）。

```swift
// [Core] Contracts/ConfigStore.swift 与 Config/*.swift
public enum ConfigWarning: Sendable, Equatable {
    case createdDefault
    case migrated(from: Int, to: Int)
    case corruptFileQuarantined(path: String)
    case valuesClamped([String])            // 被改正的字段路径
}
public enum ConfigFileOperation: String, Sendable, Equatable { case read, write, quarantine, backup }
public enum ConfigError: Error, Sendable, Equatable {
    case newerSchema(found: Int, supported: Int)
    case ioFailure(ConfigFileOperation, path: String, reason: String)   // 出错的步骤、文件路径、系统给出的说明
    case encodingFailure(String)            // 技术说明，只写日志，界面不显示
}
public struct ConfigLoadResult: Sendable { public var config: AppConfig; public var warnings: [ConfigWarning] }
public protocol ConfigStore: Sendable {
    var fileURL: URL { get }
    func load() throws(ConfigError) -> ConfigLoadResult
    func save(_ config: AppConfig) throws(ConfigError)
}
public struct JSONFileConfigStore: ConfigStore {
    public let fileURL: URL
    public init(fileURL: URL)
    public static func defaultFileURL() -> URL
    public func load() throws(ConfigError) -> ConfigLoadResult
    public func save(_ config: AppConfig) throws(ConfigError)
}
public enum ConfigMigrator {
    public static let currentSchemaVersion = 1
    /// 读出 schemaVersion，逐版本升级到当前版本后解码。
    public static func decode(_ data: Data) throws(ConfigError) -> (config: AppConfig, migratedFrom: Int?)
}
public enum ConfigValidator {
    /// 把越界值夹回范围，保证至少 1 个配置方案、activeProfileID 有效、id 与名称唯一。
    public static func normalized(_ config: AppConfig) -> (config: AppConfig, clamped: [String])
}
public enum ProfileEditor {
    public static func isValidName(_ name: String, in config: AppConfig, excluding id: String?) -> Bool
    public static func add(named name: String, to config: AppConfig) -> AppConfig?
    public static func clone(id: String, newName: String, in config: AppConfig) -> AppConfig?
    public static func rename(id: String, to name: String, in config: AppConfig) -> AppConfig?
    public static func delete(id: String, in config: AppConfig) -> AppConfig?   // 最后一个不能删
}
```

`load()` 的语义：

| 情况 | 行为 |
| --- | --- |
| 文件不存在 | 返回默认配置（一个名为 `Default` 的配置方案），警告 `createdDefault`，不立即写盘 |
| JSON 损坏或结构不符 | 把原文件改名为 `config.corrupt-<yyyyMMdd-HHmmss>.json`，返回默认配置，警告 `corruptFileQuarantined` |
| `schemaVersion` 小于当前版本 | 先把原文件复制为 `config.v<旧版本>.bak.json`，再迁移，警告 `migrated` |
| `schemaVersion` 大于当前版本 | 抛 `newerSchema`。应用用默认配置运行，本次会话不写盘，并在设置窗口提示 |
| 读文件失败 | 抛 `ioFailure(.read, …)`。隔离损坏文件失败抛 `ioFailure(.quarantine, …)`，迁移前备份失败抛 `ioFailure(.backup, …)`；设置窗口按步骤显示本地化的说明 |

`save()` 用 `JSONEncoder`（`prettyPrinted`、`sortedKeys`）编码，以原子方式写入。未知的键在下次保存时丢失。
App 的 `ConfigController` 在改动后 0.5 秒写盘，退出前立即写一次。

### 5.3 客户端发现

```swift
// [Core] Clients/*.swift
public enum TitleParser {
    public static func identity(fromTitle title: String?) -> ClientIdentity
    public static func title(for identity: ClientIdentity, pid: Int32) -> String
}
public enum ClientWindowSelector {
    /// 每个 PID 选出一个主窗口。输入是该 bundle id 下全部 layer 0 窗口。
    public static func mainWindows(from candidates: [WindowInfo]) -> [WindowInfo]
}
public struct ClientRegistry: Sendable {
    public private(set) var clients: [EVEClient]      // 按首次发现的顺序
    public init()
    public mutating func update(with mainWindows: [WindowInfo]) -> RegistryDiff
}
```

- `TitleParser.identity`：去掉首尾空白后，等于 `EVE`（不区分大小写）是 `.login`；以 `EVE - ` 开头且后面非空是 `.character(后面的部分)`；`nil`、空串和其他情况是 `.unknown`。
- `TitleParser.title`：角色返回角色名，登录返回 `EVE`，未知返回 `EVE (<pid>)`。
- `ClientWindowSelector.mainWindows`：同一 PID 下，先取标题能解析成角色或登录的窗口；没有时取面积最大且不小于 640×360 的窗口；都没有则该 PID 本轮不产生客户端。多个候选时取面积最大的，再取窗口 ID 最小的。
- `ClientRegistry.update`：按窗口 ID 做差异。新 ID 进 `added`，消失的进 `removed`，`identity` 变化进 `renamed`，其余字段变化进 `updated`。

### 5.4 布局、吸附、缩放、循环

```swift
// [Core] Layout/*.swift 与 Switching/CycleEngine.swift
public struct ResolvedLayout: Sendable, Equatable { public var frame: ScreenRect; public var isAutoPlaced: Bool }
public enum LayoutResolver {
    /// 取客户端缩略图的基准 frame（不含悬停放大）。occupied 是本轮已分配的 frame。
    public static func frame(for client: EVEClient, loginIndex: Int, profile: Profile,
                             screens: [ScreenInfo], occupied: [ScreenRect]) -> ResolvedLayout
    public static func clampSize(_ size: ScreenSize, settings: ThumbnailSettings, aspectRatio: Double?) -> ScreenSize
    public static func clampToScreens(_ rect: ScreenRect, screens: [ScreenInfo], minimumVisible: Double) -> ScreenRect
}
public struct SnapTargets: Sendable, Equatable {
    public var neighbors: [ScreenRect]      // 其他可见缩略图
    public var screens: [ScreenRect]        // 每块屏幕的 frame 与 visibleFrame
}
public struct ResizeEdges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let left = ResizeEdges(rawValue: 1), right = ResizeEdges(rawValue: 2)
    public static let top = ResizeEdges(rawValue: 4), bottom = ResizeEdges(rawValue: 8)
}
public struct SnapResult: Sendable, Equatable {
    public var rect: ScreenRect
    public var snappedX: Double?; public var snappedY: Double?   // 对齐到的边的坐标，供以后画参考线
}
public enum SnapEngine {
    public static let defaultThreshold = 8.0
    public static func snapMove(proposed: ScreenRect, targets: SnapTargets, threshold: Double) -> SnapResult
    public static func snapResize(proposed: ScreenRect, movingEdges: ResizeEdges, targets: SnapTargets,
                                  threshold: Double, minimum: ScreenSize, maximum: ScreenSize,
                                  aspectRatio: Double?) -> SnapResult
    public static func resizeEdges(at point: ScreenPoint, in rect: ScreenRect, margin: Double) -> ResizeEdges
}
public enum ZoomMath {
    public static func zoomedFrame(base: ScreenRect, factor: Int, anchor: ZoomAnchor) -> ScreenRect
}
public enum CycleDirection: Sendable, Hashable { case forward, backward }
public enum CycleEngine {
    public static func next(in members: [String], direction: CycleDirection, active: String?,
                            running: Set<String>, skipped: Set<String>) -> String?
    public static func nextLoginClient(pids: [Int32], activePID: Int32?, direction: CycleDirection) -> Int32?
}
```

`LayoutResolver.frame` 的规则：

1. 角色在 `profile.layouts` 里有记录：用记录的位置；宽高为 `nil` 时用 `defaultSize`；尺寸经 `clampSize`；`isAutoPlaced = false`。
2. 角色没有记录：在主屏 `visibleFrame` 内从左上角起向下排，边距 16 点，间距 8 点。排满换下一列，跳过与 `occupied` 相交的格子，`isAutoPlaced = true`。规划器把自动分配的位置放进 `layoutsToPersist`，以后位置固定。
3. 登录或未知的客户端：`loginPosition` 加 `(24 × loginIndex, 24 × loginIndex)`，尺寸用 `defaultSize`，不持久化。`loginIndex` 是该客户端在这类客户端里按 PID 升序的序号。
4. 结果都经过 `clampToScreens(_, screens, minimumVisible: 32)`：缩略图在任何屏幕上的可见部分不足 32 点时，把它移回最近的屏幕内。显示器拔掉后缩略图不会留在屏幕外。

`SnapEngine` 的规则：

- 输入的 `proposed` 由「拖动起点的 frame + 鼠标的原始位移」算出，不由上一次吸附后的位置累加。鼠标移出阈值后缩略图自然脱离，不另设状态。
- x 轴与 y 轴各自独立，在阈值内取最近的目标边。可对齐的组合是：左对左、左对右、右对左、右对右，y 轴同理。
- 邻居只在另一轴上有重叠或间隔不超过阈值时才参与，远处的行和列不吸附。屏幕的 4 条边始终参与。
- `snapResize` 只移动 `movingEdges` 里的边，对边不动。先吸附，再按 `minimum`、`maximum` 和 `aspectRatio` 约束，约束优先于吸附。
- `aspectRatio` 的取值：`lockAspectRatio` 打开或按住 Shift 时是拖动开始时的宽高比，否则是 `nil`。按住 Shift 时不调用吸附。

`ZoomMath.zoomedFrame`：宽高乘以 `factor`，`anchor` 指定的那个点保持不动（`nw` 表示左上角不动，`center` 表示中心不动）。放大后的尺寸不受 `maximumSize` 限制。

`CycleEngine.next` 的语义与上游的 `FindNextClientInCycleGroup` 相同：

- 在 `members` 里从 `active` 的位置按方向找下一个同时满足「在 `running` 里」和「不在 `skipped` 里」的成员，绕回一次。
- `active` 不在 `members` 里时，从该方向的第一个成员开始找。
- `active` 自己被跳过时，仍以它的位置为起点。
- 没有符合条件的成员时返回 `nil`；唯一符合条件的成员就是 `active` 时返回它自己。
- `ConfigValidator` 去掉 `members` 里的重复项（保留第一次出现的位置），所以引擎不处理重复成员。2026-11-20 按测试发现改定：原规则下重复成员会让后面的成员永远轮不到。

`nextLoginClient`：`pids` 升序排列，从 `activePID` 的位置按方向取下一个并绕回；`activePID` 不在其中时取该方向的第一个；空数组返回 `nil`。

### 5.5 热键

```swift
// [Core] Hotkeys/*.swift
public struct HotkeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let command = HotkeyModifiers(rawValue: 1), option = HotkeyModifiers(rawValue: 2)
    public static let control = HotkeyModifiers(rawValue: 4), shift = HotkeyModifiers(rawValue: 8)
}
public enum HotkeyTrigger: Sendable, Hashable {
    case key(UInt16)                        // Carbon 虚拟键码（kVK_*），按键位而不按字符
    case mouseButton(Int)                   // CGEvent 的按钮号，2～31（第一轮反馈新增）
}
public struct Hotkey: Sendable, Hashable {
    public var trigger: HotkeyTrigger
    public var modifiers: HotkeyModifiers
    public init(trigger: HotkeyTrigger, modifiers: HotkeyModifiers)
    public init(keyCode: UInt16, modifiers: HotkeyModifiers)
    public init?(mouseButton: Int, modifiers: HotkeyModifiers)
    public init?(string: String)
    public var keyCode: UInt16? { get }     // 鼠标触发键返回 nil
    public var mouseButton: Int? { get }    // 键盘触发键返回 nil
    public var isMouse: Bool { get }
    public func stringValue() -> String     // 规范写法，如 "ctrl+shift+F13"、"ctrl+Mouse4"
    public func displayString() -> String   // 界面写法，如 "⌃⇧F13"
}
public enum HotkeyScope: String, Sendable, Codable, CaseIterable { case global, game }
/// 配置里一条热键字符串的解析结果：热键加可选的作用范围后缀（"@global"、"@game"）。
public struct HotkeySpec: Sendable, Hashable {
    public var hotkey: Hotkey
    public var scope: HotkeyScope?          // nil：跟随 Profile.hotkeyDefaultScope
    public init(hotkey: Hotkey, scope: HotkeyScope? = nil)
    public init?(string: String)
    public func stringValue() -> String
    public func resolvedScope(profileDefault: HotkeyScope) -> HotkeyScope
}
public enum KeyCodeTable {
    public static func name(for keyCode: UInt16) -> String?
    public static func keyCode(for name: String) -> UInt16?
}
public enum HotkeyAction: Sendable, Hashable {
    case cycle(groupID: String, direction: CycleDirection)
    case activateCharacter(String)
    case cycleLoginClients, toggleHideAll, minimizeAll
}
public struct HotkeyBinding: Sendable, Hashable, Identifiable {
    public var id: UInt32; public var hotkey: Hotkey; public var action: HotkeyAction
    public var scope: HotkeyScope           // 已解析的作用范围（第一轮反馈新增）
}
public enum HotkeyRejection: Sendable, Equatable { case missingModifier, systemReserved }
public enum HotkeyIssue: Sendable, Equatable {
    case unparsable(text: String, action: HotkeyAction)
    case duplicate(hotkey: Hotkey, kept: HotkeyAction, dropped: HotkeyAction)
    case rejected(hotkey: Hotkey, action: HotkeyAction, reason: HotkeyRejection)
}
public struct HotkeyPlan: Sendable, Equatable { public var bindings: [HotkeyBinding]; public var issues: [HotkeyIssue] }
public enum HotkeyPlanner {
    public static func plan(for profile: Profile) -> HotkeyPlan
}
```

- 字符串语法：用 `+` 连接，不区分大小写。修饰键是 `ctrl`、`opt`（别名 `alt`）、`shift`、`cmd`，最后一段是键名。键名取自 `KeyCodeTable`：`A`～`Z`、`0`～`9`、`F1`～`F20`、`Num0`～`Num9`、`Tab`、`Space`、`Return`、`Escape`、`Delete`、`Left`、`Right`、`Up`、`Down`、`Home`、`End`、`PageUp`、`PageDown`、`Grave`、`Minus`、`Equal`、`LeftBracket`、`RightBracket`、`Backslash`、`Semicolon`、`Quote`、`Comma`、`Period`、`Slash`。表里没有的键写成 `Key<键码>`，如 `Key105`。
- `stringValue()` 的输出顺序固定为 `ctrl+opt+shift+cmd+键名`。
- 第一轮反馈的扩展：最后一段可以是 `Mouse3`～`Mouse32`（鼠标的中键、侧键与其他附加按键）；整条字符串可以带 `@global` 或 `@game` 后缀指定作用范围。语法、按钮号对照和规划规则见反馈文档 6.1～6.3 节。
- `HotkeyPlanner.plan` 的遍历顺序：`hotkeys.toggleHideAll`、`minimizeAll`、`cycleLoginClients`，然后按 `cycleGroups` 的顺序（每组先前进后后退），最后是按角色名排序的 `characterHotkeys`。`id` 从 1 起按这个顺序编号。
- 同一个热键出现多次时，先出现的生效，后出现的记为 `duplicate`。判断只看触发键与修饰键，不看作用范围。
- `missingModifier`：键盘触发键没有 `ctrl`、`opt`、`cmd` 之一时，只允许 `F1`～`F20` 和 `Num0`～`Num9`。鼠标触发键不受这一条限制。
- `systemReserved`：`cmd+Tab`、`cmd+Space`、`cmd+Q`、`cmd+W`、`cmd+H`、`cmd+M`、`cmd+Grave`，以及它们加 `shift` 的组合（E10）。

### 5.6 规划器

```swift
// [Core] Planning/*.swift 与 Layout/CaptureMath.swift
public struct PlannerInput: Sendable {
    public var clients: [EVEClient]
    public var frontmost: FrontmostContext
    public var profile: Profile
    public var session: SessionState
    public var screens: [ScreenInfo]
    public var permissions: PermissionStatus
    public var captureStates: [WindowID: CaptureState]
    public var now: Double                  // 单调时钟的秒数
}
public enum ThumbnailPlaceholder: Sendable, Equatable {
    case none, waitingForFrame, needsScreenRecording, captureStopped, minimized
}
public struct ThumbnailPresentation: Sendable, Equatable, Identifiable {
    public var id: WindowID; public var pid: Int32
    public var frame: ScreenRect            // 已含悬停放大
    public var isVisible: Bool
    public var title: String; public var showsTitle: Bool; public var titleFontSize: Double; public var titleColor: String
    public var opacity: Double
    public var highlightColor: String?      // nil：不画高亮
    public var highlightThickness: Double
    public var borderColor: String?         // nil：不画中性边框（第一轮反馈新增）
    public var borderThickness: Double
    public var alert: ThumbnailAlert?       // nil：没有战斗提醒（第一轮反馈新增）
    public var isActive: Bool; public var isSkipped: Bool; public var isAlwaysOnTop: Bool; public var isZoomed: Bool
    public var contentsRect: UnitRect
    public var placeholder: ThumbnailPlaceholder
}
public struct ThumbnailAlert: Sendable, Equatable { public var color: String; public var style: CombatAlertStyle }
public struct ThumbnailPlan: Sendable, Equatable {
    public var presentations: [ThumbnailPresentation]     // 顺序同 clients
    public var captures: [WindowID: CaptureSpec]          // 只含要捕获的窗口
    public var layoutsToPersist: [String: ThumbnailLayout]
    public var nextWakeAt: Double?
}
public enum ThumbnailPlanner {
    public static func plan(_ input: PlannerInput) -> ThumbnailPlan
}
public enum VisibilityRules {
    public static func isVisible(client: EVEClient, input: PlannerInput) -> Bool
    public static func hideDeadline(input: PlannerInput) -> Double?
}
public enum CaptureMath {
    public static func spec(thumbnailSize: ScreenSize, sourceSize: ScreenSize, scale: Double, frameRate: Int) -> CaptureSpec
    public static func contentsRect(sourceSize: ScreenSize, titleBarCropHeight: Double) -> UnitRect
}
public enum RetryPolicy {
    public static func delay(forAttempt attempt: Int) -> Double    // 0.5、1、2、4、8，之后一直是 8 秒
}
public enum HexColor {
    public static func components(_ text: String) -> (red: Double, green: Double, blue: Double)?
}
```

可见性：以下条件都不成立时缩略图可见。

1. `session.hideAll` 为真。
2. 角色名在 `profile.hiddenCharacters` 里。
3. `hideActiveClientThumbnail` 为真，且 `frontmost == .client(pid: 该客户端的 pid)`。
4. `hideWhenEVENotFrontmost` 为真，`frontmost == .other`，且 `now - session.lastEVEContextAt >= hideDelaySeconds`。

第 4 条尚未到期时，`hideDeadline` 返回到期时刻，规划器把它放进 `nextWakeAt`。
有未到期战斗提醒的客户端不受第 4 条影响；`nextWakeAt` 取隐藏期限与最早的提醒到期时刻中较小的一个（反馈文档 7.7 节）。

呈现：

- `isActive`：`frontmost == .client(pid:)` 且 PID 相同。前台是 `.selfApp` 或 `.other` 时，用 `session.lastActivePID` 判断，所以切到别的应用后高亮仍留在最后活动的客户端上。
- `highlightColor`：`highlightEnabled` 且 `isActive` 时，取 `highlightColors[角色名]`，没有则取 `overlay.highlightColor`。
- `borderColor`：`overlay.borderEnabled` 为真时取 `overlay.borderColor`，否则为 `nil`。视图先用高亮，没有高亮时用边框（反馈文档 4.1 节）。
- `alert`：该窗口在 `session.combatAlerts` 里有未到期的提醒时，取 `combatAlert` 的颜色与样式。
- `opacity`：悬停或有战斗提醒时为 1.0，否则取 `thumbnail.opacity`。
- `frame`：在 `interactingWindows` 里的窗口沿用基准 frame，不放大。悬停且 `zoomEnabled` 时取 `ZoomMath.zoomedFrame`，`isZoomed = true`。
- `placeholder` 按以下顺序取第一个成立的：没有屏幕录制权限或状态是 `permissionDenied`，取 `needsScreenRecording`；状态是 `stoppedByUser`，取 `captureStopped`；`isMinimized == true`，取 `minimized`；状态是 `idle`、`starting` 或 `retrying`，取 `waitingForFrame`；否则取 `none`。面板已有画面时，`waitingForFrame` 不遮住它。
- `contentsRect`：`CaptureMath.contentsRect`，从画面顶部裁掉 `titleBarCropHeight` 点。源窗口高度不小于所在屏幕高度时不裁（全屏窗口没有标题栏）。v1.1.1 起 `EVEClient.isFullScreen` 为真时同样不裁：原生全屏的窗口范围不含菜单栏那一条，按高度判断会漏掉。

捕获规格：只给可见的缩略图生成。`scale` 取缩略图中心点所在屏幕的值。`CaptureMath.spec` 的宽是 `缩略图宽 × scale`，高按源窗口的宽高比算出，两者都不超过源窗口的像素尺寸，且都向上取到偶数。没有屏幕录制权限时 `captures` 为空。

## 6 Platform 契约与设计

### 6.1 协议

v1.1 起 `PlatformServices` 新增 `diagnostics`（`DiagnosticsService`）与 `updates`（`UpdateService`）两个成员，协议定义在 Core 的 `Contracts/DiagnosticsContracts.swift` 与 `Contracts/UpdateContracts.swift`（v1.1 设计第 4 节）。

以下协议只含值类型，定义在 Core 的 `Contracts/PlatformContracts.swift`，由 Platform 实现。

```swift
// [Core] Contracts/PlatformContracts.swift
public protocol WindowProvider: Sendable {
    /// 返回 EVE 客户端进程的全部 layer 0 窗口。出错时返回空数组并记日志，不抛错。
    func candidateWindows() async -> [WindowInfo]
}
public enum WorkspaceEvent: Sendable, Equatable {
    case frontmostChanged, applicationsChanged, screensChanged, activeSpaceChanged, didWake
}
@MainActor public protocol WorkspaceObserver: AnyObject {
    func start(handler: @escaping @MainActor (WorkspaceEvent) -> Void)
    func stop()
    func frontmost(among clientPIDs: [Int32]) -> FrontmostContext
    func screens() -> [ScreenInfo]
}
public enum ActivationError: Error, Sendable, Equatable {
    case processGone, windowNotFound, accessibilityDenied, notFrontmostAfterTimeout
    case axFailure(code: Int32)
}
public enum ActivationOutcome: Sendable, Equatable {
    case activated                           // 目标已到前台
    case activatedAppOnly(ActivationError)   // 进程已激活，但窗口没能还原或提升
    case failed(ActivationError)
}
@MainActor public protocol WindowActivator: AnyObject {
    func activate(_ target: ClientTarget) async -> ActivationOutcome
    func minimize(_ target: ClientTarget) async -> Result<Void, ActivationError>
}
public enum PermissionPane: Sendable { case screenRecording, accessibility, filesAndFolders }
@MainActor public protocol PermissionService: AnyObject {
    func status() -> PermissionStatus
    @discardableResult func requestScreenRecording() -> Bool
    func requestAccessibility()
    func openSystemSettings(_ pane: PermissionPane)
    func relaunch()
}
public enum HotkeyFailureReason: Sendable, Equatable {
    case registrationRejected(status: Int32)    // Carbon 的 RegisterEventHotKey 返回错误
    case accessibilityRequired                  // 鼠标绑定：没有辅助功能权限
    case eventTapUnavailable                    // 鼠标绑定：系统没有建出事件监听
}
public struct HotkeyRegistrationFailure: Sendable, Equatable {
    public var binding: HotkeyBinding; public var reason: HotkeyFailureReason
}
@MainActor public protocol HotkeyRegistrar: AnyObject {
    var onHotkey: (@MainActor (HotkeyBinding.ID) -> Void)? { get set }
    /// 先停用全部旧绑定，再按当前的前台状态启用新绑定。返回失败的项。
    @discardableResult func replaceAll(with bindings: [HotkeyBinding]) -> [HotkeyRegistrationFailure]
    /// 告知前台是不是 EVE 客户端；值变化时启用或停用作用范围是 game 的绑定（第一轮反馈新增）。
    @discardableResult func setGameFrontmost(_ isFrontmost: Bool) -> [HotkeyRegistrationFailure]
    func suspend()      // 录制热键期间暂停，否则组合键被自己吞掉；应用退出时也暂停
    /// 重新注册暂停前的绑定，返回注册失败的项（2026-11-20 按审查意见增加返回值）。
    @discardableResult func resume() -> [HotkeyRegistrationFailure]
    /// 注册器自己发现失败项可能变了时在主线程调用（如鼠标事件监听被系统关掉、没能重新打开）。
    var onStateChange: (@MainActor () -> Void)? { get set }
    /// 巡检：后端没有按预期工作时拆除并记为失败，监听不可用的失败项定时重试；返回当前全部失败的项。
    /// 协调器每个轮询周期调用一次。
    @discardableResult func checkHealth() -> [HotkeyRegistrationFailure]
}
/// 游戏日志的跟踪服务（第一轮反馈新增，事件与状态类型见反馈文档 7.2 节）。
@MainActor public protocol CombatLogMonitor: AnyObject {
    var onEvents: (@MainActor ([CombatLogEvent]) -> Void)? { get set }
    var onStatusChange: (@MainActor (CombatLogStatus) -> Void)? { get set }
    var status: CombatLogStatus { get }
    func start(directory: String?)
    func stop()
}
```

捕获协议带 `IOSurface`，定义在 Platform。

```swift
// [Platform] Capture/CaptureTypes.swift 与 PlatformServices.swift
import AppKit
import IOSurface
import EVEOPreviewCore

public struct CapturedFrame: @unchecked Sendable {
    public let surface: IOSurface
    public let contentRect: CGRect          // 画面在 surface 里的位置，单位是像素
}
@MainActor public protocol CaptureService: AnyObject {
    var onFrame: (@MainActor (WindowID, CapturedFrame) -> Void)? { get set }
    var onStateChange: (@MainActor (WindowID, CaptureState) -> Void)? { get set }
    /// 声明式对账。desired 是要捕获的窗口及规格；liveWindows 是仍然存在的窗口。
    func reconcile(_ desired: [WindowID: CaptureSpec], liveWindows: Set<WindowID>)
    /// 用户在菜单里选「恢复捕获」后调用，清除 stoppedByUser 状态并重启。
    func resume(_ window: WindowID)
    /// 系统唤醒后重启处于 starting、running、retrying 的会话（2026-11-20 增加，见 6.6 节）。
    func restartActiveSessions()
    func stopAll() async
}
@MainActor public struct PlatformServices {
    public let windows: any WindowProvider
    public let workspace: any WorkspaceObserver
    public let activator: any WindowActivator
    public let hotkeys: any HotkeyRegistrar
    public let permissions: any PermissionService
    public let capture: any CaptureService
    public let combatLog: any CombatLogMonitor     // 第一轮反馈新增
    public static func makeLive() -> PlatformServices
}
```

### 6.2 窗口枚举

`CGWindowProvider`（`actor`）每次调用做以下事情：

1. 调 `CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)`。
2. 只留 `ClientWindowSelector.isCandidateLayer` 认可的窗口：`kCGWindowLayer == 0`，或层级在 1～25（状态栏层级）且不透明。v1.1.1 起加后一种：EVE 原生全屏时，前台客户端的主窗口在 layer 25，只认 layer 0 时它会从列表里消失、缩略图跟着收起。对每个 `kCGWindowOwnerPID`，用 `NSRunningApplication(processIdentifier:)?.bundleIdentifier` 判断是不是 `com.ccpgames.eveonline`，肯定结果按 PID 缓存到 PID 消失；否定结果缓存 30 秒；取不到 bundle id 时不缓存，下一轮重查。
3. 填 `WindowInfo`：`title` 取 `kCGWindowName`，空串记为 `nil`；`frame` 取 `kCGWindowBounds`；`isOnScreen` 取 `kCGWindowIsOnscreen`，缺失记为 `false`。
4. 如果有辅助功能权限，经 `AXWorker` 读每个 PID 的 AX 窗口的 `kAXTitleAttribute` 与 `kAXMinimizedAttribute`。结果写到该 PID 下标题相同的窗口；没有标题相同的窗口时，写到面积最大的窗口（补上 `title`，填 `isMinimized`）。AX 超时或失败时保留上一轮的值。

App 按 `general.pollIntervalMs` 调用它，收到 `applicationsChanged` 时立即加调一次。上一次调用还没返回时跳过本轮。
登录后标题从 `EVE` 变成 `EVE - <角色名>`，最迟在一个轮询周期后被发现。

### 6.3 捕获

每个要捕获的窗口对应一个 `WindowCaptureSession`，各持有一条 `SCStream`。

流的建立：

1. 从 `ShareableContentCache` 取窗口 ID 对应的 `SCWindow`。缓存里没有时调一次 `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)`；并发的请求合并成一次，两次调用至少间隔 1 秒（E8）。
2. 用 `SCContentFilter(desktopIndependentWindow:)` 建过滤器。
3. `SCStreamConfiguration` 的取值见下表。
4. `addStreamOutput(_, type: .screen, sampleHandlerQueue:)` 用每条流自己的串行队列，然后 `startCapture()`。

| 属性 | 取值 |
| --- | --- |
| `width`、`height` | `CaptureSpec.pixelWidth`、`pixelHeight` |
| `minimumFrameInterval` | `CMTime(value: 1, timescale: framesPerSecond)` |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` |
| `colorSpaceName` | `CGColorSpace.sRGB` |
| `queueDepth` | 3 |
| `showsCursor` | `false` |
| `scalesToFit` | `true` |
| `capturesAudio` | `false` |
| `ignoreShadowsSingleWindow` | `true` |
| `shouldBeOpaque` | `true` |

帧的处理（`StreamOutputHandler`，在流的队列上）：

1. 读 `SCStreamFrameInfo.status`。只有 `.complete` 的帧带画面；其他状态只更新「最近一次回调时刻」。
2. 取 `sampleBuffer.imageBuffer`，再用 `CVPixelBufferGetIOSurface` 取出 `IOSurface`，连同 `SCStreamFrameInfo.contentRect` 装成 `CapturedFrame`。
3. 放进「最新一帧」槽位。槽位原本为空时，向主线程派发一次；主线程取走槽位里的帧并调 `onFrame`。主线程忙时，中间的帧被后来的帧覆盖。

显示（App，主线程）：`imageLayer.contents = frame.surface`，`contentsGravity = .resize`，画面拉伸填满缩略图（与上游一致）。`contentsRect` 由 `frame.contentRect` 归一化后与规划器给的 `contentsRect` 复合得到。图层关闭隐式动画。

规格变化：缩略图尺寸、悬停放大、源窗口尺寸、所在屏幕的 scale 变化都会让规划器给出新的 `CaptureSpec`。`reconcile` 发现规格不同后等 150 毫秒，再调 `updateConfiguration`，期间的多次变化合并成一次。画面在更新完成前由图层拉伸显示。

`reconcile` 的规则：

| 窗口的情况 | 行为 |
| --- | --- |
| 在 `desired` 里，没有会话 | 建会话，状态 `starting` |
| 在 `desired` 里，规格变了 | 150 毫秒后 `updateConfiguration` |
| 不在 `desired` 里，但在 `liveWindows` 里（缩略图被隐藏） | 3 秒后停流；3 秒内回到 `desired` 则取消。最后一帧留在图层上 |
| 不在 `liveWindows` 里 | 立即停流并销毁会话，状态 `windowGone` |

错误与重启：

| 情况 | 处理 |
| --- | --- |
| `startCapture` 失败，或 `didStopWithError` 收到下面没列出的错误 | 状态 `retrying`，按 `RetryPolicy` 的延迟重建会话；连续运行 30 秒后重试计数清零 |
| 错误码 `.userDeclined` | 状态 `permissionDenied`，不重试；`reconcile` 在权限恢复前不再建会话 |
| 错误码 `.userStopped`（用户在系统的录制指示器里点了停止） | 状态 `stoppedByUser`，不重试，等 `resume(_:)` |
| `SCWindow` 查不到 | 当作可重试的错误；窗口不在 `liveWindows` 里时销毁 |
| 运行中超过 5 秒没有任何回调，且窗口 `isOnScreen` 为真 | 重建会话（V5） |

窗口最小化或在别的空间时不重启流，保留最后一帧；`isMinimized == true` 时由规划器给出 `minimized` 占位（V4）。

能耗：

- 捕获分辨率跟随缩略图，不跟随源窗口。384×216 点、scale 2.0 时每帧是 768×432 像素。
- ScreenCaptureKit 只在画面变化时产出 `.complete` 帧，静止的客户端不产生图层更新。
- 隐藏的缩略图 3 秒后停流。全部隐藏时没有任何流在运行。
- 默认 15 帧每秒。帧率在设置里可调，上限 60。

### 6.4 窗口激活

macOS 14 起应用激活是协作式的，系统不保证后台应用的激活请求被接受。点击缩略图和按热键时，本应用通常不在前台。这是本项目风险最高的部分，WP-B 应先做 6.7 节的实测，再定最终顺序。下面是设计的起点。

`SystemWindowActivator.activate(_:)` 的步骤：

1. 取 `NSRunningApplication(processIdentifier: target.pid)`。取不到返回 `.failed(.processGone)`。
2. 如果本应用在前台，先调 `NSApp.yieldActivation(to:)`。
3. 调激活：macOS 15 及以上用 `activate(from: NSRunningApplication.current, options: [])`，macOS 14 用 `activate(options: [])`。这一步在主线程立即发出，不等 AX。
4. 如果有辅助功能权限，同时让 `AXWorker` 做：取该 PID 的 AX 窗口；`kAXMinimizedAttribute` 为真时设为假；执行 `kAXRaiseAction`；把窗口的 `kAXMainAttribute` 设为真；把应用元素的 `kAXFrontmostAttribute` 设为真。
5. 100 毫秒后用 `frontmost(among:)` 的同一办法核对。目标不在前台时重做第 3 步一次，300 毫秒后再核对。
新的激活开始时，`AXWorker` 的请求计数加一；旧请求在每次 AX 写操作前核对计数，已被取代时停止并返回 `.superseded`，不再把旧目标提到前面，协调器忽略这类结果。

6. 结果：目标在前台返回 `.activated`；在前台但第 4 步失败或没有权限，返回 `.activatedAppOnly`；仍不在前台返回 `.failed(.notFrontmostAfterTimeout)`。

没有辅助功能权限时只有第 1～3 步和第 5 步。因为每个客户端是独立进程且只有一个主窗口（E4、E7），激活进程就能把窗口带到前面，只有已最小化的窗口还原不了。

`minimize(_:)` 经 `AXWorker` 把窗口的 `kAXMinimizedAttribute` 设为真；没有权限返回 `.failure(.accessibilityDenied)`。

用户已同意（Q2）把私有接口 `_SLPSSetFrontProcessWithOptions` 作为后备：第 5 步核对仍不在前台时，用 `GetProcessForPID` 取 `ProcessSerialNumber`，经 `dlsym` 在 SkyLight 框架里查找该符号并调用（`kCPSUserGenerated`），再核对一次。符号查找失败时跳过这一步，不崩溃。后备方案放在 `Windows/PrivateActivation.swift` 一个文件里，便于以后移除。

v1.1.1 起，AX 窗口列表为空时（窗口在其他空间里，典型情况是原生全屏的客户端），`AXWorker` 改取应用的 `kAXMainWindowAttribute`：它不受空间限制，角色是 `AXWindow` 且标题相同时，照常还原、提升，系统随之切到窗口所在的空间（实测 2026-11-21，只用公开接口）。读窗口状态时同时读 `AXFullScreen`，写进 `WindowInfo.isFullScreen` 与 `EVEClient.isFullScreen`；读不到时沿用上一轮的值。没有辅助功能权限时，窗口列表里 layer 大于 0 的主窗口（前台的全屏窗口在 layer 25）也记为全屏。主窗口不比标题，只要求角色是 `AXWindow`。曾试过 `SLPSPostEventRecordTo` 与 `_AXUIElementCreateWithRemoteToken` 的做法，前者实际是向目标窗口发一次合成的鼠标点击，不符合 R7，已放弃。

### 6.5 热键

第一轮反馈之后，`HotkeyRegistrar` 的实现是 `SystemHotkeyRegistrar`。它把键盘绑定交给 `CarbonHotkeyRegistrar`，把鼠标绑定交给 `MouseEventTap`，并按前台状态启用或停用作用范围是 `game` 的绑定（反馈文档 6.5、6.6 节）。下面是键盘部分。

`CarbonHotkeyRegistrar` 是键盘后端，不再实现 `HotkeyRegistrar` 协议。绑定表、暂停状态和「哪些绑定应启用」都由 `SystemHotkeyRegistrar` 管，它只负责向 Carbon 注册和注销：

- 初始化时用 `InstallEventHandler(GetApplicationEventTarget(), …)` 装一个处理器，事件类型是 `kEventClassKeyboard` / `kEventHotKeyPressed`。回调里用 `GetEventParameter` 取 `EventHotKeyID`，再在 `MainActor.assumeIsolated` 里把 `id` 交给 `CarbonHotkeyRegistrar.fire(rawID:)`：高 8 位是代数，低 24 位是绑定 id。代数是当前代数且这个 id 仍已注册时，才经 `SystemHotkeyRegistrar` 调 `onHotkey?(id)`，否则丢弃。
- `register(_:)`：对传入的每条键盘绑定调 `RegisterEventHotKey(keyCode, 修饰键, EventHotKeyID(signature: "EVOP", id: generation << 24 | binding.id), GetApplicationEventTarget(), 0, &ref)`。返回值不是 `noErr` 的记为失败（`registrationRejected`）。绑定 id 大于 `0x00FFFFFF` 时不注册，记为失败。编码与解码在 Core 的 `CarbonHotkeyID`。
- `unregister(ids:)` 与 `unregisterAll()`：对相应的引用调 `UnregisterEventHotKey`。`beginNewGeneration()`：注销全部引用，代数加 1（0～255 循环）。
- 修饰键换算：`command → cmdKey`，`option → optionKey`，`control → controlKey`，`shift → shiftKey`。

`SystemHotkeyRegistrar` 对键盘绑定的用法：`replaceAll` 先 `beginNewGeneration()`，再注册应启用的绑定；`setGameFrontmost` 只注册或注销作用范围是 `game` 的那一组；`suspend` 注销全部引用但保留绑定表，`resume` 按当前状态重新注册。作用范围是 `game` 的键盘热键在前台不是 EVE 客户端时没有注册，按键照常传给前台应用。

冲突处理分三层：

1. 配置内部的重复由 `HotkeyPlanner` 去掉（5.5 节），不会送到注册器。
2. 系统保留的组合由 `HotkeyPlanner` 按名单拒绝。
3. 注册失败由 `replaceAll`、`setGameFrontmost` 和 `resume()` 返回，设置窗口在对应的热键旁按 `HotkeyFailureReason` 显示原因。

Carbon 热键触发后，按键不再传给前台应用，与上游「吞掉匹配按键」的行为一致。按住不放时系统会重复触发，连续循环照常工作。
触发后的流程：协调器按 `id` 查 `HotkeyBinding`，按 `action` 算出目标，再调 `WindowActivator`。循环动作的 `active` 取前台客户端的角色名；前台不是 EVE 时取 `session.lastActivePID` 对应的角色。

### 6.6 前台观察与权限

`SystemWorkspaceObserver` 订阅 `NSWorkspace` 的通知，并换算成 `WorkspaceEvent`：

| 通知 | 事件 |
| --- | --- |
| `didActivateApplicationNotification` | `frontmostChanged` |
| `didLaunchApplicationNotification`、`didTerminateApplicationNotification` | `applicationsChanged` |
| `NSApplication.didChangeScreenParametersNotification` | `screensChanged` |
| `activeSpaceDidChangeNotification` | `activeSpaceChanged` |
| `didWakeNotification` | `didWake` |

`screens()` 把 `NSScreen.screens` 换算成 Core 的坐标。`didWake` 之后 App 调 `CaptureService.restartActiveSessions()`，重启处于 starting、running、retrying 的会话；已有画面的缩略图在重启期间保留最后一帧。

`SystemPermissionService`：

- `openSystemSettings` 打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`、`…?Privacy_Accessibility` 或 `…?Privacy_FilesAndFolders`。
- `requestAccessibility` 调 `AXIsProcessTrustedWithOptions`，选项键写字符串 `"AXTrustedCheckOptionPrompt"`（全局常量 `kAXTrustedCheckOptionPrompt` 在 Swift 6 下不能直接引用）。
- `relaunch` 用 `NSWorkspace.openApplication(at:configuration:)` 以新实例打开自己的包，参数带 `--relaunched-from <当前 PID>`，并转发当前进程的 `EVEO_*` 环境变量，然后退出当前进程。手动带这个参数启动、或旧实例 8 秒内没有退出时，会出现两个实例，属于已知限制。

### 6.7 探针

v1.1 起探针新增 `update` 子命令：`update feed [地址]`、`update verify <新应用> <基准应用>`、`update prepare <地址> [--cache 目录]`、`update install <dmg> <应用副本> --version 版本`（只用于临时副本）。

`EVEOProbe` 是 WP-B 的第一项产出，用来在 3 个真实客户端上验证 Platform。它从终端运行，权限记在终端应用名下。

| 命令 | 作用 |
| --- | --- |
| `EVEOProbe list` | 打印候选窗口、选出的主窗口、解析出的身份、当前前台 |
| `EVEOProbe activate <pid>` | 走一遍 6.4 节的步骤，打印每一步的结果和耗时 |
| `EVEOProbe minimize <pid>` | 最小化，2 秒后再激活还原 |
| `EVEOProbe capture <windowID> <秒数>` | 起一条流，打印每秒的帧数与各状态的计数，结束时把最后一帧存成 PNG |
| `EVEOProbe hotkey` | 注册 `ctrl+shift+F13` 与 `opt+F13`，打印触发记录 |
| `EVEOProbe mousetap [秒数]` | 建鼠标事件监听，打印中键与侧键事件的按钮号与修饰键（反馈文档 6.9 节） |
| `EVEOProbe gamelog [目录]` | 打印游戏日志目录的解析统计，可跟踪新增内容（反馈文档 7.12 节） |

## 7 App 设计

### 7.1 生命周期

v1.1 起启动顺序加入日志初始化、会话标记、状态文件与更新检查，退出时先写会话标记，再在需要时安装已下载的更新（最多等 10.5 秒）。顺序见 v1.1 设计 4.4 节，会话标记的规则见第 6 节。

- `main.swift` 建 `NSApplication`，设 `AppDelegate`，激活策略先设为 `.accessory`（Info.plist 同时写 `LSUIElement`）。v1.1 起 `AppDelegate` 读完配置后按 `general.showDockIcon` 改策略：为真（默认）时是 `.regular`，Dock 里有图标（`Support/DockIconPolicy.swift`）。
- 启动时如果同 bundle id 的实例已在运行，退出自己。例外：权限页的「重新启动」以参数 `--relaunched-from <pid>` 打开新实例，新实例最多等 8 秒让该 PID 退出，并在单实例检查中排除它（`Support/InstanceGuard.swift`）。
- `AppDelegate` 建 `ConfigController`、`PlatformServices`、`AppCoordinator`、`StatusItemController`。环境变量 `EVEO_FAKE=1` 时改用 `FakeServices`（假客户端与生成的画面），供界面开发在没有 EVE 和权限的机器上运行。
- 首次启动（`onboardingCompleted == false`）或缺权限时，打开设置窗口的权限页。
- 退出时先写配置，协调器进入停止状态并暂停热键（之后的轮询、巡检、重算、激活回调都不再生效，鼠标事件监听不再吞新的点击），再 `await capture.stopAll()`；`stopAll()` 超过 2.5 秒仍未返回时直接退出。

### 7.2 协调器

`AppCoordinator`（`@MainActor`）持有 `ClientRegistry`、`SessionState`、`FrontmostContext`、屏幕列表、权限状态、捕获状态表和当前的 `HotkeyPlan`。它的入口都是「改状态，然后 `setNeedsReplan()`」：

| 入口 | 来源 |
| --- | --- |
| `pollTick()` | 轮询定时器；取候选窗口，经 `ClientWindowSelector` 和 `ClientRegistry.update` 得到差异 |
| `handle(_: WorkspaceEvent)` | `WorkspaceObserver` |
| `configDidChange()` | `ConfigController`；配置方案或热键变了就重建 `HotkeyPlan` 并 `replaceAll` |
| `thumbnailClicked`、`thumbnailMinimizeRequested`、`hoverChanged`、`dragBegan`、`dragEnded(frame:)` | 缩略图面板 |
| `hotkeyFired(id:)` | `HotkeyRegistrar` |
| `captureStateChanged`、`frameArrived` | `CaptureService`；`frameArrived` 直接转给对应面板，不触发重算 |
| `combatEventsArrived(_:)` | `CombatLogMonitor`；按规则写 `session.combatAlerts`（反馈文档 7.7 节） |
| `frontmostDidChange()`、`permissionsDidChange(old:new:)` | 前台或权限变化后，把状态推给 `HotkeyRegistrar`（反馈文档 6.7 节） |
| `checkHotkeyHealth()` | 巡检循环（间隔 `general.pollIntervalMs`，与 `pollTick()` 分开）与 `HotkeyRegistrar.onStateChange`；重读权限，再调 `checkHealth()`（反馈文档 6.7 节） |
| `languageSettingDidChange(old:new:)` | `general.language` 变化后切换界面语言（反馈文档 5.4 节） |

协调器在前台从客户端或本应用变成其他应用的那一刻，把 `session.lastEVEContextAt` 设为当前时刻（在 `refreshFrontmost()` 里检测这次转变），隐藏延迟从那一刻算起。前台仍是客户端或本应用时也持续更新它。2026-11-20 按审查意见改为在转变时记录，原做法会让实际延迟缩短最多一个轮询周期。
`dragEnded(frame:)` 把最终 frame 写进当前配置方案的 `layouts[角色名]`；登录客户端的拖动结果写进 `loginPosition`（按 `loginIndex` 扣掉层叠偏移）。尺寸与 `defaultSize` 相同时 `width`、`height` 写 `nil`。

### 7.3 缩略图面板

`ThumbnailPanel` 是 `NSPanel` 的子类：

- `styleMask = [.borderless, .nonactivatingPanel]`，`canBecomeKey` 与 `canBecomeMain` 返回 `false`。
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`，`hidesOnDeactivate = false`，`hasShadow = false`，`isMovable = false`。
- `level`：`isAlwaysOnTop` 时是 `.floating`；同时前台是原生全屏的客户端（`isOverFullScreen`）时是 `ThumbnailPanel.fullScreenLevel`（状态栏层级加 1，即 26），否则会被全屏的 EVE 窗口（layer 25）盖住；不置顶时是 `.normal`。
- 透明度用 `alphaValue`。
- 内容视图的 `acceptsFirstMouse(for:)` 返回 `true`。
- 悬停用 `NSTrackingArea`，选项是 `[.mouseEnteredAndExited, .activeAlways, .inVisibleRect]`。本应用几乎不在前台，不用 `.activeAlways` 就收不到悬停事件。

图层从下到上有 6 层：

- 画面层：`contents` 是 `IOSurface`。
- 占位层：深色底加一行说明。
- 标题层：`CATextLayer`，在左上角，带半透明底。
- 跳过标记层：右上角的红色禁行符号。
- 边框层：用 `borderWidth` 与 `borderColor`，画在画面之上，不缩小画面。活动客户端画高亮边框，其余画中性边框（反馈文档 4.1 节）。
- 提醒层：`AlertFlashLayer`，战斗提醒期间闪烁（反馈文档 7.8 节）。

`ThumbnailWindowManager` 按 `ThumbnailPlan.presentations` 的差异建、改、删 `ThumbnailPanelController`。客户端变成活动时把它的面板 `orderFront`，重叠的缩略图里最近活动的在最上面。
`ThumbnailInteraction` 实现 4.5 节的手势：拖动中每次鼠标事件调 `SnapEngine`，直接改面板的 frame；目标 `SnapTargets` 在拖动开始时取一次。

### 7.4 菜单栏与设置窗口

v1.1 起菜单新增「检查更新…」「报告问题…」，有可用更新、更新已就绪或上次运行意外退出时，图标上出现圆点，菜单顶部多出对应的一项；「通用」页新增「更新」「诊断」两组（v1.1 设计第 11 节）。

菜单栏图标是 `StatusBarIcon` 画出的模板图像（八边形框里的分子，与应用图标同一图案），不用 SF Symbol。常驻的菜单项依次是：显示或隐藏全部缩略图、配置方案子菜单、全部最小化、「热键只在 EVE 内生效」（带勾选，切换当前配置方案的 `hotkeyDefaultScope`，第一轮反馈新增）、设置、退出。
有客户端处于 `stoppedByUser` 时多一项「恢复捕获」，缺权限时多一项权限提示。

设置窗口是 `NSWindow` 加 `NSHostingController`。`SettingsViewModel`（`@Observable`）读写 `ConfigController`，开关与滑块改动后立即生效并保存，文本框在提交时生效。打开设置窗口时调 `NSApp.activate()`。

| 页 | 内容 |
| --- | --- |
| 客户端 | 在线客户端与配置里出现过的角色；每行有显示缩略图开关、高亮颜色；「全部隐藏」开关 |
| 预览与布局 | 默认尺寸、最小与最大尺寸、「统一全部缩略图尺寸」按钮（清掉各角色的尺寸记录）、透明度、悬停放大（倍数、锚点）、标题（开关、字号、颜色）、边框（开关、颜色、粗细）、高亮（开关、颜色、粗细）、置顶、隐藏活动客户端、离开 EVE 时隐藏及延迟、吸附、锁定宽高比、锁定布局、帧率、标题栏裁剪高度、登录缩略图位置 |
| 切换与热键 | 热键的默认作用范围；循环组列表（新建、改名、删除）；成员顺序（从在线角色添加、上下移动、删除）；前进与后退热键；每角色直达热键；通用热键（全部隐藏、全部最小化、登录客户端循环）；每条热键的作用范围；`HotkeyIssue` 与注册失败的提示 |
| 提醒 | 战斗提醒的开关、状态、日志目录、闪烁的颜色、时长与样式、未命中是否提醒、最小伤害、「测试闪烁」按钮（反馈文档 7.11 节） |
| 配置方案 | 列表、切换、新建、克隆、改名、删除；「在访达中显示配置文件」 |
| 通用 | 界面语言（反馈文档 5.1 节） |
| 权限 | 两项权限的状态、请求按钮、系统设置跳转、「重新启动」按钮 |
| 关于 | 版本、上游项目与许可证（GPL-3.0）、EVE 知识产权声明、「本工具只切换窗口焦点，不向多个客户端广播输入」的说明 |

`HotkeyRecorderView` 在获得焦点时调 `hotkeys.suspend()`，用 `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown])` 取键码或鼠标按钮号与修饰键，Escape 取消，Delete 清除，结束时调 `resume()`。鼠标按键的录制规则见反馈文档 6.8 节。设置窗口失去键盘焦点或关闭时取消录制并恢复热键，避免切到 EVE 后全部热键停用。

界面文字有英、中、俄、日、韩、法、德、西 8 种语言（法、德、西文自 1.1.3 起），全部经 `L10n` 取得，不用 `.strings` 资源。语言由 `general.language` 决定，默认英文，切换后立即生效。文字按域分成协议，每种语言一份实现，漏译时编译不过；写法是 `L10n.menu.showAll`、`L10n.settings.pageClients`（反馈文档第 5 节）。v1 的做法是中英成对定义并在启动时按系统语言选一种，已被取代。不用资源的原因：SwiftPM 的资源包放进手工组装的 `.app` 后，`Bundle.module` 的查找路径与代码签名都有额外问题。

## 8 目录与文件

约定：

- 单个文件不超过 1,000 行，宜在 400 行以内；单个函数不超过 500 行，宜在 60 行以内。超过 400 行的文件按职责拆成扩展文件（`类型名+职责.swift`）。
- 注释率高于 20%，注释写中文。每个 `public` 声明有文档注释，写清语义、单位和边界情况；实现里解释原因，不复述代码。
- 每个源文件首行是 `// SPDX-License-Identifier: GPL-3.0-or-later`。
- 日志经 `PlatformLog.logger("<分类>")` 或 `AppLog.logger("<分类>")` 取得的 `LogChannel` 写，不直接建 `os.Logger`（v1.1 起，同时写系统日志与日志文件）；subsystem 是 bundle id，category 取模块名；角色名按 `.private` 记录；不用 `print`（`EVEOProbe` 除外）。v1.1 新增目录与文件的清单见 v1.1 设计第 12 节。
- 新建的文档与脚本文件名用小写英文加连字符。

以下路径相对于 `app/`。下面各表是 v1 的文件与当时的归属；第一轮反馈新增和改动的文件、它们的归属列在反馈文档第 8 节。

| 路径 | 职责 | 归属 |
| --- | --- | --- |
| `Package.swift` | 包定义 | 第 0 步 |
| `.gitignore` | 增加 `.build/`、`dist/`、`.swiftpm/`，删除 Windows 专属条目 | 第 0 步 |
| `README.md`、`docs/macos/development.md` | macOS 版的用户说明；构建、调试、CI 与发布说明 | WP-C |
| `docs/macos/architecture.md` | 本文 | 主会话 |
| `macos/scripts/build-app.sh`、`macos/packaging/Info.plist` | 构建与打包 | WP-C |
| `scripts/check_quality.py` | 质量检查（已存在，见 9.3 节） | 主会话 |

`Sources/EVEOPreviewCore/`（WP-A）：

| 文件 | 职责 |
| --- | --- |
| `Geometry/ScreenGeometry.swift` | 几何类型及其运算（边、相交、偏移、缩放） |
| `Model/ClientModels.swift` | 窗口与客户端模型 |
| `Model/RuntimeModels.swift` | 会话状态、前台、权限、捕获规格与状态 |
| `Model/AppConfig.swift` | `AppConfig`、`GeneralSettings`、默认值、解码 |
| `Model/Profile.swift` | `Profile` 及各设置结构、默认值、解码 |
| `Model/CycleGroup.swift` | `CycleGroup`、`GeneralHotkeys` |
| `Contracts/PlatformContracts.swift` | 6.1 节的 Core 协议 |
| `Contracts/ConfigStore.swift` | `ConfigStore`、错误与警告类型 |
| `Config/JSONFileConfigStore.swift` | 文件读写、隔离损坏文件、备份 |
| `Config/ConfigMigrator.swift` | 版本识别与迁移 |
| `Config/ConfigValidator.swift` | 取值范围与一致性 |
| `Config/ProfileEditor.swift` | 配置方案的增删改 |
| `Clients/TitleParser.swift`、`Clients/ClientWindowSelector.swift`、`Clients/ClientRegistry.swift` | 5.3 节 |
| `Layout/LayoutResolver.swift`、`Layout/SnapEngine.swift`、`Layout/ZoomMath.swift`、`Layout/CaptureMath.swift` | 5.4 与 5.6 节的布局计算 |
| `Switching/CycleEngine.swift` | 循环顺序 |
| `Hotkeys/Hotkey.swift`、`Hotkeys/KeyCodeTable.swift`、`Hotkeys/HotkeyPlanner.swift` | 5.5 节 |
| `Planning/PlannerModels.swift`、`Planning/VisibilityRules.swift`、`Planning/ThumbnailPlanner.swift` | 5.6 节 |
| `Support/HexColor.swift`、`Support/RetryPolicy.swift` | 颜色解析、重试延迟 |

`Tests/EVEOPreviewCoreTests/`（WP-A）：每个被测文件对应一个 `<名称>Tests.swift`，另有 `Fixtures.swift` 存放样例数据（含 E6 的真实窗口列表）。

`Sources/EVEOPreviewPlatform/`（WP-B）：

| 文件 | 职责 |
| --- | --- |
| `PlatformServices.swift` | `makeLive()`，组装各实现 |
| `Geometry/CoordinateConversion.swift` | `ScreenRect` 与 `CGRect`、AppKit frame 的互换 |
| `Windows/CGWindowProvider.swift` | 6.2 节 |
| `Windows/AXWorker.swift` | AX 读写的 `actor`：找窗口、读标题与最小化状态、提升、最小化 |
| `Windows/SystemWindowActivator.swift` | 6.4 节 |
| `Windows/PrivateActivation.swift` | 6.4 节的私有接口后备 |
| `Workspace/SystemWorkspaceObserver.swift` | 6.6 节的前台与屏幕 |
| `Permissions/SystemPermissionService.swift` | 6.6 节的权限 |
| `Hotkeys/CarbonHotkeyRegistrar.swift` | 6.5 节 |
| `Capture/CaptureTypes.swift` | `CapturedFrame`、`CaptureService` |
| `Capture/SCKCaptureService.swift` | `reconcile`、会话表、宽限期与防抖 |
| `Capture/WindowCaptureSession.swift` | 单条流的建立、更新、停止、重试 |
| `Capture/StreamOutputHandler.swift` | 帧回调、最新一帧槽位、停止回调 |
| `Capture/ShareableContentCache.swift` | `SCWindow` 查找与合并请求 |

`Sources/EVEOProbe/main.swift`（WP-B）：6.7 节的探针。

`Sources/EVEOPreview/`（WP-C）：

| 文件 | 职责 |
| --- | --- |
| `main.swift`、`AppDelegate.swift` | 启动、单实例、组装 |
| `AppCoordinator.swift`、`AppCoordinator+Actions.swift`、`AppCoordinator+Hotkeys.swift` | 7.2 节 |
| `ConfigController.swift` | 持有 `AppConfig`，延迟保存，通知变化 |
| `Thumbnails/ThumbnailPanel.swift`、`ThumbnailContentView.swift` | 面板与图层 |
| `Thumbnails/ThumbnailPanelController.swift`、`ThumbnailWindowManager.swift` | 按呈现更新面板 |
| `Thumbnails/ThumbnailInteraction.swift`、`ThumbnailContextMenu.swift` | 手势与右键菜单 |
| `StatusItem/StatusItemController.swift` | 菜单栏 |
| `Settings/SettingsWindowController.swift`、`SettingsViewModel.swift`、`SettingsRootView.swift` | 设置窗口框架 |
| `Settings/ClientsPage.swift`、`PreviewsPage.swift`、`SwitchingPage.swift`、`ProfilesPage.swift`、`PermissionsPage.swift`、`AboutPage.swift` | 6 个页 |
| `Settings/HotkeyRecorderView.swift`、`Settings/FormComponents.swift` | 热键录制、公用表单控件 |
| `Support/L10n.swift`、`Support/NSColor+Hex.swift` | 界面文字（第一轮反馈后迁到 `Localization/`）、颜色换算 |
| `Debug/FakeServices.swift` | `EVEO_FAKE=1` 时的假服务 |

## 9 构建与打包

### 9.1 `macos/scripts/build-app.sh`

脚本做以下事情：

1. 运行 `swift build -c release --product EVEOPreview`。环境变量 `UNIVERSAL=1` 时改为按 `arm64-apple-macosx14.0` 与 `x86_64-apple-macosx14.0` 两个三元组各编译一次，再用 `lipo -create` 合成通用二进制。不用 `swift build --arch arm64 --arch x86_64`，因为那条路径依赖 Xcode 的 xcbuild，只装 Command Line Tools 时不可用。
2. 建 `dist/EVE-O Preview.app/Contents/{MacOS,Resources}`，把可执行文件复制为 `Contents/MacOS/EVEOPreview`。
3. 用 `macos/packaging/Info.plist` 生成 `Contents/Info.plist`，把版本号换成环境变量 `VERSION`（默认取仓库根目录 `VERSION` 文件的内容），并用 `plutil -lint` 检查。
4. 如果存在 `macos/packaging/AppIcon.png`，用 `sips` 与 `iconutil` 生成 `Contents/Resources/AppIcon.icns`。随后写入两个附加键：`EVEOBuildLabel` 取环境变量 `LABEL`（默认等于 `VERSION`）；`EVEOBuildCommit` 取 `git rev-parse --short=7 HEAD`，不在 git 仓库里时不写。自动更新用这两个键区分正式版与 PR、`main` 的构建（v1.1 设计 8.3 节）。
5. 选签名身份：`SIGN_IDENTITY` 有值时用它；否则钥匙串里有 `EVEO Preview Dev` 时用它；都没有时用 `-`（ad-hoc）。运行 `codesign --force --sign "$身份" --identifier io.github.deletexiumu.eveopreview-macos "dist/EVE-O Preview.app"`，再用 `codesign --verify --strict` 检查。
6. 打印产物路径和签名方式。使用 ad-hoc 签名时多打印一行提示：重新构建后要重新授权。

Info.plist 的键：

| 键 | 值 |
| --- | --- |
| `CFBundleIdentifier` | `io.github.deletexiumu.eveopreview-macos` |
| `CFBundleName`、`CFBundleDisplayName` | `EVE-O Preview` |
| `CFBundleExecutable` | `EVEOPreview` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString`、`CFBundleVersion` | 由 `VERSION` 填入 |
| `LSMinimumSystemVersion` | `14.0` |
| `LSUIElement` | `true`（只有菜单栏图标，没有 Dock 图标） |
| `NSHighResolutionCapable` | `true` |
| `NSPrincipalClass` | `NSApplication` |
| `CFBundleIconFile` | `AppIcon`（有图标时） |
| `NSHumanReadableCopyright` | GPL-3.0 说明 |
| `NSDocumentsFolderUsageDescription` | 读「文稿」下游戏日志的用途说明，英文（第一轮反馈新增，反馈文档 7.9 节） |
| `EVEOBuildLabel`、`EVEOBuildCommit` | 构建标签与提交号（v1.1 新增，见上文第 4 步） |

不启用 App Sandbox（沙盒内不能用辅助功能控制别的应用），不启用 hardened runtime（本机使用，不做公证）。屏幕录制与辅助功能没有用途说明键（4.4 节）。

### 9.2 签名与权限

系统按代码签名识别应用并记录授权。ad-hoc 签名没有稳定的身份，每次构建后的可执行文件被当成另一个应用，屏幕录制与辅助功能的授权都会失效。开发期间宜用自签名证书。

1. 打开「钥匙串访问」，选菜单「证书助理」里的「创建证书」。
2. 名称填 `EVEO Preview Dev`，身份类型选「自签名根证书」，证书类型选「代码签名」，创建。
3. 运行 `SIGN_IDENTITY="EVEO Preview Dev" macos/scripts/build-app.sh`。首次签名时允许 `codesign` 访问钥匙串。

授权记录错乱时，运行 `tccutil reset ScreenCapture io.github.deletexiumu.eveopreview-macos` 和 `tccutil reset Accessibility io.github.deletexiumu.eveopreview-macos`，再重新授权。
用 `swift run` 直接运行可执行文件时，权限记在终端应用名下，适合开发调试。

### 9.3 `scripts/check_quality.py`

这个脚本已存在（主会话于 2026-11-20 创建），不属于任何工作包。用法是 `python3 scripts/check_quality.py [目录 …]`，默认检查 `Sources` 与 `Tests` 下的全部 `.swift` 文件。有任何一项不合格时退出码为 1。

| 检查项 | 规则 |
| --- | --- |
| 注释率 | `注释行 ÷（注释行 + 代码行）`，空行不计。整行都是注释（`//` 行或 `/* */` 块内的行）算注释行；同一行既有代码又有行尾注释的算代码行。全部被检查文件的合计应高于 20% |
| 文件长度 | 超过 1,000 行（含空行）不合格 |
| 函数长度 | 从 `func`、`init`、`deinit` 的声明行起，按花括号配对数到函数结束，超过 500 行不合格。字符串与注释里的花括号不计 |

脚本逐个文件打印注释率与行数，最后打印合计。本文「宜在 400 行以内」一类的推荐值不由脚本检查，由审查方核对。

### 9.4 `macos/scripts/package-release.sh`

附件名是 CI 与应用内更新之间的契约，见 v1.1 设计 8.1 节与本文 9.5 节。

脚本在 `dist/release/` 下生成发布文件：

| 文件 | 内容 |
| --- | --- |
| `EVE-O-Preview-<标签>.dmg` | 卷里有 `EVE-O Preview.app` 和指向「应用程序」的替身，用 `hdiutil create -format UDZO` 生成，再用 `hdiutil verify` 检查 |
| `eve-o-preview-macos-<标签>-source.tar.gz`、`.zip` | `git archive` 从 `HEAD` 导出的源码，顶层目录名带标签 |
| `SHA256SUMS.txt` | 以上文件的 SHA-256，可在该目录下用 `shasum -c` 核对 |

`<标签>` 取环境变量 `LABEL`，默认等于 `VERSION`。脚本默认先调用 `build-app.sh`，`SKIP_BUILD=1` 时直接打包已有的 `.app`。

### 9.5 CI 与发布

工作流是 `.github/workflows/macos.yml`，跑在 GitHub 托管的 `macos-15` 运行器上。仓库是公开仓库，不用自托管运行器；打包要用 macOS 的 `hdiutil` 与 `codesign`。第三方 action 钉到提交 SHA，行尾注释写版本号。

| 触发 | 做的事 | 产物 |
| --- | --- | --- |
| 向 `main` 发起或更新 PR、推送到 `main`、手动运行 | 质量门禁、发布说明标记检查（`scripts/check_release_notes.py`）、`swift test`、以 `UNIVERSAL=1` 打包，挂载 dmg 核对架构、签名、指定要求、「应用程序」替身与发布契约 | 工作流制品，保留 30 天；标签为 `<VERSION>-pr.<编号>.<提交>` 或 `<VERSION>-dev.<提交>` |
| 推送 `v*` tag | 同上，另外核对 tag 与 `VERSION` 文件一致，再建 GitHub Release | Release 附件：dmg、两个源码包、`SHA256SUMS.txt` |
| 手动运行并勾选「演练发布」（`rehearse_release`） | 同第一行，再建一个草稿 Release，名为 `v<VERSION>-rehearsal.<运行编号>` | 草稿 Release，不打 tag、不公开，检查完在 Releases 页面删掉 |

发布契约是 CI 与应用自动更新之间的约定（v1.1 设计 8.1 节）：`dist/release/` 只有 4 个附件且名字固定，`SHA256SUMS.txt` 有 dmg 那一行，dmg 顶层的 `EVE-O Preview.app` 是真实目录，`Info.plist` 的 `CFBundleIdentifier`、`CFBundleExecutable`、`CFBundleShortVersionString`、`EVEOBuildLabel`、`EVEOBuildCommit` 取值正确。改动其中任何一项，已安装的版本就只能提示更新、不能自动安装。

PR 构建检出 PR 的头提交，不用 GitHub 生成的合并提交，所以制品名里的提交号与内容一致。只有建 Release 的任务有 `contents: write` 权限。tag 名带 `-`（如 `v1.1.0-beta.1`）时，Release 标为预发布。Release 已存在时任务失败，不覆盖附件：已经发出去的文件与校验和不应被悄悄替换，要重发按本节末尾的步骤重打 tag。签名见 9.6 节，发布说明的格式见 9.7 节。

发布新版本的步骤：

1. 在 PR 里把 `VERSION` 文件改成新版本号，并新增 `docs/release-notes/macos/v<版本号>.md`，合并到 `main`。
2. 如果这次改了工作流的 release 任务，先手动运行工作流并勾选「演练发布」，检查草稿 Release 的附件与说明，再删掉草稿。
3. 在 `main` 上打 tag 并推送：`git tag -a v<版本号> -m "..." && git push origin v<版本号>`。

推送 tag 时，GitHub 用 tag 所在提交里的工作流。如果 tag 的运行失败，并且失败原因要改工作流或代码才能修，按以下步骤重打 tag：

1. 在 PR 里修复，合并到 `main`。
2. 如果失败的运行已经建了 Release，在 Releases 页面删掉它。
3. 删掉远端与本地的 tag：`git push origin :refs/tags/v<版本号> && git tag -d v<版本号>`。
4. 在新的 `main` 上重新打 tag 并推送。

### 9.6 签名证书

2026-11-20 起，CI 用固定的自签名证书「EVE-O Preview Release」签名（RSA 3072，代码签名用途，有效期到 2036-11-17）。证书的 SHA-1 记在 `macos/packaging/release-cert-sha1.txt`，签出的指定要求是 `identifier "io.github.deletexiumu.eveopreview-macos" and certificate root = H"<SHA-1>"`。指定要求在各版本之间不变，所以系统记录的屏幕录制与辅助功能授权在升级后仍然有效。从 v1.0.0 起，所有发布版都用这张证书签名。

| 位置 | 内容 |
| --- | --- |
| 仓库 Actions secret `MACOS_SIGNING_P12_BASE64` | 证书与私钥的 p12 文件，base64 编码 |
| 仓库 Actions secret `MACOS_SIGNING_P12_PASSWORD` | p12 的密码 |
| 维护者本机 `~/Documents/dev/ai/eve-o-preview/signing-backup/` | p12 与证书的备份，不在仓库里 |
| 维护者本机登录钥匙串，服务名 `EVE-O Preview Release p12` | p12 密码的备份 |

自签名证书只有一级，`codesign` 生成的要求可能写成 `certificate root` 或 `certificate leaf`，两种写法指同一张证书，CI 都接受。

工作流把 p12 导入一个临时钥匙串，用 `set-key-partition-list` 允许 `codesign` 直接用私钥，打包后删掉钥匙串。没有 secret 时，tag 构建与演练发布直接失败；其他构建（如来自 fork 的 PR）退回 ad-hoc 签名并给出警告。检查产物时，用固定证书签名的构建要求指定要求里含 `certificate root = H"<SHA-1>"`。

**警告：** 不应更换这张证书，除非私钥泄露。换证书后指定要求改变，所有用户升级后都要重新授权，自动更新的签名核对也会拒绝新版本。

证书没有经过 Apple 公证，用户首次下载后 Gatekeeper 仍会拦截，处理办法写在 README 的安装一节。

备份：p12 与证书在维护者本机的 `signing-backup/` 目录，密码在登录钥匙串里。宜另外把这两样存一份到离线介质或密码管理器。两处都丢失时，只能换证书。

如果私钥泄露或丢失，按以下步骤换证书：

1. 生成新证书（代码签名用途），导出为 p12，用 `security import` 导入临时钥匙串并签一个应用，确认能用。
2. 更新两个 Actions secret 与 `macos/packaging/release-cert-sha1.txt`。
3. 在发布说明里写明：这个版本换了签名证书，已安装的版本只会提示更新、不能自动安装，用户要手动下载安装并重新授予屏幕录制与辅助功能权限。
4. 演练发布，确认指定要求钉在新证书上，再打 tag。

### 9.7 发布说明格式

`docs/release-notes/macos/v<版本号>.md` 原样作为 Release 正文。英文在前，其余语言按 zh、ja、ko、ru、fr、de、es 的顺序各占一个可折叠区块，每块用 HTML 注释标出语言代码，代码与界面语言代码一致：

```markdown
<!-- lang:en -->
英文正文
<!-- /lang:en -->

<!-- lang:zh -->
<details><summary>简体中文</summary>

中文正文

</details>
<!-- /lang:zh -->
```

日、韩、俄、法、德、西文的摘要标题分别是 `日本語`、`한국어`、`Русский`、`Français`、`Deutsch`、`Español`。应用内的更新提示按界面语言取对应区块，取不到时用英文，正文里没有标记时显示全文。跳过了几个版本时，更新窗口还会列出中间各版本的说明（v1.1 设计 8.8 节），所以每个版本的说明只写这个版本自己的改动，不要把前面版本的内容抄进来。

## 10 实施计划与测试

v1.1 的工作包、测试与手工验证见 v1.1 设计第 13、14 节；风险、待用户决定的问题与术语见第 16～18 节。

### 10.1 分工

主会话于 2026-11-20 调整了顺序：不单独做第 0 步，由 WP-A 先完成 Core 与骨架，WP-B 与 WP-C 随后在各自的 git worktree 里并行。任何两个工作包都不改同一个文件。

| 步骤 | 内容 | 完成标准 |
| --- | --- | --- |
| WP-A | `Package.swift`、`.gitignore`；Core 全部实现与 `Tests/`；Platform 的骨架（`Capture/CaptureTypes.swift` 完整，`PlatformServices.swift` 的 `makeLive()` 写 `fatalError("未实现")`）；`EVEOProbe/main.swift` 与 `EVEOPreview/main.swift` 各一个能编译的空入口 | `swift build` 通过，`swift test` 全绿，10.2 节的用例齐全 |
| WP-B | Platform 全部实现、`EVEOProbe`；先做 6.7 节的实测，回报 V2、V4、V5、V6、V7、V8 | 探针的 5 个命令在 3 个真实客户端上通过 |
| WP-C | App 全部实现（含 `FakeServices`）、`macos/scripts/build-app.sh`、`macos/packaging/`、`README.md` | `EVEO_FAKE=1` 下界面功能可用，`build-app.sh` 产出能启动的 `.app` |

WP-A 之后文件的归属：Core 与 `Tests/` 归 WP-A，Platform 与 `EVEOProbe` 归 WP-B，App、`macos/scripts/build-app.sh`、`macos/packaging/`、`README.md` 归 WP-C。
契约要改时，工作包停下并报主会话；主会话改本文，再让文件的归属方改代码。
WP-C 用 `FakeServices` 代替 Platform，不等 WP-B。

集成顺序：

1. 合入 WP-A，运行 `swift test`。
2. 合入 WP-B，在真实客户端上跑探针，确定 6.4 节的最终步骤。
3. 合入 WP-C，主会话确认 `AppDelegate` 在没有 `EVEO_FAKE` 时使用 `makeLive()`，运行 `macos/scripts/build-app.sh` 和 `python3 scripts/check_quality.py`。
4. 测试方（Opus）补测试并按 10.3 节做手工验证。
5. 交审查方（Fable）独立审查。

第一轮反馈的工作包（WP-0～WP-3）、集成顺序、新增的 Core 测试与手工验证条目见反馈文档第 9、10 节。下面三小节是 v1 的计划与测试，仍然有效。

### 10.2 Core 测试

| 测试文件 | 覆盖 |
| --- | --- |
| `TitleParserTests` | `EVE`、`eve`、`EVE - Name`、带首尾空白、`EVE - `（空名）、含 ` - ` 的角色名、`nil`、别的标题 |
| `ClientWindowSelectorTests` | E6 的真实窗口列表选出 3 个主窗口；无标题时按面积；全是小窗口时不产生客户端；并列时的取舍 |
| `ClientRegistryTests` | 新增、移除、登录后改名、只移动、顺序稳定、窗口 ID 被别的 PID 复用 |
| `ConfigCodableTests` | 默认配置往返一致；缺键取默认值；多余的键被忽略；JSON 键名与 5.2 节一致 |
| `ConfigStoreTests` | 5.2 节 `load()` 表的 5 种情况（用临时目录）；原子保存；备份与隔离文件的命名 |
| `ConfigValidatorTests` | 每个范围的上下界；空配置方案列表；失效的 `activeProfileID`；重名 |
| `ProfileEditorTests` | 新建、克隆（内容相同、id 不同）、改名、删除活动方案、不能删最后一个、非法名称 |
| `LayoutResolverTests` | 有记录、无记录的自动排位、登录层叠、尺寸夹取、宽高比、屏幕外拉回、负坐标的副屏 |
| `SnapEngineTests` | 4 种边组合、阈值内外、最近者优先、远处的行不吸附、屏幕边、缩放只动拖动的边、约束优先于吸附、宽高比 |
| `ZoomMathTests` | 9 个锚点各一例 |
| `CycleEngineTests` | 前进后退、绕回、跳过、离线成员、`active` 不在组内、`active` 被跳过、全部不可用、唯一可用、重复成员；登录循环的升序与绕回 |
| `HotkeyTests` | 字符串往返、别名、大小写、`Key<键码>`、非法输入、规范顺序、`displayString` |
| `HotkeyPlannerTests` | 编号顺序、重复的取舍、缺修饰键、系统保留、无法解析的字符串 |
| `VisibilityRulesTests` | 4 条规则各自与组合、`.selfApp` 不触发隐藏、延迟未到与已到、`hideDeadline` |
| `ThumbnailPlannerTests` | 活动高亮与 `lastActivePID`、按角色的颜色、悬停放大与透明度、拖动中不放大、各种占位、无权限时 `captures` 为空、隐藏的不捕获、`layoutsToPersist`、`nextWakeAt` |
| `CaptureMathTests` | 像素换算、偶数取整、不超过源尺寸、标题栏裁剪、全屏不裁 |

### 10.3 手工验证

在目标机器上用 3 个真实客户端验证。每项记录通过与否。

1. 首次启动：权限页显示两项未授权；授权屏幕录制并重启后出现实时画面；授权辅助功能后状态在 1 秒内变化。
2. 发现：3 个缩略图的标题是 3 个角色名；启动器没有缩略图。
3. 退出一个客户端，对应缩略图在 2 秒内消失；重新启动，登录界面阶段出现在登录位置；选角色后在 2 秒内变成角色名并回到保存的位置。
4. 依次左键点 3 个缩略图，每次目标客户端都到前台；连点 20 次无失败。本应用的设置窗口在前台时同样有效。
5. Ctrl+点击最小化一个客户端，缩略图显示最小化占位；再左键点击，窗口还原并到前台。
6. 建一个含 3 个角色的循环组，绑定前进与后退热键；各按 10 次，顺序正确并绕回；右键选「跳过循环」后该角色被跳过。
7. 绑定一个角色直达热键，在别的应用里按下，对应客户端到前台。
8. 打开高亮，活动客户端的边框跟着切换变化；切到别的应用后边框留在最后活动的客户端上。
9. 右键拖动与 Option+左键拖动都能移动缩略图；靠近另一个缩略图和屏幕边时吸附；按住 Shift 不吸附；从边缘拖动能缩放；重启应用后位置与尺寸不变。
10. 打开悬停放大，鼠标移入时放大、移出时还原，放大期间画面保持更新。
11. 打开「隐藏活动客户端的缩略图」与「离开 EVE 时隐藏」：行为符合 5.6 节；打开设置窗口时缩略图不消失。
12. 新建第二个配置方案并改布局，在菜单栏里来回切换，两套布局各自保持。
13. 把一个客户端移到别的空间、切换显示器缩放，各观察 1 分钟，记录画面是否继续更新（V4）。
14. 3 个客户端运行 10 分钟，用「活动监视器」记录本应用的 CPU 占用与能耗影响。

## 11 风险与待核实事项

| 编号 | 风险或待核实事项 | 应对 |
| --- | --- | --- |
| V1 | 权限矩阵的后 3 行没有实测 | WP-C 在首次运行 `.app` 时按 4.4 节逐格核对 |
| V2 | 协作式激活下，后台应用调 `activate` 的成功率未知 | WP-B 的第一项任务；失败时按 6.4 节加重试，再不行则由用户决定是否启用私有接口 |
| V3 | SDK 是 15.2，系统是 macOS 27；新系统对屏幕录制的提示与周期性重新确认的行为未知 | 观察并记录；`stoppedByUser` 与 `permissionDenied` 两个状态已留出处理位置 |
| V4 | 窗口最小化或在别的空间时，流是否继续出帧、状态是什么，未实测 | 保留最后一帧并显示占位，不依赖其中任何一种行为 |
| V5 | 「5 秒无回调就重建」是否会在静止画面下误触发，未实测 | 用探针观察静止客户端的空闲帧回调；会误触发时删掉这条规则 |
| V6 | 标题栏高度按 28 点裁剪是估计值 | 做成可调的配置项；在真实客户端上量出实际值后改默认值 |
| V7 | 只带 Option 的热键注册返回成功（E10），实际能否触发未知 | 用探针的 `hotkey` 命令核对；不能触发时在 `HotkeyPlanner` 里拒绝 |
| V8 | `NSRunningApplication(processIdentifier:) == frontmostApplication` 对 EVE 客户端是否成立，没有实测。活动高亮、两条隐藏规则和激活后的核对都依赖它 | 探针的 `list` 与 `activate` 打印比较结果；不成立时 `frontmost(among:)` 改读 `kAXFrontmostAttribute`，没有辅助功能权限时退回 `CGWindowList` 的屏上窗口顺序 |
| R1 | ad-hoc 签名导致每次构建后重新授权 | 9.2 节的自签名证书 |
| R2 | 运行捕获时系统在菜单栏显示录制指示器，用户可能从那里停止捕获 | `stoppedByUser` 状态、占位画面、菜单里的「恢复捕获」 |
| R3 | EVE 窗口被销毁重建（切换显示模式）时窗口 ID 变化 | 运行时按新客户端处理；布局按角色名保存，不受影响 |
| R4 | EVE 用原生全屏时，切换客户端会带来空间切换动画 | 在 README 里说明宜用窗口模式；面板已设 `fullScreenAuxiliary`；v1.1.1 起能切到其他全屏空间里的客户端（6.4 节） |
| R5 | AX 调用在客户端卡顿时变慢 | AX 全部走 `AXWorker`，超时 0.25 秒，激活的第 3 步不等 AX |
| R6 | 客户端数量多时的能耗 | 分辨率跟随缩略图、隐藏即停流、帧率可调；10.3 节第 14 项实测 |
| R7 | EVE 的最终用户许可协议 | 本工具只切换焦点，不广播输入，与上游的边界相同；「关于」页写明 |
| V9～V16、R8～R17 | 第一轮反馈的风险与待核实事项 | 见反馈文档第 11 节 |

### 11.1 实测结果

WP-B 于 2026-11-20 用 `EVEOProbe` 在 3 个真实客户端上测得以下结果（macOS 27，Apple Silicon，捕获帧率 15）。

| 编号 | 结果 | 结论 |
| --- | --- | --- |
| V2 | 只用 AppKit 的 `activate(from:options:)`：10 次全部成功，耗时 4 毫秒～38 毫秒；完整的 6.4 节流程 3 次全部成功，耗时 38 毫秒～86 毫秒，私有接口后备一次也没有触发。只用私有接口的 2 次里，应用到了前台但窗口没有被提升 | 6.4 节的顺序不变；私有接口留作最后一步 |
| V4 | 窗口最小化后流先回调一次 `suspended`，之后 6.9 秒～9.4 秒没有回调，不报错也不停止；还原后立即恢复到约 15 帧每秒 | 最小化期间状态保持 `running`，由规划器的 `minimized` 占位覆盖 |
| V5 | 前台与被遮挡的客户端都持续产出 15～16 个 `complete` 帧每秒，没有 `idle` 回调，最长间隔 75 毫秒～89 毫秒 | 5 秒看门狗保留；看门狗在窗口不在屏上时重新计时 |
| V6 | 3456×2038 的捕获画面中，第 0～55 行像素是灰色标题栏，即 28 点 | `titleBarCropHeight` 默认值 28 不变 |
| V7 | `ctrl+shift+F13` 与 `opt+F13` 都注册成功；能否触发要人工按键核对 | 待手工验证 |
| V8 | `NSRunningApplication(processIdentifier:) == frontmostApplication` 对 EVE 客户端成立，与 `kAXFrontmostAttribute` 一致 | `frontmost(among:)` 按设计实现 |

其他发现：

- `SCStreamFrameInfo.contentRect` 的单位是点，乘以 `scaleFactor` 后才是 surface 里的像素位置（`StreamOutputHandler.swift`）。
- 激活最小化的窗口时，窗口 7 毫秒～17 毫秒就到前台，但 `activate()` 要等 AX 还原，680 毫秒～1,057 毫秒后才返回。App 不应等它返回再处理下一次热键；新的激活会取消旧的。
- 一次轮询约 100 毫秒，主要花在 AX 上，不占主线程。

## 12 待用户决定的问题

| 编号 | 问题 | 本文采用的默认做法 |
| --- | --- | --- |
| Q1 | 界面语言 | 已改（2026-11-20，第一轮反馈）：英、中、俄、日、韩 5 种，默认英文，可选跟随系统，见 7.4 节与反馈文档第 5 节；1.1.3 增加法、德、西文，共 8 种。此前的决定是中英双语、按系统语言选择 |
| Q2 | 是否允许私有接口 `_SLPSSetFrontProcessWithOptions` | 已定（2026-11-20）：允许作为公开接口失败后的后备，见 6.4 节 |
| Q3 | 手势 | 采用 4.5 节 |
| Q4 | 默认值是否沿用上游（透明度 0.5、高亮关闭） | 沿用上游。例外：边框默认打开（第一轮反馈，上游没有这一项） |
| Q5 | 是否现在就建自签名证书 | 已定（2026-11-20）：主会话已在登录钥匙串建好 `EVEO Preview Dev`；脚本在钥匙串里找到它时默认使用，找不到时退回 ad-hoc |
| Q6 | 区域、多选、撤销推迟到 v1 之后；是否要导入 Windows 版配置 | 推迟；不做导入 |
| Q7 | bundle id `io.github.deletexiumu.eveopreview-macos`、应用名 `EVE-O Preview`、配置目录 `~/Library/Application Support/EVE-O Preview/` | 如本文 |
| Q8 | 默认帧率 15 帧每秒 | 如本文，设置里可调 |
| Q9～Q12 | 第一轮反馈的问题（提醒与隐藏规则、未命中是否提醒、译文审校、手工验证的时间） | 见反馈文档第 12 节 |

## 13 术语

第一轮反馈增加的术语（边框、作用范围、触发键、游戏日志、战斗提醒等）列在反馈文档第 13 节。

| 词 | 意思 | 不用 |
| --- | --- | --- |
| 客户端 | 一个 EVE Online 游戏进程及其主窗口 | 实例 |
| 登录客户端 | 标题是 `EVE`、还没选角色的客户端 | 登录窗口 |
| 缩略图 | 显示某个客户端实时画面的浮动面板 | 预览、预览窗 |
| 活动客户端 | 当前在前台的客户端；前台不是 EVE 时指最后在前台的那个 | 当前客户端、焦点客户端 |
| 切换 | 把某个客户端的窗口带到前台 | 激活（指 API 调用时除外） |
| 配置方案 | 一套完整的设置、布局与循环组，对应上游的 profile | 配置文件（专指 `config.json`）、档案 |
| 循环组 | 一组有顺序的角色，配前进与后退热键 | 轮换组 |
| 跳过 | 本次会话内把某个角色排除在循环之外 | 禁用 |
| 吸附 | 拖动时把边对齐到附近的缩略图或屏幕边 | 贴靠 |
| 规划器 | `ThumbnailPlanner`，由状态算出全部缩略图呈现的纯函数 | 调度器 |
| 呈现 | `ThumbnailPresentation`，一个缩略图在某一时刻应有的全部外观属性 | 视图模型 |
| 对账 | `CaptureService.reconcile`，把运行中的流调整成与期望一致 | 同步 |
| 占位 | 没有画面时缩略图显示的说明 | 空状态 |
