//
//  ScrcpyControlChannelTests.swift
//  StageCastTests
//
//  Created by Sun on 2026/11/18.
//
//  scrcpy 设备消息解析与输入控制器状态机测试
//

import XCTest
@testable import StageCast

final class ScrcpyControlChannelTests: XCTestCase {
    // MARK: - 设备消息解析

    func testParseClipboardMessage() {
        var data = Data([0]) // DEVICE_MSG_TYPE_CLIPBOARD
        let text = Data("hello".utf8)
        data.append(UInt8((text.count >> 24) & 0xFF))
        data.append(UInt8((text.count >> 16) & 0xFF))
        data.append(UInt8((text.count >> 8) & 0xFF))
        data.append(UInt8(text.count & 0xFF))
        data.append(text)

        let result = ScrcpyControlChannel.parseDeviceMessage(from: data)
        XCTAssertEqual(result?.0, .clipboard(text: "hello"))
        XCTAssertEqual(result?.1, 5 + text.count)
    }

    func testParseIncompleteClipboardReturnsNil() {
        var data = Data([0])
        data.append(contentsOf: [0, 0, 0, 10]) // 声明 10 字节，但只给 2 字节
        data.append(contentsOf: [0x41, 0x42])

        XCTAssertNil(ScrcpyControlChannel.parseDeviceMessage(from: data))
    }

    func testParseAckClipboard() {
        var data = Data([1])
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 42])
        let result = ScrcpyControlChannel.parseDeviceMessage(from: data)

        XCTAssertEqual(result?.0, .ackClipboard(sequence: 42))
        XCTAssertEqual(result?.1, 9)
    }

    func testParseUnknownTypeReturnsNil() {
        XCTAssertNil(ScrcpyControlChannel.parseDeviceMessage(from: Data([0x7F])))
    }

    // MARK: - 输入控制器

    func testPointerDownUpSequenceInMouseMode() {
        let controller = ScrcpyInputController()
        var sent: [ScrcpyControlMessage] = []
        controller.sendHandler = { message in
            sent.append(message)
            return true
        }

        controller.pointerDown(at: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 200))
        XCTAssertTrue(controller.buttons.contains(.primary))

        controller.pointerUp(at: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 200))
        XCTAssertEqual(controller.buttons, .none)

        XCTAssertEqual(sent.count, 2)
        guard case let .injectTouch(action, pointerId, _, _, _, _, _) = sent[0] else {
            return XCTFail("首条消息应为触摸事件")
        }
        XCTAssertEqual(action, .down)
        XCTAssertEqual(pointerId, ScrcpyPointerId.mouse)

        guard case let .injectTouch(upAction, _, _, _, _, _, _) = sent[1] else {
            return XCTFail("第二条消息应为触摸事件")
        }
        XCTAssertEqual(upAction, .up)
    }

    func testPointerUsesFingerInTouchMode() {
        let controller = ScrcpyInputController()
        controller.inputMode = .touch
        var sent: [ScrcpyControlMessage] = []
        controller.sendHandler = { message in
            sent.append(message)
            return true
        }

        controller.pointerDown(at: CGPoint(x: 1, y: 1), size: CGSize(width: 10, height: 10))
        guard case let .injectTouch(_, pointerId, _, _, _, _, _) = sent[0] else {
            return XCTFail("应注入触摸事件")
        }
        XCTAssertEqual(pointerId, ScrcpyPointerId.genericFinger)
    }

    func testHoverIgnoredWhenDisabled() {
        let controller = ScrcpyInputController()
        var sent: [ScrcpyControlMessage] = []
        controller.sendHandler = { message in
            sent.append(message)
            return true
        }

        controller.pointerHover(at: CGPoint(x: 1, y: 1), size: CGSize(width: 10, height: 10))
        XCTAssertTrue(sent.isEmpty)

        controller.hoverEnabled = true
        controller.pointerHover(at: CGPoint(x: 1, y: 1), size: CGSize(width: 10, height: 10))
        XCTAssertEqual(sent.count, 1)
    }

    func testDisabledControllerSendsNothing() {
        let controller = ScrcpyInputController()
        var sent: [ScrcpyControlMessage] = []
        controller.sendHandler = { message in
            sent.append(message)
            return true
        }

        controller.isEnabled = false
        controller.pointerDown(at: .zero, size: CGSize(width: 10, height: 10))
        controller.sendText("abc")
        controller.sendBack()
        controller.rotateDevice()

        XCTAssertTrue(sent.isEmpty)
    }

    func testVirtualFingerMirrorsAroundCenter() {
        let inverted = ScrcpyInputController.inverted(
            point: CGPoint(x: 10, y: 20),
            size: CGSize(width: 100, height: 200),
            invertX: true,
            invertY: true
        )
        XCTAssertEqual(inverted.x, 90)
        XCTAssertEqual(inverted.y, 180)

        let unchanged = ScrcpyInputController.inverted(
            point: CGPoint(x: 10, y: 20),
            size: CGSize(width: 100, height: 200),
            invertX: false,
            invertY: false
        )
        XCTAssertEqual(unchanged.x, 10)
        XCTAssertEqual(unchanged.y, 20)
    }

    func testTextChunkingRespectsByteLimit() {
        let text = String(repeating: "a", count: 700)
        let chunks = ScrcpyInputController.chunks(of: text, maxBytes: 300)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 300 })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testTextChunkingKeepsCharactersIntact() {
        // 中文 3 字节，300 字节上限 → 每片最多 100 字
        let text = String(repeating: "汉", count: 250)
        let chunks = ScrcpyInputController.chunks(of: text, maxBytes: 300)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 300 })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testScrollProducesScrollMessage() {
        let controller = ScrcpyInputController()
        var sent: [ScrcpyControlMessage] = []
        controller.sendHandler = { message in
            sent.append(message)
            return true
        }

        controller.scroll(dx: 0, dy: 30, at: CGPoint(x: 5, y: 5), size: CGSize(width: 10, height: 10))
        XCTAssertEqual(sent.count, 1)
        guard case let .injectScroll(_, _, _, vScroll, _) = sent[0] else {
            return XCTFail("应注入滚轮事件")
        }
        // macOS 的 scrollingDeltaY 与 Android AXIS_VSCROLL 同向，不需要取反
        XCTAssertGreaterThan(vScroll, 0)

        // 反向滚动
        sent.removeAll()
        controller.scroll(dx: 0, dy: -30, at: .zero, size: CGSize(width: 10, height: 10))
        guard case let .injectScroll(_, _, _, negative, _) = sent[0] else {
            return XCTFail("应注入滚轮事件")
        }
        XCTAssertLessThan(negative, 0)
    }

    func testSendTextHandlesNewlineAsEnterKey() {
        let controller = ScrcpyInputController()
        var sent: [ScrcpyControlMessage] = []
        controller.sendHandler = { message in
            sent.append(message)
            return true
        }

        controller.sendText("a\nb")

        // 文本 a、回车（down+up）、文本 b
        XCTAssertEqual(sent.count, 4)
        guard case let .injectKeycode(action, keycode, _, _) = sent[1] else {
            return XCTFail("换行应转为回车键")
        }
        XCTAssertEqual(action, .down)
        XCTAssertEqual(keycode, ScrcpyKeyCode.enter)
    }
}
