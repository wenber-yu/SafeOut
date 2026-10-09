import Testing

@testable import SafeOutApp

/// 「打开『推出时提醒占用』时，要不要顺带引导用户去授辅助功能权限」的判据。
///
/// ## 为什么这条判据值得单测
///
/// 它判错的**两个方向都是真实缺陷**，而两个都**不会让任何别的断言变红**：
///
/// - **恒真** ⇒ 已经授权的用户每次拨这个开关都要被弹一次 —— 他刚在系统设置里点过，
///   这就是纯噪音（同 ``AppSettings/TakeOverAvailability`` 那条「已授权的用户
///   不该被权限提示反复打扰」）。
/// - **恒假** ⇒ 提示永不出现。而它提示的是一项**没有也不影响使用**的权限
///   （关系统框会静默降级到「结束弹框进程」），界面别处**没有任何痕迹**
///   ⇒ 用户永远不知道它存在。这正是本次要修的那个问题。
///
/// 判据本身是纯的（只吃一个布尔），所以这里能穷举两个方向 ——
/// 真实授权状态由 ``SystemEjectDialogDismisser/isAccessibilityTrusted`` 提供，
/// 那个函数不做判断，只转发系统 API。
@Suite("辅助功能引导的触发判据")
struct AccessibilityOnboardingTests {

    @Test("没授权时才引导")
    func 没授权时才引导() {
        #expect(SystemEjectDialogDismisser.shouldSuggestAccessibility(isTrusted: false))
    }

    @Test("已授权就不再打扰")
    func 已授权就不再打扰() {
        #expect(!SystemEjectDialogDismisser.shouldSuggestAccessibility(isTrusted: true))
    }
}
