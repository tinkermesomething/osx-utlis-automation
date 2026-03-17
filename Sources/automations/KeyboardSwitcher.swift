import Foundation
import IOKit
import IOKit.hid
import Carbon.HIToolbox
import AppKit

final class KeyboardSwitcher: NSObject, Automation {

    // MARK: - Automation Protocol

    let id          = "keyboard-switcher"
    let displayName = "Keyboard Layout Switcher"
    var onStatusChanged: (() -> Void)?

    private(set) var isEnabled = false

    private(set) var status: AutomationStatus = .disabled {
        didSet { onStatusChanged?() }
    }

    var extraMenuItems: [NSMenuItem] {
        guard isEnabled, let mac = resolvedMacLayout, let pc = resolvedPcLayout else { return [] }
        let item = NSMenuItem(
            title: "Mac: \(shortName(mac))   |   PC: \(shortName(pc))",
            action: nil, keyEquivalent: ""
        )
        item.isEnabled = false
        return [item]
    }

    // MARK: - Private state

    private let configManager: ConfigManager
    private var hidManager:   IOHIDManager?
    private var hidContext:   UnsafeMutableRawPointer?
    private var connectedKeyboards: [UInt64: DeviceKey] = [:]
    private var knownKeyboards: Set<DeviceKey> = []
    private let knownKeyboardsURL: URL
    private var initialEnumerationDone = false
    private var resolvedMacLayout: String?
    private var resolvedPcLayout:  String?

    // BT disconnect debounce — keyed by registry ID, cancelled on reconnect
    private var disconnectTimers: [UInt64: DispatchWorkItem] = [:]

    // Transport stored at connect time — device properties may be unreadable on disconnect
    private var deviceTransports: [UInt64: String] = [:]

    // Active keyboard detection — tracks last device to produce a keypress
    private var lastActiveRegistryID: UInt64? = nil
    private var activeKeypressCount:  Int      = 0
    private let activeKeypressThreshold = 1    // keypresses before switching

    private struct DeviceKey: Hashable { let vendorID: Int; let productID: Int }
    private let APPLE_VENDOR_ID = 0x05AC

    init(configManager: ConfigManager) {
        self.configManager    = configManager
        self.knownKeyboardsURL = CONFIG_DIR.appendingPathComponent("known-keyboards.json")
        super.init()
        loadKnownKeyboards()
    }

    // MARK: - Lifecycle

    func start() {
        isEnabled = true
        initialEnumerationDone = false

        guard let layouts = resolveLayouts() else {
            status = .error("No PC layout found — add one in System Settings > Keyboard > Input Sources")
            return
        }
        resolvedMacLayout = layouts.mac
        resolvedPcLayout  = layouts.pc

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = mgr

        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDPrimaryUsagePageKey: 1,
            kIOHIDPrimaryUsageKey:    6,
        ] as CFDictionary)

        // passRetained: IOHIDManager holds a strong ref; released in stop() after closing the manager
        let rawCtx = Unmanaged.passRetained(self).toOpaque()
        hidContext = rawCtx

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, result, _, device in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().deviceConnected(device)
        }, rawCtx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, result, _, device in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().deviceDisconnected(device)
        }, rawCtx)

        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, result, _, value in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().inputReceived(value)
        }, rawCtx)

        IOHIDManagerSetInputValueMatching(mgr, [kIOHIDElementUsagePageKey: 7] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let err = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if err != kIOReturnSuccess {
            status = .error("Input Monitoring permission required — grant in System Settings > Privacy & Security")
            log("KeyboardSwitcher: HID manager open failed (\(err))")
            return
        }

        log("KeyboardSwitcher: Started. Mac=\(layouts.mac) PC=\(layouts.pc) Known=\(knownKeyboards.count)")
        status = .ok("Watching for keyboards")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.initialEnumerationDone = true
            self.updateLayoutAndStatus()
        }
    }

    func stop() {
        isEnabled = false
        if let mgr = hidManager {
            // Unregister callbacks before closing so no callbacks fire during teardown
            IOHIDManagerRegisterDeviceMatchingCallback(mgr, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(mgr, nil, nil)
            IOHIDManagerRegisterInputValueCallback(mgr, nil, nil)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        hidManager = nil
        // Balance the passRetained from start()
        if let ctx = hidContext {
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).release()
            hidContext = nil
        }
        connectedKeyboards.removeAll()
        deviceTransports.removeAll()
        disconnectTimers.values.forEach { $0.cancel() }
        disconnectTimers.removeAll()
        lastActiveRegistryID = nil
        activeKeypressCount  = 0
        initialEnumerationDone = false
        status = .disabled
        log("KeyboardSwitcher: Stopped")
    }

    deinit { if isEnabled { stop() } }

    func reloadConfig(from config: Config) {
        let cfg = config.keyboardSwitcher
        if cfg.enabled && !isEnabled { start(); return }
        if !cfg.enabled && isEnabled { stop();  return }
        // Restart if BT or activeDetection changed — IOHIDManager needs to re-open
        // with updated filtering. Simplest correct approach: full restart.
        if isEnabled {
            stop()
            start()
        }
    }

    // MARK: - Device callbacks

    private func deviceConnected(_ device: IOHIDDevice) {
        guard isEnabled, isTrackedExternalKeyboard(device) else { return }
        let id   = registryID(device)
        let key  = deviceKey(device)
        let name = strVal(device, kIOHIDProductKey)

        // Cancel any pending disconnect debounce for this device (BT sleep/wake)
        if let timer = disconnectTimers.removeValue(forKey: id) {
            timer.cancel()
            log("KeyboardSwitcher: Reconnected '\(name)' within debounce window — no layout change")
            return
        }

        let transport = strVal(device, kIOHIDTransportKey)
        connectedKeyboards[id] = key
        deviceTransports[id]   = transport
        log("KeyboardSwitcher: Connected '\(name)' transport=\(transport) known=\(knownKeyboards.contains(key))")
        if initialEnumerationDone {
            // Only notify if this keyboard is already known (layout will actually switch)
            if knownKeyboards.contains(key), let pc = resolvedPcLayout {
                let isBT = transport == "Bluetooth" || transport == "BluetoothLowEnergy"
                notify(title: "\(isBT ? "Bluetooth" : "USB") keyboard connected",
                       body:  "Switching to \(shortName(pc))", transport: transport)
            }
            updateLayoutAndStatus()
        }
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard isEnabled else { return }
        let id = registryID(device)
        // Use stored transport — device properties may be unreadable at disconnect time
        guard connectedKeyboards[id] != nil else { return }
        let name      = strVal(device, kIOHIDProductKey)
        let transport = deviceTransports[id] ?? ""
        let isBluetooth = transport == "Bluetooth" || transport == "BluetoothLowEnergy"

        if isBluetooth {
            // Notify immediately so user knows what's happening during the debounce wait
            let isLastExternal = isKnownDevice(id) && realKeyboardCount() == 1
            if isLastExternal, let mac = resolvedMacLayout {
                notify(title: "Bluetooth keyboard disconnected",
                       body:  "Switching to \(shortName(mac)) in 1s", transport: transport)
            }
            // Debounce BT disconnects — keyboard may just be going to sleep
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.disconnectTimers.removeValue(forKey: id)
                self.connectedKeyboards.removeValue(forKey: id)
                self.deviceTransports.removeValue(forKey: id)
                log("KeyboardSwitcher: Disconnected (BT, confirmed) '\(name)'")
                if let mac = self.resolvedMacLayout, self.realKeyboardCount() == 0 {
                    self.notify(title: "Layout switched",
                                body:  "Now using \(self.shortName(mac))", transport: transport)
                }
                self.updateLayoutAndStatus()
            }
            disconnectTimers[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            log("KeyboardSwitcher: Disconnect debounce started for '\(name)' (1s)")
        } else {
            let isLastExternal = isKnownDevice(id) && realKeyboardCount() == 1
            connectedKeyboards.removeValue(forKey: id)
            deviceTransports.removeValue(forKey: id)
            log("KeyboardSwitcher: Disconnected '\(name)' real=\(realKeyboardCount())")
            if isLastExternal, let mac = resolvedMacLayout {
                notify(title: "USB keyboard disconnected",
                       body:  "Switching to \(shortName(mac))", transport: transport)
            }
            updateLayoutAndStatus()
        }
    }

    private func inputReceived(_ value: IOHIDValue) {
        guard isEnabled else { return }
        let elem = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsage(elem) > 3 else { return }
        let device     = IOHIDElementGetDevice(elem)
        let cfg        = configManager.config.keyboardSwitcher
        let isBuiltIn  = isBuiltInKeyboard(device)
        let isExternal = isTrackedExternalKeyboard(device)

        guard isExternal || (cfg.activeDetection && isBuiltIn) else { return }

        // Keyboard learning — only for external keyboards
        if isExternal {
            let key  = deviceKey(device)
            let name = strVal(device, kIOHIDProductKey)
            if knownKeyboards.insert(key).inserted {
                log("KeyboardSwitcher: Learned '\(name)' vendor=0x\(String(key.vendorID, radix: 16))")
                saveKnownKeyboards()
                // First keypress on a new keyboard — notify that we're switching
                let transport = strVal(device, kIOHIDTransportKey)
                let isBT = transport == "Bluetooth" || transport == "BluetoothLowEnergy"
                if let pc = resolvedPcLayout {
                    notify(title: "\(isBT ? "Bluetooth" : "USB") keyboard detected",
                           body:  "Switching to \(shortName(pc))", transport: transport)
                }
                updateLayoutAndStatus()
            }
        }

        // Active keyboard detection
        guard cfg.activeDetection else { return }
        let id = registryID(device)
        if id == lastActiveRegistryID {
            // Same keyboard — no action needed
            return
        }
        activeKeypressCount = (lastActiveRegistryID == nil) ? activeKeypressThreshold : 1
        lastActiveRegistryID = id
        if activeKeypressCount < activeKeypressThreshold { return }

        // Threshold reached — switch based on whether active keyboard is external or built-in
        if isExternal, let key = connectedKeyboards[id], knownKeyboards.contains(key) {
            if let pc = resolvedPcLayout {
                let t = deviceTransports[id] ?? ""
                notify(title: "External keyboard active", body: "Switched to \(shortName(pc))", transport: t)
                switchTo(pc)
                status = .ok("Active: external keyboard — \(shortName(pc))")
            }
        } else if isBuiltIn {
            if let mac = resolvedMacLayout {
                // Built-in keyboard is neither USB nor BT external — gate on USB toggle
                notify(title: "Built-in keyboard active", body: "Switched to \(shortName(mac))", transport: "USB")
                switchTo(mac)
                status = .ok("Active: built-in keyboard — \(shortName(mac))")
            }
        }
    }

    // MARK: - Layout switching

    private func realKeyboardCount() -> Int {
        connectedKeyboards.values.filter { knownKeyboards.contains($0) }.count
    }

    private func updateLayoutAndStatus() {
        guard isEnabled else { return }
        let count = realKeyboardCount()
        if count > 0 {
            guard let pc = resolvedPcLayout else { return }
            switchTo(pc)
            status = .ok("PC keyboard — \(shortName(pc))")
        } else {
            guard let mac = resolvedMacLayout else { return }
            switchTo(mac)
            status = knownKeyboards.isEmpty
                ? .ok("Watching — press a key on first connect")
                : .ok("Mac layout — \(shortName(mac))")
        }
    }

    private func switchTo(_ layoutID: String) {
        guard let listRef = TISCreateInputSourceList(nil, false) else { return }
        let sources = listRef.takeRetainedValue() as? [TISInputSource] ?? []
        for source in sources {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            guard id == layoutID else { continue }
            let err = TISSelectInputSource(source)
            if err == noErr {
                log("KeyboardSwitcher: Switched to \(layoutID)")
            } else {
                log("KeyboardSwitcher: Failed to switch to \(layoutID) err=\(err)")
                status = .degraded("Failed to switch layout — try re-granting Input Monitoring")
            }
            return
        }
        log("KeyboardSwitcher: Layout not found: \(layoutID)")
        status = .degraded("Layout '\(shortName(layoutID))' not found — check Settings")
    }

    // MARK: - Auto-detect layouts

    private func resolveLayouts() -> (mac: String, pc: String)? {
        let cfg = configManager.config.keyboardSwitcher
        if let mac = cfg.macLayout, let pc = cfg.pcLayout { return (mac: mac, pc: pc) }
        guard let listRef = TISCreateInputSourceList(nil, false) else { return nil }
        let sources = listRef.takeRetainedValue() as? [TISInputSource] ?? []
        var layoutIDs: [String] = []
        for source in sources {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            guard id.hasPrefix("com.apple.keylayout.") else { continue }
            layoutIDs.append(id)
        }
        guard let pcID = layoutIDs.first(where: { $0.hasSuffix("-PC") }) else { return nil }
        let baseID = pcID.replacingOccurrences(of: "-PC", with: "")
        let macID  = layoutIDs.first(where: { $0 == baseID })
                  ?? layoutIDs.first(where: { !$0.hasSuffix("-PC") })
        guard let macID else { return nil }
        return (mac: macID, pc: pcID)
    }

    // MARK: - Helpers

    /// External keyboard we're tracking — USB always, BT if opted in. Never Apple-branded.
    private func isTrackedExternalKeyboard(_ device: IOHIDDevice) -> Bool {
        guard intVal(device, kIOHIDVendorIDKey) != APPLE_VENDOR_ID else { return false }
        let transport = strVal(device, kIOHIDTransportKey)
        if transport == "USB" { return true }
        let cfg = configManager.config.keyboardSwitcher
        return cfg.includeBluetooth && (transport == "Bluetooth" || transport == "BluetoothLowEnergy")
    }

    /// Built-in MacBook keyboard — Apple device on SPI (Apple Silicon) or USB (Intel).
    private func isBuiltInKeyboard(_ device: IOHIDDevice) -> Bool {
        guard intVal(device, kIOHIDVendorIDKey) == APPLE_VENDOR_ID else { return false }
        let transport = strVal(device, kIOHIDTransportKey)
        return transport == "SPI" || transport == "USB"
    }

    private func deviceKey(_ device: IOHIDDevice) -> DeviceKey {
        DeviceKey(vendorID: intVal(device, kIOHIDVendorIDKey), productID: intVal(device, kIOHIDProductIDKey))
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != IO_OBJECT_NULL { IORegistryEntryGetRegistryEntryID(service, &id) }
        return id
    }

    private func intVal(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
    }

    private func strVal(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }

    private func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    /// True if the device with this registry ID is a known (learned) keyboard.
    private func isKnownDevice(_ id: UInt64) -> Bool {
        guard let key = connectedKeyboards[id] else { return false }
        return knownKeyboards.contains(key)
    }

    private func notify(title: String, body: String, transport: String) {
        let cfg  = configManager.config.keyboardSwitcher
        let isBT = transport == "Bluetooth" || transport == "BluetoothLowEnergy"
        guard isBT ? cfg.notifyBluetooth : cfg.notifyUSB else { return }
        NotificationManager.send(title: title, body: body)
    }

    // MARK: - Persistence

    private struct DeviceKeyJSON: Codable { let vendorID: Int; let productID: Int }

    private func loadKnownKeyboards() {
        guard let data    = try? Data(contentsOf: knownKeyboardsURL),
              let entries = try? JSONDecoder().decode([DeviceKeyJSON].self, from: data) else { return }
        knownKeyboards = Set(entries.map { DeviceKey(vendorID: $0.vendorID, productID: $0.productID) })
        log("KeyboardSwitcher: Loaded \(knownKeyboards.count) known keyboard(s)")
    }

    private func saveKnownKeyboards() {
        let entries = knownKeyboards.map { DeviceKeyJSON(vendorID: $0.vendorID, productID: $0.productID) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: CONFIG_DIR, withIntermediateDirectories: true)
        try? data.write(to: knownKeyboardsURL)
    }
}
