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
        Group {
            if settings.displayMode == .analog {
                AnalogClockView(scale: scale)
                    .environmentObject(settings)
            } else {
                TimelineView(.periodic(from: anchor, by: 1)) { context in
                    // ZStack 吃掉面板的全部空间，再把三行整体居中；
                    // 直接给 VStack 加 maxHeight:.infinity 会把内容顶到上边。
                    ZStack(alignment: .center) {
                        rows(at: context.date)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

/// 机械表风格的指针表盘。
///
/// - 8Hz 刷新模拟机械表扫秒；后台被系统节流到 1Hz 时读数依然正确；
/// - 表盘、刻度、日期窗、星期与三根指针都在一次 Canvas 绘制里完成，不会多层错位；
/// - 直径与字号共用 `AppSettings.analogLayout()`，设置页预览与面板尺寸一致。
struct AnalogClockView: View {
    @EnvironmentObject private var settings: AppSettings

    var scale: CGFloat = 1

    /// 机械表摆频的视觉节奏。比 60fps 省电，又不像 1Hz 那样一格一格跳。
    private static let tickInterval: TimeInterval = 1.0 / 8.0

    var body: some View {
        TimelineView(.periodic(from: Date(), by: Self.tickInterval)) { context in
            let layout = settings.analogLayout(scale: scale)
            let ink = Color(nsColor: settings.textColor)

            Canvas { canvas, size in
                Self.draw(
                    in: canvas,
                    size: size,
                    date: context.date,
                    layout: layout,
                    ink: ink,
                    weekday: settings.shortWeekdayText(for: context.date)
                )
            }
            .frame(width: layout.diameter, height: layout.diameter)
            .opacity(settings.opacity)
            .shadow(
                color: settings.shadowEnabled ? AppTheme.Palette.textEdgeShadow : .clear,
                radius: max(1, layout.diameter * AppTheme.Metrics.clockEdgeRatio)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 绘制

    private static func draw(
        in canvas: GraphicsContext,
        size: CGSize,
        date: Date,
        layout: AnalogLayout,
        ink: Color,
        weekday: String
    ) {
        let radius = min(size.width, size.height) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // 表盘底 + 细外圈：压住复杂壁纸，又不会像实心卡片那样厚重。
        let inset = max(1, radius * 0.025)
        let faceRect = CGRect(
            x: center.x - radius + inset,
            y: center.y - radius + inset,
            width: (radius - inset) * 2,
            height: (radius - inset) * 2
        )
        canvas.fill(Path(ellipseIn: faceRect), with: .color(AppTheme.Palette.analogFaceFill))
        canvas.stroke(
            Path(ellipseIn: faceRect),
            with: .color(ink.opacity(0.42)),
            lineWidth: max(0.6, radius * 0.008)
        )

        // 60 格刻度：整点长而亮，其余短而淡；0° 指向 12 点。
        for index in 0..<60 {
            let isHour = index % 5 == 0
            let angle = Double(index) * 6 * .pi / 180
            let inner = radius * (isHour ? 0.79 : 0.87)
            let outer = radius * 0.93
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + sin(angle) * inner, y: center.y - cos(angle) * inner))
            tick.addLine(to: CGPoint(x: center.x + sin(angle) * outer, y: center.y - cos(angle) * outer))
            canvas.stroke(
                tick,
                with: .color(ink.opacity(isHour ? 0.88 : 0.32)),
                lineWidth: radius * (isHour ? 0.016 : 0.006)
            )
        }

        // 3 点位日历窗 + 6 点位星期，始终显示（不受数字模式那两个显隐开关影响）。
        let apertureWidth = radius * 0.36
        let apertureHeight = radius * 0.25
        let aperture = CGRect(
            x: center.x + radius * 0.48 - apertureWidth / 2,
            y: center.y - apertureHeight / 2,
            width: apertureWidth,
            height: apertureHeight
        )
        let aperturePath = Path(
            roundedRect: aperture,
            cornerRadius: apertureHeight * 0.28,
            style: .continuous
        )
        canvas.fill(aperturePath, with: .color(ink.opacity(0.14)))
        canvas.stroke(aperturePath, with: .color(ink.opacity(0.34)), lineWidth: max(0.6, radius * 0.006))

        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        canvas.draw(
            Text("\(day)").font(Font(layout.dateFont)).foregroundColor(ink),
            at: CGPoint(x: aperture.midX, y: aperture.midY),
            anchor: .center
        )
        canvas.draw(
            Text(weekday).font(Font(layout.weekdayFont)).foregroundColor(ink.opacity(0.86)),
            at: CGPoint(x: center.x, y: center.y + radius * 0.58),
            anchor: .center
        )

        // 机械表是 12 小时盘；分针、秒针连续推进，扫秒不会一格一格跳。
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = CGFloat(components.hour ?? 0).truncatingRemainder(dividingBy: 12)
        let minute = CGFloat(components.minute ?? 0)
        let second = CGFloat(components.second ?? 0)
            + CGFloat(components.nanosecond ?? 0) / 1_000_000_000

        drawHand(
            in: canvas, center: center,
            angle: (hour + minute / 60) * 30,
            length: radius * 0.46, width: radius * 0.050, tail: radius * 0.08, color: ink
        )
        drawHand(
            in: canvas, center: center,
            angle: (minute + second / 60) * 6,
            length: radius * 0.70, width: radius * 0.034, tail: radius * 0.09, color: ink
        )
        drawHand(
            in: canvas, center: center,
            angle: second * 6,
            length: radius * 0.82,
            width: max(0.8, radius * 0.010), tail: radius * 0.16,
            color: AppTheme.Palette.analogSecondHand
        )

        let capRadius = max(1.5, radius * 0.035)
        let cap = CGRect(
            x: center.x - capRadius, y: center.y - capRadius,
            width: capRadius * 2, height: capRadius * 2
        )
        canvas.fill(Path(ellipseIn: cap), with: .color(AppTheme.Palette.analogSecondHand))
        canvas.stroke(Path(ellipseIn: cap), with: .color(ink.opacity(0.5)), lineWidth: max(0.5, radius * 0.004))
    }

    /// 局部坐标里指针指向 12 点（负 y），先旋转再平移到表盘中心。
    private static func drawHand(
        in canvas: GraphicsContext,
        center: CGPoint,
        angle: Double,
        length: CGFloat,
        width: CGFloat,
        tail: CGFloat,
        color: Color
    ) {
        let local = Path(
            roundedRect: CGRect(x: -width / 2, y: -length, width: width, height: length + tail),
            cornerRadius: width / 2,
            style: .continuous
        )
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: CGFloat(angle) * .pi / 180)
        canvas.fill(local.applying(transform), with: .color(color))
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
