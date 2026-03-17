import AppKit
import Carbon.HIToolbox

final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let configManager: ConfigManager
    private let moduleRegistry: ModuleRegistry

    // Sidebar
    private var tableView:   NSTableView!
    private var selectedRow: Int = 0

    // Detail container
    private var detailContainer:   NSView!
    private var currentDetailView: NSView?

    // Keyboard panel — refs preserved across rebuilds so populateKeyboardPanel() can reach them
    private var autoDetectCheckbox:     NSButton!
    private var macLayoutPopup:         NSPopUpButton!
    private var pcLayoutPopup:          NSPopUpButton!
    private var bluetoothCheckbox:          NSButton!
    private var activeDetectionCheckbox:    NSButton!
    private var keyboardNotifCheckbox:      NSButton!
    private var dockNotifCheckbox:          NSButton!
    private var availableLayouts:           [String] = []

    private let sidebarTitles = [
        "General",
        "Modules",
        "Keyboard Layout",
        "Dock Watcher",
    ]

    /// Set by AppDelegate — called when user clicks "Check for Updates" in General tab.
    var onCheckForUpdates: (() -> Void)?

    init(configManager: ConfigManager, moduleRegistry: ModuleRegistry) {
        self.configManager  = configManager
        self.moduleRegistry = moduleRegistry
        super.init()
    }

    func showWindow() {
        if window == nil { buildWindow() } else { selectRow(selectedRow) }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window

    private func buildWindow() {
        let w = NSWindow(
            contentRect: .zero,
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        w.title                = "Settings — osx-utils-automation"
        w.delegate             = self
        w.isReleasedWhenClosed = false

        let content = w.contentView!

        let sidebarScroll = buildSidebarView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let divider         = NSBox()
        divider.boxType     = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        detailContainer     = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebarScroll)
        content.addSubview(divider)
        content.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 160),

            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            detailContainer.topAnchor.constraint(equalTo: content.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        self.window = w

        // Size the window to the keyboard panel (most content), so the window
        // adapts to the user's font size and control sizes — no hardcoded pixels.
        selectRow(2)
        content.layoutSubtreeIfNeeded()
        w.setContentSize(content.fittingSize)
        // Show default tab
        selectRow(0)
    }

    private func buildSidebarView() -> NSScrollView {
        let col            = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.isEditable     = false

        tableView          = NSTableView()
        tableView.addTableColumn(col)
        tableView.headerView              = nil
        tableView.rowHeight               = 32
        tableView.style = .sourceList
        tableView.backgroundColor         = NSColor.controlBackgroundColor
        tableView.dataSource              = self
        tableView.delegate                = self
        tableView.focusRingType           = .none
        tableView.intercellSpacing        = .zero

        let sv                     = NSScrollView()
        sv.documentView            = tableView
        sv.hasVerticalScroller     = false
        sv.hasHorizontalScroller   = false
        sv.drawsBackground         = false
        return sv
    }

    // MARK: - Detail switching

    private func selectRow(_ row: Int) {
        selectedRow = row
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let view: NSView
        switch row {
        case 0:  view = makeGeneralPanel()
        case 1:  view = makeModulesPanel()
        case 2:  view = makeKeyboardPanel()
        default: view = makeDockPanel()
        }

        currentDetailView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
        ])
        currentDetailView = view
    }

    // MARK: - General panel

    private func makeGeneralPanel() -> NSView {
        let loginCheckbox = NSButton(
            checkboxWithTitle: "Launch at Login",
            target: self, action: #selector(launchAtLoginToggled)
        )
        loginCheckbox.state = LaunchAtLogin.isEnabled() ? .on : .off

        let updateButton = NSButton(title: "Check for Updates...", target: self, action: #selector(checkForUpdatesTapped))
        updateButton.bezelStyle = .rounded

        let divider     = NSBox()
        divider.boxType = .separator

        let stack         = NSStackView(views: [loginCheckbox, divider, updateButton])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 16
        stack.edgeInsets  = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)

        // Divider must span full width despite .leading alignment
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    @objc private func checkForUpdatesTapped() {
        onCheckForUpdates?()
    }

    @objc private func dockNotifToggled(_ sender: NSButton) {
        configManager.setDockNotificationsEnabled(sender.state == .on)
    }

    @objc private func keyboardNotifToggled(_ sender: NSButton) {
        configManager.setKeyboardNotificationsEnabled(sender.state == .on)
    }

    @objc private func bluetoothToggled(_ sender: NSButton) {
        configManager.setBluetoothEnabled(sender.state == .on)
        configManager.onChanged?()
    }

    @objc private func activeDetectionToggled(_ sender: NSButton) {
        configManager.setActiveDetectionEnabled(sender.state == .on)
        configManager.onChanged?()
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        LaunchAtLogin.setEnabled(sender.state == .on)
    }

    // MARK: - Modules panel

    private func makeModulesPanel() -> NSView {
        let v = NSView()

        let header = makeLabel("Available Modules", bold: true)
        header.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 32),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32),
        ])

        // Checkbox icon + gap is ~18pt — indent description to align with checkbox title text
        let checkboxTitleOffset: CGFloat = 32 + 18

        var prevAnchor = header.bottomAnchor
        for (idx, desc) in ModuleRegistry.available.enumerated() {
            let isActive = moduleRegistry.active.contains(where: { $0.id == desc.id })

            let checkbox   = NSButton(checkboxWithTitle: desc.displayName, target: self, action: #selector(moduleToggled(_:)))
            checkbox.state = isActive ? .on : .off
            checkbox.tag   = idx
            checkbox.translatesAutoresizingMaskIntoConstraints = false

            let descLabel  = NSTextField(wrappingLabelWithString: desc.description)
            descLabel.textColor = .secondaryLabelColor
            descLabel.font      = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            descLabel.translatesAutoresizingMaskIntoConstraints = false

            v.addSubview(checkbox)
            v.addSubview(descLabel)
            NSLayoutConstraint.activate([
                checkbox.topAnchor.constraint(equalTo: prevAnchor, constant: idx == 0 ? 16 : 20),
                checkbox.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32),
                checkbox.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -32),

                descLabel.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 3),
                descLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: checkboxTitleOffset),
                descLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -32),
            ])
            prevAnchor = descLabel.bottomAnchor
        }

        return v
    }

    @objc private func moduleToggled(_ sender: NSButton) {
        let desc = ModuleRegistry.available[sender.tag]
        if sender.state == .on {
            moduleRegistry.activate(moduleId: desc.id)
        } else {
            moduleRegistry.deactivate(moduleId: desc.id)
        }
    }

    // MARK: - Keyboard panel (instant-apply)

    private func makeKeyboardPanel() -> NSView {
        let header = makeLabel("Keyboard Layout Switcher", bold: true)

        autoDetectCheckbox = NSButton(
            checkboxWithTitle: "Auto-detect from enabled input sources",
            target: self, action: #selector(autoDetectToggled)
        )

        let macLabel       = makeLabel("OSX layout:", bold: false)
        macLabel.alignment = .right
        macLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        macLayoutPopup        = NSPopUpButton()
        macLayoutPopup.target = self
        macLayoutPopup.action = #selector(layoutChanged)
        macLayoutPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let macRow          = NSStackView(views: [macLabel, macLayoutPopup])
        macRow.orientation  = .horizontal
        macRow.spacing      = 8

        let pcLabel            = makeLabel("External keyboard:", bold: false)
        pcLabel.alignment      = .right
        pcLabel.lineBreakMode  = .byWordWrapping
        pcLabel.maximumNumberOfLines = 2
        pcLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        pcLayoutPopup        = NSPopUpButton()
        pcLayoutPopup.target = self
        pcLayoutPopup.action = #selector(layoutChanged)
        pcLayoutPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pcRow          = NSStackView(views: [pcLabel, pcLayoutPopup])
        pcRow.orientation  = .horizontal
        pcRow.alignment    = .top
        pcRow.spacing      = 8

        bluetoothCheckbox = NSButton(
            checkboxWithTitle: "Include Bluetooth keyboards",
            target: self, action: #selector(bluetoothToggled)
        )

        activeDetectionCheckbox = NSButton(
            checkboxWithTitle: "Switch layout based on active keyboard",
            target: self, action: #selector(activeDetectionToggled)
        )
        activeDetectionCheckbox.toolTip = "Switches layout when you start typing on a different keyboard, even if both are connected"

        keyboardNotifCheckbox = NSButton(
            checkboxWithTitle: "Show notifications",
            target: self, action: #selector(keyboardNotifToggled)
        )

        let stack         = NSStackView(views: [header, autoDetectCheckbox, macRow, pcRow, bluetoothCheckbox, activeDetectionCheckbox, keyboardNotifCheckbox])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Rows must fill the stack width so the popup buttons can expand
        NSLayoutConstraint.activate([
            macRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pcRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // Minimum content width so fittingSize resolves correctly (greaterThanOrEqualTo
        // = floor only; large fonts still produce wider/taller results automatically).
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        // Wrapper provides 24pt padding on all sides
        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor,          constant:  32),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor,   constant:  32),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -32),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor,     constant: -32),
        ])

        populateKeyboardPanel()
        return wrapper
    }

    private func populateKeyboardPanel() {
        guard autoDetectCheckbox != nil else { return }

        availableLayouts = fetchAvailableLayouts()
        let shortNames   = availableLayouts.map { shortName($0) }

        for popup in [macLayoutPopup!, pcLayoutPopup!] {
            popup.removeAllItems()
            popup.addItems(withTitles: shortNames)
        }

        let cfg    = configManager.config.keyboardSwitcher
        let isAuto = cfg.macLayout == nil && cfg.pcLayout == nil
        autoDetectCheckbox.state      = isAuto ? .on : .off
        bluetoothCheckbox.state       = cfg.includeBluetooth ? .on : .off
        activeDetectionCheckbox.state = cfg.activeDetection  ? .on : .off
        keyboardNotifCheckbox.state   = cfg.notifications    ? .on : .off

        if !isAuto {
            if let mac = cfg.macLayout, let idx = availableLayouts.firstIndex(of: mac) { macLayoutPopup.selectItem(at: idx) }
            if let pc  = cfg.pcLayout,  let idx = availableLayouts.firstIndex(of: pc)  { pcLayoutPopup.selectItem(at: idx)  }
        } else if let detected = autoDetectLayouts() {
            if let idx = availableLayouts.firstIndex(of: detected.mac) { macLayoutPopup.selectItem(at: idx) }
            if let idx = availableLayouts.firstIndex(of: detected.pc)  { pcLayoutPopup.selectItem(at: idx)  }
        }

        setLayoutControlsEnabled(!isAuto)
    }

    @objc private func autoDetectToggled(_ sender: NSButton) {
        let isAuto = sender.state == .on
        setLayoutControlsEnabled(!isAuto)
        if isAuto {
            configManager.setKeyboardLayouts(mac: nil, pc: nil)
        } else {
            saveLayoutsFromPopups()
        }
        configManager.onChanged?()
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        guard autoDetectCheckbox?.state == .off else { return }
        saveLayoutsFromPopups()
        configManager.onChanged?()
    }

    private func saveLayoutsFromPopups() {
        let selMac = macLayoutPopup.indexOfSelectedItem
        let selPc  = pcLayoutPopup.indexOfSelectedItem
        guard selMac >= 0, selPc >= 0,
              selMac < availableLayouts.count, selPc < availableLayouts.count else { return }
        configManager.setKeyboardLayouts(mac: availableLayouts[selMac], pc: availableLayouts[selPc])
    }

    private func setLayoutControlsEnabled(_ enabled: Bool) {
        macLayoutPopup?.isEnabled = enabled
        pcLayoutPopup?.isEnabled  = enabled
    }

    // MARK: - Dock panel

    private func makeDockPanel() -> NSView {
        let header = makeLabel("DisplayLink Dock Watcher", bold: true)

        // Live status from the active automation instance
        let statusText: String
        if let dock = moduleRegistry.active.first(where: { $0.id == "dock-watcher" }) {
            statusText = dock.status.displayString
        } else {
            statusText = "Module not active"
        }
        let statusLabel       = makeLabel(statusText, bold: false)
        statusLabel.textColor = .secondaryLabelColor

        let divider         = NSBox()
        divider.boxType     = .separator

        let body            = NSTextField(wrappingLabelWithString:
            "Launches DisplayLink Manager when a Dell D6000 dock is connected, and quits it on disconnect."
        )
        body.textColor      = .secondaryLabelColor
        body.font           = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        dockNotifCheckbox = NSButton(
            checkboxWithTitle: "Show notifications",
            target: self, action: #selector(dockNotifToggled)
        )
        dockNotifCheckbox.state = configManager.config.dockWatcher.notifications ? .on : .off

        let v = NSView()
        for sub in [header, statusLabel, divider, body, dockNotifCheckbox] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 32),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32),

            statusLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32),

            divider.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            body.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -32),

            dockNotifCheckbox.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 12),
            dockNotifCheckbox.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32),
        ])
        return v
    }

    // MARK: - Layout helpers

    private func fetchAvailableLayouts() -> [String] {
        guard let listRef = TISCreateInputSourceList(nil, false) else { return [] }
        let sources = listRef.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap { source -> String? in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            return id.hasPrefix("com.apple.keylayout.") ? id : nil
        }.sorted()
    }

    private func autoDetectLayouts() -> (mac: String, pc: String)? {
        guard let pc = availableLayouts.first(where: { $0.hasSuffix("-PC") }) else { return nil }
        let base = pc.replacingOccurrences(of: "-PC", with: "")
        let mac  = availableLayouts.first(where: { $0 == base })
                ?? availableLayouts.first(where: { !$0.hasSuffix("-PC") })
        guard let mac else { return nil }
        return (mac: mac, pc: pc)
    }

    private func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    private func makeLabel(_ title: String, bold: Bool) -> NSTextField {
        let tf   = NSTextField(labelWithString: title)
        tf.font  = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return tf
    }

    func windowWillClose(_ notification: Notification) {}
}

// MARK: - NSTableViewDataSource / Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarTitles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let tf   = NSTextField(labelWithString: sidebarTitles[row])
        tf.font  = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row != selectedRow else { return }
        selectRow(row)
    }
}
