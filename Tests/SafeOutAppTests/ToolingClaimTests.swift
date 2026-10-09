import Foundation
import Testing

@testable import SafeOutApp

/// **「活文件」里写死的门槛数量会漂** —— 2026-09-20 实测（§8.108）。
///
/// 门槛从最初的两道（零警告构建 + `swift-format --strict`）一路加到 **5 道**
/// （中间陆续加了「注释承诺句」「脚本冒烟」「测试与覆盖率」），
/// 而三处**活文件**仍停在旧数字上：
///
/// | 文件 | 当时写的 | 实际 |
/// |---|---|---|
/// | `run.sh`（`check` 用法注释） | 「CI 的**两道**严格门槛」 | 5 道 |
/// | `build_app.sh`（`STRICT_CI` 说明，2 处） | 「CI 的**两道**严格门槛」 | 5 道 |
/// | `.github/workflows/ci.yml`（注释） | 「**三道**严格门槛」 | 5 道 |
///
/// 危害不是「数字难看」：**读的人据此低估了检查范围**。
/// `run.sh` 那行尤其糟 —— 它说 `check` 只做「构建 + 格式」，
/// 而「注释承诺句」那道**从头到尾没在任何注释里出现过**，
/// 于是「本地门槛会拦下什么」这件事只能靠读 `preflight.sh` 才知道。
///
/// ## 为什么单独守这一条，而不是「把数字改对」
///
/// 与 §8.104 同族：**同一个事实写在多处 ⇒ 一定会漂，而且会把错一起复制过去**。
/// 改数字只是把这一次改对；下一次加门槛，同样三处又会漂。
/// ⇒ 本守卫守的不是「数字对不对」，而是「**这里不许有写死的数字**」。
///
/// ## 扫描范围 = 「活文件」，而且是**机械枚举**出来的
///
/// 活文件 = **被 git 跟踪**、且满足下面任一条：
/// 1. 扩展名是 `yml` / `yaml`；
/// 2. **首行是 `#!`**（shebang）。
///
/// ⚠️ 第 2 条不是凑数：本仓库有**没有扩展名的可执行脚本**（`Scripts/test/fake-gh/gh`），
/// 只按扩展名枚举会把它漏掉 —— 而「漏一个文件」与「那个文件干净」在输出上**逐字相同**
/// （§8.105 的原话）。`扫描范围必须覆盖全部活工具文件` 就是钉这件事的。
///
/// ⚠️ **`DESIGN-SPEC.md` / `2026-09-20.md` 这类文档不进范围**，不是因为「漏了」：
/// 它们写的是**当时的记录**（「三道门槛全绿」在写下那一刻是真的），
/// 改它们等于篡改历史。范围靠「是不是 shebang/YAML」机械切分，不靠手写排除表。
@Suite struct ToolingClaimTests {

    /// #filePath = <仓库根>/Tests/SafeOutAppTests/ToolingClaimTests.swift
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: 判据（纯函数 —— 样本可以直接喂给它，不必去改仓库里的文件）

    struct Claim: CustomStringConvertible {
        var line: Int
        var hit: String
        var description: String { "L\(line)：\(hit)" }
    }

    /// 「**数量 + 道门槛**」。数量可以是阿拉伯数字，也可以是中文数词
    /// （本仓库两种都真的写过：`3 道严格门槛` / `两道严格门槛`）。
    ///
    /// ⚠️ `\$\{GATE_NO\}` 这类**变量**不算写死 —— 它是从实际跑的轮数派生的，
    /// 正是我们想要的那种写法。判据里的数量类**不含**字母，所以 `N 道门槛`
    /// （文档里的占位符写法）也不会被误报。
    static let gateCountPattern = #"[0-9一二三四五六七八九十两]+[ \t]*道(?:严格)?门槛"#

    static func gateCountClaims(in text: String) -> [Claim] {
        guard let re = try? NSRegularExpression(pattern: gateCountPattern) else { return [] }
        var out: [Claim] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
                let r = Range(m.range, in: s)
            else { continue }
            out.append(Claim(line: i + 1, hit: String(s[r])))
        }
        return out
    }

    // MARK: 第二轴：bash 3.2 在 UTF-8 locale 下会连坐变量名

    /// ⚠️ **`$变量` 紧跟全角标点时，bash 3.2 会把那个字符算进变量名**（实测，本轮 CI 红）。
    ///
    /// ```
    /// $ LC_ALL=en_US.UTF-8 bash -c 'set -u; f(){ local n="$1"; echo "✘ $n：x"; }; f abc'
    /// bash: n?: unbound variable        ← 变量名被解析成 `n` + 全角冒号
    /// $ LC_ALL=C       …同上…             ✘ abc：x        ← 换 C locale 就没事
    /// $ LC_ALL=en_US.UTF-8 bash -c '… echo "✘ ${n}：x" …'  ✘ abc：x        ← 加花括号即可
    /// ```
    ///
    /// 病根：bash 3.2 用 `isalnum(字节)` 判断变量名字符，而在**多字节 locale** 下
    /// 它对高位字节返回真 ⇒ `$n` 后面的全角冒号 / 全角括号 / 全角逗号 / 中文，
    /// 全都被当成变量名的一部分。
    ///
    /// **它为什么躲过了本地门槛**：本机环境**没有** `LANG` / `LC_*`（locale 是 C），
    /// 而 CI runner 设了 `LC_ALL: en_US.UTF-8` ⇒ **本地全绿、CI 红**。
    /// 2026-09-20 实测：门槛 4（脚本冒烟）在 CI 上报
    /// `ci_status_smoke.sh: line 65: name: unbound variable`，本地一次都没红过。
    ///
    /// ⚠️ 比「红」更糟的是**不红**：脚本若没开 `set -u`，bash 会把它当成
    /// **另一个不存在的变量**静默展开成空 —— 输出少几个字，不报错。
    /// 本仓库 `Scripts/ci_status.sh` 那几处正是这样（`set -u` 下才会红，
    /// 而它只在**开发者本机**跑，本机 locale 是 C ⇒ 一直没暴露）。
    ///
    /// ⚠️ **口径：只管「具名变量」，不管位置参数** —— 这是实测出来的，不是猜的
    /// （2026-09-21 判别实验，同一个脚本两种 locale 各跑一遍）：
    /// ```
    /// $ST（期望 1）   → C locale 正常 / en_US.UTF-8 报 `ST�: unbound variable`
    /// $1（尾注）      → **两种 locale 都正常**
    /// ```
    /// 原因：位置参数不会被延长（`$1` 后面跟的非数字字符本来就终止它）。
    /// ⇒ 正则写成 `\$([A-Za-z_][A-Za-z0-9_]*)` 就够，**别去管 `$1`**；
    /// 也**别**把它扩成「`$` 后面跟任何东西」，那会制造一堆假阳性。
    /// （这条口径有**负向对照**：`变量引用判据的双向对照` 的「不该报 ③」。）
    static func unbracedVarBeforeMultibyte(in text: String) -> [Claim] {
        guard let re = try? NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#) else { return [] }
        var out: [Claim] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let s = String(line)
            for m in re.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) {
                // `${name}` 不受影响（`$` 后面是 `{`，根本进不了这个正则）
                guard let nameR = Range(m.range(at: 1), in: s) else { continue }
                // 取变量名后面**那一个字符**（Swift 的 Character ⇒ 能正确处理非 BMP）
                guard let next = s[nameR.upperBound...].first,
                    !next.unicodeScalars.allSatisfy({ $0.isASCII })
                else { continue }
                out.append(Claim(line: i + 1, hit: "$\(s[nameR]) 紧跟 \(next)"))
            }
        }
        return out
    }

    // MARK: 第三轴：grep 的**正则方言**（BRE / ERE 各有一个静默陷阱）

    /// ⚠️ 本仓库在这两条上各踩过**多次**，而且失败都是**静默**的 ——
    /// 命令不报错，只是「条件永远不成立」，于是**红绿一律判成绿**：
    ///
    /// | 写法 | 实际 | 后果 |
    /// |---|---|---|
    /// | `grep -q 'A\|B'`（**BRE**） | BSD grep 的 BRE **不支持 `\|` 交替** | 条件**永远不成立** ⇒ 变异装置把每一条都报成「仍绿」 |
    /// | `grep -cE '(?:A)'`（**ERE**） | ERE 也没有**非捕获组**，被当字面量 | 计数恒 0，`&&` 链被退出码 1 吃掉 |
    ///
    /// 累计 8 次以上，最近一次是 2026-09-20：判「内容在不在盘上」时 `grep` 返回空，
    /// 而内容**确实在**。⇒ 与「装置瞎了」逐字相同，是最难发现的那种失败。
    ///
    /// ⚠️ **注释不算**：仓库里正有一条注释写着这个坑（`# ⚠️ BSD grep 的 BRE 不支持 …`），
    /// 它自己含 `\|`。判据按「trim 后以 `#` 开头」跳过注释行 —— 否则守卫会逼人
    /// **删掉那条警示**，那比没有守卫更糟。
    static func grepDialectTraps(in text: String) -> [Claim] {
        var out: [Claim] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let s = String(line)
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            guard s.contains("grep") else { continue }
            // ⚠️ **E 可能在旗标簇里**（`-cE` / `-rnE` / `-qE`…），光找 `grep -E` 会漏 ⇒ 判据瞎了一半。
            let isERE =
                (try? NSRegularExpression(pattern: #"grep\s+-[A-Za-z]*E[A-Za-z]*\b"#))?
                .firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
            if !isERE, s.contains(#"\|"#) {
                out.append(Claim(line: i + 1, hit: #"grep（BRE）用了 `\|` 交替 —— 条件永远不成立"#))
            }
            if isERE, s.contains("(?:") {
                out.append(Claim(line: i + 1, hit: "`grep -E` 用了 `(?:` —— ERE 没有非捕获组"))
            }
        }
        return out
    }

    // MARK: 第四轴：双引号里的**反引号**

    /// ⚠️ 双引号里的反引号会被 bash 当**命令替换**执行 —— 与上一轴同源（都是静默错），
    /// 但症状不同：上一轴是「静默换一个变量名」，这一轴是「静默跑一条命令」。
    ///
    /// 2026-09-28 实发 v2026.09.28.2 当天踩的（两处）：
    /// ```
    /// say "  版本号将由 build_app.sh 从 `git describe` 派生"   # ← 会真的跑一次 git describe
    /// printf '…' "say '  从 `git describe` 派生'"              # ← 同上
    /// ```
    /// 后果是**回显里那一块变成空**（`set -u` 下若那条命令不存在则报
    /// `line N: xxx: command not found`，而 `echo` 照常输出 ⇒ 信息是错的但不报错）。
    /// 本仓库 `Scripts/preflight.sh` 里也踩过一次（症状是 `line N: ✗: command not found`）。
    ///
    /// ⚠️ **`bash -n` 查不出来**：语法完全合法。只能静态扫。
    ///
    /// 判据：剥掉单引号段（单引号里的反引号是安全的，不会被展开）之后，
    /// 若同一行**同时**含反引号与双引号 ⇒ 报。
    /// ⚠️ 转义过的 `` \` `` 不算 —— 它在双引号里是字面量。
    ///
    /// ⚠️ **必须认得 heredoc**（2026-09-28 第一版没认 ⇒ 5 处假阳性全在
    /// `Scripts/test/dmg_layout_smoke.sh` 里，一处理都没有）：
    /// 那个 `.sh` 是 bash 包着一段 **Python**（`"$PY" - … <<'PY'`），
    /// 而定界符**带引号** ⇒ heredoc 正文 bash **一字不展开** ⇒ 里面的反引号是安全的。
    /// （定界符**不带引号**的 heredoc 会展开 ⇒ 那种正文照扫。）
    static func backtickInsideDoubleQuotes(in text: String) -> [Claim] {
        let heredocRe = try? NSRegularExpression(
            pattern: #"<<-?[ \t]*(?:'([^']+)'|"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))"#)
        var out: [Claim] = []
        var skipUntil: String?

        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let s = String(line)
            if let delim = skipUntil {
                if s.trimmingCharacters(in: .whitespaces) == delim { skipUntil = nil }
                continue
            }

            var scan = s
            if let re = heredocRe,
                let m = re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s))
            {
                // 只有**带引号**的定界符才让正文免于展开（第 1/2 组）
                var quotedDelim: String?
                for g in 1...2 where m.range(at: g).location != NSNotFound {
                    if let r = Range(m.range(at: g), in: s) {
                        quotedDelim = String(s[r])
                        break
                    }
                }
                if let d = quotedDelim {
                    skipUntil = d
                    // heredoc **之前**的那一截仍是 bash，照扫
                    if let r = Range(m.range, in: s) { scan = String(s[s.startIndex..<r.lowerBound]) }
                }
            }

            if scan.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            // 先去掉转义的反引号（字面量，安全）
            let escaped = scan.replacingOccurrences(of: "\\`", with: "")
            // 再剥单引号段：单引号内不做任何展开
            let stripped =
                (try? NSRegularExpression(pattern: "'[^']*'"))?
                .stringByReplacingMatches(
                    in: escaped, range: NSRange(escaped.startIndex..<escaped.endIndex, in: escaped),
                    withTemplate: "") ?? escaped
            guard stripped.contains("`"), stripped.contains("\"") else { continue }
            out.append(Claim(line: i + 1, hit: "双引号里有反引号（会被当命令替换执行）"))
        }
        return out
    }

    // MARK: 范围

    /// `git ls-files --cached --others --exclude-standard <patterns…>`；拿不到输出返回 `nil`。
    ///
    /// ⚠️ **用 git，而不是自己遍历文件系统**：`.gitignore` 的规则**由 git 自己解释**，
    /// 自己写一份「跳过哪些目录」等于又添一份会漂的手写清单 —— 那正是本节要防的病（§8.105）。
    ///
    /// ⚠️ **必须带 `--others`（未入库文件也在范围内）** —— 2026-09-21 实测踩到：
    /// 只写 `ls-files`（= 只看 `--cached`）时，**刚建、还没 `git add` 的新脚本不进范围**。
    /// 于是同一条违规在**本地全绿**（`stamp_lines_smoke.sh` 当时是 untracked）、
    /// **推上去才红**（CI 上它已入库）。「范围窄了」与「那个文件干净」在输出上
    /// **逐字相同** —— 正是 §8.105 那句原话，这次它咬的是**守卫自己**。
    /// ⚠️ 而 `.build/` 之类**被忽略**的目录靠 `--exclude-standard` 排除，
    /// 所以加了 `--others` 也不会把构建产物扫进来（实测：189 → 191，多的正是两个新脚本）。
    static func gitLsFiles(_ patterns: [String] = []) async -> [String]? {
        let output = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "-C", repoRoot.path, "-c", "core.quotePath=false",
                    "ls-files", "--cached", "--others", "--exclude-standard",
                ] + patterns,
                timeout: 15
            ) { c.resume(returning: $0) }
            run.start()
        }
        guard let output else { return nil }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// **未入库**文件的清单 —— 用**另一条 git 命令**取（`status --porcelain` 默认就报
    /// 未跟踪文件）。拿不到输出返回 `nil`。
    ///
    /// ⚠️ 存在的理由：给「枚举范围」做交叉自证时，**不能拿 `ls-files` 跟 `ls-files` 对拍** ——
    /// 两条同源命令会**共享同一个盲点**（2026-09-21：`扫描范围必须覆盖全部活工具文件`
    /// 原本就是这样，于是它对「漏了未入库文件」这件事**一个字都说不出来**）。
    static func gitUntrackedFiles() async -> [String]? {
        let output = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "-C", repoRoot.path, "-c", "core.quotePath=false",
                    "status", "--porcelain", "--untracked-files=all",
                ],
                timeout: 15
            ) { c.resume(returning: $0) }
            run.start()
        }
        guard let output else { return nil }
        // 每行形如 `?? path`；只取未跟踪那一类（改/删的文件不影响本判据）。
        return
            output.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("?? ") }
            .map { String($0.dropFirst(3)) }
    }

    /// 文件首行；读不到返回 `nil`。只读 512 字节 —— 判断 shebang 用不着整个文件
    /// （仓库里有几百 KB 的 `DESIGN-SPEC.md`，逐个整读纯属浪费）。
    static func firstLine(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 512) else { return nil }
        return String(decoding: data, as: UTF8.self).prefix { $0 != "\n" }.description
    }

    /// 单个文件算不算「活文件」：扩展名是 `yml`/`yaml` **或** 首行是 `#!`。
    ///
    /// ⚠️ 抽成函数是为了让「范围交叉自证」能用**同一个判据**去筛**另一条** git 命令的输出 ——
    /// 判据若各写一份，两边会各自漂（那正是本节要防的病）。
    static func isLiveToolingFile(_ rel: String) -> Bool {
        let url = repoRoot.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue
        else { return false }
        if ["yml", "yaml"].contains(url.pathExtension) { return true }
        return firstLine(of: url)?.hasPrefix("#!") == true
    }

    /// 只挑 **bash** 脚本：`.sh`，或 shebang 里含 `bash`。
    ///
    /// ⚠️ **为什么必须筛**：反引号陷阱是 **bash 专属**（Python 不展开反引号），
    /// 而「活文件」里有一批 `.py`（`Scripts/test/*.py`、`Tools/*.py`）—— 它们拿反引号
    /// 当 Markdown 引用符与 `repr` 用，一抓一大把 ⇒ **假红** ⇒ 会逼人关掉守卫。
    /// 2026-09-28 第一版没筛，当场报出 11 处全部在 `.py` 里，一条真的都没有。
    ///
    /// ⚠️ 判据用 shebang **而不是**只看 `.sh`：仓库里有**无扩展名**的 bash 脚本
    /// （`run.sh` 有扩展名，但 `isLiveToolingFile` 的存在理由正是「不能只认扩展名」）。
    static func isBashScript(_ rel: String) -> Bool {
        let url = repoRoot.appendingPathComponent(rel)
        if url.pathExtension == "sh" { return true }
        return (firstLine(of: url) ?? "").contains("bash")
    }

    /// 「活文件」清单：**入库的与未入库的都要**（只要没被 `.gitignore` 排掉），
    /// 且满足 `isLiveToolingFile`。⚠️ 为什么必须含未入库的，见 `gitLsFiles` 的抬头。
    static func liveToolingFiles() async -> [String]? {
        guard let all = await gitLsFiles() else { return nil }
        return all.filter { Self.isLiveToolingFile($0) }
    }

    // MARK: 守卫

    @Test func 活文件里不得写死门槛数量() async throws {
        let listed = await Self.liveToolingFiles()
        let live = try #require(
            listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「没有写死门槛数量」）")

        // 正向锚：文件数不能塌 —— 否则下面那句「没写死」只是「没扫到」（假绿）
        #expect(live.count >= 12, "只枚举到 \(live.count) 个活文件 —— 范围口径失效了（假绿）")

        var claims: [String] = []
        for rel in live {
            claims += Self.gateCountClaims(in: try read(rel)).map { "\(rel) \($0)" }
        }

        #expect(
            claims.isEmpty,
            """
            这些**活文件**里写死了门槛数量（\(claims.count) 处）：
            \(claims.joined(separator: "\n"))
            门槛会加，数字会漂 —— 2026-09-20 实测：门槛已加到 5 道，而 `run.sh` 仍写「两道」、
            `ci.yml` 仍写「三道」，读的人据此**低估了检查范围**。
            改法：别写数字，指向唯一实现（「过 CI 的门槛，见 `Scripts/preflight.sh`」），
            或在注释里说明「要清单就跑 `./run.sh check`」——它逐道打印标题。
            """)
    }

    /// bash 3.2 那条：**活文件里的 `$变量` 后面不许紧跟多字节字符**（改 `${变量}` 即可）。
    ///
    /// ⚠️ 这条**必须静态扫**，不能靠「跑一遍」：脚本只在**特定 locale** 下才炸，
    /// 而本机 locale 是 C ⇒ 跑一遍永远是绿的。2026-09-20 的 CI 红就是这么漏出来的。
    @Test func 活文件里变量引用不得紧跟多字节字符() async throws {
        let listed = await Self.liveToolingFiles()
        let live = try #require(
            listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「没有这个坑」）")
        #expect(live.count >= 12, "只枚举到 \(live.count) 个活文件 —— 范围口径失效了（假绿）")

        var claims: [String] = []
        for rel in live {
            claims += Self.unbracedVarBeforeMultibyte(in: try read(rel)).map { "\(rel) \($0)" }
        }

        #expect(
            claims.isEmpty,
            """
            这些**活文件**里 `$变量` 紧跟了多字节字符（\(claims.count) 处）：
            \(claims.joined(separator: "\n"))
            bash 3.2 在 **UTF-8 locale** 下会把那个字符算进**变量名**
            ⇒ `set -u` 时报 `unbound variable`，不开 `set -u` 则**静默展开成空**。
            本机 locale 是 C 所以**永远不红**，CI 设了 `LC_ALL=en_US.UTF-8` 就炸
            （2026-09-20 实测：门槛 4 在 CI 报 `name: unbound variable`，本地一次没红）。
            改法：写成 `${变量}`。
            """)
    }

    /// 第三轴：grep 的方言。**同样必须静态扫** —— 这两个坑都不报错，
    /// 只是让条件**永远不成立**，跑一遍永远是绿的（而且绿得毫无信息量）。
    @Test func 活文件里grep的正则方言不得用错() async throws {
        let listed = await Self.liveToolingFiles()
        let live = try #require(
            listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「没有这个坑」）")
        #expect(live.count >= 12, "只枚举到 \(live.count) 个活文件 —— 范围口径失效了（假绿）")

        var claims: [String] = []
        for rel in live {
            claims += Self.grepDialectTraps(in: try read(rel)).map { "\(rel) \($0)" }
        }

        #expect(
            claims.isEmpty,
            """
            这些**活文件**里的 grep 用错了正则方言（\(claims.count) 处）：
            \(claims.joined(separator: "\n"))
            `grep`（BRE）不支持 `\\|` 交替、`grep -E`（ERE）不支持 `(?:` ——
            两者都**不报错**，只是让条件永远不成立（或计数恒 0）。
            改法：交替用 `grep -E 'A|B'`，或 `-e A -e B`。
            """)
    }

    /// ⚠️ **判据自己也要验**：拿「该报的」与「不该报的」各试一次。
    /// 少了这一步，「全绿」与「正则根本没编译成功」是分不开的（§8.96.4 的原话）。
    @Test func 门槛数量判据的双向对照() {
        // 该报 ①：阿拉伯数字（`ci.yml` 真的这么写过）
        #expect(
            !Self.gateCountClaims(in: "# 3 道严格门槛：零警告构建…").isEmpty,
            "阿拉伯数字没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ②：中文数词（`run.sh` / `build_app.sh` 真的这么写过）
        #expect(
            !Self.gateCountClaims(in: "# 不启动，只过 CI 的两道严格门槛").isEmpty,
            "中文数词没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ③：不带「严格」二字（`ci_status.sh` 真的这么写过）
        #expect(
            !Self.gateCountClaims(in: "本地门槛每轮都报「4 道门槛全绿」").isEmpty,
            "「N 道门槛」没被报出来 —— 判据只认「严格门槛」这一种写法")

        // 不该报 ①：`${GATE_NO}` 是**从实际轮数派生**的，正是该用的写法
        #expect(
            Self.gateCountClaims(in: #"echo " ✅ ${GATE_NO} 道门槛全部通过""#).isEmpty,
            "把变量当成了写死的数字 —— 会变成假红，逼人关掉守卫")
        // 不该报 ②：只是提到「门槛」，没有数量
        #expect(
            Self.gateCountClaims(in: "本脚本是**全部门槛的唯一实现**").isEmpty,
            "没有数量也被报了 —— 判据太松")
        // 不该报 ③：`N` 是文档里的占位符，不是某个具体数字
        #expect(
            Self.gateCountClaims(in: "别在任何活文件里写死「N 道门槛」").isEmpty,
            "占位符 `N` 被当成了数字")
    }

    /// 第二轴的双向对照。少了它，「正则没编译成功」与「真的干净」分不开。
    @Test func 变量引用判据的双向对照() {
        // 该报 ①：全角冒号（本轮 CI 红的那一行就长这样）
        #expect(
            !Self.unbracedVarBeforeMultibyte(in: #"echo "✘ $name：期望退出码""#).isEmpty,
            "全角冒号没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ②：全角括号
        #expect(
            !Self.unbracedVarBeforeMultibyte(in: #"echo "（$status）""#).isEmpty,
            "全角括号没被报出来")
        // 该报 ③：直接跟中文（同样会被算进变量名）
        #expect(
            !Self.unbracedVarBeforeMultibyte(in: #"echo "共 $count处""#).isEmpty,
            "变量名紧跟中文没被报出来")

        // 不该报 ①：加了花括号 —— 这正是修法
        #expect(
            Self.unbracedVarBeforeMultibyte(in: #"echo "✘ ${name}：期望退出码""#).isEmpty,
            "`${name}` 被误报 —— 会把正确的写法判成错")
        // 不该报 ②：半角标点没问题
        #expect(
            Self.unbracedVarBeforeMultibyte(in: #"echo "✘ $name: done""#).isEmpty,
            "半角标点被误报 —— 判据太松")
        // 不该报 ③：`$1` 这类位置参数（首字符不是字母/下划线）
        #expect(
            Self.unbracedVarBeforeMultibyte(in: #"echo "$1，不是变量""#).isEmpty,
            "位置参数 `$1` 被误报")
    }

    /// bash 3.2 那条**反引号**陷阱：活文件里不许在双引号字符串里写反引号。
    ///
    /// 与「变量紧跟多字节」同一类病（静默、且 `bash -n` 查不出），但症状不同，
    /// 所以是**独立一轴**：那条守「变量名被延长」，这条守「字符串里跑了条命令」。
    @Test func 活文件里双引号内不得有反引号() async throws {
        let listed = await Self.liveToolingFiles()
        let all = try #require(
            listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「没有这个坑」）")
        let live = all.filter { Self.isBashScript($0) }
        // 正向锚：bash 脚本数不能塌 —— 否则下面那句「没有」只是「没扫到」（假绿）
        #expect(live.count >= 8, "只枚举到 \(live.count) 个 bash 脚本 —— 范围口径失效了（假绿）")

        var claims: [String] = []
        for rel in live {
            claims += Self.backtickInsideDoubleQuotes(in: try read(rel)).map { "\(rel) \($0)" }
        }

        #expect(
            claims.isEmpty,
            """
            这些**活文件**的双引号里写了反引号（\(claims.count) 处）：
            \(claims.joined(separator: "\n"))
            bash 会把它当**命令替换**执行 ⇒ 那一块输出变成那条命令的输出（通常是空），
            而 `bash -n` 完全查不出来（语法合法）。2026-09-28 实发当天踩到两次。
            改法：① 真要执行就写 `$(…)`；② 只是想在文案里写一个反引号 ⇒ 挪进单引号，
            或改成转义形式。
            """)
    }

    /// 第三轴的双向对照。
    @Test func grep方言判据的双向对照() {
        // 该报 ①：BRE 里写 `\|`（本仓库踩过 8 次的那一条）
        #expect(
            !Self.grepDialectTraps(in: #"grep -q 'A\|B' file"#).isEmpty,
            "BRE 交替没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ②：ERE 里写 `(?:`（2026-09-20 踩过一次）
        #expect(
            !Self.grepDialectTraps(in: #"grep -cE '(?:A|B)' file"#).isEmpty,
            "ERE 非捕获组没被报出来 —— 判据在这一轴上是瞎的")

        // 不该报 ①：`grep -E` 里的**未转义** `|` 是对的
        #expect(
            Self.grepDialectTraps(in: #"grep -E 'A|B' file"#).isEmpty,
            "`grep -E 'A|B'` 被误报 —— 那是**正确**写法，误报会逼人关掉守卫")
        // 不该报 ②：仓库里那条**警示注释**自己含 `\|`，不能算违规
        #expect(
            Self.grepDialectTraps(in: "# ⚠️ BSD grep 的 BRE 不支持 `\\|` 交替 —— 一律用 `grep -E`。")
                .isEmpty,
            "注释里的警示被当成违规 —— 会逼人**删掉那条警示**，比没守卫更糟")
        // 不该报 ③：`-e A -e B` 也是对的
        #expect(
            Self.grepDialectTraps(in: #"grep -q -e A -e B file"#).isEmpty,
            "`-e A -e B` 被误报")
    }

    /// 第四轴的双向对照。
    @Test func 反引号判据的双向对照() {
        // 该报 ①：双引号里写反引号（2026-09-28 实发踩的那一行）
        #expect(
            !Self.backtickInsideDoubleQuotes(in: #"say "…从 `git describe` 派生…""#).isEmpty,
            "双引号里的反引号没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ②：行内注释之后还有双引号 + 反引号（**整行**注释才跳过，不是「含 # 就跳过」）
        #expect(
            !Self.backtickInsideDoubleQuotes(in: #"echo "$x" # 注意 `date` 这里"#).isEmpty,
            "行内注释里的反引号没被报出来 —— 那条反引号会被真的执行")

        // 不该报 ①：单引号里是安全的（bash 不做展开）
        #expect(
            Self.backtickInsideDoubleQuotes(in: #"printf '%s\n' 'say "从 `git describe` 派生"'"#)
                .isEmpty,
            "单引号里的反引号被误报 —— 那是安全写法，误报会逼人关掉守卫")
        // 不该报 ②：转义过的反引号是字面量
        #expect(
            Self.backtickInsideDoubleQuotes(in: #"echo "用 \` 包起来""#).isEmpty,
            "转义的反引号被误报")
        // 不该报 ③：整行注释（仓库里正有一条注释在讲这个坑，不能逼人删掉它）
        #expect(
            Self.backtickInsideDoubleQuotes(in: "# ⚠️ 别写 `\"…`git describe`…\"` 这种写法")
                .isEmpty,
            "警示注释被当成违规 —— 会逼人删掉那条警示，比没守卫更糟")
        // 不该报 ④：只含反引号但没有双引号（不在双引号字符串里就不会被这条规则命中）
        #expect(
            Self.backtickInsideDoubleQuotes(in: "echo `date`").isEmpty,
            "裸反引号（无双引号）被误报")
    }

    /// ⚠️ **范围本身是判据**（§8.75 / §8.105 / §8.106）。
    ///
    /// 上面那条守卫的结论是「活文件里没有写死门槛数量」——
    /// 而「**活文件**」这个词是**我定义**的。定义窄了，它就变成一句空话，
    /// 且输出与「真的没有」逐字相同。所以这里把定义本身也钉住：
    ///
    /// 1. 交叉自证：`git ls-files '*.sh' '*.yml' '*.yaml'` 的结果必须**全在**枚举结果里
    ///    （若 shebang 判定坏了、或只认 `.yml`，这里当场报出来）；
    /// 2. **无扩展名的脚本必须在范围里** —— 它正是「不能用扩展名当判据」的理由。
    /// 3. **未入库（untracked）的活文件也必须在范围里** —— 2026-09-21 实测：
    ///    原先只枚举 `--cached`，新脚本在 `git add` **之前**不在范围里，
    ///    于是同一条违规**本地全绿、推上去才红**（`stamp_lines_smoke.sh` 就是这么红的）。
    ///    ⚠️ 这一条的对照物是**另一条 git 命令**（`status --porcelain`）：
    ///    拿 `ls-files` 跟 `ls-files` 对拍等于**共享同一个盲点**，对这件事一个字都说不出来。
    ///    ⚠️ 它在 CI 上是**空转**的（那时新文件都已入库）—— 它守的正是「推之前」那一刻。
    @Test func 扫描范围必须覆盖全部活工具文件() async throws {
        let listed = await Self.liveToolingFiles()
        let live = try #require(listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「范围没问题」）")
        #expect(live.count >= 12, "只枚举到 \(live.count) 个活文件 —— 范围口径失效了（假绿）")

        let byGlob = try #require(
            await Self.gitLsFiles(["*.sh", "*.yml", "*.yaml"]),
            "拿不到 `git ls-files '*.sh' '*.yml' '*.yaml'` 的输出 —— 交叉自证没跑起来")
        #expect(byGlob.count >= 8, "按扩展名只列出 \(byGlob.count) 个文件 —— 交叉自证自己失效了（假绿）")

        let missed = byGlob.filter { !live.contains($0) }
        #expect(
            missed.isEmpty,
            """
            这些文件**按扩展名该进范围**却没进：\(missed.joined(separator: "、"))
            范围窄了 ⇒ 上面那条守卫的「没写死」只是「没扫到」。
            """)

        #expect(
            live.contains("Scripts/test/fake-gh/gh"),
            """
            无扩展名的 `Scripts/test/fake-gh/gh` 没进范围 ——
            枚举退化成「只看扩展名」了。它是**可执行脚本**（首行 `#!`），
            正是「不能拿扩展名当判据」的理由。
            """)

        // ---- ③ 未入库文件：换一条 git 命令交叉自证 ----
        let untracked = try #require(
            await Self.gitUntrackedFiles(),
            "拿不到 `git status --porcelain` 的输出 —— 交叉自证没跑起来（**不等于**「范围没问题」）")
        let untrackedLive = untracked.filter { Self.isLiveToolingFile($0) }
        let missedUntracked = untrackedLive.filter { !live.contains($0) }
        // ⚠️ 把读数打出来：一个未入库活文件都没有时，下面那条断言是**空转**的
        //    （报绿 ≠ 扫过了）—— 不打印的话，「空转」与「查过了没问题」逐字相同。
        print("   [范围自证] 未入库文件 \(untracked.count) 个，其中活文件 \(untrackedLive.count) 个")
        #expect(
            missedUntracked.isEmpty,
            """
            这些**未入库**的活文件没进范围：\(missedUntracked.joined(separator: "、"))
            ⇒ 新写的脚本在 `git add` 之前不被扫 ⇒ **本地全绿、推上去才红**
            （2026-09-21 实测：`Scripts/test/stamp_lines_smoke.sh`）。
            改法：`gitLsFiles` 的枚举带 `--others --exclude-standard`。
            """)
    }
}
