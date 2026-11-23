// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志与游戏日志的一次性读取（docs/design-intel-translate.md 5.4 节、5.6 节）：读文件的一段字节、
// 探测聊天日志的文件头、回头找位置线索。跟踪服务、频道发现与探针共用，都是同步调用，在调用方的线程上执行。
// - 聊天日志是带 BOM 的 UTF-16 小端（C2）。任何起点都先经 ChatLogDirectory.alignedOffset 取偶数；
//   起点在文件中间时用指定了编码的 LogLineFramer，丢掉第一行（它可能是半行）。
// - 位置线索的回读与消息的补读分开：不按 backfillSeconds 过滤。Local 文件常常只有会话开始时的一行（C8），
//   按时间过滤会把它丢掉。
// - 只读：用 O_RDONLY 打开，不加锁，不写、不改、不删 EVE 目录下的任何内容。

import Darwin
import Foundation
import EVEOPreviewCore

/// 日志文件的一次性读取。
public enum LogTailReader {
    /// 探测聊天日志文件头时至多读的字节数（C3）。
    public static let headerProbeBytes = 4_096
    /// 回头找 Local 系统消息时读文件末尾的字节数：4 MiB。
    public static let localLookbackBytes: Int64 = 4_194_304
    /// 末尾没有系统消息时改读文件开头的字节数。
    public static let localHeadBytes: Int64 = 8_192
    /// 回头找游戏日志 (None) 行时读文件末尾的字节数：2 MiB。
    public static let gameLookbackBytes: Int64 = 2_097_152
    /// 游戏日志的回读至多上报的线索条数。
    public static let gameLookbackLimit = 20

    /// 聊天日志文件头的探测结果。
    public enum ChatHeaderProbe: Sendable, Equatable {
        /// 文件头完整（读满 4,096 字节仍没有第二条分隔线时也算完整，各字段为 nil）。
        case complete(ChatLogHeader)
        /// 文件头还没写完（文件刚建出来），稍后重读。
        case incomplete
        /// 打不开或读不了。
        case unreadable
    }

    // MARK: - 字节

    /// 打开文件只读，失败时返回 nil。调用方负责关闭。
    static func openReadOnly(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        return fd >= 0 ? fd : nil
    }

    /// 文件的当前长度；读不到时返回 nil。
    static func size(of fd: Int32) -> Int64? {
        var info = stat()
        return fstat(fd, &info) == 0 ? Int64(info.st_size) : nil
    }

    /// 读 [from, to) 的字节。EINTR 时重试；其他错误或提前读到文件末尾时返回已读到的部分。
    static func read(_ fd: Int32, from: Int64, to: Int64) -> Data {
        guard to > from else { return Data() }
        var data = Data(count: Int(to - from))
        var done = 0
        let total = data.count
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while done < total {
                let count = pread(fd, base + done, total - done, off_t(from) + off_t(done))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                done += count
            }
        }
        return done == total ? data : data.prefix(done)
    }

    /// 读 [from, to) 并切成完整的行，最后一行没有换行符时也算一行（一次性读取，不留半行给之后）。
    ///
    /// from 为 0 时由分行器按 BOM 判断编码；否则用 encoding 建分行器，并丢掉第一行。
    static func lines(_ fd: Int32, from: Int64, to: Int64, encoding: LogTextEncoding) -> [String] {
        var framer = LogLineFramer(encoding: from == 0 ? nil : encoding)
        var result = framer.append(read(fd, from: from, to: to))
        // 补一个换行，让最后一行也被切出来。UTF-16 小端的换行是 0A 00。
        let newline: [UInt8]
        switch framer.encoding ?? encoding {
        case .utf8: newline = [0x0A]
        case .utf16LittleEndian: newline = [0x0A, 0x00]
        case .utf16BigEndian: newline = [0x00, 0x0A]
        }
        result += framer.append(Data(newline))
        if from > 0, !result.isEmpty { result.removeFirst() }
        return result
    }

    // MARK: - 聊天日志的文件头

    /// 读文件开头至多 4,096 字节，取聊天日志的文件头（5.4 节扫描规则第 2 条）。
    public static func probeChatHeader(_ path: String) -> ChatHeaderProbe {
        guard let fd = openReadOnly(path) else { return .unreadable }
        defer { Darwin.close(fd) }
        let data = read(fd, from: 0, to: Int64(headerProbeBytes))
        var framer = LogLineFramer()
        let header = ChatLogParser.parseHeader(framer.append(data))
        if header.isComplete { return .complete(header) }
        // 读满了仍没有第二条分隔线：文件头不是预期的形式，按「完整、没有字段」处理，之后被忽略。
        if data.count >= headerProbeBytes {
            return .complete(ChatLogHeader(channelID: nil, channelName: nil, listener: nil, isComplete: true))
        }
        return .incomplete
    }

    // MARK: - 位置线索的回读

    /// Local 文件里最近的一条系统消息（5.6 节来源一）。
    ///
    /// 读末尾至多 4 MiB，取最后一条系统消息；没有时改读开头的 8,192 字节，取第一条（会话开始时写入的那一条）。
    /// end 是调用方已经取成偶数的文件长度。都没有时返回 nil。
    static func lastLocalSystemLine(_ fd: Int32, end: Int64) -> ChatLine? {
        let start = ChatLogDirectory.backfillStart(fileSize: end, maxBytes: localLookbackBytes)
        let tail = lines(fd, from: start, to: end, encoding: .utf16LittleEndian)
        if let last = tail.compactMap(ChatLogParser.parseLine).last(where: { $0.isSystem }) {
            return last
        }
        guard start > 0 else { return nil }
        let headEnd = ChatLogDirectory.alignedOffset(min(end, localHeadBytes))
        let head = lines(fd, from: 0, to: headEnd, encoding: .utf16LittleEndian)
        return head.lazy.compactMap(ChatLogParser.parseLine).first { $0.isSystem }
    }

    /// 游戏日志末尾至多 2 MiB 里类别是 None 的行，至多最后 20 条，按先后顺序（5.6 节来源二）。
    static func lastGameNotes(_ fd: Int32, end: Int64, encoding: LogTextEncoding) -> [(time: Double, text: String)] {
        var start = max(0, end - gameLookbackBytes)
        // 游戏日志多是 UTF-8（L4）；万一是 UTF-16，起点同样取偶数。
        if encoding != .utf8 { start = ChatLogDirectory.alignedOffset(start) }
        let notes = lines(fd, from: start, to: end, encoding: encoding).compactMap(LocationLineParser.gameNote)
        return Array(notes.suffix(gameLookbackLimit))
    }
}
