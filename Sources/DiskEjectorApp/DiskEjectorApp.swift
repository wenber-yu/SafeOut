import AppKit
import Combine
import SwiftUI
import UserNotifications

/// `--notification-status` 自检用的取值盒。
///
/// **为什么需要一个小类**：`getNotificationSettings` 的回调是 `@Sendable`，
/// 在里面直接写 `main()` 的局部变量会被 Swift 6 严格并发拦下。
///
/// 用信号量在 `main()` 里同步等结果，所以这里只需要「加锁读写一个字符串」。
final class NotificationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = "（3 秒内没拿到通知授权状态）"

    var text: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

/// 「应用被重新打开时该亮哪一个窗口」的落点判据。
///
/// ## 为什么它值得一个纯函数
///
/// 两条落点的差别在用户眼里是「一眼看到该点哪个按钮」与「先找一轮」的区别，
/// 而判错**没有任何编译错**、也不会有断言变红 —— 窗口确实开了，只是开错了那一个。
///
/// ## 为什么放在类外面
///
/// 它只依赖一个 `Bool`，与 AppKit 无关。放进 `AppDelegate`（`@MainActor`）会让
/// 每个调用点（含测试）都被迫上主 actor；文件级 `@MainActor` 在测试里是**要登记的成本**
/// （见 `MainActorBlockingTests`）。判据本身不需要，就别付这笔账。
///
/// ## ⚠️ 这条判据是为什么存在的
///
/// **点系统通知在系统层面就是一次「打开应用」事件**，会走到
/// ``AppDelegate/applicationShouldHandleReopen(_:hasVisibleWindows:)``。
/// 真机实测（2026-09-29）：不做这层分流时，点通知会开出 **800×520 主窗口**，
/// 它成为 key window 后把 `presentAttentionPanel` 刚打开的菜单面板**顶掉** ——
/// 用户最终只看到主窗口，而「关闭并推出」在面板上。
///
/// 有待处理提醒时优先面板，对「点 Dock 图标」同样是合理行为：提醒比常规入口更要紧。
enum AppReopenPolicy {

    /// 「重新打开」时该亮哪个窗口。
    enum Target: Equatable {
        /// 有待处理提醒 → 菜单面板（提醒卡片与「关闭并推出」都在那儿）。
        case attentionPanel
        /// 平时 → 主窗口。
        case mainWindow
    }

    static func target(hasPendingAttention: Bool) -> Target {
        hasPendingAttention ? .attentionPanel : .mainWindow
    }
}

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusPopover: NSPopover!
    private var mainWindow: NSWindow!

    /// 建 `mainWindow` 时用的磁盘列表来源 —— **供自检核对「窗口渲染的确实是这份数据」**。
    ///
    /// **为什么必须记在这里**：``checkEmptyStateInsteadOfSkeleton`` 的前置条件是
    /// 「这份 store 里没有磁盘就往下查，有就跳过」。如果那个 store 是由调用方传进来的，
    /// 就可能出现「拿空 store 通过前置检查、却在看一份有盘窗口」——
    /// 断言会**因为别的原因变绿**（磁盘行墨迹也是数千量级，像素判据分不出来）。
    /// 2026-09-17 实测踩到：`--preview-main-window-empty-keys` 报「空状态核对通过」，
    /// 而抓下来的窗口图里画着 `wenbo-data 4 TB`（详见 SPEC §8.29）。
    ///
    /// `nil` 表示窗口是用生产路径建的（等价于 ``DiskListStore/shared``）。
    private var mainWindowStore: DiskListStore?

    /// 主窗口的**内容控制器**（v3 起它同时是侧栏 / 详情区那套 split 装配）。
    ///
    /// **为什么从 `mainWindow` 反推而不另存一个字段**：`makeMainWindow()` 是 `static`
    /// （窗口装配没有实例状态可依），另存一个字段就得让那个工厂把控制器「顺手」回填进来 ——
    /// 于是同一份引用有两个来源、可以各自被写成不同值。反推只有一个来源：窗口。
    private var mainWindowContent: MainWindowContentController? {
        mainWindow?.contentViewController as? MainWindowContentController
    }

    /// 「完全磁盘访问」引导面板（设计稿 `04-onboarding.html`）。
    ///
    /// **它必须能在主窗口没打开时弹出来**：直发版可能被设为「只驻留菜单栏」，
    /// 那种形态下 `mainWindow` 从未创建 —— 而授权引导恰恰是首次启动时最该说的话。
    /// 所以它自己持有一个窗口，不依赖任何其它界面。
    private var onboardingWindow: NSWindow?

    /// 引导面板的宿主控制器。
    ///
    /// **单独留引用是为了能重新量高**：真机自检要断言「窗口高 == 视图量出来的高」，
    /// 从 `window.contentViewController` 转类型去拿既啰嗦又脆（根视图一旦多包一层就转不成）。
    private var onboardingHosting: NSHostingController<OnboardingView>?

    private var ejectingDiskId: String?

    /// 上一次观测的偏好值，用于判断 UserDefaults 变更后是否需要真正响应。
    ///
    /// ⚠️ **这里只留「Dock 图标」一项**。此前还有一个平行的 `lastVisualStyleRaw`，
    /// 但 `handleDefaultsChange()` 里对应的分支体是**空的** —— 视觉风格由
    /// `ContentView` 的 `@AppStorage` 自动响应，不需要 AppDelegate 再记一份副本。
    /// 留着一个只被读、比较、赋值却不产生任何效果的变量，会让后来者以为那里有逻辑。
    private var lastShowDockIcon: Bool?

    /// popover 显示状态监听，关闭时按钮恢复未选中态。
    private var popoverEventMonitor: Any?

    /// 「待处理占用提醒」的订阅 —— 有提醒时把菜单栏图标换成警示态。
    private var attentionCancellable: AnyCancellable?

    /// 已投过系统通知的挂载路径。
    ///
    /// **为什么记在 AppDelegate 而不是 `EjectNotificationService` 里**：投递判据
    /// 「这一轮新出现了哪些提醒」本来就是**订阅端**的知识（只有它见过上一轮的键集合）。
    /// 通知服务只负责「怎么投、怎么撤」。两边各存一份必然漂移。
    private var notifiedAttentionKeys: Set<String> = []

    /// 磁盘列表等长效订阅的容器（随 app 生命周期存活）。
    private var attentionSubscriptions = Set<AnyCancellable>()

    static func main() {
        // stdout 默认是块缓冲：重定向到文件时，`print` 的内容要等进程正常退出才落盘。
        // 而 `--preview-alerts` 是要**被外部 kill 掉**的长驻预览模式，缓冲区会一起丢掉，
        // 表现为「跑起来了一条输出都没有」。改成行缓冲后，每行 print 立即可见。
        setvbuf(stdout, nil, _IOLBF, 0)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // 诊断模式：输出环境状态与识别到的磁盘后退出。
        if CommandLine.arguments.contains("--diagnostics") {
            delegate.runDiagnostics()
            return
        }

        // 关系统占用框的自检入口：`DiskEjectorApp --dismiss-system-dialog <盘名>`。
        //
        // **为什么要一个 CLI 入口**：这段逻辑只在「真有系统占用框挂在屏幕上」时才走得到，
        // 而那个状态复现成本高（挂盘 → 占用 → 从访达点推出 → 等框出现）。
        // 有了它，真机验收可以直接跑**生产代码本身**，不必另写一份探针
        // —— 另写一份等于什么都没验（同 `--preview-popover` 那条纪律）。
        if let index = CommandLine.arguments.firstIndex(of: "--dismiss-system-dialog"),
            index + 1 < CommandLine.arguments.count
        {
            let name = CommandLine.arguments[index + 1]
            let report = SystemEjectDialogDismisser.dismiss(forDiskNamed: name)
            // **把明细打出来**：失败的五种原因（没授权 / 找不到进程 / 没有窗口 /
            // 窗口不是这块盘的 / 按钮形态没覆盖到）外观完全相同，都表现为「框还在」。
            print(
                """
                关框尝试（盘=\(name)）：
                  辅助功能授权 = \(report.isTrusted)
                  agent 进程数 = \(report.agentProcessCount)
                  窗口数       = \(report.windowCount)
                  命中这块盘   = \(report.matchedWindowCount)
                  按下按钮     = \(report.pressedCount)
                  结束进程     = \(report.terminatedCount)
                  放弃(多框)   = \(report.skippedAmbiguousCount)
                """)
            return
        }

        // 通知授权自检：`DiskEjectorApp --notification-status`。
        //
        // **为什么需要它**：通知不出现的原因有好几种**外观完全相同**的可能
        // （没授权 / 用户拒绝 / 投递失败 / 被系统折叠），而本机 OSLog 读不到
        // （`log show` 任何谓词都返回 0 行）。把授权状态从命令行打出来，
        // 是不依赖日志的唯一判据 —— 同 `--dismiss-system-dialog` 的理由。
        if CommandLine.arguments.contains("--notification-status") {
            let box = NotificationStatusBox()
            let semaphore = DispatchSemaphore(value: 0)
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                box.text = """
                    通知授权状态 = \(settings.authorizationStatus.rawValue)（0=未决 1=拒绝 2=已授权 3=临时）
                    横幅/提示    = \(settings.alertSetting.rawValue)（0=未设 1=关 2=开）
                    声音         = \(settings.soundSetting.rawValue)
                    通知中心     = \(settings.notificationCenterSetting.rawValue)
                    提醒样式     = \(settings.alertStyle.rawValue)（0=无 1=横幅 2=弹窗）
                    """
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
            print(box.text)
            return
        }

        // 投一条测试通知：`DiskEjectorApp --post-test-notification`。
        //
        // **为什么值得一个入口**：真机上「通知没出现」有多种可能（没授权 /
        // 投递被拒 / 被系统折叠 / 只是没赶上截图），而单看现象它们**完全一样**。
        // 这个入口用**应用自己的身份**投一条固定内容的通知，把「通道通不通」
        // 与「业务什么时候投」两层分开 —— 前者是一次性事实，后者才是逻辑问题。
        // 与 `--dismiss-system-dialog` 同源：都跑生产路径，不另写一份探针。
        if CommandLine.arguments.contains("--post-test-notification") {
            let box = NotificationStatusBox()
            let semaphore = DispatchSemaphore(value: 0)
            let content = UNMutableNotificationContent()
            content.title = "通知通道自检"
            content.body = "能看到这条横幅，说明应用的通知通道是通的。"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "com.diskejector.app.selftest", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                box.text = error.map { "投递失败：\($0.localizedDescription)" } ?? "投递成功（未报错）"
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
            print(box.text)
            // **不要立刻退出**：交给通知中心显示需要进程再活一会儿 ——
            // 实测「add 成功」不等于「横幅已经上屏」。
            Thread.sleep(forTimeInterval: 2)
            return
        }

        // 弹窗预览：把两个推出弹窗依次显示出来，供人工核对与截图。
        //
        // **为什么需要这个开关**：弹窗是自绘的（``EjectAlertPresenter`` 自己开无边框窗口），
        // 「窗口能不能成为 key、回车/Esc 有没有接上、圆角与阴影对不对」这些问题
        // 离屏出图**测不到** —— 离屏渲染的是一张图，没有窗口。
        // 真机验证必须有一条不触发真实推出的路径，否则只能拿用户的磁盘去试。
        // 注意**不能 return**：弹窗要靠 run loop 才能真正上屏并接收键盘事件，
        // 直接返回会让进程在弹窗出现前就退出（实测踩到）。
        // `--preview-alerts-keys` 是它的自动化版本：不用人手按，进程自己投递合成
        // 回车/Esc 事件走完整分发链，并按结果设置退出码（可当门槛跑）。
        let autoKeys = CommandLine.arguments.contains("--preview-alerts-keys")
        if autoKeys || CommandLine.arguments.contains("--preview-alerts") {
            delegate.runAlertPreview(autoKeys: autoKeys)
        }

        // 引导面板预览：把「完全磁盘访问」引导面板**真的上屏**。
        //
        // **为什么离屏出图不够**：离屏渲染的是一张图，**没有窗口**。而引导面板是
        // `.fullSizeContentView` + 隐藏标题的「无标题栏浮层」—— 交通灯浮在左上角
        // 那 24pt 上内边距里，会不会压住居中的图标容器、窗口高是不是真等于视图量出来的高、
        // 面板能不能成为 key（决定回车/Esc/点击是否生效），这些只有真机才知道。
        //
        // 预览**不会真的打开系统设置**，出口被换成打印语句（见 ``runOnboardingPreview``）。
        let autoOnboardingKeys = CommandLine.arguments.contains("--preview-onboarding-keys")
        if autoOnboardingKeys || CommandLine.arguments.contains("--preview-onboarding") {
            delegate.runOnboardingPreview(autoKeys: autoOnboardingKeys)
        }

        // 菜单面板预览：把状态栏面板**真的挂到状态栏按钮上、真的上屏**。
        //
        // **为什么离屏出图不够**：面板的底衬是 `NSPopover` 窗口自己的
        // `NSPopoverFrame`（一档 `.titlebar` 的 `NSVisualEffectView`），
        // 而离屏渲染里**根本没有这个窗口** —— 「材质有没有被归一化到 `.underWindowBackground`」
        // 「contentSize 是不是真实内容高」（它直接决定锚点，错了面板会离图标几十 pt）
        // 这两件事只有真机才知道。
        let autoPopoverKeys = CommandLine.arguments.contains("--preview-popover-keys")
        if autoPopoverKeys || CommandLine.arguments.contains("--preview-popover") {
            delegate.runPopoverPreview(autoKeys: autoPopoverKeys)
        }

        // 主窗口预览：把主窗口**真的上屏**。
        //
        // **为什么离屏出图不够**：主窗口是 `.fullSizeContentView` + 透明标题栏 + 统一工具栏，
        // 三件事**只有上屏之后才存在** —— 工具栏那条 52pt 安全带、侧栏的浮岛形态、
        // 以及由此决定的红绿灯 26pt 基线。离屏搭不出窗口，这些**结构上测不到**。
        // 实测踩过（v2）：玻璃从 `ZStack` 挪到 `.background(...)` 时丢了
        // `.ignoresSafeArea()`，真机上标题栏整条露出桌面，而离屏快照仍是满窗玻璃、全绿。
        let autoMainWindowEmptyKeys = CommandLine.arguments.contains("--preview-main-window-empty-keys")
        let autoMainWindowKeys = CommandLine.arguments.contains("--preview-main-window-keys")
        // **空状态版优先**：两个都传时只跑空状态版 —— 否则会连做两遍断言并各调一次 `exit`。
        //
        // 这一版存在的理由：主窗口「列表为空 → 画空状态（而不是首屏骨架层）」那条分支
        // 此前**只能靠本机恰好没插盘才走得到**，守着它的断言大部分时间在跳过。
        // 现在注入一个空列表，任何硬件状态下都跑得了。见 ``runMainWindowPreview``。
        if autoMainWindowEmptyKeys || CommandLine.arguments.contains("--preview-main-window-empty") {
            delegate.runMainWindowPreview(autoKeys: autoMainWindowEmptyKeys, emptyDisks: true)
        } else if autoMainWindowKeys || CommandLine.arguments.contains("--preview-main-window") {
            delegate.runMainWindowPreview(autoKeys: autoMainWindowKeys)
        }

        // 设置页预览：把**主窗口的「设置 · 通用」页**真的上屏。
        //
        // **为什么离屏出图不够**：v3 起设置不再是独立窗口，它就是主窗口详情区的一页
        // ⇒ 能验的东西变成「**有没有多开一个窗口**」与「侧栏选中项有没有被拨到设置·通用」，
        // 这两件事**离屏结构上测不到**（离屏连窗口都没有，更谈不上"有几个窗口"）。
        // 任何一条老入口漏改都会「设置照旧开一个新窗」，而界面看上去完全正常。
        let autoSettingsKeys = CommandLine.arguments.contains("--preview-settings-keys")
        // 「接管可用性」那两个注入口也各自算一次「要开设置窗口」——
        // 否则 `--preview-settings-no-fda` 会被忽略掉（这里是**逐字**比较，不是前缀匹配）。
        let settingsAvailabilityFlag =
            CommandLine.arguments.contains("--preview-settings-no-fda")
            || CommandLine.arguments.contains("--preview-settings-has-fda")
        if autoSettingsKeys || settingsAvailabilityFlag
            || CommandLine.arguments.contains("--preview-settings")
        {
            delegate.runSettingsPreview(autoKeys: autoSettingsKeys)
        }

        // 更新弹窗预览：把「有新版本」弹窗**真的上屏**。
        //
        // **为什么离屏出图不够**：与推出弹窗同源 —— 弹窗是自绘的无边框窗口，
        // 「能不能成为 key（决定回车/Esc/点击是否生效）」「有没有真的上屏」
        // 「圆角与阴影对不对」这些问题离屏测不到（离屏渲染的是一张图，没有窗口）。
        //
        // 它比推出弹窗**更需要**真机自检，因为它多了一个设计稿点名要求的出口：
        // **Esc = 稍后**（不占按钮）。而 Esc 在这条链上有两个入口 ——
        // SwiftUI 的 key equivalent 与窗口的 `cancelOperation(_:)`，哪一条生效只有真机知道。
        let autoUpdateKeys = CommandLine.arguments.contains("--preview-update-keys")
        if autoUpdateKeys || CommandLine.arguments.contains("--preview-update") {
            delegate.runUpdatePreview(autoKeys: autoUpdateKeys)
        }

        app.run()
    }

    /// 是否处于真机预览模式（`--preview-*`）。
    ///
    /// 预览模式下**跳过正常的启动引导**：否则 `maybeShowFDAOnboarding()` 会先弹一次，
    /// 预览里那次就成了「第二次展示」，`didShowFDAOnboarding` 也被写脏 —— 输出难以判读。
    ///
    /// 不只启动引导要用：**凡是要读宿主 bundle 真实身份的东西都该避开预览**
    /// （Sparkle 的 updater 就是一例，见 `UpdateController`）——
    /// 预览跑的是未签名的命令行产物，`Bundle.main` 不是合规的 app bundle。
    static var isPreviewRun: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--preview-") }
    }

    /// 预览时**强制**的「接管可用性」；`nil` = 走实时探测（生产路径）。
    ///
    /// - `--preview-settings-no-fda`：强制「未授完全磁盘访问」那一态。
    /// - `--preview-settings-has-fda`：强制「已授权」那一态。
    ///
    /// **为什么不靠本机的真实 TCC 状态**：这一态由「本机给没给 FDA」决定，
    /// 而任何一台机器都只能处于其中**一半** —— 另一半**画不出来**，
    /// 于是它的排版与文案永远没人看过。这与 ``SettingsSectionPane/updateStateOverride``
    /// （七态里「下载中」等三态在真机上造不出来）是同一条理由。
    ///
    /// ⚠️ 只在 `--preview-*` 进程里生效，正常启动读不到 ⇒ 生产行为一字不变。
    /// （两个旗标本就带 `--preview-` 前缀，``isPreviewRun`` 会自动成立 —— 这里再判一次
    /// 是为了让「生产不生效」这件事在**读代码时**就看得见，而不是去数前缀。）
    private static var previewTakeOverAvailability: AppSettings.TakeOverAvailability? {
        guard isPreviewRun else { return nil }
        if CommandLine.arguments.contains("--preview-settings-no-fda") { return .needsFullDiskAccess }
        if CommandLine.arguments.contains("--preview-settings-has-fda") { return .usable }
        return nil
    }

    /// 输出一次环境自检结果并退出。
    private func runDiagnostics() {
        let sandboxed = OccupancyDetector.isSandboxed
        let disks = DiskService.shared.fetchExternalDisks()

        print("DiskEjector 诊断报告")
        // 沙盒 ≠ App Store：本应用不上架 MAS（2026-09-18 决定），
        // 这里报的是**当前进程是否真的处于沙盒中**，不再把它解释成某个分发渠道。
        print("  沙盒状态: \(sandboxed ? "已启用" : "未启用")")
        print("  占用检测: \(sandboxed ? "不可用，降级为「无法检测」" : "可用（lsof）")")
        print("  识别到的外置可推出卷: \(disks.count)")
        for disk in disks {
            let proto = disk.deviceProtocol ?? "未知"
            let model = disk.deviceModel.map { " (\($0))" } ?? ""
            print("    • \(disk.displayName) [\(disk.bsdName)] \(disk.mountPath)")
            print(
                "      协议: \(proto)\(model)，总容量: \(ByteFormat.string(disk.totalBytes))，已用: \(ByteFormat.string(disk.usedBytes))"
            )
        }

        if !sandboxed, !disks.isEmpty {
            print("")
            print("  占用进程检测（lsof，仅非沙盒可用）：")
            for disk in disks {
                let result = OccupancyDetector.shared.detectSync(mountPath: disk.mountPath)
                let desc: String
                switch result {
                case .occupied(let ps):
                    // 两个名字都打出来：`displayName` 是用户在 Dock 里看到的应用名，
                    // `processName` 是 lsof 给的可执行名（如 `Bunny` / `IMVIDEO`）。
                    // 诊断时两者不一致恰恰是排查「显示的应用不对」的关键线索。
                    desc =
                        "占用 → "
                        + ps.map { "\($0.displayName)[\($0.processName)](PID \($0.pid))" }
                        .joined(separator: ", ")
                case .needsFullDiskAccess:
                    desc = "未检测到（可能未授予完全磁盘访问，见设置引导）"
                case .unknown:
                    desc = "未知"
                case .none:
                    desc = "无占用"
                }
                print("    • \(disk.displayName): \(desc)")
            }
        }

        exit(0)
    }

    /// 依次预览两个推出弹窗，并把用户的选择打到终端。
    ///
    /// **只读**：用固定的假数据构造模型，不碰任何真实磁盘，也不会触发终止进程。
    /// 用途是人工核对离屏出图覆盖不到的部分 —— 窗口能否成为 key、回车/Esc 是否接上、
    /// 圆角与阴影在真实桌面上对不对。
    ///
    /// - Parameter autoKeys: `true` 时由进程自己投递合成按键，跑完即退出（退出码 0 = 全通过）。
    ///
    /// **为什么「自己投递合成按键」是可行的验证手段**：`NSEvent.keyEvent(...)` +
    /// `NSApp.postEvent(...)` 把事件投进**应用自己的事件队列**，之后的路径
    /// （`NSApplication.sendEvent` → 主菜单 key equivalent → key window 的 key equivalent
    /// → 第一响应者 → 响应链）与真实敲键**完全一致**，而且**不需要「辅助功能」权限** ——
    /// 那正是 `osascript` 合成按键报 `-10004` 时卡住的地方。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-alerts`（每关掉一个弹窗就出下一个，最后一个结束即退出）
    /// - 自动验证：`DiskEjectorApp --preview-alerts-keys`
    @MainActor
    private func runAlertPreview(autoKeys: Bool) {
        let disk = DiskInfo(
            id: "/Volumes/Preview", bsdName: "disk99s1", volumeName: "Samsung T7",
            mountPath: "/Volumes/Preview", totalBytes: 0, usedBytes: 0, freeBytes: 0,
            deviceProtocol: "USB", deviceModel: nil)
        let processes = [
            OccupyingProcess(pid: 1234, processName: "Finder", displayName: "Finder", path: ""),
            OccupyingProcess(pid: 5678, processName: "Preview", displayName: "图像捕捉", path: ""),
        ]

        Task {
            var mismatches: [String] = []

            // A · 占用弹窗：回车应落到默认按钮「关闭并推出」
            let a = await previewAlert(
                .busy(disk: disk, occupying: processes), label: "A · 占用弹窗",
                key: autoKeys ? .return : nil)
            if autoKeys, a != .closeAndEject {
                mismatches.append("A 回车应得 closeAndEject，实得 \(a)")
            }

            // B · 失败弹窗：回车应落到默认按钮「好」
            let b = await previewAlert(
                .failure(disk: disk, failure: .inUse), label: "B · 失败弹窗",
                key: autoKeys ? .return : nil)
            if autoKeys, b != .dismiss {
                mismatches.append("B 回车应得 dismiss，实得 \(b)")
            }

            // C · 再开一次失败弹窗：Esc 应走逃生出口（取消），与焦点在哪无关
            let c = await previewAlert(
                .failure(disk: disk, failure: .inUse), label: "C · 失败弹窗（Esc）",
                key: autoKeys ? .escape : nil)
            if autoKeys, c != .cancel {
                mismatches.append("C Esc 应得 cancel，实得 \(c)")
            }

            print("预览结束（未对任何真实磁盘执行操作）")

            guard autoKeys else { exit(0) }
            if mismatches.isEmpty {
                print("✅ 按键路径自检通过：回车 → 默认按钮，Esc → 取消")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 自检要投递的按键（只覆盖弹窗用到的两个）。
    private enum PreviewKey {
        case `return`
        case escape

        /// `(keyCode, characters)` —— 键码取自 `HIToolbox/Events.h`（kVK_Return = 36 / kVK_Escape = 53）。
        var event: (code: UInt16, chars: String) {
            switch self {
            case .return: return (36, "\r")
            case .escape: return (53, "\u{1b}")
            }
        }
    }

    /// 显示一个弹窗；`key` 非空时在它上屏后投递该按键，最后返回用户（或按键）做出的选择。
    @MainActor
    private func previewAlert(
        _ model: EjectAlertModel, label: String, key: PreviewKey?
    ) async -> EjectAlertChoice {
        // 先起一个不 await 的任务把弹窗挂上去，再等它**真正成为 key window** 后才自检。
        //
        // **不能只 sleep 一个固定时长**：`makeKeyAndOrderFront` 是异步生效的，而「上屏」到
        // 「抢到焦点」之间还有一段窗口期 —— 实测固定 sleep 700ms 时，第二个弹窗偶尔正好
        // 落在窗口期里，打印出 `key=false`，可它的回车明明是生效的，输出自相矛盾。
        let pending = Task { await EjectAlertPresenter.shared.present(model) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await waitUntilAlertIsKey()
        EjectAlertPresenter.shared.dumpWindowState(label: label)
        if let key { postKey(key) }
        let choice = await pending.value
        print("\(label) → \(choice)")
        return choice
    }

    /// 等到弹窗真正成为 key window（最多等 1.5 秒）。
    @MainActor
    private func waitUntilAlertIsKey() async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !EjectAlertPresenter.shared.isKeyWindow {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 更新弹窗预览（`--preview-update` / `--preview-update-keys`）。
    ///
    /// 样本值取自设计稿 `08-update.html` 的 A 段（1.0.0 → 1.1.0、构建 42 → 58、
    /// 2026-09-17、12.4 MB、三条更新）—— **不要换成别的样本**：
    /// 走查图与设计稿并排比的时候，样本不同就没法比（同 §8.33 的磁盘/进程样本规则）。
    ///
    /// 自检两件事，都是离屏测不到的：
    /// ① 弹窗能不能成为 key（决定回车 / Esc / 点击是否生效）；
    /// ② **Esc 是不是真的等于「稍后」** —— 设计稿把这条写成了硬规则
    ///   （「第三个出口不占按钮，但必须写在操作区左边」），而它在实现上有两个入口
    ///   （SwiftUI 的 key equivalent 与窗口的 `cancelOperation(_:)`），只有真机知道哪条生效。
    @MainActor
    private func runUpdatePreview(autoKeys: Bool) {
        let update = PendingUpdate(
            version: "1.1.0", newBuild: "58",
            currentVersion: "1.0.0", currentBuild: "42",
            date: "2026-09-17", sizeBytes: 12_400_000,
            notes: [
                "设置里新增「自动更新」开关，可后台下载并在重启后安装",
                "修复未插入磁盘时骨架层一直不消失的问题",
                "推出失败弹窗新增「查看日志」直达入口",
            ])
        let model = UpdateAlertBuilder.model(for: update)

        Task {
            var mismatches: [String] = []

            // A · 回车应落到主按钮「后台更新并重启」。
            let a = await previewAlert(
                model, label: "更新弹窗 · 回车", key: autoKeys ? .return : nil)
            if autoKeys, a != .installAndRestart {
                mismatches.append("回车应得 installAndRestart，实得 \(a)")
            }

            // B · Esc 应走「稍后」（那个不占按钮的第三个出口）。
            let b = await previewAlert(
                model, label: "更新弹窗 · Esc", key: autoKeys ? .escape : nil)
            if autoKeys, b != .cancel {
                mismatches.append("Esc 应得 cancel（稍后），实得 \(b)")
            }

            print("预览结束（未对任何真实版本执行下载或安装）")

            guard autoKeys else { exit(0) }
            if mismatches.isEmpty {
                print("✅ 更新弹窗自检通过：回车 → 后台更新并重启，Esc → 稍后")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 把一次完整的按键（down + up）投进应用自己的事件队列。
    ///
    /// **为什么 down 和 up 都要投**：AppKit 的按键处理挂在 `keyDown` 上，只投 `keyDown`
    /// 也能触发；补上 `keyUp` 是为了让队列状态与真实敲键一致，避免残留的 down 事件
    /// 让后续窗口收到「按键卡住」的假象。
    @MainActor
    private func postKey(_ key: PreviewKey) {
        let (code, chars) = key.event
        let stamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: stamp,
                    windowNumber: 0, context: nil, characters: chars,
                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    // MARK: - 启动

    /// 主菜单必须在 App 变成 active 之前装好：自建 `NSApplication` 没有 nib 主菜单，
    /// 而 ⌘W / ⌘H / ⌘Q 这些快捷键全靠主菜单里的 `keyEquivalent` 表分发（详见 `MainMenu`）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: L10n.tr(.appName)) {
            NSApp.applicationIconImage = appIcon
        }

        lastShowDockIcon = UserDefaults.standard.bool(forKey: AppSettings.Key.showDockIcon)
        updateDockIconVisibility()

        LaunchAtLoginManager.syncAtLaunch()

        setupDefaultsObservation()
        setupStatusItem()
        setupMainWindow()

        // **订阅「待处理占用提醒」驱动菜单栏图标**：有提醒 → 图标换成警示态（小圆点）。
        if !Self.isPreviewRun { setupAttentionObserver() }

        if !Self.isPreviewRun { maybeShowFDAOnboarding() }

        // **updater 必须在启动时建起来。**
        //
        // Sparkle 只在 `SPUUpdater.start()` 之后才开始按 `SUScheduledCheckInterval` 排期
        // （见 `UpdateController.startIfNeeded()` 的说明：这里**不额外**调
        // `checkForUpdatesInBackground()`，免得每次启动都打网络请求）。
        // 不建它，「自动更新」开关、`SUEnableAutomaticChecks=true`、
        // `SUScheduledCheckInterval=86400` 三样**全都显示为「配好了」**，
        // 而实际上一次检查都不会发生：设置行永远停在「尚未检查」。
        // （判据同登录项第三态：**「设了没生效」与「功能坏了」在界面上不能长得一样**。）
        //
        // ⚠️ 2026-09-18 实测踩到：`startIfNeeded()` 此前**全仓库只有定义、没有任何调用点**
        // —— 这条链等于从未接通，而它不会编译失败、不会崩、也不会有别的断言变红。
        // 守卫见 `UpdateSettingsTests.启动链上必须真的建起updater`。
        //
        // 预览模式跳过：`ensureUpdater()` 自己也会拦（`--preview-*` 的 `Bundle.main`
        // 不是合规 app bundle），这里再拦一次是为了让真机自检**不发出网络请求** ——
        // 自检要可重复，混进一次联网会让结果随网络状况变。
        if !Self.isPreviewRun { UpdateController.shared.startIfNeeded() }

        // **接管访达（Finder）的推出**：注册 DiskArbitration approval callback，
        // 让访达 / diskutil / 任何走 `NSWorkspace.unmountAndEjectDevice` 的推出请求
        // 先被本应用判定（占用缓存明确列出占用者 → 放行 + 菜单栏提醒；否则放行）。
        // 见 `EjectHookService` 的完整链路说明与 spike 实证。
        //
        // 回调**保持注册、永不注销**（注销再注册要处理「注销期间到达的请求漏掉」这类时序问题）；
        // 要不要真的提醒由 `AppSettings.takeOverFinderEject` 决定，**每次回调现读**（默认关）。
        if !Self.isPreviewRun { EjectHookService.shared.register() }

        // **开关为真时把占用轮询显式启动**：`OccupancyStore` 是懒加载单例，
        // 不主动创建的话，「开着开关、但没打开过主窗口、直接在访达点推出」这条
        // **本功能的目标路径**会读到空缓存 ⇒ 一律不提醒 ⇒ 功能静默不生效。
        if !Self.isPreviewRun { EjectHookService.syncOccupancyPolling() }
    }

    /// 直发版首次启动引导用户授予「完全磁盘访问」。
    ///
    /// **只在首次启动弹一次**：`didShowFDAOnboarding` 记住「已经说过」。
    /// 之后若用户仍未授权，主窗口顶部会留一条琥珀横幅（`NoticeBanner.warning`），
    /// 不再打断 —— 拒绝授权不等于功能失效，磁盘照样能推出，只是看不到占用者。
    ///
    /// 沙盒构建跳过：沙盒里本来就没有 FDA 这回事。
    /// （本应用不上架 MAS，这条 `guard` 是防御分支，不是某个分发渠道的专属路径。）
    private func maybeShowFDAOnboarding() {
        guard !OccupancyDetector.isSandboxed, !AppSettings.didShowFDAOnboarding else { return }
        AppSettings.didShowFDAOnboarding = true
        showOnboarding()
    }

    /// 打开「完全磁盘访问」引导面板（设计稿 `04-onboarding.html`）。
    ///
    /// **为什么是独立窗口而不是 `NSAlert`**：设计稿这块面板有居中图标容器、
    /// 三步编号 + 连接线、行内等宽路径小标、信息提示块，`NSAlert` 一样都给不了。
    /// 另外 `runModal()` 会**阻塞主线程**：授权引导是「跨应用的任务」，
    /// 用户要离开本应用去系统设置操作、再回来 —— 期间应用必须是活的。
    ///
    /// 装配方式与 ``showSettings()`` 同款（`NSHostingController` + 独立窗口），
    /// 区别是内容高由视图自己量出来（设计稿面板高随文案变化，宽固定 380）。
    ///
    /// - Parameter onExit: 面板两个出口的处理方式。为 `nil` 时走**真实行为**
    ///   （打开系统设置 / 关窗）；真机自检传自己的实现，以便观测「合成按键到底走了哪个出口」，
    ///   而不会真的去打开系统设置。
    @discardableResult
    private func showOnboarding(onExit: ((OnboardingExit) -> Void)? = nil) -> NSWindow? {
        onboardingExitHandler = onExit
        if onboardingWindow == nil {
            let root = OnboardingView(
                accent: AppSettings.accentColor,
                // 「打开系统设置」**不关窗**：用户接下来要去系统设置里翻找并开启开关，
                // 三步说明得留在屏幕上给他对照（设计稿的「三步带编号与连接线」正是
                // 为了让他中断之后能接上）。关掉它，用户回来就只剩一个空列表。
                onOpenSettings: { [weak self] in self?.handleOnboardingExit(.openSettings) },
                onLater: { [weak self] in self?.handleOnboardingExit(.later) }
            )
            let panel = Self.makeOnboardingPanel(root: root)
            onboardingWindow = panel.window
            onboardingHosting = panel.hosting
        }
        guard let window = onboardingWindow else { return nil }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        activateApp()
        return window
    }

    /// 组装承载引导面板的窗口。
    ///
    /// 设为 `internal`（而非 `private`）是为了让单测能直接断言窗口配置与尺寸 ——
    /// 与 ``EjectAlertPresenter/makePanel(hosting:height:title:)`` 同一个理由：
    /// 这几行里每一条去掉都会**静默**劣化，而任何一条都不会让别的断言变红：
    /// - 少了 `safeAreaRegions = []` → 内容被标题栏安全区**整体下推 32pt**
    ///   （设计稿 24pt 的上内边距变成 56pt，窗口也被撑到 532 高）；
    /// - 少了 `isReleasedWhenClosed = false` → 关掉面板后留下悬垂引用；
    /// - 少了 `titleVisibility = .hidden` → 面板顶上多一条标题栏。
    ///
    /// **单测只断言配置与尺寸，不真的 `makeKeyAndOrderFront`** —— 那会抢走用户焦点。
    /// 「真的上屏、能不能成为 key、回车/Esc 通不通」交给 `--preview-onboarding` 真机自检。
    static func makeOnboardingPanel(
        root: OnboardingView
    ) -> (window: NSWindow, hosting: NSHostingController<OnboardingView>) {
        let width = DesignTokens.Size.onboardingPanelWidth
        let hosting = NSHostingController(rootView: root)

        // **必须关掉容器的安全区**。
        //
        // `.fullSizeContentView` 的窗口会告诉 SwiftUI「顶部这 32pt 被标题栏占着」，
        // 于是 SwiftUI 把内容**整体下推 32pt**。`--preview-onboarding-keys` 实测到的是
        // 「窗口 380×532、安全区 top=32、内容布局区 380×500」—— 而设计稿是 380×503。
        //
        // **这件事离屏出图结构上测不到**：离屏渲染的视图没有窗口，也就没有安全区，
        // 量出来正好 500（看着完全正确）。只有把窗口真的开出来才会露出来。
        //
        // **主窗口后来也改成了这条路子**（`makeMainWindow` 里同样关掉安全区 —— 一句就够）。
        //
        // 这里曾经写着「主窗口走的是另一条**等价**路子（`ContentView` 自己 `.ignoresSafeArea()`
        // 再画 52pt 标题栏）」—— **那个「等价」判断是错的，并且是主窗口那个 bug 的认知源头**：
        // `.ignoresSafeArea()` 只改内容排版，**不改窗口尺寸**，`sizeThatFits` / 固有尺寸仍会把
        // 32pt 加进去，窗口照样被撑高。代价是主窗口长期停在 800×552（设计稿 520），
        // 玻璃只拿到内容的 520，顶部 32pt 露出桌面（2026-09-15 用户截图报告）。
        if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }

        // 高度用 `sizeThatFits(in:)` 量 —— 它会带上「宽 380」这个约束；
        // `fittingSize` 不认宽度约束，会把内容按理想宽度排版（实测会矮一截）。
        let height = hosting.sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height

        let win = KeySilentWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            // `.fullSizeContentView` + 隐藏标题：设计稿的面板是**无标题栏**的浮层，
            // 内容高就是面板高。交通灯按钮浮在左上角那块 24pt 的上内边距里
            // （图标容器是居中的，横向不会撞上）。
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = L10n.tr(.fdaOnboardingTitle)
        win.contentViewController = hosting
        // **这一句不是冗余，删不得**：赋 `contentViewController` 会把窗口 frame
        // **清成 0×0**（实测，且 `layoutIfNeeded()` 之后仍是 0），上面 `contentRect`
        // 传的高度会被丢掉。少了它，面板就是一个 0 高的空窗口 ——
        // 不报错、不崩溃，只是什么都没有。
        // `OnboardingWindowTests.挂上控制器后必须重新定尺寸` 把这个对照实验钉住了。
        win.setContentSize(NSSize(width: width, height: height))
        win.center()
        // 面板被关掉后还要能被再次打开（`showOnboarding` 是可重复调用的），
        // 默认的 `true` 会在 close 时把窗口释放掉，留下悬垂引用。
        win.isReleasedWhenClosed = false
        return (win, hosting)
    }

    /// 引导面板的两个出口。
    ///
    /// **为什么要把它变成类型而不是两个裸闭包**：真机自检要断言「合成按键到底触发了哪个出口」，
    /// 得能比较、能打印。裸闭包只能记一个布尔。
    enum OnboardingExit: Equatable {
        /// 主按钮「打开系统设置」。
        case openSettings
        /// 次按钮「稍后」（Esc 也走这里）。
        case later

        var name: String {
            switch self {
            case .openSettings: return "打开系统设置"
            case .later: return "稍后"
            }
        }
    }

    /// 引导面板出口的处理方式。
    ///
    /// **做成属性而不是在建窗时把闭包捕获进去**：窗口是复用的（`onboardingWindow` 只建一次），
    /// 而真机自检要「同一个窗口、先后走两个出口」—— 捕获进视图的闭包换不了。
    /// 为 `nil` 时走真实行为。
    private var onboardingExitHandler: ((OnboardingExit) -> Void)?

    private func handleOnboardingExit(_ exit: OnboardingExit) {
        if let handler = onboardingExitHandler {
            handler(exit)
            return
        }
        switch exit {
        case .openSettings: AppSettings.openFullDiskAccessSettings()
        case .later: onboardingWindow?.close()
        }
    }

    // MARK: - 引导面板真机自检

    /// 把引导面板真的上屏，核对离屏出图覆盖不到的部分，并把面板走了哪个出口打到终端。
    ///
    /// **只读**：不碰任何磁盘；出口被换成记录，**不会真的打开系统设置**。
    ///
    /// - Parameter autoKeys: `true` 时自己投递合成按键（回车 → 「打开系统设置」、Esc → 「稍后」），
    ///   跑完即退出（退出码 0 = 全通过）。`false` 时把面板留在屏幕上供人工核对，**不自动退出**。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-onboarding`
    /// - 自动验证：`DiskEjectorApp --preview-onboarding-keys`
    ///
    /// **注意不能 `return` 掉整个 `main()`**（与 `--preview-alerts` 同理）：面板要靠 run loop
    /// 才能真正上屏并接收键盘事件，直接返回会让进程在面板出现前就退出。
    @MainActor
    private func runOnboardingPreview(autoKeys: Bool) {
        var exits: [OnboardingExit] = []
        let record: (OnboardingExit) -> Void = { exits.append($0) }

        guard let window = showOnboarding(onExit: record) else {
            print("❌ 引导面板窗口没有建起来")
            exit(1)
        }

        // `[self]` 是把**本来就有的**隐式强捕获写成显式（行为一字不变）。
        // 本 Task 要活到预览收尾（`exit()` 才结束），期间必须能碰 `self` 的窗口与出口处理器；
        // 而下面那个**存进 `self.onboardingExitHandler` 的**闭包**故意**写 `[weak self]`
        // （否则 self → handler → 闭包 → self 成环）—— 两处所有权不同是**有意的**。
        // 不写这个 `[self]` 时，CLT 的 Swift 6.4 会报 `ImplicitStrongCapture`
        // （「内层 weak 捕获与外层**隐式**强捕获不一致」，见 SPEC §8.113.20），
        // 配上 `-warnings-as-errors` 就成了 error；CI 的旧 Xcode 不报 ⇒ 本地门槛 1 假红。
        Task { [self] in
            var mismatches: [String] = []

            await waitUntilOnboardingIsKey()
            dumpOnboardingWindowState(label: "A · 引导面板", window: window, mismatches: &mismatches)

            guard autoKeys else {
                // 人工核对模式：面板**留在屏幕上**，用户按回车 / Esc / 点按钮都会打出来。
                // 这里才换上「真实行为」的出口（关窗），让手感与线上一致；
                // 但「打开系统设置」仍只打印 —— 预览不该真的去动系统设置。
                self.onboardingExitHandler = { [weak self] exit in
                    print("  → 出口：\(exit.name)")
                    if exit == .later { self?.onboardingWindow?.close() }
                }
                print("人工核对模式：面板已上屏（本模式不会真的打开系统设置）。")
                print("  回车 → 应打印「打开系统设置」；Esc / 点「稍后」 → 应打印「稍后」并关窗。")
                print("  核对完 ⌘Q 退出。")
                return
            }

            // B · 回车应落到默认按钮「打开系统设置」
            postKey(.return)
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("B · 回车 → \(exits.map(\.name).joined(separator: "、"))")
            if exits != [.openSettings] {
                mismatches.append("B 回车应得 [打开系统设置]，实得 [\(exits.map(\.name).joined(separator: "、"))]")
            }

            // C · Esc 应落到次按钮「稍后」—— 逃生口不能有前提条件，与焦点在哪无关。
            // 面板**不关**（预览的出口只是记录），所以这里能直接复用同一个窗口再来一次。
            exits.removeAll()
            _ = showOnboarding(onExit: record)
            await waitUntilOnboardingIsKey()
            postKey(.escape)
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("C · Esc → \(exits.map(\.name).joined(separator: "、"))")
            if exits != [.later] {
                mismatches.append("C Esc 应得 [稍后]，实得 [\(exits.map(\.name).joined(separator: "、"))]")
            }

            print("预览结束（未对任何真实磁盘执行操作，也未真的打开系统设置）")
            if mismatches.isEmpty {
                print("✅ 引导面板真机自检通过：窗口尺寸与视图一致、交通灯不压内容、回车 → 主按钮、Esc → 「稍后」")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 把引导面板窗口的状态打到终端，并就地核对几件**只有真机才知道**的事。
    ///
    /// 四个断言都不是「看着对」，而是各有明确后果：
    /// 1. 宽必须是设计稿的 380 —— 说明文字是居中的两段，宽度飘了断行就飘，
    ///    第 1 步那个实测 226pt 的路径小标也会折行；
    /// 2. 窗口高必须 ≈ 视图量出来的高 —— 否则底部按钮被裁掉或下面多一块空白。
    ///    容差 1.5pt：AppKit 会把内容尺寸向上取整到整点（实测 499.95 → 500、500.45 → 501）；
    /// 3. 窗口高必须 ≈ 设计稿的 503.3 —— **这条是标题栏安全区那个 bug 的捕手**。
    ///    当时窗口被撑到 532（内容被下推 32pt），而第 2 条因为两边都含安全区反而是绿的：
    ///    「窗口高 == 视图量高」是必要条件，不是充分条件；
    /// 4. 交通灯（浮在内容之上的 `.fullSizeContentView` 标题栏）不能压住顶部图标容器 ——
    ///    横向分开是**算出来的**（图标容器居中 x 164…216、交通灯在最左），不是设计稿写死的，
    ///    所以每次真机自检都验一遍。
    @MainActor
    private func dumpOnboardingWindowState(
        label: String, window: NSWindow, mismatches: inout [String]
    ) {
        let width = DesignTokens.Size.onboardingPanelWidth
        // 与 `makeOnboardingPanel` 里建窗时**同一份量法**（同一个控制器、同一个宽约束）：
        // 两边不一致的话这条断言就没有意义。先布局一次再量，避免约 0.5pt 的抖动。
        onboardingHosting?.view.layoutSubtreeIfNeeded()
        let measured =
            onboardingHosting?.sizeThatFits(
                in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            ).height ?? 0

        print(
            "  \(label)：key=\(window.isKeyWindow) 上屏=\(window.isVisible) "
                + "可成为key=\(window.canBecomeKey) 无标题栏=\(window.titleVisibility == .hidden) "
                + "尺寸=\(window.frame.width)×\(window.frame.height) "
                + "视图量高=\(measured) 窗口号=\(window.windowNumber) 应用前台=\(NSApp.isActive)"
        )
        if let hosting = onboardingHosting {
            print(
                "    内容视图高=\(hosting.view.frame.height) "
                    + "安全区=\(hosting.view.safeAreaInsets) "
                    + "内容布局区=\(window.contentLayoutRect)"
            )
        }

        if abs(window.frame.width - width) > 0.5 {
            mismatches.append("A 面板宽应为 \(width)，实得 \(window.frame.width)")
        }
        if abs(window.frame.height - measured) > 1.5 {
            mismatches.append("A 窗口高 \(window.frame.height) 与视图量出的 \(measured) 不一致")
        }
        // 与版式契约测试同一个口径（设计稿 503.3、容差 ±4，差异来自 Blink 把行内元素
        // 的垂直内边距算进行盒高度 —— 详见 `OnboardingLayoutTests.面板总高与设计稿相差不超过4`）。
        // **这条断言正是安全区那个 bug 的捕手**：当时窗口被撑到 532，比设计稿高 28.7，
        // 而「窗口高 == 视图量高」那条因为两边都含安全区，反而是绿的。
        if abs(window.frame.height - 503.3) > 4 {
            mismatches.append("A 窗口高 \(window.frame.height) 偏离设计稿 503.3 超过 4")
        }

        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(NSRect.null) { $0.union($1) }
        guard !lights.isNull else { return }

        // 图标容器在窗口坐标里的位置（窗口原点在左下，所以 y 要从顶部往下折算）。
        let icon = DesignTokens.Size.onboardingIconContainer
        let iconRect = NSRect(
            x: (width - icon) / 2,
            y: window.frame.height - DesignTokens.Spacing.xxl - icon,
            width: icon, height: icon)
        if lights.intersects(iconRect) {
            mismatches.append("A 交通灯 \(lights) 压住了顶部图标容器 \(iconRect)")
        }
    }

    /// 等到引导面板真正成为 key window（最多等 1.5 秒）。
    ///
    /// **不能只 sleep 一个固定时长**：`makeKeyAndOrderFront` 是异步生效的，
    /// 「上屏」到「抢到焦点」之间还有一段窗口期（详见 ``previewAlert`` 的注释）。
    @MainActor
    private func waitUntilOnboardingIsKey() async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !(onboardingWindow?.isKeyWindow ?? false) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - 菜单面板真机自检

    /// 把状态栏面板真的挂到状态栏按钮上、真的上屏，核对**离屏出图覆盖不到**的部分。
    ///
    /// **为什么需要它**：面板的底衬是 `NSPopover` 窗口自己的 `NSPopoverFrame`
    /// （一档 `.titlebar` 的 `NSVisualEffectView`）。离屏渲染里**根本没有这个窗口**，
    /// 所以「材质有没有被归一化到 `.underWindowBackground`」在离屏测试里永远是绿的 ——
    /// 哪怕 `normalizeBackdropMaterial()` 一个视图都没找到。
    /// 同理，`contentSize` 是不是真实内容高只有上屏后才知道，而它直接决定锚点
    /// （错了面板会离图标几十 pt，见 ``showStatusPopover(anchoredTo:)`` 里的三组对照实验）。
    ///
    /// **只读**：面板动作出口被换成记录，不会真的打开主窗口/设置、不会退出、不会推出任何盘。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-popover`（面板留在屏幕上，核对完 ⌘Q）
    /// - 自动验证：`DiskEjectorApp --preview-popover-keys`（跑完即退出，退出码 0 = 全通过）
    ///
    /// **注意不能 `return` 掉整个 `main()`**（与其它 `--preview-*` 同理）：
    /// 面板要靠 run loop 才能真正上屏、才会建好视图树。
    @MainActor
    private func runPopoverPreview(autoKeys: Bool) {
        var fired: [MenuPopoverAction.Kind] = []
        popoverActionHandler = { fired.append($0) }

        setupStatusItem()
        guard let button = statusItem?.button else {
            print("❌ 状态栏按钮没有建起来")
            exit(1)
        }

        Task {
            var mismatches: [String] = []

            // 等状态栏按钮真的被系统放进一个可见窗口里。
            //
            // **为什么必须等**：`NSPopover.show(relativeTo:of:)` 要求锚点视图在一个
            // **可见窗口**内，而 `NSStatusBarWindow` 是系统在应用启动完成后**异步**放置的。
            // 预览是在 `main()` 里抢先建的（早于 `app.run()`），抢跑的结果是 `show` **静默**
            // 什么都不做 —— 实测第一版 `isShown` 恒为 false，且没有任何报错。
            await waitUntilStatusButtonIsOnScreen()
            // `.accessory`（只驻留菜单栏）形态下应用不在前台，popover 不会上屏。
            // **`activate` 是异步生效的**：调用后立刻 `show` 仍然会失败（实测），
            // 必须等 `isActive` 真的变 true。
            NSApp.activate(ignoringOtherApps: true)
            await WindowSelfCheck.waitUntilAppIsActive()

            showStatusPopover(anchoredTo: button)
            // 材质归一化依赖「窗口已上屏、视图树已建好」，而那是异步的 ——
            // `showStatusPopover` 里那次 `DispatchQueue.main.async` 也要等下一个 runloop。
            // 用固定等待而不是轮询：这里等的不是某个布尔量，而是**窗口建树完成**，
            // 没有可直接观测的谓词。600ms 在实测里足够（上屏通常 <100ms）。
            try? await Task.sleep(nanoseconds: 600_000_000)

            dumpPopoverState(label: "A · 菜单面板", mismatches: &mismatches)

            guard autoKeys else {
                print("人工核对模式：面板已上屏（本模式不会真的打开主窗口/设置，也不会退出）。")
                print("  核对要点：面板底衬与主窗口是否为同一块玻璃；面板是否紧贴菜单栏图标下方。")
                print("  核对完 ⌘Q 退出。")
                return
            }

            // B · 面板上的动作真的接上了（出口被换成记录，不会产生副作用）
            fired.removeAll()
            handlePopoverAction(.refreshDisks)
            print("B · 触发「刷新磁盘列表」→ \(fired.map(\.rawValue).joined(separator: "、"))")
            if fired != [.refreshDisks] {
                mismatches.append("B 应得 [refreshDisks]，实得 [\(fired.map(\.rawValue).joined(separator: "、"))]")
            }

            print("预览结束（未对任何真实磁盘执行操作，也未真的打开任何窗口）")
            if mismatches.isEmpty {
                print("✅ 菜单面板真机自检通过：面板上屏、底衬材质与主窗口同档、contentSize 等于真实内容高")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 等到状态栏按钮所在窗口真的可见（最多 3 秒）。
    ///
    /// 判据是「窗口存在 + `isVisible` + `windowNumber > 0`」三个一起看：
    /// 只看 `window != nil` 会过早通过（窗口对象先于上屏存在，此时 `show` 仍会静默失败），
    /// 而 `windowNumber` 是系统真正把窗口登记进窗口服务器之后才有的。
    @MainActor
    private func waitUntilStatusButtonIsOnScreen() async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let window = statusItem?.button?.window, window.isVisible, window.windowNumber > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("⚠️ 状态栏按钮 3 秒内没有上屏 —— 面板大概会挂不上（本机没有可用状态栏？）")
    }

    /// 等主窗口真的成为 **key**（最多 2 秒）。
    ///
    /// **为什么「应用活跃」不够**：交通灯的**红色只在 key 窗口上绘制** ——
    /// 应用已在前台但窗口还没拿到 key 时，系统仍把三个灯画成灰色，
    /// 于是红灯像素扫描得到 0。2026-09-17 实测这条断言因此**偶发变红**（约 1/3 次），
    /// 而当时窗口尺寸、玻璃、内容墨迹全部正常。
    ///
    /// ⚠️ 这里和 ``measureRedLightInk`` 里的重试是**两道保险**，不是重复：
    /// 这一道等状态，那一道等绘制。激活状态与重绘不是同一时刻发生的事 ——
    /// 只等状态仍可能抓到「状态已变、像素还没重画」的那一帧。
    @MainActor
    private func waitUntilMainWindowIsKey() async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !(mainWindow?.isKeyWindow ?? false) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 把面板窗口的状态打到终端，并就地核对几件**只有真机才知道**的事。
    ///
    /// 四条断言各有明确后果：
    /// 1. 面板必须真的上屏 —— 否则后面每一条都是在测一个不存在的窗口；
    /// 2. `contentSize.width` 必须 = 设计稿的 360（`02-menu-bar.html` 的 `.win--popover`）。
    ///    ⚠️ **不能拿窗口 frame 宽去比 360**：popover 的窗口框 = 内容尺寸 + 箭头 + 一圈阴影，
    ///    实测 386×306（360×280 + 四边各 13），拿 386 去比 360 会误报；
    /// 3. `contentSize.height` 必须 ≈ 视图自己量出来的高 —— 这条是**锚点的捕手**：
    ///    `NSPopover` 用 `contentSize` 算锚点，取到 0 会回退到默认 320×320，
    ///    面板因此离图标下偏几十 pt（实测过 72pt）；
    /// 4. 底衬材质必须是 `.underWindowBackground`（rawValue 21）——
    ///    系统默认给的是 `.titlebar`（rawValue 0），两者不是同一块玻璃。
    ///    这条**只有真机才有牙**：离屏渲染里没有 popover 窗口，永远查不出。
    @MainActor
    private func dumpPopoverState(label: String, mismatches: inout [String]) {
        guard let popover = statusPopover else {
            mismatches.append("A 面板对象不存在")
            return
        }
        let window = popover.contentViewController?.view.window
        // ⚠️ **只读**取材质：这里绝不能调 `normalizeBackdropMaterial()` —— 它会顺手把材质
        // 改好，断言就永远为真了（自证陷阱）。见 ``NSPopover/backdropMaterial``。
        let material = popover.backdropMaterial
        let contentHeight = popover.contentViewController?.view.fittingSize.height ?? 0

        print(
            "  \(label)：上屏=\(popover.isShown) 窗口=\(window?.frame.width ?? -1)×\(window?.frame.height ?? -1) "
                + "contentSize=\(popover.contentSize.width)×\(popover.contentSize.height) "
                + "视图量高=\(contentHeight) 底衬材质=\(material.map { "\($0.rawValue)" } ?? "未找到") "
                + "窗口号=\(window?.windowNumber ?? -1) 应用前台=\(NSApp.isActive) "
                + "锚点窗口号=\(statusItem?.button?.window?.windowNumber ?? -1)"
        )

        if !popover.isShown {
            // 最常见的成因是「应用不在前台」—— `NSPopover.show` 在这种情况下**静默失败**。
            // 把这条线索直接写进失败信息，省得下次又去查材质。
            let hint = NSApp.isActive ? "" : "（应用不在前台，`show` 会静默失败）"
            mismatches.append("A 面板没有上屏（isShown=false）\(hint)")
        }
        if abs(popover.contentSize.width - DesignTokens.Size.menuPopoverWidth) > 0.5 {
            mismatches.append(
                "A 面板内容宽应为 \(DesignTokens.Size.menuPopoverWidth)，实得 \(popover.contentSize.width)")
        }
        if abs(popover.contentSize.height - contentHeight) > 1 {
            mismatches.append(
                "A contentSize 高 \(popover.contentSize.height) 与视图量高 \(contentHeight) 不一致 —— "
                    + "面板会被锚错位置")
        }
        if let material, material != .underWindowBackground {
            mismatches.append(
                "A 底衬材质是 \(material.rawValue)，应被归一化为 .underWindowBackground(21)")
        } else if material == nil {
            mismatches.append("A 没有找到 popover 的底衬 NSVisualEffectView —— 材质没被归一化")
        }
    }

    // MARK: - 主窗口真机自检

    /// 把主窗口真的上屏，核对**离屏出图覆盖不到**的部分。
    ///
    /// **为什么需要它**：主窗口是 `.fullSizeContentView` + 透明标题栏，
    /// SwiftUI 因此会从窗口拿到一个 **32pt 的顶部安全区**（`DesignTokens.Size.titleBarHeight`
    /// 的 52pt 是 `ContentView` 自己画的内容带，两回事）。
    /// 「玻璃有没有连标题栏一起铺满」「窗口高是不是设计稿的 520」这两件事离屏**结构上测不到** ——
    /// 离屏没有窗口就没有安全区，`NSHostingView` 也不会把固有尺寸回推给窗口
    /// （实测离屏窗口恒为 520）。
    /// 实测踩过：`GlassSurface` 从 `ZStack` 挪到 `.background(...)` 时丢了 `.ignoresSafeArea()`，
    /// **真机上标题栏整条露出桌面**，而离屏快照 `main-window-light.png` 仍是满窗玻璃、全绿。
    /// 后来查明根因是两层：窗口被 `sizingOptions` 撑到 552（旧版就有，一直没量过），
    /// 玻璃又只拿到内容的 520。两处修法见 ``makeMainWindow()``。
    ///
    /// **只读**：不动任何磁盘、不写偏好。
    ///
    /// 跑法（`emptyDisks` 版见下）：
    /// - 人工核对：`DiskEjectorApp --preview-main-window`（窗口留在屏幕上，核对完 ⌘Q）
    /// - 自动验证：`DiskEjectorApp --preview-main-window-keys`（跑完即退出，退出码 0 = 全通过）
    /// - **空状态**（注入空磁盘列表，任何硬件状态下都能跑）：
    ///   `--preview-main-window-empty` / `--preview-main-window-empty-keys`
    ///
    /// `emptyDisks: true` 时窗口里渲染的是**空状态**，而 ``checkEmptyStateInsteadOfSkeleton``
    /// 此时不再跳过 —— 它原先只在「本机恰好没插盘」时才执行（见那个函数的说明）。
    @MainActor
    private func runMainWindowPreview(autoKeys: Bool, emptyDisks: Bool = false) {
        // **空状态自检必须注入一个「列表恒为空」的 store。**
        //
        // 为什么：``checkEmptyStateInsteadOfSkeleton`` 的判据只在「列表区画的是空状态」时成立，
        // 而列表来源此前是硬编码的 ``DiskListStore/shared`` —— 于是那条断言
        // **只在开发者本机恰好没插盘时才真的跑**，其余时候它都在打印「跳过」。
        // 一个大部分时间不执行的守卫等于没有守卫：它会给人一种「有覆盖」的错觉。
        //
        // `monitoring: false` 的理由：不挂系统挂载监听。预览进程里插入/拔出磁盘
        // 不该改变断言的前提（那是**硬件**在决定测试跑不跑，正是要消灭的东西）。
        // 同时 `skipsInitialRefresh: true` 挡住 `.task` 里的自动枚举 ——
        // 否则列表会被真实硬件重新填满，断言又会静默退化成「跳过」。
        #if DEBUG
            let injected: DiskListStore? = emptyDisks ? DiskListStore(monitoring: false) : nil
        #else
            // 注入点依赖 `#if DEBUG` 的 ``DiskListStore/init(monitoring:)``，发布构建拿不到。
            // **明确报错退出，不要静默退化成「正常预览」** —— 那会让调用方以为空状态查过了。
            if emptyDisks {
                print("❌ --preview-main-window-empty-* 只在 DEBUG 构建可用（需要注入 store）")
                exit(2)
            }
            let injected: DiskListStore? = nil
        #endif

        // **两个 store 必须配对，不能只注入列表。**
        //
        // 只注入 `store` 而让 `ContentView` 的 `occupancyStore` 仍读生产单例时，那个 store 的
        // `diskStore` 是 `DiskListStore.shared` —— 于是窗口里出现一个自相矛盾的画面：
        // **列表是空的，占用结论却来自本机真盘**；顺带还起了一条真实 `lsof` 轮询（15s 一次）。
        // 空状态自检本身看不出这个问题（没有磁盘行就没有占用可显示），所以它更该被写死在这里。
        let injectedOccupancy: OccupancyStore? =
            injected.map { OccupancyStore(diskStore: $0, autoStart: false) }

        Task {
            var mismatches: [String] = []

            // **先让位**：`applicationDidFinishLaunching` 里的 `setupMainWindow()` 会**先**建一次窗口 ——
            // 它在本 `Task` 之前执行（`Task` 是在 `app.run()` 之后才被调度的）。
            // 那次建出来的窗口用的是**生产 store**，而 `setupMainWindow` 有 `guard mainWindow == nil`，
            // 于是注入会被**静默吃掉**：窗口照旧画磁盘行，守卫却拿着空 store 通过了前置检查。
            // 2026-09-17 实测踩到 —— 抓到一张画着「wenbo-data 4 TB」的「空状态核对通过」。
            if injected != nil, let stale = mainWindow {
                stale.close()
                mainWindow = nil
            }
            setupMainWindow(
                store: injected, skipsInitialRefresh: emptyDisks, occupancyStore: injectedOccupancy)

            // **让空状态自检也不依赖系统外观。**
            //
            // 「深色像素」判据只在浅色底上成立 —— 深色底本身就是深色像素，整屏都会被算成墨迹。
            // 旧写法在深色模式下**跳过**，也就是「开着深色模式的机器上，这条断言永远不跑」。
            // 与「本机没插盘」是**同一个病根**：让环境决定守卫跑不跑。
            //
            // 与其跳过，不如把窗口切成浅色 —— 判据要什么底，就给它什么底。
            // **在窗口上屏之前设**，这样第一帧就是浅色，不需要「等重绘」（那又是一次时序赌博）。
            // 只在自动（门槛）模式做：人工核对模式保留用户自己的外观，看着更真实。
            if emptyDisks, autoKeys {
                mainWindow.appearance = NSAppearance(named: .aqua)
            }

            showMainWindow()

            // **自证：注入真的生效了。**
            // 这一条防的是「守卫因为别的原因通过」—— 光看像素数分不出窗口里画的是
            // 空状态还是磁盘行（两者墨迹都是数千量级），必须核对**数据来源的身份**。
            if let injected, mainWindowStore !== injected {
                let actual =
                    mainWindowStore.map { "有 \($0.disks.count) 块盘的注入 store" }
                    ?? "生产 store（DiskListStore.shared）"
                mismatches.append(
                    "注入的磁盘列表没有生效：主窗口读的是\(actual)，不是刚注入的那个空列表。"
                        + "空状态自检会因此变成**假绿**（它量到的是磁盘行的墨迹）或**静默跳过**。"
                        + "多半是 `applicationDidFinishLaunching` 抢在前面把窗口建好了 —— "
                        + "见 ``runMainWindowPreview`` 里「先让位」那一段。")
            }
            NSApp.activate(ignoringOtherApps: true)
            await WindowSelfCheck.waitUntilAppIsActive()
            // ⚠️ **「应用活跃」不等于「主窗口是 key」**：交通灯的红色只在 **key 窗口**上画，
            // 而窗口拿到 key 要等下一次通知。只等 `NSApp.isActive` 会偶发抓到**灰灯**
            // （红灯像素 = 0，实测约 1/3 次）—— 见 ``measureRedLightInk`` 里记的那次。
            await waitUntilMainWindowIsKey()
            // 等窗口上屏并把 SwiftUI 的视图树建好（玻璃是 `NSViewRepresentable`，
            // 要等 AppKit 那一层真的建出来才找得到）。
            try? await Task.sleep(nanoseconds: 600_000_000)

            // store 不在这里传：被调方直接读 ``mainWindowStore``（**建窗时记下的那一份**）。
            // 由调用方传的话，两边一旦不一致，守卫就会拿一份 store 做前置检查、
            // 却在看另一份数据渲染出来的窗口 —— 那正是 2026-09-17 那次假绿的形态。
            dumpMainWindowState(label: "A · 主窗口", mismatches: &mismatches)

            guard autoKeys else {
                print("人工核对模式：主窗口已上屏（本模式不会推出任何磁盘）。")
                print("  核对要点：")
                print("    ① 左侧是**四边内缩的圆角浮岛**（26 上），右侧内容区贴边 ——")
                print("       不是「贴边通高的一条深色栏」；")
                print("    ② 三条基线共线：红绿灯圆心 / 右上刷新按钮 / 「外置磁盘」标题，垂直中心应一致；")
                print("    ③ 侧栏「设置」那一组下面有五项（通用/外观/更新/诊断/关于），")
                print("       点任一项右侧头部标题应跟着变；")
                print("    ④ 窗口顶部**没有任何一段**露出比内容区头部带更低的空带。")
                if emptyDisks {
                    print("    ⑤ 【空状态模式】列表区画的必须是「空状态」（图标 + 标题 + 说明 + 按钮），")
                    print("       不能是首屏骨架层的浅灰圆角块 —— 见 SPEC §8.25。")
                }
                print("  核对完 ⌘Q 退出。")
                return
            }

            print("预览结束（未对任何真实磁盘执行操作）")
            if mismatches.isEmpty {
                let scope = emptyDisks ? "空状态（注入空磁盘列表）" : "真实磁盘列表"
                print(
                    "✅ 主窗口真机自检通过：窗口 800×520、玻璃覆盖整窗（含标题栏）、"
                        + "侧栏锁宽 200 且详情区顶距 0、标题与交通灯同一 26pt 基线（红灯画出来是圆）、"
                        + "\(scope)")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    // MARK: - 主窗口自检（量测那一半已搬到 `WindowSelfCheck`）

    /// ⚠️ 「交通灯基线 / 标题对称 / 空状态 / 墨迹中心」那几支**量测函数**已搬到
    /// ``WindowSelfCheck``（同模块，`Sources/DiskEjectorApp/WindowSelfCheck.swift`）——
    /// 它们只吃参数、不读本类型的任何成员，做成 `static func` 后这件事由**编译器**保证。
    /// 这里只留**需要读 `mainWindow`** 的那一半。

    /// 把主窗口状态打到终端，并就地核对。
    ///
    /// 六条断言各有明确后果：
    /// 1. 窗口必须是设计稿的 **800 × 520**（`_10-combined-draft.html` 的 `.win--v3`）——
    ///    这条抓的是「宿主把 520 + 工具栏安全区 52 的固有尺寸回推给窗口」；
    /// 2. **玻璃必须覆盖整个窗口**（含标题栏那一条）—— 这条是「标题栏露底」的捕手。
    ///    判据不是看颜色（离屏取不到桌面），而是**问 AppKit 那块底衬在窗口里占多大**：
    ///    ``GlassSurface`` 走的是我们自己那块（``GlassBackdrop/isOurs``），
    ///    系统的侧栏玻璃 / 标题栏玻璃不算 —— 它们算进来会替我们那块把「没铺满」补上；
    /// 3. **v3 的装配**（``WindowSelfCheck/checkSplitAssembly``）：工具栏在不在、
    ///    侧栏是不是 `.sidebar` 行为且锁宽 200、详情区 view 顶距是不是 0；
    /// 4. **交通灯与内容区头部带在同一条水平基线上**（``checkTrafficLightBaseline``）——
    ///    v3 起这 26pt 由 AppKit 按「窗口有没有工具栏」给；
    /// 5. **红灯画出来是圆的**（``checkRedLightInkShape``）—— 抓「标题栏把灯裁掉」；
    /// 6. 无外置磁盘时必须画**空状态**而不是骨架层（仅磁盘页；见 `checksDisksEmptyState`）。
    ///
    /// - Parameter checksDisksEmptyState: 第 6 条是否要跑。设置页里根本没画磁盘列表，
    ///   那种情况下「列表区墨迹」量到的是设置行 —— 结论没有意义（会假绿）。
    @MainActor
    private func dumpMainWindowState(
        label: String, checksDisksEmptyState: Bool = true, mismatches: inout [String]
    ) {
        guard let window = mainWindow else {
            mismatches.append("A 主窗口不存在")
            return
        }
        let hosting = window.contentView
        // ⚠️ **两边都必须转成窗口坐标再比**。`NSHostingView` 是 flipped 的
        // （`isFlipped == true`，原点在左上），它的 `bounds` 与 `glassBackdrops`
        // 返回的窗口坐标（原点在左下）**y 轴方向相反** —— 直接比会得到荒谬的结论。
        let contentRect = hosting?.convert(hosting?.bounds ?? .zero, to: nil) ?? .zero
        let glasses = window.glassBackdrops
        let ours = glasses.filter { $0.kind.isOurs }
        let covered = ours.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        WindowSelfCheck.checkLiquidGlassBackdrop(glasses, label: label, mismatches: &mismatches)

        // **不用 `.zero` 这种隐式成员**：在字符串插值里它没有上下文类型可推，
        // Swift 会去猜（实测猜成 `Int.zero`），然后在一个莫名其妙的地方报
        // 「binary operator '+' cannot be applied to 'String' and 'String.Stride'」。
        // 显式写类型，或者先算成局部变量。
        let insets: NSEdgeInsets = hosting?.safeAreaInsets ?? NSEdgeInsetsZero
        let size = "\(window.frame.width)×\(window.frame.height)"
        print(
            "  \(label)：上屏=\(window.isVisible) 尺寸=\(size) "
                + "内容区(窗口坐标)=\(contentRect) 安全区=\(insets)"
        )
        for (index, glass) in glasses.enumerated() {
            print("    玻璃[\(index)] \(glass.kind.label) frame=\(glass.frame)")
        }
        print("    自定义玻璃并集=\(covered)")

        let expected = DesignTokens.Size.mainWindow
        if abs(window.frame.width - expected.width) > 0.5
            || abs(window.frame.height - expected.height) > 0.5
        {
            mismatches.append(
                "A 窗口应为 \(expected.width)×\(expected.height)，实得 "
                    + "\(window.frame.width)×\(window.frame.height)")
        }

        // 玻璃要覆盖整个窗口内容区。留 0.5pt 容差给坐标取整。
        guard !ours.isEmpty, contentRect.height > 0 else {
            mismatches.append("A 没找到主窗口的自定义玻璃（material=.underWindowBackground）—— 背景没铺上")
            return
        }
        let tolerance: CGFloat = 0.5
        let covers =
            covered.minX <= contentRect.minX + tolerance
            && covered.minY <= contentRect.minY + tolerance
            && covered.maxX >= contentRect.maxX - tolerance
            && covered.maxY >= contentRect.maxY - tolerance
        if !covers {
            mismatches.append(
                "A 玻璃只覆盖 \(covered)，未铺满内容区 \(contentRect) —— "
                    + "上/下缺口 \(contentRect.minY - covered.minY) / "
                    + "\(contentRect.maxY - covered.maxY)pt（顶部安全区 32pt 就是标题栏那一带）")
        }

        // 3 · v3 的装配：工具栏还在不在、侧栏 / 详情区对不对。
        //
        // ⚠️ **这几条离屏出图全测不到**（离屏没有窗口 ⇒ 没有工具栏 ⇒ 侧栏不浮、灯不在 26pt）。
        // 返回值是详情区左缘，下面那条空状态判据要用它把扫描框限制在详情区里。
        var detailLeft: CGFloat = 0
        if let content = mainWindowContent {
            detailLeft = WindowSelfCheck.checkSplitAssembly(
                window: window, content: content, label: "A", mismatches: &mismatches)
        } else {
            mismatches.append(
                "A 主窗口的 contentViewController 不是 MainWindowContentController —— "
                    + "v3 的侧栏 / 详情区装配整个没接上（见 ``AppDelegate/makeMainWindow()``）")
        }

        // 4 · 交通灯与内容区头部带在同一条水平基线上（= 26pt）。
        //
        // v3 起这个位置**完全由 AppKit 按「窗口有没有工具栏」决定**，我们不再改灯的 frame。
        // ⇒ 这条现在守的是「工具栏还在不在」：它一旦没了，灯会掉到 16pt。
        WindowSelfCheck.checkTrafficLightBaseline(window: window, label: "A", mismatches: &mismatches)

        // 5 · 红灯**画出来**的位置与形状 —— 「标题栏那 52pt 有没有把灯裁掉」的唯一判据。
        //
        // `frame` 层面的判据（第 4 条）对「被裁」这件事**全瞎**（它量的是布局数据，
        // 不是墨迹）；只有这里数屏幕上的红色像素才看得见形状。
        WindowSelfCheck.checkRedLightInkShape(
            ink: WindowSelfCheck.measureRedLightInk(
                window: window, label: "A", mismatches: &mismatches),
            label: "A", mismatches: &mismatches)

        // 6 · 没有外置磁盘时必须显示**空状态**，不能卡在首屏骨架层。
        //
        // 离屏出图测不到这条（`cacheDisplay` 不跑 `.task`），只能真机量。
        // store 取 ``mainWindowStore``（建窗时记下的那一份），不是调用方传的 —— 见那里的说明。
        // `detailLeftInset` 见 ``WindowSelfCheck/checkEmptyStateInsteadOfSkeleton``：
        // v3 起侧栏恒有 7 行文字，不全窗口扫的话那条阈值会被侧栏的墨迹架空。
        guard checksDisksEmptyState else { return }
        WindowSelfCheck.checkEmptyStateInsteadOfSkeleton(
            window: window, diskStore: mainWindowStore ?? .shared, detailLeftInset: detailLeft,
            label: "A", mismatches: &mismatches)
    }

    // MARK: - 设置页真机自检

    /// 把**主窗口的「设置 · 通用」页**真的上屏，核对离屏出图覆盖不到的部分。
    ///
    /// ## v3 起设置不再是独立窗口
    ///
    /// 三个入口（内容区齿轮 / 主菜单 ⌘, / 菜单栏面板的「设置…」）现在都落在
    /// 「显示主窗口 + 选中设置·通用」上（``showSettings()``）。所以这个自检要回答的是
    /// **两个 v3 特有的问题**：
    ///
    /// 1. **没有第二个窗口冒出来** —— v2 时代设置是独立 `NSWindow`。任何一条老路径漏改
    ///    都会「设置照旧开一个新窗」，而界面看上去**完全正常**（用户看到两个窗口，
    ///    以为设置还能单独摆着）。判据 = 进程里的可见窗口集合。
    /// 2. **侧栏选中项真的被拨到「设置 · 通用」** —— 三条入口共用 ``AppDelegate/showSettings()``
    ///    里那一句 `model.selection = .settings(.general)`；漏了它，齿轮 / ⌘, 会打开主窗口
    ///    却停在「外置磁盘」页，用户以为设置按钮坏了。
    ///
    /// 另外复用主窗口那几条真机判据（装配 / 交通灯 / 玻璃铺满），因为**它就是同一个窗口**。
    ///
    /// **只读**：不动任何磁盘、不写偏好。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-settings`（窗口留在屏幕上，核对完 ⌘Q）
    /// - 自动验证：`DiskEjectorApp --preview-settings-keys`（跑完即退出，退出码 0 = 全通过）
    ///
    /// **注意不能 `return` 掉整个 `main()`**（与其它 `--preview-*` 同理）：
    /// 窗口要靠 run loop 才能真正上屏、才会把 SwiftUI 的视图树建出来。
    @MainActor
    private func runSettingsPreview(autoKeys: Bool) {
        Task {
            var mismatches: [String] = []

            // 走**真实路径**：三个入口用的都是 ``showSettings()``。
            // 另写一份「预览专用的代码」等于什么都没验。
            showSettings()
            await WindowSelfCheck.waitUntilAppIsActive()
            await waitUntilMainWindowIsKey()
            // 等窗口上屏并把 SwiftUI 的视图树建好（玻璃是 `NSViewRepresentable`，
            // 要等 AppKit 那一层真的建出来才找得到）。
            try? await Task.sleep(nanoseconds: 600_000_000)

            guard let window = mainWindow, let content = mainWindowContent else {
                print("❌ 主窗口 / 内容控制器没有建起来")
                exit(1)
            }

            // 1 · **不该有第二个窗口。**
            let visible = NSApp.windows.filter(\.isVisible)
            let others = visible.filter { $0 !== window }
            print("    可见窗口数=\(visible.count)（主窗口之外还有 \(others.count) 个）")
            for extra in others {
                print("      多余窗口：title=\(extra.title) class=\(type(of: extra))")
            }
            if !others.isEmpty {
                mismatches.append(
                    "A 打开设置之后进程里多出 \(others.count) 个可见窗口（"
                        + others.map { "\(type(of: $0))" }.joined(separator: "、")
                        + "）—— v3 已把设置合并进主窗口详情区，不该再有独立设置窗口。"
                        + "多半是某条老入口还在建窗（查 ``AppDelegate/showSettings()``）")
            }

            // 2 · **选中项必须是「设置 · 通用」。**
            let selection = content.model.selection
            print("    侧栏选中项=\(selection.id)（标题「\(selection.title)」）")
            if selection != .settings(.general) {
                mismatches.append(
                    "A 打开设置后侧栏选中项是 \(selection.id)，应为 settings.general —— "
                        + "齿轮 / ⌘, / 菜单栏面板三处都靠 ``AppDelegate/showSettings()`` 里那一句 "
                        + "`model.selection = .settings(.general)`；漏了它，用户会看到"
                        + "「点设置打开了主窗口，却停在磁盘页」")
            }

            // 3 · 它**就是**主窗口 ⇒ 主窗口那几条真机判据原样适用
            //     （只是不该在这里判「空状态」—— 设置页根本没画磁盘列表）。
            dumpMainWindowState(
                label: "A · 主窗口（设置页）", checksDisksEmptyState: false,
                mismatches: &mismatches)

            guard autoKeys else {
                print("人工核对模式：设置页已上屏（本模式不会改动任何设置）。")
                print("  核对要点：")
                print("    ① 侧栏「设置」那一组的五项里应有一项被选中（通用），右侧头部写着「通用」；")
                print("    ② 右侧**不该有「完成」按钮** —— 设置是常驻面板，v3 里没有这个概念；")
                print("    ③ 开关是系统样式（26 上为胶囊 + Liquid Glass），且**整行**（含文字区）都能点；")
                print("    ④ 切换侧栏分类，右侧头部标题应跟着变；")
                print("    ⑤ 桌面上**只有这一个窗口**（设置不再单独开窗）。")
                print("  核对完 ⌘Q 退出。")
                return
            }

            print("预览结束（未改动任何设置）")
            if mismatches.isEmpty {
                print(
                    "✅ 设置页真机自检通过：未多开窗口、侧栏选中「设置 · 通用」、"
                        + "主窗口装配 / 玻璃 / 交通灯基线全部成立")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    // MARK: - 状态栏

    /// 状态栏按钮：点击切换 NSPopover（与设计稿"菜单栏弹出面板"对齐：360px 宽，毛玻璃）。
    ///
    /// **幂等**：`main()` 里的 `--preview-popover` 会在 `applicationDidFinishLaunching`
    /// 之前先建一次状态栏（预览要立刻把面板挂上去），随后正常的启动流程又会调一次。
    /// 没有这道 guard 就会**建出两个状态栏图标**（而且第二次会把 `statusItem` 覆盖掉，
    /// 第一个从此没人引用、无法移除）。注意 `rebuildStatusItemIfOffscreen()` 是**故意**
    /// 绕过本方法的 —— 它要的就是「销毁重建」，不能有这道 guard。
    ///
    /// ## ⚠️ 那道 guard 与「半初始化」是耦合的（2026-10-08 修）
    ///
    /// 原来这里是 `guard let button = statusItem.button else { return }`：
    /// 若 `statusItem` 建出来了而 `button` 为 nil，就**什么都不做地返回** ——
    /// 此时 `statusItem` 已非 nil，于是 :1525 那道幂等 guard 会让**之后所有调用全部空转**，
    /// `statusPopover` 也永远不会被创建。表现是「菜单栏图标不出、点图标没反应」，
    /// 且**没有任何错误日志**（不是崩了，是静默卡死）。
    ///
    /// 现在的处置：**button 拿不到就把这个半成品状态栏拆掉**，让 `statusItem` 回到 nil
    /// ⇒ 下一次调用（换一次屏幕配置、或者压根没有下一次）仍有机会重建成功，
    /// 而不会卡在一个「有 item、无 button、无 popover」的坏状态里。
    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else {
            // 半初始化 ⇒ 立刻回滚，不留下「有 item、无 button」的坏状态。
            if let halfBuilt = statusItem {
                NSStatusBar.system.removeStatusItem(halfBuilt)
            }
            statusItem = nil
            // ⚠️ 这里**不**写 `LogService`：那是「用户可见的磁盘日志」，而这是启动期的
            // 基础设施告警，写进去会混进用户排查推出问题时看的那个文件。
            // 本文件的生产路径本来也不落日志（`print` 只服务于 `--diagnostics` /
            // `--preview-*` 自检），所以这里保持一致：不引新的日志依赖。
            // 真的发生时的可见症状是「菜单栏图标不出」，且**不崩**。
            return
        }

        updateStatusItemImage()
        button.toolTip = L10n.tr(.appName)
        button.setAccessibilityLabel(L10n.tr(.appName))
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp(L10n.tr(.openMainWindow))
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))

        statusPopover = NSPopover()
        statusPopover.behavior = .transient
        statusPopover.animates = false

        // **NSStatusBarWindow 位置异常自检与重建**：
        // 当外接屏拔除 / macOS 屏幕配置变化后，NSStatusBarWindow 的 `frame` 会**残留**
        // 旧的屏幕坐标（本机实测：曾插过外接屏，拔了后 window.frame.origin.x = -3859，
        // button.window.screen = nil，window.frame 不在 NSScreen.screens 内），
        // 导致 `button.convert(_, to:).convertToScreen()` 拿到完全错误的屏幕坐标 →
        // popover 飞到屏幕外、用户看不见。
        // 销毁并重建 NSStatusItem，强制系统重新放置状态栏按钮。
        rebuildStatusItemIfOffscreen()

        // 监听屏幕配置变化：插入/拔除外接屏时主动重置状态栏位置。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` 已保证回调在主线程执行，用 assumeIsolated 把这一事实告知编译器，
            // 否则 Swift 6 严格并发会拒绝在 `@Sendable` 闭包里触碰 @MainActor 隔离的状态。
            MainActor.assumeIsolated {
                self?.rebuildStatusItemIfOffscreen()
            }
        }
    }

    /// 状态栏按钮若已不在任何屏幕内，销毁并重建 NSStatusItem。
    ///
    /// 外接屏拔除后 NSStatusBarWindow 会残留断屏前的 frame（见 `setupStatusItem` 注释），
    /// 重建可强制系统重新放置按钮，让后续所有基于屏幕坐标的计算重新可信。
    private func rebuildStatusItemIfOffscreen() {
        guard !statusItemButtonOnScreen(), let staleItem = statusItem else { return }
        NSStatusBar.system.removeStatusItem(staleItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.toolTip = L10n.tr(.appName)
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleStatusItemClick(_:))
        updateStatusItemImage()
    }

    /// 订阅「待处理占用提醒」，驱动菜单栏图标 + 清除已推出的盘。
    ///
    /// ## 两件事（都依赖 `EjectAttentionCenter`）
    ///
    /// 1. **有提醒 → 图标警示态**：菜单栏图标加一个小圆点（`exclamationmark.circle.fill`
    ///    叠在 `eject.fill` 上），提醒用户「有盘被占用推不出去，点开看」。
    /// 2. **盘消失 → 清除提醒**：提醒的盘已不在磁盘列表里（已推出 / 已拔），
    ///    提醒就失去意义，自动清掉。**为什么挂在磁盘列表上而不是「推出成功」回调**：
    ///    用户可能点系统框自己推出、也可能物理拔盘 —— 这两种都不走本应用的推出链路，
    ///    只有「盘不在了」是它们的共同结果。
    private func setupAttentionObserver() {
        let center = EjectAttentionCenter.shared

        // 0. 系统通知：装 delegate（**点击通知 → 打开菜单面板**）。
        //
        // 授权不在这里申请 —— 只有「用户开过这个功能」才有理由弹系统授权框，
        // 判据在 `EjectNotificationService.start(onOpenPanel:)` 里。
        EjectNotificationService.shared.start { [weak self] in
            self?.presentAttentionPanel()
        }

        // 1. 提醒变化 → 更新图标 + 投 / 撤系统通知。
        attentionCancellable = center.$pending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                guard let self else { return }
                self.updateStatusItemImage()
                self.syncAttentionNotifications(pending)
            }

        // 2. 磁盘列表变化 → 清除已不存在的盘的提醒。
        DiskListStore.shared.$disks
            .receive(on: DispatchQueue.main)
            .sink { disks in
                let mounted = Set(disks.map(\.mountPath))
                let stale = center.pending.keys.filter { !mounted.contains($0) }
                for path in stale { center.clear(mountPath: path) }
            }
            .store(in: &attentionSubscriptions)
    }

    /// 按「这一轮新出现的提醒 / 已经消失的提醒」投递与撤回系统通知。
    ///
    /// ## 为什么必须 diff
    ///
    /// ``EjectAttentionCenter/pending`` 每次变化发的都是**全量字典**，而访达的重试会让
    /// 同一块盘反复 `note`（同一键、新值）⇒ 对字典里每个元素都投一条必然刷屏。
    /// 「上一轮的键集合」是订阅端独有的知识，所以这份 diff 只能做在这里
    /// （通知服务那头只保留「怎么投、怎么撤」）。
    private func syncAttentionNotifications(_ pending: [String: EjectAttention]) {
        let current = Set(pending.keys)
        for key in current.subtracting(notifiedAttentionKeys) {
            guard let item = pending[key] else { continue }
            EjectNotificationService.shared.post(item)
        }
        for key in notifiedAttentionKeys.subtracting(current) {
            EjectNotificationService.shared.withdraw(mountPath: key)
        }
        notifiedAttentionKeys = current
    }

    /// 把菜单面板亮出来 —— 用户点击系统通知时的落点。
    ///
    /// **为什么是菜单面板而不是主窗口**：提醒与「关闭并推出」都在面板上。
    /// 跳去主窗口等于让用户再找一次那个按钮。
    ///
    /// ⚠️ **必须先 `activate`**：`.accessory` 形态下应用不在前台，
    /// `NSPopover` 不会上屏（与 `--preview-popover` 那条注释同一个坑）。
    @MainActor
    private func presentAttentionPanel() {
        guard let popover = statusPopover, let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { showStatusPopover(anchoredTo: button) }
    }

    /// 根据是否还有待处理提醒，切换菜单栏图标。
    private func updateStatusItemImage() {
        guard let button = statusItem?.button else { return }
        if EjectAttentionCenter.shared.hasPendingAttention {
            button.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: "Eject attention")
        } else {
            button.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        }
    }

    /// 检查当前状态栏按钮所在窗口 frame 是否与 NSScreen.screens 中任一屏相交。
    /// 不相交 → NSStatusBarWindow 仍持有断屏前的 frame，需要重建。
    private func statusItemButtonOnScreen() -> Bool {
        guard let window = statusItem?.button?.window else { return true }
        return NSScreen.screens.contains { screen in
            screen.frame.intersects(window.frame)
        }
    }

    /// 切换 popover 显示/隐藏。第二次点同一按钮会关闭。
    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        guard let popover = statusPopover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        showStatusPopover(anchoredTo: button)
    }

    /// 把菜单面板建起来并上屏。**抽出来是为了让 `--preview-popover` 走同一条路径** ——
    /// 真机自检要验的正是这条路径（材质归一化、contentSize、上屏），
    /// 另写一份「预览专用的显示代码」等于什么都没验。
    @MainActor
    private func showStatusPopover(anchoredTo button: NSStatusBarButton) {
        guard let popover = statusPopover else { return }
        // 重新构造 contentViewController，保证引用最新 AccentColor 等设置
        let accent = AppSettings.accentColor
        let view = MenuPopoverView(
            accent: accent,
            onOpenMainWindow: { [weak self] in self?.handlePopoverAction(.openMainWindow) },
            onRefresh: { [weak self] in self?.handlePopoverAction(.refreshDisks) },
            onOpenSettings: { [weak self] in self?.handlePopoverAction(.openSettings) },
            onQuit: { [weak self] in self?.handlePopoverAction(.quit) },
            onEject: { [weak self] disk in self?.handlePopoverEject(disk) }
        )
        // **定位完全交给系统，唯一要做的是先告诉它真实内容尺寸**。
        //
        // `preferredEdge` 的官方定义（Apple Docs, show(relativeTo:of:preferredEdge:)）：
        //   "The edge of positioningView the popover should prefer to be anchored to."
        // screen 坐标 y 向上，按钮在菜单栏里时 `button.minY` 是**视觉底部**，
        // 想让 popover 出现在按钮**下方** → 锚定 `.minY`。
        //
        // ⚠️ **"popover 离图标很远 / 先出现在下方再跳"的真正根因（2026-09-11 三组对照实验确认）**：
        // 若 `popover.contentSize` 在 show 时仍是 `(0,0)`——NSHostingController 的 SwiftUI
        // 内容此刻尚未布局，其 preferredContentSize 为 0——NSPopover 会**回退到默认 320×320**
        // 来计算锚点，于是 popover 顶部比按钮底部低了 `320 − 实际内容高度` pt。
        // 本机实测：内容高约 246 → 下偏 72pt，正是"离图标老远"的来源。
        //
        // 对照实验（/tmp/de_min_popover*.swift，均为教科书式 `show(preferredEdge: .minY)`）：
        //   A 显式 contentSize=360×272            → gap 0.5pt  ✓
        //   B SwiftUI 内容 + 不设 contentSize     → contentSize 变 (320,320) → gap 48.5pt  ✗
        //   C SwiftUI 内容 + show 前先布局取高度  → gap 0.5pt  ✓
        //
        // 结论：**系统定位本身是精确的**（gap 0.5pt 就是 popover 自带阴影区）。
        // 因此只需在 show 之前强制 SwiftUI 完成一次布局、把真实高度写进 contentSize，
        // 不再需要任何 snap 平移 / alpha 隐藏补偿（那套补偿才是"复杂"的来源）。
        let hosting = NSHostingController(rootView: view)
        hosting.view.setFrameSize(NSSize(width: DesignTokens.Size.menuPopoverWidth, height: 0))
        hosting.view.layoutSubtreeIfNeeded()
        let fittingSize = hosting.view.fittingSize
        // contentSize 必须在 contentViewController 之后设置，否则会被 hosting 覆盖。
        popover.contentViewController = hosting
        popover.contentSize = NSSize(
            width: DesignTokens.Size.menuPopoverWidth,
            height: max(fittingSize.height, 1)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // **让 popover 的底衬与主窗口同档材质**。
        //
        // `NSPopover` 的窗口顶层是私有的 `NSPopoverFrame`，它本身就是一档
        // `.titlebar` 的 `NSVisualEffectView`；主窗口用的是 `.underWindowBackground`。
        // 两者不是同一块玻璃 —— 这正是「菜单栏面板和主窗口背景色不一致」的根因。
        // 探针实测（2026-09-15）见 `NSPopover.normalizeBackdropMaterial()`。
        //
        // 视图树要等窗口真正上屏才建好，所以这里同步试一次、下一个 runloop 再试一次。
        // 两次都失败也不影响功能，只是面板会退回系统默认材质。
        popover.normalizeBackdropMaterial()

        // 防焦点环 + 让 NSPopover(.transient) hit-test 命中内部
        DispatchQueue.main.async {
            self.statusPopover.normalizeBackdropMaterial()
            self.statusPopover.contentViewController?.view.window?.makeFirstResponder(
                self.statusPopover.contentViewController?.view
            )
        }

        // 兜底：监听全局鼠标事件。NSPopover(.transient) 理论上会自动在点击外部时关闭，
        // 但 macOS 26 + SwiftUI 组合下偶有不触发（尤其合成事件或某些外部窗口）。
        // 这里手动检查：若 popover 显示且当前鼠标位置不在 popover 窗口内，则主动关闭。
        if popoverEventMonitor == nil {
            popoverEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in
                guard let self, let popover = self.statusPopover, popover.isShown else { return }
                let clickLocation = NSEvent.mouseLocation
                if let popoverWindow = popover.contentViewController?.view.window,
                    !popoverWindow.frame.contains(clickLocation)
                {
                    popover.performClose(nil)
                }
            }
        }
    }

    /// 面板动作的出口。为 `nil` 时走真实行为；`--preview-popover` 会把它换成「只记录」。
    ///
    /// **做成属性而不是在建视图时捕获闭包**：视图每次点开都重建，闭包换不了；
    /// 而真机自检要「同一个面板、先后走多个出口」。与 ``onboardingExitHandler`` 同一套做法。
    private var popoverActionHandler: ((MenuPopoverAction.Kind) -> Void)?

    /// 面板上的动作分发。**穷举 `switch` 是刻意的** —— `Kind` 加了新 case 而这里没跟上时
    /// **编译不过**。若用 `default: return` 兜底，新增一行会安静地渲染成一个点不动的按钮。
    private func handlePopoverAction(_ kind: MenuPopoverAction.Kind) {
        if let handler = popoverActionHandler {
            handler(kind)
            return
        }
        switch kind {
        case .openMainWindow:
            statusPopover?.performClose(nil)
            showMainWindow()
        case .refreshDisks:
            Task { await DiskListStore.shared.refresh() }
        case .openSettings:
            statusPopover?.performClose(nil)
            showSettings()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func handlePopoverEject(_ disk: DiskInfo) {
        statusPopover?.performClose(nil)
        eject(disk)
    }

    // MARK: - 偏好变更

    private func setupDefaultsObservation() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDefaultsChange() }
        }
    }

    private func handleDefaultsChange() {
        let showDockIcon = UserDefaults.standard.bool(forKey: AppSettings.Key.showDockIcon)
        if showDockIcon != lastShowDockIcon {
            lastShowDockIcon = showDockIcon
            updateDockIconVisibility()
        }

        // ⚠️ **强调色变化刻意不响应到菜单栏图标**（2026-10-01 用户报告后移除）：
        // 曾经在强调色变化时给状态栏按钮设 `contentTintColor`（tint 成强调色），
        // 但 template 图标一旦染色就被**锁定渲染色、退出系统自适应**——macOS 会按
        // **壁纸在菜单栏区域的亮度**把未染色的 template 图标自动渲染成黑/白，
        // 染色后这个行为消失：别的图标都随壁纸反色，本 app 图标永远停在强调色
        // （浅壁纸上对比度差时看起来就是「颜色错了」）。启动时本就不染色，
        // 所以症状是「有时对有时错」——改过强调色的那个会话内才错。
        // 内容区（磁盘行/容量条/按钮）走 `@AppStorage` 自动响应，不需要这里接线。
        //
        // ⚠️ **视觉风格（`visualStyle`）同样不在这里接线**（2026-10-08 清理）：
        // 主窗口背景由 `ContentView` 的 `@AppStorage` 自动响应。此前这里有一份
        // `lastVisualStyleRaw` 副本加一个**分支体为空**的 if —— 只读、比较、赋值，
        // 不产生任何效果，属于「看起来有逻辑、实际是空转」，现已连同那个变量一并删除。
        // 若将来视觉风格真的需要 AppDelegate 介入（例如要重建窗口背景材质），
        // 届时再加回来，并在这里写明**为什么 `@AppStorage` 不够**。
    }

    /// 依据「显示 Dock 图标」偏好切换激活策略，并在切换后把界面重新拉回前台。
    ///
    /// **关于「开关打开再关闭 → 主窗口界面闪退」的实测结论（2026-09-12，不要凭猜测改写）**：
    /// 用户报告切到菜单栏模式后主窗口界面消失。为此做了多轮真机对照实验（带设置 sheet、
    /// 切换前强制前台、CGWindowList 判在屏、A/B 两组各一），**均未能复现窗口消失**：
    /// - `setActivationPolicy(.accessory)` 前后 `NSWindow.isVisible` 恒为 true，窗口始终在
    ///   CGWindowList 的层 0 列表中，`NSApp.isActive` 也维持 true；负向对照（跳过下面这段收尾）
    ///   结果完全相同 —— 说明「策略切换把 App 踢到后台 / 把窗口挤走」在本系统上**不成立**。
    /// - 也没有任何 DiskEjector 的崩溃报告，进程始终存活。
    ///
    /// 保留这段收尾的理由是**它修复的是一个真实存在、且后果不可逆的状态**：
    /// 菜单栏模式下 App 既无 Dock 图标、也不在 ⌘Tab 列表里，一旦窗口因为任何原因
    /// （切策略、⌘M 最小化、被其它全屏 App 遮盖）离开视野，用户就**没有任何入口把它找回来**——
    /// 这正是「界面闪退」这一体验的不可恢复之处。切换后统一重新激活并前置窗口，让这种状态无法停留。
    private func updateDockIconVisibility() {
        let showDockIcon = UserDefaults.standard.bool(forKey: AppSettings.Key.showDockIcon)
        let target: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        restoreVisibleWindows()
    }

    /// 把仍然打开的窗口重新置于前台，避免激活策略切换把界面「丢」到别的应用后面。
    private func restoreVisibleWindows() {
        // **应用本来就活跃、且已经有一个可见的 key window —— 什么都不做。**
        //
        // 这一段是 2026-09-17 用户报「打开『在 Dock 中显示图标』时，主窗口和设置窗口
        // 都会闪一下」的根因：旧的写法无条件 `activateApp()` + 全体 `orderFrontRegardless()`
        // + `visible.first?.makeKey()`。用户在**设置窗口**里拨开关，而 `NSApp.windows` 里
        // 排在前面的往往是主窗口 —— 于是 key 被从设置窗抢走，两个窗口一起经历
        // 「失焦 → 重新排序 → 重新激活」，看起来就是闪一下。
        //
        // 上面那段注释里真正要防的是另一种情况：**窗口被策略切换挤走了**（没有 key window）。
        // 有 key window 就说明什么都没丢，此时再抢一次焦点纯属制造闪烁。
        //
        // 判据只看「有没有可见的 key window」，**不看 `NSApp.isActive`**：
        // 切激活策略的那一瞬间 `isActive` 可能短暂为 false，但窗口并没有丢 ——
        // 以它为准会把「其实没丢」也当成「丢了」，于是又去抢一次焦点、又闪一下。
        if let key = NSApp.keyWindow, key.isVisible { return }

        // `canBecomeMain` 过滤掉 NSPopover 面板、状态栏窗口等附属窗口，只处理真正的应用窗口。
        let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        guard !visible.isEmpty else { return }
        activateApp()
        for window in visible {
            window.orderFrontRegardless()
        }
        visible.first?.makeKey()
    }

    /// 激活本应用。
    ///
    /// macOS 14 起 `NSApplication.activate(ignoringOtherApps:)` 的参数已被标记为不再生效，
    /// 仅靠它无法保证抢到前台；`NSRunningApplication.activate(options:)` 才是当前有效的路径。
    /// 两条都调：前者兼容旧系统，后者覆盖 macOS 14+。
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
    }

    // MARK: - 菜单动作

    /// ⌘H / 应用菜单里的「隐藏 DiskEjector」。
    ///
    /// 标准语义是 `NSApp.hide(_:)`，但 macOS 规定**代理类（accessory）App 无法被隐藏**：
    /// 真机实测菜单栏模式下调用后 `NSApp.isHidden` 仍为 false —— ⌘H 等于一个死键。
    /// 因此按当前激活策略分流：
    /// - 常规模式（有 Dock 图标）→ 走系统 `hide:`，行为与所有 macOS App 一致；
    /// - 菜单栏模式 → 退化为「把窗口收起来」。窗口可用菜单栏图标 →「打开主窗口」找回，
    ///   让 ⌘H 在两种模式下都有确切、可预期的行为，而不是按下去没反应。
    @objc func hideApp(_ sender: Any?) {
        if NSApp.activationPolicy() == .accessory {
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                window.orderOut(sender)
            }
        } else {
            NSApp.hide(sender)
        }
    }

    // MARK: - 推出

    /// 推出指定卷。失败/占用的弹窗统一交给 ``EjectUI`` 处理，菜单栏与主窗口共用同一套。
    ///
    /// ## 2026-09-25 改：把「弹窗」与「等系统」解耦（§8.146，与 ``ContentView/eject(_:)`` 同一条）
    ///
    /// 原先这里是「等系统推出返回 → `refresh()` → `EjectUI.handle(outcome:)`」，
    /// 于是有占用的盘要**等系统那十几秒**才弹占用窗。现在把窗口上已经显示的
    /// 那份占用结论（``OccupancyStore/result(for:)`` 的缓存）一并交给
    /// ``EjectUI/eject(disk:cachedOccupancy:)`` ⇒ 立刻弹窗，系统照常在后跑。
    /// 顺带不再在弹窗之前做全量刷新（它对弹窗内容没有贡献，只是又叠一段等待）。
    private func eject(_ disk: DiskInfo) {
        ejectingDiskId = disk.id

        Task {
            await EjectUI.eject(
                disk: disk,
                cachedOccupancy: OccupancyStore.shared.result(for: disk))
            ejectingDiskId = nil
        }
    }

    // MARK: - 主窗口

    /// **幂等**：`--preview-main-window` 与 `applicationDidFinishLaunching` 各会调一次
    /// （预览那次在 `Task` 里，**实际执行在后者之后** —— 见 ``runMainWindowPreview`` 里
    /// 「先让位」那一段，那里记了一次由此产生的假绿）。
    /// 没有这道 guard 就会**建出两个窗口**，而且第二次把 `mainWindow` 覆盖掉 ——
    /// 第一个从此没人引用、关不掉也释放不了。
    ///
    /// ⚠️ **它一旦返回，`mainWindowStore` 就与 `mainWindow` 绑定** —— 后续自检都读它。
    private func setupMainWindow(
        store: DiskListStore? = nil,
        skipsInitialRefresh: Bool = false,
        occupancyStore: OccupancyStore? = nil
    ) {
        guard mainWindow == nil else { return }
        mainWindowStore = store
        mainWindow = Self.makeMainWindow(
            store: store, skipsInitialRefresh: skipsInitialRefresh, occupancyStore: occupancyStore)
    }

    /// 建主窗口。**真机与单测走同一条装配路径**（`MainWindowTests` 直接调它）。
    ///
    /// 与 ``makeOnboardingPanel(root:)`` 同一个理由：下面这几行配置**每一条去掉都会静默劣化**，
    /// 而任何一条都不会让别的断言变红 —— 光读代码看不出它们是不是冗余。
    ///
    /// - Parameters:
    ///   - store: 内容视图读的磁盘列表来源；`nil` = ``DiskListStore/shared``（生产路径）。
    ///     注入一个空列表实例就得到**空状态**窗口，见 ``runMainWindowPreview(autoKeys:emptyDisks:)``。
    ///     与 ``MenuPopoverView`` 的 `store:` 是同一个约定（那边早就可注入）。
    ///   - skipsInitialRefresh: 见 ``ContentView/init(skipsInitialRefresh:store:)``。
    ///     ⚠️ **注入 `store` 时必须同时传 `true`** —— 否则内容视图的 `.task` 会去枚举本机磁盘，
    ///     把注入的列表覆盖掉，空状态自检当场失效（而且失效得很安静）。
    ///   - occupancyStore: 内容视图读的占用结论来源；`nil` = ``OccupancyStore/shared``。
    ///     **与 `store` 是配对关系**：只注入 `store` 会让窗口「列表是注入的、占用结论来自真机」。
    ///     单测与预览请用 ``ViewFixtures``（测试）或 `runMainWindowPreview`（预览）里配好的一对。
    static func makeMainWindow(
        store: DiskListStore? = nil,
        skipsInitialRefresh: Bool = false,
        occupancyStore: OccupancyStore? = nil
    ) -> NSWindow {
        let win = KeySilentWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: DesignTokens.Size.mainWindow.width,
                height: DesignTokens.Size.mainWindow.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.tr(.appName)
        // 标题栏不绘制标题文字：红绿灯右侧只留空白，应用身份由状态栏图标与窗口内容表达。
        // `titleVisibility = .hidden` 只影响绘制，`title` 字符串仍保留——窗口菜单（Window）、
        // Mission Control、辅助功能读取到的仍是正确的应用名。
        win.titleVisibility = .hidden

        // **窗口层面的外观，全部在这里定死 —— 不要挪回 `ContentView` 的 `WindowAccessor`。**
        //
        // 它们原先就散在那里（一个 `NSViewRepresentable`，要等视图进窗口、再走一次
        // `DispatchQueue.main.async` 才生效）。实测那是个**不可靠的时机**：
        // `MainWindowTests` 里推完布局又跑了 run loop，`titlebarAppearsTransparent` /
        // `backgroundColor` / `isOpaque` **依然没生效**。而这几条决定了
        // 「窗口看起来是玻璃，还是一块不透明白板」—— 不该靠时序碰运气。
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.defaultButtonCell = nil
        // **毛玻璃关键**：清掉 NSWindow 自带的 windowBackgroundColor 半透明白底，
        // 否则 NSVisualEffectView(.underWindowBackground, .behindWindow) 会被它盖住，
        // 桌面无法透到 SwiftUI 里的毛玻璃上面，整张主窗口看起来只是一片浅色色块。
        win.backgroundColor = .clear
        win.isOpaque = false

        // **内容装配整块搬到了 ``MainWindowContentController``**（v3：主窗口与设置合并）。
        //
        // 搬走的理由不是「文件太长」，是那三件事**必须一起对**、而它们各自都只在运行时
        // 才暴露出错：① 玻璃挂在 `NSSplitViewController.view` 的最底层；
        // ② 侧栏交还系统（浮岛 / 圆角 / 材质零代码）；③ **两个窗格对安全区的要求相反**
        // （详情区必须关、侧栏必须不关）。三条都记在那个类的抬头里，附实测数据。
        let content = MainWindowContentController(
            store: store,
            skipsInitialRefresh: skipsInitialRefresh,
            occupancyStore: occupancyStore,
            // ⚠️ 与 `--preview-settings-no-fda` / `-has-fda` 两个旗标同源：
            // 本机能给到的只有一半的 TCC 状态，另一半必须在自检里强制出来。
            takeOverAvailabilityOverride: previewTakeOverAvailability)
        win.contentViewController = content

        // **工具栏那条 52pt 带子不是「装按钮的容器」**（HANDOFF §3.1.1）。
        // 去掉它实测要付四条代价、其中两条**手工补不齐**：红绿灯垂直中心 26→16pt、
        // 侧栏浮岛的上内缩 8→32pt。详见 ``MainWindowContentController`` 与
        // `Design/ui/v3/HANDOFF.md` §3.1.1 的四行对照表。
        win.toolbarStyle = .unified
        win.toolbar = content.makeToolbar()

        // **避免 SwiftUI 启动时第一个 Button 自动获得焦点环**：
        // SwiftUI 主窗口首屏显示时，焦点环默认套在第一个 Button 上，
        // 看着像「按钮被高亮选中」。`initialFirstResponder = nil` 让首焦点为空。
        // 必须在 `contentViewController` 赋值之后设 —— 否则会被随后的赋值重置掉。
        win.initialFirstResponder = nil

        win.center()
        // **尺寸保证**：`contentRect` 只是建窗起手值，`contentViewController` 赋值会把它
        // 覆盖掉（见 ``MainWindowContentController/viewDidLoad()`` 里那条约束的说明 ——
        // v3 实测这一句会把窗口吸成 500×500）。所以尺寸由**三处**一起保证，缺一不可：
        //
        // 1. `MainWindowContentController` 里那两条宽高约束 —— 长期稳定，管住 AppKit
        //    后续任何一次「fit 到内容」；
        // 2. 下面这一句 `setContentSize` —— **建窗瞬间**就正确。单测读的正是这一刻的
        //    `frame`（不上屏，约束还没走到 layout），所以少了它 `MainWindowTests` 会红；
        // 3. 这条 `minSize` —— 用户侧的表达（本窗口没有 `.resizable`，实际拖不动）。
        //
        // 不设 `maxSize`：`sizingOptions` 会把内容视图的 `maxSize`（`.frame(maxWidth:
        // .infinity)` → 无限大）推给窗口，设了也会被覆盖 —— 写一句注定失效的代码
        // 只会误导后来者。
        win.setContentSize(DesignTokens.Size.mainWindow)
        win.minSize = NSSize(
            width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height
        )
        win.isReleasedWhenClosed = false
        return win
    }

    /// 显示主窗口。菜单栏弹窗的「打开主窗口」、菜单里的「显示主窗口」（⌘O）与
    /// Dock 图标点击（reopen）都走这里。
    ///
    /// 必须处理**最小化态**：菜单栏模式下 App 没有 Dock 图标，⌘M 把窗口缩进 Dock 后
    /// 用户**没有任何办法点回来**（Dock 上根本没有这个 App），是一个真正的死路。
    /// 这里先 `deminiaturize` 再前置，保证这条恢复路径对「关掉」和「缩掉」两种状态都有效。
    @objc func showMainWindow() {
        if mainWindow == nil {
            setupMainWindow()
        }
        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
        activateApp()
        // ⚠️ v3 起这里**不再有**「上屏后再收敛一次标题栏」那两行
        // （``enlargeTitleBar(in:)`` / ``alignTrafficLights(in:)``，已随工具栏一起退役）：
        // 52pt 那条带子现在由 `NSToolbar` 提供、红绿灯由 AppKit 自己居中到 26pt。
        // 两者都**幂等且由系统负责**，没有我们的事了（HANDOFF §3.2）。
    }

    // MARK: - 刷新磁盘列表

    /// 重新枚举外接磁盘（主菜单 ⌘R）。**转发给窗口内容控制器**，与工具栏那颗刷新按钮同路。
    ///
    /// **为什么需要这条 action**：菜单栏面板的动作行按设计稿要标出 `⌘R`，而 macOS 的 ⌘
    /// 快捷键只能经**主菜单**的 `keyEquivalent` 分发 —— 不在这里开一个 action，
    /// 面板上那个 `⌘R` 就只是画上去的装饰，按下去毫无反应。
    ///
    /// ## 为什么转发而不是自己刷一遍
    ///
    /// 刷新的落点与「窗口在看哪一份 ``DiskListStore``」绑定：注入过 store 的窗口
    /// （空状态自检、离屏出图）读的不是 `.shared`。这里若写 `DiskListStore.shared.refresh()`，
    /// 注入场景下就会出现「⌘R 刷新了另一份列表」—— 界面上**什么都没变**，
    /// 而工具栏那颗按钮（走控制器）却是好的。⇒ 收敛到一条实现。
    ///
    /// 没有主窗口时（直发版可以只驻留菜单栏）退回刷 `.shared` —— 那正是生产路径那一份。
    @objc func refreshDisks() {
        guard let content = mainWindowContent else {
            Task { @MainActor in await DiskListStore.shared.refresh() }
            return
        }
        content.refreshDisks()
    }

    // MARK: - 设置

    /// 打开设置：**显示主窗口 + 选中「设置 · 通用」**。
    ///
    /// ## v3 起设置不再是独立窗口
    ///
    /// 设计稿把主窗口与设置合并成「单侧栏导航 + 详情区」（`Design/ui/v3/`），
    /// 所以三个入口（内容区齿轮 / 主菜单 ⌘, / 菜单栏面板的「设置…」）落点完全一致：
    /// 把主窗口亮出来，再把侧栏选中项拨到「设置 · 通用」。
    ///
    /// ⚠️ **必须走 ``showMainWindow()`` 而不是自己 `makeKeyAndOrderFront`**：
    /// 那条路里有「最小化态先 `deminiaturize`」——菜单栏模式下 App 没有 Dock 图标，
    /// 窗口被 ⌘M 缩进 Dock 后用户没有任何办法点回来（同 ``showMainWindow()`` 的说明）。
    /// 设置入口是仅次于 Dock 图标的那条恢复路径，不能是唯一的例外。
    ///
    /// `@objc` 是为了能被主菜单的「设置…」（⌘,）直接指定为 action。
    @objc func showSettings() {
        showMainWindow()
        mainWindowContent?.model.selection = .settings(.general)
    }

    // MARK: - 关闭/退出

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        switch AppReopenPolicy.target(
            hasPendingAttention: EjectAttentionCenter.shared.hasPendingAttention)
        {
        case .attentionPanel: presentAttentionPanel()
        case .mainWindow: showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
