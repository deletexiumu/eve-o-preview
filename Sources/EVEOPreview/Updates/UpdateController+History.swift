// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跨版本的发布说明（v1.1 设计 8.8 节）：用户跳过了几个版本时，更新窗口在最新版的说明之后列出中间各版本的说明。
//
// - 检查本身不变（只请求 `releases/latest`）。有新版本要提示时（`evaluate` 得到 `.offer`），以及更新窗口显示某个
//   版本时，调 `ensureIntermediateNotes(for:)`：缓存合用就什么都不做，否则在后台请求一次 Release 列表。
// - 缓存（`state.updates.intermediateNotes`）合用的条件：是为同一个最新版取的，且取的时候正在运行的版本不比现在新。
//   所以每个新的最新版最多多一次请求；启动时只读缓存，不发请求。
// - 这次请求从不被检查、下载或安装等待，也不改 `phase`、`isChecking`、`workTask`；失败只记日志，1 小时内不再试，
//   被限流（`rateLimitedUntil` 在将来）时也不发。
// - 同一时刻只有一个请求；要取的最新版变了时取消旧的。请求回来时 `cachedRelease` 已换成别的版本，结果丢掉。
// - 正在运行的版本解析不了（如本机的开发构建）时不取，窗口只显示最新版的说明。

import Foundation
import EVEOPreviewCore

extension UpdateController {
    /// 取 Release 列表失败后，多久之内不再取。
    static let historyRetryDelay: TimeInterval = 3_600

    /// 更新窗口要在 release 之后列出的中间版本说明，新版在前；没有或缓存不是为这个版本取的时候是空数组。
    /// 显示前按当时正在运行的版本再过滤一次（用户可能已手动装了某个中间版本）。演示界面不过滤，直接用样例。
    func earlierNotes(for release: ReleaseInfo) -> [ReleaseNotesEntry] {
        guard let record = intermediateNotes, let latest = SemanticVersion(release.version),
              SemanticVersion(record.latestVersion) == latest else { return [] }
        if debugUIState != nil { return record.entries }
        guard let running = UpdatePolicy.comparableVersion(of: environment) else { return [] }
        return ReleaseHistory.intermediate(from: record.entries, running: running, latest: latest)
    }

    /// 中间版本是否没有列全（窗口据此在最后提示到发布页看更早的版本）。缓存不是为这个版本取的时候是假。
    func hasMoreEarlierNotes(for release: ReleaseInfo) -> Bool {
        guard let record = intermediateNotes, SemanticVersion(record.latestVersion) == SemanticVersion(release.version)
        else { return false }
        return record.hasMore
    }

    /// 缓存不合用时，在后台取 release 与正在运行的版本之间各版本的说明。可以随意多调，不会重复请求。
    func ensureIntermediateNotes(for release: ReleaseInfo) {
        guard debugUIState == nil, capability != .unavailable, !isTerminating,
              let latest = SemanticVersion(release.version),
              let running = UpdatePolicy.comparableVersion(of: environment), running < latest else { return }
        if let record = intermediateNotes, SemanticVersion(record.latestVersion) == latest,
           let from = SemanticVersion(record.runningVersion), from <= running { return }
        // 正在为同一个版本取：等它回来。为别的版本取：取消旧的，改取这个。
        if historyTask != nil, historyTaskVersion == latest { return }
        let now = Date()
        if let retry = historyRetryAfter, retry > now { return }
        if let limited = state.state.updates.rateLimitedUntil, limited > now { return }
        historyTask?.cancel()
        historyTaskVersion = latest
        let service = self.service
        let feed = self.feed
        let appVersion = environment.version
        historyTask = Task { [weak self] in
            let page = await service.fetchReleaseHistory(feed: feed, appVersion: appVersion)
            guard !Task.isCancelled else { return }
            self?.finishIntermediateNotes(page, running: running, latest: latest)
        }
    }

    /// 请求回来后：失败时记下重试时刻；成功且 `cachedRelease` 仍是这个版本时写缓存，窗口随之刷新。
    private func finishIntermediateNotes(_ page: ReleaseHistoryPage?, running: SemanticVersion,
                                         latest: SemanticVersion) {
        historyTask = nil
        historyTaskVersion = nil
        guard let page else {
            historyRetryAfter = Date().addingTimeInterval(UpdateController.historyRetryDelay)
            log.notice("没有取到中间版本的发布说明，只显示 \(latest.description, privacy: .public) 的说明")
            return
        }
        historyRetryAfter = nil
        guard let cached = state.state.updates.cachedRelease, SemanticVersion(cached.version) == latest else { return }
        let record = ReleaseHistory.record(from: page, running: running, latest: latest)
        intermediateNotes = record
        state.update { $0.updates.intermediateNotes = record }
        log.info("取到 \(record.entries.count, privacy: .public) 个中间版本的发布说明（更多：\(record.hasMore, privacy: .public)）")
    }
}
