import AppKit

final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private let configManager: ConfigManager
    private let settingsWindowController: SettingsWindowController
    private var automations: [any Automation] = []
    private let menu = NSMenu()

    init(configManager: ConfigManager, settingsWindowController: SettingsWindowController) {
        self.configManager = configManager
        self.settingsWindowController = settingsWindowController
        super.init()
    }

    // MARK: - Setup

    func register(_ automation: any Automation) {
        automation.onStatusChanged = { [weak self] in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        automations.append(automation)
    }

    func start() {
        statusItem      = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate   = self
        statusItem.menu = menu
        updateIcon()

        configManager.onChanged = { [weak self] in
            guard let self else { return }
            let config = self.configManager.config
            for automation in self.automations {
                automation.reloadConfig(from: config)
            }
            self.updateIcon()
        }
    }

    // MARK: - LaunchAgent

    private let plistLabel = "com.local.osx-utils-automation"
    private var plistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/\(plistLabel).plist"
    }

    private func launchAtLoginEnabled() -> Bool {
        launchctl("list", plistLabel) == 0
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let uid = String(getuid())
        if enabled {
            launchctl("bootstrap", "gui/\(uid)", plistPath)
        } else {
            launchctl("bootout", "gui/\(uid)/\(plistLabel)")
        }
    }

    @discardableResult
    private func launchctl(_ args: String...) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    // MARK: - Icon

    private func aggregateColor() -> NSColor {
        let statuses = automations.map { $0.status }
        if statuses.contains(where: { if case .error    = $0 { return true }; return false }) { return .systemRed    }
        if statuses.contains(where: { if case .degraded = $0 { return true }; return false }) { return .systemOrange }
        if statuses.contains(where: { if case .disabled = $0 { return true }; return false }) { return .systemYellow }
        return .systemGreen
    }

    func updateIcon() {
        let color  = aggregateColor()
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let image  = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "osx-utils-automation")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        statusItem.button?.image = image
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        for automation in automations {
            // Section header (bold, non-clickable)
            let header = NSMenuItem(title: automation.displayName, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: automation.displayName,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
            menu.addItem(header)

            // Enable / Disable toggle
            let toggle = ClosureMenuItem(title: "Enabled") { [weak self, weak automation] in
                guard let self, let automation else { return }
                let newEnabled = !automation.isEnabled
                if newEnabled { automation.start() } else { automation.stop() }
                self.configManager.setEnabled(automationId: automation.id, enabled: newEnabled)
                self.updateIcon()
            }
            toggle.state = automation.isEnabled ? .on : .off
            menu.addItem(toggle)

            // Status line
            let statusLine = NSMenuItem(title: automation.status.displayString, action: nil, keyEquivalent: "")
            statusLine.isEnabled = false
            menu.addItem(statusLine)

            // Automation-specific extras (e.g. Launch/Quit DisplayLink, layout info)
            for item in automation.extraMenuItems { menu.addItem(item) }

            menu.addItem(.separator())
        }

        let logsItem = ClosureMenuItem(title: "Open Logs") { [weak self] in self?.configManager.openLogs() }
        menu.addItem(logsItem)

        let settingsItem = ClosureMenuItem(title: "Settings") { [weak self] in self?.settingsWindowController.showWindow() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        let loginEnabled = launchAtLoginEnabled()
        let loginItem = ClosureMenuItem(title: "Launch at Login") { [weak self] in
            self?.setLaunchAtLogin(!loginEnabled)
        }
        loginItem.state = loginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
