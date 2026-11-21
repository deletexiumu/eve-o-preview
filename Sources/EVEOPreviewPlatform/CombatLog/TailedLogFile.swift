// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一个被跟踪的游戏日志文件（反馈文档 7.4 节）：描述符、已读偏移量、分行器与文件事件源。
// - 用 O_RDONLY 打开，同一个描述符既读内容又挂事件源，监听 write、extend、delete、rename。不加任何文件锁。
// - 描述符只在事件源的取消回调里关闭：取消之后内核不会再投递事件，关闭与读取也不会交错。
// - 只读不写：不改、不删 EVE 目录下的任何内容。
// - 读取出错（pread 返回负数，EINTR 除外）时不立即重读，交给 2 秒的保险定时器重试；每个文件只记一次日志，
//   下一次成功读取后才重新允许记录。
// - 从头读起的文件，接入时已有的内容是「积压」：读积压时丢掉时间早于接入时刻减容差的行，
//   不把旧历史当作新的受击（CombatLogReplayGuard）。
// 全部方法只在 CombatLogTailer 的串行队列上调用，所以类型不需要加锁。

import Darwin
import Dispatch
import Foundation
import os
import EVEOPreviewCore

/// 一个被跟踪的日志文件。只在跟踪服务的串行队列上访问。
final class TailedLogFile {
    /// 每次 `pread` 的块大小：64 KiB。
    static let chunkSize = 65_536
    /// 一次读取至多读这么多字节：1 MiB。还有剩余时由调用方立即再排一次。
    static let maxBytesPerRead = 1_048_576

    /// 文件名（不含目录）。含数字后缀，写系统日志时按 `.private` 记录。
    let name: String
    /// 文件头里的收听者。
    let listener: String
    /// 已读到的字节偏移量。
    private(set) var offset: Int64
    /// 是否已排定一次读取（100 毫秒内的多次写入合并成一次读取）。
    var readScheduled = false
    /// 已排定的这次读取由什么引起，探针用它区分文件事件与 2 秒保险（V13）。
    var pendingTrigger: CombatLogTailer.ReadTrigger = .fileEvent
    /// 已关闭。之后到达的读取请求直接忽略。
    private(set) var isClosed = false
    /// 接入时的文件长度；偏移量到达它之前读到的行是积压。从末尾读起的文件为 0（没有积压）。
    private var backlogEnd: Int64
    /// 接入时刻（1970 年以来的秒数），积压行的时间比它早过容差时丢弃。
    private let attachedAt: Double
    /// 读取出错的错误已经记过一次日志，下一次成功读取后清除。
    private var readErrorLogged = false
    private let log = PlatformLog.logger("CombatLog")

    /// 文件描述符；关闭由事件源的取消回调负责。
    private let fd: Int32
    /// 分行器。
    private var framer: LogLineFramer
    /// 文件事件源。
    private let source: DispatchSourceFileSystemObject
    /// 读取用的缓冲，跨读取复用。
    private var buffer = [UInt8](repeating: 0, count: TailedLogFile.chunkSize)

    /// 打开文件并挂上事件源。打不开时返回 nil。
    ///
    /// - Parameters:
    ///   - path: 文件的完整路径。
    ///   - startAtEnd: 为真时从当前的文件末尾读起（启动前已有的文件），否则从头读起。
    ///   - encoding: 文件头探测到的编码。从末尾读起时用它建分行器，不对中间的字节做 BOM 判断；
    ///     从头读起时传 nil，由分行器按开头的字节判断。
    ///   - attachedAt: 接入时刻（1970 年以来的秒数），从头读起时用来丢弃积压里的旧行。
    ///   - queue: 跟踪服务的串行队列，事件回调在这里执行。
    ///   - onEvent: 收到文件事件时调用，参数是事件的种类。
    init?(path: String, name: String, listener: String, startAtEnd: Bool, encoding: LogTextEncoding?,
          attachedAt: Double, queue: DispatchQueue, onEvent: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.name = name
        self.listener = listener
        self.offset = startAtEnd ? Int64(info.st_size) : 0
        self.backlogEnd = startAtEnd ? 0 : Int64(info.st_size)
        self.attachedAt = attachedAt
        self.framer = LogLineFramer(encoding: startAtEnd ? (encoding ?? .utf8) : nil)
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

    /// 当前的文件长度；读不到时返回 nil。
    func currentSize() -> Int64? {
        guard !isClosed else { return nil }
        var info = stat()
        return fstat(fd, &info) == 0 ? Int64(info.st_size) : nil
    }

    /// 读新增的字节并切成完整的行。返回这次凑齐的行，以及文件里是否还有没读的内容。
    ///
    /// 文件长度小于已读偏移量时视为被截断：偏移量改成 0，分行器重置，之后的内容都是新写入的，不再有积压。
    /// 读取出错或意外读到 0 字节时 `hasMore` 为 false，由 2 秒的保险定时器重试，不会立即重读造成死循环。
    func readNewLines() -> (lines: [String], hasMore: Bool) {
        guard let size = currentSize() else { return ([], false) }
        let start = CombatLogDirectory.readStart(offset: offset, fileSize: size)
        if start.truncated {
            offset = 0
            backlogEnd = 0
            framer.reset()
        }
        // 这次读取从积压里开始时，读到的行要过一遍历史回放的过滤。
        let readsBacklog = offset < backlogEnd
        var lines: [String] = []
        var total = 0
        var failed = false
        while offset < size, total < TailedLogFile.maxBytesPerRead {
            let want = min(TailedLogFile.chunkSize, Int(size - offset), TailedLogFile.maxBytesPerRead - total)
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress, want, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                recordReadError(errno)
                failed = true
                break
            }
            guard count > 0 else {
                // 长度说有内容、却读到 0 字节（文件在 fstat 与 pread 之间被截断）：交给下一次读取处理。
                failed = true
                break
            }
            readErrorLogged = false
            offset += Int64(count)
            total += count
            lines += framer.append(Data(buffer[0..<count]))
        }
        if readsBacklog {
            lines = lines.filter { CombatLogReplayGuard.shouldKeep($0, attachedAt: attachedAt) }
        }
        return (lines, !failed && offset < size)
    }

    /// 记录一次读取错误：同一个文件连续出错时只记第一次，错误码是公开的数字，文件名按 `.private`。
    private func recordReadError(_ code: Int32) {
        guard !readErrorLogged else { return }
        readErrorLogged = true
        log.error("读游戏日志文件失败：\(self.name, privacy: .private)，errno \(code, privacy: .public)，等待保险定时器重试")
    }

    /// 取消事件源（由取消回调关闭描述符）。可重复调用。
    func close() {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
    }
}

// MARK: - 目录与文件头的读取

/// 游戏日志目录与文件的只读操作，跟踪服务与探针共用。都是同步调用，在调用方的线程上执行。
public enum GameLogFileSystem {
    /// 读文件头时至多读的字节数（7.3 节第 3 条）。
    public static let headerProbeBytes = 2_048

    /// 列目录的结果。
    public enum Listing: Sendable, Equatable {
        /// 目录下的全部条目名（不含 `.` 与 `..`）。
        case entries([String])
        /// 被系统拒绝（EACCES 或 EPERM，缺「文件与文件夹」权限，V12）。
        case denied
        /// 不存在或不是目录。
        case missing
    }

    /// 文件头的探测结果。
    public enum HeaderProbe: Sendable, Equatable {
        /// 文件头完整：收听者（可能为 nil）与编码。
        case complete(listener: String?, encoding: LogTextEncoding?)
        /// 文件头还没写完（文件刚建出来）。
        case incomplete
        /// 打不开或读不了。
        case unreadable
    }

    /// 一个文件的时间与长度，时间是 1970 年以来的秒数。
    public struct FileInfo: Sendable, Equatable {
        /// 修改时间。
        public var modifiedAt: Double
        /// 创建时间。
        public var createdAt: Double
        /// 长度（字节）。
        public var size: Int64
    }

    /// 列目录。权限错误与「不存在」按 `errno` 区分，不用 `fileExists`（它把权限错误也报成不存在）。
    public static func list(_ path: String) -> Listing {
        guard let dir = opendir(path) else {
            return (errno == EACCES || errno == EPERM) ? .denied : .missing
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return .entries(names)
    }

    /// 取文件的修改时间、创建时间与长度；读不到时返回 nil。
    public static func info(_ path: String) -> FileInfo? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        func seconds(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        return FileInfo(modifiedAt: seconds(st.st_mtimespec), createdAt: seconds(st.st_birthtimespec),
                        size: Int64(st.st_size))
    }

    /// 读文件开头至多 2,048 字节，取收听者与编码。读满仍不完整时按「完整、没有收听者」处理。
    public static func probeHeader(_ path: String) -> HeaderProbe {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .unreadable }
        defer { Darwin.close(fd) }
        var bytes = [UInt8](repeating: 0, count: headerProbeBytes)
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, headerProbeBytes, 0) }
        guard count >= 0 else { return .unreadable }
        var framer = LogLineFramer()
        let lines = framer.append(Data(bytes[0..<count]))
        let header = CombatLogHeaderParser.parse(lines)
        if header.isComplete || count >= headerProbeBytes {
            return .complete(listener: header.listener, encoding: framer.encoding)
        }
        return .incomplete
    }
}
