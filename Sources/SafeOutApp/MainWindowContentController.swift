import AppKit
import SwiftUI

/// v3 主窗口的 **AppKit 装配**：整窗一块玻璃 + 侧栏 / 详情区。
///
/// 口径见 `Design/ui/v3/HANDOFF.md` §3.1（装配）/ §3.3（侧栏）/ §3.7（圆角）。
/// 视图侧在 `Views/MainWindowNavigation.swift`（``MainSidebarView`` / ``MainDetailView``）。
///
/// ## 为什么它**直接继承** `NSSplitViewController`
///
/// 侧栏那圈「四边内缩 8pt 的圆角浮岛 + 玻璃」、统一工具栏那条 52pt 的安全带、
/// 以及红绿灯被自动摆到 26pt —— **全是 AppKit 按「这个窗口有侧栏」给出的**。
/// 实测（`.build/probe/v3_assemble/`）：把 split 包进一层外层容器 VC 再挂上去，
/// 上面那些量**恰好也对**；但那只是碰巧 —— 认这个身份的是窗口与 AppKit 之间的约定，
/// 中间多一层没有文档保证（尤其全屏、窗口恢复、`toolbarStyle` 那几条路）。
/// ⇒ 保持本对象**就是**窗口的 `contentViewController`，玻璃另找位置（见下）。
///
/// ## 玻璃挂在 `view` 的**最底层**，而不是 `splitView` 上
///
/// 实测 `NSSplitViewController.view.subviews == [NSView, NSSplitView]`：
/// 它的 `view` **不是** `NSSplitView` 本身，而是一层普通 `NSView`，
/// 真正的 `NSSplitView` 是它的**兄弟**（两者都是 800×520）。
///
/// ⇒ `view.addSubview(backdrop, positioned: .below, relativeTo: nil)` 只需一句，
/// 而且**不会**变成一块 pane；实测 pane 的几何逐字不变（侧栏 x∈[8,208]、上内缩 8、
/// 详情区顶距 0、红绿灯中心 26 —— 与不带玻璃时全等）。
///
/// ⚠️ **别挂到 `splitView` 上** —— 那才是 pane 的父视图，往上多一个子视图就是多一块 pane。
///
/// ## 安全区：**两侧要求相反，别一视同仁**
///
/// 实测（同一探针，仅差这一句）：
///
/// | 窗格 | `safeAreaRegions` | 量到的结果 |
/// |---|---|---|
/// | 详情区 | `[]` | 52pt 头部带落在 **y ∈ [0, 52]**，标题墨迹中心 **25.8pt** |
/// | 详情区 | 默认（含 `.container`） | 同一块带量成 **104pt**，标题墨迹中心 **77.8pt**（= 26 + 52） |
///
/// ⇒ 详情区**必须**关掉（否则标题掉到 78pt，与红绿灯的 26pt 差半条带子），
/// 理由与 ``AppDelegate/makeMainWindow()`` 里那句「`.fullSizeContentView` 会让 SwiftUI
/// 把内容整体下推」同源 —— 那个 52 就是工具栏的高度（`contentLayoutRect` 量到 468 = 520 − 52）。
///
/// 侧栏则**故意不关**：那个顶部内缩正是「第一项落在红绿灯下方」的来源
/// （设计稿 `.sside` 用 `padding-top: 34px` 模拟的同一件事）。关掉之后第一项会顶到
/// 浮岛最上沿，与红绿灯叠在一起。
final class MainWindowContentController: NSSplitViewController {

    /// 侧栏与详情区共享的那一份导航状态。
    ///
    /// 公开给 ``AppDelegate/presentMainWindow(landing:)``：「打开主窗口」与「设置…」两类入口
    /// 要做的是「亮窗口 + 落在某一页」，而落在哪一页就是它那份 `selection`。
    ///
    /// ⚠️ 它**比窗口活得久**（窗口 `isReleasedWhenClosed = false`，关闭只是收起来）——
    /// 所以「关掉前停在哪一页」会在下次打开时原样留着。落点因此必须由**每次打开的那个入口**
    /// 显式给定（``MainWindowLanding``），不能指望 `selection` 的初值兜底。
    let model = MainWindowModel()

    /// 详情区磁盘页读的那份列表（已解析，非可选）。
    ///
    /// 记在这里而不是让视图自己取 `.shared`：工具栏那颗刷新按钮要刷的就是**窗口在看的这一份**，
    /// 自检要核对的也是它（同 ``AppDelegate/mainWindowStore`` 的理由）。
    let store: DiskListStore

    private let occupancyStore: OccupancyStore
    private let skipsInitialRefresh: Bool
    private let takeOverAvailabilityOverride: AppSettings.TakeOverAvailability?

    /// 整窗那块玻璃。**必须是 `NSHostingView<GlassSurface>`** —— ``GlassSurface`` 是三处
    /// 外壳（主窗口 / 菜单面板 / 引导面板）玻璃的唯一来源，自己再写一块必然分叉。
    ///
    /// `cornerRadius: 0` + `showsBorder: false`：窗口圆角归**窗口服务器**（HANDOFF §3.7.2 第 1 类），
    /// 这里只负责「材质 + `--bg-glass` 叠加色」。写任何圆角值都会切出一个比窗口更小的圆，
    /// 四角露出窗口底；描边更不该画 —— 窗口边缘由系统描。
    private let backdrop = NSHostingView(
        rootView: GlassSurface(cornerRadius: 0, showsBorder: false))

    /// - Parameters:
    ///   - store: 磁盘列表来源，`nil`（生产）读 ``DiskListStore/shared``。
    ///   - skipsInitialRefresh: 见 ``ContentView/init(skipsInitialRefresh:store:occupancyStore:)``。
    ///   - occupancyStore: 占用结论来源，`nil`（生产）读 ``OccupancyStore/shared``。
    ///     与 `store` 是**配对**关系，见同一个 init 的说明。
    ///   - takeOverAvailabilityOverride: 见 ``SettingsSectionPane/takeOverAvailabilityOverride``。
    init(
        store: DiskListStore? = nil,
        skipsInitialRefresh: Bool = false,
        occupancyStore: OccupancyStore? = nil,
        takeOverAvailabilityOverride: AppSettings.TakeOverAvailability? = nil
    ) {
        self.store = store ?? .shared
        self.skipsInitialRefresh = skipsInitialRefresh
        self.occupancyStore = occupancyStore ?? .shared
        self.takeOverAvailabilityOverride = takeOverAvailabilityOverride
        super.init(nibName: nil, bundle: nil)
    }

    /// 本对象只从代码构造（没有 nib），但这颗 init 是 `NSSplitViewController` 的
    /// **必需初始化器**，省略就编译不过。
    ///
    /// ⚠️ **照直转给 `super` 之前必须先把存储属性补齐**，否则报
    /// `property 'self.store' not initialized at super.init call` ——
    /// Swift 要求所有存储属性在 `super.init` 之前就位（`model` 有初始值所以不在此列）。
    /// 取的默认值与 `init(store:…)` 的缺省一致（`.shared`，即生产路径那一份），
    /// 于是「有人在 nib 里连了这个控制器」也能得到一个正常工作的窗口。
    ///
    /// ⛔ **不要**改成 `fatalError()` —— 那等于给 nib 路径留一个崩溃；
    /// 本类的 `viewDidLoad()` 本来就只做装配，没有依赖「必须由代码构造」的假设。
    required init?(coder: NSCoder) {
        self.store = .shared
        self.occupancyStore = .shared
        self.skipsInitialRefresh = false
        self.takeOverAvailabilityOverride = nil
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebar = NSSplitViewItem(sidebarWithViewController: makeSidebarController())
        // 宽度**锁死**（min == max）⇒ 用户拖不动那条分隔线。
        // 面板**本体** 200pt 是设计稿的值；实测系统再整体内缩 8pt，外沿落在 8→208pt。
        // ⚠️ 不要为了凑 208 去改这个数，也不要写补偿代码（HANDOFF §3.3 末尾）。
        sidebar.minimumThickness = DesignTokens.Size.mainSidebarWidth
        sidebar.maximumThickness = DesignTokens.Size.mainSidebarWidth
        // 折叠能力**不给**：设计稿已删折叠钮，留着 `canCollapse` 只会在某些路径下
        // 把侧栏折成一条缝、而没有任何 UI 能把用户救回来。
        sidebar.canCollapse = false
        // `allowsFullHeightLayout` **保持默认**（样式掩码带 `.fullSizeContentView` 且
        // behavior 是 `.sidebar` 时默认为 `true`）。设成 `false` 实测会让浮岛**整个消失**
        // （圆角 0、上内缩变成 52），见 HANDOFF §3.3。
        addSplitViewItem(sidebar)
        addSplitViewItem(NSSplitViewItem(viewController: makeDetailController()))

        // 玻璃：**最后加、放在最底层**（`positioned: .below`）。
        // 用约束而不是 `frame = view.bounds`：`viewDidLoad` 里 `view.bounds` 还是零，
        // 而 autoresizingMask 只按增量缩放、起手是零就永远是零。
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 让那块玻璃铺满整窗（含标题栏那一条），理由见本类抬头「安全区」那一节。
        backdrop.safeAreaRegions = []

        // ⚠️ **窗口尺寸必须由约束钉住 —— 这不是「稳妥起见」，是 v3 的一条真实缺陷的修法。**
        //
        // `win.contentViewController = <本对象>` 这一句会把窗口尺寸**吸成**
        // `view.frame.size` 的「最紧凑 fit」，而 `NSSplitViewController.view` 起手是
        // 「侧栏厚度 × 0」。实测（`.build/probe/v3_size/`，三份探针逐层收敛到这一条）：
        //
        // | 装配到哪一步 | 窗口 |
        // |---|---|
        // | `contentViewController` 赋值后 | **500×500**（`MainWindowTests` 报的就是这个数） |
        // | 接着挂 `toolbar` 之后 | 再收一次 |
        // | 上屏跑满 run loop | **234×16** —— 内容被压成「刚放得下最紧凑 fit」 |
        //
        // 也就是说：不钉住的话，真机上主窗口**根本不是设计稿的 800×520**，
        // 而是一个被内容拖着走的尺寸 —— 侧栏浮岛、详情区 592pt 这些几何全部无从谈起。
        //
        // 两条都试过、只有约束管用：
        // - `preferredContentSize = 设计稿` ⇒ **无效**，窗口照旧 500×500（AppKit 以
        //   `view.frame` 为准，`preferredContentSize` 在这条路上读不到）。
        // - 单纯 `win.setContentSize(设计稿)` ⇒ 建窗那一刻对，但**下一次 layout 就被
        //   吸回去**（探针里挂完工具栏量到 247×16）。
        // - **宽高约束** ⇒ 上屏跑满 run loop 仍是 800×520，且没有约束冲突日志。
        //
        // 与「居中由结构保证」同源：窗口尺寸是产品契约，该由结构给，不该由「内容碰巧
        // 多大」决定。窗口没有 `.resizable`（用户拉不动），所以固定尺寸约束不会与
        // 用户的缩放意图打架。
        //
        // ⛔ 别删这两条去指望 `win.minSize`：`minSize` 只在用户拖拽时生效，
        // 管不住 AppKit 自己把窗口 fit 到内容。
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: DesignTokens.Size.mainWindow.width),
            view.heightAnchor.constraint(equalToConstant: DesignTokens.Size.mainWindow.height),
        ])
    }

    /// 侧栏：**一行外观代码都没有**（HANDOFF §3.3 / 红线 R1、R2、R7）。
    /// 浮岛、圆角、玻璃、选中态胶囊全归系统；这里只装一个 `List(selection:)`。
    private func makeSidebarController() -> NSViewController {
        NSHostingController(rootView: MainSidebarView(model: model))
    }

    /// 详情区：52pt 头部带 + 随选中项切换的那一页。
    private func makeDetailController() -> NSViewController {
        let hosting = NSHostingController(
            rootView: MainDetailView(
                model: model,
                store: store,
                occupancyStore: occupancyStore,
                skipsInitialRefresh: skipsInitialRefresh,
                takeOverAvailabilityOverride: takeOverAvailabilityOverride))
        // ⚠️ **这一句不能省**，见类抬头那张表：不关掉的话 52pt 头部带会落在
        // 「52 + 安全区 52」的位置上，标题掉到 78pt。
        hosting.safeAreaRegions = []
        return hosting
    }

    /// 把侧栏拨到 `landing` 那一页。
    ///
    /// ## 为什么值得从 ``AppDelegate`` 那边抽成方法
    ///
    /// 这一步是「打开主窗口回主页 / 打开设置回设置页」这条契约的**全部**内容，
    /// 而它**不含任何窗口操作** —— 把它留在 `presentMainWindow(landing:)` 里，
    /// 就只能靠真机自检去验（「调 `showMainWindow()` 然后读 `model.selection`」），
    /// 门槛跑不到那条路。抽出来之后单测能直接走**同一条**实现：
    /// 造一个控制器 → 先手动拨到「设置 · 通用」→ 落点 `.disks` → 断言回到外置磁盘。
    ///
    /// ⚠️ **这条赋值本身不是可选的**：`model` 的生命周期长于窗口
    /// （`isReleasedWhenClosed = false`），不拨的话上次停在哪一页就会**跨次沿用**。
    @discardableResult
    func applyLanding(_ landing: MainWindowLanding) -> MainNavItem {
        model.selection = landing.navItem
        return model.selection
    }

    /// 重新枚举磁盘（工具栏尾端那颗刷新按钮的 action）。
    ///
    /// **与 ⌘R 走的是同一条**（``AppDelegate/refreshDisks()`` 转发到这里）：
    /// 「刷新」在界面上只出现两次（工具栏 ✓ 与空状态页那个按钮），
    /// 两处若各写一份实现，迟早出现「一个刷了列表、另一个连占用结论一起刷」这种分叉。
    ///
    /// 刷新期间按钮**原地转圈**并天然禁点（``setRefreshSpinning(_:)`` 把系统按钮
    /// 整**项**换成进度圈项 —— 按钮被移出工具栏，点不到就不存在「刷新中再点一次」的分支），
    /// 跑完换回（v3 按钮形态归系统，见 ``makeRefreshItem()``）。
    @objc func refreshDisks() {
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        setRefreshSpinning(true)
        Task { @MainActor in
            await store.refresh()
            // DE_SLOW_REFRESH=1：把转圈态拖住 5 秒——真机验证 spinner 项布局用的
            // 调试开关（正常刷新太快，截图/AX 都抓不到中间态）。
            if ProcessInfo.processInfo.environment["DE_SLOW_REFRESH"] == "1" {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            // 显式再刷一次占用：`DiskListStore.refresh()` 会把新数组赋给 `disks`，
            // 正常情况下 ``OccupancyStore`` 的订阅会跟上；这里 await 一次是为了让
            // 「点刷新 → 界面已是新结论」这条链路在**同一帧**收口。
            await occupancyStore.refresh(disks: store.disks)
            isRefreshInFlight = false
            setRefreshSpinning(false)
        }
    }

    /// 刷新是否在跑。**本地 UI 态**：只管这颗按钮的转圈与禁重复点击——
    /// 「刷新中」在界面上的唯一表现就是按钮形态，不值得为它开一个
    /// 全局 Published 属性（同 ``ContentView/refreshDisks()`` 的口径：状态跟着消费方走）。
    private var isRefreshInFlight = false

    /// 把工具栏上的刷新项在「系统按钮 ↔ 进度圈」之间切换。
    ///
    /// ## 为什么是「整项移除/插入」，**绝不能原地换 `item.view`**
    ///
    /// 第一版在这里对 `isBordered` 的系统按钮项做 `item.view = NSProgressIndicator`
    /// （再 `view = nil` 换回），真机**稳定闪退**：macOS 26 的
    /// `-[NSToolbarItemViewer configureForLayoutInDisplayMode:andSizeMode:]` 内部
    /// `-[__NSArrayM insertObject:atIndex:]` 抛 nil 插入异常（2026-09-30 崩溃报告
    /// 07A1EC0D 实锤）——带边框项的 viewer 是按「内部系统按钮」布的局，中途塞自定义
    /// view 会让它的子项数组进入不一致状态，下一次布局必炸。
    ///
    /// 改用 AppKit 动态工具栏的**正路**：`removeItem` / `insertItem` 整项替换——
    /// 与工具栏自定制拖拽走同一条内部路径，viewer 生命周期是完整重建，不碰
    /// 系统按钮项的任何属性。进度圈项（``makeSpinnerItem()``）的尺寸由约束量
    /// （`minSize`/`maxSize` 已废弃）。
    ///
    /// 移除/插入**派发到下一个 runloop tick**：本方法可能正处在刷新按钮自己的
    /// action 调用栈里，同步动工具栏的项容易踩「正在处理事件时改事件源」的坑。
    /// 替换实体在 ``performSpinnerSwap(_:)``（internal，单测直接驱动——
    /// swift-testing 的 `@MainActor` 用例里嵌套泵 runloop 带不动 dispatch 块）。
    ///
    /// ⚠️ 实体里用 **`removeItem(at:)` 按索引**增删：`removeItem(identifier:)` 是
    /// macOS 15.0 才有的新名字（部署目标 14 用不了），而按索引还能
    /// **原位替换**——进度圈出现在刷新按钮原来的位置（flexibleSpace 之后），
    /// 而不是被挪到别处。
    func setRefreshSpinning(_ spinning: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.performSpinnerSwap(spinning)
        }
    }

    /// ``setRefreshSpinning(_:)`` 的同步实体。**单独拆出来是因为单测要在
    /// `@MainActor` 用例里确定性地驱动它**——测试体自身就是主执行器上的一个作业，
    /// 嵌套 `RunLoop.run` 泵不动 `DispatchQueue.main.async` 的块（2026-09-30 实测）。
    func performSpinnerSwap(_ spinning: Bool) {
        guard let toolbar = view.window?.toolbar else { return }
        let outgoing = spinning ? Self.refreshItemIdentifier : Self.spinnerItemIdentifier
        let incoming = spinning ? Self.spinnerItemIdentifier : Self.refreshItemIdentifier
        guard
            let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == outgoing }),
            !toolbar.items.contains(where: { $0.itemIdentifier == incoming })
        else { return }
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: incoming, at: index)
        if spinning {
            spinnerIndicator.startAnimation(nil)
        } else {
            spinnerIndicator.stopAnimation(nil)
        }
    }

    /// 进度圈本体。**全局只有一份**：`NSToolbarDelegate` 可能被多次询问同一标识的项，
    /// 每次新建会让动画状态各奔东西。
    private lazy var spinnerIndicator: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        // ⚠️ **必须显式 `.spinning`**：`NSProgressIndicator()` 默认是 **bar（横条）**形态——
        // 真机实测（DE_SLOW_REFRESH=1 + 连拍 md5）：不设这条，16×16 的圈渲染成一条
        // **横线**（强调色横条，用户看到的「按钮变形」其实是它）；配上早期缺宽高约束
        // 的 0×18，就是第一轮截图里那条竖椭圆。`.spinning` 才是转圈。
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel(L10n.tr(.refreshDisks))
        return spinner
    }()

    // MARK: - 工具栏（那条 52pt 的安全带）

    /// 工具栏**标识**：每个控制器一份。
    ///
    /// ⚠️ 不写成常量：`makeMainWindow()` 在单测里会被反复调用（每个用例各建一次窗口），
    /// 同一个标识下同时存在多个 `NSToolbar`，会让 AppKit 那条「按标识自动保存工具栏配置」
    /// 的路互相干扰。
    private let toolbarIdentifier = NSToolbar.Identifier(
        "SafeOut.MainWindow.\(UUID().uuidString)")

    /// 刷新项标识。
    static let refreshItemIdentifier = NSToolbarItem.Identifier("SafeOut.Refresh")

    /// 刷新**进行中**顶上来占位的进度圈项标识（``setRefreshSpinning(_:)`` 用）。
    static let spinnerItemIdentifier = NSToolbarItem.Identifier("SafeOut.Refresh.Spinner")

    /// 造这条工具栏。**项序 `[.flexibleSpace, refresh]`** —— 刷新坐**尾端**。
    ///
    /// ## 为什么保留工具栏（HANDOFF §3.1.1 已定案）
    ///
    /// 它**不是**「装按钮的容器」，是四样基础设施：52pt 顶部安全带、让内容区头部带透出来、
    /// 系统拖拽区 / 双击缩放、以及**红绿灯居中到 26pt**。去掉它实测的四条代价里，
    /// 有两条**手工补不齐**：
    ///
    /// | 去掉工具栏后 | 实测结果 | 能否手工补 |
    /// |---|---|---|
    /// | 红绿灯垂直中心 | 26pt → **16pt** | ❌ 由窗口服务器 / `NSTitlebarView` 决定 |
    /// | 侧栏浮岛上内缩 | 8pt → **32pt** | ❌ 由 AppKit 按「有无工具栏」决定 |
    /// | 顶部左右对齐 | 左浮岛顶 32pt、右头部带顶 0pt ⇒ 横向割裂 | ❌ 同上 |
    /// | 拖拽区 / 双击缩放 | 没有了 | ⚠️ 得自己接，且行为细节与系统不一致 |
    ///
    /// ⇒ 按钮数量（1 个还是 5 个）与该不该保留工具栏**无关**。
    ///
    /// ## ⛔ 另外两件不许做的事
    ///
    /// - **不加折叠钮**：设计稿第 3 轮已删（用户原话「不需要了」）⇒
    ///   `toggleSidebar` / `sidebarTrackingSeparator` 一概不加，
    ///   与之配套的 `canCollapse = false` 见 ``viewDidLoad()``。
    /// - **不用 macOS 26 才有的 `NSToolbarItem.style` / `backgroundTintColor`**：
    ///   部署目标是 14，用它们必然要写 `if #available(macOS 26)`（HANDOFF 红线 R5）。
    ///
    /// - Parameter target: 刷新项的接收者。
    ///
    /// ⚠️ **就是本对象**（`item.target = self`）—— 于是「刷新」只有一条实现，
    /// ⌘R 走 ``AppDelegate/refreshDisks()`` 转发到这里、这颗按钮直接到这里。
    /// `NSToolbarItem.target` 是 `weak`，而本对象被窗口持有着（它是 `contentViewController`），
    /// 不会掉。
    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    /// 刷新按钮的形态：**普通 `NSToolbarItem` + `image` + `isBordered`**。
    ///
    /// 刷新**进行中**会临时换成进度圈（``setRefreshSpinning(_:)``），平时永远是
    /// 这颗系统按钮 —— v3 按钮的形状 / 圆角 / hover / 焦点环全归系统（HANDOFF §3.5），
    /// 设计稿里它是一个静态图标（`.v3refresh`），第二态是 2026-09-30 按用户反馈加回的
    /// （设计稿没画「转圈中」，但 v2 有、用户预期也在）。
    private func makeRefreshItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.refreshItemIdentifier)
        item.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: L10n.tr(.refreshDisks))
        item.label = L10n.tr(.refreshDisks)
        item.isBordered = true
        item.target = self
        item.action = #selector(MainWindowContentController.refreshDisks)
        return item
    }
}

extension MainWindowContentController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.refreshItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.refreshItemIdentifier, Self.spinnerItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.refreshItemIdentifier:
            return makeRefreshItem()
        case Self.spinnerItemIdentifier:
            return makeSpinnerItem()
        default:
            return nil
        }
    }

    /// 转圈项的承载盒。**自带 `intrinsicContentSize`（32×32）**：viewer 对
    /// insertItem 进来的自定义 view 项做 sizing 时读固有尺寸——普通 `NSView`
    /// 是 noIntrinsicMetric（真机量到 0×18），盒 32×32 与 Auto Layout 约束
    /// ``makeSpinnerItem()`` 同值（两处同步改；不进 `DesignTokens.Size`：
    /// 实现细节，不是设计稿几何契约）。
    ///
    /// ⚠️ **32 不是随便取的**（2026-09-30 真机二分实验，DE_SLOW_REFRESH=1 + 截图）：
    /// macOS 26 viewer 给该项画的 Liquid Glass **背景宽度跟随盒尺寸**，盒 28 时
    /// 背景被画成约 12×25 的**竖椭圆**（用户报的「按钮变竖椭圆」真根因——AX 布局
    /// 读数全正常，只有渲染的背景形状塌了）；放大到 44、32 实测都是**正圆**，
    /// 取 32 贴近旁边 `.regular` 按钮的大小。改小前必须真机截图复核。
    private final class SpinnerBox: NSView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: 32, height: 32)
        }
    }

    /// 刷新**进行中**顶上来的进度圈项。**只通过整项移除/插入出现或消失**
    /// （``setRefreshSpinning(_:)``），它自己的属性一经创建永不改动——
    /// 这正是第一版原地换 `item.view` 闪退的反面。
    ///
    /// ⚠️ 圈的 **16×16 宽高约束必须显式写**（真机实测，DE_SLOW_REFRESH=1 + AX 量
    /// frame）：只给 center 时，`.small` 固有尺寸在这条 insertItem 路径上不被
    /// Auto Layout 采纳，圈被量成 **0×18**（圈本身不可见；「竖椭圆」主根因是
    /// 盒尺寸 → 玻璃背景，见 ``SpinnerBox`` 注释；另一处是漏设
    /// ``spinnerIndicator`` 的 `.spinning`，见该属性注释）。
    private func makeSpinnerItem() -> NSToolbarItem {
        let box = SpinnerBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 32),
            box.heightAnchor.constraint(equalToConstant: 32),
        ])
        let spinner = spinnerIndicator
        box.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        let item = NSToolbarItem(itemIdentifier: Self.spinnerItemIdentifier)
        item.view = box
        item.label = L10n.tr(.refreshDisks)
        item.autovalidates = false
        return item
    }
}
