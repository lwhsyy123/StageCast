//
//  DeviceControlBarView.swift
//  StageCast
//
//  Created by Sun on 2026/11/18.
//
//  设备控制按钮条
//  独立的浮动控件，靠在投屏画面边上，提供录制/音量/电源/旋转/主屏幕/返回等按键
//  支持横排（底部居中）和竖排（右侧垂直居中）两种方向
//

import AppKit

// MARK: - 按钮

/// 控制条按钮
/// 按钮条放在「非激活面板」里：默认 NSButton 在窗口非激活时会吞掉第一次点击
/// （只用来激活窗口），表现为「点了没反应」。这里显式接受首次点击。
private final class ControlBarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 设备控制按钮条

/// 设备控制按钮条
/// 设计约束：
/// - 与统计角标完全独立，互不影响显隐
/// - 图标沿用 SF Symbols
/// - 默认自动隐藏，鼠标靠近画面或按钮条时出现
/// - 横排放画面下缘居中，竖排放画面右侧垂直居中（窄画面时自动切换）
final class DeviceControlBarView: NSView {
    // MARK: - 方向

    enum Orientation {
        case horizontal
        case vertical
    }

    // MARK: - 录制状态

    enum RecordingState {
        case idle
        case recording(elapsedSeconds: Int)
    }

    // MARK: - 布局常量

    /// 按钮尺寸上限（实际尺寸会按画面宽度收缩，避免超出设备边框）
    private static let maxButtonSize: CGFloat = 30
    /// 按钮最小尺寸，保证小画面下仍可点击
    private static let minButtonSize: CGFloat = 18
    /// 按钮间距
    private static let spacing: CGFloat = 6
    /// 内边距
    private static let padding: CGFloat = 8
    /// 录制时长标签宽度
    private static let recordLabelWidth: CGFloat = 32

    /// 按可用尺寸计算按钮尺寸与整体尺寸
    /// - Parameters:
    ///   - maxWidth: 按钮条允许的最大宽度（横排时取设备画面宽度）
    ///   - orientation: 布局方向
    static func layoutSize(fittingWidth maxWidth: CGFloat, orientation: Orientation = .horizontal) -> (size: NSSize, buttonSize: CGFloat) {
        let count = CGFloat(DeviceControlAction.allCases.count)
        guard count > 0, maxWidth > 0 else {
            return (NSSize(width: 0, height: 0), minButtonSize)
        }

        // 先按上限算，放不下就等比缩小按钮
        let available = maxWidth - padding * 2 - spacing * (count - 1)
        let idealButton = available / count
        let buttonSize = min(maxButtonSize, max(minButtonSize, idealButton))

        switch orientation {
        case .horizontal:
            let width = count * buttonSize + (count - 1) * spacing + padding * 2
            let height = buttonSize + padding * 2
            return (NSSize(width: min(width, maxWidth), height: height), buttonSize)
        case .vertical:
            let height = count * buttonSize + (count - 1) * spacing + padding * 2
            let width = buttonSize + padding * 2
            return (NSSize(width: width, height: height), buttonSize)
        }
    }

    /// 当前布局使用的按钮尺寸
    private var currentButtonSize: CGFloat = maxButtonSize

    /// 当前方向
    private(set) var orientation: Orientation = .horizontal

    // MARK: - UI 组件

    /// 所有按钮
    private var buttons: [NSButton] = []

    /// 录制时长标签（仅在录制中显示）
    private let recordDurationLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        label.isHidden = true
        return label
    }()

    // MARK: - 回调

    /// 按钮点击回调
    var onAction: ((DeviceControlAction) -> Void)?
    /// 鼠标进入/离开（用于自动隐藏计时）
    var onHoverChanged: ((Bool) -> Void)?

    // MARK: - 状态

    private var trackingArea: NSTrackingArea?
    private var recordingState: RecordingState = .idle

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
        // 半透明深色底
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // 面板尺寸固定，用 frame 布局更可预测，避免 Auto Layout 在非约束容器里算出零尺寸
        for action in DeviceControlAction.allCases {
            let button = makeButton(for: action)
            buttons.append(button)
            addSubview(button)
        }
        addSubview(recordDurationLabel)
    }

    private func makeButton(for action: DeviceControlAction) -> NSButton {
        let button = ControlBarButton()
        button.bezelStyle = .inline
        button.isBordered = false
        // 清空标题：图标缺失时 NSButton 会退回绘制本地化的默认标题「按钮」
        button.title = ""
        button.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        button.toolTip = action.title
        button.target = self
        button.action = #selector(buttonTapped(_:))
        button.tag = DeviceControlAction.allCases.firstIndex(of: action) ?? 0
        return button
    }

    // MARK: - 录制状态

    /// 更新录制按钮外观和时长显示
    func setRecordingState(_ state: RecordingState) {
        recordingState = state
        guard let index = DeviceControlAction.allCases.firstIndex(of: .recordToggle),
              buttons.indices.contains(index) else { return }
        let button = buttons[index]
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: DeviceControlAction.recordToggle.symbolName, accessibilityDescription: L10n.overlayUI.controlRecord)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            button.contentTintColor = NSColor.white.withAlphaComponent(0.5)
            button.toolTip = L10n.overlayUI.controlRecord
            recordDurationLabel.isHidden = true
        case .recording(let seconds):
            button.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: L10n.overlayUI.controlRecord)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            button.contentTintColor = NSColor.systemRed
            button.toolTip = L10n.recording.stop
            recordDurationLabel.stringValue = formatElapsed(seconds)
            recordDurationLabel.isHidden = false
        }
        needsLayout = true
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 每格静音状态

    /// 当前静音状态（仅影响静音按钮的图标与提示）
    private var isMuted = false

    /// 更新静音按钮的外观：静音时红色斜杠喇叭，未静音时普通喇叭
    func setMuteState(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        guard let index = DeviceControlAction.allCases.firstIndex(of: .muteToggle),
              buttons.indices.contains(index) else { return }
        let button = buttons[index]
        if muted {
            button.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: L10n.overlayUI.controlUnmute)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            button.contentTintColor = NSColor.systemRed
            button.toolTip = L10n.overlayUI.controlUnmute
        } else {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: L10n.overlayUI.controlMute)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            button.contentTintColor = NSColor.white.withAlphaComponent(0.92)
            button.toolTip = L10n.overlayUI.controlMute
        }
    }

    // MARK: - 交互

    /// 非活动窗口首次点击也直接响应，避免第一下只用于激活窗口
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func buttonTapped(_ sender: NSButton) {
        let all = DeviceControlAction.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        onAction?(all[sender.tag])
    }

    override var intrinsicContentSize: NSSize {
        Self.layoutSize(fittingWidth: 400, orientation: orientation).size
    }

    /// 设置方向并按给定尺寸重新排版
    /// - Parameters:
    ///   - orientation: 新方向
    ///   - maxWidth: 横排时画面宽度，竖排时画面高度
    func relayout(orientation newOrientation: Orientation, fittingWidth maxWidth: CGFloat) {
        orientation = newOrientation
        let (size, buttonSize) = Self.layoutSize(fittingWidth: maxWidth, orientation: newOrientation)
        currentButtonSize = buttonSize
        if frame.size != size {
            frame = CGRect(origin: frame.origin, size: size)
        }
        needsLayout = true
    }

    /// 按给定宽度重新排版（保持当前方向）
    func relayout(fittingWidth maxWidth: CGFloat) {
        relayout(orientation: orientation, fittingWidth: maxWidth)
    }

    override func layout() {
        super.layout()
        let count = CGFloat(buttons.count)
        guard count > 0 else { return }

        let buttonSize = currentButtonSize

        switch orientation {
        case .horizontal:
            // 横排：按钮从左到右居中排列
            let totalWidth = count * buttonSize + (count - 1) * Self.spacing
            let startX = (bounds.width - totalWidth) / 2
            let y = (bounds.height - buttonSize) / 2

            for (index, button) in buttons.enumerated() {
                button.frame = CGRect(
                    x: startX + CGFloat(index) * (buttonSize + Self.spacing),
                    y: y,
                    width: buttonSize,
                    height: buttonSize
                )
            }
            // 录制时长标签：放在录制按钮右侧
            if let recordIndex = DeviceControlAction.allCases.firstIndex(of: .recordToggle),
               buttons.indices.contains(recordIndex), !recordDurationLabel.isHidden {
                let recordButton = buttons[recordIndex]
                let labelX = recordButton.frame.maxX + 2
                let labelY = (bounds.height - 12) / 2
                recordDurationLabel.frame = CGRect(x: labelX, y: labelY, width: Self.recordLabelWidth, height: 12)
            }

        case .vertical:
            // 竖排：按钮从上到下居中排列
            let totalHeight = count * buttonSize + (count - 1) * Self.spacing
            let startY = (bounds.height - totalHeight) / 2
            let x = (bounds.width - buttonSize) / 2

            for (index, button) in buttons.enumerated() {
                button.frame = CGRect(
                    x: x,
                    y: startY + CGFloat(count - 1 - CGFloat(index)) * (buttonSize + Self.spacing),
                    width: buttonSize,
                    height: buttonSize
                )
            }
            // 录制时长标签：放在录制按钮下方
            if let recordIndex = DeviceControlAction.allCases.firstIndex(of: .recordToggle),
               buttons.indices.contains(recordIndex), !recordDurationLabel.isHidden {
                let recordButton = buttons[recordIndex]
                let labelY = recordButton.frame.minY - 12
                let labelX = (bounds.width - Self.recordLabelWidth) / 2
                recordDurationLabel.frame = CGRect(x: labelX, y: labelY, width: Self.recordLabelWidth, height: 12)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    /// 是否显示（由外部统一控制自动隐藏）
    /// 不再使用 animator() 淡入淡出：实测在子窗口/layer-backed 场景下
    /// animator 代理动画可能不生效（alpha 永远停在 1 或 0），
    /// 且 isHidden 与 alpha 状态一旦错位，按钮条就会永久消失或永不消失。
    /// 改为直接设置 alpha 与 isHidden，保证状态机绝对一致。
    func setVisible(_ visible: Bool, animated: Bool) {
        alphaValue = visible ? 1 : 0
        isHidden = !visible
    }
}