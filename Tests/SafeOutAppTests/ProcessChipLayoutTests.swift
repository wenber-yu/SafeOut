import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 进程芯片（``ProcessChip``）的**布局契约**测试。
///
/// **为什么需要**：主窗口里「图标 + 应用名」这两样东西必须落在背景色块的**正中央**。
/// 这件事没有编译期约束——历史上正是靠 `.padding(.top, 8) / .padding(.bottom, 3)` 这种
/// 非对称内边距凑出来的，结果内容在色块里下压 2.5pt（上留白 9.5pt / 下留白 4pt），
/// 肉眼就是「没居中、贴着底边」，而且改一个数不会让任何测试变红。
///
/// 现在居中由 `.frame(height: DesignTokens.Size.processChipHeight)` 的结构保证，
/// 本测试把该内高钉死：一旦有人重新用非对称 padding（或删掉这个 frame）凑高度，
/// 渲染出的实际高度就会偏离契约值，测试立刻变红。
@MainActor
struct ProcessChipLayoutTests {

    /// 造一个标签并返回它的**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    private func renderedSize(name: String) -> CGSize {
        // `NSApp` 这个全局由 AppKit 建共享实例时赋值；宿主一个 SwiftUI 视图前必须先起它，
        // 否则 SwiftUI 内部拿 `NSApp` 会崩在隐式解包上。
        _ = NSApplication.shared
        let chip = ProcessChip(
            process: OccupyingProcess(pid: 4242, processName: name, path: "/Volumes/Demo/clip.mp4"))
        let hosting = NSHostingController(rootView: chip)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize
    }

    @Test func 背景色块内高等于契约值() {
        let size = renderedSize(name: "DemoApp")
        #expect(
            size.height == DesignTokens.Size.processChipHeight,
            "芯片实际内高 \(size.height)pt ≠ 契约值 \(DesignTokens.Size.processChipHeight)pt——色块高度不是由 frame 固定的（很可能又用非对称 padding 凑数，那会让内容在色块里上下不居中）"
        )
    }

    /// 内高必须**大于**图标高，且差值可被上下**均分**——这是「内容垂直居中」的几何前提。
    @Test func 图标上下留白可均分() {
        let extra = DesignTokens.Size.processChipHeight - DesignTokens.Size.processChipIcon
        #expect(extra > 0, "色块内高必须大于图标高，否则图标会被压扁/裁切")
        #expect(extra.truncatingRemainder(dividingBy: 2) == 0, "上下留白应是整数点，避免半像素渲染")
    }

    /// 宽度至少要放下「左右内边距 + 图标 + 图标与文字间距 + 文字」，否则内容会被挤出色块。
    @Test func 宽度吃得住图标与文字() {
        let size = renderedSize(name: "DemoApp")
        let minimum = 16 + DesignTokens.Size.processChipIcon + 6
        #expect(size.width > minimum, "芯片渲染宽度 \(size.width)pt 未超过仅有图标时的最小宽度 \(minimum)pt")
    }

    /// 造一个 `displayName` / `processName` 各异的标签并返回渲染宽度。
    private func renderedWidth(displayName: String, processName: String) -> CGFloat {
        _ = NSApplication.shared
        let chip = ProcessChip(
            process: OccupyingProcess(
                pid: 4242, processName: processName, displayName: displayName,
                path: "/Volumes/Demo/clip.mp4"))
        let hosting = NSHostingController(rootView: chip)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.width
    }

    /// **回归**：标签里渲染的是**应用名**（``OccupyingProcess/displayName``），不是进程可执行名。
    ///
    /// 用户报的现象是「应用叫 Bunny，界面显示 IMVIDEO」。这里用**渲染宽度**做判据：
    /// 把长字符串放到 `processName`、短字符串放到 `displayName`，再交换一次比宽度——
    /// 宽度跟着 `displayName` 走就证明渲染的确实是它。
    /// （变异：把 `Text(process.displayName)` 改回 `Text(process.processName)`，大小关系反转。）
    @Test func 渲染的是应用名而不是进程可执行名() {
        let longName = "IMVIDEO-NOT-SHOWN-NAME"
        let shortName = "Bunny"
        let shortAsDisplayName = renderedWidth(displayName: shortName, processName: longName)
        let longAsDisplayName = renderedWidth(displayName: longName, processName: shortName)
        #expect(
            shortAsDisplayName < longAsDisplayName,
            "芯片宽度没跟着 displayName 走（短名 \(shortAsDisplayName)pt / 长名 \(longAsDisplayName)pt）——很可能渲染的是 processName"
        )
    }

    // MARK: - 图标：有应用身份时必须画**真图标**，不是回落的空方框
    //
    // ## 这条守卫是怎么来的（2026-09-17，用户报「应用图标又不显示了」）
    //
    // 用户看走查图 `main-window-multi-light.png`，看到进程芯片的图标位是**空方框**。
    // 查下来不是产品缺陷，而是**出图夹具**的错：夹具的进程是编的（PID 501 / 5340…），
    // 本机并不存在，于是 `proc_pidpath` 取不到路径 → `ProcessAppResolver.icon(for:)`
    // 返回 `nil` → `ProcessChip` 回落成 SF Symbol `app`（那个空方框）。
    // 夹具已修（见 `SnapshotRenderTests.SampleApp`）。
    //
    // 但**修完夹具还缺一条断言**：整个仓库此前**没有任何测试**盯住
    // `ProcessChip.iconView` 这个 `if let … else` 分支的**接线**。
    // `ProcessAppResolverTests` 只测了解析器本身（「有 bundle 时 icon(for:) 非 nil」），
    // 没测「视图有没有真的把它画出来」—— 这正是本项目反复踩的
    // 「判定逻辑测了、接线没测」（另见 `EmptyStateTests` / `MainWindowDiskListTests` 文件头）。
    // 缺了它，把 `iconView` 整个换成固定 `Image(systemName: "app")` 也全绿。

    /// 图标槽（pt，原点左上）。
    ///
    /// 由 ``ProcessChip`` 的结构算出来，不是量出来的：
    /// `HStack(spacing: 6) { iconView.frame(20×20); Text }` + `.padding(.leading, 3)`
    /// + `.frame(height: 26)` → x ∈ [3, 23]、y ∈ [(26−20)/2, …]。
    /// 只取**左半**槽（宽 10pt）：右半可能蹭到文字的抗锯齿边。
    private var iconSlot: CGRect {
        let side = DesignTokens.Size.processChipIcon
        let inset = (DesignTokens.Size.processChipHeight - side) / 2
        return CGRect(x: 3, y: inset, width: side / 2, height: side)
    }

    /// 图标槽里**彩色像素**的个数：`max(通道) − min(通道) > 40`（0…255）。
    ///
    /// ## 判据为什么是「彩色」而不是「墨迹」
    ///
    /// 这个 20×20 槽里可能出现两种东西：
    ///
    /// | 渲染 | 长相 | 通道差 |
    /// |---|---|---|
    /// | **真应用图标**（Finder） | 蓝色填充 + 白色笑脸 | 大（蓝 ≈ 150） |
    /// | **回落** SF Symbol `app` | **灰色**圆角方框描边 | ≈ 30（`#86868B`） |
    ///
    /// 两者**墨迹量是同一量级**（都「画了点东西」），所以数墨迹分不开；
    /// 而**色彩是二值的** —— 真图标一定有色相，灰色描边一定没有。阈值 40 落在
    /// 150 与 30 之间，两侧各留 2 倍以上余量。
    ///
    /// ⚠️ **必须带对照组**（本仓库栽过两次「0 命中 = 真的没有 vs 判据本身坏了」）：
    /// 下面那条用例同时断言「有身份 → 彩色多」与「无身份 → 彩色 ≈ 0」。
    private func colorfulPixels(process: OccupyingProcess) -> Int {
        _ = NSApplication.shared
        let chip = ProcessChip(process: process)
        // 先量出芯片的自然尺寸，再按它渲染 —— 尺寸精确时芯片正好铺满宿主，
        // 图标槽才会落在上面算出来的坐标上（宿主比芯片大时 SwiftUI 会居中，坐标就漂了）。
        let probe = NSHostingController(rootView: chip)
        probe.view.layoutSubtreeIfNeeded()
        let size = probe.view.fittingSize
        guard
            size.width > 0, size.height > 0,
            let rep = OffscreenRender.bitmap(chip, size: size)
        else { return -1 }

        // ⚠️ **自证**：槽位必须真的落在位图里。`forEachPixel` 会把越界**夹住**（那是为了
        // 直读时不去读缓冲区外的内存），夹住之后的数字看着照样合理，只是量的不是那块地方 ——
        // 与「判据本身坏了」逐字相同。所以这一步必须自己判。
        guard CGRect(origin: .zero, size: size).contains(iconSlot) else { return -1 }

        var n = 0
        OffscreenRender.forEachPixel(rep, in: iconSlot, scale: 2) { _, _, r, g, b in
            // `max − min > 40/255`：有饱和色相就算彩色，灰色描边不算（阈值依据见上面的表）。
            let spread = max(r, max(g, b)) - min(r, min(g, b))
            if spread * 255 > 40 { n += 1 }
        }
        return n
    }

    /// 系统里一个**任何 macOS 都有**的应用（Finder）—— 走查图与这条守卫共用同一份样本。
    private var finderAppPath: String? {
        let path = "/System/Library/CoreServices/Finder.app"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// **有应用身份 → 画真图标**；**没有 → 才回落**。两条一起跑，互为对照。
    ///
    /// 变异验证：
    /// - 把 `iconView` 整个换成 `Image(systemName: "app")` → 第一条变红（彩色 0）；
    /// - 把 `iconView` 改成「永远取通用应用图标」 → 第一条变红（通用图标是灰的）。
    @Test func 有应用身份时画真图标无身份时才回落() throws {
        let finder = try #require(finderAppPath, "系统里找不到 Finder.app —— 本机无法跑这条断言")
        let size = DesignTokens.Size.processChipIcon

        // ① 有 `appBundlePath`：真图标（Finder 是蓝色的）。
        let withApp = OccupyingProcess(
            pid: 1234, processName: "Finder", displayName: "Finder",
            appBundlePath: finder, path: "/Volumes/Demo/clip.mp4")
        let withAppColors = colorfulPixels(process: withApp)

        // ② 什么都没有（生产上等于「这个 PID 已经不在了」）：回落成灰色 `app` 空方框。
        let bare = OccupyingProcess(pid: 0, processName: "ghost", path: "/Volumes/Demo/clip.mp4")
        let bareColors = colorfulPixels(process: bare)

        // **自证**：两次渲染都必须在位。`-1` 表示渲染或坐标算错了 ——
        // 那时两个数字都不能当数（否则「都是 0」会被读成「判据对了」）。
        #expect(withAppColors >= 0, "渲染失败（-1）—— 这次的数字不可信")
        #expect(bareColors >= 0, "渲染失败（-1）—— 这次的数字不可信")

        #expect(
            withAppColors > 100,
            """
            有 `appBundlePath` 时图标槽里只有 \(withAppColors) 个彩色像素 —— 画的不是真应用图标。\
            真图标是彩色填充（Finder 蓝，20×20pt 槽在 2x 下约 \(Int(size * size * 4 / 2)) 个像素可着色）；\
            灰色 SF Symbol `app` 描边的通道差只有 ~30，低于阈值 40。\
            这就是用户 2026-09-17 报的「应用图标又不显示了」。
            """
        )
        #expect(
            bareColors < 20,
            """
            没有应用身份时图标槽里却有 \(bareColors) 个彩色像素（期望 ≈ 0）—— \
            回落分支画的不是灰色 `app`。这条是上面那条的**对照**：\
            它不成立就说明「彩色」这个判据本身区分不开两种情况，上面那条的绿是假的。
            """
        )
    }
}
