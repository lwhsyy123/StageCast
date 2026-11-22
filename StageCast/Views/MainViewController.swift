//
//  MainViewController.swift
//  StageCast
//
//  Created by Sun on 2025/12/22.
//
//  主视图控制器
//  包含预览区域和交换按钮
//

import AppKit
import Combine

// MARK: - 主视图控制器

final class MainViewController: NSViewController {
    // MARK: - UI 组件

    private let previewContainerView = PreviewContainerView()
    private var recordingReplayView: RecordingReplayView?

    // MARK: - 设备面板快捷访问

    /// iOS 面板（默认在左侧）
    private var iosPanelView: DevicePanelView { previewContainerView.iosPanelView }
    /// Android 面板（默认在右侧）
    private var androidPanelView: DevicePanelView { previewContainerView.androidPanelView }

    // MARK: - 鼠标追踪

    // MARK: - 状态

    private var cancellables = Set<AnyCancellable>()
    private var isFullScreen: Bool = false

    /// 每格录制绑定：面板 → 设备 ID。录制状态变化时统一刷新各格录制按钮。
    private var recordingBindings: [ObjectIdentifier: (panel: DevicePanelView, deviceID: String)] = [:]
    /// 缓存的 titlebar 高度（非全屏时计算并保存）
    private var cachedTitlebarHeight: CGFloat = 28

    // MARK: - 生命周期

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        setupBindings()
        startRendering()

        // 从偏好设置读取布局模式
        previewContainerView.setLayoutMode(UserPreferences.shared.layoutMode, animated: false)

        // 应用初始 bezel 可见性设置
        previewContainerView.updateBezelVisibility()

        // 应用背景设置
        applyWindowBackground()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 视图已添加到窗口，可以正确获取 titlebar 高度
        // 首次出现时缓存 titlebar 高度
        _ = titlebarHeight
        updatePreviewContainerFrame()

        // 此时 window 才可用：应用「隐藏标题栏」等窗口级设置
        applyWindowChromeVisibility()
        setupEdgeTrackingArea()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if recordingReplayView?.isHidden == false {
            hideRecordingReplay()
        }
        stopRendering()
    }

    // MARK: - UI 设置

    private func setupUI() {
        setupPreviewContainer()
        setupAndroidPanelCallbacks()
        updatePanelLayout()
    }

    /// 应用窗口背景色
    private func applyWindowBackground() {
        // 主窗口始终使用系统窗口底色，不做透明背景：
        // AppKit 在缩放等窗口状态下仍会绘制系统底色，一旦透明就会露出白边。
        let color = NSColor.windowBackgroundColor

        view.layer?.backgroundColor = color.cgColor
        previewContainerView.layer?.backgroundColor = color.cgColor

        view.window?.isOpaque = true
        view.window?.backgroundColor = color

        previewContainerView.layer?.borderWidth = 1

        // 窗口不走透明背景路径，缩放期间也不会绘制系统底色
        if let window = view.window as? TransparentWindow {
            window.opaqueBackgroundColor = color
            window.usesTransparentBackground = false
        }

        // 画面区域由 SingleDeviceRenderView.mouseDownCanMoveWindow 精确控制，
        // 这里只决定「非画面区域」是否可拖动窗口。
        applyWindowMovability()

        // 边框交由 hover 高亮统一管理
        updateWindowEdgeHighlight()

        applyWindowChromeVisibility()
    }

    /// 应用标题栏/工具栏显隐
    /// 隐藏后仍可通过菜单「视图 → 显示标题栏」恢复，不会把自己锁死
    private func applyWindowChromeVisibility() {
        guard let window = view.window else { return }
        let hidden = UserPreferences.shared.hideWindowChrome && !isFullScreen

        window.titlebarAppearsTransparent = hidden
        window.titleVisibility = hidden ? .hidden : .visible
        window.toolbar?.isVisible = !hidden
        // 让内容区延伸到标题栏，消除顶部残留灰条
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = hidden ? .none : .automatic
        // 隐藏标题栏时把标准按钮也收起来，但保留窗口可拖拽与缩放
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
        applyWindowMovability()
        updatePreviewContainerFrame()

        // 边框显隐跟随偏好
        previewContainerView.updateBezelVisibility()
    }

    /// 窗口边缘 hover 高亮
    /// 窗口外框隐藏后，鼠标靠近边缘时显示一圈淡边框，提示可缩放边界
    private func updateWindowEdgeHighlight() {
        refreshMouseNearWindowEdge()
        guard let window = view.window else { return }
        // 边缘高亮统一：不论是否 fit / 是否隐藏标题栏，靠近窗口边缘都给出同一圈淡边框，
        // 让「可缩放边界」的提示在所有模式下表现一致（全屏下没有边界，不显示）。
        let showEdge = !isFullScreen && isMouseNearWindowEdge

        view.layer?.borderWidth = showEdge ? 1 : 0
        view.layer?.borderColor = showEdge
            ? NSColor.white.withAlphaComponent(0.28).cgColor
            : NSColor.clear.cgColor
        _ = window
    }

    /// 鼠标是否靠近窗口边缘（用于显示可缩放提示边框）
    private var isMouseNearWindowEdge: Bool {
        get { _isMouseNearWindowEdge }
        set { _isMouseNearWindowEdge = newValue }
    }

    private var _isMouseNearWindowEdge = false

    /// 根据当前鼠标位置刷新 _isMouseNearWindowEdge
    private func refreshMouseNearWindowEdge() {
        guard let window = view.window else {
            _isMouseNearWindowEdge = false
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInView = view.convert(pointInWindow, from: nil)
        let edgeDistance: CGFloat = 12
        let size = view.bounds.size
        _isMouseNearWindowEdge = pointInView.x < edgeDistance
            || pointInView.y < edgeDistance
            || pointInView.x > size.width - edgeDistance
            || pointInView.y > size.height - edgeDistance
    }

    /// 鼠标移动时刷新边缘高亮
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateWindowEdgeHighlight()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateWindowEdgeHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseNearWindowEdge = false
        updateWindowEdgeHighlight()
    }

    /// 安装边缘 hover 追踪区域
    private func setupEdgeTrackingArea() {
        guard edgeTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        edgeTrackingArea = area
    }

    private var edgeTrackingArea: NSTrackingArea?

    /// 是否允许「点击背景拖动窗口」
    /// 投屏中禁止，避免抢占画面上的鼠标操作；未投屏时允许，方便调整窗口
    private func applyWindowMovability() {
        guard let window = view.window else { return }
        let capturing = AppState.shared.androidCapturing || AppState.shared.iosCapturing
        window.isMovableByWindowBackground = !capturing
    }

    private func setupAndroidPanelCallbacks() {
        // 真实视频尺寸就绪或横竖屏切换时，重新贴合窗口比例
        androidPanelView.onVideoSizeChanged = { [weak self] size in
            guard let self, size.height > 0 else { return }
            self.handleCaptureResolutionChange()
        }

        // 注：onAudioUnavailable 在 setupAndroidInput 里绑定，
        // 因为此处 androidDeviceSource 可能尚未创建（首次投屏时才建立）

        // 网格面板分配/回收：面板由 DeviceGridView 创建，内容在此接线
        previewContainerView.gridView.onPanelAssigned = { [weak self] panel, item in
            self?.wireGridPanel(panel, item: item)
        }
        previewContainerView.gridView.onPanelReleased = { [weak self] panel in
            self?.unwireGridPanel(panel)
        }
        // 拖拽换位：记忆新顺序并重建列表（面板差分保留）
        previewContainerView.gridView.onItemsReordered = { [weak self] ids in
            UserPreferences.shared.gridDeviceOrder = ids
            self?.updateGridPanels()
        }

        // 浮窗面板分配/回收：与网格共用同一套接线
        floatingWindows.onPanelAssigned = { [weak self] panel, item in
            self?.wireGridPanel(panel, item: item)
        }
        floatingWindows.onPanelReleased = { [weak self] panel in
            self?.unwireGridPanel(panel)
        }
        // 关闭浮窗即停止该设备投屏（只关窗不停流会让采集在后台空转）
        floatingWindows.onWindowClosed = { [weak self] itemID in
            self?.stopCaptureForFloatingWindow(itemID)
        }
        // 掉线浮窗上的「重新连接」
        floatingWindows.onReconnectRequest = { [weak self] itemID in
            self?.reconnectFloatingDevice(itemID)
        }
    }

    private func setupPreviewContainer() {
        // 非全屏时使用默认背景色，全屏时使用用户偏好的黑色+透明度
        previewContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(previewContainerView)
        updatePreviewContainerFrame()
    }

    /// 动态获取 titlebar 高度
    private var titlebarHeight: CGFloat {
        guard let window = view.window else {
            // 默认值：使用缓存值
            return cachedTitlebarHeight
        }
        // contentLayoutRect 是内容区域的矩形，不包含 titlebar
        // titlebar 高度 = 窗口高度 - 内容区域高度
        let contentHeight = window.contentLayoutRect.height
        let windowHeight = window.frame.height
        let height = windowHeight - contentHeight

        // 只有在非全屏且计算结果有效时才缓存
        // 退出全屏过渡期间可能计算为 0，此时使用缓存值
        if height > 0, !isFullScreen {
            cachedTitlebarHeight = height
            return height
        }

        // 过渡期间或计算为 0 时，返回缓存值
        return cachedTitlebarHeight
    }

    private func updateTitlebarVisibility(animated: Bool = true) {
        guard let window = view.window else { return }

        // 全屏时隐藏 toolbar，非全屏时显示
        let shouldShow = !isFullScreen

        // 注意：这里不能用 allowsImplicitAnimation。
        // toolbar 显隐会改变 contentLayoutRect，AppKit 随即调整窗口 frame；
        // 一旦被包成 CABasicAnimation，动画在 CA tick 中重放时目标 frame 的
        // height 可能解算为 NaN，AppKit 会在 _reallySetFrame 里抛
        // "Invalid parameter not satisfying: CGRectContainsRect(...)" 直接崩溃。
        // toolbar 显隐本身不需要动画，直接同步赋值即可。
        _ = animated
        window.toolbar?.isVisible = shouldShow

        // 更新 previewContainerView 的顶部约束
        updatePreviewContainerFrame()
    }

    /// 确保 toolbar 可见（退出全屏后调用）
    func ensureToolbarVisible() {
        guard !isFullScreen, let window = view.window else { return }
        window.toolbar?.isVisible = true
    }

    private func updatePreviewContainerFrame() {
        // 全屏、或隐藏标题栏时，内容区延伸到顶部，不留标题栏灰条
        let chromeHidden = UserPreferences.shared.hideWindowChrome
        let topOffset: CGFloat = (isFullScreen || chromeHidden) ? 0 : titlebarHeight
        let bounds = view.bounds
        previewContainerView.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(0, bounds.height - topOffset)
        )
        recordingReplayView?.frame = previewContainerView.frame
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePreviewContainerFrame()
    }

    private func updatePanelLayout(animated: Bool = true) {
        // 更新面板内容
        updateAndroidPanel(androidPanelView)
        updateIOSPanel(iosPanelView)

        // 委托给 previewContainerView 处理布局
        previewContainerView.updateLayout(animated: animated)
    }

    // MARK: - 绑定

    private func setupBindings() {
        AppState.shared.stateChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateUI()
            }
            .store(in: &cancellables)

        // 录制状态变化（含每秒计时）→ 刷新各格控制条的录制按钮
        AppState.shared.recordingService.stateChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.refreshRecordingIndicators()
            }
            .store(in: &cancellables)

        // 注意：纹理更新由数据源的帧回调驱动，而不是渲染请求
        // 这在 updateIOSPanel/updateAndroidPanel 中设置

        // 监听背景色变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackgroundColorChange),
            name: .backgroundColorDidChange,
            object: nil
        )

        // 监听标题栏显隐
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowChromeVisibilityChange),
            name: .windowChromeVisibilityDidChange,
            object: nil
        )

        // 监听 bezel 可见性变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBezelVisibilityChange),
            name: .deviceBezelVisibilityDidChange,
            object: nil
        )

        // 监听布局模式变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutModeChange),
            name: .layoutModeDidChange,
            object: nil
        )

        // 监听音频设置变化：音频通道涉及 socket 连接顺序，必须重连会话才能生效
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSettingsChange),
            name: .audioSettingsDidChange,
            object: nil
        )

        // 监听显示器变化（插拔外接屏/改分辨率）：重新贴合窗口，避免窗口留在屏幕外
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// 显示器参数变化（插拔外接屏、改分辨率）：重新贴合窗口并保证窗口可见
    @objc private func handleScreenParametersChange(_ note: Notification) {
        guard let window = view.window, !isFullScreen else { return }
        // 把窗口约束回可见区域，避免上次位置落在已拔掉的屏幕上
        if let screen = window.screen ?? NSScreen.main {
            let constrained = window.constrainFrameRect(window.frame, to: screen)
            if constrained != window.frame {
                // 不用 animate：隐式/显式窗口动画在 CA tick 中重放时，
                // 若目标 frame 含非有限值会直接 SIGABRT（详见 TransparentWindow 注释）
                window.setFrame(constrained, display: true, animate: false)
            }
        }
        updatePanelLayout(animated: false)
    }

    /// 音频设置变化：提示用户重启投屏
    /// 音频通道参与 socket 连接顺序（video → audio → control），
    /// 中途开关无法热切换，必须重建会话
    @objc private func handleAudioSettingsChange(_ note: Notification) {
        // 只关心 Android 平台，且当前正在投屏
        guard let platform = note.userInfo?["platform"] as? String, platform == "android" else { return }
        guard AppState.shared.androidCapturing else { return }

        let alert = NSAlert()
        alert.messageText = L10n.prefs.scrcpyPref.audioRestartTitle
        alert.informativeText = L10n.prefs.scrcpyPref.audioRestartMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.prefs.scrcpyPref.audioRestartNow)
        alert.addButton(withTitle: L10n.prefs.scrcpyPref.audioRestartLater)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            await AppState.shared.stopAndroidCapture()
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { self.startAndroidCapture() }
        }
    }

    /// 音频不可用提示（设备不支持 scrcpy 音频通道）
    private func showAudioUnavailableHint() {
        let alert = NSAlert()
        alert.messageText = L10n.prefs.scrcpyPref.audioUnavailableTitle
        alert.informativeText = L10n.prefs.scrcpyPref.audioUnavailableMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.common.ok)
        alert.runModal()
    }

    @objc private func handleLayoutModeChange() {
        previewContainerView.setLayoutMode(UserPreferences.shared.layoutMode, animated: true)
        // 布局模式切换要重建呈现（浮窗开关窗、网格重建面板）
        updateGridPanels()
        updateLayoutModeToolbarState()
    }

    /// 同步工具栏布局段可用状态（设备数变化时）
    private func updateLayoutModeToolbarState() {
        (NSApp.delegate as? AppDelegate)?.refreshLayoutModeToolbarState()
    }

    @objc private func handleBezelVisibilityChange() {
        previewContainerView.updateBezelVisibility()
    }

    @objc private func handleWindowChromeVisibilityChange() {
        applyWindowChromeVisibility()
    }

    @objc private func handleBackgroundColorChange() {
        // 只有全屏时才应用用户偏好的背景色（黑色+透明度）
        if isFullScreen {
            let bgColor = UserPreferences.shared.backgroundColor.cgColor
            view.layer?.backgroundColor = bgColor // titlebar 透明，会显示 view 的背景色
            previewContainerView.layer?.backgroundColor = bgColor
        } else {
            // 非全屏：透明背景开关切换后立即生效
            applyWindowBackground()
        }
    }

    // MARK: - 渲染

    private func startRendering() {
        iosPanelView.renderView.startRendering()
        androidPanelView.renderView.startRendering()
    }

    private func stopRendering() {
        iosPanelView.renderView.stopRendering()
        androidPanelView.renderView.stopRendering()
    }

    // MARK: - UI 更新

    /// 记录上次的 aspectRatio，用于检测变化
    private var lastIOSAspectRatio: CGFloat = 0
    private var lastAndroidAspectRatio: CGFloat = 0

    private func updateUI() {
        // 先记录旧的 aspectRatio
        let oldIOSRatio = iosPanelView.deviceAspectRatio
        let oldAndroidRatio = androidPanelView.deviceAspectRatio
        let oldCaptureSize = AppState.shared.androidDeviceSource?.captureSize

        // 更新面板内容
        updateAndroidPanel(androidPanelView)
        updateIOSPanel(iosPanelView)

        // 检查 aspectRatio 是否变化，如果变化则重新布局
        let newIOSRatio = iosPanelView.deviceAspectRatio
        let newAndroidRatio = androidPanelView.deviceAspectRatio

        if abs(newIOSRatio - oldIOSRatio) > 0.01 || abs(newAndroidRatio - oldAndroidRatio) > 0.01 {
            updatePanelLayout()
        }

        // 捕获分辨率变化（含横竖屏切换）时，重新贴合窗口
        let newCaptureSize = AppState.shared.androidDeviceSource?.captureSize
        if let old = oldCaptureSize, let new = newCaptureSize,
           abs(old.width - new.width) > 1 || abs(old.height - new.height) > 1 {
            handleCaptureResolutionChange()
        }

        // 网格模式：同步所有网格面板
        updateGridPanels()

    }

    // MARK: - 设备计数

    /// 正在投屏的设备总数（Android 按物理设备去重 + iOS）
    private var capturingDeviceCount: Int {
        AppState.shared.capturingPhysicalDeviceCount
    }


    // MARK: - 网格面板（多设备布局）

    /// 网格面板注册表：itemID → 面板（用于状态刷新）
    private var gridPanelsByItemID: [String: DevicePanelView] = [:]

    /// 上一次实际应用的布局模式（用于检测切换并回收旧面板）
    private var lastAppliedLayoutMode: PreviewLayoutMode?

    /// 是否因为「浮窗模式」自动把主窗最小化了（用于在退出浮窗模式时恢复）
    private var didAutoMinimizeForFloating = false

    /// 是否已经提示过「iOS 仅投屏、不支持控制」（每次启动只提示一次）
    private var didShowIOSMirrorOnlyHint = false

    /// 独立浮窗模式：每台投屏设备一个独立窗口
    private let floatingWindows = DeviceFloatingWindowManager()

    /// 主面板当前绑定的 Android 源（用于避免每次刷新都清空纹理导致静态画面黑屏）
    private var lastPrimaryAndroidSource: ScrcpyDeviceSource?

    /// 关闭浮窗后停止对应设备：Android 停采集；iOS 停采集并回退到空态/其他设备
    private func stopCaptureForFloatingWindow(_ itemID: String) {
        let appState = AppState.shared
        if appState.androidSources[itemID] != nil {
            Task { @MainActor in
                await appState.stopAndroidCapture(serial: itemID)
            }
            return
        }
        if appState.iosSources[itemID] != nil {
            Task { @MainActor in
                await appState.stopIOSCapture(deviceID: itemID)
            }
        }
    }

    /// 掉线浮窗点「重新连接」：设备还在列表里就直接重开，
    /// 无线设备掉线后通常已从 adb devices 消失，则按 serial（ip:port）重新 connect
    private func reconnectFloatingDevice(_ itemID: String) {
        Task { @MainActor in
            let provider = AppState.shared.androidDeviceProvider
            if let device = provider.device(for: itemID) {
                do {
                    try await AppState.shared.startAndroidCapture(device: device)
                } catch {
                    ToastView.warning(error.localizedDescription, in: view.window)
                }
                return
            }
            do {
                _ = try await provider.connectWirelessSmart(input: itemID)
                await provider.refreshDevices()
                guard let device = provider.device(for: itemID) else {
                    ToastView.warning(L10n.floating.reconnectFailed, in: view.window)
                    return
                }
                try await AppState.shared.startAndroidCapture(device: device)
            } catch {
                ToastView.warning(error.localizedDescription, in: view.window)
            }
        }
    }

    /// 同步网格设备列表并刷新已接线面板的显示信息
    private func updateGridPanels() {
        let appState = AppState.shared
        var items: [DeviceGridItem] = []

        // Android 按物理设备去重：同一台手机多个 transport 只出一个格子，
        // 否则会出现两个格子显示同一画面的"重复投屏"。
        for entry in appState.capturingAndroidSourcesDeduped.sorted(by: { $0.serial < $1.serial }) {
            items.append(DeviceGridItem(id: entry.serial, platform: .android))
        }
        for (deviceID, source) in appState.iosSources.sorted(by: { $0.key < $1.key }) {
            guard source.state == .capturing else { continue }
            items.append(DeviceGridItem(id: deviceID, platform: .ios))
        }

        // 按记忆顺序排序（拖拽换位持久化；未记住的设备保持原相对顺序排在已记住设备之后）
        let savedOrder = UserPreferences.shared.gridDeviceOrder
        if !savedOrder.isEmpty {
            items = items.enumerated().sorted { a, b in
                let ia = savedOrder.firstIndex(of: a.element.id) ?? Int.max
                let ib = savedOrder.firstIndex(of: b.element.id) ?? Int.max
                if ia != ib { return ia < ib }
                return a.offset < b.offset
            }.map { $0.element }
        }

        // 布局模式切换时先彻底回收旧承载（网格面板 / 浮窗面板），
        // 否则同一设备会有两套面板抢同一个帧观察者槽位，切回网格时画面全黑
        let mode = previewContainerView.layoutMode
        if lastAppliedLayoutMode != mode {
            floatingWindows.dismissAll()
            previewContainerView.gridView.resetAllPanels()
            lastAppliedLayoutMode = mode
        }

        // 浮窗模式：每台设备独立窗口，网格容器不使用
        if mode == .floating {
            // 只有「出错态」的源才值得我们保留浮窗等用户重连；
            // 用户主动停止后源会回到 connected/idle，浮窗应当关闭
            let aliveIDs = Set(appState.androidSources.filter {
                if case .error = $0.value.state { return true }
                return false
            }.keys).union(appState.iosSources.filter {
                if case .error = $0.value.state { return true }
                return false
            }.keys)
            floatingWindows.sync(items: items, anchor: view.window?.frame, aliveIDs: aliveIDs)
            // 浮窗模式下主窗里没有任何画面，自动最小化到 Dock，避免占着桌面；
            // 点 Dock 图标可随时恢复（功能入口都还在主窗里）。
            if !items.isEmpty,
               UserPreferences.shared.autoMinimizeInFloatingMode,
               !didAutoMinimizeForFloating,
               let window = view.window,
               !window.isMiniaturized {
                didAutoMinimizeForFloating = true
                window.miniaturize(nil)
            }
        } else {
            if floatingWindows.isActive {
                floatingWindows.dismissAll()
            }
            // 离开浮窗模式（或浮窗已空）时把自动最小化的主窗还原
            if didAutoMinimizeForFloating {
                didAutoMinimizeForFloating = false
                if let window = view.window, window.isMiniaturized {
                    window.deminiaturize(nil)
                }
            }
        }

        previewContainerView.updateGrid(items: items)
        (NSApp.delegate as? AppDelegate)?.refreshLayoutModeToolbarState()

        // 已接线面板：刷新分辨率/FPS/设备信息等动态内容
        for (itemID, panel) in gridPanelsByItemID {
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { continue }
            let item = items[index]
            switch item.platform {
            case .android:
                if let source = appState.androidSources[item.id] {
                    refreshAndroidGridPanel(panel, source: source)
                }
            case .ios:
                if let source = appState.iosSources[item.id] {
                    refreshIOSGridPanel(panel, source: source)
                }
            }
        }

        // 兜底清扫：停止投屏或切换布局后，可能仍有面板的控制条子窗口停在上一次的
        // 屏幕位置（面板没走到 viewWillMove(toWindow:) 时就没人收它）。
        DevicePanelView.sweepInactiveControlBars()
    }

    /// 接线一个新分配的网格面板
    private func wireGridPanel(_ panel: DevicePanelView, item: DeviceGridItem) {
        let appState = AppState.shared
        gridPanelsByItemID[item.id] = panel

        // 边框外观跟随偏好（浮窗模式窗口按整机比例，边框不会超出窗口）
        panel.setBezelVisible(UserPreferences.shared.showDeviceBezel)

        switch item.platform {
        case .android:
            guard let source = appState.androidSources[item.id] else { return }
            // 观察者模式：与主面板并存消费帧（主面板的 onFrame 不被抢占）
            androidGridFrameTokens[item.id] = source.addFrameObserver { [weak panel] pixelBuffer in
                panel?.renderView.updateTexture(from: pixelBuffer)
            }
            if let buffer = source.latestPixelBuffer {
                panel.renderView.updateTexture(from: buffer)
            }
            setupAndroidInput(for: panel, source: source)
            refreshAndroidGridPanel(panel, source: source)

        case .ios:
            guard let source = appState.iosSources[item.id] else { return }
            iosGridFrameTokens[item.id] = source.addFrameObserver { [weak panel] pixelBuffer in
                panel?.renderView.updateTexture(from: pixelBuffer)
            }
            if let buffer = source.latestFrame?.pixelBuffer {
                panel.renderView.updateTexture(from: buffer)
            }
            panel.setInputEnabled(false)
            refreshIOSGridPanel(panel, source: source)
        }

        panel.needsLayout = true
    }

    /// 网格面板帧观察者令牌（注销时使用）
    private var androidGridFrameTokens: [String: UUID] = [:]
    private var iosGridFrameTokens: [String: UUID] = [:]

    /// 回收一个网格面板：解除回调与输入
    private func unwireGridPanel(_ panel: DevicePanelView) {
        panel.setInputEnabled(false)
        panel.setControlActionsVisible(false)
        panel.onInputEvent = nil
        panel.onControlAction = nil

        // 先注销帧观察者，确保不再有渲染线程回调进来，再停渲染、清纹理
        if let itemID = gridPanelsByItemID.first(where: { $0.value === panel })?.key {
            gridPanelsByItemID.removeValue(forKey: itemID)
            if let token = androidGridFrameTokens.removeValue(forKey: itemID) {
                AppState.shared.androidSources[itemID]?.removeFrameObserver(token)
            }
            if let token = iosGridFrameTokens.removeValue(forKey: itemID) {
                AppState.shared.iosSources[itemID]?.removeFrameObserver(token)
            }
        }

        panel.renderView.stopRendering()
        panel.renderView.clearTexture()
    }

    /// 浮窗模式下把窗口宽高比同步成整机比例（含边框），消除 letterbox 黑边
    private func syncFloatingAspect(panel: DevicePanelView, resolution: CGSize) {
        guard previewContainerView.layoutMode == .floating,
              resolution.width > 0,
              resolution.height > 0,
              let itemID = gridPanelsByItemID.first(where: { $0.value === panel })?.key else { return }
        floatingWindows.updateAspect(for: itemID, aspect: panel.deviceAspectRatio)
    }

    /// 刷新 Android 网格面板的显示信息
    private func refreshAndroidGridPanel(_ panel: DevicePanelView, source: ScrcpyDeviceSource) {
        let appState = AppState.shared
        let serial = source.deviceInfo?.id ?? ""
        let device = appState.androidDeviceProvider.devices.first(where: { $0.serial == serial })
        let modelName: String? = {
            if let brand = device?.brand, let model = device?.model {
                let cleaned = model.replacingOccurrences(of: "_", with: " ")
                return "\(brand) \(cleaned)"
            }
            return nil
        }()

        panel.showCapturing(
            deviceName: device?.displayName ?? serial,
            modelName: modelName,
            systemVersion: device?.displaySystemVersion,
            sdkVersion: device?.sdkVersion,
            platform: .android,
            fps: panel.renderView.fps,
            resolution: source.captureSize,
            androidDevice: device,
            onStop: { [weak source] in
                guard let serial = source?.deviceInfo?.id, !serial.isEmpty else { return }
                Task {
                    await AppState.shared.stopAndroidCapture(serial: serial)
                }
            }
        )

        syncFloatingAspect(panel: panel, resolution: source.captureSize)

        // 音频不可用提示
        source.onAudioUnavailable = { [weak self] in
            DispatchQueue.main.async {
                self?.showAudioUnavailableHint()
            }
        }
    }

    /// 刷新 iOS 网格面板的显示信息
    private func refreshIOSGridPanel(_ panel: DevicePanelView, source: IOSDeviceSource) {
        let device = source.iosDevice
        panel.showCapturing(
            device: device,
            fps: panel.renderView.fps,
            resolution: source.captureSize,
            onStop: { [weak source] in
                guard let deviceID = source?.iosDevice.id else { return }
                Task {
                    await AppState.shared.stopIOSCapture(deviceID: deviceID)
                }
            }
        )

        syncFloatingAspect(panel: panel, resolution: source.captureSize)
    }

    private func updateAndroidPanel(_ panel: DevicePanelView) {
        let appState = AppState.shared

        // 应用初始化期间显示加载状态，避免显示"未安装"的闪烁
        if appState.isInitializing {
            panel.showLoading(platform: .android)
            return
        }

        // 检查 scrcpy-server 是否可用
        let scrcpyServerReady = appState.toolchainManager.scrcpyServerPath != nil

        if !scrcpyServerReady {
            panel.showToolchainMissing(toolName: "scrcpy-server") { [weak self] in
                self?.openPreferences()
            }
            panel.renderView.clearTexture()
        } else if appState.androidCapturing {
            // 源切换时先清空旧纹理，避免新源首帧到来前显示上一台设备的画面。
            // 注意：updateAndroidPanel 会在每次布局刷新时被调用，若源未变则不清空，
            // 否则静态画面（编码器只在画面变化时发帧）会让面板长时间显示黑屏。
            let currentSource = appState.androidDeviceSource
            if currentSource !== lastPrimaryAndroidSource {
                panel.renderView.clearTexture()
                lastPrimaryAndroidSource = currentSource
            } else if let buffer = currentSource?.latestPixelBuffer {
                // 源未变但布局刷新清不了帧：补推当前帧，防止静态画面期间面板发黑
                panel.renderView.updateTexture(from: buffer)
            }
            // 关键：解除其他源对本面板的帧回调（多设备时主源指针翻转后，
            // 旧源的 onFrame 若不清除会继续推帧，导致两格显示同一画面）
            for other in appState.androidSources.values where other !== currentSource {
                other.onFrame = nil
            }
            // 设置帧回调，每个新帧到来时更新纹理
            appState.androidDeviceSource?.onFrame = { [weak panel] pixelBuffer in
                panel?.renderView.updateTexture(from: pixelBuffer)
            }

            // 启用画面输入（鼠标/键盘操作手机）
            setupAndroidInput(for: panel)

            panel.showCapturing(
                deviceName: appState.androidDeviceName ?? "Android",
                modelName: appState.androidDeviceModelName,
                systemVersion: appState.androidDeviceSystemVersion,
                sdkVersion: appState.androidDeviceSdkVersion,
                platform: .android,
                fps: panel.renderView.fps,
                resolution: appState.androidDeviceSource?.captureSize ?? .zero,
                androidDevice: appState.currentAndroidDevice,
                onStop: { [weak self] in
                    self?.stopAndroidCapture()
                }
            )
        } else if appState.androidConnected {
            // 清除帧回调与输入（所有源都解除，防止停止后旧源继续推帧）
            for source in appState.androidSources.values {
                source.onFrame = nil
            }
            panel.setInputEnabled(false)
            panel.setControlActionsVisible(false)
            // 检查设备是否已授权（state == .device）
            let isDeviceReady = appState.androidDeviceReady
            let userPrompt = appState.androidDeviceUserPrompt

            panel.showConnected(
                deviceName: appState.androidDeviceName ?? "Android",
                platform: .android,
                modelName: appState.androidDeviceModelName,
                systemVersion: appState.androidDeviceSystemVersion,
                sdkVersion: appState.androidDeviceSdkVersion,
                userPrompt: userPrompt,
                androidDevice: appState.currentAndroidDevice,
                onStart: { [weak self] in
                    // 只有设备已授权才允许捕获
                    if isDeviceReady {
                        self?.startAndroidCapture()
                    }
                },
                onRefresh: { [weak self] completion in
                    self?.refreshAndroidDeviceInfo(completion: completion)
                }
            )

            // 如果设备未授权，禁用开始按钮
            if !isDeviceReady {
                panel.setActionButtonEnabled(false)
            }

            panel.renderView.clearTexture()
        } else {
            panel.showDisconnected(platform: .android)
            panel.setInputEnabled(false)
            panel.setControlActionsVisible(false)
            panel.renderView.clearTexture()
        }
    }


    // MARK: - Android 输入

    /// 是否已提示过“控制设置需重新开始投屏生效”，避免每帧刷新都弹提示
    private var didWarnControlNeedsRestart = false

    // MARK: - 无线：mDNS 扫描 / 配对 / 诊断

    /// 「连接设备」面板无线区的唯一实例（手动连接 / 配对 / 诊断入口都在那里）
    private weak var wirelessPanelView: DeviceWirelessPanelView?

    /// 无线相关提示的宿主视图：优先选择器面板里的无线区，回退到设备面板
    private var wirelessUIOwner: NSView { wirelessPanelView ?? androidPanelView }

    /// 由 AppDelegate 在创建「连接设备」面板后接线，把无线区事件接到这里的处理函数
    func attachWirelessPanel(_ view: DeviceWirelessPanelView) {
        wirelessPanelView = view
        view.onConnect = { [weak self] host in
            self?.connectAndroidWireless(input: host)
        }
        view.onEnable = { [weak self] in
            self?.enableAndroidWirelessDebugging()
        }
        view.onPair = { [weak self] host, port, code in
            self?.pairAndroidWireless(host: host, port: port, code: code)
        }
        view.onDiagnose = { [weak self] in
            self?.diagnoseAndroidWireless()
        }
    }

    /// 扫描局域网内的无线调试服务
    /// 主通道用系统 Network.framework 的 Bonjour 浏览（绕开 adb Openscreen 在部分 macOS 不可用），
    /// 失败时回退到 adb mdns。
    private func scanAndroidWirelessServices() {
        Task {
            let provider = AppState.shared.androidDeviceProvider
            var endpoints = await provider.discoverWirelessEndpoints()

            // 回退：系统发现为空时尝试 adb mdns
            if endpoints.isEmpty {
                let services = await provider.discoverWirelessServices()
                endpoints = services.compactMap { service in
                    guard let address = service.address,
                          let port = Int(address.split(separator: ":").last ?? "")
                    else { return nil }
                    let host = String(address.split(separator: ":").first ?? "")
                    let type: WirelessDiscoveryService.ServiceType =
                        service.isPairingService ? .pairing : .connect
                    return WirelessDiscoveredEndpoint(
                        serviceName: service.name,
                        host: host,
                        port: port,
                        serviceType: type
                    )
                }
            }

            await MainActor.run {
                AppLogger.connection.debug(
                    "[WirelessDiscovery] 扫描完成：端点 \(endpoints.count)，其中可连接 \(endpoints.filter { $0.isConnect }.count)"
                )
                // 排序：优先「上次成功连接过的 IP」，避免多设备时默认选错
                let cachedHost = UserDefaults.standard
                    .dictionaryRepresentation()
                    .keys
                    .filter { $0.hasPrefix("wireless.portCache.ip.") }
                    .max { lhs, rhs in
                        let l = UserDefaults.standard.data(forKey: lhs).flatMap {
                            try? JSONDecoder().decode(WirelessPortCacheEntry.self, from: $0)
                        }?.updatedAt ?? .distantPast
                        let r = UserDefaults.standard.data(forKey: rhs).flatMap {
                            try? JSONDecoder().decode(WirelessPortCacheEntry.self, from: $0)
                        }?.updatedAt ?? .distantPast
                        return l < r
                    }
                    .map { String($0.dropFirst("wireless.portCache.ip.".count)) }

                let sorted = endpoints.sorted { a, b in
                    let aPreferred = a.host == cachedHost
                    let bPreferred = b.host == cachedHost
                    if aPreferred != bPreferred { return aPreferred }
                    return a.host < b.host
                }

                let connects = sorted.filter { $0.isConnect }
                guard !connects.isEmpty else {
                    ToastView.warning(L10n.android.wireless.discoverEmpty, in: self.androidPanelView)
                    return
                }

                if connects.count == 1 {
                    self.applyDiscoveredEndpoint(connects[0], all: sorted)
                } else {
                    self.presentDevicePicker(options: connects, all: sorted)
                }
            }
        }
    }

    /// 回填单个发现的端点（host + 配对端口）
    private func applyDiscoveredEndpoint(
        _ endpoint: WirelessDiscoveredEndpoint,
        all: [WirelessDiscoveredEndpoint]
    ) {
        let pairing = all.first { $0.isPairing && $0.host == endpoint.host }
        wirelessPanelView?.fill(host: endpoint.host, pairPort: pairing?.port)
        // 发现成功后立即缓存端口，后续连接可跳过发现
        AppState.shared.androidDeviceProvider.rememberPort(
            endpoint.port,
            host: endpoint.host,
            guid: endpoint.displayName
        )
        ToastView.info(
            L10n.android.wireless.discoveredPort(endpoint.port),
            in: wirelessUIOwner
        )
    }

    /// 多设备时让用户选择
    private func presentDevicePicker(
        options: [WirelessDiscoveredEndpoint],
        all: [WirelessDiscoveredEndpoint]
    ) {
        let alert = NSAlert()
        alert.messageText = L10n.android.wireless.chooseDeviceTitle
        alert.informativeText = L10n.android.wireless.chooseDeviceMessage

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: "\(option.displayName) — \(option.host):\(option.port)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.common.ok)
        alert.addButton(withTitle: L10n.common.cancel)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        guard options.indices.contains(index) else { return }
        applyDiscoveredEndpoint(options[index], all: all)
    }

    /// 使用配对码完成配对并连接
    private func pairAndroidWireless(host: String, port: Int, code: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isValidIPv4(trimmedHost) else {
            ToastView.warning(L10n.android.wireless.invalidHost, in: wirelessUIOwner)
            return
        }
        guard port > 0, trimmedCode.count == 6 else {
            ToastView.warning(L10n.android.wireless.pairInvalid, in: wirelessUIOwner)
            return
        }

        Task {
            let step = await AppState.shared.androidDeviceProvider
                .pairWireless(host: trimmedHost, port: port, code: trimmedCode)

            await MainActor.run {
                self.wirelessPanelView?.showDiagnostics(
                    "[\(step.title)] \(step.command ?? "")\n\(step.output)"
                )
            }

            guard step.isSuccess else {
                await MainActor.run {
                    ToastView.warning(step.output, in: self.androidPanelView)
                }
                return
            }

            // 配对成功后连接调试端口
            // 注意：Android 11+ 的调试端口是随机的，不能固定 5555。
            // connectWirelessSmart 会依次尝试缓存 → mDNS 发现 → 5555。
            do {
                let address = try await AppState.shared.androidDeviceProvider
                    .connectWirelessSmart(input: trimmedHost)
                await MainActor.run {
                    ToastView.info(L10n.android.wireless.connected(address), in: self.androidPanelView)
                }
            } catch {
                await MainActor.run {
                    ToastView.warning(error.localizedDescription, in: self.androidPanelView)
                    self.wirelessPanelView?.showDiagnostics(
                        L10n.android.wireless.pairConnectedNeedPort
                    )
                }
            }
        }
    }

    /// 带完整诊断的无线连接
    private func diagnoseAndroidWireless() {
        let host = (wirelessPanelView?.currentHost ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isValidIPv4(host) else {
            ToastView.warning(L10n.android.wireless.invalidHost, in: wirelessUIOwner)
            return
        }

        Task {
            let steps = await AppState.shared.androidDeviceProvider
                .connectWirelessWithDiagnostics(host: host)

            await MainActor.run {
                let text = steps.map { step in
                    let mark = step.isSuccess ? "✅" : "❌"
                    return "\(mark) \(step.title)\n$ \(step.command ?? "")\n\(step.output)\n"
                }.joined(separator: "\n")
                self.wirelessPanelView?.showDiagnostics(text)

                if steps.last?.isSuccess == true {
                    ToastView.info(L10n.android.wireless.connected("\(host):5555"), in: self.androidPanelView)
                } else {
                    ToastView.warning(L10n.android.wireless.diagnosticsFailed, in: self.androidPanelView)
                }
            }
        }
    }

    /// 连接无线设备
    /// 支持 `IP` 与 `IP:端口` 两种输入，端口缺省走缓存或 5555
    private func connectAndroidWireless(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.device.info("[Wireless] 用户点击连接，输入: \(trimmed)")

        guard let parsed = AndroidDeviceProvider.parseHostPort(trimmed),
              Self.isValidIPv4(parsed.host) else {
            AppLogger.device.warning("[Wireless] 输入格式无效: \(trimmed)")
            ToastView.warning(L10n.android.wireless.invalidHost, in: wirelessUIOwner)
            return
        }

        Task {
            do {
                let address = try await AppState.shared.androidDeviceProvider
                    .connectWirelessSmart(input: trimmed)
                await MainActor.run {
                    ToastView.info(L10n.android.wireless.connected(address), in: self.androidPanelView)
                }
            } catch {
                await MainActor.run {
                    ToastView.warning(error.localizedDescription, in: self.androidPanelView)
                }
            }
        }
    }

    private func enableAndroidWirelessDebugging() {
        Task {
            guard let serial = await MainActor.run(body: {
                AppState.shared.androidDeviceProvider.devices.first { $0.connectionType == .usb }?.serial
            }) else {
                await MainActor.run {
                    ToastView.warning(L10n.android.wireless.needUSB, in: self.androidPanelView)
                }
                return
            }

            do {
                let ip = try await AppState.shared.androidDeviceProvider.enableWirelessDebugging(serial: serial)
                AppLogger.device.info("[Wireless] 无线调试已开启，IP: \(ip)")
                await MainActor.run {
                    ToastView.info(L10n.android.wireless.enabledMessage(ip, 5555), in: self.androidPanelView)
                }
            } catch {
                await MainActor.run {
                    ToastView.warning(error.localizedDescription, in: self.androidPanelView)
                }
            }
        }
    }

    /// 简单校验 IPv4 格式（无线连接输入用）
    private static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3 else { return false }
            guard part.allSatisfy(\.isNumber) else { return false }
            guard UInt8(part) != nil else { return false }
            return !(part.count > 1 && part.hasPrefix("0"))
        }
    }

    // MARK: - 操作

    private func startIOSCapture() {
        Task {
            do {
                try await AppState.shared.startIOSCapture()
                await MainActor.run {
                    // iOS 只支持画面投屏，没有反向控制通道；首次投屏时提示一次，避免用户找控制条
                    if !self.didShowIOSMirrorOnlyHint {
                        self.didShowIOSMirrorOnlyHint = true
                        ToastView.info(L10n.ios.onlyMirrorHint, in: self.iosPanelView)
                    }
                }
            } catch {
                await MainActor.run {
                    iosPanelView.stopActionLoading()
                }
                showCaptureError(platform: L10n.platform.ios, error: error)
            }
        }
    }

    private func stopIOSCapture() {
        Task {
            await AppState.shared.stopIOSCapture()
            await MainActor.run {
                ToastView.info(L10n.overlayUI.captureStopped(L10n.platform.ios), in: iosPanelView)
            }
        }
    }

    private func refreshIOSDeviceInfo(completion: @escaping () -> Void) {
        // 只刷新当前设备的信息（不刷新设备列表）
        let appState = AppState.shared
        guard let currentDevice = appState.iosDeviceProvider.devices.first else {
            completion()
            return
        }

        Task {
            let insight = DeviceInsightService.shared.refresh(udid: currentDevice.avUniqueID)

            await MainActor.run {
                appState.iosDeviceProvider.updateDevice(currentDevice.enriched(with: insight))
                updateUI()
                ToastView.success(L10n.toolbar.deviceInfoRefreshed, in: iosPanelView)
                completion()
            }
        }
    }

    private func refreshAndroidDeviceInfo(completion: @escaping () -> Void) {
        // 刷新 Android 设备列表
        let appState = AppState.shared

        Task {
            await appState.androidDeviceProvider.refreshDevices()

            await MainActor.run {
                updateUI()
                ToastView.success(L10n.toolbar.deviceInfoRefreshed, in: androidPanelView)
                completion()
            }
        }
    }

    private func startAndroidCapture() {
        Task {
            do {
                try await AppState.shared.startAndroidCapture()
            } catch {
                await MainActor.run {
                    androidPanelView.stopActionLoading()
                }
                showCaptureError(platform: L10n.platform.android, error: error)
            }
        }
    }

    private func stopAndroidCapture() {
        Task {
            await AppState.shared.stopAndroidCapture()
            await MainActor.run {
                DevicePanelView.sweepInactiveControlBars()
                ToastView.info(L10n.overlayUI.captureStopped(L10n.platform.android), in: androidPanelView)
            }
        }
    }

    private func openPreferences() {
        // 打开偏好设置窗口的工具链标签页
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showPreferences(self)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.common.error
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.common.ok)
        alert.runModal()
    }

    // MARK: - 窗口事件

    func handleWindowResize() {
        updateWindowEdgeHighlight()
        updatePanelLayout(animated: false)
    }

    func handleFullScreenChange(isFullScreen: Bool) {
        self.isFullScreen = isFullScreen
        previewContainerView.isFullScreen = isFullScreen

        // 更新背景色
        if isFullScreen {
            // 全屏时使用用户偏好的黑色+透明度
            let bgColor = UserPreferences.shared.backgroundColor.cgColor
            view.layer?.backgroundColor = bgColor
            previewContainerView.layer?.backgroundColor = bgColor
        } else {
            // 非全屏时使用默认背景色
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            previewContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }

        // 更新 titlebar 显示状态（全屏时隐藏 toolbar）
        updateTitlebarVisibility(animated: false)

        // 更新面板布局（禁用动画，让系统全屏动画统一控制）
        updatePanelLayout(animated: false)

        // 全屏切换会改变标题栏/边框显隐与背景拖动策略
        applyWindowChromeVisibility()
        applyWindowMovability()
    }

    /// 捕获分辨率变化（含横竖屏切换）：刷新面板布局
    func handleCaptureResolutionChange() {
        updatePanelLayout()
    }

    // MARK: - Android 输入

    /// 主面板：绑定当前主 Android 设备源
    private func setupAndroidInput(for panel: DevicePanelView) {
        setupAndroidInput(for: panel, source: AppState.shared.androidDeviceSource)
    }

    /// 把面板上的鼠标/键盘事件转发给指定 Android 设备源（主面板与网格面板共用）
    private func setupAndroidInput(for panel: DevicePanelView, source: ScrcpyDeviceSource?) {
        guard let source else {
            panel.setInputEnabled(false)
            panel.setControlActionsVisible(false)
            panel.onInputEvent = nil
            panel.onControlAction = nil
            bindRecordingState(for: panel, deviceID: nil)
            return
        }

        let controller = source.inputController
        panel.setInputEnabled(true)
        panel.setControlActionsVisible(true)
        // 同步每格静音按钮初始状态
        panel.setMuteState(source.isPerDeviceMuted)
        // 同步每格录制按钮初始状态
        bindRecordingState(for: panel, deviceID: source.deviceID)

        panel.onInputEvent = { [weak self, weak controller, weak source] event in
            guard let controller else { return }
            // 设备像素坐标：归一化点 × 视频分辨率
            let size: CGSize = source?.captureSize
                ?? source?.latestPixelBuffer.map {
                    CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
                }
                ?? .zero
            guard size.width > 0, size.height > 0 else {
                AppLogger.capture.info("[输入诊断] captureSize 无效，丢弃事件")
                return
            }
            let devicePoint: (CGPoint) -> CGPoint = {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            }

            switch event {
            case let .pointerDown(point, nsEvent):
                if nsEvent.type == .rightMouseDown {
                    // scrcpy 约定：右键 = 返回
                    controller.sendBack()
                    return
                }
                controller.pointerDown(at: devicePoint(point), size: size, button: .primary)
            case let .pointerMove(point, _):
                controller.pointerMove(to: devicePoint(point), size: size)
            case let .pointerUp(point, nsEvent):
                if nsEvent.type == .rightMouseUp { return } // 右键已在 down 时处理
                controller.pointerUp(at: devicePoint(point), size: size, button: .primary)
            case let .pointerHover(point, _):
                if controller.hoverEnabled {
                    controller.pointerHover(at: devicePoint(point), size: size)
                }
            case .pointerExit:
                controller.resetPointer()
            case let .scroll(dx, dy, point, _):
                // 入参已是行单位，方向与 AXIS_VSCROLL 一致，无需取反
                controller.scroll(dx: dx, dy: dy, at: devicePoint(point), size: size)
            case let .keyDown(nsEvent):
                self?.handleAndroidKeyEvent(nsEvent, controller: controller)
            }
        }

        panel.onControlAction = { [weak self, weak controller, weak panel, weak source] action in
            guard let controller else { return }
            switch action {
            case .recordToggle:
                // 每格录制：只录这一格，不触发全局录制
                guard let self, let panel, let source else { return }
                self.toggleRecording(for: panel, deviceID: source.deviceID)
            case .volumeUp: controller.sendVolumeUp()
            case .volumeDown: controller.sendVolumeDown()
            case .power: controller.sendPower()
            case .rotate: controller.rotateDevice()
            case .home: controller.sendHome()
            case .back: controller.sendBack()
            case .muteToggle:
                // 每格静音：切换本设备播放静音，不影响捕获与全局偏好
                guard let source, let panel else { return }
                let muted = !source.isPerDeviceMuted
                source.setPerDeviceMuted(muted)
                panel.setMuteState(muted)
                AppLogger.capture.info("[音频] 每格静音\(muted ? "开" : "关") 设备=\(source.displayName)")
            }
        }

        // 音频不可用提示（首次投屏时 source 才建立，因此在此绑定）
        source.onAudioUnavailable = { [weak self] in
            DispatchQueue.main.async {
                self?.showAudioUnavailableHint()
            }
        }
    }

    // MARK: - 每格录制

    /// 绑定/解绑某格面板对应的录制状态
    private func bindRecordingState(for panel: DevicePanelView, deviceID: String?) {
        let key = ObjectIdentifier(panel)
        if let deviceID {
            recordingBindings[key] = (panel, deviceID)
            applyRecordingState(to: panel, deviceID: deviceID)
        } else {
            recordingBindings.removeValue(forKey: key)
            panel.setRecordingState(.idle)
        }
    }

    /// 按录制服务当前状态刷新单格控制条录制按钮
    private func applyRecordingState(to panel: DevicePanelView, deviceID: String) {
        let service = AppState.shared.recordingService
        if service.isRecording(deviceID: deviceID) {
            panel.setRecordingState(.recording(elapsedSeconds: service.elapsedSeconds(deviceID: deviceID)))
        } else {
            panel.setRecordingState(.idle)
        }
    }

    /// 刷新所有已绑定面板的录制按钮（录制状态/计时变化时调用）
    private func refreshRecordingIndicators() {
        recordingBindings = recordingBindings.filter { $0.value.panel.superview != nil }
        for binding in recordingBindings.values {
            applyRecordingState(to: binding.panel, deviceID: binding.deviceID)
        }
    }

    /// 切换单台设备的录制：开始录制 / 停止并收尾
    private func toggleRecording(for panel: DevicePanelView, deviceID: String) {
        let service = AppState.shared.recordingService
        if service.isRecording(deviceID: deviceID) {
            Task { @MainActor in
                _ = await service.stopRecording(forDeviceID: deviceID)
                self.refreshRecordingIndicators()
            }
        } else {
            Task { @MainActor in
                do {
                    try await service.startRecording(forDeviceID: deviceID)
                } catch {
                    self.showError(error.localizedDescription)
                }
                self.refreshRecordingIndicators()
            }
        }
    }

    /// Mac 按键 → Android 按键码映射
    private func handleAndroidKeyEvent(_ event: NSEvent, controller: ScrcpyInputController) {
        switch event.keyCode {
        case 53: controller.sendKey(ScrcpyKeyCode.escape)        // Esc
        case 36, 76: controller.sendKey(ScrcpyKeyCode.enter)     // Return / 小键盘回车
        case 51: controller.sendKey(ScrcpyKeyCode.del)           // Delete
        case 48: controller.sendKey(ScrcpyKeyCode.tab)           // Tab
        case 49: controller.sendKey(ScrcpyKeyCode.space)         // Space
        case 126: controller.sendKey(ScrcpyKeyCode.dpadUp)
        case 125: controller.sendKey(ScrcpyKeyCode.dpadDown)
        case 123: controller.sendKey(ScrcpyKeyCode.dpadLeft)
        case 124: controller.sendKey(ScrcpyKeyCode.dpadRight)
        case 115: controller.sendKey(ScrcpyKeyCode.moveHome)
        case 119: controller.sendKey(ScrcpyKeyCode.moveEnd)
        case 116: controller.sendKey(ScrcpyKeyCode.pageUp)
        case 121: controller.sendKey(ScrcpyKeyCode.pageDown)
        default:
            if let characters = event.characters, !characters.isEmpty {
                controller.sendText(characters)
            }
        }
    }

    // MARK: - iOS 面板

    private func updateIOSPanel(_ panel: DevicePanelView) {
        let appState = AppState.shared

        // 应用初始化期间显示加载状态
        if appState.isInitializing {
            panel.showLoading(platform: .ios)
            return
        }

        if appState.iosCapturing, let device = appState.currentIOSDevice {
            // 设置帧回调，每个新帧到来时更新纹理
            appState.iosDeviceSource?.onFrame = { [weak panel] pixelBuffer in
                panel?.renderView.updateTexture(from: pixelBuffer)
            }

            panel.showCapturing(
                device: device,
                fps: panel.renderView.fps,
                resolution: appState.iosDeviceSource?.captureSize ?? .zero,
                onStop: { [weak self] in
                    self?.stopIOSCapture()
                }
            )
        } else if let device = appState.currentIOSDevice {
            // 清除帧回调与输入
            appState.iosDeviceSource?.onFrame = nil
            panel.setInputEnabled(false)
            panel.setControlActionsVisible(false)

            panel.showConnected(
                device: device,
                onStart: { [weak self] in
                    self?.startIOSCapture()
                },
                onRefresh: { [weak self] completion in
                    self?.refreshIOSDeviceInfo(completion: completion)
                }
            )
            panel.renderView.clearTexture()
        } else {
            panel.showDisconnected(platform: .ios)
            panel.setInputEnabled(false)
            panel.setControlActionsVisible(false)
            panel.renderView.clearTexture()
        }
    }

    // MARK: - 面板操作

    /// 交换设备位置（交换网格顺序的前两台）
    func swapPanels() {
        let ids = previewContainerView.currentGridItemIDs()
        guard ids.count >= 2 else { return }
        var order = UserPreferences.shared.gridDeviceOrder
        // 保证顺序表里至少包含当前两台
        for id in ids where !order.contains(id) { order.append(id) }
        guard let firstIndex = order.firstIndex(of: ids[0]),
              let secondIndex = order.firstIndex(of: ids[1]) else { return }
        order.swapAt(firstIndex, secondIndex)
        UserPreferences.shared.gridDeviceOrder = order
        updateGridPanels()
        updatePanelLayout(animated: false)
    }

    // MARK: - 语言变更

    /// 更新本地化文本（语言切换时调用）
    func updateLocalizedTexts() {
        previewContainerView.updateLocalizedTexts()
    }

    // MARK: - 录制回看

    /// 更新录制中标识
    func setRecordingIndicatorVisible(_ visible: Bool, elapsedSeconds: Int) {
        previewContainerView.setRecordingIndicatorVisible(visible, elapsedSeconds: elapsedSeconds)
    }

    /// 显示录制回看页。
    func showRecordingReplay(session: RecordingSession) {
        let replayView = recordingReplayView ?? RecordingReplayView(frame: previewContainerView.frame)
        replayView.onBack = { [weak self] in self?.hideRecordingReplay() }
        replayView.frame = previewContainerView.frame
        replayView.isHidden = false
        previewContainerView.isHidden = true
        if replayView.superview == nil {
            view.addSubview(replayView, positioned: .above, relativeTo: previewContainerView)
        }
        recordingReplayView = replayView
        replayView.configure(session: session)
    }

    /// 隐藏录制回看页并恢复主页预览区。
    func hideRecordingReplay() {
        recordingReplayView?.stopPlayback()
        recordingReplayView?.isHidden = true
        previewContainerView.isHidden = false
    }

    // MARK: - 错误处理

    /// 显示捕获错误，提取根本原因避免重复包装
    /// 如果是 Android 端口占用错误，提供"重置连接"选项
    private func showCaptureError(platform: String, error: Error) {
        let rootCause = extractRootCause(from: error)

        // 检查是否是 Android 端口占用错误，需要提供重置选项
        if platform == L10n.platform.android, isPortInUseError(rootCause) {
            showErrorWithResetOption(
                title: L10n.error.startCaptureFailed(platform, ""),
                message: rootCause
            )
        } else {
            showError(L10n.error.startCaptureFailed(platform, rootCause))
        }
    }

    /// 检查是否是端口占用错误
    private func isPortInUseError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("端口") && lowercased.contains("占用") ||
            lowercased.contains("address already in use") ||
            lowercased.contains("port") && lowercased.contains("in use")
    }

    /// 显示带有"重置连接"选项的错误弹窗
    private func showErrorWithResetOption(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置连接")
        alert.addButton(withTitle: "取消")

        // 使用 sheet 方式显示，避免 runModal() 的优先级反转警告
        guard let window = view.window else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                resetAndroidConnection()
            }
            return
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.resetAndroidConnection()
            }
        }
    }

    /// 重置 Android 连接
    private func resetAndroidConnection() {
        Task {
            await MainActor.run {
                androidPanelView.startActionLoading()
            }

            if let scrcpySource = AppState.shared.androidDeviceSource {
                await scrcpySource.resetConnection()
            }

            await MainActor.run {
                androidPanelView.stopActionLoading()
                ToastView.success("连接已重置，请重新开始投屏", in: androidPanelView)
            }
        }
    }

    /// 提取错误的根本原因，避免多层包装
    private func extractRootCause(from error: Error) -> String {
        if let deviceError = error as? DeviceSourceError {
            switch deviceError {
            case let .captureStartFailed(reason):
                return reason
            default:
                return error.localizedDescription
            }
        }

        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return extractRootCause(from: underlying)
        }

        return error.localizedDescription
    }
}

// MARK: - NSImage 扩展

private extension NSImage {
    /// 将图像着色为指定颜色
    func tinted(with color: NSColor) -> NSImage {
        guard let image = copy() as? NSImage else {
            return self
        }
        image.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
