import AppKit
import Foundation

/// 推出结果的统一 UI 呈现（菜单栏与主窗口共用，保证弹窗内容与按钮完全一致）。
///
/// **为什么单独抽一层**：菜单栏与主窗口是两条独立的代码路径。
/// 若两处各自拼弹窗，文案与「关闭并推出」按钮极易分叉。
/// 这里把「发起推出 → 弹窗 → 后续动作」收敛成唯一实现：
/// 两个入口都只调用 ``eject(disk:cachedOccupancy:)``，逻辑与展示不可能不一致。
/// （``handle(_:disk:)`` 是它的结果分支，也是「关闭并推出」重试之后的递归落点。）
///
/// **弹窗是自绘的**（``EjectAlertView`` + ``EjectAlertPresenter``），不是 `NSAlert` ——
/// 设计稿 `03-eject-flow.html` 的版式（图标在左、标题左对齐、提示块、下沉操作区）
/// 系统弹窗给不了。本类只负责「用户点了什么 → 该干什么」。
@MainActor
enum EjectUI {

    /// 发起一次推出 —— 主窗口与菜单栏**唯一**的编排入口。
    ///
    /// ## 为什么需要「缓存结论」这个入参（Bug：占用弹窗要等十几秒才出现）
    ///
    /// 真机日志（`/usr/bin/log show --predicate 'subsystem == "com.safeout.app"'`）：
    ///
    /// ```text
    /// 22:53:30.884 请求推出卷: /Volumes/wenbo-data
    /// 22:53:43.377 推出失败: inUse(fBsyErr)      ← 12.5 秒
    /// ```
    ///
    /// `NSWorkspace.unmountAndEjectDevice(at:)` 在卷真被占用时要**十几秒**才返回 `fBsyErr`，
    /// 而占用弹窗原先**必须等它返回**才弹。窗口里显示得快，是因为 ``OccupancyStore``
    /// 每 15s 后台跑 `lsof` 并把结论缓存进 `results`，界面直接读缓存 ——
    /// **检测逻辑是同一套**（都走 ``EjectFlowController/checkOccupancy(mountPath:)``
    /// → `OccupancyDetector.detect`），只是**时点完全不同**。
    ///
    /// ⇒ 用户已经看到「被占用」了，就没必要再等系统那十几秒：**先弹窗**。
    ///
    /// ## 为什么用**缓存**结论，而不是「现测一次」
    ///
    /// 缓存里的那一份**正是窗口上显示的那一份**（``DiskListRegion`` 读
    /// `occupancyStore.result(for:)`）。用它弹窗，才能保证「用户看到的」与「弹出的」
    /// 是**同一个结论** —— 否则会出现「窗口说没占用、点了却弹占用窗」这种自相矛盾的链。
    /// 现测一次虽然更新，但它与窗口显示的可能不一致（15s 内进程变了），
    /// 而且**它本身也要时间**（多卷时 `lsof` 并不便宜）。
    ///
    /// ⇒ 缓存的「最长 15s 过期」由**系统的权威结论兜底**：系统推出照常跑，
    /// 若它其实**成功**了（占用进程恰好自己退出了）、**或盘已经不在了**
    /// （`.failed(.notFound)`，见 §8.146.7），预弹的弹窗会被收掉
    /// （`EjectAlertPresenter.respond(.cancel)`）并刷新列表 —— 不会留一个谎报「被占用」的弹窗。
    ///
    /// ## ⚠️ 用户按了 Esc、而系统那次推出**成功**了 —— 列表靠谁刷新（2026-09-25，§8.146.6）
    ///
    /// 落闸之后 watcher 不再 `respond`，**也就不再刷新列表**。此时刷新由产品自己那条链负责：
    /// 卷被卸载 ⇒ `NSWorkspace.didUnmountNotification` ⇒ ``DiskListStore/setupMonitoring()``
    /// 的观察者 ⇒ `refresh()`。
    ///
    /// 这条链本轮**核实过成立**（观察者同时挂了 `didMountNotification` 与
    /// `didUnmountNotification`；`IntegrationEjectTests` 的文件头也把「挂载通知之后那次
    /// `refresh()`」记成了产品的判定时点）⇒ **不把 `refresh()` 从 `respond` 里拆出来**：
    /// 拆开只是给同一个结果多加一条路径，而这条通知链是产品本来就有、别处也依赖的机制。
    ///
    /// ## ⚠️ 「谁决定成败」没有变
    ///
    /// 缓存结论**只用来决定「什么时候弹窗」**，绝不参与「能不能推出」：
    /// 系统调用照常发起（`EjectFlowController.eject`），`fBsyErr` 仍是唯一的权威信号。
    /// 理由是 ``EjectFlowController/eject(disk:)`` 里写明的那条 —— `lsof` 会列出
    /// `mds` / `fseventsd` 这类**不妨碍卸载**的系统进程，拿它当判据会误报。
    static func eject(disk: DiskInfo, cachedOccupancy: OccupancyResult) async {
        // 推出结果通知的授权申请（幂等，进程内只弹一次系统框）。
        // 放在**发起推出**的时刻而不是启动时 —— 用户正在用推出功能，
        // 此刻问「要不要结果通知」名正言顺；见
        // ``EjectNotificationService/requestAuthorization()`` 的调用点说明。
        EjectNotificationService.shared.requestAuthorization()

        guard let occupying = Self.preemptivelyOccupied(cachedOccupancy) else {
            // 缓存没说被占用 ⇒ 老路：等系统结论（它才是权威）。
            await handle(await EjectFlowController.shared.eject(disk: disk), disk: disk)
            return
        }

        // ① 系统推出照常发起（**不 await**：弹窗不必等它那十几秒）。
        let inFlight = Task { @MainActor in
            await EjectFlowController.shared.eject(disk: disk)
        }

        // ② 系统那次推出的结果若**已经让这个「被占用」的弹窗站不住**（成功 / 设备已不在）
        // ⇒ 收掉它并刷新列表。
        //
        // ⚠️ **`gate` 防的是「收错窗」**：用户可能已经对这个预弹的弹窗表过态
        // （点了「关闭并推出」、按了 Esc），那个弹窗早已被收掉、甚至已经有**新的**弹窗
        // （`terminateAndEject` 失败后的失败窗）在显示 —— 此时再收一次就会收错。
        // 判据是「**这个预弹窗还在不在等用户**」（见 `dismissPreemptivePopupIfNeeded`
        // 与 `PreemptiveAlertGate` 的说明）。
        let gate = PreemptiveAlertGate()
        Task { @MainActor in
            await Self.dismissPreemptivePopupIfNeeded(
                gate: gate,
                outcome: await inFlight.value,
                dismiss: { EjectAlertPresenter.shared.respond(.cancel) },
                refresh: { await DiskListStore.shared.refresh() })
        }

        // ③ 立刻弹窗，等用户决定。
        //
        // ⚠️ **「用户已接管这个窗」由 `awaitPreemptiveChoice` 无条件记下** ——
        // 不许写成「点了『关闭并推出』才算」：那样按 Esc 这一支会提前 `return`，
        // 闸门永远不落，而那次还在跑的系统推出一旦成功就会去收掉**之后才打开的那个弹窗**
        // （§8.146.6 的复现路径）。
        let choice = await Self.awaitPreemptiveChoice(gate: gate) {
            await EjectAlertPresenter.shared.present(.busy(disk: disk, occupying: occupying))
        }
        // 用户取消 / 弹窗被「系统其实成功了」收掉 —— 两条都不该动进程。
        // （后者：`watcher` 已经刷新过列表了。）
        guard choice == .closeAndEject else { return }

        // ⚠️ 把那次还在跑的推出传进去：`terminateAndEject` 会先等它结束，
        // **不能**与它并发调 `unmountAndEjectDevice`（会把一次成功写成 notFound）。
        let result = await EjectFlowController.shared.terminateAndEject(
            disk: disk, processes: occupying, awaiting: inFlight)
        await handle(result, disk: disk)
    }

    /// 缓存结论是否已经足以「**立刻**弹占用弹窗」。
    ///
    /// **纯函数**：它是本 Bug 修复的判据本身（「什么样的缓存结论配得上提前弹」），
    /// 而 `.occupied([])` 与 `.unknown` 这两格**必须不弹** ——
    /// 前者是「系统说忙但列不出进程」（弹一个空列表的占用窗毫无意义，
    /// 而 `EjectAlertView` 对空列表本来就不画进程区块），
    /// 后者是「还没测出来」，把它当占用是本应用最不能犯的错误
    /// （见 ``OccupancyStore/result(for:)`` 的兜底说明）。
    nonisolated static func preemptivelyOccupied(_ result: OccupancyResult) -> [OccupyingProcess]? {
        guard case .occupied(let processes) = result, !processes.isEmpty else { return nil }
        return processes
    }

    /// 等用户对预弹的占用弹窗表态，并在**返回之前无条件**把闸门落下。
    ///
    /// - Returns: 用户的选择（调用方据此决定要不要动进程）。
    ///
    /// ## ⚠️ 「落闸」与「用户点了什么」无关（2026-09-25，§8.146.6）
    ///
    /// `present` **一返回**就说明这个窗已经不在屏上了 —— 要么用户点了什么
    /// （「关闭并推出」/ Esc），要么 watcher 自己把它收掉了（系统那次推出其实成功了）。
    /// 三种情况都意味着「它不再是待用户表态的窗」，所以落闸必须是**无条件**的。
    ///
    /// **原来错在哪**：那一行写在 `eject` 的 `guard choice == .closeAndEject else { return }`
    /// **之后** ⇒ 按 Esc 这一支提前 `return`、闸门永远不落，而那次还在跑的
    /// 系统推出**并没有被取消**（Esc 只是「不做激进动作」，不是「中止推出」）。
    /// 它一旦成功，watcher 就会 `respond(.cancel)` —— 收掉的是**用户之后才打开的那个弹窗**：
    ///
    /// 1. 推出盘 A（缓存说被占用）⇒ 弹窗 A 上屏，系统那次推出在后台跑（可能几十秒）；
    /// 2. 在 A 上按 Esc ⇒ `present` 返回 `.cancel`，**闸门 A 不落**；
    /// 3. 推出盘 B ⇒ 弹窗 B 上屏；
    /// 4. A 的那次推出成功了 ⇒ watcher A 看到「闸门 A 未落」⇒ `respond(.cancel)` ⇒ **把弹窗 B 收了**；
    /// 5. 于是 B 的 `EjectUI.eject` 拿到 `.cancel` 直接返回、**一个进程都没碰** ——
    ///    用户按了按钮，**什么都没发生**（本仓库最不能接受的那种结果）。
    ///
    /// 抽成函数是为了让这条顺序能被测试真正跑一遍（`EjectUI.eject` 本体要真弹窗，
    /// 测试进程里跑不了；同 ``preemptivelyOccupied(_:)`` 的理由）。
    @MainActor
    static func awaitPreemptiveChoice(
        gate: PreemptiveAlertGate,
        present: () async -> EjectAlertChoice
    ) async -> EjectAlertChoice {
        let choice = await present()
        gate.settle()
        return choice
    }

    /// 系统那次推出的结果**已经让预弹窗上那句「被占用」站不住**时，
    /// 收掉它并刷新列表（判据见 ``shouldDismissPreemptivePopup(gate:outcome:)``）。
    ///
    /// ⚠️ **它不再只服务「系统成功」那一种结果**（2026-09-25，§8.146.7）：
    /// `.failed(.notFound)`（盘已经不在了）同样要收 —— 一个关于**不存在的磁盘**的弹窗
    /// 没有任何可问的事。函数名没改，因为它问的本来就是「要不要收掉这个预弹窗」，
    /// 从来没说「成功时」；改的是判据与文档（原来那句「结果必须是 `.ejected`」已不成立）。
    ///
    /// 抽成「动作从参数进来」的形式，是为了让这条判据**能被真正跑一遍** ——
    /// `eject` 本体要真弹窗（`makeKeyAndOrderFront`），测试进程里跑不了；
    /// 而这条判据写反（漏掉 `!gate.isSettled`）**不会有任何编译错**。
    @MainActor
    static func dismissPreemptivePopupIfNeeded(
        gate: PreemptiveAlertGate,
        outcome: EjectOutcome,
        dismiss: () -> Void,
        refresh: () async -> Void
    ) async {
        guard shouldDismissPreemptivePopup(gate: gate, outcome: outcome) else { return }
        dismiss()
        await refresh()
    }

    /// 系统那次推出的结果，**已经让预弹窗上那句「被占用」站不住**了吗。
    ///
    /// 这是「要不要收掉预弹窗」的判据（``dismissPreemptivePopupIfNeeded(gate:outcome:dismiss:refresh:)``
    /// 用它）。两条判据缺一不可：
    /// - 闸门**必须未落** —— 落了说明这个窗已经不在等用户了（用户表过态、或已被收掉），
    ///   此时再 `respond` 收掉的是**之后才打开的那个弹窗**（§8.146.6）；
    /// - 结果必须是**已经让窗上那句话站不住**的那两种（见下）。
    ///
    /// ## 哪两种结果算「站不住」（2026-09-25，§8.146.7）
    ///
    /// - ``EjectOutcome/ejected``：盘已经推出去了 —— 窗还写着「被占用」就是**谎报**；
    /// - ``EjectOutcome/failed(reason:)`` 且原因是 ``EjectFailure/notFound``：
    ///   盘**已经不在了**（用户拔了、或别的工具卸了）—— 一个关于**不存在的磁盘**的弹窗
    ///   没有任何可问的事，而列表里那块盘已经消失（`didUnmountNotification` 刷过）。
    ///   这一支是第二轮复核**改判**加上的：纯逻辑，不需要换窗时序判断。
    ///
    /// ⚠️ **`.busy` 与其它失败（`.notPermitted` / `.other`）刻意留窗**：
    /// `.busy` 时窗上那句话**是对的**（盘真的还忙着）；`.notPermitted` / `.other` 时
    /// 用户点「关闭并推出」会让重试撞到真相 ⇒ 收窗反而把「用户正看着的那条线索」拿掉。
    /// 理由与代价见 §8.146.7 判断②。
    ///
    /// ⚠️ **用 `switch` 而不是 `if case`**：`EjectOutcome` 将来加 case 时这里**编译不过**
    /// ⇒ 「哪些结果算站不住」失效是**红**的，不是静默的（同 ``UpdateController/isTerminalPhase(_:)``
    /// 那条纪律）。
    ///
    /// **为什么抽成纯函数**（同 ``preemptivelyOccupied(_:)``）：它正是「收错窗 / 留错窗」
    /// 这条判据本身，而调用点在一个 `Task` 里、条件写反了不会有任何编译错。
    @MainActor
    static func shouldDismissPreemptivePopup(
        gate: PreemptiveAlertGate, outcome: EjectOutcome
    ) -> Bool {
        guard !gate.isSettled else { return false }
        switch outcome {
        case .ejected:
            return true
        case .failed(.notFound):
            return true
        case .busy:
            return false
        case .failed:
            return false
        }
    }

    /// 「预弹的占用弹窗」是否已经不再等用户表态。
    ///
    /// **为什么需要它**：见 ``eject(disk:cachedOccupancy:)`` 第 ② 步。
    /// 系统推出成功时要收掉预弹的弹窗；但用户若**已经**对这个窗表过态，
    /// 那个弹窗早已被收掉，且可能已经有新的弹窗在显示 —— 再收一次就会收错窗。
    ///
    /// ⚠️ **判据是「这个预弹窗还在不在等用户」**，实现上就是 ``isSettled``：
    /// 它在 ``awaitPreemptiveChoice(gate:present:)`` 里、`present` **一返回**就置位，
    /// **与用户点了什么无关**（含 Esc）。写成「只有点了『关闭并推出』才算表态」正是
    /// §8.146.6 那条漏判：按 Esc 时闸门永不落，watcher 会去收掉别的弹窗。
    ///
    /// ⚠️ **它在主 actor 上，读写之间没有 `await`** ⇒ 「用户做了决定」与
    /// 「watcher 检查 gate」不会交错（两者都在主 actor 上串行执行）。
    @MainActor
    final class PreemptiveAlertGate {
        /// 这个预弹窗是否已经不再是「待用户表态」状态。
        private(set) var isSettled = false

        /// 落闸：`present` 一返回就调用（**与用户的选择无关**）。
        func settle() { isSettled = true }
    }

    /// 处理一次推出结果。
    ///
    /// - `.ejected`：发「已安全推出」系统通知，刷新列表。
    /// - `.busy`：弹窗列出占用进程并提供「关闭并推出」；确认后终止进程并重试，
    ///   重试结果递归回本函数（成功刷新 / 仍占用再提示 / 其他失败）。
    ///   **此分支不发结果通知** —— 它是中间态，落定后会再次回到本函数。
    /// - `.failed`：发「推出失败」系统通知并弹失败提示，「查看日志」在访达中显示日志。
    ///   通知与弹窗并存：弹窗在本应用身上，用户切走后看不见；系统通知才够得着。
    ///
    /// **必须 `await`**：弹窗会挂起直到用户做出选择。调用方本来就在 `Task {}` 里，
    /// 写起来仍是顺序的。
    static func handle(_ outcome: EjectOutcome, disk: DiskInfo) async {
        switch outcome {
        case .ejected:
            // 通知先于刷新：通知是本函数对用户的直接反馈，不依赖刷新成败。
            EjectNotificationService.shared.postResult(outcome, disk: disk)
            await DiskListStore.shared.refresh()
            dismissSystemDialogIfAny(disk: disk)

        case .busy(let occupying):
            let choice = await EjectAlertPresenter.shared.present(
                .busy(disk: disk, occupying: occupying))
            // 只有「关闭并推出」这一条路径会丢数据，所以只有它需要确认后动手。
            guard choice == .closeAndEject else { return }
            let result = await EjectFlowController.shared.terminateAndEject(
                disk: disk, processes: occupying)
            await handle(result, disk: disk)

        case .failed(let failure):
            EjectNotificationService.shared.postResult(outcome, disk: disk)
            let choice = await EjectAlertPresenter.shared.present(
                .failure(disk: disk, failure: failure))
            if choice == .viewLog {
                LogService.shared.revealLogInFinder()
            }
        }
    }

    /// 盘推出成功后，关掉系统那张「磁盘被占用」框（如果还挂着）。
    ///
    /// ## 为什么接在这里（2026-09-29 用户需求）
    ///
    /// 用户在访达点推出 → 盘被占用 → macOS 弹 `UnmountAssistantAgent` 的
    /// 「磁盘"X"没有被推出…」框；用户改用本应用的「关闭并推出」成功后，那个框
    /// **不会自己消失**，还挂在屏幕上。``handle(_:disk:)`` 是**所有**推出成功路径的
    /// 唯一收口（预弹路径、菜单栏路径、主窗口路径最后都落到 `.ejected` 这一支），
    /// 接在这里就不会漏。
    ///
    /// ## 为什么丢到后台
    ///
    /// AX 调用是**跨进程同步**的（见 ``SystemEjectDialogDismisser``），在 `@MainActor`
    /// 上直接调会卡住 UI；而盘已经推出，关框晚几十毫秒没有任何影响。
    /// 关不掉也只是弹窗残留（体验瑕疵），绝不该影响推出结果与列表刷新。
    private static func dismissSystemDialogIfAny(disk: DiskInfo) {
        let name = disk.displayName
        Task.detached(priority: .utility) {
            SystemEjectDialogDismisser.dismiss(forDiskNamed: name)
        }
    }

    /// 占用弹窗的警示文案（**必须写清动作序列**）。
    ///
    /// 设计稿文案原则：「『先请求正常退出 → 几秒后强制结束 → 重试推出』——
    /// 用户知道点下去会发生什么。」这不是修辞：
    /// ``EjectFlowController/terminateAndEject(disk:processes:)`` 的实现恰好就是这三步
    /// （`SIGTERM` → 1.5s → `SIGKILL` → 普通重试）。
    /// 文案与实现是一对，改文案前先看实现，改实现后必须回来看文案。
    ///
    /// 品牌名走 `appName` 本地化键而不是硬编码 `SafeOut`：中文界面里应用叫
    /// 「磁盘推出助手」，正文里突然出现英文品牌名是断裂的。
    static var busyWarningText: String {
        String(format: L10n.tr(.ejectBusyWarning), L10n.tr(.appName))
    }
}
