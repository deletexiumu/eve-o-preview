// SPDX-License-Identifier: GPL-3.0-or-later
//
// 自动弹出的窗口的推迟（v1.1 设计 4.5 节）。用户可能在玩 EVE：应用自己弹出的窗口（自动检查发现新版本、
// 检测到崩溃）在前台是 EVE 客户端时不弹，等前台不再是客户端后再弹。用户点出来的窗口不经过这里。
//
// - 前台由协调器在每次 `refreshFrontmost()` 后推过来（轮询每秒一次，另有前台变化的通知）。
// - 还没收到过前台时（启动后的第一次轮询之前）不知道前台是不是 EVE，按「不能弹」处理，等第一次推送。
// - 同一个 key 重复请求时只保留最后一次。窗口已经显示时不重复弹出，由各窗口的 show 自己判断。
// - 推迟期间菜单栏图标的圆点与菜单项由各控制器经 `AppCoordinator.setAttention` 亮起，这里不管。

import Foundation
import EVEOPreviewCore

/// 菜单栏圆点的原因（4.5 节、11.1 节）。`AppCoordinator.attention` 不为空时显示圆点。
enum AttentionReason: Hashable, Sendable {
    /// 检测到上一次运行崩溃，用户还没处理。
    case crashPending
    /// 有可用的新版本。
    case updateAvailable
    /// 新版本已下载好，等用户退出或点菜单项安装。
    case updateReady
}

/// 在不打断游戏时显示自动弹出的窗口。全部方法在主线程调用。
@MainActor final class DeferredPresenter {
    /// 一个等待中的请求。
    private struct Pending {
        /// 请求的 key，如 `update`、`crash`。
        let key: String
        /// 显示窗口的动作。
        let show: @MainActor () -> Void
    }

    /// 等待中的请求，按请求的先后排列。同一个 key 只有一项。
    private var pending: [Pending] = []
    /// 最近一次推来的前台；nil 表示还没收到过。
    private(set) var frontmost: FrontmostContext?

    /// 建推迟器。前台未知，收到第一次 `frontmostDidChange` 之前不弹窗口。
    init() {}

    /// 现在能弹就立即调 show，否则等前台不再是 EVE 客户端时调。同一个 key 只保留最后一次。
    func present(key: String, show: @escaping @MainActor () -> Void) {
        pending.removeAll { $0.key == key }
        if canPresentNow {
            show()
        } else {
            pending.append(Pending(key: key, show: show))
        }
    }

    /// 取消一个等待中的请求（例如用户已从菜单打开了同一个窗口）。没有这个 key 时什么也不做。
    func cancel(key: String) {
        pending.removeAll { $0.key == key }
    }

    /// 前台变了（或轮询时重新判断了一次）。现在能弹时按请求的先后显示全部等待中的窗口。
    func frontmostDidChange(_ frontmost: FrontmostContext) {
        self.frontmost = frontmost
        guard canPresentNow, !pending.isEmpty else { return }
        // 先取出再调用：show 里可能再调 present 或 cancel，不能边遍历边改。
        let ready = pending
        pending.removeAll()
        for request in ready {
            request.show()
        }
    }

    /// 是否有等待中的请求（供菜单与调试查看）。
    var hasPending: Bool { !pending.isEmpty }

    /// 现在能否弹出自动的窗口：前台已知且 `PromptGate` 允许。
    private var canPresentNow: Bool {
        guard let frontmost else { return false }
        return PromptGate.canPresent(frontmost: frontmost, userInitiated: false)
    }
}
