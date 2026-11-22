//
//  DevicePickerView.swift
//  StageCast
//
//  Created by Sun on 2026/11/19.
//
//  设备选择器浮层
//  列出局域网内可用的 iPhone / Android 设备（有线与无线），支持按设备开始/停止投屏。
//  视觉语言与现有 HUD 浮层一致：深色半透明卡片 + 圆角 + SF Symbols。
//

import AppKit
import Combine

// MARK: - 设备选择浮层控制器

/// 设备选择浮层控制器
/// 无标题栏浮窗，点击面板外不自动隐藏（需要与列表交互）
@MainActor
final class DevicePickerPanelController {
    /// 浮层面板
    private let panel: NSPanel
    /// 内容视图（外部需要接线无线连接区，故不再 private）
    let pickerView: DevicePickerView
    /// 外部点击 / Esc 监听器（show 时安装，hide 时移除）
    private var eventMonitors: [Any] = []
    /// 宿主窗口：内容高度变化时按它重新定位
    private weak var hostWindow: NSWindow?

    /// 无线连接区（手动 IP / 开启无线调试 / 配对码 / 诊断）
    var wirelessSection: DeviceWirelessPanelView { pickerView.wirelessSection }

    /// 行内投屏成功后的自动收起回调（由 controller 设置，统一走 hide 清理监听器）
    var isVisible: Bool { panel.isVisible }

    init() {
        pickerView = DevicePickerView()
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: pickerView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 与控制条不同：选择器需要保持可见以便连续操作
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = pickerView
        // 行内投屏成功后的自动收起也走统一 hide，保证监听器被清理
        pickerView.onCloseRequest = { [weak self] in self?.hide() }
        // 切换过滤器会增减内容高度（无线 tab 多出连接区），面板需跟着改尺寸
        pickerView.onContentHeightChanged = { [weak self] in
            guard let self, let window = self.hostWindow else { return }
            self.updateFrame(for: window)
        }
    }

    /// 在指定窗口附近显示（贴主窗口左上角）
    func show(relativeTo window: NSWindow?) {
        guard let window else { return }
        hostWindow = window
        pickerView.refreshRows()
        updateFrame(for: window)
        if panel.parent !== window {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        installEventMonitors()
    }

    func hide() {
        removeEventMonitors()
        panel.orderOut(nil)
    }

    func toggle(relativeTo window: NSWindow?) {
        if panel.isVisible {
            hide()
        } else {
            show(relativeTo: window)
        }
    }

    // MARK: 显隐监听

    /// 点击浮层外或按 Esc 时关闭；扫描任务不受影响（后台继续）
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        // NSEvent.mouseLocation 与 convertToScreen 结果均为 Cocoa 屏幕坐标（左下原点），可直接与 panel.frame 比较
        let isOutsidePanel = { [weak self] (location: NSPoint) -> Bool in
            guard let self, self.panel.isVisible else { return false }
            return !self.panel.frame.contains(location)
        }

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return }
            if isOutsidePanel(NSEvent.mouseLocation) { self.hide() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isVisible,
                  let win = event.window, win !== self.panel else { return event }
            // 本地事件来自本 app 其他窗口（主窗等）：事件位置换算为屏幕坐标后在面板外 → 关闭
            let screenPoint = win.convertToScreen(
                NSRect(origin: event.locationInWindow, size: .zero)
            ).origin
            if isOutsidePanel(screenPoint) {
                self.hide()
            }
            return event
        }
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 { // Esc
                self.hide()
                return nil
            }
            return event
        }
        eventMonitors = [global, local, key].compactMap { $0 }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }

    deinit {
        // 监听器必须在主线程移除；正常路径由 hide() 清理，这里兜底
        if !eventMonitors.isEmpty {
            DispatchQueue.main.async { [monitors = eventMonitors] in
                monitors.forEach { NSEvent.removeMonitor($0) }
            }
        }
    }

    /// 依据内容高度更新面板 frame，贴窗口左上角并整体左对齐
    private func updateFrame(for window: NSWindow) {
        let size = pickerView.fittingSize
        let winFrame = window.frame
        // 用户要求「整体靠左并对齐」：面板左缘与主窗左缘保持 16pt 间距，不再贴右上角
        let x = winFrame.minX + 16
        let y = winFrame.maxY - size.height - 8
        panel.setFrame(
            NSRect(
                origin: NSPoint(
                    x: max(window.screen?.visibleFrame.minX ?? 0, x),
                    y: max(window.screen?.visibleFrame.minY ?? 0, y)
                ),
                size: size
            ),
            display: true
        )
    }
}

// MARK: - 设备选择视图

/// 设备选择视图
/// 列出全部有线/无线设备，支持按设备开始与停止投屏
final class DevicePickerView: NSView {
    // MARK: 视觉常量（与 DeviceStatusView 的深色浮层一致）

    private enum Colors {
        static let card = NSColor.black.withAlphaComponent(0.72)
        static let title = NSColor.white
        static let titleSecondary = NSColor(white: 0.6, alpha: 1.0)
        static let sub = NSColor(white: 0.55, alpha: 1.0)
        static let dotOn = NSColor.systemGreen
        static let dotOff = NSColor(white: 0.35, alpha: 1.0)
        static let accent = NSColor.appAccent
    }

    private enum Metrics {
        static let width: CGFloat = 372
        static let rowHeight: CGFloat = 64
        static let maxListHeight: CGFloat = 360
    }

    // MARK: 状态

    /// 过滤分组
    private enum Filter: Int, CaseIterable {
        case all
        case wired
        case wireless
    }

    private var filter: Filter = .all
    private var cancellables = Set<AnyCancellable>()
    /// 行容器（由 refreshRows 重建）
    private var rowViews: [NSView] = []

    /// 内容高度变化回调（切换过滤器时无线连接区显隐，面板需要跟着改尺寸）
    var onContentHeightChanged: (() -> Void)?

    // MARK: 子视图

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let rowsContainer = NSView()
    private let listScroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var filterButtons: [FilterChipButton] = []
    private let scanButton = NSButton()
    private let stopAllButton = NSButton()
    /// 无线 tab 下的手动连接区（IP / 开启无线调试 / 配对码 / 诊断）
    let wirelessSection = DeviceWirelessPanelView()

    /// 请求关闭浮层（由外部 controller 提供，投屏成功/点 X 时调用）
    var onCloseRequest: (() -> Void)?

    // MARK: 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        observeState()
        refreshRows()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    /// 内容自适应尺寸
    override var fittingSize: CGSize {
        layoutSubtreeIfNeeded()
        return CGSize(width: Metrics.width, height: max(180, bounds.height))
    }

    // MARK: UI 搭建

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Colors.card.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // 标题
        titleLabel.stringValue = L10n.devicePicker.title
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = Colors.title
        addSubview(titleLabel)

        // 关闭按钮
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: L10n.common.close
        )
        closeButton.contentTintColor = Colors.titleSecondary
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)

        // 过滤按钮（全部 / 有线 / 无线）
        let filters: [(Filter, String)] = [
            (.all, L10n.devicePicker.filterAll),
            (.wired, L10n.devicePicker.filterWired),
            (.wireless, L10n.devicePicker.filterWireless),
        ]
        for (filterType, title) in filters {
            let chip = FilterChipButton()
            chip.chipTitle = title
            chip.isChipSelected = filterType == .all
            chip.tag = filterType.rawValue
            chip.target = self
            chip.action = #selector(filterTapped(_:))
            addSubview(chip)
            filterButtons.append(chip)
        }

        // 手动连接区：只在「无线」tab 显示，展开/折叠后同步面板高度
        wirelessSection.isHidden = true
        wirelessSection.onHeightChanged = { [weak self] in
            guard let self else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        addSubview(wirelessSection)

        // 列表（可滚动，行手动布局保证尺寸精确）
        listScroll.documentView = rowsContainer
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        addSubview(listScroll)

        // 空态提示
        emptyLabel.stringValue = L10n.devicePicker.empty
        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = Colors.sub
        emptyLabel.alignment = .center
        // 允许换行显示两行，避免 11pt 文案被压扁在 18pt 高度里
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.cell?.wraps = true
        emptyLabel.cell?.isScrollable = false
        addSubview(emptyLabel)

        // 底部按钮
        styleSecondaryButton(scanButton, title: L10n.devicePicker.scanWireless, action: #selector(scanTapped))
        addSubview(scanButton)
        styleSecondaryButton(stopAllButton, title: L10n.devicePicker.stopAll, action: #selector(stopAllTapped))
        addSubview(stopAllButton)

        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = Metrics.width
        // 左基线统一 20pt：标题、胶囊、列表、底部按钮全部对齐这一条竖线
        let pad: CGFloat = 20
        let inner = width - pad * 2

        // 固定区高度
        let titleH: CGFloat = 24
        let filterH: CGFloat = 28
        let footerH: CGFloat = 30
        let gap: CGFloat = 12

        // 行区高度：无行时保留空态空间
        let rowsH: CGFloat = rowViews.isEmpty
            ? 44
            : CGFloat(rowViews.count) * Metrics.rowHeight + CGFloat(rowViews.count - 1) * 6 + 8
        let listH = min(Metrics.maxListHeight, rowsH)

        // 无线 tab 才显示手动连接区
        wirelessSection.isHidden = filter != .wireless
        let wirelessH = wirelessSection.isHidden ? 0 : wirelessSection.preferredHeight(width: inner)

        var total = pad + titleH + gap + filterH + gap + listH
        if wirelessH > 0 { total += gap + wirelessH }
        total += gap + footerH + pad
        let heightChanged = abs(bounds.height - total) > 0.5
        bounds.size = CGSize(width: width, height: total)

        // 自上而下摆放
        let top = total

        // 标题 + 关闭（X 命中区扩到 ≥24x24，小图标不好点）
        titleLabel.frame = CGRect(x: pad, y: top - pad - titleH, width: inner - 34, height: titleH)
        closeButton.sizeToFit()
        let cw = max(24, closeButton.frame.width)
        let ch = max(24, closeButton.frame.height)
        closeButton.frame = CGRect(
            x: width - pad - cw,
            y: top - pad - titleH + (titleH - ch) / 2,
            width: cw,
            height: ch
        )

        // 过滤胶囊：整像素摆放，避免半像素导致文字发虚
        let filterY = (top - pad - titleH - gap - filterH).rounded()
        var fx: CGFloat = pad
        for chip in filterButtons {
            let w = FilterChipButton.width(for: chip.chipTitle).rounded()
            chip.frame = CGRect(x: fx.rounded(), y: filterY, width: w, height: filterH)
            fx += w + 8
        }

        // 行区
        let listY = filterY - gap - listH
        listScroll.frame = CGRect(x: pad - 4, y: listY, width: inner + 8, height: listH)
        rowsContainer.frame = CGRect(x: 0, y: 0, width: inner + 8, height: rowsH)
        emptyLabel.frame = CGRect(x: pad, y: listY + listH / 2 - 17, width: inner, height: 34)

        // 手动连接区（无线 tab）
        if wirelessH > 0 {
            wirelessSection.frame = CGRect(x: pad, y: listY - gap - wirelessH, width: inner, height: wirelessH)
            wirelessSection.layoutSection()
        }

        // 底部按钮
        let buttonWidth = (inner - 10) / 2
        scanButton.frame = CGRect(x: pad, y: pad, width: buttonWidth, height: 30)
        stopAllButton.frame = CGRect(x: pad + buttonWidth + 10, y: pad, width: buttonWidth, height: 30)

        emptyLabel.isHidden = !rowViews.isEmpty

        // 内容变高/变矮后通知面板重新定位（异步避免在 layout 中改窗口尺寸）
        if heightChanged {
            DispatchQueue.main.async { [weak self] in
                self?.onContentHeightChanged?()
            }
        }
    }

    // MARK: 数据刷新

    /// 依据当前设备与状态重建列表
    func refreshRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }

        let appState = AppState.shared

        // Android 设备：先按物理设备聚合，避免同一台手机的 USB / 无线 TLS / 无线 5555 各占一行
        let dedupedAndroid = dedupAndroidDevices(
            appState.androidDeviceProvider.devices.filter {
                matchesFilter(connectionType: $0.connectionType)
            }
        )
        .sorted { $0.device.displayName < $1.device.displayName }

        for entry in dedupedAndroid {
            let device = entry.device
            // 只要这台物理设备的任一 transport 在投屏，这一行就算「投屏中」
            let capturing = appState.androidDeviceProvider.devices
                .filter { physicalIdentity($0) == physicalIdentity(device) }
                .contains { appState.isAndroidCapturing(serial: $0.serial) }
            let isPrimary = appState.primaryAndroidSerial.map { primarySerial in
                appState.androidDeviceProvider.devices
                    .filter { physicalIdentity($0) == physicalIdentity(device) }
                    .contains { $0.serial == primarySerial }
            } ?? false
            let row = buildRow(
                platformSymbol: "smartphone",
                title: device.displayName,
                subtitle: rowSubtitle(
                    platform: L10n.platform.android,
                    title: device.displayName,
                    model: device.model,
                    connectionTypes: entry.connections,
                    state: device.state == .device ? .online : .offline
                ),
                isCapturing: capturing,
                isPrimary: isPrimary
            )
            row.actionHandler = { [weak self] in
                self?.handleAndroidRowTap(device: device, capturing: capturing)
            }
            rowViews.append(row)
            rowsContainer.addSubview(row)
        }

        // iOS 设备（均通过 USB 连接）
        // 必须和 Android 一样走 connectionType 过滤：
        // iOS 只有 USB 链路，若不过滤会在「无线」标签页里也列出来（用户反馈的 bug）。
        let iosDevices = matchesFilter(connectionType: .usb)
            ? appState.iosDeviceProvider.devices
            : []

        for device in iosDevices {
            let capturing = appState.iosSources[device.id]?.state == .capturing
            let row = buildRow(
                platformSymbol: "iphone",
                title: device.displayName,
                subtitle: rowSubtitle(
                    platform: L10n.platform.ios,
                    title: device.displayName,
                    model: device.productType,
                    connectionTypes: [.usb],
                    state: .online
                ),
                isCapturing: capturing,
                isPrimary: appState.iosDeviceSource === appState.iosSources[device.id]
            )
            row.actionHandler = { [weak self] in
                self?.handleIOSRowTap(device: device, capturing: capturing)
            }
            rowViews.append(row)
            rowsContainer.addSubview(row)
        }

        emptyLabel.isHidden = !rowViews.isEmpty

        // 手动摆放行（自上而下，AppKit 原点在左下）
        // 行宽用与 layout() 相同的 inner（width-32），并给滚动条留出右侧空间，
        // 避免行内容（投屏按钮）被列表右缘裁切（修复选择器按钮被裁 bug）
        let inner = Metrics.width - 32
        for (index, row) in rowViews.enumerated() {
            let y = CGFloat(rowViews.count - 1 - index) * (Metrics.rowHeight + 6)
            row.frame = CGRect(x: 2, y: y + 4, width: inner, height: Metrics.rowHeight)
        }
        rowsContainer.frame = CGRect(
            x: 0,
            y: 0,
            width: inner + 8,
            height: rowViews.isEmpty ? 0 : CGFloat(rowViews.count) * (Metrics.rowHeight + 6) + 4
        )
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// 行副标题（型号与标题相同则不再重复展示）
    /// connectionTypes 是同一物理设备的全部可用链路（USB 优先排在前面），
    /// 去重后一台手机只显示一行，例如「Android · IN2010 · USB · Wi-Fi」
    private func rowSubtitle(
        platform: String,
        title: String,
        model: String?,
        connectionTypes: [AndroidDevice.ConnectionType],
        state: RowState
    ) -> String {
        var parts = [platform]
        if let model, !model.isEmpty {
            let normalizedModel = model.replacingOccurrences(of: "_", with: " ").lowercased()
            let normalizedTitle = title.lowercased()
            if normalizedModel != normalizedTitle {
                parts.append(model)
            }
        }
        let ordered = connectionTypes.sorted { lhs, rhs in
            // USB 在前，其次无线
            (lhs == .usb ? 0 : 1) < (rhs == .usb ? 0 : 1)
        }
        for type in ordered {
            let label = type == .usb ? L10n.devicePicker.viaUSB : L10n.devicePicker.viaWiFi
            if !parts.contains(label) { parts.append(label) }
        }
        if state == .offline { parts.append(L10n.devicePicker.offline) }
        return parts.joined(separator: " · ")
    }

    // MARK: 设备去重

    /// 一台物理设备在 adb 里可能有多个 transport（USB + 无线调试 TLS 端口 + 5555 明文端口），
    /// 直接按 devices 数组渲染会让同一台手机出现 2~3 行。这里按物理身份聚合。
    private struct DedupedDevice {
        let device: AndroidDevice
        let connections: [AndroidDevice.ConnectionType]
    }

    /// 物理身份：优先 wirelessGUID（persist.adb.wifi.guid，跨 USB/多无线端口一致），
    /// 退化时用无线 serial 的 IP 部分（同 IP 视为同一台手机）
    private func physicalIdentity(_ device: AndroidDevice) -> String {
        if let guid = device.wirelessGUID, !guid.isEmpty {
            return "guid:" + guid
        }
        let serial = device.serial
        if !serial.hasPrefix("emulator-"), let colon = serial.lastIndex(of: ":") {
            let host = String(serial[serial.startIndex ..< colon])
            // 纯 IPv4/hostname 形态才按 IP 聚合
            if host.contains(".") || host.lowercased().hasPrefix("adb-") {
                return "host:" + host.lowercased()
            }
        }
        return "serial:" + serial
    }

    /// 聚合 + 选择代表行。代表行优先级：USB > 无线 TLS 端口 > 无线 5555
    private func dedupAndroidDevices(_ devices: [AndroidDevice]) -> [DedupedDevice] {
        var order: [String] = []
        var groups: [String: [AndroidDevice]] = [:]
        for device in devices {
            let key = physicalIdentity(device)
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key]?.append(device)
        }

        func preferenceScore(_ device: AndroidDevice) -> Int {
            if device.connectionType == .usb { return 0 }
            // 无线：非 5555 端口一般是 Android 11+ 无线调试的 TLS 端口，比 5555 更稳
            if device.serial.hasSuffix(":5555") { return 2 }
            return 1
        }

        return order.compactMap { key in
            guard let members = groups[key], let representative = members.min(by: {
                preferenceScore($0) < preferenceScore($1)
            }) else { return nil }

            // 连接类型汇总（去重、保序）
            var connections: [AndroidDevice.ConnectionType] = []
            for member in members.sorted(by: { preferenceScore($0) < preferenceScore($1) }) {
                if !connections.contains(member.connectionType) {
                    connections.append(member.connectionType)
                }
            }
            if connections.isEmpty { connections = [representative.connectionType] }
            return DedupedDevice(device: representative, connections: connections)
        }
    }

    private enum RowState { case online, offline }

    private func matchesFilter(connectionType: AndroidDevice.ConnectionType) -> Bool {
        switch filter {
        case .all: return true
        case .wired: return connectionType == .usb
        case .wireless: return connectionType == .wifi
        }
    }

    // MARK: 行构建

    private func buildRow(
        platformSymbol: String,
        title: String,
        subtitle: String,
        isCapturing: Bool,
        isPrimary: Bool
    ) -> DeviceRowView {
        let row = DeviceRowView()
        row.configure(
            platformSymbol: platformSymbol,
            title: title,
            subtitle: subtitle,
            isCapturing: isCapturing,
            isPrimary: isPrimary
        )
        return row
    }

    // MARK: 动作

    /// Android 行点击：开始 / 停止 / 切换确认
    private func handleAndroidRowTap(device: AndroidDevice, capturing: Bool) {
        let appState = AppState.shared

        if capturing {
            Task { await appState.stopAndroidCapture(serial: device.serial) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.refreshRows()
            }
            return
        }

        // 设备离线：先尝试无线连接（serial 形如 IP:端口）
        if device.state != .device {
            Task { [weak self] in
                do {
                    _ = try await appState.androidDeviceProvider.connectWirelessSmart(input: device.serial)
                    try await appState.startAndroidCapture(device: device)
                    await MainActor.run {
                        self?.refreshRows()
                        self?.closeAfterStart()
                    }
                } catch {
                    await MainActor.run {
                        ToastView.warning(error.localizedDescription, in: nil as NSView?)
                        self?.refreshRows()
                    }
                }
            }
            return
        }

        startAndroidWithOccupancyCheck(device: device)
    }

    /// 启动 Android 投屏：网格模式支持多设备并发，无需占用确认
    private func startAndroidWithOccupancyCheck(device: AndroidDevice) {
        let appState = AppState.shared
        Task { [weak self] in
            do {
                try await appState.startAndroidCapture(device: device)
                await MainActor.run {
                    self?.refreshRows()
                    self?.closeAfterStart()
                }
            } catch {
                await MainActor.run {
                    ToastView.warning(error.localizedDescription, in: nil as NSView?)
                    self?.refreshRows()
                }
            }
        }
    }

    /// iOS 行点击
    private func handleIOSRowTap(device: IOSDevice, capturing: Bool) {
        let appState = AppState.shared

        if capturing {
            Task { await appState.stopIOSCapture(deviceID: device.id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.refreshRows()
            }
            return
        }

        // 网格模式支持多设备并发，无需占用确认
        Task { [weak self] in
            do {
                try await appState.startIOSCapture(device: device)
                await MainActor.run {
                    self?.refreshRows()
                    self?.closeAfterStart()
                }
            } catch {
                await MainActor.run {
                    ToastView.warning(error.localizedDescription, in: nil as NSView?)
                    self?.refreshRows()
                }
            }
        }
    }

    /// 投屏启动成功后自动收起选择器
    /// 用户明确要求：连接设备是一次性动作，连上就该把面板让出来，
    /// 停止投屏统一在下次打开选择器里做，不需要在画面上留停止按钮
    private func closeAfterStart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.onCloseRequest?()
        }
    }

    // MARK: 事件

    @objc private func closeTapped() {
        onCloseRequest?()
    }

    @objc private func filterTapped(_ sender: NSButton) {
        guard let type = Filter(rawValue: sender.tag) else { return }
        filter = type
        for chip in filterButtons {
            chip.isChipSelected = Filter(rawValue: chip.tag) == type
        }
        refreshRows()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @objc private func scanTapped() {
        scanButton.isEnabled = false
        Task { [weak self] in
            let provider = AppState.shared.androidDeviceProvider
            let endpoints = await provider.discoverWirelessEndpoints()
            // 对发现的 IPv4 端点执行 adb connect（端口缓存同时更新）
            for endpoint in endpoints where !endpoint.host.hasPrefix("fe80") {
                _ = try? await provider.connectWirelessSmart(input: "\(endpoint.host):\(endpoint.port)")
            }
            await provider.refreshDevices()
            await MainActor.run {
                self?.scanButton.isEnabled = true
                self?.refreshRows()
            }
        }
    }

    @objc private func stopAllTapped() {
        let appState = AppState.shared
        Task { [weak self] in
            for serial in appState.androidSources.keys {
                await appState.stopAndroidCapture(serial: serial)
            }
            for id in appState.iosSources.keys {
                await appState.stopIOSCapture(deviceID: id)
            }
            await MainActor.run { self?.refreshRows() }
        }
    }

    // MARK: 状态观察

    private func observeState() {
        AppState.shared.stateChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRows() }
            .store(in: &cancellables)

        AppState.shared.androidDeviceProvider.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRows() }
            .store(in: &cancellables)

        AppState.shared.iosDeviceProvider.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRows() }
            .store(in: &cancellables)
    }

    // MARK: 样式

    private func styleSecondaryButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.isBordered = false
        button.wantsLayer = true
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
        )
        button.cell?.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.cell?.usesSingleLineMode = true
        button.cell?.wraps = false
        button.cell?.lineBreakMode = .byClipping
        button.target = self
        button.action = action
    }
}

// MARK: - 单行视图

/// 设备列表行
final class DeviceRowView: NSView {
    var actionHandler: (() -> Void)?

    private let dotView = NSView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.cornerRadius = 10

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        addSubview(dotView)

        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        addSubview(iconView)

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = NSColor.white
        addSubview(nameLabel)

        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        addSubview(subLabel)

        // 单行 + 尾部截断：固定高度的 NSTextField 若不声明单行模式，
        // AppKit 会把中文字形纵向拉伸变形（行高不足时尤其明显）
        for label in [nameLabel, subLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            label.cell?.usesSingleLineMode = true
            label.cell?.truncatesLastVisibleLine = true
            // 显式设置 cell 字体：labelWithString 的 cell 字体与 label.font 偶发不同步，
            // 度量按 13pt、绘制按 13pt 但行高按 cell 字体算，中文会变形。
            label.cell?.font = label.font
        }

        actionButton.isBordered = false
        actionButton.wantsLayer = true
        actionButton.focusRingType = .none
        actionButton.refusesFirstResponder = true
        actionButton.layer?.cornerRadius = 8
        actionButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        addSubview(actionButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    func configure(
        platformSymbol: String,
        title: String,
        subtitle: String,
        isCapturing: Bool,
        isPrimary: Bool
    ) {
        dotView.layer?.backgroundColor = (isCapturing ? NSColor.systemGreen : NSColor(white: 0.35, alpha: 1.0)).cgColor
        iconView.image = NSImage(
            systemSymbolName: platformSymbol,
            accessibilityDescription: nil
        )
        // 「当前面板」状态已由绿点 + 停止按钮表达；标题后缀会导致长设备名截断
        nameLabel.stringValue = title
        subLabel.stringValue = subtitle

        actionButton.layer?.backgroundColor = (isCapturing
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.appAccent
        ).cgColor
        actionButton.attributedTitle = NSAttributedString(
            string: isCapturing ? L10n.devicePicker.stop : L10n.devicePicker.start,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
        )

        // 按钮文案变化会改变按钮宽度 → 文字区宽度随之变化
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height

        dotView.frame = CGRect(x: 14, y: (height - 8) / 2, width: 8, height: 8)
        iconView.frame = CGRect(x: 30, y: (height - 16) / 2, width: 16, height: 16)

        // 按钮宽度按文字真实宽度算：硬编码宽度会挤掉长文案（英文 "Mirror" 等）
        let buttonFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let buttonText = actionButton.attributedTitle.string
        let textAdvance = (buttonText as NSString)
            .size(withAttributes: [.font: buttonFont]).width
        let buttonWidth = max(64, ceil(textAdvance) + 24)

        let textX: CGFloat = 54
        let textRight = width - buttonWidth - 22   // 右侧 12pt 内边距 + 10pt 与按钮间距
        let textWidth = max(40, textRight - textX)

        // 高度给足：13pt 中文字身需 ~18pt、11pt 需 ~16pt（取整后留 1pt 余量），
        // 高度差 1pt 时 AppKit 会纵向拉伸中文字形而不是截断。
        nameLabel.frame = CGRect(x: textX, y: height / 2 + 1, width: textWidth, height: 18)
        subLabel.frame = CGRect(x: textX, y: height / 2 - 17, width: textWidth, height: 16)

        actionButton.frame = CGRect(
            x: width - buttonWidth - 12,
            y: (height - 28) / 2,
            width: buttonWidth,
            height: 28
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 64)
    }

    @objc private func actionTapped() {
        actionHandler?()
    }
}


// MARK: - 过滤器胶囊

/// 过滤器胶囊（自绘）
/// 之前用 NSButton.attributedTitle 时，cell 字体与 attributed 字体不同源、胶囊又落在半像素位置，
/// 中文会发虚并带 1px 重影；这里改为一次性绘制，并把文字起点取整。
final class FilterChipButton: NSButton {
    var chipTitle: String = "" {
        didSet { needsDisplay = true }
    }
    var isChipSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    private static let chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// 胶囊宽度：文字实测宽度 + 左右各 16pt
    static func width(for title: String) -> CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [.font: chipFont]).width
        return ceil(textWidth) + 32
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        focusRingType = .none
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let fill = isChipSelected
            ? NSColor.appAccent.withAlphaComponent(0.85)
            : NSColor.white.withAlphaComponent(0.10)
        fill.setFill()
        path.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.chipFont,
            .foregroundColor: NSColor.white.withAlphaComponent(isChipSelected ? 1.0 : 0.75),
        ]
        let size = (chipTitle as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: (bounds.midX - size.width / 2).rounded(),
            y: (bounds.midY - size.height / 2).rounded()
        )
        (chipTitle as NSString).draw(at: origin, withAttributes: attributes)
    }
}

// MARK: - 无线连接区

/// 无线连接区（「连接设备」面板 → 无线 tab）
/// 等待页已精简为「等待手机连接」，手动 IP 连接、USB 开启无线调试、
/// Android 11+ 配对码、逐步诊断都收进这里，默认折叠以免面板过高。
final class DeviceWirelessPanelView: NSView {
    // MARK: 回调

    /// 点「连接」（参数为输入的 IP 或 IP:端口）
    var onConnect: ((String) -> Void)?
    /// 点「开启无线调试」（需 USB）
    var onEnable: (() -> Void)?
    /// 点「配对并连接」（IP、配对端口、配对码）
    var onPair: ((String, Int, String) -> Void)?
    /// 点「诊断」
    var onDiagnose: (() -> Void)?
    /// 展开/折叠导致高度变化
    var onHeightChanged: (() -> Void)?

    // MARK: 状态

    private(set) var isExpanded = false
    /// 展开状态持久化标记（同一会话内切换 tab 不重置）
    private static var remembersExpanded = false

    // MARK: 常量

    private let fieldHeight: CGFloat = 26
    private let buttonHeight: CGFloat = 26
    private let gap: CGFloat = 8
    private let headerHeight: CGFloat = 24
    private let diagnosticsHeight: CGFloat = 108

    // MARK: 子视图

    private let headerButton = NSButton()
    private let hostBox = WirelessFieldBox(placeholder: L10n.android.wireless.hostPlaceholder)
    private let connectButton = NSButton()
    private let enableButton = NSButton()
    private let pairHintLabel = NSTextField(labelWithString: "")
    private let portBox = WirelessFieldBox(placeholder: L10n.android.wireless.pairPort)
    private let codeBox = WirelessFieldBox(placeholder: L10n.android.wireless.pairCode)
    private let pairButton = NSButton()
    private let diagnoseButton = NSButton()
    private let diagnosticsScroll = NSScrollView()
    private let diagnosticsTextView = NSTextView()

    // MARK: 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: 公开方法

    /// 当前输入框中的 IP
    var currentHost: String {
        hostBox.field.stringValue
    }

    /// 回填扫描到的地址与配对端口
    func fill(host: String, pairPort: Int?) {
        hostBox.field.stringValue = host
        if let pairPort {
            portBox.field.stringValue = String(pairPort)
        }
    }

    /// 显示诊断结果
    func showDiagnostics(_ text: String) {
        diagnosticsTextView.string = text
        diagnosticsScroll.isHidden = text.isEmpty
        if !text.isEmpty, !isExpanded {
            setExpanded(true, notify: true)
        }
        onHeightChanged?()
    }

    /// 折叠状态下只占一行表头
    func preferredHeight(width: CGFloat) -> CGFloat {
        guard isExpanded else { return headerHeight }
        return expandedHeight(width: width)
    }

    // MARK: 布局

    /// 由父视图在完成 frame 赋值后调用，摆放内部元素
    func layoutSection() {
        let width = bounds.width
        guard width > 0 else { return }

        var y = bounds.height
        y -= headerHeight
        headerButton.frame = CGRect(x: 0, y: y, width: width, height: headerHeight)

        guard isExpanded else { return }

        // 1. IP + 连接
        y -= fieldHeight
        let connectWidth: CGFloat = 64
        hostBox.frame = CGRect(x: 0, y: y, width: width - connectWidth - gap, height: fieldHeight)
        connectButton.frame = CGRect(x: width - connectWidth, y: y, width: connectWidth, height: fieldHeight)

        // 2. 开启无线调试
        y -= gap + buttonHeight
        enableButton.frame = CGRect(x: 0, y: y, width: width, height: buttonHeight)

        // 3. 配对说明
        let hintHeight = max(labelHeight(pairHintLabel, width: width), 14)
        y -= gap + hintHeight
        pairHintLabel.frame = CGRect(x: 0, y: y, width: width, height: hintHeight)

        // 4. 配对端口 + 配对码
        y -= gap + fieldHeight
        let half = (width - gap) / 2
        portBox.frame = CGRect(x: 0, y: y, width: half, height: fieldHeight)
        codeBox.frame = CGRect(x: half + gap, y: y, width: half, height: fieldHeight)

        // 5. 配对并连接
        y -= gap + buttonHeight
        pairButton.frame = CGRect(x: 0, y: y, width: width, height: buttonHeight)

        // 6. 诊断输出
        if !diagnosticsScroll.isHidden {
            y -= gap + diagnosticsHeight
            diagnosticsScroll.frame = CGRect(x: 0, y: y, width: width, height: diagnosticsHeight)
            diagnosticsTextView.frame = CGRect(x: 0, y: 0, width: width - 2, height: diagnosticsHeight)
        }

        // 7. 诊断按钮
        y -= gap + buttonHeight
        diagnoseButton.frame = CGRect(x: 0, y: y, width: 88, height: buttonHeight)
    }

    // MARK: 私有：搭建

    private func setupUI() {
        wantsLayer = true

        // 表头（折叠态唯一可见行）：标题 + 折角图标
        styleHeader()
        addSubview(headerButton)

        // IP 输入 + 连接
        addSubview(hostBox)
        styleButton(
            connectButton,
            title: L10n.android.wireless.connectShort,
            primary: true,
            action: #selector(connectTapped)
        )
        addSubview(connectButton)

        // 开启无线调试（次要）
        styleButton(
            enableButton,
            title: L10n.android.wireless.enableForUSB,
            primary: false,
            action: #selector(enableTapped)
        )
        addSubview(enableButton)

        // 配对说明
        pairHintLabel.stringValue = L10n.android.wireless.pairHint
        pairHintLabel.font = NSFont.systemFont(ofSize: 10)
        pairHintLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        pairHintLabel.alignment = .left
        pairHintLabel.lineBreakMode = .byWordWrapping
        pairHintLabel.maximumNumberOfLines = 0
        pairHintLabel.cell?.wraps = true
        pairHintLabel.cell?.isScrollable = false
        addSubview(pairHintLabel)

        // 配对端口 + 配对码
        addSubview(portBox)
        addSubview(codeBox)
        styleButton(
            pairButton,
            title: L10n.android.wireless.pairAction,
            primary: true,
            action: #selector(pairTapped)
        )
        addSubview(pairButton)

        // 诊断
        styleButton(
            diagnoseButton,
            title: L10n.android.wireless.showDiagnostics,
            primary: false,
            action: #selector(diagnoseTapped)
        )
        addSubview(diagnoseButton)

        // 诊断输出
        diagnosticsScroll.hasVerticalScroller = true
        diagnosticsScroll.drawsBackground = false
        diagnosticsScroll.borderType = .noBorder
        diagnosticsScroll.wantsLayer = true
        diagnosticsScroll.layer?.cornerRadius = 6
        diagnosticsScroll.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        diagnosticsScroll.isHidden = true
        diagnosticsTextView.isEditable = false
        diagnosticsTextView.isSelectable = true
        diagnosticsTextView.drawsBackground = false
        diagnosticsTextView.textColor = NSColor.white.withAlphaComponent(0.85)
        diagnosticsTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        diagnosticsTextView.textContainerInset = NSSize(width: 6, height: 6)
        diagnosticsScroll.documentView = diagnosticsTextView
        addSubview(diagnosticsScroll)

        // 折叠状态在同一会话内保持
        setExpanded(Self.remembersExpanded, notify: false)
    }

    private func styleHeader() {
        headerButton.isBordered = false
        headerButton.wantsLayer = true
        headerButton.focusRingType = .none
        headerButton.refusesFirstResponder = true
        headerButton.target = self
        headerButton.action = #selector(headerTapped)
        headerButton.alignment = .left
        updateHeaderTitle()
    }

    private func updateHeaderTitle() {
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        let title = "  " + L10n.devicePicker.manualSection
        headerButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            ]
        )
        headerButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        headerButton.imagePosition = .imageLeading
        headerButton.contentTintColor = NSColor.white.withAlphaComponent(0.45)
    }

    private func styleButton(
        _ button: NSButton,
        title: String,
        primary: Bool,
        action: Selector
    ) {
        button.isBordered = false
        button.wantsLayer = true
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        button.target = self
        button.action = action
        button.layer?.backgroundColor = (primary
            ? NSColor.appAccent
            : NSColor.white.withAlphaComponent(0.10)
        ).cgColor
        button.layer?.borderWidth = primary ? 0 : 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
        )
        button.cell?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.cell?.usesSingleLineMode = true
        button.cell?.wraps = false
        button.cell?.lineBreakMode = .byTruncatingTail
    }

    private func expandedHeight(width: CGFloat) -> CGFloat {
        let hintHeight = max(labelHeight(pairHintLabel, width: width), 14)
        var height = headerHeight
        height += fieldHeight + gap + buttonHeight               // IP + 连接 / 开启无线调试
        height += gap + hintHeight                                // 配对说明
        height += gap + fieldHeight                               // 端口 + 配对码
        height += gap + buttonHeight                              // 配对并连接
        if !diagnosticsScroll.isHidden {
            height += gap + diagnosticsHeight
        }
        height += gap + buttonHeight                              // 诊断
        return height
    }

    private func labelHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        let rect = NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude)
        if let size = label.cell?.cellSize(forBounds: rect) {
            return size.height
        }
        return label.intrinsicContentSize.height
    }

    // MARK: 私有：事件

    private func setExpanded(_ expanded: Bool, notify: Bool) {
        isExpanded = expanded
        Self.remembersExpanded = expanded
        updateHeaderTitle()
        let hidden = !expanded
        for view in [hostBox, connectButton, enableButton, pairHintLabel, portBox, codeBox, pairButton, diagnoseButton] {
            view.isHidden = hidden
        }
        // 诊断输出跟随展开状态，但只有存在内容时显示
        diagnosticsScroll.isHidden = hidden || diagnosticsTextView.string.isEmpty
        if notify {
            onHeightChanged?()
        }
    }

    @objc private func headerTapped() {
        setExpanded(!isExpanded, notify: true)
    }

    @objc private func connectTapped() {
        onConnect?(hostBox.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func enableTapped() {
        onEnable?()
    }

    @objc private func pairTapped() {
        let port = Int(portBox.field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        let code = codeBox.field.stringValue.trimmingCharacters(in: .whitespaces)
        onPair?(hostBox.field.stringValue.trimmingCharacters(in: .whitespaces), port, code)
    }

    @objc private func diagnoseTapped() {
        onDiagnose?()
    }
}

// MARK: - 无线输入框

/// 无线连接用的输入框（圆角底 + 左侧 8pt 内边距）
/// NSTextField 自身不带内边距，靠外层容器绘制底板，输入框内缩，
/// 这样文字不会贴着圆角边缘，也与整体左基线对齐。
final class WirelessFieldBox: NSView {
    let field = NSTextField()

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 11)
        field.alignment = .left
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.textColor = .white
        field.focusRingType = .none
        if let cell = field.cell as? NSTextFieldCell {
            cell.drawsBackground = false
            cell.usesSingleLineMode = true
            cell.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                ]
            )
        }
        addSubview(field)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 17
        field.frame = CGRect(
            x: 8,
            y: (bounds.height - height) / 2,
            width: max(1, bounds.width - 16),
            height: height
        )
    }
}

