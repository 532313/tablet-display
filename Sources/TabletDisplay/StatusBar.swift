import AppKit

/// Minimal menu-bar presence so the app does not look like an invisible
/// process. It exposes health, permission shortcuts, the log and Quit.
final class StatusBarController: NSObject, @unchecked Sendable {
    private let item: NSStatusItem
    private let statusItem: NSMenuItem
    private var port: UInt16

    @MainActor
    init(port: UInt16 = 9137) {
        self.port = port
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
        super.init()
        statusItem.isEnabled = false
        item.button?.title = "Tablet Display"
        item.button?.toolTip = "Tablet Display 无线副屏"

        let menu = NSMenu()
        menu.addItem(statusItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开状态页", action: #selector(openHealth), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let permissions = NSMenuItem(title: "权限设置", action: nil, keyEquivalent: "")
        let permissionMenu = NSMenu()
        for pane in [PermissionPane.screenRecording, .accessibility, .localNetwork] {
            let entry = NSMenuItem(title: pane.title, action: #selector(openPermission(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = pane.rawValue
            permissionMenu.addItem(entry)
        }
        permissions.submenu = permissionMenu
        menu.addItem(permissions)

        let log = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    func setPort(_ port: UInt16) {
        if Thread.isMainThread {
            self.port = port
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.port = port
            }
        }
    }

    func showError(_ message: String) {
        let present: () -> Void = {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = "无法启动 Tablet Display"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                _ = alert.runModal()
            }
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.sync(execute: present)
        }
    }

    func update(_ text: String) {
        let apply: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusItem.title = text
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func showPermissionPrompt(_ pane: PermissionPane, message: String) {
        let present = {
            MainActor.assumeIsolated {
                PermissionGuide.showMissing(pane, message: message)
            }
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.sync(execute: present)
        }
    }

    @objc private func openHealth() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let pane = PermissionPane(rawValue: sender.tag) else { return }
        MainActor.assumeIsolated { PermissionGuide.open(pane) }
    }

    @objc private func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
    }

    @objc private func quit() {
        MainActor.assumeIsolated { NSApp.terminate(nil) }
    }
}
