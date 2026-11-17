import AppKit

/// 应用入口：纯 AppKit 启动，让时钟面板与菜单栏图标完全由我们掌控
/// （不引入 SwiftUI `Settings` 场景，避免出现第二套设置窗口）。
@main
struct TClockMain {
    @MainActor private static var retainedDelegate: AppDelegate?

    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()

            retainedDelegate = delegate
            app.delegate = delegate
            // 无 Dock 图标，只驻留菜单栏。
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, @preconcurrency NSApplicationDelegate {
    private var manager: MainWindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = MainWindowManager()
        manager.start()
        self.manager = manager

        NSApp.mainMenu = manager.makeMainMenu()

        // 启动 5 秒后静默检查 GitHub Release（24 小时节流，失败不打扰）。
        AppUpdater.shared.checkSilentlyIfNeeded()
        if ProcessInfo.processInfo.environment["TCLOCK_SHOW_UPDATE"] == "1" {
            AppUpdater.shared.checkForUpdatesFromMenu()
        }

        // 首次运行：自动打开设置窗口，让用户知道菜单栏入口与可调项。
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "tclock.didWelcome") {
            defaults.set(true, forKey: "tclock.didWelcome")
            manager.presentSettings()
        }

        // 便于自动化校验：带环境变量启动时直接弹出设置窗口。
        if ProcessInfo.processInfo.environment["TCLOCK_SHOW_SETTINGS"] == "1" {
            manager.presentSettings()
        }
        if ProcessInfo.processInfo.environment["TCLOCK_SHOW_BUBBLE"] == "1" {
            manager.debugShowBubble()
        }
        // 调试：defaults write com.wdk.TClock tclock.debugBubble -bool true 后启动即展示气泡
        if defaults.bool(forKey: "tclock.debugBubble") {
            defaults.set(false, forKey: "tclock.debugBubble")
            manager.debugShowBubble()
        }

        // 调试：启动时直接把时钟放到指定角落（topLeft/topRight/bottomLeft/bottomRight），
        // 便于在不手动点击菜单的情况下校验定位几何。
        if let raw = ProcessInfo.processInfo.environment["TCLOCK_CORNER"],
           let corner = ClockCorner(rawValue: raw) {
            manager.applyCorner(corner)
        }

        // 调试：模拟一次「屏幕分辨率/外接屏变化」，验证预设角会按当前屏幕重新计算。
        if ProcessInfo.processInfo.environment["TCLOCK_SIMULATE_SCREEN_CHANGE"] == "1" {
            NotificationCenter.default.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: NSApp
            )
        }
    }

    /// 再次双击 App（或从 Finder 重新打开）时弹出设置窗口，方便找不到菜单栏图标时使用。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        manager?.presentSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
