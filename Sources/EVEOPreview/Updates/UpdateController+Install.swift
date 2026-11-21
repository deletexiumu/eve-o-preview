// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新的下载、安装与退出时安装（v1.1 设计 9.2～9.5 节）。
//
// - 用户点「安装更新」：下载并核对（已有可用的下载时跳过），安装，成功后重新启动。
// - 自动安装：后台下载并核对，成功后进入 `.readyToInstall`、亮 `.updateReady`；失败时退回普通提示。
//   之后在三个时刻安装：用户点「重新启动以更新到 <版本>」（`restartToInstall`）；没有 EVE 客户端在运行、
//   连续空闲约 1 分钟时自动安装并重新启动（UpdateController+IdleInstall.swift）；用户退出应用
//   （`installOnQuitIfReady`，不重新启动，最多等 8 秒）。
// - 每次安装失败都写 `lastInstall`（失败）与一条 error 日志；验证阶段的 fault 日志由平台层写（9.4 节）。
//   失败过的版本不再自动安装。dmg 已被平台层删掉（验证失败、校验和不符）时清掉 `prepared`。
// - 演示模式与 `EVEO_UPDATE_UI_STATE` 调试入口下不下载、不安装、不重新启动。
// - 阶段的进入顺序：下载中 → 核对中（下载完成、开始算 SHA-256）→ 安装中 → 重新启动中。
// - 开始下载或安装时，先在主线程上同步把阶段设成下载中或安装中（`isBusy` 随之为真），再建任务：
//   两次很快的调用（连点按钮、按钮与菜单项）第二次看到的已是忙，不会开始第二次安装。

import AppKit
import Foundation
import EVEOPreviewCore

extension UpdateController {
    /// 请求重新启动后，等多少秒旧实例仍在运行就认为新实例没有启动。
    static let relaunchGrace: Duration = .seconds(15)

    /// 是否允许走下载与安装：不是调试入口、不是演示模式、这个构建能安装。
    private var canRunInstaller: Bool {
        debugUIState == nil && !coordinator.isFakeMode && capability == .canInstall
    }

    // MARK: - 用户发起

    /// 下载、校验、安装并重新启动。只提示的构建改为打开发布页。
    func install() {
        guard debugUIState == nil else { return }
        if case .notifyOnly = capability {
            openReleasePage()
            return
        }
        guard canRunInstaller, !isBusy, let release = currentRelease else { return }
        coordinator.presenter.cancel(key: UpdateController.presenterKey)
        startInstall(release)
    }

    /// 自动安装已下载好时，由菜单项「重新启动以更新到 <版本>」调用。
    func restartToInstall() {
        guard canRunInstaller, !isBusy, case .readyToInstall(let release) = phase else { return }
        startInstall(release)
    }

    /// 同步定出起始阶段（已有可用的下载时是安装中，否则是下载中），再建下载与安装的任务。
    /// 不能用的旧下载在这里就丢掉。调用方已确认 `!isBusy`。
    private func startInstall(_ release: ReleaseInfo) {
        var prepared = state.state.updates.prepared
        if let existing = prepared, existing.version != release.version || !isUsable(existing) {
            discardPrepared()
            prepared = nil
        }
        preparationCancelRequested = false
        setPhase(prepared == nil ? .downloading(release, initialProgress(release)) : .installing(release))
        workTask = Task { [weak self] in await self?.downloadAndInstall(release, prepared: prepared, relaunch: true) }
    }

    /// 取消进行中的下载或核对，回到 `.available`。安装开始后不能取消。
    func cancel() {
        switch phase {
        case .downloading, .verifying:
            // 下载可能还没开始（在等启动时的清理），先记下，`prepare` 开始前看到它就不下载。
            preparationCancelRequested = true
            service.cancelPreparation()
        default: break
        }
    }

    // MARK: - 下载

    /// 自动安装的后台下载（9.5 节第 1～3 步），不显示窗口。
    func prepareInBackground(_ release: ReleaseInfo) {
        guard canRunInstaller, !isBusy else {
            promptAutomatically(release)
            return
        }
        if let prepared = state.state.updates.prepared, prepared.version == release.version, isUsable(prepared) {
            becomeReady(release)
            return
        }
        // 同步进入下载中，与 `startInstall` 相同：任务开始前 `isBusy` 已为真。
        preparationCancelRequested = false
        setPhase(.downloading(release, initialProgress(release)))
        workTask = Task { [weak self] in
            guard let self else { return }
            switch await self.prepare(release) {
            case .success:
                self.becomeReady(release)
            case .failure(.cancelled):
                self.setPhase(.available(release))
                self.coordinator.setAttention(.updateAvailable, on: true)
            case .failure:
                // 下载或核对失败：退回普通提示（9.5 节第 3 步）。
                self.promptAutomatically(release)
            }
        }
    }

    /// 下载好、等待安装：`.readyToInstall` 与 `.updateReady`。
    private func becomeReady(_ release: ReleaseInfo) {
        setPhase(.readyToInstall(release))
        coordinator.setAttention(.updateAvailable, on: false)
        coordinator.setAttention(.updateReady, on: true)
        coordinator.presenter.cancel(key: UpdateController.presenterKey)
        log.info("更新 \(release.version, privacy: .public) 已下载，空闲时或退出时安装")
        startIdleInstallWatch()
    }

    /// 下载开始前的进度：0 字节，总数取 dmg 附件声明的大小。
    private func initialProgress(_ release: ReleaseInfo) -> UpdateProgress {
        UpdateProgress(receivedBytes: 0, totalBytes: release.assets.first {
            $0.name == UpdateAssetContract.imageName(version: release.version)
        }?.size.map(Int64.init))
    }

    /// 下载并核对；成功时把结果写进 `state.updates.prepared`。先等启动时的清理做完。
    private func prepare(_ release: ReleaseInfo) async -> Result<PreparedUpdate, UpdateError> {
        preparationID += 1
        let id = preparationID
        setPhase(.downloading(release, initialProgress(release)))
        await cleanupTask?.value
        if preparationCancelRequested {
            preparationID += 1
            return .failure(.cancelled)
        }
        let result = await service.prepare(release, feed: feed) { [weak self] progress in
            Task { @MainActor in self?.progressDidChange(progress, release: release, id: id) }
        }
        // 晚到的进度回调按编号丢掉。
        preparationID += 1
        if case .success(let prepared) = result {
            state.update { $0.updates.prepared = prepared }
        } else if case .failure(let error) = result, error != .cancelled {
            log.error("下载更新失败：\(String(describing: error), privacy: .public)")
        }
        return result
    }

    /// 进度回调：收齐时进入「核对中」。
    private func progressDidChange(_ progress: UpdateProgress, release: ReleaseInfo, id: Int) {
        guard id == preparationID else { return }
        switch phase {
        case .downloading, .verifying: break
        default: return
        }
        if let total = progress.totalBytes, progress.receivedBytes >= total {
            setPhase(.verifying(release))
        } else {
            setPhase(.downloading(release, progress))
        }
    }

    // MARK: - 安装

    /// 下载（prepared 是 `startInstall` 核对过的可用下载，有时跳过下载）、安装，relaunch 为真时成功后重新启动。
    private func downloadAndInstall(_ release: ReleaseInfo, prepared: PreparedUpdate?, relaunch: Bool) async {
        var prepared = prepared
        if prepared == nil {
            switch await prepare(release) {
            case .success(let value):
                prepared = value
            case .failure(.cancelled):
                setPhase(.available(release))
                coordinator.setAttention(.updateAvailable, on: true)
                return
            case .failure(let error):
                recordFailure(error, version: release.version)
                setPhase(.failed(error, release: release))
                return
            }
        }
        guard let prepared else { return }
        // 已有下载直接安装时也先等启动时的清理做完：清理会卸下残留的挂载，
        // 没卸完就挂同一个 dmg 会报「资源忙」（复审意见）。
        await cleanupTask?.value
        setPhase(.installing(release))
        // 安装中没有对应的菜单提示项，两个圆点原因都熄灭；失败后由窗口关闭时的 remindLater 重新定出。
        coordinator.setAttention(.updateReady, on: false)
        coordinator.setAttention(.updateAvailable, on: false)
        let result = await service.install(prepared, environment: environment)
        guard case .success(let outcome) = apply(result, prepared: prepared) else {
            if case .failure(let error) = result { setPhase(.failed(error, release: release)) }
            coordinator.setAttention(.updateReady, on: false)
            return
        }
        coordinator.setAttention(.updateReady, on: false)
        coordinator.setAttention(.updateAvailable, on: false)
        guard relaunch else { return }
        setPhase(.relaunching)
        log.info("已安装 \(outcome.installedVersion, privacy: .public)，重新启动")
        coordinator.services.permissions.relaunch()
        // relaunch() 成功时本进程随后退出；等了一段时间仍在运行，说明新实例没有启动。
        try? await Task.sleep(for: UpdateController.relaunchGrace)
        log.error("安装后重新启动没有完成，请用户手动重新打开应用")
        markRelaunchFailed()
    }

    /// 把安装结果写进 `state.updates`：成功时清掉 `prepared`、记 `lastInstall` 与旧包位置、删 dmg；
    /// 失败时记 `lastInstall`（失败），dmg 已被删时清掉 `prepared`。
    @discardableResult
    private func apply(_ result: Result<InstallOutcome, UpdateError>, prepared: PreparedUpdate)
        -> Result<InstallOutcome, UpdateError> {
        switch result {
        case .success(let outcome):
            removePreparedImage(prepared)
            let record = InstallRecord(version: outcome.installedVersion, fromVersion: environment.buildLabel,
                                       at: Date(), succeeded: true)
            state.update {
                $0.updates.prepared = nil
                $0.updates.lastInstall = record
                $0.updates.staleStagingPath = outcome.stagingPath
            }
        case .failure(let error):
            recordFailure(error, version: prepared.version)
            if !FileManager.default.fileExists(atPath: prepared.imagePath) {
                state.update { $0.updates.prepared = nil }
            }
        }
        return result
    }

    /// 记一次失败：`lastInstall` 与一条 error 日志。用户取消不算失败。
    private func recordFailure(_ error: UpdateError, version: String) {
        guard error != .cancelled else { return }
        let code = UpdateController.errorCode(error)
        log.error("安装更新 \(version, privacy: .public) 失败：\(code, privacy: .public)")
        let record = InstallRecord(version: version, fromVersion: environment.buildLabel, at: Date(),
                                   succeeded: false, errorCode: code)
        state.update { $0.updates.lastInstall = record }
    }

    /// `UpdateError` 的名称，如 `signatureInvalid`。
    static func errorCode(_ error: UpdateError) -> String {
        let text = String(describing: error)
        return String(text.prefix { $0 != "(" })
    }

    // MARK: - 退出时安装

    /// 退出前调用：自动安装已下载好时安装，不重新启动。最多等 timeout。
    ///
    /// 条件全部成立才安装（9.5 节）：两个开关都打开；`prepared` 有值且版本大于正在运行的版本；能安装；
    /// 这个版本没有装失败过；没有同 bundle id 的另一个实例在运行。超时后不再等待，安装任务随进程结束。
    func installOnQuitIfReady(timeout: Duration) async {
        guard canRunInstaller, general.checkForUpdates, general.autoInstallUpdates, !isBusy,
              let prepared = state.state.updates.prepared, isUsable(prepared),
              !hasFailedInstall(of: prepared.version), !isAnotherInstanceRunning() else { return }
        loopTask?.cancel()
        if let release = state.state.updates.cachedRelease { setPhase(.installing(release)) }
        log.info("退出时安装更新 \(prepared.version, privacy: .public)")
        let service = self.service
        let environment = self.environment
        // 启动时的清理还没做完时先等它（计入时限），免得两边同时卸载挂载点、动缓存目录。
        let cleanup = cleanupTask
        let install = Task {
            await cleanup?.value
            return await service.install(prepared, environment: environment)
        }
        guard let result = await UpdateController.value(of: install, timeout: timeout) else {
            log.error("退出时安装超过时限，不再等待")
            return
        }
        apply(result, prepared: prepared)
    }

    /// 等 task 的结果，最多 timeout；超时返回 nil，task 继续运行。
    ///
    /// 不用 TaskGroup：任务组要等全部子任务结束，安装卡住时会挂住退出。两个等待任务都在主线程，
    /// 「谁先到」的标记不用锁。
    private static func value<T: Sendable>(of task: Task<T, Never>, timeout: Duration) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = ResumeGate()
            Task { @MainActor in
                let value = await task.value
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// 同 bundle id 的另一个实例是否在运行（「重新启动」的交接期间，新实例已从旧包启动）。
    private func isAnotherInstanceRunning() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: environment.bundleIdentifier)
            .contains { $0.processIdentifier != own && !$0.isTerminated }
    }
}

/// 只放行第一次的标记，保证 continuation 只恢复一次。只在主线程使用。
@MainActor private final class ResumeGate {
    /// 是否已放行过。
    private var claimed = false

    /// 第一次调用返回真，之后返回假。
    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}
