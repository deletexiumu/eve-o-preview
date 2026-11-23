// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProfileEditor 的用例（架构文档 5.2 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 配置方案的新建、克隆、改名、删除与名称规则。
struct ProfileEditorTests {
    /// 两个配置方案的配置，当前方案是 A。
    private let base = AppConfig(activeProfileID: "a", profiles: [Profile(id: "a", name: "Alpha"),
                                                                  Profile(id: "b", name: "Beta")])

    /// 新建：追加到末尾，名称去首尾空白，不切换当前方案。
    @Test func add() throws {
        let result = try #require(ProfileEditor.add(named: "  Gamma ", to: base))
        #expect(result.profiles.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(result.activeProfileID == "a")
        #expect(result.profiles[2].thumbnail == ThumbnailSettings())
    }

    /// 克隆：内容相同、id 与名称不同，插在原方案之后。
    @Test func clone() throws {
        var config = base
        config.profiles[0].layouts = ["Pilot Alpha": ThumbnailLayout(x: 1, y: 2)]
        config.profiles[0].thumbnail.opacity = 0.9
        let result = try #require(ProfileEditor.clone(id: "a", newName: "Alpha copy", in: config))
        #expect(result.profiles.map(\.name) == ["Alpha", "Alpha copy", "Beta"])
        let copy = result.profiles[1]
        #expect(copy.id != "a" && !copy.id.isEmpty)
        var normalizedCopy = copy
        normalizedCopy.id = "a"
        normalizedCopy.name = "Alpha"
        #expect(normalizedCopy == config.profiles[0])
    }

    /// 克隆不存在的方案返回 nil。
    @Test func cloneMissing() {
        #expect(ProfileEditor.clone(id: "zzz", newName: "X", in: base) == nil)
    }

    /// 改名：可以只改大小写；与别的方案重名（不区分大小写）不行。
    @Test func rename() throws {
        let result = try #require(ProfileEditor.rename(id: "a", to: "ALPHA", in: base))
        #expect(result.profiles[0].name == "ALPHA")
        #expect(ProfileEditor.rename(id: "a", to: "beta", in: base) == nil)
        #expect(ProfileEditor.rename(id: "missing", to: "New", in: base) == nil)
    }

    /// 删除当前方案：当前方案改为同位置的下一个；删末尾的当前方案时改为新的末尾。
    @Test func deleteActive() throws {
        let first = try #require(ProfileEditor.delete(id: "a", in: base))
        #expect(first.profiles.map(\.id) == ["b"] && first.activeProfileID == "b")
        var config = base
        config.activeProfileID = "b"
        let last = try #require(ProfileEditor.delete(id: "b", in: config))
        #expect(last.activeProfileID == "a")
    }

    /// 删除非当前方案时当前方案不变。
    @Test func deleteInactive() throws {
        let result = try #require(ProfileEditor.delete(id: "b", in: base))
        #expect(result.activeProfileID == "a")
    }

    /// 最后一个方案不能删；不存在的方案返回 nil。
    @Test func cannotDeleteLast() {
        let single = AppConfig(activeProfileID: "a", profiles: [Profile(id: "a", name: "Only")])
        #expect(ProfileEditor.delete(id: "a", in: single) == nil)
        #expect(ProfileEditor.delete(id: "zzz", in: base) == nil)
    }

    /// 非法名称：空白、超过 64 字、与现有方案重名（不区分大小写、忽略首尾空白）。
    @Test(arguments: ["", "   ", String(repeating: "x", count: 65), "alpha", " BETA "])
    func invalidNames(name: String) {
        #expect(!ProfileEditor.isValidName(name, in: base, excluding: nil))
        #expect(ProfileEditor.add(named: name, to: base) == nil)
        #expect(ProfileEditor.clone(id: "a", newName: name, in: base) == nil)
    }

    /// 合法名称：恰好 64 字；排除自己时可用自己的名字。
    @Test func validNames() {
        #expect(ProfileEditor.isValidName(String(repeating: "x", count: 64), in: base, excluding: nil))
        #expect(ProfileEditor.isValidName("alpha", in: base, excluding: "a"))
    }
}
