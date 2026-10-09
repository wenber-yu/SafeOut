import AppKit
import DiskArbitration
import Foundation
import OSLog

/// 接管访达（Finder）与其它进程的「推出」请求 —— 监听「点推出但盘被占用」。
///
/// ## 链路（spike 已在 `.build/probe/da_approval_spike/` 实证）
///
/// 访达的推出按钮 → `NSWorkspace.unmountAndEjectDevice` 走 DiskArbitration →
/// ``DARegisterDiskUnmountApprovalCallback`` / ``DARegisterDiskEjectApprovalCallback``。
/// 本类**不拦截、不阻塞**：判定命中「这块盘被占用」时**立即放行**（让系统走原生流程，
/// 系统自己弹「占用中」框），同时把「谁在占用」异步交给 ``EjectAttentionCenter``
/// 驱动菜单栏提示。
///
/// 判定走 ``EjectHookPolicy``（纯值、可单测），本类只做「解析 → 判定 → 放行 + 提醒」的编排。
///
/// ## ⚠️ 关键约束（spike 实证后落字）
///
/// 1. **必须自排除**：``EjectService/eject(disk:)`` 在 `unmountAndEjectDevice` 之前把
///    ``EjectService/isHookSelfInitiated`` 置 `true`；本类回调里读到即放行，
///    否则自己发起的推出也会触发提醒。
/// 2. **不能碰 `@MainActor`**：本类的回调跑在 `com.diskejector.da.approval` 上
///    （**实测 `isMainThread == false`**）。在那里写 `MainActor.assumeIsolated` 会
///    **SIGTRAP 崩掉整个进程**（实测退出码 133）⇒ 占用结论一律读
///    ``OccupancySnapshotStore``（非隔离快照），提醒走 `Task { @MainActor in … }`。
/// 3. **崩溃安全**：spike 实测 kill 掉持有回调的进程后，DA 把「没有 approval 者」视作批准
///    ⇒ SafeOut 崩了不会把用户的盘永久卡死。
///
/// ## 开关语义边界
///
/// ``AppSettings/takeOverFinderEject`` 只控制「**要不要在推出被占用时提醒**」。
/// **自排除**与**无挂载路径放行**永远生效，与开关无关。
/// 开关**每次回调现读、不缓存**（改了即时生效，不用重启）；注册的回调本身
/// **保持注册、永不注销**（注销再注册要处理「注销期间到达的请求漏掉」这类时序问题）。
final class EjectHookService: @unchecked Sendable {

    static let shared = EjectHookService()

    private init() {}

    private static let logger = Logger(subsystem: "com.safeout.app", category: "EjectHook")

    /// 单例 session；同一进程只注册一次（重复注册会重复触发回调）。
    private var session: DASession?

    /// 注册两个 approval callback。**只在 app 启动时调一次**。
    func register() {
        guard session == nil else {
            Self.logger.notice("EjectHookService 已注册，跳过")
            return
        }
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            Self.logger.error("DASessionCreate 失败，hook 不生效")
            return
        }
        // 派发到专用并发队列 —— 阻塞回调只会卡这条队列，不影响 UI。
        let queue = DispatchQueue(
            label: "com.diskejector.da.approval", attributes: .concurrent)
        DASessionSetDispatchQueue(s, queue)

        DARegisterDiskUnmountApprovalCallback(s, nil, Self.unmountApproval, nil)
        DARegisterDiskEjectApprovalCallback(s, nil, Self.ejectApproval, nil)
        session = s
        Self.logger.notice("已注册 unmount/eject approval")
    }

    /// 开关为真时**显式启动**占用轮询。
    ///
    /// ## 为什么必须有这个动作
    ///
    /// ``OccupancyStore`` 是**懒加载单例** —— 第一次有界面读它时才创建并启动轮询。
    /// 而全仓对它的触达点只有三处：`ContentView`（默认参数，**用户打开主窗口**时）、
    /// `SafeOutApp`（用户从**菜单栏自己**发起推出时）、以及本类回调。
    ///
    /// ⇒ 用户打开开关、然后**直接在访达里点推出**（正是本功能的目标场景！）时，
    /// `OccupancyStore` 可能**根本还没被创建** ⇒ 快照是空的 ⇒ 读到 `.unknown` ⇒
    /// 一律不提醒 ⇒ **功能静默不生效**，而且这条在日志上与「开关没打开」长得一样。
    ///
    /// **为什么不在启动时无条件创建**：那会给**所有**用户（包括从没开过这个开关的）
    /// 每 15s 一次 `lsof` + 一次磁盘列表刷新。开关默认关，就不该有后台代价。
    ///
    /// **调用点有两处**（缺一不可）：`applicationDidFinishLaunching` 末尾
    /// （上次开过开关 ⇒ 本次启动就绪，无需先开主窗口）、设置面板开关行 toggle 之后
    /// （刚打开开关 ⇒ 当场就绪，不必等下次启动）。
    @MainActor
    static func syncOccupancyPolling() {
        guard AppSettings.takeOverFinderEject else { return }
        _ = OccupancyStore.shared  // init 里就会 start()
    }

    // MARK: - Approval callbacks（C 函数指针，不能捕获 self）

    private static let unmountApproval: DADiskUnmountApprovalCallback = { disk, _ in
        handle(disk: disk)
    }
    private static let ejectApproval: DADiskEjectApprovalCallback = { disk, _ in
        handle(disk: disk)
    }

    /// 真正的判定 + 放行 + 提醒。**这里不再同步阻塞** —— 命中占用立即放行，
    /// 提醒异步发到菜单栏。
    ///
    /// 五段：自排除 → 解析 → 开关 → 读快照 → 判定（放行 / 提醒）。顺序即优先级，**不可交换**。
    private static func handle(disk: DADisk) -> Unmanaged<DADissenter>? {
        // ① 自排除：发起者是我们自家（读静态标志，不碰 CFType）。
        let selfInitiated = EjectService.isHookSelfInitiated

        // ② 解析：CFType → 纯值。取不到描述 / 没有挂载路径 ⇒ 立即放行。
        //    「整个盘」的 eject 回调（访达推出的第二阶段）走的就是这一支。
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
            let request = EjectHookRequest.make(description: description)
        else {
            log(.noVolumePath, mountPath: nil)
            return nil
        }

        // ③ 开关：**在三关之前**读（关掉时本应用在链路上完全不存在）。
        let enabled = AppSettings.takeOverFinderEject

        // ④ 占用结论：读**非隔离快照**，不是 `OccupancyStore.shared`
        //    —— 后者是 `@MainActor`，在本线程上读会 SIGTRAP 崩掉整个进程。
        let occupancy = OccupancySnapshotStore.occupancy(for: request.mountPath)

        // ⑤ 判定。
        let decision = EjectHookPolicy.decide(
            request, isSelfInitiated: selfInitiated, isTakeOverEnabled: enabled,
            occupancy: occupancy)

        switch decision {
        case .passThrough(let reason):
            log(reason, mountPath: request.mountPath)
            return nil

        case .notify(let diskInfo, let processes):
            // **立即放行**（系统走原生流程，盘占着 ⇒ 系统弹「占用中」框），
            // 同时异步把「谁在占用」交给菜单栏提醒。
            logger.notice(
                "提醒 mount=\(diskInfo.id, privacy: .public) 占用=\(processes.count, privacy: .public)")
            Task { @MainActor in
                EjectAttentionCenter.shared.note(disk: diskInfo, processes: processes)
            }
            return nil
        }
    }

    /// 每次回话打**一条**带原因码的日志。
    ///
    /// **为什么必须打**：真机上「没提醒」有三种解释（开关是关的 / 这次不该提醒 / hook 根本没注册），
    /// 它们的表现**逐字相同**。没有原因码，排查时只能靠猜。
    private static func log(_ reason: EjectHookPassReason, mountPath: String?) {
        logger.notice(
            "放行 reason=\(reason.rawValue, privacy: .public) mount=\(mountPath ?? "-", privacy: .public)"
        )
    }
}
