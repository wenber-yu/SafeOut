import AppKit
import Foundation
import OSLog

/// 推出失败的原因分类。
///
/// **为什么不用裸 `Error`**：调用方需要根据失败原因给出完全不同的引导——「磁盘正被使用」应当
/// 提示用户关闭程序后重试，而「权限不足」或「设备已消失」提示重试毫无意义。若只在 UI 层
/// 用 `localizedDescription` 做字符串匹配，一旦系统改动文案就会全部失配。
enum EjectFailure: Error, Sendable, Equatable {

    /// 卷上有进程正在读写（系统返回 `fBsyErr` / `EBUSY`）。
    case inUse

    /// 系统拒绝该操作（例如目标并非可推出设备）。
    case notPermitted

    /// 设备已不在（可能在操作完成前被拔掉或已卸载）。
    case notFound

    /// 未归类的失败，保留原始错误以便诊断。
    case other(String)

    /// 把系统抛出的错误归类。
    ///
    /// 实测（macOS，App Sandbox 内）：对正被进程占用的卷调用
    /// `NSWorkspace.unmountAndEjectDevice(at:)` 会抛出
    /// `NSOSStatusErrorDomain code = -47`，即 `fBsyErr`。
    static func classify(_ error: Error) -> EjectFailure {
        let ns = error as NSError

        // POSIX 层：EBUSY = 16，ENOENT = 2，EPERM / EACCES
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case 16: return .inUse
            case 2: return .notFound
            case 1, 13: return .notPermitted
            default: break
            }
        }

        // OSStatus 层：fBsyErr = -47，fnfErr = -43，permErr = -54，notPermitted = -5000
        if ns.domain == NSOSStatusErrorDomain {
            switch ns.code {
            case -47: return .inUse
            case -43: return .notFound
            case -54, -5000: return .notPermitted
            default: break
            }
        }

        // 兜底：系统未提供结构化错误码时，退而求其次匹配描述文本。
        let text = ns.localizedDescription.lowercased()
        if text.contains("in use") || text.contains("busy") { return .inUse }

        return .other(ns.localizedDescription)
    }

    /// 面向用户的原因说明（本地化）。
    func reasonText(diskName: String) -> String {
        switch self {
        case .inUse:
            // 设计稿原文，**不带磁盘名**：标题已经写了盘名，正文再重复一遍是冗余 ——
            // 设计稿文案原则是「标题带磁盘名」，正文那一行留给「怎么解决」。
            return L10n.tr(.ejectFailedInUseReason)
        case .notPermitted:
            return String(format: L10n.tr(.ejectFailedNotPermittedReason), diskName)
        case .notFound:
            return String(format: L10n.tr(.ejectFailedNotFoundReason), diskName)
        case .other(let detail):
            return String(format: L10n.tr(.ejectFailedOtherReason), diskName, detail)
        }
    }

    /// 失败弹窗里「可能的原因」清单（设计稿 `03-eject-flow.html` B 变体）。
    ///
    /// **为什么挂在失败分类上而不是 UI 里**：清单内容只由**原因分类**决定，与「谁来渲染」
    /// 无关。放在这里，将来多一个入口（通知、CLI、快捷键）也能复用同一份清单，
    /// 不会两个地方各写一遍然后慢慢分叉。
    ///
    /// **为什么有些分类没有清单**：`.notFound` 与 `.other` 的原因句本身已经把话说完了
    /// （「设备已不在，可能已被拔除或已卸载」／「无法推出：<系统原话>」），再列一份清单
    /// 只是换个说法重复一遍。设计稿的文案原则是「给出可执行的下一步」——没话可说时
    /// 就不该硬凑一屏；空数组表示「这一档没有清单可给」，UI 只显示原因句与日志提示。
    var possibleCauses: [String] {
        switch self {
        case .inUse:
            // 两条都来自设计稿原文：一条指向「关掉谁」，一条指向「等一等」。
            return [L10n.tr(.ejectFailedCauseFileOpen), L10n.tr(.ejectFailedCauseSpotlight)]
        case .notPermitted:
            // 设计稿没写这一档，但「系统不允许」是最让人困惑的一类失败：用户会反复重试。
            // 这两条覆盖了实际会撞上的两种情形（选了不可推出的卷 / 系统自己持有）。
            return [L10n.tr(.ejectFailedCauseNotRemovable), L10n.tr(.ejectFailedCauseSystemHold)]
        case .notFound, .other:
            return []
        }
    }

    /// 写入日志文件的诊断信息。
    var logText: String {
        switch self {
        case .inUse: return "inUse(fBsyErr)"
        case .notPermitted: return "notPermitted"
        case .notFound: return "notFound"
        case .other(let detail): return "other(\(detail))"
        }
    }
}

/// 磁盘推出执行器。
///
/// **为什么不再用 `diskutil unmount force`**：
/// 1. `force` 会绕过「有进程占用就失败」这层系统保护，在磁盘正被写入时强行卸载，
///    是数据损坏的直接来源；
/// 2. 它是外部命令行工具，在 App Sandbox 下依赖 fork/exec 系统二进制，不是上架版本
///    应该依赖的路径（实测沙盒内 `lsof` 已完全失效，同类依赖随时可能失效）。
///
/// 现改用 `NSWorkspace.unmountAndEjectDevice(at:)`：这是 AppKit 公开 API，等价于 Finder 的
/// 「推出」，实测在 App Sandbox 内可正常工作，且占用时会返回结构化错误而非强行卸载。
class EjectService: @unchecked Sendable {
    static let shared = EjectService()

    /// 开放给测试注入 mock 子类；生产环境一律使用 `shared`。
    init() {}

    private static let logger = Logger(subsystem: "com.safeout.app", category: "EjectService")

    // MARK: - 自排除标志（SafeOut 自己的推出请求）

    /// 当前调用栈是否由 SafeOut 内部发起（防止 ``EjectHookService`` 的
    /// DiskArbitration approval callback 把自家请求当"别人的"拦截掉，导致
    /// `NSWorkspace.unmountAndEjectDevice` 永远拿不到放行 = 永久推不出）。
    ///
    /// **为什么必须有这把锁**：`eject(_:)` 在 `Task.detached` 的线程上置/清，
    /// approval callback 在 DA 的 dispatch queue 上读。两个线程并发读写
    /// 一个普通 `static var` 在 Swift 6 严格并发下要么编不过、要么有数据竞争。
    ///
    /// **为什么不开/关之间要整段包住 unmountAndEjectDevice**：
    /// DA approval callback 是**同步阻塞**的（DA 等待回执才决定 unmount 是否继续），
    /// 因此 callback 与 `unmountAndEjectDevice` 跑在同一线程上。把标志置在
    /// `unmountAndEjectDevice` 之前、清在 `defer` 里，callback 一定能读到 `true`。
    nonisolated(unsafe) private static var _hookSelfInitiated = false
    private static let _hookSelfInitiatedLock = NSLock()
    static var isHookSelfInitiated: Bool {
        get {
            _hookSelfInitiatedLock.lock()
            defer { _hookSelfInitiatedLock.unlock() }
            return _hookSelfInitiated
        }
        set {
            _hookSelfInitiatedLock.lock()
            defer { _hookSelfInitiatedLock.unlock() }
            _hookSelfInitiated = newValue
        }
    }

    /// 推出指定卷。
    ///
    /// 内部在后台线程执行，不会阻塞调用方；`unmountAndEjectDevice` 本身线程安全。
    /// - Returns: 成功或已归类的失败原因。
    func eject(disk: DiskInfo) async -> Result<Void, EjectFailure> {
        let url = URL(fileURLWithPath: disk.mountPath)
        Self.logger.notice("请求推出卷: \(disk.mountPath, privacy: .public)")

        return await Task.detached(priority: .userInitiated) { [url] in
            // 标记本次推出由 SafeOut 自己发起 —— approval callback 见此标志即放行。
            // defer 保证「**任何**路径返回都清掉标志」，不会把后续别人的请求错认成自家。
            Self.isHookSelfInitiated = true
            defer { Self.isHookSelfInitiated = false }

            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return .success(())
            } catch {
                let failure = EjectFailure.classify(error)
                Self.logger.error("推出失败: \(failure.logText, privacy: .public)")
                return .failure(failure)
            }
        }.value
    }
}
