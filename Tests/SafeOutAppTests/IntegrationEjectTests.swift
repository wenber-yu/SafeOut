import Foundation
import Testing

@testable import SafeOutApp

/// 真机集成测试：在真实被占用的磁盘上验证「关闭占用进程并推出」端到端链路。
///
/// **为什么保留在套件里而不是删掉**：这是核心价值（列出占用进程 + 一键关闭并推出）唯一
/// 的真实端到端验证，mock 单测覆盖不了「真实 lsof 列出进程 → SIGTERM/SIGKILL → 系统推出」这条链路。
///
/// **CI / 受限环境的处理**：挂载磁盘映像需要访问 `/Volumes` 与 `/dev`，在 CI 沙盒或
/// 无权限环境下 `hdiutil attach` 会失败。此时**跳过而非失败**（见 `canAttachDiskImage`），
/// 避免把环境限制误判成产品缺陷；本地开发机上有权限时会执行完整验证。
///
/// ## ⚠️ 为什么必须「等测试盘出现」，而不是 `hdiutil attach` 一返回就查（2026-09-21）
///
/// 这条测试**真红过一次**（全量日志 `.build/preflight/门槛8.log`）。那次失败输出里：
///
/// ```
/// guard …fetchExternalDisks().first(where: { $0.mountPath == vol })  →  没找到
/// ① 本次看到的外部盘：["/Volumes/wenbo-data", "/Volumes/DiskEjectorEjectTest"]
/// ```
///
/// 同一个函数、相隔几微秒，**两次调用的结果不一样** —— 而 `try "hi".write(toFile: "\(vol)/x.txt")`
/// 已经成功 ⇒ 卷在**文件系统层面确实已挂载**。
/// ⇒ 不是「没挂上」，是「挂上了，但 `fetchExternalDisks()` 那一刻还没把它算成外置卷」：
/// ``DiskClassifier`` 对磁盘映像走第 4 条（虚拟设备没有 `DADeviceInternal`），
/// 要求 `DAMediaEjectable == true`，而那个属性由 **DiskArbitration 异步补全**。
///
/// **为什么这不是「把测试改松」**：产品自己的「盘可见」判定时点是
/// ``DiskListStore`` 收到 `NSWorkspace.didMountNotification` 之后那次 `refresh()`，
/// 比 `hdiutil attach` 返回**更晚**。原测试假设的「attach 返回 ⇒ 立刻可见」
/// **比产品契约更严** —— 偶发正是这条更严的假设造成的，不是产品缺陷。
/// ⇒ 现在等的是**产品会看到的同一个东西**（盘出现在 `fetchExternalDisks()` 里），
/// 超时仍是硬失败，且失败信息里带上「求值几次、等了多久」（``WaitOutcome``）。
///
/// ⚠️ **本套件故意不标 `@MainActor`**（2026-09-20，§8.99）。
///
/// 它**原来**有两处 `task.waitUntilExit()`（`canAttachDiskImage()` 里、`shell(_:)` 里），
/// 以及它们调起的 `hdiutil create/attach/detach` —— 全是**同步阻塞、不让路**的等待。
/// 标了 `@MainActor` 就等于把这些等待压在**主 actor** 上，而主 actor 上排着一长串
/// `@MainActor` 用例（**29 个测试文件**带它，计数口径见 §8.128），任何一个被堵住都会让**别的**用例排不上队（§8.97.3）。
///
/// 摘掉标注后这些等待跑在**协作线程池**上，主 actor 不再被占。
/// 逐处确认过：需要主 actor 的只有 `EjectFlowController`（`@MainActor`），
/// 而它两处都是 `await` 调用（跨 actor 边界本来就没问题）；
/// `DiskService` 是 `@unchecked Sendable`、非隔离 ⇒ **摘掉后没有一处需要补 `@MainActor`**。
///
/// ⚠️ **但「搬出主 actor」不是终点**（2026-09-22，§8.114 第 6 节）：`waitUntilExit()`
/// 占住的是**协作线程池**里的一根线程（池大小 ≈ 核数），CI 上核数更少 ⇒
/// 几处并发阻塞就能让整个进程停摆。⇒ 两处都改成 ``runAndAwaitExit``
/// （等 `terminationHandler` **回调**，一个线程都不占），`shell` 与 `canAttachDiskImage`
/// 随之变成 `async`。守卫：`MainActorBlockingTests.测试代码里不许同步等子进程`。
struct IntegrationEjectTests {

    @Test func 真实占用时关闭进程并推出() async throws {
        // 环境不支持挂载磁盘映像时优雅跳过（CI 沙盒等），不判失败。
        guard await Self.canAttachDiskImage() else { return }

        let dmg = "/tmp/DiskEjectorEjectTest.dmg"
        let vol = "/Volumes/DiskEjectorEjectTest"
        var tail: Process?

        // 清理必须**在任何可能失败的步骤之前**登记。
        // 原先 defer 写在 `tail.run()` 之后，而上面第 27 行的写入也在它之前 ——
        // 一旦写入抛错，defer 还没注册，挂载点与临时 dmg 就一起泄漏了。
        // 2026-09-15 实际踩过：写入被沙箱拦截 → `/Volumes/DiskEjectorEjectTest`
        // 一直挂着、`/tmp` 里留了 5 MB 映像，只能手工 hdiutil detach。
        //
        // ⚠️ **2026-09-22 起 `defer` 只做同步那两件**：`hdiutil detach` 现在走 ``shell``，
        // 而 `shell` 是 `await` 的（它不再用 `waitUntilExit()`，见那里的说明），
        // 而 **`defer` 里不许出现 `await`**。⇒ 正文包进局部函数 `body()`，
        // `detach` 写在**它之后** —— `body()` 里所有提前退出都只是 `return` 出 `body()`，
        // 收尾一定跑得到（原先靠 `defer` 保证的那件事没有被削弱）。
        defer {
            tail?.terminate()
            try? FileManager.default.removeItem(atPath: dmg)
        }

        /// 正文。⚠️ 用局部函数而**不是** `defer` —— 理由见上面那段。
        func body() async throws {
            try? await shell("hdiutil detach \(vol) 2>/dev/null")
            try? FileManager.default.removeItem(atPath: dmg)
            try await shell("hdiutil create -size 5m -fs HFS+ -volname DiskEjectorEjectTest \(dmg)")
            try await shell("hdiutil attach \(dmg) -nobrowse")
            try "hi".write(toFile: "\(vol)/x.txt", atomically: true, encoding: .utf8)

            // 制造一个真实占用进程（tail -f 持续打开文件）。
            let tailProcess = Process()
            tailProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            tailProcess.arguments = ["-f", "\(vol)/x.txt"]
            tailProcess.standardOutput = FileHandle.nullDevice
            try tailProcess.run()
            // ⚠️ **登记必须在 `run()` 之后、且在任何可能失败的步骤之前**（上面那段说的事）。
            tail = tailProcess

            // ⚠️ **等到它出现在 `fetchExternalDisks()` 里**，而不是 `hdiutil attach` 一返回就查 ——
            // 两者的差别见文件头「为什么必须等」。默认预算 300 拍 ≈ 旧 15s 窗口：实测传播延迟在
            // 亚秒级，15s 足够；真看够了 300 拍还不出现，那是**环境或产品**的问题，必须硬失败。
            let waited = await Self.waitForDisk { await Self.liveTestDisk(at: vol) }
            guard let disk = waited.disk else {
                // ⚠️ 2026-09-21 真红过一次（全量日志 `.build/preflight/门槛8.log`）。
                // 只写「未找到测试盘」等于没说：至少三种可能，而它们的修法完全不同 ——
                //   ① `hdiutil attach` 其实没挂上（沙箱 / 权限）；
                //   ② 挂成了 `DiskEjectorEjectTest 1`（上一轮的挂载点还占着名字）；
                //   ③ 挂上了，但那一刻 `fetchExternalDisks()` 还没把它算成外置卷。
                // 原诊断只打「本次看到的外部盘」，而那是一次**重新查询** —— 它拿到的是
                // 「现在的状态」，说明不了「失败那一刻为什么没看到」。
                // ⇒ 这里把能分开这三件事的证据**逐条**打出来（② 用的是既有的注入点，
                //    不需要为诊断在生产代码里加任何东西）。
                // ⚠️ 走 `"\(…)"` 而不是直接传 `String`：`Issue.record` 的重载里有 `Error` 那一支，
                // 直接传 `String` 会被解析成 `Error`（编译错）。插值造出的是 `Comment`。
                let message = Self.notFoundDiagnostic(vol: vol, outcome: waited.outcome)
                Issue.record("\(message)")
                return
            }

            // 1) 直接推出：应失败并返回 busy，且携带占用进程。
            let first = await EjectFlowController.shared.eject(disk: disk)
            guard case .busy(let occupying) = first else {
                Issue.record("期望 busy，实际 \(first)")
                return
            }
            #expect(!occupying.isEmpty, "busy 应携带占用进程（列出是谁）")

            // 2) 关闭并推出：终止占用进程后应成功。
            let second = await EjectFlowController.shared.terminateAndEject(
                disk: disk, processes: occupying)
            guard case .ejected = second else {
                // ⚠️ **`.busy` 且占用列表为空时，必须把「另一个 dissenter」这件事说出来**
                //    （2026-09-28 实测：本条连红 5 次，输出的 `期望 ejected，实际
                //    .busy(occupying: [])` 一个字都没提是谁占着，查了很久）。
                //    列表为空 = lsof 里已经没人持锁，而系统仍说忙 ⇒ 忙的是**审批会话
                //    dissenter**，不是进程。最常见的那个 dissenter 正是**本应用自己**：
                //    开着「接管访达的推出」的实例会 dissent 每一次 unmount。
                //    它的名字只在 `diskutil unmount` 的 stderr 里出现（`-69888` 那条
                //    `Dissenter parent PPID 1 (…)`），产品侧拿不到 ⇒ 只能在这里提示。
                var hint = ""
                if case .busy(let procs) = second, procs.isEmpty {
                    hint = await Self.dissenterHint(vol: vol)
                }
                Issue.record("期望 ejected，实际 \(second)\(hint)")
                return
            }

            // 3) 验证卷确实已被推出（不再出现在外置卷列表中）。
            let stillThere = DiskService.shared.fetchExternalDisks().contains { $0.mountPath == vol }
            #expect(!stillThere, "推出后卷应已消失")
        }

        // ⚠️ `body()` 抛错时**也要收尾**（否则卷与临时 dmg 一起泄漏）⇒ 先把错误记下来，
        // 收尾之后再抛回去 —— 原先是 `defer` 顺带保证的，改成显式收尾后必须自己保证。
        var thrown: Error?
        do { try await body() } catch { thrown = error }
        tail?.terminate()
        try? await shell("hdiutil detach \(vol) 2>/dev/null")
        try? FileManager.default.removeItem(atPath: dmg)
        if let thrown { throw thrown }
    }

    // MARK: - 等测试盘出现（以及它为什么必须等）

    /// 等 `probe` 交出磁盘，最多 `timeout` 秒；返回「等到了吗」与**等到的那块盘**。
    ///
    /// ⚠️ 盘**从轮询里带出来**，不在外面再查一次 —— 再查一次正是 2026-09-21 那次失败诊断的
    /// 毛病：它**重新**查了一遍，于是拿到的是「现在的状态」，而不是「失败那一刻的状态」
    /// （同族：§8.113.12「报错必须指名真因」）。
    ///
    /// ⚠️ `probe` 由调用方注入 ⇒ 这条「等到可见为止」的策略**本身可以被确定性地验**：
    /// 喂一个「第 1 拍 nil、第 2 拍给盘」的探针必须成功且恰好 2 拍；喂一个「永远 nil」的
    /// 探针必须在超时后**放弃**（而不是挂住），且拍数 ≥ 2（证明是**轮询**，不是「查一次就睡」）。
    /// 见 `等待测试盘的装置必须真的轮询并且能超时`。
    ///
    /// ⚠️ **注入探针只隔离了「被测逻辑」，没隔离「循环退出条件」** —— 2026-09-21 这条守卫
    /// 自己在 CI 上红过一次（§8.118）：探针 `[nil, nil, disk]` 要求「第 3 拍」，而当时退出
    /// 条件里的墙钟被**一次** `Task.sleep(50ms)`（runner 上实测拖到 ~6.1s）整个吃掉。
    ///
    /// ⚠️ **2026-09-23（§8.132）把根因修掉了**：退出条件从「墙钟到点」换成「**看够了次数**」，
    /// 墙钟降级成安全网。⇒ 那次踩坑的前提（「迭代次数由截止时间决定 ⇒ 拍数随负载变」）
    /// **已经不存在**，当时那条「守卫里不许写第 N 拍才成立（N ≥ 3）」的禁令随之作废 ——
    /// 它是**绕过**，不是修好。现在守卫可以直接钉「负载拖长也不误判」，
    /// 见 `每拍被拖长时不再误报超时`。
    ///
    /// 判「谁说了算」用 ``WaitOutcome/StopReason``、报数用 ``WaitOutcome`` ——
    /// 与 `ProcessAppResolverTests.waitForExecutablePath` 同一口径，别再造第三套。
    ///
    /// ⚠️ **2026-09-22 起用 ``WaitOutcome`` 的只剩这两处**：`OccupancyStoreTests` 那条等待
    /// 换成了**等事件**（``EventWait``）—— 它等的不是「条件成立」，而是「某一轮跑完了」，
    /// 两者的判据完全不同（见 `WaitOutcome.swift` 抬头）。这里仍然是**真在等条件**，留在这一族。
    ///
    /// | 参数 | 含义 | 与负载的关系 |
    /// |---|---|---|
    /// | `pollBudget` | **看几次**（默认 300 ≈ 旧 15s 窗口 / 50ms） | **无关** —— 它决定退出 |
    /// | `hardCeilingMS` | **最长挂多久**（安全网，只防挂死） | 有关，但只在病态时才到点 |
    /// | `pollIntervalNS` | **两拍之间让多久的路**（默认 50ms，与生产一致） | 有关 —— 它决定一拍**多快** |
    ///
    /// ⚠️ **安全网的余量必须拿「实测最坏单拍」算，不能拿名义的 50ms 算**（2026-09-23，§8.135）。
    /// 一次 `Task.sleep(50ms)` 在 CI 上实测能拖到 **~7.2s**（§8.118 记的是 ~6.1s；本仓 run
    /// `35783127520` 又实测到 ~7.2s）⇒ 名义值下「6s 是 120× 余量」，按实测最坏值算却是 **0×**。
    /// 本仓就在这上面红过一次：守卫把安全网设成 6s，而 CI 上一拍就吃掉 7.2s ⇒ 「预算说了算」
    /// 被翻成「没看够」（`polls: 2, stopReason: .ceilingHit`）。
    /// ⇒ **凡断言 `.budgetExhausted` 的守卫，安全网都由 ``WaitOutcome/worstObservedPollMS`` 派生**（见该文件里的常量），
    /// 并且把拍间隔压到 1ms，让「预算的名义时长」远小于安全网 —— 双重保险，且守卫的
    /// **耗时不再随 runner 抖动**（原来每条守卫在 CI 上都要 7 秒）。
    private static func waitForDisk(
        pollBudget: Int = 300,
        hardCeilingMS: Int = WaitOutcome.derivedCeilingMS,
        pollIntervalNS: UInt64 = 50_000_000,
        probe: @Sendable () async -> DiskInfo?
    ) async -> (outcome: WaitOutcome, disk: DiskInfo?) {
        let started = Date()
        let ceiling = started.addingTimeInterval(Double(hardCeilingMS) / 1000)
        var polls = 0
        // ⚠️ 默认值就是「预算花完」：`while` 的条件先判，所以「预算已满」时
        // 绝不会被误报成 `ceilingHit` —— 两个出口在结构上互斥。
        var stopReason = WaitOutcome.StopReason.budgetExhausted
        while polls < pollBudget {
            if Date() >= ceiling {
                stopReason = .ceilingHit
                break
            }
            polls += 1
            if let disk = await probe() {
                return (
                    WaitOutcome(
                        stopReason: .conditionMet, polls: polls,
                        elapsed: Date().timeIntervalSince(started)),
                    disk
                )
            }
            // `Task.sleep` 是**让路**（不是 `usleep` 那种同步阻塞）——
            // 本套件不标 `@MainActor`，但协作线程池上的同步阻塞同样会饿着别的用例（§8.99）。
            try? await Task.sleep(nanoseconds: pollIntervalNS)
        }
        // 退出循环时可能刚好是最后一拍就绪 —— 再查一次，别把「刚好赶上」误报成超时。
        polls += 1
        let found = await probe()
        return (
            WaitOutcome(
                stopReason: found != nil ? .conditionMet : stopReason, polls: polls,
                elapsed: Date().timeIntervalSince(started)),
            found
        )
    }

    /// 生产探针：**在协作线程池之外**枚举。
    ///
    /// `fetchExternalDisks()` 会做磁盘 I/O（逐卷问 DiskArbitration），与
    /// ``DiskListStore`` 的 `refresh()` 走同一条路 —— 不让它占住协作线程池的线程。
    private static func liveTestDisk(at vol: String) async -> DiskInfo? {
        await Task.detached(priority: .userInitiated) {
            DiskService.shared.fetchExternalDisks().first { $0.mountPath == vol }
        }.value
    }

    // MARK: - 失败诊断：把「三种可能」逐条分开

    /// `.busy` 且占用列表为空时补的那段提示 —— 把**真正的 dissenter**说出来。
    ///
    /// ⚠️ **为什么必须单独跑一次 `diskutil unmount`**：dissenter 的名字只写在它的
    /// stderr 里（`Volume … failed to unmount: '<名字>: disk busy' (PID …)`），
    /// 产品侧（`DADiskUnmountAndEject` 的回调）拿不到 ⇒ 只有这里能问出来。
    ///
    /// 2026-09-28 实测那条 stderr 是：
    /// ```
    /// Volume … failed to unmount: 'SafeOut: disk busy' (PID 62210)
    /// Dissenter parent PPID 1 (/sbin/launchd)
    /// ```
    /// ⇒ **dissenter 正是本应用自己**（开着「接管访达的推出」的实例会 dissent 每一次
    /// unmount）。症状是这条测试连红 5 次，而输出里一个字都没提是谁占着。
    ///
    /// ⚠️ **等子进程用 `runAndAwaitExit`**（等 `terminationHandler` 回调），**不用**
    /// `waitUntilExit()` —— 本套件不标 `@MainActor` 的理由就是这个（§8.99 / §8.114 第 6 节），
    /// 而 `MainActorBlockingTests.测试代码里不许同步等子进程` 会盯这一处。
    ///
    /// ⚠️ **stderr 走临时文件而不是 `Pipe`**：`readDataToEndOfFile()` 是同步阻塞读，
    /// 会占住协作线程池的一根线程 —— 与上面同一条理由。进程已终止后再读文件没有这个问题。
    private static func dissenterHint(vol: String) async -> String {
        let tmp = NSTemporaryDirectory() + "de-dissent-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["unmount", vol]
        task.standardOutput = FileHandle.nullDevice
        let errFile = FileHandle(forWritingAtPath: tmp)
        task.standardError = errFile
        let status = await runAndAwaitExit(task)
        try? errFile?.close()
        // 退出码 0 = 居然卸掉了（那上面的 .busy 另有原因）⇒ 这条提示没用，别打
        guard status != 0,
            let text = try? String(contentsOfFile: tmp, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return "" }

        return """

            占用列表是空的但系统仍说忙 ⇒ 忙的是**审批会话 dissenter**（不是进程）。
            最常见的 dissenter 是**本应用自己**：开着「接管访达的推出」的实例会 dissent
            每一次 unmount ⇒ 跑这条测试前请先退出 /Applications/SafeOut.app
            （或关掉那个开关）。`diskutil unmount` 的原话：
            \(text)
            """
    }

    /// 未找到测试盘时那段失败文本。
    ///
    /// 抽成纯函数是为了**可被断言** —— `Issue.record` 里的字符串在测试里取不到
    /// （同 ``WaitOutcome/failureNote(_:)`` 抽出来的理由）。
    /// 少了这层，「消息里有没有那四条证据」就退化成一条**约定**，没人守得住：
    /// 谁把 `①②③④` 删掉两条，不会有任何东西变红。
    /// 见 `未找到测试盘时的诊断必须带上四条证据与数字`。
    private static func notFoundDiagnostic(vol: String, outcome: WaitOutcome) -> String {
        """
        未找到测试盘 \(vol)
        \(outcome.failureNote("等它出现在 fetchExternalDisks() 里"))
        ① 系统挂载列表里有它吗：\(Self.mountListHas(vol))
        ② 只喂它一个 URL 给 fetchExternalDisks()：\(Self.enumerateOnly(vol))
           （空 = DiskArbitration 还描述不出它 / 判定为不可推出；非空 = 枚举本身能认它）
        ③ 现在看到的外部盘：\(Self.currentExternalPaths())
        ④ 系统挂载点：\(Self.systemMounts())
        """
    }

    /// ① 系统挂载列表里有它吗 —— 分开「根本没挂上」与「挂上了」。
    private static func mountListHas(_ vol: String) -> Bool {
        DiskService.liveMountedVolumeURLs().contains { $0.path == vol }
    }

    /// ② **只喂它一个 URL** 给 `fetchExternalDisks()`。
    ///
    /// 空 = DiskArbitration 那一刻还描述不出它（或判定为不可推出）；
    /// 非空 = 枚举本身能认它 ⇒ 失败是**时点**问题。
    ///
    /// 走的是 `fetchExternalDisks(mountedVolumeURLs:)` 这个**既有的注入点** ——
    /// 诊断不需要在生产代码里加任何东西。
    private static func enumerateOnly(_ vol: String) -> [String] {
        DiskService.shared.fetchExternalDisks(
            mountedVolumeURLs: { [URL(fileURLWithPath: vol)] }
        ).map(\.mountPath)
    }

    /// ③ 现在看到的外部盘。
    private static func currentExternalPaths() -> [String] {
        DiskService.shared.fetchExternalDisks().map(\.mountPath)
    }

    /// ④ 系统挂载点。
    private static func systemMounts() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
            .map(\.path)
    }

    /// 探测当前环境能否挂载磁盘映像**并往卷里写文件**：尝试挂载、写入、再立即卸载一个最小 dmg。
    /// 成功返回 true（顺带清理），失败返回 false（测试将跳过）。
    ///
    /// **为什么探针必须连「可写」一起探**：受管 / 嵌套沙箱会**放行 `hdiutil attach`，却拦下
    /// 对挂载点的写入**（`atomically: true` 要在同卷建临时目录，那一步被拒）。只探「能挂载」
    /// 会把这类环境误判成可用，随后在真正写文件时抛错 —— 既误报成产品缺陷，又因为当时
    /// `defer` 尚未注册而留下挂载残留。所以这里用与测试**完全相同**的写法探一次可写性。
    /// ⚠️ **本函数是 `async`，不是为了并发**（2026-09-22）：里面的 `hdiutil` 一律走
    /// ``runAndAwaitExit``（等 `terminationHandler` **回调**），**不用 `waitUntilExit()`** ——
    /// 后者同步阻塞、不让路，占住的是**协作线程池**里的一根线程（池大小 ≈ 核数），
    /// CI 上核数更少 ⇒ 几处并发阻塞就让整个进程停摆（§8.114 第 6 节）。
    private static func canAttachDiskImage() async -> Bool {
        let dmg = "/tmp/DiskEjectorCanary.dmg"
        let vol = "/Volumes/DiskEjectorCanary"
        let s = { (cmd: String) async -> Bool in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", cmd]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            // `nil`（没跑起来）与「跑起来但退出码非 0」都算失败 —— 这里只关心「成没成」。
            return await runAndAwaitExit(task) == 0
        }

        guard await s("hdiutil create -size 1m -fs HFS+ -volname DiskEjectorCanary \(dmg)") else {
            return false
        }
        guard await s("hdiutil attach \(dmg) -nobrowse") else {
            _ = await s("rm -f \(dmg)")
            return false
        }

        let writable =
            (try? "probe".write(toFile: "\(vol)/.write-probe", atomically: true, encoding: .utf8)) != nil

        _ = await s("hdiutil detach \(vol)")
        _ = await s("rm -f \(dmg)")
        return writable
    }

    /// ⚠️ **本函数是 `async`**（2026-09-22）：理由同 ``canAttachDiskImage()`` ——
    /// `waitUntilExit()` 占住的是协作池的一根线程，**「搬出主 actor」并不等于「不阻塞」**。
    ///
    /// ⚠️ 因为它变成了 `await`，**调用处不能再放进 `defer`**（`defer` 里不许出现 `await`）——
    /// 见 `真实占用时关闭进程并推出` 里那段「正文包进局部函数」的说明。
    private func shell(_ command: String) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard let status = await runAndAwaitExit(task) else {
            throw NSError(
                domain: "shell", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法启动：\(command)"])
        }
        if status != 0 {
            throw NSError(
                domain: "shell", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: command])
        }
    }

    // MARK: - 装置自己的守卫

    /// **等待装置自己的守卫**（与 `ProcessAppResolverTests.等待可执行路径超时时必须报出轮询次数与耗时`
    /// 同一口径、同一个 ``WaitOutcome``）。
    ///
    /// 没有它，「`waitForDisk` 等到了」与「`waitForDisk` 只查了一次」在输出上**逐字相同** ——
    /// 而后者会让这条测试重新变成 2026-09-21 那次偶发（那次的病根正是「只查一次」）。
    /// 探针可注入，所以这条守卫**不碰任何真磁盘**、恒可运行。
    ///
    /// ⚠️ **探针只隔离了被测逻辑，没隔离「循环退出条件」** —— 2026-09-21 这条守卫自己在 CI 上
    /// 红过一次（§8.118）：`[nil, nil, disk]` 要求「第 3 拍」，而当时退出条件里的墙钟被
    /// **一次** `await`（runner 上实测拖了 ~6.1s）整个吃掉 ⇒ 第 3 拍永远没发生。
    /// ⇒ 当时只好把断言退到「第 1 或第 2 拍」。
    ///
    /// ⚠️ **2026-09-23（§8.132）根因修掉了**：退出条件换成**轮询预算**，墙钟只当安全网。
    /// ⇒「第 N 拍才成立」不再与负载挂钩（见 `每拍被拖长时不再误报超时`，那里用**第 3 拍**）。
    /// 下面 ① 仍用第 2 拍，因为它钉的是**另一件事**：「求值了不止一次」。
    @Test func 等待测试盘的装置必须真的轮询并且能超时() async {
        let disk = Self.probeDisk

        // ① 第 1 拍 nil、第 2 拍给盘 —— 必须等到，且恰好 2 拍。
        //
        // 为什么 2 拍是**结构上**确定的（与调度无关）：`[nil, disk]` 下两条路都在第 2 次
        // 求值拿到盘 ——
        //   快路：循环里第 1 拍 nil → 睡 → 第 2 拍拿到盘（在循环里 `return`）；
        //   慢路：第 1 拍 nil → 睡过头 ⇒ 退出循环 → **补查**（也是第 2 拍）拿到盘。
        // ⇒ `polls == 2` 与调度无关，而「求值了不止一次」仍被钉住（M1 变异仍红）。
        let late = ScriptedProbe([nil, disk])
        // 拍间隔压到 1ms：这条钉的是「求值了几次」，不是「等多久」 ⇒ 不该随 runner 抖动
        // （CI 上一拍实测能拖到 ~7.2s，用默认值的话这三条守卫每条都要 7 秒）。
        let waited = await Self.waitForDisk(pollIntervalNS: 1_000_000) { await late.next() }
        #expect(waited.outcome.ok, "第 2 拍才出现的盘没被等到：\(waited.outcome.diagnostic)")
        #expect(
            waited.disk == disk,
            "等到的那块盘必须从轮询里带出来（不是外面再查一次），实得 \(String(describing: waited.disk))")
        #expect(
            waited.outcome.polls == 2,
            "第 1 拍 nil、第 2 拍给盘 ⇒ 恰好 2 次求值，实得 \(waited.outcome.polls)")
        #expect(
            waited.outcome.stopReason == .conditionMet,
            "等到了 ⇒ 必须是「条件成立」，实得 \(waited.outcome.stopReason)")

        // ② 恒不出现：必须**放弃**（不挂住），且拍数 ≥ 2。
        // ⚠️ 这条断言 `.budgetExhausted` ⇒ 安全网**必须**由实测最坏单拍派生（§8.135）：
        // 写死成 6s 时，CI 上一拍（~7.2s）就把它吃掉 ⇒ 出口翻成「没看够」。
        let never = ScriptedProbe([])
        let timedOut = await Self.waitForDisk(
            pollBudget: 1,
            hardCeilingMS: WaitOutcome.derivedCeilingMS,
            pollIntervalNS: 1_000_000
        ) { await never.next() }
        #expect(timedOut.disk == nil, "恒不出现却拿到了盘：\(String(describing: timedOut.disk))")
        #expect(!timedOut.outcome.ok, "恒不出现 ⇒ `ok` 必须是 false")
        #expect(
            timedOut.outcome.polls >= 2,
            "至少要有「循环里那次」与「放弃后那次补查」两次求值，实得 \(timedOut.outcome.polls)")
        #expect(
            timedOut.outcome.stopReason == .budgetExhausted,
            "预算 1 拍花完而放弃 ⇒ 必须报「看够了」，实得 \(timedOut.outcome.stopReason)")

        // ③ 第 1 拍就出现 ⇒ 恰好 1 拍。**反向对照**：证明 ① 的 `polls == 2` 不是恒真。
        let immediate = ScriptedProbe([disk])
        let fast = await Self.waitForDisk(pollIntervalNS: 1_000_000) { await immediate.next() }
        #expect(fast.outcome.polls == 1, "第 1 拍就出现 ⇒ 恰好 1 拍，实得 \(fast.outcome.polls)")
        #expect(fast.disk != nil, "第 1 拍就出现的盘必须被带出来")

        // ④ `pollBudget: 0` ⇒ **循环体一次都不跑**，盘只能靠「放弃后那次补查」拿到。
        //
        // 这条钉的是 ② 钉不住的那一半：② 的 `polls >= 2` 在「循环自己跑了两拍」时同样成立，
        // 所以**把补查整块删掉不会有任何东西变红**（M4）。这里循环没有机会跑，
        // 拿到盘就只可能是补查干的 ⇒ `polls == 1` 与调度无关（循环跑没跑都是 1）。
        let noLoop = ScriptedProbe([disk])
        let caughtUp = await Self.waitForDisk(
            pollBudget: 0, pollIntervalNS: 1_000_000
        ) { await noLoop.next() }
        #expect(
            caughtUp.disk != nil,
            "循环没机会跑时，盘必须靠补查拿到（补查被删就退化成 nil）")
        #expect(
            caughtUp.outcome.ok,
            "循环没机会跑时 `ok` 仍应为 true：\(caughtUp.outcome.diagnostic)")
        #expect(
            caughtUp.outcome.polls == 1,
            "循环没跑 + 补查 1 次 ⇒ 恰好 1 拍，实得 \(caughtUp.outcome.polls)")
    }

    /// **「墙钟不再说了算」的守卫**（2026-09-23，§8.132）—— 这条待办的收官判据。
    ///
    /// 要证的是：**每拍被拖长**（2026-09-21 CI 上实测一次 `Task.sleep(50ms)` 拖到 ~6.1s）
    /// 不再让等待**误报超时**，而只是让它**多等一会儿**。
    ///
    /// ## 装置自证：拿「改动前的写法」当阳性对照
    ///
    /// 只断言「新写法成功了」**证明不了任何事** —— 它可能是这份探针根本没制造出旧状态
    /// （本仓库最贵的那条坑：装置报绿有三种可能，其中一种是**装置死了**）。
    /// ⇒ 这里**同时跑一份参考实现**（``refWallClockOnly``，逐字保留改动前的退出条件：
    /// 只看墙钟），给它一个**比每拍耗时还短的窗口**：它**必须失败**。
    /// 两边用**同一份探针脚本**，差别只有退出条件。
    ///
    /// ⚠️ 这条也是「**N ≥ 3 的守卫**」——§8.118 那条禁令（守卫里不许写「第 N 拍才成立」，
    /// N ≥ 3）的**前提**是「退出由截止时间决定 ⇒ 拍数随负载变」，而那个前提已经不存在。
    /// 禁令不是被无视，是**随根因一起作废**（订正见 §8.132）。
    @Test func 每拍被拖长时不再误报超时() async {
        let disk = Self.probeDisk

        // ① 参考实现（改动前的写法）：窗口 10ms ≪ 每拍 50ms ⇒ 只够看 1 拍，第 3 拍**永远没发生**。
        let refProbe = ScriptedProbe([nil, nil, disk])
        let ref = await Self.refWallClockOnly(timeout: 0.01) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await refProbe.next()
        }
        #expect(
            !ref.outcome.ok,
            """
            阳性对照：参考实现（纯墙钟）在这份脚本下**必须**失败 —— 它不失败，就说明这份探针
            根本没制造出旧状态，下面 ② 的结论一并作废
            """)
        #expect(
            ref.outcome.polls == 2,
            "参考实现：窗口只够 1 拍 + 补查 1 拍 ⇒ 恰好 2 拍，实得 \(ref.outcome.polls)")

        // ② 新写法：同一份脚本，预算 40 拍 ⇒ 第 3 拍照常发生 ⇒ 等到。
        let newProbe = ScriptedProbe([nil, nil, disk])
        // ⚠️ 拍间隔**保持默认 50ms**：这条验的正是「每拍被拖长」，压小就把它自己消掉了。
        // 安全网改成派生：探针第 3 拍才给盘，3 拍 × 最坏 7.2s = 21.6s ⇒ 原来写死的 30s
        // 只剩 1.4× 余量，runner 再慢一点就会把「等到了」误判成「没看够」。
        let now = await Self.waitForDisk(
            pollBudget: 40, hardCeilingMS: WaitOutcome.derivedCeilingMS
        ) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await newProbe.next()
        }
        #expect(
            now.outcome.ok,
            "每拍被拖长 ⇒ 应该**多等一会儿**，不该误报超时：\(now.outcome.diagnostic)")
        #expect(
            now.outcome.polls == 3,
            "第 3 拍才给盘 ⇒ 恰好 3 次求值，实得 \(now.outcome.polls)")
        #expect(now.disk == disk, "等到的那块盘必须带出来")
    }

    /// **两个出口都要有牙**（2026-09-23，§8.132）：预算花完（看够了）与安全网到点（没看够）
    /// 必须**各自可被观测** —— 否则「分清真因」只是文档里的一句话。
    ///
    /// ⚠️ **① 曾经在这里红过一次**（CI run `35783127520`，2026-09-23，§8.135）：安全网当时
    /// 写死 **6s**，而 CI 上**一拍**就吃掉 ~7.2s ⇒ 出口从「看够了」翻成「没看够」。
    /// 病根是余量**拿名义的 50ms 算**（120×，看着很宽），而不是拿实测最坏单拍算（**0×**）。
    /// ⇒ 现在安全网由 ``WaitOutcome/derivedCeilingMS`` 派生（72s），拍间隔压到 1ms ⇒ 预算名义时长 2ms。
    /// 两层是**各自独立**的保险：即便有人把拍间隔改回 50ms，最坏单拍 7.2s 也远小于 72s。
    @Test func 放弃时要分清看够了与没看够() async {
        let never = ScriptedProbe([])

        // ① **预算说了算**：预算 2 拍、每拍 1ms ⇒ 预算名义时长 2ms，而安全网 72s
        //    ⇒ 停下来的原因只可能是预算（差 4 个数量级，与负载无关）。
        let exhausted = await Self.waitForDisk(
            pollBudget: 2,
            hardCeilingMS: WaitOutcome.derivedCeilingMS,
            pollIntervalNS: 1_000_000
        ) {
            await never.next()
        }
        #expect(
            exhausted.outcome.polls == 3,
            "预算 2 拍 + 补查 1 拍 ⇒ 恰好 3 拍，实得 \(exhausted.outcome.polls)")
        #expect(
            exhausted.outcome.stopReason == .budgetExhausted,
            "预算先到 ⇒ 必须报「看够了」，实得 \(exhausted.outcome.stopReason)")

        // ② **安全网兜底**：预算 100 拍、安全网 200ms ⇒ 拍数必须**远小于**预算。
        //    ⚠️ 这条**刻意**保留默认拍间隔（50ms）：它要的就是「一拍比安全网还长」，
        //    把间隔压到 1ms 会让 100 拍只花 100ms ⇒ 变成预算先到，这条守卫就没了。
        //    这条判据刻意写成「小于」而不是某个具体拍数 —— 撞安全网时拍数**本来就**随负载变
        //    （那正是「没看够」的定义），钉死数字等于把调度延迟写进判据。
        let starved = await Self.waitForDisk(pollBudget: 100, hardCeilingMS: 200) {
            await never.next()
        }
        #expect(
            starved.outcome.stopReason == .ceilingHit,
            "安全网先到 ⇒ 必须报「没看够」，实得 \(starved.outcome.stopReason)")
        #expect(
            starved.outcome.polls < 100,
            "撞安全网时拍数必须**远小于**预算 —— 这正是「没看够」的判据，实得 \(starved.outcome.polls)")
        #expect(!starved.outcome.ok, "恒不出现 ⇒ `ok` 必须是 false")
    }

    /// 守卫用的**合成探针盘**：不碰任何真磁盘，恒可运行。
    private static let probeDisk = DiskInfo(
        id: "/Volumes/DiskEjectorWaitProbe",
        bsdName: "disk9s1",
        volumeName: "DiskEjectorWaitProbe",
        mountPath: "/Volumes/DiskEjectorWaitProbe",
        totalBytes: 1_000,
        usedBytes: 400,
        freeBytes: 600,
        deviceProtocol: "USB",
        deviceModel: nil
    )

    /// **参考实现 = 改动前的写法**（2026-09-23，§8.132）：退出条件**只看墙钟**。
    ///
    /// ⚠️ **只用来当阳性对照**，不是备用实现 —— 生产路径一律走 ``waitForDisk``。
    /// 保留它的理由见 `每拍被拖长时不再误报超时`：「新写法成功了」这句话只有在
    /// **旧写法在同一份脚本下会失败**时才成立。
    ///
    /// ⚠️ 它的 `stopReason` 在放弃时是 ``WaitOutcome/StopReason/ceilingHit`` ——
    /// 对这份实现来说**语义是对的**：停下来的是墙钟，不是「看够了」。
    private static func refWallClockOnly(
        timeout: TimeInterval,
        probe: @Sendable () async -> DiskInfo?
    ) async -> (outcome: WaitOutcome, disk: DiskInfo?) {
        let started = Date()
        var polls = 0
        let deadline = started.addingTimeInterval(timeout)
        while Date() < deadline {
            polls += 1
            if let disk = await probe() {
                return (
                    WaitOutcome(
                        stopReason: .conditionMet, polls: polls,
                        elapsed: Date().timeIntervalSince(started)),
                    disk
                )
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        polls += 1
        let found = await probe()
        return (
            WaitOutcome(
                stopReason: found != nil ? .conditionMet : .ceilingHit, polls: polls,
                elapsed: Date().timeIntervalSince(started)),
            found
        )
    }

    /// **失败诊断的守卫**：那段文本必须带上「在找哪个卷」、求值次数，以及**四条证据**。
    ///
    /// 上面那条覆盖不到这里 —— `notFoundDiagnostic` 只在**真失败**时才被调用，
    /// 而「四条证据少了两条」不会有任何东西变红（同 ``WaitOutcome`` 文件头说的那个病）。
    @Test func 未找到测试盘时的诊断必须带上四条证据与数字() {
        let vol = "/Volumes/DiskEjectorNotThere"
        let message = Self.notFoundDiagnostic(
            vol: vol, outcome: WaitOutcome(stopReason: .budgetExhausted, polls: 7, elapsed: 1.25))

        #expect(message.contains(vol), "诊断里没有「在找哪个卷」：\(message)")
        #expect(message.contains("7"), "诊断里没有求值次数（``WaitOutcome`` 的口径）：\(message)")
        for label in ["①", "②", "③", "④"] {
            #expect(message.contains(label), "诊断少了 \(label) 那条证据 —— 三种可能就分不开了：\(message)")
        }

        // 装置自证：`systemMounts()` 恒应看到 `/`。看不到 ⇒「④ 系统挂载点：[]」与
        // 「诊断装置瞎了」**逐字相同**（§8.96.4），那段输出就不可信。
        #expect(
            Self.systemMounts().contains("/"),
            "诊断拿不到系统挂载点（连 `/` 都没有）⇒ 那条输出不可信")
        // 反向对照：`mountListHas` 不能恒为 true，否则 ① 那条证据没有信息量。
        #expect(
            !Self.mountListHas("/Volumes/__DiskEjectorNoSuchVolume__"),
            "不存在的卷被判成「已挂载」⇒ `mountListHas` 恒为 true，① 等于没打")
    }
}

/// 按脚本逐拍给出答案的探针。
///
/// 用 `actor` 而不是裸 `var`：`probe` 是 `@Sendable`，捕获可变状态会被编译器拒绝
/// （与 `OccupancyStoreTests.CallCounter` 同一处理）。
private actor ScriptedProbe {
    private var answers: [DiskInfo?]
    init(_ answers: [DiskInfo?]) { self.answers = answers }
    func next() -> DiskInfo? { answers.isEmpty ? nil : answers.removeFirst() }
}
