// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新的检查、提示与安装流程（v1.1 设计 8.5、8.6、9.5 节）。更新窗口与「通用」页按 `phase` 与 `capability` 显示；
// 本类是 `@Observable`，状态变化时 SwiftUI 视图自己刷新。本文件是启动、恢复、定时检查与提示；
// 下载、安装、退出时安装在 UpdateController+Install.swift。
//
// - 启动：算出 `capability`；`.unavailable`（不是从 .app 运行）时什么都不做。否则恢复上次的状态（不发请求），
//   清理残留文件，清理做完后再启动循环：先等 10 秒，之后每小时醒一次，到时就检查（`UpdatePolicy.isCheckDue`）。
//   下载也先等清理做完（`cleanupTask`），免得清理删掉正在下载的文件。
// - 删 dmg 前核对它在更新缓存目录下（`SystemUpdateService.isInsideCache`）：路径来自 state.json，不删别处的文件。
// - 检查失败（网络、状态码）不写 `lastCheckAt`，下一次醒来时重试。
// - 自动检查发现新版本：「自动安装」打开且能安装、这个版本没装失败过时在后台下载；否则亮圆点并经
//   `DeferredPresenter` 弹窗口（不抢焦点，EVE 在前台时推迟）。用户发起的检查直接显示窗口。
// - 日志不写发布说明的全文和环境变量的值（5.4 节）。
//
// 界面调试入口（13.1 节第 4 项）：`EVEO_FAKE=1` 且设了 `EVEO_UPDATE_UI_STATE` 时，`start()` 把 `phase` 直接设成
// 对应的样例值，取值是 `available`、`notifyonly`、`downloading`、`ready`、`failed`、`uptodate`（样例在
// FakeUpdateService.swift）。这时不检查、不清理、不安装，`checkNow` 只重新显示更新窗口。

import AppKit
import Foundation
import Observation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 更新功能的控制器。全部方法在主线程调用。
@MainActor @Observable final class UpdateController {
    /// 界面阶段。
    private(set) var phase: UpdatePhase = .idle
    /// 这个构建能否自动安装。`start()` 算出；之前是 `.unavailable`。
    private(set) var capability: InstallCapability = .unavailable
    /// 最近一次得到服务器答复的时刻，「通用」页显示它。
    private(set) var lastCheckAt: Date?
    /// 安装成功、已请求重新启动，但等了 `relaunchGrace` 秒旧实例仍在运行（新实例没有启动）。
    /// 这时 `phase` 仍是 `.relaunching`，窗口应提示用户手动重新打开应用（`reopenManually`）。
    private(set) var relaunchFailed = false
    /// 检查地址（正式地址或 `EVEO_UPDATE_FEED_URL` 的测试地址）。
    let feed: UpdateFeed
    /// 启动时读到的运行环境。
    let environment: AppEnvironment
    /// 请求显示更新窗口。参数为真表示用户点出来的，可以激活本应用。
    @ObservationIgnored var presentWindow: (@MainActor (_ userInitiated: Bool) -> Void)?

    /// 协调器：取平台服务与配置，亮起菜单栏的圆点。协调器与本控制器同生命周期，所以不持有强引用。
    @ObservationIgnored unowned let coordinator: AppCoordinator
    /// state.json 的持有者。
    @ObservationIgnored let state: StateController
    /// `EVEO_UPDATE_UI_STATE` 的取值（已转成小写）；不在演示模式或没设时是 nil。
    @ObservationIgnored let debugUIState: String?
    /// 环境变量 `EVEO_UPDATE_FEED_URL` 设了但不符合要求、被忽略。
    @ObservationIgnored let feedOverrideRejected: Bool
    /// 定时检查的循环。
    @ObservationIgnored var loopTask: Task<Void, Never>?
    /// 是否有一次检查正在进行。
    @ObservationIgnored var isChecking = false
    /// 正在下载或安装的任务。
    @ObservationIgnored var workTask: Task<Void, Never>?
    /// 启动时的残留清理。下载开始前等它做完。
    @ObservationIgnored var cleanupTask: Task<Void, Never>?
    /// 用户在下载真正开始前点了「取消」（阶段已是下载中，但还在等清理）。
    @ObservationIgnored var preparationCancelRequested = false
    /// 当前这次下载的编号；进度回调晚到时据此丢掉。
    @ObservationIgnored var preparationID = 0
    @ObservationIgnored let log = AppLog.logger("Updates")

    /// 定时循环第一次醒来前等多久。
    static let firstCheckDelay: Duration = .seconds(10)
    /// 定时循环醒来的间隔。
    static let wakeInterval: Duration = .seconds(3_600)
    /// 「检查更新…」请求延迟弹窗的 key（4.5 节）。
    static let presenterKey = "update"

    /// 建控制器。由 AppDelegate 在建好协调器之后调用；调用 `start()` 后才开始工作。
    init(coordinator: AppCoordinator, environment: AppEnvironment, state: StateController) {
        self.coordinator = coordinator
        self.environment = environment
        self.state = state
        let variables = ProcessInfo.processInfo.environment
        let override = variables["EVEO_UPDATE_FEED_URL"]
        feed = UpdateFeed.resolve(override: override)
        feedOverrideRejected = !(override ?? "").isEmpty && !feed.isTestFeed
        lastCheckAt = state.state.updates.lastCheckAt
        debugUIState = coordinator.isFakeMode ? variables["EVEO_UPDATE_UI_STATE"]?.lowercased() : nil
    }

    /// 平台的更新服务。
    var service: any UpdateService { coordinator.services.updates }
    /// 当前配置的 `general` 一组。
    var general: GeneralSettings { coordinator.config.config.general }
    /// 正在下载、核对、安装或重新启动。
    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .installing, .relaunching: return true
        default: return false
        }
    }

    // MARK: - 启动与恢复

    /// 算出 `capability`，恢复上次的状态，清理残留文件，并开始定时检查。
    func start() {
        if let name = debugUIState, let sample = FakeUpdateService.samplePhase(named: name) {
            phase = sample.phase
            capability = sample.capability
            switch sample.phase {
            case .available: coordinator.setAttention(.updateAvailable, on: true)
            case .readyToInstall: coordinator.setAttention(.updateReady, on: true)
            default: break
            }
            return
        }
        capability = UpdatePolicy.capability(for: environment, isTestFeed: feed.isTestFeed)
        guard capability != .unavailable else {
            log.info("不是从 .app 运行，更新功能停用")
            return
        }
        if feedOverrideRejected { log.error("EVEO_UPDATE_FEED_URL 不是 https，也不是回环主机的 http，已忽略") }
        if feed.isTestFeed { log.notice("使用测试地址检查更新") }
        log.info("更新功能：能否安装 \(String(describing: capability), privacy: .public)")
        logPreviousInstall()
        restoreState()
        let updates = state.state.updates
        let prepared = updates.prepared
        let stale = updates.staleStagingPath
        let service = self.service
        // 清理做完再启动定时检查，检查与后台下载不会与清理同时动缓存目录。
        cleanupTask = Task { [weak self] in
            await service.removeLeftovers(keeping: prepared, staleStagingPath: stale)
            if stale != nil { self?.state.update { $0.updates.staleStagingPath = nil } }
            self?.startLoop()
        }
    }

    /// 新实例启动时：上次安装成功且旧包还没删（说明这是安装后的第一次启动），核对版本并记日志。
    private func logPreviousInstall() {
        let updates = state.state.updates
        guard let record = updates.lastInstall, record.succeeded, updates.staleStagingPath != nil else { return }
        if SemanticVersion(record.version) == SemanticVersion(environment.version) {
            log.info("已从 \(record.fromVersion, privacy: .public) 更新到 \(record.version, privacy: .public)")
        } else {
            log.error("上次安装了 \(record.version, privacy: .public)，但正在运行的是 \(environment.version, privacy: .public)")
        }
    }

    /// 只读 `state.updates` 恢复上次的状态，不发请求（8.5 节）。1 小时内重启后，圆点与菜单项仍在。
    private func restoreState() {
        // 测试地址留下的缓存在正式地址下不认（反之亦然），连同 ETag 一起丢掉。
        if let cached = state.state.updates.cachedRelease, !feed.accepts(cached.pageURL) {
            state.update {
                $0.updates.cachedRelease = nil
                $0.updates.etag = nil
            }
        }
        if let prepared = state.state.updates.prepared, !isUsable(prepared) { discardPrepared() }
        rederivePhaseFromState()
    }

    /// 只按 `state.updates` 与开关重新定出阶段和圆点，不发请求：
    /// 已下载好、两个开关都打开、这个版本没装失败过时是 `.readyToInstall`；否则缓存的发布版仍该提示时是 `.available`
    /// （装失败过的版本退为普通提示，9.5 节）；否则是 `.idle`。
    /// 启动时的恢复与失败窗口关闭后（`remindLater`）都用它，保证圆点与阶段一致。
    func rederivePhaseFromState() {
        let updates = state.state.updates
        if general.checkForUpdates, general.autoInstallUpdates, let prepared = updates.prepared, isUsable(prepared),
           !hasFailedInstall(of: prepared.version), let release = updates.cachedRelease {
            phase = .readyToInstall(release)
            coordinator.setAttention(.updateAvailable, on: false)
            coordinator.setAttention(.updateReady, on: true)
            return
        }
        coordinator.setAttention(.updateReady, on: false)
        if general.checkForUpdates, let cached = updates.cachedRelease,
           case .offer(let release) = UpdatePolicy.offer(release: cached, running: environment,
                                                          skippedVersion: updates.skippedVersion,
                                                          userInitiated: false) {
            phase = .available(release)
            coordinator.setAttention(.updateAvailable, on: true)
        } else {
            phase = .idle
            coordinator.setAttention(.updateAvailable, on: false)
        }
    }

    /// 已下载的更新还能不能用：dmg 还在且位于更新缓存目录下；它的版本大于正在运行的版本；`cachedRelease` 的版本与它相同。
    func isUsable(_ prepared: PreparedUpdate) -> Bool {
        guard FileManager.default.fileExists(atPath: prepared.imagePath),
              SystemUpdateService.isInsideCache(prepared.imagePath),
              let version = SemanticVersion(prepared.version),
              let running = UpdatePolicy.comparableVersion(of: environment), running < version,
              let cached = state.state.updates.cachedRelease, SemanticVersion(cached.version) == version else {
            return false
        }
        return true
    }

    /// 清掉 `prepared` 并删掉它的 dmg（只在 dmg 位于更新缓存目录下时删，记录总是清掉）。
    func discardPrepared() {
        guard let prepared = state.state.updates.prepared else { return }
        removePreparedImage(prepared)
        state.update { $0.updates.prepared = nil }
    }

    /// 删 prepared 的 dmg。路径解析符号链接后不在更新缓存目录下时不删，只记日志。
    func removePreparedImage(_ prepared: PreparedUpdate) {
        guard SystemUpdateService.isInsideCache(prepared.imagePath) else {
            if FileManager.default.fileExists(atPath: prepared.imagePath) {
                log.error("state.json 记录的 dmg 不在更新缓存目录下，不删")
            }
            return
        }
        try? FileManager.default.removeItem(atPath: prepared.imagePath)
    }

    // MARK: - 定时检查

    /// 先等 10 秒，之后每小时醒一次。只有第一次醒来算启动时的检查。
    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: UpdateController.firstCheckDelay)
            var atLaunch = true
            while !Task.isCancelled {
                await self?.automaticCheckIfDue(atLaunch: atLaunch)
                atLaunch = false
                try? await Task.sleep(for: UpdateController.wakeInterval)
            }
        }
    }

    /// 自动检查：开关打开、没有在忙、到时才检查。
    func automaticCheckIfDue(atLaunch: Bool) async {
        guard capability != .unavailable, debugUIState == nil, general.checkForUpdates, !isBusy, !isChecking else {
            return
        }
        let updates = state.state.updates
        guard UpdatePolicy.isCheckDue(now: Date(), lastCheckAt: updates.lastCheckAt,
                                      rateLimitedUntil: updates.rateLimitedUntil, atLaunch: atLaunch) else { return }
        await performCheck(userInitiated: false)
    }

    /// `general.checkForUpdates` 从假变真时调用：立即按非启动时的间隔判断一次（8.5 节）。
    func checkForUpdatesWasEnabled() {
        Task { [weak self] in await self?.automaticCheckIfDue(atLaunch: false) }
    }

    /// 立即检查一次。用户发起时不看间隔；被限流时不发请求，窗口直接显示限流的说明。
    func checkNow(userInitiated: Bool) {
        if debugUIState != nil {
            presentWindow?(userInitiated)
            return
        }
        guard capability != .unavailable else { return }
        if isBusy || isChecking {
            if userInitiated { presentWindow?(true) }
            return
        }
        if userInitiated, let until = state.state.updates.rateLimitedUntil, until > Date() {
            phase = .failed(.rateLimited(until: until), release: nil)
            presentWindow?(true)
            return
        }
        Task { [weak self] in await self?.performCheck(userInitiated: userInitiated) }
    }

    /// 发一次检查请求，按 8.4 节的表写 `state.updates`，再按 8.6 节决定提示。
    func performCheck(userInitiated: Bool) async {
        isChecking = true
        defer { isChecking = false }
        let previous = phase
        if userInitiated {
            coordinator.presenter.cancel(key: UpdateController.presenterKey)
            phase = .checking
            presentWindow?(true)
        }
        let updates = state.state.updates
        // 只在有缓存的发布信息时带 ETag：304 要靠缓存继续判断。
        let etag = updates.cachedRelease == nil ? nil : updates.etag
        let result = await service.fetchLatestRelease(feed: feed, etag: etag, appVersion: environment.version)
        let now = Date()
        // 等答复期间用户可能已点了「安装更新」：之后只写 state，不改阶段，免得盖掉进度。
        let keepPhase = isBusy
        defer { lastCheckAt = state.state.updates.lastCheckAt }
        switch result {
        case .release(let release, let newTag):
            state.update {
                $0.updates.lastCheckAt = now
                $0.updates.etag = newTag
                $0.updates.cachedRelease = release
                $0.updates.rateLimitedUntil = nil
            }
            log.info("检查更新：最新的正式版是 \(release.version, privacy: .public)")
            if !keepPhase { evaluate(release, userInitiated: userInitiated, checkedAt: now, previous: previous) }
        case .notModified:
            state.update { $0.updates.lastCheckAt = now }
            if let cached = state.state.updates.cachedRelease {
                log.info("检查更新：与上次相同（\(cached.version, privacy: .public)）")
                if !keepPhase { evaluate(cached, userInitiated: userInitiated, checkedAt: now, previous: previous) }
            } else {
                // 304 但没有缓存（不应发生）：丢掉 ETag，下次取完整答复。
                state.update { $0.updates.etag = nil }
                if !keepPhase { noOffer(.notNewer, userInitiated: userInitiated, checkedAt: now, previous: previous) }
            }
        case .noRelease:
            state.update { $0.updates.lastCheckAt = now }
            log.info("检查更新：还没有正式版")
            if !keepPhase { noOffer(.notNewer, userInitiated: userInitiated, checkedAt: now, previous: previous) }
        case .rateLimited(let until):
            state.update { $0.updates.rateLimitedUntil = until }
            log.error("检查更新被限流，可以再试的时刻：\(until.map { "\($0)" } ?? "未知", privacy: .public)")
            if !keepPhase { phase = userInitiated ? .failed(.rateLimited(until: until), release: nil) : previous }
            if userInitiated { presentWindow?(true) }
        case .failed(let error):
            log.error("检查更新失败：\(String(describing: error), privacy: .public)")
            if !keepPhase { phase = userInitiated ? .failed(error, release: nil) : previous }
            if userInitiated { presentWindow?(true) }
        }
    }

    // MARK: - 决策与提示（8.6 节）

    /// 按 `UpdatePolicy.offer` 决定提示、后台下载或什么都不做。
    ///
    /// previous 是检查前的阶段：用户发起的检查已把阶段换成 `.checking`，「已下载好」要按检查前的看。
    func evaluate(_ release: ReleaseInfo, userInitiated: Bool, checkedAt: Date, previous: UpdatePhase) {
        let offer = UpdatePolicy.offer(release: release, running: environment,
                                       skippedVersion: state.state.updates.skippedVersion,
                                       userInitiated: userInitiated)
        guard case .offer(let offered) = offer else {
            if case .none(let reason) = offer {
                noOffer(reason, userInitiated: userInitiated, checkedAt: checkedAt, previous: previous)
            }
            return
        }
        // 同一个版本已下载好、等待安装：保持原样。
        if case .readyToInstall(let ready) = previous, ready.version == offered.version {
            phase = previous
            if userInitiated { presentWindow?(true) }
            return
        }
        if userInitiated {
            phase = .available(offered)
            coordinator.setAttention(.updateAvailable, on: true)
            presentWindow?(true)
            return
        }
        if general.autoInstallUpdates, capability == .canInstall, !hasFailedInstall(of: offered.version) {
            prepareInBackground(offered)
            return
        }
        promptAutomatically(offered)
    }

    /// 自动检查的普通提示：`.available`、圆点、推迟的窗口。
    func promptAutomatically(_ release: ReleaseInfo) {
        phase = .available(release)
        coordinator.setAttention(.updateAvailable, on: true)
        coordinator.presenter.present(key: UpdateController.presenterKey) { [weak self] in
            self?.presentWindow?(false)
        }
    }

    /// 不提示：用户发起的检查显示「已是最新版本」；自动检查不显示任何东西，并熄灭 `.updateAvailable` 的圆点。
    private func noOffer(_ reason: UpdateSkipReason, userInitiated: Bool, checkedAt: Date, previous: UpdatePhase) {
        log.info("检查更新：不提示（\(String(describing: reason), privacy: .public)）")
        coordinator.setAttention(.updateAvailable, on: false)
        coordinator.presenter.cancel(key: UpdateController.presenterKey)
        // 已下载好、等待安装时保持原样（圆点与菜单项仍对应 `.readyToInstall`）。
        if case .readyToInstall = previous {
            phase = previous
            if userInitiated { presentWindow?(true) }
            return
        }
        // 自动检查遇到「跳过此版本」时不说「已是最新」：用户知道有新版本。
        if reason == .skippedByUser {
            phase = .idle
        } else {
            phase = .upToDate(checkedAt: checkedAt)
        }
        // 圆点与阶段保持一致：离开 `.readyToInstall` 时熄灭 `.updateReady`。
        coordinator.setAttention(.updateReady, on: false)
        if userInitiated { presentWindow?(true) }
    }

    /// 这个版本是否已有安装失败的记录（9.5 节：失败过的版本不再自动安装）。
    func hasFailedInstall(of version: String) -> Bool {
        guard let record = state.state.updates.lastInstall, !record.succeeded else { return false }
        return SemanticVersion(record.version) == SemanticVersion(version)
    }

    // MARK: - 窗口按钮

    /// 当前阶段所对应的发布版；没有时是 nil。
    var currentRelease: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .verifying(let release),
             .readyToInstall(let release), .installing(let release):
            return release
        case .failed(_, let release):
            return release
        case .idle, .checking, .upToDate, .relaunching:
            return nil
        }
    }

    /// 跳过当前提示的版本：只影响自动检查。不关窗口（窗口自己关）。
    func skipThisVersion() {
        guard debugUIState == nil, let release = currentRelease, !isBusy else { return }
        state.update { $0.updates.skippedVersion = release.version }
        if let prepared = state.state.updates.prepared, SemanticVersion(prepared.version) == SemanticVersion(release.version) {
            discardPrepared()
            coordinator.setAttention(.updateReady, on: false)
        }
        coordinator.setAttention(.updateAvailable, on: false)
        coordinator.presenter.cancel(key: UpdateController.presenterKey)
        phase = .idle
        log.info("跳过版本 \(release.version, privacy: .public)")
    }

    /// 「稍后」：保留圆点与菜单项，下次自动检查时再提示。失败的阶段退回到可以再点的状态。
    /// 不关窗口（窗口自己关）；可以连续调用两次（按钮一次、窗口关闭时一次），第二次不改任何状态。
    func remindLater() {
        guard debugUIState == nil else { return }
        coordinator.presenter.cancel(key: UpdateController.presenterKey)
        // 失败的检查或安装关窗口后，按 state 重新定出阶段与圆点（缓存的新版本仍在时回到 `.available`）。
        guard case .failed = phase else { return }
        rederivePhaseFromState()
    }

    /// 用默认浏览器打开当前版本的发布页；没有版本时打开发布列表。
    func openReleasePage() {
        let candidate = currentRelease?.pageURL ?? state.state.updates.cachedRelease?.pageURL
        let fallback = UpdateFeed.productionAssetPrefix + "latest"
        let address = candidate.flatMap { feed.accepts($0) ? $0 : nil } ?? fallback
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 给 +Install 的阶段入口

    /// 设阶段。`phase` 的 setter 是 private，扩展文件经这里改。
    func setPhase(_ newPhase: UpdatePhase) {
        phase = newPhase
    }

    /// 记下重新启动没有成功，并重新显示更新窗口：这是用户自己发起的操作失败了，
    /// 用户可能已在「重新启动中…」时关掉了窗口，要让他看到「请手动重新打开」的说明。
    func markRelaunchFailed() {
        relaunchFailed = true
        presentWindow?(true)
    }
}
