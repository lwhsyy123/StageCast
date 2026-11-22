//
//  DevicePanelView.swift
//  StageCast
//
//  Created by Sun on 2025/12/23.
//
//  设备面板视图
//  包含设备边框和状态信息的完整设备展示
//  设备类型通过边框外观区分，不显示设备图标
//

import AppKit

// MARK: - 控制按钮条面板

/// 控制按钮条使用的不抢焦点浮层。
/// 无边框窗口默认 canBecomeKey 为 false，导致内部按钮收不到点击（第一下只当作激活窗口），
/// 这里显式允许成为 key window，但不成为 main window，避免抢主窗口的主角色。
final class ControlBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 带内边距的按钮

/// 支持内边距的自定义按钮
final class PaddedButton: NSButton {
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat

    init(horizontalPadding: CGFloat = 12, verticalPadding: CGFloat = 6) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let baseSize = super.intrinsicContentSize
        return NSSize(
            width: baseSize.width + horizontalPadding * 2,
            height: baseSize.height + verticalPadding * 2
        )
    }
}

// MARK: - 面板输入事件

/// 面板输入事件（坐标已归一化到 0...1，原点在画面左上角）
enum DevicePanelInputEvent {
    case pointerDown(CGPoint, NSEvent)
    case pointerMove(CGPoint, NSEvent)
    case pointerUp(CGPoint, NSEvent)
    case pointerHover(CGPoint, NSEvent)
    case scroll(dx: CGFloat, dy: CGFloat, point: CGPoint, event: NSEvent)
    case keyDown(NSEvent)
    case pointerExit
}

// MARK: - 设备面板视图

final class DevicePanelView: NSView {
    // MARK: - UI 组件

    /// 设备边框视图
    private let bezelView = DeviceBezelView()

    /// Metal 渲染视图（显示设备画面，嵌入到 screenContentView 中）
    private(set) var renderView = SingleDeviceRenderView()

    /// 状态视图（显示在边框屏幕区域内）
    private let statusView = DeviceStatusView()

    /// 镜像统计角标（画面右上角内侧，替代旧的侧边信息浮层）
    private let statsBadge = MirrorStatsBadge()

    // MARK: - 回调

    private var onStartAction: (() -> Void)?
    private var onStopAction: (() -> Void)?
    private var onInstallAction: (() -> Void)?
    private var onRefreshAction: ((@escaping () -> Void) -> Void)?

    /// 画面输入事件回调（仅 Android 投屏时启用）
    var onInputEvent: ((DevicePanelInputEvent) -> Void)?

    /// 浮层设备控制按钮回调
    var onControlAction: ((DeviceControlAction) -> Void)?

    /// 同步每格静音按钮外观（由外部在状态变化与接线时调用）
    func setMuteState(_ muted: Bool) {
        controlBar.setMuteState(muted)
    }

    /// 同步录制状态（录制中显示停止图标与时长）
    func setRecordingState(_ state: DeviceControlBarView.RecordingState) {
        controlBar.setRecordingState(state)
    }

    /// 双击面板回调（多设备网格：双击聚焦/返回；双设备：切换单侧）
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // 黑边/禁输入区域的事件落到本视图：双击触发聚焦，其余走默认拖窗
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        super.mouseDown(with: event)
    }

    /// 视频尺寸变化回调（透传渲染视图，用于窗口按真实比例贴合）
    var onVideoSizeChanged: ((CGSize) -> Void)? {
        get { renderView.onVideoSizeChanged }
        set { renderView.onVideoSizeChanged = newValue }
    }

    /// 安装圆角检测回调
    func installCornerDetection() {
        renderView.onCornerRadiusDetected = { [weak self] radius in
            self?.handleDetectedCornerRadius(radius)
        }
    }

    /// 是否允许拖动画面外的边框移动窗口（独立浮窗启用，主窗口关闭）
    var allowsWindowBackgroundDrag = false {
        didSet { bezelView.allowsWindowDrag = allowsWindowBackgroundDrag }
    }

    /// 独立浮窗模式下按钮条可以越出窗口边缘（窗外是桌面，无需避让相邻面板）
    var allowsControlBarOutsideWindow = false

    /// 面板本身不参与窗口拖动，避免吞掉画面上的鼠标事件
    override var mouseDownCanMoveWindow: Bool { allowsWindowBackgroundDrag }

    /// 当前是否有 USB 连接的 Android 设备
    private var hasUSBAndroidDevice: Bool {
        AppState.shared.androidDeviceProvider.devices.contains {
            $0.connectionType == .usb && $0.state == .device
        }
    }

    // MARK: - 设备控制按钮条

    /// 独立控制按钮条（与信息浮层分离）
    private let controlBar = DeviceControlBarView()
    /// 控制按钮条所在子窗口
    private var controlBarPanel: NSPanel?
    /// 控制按钮条窗口的内容容器（避免 contentView 被窗口 autoresize 拉伸）
    private var controlBarContainer: NSView?
    /// 控制按钮条是否启用
    private var isControlBarEnabled = false
    /// 鼠标是否在控制按钮条上
    private var isMouseInsideControlBar = false
    /// 控制按钮条自动隐藏计时器
    private var controlBarHideTimer: Timer?
    /// 控制按钮条轮询计时器（不依赖鼠标事件，保证脚本/远程操作也能触发显隐）
    private var controlBarPollTimer: Timer?
    /// 上一轮轮询时鼠标是否在控制条触发区内（用于识别「离开」这一瞬间）
    private var wasPointerInControlZone = false

    /// 当前设备状态提示（用于 Toast 显示）
    private var currentUserPrompt: String?

    // MARK: - 状态

    private enum PanelState {
        case loading
        case disconnected
        case connected
        case capturing
        case toolchainMissing
    }

    // MARK: - 实例登记

    /// 所有存活面板的弱引用表。
    /// 控制按钮条是各面板私有的子窗口，若面板在「停止投屏/被替换」时没有走到
    /// viewWillMove(toWindow: nil)，子窗口就会停在上一次的屏幕位置变成「幽灵条」。
    /// 这里维护一份弱引用清单，供全局清扫统一收尾。
    private static let livePanelsTable = NSHashTable<DevicePanelView>.weakObjects()

    /// 清扫所有已不在投屏状态、或已脱离窗口的面板的附属子窗口
    static func sweepInactiveControlBars() {
        for panel in livePanelsTable.allObjects {
            // 只清扫「还在窗口里但已不该出条」的面板。
            // 刚建好尚未加入窗口的面板要放过：它稍后才会被布局挂上去，
            // 提前拆掉会让它的悬停轮询再也不会启动。
            guard panel.window != nil else { continue }
            if panel.currentState != .capturing || panel.isHiddenOrHasHiddenAncestor {
                panel.teardownChildWindows()
            }
        }
    }

    private var currentState: PanelState = .loading {
        didSet {
            if currentState != .capturing {
                resetCaptureIdle()
                // 离开投屏状态的瞬间必须收起控制条：等待页/已连接页不该出现按钮条，
                // 也不能让条窗口留在屏幕上等下一次悬停把它「点亮」。
                if oldValue == .capturing {
                    hideControlBarNow()
                }
            }
        }
    }
    private var currentPlatform: DevicePlatform = .ios {
        didSet {
            if oldValue != currentPlatform {
                // 平台变化时更新渲染视图的色彩滤镜
                renderView.colorFilter = ColorProfileManager.shared.filter(for: currentPlatform)
            }
        }
    }

    // MARK: - 鼠标追踪

    private var trackingArea: NSTrackingArea?
    private var isMouseInside: Bool = false

    /// 仅记录投屏画面内的静止时间，用于静止后隐藏光标。
    private var captureIdleTimer: Timer?
    private var isCaptureIdle = false
    private let captureIdleDuration: TimeInterval = 2

    // MARK: - FPS 更新定时器

    private var fpsUpdateTimer: Timer?

    // MARK: - Bezel 可见性

    /// 是否显示设备边框
    private(set) var showBezel: Bool = true

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupTrackingArea()
        installCornerDetection()
        Self.livePanelsTable.add(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupTrackingArea()
        Self.livePanelsTable.add(self)
    }

    deinit {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        resetCaptureIdle()
        fpsUpdateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        teardownChildWindows()
    }

    // MARK: - UI 设置

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        setupBezelView()
        setupStatusContent()
    }

    private func setupBezelView() {
        addSubview(bezelView)

        // 添加 Metal 渲染视图到 screenContentView（画面会跟随 bezel 动画）
        bezelView.screenContentView.addSubview(renderView)

        // 设置默认的色彩滤镜
        renderView.colorFilter = ColorProfileManager.shared.filter(for: currentPlatform)

        // 输入事件转发（是否启用由 setInputEnabled 控制）
        renderView.onPointerDown = { [weak self] point, event in
            guard let self else { return }
            // 双击画面 → 聚焦/返回网格（拦截，不透传到手机）
            if event.clickCount == 2 {
                self.onDoubleClick?()
                return
            }
            self.onInputEvent?(.pointerDown(point, event))
        }
        renderView.onPointerMove = { [weak self] point, event in
            self?.onInputEvent?(.pointerMove(point, event))
        }
        renderView.onPointerUp = { [weak self] point, event in
            self?.onInputEvent?(.pointerUp(point, event))
        }
        renderView.onPointerHover = { [weak self] point, event in
            self?.onInputEvent?(.pointerHover(point, event))
        }
        renderView.onScroll = { [weak self] dx, dy, point, event in
            self?.onInputEvent?(.scroll(dx: dx, dy: dy, point: point, event: event))
        }
        renderView.onKeyDown = { [weak self] event in
            guard let self, renderView.acceptsInputEvents else { return false }
            onInputEvent?(.keyDown(event))
            return true
        }
        renderView.onPointerExit = { [weak self] in
            self?.onInputEvent?(.pointerExit)
        }
    }

    /// 是否允许在画面上操作设备（Android 投屏且开启控制时）
    func setInputEnabled(_ enabled: Bool) {
        renderView.acceptsInputEvents = enabled
        if !enabled {
            onInputEvent = nil
        }
    }

    /// 是否启用独立的设备控制按钮条
    /// 与信息浮层互相独立：两者可分别开关、分别自动隐藏
    func setControlActionsVisible(_ visible: Bool) {
        guard isControlBarEnabled != visible else {
            // 已经是目标状态：按钮条窗口可能在停止投屏时被拆掉了，
            // 重新开始投屏需要把它建回来并恢复悬停轮询，否则条永远不出现。
            if visible, controlBarPanel == nil {
                setupControlBarIfNeeded()
                startControlBarPolling()
            }
            return
        }
        isControlBarEnabled = visible

        if visible {
            setupControlBarIfNeeded()
            startControlBarPolling()
            refreshControlBarVisibility()
        } else {
            isMouseInsideControlBar = false
            cancelControlBarHideTimer()
            stopControlBarPolling()
            controlBarPanel?.orderOut(nil)
            onControlAction = nil
        }
    }

    /// 每 0.25s 检查一次鼠标位置，驱动按钮条显隐
    private func startControlBarPolling() {
        guard controlBarPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshControlBarVisibility()
        }
        controlBarPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopControlBarPolling() {
        controlBarPollTimer?.invalidate()
        controlBarPollTimer = nil
    }

    // MARK: - 控制按钮条

    private func setupControlBarIfNeeded() {
        guard controlBarPanel == nil else { return }

        let size = DeviceControlBarView.layoutSize(fittingWidth: controlBarAvailableWidth).size
        let panel = ControlBarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        // 用容器做 contentView：直接把 controlBar 当 contentView 时，
        // AppKit 会在窗口尺寸变化时按 autoresizing 把它拉回窗口大小，
        // 导致竖排 46×298 的按钮条被挤进 298×46 的窗口里只剩一条细缝。
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = false
        controlBar.autoresizingMask = []
        controlBar.frame = container.bounds
        container.addSubview(controlBar)
        controlBarContainer = container
        panel.contentView = container
        controlBarPanel = panel

        controlBar.onAction = { [weak self] action in
            self?.onControlAction?(action)
            // 点完按钮后重新计时，避免鼠标停在按钮上时立即消失
            self?.scheduleControlBarHideTimer()
        }
        controlBar.onHoverChanged = { [weak self] inside in
            guard let self else { return }
            isMouseInsideControlBar = inside
            if inside {
                cancelControlBarHideTimer()
                refreshControlBarVisibility()
            } else {
                scheduleControlBarHideTimer()
            }
        }
    }

    /// 根据鼠标位置与设置刷新按钮条显隐
    private func refreshControlBarVisibility() {
        guard isControlBarEnabled else { return }
        // 只有「真的在投屏 + 面板自身在当前窗口层级里可见」才允许出条。
        // 缺了后者，隐藏的等待页面板、被网格/浮窗面板顶掉的旧面板都会各自 orderFront，
        // 两个条窗口相差几个像素交替显示——就是用户看到的「鼠标移上去按钮条左右跳」。
        guard currentState == .capturing, isControlBarEligible else {
            hideControlBarNow()
            return
        }
        // 浮窗是独立窗口，用户悬停时它通常不是 key（主窗仍持有焦点）。
        // 浮窗模式下只要 App 在前台就允许出条，否则必须先把浮窗点一下才看得到按钮，
        // 与「鼠标移上去就出现」的交互预期不符。
        let floatingHover = allowsControlBarOutsideWindow && NSApp.isActive
        guard let window, window.isKeyWindow || controlBarPanel?.isKeyWindow == true || floatingHover else {
            hideControlBarNow()
            return
        }

        // 不依赖 tracking area 事件：直接按当前全局鼠标位置判断，
        // 这样即使鼠标是通过脚本/远程方式移动，也能正确显示按钮条。
        // 鼠标在画面内时还要求「本面板就是该点最上层的面板」，避免多面板叠加时互相抢条。
        let pointerOnBar = isMouseInsideControlBar || pointerInsideControlBarArea()
        let shouldShow = pointerOnBar || (isPointerInsideMirror() && isPanelTopmostUnderPointer())

        guard shouldShow else {
            // 只在「从触发区离开」的那一刻开始计时，避免每次轮询都重置计时器导致永不隐藏
            if wasPointerInControlZone {
                wasPointerInControlZone = false
                scheduleControlBarHideTimer()
            } else if controlBarPanel?.isVisible == true, controlBarHideTimer == nil, !isMouseInsideControlBar {
                // 已经离开且没有计时器（例如刚启动），补一个
                scheduleControlBarHideTimer()
            }
            return
        }

        wasPointerInControlZone = true
        cancelControlBarHideTimer()
        setupControlBarIfNeeded()
        guard let panel = controlBarPanel else { return }

        // 全局单条控制条：本面板请求显示时，其他面板的条立即收起
        DeviceControlBarCoordinator.shared.requestShow(self)

        // 每次显示都重算位置（updateControlBarPanelFrame 内部做差量比较，
        // 目标 frame 不变时不会 setFrame），这样缩放窗口、旋转屏幕、切换布局后
        // 按钮条都会重新贴回画面下缘/右侧，而不是停在旧位置。
        updateControlBarPanelFrame()
        if panel.parent !== window {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        controlBar.setVisible(true, animated: true)
    }

    /// 协调器调用：立即收起本面板的控制条（悬停切换到其他面板时）
    func controlBarCoordinatorHide() {
        cancelControlBarHideTimer()
        wasPointerInControlZone = false
        controlBar.setVisible(false, animated: false)
        controlBarPanel?.orderOut(nil)
    }

    private func scheduleControlBarHideTimer() {
        guard isControlBarEnabled, !isMouseInsideControlBar else { return }
        cancelControlBarHideTimer()
        let timer = Timer(timeInterval: Self.controlBarHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            controlBarHideTimer = nil
            guard !isMouseInsideControlBar else { return }
            // 鼠标仍在触发区时继续显示，只有真正离开才收起
            guard !shouldShowControlBar() else {
                scheduleControlBarHideTimer()
                return
            }
            controlBar.setVisible(false, animated: true)
            // 必须把承载按钮条的 NSPanel 一起收掉：只把内容视图设为透明，
            // 那个 46x298 的透明窗口仍然留在屏幕上接收鼠标事件，会挡住下面的画面点击。
            controlBarPanel?.orderOut(nil)
            DeviceControlBarCoordinator.shared.requestHide(self)
        }
        controlBarHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelControlBarHideTimer() {
        controlBarHideTimer?.invalidate()
        controlBarHideTimer = nil
    }

    /// 立刻收起按钮条（不进入自动隐藏倒计时）
    /// 用于「状态不该出条」的硬条件：非投屏状态、面板被隐藏/移出窗口、主窗口失焦。
    private func hideControlBarNow() {
        cancelControlBarHideTimer()
        wasPointerInControlZone = false
        isMouseInsideControlBar = false
        controlBar.setVisible(false, animated: false)
        controlBarPanel?.orderOut(nil)
        DeviceControlBarCoordinator.shared.requestHide(self)
    }

    /// 本面板自身是否还处于「可以显示浮层」的状态
    /// 仅靠 currentState 不够：等待页面板与网格/浮窗面板会共用同一实例，
    /// 被 isHidden 或已从窗口移除的面板同样不该再点亮按钮条。
    private var isControlBarEligible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        guard superview != nil, !isHiddenOrHasHiddenAncestor else { return false }
        guard let content = window.contentView, isDescendant(of: content) else { return false }
        return true
    }

    /// 鼠标位置处最上层的面板是否就是本面板
    /// 多面板（网格/浮窗/等待页）叠放时，命中最上层的那块画面才有资格出条，
    /// 否则两个面板会各自认为自己被悬停，反复争夺同一条按钮条。
    private func isPanelTopmostUnderPointer() -> Bool {
        guard let window, let content = window.contentView else { return false }
        // 不能用 hitTest：渲染视图对黑边区域做了命中穿透，可能返回 nil 或容器视图，
        // 拿不到真正的面板。这里改为遍历同级面板，按子视图顺序（后加的在上面）
        // 找出「指针所在画面」里最靠上的那块，只有它才有资格出条。
        var topmost: DevicePanelView?
        func visit(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden && sub.alphaValue > 0.01 {
                if let panel = sub as? DevicePanelView, panel.isPointerInsideMirror() {
                    topmost = panel
                }
                visit(sub)
            }
        }
        visit(content)
        // 指针不在任何面板画面内（例如悬停在按钮条本身）时不限制
        guard let topmost else { return true }
        return topmost === self
    }

    /// 控制按钮条自动隐藏延迟（秒）
    /// 留足时间让用户从画面移动到按钮并点击
    private static let controlBarHideDelay: TimeInterval = 4.0

    /// 鼠标是否落在控制按钮条上（含少量容差，避免边缘抖动）
    private func pointerInsideControlBarArea() -> Bool {
        // 不要求 isVisible：按钮条淡出后指针仍停在原位置时，也要能立刻把它唤回来
        guard let panel = controlBarPanel, panel.frame.width > 0, panel.frame.height > 0 else { return false }
        let frame = panel.frame.insetBy(dx: -8, dy: -8)
        return frame.contains(NSEvent.mouseLocation)
    }

    /// 鼠标当前是否落在投屏画面内（用全局坐标实时判断）
    private func isPointerInsideMirror() -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        guard superview != nil, !isHiddenOrHasHiddenAncestor else { return false }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        let screenView: NSView = showBezel ? bezelView.screenContentView : renderView
        let mirrorPoint = screenView.convert(localPoint, from: self)
        return screenView.bounds.contains(mirrorPoint)
    }

    /// 当前是否应显示「控制按钮条」
    /// 鼠标停在按钮条上、或落在投屏画面内都算触发区
    private func shouldShowControlBar() -> Bool {
        guard isControlBarEnabled, UserPreferences.shared.showDeviceControlBar else { return false }
        // 鼠标停在按钮条上：始终保持显示
        if isMouseInsideControlBar || pointerInsideControlBarArea() { return true }
        return isPointerInsideMirror()
    }

    /// 画面视图（有边框时取边框内屏幕区，否则取渲染视图）
    private var mirrorContentView: NSView {
        showBezel ? bezelView.screenContentView : renderView
    }

    /// 按钮条可用宽度：跟随实际视频画面宽度（排除黑边），保证不超出画面
    private var controlBarAvailableWidth: CGFloat {
        if let rect = renderView.videoDisplayRect, rect.width > 0 {
            return rect.width
        }
        let width = mirrorContentView.bounds.width
        return width > 0 ? width : bounds.width
    }

    /// 控制按钮条布局：画面够宽时横排贴画面下缘居中；画面偏窄（竖屏/小窗）时竖排贴画面右侧垂直居中
    private func updateControlBarPanelFrame() {
        guard let window, let panel = controlBarPanel else { return }

        syncVideoAspectFallback()

        // 以「实际视频画面」为基准：renderView 坐标 → self 坐标 → 窗口坐标 → 屏幕坐标
        let videoRectInRender = renderView.videoDisplayRect ?? renderView.bounds
        let videoRectInSelf = renderView.convert(videoRectInRender, to: self)
        let videoRectInWindow = convert(videoRectInSelf, to: nil)
        let videoFrame = window.convertToScreen(videoRectInWindow)

        // 先按横排试算：8 个按钮 + 间距 + 内边距能否塞进画面宽度（留 16pt 余量）
        let horizontalProbe = DeviceControlBarView.layoutSize(fittingWidth: videoFrame.width, orientation: .horizontal)
        let fitsHorizontally = horizontalProbe.size.width <= videoFrame.width - 16

        let gap: CGFloat = 6

        // 浮窗带边框时，按钮条应贴整机外缘而不是画面边缘：
        // 画面四周已经被金属边框占满，贴画面会压在边框上
        let useWindowAnchor = allowsControlBarOutsideWindow && showBezel
        let anchorFrame = useWindowAnchor ? window.frame : videoFrame

        if fitsHorizontally {
            controlBar.relayout(orientation: .horizontal, fittingWidth: videoFrame.width)
            let size = controlBar.frame.size
            let x = anchorFrame.midX - size.width / 2
            var y = anchorFrame.minY - gap - size.height
            // 浮窗可能被拖到屏幕底部，按钮条落到屏幕外时翻到窗口上方
            if useWindowAnchor, let visible = window.screen?.visibleFrame, y < visible.minY + 4 {
                y = anchorFrame.maxY + gap
            }
            applyControlBarFrame(panel: panel, size: size, origin: NSPoint(x: x, y: y))
        } else {
            // 竖排：可用高度 = 画面高度，贴画面右侧外侧
            controlBar.relayout(orientation: .vertical, fittingWidth: videoFrame.height)
            let size = controlBar.frame.size
            // 优先贴画面右侧；若会越出主窗口右缘压到相邻面板，改贴画面左侧
            // window.frame 本身就是屏幕坐标，不能再走 convertToScreen（会把窗口原点叠加一次导致判断失效）
            let windowScreenFrame = window.frame
            var x: CGFloat
            if !allowsControlBarOutsideWindow, videoFrame.maxX + gap + size.width > windowScreenFrame.maxX {
                x = videoFrame.minX - gap - size.width
            } else {
                x = anchorFrame.maxX + gap
            }
            // 浮窗贴到屏幕右缘时翻到窗口左侧，避免按钮条被屏幕裁掉
            if useWindowAnchor, let visible = window.screen?.visibleFrame, x + size.width > visible.maxX - 4 {
                x = anchorFrame.minX - gap - size.width
            }
            let y = anchorFrame.midY - size.height / 2
            applyControlBarFrame(panel: panel, size: size, origin: NSPoint(x: x, y: y))
        }
    }

    /// 同步按钮条窗口与内容的尺寸：先给窗口定 frame，再把按钮条按同一尺寸铺满容器
    /// 仅在目标 frame 变化时才写入，避免鼠标移动路径上反复 setFrame 造成按钮条「左右漂移」
    private func applyControlBarFrame(panel: NSPanel, size: NSSize, origin: NSPoint) {
        let target = NSRect(origin: NSPoint(x: origin.x.rounded(.toNearestOrEven), y: origin.y.rounded(.toNearestOrEven)), size: size)
        guard !NSEqualRects(panel.frame, target) else { return }
        panel.setFrame(target, display: false)
        controlBarContainer?.frame = NSRect(origin: .zero, size: size)
        controlBar.frame = NSRect(origin: .zero, size: size)
        controlBar.needsLayout = true
    }

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag, .activeInActiveApp, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let oldTrackingArea = trackingArea {
            removeTrackingArea(oldTrackingArea)
        }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag, .activeInActiveApp, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        checkMouseInCaptureZone(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        resetCaptureIdle()
        refreshControlBarVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        checkMouseInCaptureZone(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        checkMouseInCaptureZone(with: event)
    }

    /// 整个投屏画面都可触发控制按钮条，隐藏设备边框时使用实际渲染区域。
    private func checkMouseInCaptureZone(with event: NSEvent) {
        let screenView = showBezel ? bezelView.screenContentView : renderView
        let location = screenView.convert(event.locationInWindow, from: nil)
        isMouseInside = screenView.bounds.contains(location)
        // 每次实际移动都重新计时；静止后再移动时恢复光标。
        resetCaptureIdle()
        if isMouseInside, currentState == .capturing {
            scheduleCaptureIdleTimer()
        }
        // 控制按钮条按鼠标位置单独刷新
        refreshControlBarVisibility()
    }

    /// 静止两秒后隐藏光标；布局刷新不能重新显示它。
    private func scheduleCaptureIdleTimer() {
        captureIdleTimer?.invalidate()
        let timer = Timer(timeInterval: captureIdleDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.captureIdleTimer = nil
            guard self.currentState == .capturing,
                  self.isMouseInside,
                  !self.isHiddenOrHasHiddenAncestor else { return }
            self.isCaptureIdle = true
            // 由 AppKit 在下一次真实鼠标移动时自动恢复，避免隐藏计数影响其他窗口。
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        captureIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 离开画面、停止投屏或应用失活时，取消计时并恢复本次隐藏的光标。
    private func resetCaptureIdle() {
        captureIdleTimer?.invalidate()
        captureIdleTimer = nil
        if isCaptureIdle {
            isCaptureIdle = false
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    private func setupStatusContent() {
        bezelView.screenContentView.addSubview(statusView)

        // 设置回调
        statusView.onActionTapped = { [weak self] in
            self?.startActionLoading()
            self?.onStartAction?()
        }

        statusView.onRefreshTapped = { [weak self] completion in
            self?.onRefreshAction?(completion)
        }

        statusView.onStatusTapped = { [weak self] in
            guard let self, let prompt = currentUserPrompt, !prompt.isEmpty else { return }
            ToastView.warning(prompt, in: window)
        }
    }

    // MARK: - 镜像统计角标

    /// 把统计角标挂到当前画面容器的最上层（边框开关会切换容器）
    private func installStatsBadge() {
        if statsBadge.superview !== mirrorContentView {
            statsBadge.removeFromSuperview()
            mirrorContentView.addSubview(statsBadge)
        }
        updateStatsBadgeVisibility()
        layoutStatsBadge()
    }

    /// 角标贴在实际视频画面（排除黑边）右上角内侧，AppKit 原点在左下
    private func layoutStatsBadge() {
        guard statsBadge.superview === mirrorContentView else { return }

        // 尺寸由文本统一给出（单次计算，不依赖子视图先跑一次 layout）
        let size = statsBadge.preferredSize

        let baseRect: NSRect
        if let displayRect = renderView.videoDisplayRect {
            baseRect = renderView.convert(displayRect, to: mirrorContentView)
        } else {
            baseRect = mirrorContentView.bounds
        }
        let rect = baseRect.isEmpty ? mirrorContentView.bounds : baseRect

        // 固定在「实际视频画面」的右上角内侧。画面会随窗口缩放、旋转、切布局变化，
        // 因此统一以 videoDisplayRect 为基准（它已经排除了 letterbox 黑边）。
        let inset: CGFloat = 8
        // 竖屏画面顶部是手机自身的状态栏（运营商/时间/电量），角标整体下移让开；
        // 横屏状态栏在侧边，保持贴角即可
        // 竖屏顶部是手机自带状态栏（时间/电量/信号），角标再下移一点避免压字；
        // 54pt 覆盖主流 Android 状态栏高度，横屏仍贴角。
        let topInset: CGFloat = rect.height > rect.width ? 54 : inset
        statsBadge.frame = NSRect(
            x: rect.maxX - size.width - inset,
            y: rect.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        )
    }

    /// 角标显隐：偏好开启且处于投屏中才显示
    private func updateStatsBadgeVisibility() {
        statsBadge.setVisible(UserPreferences.shared.showMirrorStats && currentState == .capturing)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        resetCaptureIdle()

        // 面板离开窗口时（窗口关闭、面板被替换）必须彻底拆掉所有 child window。
        // addChildWindow 会让父窗口持有子窗口，若只在 deinit 里清理，
        // 循环引用会导致 deinit 永不执行，形成「旧投屏窗口关不掉」。
        if newWindow == nil {
            teardownChildWindows()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// 彻底拆除所有附属子窗口
    /// 在面板离开窗口层级时调用，避免残留窗口继续显示旧画面
    func teardownChildWindows() {
        // 停掉所有定时器，避免回调继续驱动已废弃的窗口
        cancelControlBarHideTimer()
        stopControlBarPolling()
        fpsUpdateTimer?.invalidate()

        if let panel = controlBarPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        controlBarPanel = nil
        DeviceControlBarCoordinator.shared.resign(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // 角标与控制按钮条的显隐偏好变化后立即刷新
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesVisibilityChanged),
            name: .captureInfoVisibilityDidChange, object: nil
        )
        // 偏好设置等窗口获得焦点后立即收起浮层并取消静止计时。
        NotificationCenter.default.addObserver(
            self, selector: #selector(captureWindowFocusChanged),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(captureWindowGeometryChanged), name: name, object: window
            )
        }
        // 应用退到后台或主窗口最小化时，清除悬停状态，避免恢复后残留浮层。
        for (name, object) in [
            (NSApplication.didResignActiveNotification, NSApp as AnyObject),
            (NSWindow.willMiniaturizeNotification, window as AnyObject),
            (NSWindow.willCloseNotification, window as AnyObject),
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(hideFloatingControls), name: name, object: object
            )
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        hideFloatingControls()
    }

    /// 收起所有悬停触发的浮层（控制按钮条）并清除悬停状态
    @objc private func hideFloatingControls() {
        isMouseInside = false
        resetCaptureIdle()

        // 窗口失焦/最小化时同时收起控制按钮条
        hideControlBarNow()
    }

    @objc private func captureWindowGeometryChanged() {
        layoutStatsBadge()
        updateControlBarPanelFrame()
        refreshCaptureHover()
    }

    @objc private func preferencesVisibilityChanged() {
        // 统计角标按偏好即时显隐
        updateStatsBadgeVisibility()

        // 控制按钮条按偏好即时显隐
        if isControlBarEnabled, !UserPreferences.shared.showDeviceControlBar {
            isControlBarEnabled = false
            isMouseInsideControlBar = false
            cancelControlBarHideTimer()
            controlBarPanel?.orderOut(nil)
            AppState.shared.stateChangedPublisher.send()
        } else {
            refreshCaptureHover()
        }
    }

    @objc private func captureWindowFocusChanged() {
        // 其他窗口（偏好设置等）成为键窗口后收起浮层，避免演示时残留
        if window?.isKeyWindow != true {
            hideFloatingControls()
        }
    }

    private func refreshCaptureHover() {
        // 几何变化也会触发本方法；后台布局不能被当成新的鼠标悬停。
        guard NSApp.isActive else {
            hideFloatingControls()
            return
        }
        // 自愈：按钮条子窗口可能在停止投屏时被拆掉，重新进入画面时要恢复轮询
        if isControlBarEnabled, currentState == .capturing {
            if controlBarPanel == nil { setupControlBarIfNeeded() }
            startControlBarPolling()
        }
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        let screenView = showBezel ? bezelView.screenContentView : renderView
        let location = screenView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isMouseInside = screenView.bounds.contains(location)
        if !isMouseInside {
            resetCaptureIdle()
        }
        refreshControlBarVisibility()
    }

    // MARK: - 公开方法

    /// 显示断开状态
    func showDisconnected(platform: DevicePlatform) {
        currentState = .disconnected
        currentPlatform = platform
        currentCaptureResolution = .zero
        stopFPSUpdateTimer()
        currentUserPrompt = nil

        // 未连接时使用通用边框
        configureBezel(for: platform, deviceName: nil)

        // 隐藏渲染视图，显示状态容器
        renderView.isHidden = true
        statusView.isHidden = false
        updateStatsBadgeVisibility()

        // 统一等待页：iOS / Android 共用「等待手机连接」，无线入口已迁到「连接设备」面板
        statusView.showDisconnected(
            title: L10n.overlayUI.waitingForDevice,
            subtitle: L10n.overlayUI.waitingHint
        )
    }

    /// 显示已连接状态
    /// - Parameters:
    ///   - deviceName: 设备名称
    ///   - platform: 设备平台
    ///   - modelName: 设备型号名称（如 "iPhone 15 Pro"）
    ///   - systemVersion: 系统版本（如 "18.2"）
    ///   - buildVersion: 系统 build 版本（如 "22C5125e"）
    ///   - userPrompt: 用户提示信息（如需要信任、解锁等）
    ///   - deviceState: 设备状态
    ///   - onStart: 开始捕获回调
    ///   - onRefresh: 刷新设备信息回调
    func showConnected(
        device: IOSDevice,
        onStart: @escaping () -> Void,
        onRefresh: ((@escaping () -> Void) -> Void)? = nil
    ) {
        showConnected(
            deviceName: device.displayName,
            platform: .ios,
            modelName: device.displayModelName,
            systemVersion: device.productVersion,
            buildVersion: device.buildVersion,
            userPrompt: device.userPrompt,
            deviceState: device.state,
            iosDevice: device,
            onStart: onStart,
            onRefresh: onRefresh
        )
    }

    /// 显示已连接状态（通用方式）
    /// - Parameters:
    ///   - deviceName: 设备名称
    ///   - platform: 设备平台
    ///   - modelName: 设备型号名称
    ///   - systemVersion: 系统版本
    ///   - buildVersion: iOS build 版本（如 "22C5125e"）
    ///   - sdkVersion: Android SDK 版本（如 "31"）
    ///   - userPrompt: 用户提示信息（如需要信任、解锁等）
    ///   - deviceState: 设备状态
    ///   - iosDevice: iOS 设备实例（用于精确识别设备型号）
    ///   - androidDevice: Android 设备实例（用于精确识别设备型号）
    ///   - onStart: 开始捕获回调
    ///   - onRefresh: 刷新设备信息回调
    func showConnected(
        deviceName: String,
        platform: DevicePlatform,
        modelName: String? = nil,
        systemVersion: String? = nil,
        buildVersion: String? = nil,
        sdkVersion: String? = nil,
        userPrompt: String? = nil,
        deviceState: IOSDevice.State? = nil,
        iosDevice: IOSDevice? = nil,
        androidDevice: AndroidDevice? = nil,
        onStart: @escaping () -> Void,
        onRefresh: ((@escaping () -> Void) -> Void)? = nil
    ) {
        // 记录之前是否在捕获状态（用于决定是否重新配置 bezel）
        let wasCapturing = currentState == .capturing

        currentState = .connected
        currentPlatform = platform
        // 注意：不重置 currentCaptureResolution，以便保留最后的 aspectRatio
        onStartAction = onStart
        onRefreshAction = onRefresh
        currentUserPrompt = userPrompt
        stopFPSUpdateTimer()

        // 配置边框：
        // - 如果之前在捕获状态（停止投屏），保留当前的 aspectRatio，避免位置跳动
        // - 如果之前不在捕获状态（新连接设备），使用设备默认值配置
        if !wasCapturing {
            if let device = iosDevice {
                configureBezel(for: device)
            } else if let device = androidDevice {
                configureBezel(for: device)
            } else {
                configureBezel(for: platform, deviceName: deviceName)
            }
        }
        // 如果是从捕获状态切换过来，保留当前 bezel 的 aspectRatio，不重新配置

        // 隐藏渲染视图，显示状态容器
        renderView.isHidden = true
        statusView.isHidden = false
        updateStatsBadgeVisibility()

        // 计算状态颜色和是否有警告
        let statusColor: NSColor
        let hasWarning: Bool
        if userPrompt != nil {
            statusColor = if let state = deviceState {
                IOSDeviceStateMapper.statusColor(for: state)
            } else {
                .systemOrange
            }
            hasWarning = true
        } else {
            statusColor = .systemGreen
            hasWarning = false
        }

        // 构建设备详细信息文本
        let detailInfo = buildDeviceDetailInfo(
            platform: platform,
            modelName: modelName,
            systemVersion: systemVersion,
            buildVersion: buildVersion,
            sdkVersion: sdkVersion
        )

        // 更新状态视图
        statusView.showConnected(
            deviceName: deviceName,
            statusText: userPrompt ?? L10n.overlayUI.deviceDetected,
            statusColor: statusColor,
            hasWarning: hasWarning,
            subtitle: detailInfo,
            showRefresh: onRefresh != nil
        )
    }

    /// 构建设备详细信息文本
    /// - Parameters:
    ///   - platform: 设备平台
    ///   - modelName: 型号名称
    ///   - systemVersion: 系统版本
    ///   - buildVersion: iOS build 版本
    ///   - sdkVersion: Android SDK 版本
    private func buildDeviceDetailInfo(
        platform: DevicePlatform,
        modelName: String?,
        systemVersion: String?,
        buildVersion: String?,
        sdkVersion: String? = nil
    ) -> String {
        var parts: [String] = []

        // 型号名称（如 iPhone 15 Pro 或 OnePlus PKX110）
        if let model = modelName, !model.isEmpty {
            parts.append(model)
        }

        // 系统版本
        if let version = systemVersion, !version.isEmpty {
            if platform == .ios {
                // iOS 版本格式：iOS 17.0 (21A5248v)
                if let build = buildVersion, !build.isEmpty {
                    parts.append("iOS \(version) (\(build))")
                } else {
                    parts.append("iOS \(version)")
                }
            } else {
                // Android 版本：直接使用已格式化的 displaySystemVersion
                // 格式如: ColorOS 15(Android 15 · SDK 35) 或 Android 15(SDK 35)
                parts.append(version)
            }
        }

        if parts.isEmpty {
            // 如果没有任何信息，返回默认提示
            return platform == .ios
                ? L10n.overlayUI.captureIOSHint
                : L10n.overlayUI.captureAndroidHint
        }

        return parts.joined(separator: " · ")
    }

    /// 显示 iOS 设备捕获中状态（推荐方式，使用 productType 精确识别）
    func showCapturing(
        device: IOSDevice,
        fps: Double,
        resolution: CGSize,
        onStop: @escaping () -> Void
    ) {
        let wasCapturing = currentState == .capturing && currentPlatform == .ios

        // 新的投屏会话：清空上一次的圆角检测缓存，
        // 否则会沿用旧半径，与新画面尺寸不匹配导致圆角错误
        if !wasCapturing {
            resetCornerRadiusCache()
        }

        // 停止加载状态
        stopActionLoading()

        currentState = .capturing
        currentPlatform = .ios
        onStopAction = onStop

        // 更新 bezel：
        // - resolution 有效时（收到第一帧后）：使用实际分辨率的 aspectRatio
        // - resolution 无效时（未收到帧）：保留当前 bezel 配置，避免位置跳动
        let resolutionValid = resolution.width > 0 && resolution.height > 0
        let resolutionChanged = abs(resolution.width - currentCaptureResolution.width) > 1 ||
            abs(resolution.height - currentCaptureResolution.height) > 1

        // 只有在收到有效分辨率且分辨率变化时才更新 bezel
        if resolutionValid, !wasCapturing || resolutionChanged {
            // 收到第一帧后，使用实际视频分辨率更新 bezel
            bezelView.updateAspectRatio(resolution.width / resolution.height)
            currentCaptureResolution = resolution
            renderView.fallbackVideoAspect = resolution.width / resolution.height
        }
        // 注意：如果还没收到帧，保留当前 bezel 的 aspectRatio，不重新配置

        // 如果已经在捕获状态，只更新分辨率相关的 UI，跳过其他配置
        if wasCapturing {
            if resolutionValid {
                statsBadge.updateResolution(resolution)
                layoutStatsBadge()
            }
            return
        }

        // 显示渲染视图，隐藏状态容器
        renderView.isHidden = false
        statusView.isHidden = true

        // 更新统计角标的分辨率和 FPS
        statsBadge.updateResolution(resolutionValid ? resolution : .zero)
        layoutStatsBadge()
        updateFPS(fps)
        updateStatsBadgeVisibility()

        // 仅在光标位于画面上时显示控制浮层，开始投屏不主动打断演示。
        refreshCaptureHover()

        // 启动 FPS 更新定时器
        startFPSUpdateTimer()
    }

    /// 显示捕获中状态（通用方式，通过设备名称识别）
    /// - Parameters:
    ///   - deviceName: 设备名称
    ///   - modelName: 型号名称
    ///   - systemVersion: 系统版本
    ///   - sdkVersion: Android SDK 版本（如 "31"）
    ///   - platform: 设备平台
    ///   - fps: 帧率
    ///   - resolution: 分辨率
    ///   - androidDevice: Android 设备实例（用于精确识别设备型号）
    ///   - onStop: 停止捕获回调
    func showCapturing(
        deviceName: String,
        modelName: String?,
        systemVersion: String? = nil,
        sdkVersion: String? = nil,
        platform: DevicePlatform,
        fps: Double,
        resolution: CGSize,
        androidDevice: AndroidDevice? = nil,
        onStop: @escaping () -> Void
    ) {
        let wasCapturing = currentState == .capturing && currentPlatform == platform

        // 新的投屏会话：清空上一次的圆角检测缓存
        if !wasCapturing {
            resetCornerRadiusCache()
        }

        // 停止加载状态
        stopActionLoading()

        currentState = .capturing
        currentPlatform = platform
        onStopAction = onStop

        // 更新 bezel：
        // - resolution 有效时（收到第一帧后）：使用实际分辨率的 aspectRatio
        // - resolution 无效时（未收到帧）：保留当前 bezel 配置，避免位置跳动
        let resolutionValid = resolution.width > 0 && resolution.height > 0
        let resolutionChanged = abs(resolution.width - currentCaptureResolution.width) > 1 ||
            abs(resolution.height - currentCaptureResolution.height) > 1

        // 只有在收到有效分辨率且分辨率变化时才更新 bezel
        if resolutionValid, !wasCapturing || resolutionChanged {
            // 收到第一帧后，使用实际视频分辨率更新 bezel
            bezelView.updateAspectRatio(resolution.width / resolution.height)
            currentCaptureResolution = resolution
            renderView.fallbackVideoAspect = resolution.width / resolution.height
        }
        // 注意：如果还没收到帧，保留当前 bezel 的 aspectRatio，不重新配置

        // 如果已经在捕获状态，只更新分辨率相关的 UI，跳过其他配置
        if wasCapturing {
            if resolutionValid {
                statsBadge.updateResolution(resolution)
                layoutStatsBadge()
            }
            return
        }

        // 显示渲染视图，隐藏状态容器
        renderView.isHidden = false
        statusView.isHidden = true

        // 更新统计角标的分辨率和 FPS
        statsBadge.updateResolution(resolutionValid ? resolution : .zero)
        layoutStatsBadge()
        updateFPS(fps)
        updateStatsBadgeVisibility()

        // 仅在光标位于画面上时显示控制浮层，开始投屏不主动打断演示。
        refreshCaptureHover()

        // 启动 FPS 更新定时器
        startFPSUpdateTimer()
    }

    /// 显示加载状态
    func showLoading(platform: DevicePlatform) {
        currentState = .loading
        currentPlatform = platform
        currentCaptureResolution = .zero
        stopFPSUpdateTimer()
        currentUserPrompt = nil

        // 配置边框外观
        configureBezel(for: platform, deviceName: nil)

        // 隐藏渲染视图，显示状态容器
        renderView.isHidden = true
        statusView.isHidden = false
        updateStatsBadgeVisibility()

        // 更新状态视图
        statusView.showLoading(title: L10n.common.loading)
    }

    /// 显示工具链缺失状态
    func showToolchainMissing(toolName: String, onInstall: @escaping () -> Void) {
        currentState = .toolchainMissing
        currentCaptureResolution = .zero
        onInstallAction = onInstall
        onStartAction = onInstall
        stopFPSUpdateTimer()
        currentUserPrompt = nil

        // 工具链缺失时使用通用 Android 边框
        configureBezel(for: .android, deviceName: nil)

        // 隐藏渲染视图，显示状态容器
        renderView.isHidden = true
        statusView.isHidden = false
        updateStatsBadgeVisibility()

        // 更新状态视图
        statusView.showToolchainMissing(
            toolName: toolName,
            hint: L10n.toolchain.installScrcpyHint
        )
    }

    // MARK: - 按钮控制

    /// 设置操作按钮的启用状态
    func setActionButtonEnabled(_ enabled: Bool) {
        statusView.setActionButtonEnabled(enabled)
    }

    /// 更新帧率
    func updateFPS(_ fps: Double) {
        guard currentState == .capturing else { return }
        statsBadge.updateFPS(fps)
        layoutStatsBadge()
    }

    /// 更新捕获分辨率（在捕获过程中分辨率变化时调用）
    /// 只更新 bezel 的 aspectRatio 和分辨率标签，避免重新配置整个 UI
    func updateCaptureResolution(_ resolution: CGSize) {
        guard currentState == .capturing else { return }

        // 检查分辨率是否真的变化了
        let resolutionChanged = abs(resolution.width - currentCaptureResolution.width) > 1 ||
            abs(resolution.height - currentCaptureResolution.height) > 1
        guard resolutionChanged else { return }

        currentCaptureResolution = resolution

        // 分辨率变化（含横竖屏切换）：圆角需重新检测并换算
        detectedCornerRadiusInPixels = nil
        renderView.resetCornerDetection()

        // 更新 bezel 的 aspectRatio
        if resolution.width > 0, resolution.height > 0 {
            bezelView.updateAspectRatio(resolution.width / resolution.height)
            statsBadge.updateResolution(resolution)
        }

        // 重新布局以更新角标位置
        needsLayout = true
        layoutStatsBadge()
    }

    /// 获取边框屏幕区域的位置（用于 Metal 渲染）
    var screenFrame: CGRect {
        if showBezel {
            let bezelScreenFrame = bezelView.screenFrame
            return bezelView.convert(bezelScreenFrame, to: self)
        } else {
            // 隐藏 bezel 时，返回整个面板的边界
            return bounds
        }
    }

    /// 获取设备的宽高比（宽度/高度）
    /// 返回值保证 > 0，避免布局约束问题
    var deviceAspectRatio: CGFloat {
        if showBezel {
            let ratio = bezelView.aspectRatio
            // 确保返回有效的宽高比，避免除零或无效约束
            return ratio > 0.1 ? ratio : 0.46 // 默认使用 iPhone 的宽高比
        } else {
            // 隐藏 bezel 时，使用屏幕内容的宽高比
            let ratio = bezelView.screenAspectRatio
            return ratio > 0.1 ? ratio : 0.46
        }
    }

    /// 获取屏幕圆角半径（用于 Metal 渲染遮罩）
    var screenCornerRadius: CGFloat {
        showBezel ? bezelView.screenCornerRadius : 0
    }

    /// 获取顶部特征（刘海/灵动岛/摄像头开孔）的底部距离
    var topFeatureBottomInset: CGFloat {
        showBezel ? bezelView.topFeatureBottomInset : 0
    }

    /// 设置 bezel 可见性
    /// - Parameter visible: 是否显示 bezel
    func setBezelVisible(_ visible: Bool) {
        guard showBezel != visible else { return }
        showBezel = visible
        updateBezelVisibility()
    }

    /// 更新 bezel 可见性（重新布局视图）
    private func updateBezelVisibility() {
        if showBezel {
            // 显示 bezel：将画面和状态视图移回屏幕区域，控制浮层始终留在独立窗口中。
            bezelView.isHidden = false

            renderView.removeFromSuperview()
            bezelView.screenContentView.addSubview(renderView)

            statusView.removeFromSuperview()
            bezelView.screenContentView.addSubview(statusView)
        } else {
            // 隐藏 bezel：将画面和状态视图移到 self 中。
            bezelView.isHidden = true

            renderView.removeFromSuperview()
            addSubview(renderView)

            statusView.removeFromSuperview()
            addSubview(statusView)
        }

        // 隐藏边框时也要保留圆角，避免画面变成生硬的直角矩形
        updateRenderCornerRadius()

        // 容器切换后角标要挂到新的画面容器上
        installStatsBadge()

        // 强制重新布局
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateContentFrames() {
        let containerView: NSView = showBezel ? bezelView.screenContentView : self
        let targetFrame = containerView.bounds
        renderView.frame = targetFrame
        statusView.frame = targetFrame
        updateRenderCornerRadius()
        layoutStatsBadge()
    }

    /// 更新渲染视图圆角
    /// 有边框时由 bezel 统一控制；无边框时按画面短边推算一个接近真机的圆角
    /// 把已知的视频宽高比同步给渲染视图，供按钮条定位兜底
    private func syncVideoAspectFallback() {
        if currentCaptureResolution.width > 0, currentCaptureResolution.height > 0 {
            renderView.fallbackVideoAspect = currentCaptureResolution.width / currentCaptureResolution.height
        }
    }

    private func updateRenderCornerRadius() {
        guard !showBezel else { return }

        // 必须拿到有效视频尺寸才能把「视频像素」换算成「视图坐标」。
        // 首帧前 deviceGeometry 为 nil，此时用兜底比例先渲染一个近似值，
        // 避免圆角在首帧缺失导致视觉跳变。
        let geometry = renderView.deviceGeometry?.size
        let videoWidth = geometry?.width ?? 0
        let videoHeight = geometry?.height ?? 0

        // 视频像素 → 视图坐标的比例
        let displayRect = renderView.videoDisplayRect ?? renderView.bounds
        guard displayRect.width > 0 else { return }

        let radiusInVideoPixels: CGFloat
        if let detected = detectedCornerRadiusInPixels {
            // 1. 像素检测结果（最准确）
            radiusInVideoPixels = detected
        } else if videoWidth > 0, videoHeight > 0 {
            // 2. 回退：设备规格比例 × 视频短边
            radiusInVideoPixels = min(videoWidth, videoHeight)
                * bezelView.deviceModel.screenCornerRadiusRatio
        } else {
            // 3. 首帧前兜底：用面板自身短边 × 设备规格比例，先给一个近似值
            let shortSide = min(displayRect.width, displayRect.height)
            guard shortSide > 0 else { return }
            renderView.cornerRadius = shortSide
                * bezelView.deviceModel.screenCornerRadiusRatio
            return
        }

        guard videoWidth > 0 else { return }
        let scale = displayRect.width / videoWidth
        renderView.cornerRadius = max(0, radiusInVideoPixels * scale)
    }

    /// 像素检测出的圆角半径（视频像素），nil 表示尚未检测到
    private var detectedCornerRadiusInPixels: CGFloat?

    /// 接收渲染视图的圆角检测结果
    private func handleDetectedCornerRadius(_ radiusInPixels: CGFloat) {
        detectedCornerRadiusInPixels = radiusInPixels
        updateRenderCornerRadius()
    }

    /// 重置圆角检测缓存
    /// 每次开始新投屏会话、或分辨率变化时必须调用，
    /// 否则会沿用上一次会话的半径，与新画面尺寸不匹配导致圆角错误。
    func resetCornerRadiusCache() {
        detectedCornerRadiusInPixels = nil
        renderView.resetCornerDetection()
        updateRenderCornerRadius()
    }

    override func layout() {
        super.layout()
        // 禁用隐式动画，避免 frame 变化时子视图产生动画
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bezelView.frame = bounds
        bezelView.layoutSubtreeIfNeeded()
        updateContentFrames()
        // 边框开关会替换画面容器，角标必须跟着挂到新容器上
        if statsBadge.superview !== mirrorContentView {
            installStatsBadge()
        }
        updateStatsBadgeVisibility()
        layoutStatsBadge()
        // 断线覆盖层要跟着窗口缩放一起重算：它只盖住「屏幕区域」，
        // 带边框时不能把金属边框也涂黑，所以不能用 autoresizingMask 铺满整个面板。
        for case let overlay as FloatingDisconnectedOverlay in subviews {
            overlay.frame = screenFrame
        }
        CATransaction.commit()
        // 布局变化后以实际光标位置更新状态，兼容设备交换和边框开关。
        refreshCaptureHover()
        updateControlBarPanelFrame()
    }

    // MARK: - 私有方法

    private var currentDeviceName: String?
    /// 当前捕获分辨率（用于检测变化，避免重复配置）
    private var currentCaptureResolution: CGSize = .zero

    private func configureBezel(for platform: DevicePlatform, deviceName: String? = nil, aspectRatio: CGSize? = nil) {
        currentDeviceName = deviceName
        if let size = aspectRatio, size.width > 0, size.height > 0 {
            bezelView.configure(deviceName: deviceName, platform: platform, aspectRatio: size.width / size.height)
        } else {
            bezelView.configure(deviceName: deviceName, platform: platform)
        }
    }

    /// 配置 iOS 设备的边框（使用 productType 精确识别）
    private func configureBezel(for device: IOSDevice, aspectRatio: CGSize? = nil) {
        currentDeviceName = device.displayName
        if let size = aspectRatio, size.width > 0, size.height > 0 {
            bezelView.configure(device: device, aspectRatio: size.width / size.height)
        } else {
            bezelView.configure(device: device)
        }
    }

    /// 配置 Android 设备的边框（使用 brand 精确识别）
    private func configureBezel(for device: AndroidDevice, aspectRatio: CGSize? = nil) {
        currentDeviceName = device.displayName
        if let size = aspectRatio, size.width > 0, size.height > 0 {
            bezelView.configure(device: device, aspectRatio: size.width / size.height)
        } else {
            bezelView.configure(device: device)
        }
    }

    // MARK: - 操作按钮状态控制

    /// 开始操作按钮加载状态
    func startActionLoading() {
        statusView.startActionLoading()
    }

    /// 停止操作按钮加载状态
    func stopActionLoading() {
        statusView.stopActionLoading()
    }

    // MARK: - FPS 更新定时器

    private func startFPSUpdateTimer() {
        stopFPSUpdateTimer()
        fpsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            updateFPS(renderView.fps)
        }
    }

    private func stopFPSUpdateTimer() {
        fpsUpdateTimer?.invalidate()
        fpsUpdateTimer = nil
    }

    /// 获取实际渲染区域（保持视频宽高比居中显示）
    private var actualRenderRect: CGRect {
        if showBezel {
            // 显示 bezel 时，渲染区域就是 screenFrame
            return screenFrame
        } else {
            // 隐藏 bezel 时，需要计算保持视频宽高比的实际渲染区域
            let containerRect = bounds
            guard containerRect.width > 0, containerRect.height > 0 else { return .zero }

            // 获取视频宽高比（使用 bezelView 的 screenAspectRatio）
            let videoAspect = bezelView.screenAspectRatio
            guard videoAspect > 0 else { return containerRect }

            let containerAspect = containerRect.width / containerRect.height

            var renderWidth: CGFloat
            var renderHeight: CGFloat

            if videoAspect > containerAspect {
                // 视频更宽，以宽度为基准
                renderWidth = containerRect.width
                renderHeight = renderWidth / videoAspect
            } else {
                // 视频更高，以高度为基准
                renderHeight = containerRect.height
                renderWidth = renderHeight * videoAspect
            }

            // 居中
            let x = (containerRect.width - renderWidth) / 2
            let y = (containerRect.height - renderHeight) / 2

            return CGRect(x: x, y: y, width: renderWidth, height: renderHeight)
        }
    }

    // MARK: - 语言变更

    /// 更新本地化文本（语言切换时调用）
    func updateLocalizedTexts() {
        // 更新状态视图的本地化文本
        statusView.updateLocalizedTexts()

        // 根据当前状态重新显示对应的界面
        // 这样可以确保所有本地化文本都被更新
        switch currentState {
        case .loading:
            statusView.showLoading(title: L10n.common.loading)

        case .disconnected:
            let title = currentPlatform == .ios
                ? L10n.overlayUI.waitingForIPhone
                : L10n.overlayUI.waitingForAndroid
            let subtitle = currentPlatform == .ios
                ? L10n.overlayUI.connectIOS
                : L10n.overlayUI.connectAndroid
            statusView.showDisconnected(title: title, subtitle: subtitle)

        case .connected:
            // 设备已连接状态需要保持当前的设备信息，只更新可本地化的文本
            // 这里不做完整的重新显示，因为设备信息是动态的
            break

        case .capturing:
            // 捕获中显示设备信息，不需要本地化更新
            break

        case .toolchainMissing:
            statusView.showToolchainMissing(
                toolName: "scrcpy",
                hint: L10n.toolchain.installScrcpyHint
            )
        }
    }
}
