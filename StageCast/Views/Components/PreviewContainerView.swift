//
//  PreviewContainerView.swift
//  StageCast
//
//  Created by Sun on 2025/12/25.
//
//  预览容器视图
//  统一承载三种呈现方式：自动排列 / 固定网格 / 独立浮窗
//

import AppKit

// MARK: - 布局模式

/// 预览呈现方式
///
/// 旧版本用"双设备并排 / 仅左 / 仅右 / 网格"四种固定槽位模式，
/// 只有一台设备时也会画两个槽，出现"同一画面显示两次"的错觉。
/// 现在统一改为按设备数量决定的三种模式。
enum PreviewLayoutMode: String, CaseIterable {
    /// 自动排列（默认）：1 台单画面、2 台并排、3 台一行三列、4 台 2×2……
    case auto
    /// 固定网格：每页设备数由偏好设置决定，可翻页
    case grid
    /// 独立浮窗：每台设备一个可自由拖动、缩放的窗口
    case floating

    /// 可在菜单/工具栏中选择的模式
    static var selectable: [PreviewLayoutMode] { allCases }

    var displayName: String {
        switch self {
        case .auto: L10n.layout.auto
        case .grid: L10n.layout.grid
        case .floating: L10n.layout.floating
        }
    }

    var iconName: String {
        switch self {
        case .auto: "square.grid.2x2"
        case .grid: "square.grid.3x2"
        case .floating: "macwindow.on.rectangle"
        }
    }

    /// 旧版本持久化的值（无对应新模式的按自动排列处理）
    static func migrated(from raw: String) -> PreviewLayoutMode {
        PreviewLayoutMode(rawValue: raw) ?? .auto
    }
}

// MARK: - 预览容器视图

final class PreviewContainerView: NSView {

    // MARK: - UI 组件

    /// 空态面板：没有任何设备投屏时展示连接引导（Android 版，含无线 IP 输入）
    private(set) var androidPanelView = DevicePanelView()
    /// 空态面板：仅有 iOS 设备可用时展示连接引导
    private(set) var iosPanelView = DevicePanelView()
    /// 网格容器（自动排列 / 固定网格共用；它同时也是多设备面板池）
    private(set) var gridView = DeviceGridView()
    /// 最近一次网格设备列表（切换布局模式后重放）
    private var pendingGridItems: [DeviceGridItem] = []

    /// 录制中状态标识（覆盖在整个投屏区域左上角）
    private let recordingIndicatorView = NSView()
    private let recordingIndicatorDotLayer = CALayer()
    private let recordingIndicatorLabel = NSTextField(labelWithString: "")

    // MARK: - 状态

    /// 当前布局模式
    private(set) var layoutMode: PreviewLayoutMode = UserPreferences.shared.layoutMode

    /// 是否全屏模式
    var isFullScreen: Bool = false {
        didSet {
            if oldValue != isFullScreen {
                updateLayout(animated: false)
            }
        }
    }

    /// 浮窗模式下容器内不承载画面
    var isFloatingPresentationActive: Bool = false {
        didSet {
            if oldValue != isFloatingPresentationActive {
                updateLayout(animated: false)
            }
        }
    }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - UI 设置

    private func setupUI() {
        wantsLayer = true
        addSubview(iosPanelView)
        addSubview(androidPanelView)
        gridView.isHidden = true
        addSubview(gridView)
        setupRecordingIndicator()
        updateLayout(animated: false)
    }

    // MARK: - 公开方法

    /// 设置布局模式
    func setLayoutMode(_ mode: PreviewLayoutMode, animated: Bool = true) {
        guard layoutMode != mode else { return }
        layoutMode = mode
        updateLayout(animated: animated)
    }

    /// 更新网格设备列表
    func updateGrid(items: [DeviceGridItem]) {
        pendingGridItems = items
        updateLayout(animated: false)
    }

    /// 当前网格内的设备顺序（用于交换位置）
    func currentGridItemIDs() -> [String] {
        pendingGridItems.map(\.id)
    }

    /// 显示引导面板用的面板引用（Android 优先，因为无线连接入口在这里）
    var emptyStatePanel: DevicePanelView {
        let appState = AppState.shared
        let hasAndroid = !appState.androidDeviceProvider.devices.isEmpty
        let hasIOS = appState.iosDeviceSource != nil || appState.currentIOSDevice != nil
        if hasIOS && !hasAndroid {
            return iosPanelView
        }
        return androidPanelView
    }

    /// 更新布局
    func updateLayout(animated: Bool = true) {
        let hasItems = !pendingGridItems.isEmpty
        let usesGrid = (layoutMode == .auto || layoutMode == .grid) && hasItems
        let usesFloating = layoutMode == .floating || isFloatingPresentationActive

        // 1. 网格/自动排列：网格容器铺满，内嵌面板全部让位
        if usesGrid {
            gridView.isHidden = false
            gridView.usesAutoGrid = (layoutMode == .auto)
            gridView.frame = bounds
            gridView.update(items: pendingGridItems)
            iosPanelView.isHidden = true
            androidPanelView.isHidden = true
            layoutRecordingIndicator()
            return
        }

        gridView.isHidden = true

        // 2. 浮窗模式：画面在各自窗口里，容器内只剩背景
        if usesFloating {
            // 没有任何投屏时不显示空白窗口，回落到引导面板（连接/扫描入口在这里）
            if !hasItems {
                layoutEmptyStatePanel()
                layoutRecordingIndicator()
                return
            }
            iosPanelView.isHidden = true
            androidPanelView.isHidden = true
            layoutRecordingIndicator()
            return
        }

        // 3. 空态：只显示一个引导面板，铺满容器并按画面比例居中
        layoutEmptyStatePanel()
        layoutRecordingIndicator()
    }

    /// 空态面板布局
    private func layoutEmptyStatePanel() {
        let panel = emptyStatePanel
        iosPanelView.isHidden = (panel !== iosPanelView)
        androidPanelView.isHidden = (panel !== androidPanelView)
        panel.frame = panelFrame(for: panel, in: bounds)
    }

    /// 更新 bezel 可见性
    func updateBezelVisibility() {
        let showBezel = UserPreferences.shared.showDeviceBezel
        iosPanelView.setBezelVisible(showBezel)
        androidPanelView.setBezelVisible(showBezel)
        gridView.panelsByID.values.forEach { $0.setBezelVisible(showBezel) }
        updateLayout(animated: false)
    }

    /// 更新本地化文本
    func updateLocalizedTexts() {
        iosPanelView.updateLocalizedTexts()
        androidPanelView.updateLocalizedTexts()
    }

    /// 更新录制状态标识。
    /// - Parameters:
    ///   - visible: 是否显示录制中标识
    ///   - elapsedSeconds: 当前录制经过秒数
    func setRecordingIndicatorVisible(_ visible: Bool, elapsedSeconds: Int) {
        recordingIndicatorView.isHidden = !visible
        guard visible else {
            recordingIndicatorDotLayer.removeAnimation(forKey: "recordingPulse")
            return
        }

        recordingIndicatorLabel.stringValue = L10n.recording.recordingWithElapsed(formatElapsedTime(elapsedSeconds))
        startRecordingPulseAnimationIfNeeded()
        layoutRecordingIndicator()
    }

    // MARK: - 面板几何

    /// 计算面板在指定区域内居中的 frame
    private func panelFrame(for panel: DevicePanelView, in areaRect: CGRect) -> CGRect {
        let vPadding: CGFloat = isFullScreen ? 0 : 24
        let showBezel = UserPreferences.shared.showDeviceBezel
        let shouldFillHeight = isFullScreen && !showBezel
        let availableHeight = shouldFillHeight ? areaRect.height : (areaRect.height - vPadding * 2)

        let aspectRatio = max(panel.deviceAspectRatio, 0.2)
        let panelHeight = max(availableHeight, 1)
        let panelWidth = panelHeight * aspectRatio

        var finalWidth = min(panelWidth, areaRect.width)
        var finalHeight = finalWidth / aspectRatio

        // 空态引导内容（图标 + 标题 + 状态行 + 副标题 + 刷新）最小需要约 320×430。
        // 按设备比例算出来的窄框（竖屏 0.46）会把内容裁掉，这里做最小尺寸兜底；
        // 放不下时直接铺满可用区域，宁可边框留白也不要截断文字。
        let minContentWidth: CGFloat = 320
        let minContentHeight: CGFloat = 430
        if finalWidth < minContentWidth || finalHeight < minContentHeight {
            finalWidth = max(finalWidth, min(minContentWidth, areaRect.width))
            finalHeight = max(finalHeight, min(minContentHeight, areaRect.height))
            // 兜底后仍超出可用区域时按可用区域裁到最大
            finalWidth = min(finalWidth, areaRect.width)
            finalHeight = min(finalHeight, areaRect.height)
        }

        let x = areaRect.origin.x + (areaRect.width - finalWidth) / 2
        let y = areaRect.origin.y + (areaRect.height - finalHeight) / 2
        return CGRect(x: x, y: y, width: finalWidth, height: finalHeight)
    }

    // MARK: - 录制标识

    private func setupRecordingIndicator() {
        recordingIndicatorView.wantsLayer = true
        recordingIndicatorView.layer?.cornerRadius = 8
        recordingIndicatorView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        recordingIndicatorView.layer?.shadowColor = NSColor.black.cgColor
        recordingIndicatorView.layer?.shadowOpacity = 0.18
        recordingIndicatorView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        recordingIndicatorView.layer?.shadowRadius = 8
        recordingIndicatorView.isHidden = true

        recordingIndicatorDotLayer.backgroundColor = NSColor.systemRed.cgColor
        recordingIndicatorDotLayer.cornerRadius = 4
        recordingIndicatorView.layer?.addSublayer(recordingIndicatorDotLayer)

        recordingIndicatorLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        recordingIndicatorLabel.textColor = .white
        recordingIndicatorLabel.alignment = .left
        recordingIndicatorLabel.lineBreakMode = .byTruncatingTail
        recordingIndicatorLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        recordingIndicatorView.addSubview(recordingIndicatorLabel)

        addSubview(recordingIndicatorView)
    }

    private func layoutRecordingIndicator() {
        guard !recordingIndicatorView.isHidden else { return }

        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 7
        let dotSize: CGFloat = 8
        let spacing: CGFloat = 8
        let labelSize = recordingIndicatorLabelSize()
        let width = min(
            bounds.width - 24,
            horizontalPadding * 2 + dotSize + spacing + labelSize.width
        )
        let height = max(28, verticalPadding * 2 + labelSize.height)
        let labelWidth = max(0, width - horizontalPadding * 2 - dotSize - spacing)

        recordingIndicatorView.frame = CGRect(
            x: 12,
            y: bounds.height - height - 12,
            width: width,
            height: height
        )

        recordingIndicatorDotLayer.frame = CGRect(
            x: horizontalPadding,
            y: (height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        recordingIndicatorLabel.frame = CGRect(
            x: horizontalPadding + dotSize + spacing,
            y: (height - labelSize.height) / 2,
            width: labelWidth,
            height: labelSize.height
        )
    }

    private func recordingIndicatorLabelSize() -> CGSize {
        let font = recordingIndicatorLabel.font ?? NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (recordingIndicatorLabel.stringValue as NSString).size(withAttributes: attributes)
        // `NSTextField.intrinsicContentSize` 在频繁更新时间文本时偶尔会偏紧，手动测量并给少量冗余。
        return CGSize(width: ceil(textSize.width) + 8, height: ceil(textSize.height))
    }

    private func startRecordingPulseAnimationIfNeeded() {
        guard recordingIndicatorDotLayer.animation(forKey: "recordingPulse") == nil else { return }

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.95
        opacity.toValue = 0.45

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.18

        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = 1.4
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        recordingIndicatorDotLayer.add(group, forKey: "recordingPulse")
    }

    private func formatElapsedTime(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainingSeconds = clamped % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    // MARK: - 布局回调

    override func layout() {
        super.layout()
        if !gridView.isHidden {
            gridView.frame = bounds
        } else if layoutMode == .floating || isFloatingPresentationActive {
            // 浮窗模式容器内无内容
        } else {
            layoutEmptyStatePanel()
        }
        layoutRecordingIndicator()
    }

    /// 容器背景允许拖动窗口（画面区域由 SingleDeviceRenderView 自行拦截）
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
    }
}

// MARK: - 独立浮窗呈现

/// 独立浮窗模式：每台投屏设备一个独立窗口，各自带控制条，
/// 可以单独拖动、缩放、关闭。
@MainActor
final class DeviceFloatingWindowManager: NSObject, NSWindowDelegate {
    /// 新建面板的接线回调（复用网格的接线逻辑）
    var onPanelAssigned: ((DevicePanelView, DeviceGridItem) -> Void)?
    /// 回收面板的解绑回调
    var onPanelReleased: ((DevicePanelView) -> Void)?
    /// 用户主动关闭浮窗的回调（参数为设备 ID），用于停止该设备的投屏
    var onWindowClosed: ((String) -> Void)?
    /// 掉线浮窗上点「重新连接」的回调（参数为设备 ID）
    var onReconnectRequest: ((String) -> Void)?
    /// 正在由代码关闭窗口（模式切换/设备下线），此时不触发 onWindowClosed
    private var isProgrammaticClose = false

    private var windows: [String: NSWindow] = [:]
    private var panels: [String: DevicePanelView] = [:]
    private var chromeViews: [String: FloatingWindowChromeView] = [:]
    private var aspects: [String: CGFloat] = [:]
    /// 掉线但仍保留窗口的设备（窗口不关，盖一层「已断开」提示）
    private var disconnectedIDs: Set<String> = []
    private var overlays: [String: FloatingDisconnectedOverlay] = [:]
    private var cascadeIndex = 0
    /// 窗口移动/缩放结束后的落定任务（吸附 + 位置记忆），按设备 ID 去抖
    private var settleWorkItems: [String: DispatchWorkItem] = [:]
    /// 基准浮窗高度：100% 尺寸，50%/75% 按此比例缩放
    private static let baseWindowHeight: CGFloat = 620

    var isActive: Bool { !windows.isEmpty }

    /// 按当前设备列表同步浮窗：新设备开窗、消失的设备关窗
    /// - Parameters:
    ///   - items: 正在投屏的设备
    ///   - anchor: 主窗口屏幕frame（新窗口从主窗口中部起排布）
    func sync(items: [DeviceGridItem], anchor: NSRect?, aliveIDs: Set<String> = []) {
        let ids = Set(items.map(\.id))
        for id in Array(windows.keys) where !ids.contains(id) {
            guard !disconnectedIDs.contains(id) else { continue }
            // 区分两种「不在投屏列表」：
            // 1) 用户主动停止投屏 → 设备源已销毁（不在 aliveIDs），关窗
            // 2) 设备掉线 → 设备源仍在（状态 error），保留窗口并盖「已断开」覆盖层供重连
            if aliveIDs.contains(id) {
                markDisconnected(id: id)
            } else {
                close(id: id)
            }
        }
        for item in items {
            if windows[item.id] == nil {
                open(item: item, anchor: anchor)
            } else if disconnectedIDs.contains(item.id) {
                markReconnected(id: item.id, item: item)
            }
        }
    }

    /// 设备掉线：保留窗口，显示「已断开」覆盖层
    private func markDisconnected(id: String) {
        guard let panel = panels[id] else { return }
        disconnectedIDs.insert(id)
        // 面板已不在 capturing 状态，控制条子窗口要收掉
        panel.teardownChildWindows()
        overlays[id]?.removeFromSuperview()
        // 覆盖层只盖住屏幕区域：浮窗带边框时不能把金属边框也涂黑
        let overlay = FloatingDisconnectedOverlay(frame: panel.screenFrame)
        overlay.onReconnect = { [weak self] in self?.onReconnectRequest?(id) }
        overlay.onClose = { [weak self] in
            guard let window = self?.windows[id] else { return }
            window.performClose(nil)
        }
        panel.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlays[id] = overlay
    }

    /// 设备重新上线：撤掉覆盖层并重新接线（stopCapture 时帧观察者已被注销）
    private func markReconnected(id: String, item: DeviceGridItem) {
        disconnectedIDs.remove(id)
        overlays[id]?.removeFromSuperview()
        overlays.removeValue(forKey: id)
        guard let panel = panels[id] else { return }
        // 恢复成用户偏好里的边框设置：浮窗默认带整机边框
        panel.setBezelVisible(UserPreferences.shared.showDeviceBezel)
        onPanelAssigned?(panel, item)
        panel.renderView.startRendering()
    }

    /// 关闭全部浮窗
    func dismissAll() {
        for id in Array(windows.keys) {
            close(id: id)
        }
    }

    /// 某台设备的浮窗
    func window(for id: String) -> NSWindow? { windows[id] }

    /// 首帧到达后用真实视频比例校正浮窗宽高比
    /// 保持高度不变、只改宽度，避免画面在用户眼前突然变高变矮
    func updateAspect(for id: String, aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0.05, aspect < 20 else { return }
        guard let window = windows[id] else { return }
        if let current = aspects[id], abs(current - aspect) < 0.001 { return }
        aspects[id] = aspect
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        let height = window.frame.height
        let width = max(160, (height * aspect).rounded())
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    /// 首帧之前的兜底比例：设备源已上报分辨率时直接用，否则按竖屏 9:19.5 估算
    private func initialAspect(for item: DeviceGridItem) -> CGFloat {
        if let size = captureSize(for: item), size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return 9.0 / 19.5
    }

    private func captureSize(for item: DeviceGridItem) -> CGSize? {
        switch item.platform {
        case .android:
            return AppState.shared.androidSources[item.id]?.captureSize
        case .ios:
            return AppState.shared.iosSources[item.id]?.captureSize
        }
    }

    private func open(item: DeviceGridItem, anchor: NSRect?) {
        let panel = DevicePanelView()
        panel.translatesAutoresizingMaskIntoConstraints = true
        panel.autoresizingMask = [.width, .height]
        // 浮窗保留整机仿真边框（用户偏好可关）：窗口按整机比例放大，
        // renderView 仍严格铺满屏幕区，所以边框外不会出现 letterbox 黑边
        panel.setBezelVisible(UserPreferences.shared.showDeviceBezel)

        let aspect = initialAspect(for: item)
        let height = Self.baseWindowHeight
        var size = NSSize(width: max(160, (height * aspect).rounded()), height: height)

        // 从主窗口中部起逐个错开，避免多窗完全重叠
        let base = anchor ?? NSScreen.main?.visibleFrame ?? NSRect(x: 120, y: 120, width: 900, height: 700)
        let offset = CGFloat(min(cascadeIndex, 5)) * 24
        cascadeIndex += 1
        var origin = NSPoint(x: base.midX - size.width / 2 + offset,
                             y: base.midY - size.height / 2 - offset)
        if let screen = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 20), screen.maxX - size.width - 20)
            origin.y = min(max(origin.y, screen.minY + 20), screen.maxY - size.height - 20)
        }

        // 位置记忆优先：拖到哪儿下次就回到哪儿（宽度按当前比例重算，兼容旋转）
        if let saved = UserPreferences.shared.floatingWindowFrame(for: item.id),
           saved.width >= 120, saved.height >= 120,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            size = NSSize(width: max(160, (saved.height * aspect).rounded()), height: saved.height)
            origin = saved.origin
        }

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 透明窗口：设备边框的圆角外应直接透出桌面，而不是套一层黑底
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 120, height: 240)
        // 锁定内容宽高比 = 整机宽高比：用户拖动缩放时也只会等比放大，
        // 不会因为窗口比例变化而重新出现黑边
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        // 关键：NSWindow 默认 isReleasedWhenClosed = true，close() 会多发一次 release，
        // 而这里 Swift 字典还持有强引用 → 双重释放，表现为关闭浮窗时
        // objc_release 崩溃（zombie 日志：-[NSKVONotifying_NSWindow release]:
        // message sent to deallocated instance）
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.title = "StageCast"
        window.delegate = self
        window.contentView = panel
        panel.frame = NSRect(origin: .zero, size: size)
        // 标题栏三个按钮全部隐藏：浮窗里只有画面，关闭改用悬停时出现的自绘按钮
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        let chrome = FloatingWindowChromeView(frame: NSRect(origin: .zero, size: size))
        chrome.autoresizingMask = [.width, .height]
        chrome.onClose = { [weak window] in window?.performClose(nil) }
        chrome.onRecenter = { [weak self] in self?.recenter(id: item.id) }
        chrome.onSetHeightPercent = { [weak self] percent in self?.setHeightPercent(percent, for: item.id) }
        chrome.onToggleAlwaysOnTop = { [weak self] in self?.toggleAlwaysOnTop(id: item.id) }
        chrome.isAlwaysOnTop = { [weak self] in self?.windows[item.id]?.level == .floating }
        panel.addSubview(chrome)
        chromeViews[item.id] = chrome
        // 允许拖动画面外的边框移动窗口（画面内仍由 ⌥ 拖动）
        panel.allowsWindowBackgroundDrag = true
        // 浮窗右侧就是桌面，按钮条直接贴整机右缘即可，不必为避让邻居翻到左边
        panel.allowsControlBarOutsideWindow = true
        window.makeKeyAndOrderFront(nil)

        windows[item.id] = window
        panels[item.id] = panel
        aspects[item.id] = aspect
        onPanelAssigned?(panel, item)
        // 面板接线后机型已确定，按整机比例（含边框）校正窗口宽度
        let deviceAspect = panel.deviceAspectRatio
        if deviceAspect.isFinite, deviceAspect > 0.05 {
            updateAspect(for: item.id, aspect: deviceAspect)
        }
        // 独立窗口没有网格那样的可见性驱动，需要自己启动渲染循环
        panel.renderView.startRendering()
    }

    // MARK: - 窗口操作

    /// 回到当前屏幕中央
    private func recenter(id: String) {
        guard let window = windows[id] else { return }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                      y: visible.midY - window.frame.height / 2))
        scheduleSettle(id: id)
    }

    /// 按基准高度的百分比缩放浮窗（右键菜单 50%/75%/100%）
    private func setHeightPercent(_ percent: Int, for id: String) {
        guard percent > 0, let window = windows[id], let aspect = aspects[id] else { return }
        let height = max(240, (Self.baseWindowHeight * CGFloat(percent) / 100).rounded())
        let width = max(140, (height * aspect).rounded())
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        frame.origin = NSPoint(x: center.x - width / 2, y: center.y - height / 2)
        // 不用 animate：缩放过程中若 frame 出现非有限值，CA 重放动画时会崩溃。
        // 缩放后主动把顶部抓手/关闭钮显示出来，否则缩到 50% 后
        // 抓手要等鼠标重新进入窗口才可见，用户找不到拖动区域。
        window.setFrame(frame, display: true, animate: false)
        chromeViews[id]?.flashControls()
        scheduleSettle(id: id)
    }

    /// 置顶 / 取消置顶
    private func toggleAlwaysOnTop(id: String) {
        guard let window = windows[id] else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    // MARK: - 位置记忆与边缘吸附

    /// 拖动/缩放结束后 0.18s 再落定：吸附屏幕边缘并写入位置记忆
    private func scheduleSettle(id: String) {
        settleWorkItems[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.windows[id] else { return }
            self.snapToScreenEdges(window)
            UserPreferences.shared.setFloatingWindowFrame(window.frame, for: id)
            self.settleWorkItems.removeValue(forKey: id)
        }
        settleWorkItems[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// 距屏幕可用区边缘 12pt 以内时吸附，方便摆成一排
    private func snapToScreenEdges(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        let threshold: CGFloat = 12
        if abs(frame.minX - visible.minX) < threshold { frame.origin.x = visible.minX }
        if abs(frame.maxX - visible.maxX) < threshold { frame.origin.x = visible.maxX - frame.width }
        if abs(frame.minY - visible.minY) < threshold { frame.origin.y = visible.minY }
        if abs(frame.maxY - visible.maxY) < threshold { frame.origin.y = visible.maxY - frame.height }
        if !NSEqualRects(frame, window.frame) {
            window.setFrame(frame, display: true)
        }
    }

    private func settleIfNeeded(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        scheduleSettle(id: id)
    }

    private func close(id: String) {
        settleWorkItems[id]?.cancel()
        settleWorkItems.removeValue(forKey: id)
        guard let window = windows[id] else { return }
        isProgrammaticClose = true
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        windows.removeValue(forKey: id)
        releasePanel(id: id)
        isProgrammaticClose = false
    }

    private func releasePanel(id: String) {
        settleWorkItems[id]?.cancel()
        settleWorkItems.removeValue(forKey: id)
        chromeViews.removeValue(forKey: id)
        aspects.removeValue(forKey: id)
        disconnectedIDs.remove(id)
        overlays.removeValue(forKey: id)?.removeFromSuperview()
        guard let panel = panels.removeValue(forKey: id) else { return }
        panel.renderView.stopRendering()
        onPanelReleased?(panel)
    }

    func windowDidMove(_ notification: Notification) {
        settleIfNeeded(notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        settleIfNeeded(notification)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        // 掉线覆盖层只盖屏幕区，窗口缩放后要跟着屏幕区走
        if disconnectedIDs.contains(id), let panel = panels[id], let overlay = overlays[id] {
            overlay.frame = panel.screenFrame
        }
        scheduleSettle(id: id)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isProgrammaticClose else { return }
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: id)
        releasePanel(id: id)
        // 用户关闭浮窗 = 停止这台设备的投屏
        onWindowClosed?(id)
    }
}

// MARK: - 浮窗悬停控件

/// 浮窗的悬停控件层：平时完全透明，鼠标进入画面后左上角浮出关闭按钮。
/// 空白区域的命中测试一律穿透，保证画面点击/拖动仍然落到设备面板上。
final class FloatingWindowChromeView: NSView {
    var onClose: (() -> Void)?
    var onRecenter: (() -> Void)?
    var onSetHeightPercent: ((Int) -> Void)?
    var onToggleAlwaysOnTop: (() -> Void)?
    var isAlwaysOnTop: (() -> Bool)?

    private let closeButton: NSButton = {
        let button = FloatingCloseButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.common.close)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = 11
        button.alphaValue = 0
        button.isHidden = true
        return button
    }()

    private let grip = FloatingGripView()
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        grip.onDoubleClick = { [weak self] in self?.onRecenter?() }
        // 抓手始终参与命中测试（只是透明）：顶部整条都是拖动/双击区，
        // 否则鼠标还没移进来时双击顶部会落到系统标题栏，触发 macOS 自带的缩放，
        // 窗口会突然变大并跑到别的屏幕。
        grip.alphaValue = 0
        addSubview(grip)
        addSubview(closeButton)
        closeButton.target = self
        closeButton.action = #selector(handleClose)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 22
        // 关闭按钮放右上角：左上角留给拖动抓手与标题栏习惯
        closeButton.frame = NSRect(x: bounds.width - side - 10,
                                   y: bounds.height - side - 10,
                                   width: side,
                                   height: side)
        // 命中区覆盖整个顶部条：拖动更容易，也不会漏到系统标题栏
        grip.frame = NSRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        setControlsVisible(false)
    }

    /// 只有关闭按钮接收事件，其余区域一律穿透
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// 主动把控件显示一小段时间再淡出
    /// 用于窗口刚创建、缩放完成等「鼠标没动但用户需要看到控件」的时机
    func flashControls() {
        setControlsVisible(true)
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(fadeOutAfterFlash),
            object: nil
        )
        perform(#selector(fadeOutAfterFlash), with: nil, afterDelay: 1.6)
    }

    @objc private func fadeOutAfterFlash() {
        // 鼠标还在窗口内就不收，交给 mouseExited
        guard let window = window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard !bounds.contains(location) else { return }
        setControlsVisible(false)
    }

    private func setControlsVisible(_ visible: Bool) {
        if visible {
            closeButton.isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            closeButton.animator().alphaValue = visible ? 1 : 0
            // 抓手只淡出、不隐藏：始终保持顶部拖动区的命中能力
            grip.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !visible else { return }
            self.closeButton.isHidden = true
        }
    }

    // MARK: - 右键菜单

    /// 抓手右键菜单：置顶、缩放比例、回中、关闭
    func presentContextMenu(with event: NSEvent) {
        let menu = NSMenu()

        let top = NSMenuItem(title: L10n.floating.alwaysOnTop,
                             action: #selector(handleToggleAlwaysOnTop),
                             keyEquivalent: "")
        top.target = self
        top.state = (isAlwaysOnTop?() ?? false) ? .on : .off
        menu.addItem(top)
        menu.addItem(.separator())

        for percent in [50, 75, 100] {
            let item = NSMenuItem(title: L10n.floating.zoomPercent(percent),
                                  action: #selector(handleHeightPercent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = percent
            if percent == 100 {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let recenter = NSMenuItem(title: L10n.floating.recenter,
                                  action: #selector(handleRecenter),
                                  keyEquivalent: "")
        recenter.target = self
        menu.addItem(recenter)

        let close = NSMenuItem(title: L10n.common.close,
                               action: #selector(handleClose),
                               keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func handleToggleAlwaysOnTop() {
        onToggleAlwaysOnTop?()
    }

    @objc private func handleHeightPercent(_ sender: NSMenuItem) {
        onSetHeightPercent?(sender.tag)
    }

    @objc private func handleRecenter() {
        onRecenter?()
    }

    @objc private func handleClose() {
        onClose?()
    }
}

/// 浮窗顶部拖动抓手：悬停时出现，按住可拖动窗口，双击回到屏幕中央
final class FloatingGripView: NSView {
    var onDoubleClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barWidth: CGFloat = 44
        let barHeight: CGFloat = 5
        let rect = NSRect(x: (bounds.width - barWidth) / 2,
                          y: (bounds.height - barHeight) / 2,
                          width: barWidth,
                          height: barHeight)
        NSColor(white: 1, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: barHeight / 2,
                     yRadius: barHeight / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func rightMouseDown(with event: NSEvent) {
        (superview as? FloatingWindowChromeView)?.presentContextMenu(with: event)
    }
}

/// 浮窗常处于非激活状态，首次点击也要直接触发关闭
private final class FloatingCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 掉线提示层

/// 设备掉线后盖在浮窗上的提示层：保留窗口位置与尺寸，提供「重新连接」。
/// 掉线不是用户本意，直接关窗会让人以为 App 崩了。
final class FloatingDisconnectedOverlay: NSView {
    // MARK: - 回调

    var onReconnect: (() -> Void)?
    var onClose: (() -> Void)?

    // MARK: - 子视图

    private let card = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: L10n.floating.disconnected)
    private let hintLabel = NSTextField(labelWithString: L10n.floating.disconnectedHint)
    private let reconnectButton = FloatingOverlayButton(title: L10n.floating.reconnect, isPrimary: true)
    private let closeButton = FloatingOverlayButton(title: L10n.common.close, isPrimary: false)

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.96).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        iconView.image = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.cell?.usesSingleLineMode = true

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.cell?.usesSingleLineMode = true

        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        addSubview(card)
        card.addSubview(iconView)
        card.addSubview(titleLabel)
        card.addSubview(hintLabel)
        card.addSubview(reconnectButton)
        card.addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let width = min(max(bounds.width - 24, 190), 320)
        let cardHeight: CGFloat = 168
        let cardX = ((bounds.width - width) / 2).rounded()
        let cardY = ((bounds.height - cardHeight) / 2).rounded()
        card.frame = CGRect(x: cardX, y: cardY, width: width, height: cardHeight)

        let inset: CGFloat = 14
        let innerWidth = width - inset * 2
        iconView.frame = CGRect(x: (width - 28) / 2, y: cardHeight - 40, width: 28, height: 28)
        titleLabel.frame = CGRect(x: inset, y: cardHeight - 68, width: innerWidth, height: 20)
        hintLabel.frame = CGRect(x: inset, y: cardHeight - 88, width: innerWidth, height: 16)
        let buttonWidth = ((innerWidth - 10) / 2).rounded()
        reconnectButton.frame = CGRect(x: inset, y: 16, width: buttonWidth, height: 32)
        closeButton.frame = CGRect(x: inset + buttonWidth + 10, y: 16, width: buttonWidth, height: 32)
    }

    // MARK: - 动作

    @objc private func reconnectTapped() {
        onReconnect?()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

/// 浮窗断线覆盖层按钮：单色圆角底 + 白字，避免默认 bezel 在深色蒙层上不可读
final class FloatingOverlayButton: NSButton {
    // MARK: - 属性

    private let isPrimary: Bool
    private var isHovering = false

    // MARK: - 初始化

    init(title: String, isPrimary: Bool) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        focusRingType = .none
        let color: NSColor = isPrimary ? .controlAccentColor : NSColor(calibratedWhite: 0.26, alpha: 1)
        layer?.backgroundColor = color.cgColor

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .paragraphStyle: style
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 交互

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    private func updateBackground() {
        let base: NSColor = isPrimary ? .controlAccentColor : NSColor(calibratedWhite: 0.26, alpha: 1)
        layer?.backgroundColor = base.withAlphaComponent(isHovering ? 1.0 : 0.92).cgColor
    }
}

