#!/bin/bash
# PoC 真机 e2e：启动刚打包的 .app → 在 Finder 里点 SpikeVol 的推出 → 看 hook 是否生效。
#
# 前提条件（手动做一次）：
#   1) DISABLE_SANDBOX=1 ./build_app.sh        # 打包 .app 到 Dist/
#   2) /Volumes/SpikeVol 已挂载（脚本会自动 attach .build/probe/da_approval_spike/spike.dmg）
#
# 跑这个脚本能验的三条链路：
#   ① 无占用场景：Finder 点推出 → 立即推出，无我们的弹窗（缓存 .none）
#   ② 有占用场景：保持占用进程活着（脚本里开 tail -f）→ Finder 点推出 → 弹我们的窗
#                  → 杀进程 + Finder 完成推出，**无系统报错框**
#   ③ 自排除：SafeOut 自己点推出 → 立即放行，不卡住
#
# ⚠️ 本脚本会启动 .app 并触发 Finder 推出。会抢占前台。运行后会自动退出 app。
set -e
# ⚠️ **默认 `Dist/SafeOut.app`，但那个目录会被 safe-delete 守卫挡住**：
# `build_app.sh` 要删旧 `.app` 里上百个文件（> 阈值 5）⇒ 脚本停在 `[2/5]`，
# `Dist/` 里留下的是**旧日期**的包（拿去验就会验错版本，2026-09-28 实测踩过）。
# ⇒ 用新目录构建后，用 `APP=…` 覆盖：
#     OUTPUT_DIR=/tmp/de DISABLE_SANDBOX=1 ./build_app.sh
#     APP=/tmp/de/SafeOut.app ./Scripts/poc_e2e.sh
APP="${APP:-Dist/SafeOut.app}"
SPIKE=".build/probe/da_approval_spike/spike.dmg"
LOG_OUT=".build/probe/poc_e2e_$(date +%s).log"

if [ ! -d "$APP" ]; then
    echo "❌ 找不到 $APP —— 先跑 DISABLE_SANDBOX=1 ./build_app.sh（或用 APP=… 指定）"
    exit 1
fi
if [ ! -f "$SPIKE" ]; then
    echo "❌ 找不到 $SPIKE —— spike.dmg 应在 .build/probe/da_approval_spike/ 下"
    exit 1
fi

# 把脚本自己的输出 + 应用日志一起落盘（避免「看不到输出」这一族坑）
mkdir -p "$(dirname "$LOG_OUT")"
exec > >(tee -a "$LOG_OUT") 2>&1
echo "=== PoC e2e 开始于 $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "日志: $LOG_OUT"

# ① 准备测试盘
if [ ! -d /Volumes/SpikeVol ]; then
    echo "--- attach spike.dmg ---"
    hdiutil attach "$SPIKE"
    sleep 1
fi
ls -d /Volumes/SpikeVol

# ② 在 SpikeVol 上写一个文件 + 启动一个会持续保持 fd 的进程（构造占用）
KEEP_FILE=/Volumes/SpikeVol/keep.txt
if [ ! -f "$KEEP_FILE" ]; then echo "x" > "$KEEP_FILE"; fi
# 用 `tail -f` 持续读这个文件（保持 fd 直到被杀）
KEEPER_PID=""
if ! pgrep -f "tail -f $KEEP_FILE" >/dev/null; then
    tail -f "$KEEP_FILE" >/dev/null 2>&1 &
    KEEPER_PID=$!
    echo "占用进程 PID=${KEEPER_PID}（tail -f ${KEEP_FILE}）"
fi
# 给 OccupancyStore 一次轮询窗口（默认 15s；生产里轮询启动后会在第一时间
# 拿当前值，但首次跑一次要等一个 tick）
echo "等 18s 让 OccupancyStore 第一次轮询填上占用缓存…"
sleep 18

# ⚠️ **必须先打开开关**：`takeOverFinderEject` 默认**关**，而判定层第一关就是
# 「开关关 ⇒ 放行」⇒ 不打开它，本脚本**永远看不到弹窗**，而它的输出
# 与「hook 坏了」**逐字相同**（2026-09-28 实测：不打开时只有「已注册」一行日志）。
# 结束时会还原成原值。
echo "--- 打开「接管访达的推出」开关（结束会还原）---"
TAKEOVER_ORIG="$(defaults read com.safeout.app takeOverFinderEject 2>/dev/null || echo MISSING)"
defaults write com.safeout.app takeOverFinderEject -bool true

# 启动 .app
echo "--- 启动 $APP ---"
open "$APP"
sleep 3

# 看 hook 是否注册了
echo "--- 看 hook 注册日志（最近 5s）---"
/usr/bin/log show --predicate 'subsystem == "com.safeout.app" AND category == "EjectHook"' --last 5s --style compact

# 触发 Finder 推出（会触发我们的 hook；如果有占用，会弹我们的窗）
echo "--- 触发 Finder eject /Volumes/SpikeVol ---"
osascript -e 'tell application "Finder" to eject disk "SpikeVol"' &
EJECT_PID=$!
echo "Eject 异步启动 PID=${EJECT_PID}；窗口上若弹出占用窗，请手动点「关闭并推出」或「取消」"

# ⚠️ **截屏「弹窗真的画出来了」**：日志里的「拦截」只证明**进了弹窗那一段**，
# 不证明窗口真的在屏上 —— 两者是两件事，而「没画出来」与「画出来了但你没看见」
# 在日志上逐字相同。2026-09-28 实测：`windowid.swift 磁盘推出助手` 查到
# `400x300 onscreen=1 即将推出「SpikeVol」`，截图里占用者 `tail` 与 PID 都在。
# ⚠️ 窗口拥有者是**本地化中文名**（「磁盘推出助手」），按英文名一条都找不到。
echo "等 10s 让弹窗出现，然后截屏…"
sleep 10
WINS=.build/probe/poc-wins.txt
if swift Tools/probe/windowid.swift 磁盘推出助手 > "$WINS" 2>/dev/null && [ -s "$WINS" ]; then
    cat "$WINS"
    while IFS=$'\t' read -r win_id _owner _size _onscreen _title; do
        screencapture -x -o -l"$win_id" ".build/probe/poc-shot-$win_id.png" \
            && echo "已截窗口 $win_id → .build/probe/poc-shot-$win_id.png"
    done < "$WINS"
else
    echo "⚠️ 没有「磁盘推出助手」的在屏窗口 —— 弹窗没画出来（或不在当前会话/空间）"
fi

# 等用户操作 + 推出完成（手动操作可能需要几秒）
echo "再等 10s 等你点「关闭并推出」…"
sleep 10

# 看应用日志
echo "--- EjectHook 日志（最近 40s）---"
/usr/bin/log show --predicate 'subsystem == "com.safeout.app" AND category == "EjectHook"' --last 40s --style compact

# 看 EjectService 日志（自排除应该出现）
echo "--- EjectService 日志（最近 40s）---"
/usr/bin/log show --predicate 'subsystem == "com.safeout.app" AND category == "EjectService"' --last 40s --style compact

# 最终状态
echo "--- /Volumes/SpikeVol 状态 ---"
ls -d /Volumes/SpikeVol 2>&1

# 关 app（PoC 测试结束）
echo "--- 退出 app ---"
osascript -e 'tell application id "com.safeout.app" to quit' 2>/dev/null || true

# 还原开关：⚠️ 别留一个「开着」的残留 —— 不然你下次在访达点推出会莫名弹窗
if [ "$TAKEOVER_ORIG" = "MISSING" ]; then
    defaults delete com.safeout.app takeOverFinderEject 2>/dev/null || true
else
    defaults write com.safeout.app takeOverFinderEject -bool "$TAKEOVER_ORIG"
fi
echo "开关已还原（原值：${TAKEOVER_ORIG}）"

# 杀占用进程（如果是脚本启动的）
if [ -n "$KEEPER_PID" ]; then kill "$KEEPER_PID" 2>/dev/null || true; fi

echo "=== PoC e2e 结束于 $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "完整日志: $LOG_OUT"