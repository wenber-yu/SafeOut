import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// **已知缺陷的记录：固定高度容器只放得下中文。**
///
/// ## 这不是「测试写错了」，是产品缺陷
///
/// 引导面板设计稿总高 503.3；v3 起中文实测 498.45（按钮组交还系统样式变矮），英文下实测 **+56.7pt**。
/// 多出来的部分会被折叠线藏到滚动区外 —— 与「关于」分组曾整个看不见是同一个后果。
///
/// ## 这些测试为什么要「断言缺陷存在」
///
/// 它是一条**锁**：设计稿给出中英两套方案、容器随之变大之后，这些断言会**变红**，
/// 提醒你删掉本文件、改由 `OnboardingLayoutTests` 里那条 `<=` 断言接管。
/// **把缺陷钉住，比让它静默通过更有价值** ——
/// 静默通过意味着没人知道英文用户看到的是被截断的面板。
///
/// ## 2026-09-18：设置面板那两条已经「还清」了
///
/// 本文件原有三条。设置面板的两条（`英文下设置面板放不下_已知缺陷`、
/// `加宽到480后中英都放得下_方案依据`）在面板加宽到 480 + 加高到 800 之后
/// **如期变红** —— 正是它们自己写的要求（「修好后请删掉本文件，并让
/// `SettingsLayoutTests` 的 `<=` 断言直接覆盖英文」）。
/// 于是设置面板的部分**摘掉了**，英文覆盖并进 `SettingsLayoutTests`：
/// 从「记录缺陷」变成「必须通过的门槛」。
///
/// ⚠️ **文件没有整个删掉**：引导面板那条缺陷还活着。
/// 判断「这条锁该不该摘」的判据永远是「**它锁的那个缺陷修好了没有**」，
/// 不是「文件名听起来该退休了」。
///
/// ## 为什么不在 `SettingsLayoutTests` 里顺手写
///
/// 那个文件的断言钉的是「**中文排版与设计稿一致**」（设计稿数字按中文实测），
/// 它已经被 `TestLanguage.with(TestLanguage.design)` 钉在中文下。
/// 本文件钉的是相反的问题 —— 「**换成英文会怎样**」。两件事，分开写才不会互相稀释。
@MainActor
struct LanguageLayoutGapTests {

    /// 与各布局 suite 同口径：`sizeThatFits` 才是「给定宽度下的真实渲染尺寸」
    /// （`NSHostingView.fittingSize` 返回的是无宽度约束的理想尺寸）。
    private func renderedSize(_ view: some View, width: CGFloat) -> CGSize {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    @Test func 英文下引导面板更高_已知缺陷() {
        let width = DesignTokens.Size.onboardingPanelWidth
        // 设计稿总高 503.3；v3 按钮交还系统样式后中文实测 **498.45**（按钮组 30→28，见
        // OnboardingLayoutTests.面板总高与设计稿相差不超过4）。这里只比较中英差异，不重复断言绝对值。
        let zh = TestLanguage.with(TestLanguage.design) {
            renderedSize(
                OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}), width: width
            ).height
        }
        let en = TestLanguage.with("en") {
            renderedSize(
                OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}), width: width
            ).height
        }
        print("[layout-gap] 引导面板高度：zh-Hans=\(zh)pt，en=\(en)pt")

        #expect(en > zh, "英文文案更长，面板只会更高；若不然说明英文文案被改短了，请复核设计稿")
        #expect(
            abs(zh - 498.45) <= 4,
            "中文下应仍是 v3 实测基准的 498.45（实际 \(zh)）—— 这属于 OnboardingLayoutTests 的管辖"
        )
    }
}
