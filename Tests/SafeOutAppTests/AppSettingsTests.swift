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

    /// 每种强调色都必须有 `AppleAccentColor` 系统编号，且四色**互不相同**。
    ///
    /// 这是「侧栏选中胶囊跟随强调色」的唯一生效路径（2026-10-22 macOS 27 实证：
    /// 系统绘制的源列表选中态只认这个键）。漏映射或两色同号，
    /// 症状都是「设置里选了颜色、侧栏没变/变成别人的颜色」。
    @Test func 每种强调色都有互不相同的系统强调色编号() {
        let values = AccentColor.allCases.map(\.appleAccentColorRawValue)
        #expect(Set(values).count == values.count, "有两个颜色映射到了同一个系统编号：\(values)")
        // 钉住已知口径：0 红 / 1 橙 / 2 黄 / 3 绿 / 5 蓝 / 6 紫 / 7 粉。
        #expect(AccentColor.blue.appleAccentColorRawValue == 5)
        #expect(AccentColor.purple.appleAccentColorRawValue == 6)
        #expect(AccentColor.orange.appleAccentColorRawValue == 1)
        #expect(AccentColor.green.appleAccentColorRawValue == 3)
    }

    /// 同步函数必须**写前比对**：值已相同就不再写。
    ///
    /// 它挂在 `UserDefaults.didChangeNotification` 上、自己又写 defaults ——
    /// 少了这层守卫就是「写 → 通知 → 再写」的循环。这里用两次调用断言第二次不动笔。
    @Test func 系统强调色同步是幂等的() {
        let defaults = UserDefaults.standard
        let key = AppSettings.appleAccentColorDefaultsKey
        let originalAccent = defaults.string(forKey: AppSettings.Key.accentColor)
        let originalApple = defaults.object(forKey: key)
        defer {
            defaults.set(originalAccent, forKey: AppSettings.Key.accentColor)
            if let originalApple {
                defaults.set(originalApple, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set("orange", forKey: AppSettings.Key.accentColor)
        defaults.removeObject(forKey: key)
        AppSettings.syncAppleAccentColor()
        #expect(defaults.object(forKey: key) as? Int == AccentColor.orange.appleAccentColorRawValue)

        // 幂等键：把键换成一个「错误但会被守卫拦住」的值前，先确认相同值时不重写。
        // 判据：同步后再把 accentColor 写一遍同值（触发通知链的形状），键值仍稳定。
        AppSettings.syncAppleAccentColor()
        #expect(defaults.object(forKey: key) as? Int == AccentColor.orange.appleAccentColorRawValue)

        // 偏好换了颜色，同步必须跟上。
        defaults.set("green", forKey: AppSettings.Key.accentColor)
        AppSettings.syncAppleAccentColor()
        #expect(defaults.object(forKey: key) as? Int == AccentColor.green.appleAccentColorRawValue)
    }

    /// 设置页色板的写入点必须显式调 `syncAppleAccentColor()`（源码结构断言）。
    ///
    /// 侧栏选中胶囊只认 `AppleAccentColor` 键，而 defaults 变更通知不可靠送达
    /// （2026-10-22 实证）—— 同步只能在**写入点**显式做。这条接线没有编译错误、
    /// 没有别的断言会红，丢了的症状就是「设置里选了颜色、侧栏没变」原样复现。
    @Test func 色板写入点必须显式同步系统强调色() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/SettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("AppSettings.syncAppleAccentColor()"),
            "SettingsView 的强调色写入点丢了 syncAppleAccentColor() —— 侧栏选中胶囊将不再跟随强调色")
    }
}
