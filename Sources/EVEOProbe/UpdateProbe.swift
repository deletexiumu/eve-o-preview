// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新的探针命令（v1.1 设计 9.6 节），供 WP-3 在不运行应用的情况下核对平台代码：
//   update feed [地址] [--running 版本] [--etag 值]
//       请求并解析发布信息，打印版本、附件与 `UpdatePolicy.offer` 的结果。
//       不给地址时请求正式地址；--running 是假定正在运行的版本（默认 0.0.0）。
//   update verify <新应用> <基准应用>
//       读基准应用的指定要求，对新应用做 9.3 节第 6 步的核对，打印返回值。
//   update prepare <地址> [--cache 目录] [--running 版本]
//       运行 9.2 节的下载与核对，打印 dmg 的位置与 SHA-256。
//   update install <dmg> <已安装的应用> --version 版本 [--cache 目录] [--cleanup]
//       设计表外的命令：对一份应用副本走一遍 9.3 节的 12 步（不重新启动，不登记到 LaunchServices）。
//       「正在运行的应用」取已安装的那一份的签名、版本与位置。只用于临时目录里的副本。
//       --cleanup：成功后再按下次启动的规则调 `removeLeftovers` 删旧包。
//
// 使用测试地址的命令要求地址通过 `UpdateFeed.resolve`（https，或回环主机的 http）。

import CryptoKit
import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// `update` 命令的分发。
@MainActor enum UpdateProbe {
    /// 子命令的名字。
    static let subcommands = ["feed", "verify", "prepare", "install"]

    /// 解析子命令并执行，返回进程退出码：参数不对时 2，失败时 1。
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first, subcommands.contains(command) else { return usage() }
        let rest = Array(args.dropFirst())
        switch command {
        case "feed": return await feed(rest)
        case "verify": return verify(rest)
        case "prepare": return await prepare(rest)
        case "install": return await install(rest)
        default: return usage()
        }
    }

    /// 打印 `update` 的用法，返回 2。
    static func usage() -> Int32 {
        print("""
        用法：EVEOProbe update feed [地址] [--running 版本] [--etag 值]
              | update verify <新应用> <基准应用>
              | update prepare <地址> [--cache 目录] [--running 版本]
              | update install <dmg> <已安装的应用> --version 版本 [--cache 目录] [--cleanup]
        """)
        return 2
    }

    // MARK: - feed

    /// 请求并解析发布信息，打印结果与 `offer` 的决定。
    static func feed(_ args: [String]) async -> Int32 {
        let positional = positionals(args)
        guard let feed = resolveFeed(positional.first) else { return 2 }
        let running = option("--running", in: args) ?? "0.0.0"
        print("地址：\(feed.feedURL.absoluteString)（测试地址：\(feed.isTestFeed)）")
        let started = ContinuousClock.now
        let result = await ReleaseFeedClient.fetch(feed: feed, etag: option("--etag", in: args), appVersion: running)
        print("耗时 \(Probe.milliseconds(since: started)) 毫秒")
        switch result {
        case .release(let info, let etag):
            printRelease(info)
            print("ETag：\(etag ?? "nil")")
            let offer = UpdatePolicy.offer(release: info, running: environment(version: running),
                                           skippedVersion: nil, userInitiated: false)
            print("offer（正在运行 \(running)）：\(offer.summary)")
            if let pair = try? UpdateAssetContract.assets(in: info, feed: feed) {
                print("契约附件：\(pair.image.name)、\(pair.checksums.name)")
            } else {
                do {
                    _ = try UpdateAssetContract.assets(in: info, feed: feed)
                } catch {
                    print("契约附件：\(error)")
                }
            }
            return 0
        default:
            print("结果：\(result)")
            return result == .notModified || result == .noRelease ? 0 : 1
        }
    }

    // MARK: - verify

    /// 读基准应用的指定要求，核对新应用，打印返回值。返回值为 0 时退出码 0，否则 1。
    static func verify(_ args: [String]) -> Int32 {
        let positional = positionals(args)
        guard positional.count == 2 else { return usage() }
        let candidate = URL(fileURLWithPath: positional[0])
        let base = URL(fileURLWithPath: positional[1])
        let baseInfo = CodeSignatureVerifier.signatureInfo(at: base)
        print("基准：类别 \(baseInfo.kind.rawValue)，签名者 \(baseInfo.signerName ?? "nil")")
        print("基准的指定要求：\(baseInfo.designatedRequirement ?? "nil")")
        let candidateInfo = CodeSignatureVerifier.signatureInfo(at: candidate)
        print("新应用：类别 \(candidateInfo.kind.rawValue)，签名者 \(candidateInfo.signerName ?? "nil")")
        guard let requirement = baseInfo.designatedRequirement else {
            print("基准没有指定要求，无法核对")
            return 1
        }
        let started = ContinuousClock.now
        let status = CodeSignatureVerifier.check(bundleAt: candidate, requirement: requirement)
        let mapped = CodeSignatureVerifier.error(for: status).map { "\($0)" } ?? "通过"
        print("SecStaticCodeCheckValidityWithErrors = \(status)（\(mapped)），耗时 \(Probe.milliseconds(since: started)) 毫秒")
        return status == 0 ? 0 : 1
    }

    // MARK: - prepare

    /// 运行下载与核对，打印 dmg 的位置与 SHA-256。不给 --cache 时用临时目录，不碰用户的缓存。
    static func prepare(_ args: [String]) async -> Int32 {
        guard let address = positionals(args).first, let feed = resolveFeed(address) else { return usage() }
        let running = option("--running", in: args) ?? "0.0.0"
        let fetched = await ReleaseFeedClient.fetch(feed: feed, etag: nil, appVersion: running)
        guard case .release(let release, _) = fetched else {
            print("检查失败：\(fetched)")
            return 1
        }
        printRelease(release)
        let service = SystemUpdateService(cacheDirectory: cacheDirectory(args), registersWithLaunchServices: false)
        let started = ContinuousClock.now
        let result = await service.prepare(release, feed: feed) { progress in
            print("  进度 \(progress.receivedBytes) / \(progress.totalBytes.map(String.init) ?? "?")")
        }
        print("耗时 \(Probe.milliseconds(since: started)) 毫秒")
        switch result {
        case .success(let prepared):
            print("dmg：\(prepared.imagePath)")
            print("SHA-256：\(prepared.sha256)")
            return 0
        case .failure(let error):
            print("失败：\(error)")
            return 1
        }
    }

    // MARK: - install

    /// 对一份应用副本走一遍 9.3 节的 12 步。「正在运行的应用」取已安装的那一份。
    ///
    /// 是否使用测试地址按环境变量 `EVEO_UPDATE_FEED_URL` 判断（与应用相同）；开发证书签名的副本要设它才能装。
    static func install(_ args: [String]) async -> Int32 {
        let positional = positionals(args)
        guard positional.count == 2, let version = option("--version", in: args) else { return usage() }
        let image = URL(fileURLWithPath: positional[0])
        let installed = URL(fileURLWithPath: positional[1], isDirectory: true)
        guard let sha256 = sha256(of: image) else {
            print("读不了 \(image.path)")
            return 1
        }
        let running = environment(ofBundle: installed)
        print("已安装：\(running.bundleIdentifier) \(running.version)（标签 \(running.buildLabel)），"
              + "签名 \(running.signature.kind.rawValue)，位置 \(running.location.rawValue)，"
              + "可写 \(running.isLocationWritable)")
        let isTestFeed = UpdateFeed.resolve(override: ProcessInfo.processInfo.environment["EVEO_UPDATE_FEED_URL"])
            .isTestFeed
        print("能否安装（测试地址 \(isTestFeed)）：\(UpdatePolicy.capability(for: running, isTestFeed: isTestFeed))")
        let prepared = PreparedUpdate(version: version, imagePath: image.path, sha256: sha256, preparedAt: Date())
        let service = SystemUpdateService(cacheDirectory: cacheDirectory(args), registersWithLaunchServices: false)
        let started = ContinuousClock.now
        let result = await service.install(prepared, environment: running)
        print("耗时 \(Probe.milliseconds(since: started)) 毫秒")
        switch result {
        case .success(let outcome):
            print("已安装 \(outcome.installedVersion)，旧包所在的暂存目录：\(outcome.stagingPath)")
            let now = UpdateProbe.environment(ofBundle: installed)
            print("安装后：\(now.version)（标签 \(now.buildLabel)）")
            if args.contains("--cleanup") {
                // 模拟下次启动：按 removeLeftovers 的规则删旧包。
                await service.removeLeftovers(keeping: nil, staleStagingPath: outcome.stagingPath)
                print("removeLeftovers 后旧包目录\(FileManager.default.fileExists(atPath: outcome.stagingPath) ? "仍在" : "已删除")")
            }
            return 0
        case .failure(let error):
            print("失败：\(error)")
            return 1
        }
    }

    // MARK: - 工具

    /// --cache 指定的缓存目录；没有时用临时目录下的 `EVEOProbe-Updates`。
    static func cacheDirectory(_ args: [String]) -> URL {
        if let path = option("--cache", in: args) { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("EVEOProbe-Updates", isDirectory: true)
    }

    /// 文件的 SHA-256（小写十六进制），口径与下载核对相同。
    static func sha256(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 把一个包当作「正在运行的应用」：版本、签名与位置的取法与 `AppEnvironmentProvider` 相同。
    static func environment(ofBundle bundle: URL) -> AppEnvironment {
        let plistData = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let info = plistData.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            as? [String: Any] ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let parent = bundle.deletingLastPathComponent().path
        return AppEnvironment(bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
                              version: version, buildLabel: info["EVEOBuildLabel"] as? String ?? version,
                              buildCommit: info["EVEOBuildCommit"] as? String, bundlePath: bundle.path,
                              executableName: info["CFBundleExecutable"] as? String ?? "",
                              signature: CodeSignatureVerifier.signatureInfo(at: bundle),
                              location: AppEnvironmentRules.locationKind(bundlePath: bundle.path,
                                                                         homeDirectory: NSHomeDirectory(),
                                                                         isReadOnlyVolume: readOnly),
                              isLocationWritable: access(parent, W_OK) == 0 && access(bundle.path, W_OK) == 0)
    }

    /// 解析地址参数：没有时用正式地址；给了但不通过 `UpdateFeed.resolve` 时打印原因并返回 nil。
    static func resolveFeed(_ text: String?) -> UpdateFeed? {
        let feed = UpdateFeed.resolve(override: text)
        if let text, !text.isEmpty, !feed.isTestFeed {
            print("地址 \(text) 不是 https，也不是回环主机的 http，不能用作测试地址")
            return nil
        }
        return feed
    }

    /// 去掉 `--名字 值` 形式的选项后剩下的位置参数。
    static func positionals(_ args: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == "--cleanup" {
                index += 1
            } else if args[index].hasPrefix("--") {
                index += 2
            } else {
                result.append(args[index])
                index += 1
            }
        }
        return result
    }

    /// `--名字 值` 形式的选项的值。
    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// 只用于 `offer` 的运行环境：版本取 version，其余字段不参与判断。
    static func environment(version: String) -> AppEnvironment {
        AppEnvironment(bundleIdentifier: PlatformLog.subsystem, version: version, buildLabel: version, buildCommit: nil,
                       bundlePath: nil, executableName: "EVEOPreview", signature: CodeSignatureInfo(kind: .release),
                       location: .other, isLocationWritable: true)
    }

    /// 打印发布信息（不打印发布说明的全文，只打印长度）。
    static func printRelease(_ info: ReleaseInfo) {
        print("版本：\(info.version)（tag \(info.tagName)），标题：\(info.title)")
        print("发布页：\(info.pageURL)，发布时刻：\(info.publishedAt.map { "\($0)" } ?? "nil")")
        print("草稿 \(info.isDraft)，预发布 \(info.isPrerelease)，发布说明 \(info.notes.count) 个字符")
        print("附件 \(info.assets.count) 个：")
        for asset in info.assets {
            print("  \(asset.name)  \(asset.size.map(String.init) ?? "?") 字节  \(asset.downloadURL)")
        }
    }
}

extension UpdateOffer {
    /// 一行摘要。
    var summary: String {
        switch self {
        case .none(let reason): return "不提示（\(reason)）"
        case .offer(let release): return "提示 \(release.version)"
        }
    }
}
