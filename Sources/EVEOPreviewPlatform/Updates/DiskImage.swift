// SPDX-License-Identifier: GPL-3.0-or-later
//
// 挂载与卸载 dmg（v1.1 设计 9.3 节第 2 步）。经 `ProcessRunner` 运行 `/usr/bin/hdiutil`，不经过 shell。
//
// - 挂载：`hdiutil attach -nobrowse -readonly -noautoopen -mountrandom <目录> -plist <dmg>`，超时 120 秒。
//   从输出的属性列表里取 `system-entities` 中第一个 `mount-point`。解析不出时返回 `imageMountFailed`。
// - 卸载：`hdiutil detach <挂载点> -force`，超时 30 秒。失败只记日志。
// - `-nobrowse` 让卷不出现在访达里；`-mountrandom` 把挂载点放在给定目录下的随机子目录里，不占用 /Volumes 下的名字。

import Foundation
import EVEOPreviewCore

/// dmg 的挂载与卸载。
public enum DiskImage {
    /// hdiutil 的路径。
    static let hdiutil = "/usr/bin/hdiutil"
    /// 挂载的超时秒数。
    static let attachTimeout: Double = 120
    /// 卸载的超时秒数。
    static let detachTimeout: Double = 30
    private static let log = PlatformLog.logger("Updates")

    /// 挂载 image，挂载点放在 mountRoot 下的随机子目录里。返回挂载点；失败时抛 `imageMountFailed`。
    public static func attach(_ image: URL, mountRoot: URL) async throws(UpdateError) -> URL {
        do {
            try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        } catch {
            throw .imageMountFailed("cannot create mount root")
        }
        let arguments = ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path,
                         "-plist", image.path]
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(hdiutil, arguments: arguments, timeout: attachTimeout)
        } catch {
            throw .imageMountFailed(error == .timedOut ? "hdiutil timed out" : "hdiutil did not start")
        }
        guard result.status == 0 else {
            log.error("hdiutil attach 退出码 \(result.status)：\(result.standardError, privacy: .public)")
            throw .imageMountFailed("hdiutil exit \(result.status)")
        }
        guard let mountPoint = mountPoint(fromPlist: result.standardOutput) else {
            throw .imageMountFailed("no mount point in hdiutil output")
        }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    /// 强制卸载挂载点。失败只记日志：卷是只读的，留着不影响已安装的应用，下次启动的 `removeLeftovers` 再试。
    public static func detach(_ mountPoint: URL) async {
        do {
            let result = try await ProcessRunner.run(hdiutil, arguments: ["detach", mountPoint.path, "-force"],
                                                     timeout: detachTimeout)
            if result.status != 0 {
                log.error("hdiutil detach 退出码 \(result.status)：\(result.standardError, privacy: .public)")
            }
        } catch {
            log.error("hdiutil detach 失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 从 `hdiutil attach -plist` 的输出里取 `system-entities` 中第一个 `mount-point`。
    ///
    /// 输出前面偶尔有别的文字（如许可协议的提示），所以从 `<?xml` 起解析。
    public static func mountPoint(fromPlist data: Data) -> String? {
        var payload = data
        if let start = data.range(of: Data("<?xml".utf8)) { payload = data.subdata(in: start.lowerBound..<data.endIndex) }
        guard let object = try? PropertyListSerialization.propertyList(from: payload, format: nil),
              let root = object as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let point = entity["mount-point"] as? String, !point.isEmpty { return point }
        }
        return nil
    }
}
