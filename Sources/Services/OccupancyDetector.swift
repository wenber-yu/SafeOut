import Foundation
import OSLog

/// 卷占用情况的检测结果。
///
/// **为什么需要 `unknown` 而不是用空数组兜底**：
/// 在 App Sandbox 下进程枚举能力不可用（实测 `lsof` 输出 0 行、`proc_listallpids` 返回 0）。
/// 若沿用「返回空数组」表示「没检测到进程」，上层会把它理解成「没有进程占用」，从而直接
/// 执行推出——把「检测失败」静默当成「安全」是危险默认值的典型形态。
/// 因此检测能力缺失必须是一个显式状态，由 UI 明确告知用户「无法检测」。
enum OccupancyResult: Sendable, Equatable {

    /// 已确认没有进程访问该卷。
    case none

    /// 检测到有进程访问该卷。
    case occupied([OccupyingProcess])

    /// 当前环境无法判断（例如运行在 App Sandbox 内）。
    case unknown

    /// 直发（非沙盒）构建下，lsof 因未授予「完全磁盘访问」而拿不到其他进程。
    /// 与 `.unknown` 的区别：`.unknown` 是环境硬限制（沙盒），`.needsFullDiskAccess`
    /// 是用户可补救的权限缺口——引导去系统设置授权后检测即可恢复。
    case needsFullDiskAccess

    var processes: [OccupyingProcess] {
        if case .occupied(let list) = self { return list }
        return []
    }
}

/// 卷占用检测。
///
/// 采用「能力探测 + 降级」而非无条件调用：先判断当前进程是否运行在 App Sandbox 内，
/// 沙盒下直接返回 ``OccupancyResult/unknown``，不浪费一次注定失败的子进程调用，
/// 也不会让上层误判为「无占用」。
class OccupancyDetector: @unchecked Sendable {
    static let shared = OccupancyDetector()

    /// 开放给测试注入 mock 子类；生产环境一律使用 `shared`。
    init() {}

    private static let logger = Logger(subsystem: "com.safeout.app", category: "Occupancy")

    /// lsof 单次调用的最长等待时间（秒），超时即视为检测失败。
    ///
    /// ⚠️ 这个数现在**真的会生效**（以前不会，见 ``SubprocessOutput`` 的说明）。
    /// 本机 `lsof` 单个卷实测 0.15~0.26s（含根卷 1.7MB 输出），留了 20 倍余量。
    static let lsofTimeout: TimeInterval = 5

    /// 当前进程是否运行在 App Sandbox 内。
    ///
    /// 系统在启动沙盒进程时会注入 `APP_SANDBOX_CONTAINER_ID` 环境变量，这是判断沙盒状态
    /// 最轻量的方式（无需私有 API）。
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// 是否已授予「完全磁盘访问」（FDA）。
    ///
    /// **为什么需要独立探测**：直发版下 `lsof` 在未授权时返回 0 行，与「确实无占用」无法区分。
    /// 把空结果一律当「无占用」会在未授权时误导用户强卸、损坏数据；一律当「需授权」又会在
    /// 已授权但无占用时错误地弹出授权引导（正是此前被反馈的 bug）。
    /// 因此先做一项与 lsof 无关的 FDA 能力探测：尝试读取 TCC 受保护的用户数据目录
    /// （Mail / Messages 等）——这些目录在无 FDA 时被系统拦截（`EACCES`），授予后可读。
    /// 任一受保护目录「存在且可读」即视为已授权。
    ///
    /// **探针选型（本机实测）**：`~/Library/Mail`、`~/Library/Messages`、
    /// `~/Library/Containers/com.apple.mail`、`~/Library/Containers/com.apple.iChat`
    /// 在无 FDA 的进程下均返回 `EACCES`，确认其受 TCC 保护、可作可靠探针；
    /// 而 `~/Library/Application Support/AddressBook` 等在无 FDA 时也可读，不可用作探针，已排除。
    nonisolated static func isFullDiskAccessAuthorized() -> Bool {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Containers/com.apple.mail",
            "\(home)/Library/Containers/com.apple.iChat",
            // 追加一组「必然存在」的 TCC 受保护目录做兜底探针，避免用户没装 Mail/Messages
            // 时四个候选全缺失 → 直接判 false（把「没装」误判成「没授权」）。
            "\(home)/Library/Application Support/com.apple.TCC",
            "\(home)/Library/Safari",
            "\(home)/Library/HomeKit",
            "\(home)/Library/IdentityServices",
            "\(home)/Library/Cookies",
            "\(home)/Library/Caches/com.apple.Safari",
        ]
        let fm = FileManager.default
        for path in candidates {
            let exists = fm.fileExists(atPath: path)
            // **判据必须是「实际列举目录内容」，不是 `isReadableFile`**：
            // `isReadableFile` 走 `access(R_OK)`，只校验 POSIX 权限位，**不触发 TCC 判定**，
            // 结果与真实的 TCC 放行状态可能相反。TCC 在 open/readdir 层拦截，
            // 因此「能否 contentsOfDirectory」才是授权状态的真实证据。
            guard exists else { continue }  // 缺失不计数（避免把「没装 Mail」误判为未授权）
            if (try? fm.contentsOfDirectory(atPath: path)) != nil {
                logger.info("FDA 探针命中: \(path, privacy: .public)")
                return true
            }
        }
        logger.info("FDA 探针全部不可列举，判定未授权")
        return false
    }

    /// 检测访问指定卷的进程。
    ///
    /// 该调用可能耗时（子进程执行），应在后台上下文调用。
    func detect(mountPath: String) async -> OccupancyResult {
        if Self.isSandboxed {
            Self.logger.info("运行于沙盒内，进程枚举不可用，返回 unknown")
            return .unknown
        }

        // 先独立探测 FDA 授权状态：未授权时 lsof 必然拿不到其他进程，直接给「需授权」，
        // 由 UI 在标题栏居中展示引导；授权后再看 lsof 输出区分「占用 / 无占用」。
        // 不能把 lsof 空输出直接当「无占用」——那样会在未授权时误导用户强卸、损坏数据；
        // 也不能一律当「需授权」——那样会在已授权但无占用时错误地弹出授权引导。
        let authorized = Self.isFullDiskAccessAuthorized()

        guard let output = await Self.lsofOutput(mountPath: mountPath) else {
            // 子进程启动失败/超时：按授权状态保守兜底，不把失败当「安全」。
            return authorized ? .none : .needsFullDiskAccess
        }

        let processes = Self.parseLsof(output)
        if !processes.isEmpty {
            // 能列出进程即证明已授权，直接返回占用列表（核心价值）。
            //
            // 这里必须补一步「应用身份解析」：lsof 的 `c` 字段只是可执行名（`IMVIDEO`），
            // 用户在 Dock 里看到的是应用显示名（`Bunny`）。解析放在检测阶段（每轮一次）
            // 而不是视图渲染阶段，既避免每帧重复解析，也让下游（含纯函数文案层）拿到的
            // 就是可直接展示的完整模型。详见 ``ProcessAppResolver``。
            return .occupied(await ProcessAppResolver.enrich(processes))
        }
        // lsof 空行：已授权 → 确实无占用（可安全推出）；未授权 → 提示授权。
        return authorized ? .none : .needsFullDiskAccess
    }

    /// 同步版本，仅供 `--diagnostics` 一次性自检使用。
    ///
    ///  diagnostics 是退出即止的开发者工具，不需要并发；同步执行可彻底避开
    /// 「主线程 `group.wait()` 阻塞」与「`static main()` 返回后进程不等异步 Task」两类生命周期陷阱，
    /// 比用 `Task { await ... }` + `RunLoop` 更可预测。
    ///
    /// **标 `@MainActor` 的原因**：尾部要做应用身份解析（``ProcessAppResolver/enrich(_:)``），
    /// 那条链路走 `NSWorkspace` / `NSRunningApplication`，只能在主 actor 上跑。用类型标注而不是
    /// `MainActor.assumeIsolated`，是为了让编译器替我们保证这个前提（唯一调用方 `runDiagnostics()`
    /// 本来就在主 actor 上），而不是在运行时赌它。
    @MainActor
    func detectSync(mountPath: String) -> OccupancyResult {
        if Self.isSandboxed {
            return .unknown
        }
        let authorized = Self.isFullDiskAccessAuthorized()
        guard let output = Self.lsofOutputSync(mountPath: mountPath) else {
            return authorized ? .none : .needsFullDiskAccess
        }
        let processes = Self.parseLsof(output)
        if !processes.isEmpty {
            return .occupied(ProcessAppResolver.enrich(processes))
        }
        return authorized ? .none : .needsFullDiskAccess
    }

    /// 同步执行 lsof 并读取全部输出（diagnostics 使用）。
    ///
    /// **为什么不直接 `readDataToEndOfFile()`**：那正是下面 ``SubprocessOutput`` 说明里
    /// 那个会永久阻塞的写法。这里改成「启动后转 run loop 等收尾」——
    /// 既不阻塞回调所在的队列（`readabilityHandler` 跑在哪条队列上由系统决定，
    /// 拿信号量堵主线程有可能和它撞车），也仍然有硬超时兜底。
    private static func lsofOutputSync(mountPath: String) -> String? {
        let run = SubprocessOutput(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-Fpcn0", mountPath],
            timeout: lsofTimeout
        ) { _ in }
        run.start()

        // 转 run loop 而不是 `semaphore.wait()`：主线程继续处理事件，
        // 无论回调被派发到哪条队列都能被执行到。
        let deadline = Date().addingTimeInterval(lsofTimeout + 3)
        while !run.isFinished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return run.output
    }

    // MARK: - lsof

    /// 执行 lsof 并取回输出。
    ///
    /// - Returns: lsof 的原始输出；`nil` = 没拿到（启动失败或超时）。
    nonisolated private static func lsofOutput(mountPath: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // `-Fpcn0`：机器可读输出（p=PID、c=命令名、n=路径），记录以 NUL 分隔。
            // 不用默认表格格式——它按空格切列，进程名含空格时会错位，见 ``parseLsof`` 的说明。
            //
            // ⚠️ **不要顺手加 `-X`**：它在 lsof 里的语义反直觉 —— `-X` = 「**跳过 mmap 文件**」，
            // 而不带 `-X` 时**会**列出「mmap 之后已 close 掉 fd」的进程（2026-09-09 实测）。
            // 那正是最隐蔽的一类占用者 ⇒ 加 `-X` 等于把它们从结果里抹掉。
            //
            // `run` 不需要调用方持有：``SubprocessOutput/start()`` 里的两个闭包
            // （readabilityHandler 与超时块）都强引用 self，实例会活到收尾为止。
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-Fpcn0", mountPath],
                timeout: lsofTimeout
            ) { output in
                continuation.resume(returning: output)
            }
            run.start()
        }
    }

    /// 解析 `lsof -F` 的机器可读输出。
    ///
    /// **为什么用 `-F` 而不是默认表格格式**：默认输出按空格切列，而进程名本身可以含空格
    /// （`Google Chrome Helper`、`Microsoft Word` 等），一旦出现，PID 列就会错位，
    /// 解析出的 pid 其实是名字的第二个单词——`Int32(...)` 转换失败，该进程被静默丢弃。
    /// 表现为「占用检测时灵时不灵」，且只在特定应用占用时才复现，极难定位。
    /// `-F` 格式以 `p`/`c`/`n` 前缀标识字段，不存在歧义。
    ///
    /// 字段含义：`p` = PID，`c` = 命令名（**可执行名，不等于用户看到的应用名**，
    /// 例：`IMVIDEO` 这个进程对应的应用显示名是 `Bunny`，见 ``OccupyingProcess``），
    /// `n` = 文件路径。
    ///
    /// **输出结构是「每个字段后跟一个 NUL」，不是「每条记录后跟一个 NUL」**——
    /// 这点必须实测确认，凭直觉按记录切分会得到一串孤立字段，解析结果恒为空。
    /// 本机实测 `lsof -Fpcn0 /Volumes/wenbo-data` 的原始字节：
    /// `p17917\0cIINA\0\nf9\0n/Volumes/.../03.mp4\0`
    /// 因此这里以「遇到 `p` 字段」作为一条新记录的开始。
    ///
    /// 同一进程可能通过多个 fd 访问同一卷，因此输出里会出现多组字段；这里按 PID 去重。
    static func parseLsof(_ output: String) -> [OccupyingProcess] {
        var byPid: [Int32: OccupyingProcess] = [:]
        var pid: Int32?
        var command: String?
        var path: String?

        /// 结束当前进程记录并入结果集。
        func commit() {
            defer {
                pid = nil
                command = nil
                path = nil
            }
            guard let pid, let command, !command.isEmpty else { return }
            // 保留首个路径即可：UI 只需要一个代表路径，重复展示同一进程没有意义。
            // 这里只填 lsof 给得出的字段；`displayName` / 图标所需的路径由
            // ``ProcessAppResolver`` 在解析阶段补齐（本函数保持纯字符串处理、可单测）。
            if byPid[pid] == nil {
                byPid[pid] = OccupyingProcess(pid: pid, processName: command, path: path ?? "")
            }
        }

        for rawField in output.split(separator: "\0", omittingEmptySubsequences: true) {
            // **lsof 会在「每条记录组」前插入一个 `\n`**（除最开头第一组）：
            // 实测多进程输出 `p5340\0cIINA\0\nf9\0n...\0\np39298\0ctail\0\nf3\0n...\0\n`。
            // 若不先剥掉前导 `\n`，后续进程的 `p` 字段会变成 `\np39298`，`field.first` 得到
            // `\n` 而被当作未知字段丢弃 → 只有一个进程被解析出，且名字会被后一个进程覆盖。
            // 这正是「多进程只显示一个、且进程名张冠李戴」的根因。
            let field = rawField.drop { $0 == "\n" || $0 == "\r" }
            guard let tag = field.first, field.count > 1 else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p":
                commit()  // 上一个进程结束
                pid = Int32(value)
            case "c":
                command = value
            case "n":
                path = value
            default:
                // 其他字段（f 文件描述符、u 用户等）本应用不到。
                // 注意 `f` 字段前会带一个换行，其首字符是 `\n`，在此被自然跳过。
                break
            }
        }
        commit()  // 提交最后一条

        return byPid.values.sorted { $0.pid < $1.pid }
    }
}

// MARK: - 子进程输出收集

/// 跑一次子进程，把它 stdout 的**全部**输出收集回来，**并保证一定收尾**。
///
/// ## 为什么要有这个类型（它取代了「阻塞读管道 + 事后 terminate」的写法）
///
/// 旧写法长这样：
///
/// ```swift
/// let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() … }
/// let output = await withTaskGroup(of: String?.self) { group in
///     group.addTask { await reader.value }
///     group.addTask { try? await Task.sleep(5s); return nil }
///     guard let first = await group.next() else { return nil }
///     group.cancelAll()
///     return first
/// }
/// guard let output else { task.terminate(); return nil }   // ← 永远到不了
/// ```
///
/// 它有两个叠加的致命缺陷。实测（2026-09-17，本机 100 次压测）：
///
/// 1. **超时是假的。** `withTaskGroup` 在闭包返回前会**等所有子任务结束**；
///    而读管道的那个子任务在等 EOF。于是 `task.terminate()` 排在一个
///    「只有 EOF 到了才会返回」的 `await` 之后 —— **一次都没被执行过**。
///    那句「超时 5 秒」是个装饰。
/// 2. **EOF 会不来。** 压测里大约第 10 次必现一次：子进程已经退出
///    （`task.isRunning == false`），但 `readDataToEndOfFile()` 就是不返回 ——
///    管道写端还被别的进程持有（fd 继承）。
///
/// 两个缺陷合起来正是用户报的「点一下刷新，一直转圈，像死循环」：
/// ``ContentView/refreshDisks()`` 永远不返回，`defer { isRefreshing = false }`
/// 永远不执行。因为它**偶发**（约 1/10），本地点两下未必能复现，极难定位。
///
/// ## 现在怎么写
///
/// - 输出走 `FileHandle.readabilityHandler`（**回调式，不阻塞任何线程**）；
/// - 超时由 `DispatchQueue.asyncAfter` 负责 —— 它跑在自己的线程上，
///   **既不依赖被测进程、也不依赖 Swift 并发线程池**，所以超时**真的会发生**；
/// - 超时后 `terminate()` 杀掉子进程，并以 `nil` 收尾。
///
/// **压测对照**：同样 100 次（含 1.7MB 输出的根卷），本类型全部 ≤ 0.36s 返回；
/// 旧写法在第 10 次左右必挂。
final class SubprocessOutput: @unchecked Sendable {

    private let lock = NSLock()
    private let task = Process()
    private let pipe = Pipe()
    private let timeout: TimeInterval
    private let completion: (String?) -> Void
    private var buffer = Data()
    private var finished = false

    /// 超时**已发生**。置位之后，**任何**收尾路径都只能按「没拿到」（`nil`）走。
    ///
    /// ⚠️ 为什么必须有这个位（2026-09-20 CI 实测撞到一次）：超时块里先 `terminate()`
    /// 再 `complete(nil)`，而 `terminate()` 会让管道**立刻 EOF** ⇒ `readabilityHandler`
    /// 收到空 chunk ⇒ `completeFromBuffer()` 以**「输出收齐了」**收尾。
    /// 这与超时块的 `complete(nil)` 是**竞态**：谁先到谁生效。
    /// EOF 先到时调用方拿到的是 **空字符串**而不是 `nil` ⇒
    /// 「没拿到」被读成「拿到了、但输出为空」，上层会按「没有占用进程」而不是「不知道」处理
    /// —— **症状与真问题逐字相同**。
    ///
    /// ⚠️ 它只在**负载下**偶发：本地一次都没复现，CI 上 434 条测试并发时炸了一次
    /// （`SubprocessOutputTests.超时是真超时而不是装饰` 拿到 `""`）。
    /// ⇒ 判据放在**同一把锁里**（见 `complete`），不靠「先到先得」。
    private var timedOut = false

    /// 结束后可读到输出；`nil` = 没拿到（启动失败或超时）。
    private(set) var output: String?

    /// ⚠️ 超时定时器**不共用全局队列**。
    ///
    /// `DispatchQueue.global()` 上同时排着本类的管道可读性回调与其它 GCD 工作；
    /// CI 负载高时 `asyncAfter` 实测**晚了 2.4s ~ 5s**（2026-09-20：
    /// `SubprocessOutputTests.超时是真超时而不是装饰` 把超时设成 1s，
    /// 实测 `elapsed` 5.98s ⇒ 断言 `< 5` 红）。
    ///
    /// 超时是本类的**正确性前提** —— 晚了就等于「超时是装饰」那个 bug 又回来了
    /// （用户报的「刷新一直转圈」正是那条路）。⇒ 给它一条专用队列。
    private static let timerQueue = DispatchQueue(label: "SafeOut.SubprocessOutput.timeout")

    /// 是否已经收尾（同步路径靠它轮询）。
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        self.timeout = timeout
        self.completion = completion
        task.executableURL = executableURL
        task.arguments = arguments
        task.standardOutput = pipe
        // **stderr 不进管道**：它会和 stdout 抢那 64KB 缓冲，
        // 填满之后子进程阻塞在写、父进程阻塞在读，又是一处死锁。直接丢弃。
        task.standardError = FileHandle.nullDevice
    }

    /// 启动。**一定**会通过 `completion` 回调恰好一次（正常结束或超时）。
    ///
    /// 调用方**不需要**持有本实例：`start()` 里的两个闭包都强引用 self，
    /// 实例会一直活到收尾；收尾时 `readabilityHandler` 置 nil，循环引用随之断开。
    func start() {
        do {
            try task.run()
        } catch {
            complete(nil)
            return
        }

        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF：写端全部关闭，输出收齐了
                completeFromBuffer()
                return
            }
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }

        Self.timerQueue.asyncAfter(deadline: .now() + timeout) { [self] in
            // ⚠️ **先置位再 terminate**：`terminate()` 会立刻造成 EOF，
            //    而 EOF 路径此刻正盯着「输出收齐了」这条路 —— 置位晚一步就会被它抢先。
            lock.lock()
            timedOut = true
            lock.unlock()
            if task.isRunning {
                task.terminate()
            }
            // 走到这里说明 EOF 没来（或来得太晚）—— 按「没拿到」收尾，
            // 上层会按授权状态兜底，绝不让调用方永远等下去。
            complete(nil)
        }
    }

    private func completeFromBuffer() {
        lock.lock()
        let text = String(data: buffer, encoding: .utf8)
        lock.unlock()
        complete(text)
    }

    private func complete(_ value: String?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        // ⚠️ **判据必须与 `timedOut` 在同一把锁里判定**：超时一旦置位，
        //    不管是超时块还是（terminate 造成的）EOF 路径先到，收尾值都只可能是 `nil`。
        //    写成「if timedOut { complete(nil) }」在外面判，锁内锁外之间仍有缝。
        output = timedOut ? nil : value
        let final = output
        lock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        completion(final)
    }
}
