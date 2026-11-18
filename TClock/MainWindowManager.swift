import AppKit
import QuartzCore
import SwiftUI

extension Notification.Name {
    /// 请求把时钟移回默认位置（左下角）。
    static let tclockResetPosition = Notification.Name("com.tclock.resetPosition")
    /// 请求把时钟移到某个预设角落；`userInfo["corner"]` 为 `ClockCorner.rawValue`。
    static let tclockApplyCorner = Notification.Name("com.tclock.applyCorner")
}

// MARK: - 时钟面板

/// 无边框 + 非激活面板。
///
/// 关键点：
/// - `.nonactivatingPanel` 让点击/拖动时钟时不激活本应用，前台应用不会被打断；
/// - `canBecomeKey = false` 让面板永远不夺取键盘焦点，即“不会被选中”；
/// - `orderFrontRegardless()` 显示，不触发激活。
final class ClockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 拖动手柄

/// 覆盖在时钟之上的一层透明视图，专门负责拖动窗口。
/// 与 SwiftUI 内容解耦，保证任何字体/内容下都能整窗拖动。
final class DragHandleView: NSView {
    /// 首次真正移动（越过抖动阈值）时回调，用于移动前立即收起气泡。
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private var isDragging = false
    private var didMove = false
    private var mouseStart = NSPoint.zero
    private var originStart = NSPoint.zero

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        isDragging = true
        didMove = false
        mouseStart = NSEvent.mouseLocation
        originStart = window.frame.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let window else { return }
        let point = NSEvent.mouseLocation
        if !didMove && (abs(point.x - mouseStart.x) > 2 || abs(point.y - mouseStart.y) > 2) {
            didMove = true
            // 移动刚开始就通知，先收起气泡，避免它悬在原地。
            onDragStart?()
        }
        window.setFrameOrigin(
            NSPoint(
                x: originStart.x + (point.x - mouseStart.x),
                y: originStart.y + (point.y - mouseStart.y)
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()

        // 真正拖动过：保存位置，不当作点击。
        if didMove {
            onDragEnd?()
            return
        }

        if event.clickCount == 2 {
            // 双击：取消待触发的单击（否则信息气泡会先闪一下）。
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fireClick), object: nil)
            onDoubleClick?()
        } else if event.clickCount == 1 {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fireClick), object: nil)
            perform(#selector(fireClick), with: nil, afterDelay: 0.26)
        }
    }

    @objc private func fireClick() {
        onClick?()
    }

    /// 右键时钟弹出快捷菜单（菜单栏图标被系统隐藏时的备用入口）。
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

// MARK: - 设置窗口

/// 承载 SwiftUI 设置面板的普通窗口。
/// 不走 SwiftUI `Settings` 场景，避免“菜单栏入口 + 系统设置窗口”两套窗口并存。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settings: AppSettings) {
        let hosting = NSHostingController(rootView: SettingsView().environmentObject(settings))
        let window = NSWindow(contentViewController: hosting)

        window.title = NSLocalizedString("window.settings.title", comment: "")
        // 偏好设置允许缩放；扁平表单内容自适应窗口宽度。
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()

        // 默认展示全部设置项：按 SwiftUI 表单的 fittingSize 定窗口高度，
        // 再夹到屏幕可见范围内。用户仍可手动缩小（缩小后表单内部滚动）。
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let screenHeight = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 1000
        let maxHeight = min(screenHeight - 80, AppTheme.Metrics.settingsMaxHeight)
        let idealHeight = fitting.height > 0
            ? fitting.height
            : AppTheme.Metrics.settingsContentHeight
        let width = min(
            max(fitting.width, AppTheme.Metrics.settingsMinWidth),
            AppTheme.Metrics.settingsMaxWidth
        )
        let height = min(max(idealHeight, AppTheme.Metrics.settingsMinHeight), maxHeight)
        window.setContentSize(NSSize(width: width, height: height))
        // 缩放下限：再小分组表单就会被挤坏。与 SettingsView 共用同一组 token。
        window.contentMinSize = NSSize(
            width: AppTheme.Metrics.settingsMinWidth,
            height: AppTheme.Metrics.settingsMinHeight
        )

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 窗口 / 菜单栏管理器

/// 负责时钟面板、菜单栏图标与菜单、设置窗口。
@MainActor
final class MainWindowManager: NSObject, NSMenuDelegate {
    private let settings = AppSettings.shared

    private var panel: ClockPanel?
    private var dragHandle: DragHandleView?
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?

    private var visibleItem: NSMenuItem?
    private var lockItem: NSMenuItem?
    private var onTopItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    private var isPanelVisible = true
    /// 最近一次选中的预设角。非 nil 时，屏幕分辨率变化 / 窗口尺寸变化会重新贴角。
    /// 用户手动拖动后清空，改为「记住自由坐标」。
    private var activeCorner: ClockCorner?

    // MARK: - 启动

    func start() {
        // 先定主题再建窗口，避免首帧闪一下系统外观。
        applyAppearance()
        buildPanel()
        applyMenuBarVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .tclockSettingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetPosition),
            name: .tclockResetPosition,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyCornerFromNotification),
            name: .tclockApplyCorner,
            object: nil
        )
        // 分辨率 / 缩放 / 外接屏插拔都会发这个通知，预设角需要按新屏幕重算。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        showPanel()
        // 重启后若保存的位置正好落在某个角，也视为「贴角」，
        // 之后换分辨率会继续贴住同一个角。
        activeCorner = currentCorner
    }

    // MARK: - 面板构建

    private func buildPanel() {
        let size = contentSize()
        let panel = ClockPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.level = settings.alwaysOnTop ? .floating : .normal
        panel.ignoresMouseEvents = settings.isLocked
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true

        let hosting = NSHostingView(rootView: AnyView(ClockView().environmentObject(settings)))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // 关键：禁止 SwiftUI 反向协商窗口尺寸，窗口大小只由字体测量决定，
        // 否则内容布局稳定后窗口会被压成内容的最小固有尺寸。
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)

        let handle = DragHandleView(frame: container.bounds)
        handle.autoresizingMask = [.width, .height]
        // 移动时钟时立即收起，不播动画，避免气泡缩放着跟随窗口。
        handle.onDragStart = { [weak self] in self?.hideInfoBubble(animated: false) }
        handle.onDragEnd = { [weak self] in
            self?.persistPosition()
            self?.hideInfoBubble()
        }
        handle.onDoubleClick = { [weak self] in self?.presentSettings() }
        handle.onClick = { [weak self] in self?.toggleInfoBubble() }
        handle.menuProvider = { [weak self] in self?.makeContextMenu() }
        container.addSubview(handle)

        panel.contentView = container

        self.panel = panel
        self.dragHandle = handle
    }

    private func showPanel() {
        guard let panel else { return }

        if settings.hasOrigin {
            panel.setFrameOrigin(NSPoint(x: settings.originX, y: settings.originY))
            ensureOnScreen()
        } else {
            moveToDefaultPosition()
        }

        panel.orderFrontRegardless()
        isPanelVisible = true
        updateMenuStates()
    }

    /// 依据三行排版度量估算面板尺寸（按「最宽样本」预留，避免秒数/日期变化时窗口忽宽忽窄）。
    private func contentSize() -> NSSize {
        let layout = settings.clockLayout()
        guard layout.contentWidth > 0 else { return NSSize(width: 320, height: 120) }
        return NSSize(width: ceil(layout.contentWidth), height: ceil(layout.contentHeight))
    }

    private func resizePanel() {
        guard let panel else { return }
        let newSize = contentSize()
        let current = panel.frame.size

        guard abs(current.width - newSize.width) > 0.5 || abs(current.height - newSize.height) > 0.5 else {
            return
        }

        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var frame = panel.frame
        frame.size = newSize
        frame.origin = clampedOrigin(
            NSPoint(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2),
            size: newSize
        )
        panel.setFrame(frame, display: true)
        settings.updateOrigin(x: frame.origin.x, y: frame.origin.y)
    }

    /// 放大字号后把窗口收进屏幕可见范围，避免越界后“消失”。
    private func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let screen = positioningScreen(reference: center) else {
            return origin
        }
        let visible = screen.visibleFrame
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, visible.minX), maxX),
            y: min(max(origin.y, visible.minY), maxY)
        )
    }

    /// 从其他屏幕/分辨率切换回来后，若窗口飘到可见区域外则拉回主屏。
    private func ensureOnScreen() {
        guard let panel else { return }
        let frame = panel.frame

        let isVisible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return !overlap.isNull && overlap.width >= 80 && overlap.height >= 40
        }

        if !isVisible {
            moveToDefaultPosition()
        }
    }

    /// 可用的目标屏幕（非激活状态下 `NSScreen.main` 可能为 nil）。
    private var targetScreen: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    /// 定位目标屏幕：参考点所在屏 → 面板当前所在屏（含最大重叠）→ 系统主屏。
    /// macOS 的 `NSScreen.frame` 是**全局点坐标**，副屏可能是负坐标；
    /// `visibleFrame` 已排除菜单栏 / Dock，因此同一套算法适配任意分辨率、缩放与多屏。
    private func positioningScreen(reference: NSPoint? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        if let reference, let screen = screens.first(where: { $0.frame.contains(reference) }) {
            return screen
        }
        if let panel {
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            if let screen = screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
            if let screen = screens.max(by: { lhs, rhs in
                Self.overlapArea(lhs.frame, panel.frame) < Self.overlapArea(rhs.frame, panel.frame)
            }), Self.overlapArea(screen.frame, panel.frame) > 0 {
                return screen
            }
        }
        return targetScreen
    }

    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    /// 无已存位置 / 越界回退时，回到默认角（左下角）。
    private func moveToDefaultPosition() {
        applyCorner(.bottomLeft)
    }

    /// 把时钟放到指定角落并静默落盘（不广播，避免触发窗口重排回调）。
    func applyCorner(_ corner: ClockCorner) {
        guard let panel, let visible = positioningScreen()?.visibleFrame else { return }
        let origin = corner.origin(
            for: panel.frame.size,
            in: visible,
            margin: ClockCorner.margin(for: visible)
        )
        panel.setFrameOrigin(origin)
        settings.updateOrigin(x: origin.x, y: origin.y)
        activeCorner = corner
    }

    /// 屏幕分辨率 / 缩放 / 外接屏变化：贴角状态按新可见区重算；自由坐标夹回可见范围。
    @objc private func handleScreenParametersChanged() {
        guard let panel else { return }
        if let corner = activeCorner {
            applyCorner(corner)
        } else {
            ensureOnScreen()
            let size = panel.frame.size
            let origin = clampedOrigin(panel.frame.origin, size: size)
            if abs(origin.x - panel.frame.origin.x) > 0.5 || abs(origin.y - panel.frame.origin.y) > 0.5 {
                panel.setFrameOrigin(origin)
                settings.updateOrigin(x: origin.x, y: origin.y)
            }
        }
        updateMenuStates()
    }

    /// 设置页按钮走通知，避免 SwiftUI 直接持有窗口管理器。
    @objc private func applyCornerFromNotification(_ note: Notification) {
        guard let raw = note.userInfo?["corner"] as? String,
              let corner = ClockCorner(rawValue: raw) else { return }
        applyCorner(corner)
        updateMenuStates()
    }

    /// 当前时钟落在哪个角（±2pt 容差），用于菜单勾选。
    private var currentCorner: ClockCorner? {
        guard let panel, let visible = positioningScreen()?.visibleFrame else { return nil }
        let size = panel.frame.size
        let margin = ClockCorner.margin(for: visible)
        return ClockCorner.allCases.first { corner in
            let o = corner.origin(for: size, in: visible, margin: margin)
            return abs(o.x - panel.frame.origin.x) < 2 && abs(o.y - panel.frame.origin.y) < 2
        }
    }

    private func persistPosition() {
        guard let panel else { return }
        // 手动拖动后退出贴角模式：之后分辨率变化按自由坐标夹回可见区。
        activeCorner = nil
        settings.updateOrigin(x: panel.frame.origin.x, y: panel.frame.origin.y)
    }

    /// 应用主题。`NSApp.appearance` 管全局；再逐个窗口同步一次，
    /// 避免非激活面板 / 气泡这类特殊窗口只换一半（改了背景没改文字）。
    /// `nil` 表示清除覆盖，恢复跟随 macOS 系统外观。
    private func applyAppearance() {
        let appearance = settings.appearanceMode.nsAppearance
        NSApp.appearance = appearance
        panel?.appearance = appearance
        bubblePanel?.appearance = appearance
        settingsController?.window?.appearance = appearance
    }

    // MARK: - 设置联动

    @objc private func handleSettingsChanged() {
        applyAppearance()
        guard let panel else { return }

        panel.ignoresMouseEvents = settings.isLocked
        panel.level = settings.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = settings.alwaysOnTop
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.canJoinAllSpaces, .ignoresCycle]

        applyMenuBarVisibility()
        resizePanel()
        // 字号变化会改变窗口尺寸；贴角状态下按新尺寸重新贴一次，保持四边留白一致。
        if let corner = activeCorner { applyCorner(corner) }
        updateMenuStates()
        hideInfoBubble()
    }

    // MARK: - 信息气泡

    private var bubblePanel: InfoBubblePanel?
    private var bubbleHosting: NSHostingView<AnyView>?
    private var isBubbleVisible = false
    /// 记录当前指针朝向：过渡的位移方向跟着它走（从时钟那一侧进出）。
    private var bubbleTailOnTop = false
    /// 弹出过渡播放期间不判定鼠标离开，避免「弹出→立刻关闭」闪烁。
    private var bubbleShownAt: CFTimeInterval = 0
    private var bubblePresentDuration: TimeInterval = AppTheme.Motion.bubblePresentDuration
    /// 每次开 / 关都递增；过期的 CATransaction completion 凭它自行作废。
    private var bubbleTransitionID: UInt = 0

    private static let bubblePresentKey = "bubblePresent"
    private static let bubbleDismissKey = "bubbleDismiss"
    /// 鼠标连续多少次（×0.2s）不在时钟/气泡上才收起。3 次 = 0.6s：
    /// 2 次（0.4s）过于急躁，鼠标顺手一划就消失，读起来像"被抢走"。
    private static let bubbleMouseAwayTicks = 3

    /// 单击时钟：显示 / 收起信息气泡（日期、星期、农历）。
    private func toggleInfoBubble() {
        if isBubbleVisible {
            hideInfoBubble()
        } else {
            showInfoBubble()
        }
    }

    private func showInfoBubble() {
        guard let clock = panel else { return }
        // 已在显示中：不重播弹出过渡。重复加一次 opacity 0→1 的动画，
        // 视觉上就是「好端端的气泡忽然闪一下再淡入」。
        guard !isBubbleVisible else { return }

        let info = ClockInfoProvider.current()
        let root = AnyView(InfoBubbleView(info: info))
        let hosting: NSHostingView<AnyView>
        let bubble: InfoBubblePanel

        if let existingHosting = bubbleHosting, let existingPanel = bubblePanel {
            existingHosting.rootView = root
            hosting = existingHosting
            bubble = existingPanel
        } else {
            let newHosting = NSHostingView(rootView: root)
            // 气泡需要向 SwiftUI 索取内容的固有尺寸来定窗口大小。
            newHosting.sizingOptions = [.intrinsicContentSize]
            newHosting.wantsLayer = true
            newHosting.layer?.backgroundColor = NSColor.clear.cgColor

            let newPanel = InfoBubblePanel(
                contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isFloatingPanel = true
            newPanel.hidesOnDeactivate = false
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.ignoresMouseEvents = true
            newPanel.animationBehavior = .none
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            newPanel.contentView = newHosting

            bubblePanel = newPanel
            bubbleHosting = newHosting
            hosting = newHosting
            bubble = newPanel
        }

        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }

        let clockFrame = clock.frame
        // 窗口内含 12pt 的阴影留白，指针尖端距离时钟约 2pt
        let gap: CGFloat = 10
        var origin = NSPoint(x: clockFrame.midX - size.width / 2, y: clockFrame.maxY - gap)
        var tailOnTop = false

        if let screen = positioningScreen() {
            let visible = screen.visibleFrame
            origin.x = min(
                max(origin.x, visible.minX + 8),
                max(visible.minX + 8, visible.maxX - size.width - 8)
            )
            // 上方放不下就落到时钟下方，指针改为朝上
            if origin.y + size.height > visible.maxY {
                tailOnTop = true
                origin.y = max(visible.minY + 8, clockFrame.minY + gap - size.height)
            }
        }

        if tailOnTop {
            hosting.rootView = AnyView(InfoBubbleView(info: info, tailOnTop: true))
            hosting.layoutSubtreeIfNeeded()
        }
        bubbleTailOnTop = tailOnTop

        // 顺序很关键：先把 layer 归零，再 orderFront，最后才挂动画。
        // 上一版顺序是「orderFront → 挂动画」，窗口会在挂动画之前先以
        // layer 的 model 值（opacity=1）刷一帧，每次打开都先「闪亮一下」再淡入。
        let fromTransform = Self.bubbleTransform(
            scale: AppTheme.Motion.bubblePresentScale,
            offset: AppTheme.Motion.bubblePresentOffset,
            tailOnTop: tailOnTop
        )

        if let layer = hosting.layer {
            // 上一次收起可能还没走完，先摘掉，避免两组动画叠加。
            bubbleTransitionID &+= 1
            layer.removeAnimation(forKey: Self.bubbleDismissKey)
            layer.removeAnimation(forKey: Self.bubblePresentKey)
            Self.setLayerState(layer, opacity: 0, transform: fromTransform)
        }

        bubble.setFrame(NSRect(origin: origin, size: size), display: true)
        bubble.alphaValue = 1
        bubble.orderFrontRegardless()

        // 弹出过渡：轻微放大 + 从时钟方向回位 + 淡入。
        // 非激活面板上 `animator()` 不可靠，直接对 hosting 的 backing layer 用 Core Animation。
        // model 值先落到终态，动画只做视觉过渡，播完即停在终态。
        if let layer = hosting.layer {
            Self.setLayerState(layer, opacity: 1, transform: CATransform3DIdentity)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1

            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: fromTransform)
            move.toValue = NSValue(caTransform3D: CATransform3DIdentity)

            let group = CAAnimationGroup()
            group.animations = [fade, move]
            group.duration = AppTheme.Motion.bubblePresentDuration
            group.timingFunction = AppTheme.Motion.bubblePresentEase
            layer.add(group, forKey: Self.bubblePresentKey)
        }

        bubblePresentDuration = AppTheme.Motion.bubblePresentDuration
        isBubbleVisible = true
        bubbleShownAt = CACurrentMediaTime()
        // 鼠标离开时钟（与气泡）范围后自动收起
        startMouseWatch()
    }

    /// 过渡用的 transform：轻微缩放 + 朝时钟方向的位移。
    /// layer 的 y 向上为正：气泡挂在时钟上方时从下方进入，挂在下方时从上方进入。
    private static func bubbleTransform(scale: CGFloat, offset: CGFloat, tailOnTop: Bool) -> CATransform3D {
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform = CATransform3DTranslate(transform, 0, tailOnTop ? offset : -offset, 0)
        return transform
    }

    /// 改 layer 的 model 值时不触发隐式过渡动画。
    /// 这些赋值都是「立刻切入某个状态」，带 0.25s 隐式动画会和显式动画打架。
    private static func withLayerActionsDisabled(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func setLayerState(_ layer: CALayer, opacity: Float, transform: CATransform3D) {
        withLayerActionsDisabled {
            layer.opacity = opacity
            layer.transform = transform
        }
    }

    /// - Parameter animated: 移动时钟触发的关闭传 false（立即消失，不等动画）；
    ///   点击收起 / 鼠标离开传 true（播放淡出 + 轻微退位）。
    private func hideInfoBubble(animated: Bool = true) {
        stopMouseWatch()
        guard let bubble = bubblePanel, isBubbleVisible else { return }
        isBubbleVisible = false
        bubbleTransitionID &+= 1
        let token = bubbleTransitionID

        guard let layer = bubbleHosting?.layer else {
            bubble.alphaValue = 0
            bubble.orderOut(nil)
            return
        }

        // 从「当前呈现值」接管，而不是假设停在 1.0：
        // 弹出还没播完就收起时，按终态起算会先跳到全亮再淡出，就是「快速点两下会闪」。
        let presented = layer.presentation()
        let fromOpacity = presented?.opacity ?? layer.opacity
        let fromTransform = presented?.transform ?? layer.transform
        // 先把 model 固化成当前呈现值，再摘动画 —— removeAnimation 那一帧才不会跳亮。
        Self.setLayerState(layer, opacity: fromOpacity, transform: fromTransform)
        layer.removeAnimation(forKey: Self.bubblePresentKey)
        layer.removeAnimation(forKey: Self.bubbleDismissKey)

        guard animated else {
            Self.setLayerState(layer, opacity: 0, transform: CATransform3DIdentity)
            bubble.alphaValue = 0
            bubble.orderOut(nil)
            return
        }

        let toTransform = Self.bubbleTransform(
            scale: AppTheme.Motion.bubbleDismissScale,
            offset: AppTheme.Motion.bubbleDismissOffset,
            tailOnTop: bubbleTailOnTop
        )

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 0

        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: fromTransform)
        move.toValue = NSValue(caTransform3D: toTransform)

        let group = CAAnimationGroup()
        group.animations = [fade, move]
        group.duration = AppTheme.Motion.bubbleDismissDuration
        group.timingFunction = AppTheme.Motion.bubbleDismissEase
        group.isRemovedOnCompletion = true

        // model 先落到隐藏态，动画只负责从当前呈现值过渡到它；
        // 播完由 CATransaction completion 收窗，不用 asyncAfter 猜时长。
        Self.setLayerState(layer, opacity: 0, transform: toTransform)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak bubble, weak layer] in
            guard let self, let bubble, let layer,
                  self.bubbleTransitionID == token, !self.isBubbleVisible else { return }
            Self.setLayerState(layer, opacity: 0, transform: CATransform3DIdentity)
            bubble.alphaValue = 0
            bubble.orderOut(nil)
        }
        layer.add(group, forKey: Self.bubbleDismissKey)
        CATransaction.commit()
    }

    // MARK: 鼠标离开检测

    private var mouseWatchTimer: Timer?
    private var mouseAwayTicks = 0

    /// 0.2 秒轮询一次鼠标位置。非激活面板收不到 mouseMoved，
    /// 而 `NSEvent.mouseLocation` 读全局坐标不需要任何权限。
    private func startMouseWatch() {
        stopMouseWatch()
        let timer = Timer(
            timeInterval: 0.2,
            target: self,
            selector: #selector(checkMouseAway),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        mouseWatchTimer = timer
    }

    private func stopMouseWatch() {
        mouseWatchTimer?.invalidate()
        mouseWatchTimer = nil
        mouseAwayTicks = 0
    }

    @objc private func checkMouseAway() {
        guard isBubbleVisible, let clock = panel else { return }

        // 弹出动画播放期间不判定离开：否则点击后鼠标一动，收起动画会打断
        // 尚未播完的弹出动画，出现「弹出→立刻关闭」的闪烁。
        // 过渡是固定时长，保护窗口与动画严格等长，不会像弹簧那样有回弹拖尾。
        if CACurrentMediaTime() - bubbleShownAt < bubblePresentDuration {
            mouseAwayTicks = 0
            return
        }

        let mouse = NSEvent.mouseLocation

        // 鼠标在时钟或气泡上，都算"还在看"。
        if clock.frame.contains(mouse) || (bubblePanel?.frame.contains(mouse) ?? false) {
            mouseAwayTicks = 0
            return
        }

        // 连续几次（约 0.6 秒）离开才收起，避免鼠标掠过时闪烁。
        mouseAwayTicks += 1
        if mouseAwayTicks >= Self.bubbleMouseAwayTicks {
            hideInfoBubble()
        }
    }

    /// 供自动化校验：直接展示气泡（不启用鼠标离开检测，方便截图）。
    func debugShowBubble() {
        showInfoBubble()
        stopMouseWatch()
    }

    // MARK: - 菜单栏

    /// 按设置增删菜单栏图标。菜单栏图标隐藏后仍有右键菜单和重新打开 App 两条恢复路径。
    private func applyMenuBarVisibility() {
        if settings.showMenuBarIcon {
            guard statusItem == nil else { return }
            buildStatusItem()
        } else {
            guard let item = statusItem else { return }
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            visibleItem = nil
            lockItem = nil
            onTopItem = nil
            loginItem = nil
        }
    }

    /// 四角预设子菜单：菜单栏下拉与时钟右键共用同一份构造。
    private func makeCornerSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: NSLocalizedString("common.presetPosition", comment: ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: NSLocalizedString("common.presetPosition", comment: ""))
        submenu.delegate = self
        for corner in ClockCorner.allCases {
            let item = NSMenuItem(
                title: corner.menuTitle,
                action: #selector(applyCornerPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = corner.rawValue
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "TClock")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "TClock"
        }

        let menu = NSMenu()
        menu.delegate = self

        let settingsItem = NSMenuItem(title: NSLocalizedString("menu.settings", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: NSLocalizedString("menu.checkUpdate", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let visibleItem = NSMenuItem(title: NSLocalizedString("menu.hideClock", comment: ""), action: #selector(toggleVisible), keyEquivalent: "")
        visibleItem.target = self
        self.visibleItem = visibleItem
        menu.addItem(visibleItem)

        let lockItem = NSMenuItem(title: NSLocalizedString("menu.lockPosition", comment: ""), action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        self.lockItem = lockItem
        menu.addItem(lockItem)

        let onTopItem = NSMenuItem(title: NSLocalizedString("menu.alwaysOnTop", comment: ""), action: #selector(toggleOnTop), keyEquivalent: "")
        onTopItem.target = self
        self.onTopItem = onTopItem
        menu.addItem(onTopItem)

        menu.addItem(.separator())

        menu.addItem(makeCornerSubmenu())

        let resetItem = NSMenuItem(title: NSLocalizedString("menu.resetPosition", comment: ""), action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        // 登录项与菜单栏图标是「启动/入口」类开关，放在菜单里，设置页不再重复。
        let loginItem = NSMenuItem(title: NSLocalizedString("menu.launchAtLogin", comment: ""), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        self.loginItem = loginItem
        menu.addItem(loginItem)

        let menuBarItem = NSMenuItem(title: NSLocalizedString("menu.hideMenubarIcon", comment: ""), action: #selector(toggleMenuBarIcon), keyEquivalent: "")
        menuBarItem.target = self
        menu.addItem(menuBarItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    /// 应用主菜单（仅在设置窗口等激活状态下可见），同时提供 ⌘C/⌘V 等编辑快捷键。
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "TClock")
        appMenu.addItem(
            NSMenuItem(
                title: "menu.about",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: NSLocalizedString("menu.settings", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: NSLocalizedString("menu.checkUpdate", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)

        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(title: NSLocalizedString("menu.hideApp", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        )
        appMenu.addItem(
            NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: NSLocalizedString("menu.edit", comment: ""))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.redo", comment: ""), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.cut", comment: ""), action: Selector(("cut:")), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.copy", comment: ""), action: Selector(("copy:")), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.paste", comment: ""), action: Selector(("paste:")), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.selectAll", comment: ""), action: Selector(("selectAll:")), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: NSLocalizedString("menu.window", comment: ""))
        windowMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.close", comment: ""), action: Selector(("performClose:")), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: NSLocalizedString("menu.minimize", comment: ""), action: Selector(("performMiniaturize:")), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }

    private func updateMenuStates() {
        lockItem?.state = settings.isLocked ? .on : .off
        onTopItem?.state = settings.alwaysOnTop ? .on : .off
        visibleItem?.title = isPanelVisible
            ? NSLocalizedString("menu.hideClock", comment: "")
            : NSLocalizedString("menu.showClock", comment: "")
        loginItem?.state = LaunchAtLogin.shared.isEnabled ? .on : .off
    }

    // MARK: - 菜单动作

    /// 右键时钟的快捷菜单。
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: NSLocalizedString("menu.settings", comment: ""), action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: NSLocalizedString("menu.checkUpdate", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let lockItem = NSMenuItem(
            title: settings.isLocked
                ? NSLocalizedString("menu.unlockPosition", comment: "")
                : NSLocalizedString("settings.behavior.lock", comment: ""),
            action: #selector(toggleLock),
            keyEquivalent: ""
        )
        lockItem.target = self
        menu.addItem(lockItem)

        let topItem = NSMenuItem(title: NSLocalizedString("menu.alwaysOnTop", comment: ""), action: #selector(toggleOnTop), keyEquivalent: "")
        topItem.target = self
        topItem.state = settings.alwaysOnTop ? .on : .off
        menu.addItem(topItem)

        menu.addItem(.separator())

        // 菜单栏图标隐藏时，这是唯一的恢复入口。
        let menuBarItem = NSMenuItem(
            title: settings.showMenuBarIcon
                ? NSLocalizedString("menu.hideMenubarIcon", comment: "")
                : NSLocalizedString("menu.showMenubarIcon", comment: ""),
            action: #selector(toggleMenuBarIcon),
            keyEquivalent: ""
        )
        menuBarItem.target = self
        menu.addItem(menuBarItem)

        // 登录项同样放在右键菜单，菜单栏图标隐藏后仍可操作。
        LaunchAtLogin.shared.refresh()
        let loginItem = NSMenuItem(title: NSLocalizedString("menu.launchAtLogin", comment: ""), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.shared.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        menu.addItem(makeCornerSubmenu())

        let resetItem = NSMenuItem(title: NSLocalizedString("menu.resetPosition", comment: ""), action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// 打开设置窗口（菜单栏入口、⌘, 与双击时钟都走这里）。
    func presentSettings() {
        hideInfoBubble()
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings)
        }
        // 关闭后重新打开都回到屏幕正中央；窗口已经可见时不打扰用户正在调整的位置。
        if let window = settingsController?.window, !window.isVisible {
            positionSettingsWindow(window)
        }
        settingsController?.present()
    }

    /// 设置窗口默认在**目标屏幕可见区正中央**打开。
    /// - 用 `visibleFrame`（已排除菜单栏/Dock，逻辑点）计算，适配任意分辨率与缩放；
    /// - 小屏上窗口可能比可见区还大，clamp 到可见区左上，避免标题栏跑出屏幕；
    /// - 只有与时钟窗口重叠时才让位到右下角（时钟默认在左下角，一般不会触发）。
    private func positionSettingsWindow(_ window: NSWindow?) {
        guard let window, let screen = positioningScreen() else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size

        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        var origin = ScreenGeometry.centeredOrigin(for: size, in: visible)

        if let panel, NSRect(origin: origin, size: size).intersects(panel.frame) {
            let margin = AppTheme.Metrics.settingsEdgeMargin
            origin = NSPoint(
                x: min(max(visible.maxX - size.width - margin, visible.minX), maxX),
                y: min(max(visible.minY + margin, visible.minY), maxY)
            )
        }
        window.setFrameOrigin(origin)
    }

    @objc private func openSettings() {
        presentSettings()
    }

    /// 菜单栏 / 右键菜单 / 应用菜单共用；手动检查忽略 24 小时节流。
    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdatesFromMenu()
    }

    @objc private func toggleVisible() {
        guard let panel else { return }
        if isPanelVisible {
            panel.orderOut(nil)
        } else {
            ensureOnScreen()
            panel.orderFrontRegardless()
        }
        isPanelVisible.toggle()
        updateMenuStates()
    }

    @objc private func toggleLock() {
        settings.isLocked.toggle()
    }

    @objc private func toggleOnTop() {
        settings.alwaysOnTop.toggle()
    }

    @objc private func toggleMenuBarIcon() {
        settings.showMenuBarIcon.toggle()
    }

    /// 登录项由系统持有，切换前先读一次真实状态（用户可能在系统设置里改过）。
    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.shared.refresh()
        LaunchAtLogin.shared.setEnabled(!LaunchAtLogin.shared.isEnabled)
        updateMenuStates()
    }

    /// 菜单栏 / 右键菜单里的四角预设。
    @objc private func applyCornerPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let corner = ClockCorner(rawValue: raw) else { return }
        applyCorner(corner)
        updateMenuStates()
    }

    @objc private func resetPosition() {
        moveToDefaultPosition()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuStates()
        refreshDynamicStates(in: menu)
    }

    /// 菜单每次展开都刷新：登录项真实状态、菜单栏图标状态、当前所处角落的勾选。
    /// 右键菜单是临时构造的，也会走这里，因此不依赖持有 item 引用。
    private func refreshDynamicStates(in menu: NSMenu) {
        LaunchAtLogin.shared.refresh()
        let current = currentCorner

        for item in menu.items {
            if item.action == #selector(toggleLaunchAtLogin) {
                item.state = LaunchAtLogin.shared.isEnabled ? .on : .off
            }

            if let raw = item.representedObject as? String,
               let corner = ClockCorner(rawValue: raw) {
                item.state = (corner == current) ? .on : .off
            } else if let submenu = item.submenu {
                for sub in submenu.items {
                    guard let raw = sub.representedObject as? String,
                          let corner = ClockCorner(rawValue: raw) else { continue }
                    sub.state = (corner == current) ? .on : .off
                }
            }
        }
    }
}
