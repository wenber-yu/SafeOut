#!/usr/bin/env bash
#
# e2e_click_takeover.sh —— 「接管访达的推出」的**全自动**真机端到端验证。
#
# ## 它补的是哪一环
#
# 本功能的验证分层此前缺最后一格：
#
# | 层 | 状态 |
# |---|---|
# | 判定层 / 编排层 | ✅ 单测（37 条） |
# | DA 回调机制（真机） | ✅ `da_approval_spike/`（09-25） |
# | 产品版拦截 + 弹窗（真机） | ✅ 2026-09-28 |
# | **在弹窗上点「关闭并推出」那一下** | ❌ **本脚本补它** |
#
# 那一环之所以一直空着，是因为 `System Events` 的两条路都拿不到 SwiftUI 的按钮
# （`click button … of window 1` 报 `-1728`，`entire contents` 返回空），
# 于是「点不动」与「没点」在证据上分不开。
# 2026-09-28 实测修正：不是「按钮没暴露给辅助功能」，而是**桥接层读不到** ——
# `AXUIElement` 原生 API 看得到两个按钮（见 `Tools/probe/axdump.swift`）。
# 于是这一环也能自动化：`Tools/probe/clickbutton.swift`（AX 定位 + CGEvent 注入）。
#
# ## 验证链（任一环断了就失败，每环都有可复现的证据）
#
#   1. 挂载测试盘（`spike.dmg`）
#   2. 起**真实占用进程**（`tail -f` 持着盘上的文件）
#   3. **打开「接管访达的推出」开关** ← 默认是关的！
#   4. 启动产品版 app（不是 spike 的 watcher）
#   5. 让**真实访达**发起推出（`osascript … Finder eject`）
#   6. 断言：盘仍在（拦住了）+ 日志记下 `拦截 … 占用=N`
#   7. **真实鼠标点击**弹窗上的「关闭并推出」
#   8. 断言：占用进程被终止、盘**真的推出**、日志记下清场与重试
#
# ⚠️ 第 3 步漏掉的话，跑出来与「hook 坏了」**逐字相同**（判定层第一关就是
# 「开关关 ⇒ 放行」）—— 这是最容易让人白跑一趟的地方，所以脚本强制打开并在收尾还原。
#
# ## 用法
#
#     source Tools/clt_swift_env.sh
#     ./Scripts/e2e_click_takeover.sh                 # 看到弹窗就点（默认 CLICK_DELAY=0）
#     CLICK_DELAY=6 ./Scripts/e2e_click_takeover.sh   # 等 6s 再点
#     APP=/path/to/X.app ./Scripts/e2e_click_takeover.sh
#
# `CLICK_DELAY` 是**自变量**，不是「随便等一等」：用它扫出「用户决策窗口」这条边界的
# 实测值（见第 7 步的注释）。大于决策窗口（现在 8s）时弹窗会**自己先收掉**，
# 脚本会把它判成「超时保护生效」而不是失败。
#
# 需要：本机给该 app「完全磁盘访问」（否则无法列出占用者，弹窗内容不同）、
# 辅助功能 + 事件注入授权（`clickbutton` 会自证）。
#
# ⚠️ **bash 3.2（macOS 自带）的一个坑，本脚本里踩过**：`$VAR` **紧跟全角字符**时，
# 变量名会把后面那些多字节字节一起吃掉 ⇒ `STAMP<乱码>: unbound variable`，
# 而 `set -u` 会因此让**整个脚本当场退出**（表现为「跑 1 秒就没了、log 都没建」）。
# 所以凡 `$VAR` 后面不是 ASCII 空格/标点的，一律写 `${VAR}`。
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

APP="${APP:-$REPO/Dist/SafeOut.app}"
SPIKE="$REPO/.build/probe/da_approval_spike/spike.dmg"
VOLUME="/Volumes/SpikeVol"
BUNDLE_ID="com.safeout.app"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPO/.workbuddy/verify/e2e-click-$STAMP.log"
APP_OUT="$REPO/.workbuddy/verify/e2e-click-$STAMP.app.log"
APP_ERR="$REPO/.workbuddy/verify/e2e-click-$STAMP.app.err"
FAILURES=0

mkdir -p "$REPO/.workbuddy/verify"
exec > >(tee "$LOG") 2>&1

echo "=== 接管访达推出 · 全自动端到端（${STAMP}）==="
echo "app = $APP"
echo "日志 = $LOG"

fail() {
    echo "❌ $*"
    FAILURES=$((FAILURES + 1))
}
ok() { echo "✅ $*"; }

# --- 前置检查 ---------------------------------------------------------------
[ -d "$APP" ] || { echo "❌ 找不到 $APP —— 先跑 OUTPUT_DIR=<目录> DISABLE_SANDBOX=1 ./build_app.sh"; exit 1; }
[ -f "$SPIKE" ] || { echo "❌ 找不到测试盘 $SPIKE"; exit 1; }

# 探针**编译成二进制**再用：`swift script.swift` 每次都要重新编译（1~2s），
# 而本脚本要**轮询**「弹窗出来了没」（0.2s 一次）—— 用解释模式会把轮询拖成龟速，
# 测出来的「滞后」全是编译时间，不是产品行为。
PROBE_BIN="$REPO/.build/probe/bin"
mkdir -p "$PROBE_BIN"
for probe in windowid axdump clickbutton; do
    source_file="$REPO/Tools/probe/$probe.swift"
    if [ ! -x "$PROBE_BIN/$probe" ] || [ "$source_file" -nt "$PROBE_BIN/$probe" ]; then
        swiftc -O "$source_file" -o "$PROBE_BIN/$probe" || { echo "❌ 编不出探针 ${probe}（没 source Tools/clt_swift_env.sh？）"; exit 1; }
    fi
done
echo "探针就绪：$PROBE_BIN"

cleanup() {
    echo "--- 收尾 ---"
    pkill -f "tail -f $VOLUME" 2>/dev/null
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null
    sleep 1
    # 开关还原：记下原值，原值不存在就把键删掉（别留一个用户没设过的偏好）
    if [ -n "${TAKEOVER_ORIG:-}" ]; then
        defaults write "$BUNDLE_ID" takeOverFinderEject -bool "$TAKEOVER_ORIG"
    else
        defaults delete "$BUNDLE_ID" takeOverFinderEject 2>/dev/null
    fi
    hdiutil detach "$VOLUME" 2>/dev/null | tail -1
    echo "--- 收尾完成（盘: $(ls -d "$VOLUME" 2>&1)）---"
}
trap cleanup EXIT

# 别让上一轮的残留污染结果
pkill -f "SafeOut.app/Contents/MacOS" 2>/dev/null
pkill -f "tail -f $VOLUME" 2>/dev/null
[ -d "$VOLUME" ] && hdiutil detach "$VOLUME" >/dev/null 2>&1
sleep 1

TAKEOVER_ORIG="$(defaults read "$BUNDLE_ID" takeOverFinderEject 2>/dev/null || true)"
echo "开关原值 = ${TAKEOVER_ORIG:-<不存在>}"
if [ -d "$VOLUME" ]; then
    fail "测试盘 $VOLUME 还挂着（上面 detach 失败）——先手工处理"
    exit 1
fi

# --- 1 / 2 / 3 --------------------------------------------------------------
echo "--- [1] 挂载测试盘 ---"
hdiutil attach "$SPIKE" | tail -1 || { fail "挂载失败"; exit 1; }
sleep 1
[ -d "$VOLUME" ] || { fail "$VOLUME 没出现"; exit 1; }
ok "测试盘已挂载"

echo "--- [2] 起真实占用进程 ---"
echo "keep" > "$VOLUME/keep.txt"
tail -f "$VOLUME/keep.txt" >/dev/null 2>&1 &
KEEPER=$!
sleep 1
kill -0 "$KEEPER" 2>/dev/null || { fail "占用进程没起来"; exit 1; }
ok "占用进程 PID=${KEEPER}（tail -f 持着盘上的文件）"

echo "--- [3] 打开「接管访达的推出」开关（不打开 ⇒ 一定放行，与 hook 坏了分不开）---"
defaults write "$BUNDLE_ID" takeOverFinderEject -bool true
ok "开关已开：$(defaults read "$BUNDLE_ID" takeOverFinderEject)"

# --- 4 -----------------------------------------------------------------------
echo "--- [4] 启动产品版 app ---"
rm -f "$APP_OUT" "$APP_ERR"
open -n "$APP" --stdout "$APP_OUT" --stderr "$APP_ERR"
sleep 15
pgrep -f "SafeOut.app/Contents/MacOS" >/dev/null || { fail "app 没起来"; exit 1; }
ok "app 已启动"

# --- 5 -----------------------------------------------------------------------
echo "--- [5] 触发真实访达推出 ---"
TRIGGER_AT=$(date +%s)
osascript -e "tell application \"Finder\" to eject disk \"SpikeVol\"" >/dev/null 2>&1 &

# **不能用固定 sleep** 等弹窗：本脚本要量的正是「用户看到弹窗后多久点下去」这个变量，
# 固定 sleep 会把它变成一个假常量。改成轮询（尺寸以 400 开头 ⇒ 是那个 400pt 宽的弹窗，
# 不会误命中同 app 的菜单栏 popover）。
wait_for_alert() {
    local deadline=$((SECONDS + 25))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$PROBE_BIN/windowid" 磁盘推出助手 2>/dev/null | awk -F'\t' '$3 ~ /^400x/ {hit=1} END {exit !hit}'; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# --- 6 -----------------------------------------------------------------------
echo "--- [6] 断言：被拦住了 ---"
if wait_for_alert; then
    ok "弹窗已出现（距触发 $(( $(date +%s) - TRIGGER_AT ))s）"
else
    fail "等到超时也没见到弹窗"
fi
if [ -d "$VOLUME" ]; then ok "盘仍在 ⇒ 推出被拦截"; else fail "盘消失了 ⇒ 没拦住，接管失效"; fi
HOOK_LOG="$(/usr/bin/log show --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"EjectHook\"" --last 90s --style compact 2>/dev/null)"
echo "$HOOK_LOG"
echo "$HOOK_LOG" | grep -q "拦截" && ok "日志记下了拦截" || fail "日志里没有「拦截」—— hook 可能没注册上"

echo "--- 弹窗上的按钮（AX 读数）---"
"$PROBE_BIN/axdump" 磁盘推出助手 --buttons 2>&1 || fail "AX 读不到按钮"

# --- 7 -----------------------------------------------------------------------
# ⚠️ `CLICK_DELAY` **不是「随便等一等」** —— 它是本脚本故意暴露出来的一个**自变量**，
#    用来量「用户决策窗口」这条边界：
#    产品在放行前是「先清场、再 `return nil` 让**访达**去 unmount」，而系统对一次
#    unmount 的等待上限 ≈ 12.5s（§8.146.3 独立实测 + 2026-09-28 端到端实测）。
#    ⇒ 放行太晚（>12.5s），访达那侧**已经不等了**，清场再干净也没人接着推。
#    实测：放行 12.07s ✅ / 14.45s ❌ / 14.78s ❌。
#    也正因如此，`EjectHookPolicy.userDecisionTimeout` 被下调到 8s（见它的注释）。
#
#    ⇒ `CLICK_DELAY` 大于决策窗口时，弹窗**会先自己收掉**（超时 → cancel → dissent）。
#      那时点击工具「找不到按钮」是**预期行为**，不是失败 —— 见下面的分支。
if [ "${CLICK_DELAY:-0}" -gt 0 ]; then
    echo "（按 CLICK_DELAY=${CLICK_DELAY} 再等 ${CLICK_DELAY}s 后点击）"
    sleep "$CLICK_DELAY"
fi
echo "--- [7] 真实鼠标点击「关闭并推出」（--coords：走 CGEvent，不走语义点击）---"
"$PROBE_BIN/clickbutton" 磁盘推出助手 关闭并推出 --coords 2>&1
CLICK_RC=$?

TIMED_OUT=0
if [ "$CLICK_RC" -ne 0 ]; then
    if /usr/bin/log show --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"EjectHook\"" --last 60s --style compact 2>/dev/null | grep -q "用户决策超时"; then
        TIMED_OUT=1
        ok "点击时弹窗已不在 —— 命中 userDecisionTimeout（决策窗口到点后自己收场），这是**预期**的"
    else
        fail "点击工具退出码 ${CLICK_RC}，且日志里**没有**超时记录 ⇒ 不是「弹窗已收掉」那一种"
    fi
fi

# --- 8 -----------------------------------------------------------------------
echo "--- [8] 断言：清场 + 推出成功 ---"
sleep 15
if [ "$TIMED_OUT" -eq 1 ]; then
    # 超时路径：用户没确认强推 ⇒ 盘**必须还挂着**（与「没接管」逐字一致），
    # 占用进程也该**还在**（超时不走清场）。
    if [ -d "$VOLUME" ]; then ok "超时路径：盘保持挂载（自洽 —— 等于没接管）"; else fail "超时了盘却没了 —— 行为不自洽"; fi
    if pgrep -f "tail -f $VOLUME" >/dev/null 2>&1; then
        ok "超时路径：占用进程未被清场（自洽）"
    else
        fail "超时了却把占用进程杀了 —— 用户没确认强推却动了手"
    fi
else
    if [ -d "$VOLUME" ]; then fail "盘还在 ⇒ 点了「关闭并推出」却没推出去"; else ok "盘已推出 ⇒ 整条链路走通"; fi
    if pgrep -f "tail -f $VOLUME" >/dev/null 2>&1; then
        fail "占用进程还在 ⇒ 清场没生效"
    else
        ok "占用进程已终止"
    fi
fi
echo "--- 应用日志 ---"
/usr/bin/log show --predicate "subsystem == \"$BUNDLE_ID\"" --last 60s --style compact 2>/dev/null | tail -25
echo "--- app stdout ---"
cat "$APP_OUT" 2>/dev/null | tail -20

# --- 结论 --------------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "===== 结论：全部通过（端到端真机验证成功）====="
    exit 0
fi
echo "===== 结论：$FAILURES 项失败 ====="
exit 1
