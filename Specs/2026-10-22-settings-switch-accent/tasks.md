# 任务清单：设置页两个缺陷修复

日期：2026-10-22　关联：spec.md

## [x] T1 Bug1 — SettingsPrompt.takeOverNeedsFDA + i18n 两键
- `Sources/Views/SettingsView.swift`：`SettingsPrompt` 新增 `takeOverNeedsFDA()` 工厂。
- `Sources/Localization/Localizable.xcstrings` 新增
  `takeOverNeedsFDAPromptTitle` / `takeOverNeedsFDAPromptMessage`（zh-Hans / en / zh-Hant 三语）。
- 运行 `python3 Tools/build_i18n.py` 同步指纹。✅ 已跑（228 条/语言 × 3）

## [x] T2 Bug1 — 未授权分支开关可点并上抛事件
- `SettingsSectionPane`：新增 `onTakeOverNeedsFDA` 事件（属性 + init 参数）。
- `takeOverUnavailableControl`：去 `.disabled(true)`，改 live binding，点击上抛。
- `SettingsDetailPage` 透传；`MainDetailView.page` 接线到 `prompt`。

## [x] T3 Bug1 — 改写 DisabledConditionInventoryTests 契约
- 账本划掉「未授权时 Toggle 恒不可点」条目（附划账注释）；
  `EjectHookPolicyTests.接管行三处都过闸门` 同步改写为新契约（可点 + 上抛 + 不写偏好）。
- 另：`DocTableIntegrityTests` 的 `docs` 列表登记本规格两份 .md。

## [x] T4 Bug2 — MainSidebarView 侧栏 tint
- 加 `@AppStorage` accent 读取 + `List` 末尾 `.tint(accent.swiftUIColor)`；补注释口径。

## [x] T5 全量测试绿
- `swift test --disable-sandbox` → EXIT=0，601 条 / 84 suites 全绿
  （日志 `.build/preflight/测试全量.log`）。

## [x] T6 重建 + 真机验证（安装前需用户确认）
- `DISABLE_SANDBOX=1 ./build_app.sh`。✅
- 真机两点验证：✅
  - 开关引导弹窗：点击开关弹「需要先允许完全磁盘访问」，开关恒关不写偏好；
    「打开系统设置」按钮链路（alert primaryButton → openSettings →
    `NSWorkspace.open(Privacy_AllFiles)`）实测跳转到系统设置「完全磁盘访问权限」页。
  - 侧栏随强调色：`AppleAccentColor` 进程启动前落盘则胶囊与源列表图标跟随
    （系统机制：运行中不可刷新，只能下次启动生效）；其余组件即时跟随。
- 用户确认后安装到 /Applications。✅ 已安装并启动（签名 Authority=SafeOut Dev Signing，
  二进制含两项修复符号；用户已拍板接受「侧栏胶囊下次启动跟随」的机制边界，不做自动重启）。
