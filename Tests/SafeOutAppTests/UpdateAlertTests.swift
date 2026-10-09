import Foundation
import Testing

@testable import SafeOutApp

/// 设计稿 `08-update.html` 的 A 段（新版本弹窗）与 appcast 说明解析。
///
/// **为什么这些断言都走模型、不走视图**：弹窗是自绘的（设计稿要求图标在左、标题左对齐、
/// 提示块、下沉操作区），视图里的文案没法像 `NSAlert.messageText` 那样直接断言。
/// 抽成 ``EjectAlertModel`` 之后，「标题带不带版本号」「Esc 有没有占一个按钮」
/// 「主按钮是哪个」这些契约都能在**不渲染、不驱动窗口**的前提下被钉住 ——
/// 与推出弹窗（`EjectAlertView`）用的是同一条路子。
@Suite("更新弹窗与说明解析")
struct UpdateAlertTests {

    private static func update(
        version: String = "1.1.0",
        newBuild: String? = "58",
        currentVersion: String = "1.0.0",
        currentBuild: String? = "42",
        date: String? = "2026-09-17",
        sizeBytes: UInt64 = 12_400_000,
        notes: [String] = ["第一条", "第二条"]
    ) -> PendingUpdate {
        PendingUpdate(
            version: version, newBuild: newBuild,
            currentVersion: currentVersion, currentBuild: currentBuild,
            date: date, sizeBytes: sizeBytes, notes: notes)
    }

    // MARK: - 弹窗

    /// **标题写版本号，不写「发现新版本」。**
    ///
    /// 设计稿 D 段「文案原则」第一条：用户要判断的是「值不值得为它重启一次」，
    /// 所以版本号必须在标题里。写成「发现新版本」的话，用户得点开才知道是哪个版本。
    @MainActor
    @Test func 标题带版本号() {
        TestLanguage.with(TestLanguage.design) {
            let model = UpdateAlertBuilder.model(for: Self.update())
            #expect(model.title.contains("1.1.0"), "标题必须带版本号")
            #expect(
                model.title.contains(TestLanguage.designText(.appName)),
                "标题必须带应用名 —— 更新弹窗可能盖在别的应用上面")
        }
    }

    /// **Esc 是第三个出口，而且它不占按钮。**
    ///
    /// 只有「跳过此版本」和「后台更新并重启」两个按钮时，用户被逼着在
    /// 「永久跳过这个版本」和「现在就重启」之间二选一 —— 而多数人真正想说的是
    /// 「现在不方便」。所以：① 操作区左边必须有那行小标；② Esc **不能**挂在任何一个按钮上
    /// （挂上去用户会以为 Esc = 永久跳过）。
    @MainActor
    @Test func Esc是第三个出口且不占按钮() {
        TestLanguage.with(TestLanguage.design) {
            let model = UpdateAlertBuilder.model(for: Self.update())

            #expect(model.footNote == TestLanguage.designText(.updateEscHint))
            #expect(model.actions.count == 2, "操作区只有两个按钮 —— Esc 不占位")
            #expect(
                model.actions.allSatisfy { !$0.isCancel },
                "没有任何按钮是「取消」：Esc 的语义是「稍后」，由窗口的 cancelOperation 兜底")
            #expect(
                model.actions.map(\.choice) == [.skipVersion, .installAndRestart],
                "按钮顺序：次按钮「跳过此版本」在前，主按钮在后（设计稿的操作区右对齐顺序）")
        }
    }

    /// 主按钮是「后台更新并重启」，接回车。
    ///
    /// **它的语义是「后台下载，重启时安装」**，不是「立刻重启」—— 立刻重启由
    /// 「已就绪」那一态的「立即重启」按钮负责（设计稿 B4 的 spec-note 点名要求）。
    @MainActor
    @Test func 主按钮是后台更新并重启() {
        TestLanguage.with(TestLanguage.design) {
            let model = UpdateAlertBuilder.model(for: Self.update())
            let primary = model.actions.last

            #expect(primary?.title == TestLanguage.designText(.updateInstallAndRestart))
            #expect(primary?.variant == .primary)
            #expect(primary?.isDefault == true, "主按钮接回车")
            #expect(model.actions.first?.variant == .outline, "次按钮是描边样式")
        }
    }

    /// 首屏给全四样：当前版本、新版本、体积、日期。
    ///
    /// 设计稿 D 段：「用户要判断的是『值不值得为它重启一次』，所以版本号、当前版本、
    /// 体积、日期四样都要在首屏给全」。缺哪一样都得让用户去别处找。
    @MainActor
    @Test func 说明行给全版本与构建号() {
        TestLanguage.with(TestLanguage.design) {
            let model = UpdateAlertBuilder.model(for: Self.update())
            let lines = model.subtitle.components(separatedBy: "\n")

            #expect(lines.count == 2, "说明行是两行：版本迁移 + 日期与体积")
            #expect(lines[0].contains("1.0.0") && lines[0].contains("1.1.0"), "两边的版本号都要有")
            #expect(lines[0].contains("42") && lines[0].contains("58"), "构建号也要有")
            #expect(lines[1].contains("2026-09-17"), "日期在第二行")
        }
    }

    /// 构建号缺失时**降级成不带构建号的写法**，而不是显示「构建 」。
    ///
    /// 同 `AppVersionInfo` 的口径：读不到就返回 `nil`，不自己编值。
    ///
    /// ⚠️ 期望值走 `TestLanguage.designText` 而不是写死中文字面量 ——
    /// 否则换台英文机器这条必红，而红的原因与被测代码无关。
    @MainActor
    @Test func 没有构建号时降级() {
        TestLanguage.with(TestLanguage.design) {
            let model = UpdateAlertBuilder.model(
                for: Self.update(newBuild: nil, currentBuild: nil))
            let firstLine = model.subtitle.components(separatedBy: "\n")[0]

            #expect(
                firstLine
                    == String(
                        format: TestLanguage.designText(.updateAlertVersionsPlainFormat),
                        "1.0.0", "1.1.0"),
                "构建号缺失时走不带构建号的那个格式串")
        }
    }

    /// 日期与体积**都可能没有**，缺一个就不画那个分隔符。
    ///
    /// 不判空的话会出现「 · 12.4 MB」这种以分隔符开头的行 —— 看起来像前面漏了一段。
    @MainActor
    @Test func 没有日期和体积时不画分隔符() {
        TestLanguage.with(TestLanguage.design) {
            let model = UpdateAlertBuilder.model(for: Self.update(date: nil, sizeBytes: 0))
            let lines = model.subtitle.components(separatedBy: "\n")

            #expect(lines.count == 1, "日期与体积都没有时，说明行只剩版本迁移那一行")
            #expect(!lines[0].contains("·"))
        }
    }

    /// 更新条目为空时**不画「本次更新」区块**。
    ///
    /// 画一个空的区块会留下一行孤零零的标题 —— 用户会以为更新内容没加载出来。
    @MainActor
    @Test func 更新条目为空时不画区块() {
        TestLanguage.with(TestLanguage.design) {
            #expect(UpdateAlertBuilder.model(for: Self.update(notes: [])).section == nil)
        }
    }

    @MainActor
    @Test func 更新条目逐条进区块() {
        TestLanguage.with(TestLanguage.design) {
            let model = UpdateAlertBuilder.model(for: Self.update(notes: ["甲", "乙", "丙"]))
            #expect(
                model.section
                    == .causes(
                        label: TestLanguage.designText(.updateWhatsNew), items: ["甲", "乙", "丙"]))
        }
    }

    /// **提示块必须说清「不会打断正在推出的磁盘」。**
    ///
    /// 设计稿 D 段：「这句是必需的 —— 用户按下更新前最怕的就是
    /// 『会不会把我正在拷的东西弄坏』」。
    @MainActor
    @Test func 提示块说清不打断磁盘() {
        TestLanguage.with(TestLanguage.design) {
            let callout = UpdateAlertBuilder.model(for: Self.update()).callout
            #expect(callout?.kind == .info, "信息态，不是警告态")
            #expect(callout?.text == TestLanguage.designText(.updateCallout))
        }
    }

    // MARK: - appcast 的 `<description>` → 条目

    /// `generate_appcast` 生成的 `<description>` 是 HTML（`<ul><li>…</li></ul>`）。
    @Test func 解析无序列表() {
        let html = "<ul>\n<li>设置里新增<b>「自动更新」</b>开关</li>\n<li>修复骨架层不消失</li>\n</ul>"
        #expect(
            UpdateReleaseNotes.lines(fromHTML: html) == [
                "设置里新增「自动更新」开关", "修复骨架层不消失",
            ])
    }

    /// **剥标签之前必须先把条目边界变成换行。**
    ///
    /// 顺序反了的话所有条目会粘成一行 —— 而粘出来的文本读起来完全正常，
    /// 只是少了分隔，肉眼在弹窗上很难发现「3 条更新变成了 1 条」。
    @Test func 条目之间必须断开() {
        #expect(UpdateReleaseNotes.lines(fromHTML: "<li>甲</li><li>乙</li>").count == 2)
        #expect(UpdateReleaseNotes.lines(fromHTML: "甲<br>乙").count == 2)
        #expect(UpdateReleaseNotes.lines(fromHTML: "<p>甲</p><p>乙</p>").count == 2)
    }

    /// 没有列表标签的裸文本（`generate_appcast` 在 commit 正文只有一行时会这样）。
    @Test func 解析裸文本() {
        #expect(UpdateReleaseNotes.lines(fromHTML: "  修了一个崩溃  ") == ["修了一个崩溃"])
    }

    /// `&amp;` **必须最后解**：先解它的话 `&amp;lt;` 会被多解一层。
    @Test func 实体解码顺序() {
        #expect(UpdateReleaseNotes.lines(fromHTML: "a &amp; b") == ["a & b"])
        #expect(
            UpdateReleaseNotes.lines(fromHTML: "&amp;lt;") == ["&lt;"],
            "双重转义的文本不该被解成 <")
        #expect(UpdateReleaseNotes.lines(fromHTML: "&lt;tag&gt;") == ["<tag>"])
    }

    /// 弹窗自己会画 `·`，所以源文本里自带的列表符号要去掉。
    ///
    /// 不去掉的话每条会变成「· · 修复了…」。
    @Test func 去掉源文本自带的列表符号() {
        #expect(UpdateReleaseNotes.lines(fromHTML: "<li>· 甲</li><li>- 乙</li>") == ["甲", "乙"])
    }

    /// 空输入返回**空数组**，不是 `[""]`。
    ///
    /// 返回 `[""]` 会让弹窗多出一行空白，且 ``UpdateAlertBuilder`` 会以为
    /// 「有更新内容」而画出空的「本次更新」区块。
    @Test func 空输入返回空数组() {
        #expect(UpdateReleaseNotes.lines(fromHTML: nil).isEmpty)
        #expect(UpdateReleaseNotes.lines(fromHTML: "").isEmpty)
        #expect(UpdateReleaseNotes.lines(fromHTML: "   \n  ").isEmpty)
        #expect(UpdateReleaseNotes.lines(fromHTML: "<ul></ul>").isEmpty)
    }
}
