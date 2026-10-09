import Foundation
import Testing

@testable import SafeOutApp

/// **文档里的表格必须「渲染得出来」** —— 这条此前一条守卫都没有，而它**真的丢过内容**。
///
/// ## 为什么值得守（2026-09-20 实测，见 §8.104.5）
///
/// 那张「仍开着」表上有三行，把「已关闭」说明写进了**多余的单元格**：
///
/// ```
/// | 35 | … | 我（下一轮） | §8.86.7 | ⬜ 仍开着（§8.86 新开）。… | ⚠️ **§8.89 追加**：… |
///                                                              ↑ 这个 `|` 让整行多出一格
/// ```
///
/// GFM 的规矩：**一行比表头多出的单元格会被忽略** ⇒ 渲染后**那一整段根本看不见**。
/// 用 `markdown-it`（commonmark + table）实测，三个探针**全部为 False**：
///
/// | 探针 | 源文件里 | 渲染后 |
/// |---|---|---|
/// | 第 35 行 `§8.89 追加` | 在 | **❌ 没了** |
/// | 第 38 行 `新开第 40 行` | 在 | **❌ 没了** |
/// | 第 39 行 `三分支` | 在 | **❌ 没了** |
///
/// ⇒ 三轮的「还账」在**渲染视图**里等于**没写**。这与本仓库的老毛病是同一个：
/// **「写了」不等于「生效了」** —— 只是这次的判据是**渲染器**，而它不报错、不警告，
/// 与「真没有」**逐字相同**。
///
/// ## 第二轴：**续行会把一张表撕开**
///
/// 单元格内容换行写（下一行不以 `|` 开头）看着舒服，但 GFM 的表**一行就是一行**。
/// 实测：第 34 / 36 行的续行让同一张表渲染成 **51 个 `<tr>`**（应为 **42**），
/// 续行变成独立行、正文挤进「#」列。⇒ **要换行请用 `<br>`**（本仓库别的表就是这么写的，见 §8.86.4）。
///
/// ## 两条判据都在这里，并且**自己也被验**（`表格判据的双向对照`）
///
/// 「没报缺陷」有两种可能：文档真的干净，或者**判据是瞎的**。两者输出逐字相同 ⇒
/// 必须拿「该报的样本」与「不该报的样本」各试一次。
///
/// ## ⚠️ 边界：**表尾**的续行查不出来
///
/// 「表块后面跟着一行非表格行」有两种含义 ——「表正常结束了」与「续行跑出去了」——
/// **在语法上长得一模一样**。所以判据只报**表中间**那一种（续行后面**又是** `|` 行）。
/// 表尾那一半靠的是「某张表最后一行必须是 `| 41 |`」这类**逐表**断言，本守卫不覆盖 ——
/// 别把「这条绿了」读成「所有表都渲染得出来」。
@Suite struct DocTableIntegrityTests {

    /// #filePath = <仓库根>/Tests/SafeOutAppTests/DocTableIntegrityTests.swift
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// 扫描范围 = **「会被 git 带进版本库的 `.md`」**（已入库 ∪ 未入库但未被忽略，当前 4 个）。
    /// 范围由 `trackedMarkdownFiles()` 一条命令给出（含 `--others`，理由见那里的注释）。
    ///
    /// ⚠️ **范围本身是判据**（§8.75）：2026-09-20 实测 —— `git ls-files '*.md'` 只有 4 个，
    /// 而此前这里只列了 2 个，**漏掉了 `README.md`（它有一个 10 行的「能力」表）**。
    /// ⇒ 凡是**在范围内**的 `.md` 都要进来；漏一份 = 那份文档里的表格永远没人守。
    ///
    /// **不进范围的**（有依据，不是漏）：`.workbuddy*/memory/*.md` —— 被 `.gitignore`
    /// 排除（`.gitignore:28` / `:30`）⇒ **CI 上根本不存在**，扫它们只会在 CI 上读不到文件。
    /// （本机实测它们有 199 个表块；要检查就手工跑 `.build/probe/round41/table_check.py`。）
    ///
    /// ⚠️ **别在这里抄表块数** —— 2026-09-20 实测：同一个数字此前在**三处**被抄成了 353
    /// （真值 354，见 §8.104.7）。要真值就用 `.build/probe/round41/blocks.swift` 打 ——
    /// **本守卫只断言下限（`>= 300`，约为当时实测总量的 83%），打印不出真值**，
    /// 所以「写错的数字」能在它这里活下来。
    private static let docs = [
        "Design/ui/v2/DESIGN-SPEC.md",
        // v3 界面合并的两份文档（设计规范修订版 + 开发交接单）。
        // ⚠️ 它们是随 v3 一并入库时**漏登记**的这一条守卫抓出来的（2026-09-30）——
        // 两份文档里各有十几张表，漏登记 = 那些表格永远没人守（§8.105 的 `README.md` 同款）。
        "Design/ui/v3/DESIGN-SPEC.md",
        "Design/ui/v3/HANDOFF.md",
        // 本次「接管访达的推出」的两份增量文档（PM 的 PRD + 架构师的设计）。
        // 它们都是**会被提交**的 `.md`，因此必须在范围内 —— 否则里面的表格
        // 永远没人守（§8.105 实测漏了 `README.md` 就是这个后果）。
        "Design/prd/incremental-takeover-finder-eject.md",
        "Design/architecture/incremental-takeover-finder-eject.md",
        "Design/architecture/eject-takeover-pivot.md",
        "SPEC.md",
        "README.md",
        "Release-notes/README.md",
    ]

    /// **会被 git 带进版本库的 `.md`**；拿不到输出返回 `nil`。
    ///
    /// ⚠️ **必须带 `--others`（未入库文件也在范围内）** —— 2026-09-21 实测踩到，
    /// 而且咬的是**守卫自己**：只写 `ls-files`（= 只看 `--cached`）时，
    /// **刚建、还没 `git add` 的新文档不进范围** ⇒ 它里面的表格违规在**本地全绿**、
    /// **推上去才红**（CI 上它已入库）。「范围窄了」与「那份文档干净」在输出上**逐字相同**。
    /// 同一课在 `ToolingClaimTests.gitLsFiles` 上先咬过一次（那边当时逃掉的是新脚本）。
    ///
    /// ⚠️ **加了 `--others` 也不会把构建产物扫进来**：`.build/`(`.gitignore:3`)、
    /// `.workbuddy/`(`:33`)、`.workbuddy-ai/`(`:35`) 全被忽略，靠 `--exclude-standard` 排除。
    /// 本机实测：旧范围 4 个、新范围**也是 4 个**（此刻盘上无未入库的 `.md`）。
    ///
    /// ⚠️ 副作用（**故意的**）：本地若躺着一个**未声明**的未入库 `.md`，
    /// `扫描范围必须覆盖所有会被提交的文档` 会红 ⇒ 逼你「要么加进 `docs`、要么写清为什么不扫」。
    /// 这是安全方向 —— 红比静默漏扫好。
    ///
    /// ⚠️ **用 git，而不是自己遍历文件系统**：判据的原话是「**凡被 git 跟踪的 `.md`
    /// 都要在列表里**」（§8.105）—— 而 `.gitignore` 的规则**由 git 自己解释**。
    /// 自己写一份「跳过哪些目录」等于又添一份会漂的手写清单（正是本节要防的病）。
    ///
    /// `core.quotePath=false` 防的是 git 把非 ASCII 文件名转义成 `\xxx`
    /// （本仓库路径现在全是 ASCII，但这行不该在下一个人加中文路径时变成坑）。
    static func trackedMarkdownFiles() async -> [String]? {
        let output = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "-C", repoRoot.path, "-c", "core.quotePath=false",
                    "ls-files", "--cached", "--others", "--exclude-standard", "*.md",
                ],
                timeout: 15
            ) { c.resume(returning: $0) }
            run.start()
        }
        guard let output else { return nil }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: 判据（纯函数 —— 样本可以直接喂给它，不必改仓库里的文档）

    struct Defect: CustomStringConvertible {
        var line: Int
        var what: String
        var description: String { "L\(line)：\(what)" }
    }

    struct Result {
        var blocks = 0
        var defects: [Defect] = []
    }

    /// **未转义**的 `|` 个数。`\|` 是转义（本仓库在单元格里写 `尚未\|还没` 就是这么写的），
    /// 不算列分隔符 —— 漏了这一条会报出成片假红（本守卫的第一版就栽在这儿）。
    static func unescapedPipes(_ s: String) -> Int {
        var n = 0
        var prev: Character?
        for ch in s {
            if ch == "|", prev != "\\" { n += 1 }
            prev = ch
        }
        return n
    }

    /// 分隔行 `|---|---|`。
    static func isSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        let inner = t.dropFirst().dropLast()
        return !inner.isEmpty && inner.allSatisfy { $0 == "-" || $0 == "|" || $0 == " " || $0 == ":" }
    }

    /// 剥掉围栏代码块（围栏里的 `|` 不是表格）。**保留行数**，这样报出来的行号仍是对的。
    static func stripFences(_ raw: String) -> [String] {
        var out: [String] = []
        var inFence = false
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
                out.append("")
                continue
            }
            out.append(inFence ? "" : line)
        }
        return out
    }

    /// 扫一份文档，返回表块数与结构缺陷。
    static func scan(_ raw: String) -> Result {
        let lines = stripFences(raw)
        var res = Result()
        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix("|") else {
                i += 1
                continue
            }
            let start = i
            while i < lines.count, lines[i].hasPrefix("|") { i += 1 }
            let end = i - 1
            res.blocks += 1

            // ① 撕表：表块后面紧跟一行「非空、不以 `|` 开头」，而**再下一行又是** `|`
            //    ⇒ 那一行是续行，渲染时会把表撕成两张（本仓库实测 51 个 <tr> vs 应有的 42）。
            if i < lines.count,
                !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                !lines[i].hasPrefix("|"),
                i + 1 < lines.count, lines[i + 1].hasPrefix("|")
            {
                res.defects.append(
                    Defect(line: end + 2, what: "表被非表格行打断 —— 续行会渲染成独立行，请改用 `<br>`"))
            }

            // ② 列数：每一行必须与**本块表头**一样多（多出的单元格渲染时会被丢掉）
            guard end > start else { continue }
            let want = unescapedPipes(lines[start])
            for j in (start + 1)...end where !isSeparator(lines[j]) {
                let got = unescapedPipes(lines[j])
                if got != want {
                    res.defects.append(
                        Defect(
                            line: j + 1,
                            what: "未转义管道 \(got) ≠ 表头 \(want) —— 多出的单元格渲染时会被丢掉（等于没写）"))
                }
            }
        }
        return res
    }

    // MARK: 守卫

    @Test func 文档里的表格必须渲染得出来() throws {
        var blocks = 0
        var defects: [String] = []
        for doc in Self.docs {
            let raw = try read(doc)
            let r = Self.scan(raw)
            blocks += r.blocks
            defects += r.defects.map { "\(doc) \($0)" }
        }

        // 正向锚：表块数不能塌 —— 否则「没缺陷」只是「没扫到」（假绿）
        #expect(blocks >= 300, "只解析到 \(blocks) 个表块 —— 扫描口径失效了（假绿）")

        #expect(
            defects.isEmpty,
            """
            文档里有 \(defects.count) 处表格结构缺陷（最多列 10 条）：
            \(defects.prefix(10).joined(separator: "\n"))
            这些内容在**渲染视图里看不见**（多余单元格被丢 / 续行把表撕开），
            而源文件读起来一切正常 —— 「写了」不等于「生效了」。
            """)
    }

    /// ⚠️ **判据自己也要验**：拿「该报的」与「不该报的」各试一次。
    /// 少了这一步，「全绿」与「装置瞎了」是分不开的（本仓库 §8.96.4 的原话）。
    @Test func 表格判据的双向对照() {
        // 该报 ①：撕表（续行）
        let torn = [
            "| a | b |",
            "|---|---|",
            "| 1 | 2 |",
            "这一行不以 | 开头，是续行",
            "| 3 | 4 |",
        ].joined(separator: "\n")
        #expect(!Self.scan(torn).defects.isEmpty, "撕表的样本没被报出来 —— 判据在这一轴上是瞎的")

        // 该报 ②：多余单元格
        let extraCell = [
            "| a | b |",
            "|---|---|",
            "| 1 | 2 | 多出来的这一格会被渲染丢掉 |",
        ].joined(separator: "\n")
        #expect(!Self.scan(extraCell).defects.isEmpty, "多余单元格的样本没被报出来 —— 判据在这一轴上是瞎的")

        // 不该报：干净的表
        let clean = [
            "| a | b |",
            "|---|---|",
            "| 1 | 2 |",
            "| 3 | 4 |",
        ].joined(separator: "\n")
        #expect(Self.scan(clean).defects.isEmpty, "干净的样本被误报 —— 判据过严（会变成假红）")

        // 不该报：转义的 `\|` 不是分隔符（本仓库真的这么写）
        let escaped = [
            "| a | b |",
            "|---|---|",
            #"| 1 | `尚未\|还没` |"#,
        ].joined(separator: "\n")
        #expect(Self.scan(escaped).defects.isEmpty, "`\\|` 被当成了分隔符 —— 会报成片假红")

        // 不该报：围栏代码块里的 `|` 不是表格
        let fenced = [
            "```",
            "| 这不是表 | 真的不是 |",
            "```",
        ].joined(separator: "\n")
        #expect(Self.scan(fenced).blocks == 0, "围栏代码块被当成表格扫了")
    }

    /// ⚠️ **`docs` 是手写的 ⇒ 会腐化**：§8.105 实测漏了 `README.md`（它有一个 10 行的
    /// 「能力」表，而当时没人发现）。这条把「**凡在范围内的 `.md` 都要在列表里**」
    /// 从一句判据变成**可执行**的断言 —— 判据只写在注释里没人执行，等于没有。
    ///
    /// 两个方向都查：**漏**（在范围内却没进列表）与**多**（列表里有、但不在范围内）。
    /// 后者看着无害，其实最阴：路径拼错 / 文件已删 ⇒ 这条守卫一直「绿」，
    /// 而那份文档**一次都没被扫过**。
    ///
    /// ⚠️ **名字里的「会被提交」= `trackedMarkdownFiles()` 的口径**
    /// （已入库 ∪ 未入库但未被忽略）。2026-09-21 之前它叫「必须覆盖所有**被跟踪**的文档」——
    /// 加了 `--others` 之后那个名字**不再准确**（未入库的新文档也在范围内），故更名。
    @Test func 扫描范围必须覆盖所有会被提交的文档() async throws {
        let listed = await Self.trackedMarkdownFiles()
        let tracked = try #require(
            listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「范围没问题」）")

        // 正向锚：数量不能塌 —— 否则下面那句「没漏」只是「没扫到」
        #expect(tracked.count >= 4, "只列出 \(tracked.count) 个 .md —— 装置口径失效了（假绿）")

        let missing = tracked.filter { !Self.docs.contains($0) }
        #expect(
            missing.isEmpty,
            """
            这些**在扫描范围内**的 `.md` 没进 `docs` 列表：\(missing.joined(separator: "、"))
            漏一份 = 那份文档里的表格**永远没人守**（§8.105 实测漏了 `README.md`）。
            请把它们加进 `docs`；若确实不该扫，就在 `docs` 的注释里写明**为什么**。
            """)

        let unknown = Self.docs.filter { !tracked.contains($0) }
        #expect(
            unknown.isEmpty,
            """
            `docs` 里有 \(unknown.count) 个**不在**扫描范围内的 `.md`：\(unknown.joined(separator: "、"))
            路径拼错 / 文件已删 / 已被 gitignore ⇒ 守卫一直「绿」，而那份文档其实没被扫过。
            """)
    }
}
