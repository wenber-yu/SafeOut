import Foundation
import OSLog

/// 一张已附着的磁盘映像（DMG）。
///
/// **为什么它算「占用者」**：访达挂载的 DMG 由 `diskimagesiod`（uid `_diskimagesiod`）持有
/// backing 文件；未授予「完全磁盘访问」时 `lsof` 看不到这个进程（不是同 uid），
/// 于是「DMG 占着外置盘」在占用列表里完全隐形（2026-10-13 用户真机事故，error.log 里
/// 11 条「未能列出占用进程」）。而 `hdiutil info` 是**用户级**接口，不需要任何授权
/// 就能列出全部已附着映像——它正是补上这块检测盲区的钥匙。
struct AttachedDiskImage: Sendable, Equatable {

    /// backing 文件（`.dmg`）的完整路径，如 `/Volumes/wenbo-data/Games/Game.dmg`。
    let imagePath: String

    /// 顶层设备节点，如 `/dev/disk6`——`hdiutil detach` 的目标。
    ///
    /// ⚠️ 必须是**整盘**节点而不是分区节点（`/dev/disk6s1`）：detach 以整盘为单位。
    let device: String
}

/// `hdiutil info -plist` 输出的解析与「backing 在不在某卷上」的匹配。
///
/// 全部为**纯函数**，不碰子进程——解析逻辑是整个 DMG 检测里最容易写错的部分
/// （plist 层级、顶层 disk 与分区节点的区分、卷名前缀误匹配），必须能离线单测。
enum DiskImageInfoParser {

    /// 解析 `hdiutil info -plist` 的输出。
    ///
    /// plist 结构（实测）：
    /// ```
    /// { images: [ { "image-path": "/path/to.dmg",
    ///               "system-entities": [ { "dev-entry": "/dev/disk6",  ... },
    ///                                    { "dev-entry": "/dev/disk6s1", "mount-point": ... }, ... ] },
    ///             ... ] }
    /// ```
    ///
    /// 顶层 device 的选取规则：`system-entities` 的所有 `dev-entry` **按字符串长度升序取第一个**——
    /// 整盘节点 `/dev/disk6` 恒比它的分区 `/dev/disk6s1` 短。不能按下标取：
    /// system-entities 的顺序不保证整盘在前。
    ///
    /// 无 `image-path` 或没有任何 `dev-entry` 的映像**跳过**（无法定位、也无法 detach，
    /// 留个不能操作的条目只会误导）。
    static func parse(plist: Data) -> [AttachedDiskImage] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil),
            let dict = root as? [String: Any],
            let images = dict["images"] as? [[String: Any]]
        else { return [] }

        return images.compactMap { image in
            guard let imagePath = image["image-path"] as? String, !imagePath.isEmpty else {
                return nil
            }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let device =
                entities
                .compactMap { $0["dev-entry"] as? String }
                .min(by: { $0.count < $1.count })
            guard let device else { return nil }
            return AttachedDiskImage(imagePath: imagePath, device: device)
        }
    }

    /// 筛出 backing 文件位于指定卷上的映像。
    ///
    /// ⚠️ **前缀必须带尾斜杠**（`mountPath + "/"`）：`/Volumes/data2/x.dmg` 也以前缀
    /// `/Volumes/data` 开头，不带斜杠会把别的卷的映像误算到这块盘上——
    /// 那会让「关闭并推出」去 detach 一张与目标盘无关的映像。
    static func backing(under mountPath: String, of images: [AttachedDiskImage]) -> [AttachedDiskImage] {
        let prefix = mountPath.hasSuffix("/") ? mountPath : mountPath + "/"
        return images.filter { $0.imagePath.hasPrefix(prefix) }
    }
}

/// 已附着磁盘映像的获取入口（带 TTL 缓存与单飞）。
///
/// ## 为什么要缓存 + 单飞
///
/// `hdiutil info` 是**全局**调用（列出全系统所有映像，与本应用查哪块盘无关），
/// 而 ``OccupancyDetector/detect(mountPath:)`` 会被 ``OccupancyStore`` 按盘**并行**调用、
/// 推出路径上还会再调。若每盘各跑一次 hdiutil，N 块盘就是 N 个子进程风暴。
/// ⇒ 5s TTL 缓存（与 ``OccupancyStore`` 15s 轮询同量级，一轮里所有盘共享一次结果），
/// 并用「单飞」保证并发调用方只触发一次真实抓取：后到者挂起等同一班机。
final class DiskImageOccupancyProvider: @unchecked Sendable {

    static let shared = DiskImageOccupancyProvider()

    private static let logger = Logger(subsystem: "com.safeout.app", category: "DiskImage")

    /// hdiutil 单次调用的最长等待（秒）。本机实测 `hdiutil info -plist` 约 0.05~0.3s，留足余量。
    static let hdiutilTimeout: TimeInterval = 5

    /// 缓存有效期（秒）。`OccupancyStore` 轮询周期 15s，5s 保证「同一轮里所有盘共享一次抓取」，
    /// 又不会让「用户刚挂载/刚弹出一张 DMG」的可见性拖过一轮轮询。
    static let cacheTTL: TimeInterval = 5

    /// 实际抓取（生产 = 跑 hdiutil；测试注入替身，完全离线）。
    private let fetch: () async -> String?

    private let lock = NSLock()
    private var cache: (images: [AttachedDiskImage], at: Date)?
    private var inFlight = false
    private var waiters: [CheckedContinuation<[AttachedDiskImage]?, Never>] = []

    /// - Parameter fetch: 返回 `hdiutil info -plist` 的原始 stdout；`nil` = 没拿到（失败/超时）。
    init(fetch: @escaping () async -> String? = { await DiskImageOccupancyProvider.hdiutilInfoOutput() }) {
        self.fetch = fetch
    }

    /// 取当前已附着的映像列表。
    ///
    /// - Returns: 映像数组（可为空 = 系统里没有附着任何映像）；`nil` = 获取失败。
    ///   失败与「没有映像」必须区分：上层（``OccupancyDetector``）对失败按「无 DMG 贡献」
    ///   降级，而不是按「已确认没有映像」。
    ///
    /// 锁操作全部在 ``nextAction()`` / ``enqueueOrResolve(_:)`` / ``finishFlight(_:)``
    /// 三个**同步**辅助方法里——Swift 6 禁止在 async 上下文直接调 `NSLock.unlock()`。
    func images() async -> [AttachedDiskImage]? {
        switch nextAction() {
        case .cached(let images):
            return images
        case .joinFlight:
            return await withCheckedContinuation { enqueueOrResolve($0) }
        case .startFlight:
            let output = await fetch()
            let parsed = output.map { DiskImageInfoParser.parse(plist: Data($0.utf8)) }
            if parsed == nil {
                Self.logger.notice("hdiutil info 获取失败，本轮按无 DMG 贡献降级")
            }
            finishFlight(parsed)
            return parsed
        }
    }

    /// 本次调用的走向（缓存命中 / 搭同班机 / 发起抓取）。
    private enum Action {
        case cached([AttachedDiskImage])
        case joinFlight
        case startFlight
    }

    /// 判定本次调用走向；判定为 ``Action/startFlight`` 时**同时**把 `inFlight` 占位
    /// （判定与占位在同一把锁里，否则两个并发调用方会各自发起一次抓取）。
    nonisolated private func nextAction() -> Action {
        lock.lock()
        defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < Self.cacheTTL {
            return .cached(cache.images)
        }
        if inFlight { return .joinFlight }
        inFlight = true
        return .startFlight
    }

    /// 搭同班机：挂进 waiters 等抓取完成时被统一唤醒。
    ///
    /// ⚠️ 「判 inFlight」与「挂进 waiters」必须在**同一把锁**里完成：
    /// 若先放锁再挂，抓取完成方可能恰好在这个缝里把 waiters 取空并唤醒——
    /// 后挂进去的 continuation 就永远等不到人（泄漏 + 调用方永久挂起）。
    /// ``finishFlight(_:)`` 先置 `inFlight = false`、写好缓存再放锁，
    /// 因此这里读到 false 时结果必然已经落定，直接按缓存/失败收尾。
    nonisolated private func enqueueOrResolve(
        _ continuation: CheckedContinuation<[AttachedDiskImage]?, Never>
    ) {
        lock.lock()
        if inFlight {
            waiters.append(continuation)
            lock.unlock()
            return
        }
        let value: [AttachedDiskImage]? =
            if let cache, Date().timeIntervalSince(cache.at) < Self.cacheTTL {
                cache.images
            } else {
                nil
            }
        lock.unlock()
        continuation.resume(returning: value)
    }

    /// 抓取收尾：写缓存（成功时）、清占位、唤醒所有同班机等待者。
    nonisolated private func finishFlight(_ parsed: [AttachedDiskImage]?) {
        lock.lock()
        inFlight = false
        if let parsed {
            cache = (parsed, Date())
        }
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: parsed)
        }
    }

    /// 同步版本，仅供 `--diagnostics` 一次性自检使用（与 ``OccupancyDetector/detectSync`` 同约束）。
    ///
    /// 不挂单飞：diagnostics 是退出即止的开发者工具，同步执行可彻底避开生命周期陷阱。
    /// 成功时顺手写缓存，让紧随其后的异步调用直接命中。
    func imagesSync() -> [AttachedDiskImage]? {
        let run = SubprocessOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["info", "-plist"],
            timeout: Self.hdiutilTimeout
        ) { _ in }
        run.start()
        // 转 run loop 而不是信号量：回调被派发到哪条队列由系统决定，堵死当前线程可能撞车。
        let deadline = Date().addingTimeInterval(Self.hdiutilTimeout + 3)
        while !run.isFinished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let output = run.output else { return nil }
        let parsed = DiskImageInfoParser.parse(plist: Data(output.utf8))
        lock.lock()
        cache = (parsed, Date())
        lock.unlock()
        return parsed
    }

    /// 分离一张映像（`hdiutil detach <device>`）。
    ///
    /// **不判成败、不返回结果**：分离失败的唯一权威证据是「它还在 `hdiutil info` 列表里」，
    /// 而 ``EjectFlowController/terminateAndEject(disk:processes:awaiting:)`` 的清场复检
    /// 本来就会重新跑一遍占用检测——分离失败的映像会自然出现在复检结果里、
    /// 作为「仍占用」交回 UI。在这里再判一次退出码只是给同一个结论多加一条会分叉的路径。
    static func detach(device: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            logger.notice("分离磁盘映像 \(device, privacy: .public)")
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", device],
                timeout: 15
            ) { _ in
                continuation.resume()
            }
            run.start()
        }
    }

    /// 异步执行 `hdiutil info -plist` 并取回全部 stdout（生产抓取的默认实现）。
    private static func hdiutilInfoOutput() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // `run` 不需要调用方持有：`SubprocessOutput.start()` 里的闭包强引用 self，
            // 实例会活到收尾为止（与 lsof 路径同一模式）。
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["info", "-plist"],
                timeout: hdiutilTimeout
            ) { result in
                // `hdiutil info -plist` 失败时 stdout 为空、plist 解析会得到空列表；
                // 这里沿用旧行为（只取 stdout），不让 stderr 参与 —— 磁盘映像列表的
                // 失败语义本来就被上层当成「补不到额外占用者」，不是检测失败。
                continuation.resume(returning: result?.output)
            }
            run.start()
        }
    }
}
