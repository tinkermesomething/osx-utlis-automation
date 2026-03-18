import AppKit
import IOKit
import IOKit.usb
import IOBluetooth

// MARK: - UserModuleRunner

/// Runtime engine for a user-defined hardware automation module.
/// Monitors USB, Bluetooth, or Thunderbolt events and executes user-configured actions.
final class UserModuleRunner: NSObject, Automation {

    // MARK: - Automation Protocol

    var id:          String { moduleConfig.id }
    var displayName: String { moduleConfig.name }
    var onStatusChanged: (() -> Void)?

    private(set) var isEnabled = false

    private(set) var status: AutomationStatus = .disabled {
        didSet { onStatusChanged?() }
    }

    var extraMenuItems: [NSMenuItem] { [] }

    // MARK: - Private state

    private var moduleConfig:  UserModuleConfig
    private let configManager: ConfigManager

    // IOKit notification port (USB / Thunderbolt)
    private var notifyPort:       IONotificationPortRef?
    private var connectIterator:  io_iterator_t = IO_OBJECT_NULL
    private var removeIterator:   io_iterator_t = IO_OBJECT_NULL
    // passRetained context pointer — must be released exactly once in stopIOKitMonitoring()
    private var hidContext:       UnsafeMutableRawPointer?

    // Bluetooth notification tokens
    private var btConnectNotification:    IOBluetoothUserNotification?
    private var btDisconnectNotification: IOBluetoothUserNotification?

    // Script process tracking (re-entrancy guard)
    private var connectScriptProcess:    Process?
    private var disconnectScriptProcess: Process?

    // Thunderbolt: track which registry IDs are currently connected
    private var connectedTBRegistryIDs = Set<UInt64>()

    init(moduleConfig: UserModuleConfig, configManager: ConfigManager) {
        self.moduleConfig  = moduleConfig
        self.configManager = configManager
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        isEnabled = true
        switch moduleConfig.trigger.eventType {
        case .usb:          startUSBMonitoring()
        case .bluetooth:    startBluetoothMonitoring()
        case .thunderbolt:  startThunderboltMonitoring()
        }
    }

    func stop() {
        isEnabled = false
        // Gate cleanup on event type — only one of these will have been started
        switch moduleConfig.trigger.eventType {
        case .usb, .thunderbolt: stopIOKitMonitoring()
        case .bluetooth:         stopBluetoothMonitoring()
        }
        connectScriptProcess?.terminate()
        connectScriptProcess = nil
        disconnectScriptProcess?.terminate()
        disconnectScriptProcess = nil
        connectedTBRegistryIDs.removeAll()
        status = .disabled
        log("UserModule[\(moduleConfig.name)]: Stopped")
    }

    deinit { if isEnabled { stop() } }

    func reloadConfig(from config: Config) {
        guard let updated = config.userModules.first(where: { $0.id == moduleConfig.id }) else {
            // Module was deleted from config — stop
            if isEnabled { stop() }
            return
        }
        let wasRunning = isEnabled  // use runtime flag, not config flag (B3)
        moduleConfig = updated
        if updated.enabled && !wasRunning { start(); return }
        if !updated.enabled && wasRunning { stop();  return }
        // Module stays enabled — restart to rebuild IOKit matching dict with updated
        // trigger criteria (device VID/PID, BT address). Notifications/actions read live.
        if isEnabled { stop(); start() }
    }

    // MARK: - USB Monitoring

    private func startUSBMonitoring() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let matchingDict = usbMatchingDict()
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        hidContext = selfPtr  // stored for balanced release in stopIOKitMonitoring()

        var connectIt: io_iterator_t = IO_OBJECT_NULL
        let connectErr = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchingDict as CFDictionary,
            { ctx, it in
                guard let ctx else { return }
                let runner = Unmanaged<UserModuleRunner>.fromOpaque(ctx).takeUnretainedValue()
                runner.handleIOKitConnected(iterator: it)
            },
            selfPtr,
            &connectIt
        )

        if connectErr == kIOReturnSuccess {
            connectIterator = connectIt
            // Drain initial enumeration — devices already connected at start-up should not trigger
            drainIterator(connectIt)
        } else {
            log("UserModule[\(moduleConfig.name)]: IOKit connect notification failed (\(connectErr))")
        }

        // Retain a second matching dict (IOServiceAddMatchingNotification consumes one ref per call)
        let matchingDict2 = usbMatchingDict()
        var removeIt: io_iterator_t = IO_OBJECT_NULL
        let removeErr = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDict2 as CFDictionary,
            { ctx, it in
                guard let ctx else { return }
                let runner = Unmanaged<UserModuleRunner>.fromOpaque(ctx).takeUnretainedValue()
                runner.handleIOKitDisconnected(iterator: it)
            },
            selfPtr,
            &removeIt
        )

        if removeErr == kIOReturnSuccess {
            removeIterator = removeIt
            drainIterator(removeIt)
        } else {
            log("UserModule[\(moduleConfig.name)]: IOKit remove notification failed (\(removeErr))")
        }

        log("UserModule[\(moduleConfig.name)]: Watching USB — \(moduleConfig.trigger.deviceName)")
        status = .ok("Watching for \(moduleConfig.trigger.deviceName)")
    }

    private func stopIOKitMonitoring() {
        if connectIterator != IO_OBJECT_NULL { IOObjectRelease(connectIterator); connectIterator = IO_OBJECT_NULL }
        if removeIterator  != IO_OBJECT_NULL { IOObjectRelease(removeIterator);  removeIterator  = IO_OBJECT_NULL }
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        // Balance the single passRetained from start — fromOpaque on the stored pointer
        if let ctx = hidContext { Unmanaged<UserModuleRunner>.fromOpaque(ctx).release(); hidContext = nil }
    }

    private func usbMatchingDict() -> NSMutableDictionary {
        let dict = IOServiceMatching(kIOUSBHostDeviceClassName) as NSMutableDictionary
        if let vid = moduleConfig.trigger.deviceVendorID {
            dict[kUSBVendorID]  = vid
        }
        if let pid = moduleConfig.trigger.deviceProductID {
            dict[kUSBProductID] = pid
        }
        return dict
    }

    private func drainIterator(_ it: io_iterator_t) {
        var service = IOIteratorNext(it)
        while service != IO_OBJECT_NULL {
            IOObjectRelease(service)
            service = IOIteratorNext(it)
        }
    }

    private func handleIOKitConnected(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        var fired = false
        while service != IO_OBJECT_NULL {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
            fired = true
        }
        guard fired else { return }
        log("UserModule[\(moduleConfig.name)]: Device connected")
        handleConnectEvent()
    }

    private func handleIOKitDisconnected(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        var fired = false
        while service != IO_OBJECT_NULL {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
            fired = true
        }
        guard fired else { return }
        log("UserModule[\(moduleConfig.name)]: Device disconnected")
        handleDisconnectEvent()
    }

    // MARK: - Bluetooth Monitoring

    private func startBluetoothMonitoring() {
        // Register for any BT device connect — filter by address in callback
        btConnectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(btDeviceConnected(_:device:))
        )

        log("UserModule[\(moduleConfig.name)]: Watching Bluetooth — \(moduleConfig.trigger.deviceName)")
        status = .ok("Watching for \(moduleConfig.trigger.deviceName)")
    }

    private func stopBluetoothMonitoring() {
        btConnectNotification?.unregister()
        btConnectNotification = nil
        btDisconnectNotification?.unregister()
        btDisconnectNotification = nil
    }

    @objc private func btDeviceConnected(_ notification: IOBluetoothUserNotification,
                                          device: IOBluetoothDevice) {
        // If configured for a specific address, filter here
        if let targetAddress = moduleConfig.trigger.bluetoothAddress {
            guard device.addressString == targetAddress else { return }
        }

        log("UserModule[\(moduleConfig.name)]: BT device connected — \(device.name ?? device.addressString ?? "")")

        // Register for disconnect on this specific device instance
        btDisconnectNotification?.unregister()
        btDisconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(btDeviceDisconnected(_:device:))
        )

        handleConnectEvent()
    }

    @objc private func btDeviceDisconnected(_ notification: IOBluetoothUserNotification,
                                             device: IOBluetoothDevice) {
        log("UserModule[\(moduleConfig.name)]: BT device disconnected — \(device.name ?? device.addressString ?? "")")
        btDisconnectNotification?.unregister()
        btDisconnectNotification = nil
        handleDisconnectEvent()
    }

    // MARK: - Thunderbolt Monitoring

    private func startThunderboltMonitoring() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let tbDict = IOServiceMatching("IOPCIDevice") as NSMutableDictionary
        tbDict["IOPCITunnelled"] = true

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        hidContext = selfPtr  // stored for balanced release in stopIOKitMonitoring()

        var connectIt: io_iterator_t = IO_OBJECT_NULL
        let connectErr = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification,
            tbDict as CFDictionary,
            { ctx, it in
                guard let ctx else { return }
                Unmanaged<UserModuleRunner>.fromOpaque(ctx).takeUnretainedValue()
                    .handleThunderboltConnected(iterator: it)
            },
            selfPtr, &connectIt
        )

        if connectErr == kIOReturnSuccess {
            connectIterator = connectIt
            drainIterator(connectIt)  // drain initial — don't fire on existing devices
        }

        let tbDict2 = IOServiceMatching("IOPCIDevice") as NSMutableDictionary
        tbDict2["IOPCITunnelled"] = true

        var removeIt: io_iterator_t = IO_OBJECT_NULL
        let removeErr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            tbDict2 as CFDictionary,
            { ctx, it in
                guard let ctx else { return }
                Unmanaged<UserModuleRunner>.fromOpaque(ctx).takeUnretainedValue()
                    .handleThunderboltDisconnected(iterator: it)
            },
            selfPtr, &removeIt
        )

        if removeErr == kIOReturnSuccess {
            removeIterator = removeIt
            drainIterator(removeIt)
        }

        log("UserModule[\(moduleConfig.name)]: Watching Thunderbolt")
        status = .ok("Watching for Thunderbolt devices")
    }

    private func handleThunderboltConnected(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        var newIDs = [UInt64]()
        while service != IO_OBJECT_NULL {
            var regID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &regID)
            IOObjectRelease(service)
            newIDs.append(regID)
            service = IOIteratorNext(iterator)
        }
        guard !newIDs.isEmpty else { return }
        for id in newIDs { connectedTBRegistryIDs.insert(id) }
        log("UserModule[\(moduleConfig.name)]: Thunderbolt device(s) connected")
        handleConnectEvent()
    }

    private func handleThunderboltDisconnected(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        var removedIDs = [UInt64]()
        while service != IO_OBJECT_NULL {
            var regID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &regID)
            IOObjectRelease(service)
            removedIDs.append(regID)
            service = IOIteratorNext(iterator)
        }
        guard !removedIDs.isEmpty else { return }
        for id in removedIDs { connectedTBRegistryIDs.remove(id) }
        log("UserModule[\(moduleConfig.name)]: Thunderbolt device(s) disconnected")
        handleDisconnectEvent()
    }

    // MARK: - Action execution

    // Identify which script slot to use — avoids inout capture in escaping closures
    private enum ScriptSlot { case connect, disconnect }

    private func handleConnectEvent() {
        if moduleConfig.notifyOnConnect {
            NotificationManager.send(
                title: "\(moduleConfig.name): connected",
                body:  moduleConfig.trigger.deviceName
            )
        }
        executeAction(moduleConfig.onConnect, slot: .connect)
    }

    private func handleDisconnectEvent() {
        if moduleConfig.notifyOnDisconnect {
            NotificationManager.send(
                title: "\(moduleConfig.name): disconnected",
                body:  moduleConfig.trigger.deviceName
            )
        }
        executeAction(moduleConfig.onDisconnect, slot: .disconnect)
    }

    private func executeAction(_ action: UserModuleAction, slot: ScriptSlot) {
        switch action.kind {
        case .none:
            break

        case .launchApp:
            guard let bundleID = action.appBundleID else { return }
            // No-op if already running
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                log("UserModule[\(moduleConfig.name)]: \(action.appName ?? bundleID) already running — skipping launch")
                return
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                log("UserModule[\(moduleConfig.name)]: App not found — \(bundleID)")
                status = .degraded("App not found: \(action.appName ?? bundleID)")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    log("UserModule[\(self.moduleConfig.name)]: Launch failed — \(error.localizedDescription)")
                    self.status = .degraded("Failed to launch \(action.appName ?? bundleID)")
                } else {
                    log("UserModule[\(self.moduleConfig.name)]: Launched \(action.appName ?? bundleID)")
                }
            }

        case .quitApp:
            guard let bundleID = action.appBundleID else { return }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if apps.isEmpty {
                log("UserModule[\(moduleConfig.name)]: \(action.appName ?? bundleID) not running — nothing to quit")
                return
            }
            apps.forEach { $0.terminate() }
            log("UserModule[\(moduleConfig.name)]: Quit \(action.appName ?? bundleID)")

        case .runScript:
            guard let path = action.scriptPath else { return }
            // Re-entrancy guard — check the right slot without inout
            let current: Process? = slot == .connect ? connectScriptProcess : disconnectScriptProcess
            if current?.isRunning == true {
                log("UserModule[\(moduleConfig.name)]: Script already running — skipping")
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments     = ["-c", path]
            // terminationHandler fires on an arbitrary thread — always dispatch to main
            process.terminationHandler = { [weak self] p in
                DispatchQueue.main.async {
                    guard let self else { return }
                    log("UserModule[\(self.moduleConfig.name)]: Script exited (\(p.terminationStatus))")
                    switch slot {
                    case .connect:    if self.connectScriptProcess    === p { self.connectScriptProcess    = nil }
                    case .disconnect: if self.disconnectScriptProcess === p { self.disconnectScriptProcess = nil }
                    }
                }
            }
            do {
                try process.run()
                switch slot {
                case .connect:    connectScriptProcess    = process
                case .disconnect: disconnectScriptProcess = process
                }
                log("UserModule[\(moduleConfig.name)]: Script launched — \(path)")
            } catch {
                log("UserModule[\(moduleConfig.name)]: Script launch failed — \(error.localizedDescription)")
                status = .degraded("Script failed: \(URL(fileURLWithPath: path).lastPathComponent)")
            }
        }
    }
}
