import SwiftUI

/// 时钟显示视图。
///
/// - 使用 `TimelineView` 按整秒对齐刷新（起点对齐到下一个整秒，避免秒数慢半拍），
///   半秒节拍用于冒号闪烁。
/// - 渲染完全由 `AppSettings` 驱动：格式串、字体、字号、颜色、透明度、阴影、冒号闪烁。
/// - `scale` 供设置页缩略预览使用。
struct ClockView: View {
    @EnvironmentObject private var settings: AppSettings

    var scale: CGFloat = 1

    /// 刷新相位：对齐到下一个整秒。
    @State private var anchor = ClockView.alignedAnchor()

    var body: some View {
        // 每秒一拍：更新数字，并按秒的奇偶翻转冒号。
        TimelineView(.periodic(from: anchor, by: 1)) { context in
            label(at: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func label(at date: Date) -> some View {
        let font = settings.resolvedFont(scale: scale)
        // 双阴影：一圈窄轮廓 + 一圈柔光，保证白字在浅色/深色壁纸上都清晰。
        // 比例与颜色都取自统一 token，组件内不再写死视觉常量。
        let edgeRadius = max(1, CGFloat(settings.fontSize) * scale * AppTheme.Metrics.clockEdgeRatio)
        let glowRadius = CGFloat(settings.fontSize) * scale * AppTheme.Metrics.clockGlowRatio

        return Text(displayText(for: date))
            .font(Font(font))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: settings.textColor))
            .opacity(settings.opacity)
            .modifier(
                TextGlow(
                    enabled: settings.shadowEnabled,
                    edgeRadius: edgeRadius,
                    glowRadius: glowRadius
                )
            )
            .fixedSize()
    }

    /// 生成显示文本。闪烁时把冒号字符设为透明 —— 宽度不变，所以窗口和数字都不会跳动。
    private func displayText(for date: Date) -> AttributedString {
        let raw = settings.text(for: date)
        var attributed = AttributedString(raw)

        guard settings.blinkSeparator else { return attributed }
        guard Self.separatorHidden(at: date) else { return attributed }

        var searchStart = raw.startIndex
        while let range = raw.range(of: ":", range: searchStart..<raw.endIndex) {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].foregroundColor = .clear
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    /// 一亮一灭：偶数秒隐藏，奇数秒显示。
    /// 不用 0.5 秒节拍 —— `TimelineView` 在后台窗口里会被系统节流到 1Hz，
    /// 那样时间戳永远落在隐藏相位，冒号就再也不出现了。
    private static func separatorHidden(at date: Date) -> Bool {
        Int(date.timeIntervalSince1970.rounded(.down)) % 2 == 0
    }

    static func alignedAnchor() -> Date {
        Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970))
    }
}

/// 文字描边 / 柔光。关闭时不改变内容，仅返回原视图。
private struct TextGlow: ViewModifier {
    let enabled: Bool
    let edgeRadius: CGFloat
    let glowRadius: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: AppTheme.Palette.textEdgeShadow, radius: edgeRadius)
                .shadow(color: AppTheme.Palette.textGlowShadow, radius: glowRadius)
        } else {
            content
        }
    }
}
