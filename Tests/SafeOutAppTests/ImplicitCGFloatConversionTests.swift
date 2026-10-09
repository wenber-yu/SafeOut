import Foundation
import Testing

/// 扫 `Tests/` + `Sources/` 里「**靠隐式转换把 `CGFloat` 塞进 `Double` 目的地**」的写法。
///
/// ## 为什么需要这一条守卫（§8.130）
///
/// 2026-09-22 CI run `35761198327` **红**在 `OffscreenRender.swift` 的一行元组返回上：
/// `return (c.redComponent, c.greenComponent, c.blueComponent)`，目的地是
/// `(Double, Double, Double)?`。**同一份源码，本地门槛 11/11 全绿**。
///
/// 差异**只在编译器版本**：本地 Xcode 27 / **Swift 6.4** 接受「元组字面量内部的
/// `CGFloat` → `Double` 隐式转换」，CI 的 Xcode 26.6 / **Swift 6.3.3** 不接受。
/// 同一个包、同一个 `swiftLanguageModes: [.v6]`、同一个 arm64
/// ⇒ 不是语言模式、不是架构、不是 SDK，就是编译器版本。
///
/// ⚠️ **本地复现不出来**：翻遍 `swiftc -help-hidden` 与 `swiftc -frontend -help-hidden`，
/// **没有任何旗标**能关掉这个隐式转换（试过 `-disable-implicit-cgfloat-conversion` /
/// `-disable-implicit-conversions`，两个都是 `unknown argument`）。
/// ⇒ 「先跑一遍本地门槛看看」在这类改动上**不成立**，只能靠源码形状兜住。
///
/// ## 口径
///
/// 违规 = **同一行**同时满足四条：
///
/// 1. 是**字面量聚合**：`return (` / `return [` / `= [`；
/// 2. 含**颜色分量访问器**（`*Component`，AppKit 上全是 `CGFloat`）；
/// 3. **没有**显式转换（`Double(` / `CGFloat(` / `Float(`）；
/// 4. **目的地含 `Double`** —— 取本行的类型标注，或往上找最近一条带 `->` 的声明行。
///
/// 第 4 条是**必须**的，不是保险：`GlassSurfaceTests.rgba` 的
/// `return (c.redComponent, …)` 目的地是 `(r: CGFloat, …)`，本来就不需要转换，
/// 报它就是噪音（噪音会让人把守卫关掉，那才是真的损失）。
///
/// ## 已知局限（故意不修，当前实测 0 例）
///
/// - 只认**单行**字面量。跨行的 `return (` 换行后再写分量，本扫描器看不见。
/// - 只认颜色分量这一个 `CGFloat` 来源。`rect.minX` / `.width` / 自定义 `CGFloat` 变量
///   同样可能落进元组/数组字面量，但正则判不出它们的类型。
/// - **实参位置不在口径内**（`f(c.redComponent)` 而 `f` 收 `Double`）：那是 SE-0307
///   （Swift 5.5 起）就支持的位置，而 6.4 放宽的是「**字面量内部**」。实测 CI 的报错清单里
///   也没有实参那一行。
///   ⚠️ 但**本仓的约定是一律显式写 `Double(...)`** —— 不为分辨「哪个位置哪版允许」，
///   而是让这个问题不存在。所以这条守卫兜的是「**字面量内部**」这一半，
///   另一半靠约定 + CI。
///
/// ## ⚠️ 这不是「本地 = CI」的保证
///
/// 它只钉住**这一个已实测的** 6.4 宽松点。别的「新编译器才接受」的写法（新语法、
/// 新的隐式转换、新的类型推断）仍然只能靠 **CI** 兜 —— 本守卫**不**改变
/// 「推后必须看 CI」这条规则的地位，也不该被当成它的替代品。
struct ImplicitCGFloatConversionTests {

    // MARK: - 扫描器（纯函数，便于用合成样本做对照）

    /// 颜色分量访问器族 —— AppKit 上全是 `CGFloat`。
    private static let componentAccessor =
        #"\.(?:red|green|blue|alpha|white|hue|saturation|brightness)Component\b"#

    /// 显式转换 —— 出现任一即视为「作者已经表过态」，不再报。
    private static let explicitConversion = #"\b(?:Double|CGFloat|Float)\s*\("#

    /// 字面量聚合的起点：`return (` / `return [` / `= [`。
    private static let literalStart = #"(?:\breturn\s*[\(\[]|=\s*\[)"#

    /// 目的地里含 `Double` 的类型写法（元组或数组，可带首元素标签）。
    private static let doubleDestination =
        #"(?:->\s*\(\s*(?:[A-Za-z_]+\s*:\s*)?Double|->\s*\[\s*Double|:\s*\(\s*(?:[A-Za-z_]+\s*:\s*)?Double|:\s*\[\s*Double)"#

    /// 一行里有没有匹配上（用 ICU 正则，支持 `(?:` 非捕获组）。
    static func matches(_ pattern: String, _ line: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// 去掉**整行**注释（行首空白后以 `//` 开头）—— 与 `MainActorBlockingTests` 同一口径。
    ///
    /// ⚠️ **必须先剥注释**：本文件的说明里就写着 `c.redComponent`，
    /// 不剥的话**注释会把自己判成违规**（「文档越全、越容易误报」的经典形状）。
    /// 剥完的行**会少**，所以下面一律用同一个数组的下标，不跨数组对位。
    static func codeOnly(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// 从 `index` 往上找**最近的**含 `->` 的行（含本行）—— 目的地判据（口径第 4 条）。
    ///
    /// ⚠️ 与 `MainActorBlockingTests` 同款**粗口径**：不做括号配平、不解析类型。
    /// 实测本仓当前 0 例误判。
    static func nearestReturnTypeLine(lines: [String], upTo index: Int) -> String? {
        for line in lines[...index].reversed() where line.contains("->") {
            return line
        }
        return nil
    }

    /// 一个文件里**真正算违规**的行（已套用口径第 4 条）。
    static func violations(inFile code: String) -> [String] {
        let lines = codeOnly(code)
        var hits: [String] = []
        for (index, line) in lines.enumerated() {
            guard matches(literalStart, line), matches(componentAccessor, line),
                !matches(explicitConversion, line)
            else { continue }
            let sameLineSaysDouble = matches(doubleDestination, line)
            let decl = nearestReturnTypeLine(lines: lines, upTo: index)
            let declSaysDouble = decl.map { matches(doubleDestination, $0) } ?? false
            guard sameLineSaysDouble || declSaysDouble else { continue }
            hits.append(line.trimmingCharacters(in: .whitespaces))
        }
        return hits
    }

    /// 只数「含颜色分量的行」—— 给**装置自证**用。
    ///
    /// 缺了它，「0 违规」有两种可能：真的没有，或者**分量正则根本失效了**。
    /// 两种情况下本守卫的输出**逐字相同**（§8.96.4）。
    static func componentLineCount(inFile code: String) -> Int {
        codeOnly(code).count { matches(componentAccessor, $0) }
    }

    // MARK: - 守卫

    @Test("隐式转换不许把CGFloat塞进Double目的地")
    func 隐式转换不许把CGFloat塞进Double目的地() throws {
        // ① 装置自证：**双向**阳性对照。只报「没找到」的装置与「瞎了」的装置输出逐字相同。
        #expect(
            Self.matches(Self.literalStart, "        return (c.redComponent, c.greenComponent)"),
            "阳性对照：`return (` 必须被认成字面量聚合")
        #expect(
            Self.matches(Self.literalStart, "        let channels = [c.redComponent, c.greenComponent]"),
            "阳性对照：`= [` 必须被认成字面量聚合")
        #expect(
            Self.matches(Self.literalStart, "        if c.redComponent < 0.75 { n += 1 }") == false,
            "阴性对照：比较语句不是字面量聚合，不许认")
        #expect(
            Self.matches(Self.componentAccessor, "return (c.redComponent, c.greenComponent)"),
            "阳性对照：`c.redComponent` 必须被认成颜色分量")
        #expect(
            Self.matches(Self.componentAccessor, "let x = color.components") == false,
            "阴性对照：`components`（不带 `*Component` 后缀）不许认 —— 它不是颜色分量")
        #expect(
            Self.matches(Self.doubleDestination, "    static func rgb(…) -> (Double, Double, Double)? {"),
            "阳性对照：`-> (Double, …)` 必须被认成 Double 目的地")
        #expect(
            Self.matches(
                Self.doubleDestination,
                "    private func rgba(_ c: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat) {") == false,
            "阴性对照：`-> (r: CGFloat, …)` **不是** Double 目的地 —— 认了就会把 `GlassSurfaceTests` 误报成违规")

        // ② 端到端对照：本仓真实出现过的那一行（**就是 CI 红掉的那一行**）必须被抓到。
        #expect(
            Self.violations(
                inFile: """
                    static func rgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (Double, Double, Double)? {
                        guard let c = rep.colorAt(x: x, y: y) else { return nil }
                        return (c.redComponent, c.greenComponent, c.blueComponent)
                    }
                    """) == ["return (c.redComponent, c.greenComponent, c.blueComponent)"],
            "阳性对照：CI 红掉的那一行必须被抓到 —— 抓不到说明本守卫对本次事故无效")

        // ③ 四条阴性对照：三种「不该报」的写法各来一条，外加一条同款但已显式转换的。
        #expect(
            Self.violations(
                inFile: """
                    private func rgba(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
                        return (c.redComponent, c.greenComponent, c.blueComponent)
                    }
                    """
            ).isEmpty,
            "阴性对照：目的地是 `CGFloat` 元组，本来就不需要转换 —— 报了就是噪音")
        #expect(
            Self.violations(
                inFile: """
                    static func rgb(…) -> (Double, Double, Double)? {
                        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                    }
                    """
            ).isEmpty,
            "阴性对照：已经显式转换了，不许再报")
        #expect(
            Self.violations(
                inFile: """
                    func colorfulPixels(…) -> Int {
                        let channels = [c.redComponent, c.greenComponent, c.blueComponent]
                        return Int((channels.max() ?? 0) * 255)
                    }
                    """
            ).isEmpty,
            "阴性对照：无标注的数组字面量推断成 `[CGFloat]`，没有 Double 目的地 —— 不许报")
        #expect(
            Self.violations(
                inFile: """
                    func rgb(…) -> (Double, Double, Double)? {
                        if c.redComponent < 0.75 || c.greenComponent < 0.75 { return nil }
                        return (0, 0, 0)
                    }
                    """
            ).isEmpty,
            "阴性对照：只有比较语句，没有字面量聚合 —— 不许报")
        #expect(
            Self.violations(
                inFile: """
                    func xs(…) -> [Double] {
                        let out: [Double] = [c.redComponent, c.greenComponent]
                        return out
                    }
                    """
            ).count == 1,
            "阳性对照：带 `: [Double]` 标注的数组字面量也必须被抓到（同一条变形轴的另一半）")

        // ④ 真扫 `Tests/` + `Sources/` 全部 `.swift`。
        let repoRoot =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SafeOutAppTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // 仓库根
        // ⚠️ **跳过本文件**：上面那些合成样本的字符串里就写着违规行，
        // 不跳过的话守卫会**自己把自己判红**（`MainActorBlockingTests` 同款处理）。
        let selfName = URL(fileURLWithPath: #filePath).lastPathComponent
        var scanned = 0
        var componentLines = 0
        var violations: [String] = []

        for dir in ["Tests", "Sources"] {
            let root = repoRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else {
                Issue.record("枚举不到 \(root.path) —— 这一半的「0 违规」不可信")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard url.lastPathComponent != selfName else { continue }
                scanned += 1
                let code = try String(contentsOf: url, encoding: .utf8)
                componentLines += Self.componentLineCount(inFile: code)
                let hits = Self.violations(inFile: code)
                if !hits.isEmpty {
                    violations.append("\(url.lastPathComponent)：\(hits.joined(separator: " ／ "))")
                }
            }
        }

        // ⑤ 装置自证：真扫到了足够多的文件、也真认出了足够多的分量行。
        //    否则「0 违规」可能只是「一个都没扫」或「正则一个都没匹配上」——
        //    这几种情况在断言层面**完全一样**。
        #expect(
            scanned > 80,
            "只扫到 \(scanned) 个文件 —— 枚举很可能没生效，这次的「0 违规」不可信（2026-09-22 实测 97 个）")
        #expect(
            componentLines > 20,
            "只认出 \(componentLines) 行含颜色分量 —— 分量正则很可能失效了，结果不可信（2026-09-22 实测 33 行）")

        #expect(
            violations.isEmpty,
            """
            这些地方把 `CGFloat` 靠**隐式转换**塞进了 `Double` 目的地：\(violations.joined(separator: "；"))。
            Swift 6.4 接受、**CI 的 Swift 6.3.3 不接受** ⇒ 本地门槛全绿、CI 红（§8.130，2026-09-22 实测）。
            ⚠️ 本地**没有旗标**能复现严格行为，所以「跑一遍本地看看」这条路不成立 —— 只能靠这里兜。
            修法：显式写 `Double(...)`（`NSColor.redComponent` 是 `CGFloat`）。
            """
        )
    }
}
