import Foundation
import Testing

@testable import SafeOutApp

/// ``SubprocessOutput`` 的两条硬契约：**收得到输出**，以及**超时是真的**。
///
/// ## 为什么必须单独测「超时是真的」
///
/// 2026-09-17 用户报「主窗口刷新按钮点了以后一直转圈」。根因是旧的 lsof 调用把
/// `task.terminate()` 排在了一个「只有管道 EOF 才会返回」的 `await` 之后 ——
/// 那句「5 秒超时」**一次都没被执行过**，是个装饰；而 EOF 又会偶发地不来。
///
/// 这种 bug 的特征是**偶发**（压测约 1/10），本地点两下未必复现，所以必须有一条
/// 不依赖 lsof、不依赖磁盘、能在 CI 里确定性跑的断言把它钉住。
/// 做法是用 `/bin/sleep` 造一个**必定超时**的子进程：
/// 旧实现会在这里永久挂住（测试跑到超时被杀），新实现必须在超时后立刻返回 `nil`。
@Suite("子进程输出收集")
struct SubprocessOutputTests {

    /// 一次收集的结果。
    ///
    /// ⚠️ **两个耗时是两件事，别只量一个**（2026-09-20 CI 踩到）：
    ///
    /// - `callbackElapsed`：`start()` 到**回调被触发**（跑在定时器线程上）——
    ///   这才是 ``SubprocessOutput`` 的契约（「超时后多久收尾」）。
    /// - `resumeElapsed`：`start()` 到 `await` **返回** —— 它还包括
    ///   **Swift 并发池把任务重新调度的延迟**，取决于同一批里有没有别的测试
    ///   把协作线程池占住（见 `MainActorBlockingTests` 那一族），**与被测对象无关**。
    ///
    /// 实测：超时设 1s 时 `callbackElapsed` 是 1 秒出头，而 `resumeElapsed` 到过 **5.98s**
    /// ⇒ 拿 `resumeElapsed` 去判「超时生效了吗」会把**别人的负载**算到被测对象头上。
    struct Collected {
        var output: String?
        var callbackElapsed: TimeInterval
        var resumeElapsed: TimeInterval
    }

    /// 记回调时刻的盒子 —— `completion` 是 `@Sendable`，**不能**捕获可变的局部变量。
    private final class Stamp: @unchecked Sendable {
        private let lock = NSLock()
        private var at: Date?
        func mark() {
            lock.lock()
            at = Date()
            lock.unlock()
        }

        func read() -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return at
        }
    }

    /// 一次收集，返回输出与两段耗时（含义见 `Collected`）。
    private func collect(
        _ executable: String, _ arguments: [String], timeout: TimeInterval
    ) async -> Collected {
        let start = Date()
        let stamp = Stamp()
        let output = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                timeout: timeout
            ) { value in
                stamp.mark()
                c.resume(returning: value)
            }
            run.start()
        }
        return Collected(
            output: output,
            callbackElapsed: stamp.read().map { $0.timeIntervalSince(start) } ?? -1,
            resumeElapsed: Date().timeIntervalSince(start))
    }

    @Test func 收集得到子进程的完整输出() async {
        let got = await collect("/bin/echo", ["hello"], timeout: 5)
        #expect(
            got.output == "hello\n", "应当拿到 /bin/echo 的完整输出，实得 \(String(describing: got.output))")
    }

    /// **这条是「刷新一直转圈」的回归测试。**
    ///
    /// `/bin/sleep 30` 注定超时；超时时间设 1s，**回调**必须在 5s 内带着 `nil` 到达。
    /// 若哪天有人把超时改回「事后 terminate」的写法，本测试会挂住直到 CI 超时 ——
    /// 那正是它该做的：把「静默永久阻塞」变成「红字」。
    ///
    /// ⚠️ 断言用的是 `callbackElapsed`（`SubprocessOutput` 的契约），**不是**
    /// `resumeElapsed`（含并发池调度延迟，属于别人的负载）。理由见 `Collected`。
    @Test func 超时是真超时而不是装饰() async {
        let got = await collect("/bin/sleep", ["30"], timeout: 1)
        #expect(
            got.output == nil,
            "超时后应当返回 nil（上层按授权状态兜底），实得 \(String(describing: got.output))")
        #expect(
            got.callbackElapsed < 5,
            """
            超时路径必须在 5s 内**回调**，实得 \(got.callbackElapsed)s
            （`await` 返回另花了 \(got.resumeElapsed - got.callbackElapsed)s，那是并发池调度，不算在它头上）
            —— 回调来晚了就说明超时没生效，调用方会一直等下去。
            """)
    }

    /// 子进程输出超过管道缓冲（64KB）也不能丢字节 —— 根卷的 lsof 实测 1.7MB。
    @Test func 大输出不会截断() async {
        // /bin/yes 会无限输出，用 head 截断成确定的 200_000 字节再比对
        let got = await collect("/bin/echo", [String(repeating: "x", count: 200_000)], timeout: 10)
        #expect(
            got.output?.count == 200_001,
            "200KB 的输出应当一个字节不少，实得 \(String(describing: got.output?.count)) 字节")
    }

    /// 可执行文件不存在时**也必须收尾**，不能把调用方挂住。
    @Test func 启动失败立刻收尾并返回nil() async {
        let got = await collect("/nonexistent/de-lsof", [], timeout: 5)
        #expect(got.output == nil)
        #expect(got.callbackElapsed < 2, "启动失败应当立刻收尾，实得 \(got.callbackElapsed)s")
    }
}
