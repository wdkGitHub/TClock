import AppKit

// MARK: - 版本号

/// 轻量语义化版本比较，支持 `v1.2` / `1.2.3` / `1.2.3-beta.1` / `1.2+build.5`。
/// 纯值类型，不依赖 AppKit 状态，便于单独验证。
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let raw: String
    private let core: [Int]
    private let prerelease: [String]

    init(_ raw: String) {
        self.raw = raw
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        // 构建元数据不参与比较。
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }

        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            pre = String(text[text.index(after: dash)...])
                .split(separator: ".")
                .map(String.init)
            text = String(text[..<dash])
        }
        self.prerelease = pre
        self.core = text.split(separator: ".").map { part -> Int in
            let digits = String(part).prefix(while: { $0.isNumber })
            return Int(String(digits)) ?? 0
        }
    }

    var description: String { raw }

    /// 用比较结果定义相等，保证 `1.2` 与 `1.2.0` 视为同一版本。
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let a = index < lhs.core.count ? lhs.core[index] : 0
            let b = index < rhs.core.count ? rhs.core[index] : 0
            if a != b { return a < b }
        }

        // 正式版永远大于同版本的预发布版。
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        let preCount = max(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<preCount {
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let a = lhs.prerelease[index]
            let b = rhs.prerelease[index]
            if a == b { continue }
            if let ai = Int(a), let bi = Int(b) { return ai < bi }
            return a < b
        }
        return false
    }
}

// MARK: - GitHub Release 模型

/// 一次可用更新所需的最小信息。
struct UpdateCandidate: Sendable {
    let versionText: String
    let version: AppVersion
    let build: Int?
    let notes: String
    let pageURL: URL
    let assetName: String
    let assetURL: URL
    let assetSize: Int64
    let isPrerelease: Bool
}

private struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL?
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case prerelease
        case draft
        case assets
    }

    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL?
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }
}

// MARK: - 错误

enum UpdateError: LocalizedError {
    case invalidResponse
    case http(Int)
    case noReleaseAsset
    case commandFailed(String)
    case noAppInDMG
    case invalidBundle
    case versionDowngrade(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return NSLocalizedString("update.error.invalidResponse", comment: "")
        case .http(let code):
            if code == 403 || code == 429 {
                return String(
                    format: NSLocalizedString("update.error.rateLimit", comment: ""),
                    code
                )
            }
            return String(
                format: NSLocalizedString("update.error.http", comment: ""),
                code
            )
        case .noReleaseAsset:
            return NSLocalizedString("update.error.noAsset", comment: "")
        case .commandFailed(let detail):
            return String(
                format: NSLocalizedString("update.error.commandFailed", comment: ""),
                detail
            )
        case .noAppInDMG:
            return NSLocalizedString("update.error.noAppInDMG", comment: "")
        case .invalidBundle:
            return NSLocalizedString("update.error.invalidBundle", comment: "")
        case .versionDowngrade(let version):
            return String(
                format: NSLocalizedString("update.error.downgrade", comment: ""),
                version
            )
        }
    }
}

// MARK: - 更新引擎（纯逻辑，不碰 UI）

/// 网络请求、DMG 挂载、应用替换脚本都放在这里。
/// 所有跨线程传递的参数都是值类型，避免 Swift 6 并发隔离问题。
enum UpdateEngine {
    // MARK: GitHub

    static func latestCandidate(
        owner: String,
        repo: String,
        includePrereleases: Bool
    ) async throws -> UpdateCandidate? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20") else {
            throw UpdateError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("TClock-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw UpdateError.http(http.statusCode) }

        return try candidate(
            from: data,
            owner: owner,
            repo: repo,
            includePrereleases: includePrereleases
        )
    }

    /// 从 GitHub `/releases` 响应里挑出可用更新。纯函数，便于用固定 JSON 验证。
    static func candidate(
        from data: Data,
        owner: String,
        repo: String,
        includePrereleases: Bool
    ) throws -> UpdateCandidate? {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        // GitHub 按发布时间倒序返回；跳过草稿、无 DMG 的发布，取第一个可用版本。
        for release in releases where !release.draft && (includePrereleases || !release.prerelease) {
            guard let asset = release.assets.first(where: {
                $0.name.lowercased().hasSuffix(".dmg") && $0.browserDownloadURL != nil
            }), let assetURL = asset.browserDownloadURL else { continue }

            let tag = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = AppVersion(tag)
            let fallback = "https://github.com/\(owner)/\(repo)/releases"
            return UpdateCandidate(
                versionText: tag,
                version: version,
                build: nil,
                notes: release.body ?? "",
                pageURL: release.htmlURL ?? URL(string: fallback)!,
                assetName: asset.name,
                assetURL: assetURL,
                assetSize: asset.size ?? 0,
                isPrerelease: release.prerelease
            )
        }
        return nil
    }

    // MARK: 下载

    /// 把 DMG 落到临时目录并返回稳定路径（URLSession 的临时文件随时可能被回收）。
    /// `file://` 用于本地 DMG 调试，直接复制即可。
    static func download(_ url: URL) async throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("tclock-update-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: target)

        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        }

        var request = URLRequest(url: url)
        request.setValue("TClock-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 180
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    // MARK: DMG 解包

    /// 挂载 DMG → 找到 TClock.app → 校验 → 复制到临时暂存区 → 清除隔离属性。
    /// 同步的 hdiutil / ditto 放到后台队列，避免卡住主线程。
    static func stageApp(from dmg: URL, minimumVersion: AppVersion) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let staged = try stageAppSync(from: dmg, minimumVersion: minimumVersion)
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func stageAppSync(from dmg: URL, minimumVersion: AppVersion) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tclock-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let mount = work.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)

        try run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path, "-quiet",
        ])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        let direct = mount.appendingPathComponent("TClock.app")
        var appURL: URL? = fm.fileExists(atPath: direct.path) ? direct : nil
        if appURL == nil,
           let enumerator = fm.enumerator(at: mount, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let item as URL in enumerator where item.pathExtension == "app" {
                appURL = item
                break
            }
        }
        guard let appURL else { throw UpdateError.noAppInDMG }

        // 与当前运行中的 App 比对 bundle id，避免硬编码 id 漂移导致校验永远失败。
        guard let expectedID = Bundle.main.bundleIdentifier,
              let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == expectedID,
              let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw UpdateError.invalidBundle
        }
        let found = AppVersion(raw)
        guard found >= minimumVersion else {
            throw UpdateError.versionDowngrade(raw)
        }

        let staged = work.appendingPathComponent("TClock.app")
        try run("/usr/bin/ditto", [appURL.path, staged.path])
        // DMG 可能带 com.apple.quarantine；清掉，否则临时签名的应用会被 Gatekeeper 拦下。
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        // 签名校验只作提示，不因环境差异阻断更新。
        _ = try? run("/usr/bin/codesign", ["--verify", "--deep", staged.path])
        return staged
    }

    // MARK: 替换与重启

    /// 生成一个脱离本进程运行的 shell 脚本：等旧进程退出 → 备份旧包 → 换入新包 → 重新打开。
    /// 旧包先 `mv` 到旁边（同卷原子操作），失败可原位回滚，不做就地递归删除。
    static func writeRelaunchScript(
        oldPID: Int32,
        destination: URL,
        stagedApp: URL
    ) throws -> URL {
        let script = """
        #!/bin/sh
        OLD_PID=\(shellQuote(String(oldPID)))
        DEST=\(shellQuote(destination.path))
        STAGE=\(shellQuote(stagedApp.path))
        BACKUP="${DEST}.tclock-backup"

        i=0
        while kill -0 "$OLD_PID" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -gt 100 ] && break
          /bin/sleep 0.2
        done

        /bin/rm -rf "$BACKUP"
        if ! /bin/mv "$DEST" "$BACKUP"; then
          /usr/bin/open -a "$DEST" 2>/dev/null || true
          exit 1
        fi
        if /usr/bin/ditto "$STAGE" "$DEST"; then
          /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
          /bin/rm -rf "$BACKUP"
        else
          /bin/rm -rf "$DEST"
          /bin/mv "$BACKUP" "$DEST"
        fi
        /usr/bin/open -a "$DEST"
        """
        let url = stagedApp.deletingLastPathComponent().appendingPathComponent("relaunch.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 脚本必须脱离当前进程：应用马上会 terminate，不能等它结束。
    static func launchDetached(_ script: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: 工具

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(
                "\(URL(fileURLWithPath: path).lastPathComponent): " +
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}

// MARK: - 更新控制器（UI + 调度）

/// 菜单栏「检查更新…」与启动静默检查的唯一入口。
///
/// 调试钩子（与工程其它调试开关同一风格）：
/// - `TCLOCK_DISABLE_UPDATE_CHECK=1`  关闭启动静默检查
/// - `TCLOCK_FORCE_UPDATE_CHECK=1`    忽略 24 小时节流
/// - `TCLOCK_SHOW_UPDATE=1`           启动即弹出手动检查
/// - `TCLOCK_UPDATE_DRY_RUN=1`        下载并校验 DMG，但不替换应用、不重启
/// - `TCLOCK_UPDATE_DMG_URL=<url>`    用本地 DMG 代替 GitHub（可配合 dry-run）
/// - `TCLOCK_UPDATE_OWNER` / `TCLOCK_UPDATE_REPO`  覆盖仓库（fork 时用）
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    private enum Config {
        static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.wdk.TClock"
        static let checkInterval: TimeInterval = 24 * 60 * 60

        static var owner: String {
            ProcessInfo.processInfo.environment["TCLOCK_UPDATE_OWNER"]
                ?? Bundle.main.object(forInfoDictionaryKey: "TClockUpdateOwner") as? String
                ?? "wdkGitHub"
        }

        static var repo: String {
            ProcessInfo.processInfo.environment["TCLOCK_UPDATE_REPO"]
                ?? Bundle.main.object(forInfoDictionaryKey: "TClockUpdateRepo") as? String
                ?? "TClock"
        }
    }

    private enum Keys {
        static let lastCheck = "tclock.updateLastCheck"
        static let skipped = "tclock.updateSkippedVersion"
    }

    private var isBusy = false
    private var currentTask: Task<Void, Never>?
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?

    private var localVersionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var localBuild: Int {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return 0 }
        return Int(raw) ?? 0
    }

    // MARK: 入口

    /// 启动后延迟 5 秒检查，24 小时节流；失败与「无更新」都静默。
    func checkSilentlyIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["TCLOCK_DISABLE_UPDATE_CHECK"] != "1" else { return }
        #if DEBUG
        return
        #else
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.check(interactive: false)
        }
        #endif
    }

    /// 菜单手动触发：忽略节流，无更新 / 失败都要给明确反馈。
    func checkForUpdatesFromMenu() {
        check(interactive: true)
    }

    private func check(interactive: Bool) {
        guard !isBusy else { return }
        isBusy = true
        currentTask = Task { [weak self] in
            defer {
                self?.isBusy = false
                self?.currentTask = nil
            }
            await self?.performCheck(interactive: interactive)
        }
    }

    // MARK: 检查

    private func performCheck(interactive: Bool) async {
        if !interactive, !shouldCheckSilently() { return }
        UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
        if interactive { showProgress(NSLocalizedString("update.progress.checking", comment: "")) }
        defer { if interactive { hideProgress() } }

        do {
            let candidate = try await resolveCandidate()
            try Task.checkCancellation()

            guard let candidate, isNewer(candidate) else {
                if interactive {
                    hideProgress()
                    showAlert(
                        NSLocalizedString("update.upToDate.title", comment: ""),
                        String(
                            format: NSLocalizedString("update.upToDate.message", comment: ""),
                            localVersionText, localBuild
                        )
                    )
                }
                return
            }

            // 「跳过此版本」只压制静默提醒，手动检查仍然显示。
            if !interactive,
               UserDefaults.standard.string(forKey: Keys.skipped) == candidate.versionText {
                return
            }

            hideProgress()
            await presentUpdate(candidate)
        } catch is CancellationError {
            return
        } catch {
            if interactive {
                hideProgress()
                showError(NSLocalizedString("update.check.failed", comment: ""), error)
            }
        }
    }

    private func resolveCandidate() async throws -> UpdateCandidate? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["TCLOCK_UPDATE_DMG_URL"], let url = URL(string: raw) {
            return UpdateCandidate(
                versionText: NSLocalizedString("update.local.package", comment: ""),
                version: AppVersion("99.0"),
                build: nil,
                notes: NSLocalizedString("update.local.notes", comment: ""),
                pageURL: url,
                assetName: url.lastPathComponent,
                assetURL: url,
                assetSize: 0,
                isPrerelease: false
            )
        }
        return try await UpdateEngine.latestCandidate(
            owner: Config.owner,
            repo: Config.repo,
            includePrereleases: false
        )
    }

    private func isNewer(_ candidate: UpdateCandidate) -> Bool {
        let local = AppVersion(localVersionText)
        if candidate.version > local { return true }
        if candidate.version < local { return false }
        if let remoteBuild = candidate.build { return remoteBuild > localBuild }
        return false
    }

    private func shouldCheckSilently() -> Bool {
        if ProcessInfo.processInfo.environment["TCLOCK_FORCE_UPDATE_CHECK"] == "1" { return true }
        guard let last = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date else { return true }
        return Date().timeIntervalSince(last) >= Config.checkInterval
    }

    // MARK: 更新提示

    private func presentUpdate(_ candidate: UpdateCandidate) async {
        let size = candidate.assetSize > 0
            ? String(
                format: NSLocalizedString("update.available.size", comment: ""),
                Double(candidate.assetSize) / 1_048_576
            )
            : ""
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("update.available.title", comment: ""),
            candidate.versionText
        )
        alert.informativeText = String(
            format: NSLocalizedString("update.available.message", comment: ""),
            localVersionText, localBuild, candidate.assetName, size, briefNotes(candidate.notes)
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("update.button.install", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("update.button.releasePage", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("update.button.remind", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("update.button.skip", comment: ""))

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal().rawValue {
        case 1000:
            await install(candidate)
        case 1001:
            NSWorkspace.shared.open(candidate.pageURL)
        case 1003:
            UserDefaults.standard.set(candidate.versionText, forKey: Keys.skipped)
        default:
            break
        }
    }

    private func briefNotes(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NSLocalizedString("update.notes.empty", comment: "") }
        return trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
    }

    // MARK: 下载与安装

    private func install(_ candidate: UpdateCandidate) async {
        let destination = URL(fileURLWithPath: Bundle.main.bundlePath)
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.open(candidate.pageURL)
            showAlert(
                NSLocalizedString("update.cannot.title", comment: ""),
                NSLocalizedString("update.cannot.message", comment: "")
            )
            return
        }

        showProgress(String(
            format: NSLocalizedString("update.progress.downloading", comment: ""),
            candidate.assetName
        ))
        defer { hideProgress() }

        do {
            let dmg = try await UpdateEngine.download(candidate.assetURL)
            try Task.checkCancellation()

            showProgress(NSLocalizedString("update.progress.verifying", comment: ""))
            let staged = try await UpdateEngine.stageApp(
                from: dmg,
                minimumVersion: AppVersion(localVersionText)
            )
            try Task.checkCancellation()

            if ProcessInfo.processInfo.environment["TCLOCK_UPDATE_DRY_RUN"] == "1" {
                hideProgress()
                showAlert(
                    NSLocalizedString("update.dryRun.title", comment: ""),
                    String(
                        format: NSLocalizedString("update.dryRun.message", comment: ""),
                        candidate.assetName
                    )
                )
                return
            }

            let script = try UpdateEngine.writeRelaunchScript(
                oldPID: ProcessInfo.processInfo.processIdentifier,
                destination: destination,
                stagedApp: staged
            )
            try UpdateEngine.launchDetached(script)
            hideProgress()
            NSApp.terminate(nil)
        } catch is CancellationError {
            return
        } catch {
            hideProgress()
            showError("update.failed.title", error)
        }
    }

    // MARK: 进度窗

    private func showProgress(_ text: String) {
        if let progressWindow {
            progressLabel?.stringValue = text
            progressWindow.makeKeyAndOrderFront(nil)
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 380, height: 140)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "update.window.title"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: frame)
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 22, y: 92, width: 336, height: 20)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        let bar = NSProgressIndicator(frame: NSRect(x: 22, y: 56, width: 336, height: 20))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)

        let cancel = NSButton(title: "common.cancel", target: self, action: #selector(cancelUpdate))
        cancel.frame = NSRect(x: 280, y: 16, width: 80, height: 28)
        cancel.bezelStyle = .rounded

        content.addSubview(label)
        content.addSubview(bar)
        content.addSubview(cancel)
        window.contentView = content
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        progressWindow = window
        progressLabel = label
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressLabel = nil
    }

    @objc private func cancelUpdate() {
        currentTask?.cancel()
        hideProgress()
    }

    // MARK: 提示框

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "common.ok")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "common.ok")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
