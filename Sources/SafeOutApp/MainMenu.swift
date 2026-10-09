import AppKit

/// 仅用于取得标准编辑动作 `#selector` 的容器。
///
/// `undo:` / `redo:` 在 AppKit 里由 `NSTextView`、`NSWindow` 等多个类沿响应链分别实现，
/// 没有统一的 Swift 类型可以引用（`NSText` 并不声明它们），因此用一个纯声明式协议承载 selector，
/// 这样仍然走 `#selector` 而不是字符串，编译期可校验、且不会产生「请使用 #selector」告警。
@objc private protocol EditMenuSelectors {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

/// 程序化装配 `NSApp.mainMenu` —— 本 App 没有 nib / storyboard，主菜单必须手工建。
///
/// **为什么必须有主菜单**（2026-09-12 定位）：
/// macOS 的 ⌘W / ⌘H / ⌘Q / ⌘M / ⌘C 这类标准快捷键**不是**由系统全局分发的，
/// 它们的实现路径是「按键 → 在**主菜单**里按 `keyEquivalent` 查找 → 执行该项的 action」。
/// 本 App 用自建的 `NSApplication` + `app.run()` 启动（见 `AppDelegate.main()`），
/// 没有 nib 也就没有主菜单 —— 实测 `NSApp.mainMenu == nil`，于是**所有 ⌘ 快捷键全部失效**，
/// 表现为「⌘W 关不掉窗口、⌘H 隐藏不了、⌘Q 退不出」。
/// 装上主菜单后，实测合成 ⌘W 事件能让 `performClose:` 沿响应链关闭当前键窗口。
///
/// 契约：
/// - 标准动作（关闭 / 隐藏 / 退出 / 最小化 …）一律 `target = nil`，交给响应链解析到当前键窗口，
///   这样同一个菜单项对主窗口、设置窗口都自动适用。
/// - 只有本 App 自己的动作（如「显示主窗口」）才显式指向 `NSApp.delegate`：没有窗口时
///   响应链是空的，走 nil-target 会找不到接收者。
@MainActor
enum MainMenu {

    /// 装配并安装主菜单。应在 `applicationWillFinishLaunching` 中调用一次。
    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    // MARK: - 应用菜单

    /// 顶层菜单项标题由系统用 `CFBundleName` 覆盖，不必本地化。
    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(
            withTitle: L10n.tr(.menuAboutApp),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())

        // ⌘, 设置 —— 菜单栏面板的动作行会把这个组合键画在行尾（设计稿 `.actionrow__key`），
        // 所以它必须真的存在：macOS 的 ⌘ 快捷键只经主菜单的 `keyEquivalent` 分发，
        // 菜单里没有这一项，面板上那个 `⌘,` 就是假的。
        let settings = menu.addItem(
            withTitle: L10n.tr(.settingsEllipsis),
            action: #selector(AppDelegate.showSettings),
            keyEquivalent: ",")
        settings.target = NSApp.delegate

        menu.addItem(.separator())

        // ⌘H 走 AppDelegate 自己的分流实现：代理类 App 不能被系统隐藏，
        // 直接用 `NSApplication.hide(_:)` 会让 ⌘H 在菜单栏模式下变成死键（见 `AppDelegate.hideApp`）。
        let hideApp = menu.addItem(
            withTitle: L10n.tr(.menuHideApp),
            action: #selector(AppDelegate.hideApp(_:)),
            keyEquivalent: "h")
        hideApp.target = NSApp.delegate
        let hideOthers = menu.addItem(
            withTitle: L10n.tr(.menuHideOthers),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: L10n.tr(.menuShowAll),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(
            withTitle: L10n.tr(.menuQuitApp),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - 文件菜单

    /// ⌘W 的落点：`performClose:` 会沿响应链找到当前键窗口，主窗口与设置窗口共用同一条目。
    ///
    /// 另带 ⌘R 刷新磁盘列表 —— 菜单栏面板的动作行会把这个组合键画在行尾，
    /// 而 ⌘ 快捷键只能经主菜单分发，所以必须在这里真的挂上一项。
    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L10n.tr(.menuFile))
        menu.addItem(
            withTitle: L10n.tr(.refreshDisks),
            action: #selector(AppDelegate.refreshDisks),
            keyEquivalent: "r"
        ).target = NSApp.delegate
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.tr(.menuCloseWindow),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - 编辑菜单

    /// 标准编辑项。本 App 自身没有输入框，但系统面板（关于面板、更新说明）里选中文本后
    /// ⌘C 应当可用；缺这一栏会让 App 的菜单栏看起来不像原生应用。
    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L10n.tr(.menuEdit))
        menu.addItem(
            withTitle: L10n.tr(.menuUndo), action: #selector(EditMenuSelectors.undo(_:)), keyEquivalent: "z")
        let redo = menu.addItem(
            withTitle: L10n.tr(.menuRedo), action: #selector(EditMenuSelectors.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L10n.tr(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L10n.tr(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L10n.tr(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - 窗口菜单

    /// 除系统标准项外，额外提供「显示主窗口」（⌘O）：菜单栏模式下用 ⌘W 关掉主窗口后，
    /// 这是除菜单栏弹窗之外的第二个入口，避免窗口关掉就找不回来。
    ///
    /// **键位取 ⌘O 而不是 ⌘1**：设计稿 `02-menu-bar.html` 的动作行把「打开主窗口」
    /// 标成 `⌘O`，面板上画的就是它。两处必须是同一个组合键，否则用户照着面板按会没反应。
    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L10n.tr(.menuWindow))

        let showMain = menu.addItem(
            withTitle: L10n.tr(.openMainWindow),
            action: #selector(AppDelegate.showMainWindow),
            keyEquivalent: "o")
        showMain.target = NSApp.delegate
        menu.addItem(.separator())

        menu.addItem(
            withTitle: L10n.tr(.menuMinimize),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        menu.addItem(withTitle: L10n.tr(.menuZoom), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.tr(.menuBringAllToFront),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")

        // 交给 AppKit 维护打开窗口的列表（会自动追加到本菜单末尾）。
        NSApp.windowsMenu = menu

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
