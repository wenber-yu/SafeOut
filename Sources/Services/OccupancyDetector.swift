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

    /// 磁盘映像（DMG）占用来源。`lsof` 看不到的「访达挂载的 DMG」由它补上
    /// （`hdiutil info` 无需完全磁盘访问，见 ``DiskImageOccupancyProvider``）。
    ///
    /// 开放测试注入：替身返回 `nil`（获取失败）时行为与引入本属性**之前**逐字一致。
    let diskImageProvider: DiskImageOccupancyProvider

    /// 开放给测试注入 mock 子类；生产环境一律使用 `shared`。
    init(diskImageProvider: DiskImageOccupancyProvider = .shared) {
        self.diskImageProvider = diskImageProvider
    }

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
            // lsof「没跑成」（启动失败 / 超时 / **stderr 非空**）：**绝不能**落成 `.none`。
            //
            // 这里曾经返回 `.none`（旁边注释还写着「不把失败当安全」，实现却与注释相反）
            // ⇒ 只要 lsof 没跑成，`DiskRowState(.none)` 就把行渲染成「可安全推出」。
            // 这正是用户报的「拷贝进行中，两块盘都显示可安全推出」：拷贝期间 lsof 偶发
            // 拿不到结果（路径瞬时失效、或子进程被杀），于是失败被静默读成了安全。
            //
            // ⚠️ 上一版又把判据收得太紧（「退出码非 0 ⇒ 没跑成」），于是**合法卷但无匹配**
            // （退出码同样是 1、stderr 0 字节）也被当成失败 ⇒ 用户报「为什么现在有的硬盘
            // 会显示占用未知」。现在的判据是 stderr 是否为空，实测依据见
            // ``lsofResult(_:)`` —— 那条路不会走到这里（stderr 为空时返回空字符串）。
            //
            // 走到这里时按授权状态区分兜底，两条**都不返回 `.none`**：
            // - 已授权 ⇒ `.unknown`：环境/工具层面的失败，用户无从下手，只能显式说「不知道」；
            // - 未授权 ⇒ `.needsFullDiskAccess`：用户可补救的权限缺口，引导去系统设置授权。
            return authorized ? .unknown : .needsFullDiskAccess
        }

        let processes = Self.parseLsof(output)
        // 合并磁盘映像占用：`lsof` 看不到 `diskimagesiod`（uid `_diskimagesiod`，无 FDA 时
        // 跨 uid 不可见），但 `hdiutil info` 无需授权就能列出「backing 文件在本卷上」的映像。
        // 这正是「访达挂载的 DMG 挡推出、应用却显示无占用」（2026-10-13 事故）的修复点。
        let images = await diskImageProvider.images() ?? []
        let merged = Self.merging(lsof: processes, diskImages: images, mountPath: mountPath)
        if !merged.isEmpty {
            // 能列出占用者即证明已授权（或占用来自 hdiutil，无需授权），直接返回（核心价值）。
            //
            // 这里必须补一步「应用身份解析」：lsof 的 `c` 字段只是可执行名（`IMVIDEO`），
            // 用户在 Dock 里看到的是应用显示名（`Bunny`）。解析放在检测阶段（每轮一次）
            // 而不是视图渲染阶段，既避免每帧重复解析，也让下游（含纯函数文案层）拿到的
            // 就是可直接展示的完整模型。详见 ``ProcessAppResolver``。
            // （磁盘映像条目在 enrich 里被原样跳过，见 ``ProcessAppResolver/enrich(_:)``。）
            return .occupied(await ProcessAppResolver.enrich(merged))
        }
        // lsof 空行且卷上无 DMG：已授权 → 确实无占用（可安全推出）；未授权 → 提示授权。
        return authorized ? .none : .needsFullDiskAccess
    }

    /// 把 lsof 进程列表与磁盘映像列表合并成统一的占用者列表（纯函数，单测靶子）。
    ///
    /// 规则：
    /// 1. 映像先按「backing 文件在本卷上」过滤（``DiskImageInfoParser/backing(under:of:)``）；
    /// 2. 卷上有映像时，剔除 lsof 结果里的 `diskimagesiod` —— 它只是系统 holder 进程，
    ///    用户无权终止它（EPERM），列出来只会误导；映像条目才是「可关闭」的那个；
    /// 3. 进程在前、映像在后（用户认知里「程序」优先）。
    static func merging(
        lsof processes: [OccupyingProcess],
        diskImages images: [AttachedDiskImage],
        mountPath: String
    ) -> [OccupyingProcess] {
        let imagesOnVolume = DiskImageInfoParser.backing(under: mountPath, of: images)
        guard !imagesOnVolume.isEmpty else { return processes }
        let imageEntries = imagesOnVolume.map {
            OccupyingProcess.diskImage(imagePath: $0.imagePath, device: $0.device)
        }
        let realProcesses = processes.filter { $0.processName != "diskimagesiod" }
        return realProcesses + imageEntries
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
            // 与异步 ``detect(mountPath:)`` 同款语义：lsof 没跑成绝不落 `.none`（见那里的长注释）。
            return authorized ? .unknown : .needsFullDiskAccess
        }
        let processes = Self.parseLsof(output)
        // 与异步 ``detect(mountPath:)`` 同款合并（见那里的注释）。
        let images = diskImageProvider.imagesSync() ?? []
        let merged = Self.merging(lsof: processes, diskImages: images, mountPath: mountPath)
        if !merged.isEmpty {
            return .occupied(ProcessAppResolver.enrich(merged))
        }
        return authorized ? .none : .needsFullDiskAccess
    }

    /// 把一次 lsof 子进程的收尾结果归约成「有没有跑成」（纯函数，单测靶子）。
    ///
    /// - 返回 `nil` ⇒ **没跑成**（启动失败 / 超时 / lsof 往 stderr 报了错）；
    /// - 返回字符串 ⇒ 跑成了，值就是 stdout。**空字符串是有效结果**（= 没有匹配，即「无占用」）。
    ///
    /// ## 判据是「stderr 是否为空」，**不是退出码**（2026-10-27 实测更正）
    ///
    /// 上一版把「退出码非 0」一律判成「没跑成」，结果是**任何 lsof 列不出东西的盘都显示
    /// 「占用未知」**（用户报「为什么现在有的硬盘会显示占用未知」）。实测证据如下：
    ///
    /// | 场景 | 退出码 | stdout | stderr |
    /// |---|---|---|---|
    /// | 失效路径 `/Volumes/NoSuchVol` | 1 | 0 字节 | **539 字节**（`lsof: status error on …: No such file or directory` + usage） |
    /// | 合法卷但无匹配 `/Volumes/wenbo-data`（已挂载 HFS+） | 1 | 0 字节 | **0 字节** |
    /// | 合法子目录无匹配 `/Volumes/wenbo-data/Applications` | 1 | 0 字节 | **0 字节** |
    /// | 正常有占用 `/Volumes/拍摄项目资料1` | 0 | 1496 字节 | 0 字节 |
    /// | 正常有占用 `/` | 0 | 2568063 字节 | 0 字节 |
    ///
    /// ⇒ **`lsof` 的退出码 1 是二义的**：它既表示「没有列出任何文件」（正常结束），
    /// 也表示真错误。**唯一可靠的区分信号是 stderr 是否为空**：
    /// - stderr 非空 ⇒ lsof 自己说了有问题，按「没跑成」处理（上层按授权状态兜底，
    ///   绝不落成「无占用」—— 那样 UI 会显示「可安全推出」）；
    /// - stderr 为空 ⇒ lsof 正常跑完了，stdout 为空只是「没有匹配」。
    ///
    /// 退出码仍然保留在 ``SubprocessResult`` 里（排查与测试要用），但**不参与判定**。
    static func lsofResult(_ result: SubprocessResult?) -> String? {
        guard let result else { return nil }
        guard result.errorOutput.isEmpty else { return nil }
        return result.output
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
        // 判据看 stderr 而不是退出码（见 ``lsofResult(_:)``）：合法卷无匹配时退出码也是 1，
        // 但 stderr 为 0 字节 —— 那是「正常跑完、没有占用」，不能落成「没跑成」。
        return Self.lsofResult(run.result)
    }

    // MARK: - lsof

    /// 执行 lsof 并取回输出。
    ///
    /// - Returns: lsof 的原始 stdout；`nil` = **没跑成**（启动失败 / 超时 / stderr 非空）。
    ///   空字符串是有效结果（= 正常跑完且无匹配，即「确实无占用」）。
    nonisolated private static func lsofOutput(mountPath: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // `-Fpcn0`：机器可读输出（p=PID、c=命令名、n=路径），记录以 NUL 分隔。
            // 不用默认表格格式——它按空格切列，进程名含空格时会错位，见 ``parseLsof`` 的说明。
            //
            // ⚠️ **不要顺手加 `-X`**：它在 lsof 里的语义反直觉 —— `-X` = 「**跳过 mmap 文件**」，
            // 而不带 `-X` 时**会**列出「mmap 之后已 close 掉 fd」的进程（2026-09-09 实测）。
            // 那正是最隐蔽的一类占用者 ⇒ 加 `-X` 等于把它们从结果里抹掉。
            //
            // `run` 不需要调用方持有：``SubprocessOutput/start()`` 里的闭包
            // （两个 readabilityHandler 与超时块）都强引用 self，实例会活到收尾为止。
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-Fpcn0", mountPath],
                timeout: lsofTimeout
            ) { result in
                // stdout 与 stderr 一起交给纯函数归约（见 ``lsofResult(_:)``）：
                // 空 stdout 的歧义由 stderr 是否为空来消解，**退出码不参与判定**。
                continuation.resume(returning: Self.lsofResult(result))
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

/// 一次子进程跑完之后可用的**全部**证据。
///
/// 三个字段同生共死：正常收尾时三样都有值（`output` / `errorOutput` 都可以是空字符串），
/// 启动失败 / 超时时整个结果为 `nil`（见 ``SubprocessOutput``）。
///
/// **为什么要把 stderr 一起交出来**：lsof 的退出码 1 是二义的 —— 合法卷「无匹配」
/// 与「路径失效」都会退 1、stdout 都 0 字节，**只有 stderr 能区分**
/// （实测表见 ``OccupancyDetector/lsofResult(_:)``）。把 stderr 丢掉，上层就只能
/// 靠退出码猜，而那正是「有的盘显示占用未知」这个回归的来源。
struct SubprocessResult: Sendable, Equatable {

    /// 标准输出（按 UTF-8 解码；空字符串是有效结果）。
    let output: String

    /// 子进程退出码。**保留给排查与测试，不作为「跑成没跑成」的判定依据**。
    let exitStatus: Int32

    /// 标准错误（按 UTF-8 解码）。**空字符串 = 子进程没有报错**，这是本次修复的判据。
    let errorOutput: String
}

/// 跑一次子进程，把它 stdout 与 stderr 的**全部**输出收集回来，**并保证一定收尾**。
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
/// ## 退出码与 stderr（2026-10-27 修订）
///
/// 自然收尾要**同时**满足「两条管道都 EOF」与「进程真的结束」（由 `terminationHandler` 给出），
/// 前者保证输出收齐、后者保证退出码可信（`Process.terminationStatus` 只在进程结束后有效）。
///
/// **判定「跑成没跑成」的权威信号是 stderr 是否为空，不是退出码**：
/// `lsof <合法卷>`（无匹配）与 `lsof <失效路径>` 的 stdout 都是 0 字节、退出码都是 1，
/// 只有「失效路径会把错误写进 stderr」能区分两者（实测表见
/// ``OccupancyDetector/lsofResult(_:)``）。退出码仍随结果交出，但只作排查线索。
///
/// ⚠️ **上一版误把「退出码非 0」当成唯一判据**，于是所有「列不出占用者」的合法盘都被
/// 判成检测失败、显示「占用未知」—— 这是本次要修掉的回归，别再改回去。
///
/// **压测对照**：同样 100 次（含 1.7MB 输出的根卷），本类型全部 ≤ 0.36s 返回；
/// 旧写法在第 10 次左右必挂。
final class SubprocessOutput: @unchecked Sendable {

    private let lock = NSLock()
    private let task = Process()

    /// stdout 与 stderr **各自一条独立管道**。
    ///
    /// 上一版把 stderr 直接丢给 `FileHandle.nullDevice`，理由是「它会和 stdout 抢 64KB 缓冲，
    /// 填满之后子进程阻塞在写、父进程阻塞在读」。现在两路都走 `readabilityHandler`
    /// （**回调式排空、不阻塞任何线程**），所以「写满 → 阻塞」这个前提不成立 ——
    /// 而 stderr 又是 lsof 成败的唯一可靠判据（见 ``SubprocessResult`` 的说明），必须收。
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()

    private let timeout: TimeInterval
    private let completion: (SubprocessResult?) -> Void
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var finished = false

    /// stdout 管道是否已到 EOF（= 标准输出收齐）。
    private var sawOutputEOF = false

    /// stderr 管道是否已到 EOF（= 标准错误收齐）。
    ///
    /// 两条管道**都要**收尾才能定案：否则可能「stdout 收齐了、stderr 还在路上」，
    /// 这时按空 stderr 判「跑成」会把一次真错误读成「无占用」。
    private var sawErrorEOF = false

    /// 子进程是否已**真正结束**。**只有它为真时 ``termination`` 才有效**。
    private var processEnded = false

    /// 子进程退出码。仅在 ``processEnded`` 为真时有意义
    ///（`Process.terminationStatus` 只在进程真的结束后才有效，见 ``start()``）。
    private var termination: Int32?

    /// 超时**已发生**。置位之后，**任何**收尾路径都只能按「没拿到」（`nil`）走。
    ///
    /// ⚠️ 为什么必须有这个位（2026-09-20 CI 实测撞到一次）：超时块里先 `terminate()`
    /// 再按「没拿到」收尾，而 `terminate()` 会让管道**立刻 EOF** ⇒ `readabilityHandler`
    /// 收到空 chunk ⇒ 收尾条件以**「输出收齐了」**成立。
    /// 这与超时块自己的「没拿到」是**竞态**：谁先到谁生效。
    /// EOF 先到时调用方拿到的是 **空字符串**而不是 `nil` ⇒
    /// 「没拿到」被读成「拿到了、但输出为空」，上层会按「没有占用进程」而不是「不知道」处理
    /// —— **症状与真问题逐字相同**（2026-10-27 修的就是这一类：失败被静默读成「可安全推出」）。
    ///
    /// ⚠️ 它只在**负载下**偶发：本地一次都没复现，CI 上 434 条测试并发时炸了一次
    /// （`SubprocessOutputTests.超时是真超时而不是装饰` 拿到 `""`）。
    /// ⇒ 判据放在**同一把锁里**（见 ``complete(_:)``），不靠「先到先得」。
    /// output / exitCode / stderr 也同锁一起落成 `nil`。
    private var timedOut = false

    /// 收尾后的完整结果；`nil` = 没拿到（启动失败 / 超时）。
    ///
    /// **三样证据在同一把锁里落定**（见 ``complete(_:)``），不会出现
    /// 「stdout 有值但 stderr 还是初值」这种半截状态。
    private(set) var result: SubprocessResult?

    /// 结束后可读到 stdout；`nil` = 没拿到（启动失败 / 超时）。
    var output: String? { result?.output }

    /// 结束后可读到子进程退出码；`nil` = **退出码无意义**（启动失败 / 超时 / 还没收尾）。
    var exitStatus: Int32? { result?.exitStatus }

    /// 结束后可读到 stderr；`nil` = 没拿到（启动失败 / 超时）。
    ///
    /// `""` 是有效值，表示「子进程没有报错」—— 判定「跑成没跑成」靠的就是它
    /// （见 ``OccupancyDetector/lsofResult(_:)``）。
    var errorOutput: String? { result?.errorOutput }

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

    /// - Parameter completion: 收尾回调，参数是完整的 ``SubprocessResult``：
    ///   `nil` = 没拿到（启动失败 / 超时）；非 `nil` 时 stdout / stderr / 退出码
    ///   在**同一把锁里**一起落定。**判定「跑成没跑成」看 `errorOutput` 是否为空**，
    ///   不是退出码（见 ``OccupancyDetector/lsofResult(_:)``）。
    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping @Sendable (SubprocessResult?) -> Void
    ) {
        self.timeout = timeout
        self.completion = completion
        task.executableURL = executableURL
        task.arguments = arguments
        task.standardOutput = outputPipe
        // stderr 也必须收（见 ``outputPipe`` 的说明）：lsof 的成败判据就在它里面。
        // 两条管道各自由一个 `readabilityHandler` 排空，不存在「抢同一块缓冲」的问题。
        task.standardError = errorPipe
    }

    /// 启动。**一定**会通过 `completion` 回调恰好一次（正常结束或超时）。
    ///
    /// 调用方**不需要**持有本实例：`start()` 里的三个闭包都强引用 self，
    /// 实例会一直活到收尾；收尾时 `readabilityHandler` 置 nil，循环引用随之断开。
    func start() {
        // ⚠️ **必须在 `run()` 之前设好**：`terminationHandler` 在进程**已经退出**后才设，
        //    有可能永远收不到回调（「刚开始就退出」的进程会漏掉，见 `SubprocessAwait` 的同款说明）。
        //    漏掉就意味着 `processEnded` 永远为 false ⇒ 收尾只能靠超时 ⇒ 一次**成功**的检测
        //    会被误判成「没跑成」。
        //    退出码只在这里读（`Process.terminationStatus` 只有进程真的结束后才有效），
        //    并**在同一把锁里**与「是否收尾」一起落定（见 ``tryFinish()``）。
        task.terminationHandler = { [self] finished in
            lock.lock()
            processEnded = true
            termination = finished.terminationStatus
            lock.unlock()
            tryFinish()
        }

        do {
            try task.run()
        } catch {
            // 启动失败 ⇒ 没有任何可信证据，按「没跑成」收尾（整个结果为 `nil`）。
            complete(nil)
            return
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF：写端全部关闭，标准输出收齐了
                lock.lock()
                sawOutputEOF = true
                lock.unlock()
                tryFinish()
                return
            }
            lock.lock()
            outputBuffer.append(chunk)
            lock.unlock()
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF：标准错误也收齐了。**它和 stdout 一样是收尾的必要条件**
                //（少等它就可能把「stderr 还没到」误读成「stderr 为空」）。
                lock.lock()
                sawErrorEOF = true
                lock.unlock()
                tryFinish()
                return
            }
            lock.lock()
            errorBuffer.append(chunk)
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
            // 走到这里说明收尾条件没凑齐（或来得太晚）—— **强制**按「没拿到」收尾。
            // 上层会按授权状态兜底（`.unknown` / `.needsFullDiskAccess`，绝不落 `.none`），
            // 绝不让调用方永远等下去。
            complete(nil)
        }
    }

    /// 自然收尾的判据：**「两条管道都收齐（EOF）」与「进程真的结束」三者必须都满足**。
    ///
    /// ⚠️ **为什么不能只看 stdout EOF 就收尾**：EOF 只说明写端关了，**不保证**
    /// `terminationHandler` 已经跑过 ⇒ 此刻读 `termination` 会拿到 `nil` ⇒
    /// 一次**成功**的 lsof（退出码 0）会被误报成「没跑成」。反之只看进程结束也不行
    /// （可能还有缓冲没读回来）。stderr 同理：它的 EOF 没到就读它会读到空值，
    /// 而「空 stderr = 跑成了」正是本轮的判据 —— 早读一步就会把真错误读成「无占用」。
    ///
    /// 三个信号（stdout EOF、stderr EOF、termination 回调）都会调到这里，但
    /// ``complete(_:)`` 里的 `finished` 闸门在**同一把锁**内，最多只有一个能真正落定 ——
    /// 不存在「先到先得」把退出码或 stderr 判错的缝。
    private func tryFinish() {
        lock.lock()
        guard !finished, sawOutputEOF, sawErrorEOF, processEnded, let status = termination else {
            lock.unlock()
            return
        }
        // 三样证据在**同一把锁内**构造，避免「读 stdout 之后 stderr 又追加了一段」的半截结果。
        let result = SubprocessResult(
            output: String(data: outputBuffer, encoding: .utf8) ?? "",
            exitStatus: status,
            errorOutput: String(data: errorBuffer, encoding: .utf8) ?? "")
        lock.unlock()
        complete(result)
    }

    /// 收尾并回调（恰好一次）。
    ///
    /// - Parameter value: 完整结果（正常路径）或 `nil`（启动失败 / 超时）。
    private func complete(_ value: SubprocessResult?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        // ⚠️ **判据必须与 `timedOut` 在同一把锁里判定**：超时一旦置位，
        //    不管是超时块还是（terminate 造成的）EOF 路径先到，收尾值都只可能是 `nil`。
        //    写成「if timedOut { complete(nil) }」在外面判，锁内锁外之间仍有缝。
        //    stdout / stderr / 退出码是**同一个结构体**，一起落成 `nil`，不会只丢一半。
        self.result = timedOut ? nil : value
        let final = self.result
        lock.unlock()
        // 三个闭包都强引用 self（见 ``start()``）；收尾时一并置 nil 才能断开循环引用。
        // 不清就是一个「每跑一次子进程泄漏一个实例」的环（本应用 15s 轮询会持续触发）。
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        task.terminationHandler = nil
        completion(final)
    }
}
