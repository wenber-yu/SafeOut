import Foundation

/// 从 `Info.plist` 读应用版本号与构建号。
///
/// **为什么单独抽出来**：设置窗口底部那行「版本 x · 构建 y · 渠道」是用户报 bug 时
/// 唯一能给出的定位信息 —— 它显示错了，后续排查全在错误的构建上做。
/// 而原先是 `SettingsView` 里两个 `private` 计算属性，**测试碰不到**，
/// 于是「读得到真值」这件事一直**没有任何守卫**（2026-09-17 核查时发现）。
///
/// ## 这里最容易静默失效的地方
///
/// `Bundle.main` 在两种运行方式下**完全不同**（实测，2026-09-17）：
///
/// | 运行方式 | `bundlePath` | `infoDictionary` |
/// |---|---|---|
/// | 裸可执行文件（`swift run` / 直接跑 `.build/debug/…`） | `.build/debug` | **0 个键** |
/// | `.app` bundle（`open` / 双击） | `…/SafeOut.app` | 5 个键 |
///
/// 也就是说：**跑法一变，版本号就从真值变成兜底值，而且不会报任何错。**
/// 所以这里**只负责读，不负责编** —— 读不到就返回 `nil`，把「怎么显示」留给调用方，
/// 免得「读失败」和「真值恰好等于兜底值」在测试里分不开。
///
/// ## 兜底值的取舍（`SettingsView` 那边）
///
/// 现在调用方兜底成 `"1.0.0"` / `"1"`。**这是已知的将就**：
/// 一个不存在的版本号比「未知」更糟（用户会照着报一个查不到的版本）。
/// 之所以还没改成显式「未知」，是因为走查快照由**测试进程**渲染，
/// 而 xctest runner 的 `Bundle.main` 同样没有这两个键 —— 改了会让所有对照图上的
/// 版本行变成「未知」，需要一并处理（见 `DESIGN-SPEC.md` §8.16）。
enum AppVersionInfo {

    /// `CFBundleShortVersionString`（打包时由 `build_app.sh` 写入，形如 `2026.09.13.1`）。
    ///
    /// **空字符串也算读不到**：`Info.plist` 里写了键但值为空，显示出来同样是空版本号。
    static func shortVersion(in bundle: Bundle = .main) -> String? {
        value(forKey: "CFBundleShortVersionString", in: bundle)
    }

    /// `CFBundleVersion`（构建号，按提交数递增，形如 `44`）。
    static func build(in bundle: Bundle = .main) -> String? {
        value(forKey: "CFBundleVersion", in: bundle)
    }

    /// 构建时的 git 提交短哈希（`DEBuildCommit`，形如 `a94f731`）。
    ///
    /// **为什么要它**：版本号取自最近的 tag，而 tag 只代表「某一次提交」。
    /// 报 bug 时给出 commit 哈希，才能精确定位到代码。
    static func commit(in bundle: Bundle = .main) -> String? {
        value(forKey: "DEBuildCommit", in: bundle)
    }

    /// 构建时**工作区里未提交的改动数**（`DEBuildDirtyCount`）。
    ///
    /// ## 这个数为什么必须显示出来
    ///
    /// `CFBundleShortVersionString` 取自最近的 tag，`CFBundleVersion` 是**提交总数** ——
    /// 两者都只反映**已提交**的代码。2026-09-17 用户发现：版本号停在 `2026.09.13.1`，
    /// 而工作区积压了 61 处未提交改动，其中就包含那几天修的所有 bug。
    /// 于是「版本 2026.09.13.1 · 构建 44」看起来像 9/13 那个正式构建，
    /// **实际跑的却是今天的工作区** —— 用户照着报的版本号会把人带到错误的代码上。
    ///
    /// 所以脏构建要在界面上说出来，而不是假装自己是 tag 对应的版本。
    ///
    /// - Returns: 改动数；`0` 表示工作区干净；键缺失或非数字时为 `nil`
    ///   （**不要拿 `0` 代替缺失** —— 「干净」与「不知道」是两回事）。
    static func dirtyCount(in bundle: Bundle = .main) -> Int? {
        guard let raw = value(forKey: "DEBuildDirtyCount", in: bundle) else { return nil }
        return Int(raw)
    }

    private static func value(forKey key: String, in bundle: Bundle) -> String? {
        guard let raw = bundle.infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
