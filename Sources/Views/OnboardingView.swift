import AppKit
import SwiftUI

// 本文件是设计稿 `Design/ui/v2/screens/04-onboarding.html`
// **第一块**「引导面板」的 Swift 实现 —— 首次启动、尚未授予完全磁盘访问时，
// 应用唯一一次主动打断用户的界面。
//
// **为什么不能继续用 `NSAlert`**（此前是它）：设计稿这块面板要居中图标容器、
// 三步编号 + 连接线、行内等宽路径小标、信息提示块 —— 这几样 `NSAlert` 一样都给不了，
// 只能自绘。同屏的另外两块（未授权横幅 / 授权成功横幅）已在 ``NoticeBanner`` 落地，
// 本文件补的是整屏里唯一缺失的那一块。

// MARK: - 步骤数据

/// 引导面板里的一步。
///
/// **抽成数据而不是散在视图里**：与 ``MenuPopoverView/actionRows`` 同一个理由 ——
/// 契约测试要能直接读到「面板上到底画了几步、每步画的是什么」。
/// 在测试里手抄一份的话，视图改了而测试没跟上，两边一起错，断言照样绿。
struct OnboardingStep: Equatable {

    /// 步骤的注释（设计稿 `.step__text small`）。
    ///
    /// **三种形态分开表达，而不是统一成「模板字符串」**：设计稿里第 1 步的注释
    /// 整条就是一个小标（设置路径），第 2 步是「文字 + 小标 + 文字」，
    /// 第 3 步是纯文字。硬塞进一种模板的话，第 1 步得写一条值恰好是 `%@`
    /// 的文案键 —— 那对翻译者是纯粹的噪音。
    enum Note: Equatable {
        /// 整条注释就是一个小标。
        case pill(L10n.Key)
        /// 纯文字注释。
        case text(L10n.Key)
        /// 文字里嵌一个小标：`%@` 处替换成 ``pill``。
        case template(L10n.Key, pill: L10n.Key)

        /// 注释里的小标内容键（没有小标时为 `nil`）。供契约测试核对。
        var pillKey: L10n.Key? {
            switch self {
            case .pill(let key): return key
            case .text: return nil
            case .template(_, let pill): return pill
            }
        }
    }

    /// 圆点里的序号（设计稿 `.step__dot` 写的是 `1 / 2 / 3`）。
    let number: Int
    /// 步骤正文。可含 `**粗体**`（设计稿里 `SafeOut` 是 `<b>`）。
    let textKey: L10n.Key
    /// 步骤注释。
    let note: Note
}

extension OnboardingStep {

    /// 面板画的三步 —— **「画了什么」的唯一出处**。
    ///
    /// 序号是写死的 `1/2/3` 而不是用数组下标：设计稿的圆点里就是数字，
    /// 而「第几步」是内容的一部分（用户离开应用去系统设置操作后，
    /// 靠这个编号接上进度）。将来若要插入一步，下标会自动错位而写死的不会 ——
    /// 契约测试会盯着序号必须连续递增。
    static let all: [OnboardingStep] = [
        OnboardingStep(
            number: 1,
            textKey: .fdaOnboardingStep1Text,
            note: .pill(.fdaOnboardingPathSettings)),
        OnboardingStep(
            number: 2,
            textKey: .fdaOnboardingStep2Text,
            note: .template(.fdaOnboardingStep2Note, pill: .fdaOnboardingPathAdd)),
        OnboardingStep(
            number: 3,
            textKey: .fdaOnboardingStep3Text,
            note: .text(.fdaOnboardingStep3Note)),
    ]

    /// 步骤正文**上屏时的样子** —— 应用名已填进 `%@`。
    ///
    /// **为什么把格式化收在这里，而不是让视图在 `Text()` 里现填**：
    /// 格式化的正确性必须**可被测试直接断言**。若视图里写
    /// `MarkdownCopy.text(L10n.tr(step.textKey))` 而忘了套 `String(format:)`，
    /// `%@` 会原样显示给用户，而任何只看**模板**的测试都照样全绿
    /// （模板里确实有 `%@`）—— 这是真实踩过的盲区。
    /// 收敛成一个函数后，视图与测试走**同一个入口**：视图漏格式化 ⇒ 测试必红。
    func renderedText(locale: Locale = .current) -> String {
        String(format: L10n.tr(textKey, locale: locale), L10n.tr(.appName, locale: locale))
    }
}

// MARK: - 视图

/// 三处注入点的**单一出口**：把 `%@` 填成 ``L10n/appName``。
///
/// 为什么不让各视图现填 `String(format:)`：漏填时 `%@` 会**原样上屏**，
/// 而只看模板的测试全绿 —— 真实踩过的盲区。收成函数后视图与测试同源，漏了必红。
enum OnboardingText {

    /// 面板说明段（`fdaOnboardingBody`）。
    static func body(locale: Locale = .current) -> String {
        String(format: L10n.tr(.fdaOnboardingBody, locale: locale), L10n.tr(.appName, locale: locale))
    }

    /// 底部信息提示块（`fdaOnboardingPrivacy`）。
    static func privacy(locale: Locale = .current) -> String {
        String(format: L10n.tr(.fdaOnboardingPrivacy, locale: locale), L10n.tr(.appName, locale: locale))
    }
}

/// 自绘的「完全磁盘访问」引导面板（设计稿 `04-onboarding.html`）。
///
/// 版式全部按设计稿实测规格：宽 380、内容内边距 24/20/20、
/// 图标容器 52×52 圆角 14、标题 17/600 居中、说明 13 行高 1.6 居中、
/// 三步编号列 22 + 间距 12、信息提示块（沿用 ``AlertCallout``）、
/// 按钮组右对齐间距 8。
///
/// **它是「面板」而不是「弹窗」**：设计稿把它画成一块独立的浮层
/// （`.win--popover`，无标题栏），所以宿主用独立窗口呈现，不挡主窗口、也不阻塞运行。
struct OnboardingView: View {

    var accent: AccentColor = .default

    /// 「打开系统设置」—— 宿主负责真正跳转。
    let onOpenSettings: () -> Void
    /// 「稍后」—— 宿主负责关窗。
    let onLater: () -> Void

    /// 面板内容宽 = 面板宽 − 左右内边距（设计稿实测 340）。
    var contentWidth: CGFloat {
        DesignTokens.Size.onboardingPanelWidth - DesignTokens.Spacing.xl * 2
    }

    // 下面四个块（`iconContainer` / `steps` / `callout` / `buttons`）**故意不是 `private`**：
    // `OnboardingLayoutTests` 要逐个量它们的真实渲染尺寸，才能把设计稿的
    // 52 / 135.5 / 54 / 30 钉住。只量面板总高的话，一处偏了会被另一处抵消 ——
    // 实测就有过「图标容器矮 4pt、提示块高 4pt，总高看着完全正常」这种巧合。
    // 与 `SettingsSectionPane` 被单独抽出来是同一个理由。

    var body: some View {
        VStack(spacing: 0) {
            iconContainer
            title
            description
            steps.padding(.top, DesignTokens.Spacing.xl)
            callout.padding(.top, DesignTokens.Spacing.xl)
            buttons.padding(.top, DesignTokens.Spacing.xl)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.xxl)
        .padding(.bottom, DesignTokens.Spacing.xl)
        .frame(width: DesignTokens.Size.onboardingPanelWidth)
        // 面板底色由宿主窗口的毛玻璃提供（与设置面板同款做法）；
        // 这里只负责「内容」，不再叠一层自己的背景 —— 叠了会让毛玻璃失效。
        .accessibilityElement(children: .contain)
    }

    // MARK: 头部（图标容器 + 标题 + 说明）

    /// 顶部图标容器：52 × 52、圆角 14、强调色浅底（设计稿 `.onboard__icon`）。
    var iconContainer: some View {
        Image(systemName: "lock")
            .font(.system(size: DesignTokens.Size.onboardingIconSize, weight: .medium))
            .foregroundStyle(accent.swiftUIColor)
            .frame(
                width: DesignTokens.Size.onboardingIconContainer,
                height: DesignTokens.Size.onboardingIconContainer
            )
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                    .fill(DesignTokens.Palette.accentSoft(accent))
            )
            .padding(.bottom, DesignTokens.Size.onboardingIconBottomGap)
            .accessibilityHidden(true)
    }

    private var title: some View {
        MarkdownCopy.text(L10n.tr(.fdaOnboardingTitle))
            .font(.system(size: DesignTokens.FontSize.heading, weight: .semibold))
            .foregroundStyle(DesignTokens.Palette.foreground)
            .multilineTextAlignment(.center)
            // 设计稿 `.onboard__title { line-height: 1.45 }`（17 → 24.65）。
            .designLineHeight(DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.heading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var description: some View {
        MarkdownCopy.text(OnboardingText.body())
            .font(.system(size: DesignTokens.FontSize.body))
            .foregroundStyle(DesignTokens.Palette.mutedForeground)
            .multilineTextAlignment(.center)
            // 设计稿 `.onboard__desc { line-height: 1.6 }`（13 → 20.8）。
            .designLineHeight(DesignTokens.LineHeight.spacious, fontSize: DesignTokens.FontSize.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DesignTokens.Spacing.sm)
    }

    // MARK: 三步

    /// 三步：编号列（圆点 + 连接线）在左，正文与注释在右。
    ///
    /// **列方向没有间距**（设计稿 `.steps { gap: 0 }`）：步与步之间的视觉间隔
    /// 完全由 `step__text` 的 12pt 下内边距提供 —— 连接线要正好落在
    /// 「上一步圆点下沿」到「下一步圆点上沿」之间，一旦再叠一层 `VStack(spacing:)`
    /// 连接线就会与圆点脱开。
    var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(OnboardingStep.all.enumerated()), id: \.element.number) { index, step in
                stepRow(step, isLast: index == OnboardingStep.all.count - 1)
            }
        }
    }

    private func stepRow(_ step: OnboardingStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Size.onboardingStepGap) {
            rail(number: step.number, isLast: isLast)
            textColumn(step, isLast: isLast)
        }
    }

    /// 编号列：22 宽的竖列，圆点在上，连接线在下（设计稿 `.step__rail`）。
    ///
    /// 圆点与线都居中（`align-items: center`）—— 线宽只有 1.5，
    /// 靠 `VStack` 的居中而不是自己算偏移。
    private func rail(number: Int, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Text("\(number)")
                .font(.system(size: DesignTokens.FontSize.footnote, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: DesignTokens.Size.onboardingStepDot,
                    height: DesignTokens.Size.onboardingStepDot
                )
                .background(Circle().fill(accent.swiftUIColor))
            if !isLast {
                Rectangle()
                    .fill(DesignTokens.Palette.borderStrong)
                    .frame(
                        width: DesignTokens.Size.onboardingStepLineWidth,
                        height: DesignTokens.Size.onboardingStepLineHeight
                    )
                    .padding(.vertical, DesignTokens.Size.onboardingStepLineMargin)
            }
        }
        .frame(width: DesignTokens.Size.onboardingStepRailWidth)
        .accessibilityHidden(true)
    }

    private func textColumn(_ step: OnboardingStep, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // ⚠️ 步骤正文里的应用名走 ``OnboardingStep/renderedText(locale:)`` 注入，
            // **不是硬编码、也不在这里现填 `%@`**。为什么：FDA 引导的落点是
            // 「让用户去系统设置列表里找到本应用」，而那份列表显示的是**本地化后的名字**
            // （中文环境 = 中文名）。文案写死一个名字 ⇒ 中英文各写一遍 ⇒ 改名必漏，
            // 且漏了用户按文案找会**找不到那一行开关**（该缺陷真实发生过）。
            MarkdownCopy.text(step.renderedText())
                .font(.system(size: DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.Palette.foreground)
                // 设计稿 `.step__text { line-height: 1.5 }`（12 → 18）。
                .designLineHeight(DesignTokens.LineHeight.relaxed, fontSize: DesignTokens.FontSize.caption)
                .fixedSize(horizontal: false, vertical: true)

            noteView(step.note)
                .padding(.top, DesignTokens.Size.onboardingNoteTopGap)
        }
        // 最后一步的正文没有下内边距（设计稿给它加了行内 `padding-bottom:0`）。
        .padding(.bottom, isLast ? 0 : DesignTokens.Size.onboardingStepTextPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 步骤注释里的一段。
    ///
    /// **为什么不直接 `ForEach(Array(pieces.enumerated()), id: \.offset)`**：
    /// 那样得在 `ViewBuilder` 里写 `let` 与两处下标判断，读起来像在拼字符串。
    /// 先切好再交给视图，视图里就只剩「画文字还是画小标」一件事。
    struct NotePiece: Identifiable, Equatable {
        let id: Int
        let text: String
        /// `true` = 画成 ``PathPill``，`false` = 普通注释文字。
        let isPill: Bool
    }

    /// 把注释模板按 `%@` 切成「文字 · 小标 · 文字」。
    ///
    /// 切出来的文字段可能为空（模板以 `%@` 开头或结尾），空段直接丢掉 ——
    /// 留着会在行首/行尾多出半个间距，小标就不再贴着边。
    static func notePieces(of template: String, pill: String) -> [NotePiece] {
        let segments = template.components(separatedBy: "%@")
        var result: [NotePiece] = []
        for (index, segment) in segments.enumerated() {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(NotePiece(id: result.count, text: trimmed, isPill: false))
            }
            // 每两个文字段之间正好有一个 `%@` 占位。
            if index < segments.count - 1 {
                result.append(NotePiece(id: result.count, text: pill, isPill: true))
            }
        }
        return result
    }

    /// 步骤注释。纯文字 / 整条小标 / 文字里嵌小标，三种形态在这里汇合。
    ///
    /// 用 ``WrappingHStack`` 而不是 `HStack`：小标是一个**独立视图**（要带底色），
    /// 而注释在英文下会超出一行 —— `HStack` 不换行，超出的部分会被裁掉。
    @ViewBuilder
    private func noteView(_ note: OnboardingStep.Note) -> some View {
        switch note {
        case .pill(let key):
            WrappingHStack(spacing: DesignTokens.Spacing.xs) {
                PathPill(text: L10n.tr(key))
            }
            .accessibilityElement(children: .combine)
        case .text(let key):
            noteText(L10n.tr(key))
        case .template(let key, let pill):
            WrappingHStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Self.notePieces(of: L10n.tr(key), pill: L10n.tr(pill))) { piece in
                    if piece.isPill {
                        PathPill(text: piece.text)
                    } else {
                        noteText(piece.text)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DesignTokens.FontSize.footnote))
            .foregroundStyle(DesignTokens.Palette.mutedForeground)
            // 设计稿 `.step__text small` 继承 `.step__text` 的 `line-height: 1.5`
            // （11 → 16.5）。
            .designLineHeight(DesignTokens.LineHeight.relaxed, fontSize: DesignTokens.FontSize.footnote)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 提示块与按钮

    /// 隐私说明（设计稿 `.callout--info`）。
    ///
    /// 复用 ``AlertCallout``：块高 54、内边距 9/11、圆角 6、0.5px 强调色内描边，
    /// 与设计稿逐项一致。
    ///
    /// 图标是 **`checkmark.shield`** 而不是 `shield`：设计稿的 `shield`
    /// （`ds.js` 的图标表）是**盾牌 + 一个勾**两条路径 —— 「只读取、不打开」
    /// 这层意思由那个勾承担。裸盾牌只是个盾，读不出「已经确认过是安全的」。
    var callout: some View {
        AlertCallout(
            kind: .info,
            systemImage: "checkmark.shield",
            text: OnboardingText.privacy(),
            accent: accent
        )
    }

    var buttons: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ActionButton(
                title: L10n.tr(.notNow),
                variant: .outline,
                size: .medium,
                accent: accent,
                keyboardShortcut: .cancelAction,
                action: onLater
            )
            ActionButton(
                title: L10n.tr(.openSystemSettings),
                variant: .primary,
                size: .medium,
                accent: accent,
                keyboardShortcut: .defaultAction,
                action: onOpenSettings
            )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - 行内路径小标

/// 行内「路径」小标（设计稿 `.path`）：等宽 11、内边距 1/5、圆角 4、静默底。
///
/// **为什么必须是独立视图**：SwiftUI 的 `Text` 只能对整段统一上底色，
/// 而设计稿这里是**一句话中间的一个小标**（第 2 步：「若不在列表中，
/// 点左下角 `＋` 从『应用程序』添加」）。要保住小标，就得把这一行拆成
/// 「文字 · 小标 · 文字」三个视图 —— 代价是换行要自己管，见 ``WrappingHStack``。
struct PathPill: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: DesignTokens.FontSize.footnote, design: .monospaced))
            .foregroundStyle(DesignTokens.Palette.foreground)
            .padding(.horizontal, DesignTokens.Size.onboardingPathPaddingH)
            .padding(.vertical, DesignTokens.Size.onboardingPathPaddingV)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Size.onboardingPathRadius, style: .continuous)
                    .fill(DesignTokens.Palette.subtle)
            )
            .fixedSize()
    }
}

// MARK: - 换行容器

/// 从左到右排布、一行放不下就换行的容器。
///
/// **为什么需要它**：设计稿里「文字 + 行内小标 + 文字」是一句话，
/// 换行由 CSS 的行内流自动完成。SwiftUI 里这句话被拆成了三个视图，
/// `HStack` 不会换行（英文下这条注释比中文长一倍，会被直接裁掉），
/// 而 `ViewThatFits` 只能「整体换一种排法」，做不到逐段折行。
///
/// 放在本文件而不是 ``DesignSystemComponents``：目前只有引导面板的步骤注释用它。
/// 出现第二个调用方时再挪进组件库 —— 那时它的行为才真的需要被多方约束。
struct WrappingHStack: Layout {

    /// 同一行内相邻两段之间的间距。
    var spacing: CGFloat = DesignTokens.Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                widest = max(widest, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, lineWidth)
        totalHeight += lineHeight

        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > bounds.width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            if x > 0 { x += spacing }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
