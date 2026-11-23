# v1.1 设计：诊断、问题报告与应用内更新

本文是 v1.1.0 两项功能的设计：诊断与问题报告、更新检查与安装。它与 [architecture.md](architecture.md)（下称架构文档）、[design-feedback-round1.md](design-feedback-round1.md)（下称反馈文档）一起构成实现依据。
规则、流程和分工的细节只写在本文。集成后由主会话把类型签名和范围表同步到架构文档（第 15 节）。文档之间说法不一致时，停下并报主会话。
本文的 Swift 片段只有类型与协议签名。它们已在 2026 年 11 月 21 日用 Swift 6.0.3 的 Swift 6 语言模式做过类型检查：签名加空实现，与现有的 Core 源码一起编译。Platform 与 App 的片段是放在同一个模块里、配一个空的 `AppCoordinator` 检查的，没有按三个模块分开编译。3.1 节的 `GeneralSettings` 与 4.3 节的注释是在现有类型上加成员，没有单独检查。

## 1 范围与决定

| 编号 | 用户的要求 | 决定 | 章节 |
| --- | --- | --- | --- |
| D1 | 日志写进文件，能看到以前各次运行（含崩溃的那次）的日志 | 日志同时写到 `~/Library/Logs/EVE-O Preview/`。单个文件 1 MiB，保留当前文件和 4 个旧文件。默认级别 `info`。私有值在文件里写成 `<private>`。调用处的写法不变，只换日志对象的来源 | 5 |
| D2 | 检测上一次运行是否异常结束，并收集对应的系统崩溃报告 | 启动时写会话标记，正常退出时标为已结束。标记没有标为已结束时，在 `~/Library/Logs/DiagnosticReports/` 里找这段时间内本应用的报告。找到报告才提示用户 | 6 |
| D3 | 「报告问题」入口：菜单栏菜单、设置窗口、崩溃后的提示 | 三个入口打开同一个报告窗口。窗口先显示将要包含的每个文件和脱敏后的内容，用户确认后才生成 zip。脱敏始终开启，没有关闭的选项 | 7 |
| D4 | 用浏览器打开预填的 GitHub Issue，并在访达里显示 zip | 应用自己不上传任何内容，不含 GitHub token。Issue 的地址在百分号编码后不超过 6,000 字节 | 7.5 |
| D5 | 启动时和每 24 小时检查 GitHub 的最新 Release；设置里有开关；菜单里有「检查更新…」 | 请求 `releases/latest`，不带凭据。带 `If-None-Match`。遇到限流时按答复头里的时刻推后 | 8 |
| D6 | 有新版本时显示发布说明，提供安装、跳过此版本、稍后 | 发布说明按界面语言取对应的一段，取不到时用英文。「跳过此版本」只影响自动检查 | 8.2、8.6 |
| D7 | 一键安装 | 下载 dmg，核对 SHA-256，挂载，复制到暂存目录，验证签名并核对它满足正在运行的应用的指定要求，原子替换，重新启动 | 9 |
| D8 | 转移运行、位置不可写、ad-hoc 或本地开发签名时只提示 | 这些情况下不下载，窗口说明原因并提供「打开发布页」 | 9.1 |
| D9 | 「自动安装更新」 | 默认打开（第 19 节修订）。打开后在后台下载并核对；没有 EVE 客户端运行、连续空闲约 1 分钟时安装并重新启动，否则等用户退出应用或点菜单项时安装。有客户端在运行时应用不自行重新启动 | 9.5 |
| D10 | 预发布版本的处理 | 忽略预发布版本，不设开关（理由见 8.3 节） | 8.3 |
| D11 | 本地端到端测试的入口 | 环境变量 `EVEO_UPDATE_FEED_URL` 指向本地 HTTP 服务。它不放宽签名核对 | 9.6 |
| D12 | 配置的新字段与版本 | `general` 加 3 个键，`schemaVersion` 保持 1。检查时刻、跳过的版本等记录放在单独的 `state.json` | 3 |
| D13 | 用户可能在玩 EVE | 应用自己弹出的窗口不激活本应用；前台是 EVE 客户端时推迟到前台变化之后 | 4.5 |
| D14 | 新界面文字要有 5 种语言 | 新增「更新」与「诊断」两个域，各 5 份实现；文字键与英文原文列在 11.4 节 | 11 |

不在本轮范围内：

| 项目 | 原因 |
| --- | --- |
| 应用自己上传诊断包，或直接创建 Issue | 要在应用里放 GitHub token，用户已定不放 |
| 预发布更新通道 | 见 8.3 节 |
| 增量更新 | dmg 只有约 2.6 MB（U10） |
| 用管理员授权写入当前用户不可写的位置 | 要弹密码框并用特权进程，这种情况改为只提示 |
| Developer ID 签名与公证 | 没有 Apple 开发者账号；发布版用自签名证书 |
| 卡死（hang）报告与 `.diag` 文件 | 只处理崩溃报告 |
| 在界面里回退到旧版本 | 用户可以从发布页下载旧版本手动安装 |
| 核对 GitHub API 的 `digest` 字段 | 完整性由 `SHA256SUMS.txt` 核对，来源由代码签名核对，再加一项不增加保护 |
| 登录时启动 | 与本轮无关，仍按架构文档 2.2 节推迟 |

## 2 已核实的事实

下表的事实于 2026-11-21 在目标机器上只读核实（macOS 27，Apple Silicon，Swift 6.0.3，只装 Command Line Tools）。U5、U6 用临时目录里的应用副本做，没有改动 `dist/` 和已安装的应用。

| 编号 | 事实 | 对设计的影响 |
| --- | --- | --- |
| U1 | 现有 73 条日志调用（12 条 `debug`，24 条 `info`，3 条 `notice`，34 条 `error`），分布在 24 个文件里。Platform 有 13 处 `Logger(subsystem: PlatformLog.subsystem, category:)`：12 处是 `private let log` 声明，1 处直接写在表达式里（`PrivateActivation.swift:48`）。App 全部经 `AppLog.logger(_:)`。没有任何地方把 `Logger` 写成类型标注 | 换掉这 14 处来源，调用处不用改（5.1 节） |
| U2 | 插值的写法：29 处带 `privacy:`（21 处 `.public`，8 处 `.private`），1 处带 `format: .fixed(precision: 2)`，1 处用多行字符串，其余是不带标注的整数、布尔值和 1 处字符串 | 5.1 节的插值重载覆盖这些写法，已对每种写法做类型检查 |
| U3 | 标为 `.public` 的值里有主目录路径：`AppDelegate.swift:58` 的配置文件路径，以及多处 `String(describing: error)` | 文件日志里会出现用户名。报告里的脱敏不能只靠 `<private>`（7.3 节） |
| U4 | `dist/` 里 ad-hoc 签名的应用，指定要求是 `cdhash H"…"` | ad-hoc 构建的任何新版本都不满足它，ad-hoc 构建只能提示 |
| U5 | 用自签名证书 `EVEO Preview Dev` 签名的副本，默认的指定要求是 `identifier "io.github.deletexiumu.eveopreview-macos" and certificate leaf = H"<证书的 SHA-1>"` | 自签名证书只有一级，叶证书就是根证书。CI 核对指定要求时应接受 `certificate leaf` 的写法（13.3 节） |
| U6 | `SecStaticCodeCheckValidityWithErrors`（标志 `kSecCSStrictValidate`、`kSecCSCheckAllArchitectures`、`kSecCSCheckNestedCode`）拿副本 A 的指定要求去核对：同一证书签名、版本号不同的副本 B 返回 0；ad-hoc 副本返回 -67050（`errSecCSReqFailed`）；签名后改了资源文件的副本返回 -67054；签名后改了 `Info.plist` 的副本返回 -67030。证书不受系统信任不影响结果 | 9.3 节第 6 步的核对办法成立 |
| U7 | `renamex_np(a, b, RENAME_SWAP)` 在 APFS 上能交换两个目录，返回 0 | 用它原子替换应用包（9.3 节第 8 步） |
| U8 | Security、CryptoKit 与 `renamex_np` 在只装 Command Line Tools 时能以 Swift 6 模式编译并运行 | 不引入第三方依赖 |
| U9 | `~/Library/Logs/DiagnosticReports/` 里现有 0 个 `.ips` 文件。现有文件的名字带主机名，主机名里有人名 | `.ips` 的格式没有在本机核实（V17），匹配规则不依赖文件内容。主机名按敏感信息处理，崩溃报告放进压缩包时改名 |
| U10 | 本机构建的 dmg 是 2,618,184 字节 | 下载上限定为 300 MiB，留足余量 |
| U11 | `AppCoordinator.configDidChange` 每次都调 `rebuildHotkeys()` 与 `setNeedsReplan()`（`AppCoordinator.swift:253`）。`ConfigController` 在 `loadError` 不为空时不写盘（`ConfigController.swift:93`） | 检查时刻、ETag、跳过的版本不放进 `config.json`（3.3 节） |
| U12 | `SystemPermissionService.relaunch()` 以参数 `--relaunched-from <PID>` 打开 `Bundle.main.bundleURL`，并转发 `EVEO_*` 环境变量 | 安装后复用它重新启动。替换后包的路径不变，新实例启动的是新版本 |
| U13 | 现有的 `docs/release-notes/macos/v1.0.0.md` 没有语言标记 | 选取规则有「没有标记时用全文」一条（8.2 节） |
| U14 | 质量检查的现状：161 个文件，注释 4,898 行，代码 14,826 行，注释率 24.8% | 两个新域的文字文件会拉低注释率（R24） |

## 3 配置与状态文件

### 3.1 `config.json` 新增的键

| JSON 路径 | 类型 | 默认值 | 取值 |
| --- | --- | --- | --- |
| `general.checkForUpdates` | 布尔 | `true` | |
| `general.autoInstallUpdates` | 布尔 | `false` | |
| `general.logLevel` | 字符串 | `"info"` | `info`、`debug` |

```swift
// [Core] Model/AppConfig.swift（WP-0）
public struct GeneralSettings: Sendable, Equatable, Codable {
    public var pollIntervalMs: Int
    public var onboardingCompleted: Bool
    public var language: LanguagePreference
    public var eveLogDirectory: String?
    public var checkForUpdates: Bool            // 新增。默认 true
    public var autoInstallUpdates: Bool         // 新增。默认 false
    public var logLevel: LogLevel               // 新增。默认 .info，只接受 .info 与 .debug
}
```

- 新属性在 `public init` 里都有带默认值的参数，现有调用处不用改。
- `logLevel` 用 `LenientDecoding.value` 解码（反馈文档 3.2 节的约定），不认识的值取 `.info`。
- `ConfigValidator.normalized` 增加一条：`logLevel` 不是 `.info` 或 `.debug` 时改成 `.info`，字段路径 `general.logLevel` 记入 `valuesClamped`。
- `autoInstallUpdates` 为真而 `checkForUpdates` 为假时不改值。界面把「自动安装」的开关置灰，行为按不检查处理。

### 3.2 `schemaVersion` 保持 1

不升版本号，不写迁移代码。理由与反馈文档 3.1 节相同：

- 3 个新键都有默认值，旧文件缺键时由 `decodeIfPresent` 取默认值。
- 没有任何已有的键改变含义或类型。
- 升版本号会让 1.0.0 拒绝读取新文件（`newerSchema`）。

用户降级到 1.0.0 时的情况：

| 情形 | 结果 |
| --- | --- |
| 1.0.0 读 1.1.0 写过的 `config.json` | `schemaVersion` 仍是 1，照常读取。3 个新键被忽略 |
| 1.0.0 保存配置 | 新键丢失（架构文档 5.2 节：未知的键在下次保存时丢失）。再升级到 1.1.0 时这 3 项回到默认值 |
| 「文件来自更新的版本时用默认配置运行、不写盘」这条规则 | 不触发。它只在以后某个版本升了 `schemaVersion` 时触发 |
| `state.json`、日志目录、报告目录 | 1.0.0 不读也不删，留在原处 |

如果本轮把版本号升到 2，降级后的 1.0.0 会用默认配置运行并且整个会话不写盘，用户看不到自己的布局。这个代价比丢 3 个开关大。

### 3.3 `state.json`

应用自己记下的东西放在 `~/Library/Application Support/EVE-O Preview/state.json`，与 `config.json` 分开。分开的原因：

- `config.json` 每次改动都会重建热键规划并重算（U11）。每天写一次检查时刻不应触发这些事。
- `config.json` 在读取失败时整个会话不写盘（U11）。那种情况下「跳过此版本」仍应记得住。
- `config.json` 是用户的设置，用户会手工编辑和备份；`state.json` 丢了也只是多检查一次更新。

```swift
// [Core] State/AppState.swift、State/JSONStateStore.swift（WP-0）
public struct AppState: Sendable, Equatable, Codable {
    public var stateVersion: Int                // 1
    public var updates: UpdateState
    public var diagnostics: DiagnosticsState
}
public struct UpdateState: Sendable, Equatable, Codable {
    public var lastCheckAt: Date?               // 最近一次得到服务器答复的时刻
    public var etag: String?
    public var cachedRelease: ReleaseInfo?
    public var rateLimitedUntil: Date?
    public var skippedVersion: String?
    public var prepared: PreparedUpdate?
    public var lastInstall: InstallRecord?
    public var staleStagingPath: String?        // 上次安装换下来的旧包所在的目录，下次启动时删除
}
public struct InstallRecord: Sendable, Equatable, Codable {
    public var version: String; public var fromVersion: String; public var at: Date
    public var succeeded: Bool; public var errorCode: String?
}
public struct DiagnosticsState: Sendable, Equatable, Codable {
    public var pendingCrash: PendingCrash?
    public var dismissedSessionIDs: [String]    // 最多保留 20 个
}
public struct PendingCrash: Sendable, Equatable, Codable {
    public var sessionID: String; public var appVersion: String
    public var startedAt: Date; public var detectedAt: Date
    public var reportFileNames: [String]
}
public enum StateStoreError: Error, Sendable, Equatable { case ioFailure(path: String, reason: String); case encodingFailure(String) }
public protocol StateStore: Sendable {
    var fileURL: URL { get }
    /// 文件不存在、损坏或 stateVersion 不认识时返回默认状态，不抛错，不隔离文件。
    func load() -> AppState
    func save(_ state: AppState) throws(StateStoreError)
}
public struct JSONStateStore: StateStore {
    public let fileURL: URL
    public static func defaultFileURL() -> URL     // ~/Library/Application Support/EVE-O Preview/state.json
    public func load() -> AppState
    public func save(_ state: AppState) throws(StateStoreError)
}
```

规则：

- 日期用 ISO 8601 字符串编码（`JSONEncoder.dateEncodingStrategy = .iso8601`），键按字母排序，原子写入。
- `load()` 在文件不存在、不是合法 JSON、结构不符或 `stateVersion` 不是 1 时返回默认状态，不抛错，不隔离文件；下一次 `save` 覆盖它。
- 全部字段用 `decodeIfPresent`。
- 写入只经 App 的 `StateController`（4.4 节）。它在每次修改后立即写盘，写盘失败只记日志。
- 环境变量 `EVEO_STATE_DIR` 可指定目录，供测试用。演示模式（`EVEO_FAKE=1`）的文件名是 `state-fake.json` 与 `session-fake.json`。

### 3.4 升级后的变化

- 从 1.0.0 升级只能手动安装（1.0.0 没有更新功能）。本仓库发布的 1.0.0 已用发布证书签名（见第 19 节），所以手动升级到 1.1.0 后权限仍然保留；之后的升级也不用再授予（V23）。
- 1.1.0 起应用默认每 24 小时访问一次 GitHub（Q13）。发布说明与 README 应写明，并写明在「通用」页可以关闭。
- 应用开始在 `~/Library/Logs/EVE-O Preview/` 下写日志文件，最多占用约 5 MiB。

## 4 模块归属与共用契约

### 4.1 归属

Core 只 `import Foundation`，并且只有 Core 有测试目标（架构文档 E2）。所以凡是要写单元测试的逻辑都放在 Core。

| 功能 | Core（纯逻辑，可测试） | Platform（系统接口） | App（界面与流程） |
| --- | --- | --- | --- |
| 日志 | `LogMessage` 与渲染、`LogLineFormatter`、`RotatingLogFile`、`LogRateLimiter`、`LogFileLayout` | `LogChannel`、`PlatformLog`、`FileLogSink`（`os.Logger` 与锁） | `AppLog`、`LogBootstrap` |
| 异常退出 | `SessionMarker`、`SessionMarkerRules`、`CrashReportMatcher` | `CrashReportLocator`（列目录、读文件） | `SessionTracker` |
| 问题报告 | `Redactor`、`CharacterNameCollector`、`ConfigSummary`、`EnvironmentReport`、`DiagnosticsBundlePlanner`、`IssueURLBuilder` | `SystemInfoReader`（`sysctl`）、`ReportArchiver`（`ditto`）、访达与浏览器 | `ProblemReportController`、报告窗口 |
| 更新检查 | `SemanticVersion`、`ReleaseFeedParser`、`UpdatePolicy`、`UpdateFeed`、`ReleaseNotes` | `ReleaseFeedClient`（`URLSession`） | `UpdateController`、更新窗口 |
| 安装更新 | `ChecksumList`、`UpdateAssetContract`、`UpdatePolicy.validate` | `UpdateDownloader`（CryptoKit）、`DiskImage`（`hdiutil`）、`CodeSignatureVerifier`（Security）、`BundleInstaller`（`renamex_np`） | `UpdateController+Install` |
| 共用 | `AppEnvironment` 与规则、`AppState`、`JSONStateStore`、`PromptGate` | `AppEnvironmentProvider`、`ProcessRunner` | `StateController`、`DeferredPresenter` |

### 4.2 运行环境 `AppEnvironment`

更新功能和问题报告都要知道「正在运行的是哪种构建、装在哪里」。Platform 在启动时读一次，之后不变。

```swift
// [Core] Model/AppEnvironment.swift（WP-0）
public enum SignatureKind: String, Sendable, Codable, CaseIterable { case release, development, adHoc, unsigned, unknown }
public struct CodeSignatureInfo: Sendable, Equatable {
    public var kind: SignatureKind
    public var signerName: String?              // 叶证书的通用名称
    public var designatedRequirement: String?   // 启动时读到的指定要求的文本
}
public enum InstallLocationKind: String, Sendable, Codable, CaseIterable {
    case applications, userApplications, other, translocated, readOnlyVolume, notBundled
}
public struct AppEnvironment: Sendable, Equatable {
    public var bundleIdentifier: String
    public var version: String                  // CFBundleShortVersionString；没有时是 "0.0.0"
    public var buildLabel: String               // Info.plist 的 EVEOBuildLabel；没有时等于 version
    public var buildCommit: String?             // Info.plist 的 EVEOBuildCommit
    public var bundlePath: String?              // nil：不是从 .app 运行
    public var executableName: String           // "EVEOPreview"
    public var signature: CodeSignatureInfo
    public var location: InstallLocationKind
    public var isLocationWritable: Bool
}
public enum AppEnvironmentRules {
    public static let releaseSignerName = "EVE-O Preview Release"
    public static func signatureKind(isSigned: Bool, isAdHoc: Bool, signerName: String?) -> SignatureKind
    public static func locationKind(bundlePath: String?, homeDirectory: String, isReadOnlyVolume: Bool) -> InstallLocationKind
}

// [Platform] Environment/AppEnvironmentProvider.swift、Support/ProcessRunner.swift（WP-0）
public enum AppEnvironmentProvider {
    /// 读正在运行的应用的版本、签名与安装位置。启动时调一次，结果在本次运行内不变。
    public static func current() -> AppEnvironment
}
public struct ProcessResult: Sendable, Equatable {
    public var status: Int32; public var standardOutput: Data; public var standardError: String
}
public enum ProcessRunnerError: Error, Sendable, Equatable { case launchFailed(String); case timedOut }
public enum ProcessRunner {
    /// 运行一个系统工具并等它结束；超过 timeout 秒时终止它。不经过 shell。
    public static func run(_ executable: String, arguments: [String], timeout: Double) async throws(ProcessRunnerError) -> ProcessResult
}
```

`AppEnvironmentProvider.current()` 的取值：

- 版本：`Info.plist` 的 `CFBundleShortVersionString`、`EVEOBuildLabel`、`EVEOBuildCommit`。后两个键由构建脚本写入（13.3 节）。
- 签名：`SecCodeCopySelf` 取自己，`SecCodeCopyStaticCode` 转成静态代码，再用 `SecCodeCopySigningInformation(_, kSecCSSigningInformation, _)` 读信息。`kSecCodeInfoFlags` 里有 `adhoc` 位表示 ad-hoc；`kSecCodeInfoCertificates` 的第一个证书经 `SecCertificateCopyCommonName` 得到 `signerName`；`SecCodeCopyDesignatedRequirement` 加 `SecRequirementCopyString` 得到 `designatedRequirement`。任何一步失败时 `kind` 取 `.unknown`。
- 位置：`bundlePath` 在 `Bundle.main.bundleURL.pathExtension == "app"` 时取它的路径，否则为 `nil`。只读卷用 `URLResourceKey.volumeIsReadOnlyKey` 判断。`isLocationWritable` 是「包所在目录与包本身对当前用户都可写」（`access(_, W_OK)`）。

`AppEnvironmentRules.signatureKind` 的规则，按顺序取第一个成立的：

| 条件 | 结果 |
| --- | --- |
| `isSigned` 为假 | `.unsigned` |
| `isAdHoc` 为真 | `.adHoc` |
| `signerName` 等于 `EVE-O Preview Release` | `.release` |
| 其他（有证书） | `.development` |

通用名称只用来给构建分类和决定界面上的说明。新版本是否可信不看名称，只看它是否满足正在运行的应用的指定要求（9.3 节）。

`AppEnvironmentRules.locationKind` 的规则，按顺序取第一个成立的：

| 条件 | 结果 |
| --- | --- |
| `bundlePath` 为 `nil` | `.notBundled` |
| 路径里有 `/AppTranslocation/` | `.translocated` |
| `isReadOnlyVolume` 为真 | `.readOnlyVolume` |
| 路径以 `/Applications/` 开头 | `.applications` |
| 路径以 `<homeDirectory>/Applications/` 开头 | `.userApplications` |
| 其他 | `.other` |

### 4.3 平台服务

`PlatformServices` 增加两个成员，`makeLive()` 用真实实现，`FakeServices.make()` 用假实现：

```swift
// [Platform] PlatformServices.swift（WP-0）
//     public let diagnostics: any DiagnosticsService    // 协议见 7.2 节
//     public let updates: any UpdateService             // 协议见 8.4 节
```

两个协议都只含值类型，定义在 Core 的 `Contracts/` 下，方法可以在任何线程调用。`ProcessRunner` 是 Platform 内部共用的小工具，`ReportArchiver` 用它运行 `ditto`，`DiskImage` 用它运行 `hdiutil`。

### 4.4 App 的控制器与接入点

```swift
// [App] StateController.swift、Support/DeferredPresenter.swift（WP-0）
@MainActor final class StateController {
    private(set) var state: AppState
    init(store: any StateStore)
    /// 修改状态并立即以原子方式写盘；写盘失败只记日志。
    func update(_ body: (inout AppState) -> Void)
}
@MainActor final class DeferredPresenter {
    /// 现在能弹就立即调 show，否则等前台不再是 EVE 客户端时调。同一个 key 只保留最后一次。
    func present(key: String, show: @escaping @MainActor () -> Void)
    func cancel(key: String)
    func frontmostDidChange(_ frontmost: FrontmostContext)
}
enum AttentionReason: Hashable, Sendable { case crashPending, updateAvailable, updateReady }
```

`AppDelegate.applicationDidFinishLaunching` 的顺序（新增的步骤标「新」）：

1. 新：`let environment = AppEnvironmentProvider.current()`。
2. 新：`LogBootstrap.start(environment:isFakeMode:)`，装上文件日志（5.2 节）。放在读配置之前，读配置的错误才能进文件。
3. 建 `ConfigController`。新：随后调 `LogBootstrap.apply(level: config.config.general.logLevel)`。
4. 新：建 `StateController(store: JSONStateStore(fileURL: …))`。
5. 设界面语言、装主菜单、建平台服务、建 `AppCoordinator`、建设置窗口（现有步骤）。
6. 新：建 `SessionTracker`、`ProblemReportController`、`UpdateController`、`UpdateWindowController`（`init(controller:)` 与 `show(userInitiated:)`），赋给协调器的同名属性，并接上两个回调：`sessionTracker.onCrashDetected` 调 `problemReport.crashDetected(_:)`；`updates.presentWindow` 调 `updateWindow.show(userInitiated:)`。
7. `coordinator.start()`（现有步骤）。新：随后调 `sessionTracker.start()` 与 `updates.start()`。

单实例检查在 `main.swift` 里，早于以上各步。重复启动的实例在那里直接 `exit(0)`，不装文件日志，也不碰会话标记。

`applicationShouldTerminate` 的改动：

- 停止任务改成：`await coordinator.stop()`，再 `await updates.installOnQuitIfReady(timeout: .seconds(8))`，然后回复。
- 超时任务的时长：没有待安装的更新时仍是 2.5 秒；有时是 10.5 秒。
- `replyToTerminate(timedOut:)` 在调 `NSApp.reply` 之前依次调 `sessionTracker.markEndedCleanly()` 与 `PlatformLog.flush()`。正常结束与超时两条路径都经过这里。

`AppCoordinator` 的改动（都由 WP-0 写进 `AppCoordinator.swift`，被调用的方法先在扩展文件里写成空实现）：

| 位置 | 加入的内容 | 实现所在的文件 |
| --- | --- | --- |
| 属性 | `environment`、`state`、`presenter`、`sessionTracker`、`problemReport`、`updates`、`updateWindow`；`attention: Set<AttentionReason>` 与 `setAttention(_:on:)`、`onAttentionChanged` | `AppCoordinator.swift` |
| `refreshFrontmost()`，`frontmostDidChange()` 之后 | `presenter.frontmostDidChange(frontmost)` | `Support/DeferredPresenter.swift` |
| `configDidChange(old:new:)` | `diagnosticsSettingsDidChange(old:new:)`、`updateSettingsDidChange(old:new:)` | `AppCoordinator+Diagnostics.swift`、`AppCoordinator+Updates.swift` |

菜单栏、「通用」页与「关于」页的接入点见 11.1、11.2 节。

### 4.5 窗口出现的时机

用户可能在玩 EVE。应用自己弹出的窗口抢走键盘焦点时，按键会落到窗口上。规则如下：

```swift
// [Core] Support/PromptGate.swift（WP-0）
public enum PromptGate {
    /// 现在能不能自己弹出窗口。用户点出来的窗口总是可以；自动的窗口在前台是 EVE 客户端时不可以。
    public static func canPresent(frontmost: FrontmostContext, userInitiated: Bool) -> Bool
}
```

- `PromptGate.canPresent`：`userInitiated` 为真时返回真。否则 `frontmost` 是 `.client` 时返回假，是 `.selfApp` 或 `.other` 时返回真。
- 用户点菜单项或按钮打开的窗口：调 `NSApp.activate()`，再 `makeKeyAndOrderFront`。
- 应用自己弹出的窗口（自动检查发现新版本、检测到崩溃）：经 `DeferredPresenter.present(key:show:)`。能弹时调 `orderFrontRegardless()`，不调 `NSApp.activate()`，窗口不成为 key 窗口（V27）。不能弹时等 `frontmostDidChange` 报告前台不再是 EVE 客户端后再弹。
- 推迟期间，菜单栏图标右上角显示一个圆点（`attention` 不为空），菜单顶部有对应的菜单项，用户随时可以点开。
- 同一个 `key` 重复请求时只保留最后一次。窗口已经显示时不重复弹出。

| 触发 | 是否由用户发起 | `key` |
| --- | --- | --- |
| 菜单项「检查更新…」、「通用」页的「立即检查」 | 是 | |
| 菜单项「报告问题…」、「通用」页的同名按钮 | 是 | |
| 启动时与每 24 小时的自动检查发现新版本 | 否 | `update` |
| 启动后检测到上一次运行崩溃 | 否 | `crash` |

## 5 日志

### 5.1 写法不变的日志入口

`os.Logger` 的消息类型 `OSLogMessage` 由编译器特殊处理，应用拿不到拼好的文字，所以不能在 `Logger` 外面再接一个文件输出。本文用自己的消息类型代替它，方法名与插值的写法保持一致。

```swift
// [Core] Logging/LogLevel.swift（WP-0）
public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case debug, info, notice, error, fault
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool
}

// [Core] Logging/LogMessage.swift（WP-0）
public enum LogPrivacy: Sendable { case `public`, `private` }
public enum LogNumberFormat: Sendable { case fixed(precision: Int) }
/// 一条日志的文字：字面量与插值分段保存，渲染时才决定私有值是否显示。
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    public enum Segment: Sendable, Equatable { case literal(String); case value(String, LogPrivacy) }
    public var segments: [Segment]
    public init(stringLiteral value: String)
    public init(stringInterpolation: StringInterpolation)
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        public init(literalCapacity: Int, interpolationCount: Int)
        public mutating func appendLiteral(_ literal: String)
        public mutating func appendInterpolation(_ value: String, privacy: LogPrivacy = .private)
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy = .public)
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, format: LogNumberFormat? = nil, privacy: LogPrivacy = .public)
        public mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public)
        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .private)
    }
    /// includingPrivate 为假时，私有值写成 "<private>"。
    public func rendered(includingPrivate: Bool) -> String
}

// [Core] Logging/LogRecord.swift（WP-0）
public struct LogRecord: Sendable, Equatable {
    public var date: Date; public var level: LogLevel; public var category: String
    public var text: String                 // 已把私有值换成 "<private>"
}
public protocol LogSink: Sendable {
    func write(_ record: LogRecord)
    func flush()
}

// [Platform] Logging/LogChannel.swift（WP-0）
/// 一个模块的日志入口。方法名与 os.Logger 相同，调用处的写法不变。
public struct LogChannel: Sendable {
    public let category: String
    public func debug(_ message: @autoclosure () -> LogMessage)
    public func info(_ message: @autoclosure () -> LogMessage)
    public func notice(_ message: @autoclosure () -> LogMessage)
    public func error(_ message: @autoclosure () -> LogMessage)
    public func fault(_ message: @autoclosure () -> LogMessage)
}
public enum PlatformLog {
    public static let subsystem = "io.github.deletexiumu.eveopreview-macos"
    public static func logger(_ category: String) -> LogChannel
    /// 加一个输出目标。启动时由 App 调一次；不调时只写系统日志。
    public static func install(_ sink: any LogSink)
    /// 低于这个级别的记录不交给 install 进来的输出目标；系统日志不受影响。
    public static func setMinimumLevel(_ level: LogLevel)
    public static func flush()
}
```

规则：

- 插值的默认隐私与 `os.Logger` 相同：整数、浮点数、布尔值默认 `.public`，字符串和其他类型默认 `.private`。其他类型用 `String(describing:)` 转成文字。
- `format: .fixed(precision: n)` 把浮点数格式化成 n 位小数。
- `LogChannel` 的每个方法做三件事：渲染一次 `rendered(includingPrivate: false)`；把结果交给 `os.Logger`，写成 `"\(text, privacy: .public)"`，级别一一对应（`notice` 对应 `.default`）；记录的级别不低于 `setMinimumLevel` 设的级别时，把 `LogRecord` 交给每个已安装的输出目标。
- `debug` 级别在文件不要、系统日志也没有打开 debug 时不求值，所以参数是 `@autoclosure`。系统日志是否打开 debug 用 `OSLog(subsystem:category:).isEnabled(type: .debug)` 判断。
- 环境变量 `EVEO_LOG_PRIVATE=1` 时，交给系统日志的那一份改用 `includingPrivate: true`，供开发时在「控制台」里看私有值。交给输出目标的那一份始终不含私有值。
- subsystem 与 category 不变，`log stream --predicate 'subsystem == "io.github.deletexiumu.eveopreview-macos"'` 照常可用。

调用处的改动只有两种（U1）：

- Platform 的 13 处 `Logger(subsystem: PlatformLog.subsystem, category: "X")` 改成 `PlatformLog.logger("X")`，含 `PrivateActivation.swift:48` 那一处。`PlatformLog` 从 `PlatformServices.swift` 搬到 `Logging/LogChannel.swift`。
- `AppLog.logger(_:)` 的返回类型改成 `LogChannel`，内部调 `PlatformLog.logger`。

73 条日志语句本身不改。`import os` 可以留着（有的文件还用 `OSAllocatedUnfairLock`）。以后新写的代码一律经 `PlatformLog.logger` 或 `AppLog.logger`，不直接建 `Logger`。

### 5.2 日志文件

```swift
// [Core] Logging/LogLineFormatter.swift（WP-1）
public enum LogLineFormatter {
    public static let maxLineLength = 4096
    /// 一条记录一行：`2026-11-21T04:05:06.789Z ERROR [Capture] 文字`。换行与回车写成 `\n`、`\r`。
    public static func line(for record: LogRecord) -> String
}
// [Core] Logging/LogFileLayout.swift（WP-0）
public struct LogFileLayout: Sendable, Equatable {
    public var directory: URL
    public var baseName: String             // "eve-o-preview"
    public static func defaultDirectory() -> URL   // ~/Library/Logs/EVE-O Preview
    public var currentURL: URL                     // eve-o-preview.log
    public func archiveURL(_ index: Int) -> URL    // eve-o-preview.1.log，1 最新
    /// 目录里属于本布局的文件，最新的在前。
    public func existingURLs() -> [URL]
}
// [Core] Logging/RotatingLogFile.swift、Logging/LogRateLimiter.swift（WP-1）
public struct LogRotationPolicy: Sendable, Equatable {
    public var maxFileBytes: Int            // 1,048,576
    public var maxArchives: Int             // 4
}
/// 带轮转的日志文件。不是线程安全的，由调用方串行使用。
public final class RotatingLogFile {
    public init(layout: LogFileLayout, policy: LogRotationPolicy)
    public func append(_ line: String) throws
    public func close()
}
public struct LogRateLimiter: Sendable {
    public enum Admission: Sendable, Equatable { case write; case writeAfterDropping(Int); case drop }
    public init(capacity: Int = 200, refillPerSecond: Double = 50)
    public mutating func admit(at uptime: Double) -> Admission
}

// [Platform] Logging/FileLogSink.swift（WP-1）
public final class FileLogSink: LogSink {
    public init(layout: LogFileLayout, policy: LogRotationPolicy)
    public func write(_ record: LogRecord)
    public func flush()
}
```

| 项目 | 取值 |
| --- | --- |
| 目录 | `~/Library/Logs/EVE-O Preview/`，权限 0700；环境变量 `EVEO_LOG_DIR` 可覆盖 |
| 文件 | `eve-o-preview.log`（当前），`eve-o-preview.1.log`～`eve-o-preview.4.log`（旧，1 最新），权限 0600，UTF-8 |
| 单个文件上限 | 1,048,576 字节 |
| 合计上限 | 5 个文件，约 5 MiB |
| 一行的格式 | `<UTC 时间，毫秒> <级别大写> [<category>] <文字>`，如 `2026-11-21T04:05:06.789Z ERROR [Capture] …` |
| 一行的上限 | 4,096 个字符，超出的部分换成 `…[truncated]` |
| 换行 | 文字里的换行与回车写成 `\n`、`\r`，一条记录只占一行 |

- 轮转只看大小，不在启动时轮转，所以崩溃那次运行的日志仍在当前文件或 `.1` 文件里。
- 轮转的条件：追加前当前文件不空，且「当前大小 + 这一行」超过上限。
- 轮转的做法：关闭当前文件，删掉 `.4`。把 `.3` 到 `.1` 依次改名为后一个序号。把当前文件改名为 `.1`，再建新文件。
- `FileLogSink` 用一把 `OSAllocatedUnfairLock` 保护 `RotatingLogFile` 与 `LogRateLimiter`，在调用线程上同步 `write(2)`，不经过队列。这样崩溃前最后一条日志已经交给了内核。一次写入约几微秒，鼠标事件监听的线程上也可以写。不调 `fsync`。
- 限速：令牌桶容量 200 条，每秒补 50 条。桶空时丢弃记录并计数，恢复后先写一行 `… dropped N lines`。它只防止某处循环写日志把 5 个文件冲掉。
- 连续 3 次写入失败后，`FileLogSink` 停止写文件，并向系统日志记一条 `error`。
- `LogBootstrap.start` 装上 `FileLogSink` 后先写一行会话头，含会话编号的前 8 位、版本、构建标签、签名类别、macOS 版本与架构。
- 重复启动后自己退出的实例、`EVEOProbe`、单元测试都不装文件输出，只写系统日志。
- 演示模式与正式运行写同一个目录。

### 5.3 级别

| 级别 | 用途 | 默认是否写进文件 |
| --- | --- | --- |
| `debug` | 排查问题时才看的细节 | 否；`general.logLevel` 为 `debug` 时写 |
| `info` | 启动、退出、客户端增减、设置变化、检查更新的结果 | 是 |
| `notice` | 不常见但不是错误的情况，如使用了测试用的更新地址 | 是 |
| `error` | 操作失败，功能受影响 | 是 |
| `fault` | 程序自身的错误，如未捕获的异常 | 是 |

「通用」页的「详细日志」开关把 `general.logLevel` 在 `info` 与 `debug` 之间切换，改动立即生效（`diagnosticsSettingsDidChange` 调 `LogBootstrap.apply(level:)`）。
任何级别都不应在每帧、每个输入事件或每次轮询里无条件写日志。

### 5.4 不应写进日志的内容

- 角色名、窗口标题、配置方案名、循环组名：只能以 `.private` 插值出现。
- 游戏日志的行文字、收听者以外的任何文件内容。
- 配置文件的全文。
- 屏幕画面、按键与鼠标事件的内容。热键的规范写法（如 `ctrl+F13`）可以写。
- 环境变量的值、发布说明的全文、下载内容。
- 路径可以标 `.public`。主目录里的用户名在生成报告时替换（7.3 节）。

### 5.5 未捕获的异常与终止信号

- `LogBootstrap.start` 用 `NSSetUncaughtExceptionHandler` 装一个处理函数：写一条 `fault`（异常的名称与原因），再调 `PlatformLog.flush()`。它不阻止崩溃。
- 不给 `SIGSEGV`、`SIGABRT`、`SIGILL`、`SIGBUS`、`SIGTRAP` 装处理函数。信号处理函数里不能安全地写日志，崩溃现场由系统的崩溃报告记录。
- `SessionTracker.start` 给 `SIGTERM` 与 `SIGINT` 各建一个 `DispatchSource` 信号源（先 `signal(_, SIG_IGN)`），收到后调 `NSApp.terminate(nil)`。这样 `kill <PID>` 也走正常的退出流程，不被记成异常结束。

## 6 异常退出检测

### 6.1 会话标记

每次运行在 `~/Library/Application Support/EVE-O Preview/session.json` 里留一个标记。

```swift
// [Core] Diagnostics/SessionModels.swift（WP-0）
public struct SessionMarker: Sendable, Equatable, Codable {
    public var markerVersion: Int               // 1
    public var sessionID: String                // UUID
    public var pid: Int32
    public var appVersion: String; public var buildLabel: String
    public var startedAt: Date
    public var endedCleanly: Bool
}
public enum PreviousRunOutcome: Sendable, Equatable {
    case noRecord                               // 没有标记，或标记读不懂
    case clean
    case stillRunning(SessionMarker)            // 上一个实例还在（重新启动的交接超时）
    case abnormal(SessionMarker)                // 没有正常结束
}
public struct CrashReportCandidate: Sendable, Equatable {
    public var fileName: String; public var modifiedAt: Date; public var byteCount: Int
    public var firstLine: String?               // 文件的第一行，最多 4,096 字节
}

// [Core] Diagnostics/SessionMarkerRules.swift（WP-1）、Diagnostics/CrashReportMatcher.swift（WP-0 骨架，WP-1 实现）
public enum SessionMarkerRules {
    public static func decode(_ data: Data) -> SessionMarker?
    public static func encode(_ marker: SessionMarker) -> Data
    public static func outcome(previous: SessionMarker?, isPreviousProcessAlive: Bool) -> PreviousRunOutcome
}
public struct CrashReportHeader: Sendable, Equatable {
    public var bundleID: String?; public var appName: String?; public var appVersion: String?
}
public enum CrashReportMatcher {
    public static let maxReports = 3
    public static let maxReportBytes = 1_048_576
    public static func isCandidateName(_ fileName: String, executableName: String) -> Bool
    public static func header(fromFirstLine line: String) -> CrashReportHeader?
    /// 选出属于本应用、修改时间落在 window 里的报告，最新的在前，最多 maxReports 个。
    public static func select(from candidates: [CrashReportCandidate], executableName: String, bundleID: String,
                              window: ClosedRange<Date>) -> [CrashReportCandidate]
}

// [App] Diagnostics/SessionTracker.swift（WP-0 骨架，WP-1 实现）
@MainActor final class SessionTracker {
    private(set) var previousRun: PreviousRunOutcome
    var onCrashDetected: (@MainActor (PendingCrash) -> Void)?
    init(environment: AppEnvironment, state: StateController, diagnostics: any DiagnosticsService, isFakeMode: Bool)
    /// 读上一次的标记、写本次的标记、装信号处理，并安排崩溃报告的扫描。
    func start()
    /// 把本次运行记为正常结束。只在 AppDelegate.replyToTerminate 里调。
    func markEndedCleanly()
}
```

`SessionTracker.start()` 的步骤：

1. 读 `session.json`，用 `SessionMarkerRules.decode` 解码。读不到或解不出时 `previous` 为 `nil`。
2. 算 `isPreviousProcessAlive`：`previous.pid` 不是本进程，且 `NSRunningApplication(processIdentifier:)` 取得到、bundle id 与本应用相同、没有终止。
3. 调 `SessionMarkerRules.outcome`，结果存进 `previousRun`，写一条 `info` 日志。
4. 以原子方式写入本次运行的标记，`endedCleanly` 为假。
5. 装 5.5 节的信号源。
6. 结果是 `.abnormal` 时，按 6.2 节安排扫描。

`SessionMarkerRules.outcome` 的规则：

| `previous` | `isPreviousProcessAlive` | 结果 |
| --- | --- | --- |
| `nil`，或 `markerVersion` 不是 1 | 任意 | `.noRecord` |
| `endedCleanly` 为真 | 任意 | `.clean` |
| `endedCleanly` 为假 | 真 | `.stillRunning` |
| `endedCleanly` 为假 | 假 | `.abnormal` |

`markEndedCleanly()` 把标记改成 `endedCleanly` 为真后写回。它只在 `AppDelegate.replyToTerminate` 里调用（4.4 节）。

各种结束方式的归类：

| 结束方式 | 标记 | 归类 |
| --- | --- | --- |
| 菜单「退出」、注销、关机、`kill <PID>`（5.5 节） | 已结束 | `.clean` |
| 权限页的「重新启动」、安装更新后的重新启动 | 旧实例退出前标为已结束 | `.clean`；旧实例 8 秒内没有退出时是 `.stillRunning`，不算异常 |
| 停止捕获超时后退出（2.5 秒） | 已结束 | `.clean` |
| 崩溃（Swift 运行时错误、未捕获的异常、非法内存访问） | 未结束 | `.abnormal`，通常有崩溃报告 |
| 强制退出、`kill -9`、断电、系统重启时被强行终止 | 未结束 | `.abnormal`，没有崩溃报告 |
| 重复启动的实例自己退出 | 不碰标记 | 不影响 |

### 6.2 匹配崩溃报告

`.abnormal` 不等于崩溃。只有在系统的崩溃报告目录里找到对应的报告，才认为上一次运行崩溃了。

- 目录：`~/Library/Logs/DiagnosticReports/` 及其 `Retired/` 子目录。
- `CrashReportMatcher.isCandidateName`：文件名以 `<可执行文件名>-` 或 `<可执行文件名>_` 开头，扩展名是 `ips`（最低支持的 macOS 14 不再写 `.crash`，见 19 节）。可执行文件名是 `EVEOPreview`。
- 时间窗口：文件的修改时间不早于 `previous.startedAt` 减 5 秒，不晚于扫描时刻加 5 秒。
- `CrashReportMatcher.header`：把文件的第一行当作 JSON 对象解析，取 `bundleID`、`app_name`、`app_version`。解析失败返回 `nil`，这个文件仍按文件名与时间参与匹配。解析成功且 `bundleID` 有值、又不等于本应用的 bundle id 时，排除这个文件。
- `select` 把符合条件的文件按修改时间从新到旧排序，取前 3 个。
- 系统写崩溃报告要几秒。`SessionTracker` 在启动后 5 秒扫描一次；没有找到时在 30 秒再扫描一次。两次都在后台任务里做，不占主线程。

`.ips` 文件的格式没有在本机核实（U9、V17）。上面的规则只依赖文件名与修改时间，文件头只用来排除别的应用。

### 6.3 提示

- 找到报告，且 `previous.sessionID` 不在 `state.diagnostics.dismissedSessionIDs` 里：把 `PendingCrash` 写进 `state.json`，调 `onCrashDetected`。
- `ProblemReportController.crashDetected(_:)`：调 `coordinator.setAttention(.crashPending, on: true)`；菜单顶部出现「EVE-O Preview 上次意外退出 — 报告…」；经 `DeferredPresenter` 以 `key: "crash"` 显示报告窗口（崩溃情境，7.4 节）。每次运行最多自动显示一次。
- 启动时 `state.json` 里已有 `pendingCrash`（上次选了「以后再说」）：同样亮起圆点和菜单项，并自动显示一次窗口。
- 用户在窗口里选「不报告」：会话编号加进 `dismissedSessionIDs`（超过 20 个时丢掉最早的），清掉 `pendingCrash` 与圆点。
- 用户生成了报告：清掉 `pendingCrash` 与圆点。
- `.abnormal` 但没有找到报告：只写一条 `info` 日志，并在报告的摘要里记 `previousRun: abnormal`，不提示用户。断电和强制退出不应换来一个报告窗口。

## 7 问题报告

### 7.1 入口与流程

入口有三个：菜单栏菜单的「报告问题…」、「通用」页的同名按钮、6.3 节的崩溃提示。前两个打开手动情境的窗口，第三个打开崩溃情境的窗口。

```swift
// [App] Diagnostics/ProblemReportController.swift（WP-0 骨架，WP-2 实现）
enum ProblemReportContext: Sendable, Equatable { case manual; case crash(PendingCrash) }
@MainActor final class ProblemReportController {
    init(coordinator: AppCoordinator, environment: AppEnvironment, state: StateController)
    /// 用户从菜单或设置窗口打开。
    func showReportWindow(context: ProblemReportContext)
    /// 检测到崩溃后调用：亮起菜单栏的提示，并在不打断游戏时显示报告窗口。
    func crashDetected(_ crash: PendingCrash)
    func dismissPendingCrash()
}
```

用户确认之前，应用不写任何文件，不打开浏览器。流程：

1. 在主线程取快照：`RuntimeSummary`（来自协调器）、`ConfigSummary`（来自当前配置）、角色名清单（`CharacterNameCollector.names`）。
2. 在后台任务里收集：`diagnostics.systemInfo()`、`diagnostics.sensitiveNames()`、日志文件（按 `DiagnosticsBundlePlanner.logSlices` 读取）、崩溃报告。崩溃情境取 `PendingCrash.reportFileNames`；手动情境用 `CrashReportMatcher.select` 取最近 7 天内的报告。
3. 用 `Redactor` 处理每个文件的内容，得到预览项（名称、大小、脱敏后的文字、替换次数）。全部在内存里。
4. 显示报告窗口（7.4 节）。
5. 用户点「生成报告并打开 GitHub」或「只生成报告」：把勾选的文件加上 `manifest.json` 交给 `diagnostics.writeArchive(named:files:)`。
6. 调 `diagnostics.revealInFinder(zip)`。选了前一个按钮时，再用 `IssueURLBuilder.url(for:)` 生成地址并调 `diagnostics.openInBrowser(url)`。
7. 崩溃情境下清掉 `pendingCrash`。窗口换成完成页，说明把 zip 拖进浏览器里的 Issue 页面。

第 5 步失败时窗口显示原因，不打开浏览器。

### 7.2 报告的内容

```swift
// [Core] Contracts/DiagnosticsContracts.swift（WP-0）
public struct SystemInfo: Sendable, Equatable, Codable {
    public var osVersion: String; public var osBuild: String
    public var architecture: String             // "arm64"、"x86_64"
    public var isTranslated: Bool               // 在 Rosetta 下运行
    public var hardwareModel: String            // sysctl hw.model
    public var cpuBrand: String                 // sysctl machdep.cpu.brand_string
    public var physicalMemoryBytes: UInt64; public var processorCount: Int
    public var localeIdentifier: String; public var preferredLanguages: [String]
}
public struct SensitiveNames: Sendable, Equatable {
    public var userName: String; public var fullUserName: String
    public var homeDirectory: String
    public var hostNames: [String]              // 主机名与电脑名称
}
public struct DiagnosticsFile: Sendable, Equatable {
    public var relativePath: String             // 压缩包里的相对路径，如 "logs/eve-o-preview.log"
    public var contents: Data
}
public enum DiagnosticsIOError: Error, Sendable, Equatable {
    case writeFailed(path: String, reason: String)
    case archiveFailed(reason: String)
}
public protocol DiagnosticsService: Sendable {
    func systemInfo() -> SystemInfo
    func sensitiveNames() -> SensitiveNames
    /// ~/Library/Logs/DiagnosticReports（含 Retired 子目录）里文件名以可执行文件名开头的报告。
    func crashReportCandidates(executableName: String) -> [CrashReportCandidate]
    func readCrashReport(named fileName: String, maxBytes: Int) -> Data?
    /// 把 files 写进一个以 name 命名的文件夹并压成 zip，返回 zip 的位置；同时只保留最近 3 个报告。
    func writeArchive(named name: String, files: [DiagnosticsFile]) throws(DiagnosticsIOError) -> URL
    @MainActor func revealInFinder(_ url: URL)
    @MainActor func openInBrowser(_ url: URL)
}

// [Core] Diagnostics/DiagnosticsSummary.swift（WP-2）
public struct ConfigSummary: Sendable, Equatable, Codable {
    public init(config: AppConfig, loadErrorKind: String?, warningKinds: [String])
}
public struct RuntimeSummary: Sendable, Equatable, Codable {
    public var uiLanguage: String
    public var screenRecordingGranted: Bool; public var accessibilityGranted: Bool
    public var combatLogStatus: String
    public var characterClients: Int; public var loginClients: Int; public var unknownClients: Int
    public var captureStates: [String: Int]     // 状态名 → 个数
    public var hotkeyBindings: Int; public var hotkeyFailures: [String: Int]
    public var screens: [String]                // 如 "1728x1117@2x main"
    public var uptimeSeconds: Int
    public var previousRun: String              // clean、abnormal、crashed、noRecord
    public var isFakeMode: Bool
}
public struct EnvironmentReport: Sendable, Equatable {
    public var app: AppEnvironment; public var system: SystemInfo; public var runtime: RuntimeSummary
    /// 压缩包里 summary.md 的全文（英文）。
    public func markdown(generatedAt: Date) -> String
    /// Issue 正文里「Environment」一节的各行（英文），不含任何路径与名字。
    public func issueLines() -> [String]
}
public enum DiagnosticsBundlePlanner {
    public static let maxLogBytes = 2_097_152
    /// 从最新的日志文件起取，合计不超过 maxLogBytes；超出的那个文件只留末尾。
    public static func logSlices(fileSizes: [(name: String, bytes: Int)]) -> [(name: String, tailBytes: Int)]
    public static func archiveName(at date: Date) -> String    // EVE-O-Preview-diagnostics-20261121-040506
}
```

压缩包的名字是 `EVE-O-Preview-diagnostics-<yyyyMMdd-HHmmss>.zip`（UTC），里面是同名的文件夹：

| 文件 | 内容 | 上限 | 能否取消勾选 |
| --- | --- | --- | --- |
| `summary.md` | `EnvironmentReport.markdown`：应用版本、构建标签、提交、签名类别、安装位置类别；macOS 版本与构建号、架构、是否经 Rosetta、机型、CPU、内存；界面语言、系统语言；屏幕；权限状态；客户端数量；热键与捕获的状态统计；运行时长；上一次运行的归类 | | 否 |
| `config-summary.json` | `ConfigSummary` | | 能 |
| `logs/eve-o-preview.log`、`logs/eve-o-preview.N.log` | 应用日志，从最新的文件起取 | 合计 2 MiB，超出的那个文件只留末尾 | 能 |
| `crash/crash-1.ips`～`crash-3.ips` | 系统的崩溃报告，按从新到旧编号，不沿用原文件名（U9） | 最多 3 个，每个 1 MiB | 能 |
| `manifest.json` | 文件清单、各文件的大小与替换次数、生成时刻、应用版本 | | 否 |

`ConfigSummary` 包含的内容：

- `schemaVersion`、配置方案的数量、读配置的错误类别与警告类别（只有类别名）。
- 当前配置方案的 `thumbnail`、`overlay`、`behavior`、`capture`、`combatAlert`、`hotkeyDefaultScope` 各项的值。
- 各类条目的数量：`layouts`、`hiddenCharacters`、`highlightColors`、`characterHotkeys`、循环组及每组的成员数。
- 热键字符串：通用热键、每个循环组的前进与后退热键、角色热键（只有热键，角色名换成序号）。
- `general` 的 `pollIntervalMs`、`language`、`checkForUpdates`、`autoInstallUpdates`、`logLevel`；`eveLogDirectory` 只写 `default` 或 `custom`。

`ConfigSummary` 不包含：配置方案名、循环组名、角色名、任何路径、其他配置方案的内容。用户自己起的名字可能含任何文字，所以这些字段整个不进报告，不靠脱敏。

`ReportArchiver` 的做法：在 `~/Library/Application Support/EVE-O Preview/Reports/` 下建同名文件夹并写入各文件，运行 `/usr/bin/ditto -c -k --norsrc --keepParent <文件夹> <zip>`（经 `ProcessRunner`，超时 30 秒），删掉文件夹。然后只保留最新的 3 个报告：只删文件名同时满足「以 `EVE-O-Preview-diagnostics-` 开头」和「以 `.zip` 结尾」的文件。

### 7.3 脱敏

```swift
// [Core] Diagnostics/Redactor.swift（WP-2）
public struct RedactionTerms: Sendable, Equatable {
    public var userNames: [String]              // 短用户名与全名
    public var hostNames: [String]
    public var characterNames: [String]
    public var homeDirectory: String?           // 不是 /Users/<用户名> 的主目录也能认出来
}
public struct RedactionCounts: Sendable, Equatable {
    public var user: Int; public var host: Int; public var character: Int; public var identifier: Int
    public static func + (lhs: RedactionCounts, rhs: RedactionCounts) -> RedactionCounts
}
public struct Redactor: Sendable {
    public static let userPlaceholder = "[user]"
    public static let hostPlaceholder = "[host]"
    public init(terms: RedactionTerms)
    /// 角色名的占位符，如 "[character-2]"；序号按名字排序后从 1 起编。
    public func placeholder(forCharacter name: String) -> String?
    public func redact(_ text: String) -> (text: String, counts: RedactionCounts)
}
public enum CharacterNameCollector {
    /// 全部配置方案里出现过的角色名，加上在线客户端的角色名，去重。
    public static func names(config: AppConfig, online: [String]) -> [String]
}
```

要替换的词：

| 类别 | 来源 | 占位符 |
| --- | --- | --- |
| 用户名 | `NSUserName()`、`NSFullUserName()`、主目录路径 | `[user]`；主目录路径整个换成 `/Users/[user]` |
| 主机名 | `gethostname`（另加去掉域名后缀的写法）、`SCDynamicStoreCopyComputerName`、`SCDynamicStoreCopyLocalHostName`。不用 `ProcessInfo.hostName` 与 `Host.current()`，它们会等域名解析 | `[host]` |
| 角色名 | 全部配置方案的 `layouts`、`hiddenCharacters`、`highlightColors`、`characterHotkeys`、循环组成员，加上在线客户端的角色名 | `[character-N]`，N 按名字排序（不区分大小写）后从 1 起编，同一份报告里同一个角色的序号不变 |
| 设备标识 | 崩溃报告里 JSON 键 `crashReporterKey`、`deviceIdentifierForVendor` 的字符串值 | `[redacted]` |

匹配规则：

1. 一次扫描完成。在每个位置试全部的词，取能匹配的最长的一个，输出占位符，再从匹配的末尾继续。不对替换后的文字再做替换：名叫 `user` 的角色不会破坏已输出的占位符，`Bob Jr` 先于 `Bob` 匹配。
2. 比较不区分大小写。
3. 只由 ASCII 字符组成的词要求两侧是边界：匹配的前一个字符和后一个字符都不是 ASCII 字母或数字。含非 ASCII 字符的词（如中文角色名）不要求边界。
4. 去掉首尾空白后不足 3 个字符的 ASCII 词，只在紧跟 `/Users/` 或 `\/Users\/` 时替换。不足 2 个字符的非 ASCII 词不替换。
5. 主目录路径同时匹配两种写法：原样的，和每个 `/` 写成 `\/` 的（JSON 转义，V17）。
6. 设备标识按 `"键" : "值"` 的形式匹配，冒号两侧的空白可有可无，只替换值。

适用范围：压缩包里每个文件的内容、Issue 的标题与正文。压缩包里的文件名都是应用自己起的，不含原文件名。
替换次数按类别计数，显示在预览窗口并写进 `manifest.json`。

已知的局限（写进 README 的隐私一节）：

- 只替换应用知道的名字。本机从未登录过、配置里也没有出现过的角色名不会被替换。
- 角色名或用户名是常见的词时，日志里同样的词也会被替换。这只让报告难读一些，不泄露信息。
- 用户在生成前能看到每个文件脱敏后的全文，可以取消勾选某个文件。

### 7.4 报告窗口

窗口是 `NSWindow` 加 `NSHostingController`，宽 720 点、高 520 点，可缩放。

- 顶部：手动情境显示说明文字 `intro`；崩溃情境显示 `crashIntro`。下面一行是 `redactionNote`。
- 左栏：文件列表，每行有勾选框、名称、大小。`summary.md` 与 `manifest.json` 的勾选框不可用。
- 右栏：选中文件脱敏后的文字，等宽字体，只读，可选择复制。超过 200,000 个字符时只显示开头，并在下方注明。再下面一行是替换次数。
- 底部按钮：手动情境是「取消」「只生成报告」「生成报告并打开 GitHub」；崩溃情境把「取消」换成「不报告」和「以后再说」。
- 收集期间（7.1 节第 2、3 步）显示进度指示，按钮不可用。
- 完成页：说明文字 `doneHelp`，按钮「在访达中显示」「再次打开 GitHub」「关闭」。

### 7.5 Issue 地址

```swift
// [Core] Diagnostics/IssueURLBuilder.swift（WP-2）
public struct IssueSection: Sendable, Equatable {
    public var heading: String; public var body: String
    public var isRequired: Bool                 // 必留的小节只会被截短，不会被丢掉
}
public struct IssueDraft: Sendable, Equatable { public var title: String; public var sections: [IssueSection] }
public enum IssueURLBuilder {
    public static let repository = "deletexiumu/eve-o-preview-macos"
    public static let maxURLBytes = 6000
    public static let maxTitleCharacters = 120
    public static func body(for draft: IssueDraft) -> String
    /// 返回的 URL 百分号编码后不超过 limit 字节。
    public static func url(for draft: IssueDraft, limit: Int = maxURLBytes) -> URL
}
```

- 地址的形式：`https://github.com/deletexiumu/eve-o-preview-macos/issues/new?title=<标题>&body=<正文>`。不带 `template` 与 `labels` 参数（V19）。
- 标题与正文一律用英文，不随界面语言变化，便于维护者阅读。标题：手动情境是 `Problem report: EVE-O Preview <版本> on macOS <系统版本>`，崩溃情境把开头换成 `Crash report:`。标题超过 120 个字符时截短。
- 正文由小节拼成，每节是 `### <标题>`、空行、内容、空行：

| 顺序 | 小节 | 内容 | `isRequired` |
| --- | --- | --- | --- |
| 1 | `What happened` | 一行 HTML 注释，请用户描述经过，并把访达里显示的 zip 拖进来 | 是 |
| 2 | `Environment` | `EnvironmentReport.issueLines()`：版本、构建标签、签名类别、macOS 版本、架构、机型、界面语言、两项权限 | 是 |
| 3 | `Previous run` | 只在崩溃情境出现：上一次运行的版本、崩溃报告的个数 | 否 |
| 4 | `Diagnostics` | zip 的文件名 | 是 |

- 编码：用 `URLComponents.queryItems` 生成，再把查询串里的 `+` 换成 `%2B`（GitHub 把 `+` 当空格）。
- 预算：`url.absoluteString.utf8.count` 不超过 6,000。一个汉字编码后占 9 字节，所以正文只用 ASCII。
- 超出时按以下顺序缩短，每一步之后重新计算：
  1. 从后往前丢掉 `isRequired` 为假的小节。
  2. 从 `Environment` 的末尾逐行删。
  3. 把最后一个小节的内容按字符从末尾截短，补上 `…`。
- 标题与正文在编码前先经 `Redactor` 处理。`issueLines()` 本身不含路径和名字，这一步是第二道保险。

### 7.6 Issue 模板

仓库增加 `.github/ISSUE_TEMPLATE/bug_report.md` 与 `config.yml`，供不经应用、直接在网页上报告的用户使用（主会话负责，13.3 节）：

- `bug_report.md` 的小节与 7.5 节相同（`What happened`、`Environment`、`Diagnostics`），并说明可以用应用里的「报告问题…」生成 zip。
- `config.yml` 写 `blank_issues_enabled: true`。应用生成的地址不带 `template` 参数，要靠空白 Issue 的入口预填正文。

## 8 更新检查

### 8.1 发布契约

应用按固定的名字找附件。下表是 CI 与应用之间的契约，改动其中任何一项都会让已安装的版本无法自动安装，只能提示。

| 项目 | 约定 |
| --- | --- |
| tag | `v<版本号>`，版本号与仓库根目录 `VERSION` 文件一致，符合语义化版本（8.3 节） |
| Release | 正式版不是草稿、不标预发布；tag 名带 `-` 的标为预发布（现有规则） |
| 安装包 | `EVE-O-Preview-<版本号>.dmg`。卷的顶层有一个名为 `EVE-O Preview.app` 的真实目录（不是符号链接） |
| dmg 里的应用 | 通用二进制；`CFBundleIdentifier` 是 `io.github.deletexiumu.eveopreview-macos`；`CFBundleExecutable` 是 `EVEOPreview`；`CFBundleShortVersionString` 等于版本号；用发布证书签名，指定要求与以前的正式版相同 |
| 校验和 | `SHA256SUMS.txt`，`shasum -a 256` 的输出格式，其中有 dmg 那一行 |
| 源码包 | `eve-o-preview-macos-<版本号>-source.tar.gz` 与 `.zip`。应用不使用 |
| Release 正文 | 8.2 节的格式 |
| `Info.plist` 的附加键 | `EVEOBuildLabel`（文件名里的版本标签，如 `1.1.0`、`1.1.0-pr.12.abc1234`）、`EVEOBuildCommit`（提交的前 7 位） |

- 附件名在 Core 的 `UpdateAssetContract` 里各有一个常量或函数，测试用例把上表的名字写死。
- 要换名字时，新旧两个名字的附件应并存至少一个正式版，让旧版本先升级到认得新名字的版本。
- Release 里找不到 dmg 或 `SHA256SUMS.txt` 时，应用降为只提示并打开发布页（`assetMissing`）。

### 8.2 发布说明的格式与选取

格式由主会话定下，原文如下（`docs/release-notes/macos/<tag>.md` 原样用作 Release 正文）：

- 英文正文在最前，包在 `<!-- lang:en -->` 与 `<!-- /lang:en -->` 之间。
- 之后每种语言一个可折叠的块，顺序是 zh、ja、ko、ru。每块的形式是：`<!-- lang:zh -->`，换行，`<details><summary>简体中文</summary>`，空行，Markdown 正文，空行，`</details>`，换行，`<!-- /lang:zh -->`。ja（日本語）、ko（한국어）、ru（Русский）同理。
- 语言代码与应用的界面语言代码相同（en、zh、ja、ko、ru）。

`ReleaseNotes.section(for:in:)` 的规则：

1. 先把正文里的 CRLF 换成 LF。
2. 找 `<!-- lang:<代码> -->` 与它之后第一个 `<!-- /lang:<代码> -->` 之间的文字。标记里 `<!--` 之后、`-->` 之前的空白可有可无，代码不区分大小写。
3. 界面语言的块存在时取它，不存在时取 `en` 的块。两块都没有时返回整个正文。1.0.0 的说明没有任何标记，属于这种情况（U13）。
4. 取出的文字如果以 `<details>` 开头（前面允许有空白），去掉从 `<details>` 到第一个 `</summary>` 的部分，以及最后一个 `</details>`。
5. 去掉首尾的空白行。

显示办法见 8.7 节。

### 8.3 版本比较与预发布

```swift
// [Core] Updates/SemanticVersion.swift（WP-3）
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int; public var minor: Int; public var patch: Int
    public var prerelease: [String]             // "1.2.0-beta.1" 的 ["beta", "1"]
    public var build: [String]                  // "+" 后面的部分，不参与比较
    public init?(_ text: String)   // 接受开头的 "v" 或 "V"
    public var isPrerelease: Bool
    public var description: String
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool
    public func hash(into hasher: inout Hasher)
}
```

- 解析：可选的 `v` 或 `V`，然后是 `主.次.修订`，可选的 `-预发布标识`，可选的 `+构建信息`。三段数字都应是非负整数。只有两段（`1.1`）或有四段的写法解析失败。
- 预发布标识按 `.` 分段，每段由 ASCII 字母、数字和 `-` 组成，不能为空。
- 比较按语义化版本 2.0.0 第 11 条：先比三段数字；数字相同时没有预发布标识的更大；都有时逐段比较，两段都是纯数字按数值比，否则按 ASCII 顺序比，纯数字的小于含字母的，前面各段都相同时段数多的更大。构建信息不参与比较。
- 放宽一处：纯数字的段带前导零（如提交号 `0012345`）时不报错，按含字母的段处理。CI 的标签 `1.1.0-pr.12.0012345` 因此能解析。
- 正在运行的版本取 `UpdatePolicy.comparableVersion`：先解析 `AppEnvironment.buildLabel`，失败时解析 `version`，都失败时返回 `nil`，更新功能按 `unparsableVersion` 处理（不提示）。

`buildLabel` 的作用：CI 给同仓库的 PR 构建和 `main` 构建也用发布证书签名，它们的 `CFBundleShortVersionString` 与下一个正式版相同。标签 `1.1.0-pr.12.abc1234`、`1.1.0-dev.abc1234` 按上面的规则都小于 `1.1.0`，所以这些构建在 1.1.0 发布后会收到更新，并且能安装。本机用 `build-app.sh` 构建的标签等于版本号，不会被提示升级到同一个版本。

预发布版本：本轮忽略，不设开关。

- `releases/latest` 只返回最新的正式版，不含草稿和预发布版本，一次请求就够。
- 要支持预发布通道，得改用 `releases` 列表接口并自己筛选，另加一个设置项和 5 种语言的文字。项目现在没有发过预发布版本。
- `SemanticVersion` 已经能比较预发布标识。以后要加通道时，只加一个设置项和一个接口地址。
- 防御：答复里 `prerelease` 或 `draft` 为真，或 tag 解析出预发布标识时，一律不提示。

### 8.4 请求、答复与限流

```swift
// [Core] Updates/UpdateModels.swift（WP-0）
public struct ReleaseAsset: Sendable, Equatable, Codable {
    public var name: String; public var downloadURL: String; public var size: Int?
}
public struct ReleaseInfo: Sendable, Equatable, Codable {
    public var version: String                  // tag 去掉开头的 "v"
    public var tagName: String; public var title: String
    public var notes: String                    // Release 正文，最多保留 65,536 个字符
    public var pageURL: String
    public var publishedAt: Date?
    public var isPrerelease: Bool; public var isDraft: Bool
    public var assets: [ReleaseAsset]
}
public enum InstallBlocker: String, Sendable, Equatable, Codable, CaseIterable {
    case translocated, readOnlyVolume, locationNotWritable, adHocSignature, developmentSignature, unsigned
}
public enum InstallCapability: Sendable, Equatable {
    case canInstall
    case notifyOnly(InstallBlocker)             // 只提示并打开发布页
    case unavailable                            // 不是从 .app 运行，更新功能整个停用
}
public struct PreparedUpdate: Sendable, Equatable, Codable {
    public var version: String; public var imagePath: String; public var sha256: String; public var preparedAt: Date
}
public struct UpdateProgress: Sendable, Equatable { public var receivedBytes: Int64; public var totalBytes: Int64? }
public struct InstallOutcome: Sendable, Equatable { public var installedVersion: String; public var stagingPath: String }
public enum UpdateError: Error, Sendable, Equatable {
    case network(String)
    case httpStatus(Int)
    case rateLimited(until: Date?)
    case malformedFeed(String)
    case assetMissing(String)                   // 缺少的附件名
    case insufficientDiskSpace
    case downloadTooLarge
    case checksumListInvalid
    case checksumEntryMissing(String)
    case checksumMismatch
    case imageMountFailed(String)
    case appMissingInImage
    case signatureInvalid(status: Int32)
    case requirementNotSatisfied
    case bundleMismatch(String)                 // bundle id、可执行文件名或架构不符
    case versionMismatch(expected: String, found: String)
    case notNewer
    case unsupportedSystem(minimum: String)
    case blocked(InstallBlocker)
    case swapFailed(code: Int32)
    case cancelled
}
public enum UpdatePhase: Sendable, Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(ReleaseInfo)
    case downloading(ReleaseInfo, UpdateProgress)
    case verifying(ReleaseInfo)
    case readyToInstall(ReleaseInfo)
    case installing(ReleaseInfo)
    case relaunching
    case failed(UpdateError, release: ReleaseInfo?)
}

// [Core] Contracts/UpdateContracts.swift（WP-0）
public struct UpdateFeed: Sendable, Equatable {
    public var feedURL: URL
    public var isTestFeed: Bool
    public static let productionURL = URL(string: "https://api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest")!
    public static let productionAssetPrefix = "https://github.com/deletexiumu/eve-o-preview-macos/releases/"
    /// override 是环境变量 EVEO_UPDATE_FEED_URL 的值。只接受 https，或主机是 127.0.0.1、localhost、::1 的 http。
    public static func resolve(override: String?) -> UpdateFeed
    /// 附件与发布页的地址是否可用：正式地址应以 productionAssetPrefix 开头；测试地址应与 feedURL 同源。
    public func accepts(_ urlString: String) -> Bool
}
public enum ReleaseFetchResult: Sendable, Equatable {
    case release(ReleaseInfo, etag: String?)
    case notModified
    case noRelease                              // 404：仓库还没有正式版
    case rateLimited(until: Date?)
    case failed(UpdateError)
}
public protocol UpdateService: Sendable {
    func fetchLatestRelease(feed: UpdateFeed, etag: String?, appVersion: String) async -> ReleaseFetchResult
    /// 下载校验和文件与 dmg，核对 SHA-256，返回放在缓存目录里的 dmg。
    func prepare(_ release: ReleaseInfo, feed: UpdateFeed,
                 progress: @escaping @Sendable (UpdateProgress) -> Void) async -> Result<PreparedUpdate, UpdateError>
    func cancelPreparation()
    /// 挂载、复制、验证并替换已安装的应用。不重新启动。
    func install(_ prepared: PreparedUpdate, environment: AppEnvironment) async -> Result<InstallOutcome, UpdateError>
    /// 删除缓存目录里除 prepared 之外的文件，以及上次安装换下来的旧包。
    func removeLeftovers(keeping prepared: PreparedUpdate?, staleStagingPath: String?) async
}

// [Core] Updates/ReleaseFeedParser.swift、Updates/ChecksumList.swift、Updates/UpdateAssetContract.swift（WP-3）
public enum ReleaseFeedParser {
    public static let maxFeedBytes = 1_048_576
    public static func parse(_ data: Data, feed: UpdateFeed) throws(UpdateError) -> ReleaseInfo
    /// 判断一次答复是不是限流，并给出可以再试的时刻。headers 的键已转成小写。
    public static func rateLimit(status: Int, headers: [String: String], now: Date) -> ReleaseFetchResult?
}
public enum UpdateAssetContract {
    public static let checksumsName = "SHA256SUMS.txt"
    public static let appBundleName = "EVE-O Preview.app"
    public static let maxImageBytes = 314_572_800
    public static let maxChecksumsBytes = 65_536
    public static func imageName(version: String) -> String    // EVE-O-Preview-<版本号>.dmg
    public static func assets(in release: ReleaseInfo, feed: UpdateFeed) throws(UpdateError) -> (image: ReleaseAsset, checksums: ReleaseAsset)
}
public enum ChecksumList {
    public static func parse(_ text: String) throws(UpdateError) -> [String: String]   // 文件名 → 小写十六进制
    public static func expectedHash(for fileName: String, in text: String) throws(UpdateError) -> String
}
```

请求（`ReleaseFeedClient`）：

- `GET https://api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest`，不带凭据。
- 请求头：`Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2022-11-28`、`User-Agent: EVE-O-Preview-macOS/<版本号>`、`Accept-Language: en`；有 ETag 且有缓存的发布信息时加 `If-None-Match`。
- `User-Agent` 与 `Accept-Language` 写在会话配置的 `httpAdditionalHeaders` 里。不写时 `URLSession` 会自己填：前者带系统与 CFNetwork 的版本，后者是系统的语言列表。`URLSession` 另外自己加 `Host`、`Accept-Encoding` 与 `Connection`。
- `URLSessionConfiguration.ephemeral`，`httpCookieStorage`、`urlCache` 设为 `nil`，`httpShouldSetCookies` 为假。请求超时 15 秒。答复正文超过 1 MiB 时按 `malformedFeed` 处理。

答复的处理：

| 答复 | 结果 | 写入 `state.updates` |
| --- | --- | --- |
| 200 | `ReleaseFeedParser.parse` 成功时是 `.release(info, etag:)`，失败时是 `.failed(.malformedFeed)` | 成功时写 `lastCheckAt`、`etag`、`cachedRelease`，清掉 `rateLimitedUntil` |
| 304 | `.notModified`，用 `cachedRelease` 继续判断 | `lastCheckAt` |
| 404 | `.noRelease`，按已是最新处理 | `lastCheckAt` |
| 403 或 429，且 `x-ratelimit-remaining` 是 `0` 或有 `retry-after` | `.rateLimited(until:)`。时刻取 `x-ratelimit-reset`（UNIX 秒）或「现在加 `retry-after` 秒」；两个头都没有时取现在加 3,600 秒 | `rateLimitedUntil` |
| 其他状态码 | `.failed(.httpStatus)` | 不写 |
| 网络错误、超时 | `.failed(.network)` | 不写 |

`ReleaseFeedParser.parse` 的规则：

- 顶层是 JSON 对象。取 `tag_name`、`name`、`body`、`html_url`、`draft`、`prerelease`、`published_at`、`assets[].name`、`assets[].browser_download_url`、`assets[].size`。
- `tag_name` 应能解析成 `SemanticVersion`，`ReleaseInfo.version` 取它的规范写法（不带 `v`）。解析不了时抛 `malformedFeed`。
- `html_url` 应通过 `feed.accepts`，否则抛 `malformedFeed`。
- 附件的地址不通过 `feed.accepts` 时丢掉这个附件。附件多于 100 个时只看前 100 个。
- `body` 超过 65,536 个字符时截短。缺失或为 `null` 时取空串。

`UpdateFeed` 的规则：

- `resolve(override:)`：`override` 为 `nil` 或空串时用正式地址，`isTestFeed` 为假。否则它应是 `https` 地址，或主机为 `127.0.0.1`、`localhost`、`::1` 的 `http` 地址；符合时用它，`isTestFeed` 为真。不符合时忽略它并用正式地址，App 记一条 `error` 日志。
- `accepts(_:)`：正式地址下，字符串应以 `https://github.com/deletexiumu/eve-o-preview-macos/releases/` 开头。测试地址下，它应与 `feedURL` 的协议、主机和端口都相同。

限流：未认证的请求每个 IP 每小时 60 次。应用每 24 小时自动检查一次，启动时的检查至少间隔 1 小时（8.5 节），一天最多约 24 次。304 答复是否计入额度没有核实（V24），设计不依赖它，ETag 只用来省流量。

### 8.5 调度

```swift
// [Core] Updates/UpdatePolicy.swift（WP-3）
public enum UpdateSkipReason: Sendable, Equatable { case notNewer, skippedByUser, prerelease, draft, unparsableVersion }
public enum UpdateOffer: Sendable, Equatable { case none(UpdateSkipReason); case offer(ReleaseInfo) }
public struct StagedAppInfo: Sendable, Equatable {
    public var bundleIdentifier: String?; public var version: String?; public var buildLabel: String?
    public var executableName: String?; public var minimumSystemVersion: String?
    public var hasCurrentArchitecture: Bool
}
public enum UpdatePolicy {
    public static let checkInterval = 86_400.0
    public static let minimumLaunchGap = 3_600.0
    public static func comparableVersion(of environment: AppEnvironment) -> SemanticVersion?
    public static func capability(for environment: AppEnvironment, isTestFeed: Bool) -> InstallCapability
    public static func offer(release: ReleaseInfo, running: AppEnvironment, skippedVersion: String?,
                             userInitiated: Bool) -> UpdateOffer
    public static func isCheckDue(now: Date, lastCheckAt: Date?, rateLimitedUntil: Date?, atLaunch: Bool) -> Bool
    /// 核对暂存目录里的新应用：bundle id、可执行文件名、版本号等于发布版本且比正在运行的新、系统版本够、含本机架构。
    public static func validate(staged: StagedAppInfo, releaseVersion: String, running: AppEnvironment,
                                systemVersion: String) throws(UpdateError)
}

// [App] Updates/UpdateController.swift（WP-0 骨架，WP-3 实现）
@MainActor @Observable final class UpdateController {
    private(set) var phase: UpdatePhase = .idle
    private(set) var capability: InstallCapability = .unavailable
    private(set) var lastCheckAt: Date?
    let feed: UpdateFeed
    let environment: AppEnvironment
    /// 请求显示更新窗口。参数为真表示用户点出来的，可以激活本应用。
    @ObservationIgnored var presentWindow: (@MainActor (_ userInitiated: Bool) -> Void)?
    init(coordinator: AppCoordinator, environment: AppEnvironment, state: StateController)
    func start()
    func checkNow(userInitiated: Bool)
    func install()                 // 下载、校验、安装并重新启动
    func cancel()
    func skipThisVersion()
    func remindLater()
    func openReleasePage()
    func restartToInstall()        // 自动安装已下载好时，由菜单项调用
    /// 退出前调用：自动安装已下载好时安装，不重新启动。最多等 timeout。
    func installOnQuitIfReady(timeout: Duration) async
}
```

- `UpdateController.start()`：读 `AppEnvironment` 算出 `capability`；`capability` 是 `.unavailable`（不是从 `.app` 运行）时什么都不做，菜单项置灰。否则调 `services.updates.removeLeftovers`，按下一条恢复状态，再启动一个循环：先等 10 秒，之后每小时醒一次；每次醒来时 `general.checkForUpdates` 为真且 `UpdatePolicy.isCheckDue` 为真就检查一次。
- 恢复状态不发请求，只读 `state.updates`。`prepared` 有值时核对三件事：dmg 文件还在；它的版本大于正在运行的版本；`cachedRelease` 的版本与它相同。都成立且「自动安装」打开时，`phase` 设为 `.readyToInstall` 并亮起 `.updateReady`；有一项不成立时清掉 `prepared` 并删掉文件。没有进入 `.readyToInstall` 时，对 `cachedRelease` 调 `UpdatePolicy.offer`（`userInitiated` 为假）：得到 `.offer` 就把 `phase` 设为 `.available` 并亮起 `.updateAvailable`，不弹窗口。这样 1 小时内重启后，圆点与菜单项仍在。
- `isCheckDue` 的规则，按顺序：`rateLimitedUntil` 晚于现在时返回假；`lastCheckAt` 为 `nil` 或晚于现在（时钟被调回）时返回真；`atLaunch` 为真时看是否已过 3,600 秒，否则看是否已过 86,400 秒。只有循环的第一次醒来算 `atLaunch`。
- 检查失败（网络错误、状态码错误）不写 `lastCheckAt`，下一次醒来时重试，所以断网期间每小时试一次。
- 用户点「检查更新…」或「立即检查」时不看间隔。`rateLimitedUntil` 晚于现在时不发请求，窗口直接显示限流的说明与可以再试的时刻。
- `general.checkForUpdates` 从假变真时（`updateSettingsDidChange`）立即按 `atLaunch` 为假判断一次。
- 演示模式（`EVEO_FAKE=1`）用 `FakeUpdateService`，不发任何请求。

### 8.6 决策与提示

`UpdatePolicy.offer` 的规则，按顺序取第一个成立的：

| 条件 | 结果 |
| --- | --- |
| `release.isDraft` | `.none(.draft)` |
| `release.isPrerelease`，或版本号带预发布标识 | `.none(.prerelease)` |
| 发布的版本或正在运行的版本解析不了 | `.none(.unparsableVersion)` |
| 发布的版本不大于正在运行的版本 | `.none(.notNewer)` |
| `skippedVersion` 等于发布的版本，且 `userInitiated` 为假 | `.none(.skippedByUser)` |
| 其他 | `.offer(release)` |

得到 `.offer` 之后：

| 情况 | 行为 |
| --- | --- |
| 用户发起的检查 | `phase` 变成 `.available`，调 `presentWindow(true)` |
| 自动检查，且「自动安装」打开、`capability` 是 `.canInstall`、这个版本没有安装失败的记录 | 不显示窗口，按 9.5 节在后台下载 |
| 其他自动检查 | `phase` 变成 `.available`，`setAttention(.updateAvailable, on: true)`，调 `presentWindow(false)`（经 `DeferredPresenter`，4.5 节） |

得到 `.none` 之后：用户发起的检查显示「已是最新版本」；自动检查不显示任何东西，并清掉 `.updateAvailable` 的圆点。

更新窗口（`UpdateWindowController`，宽 560 点、高 480 点）：

- 标题行：`EVE-O Preview <新版本> 可用`；下一行：当前版本。使用测试地址时旁边有「测试地址」字样。
- 中部：发布说明（8.7 节），可滚动。
- `capability` 是 `.canInstall` 时，按钮是「跳过此版本」「稍后」「安装更新」，下方一行说明安装后应用会重新启动。
- `capability` 是 `.notifyOnly` 时，「安装更新」换成「打开发布页」，并在发布说明上方显示不能自动安装的原因（9.1 节）。
- 下载、核对、安装期间：按钮区换成进度条与「取消」（安装开始后「取消」不可用）。
- 失败时：显示错误说明与「当前版本没有变化」，按钮是「重试」「打开发布页」「关闭」。

三个按钮的含义：

| 按钮 | 行为 |
| --- | --- |
| 安装更新 | 9.2、9.3 节，成功后重新启动 |
| 跳过此版本 | 把版本号写进 `state.updates.skippedVersion`，关窗口，清掉圆点。自动检查不再提示这个版本；有更新的版本时照常提示；用户发起的检查仍会显示它 |
| 稍后 | 关窗口，圆点与菜单项「有可用更新：<版本>…」保留，重启后仍在（8.5 节）。下一次自动检查完成时再弹一次窗口，最晚在 24 小时后 |

### 8.7 发布说明的显示

```swift
// [Core] Updates/ReleaseNotes.swift（WP-4）
public enum ReleaseNotesBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(number: Int, text: String)
    case code(String)
}
public enum ReleaseNotes {
    /// 按 8.2 节的约定取出一种语言的正文。
    public static func section(for language: AppLanguage, in body: String) -> String
    public static func blocks(from markdown: String) -> [ReleaseNotesBlock]
}
```

SwiftUI 的 `Text` 只渲染行内 Markdown，不渲染标题与列表。`ReleaseNotes.blocks(from:)` 把取出的那段文字按行切成块，由 `ReleaseNotesView` 逐块显示：

| 行的形式 | 块 |
| --- | --- |
| 以 1～6 个 `#` 加空格开头 | `heading` |
| 以 `-`、`*` 或 `+` 加空格开头，前面有 0 个或多个空格 | `bullet`，每 2 个空格算一级 |
| 以数字加 `.` 加空格开头 | `numbered` |
| 三个反引号围起来的各行 | `code` |
| 空行 | 结束当前段落 |
| 其他 | 并入当前 `paragraph`，行与行之间加一个空格 |

- 块里的文字用 `AttributedString(markdown:options:)`（`inlineOnlyPreservingWhitespace`）渲染粗体、行内代码和链接。解析失败时按纯文本显示。
- 链接只在协议是 `https` 时可点，点击后用默认浏览器打开。
- 剩下的 HTML 标签按纯文本显示，不解释。不加载图片。
- 发布说明里宜只用标题、列表、段落、行内代码和链接。主会话写说明时按这个范围写。

### 8.8 跨版本的发布说明（1.1.4）

用户跳过了几个版本时（如正在运行 1.1.1、最新是 1.1.3），更新窗口在最新版的说明之后列出中间各版本（1.1.2）的说明，新版在前，每段前是版本小标题（「版本 1.1.3」），段间有分隔线。只有最新版一段时与以前一样，没有小标题。每段都按 8.2 节的规则取界面语言的块。

```swift
// [Core] Updates/ReleaseHistory.swift
public struct ReleaseNotesEntry { var version: String; var notes: String }
public struct ReleaseHistoryPage { var entries: [ReleaseNotesEntry]; var isFull: Bool }
public struct IntermediateReleaseNotes { var latestVersion, runningVersion: String; var entries: [ReleaseNotesEntry]; var hasMore: Bool }
public enum ReleaseHistory {
    static func parse(_ data: Data) throws(UpdateError) -> ReleaseHistoryPage
    static func intermediate(from:running:latest:) -> [ReleaseNotesEntry]
    static func record(from:running:latest:) -> IntermediateReleaseNotes
}
// [Core] UpdateFeed.historyURL；UpdateService.fetchReleaseHistory(feed:appVersion:) -> ReleaseHistoryPage?
```

- 检查本身不变，仍只请求 `releases/latest`。有新版本要提示时（`UpdatePolicy.offer` 得到 `.offer`），以及更新窗口显示某个版本时，`UpdateController.ensureIntermediateNotes(for:)` 在后台请求一次 Release 列表：正式地址是 `…/releases?per_page=100`（1.3.0 之前是 30）；测试地址把最后一段换成 `releases.json`（`make-update-test-feed.sh` 一起生成），地址没有 `.json` 文件名或带查询串时不取。
- 请求头与 8.4 节相同，不带 ETag，超时 15 秒，正文上限 2 MiB。尽力而为：非 200、限流、网络错误、解析失败都只记日志，窗口只显示最新版的说明；失败后 1 小时内不再试；`rateLimitedUntil` 在将来时不发。不写 `rateLimitedUntil`，不改阶段，检查、下载与安装都不等它。
- 列表解析跳过草稿、预发布与 tag 解析不了的项，正文截到 65,536 个字符。挑出「正在运行的版本 < v < 最新版」的版本，按版本号从新到旧排，最多 10 个、总共不超过 262,144 个字符（超出时留较新的）。一页满 30 项、却没有一项不比正在运行的版本新时，可能还有更早的中间版本，`hasMore` 为真。`hasMore` 为真时说明最后多一行「更早版本的更新内容请到发布页查看」。
- 结果存在 `state.updates.intermediateNotes`，只存中间版本。缓存是为同一个最新版取的、且取的时候正在运行的版本不比现在新时直接用，所以每个新的最新版最多多一次请求；启动时只读缓存，不发请求。显示前再按正在运行的版本过滤一次。测试地址留下的缓存与 `cachedRelease` 一起丢掉。这个字段解不出来时单独丢掉，不连累 `state.updates` 的其他记录。
- 同一时刻只有一个请求；要取的版本变了时取消旧的。请求回来时 `cachedRelease` 已不是这个版本，结果丢掉。正在运行的版本解析不了时不取。
- 1.1.3 及更早的版本没有这段代码，从它们更新到 1.1.4 的那一次仍只显示 1.1.4 的说明。不在服务器侧把历史说明并进最新版的正文：旧版本只取第一个语言块，也不知道用户从哪个版本来，并进去后隔一个版本的用户会看到不相干的内容。

## 9 安装更新

### 9.1 能否安装

`UpdatePolicy.capability(for:isTestFeed:)` 的规则，按顺序取第一个成立的：

| 条件 | 结果 | 窗口里的说明 |
| --- | --- | --- |
| `location` 是 `.notBundled` | `.unavailable` | 更新功能整个停用（`swift run`） |
| `signature.kind` 是 `.unsigned` 或 `.unknown` | `.notifyOnly(.unsigned)` | 这个构建没有签名 |
| `signature.kind` 是 `.adHoc` | `.notifyOnly(.adHocSignature)` | 这个构建没有稳定的签名，无法核对新版本 |
| `signature.kind` 是 `.development`，且 `isTestFeed` 为假 | `.notifyOnly(.developmentSignature)` | 这是本机签名的开发构建 |
| `location` 是 `.translocated` | `.notifyOnly(.translocated)` | 系统在临时的只读位置运行它；请把应用移到「应用程序」后重新打开 |
| `location` 是 `.readOnlyVolume` | `.notifyOnly(.readOnlyVolume)` | 应用在只读的磁盘上；请先拷贝到「应用程序」 |
| `isLocationWritable` 为假 | `.notifyOnly(.locationNotWritable)` | 当前用户没有权限改动应用所在的文件夹 |
| 其他 | `.canInstall` | |

各种构建的结果：

| 构建 | 签名 | 检查 | 安装 |
| --- | --- | --- | --- |
| tag 构建的正式版 | 发布证书 | 有 | 能 |
| 同仓库 PR 与 `main` 的 CI 构建 | 发布证书 | 有；标签小于正式版，正式版发布后会提示 | 能 |
| fork 的 PR 构建 | ad-hoc | 有 | 只提示 |
| 本机 `build-app.sh`，钥匙串里有 `EVEO Preview Dev` | 开发证书 | 有；标签等于版本号，同版本不提示 | 只提示；使用测试地址时能装（9.6 节） |
| 本机 `build-app.sh`，没有证书 | ad-hoc | 有 | 只提示 |
| 1.0.0 | 发布证书（第 19 节） | 没有更新功能 | 手动 |
| `swift run` | 无 | 无 | 无 |

只提示的路径只用到 8.4～8.6 节的代码和「打开发布页」，不经过下载与安装的代码。安装部分有缺陷时，这条路径仍然可用（R21）。

### 9.2 下载与核对

`UpdateService.prepare`（`UpdateDownloader`）的步骤：

1. 用 `UpdateAssetContract.assets(in:feed:)` 取 dmg 与 `SHA256SUMS.txt` 两个附件。缺任何一个时返回 `assetMissing`。
2. 附件声明的大小超过 300 MiB 时返回 `downloadTooLarge`。缓存所在卷的可用空间小于「附件大小的 3 倍」（大小未知时按 200 MiB）时返回 `insufficientDiskSpace`。
3. 清理缓存目录 `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` 里别的版本的文件，建 `Updates/<版本号>/`。
4. 下载 `SHA256SUMS.txt`，超过 65,536 字节时返回 `checksumListInvalid`。用 `ChecksumList.expectedHash(for:in:)` 取 dmg 的期望值。
5. 用 `URLSessionDownloadTask` 下载 dmg 到 `Updates/<版本号>/<文件名>.partial`。已收字节超过 300 MiB 时取消并返回 `downloadTooLarge`。进度回调每秒最多 10 次。
6. 在后台按 1 MiB 一块算 SHA-256（CryptoKit），与期望值比较（都转成小写）。不同时删掉文件，返回 `checksumMismatch`。
7. 把文件改名去掉 `.partial`，返回 `PreparedUpdate`。控制器把它写进 `state.updates.prepared`。

下载的规则：

- 会话的配置与 8.4 节相同，自己设的请求头只有 `User-Agent` 与 `Accept-Language: en`。请求超时 60 秒，整个下载最长 10 分钟。
- 重定向：只跟随到 `https` 地址。使用测试地址时，也允许跟随到与测试地址同源的 `http` 地址。GitHub 会把附件的下载重定向到它的文件存储域名，这个域名不固定，所以不核对重定向后的主机；来源由第 9.3 节的签名核对保证。
- `cancelPreparation()` 取消还没有完成的请求并删掉 `.partial` 文件，`prepare` 返回 `cancelled`。

`ChecksumList.parse` 的规则：

- 每行的形式是 64 位十六进制、分隔、文件名。分隔是两个空格（文本模式）或一个空格加 `*`（二进制模式）。
- 空行和以 `#` 开头的行跳过。行尾的回车去掉。
- 十六进制不区分大小写，结果转成小写。
- 文件名是分隔之后到行尾的全部内容，可以含空格。文件名里有 `/` 或 `\` 时这一行无效。
- 任何一行无效，或同一个文件名出现两个不同的值，抛 `checksumListInvalid`。相同的重复行可以接受。
- `expectedHash` 按文件名完全相等查找，找不到时抛 `checksumEntryMissing`。

### 9.3 安装

`UpdateService.install`（`BundleInstaller`）的步骤。第 8 步之前的任何失败都不碰已安装的应用。

1. 重新算 `UpdatePolicy.capability`，不是 `.canInstall` 时返回 `blocked`。重新算 dmg 的 SHA-256，与 `PreparedUpdate.sha256` 不同时返回 `checksumMismatch`。
2. 挂载：运行 `/usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -mountrandom <Updates/mnt> -plist <dmg>`（经 `ProcessRunner`，超时 120 秒）。从输出的属性列表里取 `system-entities` 中第一个 `mount-point`。失败时返回 `imageMountFailed`。从这一步起，不论成败都在结束前运行 `hdiutil detach <挂载点> -force`（超时 30 秒）。
3. 找 `<挂载点>/EVE-O Preview.app`。用 `lstat` 确认它是目录而不是符号链接，否则返回 `appMissingInImage`。
4. 建暂存目录：`FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: <已安装的包>, create: true)`，权限改成 0700。这个目录与已安装的包在同一个卷上，第 8 步的改名才是原子的。
5. 用 `FileManager.copyItem` 把应用复制到 `<暂存目录>/EVE-O Preview.app`，然后卸载 dmg。
6. 核对暂存目录里那份副本的签名，不核对 dmg 里的那一份。`SecStaticCodeCreateWithPath` 取静态代码；`SecRequirementCreateWithString` 把 `environment.signature.designatedRequirement` 编译成要求；再调 `SecStaticCodeCheckValidityWithErrors`。标志是 `kSecCSStrictValidate`、`kSecCSCheckAllArchitectures`、`kSecCSCheckNestedCode`。返回 -67050 时是 `requirementNotSatisfied`，其他非 0 值是 `signatureInvalid(status:)`。
7. 核对副本的 `Info.plist`：用 `PropertyListSerialization` 读成 `StagedAppInfo`，交给 `UpdatePolicy.validate`。它依次核对：bundle id 与可执行文件名和正在运行的应用相同（`bundleMismatch`）；`CFBundleShortVersionString` 等于发布的版本（`versionMismatch`）；副本的标签（没有时取版本号）大于正在运行的版本（`notNewer`）；`LSMinimumSystemVersion` 不高于当前系统（`unsupportedSystem`）；可执行文件含本机架构（`bundleMismatch`）。架构用 `Bundle(url:)?.executableArchitectures` 读。
8. 副本上有 `com.apple.quarantine` 扩展属性时删掉它（递归，属性不存在不算错）。
9. 替换：`renamex_np(<暂存的副本>, <已安装的包>, RENAME_SWAP)`。成功后，已安装的路径下是新版本，暂存目录里是旧版本。
10. 对已安装的路径再做一次第 6 步的核对。失败时再调一次 `renamex_np` 换回来，返回 `signatureInvalid`。
11. 把已安装的包的修改时间设为现在，并调 `LSRegisterURL(_, true)`，让系统重新登记它。这一步失败只记日志。
12. 返回 `InstallOutcome`。控制器清掉 `state.updates.prepared`，写 `lastInstall`（成功）与 `staleStagingPath`，删掉 dmg。

第 9 步的后备：`renamex_np` 返回 `ENOTSUP` 或 `EINVAL` 时，文件系统不支持交换，改为两次改名。先把已安装的包改名到 `<暂存目录>/previous.app`，再把副本改名到已安装的路径。第二次失败时把旧包改名回去。改回去也失败时返回 `swapFailed`，并在 `fault` 日志里写明旧包所在的路径。

为什么先复制再核对：dmg 挂载后，从核对到复制之间内容可能被换掉。核对将要安装的那一份，就没有这个间隙。暂存目录的权限是 0700，别的用户改不了它。

为什么在进程自己运行时替换：替换只是改名，旧的可执行文件仍然开着，已经映射进内存的代码不受影响。应用没有资源包，运行中不会再去读包里的文件。旧包留在暂存目录里，下次启动时由 `removeLeftovers` 删除（V22、R25）。

`removeLeftovers` 的规则：

- `Updates/mnt/` 下还有挂载点时逐个 `hdiutil detach -force`。
- 删掉 `Updates/` 下除 `prepared.imagePath` 以外的文件。
- `staleStagingPath` 只在同时满足以下条件时删除：路径里有 `/TemporaryItems/`；它是目录；里面只有一个条目，名字是 `EVE-O Preview.app` 或 `previous.app`。不满足时不删，只清掉记录并写一条日志。

安装成功后的重新启动（用户发起的安装）：`phase` 变成 `.relaunching`，调 `coordinator.services.permissions.relaunch()`（U12）。新实例等旧实例退出后启动，路径不变，运行的是新版本。新实例启动时看到 `lastInstall.succeeded` 为真且版本与自己相同，写一条 `info` 日志；版本不同时写一条 `error` 日志。

### 9.4 失败处理

| 阶段 | 失败 | 已安装的应用 | 清理 | 界面 |
| --- | --- | --- | --- | --- |
| 检查 | 网络、状态码、限流、内容解析不了 | 不变 | 无 | 用户发起时显示说明；自动检查只记日志 |
| 下载 | 网络中断、取消、超过上限、磁盘空间不足 | 不变 | 删 `.partial` 文件 | 错误说明、「重试」「打开发布页」 |
| 核对 | 校验和文件无效、缺 dmg 那一行、SHA-256 不同 | 不变 | 删下载的文件 | 同上 |
| 挂载与复制 | `hdiutil` 失败或超时、卷里没有应用、复制失败 | 不变 | 卸载、删暂存目录 | 同上 |
| 验证 | 签名无效、不满足指定要求、版本或 bundle id 不符、系统版本不够 | 不变 | 卸载、删暂存目录、删 dmg | 同上，不提供「重试」以外的绕过办法 |
| 替换 | `renamex_np` 与后备都失败 | 不变（改名失败时什么都没动），或已换回 | 删暂存目录 | 同上 |
| 替换后的复核 | 新包核对失败 | 已换回旧版本 | 删暂存目录 | 同上 |
| 重新启动 | 新实例没有启动 | 已是新版本 | 无 | 旧实例继续运行，窗口提示手动重新打开应用 |

每次失败都写一条 `error` 日志（含 `UpdateError` 的名称），并把 `lastInstall` 记为失败。验证阶段的失败另写一条 `fault` 日志，含 `SecStaticCodeCheckValidityWithErrors` 的返回值。

### 9.5 自动安装

`general.autoInstallUpdates` 默认是假。打开后的行为：

1. 自动检查得到 `.offer`，且 8.6 节的三个条件都成立时，在后台运行 9.2 节的下载与核对，不显示窗口。
2. 成功后 `phase` 变成 `.readyToInstall`，`setAttention(.updateReady, on: true)`，菜单顶部出现「重新启动以更新到 <版本>」。
3. 下载或核对失败时记日志，退回 8.6 节的普通提示（`.available`、圆点、推迟的窗口）。

安装只在两个时刻发生：

| 时刻 | 做法 | 是否重新启动 |
| --- | --- | --- |
| 用户点「重新启动以更新到 <版本>」 | `restartToInstall()`：运行 9.3 节，成功后重新启动 | 是，由用户发起 |
| 用户退出应用（含注销与关机） | `installOnQuitIfReady(timeout:)`：协调器停止后运行 9.3 节，最多等 8 秒 | 否 |

应用不在别的时刻安装，也不自行重新启动：重新启动会让缩略图和热键中断几秒，用户可能正在战斗。

`installOnQuitIfReady` 的条件，全部成立才安装：`checkForUpdates` 与 `autoInstallUpdates` 都为真；`state.updates.prepared` 有值且版本大于正在运行的版本；`capability` 是 `.canInstall`；`lastInstall` 没有记这个版本失败过；此刻没有同 bundle id 的另一个实例在运行（「重新启动」的交接期间不安装，新实例已经从旧包启动了）。
8 秒内没有完成时不再等待，进程照常退出。替换那一步是原子的，被打断时已安装的应用要么是旧版本，要么是新版本。没有做完的暂存目录由下次启动的 `removeLeftovers` 清理。
某个版本安装失败后，自动安装不再试这个版本，改为普通提示，由用户决定重试还是手动下载。

### 9.6 测试入口

环境变量 `EVEO_UPDATE_FEED_URL` 把检查的地址换成本地 HTTP 服务（规则见 8.4 节的 `UpdateFeed.resolve`）。设了它且通过校验时：

- 检查请求发给这个地址。它返回的 JSON 与 GitHub 的单个 Release 对象同形，附件地址与它同源。
- `signature.kind` 是 `.development` 的构建可以安装（9.1 节）。ad-hoc 与未签名的构建仍然只提示。
- 签名核对不放宽：新应用仍应满足正在运行的应用的指定要求（9.3 节第 6 步），所以两个构建应由同一张证书签名。
- 启动时写一条 `notice` 日志，更新窗口显示「测试地址」字样。
- `relaunch()` 会把 `EVEO_*` 变量转发给新实例（U12），安装后的新实例仍然使用测试地址。

`EVEOProbe` 增加 3 个命令，供 WP-3 在不运行应用的情况下核对平台代码：

| 命令 | 作用 |
| --- | --- |
| `EVEOProbe update feed [地址]` | 请求并解析发布信息，打印版本、附件与 `UpdatePolicy.offer` 的结果 |
| `EVEOProbe update verify <新应用> <基准应用>` | 读基准应用的指定要求，对新应用做 9.3 节第 6 步的核对，打印返回值 |
| `EVEOProbe update prepare <地址>` | 运行 9.2 节的下载与核对，打印 dmg 的位置与 SHA-256 |

端到端的手工步骤在 14.2 节第 5 组。

## 10 隐私与安全

### 10.1 网络请求

1.0.0 不发任何网络请求。1.1.0 起应用只在以下情况联网，对象只有 GitHub：

| 请求 | 何时 | 发送的内容 |
| --- | --- | --- |
| `GET api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest` | 「自动检查更新」打开时，启动后与每 24 小时；用户点「检查更新…」时 | 请求头 `User-Agent: EVE-O-Preview-macOS/<版本号>`、`Accept`、`X-GitHub-Api-Version`、`Accept-Language: en`、`If-None-Match`（上次答复的 ETag），以及 `URLSession` 自己加的 `Host`、`Accept-Encoding`、`Connection` |
| `GET api.github.com/repos/deletexiumu/eve-o-preview-macos/releases?per_page=100` | 有新版本要提示、且还没有为这个版本取过时（8.8 节），每个新版本一般只一次 | 与上一行相同，不带 `If-None-Match` |
| 下载 `SHA256SUMS.txt` 与 dmg（`github.com`，重定向到 GitHub 的文件存储） | 用户点「安装更新」时；「自动安装」打开且发现新版本时 | 请求头 `User-Agent`、`Accept-Language: en`，以及 `URLSession` 自己加的那 3 个 |

- 不发送：角色名、配置、日志、硬件信息、系统版本、任何设备或安装的标识符。不用 cookie，不留缓存。
- GitHub 能看到的是 IP 地址、请求时刻和上表的请求头。这些请求头里随用户变化的只有应用的版本号与 ETag。`Accept-Language` 固定写 `en`，不带系统的语言列表；`User-Agent` 不带系统版本。实际发出的请求头由 14.2 节第 5 组第 11 项核对。
- 关掉「自动检查更新」后，应用不再自己联网；用户点「检查更新…」时仍会请求一次。
- 「报告问题」不联网。它只在本机生成 zip，并让浏览器打开一个 GitHub 地址；地址里的内容是用户在窗口里看到的环境摘要。是否提交、是否附上 zip 由用户在浏览器里决定。
- 没有遥测，没有崩溃自动上报。

「关于」页的说明加一句同样意思的话（`SettingsStrings.networkText`，11.4 节）。5 份 README 的免责声明与新增的隐私一节同步写明（第 15 节）。

### 10.2 本机留下的数据

| 位置 | 内容 | 上限 |
| --- | --- | --- |
| `~/Library/Logs/EVE-O Preview/` | 应用日志。私有值已写成 `<private>`，路径里可能有用户名（U3） | 约 5 MiB |
| `~/Library/Application Support/EVE-O Preview/session.json`、`state.json` | 会话标记；更新与诊断的记录 | 各几 KB |
| `~/Library/Application Support/EVE-O Preview/Reports/` | 用户生成的报告 zip，已脱敏 | 最新的 3 个 |
| `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` | 下载的 dmg 与校验和文件 | 安装后删除 |

README 的卸载说明应列出这 4 个位置。

### 10.3 威胁与对策

| 威胁 | 对策 |
| --- | --- |
| 下载内容在传输中被换掉 | 全程 `https`；SHA-256 核对；签名核对 |
| GitHub 账号或 Release 被人改动，放上恶意的 dmg 和配套的 `SHA256SUMS.txt` | 校验和只证明完整，不证明来源。新应用应满足正在运行的应用的指定要求，没有发布证书私钥的人做不出这样的应用（U6） |
| 拿一个真实但更旧的版本冒充更新（重放） | 副本的版本号应等于发布的版本，且大于正在运行的版本（9.3 节第 7 步） |
| 核对之后、安装之前文件被换掉 | 核对的是暂存目录里将要安装的那一份；暂存目录权限 0700；替换后再核对一次 |
| dmg 里放符号链接或别的 bundle id 的应用 | `lstat` 检查；bundle id 与可执行文件名的核对 |
| 发布信息里的地址指向别的主机 | `UpdateFeed.accepts` 只接受本仓库 Release 路径下的地址；发布说明里的链接只允许 `https`，并且只在用户点击时打开 |
| 发布说明里夹带脚本或远程图片 | 按纯文本与有限的 Markdown 显示，不用 WebView，不加载任何远程资源 |
| 用环境变量把更新指向恶意服务 | 能改应用环境变量的人已经能直接运行任意程序；即便如此，签名核对照常生效，ad-hoc 构建仍不能安装 |
| 超大的答复或下载耗尽内存与磁盘 | 发布信息 1 MiB、校验和文件 65,536 字节、dmg 300 MiB 的上限；磁盘空间预检 |
| 诊断包泄露用户名、主机名、角色名 | 7.3 节的脱敏；用户自起的名字不进 `ConfigSummary`；生成前可预览全文 |
| 日志伪造（文字里带换行冒充新的一行） | 换行写成 `\n`（5.2 节） |
| 发布证书的私钥丢失或泄露 | 见 R18、R19 |

更新后的应用不带隔离属性，不经过 Gatekeeper 的首次打开检查。这是有意的：应用没有公证，Gatekeeper 的检查通不过；来源由上面的签名核对保证。

## 11 界面与文字

### 11.1 菜单栏菜单

`StatusItemController.menuNeedsUpdate` 的顺序（新增的项标「新」）：

1. 客户端数量、演示模式提示（现有）。
2. 新：提示项，有才显示。「EVE-O Preview 上次意外退出 — 报告…」（`crashPending`）；「重新启动以更新到 <版本>」（`updateReady`）；「有可用更新：<版本>…」（`updateAvailable`）。
3. 权限提示、恢复捕获（现有）。
4. 显示或隐藏全部缩略图、配置方案、全部最小化、热键只在 EVE 内生效（现有）。
5. 分隔线，新：「检查更新…」「报告问题…」。
6. 分隔线，设置、退出（现有）。

- 第 2 组由 `updateAttentionItems()` 与 `diagnosticsAttentionItems()` 返回，第 5 组由 `updateMenuItems()` 与 `diagnosticsMenuItems()` 返回。这 4 个方法定义在 `StatusItemController+Updates.swift` 与 `StatusItemController+Diagnostics.swift`，WP-0 先写成返回空数组。
- `StatusItemController.coordinator` 的访问级别从 `private` 改成内部可见，扩展文件才能读它。
- `capability` 是 `.unavailable` 时「检查更新…」置灰。
- 圆点：`coordinator.attention` 不为空时，`StatusBarIcon.make(attention: true)` 在图标右上角画一个直径 5 点的实心圆。`onAttentionChanged` 触发时重设 `button.image`。

### 11.2 设置窗口

「通用」页在语言一组之后加两组，页数仍是 8：

| 组 | 内容 | 所在文件 |
| --- | --- | --- |
| 更新 | 「自动检查更新」开关与说明；「自动安装更新」开关与说明（`capability` 不是 `.canInstall` 或上一个开关关闭时置灰，并显示原因）；当前版本；上次检查的时刻；状态行；「立即检查」按钮 | `Settings/UpdateSettingsSection.swift` |
| 诊断 | 「详细日志」开关与说明；日志文件的位置与「在访达中显示日志」按钮；「报告问题…」按钮 | `Settings/DiagnosticsSettingsSection.swift` |

`GeneralPage` 只加两行 `UpdateSettingsSection(model: model)` 与 `DiagnosticsSettingsSection(model: model)`。两个视图经 `model.coordinator.updates`、`model.coordinator.problemReport` 取控制器；`UpdateController` 是 `@Observable`，状态变化时视图自己刷新。
「关于」页在免责声明一组里加一行 `L10n.settings.networkText`。

### 11.3 词表

在反馈文档 5.5 节的基础上增加。`ru`、`ja`、`ko` 三列由机器生成，待母语者审校；菜单项「检查更新…」取 macOS 在该语言下的通行说法。

| 英文 | 中文 | 俄文 | 日文 | 韩文 |
| --- | --- | --- | --- | --- |
| update | 更新 | обновление | アップデート | 업데이트 |
| Check for Updates… | 检查更新… | Проверить наличие обновлений… | アップデートを確認… | 업데이트 확인… |
| release notes | 发布说明 | примечания к выпуску | リリースノート | 릴리스 노트 |
| Install Update | 安装更新 | Установить обновление | アップデートをインストール | 업데이트 설치 |
| Skip This Version | 跳过此版本 | Пропустить эту версию | このバージョンをスキップ | 이 버전 건너뛰기 |
| Later | 稍后 | Позже | あとで | 나중에 |
| Report a Problem… | 报告问题… | Сообщить о проблеме… | 問題を報告… | 문제 신고… |
| report（诊断包） | 报告 | отчёт | レポート | 보고서 |
| crash report | 崩溃报告 | отчёт о сбое | クラッシュレポート | 충돌 보고서 |
| log | 日志 | журнал | ログ | 로그 |
| placeholder（脱敏） | 占位符 | заполнитель | プレースホルダ | 자리 표시자 |
| signature | 签名 | подпись | 署名 | 서명 |

### 11.4 文字键

两个新域各一个协议，组织方式同反馈文档 5.3 节：协议文件里用 `extension L10n` 定义访问器，每种语言一个结构体。带参数的写成函数，下表用 `name(参数)` 表示。英文原文按下表写，其余 4 种语言由工作包翻译。

`UpdateStrings`（`L10n.updates`，WP-4）：

| 键 | 英文 | 用在哪里 |
| --- | --- | --- |
| `menuCheckForUpdates` | Check for Updates… | 菜单 |
| `menuUpdateAvailable(version)` | Update Available: 1.1.1… | 菜单提示项 |
| `menuRestartToUpdate(version)` | Restart to Update to 1.1.1 | 菜单提示项 |
| `sectionHeader` | Updates | 「通用」页 |
| `autoCheckToggle` | Check for updates automatically | 「通用」页 |
| `autoCheckHelp` | Contacts GitHub once a day. No personal data is sent. | 「通用」页 |
| `autoInstallToggle` | Install updates automatically | 「通用」页 |
| `autoInstallHelp` | Downloads in the background and installs when you quit EVE-O Preview. | 「通用」页 |
| `currentVersionLabel` | Current version | 「通用」页 |
| `lastCheckedLabel` | Last checked | 「通用」页 |
| `lastCheckedNever` | Never | 「通用」页 |
| `checkNowButton` | Check Now | 「通用」页 |
| `statusChecking` | Checking… | 「通用」页、窗口 |
| `statusUpToDate` | EVE-O Preview is up to date. | 「通用」页、窗口 |
| `statusAvailable(version)` | Version 1.1.1 is available. | 「通用」页 |
| `statusReady(version)` | Version 1.1.1 is downloaded and will be installed when you quit. | 「通用」页 |
| `statusRateLimited(time)` | GitHub is limiting requests. Try again after 14:05. | 「通用」页、窗口 |
| `statusUnavailable` | Updates are not available in this build. | 「通用」页 |
| `windowTitle` | Software Update | 窗口标题 |
| `headline(version)` | EVE-O Preview 1.1.1 is available | 窗口 |
| `currentVersionLine(version)` | You have 1.1.0. | 窗口 |
| `releaseNotesHeader` | What's New | 窗口 |
| `installButton` | Install Update | 窗口 |
| `installHelp` | The app restarts after installing. Thumbnails disappear for a few seconds. | 窗口 |
| `skipButton` | Skip This Version | 窗口 |
| `laterButton` | Later | 窗口 |
| `openReleasePageButton` | Open Release Page | 窗口 |
| `cancelButton` | Cancel | 窗口 |
| `closeButton` | Close | 窗口 |
| `retryButton` | Try Again | 窗口 |
| `progressDownloading(received, total)` | Downloading… 1.2 MB of 2.6 MB | 窗口 |
| `progressVerifying` | Verifying… | 窗口 |
| `progressInstalling` | Installing… | 窗口 |
| `progressRelaunching` | Restarting… | 窗口 |
| `testFeedBadge` | Test feed | 窗口 |
| `notifyOnlyIntro` | This copy can't update itself. | 窗口 |
| `currentVersionUnchanged` | Your current version is unchanged. | 窗口（失败时） |
| `reopenManually` | The update is installed. Quit and open EVE-O Preview again. | 窗口（重新启动失败时） |
| `blocker(blocker)` | 见下表 | 窗口、「通用」页 |
| `error(error)` | 见下表 | 窗口 |

`blocker(_:)` 按 `InstallBlocker` 返回：

| 取值 | 英文 |
| --- | --- |
| `translocated` | macOS is running the app from a temporary read-only location. Move it to the Applications folder, then open it again. |
| `readOnlyVolume` | The app is on a read-only disk. Copy it to the Applications folder first. |
| `locationNotWritable` | You don't have permission to change the folder that contains the app. |
| `adHocSignature` | This build has no stable signature, so a new version can't be verified against it. |
| `developmentSignature` | This is a locally signed development build. |
| `unsigned` | This build isn't signed. |

`error(_:)` 按 `UpdateError` 返回（`cancelled` 不显示）：

| `UpdateError` | 英文 |
| --- | --- |
| `network` | Couldn't reach GitHub. Check your internet connection. |
| `httpStatus` | GitHub answered with an error (503). |
| `rateLimited` | 用 `statusRateLimited`；时刻未知时：GitHub is limiting requests. Try again later. |
| `malformedFeed` | The release information couldn't be read. |
| `assetMissing` | This release has no installer for automatic updates. |
| `insufficientDiskSpace`、`downloadTooLarge` | There isn't enough free disk space for the download. |
| `checksumListInvalid`、`checksumEntryMissing`、`checksumMismatch` | The download doesn't match its checksum and was discarded. |
| `imageMountFailed`、`appMissingInImage` | The downloaded disk image couldn't be opened. |
| `signatureInvalid`、`requirementNotSatisfied`、`bundleMismatch`、`versionMismatch`、`notNewer` | The new version couldn't be verified, so it wasn't installed. |
| `unsupportedSystem` | This version requires macOS 15.0 or later. |
| `blocked` | 用 `blocker(_:)` |
| `swapFailed` | The app couldn't be replaced. |

`DiagnosticsStrings`（`L10n.diagnostics`，WP-2）：

| 键 | 英文 | 用在哪里 |
| --- | --- | --- |
| `menuReportProblem` | Report a Problem… | 菜单 |
| `menuCrashPending` | EVE-O Preview quit unexpectedly — Report… | 菜单提示项 |
| `sectionHeader` | Diagnostics | 「通用」页 |
| `verboseLoggingToggle` | Verbose logging | 「通用」页 |
| `verboseLoggingHelp` | Writes more detail to the log file. Turn it on before you reproduce a problem. | 「通用」页 |
| `logLocationLabel` | Log files | 「通用」页 |
| `showLogsButton` | Show Logs in Finder | 「通用」页 |
| `reportButton` | Report a Problem… | 「通用」页 |
| `windowTitle` | Report a Problem | 窗口标题 |
| `intro` | This creates a zip file with the items below. Nothing is sent automatically: you attach the file to a GitHub issue yourself. | 窗口 |
| `crashIntro` | EVE-O Preview quit unexpectedly last time. A report helps to fix the cause. | 窗口（崩溃情境） |
| `redactionNote` | Your macOS user name, computer name and EVE character names are replaced with placeholders. | 窗口 |
| `itemsHeader` | Included in the report | 窗口 |
| `itemSummary` | Environment summary | 窗口 |
| `itemConfig` | Settings summary (no names) | 窗口 |
| `itemLog` | App log | 窗口 |
| `itemCrash(number)` | Crash report 1 | 窗口 |
| `itemManifest` | File list | 窗口 |
| `previewTruncated` | Only the first part is shown. The report contains the whole file. | 窗口 |
| `replacements(count)` | 12 replacements | 窗口 |
| `collecting` | Collecting… | 窗口 |
| `createAndOpenButton` | Create Report and Open GitHub | 窗口 |
| `createOnlyButton` | Create Report Only | 窗口 |
| `cancelButton` | Cancel | 窗口 |
| `notNowButton` | Not Now | 窗口（崩溃情境） |
| `dontReportButton` | Don't Report | 窗口（崩溃情境） |
| `doneTitle` | Report created | 完成页 |
| `doneHelp` | Finder shows the zip file. Drag it into the issue page in your browser, describe what happened, then submit. | 完成页 |
| `revealButton` | Show in Finder | 完成页 |
| `openIssueButton` | Open GitHub Again | 完成页 |
| `closeButton` | Close | 完成页 |
| `createFailed(reason)` | The report couldn't be created: … | 窗口 |

`SettingsStrings` 增加 1 条（WP-0，5 种语言都由 WP-0 写）：

| 键 | 英文 | 中文 |
| --- | --- | --- |
| `networkText` | EVE-O Preview contacts GitHub only to check for and download updates; you can turn this off under General. Problem reports are never sent automatically. | EVE-O Preview 只在检查和下载更新时访问 GitHub，可在「通用」页关闭。问题报告不会自动发送。 |

文件大小的显示用 `ByteCountFormatter`，时刻用 `Date.FormatStyle`，都跟随界面语言对应的 `Locale`，不另设文字键。
译文的标注办法同反馈文档 5.2 节：`ru`、`ja`、`ko` 的文件头注明「译文由机器生成，待母语者审校」。

## 12 文件计划

路径相对于 `app/`。归属写「WP-0 → WP-n」的文件由 WP-0 建出签名齐全的骨架（方法体不做事或返回默认值，应用能照常运行），再由 WP-n 实现。没有列出的文件本轮不改；工作包发现要改表外的文件，或要改不属于自己的文件时，停下并报主会话。

`Sources/EVEOPreviewCore/`：

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `Model/AppConfig.swift`、`Config/ConfigValidator.swift` | 3.1 节 | WP-0 |
| `Model/AppEnvironment.swift` | 新建。4.2 节 | WP-0 |
| `Support/PromptGate.swift` | 新建。4.5 节 | WP-0 |
| `State/AppState.swift`、`State/JSONStateStore.swift` | 新建。3.3 节 | WP-0 |
| `Logging/LogLevel.swift`、`Logging/LogMessage.swift`、`Logging/LogRecord.swift`、`Logging/LogFileLayout.swift` | 新建。5.1、5.2 节 | WP-0 |
| `Logging/LogLineFormatter.swift`、`Logging/RotatingLogFile.swift`、`Logging/LogRateLimiter.swift` | 新建。5.2 节 | WP-1 |
| `Diagnostics/SessionModels.swift` | 新建。`SessionMarker`、`PreviousRunOutcome`、`CrashReportCandidate` | WP-0 |
| `Diagnostics/SessionMarkerRules.swift` | 新建。6.1 节 | WP-1 |
| `Diagnostics/CrashReportMatcher.swift` | 新建。6.2 节。WP-2 的手动报告也调 `select`，所以 WP-0 先建骨架（`select` 返回空数组） | WP-0 → WP-1 |
| `Contracts/DiagnosticsContracts.swift` | 新建。7.2 节的协议与类型 | WP-0 |
| `Diagnostics/Redactor.swift`、`Diagnostics/DiagnosticsSummary.swift`、`Diagnostics/IssueURLBuilder.swift` | 新建。7.2、7.3、7.5 节 | WP-2 |
| `Updates/UpdateModels.swift`、`Contracts/UpdateContracts.swift` | 新建。8.4 节的类型、协议与 `UpdateFeed`（含实现） | WP-0 |
| `Updates/SemanticVersion.swift`、`Updates/ReleaseFeedParser.swift`、`Updates/ChecksumList.swift`、`Updates/UpdateAssetContract.swift`、`Updates/UpdatePolicy.swift` | 新建。8.3～8.6、9.1、9.2 节 | WP-3 |
| `Updates/ReleaseNotes.swift` | 新建。8.2、8.7 节 | WP-4 |

`Tests/EVEOPreviewCoreTests/`：

| 文件 | 归属 |
| --- | --- |
| `ConfigCodableTests`、`ConfigValidatorTests`（补用例），`LogMessageTests`、`AppEnvironmentRulesTests`、`PromptGateTests`、`StateStoreTests`、`UpdateFeedTests`（新建） | WP-0 |
| `LogLineFormatterTests`、`RotatingLogFileTests`、`LogRateLimiterTests`、`SessionMarkerRulesTests`、`CrashReportMatcherTests`（新建） | WP-1 |
| `RedactorTests`、`DiagnosticsSummaryTests`、`IssueURLBuilderTests`（新建） | WP-2 |
| `SemanticVersionTests`、`ReleaseFeedParserTests`、`ChecksumListTests`、`UpdateAssetContractTests`、`UpdatePolicyTests`、`UpdateFixtures.swift`（新建） | WP-3 |
| `ReleaseNotesTests`（新建） | WP-4 |

`Sources/EVEOPreviewPlatform/` 与 `Sources/EVEOProbe/`：

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `PlatformServices.swift` | 加 `diagnostics`、`updates`；`PlatformLog` 搬走 | WP-0 |
| `Logging/LogChannel.swift` | 新建。`LogChannel`、`PlatformLog` | WP-0 |
| 含 `Logger(subsystem:` 声明的 13 个文件（U1） | WP-0 只换声明那一行。WP-1 可在这些文件里给日志语句补 `privacy:` 标注，不改别的 | WP-0 → WP-1 |
| `Logging/FileLogSink.swift` | 新建。5.2 节 | WP-1 |
| `Environment/AppEnvironmentProvider.swift`、`Support/ProcessRunner.swift` | 新建。4.2、4.3 节 | WP-0 |
| `Diagnostics/SystemDiagnosticsService.swift` | 新建。`DiagnosticsService` 的实现，只把各方法转给下面 3 个文件里的类型 | WP-0 |
| `Diagnostics/CrashReportLocator.swift` | 新建。列出与读取崩溃报告 | WP-0 → WP-1 |
| `Diagnostics/SystemInfoReader.swift`、`Diagnostics/ReportArchiver.swift` | 新建。`sysctl` 与用户名、主机名；写文件、`ditto`、访达与浏览器 | WP-0 → WP-2 |
| `Updates/SystemUpdateService.swift` | 新建。`UpdateService` 的实现 | WP-0 → WP-3 |
| `Updates/ReleaseFeedClient.swift`、`Updates/UpdateDownloader.swift`、`Updates/DiskImage.swift`、`Updates/CodeSignatureVerifier.swift`、`Updates/BundleInstaller.swift` | 新建。8.4、9.2、9.3 节 | WP-3 |
| `EVEOProbe/main.swift` | 加 `update` 命令的分发 | WP-0 |
| `EVEOProbe/UpdateProbe.swift` | 新建。9.6 节的 3 个命令 | WP-0 → WP-3 |

`Sources/EVEOPreview/`：

| 文件 | 改动 | 归属 |
| --- | --- | --- |
| `AppDelegate.swift`、`AppCoordinator.swift` | 4.4 节的接入点 | WP-0 |
| `Support/AppLog.swift` | 返回 `LogChannel` | WP-0 |
| `StateController.swift`、`Support/DeferredPresenter.swift` | 新建。4.4、4.5 节，WP-0 写完整 | WP-0 |
| `StatusItem/StatusItemController.swift`、`StatusItem/StatusBarIcon.swift` | 11.1 节的接入点与圆点 | WP-0 |
| `Settings/GeneralPage.swift`、`Settings/AboutPage.swift` | 11.2 节 | WP-0 |
| `Localization/SettingsStrings.swift`、`Localization/<语言>/Strings+<语言>.swift`（5 个） | 加 `networkText` | WP-0 |
| `Debug/FakeServices.swift` | 接入两个假服务 | WP-0 |
| `AppCoordinator+Diagnostics.swift` | 新建。`diagnosticsSettingsDidChange` | WP-0 → WP-1 |
| `Diagnostics/LogBootstrap.swift`、`Diagnostics/SessionTracker.swift` | 新建。5.2、5.5、6 节 | WP-0 → WP-1 |
| `Diagnostics/ProblemReportController.swift` | 新建。7.1 节 | WP-0 → WP-2 |
| `Diagnostics/ProblemReportBuilder.swift`、`Diagnostics/ProblemReportWindowController.swift`、`Diagnostics/ProblemReportView.swift` | 新建。7.1、7.4 节 | WP-2 |
| `Settings/DiagnosticsSettingsSection.swift`、`StatusItem/StatusItemController+Diagnostics.swift` | 新建。11.1、11.2 节 | WP-0 → WP-2 |
| `Localization/DiagnosticsStrings.swift`、`Localization/<语言>/DiagnosticsStrings+<语言>.swift`（5 个） | 新建 | WP-2 |
| `Debug/FakeDiagnosticsService.swift` | 新建 | WP-0 → WP-2 |
| `AppCoordinator+Updates.swift` | 新建。`updateSettingsDidChange` | WP-0 → WP-3 |
| `Updates/UpdateController.swift` | 新建。8.5、8.6、9.5 节 | WP-0 → WP-3 |
| `Updates/UpdateController+Install.swift` | 新建。下载、安装、退出时安装 | WP-3 |
| `Debug/FakeUpdateService.swift` | 新建 | WP-0 → WP-3 |
| `Updates/UpdateWindowController.swift` | 新建。`show(userInitiated:)` | WP-0 → WP-4 |
| `Updates/UpdateView.swift`、`Updates/ReleaseNotesView.swift` | 新建。8.6、8.7 节 | WP-4 |
| `Settings/UpdateSettingsSection.swift`、`StatusItem/StatusItemController+Updates.swift` | 新建。11.1、11.2 节 | WP-0 → WP-4 |
| `Localization/UpdateStrings.swift`、`Localization/<语言>/UpdateStrings+<语言>.swift`（5 个） | 新建 | WP-4 |

其他（都归主会话，13.3 节）：

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/macos.yml`、`macos/scripts/build-app.sh`、`macos/scripts/package-release.sh`、`macos/packaging/` | 签名、`Info.plist` 的两个新键、契约检查 |
| `.github/ISSUE_TEMPLATE/bug_report.md`、`.github/ISSUE_TEMPLATE/config.yml` | 新建。7.6 节 |
| `docs/`、5 份 README、`docs/release-notes/macos/v1.1.0.md` | 第 15 节 |

## 13 工作包与集成

### 13.1 WP-0：共用的模型、契约与接入点（先做）

目的：把几个工作包都要碰的文件一次改完，之后它们各自只改自己的文件。WP-0 做完后 `swift build` 与 `swift test` 通过，应用的行为与 1.0.0 相同，只有以下几处不同：日志经 `LogChannel` 写系统日志（还没有文件）；「通用」页多出两个空的组；「关于」页多一句联网说明。

1. Core：完成第 12 节归属写 WP-0 的文件及其测试；`CrashReportMatcher` 写成骨架。
2. Platform：`LogChannel` 与 `PlatformLog`；换掉 13 处声明；`AppEnvironmentProvider`、`ProcessRunner` 写完整；`SystemDiagnosticsService` 写完整，它转发到的 3 个类型写成骨架（`CrashReportLocator` 返回空数组，`SystemInfoReader` 返回空的 `SystemInfo`，`ReportArchiver` 抛 `archiveFailed`）；`SystemUpdateService` 写成骨架（`fetchLatestRelease` 返回 `.noRelease`，`prepare` 与 `install` 返回 `.failure(.cancelled)`）。
3. App：4.4 节的全部接入点；`StateController`、`DeferredPresenter` 写完整；其余控制器、视图与菜单方法按第 12 节写成骨架（视图是 `EmptyView`，菜单方法返回空数组）。
4. `UpdateController` 的骨架带一个界面调试入口：`EVEO_FAKE=1` 且设了 `EVEO_UPDATE_UI_STATE` 时，`start()` 把 `phase` 直接设成对应的样例值。取值是 `available`、`notifyonly`、`downloading`、`ready`、`failed`、`uptodate`。WP-4 靠它在 WP-3 完成之前做界面；WP-3 实现控制器时保留这个入口。
5. `SessionTracker` 的骨架同理：`EVEO_FAKE=1` 且 `EVEO_FAKE_CRASH=1` 时，`start()` 用一份样例 `PendingCrash` 调 `onCrashDetected`，供 WP-2 做崩溃情境的窗口。
6. 骨架里的签名以本文的片段为准。工作包要改签名时停下并报主会话。

### 13.2 并行的四个工作包

四个工作包各在自己的 git worktree 里做，基线是 WP-0 的提交。开工前核对基线：`docs/macos/design-v1.1.md` 与 `Sources/EVEOPreviewCore/Contracts/UpdateContracts.swift` 应存在，不存在说明 worktree 建在了旧的提交上。
任何两个工作包都不改同一个文件（第 12 节）。

| 工作包 | 内容 | 完成标准 |
| --- | --- | --- |
| WP-1 日志与异常退出 | 第 5、6 节。文件日志、轮转、限速、启动接入、级别设置；会话标记、信号处理、崩溃报告的匹配与扫描。先用一个临时的小程序制造一次崩溃，核对 `.ips` 的文件名与文件头（V17、V18），结果回报主会话 | `swift test` 通过，14.1 节相应的用例齐全；运行应用后日志文件出现并按大小轮转；14.2 节第 1、2 组可做 |
| WP-2 问题报告 | 第 7 节。脱敏、摘要、压缩包、Issue 地址、报告窗口、「通用」页的诊断一组、菜单项、诊断域的文字（5 种语言） | `swift test` 通过；`EVEO_FAKE=1` 下能预览并生成 zip，`EVEO_FAKE_CRASH=1` 下能看到崩溃情境；14.2 节第 3 组可做 |
| WP-3 更新引擎 | 第 8 节（8.2、8.7 除外）与第 9 节。Core 的规则、Platform 的请求、下载、挂载、验证与替换、`UpdateController`、探针。先做 `EVEOProbe update verify` 与 `update feed`，回报签名核对与 V26 的实测结果 | `swift test` 通过；探针的 3 个命令对本地 HTTP 服务通过；14.2 节第 4、5 组可做 |
| WP-4 更新界面 | 8.2、8.6、8.7 节与 11 节的更新部分。`ReleaseNotes`、更新窗口、「通用」页的更新一组、菜单项、更新域的文字（5 种语言） | `swift test` 通过；`EVEO_UPDATE_UI_STATE` 的 6 种取值在 5 种语言下都显示正常 |

对四个工作包的共同要求：

- 不执行 `git commit`，提交只由主会话做。
- 不留临时文件和调试脚本。
- 实现由工作包自己完成，不转派给别的代理或外部命令行工具。
- 不启动、不重启用户正在运行的应用，不发送模拟输入，不切换 EVE 窗口，不截屏。要运行应用才能核对的项目，写进回报，由主会话与用户约时间。
- 契约或本文要改时停下，报主会话；主会话改文档，再让文件的归属方改代码。
- 要写进 README 与 `docs/macos/manual-test-checklist.md` 的文字放在回报里，不直接改这些文件。
- 回报里附 `swift build`、`swift test` 与 `python3 scripts/check_quality.py` 的输出摘要。
- `ru`、`ja`、`ko` 的译文按反馈文档 5.2 节标注，用 11.3 节与反馈文档 5.5 节的词表。

### 13.3 主会话负责的部分

这些文件主会话正在改（签名），工作包不碰。本文对它们的要求：

1. `macos/scripts/build-app.sh` 把 `EVEOBuildLabel` 与 `EVEOBuildCommit` 写进 `Info.plist`。标签取环境变量 `LABEL`，没有时取 `VERSION`；提交取 `git rev-parse --short=7 HEAD`，取不到时不写。`package-release.sh` 与 CI 把 `LABEL` 传下去。没有这两个键时，PR 构建不会收到同版本号正式版的更新（8.3 节）。
2. CI 核对指定要求时接受 `certificate leaf = H"…"` 的写法（U5）。自签名证书只有一级，`leaf` 与 `root` 指同一张证书；也可以在签名时用 `--requirements` 显式写成 `certificate root`，两种做法里应用的核对都成立。
3. CI 在打包后核对 8.1 节的契约：附件名、dmg 顶层的 `EVE-O Preview.app` 是目录、`SHA256SUMS.txt` 有 dmg 那一行、`Info.plist` 的 5 个键。
4. CI 核对发布说明文件的标记成对出现（8.2 节）：每个 `<!-- lang:xx -->` 有对应的 `<!-- /lang:xx -->`，`en` 块存在。
5. 新建 7.6 节的两个 Issue 模板文件。
6. 第 15 节的文档更新。
7. 可选：`macos/scripts/make-update-test-feed.sh`，由 `dist/release/` 的内容生成 14.2 节第 5 组要用的 `feed.json`。
8. 发布手册里写明发布证书的备份办法与更换证书时的做法（R18）。

### 13.4 集成顺序

1. 主会话（或一个实现代理）完成 WP-0，运行 `swift build` 与 `swift test`，提交。
2. 四个工作包并行。WP-1 的 `.ips` 核实结果与 WP-3 的签名核实结果出来后，主会话先确认 6.2 节与 9.3 节是否要改。
3. 按 WP-1、WP-2、WP-3、WP-4 的顺序合入。文件不重叠，顺序只影响每一步之后的编译核对：每合入一个，运行一次 `swift build` 与 `swift test`。
4. 主会话更新文档，运行 `python3 scripts/check_quality.py` 与 `macos/scripts/build-app.sh`。
5. 按 14.2 节做手工验证。第 5 组要用户配合（要退出正在运行的应用）。
6. 用 `workflow_dispatch` 演练一次草稿 Release，核对附件与发布说明符合 8.1、8.2 节。
7. 交审查方独立审查。审查时核对：第 12 节的归属有没有被越界改动；9.3 节的 12 步是否逐步实现、顺序是否一致；`Core` 的测试是否覆盖 14.1 节；新文字文件的审校标注。

## 14 测试

### 14.1 Core 测试

用 swift-testing，只测 Core。涉及文件的用例用临时目录（做法同 `ConfigStoreTests`）。

| 测试文件 | 覆盖 |
| --- | --- |
| `ConfigCodableTests`（补） | 缺少 3 个新键的 1.0.0 文件解码后是默认值；键名与 3.1 节一致；`logLevel` 是不认识的值或类型不对时取 `info`；默认配置往返一致；1.1.0 写出的文件去掉 3 个新键后（模拟 1.0.0 保存过）再读，其余字段不变 |
| `ConfigValidatorTests`（补） | `logLevel` 是 `notice`、`error`、`fault` 时改回 `info` 并记入路径；`autoInstallUpdates` 为真、`checkForUpdates` 为假时不改 |
| `LogMessageTests` | 字面量与插值的分段；整数、浮点数、布尔值默认公开；字符串与其他类型默认私有；显式标注覆盖默认；`fixed(precision:)`；`rendered(includingPrivate:)` 两种结果；多行字符串 |
| `LogLineFormatterTests` | 时间格式（UTC、毫秒）；级别大写；换行与回车的转义；4,096 个字符的截断；一条记录只有一行 |
| `RotatingLogFileTests` | 目录不存在时创建；追加到已有文件；到上限时轮转且序号递增；超过 4 个旧文件时删最旧的；一行就超过上限时仍写入；权限 0600；`LogFileLayout.existingURLs` 的顺序 |
| `LogRateLimiterTests` | 容量内全部放行；桶空后丢弃；补充后第一条带丢弃计数；时间不前进时不补充 |
| `AppEnvironmentRulesTests` | `signatureKind` 表的 4 行；`locationKind` 表的 6 行，含转移运行的真实路径形式与 `~/Applications` |
| `PromptGateTests` | 3 种前台与是否用户发起的 6 种组合 |
| `StateStoreTests` | 文件不存在、损坏、`stateVersion` 是 2 时返回默认状态且不抛错；往返一致；日期是 ISO 8601 字符串；缺键取默认值；原子写入后文件完整 |
| `SessionMarkerRulesTests` | 6.1 节规则表的 4 行；编码后解码一致；损坏的数据返回 `nil` |
| `CrashReportMatcherTests` | 文件名的 4 种合法形式与反例（别的应用、`.diag`、前缀相同但更长的名字如 `EVEOPreviewHelper-…`）；时间窗口的两个边界；文件头的 bundle id 不同时排除；文件头解析失败时仍按文件名匹配；多于 3 个时取最新的 3 个；文件头样例注明「按平台文档拼出，未经真实报告核对」，WP-1 拿到真实样例后替换 |
| `RedactorTests` | 主目录路径的原样与 `\/` 转义两种写法；用户名的边界（`cookie` 被替换，`HTTPCookieStorage` 不被替换）；不足 3 个字符的用户名只在路径里替换；主机名；角色名不区分大小写；最长优先（`Bob Jr` 与 `Bob`）；中文角色名不要求边界；名叫 `user` 的角色不破坏占位符；序号按名字排序且稳定；`crashReporterKey` 的值被替换而键保留；替换后的 JSON 仍能解析；计数；空的词表原样返回 |
| `DiagnosticsSummaryTests` | `ConfigSummary` 编码后的 JSON 里没有配置方案名、循环组名、角色名和日志目录（用带特征串的样例配置，断言输出不含这些串）；数量正确；`issueLines` 不含 `/`；`logSlices` 在合计超过 2 MiB 时只留最新文件与截断的末尾；`archiveName` 的格式 |
| `IssueURLBuilderTests` | 地址的主机与路径；标题与正文能从查询串还原；`+`、`&`、`#`、换行的编码；120 个字符的标题上限；正文超长时先丢可选小节、再删环境行、最后截断；结果不超过 6,000 字节；刚好等于上限；含非 ASCII 字符时仍不超限 |
| `UpdateFeedTests` | 没有覆盖值时是正式地址；`https` 地址、`http://127.0.0.1:8123/…`、`http://localhost/…`、`http://[::1]:8123/…` 被接受；`http://example.com/…`、`ftp://…`、不是地址的字符串被忽略；`accepts` 在正式地址下只认本仓库的 Release 路径（别的仓库、别的主机、`http` 都不认）；在测试地址下只认同源 |
| `SemanticVersionTests` | 带与不带 `v`；`1.1`、`1.1.0.0`、空串、负数失败；规范第 11 条的排序样例（`1.0.0-alpha` < `1.0.0-alpha.1` < `1.0.0-alpha.beta` < `1.0.0-beta` < `1.0.0-beta.2` < `1.0.0-beta.11` < `1.0.0-rc.1` < `1.0.0`）；构建信息不参与比较；`1.1.0-pr.12.abc1234` 与 `1.1.0-dev.abc1234` 小于 `1.1.0`、大于 `1.0.0`；带前导零的数字段能解析；`1.10.0` 大于 `1.9.0` |
| `ReleaseFeedParserTests` | GitHub 答复的样例（`UpdateFixtures.swift`，字符串常量）；缺 `body`；`tag_name` 不是版本号；`html_url` 指向别的仓库；附件地址不合格时丢掉该附件；超长的正文被截短；不是 JSON；`rateLimit` 对 403 加 `x-ratelimit-remaining: 0`、429 加 `retry-after`、普通 403、200 各自的结果 |
| `ChecksumListTests` | 文本模式与二进制模式；大写的十六进制；CRLF；空行与注释；带空格的文件名；63 位或含非十六进制字符的行；带 `/` 的文件名；同名不同值；相同的重复行；`expectedHash` 找不到时的错误；本仓库脚本的真实输出样例 |
| `UpdateAssetContractTests` | `imageName(version: "1.1.1")` 等于 `EVE-O-Preview-1.1.1.dmg`；两个附件都在时取到；缺任何一个时抛 `assetMissing` 并带上缺的名字；名字只差大小写时不算 |
| `UpdatePolicyTests` | `capability` 表的 8 行，含开发证书在测试地址下可装、ad-hoc 在测试地址下仍不可装；`offer` 表的 6 行，含跳过的版本在用户发起时仍提示、更新的版本不受跳过影响；`isCheckDue` 的各分支，含时钟调回与限流；`validate` 的每种错误与全部通过；`comparableVersion` 先取标签 |
| `ReleaseNotesTests` | 8.2 节的完整样例取各语言；非英文块去掉 `<details>` 与 `<summary>`；缺某种语言时取英文；没有任何标记时（1.0.0 的说明）返回全文；CRLF；标记里多空格与大写；`blocks` 表的每种行；段落合并；代码块里的 `#` 不算标题 |

### 14.2 手工验证（集成后追加到 `docs/macos/manual-test-checklist.md`）

第 1 组，日志：

1. 启动应用后看 `~/Library/Logs/EVE-O Preview/`。预期：有 `eve-o-preview.log`，第一行是会话头，目录权限 0700，文件权限 0600。
2. 让一个角色登录后在文件里搜它的名字。预期：搜不到，相应位置是 `<private>`。
3. 在「通用」页打开「详细日志」。预期：文件里立即出现 `DEBUG` 行；关掉后不再出现。
4. 用 `EVEO_LOG_DIR` 指向一个临时目录，把上限临时改小后写满。预期：出现 `.1`～`.4`，不出现 `.5`。
5. 运行 `log stream --predicate 'subsystem == "io.github.deletexiumu.eveopreview-macos"'`。预期：系统日志照常有输出。

第 2 组，异常退出：

1. 正常退出再启动。预期：日志里上一次运行记为 `clean`，没有任何提示。
2. `kill <PID>` 后启动。预期：同上（走了正常的退出流程）。
3. `kill -9 <PID>` 后启动。预期：记为 `abnormal`，没有提示，没有圆点。
4. `kill -SEGV <PID>` 后启动。预期：约 5 秒～30 秒后菜单栏图标出现圆点，菜单顶部有报告项；前台不是 EVE 时报告窗口出现且不抢焦点（V17、V18、V27）。
5. 接上一项，前台是 EVE 客户端时启动。预期：窗口不出现；切到别的应用后出现。
6. 在窗口里选「不报告」后重启。预期：不再提示。
7. 在权限页点「重新启动」。预期：新实例记上一次为 `clean`。

第 3 组，问题报告：

1. 从菜单打开「报告问题…」。预期：窗口列出摘要、设置摘要、日志；此时 `Reports/` 目录里没有新文件。
2. 逐个查看预览。预期：没有用户名、电脑名称、角色名；路径显示为 `/Users/[user]/…`。
3. 点「生成报告并打开 GitHub」。预期：访达选中 zip；浏览器打开新建 Issue 的页面，标题与正文已填好（V19）。
4. 解开 zip，用 `grep -ri` 搜用户名、电脑名称和每个角色名。预期：都搜不到。
5. 取消勾选日志后生成。预期：zip 里没有 `logs/`，`manifest.json` 与实际文件一致。
6. 连续生成 4 次。预期：`Reports/` 里只有最新的 3 个。
7. 5 种语言下各看一遍窗口。预期：没有被截断的文字。

第 4 组，更新检查：

1. 用 1.1.0 的正式构建启动并等 10 秒。预期：日志里有一次检查；`state.json` 里有 `lastCheckAt` 与 `etag`。
2. 1 小时内重启。预期：不再请求。
3. 点「检查更新…」。预期：显示「已是最新版本」或更新窗口。
4. 关掉「自动检查更新」后重启。预期：没有请求；「检查更新…」仍可用。
5. 断网后点「检查更新…」。预期：显示网络错误，应用照常运行。
6. 用 ad-hoc 构建、开发证书构建各做一次第 3 项（用测试地址提供一个更新的版本）。预期：ad-hoc 显示原因与「打开发布页」；开发证书在正式地址下只提示。
7. 直接从 dmg 里打开应用。预期：窗口说明应用在只读磁盘上。

第 5 组，本地端到端安装（要用户配合；先退出正在运行的应用）：

1. 用 `SIGN_IDENTITY="EVEO Preview Dev"` 构建 `VERSION=1.1.0` 的应用 A，拷贝到 `~/Applications/`。从访达打开 A，给它授予屏幕录制与辅助功能权限，确认缩略图有画面，然后退出。再构建并打包 `VERSION=1.1.1` 的应用 B，得到 dmg 与 `SHA256SUMS.txt`。
2. 写 `feed.json`（`tag_name` 是 `v1.1.1`，附件地址指向 `http://127.0.0.1:8123/`），在 `dist/release/` 下运行 `python3 -m http.server 8123 --bind 127.0.0.1`。
3. 运行 `open --env EVEO_UPDATE_FEED_URL=http://127.0.0.1:8123/feed.json "$HOME/Applications/EVE-O Preview.app"`。不直接运行包里的可执行文件：那样权限记在终端名下（架构文档 9.2 节）。第 4 项就比不出权限是否保留。预期：出现更新窗口，带「测试地址」字样，发布说明按界面语言显示（V20）。
4. 点「安装更新」。预期：进度依次是下载、核对、安装、重新启动；新实例的「关于」页显示 1.1.1；不用重新授权，缩略图有画面，最小化可用（V22、V23）。
5. 改 dmg 的一个字节后重做。预期：报校验和不符，A 没有变化。
6. 把 B 改用 ad-hoc 签名后重新打包（校验和文件随之更新）再重做。预期：报无法验证，A 没有变化，`codesign --verify` 对 A 仍通过。
7. 把 `feed.json` 的版本改成 `v1.2.0`，附件仍是 1.1.1 的 dmg。预期：报版本不符，A 没有变化。
8. 下载途中停掉 HTTP 服务。预期：报网络错误，缓存目录里没有 `.partial` 文件。
9. 打开「自动安装更新」，用测试地址启动 A。预期：不出现窗口；菜单出现「重新启动以更新到 1.1.1」；退出应用后再打开是 1.1.1。
10. 把 A 所在的文件夹改成只读后启动。预期：窗口说明没有权限，只有「打开发布页」。
11. 停掉 HTTP 服务，运行 `nc -l 127.0.0.1 8123`，再让应用检查一次。预期：`nc` 打印出的请求头与 10.1 节的表一致，`Accept-Language` 是 `en`，`User-Agent` 里没有系统版本，没有 `Cookie`。

第 6 组，升级与降级：

1. 用 1.0.0 的配置文件启动 1.1.0。预期：设置都在；`config.json` 的 `schemaVersion` 仍是 1。
2. 换回 1.0.0 启动。预期：配置照常读取，没有「来自更新版本」的提示。
3. 从 1.0.0 手动升级到 1.1.0（两者都用发布证书签名）。预期：两项权限保留，不用重新授予。

## 15 文档更新

集成时由主会话改。工作包把要写的文字放在回报里。

`docs/macos/architecture.md`：

| 章节 | 改动 |
| --- | --- |
| 开头与 2.1 | 指向本文；范围加 3 项：文件日志与问题报告、更新检查、应用内安装 |
| 3.1、3.2 | 模块职责加上 4.1 节的内容；隔离的例外加 `FileLogSink`（锁）与更新的后台任务 |
| 5.2 | `GeneralSettings` 的 3 个新键；新增「状态文件」一小节，指向本文 3.3 节 |
| 6.1 | `PlatformServices` 的两个新成员与两个协议 |
| 7.1 | 启动顺序与退出流程（本文 4.4 节）；会话标记 |
| 7.4 | 菜单的新项与圆点；「通用」页的两组 |
| 第 8 节的约定 | 日志一条改成：经 `PlatformLog.logger` 或 `AppLog.logger`，不直接建 `Logger`；新目录的文件表指向本文第 12 节 |
| 9.1 | `Info.plist` 的 `EVEOBuildLabel`、`EVEOBuildCommit` |
| 9.2、9.5 | 发布证书、同仓库 PR 的签名、草稿演练、发布说明的格式；删掉「每次升级后要重新授权」 |
| 9.4 | 附件名是契约，指向本文 8.1 节 |
| 6.7 | 探针的 `update` 命令 |
| 10、11、12、13 | 指向本文第 13、14、16、17、18 节 |

5 份 README（`README.md`、`README.zh-CN.md`、`README.ja.md`、`README.ko.md`、`README.ru.md`），内容相同：

| 小节 | 改动 |
| --- | --- |
| Features | 加「检查并安装更新」「报告问题」 |
| Installation | 从 1.0.0 升级要手动安装一次（权限保留）；之后可在应用内更新；哪些构建不能自动安装（9.1 节） |
| 新增 Updates | 自动检查、「跳过此版本」、自动安装的时机、关闭办法 |
| 新增 Reporting a problem | 三个入口、报告里有什么、脱敏的范围与局限（7.3 节）、zip 的位置 |
| 新增 Privacy | 10.1、10.2 节的内容；卸载时可删的 4 个位置 |
| Development | `EVEO_UPDATE_FEED_URL`、`EVEO_LOG_DIR`、`EVEO_STATE_DIR`、`EVEO_LOG_PRIVATE`；本地端到端测试的步骤 |
| CI and releases | 发布契约与发布说明的格式 |
| Disclaimer | 加一句：应用只在检查和下载更新时访问 GitHub，不发送个人数据 |

其他：

- `docs/macos/manual-test-checklist.md`：追加 14.2 节的 6 组。
- `docs/release-notes/macos/v1.1.0.md`：按 8.2 节的格式写。内容应有：从 1.0.0 升级要手动安装一次、权限保留；应用开始访问 GitHub 及关闭办法；新功能。
- 「关于」页的说明：`networkText`（WP-0）。

## 16 风险与待核实事项

编号接着反馈文档第 11 节。

| 编号 | 风险或待核实事项 | 应对 |
| --- | --- | --- |
| V17 | `.ips` 文件的命名、第一行的 JSON 键、路径是否写成 `\/`，本机没有样例可核实（U9） | 匹配只依赖文件名与修改时间；脱敏同时处理两种路径写法。WP-1 的第一项任务是制造一次崩溃并核对，结果不符时停下报主会话 |
| V18 | 已签名的应用读 `~/Library/Logs/DiagnosticReports/` 是否要额外的系统授权，没有实测 | 14.2 节第 2 组第 4 项。读不到时崩溃提示不出现，手动报告仍可用；在 README 里说明可手动附上崩溃报告 |
| V19 | 仓库有 Issue 模板时，不带 `template` 参数的地址能否直接进入预填的编辑页；GitHub 对地址长度的实际上限 | 14.2 节第 3 组第 3 项。进不去时改为带 `template=bug_report.md`，并核对 `body` 是否仍生效 |
| V20 | 应用传输安全（ATS）是否放行到 `127.0.0.1` 的 `http` 请求，没有实测 | 14.2 节第 5 组第 3 项。不放行时在 `Info.plist` 里加 `NSAllowsLocalNetworking`（主会话） |
| V21 | `itemReplacementDirectory` 在外接卷与 `/Applications` 上给出的位置，以及 `RENAME_SWAP` 在 APFS 以外的文件系统上的结果，没有实测（U7 只测了 APFS） | 9.3 节的两次改名后备；改名失败时已安装的应用不变 |
| V22 | 进程替换自己的包之后，用同一路径重新启动得到的是不是新版本（系统有没有缓存旧包的信息），没有实测 | 14.2 节第 5 组第 4 项；9.3 节第 11 步的重新登记。不成立时在窗口里提示用户手动重新打开 |
| V23 | 用同一张证书签名的新版本替换后，屏幕录制、辅助功能与「文稿」的授权是否保留，没有实测。它是发布证书方案的前提 | 14.2 节第 5 组第 4 项。不保留时更新后应引导用户到权限页 |
| V24 | 未认证请求的 304 答复是否计入限流额度，没有核实 | 设计不依赖它：一天最多约 24 次自动请求，额度是每小时 60 次 |
| V25 | 自签名证书签名时没有可信时间戳。证书到期（10 年）后已有签名的核对结果未知 | 记入发布手册：到期前换证书并按 R18 处理 |
| V26 | macOS 27 上 `hdiutil attach -plist` 的输出格式与 `-mountrandom` 的行为，没有实测 | WP-3 用探针核对。解析不出挂载点时返回 `imageMountFailed`，已安装的应用不变 |
| V27 | 不激活应用而用 `orderFrontRegardless()` 显示的窗口，是否出现在别的应用窗口之上且不抢键盘焦点，没有实测 | 14.2 节第 2 组第 4、5 项。不符合时自动弹出的窗口全部改成只亮圆点和菜单项 |
| R18 | 发布证书的私钥丢失，或换了证书 | 已安装的版本核对新版本时得到 `requirementNotSatisfied`，降为只提示。换证书的那个版本要用户手动安装并重新授权一次，发布说明应写明。证书与私钥应离线备份 |
| R19 | 发布证书的私钥泄露 | 攻击者还要能改动 GitHub Release 或劫持 `https` 才能送达。处理办法是换证书，同 R18 |
| R20 | CI 或发布流程改了附件名、dmg 的结构或发布说明的格式 | 8.1 节的契约表；CI 的契约检查（13.3 节）；应用降为只提示而不是报错退出 |
| R21 | 1.1.0 是第一个能自己更新的版本，安装路径第一次在用户机器上运行是 1.1.0 升到下一个版本的时候。1.1.0 的安装代码有缺陷时无法靠更新修复 | 发布 1.1.0 之前做完 14.2 节第 5 组与草稿演练；只提示的路径不依赖安装代码（9.1 节）；失败时已安装的应用不变 |
| R22 | 日志文件里有 `.public` 的路径，含用户名（U3） | 文件在用户自己的 `Library` 下，权限 0600；进报告前脱敏 |
| R23 | 脱敏漏掉应用不知道的名字，或把常见的词当成名字替换 | 7.3 节的局限说明；生成前的全文预览；用户自起的名字不进报告 |
| R24 | 两个新域的 10 个译文文件几乎没有注释，拉低注释率（U14） | 文字文件按界面位置分组写注释；各工作包交付前运行 `check_quality.py` |
| R25 | 应用在运行时替换自己的包 | 替换是原子改名；旧包留到下次启动再删；用户发起的安装随即重新启动；退出时的安装之后进程就结束 |
| R26 | 退出时的安装被注销或关机打断 | 8 秒上限；替换是原子的；残留由下次启动清理 |
| R27 | 自动弹出的窗口打扰游戏 | 4.5 节：不激活、EVE 在前台时推迟；自动安装不重新启动 |
| R28 | 首次联网让用户意外 | 发布说明、README、「关于」页写明；一个开关可关（Q13） |
| R29 | `renamex_np` 之后旧进程继续运行期间，系统按路径重新核对进程的签名 | 用户发起的安装在替换后立即重新启动，窗口期只有几秒；V22、V23 的实测一并观察 |
| R30 | 四个工作包并行，接口靠骨架约定 | WP-0 的骨架按本文已做过类型检查的签名写；改签名要经主会话 |

## 17 待用户决定的问题

以下问题都有默认做法，实现照默认做法做；用户有不同意见时改。

| 编号 | 问题 | 本文采用的默认做法 |
| --- | --- | --- |
| Q13 | 「自动检查更新」默认开还是关 | 默认开。发布说明、README 与「关于」页写明应用会访问 GitHub，「通用」页可关。另一种做法是首次启动时询问 |
| Q14 | 检测到崩溃、发现新版本时，是否自动弹出窗口 | 弹出，但不激活应用；前台是 EVE 客户端时推迟到切走之后（4.5 节）。另一种做法是只亮圆点和菜单项 |
| Q15 | 「自动安装」在什么时候安装 | 用户退出应用时，或用户点菜单项时。应用不自行重新启动（9.5 节） |
| Q16 | 报告 zip 放在哪里 | `~/Library/Application Support/EVE-O Preview/Reports/`，只留最新的 3 个。不放「下载」或「桌面」，这两个位置要另外的系统授权 |
| Q17 | 新增文字的 `ru`、`ja`、`ko` 译文 | 同 Q11：先按机器译文发布并注明 |
| Q18 | 同仓库的 PR 构建与 `main` 构建在正式版发布后是否提示更新 | 提示并可安装（8.3 节的 `buildLabel`）。这要构建脚本写入 `EVEOBuildLabel`（13.3 节第 1 项） |
| Q19 | 第 5 组手工验证要退出正在运行的应用，约 20 分钟～30 分钟，何时做 | 四个工作包合入后，由主会话与用户约时间 |

## 18 术语

在架构文档第 13 节与反馈文档第 13 节的基础上增加：

| 词 | 意思 | 不用 |
| --- | --- | --- |
| 文件日志 | 写在 `~/Library/Logs/EVE-O Preview/` 下的应用日志 | 本地日志 |
| 系统日志 | 经 `os.Logger` 写入 macOS 统一日志的记录 | 控制台日志 |
| 输出目标 | `LogSink`，接收日志记录的一方 | 接收器、汇 |
| 轮转 | 日志文件到上限后改名为旧文件、另建新文件 | 滚动、切割 |
| 私有值 | 日志里标为 `.private` 的插值，文件里写成 `<private>` | 敏感值 |
| 会话标记 | `session.json`，记一次运行的开始与是否正常结束 | 哨兵文件 |
| 异常结束 | 进程没有经过正常的退出流程就结束 | 非正常退出 |
| 崩溃报告 | macOS 写在 `DiagnosticReports` 下的 `.ips` 文件 | 崩溃日志 |
| 问题报告 | 用户发起的一次报告：一个 zip 加一个预填的 Issue 地址 | 反馈 |
| 脱敏 | 把用户名、主机名、角色名换成占位符 | 打码、匿名化 |
| 占位符 | 脱敏后代替原文的记号，如 `[user]` | 掩码 |
| 发布契约 | CI 的产物名字、结构与发布说明格式的约定（8.1、8.2 节） | 接口 |
| 指定要求 | 代码签名里的 designated requirement，系统用它判断两个构建是不是同一个应用 | 指定需求 |
| 发布证书 | CI 给发布构建签名用的自签名证书 `EVE-O Preview Release` | 正式证书 |
| 转移运行 | macOS 把带隔离属性的应用放到随机的只读路径下运行（App Translocation） | 易位 |
| 暂存目录 | 安装前放新应用副本的临时目录，与已安装的包在同一个卷上 | 中转目录 |
| 只提示 | 发现新版本后不下载，只说明原因并提供「打开发布页」 | 通知模式 |
| 测试地址 | 用 `EVEO_UPDATE_FEED_URL` 指定的更新检查地址 | 测试源 |
| 圆点 | 菜单栏图标右上角的提示标记 | 角标、红点 |
| 骨架 | 签名齐全、方法体不做事的类型，由 WP-0 先建 | 桩 |

## 19 实现后的修订

2026-11-21 集成时，主会话按工作包的回报定下以下几处，与上文不一致的地方以本节为准。

| 位置 | 修订 |
| --- | --- |
| U9 | `DiagnosticReports/Retired/` 里已有 `.ips`（如 `ExcUserFault_<进程名>-….ips`），按 `EVEOPreview-` 前缀匹配时会被排除 |
| U13 | 本仓库的 v1.0.0 发布说明已带语言标记；没有标记时显示全文的规则保留，有测试覆盖 |
| 6.2 | 实测 `.ips` 文件名是 `<可执行文件名>-YYYY-MM-DD-HHMMSS.ips`（本地时间），同一秒的第二份加 `.000`；第一行是单行 JSON，正文里的路径写成 `\/` |
| 6.3 | 启动时遗留的崩溃只由 `SessionTracker` 经 `onCrashDetected` 重放一次，问题报告一侧不再从 `state.json` 触发 |
| 9.3 | 只在 `renamex_np(RENAME_SWAP)` 可用（APFS）时自动安装，去掉「两次改名」的后备做法。实测 HFS+ 与 exFAT 返回 `ENOTSUP`，FAT 返回 `ENOTEMPTY`，一律按 `swapFailed` 处理，旧应用不变，这些卷上只能手动安装。替换后的复核失败且换回也失败时，保留存放旧应用的暂存目录并记录其位置，不删除（审查 B1） |
| 9.5 | 用户手动安装时下载失败，记为该版本安装失败，之后不自动安装该版本 |
| 8.6 | 「重新启动失败」不新增阶段或提示原因：`UpdateController.relaunchFailed` 为真时窗口与「通用」页显示 `reopenManually`，并重新弹出窗口 |
| 13.1 | 「通用」页的两组在 WP-0 是 `EmptyView`，不显示空的组 |
| 5.4 | 未捕获异常的原因按 `.public` 记录 |
| 7.x 演示模式 | 演示模式生成的 zip 写入 `Reports-fake/`（与 `*-fake.json` 同样的做法），不占 `Reports/` 的名额；Issue 标题加 `[demo] ` 前缀；「打开 GitHub」打开真实仓库的预填页面，不会自动提交 |
| 6.2、7.2 | 不认 `.crash` 扩展名（macOS 14 起只写 `.ips`）；崩溃情境从 `state.json` 读到的报告文件名，读之前再用 `isCandidateName` 核对 |
| 9.3 第 10 步 | 替换后复核失败且换回也失败时，返回 `swapFailed`，界面显示「无法替换应用」，实际装上的是未通过复核的新应用；旧应用留在暂存目录，位置写进 fault 日志。要准确提示需新增错误类型（契约改动），这种情况要连续两步失败，v1.1.0 不做 |
| 9.1 | 非 APFS 卷在第 1 步预检时返回 `swapFailed(ENOTSUP)`，界面是通用的「无法替换应用」；README 写明这类卷只能手动安装 |
| 3.4、9.1、14.2 第 6 组 | 本仓库的 v1.0.0 迁为独立仓库时已改用发布证书签名，不是 ad-hoc；从 1.0.0 手动升级后权限保留 |
| 16（新增风险） | macOS 27 上 `hdiutil attach`/`detach` 打印弃用警告，仍可用。若以后的系统去掉它，挂载失败按 `imageMountFailed` 处理，旧应用不变，用户手动安装一次；届时新版本改用 `diskutil image attach`。v1.1.0 不加未经测试的后备 |
| 9.3 | 已有下载直接安装时，也先等启动时的清理（会卸下残留挂载）做完，避免「资源忙」 |
| D9、3.1、9.5（用户在手工测试后要求） | `autoInstallUpdates` 默认改为 true。下载好以后，每 20 秒检查一次是否空闲：没有客户端窗口、系统里没有 `com.ccpgames.eveonline` 进程、本应用没有打开带标题栏的窗口；连续 3 次空闲就走「重新启动以更新」的路径安装并重新启动（`UpdateController+IdleInstall.swift`）。退出时安装与菜单项照旧 |
| 3.1、11.2（用户在手工测试后要求） | 新增 `general.showDockIcon`，默认 true：激活策略为 `.regular`，Dock 与 Cmd+Tab 里有图标，点 Dock 图标打开设置窗口。为 false 时是 `.accessory`。Info.plist 仍写 LSUIElement，读完配置再切换，关掉的用户启动时不闪图标。主菜单补上应用菜单（设置 Cmd+,、退出 Cmd+Q）；缩略图面板 `canHide = false`，不被 Cmd+H 或「隐藏其他」隐藏。配置摘要加 `showDockIcon` |
| 7.1（手工测试发现） | `relaunch` 的 `openApplication` 回调在后台队列执行，原先被推断为主线程隔离，Swift 6 运行时检查失败使旧进程崩溃；改为 `@Sendable`。SIGTERM 处理与 `relaunch` 在主队列任务里直接调 `NSApp.terminate` 会死锁，改为 `RunLoop.main.perform` |
| 6（待改进，v1.1.0 不做） | 新旧实例重叠时（重新启动），旧进程的崩溃报告会按时间算到新会话头上。可改为再核对 `.ips` 里的 PID 与会话标记的 PID |
| 9.1、9.5（独立审查后修订） | 新增 `InstallBlocker.unsupportedVolume`：`AppEnvironment.volumeSupportsSwap` 为假（卷不支持 `RENAME_SWAP`）时只提示，开关下方写明原因，不再下载后在预检时失败。上面「非 APFS 卷在第 1 步预检时返回 `swapFailed`」一行由此取代，预检保留作兜底 |
| 第 19 节空闲安装（独立审查后修订） | 空闲检查改为一个运行到退出的循环，阶段暂时离开 `.readyToInstall` 只清零计数；退出开始时 `prepareForTermination` 停掉它，之后的安装不重新启动。安装失败（含空闲与菜单项触发的）经推迟弹出机制显示更新窗口。`relaunch` 设 `activates = false`，不抢焦点。点 Dock 图标时按本应用带标题栏的可见窗口判断，不用 `hasVisibleWindows`（会把缩略图算进去）。「已下载」状态行改为「没有 EVE 客户端运行时或退出时安装」 |
| 第 19 节空闲安装（复审后修订） | `relaunch(activates:)`：权限页的「重新启动」激活新实例，自动更新后的不激活。不能安装的构建不进入 `.readyToInstall`，空闲循环也不对它动作。下载阶段的失败同样经推迟弹出机制显示更新窗口 |
