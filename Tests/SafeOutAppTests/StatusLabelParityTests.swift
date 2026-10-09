import Foundation
import Testing

@testable import SafeOutApp

/// 紧凑行（设计稿 `.crow`）的**状态短标签**：修饰类 ↔ 文案键 ↔ 实现，三者互相钉住。
///
/// ## 病（§8.75）
///
/// `06-states.html` 里**唯一**一处未知态紧凑行，挂的文案键是 `compactSafe`（「可安全推出」）：
///
/// ```html
/// <span class="crow__status crow__status--unknown" data-i18n="compactSafe">可安全推出</span>
/// ```
///
/// 而**同一页的正文**（`两条硬规则` 第 1 条）写着：
/// 「**「未知」绝不渲染成「没有占用」。** 未授权 FDA 时若显示「可安全推出」，用户会以为可以拔
/// —— 这是本应用最不能犯的错误。」
///
/// **正文与样本自相矛盾。** 同一时刻 `index.html` 里同一行画的是「占用情况未知」（第三个键），
/// 而实现侧 `DiskRowText.compactStatus(.unknown)` 用的是 `compactUnknown`（「占用未知」）——
/// 同一个状态，**三处三个答案**。
///
/// ## 为什么现有守卫抓不到
///
/// - 接线守卫（`DesignDraftIntegrityTests.界面里写死的中文必须接上语言包`）只看
///   「**有没有**接线」，不看「接的键**对不对**」；
/// - 「定义了但零消费者」那条只看**类**有没有元素用 —— 这里类用对了，**文案**错了；
/// - 症状**肉眼几乎看不见**：灰色小字「可安全推出」与绿色「可安全推出」只差颜色，
///   在 6 行列表里很容易被当成「就是灰的那一行」。
///
/// ## 三条判据（改这里之前先读）
///
/// 1. **同一个修饰类只能有一个文案键**，且**不同状态不得共用**同一个键（单射）——
///    这是「状态 ↔ 文案」最基本的对应关系，也是本轮的病**唯一**能被机器抓住的形状。
/// 2. `ds.css` 里定义的**每个** `.crow__status*` 变体都必须有样本 ——
///    不许再出现 §8.52.4 那种「有定义、零消费者」（`.meter--high` 的老病）。
/// 3. 设计稿用的键必须与实现 `DiskRowText.compactStatus(_:)` **同源**。
///
/// ⚠️ **本轮只守 `.crow__status` 一族**。`.mrow__occ`（菜单栏面板行）是**另一族**：
/// 它只定义了 `--safe`，**没有** `--unknown`，而实现 `MenuBarDiskRow.statusLine` 的
/// `.unknown` 用的是 `unknownEvidenceTitle` —— 「面板行没有未知态样本」是**另一笔账**，
/// 记在 §8.75.6，**没假装守住**。
struct StatusLabelParityTests {

    // MARK: - 守卫

    /// **同一个修饰类只能有一套文案，且不同状态不得共用同一个键。**
    ///
    /// 把 `06-states.html` 那处改回 `compactSafe`（或反过来把 `--safe` 改成 `compactUnknown`），
    /// 这条立刻红 —— 两个方向都红，因为判的是「**两个集合是否相交**」，不是「等于某个字面值」。
    @Test func 紧凑行状态修饰类与文案键必须一一对应() throws {
        let all = try samples()
        // 负向锚：扫不到东西时，下面「没有冲突」只是「没扫到任何东西」。
        #expect(all.count >= 8, "只扫到 \(all.count) 个紧凑行状态标签 —— 解析口径失效（假绿）")

        var byVariant: [String: Set<String>] = [:]
        var noKey: [String] = []
        for s in all {
            guard let key = s.key else {
                noKey.append("\(s.page) 的 `\(s.variant)`")
                continue
            }
            byVariant[s.variant, default: []].insert(key)
        }
        #expect(
            noKey.isEmpty,
            """
            这些紧凑行状态标签**没有任何文案键**（自己或子元素上都没有 `data-i18n`）：
            \(noKey.joined(separator: "、"))
            症状：**切到英文时那一行还是中文** —— 不报错、也不算漏翻（键压根没被引用）。
            """)

        // ① 同一个变体下，所有样本的**文案抹掉数字后必须完全一致**。
        //
        // 为什么是「抹掉数字」而不是「只有一个键」：被占用态的文案是 `compactBusyFormat`
        // （`%d 个程序占用`）那种**模板** —— 样本按数量不同用不同的键
        // （`ds.occ.appsShort1` / `ds.occ.appsShort2`），那是**合法的**，
        // 一刀切成「一个变体一个键」会误伤它。
        // 而「未知态挂了一句『可安全推出』」抹掉数字后仍然和「占用未知」不同 ⇒ 照样红。
        // ⇒ 这条规则**不需要例外表**：它自己就把「参数化」与「串了状态」分开了。
        let pack = try zhPack()
        var byVariantText: [String: Set<String>] = [:]
        var unresolved: Set<String> = []
        for s in all {
            guard let key = s.key else { continue }
            guard let value = pack[key] else {
                unresolved.insert(key)
                continue
            }
            byVariantText[s.variant, default: []].insert(Self.strippingDigits(Self.plainText(value)))
        }
        #expect(
            unresolved.isEmpty,
            "这些键在语言包里找不到：\(unresolved.sorted()) —— 语言包没读全，下面的结论是空的")
        let inconsistent = byVariantText.filter { $0.value.count > 1 }
        #expect(
            inconsistent.isEmpty,
            """
            同一个状态修饰类下出现了**语义不同的文案**：
            \(inconsistent.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value.sorted())" }
                .joined(separator: "、"))
            同一个类名 = 同一个视觉状态，只能有一套文案（数量词除外 —— 见判据里的「抹掉数字」）。
            两套就是「同一事实写两处」（§8.43 的病），而两处会各自漂移、谁也不会报错。
            """)

        // ② 不同状态不得**共用同一个键**（这是 §8.75 那个 bug 最直接的形状）。
        var byKey: [String: Set<String>] = [:]
        for (variant, keys) in byVariant {
            for k in keys { byKey[k, default: []].insert(variant) }
        }
        let shared = byKey.filter { $0.value.count > 1 }
        #expect(
            shared.isEmpty,
            """
            不同的状态**共用了同一个文案键**：
            \(shared.sorted { $0.key < $1.key }.map { "`\($0.key)` ← \($0.value.sorted())" }
                .joined(separator: "、"))
            这正是 §8.75 那个 bug 的形状：`06-states.html` 里唯一一处未知态紧凑行挂着
            `compactSafe`（「可安全推出」），而**同一页正文**写着
            「**「未知」绝不渲染成「没有占用」。** 未授权 FDA 时若显示「可安全推出」，
            用户会以为可以拔 —— 这是本应用最不能犯的错误。」
            正文与样本自相矛盾。改法：未知态用 `compactUnknown`（实现 `compactStatus(.unknown)` 用的就是它）。
            """)

        print(
            "  [状态标签] 共 \(all.count) 个 ｜ "
                + byVariant.sorted { $0.key < $1.key }
                .map { "\($0.key) → \($0.value.sorted().joined(separator: "/"))" }
                .joined(separator: " ｜ "))
    }

    /// `ds.css` 里定义的**每个** `.crow__status*` 变体都必须有样本。
    ///
    /// 与上一条互补：上一条管「样本用的键对不对」，这条管「**这一态有没有画过**」。
    /// 删掉未知态那一行，上一条**照样绿**（空集合谈不上冲突），但这一条会红 ——
    /// 那正是 §8.52.4 的老病（`.meter--high` 有定义、零消费者）。
    @Test func 设计稿里定义的每个紧凑行状态都必须有样本() throws {
        let variants = try statusVariants()
        // 负向锚：类名解析不出来时，「一个都不缺」是空话。
        #expect(variants.count >= 3, "只从 `ds.css` 里解析出 \(variants.count) 个 `.crow__status*` 变体 —— 解析口径失效")

        let present = Set(try samples().map(\.variant))
        let missing = variants.filter { !present.contains($0) }
        #expect(
            missing.isEmpty,
            """
            这些状态在 `ds.css` 里有定义，但设计稿里**一个元素都没用**：
            \(missing.joined(separator: "、"))
            实现侧却画得出来 ⇒ 设计稿对这一态**没有可视依据**，
            下一轮核对「实现画得对不对」时只能靠猜（§8.52.4 的 `.meter--high` 就是这么挂了一整轮）。
            """)

        print("  [状态标签] `ds.css` 定义 \(variants.count) 个变体 ｜ 都有样本：\(variants.joined(separator: "、"))")
    }

    /// 设计稿用的键必须与实现 `DiskRowText.compactStatus(_:)` **同源**。
    ///
    /// 上两条只在**设计稿内部**自洽；这条把两边接上 —— 「同一事实写两处」的正解是
    /// **两边相等**，不是各自等于某个字面值（§8.71 的口径）。
    ///
    /// ⚠️ **必须只截 `compactStatus` 这一个函数**：`MenuBarDiskRow.statusLine` 是**另一支**
    /// （它 `.unknown` 用的是 `unknownEvidenceTitle`、`.safe` 用 `compactSafe`）。
    /// 扫错函数会照样扫出两个键、**不会报错**，而守卫就指到错的地方去了。
    @Test func 紧凑行状态文案必须与实现同源() throws {
        let impl = try implementationKeys()
        #expect(
            impl.count == 2,
            """
            只从 `DiskRowText.compactStatus(_:)` 里解析出 \(impl.count) 个文案键（\(impl)），应该有 2 个。
            0 个 = 函数签名或写法变了，解析口径失效（下面「两边相等」就是空的）；
            1 个 = 两个 case 解析成了同一个 —— 守卫会指到错的地方。
            """)
        // 负向锚：两个状态解析成同一个键 ⇒ 下面的比对没有分辨力。
        #expect(
            impl["safe"] != impl["unknown"],
            "实现里 `.safe` 与 `.unknown` 解析出了同一个键（\(impl)）—— 解析口径失效")
        // ⚠️ 负向锚：紧凑行**不得直接复用**菜单栏面板行的证据标题键。
        //
        // `unknownEvidenceTitle`（「占用情况未知」）是 `MenuBarDiskRow.statusLine`
        // 那一支用的 —— 面板行有整行宽度，可以写长句；紧凑行（`.crow`）只有一列，
        // 文案必须短（`compactUnknown`「占用未知」）。两者共用同一个键，
        // 必然有一边被迫用不适合自己长度的句子。
        //
        // 这条**同时**拦住另一件事：`compactStatusBody` 若截错成了 `statusLine`
        // （两个函数都在 `DiskRow.swift` 里，且都能扫出 `.safe`/`.unknown` 两个键），
        // `.unknown` 解析出来就正是这个键 —— 截错了照样「解析出 2 个」，只有这里能拦下。
        // ⚠️ 所以这条红了有两种可能：**实现真的复用了**，或**解析截错了函数**。
        // 看 `impl["safe"]`：若它是 `compactSafe`，说明函数截对了，是前者。
        #expect(
            impl["unknown"] != "unknownEvidenceTitle",
            """
            解析到的 `.unknown` 键是 `unknownEvidenceTitle`（「占用情况未知」）——
            那是 **`MenuBarDiskRow.statusLine`**（菜单栏面板行）用的长句键。
            紧凑行只有一列，文案必须短（`compactUnknown`「占用未知」）：两个组件不得共用同一个键。
            若 `impl["safe"]` 也不是 `compactSafe`，则是 `compactStatusBody` 截错了函数
            （本 suite 守的是 `.crow` 紧凑行，改 `compactStatusBody` 的起点）。
            """)

        var byVariant: [String: Set<String>] = [:]
        for s in try samples() {
            if let key = s.key { byVariant[s.variant, default: []].insert(key) }
        }
        for (variant, state) in [("crow__status--safe", "safe"), ("crow__status--unknown", "unknown")] {
            let want = try #require(impl[state], "实现 `compactStatus` 里没解析到 `.\(state)` 的文案键")
            let got = try #require(byVariant[variant], "设计稿里没有 `\(variant)` 的样本 —— 无从比对")
            #expect(
                got == [want],
                """
                设计稿 `\(variant)` 用的键是 \(got.sorted())，而实现 `compactStatus(.\(state))` 用的是 `\(want)`。
                两边必须**相等**（§8.71 的口径）—— 不相等就是「同一事实写两处」，
                而症状是**切到某种语言才会看见**：设计稿画的和实现做的不一样。
                """)
            print("  [状态标签] \(variant) ↔ 实现 .\(state) → `\(want)`")
        }
    }

    // MARK: - 解析

    /// 一个紧凑行状态标签样本。
    private struct Sample {
        let page: String
        /// 类名里那个词：`crow__status` / `crow__status--safe` / `crow__status--unknown`
        let variant: String
        /// 元素自己**或它内部**第一个 `data-i18n` 的键。
        let key: String?
    }

    private static let classAttr = try? NSRegularExpression(pattern: #"class="([^"]*)""#)
    private static let dataI18n = try? NSRegularExpression(pattern: #"data-i18n="([^"]*)""#)
    /// `.crow__status` 以及它的变体。⚠️ 只取**类名**，不取整条选择器：
    /// `.crow__status svg { … }` 里也含这个词，但它定义的不是一个「状态」。
    private static let statusClass = try? NSRegularExpression(pattern: #"\.crow__status(--[A-Za-z][\w-]*)?"#)
    /// 语言包 `i18n.js` 里的 `"键": "值"` 对。
    private static let jsonPair = try? NSRegularExpression(pattern: #""([^"]+)":\s*"([^"]*)""#)

    /// 设计稿语言包的 `zh-Hans` 列 —— 读**生成物** `assets/i18n.js`
    /// （与 `DesignDraftIntegrityTests.loadLanguagePack()` 同一个来源；它是生成物，但必须入库）。
    ///
    /// ⚠️ 别去读 `i18n-extra.json`：它的值是 `[zh-Hans, en, zh-Hant]` **三元数组**，
    /// 按「取 zh-Hans」解析会整批漏掉 47 个 `ds.*` 键 —— 而本 suite 要判的
    /// `ds.occ.appsShort1/2` 正在其中（漏掉的话它们会走 `unresolved` 那条，报「语言包没读全」）。
    ///
    /// ⚠️ 只认 `"键": "值"` 这种**单行**写法、不做反转义 —— 本语言包的值里没有转义引号
    /// （实测 0 处），够用。不够用时这里会**解析不出来**（`unresolved` 会报），
    /// 不会静默给一个错的文案。
    private func zhPack() throws -> [String: String] {
        let js = try read(
            repoRoot.appendingPathComponent("Design/ui/v2/assets/i18n.js"))
        guard let start = js.range(of: #""zh-Hans": {"#)?.upperBound,
            let end = js[start...].range(of: "\n  },")?.lowerBound
        else { return [:] }
        let block = String(js[start..<end])
        guard let re = Self.jsonPair else { return [:] }
        var out: [String: String] = [:]
        for m in re.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            guard let k = Range(m.range(at: 1), in: block), let v = Range(m.range(at: 2), in: block)
            else { continue }
            out[String(block[k])] = String(block[v])
        }
        return out
    }

    /// 去标签 + 压平空白（与 `DesignDraftIntegrityTests.plainText` 同口径）。
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// 抹掉 ASCII 数字 —— 「参数化的文案」与「串了状态的文案」靠这一步分开。
    private static func strippingDigits(_ s: String) -> String {
        String(s.filter { !($0 >= "0" && $0 <= "9") })
    }

    /// 扫出所有紧凑行状态标签。
    ///
    /// ⚠️ 文案键可能在**子元素**上：安全态是
    /// `<span class="crow__status crow__status--safe"><i data-i="check"></i><span data-i18n="compactSafe">…</span></span>`
    /// —— §8.69.5 拍板的「图标拆兄弟节点」，所以不能只看元素自己的属性。
    ///
    /// ⚠️ 判「这是不是一个状态标签」用**类名分词后取整词**，不用前缀：
    /// `crow__status` 与 `crow__status--safe` 是同一个词的两种取值，而
    /// `.crow__grow` / `.crow__btn` 里根本没有 `crow__status` 这个词。
    private func samples() throws -> [Sample] {
        guard let attrRe = Self.classAttr, let keyRe = Self.dataI18n else { return [] }
        var out: [Sample] = []
        for url in try htmlFiles() {
            let html = try read(url)
            let page = url.lastPathComponent
            for m in attrRe.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard
                    let full = Range(m.range, in: html),
                    let valueRange = Range(m.range(at: 1), in: html)
                else { continue }
                let tokens = html[valueRange]
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                // ⚠️ 取**最长**的那个：`class="crow__status crow__status--safe"` 里
                // `crow__status` 也命中判据，而它是**排在前面的** ——
                // 首版用 `first(where:)` ⇒ 9 个样本全被归到基础态（`--safe`/`--unknown` 两个变体
                // 一个都扫不到，而失败信息长得像「设计稿没画这一态」）。
                let statusTokens = tokens.filter {
                    $0 == "crow__status" || $0.hasPrefix("crow__status--")
                }
                guard let variant = statusTokens.max(by: { $0.count < $1.count }) else { continue }

                let tagStart = html[..<full.lowerBound].lastIndex(of: "<") ?? full.lowerBound
                let segment = Self.elementSegment(in: html, from: tagStart)
                let key =
                    keyRe
                    .firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment))
                    .flatMap { Range($0.range(at: 1), in: segment).map { String(segment[$0]) } }
                out.append(Sample(page: page, variant: variant, key: key))
            }
        }
        return out
    }

    /// 从 `<` 处开始，按**同名标签**配平，返回这个元素的整段（含标签本身）。
    ///
    /// ⚠️ 只支持本设计稿这种手写 HTML：没有注释、`class` 里不会出现 `>`。
    /// 换 `XMLParser` 反而更糟 —— **HTML 不是合法 XML**（`<br>` 不闭合）。
    private static func elementSegment(in html: String, from start: String.Index) -> String {
        guard let gt = html[start...].firstIndex(of: ">") else { return String(html[start...]) }
        let head = String(html[html.index(after: start)..<gt])
        let name = head.split(separator: " ").first.map { $0.lowercased() } ?? ""
        guard !head.hasSuffix("/"), !name.isEmpty, !name.hasPrefix("/") else {
            return String(html[start...gt])  // 自闭合 / 闭合标签：整段就是它自己
        }
        let open = "<" + name
        let close = "</" + name
        var depth = 1
        var i = html.index(after: gt)
        while i < html.endIndex {
            guard let lt = html[i...].firstIndex(of: "<") else { break }
            if html[lt...].hasPrefix(close) {
                depth -= 1
                if depth == 0, let end = html[lt...].firstIndex(of: ">") {
                    return String(html[start...end])
                }
            } else if html[lt...].hasPrefix(open) {
                // 只认 `<span` 后面紧跟空格 / `>` / `/` 的那种 —— 否则 `spanned` 会被算成开标签
                let after = html.index(lt, offsetBy: open.count)
                if after < html.endIndex, html[after] == " " || html[after] == ">" || html[after] == "/" {
                    depth += 1
                }
            }
            guard let end = html[lt...].firstIndex(of: ">") else { break }
            i = html.index(after: end)
        }
        return String(html[start...gt])
    }

    /// `ds.css` 里定义过的 `.crow__status*` 变体（去重、排序）。
    private func statusVariants() throws -> [String] {
        guard let re = Self.statusClass else { return [] }
        let css = try read(
            repoRoot.appendingPathComponent("Design/ui/v2/assets/ds.css"))
        var out = Set<String>()
        for m in re.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            guard let r = Range(m.range, in: css) else { continue }
            out.insert(String(css[r]).replacingOccurrences(of: ".", with: ""))
        }
        return out.sorted()
    }

    /// 实现侧 `DiskRowText.compactStatus(_:)` 里 `.safe` / `.unknown` 各自用的文案键。
    private func implementationKeys() throws -> [String: String] {
        let src = try read(repoRoot.appendingPathComponent("Sources/Views/DiskRow.swift"))
        guard let body = Self.compactStatusBody(in: src) else { return [:] }
        var out: [String: String] = [:]
        for state in ["safe", "unknown"] {
            guard
                let re = try? NSRegularExpression(
                    pattern: "case \\.\(state):[\\s\\S]*?return L10n\\.tr\\(\\.(\\w+)\\)")
            else { continue }
            if let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                let r = Range(m.range(at: 1), in: body)
            {
                out[state] = String(body[r])
            }
        }
        return out
    }

    /// 从 `static func compactStatus(` 起到它配平的那个 `}`。
    private static func compactStatusBody(in src: String) -> String? {
        guard let start = src.range(of: "static func compactStatus(")?.lowerBound,
            let braceStart = src[start...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var i = braceStart
        while i < src.endIndex {
            if src[i] == "{" {
                depth += 1
            } else if src[i] == "}" {
                depth -= 1
                if depth == 0 { return String(src[start...i]) }
            }
            i = src.index(after: i)
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

    /// 设计稿目录下**所有** HTML（含总览页 `index.html`）。
    ///
    /// ⚠️ 与 `MeterThresholdParityTests.screenFiles()` 的差别是**故意的**：
    /// 那边只扫 `screens/`（总览页里嵌的是主窗预览的副本，重复计样本会搅乱区间），
    /// 这边必须扫全 —— 本轮那个 bug 就藏在总览页与 `06-states.html` 的**不一致**里。
    ///
    /// ⚠️ 跳过 `_` 开头的文件：无头 Chrome 探针（`_probe_*.html`）曾残留在设计稿目录里，
    /// 被别的守卫当成真页面扫过（§8.47.8）。
    private func htmlFiles() throws -> [URL] {
        let root = repoRoot.appendingPathComponent("Design/ui/v2")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "html" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.path < $1.path }
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
