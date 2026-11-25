// SPDX-License-Identifier: GPL-3.0-or-later
//
// 下载与核对（v1.1 设计 9.2 节）。步骤：
// 1. 用 `UpdateAssetContract.assets(in:feed:)` 取 dmg 与 `SHA256SUMS.txt`，缺任何一个时返回 `assetMissing`。
// 2. 附件声明的大小超过 300 MiB 时返回 `downloadTooLarge`；缓存所在卷的可用空间小于「附件大小的 3 倍」
//    （大小未知时按 200 MiB 算）时返回 `insufficientDiskSpace`。
// 3. 清理缓存目录里别的版本的文件，建 `Updates/<版本号>/`。
// 4. 下载 `SHA256SUMS.txt`，超过 65,536 字节时返回 `checksumListInvalid`，取 dmg 的期望值。
// 5. 用 `URLSessionDownloadTask` 把 dmg 下载到 `Updates/<版本号>/<文件名>.partial`。
//    已收字节超过 300 MiB 时取消并返回 `downloadTooLarge`。进度回调每秒最多 10 次。
// 6. 按 1 MiB 一块算 SHA-256（CryptoKit），与期望值比较。不同时删掉文件，返回 `checksumMismatch`。
// 7. 把文件改名去掉 `.partial`，返回 `PreparedUpdate`。
//
// 镜像（1.5.0 起，docs/update-manifest.md 第 4 节第 4 条）：每个附件按 `ReleaseAsset.urls` 的顺序下载（R2 在前、
// GitHub 在后）。一个地址失败（网络错误、状态码不对、超过上限、与清单里的 SHA-256 不符）时删掉半截文件，换下一个地址；
// 都失败时报最后一个错误。取消立即结束，不再换地址。清单里有 SHA-256 时，校验和文件与 dmg 都先与它核对，
// dmg 另外照旧与签过名的校验和文件核对（两者来自同一次发布，应当一致）。
//
// 会话的配置与检查请求相同，自己设的请求头只有 `User-Agent` 与 `Accept-Language: en`。请求超时 60 秒，
// 整个下载最长 10 分钟。重定向只跟随到 https；使用测试地址时也允许跟随到与它同源的 http。
// 重定向后的主机不核对（GitHub 的文件存储域名不固定），内容由清单里的 SHA-256 与 9.3 节的签名核对保证。
//
// 进度：下载完成、开始算 SHA-256 时，再回调一次 receivedBytes == totalBytes 的进度，控制器据此进入「核对中」。

import CryptoKit
import Foundation
import EVEOPreviewCore
import os

/// 下载与核对。一次只有一个下载；`cancel()` 取消进行中的那一个。
final class UpdateDownloader: Sendable {
    /// 缓存目录 `…/Updates`。
    let cacheRoot: URL
    /// 单个请求的超时秒数。
    static let requestTimeout: TimeInterval = 60
    /// 整个下载的最长秒数。
    static let resourceTimeout: TimeInterval = 600
    /// 附件大小未知时按多少字节估算磁盘空间。
    static let unknownSizeEstimate: Int64 = 209_715_200
    /// 进度回调的最小间隔秒数（每秒最多 10 次）。
    static let progressInterval: TimeInterval = 0.1
    /// 算 SHA-256 时每次读的字节数。
    static let hashChunkBytes = 1_048_576

    /// 进行中的下载与是否已被取消。
    private let current = OSAllocatedUnfairLock(initialState: Current())
    private let log = PlatformLog.logger("Updates")

    /// 进行中的状态，用锁保护。
    private struct Current: Sendable {
        /// 进行中的下载；没有时是 nil。
        var operation: DownloadOperation?
        /// 本次 prepare 是否已被取消。
        var cancelled = false
    }

    /// 建下载器。cacheRoot 是 `Updates` 目录，不存在时在下载前创建。
    init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    /// 取消进行中的下载；`prepare` 随后删掉 `.partial` 文件并返回 `.cancelled`。
    func cancel() {
        let operation = current.withLock { state -> DownloadOperation? in
            state.cancelled = true
            return state.operation
        }
        operation?.cancel()
    }

    /// 运行 9.2 节的 7 步。appVersion 用于 `User-Agent`。
    func prepare(_ release: ReleaseInfo, feed: UpdateFeed, appVersion: String,
                 progress: @escaping @Sendable (UpdateProgress) -> Void) async -> Result<PreparedUpdate, UpdateError> {
        current.withLock { $0 = Current() }
        defer { current.withLock { $0.operation = nil } }
        do {
            return .success(try await runSteps(release, feed: feed, appVersion: appVersion, progress: progress))
        } catch {
            if error != .cancelled { log.error("下载更新失败：\(String(describing: error), privacy: .public)") }
            return .failure(error)
        }
    }

    /// 9.2 节的 7 步；任何一步失败时抛出，已建的 `.partial` 文件在抛出前删掉。
    private func runSteps(_ release: ReleaseInfo, feed: UpdateFeed, appVersion: String,
                          progress: @escaping @Sendable (UpdateProgress) -> Void) async throws(UpdateError)
        -> PreparedUpdate {
        // 第 1、2 步：附件与上限。
        let assets = try UpdateAssetContract.assets(in: release, feed: feed)
        let declared = assets.image.size.map(Int64.init)
        if let declared, declared > Int64(UpdateAssetContract.maxImageBytes) { throw .downloadTooLarge }
        // 第 3 步：建版本目录、清理别的版本。可用空间要在目录建好后才能查。
        let versionDirectory = try prepareDirectory(version: release.version)
        let needed = (declared ?? UpdateDownloader.unknownSizeEstimate) * 3
        if let available = availableCapacity(at: versionDirectory), available < needed { throw .insufficientDiskSpace }
        try checkCancelled()

        let configuration = sessionConfiguration(appVersion: appVersion)

        // 第 4 步：校验和文件。
        let checksumsPartial = versionDirectory.appendingPathComponent(UpdateAssetContract.checksumsName + ".partial")
        defer { try? FileManager.default.removeItem(at: checksumsPartial) }
        _ = try await downloadAsset(assets.checksums, to: checksumsPartial,
                                    maxBytes: Int64(UpdateAssetContract.maxChecksumsBytes),
                                    tooLarge: .checksumListInvalid, feed: feed, configuration: configuration,
                                    progress: nil)
        guard let checksumsData = try? Data(contentsOf: checksumsPartial),
              let checksumsText = String(data: checksumsData, encoding: .utf8) else { throw .checksumListInvalid }
        let expected = try ChecksumList.expectedHash(for: assets.image.name, in: checksumsText)
        try checkCancelled()

        // 第 5 步：dmg。
        let finalURL = versionDirectory.appendingPathComponent(assets.image.name)
        let partial = versionDirectory.appendingPathComponent(assets.image.name + ".partial")
        do {
            let received = try await downloadAsset(assets.image, to: partial,
                                                   maxBytes: Int64(UpdateAssetContract.maxImageBytes),
                                                   tooLarge: .downloadTooLarge, feed: feed,
                                                   configuration: configuration, progress: progress)
            progress(UpdateProgress(receivedBytes: received, totalBytes: received))
            try checkCancelled()
            // 第 6 步：SHA-256。
            guard let actual = UpdateDownloader.sha256(of: partial) else { throw UpdateError.checksumMismatch }
            guard actual == expected.lowercased() else {
                log.error("dmg 的 SHA-256 与校验和文件不符：期望 \(expected, privacy: .public)，实际 \(actual, privacy: .public)")
                throw UpdateError.checksumMismatch
            }
            // 「核对中」也可以取消：算完 SHA-256 后再看一次。
            try checkCancelled()
            // 第 7 步：去掉 .partial。
            try? FileManager.default.removeItem(at: finalURL)
            do {
                try FileManager.default.moveItem(at: partial, to: finalURL)
            } catch {
                throw UpdateError.network("cannot move download")
            }
            log.info("更新 \(release.version, privacy: .public) 已下载并核对，\(received) 字节")
            return PreparedUpdate(version: release.version, imagePath: finalURL.path, sha256: actual, preparedAt: Date())
        } catch let error as UpdateError {
            try? FileManager.default.removeItem(at: partial)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw .network(String(describing: type(of: error)))
        }
    }

    /// 已被取消时抛 `.cancelled`。
    private func checkCancelled() throws(UpdateError) {
        if current.withLock({ $0.cancelled }) { throw .cancelled }
    }

    /// 第 3 步：建 `Updates/<版本号>/`，删掉 `Updates/` 下别的版本与这个版本目录里残留的文件。
    /// `mnt` 目录留给安装与 `removeLeftovers` 处理，这里不碰（里面可能还有挂载点）。
    private func prepareDirectory(version: String) throws(UpdateError) -> URL {
        let manager = FileManager.default
        let versionDirectory = cacheRoot.appendingPathComponent(version, isDirectory: true)
        do {
            try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            for entry in try manager.contentsOfDirectory(atPath: cacheRoot.path)
            where entry != version && entry != BundleInstaller.mountDirectoryName {
                try? manager.removeItem(at: cacheRoot.appendingPathComponent(entry))
            }
            try manager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            for entry in try manager.contentsOfDirectory(atPath: versionDirectory.path) {
                try? manager.removeItem(at: versionDirectory.appendingPathComponent(entry))
            }
        } catch {
            throw .insufficientDiskSpace
        }
        return versionDirectory
    }

    /// 目录所在卷的可用空间（字节）；查不到时返回 nil，不拦下载。
    private func availableCapacity(at directory: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? directory.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// 下载与检查请求共用会话配置，只把超时换成下载的口径。
    private func sessionConfiguration(appVersion: String) -> URLSessionConfiguration {
        let configuration = ReleaseFeedClient.sessionConfiguration(appVersion: appVersion,
                                                                   requestTimeout: UpdateDownloader.requestTimeout)
        configuration.timeoutIntervalForResource = UpdateDownloader.resourceTimeout
        return configuration
    }

    /// 按 `asset.urls` 的顺序下载一个附件到 destination，返回收到的字节数。清单给了 SHA-256 时，下完先核对，
    /// 不符时当作这个地址失败。一个地址失败就删掉半截文件、换下一个；取消时立即抛出。都失败时抛最后一个错误。
    private func downloadAsset(_ asset: ReleaseAsset, to destination: URL, maxBytes: Int64, tooLarge: UpdateError,
                               feed: UpdateFeed, configuration: URLSessionConfiguration,
                               progress: (@Sendable (UpdateProgress) -> Void)?) async throws(UpdateError) -> Int64 {
        var lastError = UpdateError.assetMissing(asset.name)
        for (index, address) in asset.urls.enumerated() where feed.acceptsAsset(address) {
            // 标明 do 块只抛 UpdateError，catch 里的 error 才能直接和 `.cancelled` 比较、赋给 lastError。
            do throws(UpdateError) {
                let received = try await download(address, to: destination, maxBytes: maxBytes, tooLarge: tooLarge,
                                                  feed: feed, configuration: configuration, progress: progress)
                if let expected = asset.sha256 {
                    try checkCancelled()
                    guard UpdateDownloader.sha256(of: destination) == expected.lowercased() else {
                        throw UpdateError.checksumMismatch
                    }
                }
                return received
            } catch {
                try? FileManager.default.removeItem(at: destination)
                if error == .cancelled { throw error }
                log.notice("下载 \(asset.name, privacy: .public) 的地址 \(index, privacy: .public) 失败：\(String(describing: error), privacy: .public)")
                lastError = error
                try checkCancelled()
            }
        }
        throw lastError
    }

    /// 从一个地址下载到 destination，返回收到的字节数。超过 maxBytes 时抛 tooLarge。
    private func download(_ address: String, to destination: URL, maxBytes: Int64, tooLarge: UpdateError,
                          feed: UpdateFeed, configuration: URLSessionConfiguration,
                          progress: (@Sendable (UpdateProgress) -> Void)?) async throws(UpdateError) -> Int64 {
        guard let url = URL(string: address) else { throw .malformedFeed("bad asset url") }
        let operation = DownloadOperation(destination: destination, maxBytes: maxBytes, tooLarge: tooLarge, feed: feed,
                                          progress: progress)
        let alreadyCancelled = current.withLock { state -> Bool in
            if !state.cancelled { state.operation = operation }
            return state.cancelled
        }
        if alreadyCancelled { throw .cancelled }
        return try await operation.run(configuration: configuration, url: url).get()
    }

    /// 按 1 MiB 一块算文件的 SHA-256，返回小写十六进制；读不了时返回 nil。
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        // read(upToCount:) 在文件末尾返回 nil 或空数据，读错时抛错。
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: hashChunkBytes)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 一次下载：自己建一个会话并当它的委托，收进度、管重定向、把临时文件移到目标位置。
///
/// 回调在 URLSession 的委托队列上，状态用锁保护，所以标为 `@unchecked Sendable`。
/// 会话强引用委托，下载结束后 `finishTasksAndInvalidate` 解除。
private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// 下载完成后文件放在这里。
    let destination: URL
    /// 已收字节的上限。
    let maxBytes: Int64
    /// 超过上限时的错误。
    let tooLarge: UpdateError
    /// 检查地址，决定重定向到 http 是否允许。
    let feed: UpdateFeed
    /// 进度回调；nil 表示不报进度。
    let progress: (@Sendable (UpdateProgress) -> Void)?

    /// 跨回调的状态。
    private struct State {
        var continuation: CheckedContinuation<Result<Int64, UpdateError>, Never>?
        var task: URLSessionDownloadTask?
        var failure: UpdateError?
        var received: Int64 = 0
        var moved = false
        var cancelled = false
        var lastProgress: TimeInterval = 0
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(destination: URL, maxBytes: Int64, tooLarge: UpdateError, feed: UpdateFeed,
         progress: (@Sendable (UpdateProgress) -> Void)?) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.tooLarge = tooLarge
        self.feed = feed
        self.progress = progress
    }

    /// 开始下载并等它结束。
    func run(configuration: URLSessionConfiguration, url: URL) async -> Result<Int64, UpdateError> {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { continuation in
            let task = session.downloadTask(with: url)
            let cancelledEarly = state.withLock { state -> Bool in
                state.continuation = continuation
                state.task = task
                return state.cancelled
            }
            if cancelledEarly {
                // 没有 resume 的任务也算未完成，`finishTasksAndInvalidate` 会一直等它，会话与委托都不释放。
                // 取消它，会话随后失效；它的 didCompleteWithError 再调 finish 时 continuation 已是 nil，不重复回复。
                task.cancel()
                finish(.failure(.cancelled))
            } else {
                task.resume()
            }
        }
    }

    /// 取消：任务随后以 cancelled 结束。
    func cancel() {
        let task = state.withLock { state -> URLSessionDownloadTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    /// 只回复一次结果。
    private func finish(_ result: Result<Int64, UpdateError>) {
        let continuation = state.withLock { state -> CheckedContinuation<Result<Int64, UpdateError>, Never>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let tooLargeNow = state.withLock { state -> Bool in
            state.received = totalBytesWritten
            if totalBytesWritten > maxBytes, state.failure == nil {
                state.failure = tooLarge
                return true
            }
            return false
        }
        if tooLargeNow {
            downloadTask.cancel()
            return
        }
        guard let progress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let due = state.withLock { state -> Bool in
            guard now - state.lastProgress >= UpdateDownloader.progressInterval else { return false }
            state.lastProgress = now
            return true
        }
        if due {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            progress(UpdateProgress(receivedBytes: totalBytesWritten, totalBytes: total))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 临时文件在这个回调返回后就被删除，所以在这里同步移走。状态码不是 200 时不移。
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?
            .int64Value ?? 0
        if size > maxBytes {
            state.withLock { if $0.failure == nil { $0.failure = tooLarge } }
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            state.withLock {
                $0.moved = true
                $0.received = size
            }
        } catch {
            state.withLock { if $0.failure == nil { $0.failure = .network("cannot store download") } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let snapshot = state.withLock { $0 }
        if let failure = snapshot.failure {
            finish(.failure(failure))
        } else if snapshot.cancelled {
            finish(.failure(.cancelled))
        } else if let error {
            finish(.failure(.network(ReleaseFeedClient.describe(error))))
        } else if let http = task.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(.httpStatus(http.statusCode)))
        } else if snapshot.moved {
            finish(.success(snapshot.received))
        } else {
            finish(.failure(.network("no file")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // 只跟随到 https；测试地址下也允许与它同源的 http。不跟随时，3xx 答复成为最终答复，按状态码报错。
        guard let target = request.url, let scheme = target.scheme?.lowercased() else {
            completionHandler(nil)
            return
        }
        let allowed = scheme == "https" || (feed.isTestFeed && feed.accepts(target.absoluteString))
        completionHandler(allowed ? request : nil)
    }
}
