import AppKit
import Testing

@testable import SafeOutApp

/// 「**没人接管的按键不该敲钟**」这条规则的契约。
///
/// ## 这个缺陷是什么
///
/// 用户在窗口里按 ⌘C 会听到一声系统警告音（「咚」）。lldb 断点 `NSBeep` 抓到的调用栈：
///
/// ```
/// #0 NSBeep
/// #1 forwardMethod
/// #2 -[NSWindow keyDown:]
/// #3 -[NSWindow(NSEventRouting) _reallySendEvent:isDelayedEvent:]
/// ```
///
/// 即「按键沿响应链一路没人接 → 落到窗口兜底 `noResponderFor(_:)` → 敲钟」。
///
/// 为什么 ⌘C 会走到这一步：macOS 的 ⌘ 快捷键**只经主菜单的 `keyEquivalent` 分发**。
/// ``MainMenu`` 里**确实**有「复制 ⌘C」（action = `NSText.copy(_:)`、`target = nil` 交给响应链），
/// 但本 App 的窗口都是 SwiftUI 视图、平时没有可编辑文本 → 响应链里没人实现 `copy:` →
/// 菜单项被自动禁用 → **被禁用的菜单项不消费按键** → 事件继续下探到窗口 → 敲钟。
///
/// ## 为什么用两个方向守
///
/// 1. **规则本身**（``无人接管的按键被静默吞掉``）：纯函数，能穷举 selector。
/// 2. **规则有没有接到类上**（``窗口类确实覆盖了兜底方法`` / ``三个窗口都用了不敲钟的窗口类``）：
///    override 被删掉、或者某个窗口改回 `NSWindow(...)`，第 1 条都不会红 —— 那正是
///    「看着在守其实守不住」的典型（本项目踩过：拿 `SettingsMetrics.headerTitleMinX`
///    那类**从被测对象自己算出来的常量**去比 —— 删掉视图里那句让位它照样是绿的。
///    该常量已随 `DESIGN-SPEC.md` §8.17 删除，教训留下）。
///
/// ## 这件事的**最终**证据不在这里
///
/// 「有没有真的敲钟」是进程级副作用，没有可断言的返回值 —— 单元测试只能守到「规则接线正确」。
/// 真正的硬证据是调试器断点（`Scripts/catch-beep.sh` 把 `NSBeep` 设成断点）：
///
/// | | ⌘C 到达窗口 | `NSBeep` 命中 |
/// |---|---|---|
/// | 修前 | ✓ | **每次命中** |
/// | 修后 | ✓ | **0 次** |
///
/// 「到达窗口」由 `-[NSWindow keyDown:]` 断点证明 —— 修的是 `noResponderFor(_:)`，
/// 不是 `keyDown(_:)`，所以这个断点在修后**仍然会命中**。少了这一半，
/// 「0 命中」就无法与「键压根没送到」区分开。
@MainActor
struct KeySilentWindowTests {

    // MARK: - 1. 规则本身

    /// 只有 `keyDown:` 该被吞 —— Apple 文档：`NSResponder.noResponderFor(_:)` 的默认实现
    /// *"beeps if `eventSelector` is `keyDown:`"*，其余 selector 本来就静默。
    ///
    /// 实测（`Tools/catch_beep.py` 的探针）`mouseDragged:` / `mouseUp:` / `keyUp:` 也都会
    /// 走到兜底 —— 但它们不该改变行为，所以必须放行给 `super`。
    /// 把这几条一起钉住，是为了防止有人图省事写成「一律 return」。
    @Test func 无人接管的按键被静默吞掉() {
        #expect(KeySilentWindow.shouldSwallowSilently(#selector(NSResponder.keyDown(with:))))

        #expect(!KeySilentWindow.shouldSwallowSilently(#selector(NSResponder.keyUp(with:))))
        #expect(!KeySilentWindow.shouldSwallowSilently(#selector(NSResponder.mouseDragged(with:))))
        #expect(!KeySilentWindow.shouldSwallowSilently(#selector(NSResponder.mouseUp(with:))))
        #expect(!KeySilentWindow.shouldSwallowSilently(#selector(NSResponder.flagsChanged(with:))))
    }

    // MARK: - 2. 规则有没有接到类上

    /// 覆盖存在性的判据：**子类的 IMP 与基类不同**。
    ///
    /// `class_getInstanceMethod` 会沿继承链解析，所以子类没覆盖时两边 IMP 相同 ——
    /// 这正是「override 被人删掉」时该红的地方。
    private func assertOverridesNoResponder(_ type: AnyClass, base: AnyClass, label: String) {
        let selector = #selector(NSResponder.noResponder(for:))
        guard let subclassMethod = class_getInstanceMethod(type, selector),
            let baseMethod = class_getInstanceMethod(base, selector)
        else {
            Issue.record("\(label)：取不到 noResponderFor: 方法（selector 拼错了？）")
            return
        }
        #expect(
            method_getImplementation(subclassMethod) != method_getImplementation(baseMethod),
            "\(label) 没有覆盖 noResponderFor(_:) —— 按键会一路落到 AppKit 的兜底并敲钟"
        )
    }

    @Test func 窗口类确实覆盖了兜底方法() {
        assertOverridesNoResponder(KeySilentWindow.self, base: NSWindow.self, label: "KeySilentWindow")
        // 弹窗必须继承 `NSPanel`（`hidesOnDeactivate` 的默认值与 `NSWindow` 相反），
        // 所以规则是**各写一遍**的 —— 那就更要盯住，两边最容易漂移。
        assertOverridesNoResponder(EjectAlertPanel.self, base: NSPanel.self, label: "EjectAlertPanel")
    }

    // MARK: - 3. 三个窗口都接上了

    /// **这一条是防止「新窗口忘了用」**：窗口的构造点分散在几个文件里，
    /// 任何一处写回 `NSWindow(...)` / `NSPanel(...)`，规则就静默失效 ——
    /// 而且失效的表现只是「偶尔响一声」，没有断言的话谁也不会发现。
    ///
    /// ## v3 起从「四个」变「三个」
    ///
    /// 独立设置窗口已退役（主窗口与设置合并成「侧栏 + 详情区」，见
    /// `Design/ui/v3/HANDOFF.md`）⇒ 这一条里原先那句
    /// `AppDelegate.makeSettingsWindow()` 连同它的断言一起删除。
    /// **不是漏了**：v3 之后设置内容住在主窗口的详情区里，
    /// 它用的就是下面这第一个窗口对象，没有第二个窗口需要检查。
    @Test func 三个窗口都用了不敲钟的窗口类() {
        // 走 `ViewFixtures` 而不是裸调 `AppDelegate.makeMainWindow()`：
        // 后者两个 store 都是生产单例，会真的去枚举本机磁盘（见 `ViewFixtures` 文件头）。
        // 这里要验的是**窗口类**，与磁盘数据无关。
        let main = ViewFixtures.mainWindowHandle()
        #expect(main is KeySilentWindow, "主窗口没走 KeySilentWindow —— ⌘C 会重新开始敲钟")

        let onboarding = AppDelegate.makeOnboardingPanel(
            root: OnboardingView(accent: .default, onOpenSettings: {}, onLater: {})
        ).window
        #expect(onboarding is KeySilentWindow, "引导面板没走 KeySilentWindow")

        let alert = EjectAlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // 弹窗的类型断言在这里是**同义反复**（它就是 EjectAlertPanel），
        // 真正要守的是「它覆盖了兜底方法」—— 那一条在上面的 `窗口类确实覆盖了兜底方法`。
        //
        // 这里确认它确实继承自 NSPanel（决定 `hidesOnDeactivate` 默认值的那件事）。
        // ⚠️ **不能写 `alert is NSPanel`** —— `alert` 的静态类型就是 `EjectAlertPanel`，
        // 编译器直接判定该表达式恒真（`-warnings-as-errors` 下报 `'is' test is always true`）。
        // 恒真的断言等于没有断言：它既挡不住「基类被改成 NSWindow」，也给人「查过了」的错觉。
        // 走运行时的 `isSubclass(of:)`，编译器折叠不掉。
        #expect(type(of: alert).isSubclass(of: NSPanel.self), "弹窗的基类不是 NSPanel，hidesOnDeactivate 的默认值会变")
    }
}
