import AppKit
import SwiftUI

// MARK: - 关于视图

/// 关于窗口内容：图标、应用名、版本号与 GitHub 仓库入口。
/// 视觉全部走 `AppTheme` token，字重只用 400 / 500。
struct AboutView: View {
    /// 仓库地址。集中在此处，链接展示与「复制」共用，避免两处漂移。
    private let repositoryURL = "https://github.com/wdkGitHub/TClock"

    /// 完整版本号 `version.build`（如 1.0.3）。
    /// 打包脚本会把两个 bundle 字段都写成完整版本（1.0.3 / 1.0.3）；
    /// 本地构建则只有 marketing 版本（1.0 / 3），需要拼上 build 段。
    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        // 打包产物里 build 字段本身已是完整版本（含点号），此时 short 即最终值。
        if build.contains(".") { return short }
        return "\(short).\(build)"
    }

    private var appIcon: NSImage? {
        NSApp.applicationIconImage
    }

    /// GitHub 官方 mark（16×16 path）。用 SVG 构造 NSImage 并设为 template，
    /// 让前景色跟随系统强调色，深浅模式下都清晰。
    private var githubIcon: NSImage? {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16">
          <path fill="#000000" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A7.995 7.995 0 0016 8c0-4.42-3.58-8-8-8z"/>
        </svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        return image
    }

    var body: some View {
        VStack(spacing: AppTheme.Space.lg) {
            VStack(spacing: AppTheme.Space.sm) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
                Text("TClock")
                    .font(.system(size: 22, weight: AppTheme.Typography.medium))
                Text(String(
                    format: NSLocalizedString("about.version", comment: ""),
                    versionText
                ))
                .font(.system(size: AppTheme.Typography.caption, weight: AppTheme.Typography.regular))
                .foregroundStyle(.secondary)
            }

            Divider()

            // 仓库区只放一个 GitHub 图标：点击用默认浏览器打开，悬浮有提示。
            if let githubIcon {
                Button {
                    openRepositoryInBrowser()
                } label: {
                    Image(nsImage: githubIcon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(AppTheme.Palette.accent)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("about.repository.open")
            }
        }
        .padding(AppTheme.Space.xxl)
        .frame(width: 380)
    }

    private func openRepositoryInBrowser() {
        guard let url = URL(string: repositoryURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 关于窗口

/// 承载关于视图的普通窗口。固定尺寸、不可缩放，默认在屏幕可见区正中央打开。
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hosting)

        window.title = NSLocalizedString("window.about.title", comment: "")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        centerOnVisibleArea()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 与设置窗口一致：用 `visibleFrame` 计算中心，避免标题栏跑出屏幕。
    private func centerOnVisibleArea() {
        guard let window,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(ScreenGeometry.centeredOrigin(for: window.frame.size, in: visible))
    }
}
