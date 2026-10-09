# SafeOut 界面设计规范 v3 — 代际归属与实现交接

> 应用中文名：磁盘推出助手 · 最低 macOS 14 · 分发 = 官网直发（不开沙盒）
> 设计稿：`Design/ui/v3/screens/`（`_` 前缀 = 未采纳草稿）
> 参照实机：本机 macOS 26（Tahoe），2026-09-30 实测
>
> 本文件回答一个问题：**设计稿是 Sequoia 一代的视觉语言，而运行环境可能是 macOS 26——
> 开发按哪套来实现？**

---

## 0. 先给结论

**会出问题，但根因不是「少画了一套 26 风格的稿」。**

真正会让实现翻车的是三类具体错配（第 3 节逐条给红线）：

| # | 错配 | 后果 |
|---|---|---|
| 1 | 照抄设计稿里的**自绘材质色**（`--bg-glass` 等） | 给系统玻璃**盖一层白**，Liquid Glass 被破坏 |
| 2 | 照抄设计稿里**写死的控件度量**（选中态颜色、圆角 px） | 26 上窗口圆角变了、控件不跟 ⇒ 视觉不齐 |
| 2b | ❗**去找「同心圆角 API」来让控件自动跟系统** | 该 API 是 **macOS 26.0+ / 27.0+**，我们最低 14 ⇒ 要么写不了、要么违反 R5。**正解见 §12.3** |
| 3 | 想在 HTML 里**画 26 的玻璃** | 画不出（vibrancy / 动态高光 / 滚动边缘），画出来是假的，诱导实现侧自绘 |

**而「26 官方风格 / 26 以下我们风格」这个目标本身是对的——它已经实现了，只是不由设计稿切换，由系统切换。**
所以本规范的形态不是两张图，而是**一张「谁渲染」的归属表**（第 2 节）+ **两条清单**（第 3、4 节）。

> ❗ **另有一类更隐蔽的错配，单列于 [第 10 节](#10-l1-细化自绘控件-vs-系统控件--逐组件处置)**：
> 材质层走了 `NSVisualEffectView`（系统自动切两代），但**控件层是不是自绘的**要逐个确认 ——
> 自绘的控件**不会**跟着系统换代走，设计稿画成什么样就实现成什么样。
> 涉及「左侧菜单栏样式」「按钮样式」时，**先读第 10 节再动手**。
>
> ✅ **悬置已由用户拍板（2026-09-30，先后三轮）**：
> **① 侧栏 → 交还系统**（`List(selection:)` + `.listStyle(.sidebar)`）；
> **② 按钮 → 交还系统**（❗**第 10 轮改判**，推翻第 9 轮的「保留自绘」）——
> `.borderedProminent` + `.tint(品牌色)` / `.bordered` / `.borderless`，
> 形状与尺寸全交系统，**颜色是唯一由我们给的东西**；
> **③ 头部 → 真系统工具栏**，但**标题归右侧内容区顶部**（第 11 轮修正：工具栏里
> 只剩刷新一个 item ⇒ 项序退化为 `[.flexibleSpace, .refresh]`）；
> **④ 侧栏宽度 → 按内容适应后锁定**（`NSSplitViewItem.min/max` 同值）；
> **⑤ 左栏形态 → 画成 macOS 26 的悬浮玻璃面板**（第 11 轮；实现侧**零成本**，
> `NSSplitViewItem(sidebarWithViewController:)` 在 26 上自动就是这样）；
> **⑥ 折叠钮 → 删除**（第 11 轮，`toggleSidebar` / `sidebarTrackingSeparator` /
> `canCollapse` 一并退役；原「折叠态」帧删除）。
> **⑦ 资源分叉 → 老版本冻结、新版复制后改**（第 12 轮；`Design/ui/v2/` 不再改动）；
> **⑧ 圆角 → 分四类元素处置、只有自绘元素要写代码**（第 12 轮，查过官方文档 + 本机实测）；
> **⑨ 侧栏圆角 → 与窗口同性质：系统所有、我们零代码**（第 12 轮补测：官方四条原文 + 五档实测。
> ❗**且侧栏里不要放 `NSVisualEffectView`** —— 官方明令移除，见 §12.2.1.1 ②）。
> **⑩ 交接单按工作流重写 + 两条既有代码的新发现**（第 13 轮）：
> ① `HANDOFF.md` 从「按轮次叠加的陷阱清单」改为**按工作流组织的工单**
>    （窗口装配 / 侧栏 / 头部 / 设置内容 / 按钮 / 圆角 / 尺寸），**不含演进史**（演进史留在本文件 §7）；
> ② **部署目标订正：是 `macOS 14` 不是 13**（`Package.swift:8 platforms: [.macOS(.v14)]` 是唯一真相，
>    commit `d5bb64e` 起生效；本文件与 `ds.css` 共 60 处已同步）；
> ③ ❗**既有代码里有两处在给 `contentView.layer` 写死 12pt 圆角**
>    （主窗口 `ContentView.swift:227`、设置窗口 `SafeOutApp.swift:2368`）——
>    与 §12.3 第 1 类直接冲突，**必须重新判定**，见 **§12.3.1**。
> 逐组件处置见 §10.4，浮岛与工具栏实测数据见
> [第 11 节](#11-工具栏与浮岛实测2026-09-30--macos-26)，
> ❗**资产纪律与圆角口径见 [第 12 节](#12-资产版本纪律--跨版本圆角口径第-12-轮2026-09-30)**，
> 实现交接见同目录 `HANDOFF.md`（**按工作流组织，先读它**）。

---

## 1. 核心原则：按「谁渲染」分层，不按「哪个系统版本」分稿

三条理由，任一条成立就足以否掉「两套稿」：

**① 材质层系统已经免费给了两套，出稿是重复劳动且有害。**
官方原文（Adopting Liquid Glass · Visual refresh）：
> "**Leverage system frameworks to adopt Liquid Glass automatically.** In system frameworks,
> standard components like bars, sheets, popovers, and controls automatically adopt this material."

同一份代码：macOS 26 上系统渲染 Liquid Glass，14–15 上系统渲染传统 vibrancy。
设计稿再画一套「26 玻璃」= 把系统已经做对的事，用一张静态图**错误地**描述一遍。

**② 出「14–15 精确稿」等于给未来埋错。**
我们最低支持 macOS 14。若为老系统出精确像素稿，那套稿在新系统上就是**错的**，
而且会诱导实现侧写 `if #available(macOS 26)` 分支——官方明确反对：

> "If you use standard controls from system frameworks and **don't hard-code their layout metrics**,
> your app adopts changes to shapes and sizes automatically when you rebuild your app with the
> latest version of Xcode."

**③ Liquid Glass 是「功能层」材质，本来就不该出现在内容层自绘里。**
官方原文（HIG Materials · Liquid Glass）：
> "**Don't use Liquid Glass in the content layer.** … Instead, use standard materials for elements
> in the content layer, such as app backgrounds."
> "**Use Liquid Glass effects sparingly.** Standard components from system frameworks pick up the
> appearance and behavior of this material automatically. If you apply Liquid Glass effects to a
> custom control, do so sparingly."

⇒ 设计稿若在内容层画玻璃，方向本身就错了。

---

## 2. 分层归属表（本规范的核心）

每条视觉规则先问「谁渲染」，再决定设计稿给什么、实现侧怎么接。

| 层 | 内容 | 谁决定 | 设计稿的职责 | 实现侧约束 |
|---|---|---|---|---|
| **L0 材质 / 结构层** | 窗口底、**侧栏浮岛（内缩 + 圆角 + 底材质）**、popover 底、工具栏、滚动边缘 | **系统** | **几何可画**（内缩 8pt / 面板圆角 17.5pt 这类结构关系，见 §11.4 / §12.2.2）；**颜色、「窗口圆角数值」与「侧栏圆角数值」都不可给**，只写「归系统」+ 参照真机截图 | 窗口底 / popover 底走 `NSVisualEffectView`；**侧栏浮岛走 `NSSplitViewItem(sidebarWithViewController:)`，其内部<u>不要</u>再放 `NSVisualEffectView`**（官方明令移除，§12.2.1.1 ②）；**一律禁止自绘背景色** |
| **L1 系统控件层** | 工具栏、侧栏选择态、**按钮（5 变体）**、开关、圆角、焦点环 | **系统** | 给**语义**（「列表选中」「主按钮」）+ **颜色**；度量一律不给 | 走系统控件（`NSToolbar` / `List(selection:)` / `.borderedProminent` / `Toggle`）；**禁止硬编码度量**。⚠️ **圆角不另找 API**：系统控件圆角归系统；自绘元素走 §12.3 公式 |
| ~~**L1′ 产品自绘控件层**~~ | **（2026-09-30 第 10 轮并入 L1，本层已无成员）** | — | — | 层定义保留，因为它记录的是**判据**：只有「在别的 App 里见不到同样形状与反馈」的控件才允许自绘。目前**没有**这样的控件 |
| **L2 自绘内容层** | 版面尺寸、间距、字号、**语义色（琥珀/红/绿）**、**品牌强调色**、磁盘行结构、容量条、应用自有图标 | **我们** | 给**精确值**（这部分才是设计稿的像素价值所在） | 照实现；**这些值与代际无关——26 与 14 同一个数** |

> ⚠️ **上一轮本站把「按钮」单独列为 L1′（产品自绘控件），本轮已被用户第 4 条推翻**：
> 「除了颜色这些，其他的最好都是使用适配的 macOS 系统对应的组件风格来定义」
> ⇒ 按钮归 L1，**颜色（品牌强调色 / 语义色）仍归 L2**（这正是那句「除了颜色」）。

**关键推论：设计稿的像素规格，价值集中在 L2；L0/L1 越界写值就是坑。**
v2 稿里 `--bg-glass: rgba(255,255,255,.72)`、`--accent` 实底选中态，都属于**越界写值**——
它们在 HTML 里是「模拟」，但实现侧看是「规格」。

---

## 3. 实现侧红线（禁止清单）

以下**七条**由本规范确立。违反不会立刻报错，只会让 26 上的界面**看起来旧**或**与系统割裂**。

| # | 禁止 | 依据 | 正确做法 |
|---|---|---|---|
| R1 | 用设计稿的 `--bg-glass` / `--bg-glass-thick` 自绘窗口或面板底色 | "Any custom backgrounds and appearances you use in these elements might **overlay or interfere with** Liquid Glass" | **窗口底 / popover 底**：用 `NSVisualEffectView`（现有 `Sources/Views/GlassViews.swift` 已合规）<br>**侧栏内部**：⛔ **连 `NSVisualEffectView` 也不要用** —— 官方原话「应把这类视图从层次里移除」（§12.2.1.1 ②），那格什么都不放 |
| R2 | 给侧栏选中态写死 `--accent` 实底 | 26 实测系统侧栏选中是**中性灰胶囊**（见第 5 节） | 走列表/侧栏的**系统选择样式**；由系统决定颜色 |
| R3 | 给系统控件的尺寸、圆角、内边距写死 px | "don't hard-code their layout metrics" | 用系统默认；**自绘元素**的圆角按 §12.3 公式算（⚠️ 不要去找 `ConcentricRectangle`，见 §12.1） |
| R4 | 自绘仿 Liquid Glass（渐变、模糊层、高光边） | "Use Liquid Glass effects sparingly"；「Don't use Liquid Glass in the content layer」 | 用系统材质；需要玻璃按钮时用 `glass` / `glassProminent` 样式 |
| R5 | 按系统版本写视觉分支（`if #available(...26)` 改配色/圆角） | 同上 | 用系统组件 ⇒ 版本差异由系统消费，代码零分支 |
| **R6** | **试图「读」窗口圆角再据此算布局**（以为存在某个可读的属性） | 实测：`NSThemeFrame.layer.cornerRadius = 0.0`、`mask = nil`、`maskedCorners` 全开 ⇒ 圆角由**窗口服务器**裁切（§12.2.3） | 不要读、不要反推；按 §12.3 分四类元素处置 |
| **R7** | **在侧栏内部放 `NSVisualEffectView`（含 `material: .sidebar`）去「模拟」侧栏底** | 官方原话：「**如果你使用 `NSVisualEffectView` 来显示边栏内的旧版材质，将会导致玻璃材质无法透过。你应该从视图层次中移除这些视觉效果视图。**」（§12.2.1.1 ②） | 侧栏那格**什么都不放**：玻璃由 `NSSplitViewItem(sidebarWithViewController:)` 自带。⚠️ 窗口底 / popover 底仍照常走 `NSVisualEffectView`（`GlassViews.swift` 合规，勿改） |

---

## 4. 必须走系统 API 的清单（L0 / L1）

| 界面元素 | 系统 API | 备注 |
|---|---|---|
| 窗口底 / 面板底材质 | `NSVisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)` | 已落地于 `GlassViews.swift`；26 上自动成为 Liquid Glass。⚠️ 只用于**窗口底 / popover 底**，**侧栏内部不要用**（§12.2.1.1 ②） |
| **侧栏浮岛（26 的内缩 + 圆角 + 玻璃）** | `NSSplitViewItem(sidebarWithViewController:)` | 26 上系统**自动**给内缩 8pt + 圆角 17.5pt + 玻璃，14–15 上自动是老形态；**实现侧零代码、零材质**（§11.4 / §12.2.2 实测；官方原文见 §12.2.1.1 ②） |
| **工具栏本体** | `NSToolbar` + `toolbarStyle = .unified`（11.0+） | 高度 / 材质 / 分隔线由系统给（实测 52pt）；本轮里面**只剩刷新一个 item** |
| **侧栏宽度锁定** | `NSSplitViewItem.minimumThickness` / `maximumThickness`（同值） | 用户要求「按内容适应后锁定」；设 200 ⇒ 面板**本体**宽 200（§11.4） |
| ~~侧栏折叠钮~~ | ~~`NSToolbarItem.Identifier.toggleSidebar`~~ | ❌ **第 11 轮整体退役**（用户：「不需要了」）—— 随之作废的还有 `sidebarTrackingSeparator` 与 `canCollapse`，本节保留它们只为「记录为什么删」 |
| 分栏结构 | `NSSplitViewController` / `NSSplitViewItem(sidebarWithViewController:)` | 流体缩放由系统给 |
| **窗口标题 / 副标** | `NSWindow.title` / **`NSWindow.subtitle`（11.0+）** | ❗`NSToolbarItem` **没有** `subtitle` 属性（SDK 已核实）；「3 块」只能走窗口副标 |
| **按钮** | `.buttonStyle(.borderedProminent / .bordered / .borderless)` + `.controlSize(...)` | 形状/尺寸/玻璃由系统给；**颜色**由 `.tint(...)` 注入 |
| **开关** | `Toggle` + `.toggleStyle(.switch)` | 替换自绘的 `SettingsSwitch`；**整行可点靠把行内容做成 label** |
| ~~同心圆角~~ | ❌ **不可用**：`ConcentricRectangle` = **macOS 26.0+**、`NSViewCornerConfiguration` = **macOS 27.0+** | 我们最低支持 14 ⇒ 用它们必然写 `if #available` ⇒ 违反 R5。**别把它当"要走的系统 API"**，见 §12.1 |
| 滚动内容被控件遮挡时的可读性 | 系统 scroll edge effect | 系统栏默认有；自定义栏需注册 |

**⚠️ 折叠钮位置的一条实现要点（2026-09-30 实测得出）**：
系统标准项在**纯默认项序**下会被摆到工具栏**尾端**；原生 App（Keynote）是**显式放进前缘项序**的，
渲染结果才是「切换钮 + 标题」整组对齐**内容区左缘**。设计稿只表达这个结果，实现侧照做即可。

---

## 5. 定量参照（2026-09-30 本机 macOS 26 实测）

测量对象：「系统设置」窗口（`com.apple.systempreferences`，723×820 逻辑点）——它与 v3 同构
（侧栏 + 内容区），是最直接的**同代际官方标尺**。方法：`screencapture -x -o -l<窗口ID>` +
逐行亮度簇扫描（2x 图 ÷2 = 逻辑点）。

### 5.1 尺度层 —— **与我们一致，不需要改**

| 元素 | 系统设置实测（macOS 26） | 我们的值 | 结论 |
|---|---|---|---|
| 侧栏行高 | **28pt**（选中行 y 330→358） | `.sside__item { height: 28px }` | ✅ 一致 |
| 分组卡片行高 | **44pt**（行界 251→294→337） | `.sline { min-height: 44px }` | ✅ 一致 |
| 侧栏行内左内距 | 选中胶囊 x 14→222.5 | `.sside__item { padding: 0 8px }` | 同量级 |

⇒ **L2 自绘层的尺寸规格，26 与 14–15 通用，一个字都不用改。** 这是「不需要两套稿」的实测证据。

### 5.2 材质 / 颜色层 —— **差异全在这里，且全都归系统**

| 元素 | 系统设置（macOS 26） | 我们 v2/v3 稿 | 归属 | 处置 |
|---|---|---|---|---|
| 侧栏选中态 | **`#dddcdb` 中性灰胶囊**（非强调色） | `--accent` `#0a84ff` 实底 + 白字 | **L1 系统** | 稿子改标语义；实现走系统选择样式 |
| 侧栏面板底 | `#f7f7f7`（半透明材质渲染结果） | `--bg-glass` rgba 白 | **L0 系统** | 稿子标注「HTML 模拟，实现禁消费」 |
| 内容区底 | `#ffffff` | `--bg-base` `#ffffff` | L0 系统 | ✅ 同色，但仍走系统 |
| 分组卡片底 | **`#f7f7f7` 浅灰、无描边** | 白底 + `0.5px` 描边 + 阴影 | **L1 系统** | 稿子标注为语义「系统分组样式」 |
| 卡片间间隙 | **10pt 白间隙**（多卡分离） | 0（一张大卡 + 内部分隔线） | **结构性差异** | 见 5.3 |
| 行分隔线 | 亮度 ≈235 的极轻线 | `--hairline` rgba(60,60,67,.08) | 同量级 | 保留 |
| 窗口实体 | 8.0 → 702.5pt（694.5 宽） | 800×520 | — | v3 尺寸自定，无冲突 |

### 5.3 一处结构性差异 —— ✅ **第 11 轮已定向**（用户拍板）

「系统设置」在 26 上是**两块分离的浮动面板**（侧栏面板 8→≈228，内容面板 250→702.5，间隙≈22pt）；
而 **Keynote 是窗口内一体分栏**。

⇒ 分离面板是**系统设置自己的选择**，不是 26 的强制形态。

**✅ 第 11 轮用户拍板：「左侧栏要 macOS 26 的悬浮玻璃形态」。**
实测（§11.4）证明：`NSSplitViewItem(sidebarWithViewController:)` 在 26 上**本来就**把侧栏渲染成
**四边内缩 8pt 的圆角面板**；差只差在没有像系统设置那样把**内容区**也做成浮岛。
⇒ 我们**采纳侧栏浮岛**（面板内缩 8pt + 圆角 **17.5pt**，内容区仍贴边），与「系统设置」同族而不全同；
   Keynote 那种「完全贴边」的旧形态**不再采用**。
> 关键：**这不是改代码改出来的**，是系统默认行为——原来的稿子画错了（画成贴边通高），
> 所以看着不像；实现侧一行都不用动。（用户第 11 轮原话：「左侧栏不是 macos26 风格的悬浮玻璃」。）

---

## 6. 代际表现对照（26 / 14–15）—— 谁切换，而不是两套稿

| 元素 | macOS 26 表现 | macOS 14–15 表现 | 切换者 |
|---|---|---|---|
| 窗口 / 面板底 | Liquid Glass | 传统 vibrancy 毛玻璃 | **系统**（同一份 `NSVisualEffectView` 代码） |
| 侧栏选中态 | 灰胶囊（26 系统样式） | 强调色实底（传统样式） | **系统**（同一份列表选择代码） |
| 控件形状 / 圆角 | 更圆；**连续曲率（squircle）** | 较方、正圆 | **系统**（不写死度量即自动跟）。⚠️ 「与窗口同心」在实测下**不成立**，见 §12.2.2 |
| 侧栏浮岛（内缩 + 圆角） | 内缩 8pt + 圆角 **17.5pt**（全高档） | 老形态：贴边通高、无浮岛圆角 | **系统**。❗ 同机换窗口配置就变 6.5 / 0pt ⇒ 我们**不需要**知道这个数，见 §12.2.2 / §12.3 |
| 窗口圆角（外壳本身） | **17.5 或 31.5pt —— 随窗口配置变** | 另一档（本机测不到） | **系统**。❗ 我们**不需要**知道这个数，见 §12.3 |
| 按钮 | 玻璃质感 | 传统按钮 | **系统** |
| 侧栏浮岛形态 | 四边内缩 8pt + 圆角面板 | 贴边、无浮岛 | **系统**（同一份 `NSSplitViewItem(sidebar…)` 代码） |
| ~~侧栏折叠钮~~ | — | — | ❌ 第 11 轮删除，不再有跨代差异 |
| 版面尺寸 / 间距 / 字号 / 语义色 | 同 | 同 | **我们**（L2，两代一个值） |

**读法**：右边一列出现「系统」的行，设计稿都不该给颜色/尺寸；出现「我们」的行才需要精确值。
**「两套稿」想覆盖的，恰好全是「系统」那几行 —— 那些行系统自己会切。**

---

## 7. 设计稿的定位修正（v3 稿要做的改动）

设计稿从「像素规格书」修正为「**布局规格 + 结构规格 + 语义规格**，像素规格只覆盖 L2」。

v3 稿（`screens/_10-combined-draft.html`）的具体改动：

1. **顶部加「代际归属声明」注释块** —— 标明本稿哪些部分是 HTML 模拟、实现侧禁止消费。
2. **`.sside__item[aria-selected]`** —— 注释改标语义（「系统侧栏选择样式」），
   并注明 26 实测为灰胶囊 `#dddcdb`；**accent 实底降级为「HTML 模拟值，勿照抄」**。
3. **`.scard`** —— 标注为「系统分组样式（26 实测浅灰无描边）」，
   白底 + 描边是 HTML 模拟；实现走系统分组/材质。
4. **圆角令牌** —— 加注「**按系统版本给实现侧定义**：分四类元素处置，见 §12；
   ❌ 不要写「实现侧用 `ConcentricRectangle`」——那是 26.0+，我们最低 14，用不了」。
5. **材质令牌**（`--bg-glass` 等）—— 在稿内与规范里统一标注「**仅 HTML 模拟，实现侧禁止消费**」。

### 7.1 ✅ 定案后追加的改动（2026-09-30）

6. **侧栏改画成系统形态** —— `.win--v3 .sside__item` 选中态从 accent 实底
   改为**灰胶囊 + 深字**（浅色 `#dddcdb` / 深色 `rgba(255,255,255,.12)`），圆角改胶囊；
   markup 语义从 `tablist/tab` 改为 `listbox/option`（对应系统的 source list 角色）。
   ⇒ 稿子与真机**同形**，工程师不会照着一代前的视觉去实现；**色值仍是模拟值，实现走系统选择样式**。
   出图自检（`SELBG` 探针）实测：浅色 `rgb(221, 220, 219)` / `radius: 999px` / 深色字，
   深色 `rgba(255, 255, 255, 0.12)` / 浅色字 —— 证明覆盖生效，不是"改了文件所以应该生效"。
7. **按钮块重写为「保留自绘」定案** —— 写明两条约束（① 圆角走同心公式；
   ② 声明「不随代际变」）与「**不要用 26-only API 去追系统**」，并指向对照图。
8. **左栏规格随之作废的三项**（已接受）：顶部 52pt 让位对齐、1pt 行距、强调色选中态
   —— 改由系统决定；分组标题「设置」走系统 Section header。

### 7.2 ✅ 第 10 轮（四条拍板）追加的改动

用户答复四条：① 头部走真系统工具栏（元素须同一水平基线）② 侧栏宽按内容适应后锁定
③ `⌘,` 直接定位到「设置·通用」 ④ 除颜色外都用系统组件风格。据此：

9. **头部结构改了**：工具栏带**横跨整个窗口**（含侧栏上方），窗内是「工具栏带 + 下方横向分栏」。
   ⇒ 稿子的 `.sdetail__head` / `.sdetail__title` / `.sdetail__sub` 三件套**退役**
   （它们是「头部在右栏内部」的产物），改为 `.v3toolbar` 一组绝对定位元素。
   ⚠️ 稿子的 DOM 结构**不代表实现层级**（实现侧是 `NSToolbar` + `NSSplitViewController`），
      稿子只表达**结果**：元素的相对位置与共线性。
10. **按钮改画成系统形态**：`.win--v3 .btn { border-radius: var(--r-full) }`（胶囊），
    并注明实现侧走 `.borderedProminent` / `.bordered` / `.borderless` + `.tint`。
    上一轮那句「保留自绘、声明不随代际变」**作废**。
11. ~~**折叠钮位置按实测重画**~~ —— ❌ **第 11 轮整条作废**（用户删除折叠钮）。
    保留此行只为记录：第 9→10 轮曾在「钮该放哪」上连错四轮，教训是
    **系统组件的位置必须「真 App 像素测量 + spike 交叉验证」两条腿**，缺一条就会错。

### 7.3 ✅ 第 11 轮（三条反馈）追加的改动

用户三条：① 左侧栏不是 macOS 26 的悬浮玻璃；② 标题不该在红绿灯旁，该在右侧区域顶部；
③ 折叠钮删掉、不需要了。据此：

14. **左栏改画成浮岛**：`.win--v3 .sside` 从「贴边通高 + 右侧 0.5px 分隔线」
    改为「四边内缩 8pt + 圆角 **17.5pt** + 独立底」（`margin: 8px 0 8px 8px`；圆角值第 12 轮复量订正）。
    ⚠️ **圆角值第 12 轮按实测订正**：第 11 轮目视取 10pt 是错的（见 §11.4 与 §12.2）。
    ⇒ 面板本体宽仍 200pt，内容区左缘随之落在 **208pt**（探针 `FLOAT` / `DETAIL` 实测）。
    ⚠️ 这是**系统默认行为的记录**，不是要求实现侧画一块（§11.4）。
15. **标题归位**：第 10 轮退役的 `.sdetail__head` 三件套 **恢复**，`.v3toolbar` 整组删除。
    标题 + 副标回到内容区顶部；head 高取 52pt ⇒ 标题中心 = 26pt，
    与红绿灯、右上刷新按钮**同一条水平基线**（探针 `BASELINE` 实测三者一致）。
16. **折叠钮删除**：`toggleSidebar` / `sidebarTrackingSeparator` / `canCollapse` 整体退役；
    稿内 `.v3toggle`、`.win--v3.collapsed` 与**原帧 3（折叠态）一并删除** ⇒ 稿子从三帧变**两帧**。
17. **`.v3toolbar__sep` 删除**（它只是 `sidebarTrackingSeparator` 的示意图，没了钮就没了意义）。
18. **代际声明的口径修正**：从「26 风格稿故意不提供」改为「**几何能画，材质画不了**」——
    浮岛的内缩 / 圆角 / 两块板的位置关系**可以**精确画进稿子（本轮已画）；
    Liquid Glass 的 vibrancy / 动态高光 / 滚动边缘仍然画不了，一律以真机截图为参照。
12. ~~**副标改两行竖排**（走 `NSWindow.subtitle`）：26 上标题 + 副标两行 ⇒ 工具栏自然 52pt 高，
    与稿子高度**恰好一致**~~ —— ❌ **第 14 轮作废**：标题归内容区头部，且 `titleVisibility = .hidden`
    ⇒ 系统标题不显示、`subtitle` 也无处可显（见 §7.4 第 22 条、§11.6）。
13. **新增「基线」自检**：出图脚本的 `BASELINE` 探针量四个元素的垂直中心，
    三帧实测**全部 = 26.0**（工具栏高 52 的一半）⇒ 用户第 1 条要求被量化证明。

### 7.4 ✅ 第 14 轮（工具栏存废）追加的改动

用户一条：「提醒 1 不要了，但是刷新按钮往哪里放？」（即当时的 §8 待拍板项 —— **现已定案**）。据此：

19. **工具栏定案保留**，项序 `[.flexibleSpace, refresh]`。「只剩一个按钮」**不构成删除工具栏的理由** ——
    它同时提供 52pt 安全带 / 红绿灯居中到 26pt / 拖拽区 / 双击缩放；删掉后红绿灯掉到 16pt、
    侧栏浮岛顶掉到 32pt、顶部左右割裂、拖拽与双击缩放丢失，其中前两项**手工补不齐**（§11.6）。
20. **`titlebarAppearsTransparent = true` 与 `titleVisibility = .hidden` 从退役清单撤回，转「必须保留」**
    —— 实测删掉前者 ⇒ 工具栏材质把内容区头部带**整条盖住**；删掉后者 ⇒ 系统窗口标题与头部带文字**叠印**。
    ⇒ 退役清单从 5 项缩到 **3 项**（`enlargeTitleBar(in:)` / `alignTrafficLights(in:)` / `ContentView.titleBar`）。
21. **刷新按钮落点 = 工具栏尾端**，不另设位置。头部带与工具栏是**同一条 52pt 带**（都占 y ∈ [0,52]），
    那条带本来就是满的 ⇒ 「空荡」这个观感不存在（证据 `.workbuddy/verify/v3-headband-B-transparent.png`）。
22. **第 10 轮的「副标走 `NSWindow.subtitle`」作废**（见上条第 12 条的删除线）。

---

## 8. v3 落地清单（实现侧）

- [ ] 窗口外壳：`NSSplitViewController` + `NSSplitViewItem(sidebarWithViewController:)`
- [ ] **侧栏浮岛**：❗**不用写任何代码** —— 26 上系统自动给内缩 8pt + 圆角 + 玻璃，14–15 自动是老形态
      （实测见 §11.4）。若实现侧发现稿子里的内缩没出现，**先查是不是套了自定义背景/圆角把它盖掉了**
- [ ] **侧栏宽锁定**：`minimumThickness = maximumThickness = 200`（用户第 2 条）
      ✅ 第 11 轮已查清「设 200 渲染 208」：**不是 bug** —— 系统把 200 当**面板本体**宽，
      再整体内缩 8pt ⇒ 外沿在 8→208。照写 200 即可，**不要为了凑 208 去改数字**
- [ ] **工具栏**：`NSToolbar` + `toolbarStyle = .unified`；本轮里面**只剩刷新一个 item**
      ⇒ 项序退化为 `[.flexibleSpace, refresh]`（`toggleSidebar` / `sidebarTrackingSeparator` 已删）
- [ ] **标题 / 副标**：标题归内容区头部（`.sdetail__head` 形态），**不再走 `window.title`**；
      若要给副标一个系统位，`NSWindow.subtitle`（11.0+）仍在，但它会占用工具栏那一行，按需选
- [ ] **退役自绘头部**：`enlargeTitleBar(in:)` / `alignTrafficLights(in:)` / `ContentView.titleBar`
      及配套自检与断言 —— 只退役**这三个**（高度改由工具栏给、红绿灯由系统居中、位置由内容区头部带接管）
- [ ] ⚠️ **但下面这两条必须保留，且看着像「旧机关残留」最容易误删**（❗第 14 轮订正，此前误列入退役清单）：
      `titlebarAppearsTransparent = true` / `titleVisibility = .hidden`。
      实测：删掉前者 ⇒ **工具栏材质把内容区头部带整条盖住**（画面上白茫茫，代码里"明明写了"）；
      删掉后者 ⇒ **系统窗口标题与头部带文字叠印糊在一起**。
      它们不是「伪造头部」的手段，而是「让工具栏那 52pt 带来让位给内容区」的手段。
      证据 `.workbuddy/verify/v3-headband-{A-opaque,B-transparent,C-titleshown}.png`；
      探针 `.build/probe/window_radius_spike/nobar.swift`
- [ ] **窗口 / popover 底**：沿用 `GlassViews.swift` 的 `NSVisualEffectView`（**已合规，勿改**）
- [ ] ⛔ **侧栏内部**：**不要**放 `NSVisualEffectView`（官方明令移除，§12.2.1.1 ②）；侧栏玻璃由
      `NSSplitViewItem(sidebarWithViewController:)` 自带 ⇒ 那格**什么都不放**
- [ ] 侧栏选中态：走系统选择样式（SwiftUI `List(selection:)` + `.listStyle(.sidebar)`），不自绘颜色 ✅ 定案
- [ ] 侧栏**圆角 / hover / 方向键 / 无障碍语义**：**全部交还系统**，左栏不保留自定义规格
- [ ] ⚠️ **侧栏行高 / 行距：第 13 轮破例自定**（2026-10-01，用户反馈「左栏选择项分布不均、
      下边空了一大块」）。实测侧栏面板 504pt 高而六项只占 209.5pt ⇒ **底部空白 47%**；
      把行高 32 → 43.5pt、分组间距 18.5 → 约 28pt 之后降到 **31%**（与「系统设置」同量级）。
      ⇒ 实现：`DesignTokens.Size.sidebarRowVerticalInset`（**只有 `listRowInsets` 有效**，
      内容 `.padding` 与 `defaultMinListRowHeight` 实测都撑不动 sidebar 行）。
      ⛔ 别再去收窗口高度（被三盘契约 440 死线挡住）或把「关于」沉底（总空白不变）。
      这条与上一行的「行高交还系统」**是冲突的**，属用户知情的破例，不是漏改。
- [ ] 分组标题「设置」：走系统 Section header
- [ ] **按钮（`ActionButton` 5 变体）：交还系统**（❗第 10 轮改判）——
      `.borderedProminent` + `.tint(...)` / `.bordered` / `.borderless` + `.controlSize(...)`；
      **移掉自绘底色与 `strokeBorder`**；⚠️ 尺寸 30→28、26→24，**布局要重量**
- [ ] **开关（`SettingsSwitch`）：交还 `Toggle` + `.toggleStyle(.switch)`**；
      并把行内容（标题 + 说明）做成 `Toggle` 的 label，**保住「整行可点」这个既有约定**
- [ ] 分组卡片：走系统分组样式；若自绘则用系统材质而非白底+描边
- [ ] 圆角：**分四类元素处置**（§12.3）—— 窗口 / 浮岛面板 / 系统控件三类**什么都不做**；
      只有**自绘元素**要算：`子圆角 = max(我们自己的父圆角 − 内距, 最小圆角)`。
      ❌ **不要用 `ConcentricRectangle`**（26.0+，§12.1）；❌ 不要读/反推窗口圆角（R6）；
      **任何元素上都不留 `6px` 这类裸常量**
- [ ] **颜色是唯一由我们给的**：品牌强调色走 `.tint(...)`、语义色（琥珀/红/绿）照 L2 实现
- [ ] **不写** `if #available(macOS 26)` 视觉分支；**不消费**设计稿材质令牌；**不用** 26-only 工具栏 API
- [ ] 走查：在 26 与 14–15 各截一次图，对比「系统切换是否正常」（而不是对比「是否符合某套稿」）

---

## 9. 附：本次取证产物

| 文件 | 内容 |
|---|---|
| **`.workbuddy/verify/v3-radius-evidence.png`** | **第 12 轮证据总图**：官方 API 可用性 + 圆角实测四宫格 + 两条假设纠正 + 落地口径（见 §12.4） |
| **`.build/probe/window_radius_spike/`** | **第 12 轮圆角探针**（4 个，可重跑）：窗口 / 浮岛 / 单窗复核 / 读不到证明（见 §12.4） |
| `.workbuddy/verify/v3-combined-light.png` | v3 帧1：磁盘页（浅色）—— **侧栏浮岛** + 标题在内容区顶部 |
| `.workbuddy/verify/v3-combined-dark.png` | v3 帧2：设置页（深色，含 hover 态模拟） |
| **`.workbuddy/verify/v3-r11-changes.png`** | **第 11 轮三处改动的标注图**（浮岛 / 标题归位 / 删钮），底图为稿子实际渲染 |
| **`.workbuddy/verify/10-侧栏行距-改前改后.png`** | **第 13 轮侧栏行距实测**（2026-10-01）：左右并排 = 改前（行高 32pt，底部空白 47%）／改后（行高 43.5pt，空白 31%）。两张都是 `screencapture -x -o -l<窗口ID>` 的真机窗口位图（2x）裁出的侧栏列 |
| **`.workbuddy/verify/v3-float-spike-{a,b}.png`** | **第 11 轮浮岛实测**：a = 面板从工具栏下开始 / b = `allowsFullHeightLayout`（面板到窗口顶、红绿灯浮其上）= **系统设置同形**（本稿取 b） |
| **`.build/probe/sidebar_float_spike/main.swift`** | **浮岛 spike**（第 11 轮新增，可重跑；内容区涂半透明色以量出真实边界） |
| `.workbuddy/verify/v3-sidebar-before-after.png` | 侧栏「改前（自绘实底）vs 改后（系统灰胶囊）」对照（第 9 轮产物，仍有效） |
| `.workbuddy/verify/v3-system-buttons-{light,dark}.png` | 系统按钮五变体真机渲染（浅色 / 深色）—— 交还系统后的目标形态 |
| `.workbuddy/verify/syssettings-tahoe-real.png` | 系统设置窗口（macOS 26）真机截图 —— **浮岛 + 灰胶囊同框参照** |
| `.workbuddy/verify/v3-toolbar-spike-v{1..4}.png` | ⚠️ 工具栏 4 变体实测（**第 11 轮起降为历史记录**：钮已删，那张项序表作废） |
| `.workbuddy/verify/keynote-tahoe-real.png` | Keynote 文档窗口（第 11 轮起降为历史记录：它当年的用途是定折叠钮位置） |
| `.build/probe/toolbar_anatomy_spike/main.swift` | 工具栏解剖 spike（第 10 轮；钮删后不再是实现依据） |
| `.build/probe/button_system_spike/main.swift` | 系统按钮 spike（第 10 轮；含 `fittingSize` 高度实测） |
| `.workbuddy/verify/v3-collapsed-light.png` | ❌ **第 11 轮作废**（折叠态帧已删；文件可能仍在磁盘上，**勿当依据**） |

> ⚠️ **做对照截屏时的一个坑**（第 10 轮实测踩到）：**非激活窗口的强调色按钮会被系统去色**。
> 第一版「浅色」截图里，窗口先创建 ⇒ 失去焦点 ⇒ `primary` 与 `danger` 全被画成灰胶囊、
> 彼此无法区分，看起来像「系统按钮没有强调色」——**是一张假图**。
> ⇒ 对照截屏要**逐个把窗口设为 key 再截**，不要一次循环截完。

> ⚠️ 本规范**故意不提供「26 风格设计稿」**。原因见第 1 节③：静态稿表达不了 Liquid Glass，
> 画出来只会诱导自绘。26 风格的参照一律用**真机截图**。

---

## 10. L1 细化：自绘控件 vs 系统控件 —— 逐组件处置

> 2026-09-30 补。触发：设计师问「左侧菜单栏的样式、按钮的样式现在都不是按 macOS 26 风格设计的，
> 这会不会给开发工程师在代码实现上造成理解差异？」

### 10.1 问题成立，而且比材质层更隐蔽

第 2 节把「按钮、开关、选择态」列进了 L1（系统层），但**漏了一个前置事实**：
这两类控件在**现有实现里是自绘的**——

| 控件 | 实现位置 | 画法 |
|---|---|---|
| 侧栏项 | `SettingsView.swift` `SettingsSidebarItem` | `.buttonStyle(.plain)` + 自绘 `RoundedRectangle(cornerRadius: 6)` + `accent` 实底 |
| 按钮 | `DesignSystemComponents.swift` `ActionButton` | `.buttonStyle(.plain)` + 自绘底 + `strokeBorder` 1px 描边 |

于是出现两层分化，而**只有一层是安全的**：

- **材质层**（窗口底 / popover 底）走 `NSVisualEffectView` ⇒ **系统换代时自动跟着变**，工程师想搞错都难；
  （**侧栏是例外**：它的玻璃由 sidebar split item 自带，我们连 `NSVisualEffectView` 都不放，见 §12.2.1.1 ②）；
- **控件层**是自绘 ⇒ **系统换代时一动不动**，设计稿画成什么样就实现成什么样。

⇒ 用户的判断准确：**理解差异恰恰出在这里**。材质层已经"交给系统"了，控件层没有。
设计稿上那套 Sequoia 一代的控件视觉（实底 + 小圆角 + 描边），会被 1:1 搬进 macOS 26 的产品里。

### 10.2 实测差距（本机 macOS 26 · spike 真渲染）

spike：`.build/probe/control_style_spike/main.swift`（左栏照 v3 稿复刻，右栏系统控件）。
标注图：`.workbuddy/verify/v3-control-style-gap.png`。

| # | 项 | 我们（照 v3 稿） | 系统控件（26 自动渲染） |
|---|---|---|---|
| 1 | 侧栏选中态 | `#3478F6` 强调色实底 + **白字** | `#DCDCDC` 中性灰胶囊 + **深色字** |
| 2 | 选中态圆角 | **6pt** 方角（`--r-sm`） | **胶囊**（半径 ≈ 行高一半） |
| 3 | 按钮形状 | 6pt 圆角矩形 + **1px 描边** | **全胶囊**（无描边） |
| 4 | 按钮材质 | **实色填充** / 透明描边 | **Liquid Glass 玻璃底** |

官方对这类情况的表述很直接（Adopting Liquid Glass）：
> "**Reduce your use of custom backgrounds in controls and navigation elements.** Any custom
> backgrounds and appearances you use in these elements might **overlay or interfere with**
> Liquid Glass or other effects that the system provides."
> "Prefer to remove custom effects and let the system determine the background appearance,
> especially for the following elements: NavigationStack, **NavigationSplitView**, titleBar, toolbar(content:)"

WWDC 2025-323 的迁移建议同向：
> "clean up hacks added in older versions … (**custom backgrounds**, translucent overlays,
> presentationBackground) … the more you keep, **the worse it looks**"

### 10.3 判据：什么时候必须把控件交还给系统

逐控件争论会没完。收敛成一条**可复用判据**：

> **这个控件的视觉，是不是「系统惯例的一部分」？**
> （自问：用户在**别的 App** 里见过同样的形状与反馈吗？）

- **是** → 交还系统控件。系统给的是「两代免费正确」：26 玻璃 / 14–15 传统，且零 `#available` 分支。
- **否**（是产品自有的视觉语言）→ 保留自绘，但规范里**必须显式声明「不随代际变」**——
  否则下一个人会把"它和系统不一样"当成漏改，然后写一段手工追系统的代码（最坏结果）。

### 10.4 逐组件处置表

| 组件 | 系统惯例？ | 现状 | ✅ 决定 | 代价 / 备注 |
|---|---|---|---|---|
| **侧栏项**（选中态、圆角、hover、方向键） | ✅ 是 | 自绘：accent 实底 + 6pt 方角 | **交还系统**：`List(selection:)` + `.listStyle(.sidebar)`（第 9 轮拍板） | 已接受：顶部对齐 / 1pt 行距 / 强调色选中 三项自定义规格作废。换来：方向键导航、VoiceOver 选中语义、**用户强调色偏好** |
| **顶部工具栏**（本轮只剩刷新） | ✅ 是 | ❌ 现状**没有** `NSToolbar`，是自绘 52pt 头部 | **交还系统**：`NSToolbar`（第 10 轮拍板）。**第 11 轮缩到只剩刷新一个 item** —— 标题移出工具栏、归内容区头部。**第 14 轮定案：工具栏保留**，`[.flexibleSpace, refresh]` | 自绘头部那 3 个机关退役（净减）；✅ 折叠钮与 `sidebarTrackingSeparator` 已删，**项序复杂度消失**。⚠️ **「只剩一个按钮」不构成删除工具栏的理由** —— 它同时提供 52pt 安全带 / 红绿灯居中到 26pt / 拖拽区 / 双击缩放；删掉后红绿灯掉到 16pt、侧栏浮岛顶掉到 32pt、顶部左右割裂（实测见 `.workbuddy/verify/v3-headband-D-no-toolbar.png`），其中红绿灯位置与浮岛内缩**手工补不齐** |
| **侧栏浮岛形态**（四边内缩 + 圆角） | ✅ 是 | ✅ **系统已经给了**（26 上自动内缩 8pt + 圆角） | ❗**不用做任何事**：26 自动浮岛、14–15 自动贴边（§11.4 实测） | ⚠️ 唯一风险：若加了自定义背景 / 圆角**把它盖掉**，看起来就不像 26 了 |
| **通用按钮**（primary/danger/outline/neutral/ghost） | ✅ 是（系统有对应样式） | 自绘：实色矩形 + 描边 + 6pt 圆角 | ❗**交还系统**（**第 10 轮改判，推翻第 9 轮的「保留自绘」**）：`.borderedProminent` + `.tint(品牌色)` / `.bordered` / `.borderless` + `.controlSize` | **颜色是唯一由我们给的**；⚠️ 高度 30→28、26→24，布局要重量 |
| **开关** | ✅ 是 | 自绘：`Capsule` + `Circle` + 阴影（`SettingsSwitch`） | **交还** `Toggle` + `.toggleStyle(.switch)` | ⚠️ 必须把行内容做成 `Toggle` 的 label，**保住「整行可点」**这个既有约定 |
| 语义色徽章（琥珀 / 红 / 绿） | ❌ 否 | 自绘 | 保留（L2，**颜色归我们**） | 无 |
| 磁盘行 / 容量条 / 磁盘图标 | ❌ 否 | 自绘 | 保留（L2） | 无 |
| 设置行的**行内排版**（标题 + 说明 + 控件三栏） | ❌ 否 | 自绘 | 保留结构（L2）；但**容器与圆角走系统** | 行高由内容定，仍要受 §5 的高度预算约束 |
| 分组卡片 | ⚠️ 部分 | 自绘：白底 + 描边 | 走系统分组样式（`Form` / `Section` 或系统材质） | 26 实测系统分组卡片是浅灰无描边、卡间 10pt 间隙 |
| 窗口底 / popover 底材质 | ✅ 是 | 已交还 | `NSVisualEffectView` ✓ | 无 |
| **侧栏底材质 + 圆角** | ✅ 是 | 已交还 | **什么代码都不写**：`NSSplitViewItem(sidebarWithViewController:)` 自带玻璃与圆角 | ⛔ **不要**往里放 `NSVisualEffectView`（官方明令移除，§12.2.1.1 ②）；⛔ 不要自设 `cornerRadius` |

**注意**：交还系统 ≠ 放弃设计。系统给的是**用户偏好色**（用户可在"外观"里改强调色，甚至设为石墨色）、
正确的圆角、hover、方向键与无障碍语义——这些我们自绘版**一条都没做全**。
设计稿的职责随之从「画那个胶囊 / 那个按钮」变成「**声明这里是一个系统控件**」，
我们保留的只有**颜色**（品牌强调色 + 语义色）。

> **本轮的处理是「两个都做」**：① 稿子**画成系统形态**（侧栏灰胶囊、按钮胶囊），
> 免得工程师照着一代前的视觉去实现；② 同时在稿内与本节**显式声明它们归系统**，
> 免得工程师把那些模拟色值当规格抄进代码。
> 对照图：`.workbuddy/verify/v3-sidebar-before-after.png`、
> `.workbuddy/verify/v3-system-buttons-{light,dark}.png`。

### 10.5 禁令补一条：不要用 26-only API 去"补"玻璃

必须说清，否则很容易被当成解法：

| API | 最低版本 |
|---|---|
| `View.glassEffect(_:in:)` | **macOS 26.0+** |
| `.buttonStyle(.glass)` / `.glassProminent` | **macOS 26.0+** |
| `NSGlassEffectView` | **macOS 26.0+** |

我们最低支持 **macOS 14**。用这些 API 必然要写 `if #available(macOS 26)` ⇒ **直接违反 R5**；
而且在 14–15 上完全没有效果，等于为老系统写了一段死代码。

> ⇒ **要两代都对，唯一的路是「用系统控件」，不是「用 26 的 API 手工补」。**

### 10.6 待修清单

- [x] v3 稿补 `.btn` / `.iconbtn` 的归属标注（第八轮已补）
- [x] v3 稿侧栏改画为系统形态 + markup 语义改 `listbox/option`（第九轮已改，含 `SELBG` 探针自检）
- [x] 侧栏 / 按钮的路线确定，§2 的 L1 行曾拆出 **L1′（产品自绘控件）**
- [x] ❗**第 10 轮：按钮改判交还系统** ⇒ **L1′ 层已并入 L1、不再有成员**（§2 表已注记）
- [x] 第 10 轮：v3 稿头部改画为系统工具栏带 + 结构改为「工具栏横跨全窗」；折叠态按实测改正
- [ ] **实现阶段**：核实并处理 `SettingsView.swift` `SettingsSidebarItem` 的错误注释
      （「Finder 与系统设置都这样」）—— 该组件整体退役，注释随之删除
- [ ] **实现阶段**：确认 `List(selection:)` 在部署目标 macOS 14 上可用（该 API 是 13.0+ ⇒ 必然可用），
      并复核「交还系统后左栏宽 200 与实测 208 的差值」（§3.3 / HANDOFF §3.3）
- [ ] **实现阶段**：核实 `NSSplitViewController` 的 sidebar 在 `min = max` 时是否真的拖不动
- [ ] **实现阶段**：实测 `Toggle` 的 label 在 macOS 14 上是否可点（决定「整行可点」怎么保）
- [ ] ❗**实现阶段（第 13 轮新增，优先级最高）**：处理 `contentView.layer.cornerRadius = 12` 的两处赋值
      —— 主窗口 `Sources/Views/ContentView.swift:227–234`（经 `WindowAccessor`）、
      设置窗口 `Sources/SafeOutApp/SafeOutApp.swift:2367–2369`。
      12 与实测窗口圆角（31.5 / 17.5）**不是一个量级** ⇒ 遮罩会切出**比窗口更小的圆**。
      按 §12.3.1 处置（截图判定、不要盲删也不要盲留）。详见 `HANDOFF.md` §3.7.3

---

## 11. 工具栏与浮岛实测（2026-09-30 · macOS 26）

> 触发 ①（第 10 轮）：用户拍板「头部走真系统工具栏」+「除颜色外用系统组件」。
> 触发 ②（第 11 轮）：用户指出「左侧栏不是 macOS 26 风格的悬浮玻璃」。
> 上一轮钮位连错四轮的教训是**拿记忆当依据**，所以每一轮都**先测再画**。
>
> ⚠️ 本节 §11.2 / §11.3 关于**折叠钮**的内容，第 11 轮起**降为历史记录**（钮已删）。
> 仍然有效的是：§11.1 的方法与两个坑、§11.4 的浮岛实测、§11.5 的 26-only 禁令。

### 11.1 方法

spike：`.build/probe/toolbar_anatomy_spike/main.swift` —— 一个程序开 4 个窗口、同屏渲染，
每个变体只改**工具栏项序 / 折叠状态**一个变量；截图按窗口 ID 直取，同时打印每个 item 的窗口坐标。

条件：窗口 800×604（= 520 内容 + **52 工具栏**）、`NSSplitViewController` 的 sidebar
设 `min = max = 200`（**实测渲染 208**）、`toolbarStyle = .unified`、`window.subtitle = "3 块"`。

**踩到的两个坑**（都已修，记下来免得别人重踩）：
1. **`contentViewController` 赋值后窗口会被 split view 撑大**（800 → 1008）——
   不显式 `setContentSize` 的话，「侧栏 200 + 内容 600」这个目标形态**根本没被渲染出来**，
   量到的所有坐标都是废的。
2. **`NSToolbar.delegate` 是 weak** —— 局部变量立即释放 ⇒ 按钮渲染不出来，
   看起来像「系统不给画按钮」。

### 11.2 工具栏数据（⚠️ 第 11 轮起降为历史记录）

| 变体 | 项序 | 折叠钮落点（窗口 x） | 结论 |
|---|---|---|---|
| v1 | `[.toggleSidebar]`（纯默认） | **694.5 → 734** | ❌ 被甩到**右上角** |
| v2 | `[.toggleSidebar, .sidebarTrackingSeparator, …, refresh]` | **256.5 → 296** | ✅ **侧栏右缘右侧** |
| v3 | `[.sidebarTrackingSeparator, .toggleSidebar, …]` | 265.5 → 305 | 与 v2 差 9pt（分隔线占位） |
| v4 | 同 v2 但**折叠**侧栏 | **685.5 → 725** | ❗折叠后钮**移到右上角** |

**共线性**：4 个元素（标题块 / 折叠钮 / 刷新钮 / 分隔线）的**垂直中心全部 = 26.0**
（= 工具栏高 52 的一半）。⇒ 用户要求的「垂直水平居中、同一水平基线」是**系统默认行为**，
不需要手算 padding 去对。**这条结论第 11 轮仍然成立**（钮删了，但红绿灯 / 刷新 / 内容区标题
三者依旧自动共线 —— 见 11.4 的 `BASELINE` 探针）。

### 11.3 三条结论（第 1、2 条已随折叠钮删除而失效）

1. ~~**项序必须显式写**，且必须含 `sidebarTrackingSeparator`~~ —— 钮删了，项序不再有坑
   （现在只剩 `[.flexibleSpace, refresh]`）。**但这条教训仍然通用**：系统组件的落点由项序决定，
   不测就会错。
2. ~~**折叠态钮在右上角**~~ —— 随钮删除一并失效。
3. **副标只能走 `NSWindow.subtitle`** —— `NSToolbarItem` **没有** `subtitle` 属性
   （已核对 AppKit SDK 头文件：只有 `title`，10.15+）。**仍然有效**。

### 11.4 浮岛实测（第 11 轮新增）—— 26 的侧栏是「四边内缩 8pt 的圆角面板」

**触发**：用户反馈「左侧栏不是 macOS 26 风格的悬浮玻璃」。

spike：`.build/probe/sidebar_float_spike/main.swift`（可重跑）—— 开两个窗口：
A = 面板从工具栏下开始（`allowsFullHeightLayout = false`）；
B = 面板延伸到窗口顶（`= true`，红绿灯浮在面板上）。
**关键手法**：**给内容区涂一层半透明色** —— 不涂色就量不出它的真实边界
（内容区底色与窗口底同色，肉眼与扫描都分不出来）。

| 量 | 实测值 | 说明 |
|---|---|---|
| 面板左 / 上 / 下内缩 | **8pt** | 面板不贴窗口边 |
| 面板**本体**宽 | **200pt** | 设 `min = max = 200` ⇒ 正好 200 |
| 内容区左缘 | **208pt** | = 8 内缩 + 200 面板；**面板右缘与内容区无缝隙** |
| 面板圆角 | **17.5pt**（第 12 轮复量；第 11 轮目视的「≈10pt」与初测的「16.5pt」**均已作废**） | 与窗口圆角**不同心**：31.5 − 8 = 23.5 ≠ 17.5；且**随窗口配置变**（仅标题栏档 6.5pt、非全高档 0pt）—— §12.2.2 |
| 内容区 | **贴边，不是浮岛** | 蓝色一直顶到窗口右缘、下缘 |

**四条结论**：

1. **这是系统默认行为，实现侧零代码** —— `NSSplitViewItem(sidebarWithViewController:)`
   在 26 上自动给内缩 + 圆角 + 玻璃，14–15 上自动是老形态。
2. ✅ **「设 200 渲染 208」的误会到此查清**：系统把 200 当作**面板本体**宽度，
   再整体内缩 8pt ⇒ 外沿落在 8→208。**照写 200 即可，不要为了凑 208 去改数字。**
3. **只有侧栏是浮岛，内容区贴边** —— 与「系统设置」不完全同（它两栏都浮），
   但那正是 split view 的默认处理，也是最省事、最不容易错的形态。
4. **A / B 两派只差一个属性**：`allowsFullHeightLayout`。B 派（面板到窗口顶、红绿灯浮其上）
   = 「系统设置」同形 ⇒ **本稿取 B**。
5. ❗ **稿子原来画错了**：画成「贴边通高 + 右侧 0.5px 分隔线」，那是 Keynote 的老形态。
   第 11 轮已按实测改成浮岛（探针 `FLOAT` / `DETAIL` 复核：8 / 8 / 8 + 宽 200，
   内容区左缘 208 且无缝隙）。
   ⚠️ **第 12 轮订正两处数值**：① 面板圆角 10px → **17.5px**（第 11 轮是目视、初测 16.5 是另一套阈值读法，都已作废）；
   ② 窗口模拟圆角 → **31.5px**（本稿画的是 unified 工具栏档，不是普通档的 17.5）。详见 §12.2。
   ⚠️ 本稿的窗口圆角是**模拟值**：实现侧**不要**照抄，窗口圆角归系统（§12.3 第 1 类）。

> ⚠️ 消费注意：稿子里 `.sside` 的 `margin: 8px` / `border-radius: 10px` 是**模拟值**，
> 只为让稿子与真机同形；**实现侧不要为了复现它去写自定义背景或圆角**（R1 / R3）——
> 写了反而会把系统默认的浮岛盖掉。

### 11.5 ⚠️ 不要用 26-only 的工具栏 API

| API | 最低版本 |
|---|---|
| `NSToolbarItem.style`（`NSToolbarItemStyle`） | **macOS 26.0+** |
| `NSToolbarItem.backgroundTintColor` | **macOS 26.0+** |

我们最低支持 **macOS 14** ⇒ 用它们必然要写 `if #available(macOS 26)` ⇒ **违反 R5**。
需要「带边框的工具钮」时用 `isBordered = true`（**10.15+**，跨代可用）。

---

### 11.6 头部带 vs 工具栏存废（第 14 轮，2026-09-30）

> 触发（用户原话）：「提醒 1 不要了，但是刷新按钮往哪里放？」
> —— 即 §8 第 1 条「工具栏里只剩刷新一个按钮，还要不要 `NSToolbar`」。

**方法**：`.build/probe/window_radius_spike/nobar.swift` —— 四变体各截单窗口图，三条**互相独立**的路径量红绿灯：
① 公开 API `standardWindowButton(.closeButton)` 的 frame 转「距窗口顶」；② 像素法（活动 = 红/黄/绿、非活动 = 低饱和灰）；
③ 直读两个 pane 的 view 在窗口基坐标里的位置。截图 `screencapture -x -o -l<windowNumber>`，`-o` 去阴影 ⇒ alpha 即窗口轮廓。

**关键数据（本机 macOS 26，2x 截图）**

| 配置 | 红绿灯高 | 灯顶距 | **灯中心** | 侧栏 view 顶距 | **内容区 view 顶距** |
|---|---|---|---|---|---|
| 有 `NSToolbar`（`.unified`） | 14.0pt | 19.0pt | **26.0pt** | 8.0pt | 0.0pt |
| 无 `NSToolbar` | 14.0pt | 9.0pt | **16.0pt** | **32.0pt** | 0.0pt |

**三条结论**

1. **内容区 view 顶距恒为 0pt**（两种配置都是）—— `fullSizeContentView` 下内容区**铺满整窗**，
   头部带从 y=0 开始、中心落在 26pt。所以「52pt 头部带中心 26pt」这个设计意图**本来就成立**，
   不需要任何额外布置。⚠️ 之前误以为「内容区在工具栏下方 52pt」—— 那是**视觉遮挡**（工具栏材质盖住顶部 52pt 的内容），不是布局。
2. **有工具栏时红绿灯中心 26pt，与头部带中心严格共线（差 0）**；无工具栏时掉到 16pt，**错位 10pt**。
   原因：AppKit 把红绿灯在其所在带内垂直居中 —— 带高 52pt（工具栏）⇒ 26pt；带高 28pt（裸标题栏）⇒ 16pt。
3. **`titlebarAppearsTransparent` 决定头部带能不能被看见**（这是本轮最重要的订正）：

   | 帧 | 配置 | 结果 |
   |---|---|---|
   | `A-opaque` | 工具栏 + **不透明**标题栏 | ❌ 头部带**被工具栏材质整条盖住**，画面上纯白 |
   | `B-transparent` | 工具栏 + **透明**标题栏 | ✅ 头部带完整可见，与红绿灯共线 —— **本稿采用** |
   | `C-titleshown` | 工具栏 + 透明 + **显示系统标题** | ❌ 系统标题与头部带文字**叠印糊在一起** |
   | `D-no-toolbar` | 无工具栏 + 透明 | ❌ 左上露 32pt 窗口底空带；红绿灯 16pt vs 头部带 26pt |

**⇒ 定案**：工具栏**保留**；`titlebarAppearsTransparent = true` 与 `titleVisibility = .hidden` **保留**；
退役的只剩 `enlargeTitleBar(in:)` / `alignTrafficLights(in:)` / `ContentView.titleBar` 三个。

**证据**：`.workbuddy/verify/v3-headband-verdict.png`（四帧对照）+ 四张单帧原图。

---

## 12. 资产版本纪律 + 跨版本圆角口径（含**侧栏**）（第 12 轮，2026-09-30）

> 触发（用户原话，两条）：
> ①「你是改了 v2 版本的 ds.css 了吗大哥？我建议不要改之前版本的，而是基于之前版本的来复制修改，
>   这样之后如果要回流版本也有依据。」
> ②「另外使用的系统 UI 组件的圆角也要根据实际系统版本来定义，例如 macOS 26 的窗口圆角比较大，
>   macOS 26 以下的系统版本窗口圆角比较小，这个你得查询下相应的官方文档来给开发工程师定义好。」

### 12.1 资产处置：老版本冻结，新版本「复制 → 修改」

**纪律：`Design/ui/v2/` 自 v3 起冻结，一个字节都不再改。**
v3 需要什么就从 v2 **复制一份**再改 ⇒ v3 与 v2 可逐行 diff、将来要回流版本有依据。

| 资产 | 处置 | 理由 |
|---|---|---|
| `assets/ds.css` | ✅ **复制到 `v3/assets/`** 后改 | 设计令牌会随代际演进（本轮已分叉 5 处，见文件抬头） |
| `assets/ds.js` | ✅ **复制到 `v3/assets/`** | 与 v2 逐字节相同；仅抬头改为 v3。留在 v3 是为了**资源根自洽**（`../assets/` 一条规则） |
| `assets/i18n-extra.json` | ❌ **不复制** | 设计稿专属键，与 v2 共享即可 |
| `assets/i18n.js` | ❌ **不复制，单源引用 v2** | ❗它是 `Tools/build_i18n.py` 的**生成物**，而**生成器输出路径写死 `v2/assets/`**；复制到 v3 必然**静默过期**（且其指纹守卫只盯 v2）⇒ 共享数据不做版本分叉 |
| `design-row-heights.json` | ❌ 不复制 | 量测中间产物，不是版本化资产 |

**分叉点必须登记。** `v3/assets/ds.css` 抬头逐条列出了「v3 相对 v2 的全部差异」——
**改 v3 的样式时，同时补抬头那条清单**，否则将来回流时不知道哪些是 v3 特有的。

> ⚠️ **v3 稿的资源引用是三个不同来源**（照抄 v2 的写法会 404）：
> ```html
> <link rel="stylesheet" href="../assets/ds.css">        <!-- v3 自己的 -->
> <script src="../assets/ds.js"></script>                 <!-- v3 自己的 -->
> <script src="../../v2/assets/i18n.js"></script>         <!-- 单源引 v2（生成物） -->
> ```

### 12.2 圆角实测（本机 macOS 26 · 2026-09-30）

#### 12.2.1 官方 API 可用性 —— 「让它自动跟系统代际变」这条路走不通

| API | 框架 | 可用版本 | 结论 |
|---|---|---|---|
| `ConcentricRectangle` / `containerShape(_:)` / `Edge.Corner.Style.concentric` | SwiftUI | **macOS 26.0+** | ❌ 我们最低 14 ⇒ 必然写 `if #available` ⇒ 违反 R5 |
| `NSView.LayoutRegion`（角适配布局区域） | AppKit | **macOS 26.0+** | ❌ 同上（**它是唯一专治「内容撞圆角」的 API**，见 §12.3 第 4 类） |
| `NSViewCornerConfiguration` / `NSViewCornerRadius.containerConcentric(_:)` | AppKit | **macOS 27.0+** | ❌ 同上，且 14–15 上是空转 |
| `NSGlassEffectView` | AppKit | **macOS 26.0+** | ❌ 同上 |
| 读窗口圆角（`NSThemeFrame.layer.cornerRadius`） | AppKit | — | ❌ **读不到**，恒 `0.0` / `mask = nil`（见 R6） |
| 读/设**侧栏**圆角 | AppKit | — | ❌ **不存在**：`NSSplitViewItem` 全部可设项里圆角相关的一个都没有（见 §12.2.2） |

**官方公式**（`concentric(minimum:)` Discussion 原文）：
> "When a corner is concentric to its container, the system calculates the corner radius to equal
> the container shape's corner radius **minus the distance between corners**."

即 `子圆角 = max(父圆角 − 内距, 最小圆角)`；距离远时算出 0 = 直角。

**官方「禁硬编码」明文**（Adopting Liquid Glass）：
> "…don't hard-code their layout metrics…"
> "…use rounded shapes that are concentric to their containers using these APIs:
> `rect(corners:isUniform:)`, `ConcentricRectangle`"

WWDC26-289《Modernize your AppKit app》：`cornerConfiguration` 覆写 +
`NSViewCornerRadius.containerConcentric`，且**必须设 minimum**；原话
"The closer the view is to the container's corner, the more its radius should match."

⇒ **同心圆角能力在我们支持的系统范围里根本不存在。** 14–15 上**没有任何 API 能拿到「父圆角」**。

#### 12.2.1.1 ⭐ 第 12 轮补查到的三条官方原文（直接决定侧栏怎么做）

**① 窗口圆角随窗口样式变 —— 不是我们的推测，是官方亲口说的**
（WWDC25-310《Build an AppKit app with the new design》，中文转写）：
> 「带有工具栏的窗口现在使用**更大的半径**……**只带有标题栏的窗口仍使用较小的圆角半径**。
> 半径会缩放以匹配工具栏的尺寸。」

⇒ 与 §12.2.2 实测的 **31.5 / 17.5** 两档一一对应。**「窗口圆角不是常数」从此有官方出处。**

**② 侧栏的形状（含圆角）由 AppKit 提供，而不是我们画**（同一场 WWDC25-310）：
> 「边栏显示为一块玻璃窗格，**悬浮在窗口内容上方**……当你创建具有边栏或检查器行为的
> `NSSplitViewItem` 时，**AppKit 会自动向它们提供相应的玻璃材质**。」

> ⛔ 同场次**明确否定**另一条路：「由于边栏现在显示在玻璃上，就不再需要旧版边栏材质。
> **如果你使用 `NSVisualEffectView` 来显示边栏内的旧版材质，将会导致玻璃材质无法透过。
> 你应该从视图层次中移除这些视觉效果视图。**」

⇒ **侧栏里不要放 `NSVisualEffectView`**（含 `.sidebar` 材质的那个）。
这一条**否掉了「自绘底色 + 自己加个材质去模拟」的整个思路** —— 侧栏那块的正解是**什么都不放**。

**③ 侧栏必须走 `NSSplitViewController`**（Apple 框架工程师，开发者论坛 thread 797087）：
> "To get the standard sidebar design, instead of directly building a `NSSplitView` you must use
> the higher-level `NSSplitViewController` and create a split item using the sidebar behavior."

⇒ 直接搭 `NSSplitView` + `NSOutlineView(.sourceList)` 拿到的是**老形态**（无圆角边框、自带 VisualEffect 底）。

#### 12.2.2 本机实测：窗口圆角**不是常数**，侧栏面板圆角**也不是**

方法：`screencapture -x -o -l<窗口ID>` 截**单窗口**（`-o` 去阴影），
窗口为纯色不透明 ⇒ **alpha 通道即窗口轮廓**，逐行取 50% 覆盖边界。
探针：`.build/probe/window_radius_spike/`（`main` / `concentric` / `single` / `read_radius` /
**`sidebar_variants`**）；`sidebar_variants` 自己读像素算半径并打印，**不做事后目视拟合**。

**（a）窗口圆角 —— 两档**

| 窗口配置 | 窗口圆角 |
|---|---|
| 仅标题栏窗口（无工具栏，800×552） | **17.5pt** |
| **统一工具栏窗口 `.unified`（800×604）** | **31.5pt** |
| 真机「系统设置」2x 截图（独立复核） | **31.5pt**（顶行 alpha 边界 = 63px） |

**（b）侧栏面板圆角 —— 五档**（第 12 轮补测；`FSCV` = `.fullSizeContentView`）

| 窗口配置 | 窗口圆角 | 侧栏面板圆角 | 面板内缩（左/上/下） |
|---|---|---|---|
| 统一工具栏 + FSCV + 全高 ← **本产品形态** | 31.5pt | **17.5pt** | 8 / 8 / 8 pt |
| 同上，但 `allowsFullHeightLayout = false` | 31.5pt | **0pt**（直角，浮岛消失） | 8 / 52 / 8 pt |
| 统一工具栏，无 FSCV（不延伸进标题栏） | 31.5pt | 17.5pt | 8 / 52 / 8 pt |
| 仅标题栏窗口 + FSCV | 17.5pt | **6.5pt** | 8 / 32 / 8 pt |
| 仅标题栏窗口，无 FSCV | 17.5pt | **6.5pt** | 8 / 32 / 8 pt |
| 真机「系统设置」2x 截图（独立复核） | 31.5pt（63px） | **17.5pt**（35px） | 7.5 / 8 / — pt |

> 读数用**两种独立算法**交叉验证（连续曲率下「半径」不是单值）：
> `Rv` = 逐行取面板左缘、到达最左那一行距面板顶的行数；
> `Rh` = 逐列取面板顶缘、到达最顶那一列距面板左的列数。
> 本产品形态档 **Rv = 17.5 / Rh = 17.0**；仅标题栏档 **Rv = Rh = 6.5**（两法一致才采信）。

**四条硬结论**：

1. ❗❗ **窗口圆角不是常数。** 两个窗口的宽度、构造、系统版本完全相同，**只差工具栏配置**，
   圆角就差 **14pt**（17.5 ↔ 31.5，已用单窗口复核排除截图污染）。
   ⇒ 任何「按系统给一个圆角数值」的做法都是错的；**连「26 = 某个数」也不成立**。
2. ❗❗ **侧栏面板圆角也不是常数。** 同机、同尺寸、同系统版本，**只差窗口配置**就够了：
   全高档 17.5pt、仅标题栏档 **6.5pt**（差 11pt）、关掉 `allowsFullHeightLayout` 直接 **0pt**。
   ⇒ 「按系统版本给侧栏一个圆角数值」**同样不成立**；它同时受 `①系统版本` 与
   `②窗口样式（有没有工具栏 / 有没有 FSCV / 是否全高）` 两个轴影响。
3. ⚠️ **面板圆角 ≠ 窗口圆角 − 内距**（同心公式在浮岛上不成立，**两档都不成立**）：
   `17.5 − 8 = 9.5 ≠ 6.5`；`31.5 − 8 = 23.5 ≠ 17.5`。
   ⇒ 浮岛圆角是**侧栏面板样式**自己的值，**不要反推、也不要试图「修正」它**。
4. ✅ **我们自绘底色不会丢圆角**：被测对象涂满不透明蓝，面板边界仍被容器裁成 17.5pt 圆角
   ⇒ **形状由容器裁切保证**；丢掉的是**材质**（那才是官方禁止自绘的理由，见 §12.2.1.1 ②）。

> ⚠️ **订正记录**：第 12 轮初测记的面板圆角是 `16.5pt`（unified）/ `5.5pt`（普通），
> 来自另一套阈值读法。第 12 轮复量用「同角点、双算法、进程内读像素」重测，得 **17.5 / 6.5**，
> 并由**真机「系统设置」2x 截图**（35px ÷ 2 = 17.5pt）独立复核。
> 两读数差 1pt 属**连续曲率的量测噪声**（见 §12.2.3），**别把噪声当规格差异**。
> 本文与 `v3/assets/ds.css` §Z、`screens/_10-combined-draft.html` 全线已按 **17.5 / 6.5** 更新。

#### 12.2.3 三个附带事实

- ❗ **窗口圆角运行时读不到（无公共 API）**：`win.contentView?.superview`（`NSThemeFrame`）
  `.layer?.cornerRadius = 0.0`、`layer?.mask = nil`、`maskedCorners` 全开；
  `NSWindow` 也没有任何圆角属性 ⇒ 圆角是**窗口服务器裁的**，不是 CALayer 圆角。见红线 R6。
- ❗ **侧栏圆角更没有任何 API**：逐条查过 `NSSplitViewItem` 的全部可设项
  （`behavior` / `collapsed` / `canCollapse` / `collapseBehavior` / `minimumThickness` /
  `maximumThickness` / `preferredThicknessFraction` / `holdingPriority` /
  `automaticMaximumThickness` / `springLoaded` / `canCollapseFromWindowResize` /
  `allowsFullHeightLayout` / `titlebarSeparatorStyle`）—— **圆角相关的一个都没有**。
  AppKit 全库的圆角入口只有四处（`NSBox.cornerRadius` 10.5+、`NSGlassEffectView.cornerRadius` 26+、
  `NSView.LayoutRegion` 26+、`NSViewCornerConfiguration` 27+），**没有一处是给侧栏用的**
  ⇒ **侧栏圆角 100% 系统所有。**
- ⚠️ **macOS 26 的圆角是连续曲率（squircle），不是正圆**：轮廓到圆心距离最多偏离名义半径
  **0.70pt**（偏「外」）⇒ 实测出的 17.5 / 31.5 / 6.5 是**名义值**，不能当圆的半径做几何推导
  （差 0.7pt 在 8pt 内缩这种量级上会被放大成误判）。

### 12.3 ⇒ 落地口径（**给实现工程师的最终定义**）

**分四类元素处置 —— 只有第 4 类要写代码。**

| # | 元素类别 | 我们做什么 | 依据 |
|---|---|---|---|
| 1 | **窗口圆角**（外壳本身） | ❗**什么都不做**。`NSWindow` 自己画。**禁止**把 `--r-window` 这类值写进实现 | 17.5 / 31.5 两档实测；官方原文；且读不到（R6） |
| 2 | **侧栏浮岛面板** | ❗**什么都不做**。`NSSplitViewItem(sidebarWithViewController:)` 自动给。**两个风险**：<br>① 自绘背景/圆角把它盖掉<br>② 往里塞 `NSVisualEffectView`（官方明令**从层次里移除**） | §11.4 / §12.2.1.1 ② / §12.2.2 |
| 3 | **系统控件**（按钮 / 开关 / 选择态 / 焦点环） | ❗**什么都不做**。我们只注入**颜色** | 官方「don't hard-code their layout metrics」 |
| 4 | **自绘元素**（卡片 / 徽章 / 行 / 图标底） | ✅ **唯一要写代码的一类**：<br>① 父容器**也是自绘** ⇒ `子圆角 = max(我们自己的父圆角 − 内距, 最小圆角)`<br>② 父容器是**系统画的**（窗口 / 面板） ⇒ **改为位置约束**：不贴角，内缩 ≥ 12pt | 官方公式；父圆角取**我们自己的**容器 ⇒ 14–15 上同样成立 |

**关键点：14–15 的窗口圆角与侧栏圆角数值，本产品其实用不到。**
四类里只有第 4 类需要数值，而那一类用的是「**我们自己的父圆角**」（L2 令牌，两代同一个值）。
**没有那些数，也不该有任何一行代码因此写不出来。**

> ⚠️ 第 4 类为什么不能直接用窗口圆角做同心减法？因为窗口圆角**读不到**（R6）、
> 且**不是常数**（12.2.2）—— 用它必然写死一个在某些窗口配置下就错的值。
> 侧栏圆角同理（§12.2.2 结论 2），而且要更小心：**它连一个可读 API 都没有**。
> 所以对「系统画的父容器」改用**位置约束**（不贴角），把不确定性交给留白。

#### 12.3.1 ❗ 既有代码里已有两处「给窗口写死圆角」——必须重新判定

规范不只约束新代码：**当前 `Sources/` 里已经有两处在做 §12.3 第 1 类禁止的事**。

| 位置 | 代码 | 处置 |
|---|---|---|
| `Sources/Views/ContentView.swift:227–234`（主窗口，经 `WindowAccessor`） | `window.contentView?.layer?.cornerRadius = DesignTokens.Radius.window`（**= 12**）+ `masksToBounds = true` | ❗**待判定**（见下） |
| `Sources/SafeOutApp/SafeOutApp.swift:2367–2369`（设置窗口） | 同上 | **随设置窗口退役一并删除** |

**为什么不能就这么留着**：`DesignTokens.Radius.window = 12`（`DesignTokens.swift:37`）与实测窗口圆角
（26 上 unified **31.5pt** / 仅标题栏 **17.5pt**，§12.2.2）**不是一个量级**。
代码注释给的理由是「不加的话窗口底角是直角」，即它是**为掩盖某个窗口配置不画圆角而写的补偿**。

- 若窗口服务器本来就在画圆角 ⇒ 这层 12pt 遮罩会**切出一个比窗口更小的圆**，26 上四角会露边；
- 若去掉后窗口底角真的变方 ⇒ 说明当前窗口配置让窗口服务器不画圆角
  （`.fullSizeContentView` + `transparentTitlebar` + `isOpaque = false` + `backgroundColor = .clear`）
  ⇒ **要改的是「让窗口服务器画」的配置，不是自己写死一个 12**。

**动作（一条也不能省）**：

1. 换成 `NSSplitViewController` 装配后，先**注释掉**这两处；
2. 开窗口截图量四角（`screencapture -x -o -l<窗口ID>`，2x ⇒ px ÷ 2 = pt）；
3. 还是圆的 ⇒ **永久删除**，并顺带退役 `DesignTokens.Radius.window` / `.settings`（唯一消费者就是这两处）；
   变方了 ⇒ 按上面第二条找配置，**不要退回写死 12**。

⚠️ **不要在没截图的情况下保留它，也不要直接删。** 两种直觉动作都可能是错的。

> `Radius.window` 另有 3 个消费者在 `SettingsView.swift`（`:192` 的 `.background(GlassSurface(cornerRadius:))`、
> `:193` 的 `.clipShape(RoundedRectangle(cornerRadius:))`、`:330` 的 `GlassSurface`）——
> 那几处属于 §12.3 **第 4 类（自绘元素）**，要按「我们自己的父圆角」**重新取值**，**不要跟着一起删**。

### 12.4 取证产物（第 12 轮）

| 文件 | 内容 |
|---|---|
| **`.workbuddy/verify/v3-radius-evidence.png`** | **圆角证据总图**：官方 API 可用性 + 实测四宫格 + 两条假设纠正 + 落地口径 |
| **`.workbuddy/verify/v3-sidebar-radius-evidence.png`** | **侧栏圆角证据图**（第 12 轮补测）：官方原文四条 + SDK 无 API 事实 + 五档实测表 + 角部对照 + 口径 |
| **`.workbuddy/verify/sb-z-{real,unified,plain,nofull}.png`** | **角部对照四片**（放大 7 倍、同角点位置）：真机 17.5 / unified 17.5 / 仅标题栏 6.5 / 非全高 0 |
| `.build/probe/window_radius_spike/sidebar_variants.swift` | **侧栏五档探针**：进程内读像素、`Rv`/`Rh` 双算法求半径、自检缺输出即报错 |
| `.build/probe/window_radius_spike/realprobe.swift` | 真机截图精测：窗口 alpha 边缘 + 面板左缘逐行曲线 + 红绿灯直径（定缩放） |
| `.build/probe/window_radius_spike/main.swift` | 单窗口圆角探针（alpha 通道法，可重跑） |
| `.build/probe/window_radius_spike/concentric.swift` | `NSSplitViewController` 浮岛探针，三变体（`notfull` / `fullheight` / `unified`） |
| `.build/probe/window_radius_spike/single.swift` | 单窗口复核 unified 的 31.5pt（排除两窗遮挡污染） |
| `.build/probe/window_radius_spike/read_radius.swift` | 证明窗口圆角**读不到**（R6 的证据） |
| `.workbuddy/verify/radius-crop-{syssettings,notfull,unified,v3draft}.png` | 上一版证据图里的四张角部裁片 |
| `.workbuddy/verify/v3-combined-{light,dark}.png` | v3 两帧（已按 §12.2 订正圆角，探针 `WINRADIUS` / `FLOAT` 断言 **31.5 / 17.5** 通过） |

> ⚠️ 14–15 的窗口圆角**本机测不到** ⇒ **别编数**。若真要，须在 14–15 机器上重跑同一套探针；
> 但按 §12.3，本产品**不需要**这个数。
