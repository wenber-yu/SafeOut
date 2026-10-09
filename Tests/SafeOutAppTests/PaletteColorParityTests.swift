import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// `DesignTokens.Palette` / `AccentColor` 与设计稿 `ds.css` 的**颜色同源契约**。
///
/// ## 为什么颜色这一轴之前没人守
///
/// `DesignTokens.swift` 的文件头写着：
///
/// > 本文件是设计稿里 `assets/ds.css` 的 Swift 侧镜像 —— **两边数值必须一致**。
///
/// 尺寸轴已经由 `DesignSizeParityTests`（§8.71 / §8.72）铺开了；**颜色轴一条都没有**：
/// 实扫 `Tests/` 里出现 `Palette` 的断言，全是「渲染出来够不够红 / 够不够琥珀」这类
/// **感知**断言，没有一条去读 `ds.css` 的变量值。⇒ 「两边数值必须一致」这句话
/// 在颜色上是**无人执行**的。
///
/// ## 颜色这一轴比尺寸多一层：**两侧**
///
/// 设计稿的颜色定义在**两个选择器**里：
///
/// | 选择器 | 含义 |
/// |---|---|
/// | `:root` | 浅色（也是深色未覆盖时的兜底） |
/// | `:root[data-theme="dark"]` | 深色（**覆盖**其中 35 个） |
///
/// 实现侧用 `Palette.adaptive(light:dark:)` 明暗自适应。所以判据必须是**两侧各比一次** ——
/// 只比浅色会漏掉整整一半（本轮修掉的三处偏差**全在深色侧**）。
///
/// ⚠️ 这正是 §8.57.6 #1 记下的那件事（「CSS 变量不区分选择器作用域」）。那一节说的是
/// **变量存在性**那一向（成本不划算、会大量假红，仍然成立）；**颜色同源这一向是可以守的** ——
/// 因为颜色令牌是有限集合，而且只需认两个选择器。§8.77 把这条边界写清楚。
///
/// ## 实扫出来的病（§8.77）
///
/// `border` / `borderStrong` / `hairline` 三个令牌**深色侧与设计稿不一致**：
/// 它们借用了 ``DesignTokens/Palette/ink(_:)`` 这个 helper，而它的深色基色是
/// `rgba(235,235,245,·)`（那是 `--text-*` **文字族**的基色），`--border*` / `--hairline`
/// 在设计稿里的深色基色是**纯白** `rgba(255,255,255,·)`。
///
/// 最讽刺的是 `borderStrong` 的注释**自己写着正确的值**：
///
/// > 设计稿 `--border-strong` 两套都是 **0.18**（浅色 `rgba(60,60,67,.18)`、
/// > 深色 `rgba(255,255,255,.18)`）。
///
/// 注释与代码不一致，而没有任何东西会红。修法：给描边族单独一个 helper
/// （``DesignTokens/Palette/edge(_:)``），`ink` 退回只服务文字族。
struct PaletteColorParityTests {

    // MARK: 取色

    /// 把 `Color` 解析成 sRGB 分量（0…1）。
    ///
    /// **为什么要显式指定外观**：`Palette` 里的颜色是 `NSColor(name:dynamicProvider:)`
    /// 造的动态色，只在绘制时按当前外观解析；不套 `performAsCurrentDrawingAppearance`
    /// 拿到的值取决于测试进程所在机器的设置 ⇒ 断言会随环境变红。
    ///
    /// ⚠️ 与 `GlassSurfaceTests` 里那份**故意各留一份**（那里是 fileprivate 的取色工具）：
    /// 两份的口径必须一致（`sRGB` + 显式外观），改动时两边都要改。
    private func rgba(_ color: Color, dark: Bool) -> RGBA {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let c = resolved else { return RGBA(r: -1, g: -1, b: -1, a: -1) }
        return RGBA(
            r: Double(c.redComponent) * 255, g: Double(c.greenComponent) * 255,
            b: Double(c.blueComponent) * 255, a: Double(c.alphaComponent))
    }

    /// sRGB 分量（`r/g/b` 用 0…255，`a` 用 0…1）。
    private struct RGBA: Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        /// 容差：颜色通道允许半格（`rgba(…, 0.055)` 这种三位小数会被解析成浮点），
        /// 透明度允许 0.004（`0.055` 与 `0.05` 是**不同**的值，必须能分辨）。
        func equals(_ other: RGBA) -> Bool {
            abs(r - other.r) <= 0.51 && abs(g - other.g) <= 0.51
                && abs(b - other.b) <= 0.51 && abs(a - other.a) <= 0.004
        }

        var text: String {
            "rgba(\(Int(r.rounded())), \(Int(g.rounded())), \(Int(b.rounded())), \(a))"
        }
    }

    // MARK: 同源表

    private struct Pair: Sendable {
        /// `ds.css` 里的变量名（含 `--`）。
        let variable: String
        let label: String
        /// 实现那一头。**写成闭包是为了每次现取** —— 写死颜色值就变回「常量跟自己比」。
        let token: @Sendable () -> Color
        let why: String
    }

    private struct SchemePair: Sendable {
        let variable: String
        let label: String
        let token: @Sendable (ColorScheme) -> Color
        let why: String
    }

    /// **明暗自适应**的颜色令牌（`Palette.adaptive(light:dark:)`）—— 两侧都钉。
    private static let pairs: [Pair] = [
        // ---- 表面 ----
        Pair(
            variable: "--bg-raised", label: "浮层 / 卡片 / 芯片底",
            token: { DesignTokens.Palette.raised }, why: "设计稿 `--bg-raised`"),
        Pair(
            variable: "--bg-subtle", label: "悬停底 / 分段槽",
            token: { DesignTokens.Palette.subtle }, why: "设计稿 `--bg-subtle`"),
        // `--bg-subtle-hi` 那条 **v3 删除**（2026-09-30）：实现侧令牌 `subtleHighlight`
        // 只被自绘按钮的 hover 底用，交还系统样式后零消费者、令牌已删
        // （`DesignTokens` 里有退役说明）。
        Pair(
            variable: "--bg-sunken", label: "证据区 / 弹窗底栏",
            token: { DesignTokens.Palette.sunken }, why: "设计稿 `--bg-sunken`"),

        // ---- 文字 ----
        Pair(
            variable: "--text-1", label: "主文字",
            token: { DesignTokens.Palette.foreground }, why: "设计稿 `--text-1`"),
        Pair(
            variable: "--text-2-strong", label: "小号加粗标题",
            token: { DesignTokens.Palette.textStrong }, why: "设计稿 `--text-2-strong`"),
        Pair(
            variable: "--text-2", label: "说明 / 容量 / 次要标签",
            token: { DesignTokens.Palette.mutedForeground }, why: "设计稿 `--text-2`"),
        Pair(
            variable: "--text-3", label: "装饰性文字",
            token: { DesignTokens.Palette.textDecorative },
            why: "设计稿 `--text-3`（**浅深透明度不同**：.38 / .36）"),

        // ---- 描边（§8.77 修的就是这三处深色侧）----
        Pair(
            variable: "--border", label: "卡片 / 分隔 / 芯片描边",
            token: { DesignTokens.Palette.border }, why: "设计稿 `--border`（深色基色是**纯白**）"),
        Pair(
            variable: "--border-strong", label: "略重的描边",
            token: { DesignTokens.Palette.borderStrong },
            why: "设计稿 `--border-strong`（深色基色是**纯白**）"),
        Pair(
            variable: "--hairline", label: "分隔线",
            token: { DesignTokens.Palette.hairline }, why: "设计稿 `--hairline`（深色基色是**纯白**）"),

        // ---- 语义色：琥珀（被占用）----
        Pair(
            variable: "--warn", label: "被占用",
            token: { DesignTokens.Palette.warning }, why: "设计稿 `--warn`"),
        Pair(
            variable: "--warn-text", label: "琥珀底上的文字",
            token: { DesignTokens.Palette.warningText }, why: "设计稿 `--warn-text`"),
        Pair(
            variable: "--warn-soft", label: "琥珀浅底",
            token: { DesignTokens.Palette.warningSoft }, why: "设计稿 `--warn-soft`"),
        Pair(
            variable: "--warn-line", label: "琥珀内描边",
            token: { DesignTokens.Palette.warningLine }, why: "设计稿 `--warn-line`"),

        // ---- 语义色：红（破坏性）----
        Pair(
            variable: "--danger", label: "破坏性",
            token: { DesignTokens.Palette.error }, why: "设计稿 `--danger`"),
        Pair(
            variable: "--danger-text", label: "红底上的文字",
            token: { DesignTokens.Palette.errorText }, why: "设计稿 `--danger-text`"),
        Pair(
            variable: "--danger-soft", label: "红浅底",
            token: { DesignTokens.Palette.errorSoft }, why: "设计稿 `--danger-soft`"),
        Pair(
            variable: "--danger-line", label: "红内描边",
            token: { DesignTokens.Palette.errorLine }, why: "设计稿 `--danger-line`"),

        // ---- 语义色：绿（可安全操作）----
        Pair(
            variable: "--ok", label: "可安全操作",
            token: { DesignTokens.Palette.success }, why: "设计稿 `--ok`"),
        Pair(
            variable: "--ok-text", label: "绿底上的文字",
            token: { DesignTokens.Palette.successText }, why: "设计稿 `--ok-text`"),
        Pair(
            variable: "--ok-soft", label: "绿浅底",
            token: { DesignTokens.Palette.successSoft }, why: "设计稿 `--ok-soft`"),
        Pair(
            variable: "--ok-line", label: "绿描边",
            token: { DesignTokens.Palette.successLine }, why: "设计稿 `--ok-line`"),
    ]

    /// **由 `ColorScheme` 传入**的颜色令牌（不是 `adaptive`）—— 同样两侧都钉。
    private static let schemePairs: [SchemePair] = [
        SchemePair(
            variable: "--bg-glass", label: "毛玻璃面（主窗口 / 面板 / 设置共用）",
            token: { DesignTokens.Palette.windowGlass(for: $0) }, why: "设计稿 `--bg-glass`"),
        SchemePair(
            variable: "--bg-base", label: "色调模式的窗口实体面",
            token: { DesignTokens.Palette.windowBase(for: $0) },
            why: "设计稿 `--bg-base`（**不透明**，色调模式用）"),
        SchemePair(
            variable: "--bg-glass-thick", label: "弹窗（更不透明）",
            token: { DesignTokens.Palette.popoverBackground(for: $0) },
            why: "设计稿 `--bg-glass-thick`（只有 `.alert` 用）"),
    ]

    /// 设计稿里**有颜色变量、实现侧没有对应令牌**的那几个 —— 每个都必须写清为什么。
    ///
    /// ⚠️ 这张表不是垃圾桶：反向守卫盯着它（登记了却已经有人用了要划掉），
    /// 而理由必须是**具体出处**，不能是空话。
    private static let designOnlyVariables: [String: String] = [
        "--bg-canvas":
            "设计稿**文档页**的画布底（`#e8ecf2` / `#16171b`）。产品窗口要么是毛玻璃（`--bg-glass`）、"
            + "要么是实体面（`--bg-base`），**没有「画布」这一层** ⇒ 实现侧不应有对应令牌",
        "--accent-hover":
            "强调色的 hover 态。v2 实现用 `.opacity(0.86)` 近似；v3（2026-09-30）按钮交还系统样式后"
            + "hover 反馈归系统 —— 与设计稿的换色做法不同，**登记为已知差异**",
        "--danger-hover":
            "危险按钮的 hover 态。同上：v2 用 `.opacity(0.86)` 近似；v3 起 hover 归系统",
        "--on-accent":
            "强调色 / 危险色**上面**的文字（`#ffffff`）。实现直接在视图里写 `.white`"
            + "（`DesignSystemComponents.swift:577`、`DiskRow.swift:880`），**等价但没有令牌**",
        "--bg-subtle-hi":
            "v3（2026-09-30）：实现侧令牌 `subtleHighlight` 只被自绘按钮的 hover 底用，"
            + "交还系统样式后令牌已删（`DesignTokens` 里有退役说明）—— 设计稿侧的声明仍在（v2 冻结稿不改），"
            + "故登记为设计稿独有",
    ]

    /// `--accent` 族由 ``强调色族的基色明暗不分这件事必须钉住()`` 单独管，不进上面两张表。
    private static let accentFamily: Set<String> = ["--accent", "--accent-soft", "--accent-ring"]

    // MARK: 路径

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadCSS() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Design/ui/v2/assets/ds.css"),
            encoding: .utf8)
    }

    // MARK: 守卫

    /// **两侧**逐值相等：浅色 ↔ `:root`，深色 ↔ `:root[data-theme="dark"]`。
    ///
    /// ⚠️ 判据只能是「**两边相等**」。写成「等于 `rgba(255,255,255,.10)`」的话，
    /// 有人把设计稿与实现**同时**改成另一个值时依然会红 —— 那是假失败（§8.51）。
    @Test func 实现颜色令牌与设计稿变量必须逐值相等() throws {
        let css = try loadCSS()
        let root = try #require(Self.scopeBody(in: css, ":root"), "取不到 `:root` 块 —— 解析口径坏了")
        let dark = try #require(
            Self.scopeBody(in: css, #":root[data-theme="dark"]"#), "取不到暗色块 —— 解析口径坏了")

        // 口径锚：解析器坏了会让下面每一项都「取不到」或比出假相等。
        #expect(Self.colorDecl(in: root, "--border") != nil, "`:root` 里解析不到 `--border`")
        #expect(Self.colorDecl(in: dark, "--border") != nil, "暗色块里解析不到 `--border`")
        #expect(Self.pairs.count >= 20, "同源表只剩 \(Self.pairs.count) 项 —— 有人删行没补回来")
        #expect(Self.schemePairs.count >= 3, "函数式令牌表只剩 \(Self.schemePairs.count) 项")

        var bad: [String] = []
        for pair in Self.pairs {
            compare(
                label: pair.label, variable: pair.variable, impl: rgba(pair.token(), dark: false),
                scope: root, dark: false, into: &bad)
            compare(
                label: pair.label, variable: pair.variable, impl: rgba(pair.token(), dark: true),
                scope: dark, dark: true, into: &bad)
        }
        for pair in Self.schemePairs {
            compare(
                label: pair.label, variable: pair.variable, impl: rgba(pair.token(.light), dark: false),
                scope: root, dark: false, into: &bad)
            compare(
                label: pair.label, variable: pair.variable, impl: rgba(pair.token(.dark), dark: true),
                scope: dark, dark: true, into: &bad)
        }

        print("  [颜色同源] 钉住 \(Self.pairs.count + Self.schemePairs.count) 项 × 明暗两侧")
        #expect(
            bad.isEmpty,
            """
            实现颜色与设计稿变量不一致（\(bad.count) 处）：
            \(bad.joined(separator: "\n"))
            `DesignTokens.swift` 的文件头写着「本文件是 `ds.css` 的 Swift 侧镜像 —— 两边数值必须一致」。
            改一边就要改另一边 —— 别让这句话变成没人执行的声明（§8.77）。
            """)
    }

    /// 设计稿里**新声明的颜色变量**必须登记进同源表（或进「设计稿独有」那张表并写明理由）。
    ///
    /// 只查「同数」的话，有人在 `ds.css` 里加一个 `--warn-bg: rgba(…)` 而实现里没有 ——
    /// 表里没这一项，同数守卫**一条都不会红**。
    @Test func 设计稿新声明的颜色变量必须登记进同源表() throws {
        let css = try loadCSS()
        let root = try #require(Self.scopeBody(in: css, ":root"), "取不到 `:root` 块")
        let declared = Self.colorVariables(in: root)
        // 负向锚：扫不到东西时差集是空的 —— 通过得毫无意义。
        #expect(
            declared.count >= 30,
            """
            `:root` 只扫到 \(declared.count) 个颜色变量（真实 33 个）—— 解析口径坏了。
            ⚠️ 这个数曾经掉到 **15**（第一版按 `;` 切分再筛 `hasPrefix("--")`：变量前面那行
            `/* ---- 表面 ---- */` 会粘在切分块前面 ⇒ **每个分组的第一项被丢**）。
            """)

        var registered = Set(Self.pairs.map(\.variable))
        registered.formUnion(Self.schemePairs.map(\.variable))
        registered.formUnion(Self.accentFamily)

        let unregistered = declared.subtracting(registered).subtracting(Self.designOnlyVariables.keys)
        #expect(
            unregistered.isEmpty,
            """
            设计稿 `:root` 里这些颜色变量**没有登记**：\(unregistered.sorted().joined(separator: ", "))
            要么在 `pairs` / `schemePairs` 里加一项把它钉住，要么进 `designOnlyVariables` 并写清
            为什么实现侧不该有对应令牌 —— **别让新颜色悄悄漂**。
            """)
    }

    /// 反向：同源表 / 豁免表里登记的东西**已经不存在了**要划掉。
    ///
    /// ⚠️ 这条守卫有牙的前提是 ``colorVariables(in:)`` 扫得准 —— 它坏掉时
    /// **失败信息看起来像「设计稿把变量删了」**，实际是解析器丢了（本轮实测 14 项假红）。
    @Test func 同源表里已经不存在的颜色变量要划掉() throws {
        let css = try loadCSS()
        let root = try #require(Self.scopeBody(in: css, ":root"), "取不到 `:root` 块")
        let declared = Self.colorVariables(in: root)
        #expect(declared.count >= 30, "`:root` 只扫到 \(declared.count) 个颜色变量 —— 解析口径坏了")

        let stale = (Set(Self.pairs.map(\.variable)).union(Self.designOnlyVariables.keys))
            .subtracting(declared).sorted()
        #expect(
            stale.isEmpty,
            """
            这些登记在案，但设计稿 `:root` 里**已经没有这个变量**了：\(stale.joined(separator: ", "))
            变量删了、这一条就永远不会被任何断言碰到，只会安静地烂在表里 —— 划掉它。
            """)
    }

    /// **强调色族的基色：两侧各钉各的**（2026-09-21 从「明暗不分」翻过来，§8.113.11）。
    ///
    /// 设计稿里 `--accent` 在暗色下**是另一个值**（蓝 `#409cff`、紫 `#bf6ae8`、
    /// 橙 `#ffb340`、绿 `#4cd964`）。2026-09-21 之前实现侧只有 `hex` 一套值，
    /// 深色下约 20 处强调色元素用的是浅色值 —— 那时这条守卫钉的是
    /// **「基色明暗不分」这个事实**（旧名：`强调色族的基色明暗不分这件事必须钉住`）。
    ///
    /// 现在实现侧加了 `hexDark` ⇒ 断言**反过来**：**两侧都必须等于设计稿各自的值**。
    /// ⚠️ 旧断言的失败消息里本就写着「别只删掉这条断言」—— 所以这里是**改判据**，
    /// 不是删守卫（把守卫删掉的话，"改了却看不出效果"就没人会红了）。
    @Test func 强调色族的基色两侧各钉各的() throws {
        let css = try loadCSS()
        let root = try #require(Self.scopeBody(in: css, ":root"), "取不到 `:root` 块")

        // ① 浅色侧：4 门强调色必须与设计稿 `--accent` **逐值相等**（这一半是钉住的）
        var bad: [String] = []
        for accent in AccentColor.allCases {
            let scope =
                accent == .blue
                ? root
                : try #require(
                    Self.scopeBody(in: css, #":root[data-accent="\#(accent.rawValue)"]"#),
                    "取不到 `\(accent.rawValue)` 的强调色块 —— 选择器改名了？")
            let design = try #require(
                Self.colorDecl(in: scope, "--accent"),
                "`\(accent.rawValue)` 的块里解析不到 `--accent` —— 解析口径坏了")
            let impl = rgba(accent.swiftUIColor, dark: false)
            if !impl.equals(design) {
                bad.append("\(accent.rawValue)：实现 \(impl.text) ≠ 设计稿 \(design.text)")
            }
        }
        #expect(
            bad.isEmpty,
            """
            强调色**浅色侧**与设计稿不一致（\(bad.count) 门）：
            \(bad.joined(separator: "\n"))
            浅色侧本来是钉住的 —— 这里红了说明 `AccentColor.hex` 被改动了。
            """)

        // ② 深色侧：基色必须等于设计稿的**深色** `--accent`（§8.113.11）。
        //
        //    2026-09-21 之前这一半是「基色必须与浅色相同」= 钉住「明暗不分」那个事实。
        //    现在两侧各钉各的 ⇒ 判据**反过来**：深色侧必须**等于设计稿深色值**。
        var darkBad: [String] = []
        for accent in AccentColor.allCases {
            let scope =
                accent == .blue
                ? try #require(
                    Self.scopeBody(in: css, #":root[data-theme="dark"]"#),
                    "取不到深色 `:root` 块 —— 选择器改名了？")
                : try #require(
                    Self.scopeBody(
                        in: css, #":root[data-theme="dark"][data-accent="\#(accent.rawValue)"]"#),
                    "取不到 `\(accent.rawValue)` 的深色强调色块 —— 选择器改名了？")
            let design = try #require(
                Self.colorDecl(in: scope, "--accent"),
                "`\(accent.rawValue)` 的深色块里解析不到 `--accent` —— 解析口径坏了")
            let impl = rgba(accent.swiftUIColor, dark: true)
            if !impl.equals(design) {
                darkBad.append("\(accent.rawValue)：实现 \(impl.text) ≠ 设计稿 \(design.text)")
            }
        }
        #expect(
            darkBad.isEmpty,
            """
            强调色**深色侧**与设计稿不一致（\(darkBad.count) 门）：
            \(darkBad.joined(separator: "\n"))
            深色基色在 `AccentColor.hexDark`。
            ⚠️ 别把这条断言删掉 —— 删了就没人会红，"加了深色值却没生效"会静默过去。
            """)
    }

    /// **强调色浅底与内描边的透明度分档**（§8.77.7 的缺口，2026-09-21 补）。
    ///
    /// 这两个令牌此前被放进 `accentFamily` **豁免**了「新变量必须登记」那条守卫，
    /// 而注释里写着「由 `强调色族的基色两侧各钉各的`（旧名：…明暗不分…）单独管」——
    /// ⚠️ **那条只测基色 `--accent`**，soft / ring **一项都没测**
    /// ⇒ 实际上是「豁免了，却没人真的接管」（同族：§8.109.4「守卫一直在，只是指针烂了」）。
    ///
    /// **为什么两侧判据不同**：
    ///
    /// - **浅色侧全值比**：实现用 `accent.appKitColorLight`（= 设计稿 `--accent` 的浅色值）+ alpha。
    /// - **深色侧 2026-09-21 起也是全值比**（§8.113.11）：实现侧加了 `hexDark` 后，
    ///   深色基色不再是浅色基色 ⇒ **RGB 两侧都该相等了**。
    ///
    ///   ⇒ 「只比 alpha」是当初「基色明暗不分」那个前提下的妥协；
    ///   **前提没了，判据就得跟着改**（否则深色基色写错了也看不出来）。
    ///
    ///   ⚠️ **一次归因错误，值得记**：改完判据后我做过一个变异 —— 把 `accentTint`
    ///   换成「单动态基色 + `withAlphaComponent`」，守卫**是绿的**。
    ///   我差点写成「判据有漏洞」。实测后才知道：AppKit 的 `withAlphaComponent`
    ///   **会保留动态 provider**，两种写法结果逐值相同。
    ///   ⇒ **变异绿 ≠ 判据没牙，也可能只是「两种写法等价」**。
    ///   别把「没红」直接读成「守卫不行」—— 先问是不是变异本身没制造出差异。
    ///
    /// ⚠️ **补这条时一并修了设计稿**：深色 + 紫 / 橙 / 绿原先**只覆盖**了
    /// `--accent` / `--accent-hover`，`--accent-soft` / `--accent-ring` 会
    /// **继承 `:root[data-theme="dark"]` 里蓝色那两个值** ⇒ 文字图标是紫色、浅底描边是蓝色。
    /// 已在 `ds.css` 补上三条声明（RGB 取各门的深色基色，alpha 取实现侧分档）。
    @Test func 强调色浅底与内描边的透明度分档必须与设计稿一致() throws {
        let css = try loadCSS()
        let root = try #require(Self.scopeBody(in: css, ":root"), "取不到 `:root` 块")
        let darkRoot = try #require(
            Self.scopeBody(in: css, #":root[data-theme="dark"]"#), "取不到暗色块")

        let cases: [(String, (AccentColor) -> Color)] = [
            ("--accent-soft", { DesignTokens.Palette.accentSoft($0) }),
            ("--accent-ring", { DesignTokens.Palette.accentRing($0) }),
        ]

        var bad: [String] = []
        for accent in AccentColor.allCases {
            let lightScope =
                accent == .blue
                ? root
                : try #require(
                    Self.scopeBody(in: css, #":root[data-accent="\#(accent.rawValue)"]"#),
                    "取不到 `\(accent.rawValue)` 的浅色块 —— 选择器改名了？")
            let darkScope =
                accent == .blue
                ? darkRoot
                : try #require(
                    Self.scopeBody(in: css, #":root[data-theme="dark"][data-accent="\#(accent.rawValue)"]"#),
                    "取不到 `\(accent.rawValue)` 的深色块 —— 补在 `ds.css` 的那三条声明没了？")

            for (variable, token) in cases {
                // ① 浅色：全值（RGBA）
                let designLight = try #require(
                    Self.colorDecl(in: lightScope, variable),
                    "`\(accent.rawValue)` 浅色块里解析不到 `\(variable)` —— 解析口径坏了")
                let implLight = rgba(token(accent), dark: false)
                if !implLight.equals(designLight) {
                    bad.append(
                        "\(accent.rawValue) \(variable) 浅色：实现 \(implLight.text) ≠ 设计稿 \(designLight.text)")
                }

                // ② 深色：全值（RGBA）—— 两侧基色分开之后 RGB 也该相等了（§8.113.11）
                let designDark = try #require(
                    Self.colorDecl(in: darkScope, variable),
                    "`\(accent.rawValue)` 深色块里解析不到 `\(variable)` —— 解析口径坏了")
                let implDark = rgba(token(accent), dark: true)
                if !implDark.equals(designDark) {
                    bad.append(
                        "\(accent.rawValue) \(variable) 深色：实现 \(implDark.text) ≠ 设计稿 \(designDark.text)"
                            + "（档位：蓝 0.16 / 0.40，其余 0.12 / 0.35；"
                            + "RGB 应取各门的**深色**基色 `AccentColor.hexDark`）")
                }
            }
        }

        #expect(
            bad.isEmpty,
            """
            强调色的浅底 / 内描边与设计稿不一致（\(bad.count) 处）：
            \(bad.joined(separator: "\n"))
            这两个令牌的**分档**是有理由的：深色下蓝要更重，否则浅底在 #1c1c1e 上看不出来。
            """)
    }

    // MARK: 断言辅助

    /// 把一项同源表条目与设计稿比一次（单侧）。
    ///
    /// 判据是 ``RGBA/equals(_:)``（**两边相等**），不是「等于某个字面值」——
    /// 后者在设计稿与实现同时改值时会给假失败。
    private func compare(
        label: String, variable: String, impl: RGBA, scope: String, dark: Bool, into bad: inout [String]
    ) {
        guard let design = Self.colorDecl(in: scope, variable) else {
            bad.append("\(label)：设计稿里取不到 `\(variable)` —— 变量改名了就要同步这张表")
            return
        }
        if !impl.equals(design) {
            bad.append(
                "\(label)（\(variable)，\(dark ? "深色" : "浅色")）："
                    + "设计稿 \(design.text)，实现 \(impl.text)")
        }
    }

    // MARK: 解析

    /// 取 `selector { … }` 的块体（按花括号配平），并**先剥掉注释**。
    ///
    /// ⚠️ 选择器与 `{` 之间**空白数不固定**（实测 `green"]  {` 是两个空格）——
    /// 精确匹配字符串会**找不到**，而那种失败看起来像「设计稿里没这个变量」。
    private static func scopeBody(in css: String, _ selector: String) -> String? {
        let cleaned = stripComments(css)
        let needle = NSRegularExpression.escapedPattern(for: selector) + #"\s*\{"#
        guard let open = cleaned.range(of: needle, options: .regularExpression) else { return nil }
        var depth = 1
        var index = open.upperBound
        let start = index
        while index < cleaned.endIndex, depth > 0 {
            switch cleaned[index] {
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
            index = cleaned.index(after: index)
        }
        return String(cleaned[start..<cleaned.index(before: index)])
    }

    /// 去掉 `/* … */` 注释。
    ///
    /// **它挡的是 ``colorDecl(in:_:)`` 的子串查找**：那里用 `range(of: "--border:")` 取
    /// 第一处出现的位置，所以**注释里提到的变量名会被当成真的声明**。
    /// 变异 M208 把一行 `/* --border: rgba(9, 9, 9, 0.99); */` 插在真声明之前：
    /// 留着本函数 → 绿（M208b），去掉本函数 → 红（M208）。
    /// **这两条一起才是「本函数不是死代码」的证据** —— 只留一条的话，
    /// 「守卫没牙」与「变异改了个寂寞」在输出里长得一模一样。
    ///
    /// ⚠️ 顺带纠正一个原本的误判（M208 实测出来的）：以为 ``colorVariables(in:)`` 也依赖它
    /// —— **不依赖**。那个函数用的是正则，`[^;]+` 只吃到第一个 `;`，
    /// 而行内注释（`--bg-canvas: #e8ecf2;   /* 设计稿底板 */`）在 `;` **之后**。
    private static func stripComments(_ text: String) -> String {
        var out = text
        while let open = out.range(of: "/*"),
            let close = out.range(of: "*/", range: open.upperBound..<out.endIndex)
        {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out
    }

    /// 取 `--x: …;` 的**颜色**值。非颜色（尺寸 / 字体 / 阴影 / `var()` 引用）返回 `nil`。
    private static func colorDecl(in body: String, _ variable: String) -> RGBA? {
        guard let r = body.range(of: "\(variable):") else { return nil }
        let rest = body[r.upperBound...]
        guard let end = rest.firstIndex(of: ";") else { return nil }
        return parseColor(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `#rrggbb` 或 `rgba(r, g, b, a)`（也接受 `rgb(...)`）。其它一律 `nil`。
    private static func parseColor(_ text: String) -> RGBA? {
        if text.hasPrefix("#"), text.count == 7 {
            guard let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
            return RGBA(
                r: Double((value >> 16) & 0xff), g: Double((value >> 8) & 0xff),
                b: Double(value & 0xff), a: 1)
        }
        guard text.hasPrefix("rgb(") || text.hasPrefix("rgba(") else { return nil }
        guard text.hasSuffix(")") else { return nil }
        let inner = text.drop(while: { $0 != "(" }).dropFirst().dropLast()
        let parts = inner.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces)) ?? -1
        }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        return RGBA(
            r: parts[0], g: parts[1], b: parts[2], a: parts.count == 4 ? parts[3] : 1)
    }

    /// 块里所有**颜色**型变量名（排除尺寸 / 字体 / 圆角 / 阴影 / 时长 / `var()` 别名）。
    ///
    /// ⚠️ **别退回「按 `;` 切分再筛 `hasPrefix("--")`」**：变量前面那行
    /// `/* ---- 表面 ---- */` 会粘在切分块前面 ⇒ `hasPrefix` 判假 ⇒
    /// **每个分组的第一项被静默丢掉**。实测这样只扫到 **15** 个（真实 33 个），
    /// 而丢掉的那批正好是每个分组的第一项 —— 症状是「登记了却已经不存在」，
    /// 看起来像设计稿删了变量（两条反向守卫一起假红 14 项）。
    private static func colorVariables(in body: String) -> Set<String> {
        let pattern = #"(--[A-Za-z0-9_-]+)\s*:\s*([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        var out: Set<String> = []
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard parseColor(value) != nil else { continue }
            out.insert(ns.substring(with: m.range(at: 1)))
        }
        return out
    }
}
