import AppKit
import Foundation
import OSLog
import Sparkle

// 本文件是设计稿 `Design/ui/v2/screens/08-update.html` 的实现侧另一半：
// 把 Sparkle 的回调翻译成 ``UpdateController`` 的状态，并在该弹窗的时候弹窗。
//
// **为什么必须自己实现 driver**：见 `UpdateController` 的类注释（下载进度只在 driver 里给）。

/// 把 Sparkle 的更新回调接到 ``UpdateController`` 的状态机上。
///
/// ## 弹窗什么时候弹（这是本页最容易做错的一条）
///
/// 设计稿 A 段的开场白写死了判据：
/// 「弹窗**只在自动更新关掉时才会出现** —— 开着的时候用户什么都不用做，
/// 这正是『后台更新』这个词的含义。」
///
/// 于是 ``showUpdateFound(with:state:reply:)`` 里**不看 `state.userInitiated`**，
/// 只看 `automaticallyDownloadsUpdates`：开关开着就静默下载（设置行显示进度），
/// 关着就弹窗。用户主动点「检查更新」时，反馈由设置行给（「正在后台下载 1.1.0」或
/// 「发现 1.1.0」），不是靠弹窗 —— 否则开关开着也会弹，与设计稿自相矛盾。
///
/// ## ⚠️ 上面那句「开关开着就静默下载（设置行显示进度）」的适用范围（2026-09-19 补）
///
/// 那个组合**只可能出现在用户手动点「检查更新」时**。定时 / 后台那条在开关开着时
/// 走的是 `SPUAutomaticUpdateDriver`，而它**根本不调 `showUpdateFound`**
/// （`SPUUIBasedUpdateDriver.m` 是这四个回调的唯一调用方），所以**连这个方法都不会进**：
/// 应用侧在那条路上收不到任何回调，进度自然也**无从得知**。
///
/// 自动那条路的落点是 delegate 的 `willInstallUpdateOnQuit` —— 它一到达就已经是
/// 「下载完成、等退出时装」，中间那段**没有界面**。完整推导见 `DESIGN-SPEC.md` §8.80。
///
/// ## 关于线程隔离
///
/// `SPUUserDriver` 是 ObjC 协议，方法没有 `@MainActor` 标注，而 Sparkle 保证
/// 这些方法都在主线程回调。实测（2026-09-18，Swift 6.3）：给这个类标 `@MainActor`
/// 就**直接编译通过**，不需要 `@preconcurrency`（加上反而会报
/// 「`@preconcurrency` on conformance has no effect」—— 那是个警告，
/// 而本仓库的门槛 1 带 `-warnings-as-errors`，留着就是红）。
///
/// 也**不用**给每个方法加 `MainActor.assumeIsolated`：那会在真出问题时
/// （真的从别的线程回调）静默走进未定义行为，不如让类型系统兜着。
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {

    private static let logger = Logger(subsystem: "com.safeout.app", category: "Update")

    private weak var controller: UpdateController?

    /// 下载总长 / 已收长度（`showDownloadDidReceiveData` 只给增量）。
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    init(controller: UpdateController) {
        self.controller = controller
        super.init()
    }

    // MARK: - 权限询问

    /// 是否允许自动检查更新。
    ///
    /// **正常不会被调用**：`Info.plist` 里已经写明 `SUEnableAutomaticChecks = YES`
    /// （见 `build_app.sh`），Sparkle 只在那个键缺失时才问。
    ///
    /// 但仍然要给出答案：不回答的话整个更新流程会停在这里等一个永远不来的点击 ——
    /// 而界面上什么都看不到（本应用没有「首次启动询问更新偏好」这一步）。
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - 检查

    /// 用户主动检查开始。
    ///
    /// ⚠️ **这里不设 `phase`** —— 中间态由 ``UpdateController/checkForUpdates()`` 负责：
    /// 它是在**调用 Sparkle 之前**就设好的，比这个回调更早也更可靠
    /// （`ensureUpdater()` 起不来时它已经 `return` 了，不会留下一个永远转的态）。
    ///
    /// ## 曾经故意不画「正在检查…」，2026-09-20 改掉了
    ///
    /// 原注释的理由是「这一段通常只有**几百毫秒**，画一个会闪一下的中间态比不画更吵」。
    /// **真机实测把这个前提推翻了**（dist 产物，单时间轴量 4 轮）：
    /// **4.31s / 3.15s / 4.51s / 0.17s**（末轮是偶发快路径），典型 **3~4.5 秒**。
    /// 按下后连抓 AX 树 0.5~4.0s，更新区**零变化**：按钮仍是「检查更新」且仍 `enabled`
    /// ⇒ 用户在这几秒里能反复点，也不知道自己那一下有没有生效。
    /// **3~4.5 秒不是「闪一下」。**
    ///
    /// ⇒ 已按 §8.93 的实测结论补上 `.checking`（设置行显示「正在检查更新…」且**不给按钮**）。
    ///
    /// - Note: `cancellation` 仍然**被丢弃** —— 它是 Sparkle 给的「取消这次检查」。
    ///   要给它落点就得再补一个「取消」按钮，而这一段本来只有几秒、
    ///   给取消反而增加噪声。真要做的话，这一格就是落点。
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Self.logger.debug("用户主动检查更新")
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard let controller else {
            reply(.dismiss)
            return
        }

        // **只读更新**（appcast 里带 `sparkle:informational`）：没有包可下，只能把人送到网页。
        // 这条必须显式处理 —— 否则会对一个没有 enclosure 的条目走「后台下载」，
        // 然后永远停在 0%。
        if appcastItem.isInformationOnlyUpdate {
            if let url = appcastItem.infoURL { NSWorkspace.shared.open(url) }
            reply(.dismiss)
            return
        }

        // **翻译只有一处**（`PendingUpdate.init(appcastItem:)`）：同一个条目也会从
        // 自动那条路的 delegate 回调送进来，两处各写一遍会静默分叉。
        let update = PendingUpdate(appcastItem: appcastItem)

        let shouldPresent = controller.driverDidFindUpdate(
            update,
            autoDownloads: controller.automaticallyDownloadsUpdates,
            reply: reply)

        if shouldPresent {
            Task { await controller.showUpdateAlertIfNeeded() }
        } else {
            // 后台路径：直接开始下载，不弹窗（这就是「自动更新」开着时的样子）。
            reply(.install)
        }
    }

    /// appcast 里**外链**的 release notes（`<sparkle:releaseNotesLink>`）。
    ///
    /// 本应用的「本次更新」清单取自 appcast **内嵌**的 `<description>`
    /// （`SUAppcastItem.itemDescription`），所以这条不会被调用。
    /// 留空实现而不是把 HTML 塞进弹窗 —— 塞进去就要在自绘弹窗里渲染任意 HTML。
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    /// Sparkle 明确回了「**没有可用更新**」（`SUNoUpdateError`）。
    ///
    /// ⚠️ **这是唯一能说「已是最新版本」的入口**（2026-09-28 用户报告）：
    /// 它与下面的 ``showUpdaterError(_:acknowledgement:)`` 是**两件相反的事**，
    /// 而两条原先都被丢进 `driverDidReset()` ⇒ 设置行把「根本没查成」也写成
    /// 「上次检查：… · 已是最新版本」。判据与后果见 ``UpdateController/CheckOutcome``。
    ///
    /// ⚠️ 只有 `SUNoUpdateError` 会到这儿（`SPUUIBasedUpdateDriver.m:464` 判了码），
    /// 所以**不需要**再在这里判一次错误码 —— 加了就是一条永远为真的分支。
    ///
    /// ⚠️ **2026-09-28 起本方法不再写结论**：`didFinishUpdateCycle`（delegate，
    /// 逐轮必到）是 ``UpdateController/lastCheckOutcome`` 的唯一来源 ——
    /// 「**没有新版本**」这个结论会由它按 `SUNoUpdateError` 落成 `.succeeded`。
    /// 这里写第二遍的话，就又出现了「两条路各写一份」的老病
    /// （而其中一条——后台检查——**根本不发**这条回调）。
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.driverDidReset()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // 更新流程出错。**分五种，落点不同**（五种按下面的顺序判，命中即停）：
        //
        // - **位置不允许更新**（只读卷 / App Translocation，错误码 `1003` / `1005`）
        //   → `.locationBlocked`。**这一支必须排在最前**：只读卷上 Sparkle 连 appcast
        //   都不会去取（`SPUBasicUpdateDriver.m:71` 判 `statfs` 的 `MNT_RDONLY` 直接 abort），
        //   `phase` 停在 `.idle`，于是走 `driverDidReset()` 会让界面回到「已是最新版本」——
        //   而 `SPUUpdater.m:789` 早就把「上次检查时间」写成了当下（不看成败）。
        //   结果就是**根本没检查却说检查过了**（§8.94 实测：零网络请求）。
        // - **已经落在终态**（`.failed` / `.locationBlocked`）→ **不动**，只记日志。
        //   **这一支必须排第二**（2026-09-22 真机实测，§8.121）：下载失败时 Sparkle 两条回调
        //   **相差 1ms 都到**，delegate 先到设好 `.failed`，本方法后到 —— 它若照旧往
        //   `driverDidReset()` 掉，就把前一条的结果**冲回 `.idle`**，界面无声回到
        //   「已是最新版本」。判据见 ``UpdateController/isTerminalPhase(_:)``。
        //   ⚠️ 它排在「位置受限」**之后**是有意的：位置受限是一个**按错误码就能定**的
        //   落点，与当前 `phase` 无关，不该被「已经在终态」挡住。
        //   ⚠️ **这一支护不住 30ms 后那一下**：末尾的 `acknowledgement()` 会让 Sparkle
        //   接着调 `dismissUpdateInstallation()`，那一支也得装同一个闸门（见它自己的注释）。
        //   ⚠️ 终态现在是**三个**：`.failed` / `.installFailed` / `.locationBlocked`。
        // - **下载成功之后那一步失败**（解压 / 验签 / 安装，码 3000 / 4000 段）
        //   → `.installFailed`（2026-09-22 新增，账本第 43 行）。
        //   **这一支必须排在「下载失败」之前**：两者都发生在 `phase == .downloading` 期间
        //   （下载完成到安装完成之间 `phase` 还是 `.downloading(version: 1)`），
        //   只能靠**错误码**区分。不分开的话界面会写「网络不可用」——
        //   而下载其实是成功的（QA 真机实测：真签名 dmg + 安装阶段失败，码 `4005`，
        //   2026-09-22。⚠️ 别归给「安装器起不来」—— §8.125 实测：本环境安装器能跑）。
        //   ⚠️ 它**不看 `phase`**：安装失败也可能在 `.ready` 之后再到达
        //   （用户点了「立即重启」、安装器失败）—— 那时说「安装失败」同样是对的。
        // - **正在下载时出错 = 下载失败** → `.failed`（界面：文案 + 「重试」按钮）。
        //   这是 `.failed` 在 user driver 这条路上的来源 ——
        //   2026-09-18 实扫发现 `driverDidFailDownload` 当时**全仓库没有调用点**，
        //   不分流的话这一态永远画不出来，而表现是「进度条无声消失」：
        //   与「下载完成了」长得一模一样，用户既不知道失败了、也没有重试入口。
        // - **其余**（feed 拿不到、签名不匹配、Sparkle 自己起不来…）→ 收掉会话 + 日志。
        //   ⚠️ **2026-09-28 改口径**：这一支此前落 ``UpdateController/driverDidCheckFail()``
        //   —— 那是**错的落点**，真机实测抓到：本方法的调用条件里有
        //   `showErrorToUser: _showedUpdate`（`SPUScheduledUpdateDriver.m:106`），
        //   而 `_showedUpdate` 只在**已经展示过更新**之后才为真
        //   ⇒ 「启动 / 后台取 feed 失败」**根本到不了这里**（真机复现：Sparkle 打了
        //   `kCFErrorDomainCFNetwork -1004`，而这一支一次都没跑）。
        //   ⇒ 「检查的结论」现在**只有一个来源**：delegate 的
        //   ``UpdateController/updater(_:didFinishUpdateCycleForUpdateCheck:error:)``
        //   （`SPUUpdater.m:810`，逐轮必到）。这里只负责收会话。
        //
        // **不弹窗**：本应用的弹窗是给「要不要装」用的；错误另有落点
        // （设置行 + 日志）。给一个「更新失败」弹窗会打断用户拔盘，
        // 而这件事与他此刻在做的事无关。
        //
        // 判据走四个**纯函数**（`isUpdateLocationBlocked(_:)` / `isTerminalPhase(_:)` /
        // `isPostDownloadFailure(_:)` / `isDownloadFailure(phase:error:)`，都有单测）——
        // 不新增「这一错是什么错」的位：能派生就别用「手动开关」。
        Self.logger.error("更新出错：\(error.localizedDescription, privacy: .public)")
        if let controller, UpdateController.isUpdateLocationBlocked(error) {
            controller.driverDidBlockAtLocation()
        } else if let controller, UpdateController.isTerminalPhase(controller.phase) {
            // ⚠️ **已落在终态 ⇒ 一动不动**（2026-09-22 真机实测，§8.121）。
            // 这不是「吞掉错误」—— 上面那行日志已经把它记下了 —— 而是
            // 「不让后到的回调覆盖先到的结果」。不这么写的后果（实测）：
            // 弹窗路（**默认就是这条**）下载失败时两条回调相差 1ms 都到，delegate 先
            // 设好 `.failed`，后到的这条却把它冲回 `.idle` ⇒ 界面无声回到「已是最新版本」：
            // 没有失败文案、也没有「重试」入口，用户不知道失败了。
            Self.logger.error(
                """
                已处于终态 \(String(describing: controller.phase), privacy: .public)，\
                本次错误不改写状态（后到的回调不覆盖先到的结果，§8.121）
                """)
        } else if let controller, UpdateController.isPostDownloadFailure(error) {
            controller.driverDidFailInstall(version: controller.pendingUpdate?.version)
        } else if let controller,
            UpdateController.isDownloadFailure(
                phase: controller.phase, error: error
            )
        {
            controller.driverDidFailDownload(version: controller.pendingUpdate?.version)
        } else {
            controller?.driverDidReset()
        }
        acknowledgement()
    }

    // MARK: - 下载

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard let controller else { return }
        expectedContentLength = 0
        receivedContentLength = 0
        controller.driverDidStartDownload(
            version: controller.pendingUpdate?.version ?? L10n.tr(.updateUnknownVersion),
            cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        // 总长未知（服务器没给 `Content-Length`）时不猜百分比 ——
        // 猜出来的进度条会在中途倒退，比没有进度更让人怀疑。
        guard expectedContentLength > 0 else { return }
        let fraction = min(1, Double(receivedContentLength) / Double(expectedContentLength))
        controller?.driverDidUpdateProgress(fraction)
    }

    func showDownloadDidStartExtractingUpdate() {
        controller?.driverDidFinishDownload()
    }

    /// 解压进度：**不画**（见 `UpdateController.driverDidFinishDownload` 的说明）。
    func showExtractionReceivedProgress(_ progress: Double) {}

    // MARK: - 安装

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let controller else {
            reply(.dismiss)
            return
        }
        // **攥着 reply 不马上回答**：见 `UpdateController.readyReply` 的说明。
        // 什么时候回答由 ``UpdateController/driverIsReady(version:reply:)`` 按三态分流决定：
        // 用户点过「后台更新并重启」且无推出在进行 ⇒ **当场**答 `.install`（自己重启）；
        // 有卷正在推出 ⇒ 攥着，等推出结束再答 `.install`（§8.146）；
        // 其余 ⇒ 攥着，等用户点「立即重启」。
        controller.driverIsReady(
            version: controller.pendingUpdate?.version ?? L10n.tr(.updateUnknownVersion),
            reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // 走到这里说明 reply 已经答了 `.install` —— 可能是用户点了「立即重启」，
        // 也可能是「后台更新并重启」那条路**自己**答的（§8.146），两者都会走到这里。
        // Sparkle 正在替换 bundle。不需要额外 UI —— 应用马上会被关掉并重新拉起，
        // 画什么都来不及看。
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    /// Sparkle 在**收掉**这一轮更新 UI（「Stop and tear down everything」，
    /// `SPUUserDriver.h:262-267`）。
    ///
    /// ## ⚠️ 它不是一个「很少走到的收尾」，而是错误路上**必经的一步**
    ///
    /// 2026-09-22 QA 真机复验（build 235）实测：下载失败时它比 `showUpdaterError`
    /// **晚 30ms** 到达，而此时 `phase` 还是 `.failed` ——
    /// 这一支原先无条件 `driverDidReset()` ⇒ **刚被终态闸门保住的 `.failed` 又被冲回 `.idle`**，
    /// 界面与修复前**逐字相同**（「上次检查：… · 已是最新版本」，没有失败文案、没有「重试」）。
    ///
    /// 为什么会到：我们**必须**调 `showUpdaterError` 给的 `acknowledgement()`（不调会话就挂着），
    /// 而 Sparkle 把 `abortUpdate()` 塞在那个块里 —— 它 `dispatch_async` 回主队列后
    /// **必定**调本方法（`SPUUIBasedUpdateDriver.m:456`，`showErrorToUser` 为真时无条件，
    /// 与错误是否为 nil 无关）。⇒ 闸门只装在 `showUpdaterError` 上**不够**。
    ///
    /// ⇒ 同一个终态闸门也装在这里：已落在终态就**不 reset**（判据与理由见
    /// ``UpdateController/isTerminalPhase(_:)``）。
    ///
    /// ⚠️ **非终态照旧 reset**（`.downloading` / `.found` / `.checking` / `.ready` / `.idle`）——
    /// 那正是「收掉 UI」的原意：流程没了，界面不该还挂着半截状态。
    /// 特别是 `.ready`：会话被拆之后 `readyReply` 已作废，留着就是一个点了没反应的
    /// 「立即重启」（设计稿点名不许）。
    func dismissUpdateInstallation() {
        guard let controller else { return }
        if UpdateController.isTerminalPhase(controller.phase) {
            Self.logger.error(
                """
                收 UI 时已处于终态 \(String(describing: controller.phase), privacy: .public)，\
                不回到「已是最新版本」（§8.121 / QA 2026-09-22 复验）
                """)
            return
        }
        controller.driverDidReset()
    }
}

// MARK: - 更新说明：appcast 的 HTML → 一行一条

/// 把 appcast 里的 `<description>`（HTML）解析成「一行一条」的更新清单。
///
/// **为什么是纯函数**：这是整条链上唯一一处「输入不可控」的转换 ——
/// appcast 是 `generate_appcast` 按 git commit 正文生成的，
/// 里面可能是 `<ul><li>…</li></ul>`，也可能只是一段裸文本。
/// 抽成纯函数之后，「三种输入各自解析成什么」可以被逐条钉住，
/// 而不是等到真发版时靠肉眼看弹窗。
enum UpdateReleaseNotes {

    /// 解析成条目。**空输入返回空数组**（调用方据此不画「本次更新」区块）——
    /// 返回一个 `[""]` 会让弹窗多出一行空白。
    static func lines(fromHTML html: String?) -> [String] {
        guard let raw = html?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }

        // ① 先把「条目边界」变成换行，**再**剥标签。
        //    顺序反了的话所有条目会粘成一行，看起来像「只有一条更新」——
        //    而这是最容易漏的一步：剥完标签的文本读起来完全正常，只是少了分隔。
        var marked = raw
        for boundary in ["<li", "<br", "</p", "</div", "<tr", "<h1", "<h2", "<h3"] {
            marked = marked.replacingOccurrences(of: boundary, with: "\n" + boundary)
        }

        // ② 剥标签 → ③ 解实体 → ④ 逐行清理。
        return stripTags(marked)
            .components(separatedBy: .newlines)
            .map { line in trimBullet(decodeEntities(line)) }
            .filter { !$0.isEmpty }
    }

    /// 剥掉 `<…>` 之间的内容（不做正则：标签名不重要，只要成对扫掉）。
    private static func stripTags(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// 解 HTML 实体。
    ///
    /// ⚠️ **`&amp;` 必须最后解**：先解它的话，`&amp;lt;` 会先变成 `&lt;`
    /// 再变成 `<` —— 一个本该显示成 `&lt;` 的文本被多解了一层。
    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&nbsp;", " "),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 去掉行首的列表符号。
    ///
    /// 弹窗自己会画 `·`（设计稿 `.changelog`），所以源文本里自带的符号必须去掉 ——
    /// 不去掉的话每条会变成「· · 修复了…」。
    private static func trimBullet(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first, "-*•·".contains(first) {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
