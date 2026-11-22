//
//  DeviceGridView.swift
//  StageCast
//
//  多设备网格布局容器（阶段二）
//  - 面板槽位池：按需创建/释放 DevicePanelView
//  - 分页：每页设备数来自偏好（自动/1/4/6/9/16）
//  - 非当前页暂停渲染（连接保持，仅停止 Metal 绘制）
//

import AppKit

// MARK: - 网格设备项

/// 网格中的一个设备槽位描述（由调用方按捕获中的设备生成）
struct DeviceGridItem {
    /// 设备唯一标识：Android 用 serial，iOS 用设备 id
    let id: String
    let platform: DevicePlatform
}

// MARK: - 网格容器

final class DeviceGridView: NSView {
    // MARK: - 联动回调

    /// 新面板已创建并分配给某个设备（调用方负责接线：帧回调、输入、状态展示）
    var onPanelAssigned: ((DevicePanelView, DeviceGridItem) -> Void)?

    /// 面板即将释放（调用方解除接线）
    var onPanelReleased: ((DevicePanelView) -> Void)?

    // MARK: - 状态

    private(set) var items: [DeviceGridItem] = []
    private(set) var panelsByID: [String: DevicePanelView] = [:]
    /// 自动排列：由设备数量决定行列数，且不分页
    var usesAutoGrid = false
    private(set) var currentPage = 0
    private(set) var pageCount = 1

    // MARK: - 分隔条

    /// 列分隔条池（最多 3 条，对应 4 列）
    private var columnDividers: [LayoutDividerView] = []
    /// 行分隔条池（最多 3 条，对应 4 行）
    private var rowDividers: [LayoutDividerView] = []
    /// 当前页生效的列分割点（relayout 时刷新，供拖拽回调换算）
    private var activeColumnPoints: [CGFloat] = []
    /// 当前页生效的行分割点
    private var activeRowPoints: [CGFloat] = []

    // MARK: - 拖拽换位

    /// 每格右上角的拖拽换位手柄（itemID → 手柄）
    private var gripViews: [String: GridCellGripView] = [:]
    /// 拖拽目标高亮框
    private lazy var swapHighlightView: NSView = {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        view.isHidden = true
        return view
    }()

    /// 拖拽换位结束后回调（新的设备顺序，按网格内顺序）
    var onItemsReordered: (([String]) -> Void)?

    /// 双击画面的外部接管（返回 true 表示已处理，不再走聚焦逻辑）
    /// 单设备 fit 模式下用它实现「双击画面恢复贴合比例」
    var onDoubleClickOverride: ((String) -> Bool)?

    // MARK: - 分页 UI

    /// 当前双击聚焦的设备（nil = 网格模式）
    private(set) var focusedItemID: String?

    /// 聚焦模式左上角的返回网格按钮
    private(set) lazy var backButton: NSButton = {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = true
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        button.layer?.cornerRadius = 12
        button.contentTintColor = .white
        button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        button.attributedTitle = NSAttributedString(
            string: L10n.layout.returnToGrid,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]
        )
        button.target = self
        button.action = #selector(backToGridTapped)
        button.isHidden = true
        button.toolTip = L10n.layout.returnToGrid
        return button
    }()

    private let paginationBar = NSView()
    private let prevButton = NSButton(frame: .zero)
    private let nextButton = NSButton(frame: .zero)
    private var dotButtons: [NSButton] = []
    private var dotLayers: [CALayer] = []

    // MARK: - 布局常量

    private enum Metrics {
        static let spacing: CGFloat = 14
        static let outerPadding: CGFloat = 12
        static let paginationHeight: CGFloat = 30
        static let paginationDotSize: CGFloat = 8
        static let paginationDotSpacing: CGFloat = 10
        static let fallbackAspect: CGFloat = 9.0 / 19.5
    }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupPaginationBar()
        setupBackButton()
        setupSwapHighlight()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGridPageSizeChange),
            name: .gridPageSizeDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPaginationBar()
        setupBackButton()
        setupSwapHighlight()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 对外接口

    /// 回收全部面板（切换布局模式时调用：避免同一设备同时存在网格面板与浮窗面板，
    /// 两者的帧观察者令牌都记在设备 ID 下，会互相顶掉导致回到网格后画面全黑）
    func resetAllPanels() {
        for (id, panel) in panelsByID {
            panelsByID.removeValue(forKey: id)
            onPanelReleased?(panel)
            panel.removeFromSuperview()
        }
    }

    /// 以最新设备列表刷新网格（差分更新面板，重算分页，调整渲染开关）
    func update(items newItems: [DeviceGridItem]) {
        items = newItems

        // 差分：移除消失的设备面板
        let newIDs = Set(items.map(\.id))
        for (id, panel) in panelsByID where !newIDs.contains(id) {
            panelsByID.removeValue(forKey: id)
            onPanelReleased?(panel)
            panel.removeFromSuperview()
        }
        // 聚焦的设备被移除时退出聚焦（并清持久化）
        if let focusID = focusedItemID, !newIDs.contains(focusID) {
            focusedItemID = nil
            UserPreferences.shared.gridFocusedDeviceID = nil
        }

        // 启动/重连后恢复持久化的聚焦设备（设备已在线且面板已建）
        if focusedItemID == nil, let savedID = UserPreferences.shared.gridFocusedDeviceID,
           panelsByID[savedID] != nil {
            focusedItemID = savedID
        }

        // 差分：新增设备面板
        for item in items where panelsByID[item.id] == nil {
            let panel = DevicePanelView()
            panel.translatesAutoresizingMaskIntoConstraints = true
            // 双击面板 → 聚焦（可在设置中关闭）；聚焦状态下再双击 → 返回网格
            panel.onDoubleClick = { [weak self, weak panel] in
                guard let self, let panel, panel === self.panelsByID[item.id] else { return }
                // 外部可优先接管双击（例如 fit 模式下双击恢复贴合画面比例）
                if self.onDoubleClickOverride?(item.id) == true { return }
                if self.focusedItemID == item.id {
                    self.exitFocus()
                } else if UserPreferences.shared.gridDoubleClickFocusEnabled {
                    self.focusItem(item.id)
                }
            }
            panelsByID[item.id] = panel
            addSubview(panel)
            onPanelAssigned?(panel, item)
        }

        // 分页总数与当前页收敛
        let pageSize = effectivePageSize
        pageCount = max(1, Int(ceil(Double(items.count) / Double(max(pageSize, 1)))))
        if currentPage >= pageCount {
            currentPage = pageCount - 1
        }
        if currentPage < 0 {
            currentPage = 0
        }

        needsLayout = true
        relayout()
        refreshPagination()
    }

    /// 刷新到指定页
    func goToPage(_ page: Int) {
        let clamped = min(max(page, 0), pageCount - 1)
        guard clamped != currentPage else { return }
        currentPage = clamped
        relayout()
        refreshPagination()
    }

    // MARK: - 页大小

    /// 生效的每页设备数（0 = 自动：选 ≥ 设备数的最小预设）
    var effectivePageSize: Int {
        if usesAutoGrid { return max(items.count, 1) }
        let pref = UserPreferences.shared.gridPageSize
        if pref > 0 { return pref }
        let count = max(items.count, 1)
        return UserPreferences.gridPageSizePresets.first { $0 >= count } ?? 16
    }

    /// 自动排列的行列数：按设备数选最贴近窗口的形状
    static func autoDimensions(for count: Int) -> (cols: Int, rows: Int) {
        switch count {
        case ...1: return (1, 1)
        case 2: return (2, 1)
        case 3: return (3, 1)      // 3 台：一行三列
        case 4: return (2, 2)
        case 5...6: return (3, 2)
        case 7...9: return (3, 3)
        case 10...12: return (4, 3)
        default: return (4, 4)
        }
    }

    /// 每页规模 → 行列数
    private func gridDimensions(forPageSize size: Int) -> (cols: Int, rows: Int) {
        switch size {
        case 1: return (1, 1)
        case 2: return (2, 1)
        case 3: return (1, 3)   // 3 台：1×3（一列三行，竖屏手机并排观感最佳）
        case 4: return (2, 2)
        case 6: return (3, 2)
        case 9: return (3, 3)
        case 16: return (4, 4)
        default: return (2, 2)
        }
    }

    /// 解析分隔点：偏好长度不匹配当前行列数时回退均分（累计比例，升序，0-1）
    private func resolvedSplitPoints(count: Int, pref: [CGFloat]) -> [CGFloat] {
        guard count > 1 else { return [] }
        let segments = count - 1
        if pref.count == segments {
            // 防御：确保严格递增且在有效范围内
            var previous: CGFloat = 0.1
            let sanitized = pref.map { value -> CGFloat in
                let clamped = min(max(value, previous), 0.95)
                previous = clamped + 0.02
                return clamped
            }
            return sanitized
        }
        return (1...segments).map { CGFloat($0) / CGFloat(count) }
    }

    /// 确保分隔条池已建立
    private func ensureDividers() {
        if columnDividers.isEmpty {
            for index in 0..<3 {
                let divider = LayoutDividerView(axis: .horizontal)
                divider.isHidden = true
                addSubview(divider)
                divider.onDrag = { [weak self] position in
                    self?.handleColumnDrag(dividerIndex: index, position: position)
                }
                divider.onDragEnded = { [weak self] in
                    self?.relayout()
                }
                columnDividers.append(divider)
            }
        }
        if rowDividers.isEmpty {
            for index in 0..<3 {
                let divider = LayoutDividerView(axis: .vertical)
                divider.isHidden = true
                addSubview(divider)
                divider.onDrag = { [weak self] position in
                    self?.handleRowDrag(dividerIndex: index, position: position)
                }
                divider.onDragEnded = { [weak self] in
                    self?.relayout()
                }
                rowDividers.append(divider)
            }
        }
    }

    /// 列分隔条拖拽：归一化窗口坐标 → 网格内比例
    private func handleColumnDrag(dividerIndex: Int, position: CGFloat) {
        let bounds = self.bounds
        let gridRect = bounds.insetBy(dx: Metrics.outerPadding, dy: Metrics.outerPadding)
        let usableWidth = gridRect.width
        guard usableWidth > 0, activeColumnPoints.indices.contains(dividerIndex) else { return }
        var points = activeColumnPoints
        let ratio = (position * bounds.width - gridRect.minX) / usableWidth
        let lower = dividerIndex > 0 ? points[dividerIndex - 1] + 0.08 : 0.12
        let upper = dividerIndex < points.count - 1 ? points[dividerIndex + 1] - 0.08 : 0.88
        points[dividerIndex] = min(max(ratio, lower), upper)
        activeColumnPoints = points
        UserPreferences.shared.gridColumnSplit = points
        relayout()
    }

    /// 行分隔条拖拽：注意 AppKit y 轴向上，分割点按从顶部累计
    private func handleRowDrag(dividerIndex: Int, position: CGFloat) {
        let bounds = self.bounds
        let gridRect = bounds.insetBy(dx: Metrics.outerPadding, dy: Metrics.outerPadding)
        let usableHeight = gridRect.height
        guard usableHeight > 0, activeRowPoints.indices.contains(dividerIndex) else { return }
        var points = activeRowPoints
        // position 是父视图归一化 y（向上），换算为「从顶部算」的累计比例
        let ratio = 1 - (position * bounds.height - bounds.minY) / usableHeight
        let lower = dividerIndex > 0 ? points[dividerIndex - 1] + 0.08 : 0.12
        let upper = dividerIndex < points.count - 1 ? points[dividerIndex + 1] - 0.08 : 0.88
        points[dividerIndex] = min(max(ratio, lower), upper)
        activeRowPoints = points
        UserPreferences.shared.gridRowSplit = points
        relayout()
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        let bounds = self.bounds
        guard bounds.width > 40, bounds.height > 40 else { return }

        let pageSize = effectivePageSize
        let (cols, rows) = usesAutoGrid
            ? Self.autoDimensions(for: max(items.count, 1))
            : gridDimensions(forPageSize: pageSize)
        let showPagination = pageCount > 1

        // 可用区域：分页条在底部时预留高度
        // 单设备自动排列 → 满铺（窗口内不留任何留白黑边）
        let singleFullBleed = usesAutoGrid && items.count == 1 && !showPagination
        let padding: CGFloat = singleFullBleed ? 0 : Metrics.outerPadding
        let gap: CGFloat = singleFullBleed ? 0 : Metrics.spacing
        let bottomReserve: CGFloat = showPagination ? Metrics.paginationHeight + 4 : 0
        let gridRect = bounds.insetBy(dx: padding, dy: padding)
        let usableHeight = gridRect.height - bottomReserve
        let usableWidth = gridRect.width

        // 双击聚焦模式：聚焦面板铺满整个网格区（含分页区），其余面板隐藏并停渲染
        if let focusID = focusedItemID, let focusPanel = panelsByID[focusID],
           items.contains(where: { $0.id == focusID }) {
            let aspect = max(focusPanel.deviceAspectRatio, 0.2)
            let focusRect = bounds.insetBy(dx: Metrics.outerPadding, dy: Metrics.outerPadding)
            var panelFrame = focusRect
            let rectAspect = focusRect.width / max(focusRect.height, 1)
            if rectAspect > aspect {
                let width = focusRect.height * aspect
                panelFrame = CGRect(
                    x: focusRect.midX - width / 2,
                    y: focusRect.minY,
                    width: width,
                    height: focusRect.height
                )
            } else {
                let height = focusRect.width / aspect
                panelFrame = CGRect(
                    x: focusRect.minX,
                    y: focusRect.midY - height / 2,
                    width: focusRect.width,
                    height: height
                )
            }
            focusPanel.frame = panelFrame
            focusPanel.isHidden = false
            if !focusPanel.renderView.isRendering {
                focusPanel.renderView.startRendering()
            }

            for (id, panel) in panelsByID where id != focusID {
                panel.isHidden = true
                if panel.renderView.isRendering {
                    panel.renderView.stopRendering()
                }
            }

            for divider in columnDividers {
                divider.isHidden = true
            }
            for divider in rowDividers {
                divider.isHidden = true
            }
            paginationBar.isHidden = true
            for grip in gripViews.values {
                grip.isHidden = true
            }
            swapHighlightView.isHidden = true

            // 返回网格按钮：左上角悬浮
            backButton.isHidden = false
            let fitting = backButton.fittingSize
            let buttonWidth = max(fitting.width + 18, 96)
            let buttonHeight = max(26, fitting.height + 8)
            backButton.frame = CGRect(
                x: focusRect.minX + 6,
                y: focusRect.maxY - buttonHeight - 6,
                width: buttonWidth,
                height: buttonHeight
            )
            return
        }
        if !backButton.isHidden {
            backButton.isHidden = true
        }

        // 分隔点：支持拖拽记忆比例（偏好长度不匹配时均分）
        let colPoints = resolvedSplitPoints(count: cols, pref: UserPreferences.shared.gridColumnSplit)
        let rowPoints = resolvedSplitPoints(count: rows, pref: UserPreferences.shared.gridRowSplit)
        activeColumnPoints = colPoints
        activeRowPoints = rowPoints
        ensureDividers()

        // 当前页可见的设备
        let startIndex = currentPage * pageSize
        let endIndex = min(startIndex + pageSize, items.count)
        let visibleItems = Array(items[startIndex..<max(startIndex, endIndex)])

        var panelIndex = 0
        for item in visibleItems {
            guard let panel = panelsByID[item.id] else { continue }

            let col = panelIndex % cols
            let row = panelIndex / cols
            panelIndex += 1

            // 列/行边界（不含 spacing；分割点从左/上累计）
            let colStart = col == 0 ? 0 : colPoints[col - 1]
            let colEnd = col == cols - 1 ? 1 : colPoints[col]
            let rowTop = row == 0 ? 0 : rowPoints[row - 1]
            let rowBottom = row == rows - 1 ? 1 : rowPoints[row]

            let cellRect = CGRect(
                x: gridRect.minX + colStart * usableWidth + gap / 2,
                y: gridRect.minY + usableHeight - rowBottom * usableHeight + gap / 2,
                width: (colEnd - colStart) * usableWidth - gap,
                height: (rowBottom - rowTop) * usableHeight - gap
            )

            // 单元格内按设备宽高比居中放置面板
            let aspect = max(panel.deviceAspectRatio, 0.2)
            var panelFrame = cellRect
            let cellAspect = cellRect.width / max(cellRect.height, 1)
            if cellAspect > aspect {
                // 单元格更宽：以高度为准
                let width = cellRect.height * aspect
                panelFrame = CGRect(
                    x: cellRect.midX - width / 2,
                    y: cellRect.minY,
                    width: width,
                    height: cellRect.height
                )
            } else {
                // 单元格更高：以宽度为准
                let height = cellRect.width / aspect
                panelFrame = CGRect(
                    x: cellRect.minX,
                    y: cellRect.midY - height / 2,
                    width: cellRect.width,
                    height: height
                )
            }
            panel.frame = panelFrame
            panel.isHidden = false
        }

        // 非当前页面板：隐藏 + 暂停渲染（连接保持）
        for (id, panel) in panelsByID {
            let visible = visibleItems.contains { $0.id == id }
            if !visible {
                panel.isHidden = true
            }
            if visible {
                if !panel.renderView.isRendering {
                    panel.renderView.startRendering()
                }
            } else if panel.renderView.isRendering {
                panel.renderView.stopRendering()
            }
        }

        // 分隔条摆放：仅当分割点两侧都有面板时显示
        let dividerThickness: CGFloat = 10
        for (index, divider) in columnDividers.enumerated() {
            let shouldShow = index < colPoints.count && visibleItems.count > index + 1
            if shouldShow {
                let x = gridRect.minX + colPoints[index] * usableWidth - dividerThickness / 2
                divider.frame = CGRect(x: x, y: gridRect.minY, width: dividerThickness, height: usableHeight)
                divider.isHidden = false
            } else {
                divider.isHidden = true
            }
        }
        for (index, divider) in rowDividers.enumerated() {
            let shouldShow = index < rowPoints.count && visibleItems.count > (index + 1) * cols
            if shouldShow {
                let y = gridRect.minY + usableHeight * (1 - rowPoints[index]) - dividerThickness / 2
                divider.frame = CGRect(x: gridRect.minX, y: y, width: usableWidth, height: dividerThickness)
                divider.isHidden = false
            } else {
                divider.isHidden = true
            }
        }

        // 分隔条必须压在面板与各类浮层之上，否则收不到鼠标事件
        for divider in columnDividers where !divider.isHidden {
            addSubview(divider, positioned: .above, relativeTo: nil)
        }
        for divider in rowDividers where !divider.isHidden {
            addSubview(divider, positioned: .above, relativeTo: nil)
        }

        // 分页条位置
        if showPagination {
            paginationBar.isHidden = false
            paginationBar.frame = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: Metrics.paginationHeight + 2
            )
            layoutPagination()
        } else {
            paginationBar.isHidden = true
        }

        // 拖拽换位手柄（置于可见面板右上角）
        updateGrips(for: visibleItems)
    }

    // MARK: - 拖拽换位

    private func setupSwapHighlight() {
        swapHighlightView.isHidden = true
        addSubview(swapHighlightView)
    }

    private func ensureGrip(for id: String) -> GridCellGripView {
        if let grip = gripViews[id] { return grip }
        let grip = GridCellGripView()
        grip.onDragMove = { [weak self] position in
            self?.handleGripDragMove(sourceID: id, position: position)
        }
        grip.onDragEnd = { [weak self] position in
            self?.handleGripDragEnd(sourceID: id, position: position)
        }
        grip.onTap = { [weak self] in
            self?.swapWithNeighbor(id: id)
        }
        gripViews[id] = grip
        addSubview(grip)
        return grip
    }

    /// relayout 末尾调用：摆放/隐藏各格拖拽手柄
    private func updateGrips(for visibleItems: [DeviceGridItem]) {
        let visibleIDs = Set(visibleItems.map(\.id))
        for (id, grip) in gripViews where !visibleIDs.contains(id) {
            grip.removeFromSuperview()
            gripViews.removeValue(forKey: id)
        }
        let shouldShow = focusedItemID == nil && visibleItems.count > 1
        guard shouldShow else {
            for grip in gripViews.values { grip.isHidden = true }
            return
        }
        for item in visibleItems {
            let grip = ensureGrip(for: item.id)
            if let panel = panelsByID[item.id], !panel.isHidden {
                grip.frame = CGRect(
                    x: panel.frame.maxX - 24,
                    y: panel.frame.maxY - 24,
                    width: 20,
                    height: 20
                )
                grip.isHidden = false
            } else {
                grip.isHidden = true
            }
        }
    }

    /// 当前页可见设备
    private func visibleItemsInPage(_ page: Int) -> [DeviceGridItem] {
        let pageSize = effectivePageSize
        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, items.count)
        guard startIndex < endIndex else { return [] }
        return Array(items[startIndex..<endIndex])
    }

    /// 命中检测：拖拽点落在哪个可见面板上
    private func hitVisibleItem(at position: NSPoint) -> String? {
        for item in visibleItemsInPage(currentPage) {
            if let panel = panelsByID[item.id], !panel.isHidden, panel.frame.contains(position) {
                return item.id
            }
        }
        return nil
    }

    private func handleGripDragMove(sourceID: String, position: NSPoint) {
        guard let targetID = hitVisibleItem(at: position), targetID != sourceID,
              let panel = panelsByID[targetID] else {
            swapHighlightView.isHidden = true
            return
        }
        swapHighlightView.frame = panel.frame.insetBy(dx: -3, dy: -3)
        swapHighlightView.isHidden = false
    }

    private func handleGripDragEnd(sourceID: String, position: NSPoint) {
        swapHighlightView.isHidden = true
        // 无论换位是否成功都要重排：拖到格子外松手时，手柄需要归位到单元格内，
        // 否则会停留在半空（旧实现直接 return，grip 就留在原地）
        defer {
            needsLayout = true
            relayout()
            refreshPagination()
        }
        guard let targetID = hitVisibleItem(at: position), targetID != sourceID,
              let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else { return }
        items.swapAt(sourceIndex, targetIndex)
        onItemsReordered?(items.map(\.id))
    }

    /// 单击手柄：与同页「下一格」互换位置（最后一格则与第一格互换）
    /// 拖拽换位需要瞄准另一格，单击换位适合两台设备快速对调。
    private func swapWithNeighbor(id: String) {
        let visible = visibleItemsInPage(currentPage)
        guard visible.count > 1,
              let sourceIndex = items.firstIndex(where: { $0.id == id }),
              let visibleIndex = visible.firstIndex(where: { $0.id == id }) else { return }
        let neighborVisibleIndex = (visibleIndex + 1) % visible.count
        let neighborID = visible[neighborVisibleIndex].id
        guard let targetIndex = items.firstIndex(where: { $0.id == neighborID }) else { return }
        items.swapAt(sourceIndex, targetIndex)
        onItemsReordered?(items.map(\.id))
        needsLayout = true
        relayout()
    }

    // MARK: - 双击聚焦

    /// 聚焦某个设备面板（铺满网格区）
    func focusItem(_ id: String) {
        guard panelsByID[id] != nil, focusedItemID != id else { return }
        focusedItemID = id
        UserPreferences.shared.gridFocusedDeviceID = id
        needsLayout = true
        relayout()
    }

    /// 退出聚焦，回到网格
    func exitFocus() {
        guard focusedItemID != nil else { return }
        focusedItemID = nil
        UserPreferences.shared.gridFocusedDeviceID = nil
        needsLayout = true
        relayout()
    }

    private func setupBackButton() {
        backButton.isHidden = true
        addSubview(backButton)
    }

    @objc private func backToGridTapped() {
        exitFocus()
    }

    // MARK: - 分页条

    private func setupPaginationBar() {
        paginationBar.translatesAutoresizingMaskIntoConstraints = true
        paginationBar.isHidden = true
        addSubview(paginationBar)

        configureArrowButton(prevButton, symbol: "chevron.left", action: #selector(prevPageTapped))
        configureArrowButton(nextButton, symbol: "chevron.right", action: #selector(nextPageTapped))
    }

    private func configureArrowButton(_ button: NSButton, symbol: String, action: Selector) {
        button.isBordered = false
        button.isTransparent = false
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = true
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.75)]))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        paginationBar.addSubview(button)
    }

    private func refreshPagination() {
        // 重建圆点
        for dot in dotButtons {
            dot.removeFromSuperview()
        }
        dotButtons.removeAll()
        dotLayers.removeAll()

        for index in 0..<pageCount {
            let dot = NSButton(frame: .zero)
            dot.isBordered = false
            dot.target = self
            dot.action = #selector(dotTapped(_:))
            dot.tag = index
            dot.toolTip = String(index + 1)
            dot.translatesAutoresizingMaskIntoConstraints = true
            dot.wantsLayer = true
            dot.layer?.cornerRadius = Metrics.paginationDotSize / 2
            paginationBar.addSubview(dot)
            dotButtons.append(dot)
            if let layer = dot.layer {
                dotLayers.append(layer)
            }
        }

        layoutPagination()
    }

    private func layoutPagination() {
        let barBounds = paginationBar.bounds
        let centerY = barBounds.midY

        // 圆点组整体宽度
        let dotsWidth = CGFloat(dotButtons.count) * Metrics.paginationDotSize
            + CGFloat(max(dotButtons.count - 1, 0)) * Metrics.paginationDotSpacing
        let dotsX = barBounds.midX - dotsWidth / 2

        for (index, dot) in dotButtons.enumerated() {
            dot.frame = CGRect(
                x: dotsX + CGFloat(index) * (Metrics.paginationDotSize + Metrics.paginationDotSpacing),
                y: centerY - Metrics.paginationDotSize / 2,
                width: Metrics.paginationDotSize,
                height: Metrics.paginationDotSize
            )
        }
        updateDotStyles()

        // 左右箭头贴着圆点两侧
        let arrowSize: CGFloat = 22
        let gap: CGFloat = 10
        prevButton.frame = CGRect(
            x: dotsX - gap - arrowSize,
            y: centerY - arrowSize / 2,
            width: arrowSize,
            height: arrowSize
        )
        nextButton.frame = CGRect(
            x: dotsX + dotsWidth + gap,
            y: centerY - arrowSize / 2,
            width: arrowSize,
            height: arrowSize
        )
        prevButton.isEnabled = currentPage > 0
        nextButton.isEnabled = currentPage < pageCount - 1
        prevButton.alphaValue = prevButton.isEnabled ? 1.0 : 0.35
        nextButton.alphaValue = nextButton.isEnabled ? 1.0 : 0.35
    }

    private func updateDotStyles() {
        for (index, layer) in dotLayers.enumerated() {
            let selected = index == currentPage
            layer.backgroundColor = (selected
                ? NSColor.white.withAlphaComponent(0.92)
                : NSColor.white.withAlphaComponent(0.32))
                .cgColor
        }
    }

    // MARK: - 动作

    @objc private func prevPageTapped() {
        goToPage(currentPage - 1)
    }

    @objc private func nextPageTapped() {
        goToPage(currentPage + 1)
    }

    @objc private func dotTapped(_ sender: NSButton) {
        goToPage(sender.tag)
    }

    @objc private func handleGridPageSizeChange() {
        currentPage = min(currentPage, max(pageCount - 1, 0))
        needsLayout = true
        relayout()
        refreshPagination()
    }
}

/// 每格右上角的换位手柄
/// 两种用法：
/// 1. 按住拖到另一格上松开 → 两格互换；
/// 2. 直接点一下 → 与「下一格」互换（不用拖，单击就能换位）。
/// 图标用 rectangle.2.swap 表达「两个画面互换」，比原来的上下箭头直观。
final class GridCellGripView: NSView {
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    /// 单击（未拖动）时触发
    var onTap: (() -> Void)?

    private var isDragging = false
    /// 按下后是否真的移动过（用于区分「单击换位」与「拖拽换位」）
    private var didMove = false
    private var mouseDownPoint: NSPoint = .zero
    private let iconView = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?

    /// 拖动判定阈值：超过 3pt 才算拖拽，否则视为单击
    private static let dragThreshold: CGFloat = 3

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        iconView.image = NSImage(
            systemSymbolName: "rectangle.2.swap",
            accessibilityDescription: L10n.layout.swapHint
        )?.withSymbolConfiguration(config)
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = L10n.layout.swapHint
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isDragging else { return }
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        restoreIdleAppearance()
    }

    private func restoreIdleAppearance() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        didMove = false
        mouseDownPoint = event.locationInWindow
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    /// 手柄自身坐标没有意义，命中检测用的是面板 frame（父视图 DeviceGridView 坐标系）
    private func gridPoint(for event: NSEvent) -> NSPoint {
        (superview ?? self).convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        if !didMove {
            let dx = abs(event.locationInWindow.x - mouseDownPoint.x)
            let dy = abs(event.locationInWindow.y - mouseDownPoint.y)
            guard dx > Self.dragThreshold || dy > Self.dragThreshold else { return }
            didMove = true
        }
        onDragMove?(gridPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        restoreIdleAppearance()
        if didMove {
            onDragEnd?(gridPoint(for: event))
        } else {
            // 没移动过 = 单击：直接和相邻格换位，不用拖
            onTap?()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 注意：不要重写 hitTest 来「无条件返回 self」——那会让手柄吞掉整个网格的点击。
    // 默认实现（convert + bounds.contains）已经把命中范围限制在 20x20 手柄内，
    // 其余区域会正常落到下层的 renderView，注入才不会被吞掉。
}