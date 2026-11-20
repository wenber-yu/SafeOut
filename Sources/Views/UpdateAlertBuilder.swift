import Foundation

/// 把 ``PendingUpdate`` 翻译成弹窗模型（设计稿 `08-update.html` A 段）。
///
/// **为什么复用 ``EjectAlertModel`` / ``EjectAlertView``**：更新弹窗与推出弹窗的
/// **结构完全一致** —— 图标 → 标题 + 说明 → 区块 → 提示块 → 操作区（左小标 + 右按钮）。
/// 差异只在数据（图标是信息态、区块是更新条目、按钮组合不同），
/// 与当初「A / B 两个推出弹窗共用同一个视图」是同一条理由，没有理由再写一遍。
///
/// 单独成文件（而不是塞进 `EjectAlertView.swift`）是因为它依赖 `L10n` 与 ``PendingUpdate``，
/// 而那两样属于更新这条线 —— 放在一起会让「弹窗长什么样」和「更新怎么翻译」互相污染。
@MainActor
enum UpdateAlertBuilder {

    /// 组装「有新版本」弹窗。
    ///
    /// 三处**不能省**的东西（设计稿 D 段「文案原则」逐条对应）：
    ///
    /// - **标题带版本号**，不写「发现新版本」：用户要判断的是「值不值得为它重启一次」。
    /// - **首屏给全四样**：版本号、当前版本、体积、日期。所以说明行是**两行**
    ///   （`当前 x（构建 n）→ y（构建 m）` ＋ `日期 · 体积`）。
    /// - **说清代价与不代价**：提示块那句「正在推出的磁盘不会被打断」是必需的 ——
    ///   用户按下更新前最怕的就是「会不会把我正在拷的东西弄坏」。
    static func model(for update: PendingUpdate) -> EjectAlertModel {
        EjectAlertModel(
            // 信息态图标（`--accent-soft`），**不是警告态** —— 见 `IconKind.info` 的说明。
            icon: .info("arrow.down.circle"),
            title: String(
                format: L10n.tr(.updateAlertTitleFormat), L10n.tr(.appName), update.version),
            subtitle: subtitle(for: update),
            // 更新条目复用 `.causes` 的版式：设计稿 `.changelog` 与「可能的原因」
            // 都是「`·` 独立成列 + 行高 1.55 + 条目间距 6」，逐项对上。
            section: update.notes.isEmpty
                ? nil
                : .causes(label: L10n.tr(.updateWhatsNew), items: update.notes),
            callout: EjectAlertModel.Callout(
                kind: .info,
                systemImage: "info.circle",
                text: L10n.tr(.updateCallout)),
            showSpotlightPrivacyButton: false,
            // 操作区左边那个**不占按钮**的出口。没有它，用户只能在
            // 「永久跳过这个版本」和「现在就重启」之间二选一 ——
            // 而多数人真正想说的是「现在不方便」。
            footNote: L10n.tr(.updateEscHint),
            actions: [
                EjectAlertModel.Action(
                    title: L10n.tr(.updateSkipVersion), variant: .outline, choice: .skipVersion,
                    isDefault: false, isCancel: false),
                EjectAlertModel.Action(
                    title: L10n.tr(.updateInstallAndRestart), variant: .primary,
                    choice: .installAndRestart,
                    // 回车 = 主按钮（设计稿：「后台更新并重启」是默认按钮）。
                    // ⚠️ **Esc 不给任何按钮**：Esc 的语义是「稍后」，由窗口的
                    // `cancelOperation` 兜底（`EjectAlertPresenter` 把它映射成 `.cancel`）。
                    // 若把 Esc 挂到「跳过此版本」上，用户会以为 Esc = 永久跳过。
                    isDefault: true, isCancel: false),
            ])
    }

    /// 说明行的两行文本。
    ///
    /// 构建号缺失时降级成不带构建号的写法，而不是显示「构建 」——
    /// **不知道就不写**（同 `AppVersionInfo` 的口径：读不到返回 `nil`，不自己编值）。
    private static func subtitle(for update: PendingUpdate) -> String {
        var lines: [String] = []

        if let newBuild = update.newBuild, let currentBuild = update.currentBuild {
            lines.append(
                String(
                    format: L10n.tr(.updateAlertVersionsFormat),
                    update.currentVersion, currentBuild, update.version, newBuild))
        } else {
            lines.append(
                String(
                    format: L10n.tr(.updateAlertVersionsPlainFormat),
                    update.currentVersion, update.version))
        }

        // 日期与体积：**两者都可能没有**（appcast 没写日期、enclosure 没写 length），
        // 所以拼之前各自判空 —— 否则会出现「 · 12.4 MB」这种以分隔符开头的行。
        var meta: [String] = []
        if let date = update.date, !date.isEmpty { meta.append(date) }
        if update.sizeBytes > 0 { meta.append(formattedSize(update.sizeBytes)) }
        if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }

        return lines.joined(separator: "\n")
    }

    /// 安装包体积（设计稿写的是「12.4 MB」）。
    ///
    /// `ByteCountFormatter` 跟随 `Locale.current` —— 所以**测试不许断言这个字符串**
    /// （断言它 = 断言开发机的语言，换台机器必红，而红的原因与被测代码无关）。
    /// 可断言的部分是「有体积 / 没体积」这一层，由 ``subtitle(for:)`` 的分支决定。
    private static func formattedSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
