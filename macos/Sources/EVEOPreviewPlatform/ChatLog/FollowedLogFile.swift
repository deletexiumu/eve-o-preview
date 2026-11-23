// SPDX-License-Identifier: GPL-3.0-or-later
//
// ChatLogTailer 跟踪的一个文件（docs/design-intel-translate.md 5.4 节）：描述符、已读偏移量、分行器与文件事件源。
// 聊天日志与游戏日志共用这个类型，用 Role 区分。做法同 CombatLog/TailedLogFile.swift，不改后者：
// - O_RDONLY 打开，同一个描述符既读内容又挂事件源，监听 write、extend、delete、rename；不加文件锁。
// - 描述符只在事件源的取消回调里关闭，关闭与读取不会交错。
// - UTF-16 的文件（聊天日志，C2）：起点与每次读取的终点都取偶数，偏移量永远是偶数。起点落在奇数字节上时
//   之后的每个字符都会错位。起点在文件中间时用指定了编码的分行器，并丢掉读到的第一行（可能是半行）。
// - 文件长度小于已读偏移量时视为被截断：偏移量改成 0，分行器重置。
// - 读取出错（pread 返回负数，EINTR 除外）时不立即重读，交给 2 秒的保险定时器；每个文件只记一次日志。
// 全部方法只在 ChatLogTailer 的串行队列上调用，所以类型不加锁。

import Darwin
import Dispatch
import Foundation
import os
import EVEOPreviewCore

/// 被跟踪的一个日志文件。只在跟踪服务的串行队列上访问。
final class FollowedLogFile {
    /// 文件的角色。
    enum Role {
        /// 聊天日志：文件头、频道种类，以及它是否与请求里的某个频道匹配（只为位置线索跟踪的 Local 文件为假）。
        case chat(header: ChatLogHeader, kind: ChatChannelKind, isRequested: Bool)
        /// 游戏日志：只取类别是 None 的行作位置线索。
        case game
    }

    /// 每次 `pread` 的块大小：64 KiB（偶数）。
    static let chunkSize = 65_536
    /// 一次读取至多读这么多字节：1 MiB（偶数）。还有剩余时由调用方立即再排一次。
    static let maxBytesPerRead: Int64 = 1_048_576

    /// 跟踪服务里的键：`chat/` 或 `game/` 加文件名，聊天日志与游戏日志的文件名不会冲突。
    let key: String
    /// 文件名（不含目录）。含频道名或角色相关的后缀，写系统日志时按 `.private` 记录。
    let name: String
    /// 文件头里的收听者。
    let listener: String
    /// 文件的角色。
    let role: Role
    /// 是否按 UTF-16 读（偏移量取偶数）。
    let isUTF16: Bool
    /// 已读到的字节偏移量。
    private(set) var offset: Int64
    /// 是否已排定一次读取（100 毫秒内的多次写入合并成一次读取）。
    var readScheduled = false
    /// 已关闭。之后到达的读取请求直接忽略。
    private(set) var isClosed = false

    /// 文件描述符；关闭由事件源的取消回调负责。
    let fd: Int32
    /// 分行器。
    private var framer: LogLineFramer
    /// 下一次切出的第一行要丢掉（起点在文件中间）。
    private var dropsFirstLine: Bool
    /// 文件事件源。
    private let source: DispatchSourceFileSystemObject
    /// 读取出错的错误已经记过一次日志，下一次成功读取后清除。
    private var readErrorLogged = false
    /// 文件的编码。
    private let encoding: LogTextEncoding
    private let log = PlatformLog.logger("ChatLog")

    /// 打开文件并挂上事件源，偏移量停在 0。打不开时返回 nil。之后由 `seek(to:dropsFirstLine:)` 定起点。
    ///
    /// - Parameters:
    ///   - path: 文件的完整路径。
    ///   - key: 跟踪服务里的键。
    ///   - encoding: 文件的编码；从文件中间读起时用它建分行器。
    ///   - queue: 跟踪服务的串行队列，事件回调在这里执行。
    ///   - onEvent: 收到文件事件时调用，参数是事件的种类。
    init?(path: String, key: String, name: String, listener: String, role: Role, encoding: LogTextEncoding,
          queue: DispatchQueue, onEvent: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) {
        guard let fd = LogTailReader.openReadOnly(path) else { return nil }
        self.fd = fd
        self.key = key
        self.name = name
        self.listener = listener
        self.role = role
        self.isUTF16 = encoding != .utf8
        self.offset = 0
        self.framer = LogLineFramer()
        self.dropsFirstLine = false
        self.encoding = encoding
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        // 事件的种类在回调里读取；回调只捕获可发送的值。
        source.setEventHandler { [weak source] in
            guard let source else { return }
            onEvent(source.data)
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    /// 当前的文件长度；UTF-16 的文件取偶数。读不到或已关闭时返回 nil。
    func currentSize() -> Int64? {
        guard !isClosed, let size = LogTailReader.size(of: fd) else { return nil }
        return isUTF16 ? ChatLogDirectory.alignedOffset(size) : size
    }

    /// 定起点并重建分行器。0 表示从头读（按 BOM 判断编码）；其余用指定的编码从文件中间读。
    ///
    /// - Parameters:
    ///   - start: 起点；UTF-16 的文件取成偶数。
    ///   - dropsFirstLine: 为真时丢掉读到的第一行。补读的起点可能落在一行中间，应为真；
    ///     从文件末尾读起时末尾是行的边界（EVE 整行写入），应为假，否则会丢掉之后的第一条消息。
    func seek(to start: Int64, dropsFirstLine: Bool) {
        let aligned = isUTF16 ? ChatLogDirectory.alignedOffset(start) : max(0, start)
        offset = aligned
        framer = LogLineFramer(encoding: aligned == 0 ? nil : encoding)
        self.dropsFirstLine = aligned > 0 && dropsFirstLine
    }

    /// 读到 limit（不含）或当前末尾为止的新内容，切成完整的行。返回这次的行，以及到 limit 或末尾前是否还有没读的内容。
    ///
    /// 最后一行没有换行符时留在分行器里，下一次读取凑齐。一次至多读 1 MiB。
    func readLines(upTo limit: Int64? = nil) -> (lines: [String], hasMore: Bool) {
        guard let size = currentSize() else { return ([], false) }
        let start = CombatLogDirectory.readStart(offset: offset, fileSize: size)
        if start.truncated {
            log.notice("日志文件被截断，从头重读：\(self.name, privacy: .private)")
            offset = 0
            framer = LogLineFramer()
            dropsFirstLine = false
        }
        let end = min(size, limit ?? size, offset + FollowedLogFile.maxBytesPerRead)
        guard end > offset else { return ([], false) }
        var lines: [String] = []
        var failed = false
        var buffer = [UInt8](repeating: 0, count: FollowedLogFile.chunkSize)
        while offset < end {
            let want = min(FollowedLogFile.chunkSize, Int(end - offset))
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                recordReadError(errno)
                failed = true
                break
            }
            // 长度说有内容、却读到 0 字节（文件在 fstat 与 pread 之间被截断）：交给下一次读取处理。
            guard count > 0 else {
                failed = true
                break
            }
            readErrorLogged = false
            offset += Int64(count)
            lines += framer.append(Data(buffer[0..<count]))
        }
        if dropsFirstLine, !lines.isEmpty {
            lines.removeFirst()
            dropsFirstLine = false
        }
        return (lines, !failed && offset < min(size, limit ?? size))
    }

    /// 记录一次读取错误：同一个文件连续出错时只记第一次，错误码是公开的数字，文件名按 `.private`。
    private func recordReadError(_ code: Int32) {
        guard !readErrorLogged else { return }
        readErrorLogged = true
        log.error("读日志文件失败：\(self.name, privacy: .private)，errno \(code, privacy: .public)，等待保险定时器重试")
    }

    /// 取消事件源（由取消回调关闭描述符）。可重复调用。
    func close() {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
    }
}
