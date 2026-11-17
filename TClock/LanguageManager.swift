import AppKit

// MARK: - 语言选项

/// 界面语言：默认跟随系统，也可强制简体中文 / 英文。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case english

    var id: String { rawValue }

    var display: String {
        switch self {
        case .system:  return NSLocalizedString("language.system", comment: "")
        case .zhHans:  return NSLocalizedString("language.zhHans", comment: "")
        case .english: return NSLocalizedString("language.english", comment: "")
        }
    }

    /// 写入 `AppleLanguages` 的值；`nil` 表示移除覆盖、跟随系统。
    var appleLanguages: [String]? {
        switch self {
        case .system:  return nil
        case .zhHans:  return ["zh-Hans"]
        case .english: return ["en"]
        }
    }
}

// MARK: - 语言管理

/// 应用语言切换。写本 App 域的 `AppleLanguages`（不影响其他 App），重启后由
/// Foundation 解析本地化包；不重启会出现菜单/静态文案只换一半的问题。
enum LanguageManager {
    /// 当前实际生效的本地化是否为中文。
    /// 用 `preferredLocalizations` 而非系统语言：强制英文时必须按英文处理，
    /// 系统语言为日文等未本地化语言时会回退到 en，也应视为非中文。
    static var isChinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
    }

    /// 应用语言选择并重启本 App。重启后自动重开设置窗口，便于确认语言已生效。
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        if let languages = language.appleLanguages {
            defaults.set(languages, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        defaults.synchronize()
        relaunch()
    }

    /// 脱离当前进程：先等旧进程退出，再启动新进程，避免两个菜单栏图标短暂并存。
    private static func relaunch() {
        guard let executable = Bundle.main.executablePath else {
            NSApp.terminate(nil)
            return
        }

        let script = """
        #!/bin/sh
        OLD_PID=\(ProcessInfo.processInfo.processIdentifier)
        i=0
        while kill -0 "$OLD_PID" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -gt 50 ] && break
          /bin/sleep 0.1
        done
        export TCLOCK_SHOW_SETTINGS=1
        exec \(shellQuote(executable))
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tclock-relaunch-\(UUID().uuidString).sh")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
