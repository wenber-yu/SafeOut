import Darwin
import Foundation

/// 「礼貌退出 → 宽限 → 强制退出」的**同步**实现。
///
/// ## 为什么从 ``EjectFlowController`` 下沉出来
///
/// 1. DA approval 回调是 `@convention(c)`，**不能 await**，而 ``EjectFlowController`` 是
///    `@MainActor` —— 在回调线程上同步用它只能再套一层信号量，多一个死锁面；
/// 2. 清场逻辑（信号顺序、宽限时长、`EPERM`/`ESRCH` 的处理）是本仓库最危险的一段代码，
///    它需要**能离线单测**，而 `@MainActor` + 真 `kill` 让它只能靠真机验证。
///
/// ## 与既有推出流程的关系
///
/// ``clear(_:termGrace:killGrace:kill:isAlive:sleep:)`` 的时序与信号
/// （`SIGTERM` → 1.5s → 复检 → `SIGKILL` → 0.8s）与
/// ``EjectFlowController/terminateAndEject(disk:processes:awaiting:)`` **同值**，
/// 所以「复用既有推出流程的终止策略」这条仍然成立 —— 复用的是策略本身，
/// 只是把它从主 actor 的编排里下沉成可同步调用的形式。
/// ``signal(_:signal:selfPid:kill:)`` 是单相位原语，``EjectFlowController`` 现在也走它，
/// 保证两边只有一份实现。
enum ProcessTerminator {

    /// `SIGTERM` 之后的宽限（秒）—— 与 ``EjectFlowController/terminateAndEject(disk:processes:awaiting:)`` 同值。
    static let termGrace: TimeInterval = 1.5
    /// 复检后对残留升级 `SIGKILL`，再等这段时间（秒）—— 同值。
    static let killGrace: TimeInterval = 0.8

    /// 向一批进程发**同一个**信号，返回「没能送达」的那些。
    ///
    /// - Returns: 无法终止的进程。
    ///   - `ESRCH`（进程已不存在）**不计入** —— 它已经没了，对调用方等于成功；
    ///   - `EPERM`（无权终止，如系统进程）与其他失败**如实计入**，UI 会告知用户哪些关不掉；
    ///   - **自身 PID 不计信号、直接计入** —— 不自杀。否则会出现「本应用把自己杀掉」这种灾难。
    ///
    /// ⚠️ **双重防线（2026-10-23，DMG 占用检测引入）**：
    /// 1. `kind != .process` 的条目（磁盘映像）**跳过**——它们没有可发信号的 pid，
    ///    「关闭」动作是 `hdiutil detach`（``EjectFlowController`` 的清场第 0 步），
    ///    这里既不发信号也**不计入**无法终止（那会把「已分离」误报成「关不掉」）；
    /// 2. `pid <= 0` **跳过**——合成/占位 pid 若漏进 `kill()`，POSIX 语义是
    ///    「信号发给**整个进程组**」（`kill(0)` 包括本进程自己）。这是本仓库最危险的一类
    ///    误操作，哪怕第 1 条未来被改坏，这一条也必须兜住。
    nonisolated static func signal(
        _ processes: [OccupyingProcess],
        signal: Int32,
        selfPid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        kill: (Int32, Int32) -> Int32 = { pid, sig in Darwin.kill(pid, sig) }
    ) -> [OccupyingProcess] {
        var unkillable: [OccupyingProcess] = []
        for process in processes {
            // 防线 1 + 2：非进程条目与非法 pid 都不在信号语义内（见函数头注释）。
            guard process.kind == .process, process.pid > 0 else {
                continue
            }
            guard process.pid != selfPid else {
                unkillable.append(process)
                continue
            }
            errno = 0
            if kill(process.pid, signal) != 0 {
                if errno == ESRCH {
                    // 进程已不存在：视为成功，不计入无法关闭。
                    continue
                }
                unkillable.append(process)
            }
        }
        return unkillable
    }

    /// 清场。**阻塞当前线程** `termGrace + killGrace`（默认 2.3s）。
    ///
    /// 四步（与 ``EjectFlowController/terminateAndEject(disk:processes:awaiting:)`` 同款）：
    /// 1. 对全部进程发 `SIGTERM`（礼貌退出，让应用有机会存盘）；
    /// 2. 等 `termGrace`；
    /// 3. **复检**，对仍然活着的（含「无权发信号」的）升级 `SIGKILL`；
    /// 4. 等 `killGrace` 让 `SIGKILL` 落地。
    ///
    /// ⚠️ **第 3 步的复检为什么不能省**：调用方（``EjectHookService``）在清场之后会
    /// **放行**访达自己的 unmount。若此时还有进程活着，访达就会拿到 `fBsyErr` 并
    /// **弹它自己的报错框** —— 而「访达不弹报错框」正是本功能最大的价值点。
    /// 只对「`SIGTERM` 都没送达」的进程升级 `SIGKILL` 是不够的：
    /// 收到 `SIGTERM` 却忽略它的应用（导出中的视频播放器等）恰恰是最常见的那类。
    ///
    /// - Parameters:
    ///   - kill: 注入点（默认 `Darwin.kill`）。测试注入替身即可**完全离线**断言
    ///     「谁在第几步收到了哪个信号」，不必真的 fork 进程。
    ///   - isAlive: 复检用的存活判据（默认 `kill(pid, 0)`；`EPERM` 也算活着）。
    ///     与 `kill` 分开注入，是为了让「全部已退出 ⇒ 不发 SIGKILL」这条判据
    ///     能被一条单测钉住，而不必让替身去解释「信号 0 是什么意思」。
    ///   - sleep: 注入点（默认 `Thread.sleep`）。测试注入空实现 ⇒ 单测**不花 2.3s**。
    /// - Returns: **关不掉的**进程（`EPERM`、复检仍活着的、以及自身 PID）。已消失（`ESRCH`）不算。
    nonisolated static func clear(
        _ processes: [OccupyingProcess],
        termGrace: TimeInterval = ProcessTerminator.termGrace,
        killGrace: TimeInterval = ProcessTerminator.killGrace,
        kill: @escaping (Int32, Int32) -> Int32 = { pid, sig in Darwin.kill(pid, sig) },
        isAlive: @escaping (Int32) -> Bool = { pid in ProcessTerminator.defaultIsAlive(pid) },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> [OccupyingProcess] {
        guard !processes.isEmpty else { return [] }
        let selfPid = Int32(ProcessInfo.processInfo.processIdentifier)

        // 第 1 步：SIGTERM 礼貌退出。
        let unkillableAfterTerm = signal(processes, signal: SIGTERM, selfPid: selfPid, kill: kill)

        // 第 2 步：宽限，让应用有机会存盘。
        sleep(termGrace)

        // 第 3 步：复检，仍活着的升级 SIGKILL。
        //
        // ⚠️ 与 ``signal(_:signal:selfPid:kill:)`` 同款防线：**只复查真进程**。
        // 磁盘映像条目若进这里，`isAlive` 会对一个合成负 pid 调 `kill(pid, 0)`
        // （进程组语义），判「活着」还会把它追加进「关不掉」清单——一句谎话。
        let escalated = processes.filter { process in
            guard process.kind == .process, process.pid > 0 else { return false }
            guard process.pid != selfPid else { return false }
            if unkillableAfterTerm.contains(where: { $0.pid == process.pid }) { return true }
            return isAlive(process.pid)
        }
        if !escalated.isEmpty {
            _ = signal(escalated, signal: SIGKILL, selfPid: selfPid, kill: kill)
        }

        // 第 4 步：让 SIGKILL 落地。
        sleep(killGrace)

        // 「关不掉」= SIGTERM 阶段就没送达的 + 复检仍活着的。自身 PID 天然在内。
        var remaining = unkillableAfterTerm
        let remainingPids = Set(remaining.map(\.pid))
        for process in escalated where !remainingPids.contains(process.pid) {
            remaining.append(process)
        }
        return remaining
    }

    /// 默认存活判据：`kill(pid, 0)`。
    ///
    /// - `0`（信号已送达）⇒ 活着；
    /// - `EPERM` ⇒ **存在但无权发信号** ⇒ 也算活着（那正是关不掉、必须如实交回 UI 的）；
    /// - `ESRCH` ⇒ 已消失。
    private static func defaultIsAlive(_ pid: Int32) -> Bool {
        errno = 0
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
