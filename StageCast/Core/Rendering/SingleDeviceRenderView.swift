//
//  SingleDeviceRenderView.swift
//  StageCast
//
//  Created by Sun on 2025/12/23.
//
//  单设备 Metal 渲染视图
//  嵌入到 DeviceBezelView 的 screenContentView 中，画面跟随设备边框动画
//

import AppKit
import CoreVideo
import Metal
import QuartzCore

// MARK: - 单设备渲染视图

final class SingleDeviceRenderView: NSView {
    // MARK: - Metal 组件

    private var metalLayer: CAMetalLayer?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    var updateTextureDebugCount = 0
    var renderDebugCount = 0
    private var samplerState: MTLSamplerState?

    // MARK: - 颜色补偿

    private var lutSamplerState: MTLSamplerState?

    /// 颜色补偿滤镜（可外部注入，支持按设备独立设置）
    var colorFilter: ColorCompensationFilter?

    // MARK: - 纹理（保持对 CVMetalTexture 的强引用，防止 MTLTexture 失效）

    private var currentCVTexture: CVMetalTexture?
    private var currentTexture: MTLTexture?
    private let textureLock = NSLock()
    /// 串行化「整帧更新 / 清空纹理」：帧观察者来自渲染线程、clearTexture 来自主线程，
    /// 两条路径同时改 frameTimestamps / 纹理缓存会破坏堆（实测 SIGSEGV _swift_release_dealloc）
    private let textureUpdateLock = NSLock()

    // MARK: - 渲染状态

    private(set) var isRendering = false
    private let renderQueue = DispatchQueue(label: "com.screenPresenter.singleRender", qos: .userInteractive)

    /// 标记是否有新帧需要渲染
    private var needsRender = false

    // MARK: - 配置

    /// 屏幕圆角半径（相对于视频显示区域，使用连续曲率圆角）
    /// 圆角只作用于 videoDisplayRect，不切到黑边
    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyCornerMask()
        }
    }

    /// 圆角遮罩层（覆盖在 videoDisplayRect 上，用反向遮罩切出圆角）
    private var cornerMaskLayer: CAShapeLayer?

    /// 按 videoDisplayRect 应用圆角遮罩
    /// 通过 mask 而非 metalLayer.cornerRadius，确保圆角只切视频区域、不影响黑边
    private func applyCornerMask() {
        guard let metalLayer else { return }

        guard cornerRadius > 0.5, let rect = videoDisplayRect, rect.width > 0, rect.height > 0 else {
            metalLayer.mask = nil
            cornerMaskLayer = nil
            return
        }

        let mask: CAShapeLayer
        if let existing = cornerMaskLayer {
            mask = existing
        } else {
            mask = CAShapeLayer()
            mask.fillColor = NSColor.white.cgColor
            cornerMaskLayer = mask
            metalLayer.mask = mask
        }

        // mask 使用 metalLayer 坐标系（与 bounds 一致）
        mask.frame = metalLayer.bounds
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        // 连续曲率在 CAShapeLayer 上不支持，用圆角矩形近似；
        // 半径本身较小，观感差异可忽略
        mask.path = path
    }

    // MARK: - 输入事件

    /// 是否允许向设备注入输入事件（iOS 面板始终为 false）
    var acceptsInputEvents = false {
        didSet {
            guard acceptsInputEvents != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            updateTrackingAreasIfNeeded()
        }
    }

    /// 输入事件回调（坐标已归一化到 0...1，原点在左上角）
    var onPointerDown: ((CGPoint, NSEvent) -> Void)?
    var onPointerMove: ((CGPoint, NSEvent) -> Void)?
    var onPointerUp: ((CGPoint, NSEvent) -> Void)?
    var onPointerHover: ((CGPoint, NSEvent) -> Void)?
    var onScroll: ((CGFloat, CGFloat, CGPoint, NSEvent) -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onPointerExit: (() -> Void)?

    /// 当前是否正在拖拽（用于区分 move 与 drag）
    private var isPointerDragging = false

    /// 追踪区域
    private var inputTrackingArea: NSTrackingArea?

    // MARK: - 统计

    private var frameTimestamps: [CFAbsoluteTime] = []
    private var _fps: Double = 0
    private let fpsLock = NSLock()

    /// 当前 FPS（线程安全）
    var fps: Double {
        get {
            fpsLock.lock()
            defer { fpsLock.unlock() }
            return _fps
        }
        set {
            fpsLock.lock()
            _fps = newValue
            fpsLock.unlock()
        }
    }

    // MARK: - 调试统计

    /// 渲染次数（周期内）
    private var renderCountInPeriod: Int = 0

    /// 纹理更新次数（周期内）
    private var textureUpdateCountInPeriod: Int = 0

    /// 上次统计时间
    private var lastRenderStatsTime = CFAbsoluteTimeGetCurrent()

    /// 渲染耗时累计
    private var totalRenderTime: Double = 0

    /// 最大渲染耗时
    private var maxRenderTime: Double = 0

    /// 纹理更新耗时累计
    private var totalTextureUpdateTime: Double = 0

    /// 最大纹理更新耗时
    private var maxTextureUpdateTime: Double = 0

    /// 纹理更新间隔
    private var lastTextureUpdateTime = CFAbsoluteTimeGetCurrent()

    /// 最大纹理更新间隔
    private var maxTextureUpdateInterval: Double = 0

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMetal()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetal()
    }

    deinit {
        stopRendering()
        // 清理纹理缓存
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    // MARK: - 视图生命周期

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        // 禁用 vsync 等待，允许帧立即呈现
        // 这可以减少延迟，但可能导致撕裂（在投屏场景中可接受）
        layer.presentsWithTransaction = false
        // 允许 triple buffering 以提高吞吐量
        layer.maximumDrawableCount = 3
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        metalLayer?.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            metalLayer?.contentsScale = window?.backingScaleFactor ?? 2.0
            updateDrawableSize()
        }
        updateTrackingAreasIfNeeded()
    }

    // MARK: - 鼠标追踪与光标

    /// 需要键盘输入时才能成为第一响应者
    override var acceptsFirstResponder: Bool { acceptsInputEvents }

    /// 命中测试：只有落在实际视频画面内才接收事件
    /// 黑边区域返回 nil，让鼠标事件穿透到下层，从而保住窗口拖拽与边框缩放
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview else { return nil }
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // 未开启输入时，整块区域都应穿透，交给窗口处理拖拽/缩放
        guard acceptsInputEvents else { return nil }

        // 开启输入时只拦截画面区域，黑边仍然穿透
        guard let rect = videoDisplayRect, rect.contains(localPoint) else { return nil }
        return self
    }

    /// 窗口未激活时首次点击也直接作用于设备，避免演示时第一下点击被吞掉
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        acceptsInputEvents
    }

    /// 关键：开启输入时禁止「点击背景拖动窗口」
    /// 若返回 true，AppKit 会在派发 mouseDown 之前就把事件用于拖窗，
    /// 导致鼠标滑动被识别为拖动窗口而不是注入到手机。
    override var mouseDownCanMoveWindow: Bool {
        !acceptsInputEvents
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingAreasIfNeeded()
    }

    private func updateTrackingAreasIfNeeded() {
        if let existing = inputTrackingArea {
            removeTrackingArea(existing)
            inputTrackingArea = nil
        }
        guard acceptsInputEvents else { return }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow,
            .inVisibleRect,
            .enabledDuringMouseDrag,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        inputTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard acceptsInputEvents else { return }
        // 用箭头光标表示“可点击的远端画面”
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - 坐标换算

    /// 把视图坐标转换为设备画面内的归一化坐标（0...1，原点左上）
    /// 画面按纵横比居中，黑边区域返回 nil
    func normalizedPoint(from event: NSEvent) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)

        // 与 Metal 渲染保持一致的 letterbox 计算
        let viewAspect = bounds.width / bounds.height
        let videoAspect: CGFloat
        if let texture = currentTextureSize, texture.height > 0 {
            videoAspect = texture.width / texture.height
        } else {
            videoAspect = viewAspect
        }

        var contentWidth = bounds.width
        var contentHeight = bounds.height
        if videoAspect > viewAspect {
            contentHeight = bounds.width / videoAspect
        } else {
            contentWidth = bounds.height * videoAspect
        }

        let originX = (bounds.width - contentWidth) / 2
        let originY = (bounds.height - contentHeight) / 2
        let relativeX = local.x - originX
        // AppKit 原点在左下，画面坐标原点在左上
        let relativeY = (bounds.height - local.y) - originY

        guard contentWidth > 0, contentHeight > 0 else { return nil }
        guard relativeX >= 0, relativeX <= contentWidth, relativeY >= 0, relativeY <= contentHeight else {
            return nil
        }
        return CGPoint(x: relativeX / contentWidth, y: relativeY / contentHeight)
    }

    /// 当前视频纹理尺寸（用于 letterbox 计算）
    private var currentTextureSize: CGSize? {
        textureLock.lock()
        defer { textureLock.unlock() }
        guard let texture = currentTexture else { return nil }
        return CGSize(width: texture.width, height: texture.height)
    }

    /// 设备画面几何信息（用于把归一化坐标还原为设备像素坐标）
    /// 未收到首帧时返回 nil，避免把点击发送到错误的分辨率
    var deviceGeometry: (size: CGSize, aspect: CGFloat)? {
        guard let size = currentTextureSize, size.width > 0, size.height > 0 else { return nil }
        return (size, size.width / size.height)
    }

    /// 视频尺寸首次就绪或发生变化时回调（用于窗口按真实比例贴合）
    var onVideoSizeChanged: ((CGSize) -> Void)?

    /// 圆角检测结果回调（单位：视频像素）
    /// 检测成功后由外部换算为视图坐标并写入 cornerRadius
    var onCornerRadiusDetected: ((CGFloat) -> Void)?

    /// 多帧确认器：连续 3 帧一致才采纳
    private let cornerConfirmer = ScreenCornerConfirmer(requiredCount: 3, tolerance: 2.0)

    /// 是否还需要做圆角检测（确认后停止，避免持续开销）
    private var needsCornerDetection = true

    /// 已尝试的检测帧数（检测不到边界时最多试 6 帧，避免逐帧空转）
    private var cornerDetectionAttempts = 0

    private static let maxCornerDetectionAttempts = 6

    /// 检测当前帧的屏幕圆角
    private func detectCornerIfNeeded(from pixelBuffer: CVPixelBuffer) {
        guard needsCornerDetection else { return }

        if cornerDetectionAttempts >= Self.maxCornerDetectionAttempts {
            // 连续多帧都测不到可靠边界（动态内容干扰），本次投屏不再重试
            needsCornerDetection = false
            AppLogger.connection.debug("[CornerDetect] 放弃检测（已达 \(Self.maxCornerDetectionAttempts) 帧上限）")
            return
        }
        cornerDetectionAttempts += 1

        let result = ScreenCornerDetector.detect(from: pixelBuffer)
        if cornerConfirmer.submit(result), let confirmed = cornerConfirmer.confirmedResult {
            needsCornerDetection = false
            AppLogger.rendering.info(
                "[CornerDetect] 确认圆角 radius=\(confirmed.radiusInPixels)px "
                + "corners=\(confirmed.cornerRadii)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.onCornerRadiusDetected?(confirmed.radiusInPixels)
            }
        }
    }

    /// 重置圆角检测状态（分辨率变化或重新开始投屏时调用）
    func resetCornerDetection() {
        cornerConfirmer.reset()
        needsCornerDetection = true
        cornerDetectionAttempts = 0
    }

    /// 外部提供的视频宽高比兜底
    /// 纹理尚未就绪时用它计算画面矩形，避免退化成「整个视图」导致按钮条贴到窗口底边
    var fallbackVideoAspect: CGFloat?

    /// 视频画面在视图内的实际显示区域（已排除黑边）
    /// 控制按钮条需要吸附到「画面」而非整个视图的底边，否则会被黑边推开
    var videoDisplayRect: CGRect? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let viewAspect = bounds.width / bounds.height
        let videoAspect: CGFloat
        if let size = currentTextureSize, size.height > 0 {
            videoAspect = size.width / size.height
        } else if let fallback = fallbackVideoAspect, fallback > 0.05, fallback < 20 {
            videoAspect = fallback
        } else {
            videoAspect = viewAspect
        }

        var contentWidth = bounds.width
        var contentHeight = bounds.height
        if videoAspect > viewAspect {
            contentHeight = bounds.width / videoAspect
        } else {
            contentWidth = bounds.height * videoAspect
        }

        let originX = (bounds.width - contentWidth) / 2
        let originY = (bounds.height - contentHeight) / 2
        return CGRect(x: originX, y: originY, width: contentWidth, height: contentHeight)
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        AppLogger.capture.info("[输入诊断] renderView mouseDown enabled=\(acceptsInputEvents) clickCount=\(event.clickCount)")
        guard acceptsInputEvents else {
            super.mouseDown(with: event)
            return
        }

        // ⌥ + 拖拽 = 拖动窗口，避免投屏时无法移动窗口
        if event.modifierFlags.contains(.option) {
            window?.performDrag(with: event)
            return
        }

        window?.makeFirstResponder(self)
        isPointerDragging = true
        if let point = normalizedPoint(from: event) {
            onPointerDown?(point, event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.mouseDragged(with: event)
            return
        }
        // ⌥ 拖拽期间不注入触摸，交给窗口拖动
        guard !event.modifierFlags.contains(.option) else { return }
        if let point = normalizedPoint(from: event) {
            onPointerMove?(point, event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.mouseUp(with: event)
            return
        }
        isPointerDragging = false
        if let point = normalizedPoint(from: event) {
            onPointerUp?(point, event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.rightMouseDown(with: event)
            return
        }
        if let point = normalizedPoint(from: event) {
            onPointerDown?(point, event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.rightMouseUp(with: event)
            return
        }
        if let point = normalizedPoint(from: event) {
            onPointerUp?(point, event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.otherMouseDown(with: event)
            return
        }
        if let point = normalizedPoint(from: event) {
            onPointerDown?(point, event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.otherMouseUp(with: event)
            return
        }
        if let point = normalizedPoint(from: event) {
            onPointerUp?(point, event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.mouseMoved(with: event)
            return
        }
        if let point = normalizedPoint(from: event) {
            onPointerHover?(point, event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // 不在悬停时抢占第一响应者
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard acceptsInputEvents else { return }
        // 拖拽过程中离开画面仍会继续收到 mouseDragged，此时不能抬起触点，
        // 否则手指会在设备上“粘住”或中断滑动
        guard !isPointerDragging else { return }
        onPointerExit?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard acceptsInputEvents else {
            super.scrollWheel(with: event)
            return
        }
        guard let point = normalizedPoint(from: event) else { return }

        // 触控板给出的是像素级增量，滚轮给出的是“行”级增量，需要分别换算
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 / 10.0 : 1.0
        onScroll?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale, point, event)
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsInputEvents, onKeyDown?(event) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        // 尺寸变化时需要重新渲染
        scheduleRender()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateDrawableSize()
        scheduleRender()
    }

    // MARK: - 设置

    private func setupMetal() {
        // 强制使用 layer-backed 视图
        wantsLayer = true

        // 创建并设置 CAMetalLayer
        let metal = CAMetalLayer()
        layer = metal
        metalLayer = metal

        guard let device = MTLCreateSystemDefaultDevice() else {
            AppLogger.rendering.error("无法创建 Metal 设备")
            return
        }
        self.device = device

        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = false
        metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metal.masksToBounds = true

        // 创建命令队列
        guard let commandQueue = device.makeCommandQueue() else {
            AppLogger.rendering.error("无法创建命令队列")
            return
        }
        self.commandQueue = commandQueue

        // 创建纹理缓存
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess else {
            AppLogger.rendering.error("无法创建纹理缓存: \(status)")
            return
        }
        textureCache = cache

        // 创建渲染管线
        guard let pipelineState = createPipelineState(device: device) else {
            AppLogger.rendering.error("无法创建渲染管线")
            return
        }
        self.pipelineState = pipelineState

        // 创建采样器
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            AppLogger.rendering.error("无法创建采样器")
            return
        }
        samplerState = sampler

        // 创建 LUT 采样器
        let lutSamplerDescriptor = ColorCompensationFilter.createLUTSamplerDescriptor()
        lutSamplerState = device.makeSamplerState(descriptor: lutSamplerDescriptor)
        samplerState = sampler

        AppLogger.rendering.info("SingleDeviceRenderView Metal 初始化成功")
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let size = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )

        if size.width > 0, size.height > 0 {
            metalLayer.drawableSize = size
        }
        // 视图尺寸变化会改变 videoDisplayRect，圆角遮罩需同步
        applyCornerMask()
    }

    // MARK: - 渲染控制

    func startRendering() {
        guard !isRendering else { return }
        isRendering = true
        updateTextureDebugCount = 0
        renderDebugCount = 0
    }

    func stopRendering() {
        guard isRendering else { return }
        isRendering = false
    }

    // MARK: - 按需渲染

    private func scheduleRender() {
        guard isRendering else { return }
        needsRender = true
        renderQueue.async { [weak self] in
            // 使用 autoreleasepool 确保每帧渲染过程中创建的临时对象及时释放
            autoreleasepool {
                self?.renderIfNeeded()
            }
        }
    }

    private func renderIfNeeded() {
        guard needsRender else { return }
        needsRender = false
        renderFrame()
    }

    // MARK: - 纹理更新

    func updateTexture(from pixelBuffer: CVPixelBuffer) {
        textureUpdateLock.lock()
        defer { textureUpdateLock.unlock() }

        let updateStartTime = CFAbsoluteTimeGetCurrent()

        guard isRendering, let cache = textureCache else {
            if updateTextureDebugCount < 5 {
                updateTextureDebugCount += 1
            }
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let texture = cvTexture else { return }
        guard let mtlTexture = CVMetalTextureGetTexture(texture) else { return }

        textureLock.lock()
        let previousSize = currentTexture.map { CGSize(width: $0.width, height: $0.height) }
        // 保持对 CVMetalTexture 的强引用，确保 MTLTexture 不会失效
        currentCVTexture = texture
        currentTexture = mtlTexture
        textureLock.unlock()

        // 视频尺寸首次就绪或发生变化（含横竖屏切换）时通知外部，
        // 让面板按真实视频比例重新布局，避免沿用兜底比例产生黑边
        let newSize = CGSize(width: mtlTexture.width, height: mtlTexture.height)
        if previousSize?.width != newSize.width || previousSize?.height != newSize.height {
            // 分辨率变化（含横竖屏切换）：重新检测圆角
            resetCornerDetection()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onVideoSizeChanged?(newSize)
            }
        }

        // 检测圆角（确认后自动停止）
        detectCornerIfNeeded(from: pixelBuffer)

        // 注意：这里不能每帧 CVMetalTextureCacheFlush。
        // 渲染在 renderQueue 上异步进行，flush 会释放上一帧仍在 GPU/渲染队列中的
        // CVMetalTexture 底层 IOSurface，实测在关闭窗口/源切换时触发
        // SIGSEGV（_swift_release_dealloc）。缓存自身会按需回收，无需手动 flush。

        // 更新 FPS 统计（加锁：updateTexture 可能被多个帧观察者并发调用，
        // 无锁并发 append/filter 会破坏堆内存导致 EXC_BREAKPOINT/malloc abort）
        let now = CFAbsoluteTimeGetCurrent()
        textureLock.lock()
        frameTimestamps.append(now)
        frameTimestamps = frameTimestamps.filter { now - $0 < 1.0 }
        fps = Double(frameTimestamps.count)
        textureLock.unlock()

        // 调试统计
        let updateTime = (now - updateStartTime) * 1000
        textureUpdateCountInPeriod += 1
        totalTextureUpdateTime += updateTime
        maxTextureUpdateTime = max(maxTextureUpdateTime, updateTime)

        // 计算更新间隔（保留用于内部统计）
        let updateInterval = (now - lastTextureUpdateTime) * 1000
        if textureUpdateCountInPeriod > 1 {
            maxTextureUpdateInterval = max(maxTextureUpdateInterval, updateInterval)
        }
        lastTextureUpdateTime = now

        // 每 5 秒重置统计（保留内部统计逻辑，移除日志输出）
        let elapsed = now - lastRenderStatsTime
        if elapsed >= 5.0 {
            // 重置统计
            lastRenderStatsTime = now
            textureUpdateCountInPeriod = 0
            renderCountInPeriod = 0
            totalTextureUpdateTime = 0
            maxTextureUpdateTime = 0
            totalRenderTime = 0
            maxRenderTime = 0
            maxTextureUpdateInterval = 0
        }

        // 触发渲染
        scheduleRender()
    }

    func clearTexture() {
        textureUpdateLock.lock()
        defer { textureUpdateLock.unlock() }

        textureLock.lock()
        currentCVTexture = nil
        currentTexture = nil
        textureLock.unlock()

        textureLock.lock()
        frameTimestamps.removeAll()
        textureLock.unlock()
        fps = 0

        // 刷新纹理缓存
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }

        // 清除画面
        scheduleRender()
    }

    // MARK: - 渲染

    private func renderFrame() {
        let renderStartTime = CFAbsoluteTimeGetCurrent()

        guard let metalLayer, let commandQueue, let pipelineState, let samplerState else {
            if renderDebugCount < 5 {
                renderDebugCount += 1
            }
            return
        }

        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            if renderDebugCount < 5 {
                renderDebugCount += 1
            }
            return
        }

        guard let drawable = metalLayer.nextDrawable() else {
            if renderDebugCount < 8 {
                renderDebugCount += 1
            }
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        // 黑边保持透明：窗口底色（系统窗口灰/浮窗黑）透过它显示，
        // 与各布局模式的视觉保持一致。
        let letterboxAlpha: Double = 0.0
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.0, green: 0.0, blue: 0.0, alpha: letterboxAlpha
        )
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        textureLock.lock()
        let texture = currentTexture
        textureLock.unlock()

        if let texture {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentSamplerState(samplerState, index: 0)

            // 计算保持纵横比的顶点
            let textureAspect = CGFloat(texture.width) / CGFloat(texture.height)
            let viewAspect = drawableSize.width / drawableSize.height

            var scaleX: Float = 1.0
            var scaleY: Float = 1.0

            if textureAspect > viewAspect {
                scaleY = Float(viewAspect / textureAspect)
            } else {
                scaleX = Float(textureAspect / viewAspect)
            }

            let vertices: [Float] = [
                -scaleX, -scaleY, 0.0, 1.0,
                scaleX, -scaleY, 1.0, 1.0,
                -scaleX, scaleY, 0.0, 0.0,
                scaleX, scaleY, 1.0, 0.0,
            ]

            encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)

            // 设置颜色补偿资源（使用注入的滤镜实例）
            if let colorFilter {
                if let lutTexture = colorFilter.getLUTTexture() {
                    encoder.setFragmentTexture(lutTexture, index: 1)
                }
                if let lutSampler = lutSamplerState {
                    encoder.setFragmentSamplerState(lutSampler, index: 1)
                }
                if let uniformBuffer = colorFilter.getUniformBuffer() {
                    encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
                }
            }

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // 统计渲染耗时
        let renderTime = (CFAbsoluteTimeGetCurrent() - renderStartTime) * 1000
        renderCountInPeriod += 1
        totalRenderTime += renderTime
        maxRenderTime = max(maxRenderTime, renderTime)
    }

    // MARK: - 着色器

    private func createPipelineState(device: MTLDevice) -> MTLRenderPipelineState? {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        // 颜色补偿参数
        struct ColorCompensationParams {
            float temperature;
            float tint;
            float saturation;
            int enabled;
        };

        // sRGB -> Linear 转换
        float srgbToLinear(float c) {
            return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
        }

        // Linear -> sRGB 转换
        float linearToSrgb(float c) {
            return (c <= 0.0031308) ? c * 12.92 : 1.055 * pow(c, 1.0/2.4) - 0.055;
        }

        float3 srgbToLinear3(float3 c) {
            return float3(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b));
        }

        float3 linearToSrgb3(float3 c) {
            return float3(linearToSrgb(c.r), linearToSrgb(c.g), linearToSrgb(c.b));
        }

        // 应用 1D LUT（RGBA16Float 格式，R/G/B 通道分别存储三条曲线）
        float3 applyLUT(float3 color, texture1d<float> lut, sampler s) {
            // LUT 纹理中：R 通道存 R 曲线，G 通道存 G 曲线，B 通道存 B 曲线
            float4 lutSample = lut.sample(s, color.r);
            float r = lutSample.r;
            
            lutSample = lut.sample(s, color.g);
            float g = lutSample.g;
            
            lutSample = lut.sample(s, color.b);
            float b = lutSample.b;
            
            return float3(r, g, b);
        }

        // 应用色温
        float3 applyTemperature(float3 color, float temp, float tint) {
            // 色温：暖 = +R -B，冷 = -R +B
            color.r += temp * 0.1;
            color.b -= temp * 0.1;
            // 色调：绿 = +G，品红 = -G
            color.g += tint * 0.05;
            return clamp(color, 0.0, 1.0);
        }

        // 应用饱和度
        float3 applySaturation(float3 color, float sat) {
            float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
            return mix(float3(luma), color, sat);
        }

        // 颜色补偿主函数
        float4 applyColorCompensation(float4 inputColor,
                                       constant ColorCompensationParams &params,
                                       texture1d<float> lut,
                                       sampler lutSampler) {
            if (params.enabled == 0) {
                return inputColor;
            }

            float3 color = inputColor.rgb;

            // 1. sRGB -> Linear
            color = srgbToLinear3(color);

            // 2. 应用 1D LUT
            color = applyLUT(color, lut, lutSampler);

            // 3. 应用色温/色调
            color = applyTemperature(color, params.temperature, params.tint);

            // 4. 应用饱和度
            color = applySaturation(color, params.saturation);

            // 5. Linear -> sRGB
            color = linearToSrgb3(color);

            return float4(color, inputColor.a);
        }

        vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                       constant float4 *vertices [[buffer(0)]]) {
            VertexOut out;
            float4 v = vertices[vertexID];
            out.position = float4(v.xy, 0.0, 1.0);
            out.texCoord = v.zw;
            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                        texture2d<float> texture [[texture(0)]],
                                        texture1d<float> lut [[texture(1)]],
                                        sampler textureSampler [[sampler(0)]],
                                        sampler lutSampler [[sampler(1)]],
                                        constant ColorCompensationParams &colorParams [[buffer(0)]]) {
            float4 color = texture.sample(textureSampler, in.texCoord);
            color = applyColorCompensation(color, colorParams, lut, lutSampler);
            return color;
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "vertexShader")
            let fragmentFunction = library.makeFunction(name: "fragmentShader")

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            AppLogger.rendering.error("编译着色器失败: \(error.localizedDescription)")
            return nil
        }
    }
}