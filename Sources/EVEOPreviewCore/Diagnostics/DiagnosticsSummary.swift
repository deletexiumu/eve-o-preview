// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的摘要（v1.1 设计 7.2 节）：
// - `ConfigSummary`：`config-summary.json` 的内容。只有数值、开关、热键与数量，
//   不含配置方案名、循环组名、角色名和任何路径。用户自己起的名字可能含任何文字，所以整个不进报告，不靠脱敏。
// - `RuntimeSummary`：协调器在主线程取的运行时快照。
// - `EnvironmentReport`：`summary.md` 的全文与 Issue 正文「Environment」一节（英文）。
// - `DiagnosticsBundlePlanner`：日志取多少、压缩包叫什么。
// - `DiagnosticsManifest`：`manifest.json` 的内容。

import Foundation

// MARK: - 配置摘要

/// `config-summary.json` 的内容。
public struct ConfigSummary: Sendable, Equatable, Codable {
    /// 配置文件格式的版本。
    public var schemaVersion: Int
    /// 配置方案的数量。
    public var profileCount: Int
    /// 读配置的错误类别（如 `newerSchema`），没有错误时为 nil。
    public var loadError: String?
    /// 读配置的警告类别（如 `valuesClamped`），只有类别名。
    public var warnings: [String]
    /// 当前配置方案的设置。
    public var activeProfile: ProfileSummary
    /// 全局设置。
    public var general: GeneralSummary

    /// 当前配置方案的设置，名字都换成了数量或序号。
    public struct ProfileSummary: Sendable, Equatable, Codable {
        public var thumbnail: ThumbnailSettings
        public var overlay: OverlaySettings
        public var behavior: BehaviorSettings
        public var capture: CaptureSettings
        public var combatAlert: CombatAlertSettings
        public var hotkeyDefaultScope: HotkeyScope
        /// 有自定位置的角色数。
        public var layoutCount: Int
        /// 隐藏的角色数。
        public var hiddenCharacterCount: Int
        /// 有自定高亮颜色的角色数。
        public var highlightColorCount: Int
        /// 有角色热键的角色数。
        public var characterHotkeyCount: Int
        /// 通用热键。
        public var hotkeys: GeneralHotkeys
        /// 循环组，按配置里的顺序，只有成员数与热键。
        public var cycleGroups: [CycleGroupSummary]
        /// 角色热键，按角色名排序（不区分大小写）后的序号排列，只有热键。
        public var characterHotkeys: [[String]]
    }

    /// 一个循环组的摘要。
    public struct CycleGroupSummary: Sendable, Equatable, Codable {
        /// 成员数。
        public var memberCount: Int
        /// 前进热键。
        public var forwardHotkeys: [String]
        /// 后退热键。
        public var backwardHotkeys: [String]
    }

    /// 全局设置的摘要。
    public struct GeneralSummary: Sendable, Equatable, Codable {
        public var pollIntervalMs: Int
        public var language: LanguagePreference
        public var checkForUpdates: Bool
        public var autoInstallUpdates: Bool
        public var logLevel: LogLevel
        /// 游戏日志目录：`default` 或 `custom`，不写路径。
        public var eveLogDirectory: String
    }

    /// 由配置建摘要。loadErrorKind、warningKinds 只传类别名，不传路径与说明。
    public init(config: AppConfig, loadErrorKind: String?, warningKinds: [String]) {
        schemaVersion = config.schemaVersion
        profileCount = config.profiles.count
        loadError = loadErrorKind
        warnings = warningKinds
        let profile = config.activeProfile
        let hotkeyNames = profile.characterHotkeys.keys.sorted {
            let left = $0.lowercased(), right = $1.lowercased()
            return left == right ? $0 < $1 : left < right
        }
        activeProfile = ProfileSummary(
            thumbnail: profile.thumbnail, overlay: profile.overlay, behavior: profile.behavior,
            capture: profile.capture, combatAlert: profile.combatAlert,
            hotkeyDefaultScope: profile.hotkeyDefaultScope,
            layoutCount: profile.layouts.count, hiddenCharacterCount: profile.hiddenCharacters.count,
            highlightColorCount: profile.highlightColors.count,
            characterHotkeyCount: profile.characterHotkeys.count, hotkeys: profile.hotkeys,
            cycleGroups: profile.cycleGroups.map {
                CycleGroupSummary(memberCount: $0.members.count, forwardHotkeys: $0.forwardHotkeys,
                                  backwardHotkeys: $0.backwardHotkeys)
            },
            characterHotkeys: hotkeyNames.map { profile.characterHotkeys[$0] ?? [] })
        let general = config.general
        let customLogDirectory = !(general.eveLogDirectory ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        self.general = GeneralSummary(pollIntervalMs: general.pollIntervalMs, language: general.language,
                                      checkForUpdates: general.checkForUpdates,
                                      autoInstallUpdates: general.autoInstallUpdates, logLevel: general.logLevel,
                                      eveLogDirectory: customLogDirectory ? "custom" : "default")
    }

    /// 编码成 `config-summary.json` 的内容：缩进、键按字母排序。
    public func encodedJSON() -> Data {
        (try? DiagnosticsJSON.encoder().encode(self)) ?? Data("{}".utf8)
    }
}

// MARK: - 运行时摘要

/// 协调器在主线程取的运行时快照，写进 `summary.md`。
public struct RuntimeSummary: Sendable, Equatable, Codable {
    /// 界面语言代码。
    public var uiLanguage: String
    /// 是否有屏幕录制权限。
    public var screenRecordingGranted: Bool
    /// 是否有辅助功能权限。
    public var accessibilityGranted: Bool
    /// 游戏日志跟踪服务的状态，只有状态名与文件数，不含路径。
    public var combatLogStatus: String
    /// 已选角色的客户端数。
    public var characterClients: Int
    /// 停在登录界面的客户端数。
    public var loginClients: Int
    /// 无法识别的客户端数。
    public var unknownClients: Int
    /// 状态名 → 个数。
    public var captureStates: [String: Int]
    /// 已注册的热键数。
    public var hotkeyBindings: Int
    /// 注册失败的原因名 → 个数。
    public var hotkeyFailures: [String: Int]
    /// 屏幕，如 `1728x1117@2x main`。
    public var screens: [String]
    /// 本次运行了多少秒。
    public var uptimeSeconds: Int
    /// 上一次运行的归类：`clean`、`abnormal`、`crashed`、`stillRunning`、`noRecord`。
    public var previousRun: String
    /// 是否为演示模式。
    public var isFakeMode: Bool

    /// 用各字段建快照。
    public init(uiLanguage: String, screenRecordingGranted: Bool, accessibilityGranted: Bool,
                combatLogStatus: String, characterClients: Int, loginClients: Int, unknownClients: Int,
                captureStates: [String: Int], hotkeyBindings: Int, hotkeyFailures: [String: Int],
                screens: [String], uptimeSeconds: Int, previousRun: String, isFakeMode: Bool) {
        self.uiLanguage = uiLanguage
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
        self.combatLogStatus = combatLogStatus
        self.characterClients = characterClients
        self.loginClients = loginClients
        self.unknownClients = unknownClients
        self.captureStates = captureStates
        self.hotkeyBindings = hotkeyBindings
        self.hotkeyFailures = hotkeyFailures
        self.screens = screens
        self.uptimeSeconds = uptimeSeconds
        self.previousRun = previousRun
        self.isFakeMode = isFakeMode
    }
}

// MARK: - 环境报告

/// 运行环境、系统信息与运行时快照的合集。
public struct EnvironmentReport: Sendable, Equatable {
    /// 应用的运行环境。只用版本、构建标签、提交、签名类别与安装位置类别；路径、签名者与指定要求不进报告。
    public var app: AppEnvironment
    /// 系统信息。
    public var system: SystemInfo
    /// 运行时快照。
    public var runtime: RuntimeSummary

    /// 用三部分建报告。
    public init(app: AppEnvironment, system: SystemInfo, runtime: RuntimeSummary) {
        self.app = app
        self.system = system
        self.runtime = runtime
    }

    /// 压缩包里 `summary.md` 的全文（英文）。
    public func markdown(generatedAt: Date) -> String {
        var lines = ["# EVE-O Preview diagnostics", "", "Generated: \(DiagnosticsJSON.isoString(generatedAt))", ""]
        lines += ["## App", ""]
        lines += [
            "- Version: \(app.version)",
            "- Build label: \(app.buildLabel)",
            "- Commit: \(app.buildCommit ?? "unknown")",
            "- Signature: \(app.signature.kind.rawValue)",
            "- Install location: \(app.location.rawValue)",
            "- Location writable: \(EnvironmentReport.yesNo(app.isLocationWritable))",
            "- Demo mode: \(EnvironmentReport.yesNo(runtime.isFakeMode))",
            "",
        ]
        lines += ["## System", ""]
        lines += [
            "- macOS: \(system.osVersion) (\(system.osBuild))",
            "- Architecture: \(architectureText)",
            "- Model: \(system.hardwareModel)",
            "- CPU: \(system.cpuBrand)",
            "- Memory: \(EnvironmentReport.gibibytes(system.physicalMemoryBytes))",
            "- Processors: \(system.processorCount)",
            "- Locale: \(system.localeIdentifier)",
            "- Preferred languages: \(system.preferredLanguages.joined(separator: ", "))",
            "- Interface language: \(runtime.uiLanguage)",
            "",
        ]
        lines += ["## Runtime", ""]
        lines += [
            "- Screen Recording: \(EnvironmentReport.granted(runtime.screenRecordingGranted))",
            "- Accessibility: \(EnvironmentReport.granted(runtime.accessibilityGranted))",
            "- Screens: \(runtime.screens.isEmpty ? "none" : runtime.screens.joined(separator: "; "))",
            "- Clients: \(runtime.characterClients) character, \(runtime.loginClients) login, "
                + "\(runtime.unknownClients) unknown",
            "- Capture states: \(EnvironmentReport.counts(runtime.captureStates))",
            "- Hotkeys registered: \(runtime.hotkeyBindings)",
            "- Hotkey failures: \(EnvironmentReport.counts(runtime.hotkeyFailures))",
            "- Combat log: \(runtime.combatLogStatus)",
            "- Uptime: \(runtime.uptimeSeconds) s",
            "- Previous run: \(runtime.previousRun)",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Issue 正文里「Environment」一节的各行（英文），不含任何路径与名字。
    ///
    /// 重要的在前：超出地址长度时从末尾逐行删。
    public func issueLines() -> [String] {
        [
            "- EVE-O Preview: \(app.version) (build \(app.buildLabel))",
            "- Signature: \(app.signature.kind.rawValue)",
            "- macOS: \(system.osVersion) (\(system.osBuild))",
            "- Architecture: \(architectureText)",
            "- Model: \(system.hardwareModel)",
            "- Interface language: \(runtime.uiLanguage)",
            "- Screen Recording: \(EnvironmentReport.granted(runtime.screenRecordingGranted))",
            "- Accessibility: \(EnvironmentReport.granted(runtime.accessibilityGranted))",
        ].map { $0.replacingOccurrences(of: "/", with: "-") }
    }

    /// 架构，Rosetta 下注明。
    private var architectureText: String {
        system.isTranslated ? "\(system.architecture) (Rosetta)" : system.architecture
    }

    /// 布尔值的英文。
    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    /// 权限状态的英文。
    private static func granted(_ value: Bool) -> String { value ? "granted" : "not granted" }

    /// 内存，单位 GiB。
    private static func gibibytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GiB", value)
    }

    /// 计数表，按名字排序，如 `running 2, idle 1`；空表写 `none`。
    private static func counts(_ table: [String: Int]) -> String {
        guard !table.isEmpty else { return "none" }
        return table.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

// MARK: - 压缩包的规划

/// 日志取多少、压缩包叫什么。
public enum DiagnosticsBundlePlanner {
    /// 日志合计的上限：2 MiB。
    public static let maxLogBytes = 2_097_152
    /// 压缩包名字的前缀。
    public static let archivePrefix = "EVE-O-Preview-diagnostics-"

    /// 从最新的日志文件起取，合计不超过 maxLogBytes；超出的那个文件只留末尾，之后的文件不取。
    ///
    /// - Parameter fileSizes: 日志文件的名字与大小，最新的在前（`LogFileLayout.existingURLs()` 的顺序）。
    /// - Returns: 要取的文件与从末尾取的字节数，顺序不变。空文件不取。
    public static func logSlices(fileSizes: [(name: String, bytes: Int)]) -> [(name: String, tailBytes: Int)] {
        var remaining = maxLogBytes
        var slices: [(name: String, tailBytes: Int)] = []
        for file in fileSizes where file.bytes > 0 {
            guard remaining > 0 else { break }
            let take = min(file.bytes, remaining)
            slices.append((file.name, take))
            remaining -= take
        }
        return slices
    }

    /// 压缩包的名字（不带扩展名），按 UTC：`EVE-O-Preview-diagnostics-20261121-040506`。
    public static func archiveName(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return archivePrefix + stamp
    }
}

// MARK: - 文件清单

/// `manifest.json` 的内容：文件清单、各文件的大小与替换次数、生成时刻、应用版本。
public struct DiagnosticsManifest: Sendable, Equatable, Codable {
    /// 清单里的一个文件。
    public struct Entry: Sendable, Equatable, Codable {
        /// 压缩包里的相对路径。
        public var path: String
        /// 脱敏后的大小，单位是字节。
        public var bytes: Int
        /// 替换次数。
        public var replacements: RedactionCounts

        /// 用各字段建一项。
        public init(path: String, bytes: Int, replacements: RedactionCounts) {
            self.path = path
            self.bytes = bytes
            self.replacements = replacements
        }
    }

    /// 应用版本。
    public var appVersion: String
    /// 构建标签。
    public var buildLabel: String
    /// 生成时刻（ISO 8601，UTC）。
    public var generatedAt: String
    /// 情境：`manual` 或 `crash`。
    public var context: String
    /// 文件清单，不含 `manifest.json` 自己。
    public var files: [Entry]

    /// 用各字段建清单。
    public init(appVersion: String, buildLabel: String, generatedAt: Date, context: String, files: [Entry]) {
        self.appVersion = appVersion
        self.buildLabel = buildLabel
        self.generatedAt = DiagnosticsJSON.isoString(generatedAt)
        self.context = context
        self.files = files
    }

    /// 编码成 `manifest.json` 的内容：缩进、键按字母排序。
    public func encodedJSON() -> Data {
        (try? DiagnosticsJSON.encoder().encode(self)) ?? Data("{}".utf8)
    }
}

/// 报告里 JSON 与时刻的统一写法。
enum DiagnosticsJSON {
    /// 缩进、键按字母排序、`/` 不转义的编码器。
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// UTC 的 ISO 8601 时刻，如 `2026-11-21T04:05:06Z`。
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
