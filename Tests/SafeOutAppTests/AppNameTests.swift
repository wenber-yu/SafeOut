import Foundation
import Testing

@testable import SafeOutApp

/// 应用名的本地化测试。
///
/// 名字会被三处「用户要去对号入座」的地方展示：Dock、菜单栏 App 菜单、关于面板，
/// 以及**系统设置 › 隐私与安全性 › 完全磁盘访问里的授权列表**。FDA 引导文案让用户
/// 「在列表中找到本应用并打开开关」——若某种语言漏配或退回英文名，用户就会在系统设置里
/// 找不到与之对应的条目。所以把「三语齐全且各自正确」钉成测试，而不是依赖人工核对。
@Suite("应用名")
struct AppNameTests {

    @Test func 简体中文显示中文名() {
        #expect(L10n.tr(.appName, locale: Locale(identifier: "zh-Hans")) == "磁盘推出助手")
    }

    @Test func 繁体中文显示繁体名() {
        #expect(L10n.tr(.appName, locale: Locale(identifier: "zh-Hant")) == "磁碟推出助手")
    }

    /// 英文环境保留英文名：`SafeOut` 是仓库名与 `.app` 产物名，英文用户看到它才找得到对应产物。
    @Test func 英文环境显示英文名() {
        #expect(L10n.tr(.appName, locale: Locale(identifier: "en")) == "SafeOut")
    }
}
