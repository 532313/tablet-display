import AppKit

enum PermissionPane: Int {
    case screenRecording
    case accessibility
    case localNetwork

    var title: String {
        switch self {
        case .screenRecording: return AppText.t("屏幕录制")
        case .accessibility: return AppText.t("辅助功能")
        case .localNetwork: return AppText.t("本地网络")
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        case .localNetwork: pane = "Privacy_LocalNetwork"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

@MainActor
enum PermissionGuide {
    static func open(_ pane: PermissionPane) {
        if !NSWorkspace.shared.open(pane.settingsURL) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }

    static func showMissing(_ pane: PermissionPane, message: String) {
        let alert = NSAlert()
        alert.messageText = "Tablet Display 需要\(pane.title)权限"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            open(pane)
        }
    }
}
