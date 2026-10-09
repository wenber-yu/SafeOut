import Foundation
import Testing

@testable import SafeOutApp

/// 更新入口的测试。
///
/// 这里锁定的不是业务逻辑，而是**上线时最容易填错的那个字符串**：
/// 常量填错既不会编译失败，也不会在开发环境暴露，只会在用户点按钮时落到 404。
@Suite("更新服务")
struct UpdateServiceTests {

    /// 直发版必须指向**真实存在**的 Releases 页。
    @Test func 直发版下载页指向本仓库的releases() throws {
        let url = try #require(UpdateService.updateSourceURL)
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path.hasSuffix("/releases"))
    }

    /// 常量已配置，应给出入口。
    @Test func 已配置下载页时给出更新入口() {
        #expect(UpdateService.canOpenUpdateSource)
    }

    /// **不存在 App Store 渠道**（2026-09-18 决定：本应用不上架 MAS）。
    ///
    /// 原先这里测的是 `normalizedAppStoreID`（把 `1234567890` 补成 `id1234567890`）。
    /// 那个函数连同 `.appStore` 分支一起删了，测试也一并删——
    /// **为一个不存在的渠道保留断言，等于把「渠道存在」继续钉在代码里**，
    /// 下一轮读的人会以为还有个渠道要照顾。
    ///
    /// 换成从**枚举本身**反查：谁把 `case appStore` 加回来，这条立刻红。
    /// 判据是「这个渠道不存在」，不是「现在跑不到」。
    @Test func 不存在AppStore渠道() {
        #expect(
            DistributionChannel(rawValue: "appStore") == nil,
            "本应用不上架 Mac App Store：`.appStore` 分支（收据判定 / appStoreID / macappstore://）已删除，别加回来"
        )
    }

    /// 测试进程是 `DEBUG` 构建 → 渠道应为开发版。
    ///
    /// 顺带钉住 `channel` 的判定口径：渠道只剩**编译期**可区分的两种，
    /// 若哪天改成「运行时读某个文件是否存在」，这条会红。
    @Test func 测试构建下渠道为开发版() {
        #expect(UpdateService.channel == .development)
    }
}
