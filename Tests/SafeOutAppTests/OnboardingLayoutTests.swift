import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 「完全磁盘访问」引导面板（设计稿 `04-onboarding.html` 第一块）的**排版契约**测试。
///
/// **为什么需要**：这块面板此前根本不存在（用的是系统 `NSAlert`），
/// 落地时每一处的尺寸都来自设计稿实测 —— 图标容器 52、步骤圆点 22、连接线 1.5×16、
/// 提示块 340×54、按钮 28 高（v3 交还系统样式，原自绘 30）、面板总高 498.45（原 503.3）。这些数字一旦被后续改动碰歪，
/// 人眼是看不出来的：面板宽 380 是死的，里面每一块矮 2pt 只表现为「底部留白多一点」。
///
/// **为什么逐个块量而不是只量总高**：两处偏差可以互相抵消。
/// 实测过「图标容器矮 4pt、提示块高 4pt」的巧合，总高完全正常。
/// 所以 `OnboardingView` 的四个块故意留成 internal，让测试能分别量。
@MainActor
struct OnboardingLayoutTests {

    private let panelWidth = DesignTokens.Size.onboardingPanelWidth

    private func makeView() -> OnboardingView {
        OnboardingView(accent: .default, onOpenSettings: {}, onLater: {})
    }

    /// 在给定宽度下渲染并返回**真实渲染尺寸**。
    ///
    /// ⚠️ 必须用 `sizeThatFits(in:)`：`NSHostingView.fittingSize` 返回的是
    /// **无宽度约束的理想尺寸**，宽度根本没生效（详见
    /// `SettingsLayoutTests.renderedSize` 的对照实验）。
    ///
    /// ⚠️ **在中文下渲染**：本文件断言的数字（498.45 / 52 / 135.5 / 54 / 28 / 54 / 106 / 226；
    /// v2 时代是 503.3 / … / 30 / 50 / 102 —— v3 按钮交还系统样式后重量，见各条注释）
    /// **全部按中文实测**，所以「与设计稿一致」的前提就是**先在中文下渲染**。
    /// 不钉就跟随 `Locale.current`，于是同一份代码在英文机器上必红
    /// （2026-09-17 CI 连续 6 次红即此因）。英文下的实际表现由 `LanguageLayoutGapTests` 单独记录。
    ///
    /// ⚠️ **`view` 必须是 `@autoclosure`**：调用点的实参表达式（如
    /// `ActionButton(title: L10n.tr(.notNow), …)`、`makeView().callout`）
    /// 会在**进入本函数之前**求值，而那些表达式里就有 `L10n.tr` ——
    /// 若在这里收普通参数，文案会在钉住的作用域**之外**就解析成英文，钉了等于没钉
    /// （2026-09-17 实测：改成本函数内部钉之后，这 4 条断言仍以完全相同的方式红着）。
    /// `@autoclosure` 把求值推迟到闭包里，于是它落在 `withValue` 之内。
    private func renderedSize<V: View>(_ view: @autoclosure () -> V, width: CGFloat) -> CGSize {
        TestLanguage.with(TestLanguage.design) {
            _ = NSApplication.shared
            let hosting = NSHostingController(rootView: view())
            return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
    }

    // MARK: 整体

    @Test func 面板宽为设计稿的380且内容宽340() {
        let panel = makeView()
        #expect(panel.contentWidth == 340, "内容宽应为 380 − 20×2 = 340，实际 \(panel.contentWidth)")
        let size = renderedSize(panel, width: panelWidth)
        #expect(
            abs(size.width - 380) < 0.5,
            "面板宽应为设计稿的 380，实际 \(size.width) —— 宽度飘了说明文字就会重新折行")
    }

    /// 面板总高。
    ///
    /// **容差 ±4 而不是「等于」，这 2.5pt 的缺口是已知且解释清楚的**：
    /// 设计稿总高 503.3；实现 v2 时代 500.9、**v3 起 498.45**。缺口有两处：
    /// - 两处**带小标的注释行**：第 1 步的注释整条是小标 → 该行取小标自身高 16（设计稿 17.5）；
    ///   第 2 步的注释是「文字 + 小标 + 文字」→ 取两者较高 16.5（设计稿 17.5）。
    ///   根因是 **Blink 会把行内元素的垂直内边距算进行盒高度**
    ///   （`.path { padding: 1px 5px }` → 该行 17.5），而 SwiftUI 里小标是独立视图，
    ///   行盒只取「行内各视图较高者」。要把这 1pt/行补回来，得给小标加 0.75pt 的
    ///   上下外边距 —— 代价是小标的圆角边落在半像素上、边缘发虚。
    ///   **用一个看得见的模糊去换 1pt 的高度是不划算的**，所以如实容差。
    /// - **v3 又矮 2.45pt**：底部按钮组交还系统样式（HANDOFF §3.5），
    ///   `.controlSize(.large)` = **28**（自绘时代 30）。503.3 − 2.45 ≈ 498.45。
    ///
    /// 容差仍然有约束力：任何一处行高令牌（`LineHeight` / `designLineHeight`）
    /// 或段间距被改动，位移都 ≥2.5pt，一定会越界。
    @Test func 面板总高与设计稿相差不超过4() {
        let height = renderedSize(makeView(), width: panelWidth).height
        #expect(
            abs(height - 498.45) <= 4,
            "面板总高应约为设计稿的 503.3，实际 \(height) —— 偏差超过 4pt 说明某一段的行高或间距被改了"
        )
    }

    // MARK: 逐块

    @Test func 顶部图标容器为设计稿的52() {
        // 图标容器 52 + 与标题之间 12 的外边距。
        let size = renderedSize(makeView().iconContainer, width: panelWidth)
        #expect(
            abs(size.width - 52) < 0.5 && abs(size.height - 64) < 0.5,
            "图标容器应为 52×52 + 下方 12 间距（合计 52×64），实际 \(size.width)×\(size.height)"
        )
    }

    @Test func 三步合计高与设计稿相差不超过3() {
        let size = renderedSize(makeView().steps, width: 340)
        #expect(
            abs(size.height - 135.5) <= 3,
            "三步合计高应约为设计稿的 135.5，实际 \(size.height) —— 步骤正文/注释的行高是 18 / 16.5"
        )
    }

    @Test func 信息提示块为设计稿的340乘54() {
        let size = renderedSize(makeView().callout, width: 340)
        #expect(
            abs(size.width - 340) < 0.5 && abs(size.height - 54) <= 2,
            "信息提示块应为 340×54（设计稿实测），实际 \(size.width)×\(size.height)"
        )
    }

    @Test func 按钮组高为系统样式的28() {
        let size = renderedSize(makeView().buttons, width: 340)
        #expect(
            abs(size.height - 28) < 0.5,
            "按钮组高应为 **28**（v3 交还系统样式：`.controlSize(.large)` = 28，HANDOFF §3.5 实测；自绘时代是 30，别改回去），实际 \(size.height)"
        )
    }

    /// 两个按钮的宽度：v3 起由**系统样式**给（文字宽度 + 系统内边距，黑盒）。
    ///
    /// v2 时代宽度 = 「文字 + 左右内边距 12」（50 / 102，设计稿硬数字）；
    /// v3 交还系统后实测 **54 / 106**（各 +4，系统 `.bordered*` 的内边距比我们自绘的宽）。
    ///
    /// ⚠️ **系统内边距是黑盒**：macOS 大版本更新若让按钮变宽/变窄，这里会红 ——
    /// 那不是缺陷，**重量再登记**即可（这正是「交还系统」的代价与收益：
    /// 形状永远跟系统走，代价是数字不再由我们说了算）。
    /// 按钮组是右对齐的，变宽只会往左长，肉眼很难发现。
    @Test func 两个按钮的宽度与系统样式一致() {
        let later = renderedSize(
            ActionButton(
                title: L10n.tr(.notNow), variant: .outline, size: .medium, accent: .default, action: {}),
            width: 340)
        let open = renderedSize(
            ActionButton(
                title: L10n.tr(.openSystemSettings), variant: .primary, size: .medium, accent: .default,
                action: {}),
            width: 340)
        #expect(
            abs(later.width - 54) <= 2,
            "「稍后」应约为 v3 实测的 54pt 宽（系统 bordered 内边距；v2 自绘时是 50），实际 \(later.width)")
        #expect(
            abs(open.width - 106) <= 2,
            "「打开系统设置」应约为 v3 实测的 106pt 宽（系统 borderedProminent 内边距；v2 自绘时是 102），实际 \(open.width)")
        #expect(later.height == 28 && open.height == 28, "两个按钮都应是 28pt 高（系统 `.controlSize(.large)`）")
    }

    /// 第 1 步的路径小标是面板里最宽的一个固定元素（设计稿实测 226）。
    ///
    /// 它的宽度决定了**它会不会折行** —— 340 的内容宽减去编号列 22 与间距 12 只剩 306，
    /// 小标 226 时安全，但如果字体/内边距变了让它涨到 306 以上，第 1 步就会变成两行。
    @Test func 路径小标宽度与设计稿一致() {
        let size = renderedSize(
            PathPill(text: L10n.tr(.fdaOnboardingPathSettings)), width: 400)
        #expect(
            abs(size.width - 226) <= 6,
            "路径小标应约为设计稿的 226pt 宽（等宽 11 + 左右各 5 内边距），实际 \(size.width)"
        )
        // 小标是 11pt 等宽 + 上下各 1 内边距（设计稿 `.path` 实测 15）。
        #expect(abs(size.height - 16) <= 1.5, "路径小标高应约为 16，实际 \(size.height)")
    }

    // MARK: 步骤数据

    @Test func 面板画三步且序号连续递增() {
        #expect(OnboardingStep.all.count == 3, "设计稿是三步，实际 \(OnboardingStep.all.count) 步")
        #expect(
            OnboardingStep.all.map(\.number) == [1, 2, 3],
            "圆点里的序号必须连续递增，实际 \(OnboardingStep.all.map(\.number))")
    }

    /// 三步的注释形态各不相同，这里逐个钉住 —— 形态错了（比如第 1 步被写成纯文字）
    /// 界面上只是「少了块底色」，很容易被当成有意为之。
    @Test func 三步的注释形态与设计稿一致() {
        let steps = OnboardingStep.all
        #expect(
            steps[0].note == .pill(.fdaOnboardingPathSettings),
            "第 1 步的注释整条就是设置路径小标")
        #expect(
            steps[1].note == .template(.fdaOnboardingStep2Note, pill: .fdaOnboardingPathAdd),
            "第 2 步的注释是「文字 + 小标 + 文字」")
        #expect(steps[2].note == .text(.fdaOnboardingStep3Note), "第 3 步的注释是纯文字")
        #expect(steps[2].note.pillKey == nil, "只有第 3 步没有小标")
    }

    /// 注释模板按 `%@` 切分。
    ///
    /// **为什么不用 `String(format:)`**：`%@` 在这里不是「格式化参数」而是
    /// 「小标的插入位置」—— 小标是个带底色的独立视图，格式化字符串给不了。
    /// 切分逻辑要是坏了（比如空段没丢掉），行首会多出半个间距，小标不再贴着边。
    @Test func 注释模板按占位符切分且丢掉空段() {
        // 显式取**设计稿语言**的文案：切分位置由该语言的 `%@` 决定，
        // 走 `Locale.current` 会让结论随机器语言变（英文模板的切分结果不同）。
        let pieces = OnboardingView.notePieces(
            of: TestLanguage.designText(.fdaOnboardingStep2Note),
            pill: TestLanguage.designText(.fdaOnboardingPathAdd))

        #expect(pieces.count == 3, "「文字 + 小标 + 文字」应切成 3 段，实际 \(pieces.count)")
        #expect(pieces[1].isPill, "中间那段是小标")
        #expect(!pieces[0].isPill && !pieces[2].isPill, "首尾两段是文字")
        #expect(
            pieces.map(\.text) == [
                "若不在列表中，点左下角", TestLanguage.designText(.fdaOnboardingPathAdd), "从「应用程序」添加",
            ],
            "切分结果不对：\(pieces.map(\.text)) —— 段首尾的空白必须被吃掉，否则行首会多出半个间距")

        // 模板以占位符开头/结尾时，空段不能进布局。
        let leading = OnboardingView.notePieces(of: "%@ 尾巴", pill: "P")
        #expect(
            leading.map(\.text) == ["P", "尾巴"] && leading.count == 2,
            "以占位符开头的模板应切成「小标 + 文字」两段，实际 \(leading.map(\.text))")
        let only = OnboardingView.notePieces(of: "%@", pill: "P")
        #expect(only.count == 1 && only[0].isPill, "整条只有占位符时应只剩一个小标")
    }

    // MARK: 文案

    /// 说明段里的 `**粗体**` 与换行是**设计稿的内容**，不是格式巧合：
    /// 加粗的那半句是「为什么要给权限」，`<br>` 之后的半句是「不给会怎样」。
    @Test func 说明段带加粗标记与换行() {
        // 加粗标记与硬换行是**中文设计稿的文案特征**，故显式在设计稿语言下取。
        let body = TestLanguage.designText(.fdaOnboardingBody)
        #expect(body.contains("**"), "说明段必须保留 Markdown 加粗标记，否则整段会读成一句平铺的说明")
        #expect(body.contains("\n"), "设计稿在两句之间有一个硬换行（`<br>`），丢了会合成一行")
    }

    /// 第 1 步的正文与第 2 步的正文里各有一处需要指名应用名。
    ///
    /// **断言的是 `%@` 占位符，而不是任何一个具体名字**（2026-10-09 订正）。
    /// 原先查的是硬编码字面量 `SafeOut`，于是：
    ///   - 改名时这条断言**必然变红**，诱导人去改测试里的字面量 —— 而真正的
    ///     事实来源（`L10n.appName`）没人管，两边就此分叉；
    ///   - 更糟的是它把「必须写死英文名」固化成了契约。
    /// 而系统设置里 FDA 列表显示的是**本地化后的名字**（中文环境 = 中文名），
    /// 文案写死英文名 ⇒ 中文用户照着找**找不到那一行开关**（该缺陷真实发生过）。
    ///
    /// 现在的不变量：文案里**必须有**名字占位符，且**不含**任何具体品牌名。
    /// 具体叫什么，由 ``L10n/appName`` 一处决定（`AppNameTests` 钉住三语值）。
    @Test func 步骤正文里的应用名走占位符而非硬编码() {
        for key in [
            L10n.Key.fdaOnboardingBody, .fdaOnboardingStep2Text,
            .fdaOnboardingStep3Text, .fdaOnboardingPrivacy,
        ] {
            for locale in ["zh-Hans", "zh-Hant", "en"] {
                let text = L10n.tr(key, locale: Locale(identifier: locale))
                #expect(
                    text.contains("%@"),
                    "\(key)/\(locale) 必须用 %@ 注入应用名，否则改名会漏这一处")
            }
        }
    }

    /// **最终上屏文案**的断言 —— 前两条守的是「文案模板」，这条守的是「渲染结果」。
    ///
    /// 为什么必须单独一条：模板里有 `%@` 只说明占位符在，**不说明渲染时真的填上了**。
    /// 忘记 `String(format:)` 时，`%@` 会**原样显示给用户**（"在列表中找到 **%@**"），
    /// 而上面两条断言**照样全绿** —— 它们只看模板。这就是它们最大的盲区。
    ///
    /// ⚠️ 判据必须落在**产品代码的同一入口**（`OnboardingStep.renderedText(locale:)` /
    /// `OnboardingText.body(locale:)` / `OnboardingText.privacy(locale:)`），
    /// **不能**在测试里自己调 `String(format:)` —— 那等于测试自己验自己，
    /// 视图漏了格式化它照样绿（2026-10-09 变异测试实测踩到：三条断言全绿）。
    @Test func 上屏文案里应用名已就位且无占位符残留() {
        let locales = ["zh-Hans", "zh-Hant", "en"].map { Locale(identifier: $0) }
        // 三个注入点各取一个代表性 key 之外的键 —— 全取，逐条不漏。
        let rendered: [(String, String)] = locales.flatMap { l in
            OnboardingStep.all.map { ("步骤\($0.number)", $0.renderedText(locale: l)) }
                + [
                    ("说明段", OnboardingText.body(locale: l)),
                    ("提示块", OnboardingText.privacy(locale: l)),
                ]
        }
        for (what, text) in rendered {
            #expect(!text.contains("%@"), "\(what) 上屏后仍有未替换的占位符 —— 渲染点漏了 String(format:)")
        }
        for l in locales {
            let brand = L10n.tr(.appName, locale: l)
            // 只对**模板里带占位符**的键要求「文案里出现品牌名」——
            // 第 1 步正文（`fdaOnboardingStep1Text`）本就不含应用名。
            let withName = OnboardingStep.all.filter {
                L10n.tr($0.textKey, locale: l).contains("%@")
            }
            for step in withName {
                #expect(
                    step.renderedText(locale: l).contains(brand),
                    "步骤\(step.number)/\(l.identifier) 上屏文案里找不到应用名「\(brand)」")
            }
            for (what, text) in [
                ("说明段", OnboardingText.body(locale: l)),
                ("提示块", OnboardingText.privacy(locale: l)),
            ] {
                #expect(text.contains(brand), "\(what)/\(l.identifier) 上屏文案里找不到应用名「\(brand)」")
            }
        }
    }

    /// 反向守卫：占位符就位之后，文案里**不许**再出现具体品牌名。
    /// 少了这条，上面的正向断言可以被「把 `%@` 和硬编码名字都留着」蒙混过关。
    ///
    /// ⚠️ 检查品牌名要**用「非占位符位置上没有大写拉丁词」这种形状判断**，
    /// 不要把品牌名逐个列出来 —— 列出来的那份清单在改名那天会被批量替换工具
    /// 改成 `contains("X") && !contains("X")`，条件重复、断言永真、守卫静默失效
    /// （2026-10-09 实际踩到：机械改名把本守卫改成了同一个词的两遍）。
    /// 取「品牌名 ≠ appName 的值」这个不变量，品牌名改了也不用回来改这里。
    @Test func 文案里不残留任何具体品牌名() {
        let brand = L10n.tr(.appName)
        for key in [
            L10n.Key.fdaOnboardingBody, .fdaOnboardingStep2Text,
            .fdaOnboardingStep3Text, .fdaOnboardingPrivacy,
        ] {
            for locale in ["zh-Hans", "zh-Hant", "en"] {
                let text = L10n.tr(key, locale: Locale(identifier: locale))
                #expect(
                    !text.contains(brand),
                    "\(key)/\(locale) 仍硬编码了品牌名「\(brand)」 —— 应用名只能来自 L10n.appName")
            }
        }
    }
}
