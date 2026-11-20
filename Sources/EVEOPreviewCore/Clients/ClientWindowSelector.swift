// SPDX-License-Identifier: GPL-3.0-or-later
//
// 从一个 EVE 进程的多个 layer 0 窗口里选出主窗口（架构文档 5.3 节、事实 E6）。
// 实测每个进程有 1 个 1728×1018 的主窗口，另有无标题的 1728×33 与 500×500 辅助窗口。

import Foundation

/// 主窗口选择规则。
public enum ClientWindowSelector {
    /// 无标题时可作为主窗口的最小尺寸，单位是点。宽和高分别比较，不比较面积：
    /// 500×500 的辅助窗口面积大于 640×360，但宽度不足 640，应排除。
    public static let minimumUntitledSize = ScreenSize(width: 640, height: 360)

    /// 每个 PID 选出一个主窗口。输入是该 bundle id 下全部 layer 0 窗口。
    ///
    /// 同一 PID 下：
    /// 1. 先取标题能解析成角色或登录的窗口。
    /// 2. 没有时，取宽不小于 640、高不小于 360 的窗口。
    /// 3. 都没有时，该 PID 本轮不产生客户端。
    ///
    /// 多个候选时取面积最大的，面积相同再取窗口 ID 最小的。
    /// - Returns: 每个 PID 至多一个窗口，按 PID 升序排列。
    public static func mainWindows(from candidates: [WindowInfo]) -> [WindowInfo] {
        let byPID = Dictionary(grouping: candidates, by: \.pid)
        return byPID.keys.sorted().compactMap { pid in
            mainWindow(among: byPID[pid] ?? [])
        }
    }

    /// 在同一进程的窗口里按上述规则选一个。
    private static func mainWindow(among windows: [WindowInfo]) -> WindowInfo? {
        let titled = windows.filter { window in
            switch TitleParser.identity(fromTitle: window.title) {
            case .character, .login: return true
            case .unknown: return false
            }
        }
        if let best = largest(titled) { return best }
        let bigEnough = windows.filter {
            $0.frame.width >= minimumUntitledSize.width && $0.frame.height >= minimumUntitledSize.height
        }
        return largest(bigEnough)
    }

    /// 面积最大者；面积相同取窗口 ID 最小者；空数组返回 nil。
    private static func largest(_ windows: [WindowInfo]) -> WindowInfo? {
        windows.min { a, b in
            // min(by:) 取「排在最前」的元素：面积大的排前，面积相同时 ID 小的排前。
            if a.frame.area != b.frame.area { return a.frame.area > b.frame.area }
            return a.windowID < b.windowID
        }
    }
}
