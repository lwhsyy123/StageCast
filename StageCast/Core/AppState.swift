//
//  AppState.swift
//  StageCast
//
//  Created by Sun on 2025/12/22.
//
//  全局应用状态
//  管理设备、捕获和渲染状态
//

import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation

// MARK: - 全局应用状态

@MainActor
final class AppState {
    // MARK: - 单例

    static let shared = AppState()

    // MARK: - 状态

    /// 工具链管理器
    private(set) var toolchainManager = ToolchainManager()

    /// iOS 设备提供者
    private(set) var iosDeviceProvider = IOSDeviceProvider()

    /// Android 设备提供者
    private(set) var androidDeviceProvider: AndroidDeviceProvider

    /// iOS 设备源
    private(set) var iosDeviceSource: IOSDeviceSource?

    /// Android 设备源
    private(set) var androidDeviceSource: ScrcpyDeviceSource?

    // MARK: 多设备源（阶段一：按设备启停，面板仍为一台每平台）

    /// 全部 Android 设备源（serial → source）
    private(set) var androidSources: [String: ScrcpyDeviceSource] = [:]

    /// 全部 iOS 设备源（设备 id → source）
    private(set) var iosSources: [String: IOSDeviceSource] = [:]

    /// 录制服务
    private(set) lazy var recordingService = RecordingService { [weak self] in
        self?.currentRecordingFrameSnapshots() ?? []
    }

    /// 是否正在初始化
    private(set) var isInitializing = true

    // MARK: - 发布者

    let stateChangedPublisher = PassthroughSubject<Void, Never>()

    // MARK: - 私有属性

    private var deviceObservationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    private init() {
        androidDeviceProvider = AndroidDeviceProvider(toolchainManager: toolchainManager)
        setupDeviceProvidersObservation()
    }

    /// 监听设备提供者的变化
    private func setupDeviceProvidersObservation() {
        // 监听 iOS 设备列表变化（包括状态变化）
        iosDeviceProvider.$devices
            .dropFirst() // 跳过初始值
            .sink { [weak self] devices in
                self?.stateChangedPublisher.send()
                // 相机权限只在真正插入 iOS 设备时才请求：
                // 启动即弹系统授权框对只用 Android 的用户是纯打扰
                if !devices.isEmpty {
                    Self.requestCameraPermissionIfNeeded()
                }
            }
            .store(in: &cancellables)

        // 监听 Android 设备列表变化
        androidDeviceProvider.$devices
            .dropFirst()
            .sink { [weak self] _ in
                self?.stateChangedPublisher.send()
            }
            .store(in: &cancellables)
    }

    /// 相机权限（iOS 投屏必需）：仅在检测到 iOS 设备时请求一次
    private static var hasRequestedCameraPermission = false

    static func requestCameraPermissionIfNeeded() {
        guard !hasRequestedCameraPermission else { return }
        hasRequestedCameraPermission = true
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            AppLogger.capture.info("相机权限请求结果: \(granted)")
        }
    }

    // MARK: - 公开方法

    /// 初始化应用
    func initialize() async {
        AppLogger.app.info("开始初始化应用")

        // 初始化工具链
        await toolchainManager.setup()

        // 开始监控设备
        iosDeviceProvider.startMonitoring()
        androidDeviceProvider.startMonitoring()

        // 启动设备观察
        startDeviceObservation()

        isInitializing = false
        stateChangedPublisher.send()

        AppLogger.app.info("应用初始化完成")
    }

    /// 清理资源
    func cleanup() async {
        AppLogger.app.info("开始清理资源")

        deviceObservationTask?.cancel()
        _ = await recordingService.stopRecording()

        // 断开所有设备（含多设备源字典中的全部实例）
        for source in iosSources.values {
            await source.stopCapture()
            await source.disconnect()
        }
        for source in androidSources.values {
            await source.stopCapture()
            await source.disconnect()
        }

        // 停止监控
        iosDeviceProvider.stopMonitoring()
        androidDeviceProvider.stopMonitoring()

        AppLogger.app.info("资源清理完成")
    }

    /// 刷新设备
    func refreshDevices() async {
        iosDeviceProvider.refreshDevices()
        await androidDeviceProvider.refreshDevices()
        stateChangedPublisher.send()
    }

    // MARK: - iOS 设备控制

    /// 启动 iOS 捕获
    func startIOSCapture() async throws {
        guard let source = iosDeviceSource else {
            if let device = iosDeviceProvider.devices.first {
                let newSource = IOSDeviceSource(device: device)
                iosDeviceSource = newSource
                try await newSource.connect()
                try await newSource.startCapture()
            } else {
                throw DeviceSourceError.connectionFailed(L10n.error.noDevice(L10n.platform.ios))
            }
            return
        }

        if source.state == .idle || source.state == .disconnected {
            try await source.connect()
        }

        try await source.startCapture()
        stateChangedPublisher.send()
    }

    /// 停止 iOS 捕获
    func stopIOSCapture() async {
        guard let source = iosDeviceSource else { return }
        await source.stopCapture()
        stateChangedPublisher.send()
    }

    // MARK: - Android 设备控制

    /// 启动 Android 捕获
    func startAndroidCapture() async throws {
        guard let source = androidDeviceSource else {
            if let device = androidDeviceProvider.devices.first {
                let newSource = ScrcpyDeviceSource(
                    device: device,
                    toolchainManager: toolchainManager
                )
                androidDeviceSource = newSource
                try await newSource.connect()
                try await newSource.startCapture()
            } else {
                throw DeviceSourceError.connectionFailed(L10n.error.noDevice(L10n.platform.android))
            }
            return
        }

        if source.state == .idle || source.state == .disconnected {
            try await source.connect()
        }

        try await source.startCapture()
        stateChangedPublisher.send()
    }

    /// 停止 Android 捕获
    func stopAndroidCapture() async {
        guard let source = androidDeviceSource else { return }
        await source.stopCapture()
        stateChangedPublisher.send()
    }

    // MARK: 多设备：按设备启停

    /// 指定 Android 设备是否正在投屏
    func isAndroidCapturing(serial: String) -> Bool {
        androidSources[serial]?.state == .capturing
    }

    /// 当前主面板正在投屏的 Android serial（无则 nil）
    var primaryAndroidSerial: String? {
        androidDeviceSource.flatMap { source in
            androidSources.first(where: { $0.value === source })?.key
        }
    }

    // MARK: 物理设备身份（跨 transport 去重）

    /// 一台物理手机在 adb 里可能有多个 transport（USB / 无线调试 TLS 端口 / 5555 明文端口），
    /// 每个 transport 的 serial 不同，若各自建源就会出现「同一台手机两个面板显示同一画面」。
    /// 这里给出稳定的物理身份键：persist.adb.wifi.guid > 无线 host IP > serial。
    static func physicalIdentity(of device: AndroidDevice) -> String {
        if let guid = device.wirelessGUID, !guid.isEmpty {
            return "guid:" + guid
        }
        if device.connectionType == .wifi {
            let host = device.serial.split(separator: ":").first.map(String.init) ?? ""
            if host.contains(".") || host.lowercased().hasPrefix("adb-") {
                return "host:" + host.lowercased()
            }
        }
        return "serial:" + device.serial
    }

    /// 已知 serial 对应的物理身份（设备不在列表里时退化为 serial 本身）
    func physicalIdentity(forSerial serial: String) -> String {
        guard let device = androidDeviceProvider.devices.first(where: { $0.serial == serial }) else {
            return "serial:" + serial
        }
        return Self.physicalIdentity(of: device)
    }

    /// 正在投屏的 Android 源，按物理设备去重：同一台手机只保留一个（优先 USB，其次 TLS 端口，最后 5555）
    var capturingAndroidSourcesDeduped: [(serial: String, source: ScrcpyDeviceSource)] {
        var ordered: [String] = []
        var best: [String: (serial: String, source: ScrcpyDeviceSource, score: Int)] = [:]

        for (serial, source) in androidSources where source.state == .capturing {
            let key = physicalIdentity(forSerial: serial)
            let device = androidDeviceProvider.devices.first(where: { $0.serial == serial })
            let score: Int
            if device?.connectionType == .usb {
                score = 0
            } else if serial.hasSuffix(":5555") {
                score = 2
            } else {
                score = 1
            }
            if let existing = best[key] {
                if score < existing.score {
                    best[key] = (serial, source, score)
                }
            } else {
                ordered.append(key)
                best[key] = (serial, source, score)
            }
        }

        return ordered.compactMap { key in
            guard let entry = best[key] else { return nil }
            return (entry.serial, entry.source)
        }
    }

    /// 正在投屏的物理设备数（Android 去重后 + iOS）
    var capturingPhysicalDeviceCount: Int {
        let iosCount = iosSources.values.filter { $0.state == .capturing }.count
        return capturingAndroidSourcesDeduped.count + iosCount
    }

    /// 启动指定 Android 设备的投屏
    /// 面板空闲 → 成为当前主面板设备；面板被其他设备占用 → 由调用方决定是否切换
    func startAndroidCapture(device: AndroidDevice) async throws {
        let serial = device.serial

        // 同一台物理手机可能换了 transport（mDNS TLS 端口 ↔ 5555）：若已有同物理设备的源在投屏，
        // 直接复用，避免"同一台手机建两个源 → 两个面板显示同一画面"。
        let identity = Self.physicalIdentity(of: device)
        if androidSources[serial] == nil,
           let sibling = androidSources.first(where: { physicalIdentity(forSerial: $0.key) == identity }) {
            if sibling.value.state == .capturing {
                androidDeviceSource = sibling.value
                stateChangedPublisher.send()
                return
            }
        }

        if let existing = androidSources[serial] {
            // 已有源：恢复/继续投屏
            if existing.state == .capturing { return }
            if case .error = existing.state {
                // 掉线/启动失败后源停在 error，connect() 会被守卫拒绝：
                // 先彻底停止并复位状态，再重建连接
                await existing.stopCapture()
                existing.resetForReconnect()
            }
            if existing.state == .idle || existing.state == .disconnected {
                try await existing.connect()
            }
            try await existing.startCapture()
            androidDeviceSource = existing
            stateChangedPublisher.send()
            return
        }

        let newSource = ScrcpyDeviceSource(device: device, toolchainManager: toolchainManager)
        androidSources[serial] = newSource
        try await newSource.connect()
        try await newSource.startCapture()
        androidDeviceSource = newSource
        recordWirelessEndpoint(for: device)
        stateChangedPublisher.send()
    }

    /// 停止指定 Android 设备的投屏
    func stopAndroidCapture(serial: String) async {
        guard let source = androidSources[serial] else { return }
        await source.stopCapture()
        if androidDeviceSource === source {
            androidDeviceSource = nil
        }
        removeWirelessEndpoint(forSerial: serial)
        stateChangedPublisher.send()
    }

    // MARK: 无线会话自动恢复

    /// 记录无线设备端点（host:port 或 mDNS serial），供下次启动自动恢复投屏
    private func recordWirelessEndpoint(for device: AndroidDevice) {
        guard device.connectionType == .wifi else { return }
        // host:port（adb connect）与 mDNS serial（adb-<guidhash>-<instance>）都记录；
        // mDNS 实例后缀每次广播会变，恢复时按 GUID 前缀匹配
        let endpoint = device.serial
        guard endpoint.contains(":") || endpoint.hasPrefix("adb-") else { return }
        var list = UserPreferences.shared.lastWirelessEndpoints
        if !list.contains(endpoint) { list.append(endpoint) }
        if list.count > 4 { list = Array(list.suffix(4)) }
        UserPreferences.shared.lastWirelessEndpoints = list
        AppLogger.device.info("[AutoRestore] 已记录无线端点 \(endpoint)")
    }

    /// 移除已停止投屏的无线端点
    private func removeWirelessEndpoint(forSerial serial: String) {
        var list = UserPreferences.shared.lastWirelessEndpoints
        let isMDNS = !serial.contains(":") && serial.hasPrefix("adb-")
        let mdnsGUIDPrefix = isMDNS
            ? serial.split(separator: "-").prefix(2).joined(separator: "-")
            : nil
        let host = serial.split(separator: ":").first.map(String.init) ?? serial
        let before = list.count
        list.removeAll {
            if $0 == serial { return true }
            if let prefix = mdnsGUIDPrefix, $0.hasPrefix(prefix) { return true }
            return $0.split(separator: ":").first.map(String.init) == host
        }
        if list.count != before {
            UserPreferences.shared.lastWirelessEndpoints = list
        }
    }

    /// 启动指定 iOS 设备的投屏
    func startIOSCapture(device: IOSDevice) async throws {
        let key = device.id

        if let existing = iosSources[key] {
            if existing.state == .capturing { return }
            if existing.state == .idle || existing.state == .disconnected {
                try await existing.connect()
            }
            try await existing.startCapture()
            iosDeviceSource = existing
            stateChangedPublisher.send()
            return
        }

        let newSource = IOSDeviceSource(device: device)
        iosSources[key] = newSource
        try await newSource.connect()
        try await newSource.startCapture()
        iosDeviceSource = newSource
        stateChangedPublisher.send()
    }

    /// 停止指定 iOS 设备的投屏
    func stopIOSCapture(deviceID: String) async {
        guard let source = iosSources[deviceID] else { return }
        await source.stopCapture()
        if iosDeviceSource === source {
            iosDeviceSource = nil
        }
        stateChangedPublisher.send()
    }

    // MARK: - 私有方法

    /// 启动设备观察
    private func startDeviceObservation() {
        deviceObservationTask?.cancel()
        deviceObservationTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await checkAndUpdateDeviceSources()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
            }
        }
    }

    /// 检查并更新设备源
    private func checkAndUpdateDeviceSources() async {
        // 处理 iOS 设备变化
        await handleIOSDeviceChange()

        // 处理 Android 设备变化
        await handleAndroidDeviceChange()
    }

    /// 处理 iOS 设备变化
    private func handleIOSDeviceChange() async {
        let currentDevice = iosDeviceProvider.devices.first

        if let device = currentDevice {
            // 设备已连接
            // 使用 avUniqueID 比较设备（保持不变），而不是 id（可能从 avUniqueID 变成真实 UDID）
            // 这样当设备信息被 enriched() 增强时，不会错误地停止正在运行的捕获
            if iosDeviceSource == nil || iosDeviceSource?.iosDevice.avUniqueID != device.avUniqueID {
                // 多设备网格：主源正在投屏时不自动替换
                if let oldSource = iosDeviceSource,
                   oldSource.state == .capturing || oldSource.state == .connecting {
                    return
                }

                // 该设备已有多设备源（网格建立过）：直接复用（按 avUniqueID 匹配，避开 id 漂移）
                if let existing = iosSources.values.first(where: { $0.iosDevice.avUniqueID == device.avUniqueID }) {
                    iosDeviceSource = existing
                    stateChangedPublisher.send()
                    return
                }

                // 断开旧设备（空闲状态才会走到这里）
                if let oldSource = iosDeviceSource {
                    await oldSource.stopCapture()
                    await oldSource.disconnect()
                }

                // 创建新设备源（不自动捕获）
                let source = IOSDeviceSource(device: device)
                iosSources[device.id] = source
                iosDeviceSource = source

                // 使用增强的设备信息记录日志
                var logMessage = "iOS 设备已连接: \(device.displayName)"
                if let modelName = device.displayModelName {
                    logMessage += " (\(modelName))"
                }
                AppLogger.device.info("\(logMessage)")

                // 如果有用户提示，单独记录
                if let prompt = device.userPrompt {
                    AppLogger.device.warning("iOS 设备状态: \(prompt)")
                }

                stateChangedPublisher.send()
            }
        } else {
            // 设备已断开：主源正在投屏时不动（源层会自行转入断开状态）；空闲主源立即清理
            if let source = iosDeviceSource, source.state != .capturing {
                await source.stopCapture()
                await source.disconnect()
                iosDeviceSource = nil

                AppLogger.device.info("iOS 设备已断开")
                stateChangedPublisher.send()
            }
        }
    }

    /// 处理 Android 设备变化
    private func handleAndroidDeviceChange() async {
        let currentDevice = androidDeviceProvider.devices.first

        if let device = currentDevice {
            // 设备已连接
            if androidDeviceSource == nil || androidDeviceSource?.deviceInfo?.id != device.serial {
                // 多设备网格：主源正在投屏时不自动替换（等它空闲后再切换）
                if let oldSource = androidDeviceSource,
                   oldSource.state == .capturing || oldSource.state == .connecting {
                    return
                }

                // 该设备已有多设备源（网格建立过）：直接复用
                if let existing = androidSources[device.serial] {
                    androidDeviceSource = existing
                    stateChangedPublisher.send()
                    return
                }

                // 断开旧设备（空闲状态才会走到这里）
                if let oldSource = androidDeviceSource {
                    await oldSource.stopCapture()
                    await oldSource.disconnect()
                }

                // 创建新设备源（不自动捕获）
                let source = ScrcpyDeviceSource(
                    device: device,
                    toolchainManager: toolchainManager
                )
                androidSources[device.serial] = source
                androidDeviceSource = source

                AppLogger.device.info("Android 设备已连接: \(device.displayName)")
                stateChangedPublisher.send()
            }
        } else {
            // 设备已断开：主源正在投屏时不动（源层 socket 关闭会自行转入断开状态，
            // 网格面板随 state 过滤自动移除）；空闲主源立即清理
            if let source = androidDeviceSource, source.state != .capturing {
                await source.stopCapture()
                await source.disconnect()
                androidDeviceSource = nil

                AppLogger.device.info("Android 设备已断开")
                stateChangedPublisher.send()
            }
        }
    }

    /// 获取当前所有正在投屏设备的帧快照（含 grid 里并发的多台设备）。
    /// 录制服务持续采样这里，因此录制开始后才启动投屏的设备也会自动加入候选池；
    /// 具体录哪几台由 RecordingService.recordingDeviceIDs 决定。
    private func currentRecordingFrameSnapshots() -> [RecordingFrameSnapshot] {
        var snapshots: [RecordingFrameSnapshot] = []

        for (deviceID, source) in iosSources where source.state == .capturing {
            guard let pixelBuffer = source.latestFrame?.pixelBuffer else { continue }
            snapshots.append(RecordingFrameSnapshot(
                platform: .ios,
                deviceID: deviceID,
                deviceName: iosDeviceProvider.devices.first { $0.id == deviceID }?.displayName
                    ?? L10n.platform.ios,
                pixelBuffer: pixelBuffer
            ))
        }

        for (serial, source) in androidSources where source.state == .capturing {
            guard let pixelBuffer = source.latestPixelBuffer ?? source.latestFrame?.pixelBuffer else { continue }
            snapshots.append(RecordingFrameSnapshot(
                platform: .android,
                deviceID: serial,
                deviceName: androidDeviceProvider.devices.first { $0.serial == serial }?.displayName
                    ?? currentAndroidDevice?.displayName
                    ?? L10n.platform.android,
                pixelBuffer: pixelBuffer
            ))
        }

        return snapshots
    }

    // MARK: - 计算属性

    /// 当前 iOS 设备（用于获取完整设备信息）
    var currentIOSDevice: IOSDevice? {
        iosDeviceProvider.devices.first
    }

    /// iOS 是否已连接
    var iosConnected: Bool {
        currentIOSDevice != nil
    }

    /// iOS 设备名称（优先使用 FBDeviceControl 增强的名称）
    var iosDeviceName: String? {
        currentIOSDevice?.displayName
    }

    /// iOS 设备型号名称
    var iosDeviceModelName: String? {
        currentIOSDevice?.displayModelName
    }

    /// iOS 设备用户提示（信任状态、占用状态等）
    var iosDeviceUserPrompt: String? {
        currentIOSDevice?.userPrompt
    }

    /// iOS 是否正在捕获
    var iosCapturing: Bool {
        iosDeviceSource?.state == .capturing
    }

    /// Android 是否已连接
    var androidConnected: Bool {
        !androidDeviceProvider.devices.isEmpty
    }

    /// 当前 Android 设备
    var currentAndroidDevice: AndroidDevice? {
        androidDeviceProvider.devices.first
    }

    /// Android 设备名称
    var androidDeviceName: String? {
        currentAndroidDevice?.displayName
    }

    /// Android 设备型号名称（用于副标题显示，如 "OnePlus PKX110"）
    var androidDeviceModelName: String? {
        guard let device = currentAndroidDevice else { return nil }
        // 返回品牌 + 型号组合，与标题的 marketName 区分
        if let brand = device.brand, let model = device.model {
            let formattedModel = model.replacingOccurrences(of: "_", with: " ")
            return "\(brand) \(formattedModel)"
        }
        return device.model?.replacingOccurrences(of: "_", with: " ")
    }

    /// Android 系统版本
    var androidDeviceSystemVersion: String? {
        currentAndroidDevice?.displaySystemVersion
    }

    /// Android SDK 版本（如 "31"）
    var androidDeviceSdkVersion: String? {
        currentAndroidDevice?.sdkVersion
    }

    /// Android 设备状态
    var androidDeviceState: AndroidDeviceState? {
        currentAndroidDevice?.state
    }

    /// Android 设备用户提示（授权状态等）
    var androidDeviceUserPrompt: String? {
        currentAndroidDevice?.state.actionHint
    }

    /// Android 设备是否可捕获（已授权）
    var androidDeviceReady: Bool {
        currentAndroidDevice?.state == .device
    }

    /// Android 是否正在捕获
    var androidCapturing: Bool {
        androidDeviceSource?.state == .capturing
    }
}
