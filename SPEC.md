# SafeOut — MVP 需求规格文档

> 版本：v1.0 MVP  
> 日期：2026-04-08  
> 作者：文博 & 代可行  
> 状态：**已确认，待开发**

---

## 1. 项目概述

| 字段 | 内容 |
|------|------|
| 项目名称 | SafeOut |
| 类型 | macOS 工具类应用 |
| 最低系统版本 | **macOS 14.0+**（Sonoma 及以上；`Package.swift` 的 `platforms` 是**唯一真相**，本行由 `DeploymentTargetTests` 钉住一致） |
| UI 框架 | SwiftUI |
| 核心功能 | 安全优雅地推出第三方移动硬盘（支持查看并自动终止占用进程、显示磁盘信息、卸载失败告警与日志） |

---

## 2. 功能规格

### 2.1 核心功能

| # | 功能点 | 描述 |
|---|--------|------|
| F1 | 外置磁盘检测与列表 | 自动扫描并展示所有已挂载的外置/移动硬盘（非系统盘） |
| F2 | 磁盘基本信息 | 每个磁盘旁显示：`名称` + 总容量 / 已用 / 剩余 |
| F3 | 占用进程展示 | 列出当前正在读写该磁盘的所有进程（进程名 + PID）。**分发渠道为官网直发（Developer ID，不开沙盒），`lsof` 可真实列出；若运行环境被沙盒限制（本应用不发布沙盒构建，仅作防御分支）则降级为「当前环境无法检测」** |
| F4 | 一键安全推出 | 调用系统推出接口；磁盘被占用时返回「正被使用」并拒绝强卸（原「自动终止进程」方案已整体移除，见 §4.2） |
| F5 | 确认对话框 | 点击推出前，弹窗列出将被终止的进程名称，用户点确认后才执行。**沙盒下无进程信息，已改为推出前确认** |
| F6 | 卸载失败告警 | 卸载失败时弹出系统告警（NSAlert），并记录错误日志 |
| F7 | 错误日志记录 | 将卸载失败信息写入本地日志文件（含时间戳、磁盘名、错误原因） |
| F8 | 接管访达的推出（可选，默认关） | 打开后，**访达里**的推出按钮（以及任何走 `NSWorkspace.unmountAndEjectDevice` 的请求）也先由本应用判定：无占用则照常放行；有占用则弹出本应用的占用窗。⚠️ 判定期间访达**静默等待**用户决定，**此时其它磁盘的推出请求会被系统一并排队**（DA 协议对 approval 回调的串行化）。⚠️ **但等待有上限**：系统对一次 unmount 的等待约 **12.5s**，超过之后访达就不等了 —— 清场再干净也没人接着推，**用户点了「关闭并推出」盘会纹丝不动**。所以本应用的决策窗口（`EjectHookPolicy.userDecisionTimeout`）必须留在那个上限之内（现为 **8 秒**，含清场宽限 2.3s）；到点未决定则按「取消」收场（访达弹它自己的「正在使用」提示、盘保持挂载），见 §8.149。默认关：它是系统级行为改动。开关在「设置 › 通用」，**改了即时生效、不需要重启**。**可用性闸门**：本功能依赖「完全磁盘访问」（要它才列得出占用者），未授权时该开关**不可点**、且那一行就地写明原因并给出直达系统设置的按钮（判定收敛在 `AppSettings.TakeOverAvailability` 这一个纯函数里，见 §8.147） |

### 2.2 交互形态

| 形态 | 说明 | 优先级 |
|------|------|--------|
| **菜单栏 App** | 顶部菜单栏常驻，点击展开磁盘列表，支持右键快捷操作 | P0 |
| **独立窗口 App** | 主窗口展示磁盘列表，支持上述所有交互 | P0 |
| **右键服务（Finder）** | Finder 中右键触发"安全推出"（macOS Services） | P1（MVP 后实现） |

---

## 3. UI/UX 设计

### 3.1 视觉风格

- **整体风格**：macOS Native SwiftUI + **Liquid Glass 毛玻璃**（「Liquid Glass」是**设计稿侧的
  视觉目标名**，见 `Design/ui/`；实现是 `NSVisualEffectView`
  `.underWindowBackground` / `.behindWindow`，见 `Sources/Views/GlassViews.swift`。
  ⚠️ **不是** macOS 26 才有的 `.glassEffect()` / `NSGlassEffectView` ⇒ **没有版本下限**，
  别写「macOS 15+ / 26+」）
- **配色方案**：
  - **透明模式（Transparent）**：全透明毛玻璃背景，contentTint 蓝色系，适配毛玻璃系统主题
  - **色调模式（Tinted）**：固定浅色 tint 背景（系统 background 色），适合不喜欢透明的用户
  - 两种模式可在设置中切换，默认为透明模式
- **深色/浅色模式**：完全跟随系统 `ColorScheme`
- **图标**：SF Symbols（`eject.fill`、`externaldrive.fill`、`xmark.circle`、`folder.fill`）

### 3.2 菜单栏模式

```
[ 💻 SafeOut 图标（SF Symbol: externaldrive.fill）]
  ↓ 点击
[ 弹出面板 - Liquid Glass 毛玻璃 ]
  ├─ 磁盘A: Samsung T7 — 1TB / 已用 300GB / 剩余 700GB   [ ⏏️ 推出 ]
  ├─ 磁盘B: WD Blue — 500GB / 已用 120GB / 剩余 380GB   [ ⏏️ 推出 ]
  └─ ─────────────────────────────────
     [ ⚙️ 设置]          [ ⏻ 退出]
```

### 3.3 主窗口模式

- **整体布局**：单窗口，左侧列表 + 右侧详情
- **左侧**：外置磁盘列表（带图标），选中态高亮
- **右侧**：
  - 磁盘名称 + 图标（顶部）
  - 容量进度条（彩色条：蓝色已用 / 灰色剩余）
  - 占用进程列表（进程图标 + 名称 + PID）
  - 底部操作区：[ 推出磁盘 ] 按钮
- **底部状态栏**：最后操作结果（成功/失败提示）

### 3.4 确认对话框

```
┌──────────────────────────────────────────────┐
│  ⚠️ 即将终止进程并推出磁盘                     │
│                                              │
│  以下程序正在访问此磁盘，关闭它们可能导致      │
│  数据丢失（未保存的工作将被丢弃）：            │
│                                              │
│  • Finder.app (PID: 1234)                    │
│  • PhotoImport.app (PID: 5678)               │
│                                              │
│            [ 取消 ]     [ 确认终止并推出 ]    │
└──────────────────────────────────────────────┘
```

---

## 4. 技术方案

### 4.1 技术栈

| 层 | 技术选型 |
|----|----------|
| UI | SwiftUI（支持 macOS 14+） |
| 磁盘枚举/属性 | DiskArbitration.framework（`DADiskCopyDescription`） |
| 推出执行 | `NSWorkspace.unmountAndEjectDevice(at:)` |
| 进程查询 | 非沙盒构建（本应用唯一的发布形态）：`lsof`；**沙盒构建：不可用，降级**（沙盒形态不发布，代码里仅作防御分支） |
| 日志 | `os.Logger` + 本地文件（FileHandle，带大小轮转） |
| 打包 | SwiftPM + `build_app.sh` 生成 .app bundle（渠道固定直发；再传 `BUILD_CHANNEL` 会报错退出） |

### 4.2 关键实现路径

1. **磁盘枚举**：`DADiskCreateFromVolumePath` → `DADiskCopyDescription`，外置判据为
   `DADeviceInternal == false`。
   - **为什么不用 `DAMediaRemovable` / `NSURLVolumeIsEjectableKey`**：实测 USB 外置硬盘
     （SanDisk Extreme，Protocol=USB / Location=External）这两个键均为 `false`——介质被标记为
     Fixed。按它们过滤会把真实外置盘漏掉。
   - **无物理设备属性的虚拟卷**（磁盘映像等）仅在系统明确标记 `DAMediaEjectable == true` 时列入，
     避免把 Xcode 模拟器映像、系统 cryptex 映像交给用户推出。
   - 网络卷（`DADeviceProtocol` 为 SMB/AFP/NFS 等）排除。
2. **占用进程检测（核心价值，依赖运行环境）**：列出「是谁占用磁盘」是本应用的核心价值。
   但 App Sandbox 会封死进程枚举（实测矩阵见下），因此**分发渠道定为官网直发
   （Developer ID，不开沙盒）**——`lsof` 在直发构建下可用，能真实列出占用进程名。

   > **2026-09-18：本应用不上架 Mac App Store**，不发布任何沙盒形态的构建。
   > 下面这张矩阵保留，是为了解释**为什么**沙盒下会降级（它决定了「不开沙盒」这个前提），
   > 不是因为还有一条 MAS 渠道在维护。

   | 能力 | 非沙盒（直发，唯一发布形态） | 沙盒（不发布，仅实测记录） |
   |------|--------|----------|
   | `lsof` | 正常（列出进程名） | **输出 0 行** |
   | `proc_listallpids` | 正常 | **返回 0** |
   | `kill()` 其他进程 | 正常 | **EPERM** |

   直发版未授予「完全磁盘访问」时，`lsof` 同样拿不到其他进程，此时检测返回
   `.needsFullDiskAccess` 并提示用户去系统设置授权——授权后恢复列出（`.occupied`）。
   保留 `lsof -Fpcn0` 解析实现；`build_app.sh` 渠道固定为直发，
   签名用 `SafeOut.direct.entitlements`（无 sandbox），并在签名后**回读校验**
   包里没有 `com.apple.security.app-sandbox`。
3. **安全推出**：`NSWorkspace.unmountAndEjectDevice(at:)`（实测沙盒内可用）。
   **不再使用 `diskutil unmount force`**——force 会绕过「有进程占用就失败」这层系统保护，
   在磁盘正被写入时强行卸载，存在数据损坏风险。
4. **失败处理**：首次失败即按错误类型给出针对性文案并写入日志；不做静默重试，
   因为 busy 类错误重试无意义，需用户先关闭占用程序。

### 4.3 目录结构

**仓库根目录即 SPM 包根**（`Package.swift` 在仓库根，与 FCPX2AAF / ProxyGenerator 布局一致）。

```
SafeOut/
├── Package.swift                    # SPM 清单（可执行 target SafeOutApp + 测试 target）
├── .swift-format                    # swift-format 配置（4 空格缩进 / 120 行宽）
├── build_app.sh                     # 一键打包 .app（渠道/签名/公证；STRICT_CI=1 先过 CI 门槛）
├── run.sh                           # 源码目录直接编译运行；`run.sh check` 只跑 CI 门槛
├── SPEC.md                          # 本文件
├── .github/workflows/ci.yml         # CI：零警告构建 + 格式检查 + 覆盖率门槛 + 打包验证
├── Sources/
│   ├── SafeOutApp/
│   │   ├── SafeOutApp.swift     # 应用入口 + AppDelegate（status item、popover 定位）
│   │   └── WindowSelfCheck.swift    # `--preview-*` 自检里**不碰应用状态**的量测函数（7 个 static func）
│   ├── Models/
│   │   ├── DiskInfo.swift           # 磁盘数据模型 + 外置判定（DiskClassifier）
│   │   ├── OccupyingProcess.swift   # 进程数据模型（原名 ProcessInfo，避免与 Foundation 同名）
│   │   └── ByteFormat.swift         # 容量格式化（单一事实来源，与 Finder 一致）
│   ├── Services/
│   │   ├── DiskService.swift        # 磁盘枚举（DiskArbitration）
│   │   ├── DiskListStore.swift      # 磁盘列表单一数据源
│   │   ├── EjectService.swift       # 推出执行 + 错误分类
│   │   ├── EjectFlowController.swift# 菜单栏/主窗口共用推出流程（EjectOutcome）
│   │   ├── EjectHookService.swift   # 接管访达的推出（DiskArbitration approval 回调）
│   │   ├── EjectHookPolicy.swift    # 接管的判定层（纯值：开关/自排除/外置/占用/去重）
│   │   ├── ProcessTerminator.swift  # 同步清场（SIGTERM → 宽限 → SIGKILL）
│   │   ├── OccupancySnapshotStore.swift # 占用结论的跨线程只读快照
│   │   ├── EjectUI.swift            # 共享推出弹窗（占用提示 + 破坏性按钮）
│   │   ├── OccupancyDetector.swift  # 占用检测（lsof 解析 / 沙盒降级 / FDA 探针）
│   │   ├── LaunchAtLoginManager.swift # 开机启动（SMAppService）
│   │   ├── UpdateService.swift      # 版本更新检查
│   │   └── LogService.swift         # 错误日志写入（带轮转）
│   ├── Settings/
│   │   └── AppSettings.swift        # 偏好键与颜色映射（单一事实来源）
│   ├── Views/
│   │   ├── ContentView.swift        # 主窗口内容
│   │   ├── MenuPopoverView.swift    # 菜单栏弹出面板
│   │   ├── SettingsView.swift       # 设置面板
│   │   ├── DesignTokens.swift       # 设计令牌（尺寸 / 配色 / 间距 / 字号）
│   │   ├── DesignSystemComponents.swift # 复用组件（ProcessTag / TextButton / FdaBanner）
│   │   └── GlassViews.swift         # 材质与玻璃效果视图
│   └── Localization/
│       └── Localizable.xcstrings    # 本地化字符串（简中 / 繁中 / 英）
├── Tests/
│   └── SafeOutAppTests/         # 单元测试 + 集成测试（真机挂 dmg 验证推出）
├── Plugins/
│   └── LocalizationGenerator/       # 构建插件：由 .xcstrings 生成 L10n.Key 枚举
├── Resources/
│   ├── AppIcon.icns                 # 应用图标资产（由 Scripts/build_icon.sh 生成）
│   ├── AppIcon.png
│   └── SafeOut.direct.entitlements # 直发版（无沙盒，可列出占用进程；沙盒版 entitlements 已随不上架决定删除）
├── Scripts/
│   ├── build_icon.sh                # 源图 → AppIcon.icns（sips + iconutil）
│   ├── catch-beep.sh                # 抓「系统提示音」用的辅助脚本
│   ├── ci_status.sh                 # 推送**之后**看 CI 结论（`./run.sh ci`；与 check 配对）
│   ├── coverage.sh                  # 覆盖率门槛（只统计 Models / Services / Settings）
│   ├── make_appcast.sh              # 生成 Sparkle appcast
│   ├── preflight.sh                 # CI 严格门槛预检（本地与 CI 共用的唯一实现）
│   └── scan_stale_comments.sh       # 门槛 3：注释承诺句必须带日期
├── Tools/
│   ├── gen_l10n_tool/               # 独立 SPM 包：本地化代码生成器（被 Plugins 调用）
│   └── icon_tool.swift              # 增强版图标生成器（ImageIO，当前未被脚本调用）
└── Design/                          # 设计资源总目录（图标源图 / 候选素材 / 截图 / UI 设计稿）
    ├── app-icon/                    # 图标源图专用目录（放图后跑 Scripts/build_icon.sh）
    ├── icon-candidates/             # 图标设计候选素材（8 款 + .design）
    ├── screenshots/                 # README 用的截图
    └── ui/                          # UI 设计稿（HTML 页面 + 设计令牌 CSS + v2/ 规范）
```

> 设计资源（图标源图 / 候选素材 / 截图 / UI 设计稿）统一收在根级 `Design/` 下，
> 与 ProxyGenerator 中 `proxy-generator-icons/` 的摆放惯例保持一致。
> ⚠️ `Sources/`、`Tests/`、`Plugins/` 三个**大写**目录名是 SwiftPM 的约定名，
> **不要**为了「统一小写」而改名（改 `Sources` 还要同步 `Package.swift` 的 `path:`）。

---

## 5. 验收标准（MVP 完成点）

- [x] 能正确识别并列出所有已挂载外置磁盘（沙盒下已实测：wenbo-data + 测试映像正确识别，系统映像已过滤）
- [x] 磁盘容量信息（总量/已用/剩余）显示正确
- [x] 占用进程：**直发版本可列出进程名**（核心价值）；沙盒环境显示「当前环境无法检测」
- [ ] 点击"推出"弹出确认对话框
- [x] 磁盘被占用时拒绝强卸，返回「正被使用」提示（沙盒下已实测 fBsyErr）
- [x] 磁盘空闲时成功推出（沙盒下已实测成功）
- [x] 卸载失败时触发系统告警并写入日志文件
- [x] 菜单栏模式正常运行
- [x] 主窗口模式正常运行
- [x] 透明 / 色调两种视觉模式可切换
- [x] 单元测试覆盖：30 tests passed，构建零警告

---

## 6. 非功能需求

### 6.1 无障碍

菜单栏的磁盘行是自定义 `NSView`（`NSMenuItem.view`）。**设置自定义 view 后系统不再提供
默认的可访问性支持**——整行对 VoiceOver 是「什么都不是」，行内按钮也不可达。因此必须显式配置：

| 元素 | 处理 |
|------|------|
| 状态栏按钮 | `setAccessibilityLabel("SafeOut")` + role `.button` |
| 菜单磁盘行 | role `.group`，标签含「磁盘名 + 已用百分比 + 已用/总容量」 |
| 推出按钮 | 标签形如「推出 wenbo-data」——多个按钮都叫「推出」时无法区分 |
| 装饰图标 | `accessibilityHidden(true)` / `setAccessibilityElement(false)` |
| SwiftUI 磁盘行 | 仅合并「名称 + 空间」两部分；**不能** `combine` 整张卡片，那会把推出按钮吞进同一元素，导致能读不能点 |

### 6.2 开机自启

使用 `SMAppService.mainApp`（macOS 13.0 起提供）——目前唯一不依赖已废弃 API、也不需要内嵌
helper 的登录项方案。（「符合 MAS 要求」这条理由随不上架决定作废，选型不变。）
不使用 `LSSharedFileList`（macOS 13 起已废弃、不再可靠生效）、不自写 LaunchAgents plist
（沙盒无写权限）。

`SMAppServiceStatus` 的 `.requiresApproval` 必须显式处理：注册已提交但需用户到
「系统设置 → 通用 → 登录项」手动开启。若只按 Bool 建模，UI 会显示「已开启」但实际不启动。
该状态下反复 `register()` 不会推进，只提示用户并提供 `SMAppService.openSystemSettingsLoginItems()`。

### 6.3 自动更新

> **2026-09-18 决定：本应用不上架 Mac App Store**，只走 Developer ID 直发。
> 因此渠道只有两种（编译期区分，不再用 App Store 收据判定）：
> `direct`（发布构建）/ `development`（`DEBUG` 构建）。
> 原先 `.appStore` 分支（收据判定 / `appStoreID` / `macappstore://` / 「在 App Store 中查看」）
> 及其两条本地化键已删除，并由 `UpdateServiceTests`、`LocalizationCatalogTests` 钉住「不存在」。

| 渠道 | 更新方式 |
|------|----------|
| Developer ID 直发（唯一渠道） | **Sparkle 2**（SwiftPM 依赖，二进制 xcframework）：`UpdateController` 持有 `SPUUpdater`；`UpdateService.openUpdateSource()` 保留为「updater 起不来」时的退路 |
| `DEBUG` 开发构建 | 同上，版本行显示「开发版」而非「官网直发版」（避免误判为可分发产物） |

**feed 不是 GitHub 的 `/releases/latest`**：那是 HTML / atom 页面，Sparkle 解析不了
（它要带 `sparkle:` 命名空间的 RSS）。`appcast.xml` 由 `Scripts/make_appcast.sh`
（内部调 `generate_appcast`）生成并提交进仓库，`SUFeedURL` 指向它的
`raw.githubusercontent.com` 地址；真正的下载地址写在 appcast 的 enclosure 里，
指向 `…/releases/download/v<TAG>/SafeOut-<VERSION>.dmg`。

> **现状（2026-09-18 实测）**：`appcast.xml` 已生成并提交，线上
> `raw.githubusercontent.com/…/master/appcast.xml` 返回 **200**，内容与仓库里那份逐字一致；
> 产物 Info.plist 里 `SUFeedURL` 指向它（实测 200）、`SUPublicEDKey` **尚未写入**（不验签）、
> `SUEnableAutomaticChecks=true`。
> **唯一还差的一步**：`v2026.09.18.3` 这个 Release 还没建 → enclosure 现在 **404**。
>
> ⚠️ **2026-09-23 订正：上面这段「现状」是 2026-09-18 的时点快照，别拿它当当前状态**
> （原句保留、不删历史 —— 它是那一天的实况）：
> - **`SUPublicEDKey` 已写入**：`build_app.sh` 里有 `DEFAULT_SPARKLE_PUBLIC_ED_KEY`
>   （2026-09-20「公钥入库当默认值」—— 它本来就烤在每个发行包里、是公开的）
>   ⇒ 产物 Info.plist 会带上它，现在是**验签**的。
> - **Release 已建、enclosure 不再 404**：仓库根 `appcast.xml` 现在的 enclosure 指向
>   `v2026.09.21.1/SafeOut-2026.09.21.1.dmg` 且带 `sparkle:edSignature`。
>   （`v2026.09.18.3` 那个 Release **确实没建过** —— 当时改发 `.4`，见账本 #8。）
> - 判据落在 `Scripts/verify_app.sh`：它校验 `SUPublicEDKey` 存在且与仓库里的默认值同源，
>   缺了 / 不一致都算产物不合格。⚠️ 它是**打包后手跑**的，**不在 preflight 门槛里**。
> ⇒ 「唯一还差的一步」这句话在 2026-09-18 是对的，**今天已经不成立**。
> 上传时**必须用** `Dist/updates/SafeOut-<VERSION>.dmg` 这个文件名（改名即 404，
> 而 appcast 本身不报任何错）。`make_appcast.sh` 现在会打印该路径，并有一条守卫
> 比对「enclosure 末段」与「待上传文件名」是否逐字相同 —— 这条守卫是补的，
> 因为此前脚本的指引写的是 `SafeOut.dmg`，与 enclosure 不一致。

**updater 必须在启动时建起来**（`applicationDidFinishLaunching` 调
`UpdateController.startIfNeeded()`）：Sparkle **只在 `SPUUpdater.start()` 之后**才按
`SUScheduledCheckInterval` 排期自动检查，不建它一次检查都不会发生。
⚠️ 2026-09-18 实测：这一行调用**此前是缺失的**（`startIfNeeded()` 全仓库只有定义、
没有任何调用点），于是「自动更新」开关、`SUEnableAutomaticChecks=true`、
`SUScheduledCheckInterval=86400` 三样**全都形同虚设**，而界面上完全看不出来
（设置行永远停在「尚未检查」，与「用户没点过检查」长得一模一样）。
现在有守卫 `UpdateSettingsTests.启动链上必须真的建起updater` 钉住（读源码，
且**限定在该函数体内**）。实测自动检查发生在**启动后 2~13 秒**，不是启动瞬间。

**发布说明（新版本弹窗的「本次更新」清单）**：由 `Release-notes/<版本>.html`
（只含 `<ul><li>…</li></ul>`）在生成时经 `RELEASE_NOTES_FILE=…` 传入，
被 `generate_appcast` **内嵌**进 appcast 的 `<description>` —— 界面只读内嵌的那份
（`UpdateUserDriver.showUpdateReleaseNotes` 是空实现，外链的 `sparkle:releaseNotesLink` 它不看）。
不传就没有 `<description>`，弹窗里那一块**不会被画出来**。
⚠️ 说明文件里**不能有 HTML 注释**：解析器 `UpdateReleaseNotes.stripTags` 只剥 `<…>` 尖括号对，
不认注释，注释正文会原样进到弹窗。格式要求见 `Release-notes/README.md`。

打包时 `build_app.sh` 必须做三件事，少一件就是「构建成功、双击打不开」：
① 把 `Sparkle.framework` 拷进 `Contents/Frameworks`；② 给可执行文件补
`@executable_path/../Frameworks` 这条 rpath；③ entitlements 开
`com.apple.security.cs.disable-library-validation`（Hardened Runtime 的库校验会拒绝
没有 Team ID 的自签构建加载第三方 dylib）。三件事各配一条回读校验。

**EdDSA 签名**：`SUPublicEDKey` 由 `SPARKLE_PUBLIC_ED_KEY` 注入；未设置时脚本会警告
且**不写该键**（更新不验签）。私钥用 `generate_keys` 生成并存进钥匙串，
CI 走 `SPARKLE_PRIVATE_KEY` 从 stdin 传入（不落盘）。

**更新相关的界面只有两处**：

| 位置 | 内容 |
|------|------|
| 设置面板「更新」组 | 自动更新开关（`automaticallyChecksForUpdates` + `automaticallyDownloadsUpdates`）+ 「检查更新」行 |
| 新版本弹窗 | 当前 → 新版本、本次更新内容、「稍后」（Esc）/「跳过此版本」/「后台更新并重启」 |

- **「检查更新」那一行是一个状态机，七种画法**（设计稿 `08-update.html` C 段矩阵）：
  `尚未检查 / 已是最新 / 已跳过 / 发现新版本 / 后台下载中 / 已就绪 / 下载失败`。
  判定是纯函数 `UpdateController.rowState(phase:skippedVersion:lastCheck:)`，
  **优先级有语义**：进行中的四态 > 跳过 > 已是最新 > 尚未检查。
  每种状态**能做的事不一样**，所以按钮也跟着状态走（查看更新 / 取消 / 立即重启 / 重试）。
- **「已就绪」那一态不显示「检查更新」按钮**：Sparkle 正在等我们回答 `.install`
  （`sessionInProgress` 为真），此时点「检查更新」没有反应
  （`SPUUpdater.h` 明写）。给一个点了没反应的按钮，与「功能坏了」长得一模一样。
- **「重启」两条路的承诺不一样**（2026-09-25 改判，完整推导见 `Design/ui/v2/DESIGN-SPEC.md` §8.146）：
  - **自动更新那条路**（`SUAutomaticallyUpdate` 开着）：**不自动做，只提供入口** ——
    下载可以完全后台，重启会关掉用户手上的一切；语义是「下次退出时静默装上」。
  - **用户在弹窗里点过「后台更新并重启」**：**下载完自己重启** ——
    弹窗的 `updateCallout` / `updateDownloadingHint` 两句都是这么承诺的；
    只有此刻有卷正在推出时才推迟到推出结束（不打断正在推出的磁盘）。
- **下载失败不染色**：琥珀只表示「磁盘被占用」、红只表示「破坏性动作」，失败两者都不是。
- **用自定义 `SPUUserDriver`，不用 `SPUStandardUserDriver`**：① 设计稿的弹窗与标准弹窗
  不是一回事；② **下载进度只在 user driver 里给**（`showDownloadDidReceiveData` 等），
  而设计稿要把百分比画在设置行上。见 `UpdateUserDriver`。
- **「检查更新」只有这一个入口**：关于行原先那个按钮已删除 —— 同一个动作有两个入口时，
  用户会以为它们做的事不一样。
- 开关在 `SPUUpdater.allowsAutomaticUpdates == false` 时**禁用并说明原因**（未签名构建会命中）。
- **「跳过此版本」记的是版本号**（`AppSettings.Key.skippedVersion`），不是布尔 ——
  布尔会在下个版本上继续沉默。手动点「检查更新」会清掉跳过标记。
- **「自动更新」偏好不另存一份**：真相在 Sparkle 的 `SPUUpdaterSettings` 里，
  再存一份就会有两个真相。
- **改语言必须重启才生效**（macOS 只在启动时读 `AppleLanguages`）→ 设置里有「待重启」第三态，
  且它是**派生**的（`LanguageManager.isRestartPending(preferred:active:)`），不是手动开关。

### 6.4 工程化

| 项 | 内容 |
|----|------|
| CI | `.github/workflows/ci.yml`：代码门槛（`Scripts/preflight.sh --with-tests`）→ 打包验证 → 产物校验 |
| 本地门槛 | `./run.sh check [--with-tests]`，或直接 `./Scripts/preflight.sh`；**与 CI 调用同一文件**，判据不会分叉 |
| CI 结论 | 推送后用 `./run.sh ci` 看结论（默认等它跑完；`--no-wait` 只看当前状态）。退出码 **0=绿 / 1=红 / 2=没拿到结论**（⚠️ 2 ≠ 绿）。起因：CI 曾连续 76 次红没人看 |
| 发布前 | `STRICT_CI=1 ./build_app.sh` —— 打包前先过零警告构建 + 格式门槛 |
| 格式 | `swift-format`，配置 `./.swift-format`（4 空格缩进 / 120 行宽） |
| 覆盖率 | `Scripts/coverage.sh`，**仅统计核心逻辑**（Models/Services/Settings），门槛 40% |
| 版本号 | `build_app.sh` 从 git 自动派生：VERSION ← 最近 tag，BUILD_NUMBER ← 提交数；可用环境变量覆盖 |

三条容易踩空的细节：
- `swift-format lint` **默认即使发现问题也返回 0**，必须加 `--strict` 才能在 CI 中拦截。
- **`build_app.sh` 的 release 构建不带 `-warnings-as-errors`**，所以「打包成功」推不出「CI 会绿」。
  2026-09 就因此让 13 条 Swift 6 并发隔离错误在本地一路绿灯的情况下潜伏三天。改完 `Sources/`
  先跑 `./run.sh check`；提交/发布前用 `STRICT_CI=1 ./build_app.sh`。
- 覆盖率**不把 Views/ 与 App 入口计入分母**：SwiftUI 视图无法在单测中真实驱动，
  计入会让数字被 UI 代码体量主导，对改进不敏感。

---

## 7. 后续扩展（尚未实现）

- Finder 扩展右键菜单
- 磁盘健康状态（SMART）监控
- 主窗口 UI 的自动化测试（当前 UI 层无测试覆盖）
