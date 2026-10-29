import AppKit
import SwiftUI

/// 设置内容（v3：**主窗口详情区的一页**，不再是独立窗口）。
///
/// ## 这个文件现在是什么
///
/// v3 把主窗口与设置窗口合并：设置不再是独立窗口、也没有自己的左栏与头部，
/// 而是主窗口详情区里**按分类切换的一页**（侧栏在 `MainWindowNavigation.swift`，
/// 头部是 ``MainDetailHead``）。所以本文件里**没有**窗口尺寸、没有左栏、
/// 也没有「完成」按钮 —— 那三样分别归窗口、``MainSidebarView``、
/// 以及「v3 里根本不存在这个概念（设置是常驻面板，没有『完成』）」。
///
/// 组成：
/// - ``SettingsPrompt``：拨完开关之后必须说的那句话（弹窗状态挂在 ``MainDetailView`` 上）；
/// - ``SettingsMetrics`` / ``SettingsLineTone``：排版度量与行的色调（测试共用同一份数字）；
/// - ``SettingsSection``：五个分类，**声明顺序即侧栏顺序**；
/// - ``SettingsSectionPane``：一个分类页的内容，本文件的主体；
/// - 页内控件：分段控件 / 色板 / 行内进度 / 下拉 / 关于页。
///
/// ⚠️ **开关交还系统**：v3 之后开关不再自绘（曾经有一个 `SettingsSwitch`：
/// `Capsule` + `Circle` + 阴影，还配一层 `SettingsLineButton` 来把命中区扩到整行）。
/// 现在走 ``SettingsSectionPane/toggleLine(label:description:isOn:isEnabled:divider:tone:)``，
/// 里面就是系统的 `Toggle` + `.toggleStyle(.switch)`；「整行可点」由 `Toggle` 的 label
/// 天然承担，颜色是唯一由我们给的东西（HANDOFF §3.4 / §3.6）。

// MARK: - 设置里的一次提示

/// 设置里的一次提示（标题 + 正文 + 可选的「打开系统设置」出口）。
///
/// **为什么把登录项失败与辅助功能引导合成一个类型，而不是挂两个 `.alert`**：
/// 同一个视图上叠两个 alert 修饰符时，「究竟哪一个弹得出来」取决于 SwiftUI 内部的
/// 呈现优先级 —— 那是**没有文档保证**的行为，而这里两种提示都是
/// 「用户拨动开关之后必须看到」的。合成一条通道后，「同一时刻最多一个弹窗」
/// 在类型层面就成立了，不必去赌框架行为。
///
/// - `openSettings == nil`：这个提示只能「知道了」（如登录项的失败原因），
///   此时 `dismissTitle` 就是唯一的按钮。
///
/// ⚠️ **它是文件级的**（曾经是 `SettingsView` 的私有嵌套类型）：v3 之后
/// 弹窗状态挂在 ``MainDetailView`` 上（切换设置分类会替换掉下层视图，
/// 挂在分类页里状态会被一起丢掉），而 ``SettingsDetailPage`` 也要上抛同一种提示。
struct SettingsPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// 「打开系统设置」那个出口；`nil` 表示没有出口。
    ///
    /// ⚠️ **类型上的 `@MainActor` 不是装饰，是必须的**：生产路径上这个出口指向
    /// ``LaunchAtLoginManager/openSystemSettings()``，而 ``LaunchAtLoginManager``
    /// 整个类型是 `@MainActor` 的（它要调 `SMAppService` 并驱动设置界面）。
    /// 声明成裸的 `() -> Void` 等于要求把主 actor 隔离「擦掉」——
    /// 在 Swift 6 严格并发下这是**编译错误**（`loses global actor 'MainActor'`），
    /// 不是可以忽略的警告。
    ///
    /// 声明成 `@MainActor` 才是诚实的：这个出口**只**从 SwiftUI 的 alert action 里调，
    /// 而那里本来就在主 actor 上。另一处赋值 ``AppSettings/openAccessibilitySettings()``
    /// 是 `nonisolated` 的，赋给带隔离的类型合法 —— 方向是「非隔离 → 隔离」，
    /// 属于放宽而不是收紧。
    let openSettings: (@MainActor () -> Void)?
    /// 关闭按钮的文案。**两种提示用的不是同一个词**：登录项失败是「确定」（一条通知），
    /// 辅助功能是「暂不」（一个选择 —— 用户有权不授权，按钮就该这么说）。
    let dismissTitle: String
}

extension SettingsPrompt {

    /// 登录项失败 → 提示内容（三类原因各自文案）。
    static func launchAtLogin(_ error: LaunchAtLoginError) -> SettingsPrompt {
        switch error {
        case .requiresApproval:
            return SettingsPrompt(
                title: L10n.tr(.launchAtLoginNeedsApprovalTitle),
                message: L10n.tr(.launchAtLoginNeedsApprovalMessage),
                openSettings: LaunchAtLoginManager.openSystemSettings,
                dismissTitle: L10n.tr(.ok))
        case .notFound:
            return SettingsPrompt(
                title: L10n.tr(.launchAtLoginErrorTitle),
                message: L10n.tr(.launchAtLoginUnavailableMessage),
                openSettings: nil,
                dismissTitle: L10n.tr(.ok))
        case .system(let text):
            LogService.shared.log(disk: nil, message: "登录项设置失败: \(text)")
            return SettingsPrompt(
                title: L10n.tr(.launchAtLoginErrorTitle),
                message: L10n.tr(.launchAtLoginErrorMessage),
                openSettings: nil,
                dismissTitle: L10n.tr(.ok))
        }
    }

    /// 用户刚打开「推出时提醒占用」时，那项**可选**权限的提示；已授权时为 `nil`。
    ///
    /// ## 为什么这件事必须让用户知道
    ///
    /// 关掉系统那张「占用中」的框有两条路：有辅助功能授权时**按下它自己的按钮**
    /// （精确到哪一块盘），没有时只能**结束弹框进程**（粗糙，但一样有效）。
    /// ⇒ **不授权功能也照常工作**，界面因此完全看不出这项权限存在 —— 而它是
    /// self-signed 分发下**每次重新构建都会掉**的那种授权。用户没有任何机会知道它，
    /// 除非我们主动说一次（并且说清「不给也行」）。
    ///
    /// ## 为什么是「每次打开开关都提」而不是像 FDA 那样「只提一次」
    ///
    /// FDA 那条走的是「只提一次 + 主窗口常驻横幅」：**没有 FDA，功能就废了**
    /// （列不出占用者），横幅是它的持续落点。辅助功能正好相反 —— 它**不影响可用性**，
    /// 所以不该为它占一条常驻横幅；可也正因为不影响，「只提一次」的那个一次被点掉之后
    /// 信息就永久消失（叠加「每次构建都掉授权」，用户会被静默降级到底）。
    /// ⇒ 落点跟着**用户拨动这个开关的动作**走，不再额外占用界面面积。
    ///
    /// ⚠️ **这不是「再加一行说明」的替代品**：设置页的宽度预算同样吃紧，
    /// 那一行的说明文字加不动 —— 加了就是「英文比中文多折一行」，而这正是这里
    /// 选弹窗的根本原因。
    ///
    /// 实际观感接近一次性：这个开关设完就不会再去动它；而**授权之后这个提示永不出现**
    /// （判据见 ``SystemEjectDialogDismisser/shouldSuggestAccessibility(isTrusted:)``）。
    static func accessibilityOnboarding() -> SettingsPrompt? {
        guard
            SystemEjectDialogDismisser.shouldSuggestAccessibility(
                isTrusted: SystemEjectDialogDismisser.isAccessibilityTrusted)
        else { return nil }
        return SettingsPrompt(
            title: L10n.tr(.accessibilityOnboardingTitle),
            message: String(format: L10n.tr(.accessibilityOnboardingMessage), L10n.tr(.appName)),
            openSettings: AppSettings.openAccessibilitySettings,
            dismissTitle: L10n.tr(.notNow))
    }

    /// 用户在**未授「完全磁盘访问」**时点击「推出时提醒占用」开关 → 引导提示。
    ///
    /// ## 为什么点击开关弹的是它，而不是静默地什么都不发生
    ///
    /// 未授权时那一行的开关曾经 `.disabled(true)`（2026-10-22 之前的形态）：
    /// 用户点开关、界面纹丝不动，唯一入口是旁边那颗不显眼的「打开系统设置」按钮 ——
    /// 「打开一个开关，然后它静默地什么都不做」是最难自查的一类缺陷。
    /// 现在开关保持**可点**，点击即弹本引导；开关本身**不写偏好**、恒显示「关」
    /// （`effectiveIsOn` 口径：没授权画了「开」就是在撒谎）。授权回到本页后，
    /// 那一行自动翻成可用（`didBecomeActive` 重探），用户再正常拨开 ——
    /// 下游「通知授权 + 辅助功能引导」链路因此一步不变。
    ///
    /// 「暂不」与 ``accessibilityOnboarding()`` 同一口径：用户有权不授权，按钮就该这么说。
    static func takeOverNeedsFDA() -> SettingsPrompt {
        SettingsPrompt(
            title: L10n.tr(.takeOverNeedsFDAPromptTitle),
            message: L10n.tr(.takeOverNeedsFDAPromptMessage),
            openSettings: AppSettings.openFullDiskAccessSettings,
            dismissTitle: L10n.tr(.notNow))
    }
}

// MARK: - 排版度量

/// 设置面板的排版度量（视图与布局契约测试共用同一份数字）。
enum SettingsMetrics {
    /// 头部高度（设计稿 `.sdetail__head { height: 52px }`）。
    ///
    /// **由「内容带 + 下方留白」拼出来，而不是独立写一个 52**：这样「标题与主窗口标题
    /// 同高」这件事只由 ``DesignTokens/Size/titleBarBandHeight`` 一个数字决定，
    /// 头部总高自动跟着走，不会出现「改了带高忘了改总高」。
    /// 与设计稿的 52 是否一致由 `TitleBarBaselineTests` 断言。
    static let headerHeight: CGFloat =
        DesignTokens.Size.titleBarBandHeight + DesignTokens.Size.titleBarBandBottomPadding

    // MARK: 内容区头部左右内边距

    /// 头部**前导**内边距（设计稿 `.sdetail__head { padding: 0 16px 0 20px }`）。
    ///
    /// ⚠️ **两栏把它从 16 改回了 20 —— 但这不是「把一段历史改回去」**：
    /// 单栏时代这里**也曾经是 20**，理由完全不同 —— 那时设置面板画着系统红绿灯，
    /// 前导要加到 20 才能让两个窗口的标题都落在 x = 80；2026-09-16 去掉红绿灯后回到 16。
    /// 现在 20 是**两栏设计稿自己写的值**（左栏 200 之后头部从 20 起排），
    /// 与红绿灯无关 —— 那个让位块早已删除，v3 起设置更是并进了主窗口详情区。
    static let headerPaddingLeading: CGFloat = DesignTokens.Spacing.xl
    /// 头部**尾随**内边距（设计稿同样是 16，不跟主窗口的 12）。
    static let headerPaddingTrailing: CGFloat = DesignTokens.Spacing.lg
    /// 头部 `HStack` 的子项间距（标题 / 弹性空档 / 「完成」之间）。
    ///
    /// 必须与视图里的 `HStack(spacing:)` 同源。**它不参与「标题左边界」的计算** ——
    /// 标题就是头部的第一个子项，左边界就等于前导内边距本身。
    static let headerSpacing: CGFloat = DesignTokens.Spacing.sm

    // MARK: 内容区内边距

    /// 内容区三边内边距（设计稿 `.sdetail__body { padding: 20px 20px 16px }`）。
    ///
    /// **产品侧可用宽 = 720 − 200(左栏) − 20×2 = 480**（单栏版只有 440 ⇒ 折行更少）。
    static let detailPaddingTop: CGFloat = DesignTokens.Size.settingsDetailPaddingTop
    static let detailPaddingH: CGFloat = DesignTokens.Size.settingsDetailPaddingH
    static let detailPaddingBottom: CGFloat = DesignTokens.Size.settingsDetailPaddingBottom

    /// 设置行内边距（设计稿 `.sline { padding: 11px 12px; min-height: 44px }`）。
    static let linePaddingV: CGFloat = 11
    static let linePaddingH: CGFloat = DesignTokens.Spacing.md
    static let lineMinHeight: CGFloat = 44

    /// 受阻行的**浅琥珀底**（设计稿 `.sline--warn { background: var(--warn-soft) }`）。
    ///
    /// 与设计稿同源，不另立数字 —— 上面几个是计量、这个是取色，
    /// 所以直接指向 ``DesignTokens/Palette/warningSoft`` 而不是抄一份 RGBA。
    static let warnRowBackground = DesignTokens.Palette.warningSoft
}

/// 开关行的**行级 hover 底**（设计稿 `--bg-subtle`）。
///
/// v3 把开关交还系统 `Toggle` 后，系统**不给**行级 hover
/// （2026-09-30 用户反馈「开关项 hover 效果没有了」），这里补回。
/// 底色直接用 ``DesignTokens/Palette/subtle``（= `--bg-subtle`，与分段控件槽 /
/// 徽标同源），形状与 ``SettingsMetrics/warnRowBackground`` 一致 —— 方形纯色、铺满整行盒。
///
/// ## 为什么 `@State` 必须住在**独立的 modifier 实例**里
///
/// 若把 hover 态挂在 pane 上，所有开关行**共享一份** hovered —— 悬停一行全体高亮。
/// `.modifier(ToggleRowHover(...))` 每行各建一份实例，状态天然隔离。
///
/// ## 为什么只在**可交互**的开关行启用
///
/// 说明行 / 分组标题这类静态行悬停高亮，反而是在暗示「这行可以点」。
/// 调用点（``SettingsSectionPane/toggleLine(...)``）传 `isEnabled` 进来，
/// 不可用的开关行（结构禁用）不给 hover —— 不可用就该长得不可用。
private struct ToggleRowHover: ViewModifier {
    var interactive: Bool

    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(hovered && interactive ? DesignTokens.Palette.subtle : Color.clear)
            .onHover { hovered = $0 }
    }
}

/// 设置行的**色调**（设计稿 `.sline` / `.sline--warn`）。
///
/// 设计稿把「受阻」收敛成一个**类变体**而不是另写一套行 —— 两页的琥珀行与普通行
/// 共用 `.sline` 基类的全部布局（`padding: 11px 12px`、`min-height: 44px`、
/// `.sline + .sline` 的分隔线），只差两处：**整行底色**与**标签色**。
/// 产品侧照这个模型来 —— ``SettingsSectionPane/line(label:description:progress:descriptionAccent:divider:tone:control:)``
/// 与 ``SettingsSectionPane/toggleLine(label:description:isOn:isEnabled:divider:tone:)``
/// 共用同一个 ``SettingsSectionPane/lineFrame(tone:divider:content:)``，而不是各复制一份布局。
/// 复制的代价不是多写几行，而是**两套布局会各自漂**：改了普通行的高度，受阻行不会跟着改，
/// 而它们在同一张卡片里。
///
/// ## 为什么是「色调」而不是「是不是警告」（`isWarning: Bool`）
///
/// 布尔参数在调用点上读不出意图（`line(..., true)` 里那个 `true` 指什么？），
/// 而色调是一个**封闭集合** —— 将来若真需要第三种（比如「信息」），
/// 加一个 case 会让所有 `switch` 处编译报错，而不是静默走 `false` 那条路。
///
/// ⚠️ **护栏（设计稿 `.sline--warn` 的注释里也写着）：同屏最多一条受阻行。**
/// 琥珀靠「稀少」产生信息量，两条就是噪声。目前消费者只有
/// ``SettingsSectionPane/loginPendingWarningLine`` 一处。
enum SettingsLineTone {

    /// 普通行。
    case normal

    /// 受阻行：琥珀浅底 + 琥珀标签（设计稿 `.sline--warn`）。
    ///
    /// 语义见设计稿 §2.1 的三条判据（**受阻、不会自愈、恢复动作在用户手上**）——
    /// 三个条件同时成立才用这个色调。判据外的语义（比如「下载失败」，
    /// 它下次启动会自动重试）**不许**借这个色调。
    case warning
}

// MARK: - 左栏（分类）

/// 设置面板的**分类**（设计稿 09 页左栏，五项）。
///
/// **为什么是枚举而不是一组字符串**：分类同时决定四件事 ——
/// 左栏的标题与图标、右栏头部的标题、以及右栏渲染哪一页。
/// 拆成四个平行的清单（左边一份标题、右边一份标题键、再一份图标名、又一处 switch）
/// 时，加一个分类要改四处，而漏掉任何一处**都不会报错**（图标变空白、标题串到隔壁页）。
///
/// `CaseIterable` 的**声明顺序就是左栏的显示顺序**（通用 → 外观 → 更新 → 诊断 → 关于），
/// 与设计稿 09 页逐项相同。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case updates
    case diagnostics
    case about

    var id: String { rawValue }

    /// 左栏项与右栏头部共用的显示名。
    ///
    /// ⚠️ **计算属性，不是 `static let`**：`L10n.tr` 依赖运行期强制语言
    /// （`L10n.forcedLocale`），写成 `static let` 会在首次访问时求值一次并固定下来 ——
    /// 单测里「钉住英文渲染」就会拿到中文那一版，而**看起来完全正常**。
    var title: String {
        switch self {
        case .general: L10n.tr(.settingsGroupGeneral)
        case .appearance: L10n.tr(.settingsGroupAppearance)
        case .updates: L10n.tr(.settingsGroupUpdates)
        case .diagnostics: L10n.tr(.settingsGroupDiagnostics)
        case .about: L10n.tr(.settingsGroupAbout)
        }
    }

    /// 左栏项的图标（设计稿 09 页的 `data-i`：`gear` / `sun` / `down` / `doc` / `info`）。
    ///
    /// **零新增图标**：五个 SF Symbol 都已在别处用过（诊断行的 `doc.text`、
    /// 更新按钮的 `arrow.down.circle` 等），语义与设计稿一一对应。
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "sun.max"
        case .updates: "arrow.down.circle"
        case .diagnostics: "doc.text"
        case .about: "info.circle"
        }
    }
}

// MARK: - 四组内容

/// 「更新」组那两个开关的展示状态 —— **仅供离屏出图 / 预览**。
///
/// **为什么需要它**：这两行有三个输入是**跑出图那个进程的环境**决定的 ——
/// 两个开关值来自 Sparkle 的 `SPUUpdaterSettings`，而「宿主是否具备自动更新能力」
/// 由 **updater 建没建起来** 决定（``UpdateController/canAutoUpdate`` = `updater != nil`，
/// **与签名无关** —— 早先记成「由签名决定」是错的，dist 产物其实是签了的，§8.113.14）。
/// 走查图跑在 xctest 进程里 ⇒ `Bundle.main` 不是合规的 app bundle ⇒ updater 建不起来 ⇒
/// 这两行**永远画成禁用态**，
/// 与设计稿 `08-update.html` 里开关打开的画法对不上（§8.44.4）。
///
/// 出图时按**设计稿假设的环境**（具备能力 + 检查开）渲染，这两行才能与设计稿并排比；
/// 「不具备能力」「检查没开」两态另有单独出图，不会被丢掉。
///
/// ⚠️ **为什么是三个布尔，不是四个**（2026-09-28 拆分时定的）：下载行**能不能点**
/// 由 `canAutoUpdate && checksIsOn` 推出来，**不在这里再存一份** ——
/// 存了就有两个真相，而「可点性」与「说明文字」必须同源
/// （否则会出现「文案说缺 A、实际因为缺 B 而点不动」，见 ``AutoUpdateRowsState`` 的消费者）。
/// 这里只提供**输入**，判定收敛在 ``SettingsSectionPane/autoDownloadTapAction``
/// 与 ``SettingsSectionPane/autoDownloadUpdateDescription`` 上，两处读同一个输入。
///
/// ⚠️ 与 ``SettingsSectionPane/autoCheckUpdateOverride`` **不是一回事**：
/// 那是「用户本次拨动后的覆盖值」（运行时会变，生产路径在用），
/// 这个是**只在出图时**注入的静态值。别把两者合并。
struct AutoUpdateRowsState: Equatable {
    /// 宿主是否具备自动更新能力（真实环境下由 **updater 建没建起来** 决定，不是签名状态）。
    var canAutoUpdate: Bool
    /// 「自动检查更新」开关是不是开着的。
    var checksIsOn: Bool
    /// 「自动下载更新」开关是不是开着的（检查关着时它必然是关的，见 ``UpdateController/automaticallyDownloadsUpdates``）。
    var downloadsIsOn: Bool
}

/// **一个分类页的内容**（不含内容区头部与滚动容器）—— 设计稿 09 页右栏那一块。
///
/// **自己读偏好、不接收绑定**：这样契约测试可以直接
/// `SettingsSectionPane(section: .general)` 构造真实视图量高度，
/// 不必在测试里搭一套假的绑定。唯一需要上抛的是登录项的失败原因（宿主负责弹 alert）。
///
/// ## 与单栏版的差别（旧类型 `SettingsSectionsColumn`，2026-09-29 拆分时删名）
///
/// 旧类型一次渲染**五组**并把它们纵向堆起来，高度 = 五组之和；
/// 新类型只渲染**一个分类**，高度只由这一页决定 —— 这正是两栏形态能解决
/// 「高度被最长语言挟持」的地方（v3 起设置并入主窗口详情区，高度契约由
/// `SettingsLayoutTests` 的逐页基准表钉住）。
///
/// ⚠️ **分组标题（`.sgroup`）在这一形态里没有了**：单栏版每组头上有个大写小标题，
/// 两栏版把它提到了内容区头部（``SettingsHeaderBar``）—— 同一句话不再写两遍。
/// 所以这里也**没有** `group(title:)` 那层包装。
struct SettingsSectionPane: View {

    /// 渲染哪一页。
    let section: SettingsSection

    /// 登录项操作失败时上抛（宿主弹提示；测试里给空实现）。
    var onLaunchAtLoginError: (LaunchAtLoginError) -> Void = { _ in }

    /// 用户**刚把「推出时提醒占用」打开**时上抛（宿主接两件下游动作：
    /// 申请通知授权、必要时提示辅助功能权限）。
    ///
    /// **为什么这两件事不在本视图里直接做**：它们都要跟用户说话（一条系统请求、
    /// 一个弹窗），而本视图是**内容列** —— 弹窗状态在宿主 ``SettingsView`` 上
    /// （`prompt`），它拿不到。上抛事件而不是上抛「结论」，也避免了
    /// 「判定在列里、弹窗在宿主」这种把一件事劈成两半的接法。
    ///
    /// 默认空实现：单测与离屏出图里拨开关不该真的去申请系统权限。
    var onTakeOverEnabled: () -> Void = {}

    /// 用户在**未授「完全磁盘访问」**时点击「推出时提醒占用」开关上抛
    /// （宿主接：弹 ``SettingsPrompt/takeOverNeedsFDA()`` 引导）。
    ///
    /// **为什么不在本视图里直接弹**：弹窗状态在宿主 ``MainDetailView`` 上
    /// （`prompt`），本视图是**内容列**，拿不到 —— 与 ``onTakeOverEnabled`` 同一条接法。
    ///
    /// 默认空实现：单测与离屏出图里点开关不该真的去弹窗。
    var onTakeOverNeedsFDA: () -> Void = {}

    /// ⚠️ **仅供离屏出图 / 预览**：`nil` 时走真实状态 ``UpdateController/rowState``。
    ///
    /// **为什么需要它**：七态里「下载中 / 已就绪 / 失败」在真机上造不出来
    /// （要真实的 appcast + 下载 + 签名校验），而它们恰恰是最需要走查的三种画法 ——
    /// 没有这个口子，走查图永远只有首帧那一态，等于**没画过的状态没人看过**。
    ///
    /// **为什么注入的是「状态」而不是 ``UpdateController/phase``**：`phase` 只是
    /// ``UpdateController/rowState(phase:skippedVersion:lastCheck:)`` 的三个输入之一，
    /// 另外两个（已跳过的版本、上次检查时间）来自 `UserDefaults` ——
    /// 只注入 `phase` 会留下两个不确定输入，出图**不可复现**。
    /// 注入「状态」跳过的只有那个**纯函数**，而它每条分支都有自己的单测
    /// （`UpdateSettingsTests.行状态的优先级`）。
    ///
    /// ⚠️ **不要**改成「给 `UpdateController.shared` 塞一个假 phase」——
    /// 那会连带编出假的进度、假的「可以取消」，与 §8.30 记的「夹具保真度」是同一个坑。
    var updateStateOverride: UpdateController.CheckRowState?

    /// ⚠️ **仅供离屏出图 / 预览**：`nil` 时走真实值（Sparkle + updater 建没建起来）。
    /// 理由见 ``AutoUpdateRowsState``。
    var autoUpdateRowsOverride: AutoUpdateRowsState?

    /// ⚠️ **仅供离屏出图 / 单测**：`nil` 时走实时探测 ``AppSettings/takeOverAvailability()``。
    ///
    /// ## 为什么这个口子非有不可
    ///
    /// 它来自「本机给没给完全磁盘访问」，而这个问题的答案**取决于跑测试的那个进程**：
    /// xctest 的 FDA 责任方是拉起它的终端（本机实测：终端有、被测 app 没有）。
    /// 不注入的话，同一份高度契约会在这台机器上绿、换台机器红，**红绿都与被测代码无关** ——
    /// 同 ``AutoUpdateRowState`` 那条的理由。
    ///
    /// 注入的是**可用性结论**（``AppSettings/TakeOverAvailability``）而不是「两个布尔」：
    /// 推导仍然只有 ``AppSettings/TakeOverAvailability/resolve(isSandboxed:isFullDiskAccessAuthorized:)``
    /// 一处，注入口不会长成第二套判据。
    var takeOverAvailabilityOverride: AppSettings.TakeOverAvailability?

    /// ⚠️ **仅供离屏出图 / 单测**：`nil` 时读真实 ``LaunchAtLoginManager/state``。
    ///
    /// ## 为什么这个口子非有不可
    ///
    /// 设计稿 09 页把「等待系统批准」那一态算进了定高的判据里（第 2 帧），
    /// 而它在真机上**造不出来** —— 要 `SMAppService` 真的返回 `.requiresApproval`。
    /// 没有这个口子，那一态在单测与走查图里**永远不存在**：
    /// 高度契约只会量到另外几页，而「那一页放不下」这件事没有任何东西会报错
    /// —— 本仓库反复吃亏的正是这一类（**没画过的状态没人看过**）。
    var launchAtLoginStateOverride: LaunchAtLoginState?

    @AppStorage(AppSettings.Key.visualStyle) private var visualStyleRaw = VisualStyle.default.rawValue
    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue
    @AppStorage(AppSettings.Key.appLanguage) private var appLanguageRaw = AppLanguage.default.rawValue

    /// 「接管访达的推出」开关（默认关）。
    ///
    /// **默认关的理由**见 ``AppSettings/takeOverFinderEject``：接管是系统级改动，
    /// 一次性推给老用户风险太高 —— 万一出 bug，用户会以为「盘推不出来了」。
    @AppStorage(AppSettings.Key.takeOverFinderEject) private var takeOverFinderEject = false

    /// 「接管访达的推出」此刻**能不能用** —— 见 ``AppSettings/TakeOverAvailability``。
    ///
    /// 存的是**结论**而不是「授权与否」：视图不自己推「有没有授权」（那是
    /// ``AppSettings/TakeOverAvailability/resolve(isSandboxed:isFullDiskAccessAuthorized:)`` 的事），
    /// 也不自己判「该画成什么」—— 一处推导，三处消费（画法 / 能否点击 / 说明文字）。
    @State private var takeOverAvailability: AppSettings.TakeOverAvailability

    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled

    /// 用户本次拨动「自动检查更新」后的值；`nil` = 还没拨过，直接读 Sparkle。
    ///
    /// **为什么是「覆盖值」而不是一个镜像布尔**：镜像需要一个「加载完了吗」的位，
    /// 否则首帧会把 Sparkle 的默认值（开）显示成关。这里反过来 —— 没拨过就读真值，
    /// 永远不可能显示错的初始状态，也不需要那个位。
    @State private var autoCheckUpdateOverride: Bool?

    /// 用户本次拨动「自动下载更新」后的值；`nil` = 还没拨过，直接读 Sparkle。
    ///
    /// 与上面那条同源。**它必须单独存在**：两个开关写的是**两个** Sparkle 标志
    /// （`SUEnableAutomaticChecks` / `SUAutomaticallyUpdate`），共用一个覆盖值
    /// 就等于把刚拆开的两件事又绑回去。
    @State private var autoDownloadUpdateOverride: Bool?

    /// 「更新」组要跟着 ``UpdateController/phase`` 变 —— 下载进度、已就绪、失败
    /// 三个状态都是**别人推着走**的（Sparkle 的回调），不订阅就永远停在首帧那一态。
    @ObservedObject private var updateController = UpdateController.shared

    // MARK: 构造

    /// **显式 init 存在的唯一理由**：给 `takeOverAvailability` 这个 `@State` 一个
    /// **打开面板那一刻算出来**的初值。
    ///
    /// 合成出来的逐个成员 init 只能给属性写默认表达式，而默认表达式**没法区分**
    /// 「调用方注入了结论」与「要现探真机」——那正是这里唯一需要判断的事。
    ///
    /// ⚠️ **参数顺序：回调在后**。`onLaunchAtLoginError` 是唯一的回调，
    /// 排在最后才能让测试写成 `SettingsSectionPane(section: .general, takeOverAvailabilityOverride: .usable)`
    /// —— 单测里有多处是「只关心高度、别的都走默认」的调用，让它们少写一个标签是有意义的。
    /// （两栏之后 `section:` 成了必填的第一个参数，这是**唯一**变的调用点；
    /// 回调靠后那条理由不变，所以其余参数顺序一字未动。）
    init(
        section: SettingsSection,
        updateStateOverride: UpdateController.CheckRowState? = nil,
        autoUpdateRowsOverride: AutoUpdateRowsState? = nil,
        takeOverAvailabilityOverride: AppSettings.TakeOverAvailability? = nil,
        launchAtLoginStateOverride: LaunchAtLoginState? = nil,
        onLaunchAtLoginError: @escaping (LaunchAtLoginError) -> Void = { _ in },
        onTakeOverEnabled: @escaping () -> Void = {},
        onTakeOverNeedsFDA: @escaping () -> Void = {}
    ) {
        self.section = section
        self.updateStateOverride = updateStateOverride
        self.autoUpdateRowsOverride = autoUpdateRowsOverride
        self.takeOverAvailabilityOverride = takeOverAvailabilityOverride
        self.launchAtLoginStateOverride = launchAtLoginStateOverride
        self.onLaunchAtLoginError = onLaunchAtLoginError
        self.onTakeOverEnabled = onTakeOverEnabled
        self.onTakeOverNeedsFDA = onTakeOverNeedsFDA
        // **打开面板的那一刻就要说实话**：首帧先画「可用」、下一帧再翻成「不可用」，
        // 用户看到的是一个**任何时刻都不存在的状态**（同 ``appVersion`` 那条「别显示假值」）。
        //
        // ⚠️ **注入口不为空时不探真机**：出图与单测要的正是「与这台机器的权限状态无关」，
        // 真机探测会把注入值覆盖掉。
        _takeOverAvailability = State(
            initialValue: takeOverAvailabilityOverride ?? AppSettings.takeOverAvailability())
        // 「等待系统批准」⇒ 开关必须画成**开**。真机上这个状态只会在用户**先开了开关**、
        // 系统还没批完时出现（设计稿 09 页第 2 帧的开关就是 `aria-checked="true"`）；
        // 而 `LaunchAtLoginManager.isEnabled` 读的是这台机器的 UserDefaults ——
        // 测试机上没设，会让快照画出「关 + 等待批准」这个**真机不存在的组合**。
        // 与 ``takeOverAvailabilityOverride`` 同一条纪律：注入口生效时不探真机。
        _launchAtLogin = State(
            initialValue: launchAtLoginStateOverride == .requiresApproval
                ? true
                : LaunchAtLoginManager.isEnabled)
    }

    private var accentColor: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

    /// 用户选的语言（`@AppStorage` 侧）。
    private var appLanguage: AppLanguage { AppLanguage.resolve(appLanguageRaw) }

    /// 「改了语言但还没重启」的第三态。
    ///
    /// 判定走 ``LanguageManager/isRestartPending(preferred:active:)`` 这个纯函数，
    /// 不读 ``LanguageManager/preferred`` —— 视图的值来自 `@AppStorage`，
    /// 两者在刷新时序上可能差一帧，混用会出现「下拉已经变了、说明还是旧的」。
    private var languageRestartPending: Bool {
        LanguageManager.isRestartPending(preferred: appLanguage)
    }

    // 这里**没有** `private var visualStyle` —— 它曾经存在且从未被使用（死代码）：
    // 本视图只需要把 raw 值交给分段控件，真正消费这个偏好的是 ``GlassSurface``
    // （窗口底色）。留一个没人读的解析属性，会让人以为「切换外观」的接线在本文件里。

    /// 从 Info.plist 读取版本号（打包时注入），缺失时回退 "1.0.0"。
    ///
    /// ⚠️ **不要为了让走查图「对上设计稿」去改这个兜底值**（2026-09-16 差点踩到）。
    ///
    /// 设计稿 `05-settings.html` 里写的是 `版本 1.0.0 · 构建 42`，而设计对照图上
    /// 实现侧显示的是 `构建 1` —— 看起来像「实现没读出版本号」，实际是**渲染夹具的产物**：
    /// 走查快照由**测试进程**渲染，它的 `Bundle.main` 是 xctest runner，
    /// **没有 `CFBundleShortVersionString` / `CFBundleVersion` 这两个键** → 落到这里的兜底值。
    ///
    /// 真机 app 读得到，值是 `2026.09.13.1` / `44`（`build_app.sh` 按提交数写入
    /// `Info.plist`，已用 `PlistBuddy` 核对）。
    ///
    /// 若把兜底值改成设计稿的 `42`，对照图会「对上」，但真机上万一读不到 plist
    /// 就会显示一个**假版本号** —— 用户报问题时给出的版本号会指向一个不存在的构建。
    /// **设计稿里的样本值（版本号、构建号、磁盘名）不是规格。**
    private var appVersion: String {
        AppVersionInfo.shortVersion() ?? "1.0.0"
    }

    /// 构建号，与版本号一并展示便于用户反馈问题时定位。兜底值的理由见 ``appVersion``。
    private var buildNumber: String {
        AppVersionInfo.build() ?? "1"
    }

    /// 分发渠道显示名。**必须区分**开发构建与正式直发构建：`DEBUG` 构建既没公证、
    /// 也不代表可分发状态，一律写成「官网直发版」会让使用者误判自己拿到的是可分发产物。
    ///
    /// （`.appStore` 分支已随「不上架 MAS」删除——渠道不存在，就没有第三个名字要显示。）
    private var channelName: String {
        switch UpdateService.channel {
        case .direct:
            return L10n.tr(.updateChannelDirect)
        case .development:
            return L10n.tr(.updateChannelDevelopment)
        }
    }

    // MARK: 「语言」行

    /// 「语言」行的说明。
    ///
    /// 三态，**每一态都要有可见落点**：
    /// - 跟随系统 → 「跟随系统语言（当前：简体中文）」；
    /// - 选了某个具体语言且**已生效** → 「当前：English」；
    /// - 选了但**还没重启** → 「将在重启后切换为 English」（并多出「立即重启」按钮）。
    ///
    /// 最后一态是必须的：macOS 只在启动时读 `AppleLanguages`，改完不可能当场生效。
    /// 不写出来，用户无法分辨「本来就要等重启」和「这个功能坏了」
    /// —— 与登录项「等待系统批准」、更新「已跳过 1.1.0」是同一类错误。
    private var languageDescription: String {
        if languageRestartPending {
            return String(format: L10n.tr(.languagePendingHintFormat), appLanguage.displayName)
        }
        switch appLanguage {
        case .system:
            return String(
                format: L10n.tr(.languageFollowSystemHintFormat),
                LanguageManager.active.displayName)
        default:
            return String(format: L10n.tr(.languageInEffectHintFormat), appLanguage.displayName)
        }
    }

    /// 「语言」行右侧的控件：下拉 + （待重启时）「立即重启」。
    ///
    /// **单独抽出来是为了让编译器喘口气**：整段塞在 `body` 里时，
    /// `SettingsPopUp` 的泛型 + `Binding(get:set:)` + `if` 分支会让类型检查器放弃，
    /// 报成 `failed to produce diagnostic for expression`（错误位置指在 `var body` 上）。
    @ViewBuilder
    private var languageControl: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            SettingsPopUp(
                items: AppLanguage.allCases,
                title: { $0.displayName },
                // 写回走 ``LanguageManager/apply(_:)`` —— 它同时更新 `appLanguage` 偏好
                // 与 `AppleLanguages`（系统认得的那个键）。只写前者的话，
                // 界面会显示「已选 English」而下次启动仍然是中文。
                selection: Binding(
                    get: { appLanguage },
                    set: { LanguageManager.apply($0) }
                ),
                accessibilityLabel: L10n.tr(.appLanguage)
            )
            // 第三态才出现的「立即重启」：让这个状态**可立刻见效**，
            // 而不是让人干等或去猜（设计稿 spec-note）。
            if languageRestartPending {
                ActionButton(
                    title: L10n.tr(.restartNow),
                    variant: .outline,
                    size: .small,
                    accent: accentColor,
                    action: { LanguageManager.restart() }
                )
            }
        }
    }

    // MARK: 「更新」组

    /// 「自动检查更新」开关的当前值。
    ///
    /// **真值在 Sparkle 那边**（`SPUUpdaterSettings`，写进同一份 UserDefaults），
    /// 这里不另存偏好 —— 见 ``AppSettings`` 顶部那段说明。
    private var autoCheckUpdateOn: Bool {
        autoUpdateRowsOverride?.checksIsOn ?? autoCheckUpdateOverride
            ?? UpdateController.shared.automaticallyChecksForUpdates
    }

    /// 「自动下载更新」开关的当前值。
    ///
    /// ⚠️ 读 `automaticallyDownloadsUpdates`（Sparkle 算出来的**有效值**：
    /// `allowsAutomaticUpdates && SUAutomaticallyUpdate`），而不是那个键本身 ——
    /// 「自动检查更新」关着时它必然为假，**正是这一行该显示的样子**。
    private var autoDownloadUpdateOn: Bool {
        autoUpdateRowsOverride?.downloadsIsOn ?? autoDownloadUpdateOverride
            ?? UpdateController.shared.automaticallyDownloadsUpdates
    }

    /// 宿主是否**具备**自动更新的能力 —— 两个开关共用的前置条件。
    ///
    /// ⚠️ **判据不看任何一个开关自己的值**（2026-09-21 真机修的 bug，§8.113.14）：
    /// 旧实现读 Sparkle 的 `allowsAutomaticUpdates`，而它在本应用里**恒等于
    /// 「自动检查」这个开关的当前值** ⇒ 用户关一次 ⇒ 整行 `onTap` 变 `nil`
    /// ⇒ **再也打不开**（重启也没用）。⇒ 判据是「updater 建没建起来」。
    private var canAutoUpdate: Bool {
        autoUpdateRowsOverride?.canAutoUpdate ?? UpdateController.shared.canAutoUpdate
    }

    /// 「自动检查更新」行的说明。不允许自动更新时**必须说明原因** ——
    /// 否则用户看到的是一个拨不动的开关，却不知道为什么。
    ///
    /// ⚠️ **说的原因必须是 `canAutoUpdate` 真的代表的那件事**：它现在只表示
    /// 「updater 没建起来」（原因有多种：预览模式、宿主不是合规 app bundle、
    /// Sparkle 配置不合规），**与签名无关**。
    /// 2026-09-21 前这里写的是「当前构建未签名」，而 dist 产物其实**是签了的**
    /// （§8.113.14）—— **编一个具体原因比不写原因更糟**：用户会照着错的原因去修。
    private var autoCheckUpdateDescription: String {
        canAutoUpdate ? L10n.tr(.autoCheckUpdateHint) : L10n.tr(.autoUpdateUnavailableHint)
    }

    /// 「自动下载更新」行的说明 —— **三态，每一态都要回答「为什么现在是这个样子」**。
    ///
    /// ⚠️ 这一行比别的行**多一个禁用原因**：它不只是「updater 没建起来」时不可点，
    /// **「自动检查更新」关着时也不可点** —— 此时 Sparkle 的
    /// `automaticallyDownloadsUpdates` setter 是**空操作**（连键都不写，
    /// 见 ``UpdateController/automaticallyDownloadsUpdates`` 里的实测），
    /// 允许点就等于「点一下、开关动一下、实际什么都没发生」。
    /// ⇒ 文案必须把这一条说出来（``autoDownloadNeedsCheckHint``），
    /// 否则用户看到的就是一个拨不动、也不说为什么的开关 ——
    /// 与本文件反复出现的那条纪律（「设了没生效」与「没设」不能长得一样）同源。
    ///
    /// ⚠️ **不许把 `autoCheckUpdateOn` 与 `canAutoUpdate` 合成一个布尔**：
    /// 两种原因必须以**两句话**说出去（「组件没起来」≠「检查没开」），
    /// 合成一个的话，用户在「检查没开」时读到的会是「组件没起来」——
    /// **编一个具体原因比不写原因更糟**。
    private var autoDownloadUpdateDescription: String {
        if !canAutoUpdate { return L10n.tr(.autoUpdateUnavailableHint) }
        return autoCheckUpdateOn ? L10n.tr(.autoDownloadUpdateHint) : L10n.tr(.autoDownloadNeedsCheckHint)
    }

    /// 拨动「自动检查更新」。
    ///
    /// ⚠️ **只驱动它自己那一个标志**（`SUEnableAutomaticChecks`）。
    /// 2026-09-28 拆成两行之前，这一个开关要写两个标志、还得靠**写入顺序**绕开
    /// Sparkle 的空操作（§8.113.15）；拆开之后那个顺序问题**自然消失** ——
    /// 因为「下载」有自己的开关，且它在检查关着时本来就不可点。
    ///
    /// **关的时候顺手把下载也关掉**：不写的话 `SUAutomaticallyUpdate` 可能停在 1，
    /// 而 getter 与 `allowsAutomaticUpdates` 相与会把它掩盖成「没生效」——
    /// 有效行为是对的，但**存储与意图不一致**，读 defaults 的人会被它骗
    /// （§8.113.15 记的就是这件事，我自己中过一次）。
    ///
    /// ⚠️ **接的是 `Toggle` 的 binding（新值直给），不是「拨一下」**：v3 把开关
    /// 交还系统 `Toggle` 之后，驱动方向由控件决定 —— 留一个 toggle 语义的函数
    /// 再由 binding 去猜当前值，会在快速连点时写反（用户连点两次，第二次读到的
    /// 可能还是旧值）。所以这里与下面那个都收**目标值**。
    private func setAutoCheckUpdate(_ newValue: Bool) {
        if newValue {
            UpdateController.shared.automaticallyChecksForUpdates = true
        } else {
            // ⚠️ **顺序不能反**：`automaticallyDownloadsUpdates` 的 setter 在
            // `allowsAutomaticUpdates` 为假时是空操作，而后者跟着 checks 走
            // ⇒ 必须先写 downloads（此刻 allows 还为真）、再写 checks。
            UpdateController.shared.automaticallyDownloadsUpdates = false
            UpdateController.shared.automaticallyChecksForUpdates = false
            autoDownloadUpdateOverride = false
        }
        autoCheckUpdateOverride = newValue
    }

    /// 拨动「自动下载更新」。**只在检查开着时可达**（见 ``autoDownloadUpdateEnabled``）。
    private func setAutoDownloadUpdate(_ newValue: Bool) {
        UpdateController.shared.automaticallyDownloadsUpdates = newValue
        autoDownloadUpdateOverride = newValue
    }

    /// 「自动下载更新」那一行此刻**能不能拨** —— 它比别的行多一个禁用原因。
    ///
    /// ⚠️ **这里的判据确实读了开关自己的值**（`autoCheckUpdateOn`），而 §8.113.14
    /// 立的是「判据不许读开关自己的值」—— 两条**不冲突**：那条禁止的是
    /// 「拿开关自己的值当『有没有这个能力』」（关一次就锁死，因为能力其实与它无关）；
    /// 而这里表达的是一个**真实的因果**：检查不做，下载根本写不进去
    /// （见 ``setAutoCheckUpdate``）。锁死的风险不存在 ——
    /// 检查行**永远可拨**，用户的出口一直在。
    private var autoDownloadUpdateEnabled: Bool {
        canAutoUpdate && autoCheckUpdateOn
    }

    /// 「更新」组的第二行 —— **一个状态机，七种画法**（设计稿 `08-update.html` B 段 + C 段矩阵）。
    ///
    /// **为什么这一行不是「固定文案 + 固定按钮」**：设计稿把「发现新版本」「后台下载中」
    /// 「已就绪」「下载失败」四种中间状态**全部就地画在这一行上** —— 不弹遮罩、不加横幅、
    /// 不往主窗口塞东西。后台更新的全部意义就是别打扰用户。
    /// 而每种状态下**能做的事不一样**（查看更新 / 取消 / 立即重启 / 重试），
    /// 所以按钮也跟着状态走。
    ///
    /// **文案与判定都不在这里做**：判定是 ``UpdateController/rowState(phase:skippedVersion:lastCheck:)``
    /// 这个纯函数（可以逐态断言），视图只负责把它翻译成人话。
    /// 视图里 if/else 拼字符串就没法断言 —— 测试只能去比本地化的日期文本，
    /// 换台机器或换个语言必红，且红的原因与被测代码无关。
    ///
    /// ⚠️ **`.ready` 那一态故意不再显示「检查更新」按钮**：Sparkle 正在等我们回答
    /// `.install`（`sessionInProgress` 为真），此时点「检查更新」是**没有反应**的
    /// （见 ``UpdateController/readyReply``）。给一个点了没反应的按钮，
    /// 与「功能坏了」长得一模一样 —— 所以那一态换成「立即重启」。
    @ViewBuilder
    private var updateCheckLine: some View {
        switch updateStateOverride ?? updateController.rowState {
        case .neverChecked:
            line(
                label: L10n.tr(.checkForUpdates),
                description: L10n.tr(.updateNeverChecked)
            ) { checkForUpdatesButton }

        case .upToDate(let date):
            line(
                label: L10n.tr(.checkForUpdates),
                description: String(
                    format: L10n.tr(.updateUpToDateFormat),
                    Self.updateCheckDateFormatter.string(from: date))
            ) { checkForUpdatesButton }

        case .checkFailed(let date):
            // ⚠️ **这一态取代的是原先的一句谎**（2026-09-28 用户报告）。
            // 此前「查到了、没有新版本」与「**根本没查成**（feed 取不到 / 超时）」
            // 共用 `updateUpToDateFormat` 那句「上次检查：… · 已是最新版本」，
            // 于是界面替用户下了一个它**没有依据**的结论（判据见 `UpdateController.CheckOutcome`）。
            //
            // ⚠️ **文案里不许出现「已是最新版本」** —— 那句断言只有在真正收到过
            // 「没有可用更新」时才允许出现。这里说的是**发生了什么事**（这次没查成），
            // 不是**结论**（有没有新版，此刻仍然未知）。
            //
            // ⚠️ **按钮用「重试」而不是「检查更新」**：`retryDownload()` 走的就是
            // `checkForUpdates()`（同一条路），而「重试」这个词准确说出了用户此刻的意图
            // —— 把上一次没成的那次重来一遍。两个词指同一个动作时，
            // 用那个**与上下文对得上**的（同 `.failed` / `.installFailed` 两态的做法）。
            line(
                label: L10n.tr(.checkForUpdates),
                description: String(
                    format: L10n.tr(.updateCheckFailedFormat),
                    Self.updateCheckDateFormatter.string(from: date))
            ) { retryUpdateButton }

        case .skipped(let version):
            line(
                label: L10n.tr(.checkForUpdates),
                description: String(format: L10n.tr(.updateSkippedFormat), version)
            ) { checkForUpdatesButton }

        case .checking:
            // ⚠️ **不给按钮**：此刻 Sparkle 正跑着，点「检查更新」是没有反应的
            // （`checkForUpdates()` 会先回到 `.idle` 再重来一遍，用户只看到闪一下）。
            // 给一个点了没反应的按钮，与「功能坏了」长得一模一样 —— 同 `.ready` 那条判据。
            //
            // ⚠️ **必须带 `description`**：面板是固定高度，而其余各态都有第二行
            // （进度条 / 说明 / 上次检查）。只有 label 的话实测会比别态矮 ——
            // §8.82 就是这么抓到「下载中（无百分比）」那一态的（矮 14.8pt）。
            line(
                label: L10n.tr(.updateChecking),
                description: L10n.tr(.updateCheckingHint)
            ) {
                EmptyView()
            }

        case .found(let version, let lastCheck):
            line(
                label: L10n.tr(.checkForUpdates),
                description: foundDescription(version: version, lastCheck: lastCheck),
                // 设计稿 B2 给这一行上了强调色：它是「有件事等你决定」，
                // 而其余几态都只是在陈述事实。
                descriptionAccent: true
            ) { viewUpdateButton }

        case .downloading(let version, let fraction):
            // `fraction == nil` = **百分比无从得知**（自动更新开着时那条路，§8.81）：
            // 那条路既不提供进度、也不提供取消入口
            // （`showDownloadInitiatedWithCancellation:` 由 `SPUUIBasedUpdateDriver` 发出，
            // 而自动那条路不经过它）。所以这一态**不画进度条、也不给「取消」** ——
            // 画一条停在 0% 的进度条、或给一个点了没反应的「取消」，
            // 都比什么都不画更让人怀疑（设计稿 B3 那条「百分比是真的，ETA 是编的」）。
            if let fraction {
                line(
                    label: String(format: L10n.tr(.updateDownloadingFormat), version),
                    progress: fraction
                ) { cancelUpdateButton }
            } else {
                // ⚠️ **这一支必须带一行说明，不能只有 label**（2026-09-19 实测，§8.82）：
                // 面板是**固定高度**，而其余各态都有第二行（进度条 / 说明 / 上次检查）——
                // 这一支既没有进度条也没有说明 ⇒ 实测比别态矮 **14.8pt**
                // ⇒ 切到这一态时底部会多出一条空白带（「更新行各态渲染出来必须一样高」
                // 就是这么抓到它的：走查图清单补上这一态之后立刻变红）。
                //
                // ⚠️ 这句说明必须对 `fraction == nil` 的**两种来源**都成立：
                // ① 自动那条路（全程 nil，终点是「退出应用时安装」）；
                // ② 手动那条路刚开始下载的那一瞬（随后有真进度，终点是「自动重启」）。
                // 所以只能说两句共同的那一句「下载完成后会自动安装」，
                // 不能写「退出时安装」—— 那对第 ② 种是假的。
                line(
                    label: String(format: L10n.tr(.updateDownloadingFormat), version),
                    description: L10n.tr(.updateDownloadingHint)
                ) {
                    EmptyView()
                }
            }

        case .ready(let version, let autoRestart):
            // ⚠️ **两句话不能合成一句**（2026-09-25，§8.146.2）：「会自动重启」对
            // **自动那条路**（`willInstallUpdateOnQuit`）是假的 —— 那条路上用户没点过
            // 任何东西，语义是「下次退出时静默装上」。而这一行**恰恰在自动那条路上
            // 待得最久**（弹窗那条路一进 `.ready` 就回答 `.install`，只有「有卷正在推出」
            // 那一段会停住）⇒ 写死「会自动重启」等于在唯一看得见它的路上说谎。
            line(
                label: String(format: L10n.tr(.updateReadyFormat), version),
                description: L10n.tr(autoRestart ? .updateReadyAutoHint : .updateReadyHint)
            ) { restartUpdateButton }

        case .failed(let version):
            line(
                label: String(format: L10n.tr(.updateFailedFormat), version),
                description: L10n.tr(.updateFailedHint)
            ) { retryUpdateButton }

        case .installFailed(let version):
            // ⚠️ **不复用 `updateFailedFormat` / `updateFailedHint`**（2026-09-22，账本第 43 行）：
            // 那两条写的是「下载失败 / 网络不可用」，而这一态**下载是成功的**
            // （失败的是解压 / 验签 / 安装）。用户照着「网络不可用」会去查网络，
            // 而真相跟他网络无关 —— 那是句谎，且这一态会一直挂着（不会一闪而过）。
            //
            // 「重试」仍然是同一个按钮：它走 `retryDownload()` ⇒ 重新检查并再走一遍
            // ⇒ 对「装不上去」是一次**真的**重试（不是点了没反应）。
            line(
                label: String(format: L10n.tr(.updateInstallFailedFormat), version),
                description: L10n.tr(.updateInstallFailedHint)
            ) { retryUpdateButton }

        case .locationBlocked:
            // ⚠️ **不给按钮**：我们没法替用户把 `.app` 搬进「应用程序」文件夹，
            // 而「重试」在只读卷上**必然再失败**（Sparkle 连 appcast 都不会去取，
            // §8.94）—— 那就是下一个「点了没反应的按钮」。
            //
            // 这一态替换掉的是原先的**谎报**：只读卷上检查更新后，界面会说
            // 「已是最新版本」并把「上次检查」刷成当下，而它其实**一次网络请求都没发**。
            line(
                label: L10n.tr(.updateLocationBlocked),
                description: L10n.tr(.updateLocationBlockedHint)
            ) {
                EmptyView()
            }
        }
    }

    /// 「发现新版本」那一行的说明（设计稿 B2：`发现 1.1.0 · 上次检查：今天 14:30`）。
    ///
    /// 上次检查时间缺失时退化成不带时间的写法 —— **不能显示成「上次检查：」后面空着**，
    /// 那看起来像「时间没读出来」，而不是「还没检查过」。
    private func foundDescription(version: String, lastCheck: Date?) -> String {
        guard let lastCheck else {
            return String(format: L10n.tr(.updateFoundShortFormat), version)
        }
        return String(
            format: L10n.tr(.updateFoundFormat), version,
            Self.updateCheckDateFormatter.string(from: lastCheck))
    }

    // MARK: 「更新」组的五个按钮（各自绑一个动作，不是同一段代码换标题）

    private var checkForUpdatesButton: some View {
        ActionButton(
            title: L10n.tr(.checkForUpdates),
            variant: .outline,
            size: .small,
            accent: accentColor,
            // 走 Sparkle：由它负责下载与安装，UI 只负责发起。
            // updater 起不来时 `checkForUpdates()` 内部会退回打开 Releases 页并记日志。
            action: { UpdateController.shared.checkForUpdates() }
        )
    }

    /// 「查看更新」是**主按钮**（设计稿 B2）：用户按过 Esc 之后，
    /// 这一行是唯一能回到弹窗的入口，它必须比「检查更新」更显眼。
    private var viewUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.updateView),
            variant: .primary,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.presentFoundUpdate() }
        )
    }

    private var cancelUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.cancel),
            variant: .outline,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.cancelDownload() }
        )
    }

    private var restartUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.restartNow),
            variant: .primary,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.installReadyUpdate() }
        )
    }

    private var retryUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.updateTryAgain),
            variant: .outline,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.retryDownload() }
        )
    }

    /// 「上次检查」的时间格式（设计稿是「今天 14:30」）。
    ///
    /// `doesRelativeDateFormatting` 负责把当天说成「今天」；**它跟随 `Locale.current`** ——
    /// 所以断言不许比这个字符串（见 ``updateStatusDescription`` 的说明）。
    private static let updateCheckDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        // **一个分类页 = 一块内容**（设计稿 09 页：标题在内容区头部，正文里不再有分组标题）。
        paneContent
            .padding(.top, SettingsMetrics.detailPaddingTop)
            .padding(.horizontal, SettingsMetrics.detailPaddingH)
            .padding(.bottom, SettingsMetrics.detailPaddingBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 回到前台时重探一次接管闸门。
            //
            // **为什么必须重探**：授「完全磁盘访问」这件事**只能在系统设置里做**，
            // 而用户走这一趟时本面板通常一直开着 —— 不重探的话，那一行会停在
            // 「去授权」的样子，而用户刚刚才把权限给了（同 ``ContentView/refreshFDAStatus()``
            // 挂在 `didBecomeActiveNotification` 上的理由）。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
                _ in
                refreshTakeOverAvailability()
            }
    }

    /// 当前分类该渲染哪一页。
    ///
    /// **为什么是 switch 而不是给 ``SettingsSection`` 挂一个 `@ViewBuilder` 属性**：
    /// 这五页用的全是本类型自己的私有计算属性与 `@State`（`languageControl` /
    /// `updateCheckLine` / `takeOverUnavailableControl` …），把渲染挪到枚举上就得把那些东西
    /// 整体上提或再包一层容器 —— 换来的只是少一个 switch。
    @ViewBuilder
    private var paneContent: some View {
        switch section {
        case .general: generalCard
        case .appearance: appearanceCard
        case .updates: updatesCard
        case .diagnostics: diagnosticsCard
        case .about: SettingsAboutPane(versionLine: versionLine)
        }
    }

    // MARK: 各分类页

    /// 外观页：视觉效果 / 强调色。
    private var appearanceCard: some View {
        settingsCard {
            line(
                label: L10n.tr(.visualEffects),
                description: L10n.tr(.transparentModeFootnote),
                divider: false
            ) {
                SettingsSegmentedControl(
                    // 可见标签用**短名**（设计稿规定「透明」/「色调」），
                    // 长名交给无障碍朗读 —— 两者都要，不能只留一个。
                    options: VisualStyle.allCases.map { ($0.rawValue, $0.shortName, $0.displayName) },
                    selection: $visualStyleRaw,
                    accent: accentColor
                )
            }
            line(label: L10n.tr(.accentColor)) {
                accentSwatches
            }
        }
    }
    /// 通用页：语言 / 登录时启动 / 推出时提醒占用。
    private var generalCard: some View {
        settingsCard {
            // 语言行是「通用」组的第一行（设计稿 `05-settings.html` 的位置）。
            // 顺序有理由：它是这一组里**唯一会「改了不立刻生效」**的一项，
            // 放在最前面，用户改完往下看时不会以为自己漏了什么。
            line(
                label: L10n.tr(.appLanguage),
                description: languageDescription,
                divider: false
            ) {
                languageControl
            }

            // （曾有「在 Dock 中显示图标」开关行，2026-10-22 随「纯菜单栏应用」决定移除：
            //   LSUIElement=true 后系统层面永不进 Dock，开关已无对象。）
            toggleLine(
                label: L10n.tr(.launchAtLogin),
                description: launchAtLoginDescription,
                // ⚠️ **不能直接把 `$launchAtLogin` 交给 `Toggle`**：这一行有副作用 ——
                // ``LaunchAtLoginManager/setEnabled(_:)`` 会失败（未签名 / 找不到登录项），
                // 失败时必须把用户拨过去的那一格**摇回去**并弹提示。
                // 用 `Binding` 把「读」与「写」分开，副作用留在 ``setLaunchAtLogin(_:)`` 里。
                isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) })
            )
            // 第三态（已注册、等系统批准）紧跟一行**受阻提示行**（设计稿第 2 帧的形态）。
            //
            // **为什么紧跟在登录行下面、而不是并进那一行**：它是一个**待办**，
            // 不是那个开关的属性 —— 开关本身的状态是「已注册」，没有任何问题；
            // 有问题的是「系统还没放行」这件事，而它只能由用户去系统设置里解决。
            // 并进登录行的话，「说明」位既要解释开关、又要交代待办，
            // 而这行说明在第三态下**本来就不该存在**（见 ``launchAtLoginDescription``）。
            if isLaunchAtLoginPendingApproval { loginPendingWarningLine }

            // 「推出时提醒占用」：默认关。放在「通用」页**最后一行** ——
            // 它是本页里唯一会改变**系统行为**（拦截别人的推出请求）的一项，
            // 前面几项都只影响本应用自己。
            //
            // ⚠️ **这一行有三态，判定全在 `takeOverAvailability` 一处**
            // （2026-09-28）：没授「完全磁盘访问」时，它画成「不可用 + 去授权引导」。
            // 那是本功能唯一会「开着却什么都不做」的情形 ——
            // 见 ``AppSettings/TakeOverAvailability`` 与 ``takeOverDescription``。
            // 可用时是**系统的开关行**（整行可点）；不可用时退化成普通行 +
            // 「打开系统设置」按钮 —— 那一行里放不下第二个可点控件，
            // 而「去哪把它打开」正是用户卡住的地方（见 ``takeOverUnavailableControl``）。
            if takeOverAvailability.isUsable {
                toggleLine(
                    label: L10n.tr(.takeOverFinderEject),
                    description: takeOverDescription,
                    isOn: Binding(
                        get: { takeOverOn },
                        set: { setTakeOverFinderEject($0) })
                )
            } else {
                line(
                    label: L10n.tr(.takeOverFinderEject),
                    description: takeOverDescription
                ) {
                    takeOverUnavailableControl
                }
            }
        }
    }
    /// 诊断页：错误日志（设计稿 09 页只有一行 —— 内容少就保持安静，
    /// **不为了「填满」而塞东西**）。
    private var diagnosticsCard: some View {
        settingsCard {
            line(
                label: L10n.tr(.logSectionTitle),
                description: L10n.tr(.logSectionHint),
                divider: false
            ) {
                // 设计稿这里是**行尾文字链接**（`.linkbtn`，图标在文字右侧），
                // 不是描边按钮 —— 详情见 ``TextLinkButton``。
                TextLinkButton(
                    title: L10n.tr(.revealLogInFinder),
                    // 设计稿的图标是 `externalLink`（ds.js）：**一个方框 + 一支
                    // 从方框右上角伸出去的箭头**，语义是「跳到别的地方去」。
                    // 曾经用 `arrow.up.forward`（一支裸箭头）—— 那是「向前/上一个」，
                    // 与「在访达里打开」不搭；裸箭头也读不出「会离开本应用」这层意思。
                    systemImage: "arrow.up.forward.square",
                    accent: accentColor,
                    action: { LogService.shared.revealLogInFinder() }
                )
            }
        }
    }

    /// 更新页：自动检查更新 / 自动下载更新 / 检查更新（后两行各是一个状态机）。
    private var updatesCard: some View {
        settingsCard {
            // **两个开关，不是一个**（2026-09-28 用户拍板）。
            //
            // 拆之前这里只有一行「自动更新」，它一个开关驱动 Sparkle 的**两个**
            // 标志（`SUEnableAutomaticChecks` / `SUAutomaticallyUpdate`），
            // 而行的**显示**只读前者 —— 于是默认态下「开关显示为开、说明写着
            // 『有新版本时自动下载』、实际走弹窗路」，三句话各说各的。
            // 拆开后每一行的显示、可点性、说明三者同源，不需要解释「开关开着
            // 为什么没自动下载」。
            toggleLine(
                label: L10n.tr(.autoCheckUpdate),
                description: autoCheckUpdateDescription,
                // updater 没起来时**整行不可拨** —— 否则用户拨一下、
                // 开关动一下、实际什么都没发生（没人会去写那两个标志）。
                //
                // ⚠️ **这个条件不许读开关自己的值**（2026-09-21 真机修的 bug）：
                // 读了就变成单向开关 —— 关一次就再也打不开（§8.113.14）。
                isOn: Binding(
                    get: { autoCheckUpdateOn },
                    set: { setAutoCheckUpdate($0) }),
                isEnabled: canAutoUpdate,
                divider: false
            )
            toggleLine(
                label: L10n.tr(.autoDownloadUpdate),
                description: autoDownloadUpdateDescription,
                // ⚠️ 不可拨的第二个原因见 ``autoDownloadUpdateEnabled``：
                // 「自动检查更新」关着时 Sparkle 会**静默丢弃**这次写入，
                // 所以这时整行不可拨，且说明文字会换成「需先打开上面的…」。
                isOn: Binding(
                    get: { autoDownloadUpdateOn },
                    set: { setAutoDownloadUpdate($0) }),
                isEnabled: autoDownloadUpdateEnabled
            )
            // 第三行是**一个状态机**（七种画法），见 ``updateCheckLine``。
            updateCheckLine
        }
    }

    // MARK: 卡片骨架

    /// 卡片容器（设计稿 `.scard`）：`bg-raised` + 内描边 + e1，行与行之间有内缩分隔线。
    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 0.5)
        )
        .shadow(
            color: DesignTokens.Elevation.e1.color,
            radius: DesignTokens.Elevation.e1.radius,
            y: DesignTokens.Elevation.e1.y
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }

    /// 行的左侧文字块：标签 + 可选说明 / 进度条。**普通行与开关行共用**。
    ///
    /// `progress` 给「后台下载中」那一行用（设计稿 B3）：说明位换成一个**固定 16pt 高**
    /// 的行内进度条。**高度必须固定** —— 与说明行同高，下载中这一行就不会被撑高，
    /// 于是整块面板在下载过程中不会跳一下。
    ///
    /// `descriptionAccent` 给「发现新版本」那一行用（设计稿 B2 的 `style="color:var(--accent)"`）。
    @ViewBuilder
    private func lineLabel(
        label: String,
        description: String?,
        progress: Double? = nil,
        descriptionAccent: Bool = false,
        tone: SettingsLineTone
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: DesignTokens.FontSize.body))
                // 受阻行的标签换成琥珀字（设计稿 `.sline--warn .sline__label`）。
                // ⚠️ **这一处不能省**：只加底色不改字色，浅琥珀底上仍是黑字 ——
                // 画面上「看着做了、其实没做」，正是本仓库那条红线
                // （样式没生效与本来没写逐字相同）。设计稿在 `.sline--warn` 的注释里
                // 特意点了同一件事，两边是同一个坑。
                .foregroundStyle(
                    tone == .warning
                        ? DesignTokens.Palette.warningText
                        : DesignTokens.Palette.foreground
                )
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.body
                )
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                SettingsProgressLine(fraction: progress, accent: accentColor)
            } else if let description {
                Text(description)
                    .font(.system(size: DesignTokens.FontSize.footnote))
                    .foregroundStyle(
                        descriptionAccent
                            ? accentColor.swiftUIColor
                            : DesignTokens.Palette.mutedForeground
                    )
                    .designLineHeight(
                        DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一行的**外框**：内边距 + 最小高 + 受阻底色 + 顶部分隔线。
    ///
    /// 抽出来只为一件事：**普通行与开关行必须长得一模一样**（设计稿里它们同是 `.sline`）。
    /// 而「高度预算」在本页是硬约束（面板高度按英文最坏情况夹逼而成），
    /// 两处各写一遍 padding，改了其中一处就会得到「某些行 44、某些行 43」——
    /// 这种偏差只在最坏语言下暴露。
    ///
    /// ⚠️ **分隔线必须在底色之上**：`.overlay` 排在 `.background` 之后，
    /// 与设计稿 `.sline + .sline { box-shadow: inset … }`（同样是「背景之上再压一条线」）
    /// 同序。反过来的话受阻行顶上那条线会被吃掉。
    @ViewBuilder
    private func lineFrame<Content: View>(
        tone: SettingsLineTone,
        divider: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, SettingsMetrics.linePaddingH)
            .padding(.vertical, SettingsMetrics.linePaddingV)
            .frame(minHeight: SettingsMetrics.lineMinHeight)
            // 底色加在**整行的盒子**上（含上面那圈内边距），与设计稿 `.sline--warn`
            // 覆盖整个 `padding: 11px 12px` 盒一致 —— 加在内边距之前会缩成一小块色斑。
            .background(tone == .warning ? SettingsMetrics.warnRowBackground : Color.clear)
            .overlay(alignment: .top) {
                if divider { Hairline() }
            }
    }

    /// 一行设置项（设计稿 `.sline`）：左侧标签 + 可选说明，右侧控件。
    ///
    /// `divider` 只应给**卡片内第二行起**的行设为 `true` —— 设计稿的规则是
    /// `.sline + .sline`，首行上方不该顶着一条横线（那会让卡片看起来被切成两半）。
    ///
    /// ## 它现在只服务**非开关**行
    ///
    /// 开关行走 ``toggleLine(label:description:isOn:isEnabled:divider:tone:)`` —— v3 把开关
    /// 交还系统的 `Toggle` 之后，「整行可点」由 `Toggle` 的 label 天然承担，
    /// 不再需要这里自绘一层按钮容器（那层 `SettingsLineButton` 已随本轮退役）。
    ///
    /// ⇒ 本方法**同时删掉了 `onTap` 与 `accessibilityValue` 两个参数**：
    /// 前者的语义曾是「传 `nil` 就不包可点容器」（既有约定：控件不可用优先靠**结构**实现），
    /// 现在没有可点容器了，那条约定由各控件自己承担（开关行走 `.disabled`）；
    /// 后者是专门给自绘开关补「开 / 关」语义的，系统 `Toggle` 自带。
    ///
    /// `tone` 给**受阻行**用（设计稿 `.sline--warn`：琥珀浅底 + 琥珀标签）。
    /// 只换颜色、**不动布局** —— 布局仍走同一个 ``lineFrame(tone:divider:content:)``，
    /// 理由见 ``SettingsLineTone``。
    @ViewBuilder
    private func line<Control: View>(
        label: String,
        description: String? = nil,
        progress: Double? = nil,
        descriptionAccent: Bool = false,
        divider: Bool = true,
        tone: SettingsLineTone = .normal,
        @ViewBuilder control: () -> Control
    ) -> some View {
        lineFrame(tone: tone, divider: divider) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                lineLabel(
                    label: label, description: description, progress: progress,
                    descriptionAccent: descriptionAccent, tone: tone)
                control()
            }
        }
    }

    /// **开关行**：整行可点，开关本体交还系统。
    ///
    /// ## 为什么单独一个方法
    ///
    /// v3 把开关交还系统（`Toggle` + `.toggleStyle(.switch)`）：形状、玻璃、hover、
    /// 焦点环、开关动画全部由系统给，我们只负责**颜色**（强调色经 `.tint` 注入）。
    ///
    /// ## 「整行可点」必须一起保住（HANDOFF §3.4 点名的最容易做丢的一条）
    ///
    /// 既有约定是：只把开关本体做成命中区时，用户瞄准稍有偏差就点空、什么都不发生
    /// —— 主观感受就是「点了没反应」。所以整行都要能点。
    ///
    /// macOS 上 `Toggle` 的 **label 区域本来就是可点的** ⇒ 把整行做成它的 label 即可。
    /// label 里那句 `frame(maxWidth: .infinity)`（在 ``lineLabel`` 里）是让它**撑满**
    /// 到开关左侧 —— 否则只有文字那几像素可点，等于没做。
    /// **不需要**再包一层自绘手势，那会退回自绘老路。
    ///
    /// ## 无障碍
    ///
    /// 系统的 `Toggle` 自带「开 / 关」的值语义，VoiceOver 会读它 ——
    /// 这里因此**不再有** `accessibilityValue` 参数（那个参数是给自绘开关补的：
    /// 它当时是 `accessibilityHidden`，不补就永远读不出当前是开还是关）。
    @ViewBuilder
    private func toggleLine(
        label: String,
        description: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        divider: Bool = true,
        tone: SettingsLineTone = .normal
    ) -> some View {
        lineFrame(tone: tone, divider: divider) {
            Toggle(isOn: isOn) {
                lineLabel(label: label, description: description, tone: tone)
            }
            .toggleStyle(.switch)
            .tint(accentColor.swiftUIColor)
            // **不可用靠结构**（`.disabled`），不是「允许点一下再弹错」。
            // 关掉之后整行（含 label）都不响应，这正是要的。
            .disabled(!isEnabled)
        }
        // 行级 hover 底（`--bg-subtle`）：v3 把开关交还系统 `Toggle` 后，
        // 系统**不给**行级 hover（2026-09-30 用户反馈「开关项 hover 效果没有了」），
        // 这里补回。只在**可交互**的开关行启用 —— 说明 / 分组标题这类静态行
        // 悬停高亮反而是在暗示「可点」。@State 必须住在独立的 modifier 里：
        // 若放在 pane 上，所有开关行共享一份 hover 态，悬停一行全体高亮。
        .modifier(ToggleRowHover(interactive: isEnabled))
    }

    /// 切换「接管访达的推出」。
    ///
    /// ⚠️ **打开时必须顺带把占用轮询启动起来**（``EjectHookService/syncOccupancyPolling()``）：
    /// ``OccupancyStore`` 是懒加载单例，不主动创建的话，
    /// 「开着开关、但没打开过主窗口、直接在访达点推出」这条**本功能的目标路径**
    /// 会读到空缓存 ⇒ 一律放行 ⇒ 功能静默不生效。
    ///
    /// 关掉时不销毁 `OccupancyStore`：它可能正被主窗口/菜单栏用着，
    /// 而且「关掉开关」的语义只是「别再拦」，不是「把占用检测停掉」。
    ///
    /// ⚠️ **打开时还要向用户说两件事**（申请通知授权、提示那项可选的辅助功能权限）。
    /// 触发时机是刻意的：用户**刚打开**功能，此刻弹框有上下文；
    /// 放在启动时申请，会让从没用过这个功能的用户也挨一个框
    /// （见 ``EjectNotificationService/start(onOpenPanel:)`` 的理由）。
    /// 具体怎么说是宿主的决定（弹窗状态在 ``MainDetailView`` 上）——
    /// 这里只上抛「他打开了」这一个事实。
    ///
    /// ⚠️ **收的是目标值，不是「拨一下」**：交给 `Toggle` 的 binding 驱动之后，
    /// toggle 语义要靠「读现在的值再取反」，快速连点会写反（同 ``setAutoCheckUpdate(_:)``）。
    private func setTakeOverFinderEject(_ newValue: Bool) {
        takeOverFinderEject = newValue
        EjectHookService.syncOccupancyPolling()
        guard newValue else { return }
        onTakeOverEnabled()
    }

    // MARK: 接管行（三态：可用 / 未授权）

    /// 开关**画出来**的那个值。
    ///
    /// 不可用时一律「关」—— **界面上的每一个像素都要对应真实行为**：
    /// 画成「开」而实际什么都不会发生，是这一行最不能犯的错。
    /// 用户偏好**不被改写**（授权后自动回到意愿值），代价与理由见
    /// ``AppSettings/TakeOverAvailability/effectiveIsOn(userWants:availability:)``。
    private var takeOverOn: Bool {
        AppSettings.TakeOverAvailability.effectiveIsOn(
            userWants: takeOverFinderEject, availability: takeOverAvailability)
    }

    /// 接管那一行的说明：**不可用时换成「缺什么」**。
    ///
    /// **就地说明**是这一行不可用时的全部交代 —— 把它删掉，用户看到的就是一个
    /// 拨不动、也不说为什么的开关（同 ``autoCheckUpdateDescription`` 的教训：
    /// 「设了没生效」与「没设」不能长得一样，而**说不出原因**等于两者都不成立）。
    private var takeOverDescription: String {
        takeOverAvailability.isUsable
            ? L10n.tr(.takeOverFinderEjectFootnote)
            : L10n.tr(.takeOverFinderEjectNeedsFDA)
    }

    /// **不可用**时的行尾：一个可点的开关（恒显示「关」）+「打开系统设置」。
    ///
    /// **为什么开关仍然画出来**：它是「本应用有这么一个设置项」的锚点。
    /// 整行换成按钮会让用户以为功能被拿掉了，而他要的只是「去哪把它打开」。
    /// 所以这一态**没有**走 ``toggleLine(label:description:isOn:isEnabled:divider:tone:)``
    /// —— 那个方法里只有 `Toggle` 一个尾巴，塞不下第二个可点控件。
    ///
    /// **为什么开关保持可点、而不是 `.disabled(true)`**（2026-10-22 用户报告）：
    /// 禁用态下点开关**什么都不会发生** —— 「打开一个开关，然后它静默地什么都不做」
    /// 是最难自查的一类缺陷；唯一入口只剩旁边那颗不显眼的按钮。
    /// 现在点击即上抛 ``onTakeOverNeedsFDA``（宿主弹 ``SettingsPrompt/takeOverNeedsFDA()``），
    /// 开关本身**不写偏好**、恒显示「关」 —— 显示口径见
    /// ``AppSettings/TakeOverAvailability/effectiveIsOn(userWants:availability:)``。
    ///
    /// **为什么旁边那个按钮仍然保留**：弹窗给「为什么」，按钮给「直达」——
    /// 已经知道原因的用户不必再看一遍弹窗。
    /// `x-apple.systempreferences:` 是**唯一**能直接跳到该子面板的手段，
    /// 全仓只有 ``AppSettings/openFullDiskAccessSettings()`` 一处实现（主窗口横幅同源）。
    ///
    /// ⚠️ 开关 `labelsHidden()`：文字已经在左边那一列，`Toggle` 再把空 label 画一遍
    /// 会在行首留一段莫名缩进。
    private var takeOverUnavailableControl: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Toggle(
                "",
                isOn: Binding(
                    get: { takeOverOn },
                    set: { newValue in
                        // 只响应「拨向开」：显示值恒为关，拨向关在这里不是真实手势。
                        guard newValue else { return }
                        onTakeOverNeedsFDA()
                    })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            ActionButton(
                title: L10n.tr(.openSystemSettings),
                variant: .outline,
                size: .small,
                accent: accentColor,
                action: AppSettings.openFullDiskAccessSettings
            )
        }
    }

    /// 重探接管闸门（回到前台、也就是刚从系统设置回来时）。
    ///
    /// ⚠️ **注入口不为空时直接返回**：出图与单测里的状态是**写死的**，
    /// 不许被这台机器上的真实权限状态覆盖（同 ``autoUpdateRowOverride`` 的纪律）。
    private func refreshTakeOverAvailability() {
        guard takeOverAvailabilityOverride == nil else { return }
        takeOverAvailability = AppSettings.takeOverAvailability()
    }

    /// 切换开机启动（失败原因上抛给宿主弹提示）。
    ///
    /// ⚠️ **收的是目标值**（`Toggle` 的 binding 直给），不再是「拨一下」——
    /// 见 ``setTakeOverFinderEject(_:)`` 与 ``setAutoCheckUpdate(_:)`` 的同一条理由。
    private func setLaunchAtLogin(_ newValue: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(newValue)
            launchAtLogin = newValue
        } catch let error as LaunchAtLoginError {
            launchAtLogin = newValue
            onLaunchAtLoginError(error)
        } catch {
            onLaunchAtLoginError(.system(underlying: "\(error)"))
        }
    }

    // MARK: 强调色

    /// 色板（设计稿 `.swatch` 22 × 22 圆，选中态外描边 2px、偏移 4）。
    private var accentSwatches: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ForEach(AccentColor.allCases, id: \.self) { color in
                AccentSwatch(
                    color: color,
                    isSelected: accentColor == color,
                    onTap: {
                        accentColorRaw = color.rawValue
                        // 同步系统侧强调色 —— 侧栏选中胶囊的唯一颜色来源
                        //（2026-10-22 macOS 27 实证，见 ``AppSettings/syncAppleAccentColor()``）。
                        // ⚠️ 不能靠 `UserDefaults.didChangeNotification` 兜底：实测它
                        // 对写入并不可靠送达（写入后键值纹丝不动），必须在写入点显式同步。
                        AppSettings.syncAppleAccentColor()
                    }
                )
            }
        }
    }

    // MARK: 登录项说明（含「需批准」第三态）

    /// 登录项是否处于**第三态**：已注册、但等待用户在系统设置里批准。
    ///
    /// **单一事实来源**：这一态同时决定三件事 —— 登录行的说明去留、
    /// 下面那条受阻行出不出现、以及高度契约（设计稿第 2 帧 368.28）。
    /// 三处读同一个判据，不各写一遍 `== .requiresApproval`。
    ///
    /// ⚠️ `launchAtLoginStateOverride` 优先（离屏出图与单测用），与
    /// ``takeOverAvailabilityOverride`` 同一条纪律：注入口不为空时不许读真实状态。
    private var isLaunchAtLoginPendingApproval: Bool {
        (launchAtLoginStateOverride ?? LaunchAtLoginManager.state) == .requiresApproval
    }

    /// 登录项说明文案。
    ///
    /// **第三态下返回 `nil`（这一行没有说明）** —— 设计稿第 2 帧就是这么画的。
    ///
    /// ## 为什么不是「换成 `launchAtLoginPendingHint`」（单栏时代的做法）
    ///
    /// 默认态那句话是「开机后自动驻留菜单栏，插盘即可用。」——
    /// 而第三态恰恰**不会**自动启动，这句话此刻是**假的**。
    /// 换文案只是让它不再是假话，但代价是：登录行成了一条「说明会跟着状态变」的行，
    /// 而块里已经有一行专门讲这件事了（``loginPendingWarningLine``）——
    /// 同一句话在屏幕上出现两遍，读起来像两个问题。
    ///
    /// ⇒ 移走说明、另起一行讲待办，是设计稿的取舍，也是这里跟的版本。
    ///
    /// ⚠️ **移走说明之后，这一行在视觉上会「矮」**（剩一个只有标签 + 开关的行）。
    /// 那是**正确**的：`launchAtLoginPendingHint` 一个字都没少，
    /// 它整体搬到了下一行（那里还多了「后果」和「出口」）。
    /// 高度契约由 `SettingsLayoutTests.登录项待批准态的高度等于设计稿()` 钉住。
    private var launchAtLoginDescription: String? {
        // 第三态：这一行**不解释** —— 待办在下一行（`loginPendingWarningLine`）。
        isLaunchAtLoginPendingApproval ? nil : L10n.tr(.launchAtLoginFootnote)
    }

    /// 「登录项等待系统批准」的**受阻行**（设计稿 09 页第 2 帧的 `.sline--warn`）。
    ///
    /// 形态与设计稿逐项对应：标签「等待系统批准」+ 说明「注册已提交，但还需在系统设置中
    /// 手动打开，否则不会自动启动。」+ 行尾一支 outline 小按钮（与头部「完成」同款）。
    ///
    /// ## 为什么这一行值得存在（而不是只靠拨开关失败时那条 alert）
    ///
    /// 那条 alert 是**动作的反馈**（用户拨了开关、失败了，告诉他为什么），
    /// 而这一行是**状态的呈现**：它常驻，直到用户真去系统设置里批准。
    /// 两者**不是二选一** —— 用户完全可能先看到 alert 又划走、
    /// 或者根本没碰过开关却处在待批准态（换台机器、从备份恢复、系统更新后复位…）。
    /// 只有 alert 的话，后一种用户的界面上**看不到任何异常**。
    ///
    /// ## 为什么按钮是 `.outline` 而不是 `.primary`
    ///
    /// 设计稿这里是 `btn btn--outline btn--sm`。语义上也对：它是一个**出口**、
    /// 是这一行自己的行动，但不是这一屏的主行动 —— 主行动仍然是头部的「完成」。
    ///
    /// ⚠️ **整行不可点**（`line` 的 `onTap` 留空）：这一行不是开关行，
    /// 全行可点会让「点说明文字」也跳系统设置。唯一的命中区就是这支按钮。
    ///
    /// ## 关于色调
    ///
    /// 用 `.warning` 而不是自配色：它的判据（**受阻、不会自愈、恢复在用户手上**）
    /// 三条同时成立，是设计稿 §2.1 给出的琥珀合法实例。
    /// 别处若想借这个色调，先对着那三条判据核一遍。
    private var loginPendingWarningLine: some View {
        line(
            label: L10n.tr(.launchAtLoginPendingTitle),
            description: L10n.tr(.launchAtLoginPendingHint),
            tone: .warning
        ) {
            // 复用 ``LaunchAtLoginManager/openSystemSettings()``（内部走
            // `SMAppService.openSystemSettingsLoginItems()`，系统官方入口）——
            // 与 `makePrompt(for:)` 里 `.requiresApproval` 那条 alert 是**同一个出口**，
            // 不为同一个目的地写第二份 URL 拼接。
            ActionButton(
                title: L10n.tr(.openSystemSettings),
                variant: .outline,
                size: .small,
                accent: accentColor,
                action: LaunchAtLoginManager.openSystemSettings
            )
        }
    }

    // MARK: 版本行（「关于」页用）

    /// 版本行（设计稿 `.aboutpane__ver`）：`版本 1.0.0 · 构建 42 · Developer ID 直发版`。
    ///
    /// **由本类型拼好后传给 ``SettingsAboutPane``**，而不是让那个视图自己去读 ——
    /// 单栏版（`05-settings.html` 的 `.aboutrow`）画的是同一句话，
    /// 两处各拼一遍迟早会漂，而它是用户报 bug 时唯一能给出的定位信息。
    ///
    /// ⚠️ 三个值的来源与兜底理由见 ``appVersion`` / ``buildNumber`` / ``channelName``。
    private var versionLine: String {
        String(format: L10n.tr(.versionLineFormat), appVersion, buildNumber, channelName)
    }
}

/// 「关于」页（设计稿 09 页第 6 帧 `.aboutpane`）：**居中大图标** + 名称 + 版本行。
///
/// ## 为什么它从「横排一行」变回「居中大图标」
///
/// 单栏版把它压成 70pt 的**横排一行**（旧 `aboutRow`），理由是原话：
/// 「居中大图标 + 竖排版本号要吃 206pt」—— 而当时面板高度已经不够。
/// 两栏之后「关于」独占一页、高度宽裕，macOS 的标准「关于」形态（大图标居中）
/// 才重新变得划算。**同一个决策，在不同的约束下正确答案会翻转** ——
/// 所以 05 页保留在册：它是那套约束下的正确答案，不是「做错的版本」。
///
/// ⚠️ **图标不复用 ``IconBadge``**：那个组件的每一种样式都是「行内徽标」
/// （`subtle` 底 + 彩色前景，见它自己的 `configuration()`）。设计稿给这里的规格是
/// **accent 实底 + 白色图标 + e2 阴影 + 40pt 图标**（`.aboutpane__icon`）——
/// 硬塞进去要么给它加两个只被这一处消费的字段，要么视觉退化。一次性控件就地画更诚实。
struct SettingsAboutPane: View {

    /// 版本行（由 ``SettingsSectionPane/versionLine`` 拼好传入）。
    let versionLine: String

    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue

    private var accent: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

    var body: some View {
        VStack(spacing: 0) {
            icon

            Text(L10n.tr(.appName))
                .font(.system(size: DesignTokens.FontSize.heading, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
                // ⚠️ **行高必须显式给**（2026-09-29 补，`DesignSizeParityTests` 那条
                // 「中文下每页与设计稿逐点相同」抓到的）：
                // `.aboutpane__name` 只写了 `font-size: 17px`，行高是**继承**来的 ——
                // 继承链的底是 `ds.css` 的文档基准 `line-height: 1.45`。
                // 不给就走 CoreText 给这个字号的自然行高（≈20.4），比 1.45 倍矮 **4.25pt**；
                // 版本行同理矮 2.4pt ⇒ 整页比设计稿矮 **7.03pt**。
                // 「少写一个修饰符」与「本来就没有」在渲染图上长得一模一样 ——
                // 这正是本仓库反复吃亏的那一类，所以由布局契约测试钉住绝对值。
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.heading
                )
                .padding(.top, DesignTokens.Spacing.lg)

            Text(versionLine)
                .font(.system(size: DesignTokens.FontSize.caption))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                // 行高理由同上（`.aboutpane__ver` 也是继承 1.45）。
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.caption
                )
                .padding(.top, 5)
                .lineLimit(1)
                .truncationMode(.tail)

            // **脏构建要说出来**（2026-09-17 用户发现版本号停在 9/13）。
            //
            // 理由与单栏版逐字相同（版本号取自最近的 tag、构建号是提交总数，
            // 两者都只反映**已提交**的代码 —— 工作区有未提交改动时，
            // 「版本 2026.09.13.1 · 构建 44」会把报 bug 的人带到错误的代码上）。
            // 只在工作区真有未提交改动时出现：干净构建下这一行完全不存在、不占位。
            if let dirty = AppVersionInfo.dirtyCount(), dirty > 0 {
                Text(
                    String(
                        format: L10n.tr(.versionDirtyNoticeFormat), dirty,
                        AppVersionInfo.commit() ?? "—")
                )
                .font(.system(size: DesignTokens.FontSize.footnote))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Palette.warningText)
                .padding(.top, DesignTokens.Spacing.sm)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
        // 设计稿 `.aboutpane { padding-top: var(--s-6) }`（`--s-6` = 24）。
        .padding(.top, DesignTokens.Spacing.xxl)
        .accessibilityElement(children: .contain)
    }

    /// 76 × 76 / 圆角 14 / accent 实底 + 白图标 40 / e2 阴影（设计稿 `.aboutpane__icon`）。
    private var icon: some View {
        Image(systemName: "eject.fill")
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: DesignTokens.Size.aboutPaneIcon, height: DesignTokens.Size.aboutPaneIcon)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                    .fill(accent.swiftUIColor)
            )
            .shadow(
                color: DesignTokens.Elevation.e2.color,
                radius: DesignTokens.Elevation.e2.radius,
                y: DesignTokens.Elevation.e2.y
            )
    }
}

// MARK: - 强调色色板（设计稿 `.swatch`）

private struct AccentSwatch: View {
    let color: AccentColor
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(
                    width: DesignTokens.Size.swatchSize,
                    height: DesignTokens.Size.swatchSize
                )
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
                )
                // 选中态：外描边 2px、偏移 4（设计稿 `inset: -4px`）。
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(color.swiftUIColor, lineWidth: 2)
                            .padding(-DesignTokens.Size.swatchRingOffset)
                    }
                }
                .scaleEffect(hovering ? 1.12 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRing()
        .onHover { hovering = $0 }
        .help(color.displayName)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 分段控件（设计稿 `.seg` / `.seg__opt`）

/// 自定义分段控件。
///
/// **为什么不用原生 `Picker(.menu)`**：踩过的两个坑 ——
/// ① 「原生 Picker + 手写 chevron」会让控件上有**两个箭头**（系统 pop-up 自带一组）；
/// ② `Menu` + `.menuStyle(.borderlessButton)` 想藏箭头时，SwiftUI 把 label 折成
///    `NSButton` 的 image + title，**背景与描边被丢弃、箭头还被挪到文字左边**。
/// 设计稿给的是「外高 28（2 内边距 + 24 选项）」的分段控件，自己画反而最简单可靠：
/// 没有系统指示器、没有样式丢失，点击行为由 SwiftUI `Button` 保证。
/// 非 `private`：`SettingsLayoutTests` 要单独量它的固有宽度，
/// 钉住「控件不许把同行的标签列挤成竖排」（与 `SettingsSectionPane` 同样的放开理由）。
struct SettingsSegmentedControl: View {
    /// (值, 可见短标签, 无障碍全名)
    ///
    /// **为什么可见标签必须是短的**：末尾的 `.fixedSize()` 让控件**无视可用宽度**、
    /// 强占固有宽度（这是药丸外观需要的）。同行的标签列是 `maxWidth: .infinity` 的弹性列，
    /// 于是「控件要多少、标签列就剩多少」。用长标签时实测溢出 305pt，
    /// 标签被压成竖排单字（详见 ``VisualStyle/shortName``）。
    let options: [(rawValue: String, title: String, accessibilityTitle: String)]
    @Binding var selection: String
    let accent: AccentColor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.rawValue) { option in
                let isSelected = selection == option.rawValue
                Button {
                    selection = option.rawValue
                } label: {
                    Text(option.title)
                        .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? DesignTokens.Palette.foreground
                                : DesignTokens.Palette.mutedForeground
                        )
                        .lineLimit(1)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? DesignTokens.Palette.raised : Color.clear)
                        )
                        .shadow(
                            color: isSelected ? DesignTokens.Elevation.e1.color : .clear,
                            radius: DesignTokens.Elevation.e1.radius,
                            y: DesignTokens.Elevation.e1.y
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disableFocusRing()
                // 视觉上只有「透明」两个字，VoiceOver 念完整表述，
                // 否则用户听到的选项名没有说明「透明什么」。
                .accessibilityLabel(option.accessibilityTitle)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DesignTokens.Palette.subtle)
        )
        .fixedSize()
    }
}

// MARK: - 行内下载进度（设计稿 `.progressline`）

/// 设置行里的行内下载进度（设计稿 `08-update.html` B3）。
///
/// **为什么只画百分比、不画「还需 1 分钟」**：下载有确定的字节数，进度条说的是实话；
/// 而「还需 1 分钟」在任何网络下都是猜的。设计稿把这条写成了硬规则 ——
/// 「百分比是真的，ETA 是编的」。（主窗口那条「推出中」不画进度，理由正好相反：
/// 系统的推出接口不提供进度。）
///
/// **外层固定 16pt 高**：与说明行同高，于是这一行不会被撑高
/// （见 ``DesignTokens/Size/settingsProgressLineHeight``）。
///
/// 与 ``StorageMeter`` 的差别只有两处：百分比**不固定宽**（设计稿给 `.progressline`
/// 单独写了 `width: auto`），以及没有「高用量转琥珀」那套 ——
/// 下载到 90% 不是预警，是快好了。
struct SettingsProgressLine: View {

    /// 0…1。
    let fraction: Double
    var accent: AccentColor = .default

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Palette.subtle)
                    Capsule(style: .continuous)
                        .fill(accent.swiftUIColor)
                        .frame(width: clamped * proxy.size.width)
                }
            }
            .frame(height: DesignTokens.Size.meterHeight)

            Text(percentText)
                .font(.system(size: DesignTokens.FontSize.groupTitle, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .fixedSize()
        }
        .frame(height: DesignTokens.Size.settingsProgressLineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.tr(.usagePercentFormat), clamped * 100))
    }

    /// **夹到 0…1**：服务器给的总长可能偏小（`showDownloadDidReceiveExpectedContentLength`
    /// 的文档明确说这个值可能不准），不夹的话填充宽度会超出轨道。
    private var clamped: Double { min(max(fraction, 0), 1) }

    private var percentText: String { String(format: "%.0f%%", clamped * 100) }
}

// MARK: - 下拉（设计稿 `.popup`）

/// 设置面板里的下拉（设计稿 `.popup`：28pt 高、`--bg-subtle` 底 + 内缩发丝描边、11pt chevron）。
///
/// **为什么是手绘 + `popover`，而不是原生 `Menu` / `Picker(.menu)`**（2026-09-18 实测两次）：
///
/// | 写法 | 结果 |
/// |---|---|
/// | `Menu` + `.menuStyle(.borderlessButton)` | 标签被折成 `NSButton` 的 image+title，**箭头被挪到文字左边** |
/// | `Menu` + 默认样式（去掉 `menuStyle`） | 箭头回到右边了，但**系统按钮外观盖掉自绘的底色与描边**（白底 + 系统描边） |
///
/// 两条都做不到「设计稿的样子」。这与 ``SettingsSegmentedControl`` 是同一个结论：
/// 需要精确外观时，借系统的**行为**可以，借系统的**外观**不行 ——
/// 所以这里 `popover` 借弹出行为，按钮与选项列表全部自绘。
///
/// ⚠️ **`popover` 的内容在离屏出图里不渲染**（没有窗口就没有弹出层）——
/// 走查图只能核对闭合态。选项列表的样子要靠单测或真机看。
///
/// 非 `private`：`SettingsLayoutTests` 要单独量它的固有宽度 ——
/// 与分段控件一样，它是行内**不可压缩**的元素，会挤同行的标签列。
struct SettingsPopUp<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    let accessibilityLabel: String

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            chrome
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRing()
        // 宽度由**最长的那一项**决定，不许被同行标签列压缩 ——
        // 压窄的结果是文字被截成「跟…」，用户看不出选了什么。
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title(selection))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            optionList
        }
    }

    /// 闭合态：当前值 + chevron。
    private var chrome: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title(selection))
                .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: DesignTokens.Size.popUpHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// 展开态：选项列表，当前项打勾。
    ///
    /// **必须有选中记号**：不打勾的话用户得靠「记住刚才选了什么」来判断，
    /// 而这里恰好有一个「选了但还没重启生效」的中间态 —— 记错就会以为没生效。
    private var optionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                    isOpen = false
                } label: {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(title(item))
                            .font(.system(size: DesignTokens.FontSize.caption))
                            .foregroundStyle(DesignTokens.Palette.foreground)
                            .lineLimit(1)
                        Spacer(minLength: DesignTokens.Spacing.lg)
                        if item == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignTokens.Palette.foreground)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disableFocusRing()
            }
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(minWidth: 140)
    }
}
