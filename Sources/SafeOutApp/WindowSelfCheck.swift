import AppKit

/// `--preview-*` 真机自检里**不碰应用状态**的那一半量测函数。
///
/// **为什么单独一个类型**：这些函数**只吃参数、不读任何 `AppDelegate` 成员**，
/// 做成 `static func` 之后这件事就由**编译器**保证（`static` 里没有 `self`）——
/// 而不是靠「我扫过一遍」。想加一个读应用状态的函数，**别放这里**。
///
/// 搬出来的那一半（按源文件顺序）：``trafficLightUnion`` / ``checkTrafficLightBaseline`` /
/// ``measureRedLightInk`` / ``checkRedLightInkShape`` / ``checkEmptyStateInsteadOfSkeleton`` /
/// ``checkSplitAssembly`` / ``checkLiquidGlassBackdrop`` / ``waitUntilAppIsActive``；
/// 需要读窗口/状态属性的入口与 `dump*` 仍在 `SafeOutApp.swift` 里。
///
/// ⚠️ **v3 退役了两条**（主窗口与设置合并时）：``checkTitleBarHorizontalSymmetry``
/// （比的是「红灯中心」与「标题栏里那颗齿轮按钮的中心」——那颗齿轮随 v3 一起删了，
/// 设置已经搬进侧栏）与 ``dumpSettingsWindowState``（整个设置窗口都没了）。
/// **不是能力退步**：「窗口左右两侧的光学对称」在那之后由 26pt 基线 + 侧栏浮岛几何承担。
///
/// ⚠️ 判据是**实测**的（SPEC §8.101.4–§8.101.5）：同一份测量连踩过三次「口径错」，
/// 最终以「能不能编译成 `static func`」为准 —— 编译器是这件事唯一的裁判。
///
/// ⚠️ **搬运的边界口径**（§8.101.5 踩过）：一个函数的「单元」= 它**自己的**文档注释 +
/// 属性行 + 声明 + 函数体。别用「到下一个函数声明前」当区间 —— 那会把**下一个函数的**
/// 文档注释算进来（第一版就是这么错的：4 个函数丢了注释，`waitUntilMainWindowIsKey`
/// 顶上了别人的注释）。验收必须**按顺序**比：多行集合比对是**位置盲**的，查不出错位。
@MainActor
enum WindowSelfCheck {

    // MARK: - 窗口位图抓取（同步）

    /// `CGWindowListCreateImage` 的**动态解析**入口。
    ///
    /// ⚠️ 为什么不直接调它（2026-09-24）：该 API **在 macOS 14.0 被废弃**，而本包的
    /// 部署目标就是 14.0 ⇒ 直接引用会触发 `[#DeprecatedDeclaration]`，在门槛 1 的
    /// `-warnings-as-errors` 下**变成硬错误**（实测：`swift build -Xswiftc -warnings-as-errors`
    /// 报 `WindowSelfCheck.swift:213/378`）。
    ///
    /// 它的官方替代品 ScreenCaptureKit 是**异步 + 需要屏幕录制权限**，而本函数服务于
    /// 「交通灯红灯有没有被标题栏裁掉」「空状态有没有被骨架屏顶掉」这两条**确定性**自检：
    /// 异步化要改整条调用链，权限化会让判据在没授权时**永远量不到** —— 那不是变弱，是**静默失效**。
    /// ⇒ 保留同步旧 API，把「我知道它废弃了」这件事**收在这一处**并写明理由。
    ///
    /// ⚠️ 解析失败返回 `nil`，调用方按「抓不到图」处理（它们本来就有这条分支）。
    /// **不**静默退化成别的取图方式 —— 那会改变判据的坐标口径（见 ``measureRedLightInk``）。
    @MainActor
    private static let windowImageFn:
        (
            @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption)
                -> Unmanaged<CGImage>?
        )? = {
            guard
                let handle = dlopen(
                    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
                let symbol = dlsym(handle, "CGWindowListCreateImage")
            else { return nil }
            return unsafeBitCast(
                symbol,
                to: (@convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption)
                    -> Unmanaged<CGImage>?).self)
        }()

    /// 同步抓指定窗口的位图（``windowImageFn`` 的 Swift 包装，接好内存管理）。
    ///
    /// `CGWindowListCreateImage` 遵循 Create 规则（返回 +1）⇒ 必须 `takeRetainedValue()`。
    @MainActor
    static func captureWindowImage(_ windowID: CGWindowID) -> CGImage? {
        windowImageFn?(.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming)?
            .takeRetainedValue()
    }

    /// 等应用真的变成前台（最多 2 秒）。
    ///
    /// `NSApp.activate(ignoringOtherApps:)` 只是**请求**激活，真正生效要等下一次
    /// 激活通知；而 `NSPopover.show` 在应用不在前台时会**静默失败**（`isShown` 保持 false）。
    @MainActor
    static func waitUntilAppIsActive() async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !NSApp.isActive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 系统交通灯在**窗口坐标**里的并集（原点在左下）。
    ///
    /// 三个按钮各自 `convert(_:to: nil)` 到窗口坐标后再求并集 —— 它们的父视图是
    /// `NSThemeFrame`，直接读 `frame` 拿到的是标题栏容器坐标系，与窗口坐标**不是一回事**
    /// （实测差一个标题栏高度，会把「距顶 16pt」算成「距顶 550pt」）。
    static func trafficLightUnion(in window: NSWindow) -> NSRect {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(NSRect.null) { $0.union($1) }
    }

    /// 核对「系统交通灯的垂直中心」与「内容区头部带的中心」是否重合，并打印数字。
    ///
    /// **为什么这条断言必须存在**：交通灯的位置由 AppKit 决定，而内容带高度
    /// ``DesignTokens/Size/titleBarBandHeight`` 是**设计稿给的** 52（三者共用同一条
    /// 基线这件事的判据见 `MainDetailHead`）。
    ///
    /// ## v3 之后它守的东西**更重要了**，而不是更少了
    ///
    /// v2 时代我们靠 ``AppDelegate/alignTrafficLights(in:)`` 手工把灯挪到 26pt，
    /// 于是这条断言守的是「那个机关有没有生效」。v3 起那个机关退役了 ——
    /// 灯的位置**完全由 AppKit 按「这个窗口有没有工具栏」决定**（实测有工具栏 26pt、
    /// 去掉工具栏立刻掉到 16pt）。⇒ 这条断言现在守的是
    /// **「工具栏还在不在」**：它一旦被去掉，这里会立刻红，而界面上只是「标题与红绿灯
    /// 差 10pt」那种不显眼的错位（HANDOFF §3.1.1 的四行代价表）。
    ///
    /// 而**离屏出图结构上测不到**这件事：离屏没有窗口，也就没有交通灯。
    ///
    /// 断言的是**两个数**：交通灯中心距窗口顶的距离，与内容带高度的一半。
    /// 前者不对时，把 ``DesignTokens/Size/systemTrafficLightCenterFromTop``
    /// 改成失败信息里的实测值即可。
    ///
    /// - Returns: 交通灯并集（取不到时为 `.null`），供调用方接着做别的判断。
    @discardableResult
    static func checkTrafficLightBaseline(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> NSRect {
        let lights = trafficLightUnion(in: window)
        guard !lights.isNull else {
            mismatches.append("\(label) 取不到交通灯位置（standardWindowButton 全为 nil）")
            return .null
        }
        // 窗口坐标原点在左下 → 「距顶」= 窗口高 − y。
        let centerFromTop = window.frame.height - lights.midY
        let band = DesignTokens.Size.titleBarBandHeight
        let expected = band / 2
        print("    交通灯并集=\(lights) 垂直中心距顶=\(centerFromTop)pt（内容带 \(band)pt 的中心应为 \(expected)pt）")
        if abs(centerFromTop - expected) > 1 {
            mismatches.append(
                "\(label) 交通灯垂直中心距顶 \(centerFromTop)pt，内容带中心 \(expected)pt，"
                    + "相差 \(centerFromTop - expected)pt —— 标题与红绿灯不在同一条基线上。"
                    + "v3 起这个位置**全由 AppKit 按「窗口有没有工具栏」决定**"
                    + "（实测：有工具栏 26pt / 去掉工具栏 16pt，差的就是这 10pt）"
                    + "⇒ 先查 ``AppDelegate/makeMainWindow()`` 里那句 `win.toolbar` 还在不在、"
                    + "`toolbarStyle = .unified` 有没有被改，而不是去补一个补偿常量")
        }
        return lights
    }

    /// 红灯在**真机渲染出来的像素**里的墨迹范围（图像坐标，**原点在左上**）。
    ///
    /// ⚠️ **两个轴都要量**：2026-09-23 那次「灯被裁掉下半部分」的缺陷里，
    /// `frame` 层面的判据（``checkTrafficLightBaseline`` 量并集中心）**一直是绿的** ——
    /// 被裁的是**绘制**，不是 frame。只有「高」这个数会说话。
    struct RedLightInk: Equatable {
        /// 墨迹中心距窗口**左边**（pt）。设计稿锚点 ``DesignTokens/Size/titleBarInsetCenter``。
        var centerX: CGFloat
        /// 墨迹中心距窗口**顶**（pt）。设计稿要的是内容带中心（52 / 2 = 26）。
        var centerYFromTop: CGFloat
        /// 墨迹宽度（pt）。12pt 的圆在 2x 下是 24px。
        var width: CGFloat
        /// 墨迹高度（pt）。**被裁掉下半部分时它只有宽度的一半** —— 判据就架在这上面。
        var height: CGFloat
        /// 扫到的红色像素个数（自证字段：太少说明没抢到前台，灯被画成了灰色）。
        var count: Int
    }

    /// 从**真机渲染的像素**里量红灯的墨迹范围，兜住「frame 对了但画出来的不对」。
    ///
    /// **为什么必须有这条**：``checkTrafficLightBaseline`` 量的是三个按钮 **`frame`**
    /// 的并集中心 —— 那是 AppKit 的布局数据，不是屏幕上的墨迹。两者在 2026-09-23
    /// 那次缺陷里**明确分叉**（frame 一直是 26.0pt、画出来的是半圆）。
    /// 这里绕开 frame，直接**数屏幕上的红色像素**，是独立的一条证据。
    ///
    /// ⚠️ v3 起它多了一层含义：交通灯的 frame 已经**不再由我们改**（``alignTrafficLights``
    /// 退役），所以「frame 与墨迹分叉」的旧根因没了 —— 但这条**仍然要留着**：
    /// 它现在是「标题栏那 52pt 区域有没有被裁」的唯一判据，而那个高度由**工具栏**提供。
    /// 工具栏一旦消失，灯掉到 16pt 且照样被裁成半圆。
    ///
    /// **扫描范围为什么只取左上角那一块**：主窗口里有 `.btn--danger` 红色按钮
    /// （「关闭并推出」），全窗口扫红色会把那些按钮也算进来 —— 与「量不到」
    /// 一样会让数字失去意义。那块按钮在内容区，所以「左上角 200pt × 内容带高」
    /// 这个框里只可能是红灯。
    /// ⚠️ v3 起侧栏浮岛顶边距窗顶 8pt、红绿灯浮在**它上面**，横向仍在 200pt 以内 ⇒ 框不用改。
    ///
    /// ⚠️ **y 的范围是 0…内容带高，不是「内容带中心 ± 7」**（2026-09-23 改）。
    /// 原来那 ±7pt 的窄条**恰好把「被裁」这个形状裁掉了**：灯的下缘掉出 33pt 时，
    /// 窄条里剩下的部分看起来仍然「有墨迹、量得到中心」—— 缺陷因此躲过了所有守卫。
    /// 要判「是不是圆」，扫描框必须**比灯大**。
    ///
    /// - Returns: 量到的墨迹范围；量不到（或不可信）时为 `nil`，并已把原因写进 `mismatches`。
    static func measureRedLightInk(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> RedLightInk? {
        let scale = window.backingScaleFactor
        let band = DesignTokens.Size.titleBarBandHeight
        // ⚠️ 从 **0** 开始扫（不是从内容带中心往上数）：要看见「掉出去的那一截」，
        //    框的上边界必须贴着窗口顶。
        let y0 = 0
        let y1 = Int(band * scale)
        let xLimit = Int(200 * scale)

        // ⚠️ **交通灯的红色只在窗口处于活跃态时才画**（2026-09-17 实测）：
        // 应用还没抢到前台时，系统把三个灯画成**灰色** —— 窗口已上屏、内容墨迹正常，
        // 但红色像素是 **0**。抓一次就断言，会把「还没激活完」误报成「红灯没画出来」，
        // 于是这条断言**偶发变红**（实测约 1/3 次），跑久了没人再看它 ——
        // 一个会随机变红的守卫比没有守卫更糟。
        //
        // 所以这里**轮询重试**，而不是抓一次就下结论：每轮之间跑一次 run loop，
        // 让 AppKit 有机会把标题栏按活跃态重画。重试只在「数不可信」时发生，
        // **红灯真的画歪了不会重试**（那时 count 仍是合理的 450 上下，直接走下面的中心断言）。
        var count = 0
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
        var pixelsWide = 0
        let deadline = Date().addingTimeInterval(3)
        while true {
            let windowID = CGWindowID(window.windowNumber)
            if let cg = Self.captureWindowImage(windowID) {
                // `NSBitmapImageRep(cgImage:)` 在 macOS 上**不是** Optional，不能放 `guard let` 里。
                let rep = NSBitmapImageRep(cgImage: cg)
                pixelsWide = rep.pixelsWide
                count = 0
                minX = Int.max
                maxX = Int.min
                minY = Int.max
                maxY = Int.min
                for y in y0..<min(rep.pixelsHigh, y1) {
                    for x in 0..<min(rep.pixelsWide, xLimit) {
                        guard let c = rep.colorAt(x: x, y: y) else { continue }
                        // 红灯 ≈ #FF5F57：红分量高、且明显压过绿蓝。
                        let isRed =
                            c.redComponent > 0.7
                            && c.redComponent - c.greenComponent > 0.25
                            && c.redComponent - c.blueComponent > 0.2
                        if isRed {
                            count += 1
                            if x < minX { minX = x }
                            if x > maxX { maxX = x }
                            if y < minY { minY = y }
                            if y > maxY { maxY = y }
                        }
                    }
                }
                // **自证**：12pt 直径的圆在 2x 下约 450 个像素。太少说明只扫到抗锯齿边缘，
                // 太多说明把别的东西（红色按钮、窗口外内容）扫了进来 —— 两种都不能算通过。
                if count > 50, count < 4000 { break }
            }
            guard Date() < deadline else { break }
            // 跑一次 run loop：激活状态的变化要靠它才会变成一次重绘。
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        guard count > 50, count < 4000 else {
            // **失败信息必须能分辨两种原因**：环境（没抢到前台 → 灯是灰的）还是缺陷。
            // 第一版只说「这个数不可信」，排查时得自己重跑一遍才知道是哪种。
            let inactive = !window.isKeyWindow || !NSApp.isActive
            mismatches.append(
                "\(label) 标题栏那一条里扫到 \(count) 个红色像素（12pt 圆的合理量级是 200…900）——"
                    + "当时 NSApp.isActive=\(NSApp.isActive) 主窗口isKey=\(window.isKeyWindow) "
                    + "图像宽=\(pixelsWide)px。"
                    + (count == 0 && inactive
                        ? "**应用没抢到前台**，系统把交通灯画成了灰色 —— 这是环境问题，"
                            + "不是布局缺陷；在交互式终端里重跑，或先点一下窗口再跑。"
                        : "要么玻璃没渲染完，要么扫描范围把红色按钮包了进来。这个数不可信"))
            return nil
        }
        // ⚠️ `NSBitmapImageRep.colorAt(x:y:)` 的 y **从图像顶部数**（图像是
        //    `CGWindowListCreateImage` 抓的位图）⇒ `minY` 直接就是「距窗口顶」，
        //    **不要**再拿窗口高去减。上面那个 `y0 = 0` 也是同一个坐标系。
        let ink = RedLightInk(
            centerX: CGFloat(minX + maxX) / 2 / scale,
            centerYFromTop: CGFloat(minY + maxY) / 2 / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale,
            count: count)
        print(
            "    红灯墨迹（真机像素）=宽 \(ink.width)pt × 高 \(ink.height)pt "
                + "中心=(距左 \(ink.centerX)pt, 距顶 \(ink.centerYFromTop)pt) 像素数=\(ink.count)")
        return ink
    }

    /// 红灯**画出来必须是圆的** —— 这条守的是「标题栏把灯裁掉下半部分」。
    ///
    /// ## 为什么非要有它（2026-09-23，用户反馈「红绿灯下半部分被 UI 挡住」）
    ///
    /// 改前的所有守卫**对这件事全瞎**：
    ///
    /// | 既有守卫 | 为什么看不见 |
    /// |---|---|
    /// | ``checkTrafficLightBaseline`` | 量的是三个按钮 `frame` 并集的中心 ⇒ **一直 26.0pt** |
    /// | 离屏快照 | 离屏**没有窗口**，也就没有系统画的灯 |
    ///
    /// 而缺陷是**绘制**层面的：macOS 标题栏只有 28pt 且 `masksToBounds = true`，
    /// 把灯的下半部分裁掉。真机实测墨迹 **24×16 px**（本该 24×24）。
    /// ⇒ v2 的修法是把标题栏区域手工加高到 52pt（``AppDelegate/enlargeTitleBar(in:)``，
    /// 已退役）；**v3 起这 52pt 由 `NSToolbar` 给**，我们不再写任何一行去撑它
    /// —— 但**判据原样留着**：它现在守的是「工具栏还在不在」。
    ///
    /// ## 判据（纯函数 ⇒ 可以离屏单测）
    ///
    /// 1. **圆**：`|宽 − 高| ≤ 2pt`（抗锯齿会吃掉边界像素，2pt 留给它）；
    /// 2. **竖直中心**：距顶应等于内容带中心（26pt），容差 1.5pt。
    ///
    /// 两条指向同一个根因，但**不能只留一条**：只判「圆」会漏掉「灯整体被挪了但没被裁」；
    /// 只判中心会漏掉「中心看着对、其实只画了一半」。
    /// ⚠️ 反过来说，**它们也不是互相独立的证据**：被裁时墨迹中心必然上移
    /// （裁的是下缘）⇒ 两条会**同时**红。这不是重复判据，是**同一根因的两个方向**
    /// —— 报错信息里要把这个从属关系写清楚，免得读的人以为是两个毛病。
    ///
    /// ⚠️ 本函数**只吃参数、不抓图** —— 于是单测能拿合成样本喂它（完整圆 / 半圆），
    /// 而抓图那半（``measureRedLightInk``）只能真机跑。**这是有意的切分**：
    /// 判据进得了门槛，量测进不了。
    static func checkRedLightInkShape(ink: RedLightInk?, label: String, mismatches: inout [String]) {
        // 量不到时 `measureRedLightInk` 已经把原因（多半是没抢到前台）写进 mismatches 了，
        // 这里再报一条只会让同一件事看起来像两个毛病。
        guard let ink else { return }
        let band = DesignTokens.Size.titleBarBandHeight
        let expected = band / 2
        if abs(ink.width - ink.height) > 2 {
            mismatches.append(
                "\(label) 红灯墨迹是 \(ink.width)×\(ink.height)pt，**不是圆的** —— "
                    + "宽比高大 \(ink.width - ink.height)pt。这是「标题栏把灯裁掉了」的形状："
                    + "`NSTitlebarView` 只有 28pt 高且 masksToBounds=true，"
                    + "而中心 26pt 的灯要占到 34pt ⇒ 下缘被裁。"
                    + "v3 起那 52pt 由 `NSToolbar` 提供 ⇒ 检查 "
                    + "``AppDelegate/makeMainWindow()`` 里 `win.toolbar` / "
                    + "`toolbarStyle = .unified` 还在不在（去掉工具栏实测灯会掉到 16pt）")
        }
        if abs(ink.centerYFromTop - expected) > 1.5 {
            mismatches.append(
                "\(label) 红灯墨迹的竖直中心距顶 \(ink.centerYFromTop)pt，"
                    + "内容带中心应为 \(expected)pt（差 \(ink.centerYFromTop - expected)pt）—— "
                    + "⚠️ 灯被裁掉一部分时**墨迹中心必然上移**（裁的是下缘），"
                    + "所以这个偏差通常是「被裁」的副产品：先看上面那条「是不是圆」")
        }
    }

    /// 无外置磁盘时，列表区必须画**空状态**，而不是卡在首屏骨架层。
    ///
    /// **为什么只有真机测得到**：`cacheDisplay` 不跑 SwiftUI 的 `.task`
    /// （没有事件循环），离屏渲染时两个状态位都停在初始值 `false` ——
    /// 无论实现对不对，离屏结果都一样。**结构上测不到**，与交通灯同类。
    ///
    /// **判据**：数列表区（标题栏以下）的**深色像素**。
    /// 空状态有图标 + 标题 + 两行说明 + 按钮，墨迹成千；
    /// 骨架层只有 `Palette.subtle` 的浅灰圆角块，**几乎没有深色墨迹** ——
    /// 两者量级差得远，不需要精细阈值。
    ///
    /// **列表非空时跳过**：那时列表区画的是磁盘行（也有大量深色文字），判据不成立。
    /// 跳过而不是硬跑 —— 假红比不测更糟。
    ///
    /// ⚠️ **`diskStore` 必须是窗口里那个视图真正在读的 store**，不能写 `DiskListStore.shared`：
    /// 空状态自检（`--preview-main-window-empty-keys`）注入的是一个**独立实例**，
    /// 拿 `.shared` 去数「有几块盘」会读到真实硬件，然后心安理得地跳过 —— 断言静默失效。
    ///
    /// **这个「跳过」曾经是常态**（2026-09-17 查明）：列表来源硬编码 `.shared`，
    /// 而开发者本机长期插着盘 —— 于是这条断言只在少数时候执行。
    /// 注入点就位后，它在**任何硬件状态下**都能跑。
    /// ⚠️ **`detailLeftInset` 必须由调用方给准**（v3 新增）：侧栏也在画文字，
    /// 而且它**恒有** 7 行内容 ⇒ 全窗口扫「深色像素」时侧栏会稳定贡献数千个，
    /// 把下面那条 2000 的阈值彻底架空（骨架层 + 侧栏一起也能过）。
    /// ⇒ 判据只在**详情区**那一块里量：`x ≥ detailLeftInset`。
    /// 实测（macOS 26）详情区左缘 = **208pt**（侧栏面板本体 200 + 系统内缩 8），
    /// 见 `Design/ui/v3/HANDOFF.md` §3.3。
    static func checkEmptyStateInsteadOfSkeleton(
        window: NSWindow, diskStore: DiskListStore, detailLeftInset: CGFloat = 0,
        label: String, mismatches: inout [String]
    ) {
        let diskCount = diskStore.disks.count
        guard diskCount == 0 else {
            print("    空状态核对：跳过（本次渲染用的列表有 \(diskCount) 块磁盘，列表区画的是磁盘行）")
            return
        }
        // ⚠️ **判据只在浅色外观下成立**：深色底本身就是「深色像素」，
        // 整屏都会被算成墨迹，这条断言会假绿。深色模式跳过，不硬跑。
        // ⚠️ **深色外观下必须跳过，不能硬跑**：深色底本身就是「深色像素」，
        // `listInk` 会无条件远超阈值 —— 那不是通过，是**假绿**。
        //
        // ⚠️ 而这条跳过在 `--preview-main-window-empty-keys` 下**不应该发生**：
        // 那个模式会把窗口切成浅色（见 ``runMainWindowPreview``），判据要什么底就给什么底。
        // 留着它是防御 —— 万一外观强制没生效，宁可跳过也不要假绿。
        guard window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua else {
            print(
                "    空状态核对：跳过（当前是深色外观，「深色像素」判据不成立 —— "
                    + "深色底上这条断言会无条件假绿）")
            return
        }
        let windowID = CGWindowID(window.windowNumber)
        guard let cg = Self.captureWindowImage(windowID) else {
            mismatches.append("\(label) 抓不到主窗口图像，无法核对空状态")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = window.backingScaleFactor
        let band = DesignTokens.Size.titleBarBandHeight

        /// 数指定 y 带、**详情区那一列**里的深色像素。见 `detailLeftInset` 的说明。
        let x0 = max(0, Int(detailLeftInset * scale))
        func darkCount(fromTop y0: CGFloat, to y1: CGFloat) -> Int {
            let a = max(0, Int(y0 * scale))
            let b = min(rep.pixelsHigh, Int(y1 * scale))
            guard a < b, x0 < rep.pixelsWide else { return 0 }
            var n = 0
            for y in a..<b {
                for x in x0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.redComponent < 0.75 || c.greenComponent < 0.75 || c.blueComponent < 0.75 {
                        n += 1
                    }
                }
            }
            return n
        }

        // **自证**：头部那条带里必须先有墨迹（标题「外置磁盘」+ 右上刷新图标），
        // 否则是玻璃没渲染完 —— 那种情况下列表区也一定是空的，会把「没渲染」误读成「骨架层」。
        //
        // ⚠️ v3 起这块带在**详情区顶部**（x ≥ 208），不再是「整个标题栏那一横条」；
        // 侧栏那 52pt 里第一行还没开始（第一行落在下方 44pt 处），量不到任何东西。
        let titleInk = darkCount(fromTop: 0, to: band)
        guard titleInk > 50 else {
            mismatches.append(
                "\(label) 详情区顶部那条带里只数到 \(titleInk) 个深色像素 —— 窗口还没渲染完，"
                    + "这次的列表区结果不可信（不能当作「画了骨架」）")
            return
        }

        let listInk = darkCount(fromTop: band, to: window.frame.height)
        // **阈值是变异验证定出来的，不是拍的**：
        // 实测空状态 **11175 ~ 11210**（强制浅色 / 原生浅色各量一次）、
        // 把 bug 造回去（强制显示骨架）后 **394** —— 差 28 倍。
        // 取 2000：离两边都有 5 倍余量，既不因抗锯齿抖动误报，也不漏掉骨架。
        // ⚠️ 第一版阈值写的 200，变异后 394 **照样绿** —— 断言看着在守，其实守不住。
        // **动这个数之前先重跑一次变异验证。**
        let emptyStateInkFloor = 2000
        print(
            "    空状态核对：标题栏墨迹=\(titleInk) 列表区墨迹=\(listInk)"
                + "（空状态实测 11175~11210，骨架层 ≈394，阈值 \(emptyStateInkFloor)）")
        if listInk < emptyStateInkFloor {
            mismatches.append(
                "\(label) 这次渲染用的列表里没有磁盘，列表区却只数到 \(listInk) 个深色像素 —— "
                    + "画的多半是**首屏骨架层**（浅灰圆角块，没有文字），而不是空状态。"
                    + "空状态有图标 + 标题 + 说明 + 按钮，墨迹应是数千量级。"
                    + "判据见 ContentView.showsSkeleton —— 骨架只能由「首屏加载结束」关闭，"
                    + "不能依赖 onChange(of: disks)（无盘时列表永远不变，那个回调不会触发）")
        }
    }

    /// 真机判据：**v3 那条工具栏还在不在、侧栏 / 详情区装配对不对**，并返回详情区左缘。
    ///
    /// ## 为什么这几条必须真机量
    ///
    /// 它们都**只有上屏之后**才成立（离屏搭不出窗口 → 没有工具栏 → 侧栏不浮、灯不在 26pt）。
    /// 而它们每一条**去掉都不会编译错**，只会让界面悄悄变旧：
    ///
    /// | 判据 | 去掉它的后果 |
    /// |---|---|
    /// | `window.toolbar != nil` + `toolbarStyle == .unified` | 红绿灯 26→**16pt**、侧栏浮岛上内缩 8→**32pt**（HANDOFF §3.1.1 实测四行） |
    /// | 侧栏是 `.sidebar` 行为的 split item | 侧栏变**贴边通高**、浮岛圆角与材质全没（拿不到系统那层外观） |
    /// | 侧栏 min == max == 200 | 用户能拖宽/拖窄，而设计稿是锁定宽度 |
    /// | `canCollapse == false` | 折叠钮已删，折起来之后**没有任何 UI 能把用户救回来** |
    /// | **详情区 view 顶距窗口顶 = 0** | 52pt 头部带整条下移 ⇒ 标题与红绿灯差一条带子（v3 实测：不关安全区时头部带量成 104pt、标题中心掉到 78pt） |
    ///
    /// ## 侧栏几何**故意不作为判据、只打印**
    ///
    /// macOS 26 上它是「四边内缩 8pt 的圆角浮岛」，14–15 上按官方表述是**贴边通高**——
    /// **两代都对**（HANDOFF §7）。把 8pt 写成断言，等于给 14–15 发一张
    /// 「永远红、且红得没有意义」的票。⇒ 只断言两代都成立的「侧栏本体至少 200pt 宽」，
    /// 另外把量到的内缩打出来供人眼核对。
    ///
    /// - Returns: 详情区左缘（窗口坐标，pt）。**拿不到时返回 0**（此时已经报了 mismatch），
    ///   调用方拿它当 ``checkEmptyStateInsteadOfSkeleton(detailLeftInset:)`` 的入参。
    @discardableResult
    static func checkSplitAssembly(
        window: NSWindow, content: MainWindowContentController, label: String,
        mismatches: inout [String]
    ) -> CGFloat {
        if window.toolbar == nil {
            mismatches.append(
                "\(label) 主窗口没有工具栏 —— v3 的那条 52pt 安全带、让头部带透出来、"
                    + "拖拽区、以及**红绿灯居中到 26pt** 全靠它。"
                    + "实测去掉后红绿灯掉到 16pt、侧栏浮岛上内缩从 8 变 32（HANDOFF §3.1.1）")
        }
        if window.toolbarStyle != .unified {
            mismatches.append(
                "\(label) toolbarStyle = \(window.toolbarStyle)（\(window.toolbarStyle.rawValue)），"
                    + "设计稿要的是 `.unified` —— 圆角与浮岛形态都按这一档实测（§3.7.1）")
        }

        let items = content.splitViewItems
        guard items.count == 2 else {
            mismatches.append("\(label) split 应有 2 个 item（侧栏 + 详情区），实得 \(items.count)")
            return 0
        }
        let sidebar = items[0]
        let detail = items[1]

        if sidebar.behavior != .sidebar {
            mismatches.append(
                "\(label) 侧栏 item 的 behavior 是 \(sidebar.behavior)，不是 `.sidebar` —— "
                    + "浮岛 / 圆角 / 玻璃 / 选中态全靠它（拿 `NSSplitViewItem(viewController:)` "
                    + "建出来的只是普通分栏，外观会退回老形态）")
        }
        let lockWidth = DesignTokens.Size.mainSidebarWidth
        if abs(sidebar.minimumThickness - lockWidth) > 0.5
            || abs(sidebar.maximumThickness - lockWidth) > 0.5
        {
            mismatches.append(
                "\(label) 侧栏宽度没有锁死：min=\(sidebar.minimumThickness) "
                    + "max=\(sidebar.maximumThickness)，应为 \(lockWidth)/\(lockWidth)（设计稿锁宽）")
        }
        if sidebar.canCollapse {
            mismatches.append(
                "\(label) 侧栏 `canCollapse = true` —— 折叠钮在 v3 已删，折起来之后"
                    + "没有任何 UI 能把用户救回来（设计稿第 3 轮定案不给折叠）")
        }

        // 几何：转成窗口坐标（原点左下）再比。
        // ⚠️ 侧栏 / 详情区的 view 是 `NSHostingView`，**是 flipped 的** ——
        // 直接读 `bounds` 会与窗口坐标 y 轴相反（同 `dumpMainWindowState` 里那条提醒）。
        let windowHeight = window.frame.height
        let sideRect = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: nil)
        let detailRect = detail.viewController.view.convert(detail.viewController.view.bounds, to: nil)
        let sideTop = windowHeight - sideRect.maxY
        let detailTop = windowHeight - detailRect.maxY
        print(
            String(
                format: "    装配：侧栏 x∈[%.1f, %.1f] 顶距=%.1f 宽=%.1f | 详情区 左缘=%.1f 顶距=%.1f 宽=%.1f | 窗口高=%.1f",
                sideRect.minX, sideRect.maxX, sideTop, sideRect.width, detailRect.minX,
                detailTop, detailRect.width, windowHeight))

        if abs(detailTop) > 0.5 {
            mismatches.append(
                "\(label) 详情区 view 的顶距是 \(detailTop)pt，应为 0（内容延伸进标题栏）—— "
                    + "它一不对，头部那 52pt 带就整条下移、标题与红绿灯差一条带子。"
                    + "查 `styleMask` 里的 `.fullSizeContentView`、以及那两个宿主控制器的 "
                    + "`safeAreaRegions`（详情区必须关掉，侧栏**故意不关**）")
        }
        if sideRect.width < lockWidth - 0.5 {
            mismatches.append(
                "\(label) 侧栏面板本体只有 \(sideRect.width)pt，应 ≥ \(lockWidth) —— "
                    + "面板太窄时文字会被截断（「设置」那五个分类名放不下）")
        }

        return detailRect.minX
    }

    /// 真机判据：macOS 26 起，**真机**上玻璃底衬必须走 Liquid Glass。
    ///
    /// **为什么要有这一条**：离屏通路（出图与像素判据）**故意**退回 `NSVisualEffectView`
    /// —— Liquid Glass 在离屏渲染里是不透明浅色，会让「透明 / 色调」两种风格画成一样、
    /// 走查图也失真（实测数据见 `EnvironmentValues.offscreenRendering` 那张表）。
    /// 于是「26 上到底走没走 Liquid Glass」这件事**只剩真机能问** —— 就是这里。
    ///
    /// ⚠️ 只认**我们自己画的**那块（``GlassBackdrop/isOurs``）：系统标题栏在 26 上也是
    /// 同一种视图，算进来的话，「我们自己那块退回了旧材质」时这条断言仍然会通过。
    @MainActor
    static func checkLiquidGlassBackdrop(
        _ glasses: [(frame: CGRect, kind: GlassBackdrop)],
        label: String,
        mismatches: inout [String]
    ) {
        guard #available(macOS 26.0, *) else { return }
        let ours = glasses.filter { $0.kind.isOurs }
        guard !ours.isEmpty else {
            mismatches.append("\(label) 没找到自定义玻璃 —— 背景没铺上")
            return
        }
        if !ours.contains(where: { $0.kind == .liquidGlass }) {
            mismatches.append(
                "\(label) 本机是 macOS 26 起，玻璃底衬应当走 Liquid Glass，实际："
                    + ours.map(\.kind.label).joined(separator: "、"))
        }
    }

}
