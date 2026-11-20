// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新的探针命令（v1.1 设计 9.6 节），供 WP-3 在不运行应用的情况下核对平台代码：
//   update feed [地址]               请求并解析发布信息，打印版本、附件与 `UpdatePolicy.offer` 的结果
//   update verify <新应用> <基准应用>  读基准应用的指定要求，对新应用做 9.3 节第 6 步的核对，打印返回值
//   update prepare <地址>            运行 9.2 节的下载与核对，打印 dmg 的位置与 SHA-256
//
// WP-0 只建骨架：识别子命令后打印「尚未实现」并返回 1；WP-3 实现。

import Foundation

/// `update` 命令的分发。
@MainActor enum UpdateProbe {
    /// 子命令的名字。
    static let subcommands = ["feed", "verify", "prepare"]

    /// 解析子命令并执行，返回进程退出码：参数不对时 2，失败或尚未实现时 1。
    ///
    /// 骨架：子命令合法时打印「尚未实现」并返回 1（WP-3 实现）。
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first, subcommands.contains(command) else { return Probe.usage() }
        print("update \(command)：尚未实现（WP-3）")
        return 1
    }
}
