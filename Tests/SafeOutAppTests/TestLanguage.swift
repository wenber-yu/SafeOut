import Foundation

@testable import SafeOutApp

/// 把测试钉在**确定的语言**下运行。
///
/// ## 为什么必须钉
///
/// 设计稿的排版数字（面板 480×920、引导窗 503.3、按钮 50 / 102、路径小标 226 …）
/// **全部按中文实测**。而 `L10n.tr` 的默认语言是 `Locale.current` ——
/// 于是「排版与设计稿一致」这类断言的结果**由运行机器的系统语言决定**：
/// 中文机器上绿，英文机器上红。同一份代码，两种结论。
///
/// 2026-09-17 实测：CI 连续 6 次红（从 `dd3d2d6` 起），19 个 issue 里 **18 个**都是它，
/// 而本地一直绿 —— 只因为开发机是中文环境。**这就是「换台机器必红」的环境依赖**。
///
/// ## 与 2026-09-12 `ed091d6` 的关系
///
/// 那次修的是同一类病的一半：「**期望值不要写死成某个中文字符串**」，
/// 改为与产品同源的 `L10n.tr(key)`。这次补上另一半 ——
/// 「**要断言中文排版，就得先明确地在中文下渲染**」。
/// 只做前一半，布局数字依然无处安放（英文下这些数字本来就不成立）。
///
/// ## 为什么用 `@TaskLocal` 而不是全局变量
///
/// swift-testing **并行**跑用例。全局可变状态会串台：一个用例把语言改成英文，
/// 另一个正在渲染的用例会跟着变，于是失败变成随机出现 —— 比环境依赖更难查。
/// 任务局部只在 `withValue` 闭包内生效、随子任务传播，天然按用例隔离。
enum TestLanguage {

    /// 设计稿的语言。**断言设计稿数字的用例都用它**。
    ///
    /// ## 本地怎么复现 CI 的英文环境
    ///
    /// 开发机是中文，而 CI 是英文 —— 「本地绿、CI 红」的差异没法在本地直接看。
    /// **把本行临时改成 `"en"` 就等于把本地变成 CI**：钉住的语言变成英文，
    /// 于是所有按中文实测的设计稿数字都会红，且红出来的数字与 CI 日志**逐位相同**
    /// （2026-09-17 实测：按钮 57.0 / 163.0、路径小标 384.0、设置面板 612.25）。
    ///
    /// 这同时是**钉是否还生效的判别实验**：改完若一条都不红，说明钉已经失效了
    /// （比如某处把 `L10n.tr` 挪出了 `withValue` 作用域），测试却还在绿 —— 那就是假绿。
    /// 用完必须改回 `"zh-Hans"`。
    static let design = "zh-Hans"

    /// 在指定语言下执行 `body`（同步）。
    ///
    /// ⚠️ **这里曾经还有一个 `async` 重载，2026-09-21 删掉了**（SPEC §8.113.20）——
    /// 两条独立的理由，任一条都够：
    ///
    /// 1. **零消费者**：全仓搜不到任何 `await TestLanguage.with`。它能活这么久，是因为
    ///    `DeclarationConsumerTests` 的口径是「**只看 `Sources/`**」（那里写着为什么），
    ///    所以 `Tests/` 里的死声明**不在它的射程内** —— 这是那条守卫的已知边界，不是它的 bug。
    /// 2. **踩了 deprecated API**：它调 `TaskLocal.withValue(_:operation:)`，而 CLT 的
    ///    Swift 6.4 把那个重载标成 deprecated（要改用 `nonisolated(nonsending)` 的那个），
    ///    `-warnings-as-errors` 下直接编译不过。
    ///
    /// ⇒ **将来真需要异步版时别照抄旧写法**：`operation` 参数必须写成
    /// `nonisolated(nonsending) () async throws -> T` 才会选中新重载，
    /// 写成裸的 `() async throws -> T` 又会掉回 deprecated 那个（这正是当初中招的写法）。
    static func with<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        try L10n.$forcedLocale.withValue(Locale(identifier: identifier), operation: body)
    }

    /// 取**设计稿语言**下的文案。
    ///
    /// 用途：断言「用了哪个 key」时，期望值应当与**渲染时同一语言**下解析出来的文本比对，
    /// 而不是写死一个中文字面量（那正是 `ed091d6` 修掉的写法）。
    static func designText(_ key: L10n.Key) -> String {
        L10n.tr(key, locale: Locale(identifier: design))
    }
}
