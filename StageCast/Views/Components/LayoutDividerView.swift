//
//  LayoutDividerView.swift
//  StageCast
//
//  布局分隔条：双设备/网格布局中可拖拽的比例分隔条
//  设计约束：
//  - 命中区较宽（便于拖拽），视觉细条居中
//  - 拖拽时把位置归一化交给父容器计算比例，本视图不持有布局知识
//  - 颜色沿用项目半透明浮层语言，悬停/拖拽时高亮
//

import AppKit

// MARK: - 布局分隔条

/// 可拖拽的布局分隔条
/// - \`axis == .horizontal\`：竖条，分左右两块（拖拽改变宽度比例）
/// - \`axis == .vertical\`：横条，分上下两块（拖拽改变高度比例）
final class LayoutDividerView: NSView {
    // MARK: - 拖拽轴

    enum Axis {
        /// 竖条（分左右）
        case horizontal
        /// 横条（分上下）
        case vertical
    }

    // MARK: - 回调

    /// 拖拽中的归一化位置：拖拽点在父视图 bounds 内的坐标（0-1）
    var onDrag: ((CGFloat) -> Void)?
    /// 拖拽结束（用于落盘偏好）
    var onDragEnded: (() -> Void)?

    // MARK: - 状态

    var axis: Axis = .horizontal
    private let barLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isDragging = false

    // MARK: - 初始化

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.addSublayer(barLayer)
        refreshBarAppearance()
    }

    // MARK: - 外观

    private func refreshBarAppearance() {
        let thickness: CGFloat = 4
        let inset: CGFloat = 8
        if axis == .horizontal {
            barLayer.frame = CGRect(
                x: (bounds.width - thickness) / 2,
                y: inset,
                width: thickness,
                height: max(0, bounds.height - inset * 2)
            )
        } else {
            barLayer.frame = CGRect(
                x: inset,
                y: (bounds.height - thickness) / 2,
                width: max(0, bounds.width - inset * 2),
                height: thickness
            )
        }
        barLayer.cornerRadius = thickness / 2
        // 无格线模式：平时完全透明，悬停/拖拽时才显形（可拖拽但不可见）
        if isDragging {
            barLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        } else if isHovering {
            barLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        } else {
            barLayer.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// 非活动窗口首次点击也能直接开始拖拽，而不是只激活窗口
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        refreshBarAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - 鼠标交互

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        refreshBarAppearance()
        pushCursor()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        refreshBarAppearance()
        if !isDragging {
            popCursor()
        }
    }

    // 拖拽分隔条时不能让窗口跟着移动：NSView.mouseDown 的默认实现
    // 会在 mouseDownCanMoveWindow 为真时启动窗口拖动跟踪循环，
    // 后续 mouseDragged 就再也进不来，所以这里不调 super。
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        refreshBarAppearance()
        pushCursor()
        notifyDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        notifyDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        refreshBarAppearance()
        popCursor()
        onDragEnded?()
    }

    private func notifyDrag(with event: NSEvent) {
        guard let superview else { return }
        let pointInSelf = convert(event.locationInWindow, from: nil)
        let pointInSuper = convert(pointInSelf, to: superview)
        let superBounds = superview.bounds
        if axis == .horizontal {
            guard superBounds.width > 0 else { return }
            onDrag?(pointInSuper.x / superBounds.width)
        } else {
            guard superBounds.height > 0 else { return }
            onDrag?(pointInSuper.y / superBounds.height)
        }
    }

    // MARK: - 光标

    private func pushCursor() {
        if axis == .horizontal {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.resizeUpDown.push()
        }
    }

    private func popCursor() {
        NSCursor.pop()
    }
}
