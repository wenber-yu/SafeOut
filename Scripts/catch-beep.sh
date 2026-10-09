#!/usr/bin/env bash
#
# 抓「拖动窗口时的系统警告音」到底是谁敲的。
#
# 在应用里打日志定位不了这件事（详见 Tools/catch_beep.py 开头）：拖动时每帧都有事件，
# 钩子一打印就刷屏，把有用的行挤走。这个脚本改用**调试器断点**：把 NSBeep 设成断点，
# 响的那一下直接把调用栈打出来。
#
# 用法：
#     Scripts/catch-beep.sh                       # 默认盯 /Applications/SafeOut.app
#     Scripts/catch-beep.sh <可执行文件路径>        # 盯别的构建产物
#     Scripts/catch-beep.sh <可执行文件路径> --preview-main-window --preview-settings
#                                                 # 后面的参数原样传给应用
#
# ⚠️ **必须让窗口真的上屏，否则用户无从拖起。**
# 本应用是菜单栏应用，正常启动**只建主窗口、不 order front**
# （`setupMainWindow()` 只 build + center；上屏在 `showMainWindow()` 里，由菜单栏图标 / ⌘O 触发）。
# 而从终端直接跑时状态栏图标不一定建得出来 —— 实测 `CGWindowListCopyWindowInfo` 里
# 该进程**一个在屏窗口都没有**（主窗口存在但 `在屏=false`）。
# 所以拖拽类诊断一律带上 `--preview-main-window --preview-settings`：
# 那是「人工核对模式」，会把窗口上屏 + 激活应用 + **停住不退出**（带 `-keys` 才会退出）。
#
# 日志同时写到 ${DE_BEEP_LOG}（默认 /tmp/dragejector-beep.log），终端滚屏丢了也不怕。
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-/Applications/SafeOut.app/Contents/MacOS/SafeOutApp}"
shift || true
APP_ARGS=("$@")
LOG="${DE_BEEP_LOG:-/tmp/dragejector-beep.log}"

if [ ! -x "$BIN" ]; then
    echo "找不到可执行文件：$BIN" >&2
    echo "先跑 DISABLE_SANDBOX=1 ./build_app.sh 打包，或显式传一个路径。" >&2
    exit 2
fi

# 先退掉已经在跑的实例：否则会出现两个菜单栏图标，
# 而且用户拖的那个未必是被断点盯着的那个进程（那就白测一轮）。
osascript -e 'tell application "SafeOut" to quit' >/dev/null 2>&1 || true
pkill -x SafeOutApp >/dev/null 2>&1 || true
sleep 1

LLDB_SRC="$(mktemp -t catch-beep)"
trap 'rm -f "$LLDB_SRC"' EXIT
cat > "$LLDB_SRC" <<EOF
command script import "$ROOT/Tools/catch_beep.py"
run ${APP_ARGS[@]+"${APP_ARGS[@]}"}
EOF

echo "盯的目标：$BIN"
if [ ${#APP_ARGS[@]} -gt 0 ]; then echo "应用参数：${APP_ARGS[*]}"; fi
echo "日志写到：$LOG"
echo ""

lldb --source "$LLDB_SRC" "$BIN" 2>&1 | tee "$LOG"
