// SPDX-License-Identifier: GPL-3.0-or-later
//
// SemanticVersion 的用例（v1.1 设计 8.3 节、14.1 节）。

import Testing
import EVEOPreviewCore

/// 版本号的解析与比较。
struct SemanticVersionTests {
    /// 解析一个应当合法的版本号。
    private func v(_ text: String) throws -> SemanticVersion {
        try #require(SemanticVersion(text))
    }

    /// 带与不带 v（大小写都可以）解析出同样的版本。
    @Test(arguments: ["1.2.3", "v1.2.3", "V1.2.3"])
    func parsesWithOptionalPrefix(text: String) throws {
        let version = try #require(SemanticVersion(text))
        #expect(version.major == 1 && version.minor == 2 && version.patch == 3)
        #expect(version.prerelease.isEmpty && version.build.isEmpty)
        #expect(version.description == "1.2.3")
        #expect(!version.isPrerelease)
    }

    /// 两段、四段、空串、负数、非数字、空的预发布段等写法失败。
    @Test(arguments: ["1.1", "1.1.0.0", "", "-1.0.0", "1.-1.0", "1.0.a", "v", "1.0.0-", "1.0.0-alpha..1",
                      "1.0.0+", "1.0.0-al_pha", " 1.0.0", "1.0.0 ", "vv1.0.0", "1..0"])
    func rejectsInvalid(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    /// 预发布与构建信息分段保存，规范写法还原原文（不带 v）。
    @Test func parsesPrereleaseAndBuild() throws {
        let version = try #require(SemanticVersion("v1.2.0-beta.1+build.5"))
        #expect(version.prerelease == ["beta", "1"])
        #expect(version.build == ["build", "5"])
        #expect(version.isPrerelease)
        #expect(version.description == "1.2.0-beta.1+build.5")
    }

    /// 规范第 11 条的排序样例。
    @Test func specificationOrdering() throws {
        let texts = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                     "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        let versions = try texts.map { try #require(SemanticVersion($0)) }
        for index in 0..<(versions.count - 1) {
            #expect(versions[index] < versions[index + 1], "\(texts[index]) < \(texts[index + 1])")
            #expect(!(versions[index + 1] < versions[index]))
        }
        #expect(versions.shuffled().sorted() == versions)
    }

    /// 三段数字按数值比较：1.10.0 大于 1.9.0，2.0.0 大于 1.99.99。
    @Test func numericComparison() throws {
        #expect(try v("1.9.0") < v("1.10.0"))
        #expect(try v("1.99.99") < v("2.0.0"))
        #expect(try v("1.0.9") < v("1.0.10"))
    }

    /// 构建信息不参与比较、相等与哈希。
    @Test func buildMetadataIgnored() throws {
        let plain = try #require(SemanticVersion("1.0.0"))
        let built = try #require(SemanticVersion("1.0.0+20261121"))
        #expect(plain == built)
        #expect(!(plain < built) && !(built < plain))
        #expect(Set([plain, built]).count == 1)
    }

    /// CI 的标签小于同版本号的正式版、大于上一个正式版。
    @Test(arguments: ["1.1.0-pr.12.abc1234", "1.1.0-dev.abc1234", "v1.1.0-pr.3.0012345"])
    func ciLabelsSortBetweenReleases(text: String) throws {
        let label = try #require(SemanticVersion(text))
        #expect(try label < v("1.1.0"))
        #expect(try v("1.0.0") < label)
        #expect(label.isPrerelease)
    }

    /// 带前导零的数字段能解析，按含字母的段处理：排在纯数字段之后。
    @Test func leadingZeroSegmentsAreAlphanumeric() throws {
        let zero = try #require(SemanticVersion("1.1.0-pr.12.0012345"))
        #expect(zero.prerelease == ["pr", "12", "0012345"])
        #expect(try v("1.1.0-pr.12.99999999") < zero)
        #expect(try zero < v("1.1.0-pr.12.abc"))
    }

    /// 纯数字的段小于含字母的段；前面各段相同时段数多的更大。
    @Test func identifierRules() throws {
        #expect(try v("1.0.0-1") < v("1.0.0-a"))
        #expect(try v("1.0.0-a") < v("1.0.0-a.1"))
        #expect(try v("1.0.0-B") < v("1.0.0-a"))
        #expect(try v("1.0.0-pr.9") < v("1.0.0-pr.12"))
    }
}
