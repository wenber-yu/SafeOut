import Foundation
import Testing

@testable import SafeOutApp

/// 四种「行」的高度：实现常量 ↔ **设计稿实测快照**。
///
/// ## 为什么这一条和 `DesignSizeParityTests` 不是一回事
///
/// 那边读的是 `ds.css` 的**声明处**（`--w-main: 800px`、`.alert__icon { width: 38px }`）——
/// 设计稿里**有一个数**可以比。而这里这五个常量：
///
/// `diskRowBusyHeight(169)` / `diskRowSafeHeight(127)` / `diskRowUnknownHeight(133)` /
/// `menuRowHeight(69)` / `compactRowHeight(46)`
///
/// 在 `ds.css` 里**一处都没有** —— 行高是 `padding + 内容` 自然排出来的，没有声明处。
/// 它们的出处是「一次无头 Chrome 实测」（设计稿实测 169.47 / 127.47 / 133.47 / 68.72 / 46），
/// 而**没有任何机制会去复核那次实测还成不成立**（清单 #17）。
///
/// ⇒ 所以这里的口径是：**把实测值固化成仓库里的一份快照**
/// （`assets/design-row-heights.json`，由 `Tools/measure_row_heights.py` 生成），
/// 再让 CI 去比。这把「只能手工复核」变成了「CI 能抓漂移」。
///
/// ## ⚠️ 这条守卫的边界（别把它读成同源守卫）
///
/// - **能抓**：实现侧飘了（谁改了 padding / 行距，行高变 180 ⇒ 立刻红）。
/// - **抓不住**：设计稿改了而没重跑脚本 —— 快照里还是旧值，两边依然「一致」。
///   要复核设计稿，就**重跑 `Tools/measure_row_heights.py`**（它会覆盖快照并打印时刻）。
///   这是「实测值」这一类事实的固有代价，`DESIGN-SPEC` 清单 #17 记的就是它。
///
/// ## 容差为什么是 1pt
///
/// 实现是**取整值**（169 vs 实测 169.47、69 vs 68.72），取整差最大 0.5pt；
/// 容差给 1pt ⇒ **1pt 以上的变化必红**，而 0.5pt 的取整差不会误报。
/// ⚠️ 别把它调大：调成 5pt 就等于放弃了「行高结构变了」这个信号。
struct RowHeightParityTests {

    private struct Row: Decodable {
        let page: String
        let selector: String
        let count: Int
        let heights: [Double]
    }

    private struct Report: Decodable {
        let measuredAt: String
        let rows: [String: Row]
    }

    /// 五种行的高度必须落在设计稿实测值附近（±1pt）。
    ///
    /// **为什么这里用容差、而 `DesignSizeParityTests` 用精确相等**：那边比的是
    /// 「设计稿写的一个整数」↔「实现写的一个整数」，两边都精确；这边比的是
    /// 「Chrome 量出来的小数」↔「实现取整后的值」，天然差不到 1pt。
    @Test func 五种行的高度必须落在设计稿实测值附近() throws {
        let r = try load()

        // 负向锚：JSON 缺档 / 读空时，下面的 #require 之外还有一种可能 ——
        // rows 只有 3 档而代码只读到 4 档中的 3 档，照样「全绿」。
        #expect(r.rows.count == 4, "快照里应该有 4 档（busy / safeUnknown / menu / compact），实际 \(r.rows.count)")

        let busy = try row(r, "busy")
        let safeUnknown = try row(r, "safeUnknown")
        let menu = try row(r, "menu")
        let compact = try row(r, "compact")

        // 负向锚：可推出 / 未知是**两种**高度（实测 127.47 / 133.47，差 6pt）。
        // 哪天量出来两个一样，说明选择器抓错了对象（或页面改版了）—— 那不是「一致」。
        #expect(
            safeUnknown.heights.count == 2 && safeUnknown.heights[0] < safeUnknown.heights[1],
            """
            「可推出 / 未知」两态量出来的高度是 \(safeUnknown.heights) ——
            应该是两个不同的值（实测 127.47 / 133.47）。若只剩一个，多半是选择器抓错了。
            """)
        #expect(busy.heights.count == 1, "忙态只应该有一种高度，实际 \(busy.heights)")

        print(
            "  [行高] 快照 \(r.measuredAt) ｜ 忙态 \(busy.heights[0]) ｜ "
                + "可推出 \(safeUnknown.heights[0]) ｜ 未知 \(safeUnknown.heights[1]) ｜ "
                + "菜单行 \(menu.heights[0]) ｜ 紧凑行 \(compact.heights[0])")

        close(busy.heights[0], DesignTokens.Size.diskRowBusyHeight, "完整行·忙态")
        close(safeUnknown.heights[0], DesignTokens.Size.diskRowSafeHeight, "完整行·可推出")
        close(safeUnknown.heights[1], DesignTokens.Size.diskRowUnknownHeight, "完整行·未知")
        close(menu.heights[0], DesignTokens.Size.menuRowHeight, "菜单行")
        close(compact.heights[0], DesignTokens.Size.compactRowHeight, "紧凑行")
    }

    /// 快照里每一档都要写明**在哪一页、用什么选择器、量到几个**。
    ///
    /// 这条守的是「快照可复核」：只有数值没有出处的话，下一轮想复核时
    /// 根本不知道当初量的是哪个元素（本项目为「量到半成品页面」吃过一次亏 ——
    /// 结论错了 18pt，因为没人知道基准值是怎么来的）。
    @Test func 实测快照的每一档都要写明页面与选择器() throws {
        let r = try load()
        var bad: [String] = []
        for (key, row) in r.rows.sorted(by: { $0.key < $1.key }) {
            if row.page.isEmpty { bad.append("\(key) 没写页面") }
            if row.selector.isEmpty { bad.append("\(key) 没写选择器") }
            if row.count <= 0 { bad.append("\(key) 命中数是 \(row.count)") }
            if row.heights.isEmpty { bad.append("\(key) 没有高度值") }
        }
        #expect(
            bad.isEmpty,
            """
            快照有问题：\(bad.joined(separator: "、"))。
            重跑 `Tools/measure_row_heights.py` —— 它会带着这些自证字段重新生成。
            """)
    }

    /// 快照必须带**实测时刻**（手改过的快照没有出处，等于又变回「一次性实测」）。
    @Test func 实测快照必须带时刻() throws {
        let r = try load()
        // 只认「YYYY-MM-DD」开头的格式：写「上次」「某天」这种都算没写。
        let ok =
            r.measuredAt.range(
                of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
        #expect(
            ok,
            """
            快照的 measuredAt = 「\(r.measuredAt)」—— 要写成 `YYYY-MM-DD HH:MM`。
            没有时刻的实测值，下次谁也不知道它是哪天量出来的（§8.34.1：
            连「尚未做」都有保质期，记下时刻比记下结论更有用）。
            """)
    }

    // MARK: - 解析

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func load() throws -> Report {
        let url = repoRoot.appendingPathComponent(
            "Design/ui/v2/assets/design-row-heights.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Report.self, from: data)
    }

    private func row(_ r: Report, _ key: String) throws -> Row {
        try #require(
            r.rows[key],
            "快照里没有 \(key) 这一档 —— 重跑 Tools/measure_row_heights.py")
    }

    /// 实测值（小数）与实现常量（取整）的差不能超过 1pt。
    private func close(_ design: Double, _ impl: CGFloat, _ who: String) {
        #expect(
            abs(design - Double(impl)) <= 1.0,
            """
            \(who)：设计稿实测 \(design)pt，实现 \(impl)pt —— 差 \(abs(design - Double(impl)))pt，超过 1pt。
            实现侧改了 padding / 行距 / 字号，或设计稿改版了而快照没更新。
            ⚠️ 设计稿改版请**重跑** `Tools/measure_row_heights.py`，别手改 JSON。
            """)
    }
}
