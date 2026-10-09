import AppKit
import Testing

@testable import SafeOutApp

/// 主菜单接线的测试。
///
/// **为什么这类退化必须由测试兜住**：本 App 用自建 `NSApplication` + `app.run()` 启动，
/// 没有 nib，主菜单是手写的。macOS 的 ⌘W / ⌘H / ⌘Q / ⌘M **不是系统全局分发**的快捷键，
/// 它们的实现路径是「按键 → 在主菜单里按 `keyEquivalent` 查找 → 执行该项 action」。
/// 菜单里少一项或 action 指错，对应快捷键就静默失效 —— 不报错、不崩溃、编译也过，
/// 只有用户按下去没反应才发现（2026-09-12 实测 `NSApp.mainMenu == nil` 时 ⌘W 完全无响应，
/// 就是这个形态）。所以把接线本身钉成断言，而不是靠人肉记得按一遍。
@Suite("主菜单接线")
@MainActor
struct MainMenuTests {

    /// 把一个菜单树摊平成所有菜单项（含各级 submenu 里的项）。
    private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            guard let submenu = item.submenu else { return [item] }
            return [item] + flatten(submenu)
        }
    }

    /// 装配主菜单，并把一个 AppDelegate 实例挂成 `NSApplication.shared.delegate`。
    ///
    /// 必须挂：菜单里「显示主窗口」与「隐藏 SafeOut」两项的 target 取自 `NSApp.delegate`
    /// （它们在没有窗口时响应链是空的，走 nil-target 会被置灰）。测试进程里没有应用委托，
    /// 不挂的话这两项的 target 会是 nil，断言就变成空对空。
    /// 返回持有的 delegate —— `NSApplication.delegate` 是 weak，不持有会被立刻释放。
    ///
    /// 开头那句 `_ = NSApplication.shared` 不可省：`NSApp` 这个全局是**由 AppKit 在
    /// 建立共享应用实例时赋值**的，测试进程里从不碰它就一直是 nil，
    /// 于是 `NSApp.delegate = ...`（`NSApp` 是隐式解包可选）会直接崩在解包上。
    private func installWithDelegate() -> AppDelegate {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        // ⚠️ **必须自己持有一份强引用**（2026-09-20 补）。
        // `NSApplication.delegate` 是 **weak** ⇒ 只赋值、不持有，委托会在函数返回后
        // 立刻释放。本文件有 5 处调用写成 `_ = installWithDelegate()`，把返回值丢了 ——
        // 现在它们只断言 `keyEquivalent` / `title`、不看 `target`，所以**暂时**不会红；
        // 但只要有人在其中一条里加一句 `target` 断言，它就会变成一个
        // 「本地全绿、偶发红」的谜（取决于 ARC 何时释放）。
        // ⇒ 与其指望每个调用点都记得持有，不如由 helper 自己持有一份，把这个坑填掉。
        Self.retainedDelegate = delegate
        MainMenu.install()
        return delegate
    }

    /// 见 ``installWithDelegate()`` —— `NSApplication.delegate` 是 weak，必须有人强持有。
    private static var retainedDelegate: AppDelegate?

    @Test func 装配后主菜单有四个顶层菜单() {
        _ = installWithDelegate()
        #expect(NSApplication.shared.mainMenu != nil)
        #expect(NSApplication.shared.mainMenu?.items.count == 4)
    }

    /// 逐个钉住用户报告过「按了没反应」的快捷键，以及其余标准项。
    @Test func 标准快捷键全部接线() throws {
        _ = installWithDelegate()
        let main = try #require(NSApplication.shared.mainMenu)
        let items = flatten(main)

        /// 取「正好是 ⌘<字符>」的那一项 —— 必须精确匹配修饰键，
        /// 否则会把 ⌘⌥H（隐藏其他）也当成 ⌘H。
        func item(_ key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
        }

        // ⌘W：指向 performClose:，交给响应链解析到当前键窗口（主窗口 / 设置窗口共用一条目）
        let close = item("w")
        #expect(close?.action == #selector(NSWindow.performClose(_:)))

        // ⌘H：**必须**是本 App 自己的分流实现，不能用 NSApplication.hide(_:)
        //（代理类 App 系统不允许隐藏，⌘H 会变成死键）
        let hide = item("h")
        #expect(hide?.action == #selector(AppDelegate.hideApp(_:)))

        // ⌘⌥H 隐藏其他仍走系统实现
        let hideOthers = item("h", modifiers: [.command, .option])
        #expect(hideOthers?.action == #selector(NSApplication.hideOtherApplications(_:)))

        // ⌘Q 退出
        #expect(item("q")?.action == #selector(NSApplication.terminate(_:)))

        // ⌘M 最小化
        #expect(item("m")?.action == #selector(NSWindow.performMiniaturize(_:)))

        // ⌘O 显示主窗口 —— 菜单栏模式下 ⌘W 关掉窗口后靠它找回。
        //
        // **键位必须是 ⌘O 而不是 ⌘1**：菜单栏面板的动作行把这一项标成 `⌘O`
        // （设计稿 `.actionrow__key`），两处不一致时用户照着面板按会没反应。
        #expect(item("o")?.action == #selector(AppDelegate.showMainWindow))

        // ⌘R 刷新磁盘列表 —— 同样在面板动作行里有标注
        #expect(item("r")?.action == #selector(AppDelegate.refreshDisks))

        // ⌘, 设置 —— macOS 惯例键位，面板动作行也标了
        #expect(item(",")?.action == #selector(AppDelegate.showSettings))
    }

    /// **面板上画出来的键位必须真的能用。**
    ///
    /// 菜单栏面板的动作行行尾有一列快捷键提示（设计稿 `.actionrow__key`）。
    /// 它是**画上去的**——若主菜单里没有对应项，那个 `⌘R` 就只是装饰：
    /// 用户按下组合键毫无反应，而且不报错、不崩溃，只有用户来投诉才发现。
    ///
    /// 这条断言把「面板标注」与「主菜单接线」两边锁在一起：
    /// 任何一边改了键位而另一边没跟上，测试立刻变红。
    @Test func 面板标注的快捷键与主菜单实际绑定一致() throws {
        _ = installWithDelegate()
        let main = try #require(NSApplication.shared.mainMenu)
        let items = flatten(main)

        // 键位清单**直接读视图的那份数据**（`MenuPopoverView.actionRows`），不在这里手抄一遍。
        // 手抄的话，视图里改了键位而测试没跟上，两边一起错，断言照样绿。
        for row in MenuPopoverView.actionRows {
            // 面板上画的是 `⌘O`，`keyEquivalent` 要的是 `o`。
            let key = row.shortcut.dropFirst().lowercased()
            let wired = items.first {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == [.command]
            }
            #expect(
                wired != nil,
                "面板动作行「\(L10n.tr(row.titleKey))」标注了 \(row.shortcut)，但主菜单里没有这一项 —— 那个键位是假的，按下去不会有反应"
            )
        }
    }

    /// 面板动作行的**条数与顺序**必须与设计稿一致。
    ///
    /// 设计稿 `02-menu-bar.html` 的动作区是固定的四行：打开主窗口 / 刷新磁盘列表 / 设置 / 退出。
    /// 少一行（比如「刷新」）用户就少一个入口，多一行则面板比设计稿高出一整行。
    ///
    /// ⚠️ **深色稿 `07-dark.html` 里只有三行**（漏了「刷新磁盘列表」），
    /// 那是深色稿自身的陈旧——`02-menu-bar.html` 是面板的专属屏幕，以它为准。
    @Test func 面板动作行与设计稿的四行一致() {
        #expect(
            MenuPopoverView.actionRows.count == 4,
            "面板动作区应有 4 行（设计稿 02-menu-bar.html），实际 \(MenuPopoverView.actionRows.count) 行"
        )
        #expect(
            MenuPopoverView.actionRows.map(\.shortcut) == ["⌘O", "⌘R", "⌘,", "⌘Q"],
            "面板动作行的键位与顺序必须与设计稿一致，实际 \(MenuPopoverView.actionRows.map(\.shortcut))"
        )
        #expect(MenuPopoverView.actionRows.last?.isDestructive == true, "「退出」是唯一的破坏性动作")
    }

    /// **同一个动作不能有两个名字。**
    ///
    /// 面板动作行的「退出」与主菜单「退出磁盘推出助手」（⌘Q）是同一个动作。
    /// 面板上若写成光秃秃的「退出」，用户会以为那是两件不同的事
    /// （一个是关窗口、一个是退应用）。设计稿 `02-menu-bar.html` 写的是
    /// `退出 SafeOut` —— 带应用名。
    ///
    /// 这条断言把两边锁在一起：改任一边的文案而另一边没跟上，测试立刻变红。
    @Test func 面板的退出项与主菜单退出项同名() throws {
        _ = installWithDelegate()
        let main = try #require(NSApplication.shared.mainMenu)
        let items = flatten(main)

        let quitItem = try #require(
            items.first { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command] })
        let panelQuit = try #require(MenuPopoverView.actionRows.last)

        #expect(
            L10n.tr(panelQuit.titleKey) == quitItem.title,
            "面板的退出项写着「\(L10n.tr(panelQuit.titleKey))」，主菜单的 ⌘Q 写着「\(quitItem.title)」—— 同一个动作，两种名字"
        )
    }

    /// 四个 App 自有动作必须显式指向 delegate，否则菜单项会被置灰（拿不到接收者）。
    ///
    /// 「设置…」与「刷新磁盘列表」是**菜单栏面板动作行的键位落点**：
    /// 面板在屏幕最上方、主窗口常常是关着的，这两项没有窗口可依，
    /// 走 nil-target 会沿响应链找到底也找不到接收者。
    @Test func 自有动作指向应用委托() throws {
        let delegate = installWithDelegate()
        let main = try #require(NSApplication.shared.mainMenu)
        let items = flatten(main)

        let showMain = try #require(items.first { $0.action == #selector(AppDelegate.showMainWindow) })
        #expect(showMain.target === delegate)

        let hide = try #require(items.first { $0.action == #selector(AppDelegate.hideApp(_:)) })
        #expect(hide.target === delegate)

        let refresh = try #require(items.first { $0.action == #selector(AppDelegate.refreshDisks) })
        #expect(refresh.target === delegate)

        let settings = try #require(items.first { $0.action == #selector(AppDelegate.showSettings) })
        #expect(settings.target === delegate)
    }

    /// 「窗口」菜单要交给 AppKit 托管（`NSApp.windowsMenu`），
    /// 这样打开的窗口会自动出现在菜单底部 —— 少这一句菜单里就不会列出窗口。
    @Test func 窗口菜单交由系统托管() {
        _ = installWithDelegate()
        #expect(NSApplication.shared.windowsMenu != nil)
        #expect(NSApplication.shared.windowsMenu?.title == L10n.tr(.menuWindow))
    }
}
