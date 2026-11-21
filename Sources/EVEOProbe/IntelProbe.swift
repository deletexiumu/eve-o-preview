// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 intel 命令（docs/design-intel-translate.md 9.5 节）：用真实的星图数据解析最近 48 小时的玩家频道日志，
// 打印消息数、认作情报的条数、有数量的条数、各情报用语的条数、推断出人名的条数。
// WP-0 的骨架：只打印「未实现」。实现归 WP-B。探针不打印角色名、频道名、说话人与消息内容。

import Foundation

/// intel 命令的实现。
@MainActor enum IntelProbe {
    /// 骨架：打印「未实现」，退出码 3。
    static func run(_ args: [String]) async -> Int32 {
        print("intel：未实现（WP-B）")
        return 3
    }
}
