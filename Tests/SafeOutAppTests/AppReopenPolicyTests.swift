import Foundation
import Testing

@testable import SafeOutApp

/// ``AppReopenPolicy/target(hasPendingAttention:)`` 的落点判据。
///
/// **为什么值得单测**：判错的表现是「点系统通知却开出了主窗口」—— 窗口**确实开了**，
/// 所以没有任何断言会因此变红、也不会崩；但主窗口成为 key window 后会把菜单面板
/// 顶掉，用户看不到「关闭并推出」。真机实测踩到过一次（2026-09-29 修复）。
@Suite("重新打开时的落点")
struct AppReopenPolicyTests {

    /// 点系统通知在系统层面就是一次「打开应用」事件 —— 有待处理提醒时必须落到面板上。
    @Test func 有待处理提醒时开菜单面板() {
        #expect(AppReopenPolicy.target(hasPendingAttention: true) == .attentionPanel)
    }

    /// 平时（没有提醒）仍然开主窗口：那是用户点 Dock 图标的常规预期。
    @Test func 没有提醒时开主窗口() {
        #expect(AppReopenPolicy.target(hasPendingAttention: false) == .mainWindow)
    }
}
