import AppKit
import Carbon.HIToolbox

final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let configManager: ConfigManager

    // Controls
    private var autoDetectCheckbox: NSButton!
    private var macLayoutPopup: NSPopUpButton!
    private var pcLayoutPopup:  NSPopUpButton!

    // All available layout IDs, in display order
    private var availableLayouts: [String] = []

    init(configManager: ConfigManager) {
        self.configManager = configManager
        super.init()
    }

    func showWindow() {
        if window == nil { buildWindow() }
        populateAndSync()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        w.title        = "osx-utils-automation — Settings"
        w.delegate     = self
        w.isReleasedWhenClosed = false

        let content = w.contentView!

        // ── Section header ──────────────────────────────────────────────
        let header = label("Keyboard Layout Switcher", bold: true)
        header.frame = NSRect(x: 20, y: 168, width: 340, height: 18)
        content.addSubview(header)

        let divider = NSBox()
        divider.boxType = .separator
        divider.frame   = NSRect(x: 20, y: 158, width: 340, height: 1)
        content.addSubview(divider)

        // ── Auto-detect checkbox ────────────────────────────────────────
        autoDetectCheckbox = NSButton(checkboxWithTitle: "Auto-detect from enabled input sources",
                                      target: self, action: #selector(autoDetectToggled))
        autoDetectCheckbox.frame = NSRect(x: 20, y: 130, width: 340, height: 20)
        content.addSubview(autoDetectCheckbox)

        // ── Mac layout row ──────────────────────────────────────────────
        let macLabel = label("Mac layout:")
        macLabel.frame = NSRect(x: 20, y: 98, width: 90, height: 20)
        macLabel.alignment = .right
        content.addSubview(macLabel)

        macLayoutPopup = NSPopUpButton(frame: NSRect(x: 118, y: 96, width: 240, height: 24))
        content.addSubview(macLayoutPopup)

        // ── PC layout row ───────────────────────────────────────────────
        let pcLabel = label("PC layout:")
        pcLabel.frame = NSRect(x: 20, y: 62, width: 90, height: 20)
        pcLabel.alignment = .right
        content.addSubview(pcLabel)

        pcLayoutPopup = NSPopUpButton(frame: NSRect(x: 118, y: 60, width: 240, height: 24))
        content.addSubview(pcLayoutPopup)

        // ── Buttons ─────────────────────────────────────────────────────
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.frame     = NSRect(x: 208, y: 16, width: 70, height: 28)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"  // Escape
        content.addSubview(cancelBtn)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.frame     = NSRect(x: 290, y: 16, width: 70, height: 28)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"        // Enter
        saveBtn.highlight(true)
        content.addSubview(saveBtn)

        self.window = w
    }

    // MARK: - Populate

    private func populateAndSync() {
        availableLayouts = fetchAvailableLayouts()
        let shortNames   = availableLayouts.map { shortName($0) }

        for popup in [macLayoutPopup, pcLayoutPopup] {
            popup!.removeAllItems()
            popup!.addItems(withTitles: shortNames)
        }

        let cfg       = configManager.config.keyboardSwitcher
        let isAuto    = cfg.macLayout == nil && cfg.pcLayout == nil
        autoDetectCheckbox.state = isAuto ? .on : .off

        if !isAuto {
            if let mac = cfg.macLayout, let idx = availableLayouts.firstIndex(of: mac) {
                macLayoutPopup.selectItem(at: idx)
            }
            if let pc = cfg.pcLayout, let idx = availableLayouts.firstIndex(of: pc) {
                pcLayoutPopup.selectItem(at: idx)
            }
        } else {
            // Auto-detect: pre-select what would be detected
            if let detected = autoDetect() {
                if let idx = availableLayouts.firstIndex(of: detected.mac) { macLayoutPopup.selectItem(at: idx) }
                if let idx = availableLayouts.firstIndex(of: detected.pc)  { pcLayoutPopup.selectItem(at: idx) }
            }
        }

        setLayoutControlsEnabled(!isAuto)
    }

    private func fetchAvailableLayouts() -> [String] {
        guard let listRef = TISCreateInputSourceList(nil, false) else { return [] }
        let sources = listRef.takeRetainedValue() as! [TISInputSource]
        return sources.compactMap { source -> String? in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            return id.hasPrefix("com.apple.keylayout.") ? id : nil
        }.sorted()
    }

    private func autoDetect() -> (mac: String, pc: String)? {
        guard let pc = availableLayouts.first(where: { $0.hasSuffix("-PC") }) else { return nil }
        let base = pc.replacingOccurrences(of: "-PC", with: "")
        let mac  = availableLayouts.first(where: { $0 == base })
                ?? availableLayouts.first(where: { !$0.hasSuffix("-PC") })
        guard let mac else { return nil }
        return (mac: mac, pc: pc)
    }

    // MARK: - Actions

    @objc private func autoDetectToggled(_ sender: NSButton) {
        setLayoutControlsEnabled(sender.state == .off)
    }

    @objc private func save() {
        let isAuto = autoDetectCheckbox.state == .on

        if isAuto {
            configManager.setKeyboardLayouts(mac: nil, pc: nil)
        } else {
            let selMac = macLayoutPopup.indexOfSelectedItem
            let selPc  = pcLayoutPopup.indexOfSelectedItem
            guard selMac >= 0, selPc >= 0,
                  selMac < availableLayouts.count, selPc < availableLayouts.count else { return }
            configManager.setKeyboardLayouts(
                mac: availableLayouts[selMac],
                pc:  availableLayouts[selPc]
            )
        }
        // Notify automations directly so they pick up the new layout immediately
        configManager.onChanged?()
        window?.close()
    }

    @objc private func cancel() { window?.close() }

    // MARK: - Helpers

    private func setLayoutControlsEnabled(_ enabled: Bool) {
        macLayoutPopup.isEnabled = enabled
        pcLayoutPopup.isEnabled  = enabled
    }

    private func label(_ title: String, bold: Bool = false) -> NSTextField {
        let tf = NSTextField(labelWithString: title)
        tf.font = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return tf
    }

    private func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    // NSWindowDelegate — nothing to do, just prevent dealloc on close
    func windowWillClose(_ notification: Notification) {}
}
