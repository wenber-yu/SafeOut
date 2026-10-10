import AppKit
import Testing

@testable import SafeOutApp

/// 「打开主窗口回哪一页」这条契约。
///
/// ## 它守的是 2026-10-10 用户报的那个现象
///
/// > 在菜单栏点击打开主窗口后默认选中外置磁盘，我再选中通用选项后关掉主窗口，
/// > 再次从菜单栏点击打开主窗口后，显示的主窗口没有选中到外置磁盘选项，还是通用选项。
///
/// ## 根因不在「关窗口」，而在 **`model` 比窗口活得久**
///
/// `MainWindowContentController.model` 是控制器上的 `let`，而窗口
/// `isReleasedWhenClosed = false` —— 关掉窗口只是把它收起来，**控制器与那份
/// `selection` 原封不动留着**。于是「上次停在哪一页」天然会跨次沿用。
///
/// 这条「沿用」本身不算 bug（保留用户上下文在很多应用里是想要的），
/// 错的是**打开入口没有显式声明落点**：入口只负责「把窗口亮出来」，
/// 于是亮出来的是**上一次残留的那一页**。
///
/// ## 为什么断言落在 `applyLanding` 上，而不是 `AppDelegate` 上
///
/// 「亮窗口」（建窗 / 反小化 / `orderFront` / 激活）会**抢用户焦点**，
/// 单测调它必然扰动正在跑测试的机器 ⇒ 断言只能落在同一份实现的**不含窗口那一步**。
/// `MainWindowContentController/applyLanding(_:)` 就是为此从
/// `presentMainWindow(landing:)` 里抽出来的那一步 —— 它是**同一条实现**，
/// 不是测试专用的替身（测试专用副本等于什么都没验，见
/// ``runSettingsPreview(autoKeys:)`` 里那句「另写一份预览专用的代码等于什么都没验」）。
@MainActor
struct MainWindowLandingTests {

    /// 造内容控制器。**两个 store 都走替身**（``ViewFixtures``），不碰真机磁盘、不跑 `lsof`。
    private func makeContent() -> MainWindowContentController {
        let s = ViewFixtures.stores()
        return MainWindowContentController(
            store: s.disk,
            skipsInitialRefresh: true,
            occupancyStore: s.occupancy
        )
    }

    // MARK: - 落点映射

    /// 两个入口必须落在**两个不同**的侧栏项上。
    ///
    /// 没有这条时，把 `.settingsGeneral` 的映射也写成 `.disks`（复制粘贴时最常见的错）
    /// 会让「点设置停在磁盘页」这条缺陷**完全隐形** —— 下面两条断言各自都还会绿。
    @Test func 两个入口落在两个不同的侧栏项上() {
        #expect(MainWindowLanding.disks.navItem == .disks)
        #expect(MainWindowLanding.settingsGeneral.navItem == .settings(.general))
        #expect(MainWindowLanding.disks.navItem != MainWindowLanding.settingsGeneral.navItem)
    }

    // MARK: - 落点会覆盖上一次残留的那一页

    /// **本次修复的正题**：先停在「设置 · 通用」，再落 `.disks` ⇒ 必须回外置磁盘。
    ///
    /// 这一条**先手动拨脏再落点**，而不是直接断言落点后读出来 —— 因为
    /// 「赋值语句自己」与「赋值能不能覆盖已有值」是两回事：写成
    /// `applyLanding` 里只写 `if model.selection == .disks { ... }` 这种带条件的版本
    /// （在「本来就是外置磁盘」的场景下测）会让本条**恒绿**，而用户看到的现象照旧。
    @Test func 落点会覆盖上一次停留的那一页() {
        let content = makeContent()
        // 先复现「上一次停在设置页」这个前提。
        content.model.selection = .settings(.general)
        #expect(content.model.selection == .settings(.general), "前置条件不成立，下面那条断言会变成恒真")

        let landed = content.applyLanding(.disks)
        #expect(landed == .disks)
        #expect(content.model.selection == .disks)
    }

    /// 「设置…」入口同理：先停在磁盘页，落 `.settingsGeneral` ⇒ 必须到设置·通用。
    @Test func 设置入口的落点是设置通用() {
        let content = makeContent()
        content.model.selection = .disks

        let landed = content.applyLanding(.settingsGeneral)
        #expect(landed == .settings(.general))
        #expect(content.model.selection == .settings(.general))
    }

    // MARK: - model 的初值不是兜底

    /// `MainWindowModel.selection` 的初值是 `.disks`，但它**只对第一次建窗有效**。
    ///
    /// 留着这条是因为那句初值很容易被后来者当成「落点的兜底」——
    /// 而它兜不住第二次之后的任何一次（控制器被复用，见本文件抬头）。
    /// 它同时也是「新建控制器天生就在主页」这条事实的记录。
    @Test func 新建model的初值是外置磁盘() {
        #expect(MainWindowModel().selection == .disks)
    }

    // MARK: - 关掉窗口不会重置（这正是必须显式落点的原因）

    /// 窗口 `close()` **不会**把 `selection` 拨回初值 —— 这条把根因钉在测试里。
    ///
    /// 它是上面两条断言的**前提**：如果哪天有人给窗口加了 `windowWillClose`
    /// 顺手重置选中项（那确实是个诱人的「修法」），本条会红，
    /// 而上面两条仍会绿 —— 于是「靠关窗口重置」这条替代路径会被明确否掉。
    ///
    /// ⚠️ **不上屏**：窗口层那条路径由 `MainWindowTests` 覆盖（它同样不上屏），
    /// 这里只关心 `close()` 对 `model.selection` 有没有副作用。
    @Test func 关掉窗口不会把选中项拨回外置磁盘() throws {
        _ = NSApplication.shared
        let window = ViewFixtures.mainWindowHandle()
        let content = try #require(window.contentViewController as? MainWindowContentController)
        content.model.selection = .settings(.general)

        window.close()
        #expect(
            content.model.selection == .settings(.general),
            "窗口 close() 竟然重置了选中项 —— 那么落点契约的实现方式需要重新评估（见本文件抬头）")
    }
}
