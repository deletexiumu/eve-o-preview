// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的游戏日志服务（反馈文档 7.12 节）：EVEO_FAKE=1 时使用，不读任何文件。
// 启动后每 8 秒给一个假角色发一条 incomingDamage，按角色轮流；状态是
// watching(directory: "fake", followedFiles: 假角色数)。假角色取自 FakeWorld 里已登录的客户端标题。

import Foundation
import EVEOPreviewCore

/// 演示模式的游戏日志服务。全部方法在主线程调用。
@MainActor
final class FakeCombatLogMonitor: CombatLogMonitor {
    /// 两条假事件之间的间隔（秒）。
    static let interval: Duration = .seconds(8)

    /// 一批受击事件。
    var onEvents: (@MainActor ([CombatLogEvent]) -> Void)?
    /// 状态变化的回调。
    var onStatusChange: (@MainActor (CombatLogStatus) -> Void)?
    /// 当前状态。
    private(set) var status: CombatLogStatus = .stopped
    /// 假世界，从中取假角色名。
    private let world: FakeWorld
    /// 发假事件的任务；nil 表示没有在运行。
    private var task: Task<Void, Never>?
    /// 下一个受击的角色在角色列表里的序号。
    private var nextIndex = 0

    /// 用假世界建服务，暂不发事件。
    init(world: FakeWorld) {
        self.world = world
    }

    /// 开始发假事件。已在运行时不做任何事（假服务不区分目录）。
    func start(directory: String?) {
        guard task == nil else { return }
        update(.watching(directory: "fake", followedFiles: characterNames().count))
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: FakeCombatLogMonitor.interval)
                guard !Task.isCancelled else { return }
                self?.emit()
            }
        }
    }

    /// 停止发假事件，状态变成 `stopped`。
    func stop() {
        task?.cancel()
        task = nil
        update(.stopped)
    }

    /// 给下一个假角色发一条受击事件，伤害数字在 50～500 之间。
    private func emit() {
        let names = characterNames()
        update(.watching(directory: "fake", followedFiles: names.count))
        guard !names.isEmpty else { return }
        let name = names[nextIndex % names.count]
        nextIndex += 1
        onEvents?([CombatLogEvent(character: name, kind: .incomingDamage(amount: Int.random(in: 50...500)))])
    }

    /// 已登录的假角色名，按名称排序。登录界面的假客户端没有角色名，不参与。
    private func characterNames() -> [String] {
        world.snapshot().compactMap { TitleParser.identity(fromTitle: $0.title).characterName }.sorted()
    }

    /// 记下新状态，变了时通知。
    private func update(_ newStatus: CombatLogStatus) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
