// SPDX-License-Identifier: GPL-3.0-or-later
//
// LogLineFramer 的用例（反馈文档 7.4 节、10.1 节）。

import Foundation
import Testing
import EVEOPreviewCore

/// 分行器：多字节字符被切开、半行、CRLF、BOM、UTF-16、超长行、reset 与指定编码。
struct LogLineFramerTests {
    /// UTF-8 字节。
    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// 一个汉字的 3 个字节被切在两次追加之间，拼起来后输出完整的行。
    @Test func multibyteSplitAcrossAppends() {
        var framer = LogLineFramer()
        let data = bytes("收听者\n")
        // 「收」占前 3 个字节，在第 2 个字节处切开。
        #expect(framer.append(data.prefix(2)).isEmpty)
        #expect(framer.append(data.dropFirst(2)) == ["收听者"])
        #expect(framer.encoding == .utf8)
    }

    /// 尾部的半行留到下次。
    @Test func partialLineKeptForNextAppend() {
        var framer = LogLineFramer()
        #expect(framer.append(bytes("first\nsec")) == ["first"])
        #expect(framer.append(bytes("ond\nthird")) == ["second"])
        #expect(framer.append(bytes("\n")) == ["third"])
    }

    /// CRLF 的回车被去掉；空行照常输出。
    @Test func crlfAndEmptyLines() {
        var framer = LogLineFramer()
        #expect(framer.append(bytes("a\r\n\r\nb\n")) == ["a", "", "b"])
    }

    /// 带 BOM 的 UTF-8：BOM 不进入输出。
    @Test func utf8WithBOM() {
        var framer = LogLineFramer()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(bytes("游戏记录\n"))
        #expect(framer.append(data) == ["游戏记录"])
        #expect(framer.encoding == .utf8)
    }

    /// 不到 3 个字节时不判断编码，凑够后再判断。
    @Test func waitsForThreeBytes() {
        var framer = LogLineFramer()
        #expect(framer.append(Data([0xEF, 0xBB])).isEmpty)
        #expect(framer.encoding == nil)
        #expect(framer.append(Data([0xBF]) + bytes("x\n")) == ["x"])
    }

    /// UTF-16 小端与大端，含 CRLF 与被切开的码元。
    @Test(arguments: [true, false])
    func utf16(bigEndian: Bool) {
        var framer = LogLineFramer()
        let text = "频道\r\nLocal\n"
        var data = Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE])
        for unit in text.utf16 {
            let pair = bigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF), UInt8(unit >> 8)]
            data.append(contentsOf: pair)
        }
        // 在奇数字节处切开，第一段末尾是半个码元。
        let cut = 5
        let first = framer.append(data.prefix(cut))
        let second = framer.append(data.dropFirst(cut))
        #expect(first + second == ["频道", "Local"])
        #expect(framer.encoding == (bigEndian ? .utf16BigEndian : .utf16LittleEndian))
    }

    /// 超长行被丢弃，之后的行恢复正常；跨多次追加的超长行也一样。
    @Test func overlongLineDiscarded() {
        var framer = LogLineFramer(maxLineBytes: 8)
        #expect(framer.append(bytes("ok\n0123456789\nfine\n")) == ["ok", "fine"])
        // 超长行分几次到达：尾部超过上限后进入丢弃状态，直到下一个换行符。
        #expect(framer.append(bytes("abcdefghij")).isEmpty)
        #expect(framer.append(bytes("klmnop")).isEmpty)
        #expect(framer.append(bytes("q\nnext\n")) == ["next"])
    }

    /// reset 清空缓冲，编码恢复成建分行器时的值（自动判断时重新判断）。
    @Test func resetClearsState() {
        var framer = LogLineFramer()
        #expect(framer.append(bytes("half")).isEmpty)
        framer.reset()
        #expect(framer.encoding == nil)
        #expect(framer.append(bytes("whole\n")) == ["whole"])
    }

    /// 指定编码时不做 BOM 判断：中间的 EF BB BF 按普通字节解码成 U+FEFF。
    @Test func explicitEncodingSkipsDetection() {
        var framer = LogLineFramer(encoding: .utf8)
        #expect(framer.encoding == .utf8)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(bytes("x\n"))
        #expect(framer.append(data) == ["\u{FEFF}x"])
        // 指定了编码时，不到 3 个字节也能切行。
        #expect(framer.append(bytes("y\n")) == ["y"])
    }

    /// 非法的 UTF-8 字节用 U+FFFD 代替，不抛错。
    @Test func invalidBytesReplaced() {
        var framer = LogLineFramer(encoding: .utf8)
        #expect(framer.append(Data([0x61, 0xFF, 0x62, 0x0A])) == ["a\u{FFFD}b"])
    }
}
