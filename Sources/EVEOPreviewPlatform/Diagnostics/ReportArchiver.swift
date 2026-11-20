// SPDX-License-Identifier: GPL-3.0-or-later
//
// 生成报告的压缩包，并在访达与浏览器里打开（v1.1 设计 7.2 节）。
//
// `writeArchive` 的步骤：
// 1. 建 `~/Library/Application Support/EVE-O Preview/Reports/`（权限 0700），在下面建与压缩包同名的文件夹并写入各文件。
//    相对路径是应用自己起的（如 `logs/eve-o-preview.log`）；含 `..`、以 `/` 开头或为空的路径拒绝写入。
// 2. 运行 `/usr/bin/ditto -c -k --norsrc --keepParent <文件夹> <zip>`（经 `ProcessRunner`，超时 30 秒）。
//    zip 里是同名的文件夹。
// 3. 无论成功与否都删掉文件夹。
// 4. 只保留最新的 3 个报告：只删文件名同时满足「以 `EVE-O-Preview-diagnostics-` 开头」和「以 `.zip` 结尾」的文件。
//    名字里的时刻是 `yyyyMMdd-HHmmss`，按名字排序就是按时间排序。
//
// `writeArchive` 是同步的（协议如此），`ProcessRunner.run` 是异步的：这里用信号量等它完成。
// 调用方应在 GCD 的后台队列上调用，不在主线程、也不在 Swift 并发的协作线程上调用。

import AppKit
import EVEOPreviewCore
import os

/// 报告压缩包的生成与打开。
struct ReportArchiver: Sendable {
    /// 存放报告的目录。
    let reportsDirectory: URL
    /// 只保留最新的几个报告。
    static let keepCount = 3
    /// `ditto` 的超时，单位是秒。
    static let archiveTimeout: Double = 30
    private static let log = PlatformLog.logger("Report")

    /// 默认目录：`~/Library/Application Support/EVE-O Preview/Reports`。
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EVE-O Preview/Reports", isDirectory: true)
    }

    /// 用存放目录建生成器，默认是 `defaultDirectory()`。
    init(reportsDirectory: URL = ReportArchiver.defaultDirectory()) {
        self.reportsDirectory = reportsDirectory
    }

    /// 把 files 写进以 name 命名的文件夹并压成 zip，返回 zip 的位置；同时只保留最新的 3 个报告。
    func writeArchive(named name: String, files: [DiagnosticsFile]) throws(DiagnosticsIOError) -> URL {
        guard ReportArchiver.isSafeComponent(name) else {
            throw .writeFailed(path: name, reason: "invalid report name")
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: reportsDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw .writeFailed(path: reportsDirectory.path, reason: error.localizedDescription)
        }
        let folder = reportsDirectory.appendingPathComponent(name, isDirectory: true)
        let zip = reportsDirectory.appendingPathComponent(name + ".zip", isDirectory: false)
        // 同一秒里重复生成时覆盖同名的文件夹与 zip。
        try? fileManager.removeItem(at: folder)
        try? fileManager.removeItem(at: zip)
        defer { try? fileManager.removeItem(at: folder) }
        try writeFiles(files, into: folder)
        try runDitto(folder: folder, zip: zip)
        prune()
        ReportArchiver.log.info("已生成报告：\(zip.lastPathComponent, privacy: .public)，\(files.count) 个文件")
        return zip
    }

    /// 在访达里显示并选中文件。
    @MainActor func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 用默认浏览器打开地址。只打开 `https` 地址。
    @MainActor func openInBrowser(_ url: URL) {
        guard url.scheme?.lowercased() == "https" else {
            ReportArchiver.log.error("拒绝打开不是 https 的地址")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 步骤

    /// 把各文件写进 folder。相对路径不合规时拒绝。
    private func writeFiles(_ files: [DiagnosticsFile], into folder: URL) throws(DiagnosticsIOError) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw .writeFailed(path: folder.path, reason: error.localizedDescription)
        }
        for file in files {
            let components = file.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !file.relativePath.hasPrefix("/"), !components.isEmpty,
                  components.allSatisfy(ReportArchiver.isSafeComponent) else {
                throw .writeFailed(path: file.relativePath, reason: "invalid relative path")
            }
            let target = components.reduce(folder) { $0.appendingPathComponent($1) }
            do {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                try file.contents.write(to: target, options: .atomic)
            } catch {
                throw .writeFailed(path: target.path, reason: error.localizedDescription)
            }
        }
    }

    /// 运行 ditto 压缩 folder。启动失败、超时或退出码不为 0 时抛 `archiveFailed`。
    private func runDitto(folder: URL, zip: URL) throws(DiagnosticsIOError) {
        let arguments = ["-c", "-k", "--norsrc", "--keepParent", folder.path, zip.path]
        let outcome = ReportArchiver.runBlocking("/usr/bin/ditto", arguments: arguments,
                                                 timeout: ReportArchiver.archiveTimeout)
        switch outcome {
        case .failure(.launchFailed(let reason)):
            throw .archiveFailed(reason: "ditto: \(reason)")
        case .failure(.timedOut):
            try? FileManager.default.removeItem(at: zip)
            throw .archiveFailed(reason: "ditto timed out")
        case .success(let result) where result.status != 0:
            try? FileManager.default.removeItem(at: zip)
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw .archiveFailed(reason: "ditto exit \(result.status): \(detail)")
        case .success:
            guard FileManager.default.fileExists(atPath: zip.path) else {
                throw .archiveFailed(reason: "ditto produced no file")
            }
        }
    }

    /// 只保留最新的 keepCount 个报告。只删名字符合规则的普通文件，删除失败只记日志。
    func prune() {
        let prefix = DiagnosticsBundlePlanner.archivePrefix
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: reportsDirectory.path) else { return }
        let reports = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".zip") }.sorted(by: >)
        for name in reports.dropFirst(ReportArchiver.keepCount) {
            let url = reportsDirectory.appendingPathComponent(name, isDirectory: false)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ReportArchiver.log.error("删除旧报告失败：\(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - 小工具

    /// 路径的一段是否安全：不为空，不是 `.` 或 `..`，不含 `/` 与 NUL。
    static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\0")
    }

    /// 在当前线程上同步等待 `ProcessRunner.run`。只在 GCD 的后台队列上调用。
    ///
    /// `ProcessRunner` 自己在 GCD 队列上等待进程，这里阻塞的线程不参与它的执行，不会互相等待。
    private static func runBlocking(_ executable: String, arguments: [String], timeout: Double)
        -> Result<ProcessResult, ProcessRunnerError> {
        let box = OSAllocatedUnfairLock<Result<ProcessResult, ProcessRunnerError>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let result: Result<ProcessResult, ProcessRunnerError>
            do throws(ProcessRunnerError) {
                result = .success(try await ProcessRunner.run(executable, arguments: arguments, timeout: timeout))
            } catch {
                result = .failure(error)
            }
            box.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 } ?? .failure(.launchFailed("no result"))
    }
}
