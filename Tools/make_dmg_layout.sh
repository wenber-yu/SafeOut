#!/bin/bash
# =============================================================
# 生成 `Resources/dmg/DS_Store` —— dmg 安装窗口的 Finder 布局模板。
#
#     ./Tools/make_dmg_layout.sh
#
# **为什么要有这个脚本**：dmg 挂载后就是一个 Finder 窗口。想让它有背景图、把两个图标
# 摆在指定位置，就得往卷里写一个 `.DS_Store` —— 而**只有 Finder 自己会写它**
# （格式私有，手写等于赌博）。所以做法是：**跑一次本脚本，把 Finder 写出来的那份存成模板**；
# 此后 `build_app.sh` 打包时直接拷模板 ⇒ **打包期零 GUI 依赖，CI 上也能用**。
#
# ⚠️ **只在布局改了的时候重跑**（改背景图尺寸 / 图标坐标 / 窗口大小）。
# ⚠️ **需要 Finder 自动化授权**：系统设置 › 隐私与安全性 › 自动化 › WorkBuddy AI → Finder。
#    没授权时 osascript 会**挂住**（权限弹窗没人点）—— 本脚本用后台 + 硬超时兜住，
#    不会真挂死，但会明确报出「超时 ⇒ 多半是没授权」。
#
# ⚠️ **两类失败要分清**（症状都是「Finder 不干活」，成因完全不同）：
#    · **-1712 / 挂住** ⇒ 权限弹窗没人点（没授权）。本脚本的硬超时兜这个。
#    · **-1728（不能获得 disk）** ⇒ 卷挂的位置不对，或 Finder 还没登记这个卷。
#      **跟权限无关**，别去改授权 —— 见下面两处「⚠️」。
#
# **同源约束**：本脚本的窗口尺寸与图标坐标，必须与 `Tools/make_dmg_background.py` 里
# 画背景图用的常量一致 —— 否则箭头会指歪，而**两边都不报错**。
# `Scripts/test/dmg_layout_smoke.sh` 会比对这两处。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="SafeOut"
VOLNAME="$APP_NAME"
APP_BUNDLE="$PACKAGE_DIR/Dist/$APP_NAME.app"
BACKGROUND="$PACKAGE_DIR/Resources/dmg/background.png"
OUT_DSSTORE="$PACKAGE_DIR/Resources/dmg/DS_Store"

# ---- 与 Tools/make_dmg_background.py 的常量同源（改这里必须改那里）----
BG_WIDTH=660
BG_HEIGHT=420
ICON_Y=185      # 图标中心的 y（Finder 图标视图坐标：原点在**内容区**左上角）
APP_CX=170      # 应用图标中心 x
APPS_CX=490     # Applications 替身中心 x

WIN_X=200
WIN_Y=160
# Finder 的 `bounds` 是**含标题栏**的窗口外框；内容区才是背景图铺的那块。
# 所以外框高 = 图高 + 标题栏高。标题栏高度**不写死成 28 就完事** —— 实测后填，
# 并由 `Scripts/test/dmg_layout_smoke.sh` 的 ③ 核对「外框高 == 图高 + 这个值」
# （⚠️ 那一步是**数值**核对；「背景图有没有被裁 / 留白边」是**像素**的事，
#  属于改布局那一轮的手动目视核对，见文件末尾）。
TITLEBAR_H=28
WIN_W=$BG_WIDTH
WIN_H=$((BG_HEIGHT + TITLEBAR_H))

TIMEOUT_SECS=25
FINDER_WAIT_SECS=15

# ⚠️ **必须挂在 /Volumes/<卷名>**：用 `-mountpoint` 挂到临时目录时，Finder 认不到这个卷，
# `tell disk "<卷名>"` 会报 **-1728**（不能获得 disk）—— 看着像权限问题，其实是位置不对。
MOUNT_POINT="/Volumes/$VOLNAME"

die() { echo "❌ $*" >&2; exit 1; }

[ -d "$APP_BUNDLE" ] || die "找不到 $APP_BUNDLE —— 先跑一次 PACKAGE=1 ./build_app.sh"
[ -f "$BACKGROUND" ] || die "找不到 $BACKGROUND —— 先跑 python3 Tools/make_dmg_background.py"

STAGING="$(mktemp -d)"
TMP_DMG="$(mktemp -u).dmg"
SCPT="$(mktemp -t dmg_layout).scpt"
OSA_OUT="$(mktemp)"

cleanup() {
    # ⚠️ 还原步骤别挂在会失败的命令后面（`&&` 链短路会让它被跳过）
    if mount | grep -qF "on $MOUNT_POINT "; then hdiutil detach "$MOUNT_POINT" -quiet || true; fi
    rm -f "$TMP_DMG" "$SCPT" "$OSA_OUT" || true
    rm -rf "$STAGING" || true
}
trap cleanup EXIT

# ---- AppleScript：**参数从 argv 传**，不要把坐标硬编码在脚本里 ----
# 硬编码的后果是「改了上面的常量、AppleScript 里那份没改」—— 两边都不报错，只有图标歪了。
cat > "$SCPT" <<'APPLESCRIPT'
on run argv
	set volName to item 1 of argv
	set wx to (item 2 of argv) as integer
	set wy to (item 3 of argv) as integer
	set wr to (item 4 of argv) as integer
	set wb to (item 5 of argv) as integer
	set appItem to item 6 of argv
	set appCx to (item 7 of argv) as integer
	set appCy to (item 8 of argv) as integer
	set appsCx to (item 9 of argv) as integer
	set appsCy to (item 10 of argv) as integer

	tell application "Finder"
		tell disk volName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {wx, wy, wr, wb}
			set theViewOptions to the icon view options of container window
			set arrangement of theViewOptions to not arranged
			set icon size of theViewOptions to 128
			set text size of theViewOptions to 13
			set background picture of theViewOptions to file ".background:background.png"
			set position of item appItem of container window to {appCx, appCy}
			set position of item "Applications" of container window to {appsCx, appsCy}
			update without registering applications
			delay 1
			set bAfter to bounds of container window
			set pApp to position of item appItem of container window
			set pApps to position of item "Applications" of container window
			close
			return "回读：窗口=" & (bAfter as text) & "  app=" & (pApp as text) & "  Applications=" & (pApps as text)
		end tell
	end tell
end run
APPLESCRIPT

echo "▶ 组装 staging（app + Applications 替身 + 背景图）..."
ditto "$APP_BUNDLE" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background"
cp "$BACKGROUND" "$STAGING/.background/background.png"

# 上一次跑挂了留下的卷会把它挤成 "SafeOut 1" ⇒ 后面的 `tell disk "SafeOut"`
# 就会 -1728。先清掉。
if mount | grep -qF "on $MOUNT_POINT "; then
    echo "   （清掉上次残留的挂载卷）"
    hdiutil detach "$MOUNT_POINT" -quiet || true
fi

echo "▶ 造一个**可写**的 dmg（UDRW）..."
hdiutil create -fs HFS+ -format UDRW -volname "$VOLNAME" -srcfolder "$STAGING" "$TMP_DMG" >/dev/null

echo "▶ 挂载..."
hdiutil attach -nobrowse "$TMP_DMG" >/dev/null
[ -f "$MOUNT_POINT/.background/background.png" ] || die "卷里没有背景图，Finder 设不了背景"

# ⚠️ **等 Finder 认到这个卷再动手**：刚 attach 完 Finder 的对象模型里还没有它，
# 直接 `tell disk "<卷名>"` 会报 **-1728**。这是**竞态**，不是权限问题 ——
# 而报错文案（「不能获得 disk」）与「卷名写错了」逐字相同。
echo "▶ 等 Finder 认到卷 ${VOLNAME}..."
FOUND=0
for _ in $(seq "$FINDER_WAIT_SECS"); do
    if osascript -e 'tell application "Finder" to get name of every disk' 2>/dev/null | grep -qF "$VOLNAME"; then
        FOUND=1
        break
    fi
    sleep 1
done
[ "$FOUND" = 1 ] || die "Finder ${FINDER_WAIT_SECS}s 内没认到卷 $VOLNAME —— 这正是 -1728 的成因"

echo "▶ 让 Finder 摆布局（窗口 ${WIN_W}×${WIN_H} 含标题栏 ${TITLEBAR_H}，图标 y=${ICON_Y}）..."
osascript "$SCPT" "$VOLNAME" "$WIN_X" "$WIN_Y" "$((WIN_X + WIN_W))" "$((WIN_Y + WIN_H))" \
    "$APP_NAME.app" "$APP_CX" "$ICON_Y" "$APPS_CX" "$ICON_Y" > "$OSA_OUT" 2>&1 &
OSA_PID=$!
# 硬超时：没授权时 osascript 会一直等权限弹窗，不能让它把整条流水线挂死
for _ in $(seq "$TIMEOUT_SECS"); do
    kill -0 "$OSA_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$OSA_PID" 2>/dev/null; then
    kill -9 "$OSA_PID" 2>/dev/null || true
    echo "❌ Finder 自动化 ${TIMEOUT_SECS}s 未返回。" >&2
    echo "   多半是**没授权**：系统设置 › 隐私与安全性 › 自动化 › WorkBuddy AI → Finder。" >&2
    echo "   （没授权时它会等一个没人点的弹窗，所以表现为「挂住」而不是报错。）" >&2
    exit 1
fi
if [ -s "$OSA_OUT" ]; then
    echo "   osascript 输出：$(cat "$OSA_OUT")"
fi

# Finder 是**异步**把布局落盘到 `.DS_Store` 的：不等一下会拷到一个空文件或旧内容，
# 而两者都不报错。`sync` 后再给 2s。
echo "▶ 等 Finder 落盘..."
sync
sleep 2

[ -f "$MOUNT_POINT/.DS_Store" ] || die "卷里没有 .DS_Store —— Finder 没写出来（布局没生效？）"
mkdir -p "$(dirname "$OUT_DSSTORE")"
cp "$MOUNT_POINT/.DS_Store" "$OUT_DSSTORE"
echo "   ✓ 已写出 Resources/dmg/DS_Store（$(stat -f '%z' "$OUT_DSSTORE") 字节）"

echo "▶ 卸载..."
hdiutil detach "$MOUNT_POINT" -quiet

cat <<'EOF'

✅ 布局模板已生成。

下一步：
  1) 跑机器判据：`Scripts/test/dmg_layout_smoke.sh`
     —— 它做三件事：① 两个源文件的常量双向比对；② 生成物（背景图尺寸 + 出处块、
     `.DS_Store` 的窗口尺寸与两个图标坐标）与源比对；③ 用与 `create_dmg` 同一串旗标
     真造一个小 dmg、真挂载、按字节比对（含阴性样本）。
     ⚠️ 它**不**看渲染效果 —— 那是像素的事，见第 2 步。
  2) **手动**目视核对（**只在改布局的那一轮做一次**）：
     打一个真 dmg（`PACKAGE=1 ./build_app.sh`）→ 挂载 → 截图 → 按像素量
     「背景图有没有铺满内容区（有没有被裁 / 留白边）」
     「两个图标有没有正好落在背景图画的箭头两端」。
     做法见 ENGINEERING-NOTES §8.143（`screencapture` 全屏 + 按 scale 裁）。
  3) 改了背景图尺寸或图标坐标 ⇒ 两个文件的常量都要改（本脚本 + make_dmg_background.py），
     并且**两边的生成物都要重跑**（本脚本 + `python3 Tools/make_dmg_background.py`）。
EOF
