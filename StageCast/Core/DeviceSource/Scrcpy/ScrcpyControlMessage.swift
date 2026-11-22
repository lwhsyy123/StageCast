//
//  ScrcpyControlMessage.swift
//  StageCast
//
//  Created by Sun on 2026/11/18.
//
//  scrcpy 控制消息
//  按照 scrcpy 4.x 控制协议（大端序）序列化客户端 → 服务端的控制消息
//  协议参考: https://github.com/Genymobile/scrcpy/blob/v4.0/app/src/control_msg.c
//

import Foundation

// MARK: - Android 事件常量

/// Android KeyEvent 动作
enum ScrcpyKeyAction: UInt8 {
    case down = 0
    case up = 1
}

/// Android MotionEvent 动作
enum ScrcpyTouchAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case outside = 4
    case pointerDown = 5
    case pointerUp = 6
    case hoverMove = 7
    case scroll = 8
}

/// Android MotionEvent 按键位（对应 AMOTION_EVENT_BUTTON_*）
struct ScrcpyMotionButton: OptionSet {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let none: ScrcpyMotionButton = []
    static let primary = ScrcpyMotionButton(rawValue: 1)
    static let secondary = ScrcpyMotionButton(rawValue: 2)
    static let tertiary = ScrcpyMotionButton(rawValue: 4)
    static let back = ScrcpyMotionButton(rawValue: 8)
    static let forward = ScrcpyMotionButton(rawValue: 16)
}

/// scrcpy 约定的特殊指针 ID
enum ScrcpyPointerId {
    /// 鼠标指针（支持悬停、右键、滚轮）
    static let mouse = UInt64(bitPattern: -1)
    /// 普通手指（模拟触摸）
    static let genericFinger = UInt64(bitPattern: -2)
    /// 虚拟手指（双指缩放/旋转时使用）
    static let virtualFinger = UInt64(bitPattern: -3)
}

/// 剪贴板复制类型
enum ScrcpyCopyKey: UInt8 {
    case none = 0
    case copy = 1
    case cut = 2
}

/// 控制消息类型（与 scrcpy control_msg.h 中的枚举顺序一致）
enum ScrcpyControlMessageType: UInt8 {
    case injectKeycode = 0
    case injectText = 1
    case injectTouchEvent = 2
    case injectScrollEvent = 3
    case backOrScreenOn = 4
    case expandNotificationPanel = 5
    case expandSettingsPanel = 6
    case collapsePanels = 7
    case getClipboard = 8
    case setClipboard = 9
    case setDisplayPower = 10
    case rotateDevice = 11
    case openHardKeyboardSettings = 15
    case startApp = 16
}

/// 注入文本的最大长度（scrcpy 限制）
let scrcpyInjectTextMaxLength = 300

// MARK: - 控制消息

/// scrcpy 控制消息
/// 每条消息都会被序列化为一段连续的字节，直接写入控制 socket（无长度前缀）
enum ScrcpyControlMessage {
    /// 注入按键事件
    case injectKeycode(action: ScrcpyKeyAction, keycode: Int, repeatCount: Int, metaState: Int)
    /// 注入文本（仅 ASCII 可打印字符可靠）
    case injectText(String)
    /// 注入触摸/鼠标事件
    case injectTouch(
        action: ScrcpyTouchAction,
        pointerId: UInt64,
        point: CGPoint,
        screenSize: CGSize,
        pressure: Float,
        actionButton: ScrcpyMotionButton,
        buttons: ScrcpyMotionButton
    )
    /// 注入滚轮事件（hScroll / vScroll 取值 -1...1）
    case injectScroll(
        point: CGPoint,
        screenSize: CGSize,
        hScroll: Float,
        vScroll: Float,
        buttons: ScrcpyMotionButton
    )
    /// 返回键（同时可点亮屏幕）
    case backOrScreenOn(ScrcpyKeyAction)
    /// 展开通知面板
    case expandNotificationPanel
    /// 展开快捷设置面板
    case expandSettingsPanel
    /// 收起面板
    case collapsePanels
    /// 获取设备剪贴板
    case getClipboard(ScrcpyCopyKey)
    /// 设置设备剪贴板（paste 为 true 时同时粘贴）
    case setClipboard(sequence: UInt64, text: String, paste: Bool)
    /// 设置屏幕电源
    case setDisplayPower(on: Bool)
    /// 旋转设备
    case rotateDevice
    /// 打开物理键盘设置
    case openHardKeyboardSettings
    /// 启动应用（包名）
    case startApp(String)

    // MARK: - 序列化

    /// 序列化为控制 socket 字节流
    func serialize() -> Data {
        var data = Data()
        data.append(type.rawValue)

        switch self {
        case let .injectKeycode(action, keycode, repeatCount, metaState):
            data.append(action.rawValue)
            data.appendUInt32BE(UInt32(bitPattern: Int32(keycode)))
            data.appendUInt32BE(UInt32(bitPattern: Int32(repeatCount)))
            data.appendUInt32BE(UInt32(bitPattern: Int32(metaState)))

        case let .injectText(text):
            data.appendString(text, maxLength: scrcpyInjectTextMaxLength)

        case let .injectTouch(action, pointerId, point, screenSize, pressure, actionButton, buttons):
            data.append(action.rawValue)
            data.appendUInt64BE(pointerId)
            data.appendPosition(point: point, screenSize: screenSize)
            data.appendUInt16BE(Self.pressureFixedPoint(pressure))
            data.appendUInt32BE(actionButton.rawValue)
            data.appendUInt32BE(buttons.rawValue)

        case let .injectScroll(point, screenSize, hScroll, vScroll, buttons):
            data.appendPosition(point: point, screenSize: screenSize)
            data.appendUInt16BE(UInt16(bitPattern: Self.scrollFixedPoint(hScroll)))
            data.appendUInt16BE(UInt16(bitPattern: Self.scrollFixedPoint(vScroll)))
            data.appendUInt32BE(buttons.rawValue)

        case let .backOrScreenOn(action):
            data.append(action.rawValue)

        case .expandNotificationPanel,
             .expandSettingsPanel,
             .collapsePanels,
             .rotateDevice,
             .openHardKeyboardSettings:
            break

        case let .getClipboard(copyKey):
            data.append(copyKey.rawValue)

        case let .setClipboard(sequence, text, paste):
            data.appendUInt64BE(sequence)
            data.append(paste ? 1 : 0)
            data.appendString(text, maxLength: 256 * 1024 - 14)

        case let .setDisplayPower(on):
            data.append(on ? 1 : 0)

        case let .startApp(name):
            data.appendTinyString(name, maxLength: 255)
        }

        return data
    }

    /// 消息类型
    var type: ScrcpyControlMessageType {
        switch self {
        case .injectKeycode: .injectKeycode
        case .injectText: .injectText
        case .injectTouch: .injectTouchEvent
        case .injectScroll: .injectScrollEvent
        case .backOrScreenOn: .backOrScreenOn
        case .expandNotificationPanel: .expandNotificationPanel
        case .expandSettingsPanel: .expandSettingsPanel
        case .collapsePanels: .collapsePanels
        case .getClipboard: .getClipboard
        case .setClipboard: .setClipboard
        case .setDisplayPower: .setDisplayPower
        case .rotateDevice: .rotateDevice
        case .openHardKeyboardSettings: .openHardKeyboardSettings
        case .startApp: .startApp
        }
    }

    // MARK: - 定点数转换

    /// 0...1 的浮点数转换为 16 位无符号定点数（sc_float_to_u16fp）
    static func pressureFixedPoint(_ value: Float) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        var fixed = UInt32(clamped * 65536)
        if fixed >= 0xFFFF {
            fixed = 0xFFFF
        }
        return UInt16(fixed)
    }

    /// -1...1 的浮点数转换为 16 位有符号定点数（sc_float_to_i16fp）
    static func scrollFixedPoint(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        let fixed = Int32(clamped * 32768)
        if fixed >= 0x7FFF {
            return 0x7FFF
        }
        if fixed <= -0x8000 {
            return -0x8000
        }
        return Int16(fixed)
    }
}

// MARK: - 数据写入辅助

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32((value >> 32) & 0xFFFF_FFFF))
        appendUInt32BE(UInt32(value & 0xFFFF_FFFF))
    }

    /// 写入位置：x(4) y(4) 屏幕宽(2) 屏幕高(2)
    mutating func appendPosition(point: CGPoint, screenSize: CGSize) {
        appendUInt32BE(UInt32(bitPattern: Int32(point.x.rounded())))
        appendUInt32BE(UInt32(bitPattern: Int32(point.y.rounded())))
        appendUInt16BE(Self.clampedUInt16(screenSize.width))
        appendUInt16BE(Self.clampedUInt16(screenSize.height))
    }

    /// 写入 4 字节长度 + UTF-8 文本（按字符边界截断）
    mutating func appendString(_ text: String, maxLength: Int) {
        let payload = Self.truncatedUTF8(text, maxLength: maxLength)
        appendUInt32BE(UInt32(payload.count))
        append(payload)
    }

    /// 写入 1 字节长度 + UTF-8 文本（按字符边界截断）
    mutating func appendTinyString(_ text: String, maxLength: Int) {
        let payload = Self.truncatedUTF8(text, maxLength: Swift.min(maxLength, 0xFF))
        append(UInt8(payload.count))
        append(payload)
    }

    static func clampedUInt16(_ value: CGFloat) -> UInt16 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt16(Swift.min(value, CGFloat(UInt16.max)))
    }

    /// 按 UTF-8 字符边界截断，避免截断半个字符导致设备端解码失败
    static func truncatedUTF8(_ text: String, maxLength: Int) -> Data {
        guard maxLength > 0 else { return Data() }
        let raw = Data(text.utf8)
        guard raw.count > maxLength else { return raw }

        var data = Data()
        data.reserveCapacity(maxLength)
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            guard data.count + bytes.count <= maxLength else { break }
            data.append(bytes)
        }
        return data
    }
}
