import Foundation
import Testing

@testable import SafeOutApp

/// **「控件在什么条件下点不动」这份清单，钉在 CI 里。**
///
/// ## 为什么需要（2026-09-21，SPEC §8.113.14）
///
/// 那一次修的是「**开关的禁用条件读了它自己的当前值**」：
/// 「自动更新」的 `onTap` 由 `canAutoUpdate` 决定，而 `canAutoUpdate` 读 Sparkle 的
/// `allowsAutomaticUpdates`，它在本应用里**恒等于这个开关自己的值**
/// ⇒ 关一次就**再也打不开**（可按元素 13 → 12，重启也救不回来）。
///
/// 这是**一类**错误，不是一处：凡是「点不动」的判据，只要它读的是
/// **这个控件自己写入的状态**，就会出现**单向陷阱**（拨过去就回不来）。
/// 同族的还有「状态会卡住」——判据读一个可能永不复位的标志，控件就永久禁用。
///
/// ⇒ 规则：**不可点判据只能看「宿主 / 环境」有没有能力，不能读控件自己。**
///
/// 发现一处之后按惯例**全局扫了一遍**（`Sources/` 下共 5 处），当时只有那一处是真陷阱。
/// 但**扫描是一次性的，清单会长出来** —— 这个 suite 就是把清单钉住：
/// 以后任何人新加一处「让控件点不动」的写法，都必须来这份账本上登记**理由**。
///
/// ## 口径（四类写法）
///
/// | 类别 | 匹配 | 为什么算 |
/// |---|---|---|
/// | `disabled` | `.disabled(` | SwiftUI 的禁用修饰符 |
/// | `hitTesting` | `.allowsHitTesting(false)` | 整个视图不吃点击 |
/// | `onTapNil` | `onTap: nil` | 行的点击动作被显式抹掉 |
/// | `tapActionNil` | `var X: (() -> Void)? {` **且体内有 `return nil`** | 点击动作是计算属性、条件返回 nil |
///
/// 前三类是**字面**匹配；第四类必须**连体一起看** —— 只看声明的话，
/// 一个「恒不返回 nil」的点击动作也会被算进来（误报）。
///
/// ## 两个方向都查（这也是装置的自证）
///
/// - **扫到的必须在账本里** ⇒ 拦住新长出来的；
/// - **账本里的必须真的扫到** ⇒ 拦住「清单过期」（条目删了、写法改了）。
///
/// ⚠️ 第二条同时是**装置自证**：如果扫描器哪天瞎了（返回空），第一条会**静默变绿**，
/// 但第二条会**立刻红**。⇒ 阴性结论（「只有这 5 处」）不会与「装置死了」同形。
/// 另外 `扫描器认得出这四类写法` 用**合成源码**单独验一遍，不依赖仓库当前内容。
///
/// ## 已知的紧 / 松
///
/// - **偏紧（会误报）**：按**行**匹配，所以 `.disabled(` 出现在**字符串字面量或行尾注释**里
///   也会被算作一处（整行注释已排除）。误报的代价是「多登记一条」，
///   而漏报的代价是「单向陷阱又长出来」—— 这个方向选的是**宁可误报**。
/// - **偏松（会漏报）**：认不出「用别的写法让控件点不动」，
///   例如自定义 `ButtonStyle` 里读环境值、或 `if` 分支根本不渲染这个控件。
///
/// ⚠️ **它守不住什么**：这是**清单守卫**，不是语义分析。它拦得住「新加了一处没登记的
/// 禁用判据」，拦不住「登记的这条理由写错了」。语义那一半靠
/// `UpdateSettingsTests.自动更新行的禁用条件不得由开关自己的值决定`（源码结构断言）
/// 与真机实测 —— 后者**没有**回归测试（一次性证据，见 §8.113.14）。
@Suite("不可点判据清单")
struct DisabledConditionInventoryTests {

    // MARK: - 账本（**这是账本，不是垃圾桶**）

    /// 当前 `Sources/` 下全部「让控件点不动」的写法。
    ///
    /// 每一条都要写**理由** —— 说明它为什么**不会**变成单向陷阱或永久禁用。
    private static let inventory: [Entry] = [
        Entry(
            file: "Sources/Views/SettingsView.swift",
            snippet: ".disabled(!isEnabled)",
            reason:
                "**v3（2026-09-30）从三条自绘开关的 tap action 合并而来**：v2 的开关是自绘的，"
                + "「不可拨」靠 `autoCheckUpdateTapAction` / `autoDownloadTapAction` 返回 `nil`；"
                + "v3 把开关交还系统的 `Toggle`（HANDOFF §3.4），判据写法随之变成 `.disabled(!isEnabled)`"
                + "（`SettingsSectionPane.toggleLine` 里那一句，两处调用方共用）。"
                + "两处实参的来源和原来逐条对应，且**都不读被禁控件自己的值**：\n"
                + "① `canAutoUpdate`（`updater != nil`）—— 宿主能力判据，与开关自己的值无关；\n"
                + "② `autoDownloadUpdateEnabled`（『自动检查更新』关着时为假）—— 读的是**另一个**开关，"
                + "表达的是真实因果：Sparkle 的 `automaticallyDownloadsUpdates` setter 在"
                + "`allowsAutomaticUpdates` 为假时是空操作，检查不做、下载根本写不进去。"
                + "**且不是死路**：检查行永远可点，用户的出口一直在；"
                + "「禁用时必须说明原因」由 `UpdateSettingsTests.下载行的可点性与说明必须同源` 钉住"),
        Entry(
            file: "Sources/Views/SettingsView.swift",
            snippet: ".disabled(true)",
            reason:
                "**v3 从 `takeOverTapAction` 搬过来的同一条判据**：没授「完全磁盘访问」时，"
                + "``SettingsSectionPane/takeOverUnavailableControl`` 里那颗 `Toggle` 恒不可点。"
                + "判据是**宿主/环境能力**（读 `takeOverAvailability`），与开关自己的值"
                + "（`takeOverFinderEject`）无关。\n"
                + "⚠️ 这一条**必须**挡，理由比 v2 更硬：那颗 `Toggle` 的 `isOn` 是"
                + "`.constant(takeOverOn)`（常量 binding）—— 若允许命中，拨一下开关**视觉会动、值不会落**，"
                + "正是「允许点击 → 什么都不发生 / 再弹错」的反面形态。"
                + "且未授权那一态**不是死路**：同一行行尾就是「打开系统设置」，"
                + "授权回来（`didBecomeActive`）这一行当场恢复可点"),
        Entry(
            file: "Sources/Views/DesignSystemComponents.swift",
            snippet: ".disabled(!isEnabled)",
            reason:
                "⚠️ `isEnabled` 默认 `true` 且**当前无调用方传入** ⇒ 恒不触发（还配了 0.45 透明度的禁用视觉）。"
                + "将来若真的传入，**必须是宿主/环境条件**，不得读该按钮自己写入的状态",
        ),
        Entry(
            file: "Sources/Views/DesignSystemComponents.swift",
            snippet: ".allowsHitTesting(false)",
            reason: "纯装饰层（1pt 分隔线的 `Canvas`），不吃点击，**不是状态判据**"),
        Entry(
            file: "Sources/Views/GlassViews.swift",
            snippet: ".allowsHitTesting(false)",
            reason: "纯背景层（玻璃底），不吃点击，**不是状态判据**"),
    ]

    // MARK: - 断言

    @Test func 不可点判据的清单是完整的() throws {
        let found = DisabledConditionScanner.scan(try realSources())
        let registered = Set(Self.inventory.map { Key(file: $0.file, snippet: $0.snippet) })

        let unregistered = found.filter { !registered.contains(Key(file: $0.file, snippet: $0.text)) }
        #expect(
            unregistered.isEmpty,
            """
            有 \(unregistered.count) 处「让控件点不动」的写法**没登记**：
            \(unregistered.map { "  \($0)" }.joined(separator: "\n"))

            ⇒ 先想清楚：**这个判据读的是「宿主/环境有没有能力」，还是「控件自己写入的状态」？**
              后者是单向陷阱（关掉就回不来，§8.113.14）。
              确认安全后，把这一条加进 `DisabledConditionInventoryTests.inventory`（**理由必填**）。
            """)
    }

    @Test func 账本里每一条都还作数() throws {
        let found = Set(DisabledConditionScanner.scan(try realSources()).map { Key(file: $0.file, snippet: $0.text) })

        let stale = Self.inventory.filter { !found.contains(Key(file: $0.file, snippet: $0.snippet)) }
        #expect(
            stale.isEmpty,
            """
            账本里有 \(stale.count) 条**已经扫不到**（写法改了 / 代码删了 / 文件改名）：
            \(stale.map { "  \($0.file)  \($0.snippet)" }.joined(separator: "\n"))

            ⇒ 回来划掉它（**还了账要回来划**），或者把 `snippet` 更新成现在的写法。
            ⚠️ 这条红也可能是**扫描器瞎了** —— 顺手跑一下 `扫描器认得出这四类写法` 分辨。
            """)
    }

    @Test func 每条理由都不是空的() {
        let empty = Self.inventory.filter { $0.reason.trimmingCharacters(in: .whitespaces).count < 12 }
        #expect(empty.isEmpty, "这几条没写理由（或短得像敷衍）：\(empty.map(\.snippet))")
    }

    /// **装置自证**：拿**合成源码**验四类写法都认得出，且整行注释不算。
    ///
    /// 不依赖仓库当前内容 ⇒ 「清单是完整的」那条变绿时，能区分
    /// 「真的没有新增」与「扫描器瞎了」。
    @Test func 扫描器认得出这四类写法() {
        let sample = """
            struct Demo: View {
                @State private var busy = false
                private var tap: (() -> Void)? {
                    guard ready else { return nil }
                    return { go() }
                }
                private var alwaysReadyTap: (() -> Void)? {
                    return { go() }
                }
                var body: some View {
                    // .disabled(被注释掉的，不算)
                    Button("a").disabled(busy)
                    Row(onTap: nil)
                    Deco().allowsHitTesting(false)
                }
            }
            """
        let hits = DisabledConditionScanner.scan([(file: "Demo.swift", text: sample)])

        #expect(hits.count == 4, "合成源码里应恰好认出 4 处，实得 \(hits.count)：\(hits.map(\.text))")
        #expect(hits.contains { $0.text == #"Button("a").disabled(busy)"# })
        #expect(hits.contains { $0.text == "Row(onTap: nil)" })
        #expect(hits.contains { $0.text == "Deco().allowsHitTesting(false)" })
        #expect(
            hits.contains { $0.text == "private var tap: (() -> Void)? {" },
            "第四类（点击动作条件返回 nil）没认出来")
        #expect(
            !hits.contains { $0.text.contains("被注释掉") },
            "整行注释被算进来了 —— 本仓库的注释习惯是**引用**被断言的标识符，不去掉会假绿")
        #expect(
            !hits.contains { $0.text == "private var alwaysReadyTap: (() -> Void)? {" },
            "「恒不返回 nil」的点击动作被误报了 —— 第四类必须连体一起看")
    }

    // MARK: - 装置

    private struct Entry {
        let file: String
        let snippet: String
        let reason: String
    }

    private struct Key: Hashable {
        let file: String
        let snippet: String
    }

    private var repoRoot: URL {
        // #filePath = <仓库根>/Tests/SafeOutAppTests/DisabledConditionInventoryTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 枚举 `Sources/` 下全部 `.swift`（**遍历目录**，不写死文件列表 —— 手写的列表会漏）。
    private func realSources() throws -> [(file: String, text: String)] {
        let root = repoRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("枚举不到 \(root.path) —— 装置死了，本 suite 的结论一律作废")
            return []
        }
        let prefix = root.path + "/"
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = "Sources/" + url.path.replacingOccurrences(of: prefix, with: "")
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

/// 扫「让控件点不动」的四类写法。**纯函数**，可以被合成源码单独验（见装置自证那条）。
private enum DisabledConditionScanner {

    struct Hit: CustomStringConvertible {
        let file: String
        let line: Int
        let text: String
        var description: String { "\(file):\(line)  \(text)" }
    }

    static func scan(_ sources: [(file: String, text: String)]) -> [Hit] {
        var hits: [Hit] = []
        for source in sources {
            let lines = source.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 整行注释不算：本仓库的注释习惯是**引用**被讨论的标识符
                //（§8.113.14 的注释里就写着 `allowsAutomaticUpdates`），
                // 不去掉的话「把判据删掉、注释留着」依然会绿。
                guard !trimmed.hasPrefix("//") else { continue }

                let number = index + 1
                if line.contains(".disabled(") {
                    hits.append(Hit(file: source.file, line: number, text: trimmed))
                }
                if line.contains(".allowsHitTesting(false)") {
                    hits.append(Hit(file: source.file, line: number, text: trimmed))
                }
                if line.range(of: #"onTap:\s*nil"#, options: .regularExpression) != nil {
                    hits.append(Hit(file: source.file, line: number, text: trimmed))
                }
                if isTapActionProperty(trimmed) && bodyReturnsNil(lines, from: index) {
                    hits.append(Hit(file: source.file, line: number, text: trimmed))
                }
            }
        }
        return hits
    }

    /// `var X: (() -> Void)? {` —— 点击动作是计算属性。
    private static func isTapActionProperty(_ trimmed: String) -> Bool {
        trimmed.range(of: #"var \w+: \(\(\) -> Void\)\? \{"#, options: .regularExpression) != nil
    }

    /// 计算属性体内有没有 `return nil`（到**同缩进的 `}`** 为止，最多看 60 行）。
    ///
    /// ⚠️ 必须看体：只看声明的话，一个「恒不返回 nil」的点击动作也会被算进来（误报）。
    private static func bodyReturnsNil(_ lines: [String], from index: Int) -> Bool {
        let declarationIndent = indent(of: lines[index])
        for offset in 1...60 where index + offset < lines.count {
            let line = lines[index + offset]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "}" && indent(of: line) <= declarationIndent { return false }
            if line.contains("return nil") { return true }
        }
        return false
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}
