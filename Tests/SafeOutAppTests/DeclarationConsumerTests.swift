import Foundation
import Testing

@testable import SafeOutApp

/// **「有声明、没有消费者」这一类，钉在 CI 里。**
///
/// ## 为什么需要（2026-09-18 实扫，SPEC §8.48 / §8.49）
///
/// 这是这半年里最贵的一类 bug，已经撞了三次：
///
/// | 实例 | 症状 |
/// |---|---|
/// | `UpdateController.startIfNeeded()` | updater 从未启动 → 自动更新整条链**从未跑过** |
/// | `driverDidFailDownload` | `.failed` 那一态**没有生产者** → 下载失败时进度条无声消失 |
/// | 三组 `*BusyBar*` 令牌**接错行** | 琥珀条短 4pt，而界面上与「本来就这么长」**逐字相同** |
/// | `AppFont`（**整个类型**） | 49 行 / 10 个字号令牌**零消费者**，而它的注释仍宣称「视图层只引用它」—— 前两个 suite 都**看不见**（只读一个文件）⇒ 第三个 suite 补上（§8.100）|
///
/// 共性是：**界面上与「功能坏了」逐字相同，读代码也看不出来。**
/// 而 **Swift 不为字符串级常量报警** —— 删掉一个没人用的设计令牌或偏好键，
/// 代码照样编译、测试照样绿、界面看不出任何变化。它只是躺在声明表里，
/// 而下一个读到的人会以为还有一个地方在用。
///
/// 上一轮（§8.48）删掉了 **15 个**零消费者令牌 + **2 个**零消费者文案键，
/// 但**当时没有守卫** ⇒ 下一轮还会长出来。这两个 suite 就是来堵这个口子的。
///
/// ## 三个 suite 共同的口径
///
/// - **只看 `Sources/`**（不含 `Tests/`）：一个只在测试里出现的常量，生产代码里
///   没有任何地方用它 —— 那正是要人过目的事（设计令牌那边实测有 5 个属于这一类）。
/// - **去掉整行注释**：本仓库的注释习惯是**引用**被讨论的标识符
///   （这两条注释自己就提到了 `startIfNeeded` / `driverDidFailDownload`），
///   不去掉的话「把使用删掉、注释留着」依然会绿。
/// - **去掉声明自己**：否则每个常量都「消费」了它自己。
///   `static var` 的计算属性与 `enum Key { … }` 体都可能是**多行**，按花括号配平整块去掉。
/// - **exemptions是账本，不是垃圾桶**：两个方向都查 —— 新长出来的要拦下，
///   登记了却已经不作数的要回来划掉（否则就会像 §8.33 清掉的那 6 条一样，
///   **还了账没人回来划**）。
///
/// ⚠️ **已知的松**：不区分「引用的是哪个命名空间下的同名常量」，且 `static func` 体、
/// `extension` 里的引用都算消费者 —— 也就是说这两个守卫**会漏报，但不会误报**
/// （宁可漏报：误报会让人把守卫关掉）。完整的（能抓漏报的）扫描在
/// `.build/probe/keyref_scan.py`，见 §8.48。
@Suite("设计令牌的消费者")
struct DesignTokenConsumerTests {

    private let sources = SourceReader()

    private var tokensFile: URL {
        sources.repoRoot.appendingPathComponent("Sources/Views/DesignTokens.swift")
    }

    // MARK: exemptions（**这是账本，不是垃圾桶**）

    /// 设计稿里有、实现当前**不用**的值 —— 留着是为了让「设计稿 vs 实现」的对照有出处。
    ///
    /// 这些不是死代码：它们是**设计稿的字面值记录**。删掉它们，下一轮再想核对
    /// 「设计稿写的是 46 还是 48」就得回去翻 `ds.css`。
    private static let designValueRecords: [String: String] = [
        "full": "设计稿圆角 999（用 `Capsule()` 表达），此处仅作语义索引",
        "display": "设计稿字号档 20/600 —— 实现未用（弹窗标题用 `title` 15、引导标题用 `heading` 17）",
        "confirmDialogMaxWidth": "推出确认对话框宽度上限（设计稿 400，上限 420），实现按内容自适应",
        "alertFootHeight": "弹窗操作区高度（设计稿实测 54 = 按钮 30 + 上下内边距 12），实现由内边距推导",
        "systemTrafficLightCenterFromTop": "系统交通灯垂直中心实测值（16pt），用来与设计稿的 26pt 对照",
        "compactRowHeight": "紧凑行高度（设计稿实测 46），实现由内容推导",
        // ⚠️ 这里原有 `"e2": "设计稿三档阴影之一（悬停抬升 / 浮层），实现目前只用 e1"` ——
        // **2026-09-29 划掉**：两栏形态的 ``SettingsAboutPane``（「关于」页居中大图标）
        // 用的是 `Elevation.e2`，生产代码有消费者了 ⇒ 豁免的前提不成立。
        // 这条守卫（`令牌exemptions不许过期`）抓的正是「账目过期」：一句话写着
        // 「实现只用 e1」，而实现已经用了 e2 —— 后面的人会照着这句话去删 e2。
        "e3": "设计稿三档阴影之一（窗口 / 弹窗），实现目前只用 `e1` / `e2`",
    ]

    /// 只被**测试**引用、生产代码不用的令牌 —— 是**设计稿实测基准**，不是「拿常量跟自己比」。
    ///
    /// ⚠️ **2026-09-18 订正**：这里原先写「正是 §8.48 那条 —— 期望值不能取实现里的令牌，
    /// 否则拿常量跟自己比，断言照样绿」—— **这个归因是错的**，实扫证伪了它。
    /// 判据是「**实现读不读它**」：这 5 个生产代码**零引用**，行高是 SwiftUI 自然布局出来的，
    /// 所以测试量的是 **「实现渲染高度 == 设计稿渲染高度」** ——
    /// 改实现的 padding、或改令牌的值，**两个方向都会红**（实测容差 2pt、偏差 ≤ 0.47pt）。
    /// 拿它们当期望值是对的：比把 169/127/133/69 散落成字面值更好（有注释、有出处）。
    ///
    /// 真正的洞在**另一头**：镜像本身没有与设计稿同源的守卫。行高在设计稿里是自然布局
    /// （CSS 里没有 `height` 声明），只能靠无头 Chrome 实测 ⇒ **进不了 CI**。
    /// 复核脚本 `.build/probe/design_row_height.py`；**2026-09-18 复核逐项仍成立**
    /// （169.47 / 127.47 / 133.47 / 68.72，且状态对应关系也核对过）。
    private static let testOnlyReferences: [String: String] = [
        "titleBarHeight": "设计稿实测基准（`.titlebar` 52px）⚠️ 这 5 个里**唯一能**做成 CI 守卫的"
            + "（CSS 有 `--h-titlebar: 52px`），但**还没做** —— 见 §8.51.4",
        "diskRowBusyHeight": "设计稿实测基准 169.47（`.row--busy`），只被 `MenuDiskRowLayoutTests` 当期望值",
        "diskRowSafeHeight": "设计稿实测基准 127.47（「可以安全推出」），只被 `MenuDiskRowLayoutTests` 当期望值",
        "diskRowUnknownHeight": "设计稿实测基准 133.47（「占用情况未知」），只被 `MenuDiskRowLayoutTests` 当期望值",
        "menuRowHeight": "设计稿实测基准 68.72（`.mrow`），只被 `MenuDiskRowLayoutTests` / `MenuPopoverLayoutTests` 当期望值",
    ]

    private static var exemptions: [String: String] {
        designValueRecords.merging(testOnlyReferences) { 设计稿侧, _ in 设计稿侧 }
    }

    // MARK: 守卫

    /// **新长出来的零消费者令牌要在这里被拦下。**
    @Test func 零消费者的令牌必须登记在案() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: tokensFile, encoding: .utf8))
        let tokens = SourceReader.staticDeclarations(in: code)
        #expect(
            tokens.count > 100,
            "只解析到 \(tokens.count) 个令牌 —— 解析逻辑多半坏了，下面的结论一律作废"
        )

        let declared = Set(tokens.map(\.name))

        // 解析器的**anchors**：几种声明形态各取一个已知令牌 ——
        // `let` 带类型（`full`）、`let` 无类型（`sm`）、`var` 单行计算属性（`raised`）、
        // `var` **多行**计算属性（`subtle`，走的是花括号配平那条路）、
        // 嵌套枚举里的（`mainWindow` / `mainSidebarWidth`）、`e1`。
        // 少了它们说明「收声明」的逻辑退化了（例如 `static var` 整类没收到），
        // 而那种情况下「未登记」会**空着** —— 通过得毫无意义。
        //
        // ⚠️ **别再用 `window` 当锚点**：那是 ``Radius/window``（我们自己给窗口画的 12pt
        // 外圆角），**v3 已删**（窗口圆角归窗口服务器，HANDOFF §3.7.2）。
        // 拿一个已退役的令牌当锚点，是把自己的守卫绑在别人的生命周期上 ——
        // 令牌一删，这条就红在「解析器坏了」上，而真正的退化点反而看不出来。
        let anchors = ["full", "sm", "display", "mainWindow", "mainSidebarWidth", "raised", "subtle", "e1"]
        let missingAnchors = anchors.filter { !declared.contains($0) }.sorted()
        #expect(missingAnchors.isEmpty, "解析器漏掉了这些已知令牌：\(missingAnchors) —— 收声明的逻辑退化了，下面的结论作废")

        let (corpus, fileCount) = try sources.corpus(
            excluding: [tokensFile.lastPathComponent: tokens.map(\.text)])
        #expect(fileCount > 30, "只读到 \(fileCount) 个 .swift —— 路径多半不对，下面的结论一律作废")

        let unregistered =
            declared
            .subtracting(Self.exemptions.keys)
            .filter { !SourceReader.isReferenced($0, in: corpus) }
            .sorted()

        #expect(
            unregistered.isEmpty,
            """
            这些设计令牌在 Sources/ 里没有任何消费者：\(unregistered)。\
            删掉它们不会编译失败、不会让任何测试变红、界面也不会有任何变化 —— \
            只是躺在令牌表里，而下一个读到的人会以为还有一个地方在用它们。
            要么接上真正的使用点，要么删掉；若确实是「designValueRecords」\
            （设计稿里有、实现当前不用），把它登记进 `designValueRecords` 并写明理由。
            """
        )
    }

    /// **exemptions不许过期** —— 账本要能自己对上。
    @Test func 令牌exemptions不许过期() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: tokensFile, encoding: .utf8))
        let tokens = SourceReader.staticDeclarations(in: code)
        let declared = Set(tokens.map(\.name))
        let (corpus, _) = try sources.corpus(
            excluding: [tokensFile.lastPathComponent: tokens.map(\.text)])

        let noLongerDeclared = Self.exemptions.keys.filter { !declared.contains($0) }.sorted()
        #expect(
            noLongerDeclared.isEmpty,
            "exemptions里登记了这些令牌，但它们已经不在 DesignTokens.swift 里了：\(noLongerDeclared)。从exemptions删掉"
        )

        let nowConsumed =
            Self.exemptions.keys
            .filter { declared.contains($0) && SourceReader.isReferenced($0, in: corpus) }
            .sorted()
        #expect(
            nowConsumed.isEmpty,
            """
            这些令牌已经有生产代码消费者了：\(nowConsumed)。\
            豁免的前提是「没有生产代码消费者」，现在不成立了 —— 回来把它们从exemptions里划掉。
            """
        )
    }
}

/// **偏好键必须有「生产代码」消费者**（`Key.<名>` 形式）。
///
/// 口径与上面那个 suite 完全一致，只有「怎么算消费者」不同：
/// 偏好键的消费者是 `Key.<名>`（可带 `AppSettings.` 前缀），**不能按裸名判** ——
/// `accentColor` / `visualStyle` 同时是 ``AppSettings`` 上的属性名，
/// 按裸名判会把「属性被读到」当成「键被用到」。
///
/// ⚠️ 另一个实测过的坑：**不能把整个声明文件排除**。`hasShownFDAOnboarding` 的消费者
/// `AppSettings.didShowFDAOnboarding` **就在同一个文件里** —— 所以只剥掉 `enum Key { … }`
/// 那一块，文件其余部分照常参与。
@Suite("偏好键的消费者")
struct PreferenceKeyConsumerTests {

    private let sources = SourceReader()

    private var settingsFile: URL {
        sources.repoRoot.appendingPathComponent("Sources/Settings/AppSettings.swift")
    }

    /// `launchAtLogin` 的键由 ``LaunchAtLoginManager`` 持有，`Key` 里那条
    /// **仅作文档索引**（它自己的文档注释就这么写的）—— 生产代码不消费它是**有意为之**。
    private static let exemptions: [String: String] = [
        "launchAtLogin": "键由 `LaunchAtLoginManager.defaultsKey` 持有，`Key` 里这条仅作文档索引"
    ]

    @Test func 零消费者的偏好键必须登记在案() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: settingsFile, encoding: .utf8))
        let keys = SourceReader.keyEnumDeclarations(in: code)
        #expect(
            keys.count >= 5,
            "只解析到 \(keys.count) 个偏好键 —— 解析逻辑多半坏了，下面的结论一律作废"
        )

        let declared = Set(keys.map(\.name))
        let (corpus, fileCount) = try sources.corpus(
            excluding: [settingsFile.lastPathComponent: keys.map(\.text)])
        #expect(fileCount > 30, "只读到 \(fileCount) 个 .swift —— 路径多半不对，下面的结论一律作废")

        let unregistered =
            declared
            .subtracting(Self.exemptions.keys)
            .filter { !SourceReader.isKeyReferenced($0, in: corpus) }
            .sorted()

        #expect(
            unregistered.isEmpty,
            """
            这些偏好键在 Sources/ 里没有任何消费者：\(unregistered)。\
            删掉它们不会编译失败、不会让任何测试变红 —— 只是躺在 `AppSettings.Key` 里，
            而下一个读到的人会以为还有一个设置项在用它们。
            """
        )
    }

    @Test func 偏好键exemptions不许过期() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: settingsFile, encoding: .utf8))
        let keys = SourceReader.keyEnumDeclarations(in: code)
        let declared = Set(keys.map(\.name))
        let (corpus, _) = try sources.corpus(
            excluding: [settingsFile.lastPathComponent: keys.map(\.text)])

        let noLongerDeclared = Self.exemptions.keys.filter { !declared.contains($0) }.sorted()
        #expect(noLongerDeclared.isEmpty, "exemptions里登记了这些偏好键，但它们已经不在 `enum Key` 里了：\(noLongerDeclared)")

        let nowConsumed =
            Self.exemptions.keys
            .filter { declared.contains($0) && SourceReader.isKeyReferenced($0, in: corpus) }
            .sorted()
        #expect(nowConsumed.isEmpty, "这些偏好键已经有生产代码消费者了：\(nowConsumed)。回来从exemptions里划掉")
    }
}

// MARK: - 类型级：整类型零引用

/// **整类型零引用** —— 上面那两条守卫的共同盲区（2026-09-20 实扫，SPEC §8.100）。
///
/// **为什么单开这一条**：`设计令牌的消费者` 只读**一个文件**（`DesignTokens.swift`），
/// 所以「**整个文件**都是死代码」这种形态它**看不见**。`AppFont.swift` 就是这样：
/// 2026-09-12 那次重构（`25d0853`）引入了 `DesignTokens` 并改写了所有视图，
/// 却把 `AppFont.swift`（49 行 / 10 个字号令牌）留在原地 —— **此后 8 天零消费者**，
/// 而它自己的文档注释还写着「视图层只引用语义（`cardTitle` / `label` / `minor` …）」：
/// **这句话是假的**，且下一个读到它的人会以为还有一个地方在用。
///
/// **为什么扫「类型」而不是继续扫「常量」**：类型名是 CamelCase，几乎不与普通词撞名。
/// 实测同一份代码里：
/// - 扫 `static let/var`：`label` / `control` / `minor` 这类**通用词**会在别处（作为别的
///   标识符）出现 ⇒ 被判成「有消费者」⇒ **漏报**（`AppFont` 的 10 个令牌里只报出 6 个）；
/// - 扫类型名：**129 个类型 / 1 个零引用 / 0 误报**。
///
/// 口径：`Sources/` 里的 `enum` / `struct` / `class` / `actor` / `protocol` 声明，
/// 在 **`Sources/` 正文**（去整行注释）里出现 **≤ 1 次**（只有声明自己）即为零引用。
/// ⚠️ 已知的松：名字出现在**字符串字面量**里、或只被自己的 `extension` 提到，都算「有引用」。
@Suite("类型的消费者")
struct TypeConsumerTests {

    private let sources = SourceReader()

    /// 已知的零引用类型 —— **空表**。
    ///
    /// 空表不等于「没有用」：它让「新长出来一个」变成一条**具体的红**，
    /// 而不是「本来就没查」。登记时必须在注释里写清**为什么留着**（照上面两条的规矩）。
    private static let exemptions: [String: String] = [:]

    /// 一条类型声明：名字 + 出处文件（失败信息里要能直接定位）。
    private struct TypeDeclaration {
        let name: String
        let file: String
    }

    private static let typePattern =
        #"^[ \t]*(?:(?:public|internal|private|fileprivate|final|open)[ \t]+)*"#
        + #"(?:enum|struct|class|actor|protocol)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"#

    private static func typeDeclarations(in code: String, file: String) -> [TypeDeclaration] {
        guard let regex = try? NSRegularExpression(pattern: typePattern) else { return [] }
        var found: [TypeDeclaration] = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let whole = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: whole),
                let range = Range(match.range(at: 1), in: text)
            else { continue }
            found.append(TypeDeclaration(name: String(text[range]), file: file))
        }
        return found
    }

    /// `Sources/` 下全部 `.swift`（递归）。
    static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// 名字在语料里出现**至少 2 次**（声明自己 + 至少一处引用）才算有消费者。
    static func isReferenced(_ name: String, in corpus: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
        let range = NSRange(corpus.startIndex..<corpus.endIndex, in: corpus)
        return regex.numberOfMatches(in: corpus, range: range) >= 2
    }

    @Test func 零引用的类型必须登记在案() throws {
        let files = Self.swiftFiles(under: sources.sourcesRoot)
        #expect(
            files.count > 20,
            "只枚举到 \(files.count) 个源文件 —— 枚举多半坏了，下面的结论一律作废")

        var corpus = ""
        var declarations: [TypeDeclaration] = []
        for url in files {
            let code = SourceReader.codeOnly(try String(contentsOf: url, encoding: .utf8))
            corpus += "\n" + code
            declarations += Self.typeDeclarations(in: code, file: url.lastPathComponent)
        }

        // 解析器的**自证**：少了它，「零引用」可能只是「一个类型都没解析出来」——
        // 这两种情况在断言层面完全一样。
        #expect(
            declarations.count > 100,
            "只解析到 \(declarations.count) 个类型声明 —— 解析逻辑多半退化了（实测 129）")

        let zero = declarations.filter { !Self.isReferenced($0.name, in: corpus) }
        let unregistered = zero.filter { Self.exemptions[$0.name] == nil }

        #expect(
            unregistered.isEmpty,
            """
            这些类型在 `Sources/` 里**没有任何消费者**（连声明自己算上只出现 1 次）：\
            \(unregistered.map { "\($0.file)：\($0.name)" }.joined(separator: "、"))。
            整类型的死代码会**一直骗下一个读代码的人**（`AppFont` 的文档注释就还在说「视图层只引用它」）。
            要么删掉，要么在 `exemptions` 里登记**留着的原因**。
            """)

        // **账本不是垃圾桶**：登记了、但现在已经有消费者了 ⇒ 回来划掉。
        let stale = Self.exemptions.keys.filter { name in
            !zero.contains { $0.name == name }
        }.sorted()
        #expect(stale.isEmpty, "exemptions 里登记了这些类型，但它们已经有消费者了：\(stale)。回来划掉")
    }
}

// MARK: - 共用的读源工具

/// 读 `Sources/` 的小工具：两个 suite 共用同一套口径（见文件头的说明）。
private struct SourceReader {

    /// `#filePath` = `<仓库根>/Tests/SafeOutAppTests/<本文件>.swift`
    let repoRoot: URL

    init(filePath: String = #filePath) {
        repoRoot =
            URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()  // SafeOutAppTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // 仓库根
    }

    var sourcesRoot: URL { repoRoot.appendingPathComponent("Sources") }

    /// 去掉**整行**注释（行首空白后以 `//` 开头）。
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `Sources/` 全部 `.swift` 去注释后的正文拼成的语料。
    ///
    /// `excluding`：`文件名 → 要从该文件里剥掉的整块文本`（常量自己的声明）。
    func corpus(excluding blocks: [String: [String]] = [:]) throws -> (text: String, fileCount: Int) {
        guard let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        else {
            Issue.record("枚举不到 \(sourcesRoot.path)")
            return ("", 0)
        }
        var pieces: [String] = []
        var fileCount = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            fileCount += 1
            var code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            for block in blocks[url.lastPathComponent] ?? [] {
                code = code.replacingOccurrences(of: block, with: "")
            }
            pieces.append(code)
        }
        return (pieces.joined(separator: "\n"), fileCount)
    }

    /// 语料里有没有这个标识符的**独立**出现（前后不是标识符字符）。
    static func isReferenced(_ name: String, in corpus: String) -> Bool {
        matches(
            pattern: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])", in: corpus)
    }

    /// 偏好键的消费者写法：`Key.<名>`（可带 `AppSettings.` 前缀）。
    ///
    /// ⚠️ 负向断言里**不能带 `.`**：`(?<![\w.])Key\.x` 本意是「别匹配 `FooKey.x`」，
    /// 实际会把 `AppSettings.Key.x` 也整个挡掉 —— 实测让 7 个键**全部误报**零引用。
    /// `(?<![A-Za-z0-9_])` 既能挡住 `myKey.x`，又放得过 `AppSettings.Key.x`。
    static func isKeyReferenced(_ name: String, in corpus: String) -> Bool {
        matches(
            pattern: "(?<![A-Za-z0-9_])Key\\.\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])",
            in: corpus)
    }

    private static func matches(pattern: String, in corpus: String) -> Bool {
        corpus.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: 收声明

    /// 一条声明：名字 + **整块原文**（多行声明会连体一起给出，供语料剥离）。
    struct Declaration {
        let name: String
        let text: String
    }

    /// 声明模式。
    ///
    /// ⚠️ 用 `[ \t]*` 而**不是** `\s*`：`\s` 含换行，匹配起点会落到上一行空行上，
    /// 行号跟着错（实测踩过，零消费者名单因此对不上）。
    private static let declarationPattern = #"^[ \t]*static (?:let|var) ([A-Za-z_][A-Za-z0-9_]*)"#

    /// 收 `static let` / `static var` 声明（全文）。
    static func staticDeclarations(in code: String) -> [Declaration] {
        declarations(in: code.components(separatedBy: "\n"))
    }

    /// 收 `enum Key { … }` 块里的 `static let` / `static var`。
    ///
    /// ⚠️ **只剥这一块，不能整文件排除**：`Key.hasShownFDAOnboarding` 的消费者
    /// `AppSettings.didShowFDAOnboarding` **就在同一个文件里** ——
    /// 整文件排除会让它误报零引用（实测踩过）。
    static func keyEnumDeclarations(in code: String) -> [Declaration] {
        let lines = code.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { Self.isKeyEnumOpening($0) }) else { return [] }
        // `enum Key {` 这一行自身带一个 `{`，从它开始配平即可取到整块。
        var end = start
        var depth = braceDelta(lines[start])
        var next = start + 1
        while next < lines.count, depth > 0 {
            depth += braceDelta(lines[next])
            end = next
            next += 1
        }
        return declarations(in: Array(lines[start...end]))
    }

    private static func isKeyEnumOpening(_ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^[ \t]*enum Key[ \t]*\{"#) else {
            return false
        }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            != nil
    }

    /// 按花括号配平把整条声明吃下来（`static var` 的计算属性可能是多行 ——
    /// 不整块剥掉的话，它体内对**别的**常量的引用会留在语料里，
    /// 把那些常量判成「有消费者」）。
    private static func declarations(in lines: [String]) -> [Declaration] {
        guard let regex = try? NSRegularExpression(pattern: declarationPattern) else { return [] }
        var found: [Declaration] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let whole = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: whole),
                let nameRange = Range(match.range(at: 1), in: line)
            else {
                index += 1
                continue
            }
            // `static var` 的计算属性可能是多行 → 按花括号配平吃完整块，
            // 否则它体内对**别的**常量的引用会留在语料里，把那些常量判成「有消费者」。
            var end = index
            var depth = braceDelta(line)
            if depth > 0 {
                var next = index + 1
                while next < lines.count, depth > 0 {
                    depth += braceDelta(lines[next])
                    end = next
                    next += 1
                }
            }
            found.append(
                Declaration(
                    name: String(line[nameRange]),
                    text: lines[index...end].joined(separator: "\n")))
            index = end + 1
        }
        return found
    }

    /// 一行里花括号的净增量。
    private static func braceDelta(_ line: String) -> Int {
        line.reduce(0) { $0 + ($1 == "{" ? 1 : ($1 == "}" ? -1 : 0)) }
    }
}
