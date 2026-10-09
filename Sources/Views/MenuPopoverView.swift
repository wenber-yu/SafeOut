import AppKit
import SwiftUI

/// 状态栏菜单的 SwiftUI 视图（设计稿 `02-menu-bar.html` / `.popstack`）。
///
/// **规格**：360pt 宽；头部 = 应用图标 + 应用名 + 磁盘数量徽标；
/// 磁盘行用 ``MenuBarDiskRow``（三行文本 + 26 × 26 图标按钮）；
/// 分隔线 + 动作区（打开主窗口 / 刷新 / 设置 / 退出）。
///
/// **职责划分**：菜单栏 = 动作（一行一行，不放容量条），主窗口 = 诊断
/// （容量条 + 证据区 + 横幅）。同一个信息在两处的表达密度不同，是刻意的。
///
/// 这里曾有一行「外置磁盘」分组标题，已删除：面板里此时只有外置磁盘一种内容，
/// 既没有其它分组可对比、也不提供额外信息，只是把首行磁盘推低了约 20pt。
/// 现在头部改为显示**应用自身**名称 + 磁盘数量，后者是有信息量的。
struct MenuPopoverView: View {

    /// 磁盘列表来源。**默认全局单例，但可注入**。
    ///
    /// **注入口是给契约测试用的**：面板总高 = 头部 50 + （行数 × 69 + 8）+ 分隔 17
    /// + 动作区 136，只有能造出「0 块 / 1 块 / 2 块盘」才量得出来。
    /// 直读 `.shared` 时测试只能拿到测试机上真实插着的盘，量到的数字随机器变。
    @ObservedObject private var store: DiskListStore

    /// 每个卷的占用检测结果 —— **与主窗口读的是同一个字典、同一帧的值**。
    ///
    /// 这里曾经是一个本视图私有的 `@State var occupancy`，只由 `.task`（每次点开跑一次）
    /// 和 `.onChange(of: store.disks)` 填充。没有定时器、没有 `didBecomeActive` 刷新，
    /// 而 `.onChange` 又只在**值不相等**时触发 —— `DiskListStore.refresh()` 赋的新数组
    /// 内容相同时它静默不动。于是面板上的「刷新磁盘列表」从来不刷新占用结论，
    /// 面板与主窗口也会长期显示两个不同的判定（2026-09-15 用户报告）。
    /// ⚠️ **故意不是 `@ObservedObject`**（2026-09-24）：本视图**不读**它的任何属性
    /// （读的地方全在 ``MenuDiskList`` 里），而 `@ObservedObject` 订阅的是
    /// `objectWillChange` **整条** —— 挂上它，占用每 15s 跑完 `lsof` 就会把整个面板
    /// （头部计数、分隔线、四行动作）一起重建。⇒ **订阅随读取走**，理由同 ``DiskListRegion``。
    private let occupancyStore: OccupancyStore

    /// 「待处理占用」提醒（有人刚在访达点推出、但盘被占用）—— 面板顶部的提醒卡片来源。
    @ObservedObject private var attention: EjectAttentionCenter

    let accent: AccentColor
    let onOpenMainWindow: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    /// 每个卷的占用检测结果（菜单栏用，与主窗口共用同一份语义）。
    /// 旧的私有 `@State` 已删除，见上方 `occupancyStore` 的说明。

    /// 由 AppDelegate 注入的「在菜单栏上点推出」的回调。
    /// 这里只发动作，真正删除前仍会通过 ``EjectUI`` 弹窗二次确认。
    let onEject: (DiskInfo) -> Void

    /// 两个 store 都可注入（默认全局单例），其余参数与原来一致。
    ///
    /// **为什么加这个 init**：`store` 从「直读 `.shared` 的 `let`」变成注入属性后，
    /// 需要显式把它们接进 `@ObservedObject` 的包装器；顺带把默认值收在这里，
    /// 生产调用点（`SafeOutApp`）一个字都不用改。
    init(
        store: DiskListStore = .shared,
        occupancyStore: OccupancyStore = .shared,
        attention: EjectAttentionCenter = .shared,
        accent: AccentColor,
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onEject: @escaping (DiskInfo) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.occupancyStore = occupancyStore
        _attention = ObservedObject(wrappedValue: attention)
        self.accent = accent
        self.onOpenMainWindow = onOpenMainWindow
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onEject = onEject
    }

    /// 动作区的四行 —— **面板上「画了什么」的唯一出处**。
    ///
    /// 抽成数据而不是散在 `actions` 里，是为了让契约测试能直接读到它：
    /// `MainMenuTests` 拿这份清单去对照主菜单的 `keyEquivalent`（键位不能是假的），
    /// 以及对照主菜单「退出」项的标题（同一个动作不能有两个名字）。
    /// 曾经测试里手抄一份键位、视图里再写一份 —— 两边同时改错就永远发现不了。
    static let actionRows: [MenuPopoverAction] = [
        MenuPopoverAction(
            kind: .openMainWindow, systemImage: "macwindow",
            titleKey: .openMainWindow, shortcut: "⌘O"),
        MenuPopoverAction(
            kind: .refreshDisks, systemImage: "arrow.clockwise",
            titleKey: .refreshDisks, shortcut: "⌘R"),
        MenuPopoverAction(
            kind: .openSettings, systemImage: "gear",
            titleKey: .openSettings, shortcut: "⌘,"),
        MenuPopoverAction(
            // 设计稿 `.actionrow--danger` 用的是 `data-i="power"`（标准电源符），
            // 不是「门里一个箭头」的登出符 —— 后者在 macOS 上读作「登出当前账户」。
            kind: .quit, systemImage: "power",
            // 文案与主菜单的「退出磁盘推出助手」（⌘Q）**逐字一致**：
            // 同一个动作在两个地方写两种名字，用户会以为是两件事。
            titleKey: .menuQuitApp, shortcut: "⌘Q", isDestructive: true),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if !attention.pending.isEmpty {
                attentionBanner
            }
            if store.disks.isEmpty {
                emptyState
            } else {
                diskList
            }
            separator
            actions
        }
        .frame(width: DesignTokens.Size.menuPopoverWidth)
        // **面板自己必须画背景**：`NSPopover` 的窗口自带材质是 `.titlebar` 一档，
        // 与主窗口的 `.underWindowBackground` 不是同一块玻璃（见
        // `NSPopover.normalizeBackdropMaterial()`）。这里补上与主窗口完全相同的
        // ``GlassSurface``（材质 + `--bg-glass` + 0.5px 外描边），
        // 两块玻璃才真正是同一套规则画出来的。
        //
        // **必须用 `.background(...)`，不能放进 `ZStack`**：`GlassSurface` 里是
        // `NSViewRepresentable`，被 `sizeThatFits(in: .greatestFiniteMagnitude)` 量到时
        // 会把 1.79e308 送进 AppKit 约束，实测直接抛
        // 「NSLayoutConstraint ... exceeds internal limits」并把测试进程打死（signal 5）。
        // `.background` 传下去的是内容已经算好的有限尺寸。
        .background(GlassSurface(cornerRadius: DesignTokens.Radius.lg))
    }

    // MARK: - 待处理占用提醒

    /// 面板顶部的「待处理占用」提醒卡片：有人刚在访达点推出、但盘被占用。
    ///
    /// **为什么是卡片而不是磁盘行里的角标**：提醒是「事件」不是「现状」——
    /// 它要醒目地告诉用户「你刚才那次推出没成，因为 X 在占用」，而不是默默
    /// 混进磁盘列表里。放在头部正下方、磁盘列表上方，是面板里最显眼的位置。
    ///
    /// **「关闭并推出」复用 `onEject`**：它走 ``EjectUI/eject(disk:cachedOccupancy:)``
    /// 的完整链路（弹确认窗 → 清场 → 推出），不在这里另写一套推出逻辑 ——
    /// 单一事实来源，避免两条推出路径漂移。
    private var attentionBanner: some View {
        VStack(spacing: 6) {
            ForEach(Array(attention.pending.values)) { item in
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignTokens.FontSize.bodyStrong))
                        .foregroundStyle(DesignTokens.Palette.error)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: L10n.tr(.ejectAttentionTitle), item.disk.displayName))
                            .font(.system(size: DesignTokens.FontSize.bodyStrong, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.foreground)
                        Text(item.processSummary)
                            .font(.system(size: DesignTokens.FontSize.footnote))
                            .foregroundStyle(DesignTokens.Palette.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)

                    Button {
                        onEject(item.disk)
                    } label: {
                        Text(L10n.tr(.closeAndEject))
                            .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous).fill(DesignTokens.Palette.error)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(format: L10n.tr(.closeAndEjectDiskFormat), item.disk.displayName))
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(DesignTokens.Palette.errorSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .strokeBorder(DesignTokens.Palette.errorLine, lineWidth: 0.5)
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "eject.fill")
                .font(.system(size: DesignTokens.Size.popoverAppIconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(accent.swiftUIColor)
                )
                // 设计稿 `.pop__appicon { box-shadow: var(--e1) }` ——
                // `0 1px 2px rgba(0,0,0,.06), 0 0 0 0.5px rgba(0,0,0,.05)`。
                // 第二部分是 0.5px 的极淡黑环，它让实心色块在浅色玻璃上有一条清晰的边；
                // 只投外阴影时，强调色块的四边会「糊」进背景里。
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
                )
                .shadow(
                    color: DesignTokens.Elevation.e1.color,
                    radius: DesignTokens.Elevation.e1.radius,
                    y: DesignTokens.Elevation.e1.y
                )
                .accessibilityHidden(true)

            Text(L10n.tr(.appName))
                .font(.system(size: DesignTokens.FontSize.bodyStrong, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)

            if !store.disks.isEmpty {
                // 设计稿 `.pop__count` 里是**裸数字**（`02-menu-bar.html` 写 `2`、
                // `07-dark.html` 也写 `2`），不带「块 / 個」这种量词 —— 它是个计数徽标，
                // 量词会把它撑成三倍宽，把应用名和右侧刷新按钮之间的留白吃掉。
                //
                // 主窗口标题栏的「外置磁盘 · N 块」是**另一回事**：那里没有量词就不成句。
                // 两个位置共用 `diskCountFormat` 曾经让面板徽标渲染成「1 块」，
                // 与设计稿的 `2` 对不上。所以这里只把裸数字画出来，
                // 量词留给无障碍标签 —— VoiceOver 读「1 块」比读「1」清楚。
                //
                // **颜色是 `--text-3`（设计稿 `.pop__count { color: var(--text-3) }`）**，
                // 不是 `--text-2`。这里曾用 `mutedForeground`（0.62），比设计稿重一档；
                // 徽标是「有几块盘」的辅助计数，压到装饰级才不会跟应用名抢注意力。
                Text("\(store.disks.count)")
                    .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Palette.textDecorative)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous).fill(DesignTokens.Palette.subtle)
                    )
                    .accessibilityLabel(
                        String(format: L10n.tr(.diskCountFormat), store.disks.count))
            }

            Spacer(minLength: 0)

            // 设计稿头部右侧的 `.iconbtn`（28 × 28）。
            //
            // **为什么头部要有一个刷新按钮**：面板是「随手推一下」的地方，
            // 用户插上盘后往往不会去主窗口，就地刷新是最短路径。
            // 它也让头部的高度由 22 变成 28 —— 设计稿头部的 50pt 就是这么来的
            // （12 上内边距 + 28 内容 + 10 下内边距）。
            PopoverIconButton(
                systemName: "arrow.clockwise",
                label: L10n.tr(.refreshDisks),
                action: onRefresh
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.md)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// 空状态（设计稿 `02-menu-bar.html` 的第二个变体）。
    ///
    /// **规格全部来自设计稿的覆盖值**，而且是**两层**内边距：
    /// - 外层 `.pop__body` 的覆盖值 `padding: 8px 12px 16px`（普通态是 `0 8px 8px`，
    ///   空状态在设计稿里被显式改宽了下留白）；
    /// - 内层内容列 `padding: 14px 8px 6px`、列间距 6。
    ///
    /// 曾经只写了内层、漏了外层，空状态整体矮 24pt（上 8 + 下 16），
    /// 面板在「没插盘」时比设计稿短一截 —— 而那一屏恰恰是新用户看到的第一眼。
    ///
    /// 图标容器 **56 × 56 圆角 14**（不是主窗口空状态那个 76 圆角 18）、图标 36；
    /// 标题 13 / 600；说明 11、行高 1.55、最大宽 250。
    ///
    /// **为什么说明要限宽 250**：面板宽 360，不限宽的话这句话会拉成一整行，
    /// 与设计稿的断法不一致；限宽后断行位置稳定，中英日各语言都不会忽长忽短。
    private var emptyState: some View {
        VStack(spacing: 6) {
            IconBadge(systemName: "externaldrive", style: .menuEmptyArt, accent: accent)
                .padding(.bottom, 2)
            Text(L10n.tr(.noRemovableDisks))
                .font(.system(size: DesignTokens.FontSize.bodyStrong, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.bodyStrong)
            Text(L10n.tr(.insertDiskHint))
                .font(.system(size: DesignTokens.FontSize.footnote))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .multilineTextAlignment(.center)
                .designLineHeight(
                    DesignTokens.LineHeight.loose, fontSize: DesignTokens.FontSize.footnote
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity)
        // 内层内容列
        .padding(.top, 14)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, 6)
        // 外层 `.pop__body`（空状态覆盖值）
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 磁盘列表

    /// 磁盘行之间**没有间距**（设计稿 `.pop__body` 里的 `.mrow` 是相邻的块级元素）。
    ///
    /// 曾经用 `Spacing.xs`（4pt）作行距，两块盘就多出 4pt —— 面板总高因此对不上设计稿。
    private var diskList: some View {
        MenuDiskList(
            occupancyStore: occupancyStore,
            disks: store.disks,
            accent: accent,
            onEject: { disk in onEject(disk) }
        )
    }

    // MARK: - 分隔线

    private var separator: some View {
        Hairline()
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
    }

    // MARK: - 动作区

    /// 动作区（设计稿 `.pop__body` 里的四个 `.actionrow`）。
    ///
    /// **行与行之间没有间距**（设计稿实测四行是 507 / 539 / 571 / 603，首尾相接）。
    /// 曾经用 2pt 行距，四行多出 6pt。
    ///
    /// **「退出」之前没有额外分隔线**：设计稿里动作区与磁盘区之间**只有一条** `.pop__sep`，
    /// 动作区内部是干净的四个相邻行。这里原先插了一条 `Hairline`，
    /// 结果面板比设计稿多出「一条线 + 4pt 留白」。
    ///
    /// **每个动作都标出快捷键**（设计稿 `.actionrow__key`，等宽 11pt 右对齐）：
    /// 面板是键盘用户的主路径，把键位写在行尾就不必去菜单栏里翻。
    /// 这些键位必须与主菜单里真实的 `keyEquivalent` 一致 —— 已由
    /// `MainMenuTests` 的「面板标注的快捷键与主菜单实际绑定一致」钉住。
    private var actions: some View {
        VStack(spacing: 0) {
            ForEach(Self.actionRows.indices, id: \.self) { index in
                let row = Self.actionRows[index]
                MenuActionRow(
                    systemName: row.systemImage,
                    label: L10n.tr(row.titleKey),
                    shortcut: row.shortcut,
                    action: handler(for: row.kind),
                    isDestructive: row.isDestructive
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    /// 把动作身份映射到真实回调。
    ///
    /// **穷举 `switch` 是刻意的**：`MenuPopoverAction.Kind` 加了新 case 而这里没跟上时
    /// **编译不过**。若用 `default: return {}` 兜底，新增一行会安静地渲染成一个点不动的按钮
    /// —— 编译通过、测试通过、只有用户点下去没反应。
    private func handler(for kind: MenuPopoverAction.Kind) -> () -> Void {
        switch kind {
        case .openMainWindow: return onOpenMainWindow
        case .refreshDisks: return onRefresh
        case .openSettings: return onOpenSettings
        case .quit: return onQuit
        }
    }

    // MARK: - 数据
    //
    // 占用取数已整体移到 ``OccupancyStore``：面板不再自己测、也不再有「什么时候测」的问题。
    // 这里保留一句说明，是因为「本文件里找不到 refreshOccupancy」很容易被误读成漏了刷新。
}

// MARK: - 面板动作行的规格（设计稿 `.actionrow`）

/// 面板动作行的一项：图标 + 文案键 + 行尾键位。
///
/// **`kind` 与 `titleKey` 分开是刻意的**：`kind` 回答「点下去触发哪个回调」，
/// `titleKey` 回答「显示什么字」。两者绑在一个枚举上时，「换个说法」会被迫改动作接线，
/// 而「换个动作」又容易忘改文案 —— 分开后各自独立，且 `handler(for:)` 的穷举 `switch`
/// 保证新增一项必然要在接线处处理。
struct MenuPopoverAction: Equatable {
    /// 动作身份。**与文案无关**，只用于映射回调。
    enum Kind: String, CaseIterable {
        case openMainWindow
        case refreshDisks
        case openSettings
        case quit
    }

    let kind: Kind
    /// SF Symbol 名。设计稿里每个 `.actionrow` 前面都有一个 15pt 图标。
    let systemImage: String
    /// 文案键。**不存字符串**：存键才能在语言切换时跟着变，也才能被本地化测试覆盖。
    let titleKey: L10n.Key
    /// 行尾键位提示（设计稿 `.actionrow__key`），如 `⌘O`。
    let shortcut: String
    /// 破坏性动作（设计稿 `.actionrow--danger`）：**只影响 hover 底色**（`--danger-soft`），
    /// 常态的文字与图标一律中性色。
    ///
    /// ## 这里曾经错成「整行染红」（2026-09-16 走查改回）
    ///
    /// 早先的实现拿这个标记把文案与图标都染成 `Palette.error`，注释还写着
    /// 「设计稿 `.actionrow--danger` 文案与图标都染成红色」。**设计稿从来没这么画过**，
    /// 四条独立证据：
    ///
    /// 1. **实测**设计稿渲染（无头 Chrome + `getComputedStyle`，浅色 `02-menu-bar.html`
    ///    与深色 `07-dark.html` 各一遍）：退出行与其余三行**逐项相同** ——
    ///    文字 `rgb(29,29,31)`、图标 `rgba(60,60,67,0.62)`、底色透明。
    ///    `ds.css` 里 `.actionrow--danger` **只有 `:hover` 一条**，没有常态规则。
    /// 2. **设计稿 §2.1 硬规则**：danger 那一行的「唯一用途」列写的是
    ///    「**仅**「关闭并推出」与失败弹窗」，退出行不在其中。
    /// 3. 设计稿唯一的那份 md（`DESIGN-SPEC.md`）里**从未出现** `.actionrow--danger`
    ///    ——「退出项染红」没有任何书面依据。
    /// 4. 本仓库 ``DesignTokens/Palette/error`` 自己的文档就写着「**唯一用途**是
    ///    「关闭并推出」与失败弹窗」，而 ``DesignTokens/Palette`` 的类注释还引用了那条硬规则。
    ///
    /// 而且**退出应用不是破坏性动作**（不丢数据），macOS 自己也从不给「退出」染红；
    /// 同一个动作在主菜单里是中性色、在面板里是红的，用户会以为是两件事
    /// —— 与「同一个动作不能有两个名字」是同一条理由。
    ///
    /// ⚠️ 顺带一个硬伤：`Palette.error`（`#FF3B30`）在浅色面板上对白底只有 **3.55:1**，
    /// **低于 WCAG AA 的 4.5:1**。设计稿专门为「红字」准备了 `--danger-text`
    /// （`#C1190F`，6.15:1）正是因为这个 —— 所以即便真要染红，也不该用 `error` 这个令牌。
    ///
    /// 保留的只有设计稿真有的那一条：hover 底色换成 `--danger-soft`（`ds.css:643`）。
    /// 断言见 `MenuPopoverLayoutTests.退出行不染红()`。
    var isDestructive: Bool = false
}

// MARK: - 菜单栏动作行（设计稿 `.actionrow`）
//
// **用 SwiftUI Button + .buttonStyle(.plain)**：相比 `onTapGesture`，SwiftUI Button
// 第一次点击响应更可靠（`onTapGesture` 在 SwiftUI 首次渲染后有约 1 个 runloop tick
// 的注册延迟，会让「第一次点击没反应」——这是用户报告的核心症状）。
//
// **去焦点环**：`.buttonStyle(.plain)` + `.focusable(false)` +
// `.disableFocusRing()`。Hover 高亮仍由 `@State hovering` + `.onHover` 手动驱动。

struct MenuActionRow: View {
    let systemName: String
    let label: String
    /// 行尾的快捷键提示（设计稿 `.actionrow__key`），如 `⌘O`。
    ///
    /// **必须与主菜单里真实的 `keyEquivalent` 一致**：只画不接线的键位等于骗用户
    /// （按下去没反应）。对应关系由 `MainMenuTests` 断言。
    let shortcut: String
    let action: () -> Void
    /// 这一行是否带「危险」气质。**只影响 hover 底色**（`--danger-soft`），
    /// 常态的文字与图标一律中性 —— 依据见 ``MenuPopoverAction/isDestructive``。
    var isDestructive: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // 设计稿 `.actionrow svg { width: 15px; height: 15px }` —— 固定 15pt 列宽，
                // 不随 SF Symbol 的包围盒伸缩，否则四行的文字起点会各不相同。
                // ⚠️ **不要在这里按 `isDestructive` 染红**：设计稿实测四行同色，
                // 红色只留给「关闭并推出」与失败弹窗。详见 ``MenuPopoverAction/isDestructive``。
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: DesignTokens.FontSize.body))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                    // **行高钉成设计稿的 32，而不是按 1.45 算行盒。**
                    //
                    // 设计稿 `.actionrow` 实测 32.0000，但它的行盒是 18 不是 18.85：
                    // `.actionrow` 是 `<button>`，浏览器 UA 样式表的 `line-height: normal`
                    // 覆盖了从 `.win` 继承的 1.45（实测 `computed.lineHeight = normal`）。
                    // 按 1.45 排版会得到 7 + 18.85 + 7 = 32.85，四行累计多 3.4pt。
                    //
                    // 复刻「18 这个浏览器怪癖」没有意义 —— 设计真正表达的是
                    // 「一个 32pt 高、上下各 7pt 内边距的动作行」。直接钉住 32
                    // （见 `MenuActionRow` 外层的 `.frame(height:)`）。
                    //
                    // `.lineLimit(1)` 是配套的：高度固定后长文案不能再折行（会顶出边框），
                    // 改成省略号截断 —— 菜单行本来也不该折行。
                    .lineLimit(1)
                Spacer(minLength: 0)
                // 键位用等宽字体：`⌘` 后面的字符宽窄不一（O / R / , / Q），
                // 非等宽时四个键位块的右边缘参差不齐。
                Text(shortcut)
                    .font(.system(size: DesignTokens.FontSize.footnote, design: .monospaced))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 7)
            // 设计稿实测 32.0000：`7 + 行盒 + 7`，其中行盒是浏览器对 `<button>` 的
            // `line-height: normal`（18），不是继承来的 18.85。见 `Text` 上方的说明。
            // 钉住总高而不是去凑那个 18：不同语言的字体度量会让行盒上下浮动，
            // 而设计表达的是「行高 32」这个固定值。
            .frame(height: DesignTokens.Size.menuActionRowHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(background)
            )
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
        // 键位提示要进 a11y 标签：看不见行尾小字的用户同样需要知道有这个快捷键。
        .accessibilityLabel("\(label)，\(shortcut)")
        .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        guard hovering else { return .clear }
        return isDestructive ? DesignTokens.Palette.errorSoft : DesignTokens.Palette.subtle
    }
}

// MARK: - 面板头部图标按钮（设计稿 `.iconbtn`）

/// 面板头部的 28 × 28 图标按钮。
///
/// 与主窗口标题栏的 `TitleBarIconButton` 是**同一个规格**（28 × 28、圆角 6、
/// hover 时 `bg-subtle`），但两者所在文件不同、可访问性上下文也不同，没有合并：
/// 合并会逼着一个只关心面板的读者去读主窗口的文件。
private struct PopoverIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    hovering
                        ? DesignTokens.Palette.foreground
                        : DesignTokens.Palette.mutedForeground
                )
                .frame(
                    width: DesignTokens.Size.popoverIconButton,
                    height: DesignTokens.Size.popoverIconButton
                )
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(hovering ? DesignTokens.Palette.subtle : Color.clear)
                )
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
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - 菜单磁盘列表（占用结论的订阅点在这里）

/// 菜单栏面板的磁盘列表。
///
/// 与 ``DiskListRegion`` 同一条规矩（2026-09-24）：``OccupancyStore`` 的**订阅随读取走** ——
/// 面板自己不订阅它（这里读 ⇒ 这里订阅），否则占用每 15s 刷一次就会把**整个面板**
/// （头部计数、分隔线、四行动作）一起重建，而它们根本不关心占用结论。
///
/// 只收**值**（`disks` / `accent`）与一个 `onEject`；不传 store。
struct MenuDiskList: View {
    @ObservedObject var occupancyStore: OccupancyStore

    let disks: [DiskInfo]

    let accent: AccentColor

    let onEject: (DiskInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(disks) { disk in
                MenuBarDiskRow(
                    disk: disk,
                    occupancy: occupancyStore.result(for: disk),
                    accent: accent,
                    onEject: { onEject(disk) }
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }
}
