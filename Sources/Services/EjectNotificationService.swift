import Foundation
import OSLog
import UserNotifications

/// 系统通知：**访达点推出但盘被占用**时，除了菜单栏图标变警示态，再投一条系统通知。
///
/// ## 为什么需要它（2026-09-29 用户需求）
///
/// 菜单栏图标变成警示态，只有「正好在看着菜单栏」的用户才注意得到；而本功能的目标场景
/// 恰恰是「用户在访达里点了推出、然后去干别的」。系统通知是 macOS 里「有事找你」的
/// 标准通道 —— **点它直接落到菜单面板上**，那儿有「关闭并推出」。
///
/// ## 幂等：同一块盘只投一条
///
/// ``EjectAttentionCenter/note(disk:processes:at:)`` 会被访达的重试**反复调用**
/// （同一挂载路径），每retry 都投一条通知会刷屏。去重判据在 ``EjectNotificationPolicy``
/// （纯值、可单测）：**同一挂载路径在 `withdraw` 之前只允许投一条**。
///
/// ## 不打扰没开这个功能的用户
///
/// 授权**只在**真正要用通知的时刻申请（见 ``requestAuthorization()`` 的调用点说明）：
/// 占用提醒走 ``AppSettings/takeOverFinderEject``（启动时已开 / 用户当场打开），
/// 推出结果通知走「用户从本应用发起推出」的那一刻（``EjectUI/eject(disk:cachedOccupancy:)``）
/// —— 两条路都不在启动时无条件弹框。
///
/// ## 降级
///
/// - 没授权：`add(_:)` 静默失败，菜单栏提示照常工作（功能降级，不是坏掉）。
/// - 裸可执行文件（无 bundle id）：通知中心不可用 ⇒ 整个类**不启动**，
///   连 delegate 都不装（见 ``isAvailable``）。
@MainActor
final class EjectNotificationService {

    static let shared = EjectNotificationService()

    private let logger = Logger(subsystem: "com.safeout.app", category: "Notification")

    /// 已投递过通知的挂载路径。**投递与撤回都经过它**，是幂等判据的唯一出处。
    private var policy = EjectNotificationPolicy()

    /// 通知中心**只弱引用** delegate（`UNUserNotificationCenter.delegate` 是 `weak`），
    /// 必须自己持有，否则下一次 runloop 就被回收、点击通知没有任何反应。
    private var delegate: NotificationDelegate?

    private var isStarted = false

    private init() {}

    /// 通知中心能不能用。**以裸可执行文件运行时（`dist/.../SafeOutApp`）没有
    /// bundle id**，`UNUserNotificationCenter.current()` 取不到宿主 ⇒ 一律跳过。
    /// 这也是本仓库「验证要用 `open dist/SafeOut.app`」那条纪律在通知上的投影。
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// 装 delegate、按需申请授权。**启动时调一次**。
    ///
    /// - Parameter onOpenPanel: 用户点击通知本体时要做的事（打开菜单面板）。
    func start(onOpenPanel: @escaping @MainActor () -> Void) {
        guard !isStarted else { return }
        guard Self.isAvailable else {
            logger.notice("通知中心不可用（没有 bundle id，多半是以裸可执行文件运行的），跳过")
            return
        }
        isStarted = true

        let center = UNUserNotificationCenter.current()
        let delegate = NotificationDelegate { Task { @MainActor in onOpenPanel() } }
        self.delegate = delegate
        center.delegate = delegate

        // 「开过这个功能」才申请授权 —— 见类文档「不打扰没开这个功能的用户」。
        if AppSettings.takeOverFinderEject { requestAuthorization() }
    }

    /// 申请通知授权（`.alert` + `.sound`）。**进程内只发一次系统调用**。
    ///
    /// **幂等**：系统只会在第一次弹授权框；之后调用只是拿回既有结论 ——
    /// 但每次推出都白跑一趟系统 API 没有意义，所以本类自己再记一道
    /// ``hasRequestedAuthorization``（拒绝后重调也无意义：用户只能去系统设置里开）。
    ///
    /// 调用点三处：
    /// 1. ``start(onOpenPanel:)`` —— 启动时占用提醒开关已开；
    /// 2. 设置面板打开「推出提醒」开关的那一刻；
    /// 3. ``EjectUI/eject(disk:cachedOccupancy:)`` —— 用户**第一次从本应用发起推出**
    ///    的时刻（2026-10-01 新增，为推出结果通知申请）。这正是「在用户操作上下文
    ///    触发权限请求」：他正在用推出功能，此刻问「要不要结果通知」名正言顺；
    ///    反过来，从没推出过任何盘的用户不该见到这个框。
    ///    第一次推出时框刚弹、结论未定 ⇒ 那一次通知缺席，从第二次起正常。
    func requestAuthorization() {
        guard isStarted, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, error in
            if let error {
                Self.loggerForCallback.error(
                    "申请通知授权失败: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Self.loggerForCallback.notice("用户未授予通知权限 —— 菜单栏提示照常，只是没有系统通知")
            }
        }
    }

    /// 是否已经申请过授权（**进程内去重**，见 ``requestAuthorization()``）。
    private var hasRequestedAuthorization = false

    /// 投一条「这块盘被占用」的通知。
    ///
    /// 幂等判据在 ``EjectNotificationPolicy``：同一挂载路径在撤回之前只投一条。
    /// 通知的**标识符就是挂载路径** —— 这样「撤回这一块盘的通知」不需要另存一份映射。
    func post(_ attention: EjectAttention) {
        guard isStarted else { return }
        guard policy.shouldPost(mountPath: attention.disk.mountPath) else { return }

        let content = UNMutableNotificationContent()
        content.title = String(format: L10n.tr(.ejectAttentionTitle), attention.disk.displayName)
        content.body = String(
            format: L10n.tr(.notifEjectBlockedBody),
            attention.processSummary, L10n.tr(.appName))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: attention.disk.mountPath, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.loggerForCallback.error(
                    "投递通知失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.notice("已投递占用通知 盘=\(attention.disk.mountPath, privacy: .public)")
    }

    /// 投一条「这块盘的推出结果」通知（成功 / 失败；2026-10-01 用户需求）。
    ///
    /// ## 与占用通知的分工
    ///
    /// ``post(_:)`` 说的是「**还没推出** —— 盘被挡下了」；本方法说的是
    /// 「**推出这件事落定了**，成没成」。两条通知的 identifier 前缀不同
    /// （`result:` vs 挂载路径本身），不会互相覆盖、也不会一起撤回。
    ///
    /// ## 为什么 `.busy` 不投（判据在 ``ResultNotificationContent/make(diskName:outcome:)``）
    ///
    /// 「忙」是流程的**中间态**：弹窗正等用户决定，之后「关闭并推出」的最终结果
    /// 会再次回到 ``handle(_:disk:)`` → 本方法 —— 中间态若也发一条，
    /// 用户必然为同一次推出收到两条通知。
    ///
    /// ## 幂等口径
    ///
    /// 与占用通知不同，这里**不做「同盘只发一条」去重**：每次推出都是独立事件，
    /// 推出 → 插回 → 再推出，两次结果都该送达。防刷屏靠 identifier 的
    /// `result:` + 挂载路径 —— 同一块盘的新结果会**覆盖**通知中心里的旧结果。
    func postResult(_ outcome: EjectOutcome, disk: DiskInfo) {
        guard isStarted else { return }
        guard
            let content = ResultNotificationContent.make(
                diskName: disk.displayName, outcome: outcome)
        else { return }

        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.body = content.body
        if content.playsSound { payload.sound = .default }

        let request = UNNotificationRequest(
            identifier: "result:" + disk.mountPath, content: payload, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.loggerForCallback.error(
                    "投递结果通知失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        let isFailure: Bool
        if case .failed = outcome { isFailure = true } else { isFailure = false }
        logger.notice(
            "已投递结果通知 盘=\(disk.mountPath, privacy: .public) 失败=\(isFailure)")
    }

    /// 撤回某块盘的通知（盘已推出 / 提醒已清除），并**允许**它下次重新投递。
    func withdraw(mountPath: String) {
        policy.forget(mountPath: mountPath)
        guard isStarted else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [mountPath])
    }

    /// 给 `@Sendable` 回调用的 logger。
    ///
    /// **为什么不能直接用 `logger`**：`add(_:withCompletionHandler:)` 与
    /// `requestAuthorization(options:completionHandler:)` 的 handler 是 `@Sendable`，
    /// 在它们里面读实例属性等于跨 actor 访问。
    ///
    /// **为什么必须显式 `nonisolated`**：本类是 `@MainActor`，**它的静态成员也跟着被隔离**
    /// —— 不加这个关键字，在 `@Sendable` 闭包里引用会报
    /// 「main actor-isolated static property … can not be referenced from a Sendable closure」。
    /// `Logger` 是 `Sendable` 的值类型，所以脱离隔离是安全的。
    nonisolated private static let loggerForCallback = Logger(
        subsystem: "com.safeout.app", category: "Notification")
}

/// 「这条提醒该不该再投一条系统通知」的**纯判据**。
///
/// 抽成独立的值类型是为了让这条幂等规则能被单测真正跑一遍 —— 它判错的表现是
/// 「访达每重试一次就多一条通知」（刷屏），而那种事**没有任何编译错**。
struct EjectNotificationPolicy: Equatable {

    /// 已经投过通知、尚未撤回的挂载路径。
    private(set) var notifiedMountPaths: Set<String> = []

    /// 该不该为这条挂载路径投通知。**同时记账**：返回 `true` 后该路径即视为已投递。
    mutating func shouldPost(mountPath: String) -> Bool {
        notifiedMountPaths.insert(mountPath).inserted
    }

    /// 撤回记账（盘已推出 / 提醒已清除），允许下次重新投递。
    mutating func forget(mountPath: String) {
        notifiedMountPaths.remove(mountPath)
    }
}

/// 「一次推出结果」该配一条什么内容的通知 —— **纯值判据**，可单测。
///
/// ## 为什么抽出来（同 ``EjectNotificationPolicy`` 的理由）
///
/// 内容判错的临床表现是「失败弹窗说一套、系统通知说另一套」——
/// 两条通道各拼一遍文案，早晚漂移。这里把两条铁律钉成**一个出处**：
/// - 失败通知的正文**就是** ``EjectFailure/reasonText(diskName:)`` ——
///   与失败弹窗的正文同源，改一处两处同步；
/// - ``EjectOutcome/busy(occupying:)`` **不产生内容**（返回 `nil`）——
///   忙是中间态，最终结果会再次走 ``EjectNotificationService/postResult(_:disk:)``，
///   中间态发通知必然重复。
///
/// 声音也是判据的一部分：**失败有声**（用户多半已切走，需要被拉回来）、
/// **成功无声**（确认性质，在通知中心里能看到就够了 —— 拔盘走人前横幅一闪足矣，
/// 响一声反而打扰）。
struct ResultNotificationContent: Equatable {
    let title: String
    let body: String
    /// `true` = 失败（带提示音）；`false` = 成功（静默）。
    let playsSound: Bool

    /// 由推出结果构造通知内容。`nil` = 这次不该发（当前只有 `.busy`）。
    ///
    /// ⚠️ **用 `switch` 而不是 `if case`**：`EjectOutcome` 将来加 case 时这里
    /// **编译不过**（同 ``EjectUI/shouldDismissPreemptivePopup(gate:outcome:)`` 那条纪律）
    /// —— 「哪些结果发通知」失效必须是**红**的，不是静默的。
    static func make(diskName: String, outcome: EjectOutcome) -> Self? {
        switch outcome {
        case .ejected:
            return Self(
                title: String(format: L10n.tr(.notifEjectResultSuccessTitle), diskName),
                body: L10n.tr(.notifEjectResultSuccessBody),
                playsSound: false)
        case .busy:
            return nil
        case .failed(let failure):
            return Self(
                title: String(format: L10n.tr(.notifEjectResultFailureTitle), diskName),
                body: failure.reasonText(diskName: diskName),
                playsSound: true)
        }
    }
}

/// `UNUserNotificationCenter` 的回调接收者。
///
/// **为什么单独一个类**：``EjectNotificationService`` 是 `@MainActor`，而通知回调
/// 来自通知中心的任意队列。把回调收进一个非隔离的小对象、只把「打开面板」这一件事
/// 跳回主 actor，比让整个服务脱离主 actor 干净（也与 ``EjectHookService`` 的理由同源）。
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{

    /// 「点通知」时要做什么。**构造时定下、之后不再改** —— 这是 `@unchecked Sendable`
    /// 在这里成立的前提（`UNUserNotificationCenter.delegate` 的调用来自任意队列）。
    private let onTap: @Sendable () -> Void

    init(onTap: @escaping @Sendable () -> Void) {
        self.onTap = onTap
        super.init()
    }

    /// 应用在**前台**时也要把通知画出来。
    ///
    /// 菜单栏常驻应用（`.accessory`）大多数时候就算「在前台」，而系统默认在应用处于前台时
    /// **不显示**横幅 —— 不实现这一条，用户点开面板的瞬间通知就永远不会出现，
    /// 看起来与「通知没配好」逐字相同。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 用户点击通知本体 —— 打开菜单面板（「关闭并推出」在那儿）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        onTap()
    }
}
