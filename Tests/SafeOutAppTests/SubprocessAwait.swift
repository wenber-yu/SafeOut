import Foundation

/// 跑一个子进程并等它退出 —— **不阻塞任何线程**。
///
/// ## 为什么不能用 `waitUntilExit()`（2026-09-22，§8.114 第 6 节）
///
/// `waitUntilExit()` 是**同步阻塞、不让路**的：它占住调用它的那根线程，直到子进程退出。
///
/// - 在**主 actor** 上调用 ⇒ 占住主 actor（`MainActorBlockingTests` 第一条守卫挡的就是这个）；
/// - 在 `nonisolated` **且** `async` 的函数里调用 ⇒ 看起来「已经搬走了」，
///   但**搬走的只是被占住的对象**：它占的是**协作线程池**里的一根线程，而池大小 ≈ **核数**。
///
/// CI runner 的核数比开发机少，几处并发阻塞就能让整个进程停摆 —— §8.114 第 6 节量到整轮
/// 出现 **4.5s 零完成窗口**，并明确写下「修法 ② 被当成了终点，而它不是」。
///
/// 症状是**别的**测试等不到东西：`ProcessAppResolverTests.waitForExecutablePath` 是
/// `nonisolated async`（⇒ 跑在协作池上），CI 上等 2 秒等不到 `proc_pidpath`
/// ⇒ 报成「进程还没就绪」，而真因是**池里没有空线程给它**。
///
/// ## 做法
///
/// 等 `terminationHandler` 回调（由 Foundation 在自己的线程上发），用
/// `withCheckedContinuation` 把它桥成 `async` —— 等待期间**一个线程都不占**。
///
/// ⚠️ **`terminationHandler` 必须在 `run()` 之前设好**，否则可能漏掉「刚起就退」的进程。
/// ⚠️ **`run()` 抛错时回调永远不会来** ⇒ 必须在那一支里也 resume，否则挂死。
/// ⚠️ 返回值用 `Int32?`：`nil` 表示**没跑起来** —— 与「跑起来但退出码非 0」是两件事，
/// 而两者的调用处处理方式不同（前者连 `terminationStatus` 都没意义）。
func runAndAwaitExit(_ task: Process) async -> Int32? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
        task.terminationHandler = { finished in
            continuation.resume(returning: finished.terminationStatus)
        }
        do {
            try task.run()
        } catch {
            // 进程根本没起来 ⇒ 回调不会来，这一支必须自己收尾。
            continuation.resume(returning: nil)
        }
    }
}
