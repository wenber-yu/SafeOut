import AppKit
import SwiftUI

/// 全局设计令牌（与设计稿统一规范的视觉常量集中声明处）。
///
/// **单一事实来源**：`Design/ui/v2/`（`index.html` 为总览入口）。
/// 本文件是设计稿里 `assets/ds.css` 的 Swift 侧镜像 —— 两边数值必须一致，
/// 改设计稿时同步改这里，不要各写一份。
///
/// **为什么不再用「系统色 + 半透明」拼视觉**：旧实现用 `Color.primary.opacity(0.06)`
/// 这类派生色，导致同一语义（如「被占用」）在不同视图里透明度各不相同，
/// 且小号文字的对比度没人核算过。现在所有语义色都以**具体 hex + 明暗两套**声明，
/// 对比度在设计稿阶段逐项核算过（WCAG AA），实现侧只取值、不再自创。
///
/// **实现策略**：
/// - 语义色用 `NSColor(name:dynamicProvider:)` 做明暗自适应，无需把 `colorScheme`
///   一路透传到每个子视图，也不会漏掉某处忘记适配深色。
/// - 毛玻璃按 macOS 版本优雅降级：15+ 用 `.ultraThinMaterial`（接近 Liquid Glass），
///   14 用 `.regularMaterial` 兜底。
enum DesignTokens {

    // MARK: 圆角

    /// 设计稿 §2.4。命名与 `ds.css` 的 `--r-*` 一一对应。
    enum Radius {
        /// 4 —— 芯片内的小标、行内小按钮。
        static let xs: CGFloat = 4
        /// 6 —— 按钮、分段选项。
        static let sm: CGFloat = 6
        /// 10 —— 磁盘行、证据区、设置卡片、图标容器。
        static let md: CGFloat = 10
        /// 14 —— 菜单栏面板、弹窗、引导面板。
        static let lg: CGFloat = 14
        /// 18 —— 空状态大图标容器。
        static let xl: CGFloat = 18
        /// 999 —— 容量条、芯片、开关、色板（用 `Capsule()` 表达，此处仅作语义索引）。
        static let full: CGFloat = 999

        // ⚠️ 这里原有 `window`（12）与 `settings`（= `window`）两个令牌，**v3 删除**。
        //
        // 它们描述的是「我们自己给窗口画的 12pt 外圆角」——设在 `contentView.layer` 上，
        // 好让玻璃卡片的圆角与窗口四角重合。
        //
        // v3 起窗口圆角**归窗口服务器**（HANDOFF §3.7.2 第 1 类口径：窗口 / 浮岛 /
        // 系统控件三类一律「什么都不做」），而且它**既不是常数、也读不到**：
        // 实测同一台机器、同样尺寸，只差窗口配置就得到 **31.5pt**（统一工具栏 + 全高）
        // 与 17.5pt（普通标题栏）两档；想读回来时 `NSThemeFrame.layer.cornerRadius`
        // 恒为 0（HANDOFF §3.7.1 与红线 R6）。
        // 自绘一个 12pt 只会在四角切出一个比窗口更小的圆、把窗口底露出来。

        // ⚠️ **v3 退役：`concentric(inset:)`（2026-09-30）**
        // 「底色内缩后圆角跟着缩」的同心圆角函数，唯一消费者是已退役的
        // `HoverBackground`（见 `Size` 里 `hoverBackgroundInset` 的退役说明）。
        // hover 反馈交还系统后，这个函数没有调用方了 —— 一并删除。
    }

    // MARK: 间距（4pt 基准）

    /// 设计稿 §2.3：`4 / 8 / 12 / 16 / 20 / 24 / 32`。
    enum Spacing {
        /// 4 —— 图标与文字、芯片间距。
        static let xs: CGFloat = 4
        /// 8 —— 按钮间距、行间距。
        static let sm: CGFloat = 8
        /// 12 —— 行内边距、图标与文本列间距。
        static let md: CGFloat = 12
        /// 16 —— 列表左右内边距、卡片内边距。
        static let lg: CGFloat = 16
        /// 20 —— 窗口内边距、弹窗内边距。
        static let xl: CGFloat = 20
        /// 24 —— 引导面板内边距。
        static let xxl: CGFloat = 24
        /// 32 —— 空状态横向留白。
        static let xxxl: CGFloat = 32

        // ⚠️ 这里原有 `titleBarTrailing`（12），**v3 删除**。
        //
        // 它是「标题栏右侧留白」，用来让**自绘的设置按钮**光学中心落在距右 26pt
        // （与红灯中心距左 26pt 对称）。v3 把自绘头部五件套整体退役之后：
        // 标题栏里**没有按钮了** —— 刷新按钮搬进系统 `NSToolbar` 的尾端，
        // 位置与留白全由 AppKit 决定；设置入口移进侧栏。
        // ⇒ 这个留白没有消费者，也没有设计稿依据可挂。
    }

    // MARK: 字号

    /// 设计稿 §2.2。数值即 pt，字重在使用处给出。
    enum FontSize {
        /// 20 / 600 —— ⚠️ **零消费者，且设计稿也没用过它**。
        ///
        /// 2026-09-18 实扫：`Sources/` 里没有一处引用它。原先这里写的是
        /// 「弹窗、引导主标题」—— **那是一句假话**：弹窗标题实际用 ``title``（15）、
        /// 引导页标题用 ``heading``（17），都没有 20。
        /// 设计稿侧 `ds.css` 也只在令牌表里**声明**了 `--fs-20`，任何页面都没应用。
        ///
        /// **保留**（不删）的理由：本文件是 `ds.css` 的镜像，`--fs-20` 还在设计稿的档位表里；
        /// 删掉会让「两边数值必须一致」这句话出现缺口。**但别把它读成「某处在用 20pt」。**
        static let display: CGFloat = 20
        /// 17 / 600 —— 引导页标题。
        static let heading: CGFloat = 17
        /// 15 / 600 —— 磁盘名、窗口标题、弹窗标题。
        static let title: CGFloat = 15
        /// 13 / 600 —— 紧凑行磁盘名、设置项标签。
        static let bodyStrong: CGFloat = 13
        /// 13 / 400 —— 设置项、动作行、正文。
        static let body: CGFloat = 13
        /// 12 / 400 —— 容量、说明、弹窗正文。
        static let caption: CGFloat = 12
        /// 11 / 400 —— 状态、百分比、快捷键。
        static let footnote: CGFloat = 11
        /// 11 / 600 —— 分组标题（配 `tracking`）。
        static let groupTitle: CGFloat = 11

        // ⚠️ 2026-09-18 实扫删除：这里原有 9 个「兼容旧命名」的语义别名
        // （`titleBar` / `diskCardName` / `capacity` / `processTag` / `primaryButton` /
        //  `menuDiskName` / `menuDiskMeta` / `menuTitle` / `settingsTitle`）。
        // 它们声明的存在理由是「语义等价，**保留以免调用点大改**」——
        // 而实扫（`.build/probe/keyref_scan.py`）发现**调用点是 0**：迁移早就做完了，
        // 别名只是留了下来。**注释里的理由被证伪 ⇒ 令牌即死代码**，故删。
        // 视图要用语义名时，上表里已有对应档位（如「菜单栏磁盘名」= ``bodyStrong``）。
    }

    // MARK: 行高

    /// 设计稿的行高倍数（`ds.css` 里的 `line-height`）。
    ///
    /// **为什么行高要单独建一组令牌、而不是让 SwiftUI 用默认值**：
    /// CSS 的 `line-height` 是**行盒高度**，对每一行（含第一行）都生效；
    /// SwiftUI 的 `Text` 用的是字体的**自然行高**，`lineSpacing` 只补**行与行之间**。
    /// 两者对 12pt 文字相差 3pt/行 —— 单行看不出来，一个三行的提示块就差 9pt，
    /// 弹窗整体高度会偏出十几 pt（实测 A 变体多 17pt、B 变体少 11pt）。
    /// 所以按设计稿的倍数显式声明，配合 ``SwiftUI/View/designLineHeight(_:fontSize:)`` 使用。
    enum LineHeight {
        /// 1.3 —— 弹窗标题（15 → 19.5）。
        static let tight: CGFloat = 1.3
        /// 1.45 —— 页面正文基准（`ds.css` 的 `body`，分组头 / 进程行 / 小标都用它）。
        static let base: CGFloat = 1.45
        /// 1.5 —— 弹窗正文与提示块。
        static let relaxed: CGFloat = 1.5
        /// 1.55 —— 「可能的原因」清单（设计稿里是行内 `line-height:1.55`）。
        static let loose: CGFloat = 1.55
        /// 1.6 —— 引导面板的说明段（设计稿 `.onboard__desc { line-height: 1.6 }`）。
        ///
        /// 这是全设计稿最大的一档行高，只用在「居中、两行以上、需要慢慢读」的段落上。
        static let spacious: CGFloat = 1.6
    }

    /// 系统字体的自然单行高度（**实测值**，不是算出来的）。
    ///
    /// **为什么要写死一张表**：`lineSpacing` 补的是行间距，要算「该补多少」就必须先知道
    /// 系统给这个字号的自然行高。而它并不是字号的简单倍数 —— 实测 11→14、12→15、
    /// 13→16、15→19，比值在 1.23~1.27 之间来回跳。乘一个系数会在某些字号上差 1pt。
    /// `AlertLayoutTests.自然行高表与实测一致` 会真的量一遍来守住这张表。
    static func naturalLineHeight(_ fontSize: CGFloat) -> CGFloat {
        switch fontSize {
        case 11: return 14
        case 12: return 15
        case 13: return 16
        case 15: return 19
        default: return (fontSize * 1.25).rounded()
        }
    }

    // MARK: 尺寸

    /// 设计稿里量出来的硬性规格。**改任何数值前先看注释里的依据**。
    enum Size {
        /// 主窗口尺寸（设计稿硬性规格）。
        static let mainWindow = CGSize(width: 800, height: 520)

        /// v3 主窗口侧栏面板的**本体**宽度（设计稿 `.win--v3 .sside { width: 200px }`）。
        ///
        /// ## ⚠️ 200 是面板本体，不是外沿 —— 别为了凑 208 改这个数
        ///
        /// 系统会在面板本体之外**再整体内缩 8pt**（四边：左 8 / 上 8 / 下 8），
        /// 于是**外沿**落在 `8 → 208`（本机实测，`.build/probe/v3_assemble/`）。
        /// 推论：**详情区左缘 = 208、可用宽 = 592**，
        /// 而不是「窗口 800 − 侧栏 200 = 600」——HANDOFF §5 那张表按 600 粗算，
        /// **少算了这 8pt 内缩**。以实测为准。
        ///
        /// ⛔ **不要写任何补偿代码**（不加宽侧栏、不改详情区内边距去凑 600/560）：
        /// 那 8pt 是系统材质浮岛的一部分，由窗口配置决定；
        /// 14–15 上没有浮岛 ⇒ 内缩为 0 ⇒ 补偿量在那一代**反而是错的**。
        /// 详情区宽度**由结构保证**，不写常量。
        static let mainSidebarWidth: CGFloat = 200

        /// v3 侧栏导航项的**额外垂直内距**（`listRowInsets` 的 top / bottom）：
        /// 每行在系统内距之上再加这么多，行高 **32 → 39.5pt**。
        ///
        /// ## 为什么破例给了一个「行内度量」（用户 2026-10-01 反馈）
        ///
        /// 侧栏行高原本是**整块交还系统**的（`HANDOFF.md` §3.3 / `DESIGN-SPEC.md` §10.4
        /// 那条「行高 / 行距 / 圆角 / hover 全部归系统，左栏不保留自定义规格」）。
        /// 破例的原因是一次逐像素实测（2x 截图，按窗口 ID 抓帧）：
        ///
        /// | 量 | 实测值 |
        /// |---|---|
        /// | 侧栏浮岛面板高 | **504pt**（y 8 → 511.5） |
        /// | 系统给的行高 / 行距 | **32pt**（六行中心等距 32） |
        /// | 最后一项「关于」下沿 | y ≈ **276** |
        /// | **底部空白** | **≈235pt = 面板的 47%** |
        ///
        /// 也就是说：**侧栏有接近一半是空的**，视觉上「六项挤在顶上、下面一大片」。
        /// 空白的绝对量是 235pt，而**行高每加 1pt 只能补回 6pt**（六个行）⇒
        /// 单纯调行距是**唯一**能动的杠杆，且效果是线性的：
        ///
        /// | `listRowInsets` 垂直值 | 行高 | 底部空白 | 占比 |
        /// |---|---|---|---|
        /// | 0（系统原值） | 32pt | 235pt | 47% |
        /// | **12（本值）** | **39.5pt（推算）** | **181pt（推算）** | **36%（推算）** |
        /// | 14（上一版） | 43.5pt | 157pt | 31% |
        ///
        /// ## 为什么从 14 降到 12（用户 2026-10-27 反馈）
        ///
        /// 用户原话：「设置窗口左侧的菜单项目的 hover 高度低一些」。
        /// 14 那一档虽然把底部空白压到 31%，但**行块（含 hover 底色）明显比系统侧栏厚**，
        /// 鼠标划过时像「大按钮」而不是列表项。12 是「往回收一档」：
        /// 行高 43.5 → **39.5pt**，仍高于系统 32pt、仍能把底部空白压在 ~36%，
        /// 保住了当初破例要解决的「六项挤顶上」问题，同时 hover 块回到更像桌面侧栏的厚度。
        ///
        /// ⚠️ **39.5 / 181 / 36% 是算出来的，不是重新量的**：
        /// 实测锚点只有上表那两个（0 → 32 / 235 / 47%，14 → 43.5 / 157 / 31%），
        /// 12 一档按「行高 = 内容自然高 + 2 × inset」的模型线性外推
        /// （`15.5 + 2 × 12 = 39.5`，底部空白 = 157 + 6 × 4 = 181）。
        /// 下次真机出图请顺手把这一行改成实测值。
        ///
        /// ⚠️ **行高是「内容高 + 上下内距」算出来的，不是一个能直接设的数**：
        /// 本机量到 `Label` 的自然高 ≈ 15.5pt ⇒ `15.5 + 2 × 14 ≈ 43.5`。
        /// 字号 / 图标尺寸一变，这个值要跟着重算（改完必须真机重量）。
        ///
        /// ⚠️ **不能无限往下压**：低于 ~8 时行高会跌破系统的 32pt 定值（内容被挤），
        /// 且 hover 底色会贴住文字墨迹 —— 12 是当前仍「看着不像被压扁」的安全档。
        ///
        /// ⚠️ **这是产品口味值，不是系统偏差**。它与「行高归系统」那条定调
        /// **是有冲突的**——本轮按用户反馈明确选择破例；想再调先改这张表并真机出图复核。
        ///
        /// ⛔ **别把「行高」当成唯一的旋钮 —— 另外两条路已探明走不通，不要再试**：
        /// - **收窗口高度**（曾评估 520 → 470）：被设计稿自己的三盘契约挡死 ——
        ///   `MenuDiskRowLayoutTests/主窗口放得下设计稿演示的三块盘` 把
        ///   `520 − 52(标题带) − 28(列表内边距) = 440` 钉成死线，而「1 块忙 + 2 块安全」
        ///   的行高之和恰好 440（= 设计稿 `.disklist [766 × 440]`）。**矮 1pt 就要出滚动条。**
        /// - **把「关于」沉到侧栏底部**：只是把空白从底端挪到中段，**总空白一点没少**，
        ///   还要把侧栏拆成两个 `List`（方向键不再跨组移动、VoiceOver 报两个列表）——
        ///   拿实打实的无障碍退化换一个「看起来分了组」，不划算。
        ///
        /// ⚠️ **别指望用内容 padding 撑高行**：实测 `.padding(.vertical,)` 与
        /// `environment(\.defaultMinListRowHeight,)` 对 sidebar 样式的行**都完全无效**，
        /// 只有 `listRowInsets` 生效（三次真机实验的记录在
        /// ``MainSidebarView/row(_:)`` 的文档注释里）。
        static let sidebarRowVerticalInset: CGFloat = 12

        /// 「设置」分组标题上方的**额外**间距（在系统分组间距之上再加）。
        ///
        /// 实测系统给的分组间距 = **18.5pt**（「外置磁盘」胶囊下沿 83.5 →
        /// 「设置」标题上沿 102）；加 10 之后标题墨迹落到 121.5，即约 28pt。
        /// 这让「磁盘」与「设置」两段之间的关系在视觉上断开得更明确 ——
        /// 与行高放大是同一件事的两面：**把内容占的纵向空间撑开**，
        /// 而不是把项均匀撒满整列（那会破坏 macOS 侧栏「一组紧凑项」的语义，
        /// 且单个 `List` 根本做不到底部对齐）。
        ///
        /// 实现上是给 `Section` 的 header 加 `.padding(.top,)` ——
        /// ⚠️ 它**不改变** header 的字号 / 字重 / 颜色（真机截图逐项核对过），
        /// 只把这一整个 block 往下推。
        static let sidebarGroupSpacingExtra: CGFloat = 10

        // ⚠️ 这里原有 `settingsPanel`（720×440）与 6 个 `settingsSidebar*` 令牌，**v3 删除**。
        //
        // 它们描述的是 v2 的**独立设置窗口**：「720 宽两栏、左栏 200、右栏内容 480」，
        // 以及把面板高度夹在「英文最坏高度」与「中文高度 + 40」之间那套推导
        // （最高一帧英文 384.22 ⇒ 440，余量 55.78）。
        //
        // v3 把主窗口与设置合并之后，**这套约束整个作废**（HANDOFF §5 原话）：
        //
        // - 设置不再是窗口，而是主窗口详情区**按分类切换的一页** ⇒ 没有「面板尺寸」这个量，
        //   画布由**窗口**（``mainWindow``）与**侧栏**（``mainSidebarWidth``）决定；
        // - 分类栏不再是自绘的 200pt 左栏，而是**系统侧栏**
        //   （`NSSplitViewItem(sidebarWithViewController:)` + `List(selection:)`）
        //   ⇒ 那 6 个 `settingsSidebar*` 的项高 / 图标 / 间距 / 内边距全归系统，
        //   我们一行外观代码都不写（HANDOFF §3.3）；
        // - 「高度由最坏语言决定」那条夹逼也随之消失：详情区高度固定（窗口 − 工具栏），
        //   内容超出走滚动，不再是「再加一行就无解」。
        //
        // ⚠️ **不要照抄那几个数字到别处**：v3 详情区宽度是
        // `800 − 200(侧栏本体) − 8(浮岛左内缩)` = **592**，与 720 无关
        // （那 8pt 的来龙去脉见 ``mainSidebarWidth``）。
        // 出图 / 量测需要的画布尺寸在**测试侧**按实测基准表达
        // （见 `SettingsLayoutTests` 的 `detailWidth`），不在这里固化成令牌 ——
        // 固化它等于把「26 有浮岛、14–15 没有」这件事写死进生产代码。
        /// 右栏内容区内边距（`.sdetail__body { padding: 20px 20px 16px }`）。
        static let settingsDetailPaddingTop: CGFloat = 20
        static let settingsDetailPaddingH: CGFloat = 20
        static let settingsDetailPaddingBottom: CGFloat = 16

        /// 菜单栏弹出面板宽度。
        static let menuPopoverWidth: CGFloat = 360
        /// 推出确认对话框最大宽度（设计稿 400，上限 420）。
        static let confirmDialogMaxWidth: CGFloat = 420

        /// 推出弹窗宽度（设计稿 `.alert { width: 400px }`，实测 400×330 / 400×314）。
        ///
        /// **为什么不是「由内容决定」**：设计稿把 400 定为硬规格（`03-eject-flow.html`
        /// 的 Handoff：「弹窗宽 400（最大 420）」），因为换行位置会影响「可能的原因」
        /// 那类长句的断行，宽度飘了断行就飘了。
        static let alertWidth: CGFloat = 400
        /// 弹窗图标容器 38 × 38，圆角 10，图标 20（设计稿 `.alert__icon`）。
        static let alertIconContainer: CGFloat = 38
        static let alertIconSize: CGFloat = 20
        /// 进程行高 29（设计稿 `.alert__item { padding: 5px 6px }` + 内容 19）。
        static let alertProcessRowHeight: CGFloat = 29
        /// 进程行内应用图标 18 × 18 圆角 4（设计稿 `.alert__item .appicon`）。
        static let alertProcessIcon: CGFloat = 18
        /// 警示块内边距 9 / 11（设计稿 `.callout { padding: 9px 11px }`）。
        static let calloutPaddingV: CGFloat = 9
        static let calloutPaddingH: CGFloat = 11
        /// 警示块图标 14（设计稿 `.callout svg { width: 14px }`）。
        static let calloutIconSize: CGFloat = 14
        /// 弹窗操作区高度（设计稿实测 54 = 按钮 30 + 上下内边距 12）。
        static let alertFootHeight: CGFloat = 54
        // MARK: 授权引导面板（设计稿 `04-onboarding.html`）

        /// 面板宽度（设计稿 `.onboard { width: 380px }`）。
        ///
        /// **为什么是硬规格而不是「由内容决定」**：说明文字是居中的两段，
        /// 宽度飘了断行就飘；第 1 步的路径小标实测 226pt，正好卡在 340pt 的内容宽里，
        /// 再窄一点它就会折行，三步的高度跟着一起变。
        static let onboardingPanelWidth: CGFloat = 380
        /// 顶部图标容器 52 × 52，圆角 14，图标 26（设计稿 `.onboard__icon`）。
        static let onboardingIconContainer: CGFloat = 52
        static let onboardingIconSize: CGFloat = 26
        /// 图标容器与标题之间 12（设计稿 `.onboard__icon { margin: 0 auto 12px }`）。
        static let onboardingIconBottomGap: CGFloat = 12
        /// 步骤序号圆点 22 × 22（设计稿 `.step__dot`，`border-radius: 999px`）。
        static let onboardingStepDot: CGFloat = 22
        /// 步骤编号列宽（设计稿 `.step__rail` 实测 22）。
        static let onboardingStepRailWidth: CGFloat = 22
        /// 连接线：宽 1.5、最小高 16、上下各 2 外边距（设计稿 `.step__line`）。
        static let onboardingStepLineWidth: CGFloat = 1.5
        static let onboardingStepLineHeight: CGFloat = 16
        static let onboardingStepLineMargin: CGFloat = 2
        /// 编号列与正文列的水平间距（设计稿 `.step { gap: 12px }`）。
        static let onboardingStepGap: CGFloat = 12
        /// 步骤正文底部内边距（设计稿 `.step__text { padding-bottom: 12px }`，
        /// 最后一步在设计稿里被行内样式改成 0）。
        static let onboardingStepTextPaddingBottom: CGFloat = 12
        /// 正文与其下方注释之间 2（设计稿 `.step__text small { margin-top: 2px }`）。
        static let onboardingNoteTopGap: CGFloat = 2
        /// 行内「路径」小标（设计稿 `.path`）：等宽 11、内边距 1/5、圆角 4。
        static let onboardingPathRadius: CGFloat = 4
        static let onboardingPathPaddingH: CGFloat = 5
        static let onboardingPathPaddingV: CGFloat = 1

        /// 标题栏**视觉总高**（设计稿 `.titlebar { height: 52px }`）。
        ///
        /// ⚠️ 它**不是**内容带的高度 —— 内容带是 ``titleBarBandHeight``。
        static let titleBarHeight: CGFloat = 52

        /// 标题栏**内容带**高度 —— 标题文字与图标按钮都在这条带子里垂直居中。
        ///
        /// **它就是设计稿的 52，不带留白**：设计稿 `.titlebar` 是
        /// `height: 52px; align-items: center`，DOM 探针实测三样东西的中心**全在 26pt** ——
        /// `.traffic`（红绿灯）`y 20 / 高 12`、`.titlebar__title` `y 15 / 高 22`、
        /// `.iconbtn` `y 12 / 高 28`。设置面板 `.shead` 同样是 26pt。
        ///
        /// ## 这里曾经是 32，而且那个数**是错的**
        ///
        /// 32 的来历是「迁就系统红绿灯」：macOS 把三个交通灯画在**距窗口顶 9pt** 处、
        /// 每个高 14pt（真机实测并集 `y 9…23`），垂直中心**距顶 16pt** —— 取 32 的带子
        /// 让内容居中后正好与灯同高。用户 2026-09-17 反馈「红绿灯、标题、按钮与窗口顶部
        /// 的距离与设计稿不一致」，量出来正是这 **10pt**。
        ///
        /// **迁就系统是不必要的**：`NSWindow.standardWindowButton` 的 frame 可以改，
        /// 实测（2026-09-17）改完在 run loop、key 切换、移动窗口、`setContentSize`
        /// 之后都不会被 AppKit 拨回去。所以正确做法是**把灯挪到设计稿要的 26pt**
        /// （见 ``trafficLightNudgeY``），而不是把标题拉到系统给的 16pt。
        ///
        /// ## ⚠️ 它同时是**窗口标题栏区域**的高度（2026-09-23 补）
        ///
        /// 「把灯挪到 26pt」这句话**当时只对了一半**：挪是挪到了（`frame` 层面
        /// 一直是 26.0pt），但 macOS 的标准标题栏只有 **28pt** 高、且
        /// `NSTitlebarView.masksToBounds == true` ⇒ 中心 26pt 的灯要占 y ∈ [18, 34]，
        /// **底部 6pt 落在区域之外、被裁掉**。真机实测墨迹 **24×16px**（本该 24×24），
        /// 三个灯看起来都是「半圆」—— 2026-09-23 用户反馈的正是这个。
        ///
        /// ⇒ 修法 ``AppDelegate/enlargeTitleBar(in:)``：把 `NSTitlebarView` 与容器
        /// 一起加高到**这个 52**，顶部贴住窗口顶 ⇒ 系统标题栏区域与设计稿的内容带
        /// **重合**。于是这个常量有**两个消费者**（内容带排版 / 标题栏区域高度），
        /// 而不是两个同值的常量各写一处。
        static let titleBarBandHeight: CGFloat = 52

        /// 内容带下方的留白，使标题栏**视觉总高**保持设计稿的 52pt（52 + 0）。
        ///
        /// 现在是 0 —— 内容带已经吃满整个 52pt。留着这个常量是为了
        /// 「内容带 + 留白 == 标题栏总高」这条自洽关系仍有一个显式的位置，
        /// 也免得将来有人想加回留白时直接把 52 改成 32（那会重新引入这 10pt 偏差）。
        static let titleBarBandBottomPadding: CGFloat = 0

        /// 系统**默认**把交通灯画在距窗口顶多高处（垂直中心）。
        ///
        /// **实测值，不要凭印象改**：macOS 26.7 上三个按钮的并集是 `y 9…23`（窗口坐标，
        /// 原点在左下 → 距顶 9pt），高 14pt，中心 **16pt**。
        /// 系统用的是「标准 28pt 标题栏」那一套位置，跟设计稿的 52pt 无关。
        static let systemTrafficLightCenterFromTop: CGFloat = 16

        // ⚠️ 这里原有三个令牌，**v3 删除**：
        // - `titleBarIconButton`（28，自绘标题栏图标按钮的盒子）；
        // - `titleBarInsetCenter`（26，红绿灯与自绘设置按钮的**光学中心**距窗口边）；
        // - `systemTrafficLightCenterFromLeft`（16，系统把红灯画在距左多远处的实测值）。
        //
        // 三者的共同前提是「**我们自己**把红绿灯与标题栏按钮摆到设计稿的位置」：
        // 要量系统默认值、算差额、再把按钮盒子对齐到同一个 26pt 中心。
        //
        // v3 之后**这件事整个归了 AppKit**：统一工具栏 + `fullSizeContentView` + 全高布局
        // 这套配置下，系统自己把红绿灯居中到 **26pt**（实测，HANDOFF §3.1.1），
        // 而标题栏里已经没有我们的按钮了（刷新按钮搬进 `NSToolbar` 尾端，位置由系统给）。
        // ⇒「要挪多少」「要对齐到哪」这两个问题都不存在了，三个令牌一起失去对象。
        //
        // 判据也没丢：真机自检 ``WindowSelfCheck/checkTrafficLightBaseline`` 每次量三个灯的
        // 中心、仍然钉住 **26pt** —— 它读的是**渲染结果**，不是这几个常量。

        // ⚠️ **v3 退役：`hoverBackgroundInset`（2026-09-30）**
        // 「hover 底色比按钮盒子内缩 3pt」是一次有意偏离设计稿的用户偏好
        // （2026-09-16「hover 效果背景小一点」，依据 `DESIGN-SPEC.md` §8.19），
        // 由 `HoverBackground` 实现。v3 交还系统样式后 hover 反馈归系统
        // （macOS 26 = Liquid Glass；14–15 = 系统高亮），`HoverBackground`
        // 与这个内缩量一起失去消费者 —— 删除。若再遇「系统 hover 不合意」，
        // 先从 git 历史读当时的取舍，别凭空自绘。

        /// 磁盘行图标容器（设计稿 40 × 40，圆角 10）。
        static let diskIconContainer: CGFloat = 40
        /// 菜单栏磁盘行图标容器（设计稿 32 × 32）。
        static let menuIconContainer: CGFloat = 32
        /// 菜单栏磁盘行图标容器**自己的**圆角与图标尺寸。
        ///
        /// **不能沿用 `Radius.md`（10）**：设计稿 `.mrow__icon` 写的是 `--r-sm` = 6，
        /// 而主窗口的 `.diskicon` 才是 `--r-md` = 10。两者是两条独立规则，
        /// 共用一档会让菜单面板里的图标容器比设计稿圆 4pt —— 32pt 的方块上
        /// 圆角从 6 变成 10，四角明显「胖」了一圈。
        ///
        /// 图标尺寸同理：`.mrow__icon svg { width: 17px }`（主窗口是 22）。
        static let menuIconRadius: CGFloat = 6
        static let menuIconSize: CGFloat = 17
        /// 菜单栏行内推出按钮的图标（设计稿 `.mbtn svg { width: 14px }`）。
        static let menuEjectIconSize: CGFloat = 14
        /// 菜单面板头部应用图标（设计稿 `.pop__appicon svg { width: 13px }`）。
        static let popoverAppIconSize: CGFloat = 13
        /// 面板外框描边宽度（设计稿 `.win { border: 0.5px solid var(--border-strong) }`）。
        ///
        /// **必须画**：设计稿的 `.win` 有一条 0.5px 描边，它是毛玻璃与桌面之间唯一的边界。
        /// 没有它时，浅色壁纸下窗口边缘完全溶进背景里，看起来像没画完。
        static let glassBorderWidth: CGFloat = 0.5
        /// 紧凑行图标容器（设计稿 30 × 30，圆角 8）。
        static let compactIconContainer: CGFloat = 30

        /// 菜单面板空状态的图标容器（设计稿 `.empty__art` 在面板里被覆盖为 56 × 56 圆角 14）。
        ///
        /// **与主窗口空状态的 76 × 76 不是同一个东西**：面板只有 360pt 宽，
        /// 76 的方块在空状态里显得比内容还重。设计稿为此单独覆盖了一档尺寸。
        static let menuEmptyArtSize: CGFloat = 56
        /// 菜单面板空状态图标（设计稿 `.empty__art svg` 36）。
        static let menuEmptyArtIcon: CGFloat = 36
        /// 菜单面板头部图标按钮（设计稿 `.iconbtn` 28 × 28）。
        static let popoverIconButton: CGFloat = 28

        /// 磁盘行（完整版）内边距（设计稿 `padding: var(--s-3)`）。
        static let rowPadding: CGFloat = 12
        /// 磁盘行内容列之间的纵向间距（设计稿 `.row__main { gap: 7px }`）。
        static let rowColumnGap: CGFloat = 7
        /// 名称行与 meta 行之间的间距（设计稿 `.row__id { gap: 3px }`）。
        static let rowIdGap: CGFloat = 3

        /// 完整行：被占用（含证据区）高度 —— 设计稿实测 **169.47**（`.row--busy`）。
        ///
        /// ⚠️ **行高在设计稿里没有声明**：`.row` / `.mrow` / `.crow` 的高度都是
        /// 「padding + 内容」自然排出来的，CSS 里找不到 `height`，DESIGN-SPEC 里也
        /// 搜不到这几个数 ⇒ 它们是**一次性实测的快照**，改了设计稿不会有任何东西报警。
        /// **复核方法**：`.build/probe/design_row_height.py`（无头 Chrome 量设计稿 HTML）。
        /// **2026-09-18 复核**：169.47 / 127.47 / 133.47 / 68.72 / 46 —— **逐项仍成立**，
        /// 状态对应关系也对（127.47 = 「可以安全推出」，133.47 = 「占用情况未知」）。
        /// 令牌**取整到整点**（169.47 → 169）；测试容差 2pt，实测偏差 ≤ 0.47pt。
        static let diskRowBusyHeight: CGFloat = 169
        /// 完整行：可安全推出高度 —— 设计稿实测 **127.47**。
        static let diskRowSafeHeight: CGFloat = 127
        /// 完整行：占用情况未知高度 —— 设计稿实测 **133.47**。
        static let diskRowUnknownHeight: CGFloat = 133
        /// 紧凑行高度 —— 设计稿实测 **46**（`.crow`：上下各 8 内边距 + 内容 30）。
        static let compactRowHeight: CGFloat = 46
        /// 菜单面板磁盘行高度 —— 设计稿实测 **68.72**（`.mrow`：上下各 8 内边距）。
        /// 取整到 69；`MenuPopoverLayoutTests` 那条增量断言容差 **0.5**，实测偏差 0.28。
        static let menuRowHeight: CGFloat = 69
        /// 菜单面板动作行高度 —— 设计稿实测 **32.0000**（`getBoundingClientRect` 四位小数）。
        ///
        /// 算术是 `7（上内边距）+ 18（行盒）+ 7（下内边距）`，但那个 **18 不是设计的决定**：
        /// `.actionrow` 是 `<button>`，浏览器 UA 样式表给它 `line-height: normal`，
        /// **覆盖**了从 `.win { line-height: 1.45 }` 继承下来的 18.85 ——
        /// 同一份设计稿里 `.mrow__name`（`<div>`，18.85）与它并不一致。
        /// 实测：`computed.lineHeight = normal`、文本行盒 16、图标 15、键位 13，
        /// 而整行高度是**硬邦邦的 32**。
        ///
        /// 所以实现里**不复刻那个 18**（复刻浏览器怪癖没有意义），
        /// 直接把行高钉成 32（见 ``MenuActionRow``）。曾经按 1.45 算成 32.85，
        /// 四行累计多 3.4pt —— 面板整体因此比设计稿高。
        static let menuActionRowHeight: CGFloat = 32
        /// 启用紧凑行的磁盘块数阈值（设计稿 §3.3：≥ 4 块）。
        static let compactRowThreshold = 4

        /// 证据区内边距：上 8 / 左右 12 / 下 12（设计稿 `.evid`）。
        static let evidencePaddingTop: CGFloat = 8
        static let evidencePaddingH: CGFloat = 12
        static let evidencePaddingBottom: CGFloat = 12
        /// 证据区头部与芯片区之间的间距（设计稿 `.evid__chips { margin-top: 8px }`）。
        static let evidenceHeadGap: CGFloat = 8

        /// 被占用行左侧琥珀条 —— **三种行各有自己的规格**，不能共用一个常数。
        ///
        /// 设计稿里它们是三条独立的 `::before` 规则：
        /// - `.row--busy::before`（主窗口完整行）`width:3px; top/bottom:10px`
        /// - `.mrow--busy::before`（菜单面板行）`width:2.5px; top/bottom:7px`
        /// - `.crow--busy::before`（紧凑行）`width:3px; top/bottom:8px`
        ///
        /// 曾经三种都取 `busyBarWidth = 3`，菜单面板行因此宽了 0.5pt；
        /// 紧凑行更是漏了上下内缩，琥珀条顶到了行的上下边缘。
        /// 三处的圆角也**只圆右端**（`border-radius: 0 2px 2px 0`）——
        /// 左端贴着行的左边缘，圆角会在行的圆角外侧露出一小段弧，看起来像没对齐。
        ///
        /// ⚠️ **2026-09-18 实扫：上面那句「修好了」当时是假的。**
        /// `menuBusyBar*`（2.5 / 7）与 `compactBusyBar*`（3 / 8）三个令牌**接错了行**：
        /// `MenuBarDiskRow`（菜单面板行）拿的是紧凑行的 3 / 8，
        /// 而 `DiskRow` 的紧凑分支拿的是完整行的 3 / 10 ——
        /// 于是菜单行**仍然宽 0.5pt**（正是这段话声称已修的症状），紧凑行的条**短 4pt**。
        /// 设计稿 §3 那张「三种行各有自己的规格 ✅」是**假 ✅**。
        /// 现在三处各自接对自己的令牌，并由
        /// `MenuDiskRowLayoutTests/三种行的琥珀条各用自己那组的规格` 钉住（量像素）。
        static let rowBusyBarWidth: CGFloat = 3
        static let rowBusyBarInset: CGFloat = 10
        /// ✅ **2.5 现在落得了地**（2026-09-20，§8.87）。
        /// 之前落不了：2026-09-18 实测 `.frame(width: 2.5)` 渲染成 **3.0pt**（6px），
        /// 与 2.6 / 3.0 / 3.4 逐像素相同。机制**已核实** —— SwiftUI 传给 `path(in:)` 的
        /// `rect` **已经被对齐到整点**，所以「用 `rect.width` 画」的形状只能落整点宽。
        /// `BusyBarShape` 改成用自己的 `width` 属性（绝对坐标）后，2.5pt 就落下来了
        /// （菜单行实测 5px = 2.5pt，由 `三种行的琥珀条各用自己那组的规格` 双侧钉住）。
        static let menuBusyBarWidth: CGFloat = 2.5
        static let menuBusyBarInset: CGFloat = 7
        static let compactBusyBarWidth: CGFloat = 3
        static let compactBusyBarInset: CGFloat = 8
        /// 琥珀条右端圆角（设计稿 `0 2px 2px 0`）。
        static let busyBarRadius: CGFloat = 2

        /// 紧凑行磁盘名的最大宽度（设计稿 `.crow__name { max-width: 190px }`）。
        ///
        /// **必须限宽**：紧凑行是单行横向排布，磁盘名过长会把 meta 与状态挤出去。
        /// 设计稿把名称截在 190pt，保证「容量 + 状态 + 按钮」三者的位置在多块盘之间**纵向对齐**。
        static let compactNameMaxWidth: CGFloat = 190

        /// 进程芯片高（设计稿 26）与芯片内图标（设计稿 20）。
        static let processChipHeight: CGFloat = 26
        static let processChipIcon: CGFloat = 20

        /// 容量条填充高（设计稿 5）。
        static let meterHeight: CGFloat = 5
        /// 百分比标签固定宽（设计稿 34）—— 固定宽才能让多行百分比纵向对齐。
        static let meterPercentWidth: CGFloat = 34

        /// 设置行里的**行内下载进度**（设计稿 `08-update.html` 的 `.progressline`）。
        ///
        /// **外层固定 16pt 高**，与说明行同高 —— 于是「后台下载中」那一行
        /// 不会被进度条撑高，整块面板在下载过程中不会跳一下。
        /// ⚠️ 这里的百分比**不是** `meterPercentWidth`：设计稿给 `.progressline` 里的
        /// `.meter__pct` 单独写了 `width: auto`（进度条占满剩余宽度），
        /// 与磁盘行那个固定 34 的口径不同。
        static let settingsProgressLineHeight: CGFloat = 16

        /// 按钮高度（v3 起只剩这一档还有实现侧消费者：菜单磁盘行的布局预算）。
        /// ⚠️ **sm 26 / md 30 / lg 34 三档里，md/lg 已随 `ActionButton` 交还系统样式退役**
        /// （HANDOFF §3.5：系统给高 —— `.large` = 28 / `.regular` = 24），
        /// 原 `buttonMediumHeight` / `buttonLargeHeight` 两个令牌一并删除。
        /// **别再拿这里的 26 当 `ActionButton` 的高度预算** —— 它不再服务按钮。
        static let buttonSmallHeight: CGFloat = 26

        // 横幅**没有固定高度**：设计稿里未授权横幅 46 是被右侧 26pt 按钮撑出来的，
        // 授权成功横幅（无按钮）只有 37。曾经有一个 `bannerHeight = 46` 的
        // `minHeight` 兜在 `NoticeBanner` 上，让后者凭空高出 9pt —— 已删除。

        /// 空状态大图标容器（设计稿 76 × 76，圆角 18）。
        static let emptyArtSize: CGFloat = 76
        /// 设置面板「关于」页的图标容器（设计稿 09 页 `.aboutpane__icon`：76 × 76、圆角 14）。
        ///
        /// ⚠️ **与 ``emptyArtSize`` 数值相同、语义不同，别合并**：那个是「空状态装饰图」
        /// （`subtle` 底、圆角 18），这个是「关于页的应用图标」（accent 实底 + 白图标、
        /// 圆角 14、带 e2 阴影）。
        ///
        /// 单栏版曾有一对 `aboutRowIcon`(44) / `aboutRowHeight`(70)，随「关于」横排一行
        /// 那个形态一起删除 —— 两栏的「关于」独占一页，不再有那条行
        /// （设计稿 05 页那一版仍在 `screens/05-settings.html` 里留着作参照）。
        static let aboutPaneIcon: CGFloat = 76

        // ⚠️ 这里原有 4 个**自绘开关**的令牌（轨道 38 × 22、滑块 18、内缩 2），**v3 删除**。
        //
        // 它们服务的是 `SettingsSwitch` —— 用 `Capsule` + `Circle` + 阴影手画的开关，
        // 外面还配一层 `SettingsLineButton` 把命中区扩到整行。
        //
        // v3 把开关交还系统（HANDOFF §3.4 / §3.6）：
        // ``SettingsSectionPane/toggleLine(label:description:isOn:isEnabled:divider:tone:)``
        // 里就是 `Toggle` + `.toggleStyle(.switch)` —— 形状 / 玻璃 / hover / 按下反馈 /
        // 焦点环 / 动画**全部由系统给**，我们只负责**颜色**
        // （`.tint(accentColor.swiftUIColor)`）。
        // 「整行可点」由 `Toggle` 的 label 天然承担（把整行做成它的 label），
        // 不再需要自绘的命中区容器。
        // ⇒ 四个尺寸令牌一起失去对象。

        /// 设置面板里的下拉（设计稿 `.popup`）：**28pt 高**、11pt chevron。
        ///
        /// **高度比开关（22）高、比按钮（28）相同** —— 与设计稿一致。
        /// 这个数同时决定「语言」那一行的高度：28 > 行内文字（13 + 11 + 2 = 26），
        /// 所以加了下拉之后该行仍落在 `lineMinHeight` 之内，**不会把行撑高**。
        static let popUpHeight: CGFloat = 28

        /// 强调色色板（设计稿 22 × 22 圆，选中态外描边偏移 4）。
        static let swatchSize: CGFloat = 22
        static let swatchRingOffset: CGFloat = 4

        // ⚠️ 2026-09-18 实扫删除：`processTagHeight` / `processTagIcon` /
        // `primaryButtonHeight` 三个「兼容旧命名」的别名 —— 与 ``FontSize`` 里那 9 个
        // 同一批、同一条被证伪的理由（调用点 0）。用到的语义已由
        // ``processChipHeight`` / ``processChipIcon`` / ``buttonSmallHeight`` 承担。
    }

    // MARK: 色彩

    /// 语义色与表面色。
    ///
    /// **硬规则**（设计稿 §2.1）：琥珀与红是**专义色** ——
    /// 琥珀只用于「**受阻，且需用户介入才能恢复**」，红色只表示「破坏性」。
    ///
    /// 判据三条**同时成立**才用琥珀：① 不是失败、是受阻；② 不介入不会自行恢复；
    /// ③ 恢复动作在**用户手上**（不在等网络、等系统、等重试）。判据外的语义
    /// 一律不复用这两种颜色，避免同色双义。
    ///
    /// ⚠️ **本条 2026-09-29 澄清过**：旧文写的是「琥珀只表示**被占用**」，比实际用法窄 ——
    /// FDA 未授权横幅、登录项等待批准都**不是「被占用」**，但都满足三条判据。
    /// 反过来「更新下载失败」不满足第 ②（它下次启动会自动重试）⇒ 不染色。
    /// 完整推导与全部实例见设计稿 §2.1 与 `06-states.html` D 节。
    enum Palette {

        // MARK: 明暗自适应工具

        /// 由明/暗两个具体色值构造自适应 `Color`。
        ///
        /// **为什么不接收 `colorScheme` 参数**：那样每个用到语义色的子视图都要把
        /// `@Environment(\.colorScheme)` 透传下来，漏一处就会在深色下显示浅色值。
        /// `NSColor` 的 dynamic provider 由 AppKit 在绘制时按当前外观解析，天然正确。
        static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                })
        }

        /// `#RRGGBB` → `NSColor`（不透明）。
        private static func hex(_ value: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1)
        }

        /// 半透明灰（v3a 基色：`rgba(26,24,34,α)` 浅色 / `rgba(240,238,246,α)` 深色）。
        ///
        /// ⚠️ **浅深两套基色不同，各自对齐 ds.css**（v3a 的 --text-* 族）。
        private static func ink(_ alpha: CGFloat) -> Color { ink(light: alpha, dark: alpha) }

        /// 明暗**透明度不同**的半透明灰。
        /// 唯一一处 alpha 不同的令牌：`--text-3` 浅 0.36 / 深 0.34。
        private static func ink(light: CGFloat, dark: CGFloat) -> Color {
            adaptive(
                light: NSColor(srgbRed: 26 / 255, green: 24 / 255, blue: 34 / 255, alpha: light),
                dark: NSColor(srgbRed: 240 / 255, green: 238 / 255, blue: 246 / 255, alpha: dark))
        }

        /// 描边用的「墨色线」基色：浅色 `rgba(30,25,50,α)`，深色**纯白** ——
        /// 与文字族（ink）是两族、基色不同。
        private static func edge(_ alpha: CGFloat) -> Color { edge(light: alpha, dark: alpha) }
        /// 明暗**alpha 不同**的描边 —— v3a text-* / border* 都是。
        private static func edge(light: CGFloat, dark: CGFloat) -> Color {
            adaptive(
                light: NSColor(srgbRed: 30 / 255, green: 25 / 255, blue: 50 / 255, alpha: light),
                dark: NSColor(white: 1, alpha: dark))
        }

        // MARK: 表面

        // ⚠️ 2026-09-18 实扫删除：`base`（= 后来的 ``windowBase(for:)`` 的旧名）
        // 与 ``mutedBackground``（= ``subtle`` 的旧名）、``accentFallback`` 三个
        // **零消费者**令牌。前两个的注释都写着「旧名／兼容旧命名」，
        // 而实扫发现调用点是 0 —— 理由被证伪，令牌即死代码。

        /// 浮层、设置卡片、进程芯片。
        /// v3a：浅色保持 `#FFFFFF`（与 base `#FAFAF7` 形成冷暖对比），
        /// 深色从 `#2C2C2E` 换成蓝紫卡 `#1E2130`，与 base `#141620` 同色系。
        static var raised: Color { adaptive(light: hex(0xFFFFFF), dark: hex(0x1E2130)) }

        /// 悬停底、分段控件槽、徽标。
        /// v3a：基色从 `rgba(120,120,128,α)` 换成 `rgba(30,25,50,α)` ——
        /// 与 ink 同族。
        static var subtle: Color {
            adaptive(
                light: NSColor(srgbRed: 30 / 255, green: 25 / 255, blue: 50 / 255, alpha: 0.06),
                dark: NSColor(white: 1, alpha: 0.06))
        }
        // ⚠️ **v3 退役：`subtleHighlight`（2026-09-30）** —— 「悬停加深一档」
        // 只被自绘按钮的 hover 底用（`--bg-subtle-hi`），交还系统样式后零消费者。

        /// 证据区、弹窗底栏。
        static var sunken: Color {
            adaptive(
                light: NSColor(srgbRed: 30 / 255, green: 25 / 255, blue: 50 / 255, alpha: 0.04),
                dark: NSColor.black.withAlphaComponent(0.25))
        }

        /// 毛玻璃面 —— 设计稿 `--bg-glass`。**主窗口、菜单面板、设置面板共用这一个**。
        ///
        /// `.win` 的三个变体（`--main` / `--popover` / `--settings`）在 `ds.css` 里
        /// 只差宽高与圆角，底色一律是 `--bg-glass`。
        ///
        /// v3a：浅色从 `rgba(255,255,255,.72)` 换成暖纸基调
        /// `rgba(252,250,245,.65)`；深色从 `rgba(38,38,42,.74)` 换成蓝紫基调
        /// `rgba(30,33,48,.70)` —— 让玻璃也跟着换色系，不再是「白/灰透出来」。
        static func windowGlass(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 30 / 255, green: 33 / 255, blue: 48 / 255).opacity(0.70)
                : Color(red: 252 / 255, green: 250 / 255, blue: 245 / 255).opacity(0.65)
        }

        /// 旧名，等价于 ``windowGlass(for:)``。保留以免调用点大改。
        static func cardBackground(for scheme: ColorScheme) -> Color { windowGlass(for: scheme) }

        /// **色调模式**的窗口实体面 —— 设计稿 `bg-base`。
        /// v3a：浅色从 `#FFFFFF` 换成暖纸白 `#FAFAF7`，
        /// 深色从 `#1C1C1E` 换成蓝紫深海 `#141620`。
        static func windowBase(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 20 / 255, green: 22 / 255, blue: 32 / 255)
                : Color(red: 250 / 255, green: 250 / 255, blue: 247 / 255)
        }

        /// 弹窗（更不透明）—— 设计稿 `--bg-glass-thick`。
        /// v3a 同步换暖纸/蓝紫基调，透明度从 0.86 略调到 0.82/0.85。
        static func popoverBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 30 / 255, green: 33 / 255, blue: 48 / 255).opacity(0.85)
                : Color(red: 252 / 255, green: 250 / 255, blue: 245 / 255).opacity(0.82)
        }

        /// 卡片、分隔、芯片描边（`--border`）。v3a α 浅 0.09 / 深 0.08。
        static var border: Color { edge(light: 0.09, dark: 0.08) }

        /// 略重的描边（`--border-strong`）。v3a α 浅 0.16 / 深 0.15。
        static var borderStrong: Color { edge(light: 0.16, dark: 0.15) }

        /// 分隔线（`--hairline`）。v3a α 浅 0.07 / 深 0.07。
        static var hairline: Color { edge(0.07) }

        // MARK: 文字

        /// 主文字 —— v3a 浅 `#1A1822` / 深 `#F0EEF6`。
        static var foreground: Color { adaptive(light: hex(0x1A1822), dark: hex(0xF0EEF6)) }

        /// 小号加粗标题（`--text-2-strong`）。v3a α 浅 0.72 / 深 0.74。
        static var textStrong: Color { ink(light: 0.72, dark: 0.74) }

        /// 说明、容量、次要标签（`--text-2`）。v3a α 浅 0.60 / 深 0.62。
        static var mutedForeground: Color { ink(light: 0.60, dark: 0.62) }

        /// **仅装饰**（`--text-3`）。v3a α 浅 0.36 / 深 0.34。
        static var textDecorative: Color { ink(light: 0.36, dark: 0.34) }

        // MARK: 语义色

        /// **受阻**：琥珀。v3a 从 `#FF9500`（Apple 饱和橙）降成 `#D97706`（琥珀-600），
        /// 深色从 `#FF9F0A` 换成 `#F59E0B`。
        static var warning: Color { adaptive(light: hex(0xD97706), dark: hex(0xF59E0B)) }
        static var warningText: Color { adaptive(light: hex(0x8B4513), dark: hex(0xFCD34D)) }
        static var warningSoft: Color {
            adaptive(
                light: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 6 / 255, alpha: 0.12),
                dark: NSColor(srgbRed: 245 / 255, green: 158 / 255, blue: 11 / 255, alpha: 0.16))
        }
        static var warningLine: Color {
            adaptive(
                light: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 6 / 255, alpha: 0.30),
                dark: NSColor(srgbRed: 245 / 255, green: 158 / 255, blue: 11 / 255, alpha: 0.32))
        }

        /// 破坏性：红色。v3a 从 `#FF3B30`（Apple 饱和红）换成 `#DC2626`（朱砂-600），
        /// 深色从 `#FF453A` 换成 `#EF4444`。
        static var error: Color { adaptive(light: hex(0xDC2626), dark: hex(0xEF4444)) }
        static var errorText: Color { adaptive(light: hex(0x991B1B), dark: hex(0xFCA5A5)) }
        static var errorSoft: Color {
            adaptive(
                light: NSColor(srgbRed: 220 / 255, green: 38 / 255, blue: 38 / 255, alpha: 0.10),
                dark: NSColor(srgbRed: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 0.16))
        }
        static var errorLine: Color {
            adaptive(
                light: NSColor(srgbRed: 220 / 255, green: 38 / 255, blue: 38 / 255, alpha: 0.26),
                dark: NSColor(srgbRed: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 0.32))
        }

        /// 可安全操作：绿。v3a 从 `#34C759` 换成青瓷 `#0D9488`（Teal-600），
        /// 深色从 `#30D158` 换成 `#14B8A6`。
        static var success: Color { adaptive(light: hex(0x0D9488), dark: hex(0x14B8A6)) }
        static var successText: Color { adaptive(light: hex(0x0F766E), dark: hex(0x5EEAD4)) }
        static var successSoft: Color {
            adaptive(
                light: NSColor(srgbRed: 13 / 255, green: 148 / 255, blue: 136 / 255, alpha: 0.12),
                dark: NSColor(srgbRed: 20 / 255, green: 184 / 255, blue: 166 / 255, alpha: 0.16))
        }
        static var successLine: Color {
            adaptive(
                light: NSColor(srgbRed: 13 / 255, green: 148 / 255, blue: 136 / 255, alpha: 0.28),
                dark: NSColor(srgbRed: 20 / 255, green: 184 / 255, blue: 166 / 255, alpha: 0.32))
        }

        // MARK: 强调色的浅底

        /// 强调色 + **随明暗切换的透明度**。
        ///
        /// **不能用 `accent.swiftUIColor.opacity(α)`**：`.opacity` 只能给一个固定 α，
        /// 而设计稿给浅色/深色配了两个值。这里直接用带 alpha 的 `NSColor` 构造。
        private static func accentTint(_ accent: AccentColor, light: CGFloat, dark: CGFloat) -> Color {
            // 两侧**各构造一次**，而不是「取动态基色再改 alpha」。
            //
            // ⚠️ **实测（2026-09-21，§8.113.11）：后者也成立** —— AppKit 的
            // `withAlphaComponent` **会保留动态 provider**，两种写法结果逐值相同
            // （变异验证：换成后者守卫照样绿）。
            // ⇒ 保留这种显式写法只是**不依赖 AppKit 那个隐式行为**，
            //   别把它当成「修了个 bug」—— 它不是。
            return adaptive(
                light: accent.appKitColorLight.withAlphaComponent(light),
                dark: accent.appKitColorDark.withAlphaComponent(dark))
        }

        /// 强调色浅底（图标容器、hover）。设计稿 `--accent-soft`。
        ///
        /// **透明度分两档**（`ds.css` 的三处声明）：浅色 蓝 0.10 / 紫橙绿 0.12；
        /// 深色 蓝 0.16 / 紫橙绿 0.12。深色下蓝要更重 —— 0.10 的蓝铺在 `#1c1c1e`
        /// 上几乎看不出是「一块强调色底」，图标容器就退化成一个没有底的图标。
        static func accentSoft(_ accent: AccentColor) -> Color {
            let isBlue = accent == .blue
            // v3a ds.css 分档：blue 浅 0.10 / 深 0.18；其余 浅 0.12 / 深 0.14
            return accentTint(accent, light: isBlue ? 0.10 : 0.12, dark: isBlue ? 0.18 : 0.14)
        }

        /// 强调色内描边。v3a 分档：blue 浅 0.30 / 深 0.38；其余 浅 0.35 / 深 0.35。
        static func accentRing(_ accent: AccentColor) -> Color {
            let isBlue = accent == .blue
            return accentTint(accent, light: isBlue ? 0.30 : 0.35, dark: isBlue ? 0.38 : 0.35)
        }
    }

    // MARK: 阴影

    /// 设计稿 §2.5。深色模式阴影几乎无效，层级靠表面亮度差与 0.5px 白描边建立。
    enum Elevation {
        /// 卡片、芯片、按钮。
        static let e1 = ShadowSpec(color: .black.opacity(0.06), radius: 2, y: 1)
        /// 悬停抬升、浮层。
        static let e2 = ShadowSpec(color: .black.opacity(0.10), radius: 8, y: 3)
        /// 窗口、弹窗。
        static let e3 = ShadowSpec(color: .black.opacity(0.18), radius: 24, y: 10)

        struct ShadowSpec {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }
    }

    // MARK: 动画

    /// 设计稿 §2.6。缓动统一 `cubic-bezier(.32,.72,0,1)`。
    ///
    /// **必须尊重 `prefers-reduced-motion`**：SwiftUI 侧由 `accessibilityReduceMotion`
    /// 环境值决定是否把时长降为 0，见 ``Motion/animation(_:reduceMotion:)``。
    enum Motion {
        /// 120ms —— 悬停、颜色过渡。
        static let fast: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.12)
        /// 180ms —— 开关、分段控件、展开收起。
        static let standard: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.18)
        /// 260ms —— 容量条填充。
        static let slow: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.26)

        /// 按「是否开启减弱动效」返回对应动画（开启时返回 `nil`，即瞬时切换）。
        static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : base
        }
    }

    // MARK: 阈值

    /// 按数值切档的**行为阈值**（不是尺寸、不是颜色）。
    ///
    /// 与 ``Size`` 分开，是因为这一族的值**量不出来**：它是「到多少算多」的判断，
    /// 在设计稿里表现为「画了哪几根条、哪几根变了色」。所以它的同源守卫不是
    /// `DesignSizeParityTests` 那种「读 CSS 声明取 px」，而是 `MeterThresholdParityTests`
    /// 那种「读设计稿画的样本 + 读它手写的声明」。
    enum Threshold {
        /// 0.9 —— 容量条用量达到这一比例时切琥珀（设计稿 `.meter--high`）。
        ///
        /// **出处**：`06-states.html` 的 `E · 容量条用量三档`（`data-meter-high="0.9"`），
        /// 那一节画了三根条 —— 30% / 70% 是常态、**95% 切琥珀**。
        ///
        /// 边界由那两根最近的样本钉住：`0.70 < 阈值 ≤ 0.95`。
        /// 取 0.9 而不是 0.8 的理由写在设计稿那一节里（70% 之后还有一段正常使用区间，
        /// 过早变琥珀会让这个颜色退化成「常态噪声」）。
        ///
        /// ⚠️ **2026-09-18 那版注释说的「设计稿里没有可视依据」已经作废**（§8.52.4 记的
        /// 是当时的事实，§8.74 补上了这一态）。现在 `0.9` 有出处，且由守卫盯着。
        static let meterHigh: Double = 0.9

        /// 判定：这个用量算不算「高」。
        ///
        /// **把 `>=` 单独拎出来是为了让它可测**：设计稿写的是「用量 **≥** 90% 时切琥珀」，
        /// 而 `>=` 与 `>` 的差别**只在正好等于阈值那一瞬间**看得见 —— 设计稿画的 95%
        /// 样本两种写法都会亮，界面上逐字相同。写成一个函数，守卫就能直接钉住这个边界。
        static func meterIsHigh(_ ratio: Double) -> Bool { ratio >= meterHigh }
    }
}

// MARK: - 辅助：NSColor 十六进制

extension NSColor {
    /// 16 进制字符串 → NSColor（公开给菜单栏 tint 等使用）。
    convenience init?(designHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
