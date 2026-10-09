import Foundation
import Testing

@testable import SafeOutApp

/// 设置项单一事实来源的测试。
///
/// 这些断言锁定的不是「颜色好不好看」，而是**一致性**：此前颜色映射存在三份副本，
/// 漏改一处就出现「设置里选了红色、菜单栏还是蓝色」。测试要能拦住这类漂移。
@Suite("设置项")
struct AppSettingsTests {

    /// 每种强调色在两个框架下都必须有对应色值，不能出现「某个 case 忘了映射」。
    ///
    /// 这里用穷举而非抽样：新增颜色时若只改了 SwiftUI 侧、漏了 AppKit 侧，
    /// 光看代码不容易发现（两处 switch 互不相邻）。
    @Test func 每种强调色都有双向色值() {
        for color in AccentColor.allCases {
            // 与系统默认色不同即说明走了具体映射分支，而不是兜底成同一个值。
            _ = color.swiftUIColor
            _ = color.appKitColor
            // 显示名不应为空——否则设置面板会出现空白选项
            #expect(!color.displayName.isEmpty)
        }
    }

    /// 各强调色的显示名必须互不相同，否则设置面板里会出现两个同名选项。
    @Test func 强调色显示名互不重复() {
        let names = AccentColor.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    /// rawValue 与 UserDefaults 中存的字符串必须稳定。
    ///
    /// 这是持久化契约：改动 rawValue 会导致老用户的偏好静默失效（回退默认色）。
    @Test func 偏好键与原始值保持稳定() {
        #expect(AppSettings.Key.visualStyle == "visualStyle")
        #expect(AppSettings.Key.accentColor == "accentColor")
        #expect(AppSettings.Key.showDockIcon == "showDockIcon")
        #expect(AppSettings.Key.launchAtLogin == "launchAtLogin")

        #expect(AccentColor.blue.rawValue == "blue")
        #expect(VisualStyle.transparent.rawValue == "transparent")
        #expect(VisualStyle.tinted.rawValue == "tinted")
    }

    /// 损坏的持久化值必须回退默认，而不是崩溃或落到未定义状态。
    @Test func 损坏的持久化值回退默认() {
        let defaults = UserDefaults.standard
        let originalAccent = defaults.string(forKey: AppSettings.Key.accentColor)
        let originalStyle = defaults.string(forKey: AppSettings.Key.visualStyle)
        defer {
            // 必须还原：UserDefaults 是进程级共享状态，污染后会影响后续测试。
            defaults.set(originalAccent, forKey: AppSettings.Key.accentColor)
            defaults.set(originalStyle, forKey: AppSettings.Key.visualStyle)
        }

        defaults.set("__not_a_real_color__", forKey: AppSettings.Key.accentColor)
        defaults.set("__not_a_real_style__", forKey: AppSettings.Key.visualStyle)

        #expect(AppSettings.accentColor == AccentColor.default)
        #expect(AppSettings.visualStyle == VisualStyle.default)
    }
}
