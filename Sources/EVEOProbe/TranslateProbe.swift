// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 translate 命令（docs/design-intel-translate.md 9.5 节）：Key 取自环境变量 EVEO_TRANSLATION_API_KEY，
// 发一次固定的测试样例，打印状态码、耗时与解析出的译文。会产生费用，只由主会话在用户同意后运行（V36）。
// WP-0 的骨架：只打印「未实现」，不发请求。实现归 WP-C。

import Foundation

/// translate 命令的实现。
@MainActor enum TranslateProbe {
    /// 骨架：打印「未实现」，退出码 3。
    static func run(_ args: [String]) async -> Int32 {
        print("translate：未实现（WP-C）")
        return 3
    }
}
