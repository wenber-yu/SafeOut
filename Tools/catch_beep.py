"""在 lldb 里抓「系统警告音到底是谁敲的」。

## 为什么需要它（而不是在应用里打日志）

拖动窗口时的「系统警告音」在应用侧几乎不可能靠打日志定位：

1. `NSResponder.noResponder(for:)` 的默认实现**只有 `eventSelector` 是 `keyDown:` 时才会真的
   `NSBeep`**（Apple 文档原文：*The default implementation beeps if `eventSelector` is `keyDown:`*），
   其余 selector 全部静默 —— 所以「日志里一堆 `noResponder(...)`」并不等于「声音从这来」。
2. 拖动过程中每帧都有事件，钩子一旦逐帧打印就会**刷屏**：用户实测「鼠标一动就一堆消息把日志挤走」，
   真正有用的那几行被冲掉了。诊断方式本身成了障碍。

真正决定性的一问只有一句：**「响的那一下，调用栈是什么？」**
—— 这件事只有调试器能回答。所以本模块把 `NSBeep` **本身**设成断点，命中时打调用栈、然后自动继续。

## 用法

    Scripts/catch-beep.sh [可执行文件路径]

（脚本会 import 本模块并 `run`。也可以手动：`lldb --source <(echo 'command script import ...') <bin>`）

## 判读

- **命中 `NSBeep`** → 声音是**本进程**发的，调用栈直接指出是哪一段代码。次数还能区分
  「拖一次响一声」还是「每帧都响」。
- **一条都没命中** → 声音**不是本进程**发的。此时只有两种可能：窗口服务器自己发的，
  或者第三方窗口管理工具（本机实测在跑 Rectangle，且开着 `hapticFeedbackOnSnap`）。
  用「拖一个访达窗口」做对照即可分辨：访达也响 = 与本应用无关。
"""

import time

import lldb

# 三档候选，从最可能的往外扩：
#   NSBeep                          —— AppKit 的「系统警告音」，也就是通常说的「咚」
#   AudioServicesPlayAlertSound    —— 系统「警告」类音效（用户偏好里那个「警告音」）
#   AudioServicesPlaySystemSound   —— 系统音效（含界面音），兜底
_SYMBOLS = [
    ("NSBeep", "NSBeep —— AppKit 系统警告音"),
    ("AudioServicesPlayAlertSound", "AudioServicesPlayAlertSound —— 系统警告音效"),
    ("AudioServicesPlaySystemSound", "AudioServicesPlaySystemSound —— 系统音效（兜底）"),
]

# **`-[NSWindow keyDown:]`：实测出来的响声来源。**
#
# 2026-09-16 的调用栈是 `NSBeep ← forwardMethod ← -[NSWindow keyDown:] ← sendEvent:`，
# 也就是「一个 `keyDown` 事件沿响应链一路没人接，最后落到窗口 → 兜底 → `NSBeep`」。
# 光知道「是 keyDown」不够 —— 还得知道**是哪个键**，否则改不动。
# 所以额外盯住 `keyDown:` 本身，在回调里读事件参数（arm64 下 x2 = 第一个参数）。
_KEYDOWN_SYMBOL = "-[NSWindow keyDown:]"

# 键码 → 名字。取自 `HIToolbox/Events.h`，只列常用的，其余直接打数字。
_KEY_NAMES = {
    36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
    55: "Command", 56: "Shift", 57: "CapsLock", 58: "Option", 59: "Control",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
}

# 修饰键位（`NSEvent.ModifierFlags`）
_MODIFIER_NAMES = [
    (1 << 16, "caps"), (1 << 17, "shift"), (1 << 18, "ctrl"), (1 << 19, "opt"),
    (1 << 20, "cmd"), (1 << 21, "num"), (1 << 22, "help"), (1 << 23, "fn"),
]

# 调用栈打多少帧。够看到「我们的代码 → AppKit → 谁发起」即可，太长反而难读。
_MAX_STACK_FRAMES = 18

# 同一个符号最多打几次完整调用栈。超过就只累加计数 ——
# 万一真是每帧一声，日志也不会变成几百份同样的栈。
_MAX_STACKS_PER_SYMBOL = 5

# `keyDown` 打几次明细（每次都要做 JIT 求值，不能无限打）
_MAX_KEY_PRINTS = 12
_key_down_count = 0

# 全局计数：{符号名: 命中次数}
_counts = {}

# {断点编号: 人类可读的名字}。
#
# **不能用 `SBBreakpoint.SetName`**：当前这版 lldb（lldb-2100）的 `SBBreakpoint`
# 根本没有这个方法，调了会抛 `AttributeError` —— 而且那个异常会**打断后面所有断点的装配**
# （脚本里第一处就炸，于是回调、自动继续、统计命令全都没装上，进程第一次命中就停死）。
# 所以名字自己存一张表，回调里按断点编号反查。
_labels = {}


# 本应用的模块名。调用栈里命中它 = 找到了「我们这边的那一行」。
_APP_MODULES = {"SafeOutApp", "SafeOut"}


def _print_stack(frame):
    """自己走一遍调用栈。

    **为什么不直接 `HandleCommand("bt")`**：断点回调里那个 debugger 没有「当前进程」，
    `bt` 会报 `error: Command requires a current process`（实测）。先手动
    `SetSelectedThread` / `SetSelectedFrame` 也能修，但用 Python API 自己遍历更稳，
    而且能顺手把「哪一帧是我们的代码」标出来 —— 那正是要看的那一帧。
    """
    thread = frame.GetThread()
    total = thread.GetNumFrames()
    for index in range(min(_MAX_STACK_FRAMES, total)):
        current = thread.GetFrameAtIndex(index)
        name = current.GetFunctionName()
        if not name:
            symbol = current.GetSymbol()
            name = symbol.GetName() if symbol.IsValid() else None
        if not name:
            name = "0x%016x" % current.GetPC()
        module = current.GetModule()
        module_name = "?"
        if module and module.IsValid():
            module_name = module.GetFileSpec().GetFilename() or "?"
        marker = "   ← **我们的代码**" if module_name in _APP_MODULES else ""
        print("  #%-2d %-16s %s%s" % (index, "[" + module_name + "]", name, marker))
    if total > _MAX_STACK_FRAMES:
        print("  …（还有 %d 帧）" % (total - _MAX_STACK_FRAMES))


def _should_print_stack(label, hits):
    if hits > _MAX_STACKS_PER_SYMBOL:
        print("（同一符号已命中 %d 次，不再重复打栈；计数继续累加）" % hits)
        return False
    # `NSBeep` 的下游（AudioServices）跟它属于**同一次**响声：NSBeep 已经打过栈了，
    # 这里再打一份几乎一样的只是噪声。反过来，NSBeep 没命中过而 AudioServices 命中了，
    # 就说明声音没走 NSBeep 这条路 —— 那时这份栈才是唯一的线索，必须打。
    if label.startswith("AudioServices") and any(k.startswith("NSBeep") for k in _counts):
        print("（NSBeep 的下游，与上面是同一次响声，不重复打栈）")
        return False
    return True


def _read_c_string(frame, expression):
    """求值一个返回 `char *` 的 ObjC 表达式并读出 C 字符串。失败返回 `"?"`。"""
    try:
        result = frame.EvaluateExpression(expression)
        if not result.GetError().Success():
            return "?"
        address = result.GetValueAsUnsigned()
        if address == 0:
            return ""
        error = lldb.SBError()
        text = frame.GetThread().GetProcess().ReadCStringFromMemory(address, 64, error)
        return text if error.Success() else "?"
    except Exception:  # noqa: BLE001 —— 诊断脚本，读不到就返回 ?，不该炸掉
        return "?"


def _read_long(frame, expression):
    """求值一个整数表达式。失败返回 `None`。"""
    try:
        result = frame.EvaluateExpression(expression)
        if not result.GetError().Success():
            return None
        return result.GetValueAsUnsigned()
    except Exception:  # noqa: BLE001
        return None


def _on_key_down(frame, bp_loc, internal_dict):
    """`-[NSWindow keyDown:]` 命中：把「是哪个键」读出来。

    **arm64 的 ABI**：ObjC 实例方法 `x0 = self`、`x1 = _cmd`、**`x2 = 第一个参数`**。
    这里的第一个参数就是那个 `NSEvent`。

    ⚠️ 只在要打印时才做表达式求值：`EvaluateExpression` 会走一遍 JIT，很慢，
    逐次求值会把拖动卡成幻灯片。
    """
    global _key_down_count
    _key_down_count += 1
    if _key_down_count > _MAX_KEY_PRINTS:
        if _key_down_count == _MAX_KEY_PRINTS + 1:
            print("（keyDown 已超过 %d 次，之后只计数；总数见 beepstats）" % _MAX_KEY_PRINTS)
        return False

    key_code = _read_long(frame, "(long)[(NSEvent *)$x2 keyCode]")
    flags = _read_long(frame, "(unsigned long)[(NSEvent *)$x2 modifierFlags]")
    chars = _read_c_string(frame, "(char *)[[(NSEvent *)$x2 characters] UTF8String]")
    window = _read_c_string(frame, "(char *)[[[(NSEvent *)$x2 window] title] UTF8String]")
    is_repeat = _read_long(frame, "(long)[(NSEvent *)$x2 isARepeat]")

    if key_code is None:
        print("  ⌨️ keyDown #%d（读不到事件参数）" % _key_down_count)
        return False

    name = _KEY_NAMES.get(key_code, "?")
    mods = "+".join(n for bit, n in _MODIFIER_NAMES if flags and flags & bit) or "无"
    # 带上时间戳：应用自己的 stderr 行都带时间，有了它才能把「按键」和「用户那一下操作」对上。
    print(
        "  ⌨️ [%s] keyDown #%d  keyCode=%d(%s)  字符=%r  修饰键=%s  连发=%s  窗口=「%s」"
        % (time.strftime("%H:%M:%S"), _key_down_count, key_code, name, chars, mods,
           "是" if is_repeat else "否", window)
    )
    return False


def _on_hit(frame, bp_loc, internal_dict):
    """断点回调：打调用栈 + 计数，然后放行。"""
    label = _labels.get(bp_loc.GetBreakpoint().GetID(), "（未知断点）")
    _counts[label] = _counts.get(label, 0) + 1
    hits = _counts[label]

    print("")
    print("─" * 70)
    print("🔔 第 %d 次命中「%s」" % (hits, label))
    print("─" * 70)
    if _should_print_stack(label, hits):
        _print_stack(frame)
    print("")
    # 不在这里停：`SetAutoContinue(True)` 会让 lldb 打完日志自动放行。
    return False


def _summary(debugger, command, result, internal_dict):
    """手动调用：打印到目前为止的命中统计。"""
    print("keyDown 次数 = %d（其中打了明细 %d 条）" % (_key_down_count, min(_key_down_count, _MAX_KEY_PRINTS)))
    if not _counts:
        print("❌ 一次都没命中 —— 声音**不是本进程**发的。")
        print("   下一步：拖一个访达窗口做对照。访达也响 = 与本应用无关")
        print("   （窗口服务器或第三方窗口管理工具，本机在跑 Rectangle）。")
        return
    print("命中统计：")
    for label, hits in sorted(_counts.items(), key=lambda kv: -kv[1]):
        print("   %-45s %d 次" % (label, hits))


def __lldb_init_module(debugger, internal_dict):
    print("")
    print("=" * 70)
    print("  抓「系统警告音」：断点已设，请**手动**做这几件事（每步之间停一秒）")
    print("=" * 70)
    print("  ① 拖一下**访达窗口**的标题条   ← 对照组：这一步也响 = 跟本应用无关")
    print("  ② 拖本应用**主窗口**的标题条")
    print("  ③ 拖本应用**设置窗口**的标题条")
    print("  ④ 拖本应用主窗口的**正文区**（磁盘列表那一块）")
    print("")
    print("  响一声就会自动打一段调用栈（不会停住，放心拖）。")
    print("  做完全部四步后：输入 `beepstats` 看统计，再 ⌘Q / Ctrl-C 退出。")
    print("=" * 70)
    print("")

    target = debugger.GetSelectedTarget()
    for symbol, label in _SYMBOLS:
        # 一个符号出问题不该拖垮其余的：全部包起来，装配失败也要把话说清楚。
        try:
            breakpoint = target.BreakpointCreateByName(symbol)
            if not breakpoint.IsValid() or breakpoint.GetNumLocations() == 0:
                print("  （跳过：本机解析不到符号 %s）" % symbol)
                continue
            _labels[breakpoint.GetID()] = label
            breakpoint.SetScriptCallbackFunction("catch_beep._on_hit")
            # 打完日志自动继续 —— 否则一次拖动会把进程停死，用户以为卡了。
            breakpoint.SetAutoContinue(True)
            print("  ✓ 已盯上 %s" % label)
        except Exception as error:  # noqa: BLE001 —— 诊断脚本，出错要能看见而不是炸掉
            print("  ✗ 装 %s 失败：%s" % (symbol, error))

    # 额外盯 `keyDown:` 本身 —— 响声的**来源**（见 `_KEYDOWN_SYMBOL` 的说明）。
    try:
        key_breakpoint = target.BreakpointCreateByName(_KEYDOWN_SYMBOL)
        if key_breakpoint.IsValid() and key_breakpoint.GetNumLocations() > 0:
            # 不登记进 `_labels`：`_on_key_down` 自己管计数（它要的是「第几次」，
            # 不是「哪个断点」），登记了反而误导。
            key_breakpoint.SetScriptCallbackFunction("catch_beep._on_key_down")
            key_breakpoint.SetAutoContinue(True)
            print("  ✓ 已盯上 %s（用来读出「是哪个键」）" % _KEYDOWN_SYMBOL)
        else:
            print("  （跳过：本机解析不到 %s）" % _KEYDOWN_SYMBOL)
    except Exception as error:  # noqa: BLE001
        print("  ✗ 装 %s 失败：%s" % (_KEYDOWN_SYMBOL, error))

    # 提供一个手打命令，方便收尾时看统计。
    debugger.HandleCommand("command script add -f catch_beep._summary beepstats")
    print("")
