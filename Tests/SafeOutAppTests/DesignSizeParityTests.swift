import Foundation
import Testing

@testable import SafeOutApp

/// 设计稿 `ds.css` 与实现 `DesignTokens.Size` 的**尺寸同源契约**。
///
/// ## 为什么要有这一层
///
/// 「同一个事实写在两个地方」在本仓库出过四次，每次都是**同一个病**：
/// 两边各自的文档里写着「另一边还没同步」，而**没有任何机制提醒谁去还这笔账**。
///
/// | # | 事实 | 症状 | 出处 |
/// |---|---|---|---|
/// | 1 | 设置面板高 | 设计稿 826 / 实现 800，**分叉了整整一轮**（2026-09-18 拍板统一成 800，§8.43） | 旧守卫在 `SettingsLayoutTests` |
/// | 2 | 标题栏高 52 | `32 + 20 = 52` 内部自洽，**但 52 本身没有出处** —— 设计稿改成 56 时实现照样绿 | 旧守卫在 `TitleBarBaselineTests` |
/// | 3 | 菜单栏面板宽 360 | 断言写成 `#expect(s.width == 360)` —— **拿常量跟自己比**（§8.51 明令禁止），设计稿改成 380 时照样绿 | §8.71 |
/// | 4 | 主窗口 800×520 | **两头都没钉**：实现注释写着「设计稿硬性规格」，但没有任何一处去读那个「稿」 | §8.71 |
///
/// §8.71 先把这 7 项收成一张表；**§8.72 把这条轴铺开**：`DesignTokens.Size` 里声称
/// 「设计稿 …」的常量有 **62 个**，而当时被钉住的只有 7 个。
///
/// ## 铺开时撞到的第二层：不是每一项都钉得住
///
/// 实扫 62 项后分出两类，**硬钉数值会在第二类中立刻产生假失败**：
///
/// - **钉得住**（45 项）：设计稿里有一个明确的声明处，取值口径固定。
///   包括要**解析 CSS 变量**的那些（`padding: var(--s-3)` ⇒ 12px）。
/// - **钉不住**（26 项）：三种情形 —— ① 实测取整（169.47 → 169，见清单 #17）；
///   ② 算出来的（54 = 按钮 30 + 内边距 12 + 12）；③ 真相写在 HTML 的**内联 style** 里
///   （56 / 44），不在 `ds.css`。
///
/// ⇒ 所以这张表**不是「全部比数值」**，而是：**能钉的钉数值，钉不了的写理由**。
/// 「写理由」不是走过场 —— ``钉不了的项必须写明理由()`` 盯着它，
/// 否则「钉不了」会变成偷懒的垃圾桶。
///
/// ## 判据（改这张表前先读）
///
/// - **判「两边相等」，不是「等于 800」**：后者在有人把两边**同时**改成 900 时依然会红 ——
///   那是假失败，会把下一个人引向错误方向（§8.51「拿常量跟自己比 = 没牙」）。
/// - **读设计稿的源文件**（`ds.css` / `DesignTokens.swift`），不是常量自己跟自己比。
/// - ⚠️ token 一律写**声明处**（`--w-main:` 带冒号）：使用处是 `var(--w-main)`，
///   而它上方那段注释里还写着 800 / 826 —— 全文搜数字会搜到注释里的那个。
/// - ⚠️ 规则型（`.rule`）**只在那个块内**找，否则会一路找到后面别的类里的同名属性。
struct DesignSizeParityTests {

    // MARK: - 同源表

    /// 设计稿那一头的**取值位置**。
    private enum Locator: Sendable {
        /// CSS 变量**声明处**（`--w-main:` 带冒号）。`nth` = 取第几个 px 值。
        case token(String, nth: Int = 1)
        /// 规则块内的属性（`.callout {` 里的 `padding:`）。`nth` = 取第几个 px 值
        /// （`padding: 9px 11px` ⇒ nth=1 是 9、nth=2 是 11）。
        case rule(String, String, nth: Int = 1)
    }

    private struct Pair: Sendable {
        /// 展示用的键（报错信息里出现）。
        let key: String
        /// `DesignTokens.Size` 里的**常量名**（账本按它对齐；`CGSize` 那两个有两行共用一名）。
        let constant: String
        /// 设计稿那一头。**`nil` = 钉不住**（`why` 里必须写清为什么）。
        let locator: Locator?
        /// 实现那一头。**写成闭包是为了每次现取**：写 `{ 800 }` 就又变回「常量跟自己比」。
        let actual: @Sendable () -> CGFloat
        let label: String
        /// 出处（钉得住的）/ 钉不住的理由（钉不住的）。
        let why: String
    }

    /// 唯一的账本。**增删尺寸常量必须同时动这里和设计稿** —— 只动一边，本文件的守卫会红。
    private static let pairs: [Pair] = [

        // ---- 窗口 / 面板 ----
        Pair(
            key: "--w-main", constant: "mainWindow", locator: .token("--w-main:"),
            actual: { DesignTokens.Size.mainWindow.width },
            label: "主窗口宽", why: "设计稿 `--w-main: 800px`"),
        Pair(
            key: "--h-main", constant: "mainWindow", locator: .token("--h-main:"),
            actual: { DesignTokens.Size.mainWindow.height },
            label: "主窗口高", why: "设计稿 `--h-main: 520px`"),
        Pair(
            key: "--w-popover", constant: "menuPopoverWidth", locator: .token("--w-popover:"),
            actual: { DesignTokens.Size.menuPopoverWidth },
            label: "菜单栏面板宽", why: "设计稿 `--w-popover: 360px`"),
        // ⚠️ 这里原有 `--w-settings`（720）/ `--h-settings`（440）两条，**v3 删除**：
        // 它们钉的是 `settingsPanel` —— v2 **独立设置窗口**的尺寸。
        // v3 把设置并进主窗口详情区之后没有「面板尺寸」这个量：画布由窗口
        // （``mainWindow``）与侧栏（``mainSidebarWidth``）决定，高度由工具栏决定，
        // 内容超出走滚动（HANDOFF §5：「这条夹逼约束整个作废」）。
        // 两个令牌也已从 `DesignTokens` 删除。
        // ds.css 里它们仍在（v3 稿子整份沿用了 v2 的令牌表）⇒ 已登记进 ``retiredSizeTokens``。
        Pair(
            key: "--h-titlebar", constant: "titleBarHeight", locator: .token("--h-titlebar:"),
            actual: { DesignTokens.Size.titleBarHeight },
            label: "标题栏高", why: "设计稿 `--h-titlebar: 52px`"),
        // ---- 侧栏（v3：主窗口的分类栏） ----
        //
        // ⚠️ **同一个 `.sside` 类在两代稿子里是两样东西**：
        // v2 的 `09-settings-split.html` 里它是**设置窗口**的左栏（自绘 —— 所以要算项高、
        // 图标、间距、内边距）；v3 稿子里它是**主窗口**的侧栏
        // （`NSSplitViewItem(sidebarWithViewController:)` + `List(selection:)`），几何全归系统。
        //
        // ⇒ 只有**宽度**这一条还值得钉：它决定详情区有多宽，而详情区宽是所有折行的前提 ——
        // 一漂，一整片高度契约跟着漂，而**没有任何东西会报错**。
        // 项高 / 图标 / 间距 / 内边距那 5 条随 `settingsSidebar*` 令牌一起删除：
        // 那些数字现在由 AppKit 排版，我们一行外观代码都不写（HANDOFF §3.3）。
        Pair(
            key: ".sside width", constant: "mainSidebarWidth",
            locator: .rule(".sside", "width:"),
            actual: { DesignTokens.Size.mainSidebarWidth },
            label: "侧栏面板宽",
            why: """
                设计稿 `.sside { width: 200px }`。⚠️ 200 是**面板本体**，不是外沿 ——
                系统再整体内缩 8pt（统一工具栏 + 全高布局），外沿因此落在 8→208pt，
                详情区左缘是 208 而不是 200。
                """),
        Pair(
            key: "–", constant: "sidebarRowVerticalInset", locator: nil,
            actual: { DesignTokens.Size.sidebarRowVerticalInset },
            label: "侧栏行额外内距",
            why: """
                14：**这不是设计稿的值，是本轮按用户反馈定的产品口味值**（2026-10-01，
                用户反馈「左栏选择项分布不均、下边空了一大块」）。设计稿
                `.sside__item { height: 28px }` 描述的是「行高整体交还系统」那个口径；
                本常量是**在系统内距之上再叠**的一段（实测把 AppKit 给的行高
                32pt 撑到 43.5pt，底部空白占比 47% → 31%），设计稿里**没有对应物**
                —— 硬钉会逼着稿子去写一个它不该管的数。
                来龙去脉与「另外两条路为什么走不通」见
                `DesignTokens/Size/sidebarRowVerticalInset`。
                """),
        Pair(
            key: ".win border", constant: "glassBorderWidth",
            locator: .rule(".win", "border:"),
            actual: { DesignTokens.Size.glassBorderWidth },
            label: "窗口描边宽", why: "设计稿 `.win { border: 0.5px solid … }`"),

        // ---- 推出弹窗 ----
        Pair(
            key: ".alert width", constant: "alertWidth",
            locator: .rule(".alert", "width:"),
            actual: { DesignTokens.Size.alertWidth },
            label: "弹窗宽", why: "设计稿 `.alert { width: 400px }`（不是 CSS 变量，直接写在类里）"),
        Pair(
            key: ".alert__icon width", constant: "alertIconContainer",
            locator: .rule(".alert__icon", "width:"),
            actual: { DesignTokens.Size.alertIconContainer },
            label: "弹窗图标容器", why: "设计稿 `.alert__icon { width: 38px }`"),
        Pair(
            key: ".alert__icon svg width", constant: "alertIconSize",
            locator: .rule(".alert__icon svg", "width:"),
            actual: { DesignTokens.Size.alertIconSize },
            label: "弹窗图标", why: "设计稿 `.alert__icon svg { width: 20px }`"),
        Pair(
            key: ".alert__item .appicon width", constant: "alertProcessIcon",
            locator: .rule(".alert__item .appicon", "width:"),
            actual: { DesignTokens.Size.alertProcessIcon },
            label: "进程行应用图标", why: "设计稿 `.alert__item .appicon { width: 18px }`"),
        Pair(
            key: ".callout padding 1", constant: "calloutPaddingV",
            locator: .rule(".callout", "padding:", nth: 1),
            actual: { DesignTokens.Size.calloutPaddingV },
            label: "警示块纵向内边距", why: "设计稿 `.callout { padding: 9px 11px }` 第 1 个数"),
        Pair(
            key: ".callout padding 2", constant: "calloutPaddingH",
            locator: .rule(".callout", "padding:", nth: 2),
            actual: { DesignTokens.Size.calloutPaddingH },
            label: "警示块横向内边距", why: "设计稿 `.callout { padding: 9px 11px }` 第 2 个数"),
        Pair(
            key: ".callout svg width", constant: "calloutIconSize",
            locator: .rule(".callout svg", "width:"),
            actual: { DesignTokens.Size.calloutIconSize },
            label: "警示块图标", why: "设计稿 `.callout svg { width: 14px }`"),

        // ---- 授权引导 ----
        Pair(
            key: ".onboard__icon width", constant: "onboardingIconContainer",
            locator: .rule(".onboard__icon", "width:"),
            actual: { DesignTokens.Size.onboardingIconContainer },
            label: "引导图标容器", why: "设计稿 `.onboard__icon { width: 52px }`"),
        Pair(
            key: ".onboard__icon svg width", constant: "onboardingIconSize",
            locator: .rule(".onboard__icon svg", "width:"),
            actual: { DesignTokens.Size.onboardingIconSize },
            label: "引导图标", why: "设计稿 `.onboard__icon svg { width: 26px }`"),
        Pair(
            key: ".onboard__icon margin", constant: "onboardingIconBottomGap",
            locator: .rule(".onboard__icon", "margin:"),
            actual: { DesignTokens.Size.onboardingIconBottomGap },
            label: "引导图标下间距", why: "设计稿 `margin: 0 auto var(--s-3)` ⇒ 12px（**要解析变量**）"),
        Pair(
            key: ".step__dot width", constant: "onboardingStepDot",
            locator: .rule(".step__dot", "width:"),
            actual: { DesignTokens.Size.onboardingStepDot },
            label: "步骤圆点", why: "设计稿 `.step__dot { width: 22px }`"),
        Pair(
            key: ".step gap", constant: "onboardingStepGap",
            locator: .rule(".step", "gap:"),
            actual: { DesignTokens.Size.onboardingStepGap },
            label: "步骤间距", why: "设计稿 `.step { gap: var(--s-3) }` ⇒ 12px"),
        Pair(
            key: ".step__text padding-bottom", constant: "onboardingStepTextPaddingBottom",
            locator: .rule(".step__text", "padding-bottom:"),
            actual: { DesignTokens.Size.onboardingStepTextPaddingBottom },
            label: "步骤文字下内边距", why: "设计稿 `.step__text { padding-bottom: var(--s-3) }`"),
        Pair(
            key: ".step__line width", constant: "onboardingStepLineWidth",
            locator: .rule(".step__line", "width:"),
            actual: { DesignTokens.Size.onboardingStepLineWidth },
            label: "步骤连接线宽", why: "设计稿 `.step__line { width: 1.5px }`"),
        Pair(
            key: ".step__line min-height", constant: "onboardingStepLineHeight",
            locator: .rule(".step__line", "min-height:"),
            actual: { DesignTokens.Size.onboardingStepLineHeight },
            label: "步骤连接线高", why: "设计稿 `.step__line { min-height: 16px }`"),
        Pair(
            key: ".step__line margin", constant: "onboardingStepLineMargin",
            locator: .rule(".step__line", "margin:"),
            actual: { DesignTokens.Size.onboardingStepLineMargin },
            label: "步骤连接线外边距", why: "设计稿 `.step__line { margin: 2px 0 }`"),
        Pair(
            key: ".step__text small margin-top", constant: "onboardingNoteTopGap",
            locator: .rule(".step__text small", "margin-top:"),
            actual: { DesignTokens.Size.onboardingNoteTopGap },
            label: "步骤小字上间距", why: "设计稿 `.step__text small { margin-top: 2px }`"),
        Pair(
            key: ".path border-radius", constant: "onboardingPathRadius",
            locator: .rule(".path", "border-radius:"),
            actual: { DesignTokens.Size.onboardingPathRadius },
            label: "路径块圆角", why: "设计稿 `.path { border-radius: var(--r-xs) }` ⇒ 4px"),
        Pair(
            key: ".path padding 1", constant: "onboardingPathPaddingV",
            locator: .rule(".path", "padding:", nth: 1),
            actual: { DesignTokens.Size.onboardingPathPaddingV },
            label: "路径块纵向内边距", why: "设计稿 `.path { padding: 1px 5px }` 第 1 个数"),
        Pair(
            key: ".path padding 2", constant: "onboardingPathPaddingH",
            locator: .rule(".path", "padding:", nth: 2),
            actual: { DesignTokens.Size.onboardingPathPaddingH },
            label: "路径块横向内边距", why: "设计稿 `.path { padding: 1px 5px }` 第 2 个数"),

        // ---- 磁盘行 / 菜单行 / 紧凑行 ----
        Pair(
            key: "--sz-diskicon", constant: "diskIconContainer",
            locator: .token("--sz-diskicon:"),
            actual: { DesignTokens.Size.diskIconContainer },
            label: "磁盘行图标容器", why: "设计稿 `--sz-diskicon: 40px`"),
        Pair(
            key: ".mrow__icon width", constant: "menuIconContainer",
            locator: .rule(".mrow__icon", "width:"),
            actual: { DesignTokens.Size.menuIconContainer },
            label: "菜单行图标容器", why: "设计稿 `.mrow__icon { width: 32px }`"),
        Pair(
            key: ".mrow__icon svg width", constant: "menuIconSize",
            locator: .rule(".mrow__icon svg", "width:"),
            actual: { DesignTokens.Size.menuIconSize },
            label: "菜单行图标", why: "设计稿 `.mrow__icon svg { width: 17px }`"),
        Pair(
            key: ".mrow__icon border-radius", constant: "menuIconRadius",
            locator: .rule(".mrow__icon", "border-radius:"),
            actual: { DesignTokens.Size.menuIconRadius },
            label: "菜单行图标圆角", why: "设计稿 `.mrow__icon { border-radius: var(--r-sm) }` ⇒ 6px"),
        Pair(
            key: ".crow__icon width", constant: "compactIconContainer",
            locator: .rule(".crow__icon", "width:"),
            actual: { DesignTokens.Size.compactIconContainer },
            label: "紧凑行图标容器", why: "设计稿 `.crow__icon { width: 30px }`"),
        Pair(
            key: ".row padding", constant: "rowPadding",
            locator: .rule(".row", "padding:"),
            actual: { DesignTokens.Size.rowPadding },
            label: "磁盘行内边距", why: "设计稿 `.row { padding: var(--s-3) }` ⇒ 12px"),
        Pair(
            key: ".row__main gap", constant: "rowColumnGap",
            locator: .rule(".row__main", "gap:"),
            actual: { DesignTokens.Size.rowColumnGap },
            label: "磁盘行主列间距", why: "设计稿 `.row__main { gap: 7px }`"),
        Pair(
            key: ".row__id gap", constant: "rowIdGap",
            locator: .rule(".row__id", "gap:"),
            actual: { DesignTokens.Size.rowIdGap },
            label: "磁盘行标识间距", why: "设计稿 `.row__id { gap: 3px }`"),
        Pair(
            key: ".evid padding 1", constant: "evidencePaddingTop",
            locator: .rule(".evid", "padding:", nth: 1),
            actual: { DesignTokens.Size.evidencePaddingTop },
            label: "证据区上内边距", why: "设计稿 `.evid { padding: var(--s-2) … }` ⇒ 8px"),
        Pair(
            key: ".evid padding 2", constant: "evidencePaddingH",
            locator: .rule(".evid", "padding:", nth: 2),
            actual: { DesignTokens.Size.evidencePaddingH },
            label: "证据区横向内边距", why: "设计稿 `.evid { padding: … var(--s-3) … }` ⇒ 12px"),
        Pair(
            key: ".evid padding 3", constant: "evidencePaddingBottom",
            locator: .rule(".evid", "padding:", nth: 3),
            actual: { DesignTokens.Size.evidencePaddingBottom },
            label: "证据区下内边距", why: "设计稿 `.evid { padding: … var(--s-3) }` ⇒ 12px"),
        Pair(
            key: ".evid__chips margin-top", constant: "evidenceHeadGap",
            locator: .rule(".evid__chips", "margin-top:"),
            actual: { DesignTokens.Size.evidenceHeadGap },
            label: "证据区芯片上间距", why: "设计稿 `.evid__chips { margin-top: var(--s-2) }` ⇒ 8px"),
        Pair(
            key: ".meter__track height", constant: "meterHeight",
            locator: .rule(".meter__track", "height:"),
            actual: { DesignTokens.Size.meterHeight },
            label: "容量条高", why: "设计稿 `.meter__track { height: 5px }`"),
        Pair(
            key: ".meter__pct width", constant: "meterPercentWidth",
            locator: .rule(".meter__pct", "width:"),
            actual: { DesignTokens.Size.meterPercentWidth },
            label: "百分比标签宽", why: "设计稿 `.meter__pct { width: 34px }`（固定宽才能纵向对齐）"),

        // ---- 菜单栏面板内 ----
        Pair(
            key: ".mbtn svg width", constant: "menuEjectIconSize",
            locator: .rule(".mbtn svg", "width:"),
            actual: { DesignTokens.Size.menuEjectIconSize },
            label: "菜单推出图标", why: "设计稿 `.mbtn svg { width: 14px }`"),
        Pair(
            key: ".pop__appicon svg width", constant: "popoverAppIconSize",
            locator: .rule(".pop__appicon svg", "width:"),
            actual: { DesignTokens.Size.popoverAppIconSize },
            label: "占用应用图标", why: "设计稿 `.pop__appicon svg { width: 13px }`"),
        Pair(
            key: ".iconbtn width", constant: "popoverIconButton",
            locator: .rule(".iconbtn", "width:"),
            actual: { DesignTokens.Size.popoverIconButton },
            label: "面板图标按钮", why: "设计稿 `.iconbtn { width: 28px }`"),
        Pair(
            key: ".empty__art svg width", constant: "menuEmptyArtIcon",
            locator: .rule(".empty__art svg", "width:"),
            actual: { DesignTokens.Size.menuEmptyArtIcon },
            label: "空状态图标", why: "设计稿 `.empty__art svg { width: 36px }`"),

        // ---- 其它组件 ----
        // ⚠️ 这里原有 `.iconbtn width (标题栏)` ↔ `titleBarIconButton`（28），**v3 删除**：
        // 自绘的标题栏图标按钮已退役（刷新搬进系统 `NSToolbar`，位置与尺寸由系统给），
        // 令牌随之删除。面板那个 `.iconbtn`（``popoverIconButton``）另有登记，不受影响。
        Pair(
            key: ".empty__art width", constant: "emptyArtSize",
            locator: .rule(".empty__art", "width:"),
            actual: { DesignTokens.Size.emptyArtSize },
            label: "空状态大图标容器", why: "设计稿 `.empty__art { width: 76px }`"),
        Pair(
            key: ".chip height", constant: "processChipHeight",
            locator: .rule(".chip", "height:"),
            actual: { DesignTokens.Size.processChipHeight },
            label: "进程芯片高", why: "设计稿 `.chip { height: 26px }`"),
        Pair(
            key: ".popup height", constant: "popUpHeight",
            locator: .rule(".popup", "height:"),
            actual: { DesignTokens.Size.popUpHeight },
            label: "下拉框高", why: "设计稿 `.popup { height: 28px }`"),
        Pair(
            key: ".swatch width", constant: "swatchSize",
            locator: .rule(".swatch", "width:"),
            actual: { DesignTokens.Size.swatchSize },
            label: "强调色色板", why: "设计稿 `.swatch { width: 22px }`"),

        // ---- 钉不住的：实测取整 / 算出来的 / 真相在内联 style ----
        Pair(
            key: "–", constant: "confirmDialogMaxWidth", locator: nil,
            actual: { DesignTokens.Size.confirmDialogMaxWidth },
            label: "确认对话框上限",
            why: "420 是**实现侧的兜底上限**，设计稿只声明了 400（= alertWidth）—— 没有第二个真相"),
        Pair(
            key: "–", constant: "alertFootHeight", locator: nil,
            actual: { DesignTokens.Size.alertFootHeight },
            label: "弹窗操作区高",
            why: "54 = 按钮 30 + 上下内边距 12+12，**算出来的**；`.alert__foot` 只写了 padding 变量"),
        Pair(
            key: "–", constant: "alertProcessRowHeight", locator: nil,
            actual: { DesignTokens.Size.alertProcessRowHeight },
            label: "进程行高",
            why: "29 = padding 5+5 + 内容 19，**算出来的**"),
        Pair(
            key: "–", constant: "onboardingPanelWidth", locator: nil,
            actual: { DesignTokens.Size.onboardingPanelWidth },
            label: "引导面板宽",
            why: """
                380 现在只写在 `04-onboarding.html` 的**内联 style** 里 ——
                ds.css 的 `.onboard` 已改成 `width: 100%`（843 行记录了为什么）。
                实现注释仍指向那条**已不存在**的规则：这是第 5 例「改一处漏一处」。
                """),
        Pair(
            key: "–", constant: "onboardingStepRailWidth", locator: nil,
            actual: { DesignTokens.Size.onboardingStepRailWidth },
            label: "步骤轨道宽",
            why: "`.step__rail` **没有 width 声明**（宽度由 flex 决定）"),
        Pair(
            key: "–", constant: "titleBarBandHeight", locator: nil,
            actual: { DesignTokens.Size.titleBarBandHeight },
            label: "标题栏内容带高",
            why: "与 `titleBarHeight` 是**同一个事实**（52），不重复钉"),
        Pair(
            key: "–", constant: "titleBarBandBottomPadding", locator: nil,
            actual: { DesignTokens.Size.titleBarBandBottomPadding },
            label: "内容带下留白",
            why: "0：实现侧的对齐补偿，设计稿没有这一项"),
        // ⚠️ 这里原有 `titleBarInsetCenter`（26）与 `systemTrafficLightCenterFromLeft`（16）
        // 两条，**v3 删除**（令牌一起删的）：它们钉的是「**我们自己**把交通灯与标题栏按钮
        // 对齐到 26pt 中心」这件事 —— v3 之后那件事整个归了 AppKit
        // （统一工具栏下系统自己把灯居中到 26pt）。理由见 `DesignTokens` 里对应位置的说明。
        Pair(
            key: "–", constant: "systemTrafficLightCenterFromTop", locator: nil,
            actual: { DesignTokens.Size.systemTrafficLightCenterFromTop },
            label: "系统交通灯纵向位置",
            why: "**系统实测值**（标准 28pt 标题栏那套），不是设计稿给的数"),
        // 1 条，**v3 删除**（令牌一起删的）：`hoverBackgroundInset`（悬停背景内缩 3pt）——
        // v3 交还系统样式后 hover 反馈归系统，那个内缩量没有对象了。
        // 理由见 `DesignTokens` 里对应位置的说明。
        Pair(
            key: "–", constant: "diskRowBusyHeight", locator: nil,
            actual: { DesignTokens.Size.diskRowBusyHeight },
            label: "完整行·忙态高",
            why: "169：设计稿**实测 169.47 取整**（清单 #17）—— 硬比小数会假红"),
        Pair(
            key: "–", constant: "diskRowSafeHeight", locator: nil,
            actual: { DesignTokens.Size.diskRowSafeHeight },
            label: "完整行·可推出高",
            why: "127：实测 **127.47** 取整"),
        Pair(
            key: "–", constant: "diskRowUnknownHeight", locator: nil,
            actual: { DesignTokens.Size.diskRowUnknownHeight },
            label: "完整行·未知高",
            why: "133：实测 **133.47** 取整"),
        Pair(
            key: "–", constant: "compactRowHeight", locator: nil,
            actual: { DesignTokens.Size.compactRowHeight },
            label: "紧凑行高",
            why: "46：实测值（padding 8+8 + 内容 30），CSS 无声明"),
        Pair(
            key: "–", constant: "menuRowHeight", locator: nil,
            actual: { DesignTokens.Size.menuRowHeight },
            label: "菜单行高",
            why: "69：实测 **68.72** 取整"),
        Pair(
            key: "–", constant: "menuActionRowHeight", locator: nil,
            actual: { DesignTokens.Size.menuActionRowHeight },
            label: "菜单动作行高",
            why: "32：**算出来的**（padding 7+7 + 内容）"),
        Pair(
            key: "–", constant: "compactRowThreshold", locator: nil,
            // ⚠️ 它是 `Int`（唯一一个非 CGFloat）—— 不转会编译不过。
            actual: { CGFloat(DesignTokens.Size.compactRowThreshold) },
            label: "紧凑行阈值",
            why: "4：**块数阈值**，不是尺寸（设计稿 §3.3）"),
        Pair(
            key: "–", constant: "compactNameMaxWidth", locator: nil,
            actual: { DesignTokens.Size.compactNameMaxWidth },
            label: "紧凑行名称截断宽",
            why: """
                190：设计稿里 190 是 `.chip`（进程芯片）的 `max-width`，**不是紧凑行名称** ——
                实现注释指向的出处是错的。**别照着这个注释去改设计稿。**
                """),
        Pair(
            key: "–", constant: "menuEmptyArtSize", locator: nil,
            actual: { DesignTokens.Size.menuEmptyArtSize },
            label: "菜单空状态容器",
            why: "56：写在 `02-menu-bar.html` 的**内联 style** 里（覆盖 ds.css 的 76），不在 `ds.css`"),
        Pair(
            key: "–", constant: "aboutPaneIcon", locator: nil,
            actual: { DesignTokens.Size.aboutPaneIcon },
            label: "「关于」页图标容器",
            why: """
                76：写在 `ds.css` 的 `.aboutpane__icon`（两栏形态，`09-settings-split.html`）。
                单栏版曾有一对 `aboutRowIcon`(44) / `aboutRowHeight`(70)，2026-09-29 随
                「关于」横排一行那个形态一起退役 —— 两栏的「关于」独占一页、是居中大图标。
                """),
        Pair(
            key: "–", constant: "rowBusyBarWidth", locator: nil,
            actual: { DesignTokens.Size.rowBusyBarWidth },
            label: "完整行琥珀条宽",
            why: "3：清单 #13 记过「三种行各有自己的规格」一度接错行；设计稿出处**待核对**"),
        Pair(
            key: "–", constant: "menuBusyBarWidth", locator: nil,
            actual: { DesignTokens.Size.menuBusyBarWidth },
            label: "菜单行琥珀条宽",
            why: "2.5：**已知渲染不出来**（清单 #14）—— 钉了只会假红"),
        Pair(
            key: "–", constant: "busyBarRadius", locator: nil,
            actual: { DesignTokens.Size.busyBarRadius },
            label: "琥珀条圆角",
            why: "2：设计稿写的是 `0 2px 2px 0` 简写，没有独立声明"),
        Pair(
            key: "–", constant: "settingsProgressLineHeight", locator: nil,
            actual: { DesignTokens.Size.settingsProgressLineHeight },
            label: "设置进度行高",
            why: "16：`.progressline` 在 ds.css 里**没有声明**，待核对"),
        Pair(
            key: "–", constant: "processChipIcon", locator: nil,
            actual: { DesignTokens.Size.processChipIcon },
            label: "进程芯片图标",
            why: "20：`.chip` 块里没有图标尺寸声明，待核对"),
        Pair(
            key: "–", constant: "swatchRingOffset", locator: nil,
            actual: { DesignTokens.Size.swatchRingOffset },
            label: "色板选中描边偏移",
            why: "4：设计稿没有对应声明，待核对"),
    ]

    // MARK: - 守卫

    /// 钉得住的每一项，设计稿那一头与实现那一头**必须同数**。
    ///
    /// ⚠️ 判据只能是「**两边相等**」。写成「等于 800」的话，有人把两边**同时**改成 900
    /// 依然会红 —— 那是假失败，会把下一个人引向错误方向（§8.51）。
    @Test func 设计稿与实现的尺寸必须同数() throws {
        let css = try loadCSS()
        let pinned = Self.pairs.filter { $0.locator != nil }
        var bad: [String] = []
        for p in pinned {
            guard let loc = p.locator else { continue }
            let design = try #require(
                Self.value(loc, in: css),
                "设计稿里取不到 \(p.key) 的值 —— 选择器/属性改名了就要同步这张表")
            let impl = p.actual()
            if design != Double(impl) {
                bad.append("\(p.label)：设计稿 \(p.key) = \(design)px，实现 \(p.constant) = \(impl)pt")
            }
        }
        print(
            "  [尺寸同源] 钉住 \(pinned.count) 项 ｜ 登记为钉不住 "
                + "\(Self.pairs.count - pinned.count) 项")
        #expect(
            bad.isEmpty,
            """
            设计稿与实现不同数（\(bad.count) 处）：
            \(bad.joined(separator: "\n"))
            改一边就要改另一边，别在文档里留一句「另一边还没同步」（§8.43 分叉一整轮的教训）。
            """)
        // 负向锚：表被删空了，上面的循环一次都不跑，照样「全绿」。
        #expect(pinned.count >= 40, "只钉住 \(pinned.count) 项 —— 有人删行没补回来")
        #expect(
            pinned.allSatisfy { $0.actual() > 0 },
            "有取到 0 的项 —— 常量改名或注掉了，这里会假装一致")
    }

    /// 钉不住的项**必须写明理由** —— 否则「钉不了」会变成偷懒的垃圾桶。
    ///
    /// ⚠️ 顺带钉住「理由不能是空话」：少于 8 个字视为没写。
    @Test func 钉不了的项必须写明理由() {
        let sloppy = Self.pairs.filter { $0.locator == nil && $0.why.count < 8 }
        #expect(
            sloppy.isEmpty,
            """
            这些「钉不住」的项没写清为什么：\(sloppy.map(\.constant).joined(separator: "、"))。
            写清楚是「实测取整」「算出来的」还是「真相在内联 style」 ——
            下一个人才知道这笔账该不该还、怎么还。
            """)
    }

    /// 设计稿里**新声明**的 `--w-*` / `--h-*` 令牌，必须登记进同源表。
    ///
    /// 只查「同数」的话，有人在 `ds.css` 里加一个 `--w-onboard: 380px`
    /// 而实现里没有对应常量 —— 表里没有这一项，同数守卫**一条都不会红**。
    @Test func 设计稿新声明的尺寸令牌必须登记进同源表() throws {
        let css = try loadCSS()
        let declared = Self.declaredSizeTokens(in: css)
        // 负向锚：正则扫不到东西时，差集是空的 —— 通过得毫无意义。
        #expect(
            declared.count >= 6,
            "只扫到 \(declared.count) 个 --w-* / --h-* 令牌 —— 解析口径失效（假绿）")

        let orphans = declared.subtracting(Self.sizeTokenKeys)
            .subtracting(Self.retiredSizeTokens).sorted()
        #expect(
            orphans.isEmpty,
            """
            ds.css 声明了这些尺寸令牌，但同源表里没有：\(orphans.joined(separator: "、"))。
            要么给它在 `DesignTokens.Size` 里配一个常量并登记进 `pairs`，
            要么说明它为什么不需要两边一致 —— **不要**放着不管，那正是 §8.43 的病。
            （若它属于「设计稿仍声明、而 v3 已确认不再需要」，登记进 `retiredSizeTokens`。）
            """)
    }

    /// 同源表里**登记了但设计稿已经没有**的令牌，要回来划掉。
    ///
    /// 只查一个方向的表会像 §8.33 那 6 条一样：**还了账没人回来划**。
    @Test func 同源表里已经不存在的令牌要划掉() throws {
        let css = try loadCSS()
        let declared = Self.declaredSizeTokens(in: css)
        #expect(declared.count >= 6, "只扫到 \(declared.count) 个尺寸令牌 —— 解析口径失效（假绿）")

        let stale = Self.sizeTokenKeys.subtracting(declared).sorted()
        #expect(
            stale.isEmpty,
            """
            同源表里记着 \(stale.joined(separator: "、"))，但 ds.css 里已经没有这几个令牌了。
            把 `pairs` 里对应那几行删掉 —— 留着它们会让「新令牌必须登记」这条守卫失去意义。
            """)
    }

    /// 同一个尺寸令牌**只能声明一次**。
    ///
    /// ⚠️ 这不是洁癖：`value` 取的是「token 之后第一个 px」，
    /// 若 `:root[data-theme="dark"]` 里又写了一遍 `--w-main`，取到哪个取决于文件顺序 ——
    /// 而**同数守卫照常绿**（取的仍是一个真实存在的值，只是不是你想的那个）。
    /// 这种「取到错误但仍自洽」的失败，比取不到更难发现。
    @Test func 设计稿的尺寸令牌不能声明两次() throws {
        let css = try loadCSS()
        var duplicated: [String] = []
        for key in Self.sizeTokenKeys.sorted() {
            let needle = key + ":"
            let n = css.components(separatedBy: needle).count - 1
            if n != 1 { duplicated.append("\(key)（\(n) 次）") }
        }
        #expect(
            duplicated.isEmpty,
            """
            这些令牌在 ds.css 里声明了不止一次：\(duplicated.joined(separator: "、"))。
            守卫取的是第一次出现的值 —— 深色主题里覆盖一份会让「同数」比错对象而照样绿。
            """)
    }

    /// `DesignTokens.Size` 里**注释声称来自设计稿**的常量，必须登记进同源表。
    ///
    /// 这是本轮真正要堵的口子：§8.71 只钉了 7 项，而写下「（设计稿 …）」的常量有 62 个 ——
    /// **每一次新增都是在还不知道有这张表的情况下发生的**。这一条让它不可能再发生：
    /// 新常量只要注释里写了「设计稿」，就必须同时登记（钉数值或写理由，二选一）。
    ///
    /// ⚠️ 口径：注释块 =「上一个常量声明之后到本声明之前」的整段文本。
    /// 与 `pairs.constant` 对齐的是**常量名**，不是行数。
    @Test func 声称来自设计稿的常量必须登记进同源表() throws {
        let declared = Self.sizeConstants(in: try loadTokens(), designDocOnly: true)
        #expect(
            declared.count >= 50,
            "只扫到 \(declared.count) 个「注释含设计稿」的常量 —— 解析口径失效（假绿）")

        let known = Set(Self.pairs.map(\.constant))
        let missing = declared.subtracting(known).sorted()
        #expect(
            missing.isEmpty,
            """
            这些常量注释里写着「设计稿 …」，但同源表里没有：\(missing.joined(separator: "、"))。
            在 `pairs` 里补一行 —— 能钉数值的给 `locator`，钉不住的 `locator: nil` **并写明为什么**。
            别让「还没登记」变成默认状态：那正是 §8.71 之前 62 项里只钉了 7 项的原因。
            """)
    }

    /// 同源表里**登记了但那个常量已经不存在**的，要回来划掉。
    ///
    /// ⚠️ 这里比对的是**全体**常量（`designDocOnly: false`），不是「注释含设计稿」那一批：
    /// 表里有 `alertIconSize`、`menuPopoverWidth` 这类**共享注释**的项（它们上面那一段
    /// 注释是别人的，自己没写），用「含设计稿」的集合比对会把它们全报成「已不存在」。
    /// **假失败比漏报更伤** —— 它会让下一个人去删掉一行正确的登记。
    @Test func 同源表里已经不存在的常量要划掉() throws {
        let all = Self.sizeConstants(in: try loadTokens(), designDocOnly: false)
        #expect(all.count >= 60, "只扫到 \(all.count) 个常量 —— 解析口径失效（假绿）")

        let stale = Set(Self.pairs.map(\.constant)).subtracting(all).sorted()
        #expect(
            stale.isEmpty,
            """
            同源表里记着 \(stale.joined(separator: "、"))，但 `DesignTokens.Size` 里
            已经没有这几个常量了（改名或删了）。把 `pairs` 里对应行删掉。
            """)
    }

    // MARK: - 解析

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

    private func loadTokens() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Views/DesignTokens.swift"),
            encoding: .utf8)
    }

    /// 同源表里**尺寸令牌型**那几项的键（`--w-main` 这种，**不含冒号** ——
    /// 与 `declaredSizeTokens` 口径一致，否则两条差集守卫会**永远为空而全绿**）。
    ///
    /// 只收 `--w-*` / `--h-*`：像 `--sz-diskicon` 这样的图标令牌不在反向扫描范围内
    /// （它由「同数」守卫的 `#require` 兜底 —— 取不到就抛）。
    private static var sizeTokenKeys: Set<String> {
        var out: Set<String> = []
        for p in pairs {
            guard case .token(let t, _) = p.locator else { continue }
            let n = t.hasSuffix(":") ? String(t.dropLast()) : t
            if n.hasPrefix("--w-") || n.hasPrefix("--h-") { out.insert(n) }
        }
        return out
    }

    /// **设计稿仍声明、而实现已经没有对应物**的尺寸令牌 —— 显式注销，不再要求两边同数。
    ///
    /// ## 为什么需要这张表（v3，2026-09-30）
    ///
    /// `ds.css` 是**设计系统**的令牌表，而 v3 稿子是「复制 v2 再改」⇒ 令牌表被整份沿用，
    /// 它**仍然声明着** `--w-settings` / `--h-settings`。但 v3 已经**没有独立设置窗口**，
    /// `DesignTokens` 里的 `settingsPanel` 也随之删除（见那里的注释）。
    ///
    /// 这两条**不是**「有人忘了登记」，是「设计稿侧还留着历史令牌」：
    /// 让它们留在 `pairs` 里做不到（常量已不存在，`actual` 无物可指），
    /// 而直接删条目又会让 ``设计稿新声明的尺寸令牌必须登记进同源表()`` 变红
    /// （它们会从差集里冒出来）。⇒ 显式注销：守卫继续拦**真的新**令牌，账记在这里。
    ///
    /// ⚠️ **往这里加东西要慎重** —— 它等于「放弃两边同数」。
    /// 只在「设计稿仍声明、而 v3 已确认不再需要」时写，并说清原因。
    private static let retiredSizeTokens: Set<String> = [
        // v2 独立设置窗口的尺寸。v3 把设置并进主窗口详情区 ⇒ 没有「面板尺寸」这个量
        // （HANDOFF §5：「这条夹逼约束整个作废」）。
        "--w-settings",
        "--h-settings",
    ]

    private static func value(_ locator: Locator, in css: String) -> Double? {
        switch locator {
        case .token(let t, let nth):
            guard let decl = declaration(in: css, after: t) else { return nil }
            return nthPx(in: resolveVars(decl, in: css), nth: nth)
        case .rule(let selector, let property, let nth):
            guard
                let body = blockBody(in: css, selector: selector),
                let decl = declaration(in: body, after: property)
            else { return nil }
            return nthPx(in: resolveVars(decl, in: css), nth: nth)
        }
    }

    /// 取 `marker` **之后**到分号 / 行尾 / 块尾的文本（就是那个属性值）。
    ///
    /// ⚠️ 只在 marker 之后找 —— token 上方那段注释里还写着 800 / 826，
    /// 全文搜数字会搜到注释里的那个，于是「改了 CSS 不改注释」也照样绿。
    private static func declaration(in text: String, after marker: String) -> String? {
        guard let r = text.range(of: marker) else { return nil }
        let rest = text[r.upperBound...]
        var end = rest.endIndex
        for stop in [";", "\n", "}"] {
            if let s = rest.range(of: stop), s.lowerBound < end { end = s.lowerBound }
        }
        return String(rest[rest.startIndex..<end])
    }

    /// 取 `selector { … }` 的块体（**只取第一个**，我们的块里没有嵌套规则）。
    ///
    /// ⚠️ 选择器后面要能接 `{`：`.callout {` 不会误匹配 `.callout svg {`。
    /// ⚠️ **必须允许花括号前有任意空白**：`ds.css` 里为了对齐写着 `.row__id   {`
    /// （三个空格）—— 按 `.row__id {` 精确匹配会**找不到**，而那种失败看起来
    /// 像「设计稿里没这个声明」，会把人引向错误方向。
    private static func blockBody(in css: String, selector: String) -> String? {
        let needle = NSRegularExpression.escapedPattern(for: selector) + #"\s*\{"#
        guard let open = css.range(of: needle, options: .regularExpression) else { return nil }
        let rest = css[open.upperBound...]
        guard let close = rest.range(of: "}") else { return nil }
        return String(rest[..<close.lowerBound])
    }

    /// 把 `var(--x)` 一层层换成 `--x` 的声明值。
    ///
    /// **为什么必须做**：`.onboard__icon { margin: 0 auto var(--s-3) }`、
    /// `.step { gap: var(--s-3) }` 这类写法才是设计稿的常态 ——
    /// 不解析变量的话，表就只剩那些「碰巧写死数字」的项，覆盖不到真正容易漂的地方。
    /// ⚠️ 限 4 层：写错成循环引用时不会把测试挂死。
    private static func resolveVars(_ text: String, in css: String, depth: Int = 0) -> String {
        guard depth < 4 else { return text }
        guard
            let m = text.range(of: #"var\(\s*(--[A-Za-z0-9_\-]+)\s*\)"#, options: .regularExpression)
        else { return text }
        let whole = String(text[m])
        let name =
            whole
            .replacingOccurrences(of: "var(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)
        let resolved = declaration(in: css, after: name + ":") ?? ""
        return resolveVars(
            text.replacingOccurrences(of: whole, with: resolved), in: css, depth: depth + 1)
    }

    /// 取解析后的属性值里第 `nth` 个 `<数字>px`（1-based）。
    ///
    /// `padding: 9px 11px` ⇒ nth=1 → 9、nth=2 → 11；
    /// `margin: 0 auto 12px` ⇒ 第 1 个 **带 px 的**数是 12（裸 `0` 不算）。
    private static func nthPx(in text: String, nth: Int) -> Double? {
        guard nth >= 1 else { return nil }
        var found: [Double] = []
        var search = text[text.startIndex...]
        while let m = search.range(of: #"[0-9]+(?:\.[0-9]+)?px"#, options: .regularExpression) {
            if let v = Double(text[m].dropLast(2)) { found.append(v) }
            search = search[m.upperBound...]
        }
        return found.count >= nth ? found[nth - 1] : nil
    }

    /// 设计稿里**声明**的 `--w-*` / `--h-*` 令牌名（不含冒号）。
    private static func declaredSizeTokens(in css: String) -> Set<String> {
        var out: Set<String> = []
        let pattern = #"--[wh]-[a-z]+(?:-[a-z]+)*\s*:"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        for m in re.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            guard let r = Range(m.range, in: css) else { continue }
            let raw = css[r].trimmingCharacters(in: .whitespaces)
            out.insert(raw.hasSuffix(":") ? String(raw.dropLast()) : raw)
        }
        return out
    }

    /// `DesignTokens.Size` 里的常量名。
    ///
    /// - `designDocOnly: true` → 只要**注释含「设计稿」**的那些（正向守卫用）。
    /// - `designDocOnly: false` → 全部（反向「划掉」守卫用）。
    ///
    /// ⚠️ **两个方向要用不同的集合**，否则会互相打架（第一版就是两边都用
    /// 「注释含设计稿」，于是共享注释的 `alertIconSize` / `menuPopoverWidth` 等 13 项
    /// 被反向守卫当成「已经不存在的常量」—— 那是**假红**，报的是解析口径的错，不是真问题）。
    ///
    /// ⚠️ 口径：注释块 =「上一个声明之后到本声明之前」的整段文本。
    /// 共享注释的常量（紧跟在别人注释后面、自己没有注释的，如 `alertIconSize`）
    /// 在 `designDocOnly: true` 下**扫不到** —— 它们由「同数」守卫覆盖，不要求登记。
    private static func sizeConstants(in source: String, designDocOnly: Bool) -> Set<String> {
        guard
            let start = source.range(of: "enum Size {"),
            let end = source[start.upperBound...].range(of: "\n    }")
        else { return [] }
        let body = String(source[start.upperBound..<end.lowerBound])
        guard let re = try? NSRegularExpression(pattern: #"static let (\w+)\s*[:=]"#) else {
            return []
        }
        let matches = re.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var out: Set<String> = []
        var previousEnd = body.startIndex
        for m in matches {
            guard
                let r = Range(m.range, in: body),
                let nameRange = Range(m.range(at: 1), in: body)
            else { continue }
            let doc = body[previousEnd..<r.lowerBound]
            previousEnd = r.upperBound
            if !designDocOnly || doc.contains("设计稿") { out.insert(String(body[nameRange])) }
        }
        return out
    }
}
