# 转向决策：接管推出 → 推出时提醒占用

> 状态：待用户拍板。本文档取代 `Design/prd/incremental-takeover-finder-eject.md` 与
> `Design/architecture/incremental-takeover-finder-eject.md` 中「拦截 + 弹窗」的核心前提。
>
> 起因：v2026.09.29 真机验收（用户真实 Finder 操作）复现「点取消后仍弹系统框」，
> 追根到底发现是 **Disk Arbitration 协议不支持「静默取消」**，不是实现 bug。

## 1. 结论（一句话）

「接管系统推出」在 DA approval 回调机制下**做不出**用户要的「点取消 = 盘保持挂载、
零弹窗」。正确产品形态是**放弃拦截，改为「放行 + 菜单栏提醒占用」**。

## 2. 为什么必须转向（证据链）

### 2.1 DA 协议只有两个合法回执

Apple 官方文档（DiskArbitration Programming Guide）原文：

> Return **NULL** if you want to allow the operation to complete.
> Return a **DADissenterRef** object to cancel the operation.

没有「静默取消」这个第三态。两条路都必然弹系统框：

| 回执 | 系统行为 | 系统框 |
|---|---|---|
| `return nil`（放行） | 继续 unmount | 盘被占用 → 弹「占用中」框 |
| `return dissenter`（拒绝） | 放弃推出 | 弹「未能推出」框 + Finder 重试风暴 |

### 2.2 真机时间线（用户 2026-09-29 真实操作）

```
08:43:54 拦截 mount=/Volumes/SpikeVol 占用=1      ← 点推出，弹应用窗
08:43:58 取消 → return nil（放行）
08:43:58~08:44:26 连续 13 次 dedupHit 放行          ← Finder 重试被去重挡住（正确）
08:44:29 拦截                                     ← 第二次点推出，又弹应用窗
08:44:37 8s 超时 → cancel → 放行                    ← 系统又弹「占用中」框
```

用户看到的三个现象，全是「放行」的必然结果：
1. 点「取消」→ 放行 → Finder 推不动 → 弹系统框；
2. 系统框不关 → Finder 卡在这次推出里 → 再点推出没反应；
3. 不点应用窗 → 8s 超时 → 放行 → 系统框又冒出来。

### 2.3 此前两轮修复为什么都翻车

- `85b1dd3`：删去重窗口 → Finder 重试风暴，反复弹窗（方向对一半，错在把去重当 bug 删了）。
- `2cee7b4`：取消改「放行」→ 重试被去重挡住（这部分对），但「放行」本身会弹系统框
  （这部分错——把「取消」映射到了「放行」，而放行的语义是「继续推」）。

两轮都在「放行 vs 拒绝」的二选一里打转，没跳出来看到：**协议根本没有用户要的第三态**。

## 3. 转向成什么（目标形态）

**核心转变**：回调不再「拦截 + 卡住 Finder」，而是「**立即放行 + 异步提醒**」。

```
用户点 Finder 推出
  → approval 回调立即 return nil（放行，不阻塞、不弹窗）
  → 同时异步记下「这块盘被占用、谁在占」
  → 系统走原生流程：推不动 → 弹 macOS 原生「占用中」框（诚实提示）
  → 菜单栏图标亮起小圆点/变色，点开面板顶部出现「X 占用 Y，[关闭并推出]」
  → 用户点「关闭并推出」→ 复用现有 terminateAndEject 清场 + 推出
```

**我们的价值点不再是「替系统接管推出」，而是「系统框弹出时，立刻告诉用户谁在占、
一键关闭」**。这绕开了「静默取消」的协议死结，也不跟系统框抢戏。

## 4. 三个已定决策（用户拍板）

1. **介入形态 = 菜单栏提示**（菜单栏图标持久状态 + 面板顶部卡片），不做自动弹窗
   （自动弹窗会与系统框叠罗汉，重蹈覆辙）。
2. **拆除旧拦截逻辑**，重建为「放行 + 提醒」，不保留双开关。
3. **开关改名**（不新增设置行，规避 480×920 固定高度约束）：
   `takeOverFinderEject`「接管访达的推出」→ 语义改为「推出时提醒占用」，
   三语文案同步改。

## 5. 落地范围（改动清单）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `Sources/Services/EjectHookPolicy.swift` | 删 `.intercept` 决策、`.allow/.passThrough` 二分、`userDecisionTimeout`、`resolve()`；判定命中占用时返回新结论「提醒」（放行 + 携带占用信息） |
| 2 | `Sources/Services/EjectHookService.swift` | `handle` 不再 `waitForUserChoice`（删信号量）；命中占用 → `return nil` + `Task @MainActor` 发提醒 |
| 3 | 菜单栏（`SafeOutApp.swift` + `MenuPopoverView.swift`） | 新增持久「待处理占用」状态源，驱动图标状态 + 面板顶部卡片，复用 `DiskRow`「关闭并推出」 |
| 4 | `Sources/Localization/Localizable.xcstrings` | 开关名 + 说明三语改写 |
| 5 | `Tests/.../EjectHookPolicyTests.swift` 等 | 删拦截/去重/resolve 旧测试，补「命中占用即放行并提醒」新测试 |
| 6 | `Scripts/test/eject_hook_mutation.py` 等变异脚本 | 同步改写变异点 |
| 7 | `EjectAlertView.swift` / `EjectAlertPresenter.swift` / `EjectUI.swift` | 评估删除或保留（弹窗不再是接管链路的一部分，但「关闭并推出」确认框可能仍复用） |

## 6. 待确认的残余问题（动手前需定）

1. **`EjectAlertPresenter` / `EjectAlertView` 是否删除？**
   - 旧接管链路里它承载「拦截弹窗」；新方案里不再拦截，这个 presenter 可能失去唯一调用点。
   - 但 `EjectUI` 里还有「从主窗口主动推出时的占用确认弹窗」，那条链路**保留**。
   - 需确认：旧「接管弹窗」的代码是否连根拔，还是仅摘掉 `EjectHookService` 对它的调用。

2. **菜单栏「待处理占用」的消失时机**：用户点「关闭并推出」成功后清除？还是盘推出后自动清除？
   还是手动点 × 清除？建议：盘推出（disappear）或用户处理成功后自动清，不留手动入口。

3. **FDA 未授权时**：占用者列不出来，菜单栏提醒显示什么？（建议：显示「有程序占用但无法列出，
   需完全磁盘访问」，与现有 `takeOverFinderEjectNeedsFDA` 文案对齐。）

## 7. 验证策略（沿用现有分层纪律）

- 判定/编排 → 单元测试（重写）。
- 回调「放行 + 提醒」→ 真机 spike（复用 `.build/probe/da_approval_spike/`）。
- 菜单栏提示 + 一键关闭 → 真机 e2e（复用 `Scripts/e2e_click_takeover.sh`，改断言：
  从「拦截」改为「放行 + 提醒出现 + 点关闭并推出后盘推出」）。
- 门槛：全量测试、14 道 preflight、变异测试、覆盖率 ≥ 40%。
