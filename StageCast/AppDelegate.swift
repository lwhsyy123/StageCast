//
//  AppDelegate.swift
//  StageCast
//
//  Created by Sun on 2025/12/22.
//
//  应用程序入口
//  配置主窗口和应用状态
//

import AppKit
import AVFoundation
import Combine

// MARK: - 应用程序委托

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - 窗口

    private var mainWindow: NSWindow?
    private var mainViewController: MainViewController?

    // MARK: - 工具栏

    private var windowToolbar: NSToolbar?
    /// 设备选择浮层控制器
    private var devicePickerPanel: DevicePickerPanelController?

    private var refreshToolbarItem: NSToolbarItem?
    private var toggleBezelToolbarItem: NSToolbarItem?
    private var preventSleepToolbarItem: NSToolbarItem?
    private var layoutModeToolbarItem: NSToolbarItem?
    private var fullScreenToolbarItem: NSToolbarItem?
    private var layoutModeSegmentedControl: NSSegmentedControl?
    private var recordingToolbarItem: NSToolbarItem?
    private var recordingOutputToolbarItem: NSToolbarItem?
    private let recordingLibrary = RecordingLibrary()
    private var recordingHistoryWindowController: NSWindowController?
    /// 已提示过的录制失败消息，避免状态发布器重复触发时反复弹 Toast。
    private var lastRecordingFailureMessage: String?
    private var isRefreshing: Bool = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 菜单项

    private var bezelMenuItem: NSMenuItem?
    private var androidControlMenuItem: NSMenuItem?
    private var windowChromeMenuItem: NSMenuItem?
private var layoutMenuItems: [NSMenuItem] = []
    private var preventSleepMenuItem: NSMenuItem?
    private let repositoryHomepageURL = URL(string: "https://github.com/lwhsyy123/StageCast")!
    private var repositoryIssuesURL: URL { repositoryHomepageURL.appendingPathComponent("issues") }

    // MARK: - 关闭状态

    private var isTerminationCloseApproved = false
    private var isTerminationCleanupInProgress = false
    private var isCaptureQuitConfirmationPresented = false
    private var quitConfirmationShortcutMonitor: Any?
    /// 当前投屏退出确认的结果回调,供快捷键监视器在弹窗展示时直接结算。
    private var pendingCaptureQuitCompletion: ((Bool) -> Void)?

    // MARK: - 应用生命周期

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.app.info("应用启动")

        // 创建主菜单（纯代码 AppKit 应用必须）
        setupMainMenu()

        // 启用 CoreMediaIO 屏幕捕获设备
        let dalEnabled = IOSScreenMirrorActivator.shared.enableDALDevices()
        AppLogger.app.info("DAL 设备启用结果: \(dalEnabled)")

        // 相机权限改为「检测到 iOS 设备接入后」再请求，启动时不再弹系统授权框

        // 创建主窗口
        setupMainWindow()

        // 监听语言变更
        setupLanguageObserver()

        // 启动捕获电源协调器（管理防休眠）
        CapturePowerCoordinator.shared.start()

        // 初始化自动更新管理器
        UpdateManager.shared.initialize()

        // 初始化应用状态
        Task {
            AppLogger.app.info("开始异步初始化应用状态...")
            await AppState.shared.initialize()
            AppLogger.app.info("应用状态初始化完成")
            await restoreWirelessSessions()
        }
    }

    /// 启动后自动恢复上次的无线投屏会话（任务：无线会话自动恢复）
    @MainActor
    private func restoreWirelessSessions() async {
        let endpoints = UserPreferences.shared.lastWirelessEndpoints
        guard !endpoints.isEmpty else { return }
        AppLogger.device.info("[AutoRestore] 尝试恢复无线会话: \(endpoints)")

        let provider = AppState.shared.androidDeviceProvider

        // 先 adb connect 各端点（部分设备重启后 adb 会话已断）；mDNS 端点依赖发现，无需 connect
        for endpoint in endpoints where endpoint.contains(":") {
            let parts = endpoint.split(separator: ":").map(String.init)
            _ = try? await provider.connectWireless(host: parts.first ?? endpoint,
                                                    port: parts.count > 1 ? Int(parts[1]) ?? 5555 : 5555)
        }
        await provider.refreshDevices()

        // 等设备列表稳定后再尝试投屏（匹配 host，容忍端口漂移）
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await provider.refreshDevices()

        for endpoint in endpoints {
            // host:port 端点按 host 匹配（容忍端口漂移）；mDNS serial 端点按 GUID 段前缀匹配
            // （实例后缀每次广播会变，如 adb-b779a8d6-F1L0Xg → 匹配 adb-b779a8d6）
            let isMDNS = !endpoint.contains(":") && endpoint.hasPrefix("adb-")
            let mdnsGUIDPrefix = isMDNS
                ? endpoint.split(separator: "-").prefix(2).joined(separator: "-")
                : nil
            guard let device = provider.devices.first(where: {
                guard $0.connectionType == .wifi && $0.state == .device else { return false }
                if isMDNS {
                    return $0.serial == endpoint || $0.serial.hasPrefix(mdnsGUIDPrefix ?? "###")
                }
                let host = endpoint.split(separator: ":").first.map(String.init) ?? endpoint
                return $0.serial == endpoint || $0.serial.hasPrefix(host + ":") || $0.serial.hasSuffix(host)
            }) else {
                AppLogger.device.info("[AutoRestore] \(endpoint) 未发现在线无线设备，跳过")
                continue
            }
            let capturing = AppState.shared.isAndroidCapturing(serial: device.serial)
            guard !capturing else { continue }
            do {
                try await AppState.shared.startAndroidCapture(device: device)
                AppLogger.device.info("[AutoRestore] 已自动恢复投屏: \(device.serial)")
            } catch {
                AppLogger.device.warning("[AutoRestore] \(device.serial) 恢复失败: \(error.localizedDescription)")
            }
        }
    }

    private func setupLanguageObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageChange),
            name: LocalizationManager.languageDidChangeNotification,
            object: nil
        )

        // 监听 bezel 可见性变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBezelVisibilityChange),
            name: .deviceBezelVisibilityDidChange,
            object: nil
        )

        // 监听防休眠设置变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreventSleepSettingChange),
            name: .preventAutoLockSettingDidChange,
            object: nil
        )

        // 监听布局模式变化（含偏好设置窗口触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutModePreferenceChange),
            name: .layoutModeDidChange,
            object: nil
        )
    }

    @objc private func handleBezelVisibilityChange() {
        // 更新工具栏按钮图标
        if let item = toggleBezelToolbarItem {
            updateBezelToolbarItemImage(item)
        }
        // 更新菜单项状态
        bezelMenuItem?.state = UserPreferences.shared.showDeviceBezel ? .on : .off
    }

    @objc private func handlePreventSleepSettingChange() {
        // 更新工具栏按钮图标
        if let item = preventSleepToolbarItem {
            updatePreventSleepToolbarItemImage(item)
        }
        // 更新菜单项状态
        preventSleepMenuItem?.state = UserPreferences.shared.preventAutoLockDuringCapture ? .on : .off
    }

    @objc private func handleLayoutModePreferenceChange() {
        updateLayoutModeToolbarState()
    }

    @MainActor
    @objc private func handleLanguageChange() {
        // 重建主菜单
        setupMainMenu()

        // 更新主窗口标题
        mainWindow?.title = L10n.window.main

        // 重建工具栏以更新按钮文字
        if let window = mainWindow {
            rebuildWindowToolbar(for: window)
        }

        // 通知主视图控制器更新本地化文本
        mainViewController?.updateLocalizedTexts()
    }

    @MainActor
    private func rebuildWindowToolbar(for window: NSWindow) {
        // 移除旧工具栏
        window.toolbar = nil
        refreshToolbarItem = nil
        toggleBezelToolbarItem = nil
        preventSleepToolbarItem = nil
        layoutModeToolbarItem = nil
        layoutModeSegmentedControl = nil
        recordingToolbarItem = nil
        recordingOutputToolbarItem = nil
        recordingHistoryWindowController?.close()
        recordingHistoryWindowController = nil

        // 创建新工具栏
        setupWindowToolbar(for: window)
        updateRecordingUI()
    }


    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.app.info("应用即将退出")

        // 停止捕获电源协调器（释放防休眠 assertion）
        CapturePowerCoordinator.shared.stop()

        // 异步资源清理已在 applicationShouldTerminate 的 terminateLater 阶段完成。
        // 此回调不能等待 Task，不能再把录制收尾放到这里。
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainViewController != nil else {
            return .terminateNow
        }

        if isTerminationCloseApproved {
            return .terminateNow
        }

        if isTerminationCleanupInProgress {
            return .terminateLater
        }

        // 二次退出请求跳过确认，但仍进入 terminateLater 清理流程。
        // 视频 writer 必须完成 finishWriting，不能直接 terminateNow。
        if isCaptureQuitConfirmationPresented {
            confirmPendingCaptureQuit()
            return .terminateLater
        }

        if hasActiveCaptureSession {
            presentCaptureQuitConfirmation { [weak self] confirmed in
                self?.replyCaptureQuitToTermination(confirmed)
            }
            return .terminateLater
        }

        beginTerminationCleanup()
        return .terminateLater
    }

    private var hasActiveCaptureSession: Bool {
        MainActor.assumeIsolated {
            AppState.shared.iosCapturing || AppState.shared.androidCapturing
        }
    }

    private var activeCaptureSessionCount: Int {
        MainActor.assumeIsolated {
            var count = 0
            if AppState.shared.iosCapturing {
                count += 1
            }
            if AppState.shared.androidCapturing {
                count += 1
            }
            return count
        }
    }

    /// 将投屏退出确认结果结算到 AppKit 终止流程:记录审批结果并回复。
    private func replyCaptureQuitToTermination(_ confirmed: Bool) {
        guard confirmed else {
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        beginTerminationCleanup()
    }

    /// AppKit 不会等待 applicationWillTerminate 中启动的异步 Task。
    /// 因此必须在 terminateLater 阶段完成录制、Helper 和设备清理，再允许进程退出。
    private func beginTerminationCleanup() {
        guard !isTerminationCleanupInProgress else { return }
        isTerminationCleanupInProgress = true

        Task { @MainActor [weak self] in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            await AppState.shared.cleanup()
            self.isTerminationCleanupInProgress = false
            self.isTerminationCloseApproved = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// 展示"投屏中退出"二次确认。必须在主窗口仍可见时调用,否则 sheet 会贴到已关闭的窗口上。
    /// - Parameter completion: 用户选择结果,true 表示确认退出。
    private func presentCaptureQuitConfirmation(completion: @escaping (Bool) -> Void) {
        guard !isCaptureQuitConfirmationPresented else {
            completion(false)
            return
        }
        isCaptureQuitConfirmationPresented = true

        let alert = NSAlert()
        alert.messageText = L10n.alert.quitConfirmMessage
        let sessionCount = max(activeCaptureSessionCount, 1)
        alert.informativeText = [
            L10n.alert.quitConfirmImpactMessage(sessionCount),
            L10n.alert.quitConfirmShortcutHint,
        ].joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: L10n.alert.quit)
        alert.addButton(withTitle: L10n.alert.cancel)

        startQuitConfirmationShortcutMonitor()

        let complete: (Bool) -> Void = { [weak self] confirmed in
            guard let self else { return }
            self.stopQuitConfirmationShortcutMonitor()
            self.isCaptureQuitConfirmationPresented = false
            self.pendingCaptureQuitCompletion = nil
            completion(confirmed)
        }
        pendingCaptureQuitCompletion = complete

        if let mainWindow, mainWindow.isVisible {
            alert.beginSheetModal(for: mainWindow) { response in
                complete(response == .alertFirstButtonReturn)
            }
        } else {
            complete(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func startQuitConfirmationShortcutMonitor() {
        guard quitConfirmationShortcutMonitor == nil else { return }
        quitConfirmationShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.isCaptureQuitConfirmationPresented else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased()
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command), key == "q" else { return event }

            self.confirmPendingCaptureQuit()
            return nil
        }
    }

    /// 跳过当前投屏退出确认，但仍通过原 terminateLater 回调完成异步资源清理。
    private func confirmPendingCaptureQuit() {
        if let mainWindow, let sheet = mainWindow.attachedSheet {
            mainWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        } else {
            // 无 sheet（极少数窗口不可见的兜底路径）时，直接以“确认”结算当前退出流程。
            pendingCaptureQuitCompletion?(true)
        }
    }

    private func stopQuitConfirmationShortcutMonitor() {
        guard let quitConfirmationShortcutMonitor else { return }
        NSEvent.removeMonitor(quitConfirmationShortcutMonitor)
        self.quitConfirmationShortcutMonitor = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 主菜单设置

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            withTitle: L10n.menu.about,
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())

        // 检查更新
        let checkUpdatesItem = appMenu.addItem(
            withTitle: L10n.menu.checkForUpdates,
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdatesItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: L10n.menu.preferences,
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(NSMenuItem.separator())

        let servicesMenu = NSMenu()
        let servicesItem = appMenu.addItem(
            withTitle: L10n.menu.services,
            action: nil,
            keyEquivalent: ""
        )
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: L10n.menu.hide,
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthersItem = appMenu.addItem(
            withTitle: L10n.menu.hideOthers,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: L10n.menu.showAll,
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: L10n.menu.quit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        mainMenu.addItem(appMenuItem)

        // 捕获菜单（设备 + 显示）
        let captureMenu = NSMenu(title: L10n.menu.capture)
        let captureMenuItem = NSMenuItem()
        captureMenuItem.submenu = captureMenu

        let refreshItem = captureMenu.addItem(
            withTitle: L10n.menu.refreshDevices,
            action: #selector(refreshDevices(_:)),
            keyEquivalent: "r"
        )
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)

        // 无线连接 Android 设备
        let wirelessItem = captureMenu.addItem(
            withTitle: L10n.android.wireless.connect,
            action: #selector(connectAndroidWireless(_:)),
            keyEquivalent: "W"
        )
        wirelessItem.keyEquivalentModifierMask = [.command, .shift]
        wirelessItem.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)

        // 设备选择浮层（多设备连接）
        let pickerItem = captureMenu.addItem(
            withTitle: L10n.devicePicker.title,
            action: #selector(toggleDevicePicker(_:)),
            keyEquivalent: "k"
        )
        pickerItem.image = NSImage(
            systemSymbolName: "rectangle.stack.badge.plus",
            accessibilityDescription: L10n.devicePicker.title
        )

        captureMenu.addItem(NSMenuItem.separator())

        // 布局模式子菜单（fit 模式下工具栏被隐藏，这是唯一的布局切换入口）
        let layoutMenu = NSMenu(title: L10n.menu.layoutMode)
        let layoutMenuItem = NSMenuItem()
        layoutMenuItem.title = L10n.menu.layoutMode
        layoutMenuItem.submenu = layoutMenu
        layoutMenuItem.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        let layoutSelectors: [(PreviewLayoutMode, Selector)] = [
            (.auto, #selector(selectAutoLayoutMode(_:))),
            (.grid, #selector(selectGridLayoutMode(_:))),
            (.floating, #selector(selectFloatingLayoutMode(_:)))
        ]
        layoutMenuItems.removeAll()
        for (mode, selector) in layoutSelectors {
            let item = layoutMenu.addItem(
                withTitle: mode.displayName,
                action: selector,
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: mode.iconName, accessibilityDescription: nil)
            item.state = UserPreferences.shared.layoutMode == mode ? .on : .off
            item.representedObject = mode.rawValue
            layoutMenuItems.append(item)
        }
        layoutMenu.addItem(NSMenuItem.separator())
        let swapLayoutItem = layoutMenu.addItem(
            withTitle: L10n.toolbar.swapPanels,
            action: #selector(swapPanels(_:)),
            keyEquivalent: ""
        )
        swapLayoutItem.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        captureMenu.addItem(layoutMenuItem)

        captureMenu.addItem(NSMenuItem.separator())

        // 导出日志
        let exportItem = captureMenu.addItem(
            withTitle: L10n.menu.exportLogs,
            action: #selector(exportLogs(_:)),
            keyEquivalent: "E"
        )
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)

        captureMenu.addItem(NSMenuItem.separator())

        // 显示/隐藏设备边框
        let bezelItem = captureMenu.addItem(
            withTitle: L10n.menu.toggleDeviceBezel,
            action: #selector(toggleDeviceBezel(_:)),
            keyEquivalent: "B"
        )
        bezelItem.keyEquivalentModifierMask = [.command, .shift]
        bezelItem.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        bezelItem.state = UserPreferences.shared.showDeviceBezel ? .on : .off
        bezelMenuItem = bezelItem

        // 禁止息屏
        let sleepItem = captureMenu.addItem(
            withTitle: L10n.menu.togglePreventSleep,
            action: #selector(togglePreventSleep(_:)),
            keyEquivalent: "S"
        )
        sleepItem.keyEquivalentModifierMask = [.command, .shift]
        sleepItem.image = NSImage(systemSymbolName: "lock.display", accessibilityDescription: nil)
        sleepItem.state = UserPreferences.shared.preventAutoLockDuringCapture ? .on : .off
        preventSleepMenuItem = sleepItem

        // 鼠标/键盘控制手机
        let controlItem = captureMenu.addItem(
            withTitle: L10n.menu.androidControl,
            action: #selector(toggleAndroidControl(_:)),
            keyEquivalent: "K"
        )
        controlItem.keyEquivalentModifierMask = [.command, .shift]
        controlItem.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
        controlItem.state = UserPreferences.shared.androidControlEnabled ? .on : .off
        androidControlMenuItem = controlItem

        captureMenu.addItem(NSMenuItem.separator())

        let chromeItem = captureMenu.addItem(
            withTitle: L10n.menu.toggleWindowChrome,
            action: #selector(toggleWindowChrome(_:)),
            keyEquivalent: "H"
        )
        chromeItem.keyEquivalentModifierMask = [.command, .shift]
        chromeItem.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        chromeItem.state = UserPreferences.shared.hideWindowChrome ? .on : .off
        windowChromeMenuItem = chromeItem

        captureMenu.addItem(NSMenuItem.separator())

        // 颜色补偿
        let colorCompItem = captureMenu.addItem(
            withTitle: L10n.menu.colorCompensation,
            action: #selector(toggleColorCompensationPanel(_:)),
            keyEquivalent: "C"
        )
        colorCompItem.keyEquivalentModifierMask = [.command, .shift]
        colorCompItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)

        captureMenu.addItem(NSMenuItem.separator())

        let closeItem = captureMenu.addItem(
            withTitle: L10n.menu.close,
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: ""
        )
        closeItem.target = nil

        mainMenu.addItem(captureMenuItem)

        // 编辑菜单
        // 之前「编辑」子菜单挂在 Markdown 菜单里，随 Markdown 编辑器一并移除后
        // 就再也没有编辑菜单了 —— 无线投屏的 IP 输入框、偏好设置里的文本框
        // 会因此失去 Cmd+C/V/X/A/Z 快捷键。这里补一个标准编辑菜单，
        // 全部 selector 走 responder chain，由当前第一响应者（NSTextField 等）实现。
        let editMenu = NSMenu(title: L10n.menu.edit)
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        editMenu.addItem(
            withTitle: L10n.menu.undo,
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: L10n.menu.redo,
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: L10n.menu.cut,
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: L10n.menu.copy,
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: L10n.menu.paste,
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: L10n.menu.selectAll,
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        mainMenu.addItem(editMenuItem)

        // 窗口菜单
        let windowMenu = NSMenu(title: L10n.menu.window)
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(
            withTitle: L10n.menu.minimize,
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: L10n.menu.zoom,
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        // 全屏入口：fit 模式会隐藏绿色按钮与工具栏，没有菜单项就完全进不去全屏
        windowMenu.addItem(
            withTitle: L10n.menu.toggleFullScreen,
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        ).keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            withTitle: L10n.menu.bringAllToFront,
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // 帮助菜单
        let helpMenu = NSMenu(title: L10n.menu.help)
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        let githubHomeItem = helpMenu.addItem(
            withTitle: L10n.menu.githubHomepage,
            action: #selector(openGitHubHomepage(_:)),
            keyEquivalent: ""
        )
        githubHomeItem.target = self
        githubHomeItem.image = symbolImage("house")

        let reportIssueItem = helpMenu.addItem(
            withTitle: L10n.menu.reportIssue,
            action: #selector(reportIssue(_:)),
            keyEquivalent: ""
        )
        reportIssueItem.target = self
        reportIssueItem.image = symbolImage("exclamationmark.bubble")
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 窗口设置

    @MainActor
    private func setupMainWindow() {
        // 创建主视图控制器
        mainViewController = MainViewController()

        // 创建窗口
        let window = TransparentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = L10n.window.main
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 800, height: 600)
        window.contentViewController = mainViewController
        window.center()
        window.setFrameAutosaveName("MainWindow")

        // 设置窗口工具栏
        setupWindowToolbar(for: window)
        setupRecordingObservation()

        // 设置窗口代理
        window.delegate = self

        // 显示窗口
        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // 激活应用（确保窗口显示在最前面）
        NSApp.activate(ignoringOtherApps: true)

        AppLogger.app.info("主窗口已创建")
    }

    private func setupWindowToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false

        window.toolbar = toolbar
        windowToolbar = toolbar
    }

    @MainActor
    private func setupRecordingObservation() {
        AppState.shared.recordingService.stateChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateRecordingUI()
                self?.surfaceRecordingFailureIfNeeded()
            }
            .store(in: &cancellables)
    }

    /// 被动停录（磁盘不足/写失败等）时经状态发布器弹出错误提示，仅在新消息出现时提示一次。
    @MainActor
    private func surfaceRecordingFailureIfNeeded() {
        guard case let .failed(message) = AppState.shared.recordingService.state else {
            lastRecordingFailureMessage = nil
            return
        }
        guard message != lastRecordingFailureMessage else { return }
        lastRecordingFailureMessage = message
        ToastView.error(message, in: mainWindow)
    }
}

// MARK: - 窗口代理

extension AppDelegate: NSWindowDelegate {
    // 注：窗口比例锁定改用 NSWindow.contentAspectRatio（系统原生能力），
    // 不再手写 windowWillResize。手写版本需自行扣除标题栏高度，
    // 在 fullSizeContentView 下会误减 32pt，导致窗口比视频窄、上下出现黑边。

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == recordingHistoryWindowController?.window {
            recordingHistoryWindowController = nil
            return true
        }

        guard sender == mainWindow else {
            return true
        }

        if isTerminationCloseApproved {
            return true
        }

        // 投屏进行中时,在窗口仍可见时先弹退出确认,
        // 避免窗口关闭后确认框贴到已消失的窗口上并循环弹出(见 issue #19)。
        if hasActiveCaptureSession {
            presentCaptureQuitConfirmation { [weak self] confirmed in
                guard let self, confirmed else { return } // 取消:窗口保持打开
                // 确认:投屏中关闭窗口等同退出应用。窗口仍开着时直接终止,
                // 保证 applicationShouldTerminate 读到的审批状态未被 windowWillClose 重置。
                self.isTerminationCloseApproved = true
                NSApp.terminate(nil)
            }
            return false
        }

        return true
    }

    func windowWillClose(_ notification: Notification) {
        AppLogger.app.info("主窗口即将关闭")
        isTerminationCloseApproved = false
    }

    func windowDidResize(_ notification: Notification) {
        // 通知渲染器更新尺寸
        mainViewController?.handleWindowResize()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        // 在全屏动画开始前更新状态，避免动画过程中布局跳动
        mainViewController?.handleFullScreenChange(isFullScreen: true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        // 在退出全屏动画开始前更新状态，避免动画过程中布局跳动
        mainViewController?.handleFullScreenChange(isFullScreen: false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // 退出全屏动画完成后，确保 toolbar 正确恢复显示
        mainViewController?.ensureToolbarVisible()
    }
}

// MARK: - 菜单操作

extension AppDelegate {
    /// 切换设备选择浮层
    @MainActor @objc func toggleDevicePicker(_ sender: Any?) {
        guard let window = mainWindow else { return }
        if devicePickerPanel == nil {
            let panel = DevicePickerPanelController()
            // 无线手动连接 / 配对 / 诊断入口在选择器面板里，创建后立即接线
            mainViewController?.attachWirelessPanel(panel.wirelessSection)
            devicePickerPanel = panel
        }
        devicePickerPanel?.toggle(relativeTo: window)
    }

    @IBAction func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        UpdateManager.shared.checkForUpdates()
    }

    @IBAction func openGitHubHomepage(_ sender: Any?) {
        openExternalLink(repositoryHomepageURL)
    }

    @IBAction func reportIssue(_ sender: Any?) {
        openExternalLink(repositoryIssuesURL)
    }

    @IBAction func toggleColorCompensationPanel(_ sender: Any?) {
        ColorCompensationPanel.shared.togglePanel()
    }

    @IBAction func refreshDevices(_ sender: Any?) {
        guard !isRefreshing else { return }

        startRefreshLoading()

        Task {
            await AppState.shared.refreshDevices()
            await MainActor.run {
                stopRefreshLoading()
                showRefreshToast()
            }
        }
    }

    // MARK: - 无线连接

    /// 无线连接入口已内嵌到 Android 等待连接页，菜单只负责把用户引导过去
    @IBAction func connectAndroidWireless(_ sender: Any?) {
        ToastView.info(L10n.android.wireless.inlineHint, in: mainWindow as NSWindow?)
    }

    /// 导出日志
    @IBAction func exportLogs(_ sender: Any?) {
        guard let window = mainWindow else { return }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "StageCast_logs_\(formattedTimestamp()).log"
        savePanel.allowedContentTypes = [.plainText, .log]
        savePanel.canCreateDirectories = true

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            self?.collectAndExportLogs(to: url)
        }
    }

    private func openExternalLink(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            NSSound.beep()
            AppLogger.app.error("打开外部链接失败: \(url.absoluteString)")
            return
        }
    }

    /// 格式化时间戳用于文件名
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    /// 收集并导出日志
    private func collectAndExportLogs(to url: URL) {
        Task {
            do {
                let logs = try await collectSystemLogs()
                try logs.write(to: url, atomically: true, encoding: .utf8)

                await MainActor.run {
                    // 显示成功提示并打开 Finder 选中文件
                    ToastView.success(L10n.toast.exportLogsSuccess, in: mainWindow)
                    NSWorkspace.shared.selectFile(
                        url.path,
                        inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                    )
                }
            } catch {
                await MainActor.run {
                    ToastView.error(L10n.toast.exportLogsFailed(error.localizedDescription), in: mainWindow)
                }
            }
        }
    }

    /// 从系统日志收集应用日志
    private func collectSystemLogs() async throws -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.haptictide.StageCast"
        var allLogs = ""

        // 添加头部信息
        let header = """
        ========================================
        StageCast Log Export
        ========================================
        Export Time: \(ISO8601DateFormatter().string(from: Date()))
        Bundle ID: \(bundleId)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        ========================================

        """
        allLogs += header

        // 收集应用日志（info 级别以上，使用 --info 标志）
        let appLogs = try await runLogCommand([
            "show",
            "--predicate", "subsystem == '\(bundleId)'",
            "--last", "1h",
            "--style", "compact",
            "--info", // 包含 info 级别日志
        ])
        allLogs += "\n--- Application Logs ---\n"
        allLogs += appLogs.isEmpty ? "(No logs found)\n" : appLogs

        // 添加内存中的日志缓存（如果有）
        let cachedLogs = LogBuffer.shared.getLogs()
        if !cachedLogs.isEmpty {
            allLogs += "\n--- In-Memory Log Buffer ---\n"
            allLogs += cachedLogs.joined(separator: "\n")
            allLogs += "\n"
        }

        return allLogs
    }

    /// 执行 log 命令并返回输出
    private func runLogCommand(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @IBAction func toggleDeviceBezel(_ sender: Any?) {
        UserPreferences.shared.showDeviceBezel.toggle()
        // 更新工具栏按钮图标
        if let item = toggleBezelToolbarItem {
            updateBezelToolbarItemImage(item)
        }
    }

    /// 工具栏全屏按钮：隐藏标题栏时红绿灯与工具栏都会收起，这个入口保证任何布局模式下都能进全屏
    @IBAction func toggleFullScreenFromToolbar(_ sender: Any?) {
        mainWindow?.toggleFullScreen(sender)
    }

    @IBAction func toggleWindowChrome(_ sender: Any?) {
        UserPreferences.shared.hideWindowChrome.toggle()
        windowChromeMenuItem?.state = UserPreferences.shared.hideWindowChrome ? .on : .off
    }

    @IBAction func toggleAndroidControl(_ sender: Any?) {
        UserPreferences.shared.androidControlEnabled.toggle()
        androidControlMenuItem?.state = UserPreferences.shared.androidControlEnabled ? .on : .off
        let message = UserPreferences.shared.androidControlEnabled
            ? L10n.overlayUI.androidControlOn
            : L10n.overlayUI.androidControlOff
        ToastView.info(message, in: nil as NSView?)

        // 立即刷新面板的输入开关，无需等待下一次状态变化
        AppState.shared.stateChangedPublisher.send()
    }

    @IBAction func togglePreventSleep(_ sender: Any?) {
        UserPreferences.shared.preventAutoLockDuringCapture.toggle()
        // 更新工具栏按钮图标
        if let item = preventSleepToolbarItem {
            updatePreventSleepToolbarItemImage(item)
        }
    }

    @objc private func selectAutoLayoutMode(_ sender: Any?) {
        setLayoutMode(.auto)
    }

    @objc private func selectGridLayoutMode(_ sender: Any?) {
        setLayoutMode(.grid)
    }

    @objc private func selectFloatingLayoutMode(_ sender: Any?) {
        setLayoutMode(.floating)
    }

    @objc private func layoutModeSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:  // 自动排列
            setLayoutMode(.auto)
        case 1:  // 网格
            setLayoutMode(.grid)
        case 2:  // 独立浮窗
            setLayoutMode(.floating)
        case 3:  // 交换位置（动作，不是模式）
            swapPanels(sender)
            updateLayoutModeToolbarState()
        default:
            break
        }
    }

    private func setLayoutMode(_ newMode: PreviewLayoutMode) {
        UserPreferences.shared.layoutMode = newMode
        updateLayoutModeToolbarState()
        refreshLayoutMenuStates()
    }

    /// 同步「捕获 → 布局」子菜单的勾选状态
    private func refreshLayoutMenuStates() {
        for item in layoutMenuItems {
            if let raw = item.representedObject as? String,
               let mode = PreviewLayoutMode(rawValue: raw) {
                item.state = mode == UserPreferences.shared.layoutMode ? .on : .off
            }
        }
    }

    private func startRefreshLoading() {
        isRefreshing = true
        refreshToolbarItem?.isEnabled = false
    }

    private func stopRefreshLoading() {
        isRefreshing = false
        refreshToolbarItem?.isEnabled = true
    }

    @MainActor
    private func showRefreshToast() {
        ToastView.success(L10n.toolbar.refreshComplete, in: mainWindow)
    }

    // MARK: - 录制操作

    @IBAction func toggleRecording(_ sender: Any?) {
        let recordingService = AppState.shared.recordingService

        if recordingService.state.isRecording {
            Task {
                let directory = await recordingService.stopRecording()
                await MainActor.run {
                    updateRecordingUI()
                }
                if let directory {
                    await presentRecordingSavedToast(directory: directory)
                }
            }
            return
        }

        Task {
            do {
                try await recordingService.startRecordingForAllDevices()
                await MainActor.run {
                    updateRecordingUI()
                    presentRecordingStartToast(audioStatus: recordingService.audioStatus)
                }
            } catch {
                // 失败提示统一由 setupRecordingObservation 监听 .failed 状态弹出，避免重复。
                await MainActor.run {
                    updateRecordingUI()
                }
            }
        }
    }

    /// 停录成功提示：能构建出会话则带「回放」动作按钮，点击直接打开回放；否则退回普通提示。
    /// 不自动弹窗，避免投屏时打断画面或暴露给观众。
    @MainActor
    private func presentRecordingSavedToast(directory: URL) async {
        guard let session = await recordingLibrary.makeSession(from: directory) else {
            ToastView.success(L10n.recording.saved, in: mainWindow)
            return
        }
        ToastView.success(
            L10n.recording.saved,
            actionTitle: L10n.recording.replay,
            in: mainWindow
        ) { [weak self] in
            self?.mainViewController?.showRecordingReplay(session: session)
        }
    }

    /// 按音频轨道状态弹出录制开始提示：有音频用 success，缺音频按成因用 warning 分别告知。
    @MainActor
    private func presentRecordingStartToast(audioStatus: RecordingAudioStatus) {
        switch audioStatus {
        case .enabled, .disabled:
            // 正常录音，或用户主动关闭麦克风：均属预期，用 success。
            ToastView.success(L10n.recording.started, in: mainWindow)
        case .noDevice:
            ToastView.warning(L10n.recording.startedNoMicrophoneDevice, in: mainWindow)
        case .permissionDenied:
            ToastView.warning(L10n.recording.startedMicrophoneDenied, in: mainWindow)
        case .unavailable:
            ToastView.warning(L10n.recording.startedMicrophoneUnavailable, in: mainWindow)
        }
    }

    @objc private func showRecordingHistory(_ sender: Any?) {
        let historyView = RecordingHistoryPopoverView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 400)
        )
        historyView.configure(sessions: [])

        let contentViewController = NSViewController()
        contentViewController.view = historyView

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: historyView.frame.size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.recording.historyTitle
        window.contentViewController = contentViewController
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)

        let windowController = NSWindowController(window: window)

        historyView.onRevealDirectory = { [weak self, weak window] session in
            self?.dismissRecordingHistoryWindow(window)
            NSWorkspace.shared.activateFileViewerSelecting([session.directory])
        }

        historyView.onReplay = { [weak self, weak window] session in
            self?.dismissRecordingHistoryWindow(window)
            self?.mainViewController?.showRecordingReplay(session: session)
        }

        historyView.onDeleteSession = { [weak self, weak historyView] session in
            self?.confirmAndDeleteRecording(session, in: historyView)
        }

        dismissRecordingHistoryWindow(recordingHistoryWindowController?.window)
        recordingHistoryWindowController = windowController

        positionRecordingHistoryWindow(window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        reloadRecordingHistory(into: historyView)
    }

    /// 扫描并刷新历史列表，同时更新总占用摘要。
    private func reloadRecordingHistory(into historyView: RecordingHistoryPopoverView) {
        Task { @MainActor [weak self, weak historyView] in
            guard let self, let historyView else { return }
            do {
                let sessions = try await recordingLibrary.scanSessions()
                historyView.configure(sessions: sessions, summaryText: historySummaryText(for: sessions))
            } catch {
                AppLogger.capture.error("读取录制历史失败: \(error.localizedDescription)")
                historyView.configure(sessions: [])
            }
        }
    }

    private func historySummaryText(for sessions: [RecordingSession]) -> String {
        guard !sessions.isEmpty else { return "" }
        let bytes = recordingLibrary.totalSize(of: sessions)
        let sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return L10n.recording.historySummary(sessions.count, sizeText)
    }

    /// 弹确认框，确认后将会话移入废纸篓并刷新列表。
    private func confirmAndDeleteRecording(
        _ session: RecordingSession,
        in historyView: RecordingHistoryPopoverView?
    ) {
        guard let historyView, let window = recordingHistoryWindowController?.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.recording.deleteConfirmTitle
        alert.informativeText = L10n.recording.deleteConfirmMessage(session.directory.lastPathComponent)
        alert.addButton(withTitle: L10n.recording.deleteConfirmButton)
        alert.addButton(withTitle: L10n.recording.cancel)

        alert.beginSheetModal(for: window) { [weak self, weak historyView] response in
            guard response == .alertFirstButtonReturn, let self, let historyView else { return }
            do {
                try self.recordingLibrary.deleteSession(session)
                self.reloadRecordingHistory(into: historyView)
            } catch {
                AppLogger.capture.error("删除录制失败: \(error.localizedDescription)")
                // beginSheetModal 的 completion 在主线程回调，断言主线程隔离以调用 @MainActor 的 Toast。
                MainActor.assumeIsolated {
                    ToastView.error(L10n.recording.deleteFailed, in: window)
                }
            }
        }
    }

    private func positionRecordingHistoryWindow(_ window: NSWindow) {
        guard let mainWindow else {
            window.center()
            return
        }

        let mainFrame = mainWindow.frame
        let windowSize = window.frame.size
        let origin = NSPoint(
            x: mainFrame.midX - windowSize.width / 2,
            y: mainFrame.midY - windowSize.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func dismissRecordingHistoryWindow(_ window: NSWindow?) {
        guard let window else {
            recordingHistoryWindowController = nil
            return
        }

        window.close()
        recordingHistoryWindowController = nil
    }

    // MARK: - 面板交换操作

    @IBAction func swapPanels(_ sender: Any?) {
        mainViewController?.swapPanels()
    }

    @MainActor
    private func updateRecordingUI() {
        let service = AppState.shared.recordingService
        let isRecording = service.state.isRecording

        if let item = recordingToolbarItem {
            item.isEnabled = !service.state.isStopping
            updateRecordingToolbarItemImage(item)
        }

        updateRecordingOutputToolbarPresence(true)

        if let item = recordingOutputToolbarItem {
            updateRecordingHistoryToolbarItemImage(item)
        }

        mainViewController?.setRecordingIndicatorVisible(isRecording, elapsedSeconds: service.elapsedSeconds)
    }

    @MainActor
    private func updateRecordingOutputToolbarPresence(_ shouldShow: Bool) {
        guard let toolbar = windowToolbar else { return }

        let items = toolbar.items
        let outputIndex = items.firstIndex { $0.itemIdentifier == ToolbarItemIdentifier.recordingOutput }

        if shouldShow {
            guard outputIndex == nil else { return }

            let recordingIndex = items.firstIndex { $0.itemIdentifier == ToolbarItemIdentifier.recording } ?? 0
            toolbar.insertItem(withItemIdentifier: ToolbarItemIdentifier.recordingOutput, at: recordingIndex)
        } else if let outputIndex, recordingOutputToolbarItem == nil {
            toolbar.removeItem(at: outputIndex)
            recordingOutputToolbarItem = nil
        }
    }

    @MainActor
    private func updateRecordingToolbarItemImage(_ item: NSToolbarItem) {
        let isRecording = AppState.shared.recordingService.state.isRecording
        let symbolName = isRecording ? "stop.circle.fill" : "record.circle"
        item.label = isRecording ? L10n.recording.stop : L10n.recording.record
        item.paletteLabel = L10n.recording.record
        item.toolTip = isRecording ? L10n.recording.stop : L10n.recording.record
        item.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: item.toolTip
        )
    }

    @MainActor
    private func updateRecordingHistoryToolbarItemImage(_ item: NSToolbarItem) {
        let image = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: L10n.recording.openHistory
        )

        item.label = L10n.recording.openHistory
        item.paletteLabel = L10n.recording.openHistory
        item.toolTip = L10n.recording.openHistory
        item.image = image
    }

    /// 供主控制器在设备数量变化时刷新布局段可用状态
    func refreshLayoutModeToolbarState() {
        updateLayoutModeToolbarState()
    }

    private func updateLayoutModeToolbarState() {
        guard let segmentedControl = layoutModeSegmentedControl else { return }
        let currentMode = UserPreferences.shared.layoutMode
        // 段索引: 0=自动排列, 1=网格, 2=独立浮窗, 3=交换位置
        switch currentMode {
        case .auto:
            segmentedControl.selectedSegment = 0
        case .grid:
            segmentedControl.selectedSegment = 1
        case .floating:
            segmentedControl.selectedSegment = 2
        }
        // 交换位置只在两台及以上设备投屏时有意义（UI 始终在主线程，直接取主线程隔离状态）
        let deviceCount = MainActor.assumeIsolated { AppState.shared.capturingPhysicalDeviceCount }
        segmentedControl.setEnabled(deviceCount >= 2, forSegment: 3)
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

// MARK: - 工具栏代理

extension AppDelegate: NSToolbarDelegate {
    private enum ToolbarItemIdentifier {
        static let recording = NSToolbarItem.Identifier("recording")
        static let recordingOutput = NSToolbarItem.Identifier("recordingOutput")
        static let layoutMode = NSToolbarItem.Identifier("layoutMode")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let toggleBezel = NSToolbarItem.Identifier("toggleBezel")
        static let preventSleep = NSToolbarItem.Identifier("preventSleep")
        static let preferences = NSToolbarItem.Identifier("preferences")
        static let devicePicker = NSToolbarItem.Identifier("devicePicker")
        static let fullScreen = NSToolbarItem.Identifier("fullScreen")
        static let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 「连接设备」是最高频入口，固定放最左；右侧是录制与设置，
        // 中间用 flexibleSpace 顶开，避免窗口变宽后所有按钮挤在左边。
        [
            ToolbarItemIdentifier.devicePicker,
            .space,
            ToolbarItemIdentifier.layoutMode,
            .space,
            ToolbarItemIdentifier.refresh,
            .flexibleSpace,
            ToolbarItemIdentifier.recording,
            ToolbarItemIdentifier.recordingOutput,
            .space,
            ToolbarItemIdentifier.fullScreen,
            ToolbarItemIdentifier.preferences,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemIdentifier.devicePicker,
            ToolbarItemIdentifier.recording,
            ToolbarItemIdentifier.recordingOutput,
            ToolbarItemIdentifier.refresh,
            ToolbarItemIdentifier.layoutMode,
            .flexibleSpace,
            .space,
            ToolbarItemIdentifier.fullScreen,
            ToolbarItemIdentifier.preferences,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarItemIdentifier.recording:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.action = #selector(toggleRecording(_:))
            recordingToolbarItem = item
            updateRecordingToolbarItemImage(item)
            return item

        case ToolbarItemIdentifier.recordingOutput:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.action = #selector(showRecordingHistory(_:))
            recordingOutputToolbarItem = item
            updateRecordingHistoryToolbarItemImage(item)
            return item

        case ToolbarItemIdentifier.layoutMode:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.toolbar.layoutMode
            item.paletteLabel = L10n.toolbar.layoutMode
            item.toolTip = L10n.toolbar.layoutModeTooltip

            // 使用 NSSegmentedControl 实现标准工具栏按钮组
            let segmentedControl = NSSegmentedControl()
            segmentedControl.segmentCount = 4
            segmentedControl.trackingMode = .selectOne
            segmentedControl.segmentStyle = .separated
            segmentedControl.target = self
            segmentedControl.action = #selector(layoutModeSegmentChanged(_:))

            // 段 0: 自动排列
            segmentedControl.setImage(
                NSImage(systemSymbolName: PreviewLayoutMode.auto.iconName, accessibilityDescription: PreviewLayoutMode.auto.displayName),
                forSegment: 0
            )
            segmentedControl.setToolTip(PreviewLayoutMode.auto.displayName, forSegment: 0)

            // 段 1: 网格
            segmentedControl.setImage(
                NSImage(systemSymbolName: PreviewLayoutMode.grid.iconName, accessibilityDescription: PreviewLayoutMode.grid.displayName),
                forSegment: 1
            )
            segmentedControl.setToolTip(PreviewLayoutMode.grid.displayName, forSegment: 1)

            // 段 2: 独立浮窗
            segmentedControl.setImage(
                NSImage(systemSymbolName: PreviewLayoutMode.floating.iconName, accessibilityDescription: PreviewLayoutMode.floating.displayName),
                forSegment: 2
            )
            segmentedControl.setToolTip(PreviewLayoutMode.floating.displayName, forSegment: 2)

            // 段 3: 交换位置
            segmentedControl.setImage(
                NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: L10n.toolbar.swapPanels),
                forSegment: 3
            )
            segmentedControl.setToolTip(L10n.toolbar.swapPanelsTooltip, forSegment: 3)

            item.view = segmentedControl
            layoutModeToolbarItem = item
            layoutModeSegmentedControl = segmentedControl
            updateLayoutModeToolbarState()
            return item

        case ToolbarItemIdentifier.refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.toolbar.refresh
            item.paletteLabel = L10n.toolbar.refresh
            item.toolTip = L10n.toolbar.refreshTooltip
            item.image = NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: L10n.toolbar.refresh
            )
            item.target = self
            item.action = #selector(refreshDevices(_:))
            refreshToolbarItem = item
            return item

        case ToolbarItemIdentifier.toggleBezel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.toolbar.toggleBezel
            item.paletteLabel = L10n.toolbar.toggleBezel
            item.toolTip = L10n.toolbar.toggleBezelTooltip
            updateBezelToolbarItemImage(item)
            item.target = self
            item.action = #selector(toggleDeviceBezel(_:))
            toggleBezelToolbarItem = item
            return item

        case ToolbarItemIdentifier.preventSleep:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.toolbar.preventSleep
            item.paletteLabel = L10n.toolbar.preventSleep
            item.toolTip = L10n.toolbar.preventSleepTooltip
            updatePreventSleepToolbarItemImage(item)
            item.target = self
            item.action = #selector(togglePreventSleep(_:))
            preventSleepToolbarItem = item
            return item

        case ToolbarItemIdentifier.devicePicker:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.devicePicker.toggleTooltip
            item.paletteLabel = L10n.devicePicker.toggleTooltip
            item.toolTip = L10n.devicePicker.toggleTooltip
            item.image = NSImage(
                systemSymbolName: "rectangle.stack.badge.plus",
                accessibilityDescription: L10n.devicePicker.toggleTooltip
            )
            item.target = self
            item.action = #selector(toggleDevicePicker(_:))
            return item

        case ToolbarItemIdentifier.fullScreen:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.toolbar.fullScreen
            item.paletteLabel = L10n.toolbar.fullScreen
            item.toolTip = L10n.toolbar.fullScreenTooltip
            item.image = NSImage(
                systemSymbolName: "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: L10n.toolbar.fullScreen
            )
            item.target = self
            item.action = #selector(toggleFullScreenFromToolbar(_:))
            fullScreenToolbarItem = item
            return item

        case ToolbarItemIdentifier.preferences:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.toolbar.preferences
            item.paletteLabel = L10n.toolbar.preferences
            item.toolTip = L10n.toolbar.preferencesTooltip
            item.image = NSImage(
                systemSymbolName: "gear",
                accessibilityDescription: L10n.toolbar.preferences
            )
            item.target = self
            item.action = #selector(showPreferences(_:))
            return item

        default:
            return nil
        }
    }

    private func updateBezelToolbarItemImage(_ item: NSToolbarItem) {
        let showBezel = UserPreferences.shared.showDeviceBezel
        // 使用不同的图标表示当前状态
        let symbolName = showBezel ? "iphone" : "iphone.slash"
        item.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: showBezel ? L10n.toolbar.hideBezel : L10n.toolbar.showBezel
        )
    }

    private func updatePreventSleepToolbarItemImage(_ item: NSToolbarItem) {
        let enabled = UserPreferences.shared.preventAutoLockDuringCapture
        // moon.zzz.fill = 阻止休眠（启用）；moon.zzz = 允许休眠（禁用）
        let symbolName = enabled ? "moon.zzz.fill" : "moon.zzz"
        item.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: enabled ? L10n.toolbar.preventSleepOn : L10n.toolbar.preventSleepOff
        )
    }
}

// MARK: - NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }

        // 没有配置更新源时禁用「检查更新」，避免点了没有任何反馈
        if action == #selector(checkForUpdates(_:)) {
            return UpdateManager.shared.isInitialized
        }

        // 「鼠标键盘控制」只对 Android 有效：只投 iOS 时置灰，避免用户以为 iOS 也能反向控制
        if menuItem === androidControlMenuItem {
            return AppState.shared.androidCapturing
        }

        return true
    }
}
