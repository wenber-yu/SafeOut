import AppKit
import Combine
import Foundation
import OSLog
import Sparkle

/// 更新这件事**当前进行到哪一步**。
///
/// **为什么不是一个布尔 / 一个「有没有新版本」标记**：设计稿 `08-update.html` 的 C 段
/// 是一张九行状态矩阵，其中「后台下载中」「已就绪」「下载失败」三种状态**都在
/// 「有新版本」之后**，布尔量装不下。
///
/// 更要紧的是：**没有生产者去推进的状态，在界面上与「已经支持了」长得一模一样** ——
/// 所以这里只列**真有代码会设置**的档位（生产者见 `UpdateUserDriver`）。
enum UpdatePhase: Equatable {
    /// 什么都没在进行（也包含「检查完发现是最新」「已跳过」「从未检查」）。
    case idle
    /// **用户点了「检查更新」，Sparkle 还没给出答案**（§8.93 / §8.97）。
    ///
    /// 真机实测（dist 产物，单时间轴 4 轮）从按下到界面有反应是 **4.31 / 3.15 / 4.51 秒**
    /// （典型 3~4.5 秒）。此前这段时间 `phase` 停在 `.idle` ⇒ 界面仍显示上一轮的结果，
    /// 且「检查更新」按钮**仍可反复点** —— 用户不知道自己那一下到底有没有生效。
    /// 原注释写的「这一段通常只有几百毫秒」已被实测推翻。
    ///
    /// ⚠️ **它必须有出口**：`showUpdateFound` → `.found` / `.downloading`；
    /// `showUpdateNotFoundWithError` 与 `showUpdaterError` → `driverDidReset()` → `.idle`。
    /// Sparkle 的手动检查**不受 24h 节流限制**（节流只针对自动检查），
    /// 所以「点了但一个回调都不来」不是一条真实存在的路。
    case checking
    /// 发现新版本，等用户决定（弹窗开着，或用户按了 Esc 之后留在设置行上）。
    case found(version: String)
    /// 正在后台下载。
    ///
    /// `fraction` 为 `nil` 表示**百分比无从得知**，与 `0` 是**两种不同的状态**：
    /// 「自动更新」开着时走的那条路（`SPUAutomaticUpdateDriver`）不提供任何进度回调，
    /// 所以只能知道「在下载」而不知道「下了多少」（§8.81）。
    ///
    /// **为什么要分成两种**：画一条停在 0% 的进度条比不画更让人怀疑 —— 用户会盯着
    /// 那个 0% 判断「是不是卡住了」。设计稿 B3 那句「百分比是真的，ETA 是编的」
    /// 反过来就是这一条：**不知道就别猜**。
    case downloading(version: String, fraction: Double?)
    /// 下载并校验完成，等重启安装。
    ///
    /// ## 为什么带着 `autoRestart`（2026-09-25，§8.146.2）
    ///
    /// 同一个「已就绪」，**两条路上的承诺不一样**：
    ///
    /// - **自动那条路**（`willInstallUpdateOnQuit`）：用户没点过任何东西，
    ///   语义是「下次退出时静默装上」⇒ 界面只能说「重启后完成安装」。
    /// - **弹窗那条路**（用户点过「后台更新并重启」）：现在会**自己重启**
    ///   （`readyHandling` 的 `.autoRestart` / `.deferUntilIdle`）⇒
    ///   界面必须说出来，否则用户在等一个他以为要自己点的动作。
    ///
    /// ⚠️ **所以它不能是「写死一句话」**：`.ready` 那一行**恰恰在自动那条路上
    /// 待得最久**（弹窗那条路一进 `.ready` 就回答 `.install`，只有「有卷在推出」
    /// 那一段会停住）—— 把「会自动重启」写死进那行的文案，会在**唯一看得见它的
    /// 那条路**上变成新的一句谎话，正是本轮在修的那一类。
    ///
    /// ⚠️ **为什么记在相位里、而不是让视图去读一个开关**：它是
    /// ``readyHandling(userChoseInstallAndRestart:activeEjections:)`` 在
    /// ``driverIsReady(version:reply:)`` 里**当场算出来的结论**，
    /// 记下来就是「这一轮会话已经这么决定了」。让视图另读一个可变开关的话，
    /// `installReadyUpdate()` 清掉那个开关之后，这一行会**在应用退出的那 100ms 里
    /// 把话改回去**（`readyReply` 被清空 ⇒ 开关翻假）。记在相位里不会翻。
    case ready(version: String, autoRestart: Bool)
    /// 下载失败。
    case failed(version: String)
    /// **下载成功了，但之后那一步失败** —— 解压 / 验签 / 安装（账本第 43 行，2026-09-22）。
    ///
    /// ## 为什么它必须**单独成态**，不能并进 ``failed(version:)``
    ///
    /// 真机实测（QA，2026-09-22）：用真签名 dmg 造成功下载时，下载与 EdDSA 验签都过了，
    /// 界面走到「正在后台下载 …」之后报 `运行更新程序时出现错误`。此时 `phase` 仍是
    /// `.downloading` ⇒ 旧判据判成「下载失败」⇒ 界面写「**网络不可用**。下次启动会自动重试」
    /// —— **而下载其实是成功的**，用户会去查网络。
    ///
    /// ⚠️ **这一态是被上一轮的修复「放大」后才显眼的**：以前那句谎 30ms 后就被冲回
    /// `.idle`（一闪而过），现在会**一直挂着**。所以必须给它自己的落点 + 不撒谎的文案。
    ///
    /// ⚠️ **不能只是「把安装失败挡掉」**：排除之后它若落进 `showUpdaterError` 的 else
    /// ⇒ `driverDidReset()` ⇒ `.idle` ⇒ **又一次无声消失**，正是前两轮修掉的那个病
    /// （§8.121 / QA 复验）。⇒ 排除与落点必须**同一轮一起做**。
    ///
    /// 判定见 ``UpdateController/isPostDownloadFailure(_:)``。
    case installFailed(version: String)
    /// **应用当前所在的位置不允许更新** —— 只读卷（dmg 挂载点）或 App Translocation（§8.94）。
    ///
    /// 这一态**不是「错误处理的细节」，是「不许说谎」**：`SPUUpdater` 发起检查时**即写**
    /// 「上次检查时间」（`SPUUpdater.m:789`，不看成败），而只读卷上 Sparkle **根本不去取
    /// appcast**（`SPUBasicUpdateDriver.m:71` 用 `statfs` 查 `MNT_RDONLY` ⇒ 直接 abort，
    /// 错误码 `1003`）。于是界面会刷新「上次检查」并宣称「已是最新版本」——
    /// **即使 appcast 里有新版本，用户永远看不到**（2026-09-20 §8.94 实测：零网络请求）。
    ///
    /// 判定见 ``UpdateController/isUpdateLocationBlocked(_:)``；文案**不给按钮**
    /// （我们没法替他搬文件，给一个点了没反应的按钮就是下一个坑）。
    case locationBlocked
}

/// 弹窗要展示的那一份「新版本说明」。
///
/// **为什么不直接从 `SUAppcastItem` 读**：那个对象只活在 `showUpdateFound` 那一次回调里，
/// 而用户可能过很久才点「查看更新」（甚至按 Esc 之后隔一天再回来）。
/// 存成值类型之后，弹窗在**任何时候**都能重建，不依赖 Sparkle 还留着那个 item。
struct PendingUpdate: Equatable {
    /// 用户看到的版本号（`CFBundleShortVersionString`，如 `1.1.0`）。
    let version: String
    /// 新版本的构建号（`CFBundleVersion`）。
    let newBuild: String?
    /// 当前版本（弹窗里「当前 x → y」的左半边）。
    let currentVersion: String
    let currentBuild: String?
    /// appcast 里的日期串（原样显示，不解析 —— appcast 写的是发布者给的字符串）。
    let date: String?
    /// 安装包字节数（0 表示 appcast 没写，此时不显示体积）。
    let sizeBytes: UInt64
    /// 本次更新条目（appcast 的 `<description>` 解析而来）。
    let notes: [String]
}

extension PendingUpdate {

    /// 从 Sparkle 的 appcast 条目翻译过来。
    ///
    /// **只有这一处知道怎么翻译**：同一个 `SUAppcastItem` 会从**两条不同的路**到达应用 ——
    ///
    /// - 弹窗那条：user driver 的 ``UpdateUserDriver/showUpdateFound(with:state:reply:)``；
    /// - 自动那条（`SUAutomaticallyUpdate` 开着 + 后台检查）：delegate 的
    ///   ``UpdateController/updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)``。
    ///   那条路**一个 user driver 回调都不发**，所以 delegate 是它唯一的入口（见 §8.80）。
    ///
    /// 两处各写一遍的话，「显示版本号 / 体积 / 更新条目」这些字段迟早会在两条路上不一致
    /// —— 而**没有任何东西会红**：两条路各画各的，用户看到的只是「自动更新时弹窗里少了体积」
    /// 这种没人会去比对的现象。
    init(appcastItem: SUAppcastItem) {
        self.init(
            version: appcastItem.displayVersionString,
            newBuild: appcastItem.versionString,
            currentVersion: AppVersionInfo.shortVersion() ?? L10n.tr(.updateUnknownVersion),
            currentBuild: AppVersionInfo.build(),
            date: appcastItem.dateString,
            sizeBytes: appcastItem.contentLength,
            notes: UpdateReleaseNotes.lines(fromHTML: appcastItem.itemDescription))
    }
}

/// Sparkle 自更新的**唯一持有者**。
///
/// ## 为什么单开一个类，不塞进 `UpdateService`
///
/// `UpdateService` 是纯值 / 纯函数（渠道判定 + 拼 Releases 页地址），在单测进程里随便跑；
/// `SPUUpdater` 一创建就要读宿主 bundle 的真实身份、起会话、可能弹窗 —— 碰它就是碰运行时。
/// 分开之后单测可以继续断言前者，不被后者拖下水（同种拆法见 `DiskService` §8.31）。
///
/// ## 用 `SPUUpdater` 而不是 `SPUStandardUpdaterController`
///
/// `SPUStandardUpdaterController` 会自动往**应用的主菜单**里插「Check for Updates…」，
/// 而本应用的菜单栏是 `MainMenu.swift` 自己搭的 SwiftUI 菜单，没有传统 MainMenu.nib。
/// 控制器插不进东西（不崩，但也没效果），还会持有一份我们看不见的状态 ——
/// 于是直接用 `SPUUpdater`，入口由我们自己决定放哪。
///
/// ## 用自定义 `UpdateUserDriver` 而不是 `SPUStandardUserDriver`（2026-09-18）
///
/// 设计稿 `08-update.html` 要求的弹窗与标准弹窗不是一回事：标题带版本号、
/// **本次更新**清单、提示块、「跳过此版本」，以及操作区左边那个不占按钮的 Esc 出口。
/// 更要紧的是设计稿把「后台下载中」的**百分比**画在设置行上，而 Sparkle **只在
/// user driver 里**给下载进度（`showDownloadDidReceiveExpectedContentLength` /
/// `showDownloadDidReceiveData`）—— 走标准 driver 拿不到这两个回调。两者叠加，只能自己实现。
@MainActor
final class UpdateController: NSObject, ObservableObject {

    static let shared = UpdateController()

    private static let logger = Logger(subsystem: "com.safeout.app", category: "Update")

    /// 本次运行是不是调试构建（决定 `ensureUpdater()` 要不要整个跳过 Sparkle）。
    ///
    /// ⚠️ **为什么是「常量 + 运行时判断」，而不是直接用 `#if DEBUG` 包住 `ensureUpdater()`
    /// 的其余部分**（2026-09-23 实测踩到）：
    /// `#if DEBUG` 里直接 `return nil` 会让**后面那一整段成为不可达代码**，
    /// `-Xswiftc -warnings-as-errors` 的门槛 1 立刻报
    /// `error: code after 'return' will never be executed`；
    /// 反过来把那段塞进 `#else`，则 Release 的代码在开发期**从未被类型检查过**，错了要等打包才发现。
    /// 把「判断」与「逻辑」分开之后，**两条分支都参与编译**，也没有不可达代码。
    nonisolated static let isDebugBuild: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    private var updater: SPUUpdater?

    /// 必须强引用住：`SPUUpdater` 对 user driver 是**弱引用**，driver 一被释放，
    /// Sparkle 就没有 UI 可用了（下一次更新会静默什么都不显示）。
    private var driver: UpdateUserDriver?

    /// 上一次启动失败的原因（避免每次点按钮都重试一遍然后再次失败）。
    private var startError: String?

    /// 本次运行是否已经做过那次「启动检查」。
    ///
    /// ⚠️ **它必须存在，否则会把 Sparkle 的定时排期一起掀掉**：
    /// ``updater(_:willScheduleUpdateCheckAfterDelay:)`` 在**每一次**排期时都会到
    /// （首启这次、以及每轮检查结束后的下一次），而那里会调
    /// `checkForUpdatesInBackground()`。不设这个闸门的话，每次 Sparkle 说「等 N 秒」，
    /// 我们都立刻替它查 —— `SUScheduledCheckInterval`（6 小时）会被压成
    /// ``launchCheckDebounce``（5 分钟），常驻期间一天要打近 300 次请求。
    /// ⇒ 只在**第一次**把 Sparkle 的排期决定覆盖掉。
    ///
    /// ⚠️ 它是**进程级**的：应用重启后重置 —— 那正是「每次启动查一次」的语义。
    private var didRunLaunchCheck = false

    /// 更新进行到哪一步。**设置面板与弹窗都读它**，不各自维护一份。
    @Published private(set) var phase: UpdatePhase = .idle {
        didSet { syncStallWatch() }
    }

    /// 弹窗的内容（`showUpdateFound` 时填充）。
    private(set) var pendingUpdate: PendingUpdate?

    /// 「后台下载中」那行「取消」要调的东西。
    private var downloadCancellation: (() -> Void)?

    // MARK: - 下载停摆兜底（DESIGN-SPEC 第 34 行）

    /// `.downloading(_, fraction: nil)` **持续超过这个时长** ⇒ 转 `.failed`（那支有「重试」）。
    ///
    /// **为什么要兜底**：那一支按设计**不给进度条、也不给「取消」**（§8.81 / §8.82），
    /// 于是下载挂住时那一行会**一直**停在那儿 —— 没进度、没错误、没出口，只能退出应用。
    /// 真机撞上过（根因是那台机器下不动 release 资产，但**症状是产品侧的**）。
    ///
    /// ✅ **N 已拍板 = 120s**（2026-09-20，DESIGN-SPEC 第 34 行）：之所以提成常量，
    /// 就是为了改一个数就能调，不必翻逻辑。
    nonisolated static let downloadStallTimeout: TimeInterval = 120

    /// 停摆检查的节拍（不是超时本身）。
    nonisolated static let stallCheckInterval: TimeInterval = 10

    /// 进入「无百分比的下载中」的时刻；离开该态即清空 ⇒ 重新进入会重新计时。
    private var stallSince: Date?
    private var stallTimer: Timer?

    /// 停摆判定 —— **纯函数，只看入参**。
    ///
    /// 为什么要与定时器解耦：这样单测**不必等真的 120 秒**，也不必实例化本类
    /// （实例化会去碰 `SPUUpdater`）。与 §8.83 把 `willDownloadUpdate` 抽纯函数是同一个理由。
    /// ⚠️ **`nonisolated`**：它是纯函数（只看三个入参），不该被 `@MainActor` 绑住
    /// —— 与 ``rowState`` 同理由（绑住之后单测进程里调不到它）。
    nonisolated static func isDownloadStalled(
        since: Date?, now: Date, timeout: TimeInterval = downloadStallTimeout
    ) -> Bool {
        // 「还没进入该态」不算停摆 —— 没有计时起点时判定必须恒假，
        // 否则会把「根本没在下载」误判成「下载停摆」。
        guard let since else { return false }
        return now.timeIntervalSince(since) >= timeout
    }

    /// 「已就绪」状态下，Sparkle 等着我们回答的那个 reply。
    ///
    /// **为什么要攥着**：攥着 reply 意味着用户点「立即重启」时
    /// 我们能给出真正的 `.install`（Sparkle 会装完并重新拉起应用），
    /// 而不是「先 dismiss 再想办法把更新找回来」。
    ///
    /// ## ⚠️ 2026-09-24 用户拍板：弹窗那条路**改成自动重启**（§8.146）
    ///
    /// 这里原来写的是「设计稿 B4 说得很清楚 —— 重启不自动做，只提供入口」。
    /// 那句与弹窗自己的两句承诺**自相矛盾**：`updateCallout` 写
    /// 「…完成后**自动重启完成安装**」、`updateDownloadingHint` 写
    /// 「下载完成后会自动安装，无需你再操作。」⇒ 用户看到的是
    /// 「弹窗说要自动重启，实际下载完却停在那里等手动点」。
    /// 以那两句为准（用户 2026-09-24 拍板），B4 那段 spec-note 已一并订正。
    ///
    /// 现在这一格仍有**两种**到达方式（判据是纯函数
    /// ``readyHandling(userChoseInstallAndRestart:activeEjections:)``）：
    ///
    /// - 用户点过「后台更新并重启」且**没有**推出在进行 ⇒ **立刻**回答 `.install`（自动重启）；
    /// - 用户点过、但**此刻有卷正在推出** ⇒ 攥着，等推出结束再回答 `.install`
    ///   （``ReadyHandling/deferUntilIdle``，见 ``driverIsReady(version:reply:)``）；
    /// - 其余（用户没点过：自动下载那条路、或弹窗上按了 Esc「稍后」）⇒ 攥着，等用户点「立即重启」。
    ///
    /// ⚠️ **代价（已核实，不是猜的）**：`SPUUpdater` 的文档写明
    /// 「`checkForUpdates` does not do anything if there is a `sessionInProgress`」，
    /// 而攥着 reply 就等于会话没结束。所以处于「已就绪」时点「检查更新」是**没有反应**的 ——
    /// 这就是为什么这一态下设置行不再显示「检查更新」按钮（改显示「立即重启」），
    /// 否则就会出现「按钮点了没反应，而用户无从分辨原因」。
    ///
    /// ## 两个来源，两种形状（2026-09-19）
    ///
    /// - **弹窗那条**：`showReady` 给的 `(SPUUserUpdateChoice) -> Void`，答 `.install`。
    /// - **自动那条**：`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`
    ///   给的 `() -> Void`，包成 `{ _ in block() }` —— 那个 block 就是「现在装」。
    ///
    /// 两者都塞进这一个字段，是为了让「立即重启」只有 `installReadyUpdate()` **一处实现**
    /// （两条路各写一份的话，「回答前先清空」这类细节迟早只在一条路上生效）。
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?

    /// 「发现新版本」时弹窗要回答的那个 reply。
    ///
    /// ## ⚠️ 用户按 Esc「稍后」时**攥着不回答**（2026-09-25，§8.146）
    ///
    /// 原先 Esc 分支回答 `.dismiss`，而 Sparkle 把 `.dismiss` 处理成
    /// `uiDriverIsRequestingAbortUpdateWithError:nil`（`SPUUIBasedUpdateDriver.m:308`）
    /// → `abortUpdateWithError:showErrorToUser:YES` → `_abortUpdateWithError:` 的
    /// `abortUpdate()` 块（`:454`）→ `dismissUpdateInstallation`（`:456`）
    /// → ``UpdateUserDriver/dismissUpdateInstallation()`` → `driverDidReset()` → `phase = .idle`。
    /// 而 `.found` **不是**终态（``isTerminalPhase(_:)``）⇒ 那一支不会拦它
    /// ⇒ 设置行落到 `rowState` 的 `if let lastCheck { return .upToDate(lastCheck) }`
    /// ⇒ 界面写「上次检查：… · **已是最新版本**」——**而它明明发现了 1.1.0**。
    /// 设计稿 `08-update.html` C 段第 6 行写死了应然行为：「稍后（Esc / 关窗）」
    /// ⇒「**与上一行相同 —— 状态留在界面上**」（B2 那一帧的标签就是
    /// 「2 · 自动更新关 · 发现新版本（Esc 之后）」）。
    ///
    /// ⇒ 攥住 reply 与 ``readyReply`` 是**同一个手法**（会话不结束、状态不被打回），
    /// 于是「查看更新」（``presentFoundUpdate()``）能原样把弹窗拉回来，
    /// 而且**不会再多打一次网络请求**。
    ///
    /// ⚠️ **代价（已核实，与 `.ready` 那条路逐字相同）**：攥着 reply 就等于
    /// `sessionInProgress == YES`，而 `SPUUpdater` 文档写明
    /// 「`checkForUpdates` does not do anything if there is a `sessionInProgress`」
    /// ⇒ `.found` 期间 ``checkForUpdates()`` **没有反应**。这就是为什么
    /// `.found` 那一行**本来就不显示**「检查更新」按钮（`SettingsView.updateCheckLine`
    /// 的 `case .found` 给的是 `viewUpdateButton`）—— 同 ``readyReply`` 那条判据。
    ///
    /// ⚠️ **不许改用「把 `.found` 加进 ``isTerminalPhase(_:)``」**：那个闸门同时装在
    /// ``UpdateUserDriver/showUpdaterError(_:acknowledgement:)`` 上，把 `.found` 变终态
    /// 会让「检查过程中出错」的 reset 路径失效 —— 而 `.found` 期间 Sparkle 那一轮
    /// **并没有** abort（我们没回答），它与「已经发生的事实」不是一回事。
    private var alertReply: ((SPUUserUpdateChoice) -> Void)?

    /// 用户在这次更新会话里是否**明确点了**「后台更新并重启」。
    ///
    /// ## 为什么必须记住它（而不是从 `phase` 派生）
    ///
    /// ``driverIsReady(version:reply:)`` 到达时，我们已经无法从 `phase` 反推用户当初选了什么：
    ///
    /// - **弹窗那条**（用户在弹窗上点了「后台更新并重启」）⇒ `reply(.install)`
    ///   ⇒ `downloadUpdateFromAppcastItem:… inBackground:NO`（`SPUUIBasedUpdateDriver.m:277`）；
    /// - **自动下载那条**（`SUAutomaticallyUpdate` 开着 + 用户手动点检查 ⇒
    ///   ``UpdateUserDriver/showUpdateFound(with:state:reply:)`` 里 `shouldPresent == false`
    ///   ⇒ 直接 `reply(.install)`）。
    ///
    /// 两者在 `showReady` 那一刻 `phase` **都是** `.downloading` —— 分不出来。
    /// 而两者的应然行为**相反**：前者要兑现弹窗提示块（`updateCallout`）的承诺
    /// 「完成后**自动重启完成安装**」；后者（以及 ``updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)``
    /// 那条路）的语义是「等退出时装」，用户没点过。
    ///
    /// ⇒ 这是**用户输入**，不是「可以派生的状态」：它记录的是用户按下了哪个按钮。
    /// 与「能派生就别用『手动开关』」那条纪律不冲突 —— 那条禁的是
    /// 「**会与真实情况脱节**的手动开关」，而这个标记的生命周期被严格绑在一次会话上
    /// （``driverDidFindUpdate(_:autoDownloads:reply:)`` 一进门就重置，
    /// ``driverDidReset()`` / ``installReadyUpdate()`` / ``checkForUpdates()`` 也清）。
    ///
    /// 判定见 ``readyHandling(userChoseInstallAndRestart:activeEjections:)``。
    private var userChoseInstallAndRestart = false

    private override init() { super.init() }

    // MARK: - 生命周期

    /// 创建并启动 updater（幂等；失败时记下原因，返回 `nil`）。
    ///
    /// **预览模式不建**：`--preview-*` 跑的是未签名的命令行产物，
    /// `Bundle.main` 不是合规的 app bundle，Sparkle 会为此报错 ——
    /// 而那句报错跟「更新能不能用」无关，只会污染自检输出（真机自检有 6 个场景要读输出）。
    ///
    /// **调试构建也不建**（2026-09-23）：开发路径 `./run.sh` → `swift run SafeOutApp`
    /// 跑的是**裸可执行文件、不是 `.app`**（`.build/out/Products/Debug/` 里没有 `Info.plist`、
    /// 也没内嵌 `__info_plist` 段）⇒ `Bundle.main.bundleIdentifier` 是 `nil`，
    /// Sparkle 在 `checkIfConfiguredProperlyAndRequireFeedURL:` 里**直接 `return NO`**
    /// （`SUInvalidHostBundleIdentifierError`）。实测它**不会联网、不查 feed、不装任何东西**，
    /// 但每次启动都会记一条 error，并让「自动更新」那一行进入「不可用」——
    /// 而真因是「这是开发构建」，不是「更新坏了」。⇒ 开发期本来就不该检查更新，
    /// 干脆别去构造一个注定失败的 `SPUUpdater`。
    private func ensureUpdater() -> SPUUpdater? {
        if let updater { return updater }
        if startError != nil { return nil }

        if AppDelegate.isPreviewRun {
            startError = "预览模式（--preview-*）"
            return nil
        }

        // ⚠️ 放在 `isPreviewRun` **之后**：预览跑的也是 DEBUG 构建，
        // 先撞这里会让 `startError` 丢掉「预览模式」那个更有信息量的原因。
        if Self.isDebugBuild {
            startError = "调试构建不检查更新"
            return nil
        }

        let driver = UpdateUserDriver(controller: self)
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            // **不能是 `nil`**：下载失败这件事 Sparkle 同时走两条路 ——
            // user driver 的 `showUpdaterError` 和 delegate 的
            // `updater(_:failedToDownloadUpdate:error:)`。delegate 给 `nil` 就等于
            // 主动放弃后者，而它才是**文档上写明的**「下载失败」信号
            // （`SPUUpdaterDelegate`：「Called after the specified update failed to download」）。
            delegate: self)
        do {
            // ObjC 是 `- (BOOL)startUpdater:(NSError **)error`，Swift 侧被重命名成 `start()`。
            try updater.start()
        } catch {
            startError = error.localizedDescription
            Self.logger.error("Sparkle 启动失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.driver = driver
        self.updater = updater
        Self.logger.info(
            "Sparkle 已启动，feed: \(updater.feedURL?.absoluteString ?? "（Info.plist 未配置 SUFeedURL）", privacy: .public)")
        return updater
    }

    // MARK: - 用户动作

    /// 用户手动「检查更新」。
    ///
    /// updater 起不来时**退回打开 Releases 页**并记一条 error —— 不是静默什么都不做：
    /// 用户点了按钮却毫无反应，比跳到网页更让人困惑。
    ///
    /// ## ⚠️ 「会话进行中它会失效」这条代价 —— **实扫之后：没有入口，代价是 0**（2026-09-25，§8.146.1.1）
    ///
    /// `SPUUpdater.m:713` 明写：会话进行中再调 `checkForUpdates` 会**只打一条日志、
    /// 什么都不做**（`Error: -checkForUpdates called but .sessionInProgress == YES`）。
    /// 而本方法在调它**之前**会先把界面清成 `.idle` ⇒ 万一这条路在会话进行中被走到，
    /// 结果就是**谎报「已是最新版本」**（与本轮 Bug 1 同一句谎，只是入口不同）。
    ///
    /// 于是本轮**实扫了一遍全部入口**（`grep -rn "UpdateController.shared\." Sources/`）：
    ///
    /// | 入口 | 出现的行态 | 可能是会话进行中吗 |
    /// |---|---|---|
    /// | `checkForUpdatesButton`（设置行的「检查更新」） | `.neverChecked` / `.upToDate` / `.skipped` | **不可能** —— 那三态的 `phase` 都不是 `.found` / `.downloading` / `.ready` |
    /// | `retryDownload()`（`.failed` / `.installFailed` 那一行的「重试」） | `.failed` / `.installFailed` | **不可能** —— 那两态是终态，会话已经结束（§8.122） |
    /// | `presentFoundUpdate()` 的兜底（本文件内部） | 只在 `.found` 且 reply 残留时 | **不可能** —— 那种残留需要「清了 `pendingUpdate` 却不清 `alertReply`」，全仓没有这种写法 |
    ///
    /// ⚠️ **菜单栏那条路也不存在**：`MainMenu.swift` 里搜 `checkForUpdates` **零命中** ——
    /// 本应用的主菜单没有「检查更新」这一项（只有设置行里有）。
    ///
    /// ⇒ **本轮一度在这里加了一道 `if sessionInProgress` 闸门 + 两条守卫 + 两条变异**，
    /// 实扫之后**自己撤掉了**：那是一条**永远走不到**的分支，而本仓库对
    /// 「有定义、没消费者」的东西判得很重（§8.47.6：它在界面上与「已经支持了」长得一模一样）。
    /// 那份「没有入口」的阴性结论改由守卫钉住 —— 见
    /// `UpdateSettingsTests.检查更新只有那几个入口且都不在会话进行中`。
    ///
    /// ⚠️ **将来若给菜单栏补一个「检查更新」**：那条守卫会**变红**并告诉你该补什么。
    /// 要补的判据就是相位（`.found` / `.downloading` / `.ready` = 会话活着），
    /// **不是「那一格上有没有按钮」** —— 同一个动作往往还有菜单栏 / 快捷键几条路，
    /// 判据要落在**动作**上。
    func checkForUpdates() {
        // **先清跳过标记再检查**：用户手动点了这一下，意思就是「我不跳了，再看一眼」。
        // 不清的话 Sparkle 仍会按跳过记录把这个版本压住 —— 界面上的「已跳过 1.1.0」
        // 永远不消失，用户会以为检查更新坏了（设计稿 B5 那条 spec-note 明确要求可撤销）。
        clearSkippedVersion()
        // 上一轮的失败 / 发现态也要清掉，否则旧状态会盖住新一轮的结果。
        pendingUpdate = nil
        phase = .idle
        // 上一轮「用户点过后台更新并重启」的意图也随之作废 —— 不带上新一轮。
        userChoseInstallAndRestart = false

        guard let updater = ensureUpdater() else {
            Self.logger.error("检查更新不可用：\(self.startError ?? "未知原因", privacy: .public)")
            UpdateService.openUpdateSource()
            return
        }
        // ⚠️ **必须放在 `ensureUpdater()` 之后**：updater 起不来时上面已经 `return` 了，
        // 那一态会永远停在「正在检查…」，而它实际发生的事是「跳去下载页」。
        //
        // 真机实测（dist 产物，单时间轴 4 轮）这一段是 **4.31 / 3.15 / 4.51 秒**（§8.93）——
        // 不画出来，用户不知道自己那一下有没有生效；而且按钮在这几秒里**仍可反复点**
        // （`rowState` 仍是 `.upToDate`，「检查更新」还亮着）。
        phase = .checking
        updater.checkForUpdates()
    }

    /// 启动时发起一次静默检查的**防抖间隔**（秒）。
    ///
    /// ⚠️ 它是**具名常量**、不是内联字面量：这是一个产品决策（「打开应用就该看一眼有没有新版」
    /// 与「别把本地工具变成联网软件」之间的取舍点），改一个数就能调。
    ///
    /// **为什么是 5 分钟而不是 0**：没有防抖的话，同一秒内被拉起两次
    /// （`open -a` 与登录项同时触发、或调试期反复重启）会打出两个并发的 feed 请求，
    /// 而其中一次必然撞上 Sparkle 的 `sessionInProgress` 被静默拒掉 —— 那是噪声，不是功能。
    /// 5 分钟短到用户永远感知不到（他不可能在 5 分钟内「第一次打开」两次）。
    nonisolated static let launchCheckDebounce: TimeInterval = 300

    /// 启动的这一刻**该不该主动查一次**（纯函数，可逐条断言）。
    ///
    /// ## 为什么需要它（2026-09-28，用户报告的缺陷）
    ///
    /// 此前启动路径**只建 updater、不发起检查**，排期完全交给 Sparkle；
    /// 而 Sparkle `start()` 之后算的是 `now − lastUpdateCheckDate`，**小于
    /// `SUScheduledCheckInterval` 就只排一个未来的定时器**（`SPUUpdater.m:552-589`）。
    /// 于是实测出来的现象是：10:03 查过一次、14:46 重新打开应用
    /// （间隔 4.7h < 24h）⇒ **本次启动零网络请求**，设置行照旧显示 4.7 小时前的结论
    /// 「上次检查：今天 10:03 · 已是最新版本」—— 而 13:22 已经发布了新版本。
    ///
    /// 更糟的是那个定时器排到**明天**：应用要是没活到那一刻（菜单栏工具被用户关掉、
    /// 或机器睡了），它就**永远不 fire**。⇒ 用户「打开应用」这个动作**不会**带来检查，
    /// 而这与所有人对「打开应用」的心智模型都相反。
    ///
    /// ## 判据
    ///
    /// - **自动检查关着** ⇒ 不查。用户明确关掉了它，启动时偷偷查一次是**违背偏好**，
    ///   而且会让那个开关看起来是坏的。
    /// - **从没查过** ⇒ 查。
    /// - **时间戳在未来**（时钟回拨 / 被手改）⇒ 查。**这种值不能当「刚查过」用** ——
    ///   拿它算差值会得到一个负数而永久静默（同 `SPUUpdater.m:558-563` 对同一件事的处理）。
    /// - 其余按 ``launchCheckDebounce`` 分叉。
    nonisolated static func shouldCheckOnLaunch(
        lastCheck: Date?, automaticallyChecks: Bool, now: Date, debounce: TimeInterval
    ) -> Bool {
        guard automaticallyChecks else { return false }
        guard let lastCheck else { return true }
        guard lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= debounce
    }

    /// 启动后的静默检查。
    ///
    /// ## ⚠️ 2026-09-28 改了行为：启动**现在真的会查**，但发起点不在这里
    ///
    /// 原注释写的是「这里**不额外调用** `checkForUpdatesInBackground()` ——
    /// 那样每次启动都打一次网络请求，而『启动就联网』正是本应用不该有的行为」。
    /// 那句话在**没有别的启动检查**时等于「启动永远不检查」：Sparkle 只在
    /// 「距上次 ≥ `SUScheduledCheckInterval`」时才立刻查（`SPUUpdater.m:573-589`），
    /// 否则**只排一个未来定时器**；应用没活到那一刻它就永远不 fire。
    /// 实测后果见 ``shouldCheckOnLaunch(lastCheck:automaticallyChecks:now:debounce:)``。
    ///
    /// 取舍变了，理由三条（都是实测 / 代码事实，不是感觉）：
    ///
    /// 1. **成本被高估了**：一次 appcast 请求 3.3 KB，且被 ``launchCheckDebounce``
    ///    与「自动更新开关」双重收口。
    /// 2. **Sparkle 自己排的那次不可靠**：定时器要应用活到那一刻才 fire。
    /// 3. **「不打扰」由别处保证**：自动下载关着时才弹窗，开着时完全静默 ——
    ///    这是设计稿 A 段写死的判据（见 `UpdateUserDriver` 的说明），不是靠「不查」实现的。
    ///
    /// ## ⚠️ 为什么检查**不能**在这里直接发起（2026-09-28 读 Sparkle 源码发现）
    ///
    /// 一开始就是写成「`ensureUpdater()` 之后直接 `updater.checkForUpdatesInBackground()`」的，
    /// 而**那会被静默丢掉**：`start()` 末尾会走一次排期，那条路在**同步**设好
    /// `sessionInProgress = YES`（`SPUUpdater.m:542-543`）之后才去**异步**探测安装器
    /// （`SPUProbeInstallStatus` 走 XPC + `dispatch_async`）。于是在 `start()` 返回后
    /// 紧接着调它，命中的是头文件那句「This method does not do anything if there is a
    /// `sessionInProgress`」（`SPUUpdater.m:664-667` **只打一条 error 日志**）。
    /// ⇒ 界面上一切照旧，而「启动检查」四个字从未生效 —— 正是本仓库最忌的
    /// 「有定义、没消费者」。
    ///
    /// ⇒ 真正的发起点挪到 ``updater(_:willScheduleUpdateCheckAfterDelay:)``：那个回调
    /// 到达时 Sparkle **已经把会话让出来了**，而且它正好在说「我准备等 N 秒」——
    /// 那就是我们要覆盖的那个决定。见那条的说明。
    func startIfNeeded() {
        _ = ensureUpdater()
    }

    /// 「查看更新」：把弹窗重新拉起来（用户按过 Esc 之后）。
    ///
    /// 没有待展示的内容时退回一次普通检查 —— **不能什么都不做**：
    /// 按钮点了没反应，与功能坏了长得一模一样。
    ///
    /// ⚠️ **判据里必须有 `phase == .found`**（2026-09-25）：`pendingUpdate` / `alertReply`
    /// 只要有一处残留（例如会话被别的原因拆掉之后），重弹的就是一个**已经 abort 的会话** ——
    /// 用户点了「后台更新并重启」，`reply` 送进一个死会话，界面上**什么都不发生**
    /// （设计稿点名不许的死按钮）。判据不成立时退回 ``checkForUpdates()``：
    /// 那会开一个**新的**会话，与「查看更新」的用户意图一致。
    ///
    /// ⚠️ **这里不会与 ``checkForUpdates()`` 递归**：后者只在 `alertReply != nil` 时才
    /// 回头调本方法，而那个条件恰好让本方法的 guard **成立**（`alertReply` 只与
    /// `phase = .found` 同时设置）⇒ 两支互斥。
    func presentFoundUpdate() {
        guard case .found = phase, pendingUpdate != nil, alertReply != nil else {
            checkForUpdates()
            return
        }
        Task { await showUpdateAlertIfNeeded() }
    }

    /// 「立即重启」：把控制交回 Sparkle 让它**现在就装**，装完重新拉起应用。
    ///
    /// 两条路共用这一处（见 ``readyReply``）：弹窗那条回答 `.install`，
    /// 自动那条调用 `immediateInstallationBlock`。**回答之前先清空**，
    /// 否则第二次点会重复回答同一个 reply。
    func installReadyUpdate() {
        guard let reply = readyReply else { return }
        readyReply = nil
        // 回答之后这个意图就用掉了 —— 留着它会让**下一轮**（例如自动那条路的
        // `willInstallUpdateOnQuit`）误以为用户点过「后台更新并重启」。
        userChoseInstallAndRestart = false
        reply(.install)
    }

    /// 「取消」：中断正在进行的下载。
    func cancelDownload() {
        downloadCancellation?()
        downloadCancellation = nil
        phase = .idle
    }

    /// 「重试」：重新走一次检查（失败多半是网络，重来一次最直接）。
    func retryDownload() {
        checkForUpdates()
    }

    // MARK: - 设置项（设置面板「自动更新」开关绑这两个）

    /// Sparkle 的设置读写口。
    ///
    /// 用 `SPUUpdaterSettings` 而不是 `updater.automaticallyChecksForUpdates`：
    /// 前者**不需要先把 updater 跑起来**就能读写（两者用的是同一份 UserDefaults），
    /// 于是「用户没点过检查更新就先去设置里开开关」这条路也成立。
    private var settings: SPUUpdaterSettings { SPUUpdaterSettings(hostBundle: Bundle.main) }

    /// 是否自动检查更新。
    var automaticallyChecksForUpdates: Bool {
        get { settings.automaticallyChecksForUpdates }
        set { settings.automaticallyChecksForUpdates = newValue }
    }

    /// 宿主是否**具备**自动更新的能力（设置面板「自动更新」那一行的禁用条件）。
    ///
    /// ⚠️ **判据不看开关当前值**（2026-09-21 真机修的 bug，§8.113.14）：
    /// 这一行此前读 Sparkle 的 `allowsAutomaticUpdates`，而它算的是
    /// `SUAllowsAutomaticUpdates ?? automaticallyChecksForUpdates`
    /// （见下面 `allowsAutomaticUpdates` 那条 2026-09-19 的订正）；本应用
    /// **没写 `SUAllowsAutomaticUpdates`** ⇒ 它**恒等于这个开关自己的值**
    /// ⇒ 用户把开关关掉 ⇒ 那一行的 `onTap` 变 `nil` ⇒ **再也打不开**
    /// （真机实测：重启也救不回来，`SUEnableAutomaticChecks = 0` 已写进 UserDefaults）。
    ///
    /// ⇒ 判据改成**只看 updater 建没建起来**：预览模式 / 构建不合规时建不起来
    /// （见 `ensureUpdater()`），与用户把开关拨到哪一边**无关**。
    var canAutoUpdate: Bool { updater != nil }

    /// 是否自动下载更新。
    ///
    /// 与设计稿那句「有新版本时自动下载，并在下次启动时安装」是同一件事。
    ///
    /// ⚠️ **2026-09-19 订正**：这里原来写的是「`SUAutomaticallyUpdate` 保持默认的 `NO`
    /// （不静默强装），于是 Sparkle 只后台下载、等应用退出时再装」—— **反了**。
    /// 实测（把开关置 `true`／`false` 各跑一遍，见 `DESIGN-SPEC.md` §8.79）：
    ///
    /// - `SUAutomaticallyUpdate = NO`（**默认**）⇒ 发现新版本时**弹窗**（不自动下载）。
    /// - `SUAutomaticallyUpdate = YES` ⇒ 后台静默下载，全程没有界面。
    ///
    /// 依据是 Sparkle 源码而不是文档措辞：`SPUUpdaterSettings.m:327` 把它算成
    /// `_allowsAutomaticUpdates && [_host boolForKey:SUAutomaticallyUpdateKey]`，
    /// 而 `SPUUpdater.m:622` 只在它为真时才选 `SPUAutomaticUpdateDriver`（静默下载那条），
    /// 否则走 `SPUScheduledUpdateDriver` → `SPUUIBasedUpdateDriver` → 弹窗。
    ///
    /// 「等应用退出时再装」这一半**两种设置下都成立**（同样 §8.79 实测：
    /// `.18.4/81` 退出后变成 `.19.1/119`）—— 因为它是**安装器工具自己**在
    /// `AppInstaller.m:392-412` 里盯着目标进程退出后接着装，
    /// 与应用回不回答 `showReady` 的 reply 无关。
    var automaticallyDownloadsUpdates: Bool {
        get { settings.automaticallyDownloadsUpdates }
        set { settings.automaticallyDownloadsUpdates = newValue }
    }

    /// 宿主是否**允许**自动更新（为 `false` 时开关应当禁用）。
    ///
    /// ⚠️ **2026-09-19 订正**：这里原来写的是「未正确签名时为 `false`」—— **没有这回事**。
    /// `SPUUpdaterSettings.m:314-317` 算的是
    /// `allowsAutomaticUpdatesOption ?? automaticallyChecksForUpdates`，而前者读的是
    /// Info.plist 里的 `SUAllowsAutomaticUpdates`（`SPUUpdaterSettings.h:54` 也这么写）。
    /// **与代码签名、与卷的读写权限都无关**（在 Sparkle 2.10.0 里搜不到任何这类判断）。
    ///
    /// 对本应用来说 `SUAllowsAutomaticUpdates` 没写 ⇒ 这一项**恒等于
    /// `automaticallyChecksForUpdates`**，也就是「自动检查」开着时它必然为真。
    /// 保留这个计算属性仍然有意义：它是**设计稿 B 段那个开关的禁用条件**，
    /// 而「设了没生效」和「功能坏了」在界面上不能长得一样（判据同登录项第三态）。
    var allowsAutomaticUpdates: Bool { settings.allowsAutomaticUpdates }

    /// 上次检查的时间（设置行里显示「上次检查：…」用；未启动时为 `nil`）。
    var lastUpdateCheckDate: Date? { updater?.lastUpdateCheckDate }

    // MARK: - 「检查更新」这一行显示什么

    /// 最近一次更新检查**到底怎么样了**。
    ///
    /// ## 为什么它必须存在（2026-09-28，用户报告）
    ///
    /// ``CheckRowState/upToDate(_:)`` 的文案是「上次检查：%@ · **已是最新版本**」——
    /// 一句**断言**。而它此前的判据只有「`phase == .idle` 且 `lastUpdateCheckDate != nil`」，
    /// 于是**两个相反的事实**被渲染成同一句话：
    ///
    /// | 真实发生的事 | Sparkle 回调 | 此前显示 |
    /// |---|---|---|
    /// | 查到了，没有可用更新 | `showUpdateNotFoundWithError`（`SUNoUpdateError`） | 已是最新版本 |
    /// | **根本没查成**（feed 拿不到 / 超时 / 验签不过） | `showUpdaterError` | 已是最新版本 |
    ///
    /// ⚠️ 而 `SULastCheckTime` 是 Sparkle 在**发起**检查时就写的
    /// （`SPUUpdater.m:789`，在任何网络请求之前），所以**失败也会把「上次检查」刷成当下**
    /// ⇒ 用户看到的是「刚刚查过、是最新版」，而真相可能是「刚刚试过、没连上」。
    /// 2026-09-28 用户报告里那条「上次检查：今天 10:03 · 已是最新版本」就是这么一次
    /// **无法分辨的读数**：当时线上 appcast 是 build 277、盘上是 273，一次真的查成的检查
    /// **不可能**得出「已是最新版本」。**维护者本人也分不清发生了什么** —— 这就是缺陷本身。
    ///
    /// ⇒ 把这个结论**单独记下来并落盘**，视图才有东西可区分（见 ``lastCheckOutcome``）。
    ///
    /// ⚠️ **它是「检查」的结论，不是「更新流程」的结论**：下载失败 / 安装失败都说明
    /// **检查是成功的**（否则不会有包可下）—— 那两件事另有落点（`.failed` / `.installFailed`），
    /// **不许**拿它们去把这里改成 `.failed`。
    enum CheckOutcome: String {
        /// Sparkle 明确回了「没有可用更新」（`SUNoUpdateError`）。
        case succeeded
        /// 检查**没能完成** —— feed 取不到 / 超时 / 验签不过 / 配置错误。
        case failed
    }

    /// 设置面板「检查更新」行的状态。
    ///
    /// **抽成枚举而不是在视图里拼字符串**：视图拼字符串就没法断言 ——
    /// 测试只能去比「上次检查：今天 14:30」这种**本地化 + 日期格式**双重依赖的文本，
    /// 换台机器或换个语言必红，而红的原因与被测代码无关
    /// （2026-09-17 CI 连续 6 次红就是这个病根）。枚举可以逐态断言，视图只负责翻译。
    ///
    /// 七个分支与设计稿 C 段那张九行矩阵一一对应（「尚未检查 / 已是最新」两行共用
    /// `lastCheck` 的有无；「稍后」不单独成态 —— 它就是留在 `found` 上）。
    enum CheckRowState: Equatable {
        /// 从未检查过。
        case neverChecked
        /// 检查过，已是最新。
        case upToDate(Date)
        /// **检查没能完成**（feed 拿不到 / 超时 / 验签不过），带着上次尝试的时间。
        ///
        /// ⚠️ **它与 ``upToDate(_:)`` 是两件相反的事，不许合并**（2026-09-28 用户报告）：
        /// 前者是「查到了，没有新版」，后者是「**根本没查成**」。
        /// 合并的后果是界面**谎报** —— 而这条谎在真机上会持续存在，不是一闪而过：
        /// 本机实测取 appcast **12.0 秒**（HTTP 200），慢到踩 Sparkle 超时不是理论风险。
        ///
        /// 判据见 ``UpdateController/lastCheckOutcome``；文案**必须带「检查失败」字样**，
        /// 且**不得**出现「已是最新版本」——否则就是本轮在修的那句谎换个地方重来。
        case checkFailed(Date)
        /// 用户点过「跳过此版本」，记着跳的是哪一版。
        case skipped(version: String)
        /// 正在检查（用户刚点了「检查更新」，Sparkle 还没回话）。
        ///
        /// ⚠️ **这一态不给按钮**：此刻点「检查更新」是没用的（Sparkle 正跑着），
        /// 给一个点了没反应的按钮，与「功能坏了」长得一模一样（同 `.ready` 那条判据）。
        case checking
        /// 发现了新版本，等用户决定。
        case found(version: String, lastCheck: Date?)
        /// 正在后台下载。`fraction` 为 `nil` = 百分比无从得知（见 ``UpdatePhase/downloading(version:fraction:)``）。
        case downloading(version: String, fraction: Double?)
        /// 已下载完成，等重启安装。
        ///
        /// `autoRestart` = **这一轮会自己重启**（用户点过「后台更新并重启」）。
        /// 两条路各自的那句话不一样，理由见 ``UpdatePhase/ready(version:autoRestart:)``。
        case ready(version: String, autoRestart: Bool)
        /// 下载失败。
        case failed(version: String)
        /// **下载成功了，但之后那一步失败**（解压 / 验签 / 安装），见 ``UpdatePhase/installFailed(version:)``。
        ///
        /// ⚠️ 文案**不许提网络** —— 下载是成功的，用户会照着「网络不可用」去查网络。
        case installFailed(version: String)
        /// **应用当前所在的位置不允许更新**（只读卷 / App Translocation，见 ``UpdatePhase/locationBlocked``）。
        ///
        /// ⚠️ **也不给按钮**：我们没法替用户把 `.app` 搬进「应用程序」文件夹 ——
        /// 而给「重试」在只读卷上**必然再失败**（Sparkle 连 appcast 都不会去取）。
        case locationBlocked
    }

    /// 用户点过「跳过此版本」的那个版本号（没跳过时为 `nil`）。
    ///
    /// **是版本号而不是布尔**：布尔记不住「跳过的是哪一版」，下个版本发布后
    /// 那个布尔还是 `true`，用户会被**永久静音**（他以为只是跳过了 1.1.0）。
    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: AppSettings.Key.skippedVersion) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: AppSettings.Key.skippedVersion)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.Key.skippedVersion)
            }
        }
    }

    /// 最近一次检查**给出过的明确结论**（`nil` = 还没有过结论），读写 `UserDefaults`。
    ///
    /// ⚠️ **必须落盘**：`phase` 只活在内存里，进程一退就没了；而「上次检查到底成没成」
    /// 是一条要在**重启之后仍然为真**的事实。不落盘的话，
    /// 应用一重启，「检查失败」就变回「已是最新版本」—— **那句谎会随重启复活**，
    /// 而它恰恰是最需要被看见的一次（用户是被那句谎引到设置面板来的）。
    ///
    /// ⚠️ **不放在 `AppSettings` 的偏好区当「设置项」**：它不是用户的偏好，
    /// 是运行结果（同类：`hasShownFDAOnboarding` 也是一种结果标记）。
    /// 键仍然集中在 `AppSettings.Key` 里声明，避免字面量散落。
    var lastCheckOutcome: CheckOutcome? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: AppSettings.Key.lastCheckOutcome)
            else { return nil }
            // 读到不认识的值（降级 / 手改）⇒ 当「没有结论」，不去猜。
            return CheckOutcome(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(
                    newValue.rawValue, forKey: AppSettings.Key.lastCheckOutcome)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.Key.lastCheckOutcome)
            }
        }
    }

    /// 当前该显示哪一态。
    var rowState: CheckRowState {
        Self.rowState(
            phase: phase, skippedVersion: skippedVersion, lastCheck: lastUpdateCheckDate,
            outcome: lastCheckOutcome)
    }

    /// 状态的判定逻辑（**纯函数**，与 `UserDefaults` / Sparkle 无关）。
    ///
    /// **为什么要抽出来**：判定里最关键的是**优先级**，而真实环境里很难构造出
    /// 「两个条件同时成立」（`lastUpdateCheckDate` 来自 Sparkle，测试里造不出来）。
    /// 留在计算属性里就只能测到「跳过标记生效了没有」，测不到顺序。
    ///
    /// **顺序有语义**：
    /// 1. 进行中 / 受阻的六态（检查 / 下载 / 就绪 / 失败 / 位置受限 / 发现）**盖过**其它一切 ——
    ///    否则用户会看到「已跳过 1.1.0」的同时有个下载进度条在跑，
    ///    或者「已是最新版本」把「这个位置不让更新」盖掉。
    /// 2. 跳过态**盖过**「已是最新」—— 用户跳过 1.1.0 之后界面上必须留着那条痕迹，
    ///    否则他无法分辨「跳过生效了」和「检查更新坏了」
    ///    （与登录项「等待系统批准」同一类判据：**第三态不画就等于没有**）。
    /// 3. 「已是最新」/「检查失败」盖过「尚未检查」—— 前两者的区别只有 `lastCheck` 的有无，
    ///    而这正是设计稿点名要分开的两行（`已是最新版本` vs `尚未检查`）。
    /// 4. 最后那一层由 ``outcome`` 分叉：「已是最新版本」是一句**断言**，
    ///    只有明确收到过 `SUNoUpdateError` 才敢说（见 ``CheckOutcome``）。
    ///
    /// ⚠️ **`outcome` 有默认值**：`nil` = 「还没有任何一次检查给出过明确结论」，
    /// 此时退回旧口径（说「已是最新版本」）。这是**移民兼容**，不是「无所谓」——
    /// 老用户的 UserDefaults 里没有这个键，而他们的 `SULastCheckTime` 已经有了；
    /// 不给默认值的话，所有老用户升级后第一眼看到的会是「检查失败」，
    /// 而那时我们**并不知道**上一次到底怎么样。（下一次检查到达时会立刻纠正。）
    ///
    /// ⚠️ **`nonisolated`**：它是纯函数（只看四个入参），不该被 `@MainActor` 绑住。
    /// 不标的话，测试里从非主 actor 上下文调它要 `await` —— 一个纯逻辑却要异步，
    /// 会让人误以为它碰了运行时。
    nonisolated static func rowState(
        phase: UpdatePhase, skippedVersion: String?, lastCheck: Date?,
        outcome: CheckOutcome? = nil
    ) -> CheckRowState {
        switch phase {
        case .checking:
            return .checking
        case .downloading(let version, let fraction):
            return .downloading(version: version, fraction: fraction)
        case .ready(let version, let autoRestart):
            return .ready(version: version, autoRestart: autoRestart)
        case .failed(let version):
            return .failed(version: version)
        case .installFailed(let version):
            return .installFailed(version: version)
        case .locationBlocked:
            return .locationBlocked
        case .found(let version):
            return .found(version: version, lastCheck: lastCheck)
        case .idle:
            break
        }
        if let skippedVersion { return .skipped(version: skippedVersion) }
        if let lastCheck {
            // 「已是最新版本」是一句**断言**：只有明确收到过 `SUNoUpdateError` 才敢说。
            // 其余（失败 / 还没有结论）一律不许替用户下这个结论（见 ``CheckOutcome``）。
            return outcome == .failed ? .checkFailed(lastCheck) : .upToDate(lastCheck)
        }
        return .neverChecked
    }

    /// **这一轮更新检查到底拿到了答案没有**（纯函数，可逐条断言）。
    ///
    /// ## 为什么它挂在 `didFinishUpdateCycleForUpdateCheck:error:` 上
    ///
    /// 2026-09-28 **真机实测发现的漏洞**：本轮的结论原先只由 user driver 的两个回调
    /// 设置（`showUpdateNotFoundWithError` / `showUpdaterError` 的兜底支），
    /// 而**后台 / 启动检查失败时那两个回调一个都不会到** ——
    /// `SPUScheduledUpdateDriver.m:106` 传给 UI 层的是
    /// `abortUpdateWithError:error showErrorToUser:_showedUpdate`，
    /// 而 `_showedUpdate` 只在**已经展示过更新**之后才为真
    /// （`:70-72` 的 `uiDriverDidShowUpdate`）。对照 `SPUUserInitiatedUpdateDriver.m:146`
    /// 写死的 `showErrorToUser:YES` ⇒ **只有「用户点的检查」失败才会弹错误**。
    ///
    /// 真机复现（`.workbuddy/verify/updcheck/`，2026-09-28）：把 feed 指到一个关掉的
    /// 本地端口，应用启动检查取 appcast **真的失败**（`kCFErrorDomainCFNetwork -1004`），
    /// 而设置行的结论**一动不动** —— 界面于是继续沿用上一次的读数，
    /// 也就是用户报的那句「已是最新版本」。
    ///
    /// ⇒ 换到 `SPUUpdater.m:810` 那个 delegate 回调：它由
    /// `notifyDelegateOfDriverCompletion` 在**每一轮**收尾时发，与 user driver 无关，
    /// 也与「有没有弹过 UI」无关（`SPUUpdater.m:800-812`）。
    ///
    /// ## 判据（三步，命中即停）
    ///
    /// 1. **已经落到下载 / 安装的终态** ⇒ 检查**必定成功**：appcast 取到了、
    ///    也判出了有新版本（否则不会有包可下）。
    ///    ⚠️ ``UpdatePhase/locationBlocked`` **不算** —— 只读卷上 Sparkle 连 appcast
    ///    都不去取（`SPUBasicUpdateDriver.m:71`），那时说「检查成功」是**又一句谎**。
    /// 2. **没有错误** ⇒ 正常结束（发现了更新、或用户关掉了弹窗，文档写明
    ///    「dismissed or skipped … is the same as no error」）。
    /// 3. **三个「不是错」的码** ⇒ 成功。这一组**照抄 Sparkle 自己**
    ///    （`SPUUpdater.m:797-807` 明确不把它们当错误记录/上报）：
    ///    `SUNoUpdateError(1001)` 没有新版本、`SUInstallationCanceledError(4007)`
    ///    用户在授权时取消、`SUInstallationAuthorizeLaterError(4008)` 用户选了稍后。
    ///    其余一律 **失败**。
    ///
    /// ⚠️ **必须带域判定**：`1001` 这种码在别的域里可能有别的含义
    /// （同 ``isUpdateLocationBlocked(_:)`` 的理由）。真实的网络失败是
    /// `NSURLErrorDomain -1004` 之类 ⇒ 域不对 ⇒ 落第三步的 `default` ⇒ 失败。
    nonisolated static func checkOutcome(
        error: (any Error)?, phase: UpdatePhase
    ) -> CheckOutcome {
        switch phase {
        case .failed, .installFailed:
            return .succeeded
        default:
            break
        }
        guard let error else { return .succeeded }
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else { return .failed }
        switch nsError.code {
        case 1001,  // SUNoUpdateError —— 查到了，没有可用更新
            4007,  // SUInstallationCanceledError
            4008:  // SUInstallationAuthorizeLaterError
            return .succeeded
        default:
            return .failed
        }
    }

    /// 下载进度是否值得发一次通知。
    ///
    /// **不是优化，是必需品**：`showDownloadDidReceiveData` 是**按数据块**回调的，
    /// 一个大 dmg 能回调上千次；每次都写 `@Published` 会让设置面板每秒重绘几十次。
    /// 而界面上显示的只是整数百分比 —— 只有整数位变了，画面才真的会变。
    ///
    /// 抽成纯函数是为了能断言它（「42.1% → 42.9% 不该发」这种边界，
    /// 在真机上根本构造不出来）。
    ///
    /// `old` 为 `nil`（上一格还不知道百分比）时**一定发**：那正是「第一次拿到进度」这一刻，
    /// 同时是「进度条该出现了」这一刻 —— 不发的话进度条永远不出现（自动更新那条路
    /// 进来时就是 `nil`，见 §8.81）。
    nonisolated static func shouldPublishProgress(from old: Double?, to new: Double) -> Bool {
        guard let old else { return true }
        return Int(old * 100) != Int(new * 100)
    }

    /// 这次报错该不该算成「下载失败」。
    ///
    /// **判据取自我们自己的状态**（是不是正在下载），不新增一个「这一错是不是下载错」的位 ——
    /// 能派生就别用「手动开关」（同 §「能派生就别用『手动开关』」）。
    ///
    /// ⚠️ **2026-09-22 加了 `error` 这个入参**（账本第 43 行）：只有「正在下载」还不够 ——
    /// 下载成功之后（解压 / 验签 / 安装）的失败也发生在 `.downloading` 期间，
    /// 判成「下载失败」就会写出「网络不可用」这种谎话。⇒ 先排除
    /// ``isPostDownloadFailure(_:)``，剩下的才算下载失败。
    ///
    /// ⚠️ **为什么是「排除安装类」而不是「只认下载段（2000..<3000）」**（与任务书口径的一处偏离，
    /// 理由必须留着）：只认下载段的话，**不认识的域**（例如某个非 `SUSparkleErrorDomain` 的
    /// 网络错误）与 **3000 段**（解压 / 验签 / 校验）都会掉进 `showUpdaterError` 的 **else**
    /// ⇒ `driverDidReset()` ⇒ `.idle` ⇒ **又一次无声消失** —— 那正是前两轮刚修掉的病
    /// （§8.121 + QA 2026-09-22 复验）。
    /// ⇒ 无法分类时**宁可给一个可操作的失败态**（`.failed` + 「重试」），也不静默消失：
    /// 文案不够精确，比「什么都没发生」轻得多。
    /// （真机侧的风险是有限的：`SPUDownloadDriver.m:100` / `:264` 把下载错误**统一包成**
    /// `SUSparkleErrorDomain` + `SUDownloadError(2001)`，所以真实下载失败总是能落到这一支。）
    ///
    /// **为什么抽成纯函数**：真实环境里「下载中报错」**构造不出来**（要真的下载、且真的失败），
    /// 而它正是 `.failed` 那一态的来源。留成驱动里一句 `if case` 的话，
    /// 「分支写反了」或「被删掉了」都不会有任何断言变红
    /// —— 2026-09-18 实扫发现 `driverDidFailDownload` 当时**全仓库没有调用点**，就是这么发生的。
    ///
    /// ⚠️ **它同时是「两条路」的去重闸门**（§8.113，关掉 SPEC 第 10 行）：
    /// 下载失败这件事 Sparkle 会**同时**走两条路 —— delegate 的
    /// `updater:failedToDownloadUpdate:error:`（`SPUCoreBasedUpdateDriver.m:273`）与
    /// user driver 的 `showUpdaterError`（`SPUUIBasedUpdateDriver.m:485`，由 `:276` 的 abort 触发）。
    /// **delegate 先到**（`:273` 在 `:276` 之前）并把 `phase` 设成 `.failed`；
    /// 等第二条路进门时 `phase` 已经不是 `.downloading` ⇒ 这里返回 false ⇒ **不会第二次写**。
    /// ⇒ 两条路是**互为兜底**，不是叠加。
    ///
    /// ⚠️ **2026-09-22 订正（§8.121）**：上面只说了「不会第二次写」这一半，**另一半是错的** ——
    /// 后到的那条**没有停在这里**，它掉进 `showUpdaterError` 的 **else** 分支 ⇒
    /// `driverDidReset()` ⇒ 把 `.failed` 冲回 `.idle`。「互为兜底」是靠
    /// ``isTerminalPhase(_:)`` 才真正成立的（终态不动），**不是**这个闸门自带的。
    /// （自动那条路是例外：`SPUAutomaticUpdateDriver.m:146-152` 只调 `_coreDriver abort…`、
    /// **不调** `showUpdaterError` ⇒ delegate 是它唯一的一条。）
    ///
    /// ⚠️ **别把它改成「`.failed` 也算」**：那会让两条路互相覆盖 —— 第二条路拿
    /// `pendingUpdate?.version` 再写一次，而这个值为 nil 时会把已知版本号冲成 `"?"`。
    nonisolated static func isDownloadFailure(phase: UpdatePhase, error: Error) -> Bool {
        guard case .downloading = phase else { return false }
        // 「正在下载」+「不是下载之后那一步的错」⇒ 下载失败。
        // 反过来写（`error` 必须落在 2000 段）会把无法分类的错误送进 else ⇒ 无声消失（见上面）。
        return !Self.isPostDownloadFailure(error)
    }

    /// 这个错误是不是「**下载已经成功、但之后那一步失败了**」—— 解压 / 验签 / 安装。
    ///
    /// ## 码的分段（`SUErrors.h` 逐行对过，不是转述）
    ///
    /// | 段 | 码 | 含义 |
    /// |---|---|---|
    /// | 1000 | `SUAppcastParseError` … `SUReleaseNotesError`（`:40-47`） | 取 feed 阶段 |
    /// | **2000** | `SUTemporaryDirectoryError=2000`、`SUDownloadError=2001`（`:50-51`） | **下载阶段** |
    /// | **3000** | `SUUnarchivingError=3000`、`SUSignatureError=3001`、`SUValidationError=3002`（`:54-56`） | **解压 / 验签** |
    /// | **4000** | `SUFileCopyFailure=4000` … `SUInstallationWriteNoPermissionError=4012`（`:59-71`） | **安装阶段** |
    /// | 5000 | `SUIncorrectAPIUsageError`（`:73`） | 我们用错 API |
    ///
    /// ⇒ **3000 与 4000 两段的共同点是「下载已经完了」** ⇒ 界面都不许说「网络不可用」。
    ///
    /// ⚠️ **为什么把 3000 段也算进来**（比任务书给的「4000 段」多一段）：
    /// 解压 / 验签失败时说「下载失败 / 网络不可用」同样是句谎，而且它在分段上
    /// 属于「下载之后」；只认 4000 段的话 3000 段会掉进 else ⇒ 无声消失（同上一条理由）。
    /// 文案上两者也共用一句真话：**「已下载，但没能装上」** —— 验签没过，确实也没装上。
    /// ℹ️ 表里那个 `SUSignatureError=3001` 其实是**死码**（下面 2026-09-22 那节有证据）：
    /// 真正的验签失败是 `3002`，而且到达我们时已经被 Sparkle 换成了 4005。
    ///
    /// ## 域不对时怎么办（**不要假设它一定是 `SUSparkleErrorDomain`**）
    ///
    /// 域不是 `SUSparkleErrorDomain` ⇒ 一概**不算**这一类（返回 `false`）。理由：
    /// 码的分段只在那个域里成立，拿别的域的码去套 3000/4000 是在**猜**；
    /// 而猜错的代价是「安装失败被写成下载失败」（或反过来）—— 谎话。
    /// ⇒ 无法分类的错误走 ``isDownloadFailure(phase:error:)`` 那半边（若当时在下载）
    /// 或 else，都不会被本函数截走。
    ///
    /// **为什么抽成纯函数**：与 ``isDownloadFailure(phase:error:)`` /
    /// ``isUpdateLocationBlocked(_:)`` 同一个理由 —— 「真的下载成功、真的安装失败」
    /// 在测试进程里**构造不出来**（QA 是在**用户触发**那条路上撞到安装阶段失败的：
    /// 真签名 dmg + 码 `4005`，2026-09-22。⚠️ 别把它归给「本环境安装器起不来」——
    /// §8.125 实测已推翻那个归因：安装器在本机能跑，不需要 Developer ID）。
    /// ⚠️ 单测一律用**字面量**（`3000` / `4005` + 域字符串），别引这里的符号 ——
    /// 同 ``isUpdateLocationBlocked(_:)`` 那条规矩：两边同源就成了「拿常量跟自己比」。
    ///
    /// ## 2026-09-22 追查：3000 段里**哪些码真能到达这里**（源码级，逐行对过）
    ///
    /// QA 造「只翻一个字节、长度不变」的 dmg 去撞验签失败，拿到的码**仍是 4005**。
    /// 当时只记为「本环境撞不到」。追下去之后结论比那句更强 ——
    /// **是结构性到不了（指 3000 段只能由安装器产出；但 §8.125 证明安装器在本机能跑，
    /// 所以这不是撞不到）**：
    ///
    /// 1. **传递链中途不换码**：`_reportInstallerError`（`SPUInstallerDriver.m:148`）→
    ///    `installerIsRequestingAbortInstallWithError:`（`SPUCoreBasedUpdateDriver.m:353`）→
    ///    `coreDriverIsRequestingAbortUpdateWithError:`（`SPUUIBasedUpdateDriver.m:446`）→
    ///    `showUpdaterError:`（`:485`，传的是**同一个** error 对象）⇒ 我们读到的 `code`
    ///    就是 `SPUInstallerDriver` 最后构造的那个，中途没人再包一层。
    /// 2. **`3001`（`SUSignatureError`）全仓没有生产者** —— 只在枚举声明处出现过一次
    ///    （`SUErrors.h:55`；阳性对照：同一个 grep 里 `3002` 在 `SUUpdateValidator.m`
    ///    出现 12 次，说明扫描真的跑了）⇒ 它是**死码**，永远不会有错误带这个码。
    /// 3. **`3002`（`SUValidationError`）到不了顶层**：由 `SUUpdateValidator.m` /
    ///    `Autoupdate/SUSignatureVerifier.m` 抛，而 validator 只在**安装器进程**里被实例化
    ///    （`Autoupdate/AppInstaller.m:268`，调用点 `:284` / `:291` / `:310`）；安装器把它
    ///    塞进 `NSUnderlyingErrorKey`（`AppInstaller.m:313`），App 侧 `SPUInstallerDriver.m:98`
    ///    一旦命中 ⇒ `:104` **换成 4005**（文案「The update is improperly signed…」）。
    ///    ⇒ **验签 / 校验失败在界面上就是 4005**，而 4005 正是 QA 真机实测通过的那一条。
    ///
    /// ⇒ 3000 段里**唯一可能成为顶层码的是 `3000`（解压）**，而且路径只有一条：
    /// 全仓 `genericErrorCode` 只有两个实参（`:194` 的 4005、`:316` 的 3000），
    /// 即 `SPUInstallerDriver.m:316` 是**唯一**能产出顶层 3000 的地方，触发条件是安装器
    /// 发来 `SPUArchiveExtractionFailed`（`:307`）。它的生产者全在安装器进程内
    /// （`Autoupdate/AppInstaller.m:256/305`、`SUDiskImageUnarchiver.m:184`、
    /// `SUPipedUnarchiver.m:181/273/289`、`SUFlatPackageUnarchiver.m:59/61/72`、
    /// `SUUnarchiverNotifier.m:48`）。
    /// ⚠️ **下载阶段不产 3000 段**：`SPUDownloadDriver.m` 只会抛 `:100` / `:264` 的
    /// `SUDownloadError(2001)` ⇒ **没有任何不经过安装器就能到达 3000 段的路径**
    /// （ℹ️ 这句**仍成立**：§8.124 第 4 节，未被 §8.125 推翻；它说的是「**必须经过安装器**」，
    /// 而 §8.125 证明了**安装器在本机能跑** ⇒ 两者不矛盾，反而是互补的）。
    ///
    /// ⇒ ~~本环境（ad-hoc 自签 ⇒ 安装器 XPC 连不上，`SPUInstallerDriver.m:190`）**结构性**
    /// 撞不到 3000 段 —— 不是「这次没撞到」。要真机证据须先让安装器能跑（Developer ID
    /// 签名 + entitlement）~~
    /// ✅ **2026-09-22 订正（§8.125 实测推翻）**：**安装器在本机能跑、不需要 Developer ID**
    /// —— 自签身份 `TeamIdentifier=not set` ⇒ `SUCodeSigningVerifier.m:448-451` **不设**
    /// XPC 校验要求；3000 段的真机证据也已拿到（造「验签能过、解压不能过」的 dmg ⇒
    /// `SPUInstallerDriver.m:313`「解压时出现错误」，generic 码就是 3000）。
    /// ⚠️ 当初「装不上」的**真变量不是签名**：app 是**用代码**控制
    /// `automaticallyDownloadsUpdates`（不直接读 Sparkle 键）⇒ 用户域缺
    /// `SUAutomaticallyUpdate` ⇒ **只检查、不下载**；启动方式（`open -a` 还是直接 exec）
    /// **不是变量**（2026-09-22 对照组已证伪）。
    /// ⚠️ **换签名等于换一条路**：真用 Apple 证书签会设 `(anchor apple generic …)`
    /// ⇒ helper 必须同为 Apple 签 ⇒ 将来换了签名，这一段要重验。
    /// ℹ️ 划掉的旧前提**故意留着**（不悄悄删）—— 否则下一段实验会重新踩回来。
    /// ⇒ 3000 段仍落在 `3000..<5000` 区间内 ⇒ 缺不缺真机证据**都不会放跑任何错误**，
    /// 只影响文案精度，不影响分类。
    ///
    /// ✅ 有一条**阴性**证据反而支持这段区间：`SUInstallationCanceledError`(4007) /
    /// `SUInstallationAuthorizeLaterError`(4008) 虽然也落在 4000 段，但
    /// `SPUUIBasedUpdateDriver.m:482` 对这两个码是**直接 `abortUpdate()`、根本不调
    /// `showUpdaterError`** ⇒ 「用户取消安装」不会被误报成「安装失败」（QA 复验核过）。
    nonisolated static func isPostDownloadFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else { return false }
        // 3000 段（解压 / 验签 / 校验）与 4000 段（安装）之间**没有别的段**，
        // 所以这一段可以写成一个连续区间（`SUErrors.h:54-71` 逐行对过）。
        return (3000..<5000).contains(nsError.code)
    }

    /// 这个 `phase` 是不是**终态** —— 即「这一格陈述的是一件**已经发生的事实**，
    /// 收掉更新 UI 也抹不掉它」。
    ///
    /// ## 它防的是什么（2026-09-22 真机实测，§8.121 + QA 复验）
    ///
    /// 弹窗那条路（`SUAutomaticallyUpdate` 未设置 ⇒ **默认就是这条**）下载失败时，
    /// Sparkle 是**一串**回调，不是一个：
    ///
    /// ```text
    /// .923  下载失败：… not found (404)        ← delegate，先到 ⇒ phase = .failed
    /// .923  更新出错：下载更新时出现错误…        ← user driver，1ms 后到
    /// .953  dismissUpdateInstallation          ← 我们调 acknowledgement() 之后，30ms
    /// ```
    ///
    /// 第三条是关键：``UpdateUserDriver/showUpdaterError(_:acknowledgement:)``
    /// **必须**调 `acknowledgement()`（不调会话就挂着），而 Sparkle 把 `abortUpdate()`
    /// 放在那个块里 ⇒ 它 `dispatch_async` 回主队列后**必定**调用
    /// `dismissUpdateInstallation()`（`SPUUIBasedUpdateDriver.m:456`，`showErrorToUser`
    /// 为真时**无条件**、与错误是否为 nil 无关）。那一支原先无条件 `driverDidReset()`
    /// ⇒ **刚保住的 `.failed` 在 30ms 后又被冲回 `.idle`**。
    ///
    /// ⇒ 闸门只装在 `showUpdaterError` 上**不够**：它守住的那一瞬，紧接着就被
    /// acknowledgement 里的这一步抹掉。同一个闸门必须也装在 `dismissUpdateInstallation` 上。
    /// （第一版只装了前者 ⇒ QA 复验：界面落点与修复前**逐字相同**。）
    ///
    /// ## 「终态」怎么划 —— 判据是「这一态说的是**过去的事实**还是**活着的会话**」
    ///
    /// - `.failed(version)` → **是**。「1.1.0 **下载失败了**」是一件已经发生的事，
    ///   收 UI 抹不掉它。把它冲回 `.idle` 正是 §8.121 那个 bug 本身。
    /// - `.installFailed(version)` → **是**（2026-09-22 新增，账本第 43 行）。
    ///   「**下载成功了，但没装上**」同样是一件已经发生的事；而且它与 `.failed`
    ///   是同一个病的两半：冲回 `.idle` 会让「装不上去」这件事无声消失。
    /// - `.locationBlocked` → **是**。「**这个位置不允许更新**」同样已成事实
    ///   （它的文档写明「**没有自动出口，也不该有**」）。冲回 `.idle` 就是 §8.94 那句谎 ——
    ///   Sparkle 已把「上次检查时间」写成当下，而它在只读卷上**一次 appcast 都没去取**。
    /// - `.ready(version:autoRestart:)` → **不是**。⚠️ **这一条 2026-09-22 由 QA 真机复验后改判**
    ///   （我第一版把它划成了终态，**错了**）。它说的是「**现在**有个装好的更新等你重启」，
    ///   是一个**对还活着的会话的主张**；而走到本判据的这两处（`showUpdaterError` /
    ///   `dismissUpdateInstallation`）都紧接着 `abortUpdateAndShowNextUpdateImmediately:`
    ///   （`SPUUIBasedUpdateDriver.m:458`，就在 `dismissUpdateInstallation` 的**下一行**）
    ///   ⇒ 会话被拆掉、我们攥着的 `readyReply` 已经作废。
    ///   留着 `.ready` ⇒ 界面继续显示「立即重启」，而那一按**什么都不会发生**
    ///   —— 设计稿点名不许的那种按钮。**宁可回到「已是最新版本」，也不留一个死按钮。**
    /// - `.downloading(version:fraction:)` → **不是**。中间态，结果正是 `.failed` / `.ready`；
    ///   这一态由 ``isDownloadFailure(phase:)`` 单独处理。
    /// - `.found(version)` → **不是**。它是「等用户拍板」的中间态，不是结果。
    ///   把它当终态会留下「查看更新 / 后台更新并重启」的入口，而 Sparkle 那一轮已经 abort。
    /// - `.checking` → **不是，而且这一条最关键**。它**不给按钮**（§8.93），
    ///   把它当终态 ⇒ 界面停在「正在检查更新…」且**没有任何出口** —— 比冲回 `.idle` 糟得多。
    /// - `.idle` → **不是**。它本来就是「什么都没在进行」，reset 到它**不丢任何信息**。
    ///
    /// ⚠️ **每个终态都有用户侧的出口** —— 「重试」走 `checkForUpdates()`
    /// （它开头就把 `phase` 设回 `.idle`）、位置受限则是用户把 `.app` 拷进「应用程序」
    /// 后重新打开（**新进程**，`phase` 从 `.idle` 起）。⇒ 「收 UI 不动它」**不会把用户锁死**。
    ///
    /// **为什么抽成纯函数**：与 ``isDownloadFailure(phase:)`` / ``isUpdateLocationBlocked(_:)``
    /// 同一个理由 —— 「三条回调隔 30ms」在测试进程里**构造不出来**
    /// （§8.121 + QA 复验是靠重打包 + 本地坏 feed + AX 点击才复现的）。留成驱动里一句 `if case`，
    /// 「哪个 case 算终态」写错了**不会有任何断言变红**；而且它必须 `nonisolated`，
    /// 否则单测从非主 actor 上下文调不到（同 ``rowState(phase:skippedVersion:lastCheck:)``）。
    ///
    /// ⚠️ **用 `switch` 而不是 `if case`**：`UpdatePhase` 将来加 case 时这里**编译不过**
    /// ⇒ 「终态口径」失效是红的，不是静默的。
    nonisolated static func isTerminalPhase(_ phase: UpdatePhase) -> Bool {
        switch phase {
        case .failed, .installFailed, .locationBlocked:
            return true
        case .idle, .checking, .found, .downloading, .ready:
            return false
        }
    }

    /// 这个错误是不是「**应用当前所在的位置不允许更新**」（只读卷 / App Translocation）。
    ///
    /// 判定输入是 Sparkle 造的 `NSError`，两个码都在**它的源码里写死**
    /// （不是运行时行为 ⇒ 读源码就是证据，**不需要真机验证**；2026-09-20 §8.95.7 逐行对过）：
    ///
    /// - `SURunningFromDiskImageError`（`1003`）：从**只读卷或临时位置**运行 ——
    ///   典型是用户直接在 dmg 挂载卷里双击。构造处 `SPUBasicUpdateDriver.m:80`。
    /// - `SURunningTranslocated`（`1005`）：Gatekeeper 的「移位隔离」——
    ///   系统把 app 挪到一个只读的随机路径上跑。构造处 `SPUBasicUpdateDriver.m:78`。
    ///
    /// 两个码都在 `SUErrors.h`（`:43` / `:45`），域是 `SUSparkleErrorDomain`
    /// （`SUConstants.m:53`），并且 `SPUUIBasedUpdateDriver.m:462→:485` 是**原样传递**
    /// （中间没有重新包装）。
    ///
    /// **为什么两个一起判**：它们是**同一件事的两种成因** —— 位置不允许替换 bundle。
    /// 只判 `1003` 的话，「从下载文件夹直接双击」那种（走 Translocation）仍会掉进
    /// 「已是最新版本」。
    ///
    /// **为什么抽成纯函数**：真机上构造不出来（要挂 dmg、从只读卷启动 app ——
    /// §8.94 做过一次，代价是打包 + 挂载 + 清理一整轮）。留成驱动里一句 `if`，
    /// 改错了不会有任何断言变红 —— 同 ``isDownloadFailure(phase:)`` 那条理由。
    ///
    /// ⚠️ **单测要用字面量**（`1003` / `1005` + 域字符串），别引这里的符号：
    /// 两边同源就成了「拿常量跟自己比」，Sparkle 哪天改了数字也测不出来。
    nonisolated static func isUpdateLocationBlocked(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else { return false }
        return nsError.code == Int(SUError.runningFromDiskImageError.rawValue)
            || nsError.code == Int(SUError.runningTranslocated.rawValue)
    }

    /// 自动那条路进入「下载中」的判据（§8.83）。
    ///
    /// 弹窗那条路与自动那条路在 `SPUCoreBasedUpdateDriver.m:136` 之前是**同一条路**，
    /// ⇒ `willDownloadUpdate` 两条路都会到。分流靠两件事：
    ///
    /// ① **`phase == .idle`**：弹窗那条路上 `showUpdateFound` 早已把 `phase` 设成 `.found`
    ///    （顺序由 `SPUBasicUpdateDriver.m:164` → `SPUUIBasedUpdateDriver.m:244` 钉死），
    ///    ⇒ `willDownloadUpdate` 到的时候 `phase` **还**是 `.idle` 就**只可能是自动那条路**
    ///    —— 这是顺推，反过来也行：弹窗那条路走到这里时 `phase` **一定不是** `.idle`。
    /// ② **`autoDownloads == true`**：`phase == .idle` 只说「没人说过话」，
    ///    没说「我们正要静默下载」，所以还要判开关（与 `SPUUpdater.m:622` 选驱动
    ///    用的是同一个属性）。
    ///
    /// 抽成纯函数是为了能断言它（**真机也构造不出**「`phase` 不是 `.idle` 又走到
    /// `willDownloadUpdate`」的场景 —— `showUpdateFound` 永远先到，§8.81.4）。
    /// 同项目既有惯例（`shouldPublishProgress` / `isDownloadFailure`）。
    nonisolated static func shouldEnterBackgroundDownload(
        phase: UpdatePhase, autoDownloads: Bool
    ) -> Bool {
        guard case .idle = phase else { return false }
        return autoDownloads
    }

    /// 用户在更新弹窗上点下的那一下，该回答 Sparkle 什么。
    ///
    /// **为什么把「回答什么」抽出来**：它是本轮 Bug 1 的**全部判据** ——
    /// Esc 该不该回答、回答什么，决定了设置行停在「发现 1.1.0」还是谎报「已是最新版本」。
    /// 而真机上构造这一串要「点检查更新 → 等新版本弹窗 → 按 Esc → 看设置行」，
    /// 中间还隔着 Sparkle 的 `dispatch_async` 与窗口系统 —— 在测试进程里**复现不出来**。
    /// 抽成纯函数之后，「三种选择各自回答什么」可以被逐条钉住。
    ///
    /// ⚠️ **`holdForLater` 不是「什么都不做」，是「先不回答」**：那个 reply 由
    /// ``alertReply`` 攥着，会话继续活着 —— 于是「查看更新」能原样重弹，
    /// 而 Sparkle **不会**走 `uiDriverIsRequestingAbortUpdateWithError:`
    /// ⇒ `phase` 留在 `.found`（详见 ``alertReply`` 的说明）。
    ///
    /// ⚠️ **`.cancel` 与 `.dismiss` 都算「稍后」**：弹窗那两句话是同一件事 ——
    /// `updateEscHint`（「Esc 稍后再提醒」）与窗口右上角关闭。
    /// 把其中一条划成别的语义，用户按同一个意思做出两种结果。
    enum AlertReply: Equatable {
        /// 回答 `.install`：后台下载，下载完**自动重启**完成安装（见 ``readyHandling``）。
        case install
        /// 回答 `.skip`：只跳过这一个版本。
        case skip
        /// **先不回答**（把 reply 攥住）：Esc / 关窗 = 稍后，状态留在设置行上。
        case holdForLater
    }

    /// 弹窗选择 → 该回答什么。**纯函数，只看入参**。
    nonisolated static func alertReplyChoice(for choice: EjectAlertChoice) -> AlertReply {
        switch choice {
        case .installAndRestart:
            return .install
        case .skipVersion:
            return .skip
        case .cancel, .dismiss, .closeAndEject, .viewLog:
            // ⚠️ `.closeAndEject` / `.viewLog` 属于**推出弹窗**，更新弹窗不会给出它们；
            // 落到这里按「稍后」处理是**保守**的选择（宁可攥着，也不 abort 一个活着的会话）。
            return .holdForLater
        }
    }

    /// `showReady` 到达时该怎么处理 Sparkle 交回来的那个 reply。
    ///
    /// ## 三态各自的依据
    ///
    /// - ``autoRestart``：用户在弹窗里点了「后台更新并重启」**且**此刻没有推出在进行
    ///   ⇒ 立刻回答 `.install`（Sparkle 随后关掉 app、替换 bundle、重新拉起 = 自动重启）。
    ///   这正是 `updateCallout`（「…完成后**自动重启完成安装**」）与
    ///   `updateDownloadingHint`（「下载完成后会自动安装，无需你再操作。」）两句承诺的实现。
    ///   ⚠️ 2026-09-24 **用户拍板**：以这两句为准，行为改成自动重启
    ///   （设计稿 B4 原来那段 spec-note 写的是「「重启」不自动做，只提供入口」，
    ///   与这两句自相矛盾，已一并订正）。
    /// - ``deferUntilIdle``：同上，但此刻**有推出在进行** ⇒ 推迟。
    ///   `updateCallout` 明写承诺「正在推出的磁盘不会被打断」——
    ///   而回答 `.install` 在 `showReady` 阶段会走 `finishInstallationWithResponse:`
    ///   （`SPUUIBasedUpdateDriver.m:422`），那是**不可逆**的：app 会立刻退出，
    ///   把正在跑的 `unmountAndEjectDevice` 腰斩。推迟的出口是
    ///   ``EjectFlowController/waitUntilIdle()``（推出结束就补上自动重启）。
    /// - ``waitForUser``：用户**没点过**「后台更新并重启」（自动下载那条路、
    ///   以及 ``updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)``
    ///   那条「等退出时装」的路）⇒ 攥着 reply，等用户点「立即重启」。
    ///   **别让自动重启在那条路上生效**：那条路的语义就是「下次退出时静默装上」。
    enum ReadyHandling: Equatable {
        /// 立刻回答 `.install`（自动重启）。
        case autoRestart
        /// 推迟到推出结束再自动重启。
        case deferUntilIdle
        /// 攥着 reply，等用户点「立即重启」。
        case waitForUser
    }

    /// `showReady` 的处理分流。**纯函数，只看入参**。
    ///
    /// **为什么抽成纯函数**：真机上构造不出「下载完成的那一刻恰好有卷在推出」，
    /// 而这一支判错**不可逆** —— `SPUUserUpdateChoice.install` 在 `showReady` 阶段
    /// 会立刻退出 app（`SPUUIBasedUpdateDriver.m:422`），
    /// 判错就等于「用户正在拖文件时被强制重启」。留成驱动里一句 `if`，
    /// 「哪个分支写反了」不会有任何断言变红（同 ``isTerminalPhase(_:)`` 那条理由）。
    ///
    /// - Parameters:
    ///   - userChoseInstallAndRestart: 用户是否在这次会话里明确点过「后台更新并重启」。
    ///   - activeEjections: 此刻正在进行的推出操作数（见 ``EjectFlowController/activeEjectionCount``）。
    nonisolated static func readyHandling(
        userChoseInstallAndRestart: Bool, activeEjections: Int
    ) -> ReadyHandling {
        guard userChoseInstallAndRestart else { return .waitForUser }
        return activeEjections > 0 ? .deferUntilIdle : .autoRestart
    }

    /// 手动「检查更新」时清掉跳过标记。
    ///
    /// **跳过必须可撤销**：不清的话用户点「检查更新」也看不到那个版本，
    /// 只能去改偏好文件才能反悔 —— 而界面上没有任何地方告诉他这一点。
    func clearSkippedVersion() { skippedVersion = nil }
}

// MARK: - 给 `UpdateUserDriver` 用的落点
//
// 这些方法**只该由 driver 调**（它们是 Sparkle 回调的落点），单独成段，
// 避免和「用户动作」混在一起看串。

extension UpdateController {

    /// 发现了新版本。
    ///
    /// - Parameter autoDownloads: 自动更新开着时走**后台路径**（不弹窗）。
    /// - Returns: `true` 表示「弹窗交给调用方展示」。
    @discardableResult
    func driverDidFindUpdate(
        _ update: PendingUpdate,
        autoDownloads: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) -> Bool {
        pendingUpdate = update
        alertReply = reply
        // **每一轮「发现」都从「用户还没点过」开始**：上一轮若点了「后台更新并重启」、
        // 之后下载失败/被跳过，这个意图不能带进新的一轮（否则自动那条路的
        // `willInstallUpdateOnQuit` 会被误判成「用户点过」⇒ 强制重启）。
        userChoseInstallAndRestart = false
        if autoDownloads {
            // 设计稿：「开着的时候用户什么都不用做，这正是『后台更新』这个词的含义」。
            //
            // `fraction: nil` 而不是 `0`：**这一刻下载还没开始**，百分比无从得知。
            // 进度会由 `driverDidStartDownload`（`showDownloadInitiated` 那条）补上 ——
            // 而 `shouldPublishProgress(from: nil, …)` 恒为真，所以第一格一定发得出去。
            phase = .downloading(version: update.version, fraction: nil)
            return false
        }
        phase = .found(version: update.version)
        return true
    }

    /// 下载开始。
    func driverDidStartDownload(version: String, cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        phase = .downloading(version: version, fraction: 0)
    }

    /// 下载进度。
    ///
    /// **这一刻也是进度条第一次出现的那一刻**：`fraction` 从 `nil`（百分比未知）
    /// 变成具体数值，设置行才开始画进度条（见 ``shouldPublishProgress(from:to:)``）。
    func driverDidUpdateProgress(_ fraction: Double) {
        guard case .downloading(let version, let old) = phase else { return }
        guard Self.shouldPublishProgress(from: old, to: fraction) else { return }
        phase = .downloading(version: version, fraction: fraction)
    }

    /// 下载完成、开始解压。
    ///
    /// 解压进度**不单独画**：设计稿只承诺百分比，而它说的是下载的百分比
    /// （「百分比是真的，ETA 是编的」），解压是秒级的，再画一条只会闪一下。
    func driverDidFinishDownload() {
        guard case .downloading(let version, _) = phase else { return }
        phase = .downloading(version: version, fraction: 1)
    }

    /// 下载失败。
    func driverDidFailDownload(version: String?) {
        let resolved = version ?? pendingUpdate?.version ?? "?"
        downloadCancellation = nil
        phase = .failed(version: resolved)
    }

    /// **下载成功了，但之后那一步失败**（解压 / 验签 / 安装）→ ``UpdatePhase/installFailed(version:)``。
    ///
    /// ⚠️ 这一态**不能并进 ``driverDidFailDownload(version:)``**：那一态的文案是
    /// 「%@ 下载失败 / 网络不可用」，而这里的**下载是成功的** —— 那是句谎（账本第 43 行）。
    ///
    /// ⚠️ **也不能不落点**：把安装失败从下载失败里排除掉、却不给它一个落点的话，
    /// 它会掉进 `showUpdaterError` 的 else ⇒ `driverDidReset()` ⇒ `.idle`
    /// ⇒ 又一次「无声消失」（§8.121 + QA 2026-09-22 复验修掉的那个病）。
    func driverDidFailInstall(version: String?) {
        let resolved = version ?? pendingUpdate?.version ?? "?"
        downloadCancellation = nil
        phase = .installFailed(version: resolved)
    }

    /// 下载并校验完成，等重启。
    ///
    /// ## 2026-09-25：用户在弹窗里点过「后台更新并重启」时**自动重启**（§8.146）
    ///
    /// 此前无论用户当初选了什么，这里都只是攥住 reply、把界面落到「已就绪 + 立即重启」——
    /// 而弹窗提示块（`updateCallout`）与下载中那一行（`updateDownloadingHint`）**都在承诺
    /// 自动重启**。用户报的正是这个落差：「下载完成 → 没有自动重启，得手动点一下」。
    ///
    /// 分流判据是纯函数 ``readyHandling(userChoseInstallAndRestart:activeEjections:)``
    /// （三态：自动重启 / 推迟到推出结束 / 等用户点），**不在这里写 `if`** ——
    /// 真机上构造不出「下载完成那一刻恰好有卷在推出」，而这一支判错**不可逆**
    /// （`SPUUserUpdateChoice.install` 在 `showReady` 阶段会立刻退出 app）。
    ///
    /// ⚠️ **自动那条路（`willInstallUpdateOnQuit`）不受影响**：它不经过弹窗，
    /// `userChoseInstallAndRestart` 一直是 `false` ⇒ 落到 `.waitForUser`。
    /// 那条路的语义就是「下次退出时静默装上」，用户没点过任何东西。
    func driverIsReady(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        downloadCancellation = nil
        readyReply = reply

        let handling = Self.readyHandling(
            userChoseInstallAndRestart: userChoseInstallAndRestart,
            // 「有没有卷正在推出」**派生**自真实操作的生命周期
            // （`EjectFlowController` 的进出计数），不是另立一个开关。
            activeEjections: EjectFlowController.shared.activeEjectionCount
        )
        // 把分流结论**记进相位**（不是让视图去读一个可变开关）——
        // 理由见 ``UpdatePhase/ready(version:autoRestart:)``：开关会被
        // `installReadyUpdate()` 清掉，而这一行还要在屏幕上待一会儿。
        phase = .ready(version: version, autoRestart: handling != .waitForUser)

        switch handling {
        case .waitForUser:
            break
        case .autoRestart:
            Self.logger.info(
                "用户点过「后台更新并重启」且当前无推出在进行：自动重启完成安装（\(version, privacy: .public)）")
            installReadyUpdate()
        case .deferUntilIdle:
            // ⚠️ **不能现在就装**：`updateCallout` 承诺「正在推出的磁盘不会被打断」，
            // 而回答 `.install` 会立刻退出 app。推迟的出口 = 推出结束（否则会留下
            // 一个「永远不自动重启」的态）。
            Self.logger.info(
                "用户点过「后台更新并重启」，但此刻有卷正在推出：推迟到推出结束再自动重启（\(version, privacy: .public)）")
            Task { @MainActor [weak self] in
                await EjectFlowController.shared.waitUntilIdle()
                // 等的时候用户可能已经点过「立即重启」（`readyReply` 被清空）、
                // 或者这一轮会话已经被别的回调拆掉 ⇒ 都要重新判一次，别回答一个作废的 reply
                // （判据抽成 ``canStillAnswerReadyReply(hasReadyReply:phase:)``，理由见那里）。
                guard
                    let self,
                    Self.canStillAnswerReadyReply(
                        hasReadyReply: self.readyReply != nil, phase: self.phase)
                else { return }
                self.installReadyUpdate()
            }
        }
    }

    /// 「等推出结束」之后那一按：**这一刻还能不能回答 reply**。
    ///
    /// ## 为什么必须重判（2026-09-25，§8.146.7）
    ///
    /// `.deferUntilIdle` 那条路是**异步**的：`await waitUntilIdle()` 期间，
    /// 用户可能已经点了「立即重启」（``installReadyUpdate()`` 会把 `readyReply` 清空），
    /// 或者这一轮会话被别的回调拆掉（``driverDidReset()`` ⇒ `phase = .idle`）。
    /// 这两种情况下那个 reply 都**已经作废** —— 再回答它，Sparkle 那一侧的状态就与我们对不上。
    ///
    /// ⚠️ **为什么抽成纯函数**：它是「别回答一个作废的 reply」这条不变量的**全部**判据，
    /// 而原先写在 `Task` 闭包里 —— 整句删掉**不会有任何断言变红**
    /// （QA 探针 Q8 实测：全量测试仍绿）。同 ``isTerminalPhase(_:)`` 那条理由：
    /// 真机上也构造不出「推出结束的那一刻用户恰好点了立即重启」。
    nonisolated static func canStillAnswerReadyReply(
        hasReadyReply: Bool, phase: UpdatePhase
    ) -> Bool {
        guard hasReadyReply, case .ready = phase else { return false }
        return true
    }

    /// 更新因为「**应用所在的位置不允许**」而中止（只读卷 / App Translocation，§8.94）。
    ///
    /// 与 ``driverDidReset()`` 的区别**只有一件事**：后者会回到「已是最新版本」——
    /// 而那正是这条链上最严重的问题：Sparkle 在发起检查时**就写好了**「上次检查时间」
    /// （`SPUUpdater.m:789`，不看成败），于是界面会刷新那个时间并宣称「已是最新」，
    /// **而它根本没去取过 appcast**（`SPUBasicUpdateDriver.m:71` 判只读就 abort）。
    /// 结果：用户即使装的是旧版本、appcast 里真有新版，也**永远看不到**。
    ///
    /// ⚠️ **这一态没有自动出口，也不该有**：位置不变，再检查多少次都是同一个结果。
    /// 用户把 `.app` 拷进「应用程序」文件夹、从那里重新打开之后，那是一个新进程，
    /// `phase` 自然从 `.idle` 开始。
    func driverDidBlockAtLocation() {
        downloadCancellation = nil
        phase = .locationBlocked
    }

    /// 回到「什么都没在进行」（检查完没有新版本、或用户关掉了错误提示）。
    ///
    /// ⚠️ **它不改 ``lastCheckOutcome``**：本方法是「收掉这一轮会话」的公共落点，
    /// 会话被拆的原因有很多（用户关窗、Sparkle 收 UI），**大多数并不说明检查失败了**。
    /// 结论**只有一个来源**：``updater(_:didFinishUpdateCycleForUpdateCheck:error:)``
    /// —— 那是 Sparkle 在**每一轮**收尾时必然发的 delegate 回调（2026-09-28 真机实测
    /// 之后从 user driver 那两条回调搬过来的，理由见 ``checkOutcome(error:phase:)``）。
    func driverDidReset() {
        downloadCancellation = nil
        phase = .idle
        // 会话结束了 ⇒ 上一轮的用户意图作废（见 ``userChoseInstallAndRestart`` 的说明）。
        userChoseInstallAndRestart = false
    }

    /// 用户跳过当前这个版本。
    ///
    /// **跳过记的是版本号**，并且把进行中的状态一起清掉 —— 否则界面会同时说
    /// 「已跳过 1.1.0」和「正在后台下载 1.1.0」。
    func skipPendingVersion() {
        if let version = pendingUpdate?.version { skippedVersion = version }
        pendingUpdate = nil
        phase = .idle
    }

    /// 把弹窗拉起来（`showUpdateFound` 那条路）。
    ///
    /// 用户的选择映射到 Sparkle 的三个 reply（映射本身是纯函数
    /// ``alertReplyChoice(for:)``，有单测）：
    /// 「后台更新并重启」→ `.install`、「跳过此版本」→ `.skip`、
    /// Esc / 关窗 → **先不回答**（把 reply 攥住，见 ``alertReply``）。
    func showUpdateAlertIfNeeded() async {
        guard let update = pendingUpdate, let reply = alertReply else { return }
        let model = UpdateAlertBuilder.model(for: update)
        let choice = await EjectAlertPresenter.shared.present(model)
        switch Self.alertReplyChoice(for: choice) {
        case .install:
            alertReply = nil
            // 记住这个意图：下载完成（`showReady`）时要**自动重启**，
            // 而不是退回「已就绪 + 立即重启」等用户再点一次（``readyHandling``）。
            userChoseInstallAndRestart = true
            reply(.install)
        case .skip:
            alertReply = nil
            userChoseInstallAndRestart = false
            skipPendingVersion()
            reply(.skip)
        case .holdForLater:
            // ⚠️ **不回答 reply，也不清 `alertReply`**：回答 `.dismiss` 会让 Sparkle
            // abort 这一轮（`SPUUIBasedUpdateDriver.m:308` → `:456`）⇒
            // `dismissUpdateInstallation` ⇒ `driverDidReset()` ⇒ `phase = .idle`
            // ⇒ 设置行谎报「已是最新版本」。攥住之后 `phase` 留在 `.found`，
            // 而「查看更新」能原样重弹。完整推导见 ``alertReply`` 的说明。
            //
            // ⚠️ 代价：`.found` 期间 `checkForUpdates()` 无效（`sessionInProgress`），
            // 所以那一行**不给**「检查更新」按钮（`SettingsView` 的 `case .found`）。
            Self.logger.info(
                "用户选择稍后（Esc / 关窗）：攥住 reply，设置行留在「发现 \(update.version, privacy: .public)」")
        }
    }
}

// MARK: - Sparkle 的 delegate 侧（与 user driver 互为兜底）
//
// `SPUUpdaterDelegate` 在头文件里标了 `NS_SWIFT_UI_ACTOR`，所以它到 Swift 侧就是
// `@MainActor` 协议 —— 这个类本身也是 `@MainActor`，实现起来不需要跳线程。
//
// ⚠️ 但这里**不全是兜底**：`willInstallUpdateOnQuit` 在自动更新开着时是**唯一**会到的落点
// （那条路一个 user driver 回调都不发）。两者的区别见它自己的说明。

extension UpdateController: SPUUpdaterDelegate {

    /// 按当前 phase 开/关停摆看门狗。挂在 `phase` 的 `didSet` 上，
    /// 所以**不需要在每个设置 phase 的地方记得调它** —— 漏一处就会留下一个没有出口的态。
    private func syncStallWatch(now: Date = Date()) {
        guard case .downloading(_, nil) = phase else {
            stopStallWatch()
            return
        }
        if stallSince == nil { stallSince = now }
        guard stallTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.stallCheckInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.checkDownloadStall() }
        }
        // ⚠️ 加到 `.common` 而不是默认的 `.default`：菜单栏面板打开时 RunLoop 跑在
        // 事件追踪模式里，默认模式的定时器**不 firing** ⇒ 兜底在最该生效的时候不生效。
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    private func stopStallWatch() {
        stallTimer?.invalidate()
        stallTimer = nil
        stallSince = nil
    }

    /// 停摆检查：由定时器调用；测试直接调它并传 `now`，不必等真的 120 秒。
    func checkDownloadStall(now: Date = Date()) {
        guard case .downloading(let version, nil) = phase else { return }
        guard Self.isDownloadStalled(since: stallSince, now: now) else { return }
        Self.logger.error(
            """
            下载 \(version, privacy: .public) 停摆超过 \(Self.downloadStallTimeout, privacy: .public)s：\
            既无进度也无回执 ⇒ 转「下载失败」，让那一行有「重试」这个出口（第 34 行兜底）
            """)
        phase = .failed(version: version)
    }

    /// Sparkle 决定「**现在不查，等 N 秒再说**」—— 启动检查的**唯一**发起点（2026-09-28）。
    ///
    /// ## 为什么是这里，而不是 `startIfNeeded()` 里那两行
    ///
    /// `start()` 末尾必然走一次排期，而 `SPUUpdater.m:542-543` 在**同步**设好
    /// `sessionInProgress = YES` 之后才去**异步**探测安装器（XPC + `dispatch_async`）。
    /// 于是在 `start()` 返回后紧接着调 `checkForUpdatesInBackground()` 会被
    /// **静默拒掉** —— 头文件原话：「This method does not do anything if there is a
    /// `sessionInProgress`」（`SPUUpdater.m:664-667` 只打一条 error 日志）。
    /// 界面上看不出任何区别，而「启动检查」从未生效。
    ///
    /// 本回调到达时 Sparkle **已经把会话让出来了**：`SPUUpdater.m:546-547` 先
    /// `setCanCheckForUpdates:YES` / `setSessionInProgress:NO`，之后（`:575-577`）
    /// 才通知 delegate。⇒ 在这里发起是安全的。
    ///
    /// 而它**语义上**也正对：Sparkle 刚算完「距上次检查还没到 `SUScheduledCheckInterval`，
    /// 所以我等 `delay` 秒」—— 我们要覆盖的就是这个决定（「打开应用就该看一眼」）。
    ///
    /// ## ⚠️ 三条边界
    ///
    /// - **只覆盖一次**（``didRunLaunchCheck``）：不设闸门的话，每轮检查结束后 Sparkle
    ///   都会再问一次，6 小时的排期会被压成 5 分钟。
    /// - **Sparkle 若判定「已过期」就自己查了**，本回调**不会**被调用
    ///   （`SPUUpdater.m:586-588` 走的是立刻检查那一支）—— 那时不需要我们插手。
    /// - **自动检查关着时本回调也不会到**（`:508-513` 走
    ///   `updaterWillNotScheduleUpdateCheck`）—— 那正是我们要的：不违背用户的开关。
    ///
    /// ## ⚠️ 「不查」那一支**必须留话**（2026-09-28 实测补的）
    ///
    /// 不留的话，「这次启动没检查」在日志上有**两种读不出区别**的原因：
    /// ① 本回调根本没到（Sparkle 自己查了 / 自动检查关着）；
    /// ② 回调到了，但 ``shouldCheckOnLaunch(lastCheck:automaticallyChecks:now:debounce:)``
    ///    判定「刚查过，不必再查」。
    /// 二者的**外部表现逐字相同**（都没有请求、`SULastCheckTime` 都不动），
    /// 而它偏偏是维护时最先要问的那个问题 —— 也是本仓库反复记过的形态
    /// （「没有」与「有但没用」在输出上不许一样）。
    /// ⇒ 这一句把**判据的三个输入**原样打出来，读日志就能自己算。
    ///
    /// 一个进程最多打一次（上面的 ``didRunLaunchCheck`` 闸门），不构成噪声。
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard !didRunLaunchCheck else { return }
        didRunLaunchCheck = true
        let lastCheck = updater.lastUpdateCheckDate
        let automaticallyChecks = automaticallyChecksForUpdates
        guard
            Self.shouldCheckOnLaunch(
                lastCheck: lastCheck,
                automaticallyChecks: automaticallyChecks,
                now: Date(),
                debounce: Self.launchCheckDebounce)
        else {
            let elapsed = lastCheck.map { String(Int(Date().timeIntervalSince($0))) } ?? "从未查过"
            Self.logger.info(
                """
                启动检查：跳过 —— 自动检查开关 \(automaticallyChecks, privacy: .public)、\
                距上次检查 \(elapsed, privacy: .public) 秒、\
                防抖 \(Int(Self.launchCheckDebounce), privacy: .public) 秒 ⇒
                沿用 Sparkle 的排期，等 \(Int(delay), privacy: .public) 秒后再查
                """)
            return
        }
        Self.logger.info(
            """
            启动检查：Sparkle 原本打算等 \(Int(delay), privacy: .public) 秒，\
            距上次检查已超过 \(Int(Self.launchCheckDebounce), privacy: .public) 秒\
            （或从未查过）⇒ 现在就查
            """)
        updater.checkForUpdatesInBackground()
    }

    /// **发现了一个有效更新** —— 「这一轮拿到了答案」的**最早**已知点。
    ///
    /// ## 为什么它也写 ``lastCheckOutcome``（2026-09-28 真机验证时发现的窄口子）
    ///
    /// 弹窗那条路**故意不结束会话**（Esc 攥住 reply，见 ``alertReply`` 的说明），
    /// 于是 ``updater(_:didFinishUpdateCycleForUpdateCheck:error:)`` **不会发**。
    /// 用户若在那之后 5 分钟内（``launchCheckDebounce``）重开应用：
    /// 启动检查被防抖拦下 ⇒ `phase` 已被重置成 `.idle`、而结论还是 `nil`
    /// ⇒ 设置行**倒退回「已是最新版本」** —— 与这一轮在修的那句谎同一个形态
    /// （真机实测：15:42 启动检查发现 2026.09.28.1、Esc 关弹窗之后结论仍是空）。
    ///
    /// ⇒ 「发现了有效更新」本身就是铁证，写在**最早的已知点**上。
    /// 这不违反「单一事实来源」：它记的是**同一个事实**（这一轮拿到答案了），
    /// 只是比周期收尾更早；两处都在 `UpdateController.swift` 里，且判据一致
    /// （见 ``checkOutcome(error:phase:)`` 第 1 步 —— 有包可下就说明检查成功了）。
    ///
    /// ⚠️ **它覆盖两条路**：`SPUBasicUpdateDriver.m:164-165` 是**基类**发的，
    /// 弹窗路（`SPUUIBasedUpdateDriver`）与自动下载路（`SPUAutomaticUpdateDriver`）
    /// 都从 `SPUCoreBasedUpdateDriver` 走它 —— 那两条路的收尾时机会差很多。
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        lastCheckOutcome = .succeeded
        Self.logger.info(
            "发现有效更新 \(item.displayVersionString, privacy: .public) ⇒ 检查成功（结论先落，会话可能还开着）")
    }

    /// **每一轮更新周期的收尾**（`SPUUpdater.m:810`，由 `notifyDelegateOfDriverCompletion` 发）。
    ///
    /// ## 为什么结论挂在这里，而不是 user driver 的那两条回调上（2026-09-28 真机实测）
    ///
    /// 这是本轮**唯一**为「检查失败」找到的、**每轮必到**的落点。原先挂在
    /// `showUpdateNotFoundWithError` / `showUpdaterError` 上时，**后台检查失败一个都不到**：
    /// `SPUScheduledUpdateDriver.m:106` 交给 UI 层的是
    /// `abortUpdateWithError:error showErrorToUser:_showedUpdate`，而 `_showedUpdate`
    /// 只在已经展示过更新之后才为真 ⇒ 「启动时取 feed 失败」**没有 UI、没有回调**。
    ///
    /// 真机复现（把 feed 指到一个关掉的端口）：Sparkle 打了
    /// `Error: 无法连接服务器（kCFErrorDomainCFNetwork错误-1004）`，
    /// 而 `lastCheckOutcome` **一个字节都没写** —— 界面继续沿用上一次的读数。
    ///
    /// ⚠️ **它是唯一写入 ``lastCheckOutcome`` 的地方**：单一来源。
    /// 判据全在 ``checkOutcome(error:phase:)``（纯函数 + 单测）。
    ///
    /// ⚠️ **`shouldShowUpdateImmediately` 时本回调不发**（`:809`）—— 那只发生在
    /// 「立刻就要起下一轮检查」时，那一轮收尾时会补上。不会漏。
    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
    ) {
        let outcome = Self.checkOutcome(error: error, phase: phase)
        Self.logger.info(
            """
            更新周期收尾（\(String(describing: updateCheck), privacy: .public)）：\
            \(String(describing: outcome), privacy: .public)\
            错误=\(error.map { String(describing: $0) } ?? "无", privacy: .public)
            """)
        lastCheckOutcome = outcome
    }

    /// 下载失败。**这是「下载失败」那一态在文档上写明的来源**
    /// （`SPUUpdaterDelegate`：「Called after the specified update failed to download」）。
    ///
    /// ## 为什么这条和 `UpdateUserDriver.showUpdaterError` 里那条分流都要有
    ///
    /// 2026-09-18 实扫发现 `driverDidFailDownload` **全仓库只有定义、没有任何调用点**：
    /// 于是设计稿 `08-update.html` 给「下载失败」配的那一整行（文案 + 「重试」按钮）
    /// **永远画不出来**，而界面上完全看不出来 —— 下载出错时流程落进
    /// `driverDidReset()` → `phase = .idle`，表现是「进度条无声消失」，
    /// 与「下载完成了」长得一模一样。
    ///
    /// ⚠️ **已核实**（2026-09-22 真机实测，§8.121；它关掉 2026-09-19 登记的那条「未核实」）：
    /// 下载失败时 Sparkle **两条都走**，而且**相差 1ms**（delegate 先、user driver 后）。
    ///
    /// ⇒ 这里原来那句「万一两条都触发，也只是把同一个状态设两遍（幂等）」**是错的**：
    /// 两条触发的是**两个不同的方法**，后到的那条走的是 `showUpdaterError` 的 **else**
    /// 分支 ⇒ `driverDidReset()` ⇒ 把 delegate 刚设好的 `.failed` **冲回 `.idle`**
    /// ⇒ 界面无声回到「已是最新版本」（没有失败文案、也没有「重试」）。
    /// **「被闸门挡掉」不等于「无害」** —— 挡掉之后它掉进的是 else。
    ///
    /// ⇒ 所以光「两条都接上」**不够**，还得让后到的那条**不覆盖先到的结果**：
    /// `showUpdaterError` 在 `phase` 已是终态时不动，判据见 ``isTerminalPhase(_:)``。
    ///
    /// ⚠️ 选择器必须与 ObjC 侧逐字对上。**2026-09-18 实测**：把 `failedToDownloadUpdate`
    /// 改一个字母（`…Updates`），**编译照过、测试全绿、什么都不崩** —— 编译器只给一条
    /// `nearly matches optional requirement` 的 **warning**，而 warning 在构建日志里
    /// 和噪音没有区别。真正的后果是方法还在、却永远不会被调：
    /// 与「这个方法根本没写」逐字相同。所以 `UpdateSettingsTests` 用 `responds(to:)`
    /// 去问**运行时**，而不是读源码猜（那条断言实测有牙：拼错即红）。
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.logger.error("下载失败：\(error.localizedDescription, privacy: .public)")
        driverDidFailDownload(version: item.displayVersionString)
    }

    /// 下载**即将开始** —— 自动更新那条路上「后台下载中」那一态的唯一来源（2026-09-19，§8.81）。
    ///
    /// ## 这条为什么能到、而 user driver 那两条到不了
    ///
    /// 它由 `SPUCoreBasedUpdateDriver.m:136` 发出，而**两条路都经过那个类**：
    /// 自动那条是 `SPUAutomaticUpdateDriver` 自己调
    /// `[_coreDriver downloadUpdateFromAppcastItem:…]`（`SPUAutomaticUpdateDriver.m:95`），
    /// 弹窗那条也走同一个下载器。所以它**不是**自动那条路专有的 ——
    /// 下面那个守卫才是真正的分流判据。
    ///
    /// ## 判据：为什么是「user driver 到现在一声没吭」，而不是「有没有后台检查过」
    ///
    /// 顺序是**确定的**，而且是**两条路共同的顺序**：
    ///
    /// 1. `SPUBasicUpdateDriver.m:164` 发 `didFindValidUpdate`（delegate）；
    /// 2. 紧接着 `:168` 才把「找到更新」交给驱动 —— **弹窗那条**于是进
    ///    `SPUUIBasedUpdateDriver`，`showUpdateFound`（`:244`）把 `phase` 设成非 `.idle`；
    /// 3. 下载开始时 `willDownloadUpdate`（delegate，`SPUCoreBasedUpdateDriver.m:136`）
    ///    **早于** user driver 的 `showDownloadInitiated`（`:359`）。
    ///
    /// ⇒ 走到这里 `phase` 还是 `.idle`，**只可能**是「user driver 一条回调都没来过」，
    /// 也就是自动那条路。反过来，弹窗那条路上 `phase` 早已不是 `.idle`。
    ///
    /// **为什么不另存一个「这次是后台检查」的位**：那是「手动开关」，会与真实情况脱节
    /// （用户可能在检查途中关掉开关）。能派生就别用「手动开关」
    /// —— 同 ``isDownloadFailure(phase:)`` 那条判据。
    ///
    /// ## 为什么还要判开关
    ///
    /// `phase == .idle` 只说「没人说过话」，没说「我们正要静默下载」。而这一态要表达的
    /// 正是「**自动下载**正在进行」，所以补上 `updater.automaticallyDownloadsUpdates` ——
    /// 与 `SPUUpdater.m:622` 选驱动时用的是**同一个属性**（那行还要求
    /// `!installerIsRunning && _resumableUpdate == nil`，但那两条不成立时根本不会有下载，
    /// 所以这里不必重复）。
    ///
    /// ## 为什么只接这一条，不接 `didDownloadUpdate` / `willExtractUpdate` / …
    ///
    /// 那几条**在自动那条路上同样会到**（同一个类发的），但它们**不会改变行态**：
    /// 设计稿在这一段只承诺「正在后台下载」一句，到 `willInstallUpdateOnQuit` 才变「已就绪」。
    /// 接了却什么都不做 = 死代码（同 §8.47.6 的教训：**有定义、没消费者**的东西
    /// 在界面上与「已经支持了」长得一模一样）。
    ///
    /// ⚠️ **这一态里百分比是 `nil`，不是 `0`**：这条路**没有任何进度回调**
    /// （`showDownloadDidReceiveData` 全库只有 `SPUUIBasedUpdateDriver.m:369` 一个调用方）。
    /// 画一条停在 0% 的进度条，用户会盯着它判断「是不是卡住了」。
    ///
    /// ⚠️ **这里故意不设 `pendingUpdate`**：那条路**不会弹窗**（没有 `alertReply`），
    /// 而 `pendingUpdate` 的消费者只有弹窗与 `driverDidFailDownload` 的兜底版本号 ——
    /// 后者本来就会拿到 `item.displayVersionString`。设了却没人读，就是死状态
    /// （同 §8.47.6：**有生产者、没消费者**的东西在界面上与「已经支持了」长得一样）。
    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        // 判据抽到 ``shouldEnterBackgroundDownload(phase:autoDownloads:)`` —— 见 §8.83：
        // 那条路由 ``guard`` 改成调用一行更清晰，同时给「自动 vs 弹窗」分流
        // 一个**能真正跑断言**的纯函数（真机也构造不出「phase 不是 .idle 又走到这里」）。
        guard
            Self.shouldEnterBackgroundDownload(
                phase: phase, autoDownloads: updater.automaticallyDownloadsUpdates
            )
        else { return }
        Self.logger.info("自动更新开始后台下载：\(item.displayVersionString, privacy: .public)")
        phase = .downloading(version: item.displayVersionString, fraction: nil)
    }

    /// 「更新已下载完成，等退出时安装」—— **自动更新开着时，应用侧唯一会到的落点**。
    ///
    /// ## 为什么必须实现它（2026-09-19，SPEC §8.80）
    ///
    /// 自动更新开着时，`SPUUpdater` 会选 `SPUAutomaticUpdateDriver`（`SPUUpdater.m:622`），
    /// 而它**一个 user driver 回调都不发**：`SPUAutomaticUpdateDriver.m:42` 那句
    /// 「The user driver is only used for a termination callback」是**字面意思** ——
    /// 全文只在初始化时给 `_userDriver` 赋了值，**再没读过**；而
    /// `showUpdateFound` / `showDownloadInitiated` / `showDownloadDidReceiveData` /
    /// `showReadyToInstallAndRelaunch` 这四个回调在全库里**只有
    /// `SPUUIBasedUpdateDriver.m` 一个调用方**（`:244` / `:359` / `:369` / `:420`），
    /// 自动那条路不经过它。
    ///
    /// ⇒ 不实现这个方法的话，整条自动路径上应用侧**收不到任何回调**：`phase` 停在 `.idle`，
    /// 设置行于是显示「已是最新版本 · 上次检查：…」——**而新版本其实已经下载好、
    /// 正等着退出时装**。这正是设计稿 C 段开头那条自洽性判据要防的反例
    /// （它只防了「设置里写着已是最新、却弹了更新窗」，漏了「已是最新 + 已下载待装」）。
    ///
    /// ## 为什么返回 `true`
    ///
    /// 返回 `true` = 「这次安装由我们接管」：Sparkle **不结束**这一轮更新周期
    /// （`SPUAutomaticUpdateDriver.m:104-129` 只在返回 `NO` 时才 `abortUpdate`），
    /// 并把 `immediateInstallationBlock` 交给我们 —— 它就是设置行「立即重启」的实现。
    /// 返回 `NO` 的话那个 block **不可用**（`SPUUpdaterDelegate.h:437` 写明
    /// 「This handler can only be used if `YES` is returned」），界面上于是会出现一个
    /// 点了没反应的「立即重启」—— 正是设计稿点名不许的那种按钮
    /// （「先画上『后台更新并重启』再补实现，用户会点到一个什么都不做的按钮」）。
    ///
    /// ⚠️ **不牺牲「退出时装」**：`SPUUpdaterDelegate.h:433` 在两种返回值下都写着
    /// 「Sparkle will always attempt to install the update when the app terminates」，
    /// 而机制在**安装器工具自己**那边（`AppInstaller.m:392-412` 盯着目标进程退出后接着装）。
    /// 这一条**已真机复验**（§8.80.4：新代码 + 旧版本号打包 → 退出后版本真的变了）——
    /// 因为「库的注释不算证据」这条判据同样适用于**有利**的那句注释。
    ///
    /// ⚠️ **代价**：这一轮周期会一直开着（`sessionInProgress == YES`），直到
    /// **三种出口**之一发生 —— 用户点「立即重启」、退出应用，或（用户点过
    /// 「后台更新并重启」时）我们**自己**回答 `.install` 让它现在就装（§8.146）。
    /// 前两种出口下 `.ready` 那一态设置行不再显示「检查更新」（改显示「立即重启」）——
    /// 与弹窗那条路**同一套理由**，见 ``readyReply`` 的说明。
    ///
    /// ## 这一态与「后台下载中」的关系（2026-09-19 订正）
    ///
    /// 这里原来写的是「自动那条路上**没有**『后台下载中』……应用侧是从『已是最新』
    /// 直接跳到『已就绪』的」—— **只对了半句**。那条路确实**没有进度**
    /// （`showDownloadDidReceiveData` 到不了），但「**下载开始了**」这件事有落点：
    /// delegate 的 ``updater(_:willDownloadUpdate:with:)``。于是中间那段**画得出来**，
    /// 只是不带百分比 —— 见 ``UpdatePhase/downloading(version:fraction:)`` 与 §8.81。
    ///
    /// ⚠️ 上一轮漏掉它的原因值得留着：当时只扫了「**user driver** 那四个回调的唯一调用方」，
    /// 没扫「自动那条路会经过的类**还会发哪些 delegate 回调**」——
    /// 于是把「**进度**到不了」读成了「**什么都**到不了」。
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Self.logger.info("自动更新已就绪（等退出时装）：\(item.displayVersionString, privacy: .public)")
        pendingUpdate = PendingUpdate(appcastItem: item)
        // 把 block 包成与 `showReady` 那条路**同一个** reply 形状 ——
        // 于是两条路的「立即重启」共用 `installReadyUpdate()` 一处实现，
        // 不会出现「自动那条路的立即重启忘了清 readyReply」这种只在一条路上发生的漏。
        driverIsReady(version: item.displayVersionString) { _ in immediateInstallHandler() }
        return true
    }
}
