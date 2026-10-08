import AppKit
import Combine
import Foundation

/// 外置可推出卷的单一事实来源（菜单栏与主窗口共用）。
///
/// **为什么需要它**：此前 `AppDelegate`（`currentDisks`）与 `ContentView`（`disks`）各持一份列表、
/// 各自监听挂载通知，导致「插拔后是否自动刷新」「看到哪些盘」两处可能分叉。
/// 本 store 集中持有列表与监听，所有 UI 只读取 ``disks``，保证看到的磁盘集合永远一致。
///
/// 监听只投递到 `NSWorkspace.shared.notificationCenter`（本机实测：默认 `NotificationCenter.default`
/// 收不到挂载事件），且只在未来事件生效，因此 `init` 里先同步填一次初始列表。
@MainActor
final class DiskListStore: ObservableObject {

    static let shared = DiskListStore { DiskService.shared.fetchExternalDisks() }

    @Published private(set) var disks: [DiskInfo] = []

    private var observers: [NSObjectProtocol] = []

    /// 真正干活的枚举入口。**可注入**是为了让 `refresh()` 的并发合并能被离线单测
    /// （见 ``fetchDisks`` 与 `init(fetch:monitoring:)`）。
    ///
    /// 生产一律走 `DiskService.shared.fetchExternalDisks()`；测试注入一个会「卡住一轮」
    /// 的替身，才能构造出「第一轮还在跑、第二个请求挤进来」那个窗口 ——
    /// 真机上那个窗口只有几毫秒宽，靠真实枚举**根本撞不出来**。
    private let fetchDisks: @Sendable () -> [DiskInfo]

    private init(fetch: @escaping @Sendable () -> [DiskInfo]) {
        self.fetchDisks = fetch
        setupMonitoring()
        // 监听只对未来事件生效，先同步填一次初始列表。
        disks = fetch()
    }

    #if DEBUG
        /// **测试专用**：造一个不挂系统监听、磁盘列表可手动灌入的实例。
        ///
        /// **为什么需要这个口子**：`disks` 是 `private(set)`，唯一写入路径 `refresh()`
        /// 会真的去枚举本机磁盘 —— 单测既没法用它构造「刚插上一块盘」，
        /// 也会因为测试机上真实的插拔而随机变红。
        /// 生产构建里不存在这个初始化器（`#if DEBUG`），`shared` 也不受影响。
        init(monitoring: Bool) {
            self.fetchDisks = { DiskService.shared.fetchExternalDisks() }
            if monitoring { setupMonitoring() }
            disks = []
        }

        /// **测试专用**：注入枚举实现，让 ``refresh()`` 的合并行为可离线断言。
        ///
        /// 传 `monitoring: false` 避免测试去挂真实系统监听（那会在测试机上真被触发）。
        init(fetch: @escaping @Sendable () -> [DiskInfo], monitoring: Bool = false) {
            self.fetchDisks = fetch
            if monitoring { setupMonitoring() }
            disks = []
        }

        /// **测试专用**：替换磁盘列表并像 `refresh()` 那样发布一次。
        ///
        /// 刻意**不做去重**：`@Published` 每次赋值都会投递，这正是
        /// ``OccupancyStore`` 用 `sink` 而不是视图里 `.onChange(of:)` 的原因 ——
        /// 后者在「新数组内容相等」时静默不触发，导致「刷新」按钮刷不动占用结论。
        func replaceDisksForTesting(_ newDisks: [DiskInfo]) {
            disks = newDisks
        }
    #endif

    /// 是否已有一轮枚举在跑。跑着的时候新请求只登记 ``pendingRerun``，由那一轮顺带补跑。
    ///
    /// **为什么必须有它**（同 ``OccupancyStore/refresh(disks:)`` 的同一套合并模式）：
    /// `refresh()` 有**五个**触发源 —— 挂载通知、卸载通知、菜单栏展开、面板刷新按钮、
    /// ``EjectUI`` 收掉预弹窗之后那次。它们之间没有任何互斥，插拔盘 + 连点刷新这类
    /// 正常操作就会让两轮 ``fetchExternalDisks()`` **并发**跑。
    ///
    /// 而它不是廉价操作：内含 ``DASessionCreate`` + 逐卷 ``DADiskCopyDescription``，
    /// 是真的磁盘 I/O。并发两轮的直接后果是**后完成的那轮覆盖先完成的那轮** ——
    /// 两次枚举之间系统状态若变了（盘刚被推出、或另一轮读到了更新的描述），
    /// 列表会闪回旧内容。
    private var isRefreshing = false

    /// 「本轮跑完之后还要不要再补一轮」。
    ///
    /// **为什么是布尔而不是排队**（与 `OccupancyStore` 的 `pending` 的区别）：
    /// 那一侧的 `refresh(disks:)` **带参数**——后来的调用可能要求测不同的盘列表，
    /// 所以必须保存「最新的那一份」。而本方法**没有参数**：每一轮都是「重新枚举当前所有卷」，
    /// 无论来几次、要来几次，**要算的答案都只有一个** ⇒ 合并成「再补一轮」即可，
    /// 不需要保存调用方的意图。
    private var pendingRerun = false

    /// 已登记、但被合并进当前这一轮（或补跑那一轮）的调用方。
    ///
    /// **为什么必须唤醒它们**：调用方（如面板上的刷新按钮）是 `await refresh()` 之后
    /// 才停转的 spinner，提前返回会让转圈撒谎 ——「转完了，列表还是旧的」。
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// 重新枚举外置卷。涉及磁盘 I/O，放到后台线程执行后回到主线程更新。
    ///
    /// ## 并发调用会被合并，但不会被丢弃
    ///
    /// 若已有一轮在跑，本次请求登记「还要补一轮」并等那一轮结束；跑完的那轮若看到
    /// 补跑标记，会**立刻**再枚举一次，然后才唤醒所有等待者。
    ///
    /// ⚠️ 这里也踩过 ``OccupancyStore`` 记录过的那个坑：改成「有 worker 就
    /// `await worker.value` 然后 return」是**错的** —— worker 可能在「检查标记」与
    /// 「退出」之间那一瞬间已经决定退出，于是新请求登记进去就永远不会被处理，
    /// 而调用方却正常返回了。表现为「点了刷新，偶尔没反应」。所以必须是
    /// 登记 + 等「本轮与补跑全部排空」。
    func refresh() async {
        if isRefreshing {
            pendingRerun = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        repeat {
            pendingRerun = false
            let fetch = fetchDisks
            let fetched = await Task.detached(priority: .userInitiated) { fetch() }.value
            disks = fetched
        } while pendingRerun
        isRefreshing = false
        // ⚠️ `isRefreshing = false` 与唤醒之间**不能有 `await`**（同 `OccupancyStore`）：
        // 否则这个窗口里进来的新请求会看到 `isRefreshing == false`、自己起一轮，
        // 同时又把自己登记进了 `refreshWaiters`，而那一批已经被我们取走 ⇒ 唤醒就丢了。
        let resuming = refreshWaiters
        refreshWaiters = []
        for continuation in resuming { continuation.resume() }
    }

    private func setupMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: NSWorkspace.shared, queue: .main) { [weak self] _ in
                // 通知在 .main 队列投递，但 Swift 并发语境下仍需显式切回主 actor 再刷新。
                Task { @MainActor in await self?.refresh() }
            }
            observers.append(token)
        }
    }
}
