import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 设置面板的**排版契约**测试。
///
/// **为什么需要**：面板尺寸是常量，五页内容的自然高度却随文案与内边距变化。
/// 历史上两者脱节（内容约 718pt vs 面板 520pt），结果是「关于 / 更新」两段被折叠线
/// 挡在滚动区外 —— 用户打开设置看不到它们，反馈为「设置界面排版不好看」。
/// 光靠人眼打开面板看一遍发现不了「几乎溢出」，所以把四件事钉成测试：
/// ① 头部 + **任一分类页**内容 ≤ 面板高度（放不下就会有内容被藏，且**不会报错**）；
/// ② 面板高度由**最高的那一页**决定，既不超出（截内容）也不虚高（留空白带）；
/// ③ 中文下实现与设计稿**逐点相同**（否则「整体缩小字号」也能让 ①② 变绿，而那是排版走样）；
/// ④ 分隔线只出现在**卡片内的行与行之间**（首行上方不该顶着一条线）。
///
/// ## ⚠️ 两栏形态（2026-09-29）之后口径变了什么
///
/// 单栏时代高度 = 五组**纵向相加** ⇒ 面板高度成了「最长那门语言」的函数
/// （英文最坏 916.20 / 容器 920，只剩 **3.8pt** ⇒ 一个字符都加不动）。
/// 两栏之后高度 = **最高的那一页**，与其它四页无关 —— 判据因此从
/// 「五组之和 ≤ 920」换成「**逐页 × 逐语言**都不超」。
///
/// ⚠️ **单栏的旧基准（899.94 / 916.20 / 876 / 800）已退役**，别再拿它们当期望值：
/// 它们量的是「五组相加」那个形态，两栏下这个数**根本不存在**。
/// 两栏的基准由 `Tools/measure_settings_split.py` 实量（本文件 ``designFrameHeights``）。
///
/// 高度断言用「≤」而不是「==」：中文与英文文案长度不同，折行数可能不同，
/// 只要**任何语言下都放得下**就成立（`SettingsView` 仍保留 `ScrollView` 兜底）。
/// 「不许虚高」由 ``最高的那一页决定面板高度()`` 用上界单独盯。
@MainActor
struct SettingsLayoutTests {

    /// 设计稿每帧的**内容自然高**（头部 52 + 正文）—— **v3 口径：详情区宽 592**。
    ///
    /// ## 这些数是量出来的，不是抄的
    ///
    /// ```bash
    /// /Users/wenbo/.workbuddy/binaries/python/versions/3.13.12/bin/python3 \
    ///     Tools/measure_settings_v3.py
    /// ```
    ///
    /// ⚠️ **v3 换脚本了，别再用 `measure_settings_split.py`**：那个量的是 v2 独立设置窗口
    /// （720×440、左栏贴边 ⇒ 详情区宽 **520**）。v3 把设置并进主窗口详情区之后宽度是 **592**，
    /// 说明文字折行更少 ⇒ 每页更矮。**宽度变了，那批数就整体作废**（HANDOFF §5 点名的第一件事）。
    ///
    /// 脚本自带四条自证（`svg>0`、`readyState` 已离开 `loading`、选择器没命中就退出码 1、
    /// **回读 `.sdetail` 实宽并要求 ≈592** —— 最后这条防的是「CSS 覆盖没生效、
    /// 静默给出 520 宽下的旧数」），且**量与出图钉在同一门语言**（它会显式调 `dsSetLang`）
    /// —— 改这段结构后必须重跑，**不许手抄**：手抄的数会与实现一起漂，
    /// 而 ``designFrameHeights`` 那条断言比的是「实现 vs 这里写的数」，两边一起漂它就**一直绿**。
    ///
    /// ## 还有一条**交叉校验**（v3 新增，别跳过）
    ///
    /// v3 稿（`screens/_10-combined-draft.html`）只画了**两帧**：磁盘页 + 设置「通用」页。
    /// 其余四页稿里没有 ⇒ 它们的基准走「**v2 内容 + v3 宽度**」。
    /// 凭什么算设计稿口径：v3 的 `assets/ds.css` 与 v2 **逐字相同**、设置页类名与结构同源
    /// ⇒ 同一段 HTML 在 592 宽下的布局是确定的。
    ///
    /// `measure_settings_v3.py` 会把两路**并排量**并打出差值 ——
    /// 「通用」页实测 **两路逐点相同（差 0.00）**，这就是上面那句论证的证据。
    ///
    /// 实测（2026-09-30，`--lang both`）：
    ///
    /// | 帧 | 页面 | zh-Hans | en |
    /// |---|---|---|---|
    /// | 0 | 通用 | **308.34** | 324.28 |
    /// | 1 | 通用 · 登录项等待系统批准 | **352.34** | **368.28** |
    /// | 2 | 外观 | 190.78 | 206.72 |
    /// | 3 | 更新 | 264.34 | 264.34 |
    /// | 4 | 诊断 | 146.78 | 146.78 |
    /// | 5 | 关于 | 251.03 | 251.03 |
    ///
    /// ## v3 只改动了「通用」页（−16pt），其余四页逐点未变 —— 而且原因是可核对的
    ///
    /// 只有「通用」页有会**换行**的长说明文字 ⇒ 详情区从 520 变宽到 592 之后它少折一行。
    /// 其余四页的行都没到折行边界 ⇒ 宽度变化对它们没有影响。
    /// **这不是「大概没变」，是两路量出来一致、且与 v2 的数逐个对上的。**
    /// （所以下表里那四页与 v2 时代同值**不是抄来的惰性**，谁再改宽度就得重跑脚本看它们动不动。）
    ///
    /// ⚠️ **判据必须是「最长的那门语言」**：只量中文会取到 352.34，短 32pt。
    private static let designFrameHeights: [SettingsSection: CGFloat] = [
        .general: 308.34,
        .appearance: 190.78,
        .updates: 264.34,
        .diagnostics: 146.78,
        .about: 251.03,
    ]

    /// **系统控件固有偏差**（v3 交还系统样式后新增）：`Toggle(.switch)` 固有高 **24pt**，
    /// 设计稿画的 `.switch` 是 **22pt** ⇒ 每个「**没有说明文字**的开关行」贡献 **+2**。
    ///
    /// ## 这个数是从哪来的（不是从实现量出来的，别怀疑循环论证）
    ///
    /// 探针 `.build/probe/v3_switch_height/`（离屏 `fittingSize`）：
    ///
    /// | 量物 | 高 |
    /// |---|---|
    /// | 系统 `Toggle(.switch)`（labelsHidden） | **24.00** |
    /// | 行（label + 系统 Toggle，padding 12/16） | 48.00 |
    /// | 同行、开关钉 `frame(height: 22)` | 46.00 |
    ///
    /// 设计稿侧 `.switch` 在 `ds.css` 里钉的是 22 ⇒ 差 **2/行**，与「通用」页实测
    /// 310.4 − 308.34 = **2.06**（多出的 0.06 是折行/浮点噪声）吻合。
    /// **有说明文字的开关行不贡献**：那种行的行高由说明文字决定，盖过控件差
    /// （⇒ 其余四页差 ≤0.98，逐点吻合）。
    ///
    /// ## HANDOFF 为什么不许把开关钉回 22
    ///
    /// §3.7 类别 3：系统控件「❗什么都不做」。钉 `frame(height: 22)` 是往系统控件上
    /// 叠自绘约束，退回老路 ⇒ 偏差只能记在**判据侧**，不能消在**实现侧**。
    ///
    /// ⚠️ **「通用」页增删一行无说明开关行，这里的数必须跟着改**
    /// （默认态 1 行：Dock 图标；第三态多 1 行：登录项行 —— 见 ``登录项待批准态的高度等于设计稿()``）。
    private static let systemToggleDelta: [SettingsSection: CGFloat] = [
        .general: 2  // 默认态：Dock 图标那一行（无说明）
    ]

    /// 设计稿**第 2 帧**（通用 · 登录项等待系统批准）的高度 —— 同一个页面的**另一帧**。
    ///
    /// ## 为什么它不在 ``designFrameHeights`` 里
    ///
    /// 那张表按**分类**索引（一页一个数）。而这一帧与第 1 帧是**同一页**，
    /// 只是多了一个条件分支 —— 塞进那张表要么覆盖掉 308.34、要么给 `SettingsSection`
    /// 编一个假分类。所以另立一张**按语言**索引的表：
    ///
    /// | 语言 | 高度（v3 口径） |
    /// |---|---|
    /// | `zh-Hans` | **352.34** |
    /// | `en` | **368.28** ← 就是 ``designTallestFrame``（2026-10-10 重量，旧值 384.22） |
    ///
    /// ⚠️ **两个数各有出处，不是同一个数抄两遍**：308.34 是第 1 帧、352.34 是第 2 帧。
    /// 而 ``designTallestFrame``（368.28）**正是这里的英文版**。
    ///
    /// ## v3 起它**不再是**面板高度的理由（这一点变了，别照旧读）
    ///
    /// v2 的面板高 **440** 是照这一帧的英文版定的 —— 设置窗口的**唯一**职责就是装设置内容，
    /// 所以高度必须贴着内容、不许留白。v3 的窗口是**主窗口**（800×520），
    /// 同时装磁盘列表与设置五页 ⇒ 高度由整体形态定，**与设置内容无关**。
    ///
    /// 这条断言仍然钉**这一帧自身**的绝对值（那一行受阻提示行有没有插进去、形态走没走样），
    /// 但**不再**用于推导面板高 —— 后者已由 `MainWindowTests.窗口尺寸为设计稿` 守着。
    ///
    /// 实测命令（`--lang both`）：`Tools/measure_settings_v3.py`。
    private static let designPendingApprovalHeights: [String: CGFloat] = [
        "zh-Hans": 352.34,
        // 384.22 → 368.28（2026-10-10 文案去 AI 化）：`takeOverFinderEjectFootnote`
        // 与 `launchAtLoginFootnote` 在英文下都变短，这一帧（英文最坏情形）随之矮 15.94pt。
        // ⚠️ **重量得来，不要手抄**：`python3 Tools/measure_settings_v3.py --json`
        // 取 `v2@592` → `en` → `frames[index=1].total`。
        "en": 368.28,
    ]

    /// 第三态比默认态**多**出的那条无说明开关行：登录项行 ——
    /// 待批准态下 `launchAtLoginDescription` 返回 `nil`（说明整体搬到受阻行），
    /// 行高改由系统 Toggle（24pt）决定 ⇒ 在 ``systemToggleDelta`` 的 1 行之上**再 +2**
    /// （第三态帧共 **2 行** ⇒ 总偏差 4，别只算这一条）。
    private static let pendingApprovalExtraToggleDelta: CGFloat = 2

    /// 设计稿**最高的一帧** = 通用 ·「登录项等待系统批准」· 英文 = **368.28**（v3 口径同值）。
    /// 旧值 384.22 → 368.28 是 2026-10-10 文案改写后重量所得（英文下两条说明都变短）。
    ///
    /// ⚠️ **v3 起它不再是「面板高度」的依据**：v2 的 440 是照它算的（旧值下 440 − 384.22 = 55.78），
    /// 因为那时窗口的职责就是装设置内容。v3 的窗口是主窗口，高度由整体形态定。
    ///
    /// 它现在只服务于**下界**那一向：「详情区比最高帧高出 ≥ 8pt」
    /// = 再来一行说明也不会被静默裁掉。
    /// （上界那一向 v3 没有对象了 → 退役，理由见 ``designSlackCeiling`` 那一段。）
    ///
    /// ## ⚠️ 为什么不拿实现自己的最高帧（这条判据的基准是刻意选的）
    ///
    /// 2026-09-29 之前，产品侧那一态与设计稿**故意不同形**（只换一句说明，
    /// 不画那行受阻提示行）⇒ 实现最高帧只有 **340.4**，比设计稿矮 44pt。
    /// 当时若拿实现当基准，会算出「面板虚高 100pt」⇒ **把设计稿自己要的高度判成 bug**。
    ///
    /// 形态对齐之后（§8.153）两者几乎相等了 —— 当时实测实现最高帧 **384.40**（同一帧，
    /// 差 0.18pt 是亚像素舍入）。但**基准仍然必须拿设计稿**，理由与数值是否相等无关：
    ///
    /// - 拿实现当基准 ⇒ 实现**漂矮**时上界跟着降 ⇒ 这条判据**一直绿**（典型的没牙）
    /// - 拿设计稿当基准 ⇒ 实现漂矮立刻触发「面板虚高」，人才会去看
    ///
    /// 完整推导见 ``面板高度既不截内容也不虚高()`` 与 `DesignTokens.Size.settingsPanel`。
    ///
    /// ⚠️ 这个数变了就要重跑 `Tools/measure_settings_split.py`，并同步复核 440。
    /// 它与 ``designPendingApprovalHeights`` 的 `en` 项**是同一个数**（同一帧、同一语言）。
    private static let designTallestFrame: CGFloat = 368.28

    /// ⚠️ **v3 退役：这里原有 `designSlackCeiling = 60`（「面板高 − 设计稿最高帧」的上界）。**
    ///
    /// 它守的是「设置窗口虚高、底部一条空白带」—— 而那条判据能成立，靠的是一个前提：
    /// **窗口高度由设置内容倒推**（v2 的 440 就是照最高帧 + 余量定的；旧值下是 384.22 + 55.78）。
    ///
    /// v3 把这个前提拿掉了：窗口是**主窗口**（800×520），同时装磁盘列表与设置五页，
    /// 高度由整体形态定、**与设置内容无关** ⇒ 详情区底部必然留白，
    /// 而且是设计稿自己画的（`screens/_10-combined-draft.html` 帧 2 就是如此，
    /// 实测余量比 v2 当时那 55.78 大）。
    /// 此时再拿「余量 ≤ 60」判虚高，等于**把设计稿自己画的留白判成 bug**。
    ///
    /// 那「窗口不许被改大」由谁守？—— 由 `MainWindowTests.窗口尺寸为设计稿`（800×520）
    /// 守着，比在这里盯余量更直接（那边断了，详情区高自然也不对）。
    ///
    /// **保留下来的那一向（下界 8）在** ``面板高度既不截内容也不虚高()`` 里：
    /// 它守的是「内容别溢出、再来一行也别被静默裁掉」—— 与窗口由谁定尺寸无关，v3 依然成立。

    /// 本文件量高度时**统一注入**的「接管闸门」状态 —— 与设计稿同一版（开关可用）。
    ///
    /// ## 为什么每一处都必须显式写
    ///
    /// 这个值的真值来自**本机的 TCC 状态**（谁给没给完全磁盘访问），而它取决于
    /// 跑测试的那个进程 —— xctest 的责任方是拉起它的终端。不注入的话，
    /// 同一份高度契约会在有授权的机器上量到一版、没授权的机器上量到另一版，
    /// **红绿都与被测代码无关**。
    ///
    /// ## 为什么选 `.usable` 而不是 `.needsFullDiskAccess`
    ///
    /// 因为**它才是设计稿画的版本**（`05-settings.html` 那一行是开关），
    /// 而本文件所有绝对值断言（900.20 / 916.20）都是拿设计稿对齐过的。
    /// 未授权那一版由 ``接管未授权态不得比可用态更高()`` 单独量，判据是**相对比较**、
    /// 不依赖绝对数 —— 于是它换台机器也成立。
    private let designTakeOver: AppSettings.TakeOverAvailability = .usable

    /// 「更新」组那两个开关**设计稿假设的环境**：具备能力 + 检查开 + 下载关。
    ///
    /// **与上面 `designTakeOver` 同一个理由、同一个毛病**：这两个开关的值来自 Sparkle、
    /// 「具不具备能力」来自 updater 建没建起来，而 xctest 进程里 updater 建不起来
    /// ⇒ 不注入的话，本文件量到的是**永远禁用态**那一版 —— 而真机上用户看到的是**可用态**，
    /// 设计稿画的也是可用态（`05-settings.html` / `08-update.html` 里开关是能拨的）。
    ///
    /// ⚠️ **下载取 `false`**：它是 Sparkle 的默认（`SUAutomaticallyUpdate` 没写），
    /// 也就是真机上**没拨过开关**的用户看到的样子 —— 面板高度只该由这个默认态决定。
    ///
    /// ⚠️ **别把它改成「全部为 true」**：那会把「下载也开着」混进定高的输入里。
    /// 「下载开着」「不具备能力」「检查没开」这三态由
    /// ``更新两行各态渲染出来必须一样高()`` 与 ``更新两行不可用态不得比可用态更高()``
    /// 以**相对比较**覆盖（不依赖绝对值，换台机器也成立）。
    private let designAutoUpdateRows = AutoUpdateRowsState(
        canAutoUpdate: true, checksIsOn: true, downloadsIsOn: false)

    /// 在给定宽度下渲染并返回**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    ///
    /// ⚠️ **必须用 `sizeThatFits(in:)`，不能用 `setFrameSize + fittingSize`**（2026-09-15 修正）。
    /// `NSHostingView.fittingSize` 返回的是**无宽度约束的理想尺寸** —— 宽度根本没生效。
    /// 实测同一份内容：`fittingSize` 报 `497×470`（宽度 497 ≠ 传入的 440），
    /// `sizeThatFits(in: 440×∞)` 报 `440×484`。
    ///
    /// 这个差别**恰好掩盖了一整类缺陷**：内容横向放不下时，弹性列（设置行的标签列）
    /// 会被压窄、文字改竖排，高度随之暴涨 —— 但理想尺寸里没有这回事，高度看着一直正常。
    /// 旧写法因此让「视觉效果」那行被压成竖排单字、内容真实高度 910pt 而面板只有 498pt
    /// 可用（45% 内容被卷走）长达一整个版本没被发现。
    ///
    /// 手法可靠性用**已知高度的磁盘行**做过对照（真值 158pt）：
    /// `sizeThatFits` → 158 ✓ ／ `fittingSize` → 158（高度对但宽度错）／ 位图扫描 → 369 ✗
    /// （`bitmapImageRepForCachingDisplay` 的缓冲区不保证清零，会扫到未初始化内存）。
    ///
    /// ⚠️ **在中文下渲染**：本文件断言的面板尺寸（480×920）是**按中英实测**出来的，
    /// 其中宽度按英文定、高度按英文 782.6 + 余量定。
    /// 不钉就跟随 `Locale.current` → 英文机器上必红（2026-09-17 CI 连续 6 次红即此因）。
    /// 英文下的表现由本文件的 ``英文下也必须放得下()`` 覆盖。
    ///
    /// ⚠️ **`view` 必须是 `@autoclosure`**：实参表达式在**进入本函数之前**求值，
    /// 而它可能含 `L10n.tr`（分区标题、行标签 …），不推迟求值就会解析成 `Locale.current` 的
    /// 那一版，钉住渲染也救不回来。理由同 `OnboardingLayoutTests.renderedSize`。
    private func renderedSize<V: View>(
        _ view: @autoclosure () -> V,
        width: CGFloat,
        language: String = TestLanguage.design
    ) -> CGSize {
        TestLanguage.with(language) {
            _ = NSApplication.shared
            let hosting = NSHostingController(rootView: view())
            return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
    }

    /// 渲染成位图后，统计**卡片内部的行间分隔线**条数。
    ///
    /// **为什么不能用「整行都有 alpha」来判定**：v2 的设置项放在 `.scard` 里
    /// （`bg-raised` 实心填充），卡片内**每一行**都是不透明的 —— 按老办法会把
    /// 卡片的每一行都数成分隔线（实测 298 条）。
    ///
    /// 现在的判据是「**相对上下都变暗、且横向均匀**」：
    /// - 分隔线是 8% 黑叠在白色卡片上 → 比上下都暗一点点，且横向亮度方差接近 0；
    /// - 卡片填充行 → 与上下同色，不构成凹陷；
    /// - 文字行 → 横向亮度方差很大（黑字 + 白底），被方差条件排除；
    /// - 卡片自身的圆角描边行 → 上下相邻行里有一行落在卡片外（覆盖率不足），被邻居条件排除。
    private func horizontalDividerCount(_ view: some View, width: CGFloat) -> Int {
        // ⚠️ **出图必须与「量高度」钉在同一种语言下**（2026-09-28 修，CI 红）。
        //
        // `renderedSize` 内部已经 `TestLanguage.with(TestLanguage.design)`（理由见它的注释：
        // 设计稿数字全按中文实测）。但**出图这一半当时漏了**，于是成了
        // 「量高度按中文、画图跟随 `Locale.current`」的错配：
        //   - 本地开发机 `Locale.current` 就是 `zh-Hans` ⇒ 两者一致 ⇒ 一直绿；
        //   - CI（runner 系统语言英文）画出来的是英文版 ⇒ 行高不同 ⇒ 少判一条线。
        // 实测（2026-09-28，CI run `36382577179`）：不钉 → `count=4`；钉住 → `count=5`（期望值正好 5）。
        // ⇒ 与 `renderedSize` 同源，别让「量一半、画一半」再分家。
        return TestLanguage.with(TestLanguage.design) {
            // 高度取 `sizeThatFits` 的**真实**高度（理由见 `renderedSize` 注释）：
            // 用 `fittingSize` 会拿到偏小的理想高度，把内容底部裁掉，
            // 万一分隔线正好落在被裁区域就会漏数。
            let realHeight = renderedSize(view, width: width).height
            // ⚠️ **高度向上取整**：`OffscreenRender.bitmap` 按 `Int(size.height * 2)` **截断**，
            // 传 773.4 只拿到 1546px（差 0.8pt 不足），底部那条线有被裁的风险。
            guard
                let rep = OffscreenRender.bitmap(
                    view,
                    size: CGSize(width: width, height: realHeight.rounded(.up)),
                    // ⚠️ **背景必须 `.clear`，不能垫白**：判据靠「卡片外那一行覆盖率不足」
                    // 排除卡片自身的圆角描边（见上面那段注释）。垫白底会让卡片之间也变成
                    // 不透明 ⇒ 描边行的上下邻居覆盖率也过线 ⇒ 多判出线。
                    background: .clear)
            else { return -1 }
            return dividerCount(in: rep, width: width)
        }
    }

    /// 从一张已画好的位图里数分隔线。**只判读、不出图** ——
    /// 出图一律走 ``OffscreenRender/bitmap(_:size:appearance:background:)``（SPEC §8.131，
    /// 自建位图会被 `PixelReadPathTests` 拦）。
    private func dividerCount(in rep: NSBitmapImageRep, width: CGFloat) -> Int {
        guard let data = rep.bitmapData else { return -1 }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel

        /// 逐行统计：覆盖率（alpha > 8 的像素占比）与不透明像素的亮度均值/标准差。
        func rowStats(_ y: Int) -> (coverage: Double, luma: Double, std: Double) {
            var opaque = 0
            var covered = 0
            var sum = 0.0
            var sumSq = 0.0
            for x in 0..<w {
                let p = y * bpr + x * spp
                let a = data[p + 3]
                if a > 8 { covered += 1 }
                guard a > 200 else { continue }
                let luma =
                    0.2126 * Double(data[p]) + 0.7152 * Double(data[p + 1])
                    + 0.0722 * Double(data[p + 2])
                opaque += 1
                sum += luma
                sumSq += luma * luma
            }
            guard opaque > 0 else { return (Double(covered) / Double(w), 0, 0) }
            let mean = sum / Double(opaque)
            let variance = max(0, sumSq / Double(opaque) - mean * mean)
            return (Double(covered) / Double(w), mean, variance.squareRoot())
        }

        let stats = (0..<h).map(rowStats)
        let gap = 4
        var dividerRows: [Int] = []
        for y in gap..<(h - gap) {
            guard stats[y].coverage > 0.85,
                stats[y - gap].coverage > 0.85,
                stats[y + gap].coverage > 0.85
            else { continue }
            // 横向必须均匀（排除文字行），且比上下都暗（排除填充行）。
            guard stats[y].std < 2.5,
                stats[y].luma < stats[y - gap].luma - 1,
                stats[y].luma < stats[y + gap].luma - 1
            else { continue }
            dividerRows.append(y)
        }
        // 相邻像素行合并成一条线。
        //
        // ⚠️ **不能用 `y != previous + 1` 这种「严格相邻」判据**（2026-09-15 修正）。
        // 一条 0.5pt 的分隔线在 scale=2 的位图里是 1 个像素，但**抗锯齿会把它的
        // 上下各染一个半透明像素**，实测三行的亮度是 `250.95 / 238.95 / 250.95`
        // （上下两行只比卡片底色 254.95 暗 4）。这三行**全都**满足「比上下都暗」
        // 的判据，于是进入 `dividerRows`。旧写法只在计数时推进 `previous`，
        // 遇到 `[246, 247, 248]` 会数成 2 条（246 计一次、247 被吞、248 又计一次）——
        // 两根真实分隔线被数成 4 条，测试报「多画了线」而产品其实完全正确。
        //
        // 正确判据是「**与上一条线的距离超过一根线的像素跨度**」：
        // 同一根线内部的行间隔 ≤ 2 个像素，而真实两根线至少隔着一个行高（≈44pt ≈ 88px）。
        // 阈值取 `4 × scale`（2pt）—— 远大于抗锯齿跨度、远小于行高，中间有两个数量级的余量。
        let scale = max(1, w / max(1, Int(width)))
        let mergeGap = 4 * scale
        var count = 0
        var previous = -1_000
        for y in dividerRows {
            if y - previous > mergeGap { count += 1 }
            previous = y
        }
        return count
    }

    // MARK: 详情区的几何 helper（v3）

    /// 侧栏面板**本体之外**再内缩的宽度（本机实测 **8pt**，四边都有）。
    ///
    /// ⚠️ **它不是设计稿给的数**，是系统在 macOS 26 上的行为
    /// （统一工具栏 + `fullSizeContentView` + 全高布局 ⇒ 侧栏浮岛四边各内缩 8pt）。
    /// 详情区左缘因此落在 **208**，而不是面板本体宽度 200。
    ///
    /// ⚠️ **14–15 上没有浮岛 ⇒ 内缩为 0 ⇒ 那一代是 600**。
    /// 所以这个数**不能进 `DesignTokens`** —— 那等于把「26 有浮岛」写死进生产代码，
    /// 而生产侧的详情区宽度是**由结构保证**的（写补偿代码会在 14–15 上反而算错，
    /// 见 ``DesignTokens/Size/mainSidebarWidth`` 的注释）。
    /// 它只是**出图与量测的画布基准**：量的是「本机（26）上长什么样」。
    private let sidebarOuterInset: CGFloat = 8

    /// v3 详情区的宽度 —— `主窗口 800 − 侧栏本体 200 − 浮岛左内缩 8 = **592**`。
    ///
    /// `Design/ui/v3/HANDOFF.md` §5 那张表按「800 − 200 = 600」粗算，**少算了这 8pt**。
    /// 以实测为准（取证：`.build/probe/v3_assemble/`，量到侧栏外沿 x ∈ [8, 208]）。
    private var detailWidth: CGFloat {
        DesignTokens.Size.mainWindow.width
            - DesignTokens.Size.mainSidebarWidth
            - sidebarOuterInset
    }

    /// v3 详情区的高度 = 主窗口高 − 系统工具栏（``DesignTokens/Size/titleBarBandHeight``）。
    ///
    /// v2 时这里是「设置面板高 440」—— 一个**独立窗口**的高度，由内容夹逼出来
    /// （英文最坏 368.28 ⇒ 取 440）。v3 的设置住在详情区里 ⇒ 高度由**窗口与工具栏**
    /// 决定，不再由内容决定：内容超出走滚动，不存在「再加一行就无解」。
    private var detailHeight: CGFloat {
        DesignTokens.Size.mainWindow.height - DesignTokens.Size.titleBarBandHeight
    }

    /// 详情区**可用内容宽** = 详情区宽 − 内容区左右内边距。
    ///
    /// 这是「一切折行」真正发生的那个宽度 —— 窗口宽与它没关系，
    /// 拿窗口宽去算百分比预算会把门槛放得很松（见 ``分段控件不许吃掉标签列的宽度()``）。
    private var contentWidth: CGFloat {
        detailWidth - 2 * SettingsMetrics.detailPaddingH
    }

    /// 渲染一个分类页并返回**真实渲染尺寸**。
    ///
    /// ⚠️ **提案宽度取 ``detailWidth``（右栏宽），不是整个窗口**：两栏之后
    /// 「一页占多宽」是右栏的事 —— 拿 720 去提案会量到一个**永远不会出现**的排版
    /// （比实际宽 200pt ⇒ 折行更少 ⇒ 高度偏矮 ⇒ 高度契约**假绿**）。
    private func renderPane(
        _ section: SettingsSection,
        language: String = TestLanguage.design
    ) -> CGSize {
        renderedSize(
            SettingsSectionPane(
                section: section,
                autoUpdateRowsOverride: designAutoUpdateRows,
                takeOverAvailabilityOverride: designTakeOver),
            width: detailWidth, language: language)
    }

    /// **每一个分类页都必须放得下**：内容区头部 + 该页 ≤ 面板高。
    ///
    /// 单栏时代的判据是「五组之和 ≤ 920」（高度 = 各组**相加**）；
    /// 两栏之后高度只由**最高的那一页**决定 —— 所以判据换成「逐页都不超」，
    /// 而「最高那一页离 440 还有多远」由 ``最高的那一页决定面板高度()`` 单独盯。
    ///
    /// ⚠️ **必须逐页 × 逐语言**：漏掉任何一页，那一页放不下就没有东西会报错 ——
    /// 它只会被滚动区静默裁掉，而「被裁掉」与「本来就没那么多内容」在渲染图上
    /// 长得一模一样（本仓库反反复复吃亏的那一类）。
    ///
    /// ## 繁中为什么在名单里（2026-09-27 起的理由，两栏之后依然成立）
    ///
    /// 繁中的 footnote 实测 **65 字**，比简中的 52 字长，且字符串里夹着 `Finder`
    /// （拉丁字符）⇒ **折行位置与简中不同**。而历史上繁中在测试层面**完全没被看过**
    /// （全仓搜不到任何 `zh-Hant` 的布局量测），是架构文档 §8 待明确事项 **R3**。
    ///
    /// ⚠️ `zh-Hant` 必须**原样**传（不能写 `zh-Hant-TW`）：`L10n.tr` 的 id 解析只按 `_`
    /// 切分，`zh-Hant-TW` 会落进 `hasPrefix("zh")` 那一支 ⇒ 拿到的是**简中**文案，
    /// 这一轮就变成了「简中的第二次复读」而看不出来。
    ///
    /// ⚠️ **自证必须有**：繁中与简中的高度**逐点相同**（2026-09-27 与 09-28 两次实测都是），
    /// 于是「繁中没生效、悄悄回退成简中」与「繁中折行数恰好与简中相同」的**输出逐字相同**。
    /// 下面那条 `L10n.tr` 断言把两者分开 —— 它在 `TestLanguage.with` 之外调，
    /// `forcedLocale` 为 nil，于是 `tr` 真的走传入的 `locale`。
    ///
    /// ⚠️ **这条判据的分辨力边界**：繁中与简中高度逐点相同 ⇒
    /// 「`language:` 传成 `zh-Hans`」这类变异它**抓不住**（两种写法量出同一个数）。
    /// 它能抓住的是「繁中没生效」。将来两者高度一旦出现差异，它就自然获得分辨力。
    @Test func 每个分类页都放得下() {
        #expect(
            L10n.tr(.takeOverFinderEject, locale: Locale(identifier: "zh-Hant"))
                != L10n.tr(.takeOverFinderEject, locale: Locale(identifier: "zh-Hans")),
            "繁中与简中解析出了同一串文案 —— `zh-Hant` 没生效，下面那轮量到的其实是简中（假绿）"
        )

        let head = SettingsMetrics.headerHeight
        for language in [TestLanguage.design, "en", "zh-Hant"] {
            for section in SettingsSection.allCases {
                let pane = renderPane(section, language: language)
                let need = head + pane.height
                print(
                    "  [两栏设置] \(language) · \(section.rawValue)：头部 \(head) + 内容 \(pane.height) = \(need)pt ｜ 窗口 \(detailHeight)"
                )
                #expect(
                    need <= detailHeight,
                    """
                    [\(language)] 「\(section.rawValue)」页需要 \(need)pt（头部 \(head) + 内容 \(pane.height)），
                    超过面板 \(detailHeight)pt —— 多出来的部分会被滚动区静默裁掉。
                    首选改法是压短那一页的文案或收内边距，**不是加高面板**：
                    面板高度是按「最长语言下最高的那一页」定的（见 DesignTokens.Size.settingsPanel）。
                    """
                )
            }
        }
    }

    /// 面板高度**既要装得下最高的那一页，也不许虚高**。
    ///
    /// ## 两条判据的基准不是同一个东西（这是两栏最反直觉的一点）
    ///
    /// - **下界**（不许截内容）量的是**实现自己**的每一帧：任何一帧超过 440 就会被
    ///   `overflow` 静默切掉。逐语言 × 逐页 × 第三态，一帧都不能漏。
    /// - **上界**（不许虚高）拿的是**设计稿**的最高帧，而**不是**实现的最高帧。
    ///
    /// 为什么上界不能用实现自己的最高帧：440 这个高度是**照设计稿定的**
    /// （``DesignTokens/Size/settingsPanel`` 的推导），而设计稿的最高帧是
    /// 「通用 · 登录项等待系统批准」= **英文 368.28**。
    ///
    /// ⚠️ **2026-09-29 形态对齐之后，实现的最高帧（384.40）曾与它几乎相等** ——
    /// 但基准**仍然拿设计稿**，其理由与「两个数是否凑巧相等」无关（见 ``designTallestFrame``）：
    /// 拿实现当基准的话，实现**漂矮**时上界跟着降，这条判据就**永远绿**。
    /// （对齐之前产品侧最高帧只有 340.4 —— 那时拿实现当基准会算出「面板虚高 100pt」，
    /// 把设计稿自己要求的高度判成 bug。）
    ///
    /// ⇒ 上界写成「面板高 − 设计稿最高帧」必须落在一个**有上下界的区间**里：
    /// 下界 8 是量脚本自己的告警线（`measure_settings_split.py` 里写着
    /// 「余量 < 8pt 再加一行就会被静默裁掉」），上界 60 是「再高就该改设计稿了」。
    /// 实测贴着上界（440 − 384.22 = 55.78，旧文案下）⇒ 有人把面板调到 500 会立刻红。
    ///
    /// ## 为什么必须逐帧量（而不是只看「最长那一页」）
    ///
    /// 单栏版高度 = 五组**相加**，所以「最长的那门语言」是唯一的变量。
    /// 两栏之后**每一页**都可能成为天花板，而「哪一页最高」是随文案改的 ——
    /// 所以判据只能是「每一帧都不超」，而「最高的是谁」只打印出来供人看。
    @Test func 面板高度既不截内容也不虚高() {
        let head = SettingsMetrics.headerHeight
        var frames: [(String, CGFloat)] = []
        for language in [TestLanguage.design, "en"] {
            for section in SettingsSection.allCases {
                frames.append(
                    (
                        "\(language)·\(section.rawValue)",
                        head + renderPane(section, language: language).height
                    ))
            }
            // 第三态：整帧照量一遍（只有「通用」页会变，但这样不会漏）。
            //
            // ⚠️ **它必须在名单里**：设计稿 09 页第 2 帧就是它，而在产品侧
            // 真机上**造不出来**（要 `SMAppService` 真返回 `.requiresApproval`）
            // —— 靠 ``SettingsSectionPane/launchAtLoginStateOverride`` 注入。
            // 不注入的话这一帧在测试里根本不存在，「放不下」没有任何东西会报错
            // （本仓库反复吃亏的那一类：**没画过的状态没人看过**）。
            let third = renderedSize(
                SettingsSectionPane(
                    section: .general,
                    autoUpdateRowsOverride: designAutoUpdateRows,
                    takeOverAvailabilityOverride: designTakeOver,
                    launchAtLoginStateOverride: .requiresApproval),
                width: detailWidth, language: language)
            frames.append(("\(language)·通用·第三态", head + third.height))
        }
        let printed = frames.map { "\($0.0) \($0.1)" }.joined(separator: " ｜ ")
        print("  [两栏设置] 各帧：\(printed)")

        guard let tallest = frames.max(by: { $0.1 < $1.1 }) else {
            Issue.record("一帧都没量到 —— 上面的渲染本身就没成功，这条断言不能算通过")
            return
        }
        print("  [两栏设置] 实现最高帧 = \(tallest.0) \(tallest.1)pt")

        #expect(
            tallest.1 <= detailHeight,
            "最高的一帧「\(tallest.0)」需要 \(tallest.1)pt，超过面板 \(detailHeight)pt —— 那一页会被截掉。全部各帧：\(printed)"
        )

        // 余量：**v3 只守下界**（上界已退役，理由见 ``designSlackCeiling`` 那一段）。
        //
        // 下界守的是「内容别溢出、再来一行也别被静默裁掉」—— 与「窗口高由谁定」无关，
        // v3 依然成立。
        let designSlack = detailHeight - Self.designTallestFrame
        print("  [两栏设置] 面板高 − 设计稿最高帧 \(Self.designTallestFrame) = \(designSlack)pt")
        #expect(
            designSlack >= 8,
            "面板只比设计稿最高帧高 \(designSlack)pt（< 8）—— 余量太薄，再加一行说明文字就会被 `overflow` **静默裁掉**。要么加高面板，要么去设计稿里收内容"
        )
    }

    /// ⚠️ **这里原先有一条 `左栏几何符合设计稿()`，v3 退役。**
    ///
    /// 它量的是两栏设置窗口那个独立左栏（``SettingsSidebar``：宽 200、五项、自然高 208），
    /// 而 v3 之后设置没有自己的左栏了 —— 分类栏就是**主窗口的侧栏**
    /// （``MainSidebarView``，`List(selection:)` + `.listStyle(.sidebar)`），
    /// 浮岛、圆角、材质、选中态全归系统。
    ///
    /// **判据没有丢，只是换了地方守**：
    /// - 「宽 200」现在由 ``MainWindowContentController`` 把 `minimumThickness` 与
    ///   `maximumThickness` **一起**锁成 ``DesignTokens/Size/mainSidebarWidth``，
    ///   真机自检 ``WindowSelfCheck/checkSplitAssembly(window:content:label:mismatches:)``
    ///   逐条核对（并确认 `canCollapse == false`、用户拖不动那条分隔线）；
    /// - 「自然高 208」是**那个自绘左栏的内边距账**（`52 + 5×28 + 4×1 + 12`），
    ///   v3 的侧栏几何由系统排版，那个数字没有对应物。
    ///
    /// 一条**仍然适用**的经验：拿 `DesignTokens.Size.…` 当期望值去比渲染结果，
    /// 等于「常量跟自己比」—— 令牌一改两边同时变，测试照样全绿
    /// （2026-09-29 变异测试实测：把 `settingsSidebarWidth` 从 200 改成 210，12 条全绿）。
    /// 现在守侧栏的那条用的是**实测的 200**。

    /// ⚠️ 这里曾有第二条「繁中下也必须放得下」——**2026-09-29 两栏之后删掉了**。
    ///
    /// 它的存在理由（「面板高度按英文 916.20 定，距 920 只剩 3.8pt，繁中多折一行就会被藏掉」）
    /// 是**单栏口径**，两栏之后那个夹逼约束不存在了（最坏余量 55.78）。
    /// 它的两件实事都已搬走，没有丢：
    /// - 「逐语言都不超」→ 并进 ``每个分类页都放得下()`` 的 `zh-Hant` 那一轮；
    /// - 「`zh-Hant` 真的解析出了另一串文案」的自证 → 也搬进了那个函数开头。
    ///
    /// 单栏时代的实测记录（繁中与简中**逐点相同**：2026-09-27 都是 841.40、
    /// 09-28 都是 900.20）只对旧口径有意义，不再复述。

    /// 面板尺寸的**依据**：中文下**每一页**都必须与设计稿逐点相同。
    ///
    /// 这一条是上面「放得下」的**前提校验**。只有「≤ 容器」时，
    /// 把内容整体缩小（字号、内边距改小）也能让断言变绿 —— 而那是排版走样，不是修好了。
    /// 所以这里钉住绝对值：**每一页中文下实现与设计稿的差必须 ≤ 2pt**。
    ///
    /// ## 逐页比，不是比总和（两栏形态的关键）
    ///
    /// 单栏版比的是「五组之和 vs 设计稿 899.94」。两栏之后**总和这个数不存在** ——
    /// 用户任何时候只看得到一页，一页偏矮、另一页偏高**互相抵消**成「总和正确」是完全可以发生的，
    /// 而每一页看起来都不对。所以逐页钉。
    ///
    /// ## 为什么这条能成立（历史量级）
    ///
    /// 同一量法在单栏版上复现过三次，中文差 0.16 / 0.24 / 0.26pt（英文差 31.65pt 是
    /// CSS 与 CoreText 的断行差异，本仓库已记为「已知不是 bug」，所以这条只钉中文）。
    /// 量法：设计稿走 ``designFrameHeights`` 那套（无头 Chrome，`.sdetail__body` 的
    /// `flex: 1 1 auto` 必须先关掉 —— 它被拉伸填满窗口，直接量到的是「被撑开的高度」）；
    /// 实现走 `sizeThatFits`。
    ///
    /// ## 「通用 · 登录项等待系统批准」那一帧**不在这条判据里，且已单独有人守**
    ///
    /// 它是**同一个页面的另一帧**（设计稿 09 页第 2 帧，英文 368.28），
    /// 而本表按**分类**索引（一页一个数）⇒ 塞不进来，也**不该**塞
    /// （那会覆盖掉 `.general` 的 324.28，即默认态）。
    ///
    /// ⚠️ 2026-09-29 之前，产品侧那一态与设计稿**故意不同形**（只换一句说明、
    /// 不画那行受阻提示行），所以两者之间**没有任何对应关系**，它当时只受
    /// ``面板高度既不截内容也不虚高()`` 的「放得下」约束。
    /// 形态对齐之后（§8.153）它**逐点相等**了，于是有了
    /// ``登录项待批准态的高度等于设计稿()`` 这条独立断言 —— 它钉的是**绝对值**，
    /// 而本条只钉默认态。
    /// ## 变异验证（2026-09-29，这条**真的抓到过东西**）
    ///
    /// 它抓到的正是它独有的一类：「关于」页的两个 `Text` **少写了行高**
    /// （设计稿的行高是从文档基准 `1.45` 继承来的，源码里看不见）
    /// ⇒ 该页比设计稿矮 **7.03pt** ⇒ 这条红。
    ///
    /// ⚠️ **`每个分类页都放得下()` 对它完全无感**（矮了当然更放得下）——
    /// 两条判据的分工据此划清：一条守「**别截**」（≤ 容器），一条守「**别走样**」（= 设计稿）。
    /// 只留前者的话，「整体缩小字号 / 收内边距」也能让所有断言变绿。
    @Test func 每个分类页的中文高度与设计稿逐点相同() {
        let head = SettingsMetrics.headerHeight
        for section in SettingsSection.allCases {
            guard let want = Self.designFrameHeights[section] else {
                Issue.record(
                    "「\(section.rawValue)」页没有设计稿基准 —— 新增分类必须同时补基准（跑 Tools/measure_settings_v3.py 重量），否则这一页的排版走样没有任何东西会报错"
                )
                continue
            }
            // 设计稿口径 + 系统控件固有偏差（见 ``systemToggleDelta``：系统 Toggle 24 vs 稿 22）。
            let expected = want + (Self.systemToggleDelta[section] ?? 0)
            let got = head + renderPane(section).height
            print("  [两栏设置] \(section.rawValue)：实现 \(got) ｜ 设计稿 \(want) + 系统偏差 \(expected - want)")

            #expect(
                abs(got - expected) <= 2,
                """
                「\(section.rawValue)」页中文下需要 \(got)pt，期望 \(expected)pt \
                （设计稿实测 \(want)pt + 系统控件偏差 \(expected - want)pt，差 \(got - expected)pt > 2）。\
                差得超过 2pt 说明**结构**变了（少/多一行、内边距或图标尺寸改动），不只是折行差异 —— \
                请同步复核设计稿与该页内容（设计稿那侧用 `Tools/measure_settings_v3.py` 重量，别手抄）。\
                若这页增删了**无说明文字的开关行**，请同步 ``systemToggleDelta``（每行 +2）。
                """
            )
        }
    }

    /// 「登录项等待系统批准」那一态（设计稿**第 2 帧**）**逐点等于设计稿**。
    ///
    /// ## 这条断言以前是空的，以及为什么现在不能空着
    ///
    /// 产品侧这一态曾经与设计稿**故意不同形** —— 设计稿画「一行独立的受阻提示行」，
    /// 产品侧是「把登录行的说明换一句话」。信息等价、高度不同 ⇒ 所以
    /// ``每个分类页的中文高度与设计稿逐点相同()`` 只量**默认态**，
    /// 这一态当时只受「放得下」约束（``面板高度既不截内容也不虚高()``）。
    /// 2026-09-29 对齐成设计稿形态（`DESIGN-SPEC.md` §8.153）之后它**应该**逐点相等了，
    /// 于是这条断言有了内容：**多 15pt（多一行）或少 15pt（少一行）都是缺陷**。
    ///
    /// ## 两条断言守的是两件事，别合并
    ///
    /// | 断言 | 守的是 |
    /// |---|---|
    /// | ``每个分类页的中文高度与设计稿逐点相同()``（默认态 324.28） | **常规排版**没走样 |
    /// | 本条（第三态英文 368.28） | **条件插入的那一行**真的插进去了、且高度对 |
    ///
    /// 只留前者的话，把 `generalCard` 里那句 `if isLaunchAtLoginPendingApproval`
    /// **整块删掉不会有任何东西报错**（默认态不经过那条分支）——
    /// 而「那一行没出现」与「这一态本来就没有那一行」在渲染图上长得一模一样，
    /// 正是本文件头反复点名的那一类。
    ///
    /// ## 装置里埋的自证（不然会出假绿）
    ///
    /// 先断言**两态渲染出来必须不同高**（差 > 20pt）：若判据没生效
    /// （比如 `launchAtLoginStateOverride` 没被读进去），两次量到的就是同一版，
    /// 而「同一版」照样能等于某个数 —— 这条就退化成了默认态那条的复读。
    @Test func 登录项待批准态的高度等于设计稿() {
        func pane(_ state: LaunchAtLoginState?, language: String = TestLanguage.design) -> CGSize {
            renderedSize(
                SettingsSectionPane(
                    section: .general,
                    autoUpdateRowsOverride: designAutoUpdateRows,
                    takeOverAvailabilityOverride: designTakeOver,
                    launchAtLoginStateOverride: state),
                width: detailWidth, language: language)
        }

        let normal = pane(nil)
        let pending = pane(.requiresApproval)
        #expect(
            pending.height > normal.height + 20,
            """
            第三态与默认态渲染出来几乎一样高（\(pending.height) vs \(normal.height)）——
            `isLaunchAtLoginPendingApproval` 那条判据没生效，下面量到的是同一版（假绿）。
            """
        )

        let head = SettingsMetrics.headerHeight
        // 设计稿口径 + 系统控件偏差：第三态帧里同样有 Dock 图标那条无说明开关行
        // （``systemToggleDelta`` 的 +2），**再加**登录项行 —— 待批准态下
        // `launchAtLoginDescription` 返回 `nil`（说明整体搬去了受阻行），
        // 行高改由系统 Toggle 24pt 决定 ⇒ 再 +2。两条合起来 = 第三态共 2 行。
        let extra = (Self.systemToggleDelta[.general] ?? 0) + Self.pendingApprovalExtraToggleDelta
        for (language, want) in Self.designPendingApprovalHeights.sorted(by: { $0.key < $1.key }) {
            let expected = want + extra
            let got = head + pane(.requiresApproval, language: language).height
            print("  [登录项第三态] \(language)：实现 \(got) ｜ 设计稿 \(want) + 系统偏差 \(extra)")

            #expect(
                abs(got - expected) <= 2,
                """
                [\(language)] 第三态需要 \(got)pt，期望 \(expected)pt \
                （设计稿实测 \(want)pt + 系统偏差 \(extra)pt，差 \(got - expected)pt > 2）。
                差得超过 2pt 说明**结构**变了（那行受阻提示行没插进去 / 插错位置 /
                按钮高度与设计稿的 `.btn--sm` 不同），不只是折行差异 ——
                请同步复核设计稿 09 页第 2 帧（用 `Tools/measure_settings_v3.py` 重量，别手抄）。
                """
            )
        }
    }

    /// 受阻行的**琥珀底真的画出来了**。
    ///
    /// ## 为什么非要有这条（本文件那条红线的又一入口）
    ///
    /// 给一行加色调 = 一个 `.background(…)` 修饰符 + 一处 `.foregroundStyle(…)`。
    /// 写错的形态很多，而**它们渲染出来都是一个「看着正常」的面板**：
    ///
    /// | 写错的形态 | 渲染结果 | 上面那些断言会红吗 |
    /// |---|---|---|
    /// | 忘了加底色 | 与普通行逐像素相同 | ❌ **全绿** |
    /// | 底色加在内边距**之前** | 只有标签那一小块有色，行首行尾是白的 | ❌ **全绿** |
    /// | 标签色忘了改 | 浅琥珀底上仍是黑字 | ❌ **全绿** |
    /// | 两处都对 | 整行琥珀底 + 琥珀标签 | ✅ |
    ///
    /// 关键在于**底色与字色都不参与布局** —— 每种写错法的高度都与正确版**一字不差**，
    /// 所以 ``登录项待批准态的高度等于设计稿()`` 之类的判据对它完全无感。
    /// 这正是本仓库反复吃亏的那一类：「样式没生效」与「本来就没写」逐字相同。
    ///
    /// ## 判据：暖色像素（`r − b > 20` 且 `r ≥ g ≥ b`）
    ///
    /// | 像素 | `r − b` | 算暖色？ |
    /// |---|---|---|
    /// | `warningSoft` 压在白上 ≈ `#FFF2E0`（**底色本体**） | 31 | ✅ |
    /// | `#B25000`（`warningText`，**标签文字**） | 178 | ✅ |
    /// | `#FFFFFF`（卡片底） | 0 | ❌ |
    /// | `#1D1D1F`（正文） | −2 | ❌ |
    /// | accent 蓝 `#007AFF` | −255 | ❌ |
    ///
    /// ⚠️ **不能只量「琥珀像素」（`r − max(g,b) > 60`）**：那条阈值是为
    /// ``Palette/warning``（`#FF9500`）与 ``Palette/warningText`` 定的（实测表见
    /// `MainWindowDiskListTests.isAmber`），而本轮的**底色** `warningSoft`
    /// 压在白上只有 **13** ⇒ 用那条阈值**只能量到标签文字、量不到底色** ——
    /// 而底色才是这一轮新加的东西。两个阈值各自对应各自要守的对象。
    ///
    /// ## 装置里的两条自证（不然会出假绿）
    ///
    /// 1. **默认态必须是 0 个**：证明判据没把卡片底/抗锯齿算进来。默认态就有暖色的话，
    ///    第三态那个数毫无意义。
    /// 2. **暖色必须铺满整行**（跨 ≥ 40pt 高）：只断言「> 0 个」的话，
    ///    「底色加在内边距之前」（只剩标签那一小条）照样能通过。
    @Test func 受阻行的琥珀底真的画出来了() {
        let size = CGSize(width: detailWidth, height: detailHeight)

        /// 暖色（底色本体 + 琥珀文字都算）。
        func isWarm(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            r * 255 - b * 255 > 20 && r >= g && g >= b
        }
        /// **琥珀**（比暖色严得多）：只有 ``Palette/warning`` 与 ``Palette/warningText``
        /// 这一档过得去，`warningSoft` 压在白上（`r − b = 31` / `r − max(g,b) = 13`）过不去。
        /// 阈值 60 与 ``MainWindowDiskListTests/isAmber`` 同源。
        func isAmber(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            r * 255 - max(g * 255, b * 255) > 60
        }

        struct Hit {
            var count = 0
            var minY = Double.infinity
            var maxY = -Double.infinity
            var height: Double { maxY - minY }
            mutating func add(_ y: Int) {
                count += 1
                minY = min(minY, Double(y) / 2)
                maxY = max(maxY, Double(y) / 2)
            }
        }

        func scan(_ state: LaunchAtLoginState?) -> (warm: Hit, amber: Hit) {
            var warm = Hit()
            var amber = Hit()
            guard
                let rep = OffscreenRender.bitmap(
                    SettingsSectionPane(
                        section: .general,
                        autoUpdateRowsOverride: designAutoUpdateRows,
                        takeOverAvailabilityOverride: designTakeOver,
                        launchAtLoginStateOverride: state),
                    size: size)
            else { return (warm, amber) }
            OffscreenRender.forEachPixel(rep, in: nil, scale: 2) { _, y, r, g, b in
                if isWarm(r, g, b) { warm.add(y) }
                if isAmber(r, g, b) { amber.add(y) }
            }
            return (warm, amber)
        }

        let normal = scan(nil)
        let pending = scan(.requiresApproval)
        print(
            "  [受阻行琥珀底] 默认态 暖色 \(normal.warm.count) / 琥珀 \(normal.amber.count) ｜ "
                + "第三态 暖色 \(pending.warm.count) 个（跨 \(pending.warm.height)pt）"
                + " / 琥珀 \(pending.amber.count) 个（跨 \(pending.amber.height)pt）"
        )

        // 自证 1：默认态一个暖色像素都不该有。
        #expect(
            normal.warm.count == 0,
            """
            默认态的「通用」页量到 \(normal.warm.count) 个暖色像素 —— 这一页本来没有任何暖色元素。
            要么判据太松（把卡片底/抗锯齿算进来了），要么受阻行在**默认态**就显示了
            （`isLaunchAtLoginPendingApproval` 判据反了、或注入口没被读）。
            这条不先绿，下面那条「第三态有暖色」就没有意义。
            """
        )

        // 主判据：整行铺满的琥珀底。
        #expect(
            pending.warm.count > 5000,
            """
            第三态只量到 \(pending.warm.count) 个暖色像素 —— 琥珀底**没画出来**，
            或者只画了标签那一小条（`.background` 加在内边距之前就会这样）。
            期望是「整行 480pt 宽 × 约 56pt 高」的量级。
            """
        )
        #expect(
            pending.warm.height >= 40,
            """
            暖色区域只跨 \(pending.warm.height)pt 高 —— 不是一整行。
            正常应接近该行的高度（标签 + 说明 ⇒ 40pt 以上）。
            只跨十几 pt 说明底色只盖住了文字那一块（加错了层）。
            """
        )

        // 第二判据：**标签字也得是琥珀**（`warningText`），不是浅底上的黑字。
        //
        // ⚠️ 单靠上面那条暖色判据抓不到它 —— 底色在，整行照样「暖」，而黑字也是「非暖」。
        // 要分辨只有用**更严的阈值**：`warningSoft` 过不去 60 这条线，只有文字过得去。
        #expect(
            normal.amber.count == 0,
            "默认态量到 \(normal.amber.count) 个琥珀像素 —— 「通用」页不该有琥珀元素（判据或布局有误）"
        )
        #expect(
            pending.amber.count > 0,
            """
            第三态一个琥珀像素都没有 —— 标签色**没生效**（`tone == .warning` 那一支没接上
            `.foregroundStyle(warningText)`），浅琥珀底上画的是黑字。
            这一条与上面那条判据守的是两件事，见本测试的注释表。
            """
        )
    }

    /// 「更新」行**各态渲染出来必须一样高**。
    ///
    /// **为什么**：这一行是设置面板里**唯一**会在运行中换画法的行 ——
    /// 其余行的形态由偏好决定，只有它随事件（检查中 / 下载中 / 已就绪 / 失败…）变形。
    /// 而面板是**固定高度**的：只要有一态比别的高，切到那一态时要么多出一条空白带、
    /// 要么把最后一行挤到折叠线外（历史上「关于」整段就是这样消失的，见文件头）。
    /// 「下载中」那一态尤其危险 —— 它多画了一条轨道 + 一个百分比。
    ///
    /// ⚠️ 这条断言**与渲染机器无关**（只比各高度互相相等，不比绝对值），所以能进 CI。
    /// 各态的出图进不了 CI（`DE_SNAPSHOTS=1` 才跑）→ **光出图不补守卫等于没补**（§8.33）。
    ///
    /// ⚠️ **名字里不写数字**（原叫「七态」）：状态数会随实现增长（2026-09-19 加了
    /// 「下载中（无百分比）」那一态，2026-09-20 又加了「正在检查」与「位置不允许更新」
    /// 两态 —— 名字里若写数字，它**已经要改两次了**），写死数字的名字**每加一态就变一次假话**，
    /// 而它又是别的文档引用这个函数时的入口。数字型的名字会漂移，就说「各态」。
    /// 同理下面打印/失败消息里也一律不写数字 —— 写数字的地方迟早与清单分叉。
    @Test func 更新行各态渲染出来必须一样高() {
        let lastCheck = Date(timeIntervalSince1970: 1_789_000_000)
        func row(_ phase: UpdatePhase, skipped: String? = nil) -> UpdateController.CheckRowState {
            UpdateController.rowState(phase: phase, skippedVersion: skipped, lastCheck: lastCheck)
        }
        let states: [(String, UpdateController.CheckRowState)] = [
            ("尚未检查", UpdateController.rowState(phase: .idle, skippedVersion: nil, lastCheck: nil)),
            ("已是最新", row(.idle)),
            // 2026-09-28 加的那一态（用户报告）：「检查**失败**」与「已是最新」原先共用同一句话。
            // ⚠️ 它必须**与「已是最新」并列**，不能顶掉它 —— 两者是**相反**的两件事
            // （`UpdateController.CheckOutcome` 有说明），合并等于那句谎原地复活。
            // 文案是「上次检查：%@ · 检查失败」+「重试」按钮，也**必须有第二行**。
            (
                "检查失败",
                UpdateController.rowState(
                    phase: .idle, skippedVersion: nil, lastCheck: lastCheck, outcome: .failed)
            ),
            ("已跳过", row(.idle, skipped: "1.1.0")),
            // 2026-09-20 加的那一态（§8.93 / §8.97）：用户点了「检查更新」、
            // Sparkle 还没答的那 3~4.5 秒。它**有第二行**（`updateCheckingHint`）——
            // 少一行就会矮（§8.82 就是这么抓到「下载中（无百分比）」那一态的：矮 14.8pt）。
            ("正在检查", row(.checking)),
            ("发现新版本", row(.found(version: "1.1.0"))),
            ("下载中", row(.downloading(version: "1.1.0", fraction: 0.42))),
            // 2026-09-19 加的那一态（§8.81 / §8.82）：自动那条路的「后台下载中」。
            // 百分比**无从得知**（`fraction: nil`）⇒ 不画进度条、不给「取消」。
            // ⚠️ 它必须**与「下载中」并列**，不能顶掉它：那是两条不同的路
            // （手动检查 vs 自动），画法也不同（有进度条 vs 没有）——
            // 统一口径时把不方便的那一态删掉，就等于那一态再也没人看过（§8.33）。
            ("下载中（无百分比）", row(.downloading(version: "1.1.0", fraction: nil))),
            // 2026-09-25 拆成两格（§8.146.2）：「已就绪」在两条路上**说的话不一样** ——
            // 自动那条路是「重启后完成安装；下次退出应用时也会自动安装」，
            // 点过「后台更新并重启」那条路是「会自动重启完成安装；有磁盘正在推出时会等它结束」。
            // ⚠️ 两格都必须在清单里：**只留一格就等于另一句话再也没人量过高度**
            // （§8.33 的老毛病 —— 统一口径时把不方便的那一态删掉）。
            ("已就绪", row(.ready(version: "1.1.0", autoRestart: false))),
            ("已就绪（会自动重启）", row(.ready(version: "1.1.0", autoRestart: true))),
            ("失败", row(.failed(version: "1.1.0"))),
            // 2026-09-22 加的那一态（账本第 43 行）：**下载成功、但之后那一步失败**
            // （解压 / 验签 / 安装）。文案是「%@ 安装失败」+ 一句说明 —— 也**必须有第二行**。
            ("安装失败", row(.installFailed(version: "1.1.0"))),
            // 2026-09-20 加的那一态（§8.94 / §8.95.7）：只读卷 / App Translocation。
            // 文案是「请把应用拷到『应用程序』文件夹」+ 一句说明 —— 也**必须有第二行**。
            ("位置不允许更新", row(.locationBlocked)),
        ]

        var heights: [(String, CGFloat)] = []
        for (name, state) in states {
            // 「更新」页 = 两个自动更新开关行 + 这一行状态机（见 ``SettingsSectionPane/updatesCard``）。
            // 两个开关行注入设计稿假设的那一态，好让「各态差异」只来自状态机本身。
            let h = renderedSize(
                SettingsSectionPane(
                    section: .updates,
                    updateStateOverride: state,
                    autoUpdateRowsOverride: designAutoUpdateRows),
                width: detailWidth
            ).height
            heights.append((name, h))
        }
        let printed = heights.map { "\($0.0) \($0.1)" }.joined(separator: " ｜ ")
        print("  [更新行各态] \(printed)")

        // 判据是「**各态互相相等**」，不是「等于某个数」—— 后者会把「整体挪了 1pt」
        // 报成每一态都失败，而真正要防的是**某一态与别的不一样**。
        let first = heights[0].1
        for (name, h) in heights.dropFirst() {
            #expect(
                abs(h - first) <= 0.5,
                """
                「\(name)」渲染出来 \(h)pt，而「\(heights[0].0)」是 \(first)pt —— 各态必须一样高。
                设置面板是固定高度：某一态更高就会挤掉最后一行（或留出空白带）。
                全部各态：\(printed)
                """
            )
        }
    }

    /// 「更新」组那两个开关**各形态渲染出来必须一样高**。
    ///
    /// 与上面那条同一个理由：面板是固定高度。而这两行的说明都是**整句替换**的
    /// （检查行 `autoCheckUpdateHint` ↔ `autoUpdateUnavailableHint`；
    /// 下载行 `autoDownloadUpdateHint` ↔ `autoDownloadNeedsCheckHint` ↔ 上面那句）——
    /// 换长了就可能多折一行，把最后一行挤出折叠线。
    ///
    /// ⚠️ **名单里必须有「检查关 · 下载行说『需先打开…』」那一态**：它是唯一一态
    /// **换了文案又同时让控件变灰**的，而「文案与可点性不同源」正是这一版要防的错
    /// （见 ``更新两行不可用态不得比可用态更高()`` 与 `UpdateSettingsTests` 里那条自洽断言）。
    /// 出图清单（`SnapshotRenderTests`）与这里**各有一份**，别只补一处。
    @Test func 更新两行各态渲染出来必须一样高() {
        let states: [(String, AutoUpdateRowsState)] = [
            ("默认（具能力 · 检查开 · 下载关）", designAutoUpdateRows),
            ("检查关", AutoUpdateRowsState(canAutoUpdate: true, checksIsOn: false, downloadsIsOn: false)),
            ("两个都开", AutoUpdateRowsState(canAutoUpdate: true, checksIsOn: true, downloadsIsOn: true)),
            ("不具备能力", AutoUpdateRowsState(canAutoUpdate: false, checksIsOn: false, downloadsIsOn: false)),
        ]

        var heights: [(String, CGFloat)] = []
        for (name, state) in states {
            // 只量「更新」页 —— 这一组两个开关都在那一页上（``SettingsSectionPane/updatesCard``）。
            // 两栏之前这里量的是**五组相加**，于是别组的差异会混进来；逐页量之后
            // 「各态等高」这条判据第一次真的只盯这两行。
            let h = renderedSize(
                SettingsSectionPane(
                    section: .updates,
                    autoUpdateRowsOverride: state,
                    takeOverAvailabilityOverride: designTakeOver),
                width: detailWidth
            ).height
            heights.append((name, h))
        }
        let printed = heights.map { "\($0.0) \($0.1)" }.joined(separator: " ｜ ")
        print("  [更新两行各态] \(printed)")

        let first = heights[0].1
        for (name, h) in heights.dropFirst() {
            #expect(
                abs(h - first) <= 0.5,
                """
                「\(name)」渲染出来 \(h)pt，而「\(heights[0].0)」是 \(first)pt —— 各态必须一样高。
                说明文案是整句替换的，长了就会多折一行、把最后一行挤出折叠线。
                全部各态：\(printed)
                """
            )
        }
    }

    /// 「更新」组那两个开关的**禁用态不得比可用态更高**（2026-09-28，与 ``接管未授权态不得比可用态更高()`` 同源）。
    ///
    /// ## 判据为什么是「≤」而不是「等高」
    ///
    /// 面板高度契约（``每个分类页都放得下()`` / ``最高的那一页决定面板高度()``）
    /// 拿 ``designAutoUpdateRows`` 那一版（**可用态**，也是真机默认态）对齐。
    /// 只要禁用态**不比它高**，那两条契约就天然覆盖了禁用态；
    /// 反过来（禁用态更高）就意味着面板要重新定高 —— 那是另一件事。
    ///
    /// ⚠️ **这条为什么不能省（它真的抓到过东西）**：禁用态的文案与可用态**不是同一句**
    /// （`autoUpdateUnavailableHint` / `autoDownloadNeedsCheckHint`），
    /// 而「不可用时把话说清楚」与「不许因为说多了就把面板撑高」是**两个方向相反的诉求**。
    /// 只压前者就会多折一行 —— 2026-09-28 把 `autoUpdateUnavailableHint` 从
    /// 79 字符压到 49 字符（英文）就是因为它在两行上**各出现一次**，
    /// 一旦折成两行，英文比中文多两行 ⇒ 面板高度**无解**（不是偏紧）。
    ///
    /// ⚠️ **将来把禁用文案写长**，首选同样是压短文案，**别把断言放宽成 `+ 40`**：
    /// 那样放过的正是「多折了一行」。
    @Test func 更新两行不可用态不得比可用态更高() {
        // 自证：三句话**必须互不相同** —— 否则下面量到的是同一版，断言恒成立
        // （同 ``接管未授权态不得比可用态更高()`` 开头那条）。
        let lines = [
            L10n.tr(.autoCheckUpdateHint), L10n.tr(.autoDownloadUpdateHint),
            L10n.tr(.autoDownloadNeedsCheckHint), L10n.tr(.autoUpdateUnavailableHint),
        ]
        #expect(
            Set(lines).count == lines.count,
            "更新两行的四句说明里有重复：\(lines) —— 重复意味着某一态其实没有换文案，量到的可能是同一版（假绿）"
        )

        for language in [TestLanguage.design, "en", "zh-Hant"] {
            let usable = renderedSize(
                SettingsSectionPane(
                    section: .updates, autoUpdateRowsOverride: designAutoUpdateRows),
                width: detailWidth, language: language)
            let blocked = renderedSize(
                SettingsSectionPane(
                    section: .updates,
                    autoUpdateRowsOverride: AutoUpdateRowsState(
                        canAutoUpdate: false, checksIsOn: false, downloadsIsOn: false)),
                width: detailWidth, language: language)
            let checksOff = renderedSize(
                SettingsSectionPane(
                    section: .updates,
                    autoUpdateRowsOverride: AutoUpdateRowsState(
                        canAutoUpdate: true, checksIsOn: false, downloadsIsOn: false)),
                width: detailWidth, language: language)
            print(
                "  [更新两行] \(language)：可用 \(usable.height) ｜ 不具备能力 \(blocked.height) ｜ 检查关 \(checksOff.height)"
            )
            #expect(
                blocked.height <= usable.height + 0.5,
                "[\(language)] 「不具备能力」那一态 \(blocked.height)pt 比可用态 \(usable.height)pt 更高 —— 禁用态的说明文案多折了一行，面板要重新定高（首选是压短文案）"
            )
            #expect(
                checksOff.height <= usable.height + 0.5,
                "[\(language)] 「检查关 · 下载行说『需先打开…』」那一态 \(checksOff.height)pt 比可用态 \(usable.height)pt 更高 —— 禁用态的说明文案多折了一行，面板要重新定高（首选是压短文案）"
            )
        }
    }

    /// 「接管访达的推出」那一行**两态**的高度关系（2026-09-28）。
    ///
    /// ## 判据为什么是「未授权态 ≤ 可用态」而不是「等高」
    ///
    /// 两态换的是说明文字（`takeOverFinderEjectFootnote` ↔ `takeOverFinderEjectNeedsFDA`），
    /// 而**可用态才是设计稿画的版本**（设计稿里这一行是开关），
    /// 本文件的绝对值断言也都是拿它对齐的。
    /// 只要未授权态**不比它高**，面板高度契约就天然对它成立；
    /// 反过来（未授权态更高）就意味着面板要重新定高，那是另一件事。
    ///
    /// ⚠️ **将来把未授权态的文案写长**（比如补一句「系统设置在哪」），这条会红 ——
    /// 那时首选是压短文案（与英文 footnote 从 158 压到 116 字符那次同一手法），
    /// **别把断言放宽成 `+ 40`**：那样放过的正是「多折了一行」。
    @Test func 接管未授权态不得比可用态更高() {
        // 自证：两态用的**必须不是同一句话** —— 否则下面两次量的是同一版，断言恒成立
        // （同 ``每个分类页都放得下()`` 开头那条自证）。
        #expect(
            L10n.tr(.takeOverFinderEjectFootnote) != L10n.tr(.takeOverFinderEjectNeedsFDA),
            "未授权态的说明与可用态逐字相同 —— 那一行没有真的换文案，量到的是同一版（假绿）"
        )

        for language in [TestLanguage.design, "en", "zh-Hant"] {
            // 这一行在「通用」页（``SettingsSectionPane/generalCard`` 最后一行）。
            let usable = renderedSize(
                SettingsSectionPane(section: .general, takeOverAvailabilityOverride: .usable),
                width: detailWidth, language: language)
            let blocked = renderedSize(
                SettingsSectionPane(
                    section: .general, takeOverAvailabilityOverride: .needsFullDiskAccess),
                width: detailWidth, language: language)
            print("  [接管行两态] \(language)：可用 \(usable.height) ｜ 未授权 \(blocked.height)")

            #expect(
                blocked.height <= usable.height + 0.5,
                """
                未授权态比可用态高 \(blocked.height - usable.height)pt（\(language)）——
                面板高度是按可用态定的，高出来的部分只能从滚动区外要（下面的行会被藏掉）。
                两态：可用 \(usable.height) ｜ 未授权 \(blocked.height)。
                首选改法是压短 takeOverFinderEjectNeedsFDA，不是加高面板。
                """
            )
        }
    }

    @Test func 分段控件不许吃掉标签列的宽度() {
        _ = NSApplication.shared
        let control = SettingsSegmentedControl(
            options: VisualStyle.allCases.map { ($0.rawValue, $0.shortName, $0.displayName) },
            selection: .constant(VisualStyle.default.rawValue),
            accent: .default
        )
        // 量**固有宽度**：提案给无穷大，控件才会报出自己真正想要的宽度。
        // （若按右栏宽 520 去提案，`.fixedSize()` 会被裁到 520，量不出溢出。）
        let hosting = NSHostingController(rootView: control)
        let ideal = hosting.sizeThatFits(
            in: CGSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))

        // 行内可用宽 ≈ **右栏可用内容宽**（480）− 卡片与行的左右内边距；留一半以上给标签列。
        //
        // ⚠️ 分母**必须**是 ``contentWidth``（480）而**不是**窗口宽（720）：两栏之后
        // 720 里有两百多是不参与排版的（左栏 + 两侧内边距），用窗口宽算预算
        // 会把门槛从 216 放到 324 —— 恰好放过「控件把标签列挤没」那类回归。
        let budget = contentWidth * 0.45
        #expect(
            ideal.width <= budget,
            """
            分段控件固有宽 \(Int(ideal.width))pt，超过预算 \(Int(budget))pt（右栏可用内容宽的 45%）。\
            它末尾带 `.fixedSize()`，**不可压缩**——同行的标签列是 `maxWidth: .infinity` 的弹性列，\
            会独吞这个差额并被压成竖排单字（2026-09-15 实测：长标签让该行理想宽 745pt vs 可用 440pt，\
            内容真实高度 910pt vs 可用 498pt）。可见标签必须用 `VisualStyle.shortName`（「透明」/「色调」）。
            """
        )
    }

    /// 分隔线只画在**卡片内的行与行之间**。
    ///
    /// ## 两栏之后改成**逐页数**
    ///
    /// 单栏版数的是五张卡的**总数**（期望 6 = 外观 1 + 通用 3 + 更新 2），
    /// 而总数这条判据有个隐含漏洞：**一页多画一条、另一页少画一条，总数照样是 6**。
    /// 两栏之后每页本来就是独立渲染的，顺手把这个漏洞堵上。
    ///
    /// ⚠️ **这些数会随「每张卡几行」变**：加一行就要 +1。
    /// 卡片自身的圆角描边不算行间分隔线（检测器已按「上下都变暗」排除）。
    ///
    /// ## ⚠️ 这条判据的边界（2026-09-29 变异测试实测，别再写成「抓首行」）
    ///
    /// 检测器要求**上下各 4px 都是不透明卡片**（`coverage > 0.85`）才认一条线 ——
    /// 所以它只能看见**夹在两行之间**的线。变异实测：
    ///
    /// | 变异 | 结果 |
    /// |---|---|
    /// | 通用页**第二行**的 `divider: false`（3 → 2） | ✅ 红（`count == want`） |
    /// | 通用页**第一行**的 `divider: true`（首行上方加线） | ❌ **绿** —— 抓不到 |
    ///
    /// 首行那条抓不到**不是样本问题，是判据看不见**：线画在首行上方 = 卡片最顶那一像素，
    /// 而它的上一行 4px 落在**卡片外**（`.clear` 背景）⇒ 邻居条件直接把它排除。
    ///
    /// ⇒ 所以本条的语义要**说准**：它守的是「**行与行之间**的缝数目对不对」
    /// （少画一条 → 卡片糊成一块；多画一条 → 某两行之间多一道），
    /// **不是**「首行上方有没有线」。而且首行上方那条在视觉上本就与卡片自己的
    /// `strokeBorder` 重合（同 0.5pt、同一位置，只是一个 `border` 一个 `hairline`），
    /// 多画一条**看不出区别** —— 这不是漏测，是**那里本来就有一条**。
    /// 想守「首行不许加线」得靠**审阅**（`line(divider:)` 的注释里写着这条规矩），
    /// 别指望这条像素判据。
    @Test func 分隔线只画在卡片内的行与行之间() {
        // 行数 → 分隔线数（n 行有 n−1 条缝）：
        //   通用 4 行（语言 / Dock 图标 / 登录项 / 提醒占用）→ 3
        //   外观 2 行（视觉效果 / 强调色）→ 1
        //   更新 3 行（自动检查 / 自动下载 / 检查更新状态机）→ 2
        //   诊断 1 行（错误日志）→ 0   ※ 只有一行，一条线都不该有
        //   关于 0 行（整页是居中图标 + 名字 + 版本行，没有卡片）→ 0
        // 历史：通用 2026-09-27 从 3 行变 4 行（加「接管访达的推出」）⇒ 2 → 3；
        //       更新 2026-09-28 从 2 行变 3 行（「自动更新」拆成两行）⇒ 1 → 2。
        //       两栏 2026-09-29：诊断 → 0、关于 → 0（单栏版把它俩算进那 6 条里）。
        let expected: [(SettingsSection, Int)] = [
            (.general, 3), (.appearance, 1), (.updates, 2), (.diagnostics, 0), (.about, 0),
        ]
        for (section, want) in expected {
            let count = horizontalDividerCount(
                SettingsSectionPane(
                    section: section,
                    autoUpdateRowsOverride: designAutoUpdateRows,
                    takeOverAvailabilityOverride: designTakeOver),
                width: detailWidth)
            #expect(
                count == want,
                "「\(section.rawValue)」页测到 \(count) 条卡片内行间分隔线，期望 \(want) 条。数目不符说明该页某张卡的首行上方也画了线（或末行下方有一条），或某条行间线没画出来"
            )
        }

        // 第三态（``登录项待批准态的高度等于设计稿()`` 那一帧）在「通用」页**多一行**
        // ⇒ 缝也多一条（4 → 5 行 ⇒ 3 → 4 条）。它必须单独量：上面那张表是**默认态**的，
        // 里面没有它。而「受阻行与上面那行糊成一整块」（忘了画分隔线）在渲染图上
        // 与「本来就该这样」长得一模一样 —— 正是本条要守的那类错误。
        //
        // ⚠️ **这条与那两条高度断言的覆盖面互补**：高度看得见「多了一行」，
        // 但看不见「那两行之间的缝」；而缝的有无一点都不影响高度。
        let pendingCount = horizontalDividerCount(
            SettingsSectionPane(
                section: .general,
                autoUpdateRowsOverride: designAutoUpdateRows,
                takeOverAvailabilityOverride: designTakeOver,
                launchAtLoginStateOverride: .requiresApproval),
            width: detailWidth)
        #expect(
            pendingCount == 4,
            """
            第三态的「通用」页测到 \(pendingCount) 条行间分隔线，期望 4 条（5 行 ⇒ 4 条缝）。
            受阻行是从普通行加出来的，`line(divider:)` 默认就是 `true` ——
            数目不对说明那一行没按同一套规则参与分隔线，或者 `divider` 被显式关掉了。
            """
        )
    }

    // MARK: 头部与设计稿内边距

    /// 头部标题的**渲染起点**必须等于设计稿的内边距（`.sdetail__head { padding: 0 16px 0 20px }`）。
    ///
    /// **必须量渲染结果**：拿 `SettingsMetrics` 里的常量跟自己比是**没牙的**。
    /// 本项目踩过 —— 这条测试原先判的是「红绿灯有没有压住标题」，用的常量
    /// `headerTitleMinX` 本身就是从让位宽度算出来的，于是**删掉视图里那句让位它照样是绿的**。
    /// 后来改成量墨迹；2026-09-16 让位连同红绿灯一起删掉（`DESIGN-SPEC.md` §8.17），
    /// 期望值也跟着变成**前导内边距本身**。
    ///
    /// ## ⚠️ 两栏把它从 16 改回了 20（不是「把历史改回去」）
    ///
    /// 单栏时代这里**也曾经是 20**，但理由完全不同 —— 那时面板画着系统红绿灯，
    /// 前导要加到 20 才能让两个窗口的标题都落在 x = 80；2026-09-16 去掉红绿灯后回到 16。
    /// 现在的 20 是**两栏设计稿自己写的值**（左栏 200 之后头部从 20 起排），与红绿灯无关。
    /// 那个让位块早已删除 ⇒ 下面失败消息里「≈80」那一档现在只剩「真把让位块加回来了」一种解释。
    ///
    /// 实测（离屏，scale 2）：前导 16 → 首列墨迹 **16.0pt**（2026-09-16 实测，最右 412.5）；
    /// 前导 20（两栏）→ **20.0pt**。
    /// 上界 +6 是给字形侧边距留的：中文「设」几乎贴边，英文 "Settings" 的 `S` 会再右偏一点。
    /// 下界 −1 是抗锯齿。
    /// **为什么非要量像素**：SwiftUI 的 `Text` 在 AppKit 视图树里**没有任何对应视图** ——
    /// 实测 `NSHostingView` 的 `subviews` 是空的、整棵树里找不到 `NSTextField`，
    /// 无障碍子树也是懒建的（`accessibilityChildren` 返回 nil）。
    /// 所以「标题从第几列开始」问不到 AppKit，只能看**渲染结果**。
    ///
    /// **判据是「相对白底变暗」而不是看 alpha**：``OffscreenRender/bitmap(_:size:appearance:background:)``
    /// 默认垫一层白底，于是每个像素都是不透明的，读到的就是真实渲染色。
    /// （`bitmapImageRepForCachingDisplay` 的缓冲区**不保证清零**，所以那边显式
    /// `NSBitmapImageRep(bitmapDataPlanes: nil, …)` 让系统分配一块干净的；
    /// 本文件原先也自己抄了这么一段出图 + 逐像素 `colorAt`，2026-09-23 收敛进
    /// ``OffscreenRender``，见 `DESIGN-SPEC.md` §8.131。）
    ///
    /// ⚠️ **宽度必须按右栏（``detailWidth``）出图**：头部只占右栏 ——
    /// 拿整窗出图，两个数都对不上产品里看到的画面。
    ///
    /// **扫描带取 y ∈ [8, 44]**（52pt 头部的中段）：**必须避开底部那条 `Hairline`** ——
    /// 它横跨整宽，会把 x=0 也算成墨迹。
    ///
    /// ## v3：渲染对象从 `SettingsHeaderBar` 换成 ``MainDetailHead``
    ///
    /// 前者是**独立设置窗口**的头部（标题 + 右侧「完成」按钮）；
    /// 后者是**主窗口详情区**的头部（标题 + 可选副标题，右侧什么都没有）——
    /// 「完成」这个概念在 v3 已不存在（设置是常驻面板，没有「做完」这个动作，
    /// 见 `Design/ui/v3/HANDOFF.md` §3.4）。
    ///
    /// ⇒ 下面那条「自证」随之**反过来**：原来要求右半侧有墨迹（那是「完成」），
    /// 现在要求右半侧**没有**墨迹 —— 顺带守住「别把『完成』按钮加回来」。
    @Test func 头部标题渲染起点等于设计稿内边距() {
        guard
            let rep = OffscreenRender.bitmap(
                MainDetailHead(title: L10n.tr(.settingsGroupGeneral), subtitle: nil),
                size: CGSize(width: detailWidth, height: SettingsMetrics.headerHeight)),
            let range = OffscreenRender.inkColumnRange(rep, rows: 8...44, maxX: detailWidth)
        else {
            Issue.record("头部离屏渲染后没扫到任何墨迹 —— 渲染本身没成功，这条断言不能算通过")
            return
        }

        // 自证：详情区头部**右侧不该有墨迹**（v3 的头部只有标题）。
        // 扫到了说明「完成」按钮又回来了 —— 那正是 v3 点名要删掉的东西。
        #expect(
            range.last < detailWidth / 2,
            """
            最右侧墨迹到了 \(range.last)pt（右栏宽 \(detailWidth)）—— 头部右侧本该是空的。\
            多半是把「完成」按钮加回来了：v3 里设置是主窗口的常驻面板，没有「完成」这个概念。
            """
        )

        let expected = SettingsMetrics.headerPaddingLeading
        // 把量到的数打出来 —— 像素量测最容易的失败方式是「量错了东西」，
        // 有这两个数才能当场分辨「对齐坏了」和「扫描带落在空白上」。
        print("  [详情区头部] 首列墨迹 \(range.first)pt、最右 \(range.last)pt（期望首列 ≈ \(expected)）")
        #expect(
            range.first >= expected - 1 && range.first <= expected + 6,
            """
            标题首列墨迹在 \(range.first)pt，设计稿内边距 \(expected)pt。\
            偏小（≈16.0）说明前导内边距退回成 16 了；\
            再小（≈12.0）说明内边距被改小；偏大（≈80.0）说明红绿灯让位块又回来了 —— \
            详情区头部里没有 traffic。
            """
        )
    }

    /// 「后台下载中」那一行的进度条**固定 16pt 高**，与说明行同高。
    ///
    /// 设计稿 `08-update.html` B3 的 spec-note 点名要求「进度条外层固定 16pt，
    /// 与 `.sline__desc` 同一行高，**下载中这一行不会被撑高**」。
    ///
    /// **为什么必须钉**：不钉的话，把外层高度去掉（只留 5pt 轨道 + 文字行盒）
    /// 会让整块设置面板在下载过程中**跳一下** —— 而这件事只在真机下载时看得到，
    /// 离屏出图与其它单测都不会红。
    @Test func 行内进度条固定16pt高() {
        let size = renderedSize(SettingsProgressLine(fraction: 0.42), width: 200)
        #expect(
            size.height == DesignTokens.Size.settingsProgressLineHeight,
            "行内进度条渲染出来 \(size.height)pt，不是固定的 \(DesignTokens.Size.settingsProgressLineHeight)pt")
        #expect(
            DesignTokens.Size.settingsProgressLineHeight == 16,
            "设计稿写的是 16 —— 改这个数要同时改设计稿 B3 的 spec-note")
    }
}
