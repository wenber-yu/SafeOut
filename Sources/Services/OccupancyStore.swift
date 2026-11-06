import Combine
import Foundation

/// 卷占用结论的**单一事实来源**（主窗口与菜单栏面板共用同一份）。
///
/// ## 为什么需要它
///
/// 2026-09-15 用户报：「主窗口显示有程序占用，菜单栏面板显示没有占用，这用的不是同一套逻辑吗？」
///
/// 检测逻辑确实是同一套 —— 两个界面都走 `EjectFlowController.checkOccupancy` →
/// `OccupancyDetector.detect`。**问题出在状态被抄了两份**：
/// `ContentView` 与 `MenuPopoverView` 各持一个 `@State var occupancy`，
/// 各自按各自的节奏去刷新：
///
/// | | 主窗口 | 菜单面板 |
/// |---|---|---|
/// | 首次加载 | `.task` | `.task`（每次点开都重建视图 → 每次都跑） |
/// | 定时刷新 | **15s 轮询** | **无** |
/// | 应用重新激活 | `didBecomeActiveNotification` | 无 |
/// | 磁盘列表变化 | `.onChange(of: store.disks)` | 同左 |
///
/// 于是「同一个时刻，两块盘，两个结论」在结构上就是可能的 —— 面板看到的是它自己被创建那一刻的快照，
/// 而主窗口看到的是最近一次 15s tick 的结果。中间任何一次插拔、任何一次进程开关文件，
/// 都会让两边分叉。
///
/// 更隐蔽的一条：`.onChange(of:)` 只在**值不相等**时触发。
/// `DiskListStore.refresh()` 每次都把新数组赋给 `disks`，内容一样时 `onChange` 静默不触发 ——
/// 面板上的「刷新磁盘列表」按钮因此**从来不会刷新占用结论**，只刷新容量数字。
///
/// ## 做法
///
/// 把「状态」与「节奏」都收进本类，两个界面退化成纯读取：
/// - 一份 `results`，两边读的是同一个字典、同一帧的值；
/// - 一个 15s 轮询循环，**只要本类被创建就在跑**，与「哪个窗口开着」无关；
/// - 监听 `DiskListStore.$disks`（`sink` 而非 `onChange`，每次赋值都触发）。
///
/// ## 生命周期
///
/// `shared` 是懒加载单例：第一次有界面读它时创建并启动轮询。
/// 两个界面都关掉后它仍在跑（每 15s 一次 `lsof`，代价可忽略），
/// 这样再次打开任何界面时看到的是**最新的**结论，而不是「刚打开那一刻重新测」。
@MainActor
final class OccupancyStore: ObservableObject {

    static let shared = OccupancyStore()

    /// 全部已挂载卷的占用结论，键是 ``DiskInfo/id``。
    ///
    /// **读不到时请用 `.unknown` 而不是 `.none`**：`.none` 是「已确认没有占用」，
    /// 把「还没测出来」渲染成它是本应用最不能犯的错误（见 ``DiskRowState``）。
    @Published private(set) var results: [String: OccupancyResult] = [:]

    /// 每块卷「正在被写入」的证据（键与 ``results`` 同源）。
    ///
    /// ## 为什么它是**另一条通道**，而不是塞进 `results`
    ///
    /// 用户报的症（2026-10-30）：访达正在拷贝，两块盘却显示「可安全推出」。
    /// 成因是 `lsof` 对访达拷贝**零命中**（不需要完全磁盘访问就看不到它持有哪些文件），
    /// 而容量在稳定增长 —— 后者是**不需要权限**的独立证据（见 ``VolumeWriteActivity``）。
    ///
    /// ⚠️ **绝不能把它造成一条合成 ``OccupyingProcess`` 塞进 `results`**：
    /// `EjectUI.eject` 会把 `results` 里的进程当成「可终止对象」交给
    /// `terminateAndEject`，而写入活动**没有 pid**（伪造一个就等于朝不存在的进程发
    /// `kill`）。所以两条通道各自发布，UI 只把「没有进程 + 有写入」归约成
    /// 琥珀色的「正在写入」，不改变「关闭并推出」的语义。
    @Published private(set) var activities: [String: VolumeWriteActivity] = [:]

    /// 上一轮的容量采样，用于算写入速率。键是 ``DiskInfo/id``。
    ///
    /// 只保留**最新一轮**：磁盘拔出后它必须消失，否则同名卷再插上来会拿别的盘的旧读数做差。
    private var lastSamples: [String: (bytes: Int64, at: Date)] = [:]

    /// 正在等待处理的磁盘列表。新的请求会**覆盖**旧的 —— 我们只关心最新状态。
    private var pending: [DiskInfo]?

    /// 是否已有一轮检测在跑。跑着的时候新请求只登记 `pending`，由那一轮顺带处理。
    private var isRunning = false

    /// 登记了请求、但被合并进当前这一轮的调用方。
    ///
    /// **为什么要有它**：被合并的调用方不能就这么返回 —— `ContentView` 的刷新按钮
    /// 是 `await refresh(...)` 之后才停转的，提前返回会让 spinner 撒谎
    /// （转完了，界面还是旧结论）。当前这一轮跑完时统一唤醒它们。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var pollingTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private let diskStore: DiskListStore
    private let pollInterval: TimeInterval
    private let detect: @Sendable (String) async -> OccupancyResult
    /// 当前时刻。测试注入固定时钟，让「速率」可以被精确断言。
    private let now: () -> Date
    /// 读一个卷的可用空间。测试注入假读数，完全离线。
    private let availableBytes: @Sendable (String) -> Int64?

    /// - Parameters:
    ///   - diskStore: 磁盘列表来源，默认全局单例。
    ///   - pollInterval: 轮询间隔（秒）。设计上取 15s —— 与主窗口原来的节奏一致。
    ///   - detect: 单卷检测入口。默认走生产链路；测试注入替身即可完全离线。
    ///   - autoStart: 是否立即开始监听与轮询。测试里传 `false` 手动驱动。
    ///   - now: 时钟，默认读系统时间。
    ///   - availableBytes: 容量读数，默认真实 `statfs`（只读）。
    init(
        diskStore: DiskListStore? = nil,
        pollInterval: TimeInterval = 15,
        detect: @escaping @Sendable (String) async -> OccupancyResult = { mountPath in
            await EjectFlowController.shared.checkOccupancy(mountPath: mountPath)
        },
        autoStart: Bool = true,
        now: @escaping () -> Date = Date.init,
        availableBytes: @escaping @Sendable (String) -> Int64? =
            VolumeWriteActivityDetector.availableBytes(atMountPath:)
    ) {
        self.diskStore = diskStore ?? .shared
        self.pollInterval = pollInterval
        self.detect = detect
        self.now = now
        self.availableBytes = availableBytes
        if autoStart { start() }
    }

    /// 开始监听磁盘列表变化并启动轮询。重复调用无副作用。
    func start() {
        guard pollingTask == nil else { return }

        // **用 `sink` 而不是视图里的 `.onChange(of:)`**：`@Published` 每次赋值都会投递，
        // 哪怕新旧数组内容相等。用户点「刷新磁盘列表」时我们**必须**重新测一次占用 ——
        // `.onChange` 会因为「值没变」而安静地什么都不做。
        //
        // 这里**不再单独发一次初始刷新**：`@Published` 的订阅会**立即投递当前值**，
        // 那次投递就是首帧刷新。再补一次会让首帧连测两轮（实测 counter 从 1 变 2），
        // 白跑一遍 `lsof`。
        let diskStore = self.diskStore
        diskStore.$disks
            .sink { [weak self] disks in
                // **同步判定这次发布的性质**：`@Published` 在赋值当下同步投递，
                // 此刻的标记说的正是这一次（晚一步可能已被下一次发布改写）。
                // 容量刷新只换数字、卷集合没变，重跑 lsof 纯属浪费；而且紧挨着的一轮
                // 会让写入活动的速率采样落空，界面在「正在写入」与「可安全推出」之间闪。
                guard !diskStore.lastPublishWasCapacityOnly else { return }
                Task { @MainActor in await self?.refresh(disks: disks) }
            }
            .store(in: &cancellables)

        let interval = pollInterval
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // `Task.sleep` 被取消时会立刻抛出，若不在循环里再判一次就会变成忙等。
                guard !Task.isCancelled, let self else { return }
                // **先把容量数字拉到最新，再取快照**：否则这一轮测的是上一轮的旧容量，
                // 界面会一直落后 15s —— 拷贝时行上写着「已用 3.4 MB」而旁边写着「正在写入」。
                // 这次发布被标记为「只换容量」，订阅方不会因此多跑一轮 lsof（见 `sink`）。
                self.diskStore.refreshCapacities()
                await self.refresh(disks: self.diskStore.disks)
            }
        }
    }

    /// 停止轮询与监听（测试收尾用；生产不需要）。
    ///
    /// 顺带唤醒还挂着的等待者：`stop()` 之后当前这一轮仍会跑完，
    /// 但万一调用方是在 `stop()` 之后才登记进来的，不让它永远挂着。
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        cancellables.removeAll()
        pending = nil
        let resuming = waiters
        waiters = []
        for continuation in resuming { continuation.resume() }
    }

    /// 取某块盘的判定结论。**主窗口与菜单面板都必须走这里**。
    ///
    /// **为什么不让调用方各写一遍 `results[disk.id] ?? .unknown`**：
    /// 兜底值写错一次就是灾难 —— 兜成 `.none` 会让「还没测出来」显示成
    /// 「可以安全推出」，而 `.none` 与 `.unknown` 在类型上都是合法的 `OccupancyResult`，
    /// 编译器不会拦。收成一个方法后，「读不到时兜什么」只有一处定义，也能被单测钉住。
    func result(for disk: DiskInfo) -> OccupancyResult {
        results[disk.id] ?? .unknown
    }

    /// 取某块卷的写入活动证据；这一轮没测到写入时返回 `nil`。
    ///
    /// ⚠️ **`nil` 不等于「可安全推出」**：安全与否由 ``result(for:)`` 回答，
    /// 这里只说「这一轮没测到容量变化」。两个信息的合成在 ``DiskRowState`` 里做 ——
    /// 分开读、分开兜底，才能保证任何一处写错都不会把「不知道」渲染成「安全」。
    func activity(for disk: DiskInfo) -> VolumeWriteActivity? {
        activities[disk.id]
    }

    /// 按给定磁盘列表刷新占用结论。
    ///
    /// **并发调用会被合并，但不会被丢弃**：若已有一轮检测在跑，本次请求覆盖 `pending`
    /// 并等待那一轮结束 —— 循环会在处理完手头这批之后**立刻**再处理最新的一批，
    /// 然后才唤醒所有等待者。
    ///
    /// **这里踩过一个坑**（值得记下来）：第一版写的是「有 worker 就 `await worker.value`
    /// 然后 return」。问题是 worker 可能在「检查 `pending`」与「退出循环」之间那一瞬间
    /// 已经决定退出 —— 此时新请求登记进去就**永远不会被处理**，
    /// 而调用方却正常返回了。表现为「点了刷新，偶尔没反应」。
    /// 现在改成：登记 + 等待「本轮全部排空」，不存在这个窗口。
    func refresh(disks: [DiskInfo]) async {
        pending = disks
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        while let next = pending {
            pending = nil
            await performDetect(disks: next)
        }
        isRunning = false
        // `isRunning = false` 与唤醒之间**不能有 `await`**：否则这个窗口里进来的新请求
        // 会看到 `isRunning == false`、自己起一轮，同时又把自己登记进了 `waiters`，
        // 而那一批 `waiters` 已经被我们取走 —— 唤醒就丢了。
        let resuming = waiters
        waiters = []
        for continuation in resuming { continuation.resume() }
    }

    /// 真正跑一轮检测：并发测每一块盘，**整体替换** `results`。
    ///
    /// **整体替换而不是逐个合并**：磁盘拔出后它的旧结论必须消失。
    /// 若只更新测到的键，拔掉的那块盘的结论会永远留在字典里，
    /// 下次同名卷再插上来会先显示一段别人的旧结论。
    private func performDetect(disks: [DiskInfo]) async {
        guard !disks.isEmpty else {
            if !results.isEmpty { publish([:]) }
            if !activities.isEmpty { activities = [:] }
            // 磁盘全拔了：旧读数必须一起消失，否则同路径卷再插上来会拿别的盘的读数做差。
            lastSamples = [:]
            return
        }
        // **采样放在检测之前**：这一轮的容量读数与「上一轮」的读数做差，
        // 间隔稳定 ≈ 轮询周期。放在 `lsof` 之后会让间隔随 `lsof` 耗时抖动，
        // 而速率是「差值 ÷ 间隔」，间隔不稳就等于速率不准。
        publishActivities(sampleActivities(disks: disks))

        let detect = self.detect
        var next: [String: OccupancyResult] = [:]
        await withTaskGroup(of: (String, OccupancyResult).self) { group in
            for disk in disks {
                // 只捕获字符串：闭包要跨 actor 边界，别把整个 DiskInfo 拖过去。
                let id = disk.id
                let path = disk.mountPath
                group.addTask { (id, await detect(path)) }
            }
            for await (id, result) in group { next[id] = result }
        }
        publish(next)
    }

    /// 占用结论的**唯一写入点**：同时写 ``results``（给界面）与 ``OccupancySnapshotStore``（给 hook）。
    ///
    /// **为什么必须收敛成一处**：``OccupancySnapshotStore`` 是 DA approval 回调线程读的那份
    /// （非主线程不能碰 `@MainActor` 单例，见该类的说明），而 `results` 是界面读的那份。
    /// 两处各写一遍必然分叉 ——「两个界面看到两个结论」正是本类诞生时要修的病
    /// （见本文件顶部那段「为什么需要它」）。
    private func publish(_ next: [String: OccupancyResult]) {
        results = next
        OccupancySnapshotStore.update(next)
    }

    /// 采一轮容量，返回这一轮测到的写入活动。
    ///
    /// **键跟着 `disks` 整体替换**：拔掉的盘不进 `next`，它的活动也就随之消失。
    ///
    /// ## 只有「这一轮真的做出了判定」才允许撤销写入活动（2026-10-30 用户报告）
    ///
    /// 用户报的症：拷贝电影的过程中，盘上「正在写入」**闪一下就变回「没有占用」**。
    /// 成因是采样把「**没测出来**」当成了「**没在写**」：
    ///
    /// - 速率 = 两轮读数之差 ÷ 间隔，间隔 < ``VolumeWriteActivityDetector/minimumInterval``
    ///   时这个式子不可信，`detect` 只能返回 `nil`；
    /// - 而 ``publishActivities(_:)`` 是**整体替换**，这一轮的 `nil` 立刻把上一轮真实的
    ///   「正在写入」抹掉 —— 于是一次「额外的、赶巧的」第二轮就能让界面闪一下。
    ///
    /// 这种额外一轮在生产里至少有三条来源（都不该被当成「写入停了」）：
    ///
    /// | 来源 | 两轮间隔 |
    /// |---|---|
    /// | 点刷新：`DiskListStore.refresh()` 的发布 + 视图紧接着那次显式 `refresh(disks:)` | 毫秒级 |
    /// | 切回应用：`didBecomeActiveNotification` 那次 refresh 撞上后台轮询 | 亚秒级 |
    /// | 插拔盘：挂载通知的刷新紧挨着轮询 tick | 亚秒级 |
    ///
    /// ⇒ 判据写成「**只有间隔足够长、且这一轮确实没测到写入，才算停手**」；
    /// 其余情况（间隔太短 / 读不到容量 / 还没有上一轮读数）**沿用上一轮的结论**。
    /// 这与「读不到 ≠ 没有」是同一条纪律（见 ``activity(for:)`` 的说明）。
    ///
    /// 代价：用户正好在两次采样之间停手时，那条「正在写入」会多留到下一个有效采样
    /// （最长一个轮询周期）。这比「拷贝进行中反复闪成『可以安全推出』」轻得多 ——
    /// 后者是会让人拔盘的错误提示。
    private func sampleActivities(disks: [DiskInfo]) -> [String: VolumeWriteActivity] {
        let at = now()
        var samples: [String: (bytes: Int64, at: Date)] = [:]
        var detected: [String: VolumeWriteActivity] = [:]
        for disk in disks {
            // 读不到（刚卸载、权限…）：没有读数 ≠ 没有写入 ⇒ 沿用上一轮，不撤销。
            guard let bytes = availableBytes(disk.mountPath) else {
                carryOver(diskId: disk.id, into: &detected)
                continue
            }
            samples[disk.id] = (bytes, at)
            // 首轮（或刚插上的卷）没有可比较的读数：这一轮同样下不了结论。
            guard let previous = lastSamples[disk.id] else {
                carryOver(diskId: disk.id, into: &detected)
                continue
            }
            // 间隔太短：差分会把任何一次调度抖动放大成假速率，既不报写入、也不撤销写入。
            guard at.timeIntervalSince(previous.at) >= VolumeWriteActivityDetector.minimumInterval
            else {
                carryOver(diskId: disk.id, into: &detected)
                continue
            }
            if let activity = VolumeWriteActivityDetector.detect(
                previousBytes: previous.bytes,
                previousAt: previous.at,
                currentBytes: bytes,
                currentAt: at)
            {
                detected[disk.id] = activity
            }
            // 走到这里 = 间隔可信 + 没测到写入 ⇒ **真的停手了**，不放进 `detected` 即撤销。
        }
        lastSamples = samples
        return detected
    }

    /// 这一轮对某块卷下不了结论时，把上一轮的结论原样带过去。
    ///
    /// **取的是已发布的 `activities`，不是某份缓存**：它正是界面此刻显示的那一条，
    /// 带着去就不会出现「数据说没在写、界面还在说在写」的分叉。
    private func carryOver(diskId: String, into detected: inout [String: VolumeWriteActivity]) {
        guard let previous = activities[diskId] else { return }
        detected[diskId] = previous
    }

    /// 写入活动与占用结论同理：**整体替换**（拔掉的盘不带着旧活动继续显示）。
    ///
    /// 这里多一道「相等就跳过」：`sampledAt` 让两次采样几乎永不相等，所以它只在
    /// **两边都为空**（没有盘在写）时起作用 —— 闲着的机器上就不必每 15s 白刷一次界面。
    private func publishActivities(_ next: [String: VolumeWriteActivity]) {
        guard activities != next else { return }
        activities = next
    }
}
