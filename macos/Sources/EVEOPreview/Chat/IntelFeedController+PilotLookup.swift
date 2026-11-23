// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警控制器的人名核对（docs/macos/design-intel-translate.md 6.10 节）：排队、发送与缓存。
//
// 何时排：intel.enabled 与 intel.resolvePilotNames 都为真，且人名缓存文件已读完时才排。
// - 新消息：收听者是活动角色、不是补读的、认作情报的，取 PilotSegmenter.candidates 里要查的名字。
//   只有一个词的人名段没有候选名字，不会被发出去（用户的要求：单个词就是一个人）。
// - 补排：对活动角色在缓冲里的消息从最新往前收集，满 500 个为止。时机：缓存文件读完、第一次确定活动角色、
//   切换客户端、收到含活动角色补读消息的一批事件、开关从关变成开、星图数据到达并重新解析之后。
// - 其他角色的消息不排；显示时用同一份缓存。
// 发送：一个任务睡到 queue.nextAttempt，取一批，调 resolver.resolve，回到主 actor 后 complete 或 fail，
// 结果进缓存后调 onChange。开关关掉时清空队列并取消任务（代号加 1，迟到的结果丢掉），缓存留着。
// 缓存：预警第一次启用时在后台读一次文件；有改动且距上次存盘满 30 秒时存一次，stop() 时同步存一次。
// 后台的各次写入排成一串（cacheWriteTask），后一次等前一次写完，做法同 TranslationController（审查 m9）。
// 日志只写个数、状态与失败的种类，不写名字（.private 也不用）。

import Foundation
import EVEOPreviewCore

/// 人名缓存文件的读取进度。
enum PilotCacheLoadState {
    /// 还没开始读。
    case notLoaded
    /// 后台任务在读。
    case loading
    /// 已读完（或读失败后从空缓存开始）。
    case loaded
}

extension IntelFeedController {
    /// 一次补排至多收集几个名字。
    static let backfillLookupLimit = 500
    /// 两次存盘至少隔几秒。
    static let cacheSaveInterval = 30.0

    /// 预警与「联网核对人名」都开着。
    var isLookupEnabled: Bool {
        guard let intel = context?.profile.intel else { return false }
        return intel.enabled && intel.resolvePilotNames
    }

    /// 人名核对的状态，给问题报告与「预警」页。预警或「联网核对人名」关着时是 `.off`。
    var pilotLookupStatus: PilotLookupStatus {
        isLookupEnabled ? lookupQueue.status : .off
    }

    /// 已保存的角色名个数。缓存文件还没读完时是 0（「预警」页据 isPilotCacheLoaded 决定显不显示）。
    var pilotCacheCount: Int { pilotCache.matchedCount }

    /// 人名缓存文件是否已读完。
    var isPilotCacheLoaded: Bool { cacheLoadState == .loaded }

    /// 给显示用的核对结果；开关关着时是 .empty，显示回到 6.4 节的推断。
    var pilotDirectory: PilotDirectory {
        isLookupEnabled ? pilotCache.directory : .empty
    }

    /// 清空内存与文件里的人名缓存。文件还没读完时，读完的结果不再用。
    func clearPilotCache() {
        cacheClearCount += 1
        pilotCache.removeAll()
        let now = wallClock
        let entries = pilotCache.snapshot(now: now)
        lastCacheSave = now
        save(entries)
        log.info("人名缓存已清空")
        onChange?()
    }

    // MARK: - 由 update、ingest 与 stop 调用

    /// 与上一次的上下文比较：开关关掉时清空队列、取消任务；打开时读缓存文件；需要时补排。
    func updatePilotLookup(previous: ChatFeedContext?, dataArrived: Bool) {
        let enabled = isLookupEnabled
        let wasEnabled = lookupWasEnabled
        lookupWasEnabled = enabled
        guard enabled else {
            if wasEnabled {
                lookupQueue.removeAll()
                cancelSending()
                saveIfDue(now: wallClock, force: true)
            }
            return
        }
        switch cacheLoadState {
        case .notLoaded:
            // 读完后会补排一次，这里不再排。
            loadCache()
            return
        case .loading:
            return
        case .loaded:
            break
        }
        let active = context?.activeCharacter
        let characterChanged = active != nil && active != previous?.activeCharacter
        if !wasEnabled || characterChanged || dataArrived { enqueueBackfillLookups() }
    }

    /// 新消息：排进它的候选名字里缓存没有结果的。
    func enqueueLookups(for report: IntelReport) {
        guard isLookupEnabled, cacheLoadState == .loaded, report.isIntelLike else { return }
        let now = wallClock
        let names = PilotSegmenter.candidates(in: report).filter { pilotCache.needsLookup($0, now: now) }
        guard !names.isEmpty else { return }
        lookupQueue.enqueue(names, now: now)
        ensureSending()
    }

    /// 补排：活动角色在缓冲里的情报，从最新的一条往前收集要查的名字，满 500 个为止。
    func enqueueBackfillLookups() {
        guard isLookupEnabled, cacheLoadState == .loaded, let active = context?.activeCharacter else { return }
        let now = wallClock
        var seen: Set<String> = []
        var names: [String] = []
        collect: for item in feed.items(for: active).reversed() where item.report.isIntelLike {
            for name in PilotSegmenter.candidates(in: item.report) where pilotCache.needsLookup(name, now: now) {
                guard seen.insert(PilotLookupAnswer.key(for: name)).inserted else { continue }
                names.append(name)
                if names.count >= Self.backfillLookupLimit { break collect }
            }
        }
        guard !names.isEmpty else { return }
        lookupQueue.enqueue(names, now: now)
        ensureSending()
    }

    /// 停止：取消发送任务；缓存有改动时同步存盘（应用退出时后台任务可能来不及跑完）。
    func stopPilotLookup() {
        cancelSending()
        guard pilotCache.isDirty else { return }
        let entries = pilotCache.snapshot(now: wallClock)
        do {
            try cacheStore.save(entries)
        } catch {
            log.error("存人名缓存失败：\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - 内部

    /// 在后台读缓存文件；读完后建缓存并补排一次。
    private func loadCache() {
        cacheLoadState = .loading
        let store = cacheStore
        let clearCount = cacheClearCount
        Task { [weak self] in
            let entries = await Task.detached(priority: .utility) { store.load() }.value
            guard let self, !self.isStopped else { return }
            // 读的过程中用户清空过缓存时，文件里的旧条目不再用。
            self.pilotCache = PilotNameCache(entries: clearCount == self.cacheClearCount ? entries : [],
                                             now: self.wallClock)
            self.cacheLoadState = .loaded
            self.log.info("人名缓存已读入：\(self.pilotCache.matchedCount) 条")
            self.enqueueBackfillLookups()
            self.onChange?()
        }
    }

    /// 没有发送任务时起一个。
    private func ensureSending() {
        guard sendTask == nil, !isStopped else { return }
        let generation = lookupGeneration
        sendTask = Task { [weak self] in
            await self?.runSending(generation: generation)
        }
    }

    /// 取消发送任务；代号加 1，任务里迟到的结果被丢掉。
    private func cancelSending() {
        lookupGeneration += 1
        sendTask?.cancel()
        sendTask = nil
    }

    /// 发送循环：能取一批就发，不能取就睡到下一次可以取的时刻；没有待查的名字时结束。
    private func runSending(generation: Int) async {
        defer { if generation == lookupGeneration { sendTask = nil } }
        while !Task.isCancelled, generation == lookupGeneration, isLookupEnabled, !isStopped {
            let now = wallClock
            guard let batch = lookupQueue.takeBatch(now: now) else {
                guard let next = lookupQueue.nextAttempt(now: now) else { return }
                try? await Task.sleep(for: .seconds(max(0.05, next - now)))
                continue
            }
            onChange?()
            let result = await resolver.resolve(batch)
            guard !Task.isCancelled, generation == lookupGeneration, !isStopped else { return }
            let done = wallClock
            switch result {
            case .success(let answer):
                lookupQueue.complete(answer, now: done)
                pilotCache.store(answer.outcomes, now: done)
                let matched = answer.outcomes.values.filter { if case .matched = $0 { true } else { false } }.count
                log.info("人名核对：\(batch.count) 个名字，查到 \(matched) 个")
                saveIfDue(now: done, force: false)
            case .failure(let failure):
                lookupQueue.fail(failure, now: done)
                log.notice("人名核对失败：\(batch.count) 个名字，\(String(describing: failure), privacy: .public)")
            }
            onChange?()
        }
    }

    /// 缓存有改动、且距上次存盘满 30 秒（或 force）时，在后台存一次。
    private func saveIfDue(now: Double, force: Bool) {
        guard pilotCache.isDirty, force || now - lastCacheSave >= Self.cacheSaveInterval else { return }
        lastCacheSave = now
        save(pilotCache.snapshot(now: now))
    }

    /// 在后台写缓存文件。各次写入排成一串：后一次等前一次写完，旧的快照不会盖掉新的。
    private func save(_ entries: [PilotNameCacheEntry]) {
        let store = cacheStore
        let previous = cacheWriteTask
        cacheWriteTask = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try store.save(entries)
            } catch {
                AppLog.logger("Intel").error("存人名缓存失败：\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}
