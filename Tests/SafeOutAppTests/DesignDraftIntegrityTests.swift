import CryptoKit
import Foundation
import Testing

@testable import SafeOutApp

/// 设计稿（HTML 原型）自身的**完整性**守卫，三个维度：
///
/// 1. **CSS 类**：「用了但没有定义」必须登记（拼错类名 / 删了 CSS 忘了改 HTML）。
/// 2. **i18n 键**：`i18n-extra.json` 里声明的键必须**有页面在用**（否则是死文案）。
/// 3. **`ds.js` 运行时创建的类**：必须在设计稿里有 CSS 定义（否则建出来的元素裸奔）。
///
/// 前两个都属于「**有声明、没有消费者**」—— Swift 侧已经在 §8.50 钉住了
/// （`DeclarationConsumerTests`），设计稿侧此前**一条都没有**。
/// 而 §8.51 刚证明设计稿是「唯一真相」的来源：**它腐化了，同源守卫全会被误导**。
///
/// **为什么「用了但没定义」报警、「定义了但没用」只记账**：设计稿里「定义了但没元素用」
/// 的类**多数是合理的**（备用样式、无障碍 `.sr-only`、文档样例）—— §8.52.5 记过：
/// **零消费者 ≠ 可删**，删设计稿的类会改变视觉。但「不删」不等于「不记账」：
/// 那一向此前只 `print`，于是手写清单烂了三处没人知道（§8.76）。现在改成**三张账本**
/// （`runtimeCreatedClasses` / `pageLocalUnused` / `spareUnused`）——
/// **成因不同判据不同**，混在一起数就会算错账。
///
/// 反过来，「用了但没定义」**一定是问题**：要么是类名拼错（`.aboutroww`），
/// 要么是删了 CSS 忘了改 HTML。它的症状是「样式没生效」——
/// 而**「样式没生效」与「本来就没写样式」在界面上逐字相同**，读代码看不出来。
/// 这一条负责把两者分开。
///
/// 第 3 向的症状与第 1 向**逐字相同**，但第 1 向**查不到它** —— 见 §8.76：
/// 它扫的是 HTML 的 `class` 属性，而 JS 建出来的类名根本不在 HTML 里。
///
/// **定义源有两个，别漏**（§8.52.1）：主 CSS `assets/ds.css` **加上每个 HTML 的 `<style>` 块**
/// —— 实测 9 个页面共 225 行 `<style>`，`.aboutrow` 的样式就在那里，只扫主 CSS 会误报。
///
/// ## ⚠️ 本套件**故意不标** `@MainActor`（2026-09-22，§8.128）
///
/// 它只做「读文件 + 正则解析」，**没有任何**主 actor 隔离的 API（44 条测试、0 条 `async`）。
/// 而标上 `@MainActor` 的后果是：这 **1.66s** 的 CPU 活全部压在**主 actor** 上 ——
/// 同一时刻还有另外 **29** 个 `@MainActor` 测试文件在排队（§8.114 第 6 节 / 计数口径 §8.128）。
/// 摘掉之后这 44 条在**协作池**上跑，主 actor 一秒都不占。
/// ⚠️ **别「顺手」加回来**：加之前先回答「这个文件里**哪一行**真的需要主 actor」——
/// 答不出来就是不需要（`MarkdownCopyTests` 标它是因为 `NSHostingController`，
/// `ProcessAppResolverTests` 标它是因为 `enrich` / `icon`，那才叫理由）。
struct DesignDraftIntegrityTests {

    // MARK: 路径

    /// #filePath = <仓库根>/Tests/SafeOutAppTests/DesignDraftClassTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var designRoot: URL {
        repoRoot.appendingPathComponent("Design/ui/v2")
    }

    // MARK: 豁免表

    /// 「用了但没定义」的**账本** —— 两个方向都查（新出现的要拦下，登记了却已经
    /// 不存在的要回来划掉）。只查一个方向，这张表就会像 §8.33 清掉的那 6 条一样：
    /// **还了账没人回来划**。
    ///
    /// 这 4 个都是**纯容器 / 语义类**：只有结构作用，本来就不该有样式。
    private static let containerOnly: [String: String] = [
        "ds": "文档根容器（`<body class=\"ds\">`），只用来挂主题与语言",
        "row__evid": "完整行的「证据区」容器，样式走 `.evid*`，本身无规则",
        "spec": "index.html 的规格表容器",
        "state-tbl": "状态矩阵表格（样式写在 `06-states.html` 的 `<style>` 里，见 `table.state-tbl`）",
    ]

    // MARK: 反向的账本（定义了但没元素用）

    /// 反向（定义了但没元素用）**不能只打印** —— §8.52.5 那张手写表就是这么烂掉的：
    /// 标题写「18 个」、表里只列了 15 行、而 `meter--high` 那一行在 `5df286f`（§8.74）
    /// 给它补上样本之后**没人回来划掉**。只打印 + 两条极松边界 = 数字变了也没人知道。
    ///
    /// ⚠️ **成因不同，判据不同** —— 这是本轮最贵的一条。把三种成因混在一起数，账就是错的
    /// （`18 / 17 / 15` 三个数字就是这么来的）：
    ///
    /// | 成因 | 有消费者吗 | 判据 |
    /// |---|---|---|
    /// | `runtimeCreatedClasses` | **有**（在 `ds.js` 里），只是消费者不在 HTML 里 | 必须在设计稿里有定义（否则运行时建出来**裸奔**） |
    /// | `pageLocalUnused` | 没有 | 必须真的「只在某页 `<style>` 里定义」 |
    /// | `spareUnused` | 没有 | 必须真的「纯 `ds.css` 定义、`ds.js` 也不建」 |
    ///
    /// **为什么不删**：§8.52.5 的判据仍然成立 —— 设计稿是规范文档，删类会改变视觉，
    /// 零消费者只说明「现在没用到」。所以这三张表是**账本**，不是**待删清单**。
    /// （唯一的例外已于 2026-09-21 补平 —— 见 `spareUnused` 上方的说明。）

    /// `ds.js` 运行时创建的类。**它们有消费者**（在 JS 里），所以**不是**零消费者。
    private static let runtimeCreatedClasses: [String: String] = [
        "langbar": "语言切换条（`ds.js:218` `bar.className = 'langbar'`），插在每个页面顶部",
        "langbar__label": "同上，语言条里的「语言」标签（`ds.js:221`）",
        "langbar__hint": "同上，语言条里的提示（`ds.js:237`）",
        "pill": "同上，语言条里的语言按钮（`ds.js:227` `b.className = 'pill'`）",
    ]

    /// 只在某个页面的 `<style>` 里定义、未启用（页面级备用样式）。
    private static let pageLocalUnused: [String: String] = [
        "kbd": "键盘按键样式，写在 `01-main-window.html` 的 `<style>` 里；该页的按键说明用的是 `.note-list code` ⇒ 写好了没启用",
        "zoomwrap": "`transform-origin: top left`，写在 `01-main-window.html` 的 `<style>` 里；页面里没有元素用它（缩放包裹层未启用）",
    ]

    /// 纯 `ds.css` 定义、静态无消费者、`ds.js` 也不建。
    ///
    /// 多数是**备用样式 / 工具类**（§8.52.5：零消费者 ≠ 可删）。
    /// （曾有的**唯一例外** `statusline--unknown` 已于 2026-09-21 补上样本、移出本表 —— §8.113；
    /// 与它同族的 `.mrow__occ--unknown` 当时**连定义都没有**，同批补了 CSS 与样本。）
    private static let spareUnused: [String: String] = [
        "appicon--doc":
            "`.appicon` 定义了 8 个分类底色，页面只画了 5 个（finder / photo / code / backup / music）。**实现侧不按分类着色** —— `ProcessChip` 画的是真应用图标（`ProcessAppResolver.icon`）⇒ 备用样式",
        "appicon--sync": "同上",
        "appicon--term": "同上",
        "callout--warn":
            "琥珀警示块。**实现侧没有这个语义** —— `AlertCallout.Kind` 只有 `{danger, info}`（`DesignSystemComponents.swift:299`）⇒ 备用样式",
        "chip--plain": "无图标 chip 变体。实现侧溢出用的是 `.chip--more`（`ProcessChipOverflow`）⇒ 备用样式",
        "glass": "毛玻璃工具类（`ds.css` 第 3 节）。设计稿的页面里没有元素用它（玻璃面由 `.win` / `.wallpaper` 承载）⇒ 工具类，备用",
        "glass-thick": "同上（加厚版）",
        "grid4": "四列网格。**同族的 `grid2` 有 15 个样本、`grid3` 有 4 个，只有 `grid4` 是 0** ⇒ 备用",
        "iconbtn--lg": "32×32 大号图标按钮。`iconbtn` 有 13 个样本，**没有一个是 32**（实现侧也没有这个尺寸）⇒ 备用",
        "sr-only": "**无障碍**工具类（仅供屏幕阅读器），**有意保留** —— 见 §8.52.5",
    ]

    // MARK: 守卫

    /// 设计稿里**用了但没有任何 CSS 定义**的类，必须全在豁免表里。
    @Test func 用了但没定义的类必须登记在案() throws {
        let scan = try load()
        // 解析器的**锚**：下面几条不成立，说明扫描逻辑退化了，
        // 而那种情况下「未定义」会**空着** —— 通过得毫无意义。
        #expect(scan.defined.count > 150, "只解析到 \(scan.defined.count) 个类 —— 扫描逻辑多半坏了")
        #expect(scan.used.count > 150, "只收集到 \(scan.used.count) 个类 —— HTML 没读到")
        #expect(
            scan.defined.contains("row"), "`.row` 都没解析到 —— 定义源（ds.css / `<style>`）没读到")
        #expect(scan.used.contains("row"), "`.row` 都没收集到 —— HTML 的 class 属性没读到")
        #expect(
            scan.defined.contains("aboutrow"),
            "`.aboutrow` 必须能解析到 —— 它的样式在 05-settings.html 的 `<style>` 里，只扫 ds.css 会漏掉（§8.52.1）"
        )

        let missing = scan.used.subtracting(scan.defined).subtracting(Self.containerOnly.keys)
        #expect(
            missing.isEmpty,
            """
            设计稿里这些类**被元素用着，但没有任何 CSS 定义**（多半是类名拼错，或删了 CSS 忘了改 HTML）：
            \(missing.sorted().joined(separator: ", "))
            已知的无样式容器类登记在 `containerOnly` 里；新增的要连同理由一起登记。
            """
        )
    }

    /// 豁免表**不许过期**：登记的类如果已经有了定义，要回来划掉。
    @Test func 豁免表里已经定义了的类要划掉() throws {
        let scan = try load()
        let stale = Self.containerOnly.keys.filter { scan.defined.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些类登记为「没有定义」，但现在**已经有定义了**：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """
        )
    }

    /// 豁免表的第三向：登记的类如果**已经没人用了**，也要回来划掉。
    ///
    /// 前两条只堵「登记了却有定义」（= 记账记错）；这一条堵「登记了但对象没了」
    /// —— 那种条目永远不会被任何断言碰到，只会**安静地烂在表里**。
    @Test func 豁免表里已经没人用的类要划掉() throws {
        let scan = try load()
        let stale = Self.containerOnly.keys.filter { !scan.used.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些类登记为「无样式容器」，但设计稿里**已经没有任何元素在用**它们：
            \(stale.sorted().joined(separator: ", "))
            要么把类也删掉，要么回来把这一条划掉 —— 留着它永远不会有人再看第二眼。
            """
        )
    }

    /// 反向（定义了但没元素用）的账本**第一向**：新出现的零消费者必须登记在案。
    ///
    /// 这一向此前**只打印**（§8.52.5 判据：零消费者 ≠ 可删）—— 但「不删」不等于「不记账」。
    /// 实测代价：手写清单三处不一致（§8.52.5 标题 18 / 表里 15 行 / §8.75.7 的 17），
    /// 而且 `meter--high` 那一行过期了整整一轮没人发现。
    @Test func 零消费者的类必须全在账本里() throws {
        let scan = try load()

        // 解析器的**锚**：下面几条不成立，说明扫描逻辑退化了，
        // 而那种情况下 `unused` 会**空着** —— 通过得毫无意义。
        #expect(scan.defined.count > 150, "只解析到 \(scan.defined.count) 个类 —— 定义那一向没扫到")
        #expect(scan.used.contains("btn"), "`.btn` 有 60+ 处消费者却没收集到 —— 使用那一向没扫到")
        #expect(
            scan.runtimeCreated.contains("pill"),
            "`ds.js` 的 `className = 'pill'` 没解析到 —— 运行时那一向没扫到（本轮修的就是这一步）")
        #expect(
            scan.pageLocal.contains("kbd"),
            "`.kbd` 只在 `01-main-window.html` 的 `<style>` 里定义，没识别出来 —— 「定义源有两个」漏了第二个")

        let unused = scan.defined.subtracting(scan.used).sorted()
        let ledger = Set(Self.pageLocalUnused.keys).union(Self.spareUnused.keys)
        let unregistered = Set(unused).subtracting(ledger).sorted()

        print("  [设计稿] 定义了但没元素用：\(unused.count) 个 —— \(unused.joined(separator: ", "))")

        #expect(
            unregistered.isEmpty,
            """
            设计稿里这些类**定义了但没有任何元素在用**，且不在账本里：
            \(unregistered.joined(separator: ", "))
            要么把它用起来，要么加进 `pageLocalUnused` / `spareUnused` 并写清定性
            —— 但**不要**为了让它消失就删掉：设计稿是规范文档，删类会改变视觉（§8.52.5）。
            若它是 `ds.js` 运行时创建的（消费者不在 HTML 里），应记进 `runtimeCreatedClasses`。
            """)
    }

    /// 账本**第二向**：登记的类如果已经有人用了 / 已经不存在了，要回来划掉。
    ///
    /// 两个方向都查，否则这张表会像 §8.33 那 6 条一样越积越不可信 ——
    /// `meter--high` 就是这么过期的：`5df286f` 给它补了样本，`06-states.html` 里
    /// 从此有元素用它，而 §8.52.5 的表里那一行**一直留着**。
    @Test func 账本里的类不许过期() throws {
        let scan = try load()
        let ledger = Set(Self.pageLocalUnused.keys).union(Self.spareUnused.keys)

        let nowUsed = ledger.intersection(scan.used).sorted()
        #expect(
            nowUsed.isEmpty,
            """
            这些类登记为「没有元素用」，但**现在已经有元素在用了**：\(nowUsed.joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            （`meter--high` 就是这么过期的：补了样本，清单没改。）
            """)

        let gone = ledger.subtracting(scan.defined).sorted()
        #expect(
            gone.isEmpty,
            """
            这些类登记在账本里，但**设计稿里已经没有任何定义了**：\(gone.joined(separator: ", "))
            定义都删了，这一条永远不会被任何断言碰到，只会安静地烂在表里 —— 划掉它。
            """)
    }

    /// 账本**第三向**：成因分类必须与实扫一致 —— 这是本轮最贵的一条判据。
    ///
    /// 三种成因的**消费者位置**不同，混在一起数就会算错账。实测三处数字打架
    /// （`18 / 17 / 15`）的根源就是没分：`langbar*` / `pill` 的消费者在 JS 里，
    /// 被当成「没人用」；`kbd` / `zoomwrap` 的消费者本该在页面里但没有；
    /// `sr-only` 是**有意**没有消费者。
    @Test func 账本的成因分类必须与实扫一致() throws {
        let scan = try load()

        // ① 「页面级备用」必须真的只在某页的 `<style>` 里定义
        for name in Self.pageLocalUnused.keys {
            #expect(
                scan.pageLocal.contains(name),
                "`\(name)` 记成「页面级备用」，但它不在「仅 `<style>` 定义」那一批里 —— 成因标错了")
        }

        // ② 「纯 ds.css 备用」不许是运行时创建、也不许只在 `<style>` 里
        for name in Self.spareUnused.keys {
            #expect(
                !scan.runtimeCreated.contains(name),
                "`\(name)` 记成「纯 ds.css 备用」，但 `ds.js` 会在运行时创建它 —— 那它**有消费者**，不该在这张表里")
            #expect(
                !scan.pageLocal.contains(name),
                "`\(name)` 记成「纯 ds.css 备用」，但它只在某个页面的 `<style>` 里定义 —— 应记进 `pageLocalUnused`")
        }

        // ③ 「运行时创建」那批必须**真的被算成消费者**
        //
        // ⚠️ 这条是**负向锚**：`load()` 若退回只认双引号（本轮修掉的那个病），
        // 这 4 个类会立刻掉进 `unused` —— 那时这条与上一条会一起红。
        for name in Self.runtimeCreatedClasses.keys {
            #expect(scan.runtimeCreated.contains(name), "`\(name)` 没被识别成「运行时创建」")
            #expect(
                scan.used.contains(name),
                "`\(name)` 由 `ds.js` 在运行时创建，却**没被算成消费者** —— `load()` 第 ③ 步又断了（本轮修的正是这一步）")
            #expect(
                !Self.pageLocalUnused.keys.contains(name) && !Self.spareUnused.keys.contains(name),
                "`\(name)` 有消费者（`ds.js` 运行时创建），却被同时记进「零消费者」表 —— 两处口径串了")
        }
    }

    /// **新的一向**：`ds.js` 运行时创建的类必须在设计稿里有 CSS 定义。
    ///
    /// 这一向此前**没有任何守卫**，而它的症状是最难发现的那种：
    /// JS 建出来的元素类名**不在任何 HTML 里**，所以「用了但没定义」那一向
    /// （扫 `class="…"`）**永远看不见它** —— 元素会**裸奔**，
    /// 而「样式丢了」与「本来就没写样式」在渲染结果上逐字相同。
    ///
    /// 实测：`ds.css` 里 `.pill` 曾有过一条关键注释（2026-09-16 补的
    /// 「`ds.js` 水合出来的 `<svg>` 没有内联宽高，没有这条规则时计算尺寸是 `0×0`」）
    /// —— 那正是这一向的病例。
    @Test func ds_js运行时创建的类必须在设计稿里有定义() throws {
        let scan = try load()

        // 锚：解析器坏了会让 `runtimeCreated` 空着，下面的差集会空着通过
        #expect(scan.runtimeCreated.count >= 4, "只解析到 \(scan.runtimeCreated.count) 个运行时类 —— JS 没读到")

        let ledger = Set(Self.runtimeCreatedClasses.keys)
        #expect(
            scan.runtimeCreated == ledger,
            """
            `ds.js` 运行时创建的类与账本不一致：
              实扫到而账本没有：\(scan.runtimeCreated.subtracting(ledger).sorted().joined(separator: ", "))
              账本有而实扫没有：\(ledger.subtracting(scan.runtimeCreated).sorted().joined(separator: ", "))
            两边都要对上 —— 少一边就会把「有消费者的类」当成「没人用」。
            """)

        let undefine = scan.runtimeCreated.subtracting(scan.defined).sorted()
        #expect(
            undefine.isEmpty,
            """
            `ds.js` 会在运行时创建这些类，但设计稿里**没有任何 CSS 定义**：
            \(undefine.joined(separator: ", "))
            建出来的元素会**裸奔**。注意「用了但没定义」那一向**查不到这个** ——
            它扫的是 HTML 的 `class` 属性，而这些类名根本不在 HTML 里。
            """)
    }

    // MARK: 图标

    /// 设计稿里**用了但图标表里没有**的名字，必须为零 —— 一个都不许有。
    ///
    /// 为什么这一向比另一向重要得多：`ds.js` 的 `build(name)` 里是
    /// `var body = I[name]; if (!body) return '';` —— **名字写错就返回空串**。
    /// 于是 `<i data-i="ejct">` 渲染出来**什么都没有**，而
    /// **「图标是空白」与「这块本来就没放图标」在界面上逐字相同**，读 HTML 看不出来。
    @Test func 用了但图标表里没有的名字一个都不许有() throws {
        let (defined, used) = try loadIcons()
        // 解析器的**锚**：图标表要是没解析到，下面的差集会空着，通过得毫无意义
        #expect(defined.count > 25, "只解析到 \(defined.count) 个图标 —— 图标表没读到")
        #expect(defined.contains("eject"), "`eject` 都没解析到 —— 图标表结构变了？")
        #expect(used.contains("eject"), "`eject` 明明在用却没收集到 —— data-i 的扫描坏了")

        let missing = used.subtracting(defined)
        #expect(
            missing.isEmpty,
            """
            这些图标名被 `<i data-i="…">` 用着，但 `ds.js` 的图标表里**没有**：
            \(missing.sorted().joined(separator: ", "))
            `build()` 对未知名字返回**空串** ⇒ 这些位置渲染出来是**空白**，
            而「图标是空白」与「本来就没放图标」长得一模一样。
            """
        )
    }

    /// 图标表里**定义了但没用**的名字 —— 只打印。
    ///
    /// 图标表是**库**（和 `ds.css` 一样是组件库），**库里允许有存货**；
    /// i18n 文案是**内容**，内容不允许有孤儿。判据见 §8.54.2。
    @Test func 图标表里的存货只记录不报警() throws {
        let (defined, used) = try loadIcons()
        let spare = defined.subtracting(used).sorted()
        print("  [设计稿] 图标表存货：\(spare.count) 个 —— \(spare.joined(separator: ", "))")
        #expect(!spare.isEmpty, "一个存货都没有 —— 「定义」那一向多半没扫到")
        #expect(spare.count < defined.count / 2, "存货超过一半 —— 解析多半出了问题")
    }

    // MARK: i18n

    /// `i18n-extra.json` 里**声明了但没有页面在用**的键 —— 死文案，登记在案。
    ///
    /// 与 CSS 类**不同**：删掉一个没用的文案键**不改变任何渲染**，所以这一向是
    /// 「零消费者 = 可删」。但仍然**登记而不是立刻删** —— 因为有些是
    /// 「备着给还没画的样本用的」，那是设计决策，不该由扫描器替人决定（§8.52.5 同理）。
    ///
    /// ⚠️ **已清空**（§8.68）：原先唯一一条 `ds.sample.cap.usedFreeC` 在那一轮给
    /// 2 TB 那块盘接上了 `data-i18n`（它本就是界面里「已用 1.4 TB · 剩余 600 GB」那一行的文案，
    /// 只是**忘了接线**，不是没有样本）。⇒ 表空了，但**别删这张表**：
    /// 下次再出现死文案，登记进来比直接删键安全（删键是设计决策，不由扫描器替人决定）。
    private static let unusedI18nKeys: [String: String] = [:]

    /// 声明了但没页面在用的文案键，必须全在豁免表里。
    @Test func 声明了但没有页面在用的文案键必须登记在案() throws {
        let (declared, referenced) = try loadI18n()
        // 解析器的**锚**
        #expect(declared.count > 30, "只解析到 \(declared.count) 个键 —— i18n-extra.json 没读到")
        #expect(
            declared.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 都没解析到 —— 键名格式变了？")
        #expect(
            referenced.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 明明被 02-menu-bar 用着却没收集到 —— 消费源扫错了")

        let dead = declared.subtracting(referenced).subtracting(Self.unusedI18nKeys.keys)
        #expect(
            dead.isEmpty,
            """
            这些文案键在 `i18n-extra.json` 里声明了，但**没有任何页面在用**（死文案）：
            \(dead.sorted().joined(separator: ", "))
            要么给它找一个 `data-i18n` 消费者，要么把键删掉 —— 留着它永远不会有人再看第二眼。
            """
        )
    }

    /// 豁免表**不许过期**：登记为「没人用」的键如果已经有页面在用了，要回来划掉。
    @Test func 已登记的文案键如果有页面在用了要划掉() throws {
        let (_, referenced) = try loadI18n()
        let stale = Self.unusedI18nKeys.keys.filter { referenced.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些键登记为「没有页面在用」，但现在已经**有消费者**了：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """
        )
    }

    /// 页面**引用了但声明集里没有**的键 —— 静默回退，一个都不许有。
    ///
    /// `Tools/build_i18n.py` 的注释自己写着：「抄漏一条不会报错，只会在切到那门语言时
    /// **静默回退成中文** —— 而『回退』和『翻好了』长得一模一样」。
    /// 声明集是 **`i18n-extra.json` ∪ `Localizable.xcstrings`**（设计稿可以引用产品已有文案）。
    @Test func 页面引用了但没有声明的文案键一个都不许有() throws {
        let (_, referenced) = try loadI18n()
        let declared = try Self.declaredTextKeys(repoRoot: repoRoot)
        #expect(declared.count > 150, "只解析到 \(declared.count) 个键 —— xcstrings 没读到")
        #expect(
            declared.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 不在声明集里 —— xcstrings / i18n-extra 都没读到")

        let missing = referenced.subtracting(declared)
        #expect(
            missing.isEmpty,
            """
            这些 `data-i18n` 引用的键**在任何一处都没有声明**：
            \(missing.sorted().joined(separator: ", "))
            切到英文/繁体时会**静默回退成中文** —— 和「翻好了」长得一模一样。
            """
        )
    }

    /// **生成物与源必须同步**：改了源忘了重跑 `Tools/build_i18n.py`，`i18n.js` 就是旧的。
    ///
    /// 这一向才贵：**加了键忘了重跑** ⇒ 切到英文时设计稿**静默回退成中文**，
    /// 而「回退」和「翻好了」在界面上长得一模一样 —— `build_i18n.py` 的头注释自己写着这句。
    ///
    /// 实测已经抓到过一次（§8.48 那轮）：从 `xcstrings` 删掉 2 个键后源是 156 条，
    /// 而**已提交的 `i18n.js` 里那 2 个键还在**（3 门语言 × 2 = 6 行），
    /// 文件时间戳甚至比源还旧 —— 生成步骤被跳过了，谁也没发现。
    ///
    /// 守的办法是**源指纹**，不是在测试里跑一遍 python：
    /// 环境无关（不要求机器上有 python、不起进程），且**任一方变了必然红**。
    @Test func 生成物i18njs的源指纹必须与源一致() throws {
        let jsURL = designRoot.appendingPathComponent("assets/i18n.js")
        let js = try read(jsURL)

        // 锚 ①：指纹行**必须解析得到**。找不到就红，绝不静默放过 ——
        // 万一头部格式改了而正则没跟上，它会「永远绿」，那种绿比不测更糟（§8.55.5）。
        let embedded = try #require(
            Self.matches(in: js, pattern: #"源指纹\s+([0-9a-f]{64})"#).first,
            """
            \(jsURL.lastPathComponent) 头部找不到「源指纹 <64 位 hex>」。
            要么没跑过 `python3 Tools/build_i18n.py`，要么头部格式改了而这里的正则没跟上。
            """)

        let expected = try Self.sourceFingerprint(repoRoot: repoRoot)

        #expect(
            embedded == expected,
            """
            \(jsURL.lastPathComponent) 与源**不同步**：
              文件里  \(embedded.prefix(16))…
              源算得  \(expected.prefix(16))…
            源（Localizable.xcstrings / i18n-extra.json / build_i18n.py）有一方改过了 —— 重跑：
                python3 Tools/build_i18n.py
            并把新生成的 i18n.js 一起提交（它是生成物，但必须入库）。
            """)
    }

    // MARK: 语言包内部（§8.65）

    /// 生成物 `i18n.js` 里的**语言包本体**（`window.DS_L10N = { … };`），按语言取键值表。
    ///
    /// ⚠️ 读的是**生成物**而不是 `i18n-extra.json`：想知道「英文那一列到底有没有值」，
    /// 只能看生成物 —— `extra.json` 里写了，不代表 `build_i18n.py` 抄进去了。
    /// 与上面「源指纹」那条互补：**它**守「生成物是不是旧的」，**这一组**守
    /// 「生成物**内部**三门语言对不对得上」。
    private func loadLanguagePack() throws -> [String: [String: String]] {
        let js = try read(designRoot.appendingPathComponent("assets/i18n.js"))
        let marker = "window.DS_L10N = "
        guard let start = js.range(of: marker)?.upperBound,
            let tail = js.range(of: "\n};", range: start..<js.endIndex)?.lowerBound
        else {
            Issue.record("i18n.js 里解析不到语言包（`window.DS_L10N = {` … `\\n};`）")
            return [:]
        }
        // `tail` 指向 `};` 前的换行；往回一步是外层收尾的那个 `}`。
        let json = String(js[start...js.index(tail, offsetBy: 1)])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let pack = obj as? [String: [String: String]]
        else {
            Issue.record("语言包不是 [语言: [键: 值]] —— 生成脚本的输出格式变了？")
            return [:]
        }
        return pack
    }

    /// 三门语言的**键集合必须完全一致**。
    ///
    /// 缺一个键 ⇒ 切到那门语言时 `t()` 取不到 ⇒ **静默回退成中文**（ds.js 的回退链），
    /// 而「回退」与「翻好了」在界面上**长得一模一样** —— 这是本仓库反复出现的同一类病。
    /// 现有两条 i18n 守卫看的是**键在不在声明集里**，不看「每一门语言都齐不齐」。
    @Test func 三门语言的键集合必须完全一致() throws {
        let pack = try loadLanguagePack()
        let langs = pack.keys.sorted()
        // 锚：三门语言都得解析到，否则「差集为空」只是「两边都是空」
        #expect(langs.count >= 3, "只解析到 \(langs) 门语言 —— 语言包结构变了？")
        guard let first = langs.first else {
            Issue.record("语言包一门语言都没解析到")
            return
        }
        let base = Set(pack[first, default: [:]].keys)
        #expect(base.count > 150, "只有 \(base.count) 个键 —— 语言包没读全")

        var problems: [String] = []
        for lang in langs.dropFirst() {
            let keys = Set(pack[lang, default: [:]].keys)
            let missing = base.subtracting(keys).sorted()
            let extra = keys.subtracting(base).sorted()
            if !missing.isEmpty {
                problems.append(
                    "\(lang) 缺 \(missing.count) 个键：\(missing.prefix(5).joined(separator: ", "))…")
            }
            if !extra.isEmpty {
                problems.append(
                    "\(lang) 多 \(extra.count) 个键：\(extra.prefix(5).joined(separator: ", "))…")
            }
        }
        #expect(
            problems.isEmpty,
            """
            三门语言的键集合对不上：
            \(problems.joined(separator: "\n  "))
            缺的那个键会**静默回退成中文** —— 界面上看不出「没翻」，只看得出「还是中文」。
            """)
    }

    /// **样本文案**在各语言下的数字必须逐字一致。
    ///
    /// 这条是 `i18n-extra.json` 头注释里**明写**的约定：
    /// 「`ds.sample.<...>` 走查用的样本数据（磁盘名、容量数字、版本号），
    ///   各语言数字必须一致，否则走查图对不上」。
    /// ⇒ 约定写下来了，但没有判据 —— 这正是 §8.45「有能力、没接线」那一族：
    /// **明写的规则没人执行，和没写一样。**
    @Test func 样本文案在各语言下的数字必须一致() throws {
        let pack = try loadLanguagePack()
        guard let first = pack.keys.sorted().first, let table = pack[first] else { return }
        let samples = table.keys.filter { $0.hasPrefix("ds.sample.") }.sorted()
        #expect(samples.count >= 5, "只有 \(samples.count) 个样本键 —— 前缀约定改了？")

        var problems: [String] = []
        for key in samples {
            var perLang: [String: String] = [:]
            for (lang, t) in pack {
                // ⚠️ `matches` 固定取**捕获组 1**：写 `(?:…)` 这种非捕获组 ⇒
                // `range(at: 1)` 越界 ⇒ NSException（进程直接 abort，不是测试失败）。
                let nums = Self.matches(in: t[key] ?? "", pattern: #"(\d+(?:\.\d+)?)"#)
                perLang[lang] = nums.joined(separator: "|")
            }
            let distinct = Set(perLang.values)
            if distinct.count > 1 {
                let detail = perLang.keys.sorted().map { "\($0)=[\(perLang[$0] ?? "")]" }
                    .joined(separator: "  ")
                problems.append("\(key)：\(detail)")
            }
        }
        #expect(
            problems.isEmpty,
            """
            样本数据在各语言下数字不一致：
            \(problems.joined(separator: "\n  "))
            走查图是逐语言各出一套的 —— 数字对不上，两门语言的图就**不是同一个盘**，
            比完以为是自己改坏了。约定见 `i18n-extra.json` 头注释。
            """)
    }

    /// 语言包里**不许有空值**。
    ///
    /// 空串与「这一行本来就没有文字」在渲染结果上**逐字相同** ——
    /// 界面上就是一个空白位置，谁也不会想到是翻译漏了。
    @Test func 语言包里不许有空值() throws {
        let pack = try loadLanguagePack()
        var problems: [String] = []
        for (lang, table) in pack {
            let empty = table.filter { $0.value.isEmpty }.keys.sorted()
            if !empty.isEmpty {
                problems.append("\(lang)：\(empty.joined(separator: ", "))")
            }
        }
        #expect(
            problems.isEmpty,
            """
            语言包里有空值：
            \(problems.joined(separator: "\n  "))
            空串渲染出来就是一个**空白位置**，和「这行本来就没有文字」一模一样。
            """)
    }

    /// 英文那一列**不许出现中文字符**（漏翻）。
    ///
    /// 与「键在不在」互补：键在、值也在、但值**就是中文** ——
    /// `t()` 取得到，回退链根本不触发，界面上完全正常，**只有切到英文才看得见**，
    /// 而走查时没人会逐条切一遍。
    ///
    /// ⚠️ 判据之所以能这么硬：实测英文列 **0 处**含 CJK，不存在「本来就该留中文」的例外。
    @Test func 英文文案里不许出现中文字符() throws {
        let pack = try loadLanguagePack()
        guard let en = pack["en"] else {
            Issue.record("语言包里没有英文列")
            return
        }
        // 负向锚：英文列是空的 ⇒ 下面「0 处漏翻」只是「没扫到任何东西」
        #expect(en.count > 150, "英文列只有 \(en.count) 个键 —— 没读全")
        let han = en.filter { _, value in
            value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }.keys.sorted()
        #expect(
            han.isEmpty,
            """
            英文列里出现了中文字符（漏翻）：\(han.joined(separator: ", "))
            键在、值也在 ⇒ 回退链**不会触发**，界面上看不出任何异常 ——
            只有切到英文才会发现那一行还是中文。
            """)
    }

    // MARK: 文案值里的 HTML（§8.66）

    private struct HtmlTag {
        var name: String
        var closing: Bool
        var attrs: String
    }

    /// 文案**值里**允许出现的标签 —— `i18n.js` 头注释里明写的清单。
    private static let allowedValueTags: Set<String> = ["b", "code", "br", "i"]

    /// 空元素（不成对，`<br>` / `<br/>` 都算）。
    private static let voidTags: Set<String> = ["br"]

    /// HTML 里的空元素（解析器不把它们压栈）。
    ///
    /// ⚠️ 与 `voidTags` 不是一回事：那个是**文案值里**允许的空元素，这个是**整份 HTML** 里的。
    private static let htmlVoidTags: Set<String> = [
        "br", "img", "meta", "link", "input", "hr", "source",
        "path", "circle", "rect", "use", "stop", "line", "polyline", "polygon", "ellipse",
    ]

    /// 设计稿**说明区 / chrome** 的类名 —— 这些区域里的中文不翻（§8.69.7 口径）。
    ///
    /// ⚠️ 必须是**完整类名**：用子串 `doc__` 会把 `doc__section`（整页外衣，8 页全有）
    /// 也算成说明区 ⇒ UI 稿整体被豁免 ⇒ 守卫 56 对所有界面文案失效（实测：旧口径假绿）。
    ///
    /// ⚠️ **2026-09-19（§8.75）扩了 3 个词**（`spec` / `toolbar` / `swatchcard`）——
    /// 扫描范围从 `screens/` 扩到 `htmlFiles()` 之后，`index.html` 里这些**设计规范页自己的
    /// chrome**（规格表 `<table class="spec">`、右上角工具条、色卡）会被当成漏接。
    /// 实测这三个词**只**出现在总览页 + `07-dark.html` 的色卡（都是 chrome），
    /// 加进来不会把任何界面文案豁免掉（加之前/之后，`screens/` 的漏接数都是 0）。
    private static let noteClassTokens: Set<String> = [
        "spec-note", "note-list", "state-tbl", "framecap", "legend", "frame__label",
        "doc__h2", "doc__h3", "doc__lede", "doc__title", "doc__eyebrow", "doc__h2desc",
        "doc__nav",
        // 设计规范页（`index.html`）的 chrome —— 规格表 / 工具条 / 色卡
        "spec", "toolbar", "swatchcard",
    ]

    private static func isNoteClass(_ cls: String?) -> Bool {
        guard let cls else { return false }
        return Set(cls.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
            .intersection(noteClassTokens).isEmpty == false
    }

    /// 给人看的**文案属性** —— 它们不参与 `innerHTML` 回填，只能靠 `data-i18n-attr` 翻。
    private static let textAttrs: Set<String> = ["title", "aria-label", "placeholder", "alt"]

    /// 属性文案的豁免表：这些值**故意不翻**（键是值本身，理由写在 value 里）。
    ///
    /// ⚠️ 曾是「含样本磁盘名」4 条（`关闭并推出 Samsung T7` …）：对应键带 `%@`，
    /// 而 `ds.js` 当初**不做插值** ⇒ 接上去会被念成「百分号 at」。
    /// 现已支持 `data-i18n-args` 插值（§8.70.2），那 4 条**已接线并移出本表**。
    private static let attrAllowlist: [String: String] = [
        "SafeOut 主窗口，列出三块外置磁盘": "画框说明（同 frame__label），属设计稿 chrome",
        "菜单栏弹出面板，列出两块外置磁盘": "画框说明（同 frame__label），属设计稿 chrome",
    ]

    /// 解析文案值里的 HTML 标签。
    ///
    /// ⚠️ 只认 `<tag …>` / `</tag>` / `<tag/>` 这一种写法 —— 文案是**手写**的，
    /// 不会有注释、不会有 `<script>`；真要去解析完整 HTML 就得换 XMLParser，
    /// 而 HTML 不是合法 XML（`<br>` 不闭合、实体未声明），换过去只会更糟。
    private func tags(in value: String) -> [HtmlTag] {
        guard let re = try? NSRegularExpression(pattern: #"<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>"#)
        else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return re.matches(in: value, range: range).compactMap { m in
            guard let slash = Range(m.range(at: 1), in: value),
                let name = Range(m.range(at: 2), in: value),
                let attrs = Range(m.range(at: 3), in: value)
            else { return nil }
            return HtmlTag(
                name: String(value[name]).lowercased(),
                closing: !value[slash].isEmpty,
                attrs: String(value[attrs]))
        }
    }

    /// 文案值里的 HTML 标签**必须闭合**。
    ///
    /// 值是被 `innerHTML` 回填的 ⇒ 少了 `</b>` 时浏览器**不报错**，
    /// 只是把这个元素**后面所有的文字都变粗** —— 症状在**别处**，
    /// 谁也不会想到是那一条文案少写了个结束标签。
    @Test func 文案值里的HTML标签必须闭合() throws {
        let pack = try loadLanguagePack()
        var problems: [String] = []
        var scanned = 0
        var sawBold = false
        for (lang, table) in pack {
            for (key, value) in table.sorted(by: { $0.key < $1.key }) {
                guard value.contains("<") else { continue }
                scanned += 1
                var stack: [String] = []
                for tag in tags(in: value) {
                    if tag.name == "b" { sawBold = true }
                    if tag.closing {
                        if Self.voidTags.contains(tag.name) { continue }
                        if stack.last != tag.name {
                            problems.append(
                                "[\(lang)] \(key)：</\(tag.name)> 对不上 \(stack.last.map { "<\($0)>" } ?? "空")")
                        } else {
                            stack.removeLast()
                        }
                    } else if !Self.voidTags.contains(tag.name) {
                        stack.append(tag.name)
                    }
                }
                if !stack.isEmpty {
                    problems.append(
                        "[\(lang)] \(key)：未闭合 \(stack.map { "<\($0)>" }.joined(separator: " "))")
                }
            }
        }
        // 锚：扫到的含标签值不能太少，且必须见过 `<b>`（白名单里最常见的那个）
        #expect(scanned >= 5, "只扫到 \(scanned) 条含标签的文案 —— 解析口径失效")
        #expect(sawBold, "一条 `<b>` 都没扫到 —— 标签解析口径失效（假绿）")
        #expect(
            problems.isEmpty,
            """
            文案值里的 HTML 标签不闭合：
            \(problems.joined(separator: "\n  "))
            值是按 **innerHTML** 回填的 ⇒ 少了 `</b>` 浏览器**不报错**，
            只是把它**后面所有文字都变粗** —— 症状出现在别处，很难想到是这条文案写漏了。
            """)
    }

    /// 文案值里的标签**必须在允许清单内**，且 `<i>` 必须带 `data-i`。
    ///
    /// 头注释写着「值里允许 HTML（`<b>` / `<code>` / `<br>` / `<i data-i="gear">`）」——
    /// 又是一条**明写却没有判据**的约定（§8.65.2 同族）。
    ///
    /// `<i>` 那条更具体：图标靠 `data-i` 水合，**没有 `data-i` 的 `<i>` 就是一段斜体字** ——
    /// 与 §8.45「有能力、没接线」同族：结构有了，接上标识才算数。
    @Test func 文案值里的HTML标签必须在允许清单内() throws {
        let pack = try loadLanguagePack()
        var problems: [String] = []
        for (lang, table) in pack {
            for (key, value) in table.sorted(by: { $0.key < $1.key }) {
                for tag in tags(in: value) {
                    if !Self.allowedValueTags.contains(tag.name) {
                        problems.append("[\(lang)] \(key)：不允许的标签 <\(tag.name)>")
                    }
                    if tag.name == "i", !tag.closing, !tag.attrs.contains("data-i") {
                        problems.append("[\(lang)] \(key)：<i> 没有 data-i —— 水合时找不到图标名")
                    }
                }
            }
        }
        #expect(
            problems.isEmpty,
            """
            文案值里出现了允许清单之外的标签：
            \(problems.joined(separator: "\n  "))
            允许的是 `<b>` / `<code>` / `<br>` / `<i data-i="…">`（见 i18n.js 头注释）。
            值是用 **innerHTML** 回填的 —— 多写一个块级标签就会把那一行的行内布局顶开。
            """)
    }

    // MARK: 跨语言结构（§8.67）

    /// 格式占位符：`%@` / `%d` / `%.0f` / `%1$@` …
    private static let placeholderPattern = #"(%(?:\d+\$)?(?:\.\d+)?[@dfslqSDF])"#

    /// 各语言的**格式占位符序列**必须一致。
    ///
    /// 这是语言包里**后果最重**的一类漂移：实现侧是 `String(format:)`，
    /// 占位符少一个 ⇒ 参数对不上 ⇒ **运行时可能直接崩**（`%d` 接到字符串），
    /// 而不是「显示得不好看」。翻译时漏掉或调换一个 `%@` 太容易了。
    ///
    /// 与 §8.65「样本数字一致」不同：那条只管 `ds.sample.*` 的**内容**，
    /// 这条管**任意键**的**结构**，且覆盖所有三门语言。
    @Test func 各语言的格式占位符必须一致() throws {
        let pack = try loadLanguagePack()
        guard !pack.isEmpty else {
            Issue.record("语言包一门语言都没解析到")
            return
        }
        // ⚠️ 键集合必须取**各语言的并集**，不能只按某一门语言筛。
        // 否则那门语言把占位符一删 ⇒ 这个键**自己从被检集合里消失** ⇒ 变异反而变绿
        // （实测 M89：删掉英文的 `%@`，判成绿 —— 判据把变异藏起来了）。
        // 与 §8.61.2「扫描看不见『该写的没写』」同源，只是这次是判据自身的盲区。
        let keys = Set(pack.values.flatMap { $0.keys }).filter { key in
            pack.values.contains {
                !Self.matches(in: $0[key] ?? "", pattern: Self.placeholderPattern).isEmpty
            }
        }.sorted()
        // 锚：含占位符的键不能太少，且必须见过 `%@`（最常见的那个）
        #expect(keys.count >= 20, "只有 \(keys.count) 个键含占位符 —— 匹配口径失效")
        let allPlaceholders = keys.flatMap { key in
            pack.values.flatMap {
                Self.matches(in: $0[key] ?? "", pattern: Self.placeholderPattern)
            }
        }
        #expect(
            allPlaceholders.contains("%@"), "一个 `%@` 都没扫到 —— 占位符口径失效（假绿）")

        var problems: [String] = []
        for key in keys {
            var perLang: [String: String] = [:]
            for (lang, t) in pack {
                perLang[lang] =
                    Self.matches(in: t[key] ?? "", pattern: Self.placeholderPattern)
                    .joined(separator: " ")
            }
            if Set(perLang.values).count > 1 {
                let detail = perLang.keys.sorted().map { "\($0)=[\(perLang[$0] ?? "")]" }
                    .joined(separator: "  ")
                problems.append("\(key)：\(detail)")
            }
        }
        #expect(
            problems.isEmpty,
            """
            同一条文案在各语言下的**占位符**对不上：
            \(problems.joined(separator: "\n  "))
            实现侧是 String(format:) —— 少一个 `%@` 就是**参数个数不匹配**，
            轻则显示错乱、重则运行时崩溃，而不是「翻得不好看」。
            """)
    }

    /// 各语言的 **HTML 标签结构**必须一致（`<b>` 强调在哪儿，各语言都得有）。
    ///
    /// 中文加了 `<b>` 强调、英文忘了 ⇒ 那门语言**重点丢了**，
    /// 而文案本身是翻好的 —— 没人会盯着「这一门语言少了个加粗」看。
    /// 与 §8.66 不同：那条是**单语言内**的合法性与闭合，这条是**跨语言**的结构一致。
    @Test func 各语言的HTML标签结构必须一致() throws {
        let pack = try loadLanguagePack()
        guard !pack.isEmpty else {
            Issue.record("语言包一门语言都没解析到")
            return
        }
        // 同上的并集口径（实测 M91：删掉英文的 `<b>`，键从集合里消失 ⇒ 判成绿）
        let keys = Set(pack.values.flatMap { $0.keys }).filter { key in
            pack.values.contains { ($0[key] ?? "").contains("<") }
        }.sorted()
        // 锚：含标签的键不能太少（现状 5 个）
        #expect(keys.count >= 3, "只有 \(keys.count) 个键含标签 —— 匹配口径失效")

        var problems: [String] = []
        for key in keys {
            var perLang: [String: String] = [:]
            for (lang, t) in pack {
                perLang[lang] = tags(in: t[key] ?? "").map { $0.name }.joined(separator: ",")
            }
            if Set(perLang.values).count > 1 {
                let detail = perLang.keys.sorted().map { "\($0)=[\(perLang[$0] ?? "")]" }
                    .joined(separator: "  ")
                problems.append("\(key)：\(detail)")
            }
        }
        #expect(
            problems.isEmpty,
            """
            同一条文案在各语言下的**标签结构**对不上：
            \(problems.joined(separator: "\n  "))
            中文加了 `<b>` 而英文没有 ⇒ 那门语言的**重点丢了**，
            而文案本身是翻好的 —— 逐条看很难发现。
            """)
    }

    // MARK: 界面文案漏接（§8.68）

    private struct ElementText {
        var text: String
        var key: String?  // data-i18n
        var note: Bool  // 在设计说明区内（说明区的中文不翻，不参与判定）
        var suppressed: Bool  // 自身、祖先或后代已接线
        /// 祖先里**还挂着** `data-i18n`（不含「祖先是说明区」）。
        ///
        /// 这一种是**有害**的：父元素回填时整块 `innerHTML` 覆盖 ⇒ 本元素连同它的
        /// 标签、样式、图标一起消失，本元素自己的键**永远不会被应用**（§8.69）。
        var ancestorWired: Bool
        /// 后代里出现过的标签名。
        ///
        /// 回填是整块覆盖 ⇒ 值里没有的标签会被**静默丢掉**（`<i data-i>` 图标 / `<b>` /
        /// `<strong>` / 整个 `<button>`）。
        var childTags: Set<String>
    }

    /// 极简 HTML 扫描：把文本**累积到栈上每一个元素**，弹出时给出「元素整文本」。
    ///
    /// 为什么必须拿**整文本**：`已用 <b>300 GB</b> · 剩余 <b>700 GB</b>` 这种，
    /// 文本被 `<b>` 切成好几段 —— 只看单段永远对不上语言包里的整句。
    /// （首版按「单个文本片段」比对 ⇒ 01/07 的容量行**一处都没扫到**。）
    ///
    /// ⚠️ 只支持设计稿这种手写 HTML：没有注释、`screens/` 下没有内联 `<script>`。
    /// 换 `XMLParser` 反而更糟 —— **HTML 不是合法 XML**。
    private func elementTexts(in html: String) -> [ElementText] {
        struct Node {
            var tag: String
            var attrs: [String: String]
            var text = ""
            var descWired = false  // 后代里已经有人接线 ⇒ 祖先不必再报
            var childTags: Set<String> = []
        }
        // ⚠️ `frame__label` 是**画框标签**（「800 × 520 · …」），属设计稿 chrome，不翻。
        // ⚠️ **没有** `dim`：那是**弹窗遮罩层**（`<div class="dim">` 包着整个 alert），
        // 把它当说明区 ⇒ 所有弹窗内容被豁免，守卫对弹窗**完全失效**（实测 M95 假绿）。
        // 类名有歧义时（dim 既可指遮罩也可指次要文字），宁可**不豁免** ——
        // 漏报比误报危险：误报会被人看见，漏报不会。
        // ⚠️ 同理**不能用子串**（`doc__` vs `doc__section`）—— 详见 `noteClassTokens`。
        func isNote(_ cls: String?) -> Bool { Self.isNoteClass(cls) }
        let voids = Self.htmlVoidTags
        var stack: [Node] = []
        var out: [ElementText] = []
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<" {
                guard let gt = html[i...].firstIndex(of: ">") else { break }
                var inner = String(html[html.index(after: i)..<gt])
                i = html.index(after: gt)
                if inner.hasPrefix("!") { continue }  // 注释 / DOCTYPE
                let closing = inner.hasPrefix("/")
                if closing { inner.removeFirst() }
                let selfClosing = inner.hasSuffix("/")
                if selfClosing { inner.removeLast() }
                let name =
                    inner.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if closing {
                    guard let idx = stack.lastIndex(where: { $0.tag == name }) else { continue }
                    // ⚠️ 两种「祖先」要分开算：**祖先接线** 与 **祖先是说明区** ——
                    // 后者只是不参与判定，前者会让本元素的接线**失效**（§8.69）。
                    let strictWired = stack[..<idx].contains { $0.attrs["data-i18n"] != nil }
                    let ancestorWired =
                        strictWired || stack[..<idx].contains { isNote($0.attrs["class"]) }
                    // ⚠️ 后代标签要**在后代关闭时往上送**，不能等父关闭时再来收集 ——
                    // 那时后代早就出栈了（首版写成后者 ⇒ `childTags` 恒为空，扫出 0 处）。
                    if idx > 0 {
                        for k in idx..<stack.count {
                            stack[idx - 1].childTags.insert(stack[k].tag)
                            stack[idx - 1].childTags.formUnion(stack[k].childTags)
                        }
                    }
                    for k in idx..<stack.count {
                        let n = stack[k]
                        out.append(
                            ElementText(
                                text: n.text,
                                key: n.attrs["data-i18n"],
                                note: isNote(n.attrs["class"]) || ancestorWired,
                                suppressed: ancestorWired || n.descWired
                                    || n.attrs["data-i18n"] != nil,
                                ancestorWired: strictWired,
                                childTags: n.childTags))
                    }
                    // 往上传递：本元素（或其后代）已接线 ⇒ 祖先不必再报
                    let wired =
                        stack[idx...].contains { $0.attrs["data-i18n"] != nil }
                        || stack[idx...].contains { $0.descWired }
                    stack.removeSubrange(idx...)
                    // ⚠️ 必须是 **||=**：兄弟元素（无 data-i18n）弹出时会把祖先的标记**清掉**
                    // ⇒ 祖先又被当成没接线（实测：05-settings 的开关行假红 4 处）。
                    if let last = stack.indices.last { stack[last].descWired = stack[last].descWired || wired }
                    continue
                }
                // ⚠️ 空元素**永不关闭** ⇒ 它不会走上面的「后代关闭时往上送」那条路，
                // 标签名就**永远进不了**父元素的 `childTags` —— 必须当场送（首版整段跳过
                // ⇒ `<br>` 从不参与判定：值里有 `<br>` 而源码没有也扫不出来，守卫 60 对
                // 换行**完全失效**）。
                // ⚠️ 只送**可能出现在文案值里**的那几个（`br`）：`voids` 里还有
                // `path`/`circle` 这些内联 SVG 标签 —— 它们进 `childTags` 会让守卫 59
                // 满屏假红（值里当然没有 `<path>`）。
                if !selfClosing, voids.contains(name) {
                    if let last = stack.indices.last, Self.allowedValueTags.contains(name) {
                        stack[last].childTags.insert(name)
                    }
                    continue
                }
                if !selfClosing, !name.isEmpty {
                    var attrs: [String: String] = [:]
                    for pair in Self.attrPairs(in: inner) { attrs[pair.0] = pair.1 }
                    stack.append(Node(tag: name, attrs: attrs))
                }
                continue
            }
            let next = html[i...].firstIndex(of: "<") ?? html.endIndex
            let piece = String(html[i..<next])
            // `<script>` / `<style>` 里的文本不当文案
            let inRaw = stack.contains { ["script", "style"].contains($0.tag) }
            if !inRaw { for k in stack.indices { stack[k].text += piece } }
            i = next
        }
        return out
    }

    /// 取标签里的 `名="值"` 对。
    private static func attrPairs(in inner: String) -> [(String, String)] {
        // ⚠️ 属性名里有**数字**（`data-i18n`、`data-i`）：写成 `[a-zA-Z-]+` 会漏掉它们
        // ⇒ `data-i18n` 解析不出来 ⇒ 已接线的元素被当成没接线（本轮首跑 `wired → 0`）。
        guard let re = try? NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9-]*)="([^"]*)""#)
        else { return [] }
        let range = NSRange(inner.startIndex..<inner.endIndex, in: inner)
        return re.matches(in: inner, range: range).compactMap { m in
            guard let a = Range(m.range(at: 1), in: inner), let b = Range(m.range(at: 2), in: inner)
            else { return nil }
            return (String(inner[a]), String(inner[b]))
        }
    }

    /// 界面里写死的中文，如果语言包里**明明有这条文案**，就必须接上 `data-i18n`。
    ///
    /// 漏接的症状：**切到英文时那一行还是中文** —— 不报错、不算漏翻（键压根没被引用）、
    /// 语言包的「覆盖」统计也看不出来。实测一轮扫出 **26 处**（§8.68）。
    ///
    /// 判据用「元素整文本 == 语言包 zh-Hans 的某个值」，因为两边都**逐字**对得上时，
    /// 接线是**零改动**的 —— 不存在「不知该挂哪个键」的歧义。
    @Test func 界面里写死的中文必须接上语言包() throws {
        let pack = try loadLanguagePack()
        guard let zh = pack["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        var byValue: [String: [String]] = [:]
        for (key, value) in zh {
            let plain = Self.plainText(value)
            guard !plain.isEmpty else { continue }
            byValue[plain, default: []].append(key)
        }
        #expect(byValue.count > 150, "只有 \(byValue.count) 条中文文案 —— 语言包没读全")

        // ⚠️ **2026-09-19（§8.75）补上「整文本」的数字盲区。**
        //
        // 「元素整文本 == 语言包某个值」这条判据有个洞：语言包里的样本是
        // `ds.occ.appsUsingA = "2 个程序正在占用"`，而入口页写着
        // `<span><span class="evid__count">3</span> 个程序正在占用</span>` ——
        // **逐字对不上**（2 ≠ 3），于是这一整块被**静默跳过**。
        // 症状与漏接一模一样（切英文还是中文），但守卫看不见。
        //
        // ⇒ 再建一张**抹掉 ASCII 数字后**的索引。只对**没有键**的元素兜底：
        // 有键的元素走上面那条路（键在不在候选里），**不改**它 ——
        // 否则「快照里的字与键的值不同步」（合法：快照只是源语言留档）会假红。
        var byValueStripped: [String: [String]] = [:]
        for (key, value) in zh {
            let plain = Self.plainText(value)
            guard !plain.isEmpty else { continue }
            byValueStripped[Self.strippingDigits(plain), default: []].append(key)
        }
        // 负向锚：索引空掉 ⇒ 下面那个分支**永远不生效**（静默失效，比红更糟）。
        #expect(
            byValueStripped[Self.strippingDigits("3 个程序正在占用")] != nil,
            "抹掉数字后的索引里查不到「个程序正在占用」—— 索引没建起来，数字兜底分支是死的（假绿）")

        var problems: [String] = []
        var wired = 0  // 已接线且整文本对得上键值的元素数（口径自证）
        var digitOnly = 0  // 只有抹掉数字才对得上的元素数（数字兜底自证）
        // ⚠️ **2026-09-19（§8.75）范围从 `screenFiles()` 扩到 `htmlFiles()`。**
        // 原来只扫 `screens/`（那个函数的注释里明写「不含 index.html 等」），
        // 而 `index.html` 是设计稿的**入口页**：它整页 0 处 `data-i18n`，
        // 守卫却一直绿 —— 因为入口页**根本不在扫描范围里**。
        // 而 `ds.js` 的 `buildLangBar()` 会往 `.doc__nav` 后面插语言切换栏，
        // 9 个页面（含入口页）都有：在总览页点「English」，**一个字都不会变**。
        var wiredByPage: [String: Int] = [:]
        for url in try htmlFiles() {
            let name = url.lastPathComponent
            for element in elementTexts(in: try read(url)) {
                let text = Self.plainText(element.text)
                // ① 整文本逐字对得上
                var keys = byValue[text]
                var fuzzy = false
                // ② 兜底：抹掉数字后对得上（**只在没有键时**才走这条）
                if keys == nil, element.key == nil {
                    let stripped = Self.strippingDigits(text)
                    if stripped != text, let hit = byValueStripped[stripped] {
                        keys = hit
                        fuzzy = true
                    }
                }
                guard let keys else { continue }
                if let key = element.key {
                    if keys.contains(key) {
                        wired += 1
                        wiredByPage[name, default: 0] += 1
                    }
                    continue
                }
                if element.note || element.suppressed { continue }
                if fuzzy { digitOnly += 1 }
                problems.append(
                    "\(name)：'\(text)' → \(keys.joined(separator: " / "))"
                        + (fuzzy ? "（⚠️ 数字与样本不同 ⇒ 只有抹掉数字才对得上）" : ""))
            }
        }
        print(
            "  [设计稿] 界面文案接线：整文本对得上的已接线元素 \(wired) 个（"
                + wiredByPage.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: " ｜ ") + "）"
                + " ｜ 数字兜底命中 \(digitOnly) 处")
        // 负向锚：**口径自证** —— 已接线的元素里必须有一大批整文本对得上，
        // 否则说明「整文本」的拼法与语言包对不上，下面「0 处漏接」就是假绿。
        #expect(
            wired >= 30,
            "只有 \(wired) 个已接线元素的整文本对得上语言包 —— 整文本口径失效（假绿）")
        // 负向锚（**扫描范围**）：上面那条管「口径对不对」，这条管「**扫没扫到入口页**」。
        // 少了它，把范围收回 `screenFiles()` 会**照样绿** —— 因为 `screens/` 本来就是 0 处漏接，
        // 「0 处漏接」这个结论对「扫了一半的页面」没有任何分辨力（§8.75 的核心教训）。
        #expect(
            wiredByPage["index.html", default: 0] >= 20,
            """
            `index.html` 只贡献了 \(wiredByPage["index.html", default: 0]) 个「整文本对得上」的已接线元素。
            这个数**不是装饰**：它是扫描范围的负向锚。范围一旦收回 `screens/`，
            总览页就完全不被扫，这个数掉到 0，而「漏接 0 处」**照样绿**（§8.75）。
            """)
        #expect(
            problems.isEmpty,
            """
            页面上写死了这些中文，而语言包里**明明有**这条文案，却没接 `data-i18n`：
            \(problems.joined(separator: "\n  "))
            症状：**切到英文时那一行还是中文** —— 不报错、也不算漏翻（键压根没被引用）。
            两边是**逐字**对得上的，接上即可，不会改变中文显示。
            """)
    }

    /// 已接线的元素**不许嵌在另一个已接线元素里**。
    ///
    /// 症状：`applyLang` 是 `el.innerHTML = 文案` —— **整块覆盖**。父元素一回填，
    /// 里面的 `<button>` / `<span class="path">` 连同它自己的 `data-i18n` 一起消失
    /// ⇒ 子元素的键**永远不会被应用**（它已经脱离文档了）。
    /// 实测 01-main-window：切英文后 `.row__act button` **5 → 4**（按钮变一行纯文字）。
    ///
    /// ⚠️ 这一条也是**上一轮守卫 56 的刹车**：给「整文本对得上」的元素接线时，
    /// 若它是个**容器**（里面还有已接线的子元素），接线本身就是在破坏页面。
    /// （上一轮我自己的接线脚本就误伤了 01/07 的 `row__act`，本轮由这条兜住。）
    @Test func 已接线的元素不许嵌在另一个已接线元素里() throws {
        let dir = designRoot.appendingPathComponent("screens")
        var problems: [String] = []
        var scanned = 0
        for name in try screenFiles() {
            for element in elementTexts(in: try read(dir.appendingPathComponent(name))) {
                guard let key = element.key else { continue }
                scanned += 1
                if element.ancestorWired {
                    problems.append("\(name)：\(key)")
                }
            }
        }
        print("  [设计稿] 接线元素 \(scanned) 个，其中嵌在别人里面的 \(problems.count) 个")
        #expect(scanned >= 150, "只扫到 \(scanned) 个已接线元素 —— 解析器没读到？")
        #expect(
            problems.isEmpty,
            """
            这些元素挂了 `data-i18n`，可它的**祖先里还有一层** `data-i18n`：
            \(problems.joined(separator: "\n  "))
            回填是 `innerHTML` **整块覆盖** ⇒ 父一回填，子元素连同它的键一起消失。
            去掉**外层**那个 `data-i18n`（留子元素的）即可。
            """)
    }

    /// `ds.js` 里取文案用的**键**，必须是语言包里有的**字面量**。
    ///
    /// 症状：`t(currentLang(), appLanguage)` —— `appLanguage` 是语言包里的**键名**，
    /// 却当裸标识符用了 ⇒ 加载即 `ReferenceError` ⇒ `init()` **半途中断**
    /// ⇒ 语言栏不生成、`applyLang` **一次都没跑过**。而页面看着完全正常
    /// （中文是 HTML 里写死的）⇒ 这条静默了整整一个版本，还顺带**掩盖**了上面那条。
    @Test func 脚本里取文案用的键必须是语言包里有的字面量() throws {
        let js = try read(designRoot.appendingPathComponent("assets/ds.js"))
        guard let zh = try loadLanguagePack()["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        let calls = Self.translateCalls(in: js)
        let declared = Self.declaredNames(in: js)
        // 锚：至少得解析出 3 处调用（`t(lang, key)` 那个是**定义**，已排除）、
        // 其中至少 1 处是字面量键 —— 否则「0 问题」只是「没扫到」。
        #expect(calls.count >= 3, "只解析到 \(calls.count) 处 t() 调用 —— 解析口径失效")
        var problems: [String] = []
        var literals = 0
        for call in calls {
            let arg = call.keyArg
            if let key = Self.quoted(arg) {
                literals += 1
                if zh[key] == nil { problems.append("'\(key)' 不在语言包里") }
                continue
            }
            if Self.isBareIdentifier(arg) {
                if !declared.contains(arg) {
                    problems.append(
                        "\(arg)：既不是字符串字面量，也不是 ds.js 里声明过的名字 ⇒ 加载即 ReferenceError")
                }
                continue
            }
            // 其余：`el.getAttribute('data-i18n')` / `parts[1]` 这类动态取键，跳过
        }
        #expect(literals >= 1, "一处字面量键都没解析到 —— 解析口径失效")
        #expect(
            problems.isEmpty,
            """
            ds.js 里取文案的键有问题：
            \(problems.joined(separator: "\n  "))
            键名要写**字符串**（`t(currentLang(), 'appLanguage')`）；
            写成裸标识符 ⇒ 加载即 `ReferenceError` ⇒ `init()` 中断，
            语言栏不生成、`applyLang` 一次都不跑 —— 而页面看着**完全正常**。
            """)
    }

    /// 已接线元素**内部的子标签**，语言包的值里必须也有 —— 否则回填时会被整块覆盖掉。
    ///
    /// 修法（§8.69.5 拍板）：`<i data-i>` 图标**拆成兄弟节点**（`<span data-i18n>` 只包文字），
    /// `<b>` / `<br>` 这类**强调与换行补进语言包的值**。基线 35 处（2026-09-18 实测）
    /// 已清零 ⇒ 从「只记录 + 上限锚」升级成**硬断言**。
    /// 实测（修好 `ds.js` 让 i18n 第一次真跑起来后）：01-main-window 的图标 **23 → 15**、
    /// `<b>` **21 → 11**、按钮 **6 → 5**。
    ///
    /// ⚠️ **2026-09-19（§8.75）范围从 `screenFiles()` 扩到 `htmlFiles()`** ——
    /// 与接线守卫同一个病：入口页 `index.html` 不在范围里。它本轮才第一次接线，
    /// 而「值里有没有这个标签」正是**接线之后**才会出问题的那一类。
    @Test func 已接线元素里的子标签必须在语言包值里出现() throws {
        guard let zh = try loadLanguagePack()["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        var rows: [String] = []
        var scanned = 0
        for url in try htmlFiles() {
            let name = url.lastPathComponent
            for element in elementTexts(in: try read(url)) {
                guard let key = element.key, let value = zh[key] else { continue }
                scanned += 1
                let valueTags = Set(tags(in: value).map { $0.name })
                let missing = element.childTags.subtracting(valueTags).sorted()
                guard !missing.isEmpty else { continue }
                rows.append("\(name)：\(key) → 值里没有 \(missing.joined(separator: "/"))")
            }
        }
        // 锚：`childTags` 恒为空时这条守卫**也是绿的**（0 处）⇒ 必须证明它扫到了东西。
        // 实测扫到的已接线元素 ≥ 150 个（扩到 `htmlFiles()` 后 239 个）。
        #expect(scanned >= 150, "只扫到 \(scanned) 个已接线元素 —— 解析口径失效")
        #expect(
            rows.isEmpty,
            """
            接线元素内的子标签在语言包的值里没有（\(rows.count) 处）：
            \(rows.joined(separator: "\n  "))
            回填是 `innerHTML = t(…)` **整块覆盖** ⇒ 值里没有的标签会被静默丢掉。
            修法（§8.69.5）：图标拆成兄弟节点；`<b>`/`<br>` 补进语言包的值。
            """)
    }

    /// 语言包**值里有**的标签，源码快照里必须也有 —— 守卫 59 的**反方向**。
    ///
    /// 源码快照是**中文兜底**：JS 没跑 / 语言包没加载时看到的就是它。值里有 `<b>` 而源码
    /// 没有 ⇒ 加载前后**长得不一样**（加载前不粗、加载后变粗），而两边都没报错。
    ///
    /// ⚠️ 只有这个方向能抓到 `<bg>` 那类**笔误**：`<b>` 打成 `<bg>` 时浏览器把 `<bg>` 当
    /// 未知元素照常渲染 ⇒ 页面**看不出来**；而 `</b>` 因为 `<bg>` 没闭合而永远不匹配，
    /// `bg` 也就**永远传不到**父元素的 `childTags` ⇒ 守卫 59 同样是绿的。
    /// 实测：`<bg>` 3 处（01 ×1、04 ×2），只有本条抓得到。
    ///
    /// ⚠️ 只比 **zh-Hans**：源码快照是中文，跟中文值比才有意义。别的语言值里多一个
    /// `<b>` 是**加分**不是丢失（切过去不会少东西），由守卫 59 那一侧管。
    ///
    /// ⚠️ **2026-09-19（§8.75）范围从 `screenFiles()` 扩到 `htmlFiles()`**（同上）。
    @Test func 语言包值里的标签必须在源码快照里出现() throws {
        guard let zh = try loadLanguagePack()["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        var rows: [String] = []
        var tagged = 0
        for url in try htmlFiles() {
            let name = url.lastPathComponent
            for element in elementTexts(in: try read(url)) {
                guard let key = element.key, let value = zh[key] else { continue }
                let valueTags = Set(tags(in: value).map { $0.name })
                    .intersection(Self.allowedValueTags)
                guard !valueTags.isEmpty else { continue }
                // 锚：**值里带标签**的元素得有一批 —— 否则「0 处」只是「一条都没比」。
                // ⚠️ 另一个隐形前提是 `<br>` 这类**空元素**的标签也进得了 `childTags`：
                // 空元素永不关闭，不走「后代关闭时往上送」那条路（实测 M108 证明）。
                tagged += 1
                let missing = valueTags.subtracting(element.childTags).sorted()
                guard !missing.isEmpty else { continue }
                rows.append("\(name)：\(key) → 源码快照里没有 \(missing.joined(separator: "/"))")
            }
        }
        #expect(tagged >= 5, "值里带标签的已接线元素只有 \(tagged) 个 —— 解析口径失效")
        #expect(
            rows.isEmpty,
            """
            语言包的值里有、但源码快照里没有的标签（\(rows.count) 处）：
            \(rows.joined(separator: "\n  "))
            源码快照是**中文兜底**（JS 没跑时看到的就是它）⇒ 两边必须长得一样。
            要么把标签补进源码快照，要么别把它写进值（§8.69.5）。
            """)
    }

    /// 中文兜底必须与语言包的 zh-Hans 值**逐字一致** —— §8.69.7 那条不变量的**文本**那一半。
    ///
    /// 守卫 59 / 60 只比**标签**（值里有 `<b>` 而源码里没有，或反过来）。**字**本身没人管：
    /// 源码快照可以整句都停在**上一版设计**的说法上，而两边都不报错 —— 因为 `ds.js` 一加载
    /// 就把 `innerHTML` 覆盖成值，**渲染出来永远是对的**。这正是本仓库反复吃亏的那一类：
    /// **少了东西不会报错**。
    ///
    /// 实测（2026-09-29）抓到 `05-settings.html` 三处：`takeOverFinderEject` 的兜底写着
    /// 「接管访达的推出」，而值是「推出时提醒占用」；说明文字更停在**已退役的拦截方案**上
    /// （「由本应用判定并列出占用者…访达会等待你的决定」）。渲染零差异，
    /// 但这页是**给人读的规格**、也是交给实现方的依据 ⇒ 陈旧兜底会把人引向错误设计。
    ///
    /// 判据与豁免（三条，都是为了**不制造假红**）：
    /// - 只比 **zh-Hans**：源码快照是中文，跟别的语言比没有意义。
    /// - 两侧都走 `plainText`（去标签 + 压平空白）：标签那一半归守卫 59 / 60，
    ///   这里只问「字对不对」。
    /// - 值里含**占位符**的跳过：03 页的兜底是**已代入样本**的「即将推出「Samsung T7」」，
    ///   而值是「即将推出「%@」」—— 逐字比必然假红。
    /// - 说明区（`noteClassTokens`）跳过：设计稿自己的论述本来就不翻。
    /// - 属性值比的是**剥掉标签之后**的文本：`ds.js` 写回属性时就是 `.replace(/<[^>]+>/g,'')`。
    @Test func 中文兜底必须与语言包的值逐字一致() throws {
        guard let zh = try loadLanguagePack()["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        var rows: [String] = []
        var compared = 0
        var attrCompared = 0
        for url in try htmlFiles() {
            let name = url.lastPathComponent
            let html = try read(url)

            for element in elementTexts(in: html) {
                guard let key = element.key, !element.note else { continue }
                guard let value = zh[key], let want = Self.fallbackComparable(value) else { continue }
                let got = Self.fallbackText(element.text)
                guard !got.isEmpty else { continue }
                compared += 1
                guard got != want else { continue }
                rows.append("\(name)：\(key)\n        兜底 = \(got)\n        值   = \(want)")
            }

            for hit in Self.textAttrHits(in: html) {
                guard !hit.note, let spec = hit.attrs["data-i18n-attr"] else { continue }
                for pair in spec.split(separator: ",") {
                    let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, parts[0] == hit.attr else { continue }
                    guard let value = zh[parts[1]], let want = Self.fallbackComparable(value)
                    else { continue }
                    attrCompared += 1
                    let got = Self.fallbackText(hit.value)
                    guard got != want else { continue }
                    rows.append(
                        "\(name)：\(parts[1]) [\(hit.attr)]\n        兜底 = \(got)\n        值   = \(want)")
                }
            }
        }
        print("  [中文兜底] 比对元素文本 \(compared) 处 ｜ 属性文案 \(attrCompared) 处")
        // 负向锚：比对数为 0 时 `rows` 恒空 —— 解析改名、或豁免条件写宽了，都是这种形状。
        // 实测（2026-09-29）元素 334 处、属性 51 处。
        #expect(compared >= 250, "只比对了 \(compared) 处元素兜底 —— 解析口径失效（假绿）")
        #expect(attrCompared >= 30, "只比对了 \(attrCompared) 处属性兜底 —— `data-i18n-attr` 解析失效（假绿）")
        #expect(
            rows.isEmpty,
            """
            中文兜底与语言包的值对不上（\(rows.count) 处）：
            \(rows.joined(separator: "\n  "))
            源码快照是**中文兜底**（JS 没跑 / 语言包没加载时看到的就是它）。
            渲染上通常看不出来（`ds.js` 一加载就覆盖），但这页是**给人读的规格** ——
            陈旧兜底会把读的人引向**已经废掉的设计**（§8.69.7 已退役的拦截方案那次就是）。
            改文案时把兜底一起改。
            """)
    }

    /// 语言包的值能不能拿来做**逐字**比对。`nil` = 不能比（含占位符，或去标签后为空）。
    ///
    /// ⚠️ 占位符键必须跳过，不是偷懒：源码快照写的是**代入样本之后**的样子
    /// （03 页「即将推出「Samsung T7」」对值「即将推出「%@」」），逐字比恒不相等。
    private static func fallbackComparable(_ value: String) -> String? {
        guard
            let re = try? NSRegularExpression(pattern: placeholderPattern),
            re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil
        else { return nil }
        let plain = fallbackText(value)
        return plain.isEmpty ? nil : plain
    }

    /// 兜底比对专用的归一化：**`<br>` 等价于空白**，然后去标签 + 压平空白。
    ///
    /// ⚠️ 不能直接用 `plainText`：它把 `<br>` 整个删掉（`。<br>macOS` → `。macOS`），
    /// 而源码里 `<br>` 后面通常跟着**换行 + 缩进**，压平后留下一个空格
    /// （`。<br>\n  macOS` → `。 macOS`）⇒ 4 处**只有空格不同**的假红（实测 2026-09-29：
    /// `fdaOnboardingBody` / `ds.empty.hintLong` / `ds.alert.updateSub` ×2）。
    /// 把 `<br>` 先换成空格，两侧的口径就一致了 —— 换行在渲染上本来就是空白，
    /// 「标签对不对」那件事归守卫 59 / 60，这里只问**字**。
    ///
    /// ⚠️ 不动 `plainText` 本身：它还被另外几条守卫用着，改它会**悄悄改变那些守卫的严格度**。
    private static func fallbackText(_ html: String) -> String {
        let brAsSpace = replace(in: html, pattern: #"<br\s*/?>"#, with: " ")
        let stripped = replace(in: brAsSpace, pattern: #"<[^>]+>"#, with: "")
        return stripped.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    // MARK: 属性文案

    /// 含中文的**属性文案**必须接上 `data-i18n-attr` —— 否则切英文时它还是中文。
    ///
    /// `applyLang` 是 `el.innerHTML = t(…)`，只覆盖**元素内容**；`title` / `aria-label`
    /// 这些属性**不在覆盖范围内** ⇒ 必须由 `data-i18n-attr` 单独驱动（`ds.js` 里实现了）。
    /// 实测（无头 Chrome，8 页）：接线前切英文，**57 处属性一处都没翻**；接线后剩 10 处
    /// （豁免表里的 8 处样本磁盘名 + 2 处画框说明）。
    ///
    /// ⚠️ 这类缺口和 §8.69 那个 `ReferenceError` 是同一形状：**机制写好了、没人用** ——
    /// `ds.js` 的注释里连用法都写了，而全库 `data-i18n-attr` **零使用**。
    /// ⚠️ 扫的是 `htmlFiles()`（**含总览页 `index.html`**，不只是 `screens/`）：
    /// 总览页同样加载了 `i18n.js` + `ds.js`，那里写死的 `aria-label` 一样不翻
    /// （实测 10 处 —— 首版只扫 `screens/` ⇒ 整个总览页是盲区）。
    @Test func 含中文的属性文案必须接上data_i18n_attr() throws {
        guard let zh = try loadLanguagePack()["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        var rows: [String] = []
        var seen: Set<String> = []
        var total = 0
        for url in try htmlFiles() {
            let name = url.lastPathComponent
            for hit in Self.textAttrHits(in: try read(url)) {
                // 与守卫「英文文案里不许出现中文字符」同一个口径（CJK 统一表意文字）
                let hasHan = hit.value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                guard !hit.note, hasHan else { continue }
                total += 1
                seen.insert(hit.value)
                if Self.attrAllowlist[hit.value] != nil { continue }
                guard let spec = hit.attrs["data-i18n-attr"] else {
                    rows.append("\(name)：\(hit.attr)=\"\(hit.value)\" → 没接 data-i18n-attr")
                    continue
                }
                // 接了还不够：这个属性对应的键必须**在语言包里**（写错键 ⇒ 属性变成键名）
                let keys = spec.split(separator: ",").compactMap { pair -> String? in
                    let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                    return parts.count == 2 && parts[0] == hit.attr ? parts[1] : nil
                }
                if keys.isEmpty {
                    rows.append("\(name)：\(hit.attr)=\"\(hit.value)\" → data-i18n-attr 里没有 \(hit.attr)")
                } else if let bad = keys.first(where: { zh[$0] == nil }) {
                    rows.append("\(name)：\(hit.attr)=\"\(hit.value)\" → 键 '\(bad)' 不在语言包里")
                }
            }
        }
        #expect(total >= 20, "只扫到 \(total) 处含中文的属性 —— 扫描逻辑多半坏了")
        #expect(seen.count >= 5, "只见到 \(seen.count) 种属性值 —— 扫描逻辑多半坏了")
        #expect(
            rows.isEmpty,
            """
            这些属性是中文，切英文时**不会跟着变**（`innerHTML` 回填不覆盖属性）：
            \(rows.joined(separator: "\n  "))
            接法：`data-i18n-attr="aria-label:refreshDisks,title:refreshDisks"`（ds.js 已实现）。
            确实不能翻的，连同理由登记进 `attrAllowlist`。
            """)
    }

    /// 键的值里**带占位符**（`%@` / `%d`）时，元素必须给 `data-i18n-args`，且个数要够。
    ///
    /// 症状：占位符会**原样显示** —— 界面上明晃晃一个 `%@`，`aria-label` 还会被 VoiceOver
    /// 念成「百分号 at」。而语言包那边一切正常（键在、值在），谁也不会想到是 HTML 少了参数。
    ///
    /// ⚠️ 实测当前**正文**里 0 处带占位符，只有 6 个属性用到了（样本磁盘名）⇒
    /// 这条守卫现在守的是「以后别忘」，锚因此写得很松（≥6）。
    @Test func 带占位符的键必须给足data_i18n_args() throws {
        guard let zh = try loadLanguagePack()["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        var rows: [String] = []
        var checked = 0
        for url in try htmlFiles() {
            let name = url.lastPathComponent
            for hit in Self.textAttrHits(in: try read(url)) {
                guard !hit.note, let spec = hit.attrs["data-i18n-attr"] else { continue }
                let args = (hit.attrs["data-i18n-args"] ?? "").split(separator: ",").count
                for pair in spec.split(separator: ",") {
                    let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let value = zh[parts[1]] else { continue }
                    let holes = value.matches(of: /%[@sd]/).count
                    guard holes > 0 else { continue }
                    checked += 1
                    if args < holes {
                        rows.append(
                            "\(name)：\(hit.attr) 用了 \(parts[1])（值 \(value)）→ 要 \(holes) 个参数，"
                                + "data-i18n-args 只给了 \(args) 个")
                    }
                }
            }
        }
        #expect(checked >= 6, "只查到 \(checked) 处带占位符的接线 —— 扫描逻辑多半坏了")
        #expect(
            rows.isEmpty,
            """
            这些接线的值里有占位符，但 `data-i18n-args` 没给够：
            \(rows.joined(separator: "\n  "))
            占位符会**原样显示**（`%@` 被 VoiceOver 念成「百分号 at」），
            而语言包一切正常 ⇒ 只有肉眼看界面才发现得了。
            """)
    }

    /// 属性豁免表**不许过期**：登记的值如果页面上已经没有了，要回来划掉。
    @Test func 属性豁免表里已经没人用的条目要划掉() throws {
        var seen: Set<String> = []
        for url in try htmlFiles() {
            for hit in Self.textAttrHits(in: try read(url)) { seen.insert(hit.value) }
        }
        let stale = Self.attrAllowlist.keys.filter { !seen.contains($0) }.sorted()
        #expect(
            stale.isEmpty,
            """
            属性豁免表里这些值，页面上**已经没有了**：\(stale.joined(separator: " / "))
            要么把它翻掉（现在 `ds.js` 可能支持插值了），要么回来划掉这一条。
            """)
    }

    /// `ds.js` 回填时**必须过一遍 `fill()`** —— 光是 HTML 里写了 `data-i18n-args` 没用。
    ///
    /// 症状：谁把 `fill()` 从属性那一支摘掉，页面照常跑、`data-i18n-args` 也都还在
    /// ⇒ **守卫 63 依然是绿的**，而 `aria-label` 又变回字面量 `%@`。
    /// 这与 §8.70.1 是同一个形状：**机制在不在，和它生效没生效，是两件事**。
    @Test func dsjs回填时必须过一遍fill() throws {
        let js = try read(designRoot.appendingPathComponent("assets/ds.js"))
        let fillCalls = js.matches(of: /fill\(\s*t\(/).count
        let argsOf = js.matches(of: /function\s+argsOf/).count
        // 两支都要过 fill：`[data-i18n]`（.innerHTML）与 `[data-i18n-attr]`（setAttribute）
        #expect(fillCalls >= 2, "ds.js 里只有 \(fillCalls) 处 fill(t(…)) —— 有一支回填忘了插值")
        #expect(argsOf == 1, "ds.js 里 argsOf 的定义有 \(argsOf) 处 —— 插值参数读不到了")
    }

    /// 扫出页面里所有**带文案属性**的起始标签（含「是否在说明区内」）。
    private static func textAttrHits(
        in html: String
    ) -> [(attr: String, value: String, attrs: [String: String], note: Bool)] {
        var stack: [[String: String]] = []
        var out: [(attr: String, value: String, attrs: [String: String], note: Bool)] = []
        var i = html.startIndex
        while i < html.endIndex {
            guard html[i] == "<", let gt = html[i...].firstIndex(of: ">") else {
                i = html.index(after: i)
                continue
            }
            var inner = String(html[html.index(after: i)..<gt])
            i = html.index(after: gt)
            if inner.hasPrefix("!") { continue }
            let closing = inner.hasPrefix("/")
            if closing { inner.removeFirst() }
            if inner.hasSuffix("/") { inner.removeLast() }
            let name = inner.split(separator: " ").first.map { $0.lowercased() } ?? ""
            if closing {
                if let idx = stack.lastIndex(where: { $0["__tag"] == name }) {
                    stack.removeSubrange(idx...)
                }
                continue
            }
            guard !name.isEmpty, !htmlVoidTags.contains(name) else { continue }
            var attrs: [String: String] = ["__tag": name]
            for pair in attrPairs(in: inner) { attrs[pair.0] = pair.1 }
            // ⚠️ **自己**的说明区 class 也算：`<p class="spec-note" aria-label="…">` 这种，
            // 只看祖先会把它当成界面文案（实测 M114 红了才发现的）。
            let note =
                Self.isNoteClass(attrs["class"]) || stack.contains { Self.isNoteClass($0["class"]) }
            for attr in textAttrs.sorted() {
                if let value = attrs[attr] { out.append((attr, value, attrs, note)) }
            }
            stack.append(attrs)
        }
        return out
    }

    /// 取 `ds.js` 里 `t(…)` **调用**的两个实参（排除 `function t(lang, key)` 这个定义）。
    private static func translateCalls(in js: String) -> [(whole: String, keyArg: String)] {
        guard let re = try? NSRegularExpression(pattern: #"\bt\s*\("#) else { return [] }
        let range = NSRange(js.startIndex..<js.endIndex, in: js)
        var out: [(String, String)] = []
        for m in re.matches(in: js, range: range) {
            guard let open = Range(m.range, in: js) else { continue }
            if js[js.startIndex..<open.lowerBound].hasSuffix("function ") { continue }
            var depth = 0
            var i = open.upperBound
            while i < js.endIndex {
                if js[i] == "(" {
                    depth += 1
                } else if js[i] == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                i = js.index(after: i)
            }
            guard i < js.endIndex else { continue }
            var d = 0
            var j = open.upperBound
            var comma: String.Index?
            while j < i {
                if js[j] == "(" {
                    d += 1
                } else if js[j] == ")" {
                    d -= 1
                } else if js[j] == ",",
                    d == 0
                {
                    comma = j
                    break
                }
                j = js.index(after: j)
            }
            guard let comma else { continue }
            let keyArg = String(js[js.index(after: comma)..<i])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append((String(js[open.lowerBound...i]), keyArg))
        }
        return out
    }

    /// `ds.js` 里**声明过**的名字（`var` / `let` / `const` / `function` / 形参）。
    private static func declaredNames(in js: String) -> Set<String> {
        var names: Set<String> = []
        let patterns = [
            #"\b(?:var|let|const|function)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#,
            #"\bfunction\s*[A-Za-z_$][A-Za-z0-9_$]*\s*\(([^)]*)\)"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(js.startIndex..<js.endIndex, in: js)
            for m in re.matches(in: js, range: range) {
                guard let g = Range(m.range(at: 1), in: js) else { continue }
                for part in String(js[g]).split(separator: ",") {
                    let n = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !n.isEmpty { names.insert(n) }
                }
            }
        }
        return names
    }

    private static func quoted(_ s: String) -> String? {
        guard s.count >= 2,
            (s.hasPrefix("'") && s.hasSuffix("'"))
                || (s.hasPrefix("\"") && s.hasSuffix("\""))
        else { return nil }
        return String(s.dropFirst().dropLast())
    }

    private static func isBareIdentifier(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#)
        else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }

    /// CSS **变量**（自定义属性）的「用了没定义」 —— 此前一条守卫都没有。
    ///
    /// `var(--foo)` 拼错 / 定义被删 ⇒ 渲染出来是「**没这个样式**」，
    /// 而「样式没生效」与「本来就没写样式」在界面上**逐字相同**（§8.52 那一向的理由）。
    /// 本设计稿 **916 处** `var()` 引用，全靠这一条守。
    ///
    /// ⚠️ 变量有**页面作用域**：`06-states.html` 的 `<style>` 里定义的变量，
    /// `01-main-window.html` **拿不到**。所以按**页**解析（`ds.css` ∪ 本页 `<style>`），
    /// **不能**把所有页面的 `<style>` 汇总 —— 汇总会把跨页断链判成可达。
    /// （本轮实测 9 个页面的 `<style>` 里**一个变量定义都没有**，两种口径目前同结果；
    ///  按页写是为了将来有人加页面级变量时不至于静默放过 —— 变异 M21 钉的就是这条。）
    ///
    /// `var(--x, 兜底)` **不算断** —— 作者明说了「没有就用兜底值」。
    /// 全库目前 0 处兜底写法，这条逻辑由变异 M22 的**绿**对照钉住。
    @Test func 用了但没定义的CSS变量一个都不许有() throws {
        let scan = try loadCSSVariables()

        // 锚：定义侧与使用侧**都得扫到足够多**，否则「0 处断链」只是「两边都没扫到」。
        #expect(scan.defined.count >= 60, "只解析到 \(scan.defined.count) 个变量定义 —— ds.css 没读到")
        #expect(
            scan.defined.contains("--fs-11") && scan.defined.contains("--text-3"),
            "`--fs-11` / `--text-3` 不在定义集里 —— 定义侧的正则坏了")
        #expect(scan.pages.count >= 9, "只扫到 \(scan.pages.count) 个页面 —— 逐页扫描坏了")
        // ⚠️ 2026-09-29：原来这里是**逐页**要求 `used` 非空。新增的
        // `09-settings-split.html` 把两栏形态的全部样式放进了共享层（它的页面里
        // 只剩 `style="gap:64px"` 这类**不含变量**的内联），于是它**合法地**是 0 处 ——
        // 而那条锚把它判成「使用侧解析坏了」，是**假红**。
        // 锚的目的（防「定义侧与使用侧两边都没扫到」）已由上面两条定义侧锚
        // 与下面的总量锚覆盖，故口径改成「**有** var() 的页面数」：
        // 既能发现整页解析失效，又不逼每个页面必须写内联变量。
        let pagesWithVars = scan.pages.filter { !$0.used.isEmpty }.count
        #expect(
            pagesWithVars >= 8,
            "只有 \(pagesWithVars) 个页面扫到 var() —— 逐页解析坏了（假绿）")
        let occurrences = scan.pages.reduce(0) { $0 + $1.used.count }
        #expect(occurrences >= 500, "只扫到 \(occurrences) 处 var() —— 量级不对（实际 900+ 处）")

        for p in scan.pages where !p.missing.isEmpty {
            #expect(
                p.missing.isEmpty,
                """
                \(p.name) 用了这些**解析不到**的 CSS 变量：\(Set(p.missing).sorted().joined(separator: ", "))
                `var(--x)` 拿不到值时**不报错**，只是那一处样式没了 ——
                而「样式没了」和「这儿本来就没写样式」在界面上长得一模一样。
                """)
        }
    }

    /// **反向**（定义了但没人用）只记录，不报警 —— 与 §8.52.5 同一个判据：
    /// 设计稿里的「存货」**多数是合理的**（备用令牌），删它会改变视觉。
    @Test func 定义了但没用的CSS变量只记录不报警() throws {
        let scan = try loadCSSVariables()
        var used: Set<String> = []
        for p in scan.pages { used.formUnion(p.used) }
        let unused = scan.defined.subtracting(used).sorted()
        print("[设计稿] 定义了但没用到的 CSS 变量：\(unused.count) 个 —— \(unused.joined(separator: ", "))")
    }

    // MARK: ds.js 查询的 DOM 目标

    /// **ds.js 查询不到目标 ⇒ 那段逻辑静默不生效**，与「这段逻辑本来就没触发」逐字相同。
    ///
    /// `document.querySelectorAll('[data-lang-btn]')` 选中 0 个元素时**不报错** ——
    /// JS 里的空集合是合法的。于是「接线断了」与「功能没写」在界面上长得一模一样
    /// （与 §8.47「updater 从来没启动过」同形，只是那一侧是 Swift、这一侧是 JS）。
    ///
    /// ⚠️ **元素从哪来不止一个来源**（上一轮踩的坑，见 §8.57.2）：
    /// HTML 静态 `class="…"` 之外，ds.js 自己还会造 ——
    /// `.className = '…'` / `classList.add(…)` / `setAttribute('data-lang-btn', …)`。
    /// 只认 HTML 静态会把 `.langbar` 误判成断链。所以来源是**并集**，
    /// 且由两条**负向锚**（`langbar` / `data-lang-btn` 必须在已知集里）钉住 ——
    /// 若哪天这两条来源的解析坏了，守卫会**先红在这里**，而不是误报一堆断链。
    /// ⚠️ **这张表现在是空的**（2026-09-19 清空）。
    ///
    /// 原来只有一条 `data-i18n-attr`：登记的是「`ds.js` 实现了属性级翻译，但设计稿
    /// **一个元素都没用** ⇒ 这段代码从不执行」。§8.70 已把它全面接线（34 个元素）
    /// ⇒ 条目变成「登记了却有人用」⇒ 由 `已登记的DOM目标如果有元素在用了要划掉`
    /// **自己报出来并划掉**（这就是那条守卫的价值：还了账它催你回来改）。
    ///
    /// 表留着：将来再出现「机制写好了、没人用」的口子，登记进来。
    private static let unresolvedDOMTargets: [String: String] = [:]

    @Test func 脚本查询的DOM目标必须存在() throws {
        let s = try loadDOM()

        // 锚：三张已知表都得有货，否则「0 处断链」只是「三张表都是空的」。
        #expect(s.selectors.count >= 15, "只解析到 \(s.selectors.count) 个查询 —— ds.js 没读到")
        #expect(s.classes.count >= 150, "只解析到 \(s.classes.count) 个 class —— HTML/ds.js 没读到")
        #expect(s.ids.count >= 30, "只解析到 \(s.ids.count) 个 id")
        #expect(s.attrs.count >= 8, "只解析到 \(s.attrs.count) 个属性")

        // 负向锚：这两个名字**只能**由 ds.js 的动态创建提供。
        // 它们不在已知集 ⇒ 不是「设计稿断了」，是**我的解析漏了来源**（假红）。
        #expect(s.classes.contains("langbar"), "`langbar` 不在已知集 —— `.className = '…'` 这条来源漏了（会假红）")
        #expect(
            s.attrs.contains("data-lang-btn"),
            "`data-lang-btn` 不在已知集 —— `setAttribute(…)` 这条来源漏了（会假红）")

        let unregistered = Set(s.missing.map { $0.target }).subtracting(Self.unresolvedDOMTargets.keys)
        let detail = s.missing
            .filter { unregistered.contains($0.target) }
            .map { "\($0.form)('\($0.selector)') → \($0.target)" }
            .sorted().joined(separator: "\n  ")
        #expect(
            unregistered.isEmpty,
            """
            ds.js 查询的这些目标**在设计稿里不存在**（且没登记）：
              \(detail)
            选中 0 个元素**不报错** —— 那段逻辑会静默不生效。
            若是 ds.js 自己动态创建的，补一条来源解析；若是设计稿真断了，修 HTML；
            若是有意保留的能力，登记进 `unresolvedDOMTargets` 并写清理由。
            """)
    }

    /// 豁免表**不许过期**：登记为「没人用」的目标，一旦有元素在用了就要回来划掉。
    @Test func 已登记的DOM目标如果有元素在用了要划掉() throws {
        let s = try loadDOM()
        let stale = Self.unresolvedDOMTargets.keys.filter { s.htmlAttrs.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些目标登记为「没有元素在用」，但 HTML 里**已经有了**：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """)
    }

    /// **量化基线**：硬编码中文的无障碍标签**只许减少，不许增加**。
    ///
    /// ⚠️ 这是**兜底**，真正的刹车是守卫 61（含中文的属性必须接 `data-i18n-attr`，
    /// 精确规则）。本条比 61 **宽**两处：① 它连说明区里的 `aria-label` 也数（61 豁免说明区）；
    /// ② 它连 `index.html` 也扫（61 只扫 `screens/`，而总览页那 10 处同样没接线 —— §8.70.6）。
    @Test func 硬编码中文的无障碍标签不得增加() throws {
        var n = 0
        for url in try htmlFiles() {
            let text = Self.withoutStyleBlocks(try read(url))
            for v in Self.matches(in: text, pattern: #"(?:aria-label|title)="([^"]*)""#) {
                if v.range(of: #"[\u{4e00}-\u{9fff}]"#, options: .regularExpression) != nil { n += 1 }
            }
        }
        #expect(
            n <= Self.hardcodedA11yBaseline,
            """
            硬编码中文的 `aria-label` / `title` 现在是 \(n) 处，基线 \(Self.hardcodedA11yBaseline) 处 —— **增加了**。
            新增的部分切到英文时不会跟着变（VoiceOver 会念中文），而 aria-label 不显示、走查看不出来。
            要么用 `data-i18n-attr="aria-label:键,title:键"` 接上翻译，要么说明为什么这里是例外。
            """)
    }

    /// 基线 = 2026-09-19 实测的 **67 处**（`screens/` 57 + 总览页 `index.html` 10）。
    /// 修掉会变小（仍绿），新增会变大（必红）。
    ///
    /// ⚠️ 别照着 `screens/` 的数去改这个基线：本条扫的是 `htmlFiles()`，
    /// **包含 `index.html`**（总览页的强调色切换器 + 开关演示，共 10 处）。
    ///
    /// **2026-09-27 → 68**（`05-settings.html` 的「接管访达的推出」开关行，+1）。
    /// 这一处**不是漏接线**，守卫 61（`含中文的属性文案必须接上data_i18n_attr`）是绿的 ——
    /// 它带 `data-i18n-attr="aria-label:takeOverFinderEject"`，切英文会跟着翻。
    /// 之所以仍然 +1：本文件其余 57 行用的都是「中文兜底 + `data-i18n-attr`」这一套写法
    /// （兜底让**读 HTML 源码的人**看得见文案），新行沿用同一套。
    /// 若为了不动这个数而让新行只留接线、不写兜底，就会在同一份设计稿里造出**第二套约定** ——
    /// 而「同一事实两种写法」正是本仓库反复吃亏的那类漂移。
    /// ⇒ 按本条自己给的第二个分支处理：**说明为什么，并同步基线**。
    ///
    /// **2026-09-28 → 72**：「自动更新」那一行拆成「自动检查更新」+「自动下载更新」
    /// ⇒ **四个页面各多一行**（`05-settings.html` 1 处、`08-update.html` 3 帧），每行 +1 处
    /// `aria-label="自动下载更新"`，合计 +4。
    /// 与上一条（接管行 +1）**完全同源**：这一处也**不是漏接线**，守卫 61 是绿的 ——
    /// 新行带 `data-i18n-attr="aria-label:autoDownloadUpdate"`，切英文会跟着翻；
    /// 之所以仍然 +4，是沿用「中文兜底 + `data-i18n-attr`」那套写法（兜底让**读 HTML 源码的人**
    /// 看得见文案）。拆行**没有**增加新的例外类别，只是同一套写法多用了 4 次。
    ///
    /// **2026-09-29 → 86**：新增 `09-settings-split.html`（设置面板的两栏形态）——
    /// 它把**同一个设置面板的分类各画了一帧**，每帧都画完整控件，共 14 处：
    /// 通用帧 4（语言下拉 + Dock / 登录项 / 推出提醒三个开关）、
    /// 通用第三态帧 4（同上，那一帧是「登录项等待系统批准」，整页重画）、
    /// 外观帧 4（四个强调色色板）、更新帧 2（两个更新开关）。
    /// 与上两次（接管行 +1、拆行 +4）**完全同源**：这 14 处**没有一处是漏接线** ——
    /// 守卫 61 对它们全是绿的，都带 `data-i18n-attr`，切英文会跟着翻；
    /// 之所以仍然 +14，是沿用「中文兜底 + `data-i18n-attr`」那套写法
    /// （兜底让**读 HTML 源码的人**看得见文案）。本轮**没有**新增例外类别。
    ///
    /// ⚠️ 它与上两次的性质不同：前两次是**产品形态变了**，这一次是
    /// **同一形态多画了几帧**（探索稿要一次看全五个分类 + 一个第三态）。
    /// 真要压这个数，只能把演示帧改成「一帧完整窗口 + 其余分类只画内容区片段」，
    /// 外加把第三态帧砍掉 —— 那会看不出两栏联动、也看不出第三态高度是否放得下，
    /// **不划算**，故如实同步基线。产品侧真正实现时这个数会**回落**（只会有一个面板）。
    private static let hardcodedA11yBaseline = 86

    // MARK: 索引 ↔ 页面自身标题（§8.62）

    /// 索引里**指向某个页面**的链接，其文字必须包含**该页面自己 `<title>` 的主名**。
    ///
    /// 这一类的静默性：改了页面标题（或改了索引里的叫法），**两边都不报错** ——
    /// 读者按索引点进去，看到的是另一个名字，只会以为自己记错了。
    /// 首跑就抓到一处真的：04 号页在卡片里叫「完全磁盘访问引导」，
    /// 而它自己的标题（与导航链接）叫「授权引导」—— **同一页面两个名字**。
    ///
    /// ⚠️ 口径是「**包含**」而不是「相等」：导航链接是短名（相等），
    /// 卡片链接带 `SCREEN 04` 前缀与一整句描述（只可能是子串）。
    /// 一开始按「相等」写会 16 条全红 —— 那是**假红**（描述性文案本来就长）。
    @Test func 索引里指向页面的名字必须与该页面自己的标题一致() throws {
        let s = try loadLinks()

        // 负向锚：解析不到链接 = 口径失效，不是「全都一致」
        #expect(s.links.count >= 8, "只解析到 \(s.links.count) 条指向页面的链接 —— 解析口径失效（假绿）")

        var mismatches: [String] = []
        for link in s.links {
            let file = designRoot.appendingPathComponent(link.href)
            guard FileManager.default.fileExists(atPath: file.path) else {
                mismatches.append("\(link.href)：索引指向的文件不存在")
                continue
            }
            guard let main = try pageMainTitle(link.href) else {
                mismatches.append("\(link.href)：页面里读不到 <title>")
                continue
            }
            if !link.text.contains(main) {
                mismatches.append("\(link.href)：索引写「\(link.text)」，页面标题主名是「\(main)」")
            }
        }
        #expect(
            mismatches.isEmpty,
            """
            索引与页面自己的标题对不上：
            \(mismatches.joined(separator: "\n  "))
            改了页面标题、或改了索引里的叫法，**两边都不会报错** ——
            读者按索引点进去看到另一个名字，只会以为自己记错了。
            统一成一个名字（页面 `<title>` 是准绳：它是页面对自己的正式命名）。
            """)
    }

    /// 页面**自己**的两个名字必须一致：`<title>` 主名 与 `<h1>`。
    ///
    /// 这一处比「索引 ↔ 页面」更近：用户打开页面，浏览器标签是一个名字、
    /// 页面大标题是另一个名字 —— 而**没有任何东西会报错**。
    /// 首跑同样只红 04 号页（`<title>`「授权引导」 vs `<h1>`「完全磁盘访问引导」），
    /// 其余 7 页**逐字相等** ⇒ 这个「相等」口径没有假红。
    @Test func 页面自己的大标题必须与它自己的title一致() throws {
        let files = try screenFiles()
        var mismatches: [String] = []
        for name in files {
            let rel = "screens/\(name)"
            guard let main = try pageMainTitle(rel) else {
                mismatches.append("\(rel)：读不到 <title>")
                continue
            }
            guard let h1 = try pageH1(rel) else {
                mismatches.append("\(rel)：读不到 <h1>")
                continue
            }
            if h1 != main {
                mismatches.append("\(rel)：<title> 主名「\(main)」 vs <h1>「\(h1)」")
            }
        }
        #expect(
            mismatches.isEmpty,
            """
            页面自己的两个名字对不上：
            \(mismatches.joined(separator: "\n  "))
            浏览器标签显示一个名字、页面大标题显示另一个，**没有任何东西会报错** ——
            读者只会以为有两个不同的页面。以 `<title>` 为**（它是页面对自己的正式命名）。
            """)
    }

    /// 反向（缺位）：**每个页面都必须被索引链接到**。
    ///
    /// ⚠️ 与 §8.61 那条相反：这一向**可以**靠扫描守住 ——
    /// 「页面文件集合」与「索引链接集合」都是现成的，不依赖历史，
    /// 所以「新加了一屏却忘记挂进索引」能判出来（那一屏从此没人找得到）。
    @Test func 每个页面都必须被索引链接到() throws {
        let s = try loadLinks()
        let linked = Set(s.links.map { $0.href })
        let fm = FileManager.default
        let screensDir = designRoot.appendingPathComponent("screens")
        let files = (try fm.contentsOfDirectory(atPath: screensDir.path))
            .filter { Self.isDraftPage($0) }.sorted()

        #expect(!files.isEmpty, "screens/ 下一个页面都没有 —— 路径错了（假绿）")

        let orphans = files.filter { !linked.contains("screens/\($0)") }
        #expect(
            orphans.isEmpty,
            """
            这些页面**没有被索引链接到**：\(orphans.joined(separator: ", "))
            新增一屏却忘记挂进 index.html，**不会有任何报错** ——
            它就在那里，但没人点得到（与 §8.45「有能力、没接线」同形）。
            """)
    }

    // MARK: 扫描

    // MARK: 页面之间的导航 + 文档清单（§8.63）

    /// 每个页面顶部 `<nav>` 必须**列全所有屏** —— 上一轮守的是「index → 页面」，
    /// 这一向是「**页面 → 页面**」：新增一屏却忘了在 8 个页面的 nav 里加，
    /// 从其他任何一屏都**点不过去**（只能退回 index），而**没有任何东西会报错**。
    @Test func 每个页面的导航必须列全所有屏() throws {
        let all = Set(try screenFiles())
        var problems: [String] = []
        for page in try screenFiles() {
            let links = Set(try navLinks(of: page).map { $0.href })
            // 负向锚：一个 nav 链接都解析不到 = 口径失效，不是「列全了」
            if links.isEmpty {
                problems.append("\(page)：nav 里一个页面链接都没解析到 —— 解析口径失效（假绿）")
                continue
            }
            let missing = all.subtracting(links).sorted()
            if !missing.isEmpty {
                problems.append("\(page)：nav 缺 \(missing.joined(separator: ", "))")
            }
        }
        #expect(
            problems.isEmpty,
            """
            页面之间的导航不全：
            \(problems.joined(separator: "\n  "))
            新增一屏却忘了加进各页的 nav ⇒ 从其他任何一屏都**点不过去**，
            而这件事**不会有任何报错**（与 §8.45「有能力、没接线」同形）。
            """)
    }

    /// nav 里的**名字**也必须与该页面自己的 `<title>` 主名一致（实测当前 8×8 全对）。
    @Test func 导航里的页面名必须与页面自己的标题一致() throws {
        var problems: [String] = []
        for page in try screenFiles() {
            for link in try navLinks(of: page) {
                guard
                    FileManager.default.fileExists(
                        atPath: designRoot.appendingPathComponent("screens/\(link.href)").path)
                else {
                    problems.append("\(page)：nav 指向不存在的文件 \(link.href)")
                    continue
                }
                guard let main = try pageMainTitle("screens/\(link.href)") else { continue }
                if link.text != main {
                    problems.append("\(page) 的 nav 写「\(link.text)」，而 \(link.href) 的标题主名是「\(main)」")
                }
            }
        }
        #expect(
            problems.isEmpty,
            """
            导航里的名字与页面自己的标题对不上：
            \(problems.joined(separator: "\n  "))
            改了页面标题却没改 nav（或反过来）**两边都不报错** ——
            读者点进去发现名字不一样，只会以为那不是同一屏。
            """)
    }

    /// §9 文件清单里对每个页面的**说明**，必须包含该页面自己的 `<title>` 主名。
    ///
    /// 首跑抓到一处真的：03 号页的清单说明写「推出确认（破坏性）与失败弹窗」，
    /// 而它自己的标题主名是「**推出流程弹窗**」—— 7/8 通过，只有它不通过（⇒ 口径无假红）。
    @Test func 文件清单里的页面说明必须含该页面的标题主名() throws {
        let listing = try screenListing()
        #expect(
            listing.count >= 8,
            "§9 文件清单里只解析到 \(listing.count) 个页面 —— 解析口径失效（假绿）")

        var problems: [String] = []
        for (file, desc) in listing.sorted(by: { $0.key < $1.key }) {
            guard let main = try pageMainTitle("screens/\(file)") else { continue }
            if !desc.contains(main) {
                problems.append("§9 里 \(file) 的说明「\(desc)」不含它的标题主名「\(main)」")
            }
        }
        #expect(
            problems.isEmpty,
            """
            §9 文件清单的说明与页面自己的标题对不上：
            \(problems.joined(separator: "\n  "))
            页面改了名字而文档没跟上 ⇒ 读者按文档找的是旧名字，
            而文档与页面**都不会报错**（与 §8.62 那处同型，只是这一处在文档侧）。
            """)
    }

    // MARK: 页面引用的资源（§8.64）

    /// 每个页面都必须把**样式与两个脚本**都引上（缺哪个都是「页面还在、功能没了」）。
    ///
    /// 缺位类，但按 §8.61.2 的判据可以守：**「该有的全集」可派生**（页面集合 + 固定的三个资源）。
    @Test func 每个页面都必须引用样式与脚本() throws {
        let required = ["ds.css", "i18n.js", "ds.js"]
        var problems: [String] = []
        for url in try htmlFiles() {
            let html = try read(url)
            let refs =
                Self.matches(in: html, pattern: ##"<link[^>]+href="([^"]+\.css)""##)
                + Self.matches(in: html, pattern: ##"<script[^>]+src="([^"]+\.js)""##)
            let have = Set(refs.map { ($0 as NSString).lastPathComponent })
            // 负向锚：一个 css/js 都没扫到 = 口径失效，不是「都引了」
            if have.isEmpty {
                problems.append("\(url.lastPathComponent)：一个 css/js 引用都没解析到 —— 解析口径失效（假绿）")
                continue
            }
            let missing = required.filter { !have.contains($0) }
            if !missing.isEmpty {
                problems.append("\(url.lastPathComponent)：没引 \(missing.joined(separator: " / "))")
            }
        }
        #expect(
            problems.isEmpty,
            """
            有页面的样式 / 脚本没引全：
            \(problems.joined(separator: "\n  "))
            少引一个，页面**还在**，只是样式或交互没了 —— 浏览器只在控制台报 404，
            走查时「页面能打开」会让人以为没问题。
            """)
    }

    /// `ds.js` 依赖 `i18n.js` 先定义 `window.DS_L10N` / `window.DS_LANGS`
    /// （ds.js line 145/192 直接读这两个全局量）。
    ///
    /// ⚠️ 这个依赖**只存在于 HTML 里 `<script>` 的先后顺序**，代码里没有任何声明 ——
    /// 交换两行 ⇒ 语言包未定义 ⇒ 文案全空，而**交换两行不会有任何报错**。
    /// 与 §8.45「有能力、没接线」同族：**依赖是隐式的，就一定要有个地方把它钉住。**
    @Test func 语言包必须排在dsjs之前() throws {
        var problems: [String] = []
        for url in try htmlFiles() {
            let html = try read(url)
            let scripts = Self.matchesWithLocation(
                in: html, pattern: ##"<script[^>]+src="([^"]+\.js)""##
            ).map { (($0.text as NSString).lastPathComponent, $0.location) }
            let names = scripts.map { $0.0 }
            guard let i18n = names.firstIndex(where: { $0.contains("i18n") }),
                let ds = names.firstIndex(of: "ds.js")
            else {
                problems.append("\(url.lastPathComponent)：没同时引到 i18n.js 与 ds.js（\(names)）")
                continue
            }
            if i18n > ds {
                problems.append(
                    "\(url.lastPathComponent)：i18n.js（第 \(i18n + 1) 个脚本）排在 ds.js（第 \(ds + 1) 个）之后")
            }
        }
        #expect(
            problems.isEmpty,
            """
            语言包与 ds.js 的加载顺序不对：
            \(problems.joined(separator: "\n  "))
            ds.js 启动时直接读 window.DS_L10N / window.DS_LANGS（都由 i18n.js 定义），
            而这个依赖**只体现在 HTML 里两个 <script> 的先后** —— 交换两行不报错，
            只会让语言包变成 undefined（文案全空）。
            """)
    }

    /// 页面里引用的**本地**资源必须真实存在（相对该页面解析）。
    ///
    /// 浏览器对 404 只在**控制台**报一下：样式表 404 ⇒ 页面变成裸 HTML，
    /// 图标 404 ⇒ 那个位置空着，两者在「页面能打开」这件事上都看不出来。
    @Test func 页面引用的本地资源必须存在() throws {
        var problems: [String] = []
        var total = 0
        for url in try htmlFiles() {
            let html = try read(url)
            let dir = url.deletingLastPathComponent()
            // ⚠️ 定界符必须是 `##"…"##` 且**末尾三连引号**：正则以 `"` 收尾（匹配属性值
            // 的右引号），它后面还得再跟一个 `"` 才是 raw string 的结束引号，然后才是 `##`。
            // 只写两个引号 ⇒ 编译器把 `"` 当成正则内容，`##` 成了裸的磅字面量（编译不过）。
            for raw in Self.matches(in: html, pattern: ##"(?:href|src)="([^"]+)""##) {
                let ref = raw.split(separator: "#")[0].split(separator: "?").joined()
                guard !ref.isEmpty,
                    !ref.hasPrefix("#"), !ref.hasPrefix("http://"), !ref.hasPrefix("https://"),
                    !ref.hasPrefix("mailto:"), !ref.hasPrefix("data:"), !ref.hasPrefix("javascript:")
                else { continue }
                total += 1
                let resolved = dir.appendingPathComponent(String(ref))
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    problems.append("\(url.lastPathComponent)：'\(ref)' → \(resolved.path)")
                }
            }
        }
        // 负向锚：一条本地引用都没扫到 = 口径失效
        #expect(total >= 20, "只扫到 \(total) 条本地引用 —— 解析口径失效（假绿）")
        #expect(
            problems.isEmpty,
            """
            页面引用了不存在的本地资源：
            \(problems.joined(separator: "\n  "))
            浏览器对 404 **只在控制台报一下**：样式表没了页面变成裸 HTML、
            图片没了那个位置空着 —— 而「页面能打开」这件事完全不受影响。
            """)
    }

    private struct LinkScan {
        var links: [(href: String, text: String)] = []
    }

    private func loadLinks() throws -> LinkScan {
        let idx = try read(designRoot.appendingPathComponent("index.html"))
        // 卡片链接是**多行**的（`<a class="scard-link" …>` 里嵌了标题与描述），
        // 导航链接是单行的 —— 一个正则要同时吃下两种，故 `.` 需跨行。
        //
        // ⚠️ 定界符必须用 **`##"`**：正则里的 `[^"#]` 含有 `"#` 这个序列，
        // 用普通 `#"…"#` 会被当成**字符串提前结束**（编译期报错：consecutive statements）。
        // 与 §8.50.3「注释会蒙过扫描器」同族：**自己写的文本里出现了自己用的定界符**。
        let pattern = ##"<a\s[^>]*href="(screens/[^"#]+)"[^>]*>(.*?)</a>"##
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return LinkScan() }
        var scan = LinkScan()
        let range = NSRange(idx.startIndex..<idx.endIndex, in: idx)
        for m in re.matches(in: idx, range: range) {
            guard let hr = Range(m.range(at: 1), in: idx),
                let tr = Range(m.range(at: 2), in: idx)
            else { continue }
            scan.links.append((String(idx[hr]), Self.plainText(String(idx[tr]))))
        }
        return scan
    }

    /// `<title>主名 · SafeOut UI v2</title>` ⇒ `主名`（页面对自己的正式命名）。
    private func pageMainTitle(_ rel: String) throws -> String? {
        let html = try read(designRoot.appendingPathComponent(rel))
        guard let t = Self.matches(in: html, pattern: #"<title>(.*?)</title>"#).first else { return nil }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// 某个页面顶部 `<nav>` 里的页面链接（`<a href="0X-….html">名字</a>`）。
    private func navLinks(of page: String) throws -> [(href: String, text: String)] {
        let html = try read(designRoot.appendingPathComponent("screens/\(page)"))
        guard let nav = Self.match(in: html, pattern: ##"<nav[^>]*>(.*?)</nav>"##) else { return [] }
        let pattern = ##"<a\s+href="([\w-]+\.html)"[^>]*>(.*?)</a>"##
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(nav.startIndex..<nav.endIndex, in: nav)
        return re.matches(in: nav, range: range).compactMap { m in
            guard let hr = Range(m.range(at: 1), in: nav), let tr = Range(m.range(at: 2), in: nav)
            else { return nil }
            return (String(nav[hr]), Self.plainText(String(nav[tr])))
        }
    }

    /// §9 文件清单里「页面文件名 → 说明」。
    private func screenListing() throws -> [String: String] {
        let spec = try read(designRoot.appendingPathComponent("DESIGN-SPEC.md"))
        guard
            let block = Self.match(
                in: spec,
                pattern: ##"^## 9\. 文件清单\s*\n+```\n(.*?)\n```"##)
        else { return [:] }
        var out: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            guard let m = l.range(of: ##"(\d\d-[\w-]+\.html)\s+(\S.*)$"##, options: .regularExpression)
            else { continue }
            let parts = l[m]
            // 文件名 + 说明（说明里的 `#` 之后是行内注释，剥掉）
            guard let mm = Self.firstMatch(in: String(parts), pattern: ##"^(\d\d-[\w-]+\.html)\s+(.*?)(?:\s+#.*)?$"##)
            else { continue }
            out[mm.0] = mm.1
        }
        return out
    }

    /// 取**第一个**匹配（整段），用于 `<nav>…</nav>` 这类**跨行**块。
    ///
    /// ⚠️ 两个 option 都不能少：`.dotMatchesLineSeparators` 让 `.` 跨行；
    /// `.anchorsMatchLines` 让 `^` 匹配**行首**（默认只匹配字符串开头 ——
    /// 少了它，「第 9 章」这种不在文件开头的行永远匹配不到，且**不报错、只返回 nil**）。
    private static func match(in text: String, pattern: String) -> String? {
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators, .anchorsMatchLines])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    /// 取第一个匹配的**两个捕获组**（文件名 / 说明）。
    /// 带**位置**（用于判断 `<script>` 的先后顺序）。
    private static func matchesWithLocation(
        in text: String, pattern: String
    ) -> [(
        text: String, location: Int
    )] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            return (String(text[r]), m.range.location)
        }
    }

    /// 取第一个匹配的**两个捕获组**（文件名 / 说明）。
    private static func firstMatch(in text: String, pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range),
            let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text)
        else { return nil }
        return (String(text[a]), String(text[b]))
    }

    /// 页面自己的 `<h1>`（取第一个）。
    private func pageH1(_ rel: String) throws -> String? {
        let html = try read(designRoot.appendingPathComponent(rel))
        guard let raw = Self.matches(in: html, pattern: ##"<h1[^>]*>(.*?)</h1>"##).first else { return nil }
        return Self.plainText(raw)
    }

    /// 一个文件名算不算**设计稿页面**。
    ///
    /// ⚠️ 工具探针的临时文件用 `_` 前缀 —— `Tools/measure_*.py` 会往 `screens/` 里
    /// 写一份「原页面 + 探针脚本」的副本：它**必须与原页面同目录**，否则相对的
    /// `../assets/ds.css` 会 404，量到的是无样式布局（这是那条技能里明写的纪律）。
    /// 这类文件**不是**设计稿页面，不该进「页面集合」，也不该被任何逐页守卫扫到。
    ///
    /// 2026-09-29 实测踩到：`swift test` 与测量脚本**并行**跑时，探针文件正好在磁盘上，
    /// 于是「每个页面都必须被索引链接到」报它是孤儿、「硬编码中文的无障碍标签」
    /// 因为它的副本被**多算了一遍**（86 → 100）—— 症状看起来**像设计稿写错了**，
    /// 实则是工具与守卫抢同一个目录。排除前缀是根治，不是把红改成绿。
    private static func isDraftPage(_ name: String) -> Bool {
        name.hasSuffix(".html") && !name.hasPrefix("_")
    }

    /// `screens/` 下的页面文件名（不含 index.html 等）。
    private func screenFiles() throws -> [String] {
        let dir = designRoot.appendingPathComponent("screens")
        return (try FileManager.default.contentsOfDirectory(atPath: dir.path))
            .filter { Self.isDraftPage($0) }.sorted()
    }

    /// 去标签 + 压平空白（`SCREEN 04\n  名字 …` ⇒ 一行）。
    private static func plainText(_ html: String) -> String {
        let stripped = replace(in: html, pattern: #"<[^>]+>"#, with: "")
        return stripped.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// 抹掉 **ASCII 数字**，其余原样（§8.75 的「数字兜底」用）。
    ///
    /// ⚠️ 与 `StatusLabelParityTests.strippingDigits` 是**同一个口径**，两处各有一份 ——
    /// 这是**故意的**：两个 suite 守的是不同的东西（那边守「同一态只能有一套文案」，
    /// 这边守「硬编码中文必须接线」），共用一个 helper 会让改动一边时**另一边悄悄变严**。
    /// 改动时**两边都要改**（`grep -rn strippingDigits Tests/` 能一次找全）。
    private static func strippingDigits(_ text: String) -> String {
        replace(in: text, pattern: #"[0-9]+"#, with: "")
    }

    private struct Scan {
        var defined: Set<String> = []
        var used: Set<String> = []
        /// **只在某个页面的 `<style>` 里定义**、`ds.css` 里没有的类（页面级备用样式）。
        var pageLocal: Set<String> = []
        /// `ds.js` 在**运行时**创建出来的类名。
        ///
        /// ⚠️ 它**不是**「用了但没定义」那一向的消费者，也**不该**被算成「零消费者」——
        /// 它的类名根本不出现在任何 HTML 的 `class` 属性里（是 JS 建的元素），
        /// 所以必须单独收一份，否则会得出「没人用」的错账。
        var runtimeCreated: Set<String> = []
    }

    private func load() throws -> Scan {
        let fm = FileManager.default
        var scan = Scan()

        // ① 主 CSS
        let cssURL = designRoot.appendingPathComponent("assets/ds.css")
        let mainCSS = Self.selectorClasses(in: Self.stripCSSComments(try read(cssURL)))
        scan.defined.formUnion(mainCSS)

        // ② 每个 HTML：`<style>` 进「定义」，body 的 class 进「使用」
        let htmls = try htmlFiles()
        #expect(htmls.count >= 8, "只找到 \(htmls.count) 个 HTML —— 设计稿目录不对")
        for url in htmls {
            let raw = try read(url)
            var local: Set<String> = []
            for block in Self.styleBlocks(in: raw) {
                local.formUnion(Self.selectorClasses(in: Self.stripCSSComments(block)))
            }
            scan.defined.formUnion(local)
            scan.pageLocal.formUnion(local.subtracting(mainCSS))
            scan.used.formUnion(Self.classAttributes(in: Self.withoutStyleBlocks(raw)))
        }

        // ③ `ds.js` 运行时创建的类也算消费者。
        //
        // ⚠️ **不能**用 `classAttributes` 去读它：那个函数只认双引号 `class="…"`，
        // 而 `ds.js` 用的是单引号 `className = '…'`。2026-09-19 实测：`ds.js` 里
        // `class="` 出现 **0 次** ⇒ 这一步此前**一个类都没收进来**，是死代码。
        // 症状是 `langbar` / `langbar__label` / `langbar__hint` / `pill` 被算成「零消费者」，
        // 而这一行的注释说它们已被算作消费者 —— **注释与代码相反**，
        // 而「零消费者」这一向当时只打印、不报警，所以没人发现（见 §8.76）。
        let jsURL = designRoot.appendingPathComponent("assets/ds.js")
        if fm.fileExists(atPath: jsURL.path) {
            let runtime = Self.runtimeClasses(in: try read(jsURL))
            scan.runtimeCreated = runtime
            scan.used.formUnion(runtime)
        }
        return scan
    }

    /// 返回（声明的键，被页面引用的键）。
    private func loadI18n() throws -> (declared: Set<String>, referenced: Set<String>) {
        let url = designRoot.appendingPathComponent("assets/i18n-extra.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            Issue.record("i18n-extra.json 顶层不是对象")
            return ([], [])
        }
        // `_comment` 是注释键，不是文案
        let declared = Set(dict.keys.filter { !$0.hasPrefix("_") })

        var referenced: Set<String> = []
        var corpus = ""
        for url in try htmlFiles() {
            corpus += Self.withoutStyleBlocks(try read(url))
        }
        let jsURL = designRoot.appendingPathComponent("assets/ds.js")
        if FileManager.default.fileExists(atPath: jsURL.path) { corpus += try read(jsURL) }

        // ① 精确形式：`data-i18n="key"`
        for m in Self.matches(in: corpus, pattern: #"data-i18n="([^"]+)""#) { referenced.insert(m) }
        // ② 精确形式：`data-i18n-attr="aria-label:key,title:key"` —— 冒号后面那半截才是键
        for raw in Self.matches(in: corpus, pattern: #"data-i18n-attr="([^"]+)""#) {
            for pair in raw.split(separator: ",") {
                if let v = pair.split(separator: ":").last { referenced.insert(String(v)) }
            }
        }
        // ③ 兜底（**偏松**）：键名以带引号的字符串形式出现就算被引用。
        //    会漏报、不会误报 —— 宁可放过，也不能把活着的键判成死的。
        for k in declared where corpus.contains("\"\(k)\"") { referenced.insert(k) }
        return (declared, referenced)
    }

    /// 返回（图标表里定义的名字，被 `data-i` 用到的名字）。
    private func loadIcons() throws -> (defined: Set<String>, used: Set<String>) {
        let js = try read(designRoot.appendingPathComponent("assets/ds.js"))
        // 图标表：`var I = { … }`，以缩进 2 空格的 `};` 收尾
        guard let block = Self.matches(in: js, pattern: #"var I = \{([\s\S]*?)\n  \};"#).first else {
            Issue.record("ds.js 里找不到 `var I = { … }` 图标表 —— 结构变了？")
            return ([], [])
        }
        let defined = Set(Self.matches(in: block, pattern: #"^\s*(\w+)\s*:"#, lines: true))

        var used: Set<String> = []
        for url in try htmlFiles() { used.formUnion(Self.matches(in: try read(url), pattern: #"data-i="([^"]+)""#)) }
        used.formUnion(Self.matches(in: js, pattern: #"data-i="([^"]+)""#))
        // i18n 文案值里也可以嵌 `<i data-i="gear">`（回填后会重新水合）
        let extraURL = designRoot.appendingPathComponent("assets/i18n-extra.json")
        if FileManager.default.fileExists(atPath: extraURL.path) {
            used.formUnion(Self.matches(in: try read(extraURL), pattern: #"data-i="([^"]+)""#))
        }
        return (defined, used)
    }

    /// 文案键的**声明集** = `i18n-extra.json` ∪ `Localizable.xcstrings`。
    private static func declaredTextKeys(repoRoot: URL) throws -> Set<String> {
        var out: Set<String> = []
        let extraURL = repoRoot.appendingPathComponent(
            "Design/ui/v2/assets/i18n-extra.json")
        if let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: extraURL)) as? [String: Any] {
            out.formUnion(obj.keys.filter { !$0.hasPrefix("_") })
        }
        let xcsURL = repoRoot.appendingPathComponent("Sources/Localization/Localizable.xcstrings")
        if let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: xcsURL)) as? [String: Any],
            let strings = obj["strings"] as? [String: Any]
        {
            out.formUnion(strings.keys)
        }
        return out
    }

    /// 源指纹 = sha256(xcstrings → extra → 生成脚本)，**拼接顺序必须与
    /// `Tools/build_i18n.py` 的 `fingerprint()` 逐字一致**（那边注释里标了顺序）。
    ///
    /// 顺序写反**不会报错** —— 只会算出另一个值，于是守卫**永远红**且看不出为什么。
    /// 所以顺带钉住三件事：三个输入都得读得到、**都得有内容**。
    /// 路径写错 ⇒ `Data(contentsOf:)` 直接抛 ⇒ 不会静默；但读到 0 字节不抛，只能靠这条。
    private static func sourceFingerprint(repoRoot: URL) throws -> String {
        let rels = [
            "Sources/Localization/Localizable.xcstrings",
            "Design/ui/v2/assets/i18n-extra.json",
            "Tools/build_i18n.py",
        ]
        var sha = SHA256()
        for rel in rels {
            let data = try Data(contentsOf: repoRoot.appendingPathComponent(rel))
            #expect(data.count > 200, "\(rel) 只有 \(data.count) 字节 —— 路径写错了？")
            sha.update(data: data)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: CSS 变量

    private struct CSSVarPage {
        let name: String
        /// 出现次数（**含重复**）—— 用来判断「使用侧到底扫到多少」。
        var used: [String] = []
        /// 用了、**没写兜底**、且这一页解析不到的变量。
        var missing: [String] = []
    }

    private struct CSSVarScan {
        /// `ds.css` 里定义的（所有页面都引它，所以算全局可用）。
        var defined: Set<String> = []
        var pages: [CSSVarPage] = []
    }

    /// 变量**按页**解析：可用集 = `ds.css` ∪ **本页** `<style>`。
    /// `ds.css` 自己也作为一个「页」参与（它内部也在用 `var()`）。
    private func loadCSSVariables() throws -> CSSVarScan {
        let cssURL = designRoot.appendingPathComponent("assets/ds.css")
        let css = Self.stripCSSComments(try read(cssURL))
        var scan = CSSVarScan()
        scan.defined = Set(Self.matches(in: css, pattern: #"(--[\w-]+)\s*:"#))
        scan.pages.append(Self.page(name: "assets/ds.css", text: css, available: scan.defined))

        for url in try htmlFiles() {
            let raw = try read(url)
            let blocks = Self.styleBlocks(in: raw)
            var own: Set<String> = []
            for b in blocks {
                own.formUnion(Self.matches(in: Self.stripCSSComments(b), pattern: #"(--[\w-]+)\s*:"#))
            }
            // 本页可见 = 全局 + 本页 <style>（**不含别的页面**）
            let body =
                Self.withoutStyleBlocks(raw) + "\n"
                + blocks.map { Self.stripCSSComments($0) }.joined(separator: "\n")
            scan.pages.append(
                Self.page(
                    name: url.lastPathComponent,
                    text: body,
                    available: scan.defined.union(own)))
        }
        return scan
    }

    private static func page(name: String, text: String, available: Set<String>) -> CSSVarPage {
        // 带兜底的 `var(--x, …)`：作者明说了「没有就用兜底」，不算断链。
        let withFallback = Set(matches(in: text, pattern: #"var\(\s*(--[\w-]+)\s*,"#))
        var p = CSSVarPage(name: name)
        for v in matches(in: text, pattern: #"var\(\s*(--[\w-]+)"#) {
            p.used.append(v)
            if !withFallback.contains(v) && !available.contains(v) { p.missing.append(v) }
        }
        return p
    }

    // MARK: DOM 目标

    private struct DOMScan {
        /// （查询形式，选择器原文）
        var selectors: [(form: String, text: String)] = []
        var classes: Set<String> = []
        var ids: Set<String> = []
        /// 所有已知属性名 = HTML 静态 ∪ ds.js 动态赋值
        var attrs: Set<String> = []
        /// **只**从 HTML 静态解析到的属性名 —— 用来查「豁免表是不是过期了」
        var htmlAttrs: Set<String> = []
        /// （查询形式，选择器原文，解析不到的那个目标）
        var missing: [(form: String, selector: String, target: String)] = []
    }

    private func loadDOM() throws -> DOMScan {
        let js = try read(designRoot.appendingPathComponent("assets/ds.js"))
        var s = DOMScan()

        // ① 查询：四种调用形式 + `closest` / `matches`
        let forms: [(String, String)] = [
            ("querySelector", #"querySelector\(\s*['\"]([^'\"]+)['\"]"#),
            ("querySelectorAll", #"querySelectorAll\(\s*['\"]([^'\"]+)['\"]"#),
            ("getElementById", #"getElementById\(\s*['\"]([^'\"]+)['\"]"#),
            ("getElementsByClassName", #"getElementsByClassName\(\s*['\"]([^'\"]+)['\"]"#),
            ("closest/matches", #"\.(?:closest|matches)\(\s*['\"]([^'\"]+)['\"]"#),
        ]
        for (form, p) in forms {
            for text in Self.matches(in: js, pattern: p) { s.selectors.append((form, text)) }
        }

        // ② 来源 A：HTML 静态（`<style>` 里的内容不算）
        var corpus = ""
        for url in try htmlFiles() { corpus += Self.withoutStyleBlocks(try read(url)) }
        s.classes.formUnion(Self.classAttributes(in: corpus))
        s.ids.formUnion(Self.matches(in: corpus, pattern: #"\bid="([^"]+)""#))
        // ⚠️ 属性可能是**无值的**（`<div data-expandable>`），只认 `data-x=` 会漏掉它
        // ⇒ 用前瞻收到 `=` / 空白 / `>` 三种结尾。
        let htmlAttrs = Self.matches(in: corpus, pattern: #"\s(data-[\w-]+)(?=[\s=>])"#)
        s.htmlAttrs.formUnion(htmlAttrs)
        s.attrs.formUnion(htmlAttrs)

        // ③ 来源 B：ds.js 自己动态造出来的
        for v in Self.matches(in: js, pattern: #"\.className\s*=\s*['\"]([^'\"]+)['\"]"#) {
            s.classes.formUnion(v.split(separator: " ").map(String.init))
        }
        for v in Self.matches(in: js, pattern: #"classList\.(?:add|toggle|remove)\(\s*['\"]([^'\"]+)['\"]"#) {
            s.classes.insert(v)
        }
        for v in Self.matches(in: js, pattern: #"setAttribute\(\s*['\"]class['\"]\s*,\s*['\"]([^'\"]+)['\"]"#) {
            s.classes.formUnion(v.split(separator: " ").map(String.init))
        }
        s.ids.formUnion(Self.matches(in: js, pattern: #"\.id\s*=\s*['\"]([^'\"]+)['\"]"#))
        // 任意属性名（含 `aria-*` / `data-*`）—— 只要 ds.js 会写出来，这个属性就算「存在」
        s.attrs.formUnion(Self.matches(in: js, pattern: #"setAttribute\(\s*['\"]([\w-]+)['\"]"#))

        // ④ 判定：`#id` / `.class` / `[attr]` 三种目标各自查表
        for (form, text) in s.selectors {
            // ⚠️ `target` 一律存**裸名**（不带 `#` / `.` / `[]`）——
            // 豁免表的键也是裸名，两边形状不同就会**永远匹配不上**（账本形同虚设）。
            switch form {
            case "getElementById":
                if !s.ids.contains(text) { s.missing.append((form, text, text)) }
            case "getElementsByClassName":
                if !s.classes.contains(text) { s.missing.append((form, text, text)) }
            default:
                for i in Self.matches(in: text, pattern: #"#([\w-]+)"#) where !s.ids.contains(i) {
                    s.missing.append((form, text, i))
                }
                for c in Self.matches(in: text, pattern: #"\.([\w-]+)"#) where !s.classes.contains(c) {
                    s.missing.append((form, text, c))
                }
                for a in Self.matches(in: text, pattern: #"\[([\w-]+)[\]=]"#) where !s.attrs.contains(a) {
                    s.missing.append((form, text, a))
                }
            }
        }
        return s
    }

    /// 取正则的第 1 捕获组。
    /// - parameter lines: 需要 `^` 按行匹配时打开（例如逐行取对象的键）。
    private static func matches(in text: String, pattern: String, lines: Bool = false) -> [String] {
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: lines ? [.anchorsMatchLines] : []
            )
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func htmlFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: designRoot, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { Self.isDraftPage($0.lastPathComponent) }
            .sorted { $0.path < $1.path }
    }

    /// 去掉 `/* … */` 注释（注释里常写着别的数字 / 类名，不剥会误收）。
    private static func stripCSSComments(_ text: String) -> String {
        Self.replace(in: text, pattern: #"/\*[\s\S]*?\*/"#, with: " ")
    }

    /// 取 `<style>` 块 —— **第二个定义源**，别漏（§8.52.1）。
    private static func styleBlocks(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<style[^>]*>([\s\S]*?)</style>"#) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return re.matches(in: html, range: range).compactMap { m in
            Range(m.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private static func withoutStyleBlocks(_ html: String) -> String {
        Self.replace(in: html, pattern: #"<style[^>]*>[\s\S]*?</style>"#, with: " ")
    }

    /// 只取**选择器位置**的类名 —— 先抹掉声明体，否则属性值里的 `.5px` 之类会被误收。
    private static func selectorClasses(in css: String) -> Set<String> {
        var text = css
        // `@media (…) {` 的条件部分先抹掉（保留 `{`），否则里面的类会被当成属性值
        text = Self.replace(in: text, pattern: #"@media[^{]*"#, with: " ")
        text = Self.replace(in: text, pattern: #"\{[^}]*\}"#, with: "{ }")
        guard
            let re = try? NSRegularExpression(
                pattern: #"(?:^|[\s,>+~])\.([a-zA-Z][\w-]*)"#, options: [.anchorsMatchLines]
            )
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(
            re.matches(in: text, range: range).compactMap { m in
                Range(m.range(at: 1), in: text).map { String(text[$0]) }
            })
    }

    private static func classAttributes(in html: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"class="([^"]*)""#) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var out: Set<String> = []
        for m in re.matches(in: html, range: range) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            out.formUnion(String(html[r]).split(separator: " ").map(String.init))
        }
        return out
    }

    /// `ds.js` **运行时创建**的类名 —— 只认三种「类列表字面量」的写法：
    ///
    /// - `className = '…'`（`ds.js` 用的是这一种）
    /// - `classList.add/toggle/remove('…')`
    /// - `class="…"`（模板串，将来可能用）
    ///
    /// ⚠️ **口径必须是「类列表字面量」，不能是「字符串里出现过这个类名」**。
    /// 宽松口径（`'…'` 里含类名即算）实测会把 14 个类判成「运行时创建」，其中
    /// **`btn`（63 处消费者）、`row`（10 处）、`ds`、`switch`** 全是假命中 ——
    /// 病根是 `\bglass\b` 会命中 `'glass-thick'` 这类**别的类的名字**，
    /// 以及 `i18n.js` 的正文里出现 `glass`（「frosted glass」）。
    /// 假命中的后果不是报错，而是**把一个有 63 处消费者的类算成「运行时创建」** ——
    /// 于是它会从「零消费者」账本里消失，账本看起来更干净，实际更错。
    private static func runtimeClasses(in js: String) -> Set<String> {
        let patterns = [
            #"className\s*=\s*['"]([^'"]*)['"]"#,
            #"class\s*=\s*['"]([^'"]*)['"]"#,
            #"classList\.(?:add|toggle|remove)\(([^)]*)\)"#,
        ]
        var out: Set<String> = []
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(js.startIndex..<js.endIndex, in: js)
            for m in re.matches(in: js, range: range) {
                guard let r = Range(m.range(at: 1), in: js) else { continue }
                for token in String(js[r]).split(separator: " ") {
                    let name = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    // 插值 / 变量一律跳过：`${x}`、`foo` 不是类名
                    guard !name.isEmpty, !name.contains("${"), !name.contains("$") else { continue }
                    out.insert(name)
                }
            }
        }
        return out
    }

    private static func replace(in text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
