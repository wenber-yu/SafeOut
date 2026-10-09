#!/usr/bin/env python3
"""造「验签能过、解压必败」的 dmg + 本地 appcast（Sparkle 更新实验装置）。

与同目录的 `make_broken_appcast.py` **用途不同**，别混：
- `make_broken_appcast.py`：enclosure 指向**不存在的**路径 ⇒ 撞**下载失败**（2001 / 404）。
- 本脚本：dmg **真的能下、验签真的过**，但内容被写坏 ⇒ 撞**解压失败**（generic 3000）。
  要验「安装阶段失败」那一类，必须用这个 —— 用下载失败那个会验错分支。

## 为什么必须写坏**头部**的 4KB

UDIF（dmg）把压缩流放在文件头附近。写坏头部 ⇒ 解压时立刻失败（`SPUDownloadDriver` 之后、
`SPUInstallerDriver.m:313` 那一句「解压时出现错误」）。**只改尾部不一定能弄坏解压**。

## 装置自证（缺任何一条 ⇒ 本次实验作废，脚本会非零退出）

① **阳性对照**：写坏 4KB **前后**，`sign_update` 给出的签名串**必须不同**。
   相同 ⇒ 文件根本没被改（本项目踩过：`dd conv=notrunc` 静默无效）——
   那样「验签过 + 解压败」就变成「验签过 + 解压也过」，**结论完全反过来**。
② 文件内容哈希**必须变**（sha256 变、长度不变）。
③ appcast 里写进去的 edSignature **必须等于**写坏后 `sign_update` 的输出
   （照抄写坏前的签名 ⇒ 验签必败 ⇒ 撞到的是 4005 而不是 3000）。
④ appcast 的 `<sparkle:version>` **必须 > 被测 app 的 CFBundleVersion**，
   否则 Sparkle 认为「已是最新」，根本不会下载。

## 用法

    python3 Tools/probe/make_bad_dmg_feed.py --old-build 238

（默认输出到 `Tools/probe/` —— **`feedsrv.py` 是从它自己所在目录取文件的**，放别处会 404。
实验完记得把那两个文件从 `Tools/probe/` 删掉。）

然后：

    python Tools/probe/feedsrv.py 8899 --log <hits.log>          # 起 feed
    defaults write com.safeout.app SUFeedURL http://127.0.0.1:8899/appcast.xml
    defaults delete com.safeout.app SULastCheckTime

⚠️ **要验「用户触发」那条路，就别开 `SUAutomaticallyUpdate`** ——
自动路径不调 `showUpdaterError`，**根本不弹 UI**，等于白跑。
⚠️ 实验完记得还原用户域偏好（删 `SUFeedURL`、还原 `SULastCheckTime`）。
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SIGN_UPDATE = REPO / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
DEFAULT_BASE_DMG = REPO / "Dist/SafeOut.dmg"
DEFAULT_APP_PLIST = REPO / "Dist/SafeOut.app/Contents/Info.plist"


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sign(sign_update: Path, p: Path) -> tuple[str, int]:
    out = subprocess.run([str(sign_update), str(p)], capture_output=True, text=True)
    if out.returncode != 0:
        print(f"sign_update 失败: {out.stderr}", file=sys.stderr)
        sys.exit(2)
    m = re.search(r'edSignature="([^"]+)"\s+length="(\d+)"', out.stdout)
    if not m:
        print(f"无法解析 sign_update 输出: {out.stdout!r}", file=sys.stderr)
        sys.exit(2)
    return m.group(1), int(m.group(2))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "--out",
        default=str(REPO / "Tools/probe"),
        help="feed 输出目录（默认 Tools/probe —— feedsrv.py 是从它自己所在目录取文件的，放别处会 404）",
    )
    ap.add_argument("--base-dmg", default=str(DEFAULT_BASE_DMG), help="基准 dmg（要基于它写坏）")
    ap.add_argument("--app-plist", default=str(DEFAULT_APP_PLIST), help="基准 app 的 Info.plist")
    ap.add_argument("--sign-update", default=str(DEFAULT_SIGN_UPDATE), help="Sparkle 的 sign_update")
    ap.add_argument("--old-build", type=int, required=True, help="被测 app 的 CFBundleVersion（appcast 必须比它大）")
    ap.add_argument("--port", type=int, default=8899, help="本地 feed 端口（默认 8899）")
    ap.add_argument("--damage-bytes", type=int, default=4096, help="从头部写坏多少字节（默认 4096）")
    args = ap.parse_args()

    out_dir = Path(args.out).resolve()
    base_dmg = Path(args.base_dmg).resolve()
    sign_update = Path(args.sign_update).resolve()
    bad_dmg = out_dir / "SafeOut-bad.dmg"
    appcast = out_dir / "appcast.xml"

    for p, what in ((base_dmg, "基准 dmg"), (sign_update, "sign_update"), (Path(args.app_plist), "Info.plist")):
        if not p.exists():
            print(f"✗ 找不到{what}：{p}", file=sys.stderr)
            return 3

    with open(args.app_plist, "rb") as f:
        info = plistlib.load(f)
    build = int(info["CFBundleVersion"])
    short = str(info["CFBundleShortVersionString"])
    print(f"基准 app: {short} (build {build})；被测 app build {args.old_build}")

    if build <= args.old_build:
        print(
            f"✗ 基准 build {build} 不大于被测 app {args.old_build} ⇒ Sparkle 会认为「已是最新」，不会下载",
            file=sys.stderr,
        )
        return 3

    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(base_dmg, bad_dmg)
    sig_before, len_before = sign(sign_update, bad_dmg)
    sha_before = sha256(bad_dmg)
    print(f"写坏前: len={len_before} sha={sha_before[:16]}… sig={sig_before[:24]}…")

    with open(bad_dmg, "r+b") as f:
        f.write(os.urandom(args.damage_bytes))

    sig_after, len_after = sign(sign_update, bad_dmg)
    sha_after = sha256(bad_dmg)
    print(f"写坏后: len={len_after} sha={sha_after[:16]}… sig={sig_after[:24]}…")

    checks = {
        "① 阳性对照：写坏前后签名不同": sig_before != sig_after,
        "② 文件内容哈希变了": sha_before != sha_after,
        "③ 长度未变（只动内容，没截断）": len_before == len_after,
        f"④ build {build} > 被测 app {args.old_build}": build > args.old_build,
    }
    for name, ok in checks.items():
        print(f"  {'OK ' if ok else '✗  '} {name}")
    if not all(checks.values()):
        print("装置自证失败 ⇒ 本次实验作废", file=sys.stderr)
        return 3

    pub = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    xml = f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>SafeOut</title>
        <item>
            <title>{short}</title>
            <pubDate>{pub}</pubDate>
            <link>http://127.0.0.1:{args.port}</link>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <description>实验装置：验签能过、解压必败的 dmg</description>
            <enclosure url="http://127.0.0.1:{args.port}/{bad_dmg.name}" length="{len_after}" type="application/octet-stream" sparkle:edSignature="{sig_after}"/>
        </item>
    </channel>
</rss>
"""
    appcast.write_text(xml, encoding="utf-8")

    written = re.search(r'edSignature="([^"]+)"', appcast.read_text(encoding="utf-8")).group(1)
    if written != sig_after:
        print("✗ appcast 里的签名 ≠ 写坏后的签名 ⇒ 验签会败（会撞到 4005 而不是 3000）", file=sys.stderr)
        return 3
    print("  OK ⑤ appcast 签名 == 写坏后签名")

    print(f"\nfeed 就绪：{out_dir}")
    print(f"  dmg     : {bad_dmg.name}")
    print(f"  appcast : {appcast.name}")
    print(f"  起服务  : python Tools/probe/feedsrv.py {args.port} --log <hits.log>  （cwd 用上面这个目录）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
