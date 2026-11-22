//
//  ScreenCornerDetector.swift
//  StageCast
//
//  Created by Sun on 2026/11/19.
//
//  屏幕圆角检测器
//  从解码后的 BGRA 像素中判断画面是否为圆角屏，并估算圆角半径
//
//  原理：
//  圆角矩形的圆角区域是一个「切角」，角点附近一定范围内是背景色（通常为黑）。
//  沿对角线从角点向内扫描，会在 d = r * (sqrt(2) - 1) 处碰到圆弧边界，
//  由此可反推出半径 r = d / (sqrt(2) - 1)。
//
//  现实情况：
//  部分角（例如底部导航栏、深色状态栏）与圆角背景同色，扫不到边界。
//  因此按「部分角有效」处理：剔除噪声值后，至少两个角一致即可采纳。
//
//  为避免单帧误判，采用多帧一致性校验，任一步失败都返回 nil，
//  由调用方回退到设备规格数据。
//

import CoreVideo
import Foundation

// MARK: - 检测结果

/// 屏幕圆角检测结果
struct ScreenCornerResult: Equatable {
    /// 圆角半径（单位：视频像素）
    let radiusInPixels: CGFloat
    /// 参与投票的角数量
    let votedCorners: Int
    /// 各角测得的半径（仅包含成功测到边界的角）
    let cornerRadii: [CGFloat]

    /// 是否为直角屏
    var isSquare: Bool { radiusInPixels < 1 }
}

// MARK: - 单角测量结果

/// 单个角的测量结果
private enum CornerMeasurement: Equatable {
    /// 测到「背景 → 内容」边界，附带反推半径
    case measured(CGFloat)
    /// 整条对角线都与角点同色，未发现边界
    case noBoundary
    /// 采样越界等异常
    case failed
}

// MARK: - 检测器

/// 屏幕圆角检测器
/// 从 CVPixelBuffer 采样四角像素，推断真实圆角半径
enum ScreenCornerDetector {
    // MARK: - 配置

    /// 采样块边长（像素）。取四角各 128x128 区域。
    /// 注意：对角线扫描距离 d = r × (√2−1) ≈ 0.414r；短边 1080 的视频
    /// maxRadiusRatio 0.20 → 半径上限 216px → 扫描距离 ~89px。
    /// 旧值 64 覆盖不到大圆角（会误判为 noBoundary → 直角屏）。
    private static let sampleSize = 128

    /// 颜色差异阈值（三通道绝对差之和）。低于该值视为同色
    private static let colorThreshold: Int = 24

    /// 圆角半径合理区间（相对于视频短边的比例）
    private static let minRadiusRatio: CGFloat = 0.005
    private static let maxRadiusRatio: CGFloat = 0.20

    // MARK: - 公开方法

    /// 检测屏幕圆角
    /// - Parameter pixelBuffer: 解码后的 BGRA 像素缓冲
    /// - Returns: 检测结果；无法可靠判断时返回 nil
    static func detect(from pixelBuffer: CVPixelBuffer) -> ScreenCornerResult? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > sampleSize * 2, height > sampleSize * 2 else { return nil }

        let shortSide = CGFloat(min(width, height))
        let minRadius = shortSide * minRadiusRatio
        let maxRadius = shortSide * maxRadiusRatio

        // 防「启动黑帧」误判：投屏刚建立的几帧画面可能是纯色（黑），
        // 四角与中心全部同色会让直角检测得出虚假的「直角屏」结论并锁定。
        // 只有帧内确实存在内容（中心与角点颜色不同）时才允许下结论。
        if isFrameUniform(base: base, bytesPerRow: bytesPerRow,
                          width: width, height: height) {
            return nil
        }

        // 四角分别测量
        let corners: [CornerMeasurement] = [
            measureCorner(base: base, bytesPerRow: bytesPerRow,
                          originX: 0, originY: 0, dirX: 1, dirY: 1),
            measureCorner(base: base, bytesPerRow: bytesPerRow,
                          originX: width - 1, originY: 0, dirX: -1, dirY: 1),
            measureCorner(base: base, bytesPerRow: bytesPerRow,
                          originX: 0, originY: height - 1, dirX: 1, dirY: -1),
            measureCorner(base: base, bytesPerRow: bytesPerRow,
                          originX: width - 1, originY: height - 1, dirX: -1, dirY: -1),
        ]

        let measured: [CGFloat] = corners.compactMap { corner in
            if case let .measured(radius) = corner { return radius }
            return nil
        }
        let noBoundaryCount = corners.filter { $0 == .noBoundary }.count

        // 情况 1：四角都没发现「背景 → 内容」边界
        // 说明画面铺满到角点（直角屏），正是「原始画面是直的」场景。
        // 若四角恰好都是深色内容导致误判，会在多帧确认阶段被过滤。
        if measured.isEmpty {
            AppLogger.connection.debug("[CornerDetect] 四角均无边界 → 直角屏")
            return ScreenCornerResult(radiusInPixels: 0, votedCorners: 0, cornerRadii: [])
        }

        // 情况 2：只测到部分角（底部导航栏等与圆角同色时测不到）
        // 先过滤超出合理范围的噪声值
        let valid = measured.filter { $0 >= minRadius && $0 <= maxRadius }
        guard !valid.isEmpty else {
            AppLogger.connection.debug("[CornerDetect] 全部超范围 measured=\(measured)")
            return nil
        }

        let sortedValid = valid.sorted()
        let median: CGFloat = {
            let count = sortedValid.count
            if count % 2 == 0 {
                return (sortedValid[count / 2 - 1] + sortedValid[count / 2]) / 2
            }
            return sortedValid[count / 2]
        }()

        // 一致性校验：与中位数偏差过大的角视为被内容干扰，剔除后至少保留 2 个
        let tolerance = max(6, median * 0.35)
        let consistent = valid.filter { abs($0 - median) <= tolerance }
        guard consistent.count >= 2 else {
            AppLogger.connection.debug(
                "[CornerDetect] 一致角不足 valid=\(valid) median=\(median) "
                + "tol=\(tolerance) consistent=\(consistent.count)"
            )
            return nil
        }

        AppLogger.connection.debug(
            "[CornerDetect] 采纳 measured=\(measured) noBoundary=\(noBoundaryCount) "
            + "median=\(median) consistent=\(consistent)"
        )

        return ScreenCornerResult(
            radiusInPixels: median,
            votedCorners: consistent.count,
            cornerRadii: measured
        )
    }

    // MARK: - 私有方法

    /// 判断整帧是否近似纯色（黑屏或纯色启动帧）
    /// 取中心区平均色与四角平均色比较，全部接近则认为无有效内容
    private static func isFrameUniform(
        base: UnsafeRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) -> Bool {
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        func avgColor(cx: Int, cy: Int, half: Int) -> (Int, Int, Int) {
            var r = 0, g = 0, b = 0, n = 0
            for y in max(0, cy - half)...min(height - 1, cy + half) {
                for x in max(0, cx - half)...min(width - 1, cx + half) {
                    let off = y * bytesPerRow + x * 4
                    r += Int(ptr[off + 2])
                    g += Int(ptr[off + 1])
                    b += Int(ptr[off])
                    n += 1
                }
            }
            guard n > 0 else { return (0, 0, 0) }
            return (r / n, g / n, b / n)
        }

        func diff(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }

        let half = 8
        let center = avgColor(cx: width / 2, cy: height / 2, half: half)
        let corners = [
            avgColor(cx: sampleSize, cy: sampleSize, half: half),
            avgColor(cx: width - 1 - sampleSize, cy: sampleSize, half: half),
            avgColor(cx: sampleSize, cy: height - 1 - sampleSize, half: half),
            avgColor(cx: width - 1 - sampleSize, cy: height - 1 - sampleSize, half: half),
        ]

        // 中心与所有角都几乎同色 → 整帧无内容
        return corners.allSatisfy { diff(center, $0) <= colorThreshold }
    }

    /// 测量单个角
    /// - Parameters:
    ///   - originX/originY: 角点像素坐标
    ///   - dirX/dirY: 向内扫描的方向（±1）
    private static func measureCorner(
        base: UnsafeRawPointer,
        bytesPerRow: Int,
        originX: Int,
        originY: Int,
        dirX: Int,
        dirY: Int
    ) -> CornerMeasurement {
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        func color(atX x: Int, y: Int) -> (Int, Int, Int) {
            let offset = y * bytesPerRow + x * 4
            // BGRA 布局
            return (
                Int(ptr[offset + 2]),   // R
                Int(ptr[offset + 1]),   // G
                Int(ptr[offset])        // B
            )
        }

        let origin = color(atX: originX, y: originY)

        for step in 1..<sampleSize {
            let x = originX + dirX * step
            let y = originY + dirY * step
            guard x >= 0, y >= 0 else { return .failed }

            let c = color(atX: x, y: y)
            let diff = abs(c.0 - origin.0) + abs(c.1 - origin.1) + abs(c.2 - origin.2)
            if diff > colorThreshold {
                // 几何关系：对角线距离 d = r * (sqrt(2) - 1)
                return .measured(CGFloat(step) / (sqrt(2) - 1))
            }
        }

        return .noBoundary
    }
}

// MARK: - 多帧确认

/// 圆角检测的多帧确认器
/// 连续 N 帧结果一致才采纳，避免动态画面造成瞬时误判
final class ScreenCornerConfirmer {
    /// 需要的连续一致帧数
    private let requiredCount: Int
    /// 半径容差（像素）。两次检测差值在该范围内视为一致
    private let tolerance: CGFloat

    /// 上一次的结果
    private var lastResult: ScreenCornerResult?
    /// 连续一致的次数
    private var matchCount = 0
    /// 已确认的结果
    private(set) var confirmedResult: ScreenCornerResult?

    init(requiredCount: Int = 3, tolerance: CGFloat = 3.0) {
        self.requiredCount = requiredCount
        self.tolerance = tolerance
    }

    /// 提交一次检测结果
    /// - Returns: 本次是否达成新的确认
    @discardableResult
    func submit(_ result: ScreenCornerResult?) -> Bool {
        guard let result else {
            // 检测失败：重置连续计数，但保留已确认结果
            matchCount = 0
            lastResult = nil
            return false
        }

        if let last = lastResult, abs(last.radiusInPixels - result.radiusInPixels) <= tolerance {
            matchCount += 1
            lastResult = result
        } else {
            matchCount = 1
            lastResult = result
        }

        guard matchCount >= requiredCount else { return false }

        // 已确认过且半径未变化，无需重复通知
        if let confirmed = confirmedResult,
           abs(confirmed.radiusInPixels - result.radiusInPixels) <= tolerance {
            return false
        }

        confirmedResult = result
        return true
    }

    /// 重置状态（分辨率变化时调用）
    func reset() {
        lastResult = nil
        matchCount = 0
        confirmedResult = nil
    }
}
