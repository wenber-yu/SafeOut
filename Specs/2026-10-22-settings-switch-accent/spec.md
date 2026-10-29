# 设置页两个缺陷修复：接管开关未授权引导 + 强调色侧栏不跟随

日期：2026-10-22
状态：待批准

## 背景

用户报告两个设置缺陷：

1. 设置 › 通用 ›「推出时提醒占用」：点击 switch 没有任何反应；期望「未授权时引导用户去开启授权」。
2. 设置 › 外观 › 强调色：选了没有任何作用。

## 根因（均已实证，非推测）

### Bug 1 — 开关是死控件

未授「完全磁盘访问」（FDA）时，`SettingsSectionPane` 走不可用分支
（SettingsView.swift `takeOverUnavailableControl`）：

```swift
Toggle("", isOn: .constant(takeOverOn))
    .toggleStyle(.switch)
    .labelsHidden()
    .disabled(true)   // ← 点击必然无反应
```

真机截图确认本机当前即此状态（开关灰白 + 右侧「打开系统设置」小按钮）。
唯一引导入口是那颗小按钮，开关本身是死控件 —— 与用户「点 switch 应引导授权」的期望直接冲突。
（FDA 在重签后掉落，属预期；`didBecomeActiveNotification` 会重探 `takeOverAvailability`，授权后回来行会自动翻成可用。）

### Bug 2 — 侧栏选中色走系统强调色；外观页零反馈

实证：`defaults write com.safeout.app accentColor orange` 后，「登录时启动」开关
实时 绿→橙 ✓，说明 accent 数据链路（`@AppStorage` → `AccentColor` → 各组件）完全正常。

但用户视野内最显眼的主色元素不跟随：

1. **v3 侧栏**（`MainSidebarView`）是系统 `List + .listStyle(.sidebar)`，选中胶囊由
   AppKit 按**系统强调色**绘制（本机系统强调色=蓝），与本应用内 accent 设置无关。
   macOS 26 上系统画中性灰（不变，是设计）；14/15 上画系统强调色实底 —— 用户看到
   「App 里选了橙，侧栏还是蓝」。
2. **外观页自身零反馈**：`SettingsSegmentedControl` 声明了 `accent: AccentColor`
   参数但 body 从不使用（选中项用中性 `Palette.raised`，这是设计稿规格，**不改**）；
   色板选中环是各色板自身颜色（静态）。用户在做选择的那一页看不到任何像素变化。

## 修复方案

### Bug 1：未授权时开关可点，点击弹 FDA 引导

原则：不写偏好（`setTakeOverFinderEject` 保持唯一写入路径，授权后用户再正常拨开，
下游「通知授权 + 辅助功能引导」链路不变）；开关始终显示关（`effectiveIsOn` 口径不变，
界面像素不撒谎）；点击 = 弹引导。

1. `Sources/Views/SettingsView.swift`
   - `SettingsPrompt` 新增工厂 `takeOverNeedsFDA()`（非可选）：
     标题/说明（新 i18n 键），`openSettings = AppSettings.openFullDiskAccessSettings`，
     `dismissTitle = L10n.tr(.notNow)`（与辅助功能引导同一口径：用户有权不授权）。
   - `SettingsSectionPane` 新事件 `var onTakeOverNeedsFDA: () -> Void = {}`（init 参数追加在回调区）。
   - `takeOverUnavailableControl`：`Toggle` 去掉 `.disabled(true)`，binding 改为
     `Binding(get: { takeOverOn }, set: { newValue in guard newValue else { return }; onTakeOverNeedsFDA() })`。
     行尾「打开系统设置」按钮**保留**（直达入口，与弹窗并存）。
2. `Sources/Views/MainWindowNavigation.swift`
   - `SettingsDetailPage` 透传 `onTakeOverNeedsFDA`。
   - `MainDetailView.page` 接线：`onTakeOverNeedsFDA: { prompt = SettingsPrompt.takeOverNeedsFDA() }`。
3. `Sources/Localization/Localizable.xcstrings` 新增 2 键（三语 zh-Hans / en / ja），
   并运行 `python3 Tools/build_i18n.py` 同步指纹：
   - `takeOverNeedsFDAPromptTitle`：「推出时提醒占用」需要完全磁盘访问
   - `takeOverNeedsFDAPromptMessage`：授权后才能列出占用外置磁盘的进程。授权后回到本页打开开关即可。
4. `Tests/SafeOutAppTests/DisabledConditionInventoryTests.swift`（L80–100 一带）：
   原断言「未授权时 Toggle 恒不可点」改写为新契约：未授权时开关**可点**、
   点击**只弹引导、不写偏好**；恒不可点清单中移除该条目。

### Bug 2：侧栏选中色跟随 App 内强调色

1. `Sources/Views/MainWindowNavigation.swift` — `MainSidebarView`：
   - 加 `@AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue`
     与 `private var accent: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }`。
   - `List` 末尾加 `.tint(accent.swiftUIColor)`。
   - 效果：macOS 14/15 选中胶囊跟随 App 强调色；macOS 26 系统仍画中性灰
     （`MainSidebarView` 既有注释已声明「两边都对，都不是 bug」，补一句 tint 口径说明）。
2. 外观页分段控件**不动**（中性选中是设计稿规格，受布局/视觉契约测试保护）。

范围外（不动）：菜单栏弹出面板（每次打开已重读 accent）、弹出窗、状态栏图标。

## 验证

1. `swift test --disable-sandbox` 全量绿（基线 601 条）；
   日志写 `.build/preflight/测试全量.log`，以 EXIT 码判定（禁管道 tail）。
2. `DISABLE_SANDBOX=1 ./build_app.sh` 重建。
3. 真机验证（本机即未授 FDA 状态，天然满足前置）：
   - 通用页点「推出时提醒占用」开关 → 弹 FDA 引导；「打开系统设置」跳系统设置；「暂不」关闭。
   - 外观页切换强调色 → 侧栏选中胶囊实时跟随（14/15）；「登录时启动」开关色同步。
4. 安装需用户确认后执行：`pkill -x SafeOut; rm -rf /Applications/SafeOut.app && cp -R Dist/SafeOut.app /Applications/`。

## 测试基线守卫

- 全量测试必须保持绿；`SettingsLayoutTests` / `SnapshotRenderTests` 中
  `takeOverAvailabilityOverride: .needsFullDiskAccess` 的离屏出图不应因去掉 `.disabled(true)` 变红
  （若有个别断言引用禁用态，按新契约同步改写）。
