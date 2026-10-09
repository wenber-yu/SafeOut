import AppKit
import Foundation
import OSLog

/// 应用的分发渠道。
///
/// 本应用**不上架 Mac App Store**（2026-09-18 决定），只走 Developer ID 直发，
/// 因此渠道只剩两种：正式构建（``direct``）与本地开发 / ad-hoc 构建（``development``）。
///
/// > 曾经存在的 `.appStore` 分支随该决定一并删除：App Store 收据判定、`appStoreID`、
/// > `macappstore://` 链接、「在 App Store 中查看」文案。
/// > **为什么不留着**：渠道不存在时，那套判定只有「永远为假」一种可能，
/// > 而下一轮读代码的人会以为还有一个渠道要照顾（DESIGN-SPEC §8.35.4）。
/// > 判定「这是死代码」的依据不是「现在跑不到」，而是「这个渠道不存在」。
enum DistributionChannel: String, Sendable, CustomStringConvertible {

    /// Developer ID 签名、官网或 GitHub 直发：可自行实现更新检查（Sparkle 等）。
    case direct

    /// 本地开发或 ad-hoc 签名：**非分发渠道**（未公证、不能正式分发）。
    ///
    /// ⚠️ **不等于「不能自更新」**（2026-09-22，§8.125 实测）：自签 / ad-hoc 产物上
    /// Sparkle 的 Autoupdate 安装器**在本机能跑**，不需要 Developer ID。
    /// 「无更新渠道」说的是**分发**（能不能公证、能不能给用户），不是说自更新跑不起来。
    case development

    var description: String { rawValue }
}

/// 更新入口。
///
/// ## 与自更新（Sparkle）的关系
///
/// ⚠️ **2026-09-20 订正**：这里原来写着「应用自身还不检查更新，接入 Sparkle 后由
/// `SPUUpdater` 承担」—— **Sparkle 早已接好**，那句话是过时的（同类的过时注释本轮
/// 还修了三处，见 §8.87）。现在的分工是：
///
/// - ``UpdateController`` 持有 `SPUUpdater`，负责**检查 / 下载 / 安装**；
/// - ``UpdateUserDriver`` 把 Sparkle 的回调翻译成 ``UpdateController`` 的状态机；
/// - **本文件**只留「手动打开 Releases 页」这一条**退路**（`openUpdateSource()`），
///   以及渠道判定。它**不参与更新检查**，也确实不 import Sparkle —— 那句
///   「本文件尚未集成 Sparkle」指的是**这个文件**，不是说应用没接。
///
/// 渠道判定与 UI 无需再分叉 —— 不上架 MAS 之后，渠道只剩一种，没有第二个分支要照顾。
enum UpdateService {

    private static let logger = Logger(subsystem: "com.safeout.app", category: "Update")

    // MARK: - 需要替换的常量

    /// 下载 / Releases 页（GitHub Releases 或自有下载页）。
    ///
    /// 注意：本文件**尚未集成 Sparkle**，此常量也与 Sparkle 的 appcast 无关——它只是
    /// 「打开下载页」按钮的目标地址。为 `nil` 时按钮隐藏。
    ///
    /// 指向 `/releases` **列表页**而不用 `/releases/latest`：后者只认最新的正式版，
    /// 当前发布还是 pre-release，`latest` 会落到 404。等首个正式版发布后再考虑切换。
    private static let downloadPageURL: URL? = URL(string: "https://github.com/wenber-yu/SafeOut/releases")

    // MARK: - 渠道判定

    /// 当前分发渠道。
    ///
    /// **判定依据**：只剩编译期能区分的两种——发布构建（非 `DEBUG`）即直发版，
    /// `DEBUG` 构建是开发版。
    ///
    /// **不再用 App Store 收据判定**：`Bundle.main.appStoreReceiptURL` 曾经用来区分
    /// MAS 版，那个渠道已经不存在，判定留着就是一段永远走不到的分支。
    /// （顺带也去掉了一个坑：收据路径在 Debug 下也会返回一个尚不存在的位置，
    /// 判定必须额外检查文件是否真的存在。）
    static var channel: DistributionChannel {
        #if DEBUG
            return .development
        #else
            return .direct
        #endif
    }

    /// 是否应提供「打开更新来源」的按钮。
    ///
    /// 常量未配置时返回 `false`，UI 据此隐藏按钮，避免出现点了没反应的死链接。
    static var canOpenUpdateSource: Bool {
        downloadPageURL != nil
    }

    /// 更新来源的地址；常量未配置时为 `nil`。
    static var updateSourceURL: URL? {
        downloadPageURL
    }

    /// 打开更新来源（Releases 页）。
    ///
    /// 未配置常量时不执行任何操作——由 ``canOpenUpdateSource`` 保证 UI 不会给出这个入口。
    static func openUpdateSource() {
        guard let url = updateSourceURL else {
            logger.warning("更新来源未配置，忽略打开请求")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
