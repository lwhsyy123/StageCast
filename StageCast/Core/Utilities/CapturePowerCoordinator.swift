//
//  CapturePowerCoordinator.swift
//  StageCast
//
//  Created by Sun on 2025/1/4.
//
//  协调捕获状态与休眠阻止
//  监听设置变化与捕获状态，自动管理 SystemSleepBlocker
//

import Combine
import Foundation

// MARK: - 捕获电源协调器

/// 捕获电源协调器
/// 监听设置与捕获状态，自动管理 SystemSleepBlocker
@MainActor
final class CapturePowerCoordinator {

    // MARK: - Singleton

    static let shared = CapturePowerCoordinator()

    // MARK: - Properties

    private var cancellables = Set<AnyCancellable>()
    private let blocker = SystemSleepBlocker.shared
    private let preferences = UserPreferences.shared

    // MARK: - Init

    private init() {
        setupObservers()
    }

    // MARK: - Setup

    private func setupObservers() {
        // 监听设置变化
        NotificationCenter.default.publisher(for: .preventAutoLockSettingDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateAndUpdate()
            }
            .store(in: &cancellables)

        // 监听 AppState 状态变化（包含捕获状态变化）
        AppState.shared.stateChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.evaluateAndUpdate()
            }
            .store(in: &cancellables)
    }

    // MARK: - Core Logic

    /// 评估当前状态并更新 blocker
    func evaluateAndUpdate() {
        let settingEnabled = preferences.preventAutoLockDuringCapture
        let iosCapturing = AppState.shared.iosCapturing
        let androidCapturing = AppState.shared.androidCapturing
        let shouldBlock = settingEnabled && isAnyDeviceCapturing

        let statusIcon = shouldBlock ? "🔒" : "💤"
        let settingStatus = settingEnabled ? "✅ 开启" : "❌ 关闭"
        let iosStatus = iosCapturing ? "📱 捕获中" : "📱 未捕获"
        let androidStatus = androidCapturing ? "🤖 捕获中" : "🤖 未捕获"

        AppLogger.app.info(
            "\(statusIcon) 休眠阻止: \(shouldBlock ? "生效" : "未生效") | " +
            "防息屏设置: \(settingStatus) | iOS: \(iosStatus) | Android: \(androidStatus)"
        )

        if shouldBlock {
            blocker.enable(reason: "StageCast 正在捕获画面")
        } else {
            blocker.disable()
        }
    }

    /// 是否有任一设备正在捕获
    private var isAnyDeviceCapturing: Bool {
        AppState.shared.iosCapturing || AppState.shared.androidCapturing
    }

    // MARK: - Lifecycle

    /// 应用启动时调用
    func start() {
        evaluateAndUpdate()
        AppLogger.app.info("CapturePowerCoordinator 已启动")
    }

    /// 应用退出时调用
    func stop() {
        blocker.disable()
        AppLogger.app.info("CapturePowerCoordinator 已停止")
    }
}
