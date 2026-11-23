// SPDX-License-Identifier: GPL-3.0-or-later
//
// 运行系统工具的小工具（v1.1 设计 4.2、4.3 节）。`ReportArchiver` 用它运行 `ditto`，`DiskImage` 用它运行 `hdiutil`。
//
// - 直接启动可执行文件，不经过 shell，参数不会被解释。
// - 标准输出与标准错误各在一个后台线程读到结束：输出超过管道缓冲区（64 KiB）时，
//   如果等进程结束后才读，进程会卡在写管道上，永远不结束。
// - 等待在 GCD 的后台队列上阻塞进行，不占 Swift 并发的协作线程。
// - 超时后先发 SIGTERM，2 秒内没有结束再发 SIGKILL。

import Foundation
import os

/// 一次运行的结果。
public struct ProcessResult: Sendable, Equatable {
    /// 退出码；被信号终止时是信号值（`Process.terminationStatus` 的口径）。
    public var status: Int32
    /// 标准输出的全部内容。
    public var standardOutput: Data
    /// 标准错误，按 UTF-8 解码（非法字节换成替换字符）。
    public var standardError: String

    /// 用各字段建结果。
    public init(status: Int32, standardOutput: Data, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// 运行失败的原因。退出码不为 0 不算失败，由调用方看 `ProcessResult.status`。
public enum ProcessRunnerError: Error, Sendable, Equatable {
    /// 进程没能启动，关联值是系统的说明。
    case launchFailed(String)
    /// 超过 timeout 秒没有结束，已被终止。
    case timedOut
}

/// 运行系统工具。
public enum ProcessRunner {
    /// 超时后发 SIGTERM，再等多少秒发 SIGKILL。
    static let terminateGrace: Double = 2
    /// 进程结束后，最多再等多少秒让两个管道读完（子进程的子进程可能还开着管道）。
    /// 到时没读完也返回：按块读，已读到的部分保留在结果里。
    static let drainGrace: Double = 2

    /// 运行一个系统工具并等它结束；超过 timeout 秒时终止它。不经过 shell。
    public static func run(_ executable: String, arguments: [String], timeout: Double) async throws(ProcessRunnerError)
        -> ProcessResult {
        let result: Result<ProcessResult, ProcessRunnerError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, timeout: timeout))
            }
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    /// 在当前线程上启动并等待进程。只在后台队列上调用。
    private static func runBlocking(_ executable: String, arguments: [String], timeout: Double)
        -> Result<ProcessResult, ProcessRunnerError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // 结束回调要在 run() 之前设置，否则进程很快结束时会错过它。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(String(describing: error)))
        }
        let readers = DispatchGroup()
        let outputBuffer = drain(output, group: readers)
        let errorBuffer = drain(errors, group: readers)

        var timedOut = false
        if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + terminateGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        _ = readers.wait(timeout: .now() + drainGrace)
        if timedOut { return .failure(.timedOut) }
        return .success(ProcessResult(status: process.terminationStatus, standardOutput: outputBuffer.data,
                                      standardError: String(decoding: errorBuffer.data, as: UTF8.self)))
    }

    /// 在后台线程上按块把管道读到结束，返回收集结果的缓冲区。
    ///
    /// 不用 `readDataToEndOfFile`：它到结束才交出数据，进程的子进程一直开着管道时，等不到结束就什么也拿不到。
    private static func drain(_ pipe: Pipe, group: DispatchGroup) -> DataBuffer {
        let buffer = DataBuffer()
        let handle = pipe.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            group.leave()
        }
        return buffer
    }
}

/// 跨线程交接一段数据的缓冲区，用锁保护。
private final class DataBuffer: Sendable {
    /// 读到的数据。
    private let storage = OSAllocatedUnfairLock(initialState: Data())

    /// 追加读到的一块数据。
    func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    /// 到目前为止读到的数据。
    var data: Data {
        storage.withLock { $0 }
    }
}
