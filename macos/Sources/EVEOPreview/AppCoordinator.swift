// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器（架构文档 3.3 节、7.2 节）：持有全部运行时状态。
// 每个入口只做一件事：改状态，然后 setNeedsReplan()。同一个主循环回合内的多次请求合并成一次重算。
// 重算调用 Core 的 ThumbnailPlanner，再把结果分发给缩略图面板、捕获服务与配置。
//
// 本文件是状态、轮询与重算；缩略图与菜单的动作在 AppCoordinator+Actions.swift，
// 热键在 AppCoordinator+Hotkeys.swift，界面语言在 AppCoordinator+Language.swift，
// 战斗提醒在 AppCoordinator+CombatAlerts.swift，预警与翻译浮窗在 AppCoordinator+ChatOverlays.swift，防止 App Nap 的后台活动在 AppCoordinator+Activity.swift。第一轮反馈的接入点见反馈文档 9.1 节第 4 项，
// 被调用的方法由各工作包在对应的扩展文件里实现，本文件只负责在固定的位置调用它们。
// v1.1 的接入点见 v1.1 设计 4.4 节：运行环境、状态文件、推迟弹窗与菜单栏圆点在本文件；
// 诊断与更新的配置响应在 AppCoordinator+Diagnostics.swift、AppCoordinator+Updates.swift。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform
import os

/// 协调器。全部方法在主线程调用。
@MainActor
final class AppCoordinator {
    /// 平台服务（真实实现或演示模式的假实现）。
    let services: PlatformServices
    /// 配置的持有者。
    let config: ConfigController
    /// 是否为演示模式，供界面显示提示。
    let isFakeMode: Bool
    /// 缩略图面板的管理器。
    let windowManager = ThumbnailWindowManager()
    /// 预警与翻译浮窗的管理器（docs/macos/design-intel-translate.md 9.3 节）。
    let overlayManager = InfoOverlayManager()
    /// 预警与翻译的总控。
    let chat: ChatFeatureController
    /// 正在拖动的浮窗；规划结果不改它们的 frame。
    var interactingOverlays: Set<OverlayKind> = []
    /// 翻译浮窗频道切换按钮触发的近期频道扫描任务；再次点击或退出时取消。
    var channelMenuTask: Task<Void, Never>?

    /// 已发现的客户端。
    private(set) var registry = ClientRegistry()
    /// 会话状态（全部隐藏、跳过、悬停、拖动、最近活动的客户端）。
    var session = SessionState()
    /// 当前前台。
    private(set) var frontmost: FrontmostContext = .other
    /// 当前屏幕。
    private(set) var screens: [ScreenInfo] = []
    /// 当前权限状态。
    private(set) var permissions: PermissionStatus = .denied
    /// 各窗口的捕获状态。
    private(set) var captureStates: [WindowID: CaptureState] = [:]
    /// 当前生效的热键规划。热键回调的 id 只能在这一份规划里查。
    var hotkeyPlan = HotkeyPlan(bindings: [], issues: [])
    /// 最近一次 `replaceAll` 返回的注册失败项。
    var hotkeyFailures: [HotkeyRegistrationFailure] = []
    /// 最近一次重算的结果。
    private(set) var lastPlan: ThumbnailPlan?

    /// 游戏日志跟踪服务的最新状态，设置窗口的「提醒」页显示它。
    /// 由 `AppCoordinator+CombatAlerts.swift` 在 `onStatusChange` 回调里更新（反馈文档 7.11 节）。
    var combatLogStatus: CombatLogStatus = .stopped

    /// 请求打开设置窗口的某一页，由 AppDelegate 设置。
    var openSettings: ((SettingsPage) -> Void)?
    /// 界面语言变了以后调用，由 AppDelegate 设置：重设设置窗口的标题、重建主菜单（反馈文档 5.4 节）。
    var onLanguageChanged: (() -> Void)?

    // MARK: v1.1 的诊断与更新（v1.1 设计 4.4 节）

    /// 启动时读到的运行环境，本次运行内不变。
    let environment: AppEnvironment
    /// `state.json` 的持有者。
    let state: StateController
    /// 自动弹出的窗口的推迟器；`refreshFrontmost()` 把前台推给它。
    let presenter = DeferredPresenter()
    // 以下 4 个控制器要引用协调器，所以由 AppDelegate 在建好协调器之后、调用 `start()` 之前赋值
    // （4.4 节第 6 步）。之后不再变，菜单与设置窗口可以直接用。
    /// 会话标记与崩溃检测。
    var sessionTracker: SessionTracker!
    /// 问题报告。
    var problemReport: ProblemReportController!
    /// 更新的检查与安装。
    var updates: UpdateController!
    /// 更新窗口。
    var updateWindow: UpdateWindowController!
    /// 菜单栏图标显示圆点的原因；不为空时显示圆点（4.5 节、11.1 节）。
    private(set) var attention: Set<AttentionReason> = []
    /// `attention` 变化后调用，由菜单栏控制器设置，用来重画图标。
    var onAttentionChanged: (() -> Void)?

    /// 激活请求的序号，每次 `activate` 加 1。完成时序号已不是最新的，说明被后来的切换取代了。
    var activationSequence = 0
    /// `stop()` 已调用（应用正在退出）。之后的重算、轮询与回调都直接返回，不再建面板或捕获会话。
    private(set) var isStopped = false

    private var runtimeObservers: [@MainActor () -> Void] = []
    private var pollTask: Task<Void, Never>?
    /// 热键后端的巡检循环，与窗口枚举分开，枚举卡住时照常运行。
    private var healthTask: Task<Void, Never>?
    /// 防止 App Nap 的后台活动令牌，由 `AppCoordinator+Activity.swift` 开始与结束。
    var backgroundActivity: NSObjectProtocol?
    private var wakeTask: Task<Void, Never>?
    private var isPolling = false
    private var replanScheduled = false
    let log = AppLog.logger("Coordinator")

    /// 用平台服务、配置、运行环境与状态建协调器；调用 `start()` 后才开始工作。
    init(services: PlatformServices, config: ConfigController, isFakeMode: Bool,
         environment: AppEnvironment, state: StateController) {
        self.services = services
        self.config = config
        self.isFakeMode = isFakeMode
        self.environment = environment
        self.state = state
        chat = ChatFeatureController(services: services, state: state, isFakeMode: isFakeMode)
    }

    /// 当前配置方案。
    var profile: Profile { config.config.activeProfile }

    /// 单调时钟的秒数，与 `SessionState` 的时间字段同一时钟。
    var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - 启动与停止

    /// 接上全部回调，注册热键，开始轮询。
    func start() {
        windowManager.delegate = self
        services.capture.onFrame = { [weak self] id, frame in self?.frameArrived(id, frame: frame) }
        services.capture.onStateChange = { [weak self] id, state in self?.captureStateChanged(id, state: state) }
        services.hotkeys.onHotkey = { [weak self] id in self?.hotkeyFired(id: id) }
        services.hotkeys.onStateChange = { [weak self] in self?.checkHotkeyHealth() }
        config.addObserver { [weak self] old, new in self?.configDidChange(old: old, new: new) }
        services.workspace.start { [weak self] event in self?.handle(event) }
        screens = services.workspace.screens()
        permissions = services.permissions.status()
        // 启动时视为刚在 EVE 环境内，「离开 EVE 时隐藏」从现在开始计延迟。
        session.lastEVEContextAt = now
        rebuildHotkeys()
        startCombatAlerts()
        startChatOverlays()
        startPolling()
        startHealthChecks()
    }

    /// 停止轮询与全部捕获。退出前调用。先置 isStopped，此后进行中的异步步骤完成时不再改界面或建流。
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        // 先暂停热键：等待退出的这段时间里不再吞掉新的点击，也不触发动作。
        services.hotkeys.suspend()
        pollTask?.cancel()
        healthTask?.cancel()
        wakeTask?.cancel()
        channelMenuTask?.cancel()
        channelMenuTask = nil
        updateBackgroundActivity()
        services.workspace.stop()
        services.combatLog.stop()
        chat.stop()
        overlayManager.closeAll()
        windowManager.closeAll()
        await services.capture.stopAll()
    }

    // MARK: - 运行时状态的观察者

    /// 注册运行时状态（客户端、权限、热键、捕获状态）变化的回调，设置窗口用它刷新。
    func addRuntimeObserver(_ observer: @escaping @MainActor () -> Void) {
        runtimeObservers.append(observer)
    }

    /// 通知全部运行时观察者。
    func notifyRuntimeObservers() {
        for observer in runtimeObservers {
            observer()
        }
    }

    // MARK: - 轮询

    /// 按 `general.pollIntervalMs` 循环轮询；间隔每轮重新读取，改设置后下一轮生效。
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollTick()
                let interval = self?.config.config.general.pollIntervalMs ?? 1000
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    /// 按轮询间隔巡检热键后端（反馈文档 6.7 节）。单独一个循环：`pollTick` 在窗口枚举返回前会跳过后来的轮询，
    /// 巡检不能被它一直跳过。等待期间不持有 self，与 `startPolling` 相同。
    private func startHealthChecks() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkHotkeyHealth()
                let interval = self?.config.config.general.pollIntervalMs ?? 1000
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    /// 立即加调一次轮询（例如收到应用启动或退出的通知、切换或最小化之后）。
    func pollNow() {
        Task { [weak self] in await self?.pollTick() }
    }

    /// 取候选窗口，选出主窗口，更新客户端登记。上一次还没返回时跳过本轮。
    func pollTick() async {
        guard !isStopped, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        let candidates = await services.windows.candidateWindows()
        // 枚举是异步的，期间可能开始了退出。
        guard !isStopped else { return }
        let diff = registry.update(with: ClientWindowSelector.mainWindows(from: candidates))
        if !diff.isEmpty {
            applyRegistryDiff(diff)
        }
        updatePermissions(services.permissions.status())
        refreshFrontmost()
        setNeedsReplan()
    }

    /// 处理客户端的增减：清掉已消失窗口的会话状态。
    private func applyRegistryDiff(_ diff: RegistryDiff) {
        for client in diff.removed {
            captureStates[client.id] = nil
            session.interactingWindows.remove(client.id)
            if session.hoveredWindow == client.id { session.hoveredWindow = nil }
            session.combatAlerts[client.id] = nil
        }
        log.info("""
            客户端变化：新增 \(diff.added.count)，移除 \(diff.removed.count)，\
            改名 \(diff.renamed.count)，现有 \(self.registry.clients.count)
            """)
    }

    /// 重新判断前台，并按架构文档 7.2 节更新 `session.lastEVEContextAt`：
    /// 前台仍是客户端或本应用时更新；从客户端或本应用变成其他应用的那一刻也记一次，
    /// 「离开 EVE 时隐藏」的延迟从这一刻算起，而不是从上一次重算算起（否则实际延迟会短最多一个轮询周期）。
    func refreshFrontmost() {
        let previous = frontmost
        frontmost = services.workspace.frontmost(among: registry.clients.map(\.pid))
        if frontmost.isEVEContext || previous.isEVEContext {
            session.lastEVEContextAt = now
        }
        // 轮询与前台通知两条路径都经过这里，所以只在这一处把前台推给热键注册器（反馈文档 6.7 节）。
        frontmostDidChange()
        // 推迟中的窗口（自动发现的新版本、崩溃提示）等前台不再是 EVE 客户端时显示（v1.1 设计 4.5 节）。
        presenter.frontmostDidChange(frontmost)
    }

    /// 重新读权限状态，变化时重算。权限页可见时每秒调用一次。
    func refreshPermissions() {
        guard updatePermissions(services.permissions.status()) else { return }
        setNeedsReplan()
    }

    /// 记下新的权限状态。状态变了时通知热键部分（辅助功能权限影响鼠标热键），返回是否变了。
    @discardableResult
    private func updatePermissions(_ status: PermissionStatus) -> Bool {
        let old = permissions
        guard status != old else { return false }
        permissions = status
        permissionsDidChange(old: old, new: status)
        return true
    }

    // MARK: - 事件入口

    /// 处理前台观察者上报的系统事件。
    func handle(_ event: WorkspaceEvent) {
        switch event {
        case .frontmostChanged:
            refreshFrontmost()
        case .applicationsChanged:
            pollNow()
        case .screensChanged:
            screens = services.workspace.screens()
        case .didWake:
            // 架构文档 6.6 节：唤醒后重建正在运行的捕获会话。睡眠期间流可能已失效却不报错，
            // 而看门狗只在窗口在屏幕上时计时，单靠重算发现不了。重建后的规格由接下来的重算对账。
            guard !isStopped else { return }
            log.info("系统唤醒，重建捕获会话")
            services.capture.restartActiveSessions()
        case .activeSpaceChanged:
            break
        }
        setNeedsReplan()
    }

    /// 配置变化：切换配置方案时清空跳过名单；热键规划变了就重新注册；然后重算。
    func configDidChange(old: AppConfig, new: AppConfig) {
        if old.activeProfileID != new.activeProfileID {
            session.skippedCharacters = []
            session.hoveredWindow = nil
        }
        languageSettingDidChange(old: old, new: new)
        combatSettingsDidChange(old: old, new: new)
        chatSettingsDidChange(old: old, new: new)
        diagnosticsSettingsDidChange(old: old, new: new)
        updateSettingsDidChange(old: old, new: new)
        rebuildHotkeys()
        setNeedsReplan()
    }

    /// 捕获服务送来新画面：直接交给面板，不触发重算。
    func frameArrived(_ id: WindowID, frame: CapturedFrame) {
        windowManager.display(frame, for: id)
    }

    /// 捕获状态变化：记下并重算（占位可能要变）。
    func captureStateChanged(_ id: WindowID, state: CaptureState) {
        // 已消失的窗口（如 windowGone）不再记录，否则状态表里会留下永远不清的条目。
        guard registry.client(withID: id) != nil, captureStates[id] != state else { return }
        captureStates[id] = state
        setNeedsReplan()
    }

    // MARK: - 菜单栏圆点

    /// 亮起或熄灭一个圆点的原因。集合变了时通知菜单栏重画图标。
    func setAttention(_ reason: AttentionReason, on: Bool) {
        let changed = on ? attention.insert(reason).inserted : attention.remove(reason) != nil
        guard changed else { return }
        onAttentionChanged?()
    }

    // MARK: - 重算

    /// 请求一次重算。同一个主循环回合内的多次请求合并成一次。
    func setNeedsReplan() {
        guard !isStopped, !replanScheduled else { return }
        replanScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.replan() }
        }
    }

    /// 由当前状态算出呈现，分发给面板、捕获服务与配置。
    private func replan() {
        replanScheduled = false
        // 退出开始后不再重算：重算会重新建面板、让捕获服务重新建流。
        guard !isStopped else { return }
        // 前台仍在 EVE 环境内时持续更新时刻；离开的那一刻由 refreshFrontmost 记下（7.2 节）。
        switch frontmost {
        case .client(let pid):
            session.lastEVEContextAt = now
            session.lastActivePID = pid
        case .selfApp:
            session.lastEVEContextAt = now
        case .other:
            break
        }
        // 先删掉到期的战斗提醒，规划器与之后的状态里只留未到期的项（反馈文档 7.7 节）。
        pruneCombatAlerts()
        let input = PlannerInput(clients: registry.clients, frontmost: frontmost, profile: profile, session: session,
                                 screens: screens, permissions: permissions, captureStates: captureStates, now: now)
        let plan = ThumbnailPlanner.plan(input)
        lastPlan = plan
        // 悬停的面板被隐藏时（如点击后「隐藏活动客户端」生效），AppKit 可能不再发 mouseExited；
        // 这里清掉悬停，否则面板再出现时仍是放大、不透明的样子。
        if let hovered = session.hoveredWindow,
           plan.presentations.first(where: { $0.id == hovered })?.isVisible != true {
            session.hoveredWindow = nil
        }
        // 拖动中的面板被隐藏或已消失时（如拖动中按热键「全部隐藏」），清掉它的交互状态，
        // 否则它一直留在 interactingWindows 里，以后规划给的 frame 永远不会应用到面板上。
        // 面板控制器隐藏面板时同时取消手势状态机里的拖动，松开鼠标时不会再提交。
        let visibleIDs = Set(plan.presentations.lazy.filter(\.isVisible).map(\.id))
        session.interactingWindows.formIntersection(visibleIDs)
        windowManager.apply(plan.presentations, interacting: session.interactingWindows)
        services.capture.reconcile(plan.captures, liveWindows: Set(registry.clients.map(\.id)))
        // 浮窗在缩略图之后规划（docs/macos/design-intel-translate.md 9.3 节）；两份规划的唤醒时刻取较早的一个。
        let overlayWake = replanOverlays()
        persistAutoLayouts(plan.layoutsToPersist)
        scheduleWake(at: [plan.nextWakeAt, overlayWake].compactMap { $0 }.min())
        notifyRuntimeObservers()
    }

    /// 把自动排位的结果写进当前配置方案。规划器在写入前每次都会返回它们，
    /// 所以只写配置里还没有的角色，写入后下一次规划就不再返回。
    private func persistAutoLayouts(_ layouts: [String: ThumbnailLayout]) {
        let existing = profile.layouts
        let missing = layouts.filter { existing[$0.key] == nil }
        guard !missing.isEmpty else { return }
        config.updateActiveProfile { profile in
            for (name, layout) in missing where profile.layouts[name] == nil {
                profile.layouts[name] = layout
            }
        }
    }

    /// 在 `nextWakeAt` 安排一次重算（隐藏延迟到期）。新的安排取代旧的。
    private func scheduleWake(at deadline: Double?) {
        wakeTask?.cancel()
        wakeTask = nil
        guard let deadline else { return }
        let delay = max(0.01, deadline - now)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.setNeedsReplan()
        }
    }
}

extension FrontmostContext {
    /// 前台是 EVE 客户端或本应用（「在 EVE 环境内」，见架构文档 4.3 节）。
    var isEVEContext: Bool {
        switch self {
        case .client, .selfApp: return true
        case .other: return false
        }
    }
}
