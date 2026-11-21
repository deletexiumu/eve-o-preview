// SPDX-License-Identifier: GPL-3.0-or-later
//
// 带轮转的日志文件（v1.1 设计 5.2 节）。
//
// - 目录不存在时创建，权限 0700；新文件权限 0600，已有文件打开时也改成 0600。
// - 每次 `append` 直接 `write(2)`，不经过用户态缓冲：崩溃前最后一行已经交给了内核。不调 `fsync`。
// - 文件以 `O_APPEND` 打开，演示模式与正式运行同时写同一个目录时各行不会互相覆盖。
// - 轮转只看大小，不在启动时轮转：追加前当前文件不空，且「当前大小 + 这一行」超过上限时轮转。
//   做法：关闭当前文件，删掉最旧的 `.N`，`.N-1`～`.1` 依次改名为后一个序号，当前文件改名为 `.1`，再建新文件。
// - 一行就超过上限时仍写进空文件，下一行再轮转。
//
// 只用 Foundation 带出的 POSIX 函数（open、write、rename），不 import 别的模块。

import Foundation

/// 轮转的参数。
public struct LogRotationPolicy: Sendable, Equatable {
    /// 单个文件的上限，单位是字节，默认 1,048,576。
    public var maxFileBytes: Int
    /// 保留的旧文件个数，默认 4。
    public var maxArchives: Int

    /// 用各字段建参数。
    public init(maxFileBytes: Int = 1_048_576, maxArchives: Int = 4) {
        self.maxFileBytes = maxFileBytes
        self.maxArchives = maxArchives
    }

    /// 设计 5.2 节的取值：1 MiB，4 个旧文件。
    public static let standard = LogRotationPolicy()
}

/// 写日志文件失败的原因。`errno` 是失败时的系统错误号。
public enum RotatingLogFileError: Error, Sendable, Equatable {
    /// 建目录失败。
    case createDirectoryFailed(path: String, reason: String)
    /// 打开文件失败。
    case openFailed(path: String, errno: Int32)
    /// 写入失败。
    case writeFailed(path: String, errno: Int32)
    /// 轮转时改名失败。
    case rotateFailed(path: String, errno: Int32)
}

/// 带轮转的日志文件。不是线程安全的，由调用方串行使用。
public final class RotatingLogFile {
    /// 文件的位置与命名。
    public let layout: LogFileLayout
    /// 轮转的参数。
    public let policy: LogRotationPolicy
    /// 当前文件的描述符；没有打开时是 -1。
    private var descriptor: Int32 = -1
    /// 当前文件的字节数，打开时从 `fstat` 取，之后按写入累加。
    private var currentSize = 0

    /// 建文件对象。不碰磁盘，第一次 `append` 时才建目录、打开文件。
    public init(layout: LogFileLayout, policy: LogRotationPolicy) {
        self.layout = layout
        self.policy = policy
    }

    deinit {
        close()
    }

    /// 追加一行。line 不应含换行符，这里在行尾加一个 `\n`。
    ///
    /// 需要时先轮转。失败时抛 `RotatingLogFileError`，文件保持关闭，下一次调用会重新打开。
    public func append(_ line: String) throws {
        var bytes = Array(line.utf8)
        bytes.append(UInt8(ascii: "\n"))
        try openIfNeeded()
        if currentSize > 0, currentSize + bytes.count > policy.maxFileBytes {
            try rotate()
            try openIfNeeded()
        }
        try writeAll(bytes)
        currentSize += bytes.count
    }

    /// 关闭当前文件。之后再 `append` 会重新打开。
    public func close() {
        guard descriptor >= 0 else { return }
        _ = Foundation.close(descriptor)
        descriptor = -1
        currentSize = 0
    }

    // MARK: - 打开、写入与轮转

    /// 没有打开时建目录并打开当前文件，读出已有的大小。
    private func openIfNeeded() throws {
        guard descriptor < 0 else { return }
        try createDirectoryIfNeeded()
        let path = layout.currentURL.path
        let fd = Foundation.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw RotatingLogFileError.openFailed(path: path, errno: errno) }
        // 已有的文件可能是别的权限（如用户手工建的），统一改成 0600。
        _ = fchmod(fd, mode_t(0o600))
        var info = stat()
        currentSize = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        descriptor = fd
    }

    /// 目录不存在时创建，权限 0700。已存在的目录不改权限（`EVEO_LOG_DIR` 可能指向别人的目录）。
    private func createDirectoryIfNeeded() throws {
        let directory = layout.directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw RotatingLogFileError.createDirectoryFailed(path: directory.path, reason: String(describing: error))
        }
    }

    /// 把全部字节写进当前文件。处理部分写入与被信号打断（EINTR）。
    private func writeAll(_ bytes: [UInt8]) throws {
        let path = layout.currentURL.path
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    close()
                    throw RotatingLogFileError.writeFailed(path: path, errno: code)
                }
                offset += written
            }
        }
    }

    /// 轮转：关闭当前文件，删最旧的旧文件，其余旧文件序号加一，当前文件改名为 `.1`。
    ///
    /// 不存在的旧文件跳过，序号中间有空缺时不补齐。`maxArchives` 为 0 时直接删掉当前文件。
    private func rotate() throws {
        close()
        let manager = FileManager.default
        guard policy.maxArchives > 0 else {
            try? manager.removeItem(at: layout.currentURL)
            return
        }
        try? manager.removeItem(at: layout.archiveURL(policy.maxArchives))
        for index in stride(from: policy.maxArchives - 1, through: 1, by: -1) {
            let source = layout.archiveURL(index)
            guard manager.fileExists(atPath: source.path) else { continue }
            try rename(source, to: layout.archiveURL(index + 1))
        }
        try rename(layout.currentURL, to: layout.archiveURL(1))
    }

    /// 改名，目标已存在时覆盖。
    private func rename(_ source: URL, to destination: URL) throws {
        guard Foundation.rename(source.path, destination.path) == 0 else {
            throw RotatingLogFileError.rotateFailed(path: source.path, errno: errno)
        }
    }
}
