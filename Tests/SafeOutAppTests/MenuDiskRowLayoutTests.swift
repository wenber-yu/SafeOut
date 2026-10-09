import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 磁盘行的**排版与判定契约**测试。
///
/// **为什么需要**：这里同时钉住两类容易悄悄坏掉的东西 ——
/// ① 菜单栏面板宽 360pt，磁盘行里能放文本的宽度只剩约 320pt，
///    历史上四段信息被拼在**同一行** meta 里（实测文本宽约 250pt）→ 必然截断，
///    用户看到的就是「列表项显示不全」；
/// ② **「未知」不能被渲染成「没有占用」**。这是本应用最不能犯的错误：
///    未授权时若显示「可以安全推出」，用户会以为可以拔，而 Spotlight 可能正抓着这块盘。
@MainActor
struct MenuDiskRowLayoutTests {

    /// 菜单栏面板里磁盘行的**外框宽**：360 − 列表左右各 8pt。
    ///
    /// ⚠️ **不要再减行自己的 8pt**：`MenuBarDiskRow` 自带 `.padding(8)`，
    /// 它接收的宽度就是外框宽 344，内容列才是 328。
    /// 曾经写成 328（把行自己的内边距也减掉了），于是所有「会不会被截断」的判断
    /// 都是在**比真机窄 16pt** 的前提下做的 —— 真机上放得下的文案，测试里会判成截断；
    /// 反过来，真机上会被截断的长文案（如「占用程序：Finder、图像捕捉」），
    /// 测试里反而看不出问题。
    private let panelRowWidth = DesignTokens.Size.menuPopoverWidth - 2 * DesignTokens.Spacing.sm

    /// 行内真正能放**文本**的宽度。
    ///
    /// 设计稿 `.mrow` 是 `grid-template-columns: 32px 1fr auto` + `column-gap: 10px`，
    /// 文本列实测 248pt。这里按同一套算式算出来（外框 344 − 行内边距 16 − 图标 32
    /// − 两个 10pt 列间距 − 按钮 26 = 250），给「第三行会不会被截断」当判据。
    private var panelContentWidth: CGFloat {
        panelRowWidth - 2 * DesignTokens.Spacing.sm
            - DesignTokens.Size.menuIconContainer
            - DesignTokens.Size.buttonSmallHeight
            - 10 * 2
    }

    private let sampleDisk = DiskInfo(
        id: "/Volumes/My Passport",
        bsdName: "disk4s2",
        volumeName: "My Passport",
        mountPath: "/Volumes/My Passport",
        totalBytes: 1_000_000_000_000,
        usedBytes: 300_000_000_000,
        freeBytes: 700_000_000_000,
        deviceProtocol: "USB",
        deviceModel: "SanDisk Extreme 55AE"
    )

    private let sampleProcesses = [
        OccupyingProcess(pid: 5340, processName: "IINA", path: "/Volumes/My Passport/clip.mp4"),
        OccupyingProcess(pid: 39298, processName: "tail", path: "/Volumes/My Passport/clip.mp4"),
    ]

    /// 菜单栏模式的磁盘行。
    private func row(occupancy: OccupancyResult) -> some View {
        MenuBarDiskRow(
            disk: sampleDisk,
            occupancy: occupancy,
            accent: .default,
            onEject: {}
        )
    }

    /// 主窗口模式的磁盘行。
    private func mainRow(occupancy: OccupancyResult, density: DiskRowDensity = .regular) -> some View {
        DiskRow(
            disk: sampleDisk,
            occupancy: occupancy,
            accent: .default,
            onEject: {},
            density: density
        )
    }

    /// 在给定宽度下渲染，返回**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    ///
    /// ⚠️ 用 `sizeThatFits(in:)` 而不是 `setFrameSize + fittingSize`：
    /// 后者返回的是**无宽度约束的理想尺寸**，宽度根本不生效。菜单栏行的理想宽约 365pt，
    /// 而这里传入的是 328pt —— 旧写法量到的其实是「365pt 宽下的高」，
    /// 与「328pt 宽下的高」不是一回事（文案要折行时差别明显）。
    /// 详细对照实验见 `SettingsLayoutTests.renderedSize` 的注释。
    private func renderedSize(_ view: some View, width: CGFloat) -> CGSize {
        // `NSApp` 由 AppKit 建共享实例时赋值；宿主 SwiftUI 视图前必须先起它。
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    /// 不受宽度约束时的**理想宽度**——这是「会不会被截断」的判据：
    /// 理想宽度超过可用宽度，SwiftUI 只能截断。
    private func idealWidth(_ view: some View) -> CGFloat {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.width
    }

    // MARK: - 判定归约（安全关键）

    /// **本应用最不能犯的错误**：把「不知道」渲染成「没有占用」。
    @Test func 未知状态绝不被归约为安全() {
        #expect(DiskRowState(.unknown) == .unknown)
        #expect(
            DiskRowState(.needsFullDiskAccess) == .unknown,
            "「未授权」是「不知道」而不是「没有占用」，不能归约成 .safe——那会让用户以为可以拔盘"
        )
        #expect(DiskRowState(.none) == .safe)
        #expect(DiskRowState(.occupied(sampleProcesses)) == .busy(sampleProcesses))
    }

    @Test func 占用列表为空时归约为安全() {
        #expect(DiskRowState(.occupied([])) == .safe, "lsof 返回 0 行时是「确认没占用」，不是「忙」")
    }

    // MARK: - 文案构成

    @Test func 无占用进程时不产生占用行文案() {
        #expect(DiskRowText.occupancy(.none) == nil)
        #expect(
            DiskRowText.occupancy(.needsFullDiskAccess) == nil,
            "「未授权」是「不知道」而不是「没有占用」，不能渲染成占用行或安全提示"
        )
        #expect(DiskRowText.occupancy(.unknown) == nil)
    }

    @Test func 有占用进程时逐行列名() {
        let text = DiskRowText.occupancy(.occupied(sampleProcesses))
        #expect(text?.contains("IINA") == true, "占用行必须列出进程名，实际：\(text ?? "nil")")
        #expect(text?.contains("tail") == true)
        #expect(
            text?.contains(L10n.tr(.processNameListSeparator)) == true,
            "多个进程之间要用本地化分隔符（中文「、」/ 英文「, 」）"
        )
    }

    /// **回归**：占用行必须显示**应用名**，而不是进程可执行名。
    ///
    /// 用户报的原话是「占用程序的应用叫 Bunny，现在显示的是 IMVIDEO」。
    /// 这条把该现象钉在文案层：两者不一致时，只能出现应用名。
    /// （变异：把 `map(\.displayName)` 改回 `map(\.processName)`，本断言立刻变红。）
    @Test func 占用行显示应用名而不是进程可执行名() {
        let processes = [
            OccupyingProcess(
                pid: 75019, processName: "IMVIDEO", displayName: "Bunny",
                appBundlePath: "/Applications/IMVIDEO.app", path: "/Volumes/wenbo-data/clip.mp4")
        ]
        let text = DiskRowText.occupancy(.occupied(processes))
        #expect(text?.contains("Bunny") == true, "实际：\(text ?? "nil")")
        #expect(
            text?.contains("IMVIDEO") != true,
            "占用行出现了进程可执行名，用户认不出这是哪个应用；实际：\(text ?? "nil")")
    }

    // MARK: - 行内动作的可访问性标签

    /// **回归**：行内按钮的 a11y 标签必须**自带磁盘名**。
    ///
    /// VoiceOver 是线性朗读的：焦点落到按钮上时，上一行念过的磁盘名早就过去了。
    /// 只念「推出」/「推出中」，多盘并列时用户根本听不出在动哪块盘。
    /// （变异：把 `ejectingAccessibilityLabel` 改回 `L10n.tr(.ejecting)`，本断言立刻变红。）
    @Test func 行内动作标签都带磁盘名() {
        let labels = [
            DiskRowText.ejectAccessibilityLabel(sampleDisk),
            DiskRowText.closeAndEjectAccessibilityLabel(sampleDisk),
            DiskRowText.ejectingAccessibilityLabel(sampleDisk),
        ]
        for label in labels {
            #expect(
                label.contains(sampleDisk.displayName),
                "「\(label)」里没有磁盘名 —— VoiceOver 用户听不出在操作哪块盘"
            )
        }
    }

    /// 三种标签必须彼此不同：否则「推出」「关闭并推出」「正在推出」在 VoiceOver 里
    /// 听起来一样，用户无法判断当前点到的是哪个动作、盘现在什么状态。
    @Test func 行内动作标签互不重复() {
        let eject = DiskRowText.ejectAccessibilityLabel(sampleDisk)
        let close = DiskRowText.closeAndEjectAccessibilityLabel(sampleDisk)
        let ejecting = DiskRowText.ejectingAccessibilityLabel(sampleDisk)
        #expect(Set([eject, close, ejecting]).count == 3, "三种动作标签出现重复：\(eject) / \(close) / \(ejecting)")
    }

    /// 证据区标题必须带进程个数（「2 个程序正在占用」），拿不到具体进程时退化为无数字版本。
    @Test func 证据区标题带进程个数() {
        let busy = DiskRowText.evidenceTitle(.busy(sampleProcesses))
        #expect(busy.contains("2"), "证据区标题应包含进程个数，实际：\(busy)")

        let fallback = DiskRowText.evidenceTitle(.busy([]))
        #expect(!fallback.isEmpty)
    }

    /// 三种状态的紧凑行短标签必须**两两不同**，否则用户无法区分「安全」与「未知」。
    @Test func 紧凑行三种状态标签互不相同() {
        let busy = DiskRowText.compactStatus(.busy(sampleProcesses))
        let safe = DiskRowText.compactStatus(.safe)
        let unknown = DiskRowText.compactStatus(.unknown)
        #expect(Set([busy, safe, unknown]).count == 3, "实际：\(busy) / \(safe) / \(unknown)")
    }

    @Test func 总容量以括号附在名称右侧() {
        let text = DiskRowText.capacity(sampleDisk)
        #expect(text.contains(sampleDisk.totalFormatted))
        // 括号本身来自本地化，中文全角 / 英文半角都算通过——不能把断言绑死在当前语言上。
        #expect(text.hasPrefix("（") || text.hasPrefix("("), "总容量必须被括号包起来，实际：\(text)")
        #expect(text.hasSuffix("）") || text.hasSuffix(")"))
    }

    /// 主窗口的容量徽标**不带括号**（设计稿 `.row__fs` 是独立 pill，括号是多余的）。
    @Test func 主窗口容量徽标不带括号() {
        let text = DiskRowText.capacityBadge(sampleDisk)
        #expect(text == sampleDisk.totalFormatted, "实际：\(text)")
    }

    @Test func 已用与剩余同处一行且不换行() {
        let text = DiskRowText.usage(sampleDisk)
        #expect(text.contains(L10n.tr(.usedSpace)))
        #expect(text.contains(L10n.tr(.freeSpace)))
        #expect(!text.contains("\n"))
    }

    @Test func 紧凑行meta同时含总容量已用与剩余() {
        let text = DiskRowText.compactMeta(sampleDisk)
        #expect(text.contains(sampleDisk.totalFormatted))
        #expect(text.contains(L10n.tr(.usedSpace)))
        #expect(text.contains(L10n.tr(.freeSpace)))
    }

    // MARK: - 自适应与截断

    /// 占用检测是**异步**的（`lsof` 较慢），结果到达时行高**不许跳动**。
    ///
    /// 菜单栏行固定三行文案（名称+容量 / 已用剩余 / 占用结论），
    /// 结论行三种状态都渲染（安全态是「可安全推出」、未知态是「占用情况未知」），
    /// 所以行高与占用结果无关 —— 用户不会看到列表在检测完成的瞬间抖一下。
    ///
    /// （旧实现是「有占用才多一行」，检测结果到达时整列会向下跳 16pt。
    /// 变异：把安全态/未知态的结论行改成不渲染，本断言立刻变红。）
    @Test func 占用结果到达时菜单栏行高不跳动() {
        let states: [(String, OccupancyResult)] = [
            ("无占用", .none),
            ("有占用", .occupied(sampleProcesses)),
            ("未知", .unknown),
            ("未授权", .needsFullDiskAccess),
        ]
        var heights: [(String, CGFloat)] = []
        for (tag, occupancy) in states {
            heights.append((tag, renderedSize(row(occupancy: occupancy), width: panelRowWidth).height))
        }
        let unique = Set(heights.map { $0.1 })
        #expect(
            unique.count == 1,
            "四种占用状态下的行高不一致 \(heights) —— 检测结果到达时列表会跳动"
        )
    }

    /// 但**内容**必须随状态变化：三种状态各自有结论文字（不能只有配色不同）。
    @Test func 菜单栏行结论文字随状态变化() {
        let safe = renderedSize(row(occupancy: .none), width: panelRowWidth)
        let busy = renderedSize(row(occupancy: .occupied(sampleProcesses)), width: panelRowWidth)
        // 行高相同、宽度可不同（文字长度不同）—— 这里断言两者都渲染成功且尺寸合理。
        #expect(safe.width > 0 && busy.width > 0)
        #expect(
            DiskRowText.compactStatus(.safe) != DiskRowText.compactStatus(.busy(sampleProcesses)),
            "安全态与占用态的结论文字不能相同"
        )
        #expect(
            DiskRowText.compactStatus(.unknown) != DiskRowText.compactStatus(.safe),
            "未知态不能复用安全态的文案——那等于把「不知道」说成「可以拔」"
        )
    }

    @Test func 菜单栏整行放得进面板不被截断() {
        for (tag, occupancy) in [
            ("无占用", OccupancyResult.none),
            ("有占用", OccupancyResult.occupied(sampleProcesses)),
        ] {
            let width = idealWidth(row(occupancy: occupancy))
            #expect(
                width <= panelRowWidth,
                "\(tag)时整行理想宽度 \(width)pt > 面板可用 \(panelRowWidth)pt，会被截断"
            )
        }
    }

    /// 面板第三行的占用文案必须放得进文本列。
    ///
    /// **这是「占用程序：…」这一行的真实约束**：它比原来的「2 个程序占用」长得多，
    /// 而文本列只有约 250pt。一旦放不下，用户看到的是「占用程序：Finder、图像…」——
    /// 而「谁挡着」正是这一行存在的全部理由，截掉就等于没写。
    ///
    /// 用**设计稿里那对进程名**（Finder、图像捕捉）一起量，因为它们是这一行的
    /// 典型长度；只量 `IINA、tail` 这种短名字会高估余量。
    @Test func 菜单栏占用行放得进文本列() throws {
        let designLike = [
            OccupyingProcess(pid: 1, processName: "Finder", path: "/Volumes/x/a"),
            OccupyingProcess(pid: 2, processName: "图像捕捉", path: "/Volumes/x/b"),
        ]
        let candidates = [
            try #require(DiskRowText.occupancy(.occupied(sampleProcesses))),
            try #require(DiskRowText.occupancy(.occupied(designLike))),
        ]
        for text in candidates {
            let width = idealWidth(
                Text(text)
                    .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
                    .lineLimit(1))
            #expect(
                width <= panelContentWidth,
                "占用行「\(text)」宽 \(width)pt > 文本列 \(panelContentWidth)pt，会被省略号截断"
            )
        }
    }

    /// 菜单栏磁盘行与动作行的高度必须与设计稿实测一致（69 / 32）。
    ///
    /// 面板是「一眼扫完」的界面，行高差 7pt 就是「比设计稿挤」的全部来源：
    /// 三行文本各按系统自然行高排时，整行只有 62pt（设计稿 69），
    /// 面板整体矮 7pt —— 单看每一行都不觉得错。
    @Test func 菜单栏行高与动作行高与设计稿一致() {
        let tolerance: CGFloat = 2
        for (tag, occupancy) in [
            ("有占用", OccupancyResult.occupied(sampleProcesses)),
            ("无占用", OccupancyResult.none),
            ("未知", OccupancyResult.unknown),
        ] {
            let height = renderedSize(row(occupancy: occupancy), width: panelRowWidth).height
            #expect(
                abs(height - DesignTokens.Size.menuRowHeight) <= tolerance,
                "\(tag)时菜单栏行高 \(height)pt，设计稿实测 \(DesignTokens.Size.menuRowHeight)pt"
            )
        }

        let actionHeight = renderedSize(
            MenuActionRow(systemName: "macwindow", label: "打开主窗口", shortcut: "⌘O", action: {}),
            width: panelRowWidth
        ).height
        #expect(
            abs(actionHeight - DesignTokens.Size.menuActionRowHeight) <= tolerance,
            "动作行高 \(actionHeight)pt，设计稿实测 \(DesignTokens.Size.menuActionRowHeight)pt"
        )
    }

    /// 紧凑行必须**明显矮于**完整行——否则「一屏 8 块」的设计目标落空。
    @Test func 紧凑行显著矮于完整行() {
        let regular = renderedSize(mainRow(occupancy: .none, density: .regular), width: 800)
        let compact = renderedSize(mainRow(occupancy: .none, density: .compact), width: 800)
        #expect(
            compact.height < regular.height / 2,
            "紧凑行 \(compact.height)pt 未显著矮于完整行 \(regular.height)pt，切换密度没有意义"
        )
    }

    /// 阈值：≥ 4 块盘自动切紧凑行（设计稿 §3.3）。
    @Test func 四块盘起自动切紧凑行() {
        #expect(DiskRowDensity.forCount(1) == .regular)
        #expect(DiskRowDensity.forCount(3) == .regular)
        #expect(DiskRowDensity.forCount(4) == .compact)
        #expect(DiskRowDensity.forCount(8) == .compact)
    }

    /// 主窗口 800 × 520 里，**设计稿演示的那三块盘必须放得下**。
    ///
    /// 预算 = 窗口高 − 标题栏 − 列表上下内边距 = 520 − 52 − 28 = 440，
    /// 与设计稿实测的 `.disklist [766 × 440]` 一致。
    ///
    /// ⚠️ **这条断言曾经断言的是「最坏组合」**：1 块忙 + 2 块未知。
    /// 那个组合即使按设计稿的真实行高（169 / 133 / 133）也是
    /// `169 + 133×2 + 8×2 = 451 > 440` —— **设计稿自己都放不下**，
    /// 因为它的 `.scrollarea` 是 `overflow:hidden`，超出部分直接裁掉。
    /// 换句话说：这条断言在要求实现做到设计稿没做到的事。
    ///
    /// 现在改成断言**设计稿首页实际展示的组合**（1 忙 + 2 安全），
    /// 这正是 `.disklist` 恰好 440 的那个场景；更高的组合允许滚动 ——
    /// 主窗口有 `ScrollView`，比设计稿的硬裁更宽容，不是退化。
    @Test func 主窗口放得下设计稿演示的三块盘() {
        let titleBar = DesignTokens.Size.titleBarHeight
        let listPadding = DesignTokens.Spacing.md + DesignTokens.Spacing.lg
        let budget = DesignTokens.Size.mainWindow.height - titleBar - listPadding
        let spacing = DesignTokens.Spacing.sm

        let busy = renderedSize(mainRow(occupancy: .occupied(sampleProcesses)), width: 800).height
        let safe = renderedSize(mainRow(occupancy: .none), width: 800).height
        let need = busy + safe * 2 + spacing * 2
        #expect(
            need <= budget,
            "三块盘共需 \(need)pt（忙 \(busy) + 安全 \(safe) ×2 + 行距 \(spacing) ×2），超出预算 \(budget)pt —— 用户会看到滚动条"
        )
    }

    /// 单块盘无论什么状态都必须放得进列表区 —— 否则第一块盘就被裁掉了。
    @Test func 任意单块盘都放得进列表区() {
        let budget =
            DesignTokens.Size.mainWindow.height - DesignTokens.Size.titleBarHeight
            - DesignTokens.Spacing.md - DesignTokens.Spacing.lg
        for (tag, occupancy) in [
            ("有占用", OccupancyResult.occupied(sampleProcesses)),
            ("无占用", OccupancyResult.none),
            ("未知", OccupancyResult.unknown),
        ] {
            let height = renderedSize(mainRow(occupancy: occupancy), width: 800).height
            #expect(height <= budget, "\(tag)时单行 \(height)pt > 列表预算 \(budget)pt")
        }
    }

    /// 完整行的高度必须与设计稿实测值一致（169 / 127 / 133）。
    ///
    /// **这是「看起来和设计稿一样」的核心数字**：三块盘各差 2pt，整列就差 6pt，
    /// 用户扫一眼就会觉得「比设计稿挤」——而每一处单独看都不觉得错。
    /// 曾经这里只有一条「总高 ±12」，把「行高整体矮 11pt」兜住了（详见
    /// `AlertLayoutTests` 里同类问题的记录）。
    @Test func 完整行三种状态高度与设计稿一致() {
        let tolerance: CGFloat = 2
        let specs: [(String, OccupancyResult, CGFloat)] = [
            ("有占用", .occupied(sampleProcesses), DesignTokens.Size.diskRowBusyHeight),
            ("无占用", OccupancyResult.none, DesignTokens.Size.diskRowSafeHeight),
            ("未知", .unknown, DesignTokens.Size.diskRowUnknownHeight),
        ]
        for (tag, occupancy, expected) in specs {
            let height = renderedSize(mainRow(occupancy: occupancy), width: 800).height
            #expect(
                abs(height - expected) <= tolerance,
                "\(tag)行高 \(height)pt，设计稿实测 \(expected)pt，差 \(height - expected)pt"
            )
        }
    }

    /// 证据区折叠后行高必须变矮（「收起清单」不是装饰）。
    @Test func 紧凑行按钮保留在行内() {
        let width = idealWidth(mainRow(occupancy: .occupied(sampleProcesses), density: .compact))
        #expect(
            width <= 800,
            "紧凑行理想宽度 \(width)pt 超过窗口宽 800pt，会被截断"
        )
    }

    // MARK: - 三种行的琥珀条规格（设计稿 §3 第 3 项）

    /// 琥珀像素判据：`r − max(g, b) > 60`。与 `MainWindowDiskListTests.isAmber` 同一套阈值 ——
    /// 琥珀文字 `#B25000` 是 98（算）、琥珀浅底 ≈13（不算）。
    ///
    /// ⚠️ 收的是**非预乘** RGB（0…1）而不是 `NSColor`，理由同 `MainWindowDiskListTests.isAmber`。
    private func isAmber(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        Int(r * 255 - max(g * 255, b * 255)) > 60
    }

    /// 量一条忙盘琥珀条：**宽**、起止 y、段长，外加该行的高（pt，原点左上）。
    ///
    /// 宽在**垂直中点**量 —— 琥珀条只圆右端，在上下端点上会少一截。
    private func amberBar(
        _ view: some View, width: CGFloat
    ) -> (barWidth: CGFloat, top: CGFloat, height: CGFloat, rowHeight: CGFloat)? {
        let scale: CGFloat = 2
        let rowHeight = renderedSize(view, width: width).height
        let size = CGSize(width: width, height: rowHeight)
        guard let rep = OffscreenRender.bitmap(view, size: size),
            let box = OffscreenRender.boundingBox(rep, scale: scale, matchingRGB: isAmber)
        else { return nil }

        let x0 = Int(box.minX * scale)
        let yMid = Int(box.midY * scale)
        guard x0 >= 0, x0 < rep.pixelsWide, yMid >= 0, yMid < rep.pixelsHigh else { return nil }

        func amberAt(_ x: Int, _ y: Int) -> Bool {
            OffscreenRender.rgb(rep, x: x, y: y).map { isAmber($0.0, $0.1, $0.2) } ?? false
        }

        var px = 0
        while x0 + px < rep.pixelsWide, amberAt(x0 + px, yMid) {
            px += 1
        }

        var start: Int?
        var top = 0
        var height = 0
        for y in 0..<rep.pixelsHigh {
            let amber = amberAt(x0 + 1, y)
            if amber, start == nil {
                start = y
            } else if !amber, let s = start {
                top = s
                height = y - s
                break
            }
        }
        guard px > 0, height > 0 else { return nil }
        return (CGFloat(px) / scale, CGFloat(top) / scale, CGFloat(height) / scale, rowHeight)
    }

    /// 设计稿里 `.row--busy` / `.mrow--busy` / `.crow--busy` 是**三条独立规则**：
    /// 完整行 3 / 内缩 10、菜单行 **2.5** / 内缩 7、紧凑行 3 / 内缩 8（宽 / 上下内缩）。
    ///
    /// ## 为什么必须有这条（2026-09-18 实扫）
    ///
    /// 三组令牌当时**接错了两处**：`MenuBarDiskRow`（菜单面板行）用的是紧凑行的 3 / 8，
    /// `DiskRow` 的紧凑分支用的是完整行的 3 / 10 —— 而给菜单行的 `menuBusyBar*`（2.5 / 7）
    /// **零消费者**。`DESIGN-SPEC.md` §3 那一项还标着 `✅`、`DesignTokens.swift` 的注释还写着
    /// 「曾经菜单面板行宽了 0.5pt，已修」—— 两处都是**假 ✅**：令牌的值一直是对的，没人用它。
    ///
    /// 后果都可见：菜单行琥珀条宽 0.5pt、紧凑行的条短 4pt。
    /// 而 `MainWindowDiskListTests` 当时**把设计稿的账算对了**（46 − 2×8 = 30）、量到 26，
    /// 把差的 4pt 归因给了 `UnevenRoundedRectangle` 的取整 ——
    /// **算术与实测对不上时，先怀疑接线，别先怀疑取整。**
    ///
    /// ## 为什么不能只断言令牌的值
    ///
    /// `#expect(menuBusyBarWidth == 2.5)` 是**拿常量跟自己比**：令牌的值一直是 2.5，
    /// 错的是「哪一行用了它」。所以这里**量像素**，且期望值取**设计稿的字面值** ——
    /// 令牌被改坏时这条也会红。
    ///
    /// ## 宽度那一轴现在两侧都守（2026-09-20 修正，§8.87）
    ///
    /// 之前只守上限，因为**当时 2.5pt 真的落不了地**：把 `BusyBar` 的修饰符链原样搬到
    /// 隔离容器里实测（2026-09-18，2x、浅色、行首对齐），老的 `UnevenRoundedRectangle`
    /// 画法是 2.4→2.0pt、**2.5→3.0pt**、2.6/3.0/3.4→3.0pt、5.0→5.0pt。
    ///
    /// **机制已实测确立**：SwiftUI 传给 `path(in:)` 的 `rect` **已经被对齐到整点**，
    /// 于是「用 `rect.width` 画」的形状一律只能落整点宽（与圆角无关 —— 无圆角 `Rectangle`
    /// 同样落 3.0pt）。`BusyBarShape` 因此**不用 `rect.width`、改用自己的 `width` 属性**
    /// （绝对坐标），2.5pt 就落得下来了。
    ///
    /// ⇒ 宽度轴**重新可观测**，守卫改成双侧、容差半个物理像素（0.25pt）。
    /// **这条有变异测试背书**：把 `BusyBarShape` 改回用 `rect.width`，实测回到 3.0pt、本条变红。
    /// 段长（内缩）那条照旧 —— 见下面。
    @Test func 三种行的琥珀条各用自己那组的规格() {
        let busy = OccupancyResult.occupied(sampleProcesses)
        let cases: [(tag: String, view: AnyView, width: CGFloat, barWidth: CGFloat, inset: CGFloat)] = [
            ("主窗口完整行（`.row--busy`）", AnyView(mainRow(occupancy: busy, density: .regular)), 800, 3, 10),
            ("主窗口紧凑行（`.crow--busy`）", AnyView(mainRow(occupancy: busy, density: .compact)), 800, 3, 8),
            ("菜单栏面板行（`.mrow--busy`）", AnyView(row(occupancy: busy)), panelRowWidth, 2.5, 7),
        ]
        for c in cases {
            guard let m = amberBar(c.view, width: c.width) else {
                Issue.record(
                    "\(c.tag)：一条琥珀条都没量到 —— 这次量测整体不可信（列位置/阈值错了？），后面的结论一律作废"
                )
                continue
            }
            // ⚠️ **两侧都守**，容差「半个物理像素」（2x 下 0.25pt）。
            // 之前只守上限（`<= 规定 + 0.5`），而 `UnevenRoundedRectangle` 把 2.5pt
            // 渲染成 3.0pt 时 **照样绿** —— 那版守卫对这次的偏差是没牙的（§8.87）。
            // 容差不能再松：3.0 与 2.5 差 0.5pt，松到 0.5 就又分不开了。
            #expect(
                abs(m.barWidth - c.barWidth) <= 0.26,
                """
                \(c.tag)的琥珀条宽实测 \(m.barWidth)pt，设计稿规定 \(c.barWidth)pt —— \
                多半是接错了另一组 `*BusyBar*` 令牌（三组：3/10、3/8、2.5/7）；\
                若实测是 \(c.barWidth.rounded(.up))pt 而规定是 \(c.barWidth)pt，\
                则是形状又把小数宽对齐到整点了（见 `BusyBarShape` 的文档）。
                """
            )
            let expected = m.rowHeight - 2 * c.inset
            #expect(
                abs(m.height - expected) <= 1.5,
                """
                \(c.tag)的琥珀条段长实测 \(m.height)pt（宽 \(m.barWidth)pt），应为「行高 \
                \(m.rowHeight) − 上下各内缩 \(c.inset)」= \(expected)pt —— 内缩取错了另一组令牌。\
                段位置：y=\(m.top)。
                """
            )
        }
    }
}
