// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图的提醒层（反馈文档 7.8 节），是内容视图的第 6 层，在边框层之上，大小与缩略图相同。
// - style 是 border 或 both 时画 4 点的边框，是 wash 或 both 时铺一层不透明度 0.25 的底色，颜色取 alert.color。
// - 闪烁：图层的 opacity 在 1.0 与 0.15 之间来回，单程 0.25 秒，自动反向，无限重复，缓入缓出，即每秒 2 次。
//   频率固定在每秒 3 次以下（WCAG 2.3.1），不做成配置项。
// - 动画是 CABasicAnimation，由渲染服务执行，应用不为它起定时器，闪烁期间主线程没有逐帧的工作。
// - update 每次重算都会被调用：alert 没变且动画还在时直接返回，不重启动画，相位不跳。
// - 系统打开「减弱动态效果」时不加动画，图层以不透明度 1.0 静止显示。
// - 面板从隐藏变成显示后，系统可能已移除动画；内容视图的 refreshAlert() 再调一次 update 把它补上（V14）。
// 图层自己关掉隐式动画：update 有时在没有关闭动画的事务里被调用（refreshAlert），颜色、显隐不应渐变。

import AppKit
import QuartzCore
import EVEOPreviewCore

/// 战斗提醒的闪烁层。
final class AlertFlashLayer: CALayer {
    /// 闪烁动画的键。
    static let animationKey = "eveo.combatAlertFlash"
    /// 边框粗细（点）。
    static let borderWidth: CGFloat = 4
    /// 底色的不透明度。
    static let washAlpha: CGFloat = 0.25
    /// 闪烁时不透明度的低点。
    static let dimOpacity: Float = 0.15
    /// 单程时长（秒）：一个来回 0.5 秒，每秒闪 2 次。
    static let halfPeriod: CFTimeInterval = 0.25

    /// 当前显示的提醒外观；nil 表示没有提醒、图层隐藏。
    private var current: ThumbnailAlert?

    /// 建一个隐藏的提醒层。
    override init() {
        super.init()
        isHidden = true
    }

    /// Core Animation 建呈现层副本时调用（动画期间会用到），按原图层复制。
    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建")
    }

    /// 关掉全部隐式动画：颜色、边框与显隐的变化立即生效。显式加上的闪烁动画不受影响。
    override func action(forKey event: String) -> CAAction? {
        nil
    }

    /// 按呈现更新。alert 与上次相同且动画还在时不做任何事。在主线程调用。
    @MainActor
    func update(_ alert: ThumbnailAlert?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let alert else {
            current = nil
            removeAnimation(forKey: AlertFlashLayer.animationKey)
            isHidden = true
            return
        }
        if alert != current {
            current = alert
            applyAppearance(alert)
        }
        isHidden = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // 减弱动态效果：静止显示。设置在提醒期间被打开时，也在这里移除已有的动画。
            removeAnimation(forKey: AlertFlashLayer.animationKey)
            opacity = 1
        } else if animation(forKey: AlertFlashLayer.animationKey) == nil {
            opacity = 1
            add(AlertFlashLayer.makeFlashAnimation(), forKey: AlertFlashLayer.animationKey)
        }
    }

    /// 按样式设置边框与底色。
    private func applyAppearance(_ alert: ThumbnailAlert) {
        let color = NSColor(hex: alert.color) ?? NSColor(hex: CombatAlertSettings.defaultColor) ?? .systemRed
        let drawsBorder = alert.style == .border || alert.style == .both
        let drawsWash = alert.style == .wash || alert.style == .both
        borderColor = color.cgColor
        borderWidth = drawsBorder ? AlertFlashLayer.borderWidth : 0
        backgroundColor = drawsWash ? color.withAlphaComponent(AlertFlashLayer.washAlpha).cgColor : nil
    }

    /// 闪烁动画：opacity 从 1.0 到 0.15，自动反向，无限重复，缓入缓出。
    private static func makeFlashAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = Float(1)
        animation.toValue = dimOpacity
        animation.duration = halfPeriod
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // 面板隐藏期间动画不应被当成已完成而移除；系统仍可能移除它，由 refreshAlert() 补上。
        animation.isRemovedOnCompletion = false
        return animation
    }
}
