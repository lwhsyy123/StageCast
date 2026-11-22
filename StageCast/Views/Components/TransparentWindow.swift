//
//  TransparentWindow.swift
//  StageCast
//
//  Created by Sun on 2026/11/19.
//
//  透明窗口
//  避免系统在缩放期间绘制默认背景，消除画面外的白边闪烁
//

import AppKit

// MARK: - 透明窗口

/// 透明窗口
/// AppKit 在 resize 期间会临时绘制窗口背景，导致画面外出现白色闪烁。
/// NSWindow 本身没有 draw 可覆盖，实际绘制发生在 contentView，
/// 因此这里通过 isOpaque / backgroundColor 控制，配合 contentView 的透明背景生效。
final class TransparentWindow: NSWindow {
    /// 是否启用透明绘制（旧「透明背景」选项使用）
    var usesTransparentBackground = false {
        didSet {
            applyTransparency()
        }
    }

    /// 不透明状态下的窗口底色
    /// 任何残余缝隙都不会显示白边
    var opaqueBackgroundColor: NSColor = .windowBackgroundColor {
        didSet {
            applyTransparency()
        }
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingType, defer: flag)
        configureAnimationBehavior()
        applyTransparency()
    }

    // MARK: - 动画行为

    /// 关闭窗口 frame 变化的系统隐式动画
    /// 背景：AppKit 默认对 frame 变化套一层 CABasicAnimation（animation(forKey: "frame")），
    /// 在 fullSizeContentView + 自定义 resize 的组合下，插值出的目标 frame 的
    /// y / height 会解算成 NaN，动画每一帧都被下面的防御块丢弃，
    /// 表现为「窗口完全无法缩放」。实测把动画关掉后缩放恢复正常。
    private func configureAnimationBehavior() {
        animationBehavior = .none
    }

    // MARK: - 非有限几何防御

    /// 判断矩形是否包含非有限数值（NaN / ±inf）
    /// 背景：窗口动画（CABasicAnimation 重放）时曾出现目标 frame 的 height 为 NaN，
    /// 直接交给 AppKit 会在 _reallySetFrame 里抛
    /// Invalid parameter not satisfying: CGRectContainsRect(...) 导致 SIGABRT。
    /// 这里统一拦下非有限几何值，任何路径都不会再把窗口推到非法尺寸。
    static func hasNonFinite(_ rect: NSRect) -> Bool {
        !rect.origin.x.isFinite || !rect.origin.y.isFinite
            || !rect.size.width.isFinite || !rect.size.height.isFinite
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !Self.hasNonFinite(frameRect) else {
            AppLogger.rendering.error("忽略非有限窗口 frame: \(String(describing: frameRect))")
            return
        }
        super.setFrame(frameRect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        guard !Self.hasNonFinite(frameRect) else {
            AppLogger.rendering.error("忽略非有限窗口 frame(animate): \(String(describing: frameRect))")
            return
        }
        // 即使调用方要求动画也按无动画执行：动画插值会再次产生 NaN 目标 frame
        _ = animateFlag
        super.setFrame(frameRect, display: flag, animate: false)
    }

    override func setContentSize(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite else {
            AppLogger.rendering.error("忽略非有限窗口 contentSize: \(String(describing: size))")
            return
        }
        super.setContentSize(size)
    }

    /// 应用透明设置
    private func applyTransparency() {
        isOpaque = !usesTransparentBackground
        backgroundColor = usesTransparentBackground ? .clear : opaqueBackgroundColor
        // 关闭窗口阴影，避免透明时边缘出现一圈灰晕
        hasShadow = !usesTransparentBackground
    }
}
