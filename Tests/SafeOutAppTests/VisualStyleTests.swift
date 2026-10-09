import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 「视觉效果」（透明 / 色调）**真的会改变窗口底色** —— 2026-09-17 的回归测试。
///
/// ## 这条测试防的是哪一类 bug
///
/// 用户报「切换透明和色调没有任何变化」。根因不是渲染错了，而是**这个偏好只被写、
/// 从来没有被读**：`SettingsSectionPane` 用 `@AppStorage` 把它存进 UserDefaults，
/// 全仓库却没有任何一处读它来决定画什么 —— ``GlassSurface`` 一律画毛玻璃。
///
/// 一个只写不读的偏好，在 UI 上和「没做这个功能」**没有区别**，而且不会让任何
/// 别的测试变红：偏好写成功了、分段控件选中态也对了，单看每一处都是对的。
/// 所以必须有一条测试**从渲染结果**上确认「两个选项画出来的东西不一样」。
@Suite("视觉效果偏好真的生效")
struct VisualStyleTests {

    /// 渲染一块 ``GlassSurface`` 并返回中心像素。
    ///
    /// `UserDefaults` 是全局状态，测完必须还原 —— 否则本文件跑完会把
    /// 后面所有测试的窗口底色改成色调模式。
    @MainActor
    private func centerPixel(style: VisualStyle) -> NSColor? {
        let key = AppSettings.Key.visualStyle
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(style.rawValue, forKey: key)

        guard
            let rep = OffscreenRender.bitmap(
                GlassSurface(cornerRadius: 12),
                size: CGSize(width: 40, height: 40),
                background: .clear)
        else { return nil }
        return rep.colorAt(x: 20, y: 20)
    }

    /// **核心断言**：两个选项画出来的底色必须不一样。
    ///
    /// 判据用**整颗像素**（RGB + alpha）而不是只看 alpha：离屏渲染里
    /// `VisualEffectBackground` 那一层 `NSVisualEffectView` 可能画得出来也可能画不出来，
    /// 无论哪种情况，不透明的 `--bg-base` 与半透明的 `--bg-glass` 叠加结果都必然不同。
    @Test @MainActor func 两种风格画出来的底色不同() {
        guard let transparent = centerPixel(style: .transparent),
            let tinted = centerPixel(style: .tinted)
        else {
            Issue.record("离屏渲染失败 —— 不渲染就断言等于没测")
            return
        }
        #expect(
            !transparent.isEqual(tinted),
            "透明与色调渲染出的底色完全相同（\(transparent)）—— 说明「视觉效果」没被读，切换不会有变化")
    }

    /// 色调模式的底色必须是**不透明**的实体面（设计稿 `bg-base`）。
    ///
    /// 这条抓的是「接上了但接错成半透明」：那样桌面仍然透出来，用户看到的还是毛玻璃。
    @Test func 色调模式的底色不透明() {
        for scheme in [ColorScheme.light, .dark] {
            let base = NSColor(DesignTokens.Palette.windowBase(for: scheme))
            #expect(
                base.alphaComponent == 1,
                "色调模式的窗口底色必须完全不透明，\(scheme) 实得 alpha \(base.alphaComponent)")
        }
    }

    /// 对照组：透明模式的底色必须是半透明的，否则上一条「不透明」就没了分辨力。
    @Test func 透明模式的底色是半透明的() {
        for scheme in [ColorScheme.light, .dark] {
            let glass = NSColor(DesignTokens.Palette.windowGlass(for: scheme))
            #expect(
                glass.alphaComponent < 1,
                "透明模式的窗口底色必须半透明（桌面要透出来），\(scheme) 实得 alpha \(glass.alphaComponent)")
        }
    }
}
