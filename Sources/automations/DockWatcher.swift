import Foundation
import IOKit
import IOKit.usb
import AppKit

final class DockWatcher: NSObject, Automation {

    // MARK: - Automation Protocol

    let id          = "dock-watcher"
    let displayName = "Dock Watcher"
    var onStatusChanged: (() -> Void)?

    private(set) var isEnabled = false

    private(set) var status: AutomationStatus = .disabled {
        didSet { onStatusChanged?() }
    }

    var extraMenuItems: [NSMenuItem] {
        guard isEnabled, let name = configManager.config.dockWatcher.appName else { return [] }
        let title = isAppRunning() ? "Quit \(name)" : "Launch \(name)"
        return [ClosureMenuItem(title: title) { [weak self] in self?.manualToggleApp() }]
    }

    // MARK: - Private state

    private let configManager: ConfigManager
    private var notifyPort:   IONotificationPortRef?
    private var addedIter:    io_iterator_t = 0
    private var removedIter:  io_iterator_t = 0
    private var ioKitContext: UnsafeMutableRawPointer?

    init(configManager: ConfigManager) {
        self.configManager = configManager
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        isEnabled = true
        let cfg = configManager.config.dockWatcher
        guard cfg.dockVendorID != nil, cfg.dockProductID != nil else {
            status = .degraded("No dock configured — set up in Settings")
            log("DockWatcher: No dock configured")
            return
        }
        guard cfg.appBundleID != nil else {
            status = .degraded("No app configured — set up in Settings")
            log("DockWatcher: No app configured")
            return
        }
        setupIOKitWatcher()
        log("DockWatcher: Started")
    }

    func stop() {
        isEnabled = false
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        if addedIter   != IO_OBJECT_NULL { IOObjectRelease(addedIter);   addedIter   = IO_OBJECT_NULL }
        if removedIter != IO_OBJECT_NULL { IOObjectRelease(removedIter); removedIter = IO_OBJECT_NULL }
        if let ctx = ioKitContext {
            Unmanaged<DockWatcher>.fromOpaque(ctx).release()
            ioKitContext = nil
        }
        status = .disabled
        log("DockWatcher: Stopped")
    }

    deinit { if isEnabled { stop() } }

    func reloadConfig(from config: Config) {
        let shouldBeEnabled = config.dockWatcher.enabled
        if  shouldBeEnabled && !isEnabled { start(); return }
        if !shouldBeEnabled &&  isEnabled { stop();  return }
        // Restart if dock device or app changed
        if isEnabled { stop(); start() }
    }

    // MARK: - IOKit watcher

    private func matchingDict() -> CFMutableDictionary {
        let cfg  = configManager.config.dockWatcher
        let dict = IOServiceMatching(kIOUSBDeviceClassName)! as NSMutableDictionary
        dict[kUSBVendorID]  = cfg.dockVendorID
        dict[kUSBProductID] = cfg.dockProductID
        return dict as CFMutableDictionary
    }

    private func setupIOKitWatcher() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            status = .error("Failed to create IONotificationPort")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let rawCtx = Unmanaged.passRetained(self).toOpaque()
        ioKitContext = rawCtx

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingDict(), { ctx, iter in
            var svc = IOIteratorNext(iter); var found = false
            while svc != IO_OBJECT_NULL { IOObjectRelease(svc); found = true; svc = IOIteratorNext(iter) }
            guard found, let ctx else { return }
            Unmanaged<DockWatcher>.fromOpaque(ctx).takeUnretainedValue().dockConnected()
        }, rawCtx, &addedIter)

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingDict(), { ctx, iter in
            var svc = IOIteratorNext(iter); var found = false
            while svc != IO_OBJECT_NULL { IOObjectRelease(svc); found = true; svc = IOIteratorNext(iter) }
            guard found, let ctx else { return }
            Unmanaged<DockWatcher>.fromOpaque(ctx).takeUnretainedValue().dockDisconnected()
        }, rawCtx, &removedIter)

        // Drain iterators to arm notifications and detect startup state
        var dockPresent = false
        var svc = IOIteratorNext(addedIter)
        while svc != IO_OBJECT_NULL { IOObjectRelease(svc); dockPresent = true; svc = IOIteratorNext(addedIter) }
        svc = IOIteratorNext(removedIter)
        while svc != IO_OBJECT_NULL { IOObjectRelease(svc); svc = IOIteratorNext(removedIter) }

        if dockPresent {
            log("DockWatcher: Dock present at startup")
            dockConnected()
        } else {
            status = .ok("Dock not connected")
        }
    }

    // MARK: - Dock events

    private func dockConnected() {
        guard isEnabled else { return }
        let name = configManager.config.dockWatcher.appName ?? "app"
        log("DockWatcher: Dock connected")
        if isAppRunning() {
            log("DockWatcher: \(name) already running")
            status = .ok("Dock connected — \(name) running")
        } else {
            notify(title: "Dock connected", body: "Launching \(name)")
            launchApp()
        }
    }

    private func dockDisconnected() {
        guard isEnabled else { return }
        let name = configManager.config.dockWatcher.appName ?? "app"
        log("DockWatcher: Dock disconnected")
        notify(title: "Dock disconnected", body: "Quitting \(name)")
        quitApp()
        status = .ok("Dock not connected")
    }

    private func notify(title: String, body: String) {
        guard configManager.config.dockWatcher.notifications else { return }
        NotificationManager.send(title: title, body: body)
    }

    // MARK: - App control

    func isAppRunning() -> Bool {
        guard let bundleID = configManager.config.dockWatcher.appBundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func launchApp() {
        guard let bundleID = configManager.config.dockWatcher.appBundleID else { return }
        let name = configManager.config.dockWatcher.appName ?? bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            log("DockWatcher: App not found — \(bundleID)")
            status = .degraded("Dock connected — \(name) not found")
            return
        }
        log("DockWatcher: Launching \(name)")
        status = .ok("Dock connected — launching \(name)…")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    log("DockWatcher: Launch failed — \(error.localizedDescription)")
                    self.status = .degraded("Dock connected — \(name) failed to start")
                } else {
                    self.status = .ok("Dock connected — \(name) running")
                }
            }
        }
    }

    private func quitApp() {
        guard let bundleID = configManager.config.dockWatcher.appBundleID else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else {
            log("DockWatcher: App not running, nothing to quit")
            return
        }
        let name = configManager.config.dockWatcher.appName ?? bundleID
        log("DockWatcher: Quitting \(name)")
        apps.forEach { $0.terminate() }
        // Force-quit after 2s if still running (some apps ignore terminate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if !still.isEmpty {
                log("DockWatcher: Force-quitting \(name)")
                still.forEach { $0.forceTerminate() }
            }
        }
    }

    private func manualToggleApp() {
        if isAppRunning() {
            quitApp()
            let name = configManager.config.dockWatcher.appName ?? "app"
            status = .ok("Dock connected — \(name) stopped")
        } else {
            launchApp()
        }
        onStatusChanged?()
    }
}
