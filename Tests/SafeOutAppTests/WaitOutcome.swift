import Foundation
import Testing

/// 一次「轮询等待」的结果。
///
/// ## 为什么不是 `Bool`（2026-09-21）
///
/// 三个等待 helper 原来只返回 `Bool`（`OccupancyStoreTests.waitUntil`、
/// `ProcessAppResolverTests.waitForExecutablePath`、`IntegrationEjectTests.waitForDisk`），
/// 失败信息分别是「`arrived` 为 false」「`ready` 为 false」。
///
/// ⚠️ **2026-09-22 起 `OccupancyStoreTests` 不再用本类型** —— 它那条等待换成了
/// **等事件**（见 ``EventWait``）：轮询在 CI 上会被主 actor 排队误报成「条件不成立」，
/// 而事件等待在结构上没有这个失败形态。本类型现在服务的是**剩下两条真在等条件成立**的轮询。
///
/// 2026-09-17 CI 上真红过一次，而那句话**什么都没说明** —— 它把两件修法完全不同的事
/// **渲染成同一句话**：
///
/// - **主 actor 被别的用例占住**，等待链根本没被轮到（并发争抢，改法在测试侧）；还是
/// - **条件确实很久不成立**（被测逻辑有问题，改法在生产代码）。
///
/// ⇒ 与 §8.113.12「门槛红了却拿到一个假名字」同一条轴：**报错必须指名真因**。
///
/// ## ⚠️ 2026-09-23：退出条件从「墙钟到点」换成「看够了次数」（§8.132）
///
/// 原来两个 helper 的循环都是 `while Date() < deadline` —— **墙钟说了算**。
/// 于是上面那两件事**在结构上分不开**：负载一高，`deadline` 会被一次 `await` 整个吃掉。
/// 2026-09-21 CI 实测**一次** `Task.sleep(50ms)` 拖到 ~6.1s：`timeout: 5` 的窗口没了
/// ⇒ 第 3 拍**永远没发生** ⇒ 守卫自己红（§8.118）。
/// 当时用「守卫里不许写第 N 拍才成立（N ≥ 3）」**绕开**了它 —— 那是把**判据写弱**，
/// 循环本身还是墙钟说了算。
///
/// ⇒ 现在退出条件改成**轮询预算**，墙钟降级成**安全网**（只防挂死）：
///
/// | 写法 | 谁决定退出 | 负载高了会怎样 |
/// |---|---|---|
/// | 旧 `while Date() < deadline` | 墙钟 | **提前放弃** ⇒ 误报「条件不成立」 |
/// | 新 `while polls < budget` | 次数 | **多等一会儿** ⇒ 结论不变 |
///
/// 三条推论：
///
/// 1. ``polls`` 现在**结构上**与负载无关（迭代次数由预算决定）
///    ⇒「第 N 拍才成立」的守卫**可以**写了（N ≥ 3 也行）——
///    那条禁令的前提（退出由截止时间决定）已经不存在；
/// 2. ``elapsed`` 仍然**只用来报告**：它照样含排队时间，不能当门槛
///    （同病：§8.113.18 查清的 `passed after` 也是「完成时刻」而非该测试自身耗时）；
/// 3. 真放弃时**必须说清是哪一种**（见 ``StopReason``）——「看够了」与「没看够」
///    的改法完全不同。
struct WaitOutcome: Sendable {

    /// **实测过的最坏单拍耗时**（毫秒）—— 两条轮询等待的**安全网余量**都拿它算。
    ///
    /// ## 为什么有这个常量（2026-09-23，§8.135：CI 真红过一次）
    ///
    /// CI 上 `放弃时要分清看够了与没看够` 红了一次：安全网当时写死 **6s**，而
    /// **CI 上一拍（一次 `Task.sleep(50ms)`）实测能拖到 ~7.2s** ⇒
    /// 拿名义的 50ms 算是 **120×** 余量，拿实测最坏单拍算是 **0×** —— 必撞，
    /// 出口于是从「看够了」翻成「没看够」（`polls: 2, stopReason: .ceilingHit`）。
    ///
    /// ⚠️ 那两个数当时**写在同一个文件里**（注释里写着「实测最坏 ~6.1s」，下一句却选 6s），
    /// 而没有任何东西会因为两个数打架而变红 ⇒ 现在改成**一处真相 + 派生**。
    ///
    /// | 出处 | 实测值 | 场合 |
    /// |---|---|---|
    /// | §8.118（2026-09-21） | ~6.1s | 一次 `Task.sleep(50ms)` 在 CI 上被拖长 |
    /// | CI run `35783127520`（2026-09-23） | ~7.2s | 同上，并把守卫的出口翻成「没看够」 |
    ///
    /// ⚠️ 取 **7.2s**（两次里更糟的）。它**不是**推算出来的，是从 CI 日志
    /// `failed after 7.579 seconds` 反推的（其中约 0.2s 是同一测试里 ② 那半段）
    /// ⇒ 够用来定余量，但别当成精确实测值。
    /// ⚠️ **它一过期，由它派生的安全网就又退化成名义值** ⇒ CI 若更慢，要跟着实测更新。
    /// ℹ️ **它进不了断言**：本地一拍就是 50ms，把安全网改回 6s 本地照样全绿
    /// ⇒ 「安全网够不够大」**在本地做不出回归测试**，只有 CI 能守住它（§8.135.7）。
    static let worstObservedPollMS = 7_200

    /// 由 ``worstObservedPollMS`` **派生**的默认挂死上限（毫秒）—— 两个等待 helper
    /// 的 `hardCeilingMS` 默认值与**所有断言 `.budgetExhausted` 的守卫**都用它。
    ///
    /// ×10 = 72s ≈ **10 拍的最坏情况**；而两条等待的实际预期拍数（等盘 ≤5、等进程路径 ≤3）
    /// 远小于它 ⇒ 正常与高负载下它都不该响。
    ///
    /// ⚠️ **它一旦响，墙钟就重新变成判据**：安全网是**真的中止等待**，不是「只报告」
    /// —— 一响，`stopReason` 就变 `.ceilingHit`，等待被掐断（§8.135.4）。
    /// ⇒「墙钟降级为安全网」这句话**只在它永不响时成立**。
    /// ⇒ **别在这里写死整数**：写死就等于把余量交回给名义值，那次红会原样重演。
    static let derivedCeilingMS = worstObservedPollMS * 10

    /// 循环为什么停下来。
    ///
    /// ⚠️ **这是唯一真相**，``ok`` 由它派生 —— 同一事实存两份必然漂，而**没有任何东西会红**
    /// （本仓库最贵的那条坑）。
    enum StopReason: Sendable {

        /// 条件成立，等到了。
        case conditionMet

        /// **看够了**：轮询预算花完，条件仍不成立 ⇒ 是被测逻辑的问题。
        case budgetExhausted

        /// **没看够**：撞上墙钟安全网 ⇒ 是排不上队 / 环境的问题，别怪被测逻辑。
        case ceilingHit
    }

    /// 循环为什么停下来（含退出循环后那一次补查的结果）。
    let stopReason: StopReason

    /// 条件被求值的次数（含退出循环后那一次补查）。
    let polls: Int

    /// 从开始等待到结束的墙钟耗时（含被调度拖走的时间）。
    let elapsed: TimeInterval

    /// 条件最终是否成立。**派生值** —— 别另存一份，那样两个字段会漂。
    var ok: Bool { stopReason == .conditionMet }

    /// 失败信息里带上数字与**真因** —— 下次 CI 红时**不用再猜**。
    ///
    /// ⚠️ 「看够了」与「没看够」必须**各有一句话**：两者在 `ok` / `polls` / `elapsed`
    /// 上都可能逐字相同，只有这句话能把下一个排查的人指向正确的方向。
    var diagnostic: String {
        let head = String(format: "等了 %.2fs、求值 %d 次，条件", elapsed, polls)
        switch stopReason {
        case .conditionMet:
            return head + "最终成立"
        case .budgetExhausted:
            return head + "始终不成立 —— **看够了**（轮询预算花完）⇒ 是被测逻辑的问题"
        case .ceilingHit:
            return head
                + "始终不成立 —— **没看够**（撞上墙钟安全网）⇒ 是排不上队/环境的问题，别怪被测逻辑"
        }
    }

    /// 失败信息：**调用处只补一句「在等什么」，数字一律从这里来**。
    ///
    /// 抽成纯函数是为了**可被断言**：``expectArrived`` 里那句 `#expect` 的消息
    /// 没法在测试里取到，而这里的返回值可以（见两个套件里的「等待 helper 自己的守卫」）。
    /// ⇒ 少了这层，「消息里到底有没有数字」就退化成一条**约定**，没人守得住。
    func failureNote(_ what: String) -> String {
        "\(what)\n\(diagnostic)"
    }
}

/// 断言「等到了」，失败信息里**一定**带 ``WaitOutcome/diagnostic``。
///
/// **为什么必须走这个函数，而不是各处手写 `#expect(x.ok, "…\(x.diagnostic)")`**：
/// 手写时「把 `diagnostic` 写进消息」只是**约定** —— 谁少写一次都不会有任何东西变红，
/// 而失败信息退化成「`arrived` 为 false」正是这次要修的病。
/// 走函数则**结构上**不可能漏：消息由 ``WaitOutcome/failureNote(_:)`` 唯一决定。
/// （同 §8.113.13「能派生就别用手动开关」。）
///
/// ⚠️ `sourceLocation` 的默认值让失败报在**调用处**而不是本函数里 ——
/// 少了它，CI 红的时候指向的是这个文件，等于又绕远路。
func expectArrived(
    _ outcome: WaitOutcome,
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(outcome.ok, "\(outcome.failureNote(what))", sourceLocation: sourceLocation)
}

/// 一次「等**事件**」的结果（与 ``WaitOutcome`` 的「等**条件成立**」相对）。
///
/// ## 为什么不是 ``WaitOutcome``（2026-09-22，账本第 35 行）
///
/// `WaitOutcome` 描述的是**轮询**：`polls`（求值几次）+ `elapsed`（墙钟）。
/// 而这里等的是一个**事件** —— 「求值几次」这个概念根本不存在：不是求值等到的，
/// 是事件把它叫醒的。
///
/// ⚠️ **不把两者混成一个类型**：混了之后「`polls` 小」到底是「事件来得快」
/// 还是「排不上队」又要靠猜 —— 那正是 §8.118 踩过的坑（`polls` 只在
/// 「迭代次数由**条件**决定」时才与负载无关）。
///
/// ## 唯一的判据是 ``arrivedByEvent``
///
/// 它把两条**修法完全不同**的路分开：
///
/// | 值 | 含义 | 该修哪儿 |
/// |---|---|---|
/// | `true` | 事件到了 | 不用修 —— 这正是期望的那条路 |
/// | `false` | 事件**从未发生**（兜底掐断的） | **接线断了**（`sink` 没接到 `refresh`），**不是**「排不上队」 |
///
/// ⚠️ ``elapsed`` 只用来**报告**：它同样包含排队时间，口径与 ``WaitOutcome/elapsed`` 一致，
/// **不能**当门槛（否则就是把机器的调度延迟写进判据，§8.118）。
struct EventWait: Sendable {

    /// 是**事件**结束的等待，还是**兜底**掐断的。
    let arrivedByEvent: Bool

    /// 墙钟耗时（含排队时间）。只报告，不下结论。
    let elapsed: TimeInterval

    var diagnostic: String {
        String(
            format: "等了 %.2fs，%@", elapsed,
            arrivedByEvent
                ? "事件到了"
                : "事件始终没发生 —— 这是**接线断了**（不是排不上队）："
                    + "查 `DiskListStore.$disks` 的 sink 有没有接到 `refresh`")
    }
}

/// 断言「事件到了」，失败信息里**一定**带 ``EventWait/diagnostic``。
///
/// 与 ``expectArrived`` 同一个理由：手写 `#expect(x.arrivedByEvent, "…\(x.diagnostic)")`
/// 时，「把 `diagnostic` 写进消息」只是**约定** —— 谁少写一次都不会有东西变红，
/// 而失败信息退化成「没等到」正是这次要修的病。
func expectEvent(
    _ outcome: EventWait,
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(outcome.arrivedByEvent, "\(what)\n\(outcome.diagnostic)", sourceLocation: sourceLocation)
}
