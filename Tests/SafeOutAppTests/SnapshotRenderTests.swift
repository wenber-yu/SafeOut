import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 把 v2 设计落地的各个屏幕**离屏渲染成 PNG**，供人工与设计稿逐屏比对。
///
/// **默认不跑**：这是唯一一个会写文件的测试，不该在 `swift test` 里产生副作用。
/// 需要出图时显式开启：
///
/// ```bash
/// DE_SNAPSHOTS=1 swift test --filter 导出设计快照
/// # 图落在 /tmp/de-snapshots/
/// ```
///
/// **为什么需要它**：SPM 工程没有 Xcode 预览，而布局契约测试只能断言数字
/// （高度、宽度、分隔线条数），断不了「看起来对不对」。设计走查时缺一个能直接看的画面。
///
/// **它已经抓到过一个真缺陷**：2026-09-15 出图时发现设置面板「视觉效果」那行的标签
/// 被压成**竖排单字** —— 数字断言全绿，只有看图才看得出来。根因见
/// ``VisualStyle/shortName``，测量手法的问题见 `SettingsLayoutTests.renderedSize`。
///
/// **覆盖面与已知缺口**：
/// - ✅ 磁盘行三种判定 × 明暗、紧凑行、设置面板、FDA 两种横幅、空状态、占用/失败弹窗
/// - ✅ 主窗口：**本机真实磁盘**一版（本机 1 块外接盘，首帧占用态为 `.unknown`，
///   正好对应设计稿的未授权变体）＋ **注入的多盘并列 / 忙态 / 紧凑行**三版
/// - ✅ 菜单栏面板：注入设计稿那两块盘（Samsung T7 忙 / WD Blue 安全）
/// - ✅ 设置面板：**五个分类页各一张 × 明暗** + 登录项第三态 + 更新各态 + 接管未授权态
///   （两栏之后新增的；2026-09-29。⚠️ 单栏时代「拍到哪一页」不是个维度，
///   两栏之后**任何一张设置图都必须说出它拍的是哪一页**，
///   否则默认页「通用」会把整批图变成同一张 —— 见下面各段的注释）
///
/// ⚠️ **2026-09-17 补**：本文件此前在文件头写着「未覆盖：多盘并列 / 忙态的主窗口与面板 ——
/// 没有注入口，属独立改动」。注入口在 §8.29 / §8.30 补齐后，**这条缺口一直没回来关**，
/// 于是走查图长期只有「本机恰好插着的那一块盘」。
/// 现在多盘那几版走 ``ViewFixtures/mainWindow(disks:occupancy:)``。
/// **机器无关的断言**在 `MainWindowDiskListTests`（出图不进 CI，光有图没有牙）。
@MainActor
struct SnapshotRenderTests {

    private let outDir = "/tmp/de-snapshots"

    /// 设置页出图的**画布宽度** —— v3 详情区宽 = 主窗口 800 − 侧栏本体 200 − 浮岛左内缩 8。
    ///
    /// ⚠️ 与 `SettingsLayoutTests/detailWidth` 同一口径，理由见那里的长注释：
    /// 那 8pt 是**本机（macOS 26）实测**的侧栏浮岛内缩，14–15 上没有浮岛、内缩为 0。
    /// `Design/ui/v3/HANDOFF.md` §5 按「800 − 200 = 600」粗算，少算了这 8pt。
    private var detailWidth: CGFloat {
        DesignTokens.Size.mainWindow.width - DesignTokens.Size.mainSidebarWidth - 8
    }

    /// 设置页出图的**画布高度** —— 详情区高 = 主窗口 − 系统工具栏（52）。
    ///
    /// v2 用的是「独立设置窗口的 440」（由内容夹逼出来）；v3 的设置住在详情区里，
    /// 高度由窗口与工具栏决定，内容超出走滚动。
    private var detailHeight: CGFloat {
        DesignTokens.Size.mainWindow.height - DesignTokens.Size.titleBarBandHeight
    }

    private let disk = DiskInfo(
        id: "/Volumes/My Passport",
        bsdName: "disk4s2",
        volumeName: "My Passport",
        mountPath: "/Volumes/My Passport",
        totalBytes: 1_000_000_000_000,
        usedBytes: 300_000_000_000,
        freeBytes: 700_000_000_000,
        deviceProtocol: "USB",
        deviceModel: "SanDisk Extreme 55AE"
    )

    // MARK: - 进程样本（走查图里芯片的图标来源）

    /// 走查图里进程芯片用的**真实应用身份**。
    ///
    /// ## 为什么必须给（2026-09-17 补，用户报「应用图标又不显示了」）
    ///
    /// 出图夹具里的进程原本只填了 `pid` / `processName` / `path` ——
    /// **没填 `appBundlePath`，也没填 `executablePath`**，而那两个字段正是
    /// ``ProcessAppResolver/icon(for:)`` 唯一的图标来源：
    ///
    /// ```swift
    /// guard let path = process.appBundlePath ?? process.executablePath else { return nil }
    /// ```
    ///
    /// 生产路径上这两个字段由 ``ProcessAppResolver/enrich(_:)`` 用 `proc_pidpath`
    /// **按 PID 查出来**；而夹具的 PID 是编的（5340 / 39298…），本机并不存在 →
    /// `proc_pidpath` 失败 → 两条路径都是 `nil` → `icon(for:)` 返回 `nil` →
    /// ``ProcessChip`` 回落成 SF Symbol `app`（**一个空方框**）。
    ///
    /// 于是**所有忙态走查图里的进程芯片都画成空方框**，而设计稿画的是「有图标的芯片」。
    /// 走查时会被读成「应用图标没显示」这种产品缺陷 —— 用户看
    /// `main-window-multi-light.png` 时正是这么读的。
    ///
    /// ## 产品代码不需要改
    ///
    /// `icon(for:)` 返回 `nil` 时回落成空方框是**对的** —— 它真正的含义是
    /// 「这个 PID 已经不在了」。错的是**夹具**：它造出了一个生产上几乎不会出现的状态，
    /// 还把它当成常态出图。（生产上只要进程还活着，`enrich` 就一定能拿到
    /// `executablePath` —— 连 `/bin/sleep` 这种 CLI 都有，见 `ProcessAppResolverTests`。）
    ///
    /// ## 为什么用系统卷上的应用
    ///
    /// 只有 `/System/…` 是**任何 macOS 都保证存在**的，出图因此与机器无关。
    /// 而且它们的图标正是设计稿要表达的那两个（Finder 的文件夹、图像捕捉的相机）——
    /// `01-main-window.html` 与 `03-eject-flow.html` 画的样本进程就是这两个。
    private enum SampleApp {
        /// 取第一个存在的候选路径。都不存在返回 `nil`（调用方用 `#require` 报错，
        /// **不要静默退回空方框** —— 那正是这次要修的病）。
        static func firstExisting(_ candidates: [String]) -> String? {
            candidates.first { FileManager.default.fileExists(atPath: $0) }
        }

        static var finder: String? {
            firstExisting(["/System/Library/CoreServices/Finder.app"])
        }

        static var imageCapture: String? {
            firstExisting([
                "/System/Applications/Image Capture.app",
                "/Applications/Image Capture.app",
            ])
        }
    }

    /// 忙态样本进程 —— **与设计稿的样本一致**（`01-main-window.html` 的磁盘行与
    /// `03-eject-flow.html` 的弹窗画的都是 `Finder` + `图像捕捉`）。
    ///
    /// 此前这里是 `IINA` / `tail`（PID 5340 / 39298）：那是某次排查时本机真实占用者的名字，
    /// **不是设计稿的样本**，而且因为 PID 是编的、又没填应用身份，图标一律是空方框。
    /// 走查图是拿来跟设计稿并排比的 —— 样本该同源（同 ``designDisks`` 用面板设计稿那两块盘）。
    ///
    /// - Note: `appBundlePath` 走 ``SampleApp`` 解析，**不硬编码到具体机型**；
    ///   解析不到时 `try #require` 会让出图直接失败，而不是悄悄出一张空方框图。
    private func sampleProcs(finderApp: String, imageCaptureApp: String) -> [OccupyingProcess] {
        [
            OccupyingProcess(
                pid: 1234, processName: "Finder", displayName: "Finder",
                appBundlePath: finderApp, path: "/Volumes/My Passport/clip.mp4"),
            OccupyingProcess(
                pid: 5678, processName: "图像捕捉", displayName: "图像捕捉",
                appBundlePath: imageCaptureApp, path: "/Volumes/My Passport/clip.mp4"),
        ]
    }

    /// **非 app 内的 CLI 进程**样本（`tail`）：身份字段里只有 `executablePath`，
    /// 图标取自可执行文件自身的系统图标 —— 这是生产上 `tail` / `ffmpeg` 的真实长相，
    /// 与「空方框」不是一回事，单独出一张图以免混进上面那组被误读。
    private let cliProc = OccupyingProcess(
        pid: 39298, processName: "tail", displayName: "tail",
        executablePath: "/usr/bin/tail", path: "/Volumes/My Passport/clip.mp4")

    /// 设置面板「更新」行各态出图用的**固定**「上次检查时间」。
    ///
    /// ⚠️ **不能用 `Date()`**：那会让每次跑出来的「上次检查：…」都不一样，
    /// 两张图 diff 不出真变化 —— 而走查图的价值恰恰在于「这次与上次不同之处 = 我改的东西」。
    /// 取值与设计稿同源（`08-update.html` 的「上次检查：今天 14:30」，日期取 2026-09-17）。
    private static let designLastCheck =
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 8 * 3600),
            year: 2026, month: 9, day: 17, hour: 14, minute: 30
        ).date ?? Date(timeIntervalSince1970: 0)

    /// 更新弹窗的样本值 —— **逐字取自设计稿 `08-update.html` A 段**
    /// （1.0.0 → 1.1.0、构建 42 → 58、2026-09-17、12.4 MB、三条更新）。
    ///
    /// 走查图要和设计稿并排比，样本就得同源；换一组「看起来差不多」的值，
    /// 比出来的差异分不清是实现的还是样本的（同 §8.33 的磁盘 / 进程样本规则）。
    private static let designUpdateFixture = PendingUpdate(
        version: "1.1.0", newBuild: "58",
        currentVersion: "1.0.0", currentBuild: "42",
        date: "2026-09-17", sizeBytes: 12_400_000,
        notes: [
            "设置里新增「自动更新」开关，可后台下载并在重启后安装",
            "修复未插入磁盘时骨架层一直不消失的问题",
            "推出失败弹窗新增「查看日志」直达入口",
        ])

    /// `02-menu-bar.html` 里面板展示的那两块盘 —— 名称、容量、占用都与设计稿逐字一致。
    ///
    /// 出图用它而不是本机真实磁盘，理由见 ``导出设计快照()`` 里面板那一段的注释。
    private let designDisks = [
        DiskInfo(
            id: "/Volumes/Samsung T7",
            bsdName: "disk5s2",
            volumeName: "Samsung T7",
            mountPath: "/Volumes/Samsung T7",
            totalBytes: 1_000_000_000_000,
            usedBytes: 300_000_000_000,
            freeBytes: 700_000_000_000,
            deviceProtocol: "USB",
            deviceModel: "Samsung PSSD T7"
        ),
        DiskInfo(
            id: "/Volumes/WD Blue",
            bsdName: "disk6s2",
            volumeName: "WD Blue",
            mountPath: "/Volumes/WD Blue",
            totalBytes: 500_000_000_000,
            usedBytes: 120_000_000_000,
            freeBytes: 380_000_000_000,
            deviceProtocol: "USB",
            deviceModel: "WD Blue SN570"
        ),
    ]

    /// 造一块夹具盘。紧凑行那一组要在 ``designDisks`` 之外再补两块。
    ///
    /// 拆成局部常量是**必需**的，不是风格偏好：把整个 `DiskInfo(...)` 字面量塞进数组里，
    /// 类型检查器会超时（实测 `unable to type-check this expression in reasonable time`）。
    private func fixtureDisk(name: String, bsd: String, total: Int64, used: Int64) -> DiskInfo {
        let path = "/Volumes/\(name)"
        return DiskInfo(
            id: path,
            bsdName: bsd,
            volumeName: name,
            mountPath: path,
            totalBytes: total,
            usedBytes: used,
            freeBytes: total - used,
            deviceProtocol: "USB",
            deviceModel: "SanDisk Extreme 55AE"
        )
    }

    // MARK: - 位图写出

    /// 把一个已经布局好的 `NSView` 按 2x 写成 PNG。
    ///
    /// 手动构造 2x 的 `NSBitmapImageRep` 而不是用 `bitmapImageRepForCachingDisplay`：
    /// 后者按视图的 backingScaleFactor 出图，而离屏视图没有 window → 只有 1x，图会发虚。
    private func writePNG(_ view: NSView, size: CGSize, name: String) throws {
        let scale: CGFloat = 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            Issue.record("无法创建位图：\(name)")
            return
        }
        rep.size = size
        view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("PNG 编码失败：\(name)")
            return
        }
        try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        print("  导出 \(name).png  \(Int(size.width))×\(Int(size.height))pt")
    }

    /// 离屏渲染一个 SwiftUI 视图并写成 PNG。
    ///
    /// 高度用 `sizeThatFits(in:)` 而不是 `fittingSize` —— 后者不认宽度约束，
    /// 会把内容按理想宽度排版，出图与真机不符（对照实验见
    /// `SettingsLayoutTests.renderedSize` 的注释）。窗口类屏幕（主窗口 / 面板）
    /// 传显式 `height`，因为它们由窗口定尺寸、不随内容收缩。
    ///
    /// 明暗通过 `hosting.view.appearance` 切换（比 `environment(\.colorScheme,)` 可靠，
    /// 因为 AppKit 宿主的外观会覆盖 SwiftUI 环境值）。
    private func dump(
        _ view: some View, width: CGFloat, height: CGFloat? = nil, name: String, dark: Bool = false
    ) throws {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let resolved =
            height
            ?? hosting.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        let size = CGSize(width: width, height: max(resolved, 1))
        hosting.view.setFrameSize(size)
        hosting.view.layoutSubtreeIfNeeded()
        try writePNG(hosting.view, size: size, name: name)
    }

    /// 弹窗出图的留白：四周各 40，便于看清圆角、描边与阴影。
    private static let alertStagePadding: CGFloat = 40

    /// 把推出弹窗垫在深色舞台上出图。
    ///
    /// **为什么不能直接截弹窗**：它是毛玻璃 + 半透明罩层，在透明背景上会渲成一片浅色，
    /// 圆角、描边与阴影全都看不出来 —— 而这三样恰恰是「看起来像不像设计稿」的关键。
    ///
    /// **必须先量出弹窗高度、再用确定尺寸搭舞台**：舞台底色 `Color` 是弹性的，
    /// 若让它参与 `sizeThatFits(in: …greatestFiniteMagnitude)` 的测量，
    /// 它会接受那个无穷大的高度提案，舞台高度随之变成无穷 → 写位图时
    /// `Int(∞ * 2)` 直接 **SIGTRAP**（实测踩到）。所以先只量弹窗本身，再定尺寸。
    private func dumpAlert(_ model: EjectAlertModel, name: String, dark: Bool = false) throws {
        _ = NSApplication.shared
        let alert = EjectAlertView(model: model, onAction: { _ in })
        let probe = NSHostingController(rootView: alert)
        let alertHeight = probe.sizeThatFits(
            in: CGSize(width: DesignTokens.Size.alertWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height
        let stage = CGSize(
            width: DesignTokens.Size.alertWidth + Self.alertStagePadding * 2,
            height: alertHeight + Self.alertStagePadding * 2)

        let hosting = NSHostingController(
            rootView: ZStack {
                Color(nsColor: NSColor(srgbRed: 0.44, green: 0.46, blue: 0.50, alpha: 1))
                alert
            }
            .frame(width: stage.width, height: stage.height))
        hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.view.setFrameSize(stage)
        hosting.view.layoutSubtreeIfNeeded()
        try writePNG(hosting.view, size: stage, name: name)
    }

    // MARK: - 出图

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DE_SNAPSHOTS"] == "1"))
    func 导出设计快照() async throws {
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // 主窗口列表：800 − 左右各 16pt 内边距。
        let mainW = DesignTokens.Size.mainWindow.width - 32
        // 菜单栏面板里的磁盘行：360 − 列表左右各 8pt。
        //
        // ⚠️ **不能再减行自己的 8pt**：`MenuBarDiskRow` 自带 `.padding(8)`，
        // 它的**外框**宽就是 360 − 16 = 344。曾经按「面板 8 + 行内 8」写成 328，
        // 于是出图比真机窄了 16pt —— 文本列被压窄，长文案（如「占用程序：…」）
        // 的截断位置与真机不一致，走查时看到的换行/省略号都是假的。
        let menuW = DesignTokens.Size.menuPopoverWidth - 16

        // 进程样本的**应用身份**：必须解析到真实 `.app`，否则芯片图标位是空方框
        // （2026-09-17 修，见 ``SampleApp``）。
        //
        // ⚠️ 用 `try #require` 而不是 `?? ""`：解析不到就**让出图直接失败**。
        // 静默退回的后果是「又出一张空方框图」，而这正是这次要修的 bug ——
        // **失败要响，不要悄悄退化成上一次的坏样子**。
        let finderApp = try #require(
            SampleApp.finder, "系统里找不到 Finder.app —— 进程芯片的图标会退回空方框")
        let imageCaptureApp = try #require(
            SampleApp.imageCapture, "系统里找不到「图像捕捉」—— 进程芯片的图标会退回空方框")
        let procs = sampleProcs(finderApp: finderApp, imageCaptureApp: imageCaptureApp)

        // ---- 磁盘行：三种判定状态（设计稿 06-states.html 的状态矩阵）----
        let states: [(String, OccupancyResult)] = [
            ("busy", .occupied(procs)),
            ("safe", OccupancyResult.none),
            ("unknown", .needsFullDiskAccess),
        ]

        for (label, occ) in states {
            try dump(
                DiskRow(disk: disk, occupancy: occ, accent: .default, onEject: {}, density: .regular),
                width: mainW, name: "row-\(label)-light")
            try dump(
                MenuBarDiskRow(disk: disk, occupancy: occ, accent: .default, onEject: {}),
                width: menuW, name: "menurow-\(label)-light")
        }

        // 紧凑行（≥ 4 块盘时自动切换）
        try dump(
            DiskRow(disk: disk, occupancy: .occupied(procs), accent: .default, onEject: {}, density: .compact),
            width: mainW, name: "row-compact-busy-light")

        // **非 app 内的 CLI 进程**（`tail`）：芯片图标取自可执行文件本身，**不是空方框**。
        //
        // 单独出一张的理由：这一档与上面那组的图标**来源不同**（`executablePath` 而不是
        // `appBundlePath`）。混在同一张图里，将来谁也说不清「那个图标为什么长得不一样」；
        // 也正因为这一档容易被误读成「图标缺失」，才需要它自己有一张图 + 一句说明。
        try dump(
            DiskRow(
                disk: disk, occupancy: .occupied([cliProc]), accent: .default, onEject: {},
                density: .regular),
            width: mainW, name: "row-busy-cli-light")

        // ---- 主窗口（设计稿 01-main-window.html）----
        // 直读 DiskListStore.shared，渲染的是本机真实磁盘与首帧占用态。
        //
        // ⚠️ **必须传 `skipsInitialRefresh: true`**：`cacheDisplay` 是**同步**截的，而
        // `ContentView` 的 `.task` 会自动 `await refreshDisks()` —— 它先把 `isRefreshing`
        // 置真，再等占用检测（`lsof`）跑完。截图正好落在「盘已经列出来、刷新还没收尾」
        // 那个窗口里，于是走查图右上角画的是 **spinner**，而设计稿里是箭头。
        // 连跑三次指纹完全一致（`4fde925d31bc`、峰值 158），是**确定性**的，不是随机。
        //
        // 磁盘列表**不需要**在这里补：`DiskListStore.shared` 的 `private init()` 会
        // 同步填一次 `fetchExternalDisks()`，访问 `.shared` 时列表就是满的。
        // ⚠️ 也**不要**在这里 `await OccupancyStore.shared.refresh(disks:)` ——
        // 那会真的跑 `lsof`，实测把出图从十几秒拖到 6 分钟以上（本轮踩到）。
        // 面板那一段用的是注入检测器的 `designOccupancy`，刻意避开了真实 `lsof`。
        try dump(
            ContentView(skipsInitialRefresh: true), width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height, name: "main-window-light")
        try dump(
            ContentView(skipsInitialRefresh: true), width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height, name: "main-window-dark", dark: true)

        // ---- 主窗口：多盘并列 + 忙态（**注入夹具**，与机器无关）----
        //
        // 上面两版画的是**本机真实磁盘**（本机 1 块），所以「多盘并列」与「忙态」
        // 在这两版里**结构上照不出来** —— 这正是本文件此前记的缺口。
        //
        // 这两组用 ``ViewFixtures/mainWindow(disks:occupancy:)``：
        // - `main-window-multi`：设计稿 `01-main-window.html` 的两块样本盘
        //   （Samsung T7 忙 / WD Blue 安全），与面板那一段**同源**；
        // - `main-window-compact`：≥ 4 块 → 紧凑行（设计稿 §3.3），
        //   一忙一安全交替，一次看清紧凑行的两种配色。
        //
        // ⚠️ **不能只靠出图**：本文件只在 `DE_SNAPSHOTS=1` 下跑，不进 CI。
        // 机器无关的断言在 `MainWindowDiskListTests`（数琥珀条）。
        //
        // 占用样本用与磁盘行同一组 ``procs``（Finder + 图像捕捉，带真实应用身份）——
        // 芯片图标的来源是 `appBundlePath`，编一个只有名字的进程就会画成空方框。
        let multiOccupancy: [String: OccupancyResult] = [
            "/Volumes/Samsung T7": .occupied(procs),
            "/Volumes/WD Blue": OccupancyResult.none,
        ]
        let multiWindow = await ViewFixtures.mainWindow(
            disks: designDisks, occupancy: multiOccupancy)
        try dump(
            multiWindow, width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height, name: "main-window-multi-light")
        try dump(
            multiWindow, width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height, name: "main-window-multi-dark", dark: true)

        let compactDisks = [
            fixtureDisk(name: "Samsung T7", bsd: "disk5s2", total: 1_000_000_000_000, used: 300_000_000_000),
            fixtureDisk(name: "WD Blue", bsd: "disk6s2", total: 500_000_000_000, used: 120_000_000_000),
            fixtureDisk(name: "影音盘", bsd: "disk7s2", total: 2_000_000_000_000, used: 1_700_000_000_000),
            fixtureDisk(name: "备份盘", bsd: "disk8s2", total: 4_000_000_000_000, used: 2_600_000_000_000),
        ]
        // 一忙一安全交替：一次看清紧凑行的两种配色（忙碌的琥珀条 / 安全的绿勾）。
        let compactOccupancy: [String: OccupancyResult] = compactDisks.enumerated().reduce(into: [:]) {
            table, item in
            table[item.element.mountPath] = item.offset.isMultiple(of: 2) ? .occupied(procs) : OccupancyResult.none
        }
        let compactWindow = await ViewFixtures.mainWindow(
            disks: compactDisks, occupancy: compactOccupancy)
        try dump(
            compactWindow, width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height, name: "main-window-compact-light")

        // ---- 菜单栏面板（设计稿 02-menu-bar.html）----
        //
        // **用设计稿里那两块盘，不用本机真实磁盘。**
        //
        // 本机只插了 1 块盘，而 `02-menu-bar.html` 的面板里有 2 块（Samsung T7 忙 /
        // WD Blue 安全）。拿「1 块盘的实现」去比「2 块盘的设计稿」，并排图上会读成
        // 「设计稿 350 / 实现 279，差了 71pt 的排版」—— 而真相是那 71pt 里
        // 69 是第二块盘的行高、2 是外框边框的实现差异（见 `MenuPopoverLayoutTests`）。
        //
        // 出图与对照都必须在**同内容量**下比。磁盘列表与占用结论现在都可注入，
        // 这条就做得到了。
        let designStore = DiskListStore(monitoring: false)
        designStore.replaceDisksForTesting(designDisks)
        // `detect` 收的是**挂载路径**，所以样本进程的 `path` 用传进来的那个（与真机一致）。
        // 两个**应用身份**（`appBundlePath`）从外面捕获进来 —— `String` 是 `Sendable`，
        // 闭包仍满足 `@Sendable`。
        let designOccupancy = OccupancyStore(
            diskStore: designStore,
            detect: { path in
                guard path.hasSuffix("Samsung T7") else { return .none }
                return .occupied([
                    OccupyingProcess(
                        pid: 1234, processName: "Finder", displayName: "Finder",
                        appBundlePath: finderApp, path: path + "/a.mov"),
                    OccupyingProcess(
                        pid: 5678, processName: "图像捕捉", displayName: "图像捕捉",
                        appBundlePath: imageCaptureApp, path: path + "/b.heic"),
                ])
            },
            autoStart: false)
        await designOccupancy.refresh(disks: designDisks)

        let popover = MenuPopoverView(
            store: designStore,
            occupancyStore: designOccupancy,
            accent: .default,
            onOpenMainWindow: {}, onRefresh: {}, onOpenSettings: {}, onQuit: {}, onEject: { _ in })
        try dump(popover, width: DesignTokens.Size.menuPopoverWidth, name: "menu-popover-light")
        try dump(popover, width: DesignTokens.Size.menuPopoverWidth, name: "menu-popover-dark", dark: true)

        // ---- FDA 横幅两种语义（设计稿 04-onboarding.html）----
        // ⚠️ 这两处的实参**必须与 `ContentView.bannerArea` 逐字一致**：
        // 走查图是拿来和真机并排看的，夹具与生产不一致 = 图里看不出线上的问题。
        // （`message` 的类型是 `Text`，就是为了逼调用方在这里做一次显式选择。）
        try dump(
            NoticeBanner(
                kind: .warning,
                icon: "lock",
                message: MarkdownCopy.text(L10n.tr(.fdaBannerLead)),
                actionTitle: L10n.tr(.openSystemSettings),
                accent: .default,
                action: {}),
            width: DesignTokens.Size.mainWindow.width, name: "banner-warning-light")
        try dump(
            NoticeBanner(
                kind: .success,
                icon: "checkmark.circle",
                message: Text(L10n.tr(.fdaGrantedBanner)),
                accent: .default),
            width: DesignTokens.Size.mainWindow.width, name: "banner-success-light")

        // ---- 引导面板（设计稿 04-onboarding.html 第一块）----
        try dump(
            OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}),
            width: DesignTokens.Size.onboardingPanelWidth, name: "onboarding-light")
        try dump(
            OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}),
            width: DesignTokens.Size.onboardingPanelWidth, name: "onboarding-dark", dark: true)

        // ---- 空状态（设计稿 02-menu-bar.html 空状态 / 06-states.html）----
        // 高度 380 与 ContentView 里 `emptyState` 的用法一致。
        try dump(
            EmptyStateView(
                systemName: "externaldrive",
                title: L10n.tr(.noRemovableDisks),
                description: L10n.tr(.insertDiskHint) + "\n" + L10n.tr(.emptyStateFilterHint),
                actionTitle: L10n.tr(.refresh),
                actionSystemImage: "arrow.clockwise",
                action: {},
                accent: .default),
            width: mainW, height: 380, name: "empty-state-light")

        // ---- 两个弹窗（设计稿 03-eject-flow.html，自绘）----
        //
        // 弹窗垫在深色底上出图：设计稿的弹窗是毛玻璃，直接截透明背景会看不出
        // 圆角、描边与阴影（这正是「层级问题只在深色暴露」的原因）。
        let busyModel = EjectAlertModel.busy(disk: disk, occupying: procs)
        let failureModel = EjectAlertModel.failure(disk: disk, failure: .inUse)
        let noProcessModel = EjectAlertModel.busy(disk: disk, occupying: [])

        try dumpAlert(busyModel, name: "alert-busy-light")
        try dumpAlert(busyModel, name: "alert-busy-dark", dark: true)
        try dumpAlert(failureModel, name: "alert-failure-light")
        try dumpAlert(failureModel, name: "alert-failure-dark", dark: true)
        // 无进程可列（未授予完全磁盘访问）—— 没有区块，只剩说明 + 警示。
        try dumpAlert(noProcessModel, name: "alert-busy-noprocess-light")

        // ---- 更新弹窗（设计稿 08-update.html A 段）----
        //
        // ⚠️ **样本值必须与设计稿同源**（1.0.0 → 1.1.0、构建 42 → 58、2026-09-17、
        // 12.4 MB、同样的三条更新）—— 拿从没在设计稿里出现过的样本去并排比，
        // 本来就比不了（同 §8.33 的磁盘/进程样本规则）。
        let updateModel = UpdateAlertBuilder.model(for: Self.designUpdateFixture)
        try dumpAlert(updateModel, name: "update-dialog-light")
        try dumpAlert(updateModel, name: "update-dialog-dark", dark: true)

        // ---- 设置面板「更新」行：各态（设计稿 08-update.html 的 B / C 段）----
        //
        // ⚠️ **状态必须经由生产那个纯函数得出**，不能手写 `.downloading(…)`：
        // 手写等于「夹具自己编了一个状态」，而
        // `rowState(phase:skippedVersion:lastCheck:)` 的**优先级**
        // （进行中 / 受阻六态 > 已跳过 > 已是最新 > 尚未检查）恰恰是最容易搞错的地方。
        // 从 `phase` 走一遍那个函数，出图才同时验证了「判定」与「画法」。
        //
        // ⚠️ **时间戳必须是固定值**（不是 `Date()`）：出图要可复现，
        // 否则每次跑出来的「上次检查」都不一样，两张图 diff 不出真变化。
        //
        // ⚠️ **样本值与设计稿同源**（版本 1.1.0、上次检查 2026-09-17 14:30）。
        let lastCheck = Self.designLastCheck

        // 「自动更新」那两行**按设计稿假设的环境**（具备能力 + 检查开 + 下载关）——
        // 出图进程里 updater 建不起来，真实值恒为「不具备能力」，不注入的话这些图会全带着
        // 一个对不上的行。
        let designAutoUpdate = AutoUpdateRowsState(
            canAutoUpdate: true, checksIsOn: true, downloadsIsOn: false)
        func row(_ phase: UpdatePhase, skipped: String? = nil) -> UpdateController.CheckRowState {
            UpdateController.rowState(phase: phase, skippedVersion: skipped, lastCheck: lastCheck)
        }
        let updateRowStates: [(String, UpdateController.CheckRowState)] = [
            ("never-checked", UpdateController.rowState(phase: .idle, skippedVersion: nil, lastCheck: nil)),
            ("up-to-date", row(.idle)),
            // 2026-09-28 加的那一态（用户报告）：「检查**失败**」与「已是最新」原先共用同一句话。
            // ⚠️ 两态都在清单里 —— 只留一格就等于另一句话再也没人看过（§8.33 的老毛病）。
            (
                "check-failed",
                UpdateController.rowState(
                    phase: .idle, skippedVersion: nil, lastCheck: lastCheck, outcome: .failed)
            ),
            ("skipped", row(.idle, skipped: "1.1.0")),
            // 2026-09-20 加的那一态（§8.93 / §8.97）：用户点了「检查更新」、
            // Sparkle 还没答的那 3~4.5 秒 —— 出图能看见它**有第二行**（否则会矮 14.8pt）。
            ("checking", row(.checking)),
            ("found", row(.found(version: "1.1.0"))),
            ("downloading", row(.downloading(version: "1.1.0", fraction: 0.42))),
            // 2026-09-19 加的那一态（§8.81 / §8.82）：自动那条路的「后台下载中」。
            // 与设计稿 B 段「3b」那一帧对应 —— 百分比无从得知 ⇒ 无进度条、无「取消」。
            ("downloading-unknown", row(.downloading(version: "1.1.0", fraction: nil))),
            ("ready", row(.ready(version: "1.1.0", autoRestart: false))),
            ("readyAuto", row(.ready(version: "1.1.0", autoRestart: true))),
            ("failed", row(.failed(version: "1.1.0"))),
            // 2026-09-22 加的那一态（账本第 43 行）：下载成功、但没装上。
            ("install-failed", row(.installFailed(version: "1.1.0"))),
            // 2026-09-20 加的那一态（§8.94 / §8.95.7）：只读卷 / App Translocation。
            ("location-blocked", row(.locationBlocked)),
        ]
        for (slug, state) in updateRowStates {
            try dump(
                SettingsDetailPage(
                    // ⚠️ **必须显式指到「更新」页**：
                    // 默认页是「通用」，而这一行状态机**只画在「更新」页上** ——
                    // 不指的话这十几张图会全部拍到「通用」，图上**一条更新行都没有**，
                    // 而文件名还叫 `settings-update-*`。看的人只会得出
                    // 「更新行画不出来」这种错误结论，甚至更糟：以为画过了。
                    // 设置在 v3 变成「按分类切换的一页」之后，「拍到哪一页」
                    // 是一个必须说清的维度 —— 单页时代所有内容都在同一屏上，
                    // 它根本不存在。
                    section: .updates,
                    updateStateOverride: state, autoUpdateRowsOverride: designAutoUpdate,
                    takeOverAvailabilityOverride: .usable),
                width: detailWidth,
                height: detailHeight,
                name: "settings-update-\(slug)-light")
        }

        // ---- 「更新」组那两个开关的形态（2026-09-28 拆成两行；设计稿 08-update.html B 段）----
        //
        // ⚠️ **各态图里那两行按设计稿假设的环境渲染**（具备能力 + 检查开）：出图跑在
        // updater 建不起来的 xctest 进程里 → 真实值恒为「不具备能力」→ 每张图会带着
        // 一个与设计稿对不上的行。
        // 「不具备能力」与「检查关」两态由下面的 `blocked` / `checks-off` 单独覆盖，
        // 所以**不会因为「统一按设计稿口径」就把它丢掉** —— 「不具备能力」正是
        // 本机预览模式下真实应用的样子。
        let autoUpdateRows: [(String, AutoUpdateRowsState)] = [
            ("default", designAutoUpdate),
            ("downloads-on", AutoUpdateRowsState(canAutoUpdate: true, checksIsOn: true, downloadsIsOn: true)),
            ("checks-off", AutoUpdateRowsState(canAutoUpdate: true, checksIsOn: false, downloadsIsOn: false)),
            ("blocked", AutoUpdateRowsState(canAutoUpdate: false, checksIsOn: false, downloadsIsOn: false)),
        ]
        for (slug, state) in autoUpdateRows {
            try dump(
                SettingsDetailPage(
                    // 同上：这两行在「更新」页上。
                    section: .updates,
                    autoUpdateRowsOverride: state, takeOverAvailabilityOverride: .usable),
                width: detailWidth,
                height: detailHeight,
                name: "settings-auto-update-\(slug)-light")
        }

        // ---- 「接管访达的推出」那一行的**未授权**态（2026-09-28）----
        //
        // ⚠️ 这一态由**本机给没给完全磁盘访问**决定 —— 任何一台机器都只能处于其中一半，
        // 所以它在真机上**未必画得出来**（授权过的机器上永远看不到）。
        // ⇒ 必须显式注入 + 单独出图，否则它的排版与文案永远没人看过。
        // 同源理由见 ``SettingsSectionPane/updateStateOverride``。
        try dump(
            SettingsDetailPage(section: .general, takeOverAvailabilityOverride: .needsFullDiskAccess),
            width: detailWidth,
            height: detailHeight,
            name: "settings-take-over-needs-fda-light")

        // ---- 五个分类各一张 + 登录项第三态（两栏形态，2026-09-29）----
        //
        // ⚠️ **这一段非有不可**：两栏之后「用户看到哪一页」是一个**新的维度**，
        // 而 `SettingsView` 的默认页是「通用」—— 上面那一大批图（更新各态、两行各态）
        // 都是**显式指定页面**才拍到东西的。不逐页出图的话，外观 / 诊断 / 关于
        // 这三页在走查图里**完全不存在**，而「没画过的页面没人看过」正是本仓库
        // 反复吃亏的那一类（§8.33）。
        for section in SettingsSection.allCases {
            for dark in [false, true] {
                try dump(
                    SettingsDetailPage(
                        section: section, takeOverAvailabilityOverride: .usable),
                    width: detailWidth,
                    height: detailHeight,
                    name: "settings-page-\(section.rawValue)-\(dark ? "dark" : "light")",
                    dark: dark)
            }
        }
        // 登录项的「等待系统批准」第三态：真机上**造不出来**（要 `SMAppService`
        // 真的返回 `.requiresApproval`），只能靠注入口 —— 不出图它永远没人看过。
        // 它也是设计稿 09 页第 2 帧，且是**设计稿最高的一帧**（英文 384.22）。
        //
        // ⚠️ **明暗各出一张**（2026-09-29 补深色）：那行受阻提示行用的是
        // `warningSoft` / `warningText` 两个**明暗自适应**令牌 ——
        // 浅色下量到的是 `#FFF2E0` 底 + `#B25000` 字，深色下换成
        // `rgba(255,159,10,0.16)` 底 + `#FFB340` 字。**两套值都要有人看过**：
        // 只出浅色的话，深色下那行是不是「浅琥珀底配深色字」（= 看不清）没有任何东西知道。
        // 令牌与设计稿逐值相等由 `PaletteColorParityTests` 守，但**渲染结果**只能看图。
        for dark in [false, true] {
            try dump(
                SettingsDetailPage(
                    section: .general,
                    takeOverAvailabilityOverride: .usable,
                    launchAtLoginStateOverride: .requiresApproval),
                width: detailWidth,
                height: detailHeight,
                name: "settings-launch-approval-\(dark ? "dark" : "light")",
                dark: dark)
        }

        // ---- 深色对照（设计稿 07-dark.html）----
        try dump(
            DiskRow(disk: disk, occupancy: .occupied(procs), accent: .default, onEject: {}, density: .regular),
            width: mainW, name: "row-busy-dark", dark: true)
        try dump(
            MenuBarDiskRow(disk: disk, occupancy: .occupied(procs), accent: .default, onEject: {}),
            width: menuW, name: "menurow-busy-dark", dark: true)
        // 上面两张深色图与这两张设置面板图都要**显式注入接管可用性**：
        // 走查图要与设计稿并排看，而设计稿画的是「开关可用」的那一版。
        try dump(
            SettingsDetailPage(section: .general, takeOverAvailabilityOverride: .usable),
            width: detailWidth, name: "settings-light")
        try dump(
            SettingsDetailPage(section: .general, takeOverAvailabilityOverride: .usable),
            width: detailWidth, name: "settings-dark", dark: true)
    }
}
