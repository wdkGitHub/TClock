import SwiftUI

/// 时钟显示视图。
///
/// 布局固定为三行，**时间是主体**：
/// - 上方：日期（字号约为主体 1/4，居中）；
/// - 中间：24 / 12 小时制的时:分:秒（用户设置的字号、字体、颜色）；
/// - 下方：左侧星期、右侧上午/下午，同一行且左右边缘与主体时间对齐。
///
/// 三行的字体与宽度都由 `AppSettings.clockLayout(scale:)` 一次算好，
/// 视图里给每行定死 frame，窗口尺寸测量也用同一份结果，不会出现数字跳动或被裁切。
/// - `TimelineView` 按整秒对齐刷新（起点对齐到下一个整秒，避免秒数慢半拍）；
/// - `scale` 供设置页缩略预览使用。
struct ClockView: View {
    @EnvironmentObject private var settings: AppSettings

    var scale: CGFloat = 1

    /// 刷新相位：对齐到下一个整秒。
    @State private var anchor = ClockView.alignedAnchor()

    var body: some View {
        TimelineView(.periodic(from: anchor, by: 1)) { context in
            // ZStack 吃掉面板的全部空间，再把三行整体居中；
            // 直接给 VStack 加 maxHeight:.infinity 会把内容顶到上边。
            ZStack(alignment: .center) {
                rows(at: context.date)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func rows(at date: Date) -> some View {
        let layout = settings.clockLayout(scale: scale)
        let mainSize = CGFloat(settings.fontSize) * scale
        // 双阴影：一圈窄轮廓 + 一圈柔光，保证白字在浅色/深色壁纸上都清晰。
        let edgeRadius = max(1, mainSize * AppTheme.Metrics.clockEdgeRatio)
        let glowRadius = mainSize * AppTheme.Metrics.clockGlowRatio
        let color = Color(nsColor: settings.textColor)

        return VStack(alignment: .leading, spacing: layout.rowGap) {
            if layout.showsDate {
                Text(settings.dateText(for: date))
                    .font(Font(layout.dateFont))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    // 先按固有宽度排版再放进定宽 frame：宽度就算略小于实际也不会被截成「…」。
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: layout.frameWidth, height: layout.dateHeight, alignment: .leading)
            }

            Text(displayTime(for: date))
                .font(Font(layout.timeFont))
                .monospacedDigit()
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: layout.frameWidth, height: layout.timeHeight, alignment: .leading)

            if layout.showsDetail {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(settings.weekdayText(for: date))
                        .font(Font(layout.detailFont))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: AppTheme.Metrics.clockDetailMinGap)

                    Text(settings.ampmText(for: date))
                        .font(Font(layout.detailFont))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: true, vertical: false)
                }
                // 只用主体时间的宽度：三行左边缘一致，同时右端精确落在「秒」下方；
                // 日期格式再长也不会把上下午推出秒的右侧。
                .frame(width: layout.timeWidth, height: layout.detailHeight, alignment: .leading)
            }
        }
        .fixedSize()
        .opacity(settings.opacity)
        .modifier(
            TextGlow(
                enabled: settings.shadowEnabled,
                edgeRadius: edgeRadius,
                glowRadius: glowRadius
            )
        )
    }

    /// 主体时间文本。闪烁时把冒号字符设为透明 —— 宽度不变，所以窗口和数字都不会跳动。
    private func displayTime(for date: Date) -> AttributedString {
        let raw = settings.timeText(for: date)
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
