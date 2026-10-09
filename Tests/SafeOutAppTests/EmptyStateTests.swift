import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 「列表为空时画骨架还是空状态」的判定契约 —— **两层守卫，缺一不可**。
///
/// **为什么单独一个文件**：这里修的是一个**确定性 bug**（2026-09-17 用户报
/// 「电脑上没插移动硬盘，打开主窗口一直显示首次加载的骨架层」）。旧写法把骨架的
/// **开启**判据写成「`disks` 为空」，而**关闭**只挂在 `onChange(of: store.disks)` 上：
///
/// - 没插盘时，刷新前是 `[]`、刷新后还是 `[]` —— **列表根本没变化，`onChange` 不触发**；
/// - 于是 300ms 闸门打开后，没有任何东西再把它关掉，骨架永驻。
///
/// 「加载完了但确实没有外置磁盘」与「还没加载完」是两种状态，
/// 但它们在 `disks` 上的表现**都是空数组** —— 只看空数组分不开，必须看加载是否结束。
///
/// ## 两层守卫的分工（2026-09-17 补齐第二层）
///
/// | 层 | 守什么 | 怎么跑 |
/// |---|---|---|
/// | ① 纯函数真值表（本文件上半） | `showsSkeleton` 的**判定逻辑** | `swift test`，任何机器 |
/// | ② 离屏渲染（本文件下半） | 那个判定**真的接到了渲染分支上** | `swift test`，任何机器 |
/// | ③ 真机 `--preview-main-window-empty-keys` | 窗口上屏后的实际像素 | 真机门槛 |
///
/// ② 之所以可能，是因为 ``ContentView`` 的磁盘来源**可以注入**了（见其 `init`）——
/// 在那之前，「列表为空」这条分支只能靠「本机恰好没插盘」才走得到，
/// ② 写不出来，③ 也大部分时间在打印「跳过」。**一个大部分时间不执行的守卫等于没有守卫。**
@MainActor
struct EmptyStateTests {

    // MARK: - ① 判定逻辑（纯函数真值表）

    /// 闸门还没到、加载也没结束 —— 磁盘枚举通常 < 50ms，这时不该闪骨架。
    @Test func 闸门未到时不显示骨架() {
        #expect(
            !ContentView.showsSkeleton(gatePassed: false, hasFinishedInitialLoad: false),
            "300ms 闸门还没放行就显示骨架，界面会「闪一下」——比什么都不显示更糟")
    }

    /// 闸门到了、加载还没结束 —— 这才是骨架存在的意义（慢加载的占位）。
    @Test func 加载未结束时显示骨架() {
        #expect(
            ContentView.showsSkeleton(gatePassed: true, hasFinishedInitialLoad: false),
            "加载超过 300ms 还没结束，应当显示骨架层作为占位")
    }

    /// **本 bug 的核心判据**：加载已经结束（哪怕结果是「一块盘都没有」），必须显示空状态。
    ///
    /// 变异验证：把 `showsSkeleton` 改回 `gatePassed && disks.isEmpty` 那种写法
    /// （或让 `hasFinishedInitialLoad` 不参与判断），本断言立刻变红 ——
    /// 那正是「没插移动硬盘时骨架永驻」的成因。
    @Test func 加载已结束时不显示骨架() {
        #expect(
            !ContentView.showsSkeleton(gatePassed: true, hasFinishedInitialLoad: true),
            """
            首屏加载已经结束，却仍要画骨架层 —— 这就是用户报的现象：\
            没插移动硬盘时刷新前后列表都是空，`onChange` 不触发，骨架永远关不掉。\
            判据必须看「加载是否结束」，不能看「列表是否为空」。
            """
        )
    }

    /// 补齐真值表最后一种组合（闸门未到 + 已加载完）——
    /// 四种组合全测过，才说明「两个输入都真的参与判断」，
    /// 而不是恰好让某几条断言在退化实现上也是绿的。
    @Test func 闸门未到但已加载完不显示骨架() {
        #expect(
            !ContentView.showsSkeleton(gatePassed: false, hasFinishedInitialLoad: true),
            "加载已结束，闸门放不放行都不该显示骨架")
    }

    // MARK: - ② 离屏渲染：判定有没有真的接到分支上

    /// **离屏守卫**：列表为空时，列表区画的必须是空状态 —— 不是骨架层，也不是空白。
    ///
    /// ## 为什么这条能取代「等本机没插盘」那种跑法
    ///
    /// 判据只看「列表区有多少深色像素」，而列表区画什么**只由注入的 store 决定** ——
    /// 与真实硬件无关。于是它每轮 CI 都跑，而不是等某台机器恰好没插盘。
    ///
    /// ## 阈值是量出来的，不是拍的（2026-09-17，800×520、2x、**白底**）
    ///
    /// | 渲染内容 | 标题带 | 列表带 |
    /// |---|---|---|
    /// | **空状态**（本测试断言的对象） | 2700 | **11250** |
    /// | 骨架层（`SkeletonRow` × 3，同款结构与间距） | 0 | **0** |
    /// | 空白（`Color.clear`） | 0 | **0** |
    ///
    /// 取 **3000**：离空状态的 11250 有 3.7 倍余量，离骨架/空白的 0 是「有」与「无」之差。
    /// 骨架之所以是 0，是因为它整块都是 ``DesignTokens/Palette/subtle`` 的浅灰 —— 够亮。
    ///
    /// ## 它**守不住**什么（别把这条当万灵药）
    ///
    /// 原 bug（「加载完了但没盘 → 骨架永驻」）需要 `skeletonGatePassed == true`，
    /// 而离屏 `cacheDisplay` 不跑 `.task`（没有事件循环），闸门永远不放行 ——
    /// **结构上测不到**。所以这条守的是**分支接错**：把 `emptyState` 写成 `skeletonList`、
    /// 或让列表区什么都不画。原 bug 的守卫是真机 `--preview-main-window-empty-keys`
    /// （`AppDelegate.checkEmptyStateInsteadOfSkeleton`，见 SPEC §8.29）。
    ///
    /// 变异验证：把渲染分支里的 `emptyState` 换成 `skeletonList` → 列表带 11250 → 0，本断言红。
    @Test func 列表为空时渲染空状态而不是骨架或空白() {
        let width = DesignTokens.Size.mainWindow.width
        let height = DesignTokens.Size.mainWindow.height
        let band = DesignTokens.Size.titleBarBandHeight
        let size = CGSize(width: width, height: height)
        let listRect = CGRect(x: 0, y: band, width: width, height: height - band)

        // **注入一个空列表**：不挂系统监听（`monitoring: false`），也不去枚举本机磁盘。
        // 这正是「不依赖物理硬件」的关键 —— 本机插没插盘都不影响。
        //
        // ⚠️ **必须走 `ViewFixtures`**，不要自己拼 `ContentView(skipsInitialRefresh:store:)`：
        // 漏掉 `occupancyStore` 的话，`ContentView` 仍会去碰 `OccupancyStore.shared`，
        // 而那条链的尽头是**本机磁盘**（`DiskListStore.shared` → `fetchExternalDisks()`）。
        // 本文件曾经正是这么写的 —— 于是「不依赖硬件」的守卫自己在悄悄摸硬件。
        // 取证见 `ViewFixtures` 文件头与 `DESIGN-SPEC.md` §8.28.6。
        let view = ViewFixtures.mainWindow(disks: [])

        // 出图与读像素都走 `OffscreenRender`（2026-09-23 收敛，§8.131）。
        //
        // ⚠️ **底必须是白的**（`OffscreenRender.bitmap` 的默认值）。`background: .clear` 时
        // 透明像素读出来是 `(0, 0, 0)`，「深色」判据会把**整块**算成墨迹 ——
        // 实测整条带 166400 全中。`.clear` 是给 ``OffscreenRender/brightPixels``
        // 那种「量亮像素」的判据用的，不是给这里。
        //
        // ⚠️ **只出图一次**：两块区域量的是同一张图，原先那个 helper 每调一次就重画一遍
        // （800×520、scale 2 = 166 万像素，出图本身不便宜）。
        guard let rep = OffscreenRender.bitmap(view, size: size) else {
            Issue.record("离屏出图失败 —— 下面两个数都不能当数")
            return
        }

        // **自证**：整窗必须先有墨迹（空状态图标 + 标题 + 说明 + 按钮，实测上万）。
        // 没有这条，一次「玻璃/文字根本没渲染出来」的失败会被读成「列表区画了骨架」——
        // 两者在列表带的数字上长得一模一样（都是 0）。
        //
        // ⚠️ 自证量**整窗**、不量标题带：v3 头部带交给系统玻璃后，CI runner（macos-26 镜像，
        // 系统与本地 build 号不同）实测整条标题带墨迹为 0 —— 顶部带的渲染内容随环境漂移
        // （安全区/玻璃材质行为差异），而列表带的空状态内容在 CI 实测稳定（listInk 照常过阈值）。
        // 整窗墨迹对「内容位移」免疫：只要画了东西就是数千量级，真·整图空白才是 0。
        let wholeInk = OffscreenRender.inkCount(rep, in: CGRect(origin: .zero, size: size))
        #expect(
            wholeInk > 5000,
            "整窗只数到 \(wholeInk) 个深色像素 —— 这次渲染整个不可信，列表带的结果不能当数"
        )

        let listInk = OffscreenRender.inkCount(rep, in: listRect)
        #expect(
            listInk > 3000,
            """
            列表为空时，列表区只数到 \(listInk) 个深色像素（空状态实测 11250，骨架/空白为 0）——\
            画的不是空状态。空状态有图标 + 标题 + 两行说明 + 按钮，墨迹应是数千量级；\
            骨架层整块是 Palette.subtle 的浅灰圆角块，深色墨迹为 0。\
            判据见 ContentView.showsSkeleton —— 骨架只能由「首屏加载结束」关闭，\
            不能依赖 onChange(of: disks)（无盘时列表永远不变，那个回调不会触发）。
            """
        )
    }
}
