import AppKit

// MARK: - Paths

let CONFIG_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/osx-utils-automation")

let CONFIG_URL = CONFIG_DIR.appendingPathComponent("config.json")

let LOG_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/osx-utils-automation.log")

// MARK: - Model

struct Config: Codable {
    var keyboardSwitcher  = KeyboardSwitcherConfig()
    var dockWatcher       = DockWatcherConfig()
    var registeredModules = ["keyboard-switcher", "dock-watcher"]
    var skippedVersions   = [String]()

    struct KeyboardSwitcherConfig: Codable {
        var enabled:          Bool
        var macLayout:        String?
        var pcLayout:         String?
        var includeBluetooth: Bool
        var activeDetection:  Bool
        var notifications:    Bool

        init(enabled: Bool = true, macLayout: String? = nil, pcLayout: String? = nil,
             includeBluetooth: Bool = false, activeDetection: Bool = false, notifications: Bool = true) {
            self.enabled          = enabled
            self.macLayout        = macLayout
            self.pcLayout         = pcLayout
            self.includeBluetooth = includeBluetooth
            self.activeDetection  = activeDetection
            self.notifications    = notifications
        }

        init(from decoder: Decoder) throws {
            let c  = try decoder.container(keyedBy: CodingKeys.self)
            enabled          = try c.decodeIfPresent(Bool.self,   forKey: .enabled)          ?? true
            macLayout        = try c.decodeIfPresent(String.self, forKey: .macLayout)
            pcLayout         = try c.decodeIfPresent(String.self, forKey: .pcLayout)
            includeBluetooth = try c.decodeIfPresent(Bool.self,   forKey: .includeBluetooth) ?? false
            activeDetection  = try c.decodeIfPresent(Bool.self,   forKey: .activeDetection)  ?? false
            notifications    = try c.decodeIfPresent(Bool.self,   forKey: .notifications)    ?? true
        }
    }

    struct DockWatcherConfig: Codable {
        var enabled:       Bool
        var notifications: Bool

        init(enabled: Bool = true, notifications: Bool = true) {
            self.enabled       = enabled
            self.notifications = notifications
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled       = try c.decodeIfPresent(Bool.self, forKey: .enabled)       ?? true
            notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboardSwitcher  = try c.decodeIfPresent(KeyboardSwitcherConfig.self, forKey: .keyboardSwitcher) ?? KeyboardSwitcherConfig()
        dockWatcher       = try c.decodeIfPresent(DockWatcherConfig.self,      forKey: .dockWatcher)      ?? DockWatcherConfig()
        // Default: both modules registered — existing users keep their current setup
        registeredModules = try c.decodeIfPresent([String].self, forKey: .registeredModules)
                         ?? ["keyboard-switcher", "dock-watcher"]
        skippedVersions   = try c.decodeIfPresent([String].self, forKey: .skippedVersions) ?? []
    }
}

// MARK: - Manager

final class ConfigManager {
    private(set) var config = Config()
    var onChanged: (() -> Void)?
    private var fsStream: FSEventStreamRef?

    init() {
        createDirIfNeeded()
        load()
        watchForChanges()
    }

    deinit {
        if let stream = fsStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsStream = nil
        }
    }

    // MARK: - Load / Save

    func load() {
        guard let data   = try? Data(contentsOf: CONFIG_URL),
              let loaded = try? JSONDecoder().decode(Config.self, from: data) else { return }
        config = loaded
    }

    func save() {
        createDirIfNeeded()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else {
            log("ConfigManager: Failed to encode config")
            return
        }
        // Write atomically (write-to-temp then rename) to prevent corruption on interrupted writes
        do {
            let tmp = CONFIG_URL.deletingLastPathComponent()
                .appendingPathComponent("config.json.tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(CONFIG_URL, withItemAt: tmp)
        } catch {
            log("ConfigManager: Failed to save config — \(error)")
        }
    }

    func setEnabled(automationId: String, enabled: Bool) {
        switch automationId {
        case "keyboard-switcher": config.keyboardSwitcher.enabled = enabled
        case "dock-watcher":      config.dockWatcher.enabled      = enabled
        default: break
        }
        save()
    }

    func setRegistered(moduleId: String, registered: Bool) {
        if registered {
            if !config.registeredModules.contains(moduleId) {
                config.registeredModules.append(moduleId)
            }
        } else {
            config.registeredModules.removeAll { $0 == moduleId }
        }
        save()
    }

    func setRegisteredModules(_ modules: [String]) {
        config.registeredModules = modules
        save()
    }

    func skipVersion(_ version: String) {
        if !config.skippedVersions.contains(version) {
            config.skippedVersions.append(version)
        }
        save()
    }

    func setKeyboardNotificationsEnabled(_ enabled: Bool) {
        config.keyboardSwitcher.notifications = enabled
        save()
    }

    func setDockNotificationsEnabled(_ enabled: Bool) {
        config.dockWatcher.notifications = enabled
        save()
    }

    func setBluetoothEnabled(_ enabled: Bool) {
        config.keyboardSwitcher.includeBluetooth = enabled
        save()
    }

    func setActiveDetectionEnabled(_ enabled: Bool) {
        config.keyboardSwitcher.activeDetection = enabled
        save()
    }

    func setKeyboardLayouts(mac: String?, pc: String?) {
        config.keyboardSwitcher.macLayout = mac
        config.keyboardSwitcher.pcLayout  = pc
        save()
    }

    func openInEditor() {
        if !FileManager.default.fileExists(atPath: CONFIG_URL.path) { save() }
        NSWorkspace.shared.open(CONFIG_URL)
    }

    func openLogs() {
        if !FileManager.default.fileExists(atPath: LOG_URL.path) {
            try? "".write(to: LOG_URL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(LOG_URL)
    }

    // MARK: - FSEvents watcher

    private func createDirIfNeeded() {
        try? FileManager.default.createDirectory(at: CONFIG_DIR, withIntermediateDirectories: true)
    }

    private func watchForChanges() {
        // passRetained: stream holds a strong ref to self; released in deinit via context release callback
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        var ctx = FSEventStreamContext(
            version: 0,
            info: selfPtr,
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<ConfigManager>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        fsStream = FSEventStreamCreate(
            nil,
            { _, ctx, _, _, _, _ in
                guard let ctx else { return }
                let mgr = Unmanaged<ConfigManager>.fromOpaque(ctx).takeUnretainedValue()
                // Debounce — wait for the editor to finish writing.
                // [weak mgr] ensures the block is a no-op if ConfigManager is freed in this window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak mgr] in
                    mgr?.load()
                    mgr?.onChanged?()
                }
            },
            &ctx,
            [CONFIG_DIR.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )

        if let stream = fsStream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }
}
