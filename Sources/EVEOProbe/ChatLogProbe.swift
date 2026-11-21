// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 chatlog 命令（docs/design-intel-translate.md 9.5 节）：打印选中的聊天日志目录、各候选文件的频道种类、
// 编码与文件头是否完整，消息行、系统消息与位置线索的数量；带 --follow 时用 ChatLogTailer 跟踪。
// WP-0 的骨架：只打印「未实现」。实现归 WP-A。探针不打印角色名、频道名、说话人与消息内容。

import Foundation

/// chatlog 命令的实现。
@MainActor enum ChatLogProbe {
    /// 骨架：打印「未实现」，退出码 3。
    static func run(_ args: [String]) async -> Int32 {
        print("chatlog：未实现（WP-A）")
        return 3
    }
}
