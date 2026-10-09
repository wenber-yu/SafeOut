import AppKit
import SwiftUI

/// **主窗口详情区里的磁盘列表页**（设计稿 `_10-combined-draft.html` 右栏那一片）。
///
/// ## 它不再是「整个主窗口」
///
/// v3 之前它是窗口内容视图：自带一条 52pt 自绘标题栏（标题 + 刷新 + 齿轮）、
/// 自绘窗口背景，还负责给 `contentView` 设圆角。合并之后这些**都不在它这一层**：
///
/// | 原先在 `ContentView` 里的 | 现在归谁 |
/// |---|---|
/// | 52pt 标题栏（标题 / 刷新 / 齿轮） | 标题 → ``MainDetailHead``；刷新 → `NSToolbar` 尾端那一个 item；**齿轮取消**（设置已经在侧栏里，再放一个就是同一件事两个入口） |
/// | `GlassSurface` 窗口背景 | `NSSplitViewController` 底下那一层（整窗一块玻璃，侧栏浮岛叠在它上面） |
/// | `contentView.layer.cornerRadius`（12pt 遮罩） | **删掉** —— 窗口圆角归系统，理由与影见 HANDOFF §3.7.3 |
/// | `frame(800 × 520)` | 窗口尺寸（``DesignTokens/Size/mainWindow``）；详情区只负责「填满分到的那一块」 |
///
/// ⇒ 它现在只做一件事：把**这一页**（FDA 横幅 + 磁盘列表）画出来。
/// 侧栏与窗口装配分别在 `MainWindowNavigation.swift` 与 `SafeOutApp.swift`。
///
/// **保留的不变量**（这些一条都没变）：
/// - 列表来自 ``DiskListStore``（与菜单栏同源）
/// - 占用检测走 ``OccupancyStore``（与菜单栏**同一份状态**，不再是两处各测各的）
/// - FDA canary 由本视图自己轮询（应用级状态，与有没有盘无关）
/// - 推出走 ``EjectUI/handle``，与菜单栏共用弹窗
struct ContentView: View {

    /// 磁盘列表来源。
    ///
    /// **生产路径是 ``DiskListStore/shared``**；离屏出图与真机自检可以注入一个自己造的实例
    /// （见 ``init(skipsInitialRefresh:store:)``）。
    ///
    /// 这里曾经硬编码 `DiskListStore.shared` —— 与 ``MenuPopoverView`` 的 `store:`
    /// 参数不一致（那边早就可注入，`SnapshotRenderTests` 就靠它出「设计稿那两块盘」的图）。
    /// 硬编码的后果是：**「列表为空 → 画空状态」这条分支只能靠本机恰好没插盘才走得到**，
    /// 于是守着它的那条真机断言大部分时间都在跳过（见 ``AppDelegate/checkEmptyStateInsteadOfSkeleton``）。
    @ObservedObject private var store: DiskListStore
    @State private var ejectingDiskId: String? = nil

    /// 每个卷的占用检测结果 —— **与菜单栏面板读的是同一个字典**。
    ///
    /// 这里曾经是一个本视图私有的 `@State var occupancy`，配一条只在本视图存活的
    /// 15s 定时器。菜单栏面板另抄了一份 `@State`、且**没有定时器**，于是
    /// 「主窗口说被占用、面板说可以安全推出」在结构上就是可能的（2026-09-15 用户报告）。
    /// 状态与刷新节奏现在都收在 ``OccupancyStore``，两个界面退化成纯读取。
    ///
    /// **可注入**，与 ``MenuPopoverView/occupancyStore`` 一致（那边早就可注入，
    /// 本视图是最后一个还在直读 `.shared` 的）。
    ///
    /// ⚠️ **这一行曾经硬编码 `OccupancyStore.shared`，而那是一条通到硬件的暗道**：
    /// `OccupancyStore.shared` 的默认 `diskStore` 是 `DiskListStore.shared`，
    /// 它的 `private init()` 会**同步真的去枚举本机磁盘**；默认 `detect` 还会真的跑 `lsof`。
    /// 于是「构造一个 `ContentView()`」这件事本身就会去摸本机的盘 ——
    /// 后果是**单测覆盖率随开发机上有没有插外置盘浮动 3.06pp**
    /// （41 行，实测坐实，取证见 `DESIGN-SPEC.md` §8.28.6）。
    ///
    /// 渲染 `ContentView` 的测试请走 ``ViewFixtures``，**不要写 `ContentView()`**。
    /// ⚠️ **故意不是 `@ObservedObject`**（2026-09-24）：本视图只在两个**显式**时机用它
    /// （`refreshDisks()` 与「回到前台」那一次 refresh），**界面上不读它的任何属性** ——
    /// 读的地方全在 ``DiskListRegion`` 里。
    ///
    /// ℹ️ **2026-09-25 补**：``eject(_:)`` 里多了一处 `result(for:)` ——
    /// 那是**一次性方法调用**（取缓存结论用于提前弹窗，§8.146），
    /// **不建立订阅**，所以「每 15s 轮询让整个窗口重算」这件事不会发生。
    /// 判据不是「有没有出现 `occupancyStore`」，而是「有没有挂 `@ObservedObject`」。
    ///
    /// 而 `@ObservedObject` 订阅的是 `objectWillChange` **整条**，不是「读到的那几个属性」：
    /// 只要挂上它，``OccupancyStore`` 每 15s 跑完 `lsof` 就会让**整个窗口重算**
    /// （标题栏、横幅、滚动区一起重建），而这些地方一个字节都没变。
    /// ⇒ **订阅随读取走**：谁画谁订阅。想加一处读占用结论的新 UI，就让它自己接
    /// ``OccupancyStore``，别在这里挂一个 `@ObservedObject` 图省事。
    private let occupancyStore: OccupancyStore

    /// 是否已授予「完全磁盘访问」（FDA）。决定是否在主窗口顶部展示未授权横幅。
    ///
    /// **必须**与 `OccupancyDetector.isFullDiskAccessAuthorized()` 的**实时探测值**同步——
    /// 该函数是 FDA 状态机的**单一事实来源**（探针选型与理由见 OccupancyDetector 注释）。
    /// 之前的实现只在占用检测末尾刷新一次、且被 `guard !disks.isEmpty` 保护，
    /// 导致「刚启动 / 没插硬盘 / 刚授权完回 app」三种场景下横幅状态都是过期的。
    /// 现在由独立的 `refreshFDAStatus()` 驱动，与占用检测彻底解耦。
    @State private var fdaAuthorized = false

    /// 本会话内是否曾经处于「未授权」状态。
    ///
    /// **为什么需要**：授权成功横幅只在「用户刚刚完成了授权动作」时才有意义。
    /// 若启动时就已授权，这个标记保持 `false`，横幅不会莫名其妙地闪一下。
    @State private var sawUnauthorizedThisSession = false

    /// 授权成功横幅是否可见（约 3 秒后淡出）。
    @State private var showGrantedBanner = false

    /// 300ms 的骨架闸门是否已经放行。
    ///
    /// **只在超过 300ms 时出现**：磁盘枚举通常 < 50ms，直接显示骨架会让界面「闪一下」，
    /// 比什么都不显示更糟。这个 `@State` **只由闸门置位、永远不会被复位** ——
    /// 「该不该显示骨架」由 ``showsSkeleton(gatePassed:hasFinishedInitialLoad:)``
    /// 现场算出来，不靠谁记得去关它。
    @State private var skeletonGatePassed = false

    /// 首屏加载是否已经结束（**无论成功与否、有没有磁盘**）。
    ///
    /// 与 ``skeletonGatePassed`` 一起决定骨架的显示，判据见
    /// ``showsSkeleton(gatePassed:hasFinishedInitialLoad:)``。
    @State private var hasFinishedInitialLoad = false

    /// 列表为空时，该画**骨架**还是**空状态**。
    ///
    /// **抽成纯函数是为了能被单测钉住** —— 这里曾经有一个确定性 bug
    /// （2026-09-17 用户报「没插移动硬盘时，主窗口一直显示骨架层」）：
    ///
    /// - 旧写法把骨架的**开启**判据写成「`disks` 为空」，
    ///   而**关闭**只挂在 `onChange(of: store.disks)` 上；
    /// - 没插盘时刷新前是 `[]`、刷新后还是 `[]` —— **列表根本没变化，`onChange` 不触发**；
    /// - 于是 300ms 闸门打开后，没有任何东西再把它关掉，骨架永驻。
    ///
    /// **判据**：「加载完了但机器上确实没有外置磁盘」与「还没加载完」是两种状态，
    /// 但它们在 `disks` 上的表现**都是空数组** —— 只看空数组分不开，必须看加载是否结束。
    static func showsSkeleton(gatePassed: Bool, hasFinishedInitialLoad: Bool) -> Bool {
        gatePassed && !hasFinishedInitialLoad
    }

    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue

    @Environment(\.colorScheme) private var colorScheme

    /// 是否跳过**首次**自动刷新（`.task` 里那一句）。
    ///
    /// **只给离屏出图用**，默认 `false` —— 生产行为一字不变。
    ///
    /// ## 为什么需要这个开关
    ///
    /// ``SnapshotRenderTests`` 出图时 `cacheDisplay` 是**同步**截的，而 `.task` 里的
    /// `await refreshDisks()` 要依次等磁盘枚举与占用检测（`lsof`）跑完。
    /// 截图正好落在「**盘已经列出来、数据还没收尾**」那个窗口里 ——
    /// 于是走查图拍到的是**中途状态**，而设计稿画的是稳态。
    /// 连跑三次指纹完全一致（`4fde925d31bc`、峰值 161），是**确定性**的，不是随机。
    ///
    /// 出图侧因此改成传 `skipsInitialRefresh: true` 渲染 —— 走查图于是停在**稳态**。
    ///
    /// ℹ️ **2026-09-30 补**：这段注释原先还说「右上角画的是 spinner、设计稿里是箭头」。
    /// 刷新按钮已经搬进 `NSToolbar`（见 `AppDelegate/makeMainWindow()`），
    /// 本视图里没有刷新按钮了 —— 但开关本身仍然必要，理由就是上面那句更一般的
    /// 「别拍中途状态」。
    ///
    /// 磁盘列表**不需要**额外准备：``DiskListStore/shared`` 的 `private init()` 会同步填一次
    /// `fetchExternalDisks()`，访问 `.shared` 时列表就是满的。
    /// ⚠️ 也**不要**在出图侧补 `await OccupancyStore.shared.refresh(disks:)` —— 那会真的跑
    /// `lsof`，实测把出图从十几秒拖到 6 分钟以上。
    ///
    /// **2026-09-17 补**：上面说的是「渲染本机真实磁盘」那一版出图。出图侧现在还有
    /// **注入夹具**的几版（多盘并列 / 忙态 / 紧凑行）—— 那几版走
    /// ``ViewFixtures/mainWindow(disks:occupancy:)``，两个 store 都是替身。
    /// 它们的 `occupancy` 必须**在截图之前 `await` 完**：`cacheDisplay` 是同步截的，
    /// 没 await 完就会截到「列表已排好、结论还是空字典」那一帧（每块盘都画成 `.unknown`）。
    ///
    /// ## 它是什么
    ///
    /// 与 ``DiskListStore`` 的 `monitoring:`、``OccupancyStore`` 的 `autoStart:` 同一种
    /// 「给测试/出图留的注入口」，不是顺手加的生产开关。**不要再加第二个**。
    let skipsInitialRefresh: Bool

    /// - Parameters:
    ///   - skipsInitialRefresh: 见上文。**调用方若自己准备了磁盘列表，必须传 `true`** ——
    ///     否则 `.task` 会真的去枚举本机磁盘，把它准备的列表覆盖掉。
    ///   - store: 磁盘列表来源，`nil`（生产）读 ``DiskListStore/shared``。
    ///     注入空列表实例即可在**任何硬件状态下**渲染空状态 ——
    ///     这是 `--preview-main-window-empty-keys` 与 `SnapshotRenderTests` 的入口。
    ///     ⚠️ 与 `skipsInitialRefresh` 是**两个独立参数**，故意不从彼此推导：
    ///     「读哪份数据」和「要不要自动刷新」是两件事，绑在一起会让调用方猜不出行为。
    ///   - occupancyStore: 占用结论来源，`nil`（生产）读 ``OccupancyStore/shared``。
    ///     与 `store` 同样是**独立**参数：调用方注入的这两个 store **必须是配对的**
    ///     （``OccupancyStore`` 用哪个 `diskStore` 决定了它测哪几块盘），
    ///     但本视图不替调用方推导 —— 猜错会得到一个「列表是 A、占用结论是 B」的画面，
    ///     而这种错在界面上几乎看不出来。
    init(
        skipsInitialRefresh: Bool = false,
        store: DiskListStore? = nil,
        occupancyStore: OccupancyStore? = nil
    ) {
        self.skipsInitialRefresh = skipsInitialRefresh
        self.store = store ?? .shared
        self.occupancyStore = occupancyStore ?? .shared
    }

    private var accentColor: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

    /// 行密度：≥ 4 块磁盘自动切紧凑行（设计稿 §3.3）。
    private var density: DiskRowDensity { .forCount(store.disks.count) }

    var body: some View {
        VStack(spacing: 0) {
            bannerArea
            scrollRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // **只「填满宿主」，不再给设计稿尺寸的 frame。**
        //
        // 这里原先还有一层 `frame(800 × 520)`，理由是「内容按设计稿排版」。
        // v3 之后那件事不成立了：详情区的可用宽 = 窗口 800 − 侧栏 200 = 600，
        // 再钉一个 800 会把内容撑到窗口外。窗口尺寸由 ``AppDelegate/makeMainWindow()``
        // 的 `contentRect` 与 `minSize` 保证，这里只管填满分到的那一块。
        //
        // ⚠️ **玻璃也不在这里挂了** —— 它是**整窗一块**（侧栏浮岛四边内缩的那 8pt
        // 也要吃到材质）。挂在详情区上的话，侧栏那一圈会露出没有材质的窗口底。
        // 挂点见 ``AppDelegate/makeMainWindow()``。
        //
        // ⚠️ **`.ignoresSafeArea()` 一并删了**：它当年是为了兜住「宿主报出标题栏
        // 安全区」那件事，而现在宿主自己就关掉了安全区（`NSHostingController` 的
        // `safeAreaRegions = []`）—— 留着它反而是个没人验证的兜底。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // 启动后立即同步探测一次 FDA 授权状态——`.task` 会在视图首次出现前异步执行，
            // 但本探测调用本身是同步的（探针只读 TCC 受保护目录的元数据，毫秒级返回），
            // 用户看不到「默认 false → 探测后变 true」的闪烁。
            refreshFDAStatus()
            // 出图时跳过：调用方已经把数据准备好了，见 ``skipsInitialRefresh`` 的文档。
            // 但「已加载完」必须置位 —— 否则 300ms 闸门会在出图时把骨架画出来。
            guard !skipsInitialRefresh else {
                hasFinishedInitialLoad = true
                return
            }
            await refreshDisks()
            // **无论有没有磁盘**，走到这里就说明首屏加载结束了。
            // 骨架的显示是算出来的（``showsSkeleton(gatePassed:hasFinishedInitialLoad:)``），
            // 置上这个标记它就自动不再显示 —— 不需要谁记得去「关」它。
            hasFinishedInitialLoad = true
        }
        .task {
            // 骨架屏延迟闸门：300ms 内加载完就永远不显示。
            try? await Task.sleep(nanoseconds: 300_000_000)
            skeletonGatePassed = true
        }
        // ⚠️ 双参闭包（不是单参）：`onChange(of:perform:)` 的单参形态在 macOS 14.0 废弃，
        //    部署目标是 14.0 ⇒ 单参写法在门槛 1 的 `-warnings-as-errors` 下是硬错误。
        .onChange(of: store.disks) { _, _ in
            // 磁盘列表变化时刷新 FDA（用户可能刚插了带占用进程的磁盘、也可能在系统设置里授权完了）。
            //
            // **占用检测不在这里**：它由 ``OccupancyStore`` 自己监听 `DiskListStore.$disks`
            // 完成。本视图再测一遍只会多一次 `lsof`，且两份结果还会互相覆盖。
            refreshFDAStatus()
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            // 每 15s 探测一次 FDA：覆盖「用户去系统设置授权后回到 app」的场景。
            // 即使没磁盘也探测（FDA 是应用级状态，与有没有盘无关）。
            //
            // **占用检测也不在这里**：``OccupancyStore`` 有自己的一条轮询，
            // 且它不依赖「主窗口是否打开」—— 面板单独开着时同样在刷新。
            refreshFDAStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // **关键**：app 重新激活时（用户在系统设置授权完切回 SafeOut）立即刷新 FDA，
            // 否则要等下一次 15s tick 才更新——用户看到横幅没消失会去系统设置重试，体验差。
            //
            // 顺带让占用结论也跟上：用户在系统设置里刚授完权，回到应用应当立刻看到
            // 「占用情况未知」变成真实结论，而不是等下一个 tick。
            refreshFDAStatus()
            Task { await occupancyStore.refresh(disks: store.disks) }
        }
    }

    /// 把 FDA 授权状态同步到本地 `@State`，是横幅显示与否的**单一闸门**。
    ///
    /// 沙盒构建不需要 FDA 概念（本应用不上架 MAS，这是防御分支）：沙盒里没有 TCC 拦截，
    /// `OccupancyResult` 直接走 `.unknown`；
    /// 此时让 `fdaAuthorized = true` 即可让未授权横幅永远不出现。
    ///
    /// **顺带驱动授权成功横幅**：从「本会话曾未授权」到「已授权」的跳变，
    /// 意味着用户刚在系统设置里翻了一通——回到应用需要一次「我做对了」的正反馈，
    /// 否则他会怀疑是不是还要再授权一次。
    private func refreshFDAStatus() {
        let authorized =
            OccupancyDetector.isSandboxed || OccupancyDetector.isFullDiskAccessAuthorized()
        defer { fdaAuthorized = authorized }

        guard authorized, !fdaAuthorized else {
            if !authorized { sawUnauthorizedThisSession = true }
            return
        }
        // 刚刚从「未授权」变成「已授权」。
        guard sawUnauthorizedThisSession else { return }
        sawUnauthorizedThisSession = false
        withAnimation(DesignTokens.Motion.standard) { showGrantedBanner = true }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(DesignTokens.Motion.slow) { showGrantedBanner = false }
        }
    }

    // MARK: - 横幅区

    /// 顶部横幅：未授权时是琥珀色引导，刚授权完是绿色正反馈。
    ///
    /// **两者互斥**：刚授权成功时 `fdaAuthorized == true`，未授权横幅本就不会出现。
    @ViewBuilder
    private var bannerArea: some View {
        if !fdaAuthorized {
            NoticeBanner(
                kind: .warning,
                icon: "lock",
                // ⚠️ 这句文案的值里带 `**`（设计稿那一句是粗体）⇒ **必须**走
                // `MarkdownCopy`。直接 `Text(L10n.tr(…))` 会原样画出裸星号（§8.78）。
                message: MarkdownCopy.text(L10n.tr(.fdaBannerLead)),
                actionTitle: L10n.tr(.openSystemSettings),
                accent: accentColor,
                action: AppSettings.openFullDiskAccessSettings
            )
        } else if showGrantedBanner {
            NoticeBanner(
                kind: .success,
                // 设计稿标记写的是 `data-i="checkCircle"` —— **描边**的圆 + 勾，
                // 与全设计稿的图标（1.7px 描边、无填充）同一套。
                // 曾经用 `.fill` 的实心圆：在一排描边图标里，它是唯一一个实心的。
                icon: "checkmark.circle",
                // 这句**不带** markdown 标记 ⇒ 走 `Text` 就够（别顺手改成 MarkdownCopy：
                // 那会让文案里偶然出现的 `_` 被当成斜体）。
                message: Text(L10n.tr(.fdaGrantedBanner)),
                accent: accentColor
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - 滚动区

    private var scrollRegion: some View {
        DiskListRegion(
            occupancyStore: occupancyStore,
            disks: store.disks,
            density: density,
            accent: accentColor,
            ejectingId: ejectingDiskId,
            showsSkeleton: Self.showsSkeleton(
                gatePassed: skeletonGatePassed,
                hasFinishedInitialLoad: hasFinishedInitialLoad),
            onEject: { disk in eject(disk) },
            onRefresh: { Task { await refreshDisks() } }
        )
    }

    /// 空状态。**不用警告色**（不是出错，是还没开始）；
    /// 文案提前解释筛选规则，消灭「插了盘却看不到」的困惑。

    // MARK: - 数据

    /// 打开设置面板。
    ///
    /// **走 nil-target 的 `sendAction`**，落点与主菜单的「设置…」（⌘,）、菜单栏面板的
    /// 「设置」**是同一个** `AppDelegate.showSettings` —— 三条入口必然打开**同一个窗口**。
    ///
    /// ## 为什么不再是 `.sheet`（2026-09-16 用户报告「设置窗口无法移动」）
    ///
    /// 这里曾经是 `showSettings = true` + `.sheet`。当时用探针实测过 sheet 窗口的
    /// `_isDraggable = false`、`_draggableFrame` 几乎是空的、**任何位置**按下
    /// `_shouldStartWindowDragForEvent:` 都返回 `false` —— sheet 在 macOS 上是**贴在父窗口上**
    /// 的，用户结构上就拖不动它。而菜单栏 / ⌘, 打开的是独立 `NSWindow`（实测顶部 52pt 可拖）。
    /// 于是同一个「设置」在两个入口下是两种东西，其中一种还拖不动。
    /// 现在统一成独立窗口，顺带删掉了一整套 `.sheet` 分支。
    ///
    private func refreshDisks() async {
        // **刷的是 `store` 自己，不是 `.shared`**：两者在出图/自检里可能是不同实例，
        // 写 `.shared` 会让「刷新」刷新一个本视图没在观察的对象（界面纹丝不动）。
        await store.refresh()
        // 显式再刷一次占用：`DiskListStore.refresh()` 会把新数组赋给 `disks`，
        // 正常情况下 ``OccupancyStore`` 的订阅会跟上；这里 await 一次是为了让
        // 「点刷新 → 按钮转完 → 界面已是新结论」这条链路在**同一帧**收口，
        // 而不是让用户看着旧结论等下一个 tick。
        await occupancyStore.refresh(disks: store.disks)
    }

    // MARK: - 推出

    /// 发起推出。
    ///
    /// **检测只决定「什么时候弹窗」，不决定「能不能推出」**：被占用时按钮已经写成红色的
    /// 「关闭并推出」，点击后**照常**走系统接口 —— `fBsyErr` 仍是「忙」的唯一权威判据，
    /// 弹窗则在缓存已经说「被占用」时**立刻**弹（见下面 2026-09-25 那段）。
    /// 这样既兑现了「破坏性前置」的设计意图，又保留了「有进程占用就失败」这层系统保护
    /// （绝不强制卸载）。
    ///
    /// ## 2026-09-25 改：把「弹窗」与「等系统」解耦（§8.146）
    ///
    /// 用户报「点有占用的盘的『关闭并推出』之后，占用弹窗很长时间才出现」。
    /// 真机日志坐实是系统那 12.5 秒（`unmountAndEjectDevice` 要十几秒才返回 `fBsyErr`），
    /// 而弹窗原先**必须等它返回**。现在把**窗口上已经显示的那份占用结论**
    /// （``OccupancyStore/result(for:)`` 的缓存）交给 ``EjectUI/eject(disk:cachedOccupancy:)``：
    /// 它已经说了「被占用」，就**立刻**弹窗，系统调用照常在后台跑
    /// （它仍是「能不能推出」的权威）。
    ///
    /// ⚠️ **顺带把 `await refreshDisks()` 从弹窗之前挪走了**：它对弹窗内容没有任何贡献，
    /// 却会**串行**跑一遍「全量刷新磁盘列表 + **所有卷**的 `lsof`」——
    /// 纯粹在弹窗前面再叠一段等待。刷新现在由 ``EjectUI`` 在真正需要时做
    /// （推出成功、或系统其实成功了而收掉预弹窗那一刻）。
    private func eject(_ disk: DiskInfo) {
        ejectingDiskId = disk.id
        Task {
            await EjectUI.eject(
                disk: disk,
                // 缓存 = **窗口上此刻显示的那一份**，用它才能保证
                // 「用户看到的」与「弹出的」是同一个结论。
                cachedOccupancy: occupancyStore.result(for: disk))
            ejectingDiskId = nil
        }
    }
}

// MARK: - 磁盘列表区（占用结论的订阅点在这里）

/// 主窗口的**磁盘列表区**：滚动容器 + 列表 / 空状态 / 骨架屏。
///
/// ## 为什么单独一个视图（2026-09-24）
///
/// ``ContentView`` 只在两个**显式**时机需要 ``OccupancyStore``（`refreshDisks()` 与
/// 「回到前台」那一次刷新），界面上**不读它的任何属性** —— 读的地方全在这里。
/// 但 `@ObservedObject` 订阅的是 `objectWillChange` **整条**，不是「读到的那几个属性」：
/// 挂一个在 `ContentView` 上，占用每 15s 跑完 `lsof` 就会让**整个窗口重算**
/// （标题栏、横幅、滚动区一起重建），而这些地方一个字节都没变。
/// ⇒ **订阅随读取走**：这里读 ⇒ 这里订阅；``ContentView`` 只把它当参数传下来。
///
/// ⚠️ **光把 body 拆成计算属性没有用**（这正是 swiftui-patterns 那条建议容易做错的地方）：
/// 计算属性会被**内联**进同一个 body，失效范围一点没变小。要拆就拆成**独立 struct**，
/// 并且**只传值**（`disks` / `ejectingId` / `showsSkeleton` 全是值）——
/// 传整个 store 或传闭包都会让「输入没变就跳过重算」失效。
struct DiskListRegion: View {

    /// 占用结论来源。**唯一的订阅点**在列表这一层。
    @ObservedObject var occupancyStore: OccupancyStore

    /// 磁盘列表（**值**）—— 由 ``ContentView`` 传下来，本视图**不订阅** ``DiskListStore``。
    let disks: [DiskInfo]

    let density: DiskRowDensity

    let accent: AccentColor

    /// 正在推出的那块盘的 id。``ContentView`` 的 `@State` 传值下来，不传闭包。
    let ejectingId: String?

    /// 是否画骨架。闸门（300ms）在 ``ContentView`` 里算好，这里只收结论。
    let showsSkeleton: Bool

    let onEject: (DiskInfo) -> Void

    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: density == .compact ? DesignTokens.Spacing.xs : DesignTokens.Spacing.sm) {
                if disks.isEmpty {
                    if showsSkeleton {
                        skeleton
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(disks) { disk in
                        DiskRow(
                            disk: disk,
                            occupancy: occupancyStore.result(for: disk),
                            accent: accent,
                            onEject: { onEject(disk) },
                            density: density,
                            isEjecting: ejectingId == disk.id
                        )
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.lg)
        }
        .scrollContentBackground(.hidden)
    }

    /// 空状态。**不用警告色**（不是出错，是还没开始）；
    /// 文案提前解释筛选规则，消灭「插了盘却看不到」的困惑。
    private var emptyState: some View {
        EmptyStateView(
            systemName: "externaldrive",
            title: L10n.tr(.noRemovableDisks),
            description: L10n.tr(.insertDiskHint) + "\n" + L10n.tr(.emptyStateFilterHint),
            actionTitle: L10n.tr(.refresh),
            actionSystemImage: "arrow.clockwise",
            action: onRefresh,
            accent: accent
        )
        .frame(height: 380)
    }

    private var skeleton: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonRow()
            }
        }
        .accessibilityLabel(L10n.tr(.loadingDisks))
    }
}
