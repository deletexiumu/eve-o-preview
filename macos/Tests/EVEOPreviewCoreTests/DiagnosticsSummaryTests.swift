// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告摘要的用例（v1.1 设计 7.2 节、14.1 节）：ConfigSummary 不含用户起的名字与路径、数量正确；
// issueLines 不含 `/`；logSlices 的 2 MiB 上限；archiveName 的格式；manifest 的编码。

import Foundation
import Testing
import EVEOPreviewCore

/// 摘要与规划。
struct DiagnosticsSummaryTests {
    /// 样例配置：名字与路径都带特征串 `SECRET`，断言输出里没有它。
    static func sampleConfig() -> AppConfig {
        let group = CycleGroup(name: "SECRET-GROUP", forwardHotkeys: ["ctrl+F1"], backwardHotkeys: ["ctrl+shift+F1"],
                               members: ["SECRET-PILOT-A", "SECRET-PILOT-B", "SECRET-PILOT-C"])
        let main = Profile(name: "SECRET-PROFILE",
                           layouts: ["SECRET-PILOT-A": ThumbnailLayout(x: 1, y: 2),
                                     "SECRET-PILOT-B": ThumbnailLayout(x: 3, y: 4)],
                           hiddenCharacters: ["SECRET-PILOT-HIDDEN"],
                           highlightColors: ["SECRET-PILOT-A": "#00FF00"],
                           cycleGroups: [group, CycleGroup(name: "SECRET-EMPTY")],
                           characterHotkeys: ["SECRET-PILOT-B": ["F2"], "secret-pilot-a": ["F3", "F4"]],
                           hotkeys: GeneralHotkeys(toggleHideAll: ["ctrl+H"]))
        let other = Profile(name: "SECRET-OTHER-PROFILE", hiddenCharacters: ["SECRET-OTHER-PILOT"])
        var general = GeneralSettings(eveLogDirectory: "/Users/SECRET-USER/Documents/EVE/logs")
        general.logLevel = .debug
        return AppConfig(activeProfileID: main.id, profiles: [main, other], general: general)
    }

    /// 编码后的 JSON 里没有配置方案名、循环组名、角色名和日志目录。
    @Test func configSummaryHasNoNames() throws {
        let summary = ConfigSummary(config: Self.sampleConfig(), loadErrorKind: nil, warningKinds: ["valuesClamped"])
        let json = String(decoding: summary.encodedJSON(), as: UTF8.self)
        #expect(!json.localizedCaseInsensitiveContains("SECRET"))
        #expect(!json.contains("/Users"))
        // 仍是合法 JSON。
        #expect(try JSONSerialization.jsonObject(with: summary.encodedJSON()) is [String: Any])
    }

    /// 数量、热键与 general 的各项正确。
    @Test func configSummaryCounts() {
        let summary = ConfigSummary(config: Self.sampleConfig(), loadErrorKind: "newerSchema",
                                    warningKinds: ["migrated"])
        #expect(summary.schemaVersion == 1)
        #expect(summary.profileCount == 2)
        #expect(summary.loadError == "newerSchema")
        #expect(summary.warnings == ["migrated"])
        let profile = summary.activeProfile
        #expect(profile.layoutCount == 2)
        #expect(profile.hiddenCharacterCount == 1)
        #expect(profile.highlightColorCount == 1)
        #expect(profile.characterHotkeyCount == 2)
        #expect(profile.cycleGroups.map(\.memberCount) == [3, 0])
        #expect(profile.cycleGroups.first?.forwardHotkeys == ["ctrl+F1"])
        #expect(profile.cycleGroups.first?.backwardHotkeys == ["ctrl+shift+F1"])
        // 角色热键按名字排序（不区分大小写）：secret-pilot-a 在 SECRET-PILOT-B 之前。
        #expect(profile.characterHotkeys == [["F3", "F4"], ["F2"]])
        #expect(profile.hotkeys.toggleHideAll == ["ctrl+H"])
        #expect(summary.general.eveLogDirectory == "custom")
        #expect(summary.general.logLevel == .debug)
        #expect(summary.general.checkForUpdates)
        // 默认值：自动安装开、显示 Dock 图标（设计第 19 节）。
        #expect(summary.general.autoInstallUpdates)
        #expect(summary.general.showDockIcon)
    }

    /// 没有自定游戏日志目录时写 `default`。
    @Test func defaultLogDirectory() {
        #expect(ConfigSummary(config: .makeDefault(), loadErrorKind: nil, warningKinds: []).general.eveLogDirectory
            == "default")
    }

    /// 样例环境报告。
    static func sampleReport() -> EnvironmentReport {
        let app = AppEnvironment(bundleIdentifier: "io.github.deletexiumu.eveopreview-macos", version: "1.1.0",
                                 buildLabel: "1.1.0-pr.12.abc1234", buildCommit: "abc1234",
                                 bundlePath: "/Users/SECRET-USER/Applications/EVE-O Preview.app",
                                 executableName: "EVEOPreview",
                                 signature: CodeSignatureInfo(kind: .release, signerName: "EVE-O Preview Release",
                                                              designatedRequirement: "identifier \"x\" and anchor"),
                                 location: .userApplications, isLocationWritable: true)
        let system = SystemInfo(osVersion: "27.0", osBuild: "26A123", architecture: "arm64", isTranslated: false,
                                hardwareModel: "Mac14,2", cpuBrand: "Apple M2", physicalMemoryBytes: 17_179_869_184,
                                processorCount: 8, localeIdentifier: "zh_CN", preferredLanguages: ["zh-Hans-CN", "en"])
        let runtime = RuntimeSummary(uiLanguage: "zh", screenRecordingGranted: true, accessibilityGranted: false,
                                     combatLogStatus: "watching (2 files)", characterClients: 2, loginClients: 1,
                                     unknownClients: 0, captureStates: ["running": 2, "idle": 1], hotkeyBindings: 5,
                                     hotkeyFailures: ["accessibilityRequired": 1], screens: ["1728x1117@2x main"],
                                     uptimeSeconds: 120, previousRun: "clean", isFakeMode: false)
        return EnvironmentReport(app: app, system: system, runtime: runtime)
    }

    /// issueLines 不含 `/`，也不含路径、签名者与指定要求。
    @Test func issueLinesHaveNoPaths() {
        let lines = Self.sampleReport().issueLines()
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(!line.contains("/"))
            #expect(!line.contains("SECRET"))
            #expect(!line.contains("identifier"))
        }
        #expect(lines.first == "- EVE-O Preview: 1.1.0 (build 1.1.0-pr.12.abc1234)")
        #expect(lines.contains("- Accessibility: not granted"))
    }

    /// summary.md 有各节，不含安装路径与指定要求。
    @Test func markdownContents() {
        let text = Self.sampleReport().markdown(generatedAt: Date(timeIntervalSince1970: 0))
        #expect(text.contains("Generated: 1970-01-01T00:00:00Z"))
        #expect(text.contains("- Signature: release"))
        #expect(text.contains("- Install location: userApplications"))
        #expect(text.contains("- Memory: 16.0 GiB"))
        #expect(text.contains("- Capture states: idle 1, running 2"))
        #expect(!text.contains("SECRET"))
        #expect(!text.contains("anchor"))
    }

    // MARK: logSlices

    /// 合计不超过 2 MiB 时全部照取。
    @Test func logSlicesUnderLimit() {
        let slices = DiagnosticsBundlePlanner.logSlices(fileSizes: [("a.log", 1000), ("a.1.log", 2000)])
        #expect(slices.map(\.name) == ["a.log", "a.1.log"])
        #expect(slices.map(\.tailBytes) == [1000, 2000])
    }

    /// 合计超过 2 MiB 时只留最新的文件与截断的末尾，更旧的不取。
    @Test func logSlicesOverLimit() {
        let mib = 1_048_576
        let slices = DiagnosticsBundlePlanner.logSlices(fileSizes: [("cur", mib), ("1", mib - 10), ("2", mib),
                                                                    ("3", mib)])
        #expect(slices.map(\.name) == ["cur", "1", "2"])
        #expect(slices.map(\.tailBytes) == [mib, mib - 10, 10])
        #expect(slices.map(\.tailBytes).reduce(0, +) == DiagnosticsBundlePlanner.maxLogBytes)
    }

    /// 最新的文件自己就超过上限时只取它的末尾。
    @Test func logSlicesSingleHugeFile() {
        let slices = DiagnosticsBundlePlanner.logSlices(fileSizes: [("cur", 5_000_000), ("1", 100)])
        #expect(slices.map(\.name) == ["cur"])
        #expect(slices.first?.tailBytes == DiagnosticsBundlePlanner.maxLogBytes)
    }

    /// 空文件不取。
    @Test func logSlicesSkipEmpty() {
        let slices = DiagnosticsBundlePlanner.logSlices(fileSizes: [("cur", 0), ("1", 10)])
        #expect(slices.map(\.name) == ["1"])
    }

    // MARK: archiveName

    /// 名字按 UTC：`EVE-O-Preview-diagnostics-yyyyMMdd-HHmmss`。
    @Test func archiveNameFormat() throws {
        // 2026-11-21T04:05:06Z
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-21T04:05:06Z"))
        #expect(DiagnosticsBundlePlanner.archiveName(at: date) == "EVE-O-Preview-diagnostics-20261121-040506")
    }

    // MARK: manifest

    /// manifest 编码后能解析，含文件清单与替换次数。
    @Test func manifestEncoding() throws {
        let manifest = DiagnosticsManifest(appVersion: "1.1.0", buildLabel: "1.1.0", generatedAt: Date(timeIntervalSince1970: 0),
                                           context: "manual",
                                           files: [.init(path: "summary.md", bytes: 10,
                                                         replacements: RedactionCounts(user: 1))])
        let object = try #require(try JSONSerialization.jsonObject(with: manifest.encodedJSON()) as? [String: Any])
        #expect(object["appVersion"] as? String == "1.1.0")
        #expect(object["generatedAt"] as? String == "1970-01-01T00:00:00Z")
        let files = try #require(object["files"] as? [[String: Any]])
        #expect(files.first?["path"] as? String == "summary.md")
        #expect((files.first?["replacements"] as? [String: Int])?["user"] == 1)
    }
}

/// 预警与翻译的摘要（docs/macos/design-intel-translate.md 3.4 节）：频道名、参考星系名、接口地址与模型名都不进报告。
struct ChatDiagnosticsSummaryTests {
    /// 名字与地址都带特征串 `SECRET`，断言摘要的 JSON 里没有它。
    @Test func summaryHasNoNamesOrAddresses() throws {
        var config = AppConfig.makeDefault()
        config.profiles[0].intel = IntelSettings(enabled: true,
                                                 channels: [ChannelRef(name: "SECRET-CHANNEL", id: "player_SECRET")],
                                                 referenceSystem: "SECRET-SYSTEM",
                                                 overlay: OverlayPanelSettings(frame: ScreenRect(x: 1, y: 2, width: 300,
                                                                                                 height: 200)))
        config.profiles[0].translation = TranslationSettings(enabled: true, channels: [.local, .corp],
                                                             targetLanguage: .ja)
        config.general.translationEndpoint = TranslationEndpointSettings(provider: .custom,
                                                                         baseURL: "https://SECRET.example",
                                                                         model: "SECRET-MODEL")
        let summary = ConfigSummary(config: config, loadErrorKind: nil, warningKinds: [])
        let json = String(decoding: summary.encodedJSON(), as: UTF8.self)
        #expect(!json.localizedCaseInsensitiveContains("SECRET"))
        let intel = summary.activeProfile.intel
        #expect(intel.enabled && intel.channelCount == 1 && intel.hasReferenceSystem && intel.hasCustomFrame)
        #expect(intel.resolvePilotNames)
        let translation = summary.activeProfile.translation
        #expect(translation.channelCount == 2 && translation.targetLanguage == .ja && translation.provider == .custom)
        #expect(translation.hasCustomBaseURL && translation.hasCustomModel)
    }

    /// IntelSummary 带 resolvePilotNames（6.9 节），JSON 里是同名的布尔值。
    @Test func intelSummaryResolvePilotNames() throws {
        let off = IntelSummary(IntelSettings(enabled: true, resolvePilotNames: false))
        #expect(!off.resolvePilotNames && off.enabled)
        #expect(IntelSummary(IntelSettings()).resolvePilotNames)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
        #expect(object["resolvePilotNames"] as? Bool == false)
    }

    /// 默认设置的摘要：都关闭，没有自定的地址与模型。
    @Test func defaultSummary() {
        let summary = ConfigSummary(config: AppConfig.makeDefault(), loadErrorKind: nil, warningKinds: [])
        #expect(summary.activeProfile.intel == IntelSummary(IntelSettings()))
        #expect(!summary.activeProfile.translation.hasCustomBaseURL && !summary.activeProfile.translation.enabled)
    }

    /// summary.md 多出聊天日志、星图数据、翻译与人名核对 4 行；不传时取默认值。
    @Test func runtimeLines() {
        let runtime = RuntimeSummary(uiLanguage: "en", screenRecordingGranted: true, accessibilityGranted: true,
                                     combatLogStatus: "stopped", chatLogStatus: "watching (3 files)",
                                     staticData: "build-3720952", translationStatus: "blocked",
                                     pilotLookupStatus: "resolving", characterClients: 0,
                                     loginClients: 0, unknownClients: 0, captureStates: [:], hotkeyBindings: 0,
                                     hotkeyFailures: [:], screens: [], uptimeSeconds: 1, previousRun: "clean",
                                     isFakeMode: false)
        #expect(runtime.chatLogStatus == "watching (3 files)" && runtime.translationStatus == "blocked")
        #expect(runtime.pilotLookupStatus == "resolving")
        let defaults = RuntimeSummary(uiLanguage: "en", screenRecordingGranted: true, accessibilityGranted: true,
                                      combatLogStatus: "stopped", characterClients: 0, loginClients: 0,
                                      unknownClients: 0, captureStates: [:], hotkeyBindings: 0, hotkeyFailures: [:],
                                      screens: [], uptimeSeconds: 1, previousRun: "clean", isFakeMode: false)
        #expect(defaults.chatLogStatus == "stopped" && defaults.staticData == "notLoaded")
        #expect(defaults.translationStatus == "off" && defaults.pilotLookupStatus == "off")
        let text = DiagnosticsSummaryTests.sampleReport().markdown(generatedAt: Date(timeIntervalSince1970: 0))
        #expect(text.contains("- Chat log: stopped"))
        #expect(text.contains("- Map data: notLoaded"))
        #expect(text.contains("- Translation: off"))
        #expect(text.contains("- Pilot lookup: off"))
    }
}
