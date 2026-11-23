// SPDX-License-Identifier: GPL-3.0-or-later
//
// 星图数据文件的查找与读取（docs/macos/design-intel-translate.md 4.4 节）。按顺序找 eve-static.json：
// 1. 环境变量 EVEO_STATIC_DATA 指定的路径（只用于调试）。
// 2. ~/Library/Application Support/EVE-O Preview/eve-static.json（用户手动覆盖）。
// 3. Bundle.main.resourceURL 下的 eve-static.json（macos/scripts/build-app.sh 复制进去的）。
// 4. 从可执行文件所在目录向上找，至多 6 级，第一个含 shared/static/eve-static.json 的目录（swift run 与探针用）。
// 取第一个存在的；第 2 条与第 3 条都存在时两个都解码，取 sdeBuild 较大的。第 2 条无效时记一条日志，接着看后面的。
// 读文件与解码在调用方的后台任务里做（load 是非隔离的 async 方法），数据在本次运行内不变。

import Foundation
import EVEOPreviewCore

/// 从应用包、用户目录或仓库读星图数据。
public struct BundleStaticDataProvider: StaticDataProvider {
    /// 一个候选文件。
    public struct Candidate: Sendable, Equatable {
        /// 来源：`environment`、`userOverride`、`bundle`、`repository`。
        public var source: String
        /// 文件位置。
        public var url: URL

        /// 用来源与位置建一个候选。
        public init(source: String, url: URL) {
            self.source = source
            self.url = url
        }
    }

    /// 数据文件的文件名。
    public static let fileName = "eve-static.json"
    /// 从可执行文件所在目录向上找仓库的层数。
    static let repositorySearchDepth = 6

    private let log = PlatformLog.logger("StaticData")

    /// 建提供者，不读文件。
    public init() {}

    /// 按 4.4 节的顺序列出候选文件（不管是否存在），探针用它打印查找过程。
    public func candidates() -> [Candidate] {
        var result: [Candidate] = []
        if let path = ProcessInfo.processInfo.environment["EVEO_STATIC_DATA"], !path.isEmpty {
            result.append(Candidate(source: "environment",
                                    url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
        }
        let support = JSONStateStore.defaultFileURL().deletingLastPathComponent()
        result.append(Candidate(source: "userOverride", url: support.appendingPathComponent(Self.fileName)))
        if let resources = Bundle.main.resourceURL {
            result.append(Candidate(source: "bundle", url: resources.appendingPathComponent(Self.fileName)))
        }
        if let repository = repositoryFile() {
            result.append(Candidate(source: "repository", url: repository))
        }
        return result
    }

    /// 读并解码。规则见文件头的说明。
    public func load() async -> StaticDataLoadResult {
        let existing = candidates().filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !existing.isEmpty else { return .missing }
        // 调试用的环境变量优先，存在时只用它。
        if let debug = existing.first(where: { $0.source == "environment" }) {
            return decode(debug)
        }
        var remaining = existing
        if let override = existing.first(where: { $0.source == "userOverride" }) {
            remaining.removeAll { $0.source == "userOverride" }
            let overrideResult = decode(override)
            guard case .loaded(let overrideData, _) = overrideResult else {
                log.notice("手动覆盖的星图数据无效，改用应用自带的数据")
                return remaining.isEmpty ? overrideResult : decodeFirst(remaining)
            }
            // 应用包里也有数据时，两个都解码，取 SDE 版本较新的。
            if let bundle = remaining.first(where: { $0.source == "bundle" }),
               case .loaded(let bundleData, _) = decode(bundle), bundleData.sdeBuild >= overrideData.sdeBuild {
                return .loaded(bundleData, source: "bundle")
            }
            return overrideResult
        }
        return decodeFirst(remaining)
    }

    // MARK: - 内部

    /// 解码第一个候选；它无效时返回它的结果（不再往后找，保持「取第一个存在的」）。
    private func decodeFirst(_ candidates: [Candidate]) -> StaticDataLoadResult {
        guard let first = candidates.first else { return .missing }
        return decode(first)
    }

    /// 读一个候选文件并解码。
    private func decode(_ candidate: Candidate) -> StaticDataLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: candidate.url)
        } catch {
            log.error("读星图数据失败：\(candidate.url.path, privacy: .private)")
            // 说明只写错误的域与代码，不写系统给的描述（里面有文件路径，可能含主目录，审查 nit b）。
            let nsError = error as NSError
            return .invalid(.unreadable("\(nsError.domain) \(nsError.code)"))
        }
        do {
            let decoded = try EVEStaticData.decode(data)
            log.info("星图数据：来源 \(candidate.source, privacy: .public)，SDE 版本 \(decoded.sdeBuild)")
            return .loaded(decoded, source: candidate.source)
        } catch {
            log.error("星图数据无效：\(error.logName, privacy: .public)")
            return .invalid(error)
        }
    }

    /// 从可执行文件所在目录向上找 shared/static/eve-static.json，至多 6 级。
    private func repositoryFile() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<Self.repositorySearchDepth {
            let file = directory.appendingPathComponent("shared").appendingPathComponent("static")
                .appendingPathComponent(Self.fileName)
            if FileManager.default.fileExists(atPath: file.path) { return file }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
