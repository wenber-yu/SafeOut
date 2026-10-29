import AppKit
import SwiftUI

// MARK: - 侧栏导航项（v3：主窗口与设置合并）

/// 主窗口侧栏的一个导航项。
///
/// ## 为什么是枚举而不是「两套并列的列表」
///
/// v3 之前是**两个窗口**：主窗口只有磁盘列表，设置是独立窗口、自带一条自绘左栏
/// （`SettingsSidebarItem`）。合并之后同一列里既有「外置磁盘」也有五个设置分类，
/// 于是「选中项 → 详情区画什么」需要一个**封闭集合**来表达。
///
/// 若改用两个平行的清单（一列标题 + 一处 `switch`），加一个导航项要改两处，
/// 而漏掉任何一处**都不会报错**（图标空白、标题串到隔壁页）。
///
/// ## 与 ``SettingsSection`` 的关系
///
/// `.settings(_)` 直接**持有**那个枚举，不复制一份：
/// 设置分类的标题、图标、顺序全部仍是 ``SettingsSection`` 那一处的知识
/// （它的 `allCases` 顺序就是侧栏顺序，见 `SettingsSectionNavigationTests`）。
enum MainNavItem: Hashable, Identifiable {

    /// 磁盘列表（应用主角）。
    case disks

    /// 设置的某一个分类页。
    case settings(SettingsSection)

    var id: String {
        switch self {
        case .disks: return "disks"
        case .settings(let section): return "settings.\(section.rawValue)"
        }
    }

    /// 「设置」分组里的五项，顺序即显示顺序。
    static var settingsItems: [MainNavItem] {
        SettingsSection.allCases.map(MainNavItem.settings)
    }

    /// 侧栏那一行的文字，也是详情区头部的标题。
    ///
    /// ⚠️ **计算属性，不是 `static let`**：`L10n.tr` 依赖运行期强制语言，
    /// 写成常量会在首次访问时固定下来 —— 单测里「钉住英文渲染」会拿到中文那一版，
    /// 而**看起来完全正常**（同 ``SettingsSection/title`` 那条的理由）。
    var title: String {
        switch self {
        case .disks: return L10n.tr(.externalDisksTitle)
        case .settings(let section): return section.title
        }
    }

    /// 侧栏那一行的图标。
    var systemImage: String {
        switch self {
        case .disks: return "externaldrive"
        case .settings(let section): return section.systemImage
        }
    }
}

// MARK: - 打开主窗口的落点

/// 「打开主窗口」时侧栏应该停在哪一项。
///
/// ## 为什么要有这个类型，而不是在两个方法里各写一行赋值
///
/// v3 把设置合并进主窗口之后，「打开主窗口」这件事有了**两个语义不同的入口**：
/// 菜单栏面板的「打开主窗口」与「设置…」（另加主菜单的 ⌘O / ⌘,）。
/// 用户对它们的预期是对称的 —— **「打开」回应用主页，「设置」回设置首页** ——
/// 而主页与设置首页恰好是这个枚举的两个 case。
///
/// 写成两行裸赋值（`showMainWindow()` 里一句 `.disks`、`showSettings()` 里一句
/// `.settings(.general)`）看着更短，实则埋了一个**顺序耦合**：`showSettings()`
/// 必须**先**建好窗口才能赋值（建窗前 ``MainWindowContentController`` 还不存在，
/// 赋值被静默吃掉），于是「先 show 再赋值」成了一条没人守着的隐式契约 ——
/// 与「漏了 `model.selection = .settings(.general)` 会静默停在磁盘页」是同一类病。
/// 收敛成落点枚举之后，落点成为入口的**显式参数**，两条入口各自写死自己那一个 case。
enum MainWindowLanding {

    /// 「打开主窗口」：回**外置磁盘** —— 应用的主角，也是「打开主窗口」想干的第一件事。
    case disks

    /// 「设置…」：回**设置 · 通用** —— 设置区的首页。
    case settingsGeneral

    /// 落点对应的那个侧栏项。
    var navItem: MainNavItem {
        switch self {
        case .disks: return .disks
        case .settingsGeneral: return .settings(.general)
        }
    }
}

// MARK: - 导航状态

/// 主窗口的导航状态：**侧栏与详情区共享的唯一一份**。
///
/// ## 为什么需要一个独立对象
///
/// v3 的窗口用 `NSSplitViewController` 装配（侧栏浮岛 / 圆角 / 材质全归系统，
/// 见 `Design/ui/v3/HANDOFF.md` §3.1），而 split item 的两侧各自是**独立的**
/// `NSHostingController` —— 两个宿主之间没有 SwiftUI 的父子关系，
/// `@State` 天然传不过去。选中项因此必须住在一个两者都能拿到的对象上。
///
/// `@MainActor`：它被两个主 actor 的视图持有并读写，标上之后由编译器保证
/// 不会从别的线程碰它（Swift 6 严格并发下这是**编译期**的保证，不是纪律）。
@MainActor
final class MainWindowModel: ObservableObject {

    /// 当前选中的导航项。默认「外置磁盘」—— 那是应用的主角，
    /// 也是「打开主窗口想干的第一件事」。
    @Published var selection: MainNavItem = .disks

    /// 供 `List(selection:)` 用的绑定。
    ///
    /// `List(selection:)` 在 macOS 上要的是 `Binding<SelectionValue?>`，而本对象上的
    /// `selection` **是非可选的** —— 「什么都没选中」这个状态在这一列里没有意义
    /// （清单恒有六项）。用户点空白处取消选中时系统会写 `nil`，这里**忽略**它，
    /// 于是那一列永远停在最后选中的一项上，而不是走进一个空详情区。
    var listSelection: Binding<MainNavItem?> {
        Binding(
            get: { [weak self] in self?.selection },
            set: { [weak self] newValue in
                guard let newValue else { return }
                self?.selection = newValue
            })
    }
}

// MARK: - 侧栏

/// 主窗口左侧导航栏（设计稿 `_10-combined-draft.html` 的 `.sside`）。
///
/// ## ⚠️ 这里**一行外观代码都不该有**
///
/// 侧栏那圈「四边内缩 8pt 的圆角浮岛 + 玻璃材质 + 选中态胶囊」是
/// `NSSplitViewItem(sidebarWithViewController:)` 在 macOS 26 上**本来就会画**的东西。
/// 我们一旦给它补背景色、圆角或材质，那层效果就被盖掉了 —— 这是本轮改动里
/// **唯一真正的风险不是「没做」而是「做多了」** 的地方（HANDOFF §3.3、红线 R1/R2/R7）。
///
/// 具体说：
/// - ⛔ 不给它 `.background(...)`（含从稿子抄 `--bg-sunken`）；
/// - ⛔ 侧栏视图层次里**不放 `NSVisualEffectView`**（本文件因此没有它）；
/// - ✅ 选中态走 `List(selection:)` + `.listStyle(.sidebar)`，由系统按代际画
///   （26 是中性灰胶囊、14–15 是强调色实底）—— **两边都对，都不是 bug**。
///
/// ## 键盘与无障碍
///
/// ↑/↓ 在项之间移动、VoiceOver 报出选中项，**都由 `List` 承担**。
/// 这里曾经有一条手写的 `.focusable()` + `.onMoveCommand`（连同
/// `SettingsSection.moved(from:step:)` 那个纯函数）—— 那是在自绘左栏的年代
/// 补系统行为；改用系统 `List` 之后它是多余且**更差**的一份（少了 PageUp/PageDown、
/// 少了 VoiceOver 的列表语义）。一并退役。
struct MainSidebarView: View {

    @ObservedObject var model: MainWindowModel

    /// App 内强调色（设置 › 外观）。
    ///
    /// ## 侧栏选中胶囊的颜色从哪里来（2026-10-22 实证，macOS 27）
    ///
    /// 选中胶囊与行图标由 **AppKit 源列表**绘制，只认 per-app 的
    /// `AppleAccentColor` 偏好键 —— 下面这句 `.tint` **传不进去**（逐组对照实验：
    /// `.tint` 在、胶囊仍系统蓝；写入 `AppleAccentColor=1`，胶囊与图标即变橙）。
    /// 系统侧那份由 ``AppSettings/syncAppleAccentColor()`` 在启动与偏好变更时同步，
    /// 本视图**不需要也不应该**再为胶囊做任何事。
    ///
    /// 这句 `.tint` 保留只是兜底 macOS 14–15（那边胶囊跟 tint 走，见旧注释），
    /// 以及侧栏内将来可能出现的其它 SwiftUI 控件。
    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue

    /// 当前指针悬停的导航项（行级 hover 底的唯一状态）。
    ///
    /// 与 ``ToggleRowHover`` 同一条纪律：**逐行一份状态**，不能挂在侧栏外层 ——
    /// 否则悬停一行会让所有行一起亮。这里用「单个可选值 + 相等判断」表达，
    /// 因为任意时刻只可能有一行在指针下。
    @State private var hoveredItem: MainNavItem?

    private var accent: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

    var body: some View {
        List(selection: model.listSelection) {
            Section {
                row(.disks)
            }
            // 分组标题（设计稿 `.sside__group`）。`Section` 的 header 在 sidebar 样式下
            // 就是那个小标题 —— 不需要自绘；这里只加一段**额外的上方间距**，
            // 让它与「外置磁盘」断开得更明确（理由与取值见
            // ``DesignTokens/Size/sidebarGroupSpacingExtra``）。
            Section {
                ForEach(MainNavItem.settingsItems) { item in
                    row(item)
                }
            } header: {
                Text(L10n.tr(.settings))
                    .padding(.top, DesignTokens.Size.sidebarGroupSpacingExtra)
            }
        }
        .listStyle(.sidebar)
        // ## 侧栏背景交还系统（2026-10-28 用户要求「把浮岛拿掉」）
        //
        // 2026-10-23 ~ 10-28 期间这里自绘过一块「四边内缩 8 + 圆角 10」的浮岛
        // （`.scrollContentBackground(.hidden)` + `.background` + `.clipShape` + `.padding`）。
        // 用户看过实物后明确不要浮岛 ⇒ 那四行**全部删除**，`List` 恢复默认的侧栏材质：
        // 方角、贴边、整面铺满 —— 与 Finder / 系统设置的侧栏同代。
        //
        // ⚠️ 别再把它们加回来：`.scrollContentBackground(.hidden)` 会关掉系统材质，
        // 而 `.background` + `.clipShape` + `.padding(8)` 会重新切出那块内缩浮岛。
        .tint(accent.swiftUIColor)
    }

    /// 一行导航项。
    ///
    /// ## 撑高行距的机制：**只有 `listRowInsets` 管用**（2026-10-01 三次真机实验）
    ///
    /// 系统给的行高在 200×504 的侧栏里会让六项挤在顶部、下面空掉 47%
    /// （逐像素实测见 ``DesignTokens/Size/sidebarRowVerticalInset`` 的那张表）。
    /// 但「撑高 sidebar 样式的 `List` 行」**不是随便一个 API 就能做到的** ——
    /// 同一台机器上逐个试过、每次都截图量行距：
    ///
    /// | 机制 | 实测结果 |
    /// |---|---|
    /// | 行内容 `.padding(.vertical, 4)`（单独用） | ❌ **无效**，六个行距仍是 32pt |
    /// | `List.environment(\.defaultMinListRowHeight, 40)`（单独用） | ❌ **无效**，同上 |
    /// | **本行的 `.listRowInsets`** | ✅ 生效：行高 32 → **39.5pt**（本值 12），点击区与选中胶囊**跟着一起长** |
    ///
    /// ⇒ 前两条别再单独试。**根因**（第二、三次实验交叉验证出来的模型）：
    /// 没有 `listRowInsets` 时，sidebar 行高是 AppKit 按样式压死的 **32pt 定值**
    /// —— 内容 padding 撑不动它，环境键也改不动它；**一旦给了 `listRowInsets`，
    /// 行高就切换成「内容自然高 + 上下内距」的自适应算法**，这时内容 padding
    /// 才重新有意义（第三次实验：`.padding(4)` + `insets(10)` ⇒ 43.5，
    /// 第四次实验：只留 `insets(10)` ⇒ 35.5，差值 8 = 2 × 4，模型吻合）。
    /// ⇒ **行高要调就调 `sidebarRowVerticalInset` 这一个数**，别去叠内容 padding。
    /// ⚠️ 行高 39.5 是「`15.5 + 2 × 12`」算出来的（14 那档实测是 43.5）；
    /// 用户 2026-10-27 反馈「hover 高度低一些」，所以从 14 收到 12（理由见令牌注释）。
    ///
    /// ## ⚠️ `leading` / `trailing` 必须显式写 **0**，不是可省的
    ///
    /// `listRowInsets` 是**在系统内距之上再叠**的，不是替换：实测 `leading: 8`
    /// 会把行内容整体右移 8pt（图标最左 30 → 38pt），而选中胶囊站在原地不动 ——
    /// 于是图标与「设置」分组标题的左边线错开 8pt，看起来像缩进错位。
    /// 写 0 即还原系统原值（实测回到 30pt）。
    ///
    /// 选中态胶囊、hover、圆角、焦点环**仍然全部由系统画** —— 这里只把行撑高。
    private func row(_ item: MainNavItem) -> some View {
        let isSelected = model.selection == item
        // ## 为什么图标要**显式上色**，而不是交给 `Label`（2026-10-27 用户反馈）
        //
        // 用户原话：「强调色 bug，切换颜色后，设置窗口左侧菜单 icon 是粉色」。
        //
        // 根因：sidebar 样式的 `List` 里，**符号图标的颜色由 AppKit 源列表自己上**
        // ——它认的是 **per-app 的 `AppleAccentColor`**（系统偏好里那个「强调色」，
        // macOS 允许选粉色），不认 SwiftUI 的 `.tint`（本视图 body 末尾那句 `.tint` 的
        // 说明已实证）。于是：
        // - 我们的选中胶囊用 `accent.swiftUIColor` 自绘，跟随应用内选择；
        // - 图标却跟着**系统强调色**走 ⇒ 用户把系统强调色设成粉、应用内选蓝，
        //   就会看到「蓝胶囊 + 粉图标」的裂开状态（即用户报的「icon 是粉色」）。
        //
        // 修法：把 `Label` 拆成 `Image` + `Text`，**图标显式用 `accent.swiftUIColor`**。
        // `accent` 读的是 `@AppStorage(AppSettings.Key.accentColor)` 投影 ⇒ 用户点色板
        // 写入 `AppSettings.Key.accentColor` 的同一帧，本视图就会重算（不是靠重启生效）。
        // 文字仍用中性前景色（图标是强调点，正文不需要跟着变色，与设计稿一致）。
        //
        // ⚠️ 别改回 `Label(...)` + 整行 `.foregroundStyle`：那样虽然也「跟随」，
        // 但会把**正文**一起染色（设计稿里正文是中性色），而且一旦哪天有人把整行
        // 前景色删掉，图标又会退回系统强调色 —— 这个 bug 会静默复发。
        return HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: item.systemImage)
                .foregroundStyle(isSelected ? Color.white : accent.swiftUIColor)
            Text(item.title)
                .foregroundStyle(isSelected ? Color.white : DesignTokens.Palette.foreground)
            Spacer(minLength: 0)
        }
            .listRowInsets(
                EdgeInsets(
                    top: DesignTokens.Size.sidebarRowVerticalInset,
                    leading: 0,
                    bottom: DesignTokens.Size.sidebarRowVerticalInset,
                    trailing: 0)
            )
            // ## 行底自绘（2026-10-22 用户反馈 + 本机 macOS 27 实测）
            //
            // 系统 sidebar 样式在 macOS 27 上画出的选中胶囊是**中性灰**（实测 #3A3A3E 一带），
            // 与 `AppleAccentColor` 写什么都无关；同时行上没有 hover 底。
            // 用户的要求是「hover 要看得出来、选中色必须等于强调色」——
            // 这两条系统都给不了，只能自己画。
            //
            // 保留 `List(selection:)` 的意义：选中值、方向键导航、VoiceOver 的列表语义
            // 仍由系统承担（我们只接管**这一层皮**）。
            .listRowBackground(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(rowBackground(for: item, isSelected: isSelected))
                    // ## 上下各留 2pt：让相邻两行的色块之间出现 4pt 空隙
                    //
                    // 用户 2026-10-28 反馈：「hover 和选中两个颜色之间没有间隔」。
                    // 根因：`listRowBackground` 铺满的是**整行矩形**（含上下各
                    // ``DesignTokens/Size/sidebarRowVerticalInset`` 的内距），而相邻两行的
                    // 矩形首尾相接 ⇒ 灰 hover 块与蓝选中块直接贴死（实测像素 y=393/394
                    // 零间隙，见用户截图 `通用` 与 `外观` 两行）。
                    //
                    // ⇒ 在**背景**上加内缩，不动 `listRowInsets`：
                    // 后者会连行高、点击区、文字位置一起改（见本函数抬头的三次实验表），
                    // 而这里只想把「色块」缩小一点。2pt 取 `Spacing.xs` 的一半，
                    // 相邻两行各让一半 ⇒ 视觉上是 4pt 的缝。
                    .padding(.vertical, DesignTokens.Spacing.xs / 2)
                    // 左右各内缩 8pt：浮岛拿掉之后 `List` 是整面铺满的，色块会直接贴到
                    // 窗口左缘与中间那条分隔线上（圆角被边缘切出「半块」的观感）。
                    // 8pt 与设计稿 `.sside { padding: 52px 10px 12px }` 的横向内边距同量级，
                    // 也是拿掉浮岛之前 `List` 那一层 `.padding` 的值。
                    .padding(.horizontal, DesignTokens.Spacing.sm)
            )
            // 选中 = 强调色实底 + 白字；未选中 = 图标强调色 + 中性文字。
            // ⚠️ 前景色在上面**逐元素**给了（见那段长注释），这里不要再整行上色 ——
            // 整行 `.foregroundStyle` 只是环境默认值，会让「谁在跟随强调色」变得看不清，
            // 也正是上一版图标退回系统强调色（粉色）的成因之一。
            .onHover { inside in
                if inside {
                    hoveredItem = item
                } else if hoveredItem == item {
                    // ⚠️ 必须比对再清：悬停移出旧行时，指针可能已经进了新行并写好新值，
                    // 无条件置 nil 会把新行的 hover 一起抹掉（快速划过时的闪烁）。
                    hoveredItem = nil
                }
            }
            .tag(item)
    }

    /// 行底色：选中 > 悬停 > 透明。
    ///
    /// 悬停底用 ``DesignTokens/Palette/subtle``（设计稿 `.sside__item:hover` 的 `--bg-subtle`），
    /// 与设置页开关行的行级 hover 同源。
    private func rowBackground(for item: MainNavItem, isSelected: Bool) -> Color {
        if isSelected { return accent.swiftUIColor }
        if hoveredItem == item { return DesignTokens.Palette.subtle }
        return .clear
    }
}

// MARK: - 详情区

/// 主窗口右侧详情区：顶部一条 52pt 内容带 + 下方随选中项切换的内容。
///
/// ## 头部为什么在**内容区**、而不是工具栏
///
/// 设计稿把标题放在内容区顶部（`.sdetail__head`），与窗口左上角的红绿灯、
/// 右上角的刷新按钮落在**同一条 52pt 水平带**上，三者垂直中心都是 26pt。
/// 三个 26pt 是实测值，天然共线 —— 所以这里**不写任何 padding 去凑**，
/// 头部在 52pt 里居中、工具栏项由系统居中，结果自动一致（HANDOFF §3.2）。
///
/// ⚠️ 这条带的 52pt 不是我们撑出来的：它同时是工具栏占的那条安全带
/// （`DesignTokens.Size.titleBarBandHeight`）。删掉工具栏会让红绿灯掉到 16pt、
/// 侧栏浮岛顶掉到 32pt —— 见 HANDOFF §3.1.1 的四项代价实测。
struct MainDetailView: View {

    @ObservedObject var model: MainWindowModel

    /// 磁盘列表来源 —— 详情区头部要显示「N 块」，所以这里也要观察它。
    @ObservedObject var store: DiskListStore

    let occupancyStore: OccupancyStore

    /// 见 ``ContentView/init(skipsInitialRefresh:store:occupancyStore:)``。
    let skipsInitialRefresh: Bool

    /// ⚠️ **仅供真机自检 / 单测**：透传给 ``SettingsDetailPage``。
    ///
    /// 只留这一个 —— 它对应 `--preview-settings-no-fda` / `--preview-settings-has-fda`
    /// 两个旗标（本机能给到的只有一半的 TCC 状态，另一半必须在自检里强制出来）。
    /// ``SettingsSectionPane`` 另外那两个注入口（更新行状态 / 自动更新行状态）
    /// 由**离屏出图**直接用，不必经过窗口 —— 从这条路径传进来的话就是零调用方的参数。
    let takeOverAvailabilityOverride: AppSettings.TakeOverAvailability?

    /// 设置页里**唯一**的弹窗状态 —— 挂在详情区这一层（而不是某个分类页上）：
    /// 切换分类会替换掉下面的视图，挂在下层的话状态会被一起丢掉，
    /// 而「拨完开关必须看到的那句话」就出自下层的上抛。
    @State private var prompt: SettingsPrompt?

    var body: some View {
        VStack(spacing: 0) {
            MainDetailHead(title: model.selection.title, subtitle: subtitle)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(item: $prompt) { prompt in
            guard let openSettings = prompt.openSettings else {
                return Alert(
                    title: Text(prompt.title),
                    message: Text(prompt.message),
                    dismissButton: .default(Text(prompt.dismissTitle)))
            }
            return Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text(L10n.tr(.openSystemSettings)), action: openSettings),
                secondaryButton: .cancel(Text(prompt.dismissTitle)))
        }
    }

    /// 头部副标题：只有磁盘页有（设计稿 `.sdetail__sub` 的「3 块」）。
    /// 没有磁盘时不显示 —— 「0 块」这种话在空状态页上已经是重复信息。
    private var subtitle: String? {
        guard model.selection == .disks, !store.disks.isEmpty else { return nil }
        return String(format: L10n.tr(.diskCountFormat), store.disks.count)
    }

    @ViewBuilder
    private var page: some View {
        switch model.selection {
        case .disks:
            ContentView(
                skipsInitialRefresh: skipsInitialRefresh,
                store: store,
                occupancyStore: occupancyStore)
        case .settings(let section):
            SettingsDetailPage(
                section: section,
                takeOverAvailabilityOverride: takeOverAvailabilityOverride,
                onLaunchAtLoginError: { error in prompt = SettingsPrompt.launchAtLogin(error) },
                onTakeOverEnabled: { prompt = SettingsPrompt.accessibilityOnboarding() },
                onTakeOverNeedsFDA: { prompt = SettingsPrompt.takeOverNeedsFDA() })
        }
    }
}

/// 详情区顶部的内容带（设计稿 `.sdetail__head`，高 52、标题与副标题居中垂直 26pt）。
///
/// **单独抽出来是为了可测**：它的高度是「标题与红绿灯共线」这条不变量的载体，
/// 而 `TitleBarBaselineTests` 要能脱离窗口、单独渲染它量墨迹位置。
///
/// ⚠️ 这里**没有**左侧 52pt 的让位块 —— 那是 v2 主窗口为了让开红绿灯留的。
/// v3 的红绿灯浮在**侧栏浮岛**上，标题在内容区顶部，两者本来就不在同一个 x 区间。
struct MainDetailHead: View {

    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: SettingsMetrics.headerSpacing) {
            Text(title)
                .font(.system(size: DesignTokens.FontSize.title, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: DesignTokens.FontSize.caption))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsMetrics.headerPaddingLeading)
        .padding(.trailing, SettingsMetrics.headerPaddingTrailing)
        // **内容带 + 下方留白**，不是直接 `.frame(height: 52)`：这样「头部总高」
        // 只有一个来源（``DesignTokens/Size/titleBarBandHeight``），
        // 内容带吃满 52 ⇒ 标题居中到距顶 26pt，与红绿灯、刷新按钮共线。
        .frame(height: DesignTokens.Size.titleBarBandHeight)
        .padding(.bottom, DesignTokens.Size.titleBarBandBottomPadding)
        // 设计稿 `.sdetail__head` 底边那条 0.5px 线。用 overlay 而不是加一条
        // `Hairline` 进 VStack：后者会占 1pt 高度，把下面内容整体推低。
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityAddTraits(.isHeader)
    }
}

/// 设置详情页：滚动容器 + 一个分类的内容 + 设置专属的那两种提示。
///
/// 它接下了原来 `SettingsView`（独立窗口）里**属于宿主**的那部分职责
/// ——「拨完开关要跟用户说一句话」的弹窗状态 —— 但不再有左栏、头部与窗口尺寸：
/// 那三样分别归侧栏、``MainDetailHead`` 与窗口。
struct SettingsDetailPage: View {

    let section: SettingsSection

    var updateStateOverride: UpdateController.CheckRowState?
    var autoUpdateRowsOverride: AutoUpdateRowsState?
    var takeOverAvailabilityOverride: AppSettings.TakeOverAvailability?
    var launchAtLoginStateOverride: LaunchAtLoginState?

    /// 登录项失败 / 辅助功能引导 / FDA 引导的上抛落点（弹窗状态在 ``MainDetailView`` 上）。
    var onLaunchAtLoginError: (LaunchAtLoginError) -> Void = { _ in }
    var onTakeOverEnabled: () -> Void = {}
    var onTakeOverNeedsFDA: () -> Void = {}

    var body: some View {
        ScrollView {
            SettingsSectionPane(
                section: section,
                updateStateOverride: updateStateOverride,
                autoUpdateRowsOverride: autoUpdateRowsOverride,
                takeOverAvailabilityOverride: takeOverAvailabilityOverride,
                launchAtLoginStateOverride: launchAtLoginStateOverride,
                onLaunchAtLoginError: onLaunchAtLoginError,
                onTakeOverEnabled: onTakeOverEnabled,
                onTakeOverNeedsFDA: onTakeOverNeedsFDA
            )
        }
        .scrollContentBackground(.hidden)
    }
}
