import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 菜单栏面板**整块**的排版契约（设计稿 `02-menu-bar.html` / `07-dark.html`）。
///
/// ## 为什么要有这一层
///
/// 2026-09-15 用户报告「菜单栏 popover 完全不是设计稿的样子」。走查时手里只有
/// 「设计稿 350 / 实现 283」两个数，**差 67pt** 看起来像排版塌了。实际逐块核算后：
///
/// | | 设计稿 | 实现 | 差 |
/// |---|---|---|---|
/// | 头部 | 50 | 50 | 0 |
/// | 磁盘区（2 块盘） | 145 | 145.5 | +0.5 |
/// | 分隔线 | 17 | 17 | 0 |
/// | 动作区（4 行） | 136 | 136 | 0 |
/// | 外框边框 | 2 | 0 | −2 |
/// | **合计** | **350** | **348.5** | **−1.5** |
///
/// 那 67pt 里 **69 是「设计稿截图里有两块盘、实现快照里只有一块」**，
/// 剩下的是 1pt 取整。换句话说：**总高对不上不是排版错，是拿两个不同内容量的画面在比**。
///
/// 这个教训值得固化成断言：**永远断言「每多一块盘就高 69」这个增量**，
/// 而不是只比一个总数 —— 总数会随内容量变化，增量才是排版规则本身。
///
/// ## 与设计稿的 1.5pt 系统性偏差（已知且接受）
///
/// 设计稿 `.win` 是 `border: 0.5px solid`，Chrome 在 1x 下把它渲染成 **1px**，
/// 于是 `getBoundingClientRect` 的 350 **含左右… 上下各 1px 的边框**。
/// 实现把这条边画成 `strokeBorder` **overlay**（不占布局高度），
/// 且宽度是真正的 0.5pt（2x 屏 = 1 物理像素，比 Chrome 的 1px 更准）。
/// 所以实现的**内容高度** 348.5 才是与设计稿的 348 可比的量。
///
/// 逐块看还差 0.5pt：菜单磁盘行实测 68.75（设计 69）。
/// 来源是 SwiftUI 自然行高与 CSS `line-height` 在小数位上的取整差，
/// 每行 0.25pt（2x 屏上 0.5 物理像素），**不为它扭曲行高**。
@MainActor
struct MenuPopoverLayoutTests {

    // MARK: - 夹具

    private func disk(_ n: Int) -> DiskInfo {
        DiskInfo(
            id: "/Volumes/D\(n)",
            bsdName: "disk\(n)s2",
            volumeName: "Disk \(n)",
            mountPath: "/Volumes/D\(n)",
            totalBytes: 1_000_000_000_000,
            usedBytes: 300_000_000_000,
            freeBytes: 700_000_000_000,
            deviceProtocol: "USB",
            deviceModel: "SanDisk Extreme 55AE"
        )
    }

    /// 造一个面板：磁盘列表与占用结论都是注入的替身，**完全不碰真机磁盘**。
    ///
    /// `DiskListStore(monitoring: false)` 不挂系统监听，`OccupancyStore(autoStart: false)`
    /// 不起轮询也不跑 `lsof` —— 否则测试会随测试机上真实插着的盘随机变红。
    private func popover(disks: [DiskInfo]) -> some View {
        let store = DiskListStore(monitoring: false)
        store.replaceDisksForTesting(disks)
        let occupancy = OccupancyStore(diskStore: store, autoStart: false)
        return MenuPopoverView(
            store: store,
            occupancyStore: occupancy,
            accent: .default,
            onOpenMainWindow: {},
            onRefresh: {},
            onOpenSettings: {},
            onQuit: {},
            onEject: { _ in }
        )
    }

    /// 走 SwiftUI 真实布局量高。
    ///
    /// ⚠️ `height` 传 `.greatestFiniteMagnitude` 是刻意的（只约束宽度、高度不限）——
    /// 但也正因为这个值会一路传进 AppKit，`MenuPopoverView` 的背景**必须**是
    /// `.background(GlassSurface(...))` 而不是 `ZStack` 里的一层：
    /// `GlassSurface` 内含 `NSViewRepresentable`，被无限量测时会把 1.79e308
    /// 送进 `NSLayoutConstraint` 并抛异常打死进程（signal 5）。
    /// 这条约束由 `GlassSurfaceTests` 与本测试共同守护 —— 谁把它挪进 `ZStack`，这里就崩。
    private func size(
        _ view: some View, width: CGFloat = DesignTokens.Size.menuPopoverWidth
    )
        -> CGSize
    {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        return hosting.sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    // MARK: - 宽度

    /// 面板渲染出来**恰好等于实现常量**（`DesignTokens.Size.menuPopoverWidth`）。
    ///
    /// 不是「约等于」：`NSPopover` 会按内容的 fitting size 定宽，
    /// 任何一处多了 1pt 内边距都会让它变成 361。
    ///
    /// ⚠️ 这里**故意不写 360**：360 的出处是设计稿 `ds.css` 的 `--w-popover`，
    /// 写死字面量就成了「拿常量跟自己比」（§8.51 明令禁止）——
    /// 设计稿改成 380 而实现没跟时，这条**照样绿**。
    /// 那一头由 `DesignSizeParityTests.设计稿与实现的尺寸必须同数()` 钉住；
    /// 这一条只守「排版没把宽度顶宽」。
    @Test func 面板渲染宽度等于实现常量() {
        let s = size(popover(disks: [disk(1)]))
        let expected = DesignTokens.Size.menuPopoverWidth
        #expect(
            s.width == expected,
            "面板宽 \(s.width)pt，实现常量是 \(expected)pt —— 多出来的多半是某处内边距")
    }

    // MARK: - 增量（与内容量无关，是排版规则本身）

    /// **每多一块盘，面板就高 69pt** —— 设计稿实测的 `.mrow` 高度。
    ///
    /// 断言增量而不是总数：总数随「插了几块盘」变化，
    /// 而 69 是「行怎么排」的规则。曾经只比总数，于是把
    /// 「设计稿 2 块盘 350 / 实现 1 块盘 283」读成了「差 67pt 的排版错误」。
    @Test func 每多一块盘面板就高一个行高() {
        let h1 = size(popover(disks: [disk(1)])).height
        let h2 = size(popover(disks: [disk(1), disk(2)])).height
        let h3 = size(popover(disks: [disk(1), disk(2), disk(3)])).height

        let expected = DesignTokens.Size.menuRowHeight
        #expect(
            abs((h2 - h1) - expected) <= 0.5,
            "1→2 块盘的增量是 \(h2 - h1)pt，设计稿行高 \(expected)pt"
        )
        #expect(
            abs((h3 - h2) - expected) <= 0.5,
            "2→3 块盘的增量是 \(h3 - h2)pt，设计稿行高 \(expected)pt"
        )
    }

    // MARK: - 总高（对着设计稿的实测值）

    /// 两块盘时面板总高 **350**（设计稿 `02-menu-bar.html` 第一个变体）。
    ///
    /// 容差 2pt 覆盖两处已知偏差：外框边框的实现方式（设计 1px 占布局 / 实现 0.5pt overlay）
    /// 与每行 0.25pt 的行高取整。见类型文档的对照表。
    @Test func 两块盘的面板总高与设计稿一致() {
        let h = size(popover(disks: [disk(1), disk(2)])).height
        #expect(abs(h - 350) <= 2, "两块盘时面板高 \(h)pt，设计稿实测 350pt，差 \(h - 350)pt")
    }

    /// 空状态面板总高 **354**（设计稿 `02-menu-bar.html` 第二个变体）。
    ///
    /// 空状态**比两块盘还高 4pt**：设计稿把 `.pop__body` 的内边距从 `0 8 8`
    /// 覆盖成 `8 12 16`，大图标 56 又比磁盘行的 32 高。容差放到 3pt，
    /// 因为这一屏的说明文字限宽 250 后行数随语言变化（中文 2 行 / 英文可能 2 行），
    /// 是整个面板里唯一「高度依赖语言」的地方。
    @Test func 空状态面板总高与设计稿一致() {
        let h = size(popover(disks: [])).height
        #expect(abs(h - 354) <= 3, "空状态面板高 \(h)pt，设计稿实测 354pt，差 \(h - 354)pt")
    }

    /// 面板里**只有一条分隔线**（设计稿动作区与磁盘区之间一个 `.pop__sep`）。
    ///
    /// 回归：实现曾在动作区内部「退出」之前多插一条 `Hairline`，
    /// 面板因此多出「一条线 + 4pt 留白」。分隔线数量从高度上是看不出来的
    /// （它只差 1pt），但视觉上「动作区被切成两组」是明显的。
    ///
    /// 判据用高度差：一条 `Hairline` 是 1pt 布局高，但设计稿的 `.pop__sep`
    /// 是 `height: 0.5px` 的 **inset box-shadow 等价物**，上下各 8pt 外边距 = 17pt。
    /// 这里断言「面板总高 − 各块之和」恰好等于一条分隔线的占位。
    @Test func 面板里只有一条分隔线() {
        let h2 = size(popover(disks: [disk(1), disk(2)])).height
        let header: CGFloat = 50
        let diskArea = 2 * DesignTokens.Size.menuRowHeight + DesignTokens.Spacing.sm
        let actions =
            4 * DesignTokens.Size.menuActionRowHeight + DesignTokens.Spacing.sm
        let separator = DesignTokens.Spacing.sm * 2 + 1
        let expected = header + diskArea + separator + actions

        #expect(
            abs(h2 - expected) <= 2,
            """
            面板总高 \(h2)pt，按「头部 \(header) + 磁盘区 \(diskArea) + 分隔线 \(separator) \
            + 动作区 \(actions)」应为 \(expected)pt —— 多出来的部分很可能是多画了一条线
            """
        )
    }

    // MARK: - 动作行

    /// 动作行高**恰好 32**（设计稿实测 32.0000，四位小数）。
    ///
    /// 这条容差只有 0.1 而不是 2，因为它曾经真的错过：
    /// 实现按设计稿的 `line-height: 1.45` 排 → `7 + 18.85 + 7 = 32.85`，
    /// 四行累计多 3.4pt。而设计稿的 `.actionrow` 是 `<button>`，
    /// 浏览器 UA 的 `line-height: normal` **覆盖**了继承来的 1.45，
    /// 真实行盒是 18（实测 `computed.lineHeight = normal`）。
    /// 现在实现直接钉住 32（见 `MenuActionRow`），所以这里可以要求严格相等。
    @Test func 动作行高恰好三十二() {
        let h = size(
            MenuActionRow(systemName: "macwindow", label: "打开主窗口", shortcut: "⌘O", action: {})
        ).height
        #expect(abs(h - 32) <= 0.1, "动作行高 \(h)pt，设计稿实测 32.0000pt")
    }

    /// 四个动作行的标签都**不许折行** —— 行高固定后折行会顶出圆角边框。
    ///
    /// 判据：把行放在比面板窄的宽度里（模拟某种语言的长文案），
    /// 行高必须仍然是 32。曾经靠 `designLineHeight` 的 padding 撑着，
    /// 一旦文案折行，行高会悄悄变成 50 而没有任何断言变红。
    @Test func 动作行文案再长也不折行() {
        let long = "这是一个刻意写得很长很长的动作行文案用来试探折行行为是否被兜住"
        let h = size(
            MenuActionRow(systemName: "gear", label: long, shortcut: "⌘,", action: {}),
            width: 200
        ).height
        #expect(abs(h - 32) <= 0.1, "长文案把动作行撑到了 \(h)pt —— 折行会顶出圆角边框")
    }

    /// **退出行不染红** —— 红色只表示「破坏性」（设计稿 §2.1 硬规则），
    /// 而「退出应用」不丢数据、不是破坏性动作。
    ///
    /// ## 这条断言是怎么来的
    ///
    /// 2026-09-16 的设计走查里，`cmp-popover.png` 显示实现那一侧「退出」是红的、
    /// 设计稿那一侧是灰的。查下去发现是**实现过度设计**：设计稿实测四行同色，
    /// `ds.css` 里 `.actionrow--danger` 只有 `:hover` 一条。四条证据见
    /// ``MenuPopoverAction/isDestructive`` 的文档。实现已改回中性色，这条断言把它钉住。
    ///
    /// ## 判据
    ///
    /// 「有没有被染红」只能看渲染结果 —— SwiftUI 的 `Text` 在 AppKit 视图树里
    /// **没有对应视图**。用 ``OffscreenRender/redPixels(_:size:in:above:appearance:background:)``
    /// 数「红色占优」的像素（实测标定：`#FF3B30` 是 196、红白抗锯齿边是 98、
    /// 灰字 `#1D1D1F` 是 −2、纯白是 0；阈值取 60）。
    ///
    /// ⚠️ **必须带对照组**：`0 命中` 有两种含义 —— 真的没有红色，或**判据本身坏了**，
    /// 两者长得一模一样。所以先渲染一段**已知是红的**文字，确认判据看得见红，
    /// 再去断言退出行是 0。本仓库已经在这上面栽过两次。
    @Test func 退出行不染红() {
        let box = CGSize(width: 360, height: 32)
        let whole = CGRect(origin: .zero, size: box)

        // 对照组：拿 Palette.error 画一段同样的文字 —— 判据必须看得见它。
        let control = Text("退出磁盘推出助手")
            .font(.system(size: DesignTokens.FontSize.body))
            .foregroundStyle(DesignTokens.Palette.error)
        let controlRed = OffscreenRender.redPixels(control, size: box, in: whole)

        // 被测：真实的破坏性动作行。`isDestructive` 仍为真 —— 它只驱动 hover 底色。
        let row = MenuActionRow(
            systemName: "power", label: "退出磁盘推出助手", shortcut: "⌘Q",
            action: {}, isDestructive: true)
        let rowRed = OffscreenRender.redPixels(row, size: box, in: whole)

        print("  [退出行不染红] 对照组红 \(controlRed)；退出行红 \(rowRed)")
        #expect(
            controlRed >= 50,
            "对照组只有 \(controlRed) 个红像素 —— 判据没通，下面那条 0 不算数")
        #expect(
            rowRed == 0,
            "退出行有 \(rowRed) 个红像素 —— 红色只留给「关闭并推出」与失败弹窗")
    }
}
