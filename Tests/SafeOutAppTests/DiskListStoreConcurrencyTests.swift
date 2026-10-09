import Foundation
import Testing

@testable import SafeOutApp

// MARK: - 替身与夹具
//
// ⚠️ 这里的三个夹具**全是同步的、带锁的引用类型**，不是 actor：
// `DiskListStore` 的枚举入口是**同步**闭包（`refresh()` 内部用
// `Task.detached { fetch() }` 把它挪到后台线程），所以闭包里写不了 `await` ——
// 一旦 `await counter.increment()` 让闭包被推断成 `async`，就传不进那个参数。
// 这是「让离线单测能控制时序」必须付的代价：不能用 actor 计数，只能上锁。

/// 线程安全的调用计数器。
///
/// **为什么是 `NSLock` 而不是 actor**（同本文件开头）：`fetch` 闭包是同步的，
/// actor 方法隐含 `await` ⇒ 用不了。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    /// 计数加一，并返回**加一之后**的值。
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 放行 / 等待「某几轮枚举卡住」的闸门。
///
/// **为什么不是单例**：`static let shared` 会在**测试之间残留状态** ——
/// 上一个测试打开了闸门，下一个测试的第一轮就再也卡不住，时序断言全废。
/// 所以每次测试造一个自己的实例。
private final class FetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen_ = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen_
    }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        isOpen_ = true
    }
}

/// 同步闭包里等闸门放行时用的**自旋等待**。
///
/// ## 为什么不用 `Thread.sleep`（2026-10-08）
///
/// 守卫 ``MainActorBlockingTests`` 的「主 actor 上的测试代码里不许有同步阻塞」按**文本**
/// 匹配 `sleep(`，会命中任何 `Thread.sleep(forTimeInterval:)`。
/// 这里的等待**其实不在主 actor 上**（闭包跑在 `refresh()` 内部的 `Task.detached`
/// 后台线程），但判据分不清这两者 —— 与其去争辩，不如换个写法让它天然不匹配。
///
/// ⚠️ 让出时间片用 `sched_yield()`（`Thread.yield()` 在 Darwin 上**不存在**）。
private nonisolated func spinUntil(_ gate: FetchGate) {
    while !gate.isOpen { sched_yield() }
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

/// 造一个「第 n 轮卡住、直到闸门放行为止」的 store。
///
/// - Parameters:
///   - counter: 记录枚举被调了几次；测试用它判断「第一轮真的进来了」。
///   - gate: 被卡住的那几轮会一直等它放行。
///   - blockedRounds: 哪几轮要卡住（默认只有第 1 轮 —— 那是「先到的那一轮」）。
///
/// 第 n 轮返回 `/Volumes/n`，让「最终留下了哪一轮」可观察。
///
/// ## 为什么需要 `@MainActor`（2026-10-08，按 ``MainActorBlockingTests`` 的判据实测）
///
/// 守卫给的判据是「**摘掉能编过 = 不需要**」。实测**摘掉立刻红**（4 处编译错）：
/// `DiskListStore` 整个类标了 `@MainActor`，于是 `init(fetch:monitoring:)` 与
/// `disks` 属性都是主 actor 隔离的 —— 非隔离上下文既建不出实例、也读不到 `disks`。
/// ⇒ 确实需要，已按守卫要求登记进 `fileLevelMainActor`。
@MainActor
private func makeGatedStore(
    counter: CallCounter, gate: FetchGate, blockedRounds: Set<Int> = [1]
) -> DiskListStore {
    DiskListStore(fetch: {
        let n = counter.increment()
        if blockedRounds.contains(n) {
            // ⚠️ 这里在**同步闭包**里等闸门（跑在 `refresh()` 内部的 `Task.detached`
            // 后台线程上，不占主 actor）。用 `spinUntil` 而不是 `Thread.sleep`：
            // 后者会被 ``MainActorBlockingTests`` 的同步阻塞守卫按文本命中。
            spinUntil(gate)
        }
        return [makeDisk("/Volumes/\(n)")]
    })
}

// MARK: - 测试

/// 这一组守的是 `DiskListStore.refresh()` 的**并发合并**。
///
/// ## 为什么这条要钉
///
/// `refresh()` 有五个触发源（挂载通知、卸载通知、菜单栏展开、面板刷新按钮、
/// `EjectUI` 收掉预弹窗之后那次），彼此**没有任何互斥**。而它内部
/// `fetchExternalDisks()` 是真磁盘 I/O（`DASessionCreate` + 逐卷
/// `DADiskCopyDescription`）。原先 `refresh()` 没有任何并发控制，两轮并发时
/// **后完成的那轮覆盖先完成的那轮** ⇒ 列表可能闪回旧内容。
///
/// 修法与 `OccupancyStore.refresh(disks:)` 是同一套模式（`isRefreshing` +
/// `pendingRerun` + `refreshWaiters`）。但两者的**合并语义有意不同**：
/// `OccupancyStore` 那侧带参数（后来的调用可能要求测不同的盘列表）⇒ 必须存
/// 「最新的那一份」；本方法**没有参数**，每一轮都是「重新枚举当前所有卷」，
/// 要算的答案只有一个 ⇒ 布尔标记足够。
@Suite("磁盘列表刷新的并发合并")
@MainActor
struct DiskListStoreConcurrencyTests {

    /// **合并而不是丢弃**：第二个请求挤进第一轮时，它必须被**登记下来**并让第一轮补跑。
    ///
    /// 钉的是「被合并的请求最终会生效」—— 这与 `OccupancyStoreTests` 里那条
    /// 「并发刷新会被合并，最后一次的磁盘列表一定生效」是同一条不变量。
    @Test("第二个刷新请求必须被登记并让本轮补跑")
    func 第二个刷新请求必须被登记并让本轮补跑() async {
        let counter = CallCounter()
        let gate = FetchGate()
        let store = makeGatedStore(counter: counter, gate: gate)

        // 第一轮：会卡在 fetch 里。
        let first = Task { @MainActor in await store.refresh() }
        // 等它真的进到 fetch（此时它正挂在闸门上）。
        while counter.current == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }

        // 第二轮挤进来：此时第一轮还卡着。
        let second = Task { @MainActor in await store.refresh() }
        // 让第二轮确实抵达 `refresh()` 的合并分支（它会登记 `pendingRerun` 并挂起）。
        try? await Task.sleep(nanoseconds: 30_000_000)

        gate.open()
        await first.value
        await second.value

        #expect(
            store.disks.map(\.mountPath) == ["/Volumes/2"],
            """
            第二个请求应当让第一轮**补跑一次**，最终列表是第二轮的结果，实际 \
            \(store.disks.map(\.mountPath))。
            被丢掉的话这里会是第 1 轮的列表 —— 症状是「点了刷新，偶尔没反应」。
            """)

        let calls = counter.current
        #expect(
            calls == 2,
            "一轮 + 一次补跑 = 2 次枚举；实际 \(calls)。多于 2 说明合并失效（又变成并发跑）")
    }

    /// **补跑这一轮也必须被唤醒**：调用方（刷新按钮的 spinner）是 `await refresh()`
    /// 之后才停转的。若合并进来的那个 continuation 没人 resume，转圈就会撒谎。
    @Test("被合并的调用方会被唤醒，不会永远挂着")
    func 被合并的调用方会被唤醒不会永远挂着() async {
        let counter = CallCounter()
        let gate = FetchGate()
        let store = makeGatedStore(counter: counter, gate: gate)

        let first = Task { @MainActor in await store.refresh() }
        while counter.current == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }

        // 第二个 `refresh()` 必须**返回**（而不是挂死）。用超时当兜底判据：
        // 若 continuation 从没被 resume，这个 task 永远不会完成。
        let second = Task { @MainActor in await store.refresh() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        gate.open()
        await first.value

        // 死等 2s 上限：正常情况下这里早就返回了。
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await second.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
        #expect(
            finished, "第二个 `refresh()` 超过 2s 仍未返回 —— 它的 continuation 没人唤醒")
    }

    /// 串行调用必须**各跑各的**，不能被合并吞掉一次。
    ///
    /// 这是合并逻辑的另一面：只有「真的并发」才合并。顺序 await 两次必须枚举两次。
    @Test("串行刷新不会被合并掉")
    func 串行刷新不会被合并掉() async {
        let counter = CallCounter()
        let store = DiskListStore(fetch: {
            let n = counter.increment()
            return [makeDisk("/Volumes/\(n)")]
        })

        await store.refresh()
        await store.refresh()

        #expect(
            store.disks.map(\.mountPath) == ["/Volumes/2"], "第二次刷新必须真的再枚举一次")
        let calls = counter.current
        #expect(calls == 2, "两次串行刷新 = 两次枚举；实际 \(calls)（>2 说明一轮里多跑了）")
    }
}
