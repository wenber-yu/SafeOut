import Combine
import Foundation
import Testing

@testable import SafeOutApp

// MARK: - 替身与夹具

/// 线程安全的调用计数器（`detect` 闭包是 `@Sendable`，不能用裸 `var`）。
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// 把 `AsyncStream` 的 continuation 装进一个盒子。
///
/// **为什么需要**：`detect` 闭包是 `@Sendable`，直接捕获 `AsyncStream.Continuation?`
/// 那个 `var` 会被编译器拒绝（`reference to captured var in concurrently-executing code`）。
/// 盒子的写入只发生在建流那一刻、且早于任何一次 `detect` 调用，因此 `@unchecked` 是安全的。
private final class SignalBox: @unchecked Sendable {
    var continuation: AsyncStream<Void>.Continuation?
}

/// 造一块测试用磁盘。`id` 就是挂载路径（与生产一致：同路径即同一卷）。
private func makeDisk(_ path: String) -> DiskInfo {
    DiskInfo(
        id: path,
        bsdName: "disk9s1",
        volumeName: (path as NSString).lastPathComponent,
        mountPath: path,
        totalBytes: 1_000,
        usedBytes: 400,
        freeBytes: 600,
        deviceProtocol: "USB",
        deviceModel: nil
    )
}

/// 「只许触发一次」的旗标：事件与兜底**谁先到谁说了算**，后到的必须无声退出
/// （`CheckedContinuation` 二次 resume 会直接崩）。
///
/// ⚠️ **必须是引用类型**：`Task { }` 的闭包是 `@Sendable`，捕获一个 `var` 会被编译器拒
/// （`reference to captured var in concurrently-executing code`）—— 同 ``SignalBox`` 的说明。
@MainActor
private final class OnceFlag {
    private var fired = false
    /// 第一次调用返回 `true`，之后一律 `false`。
    func tryFire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// 等 `store` **下一次跑完一轮并写回 `results`** —— 事件驱动，**不轮询**。
///
/// ## 为什么把轮询换掉（2026-09-22，账本第 35 行）
///
/// 这里原来是一个 `while Date() < deadline { 求值; Task.sleep(10ms) }` 的轮询，
/// 超时从 3s 一路放宽到 30s。两次 CI 红都长这样：
///
/// ```text
/// WaitOutcome(ok: false, polls: 2, elapsed: 41.73)
/// ```
///
/// ⚠️ 那个形状现在**构造不出来**了（2026-09-23，§8.132）：`WaitOutcome` 的 `ok` 已改成
/// 从 `stopReason` 派生，而且「放弃」现在还必须说清是「看够了」还是「没看够」。
/// 本文件早已不用 `WaitOutcome`（换成了 ``EventWait``）⇒ 上面那段保留原句，只当**史实样本**。
///
/// ⇒ 那 10ms 的 `sleep` 睡了 41.7 秒才被唤醒，**循环根本没被调度**；
/// 而 `deadline` 是**墙钟** ⇒ 排一次队就把整个窗口吃掉，于是「排不上队」
/// 被报成了「条件始终不成立」。⇒ **延长超时只是抬门槛**（§8.113.20 的读数已证否这条路）。
///
/// 现在改成**等事件**：`results` 是 `@Published`，每跑完一轮都会发一次 `objectWillChange`。
/// 事件一到就返回，**与「等了多久」无关** ⇒ 「排不上队」在结构上不再可能造成误报。
///
/// ⚠️ 这与 `OccupancyStore` 里那条「加一个可 await 的刷新句柄」是同一个思路，
/// 但**不用改生产代码**：`objectWillChange` 本来就有，而且它**每跑完一轮必发一次**
/// （`performDetect` 结尾那次 `results = next`，哪怕值相等）。
///
/// ## 兜底**不在正常路径上**
///
/// `backstop` 只在「事件**从未**发生」时才会命中 —— 那意味着**接线断了**
/// （`$disks` 的 sink 没接到 `refresh`），而**不是**「排不上队」。
/// 两者修法完全不同，所以返回值（``EventWait``）把这两条路分开报。
///
/// ## ⚠️ 调用约定：触发与订阅之间**不许有 `await`**
///
/// `objectWillChange` **不重放**（它不是 `@Published` 那个会补发当前值的 publisher）：
/// 订阅之前发生的那次变更不会被补发。而「触发」在主 actor 上是**同步**的
/// （`replaceDisksForTesting` → sink → `Task { @MainActor in refresh }`，那个 Task 还排不上队）
/// ⇒ 只要中间不让出主 actor，就不存在「订阅前事件已经发生」的窗口。
@MainActor
private func waitForNextRound(
    _ store: OccupancyStore, backstop: TimeInterval = 120
) async -> EventWait {
    let started = Date()
    let flag = OnceFlag()
    var cancellable: AnyCancellable?
    let arrived = await withCheckedContinuation {
        (continuation: CheckedContinuation<Bool, Never>) in
        cancellable = store.objectWillChange.sink { _ in
            if flag.tryFire() { continuation.resume(returning: true) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(backstop * 1_000_000_000))
            if flag.tryFire() { continuation.resume(returning: false) }
        }
    }
    cancellable?.cancel()
    return EventWait(arrivedByEvent: arrived, elapsed: Date().timeIntervalSince(started))
}

/// 造一个不跑真实 lsof 的 store。`pollInterval` 默认给足，避免轮询干扰断言。
@MainActor
private func makeStore(
    diskStore: DiskListStore,
    pollInterval: TimeInterval = 3600,
    autoStart: Bool = false,
    detect: @escaping @Sendable (String) async -> OccupancyResult
) -> OccupancyStore {
    OccupancyStore(
        diskStore: diskStore, pollInterval: pollInterval, detect: detect, autoStart: autoStart)
}

// MARK: - 测试
//
// 这一组测试守的是 2026-09-15 用户报告的那个 bug：
// 「主窗口显示有程序在占用，菜单栏面板显示没有占用，这用的不是同一套逻辑吗？」
//
// 检测逻辑本来就是同一套；**分叉的是状态**——两个界面各持一个私有 `@State`，
// 各按各的节奏刷新（主窗口有 15s 轮询，面板没有）。所以这里钉的不是「检测函数对不对」，
// 而是「状态只有一份、节奏只有一条、读法只有一种」。

@Suite("占用结论的单一事实来源")
@MainActor
struct OccupancyStoreTests {

    @Test("结果按卷的挂载路径归档")
    func 结果按卷的挂载路径归档() async {
        let diskStore = DiskListStore(monitoring: false)
        let a = makeDisk("/Volumes/A")
        let b = makeDisk("/Volumes/B")
        let store = makeStore(diskStore: diskStore) { path in
            path.hasSuffix("/A") ? .none : .unknown
        }

        await store.refresh(disks: [a, b])

        #expect(store.results.count == 2)
        #expect(store.result(for: a) == .none)
        #expect(store.result(for: b) == .unknown)
    }

    /// **本文件最重要的一条**：读不到结论时的兜底必须是 `.unknown`。
    ///
    /// 兜成 `.none` 会让「还没测出来」显示成绿色的「可以安全推出」——
    /// 而 `.none` 与 `.unknown` 在类型上都是合法的 `OccupancyResult`，编译器不会拦。
    @Test("读不到结论的卷兜底为 unknown，绝不兜成 none")
    func 读不到结论的卷兜底为unknown() async {
        let diskStore = DiskListStore(monitoring: false)
        let store = makeStore(diskStore: diskStore) { _ in .none }
        let never = makeDisk("/Volumes/NEVER-MEASURED")

        #expect(
            store.result(for: never) == .unknown,
            "没测过的卷必须读成「占用情况未知」。读成 .none 就是「可以安全推出」——本应用最不能犯的错误")
    }

    @Test("磁盘拔出后它的旧结论必须消失")
    func 磁盘拔出后旧结论消失() async {
        let diskStore = DiskListStore(monitoring: false)
        let a = makeDisk("/Volumes/A")
        let b = makeDisk("/Volumes/B")
        let store = makeStore(diskStore: diskStore) { _ in .none }

        await store.refresh(disks: [a, b])
        #expect(store.results.count == 2)

        await store.refresh(disks: [a])

        #expect(
            store.results.count == 1,
            "整体替换而不是逐个合并——否则拔掉的盘会把旧结论永远留在字典里")
        #expect(store.results[b.id] == nil)
        #expect(store.result(for: a) == .none)
    }

    @Test("空磁盘列表清空全部结论")
    func 空磁盘列表清空全部结论() async {
        let diskStore = DiskListStore(monitoring: false)
        let store = makeStore(diskStore: diskStore) { _ in .none }
        await store.refresh(disks: [makeDisk("/Volumes/A")])
        #expect(!store.results.isEmpty)

        await store.refresh(disks: [])

        #expect(store.results.isEmpty)
    }

    @Test("检测结果原样透传，unknown 不会被降级成 none")
    func unknown不会被降级() async {
        let diskStore = DiskListStore(monitoring: false)
        let disk = makeDisk("/Volumes/A")
        let store = makeStore(diskStore: diskStore) { _ in .unknown }

        await store.refresh(disks: [disk])

        #expect(store.result(for: disk) == .unknown)
    }

    /// **并发刷新必须被「合并」，不能被「丢弃」**。
    ///
    /// 主窗口原来用的是「单飞 + 直接 return」：上一轮 lsof 没跑完时，新的请求被丢掉。
    /// 用户点「刷新」正好撞上后台轮询，那一次点击就静默失效 —— 界面停在旧值上，
    /// 看起来就是「点了没反应」。现在改成登记 `pending`，循环处理完上一批立刻接着处理。
    @Test("并发刷新会被合并，最后一次的磁盘列表一定生效")
    func 并发刷新被合并() async {
        let diskStore = DiskListStore(monitoring: false)
        let a = makeDisk("/Volumes/A")
        let b = makeDisk("/Volumes/B")
        let counter = CallCounter()

        // 用 AsyncStream 当「第一轮已开始」的信号，替代固定 sleep。
        let box = SignalBox()
        let started = AsyncStream<Void> { box.continuation = $0 }

        let store = makeStore(diskStore: diskStore) { _ in
            await counter.increment()
            box.continuation?.yield(())
            try? await Task.sleep(nanoseconds: 60_000_000)
            return .none
        }

        let first = Task { @MainActor in await store.refresh(disks: [a]) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()  // 等第一轮真的跑起来
        let second = Task { @MainActor in await store.refresh(disks: [a, b]) }
        await first.value
        await second.value
        box.continuation?.finish()

        #expect(
            store.results.count == 2,
            "第二次请求带上了 B，最终结果必须包含 B —— 被丢掉就说明「刷新」会静默失效")
        let calls = await counter.count
        #expect(calls >= 3, "A 测两次（两轮）+ B 测一次 = 3；只有 1 次说明第二次请求被丢了，实际 \(calls)")
    }

    /// **本文件第二条关键断言**：磁盘列表一变就必须重测。
    ///
    /// 面板上的「刷新磁盘列表」走的是 `DiskListStore.refresh()` —— 它每次都把新数组
    /// 赋给 `disks`。视图里原先用 `.onChange(of: store.disks)` 监听，而
    /// `.onChange` **只在值不相等时触发**：重新枚举了一遍但内容没变时，
    /// 它安静地什么都不做。`OccupancyStore` 改用 Combine `sink`，每次赋值都投递。
    @Test("磁盘列表一变就重测占用（刷新按钮真的会刷新占用结论）")
    func 磁盘列表一变就重测占用() async {
        let diskStore = DiskListStore(monitoring: false)
        let disk = makeDisk("/Volumes/NEW")

        let store = makeStore(diskStore: diskStore, autoStart: true) { _ in .none }
        defer { store.stop() }
        #expect(store.results.isEmpty)

        diskStore.replaceDisksForTesting([disk])
        // ⚠️ 触发与订阅之间**不许有 `await`**（见 ``waitForNextRound`` 的调用约定）。
        let arrived = await waitForNextRound(store)
        // ⚠️ 走 ``expectEvent`` 而不是手写 `#expect(arrived.arrivedByEvent, "…")`：
        // 消息里那句「等了多久、是事件到了还是接线断了」由 ``EventWait`` 唯一决定，调用处漏不掉。
        expectEvent(
            arrived,
            "DiskListStore.disks 一变，占用结论必须重测；"
                + "否则「刷新磁盘列表」只刷新容量数字、刷不动占用结论。")
        #expect(
            store.result(for: disk) == .none,
            "重测之后结论必须是 .none，实际 \(store.result(for: disk))")

        // 同一份列表再发一次（内容完全相同）：`.onChange` 会漏掉，`sink` 不会。
        let counter = CallCounter()
        let store2 = makeStore(diskStore: diskStore, autoStart: true) { _ in
            await counter.increment()
            return .none
        }
        defer { store2.stop() }
        // 首轮：`@Published` 的订阅会**立即投递当前值**，那一次投递就是首帧刷新。
        expectEvent(await waitForNextRound(store2), "store2 建好后必须跑完首轮")
        let afterFirst = await counter.count

        diskStore.replaceDisksForTesting([disk])  // 内容一模一样

        let retested = await waitForNextRound(store2)
        expectEvent(retested, "内容相同的一次重新枚举也必须重测——这正是 `.onChange` 漏掉的那种情况。")
        let afterRetest = await counter.count
        #expect(
            afterRetest > afterFirst,
            "内容相同也必须重测：内容一样时 `.onChange` 会静默什么都不做（实际 \(afterFirst) → \(afterRetest)）")
    }

    @Test("stop 之后不再响应磁盘列表变化")
    func stop之后不再响应() async {
        let diskStore = DiskListStore(monitoring: false)
        let counter = CallCounter()
        let store = makeStore(diskStore: diskStore, autoStart: true) { _ in
            await counter.increment()
            return .none
        }

        // 初始列表为空 → 首轮不会调用 detect（`performDetect` 对空列表直接返回），
        // 所以 baseline 一定是 0。等一会儿让首轮彻底排空，避免把「首轮还在跑」
        // 误当成「stop 之后仍在响应」。
        try? await Task.sleep(nanoseconds: 150_000_000)
        store.stop()
        let baseline = await counter.count

        diskStore.replaceDisksForTesting([makeDisk("/Volumes/AFTER-STOP")])

        // 给足时间让「本不该发生」的检测有机会发生。
        try? await Task.sleep(nanoseconds: 250_000_000)
        let afterStop = await counter.count
        #expect(
            afterStop == baseline,
            "stop() 之后订阅已解除，不该再有检测（实际多了 \(afterStop - baseline) 次）")
    }

    // MARK: - 等待装置自己的守卫

    /// 等事件的装置必须能把「**事件到了**」与「**接线断了**」分开报 —— **双向对照**。
    ///
    /// **为什么这条值得单独写**：它是本文件里唯一「守装置而不是守产品」的测试。
    /// 少了它，「失败信息里到底说的是哪条路」只能靠**下次 CI 真红**才发现 ——
    /// 而那正是 2026-09-17 发生过的（报出「`arrived` 为 false」，什么都没说明）。
    /// ⇒ 与 §8.113.12「门槛红了却拿到一个假名字」同一条轴。
    ///
    /// ⚠️ **两个方向都必须是确定性的**，不许依赖机器快慢：
    /// - **阴性**：`autoStart: false` ⇒ 没有任何东西会触发一轮 ⇒ 事件**永不发生**，
    ///   只能由兜底结束。这条同时证明 `arrivedByEvent` **不是恒真**。
    /// - **阳性**：`autoStart: true` + 一次**同步**的列表变更 ⇒ 走事件路。
    ///
    /// ⚠️ 断言的是 `arrivedByEvent`（一个**位**），**不是** `elapsed` ——
    /// 拿墙钟当门槛就是把调度延迟写进判据（§8.118 踩过，同一把尺子）。
    @Test("等事件的装置必须分开报「事件到了」与「接线断了」")
    func 等事件的装置必须分开报事件到了与接线断了() async {
        let diskStore = DiskListStore(monitoring: false)

        // ── 阴性对照：没有任何轮次 ⇒ 事件不可能到达，只能靠兜底结束。
        let idle = makeStore(diskStore: diskStore, autoStart: false) { _ in .none }
        defer { idle.stop() }
        let timedOut = await waitForNextRound(idle, backstop: 0.05)
        #expect(!timedOut.arrivedByEvent, "没有任何轮次，事件不可能到达：\(timedOut.diagnostic)")
        #expect(timedOut.elapsed >= 0.05, "墙钟不小于兜底值，实得 \(timedOut.elapsed)")
        // ⚠️ 只断言 `arrivedByEvent == false` **还不够**：`diagnostic` 才是给下一个排查的人
        // 看的那句话，而它完全可能被写成一句不带方向的话（那样等于没改）。
        #expect(
            timedOut.diagnostic.contains("接线"),
            "兜底失败必须指出「这是接线断了，不是排不上队」：\(timedOut.diagnostic)")
        // 真正给排查的人看的是 ``expectEvent`` 拼出来的那句话，它完全可能把 `diagnostic` 丢掉。
        // （断言只挑**与 locale 无关**的部分：`%.2f` 的小数点在某些 locale 下会变逗号。）
        #expect(
            timedOut.diagnostic.contains("s，"),
            "诊断串里没带出实际数字：\(timedOut.diagnostic)")

        // ── 阳性对照：真的触发一轮 ⇒ 走事件路。
        // ⚠️ **先放一块盘**：空列表那一轮**不发事件** —— `performDetect` 对空列表直接 `return`，
        // 连 `results` 都不赋值。这不是 bug（没结论要写回），但写阳性对照时必须知道。
        diskStore.replaceDisksForTesting([makeDisk("/Volumes/PROBE")])
        let live = makeStore(diskStore: diskStore, autoStart: true) { _ in .none }
        defer { live.stop() }
        expectEvent(await waitForNextRound(live), "首轮必须走事件路")

        diskStore.replaceDisksForTesting([makeDisk("/Volumes/PROBE-2")])
        expectEvent(await waitForNextRound(live), "列表一变必须走事件路")
    }
}
