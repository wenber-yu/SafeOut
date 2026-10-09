import Foundation
import Testing

/// **本地门槛 = CI 门槛** —— 这条约定此前只在**文字里**承诺，没有任何机器检查。
///
/// 现在有四处写着它：
/// 1. `SPEC.md` §6.4：「本地门槛 `./run.sh check`，或直接 `./Scripts/preflight.sh`；
///    **与 CI 调用同一文件**，判据不会分叉」
/// 2. `.github/workflows/ci.yml` line 57 调用 `./Scripts/preflight.sh --with-tests`
/// 3. `ci.yml` line 52–55 的注释：本地跑的是同一个文件，「否则 13 条并发错误会潜伏三天」
/// 4. `run.sh` 的 `check` 分支：`exec "$SCRIPT_DIR/Scripts/preflight.sh" "$@"`
///    （⚠️ **不写行号** —— 2026-09-20 给 `run.sh` 加了 `ci` 子命令，行号当场就漂了）
///
/// ⚠️ 但**四处都是人写的字** —— 谁改了其中一处，其余三处不会有任何报错，
/// 而后果正是注释里写的那个：本地一路绿灯、CI 判据其实更严（或更松），
/// 「本地绿」与「CI 绿」从此**不是同一件事**，且**界面上/日志上都看不出来**。
///
/// §8.51 立过：**「A 与 B 必须一致」的约定要配守卫，不能靠两边各写一句「记得同步」。**
/// 这一条就是那句话的落地 —— 把四处**互相钉住**，而不是再写第五句「记得同步」。
///
/// ## ⚠️ 本文件第一版是**纸老虎**（变异 6 条只红 1 条，§8.60 记了全过程）
///
/// 三条断言写完**全绿**，看着很好；变异才暴露出 3 条里 2 条没牙：
///
/// | 变异 | 第一版 | 病根 |
/// |---|---|---|
/// | CI 改调别的命令 | 🟢 绿 | **进程崩溃**（`range(at: 1)` 越界）被判红口径当成「绿」 |
/// | 删掉 `--with-tests` 分支 | 🟢 绿 | `contains("--with-tests")` —— 脚本的**用法注释里**也有这个串 |
/// | 文档改脚本名 | 🟢 绿 | `contains` —— 文档里有**第二处**写法不同的引用 |
///
/// ⇒ 三条改法：**① 解析改成全量集合，不取「第一个匹配」；② 参数分支查结构且剥注释；
/// ③ 文档侧查「引用集合必须唯一」，不是「至少有一处对」。**
/// 更根本的：**「断言全绿」不是证据，变异红才是。**
///
/// ### ⚠️ 收得过头也是假红：「唯一」是相对于**角色**，不是相对于整个文件
///
/// 第二版把「SPEC.md 里所有 `Scripts/*.sh` 引用必须唯一」当断言 ⇒ 立刻红，
/// 报出 `build_icon.sh` / `coverage.sh` / `make_appcast.sh` —— 它们是**别的脚本**，
/// 从来没自称过「门槛」。⇒ 收集范围必须是「**自称门槛的那些行**」，不是「全文」。
/// 与 §8.59 那条正好互补：那边是「来源比想的多」（假绿），这边是「范围比该管的宽」（假红）。
///
/// ## 第二族：CI 声明的环境变量 ↔ 脚本真的读它（§8.61）
///
/// `ci.yml` 顶层 `env` 是**声明**，脚本里的 `${VAR:-默认}` 是**消费**。
/// 两边断开时**谁都不报错** —— 只是 CI 失败时日志被截成 30 行，断言消息看不全
/// （本仓库踩过：19 个 issue 只露出 12 个，只能反复推 CI 靠猜）。
///
/// ⚠️ 这一族的关键是**扫描不够**：扫描只能发现「声明了没人读」，
/// 发现不了「**该声明的没声明**」（把 `env` 那行删掉，扫描器眼里世界依然一致）。
/// ⇒ 必须配一张**显式契约表**，两个方向各守一次。
struct GateParityTests {

    // MARK: 路径

    /// #filePath = <仓库根>/Tests/SafeOutAppTests/GateParityTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: 守卫

    /// `run.sh check` 转调的脚本，必须出现在 **CI 实际调用的脚本集合**里。
    ///
    /// ⚠️ 这里用**集合包含**而不是「两边各取第一个相匹配」——
    /// 第一版就是取「第一个匹配」：CI 里那处调用被改掉后，扫描器静默滑到
    /// 后面另一个 `.sh`（打包验证的 `build_app.sh`）上，比较仍然「有意义」但**比错了对象**。
    @Test func 本地门槛与CI门槛必须调用同一个脚本() throws {
        let scan = try load()

        // 负向锚：两边都得真读到脚本名（读不到 = 解析口径失效，不是「一致」）
        #expect(!scan.ciScripts.isEmpty, "ci.yml 的非注释行里找不到任何 `./xxx.sh` 调用 —— 解析口径失效（假绿）")
        #expect(scan.runScript != nil, "run.sh 里找不到 `exec $SCRIPT_DIR/xxx.sh` —— check 分支改写法了？")

        guard let run = scan.runScript else { return }
        #expect(
            scan.ciScripts.contains(run),
            """
            CI 实际调用的脚本 **\(scan.ciScripts.sorted())** 里，没有本地门槛用的 `\(run)`。
            本地跑的与 CI 跑的从此不是同一个文件 —— 判据可以分叉，
            而两边都不会报错（本仓库曾因此让 13 条并发错误在本地绿灯下潜伏三天）。
            要改就**两边一起改**，或者让其中一个继续转调到另一个。
            """)
    }

    /// ⚠️ `run.sh` 里 `exec "$SCRIPT_DIR/xxx.sh"` 有**两处**（`check` / `ci`），
    /// 而上一条守卫取的是**第一个**匹配 ⇒ `check` 必须排在 `ci` 之前。
    ///
    /// 为什么值得单立一条：这个顺序在 2026-09-20 之前**不是假设**（当时只有一处，
    /// 是加 `ci` 子命令才让它成为假设）。若有人把 `ci` 挪到前面，上一条守卫会静默
    /// 改去比对 `ci_status.sh` —— 它不在 CI 调用的脚本集合里，于是报出一条
    /// **看起来像真问题**的假红，排查方向被带偏。
    @Test func run_sh里check分支必须排在ci分支之前() throws {
        let body = Self.stripComments(try read("run.sh"))
        let checkAt = body.range(of: #"= "check""#)?.lowerBound
        let ciAt = body.range(of: #"= "ci""#)?.lowerBound
        // 负向锚：两个子命令都得真读到（读不到 = 解析口径失效，不是「顺序对」）
        #expect(checkAt != nil, "run.sh 里找不到 `= \"check\"` —— 子命令分发改写法了？")
        #expect(ciAt != nil, "run.sh 里找不到 `= \"ci\"` —— ci 子命令被删了？")
        guard let c = checkAt, let i = ciAt else { return }
        #expect(
            c < i,
            """
            `check` 分支必须排在 `ci` 分支之前：`本地门槛与CI门槛必须调用同一个脚本`
            取的是**第一个** `exec "$SCRIPT_DIR/xxx.sh"`。顺序反了它就会去比对
            `ci_status.sh`（不在 CI 调用的集合里）⇒ 报一条与真问题无关的假红。
            """)
    }

    /// CI **不许绕过门槛脚本**直接跑测试 / 格式 —— 那等于门槛被架空。
    ///
    /// ⚠️ 第一版这条**会崩**：`range(at: 1)` 取捕获组，而 `swift test` 这条正则
    /// 根本没有捕获组 ⇒ `NSInvalidArgumentException` ⇒ 进程 SIGABRT。
    /// 危害不在崩本身，而在**崩被判红口径当成「绿」**（见文件头表格第一行）。
    @Test func CI不许绕过门槛脚本直接跑测试或格式() throws {
        let scan = try load()
        #expect(
            scan.bypass.isEmpty,
            """
            ci.yml 直接跑了门槛命令，绕过了 `\(scan.runScript ?? "门槛脚本")`：
            \(scan.bypass.joined(separator: " / "))
            一旦 CI 与本地各跑各的，判据就会分叉 ——
            而「本地绿」与「CI 绿」从此**不是同一件事**，谁都不会报错。
            """)
    }

    /// 门槛脚本必须**真的**解析 `--with-tests` —— 否则「两边都调 preflight.sh」
    /// 也可能只是「两边都调了一个不跑测试的壳」。
    ///
    /// ⚠️ 第一版用 `contains("--with-tests")` ⇒ 脚本顶部的**用法注释**里也有这个串，
    /// 把参数分支整行删掉仍然绿（假阴性）。现在查的是**结构**：非注释行里的 case 分派。
    @Test func 门槛脚本必须真的解析withTests参数() throws {
        let scan = try load()
        guard let run = scan.runScript else { return }
        let script = try read(run)
        let body = Self.stripComments(script)
        let dispatched = body.contains("--with-tests)") && body.contains("WITH_TESTS=1")

        #expect(
            dispatched,
            """
            `\(run)` 的非注释正文里找不到 `--with-tests` 的参数分派。
            只查「文件里有这个串」不够 —— 它的用法注释里也写着这个串，
            **注释会假扮成实现**（与 §8.50.3「注释会蒙过『方法体里有这句调用』」同族）。
            """)
    }

    /// 文档（SPEC.md §6.4）承诺的门槛命令必须与实际**同一个文件**，且**只能有一个说法**。
    ///
    /// ⚠️ 第一版用 `contains` ⇒ 文档里有**第二处**写法不同的引用（`Scripts/preflight.sh`
    /// 不带 `./`），改掉第一处仍绿。现在查「引用集合**必须唯一**且等于实际脚本」。
    ///
    /// ⚠️ 收集范围只限**自称门槛的行**：全文扫会捞到 `build_icon.sh` / `coverage.sh` 等
    /// 别的脚本（它们没自称门槛），那是假红 —— 见文件头「唯一是相对于角色」。
    @Test func 文档承诺的门槛命令必须与实际一致() throws {
        let scan = try load()
        guard let run = scan.runScript else { return }
        let spec = try read("SPEC.md")

        // 「自称门槛」的行：§6.4 表格里的「本地门槛」行，以及 CI 那行的「代码门槛」。
        var refs = Set<String>()
        var claimLines: [String] = []
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard Self.gateClaimKeywords.contains(where: { s.contains($0) }) else { continue }
            claimLines.append(s)
            for m in Self.allMatches(in: s, pattern: #"[A-Za-z0-9_./-]*Scripts/[A-Za-z0-9_]+\.sh"#) {
                refs.insert(Self.normalize(m))
            }
        }

        // 负向锚：找不到承诺行 / 承诺行里没有脚本引用 = 口径失效，不是「没有不一致」
        #expect(
            !claimLines.isEmpty,
            "SPEC.md 里找不到自称「门槛」的行 —— §6.4 那句承诺被删了，或关键词失效（假绿）")
        #expect(
            !refs.isEmpty,
            "自称门槛的那些行里没有 `Scripts/xxx.sh` 引用 —— 只写「与 CI 同一文件」却不写是哪个文件（假绿）")

        #expect(
            refs == [run],
            """
            文档自称门槛的地方写的是 \(refs.sorted())，实际门槛脚本是 \(Set([run]))。
            §6.4 写着「与 CI 调用同一文件，判据不会分叉」—— 对不上的那个说法会让读者
            按文档跑一遍，跑的却不是 CI 那个判据。改了脚本位置就把文档**所有**说法一起改。
            """)
    }

    /// 「自称门槛」的标志词。目录树那行（`preflight.sh # CI 严格门槛预检…`）不含这些词，
    /// 因此不进收集范围 —— 它没在**承诺**什么，只是列目录。
    private static let gateClaimKeywords = ["本地门槛", "代码门槛", "同一文件"]

    // MARK: 第二族：环境变量契约（§8.61）

    /// CI ↔ 门槛脚本的**显式契约表**：变量 → CI 必须设的值。
    ///
    /// ⚠️ 这张表**不能靠扫描替代**：扫描只看得见「现在写着什么」，
    /// 看不见「**该写的没写**」—— 把 `PREFLIGHT_FAIL_TAIL` 那行删掉，
    /// 「ci.yml 声明的变量都被读了」依然成立（没声明就不查），守卫全绿而契约已死。
    private static let envContracts: [String: String] = ["PREFLIGHT_FAIL_TAIL": "0"]

    /// runner 级变量：设给 **runner 进程本身**，不由脚本读（`LC_ALL` 修的是 runner 的 locale）。
    /// 判它「没人读」是假红 —— 它的消费者是 CI  runner，不在本仓库里。
    private static let runnerLevelEnv: Set<String> = ["LC_ALL"]

    /// 契约中的变量，ci.yml **必须**声明且值**逐字**相等（防删、防改值）。
    @Test func CI必须按契约声明门槛变量() throws {
        let env = try loadEnv()

        // 负向锚：两边解析为空 = 口径失效，不是「都一致」
        #expect(!Self.envContracts.isEmpty, "契约表是空的 —— 守卫自己被清空了（假绿）")
        #expect(!env.declared.isEmpty, "ci.yml 顶层 env 块解析为空 —— 口径失效（假绿）")

        for (name, value) in Self.envContracts {
            #expect(
                env.declared[name] == value,
                """
                ci.yml 顶层 env 里没有 `\(name): "\(value)"`（实际 \(env.declared[name].map { "\"\($0)\"" } ?? "无")）。
                「门槛失败时全量回显日志」这条由此变量保证；删掉或改值**不会有任何报错** ——
                只会让 CI 失败时日志被截成 30 行，断言消息看不全（踩过：19 个 issue 只露出 12 个）。
                """)
        }
    }

    /// 契约里的变量，脚本必须**真的读**它（防改名 ⇒ 静默失效）。
    @Test func 契约变量必须被脚本真的读() throws {
        let env = try loadEnv()
        for name in Self.envContracts.keys {
            let readers = env.readers(of: name)
            #expect(
                !readers.isEmpty,
                """
                没有任何脚本读 `\(name)` ——
                ci.yml 设了它，但没有脚本取用，**声明与消费断开而双方都不报错**。
                （改了脚本里的变量名却忘了改 ci.yml，症状一模一样：CI 悄悄退回默认值。）
                """)
        }
    }

    /// 脚本必须**认**契约里那个值 —— 光读到还不够。
    ///
    /// 少了这一条，`PREFLIGHT_FAIL_TAIL=0` 会被 `tail -n 0` 执行成「**一行都不回显**」：
    /// 变量读了、值也对，语义却是反的。
    ///
    /// ⚠️ 第二版这里只查「正文里有 `= "值"`」⇒ **变异把那一处改掉后仍然绿**：
    /// `preflight.sh` 里 `= "0"` 共 4 处，`FAILED` / `WITH_TESTS` 的比较把它顶住了。
    /// ⇒ **字面量必须绑定角色**：同一行里要同时出现「承接这个变量的那个名字」和这个值。
    /// （与文件头「唯一是相对于角色」同一条，方向相反：那次是集合范围宽，这次是模式宽。）
    @Test func 脚本必须认契约里那个值() throws {
        let env = try loadEnv()
        for (name, value) in Self.envContracts {
            let readers = env.readers(of: name)
            guard !readers.isEmpty else { continue }
            // ⚠️ `readers` 返回的是**脚本路径**，不是正文 —— 拿路径去搜字面量永远搜不到
            // （第一版就是这么写的：红得很冤，但至少不是假绿）。
            let handled = readers.contains { path in
                guard let body = env.scriptBodies[path] else { return false }
                // 承接它的名字（`FAIL_TAIL="${PREFLIGHT_FAIL_TAIL:-30}"` ⇒ `FAIL_TAIL`），
                // 加上变量本身 —— 脚本也可能直接拿原名比较。
                let names = Set([name] + Self.assignedNames(of: name, in: body))
                return body.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
                    let l = String(line)
                    guard l.contains("= \"\(value)\"") || l.contains("=\"\(value)\"") else { return false }
                    return names.contains { l.contains($0) }
                }
            }
            #expect(
                handled,
                """
                读 `\(name)` 的脚本（\(readers.joined(separator: " / "))）里，
                找不到针对值 `\(value)` 的分支（形如 `= "\(value)"`）。
                变量读了、值也对，但若脚本没有这一支，`\(value)` 会落进别的语义 ——
                例如 `tail -n 0` 会把日志**整个抹掉**，比不设还糟。
                """)
        }
    }

    /// 反向（通用补充）：ci.yml 声明的变量必须被脚本读，除 runner 级白名单。
    ///
    /// 这一条守的是「**以后新增 env 时忘了接线**」—— 契约表只覆盖已知的那几个。
    @Test func CI声明的变量必须被脚本读() throws {
        let env = try loadEnv()
        for (name, _) in env.declared where !Self.runnerLevelEnv.contains(name) {
            #expect(
                !env.readers(of: name).isEmpty,
                """
                ci.yml 声明了 `\(name)`，但没有脚本读它 —— **设了没生效**，
                而两边都不会报错。要么接上消费方，要么把它放进 `runnerLevelEnv`
                （若它的消费者是 CI runner 本身，如 `LC_ALL`）。
                """)
        }
    }

    /// 白名单是**账本**，两个方向都要查（§8.50.2）：
    /// 放进白名单的理由是「没人读它」—— 哪天有人读了，它就得**移出**白名单。
    @Test func runner级白名单要双向查() throws {
        let env = try loadEnv()
        for name in Self.runnerLevelEnv {
            #expect(
                env.readers(of: name).isEmpty,
                """
                `\(name)` 在白名单里（理由是「它的消费者是 CI runner，不由脚本读」），
                但现在有脚本读它了 —— 它已经是**普通契约变量**，
                该从 `runnerLevelEnv` 移出，否则以后它断开了没人拦（假绿）。
                """)
        }
    }

    /// ⚠️ **门槛脚本必须把 CI 的 runner 级变量设成同一个值**（2026-09-21 新增）。
    ///
    /// 为什么需要它：`runnerLevelEnv` 把 `LC_ALL` 白名单成「消费者是 CI runner，不由脚本读」
    /// —— 而白名单**同时**把它排除在两条既有检查之外
    /// （`CI必须按契约声明门槛变量` 只查 ci.yml 那侧；`CI声明的变量必须被脚本读` 又跳过白名单）
    /// ⇒ 「**本地这侧设了吗**」**没有任何机器检查**。
    ///
    /// 而它以前是靠**手动**补的：`1f611d9` 的提交正文写着「门槛 11/11 通过
    /// （本地 LC_ALL=en_US.UTF-8）」—— 「本地门槛 = CI 门槛」这条承诺**靠人记得加那一段**；
    /// 忘了加就悄悄降级，而两边都不报错。真出过事：`b530f68`（§8.108.1）——
    /// bash 3.2 在 UTF-8 locale 下会把紧跟变量名的**全角括号**算进变量名 ⇒ `set -u` 报 unbound；
    /// 本机 locale 是 C 所以**永远不红**，推上去才炸。
    ///
    /// ⚠️ **别读成「它能复现 CI 的文案类断言失败」**：`LC_ALL` **不会改变 `Locale.current`**
    /// （ci.yml 自己实测过：设了它，`Locale.current` 仍是 `zh_CN`）⇒ 那 76 次连红走的是
    /// Swift 侧 `Locale.current` 那条轴，与这里**不是同一件事**。
    ///
    /// 判据：ci.yml 顶层 env 里的 runner 级变量，门槛脚本必须设成**逐字相同的值**。
    @Test func 门槛必须把CI的runner级变量设成同一个值() throws {
        let env = try loadEnv()
        let gate = Self.stripComments(try read("Scripts/preflight.sh"))

        // 负向锚：两边都得真读到（读不到 = 口径失效，不是「一致」）
        #expect(!Self.runnerLevelEnv.isEmpty, "runner 级白名单是空的 —— 守卫自己被清空了（假绿）")
        let contracted = Self.runnerLevelEnv.filter { env.declared[$0] != nil }.sorted()
        #expect(
            !contracted.isEmpty,
            """
            ci.yml 顶层 env 里找不到任何 runner 级变量（白名单 \(Self.runnerLevelEnv.sorted())）。
            口径失效：变量名改了、或 `env:` 块解析坏了 —— 这一条会静默退化成「无事可查」（假绿）。
            """)

        for name in contracted {
            guard let value = env.declared[name] else { continue }
            let assigned = gate.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
                let l = String(line)
                return l.contains("\(name)=") && l.contains(value)
            }
            #expect(
                assigned,
                """
                门槛脚本 `Scripts/preflight.sh` 没有把 `\(name)` 设成 CI 那个值（`\(value)`）。
                它被 `runnerLevelEnv` 白名单排除在「脚本必须读」之外 ⇒ **断了不会有任何东西变红**。
                后果：本地门槛跑在与 CI **不同的 shell locale** 下（本机 LC_COLLATE=C、
                CI en_US.UTF-8）—— 这类差异曾让 `b530f68`（§8.108.1）**推上去才炸**，
                本机因为 locale 是 C 而永远不红。
                """)
        }
    }

    // MARK: 第三族：门槛的**输入**不得被实验状态污染（2026-09-20）

    /// 「本地复现 CI 英文环境」那个实验开关，必须处于**正式值**。
    ///
    /// `TestLanguage.swift` 里 `design` 的文档注释写着「**用完必须改回 `"zh-Hans"`**」——
    /// 这是一句**只靠人记性**的承诺：与 §8.88 那类「注释里的承诺」同族，**没有任何机器检查**。
    ///
    /// ⚠️ 为什么它比看上去重要：这个常量是**门槛的输入**，不是一个普通的测试参数。
    /// 它一变成 `"en"`，所有「按中文实测的设计稿数字」断言立刻变红，
    /// 而**红出来的数字与 CI 英文环境逐位相同**（`TestLanguage.swift` 自己举过例：
    /// 按钮 57.0 / 163.0、路径小标 384.0、设置面板 612.25）。
    /// ⇒ 同一个红有两种解释 —— 「产品坏了」与「我还在实验态」—— **看到红的人无从分辨**。
    /// 这正是本仓库反复踩的那一族：**症状与真问题逐字相同**。
    ///
    /// 后果有两条，方向相反：
    /// 1. 忘了改回 ⇒ 本地门槛从此按**英文**判，报出的红被当成产品缺陷去查（永远查不到）；
    /// 2. 忘了改回**并提交了** ⇒ CI 判据被永久改宽/改窄，本地再也复现不出来。
    ///
    /// ⚠️ **做判别实验时这条会红，那是设计意图** —— 它让「我现在在实验态」
    /// 在测试输出里**可见**，而不是只存在于某人的记忆里。
    /// （判别实验本身是 §8.102 ⑥ 那套：改 `design` 复现 CI 只是判别手段，**验收是 CI 自己**。）
    @Test func 复现CI用的实验开关必须复位() {
        #expect(
            TestLanguage.design == "zh-Hans",
            """
            `TestLanguage.design` 现在是 `\(TestLanguage.design)`，不是 `"zh-Hans"`。
            这是「本地复现 CI 英文环境」的**实验状态**，用完必须改回 ——
            见 `Tests/SafeOutAppTests/TestLanguage.swift` 里 `design` 的文档注释。
            在复位之前，门槛报出来的红**不能**当成产品缺陷：两者症状逐位相同。
            """)
    }

    // MARK: 扫描

    private struct Scan {
        var ciScripts: Set<String> = []  // ci.yml 非注释行里调用的脚本（已归一化）
        var runScript: String?  // run.sh check 分支 exec 的脚本
        var bypass: [String] = []  // ci.yml 里直接跑的门槛命令
    }

    /// ci.yml 的 **env 声明** 与脚本正文的**消费**。
    private struct EnvScan {
        var declared: [String: String] = [:]  // 变量 → 值（已剥引号）
        var scriptBodies: [String: String] = [:]  // 脚本路径 → 非注释正文

        /// 哪些脚本**真的取用**了这个变量（`$VAR` / `${VAR`）。
        func readers(of name: String) -> [String] {
            let pattern = #"\$\{?"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return scriptBodies.filter { _, body in
                re.firstMatch(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) != nil
            }.keys.sorted()
        }
    }

    private func loadEnv() throws -> EnvScan {
        var scan = EnvScan()
        scan.declared = Self.parseEnvBlock(try read(".github/workflows/ci.yml"))

        let fm = FileManager.default
        var files: [String] = []
        let scriptsDir = repoRoot.appendingPathComponent("scripts")
        // ⚠️ **必须递归**（`subpathsOfDirectory`，不是 `contentsOfDirectory`）：
        //    2026-09-20 把 `run_gate` 抽到 `Scripts/lib/gate_report.sh`，环境契约的
        //    「读」随之挪走，而这里只枚举一层 ⇒ 立刻报「**没有任何脚本读**
        //    `PREFLIGHT_FAIL_TAIL`」。那句与「真的没人读了」**逐字相同** ——
        //    范围窄了一层，判据就从「查接线」变成了「报错文不对题」。
        files += ((try? fm.subpathsOfDirectory(atPath: scriptsDir.path)) ?? [])
            .filter { $0.hasSuffix(".sh") }.sorted().map { "Scripts/\($0)" }
        files += ((try? fm.contentsOfDirectory(atPath: repoRoot.path)) ?? [])
            .filter { $0.hasSuffix(".sh") }.sorted()

        for f in files {
            // 读不到就抛 —— 静默跳过会让「没有脚本读它」变成一句空话（假绿）。
            scan.scriptBodies[f] = Self.stripComments(try read(f))
        }
        return scan
    }

    /// ⚠️ **范围锚**：`loadEnv` 扫到的脚本集必须 == `Scripts/` 下**所有** `.sh`（递归）。
    ///
    /// 2026-09-20 它只枚举一层，`Scripts/lib/gate_report.sh` 一挪进去就**不在范围里**，
    /// 于是「`PREFLIGHT_FAIL_TAIL` 没有脚本读」—— 而这条消息与「真的没人读了」
    /// **逐字相同**，读它的人会去改接线，越改越错。⇒ 范围本身要有一条守卫。
    /// 少了这一条，退回 `contentsOfDirectory`（一层）**照样绿**。
    @Test func 脚本扫描范围必须覆盖scripts下所有sh() throws {
        let env = try loadEnv()
        let fm = FileManager.default
        let dir = repoRoot.appendingPathComponent("scripts")
        let expected = Set(
            ((try? fm.subpathsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".sh") }
                .map { "Scripts/\($0)" })
        let got = Set(env.scriptBodies.keys.filter { $0.hasPrefix("Scripts/") })
        #expect(
            !expected.isEmpty,
            "Scripts/ 下没找到任何 .sh —— 枚举口径失效，后面的「没人读」全是假绿")
        #expect(
            got == expected,
            "扫描范围与「Scripts/ 下所有 .sh（递归）」不一致，缺：\(expected.subtracting(got).sorted())")
    }

    /// 承接某个环境变量的**局部变量名**：`FAIL_TAIL="${PREFLIGHT_FAIL_TAIL:-30}"` ⇒ `FAIL_TAIL`。
    ///
    /// ⚠️ 派生而不是手填 —— 手填一张「变量 → 局部变量」表，改脚本时又会不同步
    /// （记忆里的原则：**能派生就别用「手动开关」**）。
    private static func assignedNames(of name: String, in body: String) -> [String] {
        let pattern = #"^\s*([A-Za-z_][A-Za-z0-9_]*)="?\$\{?"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        let r = NSRange(body.startIndex..<body.endIndex, in: body)
        return re.matches(in: body, range: r).compactMap { m in
            Range(m.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// 解析 ci.yml **顶层** `env:` 块（缩进 2 起的 `KEY: 值`）。
    private static func parseEnvBlock(_ yml: String) -> [String: String] {
        let lines = yml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String: String] = [:]
        var inEnv = false
        for l in lines {
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed == "env:" {
                inEnv = true
                continue
            }
            guard inEnv else { continue }
            if !l.hasPrefix(" ") && !l.hasPrefix("\t") {
                if trimmed.isEmpty { continue }
                break  // 回到顶层键 ⇒ env 块结束
            }
            guard
                let re = try? NSRegularExpression(
                    pattern: #"^\s+([A-Za-z_][A-Za-z0-9_]*):\s*"?(.*?)"?\s*$"#),
                let m = re.firstMatch(in: l, range: NSRange(l.startIndex..<l.endIndex, in: l)),
                let kr = Range(m.range(at: 1), in: l), let vr = Range(m.range(at: 2), in: l)
            else { continue }
            out[String(l[kr])] = String(l[vr])
        }
        return out
    }

    private func load() throws -> Scan {
        let ciRaw = try read(".github/workflows/ci.yml")
        // 注释行不算「跑了命令」—— ci.yml 里大量中文注释会提到这些命令名（假红来源）。
        let ciBody = Self.stripComments(ciRaw)

        var scan = Scan()
        for m in Self.allMatches(in: ciBody, pattern: #"\./([A-Za-z0-9_./-]+\.sh)"#) {
            scan.ciScripts.insert(Self.normalize(m))
        }
        for p in ["swift test", #"swift-format\s+lint"#, #"swift-format\s+format"#] {
            scan.bypass.append(contentsOf: Self.allMatches(in: ciBody, pattern: p))
        }

        let runRaw = try read("run.sh")
        // `exec "$SCRIPT_DIR/xxx.sh" "$@"` 在 run.sh 里有**两处**（2026-09-20 起）：
        // `check` → preflight.sh、`ci` → ci_status.sh。
        // ⚠️ 这里取 `hits.first` ⇒ **`check` 分支必须排在 `ci` 分支之前**；
        // 否则本守卫会静默改去比对 `ci_status.sh` —— 它不在 CI 调用的脚本集合里
        // ⇒ 报一条**与真问题无关的假红**。该顺序由下面
        // `run_sh里check分支必须排在ci分支之前` 钉住。
        let hits = Self.allMatches(
            in: runRaw, pattern: #"exec\s+"\$SCRIPT_DIR/([A-Za-z0-9_./-]+\.sh)""#)
        scan.runScript = hits.first.map(Self.normalize)
        return scan
    }

    // MARK: 工具

    /// 剥掉**整行**注释（`#` 开头，含缩进）。
    ///
    /// ⚠️ 不剥行内尾注：shell 里 `#` 未必是注释（`$#`／`${x#y}`），
    /// 粗剥会把真代码削掉 ⇒ 假阴性。本仓库这几处都是整行注释，够用。
    private static func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// 路径归一化：`./Scripts/preflight.sh` 与 `Scripts/preflight.sh` 是同一个文件。
    private static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        return p
    }

    /// ⚠️ 取**整个匹配**（range 0），不用捕获组 ——
    /// 调用方极易写出「没有捕获组的正则」，`range(at: 1)` 会直接抛异常把测试进程带崩。
    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            // 有捕获组就用它（好读），没有就退回整个匹配（不崩）。
            let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range(at: 0)
            return Range(r, in: text).map { String(text[$0]) }
        }
    }
}
