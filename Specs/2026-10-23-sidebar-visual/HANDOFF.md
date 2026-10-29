# 侧栏视觉改造 · 交接文档

> 日期：2026-10-23　适用：SafeOut（macOS 纯菜单栏应用，SwiftPM + SwiftUI/AppKit）
> 本文只交接**本轮未完成的工作**；更早的「设置开关 + 强调色」两条修复已交付安装（见 §2）。

---

## 0. 一句话现状

用户在设置窗口的左侧菜单栏提出三条诉求：**① 行没有 hover 反馈；② 选中底色不等于强调色；③ 侧栏要四周圆角**。

后续进展（2026-10-28/29，详见 §9）：三条都已落地过，但 **③ 的「四周圆角浮岛」被用户当面撤销**
（原话：「把左侧菜单中的浮岛拿掉吧，不要了」）⇒ 侧栏背景已交还系统材质（方角、贴边、整面铺满）。
现在侧栏只剩 **行级皮** 是自绘的：hover 底、选中色、行色块四周的内缩与行间间隙。

---

## 1. 用户诉求（原文）

> 设置窗口，左侧菜单栏没有hover效果，另外选中后的颜色和选定的强调色也不一样，现在和强调色一样的只有switch，其他都不一样，然后把左侧菜单栏调整为像四周圆角

拆成三条验收：

| # | 诉求 | 状态 |
|---|---|---|
| 1 | 行 hover 反馈 | ✅ 生效（真机截图 + 像素采样，见 §9） |
| 2 | 选中色 = 强调色（orange 时橙底白字） | ✅ 已验证 |
| 3 | 侧栏整体四周圆角（浮岛） | ⛔ **已撤销** —— 用户 2026-10-28 明确不要浮岛，见 §9 |

---

## 2. 上一轮已交付（无需重做，仅供背景）

`Specs/2026-10-22-settings-switch-accent/`：

- **「推出时提醒占用」开关点击无反应** → 未授 FDA 时开关可点、点击弹引导，主按钮跳系统设置「完全磁盘访问权限」页。真机验证通过。
- **强调色不生效** → 加了 `AccentColor.appleAccentColorRawValue` + `AppSettings.syncAppleAccentColor()`（启动时 + 色板写入点各同步一次），同步到 per-app `AppleAccentColor` 偏好键。
- 604 条测试全绿；已安装 `/Applications/SafeOut.app`（签名 `SafeOut Dev Signing`）。

⚠️ **上一轮的机制边界已作废**：那条结论是「侧栏选中胶囊只能下次启动跟随强调色」。
**本轮实测推翻了它** —— macOS 27 上系统 sidebar 的选中胶囊是**中性灰**，写 `AppleAccentColor` 根本不改变胶囊颜色（详见 §5）。所以本轮改为**自绘行底**，颜色即时跟随，不再依赖重启。

---

## 3. 代码现状：唯一改动文件

**`Sources/Views/MainWindowNavigation.swift`**（仅此一个文件有改动；`DesignTokens` 未动，全部复用既有令牌）

### 3.1 `MainSidebarView.body`

```swift
.listStyle(.sidebar)
.tint(accent.swiftUIColor)      // 仅兜底 macOS 14–15；27 上胶囊/图标由本视图自绘
```

⛔ 2026-10-23 版这里曾有「浮岛」四行（`.scrollContentBackground(.hidden)` +
`.background(RoundedRectangle(…Radius.md…).fill(Palette.sunken))` + `.clipShape` + `.padding(8)`），
**2026-10-28 按用户要求整段删除**。删干净之后 `List` 恢复系统侧栏材质：方角、贴边、整面铺满。
别再按旧版加回来（理由见 §9）。

### 3.2 `MainSidebarView.row(_:)`

```swift
.listRowBackground(
    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        .fill(rowBackground(for: item, isSelected: isSelected))
        .padding(.vertical, DesignTokens.Spacing.xs / 2)    // 相邻行各让 2pt ⇒ 4pt 缝
        .padding(.horizontal, DesignTokens.Spacing.sm))      // 左右各内缩 8pt
.onHover { inside in
    if inside { hoveredItem = item }
    else if hoveredItem == item { hoveredItem = nil }   // 比对再清，避免快速划过闪烁
}
```

新增状态：`@State private var hoveredItem: MainNavItem?`。
`rowBackground`：选中 → `accent.swiftUIColor`；悬停 → `Palette.subtle`；否则 `.clear`。

⚠️ 内缩只加在**背景**上，不加在 `listRowInsets` 上 —— 后者会连行高、点击区、文字位置一起改。

### 3.3 已删除的调试残留

诊断 hover 时临时加过 `NSLog("[sidebar-hover] …")`，**已删除**，不要以为是漏改。

---

## 4. 待办（按优先级）

### T1（阻塞项）让 hover 生效

**已确认的事实**：`listRowBackground` 机制本身是好的 —— 选中行确实渲染成**橙色实底 + 白字**（截图像素采样验证）。所以问题**不在绘制层，而在 `onHover` 事件没有触发**：加 `NSLog` 后把鼠标移到行上，日志**零输出**。

**首要怀疑（先排除，成本最低）**：验证方式本身有问题。
本轮所有鼠标移动都是用 `CGEvent` **合成**的 `mouseMoved`。`onHover` 依赖 `NSTrackingArea` 的 `mouseEntered`，合成事件未必能驱动它。
⇒ **先请用户用真实鼠标手动悬停一次并截图确认**。若真实鼠标能出 hover 底，T1 直接关闭，不要再改代码。

若真实鼠标也不行，按顺序试：

1. **最小改动**：给行内容撑满宽度并显式声明命中区
   ```swift
   Label(...)
       .frame(maxWidth: .infinity, alignment: .leading)
       .contentShape(Rectangle())
   ```
   理由：`.listRowInsets(leading: 0)` 之后 Label 只有内容宽，`onHover` 的 tracking 区域可能窄到几乎不可命中。
2. **换容器**：`List` 在 macOS 上的行由 `NSTableRowView` 承载，SwiftUI 的 `onHover` 在行内可能被拦截。
   改 `ScrollView + VStack + Button(.plain)` 自绘（`onHover` 在普通视图上可靠）。
   代价：丢失系统方向键导航与 `List` 无障碍语义，需补 `.focusable()` + `.onMoveCommand`、
   `.accessibilityAddTraits(.isSelected)`。**这是最后手段，不要一上来就用。**
3. **保留 List + 自建 tracking**：`NSViewRepresentable` 包一个透明 `NSView` 覆在行上重写
   `updateTrackingAreas` / `mouseEntered`。可控但代码量最大。

> 验收：鼠标停在「外观」行，行底亮度应高于邻近未悬停行（`Palette.subtle` = 暗色 6% 白）。
> 可用像素采样判定：`python3 -c "from PIL import Image; ..."`，见 §7。

### T2 更新已过时的文档注释（必须做，否则误导下次修改）

`MainSidebarView` 的结构体注释（约 L137–148）与 `row(_:)` 的注释（约 L229–250）仍写着：

- 「这里**一行外观代码都不该有**」
- 「选中态胶囊、hover、圆角、焦点环**仍然全部由系统画**」

这两句在本轮之后**已不成立**。需改写为：macOS 27 实测系统不再给浮岛/强调色胶囊/hover，
本轮起由视图自绘，并保留「`List(selection:)` 仍负责选中值与键盘导航」这句。

同时 `Design/ui/v3/HANDOFF.md` §3.3 关于「系统自动画浮岛、选中态交还系统」的结论
应标注「macOS 27 已失效（2026-10-23 实测）」，避免后来者按旧文档回滚。

### T3 跑全量测试与构建

```bash
cd /Users/wenbo/MyCode/AppleProject/SafeOut
swift test --disable-sandbox > .build/preflight/测试全量.log 2>&1; echo "EXIT=$?"
```
⚠️ 必须看 **EXIT 码**，不要用 `tail` 判成败（管道会把退出码换成 tail 的）。
基线：上一轮 604 条 / 84 suites 全绿。本轮只改视图，预期不新增失败；
若 `DesignSizeParityTests` / `SettingsLayoutTests` 报红，先看是否把 `sidebarRowVerticalInset` 改动牵连进去（本轮未改该值）。

重建：
```bash
DISABLE_SANDBOX=1 ./build_app.sh          # EXIT=0 且尾部打印安装提示即为成功
```

### T4 真机验证 + 安装（需用户确认）

1. 用真实鼠标验证三条诉求（hover / 橙色选中 / 四角圆角），并切换强调色到紫/绿/蓝各看一次。
2. 安装前必须问用户：
   ```bash
   pkill -x SafeOutApp; rm -rf /Applications/SafeOut.app && cp -R Dist/SafeOut.app /Applications/
   ```

### T5 清理

- 关掉预览进程：`pkill -f "SafeOutApp --preview"`
- 本机偏好保持用户当前值（`accentColor=orange`、`AppleAccentColor=1`），**不要擅自改回蓝色**。
- `/tmp` 下的截图/点击脚本是会话临时物，不属于仓库。

---

## 5. 本轮确立的技术事实（实证，别再重复踩）

1. **macOS 27 的系统 sidebar 在 `NSSplitViewItem(sidebarWithViewController:)` 下不再画「四边内缩 8 + 圆角」的浮岛** —— 实测为方角贴边（`Design/ui/v3/HANDOFF.md` §3.3 记的是 macOS 26 行为）。要浮岛必须自绘。
2. **选中胶囊是中性灰，与 `AppleAccentColor` 无关**。上一轮「写 `AppleAccentColor=1` 胶囊变橙」的结论在本机 macOS 27 上**不可复现**。`syncAppleAccentColor()` 保留（它仍影响系统级强调色口径），但**不能指望它染色侧栏**。
3. **`listRowBackground` 可覆盖选中视觉**：橙色实底能盖住系统灰胶囊，行文字同步改白即可。这是本轮 ② 生效的机制。
4. **`listRowBackground` 会随 `model.selection` 重算**（选中切换正常），所以「背景不刷新」不是当前 hover 失败的原因。
5. 设计稿取值（`Design/ui/v3/assets/ds.css`）：行圆角 `--r-sm = 6`、悬停底 `--bg-subtle`、
   侧栏底 `--bg-sunken`（暗色 `rgba(0,0,0,.25)`、浅色 `rgba(30,25,50,.04)`）、选中态 `--accent` 实底 + `--on-accent` 白字。

---

## 6. 环境与工具链

| 项 | 说明 |
|---|---|
| 构建 | `swift build --disable-sandbox`（受管环境必须带；否则宏报 malformed response 假错） |
| 打包 | `DISABLE_SANDBOX=1 ./build_app.sh` |
| 测试 | 日志写 `.build/preflight/测试全量.log`，**以 EXIT 码判定** |
| 签名 | `SafeOut Dev Signing`（自签 10 年，DR 锚证书 leaf hash）⇒ FDA/TCC 跨重建保留 |
| 预览 | `Dist/SafeOut.app/Contents/MacOS/SafeOutApp --preview-main-window --preview-settings` |

### 截图/自动化小工具（都在 `/tmp`，重启即丢，附重建要点）

- **全屏截图**（`screencapture` 因 TCC 失效时用它）：`SCScreenshotManager.captureImage` + `SCDisplay` 过滤。
  多窗口过滤会触发 `CGS_REQUIRE_INIT` 断言，**必须先 `_ = NSApplication.shared`** 再 `NSApplication.shared.run()`。
- **单窗口截图**：`SCContentFilter(desktopIndependentWindow:)`，同样需要 AppKit 初始化。
- **窗口边界**：`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 按 `kCGWindowOwnerPID` 过滤。
- **置前窗口**：`NSRunningApplication(processIdentifier:).activate(options:)`（不需要 AX 权限）。
- **点击/按键/移动鼠标**：`CGEvent.post(tap: .cghidEventTap)`（`cliclick` 会报 AX 未授权，但自写 CGEvent 可用）。
- **PIL 采样**：`python3 -c "from PIL import Image; ..."` 读像素，用来判断「有没有变色」比肉眼可靠。

坐标换算：`CGWindowList` 给的是**点**；截图像素 = 点 × 2（Retina）。
鼠标屏幕坐标 = 窗口原点 + 窗口内坐标（同为点，y 向下）。

---

## 7. 本轮验证记录（可复现）

- 构建：`swift build --disable-sandbox` 通过（9.85s，无警告）；`build_app.sh` EXIT=0。
- 截图（1600×1040，窗口 800×520 @2x）：
  - 选中「通用」= **橙色实底 (237,151,79) + 白字**（强调色 orange）✅
  - 侧栏左上/左下/右上/右下均可见圆角，四边内缩 8pt ✅
  - 鼠标移到「外观」行后，行底色仍为 `(27,28,32)`，与相邻行**完全相同** ❌
- `onHover` 加 `NSLog` 后日志**零输出** ⇒ 事件未触发，非绘制问题。

---

## 8. 风险与红线（动代码前读）

1. **「不要给侧栏加背景/圆角」这条旧红线已恢复生效**（2026-10-28 用户撤销浮岛）。
   历史：10-23 按用户「要四周圆角」自绘过浮岛，10-28 用户看实物后明确不要 ⇒ 已删除。
   ⛔ 别再给 `List` 加 `.background` / `.clipShape` / `.scrollContentBackground(.hidden)`。
2. 浮岛外圈露出的是窗口玻璃。若将来给侧栏内塞 `NSVisualEffectView`，会把玻璃材质盖死（官方明文禁止）。
3. 选中态颜色**只许来自 `AccentColor`**（`accent.swiftUIColor`），不要写死 `#EA580C` 之类的十六进制。
4. 行圆角用 `Radius.sm`(6)、内缩用 `Spacing.sm`(8)、行色块上下让位用 `Spacing.xs / 2`(2) ——
   全部取自现有令牌，**没有新增令牌**，因此 `ds.css` / `DesignTokens.swift` / 测试三处无同步动作。
   （`Radius.md`(10) 现在只被删掉的浮岛用过，侧栏里不再用它。）
5. 改完必须跑全量测试 + 零警告构建（仓库铁律）。

---

## 9. 2026-10-28/29：浮岛撤销 + 行间间隙 + 左右内缩

### 9.1 用户原话与结论

1. 「左侧菜单hover和选中两个颜色之间没有间隔，而且你看下背景圆角现在是半块」
2. （澄清「半块」= 哪一半）用户选择：**「浮岛背景只有下半截」** —— 灰底只从标题栏下方开始，
   窗口顶部（红绿灯那一带）是空的玻璃。
3. 「把左侧菜单中的浮岛拿掉吧，不要了」

⇒ 结论：不再和「浮岛铺满整窗」较劲，**直接把浮岛删掉**，侧栏背景回到系统材质。

### 9.2 为什么「铺满整窗」那条路走不通（试过并回退）

侧栏顶部那条 52pt 内缩来自**安全区**（`MainWindowContentController/makeSidebarController`
故意没设 `safeAreaRegions = []`）—— 它正是「第一项落在红绿灯下方」的来源，必须保留。
把 `safeAreaRegions` 关掉之后，实测 `.contentMargins(.top, 44, for: .scrollContent)`
**完全补不回**那个内距，第一项直接压在红绿灯上 ⇒ 已回退，安全区保持默认。

### 9.3 三处改动（都在 `MainWindowNavigation.swift`）

| 改动 | 取值 | 理由 |
|---|---|---|
| 删掉浮岛四行 | — | 用户不要；删后系统材质方角贴边铺满 |
| `listRowBackground` 上下内缩 | `Spacing.xs / 2` = 2pt | 相邻行各让 2pt ⇒ 4pt 缝。原状实测 y=393/394 **零间隙** |
| `listRowBackground` 左右内缩 | `Spacing.sm` = 8pt | 浮岛没了之后行色块会贴窗口左缘与分隔线，圆角被切出「半块」观感 |

⚠️ 内缩只加在背景层，`listRowInsets` 一个字没动（行高 / 点击区 / 文字位置不变）。

### 9.4 真机取证（1600×1040 = 窗口 800×520 @2x）

对 `new8_hover.png` 逐像素扫描（鼠标悬停「外观」、选中「通用」）：

- 竖直 x=340px（170pt，避开文字）：紫块 `y 258…337` → 背景 `338…341` → 灰 hover 块 `342…413`
  ⇒ **两块之间 4px = 2pt 的底色缝**（加上两侧抗锯齿可见约 4pt），零间隙已修好。
- 水平 y=350px（175pt）：窗口左缘 `x 0…15` 是侧栏底色 `(224,224,224)`，灰块从 `x 17` 起
  ⇒ 左内缩 **8pt**；灰块右缘 `x 383` = 191.5pt ⇒ 距分隔线（200pt）也是 8pt。
- 侧栏底色从 y=0（红绿灯那一带）一直铺到窗口底，**没有内缩、没有圆角** ⇒ 浮岛已彻底消失。
- 第一项「外置磁盘」仍在红绿灯下方（安全区默认）。

> 取证工具在 `/tmp`（会话临时）：`shot_bin <pid> <wid> <x> <y> <out>`（激活 → 移鼠标 → 截图，
> 一个进程做完，避免截图进程抢焦点把 hover 清掉）、`sample_bin`（逐像素扫描色段）、`win_bin`（取 wid/bounds）。

### 9.5 关于 hover 的老结论：T1 的「合成事件驱动不了 tracking area」不成立

10-23 记的「`CGEvent` 合成的 `mouseMoved` 未必能驱动 `onHover`」被 10-29 的取证推翻：
`shot_bin` 用的同样是合成 `mouseMoved`，hover 底**正常出现**。

真正的原因是**窗口没激活**：先 `NSRunningApplication.activate` 再移鼠标，hover 立刻可见；
若截图进程抢先成为前台 app（窗口失活，红绿灯变灰），hover 底同时消失。
⇒ 以后验证 hover：先激活 → 再移指针 → 再截图，且**三个动作在同一个进程里**按顺序完成。

测试基线：`swift test --disable-sandbox` = **609 条 / 84 suites 全绿，EXIT=0**。
