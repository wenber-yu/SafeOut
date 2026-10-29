# Spec — DMG 镜像/聚焦索引占用导致外置盘无法推出且 SafeOut 显示「无占用」

> 日期：2026-10-23
> 状态：**待用户确认**
> 范围：用户已确认 A + B + C 全做

---

## 1. 问题与根因（已实测确认，不再重复调查）

**现象**：外置硬盘 `/Volumes/wenbo-data` 上打开过两个游戏 DMG；访达与本应用都推不出，
SafeOut 显示「当前没有应用占用」。`hdiutil info` 可见这两个 DMG 的 `image-path` 就在该卷上，
聚焦索引（`mds_stores`）也在占用。

**根因（两条叠加）**：

1. **SafeOut 是 ad-hoc 签名**（`build_app.sh` 294–299 行兜底分支；本机钥匙串 0 个代码签名身份）。
   ad-hoc 二进制的 TCC/完全磁盘访问（FDA）授权按 cdhash 记录，**每次重新构建 cdhash 都变**，
   系统设置里开关仍显示「开」但实际已失效。
2. **无有效 FDA 时 `lsof` 只能看到同 uid 进程**。访达挂载的 DMG 由 `diskimagesiod`
   （uid `_diskimagesiod`）持有，聚焦索引由 `mds_stores`（uid `_mds_stores`）持有，
   两者对 SafeOut 的 `lsof -Fpcn0 <mountPath>` 均不可见 → 检测为空 →
   `OccupancyResult.needsFullDiskAccess` → `DiskRowState.unknown` → 界面**不渲染占用行**，
   用户读作「没有占用」。

**实证**：error.log（10-13 09:28–09:32）11 条「推出被占用: 未能列出占用进程」；
真机复现确认 hdiutil 可见、lsof 不可见。

## 2. 修复方案（三项）

### A — DMG 占用检测：`hdiutil info -plist`（无需 FDA）

核心事实：`hdiutil info` 是用户级 API，**无 FDA 也能列出所有已附着映像**（`image-path` + `/dev/diskN`）。
把「backing 文件位于目标卷上」的映像合成为占用条目，合并进现有检测结论。
「关闭并推出」时用 `hdiutil detach diskN`（用户附着的映像用户有权分离）释放占用，而不是发信号。

### B — 稳定自签名身份（治本：FDA 授权不再随构建失效）

创建 10 年有效的自签名代码签名证书「SafeOut Dev Signing」，`build_app.sh` 会自动选中它
（现有逻辑按身份可用性选择）。此后 FDA 按证书哈希记录，重构不失效。
用户需在系统设置里删除旧的 SafeOut FDA 条目并**重授一次**。

### C — 查不出占用进程时的诚实文案

现有文案只引导授权；补充「聚焦索引等系统服务也会占用」这一可能，避免用户误以为应用坏了。

## 3. 精确改动清单

### 3.1 新文件 `Sources/Services/DiskImageOccupancy.swift`

```swift
struct AttachedDiskImage: Sendable, Equatable {
    let imagePath: String   // backing 文件完整路径
    let device: String      // 顶层设备，如 /dev/disk6（detach 的目标）
}
```

- `enum DiskImageInfoParser`（纯函数，可离线单测）：
  - `static func parse(plist: Data) -> [AttachedDiskImage]`
    用 `PropertyListSerialization` 解析 `hdiutil info -plist` 输出：
    顶层 `images` 数组 → 每项取 `image-path`；`system-entities` 数组中所有 `dev-entry`
    **按字符串长度升序取第一个**作为顶层 device（`/dev/disk6` 比分区 `/dev/disk6s1` 短）。
    无 `image-path` 或无任何 `dev-entry` 的项跳过。
  - `static func backing(under mountPath: String, of images: [AttachedDiskImage]) -> [AttachedDiskImage]`
    前缀匹配 `mountPath + "/"`（**必须带尾斜杠**，否则 `/Volumes/data2` 误中 `/Volumes/data`）。
- `final class DiskImageOccupancyProvider: @unchecked Sendable`
  - `static let shared`；`init(fetch:)` 开放测试注入。
  - `func images() async -> [AttachedDiskImage]?`（`nil` = 获取失败，上层按「无 DMG 贡献」处理）。
  - 实现：`/usr/bin/hdiutil info -plist`，复用 `SubprocessOutput`，超时 5s。
  - **TTL 缓存 5s + 单飞**（NSLock + 等待中的 continuation 数组）：
    `hdiutil info` 是全局调用，而 `detect(mountPath:)` 被 `OccupancyStore` 按盘并行调用、
    推出路径还会再调，不能每盘各跑一次。

### 3.2 `Sources/Models/OccupyingProcess.swift`

- 新增 `enum Kind: Sendable, Equatable { case process; case diskImage(device: String) }`。
- 新增 `let kind: Kind`，现有 init 加默认参数 `kind: Kind = .process`（现有调用点零改动）。
- 新增工厂 `static func diskImage(imagePath: String, device: String) -> OccupyingProcess`：
  - `pid` 用**合成负值**：`-1 - Int32(FNV1a32(device) & 0x3FFFFFFF)`。
    理由：同一 device 每次检测得到相同 id（SwiftUI diff 不闪行）；负值永不与真 pid 冲突。
    Swift 自带 `hashValue` 每次运行随机化，**不可用**；文件内写一个 8 行 FNV-1a。
  - `processName` / `displayName` = `imagePath` 末段文件名（含 `.dmg`）；`path = imagePath`。
- Equatable 维持合成（加 `kind` 后仍正确）。

### 3.3 `Sources/Services/ProcessTerminator.swift`（kill(0) 防线）

- `signal(_:signal:...)` 循环开头加 `guard process.kind == .process else { continue }`：
  DMG 条目**既不发信号、也不计入 unkillable**（分离由 detach 流程负责）。
  ⚠️ 这是硬性安全线：合成 pid 若漏到 `kill()`，负值/0 在 POSIX 里是「整个进程组」语义。
- 防御纵深：同一循环再加 `guard process.pid > 0 else { continue }`（真 pid 恒 > 0）。
- `clear(...)` 不改：`signal` 层已挡，escalated 过滤基于其返回值。

### 3.4 `Sources/Services/OccupancyDetector.swift`

- 加实例属性 `let diskImageProvider: DiskImageOccupancyProvider`，init 默认 `.shared`
  （init 已开放测试注入；mock 返回 `nil` 时行为与现状**逐字一致**，旧测试不受影响）。
- 新增纯静态合并函数（单测靶子）：
  `static func merging(lsof: [OccupyingProcess], diskImages: [AttachedDiskImage], mountPath: String) -> [OccupyingProcess]`
  - `diskImages` 先过 `backing(under:)`，映射为 `OccupyingProcess.diskImage(...)`；
  - 若映像非空：从 lsof 结果剔除 `processName == "diskimagesiod"`（它只是 holder，
    用户杀不掉它，显示出来只会误导；映像条目才是可操作的）；
  - 返回 进程 + 映像 的合并列表（进程在前）。
- `detect(mountPath:)`：
  - lsof 解析后，无论空与否，`await diskImageProvider.images()` 并调 `merging(...)`；
  - 合并后非空 → `.occupied(await ProcessAppResolver.enrich(...))`
    （enrich 只会碰 `.process` 条目，见 3.5）；
  - 合并后为空 → 维持原兜底（`authorized ? .none : .needsFullDiskAccess`）。
  - **关键行为变化**：无 FDA + 卷上有 DMG ⇒ 直接 `.occupied`，不再落 `.needsFullDiskAccess`。
- `detectSync(mountPath:)`（diagnostics）：同样合并；provider 加同步变体
  `imagesSync()`（仿 `lsofOutputSync` 的 run-loop 等待写法）。

### 3.5 `Sources/Services/ProcessAppResolver.swift`

- `enrich(_ process:)` 开头：`guard process.kind == .process else { return process }`。
- `icon(for:)`：`switch process.kind` → `.diskImage` 返回
  `NSWorkspace.shared.icon(forFile: process.path)`（系统给的磁盘映像白盒图标）；`.process` 走原逻辑。

### 3.6 `Sources/Services/EjectFlowController.swift` — `terminateAndEject`

- init 加注入 `detachDiskImage: (String) async -> Void`，生产实现：
  `/usr/bin/hdiutil detach <device>`（`SubprocessOutput`，超时 15s）。
  **不单独判成败**：第 3 步复检走 `occupancyDetector.detect`（含 hdiutil），
  分离失败的映像会自然回到 `.busy(remaining)` 链路交给 UI。
- 流程改为**第 0 步**（在 SIGTERM 之前）：
  对 `processes` 中 `kind == .diskImage` 的条目逐个 `await detachDiskImage(device)`。
  其余步骤（SIGTERM → 1.5s → 等 inFlight → 复检 SIGKILL → 0.8s → 重试推出）不动。
- **边界**：普通 `eject(disk:)` **永不 detach**——分离映像等同于关应用，必须用户点过
  「关闭并推出」才做。

### 3.7 `Sources/Services/EjectHookService.swift`

**不改代码**。快照（`OccupancySnapshotStore`）由 `OccupancyStore` 轮询写入，
检测器合并 hdiutil 后快照自动携带 DMG 条目；提醒文案走 `displayName`（映像文件名）自动正确。
明确决策：DA approval 线程上**不跑子进程**（不做 hook 侧 detach），用户经提醒卡片走
`EjectUI` → `terminateAndEject` 完成分离。

### 3.8 UI 三处

- `Sources/Views/EjectAlertView.swift` `processRow(_:striped:)`（~L300）：
  `kind == .diskImage` 时，原「PID %d」位置显示新键 `diskImageKindLabel`（磁盘映像 / Disk Image / 磁碟映像）。
- `Sources/Views/DesignSystemComponents.swift` `ProcessChip`：
  `tooltip` 分支——`.diskImage` 时显示 `process.path`（backing 文件完整路径，用户可自证是哪个文件）；
  `accessibilityLabel` 前加「磁盘映像」。图标走 `ProcessAppResolver.icon(for:)` 自动生效（3.5）。
- `Sources/Views/DiskRow.swift` / `EjectAttentionCenter`：**不改**——
  占用行文案与提醒均走 `displayName` 拼接，映像以文件名自然出现。

### 3.9 `Sources/Localization/Localizable.xcstrings`

- 改写 `ejectBusyNoProcessInfo`（三语），承认聚焦索引可能：
  - zh-Hans：`磁盘「%@」正被占用，但查不出是哪些程序——聚焦索引等系统服务也会这样。请到「系统设置 › 隐私与安全性 › 完全磁盘访问」允许 %@ 后重试。`
  - en：`"%@" is in use, but we can't tell which apps — system services like Spotlight indexing can also hold it. Allow %@ under System Settings › Privacy & Security › Full Disk Access, then try again.`
  - zh-Hant：`磁碟「%@」正被佔用，但查不出是哪些程式——聚焦索引等系統服務也會這樣。請到「系統設定 › 隱私權與安全性 › 完全磁碟存取」允許 %@ 後重試。`
- 新增 `diskImageKindLabel`：磁盘映像 / Disk Image / 磁碟映像。

### 3.10 B — 自签名证书与重签（shell 操作，非代码）

1. `security find-identity -p codesigning -v` 确认现状为空。
2. openssl 生成：`openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
   -subj "/CN=SafeOut Dev Signing" -addext "extendedKeyUsage=codeSigning" \
   -addext "keyUsage=digitalSignature" -keyout /tmp/safeout-dev.key -out /tmp/safeout-dev.crt`，
   合并导出 p12，`security import` 入 login keychain，
   `security set-key-partition-list -S apple-tool:,apple:,codesign:` 免弹窗。
3. 验证 `security find-identity -p codesigning -v` 列出该证书。
4. `./build_app.sh` 重建（自动选中该身份）→ `codesign -dr - Dist/SafeOut.app`
   确认 DR 含证书哈希（不再是裸 `cdhash H"..."`）→ `codesign --verify --deep --strict` 通过
   → 安装到 /Applications（跟随 build_app.sh 现有安装逻辑）。
5. 清理 /tmp 私钥。
6. **告知用户**：系统设置 › 隐私与安全性 › 完全磁盘访问：删除旧 SafeOut 条目 → 重新添加。

## 4. 测试计划（`swift test` 全量必须保持绿，581+）

新增 `Tests/SafeOutAppTests/DiskImageOccupancyTests.swift`：

1. **plist 解析**：fixture 含 2 张映像（一张 backing 在 `/Volumes/wenbo-data`、一张在别处），
   断言解析出正确 imagePath 与顶层 device（分区 dev-entry 存在时选短的）。
2. **backing(under:)**：`/Volumes/data` 不误中 `/Volumes/data2`；精确命中带子路径的 backing。
3. **merging(...)**：
   - lsof 含 `diskimagesiod` + 有映像 → diskimagesiod 被剔除、映像在内；
   - lsof 空 + 有映像 → 结果非空（⇒ `.occupied` 而非 `.needsFullDiskAccess`）；
   - 无映像 → 原样返回 lsof 列表。
4. **OccupyingProcess.diskImage 工厂**：pid 为负、同 device 两次构造 pid 相同、displayName 为文件名。
5. **ProcessTerminator.signal**：列表含 diskImage 条目时，kill 替身**零调用**、返回值不含该条目。
6. **terminateAndEject**：注入 `detachDiskImage` 记录型替身 + mock detector/ejectService，
   断言 detach 在 SIGTERM 之前发生、device 正确（沿用 `EjectFlowControllerTests` 现有注入模式）。
7. **文案**：`busyMessage(occupying: [])` 三语快照断言更新（现有本地化测试基线同步改）；
   `LocalizationCatalogTests` 的键完整性自动覆盖新键三语齐全。

既有测试不受影响的理由：detector 的 provider 注入默认 shared、mock 返 `nil` 时行为逐字不变；
enrich/icon/terminator/UI 的新分支都以 `kind == .process` 为默认路径。

## 5. 验证步骤

1. `swift test` 全绿。
2. `./build_app.sh` 重签成功，DR 基于证书。
3. 真机（不重授 FDA 也可验 DMG 检测）：打开主窗口 → `/Volumes/wenbo-data` 应列出
   两个游戏 DMG 为占用者（磁盘映像图标 + 文件名）。
4. 点「关闭并推出」→ 两个 DMG 被 detach → 盘推出成功。
5. 重授 FDA 后：`lsof` 可见系统进程，Spotlight 占用时列表能显示 `mds_stores`；
   未授权时弹窗文案含「聚焦索引等系统服务」。

## 6. 明确的非目标

- 不拦截/强卸 Spotlight 索引本身（系统服务，无权也无该杀）。
- 不在 DA approval 线程跑任何子进程（hook 侧只读快照）。
- 不动 `EjectHookPolicy` 判定逻辑、`OccupancyStore` 轮询结构、设计令牌。
- 普通「推出」路径永不 detach 映像。

## 7. 风险

| 风险 | 缓解 |
|------|------|
| 合成负 pid 漏进 `kill()`（进程组信号灾难） | `signal` 双重 guard（kind + pid>0）；单测钉住 |
| hdiutil 每盘并行重复调用 | provider TTL 缓存 + 单飞 |
| detach 失败被当成成功 | 不判退出码，复检由 detect 权威兜底，失败映像回到 `.busy` |
| 旧 FDA 条目残留导致用户以为没生效 | 交付说明里明确「删旧条目→重授」一步 |
