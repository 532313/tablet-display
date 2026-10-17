import AppKit

/// Minimal menu-bar presence so the app does not look like an invisible
/// process. It intentionally exposes only the health page and Quit.
final class StatusBarController: NSObject, @unchecked Sendable {
    private let item: NSStatusItem
    private let statusItem: NSMenuItem
    private var port: UInt16

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
        let present = {
            let alert = NSAlert()
            alert.messageText = "无法启动 Tablet Display"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.sync(execute: present)
        }
    }

    func update(_ text: String) {
        if Thread.isMainThread {
            statusItem.title = text
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.title = text
            }
        }
    }

    @objc private func openHealth() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
