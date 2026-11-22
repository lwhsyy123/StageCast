//
//  UpdateManager.swift
//  StageCast
//
//  Created by Sun on 2026/1/6.
//
//  自动更新管理器
//  基于 Sparkle 框架，使用仓库内 appcast + GitHub Release 公网分发
//

import Foundation
import Sparkle

// MARK: - 更新管理器

/// 自动更新管理器
/// 封装 Sparkle 更新逻辑，使用公开 appcast 与 Release 下载地址
final class UpdateManager: NSObject {

    // MARK: - Singleton

    static let shared = UpdateManager()

    // MARK: - Properties

    /// Sparkle 更新控制器
    private var updaterController: SPUStandardUpdaterController?

    /// 是否已初始化
    private(set) var isInitialized = false

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// 初始化更新管理器
    /// 应在应用启动时调用
    func initialize() {
        guard !isInitialized else { return }

        // 没有配置更新源（例如重命名后的本地构建）时直接跳过，
        // 否则 Sparkle 会在启动阶段因为缺少 SUFeedURL 报错
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.isEmpty
        else {
            AppLogger.app.info("ℹ️ 未配置 SUFeedURL，跳过自动更新初始化")
            return
        }

        // 创建 Sparkle 更新控制器
        // startingUpdater: true 表示立即启动后台更新检查
        // updaterDelegate: self 用于保留扩展点（如 channel 控制）
        // userDriverDelegate: nil 使用默认 UI
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        isInitialized = true
        AppLogger.app.info("✅ UpdateManager 已初始化，更新源: \(feedURL)")
    }

    // MARK: - Public API

    /// 检查更新（用户手动触发）
    @objc func checkForUpdates() {
        guard let controller = updaterController else {
            AppLogger.app.warning("⚠️ UpdateManager 未初始化，无法检查更新")
            return
        }

        AppLogger.app.info("🔄 用户手动检查更新...")
        controller.checkForUpdates(nil)
    }

    /// 是否可以检查更新
    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    /// 获取上次更新检查时间
    var lastUpdateCheckDate: Date? {
        updaterController?.updater.lastUpdateCheckDate
    }

    /// 自动检查更新是否启用
    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? true }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 自动下载更新是否启用
    var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? false }
        set { updaterController?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// 更新检查间隔（秒）
    var updateCheckInterval: TimeInterval {
        get { updaterController?.updater.updateCheckInterval ?? 86400 }
        set { updaterController?.updater.updateCheckInterval = newValue }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateManager: SPUUpdaterDelegate {

    /// 保持默认安全策略，不允许非 HTTPS 更新
    func updater(_ updater: SPUUpdater, shouldAllowInsecureConnectionFor update: SUAppcastItem) -> Bool {
        return false
    }

    /// 允许的 channels（可用于区分 stable/beta）
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // 默认只接收稳定版
        // 如果需要 beta 通道，可以返回 ["beta"]
        return []
    }

    /// 自定义 appcast URL（可动态修改）
    func feedURLString(for updater: SPUUpdater) -> String? {
        // 返回 nil 使用 Info.plist 中的 SUFeedURL
        // 也可以在这里动态返回不同的 URL
        return nil
    }
}
