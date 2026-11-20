// SPDX-License-Identifier: GPL-3.0-or-later
//
// 读系统信息与要脱敏的本机名字（v1.1 设计 7.2、7.3 节）：`sysctl`、用户名、主机名。
// 主机名不用 `ProcessInfo.hostName` 与 `Host.current()`，它们会等域名解析。
// WP-0 只建骨架：返回空的值；WP-2 实现。

import Foundation
import EVEOPreviewCore

/// 系统信息与本机名字的读取。
struct SystemInfoReader: Sendable {
    /// 读系统信息。
    ///
    /// 骨架：返回各字段为空的 `SystemInfo`（WP-2 实现）。
    func systemInfo() -> SystemInfo {
        SystemInfo(osVersion: "", osBuild: "", architecture: "", isTranslated: false, hardwareModel: "",
                   cpuBrand: "", physicalMemoryBytes: 0, processorCount: 0, localeIdentifier: "",
                   preferredLanguages: [])
    }

    /// 读要脱敏的本机名字。
    ///
    /// 骨架：返回空的名字表（WP-2 实现）。
    func sensitiveNames() -> SensitiveNames {
        SensitiveNames(userName: "", fullUserName: "", homeDirectory: "", hostNames: [])
    }
}
