// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的内容（v1.1 设计 7.1～7.3 节、7.5 节）。全部在内存里，用户确认之前不写任何文件。
//
// 1. `snapshot`：在主线程取快照，含运行时摘要、配置摘要与角色名清单。
// 2. `collect`：在后台读系统信息、本机名字、日志文件的末尾与崩溃报告，用 `Redactor` 处理每个文件，得到预览项。
// 3. 用户确认后，`manifestItem` 按勾选的文件生成 `manifest.json`，`issueDraft` 生成脱敏后的 Issue 草稿。
//
// 压缩包里的文件名都是应用自己起的：`summary.md`、`config-summary.json`、`logs/<日志文件名>`、
// `crash/crash-N.ips`（按从新到旧编号，不沿用原文件名；macOS 14 起只有 `.ips`）、`manifest.json`。

import Foundation
import EVEOPreviewCore

/// 报告里的一个文件（预览与压缩包共用）。内容已脱敏。
struct ReportItem: Sendable, Identifiable, Equatable {
    /// 文件的种类，决定列表里显示的名称。
    enum Kind: Sendable, Equatable {
        case summary, config, log, crash(Int), manifest
    }

    /// 种类。
    let kind: Kind
    /// 压缩包里的相对路径，也是列表里的标识。
    let relativePath: String
    /// 脱敏后的内容（UTF-8）。
    let contents: Data
    /// 预览显示的文字：超过 `previewLimit` 个字符时只取开头。
    let previewText: String
    /// 预览是否只显示了开头。
    let isPreviewTruncated: Bool
    /// 替换次数。
    let counts: RedactionCounts

    /// 预览最多显示多少个字符。
    static let previewLimit = 200_000

    var id: String { relativePath }

    /// `summary.md` 与 `manifest.json` 不能取消勾选。
    var isRequired: Bool { kind == .summary || kind == .manifest }

    /// 用脱敏后的文字建一项。
    init(kind: Kind, relativePath: String, redacted text: String, counts: RedactionCounts) {
        self.kind = kind
        self.relativePath = relativePath
        contents = Data(text.utf8)
        let truncated = text.count > ReportItem.previewLimit
        previewText = truncated ? String(text.prefix(ReportItem.previewLimit)) : text
        isPreviewTruncated = truncated
        self.counts = counts
    }
}

/// 在主线程取的快照，交给后台收集。
struct ProblemReportSnapshot: Sendable {
    /// 情境。
    let context: ProblemReportContext
    /// 运行环境。
    let environment: AppEnvironment
    /// 运行时摘要。
    let runtime: RuntimeSummary
    /// 配置摘要。
    let config: ConfigSummary
    /// 全部配置方案与在线客户端的角色名。
    let characterNames: [String]
    /// 日志目录。
    let logDirectory: URL
    /// 平台服务。
    let diagnostics: any DiagnosticsService
    /// 取快照的时刻。
    let takenAt: Date
}

/// 收集的结果：预览项（不含 `manifest.json`）与生成时要用的部分。
struct ProblemReportContents: Sendable {
    /// 快照。
    let snapshot: ProblemReportSnapshot
    /// 环境报告。
    let report: EnvironmentReport
    /// 脱敏器，Issue 草稿与 `manifest.json` 也用它。
    let redactor: Redactor
    /// 预览项：摘要、配置摘要、日志、崩溃报告。
    let items: [ReportItem]

    /// 崩溃报告的个数。
    var crashCount: Int {
        items.filter { if case .crash = $0.kind { return true } else { return false } }.count
    }
}

/// 问题报告内容的收集与生成。
enum ProblemReportBuilder {
    /// 手动情境取最近几天内的崩溃报告。
    static let manualCrashWindowDays: Double = 7

    // MARK: - 第 1 步：主线程快照

    /// 在主线程取快照：运行时摘要、配置摘要、角色名清单。
    @MainActor static func snapshot(coordinator: AppCoordinator, environment: AppEnvironment,
                                    context: ProblemReportContext, launchUptime: Double,
                                    pendingCrash: PendingCrash?) -> ProblemReportSnapshot {
        let config = coordinator.config
        let online = coordinator.registry.clients.compactMap(\.characterName)
        let configSummary = ConfigSummary(config: config.config, loadErrorKind: config.loadError.map(errorKind),
                                          warningKinds: config.warnings.map(warningKind))
        let runtime = runtimeSummary(coordinator: coordinator, context: context, launchUptime: launchUptime,
                                     pendingCrash: pendingCrash)
        return ProblemReportSnapshot(context: context, environment: environment, runtime: runtime,
                                     config: configSummary,
                                     characterNames: CharacterNameCollector.names(config: config.config, online: online),
                                     logDirectory: LogBootstrap.logDirectory(),
                                     diagnostics: coordinator.services.diagnostics,
                                     takenAt: Date())
    }

    /// 协调器的运行时摘要。只有状态名与数量，不含路径与名字。
    @MainActor private static func runtimeSummary(coordinator: AppCoordinator, context: ProblemReportContext,
                                                  launchUptime: Double, pendingCrash: PendingCrash?) -> RuntimeSummary {
        let clients = coordinator.registry.clients
        var captureStates: [String: Int] = [:]
        for state in coordinator.captureStates.values {
            captureStates[captureStateName(state), default: 0] += 1
        }
        var failures: [String: Int] = [:]
        for failure in coordinator.hotkeyFailures {
            failures[caseName(failure.reason), default: 0] += 1
        }
        let screens = coordinator.screens.map { screen in
            let scale = screen.scale.rounded() == screen.scale ? String(Int(screen.scale)) : String(screen.scale)
            return "\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(scale)x" + (screen.isMain ? " main" : "")
        }
        return RuntimeSummary(
            uiLanguage: L10n.language.rawValue, screenRecordingGranted: coordinator.permissions.screenRecording,
            accessibilityGranted: coordinator.permissions.accessibility,
            combatLogStatus: combatLogStatusName(coordinator.combatLogStatus),
            characterClients: clients.filter { $0.characterName != nil }.count,
            loginClients: clients.filter { $0.identity == .login }.count,
            unknownClients: clients.filter { $0.identity == .unknown }.count,
            captureStates: captureStates, hotkeyBindings: coordinator.hotkeyPlan.bindings.count,
            hotkeyFailures: failures, screens: screens,
            uptimeSeconds: max(0, Int(ProcessInfo.processInfo.systemUptime - launchUptime)),
            previousRun: previousRunName(coordinator.sessionTracker?.previousRun, context: context,
                                         pendingCrash: pendingCrash),
            isFakeMode: coordinator.isFakeMode)
    }

    /// 上一次运行的归类名。异常结束且有对应的崩溃报告时是 `crashed`。
    private static func previousRunName(_ outcome: PreviousRunOutcome?, context: ProblemReportContext,
                                        pendingCrash: PendingCrash?) -> String {
        switch outcome {
        case .none, .noRecord: return "noRecord"
        case .clean: return "clean"
        case .stillRunning: return "stillRunning"
        case .abnormal(let marker):
            if case .crash = context { return "crashed" }
            return pendingCrash?.sessionID == marker.sessionID ? "crashed" : "abnormal"
        }
    }

    /// 捕获状态的名字。
    private static func captureStateName(_ state: CaptureState) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running: return "running"
        case .retrying: return "retrying"
        case .stoppedByUser: return "stoppedByUser"
        case .permissionDenied: return "permissionDenied"
        case .windowGone: return "windowGone"
        }
    }

    /// 游戏日志跟踪服务的状态名，只带文件数，不带路径。
    private static func combatLogStatusName(_ status: CombatLogStatus) -> String {
        switch status {
        case .stopped: return "stopped"
        case .watching(_, let files): return "watching (\(files) files)"
        case .directoryNotFound: return "directoryNotFound"
        case .accessDenied: return "accessDenied"
        }
    }

    /// 读配置的错误类别名，不带路径与说明。
    private static func errorKind(_ error: ConfigError) -> String {
        switch error {
        case .newerSchema: return "newerSchema"
        case .ioFailure(let operation, _, _): return "ioFailure.\(operation.rawValue)"
        case .encodingFailure: return "encodingFailure"
        }
    }

    /// 读配置的警告类别名，不带路径。
    private static func warningKind(_ warning: ConfigWarning) -> String {
        caseName(warning)
    }

    /// 枚举值的名字，去掉关联值（如 `registrationRejected(status: -9878)` → `registrationRejected`）。
    private static func caseName<T>(_ value: T) -> String {
        let text = String(describing: value)
        return text.firstIndex(of: "(").map { String(text[..<$0]) } ?? text
    }

    // MARK: - 第 2 步：后台收集

    /// 在 GCD 的后台队列上收集，不占主线程与 Swift 并发的协作线程（读文件是阻塞的）。
    static func collectInBackground(_ snapshot: ProblemReportSnapshot) async -> ProblemReportContents {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: collect(snapshot))
            }
        }
    }

    /// 读系统信息、本机名字、日志与崩溃报告，逐个脱敏。阻塞调用，只在后台线程上用。
    static func collect(_ snapshot: ProblemReportSnapshot) -> ProblemReportContents {
        let diagnostics = snapshot.diagnostics
        let names = diagnostics.sensitiveNames()
        let redactor = Redactor(terms: RedactionTerms(userNames: [names.userName, names.fullUserName],
                                                      hostNames: names.hostNames,
                                                      characterNames: snapshot.characterNames,
                                                      homeDirectory: names.homeDirectory))
        let report = EnvironmentReport(app: snapshot.environment, system: diagnostics.systemInfo(),
                                       runtime: snapshot.runtime)
        var items: [ReportItem] = []
        func add(_ kind: ReportItem.Kind, _ path: String, _ text: String) {
            let result = redactor.redact(text)
            items.append(ReportItem(kind: kind, relativePath: path, redacted: result.text, counts: result.counts))
        }
        add(.summary, "summary.md", report.markdown(generatedAt: snapshot.takenAt))
        add(.config, "config-summary.json", String(decoding: snapshot.config.encodedJSON(), as: UTF8.self))
        for log in readLogs(in: snapshot.logDirectory) {
            add(.log, "logs/\(log.name)", log.text)
        }
        for (index, text) in readCrashReports(snapshot).enumerated() {
            add(.crash(index + 1), "crash/crash-\(index + 1).ips", text)
        }
        return ProblemReportContents(snapshot: snapshot, report: report, redactor: redactor, items: items)
    }

    /// 按 `DiagnosticsBundlePlanner.logSlices` 读日志文件的末尾，最新的在前。
    /// 截断的文件从第一个换行之后开始，不留半行。
    private static func readLogs(in directory: URL) -> [(name: String, text: String)] {
        let urls = LogFileLayout(directory: directory).existingURLs()
        let sizes = urls.map { url in
            (name: url.lastPathComponent,
             bytes: ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0)
        }
        var result: [(name: String, text: String)] = []
        for slice in DiagnosticsBundlePlanner.logSlices(fileSizes: sizes) {
            guard let size = sizes.first(where: { $0.name == slice.name })?.bytes,
                  let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(slice.name)) else {
                continue
            }
            defer { try? handle.close() }
            let offset = UInt64(max(0, size - slice.tailBytes))
            guard (try? handle.seek(toOffset: offset)) != nil,
                  var data = try? handle.read(upToCount: slice.tailBytes) else { continue }
            if offset > 0, let newline = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            }
            result.append((slice.name, String(decoding: data, as: UTF8.self)))
        }
        return result
    }

    /// 崩溃报告的内容，从新到旧，最多 `CrashReportMatcher.maxReports` 个。
    /// 崩溃情境取 `PendingCrash.reportFileNames`；手动情境取最近 7 天内的报告。
    /// `reportFileNames` 来自 state.json，读之前再用 `isCandidateName` 核对一次（不含 `/`、前缀与扩展名都对）。
    private static func readCrashReports(_ snapshot: ProblemReportSnapshot) -> [String] {
        let diagnostics = snapshot.diagnostics
        let fileNames: [String]
        switch snapshot.context {
        case .crash(let crash):
            let executable = snapshot.environment.executableName
            fileNames = crash.reportFileNames.filter {
                CrashReportMatcher.isCandidateName($0, executableName: executable)
            }
        case .manual:
            let now = snapshot.takenAt
            let candidates = diagnostics.crashReportCandidates(executableName: snapshot.environment.executableName)
            fileNames = CrashReportMatcher.select(
                from: candidates, executableName: snapshot.environment.executableName,
                bundleID: snapshot.environment.bundleIdentifier,
                window: now.addingTimeInterval(-manualCrashWindowDays * 86_400)...now.addingTimeInterval(5)
            ).map(\.fileName)
        }
        let maxBytes = CrashReportMatcher.maxReportBytes
        return fileNames.prefix(CrashReportMatcher.maxReports).compactMap { name in
            guard var data = diagnostics.readCrashReport(named: name, maxBytes: maxBytes) else { return nil }
            // 读到上限时文件可能被截断，去掉末尾不完整的一行。
            if data.count >= maxBytes, let newline = data.lastIndex(of: 0x0A) {
                data = data.subdata(in: data.startIndex..<data.index(after: newline))
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - 第 3 步：生成

    /// 按勾选的文件生成 `manifest.json`（不含它自己）。
    static func manifestItem(for items: [ReportItem], contents: ProblemReportContents, generatedAt: Date) -> ReportItem {
        let context: String
        switch contents.snapshot.context {
        case .manual: context = "manual"
        case .crash: context = "crash"
        }
        let manifest = DiagnosticsManifest(
            appVersion: contents.snapshot.environment.version, buildLabel: contents.snapshot.environment.buildLabel,
            generatedAt: generatedAt, context: context,
            files: items.map { .init(path: $0.relativePath, bytes: $0.contents.count, replacements: $0.counts) })
        let result = contents.redactor.redact(String(decoding: manifest.encodedJSON(), as: UTF8.self))
        return ReportItem(kind: .manifest, relativePath: "manifest.json", redacted: result.text, counts: result.counts)
    }

    /// Issue 草稿：按 7.5 节拼出，标题与每节内容再经 `Redactor` 处理一次（第二道保险）。
    static func issueDraft(contents: ProblemReportContents, archiveFileName: String) -> IssueDraft {
        let crash: PendingCrash?
        if case .crash(let pending) = contents.snapshot.context { crash = pending } else { crash = nil }
        var draft = IssueURLBuilder.problemReportDraft(isCrash: crash != nil, environment: contents.report,
                                                       previousVersion: crash?.appVersion,
                                                       crashReportCount: contents.crashCount,
                                                       archiveFileName: archiveFileName)
        draft.title = contents.redactor.redact(draft.title).text
        for index in draft.sections.indices {
            draft.sections[index].body = contents.redactor.redact(draft.sections[index].body).text
        }
        return draft
    }

    /// 在 GCD 的后台队列上写压缩包（`writeArchive` 是阻塞调用）。
    static func writeArchive(_ diagnostics: any DiagnosticsService, named name: String,
                             files: [DiagnosticsFile]) async -> Result<URL, DiagnosticsIOError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do throws(DiagnosticsIOError) {
                    continuation.resume(returning: .success(try diagnostics.writeArchive(named: name, files: files)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }
}
