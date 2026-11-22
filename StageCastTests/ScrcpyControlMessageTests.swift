//
//  ScrcpyControlMessageTests.swift
//  StageCastTests
//
//  Created by Sun on 2026/11/18.
//
//  scrcpy 控制协议序列化测试
//  对照 scrcpy v4.0 app/src/control_msg.c 的字节布局逐字段校验
//

import XCTest
@testable import StageCast

final class ScrcpyControlMessageTests: XCTestCase {
    // MARK: - 按键

    func testInjectKeycodeLayout() {
        let message = ScrcpyControlMessage.injectKeycode(
            action: .down,
            keycode: ScrcpyKeyCode.back,
            repeatCount: 0,
            metaState: 0
        )
        let data = message.serialize()

        XCTAssertEqual(data.count, 14)
        XCTAssertEqual(data[0], 0) // TYPE_INJECT_KEYCODE
        XCTAssertEqual(data[1], 0) // ACTION_DOWN
        XCTAssertEqual(Array(data[2 ..< 6]), [0, 0, 0, 4]) // keycode 4 = BACK
        XCTAssertEqual(Array(data[6 ..< 10]), [0, 0, 0, 0])
        XCTAssertEqual(Array(data[10 ..< 14]), [0, 0, 0, 0])
    }

    func testInjectKeycodeWithMetaState() {
        let data = ScrcpyControlMessage.injectKeycode(
            action: .up,
            keycode: 29, // A
            repeatCount: 2,
            metaState: 0x1000
        ).serialize()

        XCTAssertEqual(data[1], 1) // ACTION_UP
        XCTAssertEqual(Array(data[2 ..< 6]), [0, 0, 0, 29])
        XCTAssertEqual(Array(data[6 ..< 10]), [0, 0, 0, 2])
        XCTAssertEqual(Array(data[10 ..< 14]), [0, 0, 0x10, 0x00])
    }

    // MARK: - 文本

    func testInjectTextLayout() {
        let data = ScrcpyControlMessage.injectText("hi").serialize()

        XCTAssertEqual(data[0], 1) // TYPE_INJECT_TEXT
        XCTAssertEqual(Array(data[1 ..< 5]), [0, 0, 0, 2]) // 长度 4 字节大端
        XCTAssertEqual(String(data: data.subdata(in: 5 ..< 7), encoding: .utf8), "hi")
    }

    func testInjectTextTruncatesAtScalarBoundary() {
        // 300 字节上限，中文每字 3 字节：100 字刚好 300 字节，第 101 字应被截断
        let text = String(repeating: "测", count: 120)
        let data = ScrcpyControlMessage.injectText(text).serialize()

        let length = Int(data[1]) << 24 | Int(data[2]) << 16 | Int(data[3]) << 8 | Int(data[4])
        XCTAssertEqual(length, 300)
        XCTAssertEqual(data.count, 5 + 300)
        // 截断后仍是合法 UTF-8
        XCTAssertNotNil(String(data: data.subdata(in: 5 ..< 5 + length), encoding: .utf8))
    }

    // MARK: - 触摸

    func testInjectTouchLayout() {
        let data = ScrcpyControlMessage.injectTouch(
            action: .down,
            pointerId: ScrcpyPointerId.mouse,
            point: CGPoint(x: 540, y: 960),
            screenSize: CGSize(width: 1080, height: 1920),
            pressure: 1,
            actionButton: .primary,
            buttons: .primary
        ).serialize()

        XCTAssertEqual(data.count, 32)
        XCTAssertEqual(data[0], 2) // TYPE_INJECT_TOUCH_EVENT
        XCTAssertEqual(data[1], 0) // ACTION_DOWN
        // pointer id -1 → 0xFFFFFFFFFFFFFFFF
        XCTAssertEqual(Array(data[2 ..< 10]), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        // x = 540
        XCTAssertEqual(Array(data[10 ..< 14]), [0, 0, 0x02, 0x1C])
        // y = 960
        XCTAssertEqual(Array(data[14 ..< 18]), [0, 0, 0x03, 0xC0])
        // 屏幕尺寸
        XCTAssertEqual(Array(data[18 ..< 20]), [0x04, 0x38]) // 1080
        XCTAssertEqual(Array(data[20 ..< 22]), [0x07, 0x80]) // 1920
        // pressure = 1.0 → 0xFFFF
        XCTAssertEqual(Array(data[22 ..< 24]), [0xFF, 0xFF])
        // actionButton = 1, buttons = 1
        XCTAssertEqual(Array(data[24 ..< 28]), [0, 0, 0, 1])
        XCTAssertEqual(Array(data[28 ..< 32]), [0, 0, 0, 1])
    }

    func testTouchPressureFixedPoint() {
        XCTAssertEqual(ScrcpyControlMessage.pressureFixedPoint(0), 0)
        XCTAssertEqual(ScrcpyControlMessage.pressureFixedPoint(1), 0xFFFF)
        XCTAssertEqual(ScrcpyControlMessage.pressureFixedPoint(0.5), 0x8000)
        // 越界应被钳制
        XCTAssertEqual(ScrcpyControlMessage.pressureFixedPoint(-1), 0)
        XCTAssertEqual(ScrcpyControlMessage.pressureFixedPoint(2), 0xFFFF)
    }

    // MARK: - 滚轮

    func testInjectScrollLayout() {
        let data = ScrcpyControlMessage.injectScroll(
            point: CGPoint(x: 100, y: 200),
            screenSize: CGSize(width: 1080, height: 1920),
            hScroll: 0,
            vScroll: -1,
            buttons: .none
        ).serialize()

        XCTAssertEqual(data.count, 21)
        XCTAssertEqual(data[0], 3) // TYPE_INJECT_SCROLL_EVENT
        XCTAssertEqual(Array(data[1 ..< 5]), [0, 0, 0, 100])
        XCTAssertEqual(Array(data[5 ..< 9]), [0, 0, 0, 200])
        XCTAssertEqual(Array(data[9 ..< 11]), [0x04, 0x38])
        XCTAssertEqual(Array(data[11 ..< 13]), [0x07, 0x80])
        // hscroll = 0
        XCTAssertEqual(Array(data[13 ..< 15]), [0, 0])
        // vscroll = -1 → 0x8000
        XCTAssertEqual(Array(data[15 ..< 17]), [0x80, 0x00])
        XCTAssertEqual(Array(data[17 ..< 21]), [0, 0, 0, 0])
    }

    func testScrollFixedPoint() {
        XCTAssertEqual(ScrcpyControlMessage.scrollFixedPoint(0), 0)
        XCTAssertEqual(ScrcpyControlMessage.scrollFixedPoint(1), 0x7FFF)
        XCTAssertEqual(ScrcpyControlMessage.scrollFixedPoint(-1), -0x8000)
        XCTAssertEqual(ScrcpyControlMessage.scrollFixedPoint(3), 0x7FFF) // 钳制
    }

    // MARK: - 无负载消息

    func testEmptyPayloadMessages() {
        XCTAssertEqual(ScrcpyControlMessage.expandNotificationPanel.serialize(), Data([5]))
        XCTAssertEqual(ScrcpyControlMessage.expandSettingsPanel.serialize(), Data([6]))
        XCTAssertEqual(ScrcpyControlMessage.collapsePanels.serialize(), Data([7]))
        XCTAssertEqual(ScrcpyControlMessage.rotateDevice.serialize(), Data([11]))
        XCTAssertEqual(ScrcpyControlMessage.openHardKeyboardSettings.serialize(), Data([15]))
    }

    func testBackOrScreenOn() {
        XCTAssertEqual(ScrcpyControlMessage.backOrScreenOn(.down).serialize(), Data([4, 0]))
        XCTAssertEqual(ScrcpyControlMessage.backOrScreenOn(.up).serialize(), Data([4, 1]))
    }

    func testSetDisplayPower() {
        XCTAssertEqual(ScrcpyControlMessage.setDisplayPower(on: true).serialize(), Data([10, 1]))
        XCTAssertEqual(ScrcpyControlMessage.setDisplayPower(on: false).serialize(), Data([10, 0]))
    }

    // MARK: - 剪贴板

    func testGetClipboard() {
        XCTAssertEqual(ScrcpyControlMessage.getClipboard(.copy).serialize(), Data([8, 1]))
        XCTAssertEqual(ScrcpyControlMessage.getClipboard(.cut).serialize(), Data([8, 2]))
    }

    func testSetClipboardLayout() {
        let data = ScrcpyControlMessage.setClipboard(sequence: 7, text: "ab", paste: true).serialize()

        XCTAssertEqual(data[0], 9)
        XCTAssertEqual(Array(data[1 ..< 9]), [0, 0, 0, 0, 0, 0, 0, 7]) // sequence
        XCTAssertEqual(data[9], 1) // paste
        XCTAssertEqual(Array(data[10 ..< 14]), [0, 0, 0, 2]) // 文本长度
        XCTAssertEqual(String(data: data.subdata(in: 14 ..< 16), encoding: .utf8), "ab")
    }

    // MARK: - 启动应用

    func testStartAppUsesTinyString() {
        let data = ScrcpyControlMessage.startApp("com.android.settings").serialize()

        XCTAssertEqual(data[0], 16)
        XCTAssertEqual(data[1], 20) // 1 字节长度
        XCTAssertEqual(String(data: data.subdata(in: 2 ..< 22), encoding: .utf8), "com.android.settings")
    }
}
