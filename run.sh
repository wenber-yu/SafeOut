#!/bin/bash
# =============================================================
# SafeOut — 一键启动脚本
# 用法：
#   ./run.sh                # 编译并启动（菜单栏 App）
#   ./run.sh --reset        # 透传参数给程序本身
#   ./run.sh check          # 不启动，只过 CI 的门槛（**逐道打印标题**——那份输出才是清单）
#   ./run.sh check --with-tests   # 再追加最贵的那道：测试与覆盖率
#   ./run.sh ci             # 推送**之后**看 CI 结论（等它跑完；--no-wait 只看状态）
#                           #   退出码 0=绿 / 1=红 / 2=没拿到结论（2 ≠ 绿）
#   ./run.sh release        # 发版一条命令（门槛 → 提交 → tag → 构建 → push → Release → appcast）
#                           #   先 `./run.sh release --dry-run` 预演；详见 Scripts/release.sh 头部
# 说明：在源码目录编译并启动 SafeOut（菜单栏 App）。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根 == SPM 包根
PACKAGE_DIR="$SCRIPT_DIR"

# 子命令 check：改完代码先过 CI 门槛的最短路径。
# 与 CI 调用同一个脚本（Scripts/preflight.sh），确保本地判据与 CI 完全一致。
if [ "${1:-}" = "check" ]; then
    shift
    exec "$SCRIPT_DIR/Scripts/preflight.sh" "$@"
fi

# 子命令 ci：推送**之后**看 CI 结论的最短路径（与 check 配对）。
# 起因（2026-09-20）：CI 曾连续 76 次红而没人看 —— 「推完就走」没有任何落点。
# 退出码 0 = 绿 / 1 = 红 / 2 = 没拿到结论（⚠️ 2 **不等于**绿）。
if [ "${1:-}" = "ci" ]; then
    shift
    exec "$SCRIPT_DIR/Scripts/ci_status.sh" "$@"
fi

# 子命令 release：发版一条命令（与 check / ci 同一写法 —— 都是转发到 Scripts/ 下的脚本，
# 这样本地与「照着文档敲」用的是同一个入口）。**默认先跑 dry-run 看一眼**：
#   ./run.sh release --dry-run
if [ "${1:-}" = "release" ]; then
    shift
    exec "$SCRIPT_DIR/Scripts/release.sh" "$@"
fi

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

cd "$PACKAGE_DIR"
echo "▶ 启动 SafeOut ..."
# `-Xlinker -rpath -Xlinker @loader_path`：给链接期补一条 rpath。
#
# ⚠️ **为什么必须有**（2026-09-24 实测）：Sparkle 是动态框架，可执行文件里记的是
# `@rpath/Sparkle.framework/Versions/B/Sparkle`，而 SwiftPM 给它生成的 `LC_RPATH`
# 只有 `/usr/lib/swift` 与 CLT 的 swift-6.2 目录 —— **没有一条指向产物自己的目录**
# ⇒ `swift run` 起来就死在 dyld：
#     Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
# 产物旁边就有 `Sparkle.framework`（同目录），`@loader_path` 正好指过去。
#
# ⚠️ **参数必须排在可执行名之前**：`swift run [<options>] [<executable>] [<arguments>...]`
# —— 可执行名之后的参数是传给**程序**的（同 `Tools/clt_swift_env.sh` 里那个坑）。
#
# ⚠️ **为什么写在 run.sh 而不是 CLT 包装器**：`build_app.sh` 走的是
# `swift build -c release`，配置不同 ⇒ 产物目录不同，两条路径**不会互相污染**；
# 把改动收在开发入口这一个文件里，发版路径的二进制保持原样（它自己用
# `install_name_tool -add_rpath @executable_path/../Frameworks` 补，且会回读验证）。
# exec 让程序直接接管当前终端进程，Ctrl+C 即可退出
#
# `${MACOS_LINK_VERSION_ARGS[@]}`：修正 XCBuild 把 LC_BUILD_VERSION 的 sdk 字段
# 错钉成部署目标的问题（macOS 26 按「链接 SDK」门控新外观，sdk=14.0 会让
# 侧栏浮岛 / 玻璃 / hover 整体退回旧形态）——详见该脚本头部说明。
source "$SCRIPT_DIR/Scripts/lib/macos_link_version_args.sh" "$PACKAGE_DIR"
exec swift run ${MACOS_LINK_VERSION_ARGS[@]+"${MACOS_LINK_VERSION_ARGS[@]}"} \
    -Xlinker -rpath -Xlinker '@loader_path' SafeOutApp "$@"
