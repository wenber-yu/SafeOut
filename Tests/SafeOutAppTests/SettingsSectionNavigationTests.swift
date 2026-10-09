import Foundation
import Testing

@testable import SafeOutApp

/// 左栏分类的**顺序契约**。
///
/// ## v3 起这个文件只剩一条断言（原先七条）
///
/// 原先它守的是「↑/↓ 在分类间移动」那套算术 —— ``SettingsSection/moved(from:step:)``
/// 就是为此从视图里抽出来的纯函数，另配一条静态扫源码的「步长符号不能写反」。
///
/// v3 把设置搬进主窗口详情区、侧栏换成 ``MainSidebarView``（`List(selection:)` +
/// `.listStyle(.sidebar)`）之后，**那套接线整个消失**：方向键由系统 `List` 自己处理，
/// 源码里既没有 `moved(from:step:)` 也没有 `.onMoveCommand`
/// （实测 `grep -rn "func moved\|onMoveCommand" Sources/` 只剩一句注释）。
/// ⇒ 六条算术断言与那条源码扫描一起退役，**不是漏了**。
///
/// **判据没有丢**：系统 `List` 自带方向键导航，
/// 「侧栏方向键能上下移动、VoiceOver 报出选中项、改系统强调色侧栏跟着变」
/// 这三条仍在 `Design/ui/v3/HANDOFF.md` §7 的验收表里，真机走查。
/// 这里原来那条「纯函数算术」在 v3 已经没有可断言的对象了（函数不存在）。
///
/// 留下来的这一条与「谁处理方向键」无关：侧栏按 `allCases` 渲染，
/// **声明顺序即显示顺序**这条契约照样要有东西盯着。
struct SettingsSectionNavigationTests {

    /// 设计稿 09 页左栏逐项为：通用 → 外观 → 更新 → 诊断 → 关于。
    ///
    /// 没有这条断言时，有人把 `.about` 挪到第二位**不会让任何测试变红** ——
    /// 只会在走查图上表现为「顺序变了」，而走查图不进 CI。
    @Test func 分类的声明顺序就是左栏显示顺序() {
        #expect(
            SettingsSection.allCases == [.general, .appearance, .updates, .diagnostics, .about])
    }
}
