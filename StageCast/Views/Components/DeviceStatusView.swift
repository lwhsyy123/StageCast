//
//  DeviceStatusView.swift
//  StageCast
//
//  Created by Sun on 2025/12/25.
//
//  设备状态视图
//  统一等待页：轮廓图标 + 「等待手机连接」 + 一行说明
//  连接/配对/诊断等进阶入口已迁移到「连接设备」面板的无线 tab
//

import AppKit

// MARK: - 设备状态视图

final class DeviceStatusView: NSView {
    // MARK: - 颜色定义（适配黑色背景的屏幕区域）

    private enum Colors {
        /// 主标题颜色（白色）
        static let title = NSColor.white
        /// 次要标题颜色（浅灰色）
        static let titleSecondary = NSColor(white: 0.6, alpha: 1.0)
        /// 状态文字颜色（中灰色）
        static let status = NSColor(white: 0.7, alpha: 1.0)
        /// 提示文字颜色（深灰色）
        static let hint = NSColor(white: 0.5, alpha: 1.0)
        /// 次要按钮文字颜色（中灰色）
        static let actionSecondary = NSColor(white: 0.7, alpha: 1.0)
        /// 设备轮廓图标颜色（更浅的灰，作为背景装饰）
        static let deviceGlyph = NSColor(white: 0.28, alpha: 1.0)
    }

    // MARK: - 尺寸常量

    /// 标题基准字号
    private let titleBaseFontSize: CGFloat = 26
    /// 标题最小字号
    private let titleMinFontSize: CGFloat = 15
    /// 副标题基准字号
    private let subtitleBaseFontSize: CGFloat = 13
    /// 副标题最小字号
    private let subtitleMinFontSize: CGFloat = 10
    /// 设备轮廓图标尺寸
    private let deviceGlyphSize: CGFloat = 44

    // MARK: - UI 组件

    /// 内容居中容器
    private let contentContainer = NSView()
    /// 设备轮廓图标（空态装饰）
    private let deviceGlyphView = NSImageView()
    /// 加载指示器（菊花）
    private let loadingIndicator = NSProgressIndicator()
    /// 标题（设备名称或提示文案）
    private let titleLabel = NSTextField(labelWithString: "")
    /// 状态栏容器
    private let statusContainer = NSView()
    /// 状态指示灯
    private let statusIndicator = NSView()
    /// 状态文本
    private let statusLabel = NSTextField(labelWithString: "")
    /// 操作按钮（仅工具链缺失时使用）
    private let actionButton = PaddedButton(horizontalPadding: 20, verticalPadding: 12)
    /// 操作按钮加载指示器
    private let actionLoadingIndicator = NSProgressIndicator()
    /// 副标题/提示
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// 刷新按钮
    private let refreshButton = PaddedButton(horizontalPadding: 10, verticalPadding: 6)
    /// 刷新加载指示器
    private let refreshLoadingIndicator = NSProgressIndicator()

    // MARK: - 回调

    /// 操作按钮点击
    var onActionTapped: (() -> Void)?
    /// 刷新按钮点击（完成后调用传入的 completion 结束加载态）
    var onRefreshTapped: (((@escaping () -> Void) -> Void))?
    /// 状态区域点击（查看设备详情）
    var onStatusTapped: (() -> Void)?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 构建 UI

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.05, alpha: 1.0).cgColor

        setupContentContainer()
        setupDeviceGlyph()
        setupLoadingIndicator()
        setupTitleLabel()
        setupStatusStack()
        setupActionButton()
        setupSubtitleLabel()
        setupRefreshButton()
        setupStatusGesture()
    }

    private func setupContentContainer() {
        addSubview(contentContainer)
    }

    private func setupDeviceGlyph() {
        let configuration = NSImage.SymbolConfiguration(pointSize: deviceGlyphSize, weight: .ultraLight)
        if let image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            // 模板图 + tint 让图标跟随主题色，不依赖 SF Symbol 的多层渲染
            image.isTemplate = true
            deviceGlyphView.image = image
            deviceGlyphView.contentTintColor = Colors.deviceGlyph
        }
        deviceGlyphView.imageScaling = .scaleProportionallyUpOrDown
        contentContainer.addSubview(deviceGlyphView)
    }

    private func setupLoadingIndicator() {
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isHidden = true
        // 强制使用 darkAqua 外观，确保在深色背景下菊花图标可见（白色）
        loadingIndicator.appearance = NSAppearance(named: .darkAqua)
        contentContainer.addSubview(loadingIndicator)
    }

    private func setupTitleLabel() {
        titleLabel.font = NSFont.systemFont(ofSize: titleBaseFontSize, weight: .semibold)
        titleLabel.textColor = Colors.title
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.wraps = true
        titleLabel.cell?.usesSingleLineMode = false
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.isHidden = false
        contentContainer.addSubview(titleLabel)
    }

    private func setupStatusStack() {
        contentContainer.addSubview(statusContainer)

        // 状态指示灯
        statusIndicator.wantsLayer = true
        statusIndicator.layer?.cornerRadius = 5
        statusIndicator.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusContainer.addSubview(statusIndicator)

        // 状态文本
        statusLabel.font = NSFont.systemFont(ofSize: 15)
        statusLabel.textColor = Colors.status
        statusContainer.addSubview(statusLabel)
    }

    private func setupActionButton() {
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.wantsLayer = true
        actionButton.isBordered = false
        actionButton.layer?.cornerRadius = 8
        actionButton.layer?.backgroundColor = NSColor.appAccent.cgColor
        actionButton.focusRingType = .none
        actionButton.refusesFirstResponder = true
        setActionButtonTitle(L10n.overlayUI.startCapture)
        contentContainer.addSubview(actionButton)

        // 操作按钮加载指示器
        actionLoadingIndicator.style = .spinning
        actionLoadingIndicator.controlSize = .small
        actionLoadingIndicator.isIndeterminate = true
        actionLoadingIndicator.isHidden = true
        actionLoadingIndicator.appearance = NSAppearance(named: .darkAqua)
        actionButton.addSubview(actionLoadingIndicator)
    }

    private func setupSubtitleLabel() {
        subtitleLabel.font = NSFont.systemFont(ofSize: subtitleBaseFontSize)
        subtitleLabel.textColor = Colors.hint
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.cell?.wraps = true
        subtitleLabel.cell?.usesSingleLineMode = false
        contentContainer.addSubview(subtitleLabel)
    }

    private func setupRefreshButton() {
        refreshButton.wantsLayer = true
        refreshButton.isBordered = false
        refreshButton.layer?.cornerRadius = 6
        refreshButton.layer?.backgroundColor = Colors.actionSecondary.withAlphaComponent(0.2).cgColor
        refreshButton.focusRingType = .none
        refreshButton.refusesFirstResponder = true
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        updateRefreshButtonTitle()
        contentContainer.addSubview(refreshButton)

        // 刷新加载指示器
        refreshLoadingIndicator.style = .spinning
        refreshLoadingIndicator.controlSize = .small
        refreshLoadingIndicator.isIndeterminate = true
        refreshLoadingIndicator.isHidden = true
        refreshLoadingIndicator.appearance = NSAppearance(named: .darkAqua)
        refreshButton.addSubview(refreshLoadingIndicator)
    }

    private func setupStatusGesture() {
        let tapGesture = NSClickGestureRecognizer(target: self, action: #selector(statusAreaTapped))
        statusContainer.addGestureRecognizer(tapGesture)
    }

    // MARK: - 公开方法

    /// 显示加载状态
    func showLoading(title: String) {
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)

        deviceGlyphView.isHidden = true

        titleLabel.stringValue = title
        titleLabel.textColor = Colors.titleSecondary

        statusContainer.isHidden = true
        actionButton.isHidden = true
        subtitleLabel.isHidden = true
        refreshButton.isHidden = true

        needsLayout = true
    }

    /// 显示空态等待页
    /// - 统一文案：标题「等待手机连接」+ 一行说明，不再按 iOS / Android 区分
    /// - 参数保留是为了不改动 DevicePanelView 的调用点，文案由本视图统一提供
    func showDisconnected(title: String, subtitle: String) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true

        deviceGlyphView.isHidden = false

        titleLabel.stringValue = L10n.overlayUI.waitingForDevice
        titleLabel.textColor = Colors.title

        statusIndicator.isHidden = true
        statusLabel.stringValue = ""
        statusContainer.isHidden = true

        // 「开始投屏」入口已取消：投屏统一从「连接设备」面板发起
        actionButton.isHidden = true

        subtitleLabel.stringValue = L10n.overlayUI.waitingHint
        subtitleLabel.textColor = Colors.hint
        subtitleLabel.isHidden = false

        refreshButton.isHidden = true

        needsLayout = true
    }

    /// 显示已检测到设备（尚未开始投屏）的状态
    /// 仍是等待页，只在下方补一行「设备名 · 状态」，避免画面区域出现大按钮
    func showConnected(
        deviceName: String,
        statusText: String,
        statusColor: NSColor,
        hasWarning: Bool,
        subtitle: String,
        showRefresh: Bool
    ) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true

        deviceGlyphView.isHidden = false

        titleLabel.stringValue = L10n.overlayUI.waitingForDevice
        titleLabel.textColor = Colors.title

        statusContainer.isHidden = false
        statusIndicator.isHidden = false
        statusIndicator.layer?.backgroundColor = statusColor.cgColor
        // 状态行保持紧凑：只显示设备名（状态详情在副标题里），过长时省略而不是撑破边框
        statusLabel.stringValue = hasWarning ? "⚠️ \(deviceName)" : deviceName
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.usesSingleLineMode = true
        statusLabel.textColor = hasWarning ? statusColor : Colors.status

        // 投屏启动后由面板切到渲染视图，这里不再提供「开始投屏」按钮
        actionButton.isHidden = true

        subtitleLabel.stringValue = subtitle.isEmpty ? L10n.overlayUI.waitingHint : subtitle
        subtitleLabel.textColor = Colors.hint
        subtitleLabel.isHidden = false

        refreshButton.isHidden = !showRefresh
        stopRefreshLoading()

        needsLayout = true
    }

    /// 显示工具链缺失状态
    func showToolchainMissing(toolName: String, hint: String) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true

        deviceGlyphView.isHidden = true

        titleLabel.stringValue = L10n.overlayUI.toolNotInstalled(toolName)
        titleLabel.textColor = .systemOrange

        statusContainer.isHidden = false
        statusIndicator.isHidden = false
        statusIndicator.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusLabel.stringValue = L10n.overlayUI.needInstall(toolName)
        statusLabel.textColor = .systemOrange

        setActionButtonTitle(L10n.overlayUI.installTool(toolName))
        actionButton.isEnabled = true
        actionButton.isHidden = false

        subtitleLabel.stringValue = hint
        subtitleLabel.textColor = Colors.hint
        subtitleLabel.isHidden = false

        refreshButton.isHidden = true

        needsLayout = true
    }

    /// 设置操作按钮的启用状态
    func setActionButtonEnabled(_ enabled: Bool) {
        actionButton.isEnabled = enabled
        actionButton.alphaValue = enabled ? 1.0 : 0.7
    }

    /// 开始操作按钮加载状态
    func startActionLoading() {
        actionButton.isEnabled = false
        actionButton.alphaValue = 0.7
        actionButton.attributedTitle = NSAttributedString(string: "")
        actionLoadingIndicator.isHidden = false
        actionLoadingIndicator.startAnimation(nil)
    }

    /// 停止操作按钮加载状态
    func stopActionLoading() {
        actionButton.isEnabled = true
        actionButton.alphaValue = 1.0
        actionLoadingIndicator.stopAnimation(nil)
        actionLoadingIndicator.isHidden = true
        setActionButtonTitle(L10n.overlayUI.startCapture)
    }

    // MARK: - 私有方法

    private func setActionButtonTitle(_ title: String) {
        let buttonFont = NSFont.systemFont(ofSize: 16, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: buttonFont,
        ]
        actionButton.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    private func updateRefreshButtonTitle() {
        let buttonFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: Colors.actionSecondary,
            .font: buttonFont,
        ]
        refreshButton.attributedTitle = NSAttributedString(
            string: L10n.common.refresh,
            attributes: attributes
        )
    }

    private func startRefreshLoading() {
        refreshButton.isEnabled = false
        refreshLoadingIndicator.isHidden = false
        refreshLoadingIndicator.startAnimation(nil)
    }

    private func stopRefreshLoading() {
        refreshButton.isEnabled = true
        refreshLoadingIndicator.stopAnimation(nil)
        refreshLoadingIndicator.isHidden = true
    }

    // MARK: - 操作

    @objc private func actionTapped() {
        onActionTapped?()
    }

    @objc private func refreshTapped() {
        startRefreshLoading()
        onRefreshTapped? { [weak self] in
            DispatchQueue.main.async {
                self?.stopRefreshLoading()
            }
        }
    }

    @objc private func statusAreaTapped() {
        onStatusTapped?()
    }

    // MARK: - 本地化

    /// 更新本地化文本（等待页文案在 showDisconnected / showConnected 里统一取，无需缓存）
    func updateLocalizedTexts() {
        updateRefreshButtonTitle()
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        layoutContent()
    }

    // MARK: - 字体自适应

    /// 根据可用宽度更新字体大小
    private func updateFontsForWidth(_ availableWidth: CGFloat) {
        guard availableWidth > 0 else { return }

        // 更新标题标签字体
        let titleFont = titleLabel.stringValue.calculateFittingFont(
            baseSize: titleBaseFontSize,
            minSize: titleMinFontSize,
            weight: .semibold,
            availableWidth: availableWidth
        )
        titleLabel.font = titleFont

        // 更新副标题标签字体
        let subtitleFont = subtitleLabel.stringValue.calculateFittingFont(
            baseSize: subtitleBaseFontSize,
            minSize: subtitleMinFontSize,
            weight: .regular,
            availableWidth: availableWidth
        )
        subtitleLabel.font = subtitleFont
    }

    private func layoutContent() {
        let availableWidth = max(0, bounds.width - 40)
        updateFontsForWidth(availableWidth)

        let glyphSize = CGSize(width: deviceGlyphSize, height: deviceGlyphSize)
        let loadingSize = CGSize(width: 32, height: 32)
        let titleSize = labelSize(titleLabel, maxWidth: availableWidth)
        let statusLabelSize = statusLabel.intrinsicContentSize
        // NSTextField 的 intrinsicContentSize 比实际绘制宽度略窄，直接用它当 frame 宽会吃掉最后一个字
        let statusLabelWidth = min(ceil(statusLabelSize.width) + 8, max(0, availableWidth - 18))
        let statusContainerWidth = min(availableWidth, 18 + ceil(statusLabelWidth))
        let statusContainerHeight = max(10, ceil(statusLabelSize.height) + 2)
        let actionSize = actionButton.intrinsicContentSize
        let subtitleSize = labelSize(subtitleLabel, maxWidth: availableWidth)
        let refreshSize = refreshButton.intrinsicContentSize

        let elements: [(NSView, CGFloat, CGSize)] = [
            (deviceGlyphView, 0, glyphSize),
            (loadingIndicator, 0, loadingSize),
            (titleLabel, 16, titleSize),
            (statusContainer, 12, CGSize(width: statusContainerWidth, height: statusContainerHeight)),
            (actionButton, 20, actionSize),
            (subtitleLabel, 12, subtitleSize),
            (refreshButton, 14, refreshSize),
        ]

        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        var visibleElements: [(NSView, CGFloat, CGSize)] = []

        for (view, spacing, size) in elements where !view.isHidden {
            let spacingToApply = visibleElements.isEmpty ? 0 : spacing
            totalHeight += spacingToApply + size.height
            maxWidth = max(maxWidth, size.width)
            visibleElements.append((view, spacingToApply, size))
        }

        let contentWidth = max(availableWidth, 0)
        contentContainer.frame = CGRect(
            x: (bounds.width - contentWidth) / 2,
            y: (bounds.height - totalHeight) / 2,
            width: contentWidth,
            height: totalHeight
        )

        // 从顶部开始向下布局（macOS 默认坐标系原点在左下角）
        var y: CGFloat = totalHeight
        for (view, spacing, size) in visibleElements {
            y -= spacing // 先减去与前一个元素的间距
            y -= size.height
            // 文本类视图用满容器宽度，避免单行被截断（对齐方式仍是居中）
            let wide = (view === titleLabel || view === subtitleLabel) ? contentWidth : size.width
            view.frame = CGRect(
                x: (contentWidth - wide) / 2,
                y: y,
                width: wide,
                height: size.height
            )
        }
        statusIndicator.frame = CGRect(x: 0, y: (statusContainerHeight - 10) / 2, width: 10, height: 10)
        statusLabel.frame = CGRect(
            x: 10 + 8,
            y: (statusContainerHeight - statusLabelSize.height) / 2,
            width: statusLabelWidth,
            height: max(10, min(statusLabelSize.height, statusContainerHeight))
        )

        actionLoadingIndicator.frame = CGRect(
            x: (actionSize.width - 16) / 2,
            y: (actionSize.height - 16) / 2,
            width: 16,
            height: 16
        )
        refreshLoadingIndicator.frame = CGRect(
            x: (refreshSize.width - 16) / 2,
            y: (refreshSize.height - 16) / 2,
            width: 16,
            height: 16
        )
    }

    /// 计算标签在限定宽度下换行后的尺寸
    private func labelSize(_ label: NSTextField, maxWidth: CGFloat) -> CGSize {
        guard !label.stringValue.isEmpty else { return .zero }
        let attributed = NSAttributedString(
            string: label.stringValue,
            attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 14)]
        )
        let bounding = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // 高度多留 4pt：boundingRect 用字体 leading 估算，行高可能比实际略小，
        // 少算一点点会导致最后一行被裁掉（表现为文字突然截断且没有省略号）
        return CGSize(width: min(maxWidth, ceil(bounding.width) + 2), height: ceil(bounding.height) + 4)
    }
}

// MARK: - 字号自适应

extension String {
    /// 在可用宽度内计算不换行时的最大字号（不低于 minSize）
    func calculateFittingFont(
        baseSize: CGFloat,
        minSize: CGFloat,
        weight: NSFont.Weight,
        availableWidth: CGFloat
    ) -> NSFont {
        guard availableWidth > 0, !isEmpty else {
            return NSFont.systemFont(ofSize: baseSize, weight: weight)
        }
        var size = baseSize
        while size > minSize {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            let width = (self as NSString).size(withAttributes: [.font: font]).width
            if width <= availableWidth { break }
            size -= 1
        }
        return NSFont.systemFont(ofSize: max(size, minSize), weight: weight)
    }
}
