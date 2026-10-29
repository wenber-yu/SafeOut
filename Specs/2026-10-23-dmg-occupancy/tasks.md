# Tasks — DMG 占用检测与签名修复

> 关联：spec.md（同目录）。按序执行；每步完成后打勾。

## A — DMG 占用检测与分离

- [x] T1 新建 `Sources/Services/DiskImageOccupancy.swift`
  - `AttachedDiskImage`、`DiskImageInfoParser.parse/backing(under:)`（纯函数）、
    `DiskImageOccupancyProvider`（TTL 5s 缓存 + 单飞 + `fetch` 注入点 + `imagesSync()`）
- [x] T2 `Sources/Models/OccupyingProcess.swift`
  - `Kind` 枚举、`kind` 属性（默认 `.process`）、`diskImage(imagePath:device:)` 工厂（FNV-1a 合成负 pid）
- [x] T3 `Sources/Services/ProcessTerminator.swift`
  - `signal` 加 `kind == .process` 与 `pid > 0` 双重 guard
- [x] T4 `Sources/Services/OccupancyDetector.swift`
  - init 加 `diskImageProvider` 注入；`merging(lsof:diskImages:mountPath:)` 纯函数；
    `detect` / `detectSync` 合并 hdiutil 结果
- [x] T5 `Sources/Services/ProcessAppResolver.swift`
  - `enrich` 跳过非 process；`icon(for:)` 对 `.diskImage` 用 `icon(forFile:)`
- [x] T6 `Sources/Services/EjectFlowController.swift`
  - init 加 `detachDiskImage` 注入（生产：`hdiutil detach`，15s 超时）；
    `terminateAndEject` 第 0 步先分离所有 `.diskImage` 条目
- [x] T7 UI
  - `EjectAlertView.processRow`：`.diskImage` 显示 `diskImageKindLabel` 替代 PID
  - `DesignSystemComponents.ProcessChip`：`.diskImage` tooltip 显示 backing 路径、a11y 前缀「磁盘映像」

## C — 诚实文案

- [x] T8 `Sources/Localization/Localizable.xcstrings`
  - 改写 `ejectBusyNoProcessInfo` 三语（含「聚焦索引等系统服务」）
  - 新增 `diskImageKindLabel` 三语

## 测试

- [x] T9 新建 `Tests/SafeOutAppTests/DiskImageOccupancyTests.swift`（解析/匹配/合并/工厂/terminator 防线）
  - 修：plistData 用 `data(fromPropertyList:format:options:)`、helper 补 `devEntries:` 标签、
    lazy var 改计算属性（mutating getter）、`#expect` 内不得 `await`（先落本地常量）
- [x] T10 `EjectFlowControllerTests` 增补 detach 顺序断言；文案相关测试基线更新
- [x] T11 `swift test` 全量通过（601 条绿，含两条守卫修复：重跑 `Tools/build_i18n.py` 同步 i18n.js 指纹；
  `DocTableIntegrityTests.docs` 登记本规格两份文档）
  - ⚠️ 环境教训：本机受管环境必须 `swift test --disable-sandbox`，否则 SwiftPM 沙箱 exec
    plugin-server 报 EPERM，症状与「@TaskLocal 宏 flaky」逐字相同

## B — 签名（**已完成稳定自签**，中途曾按用户决定改 ad-hoc，随后用户清掉钥匙串 ACL 后走通）

- [x] T12 「SafeOut Dev Signing」自签证书（10 年，EKU=codeSigning）已导入 login keychain
  - 根因记录：login.keychain-db 上 `group:everyone deny write` ACL 致一切非 root 写入 EPERM；
    用户 `chmod -N` 清除后导入成功
- [x] T13 `./build_app.sh` 重建：**自签身份签名**（`codesign -dr -` 显示 DR 锚定
  `certificate leaf = H"68022214…"`，FDA 授权此后可跨重建保留）；`--verify --deep --strict`
  通过；已安装到 /Applications
  - 顺带修脚本 bug：`build_app.sh` 第二档检测原用 `find-identity -v`，自签证书恒为
    `CSSMERR_TP_NOT_TRUSTED` ⇒ 该档曾是死代码；已去掉 `-v`（保留 `-p codesigning` EKU 过滤）
- [x] T14 清理 /tmp 私钥与 p12（safeout-dev.{key,crt,p12}、signtest 已删）

## 交付

- [x] T15 告知用户删旧 FDA 条目并重授；真机验证两个游戏 DMG 被列出、「关闭并推出」可推出
  （指引已交付，真机验证由用户执行）
