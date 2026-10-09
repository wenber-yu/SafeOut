import Foundation
import Testing

@testable import SafeOutApp

/// **「最低系统版本」只能有一处真相，而且每一处声明都必须与它一致。**
///
/// ## 为什么值得守（2026-09-24 实测）
///
/// 「最低系统版本」在这个仓库里被**声明了 7 次**：`Package.swift` 的 `platforms`、
/// `Tools/gen_l10n_tool/Package.swift`、`README.md` 的 hero 行、`SPEC.md` 的两张表、
/// 设计稿抬头（`DESIGN-SPEC.md` / `index.html`），以及 `build_app.sh` 写进 Info.plist 的
/// `LSMinimumSystemVersion`。
///
/// 它们是**同一件事的七次抄写**，而此前**没有任何东西会让它们一致** —— 本轮就抓到一处：
/// 代码与文档都已经在说 14，`build_app.sh` 里还硬编码着 `13.0`。
/// 那个错**不会**在构建、测试、格式检查里露头（打包一路绿灯），
/// 症状只出现在用户机器上：包在 macOS 13 上**启动、然后崩** —— Gatekeeper 只看
/// `LSMinimumSystemVersion`，它写着 13.0 ⇒ 系统放行，然后 dyld 找不到只有 14 才有的符号。
/// 这正是本仓库反复踩的形状：**「写了」不等于「生效了」，而「不一致」没有任何东西会红**。
///
/// ## 口径
///
/// 1. **真相**只有一处：`Package.swift` 的 `platforms: [.macOS(.vNN)]`（编译器读的也是它）。
/// 2. 其余声明处**逐个锚定**：锚点失配（措辞被改写）**也判红** ——
///    否则守卫会**静默失效**，而「静默失效」与「文档干净」在输出上**逐字相同**（§8.96.4）。
/// 3. 全仓负向扫：部署目标形状的版本号必须都等于真相；范围与豁免见 ``scanExcludes``。
///
/// ## 判据为什么长这样
///
/// 同一个仓库里还有一批「macOS NN」讲的是 **API 可用性事实**，不是部署目标 ——
/// `#available(macOS 13.3, *)`、`macOS 13 起已废弃`、`macOS 13.0 起提供`、
/// `在 macOS 14 上偏厚`。判据只认三种**部署目标形状**（见 ``mentionedMajor(in:)``）⇒
/// 它们天然不匹配。为了让这条边界成立，本轮把两处「（macOS 13+）」改写成了
/// 「（macOS 13.0 起提供）」—— 即**把那个形状留给部署目标**，免得守卫被迫维护一张
/// 越来越长的白名单。
///
/// ⚠️ **已知局限（故意不修）**：`mentionedMajor` 一行只取**第一个**匹配。
/// 一行里同时写两个版本号的写法目前 0 例；真出现时靠 ``文档里的最低系统版本必须与Package_swift一致``
/// 的锚点那一侧兜。
///
/// ⚠️ **变异脚本（手动跑，不进门槛）**：`Scripts/test/deployment_target_mutation.py`
/// —— 9 条变异证明下面这几条守卫各自有牙（含 1 条阴性对照），见该脚本抬头。
@Suite struct DeploymentTargetTests {

    // MARK: - 期望值

    /// 期望的最低系统版本（**major**）。改这个数 = 「升级部署目标」，
    /// 此时下面每条断言都会把还没跟着改的地方**逐处**点出来。
    ///
    /// ⚠️ 它是**第二处**声明（真相在 `Package.swift` 的 `platforms`）—— 这正是本测试的用法：
    /// 拿一个写死的期望值去比真相，**不一致就红**。若改成「从 `Package.swift` 读出来
    /// 再和自己比」，这条守卫立刻退化成同义反复（**没牙**）。
    private static let expectedMajor = 14

    // MARK: - 路径

    /// #filePath = <仓库根>/Tests/SafeOutAppTests/DeploymentTargetTests.swift
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SafeOutAppTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // 仓库根
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - 判据（纯函数 —— 样本可以直接喂给它，不必改仓库里的文件）

    /// 从 `Package.swift` 的文本里取 `platforms: [.macOS(.vNN)]` 的 `NN`；取不到返回 `nil`。
    ///
    /// ⚠️ 取不到返回 `nil` 而**不给默认值**：「没有 `platforms` 行」与「平台是某个值」
    /// 是两件事，给默认值会让守卫在 `Package.swift` 被改写后**静默放过**。
    static func major(inPackageSwift text: String) -> Int? {
        firstGroup(#"platforms:\s*\[\s*\.macOS\(\.v(\d+)\)"#, in: text).flatMap(Int.init)
    }

    /// 一段文本里出现的**部署目标形状**的版本号；0 个匹配返回 `nil`。
    ///
    /// 三种形状，都是「最低系统版本」的写法：
    /// - `macOS 14+` / `macOS 14.0+`（文档里的口语写法）
    /// - `.macOS(.v14)`（`Package.swift` 的 `platforms`）
    /// - `部署目标 macOS 14`（注释里的口语写法）
    ///
    /// ⚠️ **故意不匹配**这些：`macOS 13.3, *`（`#available` 的元组）、`macOS 13 起已废弃`、
    /// `macOS 13.0 起提供`、`在 macOS 14 上偏厚` —— 它们讲的是 API 可用性事实，
    /// 与最低系统版本无关。判据宽一格就会把它们整片扫成违规（然后守卫会被关掉）。
    static func mentionedMajor(in line: String) -> Int? {
        let patterns = [
            #"\.macOS\(\.v(\d+)\)"#,
            #"macOS\s+(\d+)(?:\.\d+)?\+"#,
            #"部署目标\s+macOS\s+(\d+)"#,
        ]
        for pattern in patterns {
            if let major = firstGroup(pattern, in: line).flatMap(Int.init) { return major }
        }
        return nil
    }

    /// 第一个捕获组；没匹配到（或没有捕获组）返回 `nil`。
    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
            let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    // MARK: - 装置（`git grep`）

    struct Hit {
        var file: String
        var line: Int
        var text: String
    }

    /// 负向扫**排除**的范围 —— 两条，都有依据（**排除也是判据**，§8.75）。
    ///
    /// 1. `Design/` —— 设计交付物（mockup + 设计规格 + 历史账本）。里面大量是
    ///    **引用旧文案**或**记录历史**的写法，实测 3 处：v1 mockup
    ///    `pages/settings-panel.html` 的旧副标题（写着「需 macOS 15+」，而 v2 已把它改成
    ///    「透明模式使用系统毛玻璃；色调模式使用固定的浅色背景。」）、
    ///    `v2/DESIGN-SPEC.md` 的对比表与历史条目。**设计侧的部署目标声明只有一处** ——
    ///    `v2/DESIGN-SPEC.md` 的抬头，由 ``文档里的最低系统版本必须与Package_swift一致`` 钉住。
    /// 2. **本文件自己** —— 判据的模式串、白名单样本、以及上面那些反例（`macOS 13+` 之类）
    ///    就写在这里，自扫必然自伤。与 `PixelReadPathTests` 跳过本文件同款处理。
    /// 3. `Scripts/test/deployment_target_mutation.py` —— **同理**，而且它是**必须**写的：
    ///    变异脚本的职责就是逐字持有「要变异的旧串」（`platforms: [.macOS(.v13)],`、
    ///    `macOS 13+ · SwiftUI` …）。那不是「在声明最低系统版本」。
    ///    ⚠️ 这条不是想当然加的：**2026-09-24 实测**——刚把这个脚本建出来，本守卫当场判红
    ///    （它把脚本里的 `V13` 常量当成了真声明）。守卫没瞎的又一证据。
    private static let scanExcludes = [
        "Design/",
        "Tests/SafeOutAppTests/DeploymentTargetTests.swift",
        "Scripts/test/deployment_target_mutation.py",
    ]

    /// 允许保留的**部署目标形状**写法 —— 只收「**元陈述**」（讲这条规矩本身的句子）。
    ///
    /// ⚠️ 任何一处**真的**在声明最低系统版本的地方都必须改成与 `Package.swift` 一致，
    /// **不许进白名单**。白名单条目**自证**：`contains` 不再出现在 `file` 里 ⇒ 判红
    /// （否则它会腐化成「一份没人敢删的豁免」）。
    private static let allowedMentions: [(file: String, contains: String, why: String)] = [
        (
            "SPEC.md", "别写「macOS 15+ / 26+」",
            "这一句是**禁令本身**（元陈述：不许拿那个形状描述 Liquid Glass）—— "
                + "它引用的正是要禁的写法，不是在声明最低系统版本"
        )
    ]

    /// 跑一次 `git grep`，返回 `路径 / 行号 / 行内容`。
    ///
    /// ⚠️ 用 `git` 而不是自己遍历文件系统：`git` 才是 `.gitignore` 的解释者，
    /// 手写「跳过哪些目录」等于又添一份会漂的清单（§8.105 的教训）。
    ///
    /// ⚠️ **`--untracked` 不可省**：少了它，**刚建、还没 `git add`** 的新文件不在范围里
    /// ⇒ 它里面的旧写法在**本地全绿**、**推上去才红**（§8.105 实测踩过，
    /// 而且咬的是守卫自己）。`--untracked` 仍尊重 `.gitignore`（未忽略的才进）。
    ///
    /// ⚠️ `-I` 跳过二进制文件；`nil` = **装置没跑起来**（启动失败 / 超时），
    /// 与「0 条命中」是两件事 —— 后者是空字符串，不是 `nil`。
    ///
    /// `excludes` 传 `nil` 用默认的 ``scanExcludes``；传 `[]` = 不排除任何东西
    /// （供 ``判据与装置的双向对照`` 用数量差证明「排除真的生效」）。
    static func gitGrep(_ pattern: String, excludes: [String]? = nil) async -> [Hit]? {
        var args = [
            "-C", repoRoot.path, "-c", "core.quotePath=false",
            "grep", "-n", "-I", "-E", "--untracked", pattern, "--", ".",
        ]
        args += (excludes ?? scanExcludes).map { ":!\($0)" }

        let output = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: args,
                timeout: 30
            ) { c.resume(returning: $0) }
            run.start()
        }
        guard let output else { return nil }

        // ⚠️ 解析要**容错**：`git grep` 的输出是 `路径:行号:内容`，而**内容里也会有冒号**
        //    （本仓库到处都是 `foo: bar`）⇒ 只能按**前两个**冒号切，剩下整段都是内容。
        return output.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let line = Int(parts[1]) else { return nil }
            return Hit(file: String(parts[0]), line: line, text: String(parts[2]))
        }
    }

    // MARK: - 守卫

    /// **真相**：主包的 `platforms` 必须是期望值；本地化工具包必须同档。
    @Test func 部署目标的唯一真相是Package_swift() throws {
        let main = try read("Package.swift")
        let major = try #require(
            Self.major(inPackageSwift: main),
            "在 Package.swift 里找不到 `platforms: [.macOS(.vNN)]` —— 唯一真相没了，下面的断言全部无意义")

        #expect(
            major == Self.expectedMajor,
            """
            部署目标是 macOS \(major)，期望 \(Self.expectedMajor)。
            改这个数不只是改这一行：README.md / SPEC.md / 设计稿抬头 / build_app.sh 的
            Info.plist 都跟着它走 —— 本测试会把还没跟上的地方逐处点出来。
            """)

        let tool = try read("Tools/gen_l10n_tool/Package.swift")
        #expect(
            Self.major(inPackageSwift: tool) == Self.expectedMajor,
            "本地化生成器工具包的 platforms 与主包不同档（口径：全仓部署目标统一）")
    }

    /// 文档里的「最低系统版本」必须与真相一致 —— **逐处锚定**，锚点失配也判红。
    @Test func 文档里的最低系统版本必须与Package_swift一致() throws {
        // ⚠️ 比对基准取 `Package.swift` 里的**实际值**，不取 ``expectedMajor`` ——
        //    这样「真升级到 15、文档没跟上」时，本测试报的是**哪几份文档要改**；
        //    若拿 `expectedMajor` 当基准，那时只有 ``部署目标的唯一真相是Package_swift``
        //    会红，信息指向「Package.swift 不是 14」，还得自己想半天才意识到文档也要动。
        let truth = try #require(
            Self.major(inPackageSwift: try read("Package.swift")),
            "读不到 Package.swift 的 platforms —— 比对基准没了，本测试无意义")

        // (文件, 锚点正则（捕获组 = 版本号）, 这一处是什么)
        let declarations: [(file: String, pattern: String, what: String)] = [
            ("README.md", #"(?m)^macOS (\d+)\+ "#, "hero 行的版本串"),
            ("SPEC.md", #"(?m)^\| 最低系统版本 \| \*\*macOS (\d+)\.\d+\+\*\*"#, "「最低系统版本」表格行"),
            ("SPEC.md", #"(?m)^\| UI \| SwiftUI（支持 macOS (\d+)\+）"#, "「技术栈 · UI」表格行"),
            ("Design/ui/v2/DESIGN-SPEC.md", #"(?m)^> 应用中文名：磁盘推出助手 · macOS (\d+)\+ "#, "设计稿抬头"),
            ("Design/ui/v2/index.html", #"macOS (\d+)\+ · SwiftUI"#, "设计稿 index 的 hero 元信息"),
        ]

        var problems: [String] = []
        for d in declarations {
            let text = try read(d.file)
            guard let got = Self.firstGroup(d.pattern, in: text).flatMap(Int.init) else {
                problems.append(
                    "\(d.file)（\(d.what)）：锚点没匹配上 —— 措辞被改写了，守卫在这一处**静默失效**")
                continue
            }
            if got != truth {
                problems.append("\(d.file)（\(d.what)）：写的是 macOS \(got)+，Package.swift 是 \(truth)")
            }
        }

        #expect(
            problems.isEmpty,
            """
            \(problems.count) 处最低系统版本与 Package.swift 不一致：
            \(problems.joined(separator: "\n"))
            它们是**同一件事的多次抄写**，而「不一致」不会让任何别的检查变红。
            """)
    }

    /// `build_app.sh` 写进 Info.plist 的 `LSMinimumSystemVersion` **必须是派生的**。
    ///
    /// 本轮实测抓到的那处就是这么来的：代码与文档都已经在说 14，而这里硬编码着 `13.0`
    /// —— 打包一路绿灯，谁都不会发现，直到用户在 13 上双击。
    ///
    /// ⚠️ 这两条是**文本**断言（守得住「那行还在」，守不住「改坏了但还在」）⇒
    /// 「派生**这条路**真的通」由 `Scripts/test/build_app_version_smoke.sh` 的
    /// `ⓘ 部署目标：` 那一行**行为**兜（跑 `build_app.sh`、读它的输出）。
    @Test func 打包脚本的最低系统版本必须是派生的() throws {
        let script = try read("build_app.sh")

        let derived = #"(?s)<key>LSMinimumSystemVersion</key>\s*<string>\$\{?[A-Za-z_][A-Za-z0-9_]*\}?</string>"#
        #expect(
            script.range(of: derived, options: .regularExpression) != nil,
            """
            build_app.sh 的 LSMinimumSystemVersion 不是变量插值。
            写死一个数字就一定会与 Package.swift 漂 —— 本轮实测就是这么漂的。
            """)

        let hardcoded = #"(?s)<key>LSMinimumSystemVersion</key>\s*<string>\s*[0-9]"#
        #expect(
            script.range(of: hardcoded, options: .regularExpression) == nil,
            "build_app.sh 把最低系统版本写死成了字面量数字 —— 它必须从 Package.swift 派生")

        #expect(
            script.contains("$PACKAGE_DIR/Package.swift"),
            "build_app.sh 里找不到从 $PACKAGE_DIR/Package.swift 读部署目标的那一步")
    }

    /// 全仓负向扫：**部署目标形状**的版本号必须都等于真相。
    ///
    /// 这一条抓的是「又冒出一处**第三值**」—— 既不是真相、也不在豁免表里的写法。
    /// 它本轮实测抓到过两处（一处是真的漂：v1 mockup 的旧副标题；一处是元陈述：
    /// `SPEC.md` 里那句禁令本身），两处都按上面的 `scanExcludes` / `allowedMentions` 处置。
    @Test func 全仓不得再出现与真相不同的部署目标写法() async throws {
        let pattern = #"\.macOS\(\.v[0-9]+\)|macOS [0-9]+(\.[0-9]+)?\+|部署目标 macOS [0-9]+"#
        let hits = try #require(
            await Self.gitGrep(pattern),
            "拿不到 git grep 的输出 —— 装置没跑起来（**不等于**「全仓干净」）")

        // 正向锚：装置必须**数得到东西**。少了它，「0 条命中」与「装置瞎了」逐字相同。
        #expect(hits.count >= 5, "只扫到 \(hits.count) 条 —— 扫描口径失效了（假绿）")

        var bad: [String] = []
        var used = [Bool](repeating: false, count: Self.allowedMentions.count)
        for hit in hits {
            if let i = Self.allowedMentions.firstIndex(where: {
                $0.file == hit.file && hit.text.contains($0.contains)
            }) {
                used[i] = true
                continue
            }
            if Self.mentionedMajor(in: hit.text) != Self.expectedMajor {
                bad.append("\(hit.file):\(hit.line)：\(hit.text.trimmingCharacters(in: .whitespaces))")
            }
        }

        // 白名单**自证**：登记了却不再出现 ⇒ 判红（否则它腐化成一份没人敢删的豁免）。
        let rotten = zip(Self.allowedMentions, used).filter { !$0.1 }.map { $0.0.file }
        #expect(
            rotten.isEmpty,
            """
            白名单里有 \(rotten.count) 条已经**不再出现**：\(rotten.joined(separator: "、"))
            要么那条已经改好（删掉它），要么它已经漂到别处（重新定位）
            """)

        #expect(
            bad.isEmpty,
            """
            全仓有 \(bad.count) 处部署目标形状的版本号与真相（macOS \(Self.expectedMajor)）不符：
            \(bad.joined(separator: "\n"))
            若是**真的**在声明最低系统版本 ⇒ 改成与 Package.swift 一致；
            若是**引用旧文案 / 记录历史 / 讲这条规矩本身** ⇒ 加进 allowedMentions 并写明理由。
            """)
    }

    /// ⚠️ **判据与装置都要自己验**：拿「该报的」与「不该报的」各试一次。
    /// 少了这一步，「全绿」与「判据瞎了」是分不开的（本仓库 §8.96.4 的原话）。
    @Test func 判据与装置的双向对照() async throws {
        // ① 判据 · 该报：三种部署目标形状，值都不是期望值
        let legacy = [
            "macOS 13+ · SwiftUI",
            "| 最低系统版本 | **macOS 13.0+**（Ventura 及以上） |",
            "    platforms: [.macOS(.v13)],",
            "/// 证明不了「部署目标 macOS 13 上也有」",
        ]
        for sample in legacy {
            #expect(
                Self.mentionedMajor(in: sample) == 13,
                "样本「\(sample)」没被抽出版本号 13 —— 判据在这一轴上是瞎的")
        }

        // ② 判据 · 不该报：这些讲的是 **API 可用性事实**，不是部署目标
        let apiFacts = [
            "        if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }",
            "不使用 `LSSharedFileList`（macOS 13 起已废弃、不再可靠生效）",
            "使用 `SMAppService.mainApp`（macOS 13.0 起提供）",
            "/// `.ultraThinMaterial` 在 macOS 14 上偏厚",
        ]
        for sample in apiFacts {
            #expect(
                Self.mentionedMajor(in: sample) == nil,
                "样本「\(sample)」被误判成部署目标声明 —— 判据过宽（会变成假红，然后被关掉）")
        }

        // ③ 判据 · `Package.swift` 那一支：取不到要返回 nil（不给默认值）
        #expect(Self.major(inPackageSwift: "    platforms: [.macOS(.v14)],") == 14)
        #expect(
            Self.major(inPackageSwift: "// 没有 platforms 行") == nil,
            "没有 platforms 行时返回了默认值 —— 「没写」与「写了某个值」分不开了")

        // ④ 装置 · 阳性：真跑一次 git grep，必须数得到东西
        let pattern = #"\.macOS\(\.v[0-9]+\)|macOS [0-9]+(\.[0-9]+)?\+|部署目标 macOS [0-9]+"#
        let hits = try #require(await Self.gitGrep(pattern), "装置没跑起来（启动失败 / 超时）")
        #expect(hits.count >= 5, "装置只数到 \(hits.count) 条 —— 与「全仓干净」分不开（假绿）")
        #expect(
            hits.allSatisfy { !$0.file.isEmpty && $0.line > 0 },
            "解析出的命中里有空路径 / 非正行号 —— `路径:行号:内容` 的切法坏了")

        // ⑤ 装置 · 阴性：瞎编的模式必须 0 条，且**返回的是空数组而不是 nil**
        //    （「没命中」与「装置没跑起来」是两件事 —— 后者会让守卫静默变成假绿）
        let none = try #require(await Self.gitGrep("ZZZ_DEPLOY_TARGET_NO_SUCH_STRING_ZZZ"))
        #expect(none.isEmpty, "瞎编的模式居然命中了 \(none.count) 条 —— 装置的口径不对")

        // ⑥ 装置 · **排除真的生效**：把排除清空，命中数必须**变多**。
        //    「排除写了但没生效」与「没排除」在输出上**逐字相同** ⇒ 只能用数量差证明它生效。
        let unscoped = try #require(await Self.gitGrep(pattern, excludes: []))
        #expect(
            unscoped.count > hits.count,
            "清空排除后命中数没变（\(hits.count) → \(unscoped.count)）—— 排除根本没生效")
    }
}
