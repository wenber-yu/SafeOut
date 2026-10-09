import Foundation
import SwiftUI

/// 文案里的 **Markdown 行内标记**（设计稿用 `<b>` / `<strong>`）必须走这里渲染。
///
/// ## 为什么需要它
///
/// 设计稿侧的文案值允许带 `**加粗**`：`Tools/build_i18n.py` 的 `md_bold` 把成对的
/// `**X**` 换成 `<b>X</b>`，回填后由 `ds.js` 当 HTML 渲染 —— 设计稿里**显示为粗体**。
/// 那份转换器的注释写得很清楚：「直接回填会显示成裸星号」。
///
/// ⚠️ 但 app 侧 **`Text(String)` 不解析 Markdown**（只有 `LocalizedStringKey` 才解析）。
/// 所以「值里带 `**`、渲染时直接 `Text(string)`」在 app 里会**原样显示裸星号**。
///
/// 实测（`MarkdownCopyTests` 的口径锚，量的是渲染出来的理想宽度）：
///
/// | 渲染方式 | 宽度 |
/// |---|---|
/// | `Text(原样字符串)` | **289.0** |
/// | `Text(去掉 `**` 的字符串)` | 265.0 |
/// | `Text(AttributedString(markdown:))` | 265.0 |
///
/// 星号**真的占了宽度** ⇒ 那不是「粗体没生效」，是「星号被画出来了」。
///
/// ⇒ 约定：**凡是值里带 `**` 的文案键，渲染时必须经过 ``text(_:)``**。
/// 这条约定由 `MarkdownCopyTests` 两条守卫盯着：
/// ① 源码扫描（带 `**` 的键，其消费文件必须调用本函数）；
/// ② 端到端量宽（用真实文案渲染组件，星号不得占宽度）。
enum MarkdownCopy {

    /// 把文案当 **Markdown 行内标记**渲染。
    ///
    /// **为什么不把加粗拆成「前段 + 粗体词 + 后段」三个文案键**：那等于把语序写进
    /// 代码，英文里 `SafeOut` 的位置与中文不同，翻译者无法调整。
    /// 让文案自己带 `**` 标记，语序就完全归翻译者管。
    ///
    /// `inlineOnlyPreservingWhitespace` 是关键：它只解析行内标记，
    /// **保留换行** —— 设计稿的说明段中间有一个 `<br>`，不保留就会被合成一行。
    static func text(_ raw: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: raw, options: options) else {
            // 文案里有不成对的 `*` / `_` 时会解析失败 —— 退回纯文本，
            // 而不是把整段变成空白（那才是真正的「界面和设计不一样」）。
            return Text(raw)
        }
        return Text(attributed)
    }
}
