import AppKit
import SwiftUI

// 本文件是设计稿 `Design/ui/v2/screens/03-eject-flow.html` 里
// A（被占用确认）/ B（推出失败）两个弹窗的 Swift 实现。两个变体**共用同一个视图** ——
// 它们的结构完全一致（图标 → 标题+说明 → 区块 → 提示块 → 操作区），
// 差异只在数据（图标色调、区块是进程还是原因、按钮组合），所以没有理由写两遍。

/// 用户在推出弹窗上的选择。
///
/// **为什么不让视图直接回调业务动作**：视图只负责「用户点了哪个按钮」，
/// 「点了之后该干什么」（终止进程并重试 / 打开日志）留在 ``EjectUI``。
/// 这样弹窗可以被离屏渲染、被测试驱动，而不会顺手触发真实的进程终止。
enum EjectAlertChoice: Equatable {
    /// 「取消」—— 放弃推出；在更新弹窗里表示 **Esc / 关窗 = 稍后**。
    case cancel
    /// 「关闭并推出」—— 确认终止占用进程并重试。
    case closeAndEject
    /// 「好」—— 失败弹窗的确认（仅关闭）。
    case dismiss
    /// 「查看日志」—— 在访达中显示错误日志。
    case viewLog
    /// 「跳过此版本」—— 只跳这一个版本，下个版本照常提醒。
    case skipVersion
    /// 「后台更新并重启」—— 后台下载，重启时安装。
    case installAndRestart
}

/// 推出弹窗的内容模型（**纯数据，不依赖 SwiftUI / AppKit**）。
///
/// **为什么要把文案与结构抽成模型**：弹窗是自绘的（设计稿要求图标在左、标题左对齐、
/// 提示块、下沉操作区 —— `NSAlert` 一样都给不了），而自绘视图里的文案没法像
/// `NSAlert.messageText` 那样直接断言。抽成模型后，
/// 「标题带不带盘名」「有没有可能的原因清单」「按钮是『好』还是『确定』」
/// 这些契约都能在**不渲染、不驱动窗口**的前提下被测试钉住。
struct EjectAlertModel: Equatable {

    /// 左上角图标容器的语义色调（设计稿 `.alert__icon--warn` / `--danger` / `--info`）。
    enum IconKind: Equatable {
        /// 琥珀 —— 被占用。
        case warning
        /// 红 —— 失败。
        case danger
        /// 强调色 + 自选图标 —— **信息态**（更新弹窗用）。
        ///
        /// **不是 `warning`**：设计稿 §2.1 把琥珀与红定成专义色
        /// （琥珀只用于「受阻，且需用户介入才能恢复」、红只表示「破坏性动作」），
        /// 「有新版本可用」三条判据一条都不满足 —— 借一个已经承担了别的含义的颜色，
        /// 比没有颜色更糟（用户会以为磁盘出了问题）。
        case info(String)
    }

    /// 提示 / 警示块（设计稿 `.callout`）。
    struct Callout: Equatable {
        enum Kind: Equatable {
            /// 红底红字。
            case danger
            /// 强调色底、正文色字。
            case info
        }

        let kind: Kind
        /// SF Symbol 名（设计稿内联 SVG 的对应物）。
        let systemImage: String
        let text: String
    }

    /// 中段区块（设计稿 `.alert__section`）：要么是占用进程清单，要么是原因清单。
    enum Section: Equatable {
        case processes(label: String, items: [OccupyingProcess])
        case causes(label: String, items: [String])
    }

    /// 底部按钮。
    struct Action: Equatable {
        let title: String
        let variant: ButtonVariant
        let choice: EjectAlertChoice
        /// 回车触发的默认按钮（设计稿：「关闭并推出」/「好」）。
        let isDefault: Bool
        /// Esc 触发的取消按钮（设计稿：「取消」）。
        let isCancel: Bool
    }

    let icon: IconKind
    let title: String
    let subtitle: String
    let section: Section?
    let callout: Callout?
    /// 操作区左侧小标（设计稿 `.alert__foot-note`，只有 A 变体有）。
    let footNote: String?
    let actions: [Action]
}

// MARK: - 两个变体的构造

extension EjectAlertModel {

    /// A · 被占用时的确认（设计稿 `03-eject-flow.html` A 变体）。
    ///
    /// 破坏性按钮标红、默认按钮是「关闭并推出」、操作区带「此操作不可撤销」小标。
    @MainActor
    static func busy(disk: DiskInfo, occupying: [OccupyingProcess]) -> EjectAlertModel {
        EjectAlertModel(
            icon: .warning,
            // 标题带磁盘名（设计稿文案原则：「多块盘时，用户必须确认操作对象没选错」）。
            title: String(format: L10n.tr(.ejectBusyTitle), disk.displayName),
            subtitle: EjectFlowController.shared.busyMessage(disk: disk, occupying: occupying),
            section: occupying.isEmpty
                ? nil
                : .processes(
                    label: String(format: L10n.tr(.ejectBusyOccupiedHeaderFormat), occupying.count),
                    items: occupying),
            callout: Callout(
                kind: .danger,
                systemImage: "exclamationmark.triangle",
                text: EjectUI.busyWarningText),
            footNote: L10n.tr(.ejectBusyIrreversibleCaption),
            actions: [
                Action(
                    title: L10n.tr(.cancel), variant: .outline, choice: .cancel,
                    isDefault: false, isCancel: true),
                Action(
                    title: L10n.tr(.closeAndEject), variant: .danger, choice: .closeAndEject,
                    isDefault: true, isCancel: false),
            ])
    }

    /// B · 推出失败（设计稿 `03-eject-flow.html` B 变体）。
    ///
    /// 失败要留痕：提示块告诉用户「记了什么、去哪看」。
    /// 那句话由 ``EjectFlowController/record(_:disk:)`` 兑现 —— 它在返回 `.failed`
    /// 之前已经把这条失败写进了 `error.log`。文案与接线是一对，缺一个就是骗用户。
    @MainActor
    static func failure(disk: DiskInfo, failure: EjectFailure) -> EjectAlertModel {
        let causes = failure.possibleCauses
        return EjectAlertModel(
            icon: .danger,
            title: String(format: L10n.tr(.ejectFailedTitleFormat), disk.displayName),
            subtitle: EjectFlowController.shared.failureMessage(disk: disk, failure: failure),
            section: causes.isEmpty
                ? nil
                : .causes(label: L10n.tr(.ejectFailedCausesTitle), items: causes),
            callout: Callout(
                kind: .info,
                systemImage: "doc",
                text: L10n.tr(.ejectFailedLoggedHint)),
            footNote: nil,
            actions: [
                Action(
                    title: L10n.tr(.viewLog), variant: .outline, choice: .viewLog,
                    isDefault: false, isCancel: false),
                Action(
                    title: L10n.tr(.okAcknowledge), variant: .primary, choice: .dismiss,
                    isDefault: true, isCancel: false),
            ])
    }
}

// MARK: - 视图

/// 自绘推出弹窗（设计稿 `03-eject-flow.html` 的 A / B 两个变体共用）。
///
/// 版式完全按设计稿的实测规格：宽 400、圆角 14、内容内边距 20/20/16、
/// 图标 38×38 圆角 10 在左、标题 15/600 左对齐、区块上边距 16、
/// 提示块上边距 12、操作区下沉 54（按钮 30 + 上下 12）。
struct EjectAlertView: View {
    let model: EjectAlertModel
    var accent: AccentColor = .default
    let onAction: (EjectAlertChoice) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            content
            foot
        }
        .frame(width: DesignTokens.Size.alertWidth)
        .background(
            ZStack {
                VisualEffectBackground()
                DesignTokens.Palette.popoverBackground(for: colorScheme)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(DesignTokens.Palette.borderStrong, lineWidth: 0.5)
        )
    }

    // MARK: 内容区（设计稿 `.alert__body { padding: 20px 20px 16px }`）

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if let section = model.section {
                sectionView(section).padding(.top, DesignTokens.Spacing.lg)
            }
            if let callout = model.callout {
                AlertCallout(
                    kind: callout.kind == .danger ? .danger : .info,
                    systemImage: callout.systemImage,
                    text: callout.text,
                    accent: accent
                )
                .padding(.top, DesignTokens.Spacing.md)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.lg)
    }

    /// 头部：图标在左，标题与说明左对齐在右（设计稿 `.alert__head { gap: 12px }`）。
    private var head: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            AlertIcon(kind: iconKind, accent: accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: DesignTokens.FontSize.title, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                    // 设计稿 `.alert__title { line-height: 1.3 }` → 15pt 字号行高 19.5。
                    .designLineHeight(
                        DesignTokens.LineHeight.tight, fontSize: DesignTokens.FontSize.title
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.subtitle)
                    .font(.system(size: DesignTokens.FontSize.caption))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    // 设计稿 `.alert__sub { line-height: 1.5 }` → 12pt 字号行高 18。
                    .designLineHeight(
                        DesignTokens.LineHeight.relaxed, fontSize: DesignTokens.FontSize.caption
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 允许标题/说明换行而不是把图标挤扁（设计稿 `style="min-width:0"`）。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var iconKind: AlertIcon.Kind {
        switch model.icon {
        case .warning: return .warning
        case .danger: return .danger
        case .info(let symbol): return .accent(symbol)
        }
    }

    // MARK: 区块

    @ViewBuilder
    private func sectionView(_ section: EjectAlertModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch section {
            case .processes(let label, let items):
                labelView(label)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, process in
                        processRow(process, striped: index.isMultiple(of: 2))
                    }
                }
            case .causes(let label, let items):
                labelView(label)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.self) { cause in
                        causeRow(cause)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分组标签（设计稿 `.alert__label`：11/600、字距 0.04em、行高随正文 1.45）。
    private func labelView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DesignTokens.FontSize.groupTitle, weight: .semibold))
            .tracking(DesignTokens.FontSize.groupTitle * 0.04)
            .foregroundStyle(DesignTokens.Palette.textStrong)
            // 设计稿没给 `.alert__label` 单独的行高，它继承 `body` 的 1.45 → 11pt 行高 15.95。
            .designLineHeight(
                DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.groupTitle)
    }

    /// 占用进程行（设计稿 `.alert__item`：高 29、圆角 6、奇数行带下沉底色）。
    ///
    /// **奇数行底色不是装饰**：多进程时它把每行从「一串连续的图标+名字」切成可数的条目，
    /// 用户要确认的是「一共几个、都是谁」。
    private func processRow(_ process: OccupyingProcess, striped: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            processIcon(process)
            // 展示应用显示名（`Bunny`），不是进程可执行名（`IMVIDEO`）。
            Text(process.displayName)
                .font(.system(size: DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 磁盘映像没有 pid——它的「pid」是合成负值（仅作 Identifiable 身份），
            // 显示「PID -1073…」是彻头彻尾的噪音；标明种类才是对用户有用的信息。
            Text(kindLabel(for: process))
                .font(.system(size: DesignTokens.FontSize.footnote).monospacedDigit())
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .layoutPriority(1)
        }
        .padding(.horizontal, 6)
        .frame(height: DesignTokens.Size.alertProcessRowHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(striped ? DesignTokens.Palette.sunken : .clear)
        )
    }

    /// 行尾标识：真进程显示 PID，磁盘映像显示「磁盘映像」。
    private func kindLabel(for process: OccupyingProcess) -> String {
        switch process.kind {
        case .process:
            return String(format: L10n.tr(.processPidFormat), process.pid)
        case .diskImage:
            return L10n.tr(.diskImageKindLabel)
        }
    }

    /// 进程所属应用的图标；解析不到时回落为通用应用图标。
    ///
    /// 图标必须从**解析出的 app bundle 路径**取，不能拿进程名去猜 ——
    /// `/Applications/IMVIDEO.app` 的可执行名与 bundle 名都叫 `IMVIDEO`，
    /// 但用户认识的是它的本地化显示名 `Bunny`（见 ``ProcessAppResolver``）。
    private func processIcon(_ process: OccupyingProcess) -> some View {
        let image = ProcessAppResolver.icon(for: process) ?? NSWorkspace.shared.icon(for: .application)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(
                width: DesignTokens.Size.alertProcessIcon,
                height: DesignTokens.Size.alertProcessIcon
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous))
    }

    /// 原因行（设计稿用 `display:flex; gap:8px` 把「·」与文字分成两列）。
    ///
    /// **项目符号必须独立成列**：把「· 」拼进同一个 Text，换行后的第二行会缩进到
    /// 符号下方，看起来像另一个条目；分列后第二行与第一行文字左对齐。
    ///
    /// **行高必须是 1.55**：设计稿这一块是行内 `line-height:1.55`（12pt → 18.6），
    /// 而弹窗别处是 1.5。第一条原因会折成两行，这一条之差就是 3.6pt。
    private func causeRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text("·")
                .font(.system(size: DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .designLineHeight(
                    DesignTokens.LineHeight.loose, fontSize: DesignTokens.FontSize.caption)
            Text(text)
                .font(.system(size: DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .designLineHeight(
                    DesignTokens.LineHeight.loose, fontSize: DesignTokens.FontSize.caption
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 操作区（设计稿 `.alert__foot`：下沉底 + 发丝线 + 右对齐按钮）

    private var foot: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let footNote = model.footNote {
                Text(footNote)
                    .font(.system(size: DesignTokens.FontSize.footnote))
                    .foregroundStyle(DesignTokens.Palette.textDecorative)
                Spacer(minLength: DesignTokens.Spacing.md)
            } else {
                Spacer(minLength: 0)
            }
            ForEach(model.actions, id: \.title) { action in
                ActionButton(
                    title: action.title,
                    variant: action.variant,
                    size: .medium,
                    accent: accent,
                    keyboardShortcut: shortcut(for: action),
                    action: { onAction(action.choice) }
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.sunken)
        .overlay(alignment: .top) { Hairline() }
    }

    /// 默认按钮接回车、取消按钮接 Esc（设计稿：「默认按钮是『关闭并推出』（回车即触发），
    /// 『取消』保留为逃生口」）。
    private func shortcut(for action: EjectAlertModel.Action) -> KeyboardShortcut? {
        if action.isDefault { return .defaultAction }
        if action.isCancel { return .cancelAction }
        return nil
    }
}
