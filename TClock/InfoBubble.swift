import AppKit
import Foundation
import SwiftUI

// MARK: - 信息模型

/// 时钟气泡里展示的信息：公历日期 + 星期、农历。
/// 农历只在中文环境展示，非中文环境下 `lunarText` 为 nil。
struct ClockInfo {
    var dateText: String
    var lunarText: String?
}

@MainActor
enum ClockInfoProvider {
    /// 跟随 App 生效语言：设置里切换语言后 `Locale.current` 会随重启更新，
    /// 因此星期缩写（EEE）也会一起切换，不再固定读系统偏好语言。
    private static var baseLocale: Locale { Locale.current }

    static func current() -> ClockInfo {
        let now = Date()

        let dateFormatter = DateFormatter()
        dateFormatter.locale = baseLocale
        dateFormatter.dateFormat = "yyyy-MM-dd EEE"
        let dateText = dateFormatter.string(from: now)
        // 非中文环境不显示农历：直接置 nil，气泡视图按可选绑定跳过该行。
        let lunar = LanguageManager.isChinese
            ? NSLocalizedString("bubble.lunar", comment: "") + " " + lunarText(for: now)
            : nil

        return ClockInfo(
            dateText: dateText,
            lunarText: lunar
        )
    }

    // MARK: 农历

    private static let lunarMonths = [
        "lunar.month.1", "lunar.month.2", "lunar.month.3", "lunar.month.4", "lunar.month.5", "lunar.month.6",
        "lunar.month.7", "lunar.month.8", "lunar.month.9", "lunar.month.10", "lunar.month.11", "lunar.month.12",
    ]

    private static let lunarDays = [
        "lunar.day.1", "lunar.day.2", "lunar.day.3", "lunar.day.4", "lunar.day.5", "lunar.day.6", "lunar.day.7", "lunar.day.8", "lunar.day.9", "lunar.day.10",
        "lunar.day.11", "lunar.day.12", "lunar.day.13", "lunar.day.14", "lunar.day.15", "lunar.day.16", "lunar.day.17", "lunar.day.18", "lunar.day.19", "lunar.day.20",
        "lunar.day.21", "lunar.day.22", "lunar.day.23", "lunar.day.24", "lunar.day.25", "lunar.day.26", "lunar.day.27", "lunar.day.28", "lunar.day.29", "lunar.day.30",
    ]

    private static func lunarText(for date: Date) -> String {
        let calendar = Calendar(identifier: .chinese)
        let components = calendar.dateComponents([.month, .day, .isLeapMonth], from: date)

        let month = components.month ?? 1
        let day = components.day ?? 1
        let leap = components.isLeapMonth ?? false

        let monthKey = lunarMonths[max(0, min(lunarMonths.count - 1, month - 1))]
        let dayKey = lunarDays[max(0, min(lunarDays.count - 1, day - 1))]
        let monthName = NSLocalizedString(monthKey, comment: "")
        let dayName = NSLocalizedString(dayKey, comment: "")
        let leapPrefix = leap ? NSLocalizedString("lunar.leap", comment: "") : ""
        // 农历只在中文环境显示；模板用于把「闰 + 月 + 日」拼成规范中文写法。
        return String(
            format: NSLocalizedString("lunar.format", comment: ""),
            leapPrefix, monthName, dayName
        )
    }

}

// MARK: - 气泡形状

/// 带指针的圆角矩形（参照 macOS 原生提示气泡）。
///
/// 关键点：整块形状由**一条连续闭合路径**绘制 —— 顺时针走完圆角矩形，
/// 在底边（或顶边）中央用两段 `addQuadCurve` 收拢成指针，最后只 `closeSubpath()` 一次。
/// 上一版把圆角矩形与指针拼成两个子路径叠加，接缝处两条边各自抗锯齿，
/// 于是出现一条明显的深色横线；改成单条子路径后接缝消失。
struct BubbleShape: Shape {
    /// 圆角半径（浮层用大一档的圆角，取自统一 token）。
    var cornerRadius: CGFloat = AppTheme.Radius.bubble
    /// 指针宽度。
    var tailWidth: CGFloat = AppTheme.Metrics.bubbleTailWidth
    /// 指针高度。
    var tailHeight: CGFloat = AppTheme.Metrics.bubbleTailHeight
    /// 指针朝上（气泡挂在时钟下方时使用）。
    var tailOnTop = false

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let tailH = max(0, min(tailHeight, rect.height / 2))
        let halfTail = max(0, min(tailWidth / 2, rect.width / 2 - radius))

        // 主体区域：把指针高度让出来。
        let body = tailOnTop
            ? CGRect(
                x: rect.minX,
                y: rect.minY + tailH,
                width: rect.width,
                height: max(0, rect.height - tailH)
            )
            : CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: max(0, rect.height - tailH)
            )

        // 指针底边（与主体相接处）与尖端。
        let baseY = tailOnTop ? body.minY : body.maxY
        let tipY = tailOnTop ? rect.minY : rect.maxY
        // 控制点让指针两侧内凹，形成柔和的"小尾巴"而不是硬三角。
        let controlOffset = tailH * 0.62
        let controlY = tailOnTop ? baseY - controlOffset : baseY + controlOffset
        let midX = rect.midX

        var path = Path()

        if tailOnTop {
            // 从指针左根出发，顺时针绕一整圈。
            path.move(to: CGPoint(x: midX - halfTail, y: baseY))
            path.addQuadCurve(
                to: CGPoint(x: midX, y: tipY),
                control: CGPoint(x: midX - halfTail * 0.30, y: controlY)
            )
            path.addQuadCurve(
                to: CGPoint(x: midX + halfTail, y: baseY),
                control: CGPoint(x: midX + halfTail * 0.30, y: controlY)
            )
            path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: body.minY),
                tangent2End: CGPoint(x: body.maxX, y: body.maxY),
                radius: radius
            )
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                tangent2End: CGPoint(x: body.minX, y: body.maxY),
                radius: radius
            )
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: body.maxY),
                tangent2End: CGPoint(x: body.minX, y: body.minY),
                radius: radius
            )
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: body.minY),
                tangent2End: CGPoint(x: midX - halfTail, y: body.minY),
                radius: radius
            )
        } else {
            path.move(to: CGPoint(x: midX - halfTail, y: baseY))
            path.addQuadCurve(
                to: CGPoint(x: midX, y: tipY),
                control: CGPoint(x: midX - halfTail * 0.30, y: controlY)
            )
            path.addQuadCurve(
                to: CGPoint(x: midX + halfTail, y: baseY),
                control: CGPoint(x: midX + halfTail * 0.30, y: controlY)
            )
            path.addLine(to: CGPoint(x: body.maxX - radius, y: body.maxY))
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                tangent2End: CGPoint(x: body.maxX, y: body.minY),
                radius: radius
            )
            path.addArc(
                tangent1End: CGPoint(x: body.maxX, y: body.minY),
                tangent2End: CGPoint(x: body.minX, y: body.minY),
                radius: radius
            )
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: body.minY),
                tangent2End: CGPoint(x: body.minX, y: body.maxY),
                radius: radius
            )
            path.addArc(
                tangent1End: CGPoint(x: body.minX, y: body.maxY),
                tangent2End: CGPoint(x: midX + halfTail, y: body.maxY),
                radius: radius
            )
        }

        // 只闭合一次：整块形状始终只有一个子路径。
        path.closeSubpath()
        return path
    }
}

// MARK: - 气泡视图

/// 信息气泡：半透明纯色底 + token 化的圆角 / 描边 / 阴影 / 字号。
///
/// 背景不用毛玻璃：带指针的路径在裁剪边界会出现一条深色接缝线，
/// 纯色填充由 `BubbleShape` 一条连续路径一次成型最干净。
/// 深浅模式只切换 token 里的动态色，不覆盖 `colorScheme`，也不重写组件规则。
/// 弹出/收起的过渡动画在面板层（MainWindowManager）用 Core Animation 实现，
/// SwiftUI 视图本身不做动画，避免非激活面板上 SwiftUI 动画被节流导致闪烁。
struct InfoBubbleView: View {
    let info: ClockInfo
    var tailOnTop = false

    private var cornerRadius: CGFloat { AppTheme.Radius.bubble }
    private var tailWidth: CGFloat { AppTheme.Metrics.bubbleTailWidth }
    private var tailHeight: CGFloat { AppTheme.Metrics.bubbleTailHeight }
    /// 给阴影留出的绘制空间，`MainWindowManager` 的定位依赖这个值。
    private var shadowMargin: CGFloat { AppTheme.Metrics.bubbleShadowMargin }

    /// 主体与指针共用同一形状，避免圆角值写两遍。
    private var shape: BubbleShape {
        BubbleShape(
            cornerRadius: cornerRadius,
            tailWidth: tailWidth,
            tailHeight: tailHeight,
            tailOnTop: tailOnTop
        )
    }

    var body: some View {
        content
            .padding(.horizontal, AppTheme.Space.lg)
            .padding(.top, tailOnTop ? AppTheme.Space.xl : AppTheme.Space.md)
            .padding(.bottom, tailOnTop ? AppTheme.Space.md : AppTheme.Space.xl)
            .background(background)
            .padding(shadowMargin)
    }

    // MARK: 内容

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主标题：日期与星期，稍大一档并加字距，建立视觉重心。
            Text(info.dateText)
                .font(.system(size: AppTheme.Typography.bubbleTitle, weight: AppTheme.Typography.medium))
                .foregroundStyle(AppTheme.Palette.bubbleTextPrimary)
                .kerning(0.3)

            // 细分隔线拉开主次层次；没有农历时不显示。
            if info.lunarText != nil {
                Rectangle()
                    .fill(AppTheme.Palette.bubbleTextSecondary.opacity(0.22))
                    .frame(height: 0.5)
                    .padding(.vertical, AppTheme.Space.sm)
            }

            if let lunar = info.lunarText {
                detailLine(lunar)
            }
        }
        .monospacedDigit()
        .fixedSize()
    }

    /// 次级信息行：小圆点 + 文字，比主标题小一档、更柔和。
    private func detailLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.sm) {
            Circle()
                .fill(AppTheme.Palette.bubbleTextSecondary.opacity(0.55))
                .frame(width: 3, height: 3)
            Text(text)
                .font(.system(size: AppTheme.Typography.bubbleDetail, weight: AppTheme.Typography.regular))
                .foregroundStyle(AppTheme.Palette.bubbleTextSecondary)
                .lineLimit(1)
        }
    }

    // MARK: 背景

    private var background: some View {
        let shadow = AppTheme.Shadow.bubble
        return shape
            .fill(AppTheme.Palette.bubbleFill)
            .overlay {
                // 极细高光描边，让半透明浮层在浅色壁纸上也有清晰边界。
                shape.stroke(AppTheme.Palette.bubbleBorder, lineWidth: 0.5)
            }
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

// MARK: - 气泡窗口

/// 显示在时钟上方的小气泡：不接收鼠标事件、不抢焦点。
final class InfoBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
