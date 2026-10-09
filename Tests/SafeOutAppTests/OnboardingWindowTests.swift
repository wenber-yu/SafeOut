import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 引导面板**窗口层面**的契约。
///
/// **为什么单开一个文件、与 `OnboardingLayoutTests` 分开**：那边量的是「视图要多大」，
/// 这边量的是「窗口给了多大、以及窗口有没有偷偷改动内容的排版」。
/// 两者可以**同时正确又同时出错** —— 这正是本文件存在的理由。
///
/// ## 它抓到过一个真缺陷（2026-09-15）
///
/// 面板上屏后量到的是 **380×532**，而设计稿是 380×503、离屏出图也是 500。
/// 根因：`.fullSizeContentView` 的窗口会向 SwiftUI 报出「顶部 32pt 被标题栏占了」的安全区，
/// SwiftUI 于是把内容**整体下推 32pt** —— 设计稿的 24pt 上内边距变成 56pt，
/// 窗口也被撑高 32pt。
///
/// **这个缺陷对当时所有已有的断言都是隐形的**：
/// - `OnboardingLayoutTests` 只量视图，视图没有窗口 → 没有安全区 → 量出 500，全绿；
/// - 真机自检里那条「窗口高 == 视图量出来的高」也是绿的 —— 因为**两边都含安全区**
///   （`sizeThatFits` 跟着一起加 32pt，实测 532 vs 531.95）。
///
/// 所以本文件里抓它的是 **`挂到窗口上之后量高不变`**（差 31.5pt）与
/// **`窗口尺寸贴合视图`**（窗口 501 装不下 531.95 的内容），不是 `窗口高与设计稿相差不超过4`。
///
/// ## 同一个断言，在两个环境里力度不同（实测结论，别想当然）
///
/// `窗口高与设计稿相差不超过4` 在**真机自检**里抓到了它（窗口 532），
/// 在**本文件（离屏单测）**里却**抓不到** —— 撤掉修复跑一遍，它照样是绿的。
///
/// 原因是建窗用的那次量高发生在 `contentViewController` 赋值**之前**：
/// 那时宿主控制器还没进窗口，离屏环境根本不报安全区，量出 499.95 → frame 501。
/// 而窗口真的上屏时，量高从一开始就带着安全区（531.95）→ frame 532。
///
/// 结论：**「窗口高 == 视图量高」是必要条件，不是充分条件**；
/// 而「设计稿高」这条虽然更本质，却只在真机上才有牙。
/// 两条都要有，且不能拿一条的绿去替另一条背书。
///
/// ## 顺带钉住的 AppKit 行为
///
/// 给窗口赋 `contentViewController` 会把窗口 frame **清成 0×0**，而且 `layoutIfNeeded()`
/// 之后仍是 0（见 `挂上控制器后必须重新定尺寸`）。所以 `makeOnboardingPanel` 里
/// `setContentSize` 那一句**不是冗余** —— 少了它，面板是一个 0 高的空窗口。
@MainActor
struct OnboardingWindowTests {

    private let width = DesignTokens.Size.onboardingPanelWidth

    private func makeView() -> OnboardingView {
        OnboardingView(accent: .default, onOpenSettings: {}, onLater: {})
    }

    /// ⚠️ **都钉在中文下**：本文件的 503.3 / 380 来自**中文实测**的设计稿。
    ///
    /// 与 `AlertLayoutTests` 同理，`makePanel()` 得连**建窗**一起钉 ——
    /// `AppDelegate.makeOnboardingPanel` 会在构造时用 `sizeThatFits` 定 `contentSize`，
    /// 那一刻就会解析文案。钉晚了只是把已经成型的文本排版一遍。
    /// 不钉 → 英文机器上窗口高会变成 560pt（2026-09-17 CI 实测差 56.7pt）。
    /// 英文的实际表现由 `LanguageLayoutGapTests` 记录。
    private func makeHosting() -> NSHostingController<OnboardingView> {
        TestLanguage.with(TestLanguage.design) {
            let hosting = NSHostingController(rootView: makeView())
            if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
            return hosting
        }
    }

    /// 只建窗，**不上屏** —— 单测不抢用户焦点（与 `AlertLayoutTests` 对弹窗窗口的处理一致）。
    private func makePanel() -> (window: NSWindow, hosting: NSHostingController<OnboardingView>) {
        TestLanguage.with(TestLanguage.design) {
            _ = NSApplication.shared
            return AppDelegate.makeOnboardingPanel(root: makeView())
        }
    }

    private func measuredHeight(of hosting: NSHostingController<OnboardingView>) -> CGFloat {
        TestLanguage.with(TestLanguage.design) {
            // 先布局一次再量：宿主视图还没按「宽 380」排过版时，量出来会有约 0.5pt 的抖动
            // （实测 500.45 vs 499.95）—— 断言里那点容差就是留给它的。
            hosting.view.layoutSubtreeIfNeeded()
            return hosting.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
        }
    }

    // MARK: - 尺寸

    /// 窗口高 ≈ **498.45**（v3 起的中文实测；口径与
    /// `OnboardingLayoutTests.面板总高与设计稿相差不超过4` 一致 —— 按钮组交还系统样式后
    /// 由 503.3 降下来的，别「改回去」）。
    ///
    /// ⚠️ **这条在本文件里抓不到安全区那个缺陷**（撤掉修复跑一遍照样绿，原因见文件头）。
    /// 它有牙的地方是**真机自检** `--preview-onboarding-keys`（那里窗口真的上屏，量到 532）。
    /// 留在这里是因为它钉的是另一件独立的事：**窗口高不该由内容之外的东西决定**。
    @Test func 窗口高与设计稿相差不超过4() {
        let (window, _) = makePanel()
        #expect(
            abs(window.frame.height - 498.45) <= 4,
            "窗口高 \(window.frame.height)，基准 498.45 —— 差得远通常意味着标题栏安全区把窗口撑高了")
    }

    @Test func 窗口宽为设计稿的380() {
        let (window, _) = makePanel()
        #expect(window.frame.width == width)
    }

    /// **安全区回归测试**：同一个视图，挂在窗口上量出来的高必须与离屏量出来的一致。
    ///
    /// 这条是「内容有没有被下推」的**充分条件**：`NSHostingController.sizeThatFits(in:)`
    /// 会把容器安全区加进去，所以只要窗口报了安全区，这里就会多出 32pt
    /// （实测未修时 531.95 vs 499.95）。
    ///
    /// **不能直接断言 `hosting.view.safeAreaInsets`**：即使把 `safeAreaRegions` 关掉，
    /// AppKit 那一层仍照报 `top: 32`（它描述的是窗口本身），变的只是「SwiftUI 认不认」。
    /// 所以只能断言**后果**，不能断言那个数值。
    @Test func 挂到窗口上之后量高不变() {
        _ = NSApplication.shared
        let offscreen = measuredHeight(of: makeHosting())
        let (_, hosting) = makePanel()
        let inWindow = measuredHeight(of: hosting)

        #expect(
            abs(inWindow - offscreen) <= 0.5,
            "离屏量 \(offscreen)、挂到窗口上量 \(inWindow) —— 差了 \(inWindow - offscreen)pt，说明窗口的标题栏安全区被算进了内容排版（`safeAreaRegions` 没关掉）"
        )
    }

    /// 窗口尺寸贴合视图：容得下，且不多出空白。
    ///
    /// 容差 1.5 的来历：AppKit 会把内容尺寸**向上取整到整点**
    /// （实测 `sizeThatFits` 500.45 → frame 501、499.95 → frame 500），
    /// 再叠加量高本身约 0.5pt 的抖动。这点差是取整，不是布局问题 ——
    /// 而它要防的「安全区把窗口撑高 32pt」是另一个量级，1.5pt 容差照样拦得住。
    @Test func 窗口尺寸贴合视图() {
        let (window, hosting) = makePanel()
        let measured = measuredHeight(of: hosting)
        #expect(window.frame.height >= measured - 0.5, "窗口 \(window.frame.height) 装不下视图 \(measured)")
        #expect(window.frame.height <= measured + 1.5, "窗口 \(window.frame.height) 比视图 \(measured) 多出一截空白")
    }

    /// **钉住那句 `setContentSize` 不是冗余**：给窗口赋 `contentViewController`
    /// 会把 frame 清成 0×0，而且 `layoutIfNeeded()` 之后仍是 0 —— 少了随后的 `setContentSize`，
    /// 面板就是一个 0 高的空窗口（不报错、不崩溃，只是什么都没有）。
    ///
    /// 这个对照实验是必要的：单看 `makeOnboardingPanel` 里
    /// 「`contentRect` 已经传了高度、随后又 `setContentSize` 同一个值」很像是冗余代码，
    /// 很容易被后来者「顺手删掉」。
    @Test func 挂上控制器后必须重新定尺寸() {
        _ = NSApplication.shared
        let hosting = makeHosting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        #expect(window.frame.height == 500)

        window.contentViewController = hosting
        #expect(window.frame.height == 0, "赋控制器之后窗口不再归零 —— 那么 `setContentSize` 那句确实可以删，请更新这条断言与注释")
        window.layoutIfNeeded()
        #expect(window.frame.height == 0)

        window.setContentSize(NSSize(width: width, height: 500))
        #expect(window.frame.height == 500, "setContentSize 没把窗口恢复回来")
    }

    // MARK: - 配置

    /// 无标题栏浮层该有的配置。每一条去掉都会**静默**劣化（不会让别的断言变红）。
    @Test func 窗口配置符合无标题栏浮层() {
        let (window, hosting) = makePanel()

        #expect(window.styleMask.contains(.fullSizeContentView), "少了它内容不会铺满整窗，顶上多一条实心标题栏")
        #expect(window.styleMask.contains(.closable), "少了它面板只能靠「稍后」关，没有系统关闭入口")
        #expect(window.titlebarAppearsTransparent, "标题栏不透明会在面板顶上压一条底色")
        #expect(window.titleVisibility == .hidden, "标题文字会与居中的图标容器抢视觉重心")
        #expect(!window.isReleasedWhenClosed, "默认 true 会在关窗时释放窗口，复用 `onboardingWindow` 时是悬垂引用")
        #expect(window.canBecomeKey, "不能成为 key 的话回车/Esc/按钮点击全都失效")
        #expect(window.contentViewController === hosting)
        // 窗口标题保留（只是不绘制）：Mission Control、窗口菜单、辅助功能读到的仍是它。
        //
        // ⚠️ 期望值必须显式取**设计稿语言**的那一份：窗口是在 `makePanel()` 里、
        // 钉住中文的那个作用域内建的（`window.title` 因此恒为中文），
        // 而 `L10n.tr(.fdaOnboardingTitle)` 走 `Locale.current` ——
        // 两侧语言不同时这条会红，且**红的原因跟被测代码毫无关系**。
        #expect(window.title == TestLanguage.designText(.fdaOnboardingTitle))

        // **建窗不上屏**：单测跑到这里如果窗口可见，就是抢了用户的焦点。
        #expect(!window.isVisible)
    }
}
