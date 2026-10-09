# v3 界面合并 · 开发交接单

> **这份单子是什么**：把设计稿的意图翻译成「实现侧**要做什么 / 不要做什么 / 怎么证明做对了**」。
> 稿子是给人看结果的，**不是给机器读的规格** —— 两者有几处**故意不一样**，不写明就会实现错。
>
> **本单只写当前口径，不含演进史。** 要追「哪一轮改了什么、为什么改」，看 `DESIGN-SPEC.md` §7；
> 要追**实测数据与官方出处**，看 `DESIGN-SPEC.md` §5 / §11 / §12 和 `assets/ds.css` §Z。
>
> | | |
> |---|---|
> | **交付对象** | 实现工程师 |
> | **深度规范** | `Design/ui/v3/DESIGN-SPEC.md`（分层归属、红线、逐组件处置、全部实测与官方原文） |
> | **设计稿** | `Design/ui/v3/screens/_10-combined-draft.html`（`_` 前缀 = 探索稿，**尚未升格**为正式页面） |
> | **设计令牌** | `Design/ui/v3/assets/ds.css`（**看 v3 这份，别看 v2**；末尾 §Z = 圆角口径全文） |
> | **部署目标** | **macOS 14**（`Package.swift` 是唯一真相，有守卫盯着） |
> | **仓库铁律** | 构建零警告 + 全量测试全绿；`Sources/` 改动后要额外跑 CI 级 `-warnings-as-errors` |

---

## 目录

- 0 一页速览（先读这个）
- 1 目标形态
- 2 代码现状 → 目标差距
- 3 实现清单（按工作流）
- 4 红线（违反不会报错，只会让界面变旧或割裂）
- 5 必须重算的尺寸预算
- 6 落地顺序
- 7 验收：怎么证明做对了
- 8 剩余待确认（**无阻塞项**）
- 附 A 文件地图
- 附 B 取证产物（可重跑）
- 附 C 已作废的旧结论（别照着实现）

---

## 0 一页速览（先读这个）

**这是一次形态变更，不是调样式。** 主窗口从「单栏列表 + 独立设置窗口」变成
「**单侧栏导航 + 详情区**」；原设置窗口的内容整体搬进详情区。窗口尺寸**不变**（800×520）。

### ① 下面五件事**你一行外观代码都不用写** —— 全归系统

| 元素 | 谁给 |
|---|---|
| **窗口圆角** | `NSWindow` / 窗口服务器（26 上实测 31.5pt 或 17.5pt，**随窗口配置变**） |
| **侧栏浮岛**（四边内缩 8pt + 圆角 + 玻璃材质） | `NSSplitViewItem(sidebarWithViewController:)` 自动 |
| **侧栏选中态** | `List(selection:)` + `.listStyle(.sidebar)` |
| **按钮形状 / 玻璃 / hover / 焦点环** | 系统按钮样式（我们只给**颜色**） |
| **开关样式** | `Toggle` + `.toggleStyle(.switch)` |

⚠️ **唯一的风险不是「没做」，而是「做多了把它盖掉」** —— 一旦给这些元素自绘背景、圆角或材质，
系统的效果就没了。见 §4 红线。

> ⚠️ **第 13 轮补（2026-10-01）：侧栏「行高 / 行距」是上表唯一的例外，已自定。**
> 实测侧栏面板 504pt 高而六项内容只占 209.5pt ⇒ **底部空白占 47%**（用户反馈
> 「左栏选择项分布不均、下边空了一大块」）。现按
> `DesignTokens.Size.sidebarRowVerticalInset = 14` 把行高撑到 43.5pt、分组间距加到约 28pt，
> 空白降到 **31%**。实现上**只有 `listRowInsets` 有效** ——
> 行内容 `.padding(.vertical,)` 与 `environment(\.defaultMinListRowHeight,)` 实测**都撑不动**
> sidebar 样式的行。选中态 / hover / 圆角 / 方向键 / 无障碍语义**仍然全部归系统**。
> 检查项见 `DESIGN-SPEC.md` §10.4，实测数据见 `DesignTokens` 里那个常量的注释。

### ② 你真正要写的只有这些

1. **窗口装配**换成 `NSSplitViewController`（sidebar item + detail item），工具栏只留刷新 —— §3.1
2. **设置内容搬进详情区**，拆成五个分类页；`Toggle` 换完要**保住「整行可点」** —— §3.4
3. **自绘元素的圆角**按「我们自己的父圆角」算 —— §3.7
4. **退役**：自绘 52pt 头部五件套、`SettingsWindow`、`SettingsSidebarItem`、`SettingsSwitch`、`ActionButton` 的自绘部分
5. **重算尺寸预算**（内容区由 480 变宽到 560）—— §5

### ③ 两条**本轮新查到、且必须先处理**的既有代码

| # | 事实 | 为什么必须处理 |
|---|---|---|
| **A** | `DesignTokens.Radius.window = 12`，被 **3 个文件 5 处**消费；其中两处在给 `window.contentView?.layer?.cornerRadius` 赋值（主窗口 `ContentView.swift:227`、设置窗口 `SafeOutApp.swift:2368`） | 12 与真实窗口圆角（31.5 / 17.5）**不是一个量级**。这层遮罩会把内容切出一个**比窗口更小的圆**，26 上四角可能露边。**必须重新判定**，见 §3.7.3 |
| **B** | 设计规范与旧文档里写的**最低系统是 macOS 14，不是 13** | 已全线订正（`Package.swift` 是唯一真相）。本单所有结论按 **14** 成立 |

### ④ 动工前的确认项 —— **已全部定案，可直接开工**

**工具栏必须留着，刷新按钮就放工具栏尾端。** 标题移出、折叠钮删掉之后工具栏里确实只剩它一个按钮，
但「一条带子上只有一个按钮」**不等于**「可以把这条带子删掉」：

- 头部带与工具栏是**同一条 52pt 水平带**（都占 y ∈ [0, 52]）⇒ 那条带**本来就是满的**（§3.1.1 有截图）
- 删掉工具栏会让红绿灯从 26pt 掉到 **16pt**、侧栏浮岛从 8pt 掉到 **32pt**、窗口左上露出一段空带，
  且拖拽与双击缩放一并丢失 —— 四项代价、有两项**手工补不齐**（§3.1.1 有实测表）

> ⚠️ **顺带一条最容易误删的**：`titlebarAppearsTransparent = true` 与 `titleVisibility = .hidden`
> **必须保留**（它们曾被误列为「退役」）。删了前者 ⇒ 工具栏材质把头部带整条盖住；
> 删了后者 ⇒ 系统标题与头部带文字叠印。见 §3.2 的四帧对照。

⇒ **`makeMainWindow()` 按 §3.1 装配，不需要等确认了。**

---

## 1 目标形态

```
┌────────────────────────────────────────────────────┐  ← 窗口顶（红绿灯浮在左栏浮岛上）
│ ●●●  ┏━━━━━━━━━━━┓                                │
│      ┃ 外置磁盘   ┃  外置磁盘  3 块          [⟳]   │  ← 标题在内容区顶部
│      ┃ ─────────  ┃┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│
│      ┃ 设置       ┃  ① Samsung T7   [关闭并推出]   │
│      ┃   通用     ┃  ② WD Blue           [推出]   │
│      ┃   外观     ┃  ③ Backup SSD        [推出]   │
│      ┃   更新     ┃                               │
│      ┃   诊断     ┃                               │
│      ┃   关于     ┃                               │
│      ┗━━━━━━━━━━━┛                                │
└────────────────────────────────────────────────────┘
      800 × 520（沿用 DesignTokens.Size.mainWindow，不改）
      ┏━┓ = 左栏**四边内缩 8pt 的圆角浮岛**（系统自动给，见 §3.3）
      虚线 = 面板右缘与内容区**无缝隙**（内容区左缘 = 8 + 200 = 208pt）
```

- **左栏是浮岛、内容区贴边** —— 这是 `NSSplitViewController` 在 26 上的默认形态，**不是我们画的**。
- **红绿灯浮在浮岛上**（`allowsFullHeightLayout = true`）—— 与「系统设置」同形。
- **侧栏 200pt**：第一项「外置磁盘」（应用主角），其下「设置」分组放五个分类。
- **详情区随选中切换**：选中「外置磁盘」= 现有磁盘列表；选中某个设置分类 = 该分类的设置内容。
- ~~「完成」按钮~~ **退役**（§3.4）；~~折叠钮~~ **退役**（§3.1）。

---

## 2 代码现状 → 目标差距

| 现在（代码） | v3 目标 | 影响面 |
|---|---|---|
| 主窗口是 `NSHostingController(rootView: ContentView())` 直接挂到 window | 换成 `NSSplitViewController`：`sidebarWithViewController` + 详情 item | `AppDelegate.makeMainWindow()`（`SafeOutApp.swift:1912`）装配方式重写 |
| 窗口用**自绘 52pt 标题栏** + `titlebarAppearsTransparent = true` + `titleVisibility = .hidden`；`enlargeTitleBar(in:)` 撑到 52、`alignTrafficLights(in:)` 挪红绿灯 | **整体退役**，改真 `NSToolbar`（§3.2） | 上述 4 个机关 + `--preview-main-window-keys` 自检 + `MainWindowTests` 相关断言 |
| **窗口没有 `NSToolbar`**（全仓 `Sources/` 搜不到 `NSToolbar`） | 新增 `NSToolbar`（unified），里面**只放刷新一个 item** | 新增 |
| 设置 = **独立窗口** `SettingsWindow`（720×440，右上「完成」） | 设置内容进主窗口详情区；独立窗口退役 | `SettingsWindow.swift`(79 行)、`AppDelegate.showSettings()`(2288)、`AppDelegate.makeSettingsWindow()`(2323)、`WindowSelfCheck` 里校验设置窗口尺寸的断言 |
| 点「设置」→ 开独立窗口 | 改为「显示主窗口 + 选中设置·通用分类」 | `ContentView.openSettings()`（`ContentView.swift:488`） |
| 菜单栏面板「设置…」⌘, → 同一个入口 | **⌘, 必须保留**（macOS 惯例）⇒ 同上，定位到**通用** | `MenuPopoverView` 的 `onOpenSettings` |
| `SettingsView` 内含**自绘左栏** `SettingsSidebarItem`（`accent` 实底 + 6pt 圆角）+ 右栏 `SettingsPanel` | 左栏**退役**并入主窗口侧栏；右栏内容拆成详情区各分类 | `SettingsView.swift:598`（该文件 2302 行，需拆） |
| `SettingsSwitch` 是**纯自绘**（`Capsule` + `Circle` + 阴影） | 交还 `Toggle` + `.toggleStyle(.switch)` | `SettingsView.swift:2272`；**「整行可点」要一起处理**（§3.4） |
| `ActionButton` 是**纯自绘**（`.buttonStyle(.plain)` + 自绘底 + `strokeBorder`） | 交还系统按钮样式（§3.5） | `DesignSystemComponents.swift:494` |
| 左栏规格：`settingsSidebarWidth=200` / `ItemHeight=28` / `ItemIcon=15` / `ItemGap=9` / `ItemSpacing=1` / `PaddingH=10` | 交还系统后**全部作废** | `DesignTokens.swift:296–306` |
| `contentView.layer.cornerRadius = Radius.window`（=12）设了两处 | ❗**重新判定**，见 §3.7.3 | `ContentView.swift:227`、`SafeOutApp.swift:2367` |

⚠️ **`SettingsView.swift` 约 594 行有一条注释是错的**：
写着「选中态 = 强调色实底 + 白字（macOS 侧栏惯例，**Finder 与系统设置都这样**）」。
这句话在 macOS 26 上**不成立** —— 实测系统设置的侧栏选中态是 `#dddcdb` **中性灰胶囊**。
别被这条注释带偏，它正是要被退役的那段代码。

---

## 3 实现清单（按工作流）

每一小节统一三段：**做什么 / ⛔ 别做什么 / 判据**。

### 3.1 窗口装配：`NSSplitViewController` + 工具栏

**做什么**

```swift
let split = NSSplitViewController()
let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)   // ← 关键：用 sidebar behavior
sidebar.minimumThickness = 200
sidebar.maximumThickness = 200   // 锁死 ⇒ 用户拖不动
sidebar.canCollapse = false      // 折叠钮已删，折叠能力一并关掉

let detail = NSSplitViewItem(viewController: detailVC)
split.addSplitViewItem(sidebar)
split.addSplitViewItem(detail)

window.contentViewController = split
window.styleMask.insert(.fullSizeContentView)   // ← 必需，见 §3.3
```

工具栏（若保留）：`NSToolbar` + `toolbarStyle = .unified`，项序 `[.flexibleSpace, refresh]`。

**⛔ 别做什么**

- ⛔ **不要自己搭 `NSSplitView` + `NSOutlineView(.sourceList)`** —— 那样拿到的是**老形态**（贴边通高、无浮岛）。
  官方框架工程师原话：要拿到标准侧栏外观，必须用 `NSSplitViewController` + sidebar behavior 的 split item。
- ⛔ **不要**用 macOS 26 才有的 `NSToolbarItem.style` / `.backgroundTintColor`（见 §4.1）。
- ⛔ **不要**手算 top / padding 去对齐标题与红绿灯（见 §3.2）。

**判据**：26 上侧栏是**四边内缩的圆角面板**；14–15 上贴边 —— **两边都对**。
宽度拖不动；方向键能上下移动；VoiceOver 报出选中项。

> 工具栏高 **52pt**、item 高 **36pt**、垂直中心 **26pt**（实测）。
> ⚠️ `NSToolbarItem` **没有** `subtitle` 属性（AppKit 只有 `title`，10.15+）。
> 刷新按钮：普通 `NSToolbarItem` + `image`（`NSImage(systemSymbolName: "arrow.clockwise")`）+ `isBordered = true`。

#### 3.1.1 刷新按钮放哪 —— 「工具栏只剩一个按钮」这个顾虑不成立（已定案：**保留工具栏**）

**定案：保留 `NSToolbar`，刷新按钮就是工具栏尾端那一个 item。**
它不需要另外找地方 —— 因为**那条带子并不空**，只是空着的那段被我们自己的头部带填满了。

实测四帧（`.workbuddy/verify/v3-headband-B-band-transparent.png`）：**头部带与工具栏是同一条水平带**
（都占窗口 y ∈ [0, 52]），头部带在内容区那 592pt 宽里从 0pt 铺满 ⇒ 视觉上是
「左侧浮岛 + 右侧一整条头部带」，「空白」根本不存在，刷新按钮只是坐在这条带的最右端。

去掉工具栏则要自己补四件事，且其中一件**补不齐**：

| 去掉工具栏后 | 实测结果 | 能否手工补 |
|---|---|---|
| 红绿灯垂直中心 | 26pt → **16pt**（回落进 28pt 标题栏居中） | ❌ 红绿灯位置由窗口服务器/`NSTitlebarView` 决定，读不到也改不动（`NSThemeFrame.layer.cornerRadius` 同理读不到） |
| 侧栏浮岛上内缩 | 8pt → **32pt**（窗口左上露出 32pt 的窗口底空带） | ❌ 由 AppKit 按「有无工具栏」决定 |
| 顶部左右对齐 | 左浮岛顶 32pt、右头部带顶 0pt ⇒ **横向割裂** | ❌ 同上 |
| 拖拽区 / 双击标题栏缩放 | 没有了（工具栏区域是系统的天然拖拽区） | ⚠️ 需自己接 `isMovableByWindowBackground` / `performZoom`，且**双击缩放的行为细节与系统不一致** |

⇒ **`NSToolbar` 在这里不是「装按钮的容器」，是「提供 52pt 顶部安全带 + 让头部带透出来 + 拖拽 + 红绿灯居中」的基础设施。**
按钮数量（1 个还是 5 个）与该不该保留工具栏**无关**。

**判据**：截图里能同时看到三条基线共线 —— 红绿灯中心 26pt、头部带文字中心 26pt、刷新按钮中心 26pt。
且窗口顶部**没有**任何一段露出「比头部带更低的空带」。

> ⚠️ 若将来硬要去掉工具栏（比如产品决定窗口不再需要拖动），必须同步接受上表四行代价，
> 并把头部带高度从 52pt 改成 **32pt**（否则它与红绿灯中心差 10pt）。
> **不要**用「给内容区补 52pt 顶部 padding」这种办法去凑 —— 那只是把错位藏起来，红绿灯该在 16pt 还是 16pt。

---

### 3.2 头部与标题：自绘五件套退役

**做什么** —— 标题回到**内容区自己的头部**（`.sdetail__head` 形态，高 52pt）。

| 位置 | 元素 | 谁画 | 垂直中心 |
|---|---|---|---|
| 窗口左上 | 红绿灯 | 系统（浮在左栏浮岛上） | 26pt |
| 内容区顶部那一条（52pt） | 「外置磁盘 / 3 块」 | **我们** | 26pt |
| 窗口右上 | 刷新按钮 | 系统 `NSToolbar` 尾端 item | 26pt |

**三个 26pt 是实测值** ⇒ 天然同一条水平基线。head 里 `align-items: center`、工具栏项由系统居中，
**结果自动一致 —— 你不需要算任何 padding。**

同时**退役**这三个「在没有工具栏的年代伪造头部」的机关（现在是净减）：

| 机关 | 处置 | 为什么 |
|---|---|---|
| `enlargeTitleBar(in:)`（手工把标题栏撑到 52pt） | **退役** | 高度由工具栏给 |
| `alignTrafficLights(in:)`（手工挪红绿灯） | **退役** | 系统自动把它居中到 26pt |
| `ContentView` 里的 `titleBar` 自绘视图 | **退役** | 位置由内容区头部带接管 |

> ⚠️ **但这三条必须留着，一条都不能删。** 它们看着像「旧机关的残留」，实际是**头部带能不能被看见**的前提。
> 四帧对照实测（`.build/probe/window_radius_spike/nobar.swift` → `.workbuddy/verify/v3-headband-*.png`）：
>
> | 配置 | 处置 | 删掉的后果（实测） |
> |---|---|---|
> | `.fullSizeContentView` | **保留** | 内容区视图顶不再落在 0pt ⇒ 头部带整条下移 |
> | `titlebarAppearsTransparent = true` | **保留** | **工具栏材质把内容区头部带整条盖住** ⇒ 代码里"明明写了"、画面上白茫茫一片（帧 `A-opaque`） |
> | `titleVisibility = .hidden` | **保留** | 系统窗口标题与头部带文字**叠印糊在一起**（帧 `C-titleshown`） |
>
> 这三条**不是**「伪造头部」的手段，而是「让工具栏那条 52pt 带让位给内容区」的手段。
> 退役表里原先误列了前两条，已订正。

**⛔ 别做什么**：**不要**手算 padding 去凑基线（会错）；**不要**改 head 的 52pt（它是实测值，决定标题与红绿灯共线）。

**判据**：标题在**内容区顶部**、不在红绿灯旁；切换分类时跟着变；三者垂直中心一致。

---

### 3.3 侧栏：交还系统（浮岛 + 材质 + 宽度 + 选中态）

**⚠️ 这一块你不用写任何外观代码。** 实测证明（`.build/probe/sidebar_float_spike/`）：
`NSSplitViewItem(sidebarWithViewController:)` 在 macOS 26 上**本来就把侧栏渲染成四边内缩的圆角面板**。

| 量 | 实测值 |
|---|---|
| 面板左 / 上 / 下内缩 | **8pt** |
| 面板**本体**宽 | **200pt** |
| 内容区左缘 | **208pt**（= 8 + 200） |
| 面板圆角 | **17.5pt**（不是常数，随窗口配置变 —— 见 §3.7） |
| 面板右缘与内容区 | **无缝隙** |
| 内容区 | **贴边，不是浮岛**（不要给它也套圆角） |

**选中态走系统列表样式**：

```swift
List(selection: $selection) { ... }
    .listStyle(.sidebar)
```

**同一份代码在两代上的表现（都对，都不是 bug）**：

| | macOS 26 | macOS 14–15 |
|---|---|---|
| 选中态 | 中性灰胶囊 + 深色字 | **用户强调色实底 + 白字** |

⚠️ **在 14–15 上看到蓝色实底，不要当成「没改干净」去改代码** —— 那正是交还系统的意义。

**⛔ 别做什么（本节重点）**

- ⛔ **不要给侧栏加任何自定义背景色或圆角**（包括从稿子抄 `--bg-sunken`、`border-radius`，
  或在 SwiftUI 里包一层 `.background(...)`）—— 会把系统浮岛盖掉。
- ⛔ **侧栏视图层次里不要放 `NSVisualEffectView`**（含 `material: .sidebar` 那版）。
  官方明文：「如果你使用 `NSVisualEffectView` 来显示边栏内的旧版材质，将会导致玻璃材质无法透过。
  **你应该从视图层次中移除这些视觉效果视图。**」
  ⚠️ 这条**只针对侧栏内部**：窗口底 / popover 底的 `NSVisualEffectView`（`GlassViews.swift`）**照旧保留，勿改**。
- ⛔ **不要把 `allowsFullHeightLayout` 设成 `false`** —— 实测会让浮岛**整个消失**（圆角 0、上内缩 52pt）。
  这个属性只在样式掩码带 `.fullSizeContentView` 时生效。

**✅ 一条让你安心的实测**：**自绘底色不会丢圆角** —— 给侧栏内容涂满不透明色，容器仍把它裁成 17.5pt 圆角
⇒ **形状由容器裁切保证**，丢的是**材质**。那才是官方禁止自绘的理由。

**判据**：侧栏内部 `grep` 不到挂在侧栏视图上的 `NSVisualEffectView`；
26 上看到方角或贴边 ⇒ 先查上面那两条（`allowsFullHeightLayout` / `.fullSizeContentView`）。

> ✅ **历史疑问已查清，别再当 bug**：量到「设 200、渲染 208」不是 bug ——
> 系统把 200 当作**面板本体**宽度，再整体内缩 8pt ⇒ 外沿落在 8→208pt。
> **照写 200 即可，不要为了凑 208 改数字，也不要写补偿代码。**

---

### 3.4 设置内容搬进详情区（含「整行可点」）

**做什么**

1. `SettingsView` 的右栏内容按分类拆成五个详情页（通用 / 外观 / 更新 / 诊断 / 关于）。
2. **「完成」按钮删除** —— v3 里设置是主窗口右栏的常驻面板，不存在「完成」这个概念。
3. 三个入口（`ContentView` 齿轮按钮 / `⌘,` / popover 的「设置…」）统一为
   「**显示主窗口 + 选中设置·通用**」。

**❗「整行可点」必须保住**（本次最容易做丢的一条）

背景：为了让「整行可点」，现在用自绘的 `SettingsLineButton` 包住整行
（只做 38×22 的开关本体**容易点空**，会被当成「没反应」）。交还 `Toggle` 后**必须同时保住这个既有约定**，
否则是功能回退。

正确做法是把整行做成 `Toggle` 的 **label**：

```swift
Toggle(isOn: $value) {
    VStack(alignment: .leading) {
        Text(title)
        if let desc { Text(desc).font(.caption).foregroundStyle(.secondary) }
    }
}
.toggleStyle(.switch)
```

macOS 上 `Toggle` 的 label 区域**是可点的**，整行自然可点 —— **不需要**再包一层自绘手势（那会退回自绘老路）。

**⛔ 别做什么**：不要「能点但点了没反应」。既有约定是**控件不可用优先靠结构实现** ——
`onTap == nil` 时**不包**可点容器，而不是允许点击后再弹错。
（同屏出现「条件未满足」的警告却又允许操作，用户会直接判成 bug。）

**判据**：英文（最坏语言）下**整个行**（含文字区）都能点；开关在两行文字里垂直居中。

⚠️ **本机测不到 14**：`Toggle` 的 label 可点性在**部署目标 macOS 14** 上的表现，
在本机（只能跑 26）**无法验证** ⇒ **放到验收阶段验**（§7 验收表已列「整行可点仍然成立」这一条）。
若在 14 上 label 不可点，兜底是给行加 `contentShape(Rectangle())` —— **优先用系统行为**。

---

### 3.5 按钮：交还系统

**映射表**（真机渲染图：`.workbuddy/verify/v3-system-buttons-{light,dark}.png`）：

| 我们的变体 | 系统样式 | 颜色（唯一由我们给的） |
|---|---|---|
| `primary`（推出） | `.buttonStyle(.borderedProminent)` | `.tint(品牌强调色)` |
| `danger`（关闭并推出） | `.buttonStyle(.borderedProminent)` | `.tint(.red)` |
| `outline`（取消） | `.buttonStyle(.bordered)` | 默认 |
| `neutral`（稍后） | `.buttonStyle(.bordered)` | 默认 |
| `ghost`（了解更多） | `.buttonStyle(.borderless)` | 默认 |

⇒ 形状 / 圆角 / 玻璃 / hover / 按下反馈 / 焦点环 **全部由系统给**：
macOS 26 = 全胶囊 + Liquid Glass；14–15 = 传统圆角矩形。**同一份代码系统自己切。**

**⚠️ 尺寸会变小 —— 实测量 `NSHostingView.fittingSize`**：

| | 我们现在的值 | 系统值 | 差值 |
|---|---|---|---|
| medium（磁盘行内的「推出」） | **30** | `.controlSize(.large)` = **28** | −2 |
| small（`.btn--sm`） | **26** | `.controlSize(.regular)` = **24** | −2 |
| ghost（纯文字） | — | `.borderless` = **16** | — |

⇒ **磁盘行高、行内按钮高度、以及依赖它们的布局预算要重量**，别沿用 `DesignTokens.Size` 里的旧值。

**⛔ 别做什么**：`ButtonVariant` / `ButtonSize` 两个枚举**可以保留**（调用点不用全改），
但要改成「到系统样式的**映射**」，**不要再自绘底色与描边**。`HoverBackground` 若只服务按钮，可一并退役。

---

### 3.6 材质、卡片底色与颜色

| 稿子里画的 | 能不能抄 | 正确做法 |
|---|---|---|
| `--bg-glass` / `--bg-glass-thick`（**窗口底**） | ❌ **禁止** | 走系统材质：`NSVisualEffectView` —— `Sources/Views/GlassViews.swift` **已合规，别改** |
| 同上（**侧栏底**） | ❌ **禁止** | ⛔ **连 `NSVisualEffectView` 都不要放**：侧栏玻璃由 `NSSplitViewItem(sidebar…)` 自带（§3.3） |
| `.scard` 白底 + 0.5px 描边 | ❌ | 26 实测系统分组卡片是 `#f7f7f7` 浅灰、**无描边**、卡间 10pt 白间隙。走系统分组样式 |
| 行分隔线 `--hairline` | ✅ 可以 | 与系统同量级，保留 |
| 侧栏底色 `--bg-sunken` | ❌ | 属于侧栏材质，归系统（**什么都不放**） |

**判定规则（一句话）**：这个视觉元素在**别的 App 里也能看到同样的东西**吗？
能 ⇒ 它是**系统惯例** ⇒ 交还系统，不要自绘；不能 ⇒ 是我们的**产品语言** ⇒ 照稿实现。

**❇️ 颜色是唯一由我们给的东西**（用户原话：「**除了颜色这些**，其他的最好都是使用适配的系统组件风格」）：

- **品牌强调色**（用户在设置里选的 `AccentColor`）→ 通过 `.tint()` 注入系统控件；
- **语义色**（琥珀 = 占用警告 / 红 = 危险 / 绿 = 安全）→ 徽章、状态行、容量条；
- **磁盘图标底色的区分色**。

⇒ 这些是 L2 内容层，**照稿实现**，与代际无关（26 与 14 同一个值）。

---

### 3.7 圆角：四类元素，只有一类要写代码

#### 3.7.1 先确认两条官方事实

| API | 所属 | 可用版本 | 结论 |
|---|---|---|---|
| `ConcentricRectangle` / `containerShape(_:)` / `Edge.Corner.Style.concentric` | SwiftUI | **macOS 26.0+** | ❌ 部署目标 14 ⇒ 必然写 `if #available` ⇒ 违反 R5 |
| `NSViewCornerConfiguration` / `NSViewCornerRadius.containerConcentric(_:)` | AppKit | **macOS 27.0+** | ❌ 同上，且 14–15 上是空转 |
| `NSGlassEffectView` | AppKit | **macOS 26.0+** | ❌ 同上 |
| **读**窗口圆角（`NSThemeFrame.layer.cornerRadius`） | AppKit | — | ❌ **读不到**，恒 `0.0` / `mask = nil`（见 R6） |

⇒ **「用 `ConcentricRectangle` 让控件自动跟系统圆角变」这条路用不了** —— 它在我们的系统范围里根本不存在。

**实测补充：圆角不是常数。**

| 窗口配置 | 窗口圆角 | 侧栏面板圆角 | 面板内缩（左/上/下） |
|---|---|---|---|
| **统一工具栏 + FSCV + 全高 ← 本产品形态** | **31.5pt** | **17.5pt** | 8 / 8 / 8 pt |
| 同上，但 `allowsFullHeightLayout = false` | 31.5pt | **0pt**（浮岛没了） | 8 / 52 / 8 pt |
| 普通标题栏窗口 | **17.5pt** | **6.5pt** | 8 / 32 / 8 pt |

⇒ ❗**「macOS 26 = 某个圆角值」这个前提本身就是错的**：同机、同尺寸，只差窗口配置，
**窗口**圆角差 14pt、**侧栏面板**圆角差 11pt。官方也明说
「带有工具栏的窗口现在使用**更大的半径**……只带有标题栏的窗口仍使用较小的圆角半径」。
⇒ ⚠️ 顺带否掉一条流行假设：**面板圆角 ≠ 窗口圆角 − 内距**
（`31.5 − 8 = 23.5 ≠ 17.5`；`17.5 − 8 = 9.5 ≠ 6.5`，**两档都不成立**）。

> 📌 为什么只能用实测：窗口圆角**没有公共 API 可读**（`NSThemeFrame.layer.cornerRadius` 恒 `0.0`、
> `mask = nil` ⇒ 圆角由**窗口服务器**裁切）；侧栏圆角更是**连 API 都没有**
> —— 证据是把 `NSSplitViewItem` 的**全部可设项列一遍**（`behavior` / `collapsed` / `canCollapse` /
> `collapseBehavior` / `minimumThickness` / `maximumThickness` / `preferredThicknessFraction` /
> `holdingPriority` / `automaticMaximumThickness` / `springLoaded` / `canCollapseFromWindowResize` /
> `allowsFullHeightLayout` / `titlebarSeparatorStyle`）—— **圆角相关的一个都没有**；
> 而 AppKit 全库的圆角入口只有四处（`NSBox.cornerRadius` 10.5+、`NSGlassEffectView.cornerRadius` 26+、
> `NSView.LayoutRegion` 26+、`NSViewCornerConfiguration` 27+），**没有一处是给侧栏用的**。
> **别去找、别反推。**

#### 3.7.2 口径：分四类，只有第 4 类要写代码

| # | 元素 | 你做什么 |
|---|---|---|
| 1 | **窗口圆角** | ❗**什么都不做**。`NSWindow` 自己画。**禁止**把任何圆角值写进实现 |
| 2 | **侧栏浮岛面板**（内缩 + 圆角 + 玻璃） | ❗**什么都不做**。系统自动给 |
| 3 | **系统控件**（按钮/开关/选择态/焦点环） | ❗**什么都不做**。只注入**颜色** |
| 4 | **自绘元素**（卡片/徽章/行/图标底） | ✅ **唯一要写代码的一类**（见下） |

**第 4 类的算法**：

```
父容器也是自绘（我们的卡片/面板）
  ⇒ 子圆角 = max(我们的父圆角 − 内距, 最小圆角)      ← 父圆角是 L2 令牌，两代同一个值

父容器是系统画的（窗口 / 侧栏浮岛）
  ⇒ 不做同心减法，改为「位置约束」：子元素不贴角，内缩 ≥ 12pt
```

**为什么对系统容器不能做减法**：窗口圆角**读不到**（R6）**且不是常数**（17.5 / 31.5 两档）
⇒ 任何减法都要写死一个在别的窗口配置下就错的值。

> ✅ **划重点**：**14–15 的窗口圆角数值，你这套代码根本用不到。**
> 四类里只有第 4 类需要数值，而那一类用的是「**我们自己的父圆角**」。
> **没有那个数，也不该有任何一行代码因此写不出来。**

#### 3.7.3 既有代码里两处在给 `contentView` 设 12pt 圆角 —— 必须重新判定

| 位置 | 代码 | 处置 |
|---|---|---|
| `ContentView.swift:227–234`（主窗口，经 `WindowAccessor`） | `contentView.layer.cornerRadius = DesignTokens.Radius.window`（**= 12**）+ `masksToBounds = true` | ❗**待判定，见下** |
| `SafeOutApp.swift:2367–2369`（设置窗口） | 同上 | **随设置窗口退役一起删** |

**为什么必须重新判定**：`Radius.window = 12` 与真实窗口圆角（26 上 unified **31.5pt** / 仅标题栏 **17.5pt**）
**不是一个量级**（代码注释里的理由是「不加的话窗口底角是直角」）。

- 若窗口服务器本来就在画圆角 ⇒ 这层 12pt 遮罩会**切出一个比窗口更小的圆**，26 上四角会露边；
- 若去掉后窗口底角真的变方 ⇒ 说明当前窗口配置（`.fullSizeContentView` + 透明标题栏 + `isOpaque = false`
  + `backgroundColor = .clear`）让窗口服务器不画圆角 —— **那时要改的是「让窗口服务器画」的配置，
  不是自己写死一个 12**（这正是 §3.7.2 的立场：窗口圆角归系统）。

**动作**：改成 `NSSplitViewController` 装配后，先**注释掉**这两处，开窗口截图量四角
（`screencapture -x -o -l<窗口ID>`，2x ⇒ px ÷ 2 = pt）；确认还是圆的就**永久删掉**，
并顺带退役 `DesignTokens.Radius.window` / `.settings`。
**不要在没截图的情况下保留它。**

> `Radius.window` 的另外 3 个消费者是 `SettingsView` 的 `GlassSurface` 与 `clipShape`
> （`.background(GlassSurface(cornerRadius:…))` / `.clipShape(RoundedRectangle(cornerRadius:…))`），
> 那两处要按「**第 4 类：父容器自绘**」重新取值，不要跟着一起删。

---

### 3.8 设计稿资产纪律：**v2 已冻结**

**`Design/ui/v2/` 自 v3 起冻结，一个字节都不再改**（含 `ds.css` / `DESIGN-SPEC.md`）。
v3 用**自己的一份**：

| 资源 | 位置 | 说明 |
|---|---|---|
| `ds.css` | `Design/ui/v3/assets/ds.css` | 从 v2 **复制**后改；抬头逐条登记了「v3 相对 v2 的全部差异」 |
| `ds.js` | `Design/ui/v3/assets/ds.js` | 从 v2 复制，逐字节相同（仅抬头改 v3） |
| `i18n.js` | ❗ **仍引 `Design/ui/v2/assets/i18n.js`** | **不复制**。它是 `Tools/build_i18n.py` 的**生成物**，生成器输出路径**写死 v2**；复制到 v3 必然**静默过期**，且其指纹守卫只盯 v2 ⇒ 共享数据不做版本分叉 |

**⚠️ `i18n.js` 不在 v3 目录下不是遗漏，是故意的；别"顺手补一份"。**

> 本条**只影响设计稿资产，不影响 `Sources/` 里的产品代码**。产品代码一行不用动。

---

## 4 红线（违反不会报错，只会让界面变旧或割裂）

| # | 禁止 | 为什么 |
|---|---|---|
| R1 | 用稿子的 `--bg-glass` 自绘**窗口/侧栏**底色 | 会盖住系统的 Liquid Glass |
| R2 | 给侧栏选中态写死颜色（包括稿子里的 `#dddcdb`） | 锁死在某一代；应走系统选择样式 |
| R3 | 给系统控件的尺寸/圆角/内边距写死 px | 系统换代时不会自动跟；**自绘元素的圆角按 §3.7.2 第 4 类算** |
| R4 | 自绘仿 Liquid Glass（渐变、模糊层、高光边） | 官方明确要求 sparingly；内容层不该出现玻璃 |
| R5 | 按系统版本写视觉分支 `if #available(macOS 26)` | 同一份代码应零分支，由系统消费版本差异 |
| R6 | 试图「**读**」窗口圆角再据此算布局（以为存在可读属性） | 实测读不到（恒 `0.0` / `mask = nil`，窗口服务器裁的），且随窗口配置变。**侧栏圆角更是连 API 都没有** |
| R7 | 在**侧栏内部**放 `NSVisualEffectView`（含 `material: .sidebar`） | 官方原话：会让玻璃无法透过，**应从视图层次里移除** |

### 4.1 一条容易「好心帮倒忙」的禁令

**不要用 macOS 26 的新 API 把自绘件「补」成新代际的样子。** 这些都是 **26.0+**：

| API | 最低版本 |
|---|---|
| `View.glassEffect(_:in:)` | macOS 26.0+ |
| `.buttonStyle(.glass)` / `.glassProminent` | macOS 26.0+ |
| `NSGlassEffectView` | macOS 26.0+ |
| `NSToolbarItem.style` / `.backgroundTintColor` | macOS 26.0+ |
| **`ConcentricRectangle` / `containerShape(_:)` / `.concentric`** | **macOS 26.0+**（⚠️ 它看起来**最像"该用的 API"**，其实**用不了**） |
| **`NSViewCornerConfiguration` / `NSViewCornerRadius`** | **macOS 27.0+** |

部署目标是 **macOS 14** ⇒ 用它们**必然**要写 `if #available(macOS 26)` ⇒ **直接违反 R5**，
而且在 14–15 上完全没有效果，等于为老系统写了一段死代码。

**⇒ 要两代都对，唯一的路是「用系统控件」，不是「用新 API 手工补」。**

---

## 5 必须重算的尺寸预算

|  | v2 独立设置窗口 | v3 详情区 |
|---|---|---|
| 总宽 | 720 | **800 − 200（侧栏）= 600** |
| 设置内容可用宽 | 480（720 − 200 左栏 − 20×2 内边距） | **560**（600 − 20×2 内边距） |
| 总高 | 440 | 520 |
| 工具栏 | 无（自绘头部 52 在窗口内） | **52**（系统给） |

**三件事必须重量**：

1. **设置面板高度**：内容区**变宽**（480 → 560）⇒ 说明文字**折行更少** ⇒ 行高更低 ⇒ 总高变化。
   现在 `DesignTokens.Size.settingsPanel = 720×440` 是按 v2 两栏形态量出来的，
   其推导写着「高度只由**最高的那一页**决定」「英文最坏 384.22 ⇒ 440 ⇒ 余量 55.78pt」。
   形态一变，**这条夹逼约束整个作废**。
2. **按钮尺寸**：见 §3.5（30→28、26→24）。
3. **磁盘行高**：行内按钮变小 ⇒ 行高可能跟着变。

**纪律（一步不能省）**

- **重量，不许手抄**：`Tools/measure_settings_split.py`（设计稿侧）+ `SettingsLayoutTests`（实现侧）**双测复量**。
- **判据永远是「最长的那门语言」**：只量中文会拿到偏小的数，按它定高会在英文下把最后一行推进 `overflow: hidden`
  —— 而「被裁掉」和「本来就没那么多内容」在渲染图上**长得一模一样**。

---

## 6 落地顺序

每一步都保持可运行（仓库铁律：构建零警告 + 全量测试全绿）。

1. **拆 `ContentView`**：把「导航侧栏」「磁盘详情区」「设置详情区」三块分开。
   现有的磁盘行、占用、刷新、FDA 横幅逻辑**整体搬进详情区，不重写**。
2. **窗口装配换成 `NSSplitViewController`**：sidebar item + detail item；
   `canCollapse = false`，`min/max` 锁宽 200。❗**侧栏的浮岛 / 圆角 / 材质一概不要自绘**（§3.3）。
3. **处理 `contentView` 圆角那两处**（§3.7.3）—— 截图判定，不要直接留、也不要直接删。
4. **上 `NSToolbar`**（unified）：项序 `[.flexibleSpace, refresh]`。
   ✅ §8.1 已定案：**保留工具栏**，刷新放尾端。
5. **退役自绘头部五件套**，以及为它们写的自检与断言（§3.2）。
6. **侧栏改用 `List(selection:)` + `.listStyle(.sidebar)`**；`SettingsSidebarItem` 退役。
7. **设置内容搬进详情区**：按分类拆成五个详情页；`SettingsSwitch` 换 `Toggle` + `.switch`
   （**注意保住整行可点**，§3.4）。
8. **按钮改系统样式**（§3.5）：`ActionButton` 内部换 `.bordered` 系列 + `.tint`，调用点尽量不动。
9. **入口改接**：齿轮按钮 / `⌘,` / popover 的「设置…」⇒ 统一为「显示主窗口 + 选中**设置·通用**」。
10. **退役 `SettingsWindow`** 及其自检/测试（**确认无其他复用者后再动** —— `KeySilentWindow` 是基类，
    主窗口可能也在用，那部分不受影响、别跟着删）。
11. **重算尺寸预算**（§5），同步更新 `DesignTokens` 与测试。
12. **走查两代**（§7）。

---

## 7 验收：怎么证明做对了

**不要**用「和设计稿长得像不像」当验收标准 —— 稿子是模拟值，长得像不代表对。

| 检查项 | 判据 |
|---|---|
| 两代行为 | 在 **macOS 26 与 14–15** 上各截一次图，比的是「**系统切换是否正常**」，不是「是否符合某套稿」 |
| 侧栏 | 方向键能上下移动；VoiceOver 报出选中项；把系统强调色改成石墨色，侧栏跟着变 |
| 侧栏浮岛 | 26 上侧栏是**四边内缩的圆角面板**（不是贴边通高）；14–15 上贴边 —— **两边都对**。若 26 上方角/贴边，先查 ① `allowsFullHeightLayout` 是否被设 `false` ② 样式掩码是否少了 `.fullSizeContentView` |
| 侧栏内部 | `grep -rn "NSVisualEffectView" Sources/` 的结果里，**没有一处挂在侧栏视图上**（窗口底 / popover 底的要留着） |
| 侧栏宽度 | 拖不动（已锁定）；面板**本体 200pt**、外沿 8→208pt |
| 基线 | 红绿灯 / 刷新 / 内容区标题**垂直中心一致**（实测基准 26pt） |
| 标题 | 在**内容区顶部**、不在红绿灯旁；切换分类时跟着变 |
| 材质 | 26 上窗口/侧栏是系统材质，**没有被我们盖一层白** |
| 按钮 | 五个变体可用；26 上是胶囊 + 玻璃，14–15 上是传统形状（**两边都对**） |
| 开关 | 系统样式；**整行可点仍然成立** |
| **圆角** | **窗口 / 浮岛 / 系统控件**：代码里搜不到写死的圆角值（含 §3.7.3 那两处）；**自绘元素**：圆角由「我们自己的父圆角」算出，且不贴系统容器角 |
| 高度 | 英文（最坏语言）下最后一行**没有被裁**；同时**不留大片空白**（两条都要） |
| 回归 | `./run.sh check` 全绿；改过 `Sources/` 后额外跑一次 CI 级的 `-warnings-as-errors` 构建 |

**截图与量测注意（都是踩过的坑）**

- **验证 UI 不必抢焦点**：`screencapture -x -o -l<窗口ID>`（ID 用 `Tools/probe/windowid.swift`）。
- 位图是 **2x ⇒ px ÷ 2 = pt**。
- 像素量测时**出图与量高必须钉在同一语言下**。
- ⚠️ **做对照图时，非激活窗口的强调色按钮会被系统去色**（实测：浅色窗口失焦后 primary 与 danger
  都变灰胶囊、彼此无法区分 —— 是一张**假图**）。对照截屏要**逐个设为 key window 再截**。

---

## 8 剩余待确认 —— **没有一条阻塞动工**

> **动工前没有需要你拍板的项了。** 下面分三块：已定案（照做，不必再问）／本机验不了但不阻塞／可选的后续动作。

### 8.1 已定案（照做，不必再问）

| # | 决定 | 出处 |
|---|---|---|
| 1 | **保留 `NSToolbar`**，刷新按钮坐工具栏**尾端**，不另找位置 | §3.1.1（去掉它的四项代价实测） |
| 2 | `titlebarAppearsTransparent` / `titleVisibility` **保留**（曾被误列为「退役」，实为必需） | §3.2 四帧对照 |
| 3 | **侧栏折叠能力不给**：`canCollapse = false`、200pt 锁死、**不加折叠按钮** | §3.1 / §3.3 |

### 8.2 本机验不了、但**不阻塞**的两处

1. ⚠️ **14–15 上侧栏长什么样 —— 未取证**（本机只能跑 26）。按官方表述推知是
   **贴边通高、无浮岛圆角**的老形态，但**没有在 14–15 机器上实测过**。
   **不阻塞动工**：按 §3.3 的口径，我们对侧栏圆角/材质**一行代码都不写**
   ⇒ 无论 14–15 长什么样，代码都不用改。
   若将来要写进规格数值，须在 14–15 上重跑 `.build/probe/window_radius_spike/sidebar_variants.swift`。
2. ⚠️ **`Toggle` 的 label 可点性在 macOS 14 上 —— 未实测**（本机 26）。
   这条**在验收时验，不在动工时卡着**：§7 验收表已列「开关：系统样式 + 整行可点仍然成立」。
   若在 14 上发现 label 不可点，兜底是给行加 `contentShape(Rectangle())` —— **优先用系统行为**（§3.4）。

### 8.3 可选的后续动作（不影响交付，随时可做）

**v3 稿要不要升格为正式页面**（进页面索引 + 补状态矩阵）？
—— 升格后才会被设计稿守卫扫描（`Design/ui/v2` 之外的目录目前**不被任何守卫扫描**，
所以 v3 现在怎么改都不会有测试拦你，这也意味着**它现在拦不住你**）。
⚠️ 附带后果：`v3/assets/ds.css` 抬头的「分叉点清单」目前**靠人工维护**；
升格（或补一条守卫扫描 v3）之后，才能变成「改了忘登记就报红」。
**在那之前，改 v3 的样式时请顺手补抬头那条清单。**

> ✅ **`Design/ui/v3/` 已随 v3 交接一并入库**（此前未被跟踪、没有版本历史）。
> **动工前的基线 = `7f7323d`**；之后每一步都能 `git diff 7f7323d` 对照与回退。

---

## 附 A 文件地图

**设计侧**

| 文件 | 作用 |
|---|---|
| `Design/ui/v3/screens/_10-combined-draft.html` | 探索稿（**两帧**；`_` 前缀 = 不算正式页面） |
| `Design/ui/v3/DESIGN-SPEC.md` | 代际归属规范（§2 分层、§3 红线、§10 逐组件处置、§11 工具栏与浮岛实测、§12 资产纪律与圆角口径） |
| **`Design/ui/v3/assets/ds.css`** | **v3 设计令牌（看这份，别看 v2）**；抬头 = 分叉点清单，末尾 **§Z = 圆角口径全文** |
| `Design/ui/v3/assets/ds.js` | v3 运行时（与 v2 逐字节相同） |
| `Design/ui/v2/assets/i18n.js` | 语言包，**v3 单源引用**（生成物，故意不复制） |
| `Design/ui/v2/*` | ⚠️ **自 v3 起冻结，不要再改**（含其 `DESIGN-SPEC.md` §8.152，部分内容已被本单取代） |

**实现侧（按改动量排序）**

| 文件 | 要动什么 |
|---|---|
| `Sources/Views/SettingsView.swift`（2302 行） | **拆**：左栏 `SettingsSidebarItem`(598) 退役、右栏拆五个详情页、`SettingsSwitch`(2272) 换 `Toggle` |
| `Sources/SafeOutApp/SafeOutApp.swift`（2392 行） | `AppDelegate.makeMainWindow()`(1912) 换装配、`showSettings()`(2288) 改入口、`makeSettingsWindow()`(2323) 退役、头部四机关退役 |
| `Sources/Views/ContentView.swift`（751 行） | 拆三块；`openSettings()`(488) 改入口；**`:227` 圆角遮罩待判定** |
| `Sources/Views/DesignSystemComponents.swift`（1028 行） | `ActionButton`(494) 改系统样式；`HoverBackground`(467) 视情况退役 |
| `Sources/Views/DesignTokens.swift` | `Size` 重算；`settingsSidebar*`(296–306) 作废；`Radius.window`/`.settings` 待退役 |
| `Sources/SafeOutApp/SettingsWindow.swift`（79 行） | 建议**整体退役** |
| `Sources/SafeOutApp/WindowSelfCheck.swift`（652 行） | 同步（含设置窗口尺寸校验） |
| `Sources/Views/GlassViews.swift` | ✅ **已合规，勿改** |
| `Sources/Views/MenuPopoverView.swift` | 「设置…」入口改接 |
| `Sources/SafeOutApp/MainMenu.swift` | **不用动**：折叠能力定为不给（§8.1）⇒ 不加 View 菜单的「隐藏侧栏」项 |

---

## 附 B 取证产物（可重跑）

**证据图**（`.workbuddy/verify/`）

| 文件 | 内容 |
|---|---|
| `v3-combined-light.png` / `-dark.png` | **稿子两帧的实际渲染**（主要验收图） |
| `v3-radius-evidence.png` | 圆角实测总图：官方 API 可用性 + 实测四宫格 + 两条假设纠正 + 落地口径 |
| `v3-sidebar-radius-evidence.png` | **侧栏**圆角：官方原文 + SDK 无 API 事实 + 五档实测 + 角部对照 |
| `sb-z-{real,unified,plain,nofull}.png` | 角部对照四片（放大 7 倍，看圆角差异最直观） |
| `v3-system-buttons-{light,dark}.png` | 五个按钮变体的真机渲染 |
| `v3-float-spike-{a,b}.png` | 侧栏浮岛形态 A/B 实测（b = 本稿采用的形态） |
| `v3-toolbar-spike-{v1..v4}.png` | 工具栏 4 变体实测（钮删后**仅作历史**） |
| `v3-headband-verdict.png` | **头部带四帧对照**（A 不透明标题栏 / B 透明 / C 显示标题 / D 无工具栏）—— 刷新按钮与「必须保留的三条配置」的判据 |
| `v3-headband-{A-opaque,B-transparent,C-titleshown,D-no-toolbar}.png` | 上图的四张单帧原图 |
| `syssettings-tahoe-real.png` | 真机「系统设置」截图（所有侧栏数值的**独立复核源**） |

**探针**（可重跑）

| 路径 | 内容 |
|---|---|
| `.build/probe/window_radius_spike/sidebar_variants.swift` | **侧栏五档探针**（自读像素、双算法、自检）—— 侧栏数值的取真值入口 |
| `.build/probe/window_radius_spike/nobar.swift` | **头部带 / 工具栏存废探针**：三条独立路径量红绿灯（公开 API `standardWindowButton`、像素法、pane view frame）+ 四变体截图 —— 刷新按钮落点与「必须保留的三条配置」的取真值入口 |
| `.build/probe/tools/cropstack.swift` | 顶部裁切拼接工具（多张窗口截图 → 纵向堆叠 + 放大），出对照图用 |
| `.build/probe/window_radius_spike/{main,concentric,single,read_radius,realprobe,scan}.swift` | 窗口圆角 / 浮岛 / 单窗复核 / 「读不到」证据 / 真机精测 / 扫描线与结构图 |
| `.build/probe/sidebar_float_spike/main.swift` | 浮岛形态 A/B 实测 |
| `.build/probe/button_system_spike/main.swift` | 系统按钮五变体 + 尺寸实测 |
| `.build/probe/toolbar_anatomy_spike/main.swift` | 工具栏 4 变体（**仅作历史**） |

---

## 附 C 已作废的旧结论（别照着实现）

仓库里/旧文档里可能还留着这些说法，**它们都已失效**：

| 旧结论 | 现状 |
|---|---|
| 最低系统 **macOS 13** | ❌ 实际是 **macOS 14**（`Package.swift` 是唯一真相，有守卫） |
| 「圆角用 `ConcentricRectangle` 同心计算」 | ❌ API 是 26.0+ / 27.0+，**用不了**；正解见 §3.7.2 |
| 「面板圆角 = 窗口圆角 − 内距」 | ❌ **两种配置下都不成立**（同心公式在浮岛上不适用） |
| 「macOS 26 的窗口圆角是某个固定值」 | ❌ **不是常数**（同机同配置差 14pt，官方也承认随样式变） |
| 侧栏面板圆角 **16.5pt / 5.5pt** | ❌ 复量订正为 **17.5pt / 6.5pt**（差 1pt 是连续曲率的量测噪声） |
| 「设 200 渲染 208」当成 bug | ❌ 不是 bug（208 = 含 8pt 内缩的**外沿**） |
| 标题走 `window.title` / `NSWindow.subtitle` 放进工具栏 | ❌ 已撤回 —— 标题归**内容区顶部** |
| 工具栏放「标题 + 折叠钮 + 刷新」三件事 | ❌ 只剩**刷新**；折叠钮已删、`sidebarTrackingSeparator` 不再适用 |
| `toggleSidebar` 标准项 / `sidebarTrackingSeparator` | ❌ 一并退役 |
| 「按钮保留自绘」（早前的结论） | ❌ **已改判为交还系统**（§3.5） |
| `SettingsView.swift:594` 注释「侧栏选中态 = 强调色实底 + 白字，Finder 与系统设置都这样」 | ❌ 26 上不成立（系统设置实测是 `#dddcdb` **中性灰胶囊**） |
| 稿子里的 `--bg-glass` / `--bg-sunken` / `--r-window: 12px` / `.scard` 白底 | ❌ 全是 **HTML 模拟值**，**禁止抄进实现** |
| 稿子里 `.win--v3 { border-radius: 31.5px }` / `.sside { border-radius: 17.5px }` | ❌ 同样是**模拟值**。注意单位陷阱：**同样的数字在真机上量到的是 pt**（窗口 31.5pt / 面板 17.5pt）。两者数值相同纯属巧合 —— **实现侧一个都不要抄**（窗口与侧栏的圆角都归系统，§3.7.2） |
| 「往侧栏加 `NSVisualEffectView(.sidebar)` 模拟材质」 | ❌ 官方明令**从视图层次里移除**（R7） |
| 在 26 上看到侧栏方角/贴边 ⇒ 判为「系统没给浮岛」 | ❌ 先查 `allowsFullHeightLayout` 与 `.fullSizeContentView`（两个陷阱见 §3.3） |
| 「`titlebarAppearsTransparent` / `titleVisibility` 属于伪造头部的旧机关，该退役」 | ❌ **彻底反了** —— 实测它们是头部带**可见**的前提。删前者 ⇒ 工具栏材质整条盖住头部带（帧 `A-opaque`）；删后者 ⇒ 系统标题与头部带文字叠印（帧 `C-titleshown`）。§3.2 |
| 「工具栏里只剩一个刷新按钮，所以工具栏可以省掉」 | ❌ 按钮个数与该不该留工具栏**无关**；工具栏提供 52pt 安全带 / 红绿灯居中 / 拖拽 / 双击缩放，删掉的四项代价见 §3.1.1 |
| 「无工具栏时红绿灯仍在 26pt，头部带 52pt 仍能共线」 | ❌ 无工具栏 ⇒ 红绿灯中心 **16pt**、侧栏浮岛顶 **32pt**，与头部带中心 26pt 错位 10pt（帧 `D-no-toolbar`） |
