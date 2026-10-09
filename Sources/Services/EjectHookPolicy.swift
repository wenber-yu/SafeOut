import Foundation

// MARK: - 请求（CFType → 纯值）

/// 一次 DA approval 回调里**做判定所需的全部输入**。
///
/// **为什么要有它**：`handle(disk: DADisk)` 拿不到可测的入参 —— `DADisk` 是 CFType，
/// 测试里只能真挂一块盘才能构造。把「取描述字典 → 提取字段」这一步单独做成
/// `make(description:)`，判据就能喂一个 `[String: Any]` 字面量进去。
struct EjectHookRequest: Sendable, Equatable {

    /// 挂载路径，同时也是 ``DiskInfo/id``。
    let mountPath: String
    /// 卷名（`/Volumes` 下显示的那个）。取不到时为空串。
    let volumeName: String
    /// BSD 设备名，如 `disk9s1`。
    let bsdName: String
    /// 设备型号，如 `SanDisk Extreme 55AE`。虚拟设备可能没有。
    let deviceModel: String?
    /// 交给 ``DiskClassifier/isExternalVolume(_:)`` 的设备属性。
    let attributes: DiskClassifier.Attributes

    /// `DADiskCopyDescription` 返回字典里的键名。
    ///
    /// ## 为什么这里写的是字面量，而不是 `kDADiskDescription*Key`
    ///
    /// 本文件是「纯值世界」：**不 import DiskArbitration**。一旦允许 import 那个框架，
    /// `DADisk` 就随手可用，判定层迟早会被掺进 CFType —— 而「把 CFType 挡在判定层之外」
    /// 正是本次要把 `handle` 一分为三的全部理由。
    ///
    /// **代价与兜底**：字面量写错不会编译报错，只会让字段解析不出来 ⇒ 一律放行 ⇒
    /// 症状与「功能没生效」逐字相同。因此由
    /// `EjectHookPolicyTests.描述字典键名与系统常量逐字相同` 反向钉住：
    /// 那条测试 import DiskArbitration，逐键与 `kDADiskDescription*Key` 比较。
    enum DescriptionKey {
        static let volumePath = "DAVolumePath"
        static let volumeName = "DAVolumeName"
        static let mediaBSDName = "DAMediaBSDName"
        static let deviceModel = "DADeviceModel"
        static let deviceInternal = "DADeviceInternal"
        static let deviceProtocol = "DADeviceProtocol"
        static let volumeNetwork = "DAVolumeNetwork"
        static let mediaEjectable = "DAMediaEjectable"
    }

    /// 从 `DADiskCopyDescription` 的字典解析。
    ///
    /// - Returns: **`nil` = 取不到描述、或没有挂载路径** ⇒ 调用方必须**立即放行**。
    ///
    /// ⚠️ **「没有挂载路径」不是边界情况，是常态**：实测（`.build/probe/da_approval_spike/log-approve.txt`）
    /// `NSWorkspace.unmountAndEjectDevice` 会触发**两个**回调：
    /// ```
    /// UNMOUNT-APPROVAL  vol=SpikeVol bsd=disk9s1 whole=false mount=/Volumes/SpikeVol
    /// EJECT-APPROVAL    vol=-        bsd=disk9   whole=true  mount=-
    /// ```
    /// 第二个是**整个盘**的 eject，它**没有卷名、没有挂载路径**。若这一步不判空，
    /// 它会被当成「一块盘」走进判定 —— 而它正是访达自己推出的**第二阶段**。
    static func make(description: [String: Any]) -> EjectHookRequest? {
        let mountPath = (description[DescriptionKey.volumePath] as? URL)?.path ?? ""
        guard !mountPath.isEmpty else { return nil }

        let attributes = DiskClassifier.Attributes(
            deviceInternal: description[DescriptionKey.deviceInternal] as? Bool,
            deviceProtocol: description[DescriptionKey.deviceProtocol] as? String,
            isNetworkVolume: description[DescriptionKey.volumeNetwork] as? Bool,
            isEjectable: description[DescriptionKey.mediaEjectable] as? Bool,
            mountPath: mountPath)

        return EjectHookRequest(
            mountPath: mountPath,
            // 空串而不是 `"-"`：``DiskInfo/displayName`` 对空卷名会回落到 `bsdName`，
            // 而 `"-"` 会被当成一个真实卷名原样显示给用户。
            volumeName: description[DescriptionKey.volumeName] as? String ?? "",
            bsdName: description[DescriptionKey.mediaBSDName] as? String ?? "",
            deviceModel: description[DescriptionKey.deviceModel] as? String,
            attributes: attributes)
    }
}

// MARK: - 判定

/// 放行的**原因**。
///
/// **为什么要有原因码**：真机上「没提醒」有多种解释（开关是关的 / hook 根本没注册 /
/// 这次不该提醒），它们的表现**逐字相同**。每次回话都打一条带原因码的日志，
/// 才能把「功能没生效」与「功能生效了但这次不该提醒」分开。
enum EjectHookPassReason: String, Sendable, Equatable {
    /// 设置里的开关是关的。开关在**三关之前**读（关掉时本应用在链路上完全不存在）。
    case takeOverDisabled
    /// 这次推出是 SafeOut 自己发起的（``EjectService/isHookSelfInitiated``）。
    case selfInitiated
    /// 取不到描述 / 没有挂载路径（含「整个盘」的 eject 回调）。
    case noVolumePath
    /// 不是外置可推出卷（``DiskClassifier/isExternalVolume(_:)`` 为假）。
    case notExternalVolume
    /// 占用缓存没有**明确列出**占用进程（`.none` / `.unknown` / `.needsFullDiskAccess` / `.occupied([])`）。
    case occupancyNotBlocking
}

/// 判定结论。
///
/// ## 为什么没有「拦截」这个结论（2026-09-29 转向）
///
/// 早期实现有 `.intercept`（弹应用窗 + 同步等用户决定）。真机验收（用户真实 Finder 操作）
/// 证明那条路走不通：DA approval 回调只有「放行」与「拒绝」两个合法回执，
/// 没有「静默取消」—— 用户点「取消」后无论放行还是拒绝，系统框都会弹出来，
/// 反复翻车。转向后的形态是**放行 + 提醒**：命中占用时不拦截，而是
/// **立即放行**（让系统走原生流程），同时把「谁在占用」交给菜单栏提醒。
enum EjectHookDecision: Sendable, Equatable {
    /// 立即回话 `nil`（放行），**不阻塞**。
    case passThrough(EjectHookPassReason)
    /// 放行，同时**提醒**用户「这块盘被占用、谁在占」（供菜单栏提示）。
    ///
    /// ⚠️ **仍然放行**：`notify` 不是拦截。系统会继续走它的推出流程，
    /// 盘还占着 ⇒ 系统弹它自己的「占用中」框 —— 这是 macOS 原生、用户熟悉的闭环，
    /// 本应用不再跟它对抗，只在旁边提供「谁在占用 + 一键关闭并推出」。
    case notify(disk: DiskInfo, processes: [OccupyingProcess])
}

/// 判定层。**纯值、无单例、无 `@MainActor`、无 `DADisk`** —— 全部 P0 判据落在这里。
///
/// **为什么不抽成协议 + 注入 mock**：判据本身是纯函数，不需要替身对象；
/// 协议只会多一层「替身是否保真」的风险。
enum EjectHookPolicy {

    /// 三关 + 开关 → 结论。**顺序即优先级，不可交换**。
    ///
    /// 顺序与理由：
    /// 1. `isTakeOverEnabled` —— 开关在三关之前读；关掉时本应用在链路上**完全不存在**，
    ///    连日志噪音都不该有；
    /// 2. `isSelfInitiated` —— 自排除。**必须早于任何查缓存/提醒**：漏了它 = 自己提醒自己；
    /// 3. `isExternalVolume` —— 判错会把系统盘/网络卷交给用户（``DiskClassifier`` 的注释）；
    /// 4. `occupancy` —— **只有明确列出占用进程才提醒**（`.occupied([])` 也放行）。
    static func decide(
        _ request: EjectHookRequest,
        isSelfInitiated: Bool,
        isTakeOverEnabled: Bool,
        occupancy: OccupancyResult
    ) -> EjectHookDecision {
        guard isTakeOverEnabled else { return .passThrough(.takeOverDisabled) }
        guard !isSelfInitiated else { return .passThrough(.selfInitiated) }
        guard DiskClassifier.isExternalVolume(request.attributes) else {
            return .passThrough(.notExternalVolume)
        }
        guard let processes = shouldNotify(occupancy) else {
            return .passThrough(.occupancyNotBlocking)
        }

        // 提醒只需要盘名与图标，容量等字段不参与 —— 给 0 而不是去读磁盘列表
        // （读列表要跨 actor，而这里在 DA 回调线程上）。
        let disk = DiskInfo(
            id: request.mountPath,
            bsdName: request.bsdName,
            volumeName: request.volumeName,
            mountPath: request.mountPath,
            totalBytes: 0,
            usedBytes: 0,
            freeBytes: 0,
            deviceProtocol: request.attributes.deviceProtocol,
            deviceModel: request.deviceModel)
        return .notify(disk: disk, processes: processes)
    }

    /// 占用结论里**该提醒的进程列表**；`nil` = 不提醒。
    ///
    /// 与 `EjectUI.preemptivelyOccupied` 同款判定：`.none` = 确认无占用；
    /// `.unknown` = 还没测出来（让系统自己判）；`.needsFullDiskAccess` = 用户没授权；
    /// `.occupied([])` = 系统说忙但列不出具体程序（空提醒无意义）。
    ///
    /// **抽成独立函数**是为了让「四种放行」各自能被一条单测钉住 —— 写在 `decide` 的
    /// `guard case` 里时，只有「都放行」这一个整体行为可断言。
    static func shouldNotify(_ occupancy: OccupancyResult) -> [OccupyingProcess]? {
        guard case .occupied(let processes) = occupancy, !processes.isEmpty else { return nil }
        return processes
    }
}
