import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 主窗口**窗口层面**的契约（v3：单侧栏 + 详情区）。
///
/// ## v3 起装配换成了 `NSSplitViewController`
///
/// v2 里 `contentView` 是一个 `NSHostingView<ContentView>`，窗口层面的三件事
/// （宿主安全区、固有尺寸、玻璃铺满）都围着它转。
/// v3 里 `contentViewController` 是 ``MainWindowContentController``（`NSSplitViewController`），
/// 玻璃挂在**它的 `view` 最底层**，两个窗格各自是 `NSHostingController`。
/// ⇒ 下面几条断言的对象整体换了，判据跟着重写（各条注释里写了「v2 是什么」）。
///
/// ## 它抓到过两个真缺陷（2026-09-15，用户报「主窗口的红绿灯工具栏成了纯透明」）
///
/// 顶部 32pt 露出桌面，是**两个独立缺陷叠加**的结果 —— 各自都能单独存在：
///
/// 1. **宿主把标题栏安全区算进了尺寸**：`.fullSizeContentView` 的窗口会向 SwiftUI 报出
///    「顶部这条被标题栏占着」，`NSHostingView` 的固有尺寸 = 内容 + 安全区，
///    而默认 `sizingOptions` 又把它回推给窗口 ⇒ 窗口在上屏那一刻被撑高。修法是一句
///    `safeAreaRegions = []`。
///    **v3 里这一句仍然必须有**：实测（`.build/probe/v3_assemble/`）详情区宿主不关时，
///    那条 52pt 头部带会量成 **104pt**、标题墨迹中心从 **25.8** 掉到 **77.8**。
/// 2. **玻璃只拿到内容那一块**：玻璃从 `ZStack` 改挂 `.background(...)` 之后，
///    「铺满整窗」变成了依赖「窗口高恰好等于内容高」这个巧合。
///
/// ## 为什么单测测得到，而离屏快照测不到
///
/// `SnapshotRenderTests` 渲染的视图**没有窗口**，于是既没有安全区、窗口也不会被回推撑高
/// —— 快照永远是「满窗玻璃、全绿」，对上面两条**结构性失明**。
///
/// ## v3 删掉的三条（不是漏了）
///
/// - `标题栏区域必须够高到放得下设计稿的灯`、
/// - `标题栏被拨回时必须自己补回来`、
/// - `resize之后观察者盯的还是同一个标题栏`
///
/// 三条都围着 ``AppDelegate/enlargeTitleBar(in:)`` / ``AppDelegate/watchTitleBarResets(in:)``
/// 转 —— 那两件事（把系统标题栏加高到 52pt、盯住它被拨回）在 v3 里**整个消失**：
/// 52pt 那条带子现在由 `NSToolbar` 提供（统一工具栏 + 全尺寸内容视图 ⇒ 系统自己就给了
/// 52pt，红绿灯也被系统居中到 26pt），没有「我们要加高、要补回来」这回事。
/// 判据仍在真机自检里：``WindowSelfCheck/checkTrafficLightBaseline`` 与
/// ``WindowSelfCheck/checkRedLightInkShape`` 每次量真实窗口。
@MainActor
struct MainWindowTests {

    private let expected = DesignTokens.Size.mainWindow

    /// 建主窗口，**不上屏**（单测不抢用户焦点，与 `AlertLayoutTests` / `OnboardingWindowTests` 一致）。
    ///
    /// 走 ``ViewFixtures/mainWindowHandle()`` —— 与真机**同一条装配路径**，只换数据来源。
    /// ⚠️ 不要裸调 `AppDelegate.makeMainWindow()`：那两个 store 是生产单例，会真的枚举本机磁盘。
    private func makeWindow() -> NSWindow {
        // 建窗口、建 hosting 都需要 `NSApplication.shared` 存在。
        _ = NSApplication.shared
        return ViewFixtures.mainWindowHandle()
    }

    /// 窗口的内容控制器 —— v3 起是 ``MainWindowContentController``。
    private func content(of window: NSWindow) -> MainWindowContentController? {
        window.contentViewController as? MainWindowContentController
    }

    /// 详情区那个 SwiftUI 宿主 —— 52pt 头部带与磁盘列表都住在它里面。
    ///
    /// 侧栏是第 0 项、详情区是第 1 项（与 ``MainWindowContentController/viewDidLoad()``
    /// 里 `addSplitViewItem` 的顺序一致）。
    private func detailHosting(of window: NSWindow) -> NSViewController? {
        guard let content = content(of: window), content.splitViewItems.count == 2 else { return nil }
        return content.splitViewItems[1].viewController
    }

    /// 玻璃覆盖范围：**我们自己画的那块**玻璃，统一到 `host` 坐标系。
    ///
    /// 判据不是看颜色（离屏取不到桌面），而是**问 AppKit 那块玻璃视图占多大**。
    /// 「自己画的」由 ``GlassBackdrop/isOurs`` 判定 —— 系统标题栏自带的必须排除，
    /// 否则「我们没铺满」会被它补上。
    private func glassCoverage(in host: NSView) -> CGRect {
        host.glassBackdrops
            .filter { $0.kind.isOurs }
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }
    }

    private func covers(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        outer.minX <= inner.minX + tolerance
            && outer.minY <= inner.minY + tolerance
            && outer.maxX >= inner.maxX - tolerance
            && outer.maxY >= inner.maxY - tolerance
    }

    // MARK: - 尺寸

    @Test func 窗口尺寸为设计稿() {
        let window = makeWindow()
        #expect(
            window.frame.width == expected.width,
            "窗口宽 \(window.frame.width)，设计稿 \(expected.width)")
        #expect(
            window.frame.height == expected.height,
            "窗口高 \(window.frame.height)，设计稿 \(expected.height)")
        #expect(!window.isVisible, "建窗不该上屏 —— 单测跑到这里窗口可见就是抢了用户焦点")
    }

    // MARK: - 玻璃

    /// **缺陷 2 的捕手（v3 版）**：玻璃必须铺满**整窗**。
    ///
    /// v2 用的是「给它一个比设计稿高 32pt 的宿主，看玻璃跟不跟得上」—— 那时玻璃挂在
    /// 一个 SwiftUI 视图里，铺满是靠外层 `frame(maxWidth/maxHeight: .infinity)` 争取来的，
    /// 所以要防它「只拿到内容那块」。
    ///
    /// v3 里玻璃直接挂在 ``MainWindowContentController`` 的 `view` 上、四边用约束贴死
    /// ⇒ **铺满由约束保证**（比尺寸巧合更强的结构保证）。
    /// 这条断言因此变成：玻璃在不在、以及它是不是真的铺满了那个 `view`。
    @Test func 玻璃必须铺满整窗() {
        let window = makeWindow()
        guard let content = content(of: window) else {
            Issue.record("主窗口的 contentViewController 不是 MainWindowContentController")
            return
        }
        content.view.layoutSubtreeIfNeeded()
        let glass = glassCoverage(in: content.view)
        #expect(
            !glass.isNull,
            "窗口视图树里没找到自定义玻璃（material=.underWindowBackground）—— 背景根本没铺上")
        #expect(
            covers(glass, content.view.bounds),
            "窗口 \(content.view.bounds) 里的玻璃只覆盖 \(glass) —— 没铺满，真机上这块会露出桌面")
    }

    // MARK: - 配置

    /// 主窗口该有的配置。每一条去掉都会**静默**劣化（不会让别的断言变红）。
    ///
    /// 这些配置**全部**在 ``AppDelegate/makeMainWindow()`` 里 —— 建窗时确定生效，可直接断言。
    @Test func 窗口配置符合主窗口() {
        let window = makeWindow()

        #expect(window.styleMask.contains(.titled), "少了它就没有红绿灯")
        #expect(
            window.styleMask.contains(.fullSizeContentView),
            "少了它内容不会铺满整窗，顶上多一条实心标题栏，玻璃也盖不住红绿灯那一带")
        #expect(window.titlebarAppearsTransparent, "标题栏不透明会在顶上压一条底色")
        #expect(
            window.titleVisibility == .hidden,
            "标题栏会画出应用名，与详情区头部那行标题重复")
        #expect(
            window.backgroundColor.alphaComponent == 0,
            "不清掉 windowBackgroundColor 的话，NSVisualEffectView 会被它盖住，桌面透不上来")
        #expect(!window.isOpaque, "不透明窗口看不到毛玻璃")
        #expect(window.isMovableByWindowBackground, "少了它拖窗口只能拖标题栏那一条窄带")
        #expect(window.defaultButtonCell == nil, "有默认按钮的话回车会触发它，而窗口里没有「默认动作」")
        #expect(
            !window.isReleasedWhenClosed,
            "默认 true 会在关窗时释放窗口，复用 `mainWindow` 时是悬垂引用")
        // v3：真正把尺寸钉死的是 `MainWindowContentController` 里那两条宽高约束
        // （见那个类的 `viewDidLoad()`），`minSize` 于是被 AppKit 抬成
        // 「内容 520 + 装饰 20 = **540**」。
        //
        // ⚠️ 这里**不写 `== 设计稿`**：540 是「约束生效」的旁证，把它钉成字面量等于
        // 把窗口装饰高度锁进测试，换个工具栏样式就红。这条断言的意图是防**静默改小**
        // （改小意味着窗口能被拉成非设计稿尺寸），所以断「不低于设计稿」。
        #expect(
            window.minSize.width >= expected.width && window.minSize.height >= expected.height,
            "最小尺寸被改小了 —— 窗口可以被拉成比设计稿更小的尺寸")
        // 内容尺寸才是「设计稿契约」本身，断它。
        #expect(
            window.contentView?.frame.size == expected,
            "内容视图 \(String(describing: window.contentView?.frame.size))，设计稿 \(expected)")
        // ⚠️ 别补一条 `contentMinSize == 设计稿`：实测它读到的也是 **540**
        // （`minSize` 与 `contentMinSize` 在这条路上同值，都带那 20pt 装饰）。
        // 内容真实尺寸由上面那条断言把关，这里再钉一个 540 只会把装饰高度锁进测试。
        // v3：内容不再是一个 `NSHostingView<ContentView>`，而是 split 控制器。
        #expect(
            content(of: window) != nil,
            "contentViewController 必须是 MainWindowContentController")
        // 标题字符串保留（只是不绘制）：Mission Control、窗口菜单、辅助功能读到的仍是它。
        #expect(window.title == L10n.tr(.appName))

        // **建窗不上屏**：单测跑到这里如果窗口可见，就是抢了用户的焦点。
        #expect(!window.isVisible)
    }

    /// **缺陷 1 的机制（v3 版）**：两个宿主**都必须**关掉安全区。
    ///
    /// v2 只问一个宿主（`NSHostingView<ContentView>`）。
    /// v3 有**三个** SwiftUI 宿主，而对安全区的要求**不一样**：
    ///
    /// | 宿主 | 要求 | 不关的后果（实测） |
    /// |---|---|---|
    /// | 详情区 | **必须关** | 52pt 头部带量成 **104pt**，标题墨迹中心 25.8 → **77.8** |
    /// | 整窗玻璃 | **必须关** | 玻璃自己缩进一条安全区，顶部露出窗口底 |
    /// | 侧栏 | **故意不关** | 那个顶部内缩正是「第一项落在红绿灯下方」的来源 |
    ///
    /// ⚠️ 最后一行**不是笔误**：侧栏若关了，第一项会顶到浮岛最上沿、与红绿灯叠在一起。
    /// 所以这条断言只查前两个。
    ///
    /// v2 那条「宿主不得把标题栏安全区算进尺寸」（量固有尺寸 ≤ 520）没有单独留下 ——
    /// 它测的是「安全区没关」的**后果**，而 v3 里窗口尺寸由 `contentRect` 定、不会被回推；
    /// 安全区关没关本身就是更直接的机制判据（就是这一条）。
    @Test func 两个宿主必须关掉安全区() {
        let window = makeWindow()
        guard #available(macOS 13.3, *) else { return }

        guard let detail = detailHosting(of: window) as? NSHostingController<MainDetailView> else {
            Issue.record("详情区不是 NSHostingController<MainDetailView> —— 装配结构变了")
            return
        }
        #expect(
            detail.safeAreaRegions == [],
            "详情区宿主没关安全区 —— 头部带会被推成两条高（52 → 104pt），标题掉到 78pt")

        guard let content = content(of: window),
            let backdrop = content.view.subviews
                .compactMap({ $0 as? NSHostingView<GlassSurface> }).first
        else {
            Issue.record("找不到整窗玻璃宿主 —— 装配结构变了")
            return
        }
        #expect(
            backdrop.safeAreaRegions == [],
            "整窗玻璃没关安全区 —— 玻璃自己会缩进一条，顶部露出窗口底")
    }

    // MARK: - 红灯墨迹判据（纯函数）

    /// **墨迹不是圆时必须报错** —— 喂合成样本，不需要真机。
    ///
    /// 为什么值得单独立一条：真机那条（``WindowSelfCheck/checkRedLightInkShape``）要窗口、
    /// 要前台、要系统把灯画成红色 —— **门槛里跑不了**。判据被切成「纯函数 + 量测」两半，
    /// 就是为了让**判据这半进得了门槛**：这里喂合成样本，把「什么形状算被裁」钉死。
    ///
    /// ⚠️ **三个方向都要有**（少一个就可能假绿）：
    /// ① 完整圆 ⇒ **不报**（否则「永远报错」也能绿）；
    /// ② 半圆 ⇒ 报，且要报**两条**（不是圆 + 中心上移）—— 这两条是同一根因的两个方向，
    ///    数量写死是为了让「只留一条」这种退化被抓出来；
    /// ③ `nil` ⇒ 不报（量测那半已经写过原因，再报一条会把一件事说成两件）。
    @Test func 红灯墨迹不是圆时必须报错() {
        let anchor = DesignTokens.Size.titleBarBandHeight / 2
        // v3：`titleBarInsetCenter` 令牌已删（红绿灯的水平位置归 AppKit，且我们不再对齐它）。
        // 这里喂的是**合成样本**，`centerX` 只需要是一个合法的中心位置 ——
        // 与 `anchor` 同源即可，判据本身与这个数无关。
        let inset = anchor

        // ① 完整圆：12pt 的圆在 2x 下量到 12×12pt，中心正好在内容带中心。
        var ok: [String] = []
        WindowSelfCheck.checkRedLightInkShape(
            ink: .init(centerX: inset, centerYFromTop: anchor, width: 12, height: 12, count: 452),
            label: "T", mismatches: &ok)
        #expect(ok.isEmpty, "完整的圆不该报错，实得：\(ok)")

        // ② 被裁：真机实测的形态 —— 24×16px ⇒ 12×8pt，中心因下缘被裁而上移。
        var bad: [String] = []
        WindowSelfCheck.checkRedLightInkShape(
            ink: .init(centerX: inset, centerYFromTop: anchor - 4, width: 12, height: 8, count: 320),
            label: "T", mismatches: &bad)
        #expect(
            bad.count == 2,
            "被裁掉下半部分应报 2 条（不是圆 + 中心上移），实得 \(bad.count) 条：\(bad)")
        #expect(
            bad.contains { $0.contains("不是圆的") },
            "报错信息必须指出「不是圆」—— 否则读的人会顺着中心偏移去查错方向。实得：\(bad)")

        // ③ 量不到时不重复报：原因已由 `measureRedLightInk` 写过。
        var none: [String] = []
        WindowSelfCheck.checkRedLightInkShape(ink: nil, label: "T", mismatches: &none)
        #expect(none.isEmpty, "ink 为 nil 时不该报错（原因由量测那半写），实得：\(none)")
    }

    // MARK: - 刷新转圈的项替换（2026-09-30 崩溃 07A1EC0D 的回归测试）

    /// 刷新转圈 = 工具栏上「系统按钮项 ↔ 进度圈项」**整项移除/插入**。
    ///
    /// 第一版实现是原地换 `item.view`，真机**必崩**：macOS 26 的
    /// `NSToolbarItemViewer configureForLayoutInDisplayMode:` 在布局期
    /// `-[__NSArrayM insertObject:atIndex:]` 抛 nil 插入异常（用户点刷新即闪退）。
    /// 本测试直接驱动替换实体（``MainWindowContentController/performSpinnerSwap(_:)``，
    /// 异步包装层泵不动——见该方法的注释），**每步强制布局**——旧实现在第一个
    /// `layoutIfNeeded` 就会以同样的 ObjC 异常炸掉测试进程，所以这条测试对
    /// 那一版是**必红**的（变异验证：换回 `item.view = …` 即死）。
    @Test func 刷新转圈按整项替换且布局不炸() {
        let window = makeWindow()
        guard let controller = content(of: window), let toolbar = window.toolbar else {
            Issue.record("主窗口必须有 MainWindowContentController 与 toolbar")
            return
        }
        // 初始项序：[flexibleSpace, refresh]。
        #expect(
            toolbar.items.last?.itemIdentifier == MainWindowContentController.refreshItemIdentifier,
            "初始尾端应是刷新按钮，实得 \(toolbar.items.map(\.itemIdentifier.rawValue))")

        // 完整走两轮「换出 → 换回」（对应用户连点两次刷新），每步都强制布局。
        for round in 1...2 {
            controller.performSpinnerSwap(true)
            window.layoutIfNeeded()  // ⚠️ 崩溃发生在布局期——这一步就是把雷踩实
            var ids = toolbar.items.map(\.itemIdentifier)
            #expect(
                ids.contains(MainWindowContentController.spinnerItemIdentifier),
                "第 \(round) 轮换出后必须有进度圈项，实得 \(ids.map(\.rawValue))")
            #expect(
                !ids.contains(MainWindowContentController.refreshItemIdentifier),
                "第 \(round) 轮换出后按钮项必须移除（禁重复点击靠它），实得 \(ids.map(\.rawValue))")
            #expect(
                toolbar.items.first?.itemIdentifier == .flexibleSpace,
                "第 \(round) 轮换出后 flexibleSpace 必须还在头部，实得 \(ids.map(\.rawValue))")

            controller.performSpinnerSwap(false)
            window.layoutIfNeeded()
            ids = toolbar.items.map(\.itemIdentifier)
            #expect(
                ids.last == MainWindowContentController.refreshItemIdentifier,
                "第 \(round) 轮换回后按钮必须在尾端原位，实得 \(ids.map(\.rawValue))")
            #expect(
                !ids.contains(MainWindowContentController.spinnerItemIdentifier),
                "第 \(round) 轮换回后圈项必须移除，实得 \(ids.map(\.rawValue))")
            #expect(
                toolbar.items.first?.itemIdentifier == .flexibleSpace,
                "第 \(round) 轮换回后 flexibleSpace 必须还在头部，实得 \(ids.map(\.rawValue))")
        }
    }
}
