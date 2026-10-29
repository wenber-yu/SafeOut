import AppKit
import SwiftUI

// 本文件是设计稿 `Design/ui/v2/` 的**基础组件库** Swift 实现。
// 每个组件上方都标注了它在 `assets/ds.css` 里的对应类与关键尺寸来源。
// 改视觉先改设计稿与 ``DesignTokens``，再回来对齐这里 —— 不要在视图里写魔法数。

// MARK: - Hairline（1 物理像素发丝线）
//
// 设计稿的分隔线统一是 `box-shadow: inset 0 0.5px 0 var(--hairline)`
// （见 `ds.css` 的 `.sline + .sline`）—— 0.5 CSS px 在 2x 屏上正好是 **1 物理像素**。
//
// **为什么不能直接写 `.frame(height: 0.5)`**：
// `0.5` 是**亚像素高度**，SwiftUI 对它的取整方向不确定。实测同一个
// `Rectangle().fill(hairline).frame(height: 0.5)`：
// - 放在设置面板「外观」卡的第二行上 → 取整成 1pt（2 物理像素），看得见；
// - 放在「通用」卡的第二行上 → 取整成 0pt，**整条线凭空消失**。
// 症状是「分隔线时有时无」，而且改一个字号或文案长度就会换另一条线消失，
// 排查时极易误判成颜色、透明度或 z 轴层级问题（实测排了三轮才定位到取整）。
//
// 现在的画法把**布局高度**和**绘制高度**分开：
// - 布局高度固定 `1pt`（整数，取整无歧义，永远不会塌成 0）；
// - 绘制高度 `1 / displayScale`，2x 屏正好 1 物理像素、1x 屏 1 像素。
// 于是「有 1pt 的位置放线」和「线只占 1 物理像素」两件事互不干扰。
//
// 副作用：作为**布局元素**（而非 overlay）使用时它会占 1pt 高度，
// 而设计稿的 `inset box-shadow` 不占高度。所以能用 overlay 的地方优先用 overlay。
struct Hairline: View {

    /// 线的颜色。默认取调色板的 `hairline`（8% 墨色）。
    var color: Color = DesignTokens.Palette.hairline

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: 1 / displayScale)),
                with: .color(color))
        }
        .frame(height: 1)
        // 纯装饰：不参与命中测试，否则会把下方行的点击区挡掉。
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 按设计稿的 CSS line-height 排版
//
// **为什么需要这个东西**：CSS 的 `line-height` 定义的是**行盒高度**，对每一行（含第一行）
// 都生效；SwiftUI 的 `Text` 用的是字体自然行高（12pt 只有 15pt），`lineSpacing` 又只补
// **行与行之间**。于是同一段文字在两边差出 3pt/行：
//
// | | CSS `line-height: 1.5`（12pt） | SwiftUI 默认 |
// |---|---|---|
// | 单行 | 18 | 15 |
// | 三行 | 54 | 45 |
//
// 单行看不出，三行的提示块差 9pt —— 落到弹窗上就是整体高度偏出十几 pt
// （实测 A 变体多 17pt、B 变体少 11pt，而「看起来对不对」的走查完全没发现）。
//
// **手法**：`lineSpacing` 补上差额，再把差额的一半补在上下内边距上。
// 设差额 `d = 设计行高 − 自然行高`：
// - 单行：`自然 + d = 设计行高` ✓
// - n 行：`n × 自然 + (n−1) × d（行间距） + d（内边距） = n × 设计行高` ✓
//
// 补在**上下各一半**而不是全补在上面，是为了和 CSS 的 half-leading 一致 ——
// 行盒里多出来的高度上下均分，文字在行盒内保持居中，基线位置也就跟着对齐了。
//
// ⚠️ **不要试图用 `NSParagraphStyle` 的 `minimumLineHeight`**：`Text(AttributedString)`
// 会**忽略**段落样式（实测设了 18 仍按 15 排版），此路不通。
extension View {

    /// 按设计稿的 CSS `line-height` 排版。
    ///
    /// - Parameters:
    ///   - multiple: 设计稿的行高倍数（见 ``DesignTokens/LineHeight``）。
    ///   - fontSize: 该段文字的字号 —— 用来查自然行高并算出要补的差额。
    func designLineHeight(_ multiple: CGFloat, fontSize: CGFloat) -> some View {
        let delta = fontSize * multiple - DesignTokens.naturalLineHeight(fontSize)
        // 自然行高已经高于设计行高时（理论上不会发生）不反向压缩，交给系统。
        let inset = max(0, delta)
        return lineSpacing(inset).padding(.vertical, inset / 2)
    }
}

// MARK: - IconBadge（圆角图标容器）
//
// 设计稿 `.diskicon` / `.crow__icon` / `.empty__art`：图标坐在带浅色底的圆角方块里。
// 被占用时整块切琥珀配色（`.diskicon--busy`），这是「判定优先」的第一层线索。

struct IconBadge: View {
    enum Style {
        /// 主窗口磁盘行：40 × 40，圆角 10，图标 22。
        case diskRow
        /// 菜单栏磁盘行：32 × 32，圆角 10，图标 18。
        case menuRow
        /// 紧凑行：30 × 30，圆角 8，图标 17。
        case compactRow
        /// 空状态大图标：76 × 76，圆角 18，图标 36。
        case emptyArt
        /// 菜单栏面板空状态图标：56 × 56，圆角 14，图标 36。
        ///
        /// **与 `.emptyArt` 不是同一档**：面板只有 360pt 宽，76 的方块在空状态里
        /// 比文案还重。设计稿在 `02-menu-bar.html` 里把它覆盖成 56 / 圆角 14。
        case menuEmptyArt
        // ⚠️ 2026-09-29 删除 `case settingsAbout`（44 × 44、圆角 12、accent 实心）：
        // 设置面板切两栏后「关于」独占一页、改用居中大图标（``SettingsAboutPane``，
        // 在 `SettingsView.swift` 里）。理由与下面那两条逐字相同 —— 零实例化点。
        // ⚠️ 这里曾经还有 `dialogWarning` / `dialogPrimary`（「无底色，警告色/强调色 32pt」），
        // 2026-09-16 设计走查时删掉。两条理由：
        //
        // 1. **死代码**：全仓库（`Sources/` + `Tests/`）只有声明处引用，没有任何实例化点
        //    —— 其余六个 case 都有 ≥2 处（声明 + 使用）。`style:` 实参也全是字面量，
        //    不存在动态构造。
        // 2. **规格是错的**：设计稿的弹窗图标**永远**坐在 `.alert__icon` 浅底容器里
        //    （38 × 38、圆角 10、图标 20；`ds.css` 只有 `--warn` / `--danger` / `--info`
        //    三个修饰符，**没有「无底色」这一档**）。那条正确的规格由 ``AlertIcon`` 承担。
        //
        // 留着它的代价与 `.actionrow--danger` 染红同类：下一个读到这里的人会以为
        // 「设计稿的弹窗警告图标是一个 32pt 无底色的琥珀图标」，然后照着它做一个
        // 不合规的弹窗 —— **一个过时的规格比没有规格更危险**。
    }

    let systemName: String
    let style: Style
    let accent: AccentColor
    /// 是否处于「被占用」状态（切琥珀配色）。仅行内样式有意义。
    var isBusy: Bool = false

    var body: some View {
        let cfg = configuration()
        Image(systemName: systemName)
            .font(.system(size: cfg.iconSize, weight: .medium))
            .foregroundStyle(cfg.foreground)
            .frame(width: cfg.container, height: cfg.container)
            .background(
                RoundedRectangle(cornerRadius: cfg.radius, style: .continuous)
                    .fill(cfg.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cfg.radius, style: .continuous)
                    .strokeBorder(cfg.border, lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    private struct Config {
        let container: CGFloat
        let iconSize: CGFloat
        let radius: CGFloat
        let background: Color
        let foreground: Color
        let border: Color
    }

    private func configuration() -> Config {
        let accentColor = accent.swiftUIColor
        // ## 为什么「被占用」的磁盘徽标用**红**而不是琥珀（2026-10-27 用户明确要求）
        //
        // 用户原话：「菜单栏列表或者设置窗口中，硬盘被占用的时候，该硬盘项的硬盘 icon
        // 调整为红色强调色」。这里**按用户要求破例**，与
        // ``DesignTokens/Palette`` 的硬规则（琥珀 = 受阻且需用户介入；红 = 破坏性）
        // 刻意不一致 —— 不是笔误，别"顺手改回琥珀"：
        // - 磁盘被占用确实是「受阻」，按设计稿该用琥珀；
        // - 但在这个产品里，「占用」是**推不出的直接原因**，用户要的是**一眼看到是哪块盘**
        //   —— 行首那根琥珀色忙碌条 + 状态文案已经承担了「受阻」的语义，
        //   徽标再是琥珀就融进背景、扫视时看不出来；
        // - 红色在这里承担的是**指向（这块盘）**而不是「破坏性」——只染徽标本身，
        //   行内**忙碌条、文案、按钮一律不动**（用户只要求 icon）。
        // 破例范围严格限定在 `isBusy` 的三个行档位；其它任何地方仍按硬规则用琥珀。
        switch style {
        case .diskRow:
            return Config(
                container: DesignTokens.Size.diskIconContainer,
                iconSize: 22,
                radius: DesignTokens.Radius.md,
                background: isBusy
                    ? DesignTokens.Palette.errorSoft : DesignTokens.Palette.accentSoft(accent),
                foreground: isBusy ? DesignTokens.Palette.error : accentColor,
                border: isBusy
                    ? DesignTokens.Palette.errorLine : DesignTokens.Palette.accentRing(accent)
            )
        case .menuRow:
            // **与 `.diskRow` 不是同一档**（设计稿两条独立规则）：
            //   `.mrow__icon  { width:32px; height:32px; border-radius: var(--r-sm)=6px;
            //                   background: var(--accent-soft); color: var(--accent); }
            //   `.mrow__icon svg { width: 17px }`
            // 没有描边。曾经沿用 `.diskRow` 的圆角 10 + 0.5px `accent-ring`，
            // 32pt 的方块上圆角从 6 变 10，四角明显「胖」了一圈，还多出一条设计稿没有的边。
            return Config(
                container: DesignTokens.Size.menuIconContainer,
                iconSize: DesignTokens.Size.menuIconSize,
                radius: DesignTokens.Size.menuIconRadius,
                background: isBusy
                    ? DesignTokens.Palette.errorSoft : DesignTokens.Palette.accentSoft(accent),
                foreground: isBusy ? DesignTokens.Palette.error : accentColor,
                border: .clear
            )
        case .compactRow:
            return Config(
                container: DesignTokens.Size.compactIconContainer,
                iconSize: 17,
                radius: DesignTokens.Radius.sm + 2,
                background: isBusy
                    ? DesignTokens.Palette.errorSoft : DesignTokens.Palette.accentSoft(accent),
                foreground: isBusy ? DesignTokens.Palette.error : accentColor,
                border: isBusy
                    ? DesignTokens.Palette.errorLine : DesignTokens.Palette.accentRing(accent)
            )
        case .emptyArt:
            return Config(
                container: DesignTokens.Size.emptyArtSize,
                iconSize: 36,
                radius: DesignTokens.Radius.xl,
                background: DesignTokens.Palette.subtle,
                foreground: DesignTokens.Palette.textDecorative,
                border: .clear
            )
        case .menuEmptyArt:
            return Config(
                container: DesignTokens.Size.menuEmptyArtSize,
                iconSize: DesignTokens.Size.menuEmptyArtIcon,
                radius: DesignTokens.Radius.lg,
                background: DesignTokens.Palette.subtle,
                foreground: DesignTokens.Palette.textDecorative,
                border: .clear
            )
        // ⚠️ 2026-09-29 删除 `case .settingsAbout`：设置面板切两栏后，
        // 「关于」独占一页、改用居中大图标（``SettingsAboutPane``：76 × 76、
        // accent 实底 + 白图标 40、e2 阴影）。本档位（44 × 44 的行内徽标）
        // 在源码与测试里都**再没有实例化点** —— 与上面那两条
        // `dialogWarning` / `dialogPrimary` 同一条纪律：留着一个没人用的规格，
        // 下一个人会以为「关于页的图标是个 44pt 的行内徽标」。
        // 设计稿 05 页那一版（`.aboutrow`）仍在册，但产品侧已随形态切换退役。
        }
    }
}

// MARK: - AlertIcon（弹窗图标容器）
//
// 设计稿 `.alert__icon`：38 × 38、圆角 10、图标 20，坐在同色系浅底上。
// 与 ``IconBadge`` 的区别是**它带语义色**：琥珀=受阻（`.alert__icon--warn`，
// 本组件拿它表达「被占用」这个实例）、红=破坏性失败（`.alert__icon--danger`）。
// 这两种颜色在设计稿里是**专义**的（§2.1：琥珀=受阻且需用户介入、红=破坏性），
// 所以不做成通用的可配色组件。

/// 弹窗左上角图标。设计稿 `.alert__icon--warn` / `.alert__icon--danger`。
struct AlertIcon: View {
    enum Kind {
        /// 琥珀 + 三角感叹号 —— 「即将推出，但被占用」。
        case warning
        /// 红 + × —— 推出失败。
        case danger
        /// 强调色 + 自选图标 —— 供其它弹窗复用。
        case accent(String)
    }

    let kind: Kind
    var accent: AccentColor = .default

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: DesignTokens.Size.alertIconSize, weight: .medium))
            .foregroundStyle(foreground)
            .frame(
                width: DesignTokens.Size.alertIconContainer,
                height: DesignTokens.Size.alertIconContainer
            )
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(background)
            )
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .warning: return "exclamationmark.triangle"
        case .danger: return "xmark"
        case .accent(let name): return name
        }
    }

    private var foreground: Color {
        switch kind {
        case .warning: return DesignTokens.Palette.warning
        case .danger: return DesignTokens.Palette.error
        case .accent: return accent.swiftUIColor
        }
    }

    private var background: Color {
        switch kind {
        case .warning: return DesignTokens.Palette.warningSoft
        case .danger: return DesignTokens.Palette.errorSoft
        case .accent: return DesignTokens.Palette.accentSoft(accent)
        }
    }
}

// MARK: - AlertCallout（弹窗警示块）
//
// 设计稿 `.callout`：圆角 6、内边距 9/11、左侧 14pt 图标 + 12pt 文字、0.5px 同色内描边。
//
// **为什么不做成「一段彩色文字」**：设计稿把警示/提示从正文里拎出来单独成块，
// 是为了让它在扫读时先被看到。实测（`03-eject-flow.html`）块高 72（红）/ 54（蓝），
// 明显高于同字号的普通段落 —— 这个高度差本身就是信息层级。

/// 弹窗内的警示 / 提示块。设计稿 `.callout` / `.callout--info`。
struct AlertCallout: View {
    enum Kind {
        /// 红底红字 —— 「关闭它们会丢失未保存的内容」。
        case danger
        /// 强调色底、正文色字 —— 「这次失败已记入日志」。
        case info
    }

    let kind: Kind
    let systemImage: String
    let text: String
    var accent: AccentColor = .default

    var body: some View {
        // 图标**垂直居中**在提示块里，与设计稿渲染结果一致。
        //
        // ⚠️ 设计稿自身在这里是矛盾的：`.callout svg` 写的是 `margin-top: 1px`（顶部对齐），
        // 但 `ds.js` 会给所有 `<i>`/`<span>` 图标包裹层加上 `display:inline-flex;
        // align-items:center`，而该包裹层作为 `.callout` 的 flex 项被拉满内容高度 ——
        // 于是**实际渲染出来是居中的**（实测：A 变体 72pt 高的块里 svg 顶边在 29pt，
        // 正是居中位置）。用户比对的是渲染结果，所以这里跟渲染结果走。
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DesignTokens.Size.calloutIconSize, weight: .medium))
                .foregroundStyle(iconColor)
                // 设计稿 `.callout svg { width: 14px; height: 14px; flex: none }`：
                // 图标列是**固定 14pt** 的，不随字形包围盒伸缩。
                //
                // **少了这层 `frame` 照样编译、也照样好看，但列宽是错的**：SF Symbol 在
                // 14pt 字号下的包围盒是 **17pt 宽**（`exclamationmark.triangle` 实测 17×16），
                // 比设计稿多占 3pt，文字列会从 316pt 缩到 313pt。
                // 而警示文案正好卡在折行边界上（每行 26 个汉字 = 312pt）：
                // 316pt 列留 4pt 余量，313pt 列只剩 1pt —— 字号或文案稍有变化就会多顶出一行。
                // 列宽已钉成测试（`警示块图标列固定为设计稿的14`）。
                .frame(
                    width: DesignTokens.Size.calloutIconSize,
                    height: DesignTokens.Size.calloutIconSize)
            Text(text)
                .font(.system(size: DesignTokens.FontSize.caption))
                .foregroundStyle(textColor)
                .designLineHeight(
                    DesignTokens.LineHeight.relaxed, fontSize: DesignTokens.FontSize.caption
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Size.calloutPaddingH)
        .padding(.vertical, DesignTokens.Size.calloutPaddingV)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(border, lineWidth: 0.5)
        )
    }

    private var background: Color {
        switch kind {
        case .danger: return DesignTokens.Palette.errorSoft
        case .info: return DesignTokens.Palette.accentSoft(accent)
        }
    }

    private var border: Color {
        switch kind {
        case .danger: return DesignTokens.Palette.errorLine
        case .info: return DesignTokens.Palette.accentRing(accent)
        }
    }

    /// 图标颜色 = **同块的文字颜色**。
    ///
    /// 设计稿的 `.callout svg` 没有自己的 `color`，图标 SVG 用的是
    /// `stroke="currentColor"`（见 `ds.js` 的 `build()`），所以它继承 `.callout`
    /// 的 `color`：红块是 `--danger-text`、信息块是 `--text-1`。
    ///
    /// **曾经红块用 `--danger`（亮红）、信息块用强调色** —— 都比设计稿跳一档。
    /// 在 `04-onboarding.png` 上采样证实：信息块里的盾牌是 `rgb(29,29,31)`
    /// （正文色），不是强调色蓝。图标比正文跳，会让「这是一段说明」变成
    /// 「这是一个警告」，而提示块本身已经用底色说了这件事。
    private var iconColor: Color { textColor }

    private var textColor: Color {
        switch kind {
        case .danger: return DesignTokens.Palette.errorText
        case .info: return DesignTokens.Palette.foreground
        }
    }
}

// MARK: - 按钮
//
// 设计稿 `.btn` 三个尺寸 × 五个变体。**高度/内边距/字号全部来自令牌**，
// 视图侧只选变体，不自己调数值 —— 否则同一排按钮会各自高低不齐。

/// 按钮变体（设计稿 `.btn--*`）。
enum ButtonVariant: Equatable {
    /// 强调色实心 —— 「推出」（空闲）。
    case primary
    /// 红色实心 —— 「关闭并推出」（被占用）。**破坏性专用**。
    case danger
    /// 透明 + 1px 描边 —— 取消、打开系统设置。
    case outline
    /// 中性浅底 —— 次级动作。
    case neutral
    /// 透明 + 强调色文字 —— 链接式动作。
    case ghost
}

/// 按钮尺寸（设计稿 `.btn` / `.btn--sm` / `.btn--lg`）。
enum ButtonSize {
    /// 高 34 / 内边距 16 —— 主行动（弹窗主按钮）。
    case large
    /// 高 30 / 内边距 12 —— 默认（弹窗次按钮）。
    case medium
    /// 高 26 / 内边距 10 / 字号 12 —— 行内、面板。
    case small

    /// ⚠️ **v3 起高度归系统**（HANDOFF §3.5 实测表）：`.large` = 28 / `.regular` = 24 /
    /// borderless = 16 —— 自绘的 `height`（34/30/26）与 `paddingH` 已随之退役，
    /// **别再拿旧值做布局预算**。
    var controlSize: ControlSize {
        switch self {
        // 原自绘 34（弹窗主按钮）与 30（默认）都落系统的 `.large`（28）；
        // 原 26（行内）落 `.regular`（24）。
        case .large, .medium: return .large
        case .small: return .regular
        }
    }
    var fontSize: CGFloat {
        switch self {
        case .large: return DesignTokens.FontSize.body
        case .medium: return DesignTokens.FontSize.body
        case .small: return DesignTokens.FontSize.caption
        }
    }
    var iconSize: CGFloat {
        switch self {
        case .large: return 14
        case .medium: return 14
        case .small: return 13
        }
    }
}

/// ⚠️ **v3 退役：`HoverBackground`（2026-09-30）**
///
/// 它过去负责「hover 底色比按钮盒子向内缩一圈」的几何（曾有 5 条离屏测试
/// `HoverBackgroundTests` 钉着）。v3 交还系统样式后：
/// - `ActionButton` 的 hover 反馈归系统（macOS 26 = Liquid Glass；14–15 = 系统高亮）；
/// - 唯一的另一名用户 `TitleBarIconButton` 已随自绘头部五件套退役；
/// ⇒ 消费者清零，按 HANDOFF §3.5「HoverBackground 若只服务按钮，可一并退役」删除。
/// 若将来再有「自绘 hover 底」的需求，从 git 历史把它找回来 —— **先问是不是
/// 又在画系统该给的东西**。

/// 统一按钮。设计稿的 `.btn` 系列。
///
/// **v3（HANDOFF §3.5）：形状交还系统** —— `ButtonVariant` / `ButtonSize` 两个枚举
/// **保留**（调用点不用全改），但语义从「自绘参数」变成了「**到系统样式的映射**」：
///
/// | 我们的变体 | 系统样式 | 颜色（唯一由我们给的） |
/// |---|---|---|
/// | `primary`（推出） | `.borderedProminent` | `.tint(品牌强调色)` |
/// | `danger`（关闭并推出） | `.borderedProminent` | `.tint(.red)` |
/// | `outline`（取消） | `.bordered` | 默认 |
/// | `neutral`（稍后） | `.bordered` | 默认 |
/// | `ghost`（了解更多） | `.borderless` | `.tint(品牌强调色)` |
///
/// ⇒ 形状 / 圆角 / 玻璃 / hover / 按下反馈 / **焦点环** / 禁用态视觉 **全部由系统给**：
/// macOS 26 = 全胶囊 + Liquid Glass；14–15 = 传统圆角矩形。**同一份代码系统自己切。**
///
/// ⚠️ **高度也归系统**（`fittingSize` 实测，HANDOFF §3.5 表）：
/// `.large` = 28（原自绘 34）/ `.regular` = 24（原 26）——
/// **别再拿 ``ButtonSize/height`` 之外的自绘高度做布局预算**。
///
/// **仍然用 SwiftUI `Button` 而不是 `onTapGesture`**：SwiftUI Button 的点击响应在 macOS 上
/// 经过 NSButton 路径，第一次点击立即可触发；`onTapGesture` 在首次渲染后存在约 1 个
/// runloop tick 的注册延迟，会出现「第一次点击没反应」——这是本项目用户报告过的核心症状。
struct ActionButton: View {
    let title: String
    var systemImage: String?
    var variant: ButtonVariant = .neutral
    var size: ButtonSize = .medium
    var accent: AccentColor = .default
    var isEnabled: Bool = true
    /// 无障碍标签。行内按钮必须带上磁盘名（设计稿 §6 VoiceOver 第 2 条），
    /// 否则用户听到的是一串无差别的「推出」。
    var accessibilityLabel: String?
    /// 键盘快捷键。弹窗的默认按钮用 `.defaultAction`（回车）、取消按钮用 `.cancelAction`（Esc）。
    ///
    /// **必须加在 `Button` 上而不是外层**：`.keyboardShortcut` 只对它修饰的 `Button` 生效，
    /// 加在包裹它的自定义视图上不会向下传递。所以这里把它作为参数收进来。
    var keyboardShortcut: KeyboardShortcut?
    let action: () -> Void

    var body: some View {
        button
            .controlSize(size.controlSize)
            .keyboardShortcut(keyboardShortcut)
            .disabled(!isEnabled)
            .help(title)
            .accessibilityLabel(accessibilityLabel ?? title)
    }

    /// 样式映射本体 —— **每个变体一条链**（三种系统 style 是不同类型，
    /// `@ViewBuilder` 的 switch 是最直白的写法；别用 `AnyView` 包）。
    @ViewBuilder
    private var button: some View {
        switch variant {
        case .primary:
            core.buttonStyle(.borderedProminent).tint(accent.swiftUIColor)
        case .danger:
            // v3a：从系统 `.red`（#FF3B30，旧配色）换成设计令牌的朱砂
            // `DesignTokens.Palette.error`（浅色 #DC2626 / 深色 #EF4444），
            // 否则这颗按钮会一直是旧配色的红，与新语义色脱节。
            core.buttonStyle(.borderedProminent).tint(DesignTokens.Palette.error)
        case .outline, .neutral:
            core.buttonStyle(.bordered)
        case .ghost:
            core.buttonStyle(.borderless).tint(accent.swiftUIColor)
        }
    }

    /// 内容层：图标 + 文字。**只给字号与字重**，底色 / 描边 / 圆角一概不画。
    private var core: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size.iconSize, weight: .medium))
                }
                Text(title)
                    .font(.system(size: size.fontSize, weight: .medium))
            }
        }
    }
}

// MARK: - ProcessChip（进程芯片）
//
// 设计稿 `.chip`：高 26、全圆角、`bg-raised` + e1 阴影。
// 结构 = 应用图标 20 × 20（圆角 5）+ 显示名 12/500。
//
// **「应用名」与「图标」都来自 ``OccupyingProcess/displayName`` 与 ``ProcessAppResolver``**：
// 直接用进程可执行名会把 `Bunny` 显示成 `IMVIDEO`（用户认不出的内部名）。

struct ProcessChip: View {
    let process: OccupyingProcess

    private var iconSize: CGFloat { DesignTokens.Size.processChipIcon }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            iconView
                .frame(width: iconSize, height: iconSize)
            Text(process.displayName)
                .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 3)
        .padding(.trailing, 9)
        // 内高固定为契约值：居中由 `.frame(height:)` 的结构保证，
        // 不靠上下不对称的 padding 凑（那会让内容在色块里下压）。
        .frame(height: DesignTokens.Size.processChipHeight)
        .background(
            Capsule(style: .continuous)
                .fill(DesignTokens.Palette.raised)
        )
        .shadow(
            color: DesignTokens.Elevation.e1.color,
            radius: DesignTokens.Elevation.e1.radius,
            y: DesignTokens.Elevation.e1.y
        )
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
    }

    /// 可访问性名称：磁盘映像前加种类前缀（VoiceOver 用户分不清「Game.dmg」
    /// 是个应用还是别的什么）；普通进程就是显示名。
    private var accessibilityName: String {
        switch process.kind {
        case .process:
            return process.displayName
        case .diskImage:
            return "\(L10n.tr(.diskImageKindLabel)) \(process.displayName)"
        }
    }

    /// 悬停提示：显示名与进程名一致时就是显示名；不一致时补上进程名。
    ///
    /// 这一行的价值是**让用户能自己验证**——磁盘明明是被 `Bunny` 占用的，
    /// 为什么在系统的进程列表里找不到 `Bunny`？因为它的可执行文件叫 `IMVIDEO`。
    ///
    /// **磁盘映像**：显示 backing 文件的完整路径——「是哪张映像在占」的唯一自证方式。
    private var tooltip: String {
        switch process.kind {
        case .diskImage:
            return process.path
        case .process:
            guard process.displayName != process.processName else { return process.displayName }
            return String(
                format: L10n.tr(.processExecutableNameFormat), process.displayName, process.processName)
        }
    }

    /// 应用图标；取不到时回落成 SF Symbol `app`。
    ///
    /// ## 那个回落分支什么时候才会走到（2026-09-17 补注）
    ///
    /// **只在「这个 PID 已经不在了」时** —— 不是「CLI 进程没有图标」。
    /// ``ProcessAppResolver/icon(for:)`` 的取值顺序是
    /// `appBundlePath ?? executablePath`，而生产路径上
    /// ``ProcessAppResolver/enrich(_:)`` 用 `proc_pidpath` 给**任何还活着的进程**都填上了
    /// `executablePath`（`/bin/sleep` 这种也有，见 `ProcessAppResolverTests`）。
    /// 所以 `tail` / `ffmpeg` 这类 CLI 进程拿到的是**可执行文件自身的系统图标**，
    /// 不是这个灰色方框。
    ///
    /// ⚠️ **出图夹具踩过这个坑**：夹具的进程是编的（PID 501 / 5340…），本机并不存在
    /// → 两条路径都是 `nil` → 走查图上所有进程芯片都成了空方框，被读成「图标缺失」。
    /// 夹具已修（`SnapshotRenderTests.SampleApp`），接线由
    /// `ProcessChipLayoutTests.有应用身份时画真图标无身份时才回落` 守着。
    @ViewBuilder
    private var iconView: some View {
        if let icon = ProcessAppResolver.icon(for: process) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
        } else {
            Image(systemName: "app")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .frame(width: iconSize, height: iconSize)
        }
    }
}

/// 「还有 N 个」芯片（设计稿 `.chip--more`）：透明底 + 1px 描边。
struct ProcessChipOverflow: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: DesignTokens.FontSize.caption))
            .foregroundStyle(DesignTokens.Palette.mutedForeground)
            .padding(.horizontal, 10)
            .frame(height: DesignTokens.Size.processChipHeight)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DesignTokens.Palette.borderStrong, lineWidth: 1)
            )
            .accessibilityLabel("+\(count)")
    }
}

// MARK: - StorageMeter（容量条 + 百分比）
//
// 设计稿 `.meter`：轨道高 5 全圆角，右侧百分比**固定宽 34** —— 固定宽才能让
// 多行磁盘的百分比数字纵向对齐（数字用 `tabular-nums` 等宽）。
// 用量达到 ``DesignTokens/Threshold/meterHigh``（90%）时切琥珀（`.meter--high`）。
//
// ⚠️ **它不是规则的例外，是规则的实例**（2026-09-29 更正）。照 §2.1 那三条判据逐条核：
// ① 快满，不是失败，是受阻；② 用户不清它就不会自己变少；③ 清理由用户做（删文件 / 换盘）。
// 三条全中 ⇒ 用琥珀是**合法**的，不需要「唯一例外」这种豁免。
// 它同时**不参与「能否推出」的判定** —— 与「被占用」那一支的琥珀各说各的。
//
// ⚠️ 旧文写的是「D 节写着『琥珀只表示被占用』，并把这一处列为**唯一例外**」——
// 那句引用**已经失效**：D 节现在写的是三条判据，正文里的「唯一例外」措辞
// 已于 2026-09-29 删除。改动这一档之前读 `06-states.html` 的 D 节（判据）与 E 节（本实例）。

struct StorageMeter: View {
    let ratio: Double
    let accent: AccentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 这一档的用量算不算「高」。
    ///
    /// **阈值与判定都在 ``DesignTokens/Threshold``**，出处是设计稿 `06-states.html` 的
    /// `E · 容量条用量三档`（`data-meter-high="0.9"` + 30/70/95 三根条）。
    ///
    /// ⚠️ 这里**不写数字、也不写比较符**：原先这里是 `private let highThreshold = 0.9`
    /// 加一句 `ratio >= highThreshold` —— 注释还写着「设计稿 `.meter--high`」，而
    /// 2026-09-18 实扫发现设计稿里**一根 ≥90% 的条都没有**，那句注释是假的（§8.52.4）；
    /// 而且比较符落在视图里，`>=` 与 `>` 的差别**只有渲染才测得到**。
    /// 现在值由 `MeterThresholdParityTests` 双向盯着，等号由 ``DesignTokens/Threshold/meterIsHigh(_:)`` 自己承担。
    private var isHigh: Bool { DesignTokens.Threshold.meterIsHigh(ratio) }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Palette.subtle)
                    Capsule(style: .continuous)
                        .fill(isHigh ? DesignTokens.Palette.warning : accent.swiftUIColor)
                        .frame(width: max(0, min(1, ratio)) * geo.size.width)
                }
            }
            .frame(height: DesignTokens.Size.meterHeight)

            Text(percentText)
                .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(
                    isHigh ? DesignTokens.Palette.warningText : DesignTokens.Palette.mutedForeground
                )
                // 设计稿 `.meter` 实测高 16 = 百分比那一行的行盒（11pt × 1.45）。
                // 不加这一句时整个容量条只有 14（被 5pt 的轨道衬着看不出来），
                // 但磁盘行的总高会因此比设计稿矮 2pt —— 三块盘就是 6pt。
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                )
                .frame(width: DesignTokens.Size.meterPercentWidth, alignment: .trailing)
        }
        .animation(
            DesignTokens.Motion.animation(DesignTokens.Motion.slow, reduceMotion: reduceMotion),
            value: ratio
        )
        .accessibilityElement(children: .ignore)
        // 只报百分比：容量条拿不到「已用 / 剩余」字节数，硬塞 `usageFormat` 会读成
        // 「30.0% 已使用 ( / )」这种半截句子（实测过）。完整容量由同一行的 meta 文案承载，
        // 此处不必重复，免得 VoiceOver 把同一件事念两遍。
        .accessibilityLabel(String(format: L10n.tr(.usagePercentFormat), ratio * 100))
    }

    private var percentText: String {
        String(format: "%.0f%%", ratio * 100)
    }
}

// MARK: - CapacityBadge（总容量徽标）
//
// 设计稿 `.row__fs`：11/500、`bg-subtle` 全圆角、`tabular-nums`。
// 总容量从「meta 行里的一段文字」提为**名称右侧的徽标**，
// 因为它属于「身份」层（这是哪块盘），而 meta 行留给「已用/剩余」（变化更快的信息）。
//
// **行高也要跟着设计稿走**：`.row__fs` 实测 18 高（11pt 的行盒 16 + 上下各 1 内边距）。
// 用自然行高时只有 16，徽标比磁盘名矮一截，与名称基线对齐时会显得「贴不住」。

struct CapacityBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(DesignTokens.Palette.mutedForeground)
            .designLineHeight(DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote)
            .padding(.horizontal, 7)
            .background(
                Capsule(style: .continuous).fill(DesignTokens.Palette.subtle)
            )
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - TextLinkButton（行尾文字链接）
//
// 设计稿设置面板的 `.linkbtn`：`12 / 500`、强调色、**图标在文字右侧**（`gap:4`、svg 12）。
//
// **为什么不能拿 `ActionButton(variant: .ghost)` 顶替**：那是按钮 —— 有 26pt 的固定高度
// 与 10pt 的左右内边距，图标默认在**左**。设计稿这一处是**行内链接**：实测控件盒只有
// 88 × 17（文字 + 12pt 图标，没有按钮内边距）。用按钮会让设置行右侧多出一块
// 视觉重量，并把这个控件从「链接」读成「按钮」——VoiceOver 的角色也会跟着变。

struct TextLinkButton: View {
    let title: String
    var systemImage: String?
    var accent: AccentColor = .default
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                    // 下划线是 hover 的唯一反馈（设计稿 `.linkbtn:hover`）——
                    // 链接没有底色可改，不加这一条鼠标移上去毫无变化。
                    .underline(hovering)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(accent.swiftUIColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRing()
        .onHover { hovering = $0 }
        .animation(
            DesignTokens.Motion.animation(DesignTokens.Motion.fast, reduceMotion: reduceMotion),
            value: hovering
        )
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - NoticeBanner（顶部横幅）
//
// 设计稿 `.banner`：整条横向铺满。两种语义：`.warning`（未授权，需要用户行动）/
// `.success`（刚授权成功，确认反馈）。
//
// **两者的描边不同**：琥珀是上下各一条 0.5px，成功是一圈完整的 0.5px —— 见
// ``topHairline`` / ``ring`` 的注释。
//
// **文字是正文色而不是语义色**（设计稿 `.banner__text { color: var(--text-1) }`）：
// 语义由底色 + 图标承载就够了，文字再染成琥珀/绿色反而把对比度从 16:1 拉到 4.6:1，
// 而且一屏里出现两处彩色文字会让「哪里真的需要我动手」变模糊。
//
// **高度由内容决定，不设 minHeight**：设计稿里未授权横幅是 46（因为右侧有 26pt 的按钮
// 撑着），授权成功横幅只有 37（没有按钮）。给它钉一个 46 的 `minHeight` 会让
// 后者凭空高出 9pt —— 一条只闪 3 秒的绿条没必要和带按钮的那条一样高。

struct NoticeBanner: View {
    enum Kind {
        case warning
        case success
    }

    let kind: Kind
    let icon: String
    /// ⚠️ 类型是 `Text` 而**不是 `String`** —— 由**调用方**决定要不要走
    /// ``MarkdownCopy/text(_:)``。理由是只有调用方知道这条文案的**值里有没有 `**`**：
    /// `fdaBannerLead` 有（设计稿里那一句是粗体），`fdaGrantedBanner` 没有。
    ///
    /// **曾经是 `String` + 内部 `Text(message)`** —— 那样渲染是**原样**的，
    /// 于是 `fdaBannerLead` 在界面上显示成 `…才能看到**是谁占用了磁盘**`（裸星号）。
    /// 见 §8.78。
    let message: Text
    var actionTitle: String?
    var accent: AccentColor = .default
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            // 设计稿 `.banner__icon` 是 16 × 16 的固定列（svg 尺寸）。
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            message
                .font(.system(size: DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.caption
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                ActionButton(
                    title: actionTitle,
                    variant: .outline,
                    size: .small,
                    accent: accent,
                    action: action
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, 10)
        .background(background)
        .overlay(alignment: .top) { topHairline }
        .overlay(alignment: .bottom) { bottomHairline }
        .overlay { ring }
        .accessibilityElement(children: .combine)
    }

    private var background: Color {
        switch kind {
        case .warning: return DesignTokens.Palette.warningSoft
        case .success: return DesignTokens.Palette.successSoft
        }
    }
    private var iconColor: Color {
        switch kind {
        case .warning: return DesignTokens.Palette.warning
        case .success: return DesignTokens.Palette.success
        }
    }

    /// 琥珀横幅的描边 = **上下各一条 0.5px**（设计稿 `.banner` 的
    /// `inset 0 -0.5px 0, inset 0 0.5px 0`），读作「插进来的一条」。
    @ViewBuilder
    private var topHairline: some View {
        if kind == .warning { Hairline(color: DesignTokens.Palette.warningLine) }
    }
    @ViewBuilder
    private var bottomHairline: some View {
        if kind == .warning { Hairline(color: DesignTokens.Palette.warningLine) }
    }

    /// 成功横幅的描边 = **一圈完整的 0.5px**（设计稿 `04-onboarding.html` 里
    /// 那条成功横幅的 `box-shadow: inset 0 0 0 0.5px var(--ok-line)`），
    /// 读作「一个已经确认的块」。
    ///
    /// **两种语义的描边方式在设计稿里就是不同的**，不是笔误：琥珀条是「插进来的」，
    /// 成功条是「确认好的」。曾经两者都画上下两条线 —— 成功横幅左右两侧没有边界，
    /// 绿底在窗口边缘「化」进背景里，看起来像没画完。
    @ViewBuilder
    private var ring: some View {
        if kind == .success {
            Rectangle().strokeBorder(DesignTokens.Palette.successLine, lineWidth: 0.5)
        }
    }
}

// MARK: - SkeletonRow（首屏骨架）
//
// 设计稿 §5.3：磁盘枚举通常 < 50ms，骨架屏**只在超过 300ms** 时出现，避免闪烁。
// 这个阈值由调用方（``ContentView``）用延迟控制，组件本身只负责长相。

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.subtle)
                .frame(
                    width: DesignTokens.Size.diskIconContainer,
                    height: DesignTokens.Size.diskIconContainer)
            VStack(alignment: .leading, spacing: DesignTokens.Size.rowIdGap) {
                bar(width: 140, height: 14)
                bar(width: 200, height: 11)
            }
            Spacer(minLength: 0)
            bar(width: 72, height: DesignTokens.Size.buttonSmallHeight)
        }
        .padding(DesignTokens.Size.rowPadding)
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
            .fill(DesignTokens.Palette.subtle)
            .frame(width: width, height: height)
    }
}

// MARK: - EmptyStateView（空状态）
//
// 设计稿 `.empty`：**不用警告色**（不是出错，是还没开始）；
// 文案要提前解释筛选规则（「系统盘与网络卷不会被列出」），
// 消灭用户「插了盘却看不到」的困惑。

struct EmptyStateView: View {
    let systemName: String
    let title: String
    let description: String
    let actionTitle: String
    let actionSystemImage: String?
    let action: () -> Void
    let accent: AccentColor

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Spacer(minLength: 0)
            IconBadge(systemName: systemName, style: .emptyArt, accent: accent)
                .padding(.bottom, DesignTokens.Spacing.sm)
            Text(title)
                .font(.system(size: DesignTokens.FontSize.title, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
            Text(description)
                .font(.system(size: DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, DesignTokens.Spacing.sm)
            ActionButton(
                title: actionTitle,
                systemImage: actionSystemImage,
                variant: .outline,
                size: .small,
                accent: accent,
                action: action
            )
            .padding(.top, DesignTokens.Spacing.md)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.xxxl)
    }
}
