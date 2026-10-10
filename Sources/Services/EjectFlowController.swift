import Darwin
import Foundation
import os

/// 推出操作的最终结果（菜单栏与主窗口共用同一套判定）。
///
/// **为什么不再直接用 `Result<Void, EjectFailure`**：弹窗需要区分「失败原因」与
/// 「当前是谁在占用」——`fBsyErr` 只告诉我们「忙」，但真正的体验价值在于把
/// 占用进程名陈列出来并给出「关闭并推出」。`.busy` 携带检测到的进程列表，
/// 空数组表示「系统判定忙、但本应用没能列出具体进程」（例如未授予完全磁盘访问）。
enum EjectOutcome: Sendable, Equatable {
    /// 推出成功。
    case ejected
    /// 卷正被占用。`occupying` 为检测到的进程；可能为空（无法列出具体程序）。
    case busy(occupying: [OccupyingProcess])
    /// 其他失败（权限不足、设备已消失、未归类等）。
    case failed(reason: EjectFailure)
}

/// 统一磁盘推出流程（菜单栏与主窗口共用唯一实现）。
///
/// 收敛理由：此前 AppDelegate（菜单栏）与 ContentView（主窗口）各自实现一套
/// 「检查占用 → 确认 → 推出」逻辑，导致行为分叉。
///
/// 本类只做编排，不含业务规则：
/// - 外置判定在 ``DiskClassifier``
/// - 推出执行在 ``EjectService``
/// - 占用检测在 ``OccupancyDetector``
/// 三处都可独立替换与单测。
@MainActor
final class EjectFlowController {

    static let shared = EjectFlowController()

    /// 系统日志出口（`log stream` 诊断用；**不**进用户可见的 `error.log` ——
    /// 「被外部推手抢先推成」不是失败，不该让「已记入日志」的承诺说谎）。
    private static let logger = Logger(
        subsystem: "com.safeout.app", category: "EjectFlow")

    private let ejectService: EjectService
    private let occupancyDetector: OccupancyDetector

    /// 写「用户可见日志」的入口。生产默认落 ``LogService``（`~/Library/Logs/SafeOut/error.log`）。
    ///
    /// **为什么做成可注入的闭包**：失败弹窗向用户承诺「已记入日志」，
    /// 这条承诺必须有测试兜住 —— 否则将来有人把 ``recordFailure(disk:failure:)`` 改回直接
    /// `return .failed(...)`，界面照旧显示「已记入日志」，而日志里其实什么都没有，
    /// 且没有任何测试会红。测试注入一个记录型替身即可断言「失败确实留痕」，
    /// 同时避免把测试造的假失败写进用户真实的日志文件。
    private let log: (String?, String) -> Void

    /// 挂载点是否仍在系统挂载列表里（用于「报错后验盘」兜底，见 ``volumeStillMounted(_:)``）。
    ///
    /// **为什么做成可注入的闭包**：测试造不出「真挂载又真卸载」的卷
    /// （那是真机、真硬件的事），注入替身才能单测「报错 + 盘已消失 ⇒ 算成功」这条兜底。
    private let volumeMounted: (String) -> Bool

    /// 可注入初始化（生产一律用 `shared`；测试传入 mock 子类）。
    init(
        ejectService: EjectService = .shared,
        occupancyDetector: OccupancyDetector = .shared,
        log: @escaping (String?, String) -> Void = { disk, message in
            LogService.shared.log(disk: disk, message: message)
        },
        volumeMounted: @escaping (String) -> Bool = { EjectFlowController.volumeStillMounted($0) }
    ) {
        self.ejectService = ejectService
        self.occupancyDetector = occupancyDetector
        self.log = log
        self.volumeMounted = volumeMounted
    }

    /// 挂载点是否仍在系统挂载列表里。
    ///
    /// **为什么用 `mountedVolumeURLs` 而不是 `fileExists`**：卸载后 `/Volumes/X`
    /// 的挂载点目录**通常**会被移除，但残根目录（强制拔盘、权限残留）会骗过
    /// `fileExists`；挂载列表是内核的权威答案。
    private static func volumeStillMounted(_ mountPath: String) -> Bool {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.contains { $0.path == mountPath }
    }

    // MARK: - 「此刻有没有卷正在推出」

    /// 此刻正在进行的推出操作数（`> 0` = 有卷正在推出）。
    ///
    /// ## 为什么需要它
    ///
    /// 更新弹窗的提示块（`updateCallout`）向用户承诺「**正在推出的磁盘不会被打断**」——
    /// 而「后台更新并重启」那条路下载完之后会**自动重启**（§8.146），
    /// 重启 = 立刻退出 app，把正在跑的 `unmountAndEjectDevice` 腰斩。
    /// ⇒ 自动重启前必须能问出「现在有没有推出在进行」。
    ///
    /// ## 为什么是「计数器」而不是一个布尔开关
    ///
    /// 它**派生自真实操作的进出**（``eject(disk:)`` / ``terminateAndEject(disk:processes:awaiting:)``
    /// 的 `defer` 里减），不是「用户点过按钮没有」—— 后者会与真实情况脱节：
    /// 点了按钮但操作早已结束、或操作由别的入口发起，布尔开关都会答错
    /// （同「能派生就别用『手动开关』」那条纪律）。
    ///
    /// ⚠️ **它是 `private(set)`**：别的类型只能读。写入口只有下面两个操作自己的进出。
    private(set) var activeEjectionCount = 0

    /// 等所有进行中的推出结束；当前没有推出时**立即返回**。
    ///
    /// **为什么要它**：``UpdateController/driverIsReady(version:reply:)`` 遇到
    /// 「有卷正在推出」时**推迟**自动重启（否则会打断推出）。推迟的出口就是这里 ——
    /// 推出结束的那一刻唤醒等待者，把自动重启补上。
    /// 没有它的话那个分支会留下一个「**永远不自动重启**」的态
    /// （而弹窗已经向用户承诺过会自动重启）。
    ///
    /// ⚠️ **用 `while` 而不是 `if`**：被唤醒之后可能又有一轮推出进来了
    /// （`activeEjectionCount` 重新 `> 0`）⇒ 必须再等一次，
    /// 否则会在一轮推出刚起步时就把 app 重启掉。
    func waitUntilIdle() async {
        while activeEjectionCount > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// 一次推出操作结束：计数减一；归零时唤醒所有等待者。
    ///
    /// ⚠️ **`activeEjectionCount = 0` 与唤醒之间不许有 `await`**
    /// （与 ``OccupancyStore/refresh(disks:)`` 同一个坑）：否则这个窗口里进来的
    /// 新操作会看到计数为 0、自己开一轮，同时它的 continuation 又被我们取走 —— 唤醒就丢了。
    private func endEjection() {
        activeEjectionCount -= 1
        guard activeEjectionCount == 0 else { return }
        let resuming = idleWaiters
        idleWaiters = []
        for continuation in resuming { continuation.resume() }
    }

    /// 正在等「推出全部结束」的调用方。
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// 检测访问该卷的进程。
    ///
    /// 沙盒环境下返回 ``OccupancyResult/unknown``，调用方必须显式处理该状态，
    /// 不能当作「无占用」。
    func checkOccupancy(mountPath: String) async -> OccupancyResult {
        await occupancyDetector.detect(mountPath: mountPath)
    }

    /// 执行推出。
    ///
    /// **检测只用于展示，不干预决策**：先 `lsof` 捕获占用进程名（让弹窗能列出是谁），
    /// 但真实推出仍交给系统的 `unmountAndEjectDevice`——系统返回 `fBsyErr` 才是
    /// 「忙」的权威信号，检测缺失也绝不会绕过它。这既兑现了「弹出时显示是谁占用」，
    /// 又保留了 Finder 式的安全兜底。
    ///
    /// ⚠️ **它也是「此刻有卷正在推出」的登记处**（``activeEjectionCount``）——
    /// 更新那条路靠这个信号决定「能不能现在自动重启」（§8.146）。
    /// 计数放在**整个函数**上（而不是只包住 `ejectService.eject`）：`detect` 那一段
    /// 也是这次推出的组成部分，而它同样不该被一次重启腰斩。
    ///
    /// - Returns: ``EjectOutcome``，调用方据此决定弹窗内容与「关闭并推出」可用性。
    func eject(disk: DiskInfo) async -> EjectOutcome {
        activeEjectionCount += 1
        defer { endEjection() }

        // 捕获占用进程用于弹窗展示；检测失败（沙盒/.needsFullDiskAccess）时为 []。
        let occupancy = await occupancyDetector.detect(mountPath: disk.mountPath)
        let processes = occupancy.processes

        let result = await ejectService.eject(disk: disk)
        let outcome: EjectOutcome =
            switch result {
            case .success: .ejected
            // 系统判定忙：把检测到的进程（可能为空）交给弹窗呈现。
            case .failure(.inUse): .busy(occupying: processes)
            case .failure(let failure):
                // ⚠️ **报错 ≠ 失败**：先验盘，盘已不在 = 有人抢先推成了。
                // 典型场景（2026-09-29 用户真机实测）：Finder 重试风暴进行中
                // （用户点过 Finder 推出、没点系统框「取消」），本应用发起的
                // `unmountAndEjectDevice` 撞上一个刚被 Finder 推掉的卷，
                // 系统报 `OSStatus -36` / `notFound` —— 但「盘推出」正是用户要的结果，
                // 此时报错弹窗是**误报**。详见 ``terminateAndEject(disk:processes:awaiting:)``。
                volumeMounted(disk.mountPath) ? .failed(reason: failure) : .ejected
            }
        return record(outcome, disk: disk)
    }

    /// 关闭占用进程并重新尝试推出。
    ///
    /// **安全性设计**（区别于已被否决的 `umount -f`）：
    /// 1. 先发 `SIGTERM` 礼貌请求退出，让应用有机会存盘；
    /// 2. 等约 1.5s 后复检，仍被占用的进程升级为 `SIGKILL` 强制终止；
    /// 3. 再等约 0.8s 后做**普通** `unmountAndEjectDevice` 重试——绝不强制卸载文件系统。
    /// 若杀掉进程后磁盘仍被 root 级进程/内核持有，推出会再次返回 `fBsyErr`，此时
    /// 返回 `.busy(remaining)` 把「关不掉」的进程交回 UI，而不是强行卸载。
    /// 自身 PID 会被跳过；`EPERM`（无权终止，如系统进程）算作「无法关闭」如实返回。
    ///
    /// ⚠️ **中间那一步（1.5s 之后）多了一个「等上一次系统推出结束」**（2026-09-25，§8.146）：
    /// 调用方可能已经先发起过一次 ``eject(disk:)``（「先弹窗、系统在后台跑」那条路），
    /// 此时不能与它并发调 `unmountAndEjectDevice`（理由见 ``inFlight`` 那一段的注释）。
    /// 若那次推出在 `SIGTERM` 之后成功了，这里直接返回 `.ejected`。
    ///
    /// - Parameters:
    ///   - disk: 目标卷。
    ///   - processes: 来自上次 `.busy` 的占用进程列表。
    ///   - inFlight: 若调用方**已经**发起过一次 ``eject(disk:)``（「先弹窗、系统在后台跑」
    ///     那条路，见 ``EjectUI/eject(disk:cachedOccupancy:)``），把它传进来。
    ///     `SIGTERM` 之后会先等它 —— 理由见下。
    func terminateAndEject(
        disk: DiskInfo, processes: [OccupyingProcess],
        awaiting inFlight: Task<EjectOutcome, Never>? = nil
    ) async -> EjectOutcome {
        activeEjectionCount += 1
        defer { endEjection() }

        // 第 1 步：SIGTERM 礼貌退出。
        let unkillableAfterTerm = terminate(processes, signal: SIGTERM)

        // 第 2 步：等约 1.5s 让 SIGTERM 生效（应用有机会存盘），再复检。
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // ⚠️ **若有一次系统推出正在跑，等它结束再往下走 —— 不能与它并发**（2026-09-25，§8.146）：
        // 两次 `unmountAndEjectDevice` 对同一个卷并发调用行为未定义，而第二次会因
        // 「设备已不在」报 `notFound` —— **把一次成功写成失败**，用户看到的是
        // 「设备已不在，可能已被拔除」这种误导文案。
        //
        // 为什么排在上面那 1.5s **之后**：SIGTERM 一发出去，卡在 `unmountAndEjectDevice`
        // 里的那次调用就会随占用进程退出而返回 —— 等完 1.5s 再来看它，几乎总是「已成功」，
        // 于是这里不会真的再等一轮十几秒（反过来先等它、再等 SIGTERM，用户会白等一整轮）。
        if let inFlight {
            if case .ejected = await inFlight.value {
                // 占用进程退出之后系统那次推出自己成功了 —— 已经推出去了，别再动它。
                return record(.ejected, disk: disk)
            }
        }

        // 第 3 步：复检，仍占用则对残留升级 SIGKILL。
        let recheck = await occupancyDetector.detect(mountPath: disk.mountPath)
        var remaining = unkillableAfterTerm
        if case .occupied(let stillBusy) = recheck, !stillBusy.isEmpty {
            remaining = terminate(stillBusy, signal: SIGKILL)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        // 第 3 步：普通推出重试（非强制）。
        let result = await ejectService.eject(disk: disk)
        let outcome: EjectOutcome
        switch result {
        case .success:
            outcome = .ejected
        case .failure(.inUse):
            // 仍忙：把当前仍持锁的进程交回 UI（优先用复检结果，失败则退回无法终止的列表）。
            let finalCheck = await occupancyDetector.detect(mountPath: disk.mountPath)
            if case .occupied(let procs) = finalCheck, !procs.isEmpty {
                outcome = .busy(occupying: procs)
            } else {
                outcome = .busy(occupying: remaining)
            }
        case .failure(let failure):
            // ⚠️ **报错 ≠ 失败**：清场之后可能有「外部推手」抢先推成了（2026-09-29 用户真机实测）。
            //
            // 场景：接管开关开着，用户在 Finder 点推出 → 本应用放行 → Finder 弹系统
            // 「占用中」框并**持续重试**（~2.16s 间隔，直到用户点系统框「取消」）。
            // 用户此时点提醒卡片的「关闭并推出」走到这里：SIGTERM 清掉占用进程后，
            // **Finder 的下一轮重试会先把盘推掉**（我们杀进程恰好帮了它）；
            // 我们随后这次 `unmountAndEjectDevice` 撞上一个已消失的卷，
            // 系统报 `OSStatus -36`（实测日志 10:31:38.132）。但盘已推出 =
            // 用户要的结果已达成 ⇒ **验盘兜底**：挂载点已不在挂载列表里就视作成功，
            // 不弹「无法推出」误报框。
            //
            // （`.inUse` 分支不需要这层兜底：卷都不在挂载列表里就轮不到「忙」。）
            if volumeMounted(disk.mountPath) {
                outcome = .failed(reason: failure)
            } else {
                Self.logger.notice(
                    "盘已被外部推手抢先推出，unmount 落空(\(String(describing: failure), privacy: .public))视作成功 mount=\(disk.mountPath, privacy: .public)"
                )
                outcome = .ejected
            }
        }
        return record(outcome, disk: disk)
    }

    /// 记录一次「没能推出」，并原样返回结果供 UI 使用。
    ///
    /// **为什么必须真的落盘**：失败弹窗会告诉用户「已记入日志，可在『设置 › 诊断』中查看」
    /// （设计稿 `03-eject-flow.html`），设置面板的诊断分组也写着
    /// 「记录每次推出失败的时间、磁盘与原因」。这两句话只有在日志确实写入时才成立 ——
    /// ``LogService`` 早就实现了、``EjectFailure/logText`` 也早就备好了，
    /// 但两边从未接上，用户可见的 `error.log` 里一条推出失败都没有。
    /// 若照抄设计稿文案却不接线，就是在骗用户。
    ///
    /// **为什么 `.busy` 也要记**：诊断文案承诺的是「每次」推出失败，而「被占用」
    /// 恰恰是最常见的推出失败 —— 用户报「磁盘推不出来」时，日志必须能回答
    /// 「当时是谁占着」。只记 `.failed` 会让最常见的那种情况在日志里查无此事。
    /// 写入量由用户操作次数决定，不会失控。
    ///
    /// **为什么记在这里而不是 UI 层**：菜单栏与主窗口共用本类，记一次就够；
    /// 将来多一个入口（快捷键、URL scheme）也不会漏记。
    private func record(_ outcome: EjectOutcome, disk: DiskInfo) -> EjectOutcome {
        switch outcome {
        case .ejected:
            break
        case .busy(let occupying):
            // 用应用显示名（`Bunny`）而不是进程可执行名（`IMVIDEO`），否则日志对用户无意义。
            let names = occupying.map(\.displayName).joined(separator: ", ")
            log(disk.displayName, names.isEmpty ? "推出被占用: 未能列出占用进程" : "推出被占用: \(names)")
        case .failed(let failure):
            log(disk.displayName, "推出失败: \(failure.logText)")
        }
        return outcome
    }

    /// 向给定进程发送信号，返回「无法终止」的进程。
    ///
    /// **实现已下沉到 ``ProcessTerminator/signal(_:signal:selfPid:kill:)``**（2026-09-27）：
    /// 同一套信号语义现在有两个消费方 —— 本类（主窗口 / 菜单栏那条路，`@MainActor` 编排）
    /// 与 ``EjectHookService``（DA approval 回调线程，**不能 await**，走
    /// ``ProcessTerminator/clear(_:termGrace:killGrace:kill:isAlive:sleep:)``）。
    /// 留两份实现必然分叉，而分叉的那一份会在「`EPERM` 该不该计入」这类细节上
    /// 让两个入口对同一块盘给出不同说法。
    ///
    /// **行为逐字不变**（纯重构）：`ESRCH` 不计入、`EPERM` 计入、自身 PID 不发信号且计入。
    private func terminate(_ processes: [OccupyingProcess], signal: Int32) -> [OccupyingProcess] {
        ProcessTerminator.signal(processes, signal: signal)
    }

    /// 占用弹窗的说明文案（两处 UI 复用，避免文案分叉）。
    ///
    /// 仅生成引导句：占用进程的「图标 + 名称」列表由 `EjectUI` 用 accessoryView 单独呈现，
    /// 不在此处拼接为文本（`NSAlert` 的纯文本既放不了图标，也没有必要把 PID 塞给用户）。
    /// 磁盘名已经放在弹窗的 messageText（设计稿"即将推出 Samsung T7"），此处不需要重复。
    /// `occupying` 为空表示系统判定忙但本应用无法列出具体进程（通常未授予完全磁盘访问）。
    nonisolated func busyMessage(disk: DiskInfo, occupying: [OccupyingProcess]) -> String {
        if occupying.isEmpty {
            // ⚠️ 两个 %@：磁盘名 + 应用名。应用名**必须走 %@**（2026-10-10）——
            // 原文案把「磁盘推出助手」/「SafeOut」三语都硬编码进值里，改应用名时
            // 会漏掉其中一语；`fdaOnboardingBody` / `fdaOnboardingPrivacy` 早已用 %@，此处对齐。
            return String(
                format: L10n.tr(.ejectBusyNoProcessInfo), disk.displayName,
                L10n.tr(.appName))
        }
        return L10n.tr(.ejectBusyMessageFormat)
    }

    /// 推出失败的统一提示文案（两处 UI 复用，避免文案分叉）。
    nonisolated func failureMessage(disk: DiskInfo, failure: EjectFailure) -> String {
        failure.reasonText(diskName: disk.displayName)
    }
}
