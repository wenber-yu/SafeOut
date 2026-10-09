import Foundation
import Testing

@testable import SafeOutApp

/// 容量条「高用量」这一档：**设计稿画的样本 ↔ 设计稿声明的阈值 ↔ 实现常量**，三者互相钉住。
///
/// ## 为什么单开一个文件（而不是塞进 `DesignSizeParityTests`）
///
/// 那边守的是「**尺寸**」：`ds.css` 里有一个 `--w-main: 800px` 可以读，判据是「两边相等」。
/// 这一档不一样 —— **设计稿里没有任何一处写得出「≥90% 切琥珀」这个阈值**：
///
/// - CSS 不能按数值切类（`.meter--high` 是**类**，不是 `@media` 条件）；
/// - 它不是尺寸，量不出来（`DesignTokens.Size` 的解析口径是「取第 n 个 px」）。
///
/// 它的真实依据是**设计稿画了哪几根条、哪几根变了色**。
///
/// ## 这一档的历史（§8.52.4 → §8.74）
///
/// 2026-09-18 实扫发现：`ds.css` 定义了 `.meter--high`，而 **9 个 HTML 里没有一个元素用它**；
/// 设计稿所有容量条样本最高 **70%**。而实现侧写着 `highThreshold = 0.9`，
/// 注释还写着「（设计稿 `.meter--high`）」—— **那句注释是假的**，设计稿从没画过这一态。
///
/// ⇒ 本轮（§8.74）在设计稿 `06-states.html` 补了 `E · 容量条用量三档`
/// （30% / 70% / **95% 切琥珀**），并在该节根节点上写了 `data-meter-high="0.9"`。
///
/// ## 三条口径（改这里之前先读）
///
/// 1. **样本是从 HTML 里现扫的**，不是快照：`class="meter …"` 块 + 它里面的 `width:NN%`。
///    所以「设计稿把 70% 改成 80%」会被立刻看见 —— 这是它比 `design-row-heights.json`
///    那种快照强的地方（那边抓不住设计稿侧的改动，见 `RowHeightParityTests` 的边界说明）。
/// 2. **`data-meter-high` 是手写的机器可读声明**（同 `data-theme` / `data-accent-btn` 那一类），
///    不是 `data-page-node-id` 那种编辑器注入的。
///    ⚠️ 若哪天设计稿编辑器重写文件把它丢了，`容量条高用量阈值必须与设计稿声明的值同数`
///    会**红**（不是静默退回）—— 这是有意的。
/// 3. **只扫 `screens/`**：`v2/index.html` 里嵌的是主窗预览的**副本**（30% / 24%），
///    算进去只是把同样的样本数一遍，改不了区间；而 `screens/` 才是「设计稿的屏」。
struct MeterThresholdParityTests {

    // MARK: - 守卫

    /// 设计稿里**必须真的画出**这一档 —— `.meter--high` 不许再是「有定义、零消费者」。
    ///
    /// 这条是 §8.52.4 那个洞的直接反制：那一档之所以「没有可视依据」，就是因为
    /// 谁都没画过它。删掉那根 95% 的条，这条立刻红。
    @Test func 设计稿必须画出至少一根高用量容量条() throws {
        let all = try samples()
        // 负向锚：扫不到东西时，下面两条 `isEmpty` 之外的结论全是空的。
        #expect(all.count >= 10, "只扫到 \(all.count) 根容量条 —— 解析口径失效（假绿）")

        let high = all.filter(\.isHigh)
        let low = all.filter { !$0.isHigh }

        #expect(
            !high.isEmpty,
            """
            设计稿里一根带 `.meter--high` 的容量条都没有（共扫到 \(all.count) 根）。
            `.meter--high` 就又会变回「有定义、零消费者」—— 那正是 §8.52.4 的病：
            实现侧 `DesignTokens.Threshold.meterHigh` 是个**没有出处**的数。
            在 `06-states.html` 的 `E · 容量条用量三档` 里补一根 ≥ 阈值的样本。
            """)
        #expect(
            !low.isEmpty,
            "设计稿里所有容量条都带了 `.meter--high` —— 那这一档就分不出「高/不高」了")

        print(
            "  [容量条] 共 \(all.count) 根 ｜ 高用量 \(high.count) 根（"
                + high.map { "\($0.page) \(fmt($0.percent))%" }.joined(separator: "、")
                + "）｜ 常态 \(low.count) 根，最高 \(fmt(low.map(\.percent).max() ?? 0))%")
    }

    /// 阈值必须**落在设计稿画的两根最近的条之间**：常态的最高那根不能算高、高用量的最低那根必须算高。
    ///
    /// 这一条不依赖任何声明处 —— 它只用**画面上的事实**。
    /// 把阈值调成 0.7（70% 那根就会变琥珀）或 0.96（95% 那根就不亮了），都会在这里红。
    @Test func 容量条高用量阈值必须落在设计稿两根边界条之间() throws {
        let all = try samples()
        let lowMax = try #require(
            all.filter { !$0.isHigh }.map(\.percent).max(),
            "设计稿里没有「常态」样本 —— 区间下界无从谈起")
        let highMin = try #require(
            all.filter(\.isHigh).map(\.percent).min(),
            "设计稿里没有「高用量」样本 —— 区间上界无从谈起")
        let t = DesignTokens.Threshold.meterHigh

        #expect(
            t > lowMax / 100,
            """
            阈值 \(t) ≤ 设计稿常态样本的最高值 \(fmt(lowMax))% ——
            那根条在设计稿里**没有**变琥珀，实现却会把它判成高用量。
            要么把阈值调上去，要么在设计稿里把那根条改成 `.meter--high`。
            """)
        #expect(
            t <= highMin / 100,
            """
            阈值 \(t) > 设计稿高用量样本的最低值 \(fmt(highMin))% ——
            那根条在设计稿里**是**琥珀的，实现却不会判成高用量。
            """)
        print("  [容量条] 设计稿区间 (\(fmt(lowMax))%, \(fmt(highMin))%] ｜ 实现阈值 \(t)")
    }

    /// 实现常量必须与设计稿**声明的值**同数（`data-meter-high`）。
    ///
    /// 上一条只把阈值钉进一个**区间**；这一条把它钉到**那个数**上。
    /// 两条都需要：区间那条管「画面对得上」，这条管「两边写的是同一个数」。
    ///
    /// ⚠️ 声明**只许有一处**：两处就是「同一个事实写在两个地方」（§8.43 的病），
    /// 而两处会各自漂移、谁也不会报错。
    @Test func 容量条高用量阈值必须与设计稿声明的值同数() throws {
        let declared = try declaredThresholds()
        #expect(
            declared.count == 1,
            """
            设计稿里 `data-meter-high` 出现了 \(declared.count) 次（值 \(declared)），应该**恰好一处**。
            0 次 = 声明丢了（实现侧那个常量就又没有出处了）；
            2 次以上 = 同一个事实写了两个地方 —— 两边会各自漂移而没人报错。
            声明处是 `06-states.html` 的 `E · 容量条用量三档`。
            """)
        let d = try #require(declared.first, "设计稿里没有 `data-meter-high` 声明")
        #expect(
            DesignTokens.Threshold.meterHigh == d,
            """
            设计稿声明 \(d)，实现 `DesignTokens.Threshold.meterHigh` 是 \(DesignTokens.Threshold.meterHigh)。
            改一边就要改另一边 —— 别在文档里留一句「另一边还没同步」（§8.43 分叉一整轮的教训）。
            """)
    }

    /// 设计稿**正文里写的百分比**必须与它声明的阈值一致。
    ///
    /// 「用量 ≥ 90% 时切琥珀」这句话是给人读的，`data-meter-high="0.9"` 是给守卫读的 ——
    /// 两者是**同一事实的两处**。只改一处时：改声明 → 这条红；改正文 → 这条也红。
    @Test func 设计稿正文里的百分比必须与声明的阈值一致() throws {
        // ⚠️ 里面那个 `try` 不能省：`#require` 把实参包成 `@autoclosure`，
        // 抛错的调用必须**在实参位置上**标 `try`（省掉报「call can throw」）。
        let section = try #require(try thresholdSection(), "找不到带 `data-meter-high` 的小节")
        let re = try #require(Self.usageAtLeast, "「用量 ≥ NN%」那条正则没编出来")
        let matches = re.matches(in: section, range: NSRange(section.startIndex..., in: section))
        #expect(
            matches.count == 1,
            """
            这一节里「用量 ≥ NN%」出现了 \(matches.count) 次，应该恰好一次。
            0 次 = 这句话被改写了（守卫靠它把「正文里的数」取出来）——
            改法随意，但要把这条守卫的锚一起改掉，别让它静默失效。
            """)
        let m = try #require(matches.first)
        let digits = try #require(
            Range(m.range(at: 1), in: section).map { String(section[$0]) },
            "取不到百分比数字")
        let pct = try #require(Int(digits))
        let d = try #require(declaredThresholds().first)

        #expect(
            pct == Int((d * 100).rounded()),
            """
            正文写「用量 ≥ \(pct)%」，而本节声明的阈值是 \(d)（= \(Int((d * 100).rounded()))%）。
            同一事实写了两处，其中一处改了另一处没改。
            """)
    }

    /// 判定必须**含等号** —— 设计稿写的是「用量 **≥** 90% 时切琥珀」。
    ///
    /// `>=` 与 `>` 的差别**只在正好等于阈值那一瞬间**看得见：设计稿画的 95% 样本
    /// 两种写法都会亮，界面上逐字相同。所以这条必须直接测边界，
    /// 而边界值**取自设计稿的声明**（不是常量自己跟自己比）。
    @Test func 高用量判定必须含等号() throws {
        let d = try #require(try declaredThresholds().first, "设计稿里没有 `data-meter-high` 声明")
        #expect(
            DesignTokens.Threshold.meterIsHigh(d),
            "正好等于阈值 \(d) 时不算高用量 —— 设计稿写的是「≥」，`>=` 多半被写成了 `>`")
        #expect(
            !DesignTokens.Threshold.meterIsHigh(d - 0.01),
            "阈值下方 0.01 就算高用量 —— 这一档的边界不是 \(d)")
    }

    // MARK: - 解析

    /// 一根容量条样本：在哪一页、百分比多少、有没有带 `.meter--high`。
    private struct Sample {
        let page: String
        let percent: Double
        let isHigh: Bool
    }

    /// `class="…"` 的属性值。
    private static let classAttr = try? NSRegularExpression(pattern: #"class="([^"]*)""#)
    /// 容量条填充的宽度（`style="width:30%"`）。
    private static let fillWidth = try? NSRegularExpression(pattern: #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#)
    /// 设计稿手写的阈值声明。
    private static let meterHighDecl = try? NSRegularExpression(pattern: #"data-meter-high="([0-9.]+)""#)
    /// 正文里那句「用量 ≥ NN%」—— 取正文那个数的**唯一**锚点。
    private static let usageAtLeast = try? NSRegularExpression(pattern: #"用量\s*≥\s*([0-9]+)%"#)

    /// 扫出所有容量条样本。
    ///
    /// ⚠️ 判「这是不是一根容量条」用的是**类名分词**，不是前缀：
    /// `class="meter__track"` / `class="meter__fill"` 里都没有 `meter` 这个词，
    /// 用 `hasPrefix("meter")` 会把它们也算进来（而它们里面没有 `width:NN%` 的语义）。
    ///
    /// ⚠️ `08-update.html` 的下载进度条是 `.progressline`（**没有** `.meter` 外壳）——
    /// 它是「下载进度」不是「磁盘占用」，天然被排除。别为了「扫全」把它捞进来：
    /// 42% 的进度条混进样本会让「区间下界」变成 42%。
    private func samples() throws -> [Sample] {
        var out: [Sample] = []
        for url in try screenFiles() {
            let html = try read(url)
            let page = url.lastPathComponent
            guard let attrRe = Self.classAttr, let widthRe = Self.fillWidth else { continue }
            for m in attrRe.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard
                    let full = Range(m.range, in: html),
                    let valueRange = Range(m.range(at: 1), in: html)
                else { continue }
                let tokens = Set(
                    html[valueRange].split(whereSeparator: { $0 == " " || $0 == "\t" })
                        .map(String.init))
                guard tokens.contains("meter") else { continue }

                let after = html[full.upperBound...]
                guard
                    let w = widthRe.firstMatch(
                        in: String(after), range: NSRange(after.startIndex..., in: after)),
                    let numRange = Range(w.range(at: 1), in: after),
                    let percent = Double(after[numRange])
                else { continue }

                out.append(
                    Sample(page: page, percent: percent, isHigh: tokens.contains("meter--high")))
            }
        }
        return out
    }

    /// 设计稿里所有 `data-meter-high` 的声明值。
    private func declaredThresholds() throws -> [Double] {
        guard let re = Self.meterHighDecl else { return [] }
        var out: [Double] = []
        for url in try screenFiles() {
            let html = try read(url)
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let r = Range(m.range(at: 1), in: html), let v = Double(html[r]) else {
                    continue
                }
                out.append(v)
            }
        }
        return out
    }

    /// 声明了阈值的那**一个小节**的 HTML（从它所在的外衣 `doc__section` 到下一个）。
    private func thresholdSection() throws -> String? {
        for url in try screenFiles() {
            let html = try read(url)
            guard let decl = html.range(of: "data-meter-high=") else { continue }
            let head = html[..<decl.lowerBound]
            let start =
                head.range(of: #"<div class="doc__section""#, options: .backwards)?.lowerBound
                ?? head.startIndex
            let tail = html[decl.upperBound...]
            let end =
                tail.range(of: #"<div class="doc__section""#)?.lowerBound ?? html.endIndex
            return String(html[start..<end])
        }
        return nil
    }

    // MARK: - 文件

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// `screens/` 下的真页面。
    ///
    /// ⚠️ 跳过 `_` 开头的文件：无头 Chrome 探针（`_probe_*.html`）曾残留在这一层，
    /// 被别的守卫当成真页面扫过（§8.47.8）。这里多一道保险 —— 一个探针里的
    /// `width:95%` 就能把「区间上界」搅乱，而症状是「守卫红了但页面没问题」。
    private func screenFiles() throws -> [URL] {
        let dir = repoRoot.appendingPathComponent("Design/ui/v2/screens")
        return
            try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "html" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// 打印用：`70.0` 写成 `70`，`95.5` 保留小数。
    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
