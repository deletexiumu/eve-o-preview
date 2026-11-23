// SPDX-License-Identifier: GPL-3.0-or-later
//
// 把读到的字节切成完整的文本行（反馈文档 7.4 节）。
// - 编码在凑够开头 3 个字节后判断一次：FF FE 是 UTF-16 小端，FE FF 是 UTF-16 大端，EF BB BF 是带 BOM 的
//   UTF-8，其余是 UTF-8。BOM 不进入输出。本机的游戏日志都是不带 BOM 的 UTF-8（L4），UTF-16 只作防御。
// - 从文件中间开始读时，调用方用文件头确定编码后以 init(encoding:) 建分行器，不对中间的字节做 BOM 判断。
// - 只在换行符（UTF-8 的 0A，UTF-16 按 2 字节码元对齐的 000A）处切行，所以多字节字符被两次读取切开时，
//   尾部自然留在缓冲里；行尾的回车去掉。
// - 一行超过 maxLineBytes 时丢弃这一行直到下一个换行符，缓冲的大小因此有上限。
// - 解码失败的字节用 U+FFFD 代替，不抛错。

import Foundation

/// 日志文件的文本编码。
public enum LogTextEncoding: Sendable, Equatable {
    case utf8, utf16LittleEndian, utf16BigEndian
}

/// 按换行符切行的分行器。值类型，由调用方在自己的队列上持有。
public struct LogLineFramer: Sendable {
    /// 当前编码；nil 表示还没读到足够的字节来判断。
    public private(set) var encoding: LogTextEncoding?
    /// 建分行器时指定的编码，`reset()` 后恢复成它。
    private let initialEncoding: LogTextEncoding?
    /// 一行的字节上限，超过的行被丢弃。
    private let maxLineBytes: Int
    /// 还没凑成完整行的字节。
    private var buffer: [UInt8] = []
    /// 正在丢弃一条超长的行，直到下一个换行符。
    private var discarding = false

    /// 建分行器。encoding 为 nil 时按开头的字节判断编码；有值时直接使用，不做 BOM 判断。
    public init(encoding: LogTextEncoding? = nil, maxLineBytes: Int = 65_536) {
        self.encoding = encoding
        self.initialEncoding = encoding
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// 追加一段字节，返回这次凑齐的完整行（不含换行符）。不完整的尾部留到下次。
    public mutating func append(_ data: Data) -> [String] {
        buffer.append(contentsOf: data)
        if encoding == nil {
            // 不到 3 个字节时还分不清是不是 BOM，先攒着。
            guard buffer.count >= 3 else { return [] }
            detectEncoding()
        }
        guard let encoding else { return [] }
        return encoding == .utf8 ? splitUTF8() : splitUTF16(bigEndian: encoding == .utf16BigEndian)
    }

    /// 清空缓冲，编码恢复成建分行器时指定的值（文件被截断、从头重读时调用）。
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        discarding = false
        encoding = initialEncoding
    }

    // MARK: - 内部

    /// 按开头的字节判断编码，去掉 BOM。
    private mutating func detectEncoding() {
        if buffer[0] == 0xFF, buffer[1] == 0xFE {
            encoding = .utf16LittleEndian
            buffer.removeFirst(2)
        } else if buffer[0] == 0xFE, buffer[1] == 0xFF {
            encoding = .utf16BigEndian
            buffer.removeFirst(2)
        } else if buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF {
            encoding = .utf8
            buffer.removeFirst(3)
        } else {
            encoding = .utf8
        }
    }

    /// UTF-8：在 0A 处切行，去掉行尾的 0D。
    private mutating func splitUTF8() -> [String] {
        var lines: [String] = []
        var start = 0
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var end = newline
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            if accepts(end - start) {
                lines.append(String(decoding: buffer[start..<end], as: UTF8.self))
            }
            start = newline + 1
        }
        keepTail(from: start)
        return lines
    }

    /// UTF-16：按 2 字节的码元对齐查找 000A，去掉行尾的 000D。
    private mutating func splitUTF16(bigEndian: Bool) -> [String] {
        var lines: [String] = []
        var start = 0
        var index = 0
        // 读一个码元的值。
        func unit(at i: Int) -> UInt16 {
            bigEndian ? UInt16(buffer[i]) << 8 | UInt16(buffer[i + 1])
                      : UInt16(buffer[i + 1]) << 8 | UInt16(buffer[i])
        }
        while index + 1 < buffer.count {
            if unit(at: index) == 0x000A {
                var end = index
                if end - start >= 2, unit(at: end - 2) == 0x000D { end -= 2 }
                if accepts(end - start) {
                    let units = stride(from: start, to: end - 1, by: 2).map { unit(at: $0) }
                    lines.append(String(decoding: units, as: UTF16.self))
                }
                start = index + 2
            }
            index += 2
        }
        keepTail(from: start)
        return lines
    }

    /// 一行是否输出。正在丢弃超长行时，这一段是超长行的结尾，不输出；超过上限的行同样丢弃。
    private mutating func accepts(_ byteCount: Int) -> Bool {
        if discarding {
            discarding = false
            return false
        }
        return byteCount <= maxLineBytes
    }

    /// 去掉已切出的部分，只留不完整的尾部。尾部超过上限时清空并进入丢弃状态，缓冲不会无限增长。
    ///
    /// 比较长度时不计尾部可能属于行尾 CRLF 的回车（见 `trailingCarriageReturnBytes`），
    /// 这样「内容正好等于上限、回车与换行被切开」的行与一次追加时的结果一致。
    /// 少算只会推迟丢弃：真正超长的行到换行符时仍由 `accepts` 丢掉，缓冲最多多留一个回车。
    private mutating func keepTail(from start: Int) {
        buffer.removeFirst(start)
        if buffer.count - trailingCarriageReturnBytes() > maxLineBytes {
            // UTF-16 的缓冲是奇数个字节时，最后一个字节是半个码元，留下它以免后面的码元错位。
            let keep = (encoding != .utf8 && buffer.count % 2 == 1) ? 1 : 0
            buffer.removeFirst(buffer.count - keep)
            discarding = true
        }
    }

    /// 缓冲尾部可能属于行尾 CRLF 的字节数（回车，以及切在换行码元中间的前半个码元）。
    ///
    /// UTF-8 是 1（0D）。UTF-16 是完整的 000D 码元的 2 字节；缓冲是奇数个字节时，最后一个字节是下一个码元的
    /// 前半个，它可能是回车或换行的前半个（小端 0D、0A，大端 00），也算进去，其前面若是完整的回车再加 2。
    /// 这里宁可少算：算少只会推迟丢弃，真正超长的行到换行符时仍由 `accepts` 丢掉。
    private func trailingCarriageReturnBytes() -> Int {
        guard let last = buffer.last else { return 0 }
        switch encoding {
        case .utf8:
            return last == 0x0D ? 1 : 0
        case .utf16LittleEndian, .utf16BigEndian:
            let littleEndian = encoding == .utf16LittleEndian
            var n = buffer.count
            var uncounted = 0
            if n % 2 == 1 {
                // 最后一个字节是下一个码元的前半个。
                let isLineEndStart = littleEndian ? (last == 0x0D || last == 0x0A) : last == 0x00
                guard isLineEndStart else { return 0 }
                uncounted = 1
                n -= 1
            }
            guard n >= 2 else { return uncounted }
            let isCR = littleEndian ? (buffer[n - 2] == 0x0D && buffer[n - 1] == 0x00)
                                    : (buffer[n - 2] == 0x00 && buffer[n - 1] == 0x0D)
            return uncounted + (isCR ? 2 : 0)
        case nil:
            return 0
        }
    }
}
