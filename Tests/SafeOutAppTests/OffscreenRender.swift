import AppKit
import SwiftUI

@testable import SafeOutApp

/// 离屏渲染工具：把 SwiftUI 视图画进位图，再量**墨迹**（深色像素）或**某个颜色的覆盖范围**。
///
/// ## 为什么只能这么量
///
/// SwiftUI 的 `Text` / `Image` 在 AppKit 视图树里**没有任何对应视图**
/// （`NSHostingView.subviews` 是空的，整棵树里找不到 `NSTextField`，
/// 无障碍子树也是懒建的），「这个视图到底画了多大」问不到 AppKit —— 只能看**渲染结果**。
///
/// ## 两个必须记住的坑
///
/// 1. **缓冲区不保证清零** → 必须显式分配 `NSBitmapImageRep`，不要复用别人的。
/// 2. **量之前先确认渲染通路是通的**（放一个已知会命中的对照组）。
///    「0 命中」有两种含义：真的没有，或**判据本身坏了** —— 两者长得一模一样。
///    本仓库已经在这上面栽过两次。
///
/// ## 读像素走**缓冲区直读**（2026-09-23 改）
///
/// 原先每个像素都调一次 `NSBitmapImageRep.colorAt(x:y:)`（内部要构造一个 `NSColor`）。
/// 最重的量测一次要扫 1600×1040 ≈ **166 万**像素，5 个用例各扫一遍，实测 **1.5s/次**
/// 且**整段串在主 actor 上**（`DESIGN-SPEC.md` §8.114 的重活清单）。
/// 现在改成直读 ``PixelBuffer``，`colorAt` 只作为**布局不认识时**的兜底。
///
/// ⚠️ 语义等价**不是**「看着差不多」：预乘 / 非预乘弄反的话，扫出来的计数**照样是个合理的整数**，
/// 只是悄悄偏了 —— 这正是本仓库最怕的失效方式。所以另有一条 `OffscreenRenderParityTests`
/// 把两条路**逐像素**对一遍。
///
/// ⚠️ `TitleBarBaselineTests` 里有一份**更早的、只量列/行范围**的实现，先于本文件存在。
/// 两者判据一致（深色阈值 0.75），只是那两份返回的是区间而不是总数/包围盒。
/// 新写的测试请用本文件，不要再来第三份。
@MainActor
enum OffscreenRender {

    // MARK: - 出图

    /// 把 `view` 画进 `size` 大小的位图（scale 2，与真机 Retina 一致）。
    ///
    /// `appearance` 默认 `.aqua`（浅色）。**深色页面必须显式传 `.darkAqua`** ——
    /// AppKit 宿主的外观会覆盖 SwiftUI 环境值，深色稿在浅色宿主里渲染出来的是浅色版。
    ///
    /// `background` 默认白（``inkCount`` 的「深色墨迹」判据依赖它）。
    /// **量 `ContentView` 这类自带不透明玻璃的页面时必须传 `.clear`** ——
    /// 垫一层白底会把半透明玻璃透出来的地方抬到接近 255，
    /// 亮像素判据（见 ``brightPixels(_:size:in:above:appearance:background:)``）就废了。
    static func bitmap(
        _ view: some View, size: CGSize, appearance: NSAppearance.Name = .aqua,
        background: Color = .white
    ) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let scale: CGFloat = 2
        // ⚠️ **必须注入 `offscreenRendering`**：macOS 26 起的 Liquid Glass 在离屏渲染里
        // 是不透明浅色（实测见 `OffscreenRenderingKey` 的表）⇒ 不注入的话，透明玻璃会被
        // 画成纯白、与色调风格无法区分，本文件所有像素判据和走查图一起失真。
        // 真机那条路（Liquid Glass）由 `--preview-main-window-keys` 负责。
        let hosting = NSHostingView(
            rootView: view.environment(\.offscreenRendering, true).background(background))
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    // MARK: - 读像素

    /// 位图缓冲区的**直读器**：按字节取像素，不构造 `NSColor`。
    ///
    /// ## 布局是**实测**的，不是推断的（2026-09-23 探针）
    ///
    /// 把 ``bitmap(_:size:appearance:background:)`` 产出的 rep 原样打出来：
    ///
    /// | 属性 | 实测值 |
    /// |---|---|
    /// | `bitsPerSample` / `samplesPerPixel` | 8 / 4 |
    /// | `bytesPerRow` | `pixelsWide * 4`（**无行末补齐**） |
    /// | `bitmapFormat.rawValue` | `0`（alpha 在**末位**且**预乘**） |
    /// | 每像素字节序 | R, G, B, A |
    ///
    /// ## ⚠️ 缓冲区是**预乘**的，而 `colorAt` 返回**非预乘**的
    ///
    /// 两者对**不透明**像素完全一致，对半透明像素差一个 alpha 因子。实测（50% 红压透明底）：
    ///
    /// | 像素 | 原始字节 | `colorAt.r` | 直读 `r` | `r / a` |
    /// |---|---|---|---|---|
    /// | 50% 红 | `128 0 0 128` | **1.0** | 0.502 | **1.0** |
    ///
    /// ⇒ 必须 `r / a`；`a == 0` 时 `colorAt` 返回全 0，直读也返回全 0。
    ///
    /// ⚠️ 试过给 `NSBitmapImageRep` 传 `.alphaNonpremultiplied` 把这一步省掉 ——
    /// **实测拿到全零缓冲区**（`rawValue = 2`，每个字节都是 0），那条路走不通。
    ///
    /// ⚠️ `bytesPerRow` **读属性**、不写死 `width * 4`：实测相等，但那是「今天这个 init」的结论，
    /// 行末补齐是位图 API 的常规行为。
    struct PixelBuffer {
        private let base: UnsafeMutablePointer<UInt8>
        private let bytesPerRow: Int
        let width: Int
        let height: Int

        /// 只在布局与上表一致时启用；否则返回 `nil`，调用方退回 `colorAt`。
        init?(_ rep: NSBitmapImageRep) {
            guard rep.bitsPerSample == 8, rep.samplesPerPixel == 4, !rep.isPlanar,
                !rep.bitmapFormat.contains(.alphaFirst),
                !rep.bitmapFormat.contains(.alphaNonpremultiplied),
                let data = rep.bitmapData
            else { return nil }
            self.base = data
            self.bytesPerRow = rep.bytesPerRow
            self.width = rep.pixelsWide
            self.height = rep.pixelsHigh
        }

        /// (x, y) 的**非预乘** RGBA（0…1）—— 与 `colorAt(x:y:)` 的通道值同义。
        ///
        /// 这是本类型的原语；`rgb` 只是丢掉 alpha 的便利版。
        func rgba(x: Int, y: Int) -> (Double, Double, Double, Double) {
            let p = base + y * bytesPerRow + x * 4
            let a = Double(p[3])
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(p[0]) / a, Double(p[1]) / a, Double(p[2]) / a, a / 255)
        }

        /// (x, y) 的**非预乘** RGB（0…1）。
        func rgb(x: Int, y: Int) -> (Double, Double, Double) {
            let (r, g, b, _) = rgba(x: x, y: y)
            return (r, g, b)
        }
    }

    /// 取 `(x, y)` 的**非预乘** RGB（0…1）。越界或读不出来返回 `nil`。
    ///
    /// 给「沿一列竖扫」这类调用方用（`MainWindowDiskListTests.amberRuns`、
    /// `MenuDiskRowLayoutTests.amberBar`）—— 它们原先也是逐像素 `colorAt`。
    static func rgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (Double, Double, Double)? {
        guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { return nil }
        if let buf = PixelBuffer(rep) { return buf.rgb(x: x, y: y) }
        guard let c = rep.colorAt(x: x, y: y) else { return nil }
        // ⚠️ 这三个 `Double(...)` **不是冗余**，删了本地照样绿、CI 会红（§8.130）：
        // `NSColor.redComponent` 是 `CGFloat`，而「元组字面量内部的 CGFloat → Double 隐式转换」
        // 是 **Swift 6.4 才放宽**的（本地 Xcode 27 / Swift 6.4 接受，CI 的 Xcode 26.6 / Swift 6.3.3 拒绝）。
        // 2026-09-22 CI run 35761198327 就红在这一行。
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// 逐像素遍历 `rect`（pt，原点左上；`nil` = 全图），把**非预乘** RGB（0…1）与像素坐标交给 `body`。
    ///
    /// 返回 `false` 表示**区域为空** —— 调用方沿用本文件「量不出来就返回 `-1` / `nil`」的约定。
    /// 走 ``PixelBuffer`` 快路径；布局不认识时退回 `colorAt`（慢，语义一致）。
    ///
    /// ## ⚠️ 这是本仓**唯一**的读像素入口（2026-09-23 起）
    ///
    /// 在它之前，`Tests/` 里有 5 个文件各自手写「逐像素 `colorAt` 循环」，另有 3 份
    /// 各写一遍的 `NSBitmapImageRep(bitmapDataPlanes: nil, …)` 出图块。那些副本不是
    /// 「风格不统一」这种审美问题 —— §8.130 那次 **CI 红**就长在一份这样的副本里
    /// （`c.redComponent` 隐式转 `Double`，本地 6.4 接受、CI 6.3.3 拒绝）。
    /// 而且 `colorAt` 每次要构造一个 `NSColor`：实测 **0.773 µs/次**，直读是 **0.002 µs/次**，
    /// 差 **约 400 倍**（探针见 `DESIGN-SPEC.md` §8.131）。
    ///
    /// ⇒ **新写的量测一律走本文件**：计数用 ``inkCount(_:in:scale:)``、
    /// 区间用 ``inkColumnRange(_:rows:maxX:scale:)`` / ``inkRowRange(_:columns:rows:scale:)``、
    /// 自定义谓词用本函数。**不要再手写循环**（回退由 `PixelReadPathTests` 拦）。
    ///
    /// ⚠️ **越界是「夹住」不是「报错」**：`rect` 超出位图会被 `max` / `min` 裁到边界，
    /// 于是「槽位算歪了」与「量到了空的地方」都会得到一个**看着合理的数字**。
    /// 调用方要自己先证明 `rect` 落在位图里（`ProcessChipLayoutTests` 就是这么做的）。
    ///
    /// ⚠️ **夹取是必须的，不是保险**：旧写法（逐像素 `colorAt`）越界会返回 `nil`、
    /// 被 `continue` 跳过；换成直读之后越界就是**真的读缓冲区外的内存**。
    /// 所以本文件所有入口一律 `max(0, …)` / `min(pixels…, …)`。
    @discardableResult
    static func forEachPixel(
        _ rep: NSBitmapImageRep, in rect: CGRect?, scale: CGFloat,
        _ body: (Int, Int, Double, Double, Double) -> Void
    ) -> Bool {
        let x0: Int
        let x1: Int
        let y0: Int
        let y1: Int
        if let rect {
            x0 = max(0, Int(rect.minX * scale))
            x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
            y0 = max(0, Int(rect.minY * scale))
            y1 = min(rep.pixelsHigh, Int(rect.maxY * scale))
        } else {
            x0 = 0
            x1 = rep.pixelsWide
            y0 = 0
            y1 = rep.pixelsHigh
        }
        guard x0 < x1, y0 < y1 else { return false }
        forEachPixel(rep, x: x0..<x1, y: y0..<y1, body)
        return true
    }

    /// **像素空间**的遍历 —— 本文件里**唯一**真正读像素的地方。
    ///
    /// ⚠️ 为什么不把上面那条 pt 版当唯一入口：`CGRect.maxY` 是 `y + height` **算出来的**，
    /// 而 `a + (b - a) == b` 在浮点上**不保证**（差一个 ulp 就让 `Int(x * scale)` 少 1，
    /// 扫描带悄悄窄一格 —— 那种失败与「墨迹真的不在那」在断言层面**逐字相同**）。
    /// ``inkColumnRange(_:rows:maxX:scale:)`` / ``inkRowRange(_:columns:rows:scale:)``
    /// 拿到的边界就是 pt 区间端点，必须**照旧逐位**换算，所以它们走这一条。
    ///
    /// 夹取由调用方负责（两条 pt 入口都夹过了）。
    ///
    /// ## ⚠️ 构造 `x0..<x1` / `y0..<y1` 时，`..<` 的**右边不许紧跟操作数**（2026-09-23 编译器实测）
    ///
    /// `..<` 是**既有二元又有前缀**（`PartialRangeUpTo`）的运算符，Swift 靠**空格**消歧：
    /// **左侧有空白 + 右侧无空白 ⇒ 前缀**（换行也算左侧空白）。所以把长表达式折行写成
    /// `let xs = x0` ⏎ `..<x1` 时，`..<x1` 会被解析成**前缀运算符**，`xs` 变成 `Int`。
    ///
    /// | 写法 | 编译器判据（`swiftc -typecheck`，2026-09-23 实测） |
    /// |---|---|
    /// | `x0..<x1`（两侧都无空格） | ✅ 二元 ⇒ `Range<Int>` |
    /// | `x0 ..< x1`（两侧都有空格） | ✅ 二元 ⇒ `Range<Int>` |
    /// | `x0 ..<x1`（左有空格、右无） | ❌ 前缀 ⇒ `consecutive statements on a line must be separated by ';'` |
    /// | `x0` ⏎ `..<x1`（换行 + 右侧无空格） | ❌ 前缀 ⇒ `xs` 是 `Int` |
    ///
    /// ⚠️ 折行那一种最阴：报错是「`cannot convert return expression of type 'Int' to return type 'Range<Int>'`」，
    /// **指向使用处而不是构造处** ⇒ 第一反应会去改使用处（`TitleBarBaselineTests.inkRowRange`
    /// 就为此绕过一次，那段注释随该套件一起删了，2026-09-23 迁到这里）。
    ///
    /// ⇒ 折行时右侧**必须留空格**（`..< x1`），或者干脆让区间构造待在同一行。
    ///
    /// ℹ️ **这条是注释、不是守卫**：它**编译不过**，所以永远到不了 CI ——
    /// 代价只是「报错指错地方」的调试时间，而「指向哪里」是编译器的事，静态扫描器替不了。
    /// （对比 ``ImplicitCGFloatConversionTests``：那一条是**编译得过但 CI 拒**，所以才需要守卫。）
    private static func forEachPixel(
        _ rep: NSBitmapImageRep, x xs: Range<Int>, y ys: Range<Int>,
        _ body: (Int, Int, Double, Double, Double) -> Void
    ) {
        if let buf = PixelBuffer(rep) {
            for x in xs {
                for y in ys {
                    let (r, g, b) = buf.rgb(x: x, y: y)
                    body(x, y, r, g, b)
                }
            }
        } else {
            for x in xs {
                for y in ys {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    // 同 ``rgb(_:x:y:)``：显式 `Double(...)`，别依赖隐式转换（§8.130）。
                    body(
                        x, y, Double(c.redComponent), Double(c.greenComponent),
                        Double(c.blueComponent))
                }
            }
        }
    }

    // MARK: - 墨迹判据

    /// **深色墨迹**的判据：任一通道 < `0.75`。
    ///
    /// ## 为什么把它抽成一个函数（2026-09-23）
    ///
    /// 这条判据原先在 `Tests/` 里**逐字抄了 6 遍**（本文件 1 处 + `TitleBarBaselineTests` 2 处 +
    /// `EmptyStateTests` / `SettingsLayoutTests` / `TrafficLightAlignmentTests` 各 1 处）。
    /// 抄着的坏处不是啰嗦：**改阈值要改 6 处，漏掉一处就会有一条测试在守另一个判据 ——
    /// 而没有任何东西会红**（「同一事实写两处会漂」的经典形状）。
    ///
    /// ⚠️ 产品代码里还有一份**独立的**同款判据（`WindowSelfCheck.swift`，两处）。
    /// 它读的是 `CGWindowListCreateImage` 的真机截图、不在本 target 里，**用不到本函数** ——
    /// 那一半的收敛记在 `DESIGN-SPEC.md` 的账本里，别以为这里抽完就全仓只剩一处了。
    static func isInk(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        r < 0.75 || g < 0.75 || b < 0.75
    }

    // MARK: - 三种形状（计数 / 列区间 / 行区间）

    /// `rect`（pt，原点左上）内的**深色墨迹像素个数**；区域为空返回 `-1`。
    ///
    /// `-1` 而不是 `0`：`0` 是「区域里确实没有墨迹」，`-1` 是「这次没量到」——
    /// 两者在断言层面长得一样，而本仓库已经栽过两次「0 命中 = 真的没有 vs 判据坏了」。
    static func inkCount(_ rep: NSBitmapImageRep, in rect: CGRect, scale: CGFloat = 2) -> Int {
        var n = 0
        let ok = forEachPixel(rep, in: rect, scale: scale) { _, _, r, g, b in
            if isInk(r, g, b) { n += 1 }
        }
        return ok ? n : -1
    }

    /// 出图 + ``inkCount(_:in:scale:)``。一个用例要量同一张图的**好几块区域**时，
    /// 先自己 `bitmap()` 一次、再用上面那条 —— 否则每块区域都会重画一遍。
    static func inkCount(_ view: some View, size: CGSize, in rect: CGRect) -> Int {
        guard let rep = bitmap(view, size: size) else { return -1 }
        return inkCount(rep, in: rect)
    }

    /// 深色墨迹在「**行 `rows`** × **列 `0…maxX`**」这块里占据的**首列 / 末列**。
    ///
    /// ⚠️ **返回的是「有墨迹的那一列像素的左边缘」，不是「墨迹的左右边界」**：
    /// 末列 `last` 对应像素 `x = Int(last * scale)`，墨迹实际一直画到它**右**边缘
    /// （即 `(last * scale + 1) / scale`）。这与 `TitleBarBaselineTests` 里那份更早的
    /// 实现**逐字同义** —— 那些断言的容差是照着这个口径定的，改口径会让它们全变。
    ///
    /// ⚠️ **参数是 pt 区间而不是 `CGRect`**：区间端点直接换算成像素下标（`Int(bound * scale)`），
    /// 而 `CGRect` 的 `maxY` 是 `y + height` 算出来的 —— 差一个 ulp 就会让扫描带窄一格。
    /// 见 ``forEachPixel(_:x:y:_:)`` 的说明。
    ///
    /// ## ⚠️ 首 / 末是**极值**，不是「扫到的第一个 / 最后一个」（2026-09-23）
    ///
    /// ``forEachPixel(_:x:y:_:)`` 是 **x 外层、y 内层**。所以「扫到的第一个墨迹」
    /// 的实际含义是「**最左那一列**自己的最小 y」—— 只有当「最左列的墨迹恰好也带着最小 y」时，
    /// 它才等于「真正的最小 y」。**两种写法都会给出一个看着合理的数**。
    ///
    /// 这不是假想：把 `TitleBarBaselineTests.inkRowRange`（原 **y 外层**）改成走这条公共遍历时
    /// 就是这么错的 —— `first` 从 `19.5` 悄悄变成 `51.0`，没有任何东西会红。
    /// ⇒ 这里一律用 `min` / `max` 累积，**不依赖遍历顺序**。
    /// 分辨这条轴的样本见 `OffscreenRenderParityTests.首末是极值不是扫到的第一个`。
    ///
    /// 没扫到任何墨迹返回 `nil`（与「扫到了、但那一列都没有」是同一件事）。
    static func inkColumnRange(
        _ rep: NSBitmapImageRep, rows: ClosedRange<CGFloat>, maxX: CGFloat, scale: CGFloat = 2
    ) -> (first: CGFloat, last: CGFloat)? {
        let x0 = 0
        let x1 = min(rep.pixelsWide, Int(maxX * scale))
        let y0 = max(0, Int(rows.lowerBound * scale))
        let y1 = min(rep.pixelsHigh, Int(rows.upperBound * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        var lo: Int?
        var hi: Int?
        forEachPixel(rep, x: x0..<x1, y: y0..<y1) { x, _, r, g, b in
            guard isInk(r, g, b) else { return }
            lo = lo.map { Swift.min($0, x) } ?? x
            hi = hi.map { Swift.max($0, x) } ?? x
        }
        guard let lo, let hi else { return nil }
        return (CGFloat(lo) / scale, CGFloat(hi) / scale)
    }

    /// 深色墨迹在「**列 `columns`** × **行 `rows`**」这块里占据的**首行 / 末行**。
    /// 口径与 ``inkColumnRange(_:rows:maxX:scale:)`` 同（取像素**上**边缘、参数是 pt 区间、
    /// **首末是极值不是扫到的第一个**）。
    static func inkRowRange(
        _ rep: NSBitmapImageRep, columns: ClosedRange<CGFloat>, rows: ClosedRange<CGFloat>,
        scale: CGFloat = 2
    ) -> (first: CGFloat, last: CGFloat)? {
        let x0 = max(0, Int(columns.lowerBound * scale))
        let x1 = min(rep.pixelsWide, Int(columns.upperBound * scale))
        let y0 = max(0, Int(rows.lowerBound * scale))
        let y1 = min(rep.pixelsHigh, Int(rows.upperBound * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        var lo: Int?
        var hi: Int?
        forEachPixel(rep, x: x0..<x1, y: y0..<y1) { _, y, r, g, b in
            guard isInk(r, g, b) else { return }
            lo = lo.map { Swift.min($0, y) } ?? y
            hi = hi.map { Swift.max($0, y) } ?? y
        }
        guard let lo, let hi else { return nil }
        return (CGFloat(lo) / scale, CGFloat(hi) / scale)
    }

    // MARK: - 四个量

    /// 整幅图里的深色像素个数。判据见 ``isInk(_:_:_:)``。
    static func inkCount(_ view: some View, size: CGSize) -> Int {
        guard let rep = bitmap(view, size: size) else { return -1 }
        return inkCount(rep, in: CGRect(origin: .zero, size: size))
    }

    /// 符合 `matchingRGB` 的像素的**包围盒**（pt，原点左上）。用来量「某块底色到底画了多大」。
    ///
    /// **必须用纯色去量**：判定一个接近背景色的半透明填充，阈值怎么定都说不清；
    /// 换成纯黑/纯白之后「覆盖到哪」就是确定的。
    ///
    /// ⚠️ 谓词收的是**非预乘** RGB（0…1），与 `NSColor` 的通道值同义。原先收
    /// `(NSColor) -> Bool`，改成三个 `Double` 是为了能走 ``PixelBuffer`` 快路径 ——
    /// 收 `NSColor` 就得逐像素构造对象，而**三处调用方的谓词都只看 r/g/b**（不看 alpha）。
    static func boundingBox(
        _ view: some View, size: CGSize, scale: CGFloat = 2,
        matchingRGB: (Double, Double, Double) -> Bool
    ) -> CGRect? {
        guard let rep = bitmap(view, size: size) else { return nil }
        return boundingBox(rep, scale: scale, matchingRGB: matchingRGB)
    }

    /// 用**已经画好**的位图量包围盒 —— 一个用例要同时量好几件事时，省掉一次重复出图。
    ///
    /// `MainWindowDiskListTests.amberRuns` 原先先 `bitmap()` 拿到 `rep`、再让 `boundingBox`
    /// **自己又画一遍**，同一张图渲染两次；`MenuDiskRowLayoutTests.amberBar` 同款。
    static func boundingBox(
        _ rep: NSBitmapImageRep, scale: CGFloat = 2,
        matchingRGB: (Double, Double, Double) -> Bool
    ) -> CGRect? {
        var minX = rep.pixelsWide
        var minY = rep.pixelsHigh
        var maxX = -1
        var maxY = -1
        forEachPixel(rep, in: nil, scale: scale) { x, y, r, g, b in
            guard matchingRGB(r, g, b) else { return }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale)
    }

    /// `rect`（pt，原点左上）内**亮度 > `above`** 的像素个数。区域外不参与。
    ///
    /// ## 判据选型的实测依据（2026-09-16）
    ///
    /// 要判「标题栏刷新按钮那一格画的是箭头还是 spinner」，在**离屏出图**的环境里量过三种判据
    /// （`main-window-dark.png`，2x，刷新盒 x ∈ [730, 758]、y ∈ [0, 32]pt，
    /// 设置盒 x ∈ [760, 788]pt 作同款图标参照）：
    ///
    /// | 判据 | 箭头 | spinner | 分辨力 |
    /// |---|---|---|---|
    /// | 峰值亮度 | 168 | 158 | ❌ 只差 10 |
    /// | 最大连通块 | 174 | 36 | ✅ 5 倍，但要写洪泛填充 |
    /// | **亮度 >118 的像素数** | **174** | **93** | ✅ **近 2 倍，够用** |
    ///
    /// ⚠️ **别把真机量到的「箭头 245 / spinner 160」搬过来** —— 那是 `screencapture`
    /// 拍真实窗口的数，离屏渲染里同一个 `mutedForeground` 图标只有 168。
    /// **同一个判据不能跨环境搬**（本轮踩到，第一版断言就是照搬真机数字写死的）。
    ///
    /// ⚠️ `above` 是**相对阈值**，只在深色底（背景峰值 78）上有意义；
    /// 浅色页面图标是深色的，得换判据。`background` 默认白，
    /// **量 `ContentView` 这类自带不透明玻璃的页面必须传 `.clear`**。
    static func brightPixels(
        _ view: some View, size: CGSize, in rect: CGRect, above: Int = 118,
        appearance: NSAppearance.Name = .aqua, background: Color = .white
    ) -> Int {
        guard let rep = bitmap(view, size: size, appearance: appearance, background: background)
        else { return -1 }
        var n = 0
        let ok = forEachPixel(rep, in: rect, scale: 2) { _, _, r, g, b in
            if Int(max(r, g, b) * 255) > above { n += 1 }
        }
        return ok ? n : -1
    }

    /// `rect`（pt，原点左上）内**红色占优**的像素个数：`r − max(g, b) > above`（0…255）。
    ///
    /// ## 用途：断言「某段文字不是红的」
    ///
    /// 「这个视图有没有被染红」问不到视图树（SwiftUI 的 `Text` 在 AppKit 里没有对应视图），
    /// 只能看渲染结果。判据要能**同时**满足两件事：红字算红、灰字不算红。
    ///
    /// | 被测像素 | `r − max(g,b)` | 结论 |
    /// |---|---|---|
    /// | `#FF3B30`（`Palette.error`） | 255 − 59 = **196** | ✅ 算红 |
    /// | 上面这红与白各半混（抗锯齿边） | 255 − 157 = **98** | ✅ 仍算红 |
    /// | `#1D1D1F`（`Palette.foreground`） | 29 − 31 = **−2** | ✅ 不算红 |
    /// | `rgba(60,60,67,.62)` 压在白上 ≈ `#86868B` | 134 − 139 = **−5** | ✅ 不算红 |
    /// | 纯白底 | 0 | ✅ 不算红 |
    ///
    /// `above` 默认 **60**：离抗锯齿边的 98 留了近 40 的余量，离灰字的 0 附近也留了 60。
    /// ⚠️ **必须带对照组**：本仓库已经栽过两次「0 命中」——
    /// 真的没有红色，与判据本身坏了，两者长得一模一样。
    /// 所以断言里要有一条「已知会命中」的红色样本。
    static func redPixels(
        _ view: some View, size: CGSize, in rect: CGRect, above: Int = 60,
        appearance: NSAppearance.Name = .aqua, background: Color = .white
    ) -> Int {
        guard let rep = bitmap(view, size: size, appearance: appearance, background: background)
        else { return -1 }
        var n = 0
        let ok = forEachPixel(rep, in: rect, scale: 2) { _, _, r, g, b in
            let r255 = r * 255
            let g255 = g * 255
            let b255 = b * 255
            if Int(r255 - max(g255, b255)) > above { n += 1 }
        }
        return ok ? n : -1
    }
}
