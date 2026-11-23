// SPDX-License-Identifier: GPL-3.0-or-later
//
// ClientRegistry 的用例（架构文档 5.3 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 客户端登记：新增、移除、改名、更新、顺序与 ID 复用。
struct ClientRegistryTests {
    /// E6 的 3 个主窗口。
    private var mainWindows: [WindowInfo] {
        ClientWindowSelector.mainWindows(from: Fixtures.e6Windows)
    }

    /// 首轮全部是新增，身份已解析。
    @Test func firstUpdateAddsAll() {
        var registry = ClientRegistry()
        let diff = registry.update(with: mainWindows)
        #expect(diff.added.map(\.identity) == [.character(Fixtures.pilotAlpha), .character(Fixtures.pilotBravo),
                                                .character(Fixtures.pilotCharlie)])
        #expect(diff.removed.isEmpty && diff.renamed.isEmpty && diff.updated.isEmpty)
        #expect(registry.clients.count == 3)
    }

    /// 同样的输入再来一次，差异为空。
    @Test func unchangedInputGivesEmptyDiff() {
        var registry = ClientRegistry()
        registry.update(with: mainWindows)
        #expect(registry.update(with: mainWindows).isEmpty)
    }

    /// 窗口消失进 removed，登记表随之缩短。
    @Test func removal() {
        var registry = ClientRegistry()
        registry.update(with: mainWindows)
        let diff = registry.update(with: Array(mainWindows.dropFirst()))
        #expect(diff.removed.map(\.id.rawValue) == [9002])
        #expect(registry.clients.map(\.id.rawValue) == [9103, 9201])
    }

    /// 登录后标题从 `EVE` 变成 `EVE - <角色名>`：进 renamed，位置不变。
    @Test func renameAfterLogin() {
        var registry = ClientRegistry()
        var windows = mainWindows
        windows[1].title = "EVE"
        registry.update(with: windows)
        #expect(registry.clients[1].identity == .login)

        let diff = registry.update(with: mainWindows)
        #expect(diff.renamed.count == 1)
        #expect(diff.renamed.first?.before.identity == .login)
        #expect(diff.renamed.first?.after.identity == .character(Fixtures.pilotBravo))
        #expect(diff.updated.isEmpty)
        #expect(registry.clients[1].identity == .character(Fixtures.pilotBravo))
    }

    /// 只移动窗口或改变最小化状态：进 updated，不进 renamed。
    @Test func moveOnlyIsUpdate() {
        var registry = ClientRegistry()
        registry.update(with: mainWindows)
        var windows = mainWindows
        windows[0].frame.x += 100
        windows[2].isMinimized = true
        let diff = registry.update(with: windows)
        #expect(diff.updated.map(\.after.id.rawValue) == [9002, 9201])
        #expect(diff.renamed.isEmpty && diff.added.isEmpty && diff.removed.isEmpty)
        #expect(registry.clients[0].windowFrame.x == 100)
    }

    /// 顺序按首次发现：后来的客户端排到末尾，即使输入里排在前面。
    @Test func orderIsStable() {
        var registry = ClientRegistry()
        registry.update(with: Array(mainWindows.suffix(2)))
        registry.update(with: mainWindows)
        #expect(registry.clients.map(\.id.rawValue) == [9103, 9201, 9002])
        // 输入顺序变化不影响已有客户端的顺序。
        registry.update(with: mainWindows.reversed())
        #expect(registry.clients.map(\.id.rawValue) == [9103, 9201, 9002])
    }

    /// 窗口 ID 被另一个 PID 复用：旧客户端移除，新客户端新增并排到末尾。
    @Test func windowIDReusedByAnotherPID() {
        var registry = ClientRegistry()
        registry.update(with: mainWindows)
        var windows = mainWindows
        windows[0].pid = 5000
        windows[0].title = "EVE"
        let diff = registry.update(with: windows)
        #expect(diff.removed.map(\.pid) == [Fixtures.pidA])
        #expect(diff.added.map(\.pid) == [5000])
        #expect(diff.renamed.isEmpty)
        #expect(registry.clients.map(\.id.rawValue) == [9103, 9201, 9002])
        #expect(registry.client(withPID: 5000)?.identity == .login)
    }

    /// 查找方法按 ID、PID、角色名取到客户端。
    @Test func lookups() {
        var registry = ClientRegistry()
        registry.update(with: mainWindows)
        #expect(registry.client(withID: WindowID(rawValue: 9103))?.pid == Fixtures.pidB)
        #expect(registry.client(withPID: Fixtures.pidC)?.characterName == Fixtures.pilotCharlie)
        #expect(registry.client(named: Fixtures.pilotAlpha)?.id.rawValue == 9002)
        #expect(registry.client(named: "pilot alpha") == nil)
    }
}
