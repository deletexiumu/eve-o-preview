// SPDX-License-Identifier: GPL-3.0-or-later
//
// ChecksumList 的用例（v1.1 设计 9.2 节、14.1 节）。

import Testing
import EVEOPreviewCore

/// 校验和文件的解析。
struct ChecksumListTests {
    private let a = UpdateFixtures.digest("a")
    private let b = UpdateFixtures.digest("b")

    /// 文本模式（两个空格）与二进制模式（空格加 *）都认。
    @Test func textAndBinaryModes() throws {
        let entries = try ChecksumList.parse("\(a)  one.dmg\n\(b) *two.dmg\n")
        #expect(entries == ["one.dmg": a, "two.dmg": b])
    }

    /// 大写的十六进制转成小写。
    @Test func uppercaseHexLowercased() throws {
        let upper = String(repeating: "AB", count: 32)
        #expect(try ChecksumList.parse("\(upper)  x.dmg") == ["x.dmg": upper.lowercased()])
    }

    /// CRLF 的行尾去掉回车。
    @Test func crlfLineEndings() throws {
        let entries = try ChecksumList.parse("\(a)  one.dmg\r\n\(b)  two.dmg\r\n")
        #expect(entries == ["one.dmg": a, "two.dmg": b])
    }

    /// 空行与 # 开头的行跳过。
    @Test func blankAndCommentLinesSkipped() throws {
        let text = "# SHA-256\n\n\(a)  one.dmg\n\n# end\n"
        #expect(try ChecksumList.parse(text) == ["one.dmg": a])
    }

    /// 文件名可以含空格，分隔之后到行尾都算文件名。
    @Test func fileNameWithSpaces() throws {
        #expect(try ChecksumList.parse("\(a)  EVE-O Preview 1.1.1.dmg") == ["EVE-O Preview 1.1.1.dmg": a])
    }

    /// 63 位、含非十六进制字符、分隔不对、没有文件名、带路径分隔符的行使整个文件无效。
    @Test(arguments: [
        String(repeating: "a", count: 63) + "  x.dmg",
        String(repeating: "a", count: 63) + "g  x.dmg",
        String(repeating: "a", count: 64) + " x.dmg",
        String(repeating: "a", count: 64) + "\tx.dmg",
        String(repeating: "a", count: 64) + "  ",
        String(repeating: "a", count: 64) + "  dir/x.dmg",
        String(repeating: "a", count: 64) + "  dir\\x.dmg",
        "not a checksum line",
    ])
    func invalidLines(line: String) {
        #expect(throws: UpdateError.checksumListInvalid) { try ChecksumList.parse("\(a)  ok.dmg\n\(line)\n") }
    }

    /// 同名不同值无效；相同的重复行可以接受。
    @Test func duplicates() throws {
        #expect(throws: UpdateError.checksumListInvalid) { try ChecksumList.parse("\(a)  x.dmg\n\(b)  x.dmg\n") }
        #expect(try ChecksumList.parse("\(a)  x.dmg\n\(a)  x.dmg\n") == ["x.dmg": a])
        #expect(try ChecksumList.parse("\(a)  x.dmg\n\(a.uppercased()) *x.dmg\n") == ["x.dmg": a])
    }

    /// expectedHash 按文件名完全相等查找，找不到时报缺的文件名。
    @Test func expectedHash() throws {
        let text = "\(a)  EVE-O-Preview-1.1.1.dmg\n"
        #expect(try ChecksumList.expectedHash(for: "EVE-O-Preview-1.1.1.dmg", in: text) == a)
        #expect(throws: UpdateError.checksumEntryMissing("eve-o-preview-1.1.1.dmg")) {
            try ChecksumList.expectedHash(for: "eve-o-preview-1.1.1.dmg", in: text)
        }
        #expect(throws: UpdateError.checksumEntryMissing("EVE-O-Preview-1.1.2.dmg")) {
            try ChecksumList.expectedHash(for: "EVE-O-Preview-1.1.2.dmg", in: text)
        }
        #expect(throws: UpdateError.checksumListInvalid) { try ChecksumList.expectedHash(for: "x", in: "junk") }
    }

    /// 本仓库打包脚本的真实输出格式。
    @Test func packageScriptOutput() throws {
        let entries = try ChecksumList.parse(UpdateFixtures.packageScriptChecksums)
        #expect(entries.count == 3)
        #expect(try ChecksumList.expectedHash(for: "EVE-O-Preview-1.1.1.dmg", in: UpdateFixtures.packageScriptChecksums)
            == "00cbbd0ddbda2762798f7009838ed34ca1f12b93965813c7df22943bc62166d1")
    }

    /// 空文件解析成空表。
    @Test func emptyFile() throws {
        #expect(try ChecksumList.parse("").isEmpty)
    }
}
