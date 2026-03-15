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
    private var hidManager: IOHIDManager?
    private var connectedKeyboards: [UInt64: DeviceKey] = [:]
    private var knownKeyboards: Set<DeviceKey> = []
    private let knownKeyboardsURL: URL
    private var initialEnumerationDone = false
    private var resolvedMacLayout: String?
    private var resolvedPcLayout:  String?

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

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, result, _, device in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().deviceConnected(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, result, _, device in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().deviceDisconnected(device)
        }, ctx)

        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, result, _, value in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().inputReceived(value)
        }, ctx)

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
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        hidManager = nil
        connectedKeyboards.removeAll()
        initialEnumerationDone = false
        status = .disabled
        log("KeyboardSwitcher: Stopped")
    }

    func reloadConfig(from config: Config) {
        let shouldBeEnabled = config.keyboardSwitcher.enabled
        if shouldBeEnabled && !isEnabled { start(); return }
        if !shouldBeEnabled && isEnabled { stop();  return }
        // Already in the right state — refresh layouts if running
        if isEnabled, let layouts = resolveLayouts() {
            resolvedMacLayout = layouts.mac
            resolvedPcLayout  = layouts.pc
            updateLayoutAndStatus()
        }
    }

    // MARK: - Device callbacks

    private func deviceConnected(_ device: IOHIDDevice) {
        guard isEnabled, isNonAppleUSBDevice(device) else { return }
        let id   = registryID(device)
        let key  = deviceKey(device)
        let name = strVal(device, kIOHIDProductKey)
        connectedKeyboards[id] = key
        log("KeyboardSwitcher: Connected '\(name)' vendor=0x\(String(key.vendorID, radix: 16)) known=\(knownKeyboards.contains(key))")
        if initialEnumerationDone { updateLayoutAndStatus() }
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard isEnabled, isNonAppleUSBDevice(device) else { return }
        let id   = registryID(device)
        let name = strVal(device, kIOHIDProductKey)
        guard connectedKeyboards.removeValue(forKey: id) != nil else { return }
        log("KeyboardSwitcher: Disconnected '\(name)' real=\(realKeyboardCount())")
        updateLayoutAndStatus()
    }

    private func inputReceived(_ value: IOHIDValue) {
        guard isEnabled else { return }
        let elem = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsage(elem) > 3 else { return }
        let device = IOHIDElementGetDevice(elem)
        guard isNonAppleUSBDevice(device) else { return }
        let key  = deviceKey(device)
        let name = strVal(device, kIOHIDProductKey)
        guard knownKeyboards.insert(key).inserted else { return }
        log("KeyboardSwitcher: Learned '\(name)' vendor=0x\(String(key.vendorID, radix: 16))")
        saveKnownKeyboards()
        updateLayoutAndStatus()
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
        let sources = listRef.takeRetainedValue() as! [TISInputSource]
        for source in sources {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            guard id == layoutID else { continue }
            let err = TISSelectInputSource(source)
            log("KeyboardSwitcher: \(err == noErr ? "Switched" : "Failed to switch") to \(layoutID)")
            return
        }
        log("KeyboardSwitcher: Layout not found: \(layoutID)")
    }

    // MARK: - Auto-detect layouts

    private func resolveLayouts() -> (mac: String, pc: String)? {
        let cfg = configManager.config.keyboardSwitcher
        if let mac = cfg.macLayout, let pc = cfg.pcLayout { return (mac: mac, pc: pc) }
        guard let listRef = TISCreateInputSourceList(nil, false) else { return nil }
        let sources = listRef.takeRetainedValue() as! [TISInputSource]
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

    private func isNonAppleUSBDevice(_ device: IOHIDDevice) -> Bool {
        strVal(device, kIOHIDTransportKey) == "USB" && intVal(device, kIOHIDVendorIDKey) != APPLE_VENDOR_ID
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
