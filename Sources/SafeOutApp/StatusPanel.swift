import AppKit

/// 菜单栏面板的无边框窗口。
///
/// ## 为什么不再用 `NSPopover`（2026-11-10 用户反馈两条）
///
/// 1. **第二次点图标会「闪一下再出现」**：`.transient` 的关闭时机是「用户与 popover
///    **外**的任何 UI 元素交互」——菜单栏图标也在「外」。于是 mouseDown 时系统先把 popover
///    关掉，mouseUp 时按钮 action 再看到 `isShown == false` 又打开一次。
///    自绘窗口没有这层隐式行为：「显示 / 关闭」只由 ``AppDelegate/handleStatusItemClick(_:)``
///    一个地方决定，第二次点击就是 `orderOut`。
/// 2. **图标下方多一个倒三角**：那是 `NSPopover` 的锚点箭头，AppKit **没有公开 API** 关掉它；
///    系统自己的菜单栏面板（控制中心 / Wi-Fi / 电池）也都不画箭头。
///    ⇒ 换成一个普通无边框面板，形状完全由我们的 ``GlassSurface``（圆角 + 系统材质）决定。
///
/// ## 与 ``EjectAlertPanel`` 的两处刻意不同
///
/// | 项 | 推出弹窗 | 菜单面板 |
/// |---|---|---|
/// | 层级 | `.modalPanel`（不盖系统弹窗） | `.popUpMenu`（浮在普通窗口之上、与菜单同层） |
/// | 激活 | 普通窗口，`NSApp.activate` | `.nonactivatingPanel`，点图标不把应用拉到前台 |
///
/// `hidesOnDeactivate` 必须显式关掉 —— `NSPanel` 的默认值是 `true`（`NSWindow` 是 `false`），
/// 开着的话用户点一下别的应用，面板会被系统直接从屏幕上摘掉。
@MainActor
final class StatusPanel: NSPanel {

    /// 面板顶边与菜单栏按钮底边的间距。
    ///
    /// 没有箭头之后留 6pt：贴死（0）会让圆角与菜单栏挤在一起，看起来像菜单栏被切开；
    /// 系统弹层（如控制中心）也留了这一小段呼吸。
    static let anchorGap: CGFloat = 6

    /// Esc 的出口。由 AppDelegate 接到「收起面板」。
    var onCancel: (() -> Void)?

    /// 无边框窗口默认不能成为 key ⇒ 回车 / Esc / 键盘导航全部失效。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// 与 ``KeySilentWindow`` 同一条规则：没人接管的按键不敲钟。
    ///
    /// `NSPanel` 与 `KeySilentWindow` 是两条继承链（Swift 单继承），所以共用静态判据。
    override func noResponder(for eventSelector: Selector) {
        if KeySilentWindow.shouldSwallowSilently(eventSelector) { return }
        super.noResponder(for: eventSelector)
    }
}
