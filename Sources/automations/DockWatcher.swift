import Foundation
import IOKit
import IOKit.usb
import AppKit

final class DockWatcher: NSObject, Automation {

    // MARK: - Automation Protocol

    let id          = "dock-watcher"
    let displayName = "DisplayLink Watch"
    var onStatusChanged: (() -> Void)?

    private(set) var isEnabled = false

    private(set) var status: AutomationStatus = .disabled {
        didSet { onStatusChanged?() }
    }

    var extraMenuItems: [NSMenuItem] {
        guard isEnabled else { return [] }
        let title = isDisplayLinkRunning() ? "Quit DisplayLink" : "Launch DisplayLink"
        return [ClosureMenuItem(title: title) { [weak self] in self?.manualToggleDisplayLink() }]
    }

    // MARK: - Private state

    private let configManager: ConfigManager
    private var notifyPort:   IONotificationPortRef?
    private var addedIter:    io_iterator_t = 0
    private var removedIter:  io_iterator_t = 0
    private var ioKitContext: UnsafeMutableRawPointer?

    private let DOCK_VENDOR_ID:  Int32 = 6121   // 0x17E9 DisplayLink
    private let DOCK_PRODUCT_ID: Int32 = 24582  // 0x6006 D6000
    private let DISPLAYLINK_PROCESS = "DisplayLinkUserAgent"
    private let DISPLAYLINK_APP     = "DisplayLink Manager"

    init(configManager: ConfigManager) {
        self.configManager = configManager
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        isEnabled = true
        setupIOKitWatcher()
        log("DockWatcher: Started")
    }

    func stop() {
        isEnabled = false
        // Destroy the port first — this stops callbacks before we release the context pointer
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        if addedIter   != IO_OBJECT_NULL { IOObjectRelease(addedIter);   addedIter   = IO_OBJECT_NULL }
        if removedIter != IO_OBJECT_NULL { IOObjectRelease(removedIter); removedIter = IO_OBJECT_NULL }
        // Balance the passRetained from setupIOKitWatcher
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
        if  shouldBeEnabled && !isEnabled { start() }
        if !shouldBeEnabled &&  isEnabled { stop()  }
    }

    // MARK: - IOKit watcher

    private func matchingDict() -> CFMutableDictionary {
        let dict = IOServiceMatching(kIOUSBDeviceClassName)! as NSMutableDictionary
        dict[kUSBVendorID]  = DOCK_VENDOR_ID
        dict[kUSBProductID] = DOCK_PRODUCT_ID
        return dict as CFMutableDictionary
    }

    private func setupIOKitWatcher() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            status = .error("Failed to create IONotificationPort")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        // passRetained: IOKit holds a strong ref; released in stop() after port is destroyed
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
        log("DockWatcher: Dock connected")
        if isDisplayLinkRunning() {
            log("DockWatcher: DisplayLink already running")
            status = .ok("Dock connected — DisplayLink running")
        } else {
            notify(title: "Dock connected", body: "Launching DisplayLink Manager")
            launchDisplayLink()
        }
    }

    private func dockDisconnected() {
        guard isEnabled else { return }
        log("DockWatcher: Dock disconnected")
        notify(title: "Dock disconnected", body: "DisplayLink Manager quit")
        quitDisplayLink()
        status = .ok("Dock not connected")
    }

    private func notify(title: String, body: String) {
        guard configManager.config.dockWatcher.notifications else { return }
        NotificationManager.send(title: title, body: body)
    }

    // MARK: - DisplayLink control

    func isDisplayLinkRunning() -> Bool { displayLinkPID() != nil }

    private func displayLinkPID() -> Int32? {
        let pipe = Pipe()
        let task = Process()
        task.launchPath     = "/usr/bin/pgrep"
        task.arguments      = ["-f", DISPLAYLINK_PROCESS]
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pid = Int32(trimmed), pid > 0 else { return nil }
        return pid
    }

    private func launchDisplayLink() {
        log("DockWatcher: Launching \(DISPLAYLINK_APP)")
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments  = ["-a", DISPLAYLINK_APP]
        try? task.run()
        status = .ok("Dock connected — DisplayLink launching…")
        // Confirm launch after a few seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.status = self.isDisplayLinkRunning()
                ? .ok("Dock connected — DisplayLink running")
                : .degraded("Dock connected — DisplayLink failed to start")
        }
    }

    private func quitDisplayLink() {
        guard let pid = displayLinkPID() else {
            log("DockWatcher: DisplayLink not running")
            return
        }
        log("DockWatcher: Killing \(DISPLAYLINK_PROCESS) pid=\(pid)")
        // SIGTERM is ignored by DisplayLinkUserAgent — SIGKILL required
        let task = Process()
        task.launchPath = "/bin/kill"
        task.arguments  = ["-9", String(pid)]
        try? task.run()
        task.waitUntilExit()
    }

    private func manualToggleDisplayLink() {
        if isDisplayLinkRunning() {
            quitDisplayLink()
            status = .ok("Dock connected — DisplayLink stopped")
        } else {
            launchDisplayLink()
        }
        onStatusChanged?()
    }
}
