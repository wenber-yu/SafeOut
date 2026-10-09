#!/usr/bin/env python3
"""造一份「一定会**下载失败**」的本地 appcast（SPEC 第 10 行的实验装置）。

## 它造的是什么

**照抄真实 `appcast.xml`**，只改两处：

1. `<sparkle:version>` → **999**（比产物 build 大 ⇒ Sparkle 才会「发现有更新」）；
2. `<enclosure url=…>` → 一个**必然 404** 的本地路径 ⇒ 下载**真的失败**。

## ⚠️ 两个反直觉的点（下次别再从头撞）

- **EdDSA 签名不用管**：`sparkle:edSignature` 签的是**下载到的那个文件**，
  而这里第一步就 404 ⇒ **根本走不到验签**。所以照抄原属性即可。
- **版本号要改的是 `<sparkle:version>`，不是 `<sparkle:shortVersionString>`**：
  前者参与**版本比较**（决定「有没有更新」），后者只是**显示**
  （`SUAppcastItem.m:747` ⇒ `displayVersionString` 取它）。
  只改后者的话，日志里版本号会变、但**更新根本不会被找到**。
  ⚠️ 真 appcast 里它是**元素**（`<sparkle:shortVersionString>…</…>`），
  不是属性 —— 按属性写正则会**静默匹配不到**（本轮踩过）。

## 用法

```bash
source Tools/clt_swift_env.sh
python3 Tools/probe/make_broken_appcast.py .build/probe/broken-feed/appcast.xml
python3 Tools/probe/feedsrv.py 8899        # 服务的是它自己的目录，见 feedsrv.py
```

配合 `defaults write com.safeout.app SUFeedURL http://127.0.0.1:8899/appcast.xml`
把 app 指过来（`SUFeedURL` 可被 user defaults 覆盖：`SPUUpdater.m:179` / `:1155`）。

## ⚠️ 用完必须还原

`SUFeedURL` / `SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` **三个键都要删掉**
（正常情况下它们本来就是「未设置」）。留着 `SUFeedURL` 会让人**再也收不到真更新**。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]  # Tools/probe/x.py ⇒ 仓库根
PORT_DEFAULT = 8899


def build(port: int = PORT_DEFAULT) -> str:
    src = (REPO / "appcast.xml").read_text(encoding="utf-8")
    out = re.sub(r"<sparkle:version>\d+</sparkle:version>",
                 "<sparkle:version>999</sparkle:version>", src)
    out = re.sub(r'url="https://[^"]*"',
                 f'url="http://127.0.0.1:{port}/missing.dmg"', out)
    return out


def main() -> int:
    out_path = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        REPO / ".build/probe/broken-feed/appcast.xml")
    port = int(sys.argv[2]) if len(sys.argv) > 2 else PORT_DEFAULT

    out = build(port)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(out, encoding="utf-8")

    # 装置自证：三件事必须都成立，否则这次实验作废
    checks = {
        "version 已改成 999": "<sparkle:version>999</sparkle:version>" in out,
        "enclosure 指到本地 404 路径": f"http://127.0.0.1:{port}/missing.dmg" in out,
        "仍是合法 XML（有 <item>）": "<item>" in out,
        "没把真 feed 改坏（源文件未动）": (REPO / "appcast.xml").read_text(
            encoding="utf-8") != out,
    }
    for name, ok in checks.items():
        print(f"  {'OK ' if ok else '✗  '} {name}")
    if not all(checks.values()):
        print("装置自证失败 ⇒ 本次实验作废")
        return 3

    print(f"\n写到 {out_path}")
    print("⚠️ 用完记得删掉那三个 Sparkle 偏好键（尤其 SUFeedURL）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
