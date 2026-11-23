# 第一轮反馈的设计

本文是 v1 试用后 4 项反馈的设计，与 [architecture.md](architecture.md)（下称架构文档）一起构成实现依据。
架构文档已同步改动后的类型签名、默认值和范围表；规则、流程和分工的细节只写在本文。两份文档说法不一致时，停下并报主会话。
本文的 Swift 片段只有类型与协议签名，已在 2026 年 11 月 20 日用 Swift 6.0.3 的 Swift 6 语言模式编译通过（签名加空实现）。

## 1 范围与决定

| 编号 | 用户的要求 | 决定 | 章节 |
| --- | --- | --- | --- |
| F1 | 缩略图默认带边框，便于区分 | 每个缩略图画一圈中性色边框，默认打开，颜色 `#C0C0C0`，粗细 2 点。活动客户端的高亮边框盖过它 | 4 |
| F2 | 界面多语言，至少英、俄、日、韩，保留中文，默认英文 | `general.language` 取 `en`（默认）、`zh`、`ru`、`ja`、`ko`、`system`。切换后立即生效，不重启。界面文字按「协议加每种语言一份实现」组织，缺译文时编译不过 | 5 |
| F3a | 循环切换热键能录制鼠标侧键与中键，触发时吞掉事件 | 热键字符串增加 `Mouse3`～`Mouse32`。平台层用 `CGEventTap` 监听并吞掉匹配的按下、拖动和松开 | 6 |
| F3b | 每个切换热键可设为全局或仅在游戏内生效 | 配置方案有默认作用范围 `hotkeyDefaultScope`，每条热键可用后缀 `@global`、`@game` 单独指定。录制鼠标按键时默认写 `@game` | 6 |
| F4 | 角色被攻击时，它的缩略图闪烁 | 读 `Gamelogs` 下的游戏日志，按伤害数字的颜色标记识别受击。受到伤害和对方开火但未命中都触发闪烁，默认持续 3 秒。功能默认关闭，在设置窗口的「提醒」页打开 | 7 |

不在本轮范围内：

| 项目 | 原因 |
| --- | --- |
| 上游的伤害数字、DPS、α 值、维修量、所在星系叠层 | 依赖 SQLite 存储与 SDE 静态数据，属于独立的子系统。本轮只判断「有没有受击」 |
| 跃迁扰断、能量中和、ECM 等电子战提醒 | 方向判断依赖各语言的整句模板。`CombatLineKind` 留了 `otherCombat`，以后可细分 |
| 提醒音 | 用户没有提出 |
| 读取 `Chatlogs`、`Fleetlogs`、`Marketlogs` | 与受击无关 |
| 德语、法语、西班牙语界面 | 用户只要求先做英、俄、日、韩。结构上加一种语言只加一组文件（5.3 节） |
| 把左键、右键绑成热键 | 吞掉左右键会让系统无法操作 |
| 按键松开时触发、鼠标滚轮触发 | 用户没有提出 |

## 2 已核实的事实

下表的事实于 2026-11-20 在目标机器上只读核实（macOS 27，Apple Silicon，EVE 中文客户端）。

| 编号 | 事实 | 对设计的影响 |
| --- | --- | --- |
| L1 | 游戏日志在 `~/Documents/EVE/logs/Gamelogs/`，同级还有 `Chatlogs`、`Fleetlogs`、`Marketlogs`。现有 247 个文件，最大的 447,289 字节 | 默认目录取这个路径；目录在「文稿」里，读取受系统的「文件与文件夹」权限管（7.9 节） |
| L2 | 文件名有两种：`yyyyMMdd_HHmmss_<数字>.txt`（122 个）和 `yyyyMMdd_HHmmss.txt`（125 个）。文件名里的时间是 UTC | 文件名可按字符串排序得到时间顺序 |
| L3 | 带数字后缀的文件，文件头有收听者一行；不带后缀的文件没有收听者，只有 173 字节，是登录界面阶段建的 | 没有收听者的文件不跟踪 |
| L4 | 抽查最新的 40 个文件：全部是 UTF-8、没有 BOM、换行是 LF | 按 UTF-8 读；BOM 探测只作防御（7.4 节） |
| L5 | 文件头是 5 行：分隔线、标题、收听者、进程开始时间、分隔线。本机同时有中文（`收听者`、`进程开始`）和英文（`Listener`、`Session Started`）两种文件头 | 文件头按多语言标签表解析（7.5 节） |
| L6 | 日志行的形式是 `[ yyyy.MM.dd HH:mm:ss ] (类别) 正文`。本机出现的类别：`combat` 2,687 行，`hint`、`notify`、`question`、`info`、`bounty`、`warning` 共 431 行 | 只看 `combat` 类别 |
| L7 | 1,011 行受到伤害的行都以 `<color=0xffcc0000><b>数字</b>` 开头，774 行造成伤害的行都以 `<color=0xff00ffff><b>数字</b>` 开头。数字最大 1,265，没有千分位符号。有 4 行受到伤害的数字是 0 | 用开头的颜色判断方向（7.6 节） |
| L8 | 852 行「对方未命中你」都是不带标记的纯文本，以 `完全没有打中你` 结尾，后面没有别的内容 | 未命中按句尾的固定短语识别 |
| L9 | `combat` 类别里还有别的消息，如跃迁扰断（以 `<color=0x77ffffff>` 开头，没有开头的数字） | 这类行归为 `otherCombat`，不触发闪烁；用作反例 |
| L10 | 有的日志条目跨多行，后续行不以 `[` 开头 | 不以 `[ ` 开头的行直接丢弃 |
| L11 | 最新一个文件：最后一行日志的时间是 09:51:46（UTC），文件修改时间是 17:51:46（本地时间，UTC+8） | 这一次写入在 1 秒内落盘；战斗中的延迟留给 V13 实测 |
| L12 | 写入最密的一个文件，1 秒内最多 14 行 | 读取与解析的负载很小（7.10 节） |
| L13 | 带数字后缀的 122 个文件里共有 10 个不同的数字，每个数字只对应一个收听者名字 | 数字后缀与角色一一对应，但设计不依赖它，只认文件头的收听者（7.5 节） |
| L14 | 上游的日文、俄文真实客户端录制样例，受到伤害与造成伤害的行开头同样是 `0xffcc0000` 与 `0xff00ffff`。上游的全部消息模板里没有别的消息使用这两种颜色 | 颜色判断不依赖语言。上游只对日文用颜色，因为日文两个方向的介词相同 |
| L15 | 现有界面文字 158 条（146 个静态属性，12 个带参数的函数），调用处 164 个。静态属性都是 `static let`，首次访问后不再变 | 要即时切换语言，文字应改成每次访问时取（5.3 节） |
| L16 | 质量检查的现状：98 个文件，注释 2,824 行，代码 8,807 行，注释率 24.3% | 5 种语言的文字表会拉低注释率（R10） |

上游的依据：`upstream-ref/src/docs/ai/combat-logs.md`、`log-languages.md`、`Eve-O-Preview/Services/Logs/EveLogLanguageCatalog.cs`、`EveLogText.cs`，以及 `tests/Eve-O-Preview.Tests/Fixtures/logs/` 下的样例。

## 3 配置变更

### 3.1 新增的键

`schemaVersion` 保持 1，不写迁移代码。理由：

- 新键全部有默认值，旧文件缺键时由 `decodeIfPresent` 取默认值（架构文档第 5 节的约定）。
- 热键仍存字符串数组。旧版本读到 `Mouse4` 或 `@game` 后缀时记为「无法识别」并原样保留，不丢数据。
- 升版本号会让旧版本拒绝读取新文件（`newerSchema`），代价比上面两点大。

| JSON 路径 | 类型 | 默认值 | 范围或取值 |
| --- | --- | --- | --- |
| `general.language` | 字符串 | `"en"` | `en`、`zh`、`ru`、`ja`、`ko`、`system` |
| `general.eveLogDirectory` | 字符串或缺失 | 缺失 | 缺失表示自动查找；空串按缺失处理 |
| `profiles[].overlay.borderEnabled` | 布尔 | `true` | |
| `profiles[].overlay.borderColor` | 字符串 | `"#C0C0C0"` | `#RRGGBB`，非法时改回默认值 |
| `profiles[].overlay.borderThickness` | 整数 | `2` | 1～6 |
| `profiles[].hotkeyDefaultScope` | 字符串 | `"global"` | `global`、`game` |
| `profiles[].combatAlert.enabled` | 布尔 | `false` | |
| `profiles[].combatAlert.color` | 字符串 | `"#FF3B30"` | `#RRGGBB`，非法时改回默认值 |
| `profiles[].combatAlert.durationSeconds` | 小数 | `3.0` | 1～10 |
| `profiles[].combatAlert.style` | 字符串 | `"both"` | `border`、`wash`、`both` |
| `profiles[].combatAlert.includeMisses` | 布尔 | `true` | |
| `profiles[].combatAlert.minimumDamage` | 整数 | `1` | 1～100,000 |

热键字符串的语法扩展见 6.1 节，不新增键。

```swift
// [Core] Model/AppLanguage.swift（新文件）
/// 界面实际使用的语言。
public enum AppLanguage: String, Sendable, Codable, CaseIterable {
    case en, zh, ru, ja, ko
    /// 语言的自称，不随界面语言变化：English、中文、Русский、日本語、한국어。
    public var autonym: String { get }
}
/// 配置里的语言选项。
public enum LanguagePreference: String, Sendable, Codable, CaseIterable {
    case en, zh, ru, ja, ko, system
    public func resolved(preferredLanguages: [String], override: String?) -> AppLanguage
}

// [Core] Model/AppConfig.swift
public struct GeneralSettings: Sendable, Equatable, Codable {
    public var pollIntervalMs: Int
    public var onboardingCompleted: Bool
    public var language: LanguagePreference     // 新增。默认 .en
    public var eveLogDirectory: String?         // 新增。默认 nil
}

// [Core] Model/Profile.swift
public struct OverlaySettings: Sendable, Equatable, Codable {
    public var showTitle: Bool; public var titleFontSize: Double; public var titleColor: String
    public var highlightEnabled: Bool; public var highlightColor: String; public var highlightThickness: Int
    public var borderEnabled: Bool              // 新增。默认 true
    public var borderColor: String              // 新增。默认 "#C0C0C0"
    public var borderThickness: Int             // 新增。默认 2，范围 1～6
}
// Profile 新增两个属性：
//     public var hotkeyDefaultScope: HotkeyScope      // 默认 .global
//     public var combatAlert: CombatAlertSettings

// [Core] Model/CombatAlertSettings.swift（新文件）
public enum CombatAlertStyle: String, Sendable, Codable, CaseIterable { case border, wash, both }
public struct CombatAlertSettings: Sendable, Equatable, Codable {
    public var enabled: Bool                    // false
    public var color: String                    // "#FF3B30"
    public var durationSeconds: Double          // 3.0，范围 1～10
    public var style: CombatAlertStyle          // both
    public var includeMisses: Bool              // true
    public var minimumDamage: Int               // 1，范围 1～100,000
}

// [Core] Support/LenientDecoding.swift（新文件）
public enum LenientDecoding {
    /// 解码一个以字符串为原始值的枚举。键缺失、类型不对或值不认识时返回 fallback，不抛错。
    public static func value<T: RawRepresentable & Sendable, K: CodingKey>(
        _ type: T.Type, in container: KeyedDecodingContainer<K>, forKey key: K, default fallback: T
    ) -> T where T.RawValue == String
}
```

### 3.2 解码与校验规则

- 每个新增属性在 `public init` 里都有带默认值的参数，现有调用处不用改。
- 新增的 3 个枚举键（`language`、`hotkeyDefaultScope`、`combatAlert.style`）用 `LenientDecoding.value` 解码，以后新增的枚举键照此办理。原因：`decodeIfPresent(枚举.self)` 遇到不认识的值会抛错，整个配置文件会被当成损坏文件隔离。以后的版本增加语言后，旧版本读到 `"de"` 应退回 `en`，不应丢掉全部配置。
- 不认识的枚举值退回默认值时不产生 `ConfigWarning`，下次保存时被默认值覆盖。
- 现有的 `ZoomAnchor` 仍按原方式解码，本轮不改。
- `LanguagePreference.resolved` 的规则：
  1. `override` 去掉首尾空白并转成小写后，取第一个 `-` 或 `_` 之前的部分（第一个子标签）。它与 `en`、`zh`、`ru`、`ja`、`ko` 之一完全相同时，返回对应语言。`override` 来自环境变量 `EVEO_LANG`，只用于调试。
  2. 选项不是 `system` 时，返回同名的语言。
  3. 选项是 `system` 时，按顺序看 `preferredLanguages` 的每一项，取第一个子标签是受支持语言代码的那一项（如 `zh-Hans-CN`、`zh_CN` 对应 `zh`）；都不匹配时返回 `en`。只比第一个子标签，不比前缀：`kok-IN`、`rue`、`jam`、`zha` 不算 `ko`、`ru`、`ja`、`zh`。
- `ConfigValidator.normalized` 增加：`borderThickness` 夹到 1～6；`borderColor`、`combatAlert.color` 不是合法的 `#RRGGBB` 时改回默认值；`durationSeconds` 夹到 1～10；`minimumDamage` 夹到 1～100,000；`eveLogDirectory` 去掉首尾空白后是空串时改成 `nil`。被改正的字段路径照旧记入 `valuesClamped`。

### 3.3 升级后的变化

- 已有配置文件的用户升级后，每个配置方案的缩略图都出现边框（F1 的要求）。
- 界面语言变成英文，包括此前按系统语言显示中文的用户。用户在「通用」页选一次「中文」后保持。发布说明应写明这一点。
- 热键的作用范围默认是 `global`，行为与 v1 相同。
- 战斗提醒默认关闭，不读日志目录，不触发权限提示。

## 4 缩略图边框

### 4.1 规则

- 边框画在画面之上，不缩小画面，与高亮边框共用一个图层（架构文档 7.3 节的边框层）。
- 每个缩略图只画一种静态边框，取值顺序是：
  1. `highlightColor` 不为 `nil`（高亮已打开，且是活动客户端）：用高亮的颜色和粗细。
  2. 否则 `borderColor` 不为 `nil`：用边框的颜色和粗细。
  3. 否则不画。
- 战斗提醒的闪烁在边框层之上另有一层（7.8 节），两者互不影响。
- 边框颜色不按角色区分。按角色的颜色仍只有高亮（`highlightColors`）。

默认值的取舍：缩略图的默认透明度是 0.5，边框随面板一起变淡。`#C0C0C0` 在深色的游戏画面上仍能看清；粗细取 2 点，比高亮的默认值 3 点细，两者能分清。

### 4.2 Core 的改动

```swift
// [Core] Planning/PlannerModels.swift：ThumbnailPresentation 新增 3 个属性
//     public var borderColor: String?       // nil：不画中性边框
//     public var borderThickness: Double
//     public var alert: ThumbnailAlert?     // nil：没有战斗提醒，见 7.7 节
public struct ThumbnailAlert: Sendable, Equatable {
    public var color: String; public var style: CombatAlertStyle
}
```

规划器的取值：`borderColor` 在 `overlay.borderEnabled` 为真时取 `overlay.borderColor`，否则取 `nil`；`borderThickness` 取 `overlay.borderThickness`。这两个值不看客户端是否活动，由视图按 4.1 节的顺序选用。
`highlightColor` 与 `highlightThickness` 的规则不变。

### 4.3 App 的改动

- `ThumbnailContentView.apply`：按 4.1 节的顺序设置边框层的 `borderColor`、`borderWidth` 和 `isHidden`。
- 「预览与布局」页的「外观」一组，在高亮的 3 行之前加 3 行：边框开关、边框颜色（`HexColorPicker`）、边框粗细（`IntStepperRow`，1～6）。开关关闭时后两行置灰。

## 5 多语言

### 5.1 语言设置

- 语言存在 `general.language`，对全部配置方案生效。
- 设置窗口新增「通用」页，放语言选择。选项依次是 `English`、`中文`、`Русский`、`日本語`、`한국어`（用 `AppLanguage.autonym`，不翻译），最后是「跟随系统」。
- 选择后立即生效，不重启应用（5.4 节）。
- 环境变量 `EVEO_LANG` 仍可覆盖，取值扩大为 `en`、`zh`、`ru`、`ja`、`ko`。

### 5.2 译文的来源与审校

`en` 与 `zh` 沿用 v1 的文字。`ru`、`ja`、`ko` 的译文由模型生成，没有经过母语者审校。

- 每个 `ru`、`ja`、`ko` 文字文件的文件头注释应写明：「译文由机器生成，待母语者审校」。
- README 的语言一节写同样的说明。
- 「通用」页在语言选择下方显示一行说明：部分译文由机器生成，欢迎指正。
- 译文应使用 5.5 节的词表，三个工作包的用词保持一致。
- 系统权限的名称（辅助功能、屏幕录制、文件与文件夹）应使用 macOS 在该语言下的官方名称。

### 5.3 文字的组织方式

不用 SwiftPM 资源，原因见架构文档 7.4 节。文字仍写在 Swift 源码里，按以下方式组织：

- 每个域一个协议，声明这个域的全部文字。不带参数的文字是只读属性，带参数的文字是函数。
- 每种语言对每个协议各有一个不含存储属性的结构体实现，每条文字写成一个计算属性或函数。
- 某种语言漏了一条文字时，结构体不满足协议，编译不过。完整性由编译器保证，不靠运行时检查。
- 带参数的文字不用格式串，各语言在函数里自己拼接。俄语的复数有 3 种形式，由俄语的实现自己处理。
- v1 的 3 条格式串（`secondsFormat`、`fpsFormat`、`millisecondsFormat`）宜改成函数，如 `seconds(_ value: Double) -> String`，免去核对占位符。

域的划分与归属：

| 域 | 协议 | 访问方式 | 内容 | 归属 |
| --- | --- | --- | --- | --- |
| 菜单与缩略图 | `MenuStrings`、`EditMenuStrings`、`ThumbnailStrings` | `L10n.menu`、`L10n.editMenu`、`L10n.thumbnail` | v1 的 `L10n.Menu`、`L10n.EditMenu`、`L10n.Thumbnail` | WP-1 |
| 设置窗口 | `SettingsStrings` | `L10n.settings` | v1 的 `L10n.Settings`，去掉「切换与热键页」一组；加上边框、语言、「通用」页与「提醒」页的页名 | WP-1 |
| 热键 | `HotkeyStrings` | `L10n.hotkeys` | v1「切换与热键页」一组的 26 条，加上鼠标与作用范围的新文字 | WP-2 |
| 战斗提醒 | `CombatStrings` | `L10n.combat` | 「提醒」页的全部文字 | WP-3 |

```swift
// [App] Localization/L10n.swift（WP-1）
enum L10n {
    static let appName = "EVE-O Preview"
    /// 当前界面语言。用锁保护，可在任何线程读取。
    static var language: AppLanguage { get }
    /// 设置界面语言，返回语言是否变了。
    @discardableResult static func setLanguage(_ language: AppLanguage) -> Bool
    static var menu: any MenuStrings { get }
    static var editMenu: any EditMenuStrings { get }
    static var thumbnail: any ThumbnailStrings { get }
    static var settings: any SettingsStrings { get }
}

// [App] Localization/Strings.swift（WP-1），只列出形式
protocol MenuStrings: Sendable {
    var showAll: String { get }
    func clientCount(_ count: Int) -> String
}

// [App] Localization/en/Strings+en.swift（WP-1），只列出形式
struct MenuStringsEN: MenuStrings {
    var showAll: String { "Show All Thumbnails" }
    func clientCount(_ count: Int) -> String { count == 1 ? "1 client" : "\(count) clients" }
}
```

- 每个访问器用 `switch L10n.language` 返回对应语言的结构体。`switch` 不写 `default`，以后加语言时编译器会指出每一处要补的地方。
- WP-1 的 4 个访问器写在 `L10n.swift` 里。`L10n.hotkeys` 定义在 `HotkeyStrings.swift`（WP-2），`L10n.combat` 定义在 `CombatStrings.swift`（WP-3），都写成 `extension L10n`。三个工作包不改同一个文件。
- `L10n.language` 的名字与类型由 WP-0 定下（9.1 节），WP-1 迁移时保持不变，WP-2 与 WP-3 的访问器依赖它。
- `L10n.language` 的存储用 `OSAllocatedUnfairLock<AppLanguage>`，初始值 `.en`。这样 `L10n` 不受 actor 隔离限制，现有的调用处不用加标注。
- 文件布局：`Sources/EVEOPreview/Localization/` 下放协议文件和 `L10n.swift`；每种语言一个子目录（`en`、`zh`、`ru`、`ja`、`ko`），子目录里每个域一个文件，文件名带语言后缀，如 `ru/Strings+ru.swift`、`ru/HotkeyStrings+ru.swift`、`ru/CombatStrings+ru.swift`。同一个模块里文件名不重复。
- 加一种语言的步骤：给 `AppLanguage` 与 `LanguagePreference` 各加一个成员，新建一个语言子目录并实现全部协议，再按编译错误补全各处 `switch`。
- 文件长度：`Strings+<语言>.swift` 约 150 条，一条一行，加分组注释后宜在 400 行以内；超过时把设置窗口的部分拆到 `SettingsStrings+<语言>.swift`。

### 5.4 即时切换

`configDidChange` 发现 `general.language` 变了以后，协调器按以下顺序做（`AppCoordinator+Language.swift`，WP-1）：

1. 调 `L10n.setLanguage(新选项.resolved(preferredLanguages: Locale.preferredLanguages, override: EVEO_LANG 的值))`。
2. 如果返回值为真，调 `onLanguageChanged?()`，再调 `setNeedsReplan()`。

启动时，`AppDelegate` 在读完配置、建任何界面之前做一次第 1 步。

各处界面的刷新办法：

| 界面 | v1 的做法 | 切换语言后的刷新办法 |
| --- | --- | --- |
| 设置窗口的各页 | SwiftUI 视图每次求值时读 `L10n` | `SettingsRootView` 的内容区加 `.id(model.config.general.language)`，语言变了就重建视图树 |
| 设置窗口的标题 | 建窗口时设一次 | `onLanguageChanged` 里重设 `window.title` |
| 主菜单的「编辑」菜单 | 启动时建一次 | `onLanguageChanged` 里重建主菜单 |
| 菜单栏菜单 | 每次打开时重建（`menuNeedsUpdate`） | 不用处理 |
| 缩略图的占位文字 | 每次重算都重新设置 | 第 2 步的 `setNeedsReplan()` 已覆盖 |
| 缩略图的右键菜单 | 每次打开时新建 | 不用处理 |

`onLanguageChanged` 是 `AppCoordinator` 上的一个可选闭包（做法同 `openSettings`），由 `AppDelegate` 设置。
设置窗口重建视图树时，录制到一半的热键被取消（`HotkeyRecorderView` 的 `onDisappear` 已处理）。

### 5.5 词表

三个工作包的译文应使用下表的词。`ru`、`ja`、`ko` 三列由机器生成，待母语者审校。

| 英文 | 中文 | 俄文 | 日文 | 韩文 |
| --- | --- | --- | --- | --- |
| thumbnail | 缩略图 | миниатюра | サムネイル | 썸네일 |
| client | 客户端 | клиент | クライアント | 클라이언트 |
| profile | 配置方案 | профиль | プロファイル | 프로필 |
| cycle group | 循环组 | группа переключения | サイクルグループ | 순환 그룹 |
| hotkey | 热键 | горячая клавиша | ホットキー | 단축키 |
| border | 边框 | рамка | 枠線 | 테두리 |
| highlight | 高亮 | подсветка | ハイライト | 강조 표시 |
| combat alert | 战斗提醒 | боевое оповещение | 戦闘アラート | 전투 알림 |
| game log | 游戏日志 | игровой журнал | ゲームログ | 게임 로그 |
| settings | 设置 | настройки | 設定 | 설정 |
| mouse button | 鼠标按键 | кнопка мыши | マウスボタン | 마우스 버튼 |
| Accessibility（系统权限） | 辅助功能 | Универсальный доступ | アクセシビリティ | 손쉬운 사용 |
| Screen Recording（系统权限） | 屏幕录制 | Запись экрана | 画面収録 | 화면 기록 |
| Files and Folders（系统权限） | 文件与文件夹 | Файлы и папки | ファイルとフォルダ | 파일 및 폴더 |

「游戏日志」的俄文与日文取自 EVE 客户端自己写在日志文件头里的标题（`Игровой журнал`、`ゲームログ`，见上游的录制样例）。

## 6 热键：鼠标按键与作用范围

### 6.1 字符串语法

热键在配置里仍是字符串数组。一条字符串的语法是：

```text
热键字符串 = 热键 [ "@" 作用范围 ]
作用范围   = "global" | "game"
热键       = { 修饰键 "+" } 触发键
触发键     = 键名 | "Key" 键码 | "Mouse" 序号
```

- 修饰键、键名与 `Key<键码>` 的规则不变（架构文档 5.5 节）。
- `Mouse<序号>` 的序号是 3～32，对应 `CGEvent` 的按钮号 2～31，即 `按钮号 = 序号 - 1`。

| 写法 | 按钮号 | 常见的物理按键 |
| --- | --- | --- |
| `Mouse3` | 2 | 中键（按下滚轮） |
| `Mouse4` | 3 | 侧键（后退） |
| `Mouse5` | 4 | 侧键（前进） |
| `Mouse6`～`Mouse32` | 5～31 | 其他附加按键 |

- 左键（按钮号 0）和右键（按钮号 1）没有写法。`Mouse1`、`Mouse2`、`Mouse0`、`Mouse33` 都解析失败，记为 `unparsable`。
- 鼠标触发键可以带修饰键，也可以不带，如 `Mouse4`、`ctrl+Mouse4`、`shift+Mouse5`。
- 全部内容不区分大小写；各段与 `@` 两侧的空白去掉。
- 规范写法：修饰键顺序不变，触发键写成 `Mouse4` 的形式，作用范围紧跟在后，如 `ctrl+Mouse4@game`。没有后缀表示跟随配置方案的 `hotkeyDefaultScope`。
- `@` 后面不是 `global` 或 `game`、有多个 `@`、`@` 前面为空，都解析失败。

物理按键与按钮号的对应取决于鼠标与驱动，上表的第 3 列留给 V10 在用户的鼠标上核实。

### 6.2 Core 的类型

```swift
// [Core] Hotkeys/Hotkey.swift
public enum HotkeyTrigger: Sendable, Hashable {
    case key(UInt16)            // Carbon 虚拟键码
    case mouseButton(Int)       // CGEvent 的按钮号，2～31
}
public struct Hotkey: Sendable, Hashable {
    public var trigger: HotkeyTrigger
    public var modifiers: HotkeyModifiers
    public static let mouseButtonRange: ClosedRange<Int> = 2...31
    public init(trigger: HotkeyTrigger, modifiers: HotkeyModifiers)
    public init(keyCode: UInt16, modifiers: HotkeyModifiers)        // 保留，现有调用处不变
    public init?(mouseButton: Int, modifiers: HotkeyModifiers)      // 按钮号不在 2～31 时返回 nil
    public init?(string: String)                                    // 不接受 "@" 后缀
    public var keyCode: UInt16? { get }                             // 鼠标触发键返回 nil
    public var mouseButton: Int? { get }                            // 键盘触发键返回 nil
    public var isMouse: Bool { get }
    public func stringValue() -> String     // "ctrl+shift+F13"、"ctrl+Mouse4"
    public func displayString() -> String   // "⌃⇧F13"、"⌃Mouse4"
}

// [Core] Hotkeys/HotkeyScope.swift（新文件）
public enum HotkeyScope: String, Sendable, Codable, CaseIterable {
    case global     // 对所有应用生效
    case game       // 只在前台是 EVE 客户端时生效
}

// [Core] Hotkeys/HotkeySpec.swift（新文件）
/// 配置里一条热键字符串的解析结果。
public struct HotkeySpec: Sendable, Hashable {
    public var hotkey: Hotkey
    public var scope: HotkeyScope?          // nil：跟随配置方案的默认值
    public init(hotkey: Hotkey, scope: HotkeyScope? = nil)
    public init?(string: String)
    public func stringValue() -> String
    public func resolvedScope(profileDefault: HotkeyScope) -> HotkeyScope
}

// [Core] Hotkeys/HotkeyPlanner.swift：HotkeyBinding 新增 scope
public struct HotkeyBinding: Sendable, Hashable, Identifiable {
    public var id: UInt32; public var hotkey: Hotkey; public var action: HotkeyAction
    public var scope: HotkeyScope           // 已解析的作用范围
    public init(id: UInt32, hotkey: Hotkey, action: HotkeyAction, scope: HotkeyScope = .global)
}
```

`HotkeyAction`、`HotkeyIssue`、`HotkeyRejection`、`HotkeyPlan` 与 `HotkeyPlanner.plan(for:)` 的签名不变。`Hotkey.keyCode` 从 `UInt16` 变成 `UInt16?`，用到它的 4 处（`HotkeyPlanner`、`CarbonHotkeyRegistrar`、`HotkeyTests`、`HotkeyRecorderView`）由 WP-2 修改。

### 6.3 规划规则

`HotkeyPlanner.plan` 的遍历顺序与编号规则不变。每条字符串依次检查：

1. `HotkeySpec(string:)` 返回 `nil`：记 `unparsable`。
2. 键盘触发键：按原规则检查 `systemReserved` 与 `missingModifier`。鼠标触发键跳过这两项，没有修饰键也接受。
3. 与已接受的热键相同：记 `duplicate`。判断只看 `Hotkey`（触发键加修饰键），不看作用范围。`F13@game` 与 `F13@global` 是重复，后出现的被丢弃。
4. 通过检查：生成 `HotkeyBinding`，`scope` 取 `spec.resolvedScope(profileDefault: profile.hotkeyDefaultScope)`。

键盘热键与鼠标热键的触发键不同，互不重复。作用范围对 5 种动作都有效，包括全部隐藏与全部最小化。

作用范围放在哪一层的取舍：

- 只放在配置方案上：做不到「这个热键全局、那个热键只在游戏内」。
- 只放在每条热键上：用户想临时把全部热键改成只在游戏内时，要逐条改。
- 两者都有：平时改一个默认值，个别热键用后缀固定。本文采用这一种。菜单栏菜单另有一项「热键只在 EVE 内生效」，切换当前配置方案的 `hotkeyDefaultScope`。

`game` 的含义：前台是 EVE 客户端（`FrontmostContext.client`）。前台是本应用的设置窗口（`.selfApp`）或其他应用时都不生效。在设置窗口的文本框里打字时，热键不应触发。

### 6.4 平台协议

```swift
// [Core] Contracts/PlatformContracts.swift
public enum HotkeyFailureReason: Sendable, Equatable {
    case registrationRejected(status: Int32)    // Carbon 的 RegisterEventHotKey 返回错误
    case accessibilityRequired                  // 鼠标绑定：没有辅助功能权限
    case eventTapUnavailable                    // 鼠标绑定：有权限，但系统没有建出事件监听
}
public struct HotkeyRegistrationFailure: Sendable, Equatable {
    public var binding: HotkeyBinding
    public var reason: HotkeyFailureReason      // 取代原来的 status: Int32
    public init(binding: HotkeyBinding, reason: HotkeyFailureReason)
}
@MainActor public protocol HotkeyRegistrar: AnyObject {
    var onHotkey: (@MainActor (HotkeyBinding.ID) -> Void)? { get set }
    /// 先停用全部旧绑定，再按当前的前台状态启用新绑定。返回失败的项。
    @discardableResult func replaceAll(with bindings: [HotkeyBinding]) -> [HotkeyRegistrationFailure]
    /// 告知前台是不是 EVE 客户端。值变化时启用或停用作用范围是 game 的绑定，返回当前失败的项。
    @discardableResult func setGameFrontmost(_ isFrontmost: Bool) -> [HotkeyRegistrationFailure]
    func suspend()
    @discardableResult func resume() -> [HotkeyRegistrationFailure]
    /// 注册器自己发现失败项可能变了时在主线程调用（如鼠标事件监听被系统关掉、没能重新打开）。
    var onStateChange: (@MainActor () -> Void)? { get set }
    /// 巡检：后端没有按预期工作时拆除并记为失败，监听不可用的失败项定时重试；返回当前全部失败的项。
    /// 协调器每个轮询周期调用一次。
    @discardableResult func checkHealth() -> [HotkeyRegistrationFailure]
}
```

`PlatformServices.makeLive()` 里的实现从 `CarbonHotkeyRegistrar` 换成 `SystemHotkeyRegistrar`。

### 6.5 `SystemHotkeyRegistrar`

`SystemHotkeyRegistrar`（`@MainActor`）持有绑定表、`isGameFrontmost`、`isSuspended`、键盘后端 `CarbonHotkeyRegistrar` 和鼠标后端 `MouseEventTap`。它把绑定按触发键分成两组。

键盘绑定：

- 「应启用」的条件是：没有暂停，且作用范围是 `global`，或作用范围是 `game` 且 `isGameFrontmost` 为真。
- `replaceAll`：调 `CarbonHotkeyRegistrar.beginNewGeneration()`（注销全部 Carbon 热键，代数加 1），再注册应启用的那些。
- `setGameFrontmost`：值没变时不做任何事。值变了，只注册或注销作用范围是 `game` 的那一组，`global` 的热键不动。
- 作用范围是 `game` 的热键在前台不是 EVE 时没有注册，按键照常传给前台应用。这是「只在游戏内生效」对键盘的实现办法。
- `CarbonHotkeyRegistrar` 改成内部的键盘后端，不再实现 `HotkeyRegistrar` 协议。它提供 `register(_:)`、`unregister(ids:)`、`unregisterAll()`、`beginNewGeneration()`，事件处理器与修饰键换算不变。
- 代数：`HotkeyPlanner` 每次规划都从 1 起重新编号。已排进主线程事件队列的热键事件在 `replaceAll` 之后才分发时，旧编号会对上新规划里别的动作。所以 `EventHotKeyID.id` 的高 8 位放代数（0～255，循环使用），低 24 位放绑定 id；绑定 id 大于 `0x00FFFFFF` 时不注册，记为 `registrationRejected`。事件处理器收到事件后，代数不是当前代数或这个 id 已注销时丢弃。只有 `replaceAll` 开始新的一代，前台变化、暂停与恢复不改代数。编码与解码在 Core 的 `CarbonHotkeyID`（`Hotkeys/HotkeyBackendRules.swift`），用例在 `HotkeyBackendRulesTests`。

鼠标绑定：

- 绑定表里没有鼠标绑定时，不建事件监听，也不要求辅助功能权限。
- 有鼠标绑定时，先查 `AXIsProcessTrusted()`。为假时不调 `CGEvent.tapCreate`，每条鼠标绑定记一条 `accessibilityRequired`。
- 有权限时建事件监听（6.6 节）。`tapCreate` 返回 `nil` 时，每条鼠标绑定记一条 `eventTapUnavailable`，之后由巡检定时重试（本节末尾）。
- 事件监听的开关：存在此刻生效的鼠标绑定（没有暂停，且作用范围是 `global`，或作用范围是 `game` 且 `isGameFrontmost` 为真），或者还有按下已被吞掉、没等到松开的按钮时，监听打开（`CGEvent.tapEnable`）；否则关闭。只有 `game` 范围的鼠标绑定时，离开游戏且没有这样的按钮，监听是关的，其他应用里的鼠标事件不经过本应用。只因还按着按钮而开着的监听最多再开 10 秒（6.6 节）。
- `replaceAll` 传入的鼠标绑定为空时：没有已吞掉按下的按钮就立即拆掉事件监听并结束它的线程；有的话等它松开（或 10 秒到期）后再拆。没有辅助功能权限时，不论绑定表是否为空都立即拆掉，不等松开。

`suspend()`（录制热键期间、应用退出期间）注销全部 Carbon 热键，并让鼠标后端进入暂停。暂停期间新的按下一律放行，录制器因此能收到已绑定的鼠标按键。没有已吞掉按下的按钮时监听立即关闭，有的话等它松开（或 10 秒到期）后关闭。`resume()` 按当前状态恢复。

失败项：键盘的失败项来自最近一次注册；没有注册过的 `game` 范围热键不产生失败项，等前台第一次变成 EVE 时才知道。`replaceAll`、`setGameFrontmost`、`resume`、`checkHealth` 都返回当前全部失败项，协调器存入 `hotkeyFailures`，变化时通知设置窗口。

`checkHealth()`（巡检）的规则：

- 监听应打开却是关的时，没有辅助功能权限就拆掉监听，每条鼠标绑定记一条 `accessibilityRequired`；有权限就重新打开一次，仍是关的就拆掉，记 `eventTapUnavailable`。
- `accessibilityRequired` 不重试，保留到下一次 `replaceAll`（辅助功能权限变化时）。
- `eventTapUnavailable`（`tapCreate` 返回 `nil`，或巡检拆掉了监听）由巡检定时重试。没有暂停且距上次失败满 10 秒（`MouseTapRetry.interval`）时，重新建一次监听。建成后失败项清除；仍建不成就重新计时，失败项不变时不再记错误日志。
- 监听线程自己没能重新打开监听时调 `onStateChange`，协调器随即巡检一次。

### 6.6 `MouseEventTap`

```swift
// [Platform] Hotkeys/MouseEventTap.swift（只在 Platform 内部使用）
// 匹配规则在 Core 的 Hotkeys/HotkeyActivation.swift（MouseHotkeyMatcher），用例在 HotkeyActivationTests、
// HotkeyScopeEdgeCaseTests。
final class MouseEventTap: Sendable {
    enum StartResult: Sendable, Equatable { case notNeeded, running, accessibilityRequired, unavailable }
    struct State: Sendable {
        var matcher = MouseHotkeyMatcher()   // 绑定表、isGameFrontmost、isSuspended、swallowedButtons、releaseDeadline
        var generation: UInt64 = 0           // 替换绑定表、进入暂停时加 1
        var scheduledCheck: Double?          // 已安排的截止检查时刻
    }
    /// 事件监听的系统资源。CoreFoundation 的引用不是 Sendable，单独放一个盒子，只在持锁时读写。
    struct Resources: @unchecked Sendable {
        var port: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var thread: Thread?
        var finished: DispatchSemaphore?
    }
    let state: OSAllocatedUnfairLock<State>
    let resources: OSAllocatedUnfairLock<Resources>
    init(onFire: @escaping @MainActor @Sendable (UInt32) -> Void,
         onProblem: @escaping @MainActor @Sendable () -> Void)
    func update(bindings: [MouseHotkeyMatcher.Binding]) -> StartResult
    func setGameFrontmost(_ isFrontmost: Bool)
    func setSuspended(_ isSuspended: Bool)
    /// 按匹配状态打开、关闭或拆除监听，只在主线程调用。
    func reevaluate()
    /// 巡检：监听应打开却是关的时候处理，返回失败原因；没有问题时返回 nil。
    func checkHealth() -> StartResult?
    func shutdown()
    /// 在监听线程上判断一个事件，返回 true 表示吞掉。
    func handle(type: CGEventType, button: Int, flags: CGEventFlags) -> Bool
    /// 在监听线程上处理 tapDisabledByTimeout、tapDisabledByUserInput。
    func tapWasDisabled(_ type: CGEventType)
}
```

建立：

- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest:callback:userInfo:)`。
- 事件掩码只含 `otherMouseDown`、`otherMouseUp`、`otherMouseDragged`。键盘、左键、右键、滚轮与鼠标移动都不经过本应用。
- 回调是文件级的 C 函数，`userInfo` 是 `MouseEventTap` 的非持有指针。
- 用 `CFMachPortCreateRunLoopSource` 建事件源，加到一条专用线程的运行循环上。线程名 `EVEOPreview.MouseTap`，服务质量取 `userInteractive`，线程体只做 `CFRunLoopRun()`。
- 不放在主线程的原因：没匹配的中键、侧键事件也要等回调返回才继续传给游戏。主线程在布局或处理别的事件时，这些按键会被拖慢。专用线程上的回调只读一次加锁的状态，不等主线程。

判断（`handle`，在监听线程上，全程持锁）：

| 事件 | 条件 | 结果 |
| --- | --- | --- |
| `otherMouseDown` | 任何情况 | 先把这个按钮号移出 `swallowedButtons`，再看下面三行 |
| `otherMouseDown` | 已暂停 | 放行 |
| `otherMouseDown` | 存在绑定满足：按钮号相同，修饰键完全相同，且作用范围是 `global` 或 `isGameFrontmost` 为真 | 把按钮号放进 `swallowedButtons`，调 `onFire(id)`，吞掉 |
| `otherMouseDown` | 其他 | 放行 |
| `otherMouseUp` | 按钮号在 `swallowedButtons` 里 | 移出集合，吞掉 |
| `otherMouseDragged` | 按钮号在 `swallowedButtons` 里 | 吞掉 |
| `otherMouseUp`、`otherMouseDragged` | 其他 | 放行 |

- 按钮号取 `event.getIntegerValueField(.mouseEventButtonNumber)`。
- 修饰键取 `event.flags` 里的 `maskCommand`、`maskAlternate`、`maskControl`、`maskShift` 四位，其余位（大写锁定、fn、小键盘）忽略。「完全相同」与 Carbon 热键的匹配方式一致：绑定是 `Mouse4` 时，按住 Shift 点侧键不触发。
- 松开是否吞掉只看 `swallowedButtons`，不看松开时的修饰键、前台与暂停状态。按下被吞掉的那次点击，它的拖动和松开一定被吞掉；按下被放行的点击，它的拖动和松开一定被放行。
- 为了做到上一条，绑定表被替换、前台变化、进入暂停都不清空 `swallowedButtons`，监听也不关：`shouldListen` 是「存在此刻生效的绑定，或 `swallowedButtons` 不空」。最后一个已吞掉的按钮松开后，监听线程切回主线程调 `reevaluate()`，此时没有生效的绑定就关闭监听，绑定表已空就拆除。
- 截止时刻：监听只因还按着按钮而开着时，从进入这种状态的那一刻起最多再开 10 秒（`MouseHotkeyMatcher.releaseTimeout`），`reevaluate()` 在截止时刻再调一次，到期后清空 `swallowedButtons` 并关闭监听。绑定一直生效时不计时，按住多久都不会提前放弃。截止时刻防止松开事件丢失时监听一直开着。
- `swallowedButtons` 不能留下过期的按钮号。除了每次按下时先移出、截止时刻到期，以下时刻整个清空：收到 `tapDisabled*` 事件且确认是被系统关掉、巡检发现监听是关的、监听被拆除。这些时刻之后的松开事件收不到，不清空的话，下一次没匹配的点击会被吞掉松开。
- 按住侧键期间移动鼠标会产生 `otherMouseDragged`。按下已被吞掉时，这些拖动事件也吞掉，游戏不会收到没有按下的拖动。
- `onFire` 用 `DispatchQueue.main.async` 切回主线程，再调 `SystemHotkeyRegistrar.onHotkey`。切换时带上判断时的代数与时刻。到主线程后，代数已变（绑定表被替换、进入暂停，编号可能已重排）时丢弃这次触发；排队超过 0.5 秒（`maxFireAge`）时也丢弃，因为主线程卡住时前台与作用范围可能已经变了。
- 回调收到 `tapDisabledByTimeout` 或 `tapDisabledByUserInput`、且监听应打开却是关的时：清空 `swallowedButtons`；没有辅助功能权限时不重新打开，切回主线程调 `onProblem`，由巡检拆除监听并显示 `accessibilityRequired`；有权限时调 `CGEvent.tapEnable(tap:enable: true)`，再用 `CGEvent.tapIsEnabled` 确认真的打开了才记「已重新打开」，仍是关的就调 `onProblem`，巡检拆除并显示 `eventTapUnavailable`，之后按 6.5 节定时重建。该事件一律放行。监听线程上不调 `shutdown()`：它要等监听线程自己结束。
- 2026-11-20 实测：macOS 27 上本应用自己调 `tapEnable(false)` 关闭监听时，回调也会收到 `tapDisabledByUserInput`。所以只有「监听应打开、实际却被关闭」时才按系统禁用处理（`MouseEventTap.swift`），新建的监听也不再先关后开。
- 匹配只看状态快照。用户切进游戏后、前台通知到达之前（几十毫秒内）按下的侧键会被放行给游戏，可以接受。

权限：`options: .defaultTap` 的事件监听能改动事件流，按平台文档由辅助功能权限放行。macOS 27 上只凭辅助功能权限能否建成，由 WP-2 的第一项任务用探针核实（V9）。如果系统另外要求「输入监控」权限，WP-2 停下并报主会话，由主会话改本文和权限页。

权限变化：协调器每次轮询与巡检都读权限状态。辅助功能权限从无到有或从有到无时，协调器重新调 `replaceAll`。授权后鼠标绑定自动生效；撤销后事件监听被拆掉，鼠标绑定显示 `accessibilityRequired`。

没有辅助功能权限时的降级：键盘热键（两种作用范围）照常工作，因为前台判断只用 `NSWorkspace`（架构文档 E5、V8）。鼠标绑定全部不生效，设置窗口在每条鼠标绑定旁显示「需要辅助功能权限」，权限页的说明里写明鼠标热键依赖这项权限。

### 6.7 协调器

`AppCoordinator+Hotkeys.swift`（WP-2）增加两个入口，调用点由 WP-0 预先写进 `AppCoordinator.swift`：

- `frontmostDidChange()`：在 `refreshFrontmost()` 更新 `frontmost` 之后调用。它调 `services.hotkeys.setGameFrontmost(frontmost 是 .client)`，并更新 `hotkeyFailures`。轮询与前台通知两条路径都经过 `refreshFrontmost()`，所以只有这一处推送。
- `permissionsDidChange(old:new:)`：权限状态变化时调用。`accessibility` 变了就用当前的 `hotkeyPlan.bindings` 重新调 `replaceAll`。

第一轮反馈的审查修复又加了以下三处：

- `checkHotkeyHealth()`：先调 `refreshPermissions()`（辅助功能权限变了会重新调 `replaceAll`），再调 `services.hotkeys.checkHealth()` 并更新 `hotkeyFailures`。`start()` 启动一个单独的巡检循环，每隔 `general.pollIntervalMs`（300 毫秒～2,000 毫秒）调一次；`services.hotkeys.onStateChange` 触发时也调一次。巡检不放进 `pollTick()`：窗口枚举没返回时 `pollTick()` 会跳过后来的轮询。
- `stop()`：先调 `services.hotkeys.suspend()`，再取消轮询与巡检循环。退出期间不吞新的点击，也不触发动作；退出开始后 `resumeHotkeys()` 不恢复热键。
- `updateBackgroundActivity()`（`AppCoordinator+Activity.swift`）：战斗提醒已开启，或有鼠标绑定且鼠标绑定没有失败项时，用 `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)` 声明一项后台活动，防止 App Nap 压低计时器精度；两个条件都不满足或应用退出时结束。写 `hotkeyFailures` 的地方（`reregisterHotkeys()`、`updateHotkeyFailures(_:)`、`resumeHotkeys()`）都随后调它。

`rebuildHotkeys()` 在 `replaceAll` 之后补调一次 `setGameFrontmost`，保证新绑定按当前前台状态启用。

### 6.8 录制与设置界面

录制器（`HotkeyRecorderView.swift`）：

- 本地事件监视器的掩码从 `.keyDown` 扩大为 `[.keyDown, .otherMouseDown]`。
- 收到 `otherMouseDown` 且 `buttonNumber` 在 2～31 内时，记录 `Hotkey(mouseButton:modifiers:)`，并消费这个事件。
- 本地监视器只在事件发给本应用时收到，所以录制鼠标按键时指针应停在设置窗口内。提示文字改为「按下组合键或鼠标侧键（指针停在本窗口内）…」。
- 左键与右键不录制，行为与 v1 相同（左键点别处、窗口失去焦点都会取消录制）。
- `Outcome.recorded` 的关联值不变，仍是 `Hotkey`。

热键列表（`HotkeyListEditor`，从 `HotkeyRecorderView.swift` 拆到 `Settings/HotkeyListEditor.swift`）：

- 每一行在热键按钮右侧加一个作用范围菜单，3 项：「跟随默认（当前：全局或仅游戏内）」「全局」「仅游戏内」。菜单的图标反映已解析的作用范围。
- 行的读写用 `HotkeySpec`：显示时用 `spec.hotkey.displayString()`，保存时用 `spec.stringValue()`。
- 新录制的鼠标热键写成 `@game`。原因：全局的鼠标绑定会在所有应用里吞掉这个按键，例如浏览器的后退键会失效。重新录制已有的一行时保留这一行原来的作用范围；原来没有后缀而新录的是鼠标按键时，补上 `@game`。
- 新录制的键盘热键不写后缀。
- 判断重复添加时比较 `Hotkey`，不比较字符串。

「切换与热键」页：

- 页首加一行「热键的默认作用范围」，分段选择「全局」与「仅游戏内」，绑定 `hotkeyDefaultScope`。
- 说明文字改为：键盘热键应包含 Ctrl、Option 或 Command 之一，F1～F20 与小键盘数字可以单独使用；鼠标的中键与侧键可以单独使用，触发时这次点击不会传给游戏。
- 问题提示增加两种：`accessibilityRequired` 显示「需要辅助功能权限」，`eventTapUnavailable` 显示「无法监听鼠标」。`registrationRejected` 沿用「注册失败（错误码）」。

菜单栏菜单（`StatusItemController.swift`）：在「全部最小化」之后加一项「热键只在 EVE 内生效」，带勾选状态，点击后在 `global` 与 `game` 之间切换当前配置方案的 `hotkeyDefaultScope`。

### 6.9 探针

`EVEOProbe mousetap [秒数]`（WP-2 的第一项产出，文件 `Sources/EVEOProbe/MouseTapProbe.swift`）：

1. 打印 `AXIsProcessTrusted()` 的结果。
2. 建一个与 6.6 节相同的事件监听，打印是否建成。
3. 在给定的秒数内（默认 20 秒），打印收到的每个事件的类型、按钮号、修饰键，全部放行。
4. 带 `--swallow <按钮号>` 时吞掉该按钮的按下、拖动与松开，用来核对游戏是否还能收到。

探针要用户按鼠标按键配合，运行前应和用户约好时间，不在用户游戏时自行运行。

## 7 战斗提醒

### 7.1 总体流程

```text
EVE 客户端写 Gamelogs/<会话文件>.txt
   → CombatLogTailer（Platform，自己的串行队列）：发现文件、读新增的字节
   → LogLineFramer（Core）：按编码切成完整的行
   → CombatLogHeaderParser（Core）：从文件头取收听者（角色名）
   → CombatLogParser（Core）：把一行归类成 CombatLineKind
   → FileCombatLogMonitor（Platform，主线程）：onEvents([CombatLogEvent])
   → AppCoordinator：按规则决定是否提醒，写 session.combatAlerts，请求重算
   → ThumbnailPlanner：ThumbnailPresentation.alert
   → AlertFlashLayer（App）：闪烁动画
```

只读日志文件，不写、不改、不删 EVE 目录下的任何内容，也不向游戏发送任何输入。

### 7.2 Core 的类型

```swift
// [Core] CombatLog/CombatLogModels.swift（新文件）
public enum CombatLineKind: Sendable, Equatable {
    case incomingDamage(amount: Int)    // 本角色受到伤害
    case outgoingDamage(amount: Int)    // 本角色造成伤害
    case incomingMiss                   // 对方攻击本角色但没有命中
    case outgoingMiss                   // 本角色的攻击没有命中
    case otherCombat                    // combat 类别的其他消息，或判断不了方向的伤害行
    case other                          // 其他类别
}
public struct CombatLogLine: Sendable, Equatable {
    public var category: String         // 小写，如 "combat"
    public var kind: CombatLineKind
}
public struct CombatLogEvent: Sendable, Equatable {
    public var character: String        // 文件头里的收听者
    public var kind: CombatLineKind     // 只会是 incomingDamage 或 incomingMiss
    public init(character: String, kind: CombatLineKind)
}
public enum CombatLogStatus: Sendable, Equatable {
    case stopped
    case watching(directory: String, followedFiles: Int)
    case directoryNotFound(path: String)
    case accessDenied(path: String)
}

// [Core] CombatLog/CombatLogParser.swift（新文件）
public enum CombatLogParser {
    /// 解析一行。不是「[ 时间 ] (类别) 正文」形式的行返回 nil。
    public static func parse(_ line: String) -> CombatLogLine?
    /// 去掉标记，得到可见文字。
    public static func plainText(_ markup: String) -> String
}

// [Core] CombatLog/CombatLogCatalog.swift（新文件）：7.5、7.6 节的多语言短语表
public enum CombatLogCatalog {
    public static let listenerLabels: [String]
    public static let incomingWords: [String]
    public static let outgoingWords: [String]
    public static let incomingMissMarkers: [String]
    public static let missMarkers: [String]
}

// [Core] CombatLog/CombatLogHeaderParser.swift（新文件）
public struct CombatLogHeader: Sendable, Equatable {
    public var listener: String?        // nil：文件头里没有收听者
    public var isComplete: Bool         // false：还没读到第二条分隔线
}
public enum CombatLogHeaderParser {
    public static let maxHeaderLines = 12
    public static func parse(_ lines: [String]) -> CombatLogHeader
}

// [Core] CombatLog/LogLineFramer.swift（新文件）
public enum LogTextEncoding: Sendable, Equatable { case utf8, utf16LittleEndian, utf16BigEndian }
public struct LogLineFramer: Sendable {
    public private(set) var encoding: LogTextEncoding?      // nil：还没读到足够的字节
    /// encoding 为 nil 时按开头的字节判断编码；有值时直接使用，不做 BOM 判断。
    public init(encoding: LogTextEncoding? = nil, maxLineBytes: Int = 65_536)
    /// 追加一段字节，返回这次凑齐的完整行（不含换行符）。不完整的尾部留到下次。
    public mutating func append(_ data: Data) -> [String]
    public mutating func reset()
}

// [Core] CombatLog/CombatLogDirectory.swift（新文件）
public enum CombatLogDirectory {
    /// 按优先顺序返回可能的 Gamelogs 目录路径。
    public static func candidates(configured: String?, homeDirectory: String) -> [String]
}

// [Core] CombatLog/CombatAlertRules.swift（新文件）
public enum CombatAlertRules {
    public static func triggers(_ kind: CombatLineKind, settings: CombatAlertSettings) -> Bool
    public static func extended(_ existing: CombatAlertWindow?, now: Double, duration: Double) -> CombatAlertWindow
}

// [Core] Model/RuntimeModels.swift：SessionState 新增
//     public var combatAlerts: [WindowID: CombatAlertWindow]
public struct CombatAlertWindow: Sendable, Equatable {
    public var startedAt: Double; public var until: Double      // 单调时钟的秒数
    public init(startedAt: Double, until: Double)
}

// [Core] Contracts/PlatformContracts.swift
@MainActor public protocol CombatLogMonitor: AnyObject {
    /// 一批受击事件，每个角色至多两条（伤害最大的一条与未命中各一条）。在主线程调用。
    var onEvents: (@MainActor ([CombatLogEvent]) -> Void)? { get set }
    var onStatusChange: (@MainActor (CombatLogStatus) -> Void)? { get set }
    var status: CombatLogStatus { get }
    /// 开始跟踪。directory 为 nil 时自动查找。目录与上次相同时不做任何事，不同时切换目录。
    func start(directory: String?)
    func stop()
}
// PermissionPane 新增 case filesAndFolders；PlatformServices 新增 let combatLog: any CombatLogMonitor
```

### 7.3 目录与文件的发现

`CombatLogDirectory.candidates` 的规则：

- `configured` 为 `nil`：返回 `["<homeDirectory>/Documents/EVE/logs/Gamelogs"]`（L1）。
- `configured` 有值：先展开开头的 `~`。路径的最后一段是 `Gamelogs`（不区分大小写）时只返回它自己；否则返回 `["<configured>/Gamelogs", "<configured>"]`。用户选 `logs` 目录或直接选 `Gamelogs` 目录都能用。

`CombatLogTailer` 取候选里第一个存在的目录。都不存在时状态是 `directoryNotFound(第一个候选)`，每 10 秒重查一次（EVE 首次运行后才建目录）。列目录被系统拒绝时状态是 `accessDenied`（7.9 节）。

扫描目录（`rescan`）的规则：

1. 列出目录下的 `.txt` 文件，取每个文件的修改时间和创建时间。
2. 只看修改时间在最近 48 小时内的文件。EVE 每天例行维护时全部客户端断线，一个会话文件不会连续写一天以上；更早的文件如果又被写入，修改时间更新后会在下一次扫描时进入范围。
3. 对每个没见过的文件，读开头至多 2,048 字节，用 `LogLineFramer` 与 `CombatLogHeaderParser` 取收听者。结果按文件名缓存，以后的扫描不重读。文件头还不完整的文件（刚建出来）不缓存，记进 `pendingHeaders`；有这样的文件时，2 秒的保险定时器到点就重新扫描，再读一次文件头，直到读完整。
4. 文件头完整但没有收听者的文件（登录界面阶段的文件，L3）记为忽略。
5. 同一个收听者有多个文件时，只跟踪文件名最大的那个（文件名以时间开头，最大即最新，L2）。角色重新登录后有了新文件，旧文件停止跟踪。
6. 同时跟踪的文件至多 16 个；超过时保留文件名最大的 16 个。

起点（「启动后只读新内容」按字节偏移量定义；只有下面第 4 条的积压过滤看日志行里的时间）：

- 文件的创建时间早于 `CombatLogTailer` 的启动时刻减 2 秒：起点是当前的文件末尾。历史内容不读、不触发提醒。
- 否则（跟踪开始后才建的新文件）：起点是 0。
- 跟踪过的文件再次跟踪时（目录被拒绝后恢复、目录重新出现），一律从末尾读起。跟踪过的文件名记在 `everFollowed` 里，停止监视目录时不清空，扫描时只保留目录里还在的文件名。否则启动后才建的文件会把已经提醒过的历史行再提醒一次。
- 起点是 0、但第一次跟踪得晚的文件（访问权限恢复后才第一次读到、16 个文件的上限腾出名额），接入时文件里已有的内容是积压。读积压时，行里的时间（UTC，由 `CombatLogParser.logTime` 解析）早于接入时刻减 5 秒的行丢弃，解析不出时间的行也丢弃（无法证明是新写入的，宁可漏报）。过滤按读取计：一次读取从积压里开始时，这次读到的行全部过滤（一次至多 1 MiB，可能含接入后才写入的行）；偏移量过了积压末尾之后的读取不过滤。规则在 `CombatLogReplayGuard.shouldKeep`，用例在 `CombatLogReplayTests`。5 秒大于 2 秒的保险周期加 1 秒的时间戳粒度。本机时钟与 EVE 时间相差超过 5 秒时，这条过滤会多丢或少丢，正常跟踪不受影响。
- 从文件末尾开始时，第一段可能是半行。半行不以 `[ ` 开头，`CombatLogParser.parse` 返回 `nil`，被丢弃。

触发扫描的时机：启动时一次；目录的文件系统事件到达后 200 毫秒一次（期间的多次事件合并）；此外每 30 秒一次，作为保险。

### 7.4 读取新增内容

机制的取舍：

| 办法 | 结论 |
| --- | --- |
| `DispatchSource` 的文件系统对象事件源（kqueue） | 采用。写入发生时内核立即通知，空闲时没有任何唤醒 |
| FSEvents | 不采用。事件有合并延迟，面向整棵目录树，这里只看一个目录下的十几个文件 |
| 只靠定时查文件长度 | 不单独采用。延迟由周期决定，周期短了又增加空闲唤醒。只留一个 2 秒的保险 |

做法：

- 目录：用 `O_EVTONLY` 打开，事件源监听 `.write`、`.delete`、`.rename`。有文件新建或删除时触发扫描。
- 每个被跟踪的文件：用 `O_RDONLY` 打开，同一个描述符既读内容又挂事件源，监听 `.write`、`.extend`、`.delete`、`.rename`。不加任何文件锁。
- 收到 `.write` 或 `.extend`：如果这个文件还没有排定的读取，排一次 100 毫秒后的读取。这 100 毫秒内的多次写入合并成一次读取。
- 读取：`fstat` 取长度。长度小于已读偏移量时视为文件被截断，把偏移量改成 0 并 `reset()` 分行器。然后用 `pread` 从偏移量读到末尾，每块 64 KiB，一次读取至多 1 MiB；还有剩余时立即再排一次。`pread` 出错（`EINTR` 除外）或读到 0 字节时结束这次读取，不立即再排，由 2 秒的保险重试；同一个文件连续出错只记一条日志。
- 收到 `.delete` 或 `.rename`：关闭描述符，忘掉这个文件，触发一次扫描。
- 保险：有被跟踪的文件时，每 2 秒对每个文件做一次 `fstat`，长度与已读偏移量不同就排一次读取。没有被跟踪的文件时不运行。V13 实测确认事件不会漏之后，可删掉这一条。
- 全部状态只在 `CombatLogTailer` 自己的串行队列上访问（`DispatchQueue`，服务质量 `utility`）。结果用 `DispatchQueue.main.async` 交给 `FileCombatLogMonitor`。
- `stop()`：取消全部事件源和定时器，关闭全部描述符。

`LogLineFramer` 的规则：

- 编码在凑够开头 3 个字节后判断一次：`FF FE` 是 UTF-16 小端，`FE FF` 是 UTF-16 大端，`EF BB BF` 是带 BOM 的 UTF-8，其余是 UTF-8。BOM 不进入输出。本机的游戏日志都是不带 BOM 的 UTF-8（L4）；上游记录 Windows 上的聊天日志是 UTF-16，游戏日志是 UTF-8。UTF-16 的分支只作防御。
- 从文件中间开始读时（7.3 节的「起点是文件末尾」），调用方先用文件头确定编码，再用 `init(encoding:)` 建一个指定编码的分行器；它不对中间的字节做 BOM 判断。
- 按换行符 `0A` 切行（UTF-16 按 2 字节的码元对齐）。行尾的 `0D` 去掉。
- 多字节字符被两次读取切开时，尾部留在缓冲里，不产生半个字符。
- 一行超过 `maxLineBytes`（默认 64 KiB）时丢弃这一行，直到下一个换行符。行尾的回车不计入行长：内容正好等于上限的 CRLF 行，回车与换行被两次读取切开时照样保留。
- 解码失败的字节序列用 U+FFFD 代替，不抛错。

### 7.5 文件与角色的对应

- 只认文件头里的收听者。收听者的名字与窗口标题里的角色名（`EVE - <角色名>`）先按原样比较，不相等时再做一次不区分大小写的比较。
- 文件名里的数字后缀不用来识别角色。本机上它与收听者一一对应（L13），但上游提醒它与角色 ID 不能互换。

`CombatLogHeaderParser.parse` 的规则：

1. 输入是文件开头的各行，至多 `maxHeaderLines` 行。第一条全是 `-` 的行是文件头的开始，第二条是结束。
2. 两条分隔线之间的每一行先去掉首尾空白。如果它以 `listenerLabels` 里的某个标签开头，后面紧跟半角或全角冒号，冒号后去掉空白的部分就是收听者。
3. 没有匹配的标签，但两条分隔线之间正好有 3 行时，取第 2 行冒号后的部分。这一条应对标签表以外的语言。
4. 读到第二条分隔线时 `isComplete` 为真。读了 `maxHeaderLines` 行还没有第二条分隔线时，`isComplete` 为真，`listener` 为 `nil`。

`listenerLabels`（取自上游的 `EveLogLanguageCatalog.cs`）：

| 语言 | 标签 | 依据 |
| --- | --- | --- |
| 英文 | `Listener` | 本机日志（L5） |
| 中文 | `收听者` | 本机日志（L5） |
| 俄文 | `Слушатель` | 上游录制样例 |
| 日文 | `傍聴者` | 上游录制样例 |
| 德文 | `Empfänger` | 上游模板 |
| 法文 | `Auditeur` | 上游模板 |
| 韩文 | `청취자` | 上游模板 |
| 西班牙文 | `Oyente` | 上游模板 |

日志的语言与界面语言无关，8 种语言的标签同时生效，不设语言选项。

### 7.6 行的归类

`CombatLogParser.parse` 的步骤：

1. 去掉行首的 U+FEFF 和行尾的回车。
2. 行应是 `[ yyyy.MM.dd HH:mm:ss ] (类别) 正文`：以 `[ ` 开头，时间部分是 19 个字符，后面是 ` ] (`、类别、`) `。不符合时返回 `nil`。时间只核对形式，不换算。
3. 类别转成小写。不是 `combat` 时返回 `kind = .other`。
4. 取开头的数字：从正文开头起跳过空白和 `<…>` 标记，直到第一个可见字符；记下跳过的标记里最后一个 `<color=…>` 的值。可见文字以 ASCII 数字开头时读出整数：数字之间的单个 `,`、U+00A0、U+202F 跳过，遇到其他字符停止。
5. 有开头的数字时，按颜色判断方向：颜色值（不区分大小写，前缀 `0x` 或 `#`）是 `ffcc0000` 时为 `incomingDamage(amount:)`，是 `ff00ffff` 时为 `outgoingDamage(amount:)`（L7、L14）。
6. 有开头的数字、但没有颜色标记时，改用方向词。取 `plainText(正文)`，去掉开头的数字和空白。剩下的部分以 `incomingWords` 里的某个词加空白开头时为受到伤害，以 `outgoingWords` 里的某个词加空白开头时为造成伤害。韩文按句尾判断：含 `에 의해 입음` 为受到伤害，含 `에게 입힘` 为造成伤害。都不匹配时转第 7 步，用整段 `plainText(正文)` 判断未命中，武器名以数字开头的未命中行（如 `125mm … misses you completely`）因此能识别。颜色标记不是两种伤害色时直接归为 `otherCombat`，不看方向词，也不转第 7 步。
7. 没有开头的数字，或第 6 步的方向词都不匹配时：`plainText(正文)` 去掉尾部空白和一个句号后，以 `incomingMissMarkers` 里的某个短语结尾时为 `incomingMiss`；否则含 `missMarkers` 里的某个短语时为 `outgoingMiss`；否则为 `otherCombat`。

`plainText`：删掉每一对 `<` 与 `>` 之间的内容（找不到 `>` 的 `<` 保留为普通字符），把连续的空白（含 U+00A0）合成一个空格，去掉首尾空白。不解码 `&amp;` 一类的实体，归类用不到。

颜色是主要依据，原因：它由客户端在拼伤害行时加上，8 种语言相同，日文两个方向的介词相同（都是 `から`），只有颜色能区分。方向词只在颜色缺失时用。2026-11-20 实现时明确：行首数字带有两种伤害颜色以外的颜色时，归为 `otherCombat`，不再看方向词。原因是上游的远程维修模板（519190）用 `0xff7fffff` 且含「来自」，按方向词会把被维修误判成受到攻击（`CombatLogParser.swift`）。

方向词与未命中短语（取自上游的模板，编号 285197～285204）：

| 语言 | 受到伤害的词 | 造成伤害的词 | 对方未命中的句尾 | 未命中的通用短语 | 依据 |
| --- | --- | --- | --- | --- | --- |
| 中文 | `来自` | `对` | `完全没有打中你`、`完全没有击中你` | `完全没有打中`、`完全没有击中` | 本机日志（L7、L8） |
| 英文 | `from` | `to` | `misses you completely` | `misses ` | 上游模板与测试用例 |
| 俄文 | `из` | `на` | `мимо вашего корабля` | `промах` | 伤害行有上游录制样例；未命中只有模板 |
| 日文 | 不列（两个方向都是 `から`） | 不列 | `あなたを完全に外した` | `完全に外した` | 伤害行有上游录制样例；未命中只有模板 |
| 德文 | `von` | `nach` | `hat Sie völlig verfehlt`、`verfehlt Sie völlig` | `völlig verfehlt` | 上游模板 |
| 法文 | `de` | `à` | `vous a complètement manqué`、`vous a complètement manquée` | `complètement manqué` | 上游模板 |
| 西班牙文 | `de` | `a` | `falla por mucho` | `por mucho` | 上游模板 |
| 韩文 | 按句尾 `에 의해 입음` | 按句尾 `에게 입힘` | `완전히 빗나감`，且整句不含 `을(를) 완전히 빗나감`、`을 완전히 빗나감`、`를 완전히 빗나감`（客户端可能把 `을(를)` 换成实际的助词） | `완전히 빗나감` | 上游模板 |

- 匹配方向词与短语时不区分大小写。
- 日文的伤害行没有颜色标记时归为 `otherCombat`，不猜方向。
- 判断不了的行一律不触发提醒。宁可漏报，不误报。
- 数字为 0 的受到伤害的行（L7）解析成 `incomingDamage(amount: 0)`，是否提醒由 7.7 节的规则决定。

### 7.7 提醒规则

事件的产生（`CombatLogTailer`）：一次读取里，每个文件至多产生两条 `CombatLogEvent`。这次读到的行里有 `incomingDamage` 时，上报其中数字最大的一条；有 `incomingMiss` 时，另外上报一条 `incomingMiss`。两种各自上报，所以「一次小于阈值的伤害加一次未命中」仍能按未命中触发提醒。其他种类的行不上报。数字为 0 的命中按未命中对待：同一次读取里另有大于 0 的伤害时，除了数字最大的一条，再上报一条 `incomingMiss`，0 不会被较大的数字盖住；这次读取里的伤害全是 0 时，只上报 `incomingDamage(0)`，由 `triggers` 表的第 2 行处理。上报仍不超过两条。

`CombatAlertRules.triggers`：

| 种类 | 条件 | 结果 |
| --- | --- | --- |
| `incomingDamage(amount)` | `amount >= settings.minimumDamage` | 提醒 |
| `incomingDamage(amount)` | `amount == 0` 且 `settings.includeMisses` | 提醒 |
| `incomingMiss` | `settings.includeMisses` | 提醒 |
| 其他 | | 不提醒 |

`minimumDamage` 默认是 1，所以默认情况下任何大于 0 的伤害都提醒。把它调高可以忽略零星的小伤害。`includeMisses` 默认打开：对方开火但没有命中，同样说明角色正被攻击。

`CombatAlertRules.extended`：

- `existing` 不为 `nil` 且 `now < existing.until`：返回 `(startedAt: existing.startedAt, until: max(existing.until, now + duration))`。持续受击时提醒一直延长，不重新开始。
- 否则：返回 `(startedAt: now, until: now + duration)`。

`now` 是协调器在主线程收到事件时的单调时钟读数，不用日志行里的时间（日志时间是 UTC 的整秒，L2、L11）。

协调器（`AppCoordinator+CombatAlerts.swift`，WP-3）：

- `startCombatAlerts()`：在 `start()` 里调用。设置 `services.combatLog` 的两个回调，再调 `applyCombatLogSettings()`。
- `applyCombatLogSettings()`：当前配置方案的 `combatAlert.enabled` 为真时调 `services.combatLog.start(directory: general.eveLogDirectory)`，否则调 `stop()`。
- `combatSettingsDidChange(old:new:)`：在 `configDidChange` 里调用。`enabled`、`eveLogDirectory` 或活动配置方案变了，就调 `applyCombatLogSettings()`。
- `combatEventsArrived(_:)`：对每条事件，先过 `CombatAlertRules.triggers`；再按 7.5 节的比较办法在 `registry` 里找这个角色的客户端，找不到就丢弃；找到后把 `session.combatAlerts[窗口 ID]` 设为 `extended(…)` 的结果，然后 `setNeedsReplan()`。
- `pruneCombatAlerts()`：在每次重算开头调用，删掉 `until <= now` 的项。客户端消失时，`applyRegistryDiff` 删掉它的项。
- `testCombatAlert()`：给当前全部客户端（含登录客户端）各设一条提醒，时长取 `combatAlert.durationSeconds`。它不要求 `enabled` 为真，供「测试闪烁」按钮使用。

提醒对全部客户端生效，包括活动客户端（用户的决定）。提醒按窗口 ID 存放，与 `hoveredWindow`、`interactingWindows` 一致（架构文档 4.1 节）。

规划器的改动：

- `alert`：`session.combatAlerts[client.id]` 存在且 `now < until` 时，取 `ThumbnailAlert(color: combatAlert.color, style: combatAlert.style)`，否则取 `nil`。规划器不看 `combatAlert.enabled`，是否读日志由协调器把关。
- `ThumbnailAlert` 里没有时间。提醒延长时呈现不变，面板不重复更新。
- `opacity`：悬停或有提醒时为 1.0，否则取 `thumbnail.opacity`。提醒中的缩略图不透明，在默认透明度 0.5 下也能看清。
- 可见性：有提醒的客户端不受第 4 条可见性规则（`hideWhenEVENotFrontmost`）影响。用户在别的应用里时，被攻击角色的缩略图会出现并闪烁，提醒结束后按原规则隐藏。第 1～3 条（全部隐藏、按角色隐藏、隐藏活动客户端）不受提醒影响。
- `nextWakeAt`：取 `hideDeadline` 与全部未到期提醒的最小 `until` 中较小的一个。提醒到期时有一次重算，把 `alert` 清掉。

### 7.8 闪烁的呈现

`AlertFlashLayer`（`Thumbnails/AlertFlashLayer.swift`，`CALayer` 的子类）是缩略图的第 6 层，在边框层之上，大小与缩略图相同。

```swift
// [App] Thumbnails/AlertFlashLayer.swift
final class AlertFlashLayer: CALayer {
    /// 按呈现更新。alert 与上次相同且动画还在时不做任何事。
    func update(_ alert: ThumbnailAlert?)
}
```

- `style` 是 `border` 或 `both` 时画边框：颜色取 `alert.color`，粗细 4 点。
- `style` 是 `wash` 或 `both` 时铺一层底色：`alert.color`，不透明度 0.25。
- 动画：图层的 `opacity` 在 0.15 与 1.0 之间来回，单程 0.25 秒，自动反向，无限重复，缓入缓出。一个来回 0.5 秒，即每秒闪 2 次。
- 动画是 `CABasicAnimation`，由渲染服务执行。应用不为它起定时器，闪烁期间主线程没有逐帧的工作。
- `update` 在每次重算时都会被调用。`alert` 没变且 `animation(forKey:)` 不为 `nil` 时直接返回，不重启动画，相位不跳。
- `alert` 变成 `nil`：移除动画并隐藏图层。
- 系统打开了「减弱动态效果」（`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`）时不加动画，图层以不透明度 1.0 静止显示。
- 面板从隐藏变成显示后，动画可能已被系统移除。`ThumbnailPanelController` 在 `orderFrontRegardless()` 之后调一次 `contentView.refreshAlert()`，它用当前的呈现再调一次 `update`（V14）。

闪烁频率固定为每秒 2 次，不做成配置项。每秒 3 次以上的闪烁有诱发光敏性癫痫的风险（WCAG 2.3.1），固定值留在这条线以下。

### 7.9 权限

默认的日志目录在「文稿」里。未启用沙盒的应用第一次读「文稿」时，系统弹出「文件与文件夹」的授权提示（V12）。

- 战斗提醒默认关闭。用户在「提醒」页打开开关时才第一次读目录，系统提示出现在用户刚做完的操作之后。
- `macos/packaging/Info.plist` 增加 `NSDocumentsFolderUsageDescription`，值是英文：`EVE-O Preview reads EVE game logs in Documents/EVE/logs to flash a thumbnail when its character is attacked.`。Info.plist 的文字不随界面语言变化（没有资源目录）。
- 用户拒绝后，列目录返回权限错误，状态是 `accessDenied`。「提醒」页显示说明和「打开系统设置」按钮，按钮调 `openSystemSettings(.filesAndFolders)`，打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`。
- 状态是 `accessDenied` 时每 10 秒重试一次列目录，用户在系统设置里授权后自动恢复。
- 用 `swift run` 运行时，权限记在终端应用名下。
- 日志目录改到「文稿」「桌面」「下载」以外的位置时，不涉及这项权限。

这项权限只影响战斗提醒，不进架构文档 4.4 节的权限矩阵，在那里加一条说明。

### 7.10 负载与隐私

负载的设计上限（实测值由 10.2 节第 5 组第 9 项记录）：

- 空闲时：没有文件写入就没有事件。定时的工作只有两项：每 2 秒对每个被跟踪的文件做一次 `fstat`，每 30 秒列一次目录。
- 战斗中：每个文件每秒至多读 10 次（100 毫秒合并一次），每次只读新增的字节。本机历史数据里写入最密的 1 秒是 14 行（L12），一行约 250 字节。
- 解析不用正则表达式，只做前缀、后缀与子串比较。
- 主线程：每批事件一次回调，每个角色至多两条；重算本身已合并到每个主循环回合一次。
- 描述符：至多 16 个文件加 1 个目录。

隐私：

- 日志里有角色名、对手的名字和舰船。本应用只在内存里保留收听者的名字和每行的归类结果，不保存任何日志内容，不上传。
- 写系统日志时，角色名、文件名（含数字后缀）与目录路径按 `.private` 记录。不记录日志行的内容。
- 测试样例里的名字全部换成虚构的（10.1 节）。

### 7.11 设置界面

设置窗口新增「提醒」页（`Settings/AlertsPage.swift`），内容依次是：

| 控件 | 绑定或动作 |
| --- | --- |
| 开关「角色被攻击时闪烁缩略图」 | `combatAlert.enabled` |
| 状态行 | `combatLogStatus`：未启用；监视中（目录、跟踪的文件数）；找不到日志目录；没有访问权限（附「打开系统设置」按钮） |
| 日志目录：路径、「选择…」、「使用自动位置」 | `general.eveLogDirectory`。「选择…」用 `NSOpenPanel` 选目录；「使用自动位置」把它设回 `nil` |
| 闪烁颜色 | `combatAlert.color`，`HexColorPicker` |
| 持续时间 | `combatAlert.durationSeconds`，滑块 1～10 秒，步长 0.5 |
| 样式 | `combatAlert.style`，分段选择：边框、底色、两者 |
| 开关「未命中的攻击也提醒」 | `combatAlert.includeMisses` |
| 最小伤害 | `combatAlert.minimumDamage`，1～100,000 |
| 按钮「测试闪烁」 | `coordinator.testCombatAlert()` |
| 说明文字 | EVE 客户端应开启把游戏消息写入日志文件的设置；本功能只读日志，不向游戏发送任何输入 |

页的侧栏顺序是：客户端、预览与布局、切换与热键、提醒、配置方案、通用、权限、关于，共 8 页。
`SettingsViewModel` 增加 `combatLogStatus`，在 `refreshRuntime()` 里从协调器复制。

### 7.12 假服务与探针

- `FakeCombatLogMonitor`（`Debug/FakeCombatLogMonitor.swift`）：`EVEO_FAKE=1` 时使用。启动后每 8 秒给一个假角色发一条 `incomingDamage`，状态是 `watching(directory: "fake", followedFiles: 假角色数)`。
- `EVEOProbe gamelog [目录] [--follow 秒数]`（`Sources/EVEOProbe/GameLogProbe.swift`）：打印选中的目录、每个候选文件的编码与是否有收听者、各种 `CombatLineKind` 的行数。带 `--follow` 时用 `CombatLogTailer` 跟踪，逐条打印收到事件的时刻、种类，以及日志行时间与收到时刻的差（V13）。探针不打印名字和行内容。

## 8 文件计划

约定同架构文档第 8 节：文件不超过 1,000 行，宜在 400 行以内；函数不超过 500 行；注释率高于 20%，注释写中文；首行是 SPDX 标识。以下路径相对于 `app/`。
「归属」一栏写「WP-0 → WP-n」的文件，由 WP-0 先建好骨架或接入点，之后只由 WP-n 修改。写「WP-0」的文件在 WP-0 之后冻结，三个并行的工作包都不改它。

`Sources/EVEOPreviewCore/`：

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `Model/AppLanguage.swift` | 新建。`AppLanguage`、`LanguagePreference` 与 `resolved` | WP-0 |
| `Model/CombatAlertSettings.swift` | 新建。`CombatAlertStyle`、`CombatAlertSettings` | WP-0 |
| `Model/AppConfig.swift` | `GeneralSettings` 加 `language`、`eveLogDirectory` | WP-0 |
| `Model/Profile.swift` | `OverlaySettings` 加边框 3 项；`Profile` 加 `hotkeyDefaultScope`、`combatAlert` | WP-0 |
| `Model/RuntimeModels.swift` | `SessionState.combatAlerts`、`CombatAlertWindow` | WP-0 |
| `Support/LenientDecoding.swift` | 新建 | WP-0 |
| `Config/ConfigValidator.swift` | 3.2 节的校验 | WP-0 |
| `Contracts/PlatformContracts.swift` | `HotkeyFailureReason`、`HotkeyRegistrar.setGameFrontmost`、`CombatLogMonitor`、`PermissionPane.filesAndFolders` | WP-0 |
| `Planning/PlannerModels.swift`、`Planning/ThumbnailPlanner.swift`、`Planning/VisibilityRules.swift` | 边框、提醒、不透明度、可见性例外、`nextWakeAt`（4.2、7.7 节） | WP-0 |
| `Hotkeys/HotkeyScope.swift` | 新建 | WP-0 |
| `Hotkeys/Hotkey.swift`、`Hotkeys/HotkeyPlanner.swift` | 6.2、6.3 节 | WP-2 |
| `Hotkeys/HotkeySpec.swift` | 新建 | WP-2 |
| `Hotkeys/HotkeyActivation.swift` | 新建。`HotkeyActivation.isActive` 与鼠标热键的匹配器 `MouseHotkeyMatcher`（6.6 节的吞掉规则与截止时刻） | WP-2 |
| `Hotkeys/HotkeyBackendRules.swift` | 新建。`CarbonHotkeyID` 编解码 Carbon 热键编号，`MouseTapRetry` 判断何时重建鼠标事件监听（6.5 节） | 第一轮反馈的审查修复 |
| `CombatLog/CombatLogReplayGuard.swift` | 新建。晚跟踪文件的积压过滤（7.3 节） | 第一轮反馈的审查修复 |
| `CombatLog/CombatLogModels.swift` | 新建。`CombatLineKind`、`CombatLogLine`、`CombatLogEvent`、`CombatLogStatus` | WP-0 |
| `CombatLog/CombatLogParser.swift`、`CombatLogCatalog.swift`、`CombatLogHeaderParser.swift`、`LogLineFramer.swift`、`CombatLogDirectory.swift`、`CombatAlertRules.swift` | 新建 | WP-3 |

`Tests/EVEOPreviewCoreTests/`：

| 文件 | 归属 |
| --- | --- |
| `ConfigCodableTests`、`ConfigValidatorTests`、`ThumbnailPlannerTests`、`VisibilityRulesTests`（补用例），`AppLanguageTests`（新建） | WP-0 |
| `HotkeyTests`、`HotkeyPlannerTests`（补用例），`HotkeySpecTests`、`HotkeyActivationTests`（新建，`HotkeyActivation` 与 `MouseHotkeyMatcher`） | WP-2 |
| `HotkeyScopeEdgeCaseTests`、`CombatLogEdgeCaseTests`（测试方补充的边界用例），`CombatLogReplayTests`、`HotkeyBackendRulesTests`（新建） | 集成后补充 |
| `CombatLogParserTests`、`CombatLogHeaderParserTests`、`LogLineFramerTests`、`CombatLogDirectoryTests`、`CombatAlertRulesTests`、`CombatLogFixtures.swift`（都是新建） | WP-3 |

`Sources/EVEOPreviewPlatform/` 与 `Sources/EVEOProbe/`：

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `PlatformServices.swift` | 加 `combatLog`；`hotkeys` 换成 `SystemHotkeyRegistrar` | WP-0 |
| `Permissions/SystemPermissionService.swift` | `openSystemSettings(.filesAndFolders)` | WP-0 |
| `Hotkeys/SystemHotkeyRegistrar.swift` | 新建。WP-0 先写成转发给 `CarbonHotkeyRegistrar` 的骨架 | WP-0 → WP-2 |
| `Hotkeys/CarbonHotkeyRegistrar.swift` | WP-0 只改失败项的类型并补 `setGameFrontmost` 的空实现；WP-2 改成键盘后端 | WP-0 → WP-2 |
| `Hotkeys/MouseEventTap.swift` | 新建。系统资源的建立、开关、巡检与拆除；判断交给 Core 的 `MouseHotkeyMatcher` | WP-2 |
| `CombatLog/FileCombatLogMonitor.swift` | 新建。WP-0 先写成不做事的骨架 | WP-0 → WP-3 |
| `CombatLog/CombatLogTailer.swift`、`CombatLog/TailedLogFile.swift` | 新建。队列上的跟踪逻辑；单个文件的描述符、偏移量与分行器 | WP-3 |
| `EVEOProbe/main.swift` | 加 `mousetap`、`gamelog` 两个命令的分发 | WP-0 |
| `EVEOProbe/MouseTapProbe.swift` | 新建。WP-0 先写成打印「未实现」的骨架 | WP-0 → WP-2 |
| `EVEOProbe/GameLogProbe.swift` | 同上 | WP-0 → WP-3 |

`Sources/EVEOPreview/`：

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `AppCoordinator.swift` | 9.1 节列出的接入点；`combatLogStatus`、`onLanguageChanged` 两个属性 | WP-0 |
| `AppCoordinator+Language.swift` | 新建。5.4 节 | WP-0 → WP-1 |
| `AppCoordinator+Hotkeys.swift` | 6.7 节 | WP-0 → WP-2 |
| `AppCoordinator+CombatAlerts.swift` | 新建。7.7 节 | WP-0 → WP-3 |
| `AppCoordinator+Activity.swift` | 新建。防止 App Nap 的后台活动（6.7 节） | 第一轮反馈的审查修复 |
| `AppDelegate.swift` | 启动时设语言；`onLanguageChanged` 里重建主菜单 | WP-1 |
| `Support/L10n.swift`、`Support/L10n+Settings.swift` | WP-0 按 9.1 节改名；WP-1 删除，内容迁到 `Localization/` | WP-0 → WP-1 |
| `Support/L10n+Hotkeys.swift` | WP-0 新建（从 `L10n+Settings.swift` 搬出 26 条）；WP-2 删除，内容迁到 `Localization/` | WP-0 → WP-2 |
| `Localization/L10n.swift`、`Localization/Strings.swift`、`Localization/SettingsStrings.swift` | 新建 | WP-1 |
| `Localization/<语言>/Strings+<语言>.swift`（5 个） | 新建 | WP-1 |
| `Localization/HotkeyStrings.swift`、`Localization/<语言>/HotkeyStrings+<语言>.swift`（5 个） | 新建 | WP-2 |
| `Localization/CombatStrings.swift`、`Localization/<语言>/CombatStrings+<语言>.swift`（5 个） | 新建 | WP-3 |
| `Thumbnails/ThumbnailContentView.swift` | WP-0 加提醒层的接入点（建层、布局、`apply` 里调 `update`、`refreshAlert()`）；WP-1 改边框的取值顺序 | WP-0 → WP-1 |
| `Thumbnails/ThumbnailPanelController.swift` | 显示面板后调 `refreshAlert()` | WP-0 |
| `Thumbnails/AlertFlashLayer.swift` | 新建。WP-0 先写成空的 `update` | WP-0 → WP-3 |
| `Settings/SettingsWindowController.swift` | WP-0 给 `SettingsPage` 加 `alerts`、`general`；WP-1 加重设窗口标题的方法 | WP-0 → WP-1 |
| `Settings/SettingsRootView.swift` | WP-0 补全页的分发、标题与图标；WP-1 加 `.id(…)` | WP-0 → WP-1 |
| `Settings/SettingsViewModel.swift` | 加 `combatLogStatus` | WP-0 |
| `Settings/GeneralPage.swift` | 新建。语言选择 | WP-0 → WP-1 |
| `Settings/PreviewsPage.swift` | 边框的 3 行；格式串改成函数 | WP-1 |
| `Settings/PermissionsPage.swift` | 辅助功能的说明补上鼠标热键 | WP-1 |
| `Settings/AboutPage.swift` | WP-0 改访问器的名字；WP-1 在说明里加一句「战斗提醒只读游戏日志」（R17），对应的文字加在 `SettingsStrings` | WP-0 → WP-1 |
| `Settings/ClientsPage.swift`、`Settings/ProfilesPage.swift`、`Thumbnails/ThumbnailContextMenu.swift` | 只按 9.1 节第 6 项把 `L10n` 的访问器改成小写 | WP-0 |
| `Settings/FormComponents.swift` | 只在文字接口变了时改 | WP-1 |
| `Settings/SwitchingPage.swift`、`Settings/HotkeyRecorderView.swift` | 6.8 节 | WP-2 |
| `Settings/HotkeyListEditor.swift` | 新建，从 `HotkeyRecorderView.swift` 拆出 | WP-2 |
| `Settings/SettingsViewModel+Actions.swift` | WP-0 把失败提示改成按 `reason` 分支；WP-2 改成用 `HotkeySpec`、加作用范围的读写 | WP-0 → WP-2 |
| `StatusItem/StatusItemController.swift` | 6.8 节的菜单项 | WP-2 |
| `Settings/AlertsPage.swift`、`Settings/SettingsViewModel+Alerts.swift` | 新建。7.11 节 | WP-0 → WP-3（后一个由 WP-3 新建） |
| `Debug/FakeServices.swift` | WP-0 接入假的战斗日志服务、补 `setGameFrontmost`；WP-2 按需改假热键 | WP-0 → WP-2 |
| `Debug/FakeCombatLogMonitor.swift` | 新建。7.12 节 | WP-0 → WP-3 |

其他：

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `macos/packaging/Info.plist` | 加 `NSDocumentsFolderUsageDescription` | WP-3 |
| `docs/macos/architecture.md`、`docs/macos/design-feedback-round1.md` | 设计 | 主会话 |
| `README.md`、`docs/macos/manual-test-checklist.md` | 语言、热键、战斗提醒的说明；10.2 节的条目 | 主会话，在集成时按各工作包回报的文字写 |

9.1 节第 6 项的改名会碰到每一个含 `L10n.` 调用的文件，上表已全部列出。没有列出的文件本轮不改。工作包发现要改表外的文件，或要改不属于自己的文件时，停下并报主会话。

## 9 工作包与集成

### 9.1 WP-0：共用的模型、契约与接入点（主会话，先做）

目的：把三个工作包都要碰的文件一次改完，之后它们各自只改自己的文件。WP-0 做完后 `swift build` 与 `swift test` 通过，应用的行为除下面第 2 项外与 v1 相同。

1. Core：完成第 8 节归属写 WP-0 的全部文件及其测试。`HotkeyBinding`、`Hotkey` 暂不改。
2. 规划器已给出 `borderColor`，但视图在 WP-1 之前不画中性边框；`alert` 始终是 `nil`（没有人写 `combatAlerts`）。
3. Platform：`PlatformServices` 加 `combatLog`，`makeLive()` 用骨架的 `SystemHotkeyRegistrar` 与 `FileCombatLogMonitor`；`HotkeyRegistrationFailure` 改用 `reason`。
4. 在 `AppCoordinator.swift` 里加接入点。被调用的方法先在扩展文件里写成空实现：

| 位置 | 加入的调用 | 实现所在的文件 |
| --- | --- | --- |
| `start()`，`rebuildHotkeys()` 之后 | `startCombatAlerts()` | `AppCoordinator+CombatAlerts.swift` |
| `stop()` | `services.combatLog.stop()` | |
| `applyRegistryDiff`，处理 `removed` 时 | `session.combatAlerts[client.id] = nil` | |
| `refreshFrontmost()`，更新 `frontmost` 之后 | `frontmostDidChange()` | `AppCoordinator+Hotkeys.swift` |
| `pollTick()` 与 `refreshPermissions()` 更新 `permissions` 处 | 状态变了时调 `permissionsDidChange(old:new:)` | `AppCoordinator+Hotkeys.swift` |
| `configDidChange(old:new:)` | `languageSettingDidChange(old:new:)`、`combatSettingsDidChange(old:new:)` | `AppCoordinator+Language.swift`、`AppCoordinator+CombatAlerts.swift` |
| `replan()`，建 `PlannerInput` 之前 | `pruneCombatAlerts()` | `AppCoordinator+CombatAlerts.swift` |

5. 设置窗口：`SettingsPage` 加 `alerts` 与 `general`，顺序按 7.11 节；`AlertsPage`、`GeneralPage` 先写成只有页标题的空页。
6. 界面文字的改名（只改名字，不改文字内容）：
   1. 把 `L10n+Settings.swift` 里「切换与热键页」一组的 26 个成员搬到新文件 `Support/L10n+Hotkeys.swift` 的 `enum L10n.Hotkeys` 里。成员是：`switchingSubtitle`、`cycleGroupsHeader`、`addGroup`、`noGroups`、`groupName`、`deleteGroup`、`forwardHotkeys`、`backwardHotkeys`、`noMembers`、`addMember`、`characterHotkeysHeader`、`globalHotkeysHeader`、`hotkeyToggleHideAll`、`hotkeyMinimizeAll`、`hotkeyCycleLogin`、`hotkeyRulesHint`、`addHotkey`、`recordingPrompt`、`recorderHelp`、`removeHotkey`、`hotkeyUnparsable`、`hotkeyMissingModifier`、`hotkeyReserved`、`hotkeyDuplicate`、`hotkeyRegistrationFailed`、`newGroupName`。
   2. 给 `L10n` 加 5 个小写的访问器，暂时返回原来的命名空间类型：`static var menu: Menu.Type { Menu.self }`，`editMenu`、`thumbnail`、`settings`、`hotkeys` 同理。`hotkeys` 写在 `L10n+Hotkeys.swift` 里，`settings` 写在 `L10n+Settings.swift` 里，其余写在 `L10n.swift` 里。
   3. `L10n+Hotkeys.swift` 不调用 `L10n.text(zh:en:)`，自己按 `L10n.language == .zh` 取中文或英文。这样 WP-1 删掉 `L10n.text` 时，它的 worktree 里这个文件仍能编译。
   4. 把全部调用处改成小写访问器：`L10n.Menu.` 改成 `L10n.menu.`，`L10n.EditMenu.` 改成 `L10n.editMenu.`，`L10n.Thumbnail.` 改成 `L10n.thumbnail.`；`L10n.Settings.` 后面是上面 26 个成员之一的改成 `L10n.hotkeys.`，其余改成 `L10n.settings.`。
   5. 给 `L10n` 加 `language` 与 `setLanguage`（5.3 节的签名）。初始值按 v1 的规则取（`EVEO_LANG` 或系统语言是中文时为 `.zh`，否则为 `.en`），`isChinese` 改成读 `language`。
   6. 给 `L10n.Settings` 加 `pageAlerts`、`pageGeneral` 两条（中英文）。

第 6 项做完后，WP-1 把访问器的返回类型换成协议，调用处不用再改；WP-2 与 WP-3 的新代码直接写 `L10n.hotkeys.x`、`L10n.combat.x`。WP-1 迁移时不改 v1 已有成员的名字（3 条格式串除外，它们只在 `PreviewsPage.swift` 里用）。

### 9.2 并行的三个工作包

三个工作包各在自己的 git worktree 里做，基线是 WP-0 的提交。开工前核对基线：`docs/macos/design-feedback-round1.md` 与 `Sources/EVEOPreviewCore/CombatLog/CombatLogModels.swift` 应存在，不存在说明 worktree 建在了旧的提交上。
任何两个工作包都不改同一个文件（第 8 节）。

| 工作包 | 内容 | 完成标准 |
| --- | --- | --- |
| WP-1 多语言与边框 | 第 4、5 节。把 v1 的文字迁到协议结构，补 `ru`、`ja`、`ko` 三种译文；语言设置与即时切换；「通用」页；边框的视图与设置项 | `swift build` 通过；`EVEO_FAKE=1` 下 5 种语言都能切换，10.2 节第 1、2 组可做；`check_quality.py` 通过 |
| WP-2 热键 | 第 6 节。先做 6.9 节的探针并回报 V9、V10、V16；再做 Core、Platform、录制器与设置界面；热键域的文字（5 种语言） | `swift test` 通过，10.1 节热键的用例齐全；探针的结果已回报；10.2 节第 3、4 组可做 |
| WP-3 战斗提醒 | 第 7 节。Core 的解析与规则、Platform 的跟踪、闪烁层、「提醒」页、假服务、探针、战斗域的文字（5 种语言）、Info.plist | `swift test` 通过，10.1 节战斗日志的用例齐全；`EVEOProbe gamelog` 在本机日志目录上给出各类行数；`EVEO_FAKE=1` 下能看到闪烁 |

对三个工作包的共同要求：

- 不执行 `git commit`，提交只由主会话做。
- 不留临时文件和调试脚本。
- 契约或本文要改时停下，报主会话；主会话改文档，再让文件的归属方改代码。
- 要写进 `README.md` 与 `docs/macos/manual-test-checklist.md` 的文字，放在回报里，不直接改这两个文件。
- 回报里附 `swift build`、`swift test` 与 `python3 scripts/check_quality.py` 的输出摘要。
- `ru`、`ja`、`ko` 的译文按 5.2 节标注，用 5.5 节的词表。

### 9.3 集成顺序

1. 主会话完成 WP-0，运行 `swift build` 与 `swift test`，提交。
2. 三个工作包并行。WP-2 的探针结果（V9）出来后，主会话先确认 6.6 节的权限说法是否要改。
3. 按 WP-1、WP-2、WP-3 的顺序合入。文件不重叠，顺序只影响每一步之后的编译核对：每合入一个，运行一次 `swift build` 与 `swift test`。
4. 主会话更新 `README.md`、`docs/macos/manual-test-checklist.md`，运行 `python3 scripts/check_quality.py` 与 `macos/scripts/build-app.sh`。
5. 测试方按 10.2 节做手工验证。鼠标热键与战斗提醒的条目要用户配合。
6. 交审查方独立审查。审查时核对：第 8 节的归属有没有被越界改动；`ru`、`ja`、`ko` 的文件头有没有审校说明；`Core` 的测试是否覆盖 10.1 节。

## 10 测试

### 10.1 Core 测试

用 swift-testing，只测 Core（架构文档 E2）。界面文字的完整性由编译保证（5.3 节），不写测试。

| 测试文件 | 覆盖 |
| --- | --- |
| `AppLanguageTests` | 6 种选项各自的解析结果；`system` 下 `zh-Hans-CN`、`ru-RU`、`ja-JP`、`ko-KR` 各对应一种语言，`de-DE` 与空数组得到 `en`；首选语言不受支持时取后面第一个受支持的；`override` 覆盖选项，非法的 `override` 被忽略 |
| `ConfigCodableTests`（补） | 缺少全部新键的 v1 文件解码后：`borderEnabled` 为真、`language` 为 `en`、`hotkeyDefaultScope` 为 `global`、`combatAlert.enabled` 为假；新键的 JSON 名称与 3.1 节一致；`language`、`hotkeyDefaultScope`、`combatAlert.style` 是不认识的值或类型不对时取默认值，不抛错；默认配置往返一致 |
| `ConfigValidatorTests`（补） | `borderThickness`、`durationSeconds`、`minimumDamage` 的上下界；`borderColor`、`combatAlert.color` 非法时改回默认值；`eveLogDirectory` 是空白串时变成 `nil` |
| `ThumbnailPlannerTests`（补） | 边框默认打开时 `borderColor` 有值，关闭时为 `nil`；活动客户端同时有 `highlightColor` 与 `borderColor`；有未到期的提醒时 `alert` 有值且 `opacity` 为 1.0；提醒到期后 `alert` 为 `nil`；提醒延长时呈现不变；`nextWakeAt` 取隐藏期限与提醒到期时刻中较小的一个 |
| `VisibilityRulesTests`（补） | 有提醒时第 4 条规则不隐藏该客户端；第 1～3 条不受提醒影响；提醒到期后恢复原规则 |
| `HotkeyTests`（补） | `Mouse3`～`Mouse32` 往返；`mouse4`、`MOUSE4` 大小写；`ctrl+Mouse4`、`shift+Mouse5`；`Mouse0`、`Mouse1`、`Mouse2`、`Mouse33`、`Mouse`、`Mouse4x` 解析失败；按钮号等于序号减 1；`displayString`；`Hotkey(keyCode:modifiers:)` 的 `keyCode` 与 `isMouse`；`Hotkey(mouseButton:)` 的范围 |
| `HotkeySpecTests` | 没有后缀时 `scope` 为 `nil`；`@game`、`@global`、大小写与空白；`@`、`@foo`、`F13@game@global`、`@game` 解析失败；规范写法往返；`resolvedScope` |
| `HotkeyPlannerTests`（补） | 没有后缀的绑定取配置方案的默认范围；后缀覆盖默认范围；不带修饰键的鼠标触发键被接受；同一热键不同范围记为重复；键盘与鼠标不互相重复；`Mouse1` 记为 `unparsable`；编号顺序不变 |
| `CombatLogParserTests` | 见下面的样例表；另有：不以 `[ ` 开头的行、时间不完整的行、空行返回 `nil`；非 `combat` 类别得到 `other`；带千分位逗号的数字；数字为 0；颜色值大写、`#` 前缀；行首的 U+FEFF 与行尾的回车 |
| `CombatLogHeaderParserTests` | 8 种语言的收听者标签；全角冒号；没有收听者的文件头（L3）；标签不认识但正好 3 行时取第 2 行；文件头不完整；超过 `maxHeaderLines` |
| `LogLineFramerTests` | 一个汉字被切在两次追加之间；尾部半行留到下次；CRLF；带 BOM 的 UTF-8；UTF-16 小端与大端；超长行被丢弃后恢复正常；`reset()`；指定编码时不做 BOM 判断 |
| `CombatLogDirectoryTests` | 没有配置时的默认路径；配置的是 `logs` 目录、`Gamelogs` 目录、带 `~` 的路径 |
| `CombatAlertRulesTests` | `triggers` 表的每一行与 `minimumDamage` 的边界；`extended` 在提醒未到期时保留 `startedAt` 并延长，到期后重新开始，`until` 不会缩短 |

`CombatLogFixtures.swift` 里的样例写成字符串常量（不用测试资源文件）。每条样例注明来源：

| 语言 | 样例 | 来源 |
| --- | --- | --- |
| 中文 | 文件头；受到伤害、造成伤害、数字为 0 的受到伤害、对方未命中、己方未命中、跃迁扰断（反例）、`hint` 行 | 本机日志的真实格式（L5～L9），名字换成虚构的 |
| 日文 | 文件头；两个方向的伤害行（介词相同，只有颜色不同）；去掉颜色后归为 `otherCombat` | 上游的录制样例 `japanese-damage.txt` |
| 俄文 | 文件头；两个方向的伤害行 | 上游的录制样例 `russian-client.txt` |
| 英文 | 文件头；两个方向的伤害行；两种未命中 | 文件头是本机日志的真实格式；伤害行与未命中取自上游的测试用例与模板 |
| 德文、法文、西班牙文、韩文 | 文件头；两个方向的伤害行（带颜色与不带颜色各一条）；对方未命中 | 按上游模板拼出，样例旁注明「由模板推得，未经真实客户端核对」 |

上游的样例以 GPL-3.0 发布，与本项目的许可证相同；样例文件的头部注明出处。

### 10.2 手工验证（集成后追加到 `docs/macos/manual-test-checklist.md`）

第 1 组，边框：

1. 用 v1 留下的配置文件启动。预期：每个缩略图都有一圈浅灰色边框。
2. 打开高亮，切换活动客户端。预期：活动客户端显示高亮颜色的边框，其余仍是浅灰色。
3. 在「预览与布局」页关掉边框，再改颜色与粗细后打开。预期：改动立即生效，重启后保持。

第 2 组，语言：

1. 用没有 `language` 键的配置文件启动（系统语言是中文）。预期：界面是英文。
2. 在「通用」页依次选 5 种语言和「跟随系统」。预期：设置窗口的各页、窗口标题、菜单栏菜单、缩略图右键菜单、占位文字都立即变成所选语言，不用重启。
3. 每种语言下把 8 页各看一遍。预期：没有被截断或重叠的文字，没有漏翻成别的语言的文字。记录俄文下过长的条目。
4. 重启应用。预期：语言保持。

第 3 组，鼠标热键（要用户配合）：

1. 运行 `EVEOProbe mousetap`，按中键与两个侧键。预期：记下每个按键的按钮号，与 6.1 节的表核对（V10）。
2. 在循环组的前进热键里录制一个侧键。预期：显示为 `Mouse4` 或 `Mouse5`，作用范围默认是「仅游戏内」。
3. 在 EVE 客户端里按这个侧键 10 次。预期：每次都切到下一个客户端；游戏内绑在这个侧键上的功能不触发（V11）。
4. 在浏览器里按这个侧键。预期：浏览器照常后退，客户端不切换。
5. 把这条热键改成「全局」，在浏览器里按。预期：客户端切换，浏览器不后退。
6. 录制 `ctrl+中键`。预期：单按中键不触发并照常传给前台应用；按住 Ctrl 按中键触发。
7. 在系统设置里撤销辅助功能权限。预期：2 秒内鼠标热键旁出现「需要辅助功能权限」，键盘热键照常；重新授权后鼠标热键恢复，不用重启。
8. 按住已绑定的侧键移动鼠标再松开。预期：只触发一次，游戏没有收到这次点击与拖动。

第 4 组，作用范围：

1. 绑定一个作用范围是「仅游戏内」的键盘热键（如 `F13`）。在文本编辑器里按它对应的键。预期：按键照常输入或没有反应，客户端不切换。
2. 切到 EVE 客户端后按它。预期：切换；游戏没有收到这个按键。
3. 用菜单栏菜单的「热键只在 EVE 内生效」切换默认范围。预期：没有后缀的热键跟着变，带后缀的不变。
4. 打开设置窗口，在文本框里按一个「仅游戏内」的热键。预期：不触发。
5. 同一个按键绑两次，范围不同。预期：后一条显示重复提示。

第 5 组，战斗提醒（要用户配合，在安全的场景里让角色受到攻击）：

1. 在「提醒」页打开开关。预期：系统弹出访问「文稿」文件夹的提示（V12）；允许后状态行显示「监视中」与跟踪的文件数。
2. 点「测试闪烁」。预期：全部缩略图（含活动客户端）按设定的颜色闪烁，到时间后停止。
3. 让一个角色受到 NPC 攻击。预期：只有这个角色的缩略图闪烁；记录从游戏内受击到开始闪烁的延迟（V13）。
4. 持续受击 30 秒。预期：闪烁不间断，相位不跳；停火后在设定的持续时间内停止。
5. 该角色是活动客户端时受击。预期：它的缩略图同样闪烁。
6. 打开「离开 EVE 时隐藏」，切到别的应用，让角色受击。预期：这个角色的缩略图出现并闪烁，提醒结束后隐藏。
7. 启动应用前已有的日志内容。预期：启动后不因历史内容闪烁。
8. 让一个角色退出再登录（产生新的日志文件）。预期：新文件被跟踪，受击时照常闪烁。
9. 3 个客户端同时战斗 5 分钟，在「活动监视器」里记录本应用的 CPU 占用，与关闭战斗提醒时对比。预期：记下两个数值。
10. 在系统设置里撤销「文稿」文件夹的访问。预期：状态行显示没有访问权限，「打开系统设置」按钮可用；重新授权后 10 秒内恢复。
11. 系统打开「减弱动态效果」后点「测试闪烁」。预期：提醒层静止显示，不闪。
12. 把日志目录改成一个不存在的路径。预期：状态行显示找不到目录；点「使用自动位置」后恢复。

## 11 风险与待核实事项

编号接着架构文档第 11 节。

| 编号 | 风险或待核实事项 | 应对 |
| --- | --- | --- |
| V9 | macOS 27 上只凭辅助功能权限能否建成会改动事件流的 `CGEventTap`，没有实测 | WP-2 的第一项任务（6.9 节）。要另一项权限时停下报主会话 |
| V10 | 用户鼠标的侧键是否以 `otherMouseDown` 到达、按钮号是多少，没有实测。有的鼠标驱动把侧键改成了键盘按键或系统手势 | 探针打印真实的按钮号。侧键被驱动改成按键时，按键盘热键录制 |
| V11 | EVE 客户端是否只从系统事件流读鼠标按键，没有实测。如果它直接读 HID 设备，事件监听吞不掉 | 10.2 节第 3 组第 3、8 项。吞不掉时在界面说明里写明，并让用户在游戏里取消这个按键的绑定 |
| V12 | 已签名的 `.app` 第一次读「文稿」时系统提示的形式、拒绝后的错误码，没有实测 | 10.2 节第 5 组第 1、10 项。WP-3 按实际的错误判断 `accessDenied` |
| V13 | 战斗中从受击到日志写入文件的延迟没有实测；本机只看到一次非战斗写入在 1 秒内落盘（L11）。EVE 的写入是否都能触发文件事件也没有实测 | `EVEOProbe gamelog --follow` 与 10.2 节第 5 组第 3 项。延迟由客户端决定，本应用缩短不了；事件会漏时保留 2 秒的保险 |
| V14 | 面板隐藏再显示后，图层上的动画是否还在，没有实测 | 7.8 节的 `refreshAlert()`；WP-3 核实 |
| V15 | 英文的未命中，以及德、法、西、韩 4 种语言的全部格式，只有上游模板，没有真实客户端的样例。1 万以上的伤害数字是否带千分位符号也没有样例 | 伤害行靠颜色判断，不依赖这些模板；未命中识别不出时只是不提醒。拿到真实样例后补用例 |
| V16 | SwiftUI 承载的设置窗口里，本地事件监视器能否收到 `otherMouseDown`，没有实测 | WP-2 在录制器里核实。收不到时，录制期间临时建一个只听不吞的事件监听 |
| R8 | 作用范围是全局的鼠标绑定会在所有应用里吞掉这个按键 | 新录制的鼠标热键默认 `@game`；说明文字写明 |
| R9 | 同一个鼠标按键已在系统设置（调度中心）或鼠标厂商的软件里另有用途 | 探针能看出事件有没有到达；说明文字提示先取消别处的绑定 |
| R10 | 5 种语言的文字表几乎没有注释，会把注释率从 24.3% 往下拉（L16） | 文字文件按页分组写注释，写明每组出现在界面的哪里和翻译时的取舍；各工作包交付前运行 `check_quality.py`。合计仍不足时，主会话决定是否把文字文件排除在注释率统计之外 |
| R11 | `ru`、`ja`、`ko` 的译文由机器生成，可能有不自然或错误的说法 | 5.2 节的标注；词表统一用词；Q11 |
| R12 | 俄文的文字普遍比英文长，设置窗口里可能被截断 | 10.2 节第 2 组第 3 项；过长的条目改短 |
| R13 | 事件监听运行期间用户撤销辅助功能权限 | 协调器每次轮询与巡检都查权限（巡检循环与窗口枚举分开，间隔 300 毫秒～2,000 毫秒），变化后拆掉事件监听；监听应打开却是关的时，巡检也会拆掉（6.5 节、6.7 节） |
| R14 | CCP 改了日志格式或伤害行的颜色后，提醒会静默失效 | 状态行仍显示「监视中」，所以「测试闪烁」不能发现这个问题；用 `EVEOProbe gamelog` 看各类行数来诊断。方向词是颜色之外的第二依据 |
| R15 | 闪烁的画面可能让部分用户不适 | 频率固定为每秒 2 次；遵从系统的「减弱动态效果」；样式可选只画边框 |
| R16 | 升级后界面从中文变成英文，用户可能以为设置丢了 | 3.3 节；发布说明与 README 写明在「通用」页切换 |
| R17 | 读游戏日志是否符合 EVE 的用户协议 | 本功能只读客户端自己写出的日志文件，不读内存、不改文件、不发送输入，与上游的做法相同；「关于」页的说明补上这一句（WP-1） |

## 12 待用户决定的问题

以下问题都有默认做法，实现照默认做法做；用户有不同意见时改。

| 编号 | 问题 | 本文采用的默认做法 |
| --- | --- | --- |
| Q9 | 打开了「离开 EVE 时隐藏」时，被攻击角色的缩略图是否临时出现 | 出现并闪烁，提醒结束后隐藏（7.7 节） |
| Q10 | 对方开火但没有命中，算不算「被攻击」 | 算，默认提醒；「提醒」页有开关可以关掉 |
| Q11 | `ru`、`ja`、`ko` 的译文由谁做母语审校 | 先按机器译文发布，并在界面与 README 里注明 |
| Q12 | 鼠标探针与第 3、5 组手工验证要用户配合（各约 5 分钟～10 分钟），何时做 | WP-2 做完探针后由主会话与用户约时间 |

## 13 术语

在架构文档第 13 节的基础上增加：

| 词 | 意思 | 不用 |
| --- | --- | --- |
| 边框 | 每个缩略图都有的中性色边线，对应 `borderEnabled` 等 3 项 | 描边、外框 |
| 高亮边框 | 活动客户端的边线，颜色可按角色设置 | 活动边框 |
| 界面语言 | 本应用的界面文字所用的语言 | 本地化语言 |
| 域 | 界面文字的一组，对应一个协议和每种语言的一份实现 | 模块 |
| 触发键 | 热键里修饰键以外的部分：一个键盘按键或一个鼠标按键 | 主键 |
| 作用范围 | 热键在什么情况下生效：`global`（全局）或 `game`（仅游戏内） | 作用域、生效范围 |
| 事件监听 | 用 `CGEventTap` 建立的系统输入事件监听 | 钩子、事件拦截器 |
| 吞掉 | 事件监听不把一个事件继续传给前台应用 | 拦截、屏蔽 |
| 游戏日志 | EVE 客户端写在 `Gamelogs` 目录下的文本文件，一个会话一个文件 | 战斗日志（上游用它指整个子系统） |
| 收听者 | 游戏日志文件头里的角色名 | 监听者 |
| 跟踪 | 持续读取一个日志文件新增的内容 | 监控、尾随 |
| 受击 | 角色受到伤害，或被攻击但对方没有命中 | 被打、挨打 |
| 战斗提醒 | 角色受击时让它的缩略图闪烁 | 警报、告警 |
| 闪烁 | 提醒层的不透明度周期变化 | 闪动、抖动 |
