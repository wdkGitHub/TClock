import AppKit
import QuartzCore
import SwiftUI

/// Apple / macOS 原生观感的统一设计 token。
///
/// 对应 `apple-native-ui-refactor` 技能里的 `design-tokens.css`，
/// 本项目是原生 AppKit + SwiftUI，没有 CSS，因此把 token 平移成 Swift 常量：
/// - **色值只允许出现在本文件**；组件内一律 `AppTheme.Palette.xxx`；
/// - **深浅模式只切换动态 `NSColor`**，不重写任何组件规则；
/// - 阴影 / 圆角 / 间距 / 字号成体系，组件里不再各写一套；
/// - 与窗口定位、事件时序相关的几何值集中在 `Metrics`，数值保持不变，
///   避免视觉改造影响窗口尺寸测量与定位逻辑。
///
/// 全部用「计算属性」而非全局存储属性，避免 Swift 6 严格并发下的全局状态告警。

// MARK: - 动态色值构造

/// 生成随系统外观自动切换的 `NSColor`。
/// `Color(nsColor:)` 会解析动态色，因此组件侧不需要 `@Environment(\.colorScheme)`。
private func dynamicNSColor(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: NSColor.Name(name)) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// 柔和阴影的描述体：组件不再各写一遍 color / radius / x / y。
struct ShadowToken {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum AppTheme {

    // MARK: - 配色（低饱和、冷中性灰、无纯黑纯红纯绿）

    enum Palette {
        /// 细腻边框，不抢视觉。
        static var borderSubtle: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.borderSubtle",
                light: NSColor(calibratedWhite: 0, alpha: 0.06),
                dark: NSColor(calibratedWhite: 1, alpha: 0.08)
            ))
        }

        static var borderDefault: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.borderDefault",
                light: NSColor(calibratedWhite: 0, alpha: 0.10),
                dark: NSColor(calibratedWhite: 1, alpha: 0.12)
            ))
        }

        /// 强调色：给后续自定义控件预留，系统控件仍用系统 accent。
        static var accent: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.accent",
                light: NSColor(srgbRed: 0.31, green: 0.43, blue: 0.97, alpha: 1),
                dark: NSColor(srgbRed: 0.44, green: 0.53, blue: 1.00, alpha: 1)
            ))
        }

        static var accentSoft: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.accentSoft",
                light: NSColor(srgbRed: 0.31, green: 0.43, blue: 0.97, alpha: 0.12),
                dark: NSColor(srgbRed: 0.44, green: 0.53, blue: 1.00, alpha: 0.18)
            ))
        }

        // MARK: 气泡（桌面浮层）

        /// 半透明纯色底：不用毛玻璃，避免带指针的路径在裁剪边界出现接缝。
        /// alpha 调低以增强通透感，让壁纸透出更多；文字对比度由阴影与细描边兜底。
        static var bubbleFill: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.bubbleFill",
                light: NSColor(calibratedWhite: 0.33, alpha: 0.66),
                dark: NSColor(calibratedWhite: 0.20, alpha: 0.70)
            ))
        }

        static var bubbleBorder: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.bubbleBorder",
                light: NSColor(calibratedWhite: 1, alpha: 0.16),
                dark: NSColor(calibratedWhite: 1, alpha: 0.12)
            ))
        }

        static var bubbleTextPrimary: Color {
            Color(nsColor: NSColor(calibratedWhite: 1, alpha: 0.98))
        }

        static var bubbleTextSecondary: Color {
            Color(nsColor: NSColor(calibratedWhite: 1, alpha: 0.80))
        }

        // MARK: 阴影色（冷调深色，不用纯黑）

        /// 时钟文字描边阴影。文字压在任意壁纸上，对比度优先，
        /// 因此透明度高于卡片阴影（这是有意的例外）。
        static var textEdgeShadow: Color {
            Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.14, alpha: 0.36))
        }

        static var textGlowShadow: Color {
            Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.14, alpha: 0.44))
        }

        static var bubbleShadowColor: Color {
            Color(nsColor: NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 0.26))
        }

        static var cardShadowColor: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.cardShadow",
                light: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.10),
                dark: NSColor(calibratedRed: 0.00, green: 0.00, blue: 0.00, alpha: 0.24)
            ))
        }

        // MARK: 指针表盘

        /// 表盘底：比气泡更淡，压住复杂壁纸但保留通透感。
        static var analogFaceFill: Color {
            Color(nsColor: dynamicNSColor(
                "tclock.analogFaceFill",
                light: NSColor(calibratedWhite: 0.28, alpha: 0.46),
                dark: NSColor(calibratedWhite: 0.14, alpha: 0.50)
            ))
        }

        /// 扫秒指针：沿用应用图标的琥珀色，与时分针拉开层次。
        static var analogSecondHand: Color {
            Color(nsColor: NSColor(srgbRed: 0.91, green: 0.72, blue: 0.47, alpha: 1))
        }
    }

    // MARK: - 圆角（大圆角是原生感的关键）

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        /// 卡片 14 起。
        static let card: CGFloat = 14
        /// 浮层气泡再放大一档。
        static let bubble: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: - 阴影（柔和多层，透明度克制）

    enum Shadow {
        static var bubble: ShadowToken {
            ShadowToken(color: Palette.bubbleShadowColor, radius: 9, x: 0, y: 3)
        }

        static var card: ShadowToken {
            ShadowToken(color: Palette.cardShadowColor, radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - 间距（8pt 网格）

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - 字号 / 字重（只用 400 / 500）

    enum Typography {
        /// 气泡主标题（日期），比次级信息大一档，拉开层次。
        static let bubbleTitle: CGFloat = 16
        static let bubbleLine: CGFloat = 14
        static let bubbleDetail: CGFloat = 13
        static let body: CGFloat = 13
        static let caption: CGFloat = 12

        static var regular: Font.Weight { .regular }
        static var medium: Font.Weight { .medium }
    }

    // MARK: - 动效（浮层弹出 / 收起）

    /// 气泡过渡：一次「淡入 + 轻微放大 + 朝时钟方向回位」，收起走同一条曲线反向短播。
    ///
    /// 这一版刻意不用弹簧与 anchorPoint 补偿：
    /// - 弹簧的 `settlingDuration` 会拖长到 0.4s+，既容易和鼠标离开判定撞车，
    ///   还要靠 `asyncAfter` 猜结束时刻，快速点两下就会出现两组动画打架；
    /// - 改 anchorPoint 到指针尖要同步补偿 position，静止态几何长期处于偏移状态。
    ///
    /// 现在只有一条固定时长的 `CAAnimationGroup`，起始值从 presentation layer 接管，
    /// 结束由 `CATransaction` completion 收窗，配合代次令牌避免过期回调。
    enum Motion {
        /// 弹出：略小 + 略靠近时钟 → 原位，淡入。
        static let bubblePresentDuration: TimeInterval = 0.22
        static let bubblePresentScale: CGFloat = 0.97
        static let bubblePresentOffset: CGFloat = 6
        /// 收起：快速淡出，只轻微缩小并往时钟方向退一点，不「被吞掉」。
        static let bubbleDismissDuration: TimeInterval = 0.14
        static let bubbleDismissScale: CGFloat = 0.985
        static let bubbleDismissOffset: CGFloat = 4

        /// 弹出曲线：平滑减速，起手不拖沓、收尾不弹跳。
        static var bubblePresentEase: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        }

        /// 收起曲线：起手留住、末尾迅速消失。
        static var bubbleDismissEase: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        }
    }

    // MARK: - 几何常量（数值保持原样，仅供集中管理）

    /// 这些值与窗口尺寸测量、气泡定位直接耦合，属于不可动红线，
    /// 这里只做「收拢」，不改数值。
    enum Metrics {
        static let clockEdgeRatio: CGFloat = 0.018
        static let clockGlowRatio: CGFloat = 0.12
        static let bubbleShadowMargin: CGFloat = 12
        static let bubbleTailWidth: CGFloat = 28
        static let bubbleTailHeight: CGFloat = 12
        static let previewHeight: CGFloat = 88
        static let previewScaleTarget: CGFloat = 32
        static let controlWidth: CGFloat = 200
        static let settingsMinWidth: CGFloat = 480
        static let settingsMinHeight: CGFloat = 440
        static let settingsContentWidth: CGFloat = 500
        static let settingsContentHeight: CGFloat = 560
        /// 四角预设离屏幕可见区边缘的留白。
        static let cornerMargin: CGFloat = 48
        /// 设置窗口「默认展示全部内容」时的自适应上限。
        static let settingsMaxWidth: CGFloat = 640
        static let settingsMaxHeight: CGFloat = 900
        /// 设置窗口与时钟重叠时让位到角落的边距。
        static let settingsEdgeMargin: CGFloat = 60

        // MARK: 时钟三行排版（时间为本体，其余两行按比例收敛）

        /// 日期行字号 = 主体字号 × 此系数（有 9pt 下限）。
        static let clockDateFontRatio: CGFloat = 0.26
        /// 星期 / 上下午行字号 = 主体字号 × 此系数（有 8pt 下限）。
        static let clockDetailFontRatio: CGFloat = 0.20
        /// 星期与上下午同时显示时的最小间距。
        static let clockDetailMinGap: CGFloat = 12
        /// 行间距 = 主体字号 × 此系数（最小 2pt）。
        static let clockRowGapRatio: CGFloat = 0.03
        /// 窗口宽度安全余量：SwiftUI 等宽数字比 AppKit 度量略宽，留一点余量避免尾部被裁。
        static let clockWidthSlack: CGFloat = 20

        // MARK: 指针表盘

        /// 表盘直径 = 主体字号 × 此系数（默认 96pt → 192pt）。
        static let analogDiameterRatio: CGFloat = 2.0
        /// 表盘外缘留白：给描边留位置，同时作为窗口尺寸的固定余量。
        static let analogPadding: CGFloat = 10
    }
}
