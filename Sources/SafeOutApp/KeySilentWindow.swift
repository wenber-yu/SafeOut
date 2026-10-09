import AppKit

/// 不敲钟的窗口：**没人接管的按键不再发系统警告音**。
///
/// ## 症状与根因（2026-09-16 定位）
///
/// 用户在窗口里按 ⌘C 会听到一声「咚」（系统警告音）。lldb 断点 `NSBeep` 抓到的调用栈：
///
/// ```
/// #0 NSBeep
/// #1 forwardMethod
/// #2 -[NSWindow keyDown:]
/// #3 -[NSWindow(NSEventRouting) _reallySendEvent:isDelayedEvent:]
/// #4 -[NSWindow(NSEventRouting) sendEvent:]
/// #5 -[NSApplication(NSEventRouting) sendEvent:]
/// #6 -[NSApplication _handleEvent:]
/// #7 -[NSApplication run]
/// ```
///
/// 路径是：**按键沿响应链一路没人接 → 落到窗口的兜底实现 `noResponderFor(_:)` → 敲钟**。
///
/// 为什么 ⌘C 会走到这一步：macOS 的 ⌘ 快捷键**只经主菜单的 `keyEquivalent` 分发**（见 ``MainMenu``）。
/// 主菜单里**确实**有「复制 ⌘C」这一项（action 是 `NSText.copy(_:)`、`target = nil` 交给响应链），
/// 但本 App 的两个窗口都是 SwiftUI 视图、平时**没有可编辑文本**，
/// 于是响应链里没有任何对象实现 `copy:` → 菜单项被自动禁用 → **被禁用的菜单项不消费按键** →
/// 事件继续下探到窗口 → 敲钟。
///
/// ## 为什么改窗口而不是改菜单
///
/// `noResponderFor(_:)` 是**响应链彻底走空之后**的最后一站：走到这里就说明「主菜单没接、
/// 响应链也没人接」，也就是「这个键在当前上下文里没有任何意义」。对这种键，**安静地忽略**
/// 才是对的 —— 用系统警告音去责怪用户按错键，是 1990 年代的行为。
///
/// 反过来说，**这一层不会掩盖任何真实功能**：任何被菜单项接管的组合键（⌘W / ⌘M / ⌘Q / ⌘, …）
/// 以及任何被响应链接管的按键（文本框里的 ⌘C / ⌘V、对话框的 Esc）都在到达这里**之前**
/// 就被处理掉了，根本不会调用本方法。
///
/// ## 只吞 `keyDown:`，其余照旧交给 super
///
/// Apple 文档明确：`NSResponder.noResponderFor(_:)` 的默认实现
/// *"beeps if `eventSelector` is `keyDown:`"* —— 其余 selector 本来就静默。
/// 实测 `mouseDragged:` / `mouseUp:` / `keyUp:` 也都会走到这里（窗口不实现它们），
/// 但它们不该改变行为，所以照旧交给 `super`。
///
/// ## 这件事必须真机验证
///
/// 「有没有敲钟」**离屏测不到**：`NSBeep` 是进程级的副作用，没有可断言的返回值。
/// 唯一的硬证据是调试器断点 —— `Scripts/catch-beep.sh` 把 `NSBeep` 设成断点，
/// 修前投一次 ⌘C 会命中、修后同一次投递应当**零命中**（见 `DESIGN-SPEC.md` §8.15）。
///
/// ## 为什么现在是 `final`
///
/// 曾经不能 `final`：独立设置窗口 ``SettingsWindow``（v3 已随窗口合并退役，
/// 移出仓库）继承它 —— 设置面板既要「不敲钟」，又要「藏掉三个系统按钮」，
/// 而那两件事都是窗口级的。Swift 单继承，所以当时只能让本类可继承，
/// 而不是把 `noResponderFor(_:)` 在子类里再抄一遍（抄一遍就迟早漂移）。
///
/// v3 起**没有子类了**（`SafeOutApp` 两处都是直接构造），`final` 化把
/// 「又冒出一个没过 `shouldSwallowSilently` 闸门的子类」拦在编译期。
/// 共用规则的另一半（`NSPanel` 那边）走 ``EjectAlertPresenter`` 的静态函数，
/// 不依赖继承。
final class KeySilentWindow: NSWindow {

    /// 这个 selector 走到兜底时，是否应当**静默吞掉**（而不是交给 `super` 去敲钟）。
    ///
    /// 单独抽成静态方法是为了**可测**：`NSPanel` 不能继承 `NSWindow` 子类
    /// （``EjectAlertPanel`` 只能各写一遍 override），两边共用同一条规则才不会漂移。
    static func shouldSwallowSilently(_ eventSelector: Selector) -> Bool {
        eventSelector == #selector(NSResponder.keyDown(with:))
    }

    override func noResponder(for eventSelector: Selector) {
        if Self.shouldSwallowSilently(eventSelector) { return }
        super.noResponder(for: eventSelector)
    }
}
