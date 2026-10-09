import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 主窗口**磁盘列表**的契约：多块盘并列、忙态逐行着色、≥4 块切紧凑行。
///
/// ## 为什么单独一个文件（2026-09-17 补）
///
/// `DESIGN-SPEC.md` §8.1 末尾留了一条：
/// 「⚠️ **仍未覆盖**：多盘并列 / 忙态的主窗口与面板……要覆盖这些状态得给
/// `DiskListStore` / `ContentView` 加依赖注入，属独立改动。」
///
/// 依赖注入在 §8.29 / §8.30 补齐了，但**这条缺口一直没回来关**：
/// `SnapshotRenderTests` 的主窗口仍在渲染 `DiskListStore.shared` 的真实枚举结果，
/// 于是走查图永远是「本机恰好插着的那一块盘」—— 多盘与忙态**一张图都没有**。
///
/// ## 为什么光有图不够，还要有断言
///
/// 出图只在 `DE_SNAPSHOTS=1` 下跑，**不进 CI**（它是唯一会写文件的测试）。
/// 于是「多盘 / 忙态 / 紧凑行」这三件事在 CI 里**一条断言都没有**。
/// 本文件把它们变成数字。
///
/// ## 判据为什么选「琥珀条」而不是「深色墨迹」
///
/// 深色墨迹只能回答「这一片画了东西」，回答不了「画了**几行**」「哪几行是忙的」——
/// 两块盘的文字、容量条、按钮全都会贡献墨迹，混在一起分不开。
///
/// 被占用行的**左侧琥珀条**（`DiskRow.busyBar`，设计稿 `.row--busy::before`）
/// 是这套界面里唯一「一块忙盘 ⇒ 恰好一条、且互不重叠」的元素：
/// 它贴行的左边缘（列表内边距 16pt 处），宽 3pt，纵向按行内缩。
/// 于是**沿它所在的那一列竖着扫一遍，数出几段琥珀 = 有几块忙盘**。
///
/// 顺带还能量到**每段多长** —— 那就是行高减去上下内缩。紧凑行的段长只有完整行的
/// 五分之一左右，于是「≥4 块切紧凑」这件事也一并变成了数字。
///
/// ⚠️ **别用「整窗琥珀像素总数」**：那是「行数 × 行高」的乘积，
/// 行数从 2 变 4、行高从 169 变 46，总数可能反而变小 —— 拿一个会自相抵消的量当判据，
/// 断言会时真时假。
@MainActor
struct MainWindowDiskListTests {

    // MARK: - 夹具

    /// 造 N 块盘，名称/容量各不相同 —— 名称相同会让「是不是同一块盘画了两遍」看不出来。
    ///
    /// ⚠️ 每一步都拆成局部常量：写成一个大 `DiskInfo(...)` 字面量放进 `map` 闭包，
    /// 类型检查器会超时（实测 `unable to type-check this expression in reasonable time`）。
    private func disks(_ n: Int) -> [DiskInfo] {
        let total: Int64 = 1_000_000_000_000
        let step: Int64 = 100_000_000_000
        return (1...n).map { i in
            let name = "Disk \(i)"
            let path = "/Volumes/\(name)"
            let bsd = "disk\(i)s2"
            let used = Int64(i) * step
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
    }

    private let occupying = [
        OccupyingProcess(pid: 5340, processName: "IINA", path: "/Volumes/Disk1/clip.mp4"),
        OccupyingProcess(pid: 39298, processName: "tail", path: "/Volumes/Disk1/clip.mp4"),
    ]

    /// 给前 `busyCount` 块盘挂上「被占用」，其余是 `.none`（已确认可安全推出）。
    private func occupancy(_ ds: [DiskInfo], busy: Int) -> [String: OccupancyResult] {
        var table: [String: OccupancyResult] = [:]
        for (i, d) in ds.enumerated() {
            table[d.mountPath] = i < busy ? .occupied(occupying) : OccupancyResult.none
        }
        return table
    }

    // MARK: - 量琥珀条

    /// 琥珀像素判据：`r − max(g, b) > 60`（0…255）。与 ``OffscreenRender/redPixels`` 同构，只是换成琥珀。
    ///
    /// 实测四档（浅色、白底）：
    ///
    /// | 被测像素 | `r − max(g,b)` | 结论 |
    /// |---|---|---|
    /// | `#FF9500`（`Palette.warning`，琥珀条本体） | 255 − 149 = **106** | ✅ 算琥珀 |
    /// | `#B25000`（`Palette.warningText`，忙态文字） | 178 − 80 = **98** | ✅ 算琥珀 |
    /// | `warningSoft` 压在白上 ≈ `#FFF2E0`（徽章底） | 255 − 242 = **13** | ✅ 不算 |
    /// | `#1D1D1F`（`Palette.foreground`，正文） | 29 − 31 = **−2** | ✅ 不算 |
    ///
    /// 取 60：离琥珀文字的 98 有 38 的余量，离徽章底的 13 有 47 的余量。
    ///
    /// ⚠️ 收的是**非预乘** RGB（0…1）而不是 `NSColor` —— 见
    /// ``OffscreenRender/boundingBox(_:scale:matchingRGB:)``：收 `NSColor` 就得逐像素构造对象，
    /// 而本判据只看 r/g/b（不看 alpha）。
    private func isAmber(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        Int(r * 255 - max(g * 255, b * 255)) > 60
    }

    /// 一块忙盘的琥珀条：起止 y（pt，原点左上）与段长。
    struct AmberRun {
        let top: CGFloat
        let height: CGFloat
    }

    /// 沿琥珀条所在的那一列竖扫，返回**每一段连续琥珀**的位置与长度。
    ///
    /// ## 列位置是**量出来的**，不是写死的
    ///
    /// 琥珀条贴行的左边缘，即列表内边距 `Spacing.lg`（16pt）处 —— 但那是**今天**的排版。
    /// 写死 `x = 17` 的话，将来谁把列表内边距从 16 改成 20，
    /// 这一列就会扫到空白，返回 **0 段**，而 0 段在「一块忙盘都没有」时也是合法的 ——
    /// **失败与通过长得一模一样**。本仓库已经在这上面栽过两次（见 ``OffscreenRender`` 文件头）。
    ///
    /// 所以先取**整窗琥珀像素的包围盒**，用它的 `minX` 当列位置：琥珀条是全局最靠左的琥珀元素
    /// （行的左边缘），徽章与文字都在它右侧。再往右偏 1pt 落在条的**内部**，
    /// 避开圆角与抗锯齿。
    private func amberRuns(_ view: some View, size: CGSize) -> (runs: [AmberRun], columnX: CGFloat) {
        guard let rep = OffscreenRender.bitmap(view, size: size) else { return ([], -1) }
        let scale: CGFloat = 2

        // ⚠️ 把**已经画好**的 `rep` 交给 `boundingBox`：它原先自己又渲染一遍，
        // 同一张 1600×1040 的图白画两次 —— 2026-09-23 顺手省掉。
        guard let box = OffscreenRender.boundingBox(rep, scale: scale, matchingRGB: isAmber) else {
            return ([], -1)
        }
        let columnX = box.minX + 1
        let x = Int(columnX * scale)
        guard x >= 0, x < rep.pixelsWide else { return ([], columnX) }

        var runs: [AmberRun] = []
        var start: Int? = nil
        for y in 0..<rep.pixelsHigh {
            let amber = OffscreenRender.rgb(rep, x: x, y: y).map { isAmber($0.0, $0.1, $0.2) } ?? false
            if amber {
                if start == nil { start = y }
            } else if let s = start {
                runs.append(AmberRun(top: CGFloat(s) / scale, height: CGFloat(y - s) / scale))
                start = nil
            }
        }
        if let s = start {
            runs.append(AmberRun(top: CGFloat(s) / scale, height: CGFloat(rep.pixelsHigh - s) / scale))
        }
        return (runs, columnX)
    }

    private var size: CGSize {
        CGSize(width: DesignTokens.Size.mainWindow.width, height: DesignTokens.Size.mainWindow.height)
    }

    // MARK: - 多盘并列 + 忙态逐行着色

    /// **一块忙盘 ⇒ 恰好一条琥珀条。**
    ///
    /// 这条是后面几条的**基准**：它同时给出「一条条到底多长」这个量，
    /// 后面比较行密度才有参照物。也是一条**对照组** —— 若它数到 0 段，
    /// 说明判据本身坏了（列位置错了 / 颜色阈值不对），后面几条的数字一律作废。
    @Test func 一块忙盘画一条琥珀条() async {
        let ds = disks(2)
        let view = await ViewFixtures.mainWindow(disks: ds, occupancy: occupancy(ds, busy: 1))
        let (runs, columnX) = amberRuns(view, size: size)

        #expect(
            runs.count == 1,
            """
            2 块盘、1 块被占用，却在 x=\(columnX)pt 那一列数到 \(runs.count) 段琥珀（期望 1）——\
            数到 0 说明这一列扫空了（列表内边距变了？），数到 ≥2 说明琥珀条被切成了几段。\
            段位置：\(runs.map { "y=\($0.top) h=\($0.height)" })
            """
        )
    }

    /// **两块忙盘 ⇒ 两条琥珀条**，且**两条之间隔着一段空白**（不是一条被切开的）。
    ///
    /// 「多盘并列」这件事的可观测后果就是这个：单盘实现下第二条**无处可来**。
    @Test func 两块忙盘画两条琥珀条() async {
        let ds = disks(2)
        let view = await ViewFixtures.mainWindow(disks: ds, occupancy: occupancy(ds, busy: 2))
        let (runs, columnX) = amberRuns(view, size: size)

        #expect(
            runs.count == 2,
            "2 块盘都被占用，x=\(columnX)pt 那一列却数到 \(runs.count) 段琥珀（期望 2）——多盘没有并列画出来"
        )
        guard runs.count == 2 else { return }

        // 两条之间必须真的断开：行间距 `Spacing.sm`（8pt）+ 上下各 10pt 内缩 = 28pt 的空隙。
        let gap = runs[1].top - (runs[0].top + runs[0].height)
        #expect(
            gap > 20,
            "两条琥珀条之间只隔了 \(gap)pt（期望 > 20）—— 这说明它们其实是同一条被切成了两半，不是两块盘各一条"
        )
    }

    /// **忙态是逐行着的，不是整列都染**：1 忙 + 1 安全的列表里，琥珀条只能有一条。
    ///
    /// 这条是上一条的**反向对照**。缺了它，「画了两条」也可能来自
    /// 「只要列表里存在任意一块忙盘，就给所有行都画条」这种实现 —— 那同样是错的。
    @Test func 安全盘不画琥珀条() async {
        let ds = disks(2)
        let view = await ViewFixtures.mainWindow(disks: ds, occupancy: occupancy(ds, busy: 1))
        let (runs, _) = amberRuns(view, size: size)
        #expect(runs.count == 1, "只有第一块盘被占用，却数到 \(runs.count) 段琥珀 —— 忙态串到了安全的行上")
    }

    // MARK: - 行密度：≥ 4 块切紧凑行

    /// `DiskRowDensity.forCount` 是纯函数，已有单测（`MenuDiskRowLayoutTests` 里
    /// `forCount(1|3) == .regular`、`forCount(4|8) == .compact`）。
    /// **但「`ContentView` 有没有拿磁盘数去调它」没人测** —— 这正是本项目反复踩的
    /// 「判定逻辑测了、接线没测」（见 `EmptyStateTests` 文件头同一段话）。
    ///
    /// ## 判据：琥珀条的**段长**，实测标定（800×520、2x、浅色）
    ///
    /// | 盘数 | 密度 | 琥珀条实测 | 算术 |
    /// |---|---|---|---|
    /// | 2（本文件其他用例） | `.regular` | `y=74 h=148` | 行高 169 − 上下各内缩 10 = 149 |
    /// | 3（本用例） | `.regular` | `y=74 h=148` / `y=250 h=147` / `y=425 h=**95**` | 同上；**第三条被窗口下沿截断**，见下 |
    /// | 4（下一用例） | `.compact` | `h=30` × 4 | 行高 46 − 上下各内缩 8 = 30 |
    ///
    /// 完整行与紧凑行差近 **5 倍**，不需要精确定标就能分开。
    ///
    /// ## 两个实测到的、值得记一笔的现象
    ///
    /// 1. **第三条被窗口下沿截断（h=95 而不是 148）**。三块完整行的总高
    ///    `169 + 169 + 127 + 2×8 = 481`，而列表区只有
    ///    `520 − 标题带 52 − 上内边距 12 − 下内边距 16 = 440` —— **放不下，要滚动**。
    ///    所以本用例的断言只看 `runs.first`（第一条完整可见），
    ///    `runs.count == 3` 仍然成立是因为第三条还剩 95pt 露在外面。
    /// 2. ~~紧凑行实测 26 而不是算出来的 30，差在 `UnevenRoundedRectangle` 的取整~~
    ///    —— **这条归因是错的，2026-09-18 订正**。当时算出的 30 是对的，量到的 26 也是对的；
    ///    错的是**紧凑行接错了令牌**：它拿的是完整行的 `rowBusyBarInset`（10）而不是紧凑行的 8，
    ///    于是 46 − 2×10 = **26**。差的 4pt 正好是 `2 ×（10 − 8）`。
    ///    而当时这条断言只写 `< 40` —— 26 与 30 **都能过**，失败与通过长得一模一样。
    ///    **算术与实测对不上时，先怀疑接线，别先怀疑取整。**
    ///    现在内缩由 `MenuDiskRowLayoutTests/三种行的琥珀条各用自己那组的规格` 逐行钉住。
    @Test func 三块忙盘仍是完整行() async {
        let ds = disks(3)
        let view = await ViewFixtures.mainWindow(disks: ds, occupancy: occupancy(ds, busy: 3))
        let (runs, _) = amberRuns(view, size: size)

        #expect(runs.count == 3, "3 块忙盘应画 3 条琥珀条，实际 \(runs.count) 条")
        guard let first = runs.first else { return }
        #expect(
            first.height > 100,
            """
            3 块盘（< 阈值 \(DesignTokens.Size.compactRowThreshold)）的行应是**完整行**，\
            琥珀条段长实测 148pt，只有 \(first.height)pt —— 提前切了紧凑行。
            """
        )
    }

    /// **4 块盘切紧凑行**：琥珀条段长从实测 148pt 掉到 30pt，且 4 块盘全都画出来。
    ///
    /// ## 断言顺序是**故意**的：先段长、后条数
    ///
    /// 变异验证（把 `ContentView.density` 改成恒 `.regular`）时，**两条都会红** ——
    /// 段长变成 148，且因为四块完整行（4×169）放不进 440pt 的列表区，
    /// 第四条整条落到窗口外，条数也变成 3。
    /// 先报段长，失败信息直接指向「没切紧凑行」这个根因；
    /// 先报条数则会把人引向「是不是漏画了一块盘」，是条歧路。
    @Test func 四块忙盘切紧凑行() async {
        let ds = disks(4)
        let view = await ViewFixtures.mainWindow(disks: ds, occupancy: occupancy(ds, busy: 4))
        let (runs, columnX) = amberRuns(view, size: size)

        guard let first = runs.first else {
            Issue.record(
                """
                x=\(columnX)pt 那一列一条琥珀条都没数到 —— 这次渲染整体不可信（列位置错了？颜色阈值不对？），\
                后面的结论一律作废。本文件其他用例是这条的对照组。
                """
            )
            return
        }
        #expect(
            abs(first.height - 30) <= 2,
            """
            4 块盘（≥ 阈值 \(DesignTokens.Size.compactRowThreshold)）应切**紧凑行**：\
            琥珀条段长应为 **30pt**（设计稿 `.crow--busy::before`：行高 46 − 上下各内缩 8），\
            实测 \(first.height)pt。**≈26 就是紧凑行拿回了完整行的内缩 10**（2026-09-18 那次接错），\
            ≈148 则是压根没切紧凑行 —— 判据是 `ContentView.density`\
            （`DiskRowDensity.forCount(store.disks.count)`）没有真的接到行上。
            """
        )
        #expect(
            runs.count == 4,
            """
            ≥ 4 块盘应把 4 块都画出来，实际在 x=\(columnX)pt 数到 \(runs.count) 条琥珀条。\
            段位置：\(runs.map { "y=\($0.top) h=\($0.height)" })
            """
        )
        for run in runs {
            #expect(
                abs(run.height - 30) <= 2,
                "第 y=\(run.top)pt 那条长 \(run.height)pt（应为 30）—— 同一列里混了完整行与紧凑行，或内缩取错了"
            )
        }
    }
}
