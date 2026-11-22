//
//  DeviceCaptureInfoView.swift
//  StageCast
//
//  Created by Sun on 2025/12/25.
//
//  设备控制动作 + 镜像统计角标
//  统计角标：投屏画面右上角内侧的小胶囊，常显分辨率与帧率
//

import AppKit

// MARK: - 设备控制动作

/// 浮层上的设备控制动作
enum DeviceControlAction: CaseIterable {
    case recordToggle
    case volumeUp
    case volumeDown
    case power
    case rotate
    case home
    case back
    case muteToggle

    /// 按钮图标（SF Symbols，与项目其余图标风格一致）
    var symbolName: String {
        switch self {
        case .recordToggle: "record.circle"
        case .volumeUp: "speaker.plus.fill"
        case .volumeDown: "speaker.minus.fill"
        case .power: "power"
        case .rotate: "rotate.right"
        case .home: "house.fill"
        case .back: "arrow.uturn.backward"
        case .muteToggle: "speaker.slash.fill"
        }
    }

    /// 按钮提示文案
    var title: String {
        switch self {
        case .recordToggle: L10n.overlayUI.controlRecord
        case .volumeUp: L10n.overlayUI.controlVolumeUp
        case .volumeDown: L10n.overlayUI.controlVolumeDown
        case .power: L10n.overlayUI.controlPower
        case .rotate: L10n.overlayUI.controlRotate
        case .home: L10n.overlayUI.controlHome
        case .back: L10n.overlayUI.controlBack
        case .muteToggle: L10n.overlayUI.controlMute
        }
    }
}

// MARK: - 镜像统计角标

/// 投屏画面右上角内侧的统计角标
/// 显示分辨率与帧率，默认常显，等宽字体小胶囊
final class MirrorStatsBadge: NSView {
    // MARK: - UI 组件

    private let label = NSTextField(labelWithString: "")

    // MARK: - 状态

    private var resolution: CGSize = .zero
    private var fps: Double = 0
    private var displayTimer: Timer?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        displayTimer?.invalidate()
    }

    // MARK: - UI 设置

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        addSubview(label)

        updateLabelText()
    }

    // MARK: - 公开方法

    /// 更新分辨率
    func updateResolution(_ size: CGSize) {
        resolution = size
        updateLabelText()
    }

    /// 更新帧率
    func updateFPS(_ value: Double) {
        fps = value
        updateLabelText()
    }

    /// 是否显示（由外部偏好控制）
    func setVisible(_ visible: Bool) {
        guard isHidden == visible else { return }
        alphaValue = visible ? 1 : 0
        isHidden = !visible
    }

    // MARK: - 布局

    /// 文本驱动的目标尺寸（供外部布局使用）
    /// 角标是右对齐浮层：宽度必须由这里统一给出，避免子视图 layout() 自己改尺寸
    /// 把右边缘顶出画面（表现为「角标偶尔不在右上角」）。
    var preferredSize: NSSize {
        label.sizeToFit()
        let labelSize = label.fittingSize
        let text = label.stringValue
        let padding: CGFloat = 6
        let estWidth = text.isEmpty ? 0 : (CGFloat(text.count) * 6.4 + padding * 2)
        let w = max(labelSize.width + padding * 2, estWidth)
        return NSSize(width: ceil(w), height: 18)
    }

    override func layout() {
        super.layout()
        let target = preferredSize
        // 保持右边缘与上边缘锚定：宽度变化时向左/向下扩张，绝不越过画面边界
        if abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 {
            frame = NSRect(
                x: frame.maxX - target.width,
                y: frame.maxY - target.height,
                width: target.width,
                height: target.height
            )
        }
        label.sizeToFit()
        let labelSize = label.fittingSize
        label.frame = CGRect(
            x: 6,
            y: (bounds.height - labelSize.height) / 2,
            width: bounds.width - 12,
            height: labelSize.height
        )
    }

    // MARK: - 内部

    private func updateLabelText() {
        var parts: [String] = []
        if resolution.width > 0, resolution.height > 0 {
            parts.append("\(Int(resolution.width))×\(Int(resolution.height))")
        }
        if fps > 0 {
            parts.append("\(Int(fps))fps")
        }
        label.stringValue = parts.joined(separator: " · ")
        needsLayout = true
    }
}
