import Foundation

enum AppText {
    static var isEnglish: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
    }

    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    /// Status strings are composed at runtime, so exact Localizable.strings
    /// lookup only covers fixed messages. Prefix mapping covers connected/
    /// connecting/etc. messages without changing every call site.
    static func status(_ text: String) -> String {
        guard isEnglish else { return text }
        let exact = t(text)
        if exact != text { return exact }
        let prefixes: [(String, String)] = [
            ("启动未完成：", "Startup incomplete: "),
            ("启动错误：", "Startup error: "),
            ("启动失败：", "Startup failed: "),
            ("连接失败：", "Connection failed: "),
            ("重启失败：", "Restart failed: "),
            ("正在连接 ", "Connecting to "),
            ("正在重新连接", "Reconnecting"),
            ("正在重启", "Restarting"),
            ("正在启动", "Starting"),
            ("已连接 ", "Connected "),
            ("等待重试", "Waiting to retry"),
            ("采集运行中", "Capturing"),
            ("触摸未授权", "Touch permission required"),
            ("启动失败", "Startup failed"),
            ("正在扫描", "Scanning")
        ]
        for (prefix, replacement) in prefixes where text.hasPrefix(prefix) {
            return replacement + String(text.dropFirst(prefix.count))
        }
        return text
    }
}
