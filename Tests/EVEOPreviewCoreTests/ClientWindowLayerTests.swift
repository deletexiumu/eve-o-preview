// SPDX-License-Identifier: GPL-3.0-or-later
//
// `ClientWindowSelector.isCandidateLayer` 的测试（v1.1.1）：EVE 原生全屏时前台客户端的主窗口在 layer 25。

import Testing
@testable import EVEOPreviewCore

/// 候选窗口的层级规则。
struct ClientWindowLayerTests {
    /// 普通窗口（layer 0）不论透明度都是候选，与 v1.1.0 相同。
    @Test func layerZeroAlwaysCandidate() {
        #expect(ClientWindowSelector.isCandidateLayer(0, alpha: 1))
        #expect(ClientWindowSelector.isCandidateLayer(0, alpha: 0))
    }

    /// 全屏前台客户端：layer 25、不透明的主窗口是候选；同层透明的 44 点高辅助窗口不是。
    @Test func fullScreenKeyWindow() {
        #expect(ClientWindowSelector.isCandidateLayer(25, alpha: 1))
        #expect(!ClientWindowSelector.isCandidateLayer(25, alpha: 0))
    }

    /// 高于状态栏层级（弹出菜单、屏幕保护等）与负层级都不是候选。
    @Test func otherLayersExcluded() {
        #expect(!ClientWindowSelector.isCandidateLayer(26, alpha: 1))
        #expect(!ClientWindowSelector.isCandidateLayer(101, alpha: 1))
        #expect(!ClientWindowSelector.isCandidateLayer(-1, alpha: 1))
        #expect(ClientWindowSelector.statusWindowLevel == 25)
    }
}
