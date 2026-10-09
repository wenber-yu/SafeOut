import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

// MARK: - 取色工具

/// 把 `Color` 解析成 sRGB 分量。
///
/// **为什么要显式指定外观**：`DesignTokens.Palette` 里的语义色是
/// `NSColor(name:dynamicProvider:)` 造的**动态色**，只在「绘制时」按当前外观解析。
/// 不套 `performAsCurrentDrawingAppearance` 拿到的是当前线程外观下的值 ——
/// 在测试进程里它取决于机器设置，会让断言随环境变红。
private func rgba(_ color: Color, dark: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(color).usingColorSpace(.sRGB)
    }
    guard let c = resolved else { return (-1, -1, -1, -1) }
    return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
}

private func hex255(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }

/// 离屏渲染一个视图，返回 2x 位图。
///
/// ⚠️ **必须走 `OffscreenRender`、且必须 `background: .clear`**（2026-09-23 收敛）：
/// 本文件原先自带第三份 `NSHostingController` + `NSBitmapImageRep(bitmapDataPlanes:)` 出图块。
/// 它要量的是「这块玻璃**自己**画没画底」，所以宿主**不能**垫背景 ——
/// `OffscreenRender.bitmap` 的 `background` 默认 `.white`，这里显式传 `.clear`
/// （`.background(.clear)` 不画任何东西，与原先「完全不叠背景」等价，见 `GlassSurfaceTests`
/// 的 alpha 断言）。
@MainActor
private func render(_ view: some View, size: CGSize, dark: Bool = false) -> NSBitmapImageRep? {
    OffscreenRender.bitmap(
        view, size: size, appearance: dark ? .darkAqua : .aqua, background: .clear)
}

/// 读 2x 位图上的一个点（传入的是 **pt** 坐标）。
private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
    let px = Int(x * 2)
    let py = Int(y * 2)
    guard let c = rep.colorAt(x: px, y: py) else { return (-1, -1, -1, -1) }
    let s = c.usingColorSpace(.sRGB) ?? c
    return (
        Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
        Int((s.blueComponent * 255).rounded()), Int((s.alphaComponent * 255).rounded())
    )
}

// MARK: - 测试

/// 这一组守的是用户 2026-09-15 报的另外三条：
/// 「菜单栏 popover 和主窗口的背景色也没有一致」、
/// 「亮/暗模式和设计稿不一样」、「主窗口和 popover 的细节也没有按照设计稿一致」。
///
/// 背景不一致的根因有三层，各自钉一条：
/// 1. 令牌值抄错（`--text-3` 深色、`--danger-text` 深色、`--bg-subtle-hi` 深色）；
/// 2. 主窗口只铺了系统材质、**没叠 `--bg-glass`**，于是显示为材质那层偏冷的灰；
/// 3. 菜单面板**根本没画背景**（靠 `NSPopover` 的 `.titlebar` 材质），
///    离屏渲染出来整块透明 —— 第 3 条由 `GlassSurface 会画出不透明的底` 兜住。
@Suite("窗口玻璃与设计令牌")
struct GlassSurfaceTests {

    // MARK: 令牌值（逐值对照 ds.css）

    @Test("--bg-glass 明暗两套与 ds.css 逐值一致")
    func bgGlass与设计稿一致() {
        let light = rgba(DesignTokens.Palette.windowGlass(for: .light), dark: false)
        #expect(hex255(light.r) == 255 && hex255(light.g) == 255 && hex255(light.b) == 255)
        #expect(abs(light.a - 0.72) < 0.005, "浅色 --bg-glass 是 rgba(255,255,255,.72)")

        let dark = rgba(DesignTokens.Palette.windowGlass(for: .dark), dark: true)
        #expect(hex255(dark.r) == 38 && hex255(dark.g) == 38 && hex255(dark.b) == 42)
        #expect(abs(dark.a - 0.74) < 0.005, "深色 --bg-glass 是 rgba(38,38,42,.74)")
    }

    /// 设计稿里主窗口与菜单面板是**同一条** `.win` 规则，底色必须同源。
    @Test("主窗口与菜单面板取的是同一个毛玻璃令牌")
    func 三块玻璃同源() {
        for scheme in [ColorScheme.light, .dark] {
            let main = rgba(DesignTokens.Palette.windowGlass(for: scheme), dark: scheme == .dark)
            let popover = rgba(DesignTokens.Palette.cardBackground(for: scheme), dark: scheme == .dark)
            #expect(main == popover, "主窗口与面板必须取同一个值，否则就是两块不同色温的玻璃")
        }
    }

    @Test("弹窗用的 --bg-glass-thick 比 --bg-glass 更不透明")
    func 弹窗玻璃更厚() {
        let glass = rgba(DesignTokens.Palette.windowGlass(for: .light), dark: false)
        let thick = rgba(DesignTokens.Palette.popoverBackground(for: .light), dark: false)
        #expect(abs(thick.a - 0.86) < 0.005)
        #expect(thick.a > glass.a, "弹窗浮在窗口之上，需要更强的遮挡")
    }

    @Test("--text-3 是全设计稿唯一明暗透明度不同的一档（.38 / .36）")
    func textDecorative明暗分档() {
        let light = rgba(DesignTokens.Palette.textDecorative, dark: false)
        let dark = rgba(DesignTokens.Palette.textDecorative, dark: true)
        #expect(abs(light.a - 0.38) < 0.005, "浅色 --text-3 是 rgba(60,60,67,.38)")
        #expect(abs(dark.a - 0.36) < 0.005, "深色 --text-3 是 rgba(235,235,245,.36)")
        #expect(hex255(dark.r) == 235 && hex255(dark.g) == 235 && hex255(dark.b) == 245)
    }

    // ⚠️ v3 退役：`--bg-subtle-hi 明暗两套都是 .14`（2026-09-30）——
    // 它钉的 `Palette.subtleHighlight` 只被自绘按钮的 hover 底用，
    // 交还系统样式后令牌已删（`DesignTokens` 里有退役说明）。

    @Test("--danger-text 深色是 #ff8078")
    func dangerText深色值() {
        let dark = rgba(DesignTokens.Palette.errorText, dark: true)
        #expect(
            hex255(dark.r) == 0xFF && hex255(dark.g) == 0x80 && hex255(dark.b) == 0x78,
            "设计稿 --danger-text 深色 #ff8078；曾经写 #ff6961")
    }

    @Test("--ok-text 深色是 #5cdb7c")
    func okText深色值() {
        let dark = rgba(DesignTokens.Palette.successText, dark: true)
        #expect(hex255(dark.r) == 0x5C && hex255(dark.g) == 0xDB && hex255(dark.b) == 0x7C)
    }

    // MARK: 几何令牌

    @Test("窗口圆角不自绘 —— 归窗口服务器")
    func 窗口圆角归系统() {
        // v3：这里原先断言 `Radius.window == 12` 与 `Radius.settings == Radius.window`。
        // 那两个令牌**已随 v3 删除** —— 窗口圆角归窗口服务器，而它既不是常数
        // （同机实测 31.5pt / 17.5pt 两档，只差窗口配置）也读不到
        // （`NSThemeFrame.layer.cornerRadius` 恒 0，HANDOFF §3.7.1 + 红线 R6）。
        // 自绘一个 12pt 只会在四角切出比窗口更小的圆、把窗口底露出来。
        //
        // 留下的是**仍然有效的那一档**：菜单面板 / 弹窗 / 引导面板的圆角。
        #expect(DesignTokens.Radius.lg == 14, "面板是 --r-lg")
    }

    @Test("菜单栏磁盘行图标容器是 32 / 圆角 6 / 图标 17")
    func 菜单栏图标容器规格() {
        #expect(DesignTokens.Size.menuIconContainer == 32)
        #expect(
            DesignTokens.Size.menuIconRadius == 6,
            "设计稿 .mrow__icon 是 --r-sm=6；沿用主窗口的 10 会让 32pt 方块四角明显变胖")
        #expect(DesignTokens.Size.menuIconSize == 17, "设计稿 .mrow__icon svg { width: 17px }")
        #expect(
            DesignTokens.Size.menuIconRadius != DesignTokens.Radius.md,
            "主窗口 .diskicon 才是 --r-md=10，两者是两条独立规则，不能共用")
    }

    @Test("面板头部应用图标 13、行内推出按钮图标 14")
    func 面板图标尺寸() {
        #expect(DesignTokens.Size.popoverAppIconSize == 13, "设计稿 .pop__appicon svg { width: 13px }")
        #expect(DesignTokens.Size.menuEjectIconSize == 14, "设计稿 .mbtn svg { width: 14px }")
    }

    @Test("外框描边 0.5pt")
    func 外框描边宽度() {
        #expect(DesignTokens.Size.glassBorderWidth == 0.5, "设计稿 .win { border: 0.5px solid var(--border-strong) }")
    }

    // MARK: 玻璃层真的画出来了

    /// **回归守卫**：菜单面板原先没有背景层，离屏渲染出来整块 alpha = 0。
    ///
    /// 这条断言之所以有价值，是因为「漏画背景」在**离屏**是看不出来的 ——
    /// 真机上 `NSPopover` 会补一层 `.titlebar` 材质，截图里似乎有背景；
    /// 只有离屏渲染才会暴露「这个视图自己什么都没画」。
    @Test("GlassSurface 会画出不透明的底（浅色）")
    @MainActor
    func glassSurface浅色不透明() throws {
        let size = CGSize(width: 120, height: 80)
        let rep = try #require(render(GlassSurface(cornerRadius: 12), size: size))
        let center = pixel(rep, x: 60, y: 40)
        #expect(center.a == 255, "玻璃底必须是不透明的；alpha=0 说明这个视图根本没画背景")
        #expect(center.r >= 245, "浅色下应当叠上 --bg-glass（白 .72），比裸材质更亮；实测 \(center)")
        #expect(center.r == center.g && center.g == center.b, "浅色玻璃是中性白，不该偏色")
    }

    @Test("GlassSurface 会画出不透明的底（深色）")
    @MainActor
    func glassSurface深色不透明() throws {
        let size = CGSize(width: 120, height: 80)
        let rep = try #require(render(GlassSurface(cornerRadius: 12), size: size, dark: true))
        let center = pixel(rep, x: 60, y: 40)
        #expect(center.a == 255, "深色下同样必须不透明")
        #expect(center.r < 70, "深色玻璃应当压暗；实测 \(center)")
    }

    /// 外描边是「毛玻璃与桌面之间唯一的边界」，用**差分**断言：
    /// 同一块玻璃，画描边时左边缘一定比不画时暗。
    ///
    /// 不用「左边缘像素 == 某个具体值」是因为描边只有 0.5pt，
    /// 落在 2x 位图上恰好一个物理像素，抗锯齿会让具体值随圆角、缩放而变。
    @Test("外描边确实画在边缘上")
    @MainActor
    func 外描边存在() throws {
        let size = CGSize(width: 120, height: 80)
        let withBorder = try #require(render(GlassSurface(cornerRadius: 12), size: size))
        let withoutBorder = try #require(
            render(GlassSurface(cornerRadius: 12, showsBorder: false), size: size))

        let a = pixel(withBorder, x: 0.25, y: 40)
        let b = pixel(withoutBorder, x: 0.25, y: 40)
        #expect(a.a == 255 && b.a == 255, "描边不该把边缘弄成透明")
        #expect(a.r < b.r, "画了 0.5px var(--border-strong) 的左边缘必须比不画时暗：\(a) vs \(b)")
    }

    // MARK: 玻璃底衬走哪一条路（2026-09-24 新增）

    /// `GlassSurface` 必须按**系统版本**挑对那条路：26 起走 Liquid Glass，14–25 走
    /// `NSVisualEffectView`。
    ///
    /// **为什么值得钉**：两条路在界面上都是「一块玻璃」，看不出差别；写反了（或有人为了
    /// 省事把 26 那条删了）**没有任何东西会红** —— 只有这条测试会。
    ///
    /// ⚠️ 它是**自证型**的：期望值由当前的 `#available` 决定，所以只能证明
    /// 「跑测试的这台机器上挑对了」，证明不了 14–25 上的行为 —— 后者要靠部署目标守卫
    /// （`@available` 写错版本是编译不过的）与真机 `--preview-main-window-keys`。
    ///
    /// ⚠️ **它测的是「真机那条路」**：这里的宿主是**裸建**的，**不注入**
    /// ``EnvironmentValues/offscreenRendering``（注入是 ``OffscreenRender`` 干的）。
    /// 而像素判据（`GlassSurface 会画出不透明的底` / `两种风格画出来的底色不同`）走的是
    /// 注入后的离屏通路 ⇒ **两边各自测一半**：
    /// 这一条管「26 上选的是不是 Liquid Glass」，那两条管「叠加色 / 描边画得对不对」。
    /// 别把这条改成走 `OffscreenRender` —— 那样它就永远只能看到旧材质，等于不测。
    @Test("玻璃底衬挑的是本系统该走的那条路")
    @MainActor
    func 玻璃底衬按系统版本分叉() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GlassSurface(cornerRadius: 12))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        host.layoutSubtreeIfNeeded()

        let ours = host.glassBackdrops.filter { $0.kind.isOurs }
        #expect(
            !ours.isEmpty,
            """
            视图树里找不到**我们自己画的**玻璃 —— 要么底衬根本没铺上，要么
            `isOurs` 的识别办法没跟上（26 起那条路靠 `identifier` 认）。
            """)

        // 只声明「应当」而不逐一比对，是为了让失败信息能说出**实际走的是哪条路** ——
        // 光写 `isLiquidGlass == true` 的话，红的时候只能看到 false，看不出它其实是旧材质。
        let walked = ours.map(\.kind.label).joined(separator: ", ")
        if #available(macOS 26.0, *) {
            #expect(
                ours.allSatisfy { $0.kind.label == GlassBackdrop.liquidGlass.label },
                "本机是 macOS 26 起，玻璃底衬应当走 Liquid Glass；实际：\(walked)")
        } else {
            #expect(
                ours.allSatisfy { $0.kind.label.hasPrefix("NSVisualEffectView") },
                "本机不到 macOS 26，玻璃底衬应当走 NSVisualEffectView；实际：\(walked)")
        }
    }
}
