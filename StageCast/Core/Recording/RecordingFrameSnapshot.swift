//
//  RecordingFrameSnapshot.swift
//  StageCast
//
//  Created by Sun on 2026/06/30.
//
//  录制画面快照
//  描述当前可写入视频的一台投屏设备
//

import CoreVideo
import Foundation

// MARK: - 录制画面快照

struct RecordingFrameSnapshot {
    let platform: DevicePlatform
    /// 稳定的设备标识（Android 用 serial，iOS 用 device.id）。
    /// 录制轨道、每格录制按钮的开关判定都以它为准，deviceName 只用于目录命名。
    let deviceID: String
    let deviceName: String
    let pixelBuffer: CVPixelBuffer
}
