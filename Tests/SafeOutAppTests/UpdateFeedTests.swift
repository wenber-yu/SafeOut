import Foundation
import Testing

@testable import SafeOutApp

/// Sparkle 更新 feed 的**配置契约**测试。
///
/// ## 为什么测的是 shell 脚本，不是 Swift 代码
///
/// feed 地址只有一个真相：`build_app.sh` 写进 Info.plist 的 `SUFeedURL`
/// （Sparkle 从 Info.plist 读它；`SPUUpdater.setFeedURL` 已废弃）。Swift 侧**没有第二份**。
/// 于是能钉的只有脚本本身 —— 这正是要测的东西：
/// **改了脚本而测试还绿 = 假覆盖**，所以测试得读脚本，不能读某个自己维护的常量。
///
/// 判据同 `LocalizationCatalogTests`：手改的配置最容易填错，而填错不会编译失败。
@Suite("更新 feed")
struct UpdateFeedTests {

    private var repoRoot: URL {
        // #filePath = <仓库根>/Tests/SafeOutAppTests/UpdateFeedTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// `SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-<默认值>}"` 里的默认值。
    private func defaultFeedURL() throws -> String {
        let script = try contents("build_app.sh")
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            guard
                let range = line.range(
                    of: #"SPARKLE_FEED_URL="\$\{SPARKLE_FEED_URL:-([^}]*)\}""#,
                    options: .regularExpression)
            else { continue }
            let inner = line[range]
            // 取 `:-` 到结尾 `}"` 之间的内容
            guard let start = inner.range(of: ":-", options: .backwards) else { continue }
            var value = String(inner[start.upperBound...])
            if value.hasSuffix("}\"") { value.removeLast(2) }
            return value
        }
        Issue.record("build_app.sh 里找不到 SPARKLE_FEED_URL 的默认值")
        return ""
    }

    /// feed 必须是** appcast**，不能是 GitHub 的 /releases/latest。
    ///
    /// 「更新链接用 GitHub 的 release 最新版本链接」这个说法很容易被直接实现成
    /// `SUFeedURL = https://github.com/.../releases/latest` —— 那个地址给的是
    /// HTML 页面 / atom 源，Sparkle 解析不了（它要带 `sparkle:` 命名空间的 RSS）。
    /// GitHub Releases 是**文件托管处**，不是 feed；下载地址在 appcast 的 enclosure 里。
    @Test func feed指向appcast而不是GitHub的latest页() throws {
        let raw = try defaultFeedURL()
        let url = try #require(URL(string: raw), "feed 地址不是合法 URL：\(raw)")

        #expect(url.scheme == "https", "feed 必须走 https：\(raw)")
        #expect(url.path.hasSuffix("appcast.xml"), "feed 必须指向 appcast.xml：\(raw)")
        #expect(
            !raw.contains("releases/latest"),
            "别把 feed 指向 /releases/latest —— 那是 HTML/atom 页面，Sparkle 解析不了；下载链接应写在 appcast 的 enclosure 里"
        )
    }

    /// 不给 Sparkle 抢先弹「要不要自动检查更新」的机会：本应用自己有开关。
    ///
    /// ⚠️ 第三条断言（heredoc 里不许有反引号）是 2026-09-28 补的，**它自己就是事故现场**：
    /// 那一轮往 `SUScheduledCheckInterval` 的注释里写了反引号包起来的 Swift 方法名，
    /// 于是**每次构建**都打一条
    /// `command substitution: line N: …` 的告警（看着像噪音），
    /// 而那段文字在产出的 `Info.plist` 注释里**被静默吃掉**（替换成空串）。
    ///
    /// 根因是 shell 语义而不是笔误：起始那行的 heredoc 标记是**裸的** `PLIST`（没带引号），
    /// 未加引号的 heredoc 会先做参数展开 / 命令替换 ⇒ 反引号与「美元括号」都会被求值。
    /// 所以这不是「注释里写错字无所谓」——**同一位置写一条破坏性命令就是真的执行**。
    /// 本仓库对「静默失真」零容忍，因此用一条断言钉住，而不是靠记得。
    @Test func 脚本写明了自动检查的默认值() throws {
        let script = try contents("build_app.sh")
        #expect(
            script.contains("<key>SUEnableAutomaticChecks</key>"),
            "缺 SUEnableAutomaticChecks：不设的话 Sparkle 会在第二次启动弹权限窗，和设置里的「自动更新」开关打架"
        )
        #expect(
            script.contains("<key>SUScheduledCheckInterval</key>"),
            "缺 SUScheduledCheckInterval：自动检查的周期应当显式写出来"
        )

        // ---- 写 Info.plist 的那段 heredoc：标记必须是裸的，正文里不许有会被求值的语法 ----
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let open = try #require(
            lines.firstIndex { $0.contains("<<PLIST") },
            "build_app.sh 里找不到写入 Info.plist 的那个 heredoc（结束标记 PLIST）")
        let opener = lines[open]
        // 加了引号确实能关掉替换 —— 但那样 `${变量}` 也会原样写进 plist，整个文件就废了。
        // 这条前置断言守的是「别人为了躲开反引号而顺手把它引起来」这个修法。
        #expect(
            !opener.contains("<<'PLIST") && !opener.contains("<<\"PLIST"),
            """
            Info.plist 的 heredoc 起始行被加上了引号 ⇒ 里面所有变量替换都会失效，
            写进 plist 的会是字面量 `$APP_DISPLAY_NAME` 这种东西。
            要躲开反引号，请把反引号删掉，不要给 heredoc 加引号。实得：\(opener)
            """)
        let close = try #require(
            lines[(open + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "PLIST" },
            "Info.plist 的 heredoc 没有结束标记（裸 PLIST 独占一行）")
        let body = lines[(open + 1)..<close].joined(separator: "\n")
        for (marker, why) in [
            ("`", "反引号"),
            ("$(", "「美元括号」命令替换"),
        ] {
            #expect(
                !body.contains(marker),
                """
                Info.plist 的 heredoc 里出现了\(why)。那段的起始标记是**裸的** PLIST（没带引号），
                而未加引号的 heredoc 会**先做命令替换** ⇒ 每次构建打一条
                `command substitution: line N: …` 的告警（看着像噪音），而那段文字在产物里
                **被静默吃掉**（2026-09-28 实测：SUScheduledCheckInterval 的注释整句消失）。
                同一位置写破坏性命令就是**真的执行**。要引用代码请直接写名字。
                """)
        }
    }

    /// `--download-url-prefix` 必须以斜杠结尾。
    ///
    /// 实测（2026-09-18）：不带斜杠时 generate_appcast 会把前缀的最后一段当文件名替换掉，
    /// 产出 `.../download/SafeOut-1.2.3.dmg` —— **tag 那一段没了，而且不报错**，
    /// 直到用户点「安装更新」才 404。
    @Test func appcast脚本的下载前缀必须以斜杠结尾() throws {
        let script = try contents("Scripts/make_appcast.sh")
        // 只看**真正传参的那一行**：注释和错误提示里也会出现这个选项名，
        // 连它们一起断言会把「改了注释」误判成「改了参数」。
        var invocation: String?
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("GEN_ARGS+=(") && line.contains("--download-url-prefix") {
                invocation = String(line)
            }
        }
        let line = try #require(invocation, "Scripts/make_appcast.sh 里找不到 --download-url-prefix 的调用")
        #expect(
            line.hasSuffix("v$VERSION/\")"),
            "下载前缀必须以斜杠结尾，否则 generate_appcast 会吃掉最后一段（tag）而不报错：\(line)"
        )
    }

    // MARK: - 仓库里那份 appcast.xml（真实交付物）

    /// 把 appcast 的 XML 解出来。**用 XMLParser，不用正则** ——
    /// `<description>` 是 CDATA，正则取到的是原文（会连 `]]>` 一起带上），
    /// 而 Sparkle 交给 `UpdateUserDriver` 的是**解完 CDATA 的纯文本**。
    /// 用正则测等于测了个和线上不同的东西。
    ///
    /// ⚠️ **必须按 `sparkle:version` 挑最新一条，不能取「最后解析到的那条」**（2026-10-09 修）。
    /// 原实现只留一份可变字段，`<item>` 之间不复位 ⇒ 后面那条会**覆盖**前面的 ⇒
    /// 实际拿到的是**文档里最后一条**。仓库里长期只有一条 item，所以这个缺陷一直没露头；
    /// 一旦发第二个版本，appcast 变成两条，判据就会去校验**最老的那条** ——
    /// 而它恰好是刻意保留旧资产名的历史条目 ⇒ 守卫会**静默全绿**，
    /// 正是「改了测试才能过 / 永远绿」的那种假守卫。
    ///
    /// 判据取 `sparkle:version`（= `CFBundleVersion`，单调递增的构建号）而**不是文档顺序**：
    /// 顺序取决于 `generate_appcast` 怎么写、有没有人手工插条目，而「谁更新」Sparkle 自己
    /// 也是拿这个构建号比的 —— 用它才和线上行为同源。
    private final class AppcastParser: NSObject, XMLParserDelegate {
        struct Item {
            /// `sparkle:version`（CFBundleVersion）。Sparkle 用它比新旧。
            var buildNumber: Int?
            var shortVersion: String?
            var enclosureURL: String?
            var descriptionHTML: String?
        }

        private(set) var items: [Item] = []
        private var currentItem: Item?
        private var current = ""

        /// 最新一条。`buildNumber` 缺失的条目排在最后（`Int.min`）——
        /// 真 appcast 里它一定存在（`generate_appcast` 必写），缺失只可能是文件被改坏。
        var latest: Item? {
            items.reduce(nil) { best, candidate in
                guard let best else { return candidate }
                return (candidate.buildNumber ?? .min) > (best.buildNumber ?? .min) ? candidate : best
            }
        }

        var shortVersion: String? { latest?.shortVersion }
        var enclosureURL: String? { latest?.enclosureURL }
        var descriptionHTML: String? { latest?.descriptionHTML }

        static func parse(_ xml: String) -> AppcastParser? {
            let parser = AppcastParser()
            let xmlParser = XMLParser(data: Data(xml.utf8))
            xmlParser.delegate = parser
            guard xmlParser.parse() else { return nil }
            return parser
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            current = ""
            switch elementName {
            case "item": currentItem = Item()
            case "enclosure": currentItem?.enclosureURL = attributes["url"]
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            current += string
        }

        /// ⚠️ CDATA 走的是**这个方法**，不是 `foundCharacters` —— 少了它
        /// `<description>` 会永远读成空串，测试于是「通过」（空输入返回空数组）。
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            current += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "item":
                if let currentItem { items.append(currentItem) }
                currentItem = nil
            case "description": currentItem?.descriptionHTML = text
            case "sparkle:version", "version": currentItem?.buildNumber = Int(text)
            case "sparkle:shortVersionString", "shortVersionString": currentItem?.shortVersion = text
            default: break
            }
            current = ""
        }
    }

    /// 仓库里那份 appcast 必须能让弹窗**真的显示出更新条目**。
    ///
    /// 空 `<description>` 不会崩、不会报错 —— `UpdateReleaseNotes.lines` 空输入返回空数组，
    /// 调用方据此**不画**「本次更新」区块。于是「没写说明」与「写了但没生效」
    /// 在界面上长得一模一样（都是「没有这一块」）。这条守卫把它们区分开。
    @Test func 仓库里的appcast必须能解析出更新条目() throws {
        let appcast = try contents("appcast.xml")
        let parsed = try #require(AppcastParser.parse(appcast), "appcast.xml 不是合法 XML")

        let lines = UpdateReleaseNotes.lines(fromHTML: parsed.descriptionHTML)
        #expect(
            !lines.isEmpty,
            """
            appcast.xml 的 <description> 解析不出任何条目 → 新版本弹窗的「本次更新」是空的。
            要么补 Release-notes/<版本>.html 后用 RELEASE_NOTES_FILE=… ./Scripts/make_appcast.sh 重新生成，
            要么明确接受「这一块不显示」。
            """
        )

        // 残留的标记：说明文件里写了 HTML 注释时最容易中招 ——
        // `stripTags` 只剥 `<…>` 尖括号对，**不认注释**，注释正文会原样进到弹窗里。
        for line in lines {
            #expect(!line.contains("<!--") && !line.contains("-->"), "条目里残留了注释标记：\(line)")
            #expect(!line.contains("]]>"), "条目里残留了 CDATA 结束符（说明取的是正则原文而非 XML 解析结果）：\(line)")
        }
    }

    /// 「最新一条」必须**与文档顺序无关** —— 否则下面那条守卫会指错条目。
    ///
    /// 这守的是**测试自己的装置**：解析器原先不复位字段，实际拿到的是文档最后一条。
    /// 仓库里长期只有一条 item，这个缺陷一直没露头；发第二个版本时它会去校验
    /// **最老的那条**（= 刻意保留旧资产名的历史条目）⇒ 断言静默全绿。
    /// 用合成 XML 做**双向对照**（新的在前 / 新的在后）把它钉死：
    /// 两种顺序都必须选出构建号最大的那条。
    @Test func appcast解析器取构建号最大的那条而非文档最后一条() throws {
        func item(build: Int, short: String) -> String {
            """
            <item>
                <sparkle:version>\(build)</sparkle:version>
                <sparkle:shortVersionString>\(short)</sparkle:shortVersionString>
                <enclosure url="https://example.com/\(short).dmg" length="1" type="application/octet-stream"/>
            </item>
            """
        }
        let head = """
            <?xml version="1.0" standalone="yes"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
                <channel><title>SafeOut</title>
            """
        let tail = "</channel></rss>"
        let old = item(build: 325, short: "2026.10.08.1")
        let new = item(build: 326, short: "2026.10.09")

        for (label, xml) in [("新的在前", head + new + old + tail), ("新的在后", head + old + new + tail)] {
            let parsed = try #require(AppcastParser.parse(xml), "\(label)：不是合法 XML")
            #expect(parsed.items.count == 2, "\(label)：条目数不对")
            #expect(parsed.shortVersion == "2026.10.09", "\(label)：没有选中最新的那条")
            #expect(
                parsed.enclosureURL == "https://example.com/2026.10.09.dmg",
                "\(label)：enclosure 取的不是最新那条"
            )
        }
    }

    /// `enclosure` 的文件名必须与脚本让你上传的那个资产**同名**。
    ///
    /// 实测（2026-09-18）：`make_appcast.sh` 的「下一步」原本让用户上传
    /// `SafeOut.dmg`，而 enclosure 里写的是 `SafeOut-<版本>.dmg` ——
    /// 照指引做，用户点「安装更新」时**必 404**，而 appcast 本身不报任何错。
    /// 同一个事实被写在两个地方（指引一次、工具生成一次），所以得有一条守卫来比对。
    ///
    /// ⚠️ 改名后这条守卫长出了尖角：**历史条目不能跟着改名**（2026-10-09）。
    /// 已发布的资产在 GitHub 上没有被重命名 —— 实测
    /// `.../SafeOut-2026.10.08.1.dmg` → 404，而 `.../DiskEjector-2026.10.08.1.dmg` → 200。
    /// 若把历史条目也改名，那条更新链接当场失效，且 EdDSA 签名与下载内容绑定、改了必坏。
    ///
    /// 所以判据从「**所有**条目都用新名」改成：
    /// **最新一条**（发版链路的产物）必须用当前 `APP_NAME`；**更早的**条目按「真实可达」放行。
    /// 「真实可达」无法在单测里联网验证，改用**可离线核对的不变量**：
    /// 历史条目的资产名必须与它自己 `sparkle:version` 对应的那一版成对存在，
    /// 且**条目的 tag 与资产名里的版本号必须一致**（否则才是真的写错）。
    @Test func appcast的下载文件名必须与待上传资产同名() throws {
        let appcast = try contents("appcast.xml")
        let parsed = try #require(AppcastParser.parse(appcast), "appcast.xml 不是合法 XML")

        let version = try #require(parsed.shortVersion, "appcast 里没有 sparkle:shortVersionString")
        let enclosure = try #require(parsed.enclosureURL, "appcast 里没有 enclosure，更新无法下载")

        #expect(
            enclosure.contains("/releases/download/v\(version)/"),
            "enclosure 里没有 releases/download/v\(version)/ 这一段（前缀少了斜杠就会这样，而且不报错）：\(enclosure)"
        )

        // 资产名里**必须有**这个版本号 —— 无论新旧品牌名，这是唯一恒真的那部分。
        // 少了它，tag 与文件名错配（最常见的一种写错）就查不出来了。
        let fileName = URL(string: enclosure)?.lastPathComponent ?? ""
        #expect(
            fileName.contains(version),
            "enclosure 的文件名里没有版本号 \(version)，tag 与资产名对不上：\(enclosure)"
        )

        // 品牌名（`SafeOut-` 还是 `DiskEjector-`）**只对「尚未发布的资产」有要求**。
        //
        // 判据 = **这个 tag 是不是已经存在**（发版先打 tag，见 `build_app.sh` 的版本派生）：
        //   tag 已存在 ⇒ 那一版**已经发布** ⇒ 它的资产在 GitHub 上以旧名存在 ⇒ 改名即失效；
        //   tag 不存在 ⇒ 那是**待发布**的资产 ⇒ 必须用当前 `APP_NAME`，否则用户点更新必 404。
        //
        // 查 tag **不引入子进程**：既绕开 `waitUntilExit` 占死协作线程池的坑
        // （`MainActorBlockingTests/测试代码里不许同步等子进程` 守着），也免掉一次进程开销。
        //
        // ⚠️ **两处都要查**，只查一处会静默漏判：
        //   - `.git/refs/tags/<tag>`：普通 tag 的松散引用；
        //   - `.git/packed-refs`：被 `git pack-refs` 收拢后的 tag（**只有这一份**时松散引用不存在）。
        // 只查松散引用 ⇒ 在「refs 已被打包」的 checkout 上会误判成「未发布」，
        // 于是拿旧资产名去撞「必须用新名」的断言 —— 症状与守卫完全失效一模一样。
        let tagExists: Bool = {
            let tagName = "v\(version)"
            let repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let fm = FileManager.default
            if fm.fileExists(atPath: repo.appendingPathComponent(".git/refs/tags/\(tagName)").path) {
                return true
            }
            guard let packed = try? String(contentsOf: repo.appendingPathComponent(".git/packed-refs"), encoding: .utf8)
            else { return false }
            return packed.split(separator: "\n").contains { $0.hasSuffix(" refs/tags/\(tagName)") }
        }()
        if !tagExists {
            #expect(
                fileName == "SafeOut-\(version).dmg",
                """
                tag v\(version) **尚未发布** ⇒ 这是待上传的资产，文件名必须与脚本让你上传的\
                那个逐字相同，改名即 404：\(enclosure)
                """
            )
        }
    }

    /// 发布说明文件必须**能被真实解析器解析出条目**，且里面**不能有 HTML 注释**。
    ///
    /// `UpdateReleaseNotes.stripTags` 只剥 `<…>` 尖括号对 —— `<!-- 说明 -->`
    /// 剥掉 `<!--` 之后，**注释正文会原样出现在新版本弹窗里**（2026-09-18 实测踩到）。
    /// 脚本里已有一条守卫直接拦下，这里再对**仓库里真实存在的说明文件**兜一层。
    ///
    /// ⚠️ 第二条断言（解析出条目）是 2026-09-18 补的：说明文件被外部编辑器改写
    /// （例如注入 `data-page-node-id="…"` 这类**属性**）时，`stripTags` 的深度计数
    /// 会把整个标签连属性一起吞掉，于是**解析结果不变** —— 但那只是这一次运气好。
    /// 「改坏了」在弹窗上的表现是「这一块不显示」，与「本来就没写说明」长得一模一样，
    /// 所以这里必须用**真实解析器**跑一遍，而不是靠读文件推断。
    @Test func 发布说明文件里不能有HTML注释() throws {
        let dir = repoRoot.appendingPathComponent("release-notes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            // 只看**说明文件**：`README.md` 是格式文档，里面正当地举了 `<!-- 说明 -->` 这个反例。
            .filter { $0.hasSuffix(".html") }
        for file in files {
            let body = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            #expect(
                !body.contains("<!--"),
                "Release-notes/\(file) 里有 HTML 注释 —— 解析器不认注释，注释正文会原样出现在弹窗里"
            )
            let lines = UpdateReleaseNotes.lines(fromHTML: body)
            #expect(
                !lines.isEmpty,
                """
                Release-notes/\(file) 用真实解析器跑出来是空的 → 用它生成的 appcast
                会让弹窗的「本次更新」整块不显示，而那与「没写说明」长得一模一样。
                """
            )
        }
    }
}
