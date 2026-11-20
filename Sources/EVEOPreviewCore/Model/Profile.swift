// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置方案及其各组设置（架构文档 5.2 节）。默认值沿用上游 EVE-O Preview；
// 上游没有的项标「新增」，与上游不同的标「改动」。取值范围由 ConfigValidator 夹取。

import Foundation

/// 一个配置方案：一套完整的设置、布局与循环组。
///
/// 以角色名为键的字段（布局、隐藏名单、高亮颜色、角色热键）区分大小写。
public struct Profile: Sendable, Equatable, Codable, Identifiable {
    /// 新建配置文件时第一个配置方案的名称。
    public static let defaultName = "Default"

    /// 配置方案的 id（UUID 字符串），在配置文件内唯一。
    public var id: String
    /// 显示名称。去掉首尾空白后 1～64 字，不区分大小写唯一。
    public var name: String
    /// 缩略图尺寸、透明度、放大与吸附。
    public var thumbnail: ThumbnailSettings
    /// 标题、高亮边框与中性边框。
    public var overlay: OverlaySettings
    /// 置顶与隐藏规则。
    public var behavior: BehaviorSettings
    /// 捕获帧率与标题栏裁剪。
    public var capture: CaptureSettings
    /// 每个角色的缩略图位置与尺寸，键是角色名。
    public var layouts: [String: ThumbnailLayout]
    /// 登录界面客户端的缩略图起始位置。改动：默认 (5, 40)，上游是 (5, 5)，因为 macOS 顶部有菜单栏。
    public var loginPosition: ScreenPoint
    /// 不显示缩略图的角色名。
    public var hiddenCharacters: [String]
    /// 按角色设置的高亮颜色，角色名 → `#RRGGBB`。
    public var highlightColors: [String: String]
    /// 循环组，按设置窗口里的顺序。
    public var cycleGroups: [CycleGroup]
    /// 角色直达热键，角色名 → 热键字符串数组。
    public var characterHotkeys: [String: [String]]
    /// 全局热键。
    public var hotkeys: GeneralHotkeys
    /// 没有 `@global`、`@game` 后缀的热键的作用范围。第一轮反馈新增，默认 `global`（反馈文档 6.3 节）。
    public var hotkeyDefaultScope: HotkeyScope
    /// 战斗提醒的设置。第一轮反馈新增，默认关闭（反馈文档 3.1 节）。
    public var combatAlert: CombatAlertSettings

    /// 用各字段建一个配置方案；除名称外都有默认值，id 默认生成新的 UUID。
    public init(id: String = UUID().uuidString, name: String,
                thumbnail: ThumbnailSettings = ThumbnailSettings(),
                overlay: OverlaySettings = OverlaySettings(),
                behavior: BehaviorSettings = BehaviorSettings(),
                capture: CaptureSettings = CaptureSettings(),
                layouts: [String: ThumbnailLayout] = [:],
                loginPosition: ScreenPoint = Profile.defaultLoginPosition,
                hiddenCharacters: [String] = [], highlightColors: [String: String] = [:],
                cycleGroups: [CycleGroup] = [], characterHotkeys: [String: [String]] = [:],
                hotkeys: GeneralHotkeys = GeneralHotkeys(),
                hotkeyDefaultScope: HotkeyScope = .global,
                combatAlert: CombatAlertSettings = CombatAlertSettings()) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
        self.overlay = overlay
        self.behavior = behavior
        self.capture = capture
        self.layouts = layouts
        self.loginPosition = loginPosition
        self.hiddenCharacters = hiddenCharacters
        self.highlightColors = highlightColors
        self.cycleGroups = cycleGroups
        self.characterHotkeys = characterHotkeys
        self.hotkeys = hotkeys
        self.hotkeyDefaultScope = hotkeyDefaultScope
        self.combatAlert = combatAlert
    }

    /// 登录客户端缩略图的默认起始位置 (5, 40)，单位是点。
    public static let defaultLoginPosition = ScreenPoint(x: 5, y: 40)

    /// 解码时缺失的键取默认值。id 与名称缺失时为空串，由 `ConfigValidator` 补上。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        thumbnail = try c.decodeIfPresent(ThumbnailSettings.self, forKey: .thumbnail) ?? ThumbnailSettings()
        overlay = try c.decodeIfPresent(OverlaySettings.self, forKey: .overlay) ?? OverlaySettings()
        behavior = try c.decodeIfPresent(BehaviorSettings.self, forKey: .behavior) ?? BehaviorSettings()
        capture = try c.decodeIfPresent(CaptureSettings.self, forKey: .capture) ?? CaptureSettings()
        layouts = try c.decodeIfPresent([String: ThumbnailLayout].self, forKey: .layouts) ?? [:]
        loginPosition = try c.decodeIfPresent(ScreenPoint.self, forKey: .loginPosition)
            ?? Profile.defaultLoginPosition
        hiddenCharacters = try c.decodeIfPresent([String].self, forKey: .hiddenCharacters) ?? []
        highlightColors = try c.decodeIfPresent([String: String].self, forKey: .highlightColors) ?? [:]
        cycleGroups = try c.decodeIfPresent([CycleGroup].self, forKey: .cycleGroups) ?? []
        characterHotkeys = try c.decodeIfPresent([String: [String]].self, forKey: .characterHotkeys) ?? [:]
        hotkeys = try c.decodeIfPresent(GeneralHotkeys.self, forKey: .hotkeys) ?? GeneralHotkeys()
        // 枚举键用宽松解码：以后的版本新增取值时，旧版本退回默认值，不把整个文件判为损坏。
        hotkeyDefaultScope = LenientDecoding.value(HotkeyScope.self, in: c, forKey: .hotkeyDefaultScope,
                                                   default: .global)
        combatAlert = try c.decodeIfPresent(CombatAlertSettings.self, forKey: .combatAlert)
            ?? CombatAlertSettings()
    }
}

/// 缩略图尺寸、透明度、悬停放大与吸附。尺寸单位都是点。
public struct ThumbnailSettings: Sendable, Equatable, Codable {
    /// 没有尺寸记录的缩略图使用的尺寸，默认 384×216。
    public var defaultSize: ScreenSize
    /// 缩放下限，默认 192×108。
    public var minimumSize: ScreenSize
    /// 缩放上限，默认 960×540。悬停放大后的尺寸不受它限制。
    public var maximumSize: ScreenSize
    /// 未悬停时的不透明度，默认 0.5，范围 0.2～1.0；悬停时总是 1.0。
    public var opacity: Double
    /// 是否启用悬停放大，默认 false。
    public var zoomEnabled: Bool
    /// 悬停放大倍数，默认 2，范围 2～10。
    public var zoomFactor: Int
    /// 悬停放大时保持不动的点，默认 `nw`（左上角）。
    public var zoomAnchor: ZoomAnchor
    /// 拖动时是否吸附到其他缩略图和屏幕边，默认 true。
    public var snapEnabled: Bool
    /// 缩放时是否保持宽高比，默认 false。
    public var lockAspectRatio: Bool

    /// 用各字段建缩略图设置，默认值见各属性。
    public init(defaultSize: ScreenSize = ScreenSize(width: 384, height: 216),
                minimumSize: ScreenSize = ScreenSize(width: 192, height: 108),
                maximumSize: ScreenSize = ScreenSize(width: 960, height: 540),
                opacity: Double = 0.5, zoomEnabled: Bool = false, zoomFactor: Int = 2,
                zoomAnchor: ZoomAnchor = .nw, snapEnabled: Bool = true, lockAspectRatio: Bool = false) {
        self.defaultSize = defaultSize
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.opacity = opacity
        self.zoomEnabled = zoomEnabled
        self.zoomFactor = zoomFactor
        self.zoomAnchor = zoomAnchor
        self.snapEnabled = snapEnabled
        self.lockAspectRatio = lockAspectRatio
    }

    /// 解码时缺失的键取默认值；无法识别的锚点名取默认锚点，不把整个文件判为损坏。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThumbnailSettings()
        defaultSize = try c.decodeIfPresent(ScreenSize.self, forKey: .defaultSize) ?? d.defaultSize
        minimumSize = try c.decodeIfPresent(ScreenSize.self, forKey: .minimumSize) ?? d.minimumSize
        maximumSize = try c.decodeIfPresent(ScreenSize.self, forKey: .maximumSize) ?? d.maximumSize
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        zoomEnabled = try c.decodeIfPresent(Bool.self, forKey: .zoomEnabled) ?? d.zoomEnabled
        zoomFactor = try c.decodeIfPresent(Int.self, forKey: .zoomFactor) ?? d.zoomFactor
        let anchorName = try c.decodeIfPresent(String.self, forKey: .zoomAnchor)
        zoomAnchor = anchorName.flatMap(ZoomAnchor.init(rawValue:)) ?? d.zoomAnchor
        snapEnabled = try c.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? d.snapEnabled
        lockAspectRatio = try c.decodeIfPresent(Bool.self, forKey: .lockAspectRatio) ?? d.lockAspectRatio
    }
}

/// 悬停放大时保持不动的点：4 个角、4 条边的中点和中心。
public enum ZoomAnchor: String, Sendable, Codable, CaseIterable {
    /// 左上角（north-west）。按方位命名：n 是上，s 是下，w 是左，e 是右。
    case nw
    /// 上边中点。
    case n
    /// 右上角。
    case ne
    /// 左边中点。
    case w
    /// 中心。
    case center
    /// 右边中点。
    case e
    /// 左下角。
    case sw
    /// 下边中点。
    case s
    /// 右下角。
    case se

    /// 不动点在矩形内的相对位置，(0, 0) 是左上角，(1, 1) 是右下角。
    public var unitPosition: (x: Double, y: Double) {
        switch self {
        case .nw: return (0, 0)
        case .n: return (0.5, 0)
        case .ne: return (1, 0)
        case .w: return (0, 0.5)
        case .center: return (0.5, 0.5)
        case .e: return (1, 0.5)
        case .sw: return (0, 1)
        case .s: return (0.5, 1)
        case .se: return (1, 1)
        }
    }
}

/// 缩略图上的叠层：标题、高亮边框与中性边框。颜色都是 `#RRGGBB`。
public struct OverlaySettings: Sendable, Equatable, Codable {
    /// 是否显示角色名标题，默认 true。
    public var showTitle: Bool
    /// 标题字号，单位是点。新增项，默认 12，范围 8～36。
    public var titleFontSize: Double
    /// 标题颜色，默认 `#FFFFFF`。
    public var titleColor: String
    /// 是否给活动客户端画高亮边框，默认 false。
    public var highlightEnabled: Bool
    /// 没有按角色设置时的高亮颜色，默认 `#ADFF2F`。
    public var highlightColor: String
    /// 高亮边框粗细，单位是点，默认 3，范围 1～6。
    public var highlightThickness: Int
    /// 是否给每个缩略图画一圈中性边框。第一轮反馈新增，默认 true（反馈文档第 4 节）。
    public var borderEnabled: Bool
    /// 中性边框的颜色。第一轮反馈新增，默认 `#C0C0C0`；非法时由校验改回默认值。
    public var borderColor: String
    /// 中性边框的粗细，单位是点。第一轮反馈新增，默认 2，范围 1～6。
    public var borderThickness: Int

    /// 中性边框的默认颜色。
    public static let defaultBorderColor = "#C0C0C0"

    /// 用各字段建叠层设置，默认值见各属性。
    public init(showTitle: Bool = true, titleFontSize: Double = 12, titleColor: String = "#FFFFFF",
                highlightEnabled: Bool = false, highlightColor: String = "#ADFF2F",
                highlightThickness: Int = 3, borderEnabled: Bool = true,
                borderColor: String = OverlaySettings.defaultBorderColor, borderThickness: Int = 2) {
        self.showTitle = showTitle
        self.titleFontSize = titleFontSize
        self.titleColor = titleColor
        self.highlightEnabled = highlightEnabled
        self.highlightColor = highlightColor
        self.highlightThickness = highlightThickness
        self.borderEnabled = borderEnabled
        self.borderColor = borderColor
        self.borderThickness = borderThickness
    }

    /// 解码时缺失的键取默认值。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings()
        showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? d.showTitle
        titleFontSize = try c.decodeIfPresent(Double.self, forKey: .titleFontSize) ?? d.titleFontSize
        titleColor = try c.decodeIfPresent(String.self, forKey: .titleColor) ?? d.titleColor
        highlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .highlightEnabled) ?? d.highlightEnabled
        highlightColor = try c.decodeIfPresent(String.self, forKey: .highlightColor) ?? d.highlightColor
        highlightThickness = try c.decodeIfPresent(Int.self, forKey: .highlightThickness)
            ?? d.highlightThickness
        borderEnabled = try c.decodeIfPresent(Bool.self, forKey: .borderEnabled) ?? d.borderEnabled
        borderColor = try c.decodeIfPresent(String.self, forKey: .borderColor) ?? d.borderColor
        borderThickness = try c.decodeIfPresent(Int.self, forKey: .borderThickness) ?? d.borderThickness
    }
}

/// 缩略图面板的行为：置顶、隐藏规则与布局锁定。
public struct BehaviorSettings: Sendable, Equatable, Codable {
    /// 缩略图是否置顶（面板层级为 floating），默认 true。
    public var alwaysOnTop: Bool
    /// 是否隐藏活动客户端自己的缩略图，默认 false。
    public var hideActiveClientThumbnail: Bool
    /// 前台不是 EVE 也不是本应用时是否隐藏全部缩略图，默认 false。
    public var hideWhenEVENotFrontmost: Bool
    /// 上一项的隐藏延迟，单位是秒，默认 1.0，范围 0～10。
    public var hideDelaySeconds: Double
    /// 锁定布局后忽略移动和缩放手势。新增项，默认 false。
    public var lockLayout: Bool

    /// 用各字段建行为设置，默认值见各属性。
    public init(alwaysOnTop: Bool = true, hideActiveClientThumbnail: Bool = false,
                hideWhenEVENotFrontmost: Bool = false, hideDelaySeconds: Double = 1.0,
                lockLayout: Bool = false) {
        self.alwaysOnTop = alwaysOnTop
        self.hideActiveClientThumbnail = hideActiveClientThumbnail
        self.hideWhenEVENotFrontmost = hideWhenEVENotFrontmost
        self.hideDelaySeconds = hideDelaySeconds
        self.lockLayout = lockLayout
    }

    /// 解码时缺失的键取默认值。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BehaviorSettings()
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? d.alwaysOnTop
        hideActiveClientThumbnail = try c.decodeIfPresent(Bool.self, forKey: .hideActiveClientThumbnail)
            ?? d.hideActiveClientThumbnail
        hideWhenEVENotFrontmost = try c.decodeIfPresent(Bool.self, forKey: .hideWhenEVENotFrontmost)
            ?? d.hideWhenEVENotFrontmost
        hideDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .hideDelaySeconds) ?? d.hideDelaySeconds
        lockLayout = try c.decodeIfPresent(Bool.self, forKey: .lockLayout) ?? d.lockLayout
    }
}

/// 捕获设置。
public struct CaptureSettings: Sendable, Equatable, Codable {
    /// 捕获帧率上限，单位是帧每秒。新增项，默认 15，范围 1～60。
    public var frameRate: Int
    /// 从画面顶部裁掉的高度，单位是点。新增项，默认 28，范围 0～60；0 表示不裁。
    public var titleBarCropHeight: Double

    /// 用各字段建捕获设置，默认值见各属性。
    public init(frameRate: Int = 15, titleBarCropHeight: Double = 28) {
        self.frameRate = frameRate
        self.titleBarCropHeight = titleBarCropHeight
    }

    /// 解码时缺失的键取默认值。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate
        titleBarCropHeight = try c.decodeIfPresent(Double.self, forKey: .titleBarCropHeight)
            ?? d.titleBarCropHeight
    }
}

/// 一个角色的缩略图位置与尺寸，全局屏幕坐标，单位是点。
public struct ThumbnailLayout: Sendable, Equatable, Codable {
    /// 左上角的 x 坐标。
    public var x: Double
    /// 左上角的 y 坐标。
    public var y: Double
    /// 宽度；nil 表示使用 `ThumbnailSettings.defaultSize`。
    public var width: Double?
    /// 高度；nil 表示使用 `ThumbnailSettings.defaultSize`。
    public var height: Double?

    /// 用位置与可选的尺寸建一条布局记录。
    public init(x: Double, y: Double, width: Double? = nil, height: Double? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 解码时缺失的位置取 0，缺失的尺寸为 nil。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width)
        height = try c.decodeIfPresent(Double.self, forKey: .height)
    }
}
