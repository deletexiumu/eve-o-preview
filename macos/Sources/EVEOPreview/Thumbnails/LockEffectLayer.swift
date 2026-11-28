// SPDX-License-Identifier: GPL-3.0-or-later
//
// 锁定布局的视觉特效层（缩略图与浮窗共用）：
// - 由调用方按外圈边框宽度（活动高亮或中性边框）向内缩进摆放，绝不覆盖外圈活动高亮边框，
//   使「锁定布局」与「活动窗口高亮」两种效果清晰叠加。
// - 四个子图层：
//   1. hairlineLayer：内圈 1 点战术青蓝微光边线，开启瞬间闪亮后回落为柔和常驻边线；
//   2. glintLayer：顺时针沿内圈周长巡游的流光弧段，由 Core Animation 渲染服务驱动；
//   3. sheenLayer：仅在从未锁定切为锁定瞬间扫过一次的对角流光；
//   4. clampsLayer：四角 L 型战术锁扣，开启瞬间向四角卡紧合拢，常驻期间柔和呼吸。
// - 全程使用 Core Animation，不启主线程定时器；系统开启「减弱动态效果」时静止显示。
// - 面板从隐藏恢复显示时由 refresh() 补回可能被系统移除的动画（V14）。

import AppKit
import QuartzCore
import EVEOPreviewCore

/// 锁定布局的叠加特效图层。
final class LockEffectLayer: CALayer {
    /// 常驻呼吸动画的键。
    static let breathAnimationKey = "eveo.lockLayoutBreath"
    /// 内圈流光巡游动画的键。
    static let glintAnimationKey = "eveo.lockLayoutGlint"
    /// 开启瞬间锁扣合拢动画的键。
    static let engageClampAnimationKey = "eveo.lockLayoutEngageClamp"
    /// 开启瞬间锁扣闪色动画的键。
    static let engageColorAnimationKey = "eveo.lockLayoutEngageColor"
    /// 开启瞬间内圈脉冲动画的键。
    static let engageHairlineAnimationKey = "eveo.lockLayoutEngageHairline"
    /// 开启瞬间对角流光动画的键。
    static let engageSheenAnimationKey = "eveo.lockLayoutEngageSheen"

    /// 内圈微光边线图层。
    private let hairlineLayer = CAShapeLayer()
    /// 顺时针巡游的内圈流光图层。
    private let glintLayer = CAShapeLayer()
    /// 开启瞬间扫过的对角流光图层。
    private let sheenLayer = CAGradientLayer()
    /// 四角战术 L 型锁扣图层。
    private let clampsLayer = CAShapeLayer()

    /// 主色与高光色的 CGColor 缓存。
    private let accentColor: CGColor
    private let flashColor: CGColor

    /// 当前是否处于锁定状态。
    private var isLocked = false
    /// 上一次按尺寸构建路径时的矩形，尺寸变化时重建路径并同步流光周长。
    private var lastLayoutBounds: CGRect = .zero

    /// 建一个隐藏的锁定特效图层。
    override init() {
        accentColor = (NSColor(hex: LockEffectRules.accentHex) ?? .systemTeal).cgColor
        flashColor = (NSColor(hex: LockEffectRules.flashHex) ?? .white).cgColor
        super.init()
        setUpSublayers()
    }

    /// Core Animation 建呈现层副本时调用。
    override init(layer: Any) {
        if let other = layer as? LockEffectLayer {
            accentColor = other.accentColor
            flashColor = other.flashColor
            isLocked = other.isLocked
            lastLayoutBounds = other.lastLayoutBounds
        } else {
            accentColor = NSColor.systemTeal.cgColor
            flashColor = NSColor.white.cgColor
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建")
    }

    /// 关掉全部隐式动画：显隐、尺寸与边框内缩变化立即生效，显式动画不受影响。
    override func action(forKey event: String) -> CAAction? {
        nil
    }

    /// 初始化四个子图层与默认静态样式。
    private func setUpSublayers() {
        isHidden = true
        masksToBounds = true
        backgroundColor = nil

        let noActions: [String: CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "opacity": NSNull(),
            "path": NSNull(), "lineDashPattern": NSNull(), "cornerRadius": NSNull(),
        ]

        // 1. 内圈微光边线。
        hairlineLayer.fillColor = nil
        hairlineLayer.strokeColor = accentColor
        hairlineLayer.lineWidth = CGFloat(LockEffectRules.hairlineStrokeWidth)
        hairlineLayer.opacity = Float(LockEffectRules.steadyHairlineOpacity)
        hairlineLayer.actions = noActions

        // 2. 沿内圈顺时针巡游的流光弧段。
        glintLayer.fillColor = nil
        glintLayer.strokeColor = flashColor
        glintLayer.lineWidth = CGFloat(LockEffectRules.clampStrokeWidth)
        glintLayer.lineCap = .round
        glintLayer.shadowColor = accentColor
        glintLayer.shadowRadius = 3.5
        glintLayer.shadowOpacity = 0.85
        glintLayer.shadowOffset = .zero
        glintLayer.actions = noActions

        // 3. 开启瞬间对角流光：默认模型不透明度为 0，仅在触发关键帧动画时出现。
        sheenLayer.colors = [
            NSColor.clear.cgColor,
            NSColor(cgColor: accentColor)?.withAlphaComponent(0.16).cgColor ?? accentColor,
            NSColor(cgColor: flashColor)?.withAlphaComponent(0.36).cgColor ?? flashColor,
            NSColor(cgColor: accentColor)?.withAlphaComponent(0.16).cgColor ?? accentColor,
            NSColor.clear.cgColor,
        ]
        sheenLayer.locations = [0.0, 0.34, 0.5, 0.66, 1.0]
        sheenLayer.startPoint = CGPoint(x: 0.0, y: 0.25)
        sheenLayer.endPoint = CGPoint(x: 1.0, y: 0.75)
        sheenLayer.opacity = 0
        sheenLayer.actions = noActions

        // 4. 四角战术 L 型锁扣。
        clampsLayer.fillColor = nil
        clampsLayer.strokeColor = accentColor
        clampsLayer.lineWidth = CGFloat(LockEffectRules.clampStrokeWidth)
        clampsLayer.lineCap = .square
        clampsLayer.lineJoin = .miter
        clampsLayer.shadowColor = accentColor
        clampsLayer.shadowRadius = 2.5
        clampsLayer.shadowOpacity = 0.65
        clampsLayer.shadowOffset = .zero
        clampsLayer.actions = noActions

        for sublayer in [hairlineLayer, glintLayer, sheenLayer, clampsLayer] {
            addSublayer(sublayer)
        }
    }

    /// 同步屏幕缩放比例，确保 Retina 屏幕下线条与角标边缘清晰锐利。
    func updateContentsScale(_ scale: CGFloat) {
        contentsScale = scale
        hairlineLayer.contentsScale = scale
        glintLayer.contentsScale = scale
        sheenLayer.contentsScale = scale
        clampsLayer.contentsScale = scale
    }

    /// 尺寸变化时重建内圈、流光与四角锁扣路径；处于锁定开启动画态时同步更新流光周长。
    override func layoutSublayers() {
        super.layoutSublayers()
        guard bounds != lastLayoutBounds else { return }
        lastLayoutBounds = bounds
        rebuildGeometry()
        if isLocked {
            syncGlintAnimation(forceRestart: true)
        }
    }

    /// 按当前锁定状态更新图层显示与动画。
    ///
    /// - Parameters:
    ///   - locked: 当前布局是否锁定。
    ///   - triggerEngage: 是否触发「从未锁定切到锁定」的开启瞬间特效动画。
    @MainActor
    func update(locked: Bool, triggerEngage: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        isLocked = locked
        guard locked else {
            removeAllEffectAnimations()
            isHidden = true
            return
        }
        isHidden = false
        rebuildGeometry()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            applyReducedMotionAppearance()
            return
        }
        applyAmbientAnimations()
        if triggerEngage {
            playEngageBurst()
        }
    }

    /// 面板从隐藏变为显示后补回可能被系统移除的常驻动画（V14）。
    @MainActor
    func refresh() {
        update(locked: isLocked, triggerEngage: false)
    }

    // MARK: - 几何路径

    /// 按当前 bounds 重建内圈微光边线、巡游流光与四角锁扣的矢量路径。
    private func rebuildGeometry() {
        let rect = bounds
        hairlineLayer.frame = rect
        glintLayer.frame = rect
        clampsLayer.frame = rect
        // 对角流光图层比视图略宽，方便沿水平轴从左外侧完整扫到右外侧。
        let bandWidth = max(48, rect.width * 0.72)
        sheenLayer.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: max(1, rect.height * 1.4))
        sheenLayer.position = CGPoint(x: rect.midX, y: rect.midY)

        guard rect.width > 4, rect.height > 4 else {
            hairlineLayer.path = nil
            glintLayer.path = nil
            clampsLayer.path = nil
            return
        }
        let hairlineRect = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(cornerRadius, min(hairlineRect.width, hairlineRect.height) / 2)
        hairlineLayer.path = CGPath(roundedRect: hairlineRect, cornerWidth: radius, cornerHeight: radius,
                                    transform: nil)

        let glintRect = rect.insetBy(dx: 1.0, dy: 1.0)
        let glintRadius = max(0, min(cornerRadius - 0.5, min(glintRect.width, glintRect.height) / 2))
        glintLayer.path = CGPath(roundedRect: glintRect, cornerWidth: glintRadius, cornerHeight: glintRadius,
                                 transform: nil)
        let perimeter = Self.perimeterLength(of: glintRect, cornerRadius: glintRadius)
        let dash = max(14.0, perimeter * LockEffectRules.glintFraction)
        let gap = max(1.0, perimeter - dash)
        glintLayer.lineDashPattern = [NSNumber(value: dash), NSNumber(value: gap)]

        clampsLayer.path = Self.makeClampsPath(in: rect, extraOffset: 0)
    }

    /// 构造四角 L 型战术锁扣路径；`extraOffset > 0` 时向中心收拢偏移，用于开启瞬间的卡紧动画。
    private static func makeClampsPath(in rect: CGRect, extraOffset: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let arm = CGFloat(LockEffectRules.cornerArmLength(innerWidth: Double(rect.width),
                                                          innerHeight: Double(rect.height)))
        guard arm > 1 else { return path }
        let baseInset = CGFloat(LockEffectRules.clampGap) + CGFloat(LockEffectRules.clampStrokeWidth) / 2
        let maxOffset = max(0, min(rect.width, rect.height) / 2 - baseInset - arm)
        let inset = baseInset + min(extraOffset, maxOffset)
        let minX = rect.minX + inset
        let maxX = rect.maxX - inset
        let minY = rect.minY + inset
        let maxY = rect.maxY - inset
        guard maxX > minX, maxY > minY else { return path }

        // 左下角。
        path.move(to: CGPoint(x: minX, y: minY + arm))
        path.addLine(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: minX + arm, y: minY))
        // 右下角。
        path.move(to: CGPoint(x: maxX - arm, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: minY + arm))
        // 右上角。
        path.move(to: CGPoint(x: maxX, y: maxY - arm))
        path.addLine(to: CGPoint(x: maxX, y: maxY))
        path.addLine(to: CGPoint(x: maxX - arm, y: maxY))
        // 左上角。
        path.move(to: CGPoint(x: minX + arm, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: maxY - arm))
        return path
    }

    /// 计算圆角矩形的近似周长，用于流光虚线相位动画的无缝循环。
    private static func perimeterLength(of rect: CGRect, cornerRadius: CGFloat) -> Double {
        let straight = 2.0 * (Double(rect.width) + Double(rect.height))
        guard cornerRadius > 0 else { return straight }
        let r = Double(cornerRadius)
        return max(1.0, straight - 8.0 * r + 2.0 * .pi * r)
    }

    // MARK: - 动画控制

    /// 减弱动态效果：移除全部动画，保留清晰的静态锁扣与内圈边线。
    private func applyReducedMotionAppearance() {
        removeAllEffectAnimations()
        glintLayer.isHidden = true
        sheenLayer.opacity = 0
        hairlineLayer.opacity = Float(LockEffectRules.staticHairlineOpacity)
        clampsLayer.opacity = Float(LockEffectRules.staticClampOpacity)
    }

    /// 启动或维持常驻呼吸与内圈巡游流光动画；已有动画时不重启，避免相位跳动。
    private func applyAmbientAnimations() {
        glintLayer.isHidden = false
        hairlineLayer.opacity = Float(LockEffectRules.steadyHairlineOpacity)
        if clampsLayer.animation(forKey: Self.breathAnimationKey) == nil {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = Float(LockEffectRules.breathMinOpacity)
            breath.toValue = Float(LockEffectRules.breathMaxOpacity)
            breath.duration = LockEffectRules.breathHalfPeriod
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.isRemovedOnCompletion = false
            clampsLayer.opacity = Float(LockEffectRules.breathMaxOpacity)
            clampsLayer.add(breath, forKey: Self.breathAnimationKey)
        }
        syncGlintAnimation(forceRestart: false)
    }

    /// 同步内圈流光的虚线相位循环动画。
    private func syncGlintAnimation(forceRestart: Bool) {
        guard !glintLayer.isHidden, bounds.width > 4, bounds.height > 4 else { return }
        if !forceRestart, glintLayer.animation(forKey: Self.glintAnimationKey) != nil {
            return
        }
        let glintRect = bounds.insetBy(dx: 1.0, dy: 1.0)
        let glintRadius = max(0, min(cornerRadius - 0.5, min(glintRect.width, glintRect.height) / 2))
        let perimeter = Self.perimeterLength(of: glintRect, cornerRadius: glintRadius)
        let sweep = CABasicAnimation(keyPath: "lineDashPhase")
        sweep.fromValue = 0.0
        // CGPath(roundedRect:) 在 y 轴向上的非翻转视图中按逆时针绘制，在 y 轴向下的翻转视图中按顺时针绘制；
        // 按图层几何方向选定符号，保证缩略图与浮窗上的流光统一顺时针巡游。
        sweep.toValue = contentsAreFlipped() ? -perimeter : perimeter
        sweep.duration = LockEffectRules.glintPeriod
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        glintLayer.add(sweep, forKey: Self.glintAnimationKey)
    }

    /// 播放开启瞬间特效：四角锁扣卡紧、亮青闪光、内圈脉冲与对角流光扫过。
    private func playEngageBurst() {
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        // 1. 四角锁扣从内侧偏移迅速卡紧到四角。
        let startPath = Self.makeClampsPath(in: bounds, extraOffset: CGFloat(LockEffectRules.engageStartOffset))
        let endPath = Self.makeClampsPath(in: bounds, extraOffset: 0)
        let clampSnap = CABasicAnimation(keyPath: "path")
        clampSnap.fromValue = startPath
        clampSnap.toValue = endPath
        clampSnap.duration = LockEffectRules.engageDuration
        clampSnap.timingFunction = easeOut
        clampsLayer.add(clampSnap, forKey: Self.engageClampAnimationKey)

        // 2. 锁扣亮青白高光回落到主色。
        let colorFlash = CABasicAnimation(keyPath: "strokeColor")
        colorFlash.fromValue = flashColor
        colorFlash.toValue = accentColor
        colorFlash.duration = LockEffectRules.engageDuration
        colorFlash.timingFunction = easeOut
        clampsLayer.add(colorFlash, forKey: Self.engageColorAnimationKey)

        // 3. 内圈边线脉冲。
        let hairlinePulse = CABasicAnimation(keyPath: "opacity")
        hairlinePulse.fromValue = Float(0.85)
        hairlinePulse.toValue = Float(LockEffectRules.steadyHairlineOpacity)
        hairlinePulse.duration = LockEffectRules.engageDuration
        hairlinePulse.timingFunction = easeOut
        hairlineLayer.add(hairlinePulse, forKey: Self.engageHairlineAnimationKey)

        // 4. 对角流光自左向右扫过缩略图。
        let bandHalf = sheenLayer.bounds.width / 2
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -bandHalf
        move.toValue = bounds.width + bandHalf
        move.timingFunction = easeOut

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [Float(0.0), Float(1.0), Float(0.85), Float(0.0)]
        fade.keyTimes = [0.0, 0.2, 0.72, 1.0]

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = LockEffectRules.sheenDuration
        group.isRemovedOnCompletion = true
        sheenLayer.add(group, forKey: Self.engageSheenAnimationKey)
    }

    /// 清除全部锁定特效动画。
    private func removeAllEffectAnimations() {
        clampsLayer.removeAnimation(forKey: Self.breathAnimationKey)
        clampsLayer.removeAnimation(forKey: Self.engageClampAnimationKey)
        clampsLayer.removeAnimation(forKey: Self.engageColorAnimationKey)
        hairlineLayer.removeAnimation(forKey: Self.engageHairlineAnimationKey)
        glintLayer.removeAnimation(forKey: Self.glintAnimationKey)
        sheenLayer.removeAnimation(forKey: Self.engageSheenAnimationKey)
    }
}
