// SPDX-License-Identifier: GPL-3.0-or-later
//
// 读系统信息与要脱敏的本机名字（v1.1 设计 7.2、7.3 节）：`sysctl`、用户名、主机名。
//
// - 系统信息：系统版本取 `ProcessInfo.operatingSystemVersion`，构建号、机型、CPU 与 Rosetta 取 `sysctl`，
//   架构按编译目标，内存与核数取 `ProcessInfo`，区域与语言取 `Locale`。
// - 本机名字：`NSUserName()`、`NSFullUserName()`、`NSHomeDirectory()`；主机名取 `gethostname`（另加去掉域名后缀的写法）、
//   `SCDynamicStoreCopyComputerName`、`SCDynamicStoreCopyLocalHostName`（另加 `.local` 后缀的写法）。
//   不用 `ProcessInfo.hostName` 与 `Host.current()`，它们会等域名解析。

import Foundation
import SystemConfiguration
import EVEOPreviewCore

/// 系统信息与本机名字的读取。
struct SystemInfoReader: Sendable {
    /// 读系统信息。读不到的 `sysctl` 项是空串。
    func systemInfo() -> SystemInfo {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        var osVersion = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { osVersion += ".\(version.patchVersion)" }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return SystemInfo(osVersion: osVersion, osBuild: SystemInfoReader.sysctlString("kern.osversion"),
                          architecture: architecture,
                          isTranslated: SystemInfoReader.sysctlInt("sysctl.proc_translated") == 1,
                          hardwareModel: SystemInfoReader.sysctlString("hw.model"),
                          cpuBrand: SystemInfoReader.sysctlString("machdep.cpu.brand_string"),
                          physicalMemoryBytes: process.physicalMemory, processorCount: process.processorCount,
                          localeIdentifier: Locale.current.identifier, preferredLanguages: Locale.preferredLanguages)
    }

    /// 读要脱敏的本机名字。主机名去重，去掉空串。
    func sensitiveNames() -> SensitiveNames {
        var hosts: [String] = []
        if let host = SystemInfoReader.hostName() {
            hosts.append(host)
            // 去掉域名后缀的写法，如 `cookies-mbp.local` → `cookies-mbp`。
            if let dot = host.firstIndex(of: "."), dot != host.startIndex {
                hosts.append(String(host[..<dot]))
            }
        }
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            hosts.append(computer)
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            hosts.append(local)
            hosts.append(local + ".local")
        }
        var seen = Set<String>()
        let unique = hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return SensitiveNames(userName: NSUserName(), fullUserName: NSFullUserName(),
                              homeDirectory: NSHomeDirectory(), hostNames: unique)
    }

    // MARK: - 系统调用

    /// `gethostname` 的结果；失败时返回 nil。
    private static func hostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        let name = SystemInfoReader.decode(buffer.map { UInt8(bitPattern: $0) })
        return name.isEmpty ? nil : name
    }

    /// 字符串类的 `sysctl` 项；读不到时返回空串。
    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return decode(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 以 NUL 结尾的 UTF-8 字节转成字符串，只取第一个 NUL 之前的部分。
    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// 整数类的 `sysctl` 项；读不到时返回 nil（如 Intel 机器上没有 `sysctl.proc_translated`）。
    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
