import AppKit

// MARK: - Paths

let CONFIG_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/osx-utils-automation")

let CONFIG_URL = CONFIG_DIR.appendingPathComponent("config.json")

let LOG_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/osx-utils-automation.log")

// MARK: - Model

struct Config: Codable {
    var keyboardSwitcher = KeyboardSwitcherConfig()
    var dockWatcher      = DockWatcherConfig()

    struct KeyboardSwitcherConfig: Codable {
        var enabled: Bool
        var macLayout: String?
        var pcLayout:  String?

        init(enabled: Bool = true, macLayout: String? = nil, pcLayout: String? = nil) {
            self.enabled   = enabled
            self.macLayout = macLayout
            self.pcLayout  = pcLayout
        }

        init(from decoder: Decoder) throws {
            let c  = try decoder.container(keyedBy: CodingKeys.self)
            enabled   = try c.decodeIfPresent(Bool.self,   forKey: .enabled)   ?? true
            macLayout = try c.decodeIfPresent(String.self, forKey: .macLayout)
            pcLayout  = try c.decodeIfPresent(String.self, forKey: .pcLayout)
        }
    }

    struct DockWatcherConfig: Codable {
        var enabled: Bool

        init(enabled: Bool = true) { self.enabled = enabled }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboardSwitcher = try c.decodeIfPresent(KeyboardSwitcherConfig.self, forKey: .keyboardSwitcher) ?? KeyboardSwitcherConfig()
        dockWatcher      = try c.decodeIfPresent(DockWatcherConfig.self,      forKey: .dockWatcher)      ?? DockWatcherConfig()
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
        guard let data = try? enc.encode(config) else { return }
        try? data.write(to: CONFIG_URL)
    }

    func setEnabled(automationId: String, enabled: Bool) {
        switch automationId {
        case "keyboard-switcher": config.keyboardSwitcher.enabled = enabled
        case "dock-watcher":      config.dockWatcher.enabled      = enabled
        default: break
        }
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
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(version: 0, info: selfPtr, retain: nil, release: nil, copyDescription: nil)

        fsStream = FSEventStreamCreate(
            nil,
            { _, ctx, _, _, _, _ in
                guard let ctx else { return }
                let mgr = Unmanaged<ConfigManager>.fromOpaque(ctx).takeUnretainedValue()
                // Debounce — wait for the editor to finish writing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    mgr.load()
                    mgr.onChanged?()
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
