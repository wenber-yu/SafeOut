import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SafeOutApp

/// 文案里的 `**加粗**` 必须**真的渲染成粗体**，而不是把裸星号画在界面上（§8.78）。
///
/// ## 这一类为什么是静默的
///
/// 设计稿侧的文案值允许带 `**`：`Tools/build_i18n.py` 的 `md_bold` 把成对的 `**X**`
/// 换成 `<b>X</b>`，回填后由 `ds.js` 当 HTML 渲染 ⇒ **设计稿里显示粗体**。
/// 那份转换器的注释甚至写了「直接回填会显示成裸星号」。
///
/// ⚠️ 但 app 侧 **`Text(String)` 不解析 Markdown**（只有 `LocalizedStringKey` 才解析）。
/// 于是「值里带 `**`、渲染时直接 `Text(string)`」在 app 里**原样画出星号** ——
/// 而**没有任何东西会报错**：编译过、测试绿、设计稿那侧还是对的。
///
/// 实测（``渲染器必须真的把成对星号吃掉()`` 量的是渲染出来的理想宽度）：
/// `Text(原样)` **289.0pt** vs `Text(去掉 `**`)` **265.0pt** —— 星号真的占了宽度。
///
/// ## 本轮修的病
///
/// `NoticeBanner.message` 的类型是 `String`、内部 `Text(message)` ⇒ 渲染是**原样**的。
/// §8.69 给 `fdaBannerLead` 的值加上了 `**`（因为设计稿那句是粗体），
/// 于是**主窗口那条 FDA 横幅**（未授权时每个新用户都会看到）显示成
/// `需要「完全磁盘访问」才能看到**是谁占用了磁盘**`。
/// 修法：`message` 改成 `Text`，由**调用方**决定要不要走 ``MarkdownCopy/text(_:)``。
///
/// ⚠️ 整条 suite 必须 `@MainActor`：`NSHostingController` 是 main-actor 隔离的，
/// 非隔离上下文里传 view 进去会报 `SendingRisksDataRace`（实测编译红）。
/// 与 `ProcessChipLayoutTests` 同一取舍。
@MainActor
struct MarkdownCopyTests {

    // MARK: 路径

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    private var catalogURL: URL {
        repoRoot.appendingPathComponent("Sources/Localization/Localizable.xcstrings")
    }
    private var sourcesRoot: URL { repoRoot.appendingPathComponent("Sources") }

    /// 渲染出来的**理想宽度**（走 SwiftUI 布局，不是读常量）。
    private func idealWidth(_ view: some View) -> CGFloat {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.width
    }

    // MARK: 守卫

    /// **口径锚**：渲染器真的把成对星号吃掉了 —— 否则下面那条守卫的判据是空的。
    ///
    /// ⚠️ **别拿「粗体是否更宽」当判据**：这段文案几乎全是 CJK 全角字符，
    /// **粗体不改变字宽**（实测解析后 265.0 == 去掉星号后 265.0）。
    /// 能分辨的只有「星号在不在」——那正好就是这条守卫要问的问题。
    @Test func 渲染器必须真的把成对星号吃掉() {
        let raw = "需要「完全磁盘访问」才能看到**是谁占用了磁盘**"
        let parsed = idealWidth(MarkdownCopy.text(raw))
        let verbatim = idealWidth(Text(raw))

        #expect(
            verbatim - parsed > 10,
            """
            原样渲染只比解析后宽 \(verbatim - parsed)pt —— **量测口径坏了**，结论作废。
            实测应差约 24pt（4 个星号 × 约 6pt）。
            """)
        #expect(
            parsed < verbatim,
            "`MarkdownCopy.text` 没有解析 markdown —— 星号还占着宽度，界面上会画出裸星号")
    }

    /// **带加粗标记的值，`**` 必须成对**（§8.113：替掉一条守不了的路径）。
    ///
    /// 这一条**替换**了原本想写的「不成对标记的兜底要退回原样」。那条写不出来 ——
    /// 实测（2026-09-21）12 种畸形输入（落单 `**` / `*` / 反引号 / `___x` / `[](` /
    /// `<script>` / 200 个连续星号 …）**全部解析成功**，
    /// `try? AttributedString(markdown:)` 一次都没返回 nil ⇒
    /// `MarkdownCopy.text` 里那句 `return Text(raw)` 的兜底**不可达**。
    /// 变异证实了这一点：把兜底改成 `Text("")`，那条测试**照样绿** —— 它守的是条没人走的路。
    ///
    /// ⇒ 但落单的 `**` 仍然是个真问题，只是**不在兜底那一侧**：
    /// 解析**成功**、星号被当字面量保留 ⇒ 界面上**原样画出裸星号**，
    /// 与「忘了包 `MarkdownCopy.text`」的结果**逐字相同**（§8.78 那个 bug 的形状）。
    /// 所以真正该守的是**值本身**：星号必须成对。
    ///
    /// **判据**：先剥掉所有成对的 `**…**`，剩下的若还有 `**` ⇒ 落单。
    /// （只数奇偶不够：`**a** 与 **b` 的 `**` 总数是 3，但真正的问题是最后那个落单的。）
    @Test func 带加粗标记的文案值里星号必须成对() throws {
        let marked = try markedValues()
        #expect(
            marked.count >= 2,
            "只扫到 \(marked.count) 个带 `**` 的值 —— 扫描口径坏了，下面的「无落单」不可信")

        var bad: [String] = []
        for item in marked {
            var rest = item.value
            rest = rest.replacingOccurrences(
                of: #"\*\*[^*]+\*\*"#, with: "", options: .regularExpression)
            if rest.contains("**") {
                bad.append("\(item.key)（\(item.language)）：\(item.value)")
            }
        }

        #expect(
            bad.isEmpty,
            """
            这些文案值里有**落单**的 `**`（\(bad.count) 处）：
            \(bad.joined(separator: "\n"))
            落单的 `**` 不会被解析成加粗 —— `AttributedString` 把它当字面量保留
            ⇒ 界面上原样画出裸星号，与「忘了包 MarkdownCopy.text」长得一模一样。
            """)
    }

    /// 语言包里**值带 `**` 的键**，消费它的文件必须调用 markdown 渲染器。
    ///
    /// 这是**类级**的网：单靠「这条横幅现在是对的」证明不了「下一条带 `**` 的文案也对」。
    ///
    /// ⚠️ 扫描粒度是**文件**而不是行：`message` 的值常常先经一层组件再渲染，
    /// 行级判断会误报。文件级的代价是「同文件里另一处调用也能满足它」——
    /// **会漏报、不会误报**，与 `LocalizationCatalogTests.每个键都必须有消费者` 同一取舍。
    @Test func 带markdown标记的文案键必须在解析markdown的文件里被消费() throws {
        let keys = try markdownKeys()
        #expect(
            keys.count >= 3,
            "只找到 \(keys.count) 个带 `**` 的键（真实 3 个）—— 解析口径坏了，下面的结论作废")

        let byFile = try strippedSourceByFile()
        #expect(
            byFile.count > 30,
            "只读到 \(byFile.count) 个 .swift —— 路径多半不对，下面的结论一律作废")

        let renderer = "MarkdownCopy.text("
        let filesWithRenderer = byFile.filter { $0.value.contains(renderer) }.keys.sorted()
        #expect(
            filesWithRenderer.count >= 2,
            """
            只有 \(filesWithRenderer.count) 个文件调用了 `MarkdownCopy.text` —— **范围锚**没立住，
            下面「每个消费文件都调用了渲染器」会因为扫不到而假绿。
            """)

        var bad: [String] = []
        for key in keys {
            // ⚠️ `\.` 要转义：`MarkdownCopy.text` 里的 `.` 在正则里是「任意字符」，
            // 不转义的话注释里写的 `MarkdownCopy/text(_:)` 也会命中（实测踩过）。
            let pattern = "\\.\(key)(?![A-Za-z0-9_])"
            let consumers = byFile.filter {
                $0.value.range(of: pattern, options: .regularExpression) != nil
            }
            if consumers.isEmpty {
                bad.append("\(key)：在 Sources/ 里找不到消费者（另一条守卫本该拦下它）")
                continue
            }
            for (file, text) in consumers.sorted(by: { $0.key < $1.key })
            where !text.contains(renderer) {
                bad.append("\(key)：消费者在 `\(file)`，而那个文件**没有**调用 `MarkdownCopy.text`")
            }
        }

        #expect(
            bad.isEmpty,
            """
            这些带 `**` 的文案键被「不解析 markdown」的路径消费（\(bad.count) 处）：
            \(bad.joined(separator: "\n"))
            `Text(String)` **不解析 Markdown**（只有 `LocalizedStringKey` 才解析）⇒
            界面上会**原样画出裸星号**。修法：把实参包一层 `MarkdownCopy.text(...)`。
            """)
    }

    /// 走查图的横幅夹具必须与生产**逐字一致**。
    ///
    /// **为什么要有这条**：本轮修 bug 时发现 `SnapshotRenderTests` 的横幅夹具
    /// **也**把裸 `String` 传进去 —— 也就是说走查图上一直画着裸星号，
    /// 而图是用来和真机并排看的 ⇒ **图里看不出线上的问题**（§8.33 那条「夹具保真度
    /// = 可观测性上限」）。`message` 改成 `Text` 后编译器会逼调用方做一次显式选择，
    /// 但**选错照样编得过** —— 所以还要这条守卫来比对两侧。
    @Test func 走查图的横幅夹具必须与生产逐字一致() throws {
        let production = try messageArguments(in: "Sources/Views/ContentView.swift")
        let fixture = try messageArguments(in: "Tests/SafeOutAppTests/SnapshotRenderTests.swift")

        #expect(
            production.count >= 2,
            "生产侧只扫到 \(production.count) 个 `message:` 实参 —— 扫描口径坏了")
        #expect(!fixture.isEmpty, "夹具侧一个 `message:` 实参都没扫到 —— 扫描口径坏了")

        #expect(
            Set(production) == Set(fixture),
            """
            走查图夹具与生产的 `message:` 实参不一致：
              生产：\(production.sorted())
              夹具：\(fixture.sorted())
            走查图是拿来和真机并排看的 —— 两边不一致，图里就**看不出**线上的问题。
            """)
    }

    // MARK: 解析

    /// `Sources/` 下所有 `.swift`，**逐文件去掉整行注释**后的正文。
    ///
    /// ⚠️ 必须去掉整行注释：本仓库的注释习惯是**引用**被讨论的标识符 ——
    /// 实测 `MarkdownCopy.text` 就出现在 `DesignSystemComponents.swift` 的一条文档注释里。
    /// 不去掉的话「把调用删掉、注释留着」依然会绿。
    private func strippedSourceByFile() throws -> [String: String] {
        var out: [String: String] = [:]
        guard
            let walker = FileManager.default.enumerator(
                at: sourcesRoot, includingPropertiesForKeys: nil)
        else {
            Issue.record("枚举不到 \(sourcesRoot.path)")
            return out
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out[url.lastPathComponent] =
                text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        return out
    }

    /// 语言包里**值带 `**` 的键**（任一语言带就算）。
    private func markdownKeys() throws -> [String] {
        let data = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = root["strings"] as? [String: Any]
        else {
            Issue.record("`Localizable.xcstrings` 解析不出 `strings` —— 结构变了？")
            return []
        }
        return strings.compactMap { key, value -> String? in
            guard let entry = value as? [String: Any],
                let localizations = entry["localizations"] as? [String: Any]
            else { return nil }
            let marked = localizations.values.contains { language in
                guard let language = language as? [String: Any],
                    let unit = language["stringUnit"] as? [String: Any],
                    let text = unit["value"] as? String
                else { return false }
                return text.contains("**")
            }
            return marked ? key : nil
        }.sorted()
    }

    /// 取某文件里所有 `message:` 实参（整行、去缩进、跳过注释行）。
    /// 语言包里**值带 `**`**的所有 (键, 语言, 值)。
    private func markedValues() throws -> [(key: String, language: String, value: String)] {
        let data = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = root["strings"] as? [String: Any]
        else {
            Issue.record("`Localizable.xcstrings` 解析不出 `strings` —— 结构变了？")
            return []
        }
        var out: [(key: String, language: String, value: String)] = []
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any],
                let localizations = entry["localizations"] as? [String: Any]
            else { continue }
            for (language, lv) in localizations {
                guard let l = lv as? [String: Any],
                    let unit = l["stringUnit"] as? [String: Any],
                    let value = unit["value"] as? String,
                    value.contains("**")
                else { continue }
                out.append((key, language, value))
            }
        }
        return out.sorted { $0.key < $1.key }
    }

    private func messageArguments(in relativePath: String) throws -> [String] {
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("message:") }
    }
}
