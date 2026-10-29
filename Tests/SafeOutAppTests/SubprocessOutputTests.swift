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
///
/// ## 2026-10-27：判据从「退出码」改成「stderr 是否为空」
///
/// 上一版把「退出码非 0」一律当成「没跑成」，于是**任何 lsof 列不出占用者的合法盘
/// 都显示「占用未知」**（用户报「为什么现在有的硬盘会显示占用未知」）。实测：
/// `lsof /Volumes/wenbo-data`（合法卷、无匹配）与 `lsof /Volumes/NoSuchVol`（失效路径）
/// **退出码都是 1、stdout 都是 0 字节**，唯一区别是后者往 stderr 写了 539 字节。
/// ⇒ 所以本文件把四种组合都钉住，见末尾「退出码不参与判定」那一节。
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
        /// 完整结果；`nil` = 没拿到（启动失败 / 超时）。
        ///
        /// stdout / stderr / 退出码是**同一个结构体**，一起为 `nil` 或一起有值 ——
        /// 不存在「拿到了 stdout 但不知道有没有 stderr」的半截状态（见 ``SubprocessOutput``）。
        var result: SubprocessResult?
        var callbackElapsed: TimeInterval
        var resumeElapsed: TimeInterval

        /// 上层（lsof 路径）看到的归约结果：`nil` = 没跑成，字符串 = stdout（空串也算跑成）。
        var lsofOutput: String? { OccupancyDetector.lsofResult(result) }
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

    /// 一次收集，返回完整结果与两段耗时（含义见 `Collected`）。
    private func collect(
        _ executable: String, _ arguments: [String], timeout: TimeInterval
    ) async -> Collected {
        let start = Date()
        let stamp = Stamp()
        let result = await withCheckedContinuation {
            (c: CheckedContinuation<SubprocessResult?, Never>) in
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
            result: result,
            callbackElapsed: stamp.read().map { $0.timeIntervalSince(start) } ?? -1,
            resumeElapsed: Date().timeIntervalSince(start))
    }

    @Test func 收集得到子进程的完整输出() async {
        let got = await collect("/bin/echo", ["hello"], timeout: 5)
        #expect(
            got.result?.output == "hello\n",
            "应当拿到 /bin/echo 的完整输出，实得 \(String(describing: got.result?.output))")
        #expect(
            got.result?.exitStatus == 0,
            "正常结束必须暴露退出码 0，实得 \(String(describing: got.result?.exitStatus))")
        #expect(got.result?.errorOutput == "", "echo 不写 stderr，实得 \(String(describing: got.result?.errorOutput))")
    }

    /// **stderr 必须真的被收集**（本轮新增的核心能力）。
    ///
    /// 上一版把 stderr 丢给 `FileHandle.nullDevice`，于是「lsof 报错」这个唯一可靠的
    /// 失败信号被永久丢弃。这条用 `/bin/sh` 确定性地往 stderr 写一段再退出。
    @Test func 收集得到子进程的stderr() async {
        let got = await collect("/bin/sh", ["-c", "echo oops >&2; echo out; exit 3"], timeout: 5)
        #expect(
            got.result?.errorOutput == "oops\n",
            "stderr 必须逐字收回来，实得 \(String(describing: got.result?.errorOutput))")
        #expect(got.result?.output == "out\n", "stdout 与 stderr 两路互不干扰")
        #expect(got.result?.exitStatus == 3, "退出码应原样交出（仅作排查线索）")
    }

    /// **这条是「刷新一直转圈」的回归测试。**
    ///
    /// `/bin/sleep 30` 注定超时；超时时间设 1s，**回调**必须在 5s 内带着 `nil` 到达。
    /// 若哪天有人把超时改回「事后 terminate」的写法，本测试会挂住直到 CI 超时 ——
    /// 那正是它该做的：把「静默永久阻塞」变成「红字」。
    ///
    /// ⚠️ 断言用的是 `callbackElapsed`（`SubprocessOutput` 的契约），**不是**
    /// `resumeElapsed`（含并发池调度延迟，属于别人的负载）。理由见 `Collected`。
    ///
    /// ⚠️ 超时后整个 `result` 必须是 `nil`（含 stderr）：三样证据一起作废，
    /// 否则上层会拿一个「退出码不可信、stderr 可能是假的」的结果去做判据。
    @Test func 超时是真超时而不是装饰() async {
        let got = await collect("/bin/sleep", ["30"], timeout: 1)
        #expect(
            got.result == nil,
            "超时后整个结果应为 nil（上层据此判为「没跑成」），实得 \(String(describing: got.result))")
        #expect(
            got.lsofOutput == nil,
            "超时必须是「没跑成」，不能被读成「无占用」")
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
            got.result?.output.count == 200_001,
            "200KB 的输出应当一个字节不少，实得 \(String(describing: got.result?.output.count)) 字节")
    }

    /// 可执行文件不存在时**也必须收尾**，不能把调用方挂住。
    @Test func 启动失败立刻收尾并返回nil() async {
        let got = await collect("/nonexistent/de-lsof", [], timeout: 5)
        #expect(got.result == nil)
        #expect(got.lsofOutput == nil, "启动失败没有可信证据，必须是「没跑成」")
        #expect(got.callbackElapsed < 2, "启动失败应当立刻收尾，实得 \(got.callbackElapsed)s")
    }

    // MARK: - 判定语义（2026-10-27：退出码不参与判定，只看 stderr）

    /// **回归点之一**：退出码 1 且 **stderr 为空** ⇒ 正常跑完、无匹配。
    ///
    /// 这正是 `lsof /Volumes/wenbo-data`（合法卷、没有进程占用）的真实形态：
    /// 退出码 1、stdout 0 字节、stderr 0 字节。上一版把「退出码 1」当失败，
    /// 于是这类盘全显示「占用未知」—— 这条断言就是防它再回来。
    @Test func 退出码一且stderr为空视作正常跑完() async {
        // `/usr/bin/false`：退出码恒为 1、stdout 与 stderr 都不写 —— 与「合法卷无匹配」同形。
        let got = await collect("/usr/bin/false", [], timeout: 5)
        #expect(got.result?.exitStatus == 1, "false 的退出码应是 1，实得 \(String(describing: got.result?.exitStatus))")
        #expect(got.result?.errorOutput == "", "false 不写 stderr")
        #expect(
            got.lsofOutput == "",
            "退出码 1 + 空 stderr = 正常跑完但没有匹配，必须返回空字符串（= 无占用），不能是 nil")
    }

    /// **回归点之二**：stderr 非空 ⇒ 没跑成（哪怕退出码是 0）。
    ///
    /// lsof 对失效路径的形态是「stderr 539 字节 + 退出码 1」，但判据只看 stderr ——
    /// 这样即使某个工具在「有警告」时仍退 0，也不会把警告当成成功。
    @Test func stderr非空判为没跑成() async {
        let got = await collect("/bin/sh", ["-c", "echo 'status error on x' >&2; exit 0"], timeout: 5)
        #expect(got.result?.exitStatus == 0)
        #expect(got.result?.errorOutput.isEmpty == false)
        #expect(
            got.lsofOutput == nil,
            "只要 stderr 非空就按「没跑成」处理（上层按授权状态兜底，绝不落成「可安全推出」）")
    }

    /// 退出码 0、stdout 为空、stderr 为空 ⇒ **成功但无匹配**，不等于「没跑成」。
    ///
    /// 这是 `lsof <正常卷>` 无匹配时的另一种真实形态：必须能落成「确实无占用」。
    @Test func 退出码零且输出为空仍是成功() async {
        let got = await collect("/usr/bin/true", [], timeout: 5)
        #expect(got.result?.exitStatus == 0, "true 的退出码应是 0，实得 \(String(describing: got.result?.exitStatus))")
        #expect(
            got.lsofOutput == "",
            "退出码 0 且无输出 = 成功但无匹配，必须返回空字符串而不是 nil")
    }

    /// 纯函数层面：`parseLsof("")` 返回空数组（现状，防止有人误改成崩）。
    @Test func 解析空输出返回空数组() {
        #expect(OccupancyDetector.parseLsof("") == [])
    }
}
