//
//  ScrcpyInputController.swift
//  StageCast
//
//  Created by Sun on 2026/11/18.
//
//  scrcpy 输入控制器
//  将 macOS 鼠标/键盘事件翻译为 scrcpy 控制消息，提供与 scrcpy 桌面端一致的交互：
//  - 左键点击/拖拽 = 触摸点按/滑动
//  - 右键 = 返回，中键 = 桌面，侧键 = 多任务
//  - 滚轮 = 滑动
//  - ⌥ + 左键拖拽 = 双指缩放/旋转（虚拟手指）
//  - 键盘输入 = 文本注入，功能键 = 按键注入
//

import AppKit
import Foundation

// MARK: - 输入模式

/// 输入模式
enum ScrcpyInputMode: String, CaseIterable {
    /// 鼠标模式：与 scrcpy 桌面端一致，支持悬停、右键返回、滚轮
    case mouse
    /// 触摸模式：所有操作都按手指触摸注入，兼容只接受触摸的 App（如游戏）
    case touch

    var displayName: String {
        switch self {
        case .mouse: L10n.prefs.scrcpyPref.controlModeMouse
        case .touch: L10n.prefs.scrcpyPref.controlModeTouch
        }
    }
}

// MARK: - Android 按键码

/// Android KeyEvent 按键码（android/keycodes.h）
enum ScrcpyKeyCode {
    static let home = 3
    static let back = 4
    static let call = 5
    static let menu = 82
    static let appSwitch = 187
    static let enter = 66
    static let del = 67
    static let forwardDel = 112
    static let tab = 61
    static let escape = 111
    static let space = 62
    static let dpadUp = 19
    static let dpadDown = 20
    static let dpadLeft = 21
    static let dpadRight = 22
    static let moveHome = 122
    static let moveEnd = 123
    static let pageUp = 92
    static let pageDown = 93
    static let power = 26
    static let volumeUp = 24
    static let volumeDown = 25
    static let camera = 27
    static let notification = 83
    static let search = 84
}

// MARK: - 输入控制器

/// scrcpy 输入控制器
/// 负责维护指针/按键状态，并把高层操作翻译为控制消息
final class ScrcpyInputController {
    // MARK: - 发送

    /// 消息发送句柄（由 ScrcpyControlChannel 提供）
    var sendHandler: ((ScrcpyControlMessage) -> Bool)?

    // MARK: - 配置

    /// 输入模式
    var inputMode: ScrcpyInputMode = .mouse

    /// 是否发送鼠标悬停事件（鼠标模式下有效）
    var hoverEnabled = false

    /// 是否允许控制（关闭后只投屏不注入）
    var isEnabled = true

    // MARK: - 状态

    /// 当前按下的鼠标按钮
    private(set) var buttons: ScrcpyMotionButton = .none

    /// 主指针（手指或鼠标）是否处于按下状态
    private(set) var isPointerDown = false

    /// 虚拟手指（双指手势）是否处于按下状态
    private(set) var isVirtualFingerDown = false

    /// 虚拟手指的反转方向（对应 scrcpy 的 Ctrl/Shift 组合）
    private var vfingerInvertX = false
    private var vfingerInvertY = false

    /// 剪贴板写入序号（设备端用于 ACK 匹配）
    private var clipboardSequence: UInt64 = 0

    /// 最近一次触摸位置（用于滚轮、按键时的位置）
    private var lastPosition: (point: CGPoint, size: CGSize)?

    // MARK: - 指针操作

    /// 指针按下
    /// - Parameters:
    ///   - point: 设备坐标系中的位置
    ///   - size: 设备屏幕尺寸
    ///   - button: 鼠标按钮（鼠标模式下用于区分左右键）
    func pointerDown(at point: CGPoint, size: CGSize, button: ScrcpyMotionButton = .primary) {
        AppLogger.capture.info("[输入诊断] pointerDown point=\(point) size=\(size) enabled=\(isEnabled)")
        guard isEnabled else { return }
        lastPosition = (point, size)

        if inputMode == .mouse {
            buttons.insert(button)
            send(.injectTouch(
                action: .down,
                pointerId: ScrcpyPointerId.mouse,
                point: point,
                screenSize: size,
                pressure: 1,
                actionButton: button,
                buttons: buttons
            ))
        } else {
            isPointerDown = true
            send(.injectTouch(
                action: .down,
                pointerId: ScrcpyPointerId.genericFinger,
                point: point,
                screenSize: size,
                pressure: 1,
                actionButton: .none,
                buttons: .none
            ))
        }
    }

    /// 指针移动（拖拽）
    func pointerMove(to point: CGPoint, size: CGSize) {
        guard isEnabled else { return }
        lastPosition = (point, size)

        let isActive = inputMode == .mouse ? buttons != .none : isPointerDown
        guard isActive else { return }

        send(.injectTouch(
            action: .move,
            pointerId: inputMode == .mouse ? ScrcpyPointerId.mouse : ScrcpyPointerId.genericFinger,
            point: point,
            screenSize: size,
            pressure: 1,
            actionButton: .none,
            buttons: inputMode == .mouse ? buttons : .none
        ))

        // 虚拟手指：围绕屏幕中心做镜像移动，实现双指缩放/旋转
        if isVirtualFingerDown {
            let mirrored = Self.inverted(point: point, size: size, invertX: vfingerInvertX, invertY: vfingerInvertY)
            send(.injectTouch(
                action: .move,
                pointerId: ScrcpyPointerId.virtualFinger,
                point: mirrored,
                screenSize: size,
                pressure: 1,
                actionButton: .none,
                buttons: .none
            ))
        }
    }

    /// 指针抬起
    func pointerUp(at point: CGPoint, size: CGSize, button: ScrcpyMotionButton = .primary) {
        guard isEnabled else { return }
        lastPosition = (point, size)

        if inputMode == .mouse {
            buttons.remove(button)
            send(.injectTouch(
                action: .up,
                pointerId: ScrcpyPointerId.mouse,
                point: point,
                screenSize: size,
                pressure: 0,
                actionButton: button,
                buttons: buttons
            ))
        } else {
            isPointerDown = false
            send(.injectTouch(
                action: .up,
                pointerId: ScrcpyPointerId.genericFinger,
                point: point,
                screenSize: size,
                pressure: 0,
                actionButton: .none,
                buttons: .none
            ))
        }

        // 抬起时一并结束虚拟手指，避免设备端残留多点触摸
        if isVirtualFingerDown {
            isVirtualFingerDown = false
            send(.injectTouch(
                action: .up,
                pointerId: ScrcpyPointerId.virtualFinger,
                point: point,
                screenSize: size,
                pressure: 0,
                actionButton: .none,
                buttons: .none
            ))
        }
    }

    /// 鼠标悬停（仅在鼠标模式且开启 hover 时发送）
    func pointerHover(at point: CGPoint, size: CGSize) {
        guard isEnabled, inputMode == .mouse, hoverEnabled, buttons == .none else { return }
        lastPosition = (point, size)
        send(.injectTouch(
            action: .hoverMove,
            pointerId: ScrcpyPointerId.mouse,
            point: point,
            screenSize: size,
            pressure: 1,
            actionButton: .none,
            buttons: .none
        ))
    }

    /// 结束当前指针状态（停止投屏或鼠标移出画面时调用）
    /// 会主动发送抬起/取消事件，避免设备端残留按下的触点
    func resetPointer() {
        if let (point, size) = lastPosition {
            if isVirtualFingerDown {
                isVirtualFingerDown = false
                send(.injectTouch(
                    action: .up,
                    pointerId: ScrcpyPointerId.virtualFinger,
                    point: point,
                    screenSize: size,
                    pressure: 0,
                    actionButton: .none,
                    buttons: .none
                ))
            }
            if isPointerDown {
                isPointerDown = false
                send(.injectTouch(
                    action: .up,
                    pointerId: ScrcpyPointerId.genericFinger,
                    point: point,
                    screenSize: size,
                    pressure: 0,
                    actionButton: .none,
                    buttons: .none
                ))
            }
            if buttons != .none {
                send(.injectTouch(
                    action: .up,
                    pointerId: ScrcpyPointerId.mouse,
                    point: point,
                    screenSize: size,
                    pressure: 0,
                    actionButton: .primary,
                    buttons: .none
                ))
            }
        }
        isPointerDown = false
        isVirtualFingerDown = false
        buttons = .none
    }

    // MARK: - 双指手势

    /// 开始双指手势（⌥ + 左键按下）
    /// - Parameters:
    ///   - point: 主手指位置
    ///   - size: 设备屏幕尺寸
    ///   - ctrlPressed: 是否按下 Control（与 scrcpy 一致：Ctrl 控制旋转）
    ///   - shiftPressed: 是否按下 Shift（与 scrcpy 一致：Shift 控制纵向倾斜）
    func beginVirtualFinger(at point: CGPoint, size: CGSize, ctrlPressed: Bool, shiftPressed: Bool) {
        guard isEnabled else { return }
        vfingerInvertX = ctrlPressed != shiftPressed
        vfingerInvertY = ctrlPressed

        let mirrored = Self.inverted(point: point, size: size, invertX: vfingerInvertX, invertY: vfingerInvertY)
        isVirtualFingerDown = true
        send(.injectTouch(
            action: .down,
            pointerId: ScrcpyPointerId.virtualFinger,
            point: mirrored,
            screenSize: size,
            pressure: 1,
            actionButton: .none,
            buttons: .none
        ))
    }

    // MARK: - 滚轮

    /// 滚轮滚动
    /// - Parameters:
    ///   - dx: 水平滚动量（macOS 点，正数表示内容向右移动）
    ///   - dy: 垂直滚动量（macOS 点，正数表示内容向下移动，即向上翻页）
    ///   - point: 当前指针位置
    ///   - size: 设备屏幕尺寸
    func scroll(dx: CGFloat, dy: CGFloat, at point: CGPoint, size: CGSize) {
        AppLogger.capture.info("[输入诊断] scroll dx=\(dx) dy=\(dy) point=\(point) size=\(size) enabled=\(isEnabled)")
        guard isEnabled else { return }
        lastPosition = (point, size)

        // 入参已经是“行”单位，方向与 Android AXIS_VSCROLL 一致，无需取反
        let h = Float(Self.clampScrollLines(dx))
        let v = Float(Self.clampScrollLines(dy))
        guard h != 0 || v != 0 else { return }

        send(.injectScroll(
            point: point,
            screenSize: size,
            hScroll: h,
            vScroll: v,
            buttons: buttons
        ))
    }

    // MARK: - 按键

    /// 注入文本
    /// - ASCII 部分通过 inject_text 逐字符注入
    /// - 非 ASCII（中文等）无法用 KeyCharacterMap 还原，改用剪贴板粘贴，与 scrcpy 的降级策略一致
    func sendText(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }

        var asciiBuffer = ""
        var pendingNonASCII = ""

        func flushNonASCII() {
            guard !pendingNonASCII.isEmpty else { return }
            setClipboard(pendingNonASCII, paste: true)
            pendingNonASCII = ""
        }

        func flushASCII() {
            guard !asciiBuffer.isEmpty else { return }
            // 单条消息最多 300 字节，超长时分片发送
            for chunk in Self.chunks(of: asciiBuffer, maxBytes: scrcpyInjectTextMaxLength) {
                send(.injectText(chunk))
            }
            asciiBuffer = ""
        }

        for character in text {
            if character.isASCII, !character.isNewline {
                flushNonASCII()
                asciiBuffer.append(character)
            } else if character.isNewline {
                flushNonASCII()
                flushASCII()
                sendKey(ScrcpyKeyCode.enter)
            } else {
                flushASCII()
                pendingNonASCII.append(character)
            }
        }

        flushASCII()
        flushNonASCII()
    }

    /// 注入按键（按下 + 抬起）
    /// - Parameters:
    ///   - keycode: Android 按键码
    ///   - metaState: 修饰键状态（Android MetaKey 位掩码）
    func sendKey(_ keycode: Int, metaState: Int = 0) {
        guard isEnabled else { return }
        send(.injectKeycode(action: .down, keycode: keycode, repeatCount: 0, metaState: metaState))
        send(.injectKeycode(action: .up, keycode: keycode, repeatCount: 0, metaState: metaState))
    }

    /// 返回键
    func sendBack() {
        guard isEnabled else { return }
        // back_or_screen_on 在屏幕熄灭时还能点亮屏幕
        send(.backOrScreenOn(.down))
        send(.backOrScreenOn(.up))
    }

    /// 桌面（Home）
    func sendHome() {
        sendKey(ScrcpyKeyCode.home)
    }

    /// 多任务（最近任务）
    func sendAppSwitch() {
        sendKey(ScrcpyKeyCode.appSwitch)
    }

    /// 菜单
    func sendMenu() {
        sendKey(ScrcpyKeyCode.menu)
    }

    /// 旋转屏幕
    func rotateDevice() {
        guard isEnabled else { return }
        send(.rotateDevice)
    }

    /// 电源键
    func sendPower() {
        sendKey(ScrcpyKeyCode.power)
    }

    /// 音量加/减
    func sendVolumeUp() {
        sendKey(ScrcpyKeyCode.volumeUp)
    }

    func sendVolumeDown() {
        sendKey(ScrcpyKeyCode.volumeDown)
    }

    /// 展开通知面板
    func expandNotificationPanel() {
        guard isEnabled else { return }
        send(.expandNotificationPanel)
    }

    /// 展开快捷设置面板
    func expandSettingsPanel() {
        guard isEnabled else { return }
        send(.expandSettingsPanel)
    }

    /// 收起所有面板
    func collapsePanels() {
        guard isEnabled else { return }
        send(.collapsePanels)
    }

    /// 写入设备剪贴板
    /// - Parameters:
    ///   - text: 文本
    ///   - paste: 是否立即粘贴
    func setClipboard(_ text: String, paste: Bool) {
        guard isEnabled else { return }
        clipboardSequence += 1
        send(.setClipboard(sequence: clipboardSequence, text: text, paste: paste))
    }

    /// 请求设备剪贴板
    func requestClipboard(cut: Bool = false) {
        guard isEnabled else { return }
        send(.getClipboard(cut ? .cut : .copy))
    }

    /// 设置屏幕电源
    func setDisplayPower(on: Bool) {
        guard isEnabled else { return }
        send(.setDisplayPower(on: on))
    }

    /// 启动应用
    func startApp(packageName: String) {
        guard isEnabled, !packageName.isEmpty else { return }
        send(.startApp(packageName))
    }

    // MARK: - 私有方法

    /// 发送消息
    private func send(_ message: ScrcpyControlMessage) {
        _ = sendHandler?(message)
    }

    /// 把滚动行数限制在 scrcpy 允许的 ±16 区间
    static func clampScrollLines(_ lines: CGFloat) -> CGFloat {
        guard lines.isFinite else { return 0 }
        return Swift.min(Swift.max(lines, -16), 16)
    }

    /// 计算关于屏幕中心镜像的点
    static func inverted(point: CGPoint, size: CGSize, invertX: Bool, invertY: Bool) -> CGPoint {
        let x = invertX ? size.width - point.x : point.x
        let y = invertY ? size.height - point.y : point.y
        return CGPoint(x: x, y: y)
    }

    /// 按 UTF-8 字节数分片，且不切断字符
    static func chunks(of text: String, maxBytes: Int) -> [String] {
        guard maxBytes > 0 else { return [] }
        var result: [String] = []
        var current = ""
        var currentBytes = 0

        for character in text {
            let characterBytes = String(character).utf8.count
            if currentBytes + characterBytes > maxBytes {
                if !current.isEmpty {
                    result.append(current)
                }
                current = String(character)
                currentBytes = characterBytes
            } else {
                current.append(character)
                currentBytes += characterBytes
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
