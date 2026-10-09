import Foundation
import Testing

/// 「仍开着」表的**状态标记不得自相矛盾**（2026-09-21，§8.113.13）
///
/// 【它解决什么】
/// 「表自己也会漂」在本项目已经发生**三次**（§8.104、§8.113.6 那次、2026-09-21 的
/// 第 32 / 35 行）：一件事做完了、没回来划账 ⇒ 那一行的**状态列**还写着
/// `⬜ 仍开着`，而**描述列**里明明已经写了 🟢（已关闭 / 拿到结论）。
/// ⇒ 只看「清单里有它」会以为还开着；只看描述列又会以为已经划过账。
/// 两种读法都成立，而**没有任何东西会红** —— 正是本守卫要堵的洞。
///
/// 【判据】一行里不得同时出现「仍开着」标记 `⬜ **仍开着**` 与「整项关闭」标记 `🟢`。
///
/// 【⚠️ 为什么只认 `🟢`、不认 `✅` —— 精度】
/// `✅` 在本文件里大量用于**子项**（「① ✅ 已进守卫；② ⬜ 深色值仍缺」是**合法的部分关闭**）。
/// 用 git 里划账前那一版实测过：带上 `✅` 的宽判据命中 **2 行**，其中第 35 行是**误报**
/// —— 它那个 `✅ 已关闭` 在 4.3 订正里被**撤销**了，那一行当时**确实还开着**。
/// ⇒ 只认 `🟢`（本文件里 `🟢` = 整项拿到结论）。**precision 100% / recall 偏低**，这个交换值：
/// 喊狼来了的守卫一定会被关掉（§8.88.3 那条教训）。
///
/// 【⚠️ 它抓不到什么 —— 别把「绿了」读成「表不会漂」】
/// 只抓「同一行里两种标记打架」这一种：
/// - 「描述列写了结论、状态列压根没写『仍开着』」的行 ⇒ **看不见**；
/// - 「状态列是 `⬜ 仍开着`、描述列里用 `✅` 写了结论」⇒ **故意不报**（见上）。
/// 这两类仍要靠**人回头核对**（判据里那条：核对时每行都要对一遍现状）。
@Suite struct DocStatusMarkerTests {

    struct Hit: CustomStringConvertible {
        var file: String
        var line: Int
        var description: String { "\(file) L\(line)" }
    }

    /// 纯函数：喂行数组，返回「自相矛盾」的行号（1 起）。
    ///
    /// 抽成纯函数是为了让**样本可以直接喂进来**（下面那条双向对照），
    /// 不必真的把仓库里的文档改坏再验（改坏了还要还原，还原本身又会出错）。
    static func drift(in lines: [String]) -> [Int] {
        var out: [Int] = []
        for (i, line) in lines.enumerated() {
            // ⚠️ **只管表格行**（`|` 开头）：2026-09-21 实测 —— 不限定的话，
            // §8.113.13 里**讨论这两个标记**的散文行会把自己报成漂移
            // （那一节正是拿它们当例子写的）。散文里同时提到两种标记是**正常的**。
            guard line.hasPrefix("|") else { continue }
            if line.contains("⬜ **仍开着**") && line.contains("🟢") {
                out.append(i + 1)
            }
        }
        return out
    }

    // MARK: 第二向：未退役的行**必须**表态（2026-09-21 补，填 §8.113.13 承认的洞）

    /// 账本表块的判据：表头里必须含这个词。
    ///
    /// 用它把「仍开着」表和文档里**别的**编号表（§8.57.6 的守卫清单、§8.69.3 的判据表……）
    /// 区分开 —— 那些表的「最后一格」是变异编号或备注，**本来就不表态**。
    private static let ledgerHeaderMarker = "谁才能关"

    /// 状态列允许出现的标记。
    ///
    /// ⚠️ **四个都收**：`🟢` 整项关闭 / `✅` 子项或老式关闭 / `⬜` 仍开着 / `🟡` 部分关闭。
    /// 这一向问的是「**有没有表态**」，不是「表的是什么态」——
    /// 表态的**精度**交给上面那条 `drift`（它只认 🟢，见文件头那段权衡）。
    private static let statusMarkers = ["🟢", "✅", "⬜", "🟡"]

    /// 按**未转义**的 `|` 切单元格。
    ///
    /// ⚠️ **不能直接 `split("|")`**：本仓库在单元格里写 `尚未\|还没`、`` `\| tail -10` ``
    /// 这类**转义**管道，naive 切分会把它当列分隔符 ⇒ 凭空多出一格。
    /// 2026-09-21 实测：账本第 35 行被误判成 6 格（真值 5 格），据此差点报出一个假缺陷。
    static func splitCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                current.append(ch)
                continue
            }
            if ch == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        cells.append(current)
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeFirst() }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 纯函数：喂**原始文档**，返回「账本行未退役、而状态列**一个标记都没有**」的行号（1 起）。
    ///
    /// 【为什么需要】文件头那条「抓不到什么」写的就是这一向：
    /// 「描述列写了结论、状态列**压根没写**『仍开着』」的行，`drift` **看不见**。
    /// 2026-09-21 回头核对时人肉做过一遍（当时零漂移），本条把那次核对**固化成机器判据**。
    ///
    /// 【口径】
    /// - 只认**账本表块**（表头含 ``ledgerHeaderMarker``）；
    /// - **退役行不要求表态**：项那格以 `~~` 开头 = 整行划掉；
    /// - ⚠️ **必须先 `stripFences`**：§8.104.5 里**引用**了那段坏行当样本
    ///   （围栏内的 `| 35 | … | ⚠️ **§8.89 追加**：… |`，最后一格没有标记）。
    ///   不去围栏的话，**引用本身**会被报成缺陷。
    static func unmarkedLedgerRows(inRaw raw: String) -> [Int] {
        let lines = DocTableIntegrityTests.stripFences(raw)
        var out: [Int] = []
        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix("|") else {
                i += 1
                continue
            }
            let start = i
            while i < lines.count, lines[i].hasPrefix("|") { i += 1 }
            guard lines[start].contains(ledgerHeaderMarker) else { continue }
            for j in (start + 1)..<i {
                let cells = splitCells(lines[j])
                guard cells.count >= 3 else { continue }
                guard Int(cells[0]) != nil else { continue }  // 分隔线 / 非编号行
                if cells[1].hasPrefix("~~") { continue }  // 退役行
                let status = cells[cells.count - 1]
                if !statusMarkers.contains(where: { status.contains($0) }) {
                    out.append(j + 1)
                }
            }
        }
        return out
    }

    /// 仓库根：`#filePath` = <仓库根>/Tests/SafeOutAppTests/DocStatusMarkerTests.swift
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func 标着仍开着却写着整项关闭的行必须被抓出来() async throws {
        // 扫描范围 = **被 git 跟踪的 `.md`**（复用 `DocTableIntegrityTests` 那份）。
        // ⚠️ **范围本身是判据**（§8.105）：自己手写一份清单 = 又添一份会漂的东西；
        // 这里复用同一份 ⇒ 「范围」在两个守卫之间**只有一个真相**。
        let files = try #require(
            await DocTableIntegrityTests.trackedMarkdownFiles(),
            "拿不到 `git ls-files '*.md'` 的输出 —— 扫描范围也拿不到了（范围本身就是判据）")
        #expect(!files.isEmpty, "被跟踪的 `.md` 一份都没有 —— 范围坏了")

        var hits: [Hit] = []
        for f in files {
            let url = Self.repoRoot.appendingPathComponent(f)
            // CI 上 `.workbuddy*/memory/*.md` 不存在（被 .gitignore 排除）⇒ 读不到就跳过，
            // 与 `DocTableIntegrityTests` 同源的口径一致。
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for lineNo in Self.drift(in: raw.components(separatedBy: "\n")) {
                hits.append(Hit(file: f, line: lineNo))
            }
        }

        #expect(
            hits.isEmpty,
            """
            这些行**状态列写着「仍开着」、同一行却出现了整项关闭标记 🟢** —— 表自己漂了：
            \(hits.map(\.description).joined(separator: "\n"))
            正确的处置是**把状态列划成已关闭**（写清核对时刻与依据章节），
            不是把那行里的 🟢 删掉 —— 删了就等于把「已经做完」这件事也一起删了。
            """)
    }

    @Test func 账本里未退役的行必须在状态列里有标记() async throws {
        let files = try #require(
            await DocTableIntegrityTests.trackedMarkdownFiles(),
            "拿不到 `git ls-files '*.md'` 的输出 —— 扫描范围也拿不到了（范围本身就是判据）")
        #expect(!files.isEmpty, "被跟踪的 `.md` 一份都没有 —— 范围坏了")

        var hits: [Hit] = []
        for f in files {
            let url = Self.repoRoot.appendingPathComponent(f)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for lineNo in Self.unmarkedLedgerRows(inRaw: raw) {
                hits.append(Hit(file: f, line: lineNo))
            }
        }

        #expect(
            hits.isEmpty,
            """
            这些账本行**既没退役、状态列又没表态** —— 读的人不知道它到底关没关：
            \(hits.map(\.description).joined(separator: "\n"))
            处置二选一：① 真关了 ⇒ 状态列写清标记（`🟢`/`✅`）＋核对时刻＋依据章节；
            ② 真还开着 ⇒ 状态列写 `⬜ **仍开着**`；
            ③ 整项作废 ⇒ 把「项」那格划上删除线（`~~…~~`），退役行不要求表态。
            """)
    }

    @Test func 判据的双向对照() throws {
        // ① 阳性：真的打架 ⇒ 必须命中（否则装置瞎了，与「没有漂移」逐字相同）
        let bad = [
            "| 32 | … | ⬜ **仍开着**（§8.82 新开）。… 🟢 **已关闭（2026-09-21，§8.113.10）** … |"
        ]
        #expect(
            Self.drift(in: bad) == [1],
            "阳性对照失败：真的自相矛盾没被抓出来 ⇒ 这条守卫等于没有")

        // ② 阴性：合法的部分关闭（✅ 子项 + ⬜ 子项，状态列写「🟡 部分关闭」）⇒ 不得命中
        let partial = [
            "| 25 | … | ① ✅ 已进守卫；② ⬜ 深色值仍缺 | 🟡 **部分关闭** |"
        ]
        #expect(
            Self.drift(in: partial).isEmpty,
            "阴性对照失败：合法的「部分关闭」被误报 ⇒ 守卫会喊狼来了")

        // ③ 阴性：`⬜ **仍开着**` + `✅` ⇒ **故意不报**（第 35 行那种，见文件头）
        let onlyCheck = [
            "| 35 | … | ⬜ **仍开着**（§8.86 新开）。… ✅ **已关闭（随后撤销）** … |"
        ]
        #expect(
            Self.drift(in: onlyCheck).isEmpty,
            "阴性对照失败：`✅` 只表示子项完成，不该被当成整项关闭（精度靠这一条守住）")

        // ④ 阴性：两种标记在**不同行** ⇒ 不得命中（别把相邻两行读成同一行）
        let twoLines = [
            "| 32 | … 🟢 已关闭 … |",
            "| 35 | … ⬜ **仍开着** … |",
        ]
        #expect(
            Self.drift(in: twoLines).isEmpty,
            "阴性对照失败：跨行不该被当成同一行里的矛盾")

        // ⑤ 阴性：**散文**里同时提到两种标记 ⇒ 不得命中。
        //    2026-09-21 实测：不加「只管表格行」这条限定，§8.113.13 里讨论本判据的
        //    那段文字会把自己报成漂移（那一节正是拿这两个标记当例子写的）。
        let prose = [
            "**判据**：一行里不得同时出现「仍开着」标记 `⬜ **仍开着**` 与「整项关闭」标记 `🟢`。"
        ]
        #expect(
            Self.drift(in: prose).isEmpty,
            "阴性对照失败：散文里讨论这两个标记不该被当成漂移")
    }

    @Test func 未退役行的判据的双向对照() throws {
        // ① 阳性：未退役的行**状态列没表态** ⇒ 必须命中（否则装置瞎了）
        let ledger = [
            "| # | 项 | 谁才能关 | 出处 | 现状 |",
            "|---|---|---|---|---|",
            "| 1 | ~~旧账~~ | 我 | §8.1 | 早就关了 |",
            "| 2 | 新账 | 我 | §8.2 | 还在查 |",
        ].joined(separator: "\n")
        #expect(
            Self.unmarkedLedgerRows(inRaw: ledger) == [4],
            "阳性对照失败：未退役、状态列又没标记的行没被抓出来 ⇒ 这一向等于没有")

        // ② 阴性：退役行（项那格划了删除线）**不要求表态**
        let retired = [
            "| # | 项 | 谁才能关 | 出处 | 现状 |",
            "|---|---|---|---|---|",
            "| 1 | ~~旧账~~ | 我 | §8.1 | 早就关了 |",
        ].joined(separator: "\n")
        #expect(
            Self.unmarkedLedgerRows(inRaw: retired).isEmpty,
            "阴性对照失败：退役行不该被要求表态")

        // ③ 阴性：**别的**编号表（表头没有「谁才能关」）不归这一向管 ——
        //    那些表的最后一格是变异编号 / 备注，本来就不表态。
        let otherTable = [
            "| # | 判据 | 变异 |",
            "|---|---|---|",
            "| 57 | 挂了 `data-i18n` 的元素，祖先里不许再有一层 | M100 |",
        ].joined(separator: "\n")
        #expect(
            Self.unmarkedLedgerRows(inRaw: otherTable).isEmpty,
            "阴性对照失败：非账本的编号表被误报 ⇒ 守卫会喊狼来了")

        // ④ 阴性：**围栏内引用的坏行样本** ⇒ 不得命中。
        //    §8.104.5 正是把那段坏行抄进代码围栏里当样本的，而它最后一格没有标记。
        //    不去围栏的话，**引用本身**会被报成缺陷。
        let fencedQuote = [
            "核对到一半时发现：",
            "```",
            "| # | 项 | 谁才能关 | 出处 | 现状 |",
            "|---|---|---|---|---|",
            "| 2 | 新账 | 我 | §8.2 | 还在查 |",
            "```",
            "以上是引用。",
        ].joined(separator: "\n")
        #expect(
            Self.unmarkedLedgerRows(inRaw: fencedQuote).isEmpty,
            "阴性对照失败：围栏内引用的坏行被当成真缺陷 ⇒ 必须先去围栏")

        // ⑤ 转义管道不算列分隔符（naive `split(\"|\")` 会凭空多出一格）
        let escaped = Self.splitCells("| 35 | 门槛输出 `\\| tail -10` 了 | 我 | §8.86.7 | 🟢 已关闭 |")
        #expect(
            escaped.count == 5,
            "转义管道被当成了列分隔符：切出 \(escaped.count) 格（应为 5）—— 2026-09-21 实测踩过这个假缺陷")
    }
}
