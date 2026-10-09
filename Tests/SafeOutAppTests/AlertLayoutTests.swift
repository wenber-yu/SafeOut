import AppKit
import SwiftUI
import Testing

@testable import SafeOutApp

/// 推出弹窗的**版式契约**：宽度、每一块的高度、行高、图标列，逐项对着设计稿实测值钉住。
///
/// ## 为什么不是「一条总高断言」
///
/// 原来只有一条 `弹窗高度与设计稿实测值一致`（容差 ±12pt）。它看着很稳，实际**掩盖了两处
/// 十几 pt 的偏差**：
///
/// 1. **基准值取自错误的量测时刻**：设计稿的图标是 `ds.js` 在 `DOMContentLoaded` 时水合出来的，
///    在那之前量 `.alert` 得到 A = **312.13**（警示块 54，2 行）；水合之后才是 A = **330.13**
///    （警示块 72，3 行）。早先记录的是前者 —— 基准本身就偏了 18pt。
/// 2. **±12 的容差刚好兜住 B 变体少掉的 11pt**：B 的「可能的原因」清单行高按 SwiftUI 默认排，
///    比设计稿的 `line-height: 1.45~1.55` 每行少 3pt，两条（其中一条折两行）累计差 11pt，
///    而断言一直是绿的。
///
/// 所以这里改成**逐块断言 + ±2pt 容差**，并把每一块的来源写在注释里。
///
/// ## 量测手法
///
/// - `sizeThatFits(in:)` 才认宽度约束；`NSHostingView.fittingSize` 返回的是**无宽度约束的
///   理想尺寸**，弹窗这类「宽度固定、高度自适应」的视图用它必然量错。
/// - 逐块高度用**做减法**得到：把某一块置空（`section: nil` / `callout: nil`）再量一次，
///   差值就是那一块连同它的上边距。
/// - 文案固定用设计稿那一份（`Samsung T7` + `Finder 1234` / `图像捕捉 5678`），才可比。
@MainActor
@Suite("弹窗版式")
struct AlertLayoutTests {

    // MARK: 设计稿实测值

    /// 设计稿 `screens/03-eject-flow.html` 的实测值（CSS px，与 SwiftUI 的 pt 同尺度）。
    ///
    /// **量测前提**：必须在**图标水合之后**量（`--virtual-time-budget` 让
    /// `DOMContentLoaded` 跑完，页面上应有 6 个 svg）。量测脚本与命令见
    /// `Design/ui/v2/DESIGN-SPEC.md` §8.3。
    private enum Spec {
        /// `.alert { width: 400px }`
        static let width: CGFloat = 400
        /// `.alert__head`（图标 38 与「标题 19.5 + 3 + 正文 36」取高者）
        static let head: CGFloat = 58.5
        /// `.alert__section { margin-top: 16px }`
        static let sectionTop: CGFloat = 16
        /// `.alert__foot { padding: 12px 20px }` + 按钮 30
        static let foot: CGFloat = 54

        /// A 变体总高（警示块折 3 行）
        static let busyTotal: CGFloat = 330.13
        /// A 的 `.alert__section`：`label 15.94 + 6 + list 59.69`
        static let busySection: CGFloat = 81.63
        /// A 的 `.callout`：`padding 9×2 + 18 × 3 行`
        static let busyCallout: CGFloat = 72

        /// B 变体总高
        static let failureTotal: CGFloat = 314.22
        /// B 的 `.alert__section`：`label 15.94 + 6 + causes 61.78`
        /// （causes = 折两行的 37.19 + gap 6 + 单行的 18.59）
        static let failureSection: CGFloat = 83.72
        /// B 的 `.callout`：`padding 9×2 + 18 × 2 行`
        static let failureCallout: CGFloat = 54

        /// 逐块容差：够吸收系统字体的亚像素取整，但拦得住任何一处 3pt 以上的偏差。
        static let tolerance: CGFloat = 2
    }

    // MARK: Fixtures

    private func makeDisk(name: String = "Samsung T7") -> DiskInfo {
        DiskInfo(
            id: "/Volumes/\(name)", bsdName: "disk99s1", volumeName: name,
            mountPath: "/Volumes/\(name)", totalBytes: 0, usedBytes: 0, freeBytes: 0,
            deviceProtocol: "USB", deviceModel: nil)
    }

    /// 与设计稿同一份数据：Finder 1234 + 图像捕捉 5678。
    private var designProcesses: [OccupyingProcess] {
        [
            OccupyingProcess(pid: 1234, processName: "Finder", displayName: "Finder", path: ""),
            OccupyingProcess(pid: 5678, processName: "Preview", displayName: "图像捕捉", path: ""),
        ]
    }

    /// ⚠️ **造模型也必须钉语言**，只钉渲染没用。
    ///
    /// `EjectAlertModel.busy(...)` / `.failure(...)` 内部就调用了 `L10n.tr`
    /// （标题、说明句、警示文案全在**构造时**解析成字符串），
    /// 之后渲染只是把这批已经成型的文本排版。若模型在钉住的作用域之外构造，
    /// 钉渲染就是白钉 —— 文案仍是 `Locale.current` 的那一份。
    ///
    /// 这是本 suite 相比 `OnboardingLayoutTests` 多出来的一个坑：
    /// 后者量的是纯 SwiftUI 视图（文本在 body 里解析），钉住渲染就够了。
    private var designBusy: EjectAlertModel {
        TestLanguage.with(TestLanguage.design) {
            .busy(disk: makeDisk(), occupying: designProcesses)
        }
    }

    private var designFailure: EjectAlertModel {
        TestLanguage.with(TestLanguage.design) {
            .failure(disk: makeDisk(), failure: .inUse)
        }
    }

    // MARK: 量测

    /// 按设计稿宽度量一个视图（`sizeThatFits(in:)` 才认宽度约束）。
    ///
    /// ⚠️ **在中文下渲染**：本文件所有高度基准（弹窗总高、头部、区块、提示块）都来自
    /// **中文实测**的设计稿，所以量之前必须先把语言钉住。不钉就跟随 `Locale.current`
    /// → 英文机器上必红（2026-09-17 CI 连续 6 次红即此因：四处高度差 18–19pt）。
    /// ⚠️ 同样用 `@autoclosure`：实参表达式（含 `L10n.tr`）必须在钉住的作用域内求值。
    private func size<V: View>(_ view: @autoclosure () -> V, width: CGFloat = Spec.width) -> CGSize {
        TestLanguage.with(TestLanguage.design) {
            _ = NSApplication.shared
            return NSHostingController(rootView: view()).sizeThatFits(
                in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        }
    }

    private func height(_ model: EjectAlertModel) -> CGFloat {
        size(EjectAlertView(model: model, onAction: { _ in })).height
    }

    /// 造一个只改指定字段的副本（逐块做减法用）。
    private func variant(
        _ base: EjectAlertModel,
        section: EjectAlertModel.Section?? = nil,
        callout: EjectAlertModel.Callout?? = nil,
        footNote: String?? = nil,
        actions: [EjectAlertModel.Action]? = nil
    ) -> EjectAlertModel {
        EjectAlertModel(
            icon: base.icon, title: base.title, subtitle: base.subtitle,
            section: section ?? base.section, callout: callout ?? base.callout,
            footNote: footNote ?? base.footNote, actions: actions ?? base.actions)
    }

    // MARK: 宽度

    /// 弹窗宽度是硬规格（设计稿 Handoff：400，最大 420）。
    ///
    /// **为什么钉住**：宽度决定「可能的原因」那类长句的断行位置，宽度飘了断行就飘了，
    /// 高度随之变化，与设计稿越走越远。
    @Test func 弹窗宽度等于设计稿的400() {
        for model in [designBusy, designFailure] {
            let width = size(EjectAlertView(model: model, onAction: { _ in })).width
            #expect(width == DesignTokens.Size.alertWidth, "\(model.title) 实际宽 \(width)")
        }
    }

    // MARK: 总高

    @Test func 占用弹窗总高与设计稿一致() {
        let actual = height(designBusy)
        #expect(
            abs(actual - Spec.busyTotal) <= Spec.tolerance,
            "A 变体应 \(Spec.busyTotal)（设计稿实测），实际 \(actual)")
    }

    @Test func 失败弹窗总高与设计稿一致() {
        let actual = height(designFailure)
        #expect(
            abs(actual - Spec.failureTotal) <= Spec.tolerance,
            "B 变体应 \(Spec.failureTotal)（设计稿实测），实际 \(actual)")
    }

    // MARK: 逐块

    /// 头部 = 标题 19.5 + 间距 3 + 正文 36 = 58.5；图标 38 比它矮，不参与定高。
    ///
    /// **这条同时守住行高**：标题按设计稿 `line-height: 1.3`（15 → 19.5）、正文按 `1.5`
    /// （12 → 18）。若退回 SwiftUI 默认行高（15/19），头部会掉到 56。
    @Test func 头部高度与设计稿一致() {
        for (label, model) in [("A", designBusy), ("B", designFailure)] {
            let bare = height(variant(model, section: .some(nil), callout: .some(nil)))
            // 内容内边距 20/16 + 操作区 54
            let head = bare - 20 - 16 - Spec.foot
            #expect(abs(head - Spec.head) <= Spec.tolerance, "\(label) 头部应 \(Spec.head)，实际 \(head)")
        }
    }

    /// 区块（含上边距 16）：A 是两行进程，B 是两条原因（第一条折两行）。
    ///
    /// **B 这条是行高的主要守卫**：设计稿的原因清单是行内 `line-height: 1.55`（12 → 18.6），
    /// 别处是 1.5。用 SwiftUI 默认行高会掉到 91（设计稿 99.72），差 8.7pt。
    @Test func 区块高度与设计稿一致() {
        let busySection = height(designBusy) - height(variant(designBusy, section: .some(nil)))
        #expect(
            abs(busySection - (Spec.busySection + Spec.sectionTop)) <= Spec.tolerance,
            "A 区块应 \(Spec.busySection + Spec.sectionTop)，实际 \(busySection)")

        let failureSection =
            height(designFailure) - height(variant(designFailure, section: .some(nil)))
        #expect(
            abs(failureSection - (Spec.failureSection + Spec.sectionTop)) <= Spec.tolerance,
            "B 区块应 \(Spec.failureSection + Spec.sectionTop)，实际 \(failureSection)")
    }

    /// 提示块（含上边距 12）：A 折 3 行（72）、B 折 2 行（54）。
    ///
    /// **折行数是文案与列宽共同的结果，必须钉住**：A 的警示文案正好卡在折行边界
    /// （每行 26 个汉字 = 312pt，列宽 316pt），列宽或行高任一处变动都会改变行数。
    @Test func 提示块高度与设计稿一致() {
        let busyCallout = height(designBusy) - height(variant(designBusy, callout: .some(nil)))
        #expect(
            abs(busyCallout - (Spec.busyCallout + 12)) <= Spec.tolerance,
            "A 提示块应 \(Spec.busyCallout + 12)（3 行），实际 \(busyCallout)")

        let failureCallout =
            height(designFailure) - height(variant(designFailure, callout: .some(nil)))
        #expect(
            abs(failureCallout - (Spec.failureCallout + 12)) <= Spec.tolerance,
            "B 提示块应 \(Spec.failureCallout + 12)（2 行），实际 \(failureCallout)")
    }

    /// 操作区 54 = 按钮 30 + 上下内边距 12（设计稿 `.alert__foot`）。
    ///
    /// **这条测的是「各块之和闭合到总高」**：头部先独立量出来（把区块、提示块、小标、按钮
    /// 全去掉 → 只剩 `20 + head + 16 + 24`），再用总高减去内边距与各块得到操作区。
    /// 于是它同时守住内容区上下内边距（20 / 16）—— 任何一处写错都会让操作区算出来不是 54。
    @Test func 各块之和闭合到总高且操作区为54() {
        for (label, model) in [("A", designBusy), ("B", designFailure)] {
            let headOnly = height(
                variant(
                    model, section: .some(nil), callout: .some(nil), footNote: .some(nil),
                    actions: []))
            let head = headOnly - 20 - 16 - 24

            let section = height(model) - height(variant(model, section: .some(nil)))
            let callout = height(model) - height(variant(model, callout: .some(nil)))
            let foot = height(model) - (20 + head + section + callout + 16)

            #expect(
                abs(foot - Spec.foot) <= Spec.tolerance,
                "\(label) 各块之和应闭合到操作区 54，实际 \(foot)（head=\(head) section=\(section) callout=\(callout)）")
        }
    }

    // MARK: 图标列

    /// 警示块图标列必须**固定 14pt**（设计稿 `.callout svg { width:14px; flex:none }`）。
    ///
    /// **量法**：把整块 `fixedSize(horizontal: true)` 让文字塌回单行理想宽度，
    /// 于是「整块宽 − 左右内边距 22 − 间距 8 − 文字宽」就是图标列宽。
    ///
    /// **为什么值得单独钉一条**：SF Symbol 在 14pt 字号下的包围盒是 **17pt 宽**
    /// （`exclamationmark.triangle` 实测 17×16）。少写这层 `frame` 编译照过、肉眼看也正常，
    /// 但文字列会从 316pt 缩到 313pt —— 而 A 的警示文案每行正好占 312pt，余量从 4pt 掉到 1pt。
    @Test func 警示块图标列固定为设计稿的14() {
        let text = "警示文案示例"
        let textWidth = size(
            Text(text).font(.system(size: DesignTokens.FontSize.caption)).fixedSize(), width: 4000
        ).width
        for symbol in ["exclamationmark.triangle", "doc", "xmark"] {
            let callout = AlertCallout(kind: .danger, systemImage: symbol, text: text)
                .fixedSize(horizontal: true, vertical: false)
            let column =
                size(callout, width: 4000).width
                - DesignTokens.Size.calloutPaddingH * 2 - DesignTokens.Spacing.sm - textWidth
            #expect(
                abs(column - DesignTokens.Size.calloutIconSize) <= 0.5,
                "\(symbol) 图标列应 14，实际 \(column)")
        }
    }

    // MARK: 行高

    /// 自然行高表必须与系统实测一致。
    ///
    /// `designLineHeight(_:fontSize:)` 靠这张表算「该补多少行间距」。系统字体的自然行高
    /// 不是字号的简单倍数（实测 11→14、12→15、13→16、15→19，比值在 1.23~1.27 之间跳），
    /// 所以表里是实测值。**这条会真的量一遍** —— 换系统字体或改字号时它会先红。
    @Test func 自然行高表与实测一致() {
        for fontSize in [CGFloat(11), 12, 13, 15] {
            let measured = size(Text("单").font(.system(size: fontSize)).fixedSize(), width: 4000)
                .height
            #expect(
                abs(measured - DesignTokens.naturalLineHeight(fontSize)) <= 0.5,
                "\(fontSize)pt 自然行高实测 \(measured)，表里写的是 \(DesignTokens.naturalLineHeight(fontSize))")
        }
    }

    /// `designLineHeight` 要真的产出设计稿的行高 —— 单行与多行都对。
    ///
    /// **为什么多行也要测**：`lineSpacing` 只补**行间**，单行文本完全不受它影响，
    /// 所以只测单行会漏掉「多行时每行都高一点」这种偏差；反过来只测多行会漏掉首行。
    /// 手法是 `lineSpacing(d)` + 上下各补 `d/2`，两者都要验证。
    @Test func 行高修饰器产出设计稿的行盒高度() {
        let size12 = DesignTokens.FontSize.caption
        let design = size12 * DesignTokens.LineHeight.relaxed  // 12 × 1.5 = 18

        let oneLine = size(
            Text("短").font(.system(size: size12))
                .designLineHeight(DesignTokens.LineHeight.relaxed, fontSize: size12).fixedSize(),
            width: 4000
        ).height
        #expect(abs(oneLine - design) <= 0.5, "单行应 \(design)，实际 \(oneLine)")

        // 60 个字在 316pt 列里是 3 行 → 3 × 18 = 54
        let threeLines = size(
            Text(String(repeating: "字", count: 60)).font(.system(size: size12))
                .designLineHeight(DesignTokens.LineHeight.relaxed, fontSize: size12)
                .frame(width: 316),
            width: 316
        ).height
        #expect(abs(threeLines - design * 3) <= 1, "3 行应 \(design * 3)，实际 \(threeLines)")
    }
}
