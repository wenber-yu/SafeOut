import Foundation
import Testing

/// 文档内部 **`§x.y` 交叉引用**的完整性守卫。
///
/// 为什么值得守：这份规范 **6700+ 行 / 561 处交叉引用**，
/// 而「引用了一节**不存在**的编号」**不会有任何报错** ——
/// 读者按引用翻过去，翻不到，只会以为自己看漏了。
/// 这一条我自己就写错过一次（§8.55.5 的标题自我引用），是被**肉眼**发现的。
///
/// ⚠️ **引用目标不止一个来源**（本轮连踩三个，见下面三条负向锚）：
///
/// 1. 标题编号有两种写法 —— `### 2.1 色彩`（**不带** `§`）与 `## §8.55 …`（带 `§`）。
///    只认带 `§` 的那批 ⇒ 报出 40 条假断链（实际 0 条）。
/// 2. **编号列表项**也是合法目标 —— `§8.35.7.1` 指的是 §8.35.7 下面第 1 条，不是一个小节标题。
/// 3. **跨文件**引用 —— `§4.2` / `§6.4` 指的是仓库根的 `SPEC.md`，不是本文件。
///
/// 三条都由**负向锚**钉住（§8.58 立的规矩：负向锚防假红）。
/// 少了任何一条，这个守卫就会在文档没坏的时候报错，然后被人关掉。
struct DocCrossReferenceTests {

    // MARK: 路径

    /// #filePath = <仓库根>/Tests/SafeOutAppTests/DocCrossReferenceTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var specURL: URL {
        repoRoot.appendingPathComponent("Design/ui/v2/DESIGN-SPEC.md")
    }

    private var rootSpecURL: URL {
        repoRoot.appendingPathComponent("SPEC.md")
    }

    // MARK: 守卫

    /// 正文引用的每一个 `§x.y` 都必须**真的存在**（三种来源任一）。
    @Test func 文档引用的章节必须存在() throws {
        let s = try load()

        // 正向锚：两张表都得有货
        #expect(s.headings.count >= 300, "只解析到 \(s.headings.count) 个标题 —— 文档没读到")
        #expect(s.referenceCount >= 400, "只解析到 \(s.referenceCount) 处引用 —— 引用侧的正则坏了")

        // 负向锚 ①：不带 `§` 的标题（第 2 章那批）必须在
        #expect(s.headings.contains("2.1"), "`2.1` 不在标题集 —— 只认了带 § 的标题（会假红 40 条）")
        // 负向锚 ②：编号列表项必须在（§8.35.7 下面第 1 条，不是小节标题）
        #expect(s.listItems.contains("8.35.7.1"), "`8.35.7.1` 不在 —— 列表项这条来源漏了（会假红）")
        // 负向锚 ③：只能由**仓库根 SPEC.md** 提供的编号（本文件第 4 章没有小节）
        #expect(s.headings.contains("4.2"), "`4.2` 不在 —— 跨文件（SPEC.md）这条来源漏了（会假红）")
        // 负向锚 ④：代码块**不能**贡献标题。DESIGN-SPEC 里有一段堆栈：
        // `#0  [AppKit] NSBeep` … `#8  [SafeOutApp] …` —— 不剥围栏就会凭空多出 0–8 九个「章」，
        // 它们会**掩盖真的断引用**（写错成 `§3` 却恰好有个假的 "3"）⇒ 这是**假阴性**，比假红更隐蔽。
        #expect(!s.headings.contains("0"), "标题集里出现了 `0` —— 代码块没剥掉（会假阴性）")

        #expect(
            s.broken.isEmpty,
            """
            这些 `§x.y` 引用**指向不存在的章节**：
            \(s.broken.map { "§\($0.0)（\($0.1) 次）" }.joined(separator: ", "))
            读者按引用翻过去会翻不到，只会以为自己看漏了。
            要么改成对的编号，要么补上那一节。
            """)
    }

    /// **反向**（有这一节、但没人引用）只记录 —— 孤立的小节不是错误，多数只是还没被提到。
    @Test func 定义了但没人引用的章节只记录不报警() throws {
        let s = try load()
        let referenced = Set(s.references.keys)
        let lonely = s.headings.subtracting(referenced)
            .filter { !$0.contains(".") }  // 只看章级：小节被父节引用就算数
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        print("[文档] 没有任何 `§` 引用的章：\(lonely.count) 个 —— \(lonely.joined(separator: ", "))")
    }

    // MARK: 扫描

    private struct Scan {
        /// 两个文档里所有标题的编号（**并集**，跨文件引用靠它）
        var headings: Set<String> = []
        /// 「标题编号 + 列表项序号」—— 例：`8.35.7.1`（§8.35.7 下面第 1 条）
        var listItems: Set<String> = []
        /// 引用 → 出现次数
        var references: [String: Int] = [:]
        var referenceCount = 0
        /// （引用，次数）—— 指向不存在章节的那些
        var broken: [(String, Int)] = []
    }

    private func load() throws -> Scan {
        var s = Scan()

        // ① 标题（两个文档）+ ② 标题下的编号列表项
        for url in [specURL, rootSpecURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var current = ""
            for line in Self.withoutCodeFences(try read(url)).split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                if let h = Self.firstMatch(in: l, pattern: #"^#+\s*§?([\d]+(?:\.[\d]+)*)"#) {
                    current = h
                    s.headings.insert(h)
                    continue
                }
                // 有序列表项：`1.` / `2)` 都算
                if !current.isEmpty, let n = Self.firstMatch(in: l, pattern: #"^\s*(\d+)[.)]\s"#) {
                    s.listItems.insert(current + "." + n)
                }
            }
        }

        // ③ 引用（只看设计稿规范；根 SPEC.md 里也有 `§` 但它引的多是本仓库其它文档）
        for m in Self.matches(in: Self.withoutCodeFences(try read(specURL)), pattern: #"§([\d]+(?:\.[\d]+)*)"#) {
            s.references[m, default: 0] += 1
            s.referenceCount += 1
        }

        // ④ 判定：标题 / 列表项 / 「有子节」（`§8.55` 可以指 §8.55.x 这一族）
        for (ref, n) in s.references {
            let hit =
                s.headings.contains(ref) || s.listItems.contains(ref)
                || s.headings.contains(where: { $0.hasPrefix(ref + ".") })
                || s.listItems.contains(where: { $0.hasPrefix(ref + ".") })
            if !hit { s.broken.append((ref, n)) }
        }
        s.broken.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        return s
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// 去掉 ``` 围栏里的内容。
    ///
    /// ⚠️ 不剥会把**代码块里的 `#` 行**当成 markdown 标题：
    /// DESIGN-SPEC 里有一段 AppKit 堆栈（`#0  [AppKit] NSBeep` … `#8  [SafeOutApp] …`），
    /// 于是凭空多出 0–8 九个「章」。它们不只会污染反向清单，
    /// 还会**掩盖真的断引用** —— 假阴性比假红隐蔽得多。
    private static func withoutCodeFences(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence { out.append(l) }
        }
        return out.joined(separator: "\n")
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        matches(in: text, pattern: pattern).first
    }
}
