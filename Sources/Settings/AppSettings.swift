import AppKit
import ApplicationServices
import SwiftUI

/// 视觉风格（设置项单一事实来源）。
///
/// 此前 `"transparent"` / `"tinted"` 两个字面量散落在 ContentView 与 SettingsView，
/// 任何一处写错都不会在编译期报错，只会在运行时静默回退到默认外观。收敛为枚举后，
/// 拼写错误变成编译错误。
enum VisualStyle: String, CaseIterable, Sendable {
    case transparent
    case tinted

    static let `default`: VisualStyle = .transparent

    /// 设置面板里的**显示名（长）**，用于无障碍朗读与提示。
    ///
    /// 与 ``AccentColor/displayName`` 同源：显示名只在这里定义一次，
    /// 视图侧不许再各写一份 `switch` —— 否则新增风格时必然出现「枚举加了、下拉里没有」。
    var displayName: String {
        switch self {
        case .transparent: return L10n.tr(.transparentMode)
        case .tinted: return L10n.tr(.tintedMode)
        }
    }

    /// 分段控件上的**短标签**（设计稿 `05-settings.html` 规定为「透明」/「色调」）。
    ///
    /// **为什么必须与 `displayName` 分开**：分段控件的宽度**不可压缩** —— 标签换行会被
    /// SwiftUI 拒绝，它只会按固有宽度撑开，把同一行里 `maxWidth: .infinity` 的弹性列
    /// （也就是「视觉效果」标签列）挤到只剩一个字宽，渲染成竖排单字。
    /// 实测（面板 440 时）：用长名时该行内容理想宽 745pt，溢出 305pt；
    /// 改用短标签后降到面板之内。
    /// 长名不删 —— 它是 VoiceOver 该念的完整表述，挂在这个控件的 accessibilityLabel 上。
    var shortName: String {
        switch self {
        case .transparent: return L10n.tr(.transparentModeShort)
        case .tinted: return L10n.tr(.tintedModeShort)
        }
    }
}

/// 强调色（设置项单一事实来源）。
///
/// **为什么要收敛**：此前「字符串 → 颜色」的映射存在三份实现：
/// - `AppDelegate` 里映射成 `NSColor`（菜单栏用）
/// - `ContentView` 里映射成 SwiftUI `Color`（主窗口用）
/// - `SettingsView` 里再维护一份 tag 字符串列表
///
/// 三份各自 switch，新增一个颜色要改三处，漏改就出现「设置里选了红色、菜单栏还是蓝色」。
/// 现在颜色语义、可选列表、两种框架下的色值全部收敛到这一个类，两处 UI 只读取。
///
/// **2026-09-09 简化**：与设计稿对齐，只保留 4 色（蓝/紫/橙/绿）。旧偏好 `red`/`yellow` 自动回退
/// 到 `blue`，避免「设置里选了红色、UI 仍是蓝色」的口径漂移。
enum AccentColor: String, CaseIterable, Sendable {
    case blue
    case purple
    case orange
    case green

    /// 从字符串解析（旧的 `red`/`yellow` 自动回退默认）。
    static func resolve(_ raw: String?) -> AccentColor {
        guard let raw, let value = AccentColor(rawValue: raw) else { return .default }
        return value
    }

    static let `default`: AccentColor = .blue

    /// 16 进制显示色（设计稿统一规范），供设置面板圆点、菜单栏 tint 使用。
    var hex: String {
        switch self {
        case .blue: return "#0a84ff"
        case .purple: return "#af52de"
        case .orange: return "#ff9f0a"
        case .green: return "#34c759"
        }
    }

    /// 深色侧 16 进制基色（`ds.css` 的 `:root[data-theme="dark"] --accent`）。
    ///
    /// **为什么要单开一套**：深色下浅色那套基色铺在 `#1c1c1e` 上偏暗、不够醒目，
    /// 设计稿四门都给了**更亮的**深色值。2026-09-21 之前两侧共用浅色基色、
    /// 只靠 alpha 分档拉开（§8.113.7 曾把「基色明暗不分」当作已知事实钉住）；
    /// 现在改成两侧各钉各的，那条守卫也一并翻过来（§8.113.11）。
    var hexDark: String {
        switch self {
        case .blue: return "#409cff"
        case .purple: return "#bf6ae8"
        case .orange: return "#ffb340"
        case .green: return "#4cd964"
        }
    }

    /// 浅色侧基色。
    var appKitColorLight: NSColor { NSColor(hex: hex) ?? .systemBlue }

    /// 深色侧基色。
    var appKitColorDark: NSColor { NSColor(hex: hexDark) ?? .systemBlue }

    /// SwiftUI 侧色值（主窗口用）。**深浅各一套基色**，随主题切换。
    var swiftUIColor: Color {
        DesignTokens.Palette.adaptive(light: appKitColorLight, dark: appKitColorDark)
    }

    /// AppKit 侧色值（菜单栏用）。**深浅各一套基色**，随主题切换。
    ///
    /// ⚠️ 这是**动态色**（`NSColor(name:dynamicProvider:)`）。
    /// 别对它调 `withAlphaComponent` 后再当固定色用 —— 那样会把两侧的基色差异
    /// 抹平（`accentTint` 因此必须**两侧各构造一次**，见 DesignTokens）。
    var appKitColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? self.appKitColorDark
                : self.appKitColorLight
        }
    }

    /// 设置面板里的显示名（本地化）。
    var displayName: String {
        switch self {
        case .blue: return L10n.tr(.colorBlue)
        case .green: return L10n.tr(.colorGreen)
        case .purple: return L10n.tr(.colorPurple)
        case .orange: return L10n.tr(.colorOrange)
        }
    }
}

/// 16 进制 → Color / NSColor 工具（用于把设计稿统一规范的色值直接接入）。
extension Color {
    fileprivate init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

extension NSColor {
    fileprivate convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

/// 偏好设置键与默认值的唯一声明处。
///
/// 此前 `"accentColor"` / `"showDockIcon"` / `"visualStyle"` 这些字符串在源码里硬编码 6 处，
/// 其中 `AppDelegate` 用 `UserDefaults.standard.string(forKey:)` 读取、`SettingsView` 用
/// `@AppStorage` 写入——两端靠字符串字面量对齐，改一处忘一处就会出现「设置改了但菜单栏没变」。
enum AppSettings {
    /// ⚠️ **「自动更新」开关的偏好不在这里**：它的唯一真相是 Sparkle 的
    /// `SPUUpdaterSettings.automaticallyChecksForUpdates`（写进同一个 UserDefaults 域）。
    /// 在这里再存一份必然与 Sparkle 脱节 —— 用户若在别处改了它，我们这份不会知道，
    /// 于是界面显示的开关位置与实际行为不一致（「设了没生效」与「没设」长得一模一样）。
    enum Key {
        static let visualStyle = "visualStyle"
        static let accentColor = "accentColor"
        static let showDockIcon = "showDockIcon"

        /// 登录项偏好的键由 ``LaunchAtLoginManager`` 持有，此处仅作文档索引，不要另写字面量。
        static var launchAtLogin: String { LaunchAtLoginManager.defaultsKey }

        /// 首次启动的「完全磁盘访问」引导是否已展示过。
        /// 直发（非沙盒）版依赖 lsof 列出占用进程，而这需要用户授权 FDA；
        /// 该标记避免每次启动都弹引导窗，仅首次未授权时提示一次。
        static let hasShownFDAOnboarding = "hasShownFDAOnboarding"

        /// 界面语言偏好（``AppLanguage`` 的 rawValue；`"system"` = 跟随系统）。
        ///
        /// **不写 `AppleLanguages` 之外的第二份真相**：本键只记用户选了什么，
        /// 「本次启动实际生效的是哪个语言」由 ``LanguageManager/active`` 从系统读。
        static let appLanguage = "appLanguage"

        /// 用户点过「跳过此版本」的那个版本号。
        ///
        /// **是版本号字符串，不是布尔**：布尔记不住「跳过的是哪一版」——
        /// 下个版本发布后那个布尔还是 `true`，用户会被永久静音。
        static let skippedVersion = "skippedVersion"

        /// 最近一次更新检查的结论（``UpdateController/CheckOutcome`` 的 rawValue）。
        ///
        /// **为什么必须落盘**：Sparkle 的 `SULastCheckTime` 是在**发起**检查时就写的
        /// （`SPUUpdater.m:789`，在任何网络请求之前），所以它只说明「查过」，
        /// 不说明「查成了」。不把结论也存下来的话，应用一重启，
        /// 「上次检查失败」就又变回「已是最新版本」—— 那句谎会随重启复活。
        static let lastCheckOutcome = "lastCheckOutcome"

        /// 是否接管访达（Finder）的「推出」。详见 ``takeOverFinderEject``。
        static let takeOverFinderEject = "takeOverFinderEject"
    }

    /// 是否接管访达（Finder）的「推出」（读写 UserDefaults）。
    ///
    /// **为什么默认关（`false`）**：接管是**系统级**的改动 —— 它会让 SafeOut
    /// 拦截所有走 `NSWorkspace.unmountAndEjectDevice` 的推出请求（Finder 的推出按钮、
    /// `diskutil eject` 都算），并且为了「不让访达弹它自己那句没用的报错」，
    /// 回调必须**同步阻塞等用户决定**（见 ``EjectHookService`` 的说明）。
    /// 一次性给老用户引入这条新行为风险太高：万一出 bug，用户会以为「盘推不出来了」。
    /// ⇒ 默认关，由用户在设置里显式打开（设置项的描述里写清代价）。
    ///
    /// **为什么用 `bool(forKey:)` 而不是 `register(defaults:)`**：键不存在时
    /// `bool(forKey:)` 返回的正是 `false`，与「默认关」一致，不需要第二处真相。
    ///
    /// **改了即时生效，不需要重启**：``EjectHookService`` 在每次 approval 回调里读本值，
    /// 关闭时直接放行（不弹窗、不阻塞）。注册的回调本身保持注册状态 ——
    /// 注销再注册反而要处理「注销期间的请求漏掉」这类时序问题。
    ///
    /// ⚠️ **把它改成 `true` 之后必须调 ``EjectHookService/syncOccupancyPolling()``**：
    /// ``OccupancyStore`` 是懒加载单例，不主动创建的话「开着开关、没打开过主窗口、
    /// 直接在访达点推出」这条路径会读到空缓存 ⇒ 一律放行 ⇒ 功能静默不生效。
    nonisolated static var takeOverFinderEject: Bool {
        get { UserDefaults.standard.bool(forKey: Key.takeOverFinderEject) }
        set { UserDefaults.standard.set(newValue, forKey: Key.takeOverFinderEject) }
    }

    /// 接管开关此刻**能不能用** —— 这个问题的唯一事实来源。
    ///
    /// ## 为什么需要它
    ///
    /// 接管的全部价值是「把占着盘的进程列出来」，而列进程要 `lsof`，`lsof` 要
    /// 「完全磁盘访问」。**没授权时这条链路的每一环都还是好的，只是永远走不进弹窗**
    /// —— ``EjectHookPolicy/decide(_:isSelfInitiated:isTakeOverEnabled:occupancy:)``
    /// 会因 `occupancy == .needsFullDiskAccess` 而放行
    /// （`.needsFullDiskAccess` 是「用户可补救的权限缺口」，见 ``OccupancyResult``）。
    ///
    /// 于是「开关打开着」与「开关真的在管事」是**两件事**：
    /// 前者是用户偏好，后者还要乘上这个闸门。旧版把两者画成同一个开关，
    /// 用户打开之后什么都不会发生，而界面上没有任何一句话说得出原因 ——
    /// 「打开一个开关，然后它静默地什么都不做」是最难自查的一类缺陷。
    ///
    /// ## 为什么收敛成一个枚举 + 两个纯函数
    ///
    /// 「未授权」这个状态要同时决定四件事：开关画成什么、那一行还能不能点、
    /// 说明文字写什么、要不要引导去系统设置。四处各判一次必然漂移
    /// （本仓库的铁律：判定收成一个可单测的纯函数，UI 只渲染不判断）。
    /// 这里就是那个纯函数 —— ``resolve(isSandboxed:isFullDiskAccessAuthorized:)``
    /// 只吃两个布尔、不碰任何系统 API，因此可以穷举断言。
    enum TakeOverAvailability: Sendable, Equatable {

        /// 可用：占用检测能列出进程，开关拨了就生效。
        case usable

        /// 不可用：没授「完全磁盘访问」，占用检测拿不到结果 ⇒ 拨了也不会生效。
        case needsFullDiskAccess

        /// 由「是否沙盒」+「是否已授权」推导。**这是唯一的推导处**。
        ///
        /// - 沙盒构建里没有 TCC 拦截，`OccupancyResult` 直接走 `.unknown`，
        ///   不存在「用户去授权」这条路 ⇒ 一律算可用（与 ``ContentView/refreshFDAStatus()``
        ///   同一条判据；本应用不上架 MAS，这是防御分支）。
        /// - 判据**只看授权**，绝不看开关自己的值 —— 读了开关的值就会变成
        ///   「关一次再也开不开」的单向开关（§8.113.14 那个真机 bug 的形态）。
        static func resolve(isSandboxed: Bool, isFullDiskAccessAuthorized: Bool) -> Self {
            (isSandboxed || isFullDiskAccessAuthorized) ? .usable : .needsFullDiskAccess
        }

        /// 开关此刻能不能操作。
        var isUsable: Bool { self == .usable }

        /// 开关**画出来**（也是唯一有意义的）那个值。
        ///
        /// ## 为什么不是「直接显示用户偏好」
        ///
        /// 不可用时显示 `true` 就是在撒谎：那个开关画成「开」，而它**什么都不会做**。
        /// 所以不可用时一律画「关」—— 界面上的每一个像素都对应真实行为。
        ///
        /// ## 代价（想清楚了才这么写）
        ///
        /// `userWants` **不被改写**（不往 `UserDefaults` 里写 `false`）：它是用户的意愿，
        /// 不是此刻能不能生效。授权之后 ``effectiveIsOn(userWants:availability:)`` 自然回到
        /// 用户的意愿值，用户不需要重新拨一次。
        ///
        /// 反过来说，**显示层与存储层在这一个状态下是分叉的**（存 `true`、画 `false`）。
        /// 这是唯一的例外，也是有意为之：
        /// - 画「关」⇒ 不存在「关不掉的开关」（用户看不到一个自己关不了的 `开`，
        ///   §8.113.14 那类锁死形不成）；
        /// - 存「意愿」⇒ 自签构建每次更新都会掉 FDA（TCC 按签名记账），
        ///   若顺手把偏好清零，用户每更一版都得重开一次。
        ///
        /// 两者都只在**未授权**这一个窗口内并存，且那一行的说明文字正在解释它。
        static func effectiveIsOn(userWants: Bool, availability: Self) -> Bool {
            userWants && availability.isUsable
        }
    }

    /// 探测当前的接管可用性。**读系统状态的唯一一处**。
    ///
    /// 判定本身是纯函数（``TakeOverAvailability/resolve(isSandboxed:isFullDiskAccessAuthorized:)``），
    /// 这里只负责把系统探测的两个布尔喂进去。分开放的理由：
    /// `isFullDiskAccessAuthorized()` 要真的去列举 TCC 受保护目录（10 条路径走一遍
    /// `contentsOfDirectory`），测试里不该被迫跑它 —— 判据测纯函数，探测只在这一行。
    ///
    /// ⚠️ **不在启动时无条件调用**：接管开关默认关，不该给所有用户加上这 10 次目录列举。
    /// 调用点只有两处 —— ``EjectHookService/syncOccupancyPolling()`` 那条「开关为真才启动」
    /// 的路径，以及设置面板打开 / 回到前台时（用户正在看这个开关，此时必须说实话）。
    nonisolated static func takeOverAvailability() -> TakeOverAvailability {
        TakeOverAvailability.resolve(
            isSandboxed: OccupancyDetector.isSandboxed,
            isFullDiskAccessAuthorized: OccupancyDetector.isFullDiskAccessAuthorized())
    }

    /// 从 UserDefaults 读取当前强调色，无值或损坏值时回退默认色。
    ///
    /// 旧的 6 色枚举里的 `red`/`yellow` 会自动回退到 `blue`（``AccentColor/resolve(_:)``）。
    nonisolated static var accentColor: AccentColor {
        AccentColor.resolve(UserDefaults.standard.string(forKey: Key.accentColor))
    }

    /// 从 UserDefaults 读取当前视觉风格，无值或损坏值时回退默认。
    nonisolated static var visualStyle: VisualStyle {
        guard let raw = UserDefaults.standard.string(forKey: Key.visualStyle),
            let value = VisualStyle(rawValue: raw)
        else {
            return .default
        }
        return value
    }

    /// 首次启动的「完全磁盘访问」引导是否已展示（读写 UserDefaults）。
    ///
    /// 直发版依赖 lsof 列出占用进程，而它需要用户授权 FDA。
    /// 该标记确保引导窗只在首次启动时弹一次，避免每次启动都打扰用户。
    nonisolated static var didShowFDAOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hasShownFDAOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hasShownFDAOnboarding) }
    }

    /// 打开「系统设置 › 隐私与安全性 › 完全磁盘访问」面板。
    ///
    /// 该 URL scheme 是 macOS 跳转到指定隐私子面板的官方方式；
    /// 直发版需要用户在此处为 SafeOut 开启开关，lsof 才能列出其他进程。
    nonisolated static func openFullDiskAccessSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// 打开「系统设置 › 隐私与安全性 › 辅助功能」面板。
    ///
    /// ## 为什么先调一次 `AXIsProcessTrustedWithOptions(prompt:)`
    ///
    /// 那是**唯一**能把本应用登记进「辅助功能」列表的手段 —— 用户跳到面板里却
    /// **找不到「磁盘推出助手」这一项**，比不提示更让人困惑（他会以为是我们写错了）。
    /// 被动查询（``SystemEjectDialogDismisser/isAccessibilityTrusted`` 走的
    /// `AXIsProcessTrusted()`）不会产生这个副作用，所以两者不能互相替代。
    ///
    /// ⚠️ 该调用在**还没授权**时会额外弹一个系统框（「…想要控制此电脑」），
    /// 而它自带「打开系统设置」按钮 ⇒ 用户可能连着看到两个入口。这是有意的：
    /// 它同时也是「用户关掉了这个框」时的第二道出口，且**顺序上先登记、后跳转**，
    /// 用户无论走哪条路到了面板，那一项都已经在列表里了。
    ///
    /// 与 ``openFullDiskAccessSettings()`` 并列：两者是**不同**的权限、不同的子面板，
    /// 且本应用两个都要（FDA 用于列占用者，辅助功能用于关系统框），不能互相跳转替代。
    nonisolated static func openAccessibilitySettings() {
        // ⚠️ **键名写成字面量，而不是引用 `kAXTrustedCheckOptionPrompt`**：
        // 那个常量在 `AXUIElement.h` 里是 `CFStringRef`（值就是这个字符串），
        // 但 Swift 6 把导入的 C 全局 `var` 一律判为「共享可变状态」——
        // 在 nonisolated 上下文里引用它**直接编译不过**：
        //   reference to var 'kAXTrustedCheckOptionPrompt' is not concurrency-safe
        // 而它实际是只读的（这是导入层的判定，不是它的真实语义）。
        // 直接 `as String` 也不行（它是 `Unmanaged<CFString>`）。
        // 改错这里的表现是「既不弹框、也不登记本应用」—— 用户会跳到一个找不到
        // 「磁盘推出助手」的面板里，且**没有任何报错**，所以这行有真机验收
        // （见本方法的说明与 `AccessibilityOnboardingTests`）。
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
