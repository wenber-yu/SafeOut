import AppKit
import SwiftUI

/// 系统原生毛玻璃材质（NSVisualEffectView）。
///
/// **为什么用 NSVisualEffectView 而非 SwiftUI `.ultraThinMaterial`**：
/// - SwiftUI 的 Material 是窗口内的"应用级毛玻璃"；`.ultraThinMaterial` 在 macOS 14 上偏厚，
///   整窗覆盖会让窗口失去悬浮感。
/// - `NSVisualEffectView(.underWindowBackground, .behindWindow)` 让桌面直接透过窗口呈现，
///   这是最接近设计稿 `backdrop-filter: blur(30px) saturate(180%)` 的一档系统材质。
///
/// ⚠️ **本文件曾写「`.underWindowBackground` = NSPopover 系统默认背景」，这是错的**：
/// 2026-09-15 用探针打印 `NSPopover` 的窗口视图树，popover 的 `NSPopoverFrame`
/// 是一档 **`.titlebar`**（material rawValue 0）的 `NSVisualEffectView`。
/// 也就是说菜单面板与主窗口**本来就不是同一档材质** —— 这正是「两块玻璃色温不一样」的根因之一。
/// 修法见 ``NSPopover/normalizeBackdropMaterial()``。
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

// MARK: - 让系统 popover 的底衬与主窗口同档

extension NSPopover {

    /// 把系统 popover 的底衬材质改成与主窗口同一档（`.underWindowBackground`）。
    ///
    /// **为什么需要**：`NSPopover` 的窗口视图树顶层是私有的 `NSPopoverFrame`，
    /// 它本身就是一个 `NSVisualEffectView`，材质是 **`.titlebar`** —— 与主窗口的
    /// `.underWindowBackground` 不是同一档。两者各自叠上 `--bg-glass` 之后仍是两种色温。
    ///
    /// **为什么可以这么改**：`material` / `blendingMode` / `state` 都是 `NSVisualEffectView`
    /// 的**公开属性**，`NSPopoverFrame` 只是它的子类，改的是公开 API。
    /// 探针实测（2026-09-15）：改后 material 稳定停在 `.underWindowBackground`（rawValue 21），
    /// popover 的圆角、箭头、窗口阴影全部保持 —— 它们由 frame 的遮罩与窗口阴影负责，
    /// 与 material 无关。
    ///
    /// **不摘 `NSGlassView`**：那是系统新增的玻璃渲染层，也是圆角/描边的绘制者之一，
    /// 摘掉属于动系统私有视图，风险大于收益。材质对齐 + 同色叠加已经足够让两块玻璃一致。
    ///
    /// - Returns: 被改到的那个 `NSVisualEffectView`；视图树还没建好时为 `nil`。
    @discardableResult
    func normalizeBackdropMaterial() -> NSVisualEffectView? {
        guard let frame = backdropFrameView else { return nil }
        frame.material = .underWindowBackground
        frame.blendingMode = .behindWindow
        frame.state = .followsWindowActiveState
        return frame
    }

    /// **只读**当前底衬材质（不做任何修改）。
    ///
    /// **为什么要有这个只读版本**：真机自检（`--preview-popover-keys`）要验的是
    /// 「上屏路径有没有把材质归一化」。如果自检里用 `normalizeBackdropMaterial()` 去取材质，
    /// 它自己就把材质改好了 —— **断言永远为真，等于没测**。
    /// 这个坑值得记下来：自检里读一个「会被自检本身修正」的状态，就是在自证。
    var backdropMaterial: NSVisualEffectView.Material? { backdropFrameView?.material }

    /// popover 窗口视图树的**最外层** `NSVisualEffectView`，也就是私有的 `NSPopoverFrame`。
    ///
    /// 从 `window.contentView` 一路向上到根，再向下深度优先找第一个 ——
    /// 因为 `NSPopoverFrame` 既是根视图本身、又是效果视图，只能这么找。
    private var backdropFrameView: NSVisualEffectView? {
        guard let window = contentViewController?.view.window else { return nil }
        var top = window.contentView
        while let parent = top?.superview { top = parent }
        return top?.firstVisualEffectView
    }
}

extension NSView {
    /// 深度优先找到第一个 `NSVisualEffectView`（**先看自己**，因为 `NSPopoverFrame`
    /// 本身就是效果视图，而它是整棵树里最外层的那个）。
    fileprivate var firstVisualEffectView: NSVisualEffectView? {
        if let effect = self as? NSVisualEffectView { return effect }
        for sub in subviews {
            if let found = sub.firstVisualEffectView { return found }
        }
        return nil
    }
}

// MARK: - 玻璃底衬的两条路

/// **离屏渲染**（出图 / 像素判据）专用的环境值，默认 `false`（= 真机）。
///
/// ## 为什么需要它（2026-09-24 实测，不是推测）
///
/// macOS 26 起的 `NSGlassEffectView` 在**离屏渲染**里被画成**不透明的浅色** ——
/// 它背后没有真实桌面可采样。实测 `GlassSurface` 的中心像素：
///
/// | 风格 | 明 | 暗 |
/// |---|---|---|
/// | 透明 | **255,255,255** | 94,94,97 |
/// | 色调 | **255,255,255** | 28,28,30 |
///
/// 后果是两条守卫直接失效：
/// ① **透明风格退化成纯白** ⇒ 与色调风格「画出来完全一样」（`VisualStyleTests` 红）；
/// ② 深色下玻璃不再被叠加色压暗到 < 70（实测 94 ⇒ `GlassSurfaceTests` 红）。
///
/// 而这两条正是「三块玻璃三种色温」那组修复的判据，走查图（`SnapshotRenderTests`）
/// 也靠同一条通路 —— 26 上出的图会把透明玻璃画成白板。
/// ⇒ **离屏时退回 `NSVisualEffectView`**（它在离屏下让叠加色正常透出），真机才用 Liquid Glass。
///
/// ## 代价与分工（**必须知道**）
///
/// 离屏通路**测不到** 26 那条（真机）路径。那一条由**真机自检**负责：
/// `--preview-main-window-keys` 会打印每块玻璃的 `kind`，并在 26 上断言必须是
/// ``GlassBackdrop/liquidGlass``。两边分工：**离屏管「叠加色 / 描边 / 铺满」，
/// 真机管「走的是哪条玻璃路」**。
private struct OffscreenRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 见 ``OffscreenRenderingKey``。由 ``OffscreenRender`` 注入 `true`。
    var offscreenRendering: Bool {
        get { self[OffscreenRenderingKey.self] }
        set { self[OffscreenRenderingKey.self] = newValue }
    }
}

/// 我们自己那块玻璃的标记。
///
/// ⚠️ **故意不挂在 `LiquidGlassBackground` 上**：那个类型是 `@available(macOS 26.0, *)` 的，
/// 而这里的判据在**部署目标 14** 下也要能编译、能读 —— 挂上去，14 那条路就引用不到了。
enum GlassIdentifiers {
    static let surface = NSUserInterfaceItemIdentifier("SafeOut.GlassSurface")
}

/// 一块玻璃底衬是哪一条路的产物。
///
/// **为什么会有两条**：macOS 26 起 AppKit 提供 `NSGlassEffectView`（Liquid Glass），
/// 观感与旧材质不同（边缘折射 + 高光）。而本包的部署目标是 14 ⇒ 两条路都得留，
/// 由 ``GlassSurface`` 按可用性挑一条。
enum GlassBackdrop: Equatable {
    /// AppKit 的 `NSVisualEffectView`（14–25 那条路）。带材质档位，用来挑出「我们画的那块」。
    case visualEffect(NSVisualEffectView.Material)
    /// macOS 26 起提供的 `NSGlassEffectView`（Liquid Glass）。
    case liquidGlass

    /// 是不是**我们自己画的那块** —— 判据只认它。
    ///
    /// 两条路的识别办法不同：`NSVisualEffectView` 看 `material`（``GlassSurface`` 用
    /// `.underWindowBackground`，系统标题栏自带的是别的档）；macOS 26 起提供的
    /// `NSGlassEffectView` 没有 `material` 可看，改靠 ``GlassIdentifiers/surface``。
    ///
    /// ⚠️ 26 那条路**不能「见到 `NSGlassEffectView` 就算」** —— 系统标题栏在 26 上也是
    /// 同一种视图，算进来的话「我们自己那块没铺满」会被系统那块补上，判据就瞎了。
    var isOurs: Bool {
        switch self {
        case .visualEffect(let material): material == .underWindowBackground
        case .liquidGlass: true
        }
    }

    /// 真机自检打印用的名字（只看得懂就行，不作判据）。
    var label: String {
        switch self {
        case .visualEffect(let material): "NSVisualEffectView(material=\(material.rawValue))"
        case .liquidGlass: "LiquidGlass"
        }
    }
}

// MARK: - 窗口玻璃的自检入口

extension NSView {

    /// 本视图**及其子树**里所有玻璃底衬的 frame（**统一转成 `self` 的坐标系**）与种类。
    ///
    /// **为什么下沉到 `NSView`**：`NSWindow` 版本只能问「窗口里占多大」（真机自检用），
    /// 而 `MainWindowTests` 要问的是**「玻璃有没有铺满宿主」** —— 那只需要一个宿主视图，
    /// 不需要窗口（实测离屏也能建出玻璃视图，`layoutSubtreeIfNeeded()` 就够）。
    ///
    /// ⚠️ **为什么两条路都能离屏探到**（2026-09-24 实测，决定这条设计的关键数据）：
    /// SwiftUI 的 `.glassEffect(in:)` **在视图树里完全没有落脚点** —— 离屏搭一个
    /// `NSHostingView` 铺满它，子树里一个视图都没有 ⇒ 换它，这里所有判据会**静默失效**。
    /// AppKit 的 `NSGlassEffectView` 则**挂在视图树上**（`AppKitPlatformViewHost` 之下、
    /// frame 铺满）⇒ 探得到、判据不用改弱。⇒ 26 那条路走 AppKit，不走 SwiftUI 修饰器。
    var glassBackdrops: [(frame: CGRect, kind: GlassBackdrop)] {
        var result: [(CGRect, GlassBackdrop)] = []
        func walk(_ view: NSView) {
            // ⚠️ 必须转成统一坐标系：各层 frame 是各自父视图坐标系里的值，
            // 直接拿来求并集会得到毫无意义的矩形。
            if let effect = view as? NSVisualEffectView {
                result.append((effect.convert(effect.bounds, to: self), .visualEffect(effect.material)))
            } else if view.identifier == GlassIdentifiers.surface {
                result.append((view.convert(view.bounds, to: self), .liquidGlass))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
        return result
    }
}

extension NSWindow {

    /// 窗口内容视图树里所有玻璃底衬的**窗口坐标** frame。
    ///
    /// **用途**：回答「窗口玻璃有没有覆盖整窗」这个**只有真机才能问**的问题。
    /// 离屏渲染里没有窗口，也就没有「标题栏安全区」这回事 ——
    /// 玻璃少画了标题栏那一带，离屏出图**完全看不出来**（实测踩过：
    /// `GlassSurface` 从 `ZStack` 挪到 `.background(...)` 时丢了 `.ignoresSafeArea()`，
    /// 真机上标题栏整条露出桌面，而离屏快照仍是满窗玻璃）。
    ///
    /// **必须转成窗口坐标再比**：内容视图树里各层的坐标系互不相同，
    /// 而 `NSHostingView` 还是 flipped 的（原点在左上），拿它的 `bounds` 去比 y 轴会反过来。
    var glassBackdrops: [(frame: CGRect, kind: GlassBackdrop)] {
        guard let root = contentView else { return [] }
        // 复用 `NSView` 那一份的遍历（坐标先归到 `root`，再转窗口坐标）——
        // 两个版本各写一份 `walk` 迟早会漂移。
        return root.glassBackdrops.map {
            (root.convert($0.frame, to: nil), $0.kind)
        }
    }
}

// MARK: - Liquid Glass 那条路（macOS 26 起提供）

/// macOS 26 起提供的 AppKit 玻璃视图 `NSGlassEffectView` 的 SwiftUI 包装。
///
/// ⚠️ **为什么是 AppKit 而不是 SwiftUI 的 `.glassEffect(in:)`**（2026-09-24 实测）：
/// 后者在视图树里**不留任何落脚点**（离屏铺满一个 `NSHostingView` 也探不到），
/// 换它 ⇒ `glassBackdrops` 找不到东西 ⇒ 「玻璃铺满整窗」那几条判据**静默失效**。
/// `NSGlassEffectView` 挂在视图树上、frame 可测，判据不用改弱。
///
/// ⚠️ **为什么要打 `identifier`**：系统在 26 上也用同一种视图画标题栏，
/// 判据必须能区分「我们画的」和「系统自带的」 ⇒ 建视图时打上
/// ``GlassIdentifiers/surface``，``GlassBackdrop/isOurs`` 只认它。
@available(macOS 26.0, *)
struct LiquidGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView(frame: .zero)
        view.identifier = GlassIdentifiers.surface
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.identifier = GlassIdentifiers.surface
    }
}

// MARK: - 窗口/面板的统一玻璃底

/// 一块「窗口级毛玻璃」：**材质 + `--bg-glass` 叠加色 + 0.5px 外描边**。
///
/// **为什么必须是一个共用组件**：设计稿里主窗口、菜单面板、设置面板的外壳是同一条规则 ——
/// ```css
/// .win { border-radius: var(--r-window); border: 0.5px solid var(--border-strong);
///        background: var(--bg-glass); backdrop-filter: blur(30px) saturate(180%); }
/// ```
/// 但实现侧三处各写各的：主窗口只有 `NSVisualEffectView`（缺 `--bg-glass` 叠加，
/// 于是显示为系统材质那层偏冷的灰）、菜单面板什么都没有（靠 `NSPopover` 自带材质，
/// 又是另一档 `.titlebar`）、设置面板用了 `--bg-glass-thick`（白一档）。
/// 三块玻璃三种色温 —— 用户一眼就看出来了。
///
/// **材质之上为什么还要叠一层色**：`--bg-glass` 在设计稿里是铺在模糊之上的**半透明色**，
/// 它才是决定「暖白 / 暖深灰」的那一层。只放系统材质等于只做了模糊、没上色。
///
/// ⚠️ **挂法：一律用 `.background(GlassSurface(...))`，不要放进 `ZStack`。**
/// 里面是 `NSViewRepresentable`，放进 `ZStack` 后会被父级用「建议高度 = 无限大」量一次
/// （`sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))`），
/// SwiftUI 会拿这个 1.79e308 去建 AppKit 约束，AppKit 抛
/// `NSLayoutConstraint ... exceeds internal limits` 并**把进程打死**（实测 signal 5）。
/// `.background` 传下去的是内容已经算好的有限尺寸，不会触发。
struct GlassSurface: View {

    /// 圆角。主窗口 12（`--r-window`）、菜单面板 14（`--r-lg`）、设置面板 12。
    var cornerRadius: CGFloat

    /// 是否画 0.5px 外描边（设计稿 `.win` 的 `border: 0.5px solid var(--border-strong)`）。
    ///
    /// 默认画。只有「本身已在外框里、再画会重复」的场合才关掉。
    var showsBorder: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    /// **「视觉效果」偏好必须在这一层读** —— 设置面板只负责写它。
    ///
    /// 2026-09-17 用户报「切换透明和色调没有任何变化」，根因就是这个令牌
    /// **全仓库只有写入点、没有任何读取点**：`SettingsSectionPane` 用
    /// `@AppStorage` 把它存进 UserDefaults，而 ``GlassSurface`` 一律画毛玻璃。
    /// 一个只写不读的偏好，在 UI 上和「没做这个功能」没有区别。
    ///
    /// 放在这里而不是让三个调用点各自传参，是因为「窗口底色是什么」必须只有一个答案 ——
    /// 主窗口、菜单面板、设置面板是同一个设计规则（`.win`），
    /// 任何一处漏传都会退回毛玻璃，又会变成「三块玻璃三种色温」。
    @AppStorage(AppSettings.Key.visualStyle) private var visualStyleRaw = VisualStyle.default.rawValue

    private var style: VisualStyle { VisualStyle(rawValue: visualStyleRaw) ?? .default }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// 玻璃底衬：**26 起在真机上走 Liquid Glass，其余情况走 `NSVisualEffectView`**。
    ///
    /// 分叉写在这一处（``GlassSurface`` 是三处外壳的唯一来源），调用方不感知。
    ///
    /// ⚠️ `!offscreenRendering` 这一半**不是可有可无的开关**：Liquid Glass 在离屏渲染里
    /// 是不透明浅色（实测数据见 ``OffscreenRenderingKey``）⇒ 出图与像素判据会失真。
    /// 去掉它，`VisualStyleTests` 与 `GlassSurfaceTests` 立刻红，走查图也会变成白板。
    @ViewBuilder private var backdrop: some View {
        if #available(macOS 26.0, *), !offscreenRendering {
            LiquidGlassBackground()
        } else {
            VisualEffectBackground()
        }
    }

    @Environment(\.offscreenRendering) private var offscreenRendering

    var body: some View {
        ZStack {
            // **两种视觉风格都保留这一层玻璃**，只换上面那层色：
            // - 透明：半透明 `--bg-glass` 铺在模糊之上 → 桌面透出来，是毛玻璃；
            // - 色调：不透明的 `--bg-base` 把它完全盖住 → 固定的实体面。
            //
            // 不按风格摘掉它，是因为「玻璃铺满整窗」这条不变量由 `MainWindowTests`
            // 与 `--preview-main-window-keys` 靠**找玻璃底衬**（``glassBackdrops``）来断言。
            // 摘掉的话，那两条断言就会随用户的偏好值变绿变红 —— 自检不该依赖运行态偏好。
            backdrop
            style == .tinted
                ? DesignTokens.Palette.windowBase(for: colorScheme)
                : DesignTokens.Palette.windowGlass(for: colorScheme)
        }
        .clipShape(shape)
        .overlay {
            if showsBorder {
                shape.strokeBorder(
                    DesignTokens.Palette.borderStrong,
                    lineWidth: DesignTokens.Size.glassBorderWidth)
            }
        }
        // 纯背景：不能吃掉任何点击，否则窗口里所有控件都点不动。
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 视图级辅助（**只放有真实调用方的辅助**）。
///
/// ⚠️ 这里曾有一个 `cardStyle()`（设计稿迁移期遗留）：**零调用方**、描边用
/// `Color.primary.opacity(0.14)`（违反 `DesignTokens` 的令牌政策）、注释里引用的
/// `ProxyGenerator` 也不在本仓。2026-09-24 删除 —— 理由记在这里，
/// 免得下次有人从设计稿翻出这个样式名却找不到实现（「删宿主会顺带删知识」）。
extension View {
    /// **去 SwiftUI Button 默认 focus 环**。
    ///
    /// 主窗口启动时第一个 interactive Button 会自动获得焦点环（macOS 14+ 的 SwiftUI 默认行为），
    /// 蓝色环套在 RefreshButton 上看着像「按钮被高亮选中」——但用户没点任何按钮。
    /// - `.focusable(false)` 移除 focus 资格；
    /// - `.focusEffectDisabled()` 关掉焦点效果。
    ///
    /// ⚠️ 2026-09-24 随部署目标提到 14.0 简化：原实现是
    /// `disableFocusRing()` + 一个 `DisableFocusRingModifier`，里面用
    /// `if #available(macOS 14.0, *)` 分岔 —— 目标到 14 之后那个 `else`（原样返回 content）
    /// **永远走不到**，整层包装成了死代码，名字里的 `IfAvailable` 也不再成立。
    /// ⇒ 直接调用，把「为什么需要它」的理由留在注释里（比留一个空壳值钱）。
    func disableFocusRing() -> some View {
        focusable(false).focusEffectDisabled()
    }
}

// ⚠️ 这里原有 ``WindowAccessor``（`NSViewRepresentable`，挂进视图树后拿到 `NSWindow`
// 再跑一段配置闭包），**v3 删除**。
//
// 它服务的是「窗口层面的外观」：把标题栏设透明、让内容延伸到标题栏、支持拖动窗口背景 ——
// 主窗口与设置窗口各挂一个，顺带设 `contentView.layer` 的 12pt 圆角。
//
// v3 之后这些配置**全部搬到了 ``AppDelegate/makeMainWindow()`` 里**
// （那个函数本来就有完整的一套窗口配置，注释里写着「窗口层面的外观，全部在这里定死 ——
// 不要挪回 `ContentView` 的 `WindowAccessor`」）；
// 而「给 `contentView` 设 12pt 圆角」那一项随 ``DesignTokens/Radius`` 的
// `window` / `settings` 两个令牌一起退役 —— 窗口圆角归**窗口服务器**，
// 自绘一个只会在四角切出比窗口更小的圆（HANDOFF §3.7.2 第 1 类）。
// ⇒ 整个类型零引用，删掉它不会有任何界面变化。
