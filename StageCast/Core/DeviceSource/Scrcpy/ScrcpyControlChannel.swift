//
//  ScrcpyControlChannel.swift
//  StageCast
//
//  Created by Sun on 2026/11/18.
//
//  scrcpy 控制通道
//  在 video / audio 之后建立第三条 socket 连接，用于双向控制：
//  - 客户端 → 设备：发送 ScrcpyControlMessage（按键、触摸、滚轮、剪贴板等）
//  - 设备 → 客户端：接收 DeviceMessage（剪贴板同步、剪贴板 ACK 等）
//

import Foundation
import Network

// MARK: - 设备消息

/// 设备 → 客户端消息类型（scrcpy device_msg.h）
enum ScrcpyDeviceMessageType: UInt8 {
    case clipboard = 0
    case ackClipboard = 1
}

/// 设备 → 客户端消息
enum ScrcpyDeviceMessage: Equatable {
    /// 设备剪贴板内容变化
    case clipboard(text: String)
    /// 设备确认收到指定序号的剪贴板写入
    case ackClipboard(sequence: UInt64)
}

// MARK: - 控制通道

/// scrcpy 控制通道
/// 负责建立控制 socket、发送控制消息、解析设备消息
final class ScrcpyControlChannel {
    // MARK: - 常量

    /// 单条设备消息的最大长度（与 scrcpy DEVICE_MSG_MAX_SIZE 一致）
    private static let maxMessageSize = 1 << 18

    // MARK: - 属性

    /// 控制连接
    private var connection: NWConnection?

    /// 连接所在队列
    private let queue: DispatchQueue

    /// 接收缓冲区
    private var receiveBuffer = Data()

    /// 是否已就绪
    private(set) var isReady = false

    /// 设备消息回调
    var onDeviceMessage: ((ScrcpyDeviceMessage) -> Void)?

    /// 连接断开回调
    var onDisconnected: (() -> Void)?

    /// 发送统计（用于诊断）
    private var sentMessageCount = 0

    // MARK: - 初始化

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: - 连接

    /// 接管一条已经就绪的控制连接
    /// 连接由 ScrcpySocketAcceptor 建立并启动，这里只接管读写与状态监听
    /// - Parameter connection: 已就绪的 NWConnection
    func attach(_ connection: NWConnection) {
        self.connection = connection
        isReady = true

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed:
                isReady = false
                AppLogger.connection.error("[ControlChannel] 控制连接中断")
                onDisconnected?()
            case .cancelled:
                isReady = false
                AppLogger.connection.info("[ControlChannel] 控制连接已关闭")
            default:
                break
            }
        }

        AppLogger.connection.info("[ControlChannel] ✅ 控制连接已接管，开始接收设备消息")
        startReceiving()
    }

    /// 停止并释放连接
    func stop() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isReady = false
        receiveBuffer.removeAll()
    }

    // MARK: - 发送

    /// 发送一条控制消息
    /// - Parameter message: 控制消息
    /// - Returns: 是否成功入队
    @discardableResult
    func send(_ message: ScrcpyControlMessage) -> Bool {
        guard let connection, isReady else {
            AppLogger.connection.debug("[ControlChannel] 控制通道未就绪，丢弃消息: \(message.type)")
            return false
        }

        let data = message.serialize()
        guard !data.isEmpty else { return false }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            AppLogger.connection.error("[ControlChannel] 发送控制消息失败: \(error.localizedDescription)")
            self?.isReady = false
        })

        sentMessageCount += 1
        if sentMessageCount % 200 == 1 {
            AppLogger.connection.debug("[ControlChannel] 已发送 \(sentMessageCount) 条控制消息")
        }
        return true
    }

    // MARK: - 接收

    /// 开始接收设备消息
    private func startReceiving() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                AppLogger.connection.error("[ControlChannel] 接收设备消息失败: \(error.localizedDescription)")
                isReady = false
                onDisconnected?()
                return
            }

            if let data = content, !data.isEmpty {
                receiveBuffer.append(data)
                parseDeviceMessages()
            }

            if isComplete {
                AppLogger.connection.info("[ControlChannel] 控制连接已被对端关闭")
                isReady = false
                onDisconnected?()
                return
            }

            startReceiving()
        }
    }

    /// 从缓冲区解析完整消息，剩余不完整数据留待下次
    private func parseDeviceMessages() {
        while !receiveBuffer.isEmpty {
            // 未知消息类型无法重新同步，直接清空缓冲区，避免缓冲区无限增长
            guard let typeByte = receiveBuffer.first,
                  ScrcpyDeviceMessageType(rawValue: typeByte) != nil else {
                AppLogger.connection.error(
                    "[ControlChannel] 未知设备消息类型: \(String(describing: receiveBuffer.first))，丢弃缓冲区"
                )
                receiveBuffer.removeAll(keepingCapacity: true)
                return
            }
            guard let (message, consumed) = Self.parseDeviceMessage(from: receiveBuffer) else {
                // 数据不完整，等待后续数据
                return
            }
            receiveBuffer.removeFirst(consumed)
            onDeviceMessage?(message)
        }
    }

    /// 解析一条设备消息
    /// - Parameter buffer: 缓冲区
    /// - Returns: 消息与已消费字节数；数据不完整时返回 nil
    static func parseDeviceMessage(from buffer: Data) -> (ScrcpyDeviceMessage, Int)? {
        guard let typeByte = buffer.first else { return nil }

        // receiveBuffer 经过 removeFirst 后 startIndex 不为 0，
        // 所有绝对索引必须基于 startIndex 计算，否则 subdata(in:) 会越界崩溃
        let base = buffer.startIndex

        switch typeByte {
        case ScrcpyDeviceMessageType.clipboard.rawValue:
            guard buffer.count >= 5 else { return nil }
            let length = Int(buffer.readUInt32BE(at: 1))
            guard length <= Self.maxMessageSize else {
                AppLogger.connection.error("[ControlChannel] 剪贴板消息长度异常: \(length)，丢弃缓冲区")
                return nil
            }
            guard buffer.count >= 5 + length else { return nil }
            let textData = buffer.subdata(in: (base + 5) ..< (base + 5 + length))
            let text = String(data: textData, encoding: .utf8) ?? ""
            return (.clipboard(text: text), 5 + length)

        case ScrcpyDeviceMessageType.ackClipboard.rawValue:
            guard buffer.count >= 9 else { return nil }
            let sequence = buffer.readUInt64BE(at: 1)
            return (.ackClipboard(sequence: sequence), 9)

        default:
            // 未知消息类型：无法恢复，交由调用方清空缓冲区
            return nil
        }
    }
}

// MARK: - Data 读取辅助

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        (UInt64(readUInt32BE(at: offset)) << 32) | UInt64(readUInt32BE(at: offset + 4))
    }
}
