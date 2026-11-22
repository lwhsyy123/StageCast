//
//  ScrcpyClipboardBridge.swift
//  StageCast
//
//  Created by Sun on 2026/11/18.
//
//  scrcpy 剪贴板桥接
//  在设备剪贴板与 macOS 剪贴板之间做最小同步，避免演示时反复手动复制
//

import AppKit
import Foundation

/// 剪贴板桥接（单例）
final class ScrcpyClipboardBridge {
    // MARK: - 单例

    static let shared = ScrcpyClipboardBridge()

    // MARK: - 属性

    /// 是否把设备剪贴板自动写入 macOS 剪贴板
    var syncDeviceToMac = true

    /// 最近一次同步的文本（用于抑制回环）
    private var lastSyncedText: String?

    private init() {}

    // MARK: - 公开方法

    /// 设备剪贴板内容变化时调用
    /// - Parameter text: 设备剪贴板文本
    func updateFromDevice(_ text: String) {
        guard syncDeviceToMac, !text.isEmpty, text != lastSyncedText else { return }

        lastSyncedText = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLogger.capture.info("[Clipboard] 已把设备剪贴板同步到 macOS（\(text.count) 字符）")
    }

    /// 读取 macOS 剪贴板文本（用于粘贴到设备）
    func readLocalText() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return nil
        }
        lastSyncedText = text
        return text
    }
}
