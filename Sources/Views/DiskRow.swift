import AppKit
import SwiftUI

// 磁盘行 —— 整个界面里最重要的一块。
//
// 设计稿把一块盘的信息按 **判定 → 身份 → 证据 → 动作** 四层排布：
//
//   [图标]  磁盘名 [总容量]                                  [主按钮]
//           已用 300 GB · 剩余 700 GB
//           ▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░  30%
//           ┌ 证据区 ───────────────────────────────┐
//           │ ⚠ 2 个程序正在占用          收起清单   │
//           │ [Finder] [图像捕捉]                    │
//           └───────────────────────────────────────┘
//
// 三条硬规则（写代码时不许绕过）：
// 1. **判定优先**：左侧琥珀条 + 结论文字 + 按钮形态，三处同时表达状态，
//    用户扫一眼就知道能不能拔，不必读完整行。
// 2. **「未知」绝不渲染成「没有占用」**：未授权时显示「占用情况未知 · 授权后可检测」，
//    而不是绿色「可以安全推出」。这是本应用最不能犯的错误。
// 3. **琥珀只表示「受阻且需用户介入才能恢复」，红色只表示「破坏性」**（设计稿 §2.1）。
//    「被占用」只是琥珀的**一个实例**（本文件几处琥珀条、忙态文字都是它），
//    判据外的语义不复用 —— 见 ```DesignTokens/Palette``` 抬头那三条判据。

// MARK: - 被占用行的琥珀条
//
// 设计稿里它是 `::before`：`border-radius: 0 2px 2px 0` —— **只圆右端**。
// 三种行各有自己的宽度与上下内缩（见 ``DesignTokens/Size`` 的 `*BusyBar*`）。
//
// **为什么不能用一个 `Capsule()` 了事**：左端也跟着圆 1.5pt 之后，
// 琥珀条的左端会缩进行内 1.5pt，与行的左边缘之间露出一小段背景色 ——
// 3pt 宽的东西上这点差异在 2x 屏上就是 3 个物理像素的缺口，放大看很明显。

/// 琥珀条的形状：**只圆右端**，且**宽度走自己的属性，不用 `path(in:)` 给的那个 `rect.width`**。
///
/// ## 为什么必须自己画（2026-09-20，SPEC §8.87）
///
/// 之前用 `UnevenRoundedRectangle` —— 而它**渲染不出 2.5pt**：2x 实测
/// `.frame(width: 2.5)` 一律渲染成 **3.0pt（6px）**，2.4 → 2.0pt、5.0 → 5.0pt。
/// ⚠️ **与圆角无关**：无圆角的 `Rectangle` 同样落 3.0pt（排除「圆角放不下被撑开」这个猜想）。
///
/// **机制（实测确立，不是猜）**：SwiftUI 传给 `path(in:)` 的 `rect` **已经被对齐到整点**，
/// 于是**任何「用 `rect.width` 画」的形状都只能落整点宽** —— 自定义 `Shape` 也一样。
/// ⇒ 只要 path 用**绝对坐标**（这里就是 `self.width`），小数宽度就落得下来。
///
/// 另一条能落 2.5pt 的路是 `scaleEffect(x: 0.5)`（画 5pt 再缩一半）—— **没用它**：
/// 那会把右端圆角压成**椭圆**（x 半径 2 / y 半径 4），与设计稿 `0 2px 2px 0` 的**圆**角不符。
private struct BusyBarShape: Shape {
    let width: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = width
        let h = rect.height
        let r = min(radius, w, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addArc(
            center: CGPoint(x: w - r, y: r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false)
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addArc(
            center: CGPoint(x: w - r, y: h - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

/// 被占用行左侧的琥珀判定条。只圆右端，左端贴齐行的左边缘。
///
/// 宽与上下内缩由调用方给（三种行各有自己的一组 `*BusyBar*` 令牌）。
/// 形状本身见 ``BusyBarShape`` —— 那里解释了为什么不能用现成的圆角矩形。
private struct BusyBar: View {
    let width: CGFloat
    let verticalInset: CGFloat

    var body: some View {
        BusyBarShape(width: width, radius: DesignTokens.Size.busyBarRadius)
            .fill(DesignTokens.Palette.warning)
            .frame(width: width)
            .padding(.vertical, verticalInset)
            .accessibilityHidden(true)
    }
}

// MARK: - 行状态

/// 一块盘的判定结论。由 ``OccupancyResult``（+ 可选的 ``VolumeWriteActivity``）归约而来，
/// UI 只认这四种。
///
/// **为什么要单独归约**：``OccupancyResult`` 有四个 case，其中 `.needsFullDiskAccess`
/// 与 `.unknown` 在**展示上是同一件事**（都是「不知道」），但语义不同（前者用户可补救）。
/// 归约一次，视图里就不会再出现「某个 case 忘了处理、默默渲染成安全」的漏洞。
enum DiskRowState: Equatable {
    /// 已确认有进程占用，携带进程列表。
    case busy([OccupyingProcess])
    /// 没有进程占用，但容量在稳定减少 —— **正在被写入**（见 ``VolumeWriteActivity``）。
    case writing(VolumeWriteActivity)
    /// 已确认没有进程占用、也没有测到写入。
    case safe
    /// 无法判断（未授权 FDA / 沙盒）。**不可当作安全**。
    case unknown

    /// 归约。**写入活动只在「没有进程」时才升格成 ``writing``**：
    /// 有进程时那句话更具体（能点名、能关闭），速率反而是次要信息。
    init(_ result: OccupancyResult, activity: VolumeWriteActivity? = nil) {
        switch result {
        case .occupied(let processes):
            if !processes.isEmpty {
                self = .busy(processes)
            } else {
                // `.occupied([])` 是「系统说忙但列不出进程」，它本身已经**不安全**；
                // 此时写入活动正好补上一条可读的理由。
                self = activity.map(DiskRowState.writing) ?? .safe
            }
        case .none:
            self = activity.map(DiskRowState.writing) ?? .safe
        case .unknown, .needsFullDiskAccess:
            // 「不知道」压过任何活动证据：连进程都看不到，就别再断言别的了。
            self = .unknown
        }
    }

    /// 有**进程**占用（决定按钮是否变红「关闭并推出」）。
    ///
    /// ⚠️ 写入活动**不算** `isBusy`：它没有 pid，变红按钮等于承诺一个做不到的动作。
    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }

    /// 需要用户留意（任一种「这块盘现在别拔」）。琥珀条、琥珀图标、悬停底色都用它。
    ///
    /// **为什么不直接用 `isBusy`**：写入中的盘同样是「别拔」，只是拦它的手段不同
    /// （等它写完，而不是关掉某个应用）。若只按 `isBusy` 画琥珀条，
    /// 界面会在最危险的时刻表现得和闲置时一模一样 —— 这次用户报的正是这个。
    var needsAttention: Bool {
        switch self {
        case .busy, .writing: return true
        case .safe, .unknown: return false
        }
    }

    var processes: [OccupyingProcess] {
        if case .busy(let list) = self { return list }
        return []
    }
}

/// 行的密度（设计稿 §3.3）。
///
/// **≥ 4 块磁盘自动切紧凑行**：完整行 112~169pt 时一屏只放得下 3 块，
/// 用户插满读卡器就得滚动。紧凑行去掉容量条（数字已表达同一信息），
/// 保留全部判定线索，行高 46pt，一屏可见 8 块。
enum DiskRowDensity {
    /// 完整行：图标 40、容量条、证据区。
    case regular
    /// 紧凑行：图标 30、单行、无容量条。
    case compact

    /// 按磁盘数量选择密度。
    static func forCount(_ count: Int) -> DiskRowDensity {
        count >= DesignTokens.Size.compactRowThreshold ? .compact : .regular
    }
}

// MARK: - 文案（纯函数，UI 只渲染不判断）

/// 磁盘行的文案构成。
///
/// **为什么单独抽出来**：菜单栏面板宽 360pt、主窗口 800pt，同一块盘在两处的文案
/// 详略不同。把构成收敛成无视图依赖的纯函数后，单测可以直接断言
/// 「无占用时不产生占用行文案」「占用行显示应用名而不是进程可执行名」，
/// 而不必去视图里猜字符串是怎么拼的。
enum DiskRowText {

    /// 总容量徽标（主窗口 `.row__fs`），如「1 TB」。**不带括号**。
    static func capacityBadge(_ disk: DiskInfo) -> String { disk.totalFormatted }

    /// 菜单栏名称行右侧的括号总容量，如「（1 TB）」。
    ///
    /// 括号本体来自本地化（中文全角「（）」/ 英文半角「()」），不写死。
    static func capacity(_ disk: DiskInfo) -> String {
        String(format: L10n.tr(.capacityInParenthesesFormat), disk.totalFormatted)
    }

    /// 已用 / 剩余，如「已用 300 GB · 剩余 700 GB」。
    static func usage(_ disk: DiskInfo) -> String {
        "\(L10n.tr(.usedSpace)) \(disk.usedFormatted) · "
            + "\(L10n.tr(.freeSpace)) \(disk.freeFormatted)"
    }

    /// 紧凑行的单行 meta，如「1 TB · 已用 300 GB · 剩余 700 GB」。
    static func compactMeta(_ disk: DiskInfo) -> String {
        "\(disk.totalFormatted) · \(usage(disk))"
    }

    /// 占用进程行，如「占用程序: Bunny、tail」。
    ///
    /// 用的是 ``OccupyingProcess/displayName``（**应用显示名**，如 `Bunny`）而不是
    /// ``OccupyingProcess/processName``（可执行名，如 `IMVIDEO`）——后者用户认不出。
    ///
    /// **没有可列出的进程时返回 `nil`**，调用方据此**整行不渲染**，行高自适应。
    /// `.needsFullDiskAccess` / `.unknown` 也返回 `nil`——它们是「不知道」而不是
    /// 「没有占用」，若渲染成「无进程占用」会让用户误以为可以安全推出。
    static func occupancy(_ result: OccupancyResult) -> String? {
        let names = result.processes.map(\.displayName)
        guard !names.isEmpty else { return nil }
        let joined = names.joined(separator: L10n.tr(.processNameListSeparator))
        return "\(L10n.tr(.occupiedProcessesTitle)) \(joined)"
    }

    /// 证据区头部标题：有进程时「2 个程序正在占用」，拿不到具体进程时退化为「有程序正在占用」。
    static func evidenceTitle(_ state: DiskRowState) -> String {
        switch state {
        case .busy(let processes) where !processes.isEmpty:
            return String(format: L10n.tr(.busyEvidenceTitleFormat), processes.count)
        case .busy:
            return L10n.tr(.busyEvidenceTitleFallback)
        case .writing(let activity):
            // **说人话**：用户此刻最想知道的是「我到底能不能拔」，而不只是「有进程」。
            // 速率来自 ``VolumeWriteActivity`` 的实测，比笼统的「有写入」更像在做事。
            return String(format: L10n.tr(.writingEvidenceTitleFormat), activity.formattedRate)
        case .safe:
            return L10n.tr(.safeToEjectConclusion)
        case .unknown:
            return L10n.tr(.unknownEvidenceTitle)
        }
    }

    /// 紧凑行的状态短标签。
    static func compactStatus(_ state: DiskRowState) -> String {
        switch state {
        case .busy(let processes):
            return processes.isEmpty
                ? L10n.tr(.busyEvidenceTitleFallback)
                : String(format: L10n.tr(.compactBusyFormat), processes.count)
        case .writing:
            // 紧凑行只有 46pt 高、还要和容量数字挤一行，速率留给证据区/面板，这里只报状态。
            return L10n.tr(.compactWriting)
        case .safe:
            return L10n.tr(.compactSafe)
        case .unknown:
            return L10n.tr(.compactUnknown)
        }
    }

    /// 菜单栏面板第三行的写入文案，如「正在写入 · 36 MB/s」。
    ///
    /// 与 ``evidenceTitle(_:)`` 的写入分支分开，是因为面板只有 360pt 宽：
    /// 主窗口那句「（可能在拷贝文件）」放进来会被截尾，反而把速率挤掉。
    static func writingStatus(_ activity: VolumeWriteActivity) -> String {
        String(format: L10n.tr(.writingStatusFormat), activity.formattedRate)
    }

    // MARK: 行内动作的可访问性标签

    /// 为什么这三个标签必须**自带磁盘名**：
    /// VoiceOver 是**线性**朗读的。焦点落到行内按钮时，上一行刚念过的磁盘名早过去了，
    /// 只念「推出」/「推出中」等于没说在动哪块盘 —— 多盘并列时用户根本无从分辨。
    /// 可见文字反而不需要带名字（按钮就画在那一行里，看得见的人自带上下文）。
    ///
    /// 三个都收在这里而不是散在视图里，是为了让「必须带磁盘名」这条规则
    /// 只有一个出处，也能被单测钉住（`MenuDiskRowLayoutTests`）。

    /// 空闲态按钮的标签，如「推出 Samsung T7」。
    static func ejectAccessibilityLabel(_ disk: DiskInfo) -> String {
        String(format: L10n.tr(.ejectDiskFormat), disk.displayName)
    }

    /// 被占用态按钮的标签，如「关闭并推出 Samsung T7」。
    static func closeAndEjectAccessibilityLabel(_ disk: DiskInfo) -> String {
        String(format: L10n.tr(.closeAndEjectDiskFormat), disk.displayName)
    }

    /// 推出进行中的标签（按钮与 spinner 共用），如「正在推出 Samsung T7」。
    static func ejectingAccessibilityLabel(_ disk: DiskInfo) -> String {
        String(format: L10n.tr(.ejectingDiskFormat), disk.displayName)
    }
}

// MARK: - 主窗口磁盘行

/// 主窗口的磁盘行（设计稿 `.row` / `.crow`）。
struct DiskRow: View {

    let disk: DiskInfo
    let occupancy: OccupancyResult
    /// 「正在被写入」的实测证据（来自 ``OccupancyStore/activity(for:)``）。
    ///
    /// 单独成一路入参而不是并进 `occupancy`：它不是「占用」，没有 pid，
    /// 也不能被「关闭并推出」拿去清场（见 ``OccupancyStore/activities`` 的说明）。
    var activity: VolumeWriteActivity? = nil
    let accent: AccentColor
    let onEject: () -> Void

    /// 行密度。默认按磁盘数量自动选择，调用方可用 `density` 显式覆盖（测试用）。
    var density: DiskRowDensity = .regular
    /// 推出中：按钮就地变「推出中」+ spinner，保留原尺寸。
    var isEjecting: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// 证据区是否展开（设计稿 `.evid__hint` 的「收起清单」）。
    @State private var isEvidenceExpanded = true

    private var state: DiskRowState { DiskRowState(occupancy, activity: activity) }

    var body: some View {
        switch density {
        case .regular: regularBody
        case .compact: compactBody
        }
    }

    // MARK: 完整行

    private var regularBody: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            IconBadge(
                systemName: "externaldrive.fill",
                style: .diskRow,
                accent: accent,
                isBusy: state.needsAttention)

            VStack(alignment: .leading, spacing: DesignTokens.Size.rowColumnGap) {
                headRow
                StorageMeter(ratio: disk.usagePercent, accent: accent)
                evidenceArea
            }
        }
        .padding(DesignTokens.Size.rowPadding)
        .background(rowBackground)
        .overlay(alignment: .leading) { busyBar }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(
            DesignTokens.Motion.animation(DesignTokens.Motion.fast, reduceMotion: reduceMotion),
            value: hovering)
    }

    /// 头部：身份（名称 + 容量徽标 + 已用/剩余）与动作（主按钮）同处一行。
    ///
    /// **两行文字都按设计稿的行高排版**（`.row__name` 15pt → 行盒 22、`.row__meta` 12pt → 17）。
    /// 用系统自然行高时这两行只有 19 / 15，整行的 `.row__id` 比设计稿矮 5pt，
    /// 三块盘排下来就是「列表看起来比设计稿紧」——而每一处单独看都不觉得错。
    private var headRow: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Size.rowIdGap) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(disk.displayName)
                        .font(.system(size: DesignTokens.FontSize.title, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.foreground)
                        .designLineHeight(
                            DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.title
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    CapacityBadge(text: DiskRowText.capacityBadge(disk))
                }
                metaLine
                    .font(.system(size: DesignTokens.FontSize.caption))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .designLineHeight(
                        DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.caption
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // 名称列优先让位：宽度不够时先截断磁盘名，按钮始终完整。
            .layoutPriority(1)

            Spacer(minLength: DesignTokens.Spacing.sm)

            actionButton
        }
    }

    /// 「已用 **300 GB** · 剩余 **700 GB**」——数字加重，让同排多块盘的容量能纵向扫读。
    private var metaLine: Text {
        Text(L10n.tr(.usedSpace) + " ")
            + Text(disk.usedFormatted).fontWeight(.medium).foregroundColor(
                DesignTokens.Palette.foreground)
            + Text(" · " + L10n.tr(.freeSpace) + " ")
            + Text(disk.freeFormatted).fontWeight(.medium).foregroundColor(
                DesignTokens.Palette.foreground)
    }

    /// 证据区（设计稿 §3.4）。三种状态各有长相，但**都由同一处判定驱动**。
    @ViewBuilder
    private var evidenceArea: some View {
        switch state {
        case .busy(let processes):
            EvidenceBlock(
                kind: .busy,
                title: DiskRowText.evidenceTitle(state),
                processes: processes,
                isExpanded: isEvidenceExpanded,
                hint: processes.count > 1
                    ? (isEvidenceExpanded ? L10n.tr(.collapseList) : L10n.tr(.expandList))
                    : nil,
                onToggleHint: processes.count > 1
                    ? { withAnimation(DesignTokens.Motion.standard) { isEvidenceExpanded.toggle() } }
                    : nil
            )
        case .writing:
            // 没有可点名的进程：证据区只放结论（带速率），不画芯片列表。
            EvidenceBlock(
                kind: .writing,
                title: DiskRowText.evidenceTitle(state),
                processes: [],
                isExpanded: true,
                hint: nil,
                onToggleHint: nil
            )
        case .safe:
            EvidenceBlock(
                kind: .safe,
                title: DiskRowText.evidenceTitle(state),
                processes: [],
                isExpanded: true,
                hint: nil,
                onToggleHint: nil
            )
        case .unknown:
            EvidenceBlock(
                kind: .unknown,
                title: DiskRowText.evidenceTitle(state),
                processes: [],
                isExpanded: true,
                hint: L10n.tr(.unknownEvidenceHint),
                onToggleHint: nil
            )
        }
    }

    // MARK: 紧凑行

    private var compactBody: some View {
        HStack(spacing: 10) {
            IconBadge(
                systemName: "externaldrive.fill",
                style: .compactRow,
                accent: accent,
                isBusy: state.needsAttention)

            Text(disk.displayName)
                .font(.system(size: DesignTokens.FontSize.bodyStrong, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                // 设计稿 `.crow__name { max-width: 190px }`：限宽才能让多块盘的
                // 「容量 / 状态 / 按钮」三列纵向对齐 —— 否则长名字的盘会把后面全推右。
                .frame(maxWidth: DesignTokens.Size.compactNameMaxWidth, alignment: .leading)
                .layoutPriority(1)

            Text(DiskRowText.compactMeta(disk))
                .font(.system(size: DesignTokens.FontSize.footnote))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)

            // 设计稿 `.crow__grow { min-width: 12px }`。
            Spacer(minLength: 12)

            compactStatusLabel

            actionButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(rowBackground)
        .overlay(alignment: .leading) { busyBar }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(
            DesignTokens.Motion.animation(DesignTokens.Motion.fast, reduceMotion: reduceMotion),
            value: hovering)
    }

    private var compactStatusLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: compactStatusIcon)
                .font(.system(size: 11, weight: .semibold))
            Text(DiskRowText.compactStatus(state))
                .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
        }
        .foregroundStyle(compactStatusColor)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var compactStatusIcon: String {
        switch state {
        case .busy: return "exclamationmark.triangle.fill"
        case .writing: return "arrow.down.circle.fill"
        case .safe: return "checkmark"
        case .unknown: return "info.circle"
        }
    }

    private var compactStatusColor: Color {
        switch state {
        case .busy, .writing: return DesignTokens.Palette.warningText
        case .safe: return DesignTokens.Palette.successText
        case .unknown: return DesignTokens.Palette.mutedForeground
        }
    }

    // MARK: 部件

    /// 悬停底色：被占用行用琥珀浅底（强化「这块盘有情况」），其余用中性浅底。
    private var rowBackground: Color {
        guard hovering else { return .clear }
        return state.needsAttention ? DesignTokens.Palette.warningSoft : DesignTokens.Palette.subtle
    }

    /// 被占用行的左侧琥珀条 —— **两种密度各有自己的规格**（设计稿 §3 的「三种行」）。
    ///
    /// | 密度 | 设计稿类 | 宽 / 上下内缩 |
    /// |---|---|---|
    /// | ``DiskRowDensity/regular`` | `.row--busy::before` | 3 / 10 |
    /// | ``DiskRowDensity/compact`` | `.crow--busy::before` | 3 / 8 |
    ///
    /// ⚠️ **2026-09-18 实扫修正**：此前这里**不分密度**，紧凑行也拿 `.row--busy` 的
    /// 内缩 10 —— 琥珀条比设计稿**短 4pt**（46 − 2×10 = 26，应为 46 − 2×8 = 30）。
    ///
    /// 当时 `MainWindowDiskListTests` **把设计稿的账算对了**（「行高 46 − 上下各内缩 8 = 30」），
    /// 却量到 26，于是把差的 4pt 归因给 `UnevenRoundedRectangle` 的取整 ——
    /// 而 4pt 正好是 `2 ×（10 − 8）`。**算术与实测对不上时，先怀疑接线，别先怀疑取整。**
    @ViewBuilder
    private var busyBar: some View {
        if state.needsAttention {
            switch density {
            case .regular:
                BusyBar(
                    width: DesignTokens.Size.rowBusyBarWidth,
                    verticalInset: DesignTokens.Size.rowBusyBarInset)
            case .compact:
                BusyBar(
                    width: DesignTokens.Size.compactBusyBarWidth,
                    verticalInset: DesignTokens.Size.compactBusyBarInset)
            }
        }
    }

    /// 主按钮 —— **随状态变形**（设计稿 §3.1 与 §5.1）。
    ///
    /// 空闲 = 强调色「推出」；被占用 = 红色「关闭并推出」。
    /// 破坏性在按钮本身就可见，不必点完才知道。点击后**照常**走系统接口 ——
    /// `fBsyErr` 仍是「忙」的唯一权威判据；而占用弹窗在缓存已经说「被占用」时就**立刻**弹，
    /// 不再等系统那十几秒（§8.146）—— 检测只决定「什么时候弹窗」，不决定「能不能推出」。
    @ViewBuilder
    private var actionButton: some View {
        if isEjecting {
            EjectingButton(
                accent: accent,
                disk: disk,
                size: density == .regular ? .small : .small
            )
        } else if state.isBusy {
            ActionButton(
                title: L10n.tr(.closeAndEject),
                systemImage: "eject.fill",
                variant: .danger,
                size: .small,
                accent: accent,
                accessibilityLabel: DiskRowText.closeAndEjectAccessibilityLabel(disk),
                action: onEject)
        } else {
            ActionButton(
                title: L10n.tr(.eject),
                systemImage: "eject.fill",
                variant: .primary,
                size: .small,
                accent: accent,
                accessibilityLabel: DiskRowText.ejectAccessibilityLabel(disk),
                action: onEject)
        }
    }
}

// MARK: - 证据区（设计稿 §3.4 / `.evid`）

/// 证据区：回答「谁挡着？」。这是本应用存在的理由，所以它是一块**有边界的区域**，
/// 而不是行尾一个小标签。
struct EvidenceBlock: View {
    enum Kind {
        case busy
        /// 有写入但没有可点名的进程（访达拷贝这类 `lsof` 看不到的写入）。
        ///
        /// 与 `.busy` 共用琥珀底色 —— 用户要做的决定是同一个（「先别拔」），
        /// 只是拦路的原因不同；图标与文案把这层差别说清楚。
        case writing
        case safe
        case unknown
    }

    let kind: Kind
    let title: String
    let processes: [OccupyingProcess]
    /// 芯片区是否展开。折叠时只留头部（进程很多时用户可主动收起）。
    let isExpanded: Bool
    /// 右侧提示：`.unknown` 时是「授权后可检测」，`.busy` 时是「收起/展开清单」。
    let hint: String?
    let onToggleHint: (() -> Void)?

    /// 芯片最多显示几个，其余折叠为 `+N`。
    private let maxVisibleChips = 6

    var body: some View {
        switch kind {
        case .safe: safeBody
        case .busy, .writing:
            blockBody(
                background: DesignTokens.Palette.warningSoft,
                border: DesignTokens.Palette.warningLine)
        case .unknown:
            blockBody(background: DesignTokens.Palette.sunken, border: DesignTokens.Palette.border)
        }
    }

    /// 头部图标。**写入用「向下箭头进圈」而不是警告三角**：它不是在报错，
    /// 而是在说「数据正在流进来」——三角会让用户以为出了问题、急着去关东西。
    private var iconName: String {
        switch kind {
        case .busy: return "exclamationmark.triangle.fill"
        case .writing: return "arrow.down.circle.fill"
        case .unknown: return "info.circle"
        case .safe: return "checkmark"
        }
    }

    /// 头部的配色是否走琥珀这一档（只有 `blockBody` 里会问）。
    private var usesWarningColor: Bool {
        switch kind {
        case .busy, .writing: return true
        case .safe, .unknown: return false
        }
    }

    /// 可安全推出：**无底色、无边框**——它不是一个「区域」，只是一句结论。
    /// 给它画框会让「没事」看起来和「有事」一样重。
    ///
    /// 设计稿 `.evid--safe { padding: 7px 12px }`，块高 31 = 7 + 7 + 行盒 17。
    /// 用自然行高时只有 15，整行矮 2pt。
    private var safeBody: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.success)
            Text(title)
                .font(.system(size: DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.Palette.successText)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.caption)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, DesignTokens.Size.evidencePaddingH)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr(.safeToEject))
    }

    private func blockBody(background: Color, border: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Size.evidenceHeadGap) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: DesignTokens.FontSize.caption, weight: .semibold))
                    .monospacedDigit()
                    .designLineHeight(
                        DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.caption)
                Spacer(minLength: DesignTokens.Spacing.sm)
                if let hint {
                    hintView(hint)
                }
            }
            .foregroundStyle(
                usesWarningColor
                    ? DesignTokens.Palette.warningText : DesignTokens.Palette.mutedForeground)

            if isExpanded && !processes.isEmpty {
                chips
            }
        }
        .padding(.top, DesignTokens.Size.evidencePaddingTop)
        .padding(.horizontal, DesignTokens.Size.evidencePaddingH)
        .padding(.bottom, DesignTokens.Size.evidencePaddingBottom)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(border, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func hintView(_ text: String) -> some View {
        if let onToggleHint {
            Button(action: onToggleHint) {
                HStack(spacing: 3) {
                    Text(text)
                        .designLineHeight(
                            DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .font(.system(size: DesignTokens.FontSize.footnote))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disableFocusRing()
            .accessibilityAddTraits(.isButton)
        } else {
            Text(text)
                .font(.system(size: DesignTokens.FontSize.footnote))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote)
        }
    }

    /// 进程芯片。**必须用真实应用图标 + 显示名**，不用 `lsof` 的可执行名。
    private var chips: some View {
        let visible = Array(processes.prefix(maxVisibleChips))
        let overflow = processes.count - visible.count
        return HStack(spacing: 6) {
            ForEach(visible) { process in
                ProcessChip(process: process)
            }
            if overflow > 0 {
                ProcessChipOverflow(count: overflow)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 推出中按钮（设计稿 §5.2）

/// 进行中：按钮**就地**变「推出中」+ spinner，保留原尺寸（换 spinner 后不能塌陷）。
///
/// **不弹遮罩、不显示进度百分比**：系统接口不提供进度，编一个进度条是撒谎。
struct EjectingButton: View {
    let accent: AccentColor
    /// 目标磁盘 —— **只用于可访问性标签**。
    ///
    /// 可见文字是「推出中」就够了（按钮就画在那一行里），
    /// 但 VoiceOver 用户是**线性**听的：焦点落到按钮上时，上一行的磁盘名早念完了。
    /// 只念「推出中」等于没说在推哪块盘，所以 a11y 标签必须自己带磁盘名
    /// （与「推出 %@」「关闭并推出 %@」同一套规则，见 ``DiskRowText``）。
    let disk: DiskInfo
    var size: ButtonSize = .small

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(L10n.tr(.ejecting))
                .font(.system(size: size.fontSize, weight: .medium))
        }
        .foregroundStyle(DesignTokens.Palette.mutedForeground)
        .padding(.horizontal, 10)
        // v3：按钮高度归系统（`.controlSize(.regular)` = 24，HANDOFF §3.5 实测）。
        // 这里的 24 不是自绘预算，是**对齐值** —— 它就地在「推出」按钮的位置上
        // 换内容，高度必须与系统按钮一致，切换瞬间才不会塌陷/跳动。
        .frame(height: 24)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.borderStrong, lineWidth: 1)
        )
        .accessibilityLabel(DiskRowText.ejectingAccessibilityLabel(disk))
    }
}

// MARK: - 菜单栏磁盘行（设计稿 `.mrow`）

/// 菜单栏面板（360pt 宽）的磁盘行。
///
/// **与主窗口行是两套排版，不能共用**：面板只有 360pt 宽，放不下容量条与证据区。
/// 这里用三行文本压缩表达同一套信息（名称+容量 / 已用剩余 / 占用结论），
/// 按钮退化为 26 × 26 图标按钮 —— 但**判定线索一条不少**：
/// 琥珀条、琥珀图标容器、红色按钮、占用结论文字，四处仍在。
struct MenuBarDiskRow: View {

    let disk: DiskInfo
    let occupancy: OccupancyResult
    /// 「正在被写入」的实测证据，同 ``DiskRow/activity``。
    var activity: VolumeWriteActivity? = nil
    let accent: AccentColor
    let onEject: () -> Void
    var isEjecting: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var state: DiskRowState { DiskRowState(occupancy, activity: activity) }

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(
                systemName: "externaldrive.fill",
                style: .menuRow,
                accent: accent,
                isBusy: state.needsAttention)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    // **字重是 500，不是 600**：设计稿 `.mrow__name { font-weight: 500 }`。
                    // 面板里这一行只有 13pt，600 会让「磁盘名」比同一行的应用名
                    // （`.pop__appname` 才是 600）还重，扫视时抢错焦点。
                    // 主窗口的 `.row__name` 是另一档（15pt / 600），两处不能共用字重。
                    Text(disk.displayName)
                        .font(.system(size: DesignTokens.FontSize.bodyStrong, weight: .medium))
                        .foregroundStyle(DesignTokens.Palette.foreground)
                        .designLineHeight(
                            DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.bodyStrong
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 容量取 `layoutPriority(1) + fixedSize()`：名称过长时截断名称，
                    // 括号里的容量始终完整可见。
                    //
                    // **颜色是 `--text-3`**：设计稿 `.mrow__name span { color: var(--text-3) }`
                    // —— 括号里的总容量是**磁盘名的补充**，不是独立的一行信息，
                    // 用 `--text-2` 会把它抬到与「已用/剩余」同一档，三行读起来主次不分。
                    Text(DiskRowText.capacity(disk))
                        .font(.system(size: DesignTokens.FontSize.footnote))
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Palette.textDecorative)
                        .designLineHeight(
                            DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                        )
                        .lineLimit(1)
                        .layoutPriority(1)
                        .fixedSize()
                }
                Text(DiskRowText.usage(disk))
                    .font(.system(size: DesignTokens.FontSize.footnote))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .designLineHeight(
                        DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 设计稿 `.mrow` 的 `column-gap: 10px` 对三列一视同仁，
            // 所以文本列与按钮之间也是 10（不是「随便留一点」）。
            Spacer(minLength: 10)

            if isEjecting {
                // 别留一个没标签的 spinner：VoiceOver 只会念出「忙」或干脆跳过，
                // 用户听不出「正在推出的是哪块盘」。这里复用与推出按钮同一条带磁盘名的文案。
                ProgressView().controlSize(.mini)
                    .frame(width: 26, height: 26)
                    .accessibilityLabel(DiskRowText.ejectingAccessibilityLabel(disk))
            } else {
                MenuBarEjectButton(state: state, accent: accent, disk: disk, action: onEject)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .background(hovering ? hoverBackground : Color.clear)
        .overlay(alignment: .leading) { busyBar }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(
            DesignTokens.Motion.animation(DesignTokens.Motion.fast, reduceMotion: reduceMotion),
            value: hovering
        )
        // **VoiceOver 第 1 条**：只合并「名称 + 容量 + 结论」，
        // 绝不能把整行 combine —— 那会把推出按钮一起吞掉，结果是「能读不能点」。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(disk.displayName) \(DiskRowText.capacity(disk)) \(DiskRowText.usage(disk))")
    }

    /// 第三行：占用结论。三种状态各自配色，**未知态显示为中性灰而不是绿色**。
    ///
    /// **被占用时列的是「占用程序：Finder、图像捕捉」而不是「2 个程序占用」**：
    /// 设计稿 `.mrow__occ` 写的是进程名。面板是用户「随手推一下」的地方，
    /// 他此刻要决定的是「去关掉哪个应用」——数字回答不了这个问题。
    /// 主窗口的紧凑行（`.crow__status`）才用计数，那里一行要挤下更多信息。
    ///
    /// 拿不到进程名时（未授权 FDA / 沙盒）退回计数文案，
    /// 但**绝不渲染成「没有占用」**（见 ``DiskRowText/occupancy(_:)`` 的约定）。
    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .busy(let processes):
            Text(
                DiskRowText.occupancy(occupancy)
                    ?? (processes.isEmpty
                        ? L10n.tr(.busyEvidenceTitleFallback)
                        : String(format: L10n.tr(.compactBusyFormat), processes.count))
            )
            .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
            .foregroundStyle(DesignTokens.Palette.warningText)
            .designLineHeight(
                DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
            )
            .lineLimit(1)
            .truncationMode(.tail)
        case .writing(let activity):
            // **这里说的就是用户想知道的那件事**：不是「有个我们查不到的进程」，
            // 而是「文件正在往里写，速度多少」。面板只有三行长、宽 360pt，
            // 所以用短句式（不带「可能在拷贝文件」那半句），把速率留在最前面。
            Text(DiskRowText.writingStatus(activity))
                .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.warningText)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                )
                .lineLimit(1)
                .truncationMode(.tail)
        case .safe:
            Text(L10n.tr(.compactSafe))
                .font(.system(size: DesignTokens.FontSize.footnote))
                .foregroundStyle(DesignTokens.Palette.successText)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                )
                .lineLimit(1)
        case .unknown:
            Text(L10n.tr(.unknownEvidenceTitle))
                .font(.system(size: DesignTokens.FontSize.footnote))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                )
                .lineLimit(1)
        }
    }

    private var hoverBackground: Color {
        state.needsAttention ? DesignTokens.Palette.warningSoft : DesignTokens.Palette.subtle
    }

    /// 被占用行的左侧琥珀条（设计稿 `.mrow--busy::before`：**2.5pt**，上下各内缩 7）。
    ///
    /// ⚠️ **2026-09-18 实扫修正**：此前这里引的设计稿类名是 `.crow--busy`（**紧凑行**的
    /// 规格：3pt / 内缩 8），取的值也是 `compactBusyBar*` —— 而 `MenuBarDiskRow` 是
    /// **菜单栏面板行**（只被 `MenuPopoverView` 用，对应 `02-menu-bar.html` 的 `.mrow`）。
    /// 于是琥珀条比设计稿**宽 0.5pt**、内缩多 1pt：
    /// 这正是 ``DesignTokens/Size/menuBusyBarWidth`` 那段注释说「已经修好」的那个症状 ——
    /// 而承载修复的 `menuBusyBar*` 两个令牌当时**零消费者**（注释里的 `✅` 是假的）。
    @ViewBuilder
    private var busyBar: some View {
        if state.needsAttention {
            BusyBar(
                width: DesignTokens.Size.menuBusyBarWidth,
                verticalInset: DesignTokens.Size.menuBusyBarInset)
        }
    }
}

/// 菜单栏行的 26 × 26 图标按钮（设计稿 `.mbtn`）。
///
/// **VoiceOver 第 3 条**：`NSMenuItem.view` 一旦设置，系统不再提供默认可访问性支持，
/// 所以这里的 role 与 label 必须显式给出，装饰性图标要 `accessibilityHidden`。
private struct MenuBarEjectButton: View {
    let state: DiskRowState
    let accent: AccentColor
    let disk: DiskInfo
    let action: () -> Void

    @State private var hovering = false

    private var isBusy: Bool { state.isBusy }

    /// 既是 tooltip 也是可访问性标签 —— **必须带磁盘名**，理由见 ``DiskRowText``。
    private var label: String {
        isBusy
            ? DiskRowText.closeAndEjectAccessibilityLabel(disk)
            : DiskRowText.ejectAccessibilityLabel(disk)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "eject.fill")
                // 设计稿 `.mbtn svg { width: 14px; height: 14px }`（不是 13）。
                .font(.system(size: DesignTokens.Size.menuEjectIconSize, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRing()
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    /// 被占用 = 红底红图标（破坏性可见）；空闲 = 中性图标，hover 时才染强调色。
    private var foreground: Color {
        if isBusy { return hovering ? .white : DesignTokens.Palette.error }
        return hovering ? accent.swiftUIColor : DesignTokens.Palette.mutedForeground
    }

    private var background: Color {
        if isBusy {
            return hovering ? DesignTokens.Palette.error : DesignTokens.Palette.errorSoft
        }
        return hovering ? DesignTokens.Palette.accentSoft(accent) : .clear
    }
}
