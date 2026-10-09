import AppKit
import OSLog
import ServiceManagement

/// 登录项在系统中的实际状态。
///
/// **为什么要建模成四态而不是 Bool**：
/// `SMAppServiceStatus` 里有 `.requiresApproval` 这一态——注册请求已提交，但 macOS 要求用户
/// 到「系统设置 → 通用 → 登录项」里手动打开开关。此时开关在用户看来是「我明明开了却没生效」，
/// 而代码如果只是 `try register()` 后就认为成功，UI 会一直显示已开启但实际不启动，
/// 用户无法判断问题出在哪里。
/// 把它提升为显式状态，UI 才能给出「去系统设置里允许」这个正确指引。
enum LaunchAtLoginState: Equatable, Sendable {

    /// 已注册且生效。
    case enabled

    /// 未注册。
    case disabled

    /// 已注册，等待用户在系统设置中批准。
    case requiresApproval

    /// 系统找不到该服务的注册信息（例如 app 不在 `/Applications`，或签名不完整）。
    case unavailable

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .disabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .unavailable
        @unknown default: self = .unavailable
        }
    }
}

/// 登录项操作失败原因。
enum LaunchAtLoginError: LocalizedError, Equatable {

    /// 注册已提交，但需要用户在系统设置中批准。
    case requiresApproval

    /// 系统找不到服务（app 可能不在 `/Applications`）。
    case notFound

    /// 底层 `SMAppService` 返回的错误。
    case system(underlying: String)

    var errorDescription: String? {
        switch self {
        case .requiresApproval: return "等待用户在系统设置中批准"
        case .notFound: return "系统未找到该登录项"
        case .system(let text): return text
        }
    }
}

/// 开机自启动（登录项）管理。
///
/// 基于 macOS 13.0 起提供的 `SMAppService.mainApp` 将当前应用注册为登录项——它是目前**唯一**
/// 不依赖已废弃 API、也不需要内嵌 helper 的方案。
///
/// > 「符合 Mac App Store 要求」曾经是选它的首要理由；本应用已决定不上架 MAS
/// > （2026-09-18），那条理由作废，下面三条**运行时**理由依然成立，故选型不变。
///
/// **为什么不用别的方案**（另外三条都会在系统层出问题）：
/// - `LSSharedFileListInsertItemURL`：macOS 13 起已废弃，不再可靠生效。
/// - 自己往 `~/Library/LaunchAgents` 写 plist：沙盒内没有写权限。
/// - 内嵌 Login Item helper app：可以用，但要求 helper 与主 app 双双签名并做 bundle 校验，
///   对于「仅开机启动主 app」这一需求属于过度设计，`SMAppService.mainApp` 已覆盖。
@MainActor
enum LaunchAtLoginManager {

    private static let logger = Logger(subsystem: "com.safeout.app", category: "LaunchAtLogin")

    /// 持久化键，与 SettingsView 的 Toggle 共用。
    ///
    /// `nonisolated`：这是纯字符串常量，读取它不涉及任何 UI 状态，
    /// 不应因为没有切换到主 actor 就无法引用（``AppSettings`` 需要在非隔离上下文中索引它）。
    nonisolated static let defaultsKey = "launchAtLogin"

    /// 当前持久化的偏好值。
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// 登录项在系统中的实际状态。
    ///
    /// 与 ``isEnabled`` 的区别：后者是「用户想要什么」，这里是「系统实际是什么」。
    /// 两者可能不一致（用户在系统设置里改过、或等待批准），UI 需要同时看这两个值。
    static var state: LaunchAtLoginState {
        LaunchAtLoginState(SMAppService.mainApp.status)
    }

    /// 应用启动时对齐登录项状态。
    ///
    /// 逐状态处理而非「偏好开就注册、偏好关就注销」，因为 `.requiresApproval` 下
    /// 反复注册不会推进状态，只会重复向系统提交同一个待批准请求。
    static func syncAtLaunch() {
        let state = self.state
        logger.info("启动对齐：偏好=\(self.isEnabled, privacy: .public)，系统状态=\(String(describing: state), privacy: .public)")

        switch state {
        case .enabled:
            if !isEnabled {
                try? SMAppService.mainApp.unregister()
            }
        case .disabled:
            if isEnabled {
                do { try SMAppService.mainApp.register() } catch {
                    logger.error("补注册登录项失败: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .requiresApproval:
            // 需要用户手动批准，代码无能为力。不重试，避免重复提交待批准请求。
            logger.notice("登录项等待用户在系统设置中批准")
        case .unavailable:
            logger.warning("登录项不可用（app 可能不在 /Applications）")
        }
    }

    /// 切换登录项。
    ///
    /// - Throws: 注册失败时抛 ``LaunchAtLoginError``。其中 `.requiresApproval` 不算失败——
    ///           注册请求本身已成功提交，只是需要用户批准，因此**仍会写回偏好**，
    ///           但 UI 应当提示用户去系统设置完成最后一步。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                throw LaunchAtLoginError.system(underlying: error.localizedDescription)
            }
            UserDefaults.standard.set(true, forKey: defaultsKey)

            // 注册调用成功不等于生效：可能落在 requiresApproval。
            // 抛出该状态让 UI 给出指引，而不是静默显示「已开启」。
            let after = state
            if after == .requiresApproval {
                throw LaunchAtLoginError.requiresApproval
            } else if after == .unavailable {
                throw LaunchAtLoginError.notFound
            }
        } else {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw LaunchAtLoginError.system(underlying: error.localizedDescription)
            }
            UserDefaults.standard.set(false, forKey: defaultsKey)
        }
    }

    /// 打开「系统设置 → 通用 → 登录项」，供用户手动批准或调整。
    ///
    /// 使用系统官方入口而非自己拼 `x-apple.systempreferences:` URL——后者在不同系统版本
    /// 上路径会变，且沙盒内可能被拒。
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
