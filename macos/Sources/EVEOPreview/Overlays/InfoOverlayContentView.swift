// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的内容视图（docs/macos/design-intel-translate.md 8.4 节、8.5 节）。从上到下：标题行、状态行（至多 2 行）、
// NSScrollView 里的 NSTableView（占满其余高度）；列表为空时中间显示说明，用户离开底部且有新消息时底部居中显示新消息条。
// - 背景：黑色，不透明度取 presentation.opacity，圆角 6 点，1 点的白色边线（0.18）。只有背景随不透明度变。
// - 视图是翻转的（y 轴向下），各子视图的 frame 在 layoutContent 里手工摆放。
// - 行高：OverlayRowView.measuredHeight 按列宽量出，结果按「行编号、内容、列宽、字号」缓存；
//   列宽或字号变了时清空缓存并对全部行调 noteHeightOfRows。
// 滚动与贴住底部（8.5 节）：
// - 用户滚动：监听剪裁视图的 boundsDidChangeNotification，用 OverlayScrollRules.afterUserScroll 更新状态。
//   程序自己引起的滚动（内容更新、缩放、换字号、回到最新）用 isAdjusting 排除，整段都在标志位内，
//   头部删行让剪裁视图移动时也不会被当成用户滚动。
// - 内容更新：contextKey 变了时整表重载、状态回到初始、滚到底部；否则按 OverlayScrollRules.diff 增删改行，
//   不带动画。更新前贴住底部的，更新后滚到底部；不贴的，回到更新前第一个可见行的同一偏移（那一行没了时滚到顶部），
//   再用 afterAppend 累加新消息条数。
// - 面板缩放后：贴住底部时滚到底部，否则保持第一个可见行。

import AppKit
import EVEOPreviewCore

/// 浮窗的内容视图。
final class InfoOverlayContentView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// 左右的内边距，单位是点。
    private static let inset: CGFloat = 8

    private let titleLabel = InfoOverlayContentView.makeLabel(maximumLines: 1)
    /// 标题行右侧的频道切换按钮（只有 channelLabel 不为 nil 时显示，如翻译浮窗）。
    private let channelButton = NSView()
    private let channelButtonLabel = InfoOverlayContentView.makeLabel(maximumLines: 1)
    private let statusLabel = InfoOverlayContentView.makeLabel(maximumLines: 2)
    private let placeholderLabel = InfoOverlayContentView.makeLabel(maximumLines: 3)
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    /// 新消息条：圆角底色加一行文字。
    private let newMessagesBar = NSView()
    private let newMessagesLabel = InfoOverlayContentView.makeLabel(maximumLines: 1)
    /// 锁定特效层：画在 1 点白色边线之内侧，锁定布局开启时显示叠加动画。
    private let lockLayer = LockEffectLayer()
    /// 最近一次应用的锁定状态，用于判断是否触发开启瞬间动画。
    private var lastLocked: Bool?

    /// 最近一次的内容；nil 表示还没收到过内容。
    private var content: OverlayContent?
    /// 表格当前显示的行，与 content.lines 一致。
    private var lines: [OverlayLine] = []
    /// 第一行的字号。
    private var fontSize = 12.0
    /// 滚动状态：是否贴住底部，离开底部后新到的条数。
    private(set) var scrollState = OverlayScrollState.initial
    /// 程序正在调整内容或滚动位置：这期间剪裁视图的移动不算用户滚动。
    private var isAdjusting = false
    /// 鼠标正悬停在频道切换按钮上：用于高亮底色与只在本视图改过光标时恢复箭头。
    private var isChannelButtonHovered = false
    /// 鼠标停在浮窗上时应显示缩放光标的边，由控制器接到 OverlayInteraction.hoverEdges（v1.2.1）。
    var cursorEdges: (() -> ResizeEdges)?
    /// 光标用的跟踪区域；activeAlways，因为本应用几乎不在前台。
    private var cursorTrackingArea: NSTrackingArea?

    /// 一行的高度缓存。
    private struct CachedHeight {
        var line: OverlayLine
        var width: CGFloat
        var fontSize: Double
        var height: CGFloat
    }
    /// 行高缓存，键是行编号。
    private var heightCache: [UInt64: CachedHeight] = [:]
    /// 量行高时用的列宽；变了时清空缓存。
    private var measuredWidth: CGFloat = 0

    /// 建视图：背景图层、标题、状态、列表、说明与新消息条。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = OverlayStyle.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: OverlayStyle.borderAlpha).cgColor
        layer?.masksToBounds = true
        setUpTable()
        channelButton.wantsLayer = true
        channelButton.layer?.cornerRadius = 4
        channelButton.layer?.borderWidth = 1
        channelButton.isHidden = true
        channelButtonLabel.textColor = OverlayStyle.titleColor
        channelButtonLabel.alignment = .center
        channelButton.addSubview(channelButtonLabel)
        updateChannelButtonAppearance()
        newMessagesBar.wantsLayer = true
        newMessagesBar.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        newMessagesBar.addSubview(newMessagesLabel)
        newMessagesLabel.alignment = .center
        newMessagesLabel.textColor = .white
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = NSColor(white: 1, alpha: 0.55)
        titleLabel.textColor = OverlayStyle.titleColor
        for view in [titleLabel, channelButton, statusLabel, scrollView, placeholderLabel, newMessagesBar] {
            addSubview(view)
        }
        lockLayer.cornerRadius = max(0, OverlayStyle.cornerRadius - 1)
        layer?.addSublayer(lockLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        applyAppearance(opacity: 0.75, fontSize: 12)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 创建")
    }

    /// 视图翻转：y 轴向下，从上往下摆放。
    override var isFlipped: Bool { true }

    // MARK: - 缩放光标

    /// 重建光标用的跟踪区域。inVisibleRect 让区域随视图尺寸自动变化（拖边缩放时面板会变大变小）。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways,
                                            .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    // 鼠标在浮窗上移动时按边缘带与频道切换按钮显示对应光标，离开时恢复箭头。
    override func mouseEntered(with event: NSEvent) { updateHoverAndCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { updateHoverAndCursor(for: event) }
    override func cursorUpdate(with event: NSEvent) { updateHoverAndCursor(for: event) }
    override func mouseExited(with event: NSEvent) { resetHoverAndCursor() }

    /// 清除频道按钮悬停态与光标（面板隐藏或鼠标离开时调用）。
    func resetHoverAndCursor() {
        setChannelButtonHovered(false, resetArrow: true)
        ResizeCursor.reset()
    }

    /// 鼠标停在频道按钮上时高亮按钮并显示手形光标；否则按边缘带显示或恢复缩放光标。
    private func updateHoverAndCursor(for event: NSEvent) {
        if isChannelButton(atWindowPoint: event.locationInWindow) {
            ResizeCursor.reset()
            setChannelButtonHovered(true, resetArrow: false)
            NSCursor.pointingHand.set()
            return
        }
        let edges = cursorEdges?() ?? []
        setChannelButtonHovered(false, resetArrow: edges.isEmpty)
        ResizeCursor.update(for: edges)
    }

    /// 更新频道按钮的悬停状态与底色；仅在本视图曾经改成手形光标且 resetArrow 为真时恢复箭头。
    private func setChannelButtonHovered(_ hovered: Bool, resetArrow: Bool) {
        guard hovered != isChannelButtonHovered else { return }
        isChannelButtonHovered = hovered
        updateChannelButtonAppearance()
        if !hovered, resetArrow { NSCursor.arrow.set() }
    }

    /// 按悬停状态更新频道按钮的背景与边线颜色。
    private func updateChannelButtonAppearance() {
        channelButton.layer?.backgroundColor = NSColor(white: 1, alpha: isChannelButtonHovered ? 0.2 : 0.1).cgColor
        channelButton.layer?.borderColor = NSColor(white: 1, alpha: isChannelButtonHovered ? 0.34 : 0.2).cgColor
    }

    /// 光标在标题、状态行、说明或新消息条上时，滚轮事件沿响应链到这里；转给列表，让整个浮窗都能滚动列表。
    override func scrollWheel(with event: NSEvent) {
        scrollView.scrollWheel(with: event)
    }

    /// 列表：一列、没有表头、透明背景、不能选中、行间距 2 点、行高手工给出；滚动条只有竖向的、悬浮、自动隐藏。
    private func setUpTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.refusesFirstResponder = true
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    // MARK: - 对外接口

    /// 移到不同缩放的屏幕时更新锁定特效图层的 contentsScale。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lockLayer.updateContentsScale(window?.backingScaleFactor ?? 2)
    }

    /// 更新锁定布局的叠加特效：仅当从未锁定切为锁定时播放开启瞬间动画。
    func applyLockState(_ isLocked: Bool) {
        let trigger = LockEffectRules.shouldTriggerEngage(previousLocked: lastLocked, newLocked: isLocked)
        lastLocked = isLocked
        lockLayer.update(locked: isLocked, triggerEngage: trigger)
    }

    /// 面板从隐藏变为显示后补回可能被系统移除的锁定特效动画。
    func refreshLockEffect() {
        lockLayer.refresh()
    }

    /// 应用外观：背景不透明度与字号。字号变了时重排全部行，位置按贴住底部的规则保持。
    func applyAppearance(opacity: Double, fontSize: Double) {
        layer?.backgroundColor = NSColor(white: 0, alpha: CGFloat(opacity)).cgColor
        guard fontSize != self.fontSize || titleLabel.font?.pointSize != CGFloat(fontSize) else { return }
        self.fontSize = fontSize
        titleLabel.font = .boldSystemFont(ofSize: CGFloat(fontSize))
        let secondaryFontSize = CGFloat(max(OverlayStyle.minimumSecondaryFontSize, fontSize - 1))
        channelButtonLabel.font = .systemFont(ofSize: secondaryFontSize, weight: .medium)
        statusLabel.font = .systemFont(ofSize: secondaryFontSize)
        placeholderLabel.font = .systemFont(ofSize: CGFloat(fontSize))
        newMessagesLabel.font = .systemFont(ofSize: secondaryFontSize, weight: .medium)
        preservingPosition {
            heightCache = [:]
            layoutContent()
            tableView.reloadData()
        }
        updateAccessories()
    }

    /// 显示新内容（8.5 节「内容更新」）。
    func setContent(_ new: OverlayContent) {
        let previous = content
        content = new
        titleLabel.stringValue = new.title
        if let label = new.channelLabel {
            channelButtonLabel.stringValue = "\(label) ▾"
            channelButton.isHidden = false
        } else {
            channelButtonLabel.stringValue = ""
            channelButton.isHidden = true
            setChannelButtonHovered(false, resetArrow: true)
        }
        statusLabel.stringValue = new.status?.text ?? ""
        statusLabel.textColor = new.status.map { OverlayStyle.statusColor($0.level) } ?? OverlayStyle.titleColor
        statusLabel.isHidden = new.status == nil
        guard let previous, previous.contextKey == new.contextKey else {
            // 第一次收到内容或换了角色：整表重载，回到初始状态并滚到底部。
            let wasAdjusting = isAdjusting
            isAdjusting = true
            lines = new.lines
            heightCache = [:]
            layoutContent()
            tableView.reloadData()
            // 重载后先让表格按新行数定好自己的高度，再按这个高度滚到底部。
            tableView.tile()
            scrollState = .initial
            scrollToBottom()
            isAdjusting = wasAdjusting
            updateAccessories()
            return
        }
        // 同一个角色：按行编号对齐新旧列表，只增删改变了的行，免得整表重载让滚动位置跳动（V37）。
        let diff = OverlayScrollRules.diff(old: lines, new: new.lines)
        preservingPosition {
            // 标题与状态行的高度可能变了，先重排，列表区域的高度随之改变。
            layoutContent()
            guard !diff.isEmpty else { return }
            lines = new.lines
            pruneHeightCache()
            if diff.isReload {
                tableView.reloadData()
            } else {
                apply(diff)
            }
        }
        // 补读的消息在第一次内容更新里到达，那时还贴着底部，不计入条数；之后不贴底部时才累加。
        scrollState = OverlayScrollRules.afterAppend(scrollState, appended: diff.appended)
        updateAccessories()
    }

    /// 回到最新：滚到底部，状态回到初始（右键菜单与新消息条）。
    func scrollToLatest() {
        let wasAdjusting = isAdjusting
        isAdjusting = true
        scrollToBottom()
        isAdjusting = wasAdjusting
        scrollState = .initial
        updateAccessories()
    }

    /// 窗口坐标的点下面的那一行；不在列表的可见区域或不在某一行上时为 nil。
    func line(atWindowPoint point: NSPoint) -> OverlayLine? {
        guard scrollView.bounds.contains(scrollView.convert(point, from: nil)) else { return nil }
        let row = tableView.row(at: tableView.convert(point, from: nil))
        return lines.indices.contains(row) ? lines[row] : nil
    }

    /// 窗口坐标的点是否落在可见的新消息条上。
    func isNewMessagesBar(atWindowPoint point: NSPoint) -> Bool {
        !newMessagesBar.isHidden && newMessagesBar.frame.contains(convert(point, from: nil))
    }

    /// 窗口坐标的点是否落在可见的频道切换按钮上。
    func isChannelButton(atWindowPoint point: NSPoint) -> Bool {
        !channelButton.isHidden && channelButton.frame.contains(convert(point, from: nil))
    }

    /// 频道切换菜单弹出的锚点（内容视图翻转坐标）：按钮左下角下方 2 点。
    func channelButtonMenuOrigin() -> NSPoint {
        NSPoint(x: channelButton.frame.minX, y: channelButton.frame.maxY + 2)
    }

    // MARK: - 列表的更新

    /// 按差异增删改行，不带动画：先删头部、再加尾部（beginUpdates 里后一步的下标以前一步之后为准），最后重排变了的行。
    private func apply(_ diff: OverlayListDiff) {
        tableView.beginUpdates()
        if diff.removedFromHead > 0 {
            tableView.removeRows(at: IndexSet(0..<diff.removedFromHead), withAnimation: [])
        }
        if diff.appended > 0 {
            tableView.insertRows(at: IndexSet((lines.count - diff.appended)..<lines.count), withAnimation: [])
        }
        tableView.endUpdates()
        if !diff.changed.isEmpty {
            let changed = IndexSet(diff.changed.filter { lines.indices.contains($0) })
            tableView.noteHeightOfRows(withIndexesChanged: changed)
            tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }
    }

    /// 丢掉已不在列表里的行的高度缓存。
    private func pruneHeightCache() {
        let ids = Set(lines.map(\.id))
        heightCache = heightCache.filter { ids.contains($0.key) }
    }

    // MARK: - 滚动位置

    /// 第一个可见行与它露出的偏移。
    private struct Anchor {
        var id: UInt64
        var offset: CGFloat
    }

    /// 在程序调整的期间执行 body，之后按贴住底部的规则恢复位置：贴住时滚到底部，否则回到原来的第一个可见行。
    private func preservingPosition(_ body: () -> Void) {
        let pinned = scrollState.isPinnedToBottom
        let anchor = pinned ? nil : captureAnchor()
        let wasAdjusting = isAdjusting
        isAdjusting = true
        body()
        tableView.tile()
        if pinned {
            scrollToBottom()
        } else {
            restore(anchor)
        }
        isAdjusting = wasAdjusting
    }

    /// 记下第一个可见行的编号，以及可见区域的上边比那一行的上边低多少。
    private func captureAnchor() -> Anchor? {
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        guard range.length > 0, lines.indices.contains(range.location) else { return nil }
        // 第一行只露出下半截时 offset 为正，恢复时让它露出同样多。
        let row = range.location
        return Anchor(id: lines[row].id, offset: visible.minY - tableView.rect(ofRow: row).minY)
    }

    /// 回到记下的那一行的同一偏移；那一行已被去掉或没有记录时滚到顶部。
    private func restore(_ anchor: Anchor?) {
        guard let anchor, let row = lines.firstIndex(where: { $0.id == anchor.id }) else {
            scroll(toY: 0)
            return
        }
        scroll(toY: tableView.rect(ofRow: row).minY + anchor.offset)
    }

    /// 滚到底部。
    private func scrollToBottom() {
        scroll(toY: .greatestFiniteMagnitude)
    }

    /// 把可见区域的上边移到 y，夹在 0 与「文档高度减可见高度」之间。
    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        // 表格比可见区域矮时 maxY 是 0，滚动位置停在顶部，也就是底部。
        let maxY = max(0, tableView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 剪裁视图移动了：程序调整的期间忽略，否则按用户滚动更新状态。
    @objc private func clipBoundsChanged(_ notification: Notification) {
        guard !isAdjusting else { return }
        // 内容底部到可见区域底部的距离；弹性滚动越过底部时为负数，也算贴住。
        let distance = tableView.frame.height - scrollView.contentView.bounds.maxY
        let newState = OverlayScrollRules.afterUserScroll(scrollState, distanceFromBottom: distance)
        guard newState != scrollState else { return }
        scrollState = newState
        updateAccessories()
    }

    // MARK: - 布局

    /// 尺寸变了：重排子视图；列宽变了时重量行高。位置按贴住底部的规则保持（8.5 节「面板缩放后」）。
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else {
            super.setFrameSize(newSize)
            return
        }
        let pinned = scrollState.isPinnedToBottom
        let anchor = pinned ? nil : captureAnchor()
        let wasAdjusting = isAdjusting
        isAdjusting = true
        super.setFrameSize(newSize)
        layoutContent()
        tableView.tile()
        if pinned { scrollToBottom() } else { restore(anchor) }
        isAdjusting = wasAdjusting
        updateAccessories()
    }

    /// 摆放标题、状态与列表；列宽变了时清空行高缓存并让表格重量全部行。
    private func layoutContent() {
        let width = bounds.width
        let inset = InfoOverlayContentView.inset
        let titleLine = lineHeight(titleLabel.font)
        let buttonLine = lineHeight(channelButtonLabel.font)
        let titleHeight: CGFloat
        var titleWidth = max(0, width - 2 * inset)
        if !channelButton.isHidden {
            // 顶部留出 EdgeGrip 的 6 点边缘带，不让频道按钮吃掉顶边缩放区域。
            let topBand = CGFloat(EdgeGrip.bandWidth)
            let horizontalPadding: CGFloat = 12
            let gap: CGFloat = 6
            let labelWidth = ceil(channelButtonLabel.cell?.cellSize.width ?? 0)
            let maxButtonWidth = max(72, floor(titleWidth * 0.48))
            let buttonWidth = min(maxButtonWidth, labelWidth + horizontalPadding)
            let buttonHeight = buttonLine + 4
            let rowHeight = max(titleLine, buttonHeight)
            titleHeight = topBand + rowHeight + 4
            let buttonX = max(inset, width - inset - buttonWidth)
            channelButton.frame = NSRect(x: buttonX, y: topBand + (rowHeight - buttonHeight) / 2,
                                         width: buttonWidth, height: buttonHeight)
            channelButtonLabel.frame = NSRect(x: horizontalPadding / 2, y: (buttonHeight - buttonLine) / 2,
                                              width: max(0, buttonWidth - horizontalPadding), height: buttonLine)
            titleWidth = max(0, buttonX - inset - gap)
            titleLabel.frame = NSRect(x: inset, y: topBand + (rowHeight - titleLine) / 2, width: titleWidth,
                                      height: titleLine)
            // 按钮因换频道变窄后，若静止光标不再落在按钮内则立即退出悬停态。
            if isChannelButtonHovered, let window {
                let mouseInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                if !isChannelButton(atWindowPoint: mouseInWindow) {
                    setChannelButtonHovered(false, resetArrow: true)
                }
            }
        } else {
            titleHeight = CGFloat(fontSize) + 10
            titleLabel.frame = NSRect(x: inset, y: (titleHeight - titleLine) / 2, width: titleWidth,
                                      height: titleLine)
        }
        var top = titleHeight
        if !statusLabel.isHidden {
            let maxHeight = 2 * lineHeight(statusLabel.font) + 2
            let measured = statusLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(0, width - 2 * inset),
                                                                        height: maxHeight)).height ?? maxHeight
            let height = min(ceil(measured), maxHeight)
            statusLabel.frame = NSRect(x: inset, y: top, width: max(0, width - 2 * inset), height: height)
            top += height + 4
        }
        // 右侧与底部各留 6 点：悬浮滚动条整个落在 EdgeGrip 的 6 点边缘带之内侧，左键拖滚动条不会变成缩放。
        let edgeBand = CGFloat(EdgeGrip.bandWidth)
        scrollView.frame = NSRect(x: 2, y: top, width: max(0, width - 2 - edgeBand),
                                  height: max(0, bounds.height - top - edgeBand))
        // 单列占满列表的宽度：悬浮滚动条不占宽度，所以列宽就是剪裁视图的宽度。
        let columnWidth = scrollView.contentSize.width
        if let column = tableView.tableColumns.first, column.width != columnWidth { column.width = columnWidth }
        if columnWidth != measuredWidth {
            measuredWidth = columnWidth
            heightCache = [:]
            if !lines.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<lines.count)) }
        }
        layoutAccessories()
        // 锁定特效层贴在 1 点白色边线之内侧，始终置于最顶层以便在列表与内容上清晰呈现。
        let lockInset: CGFloat = 1
        let safeInset = min(lockInset, min(bounds.width, bounds.height) / 2)
        lockLayer.frame = bounds.insetBy(dx: safeInset, dy: safeInset)
        if let rootLayer = layer, lockLayer.superlayer === rootLayer {
            lockLayer.zPosition = 100
        }
    }

    /// 更新空列表的说明与新消息条的文字和可见性，并摆放它们。
    private func updateAccessories() {
        switch content.flatMap(OverlayScrollRules.placeholder(for:)) {
        case .noActiveCharacter: placeholderLabel.stringValue = L10n.overlay.noActiveCharacter
        case .empty: placeholderLabel.stringValue = L10n.overlay.emptyList
        case nil: placeholderLabel.stringValue = ""
        }
        placeholderLabel.isHidden = placeholderLabel.stringValue.isEmpty
        let showsBar = !scrollState.isPinnedToBottom && scrollState.unseenCount > 0
        newMessagesBar.isHidden = !showsBar
        if showsBar { newMessagesLabel.stringValue = L10n.overlay.newMessages(scrollState.unseenCount) }
        layoutAccessories()
    }

    /// 说明居中于列表区域；新消息条在列表底部居中，离底边 6 点。
    private func layoutAccessories() {
        let area = scrollView.frame
        let placeholderWidth = max(0, area.width - 16)
        let placeholderHeight = ceil(placeholderLabel.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: placeholderWidth, height: area.height)).height ?? 0)
        placeholderLabel.frame = NSRect(x: area.minX + 8, y: area.midY - placeholderHeight / 2,
                                        width: placeholderWidth, height: placeholderHeight)
        guard !newMessagesBar.isHidden else { return }
        // 条的宽度随文字变，左右各留 10 点，但不超过列表的宽度。
        let labelSize = newMessagesLabel.cell?.cellSize ?? .zero
        let barWidth = min(area.width - 8, ceil(labelSize.width) + 20)
        let barHeight = ceil(labelSize.height) + 6
        newMessagesBar.frame = NSRect(x: area.midX - barWidth / 2, y: area.maxY - barHeight - 6,
                                      width: max(0, barWidth), height: barHeight)
        newMessagesBar.layer?.cornerRadius = barHeight / 2
        newMessagesLabel.frame = NSRect(x: 0, y: 3, width: newMessagesBar.bounds.width, height: ceil(labelSize.height))
    }

    /// 一行文字的高度。
    private func lineHeight(_ font: NSFont?) -> CGFloat {
        guard let font else { return CGFloat(fontSize) * 1.25 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    // MARK: - 表格的数据源与委托

    /// 行数。
    func numberOfRows(in tableView: NSTableView) -> Int {
        lines.count
    }

    /// 一行的视图：复用 OverlayRowView，填入富文本与强调背景。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard lines.indices.contains(row) else { return nil }
        let view = tableView.makeView(withIdentifier: OverlayRowView.identifier, owner: self) as? OverlayRowView
            ?? OverlayRowView(frame: .zero)
        let line = lines[row]
        view.show(OverlayStyle.attributedText(for: line, fontSize: fontSize), emphasis: line.emphasis)
        return view
    }

    /// 一行的高度，按「行编号、内容、列宽、字号」缓存。
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard lines.indices.contains(row) else { return 1 }
        let line = lines[row]
        // 缓存命中的条件：同一条内容、同样的列宽与字号。内容变了（译文到达、人名核对的结果到达）时重量。
        let width = tableView.tableColumns.first?.width ?? measuredWidth
        if let cached = heightCache[line.id], cached.line == line, cached.width == width, cached.fontSize == fontSize {
            return cached.height
        }
        let height = OverlayRowView.measuredHeight(of: OverlayStyle.attributedText(for: line, fontSize: fontSize),
                                                   columnWidth: width)
        heightCache[line.id] = CachedHeight(line: line, width: width, fontSize: fontSize, height: height)
        return height
    }

    /// 行不能被选中。
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // MARK: - 工具

    /// 建一个不可选中、不画背景与边框的标签，按词折行，至多 maximumLines 行，末尾截断。
    private static func makeLabel(maximumLines: Int) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.refusesFirstResponder = true
        label.maximumNumberOfLines = maximumLines
        label.lineBreakMode = maximumLines == 1 ? .byTruncatingTail : .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        return label
    }
}
