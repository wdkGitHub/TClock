import AppKit
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
    }
}
