import AppKit
import Testing

@testable import SafeOutApp

/// 刷新**转圈项**的形态与尺寸判据（2026-09-30 真机修复的回归）。
///
/// ## 为什么 headless 测试绿、真机红 —— 这三条判据钉的是什么
///
/// macOS 26 真机（`DE_SLOW_REFRESH=1` + AX 量 frame + 连拍截图）实测：
/// viewer 对 `insertItem` 进来的自定义 view 项，sizing **不读** Auto Layout
/// 约束、`.small` 的固有尺寸**也不被采纳**——圈只给 center 约束时被量成
/// **0×18**（竖线）；而 `NSProgressIndicator()` 默认是 **bar（横条）**形态，
/// 有了 16×16 尺寸后渲染成强调色**横条**。两条叠加，就是用户截图里的
/// 「刷新按钮变成竖着的椭圆 + 没有转圈」。headless 测试里 `layoutIfNeeded`
/// 尊重约束，所以旧实现测试全绿、真机全红——本用例把两处修复**逐条钉死**：
///
/// 1. `style == .spinning`（漏设 = bar 横条；变异：删该行必红）
/// 2. 圈 16×16 宽高约束显式存在（漏设 = 0×18 竖线；变异：删约束必红）
/// 3. 盒固有尺寸 32×32（`SpinnerBox.intrinsicContentSize`，与约束同值）
@MainActor
struct SpinnerItemLayoutTests {

    @Test func 转圈项必须是转圈形态且宽高钉死() {
        // 建窗口、建 hosting 都需要 `NSApplication.shared` 存在。
        _ = NSApplication.shared
        let window = ViewFixtures.mainWindowHandle()
        guard
            let controller = window.contentViewController as? MainWindowContentController,
            let toolbar = window.toolbar
        else {
            Issue.record("主窗口必须有 MainWindowContentController 与 toolbar")
            return
        }
        // 驱动一次换入（同步实体，与「整项替换」测试同一条路径）。
        controller.performSpinnerSwap(true)
        defer { controller.performSpinnerSwap(false) }

        guard
            let item = toolbar.items.first(where: {
                $0.itemIdentifier == MainWindowContentController.spinnerItemIdentifier
            }),
            let box = item.view
        else {
            Issue.record("换入后工具栏里必须有转圈项且自带 view")
            return
        }

        // ③ 盒固有尺寸 32×32（viewer sizing 的取值来源）。
        #expect(
            box.intrinsicContentSize == NSSize(width: 32, height: 32),
            "盒固有尺寸必须是 32×32，实得 \(box.intrinsicContentSize)")

        guard let circle = box.subviews.compactMap({ $0 as? NSProgressIndicator }).first else {
            Issue.record("转圈项的盒里必须有一个 NSProgressIndicator")
            return
        }

        // ① 形态必须是转圈——默认 bar 在 16×16 里渲染成强调色横条。
        #expect(
            circle.style == .spinning,
            "圈必须是 .spinning 形态（bar 会渲染成横条），实得 \(circle.style.rawValue)")

        // ② 宽高必须显式钉死 16——只给 center 时真机量到 0×18。
        let selfConstraints = circle.constraints
        #expect(
            selfConstraints.contains {
                $0.firstAttribute == .width && $0.secondAttribute == .notAnAttribute && $0.constant == 16
            },
            "圈必须显式钉宽 16（缺了真机被压成 0×18 竖线）")
        #expect(
            selfConstraints.contains {
                $0.firstAttribute == .height && $0.secondAttribute == .notAnAttribute && $0.constant == 16
            },
            "圈必须显式钉高 16（缺了真机被压成 0×18 竖线）")
    }
}
