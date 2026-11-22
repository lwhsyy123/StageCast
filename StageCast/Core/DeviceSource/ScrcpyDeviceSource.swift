//
//  ScrcpyDeviceSource.swift
//  StageCast
//
//  Created by Sun on 2025/12/22.
//
//  Scrcpy 设备源
//  通过 scrcpy-server 获取 Android 设备的 H.264/H.265 码流
//  使用 VideoToolbox 进行硬件解码
//

import AppKit
import Combine
import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

// MARK: - Scrcpy 配置

/// Scrcpy 启动配置
struct ScrcpyConfiguration {
    /// 设备序列号
    var serial: String

    /// 最大尺寸限制（0 表示不限制）
    var maxSize: Int = 0

    /// 比特率 (bps)
    var bitrate: Int = 8_000_000

    /// 最大帧率
    var maxFps: Int = 60

    /// 是否显示触摸点
    var showTouches: Bool = false

    /// 是否关闭设备屏幕
    var turnScreenOff: Bool = false

    /// 是否保持唤醒
    var stayAwake: Bool = true

    /// 是否启用音频（Android 11+ 支持）
    var audioEnabled: Bool = false

    /// 音频编解码器
    var audioCodec: AudioCodec = .opus

    /// 音频比特率 (bps)
    var audioBitRate: Int = 128_000

    /// 视频编解码器
    var videoCodec: VideoCodec = .h264

    /// 窗口标题（用于 scrcpy 窗口模式）
    var windowTitle: String?

    /// 窗口置顶
    var alwaysOnTop: Bool = false

    /// 录屏文件路径
    var recordPath: String?

    /// 录制格式
    var recordFormat: RecordFormat = .mp4

    /// 是否启用输入控制（鼠标/键盘操作手机）
    var controlEnabled: Bool = true

    /// 输入模式（鼠标 / 触摸）
    var inputMode: ScrcpyInputMode = .mouse

    /// 是否发送鼠标悬停事件
    var hoverEnabled: Bool = false

    /// 视频编解码器枚举
    enum VideoCodec: String {
        case h264
        case h265

        var fourCC: CMVideoCodecType {
            switch self {
            case .h264: kCMVideoCodecType_H264
            case .h265: kCMVideoCodecType_HEVC
            }
        }
    }

    /// 音频编解码器枚举
    enum AudioCodec: String {
        case opus
        case aac
        case flac
        case raw
    }

    /// 录制格式枚举
    enum RecordFormat: String {
        case mp4
        case mkv
    }

    /// 构建命令行参数（用于原始流输出）
    func buildRawStreamArguments() -> [String] {
        var args: [String] = []

        args.append("-s")
        args.append(serial)

        if maxSize > 0 {
            args.append("--max-size=\(maxSize)")
        }

        args.append("--video-bit-rate=\(bitrate)")
        args.append("--max-fps=\(maxFps)")
        args.append("--video-codec=\(videoCodec.rawValue)")

        // 关键：不显示窗口，输出原始流
        // 注意: scrcpy 3.0 起已移除 --no-display，使用 --no-playback 替代
        args.append("--no-playback")

        // 音频配置
        if audioEnabled {
            // 启用音频捕获（Android 11+ 支持）
            args.append("--audio-codec=\(audioCodec.rawValue)")
            args.append("--audio-bit-rate=\(audioBitRate)")
        } else {
            args.append("--no-audio")
        }

        args.append("--no-control")

        // 视频源为显示器
        args.append("--video-source=display")

        if stayAwake {
            args.append("--stay-awake")
        }

        return args
    }

    /// 构建命令行参数（用于窗口显示模式）
    func buildWindowArguments() -> [String] {
        var args: [String] = []

        args.append("-s")
        args.append(serial)

        if !audioEnabled {
            args.append("--no-audio")
        }
        if stayAwake {
            args.append("--stay-awake")
        }
        if turnScreenOff {
            args.append("--turn-screen-off")
        }
        if maxSize > 0 {
            args.append("--max-size=\(maxSize)")
        }
        if maxFps > 0 {
            args.append("--max-fps=\(maxFps)")
        }
        if bitrate > 0 {
            args.append("--video-bit-rate=\(bitrate)")
        }
        if let windowTitle {
            args.append("--window-title=\(windowTitle)")
        }
        if alwaysOnTop {
            args.append("--always-on-top")
        }
        if let recordPath {
            args.append("--record=\(recordPath)")
            args.append("--record-format=\(recordFormat.rawValue)")
        }

        return args
    }
}

// MARK: - Scrcpy 设备源

/// Scrcpy 设备源实现
/// 通过直接与 scrcpy-server 通信获取原始 H.264/H.265 码流并使用 VideoToolbox 解码
final class ScrcpyDeviceSource: BaseDeviceSource {
    // MARK: - 配置

    /// 配置（每次开始投屏时从偏好设置刷新，保证音频/控制等开关无需重启 App 即可生效）
    private var configuration: ScrcpyConfiguration
    private let toolchainManager: ToolchainManager

    // MARK: - 组件

    /// ADB 服务
    private var adbService: AndroidADBService?

    /// 服务器启动器
    private var serverLauncher: ScrcpyServerLauncher?

    /// Socket 接收器
    private var socketAcceptor: ScrcpySocketAcceptor?

    /// 控制通道（启用控制时创建）
    private var controlChannel: ScrcpyControlChannel?

    /// 输入控制器（将鼠标/键盘事件翻译为控制消息）
    let inputController = ScrcpyInputController()

    /// 设备唯一标识：与 AppState.androidSources 的键、录制服务使用的设备 ID 一致
    var deviceID: String { configuration.serial }

    /// 控制通道是否可用（未开启或连接未建立时为 false）
    var isControlAvailable: Bool {
        controlChannel?.isReady == true
    }

    /// 视频流解析器
    private var streamParser: ScrcpyVideoStreamParser?

    /// VideoToolbox 解码器
    private var decoder: VideoToolboxDecoder?

    // MARK: - 音频组件

    /// 音频流解析器
    private var audioStreamParser: ScrcpyAudioStreamParser?

    /// AAC 音频解码器
    private var aacDecoder: ScrcpyAudioDecoder?

    /// OPUS 音频解码器
    private var opusDecoder: ScrcpyOpusDecoder?

    /// RAW PCM 音频解码器
    private var rawDecoder: ScrcpyRAWDecoder?

    /// 当前音频编解码器类型
    private var currentAudioCodecId: UInt32?

    /// 音频播放器
    private var audioPlayer: AudioPlayer?

    /// 音频同步器
    private var audioSynchronizer: AudioSynchronizer?

    /// 音频是否启用（从偏好设置读取，控制播放而非捕获）
    var audioEnabled: Bool {
        get { UserPreferences.shared.androidAudioEnabled }
        set {
            UserPreferences.shared.androidAudioEnabled = newValue
            audioPlayer?.isMuted = isPerDeviceMuted || !newValue
        }
    }

    /// 每格静音（手动覆盖，独立于全局音频开关）
    private(set) var isPerDeviceMuted = false

    /// 静音前记录的手机媒体音量（取消静音时恢复）
    private var preMuteDeviceVolume: Int?

    /// 设置每格静音状态（控制本设备播放，不影响捕获与全局偏好）
    /// Mac 端：audioPlayer 静音；手机端：通过 adb 将媒体音量（STREAM_MUSIC）设为 0 / 恢复
    func setPerDeviceMuted(_ muted: Bool) {
        isPerDeviceMuted = muted
        audioPlayer?.isMuted = muted || !UserPreferences.shared.androidAudioEnabled
        Task { [weak self] in
            await self?.applyDeviceMute(muted)
        }
    }

    /// 手机端静音/恢复（adb shell media volume）
    private func applyDeviceMute(_ muted: Bool) async {
        guard let adbService else { return }
        if muted {
            // 记录当前媒体音量再置 0，取消静音时恢复
            if let result = try? await adbService.shell("cmd media_session volume --stream 3 --get"), result.isSuccess {
                if let range = result.stdout.range(of: "volume is ") {
                    let tail = result.stdout[range.upperBound...].prefix(while: { $0.isNumber })
                    if let v = Int(tail) {
                        preMuteDeviceVolume = v
                    }
                }
            }
            _ = try? await adbService.shell("cmd media_session volume --stream 3 --set 0")
            AppLogger.capture.debug("[音频] 手机端静音（媒体音量置 0）")
        } else {
            let restored = preMuteDeviceVolume ?? 8
            _ = try? await adbService.shell("cmd media_session volume --stream 3 --set \(restored)")
            preMuteDeviceVolume = nil
            AppLogger.capture.debug("[音频] 手机端取消静音（媒体音量恢复 \(restored)）")
        }
    }

    /// 音量 (0.0 - 1.0)
    var audioVolume: Float {
        get { UserPreferences.shared.androidAudioVolume }
        set {
            UserPreferences.shared.androidAudioVolume = newValue
            audioPlayer?.volume = newValue
        }
    }

    /// 是否静音（由 audioEnabled 自动控制）
    var audioMuted: Bool {
        get { !audioEnabled }
        set { audioEnabled = !newValue }
    }

    // MARK: - 状态

    /// 服务器进程
    private var serverProcess: Process?

    /// 监控任务
    private var monitorTask: Task<Void, Never>?

    /// 帧管道（参照 scrcpy trait 模式设计）
    /// 实现: 解码线程 → FramePipeline → 主线程渲染
    private let framePipeline = FramePipeline()

    /// 最新的 CVPixelBuffer 存储（兼容旧接口）
    private let latestPixelBufferLock = NSLock()
    private var latestPixelBufferStorage: CVPixelBuffer?

    /// 最近一次收到帧的时间（用于熄屏后编码器停帧的自动恢复检测）
    private var lastFrameArrivalTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    /// 帧停滞看门狗任务（stopCapture 时取消）
    private var frameStallWatchdogTask: Task<Void, Never>?

    /// 最新的 CVPixelBuffer（供渲染使用）
    override var latestPixelBuffer: CVPixelBuffer? {
        latestPixelBufferLock.lock()
        defer { latestPixelBufferLock.unlock() }
        return latestPixelBufferStorage
    }

    /// 捕获回调开关（避免 stop/cleanup 后仍处理解码回调）
    private let captureGateLock = NSLock()
    private var isCaptureActive = false

    /// 帧回调（通过 FramePipeline 分发，已实现事件合并）
    /// 说明：主面板等单一消费方使用；网格面板请用 addFrameObserver（可多路并存）。
    private let onFrameLock = NSLock()
    private var _onFrame: ((CVPixelBuffer) -> Void)?

    /// 帧回调（通过 FramePipeline 分发，已实现事件合并）
    /// 说明：主面板等单一消费方使用；网格面板请用 addFrameObserver（可多路并存）。
    /// 线程说明：写入发生在主线程、读取发生在渲染线程，必须走锁快照，
    /// 否则「停止投屏/关闭浮窗」时替换回调会与渲染线程并发访问同一闭包对象，
    /// 表现为 _swift_release_dealloc 崩溃。
    var onFrame: ((CVPixelBuffer) -> Void)? {
        get {
            onFrameLock.lock()
            defer { onFrameLock.unlock() }
            return _onFrame
        }
        set {
            onFrameLock.lock()
            _onFrame = newValue
            onFrameLock.unlock()
            // 将通知链注册到帧管道：onFrame 与观察者并存分发
            framePipeline.setFrameHandler { [weak self] pixelBuffer in
                guard let self else { return }
                // 更新最新帧引用（线程安全）
                self.setLatestPixelBuffer(pixelBuffer)
                self.notifyFrameConsumers(pixelBuffer)
            }
        }
    }

    /// 帧观察者注册表（网格面板与主面板需同时消费帧）
    private let frameObserversLock = NSLock()
    private var frameObservers: [UUID: (CVPixelBuffer) -> Void] = [:]

    /// 注册帧观察者，返回用于注销的令牌
    @discardableResult
    func addFrameObserver(_ handler: @escaping (CVPixelBuffer) -> Void) -> UUID {
        let token = UUID()
        frameObserversLock.lock()
        frameObservers[token] = handler
        frameObserversLock.unlock()
        return token
    }

    /// 注销帧观察者
    func removeFrameObserver(_ token: UUID) {
        frameObserversLock.lock()
        frameObservers.removeValue(forKey: token)
        frameObserversLock.unlock()
    }

    /// 分发帧到所有消费方（主回调 + 观察者）
    private func notifyFrameConsumers(_ pixelBuffer: CVPixelBuffer) {
        onFrameLock.lock()
        let handler = _onFrame
        onFrameLock.unlock()
        handler?(pixelBuffer)
        frameObserversLock.lock()
        let handlers = Array(frameObservers.values)
        frameObserversLock.unlock()
        for handler in handlers {
            handler(pixelBuffer)
        }
    }

    /// 当前端口
    private var currentPort: Int

    /// 帧管道统计任务
    private var pipelineStatsTask: Task<Void, Never>?

    // MARK: - 初始化

    init(device: AndroidDevice, toolchainManager: ToolchainManager, configuration: ScrcpyConfiguration? = nil) {
        // 使用传入的配置或从用户偏好设置构建配置
        var config = configuration ?? UserPreferences.shared.buildScrcpyConfiguration(serial: device.serial)
        config.serial = device.serial
        self.configuration = config
        self.toolchainManager = toolchainManager

        // 从用户偏好读取端口范围起始值作为初始端口
        currentPort = UserPreferences.shared.scrcpyPortRangeStart

        super.init(
            displayName: device.displayName,
            sourceType: .scrcpy
        )

        // 设置设备信息
        deviceInfo = GenericDeviceInfo(
            id: device.serial,
            name: device.displayName,
            model: device.model,
            platform: .android
        )

        AppLogger.device.info("创建 Scrcpy 设备源: \(device.displayName)")
    }

    deinit {
        deactivateCaptureCallbacks()
        monitorTask?.cancel()
    }

    // MARK: - 连接

    override func connect() async throws {
        AppLogger.connection.info("准备连接 Android 设备: \(configuration.serial), 当前状态: \(state)")

        guard state == .idle || state == .disconnected else {
            AppLogger.connection.warning("设备已连接或正在连接中，当前状态: \(state)")
            return
        }

        updateState(.connecting)
        AppLogger.connection.info("开始连接 Android 设备: \(configuration.serial)")

        // 获取工具链路径
        let (adbPath, scrcpyServerPath) = await MainActor.run {
            (
                toolchainManager.adbPath,
                toolchainManager.scrcpyServerPath
            )
        }

        guard let serverPath = scrcpyServerPath else {
            let error = DeviceSourceError.connectionFailed("scrcpy-server 未找到")
            AppLogger.connection.error("连接失败: scrcpy-server 未找到")
            updateState(.error(error))
            throw error
        }

        // 创建 ADB 服务
        adbService = await MainActor.run {
            AndroidADBService(
                adbPath: adbPath,
                deviceSerial: configuration.serial
            )
        }

        // 创建视频流解析器（使用标准协议模式）
        streamParser = ScrcpyVideoStreamParser(codecType: configuration.videoCodec.fourCC, useRawStream: false)

        // 设置 SPS 变化回调（分辨率变化时重建解码器）
        streamParser?.onSPSChanged = { [weak self] _ in
            self?.handleSPSChanged()
        }

        // 创建 VideoToolbox 解码器
        decoder = VideoToolboxDecoder(codecType: configuration.videoCodec.fourCC)
        attachDecoderCallback()

        // 获取 scrcpy 版本
        let scrcpyVersion = getScrcpyVersion()

        // 创建服务器启动器
        guard let adbService else {
            updateState(.disconnected)
            AppLogger.connection.error("❌ 缺少 adbService，无法启动 scrcpy: \(displayName)")
            return
        }

        serverLauncher = ScrcpyServerLauncher(
            adbService: adbService,
            serverLocalPath: serverPath,
            port: currentPort,
            scrcpyVersion: scrcpyVersion
        )

        updateState(.connected)
        AppLogger.connection.info("✅ 设备连接成功: \(displayName), 状态: \(state)")
    }

    override func disconnect() async {
        AppLogger.connection.info("断开连接: \(displayName), 当前状态: \(state)")

        monitorTask?.cancel()
        monitorTask = nil

        // stopCapture 会处理所有清理工作
        await stopCapture()

        // 清理组件
        adbService = nil
        serverLauncher = nil
        socketAcceptor = nil
        cleanupControlChannel()
        streamParser = nil
        decoder = nil
        setLatestPixelBuffer(nil)

        updateState(.disconnected)
    }

    // MARK: - 捕获

    override func startCapture() async throws {
        AppLogger.capture.info("开始捕获 Android 设备: \(displayName), 状态: \(state)")

        guard state == .connected || state == .paused || state == .capturing else {
            AppLogger.capture.error("无法开始捕获: 设备未连接，当前状态: \(state)")
            throw DeviceSourceError.captureStartFailed(L10n.capture.deviceNotConnected)
        }

        // 重新从偏好设置生成配置：设备源创建后用户可能改过音频/控制开关，
        // 继续沿用初始化时的快照会导致这些改动必须重启 App 才生效
        refreshConfigurationFromPreferences()

        do {
            guard adbService != nil else {
                throw DeviceSourceError.captureStartFailed("ADB 服务未初始化")
            }

            // 重新挂载解码回调（stop/cleanup 会清空）
            attachDecoderCallback()

            // 0. 唤醒设备（如果息屏）
            await wakeUpDeviceIfNeeded()

            // 1. 查找可用端口（支持与其他 scrcpy 共存）
            try await findAvailablePort()

            // 2. 清理之前可能残留的 ADB 端口转发
            await cleanupADBForwarding()

            // 3. 创建/重建 launcher（使用新端口）
            // 因为端口可能已经改变，需要重新创建 launcher
            await recreateLauncherIfNeeded()

            guard let launcher = serverLauncher else {
                throw DeviceSourceError.captureStartFailed("服务器启动器未初始化")
            }

            AppLogger.capture
                .debug("[Scrcpy] 启动参数: 端口=\(currentPort), scid=\(launcher.scid), socketName=\(launcher.socketName)")

            // 4. 推送 scrcpy-server 并设置端口转发
            try await launcher.prepareEnvironment(configuration: configuration)

            // 5. 创建并启动 Socket 监听器/连接器（必须在服务端启动前！）
            socketAcceptor = ScrcpySocketAcceptor(
                port: currentPort,
                connectionMode: launcher.connectionMode,
                audioEnabled: configuration.audioEnabled,
                controlEnabled: configuration.controlEnabled
            )

            // 控制通道：在 video/audio 之后接管第三条连接
            if configuration.controlEnabled {
                setupControlChannel()
            }

            // 设置视频数据接收回调
            socketAcceptor?.onDataReceived = { [weak self] data in
                autoreleasepool {
                    self?.handleReceivedData(data)
                }
            }

            // 设置音频数据接收回调（如果启用）
            if configuration.audioEnabled {
                AppLogger.capture.debug("[Scrcpy] 音频已启用，设置音频组件")
                setupAudioComponents()
                socketAcceptor?.onAudioDataReceived = { [weak self] data in
                    autoreleasepool {
                        self?.handleReceivedAudioData(data)
                    }
                }
            }

            // 4. 启动监听/连接
            // 用最新配置同步音频开关，确保连接顺序判断与实际服务端参数一致
            socketAcceptor?.setAudioEnabled(configuration.audioEnabled)
            try await socketAcceptor?.start()

            // 启动音频监控：设备不支持音频时会提示，而非静默无声
            startAudioWatchdog()

            // 5. 提前启动帧管道（必须在数据开始接收之前！）
            framePipeline.start(size: CGSize(width: 1080, height: 1920))

            // 6. 提前设置状态为 capturing
            updateState(.capturing)
            setCaptureActive(true)

            // 7. 启动 scrcpy-server
            // 熄屏状态下启动 server 会导致 encoder 输出黑帧，且屏幕点亮后
            // virtual display 不会自动恢复（实测 OnePlus 8：投屏持续黑屏直到
            // 再次收到 WAKEUP）。启动前先点亮屏幕，让 encoder 在亮屏状态创建。
            do {
                _ = try? await adbService?.shell("input keyevent KEYCODE_WAKEUP")
                AppLogger.capture.debug("[Scrcpy] 已发送 WAKEUP 确保亮屏启动")
            }

            // 设备的 settings provider 可能拒绝写入（如部分 ColorOS 设备 shell settings 挂起，
            // 或缺少 WRITE_SECURE_SETTINGS），导致 stay_on_while_plugged_in 写入失败、server 以 255 退出。
            // 注意：设备 wedge 时 adb shell 挂起、server 进程可能长期存活，launcher 的 1.5s 检查不会抛错，
            // 失败往往表现为「server 存活但视频连接超时」。因此把「启动失败」与「视频等待超时」合并为同一
            // 降级条件：stay_awake 开启时，任一失败 → 关闭 stay_awake / screen_off_timeout 后重试一次
            // （牺牲防熄屏，换取投屏可用）。
            do {
                serverProcess = try await launcher.startServer(configuration: configuration)
                try await socketAcceptor?.waitForVideoConnection(timeout: 10)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 只要能确定是 stay_awake 引起的问题（SettingsException / server 255 退出 / 连接超时），
                // 一律降级重试一次；不能只匹配特定错误类型，否则部分机型会直接失败收场。
                guard configuration.stayAwake else { throw error }
                AppLogger.connection.warning("[Scrcpy] 启动失败（\(error)），降级重试：关闭 stay_awake/screen_off_timeout")
                configuration.stayAwake = false
                serverProcess?.terminate()
                serverProcess = nil
                _ = try? await adbService?.shell("input keyevent KEYCODE_WAKEUP")
                serverProcess = try await launcher.startServer(configuration: configuration)
                try await socketAcceptor?.waitForVideoConnection(timeout: 10)
            }

            // 视频连接建立后再补发一次 WAKEUP 兜底：重试/自动重连场景下，
            // 预唤醒到 encoder 就绪之间屏幕可能再次熄灭（encoder 输出黑帧且
            // 不会随屏幕点亮自动恢复），补一发 WAKEUP 确保画面立即出现。
            // 若屏幕已亮则为无害空操作。
            do {
                _ = try? await adbService?.shell("input keyevent KEYCODE_WAKEUP")
                AppLogger.capture.debug("[Scrcpy] 视频连接已建立，补发 WAKEUP 兜底")
            }

            AppLogger.capture.info("捕获已启动: \(displayName)")

            // 启动进程监控
            startProcessMonitoring()

            // 启动帧管道统计任务
            startPipelineStats()

            // 启动帧停滞看门狗（熄屏后编码器停帧不恢复的自动恢复）
            // 基准时间在这里重置：server 启动到首帧可达数秒，避免启动期误判
            lastFrameArrivalTime = CFAbsoluteTimeGetCurrent()
            startFrameStallWatchdog()

        } catch {
            // 捕获失败时清理资源
            await cleanupAfterError()

            // 转换为用户友好的错误
            let scrcpyError = ScrcpyErrorHelper.mapError(error, port: currentPort)
            let captureError = DeviceSourceError.captureStartFailed(scrcpyError.fullDescription)

            AppLogger.capture.error("[Scrcpy] 启动失败: \(scrcpyError.fullDescription)")

            // 重要：错误后恢复到 connected 状态，而不是 error 状态
            // 这样用户可以重新尝试，而不需要重启应用
            updateState(.connected)

            throw captureError
        }
    }

    /// 从当前偏好设置刷新 scrcpy 配置
    private func refreshConfigurationFromPreferences() {
        var latest = UserPreferences.shared.buildScrcpyConfiguration(serial: configuration.serial)
        latest.serial = configuration.serial

        if latest.audioEnabled != configuration.audioEnabled {
            AppLogger.capture
                .info("[Scrcpy] 音频开关已按最新偏好更新: \(configuration.audioEnabled) -> \(latest.audioEnabled)")
        }
        if latest.controlEnabled != configuration.controlEnabled {
            AppLogger.capture
                .info("[Scrcpy] 控制开关已按最新偏好更新: \(configuration.controlEnabled) -> \(latest.controlEnabled)")
        }

        configuration = latest
    }

    /// 创建或重建 ScrcpyServerLauncher
    /// 当端口改变时需要重建，因为 launcher 的端口在初始化时就固定了
    private func recreateLauncherIfNeeded() async {
        guard let adbService else { return }

        // 获取 scrcpy-server 路径（需要在 MainActor 上访问）
        let serverPath = await MainActor.run { toolchainManager.scrcpyServerPath }

        guard let serverPath else {
            AppLogger.capture.error("[ScrcpyDeviceSource] 无法获取 scrcpy-server 路径")
            return
        }

        // 获取 scrcpy 版本
        let scrcpyVersion = getScrcpyVersion()

        // 检查是否需要重建（端口改变，或者 launcher 不存在）
        if serverLauncher == nil {
            AppLogger.capture.info("[ScrcpyDeviceSource] 创建 ScrcpyServerLauncher (端口: \(currentPort))")
        } else {
            AppLogger.capture.info("[ScrcpyDeviceSource] 重建 ScrcpyServerLauncher (新端口: \(currentPort))")
        }

        serverLauncher = ScrcpyServerLauncher(
            adbService: adbService,
            serverLocalPath: serverPath,
            port: currentPort,
            scrcpyVersion: scrcpyVersion
        )
    }

    /// 唤醒设备（如果息屏）
    /// 通过 ADB 发送电源键事件，模拟 scrcpy 的 power_on 行为
    private func wakeUpDeviceIfNeeded() async {
        guard let adbService else { return }

        AppLogger.capture.info("[ScrcpyDeviceSource] 检测设备屏幕状态...")

        do {
            // 检测屏幕是否亮起
            // dumpsys power 输出包含 "mWakefulness=Awake" (亮屏) 或 "mWakefulness=Asleep" (息屏)
            let result = try await adbService.shell("dumpsys power | grep mWakefulness")

            let isScreenOn = result.stdout.contains("Awake")

            if isScreenOn {
                AppLogger.capture.info("[ScrcpyDeviceSource] 设备屏幕已亮起")
                return
            }

            AppLogger.capture.info("[ScrcpyDeviceSource] 设备息屏，发送电源键唤醒...")

            // 发送电源键事件唤醒设备 (keyevent 26 = KEYCODE_POWER)
            _ = try await adbService.shell("input keyevent 26")

            // 等待设备实际响应（参考 scrcpy 的 500ms 延迟）
            try await Task.sleep(nanoseconds: 500_000_000)

            AppLogger.capture.info("[ScrcpyDeviceSource] 设备已唤醒")

        } catch {
            // 唤醒失败不应阻止捕获，只记录警告
            AppLogger.capture.warning("[ScrcpyDeviceSource] 检测/唤醒设备失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 帧停滞自动恢复

    /// 帧停滞阈值：超过该时长没有任何新帧视为流停滞
    private static let frameStallThreshold: CFAbsoluteTime = 10
    /// 看门狗轮询间隔
    private static let stallCheckInterval: UInt64 = 5_000_000_000
    /// 单次恢复流程的重入保护
    private let stallRecoveryLock = NSLock()
    private var isRecoveringFromStall = false
    /// 上次看门狗检测到的设备亮灭状态（用于区分「亮屏后编码器不恢复」与「静态画面 legitimately 无帧」）
    private var lastObservedWakefulness: String?

    /// 启动帧停滞看门狗：设备亮屏但超过阈值无帧 → 编码器停帧（熄屏期间
    /// MediaCodec 虚拟 display 停止输出，唤醒后不自动恢复），自动重启该路捕获。
    private func startFrameStallWatchdog() {
        frameStallWatchdogTask?.cancel()
        isRecoveringFromStall = false
        lastObservedWakefulness = nil
        frameStallWatchdogTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.stallCheckInterval)
                if Task.isCancelled { break }
                // 恢复流程（stop+start）会在 stopCapture 内取消本看门狗任务，
                // 因此把检测与恢复放进非结构化任务，避免取消传播打断重启
                await Task.detached { [weak self] in
                    await self?.checkFrameStall()
                }.value
            }
        }
        AppLogger.capture.debug("[Scrcpy] 帧停滞看门狗已启动（阈值 \(Int(Self.frameStallThreshold))s）")
    }

    private func checkFrameStall() async {
        // 状态守卫：仅在正常捕获中检测
        guard state == .capturing, isCaptureActive else { return }
        // 恢复流程重入保护（lock 闭包内无挂起点，async-safe）
        let alreadyRecovering = stallRecoveryLock.withLock { isRecoveringFromStall }
        if alreadyRecovering { return }
        stallRecoveryLock.withLock { isRecoveringFromStall = true }
        defer {
            stallRecoveryLock.withLock { isRecoveringFromStall = false }
        }

        let now = CFAbsoluteTimeGetCurrent()
        let sinceLastFrame = now - lastFrameArrivalTime
        guard sinceLastFrame > Self.frameStallThreshold else { return }

        // 设备息屏属正常停帧（省电），唤醒后由用户操作或下次检测处理；
        // 只在「刚从息屏进入亮屏后仍无帧」时才重启（MediaCodec 虚拟 display 熄屏后不恢复的缺陷）。
        // 静态画面（锁屏时钟不动、无动画）下 scrcpy 编码器合法地长时间不发帧，不能据此重启，
        // 否则会陷入「静止画面→重启→黑帧→再静止→再重启」的循环（实测 MIX/Android 16 必现）。
        guard let adbService else { return }
        let wakeResult = try? await adbService.shell("dumpsys power | grep mWakefulness")
        let isAwake = wakeResult?.isSuccess == true && wakeResult!.stdout.contains("Awake")

        // 记录/检测亮灭状态迁移
        let previous = lastObservedWakefulness
        let transitionedToAwake = isAwake && previous != nil && previous != "Awake"
        lastObservedWakefulness = isAwake ? "Awake" : "Asleep"

        if !isAwake {
            AppLogger.capture.debug("[Scrcpy] \(Int(sinceLastFrame))s 无帧但设备息屏，跳过恢复")
            // 息屏期间刷新基准，避免唤醒瞬间误判（唤醒后 10s 无帧才触发恢复）
            lastFrameArrivalTime = now
            return
        }

        // 亮屏但非「刚唤醒」且一直无帧：静态画面，属正常现象，刷新基准跳过。
        // previous == nil（本次捕获首次观察）同样跳过：重启会重置看门狗，若首检即重启将陷入循环。
        guard transitionedToAwake else {
            AppLogger.capture.debug("[Scrcpy] \(Int(sinceLastFrame))s 无帧且设备持续亮屏（静态画面），跳过恢复")
            lastFrameArrivalTime = now
            return
        }

        AppLogger.capture.warning("[Scrcpy] 检测到帧停滞（\(Int(sinceLastFrame))s 无帧，设备刚唤醒且编码器未恢复），自动重启捕获流: \(displayName)")

        // 修复熄屏期间唤醒后补 WAKEUP 也不恢复的场景：完整重启 server + 解码管线。
        // 重启放在独立任务里执行：看门狗任务下次 tick 的 Task.isCancelled 检查
        // 或外部 stopCapture 都不会中断进行中的 stop→start 序列。
        await stopCapture()
        await Task.detached { [weak self] in
            await self?.restartAfterStall()
        }.value
    }

    /// 帧停滞后的重启（独立于看门狗任务的上下文）
    private func restartAfterStall() async {
        do {
            try await startCapture()
            AppLogger.capture.info("[Scrcpy] 帧停滞恢复完成: \(displayName)")
        } catch is CancellationError {
            AppLogger.capture.warning("[Scrcpy] 帧停滞恢复被取消（可能用户已停止）: \(displayName)")
        } catch {
            AppLogger.capture.error("[Scrcpy] 帧停滞恢复失败: \(error.localizedDescription)")
        }
    }

    /// 查找可用端口（支持与其他 scrcpy 实例共存）
    /// 仿照 scrcpy 的行为：从配置的起始端口开始，如果被占用则尝试下一个端口
    /// 端口范围由偏好设置控制，默认 27183 - 27199（与 scrcpy 官方一致）
    private func findAvailablePort() async throws {
        let portRange = UserPreferences.shared.scrcpyPortRange

        for port in portRange {
            let available = ScrcpyErrorHelper.isPortAvailable(port)
            if available {
                currentPort = port
                AppLogger.capture.debug("[Scrcpy] 使用端口 \(port)")
                return
            }
        }

        // 所有端口都被占用
        throw ScrcpyError.portInUse(port: portRange.lowerBound)
    }

    /// 清理 ADB 端口转发（移除可能残留的转发规则）
    private func cleanupADBForwarding() async {
        guard let adbService else { return }

        AppLogger.capture.info("[ScrcpyDeviceSource] 清理残留的 ADB 端口转发...")

        // 移除与当前端口相关的 forward 和 reverse
        await adbService.removeForward(tcpPort: currentPort)
        // reverse 需要 socketName，但此时 launcher 可能还没初始化
        // 所以我们只清理 forward，reverse 由 launcher 在 stop() 时清理
    }

    /// 错误后清理资源
    private func cleanupAfterError() async {
        AppLogger.capture.info("[ScrcpyDeviceSource] 错误后清理资源...")

        // 先停掉回调，避免清理过程中仍处理帧
        deactivateCaptureCallbacks()

        // 停止帧管道
        stopPipelineStats()
        framePipeline.stop()

        // 清理控制通道
        cleanupControlChannel()

        // 清理 socket
        socketAcceptor?.stop()
        socketAcceptor = nil

        // 停止 launcher（会清理端口转发）
        await serverLauncher?.stop()

        // 终止服务器进程
        if let process = serverProcess, process.isRunning {
            process.terminate()
        }
        serverProcess = nil

        // 清理音频组件
        cleanupAudioComponents()

        // 重置解析器和解码器
        streamParser?.reset()
        decoder?.reset()
    }

    /// 重置连接（供外部调用，用于从错误状态恢复）
    func resetConnection() async {
        AppLogger.capture.info("[ScrcpyDeviceSource] 重置连接...")

        // 1. 彻底清理所有资源
        await cleanupAfterError()

        // 2. 清理 ADB 转发
        await cleanupADBForwarding()

        // 3. 尝试释放端口
        _ = await ScrcpyErrorHelper.tryReleasePort(currentPort)

        // 4. 重置状态
        if state != .disconnected {
            updateState(.connected)
        }

        AppLogger.capture.info("[ScrcpyDeviceSource] 连接已重置，可以重新开始捕获")
    }

    override func stopCapture() async {
        AppLogger.capture.info("停止捕获: \(displayName)")

        // 先停掉回调，避免清理过程中仍处理帧
        deactivateCaptureCallbacks()

        // 0. 停止帧管道统计任务
        stopPipelineStats()

        // 0.5. 停止帧管道
        framePipeline.stop()

        // 0.6. 清理控制通道（先于 socket，避免输入消息发往已关闭的连接）
        cleanupControlChannel()

        // 1. 停止 Socket 接收器
        socketAcceptor?.stop()
        socketAcceptor = nil

        // 2. 停止服务器启动器
        await serverLauncher?.stop()

        // 3. 终止服务器进程
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil

        // 4. 重置解析器
        streamParser?.reset()

        // 5. 重置解码器
        decoder?.reset()

        // 6. 重置帧管道（清空旧帧）
        framePipeline.stop()

        // 7. 清理设备端残留的 scrcpy-server 进程
        // 关键：adb shell 被 terminate 后，设备上由 app_process 启动的 Java 进程
        // 已 detach，不会随之退出。若不清理，它会继续占用 SurfaceFlinger 虚拟显示
        // 并向已关闭的 socket 推流，表现为「旧投屏画面关不掉」。
        await killRemoteScrcpyServer()

        // 8. 停止设备端正在播放的媒体
        // 投屏断开后手机继续外放会很突兀，这里主动暂停播放
        await pauseDeviceMediaPlayback()

        // 9. 停止音频组件
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        cleanupAudioComponents()

        // 注意：不取消 frameStallWatchdogTask —— 帧停滞恢复流程在 stopCapture()
        // 内部调用本方法，取消看门狗会连带取消恢复中的 startCapture()（CancellationError）。
        // 看门狗自身用 state==.capturing 守卫，停止期间不会误触发。

        if state == .capturing {
            updateState(.connected)
        }
    }

    /// 设备掉线或启动失败后把状态复位为 disconnected
    /// 源的 connect() 只接受 idle/disconnected，停在 error 时重连会被直接拒绝
    func resetForReconnect() {
        guard case .error = state else { return }
        AppLogger.connection.info("[Scrcpy] 复位失败状态，允许重新连接: \(configuration.serial)")
        updateState(.disconnected)

        AppLogger.capture.info("捕获已停止: \(displayName)")
    }

    override func pauseCapture() {
        super.pauseCapture()
        // 暂停时不再处理解码回调
        if state == .paused {
            setCaptureActive(false)
        }
    }

    override func resumeCapture() {
        super.resumeCapture()
        // 恢复时重新允许处理解码回调
        if state == .capturing {
            setCaptureActive(true)
        }
    }

    // MARK: - 数据处理

    /// 过滤掉的非 VCL NAL 计数（用于诊断）
    private var filteredNonVCLCount = 0

    /// 端到端延迟统计
    private var frameReceiveTime: CFAbsoluteTime = 0
    private var frameDecodeCompleteTime: CFAbsoluteTime = 0
    private var totalE2ELatency: Double = 0
    private var maxE2ELatency: Double = 0
    private var e2eLatencyCount: Int = 0
    private var lastE2EStatsTime = CFAbsoluteTimeGetCurrent()

    /// 处理接收到的数据
    private func handleReceivedData(_ data: Data) {
        // 记录数据接收时间
        frameReceiveTime = CFAbsoluteTimeGetCurrent()

        guard let parser = streamParser, let decoder else { return }

        // 解析 NAL 单元
        let nalUnits = parser.append(data)

        for nalUnit in nalUnits {
            // 如果是参数集且解码器未初始化，尝试初始化
            if nalUnit.isParameterSet, !decoder.isReady {
                if parser.hasCompleteParameterSets {
                    initializeDecoderIfNeeded()
                }
                continue
            }

            // 过滤非 VCL NAL 单元（SEI/AUD/filler 等）
            // 这些单元不包含实际视频数据，不应送入解码器
            guard nalUnit.isVCL else {
                filteredNonVCLCount += 1
                // 每 100 个非 VCL NAL 记录一次日志（避免日志过多）
                if filteredNonVCLCount % 100 == 1 {
                    AppLogger.capture.debug("[Scrcpy] 过滤非 VCL NAL (type=\(nalUnit.type))，累计过滤: \(filteredNonVCLCount)")
                }
                continue
            }

            // 解码 VCL NAL 单元（实际视频帧数据）
            if decoder.isReady {
                decoder.decode(nalUnit: nalUnit)
            }
        }
    }

    /// 初始化解码器（如果需要）
    private func initializeDecoderIfNeeded() {
        guard let parser = streamParser, let decoder else { return }
        guard !decoder.isReady else { return }
        guard parser.hasCompleteParameterSets else { return }

        initializeDecoder()
    }

    /// 初始化解码器
    private func initializeDecoder() {
        guard let parser = streamParser, let decoder else { return }
        guard parser.hasCompleteParameterSets else { return }

        // 获取实际的编解码类型（可能从协议元数据更新）
        let codecType = parser.currentCodecType

        do {
            if codecType == kCMVideoCodecType_H264 {
                guard let sps = parser.sps, let pps = parser.pps else { return }
                try decoder.initializeH264(sps: sps, pps: pps)
            } else {
                guard let vps = parser.vps, let sps = parser.sps, let pps = parser.pps else { return }
                try decoder.initializeH265(vps: vps, sps: sps, pps: pps)
            }
            decoder.activateCallbacks()
            AppLogger.capture.info("✅ 解码器初始化成功（可能是旋转后重建）")
        } catch {
            AppLogger.capture.error("解码器初始化失败: \(error.localizedDescription)")
        }
    }

    /// 处理 SPS 变化（分辨率变化）
    /// 注意：只标记需要重建解码器，不立即重建
    /// 因为新的 PPS 可能还没到达，需要等待完整参数集
    private func handleSPSChanged() {
        AppLogger.capture.info("⚠️ 检测到 SPS 变化（设备旋转），标记解码器需要重建...")

        // 重置解码器（这会导致 isReady = false）
        decoder?.reset()

        // 重置帧管道（清空旧帧，避免显示旧的旋转前内容）
        framePipeline.stop()
        // 立即重新启动（使用当前尺寸或默认尺寸）
        framePipeline.start(size: captureSize != .zero ? captureSize : CGSize(width: 1080, height: 1920))

        AppLogger.capture.info("[旋转] 解码器已重置，等待新的完整参数集...")

        // 不在这里调用 initializeDecoder()
        // 等待 handleReceivedData 中收到新的参数集后自动重新初始化
        // 因为设备旋转时，scrcpy 会重新发送完整的 config packet (SPS + PPS)
    }

    /// 处理解码后的帧
    /// 使用双帧缓冲设计（与 scrcpy frame_buffer.c 一致）
    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard canHandleFrames() else { return }

        // 计算端到端延迟（从数据接收到解码完成）
        let decodeCompleteTime = CFAbsoluteTimeGetCurrent()
        let e2eLatency = (decodeCompleteTime - frameReceiveTime) * 1000 // 转换为毫秒

        totalE2ELatency += e2eLatency
        maxE2ELatency = max(maxE2ELatency, e2eLatency)
        e2eLatencyCount += 1

        // 每 5 秒重置统计（保留内部统计逻辑，移除日志输出）
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastE2EStatsTime
        if elapsed >= 5.0 {
            // 重置统计
            lastE2EStatsTime = now
            totalE2ELatency = 0
            maxE2ELatency = 0
            e2eLatencyCount = 0
        }

        // 更新最新帧（兼容旧接口）
        setLatestPixelBuffer(pixelBuffer)

        // 更新捕获尺寸（这会触发 UI 刷新，包括 bezel 更新）
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let newSize = CGSize(width: width, height: height)

        // 检测尺寸变化（可能是旋转导致）
        if captureSize != newSize {
            let wasLandscape = captureSize.width > captureSize.height
            let isLandscape = width > height
            if wasLandscape != isLandscape {
                AppLogger.capture.info("[旋转] 检测到方向变化: \(wasLandscape ? "横屏" : "竖屏") → \(isLandscape ? "横屏" : "竖屏")")
                AppLogger.capture.info("[旋转] 新尺寸: \(width) x \(height)")
            }
        }

        updateCaptureSize(newSize)

        // 创建 CapturedFrame
        let frame = CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: Int64(CACurrentMediaTime() * 1_000_000), timescale: 1_000_000),
            size: newSize
        )
        emitFrame(frame)

        // 使用 FramePipeline 分发帧到主线程
        // FramePipeline 实现了 scrcpy 的事件合并机制：
        // - 如果上一帧还未被渲染，不发送新的主线程事件
        // - 主线程消费时总是获取最新帧
        // 这避免了主线程任务堆积的问题
        framePipeline.pushFrame(pixelBuffer)
    }

    // MARK: - 回调与状态保护

    private func setLatestPixelBuffer(_ pixelBuffer: CVPixelBuffer?) {
        latestPixelBufferLock.lock()
        latestPixelBufferStorage = pixelBuffer
        latestPixelBufferLock.unlock()
        if pixelBuffer != nil {
            lastFrameArrivalTime = CFAbsoluteTimeGetCurrent()
        }
    }

    private func setCaptureActive(_ active: Bool) {
        captureGateLock.lock()
        isCaptureActive = active
        captureGateLock.unlock()
    }

    private func canHandleFrames() -> Bool {
        captureGateLock.lock()
        let active = isCaptureActive
        captureGateLock.unlock()
        return active
    }

    private func attachDecoderCallback() {
        decoder?.activateCallbacks()
        decoder?.onDecodedFrame = { [weak self] pixelBuffer in
            self?.handleDecodedFrame(pixelBuffer)
        }
    }

    private func deactivateCaptureCallbacks() {
        setCaptureActive(false)
        decoder?.stopAndDrain(clearCallback: true)
        setLatestPixelBuffer(nil)
    }

    // MARK: - 辅助方法

    // MARK: - 常量

    /// 内置 scrcpy-server 版本号
    private static let bundledScrcpyServerVersion = "4.0"

    /// 获取 scrcpy 版本
    /// 直接返回内置 scrcpy-server 的版本号
    private func getScrcpyVersion() -> String {
        Self.bundledScrcpyServerVersion
    }

    /// 启动进程监控
    private func startProcessMonitoring() {
        monitorTask = Task { [weak self] in
            guard let self, let serverProcess else { return }

            // 等待进程退出
            await withCheckedContinuation { continuation in
                serverProcess.terminationHandler = { _ in
                    continuation.resume()
                }
            }

            let exitCode = serverProcess.terminationStatus

            await MainActor.run { [weak self] in
                guard let self else { return }

                // 退出码 0 表示正常退出，15 (SIGTERM) 表示被主动终止（也是正常情况）
                let isNormalExit = exitCode == 0 || exitCode == 15 // SIGTERM

                if !isNormalExit, state != .disconnected {
                    AppLogger.connection.error("scrcpy-server 进程异常退出，退出码: \(exitCode)")
                    updateState(.error(.processTerminated(exitCode)))
                } else {
                    AppLogger.connection.info("scrcpy-server 进程正常退出")
                    if state == .capturing {
                        updateState(.connected)
                    }
                }
            }
        }
    }

    // MARK: - 帧缓冲统计

    /// 启动帧管道统计任务（生产环境已禁用日志输出）
    private func startPipelineStats() {
        // 保留任务结构以便后续调试使用，但不再输出日志
        pipelineStatsTask = nil
    }

    /// 停止帧管道统计任务
    private func stopPipelineStats() {
        pipelineStatsTask?.cancel()
        pipelineStatsTask = nil
    }

    /// 暂停设备端正在播放的音乐/视频
    /// 说明：scrcpy 断开后手机仍在继续播放，声音会从手机外放出来，
    /// 因此在停止投屏时发送一个媒体暂停按键事件。
    /// 清理设备端残留的 scrcpy-server 进程
    /// 先按类名精确匹配，失败时兜底清理所有 app_process 启动的 scrcpy 实例
    /// 音频无数据流入监控
    /// Android 10 及以下不支持 scrcpy 音频通道，但代码不擅自关闭用户设置，
    /// 改为在等待一段时间仍无音频数据时给出明确提示。
    private var audioWatchdogTask: Task<Void, Never>?

    /// 是否已收到过音频数据
    private var hasReceivedAudioData = false

    /// 启动音频监控
    private func startAudioWatchdog() {
        audioWatchdogTask?.cancel()
        hasReceivedAudioData = false
        guard configuration.audioEnabled else { return }

        audioWatchdogTask = Task { [weak self] in
            // 给服务端足够的启动与首包时间
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !self.hasReceivedAudioData else { return }

            AppLogger.capture.warning("[Scrcpy] 已启用音频但未收到音频数据，设备可能不支持")
            await MainActor.run {
                self.onAudioUnavailable?()
            }
        }
    }

    /// 音频不可用回调（由上层提示用户）
    var onAudioUnavailable: (() -> Void)?

    private func killRemoteScrcpyServer() async {
        guard let adbService else { return }

        // 首选：按主类名精确匹配
        do {
            _ = try await adbService.shell("pkill -f com.genymobile.scrcpy.Server")
            AppLogger.capture.info("[Scrcpy] 已清理设备端 scrcpy-server 进程")
            return
        } catch {
            AppLogger.capture.debug("[Scrcpy] pkill 精确匹配失败: \(error.localizedDescription)")
        }

        // 兜底：部分设备 pkill 权限受限，用 busybox/toybox 的 killall
        do {
            _ = try await adbService.shell("killall -9 app_process 2>/dev/null || true")
            AppLogger.capture.info("[Scrcpy] 已通过 killall 清理设备端进程")
        } catch {
            AppLogger.capture.debug("[Scrcpy] killall 兜底失败: \(error.localizedDescription)")
        }
    }

    private func pauseDeviceMediaPlayback() async {
        guard let adbService else { return }
        do {
            // KEYCODE_MEDIA_PAUSE = 127
            _ = try await adbService.shell("input keyevent 127")
            AppLogger.capture.info("[Scrcpy] 已请求设备暂停媒体播放")
        } catch {
            AppLogger.capture.warning("[Scrcpy] 暂停设备媒体播放失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 控制通道

    /// 设置控制通道
    /// 控制连接在 video/audio 之后建立，由 SocketAcceptor 移交过来
    private func setupControlChannel() {
        let channel = ScrcpyControlChannel(queue: controlQueue)
        controlChannel = channel

        // 输入控制器 → 控制通道
        inputController.inputMode = configuration.inputMode
        inputController.hoverEnabled = configuration.hoverEnabled
        inputController.isEnabled = true
        inputController.sendHandler = { [weak channel] message in
            channel?.send(message) ?? false
        }

        // 设备消息（剪贴板同步等）
        channel.onDeviceMessage = { message in
            switch message {
            case let .clipboard(text):
                AppLogger.capture.debug("[Scrcpy] 设备剪贴板已同步（\(text.count) 字符）")
                ScrcpyClipboardBridge.shared.updateFromDevice(text)
            case let .ackClipboard(sequence):
                AppLogger.capture.debug("[Scrcpy] 设备已确认剪贴板写入，序号: \(sequence)")
            }
        }

        channel.onDisconnected = { [weak self] in
            AppLogger.capture.warning("[Scrcpy] 控制通道已断开，输入注入停止")
            self?.inputController.isEnabled = false
        }

        // 由 SocketAcceptor 在控制连接就绪后回调
        socketAcceptor?.onControlConnectionReady = { [weak channel] connection in
            channel?.attach(connection)
        }

        AppLogger.capture.info("[Scrcpy] 控制通道已创建，模式: \(configuration.inputMode.rawValue)")
    }

    /// 控制通道专用队列（避免输入事件与视频解析互相阻塞）
    private let controlQueue = DispatchQueue(label: "com.screenPresenter.scrcpy.control", qos: .userInteractive)

    /// 清理控制通道
    private func cleanupControlChannel() {
        inputController.resetPointer()
        inputController.isEnabled = false
        inputController.sendHandler = nil

        socketAcceptor?.onControlConnectionReady = nil
        controlChannel?.onDeviceMessage = nil
        controlChannel?.onDisconnected = nil
        controlChannel?.stop()
        controlChannel = nil
    }

    // MARK: - 音频处理

    /// 设置音频组件
    private func setupAudioComponents() {
        // 创建音频流解析器
        audioStreamParser = ScrcpyAudioStreamParser()

        // [调试测试 10b] 测试 regulator.push
        audioStreamParser?.onCodecIdParsed = { [weak self] codecId in
            guard let self else { return }

            let codecName: String
            switch codecId {
            case ScrcpyAudioStreamParser.codecIdOpus:
                codecName = "opus"
                // 创建 OPUS 解码器
                opusDecoder = ScrcpyOpusDecoder()
                opusDecoder?.initialize(codecId: codecId)
            case ScrcpyAudioStreamParser.codecIdAAC:
                codecName = "aac"
            case ScrcpyAudioStreamParser.codecIdRAW:
                codecName = "raw"
            default:
                codecName = String(format: "0x%08x", codecId)
            }
            AppLogger.capture.debug("[音频] codec: \(codecName)")

            // 创建音频播放器
            audioPlayer = AudioPlayer()
            // 恢复每格静音状态（重建播放器后仍保持静音覆盖）
            audioPlayer?.isMuted = isPerDeviceMuted || !UserPreferences.shared.androidAudioEnabled

            // 启用音频调节器
            audioPlayer?.enableRegulator(sampleRate: 48000, channels: 2, targetBufferingMs: 50)

            // 设置 onDecodedAudio 回调
            opusDecoder?.onDecodedAudio = { [weak self] pcmData, format in
                guard let self else { return }

                // 检查是否已初始化
                if audioPlayer?.isInitialized != true {
                    _ = audioPlayer?.initializeFromFormat(format)
                    audioPlayer?.start()
                }

                // 将数据推送到 regulator
                audioPlayer?.processPCMData(pcmData, format: format)
            }
        }

        // 实际调用解码 - 跳过 config 包
        audioStreamParser?.onAudioPacket = { [weak self] data, pts, isConfig, isKeyFrame in
            guard let self else { return }
            // Config 包不是音频数据，跳过
            if isConfig {
                return
            }
            opusDecoder?.decode(data, pts: pts, isKeyFrame: isKeyFrame)
        }
    }

    /// 音频处理队列（避免阻塞网络队列）
    private let audioProcessingQueue = DispatchQueue(label: "com.screenPresenter.audio.processing", qos: .userInitiated)

    /// 处理接收到的音频数据
    private func handleReceivedAudioData(_ data: Data) {
        // 标记已收到音频数据，供 watchdog 判断设备是否真的支持音频
        if !hasReceivedAudioData {
            hasReceivedAudioData = true
            audioWatchdogTask?.cancel()
            audioWatchdogTask = nil
            AppLogger.capture.info("[Scrcpy] 已收到音频数据")
        }

        // 将音频处理移到单独的队列，避免阻塞网络接收
        audioProcessingQueue.async { [weak self] in
            self?.audioStreamParser?.processData(data)
        }
    }

    /// 清理音频组件
    private func cleanupAudioComponents() {
        audioPlayer?.stop()
        audioPlayer?.reset()
        audioPlayer = nil

        aacDecoder?.cleanup()
        aacDecoder = nil

        opusDecoder?.cleanup()
        opusDecoder = nil

        rawDecoder?.cleanup()
        rawDecoder = nil

        currentAudioCodecId = nil

        // 清理音频同步器
        audioSynchronizer?.reset()
        audioSynchronizer = nil

        audioStreamParser?.reset()
        audioStreamParser = nil
    }
}
