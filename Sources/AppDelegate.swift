import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var configManager:            ConfigManager!
    private var moduleRegistry:           ModuleRegistry!
    private var menuBarController:        MenuBarController!
    private var settingsWindowController: SettingsWindowController!
    private var aboutWindowController:    AboutWindowController!
    private var updateWindowController:   UpdateWindowController!
    private var updateChecker:            UpdateChecker!
    private var welcomeWindowController:  WelcomeWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        configManager  = ConfigManager()
        moduleRegistry = ModuleRegistry(configManager: configManager)

        // Detect first run before any writes happen (config file won't exist yet)
        let isFirstRun = !FileManager.default.fileExists(atPath: CONFIG_URL.path)

        settingsWindowController = SettingsWindowController(configManager: configManager, moduleRegistry: moduleRegistry)
        aboutWindowController    = AboutWindowController()
        updateWindowController   = UpdateWindowController(configManager: configManager)
        updateChecker            = UpdateChecker()

        menuBarController = MenuBarController(
            configManager:            configManager,
            moduleRegistry:           moduleRegistry,
            settingsWindowController: settingsWindowController,
            aboutWindowController:    aboutWindowController,
            updateWindowController:   updateWindowController,
            updateChecker:            updateChecker
        )
        menuBarController.start()

        // Wire "Check for Updates" button in Settings > General
        settingsWindowController.onCheckForUpdates = { [weak self] in
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

        if isFirstRun {
            // Show welcome wizard; startAll() is deferred until user taps "Get Started"
            welcomeWindowController = WelcomeWindowController(configManager: configManager, moduleRegistry: moduleRegistry)
            welcomeWindowController.onCompleted = { [weak self] in
                self?.moduleRegistry.startAll()
            }
            welcomeWindowController.show()
        } else {
            moduleRegistry.startAll()
        }

        // Non-blocking update check — fires after a short delay so launch is not held up
        updateChecker.onUpdateAvailable = { [weak self] info in
            self?.updateWindowController.showUpdate(info)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.updateChecker.checkAsync(skippedVersions: self.configManager.config.skippedVersions)
        }

        // Request notification permission upfront in the proper app launch context.
        // Calling this from within IOHIDManager callbacks is too late — macOS won't prompt.
        NotificationManager.requestAuthorizationIfNeeded()

        log("osx-utils-automation started")
    }
}
