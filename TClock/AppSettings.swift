import AppKit
import Combine
import CoreText
import ServiceManagement

/// 设置发生变化时广播（窗口管理器据此重排窗口、切换层级与穿透状态）。
extension Notification.Name {
    static let tclockSettingsChanged = Notification.Name("com.tclock.settingsChanged")
}

// MARK: - 日期格式预设

/// 日期行常用格式预设。`pattern` 直接作为 `DateFormatter.dateFormat` 使用。
/// 时间本身不再允许自定义格式，只由「24 / 12 小时制」决定。
struct DateFormatPreset: Identifiable, Hashable {
    let pattern: String
    let title: String

    var id: String { pattern }

    /// 只含年月日的预设：星期不出现在日期行，由下方独立开关控制。
    static let all: [DateFormatPreset] = [
        DateFormatPreset(pattern: "yyyy-MM-dd", title: NSLocalizedString("preset.date.iso", comment: "")),
        DateFormatPreset(pattern: "yyyy/MM/dd", title: NSLocalizedString("preset.date.slash", comment: "")),
        DateFormatPreset(pattern: "yyyy.MM.dd", title: NSLocalizedString("preset.date.dot", comment: "")),
        DateFormatPreset(pattern: "yyyy年M月d日", title: NSLocalizedString("preset.date.cnFull", comment: "")),
        DateFormatPreset(pattern: "M月d日", title: NSLocalizedString("preset.date.cnShort", comment: "")),
        DateFormatPreset(pattern: "MM/dd/yyyy", title: NSLocalizedString("preset.date.us", comment: "")),
        DateFormatPreset(pattern: "MMM d, yyyy", title: NSLocalizedString("preset.date.western", comment: "")),
    ]
}

// MARK: - 时间制式

/// 主体时间只有两种固定格式：24 小时制 / 12 小时制，秒始终显示。
enum HourCycle: String, CaseIterable, Identifiable {
    case twentyFour
    case twelve

    var id: String { rawValue }

    var display: String {
        switch self {
        case .twentyFour: return NSLocalizedString("time.hour24", comment: "")
        case .twelve: return NSLocalizedString("time.hour12", comment: "")
        }
    }

    var timePattern: String {
        switch self {
        case .twentyFour: return "HH:mm:ss"
        case .twelve: return "hh:mm:ss"
        }
    }
}

// MARK: - 时钟排版度量

/// 一次算清「日期 / 时间 / 星期·上下午」三行的字体与尺寸。
/// `ClockView` 用它给每行定 frame，`MainWindowManager.contentSize()` 用它定面板大小，
/// 两边共用同一份度量，窗口才不会裁掉文字或留一大块空白。
struct ClockLayout {
    let timeFont: NSFont
    let dateFont: NSFont
    let detailFont: NSFont

    /// 主体时间的最宽宽度（数字放宽成 8 后的测量值）。
    let timeWidth: CGFloat
    /// 三行共用的宽度：以主体时间为主，日期 / 星期·上下午更宽时才撑开。
    /// 三行都用同一个值 + `.leading`，左边缘天然对齐，下方行右端落在秒下方。
    let frameWidth: CGFloat

    let dateHeight: CGFloat
    let timeHeight: CGFloat
    let detailHeight: CGFloat
    let rowGap: CGFloat

    let showsDate: Bool
    let showsDetail: Bool

    /// 水平 / 垂直留白已计入，另含安全余量：等宽数字在 SwiftUI 里比 AppKit 度量略宽，
    /// 没有这段余量时窗口会把最后一个字符裁成「…」。
    var contentWidth: CGFloat { frameWidth + horizontalPadding * 2 + AppTheme.Metrics.clockWidthSlack }
    var contentHeight: CGFloat {
        var height = timeHeight
        if showsDate { height += dateHeight + rowGap }
        if showsDetail { height += detailHeight + rowGap }
        return height + verticalPadding * 2 + 2
    }

    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat

    init(
        timeFont: NSFont,
        dateFont: NSFont,
        detailFont: NSFont,
        timeWidth: CGFloat,
        frameWidth: CGFloat,
        dateHeight: CGFloat,
        timeHeight: CGFloat,
        detailHeight: CGFloat,
        rowGap: CGFloat,
        showsDate: Bool,
        showsDetail: Bool,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat
    ) {
        self.timeFont = timeFont
        self.dateFont = dateFont
        self.detailFont = detailFont
        self.timeWidth = timeWidth
        self.frameWidth = frameWidth
        self.dateHeight = dateHeight
        self.timeHeight = timeHeight
        self.detailHeight = detailHeight
        self.rowGap = rowGap
        self.showsDate = showsDate
        self.showsDetail = showsDetail
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }
}

// MARK: - 字重

enum FontWeightOption: String, CaseIterable, Identifiable {
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    var id: String { rawValue }

    var display: String {
        switch self {
        case .light: return NSLocalizedString("weight.light", comment: "")
        case .regular: return NSLocalizedString("weight.regular", comment: "")
        case .medium: return NSLocalizedString("weight.medium", comment: "")
        case .semibold: return NSLocalizedString("weight.semibold", comment: "")
        case .bold: return NSLocalizedString("weight.bold", comment: "")
        case .heavy: return NSLocalizedString("weight.heavy", comment: "")
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

// MARK: - 外观主题

/// 应用主题：默认跟随 macOS 系统外观，或强制浅色 / 深色。
/// 用 `NSApp.appearance` 生效，影响设置窗口、信息气泡与时钟面板；
/// 时钟文字颜色由用户单独设置，不随主题改变。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var display: String {
        switch self {
        case .system: return NSLocalizedString("appearance.system", comment: "")
        case .light: return NSLocalizedString("appearance.light", comment: "")
        case .dark: return NSLocalizedString("appearance.dark", comment: "")
        }
    }

    /// `nil` 表示清除覆盖、恢复跟随系统。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 预设位置

/// 时钟在屏幕四个角的预设坐标。**左下角**是默认初始化位置。
/// `origin(for:in:margin:)` 返回 AppKit 坐标（原点在屏幕左下）。
enum ClockCorner: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var display: String {
        switch self {
        case .topLeft: return NSLocalizedString("corner.topLeft", comment: "")
        case .topRight: return NSLocalizedString("corner.topRight", comment: "")
        case .bottomLeft: return NSLocalizedString("corner.bottomLeft", comment: "")
        case .bottomRight: return NSLocalizedString("corner.bottomRight", comment: "")
        }
    }

    /// 菜单里用完整说法，设置页按钮用简称。整条文案本地化，避免「简称 + 角」拼出英文不通顺。
    var menuTitle: String {
        switch self {
        case .topLeft: return NSLocalizedString("corner.topLeft.menu", comment: "")
        case .topRight: return NSLocalizedString("corner.topRight.menu", comment: "")
        case .bottomLeft: return NSLocalizedString("corner.bottomLeft.menu", comment: "")
        case .bottomRight: return NSLocalizedString("corner.bottomRight.menu", comment: "")
        }
    }

    static let `default`: ClockCorner = .bottomLeft

    /// 留白按屏幕短边自适应：大屏保持 48pt，小屏（低分辨率 / 缩放后点尺寸变小）
    /// 按比例收窄，避免时钟被挤得离边太远。
    static func margin(for visible: NSRect) -> CGFloat {
        min(AppTheme.Metrics.cornerMargin, min(visible.width, visible.height) * 0.06)
    }

    func origin(for size: NSSize, in visible: NSRect, margin: CGFloat) -> NSPoint {
        switch self {
        case .topLeft:
            return NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case .topRight:
            return NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        case .bottomLeft:
            return NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case .bottomRight:
            return NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        }
    }
}

// MARK: - 屏幕定位几何

/// 与屏幕尺寸相关的纯计算，集中在这里便于独立验证（不依赖窗口对象）。
enum ScreenGeometry {
    /// 窗口在可见区正中央的 origin。
    /// 窗口放得下时严格居中；比可见区还大时（异常小屏 / 超大窗口）夹到可见区，
    /// 并优先让**窗口顶部（标题栏）**留在屏幕内，而不是把标题栏顶出屏幕。
    static func centeredOrigin(for size: NSSize, in visible: NSRect) -> NSPoint {
        let x = min(
            max(visible.midX - size.width / 2, visible.minX),
            max(visible.minX, visible.maxX - size.width)
        )
        let y: CGFloat
        if size.height <= visible.height {
            y = min(
                max(visible.midY - size.height / 2, visible.minY),
                visible.maxY - size.height
            )
        } else {
            y = visible.maxY - size.height
        }
        return NSPoint(x: x, y: y)
    }
}

// MARK: - 字体目录

enum FontCatalog {
    /// 内建“系统字体”标识，对应 `NSFont.systemFont`。
    static let systemFamily = "System"

    private static let favorites = [
        "SF Pro Rounded",
        "Helvetica Neue",
        "Avenir Next",
        "PingFang SC",
        "Hiragino Sans GB",
        "Menlo",
        "Monaco",
        "Futura",
        "Georgia",
        "Times New Roman",
        "Impact",
    ]

    /// 系统字体族全集，常用字体置顶。
    @MainActor
    static let allFamilies: [String] = {
        let installed = NSFontManager.shared.availableFontFamilies
        var result = favorites.filter { installed.contains($0) }
        result.append(contentsOf: installed.filter { !result.contains($0) }.sorted())
        return result
    }()
}

// MARK: - 设置模型

/// 全局设置。所有字段改动后立即写入 `UserDefaults` 并广播通知，
/// 保证「设置窗口 → 时钟窗口」实时联动，重启后保持。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: 显示格式

    /// 是否在时间上方显示日期行。
    @Published var showDate: Bool { didSet { sync() } }
    /// 日期行格式串；留空时回退到 `yyyy-MM-dd`。时间本身不可自定义格式。
    @Published var datePattern: String {
        didSet {
            rebuildFormatters()
            sync()
        }
    }
    /// 主体时间：24 小时制 / 12 小时制（秒始终显示）。
    @Published var hourCycle: HourCycle {
        didSet {
            rebuildFormatters()
            sync()
        }
    }
    /// 12 小时制时，在秒的下方右侧显示上午 / 下午。
    @Published var showAMPM: Bool { didSet { sync() } }
    /// 在小时下方左侧显示星期，与上下午同一行。
    @Published var showWeekday: Bool { didSet { sync() } }

    // MARK: 外观

    @Published var fontFamily: String { didSet { sync() } }
    @Published var fontSize: Double { didSet { sync() } }
    @Published var fontWeight: FontWeightOption { didSet { sync() } }
    @Published var textColor: NSColor { didSet { sync() } }
    @Published var opacity: Double { didSet { sync() } }
    @Published var shadowEnabled: Bool { didSet { sync() } }
    /// 时:分:秒之间的冒号是否闪烁。
    @Published var blinkSeparator: Bool { didSet { sync() } }
    /// 应用主题（默认 / 浅色 / 深色）。
    @Published var appearanceMode: AppearanceMode { didSet { sync() } }
    /// 界面语言（跟随系统 / 简体中文 / 英文）。切换后由 LanguageManager 重启生效。
    @Published var language: AppLanguage { didSet { sync() } }

    // MARK: 窗口行为

    /// 锁定后窗口完全鼠标穿透：不可拖动、不可被选中，位置固定。
    @Published var isLocked: Bool { didSet { sync() } }
    /// 是否浮于其他窗口之上。
    @Published var alwaysOnTop: Bool { didSet { sync() } }

    /// 是否在系统菜单栏显示 TClock 图标。
    @Published var showMenuBarIcon: Bool { didSet { sync() } }

    @Published var originX: Double { didSet { sync() } }
    @Published var originY: Double { didSet { sync() } }
    @Published var hasOrigin: Bool { didSet { sync() } }

    /// 批量修改时暂停广播，避免一次操作触发多次重排。
    private var isSuspended = false

    private var dateFormatter = DateFormatter()
    private var timeFormatter = DateFormatter()
    private var ampmFormatter = DateFormatter()
    private var weekdayFormatter = DateFormatter()

    // MARK: - 初始化

    private init() {
        let defaults = UserDefaults.standard

        self.showDate = defaults.object(forKey: Keys.showDate) as? Bool ?? true
        self.datePattern = defaults.string(forKey: Keys.datePattern) ?? "yyyy-MM-dd"
        self.hourCycle = HourCycle(rawValue: defaults.string(forKey: Keys.hourCycle) ?? "") ?? .twentyFour
        self.showAMPM = defaults.object(forKey: Keys.showAMPM) as? Bool ?? true
        self.showWeekday = defaults.object(forKey: Keys.showWeekday) as? Bool ?? true
        self.fontFamily = defaults.string(forKey: Keys.family) ?? FontCatalog.systemFamily
        self.fontSize = defaults.object(forKey: Keys.size) as? Double ?? 96
        self.fontWeight = FontWeightOption(rawValue: defaults.string(forKey: Keys.weight) ?? "") ?? .regular

        if let components = defaults.array(forKey: Keys.color) as? [Double], components.count == 4 {
            self.textColor = NSColor(
                srgbRed: components[0],
                green: components[1],
                blue: components[2],
                alpha: components[3]
            )
        } else {
            self.textColor = .white
        }

        self.opacity = defaults.object(forKey: Keys.opacity) as? Double ?? 1.0
        self.shadowEnabled = defaults.object(forKey: Keys.shadow) as? Bool ?? true
        self.blinkSeparator = defaults.object(forKey: Keys.blink) as? Bool ?? true
        self.appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: Keys.appearanceMode) ?? ""
        ) ?? .system
        self.language = AppLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? .system
        self.isLocked = defaults.object(forKey: Keys.locked) as? Bool ?? false
        self.alwaysOnTop = defaults.object(forKey: Keys.onTop) as? Bool ?? true
        self.showMenuBarIcon = defaults.object(forKey: Keys.menuBarIcon) as? Bool ?? true
        self.originX = defaults.object(forKey: Keys.x) as? Double ?? 0
        self.originY = defaults.object(forKey: Keys.y) as? Double ?? 0
        self.hasOrigin = defaults.object(forKey: Keys.hasOrigin) as? Bool ?? false

        rebuildFormatters()
    }

    // MARK: - 文本生成

    /// App 生效语言的 locale 标识（跟随应用内语言切换，而不是系统偏好语言）。
    private static var effectiveIdentifier: String {
        Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
    }

    private func makeFormatter(_ pattern: String, twelveHour: Bool = false) -> DateFormatter {
        var components = Locale.Components(identifier: Self.effectiveIdentifier)
        // 中文等 locale 默认 24 小时制，会把 12 小时制的 hh 顶掉（显示 17 点）；
        // 显式指定 hourCycle 才能按用户选择渲染，同时让 a 输出「上午/下午」而非空串。
        components.hourCycle = twelveHour ? .oneToTwelve : .zeroToTwentyThree
        let formatter = DateFormatter()
        formatter.locale = Locale(components: components)
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter
    }

    /// 日期行只呈现年月日：把格式串里未加引号的星期字段符号（E / e / c）剔除。
    /// 星期由下方独立的开关控制，不在日期行重复出现；引号里的字面文本原样保留。
    private static func dateOnlyPattern(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "yyyy-MM-dd" }
        guard let regex = try? NSRegularExpression(pattern: "'[^']*'|[Eec]+") else { return trimmed }

        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        var result = ""
        var cursor = trimmed.startIndex
        for match in regex.matches(in: trimmed, range: fullRange) {
            guard let range = Range(match.range, in: trimmed) else { continue }
            result += trimmed[cursor..<range.lowerBound]
            let token = String(trimmed[range])
            if token.hasPrefix("'") { result += token }
            cursor = range.upperBound
        }
        result += trimmed[cursor...]

        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只剩分隔符（例如原本只写了 EEEE）时退回安全默认值。
        return result.rangeOfCharacter(from: .letters) == nil ? "yyyy-MM-dd" : result
    }

    private func rebuildFormatters() {
        let pattern = Self.dateOnlyPattern(datePattern)
        let is12 = hourCycle == .twelve

        dateFormatter = makeFormatter(pattern, twelveHour: is12)
        timeFormatter = makeFormatter(hourCycle.timePattern, twelveHour: is12)
        ampmFormatter = makeFormatter("a", twelveHour: true)
        weekdayFormatter = makeFormatter("EEEE", twelveHour: is12)
    }

    /// 日期行的显隐是独立开关，与格式串互不干扰。
    var showsDate: Bool { showDate }
    /// 上下午只在 12 小时制下有意义。
    var showsAMPM: Bool { hourCycle == .twelve && showAMPM }
    /// 下方一行由星期、上下午两者任意一个撑起。
    var showsDetailRow: Bool { showsAMPM || showWeekday }

    func dateText(for date: Date) -> String {
        showDate ? dateFormatter.string(from: date) : ""
    }

    func timeText(for date: Date) -> String {
        timeFormatter.string(from: date)
    }

    func ampmText(for date: Date) -> String {
        showsAMPM ? ampmFormatter.string(from: date) : ""
    }

    func weekdayText(for date: Date) -> String {
        showWeekday ? weekdayFormatter.string(from: date) : ""
    }

    // MARK: - 排版度量

    /// 覆盖一周内星期文本、上下午文本与最长月份文本的样本日期。
    private func probeDates() -> [Date] {
        var dates: [Date] = []
        let now = Date()
        for offset in 0..<8 {
            dates.append(now.addingTimeInterval(Double(offset) * 86_400))
        }
        let calendar = Calendar.current
        for components in [
            DateComponents(year: 2088, month: 12, day: 28, hour: 12, minute: 58, second: 58),
            DateComponents(year: 2088, month: 9, day: 9, hour: 8, minute: 38, second: 38),
            DateComponents(year: 2088, month: 1, day: 1, hour: 0, minute: 38, second: 38),
        ] {
            if let date = calendar.date(from: components) {
                dates.append(date)
            }
        }
        return dates
    }

    /// 数字放宽成 8，按最宽数字预留宽度，秒数变化不会让窗口与下方一行左右跳动。
    private func widened(_ text: String) -> String {
        String(text.map { $0.isNumber ? "8" : $0 })
    }

    /// 与 SwiftUI `.monospacedDigit()` 对齐：测量时也打开等宽数字特性。
    /// 否则 AppKit 量出的时间宽度偏小，SwiftUI 会把末尾的秒数截成「…」。
    private static func monospacedDigitFont(_ font: NSFont) -> NSFont {
        let features: [[NSFontDescriptor.FeatureKey: Any]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func measure(_ texts: [String], font: NSFont) -> (width: CGFloat, height: CGFloat) {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for text in texts {
            let size = (text as NSString).size(withAttributes: [.font: font])
            width = max(width, size.width)
            height = max(height, size.height)
        }
        // +2 抵消 NSString 度量与 SwiftUI 行高的细微差，行 frame 与面板尺寸都用它。
        return (ceil(width), ceil(height) + 2)
    }

    /// 计算当前设置下的三行排版。`scale` 供设置页缩略预览等比缩小。
    func clockLayout(scale: CGFloat = 1) -> ClockLayout {
        let mainSize = max(6, CGFloat(fontSize) * scale)
        let timeFont = resolvedFont(pointSize: mainSize)
        let dateFont = resolvedFont(pointSize: max(9, mainSize * AppTheme.Metrics.clockDateFontRatio))
        let detailFont = resolvedFont(pointSize: max(8, mainSize * AppTheme.Metrics.clockDetailFontRatio))

        // 测量用等宽数字字体，与 ClockView 的 `.monospacedDigit()` 一致。
        let monoTimeFont = Self.monospacedDigitFont(timeFont)
        let monoDateFont = Self.monospacedDigitFont(dateFont)
        let monoDetailFont = Self.monospacedDigitFont(detailFont)

        let dates = probeDates()
        let time = Self.measure(dates.map { widened(timeText(for: $0)) }, font: monoTimeFont)
        let date = showsDate
            ? Self.measure(dates.map { widened(dateText(for: $0)) }, font: monoDateFont)
            : (width: 0, height: 0)
        let weekday = showWeekday
            ? Self.measure(dates.map { weekdayText(for: $0) }, font: monoDetailFont)
            : (width: 0, height: 0)
        let ampm = showsAMPM
            ? Self.measure(dates.map { ampmText(for: $0) }, font: monoDetailFont)
            : (width: 0, height: 0)

        // 下方一行按「左星期 + 间距 + 右上下午」估宽，只在两者都显示时才加间距。
        let detailWidth = weekday.width + ampm.width
            + (showWeekday && showsAMPM ? AppTheme.Metrics.clockDetailMinGap : 0)
        let detailHeight = max(weekday.height, ampm.height)

        return ClockLayout(
            timeFont: timeFont,
            dateFont: dateFont,
            detailFont: detailFont,
            timeWidth: time.width,
            frameWidth: max(time.width, date.width, detailWidth),
            dateHeight: date.height,
            timeHeight: time.height,
            detailHeight: detailHeight,
            rowGap: max(2, mainSize * AppTheme.Metrics.clockRowGapRatio),
            showsDate: showsDate,
            showsDetail: showsDetailRow,
            horizontalPadding: max(10, mainSize * 0.10),
            verticalPadding: max(6, mainSize * 0.05)
        )
    }

    // MARK: - 字体

    /// 按绝对点值解析字体。
    func resolvedFont(pointSize: CGFloat) -> NSFont {
        let size = max(6, pointSize)
        let weight = fontWeight.nsWeight

        guard fontFamily != FontCatalog.systemFamily else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }

        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: fontFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 解析当前主体字体；`scale` 供设置页预览等比缩小使用。
    func resolvedFont(scale: CGFloat = 1) -> NSFont {
        resolvedFont(pointSize: CGFloat(fontSize) * scale)
    }

    // MARK: - 位置

    /// 拖动结束时调用：静默落盘，不触发窗口重排（避免回调风暴）。
    func updateOrigin(x: Double, y: Double) {
        isSuspended = true
        originX = x
        originY = y
        hasOrigin = true
        isSuspended = false

        let defaults = UserDefaults.standard
        defaults.set(x, forKey: Keys.x)
        defaults.set(y, forKey: Keys.y)
        defaults.set(true, forKey: Keys.hasOrigin)
    }

    func clearOrigin() {
        isSuspended = true
        hasOrigin = false
        isSuspended = false
    }

    // MARK: - 持久化

    private enum Keys {
        static let showDate = "tclock.showDate"
        static let datePattern = "tclock.datePattern"
        static let hourCycle = "tclock.hourCycle"
        static let showAMPM = "tclock.showAMPM"
        static let showWeekday = "tclock.showWeekday"
        static let family = "tclock.fontFamily"
        static let size = "tclock.fontSize"
        static let weight = "tclock.fontWeight"
        static let color = "tclock.textColor"
        static let opacity = "tclock.opacity"
        static let shadow = "tclock.shadow"
        static let blink = "tclock.blinkSeparator"
        static let appearanceMode = "tclock.appearanceMode"
        static let language = "tclock.language"
        static let locked = "tclock.locked"
        static let onTop = "tclock.alwaysOnTop"
        static let menuBarIcon = "tclock.showMenuBarIcon"
        static let x = "tclock.originX"
        static let y = "tclock.originY"
        static let hasOrigin = "tclock.hasOrigin"
    }

    private func sync() {
        guard !isSuspended else { return }
        save()
        NotificationCenter.default.post(name: .tclockSettingsChanged, object: nil)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(showDate, forKey: Keys.showDate)
        defaults.set(datePattern, forKey: Keys.datePattern)
        defaults.set(hourCycle.rawValue, forKey: Keys.hourCycle)
        defaults.set(showAMPM, forKey: Keys.showAMPM)
        defaults.set(showWeekday, forKey: Keys.showWeekday)
        defaults.set(fontFamily, forKey: Keys.family)
        defaults.set(fontSize, forKey: Keys.size)
        defaults.set(fontWeight.rawValue, forKey: Keys.weight)

        if let color = textColor.usingColorSpace(.sRGB) {
            defaults.set(
                [
                    Double(color.redComponent),
                    Double(color.greenComponent),
                    Double(color.blueComponent),
                    Double(color.alphaComponent),
                ],
                forKey: Keys.color
            )
        }

        defaults.set(opacity, forKey: Keys.opacity)
        defaults.set(shadowEnabled, forKey: Keys.shadow)
        defaults.set(blinkSeparator, forKey: Keys.blink)
        defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
        defaults.set(language.rawValue, forKey: Keys.language)
        defaults.set(isLocked, forKey: Keys.locked)
        defaults.set(alwaysOnTop, forKey: Keys.onTop)
        defaults.set(showMenuBarIcon, forKey: Keys.menuBarIcon)
        defaults.set(originX, forKey: Keys.x)
        defaults.set(originY, forKey: Keys.y)
        defaults.set(hasOrigin, forKey: Keys.hasOrigin)
    }
}

// MARK: - 开机启动

/// 登录项开关。
///
/// 本机长期用临时签名（CODE_SIGN_IDENTITY = "-"），`SMAppService.mainApp.register()`
/// 在这种签名下通常返回 `.requiresApproval` 或抛 kSMErrorInvalidSignature，无法可靠自启。
/// 因此以写 `~/Library/LaunchAgents/<bundle id>.plist`（RunAtLoad）为可靠主力，
/// 同时尽力向系统登录项登记，方便用户在「系统设置 › 通用 › 登录项」里看到；
/// 若系统登记真正成功则撤掉 LaunchAgent，避免同一 App 被启动两次。
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// 系统登录时是否会启动本 App。
    @Published private(set) var isEnabled = false
    /// 已登记但等用户在系统设置里批准（仅 SMAppService 路径）。
    @Published private(set) var needsApproval = false
    /// 最近一次操作的错误描述；nil 表示正常。
    @Published private(set) var errorMessage: String?

    /// 与 Bundle ID 保持一致；旧版本误用 com.kou.TClock，需一并清理残留。
    private let agentLabel = Bundle.main.bundleIdentifier ?? "com.wdk.TClock"
    private let legacyLabel = "com.kou.TClock"

    private init() {
        refresh()
    }

    private func agentURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private var agentURL: URL { agentURL(for: agentLabel) }
    private var legacyAgentURL: URL { agentURL(for: legacyLabel) }

    /// 重新读取真实状态：系统登录项已启用，或 LaunchAgent 文件存在，都算开启。
    func refresh() {
        needsApproval = SMAppService.mainApp.status == .requiresApproval
        isEnabled = SMAppService.mainApp.status == .enabled
            || FileManager.default.fileExists(atPath: agentURL.path)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        if enabled {
            // 清历史遗留 label，避免误判与重复启动。
            removeAgent(at: legacyAgentURL)
            // 主力：可靠 LaunchAgent —— 写盘后立即 load，本次会话即生效。
            writeAgent()
            loadAgent()
            // 补充：尽力登记系统登录项；成功则撤掉 LaunchAgent 防双启。
            // adhoc 签名下 register 会失败/卡在 requiresApproval，此时保留 LaunchAgent 兜底。
            if registerWithSystem() {
                unloadAgent()
                removeAgent()
            }
        } else {
            unregisterFromSystem()
            unloadAgent()
            removeAgent()
            removeAgent(at: legacyAgentURL)
        }
        refresh()
    }

    /// 返回 true 表示系统登录项真正启用（可安全撤掉 LaunchAgent）。
    private func registerWithSystem() -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled:
            return true
        case .notRegistered, .requiresApproval:
            do {
                try SMAppService.mainApp.register()
                return SMAppService.mainApp.status == .enabled
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    private func unregisterFromSystem() {
        guard SMAppService.mainApp.status != .notRegistered else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            errorMessage = String(
                format: NSLocalizedString("error.login.remove", comment: ""),
                error.localizedDescription
            )
        }
    }

    private func writeAgent() {
        // 直接执行 Mach-O，不依赖 `open -a` 在 launchd 会话里查找 App。
        let executable = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: agentURL)
        } catch {
            errorMessage = String(
                format: NSLocalizedString("error.login.create", comment: ""),
                error.localizedDescription
            )
        }
    }

    private func loadAgent() {
        runLaunchctl("load", "-w")
    }

    private func unloadAgent() {
        runLaunchctl("unload")
    }

    private func runLaunchctl(_ command: String, _ extra: String? = nil) {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        var args = [command]
        if let extra { args.append(extra) }
        args.append(agentURL.path)
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }

    private func removeAgent(at url: URL? = nil) {
        let target = url ?? agentURL
        try? FileManager.default.removeItem(at: target)
    }
}
