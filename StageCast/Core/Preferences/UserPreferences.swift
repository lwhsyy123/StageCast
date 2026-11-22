//
//  UserPreferences.swift
//  StageCast
//
//  Created by Sun on 2025/12/22.
//
//  用户偏好设置
//  持久化存储用户的各项配置选项
//

import AppKit
import Foundation

// MARK: - Scrcpy 编解码器类型

/// Scrcpy 编解码器类型
enum ScrcpyCodecType: String, CaseIterable {
    case h264
    case h265

    var displayName: String {
        switch self {
        case .h264: "H.264"
        case .h265: "H.265 (HEVC)"
        }
    }
}

// MARK: - 用户偏好设置模型

/// 用户偏好设置
final class UserPreferences {
    // MARK: - Singleton

    static let shared = UserPreferences()

    // MARK: - Keys

    private enum Keys {
        static let iosOnLeft = "iosOnLeft"
        static let layoutMode = "layoutMode"
        static let gridPageSize = "gridPageSize"
        static let dualSplitRatio = "dualSplitRatio"
        static let gridColumnSplit = "gridColumnSplit"
        static let gridRowSplit = "gridRowSplit"
        static let gridDeviceOrder = "gridDeviceOrder"
        static let gridFocusedDeviceID = "gridFocusedDeviceID"
        static let floatingWindowFrames = "floatingWindowFrames"
        static let autoLayout = "autoLayout"
    static let lastWirelessEndpoints = "lastWirelessEndpoints"
        static let appLanguage = "appLanguage"
        static let backgroundOpacity = "backgroundOpacity"
        static let showDeviceBezel = "showDeviceBezel"
        static let captureFrameRate = "captureFrameRate"
        static let scrcpyBitrate = "scrcpyBitrate"
        static let scrcpyMaxSize = "scrcpyMaxSize"
        static let scrcpyShowTouches = "scrcpyShowTouches"
        static let showCaptureInfoStats = "showCaptureInfoStats"
        static let showMirrorStats = "showMirrorStats"
        static let showDeviceControlBar = "showDeviceControlBar"
        static let showDeviceCameraOverlay = "showDeviceCameraOverlay"
        static let gridDoubleClickFocusEnabled = "gridDoubleClickFocusEnabled"
        static let hideWindowChrome = "hideWindowChrome"
        static let autoMinimizeInFloatingMode = "autoMinimizeInFloatingMode"
        static let scrcpyPortRangeStart = "scrcpyPortRangeStart"
        static let scrcpyPortRangeEnd = "scrcpyPortRangeEnd"
        static let scrcpyCodec = "scrcpyCodec"
        static let androidControlEnabled = "androidControlEnabled"
        static let androidControlMode = "androidControlMode"
        static let androidControlHover = "androidControlHover"
        // 自定义路径
        static let customAdbPath = "customAdbPath"
        static let customScrcpyServerPath = "customScrcpyServerPath"
        static let useCustomAdbPath = "useCustomAdbPath"
        static let useCustomScrcpyServerPath = "useCustomScrcpyServerPath"
        // 电源管理
        static let preventAutoLockDuringCapture = "preventAutoLockDuringCapture"
        // 音频设置
        static let iosAudioEnabled = "iosAudioEnabled"
        static let iosAudioVolume = "iosAudioVolume"
        static let androidAudioEnabled = "androidAudioEnabled"
        static let androidAudioVolume = "androidAudioVolume"
        static let androidAudioCodec = "androidAudioCodec"
        // 投屏录制
        static let recordingSaveDirectory = "recordingSaveDirectory"
        static let recordingMicrophoneEnabled = "recordingMicrophoneEnabled"
    }

    // MARK: - UserDefaults

    private let defaults = UserDefaults.standard
    /// 本次应用启动时 iOS 音频捕获开关快照（运行期偏好改动需重启后生效）
    private var iosAudioEnabledAtLaunch: Bool = false
    /// 本次应用启动时 Android 音频捕获开关快照（运行期偏好改动需重启后生效）
    private var androidAudioEnabledAtLaunch: Bool = false

    // MARK: - Layout Settings

    /// iOS 设备是否在左侧（默认 true：左 iOS | 右 Android）
    var iosOnLeft: Bool {
        get {
            // 如果从未设置过，默认为 true
            if defaults.object(forKey: Keys.iosOnLeft) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.iosOnLeft)
        }
        set {
            defaults.set(newValue, forKey: Keys.iosOnLeft)
        }
    }

    /// 布局模式（默认 auto：按投屏设备数自动排列）
    var layoutMode: PreviewLayoutMode {
        get {
            guard let raw = defaults.string(forKey: Keys.layoutMode) else {
                return .auto
            }
            // 兼容旧版本取值（dual/leftOnly/rightOnly → auto/grid）
            return PreviewLayoutMode.migrated(from: raw)
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.layoutMode)
            // 发送通知更新 UI
            NotificationCenter.default.post(name: .layoutModeDidChange, object: nil)
        }
    }

    /// 自动布局：按正在投屏的设备数切换布局（1→网格居中，2→并排，3+→网格）。手动切换布局时自动关闭。
    var autoLayout: Bool {
        get {
            if defaults.object(forKey: Keys.autoLayout) == nil { return true }
            return defaults.bool(forKey: Keys.autoLayout)
        }
        set { defaults.set(newValue, forKey: Keys.autoLayout) }
    }

    /// 网格布局支持的每页设备数预设（0 表示自动）
    static let gridPageSizePresets: [Int] = [1, 2, 4, 6, 9, 16]

    /// 网格布局每页设备数：0 = 自动（按设备数选择最小预设），否则为 1/4/6/9/16
    var gridPageSize: Int {
        get {
            let value = defaults.integer(forKey: Keys.gridPageSize)
            return Self.gridPageSizePresets.contains(value) ? value : 0
        }
        set {
            let clamped = Self.gridPageSizePresets.contains(newValue) ? newValue : 0
            defaults.set(clamped, forKey: Keys.gridPageSize)
            NotificationCenter.default.post(name: .gridPageSizeDidChange, object: nil)
        }
    }

    // MARK: - 分隔条拖拽（多设备布局记忆）

    /// 双设备布局左右比例：左格占可用宽度的比例（0.25 - 0.75，默认 0.5）
    var dualSplitRatio: CGFloat {
        get {
            guard defaults.object(forKey: Keys.dualSplitRatio) != nil else { return 0.5 }
            return CGFloat(min(max(defaults.double(forKey: Keys.dualSplitRatio), 0.25), 0.75))
        }
        set {
            defaults.set(Double(min(max(newValue, 0.25), 0.75)), forKey: Keys.dualSplitRatio)
        }
    }

    /// 网格列分割点（累计比例，长度 = 列数-1，升序 0-1；空数组 = 均分）
    var gridColumnSplit: [CGFloat] {
        get {
            guard let values = defaults.array(forKey: Keys.gridColumnSplit) as? [Double] else { return [] }
            return values.map { CGFloat(min(max($0, 0.05), 0.95)) }.sorted()
        }
        set { defaults.set(newValue.map { Double($0) }, forKey: Keys.gridColumnSplit) }
    }

    /// 网格行分割点（累计比例，长度 = 行数-1，升序 0-1；空数组 = 均分）
    var gridRowSplit: [CGFloat] {
        get {
            guard let values = defaults.array(forKey: Keys.gridRowSplit) as? [Double] else { return [] }
            return values.map { CGFloat(min(max($0, 0.05), 0.95)) }.sorted()
        }
        set { defaults.set(newValue.map { Double($0) }, forKey: Keys.gridRowSplit) }
    }

    /// 网格设备顺序（拖拽换位持久化；未知设备按原相对顺序排在已记住设备之后）
    var gridDeviceOrder: [String] {
        get { defaults.stringArray(forKey: Keys.gridDeviceOrder) ?? [] }
        set { defaults.set(newValue, forKey: Keys.gridDeviceOrder) }
    }

    /// 网格双击聚焦的设备 ID（nil = 网格模式；跨重启持久化）
    var gridFocusedDeviceID: String? {
        get { defaults.string(forKey: Keys.gridFocusedDeviceID) }
        set { newValue == nil ? defaults.removeObject(forKey: Keys.gridFocusedDeviceID) : defaults.set(newValue!, forKey: Keys.gridFocusedDeviceID) }
    }

    /// 独立浮窗的位置记忆（设备 ID → 屏幕坐标 frame）
    /// 用户把窗口拖到喜欢的位置后，下次投屏仍回到原处
    func floatingWindowFrame(for id: String) -> NSRect? {
        guard
            let all = defaults.dictionary(forKey: Keys.floatingWindowFrames),
            let values = all[id] as? [Double],
            values.count == 4
        else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    func setFloatingWindowFrame(_ frame: NSRect, for id: String) {
        var all = defaults.dictionary(forKey: Keys.floatingWindowFrames) ?? [:]
        all[id] = [
            Double(frame.origin.x),
            Double(frame.origin.y),
            Double(frame.size.width),
            Double(frame.size.height)
        ]
        defaults.set(all, forKey: Keys.floatingWindowFrames)
    }

    func removeFloatingWindowFrame(for id: String) {
        guard var all = defaults.dictionary(forKey: Keys.floatingWindowFrames) else { return }
        all.removeValue(forKey: id)
        defaults.set(all, forKey: Keys.floatingWindowFrames)
    }

    /// 上次投屏的无线设备端点（host:port，用于启动后自动恢复无线会话）
    var lastWirelessEndpoints: [String] {
        get { defaults.stringArray(forKey: Keys.lastWirelessEndpoints) ?? [] }
        set { defaults.set(newValue, forKey: Keys.lastWirelessEndpoints) }
    }

    // MARK: - Display Settings

    /// 应用语言
    var appLanguage: AppLanguage {
        get {
            guard
                let raw = defaults.string(forKey: Keys.appLanguage),
                let lang = AppLanguage(rawValue: raw)
            else {
                return .system
            }
            return lang
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.appLanguage)
            LocalizationManager.shared.setLanguage(newValue)
        }
    }

    /// 背景透明度 (0.0 - 1.0)
    var backgroundOpacity: CGFloat {
        get {
            let value = defaults.double(forKey: Keys.backgroundOpacity)
            // 如果值为 0 且从未设置过，返回默认值 1.0
            if value == 0, defaults.object(forKey: Keys.backgroundOpacity) == nil {
                return 1.0
            }
            return CGFloat(value)
        }
        set {
            defaults.set(Double(newValue), forKey: Keys.backgroundOpacity)
        }
    }

    /// 获取背景色（固定黑色，透明度可调）
    var backgroundColor: NSColor {
        NSColor.black.withAlphaComponent(backgroundOpacity)
    }

    /// 是否显示设备边框（默认 true）
    /// 边框是本项目的核心特性：按机型渲染灵动岛/刘海/打孔/侧键与圆角。
    var showDeviceBezel: Bool {
        get {
            if defaults.object(forKey: Keys.showDeviceBezel) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showDeviceBezel)
        }
        set {
            defaults.set(newValue, forKey: Keys.showDeviceBezel)
            // 发送通知更新 UI
            NotificationCenter.default.post(name: .deviceBezelVisibilityDidChange, object: nil)
        }
    }

    // MARK: - 摄像头打孔显示

    /// 在设备边框上显示摄像头（打孔/灵动岛/刘海）装饰。
    /// 机型识别不准确时用户可在设置中关闭（默认开启）。
    var showDeviceCameraOverlay: Bool {
        get {
            if defaults.object(forKey: Keys.showDeviceCameraOverlay) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showDeviceCameraOverlay)
        }
        set {
            defaults.set(newValue, forKey: Keys.showDeviceCameraOverlay)
            NotificationCenter.default.post(name: .deviceBezelVisibilityDidChange, object: nil)
        }
    }

    /// 网格布局中双击面板聚焦到单画面（默认开启）
    var gridDoubleClickFocusEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.gridDoubleClickFocusEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.gridDoubleClickFocusEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.gridDoubleClickFocusEnabled)
        }
    }

    // MARK: - Power Settings

    /// 捕获期间禁止自动锁屏（默认 true）
    var preventAutoLockDuringCapture: Bool {
        get {
            // 如果从未设置过，默认为 true（推荐在捕获时阻止休眠）
            if defaults.object(forKey: Keys.preventAutoLockDuringCapture) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.preventAutoLockDuringCapture)
        }
        set {
            defaults.set(newValue, forKey: Keys.preventAutoLockDuringCapture)
            // 发送通知更新 UI 和协调器
            NotificationCenter.default.post(name: .preventAutoLockSettingDidChange, object: nil)
        }
    }

    // MARK: - Capture Settings

    /// 捕获帧率
    var captureFrameRate: Int {
        get {
            let value = defaults.integer(forKey: Keys.captureFrameRate)
            return value > 0 ? value : 60
        }
        set { defaults.set(newValue, forKey: Keys.captureFrameRate) }
    }

    // MARK: - scrcpy Settings

    /// 码率（Mbps）
    var scrcpyBitrate: Int {
        get {
            let value = defaults.integer(forKey: Keys.scrcpyBitrate)
            return value > 0 ? value : 8
        }
        set { defaults.set(newValue, forKey: Keys.scrcpyBitrate) }
    }

    /// 最大分辨率（0 表示不限制）
    var scrcpyMaxSize: Int {
        get {
            // 需要区分"未设置"和"设置为 0（不限制）"
            if defaults.object(forKey: Keys.scrcpyMaxSize) == nil {
                return 0 // 默认值
            }
            return defaults.integer(forKey: Keys.scrcpyMaxSize)
        }
        set { defaults.set(newValue, forKey: Keys.scrcpyMaxSize) }
    }

    /// 显示触摸点
    var scrcpyShowTouches: Bool {
        get { defaults.bool(forKey: Keys.scrcpyShowTouches) }
        set { defaults.set(newValue, forKey: Keys.scrcpyShowTouches) }
    }

    /// 浮层是否显示帧率与分辨率等统计信息
    /// 统一使用 showMirrorStats 单一键（渲染层 DevicePanelView 读取同一键），
    /// 修复此前勾选框写 showCaptureInfoStats 而角标读 showMirrorStats 导致开关无效的问题
    var showCaptureInfoStats: Bool {
        get {
            if defaults.object(forKey: Keys.showMirrorStats) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showMirrorStats)
        }
        set {
            defaults.set(newValue, forKey: Keys.showMirrorStats)
            NotificationCenter.default.post(name: .captureInfoVisibilityDidChange, object: nil)
        }
    }


    /// 是否隐藏窗口标题栏与工具栏（只留画面）
    var hideWindowChrome: Bool {
        get { defaults.bool(forKey: Keys.hideWindowChrome) }
        set {
            defaults.set(newValue, forKey: Keys.hideWindowChrome)
            NotificationCenter.default.post(name: .windowChromeVisibilityDidChange, object: nil)
        }
    }

    /// 浮窗模式下是否自动把主窗口最小化到 Dock
    /// 浮窗模式下主窗口里没有任何画面（每台设备各自独立窗口），
    /// 留着只会挡在桌面中间；最小化后点 Dock 图标即可恢复，功能不丢。
    var autoMinimizeInFloatingMode: Bool {
        get {
            if defaults.object(forKey: Keys.autoMinimizeInFloatingMode) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.autoMinimizeInFloatingMode)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoMinimizeInFloatingMode)
        }
    }

    /// 是否显示独立的设备控制按钮条（音量/电源/旋转/主屏幕/返回）
    var showDeviceControlBar: Bool {
        get {
            if defaults.object(forKey: Keys.showDeviceControlBar) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showDeviceControlBar)
        }
        set {
            defaults.set(newValue, forKey: Keys.showDeviceControlBar)
            NotificationCenter.default.post(name: .captureInfoVisibilityDidChange, object: nil)
        }
    }


    /// 投屏画面右上角是否常显分辨率和帧率角标（默认开启）
    /// 与旧的悬停信息浮层不同：这个角标一直显示在小胶囊里，鼠标不需要悬停
    var showMirrorStats: Bool {
        get {
            if defaults.object(forKey: Keys.showMirrorStats) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showMirrorStats)
        }
        set {
            defaults.set(newValue, forKey: Keys.showMirrorStats)
            NotificationCenter.default.post(name: .captureInfoVisibilityDidChange, object: nil)
        }
    }

    /// 是否允许用鼠标/键盘操作 Android 设备（默认开启）
    var androidControlEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.androidControlEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.androidControlEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.androidControlEnabled) }
    }

    /// 输入模式（鼠标 / 触摸）
    var androidControlMode: ScrcpyInputMode {
        get {
            guard
                let raw = defaults.string(forKey: Keys.androidControlMode),
                let mode = ScrcpyInputMode(rawValue: raw)
            else {
                return .mouse
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.androidControlMode) }
    }

    /// 是否发送鼠标悬停事件（仅鼠标模式生效）
    var androidControlHover: Bool {
        get { defaults.bool(forKey: Keys.androidControlHover) }
        set { defaults.set(newValue, forKey: Keys.androidControlHover) }
    }

    /// scrcpy 端口范围起始（默认 27183，与 scrcpy 官方一致）
    var scrcpyPortRangeStart: Int {
        get {
            let value = defaults.integer(forKey: Keys.scrcpyPortRangeStart)
            return value > 0 ? value : 27183
        }
        set { defaults.set(newValue, forKey: Keys.scrcpyPortRangeStart) }
    }

    /// scrcpy 端口范围结束（默认 27199，支持最多 17 个并发连接）
    var scrcpyPortRangeEnd: Int {
        get {
            let value = defaults.integer(forKey: Keys.scrcpyPortRangeEnd)
            return value > 0 ? value : 27199
        }
        set { defaults.set(newValue, forKey: Keys.scrcpyPortRangeEnd) }
    }

    /// 端口范围（便捷属性）
    var scrcpyPortRange: ClosedRange<Int> {
        let start = scrcpyPortRangeStart
        let end = scrcpyPortRangeEnd
        // 确保 start <= end
        return min(start, end)...max(start, end)
    }

    /// scrcpy 编解码器（h264/h265，默认 h264）
    var scrcpyCodec: ScrcpyCodecType {
        get {
            guard
                let raw = defaults.string(forKey: Keys.scrcpyCodec),
                let codec = ScrcpyCodecType(rawValue: raw)
            else {
                return .h264
            }
            return codec
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.scrcpyCodec) }
    }

    // MARK: - Custom Tool Paths

    /// 是否使用自定义 adb 路径
    var useCustomAdbPath: Bool {
        get { defaults.bool(forKey: Keys.useCustomAdbPath) }
        set { defaults.set(newValue, forKey: Keys.useCustomAdbPath) }
    }

    /// 自定义 adb 路径
    var customAdbPath: String? {
        get { defaults.string(forKey: Keys.customAdbPath) }
        set { defaults.set(newValue, forKey: Keys.customAdbPath) }
    }

    /// 是否使用自定义 scrcpy-server 路径
    var useCustomScrcpyServerPath: Bool {
        get { defaults.bool(forKey: Keys.useCustomScrcpyServerPath) }
        set { defaults.set(newValue, forKey: Keys.useCustomScrcpyServerPath) }
    }

    /// 自定义 scrcpy-server 路径
    var customScrcpyServerPath: String? {
        get { defaults.string(forKey: Keys.customScrcpyServerPath) }
        set { defaults.set(newValue, forKey: Keys.customScrcpyServerPath) }
    }

    // MARK: - Audio Settings

    /// iOS 音频是否启用（默认 false，需要用户手动启用）
    var iosAudioEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.iosAudioEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.iosAudioEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.iosAudioEnabled)
            NotificationCenter.default.post(name: .audioSettingsDidChange, object: nil, userInfo: ["platform": "ios"])
        }
    }

    /// iOS 音频音量 (0.0 - 1.0，默认 1.0)
    var iosAudioVolume: Float {
        get {
            let value = defaults.float(forKey: Keys.iosAudioVolume)
            if value == 0, defaults.object(forKey: Keys.iosAudioVolume) == nil {
                return 1.0
            }
            return value
        }
        set {
            defaults.set(newValue, forKey: Keys.iosAudioVolume)
            NotificationCenter.default.post(name: .audioSettingsDidChange, object: nil, userInfo: ["platform": "ios"])
        }
    }

    /// Android 音频是否启用（默认 false，需要用户手动启用）
    /// Android 音频投屏（默认开启）
    /// 不做 Android 版本自动降级：部分设备虽低于 Android 11 仍可能通过其他路径支持，
    /// 代码不擅自关闭用户设置，改为在实际无音频数据流入时给出提示。
    var androidAudioEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.androidAudioEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.androidAudioEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.androidAudioEnabled)
            NotificationCenter.default.post(
                name: .audioSettingsDidChange,
                object: nil,
                userInfo: ["platform": "android"]
            )
        }
    }

    /// Android 音频音量 (0.0 - 1.0，默认 1.0)
    var androidAudioVolume: Float {
        get {
            let value = defaults.float(forKey: Keys.androidAudioVolume)
            if value == 0, defaults.object(forKey: Keys.androidAudioVolume) == nil {
                return 1.0
            }
            return value
        }
        set {
            defaults.set(newValue, forKey: Keys.androidAudioVolume)
            NotificationCenter.default.post(
                name: .audioSettingsDidChange,
                object: nil,
                userInfo: ["platform": "android"]
            )
        }
    }

    /// Android 音频编解码器（默认 opus）
    var androidAudioCodec: ScrcpyConfiguration.AudioCodec {
        get {
            guard
                let rawValue = defaults.string(forKey: Keys.androidAudioCodec),
                let codec = ScrcpyConfiguration.AudioCodec(rawValue: rawValue) else {
                return .opus
            }
            return codec
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.androidAudioCodec)
            NotificationCenter.default.post(
                name: .audioSettingsDidChange,
                object: nil,
                userInfo: ["platform": "android", "codec": newValue.rawValue]
            )
        }
    }

    // MARK: - 投屏录制设置

    /// 录制文件保存的基准目录。实际会话写入 `<基准>/StageCast Recordings/` 之下。
    /// 默认 ~/Movies；返回 nil 表示使用默认位置。
    var recordingSaveDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Keys.recordingSaveDirectory), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue?.path, forKey: Keys.recordingSaveDirectory) }
    }

    /// 录制时是否采集麦克风音频。关闭则纯画面录制，不请求权限。默认开。
    var recordingMicrophoneEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.recordingMicrophoneEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.recordingMicrophoneEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.recordingMicrophoneEnabled) }
    }

    /// 录制会话的根目录：`<保存位置或默认 Movies>/StageCast Recordings/`。
    /// 录制写入与历史扫描都以此为准，保证一致。
    func recordingsRootDirectory(fileManager: FileManager = .default) -> URL {
        let base = recordingSaveDirectory ?? fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Movies", isDirectory: true)
        return base.appendingPathComponent("StageCast Recordings", isDirectory: true)
    }

    /// 本次应用启动会话中，指定平台的音频捕获是否开启
    /// 说明：该值在应用启动时固定，偏好设置的运行时修改需要重启应用后才生效。
    func isAudioCaptureEnabledForCurrentSession(platform: DevicePlatform) -> Bool {
        switch platform {
        case .ios:
            iosAudioEnabledAtLaunch
        case .android:
            androidAudioEnabledAtLaunch
        }
    }

    // MARK: - Private Init

    private init() {
        // 设置默认值
        registerDefaults()
        iosAudioEnabledAtLaunch = defaults.bool(forKey: Keys.iosAudioEnabled)
        androidAudioEnabledAtLaunch = defaults.bool(forKey: Keys.androidAudioEnabled)
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.backgroundOpacity: 1.0,
            // 注意：register 的值会穿透 object(forKey:)，
            // 这里必须与各 getter 的「未写入时默认」语义一致，
            // 否则 getter 的默认分支永远不生效（曾导致边框/音频默认开启失效）
            Keys.showDeviceBezel: true,
            Keys.captureFrameRate: 60,
            Keys.scrcpyBitrate: 8,
            Keys.scrcpyMaxSize: 0,
            Keys.scrcpyShowTouches: false,
            Keys.showCaptureInfoStats: true,
            Keys.showMirrorStats: true,
            Keys.showDeviceControlBar: true,
            Keys.showDeviceCameraOverlay: true,
            Keys.gridDoubleClickFocusEnabled: true,
            Keys.autoMinimizeInFloatingMode: true,
            Keys.gridPageSize: 0,
            Keys.dualSplitRatio: 0.5,
            Keys.scrcpyPortRangeStart: 27183,
            Keys.scrcpyPortRangeEnd: 27199,
            Keys.scrcpyCodec: ScrcpyCodecType.h264.rawValue,
            Keys.androidControlEnabled: true,
            Keys.androidControlMode: ScrcpyInputMode.mouse.rawValue,
            Keys.androidControlHover: false,
            Keys.iosAudioEnabled: true,
            Keys.iosAudioVolume: 1.0,
            Keys.androidAudioEnabled: true,
            Keys.androidAudioVolume: 1.0,
            Keys.recordingMicrophoneEnabled: true,
        ])
    }

    // MARK: - scrcpy 配置生成

    /// 为特定设备构建 scrcpy 配置
    func buildScrcpyConfiguration(serial: String) -> ScrcpyConfiguration {
        let videoCodec: ScrcpyConfiguration.VideoCodec = switch scrcpyCodec {
        case .h264: .h264
        case .h265: .h265
        }

        return ScrcpyConfiguration(
            serial: serial,
            maxSize: scrcpyMaxSize,
            bitrate: scrcpyBitrate * 1_000_000,
            maxFps: captureFrameRate,
            showTouches: scrcpyShowTouches,
            // 复用「投屏时禁止自动锁屏」偏好：同时控制 Mac 显示器与手机屏幕常亮
            stayAwake: preventAutoLockDuringCapture,
            audioEnabled: androidAudioEnabled, // 从用户偏好读取音频开关
            audioCodec: androidAudioCodec,
            videoCodec: videoCodec,
            controlEnabled: androidControlEnabled,
            inputMode: androidControlMode,
            hoverEnabled: androidControlHover
        )
    }

}

// MARK: - NSColor Hex Extension

extension NSColor {
    /// 从十六进制字符串创建颜色
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xf) * 17, (int & 0xf) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xff, int & 0xff)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xff, int >> 8 & 0xff, int & 0xff)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }

    /// 将颜色转换为十六进制字符串
    func toHex() -> String {
        guard let rgbColor = usingColorSpace(.sRGB) else {
            return "000000"
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
