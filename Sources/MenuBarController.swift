import AppKit

final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private let configManager:            ConfigManager
    private let moduleRegistry:           ModuleRegistry
    private let settingsWindowController: SettingsWindowController
    private let aboutWindowController:    AboutWindowController
    private let updateWindowController:   UpdateWindowController
    private let updateChecker:            UpdateChecker
    private let menu = NSMenu()

    init(
        configManager:            ConfigManager,
        moduleRegistry:           ModuleRegistry,
        settingsWindowController: SettingsWindowController,
        aboutWindowController:    AboutWindowController,
        updateWindowController:   UpdateWindowController,
        updateChecker:            UpdateChecker
    ) {
        self.configManager            = configManager
        self.moduleRegistry           = moduleRegistry
        self.settingsWindowController = settingsWindowController
        self.aboutWindowController    = aboutWindowController
        self.updateWindowController   = updateWindowController
        self.updateChecker            = updateChecker
        super.init()
    }

    // MARK: - Setup

    func start() {
        statusItem      = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate   = self
        statusItem.menu = menu
        updateIcon()

        // Registry status changes (automation status update or module list change)
        moduleRegistry.onChanged = { [weak self] in
            DispatchQueue.main.async { self?.updateIcon() }
        }

        // Config file changed on disk — delegate to registry which handles reload + rebuild
        configManager.onChanged = { [weak self] in
            guard let self else { return }
            self.moduleRegistry.reloadFromConfig()
            self.updateIcon()
        }
    }

    // MARK: - Icon

    private func aggregateColor() -> NSColor {
        let statuses = moduleRegistry.active.map { $0.status }
        if statuses.isEmpty { return .systemGreen }
        if statuses.contains(where: { if case .error    = $0 { return true }; return false }) { return .systemRed    }
        if statuses.contains(where: { if case .degraded = $0 { return true }; return false }) { return .systemOrange }
        if statuses.contains(where: { if case .disabled = $0 { return true }; return false }) { return .systemYellow }
        return .systemGreen
    }

    func updateIcon() {
        let color  = aggregateColor()
        let config = NSImage.SymbolConfiguration(paletteColors: [.white, color])
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

        for automation in moduleRegistry.active {
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

        let aboutItem = ClosureMenuItem(title: "About osx-utils-automation") { [weak self] in
            self?.aboutWindowController.showWindow()
        }
        menu.addItem(aboutItem)

        let checkUpdatesItem = ClosureMenuItem(title: "Check for Updates...") { [weak self] in
            guard let self else { return }
            self.updateChecker.checkManual(skippedVersions: self.configManager.config.skippedVersions) { [weak self] result in
                switch result {
                case .available(let info):
                    self?.updateWindowController.showUpdate(info)
                case .upToDate:
                    let alert = NSAlert()
                    alert.messageText     = "You're up to date"
                    alert.informativeText = "osx-utils-automation is already running the latest version."
                    alert.alertStyle      = .informational
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                case .failed:
                    let alert = NSAlert()
                    alert.messageText     = "Update check failed"
                    alert.informativeText = "Could not reach GitHub. Check your internet connection and try again."
                    alert.alertStyle      = .warning
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
        menu.addItem(checkUpdatesItem)

        menu.addItem(.separator())

        let logsItem = ClosureMenuItem(title: "Open Logs") { [weak self] in self?.configManager.openLogs() }
        menu.addItem(logsItem)

        let settingsItem = ClosureMenuItem(title: "Settings") { [weak self] in
            self?.settingsWindowController.showWindow()
        }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        let loginEnabled = LaunchAtLogin.isEnabled()
        let loginItem = ClosureMenuItem(title: "Launch at Login") {
            LaunchAtLogin.setEnabled(!loginEnabled)
        }
        loginItem.state = loginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
