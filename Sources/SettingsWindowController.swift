import AppKit
import Carbon.HIToolbox
import IOKit
import IOKit.usb
import UniformTypeIdentifiers

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
    private var keyboardUSBNotifCheckbox:   NSButton!
    private var keyboardBTNotifCheckbox:    NSButton!
    private var dockNotifCheckbox:          NSButton!

    // Dock panel — live labels updated by detect/browse
    private var dockDeviceLabel:  NSTextField!
    private var dockAppLabel:     NSTextField!
    private var detectDockButton: NSButton!

    // Dock detection IOKit state
    private var detectPort:    IONotificationPortRef?
    private var detectIter:    io_iterator_t = 0
    private var detectCtx:     UnsafeMutableRawPointer?
    private var detectTimeout: DispatchWorkItem?
    private var availableLayouts:           [String] = []

    private enum SidebarItem: Equatable {
        case general, modules, keyboard, dock, notifications
        var title: String {
            switch self {
            case .general:       return "General"
            case .modules:       return "Modules"
            case .keyboard:      return "Keyboard Layout"
            case .dock:          return "Dock Watcher"
            case .notifications: return "Notifications"
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        let active = moduleRegistry.active
        var items: [SidebarItem] = [.general]
        // Notifications tab appears when at least one module with notification settings is active
        if active.contains(where: { $0.id == "keyboard-switcher" || $0.id == "dock-watcher" }) {
            items.append(.notifications)
        }
        items.append(.modules)
        if active.contains(where: { $0.id == "keyboard-switcher" }) { items.append(.keyboard) }
        if active.contains(where: { $0.id == "dock-watcher" })      { items.append(.dock) }
        return items
    }

    private var sidebarTitles: [String] { sidebarItems.map { $0.title } }

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
        w.title                = "Settings — latch"
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

        // Size the window to the most content-heavy registered panel so it adapts
        // to the user's font size and control sizes — no hardcoded pixels.
        let items = sidebarItems
        let sizingRow = items.lastIndex(of: .keyboard) ?? items.lastIndex(of: .dock) ?? 1
        selectRow(sizingRow)
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

        let items = sidebarItems
        let item  = row < items.count ? items[row] : .general
        let view: NSView
        switch item {
        case .general:       view = makeGeneralPanel()
        case .modules:       view = makeModulesPanel()
        case .keyboard:      view = makeKeyboardPanel()
        case .dock:          view = makeDockPanel()
        case .notifications: view = makeNotificationsPanel()
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

    @objc private func keyboardUSBNotifToggled(_ sender: NSButton) {
        configManager.setKeyboardUSBNotificationsEnabled(sender.state == .on)
    }

    @objc private func keyboardBTNotifToggled(_ sender: NSButton) {
        configManager.setKeyboardBluetoothNotificationsEnabled(sender.state == .on)
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
        // Rebuild sidebar — module tabs may appear or disappear
        tableView.reloadData()
        // If the currently-selected row no longer exists, fall back to Modules tab
        if selectedRow >= sidebarItems.count {
            selectRow(1)
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

        let stack         = NSStackView(views: [header, autoDetectCheckbox, macRow, pcRow, bluetoothCheckbox, activeDetectionCheckbox])
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
        autoDetectCheckbox.state     = isAuto ? .on : .off
        bluetoothCheckbox.state       = cfg.includeBluetooth ? .on : .off
        activeDetectionCheckbox.state = cfg.activeDetection  ? .on : .off

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
        let cfg = configManager.config.dockWatcher

        let header = makeLabel("Dock Watcher", bold: true)

        let statusText = moduleRegistry.active.first(where: { $0.id == "dock-watcher" })
            .map { $0.status.displayString } ?? "Module not active"
        let statusLabel       = makeLabel(statusText, bold: false)
        statusLabel.textColor = .secondaryLabelColor

        let descLabel = NSTextField(wrappingLabelWithString:
            "Watches for a USB dock. When connected, launches the selected app. When disconnected, quits it."
        )
        descLabel.textColor = .secondaryLabelColor
        descLabel.font      = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let divider1 = NSBox(); divider1.boxType = .separator

        // Dock device row
        let deviceSectionLabel = makeLabel("Dock Device", bold: true)
        deviceSectionLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        deviceSectionLabel.textColor = .secondaryLabelColor

        let deviceTitleLabel = makeLabel("Device:", bold: false)
        deviceTitleLabel.alignment = .right
        deviceTitleLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        dockDeviceLabel = NSTextField(labelWithString: cfg.dockName ?? "Not configured")
        dockDeviceLabel.textColor = cfg.dockName != nil ? .labelColor : .secondaryLabelColor

        detectDockButton = NSButton(title: "Detect Dock…", target: self, action: #selector(detectDockTapped))
        detectDockButton.bezelStyle = .rounded

        let deviceRow         = NSStackView(views: [deviceTitleLabel, dockDeviceLabel, detectDockButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing     = 8
        deviceRow.alignment   = .centerY

        let divider2 = NSBox(); divider2.boxType = .separator

        // App row
        let appSectionLabel = makeLabel("App", bold: true)
        appSectionLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        appSectionLabel.textColor = .secondaryLabelColor

        let appTitleLabel = makeLabel("App:", bold: false)
        appTitleLabel.alignment = .right
        appTitleLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        dockAppLabel = NSTextField(labelWithString: cfg.appName ?? "Not configured")
        dockAppLabel.textColor = cfg.appName != nil ? .labelColor : .secondaryLabelColor

        let browseButton = NSButton(title: "Browse App…", target: self, action: #selector(browseAppTapped))
        browseButton.bezelStyle = .rounded

        let appRow         = NSStackView(views: [appTitleLabel, dockAppLabel, browseButton])
        appRow.orientation = .horizontal
        appRow.spacing     = 8
        appRow.alignment   = .centerY

        let stack         = NSStackView(views: [header, statusLabel, descLabel, divider1,
                                                deviceSectionLabel, deviceRow,
                                                divider2,
                                                appSectionLabel, appRow])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        for v in ([divider1, divider2] as [NSView]) + [deviceRow, appRow, descLabel] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor,          constant:  32),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor,   constant:  32),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -32),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor,     constant: -32),
        ])
        return wrapper
    }

    // MARK: - Notifications panel

    private func makeNotificationsPanel() -> NSView {
        let header = makeLabel("Notifications", bold: true)

        var views: [NSView] = [header]
        let active = moduleRegistry.active

        if active.contains(where: { $0.id == "keyboard-switcher" }) {
            let sectionLabel = makeLabel("Keyboard Layout Switcher", bold: false)
            sectionLabel.font      = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            sectionLabel.textColor = .secondaryLabelColor

            keyboardUSBNotifCheckbox = NSButton(
                checkboxWithTitle: "USB keyboard connected / disconnected",
                target: self, action: #selector(keyboardUSBNotifToggled)
            )
            keyboardUSBNotifCheckbox.state = configManager.config.keyboardSwitcher.notifyUSB ? .on : .off

            keyboardBTNotifCheckbox = NSButton(
                checkboxWithTitle: "Bluetooth keyboard connected / disconnected",
                target: self, action: #selector(keyboardBTNotifToggled)
            )
            keyboardBTNotifCheckbox.state = configManager.config.keyboardSwitcher.notifyBluetooth ? .on : .off

            let divider = NSBox(); divider.boxType = .separator
            views += [divider, sectionLabel, keyboardUSBNotifCheckbox, keyboardBTNotifCheckbox]
        }

        if active.contains(where: { $0.id == "dock-watcher" }) {
            let sectionLabel = makeLabel("Dock Watcher", bold: false)
            sectionLabel.font      = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            sectionLabel.textColor = .secondaryLabelColor

            dockNotifCheckbox = NSButton(
                checkboxWithTitle: "Dock connected / disconnected",
                target: self, action: #selector(dockNotifToggled)
            )
            dockNotifCheckbox.state = configManager.config.dockWatcher.notifications ? .on : .off

            let divider = NSBox(); divider.boxType = .separator
            views += [divider, sectionLabel, dockNotifCheckbox]
        }

        let stack         = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        // Dividers span full width
        for v in views where (v as? NSBox)?.boxType == .separator {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor,          constant:  32),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor,   constant:  32),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -32),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor,     constant: -32),
        ])
        return wrapper
    }

    // MARK: - Dock detection

    @objc private func detectDockTapped() {
        detectDockButton.isEnabled = false
        detectDockButton.title     = "Listening…"
        dockDeviceLabel.stringValue = "Plug in your dock now…"
        dockDeviceLabel.textColor   = .secondaryLabelColor

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            resetDetectButton()
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
        detectPort = port

        let rawCtx = Unmanaged.passRetained(self).toOpaque()
        detectCtx  = rawCtx

        let dict = IOServiceMatching(kIOUSBDeviceClassName)! as NSMutableDictionary
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, dict as CFMutableDictionary,
            { ctx, iter in
                var svc  = IOIteratorNext(iter)
                var last: io_object_t = IO_OBJECT_NULL
                while svc != IO_OBJECT_NULL {
                    if last != IO_OBJECT_NULL { IOObjectRelease(last) }
                    last = svc
                    svc  = IOIteratorNext(iter)
                }
                guard last != IO_OBJECT_NULL, let ctx else { return }
                Unmanaged<SettingsWindowController>.fromOpaque(ctx)
                    .takeUnretainedValue().dockDeviceDetected(last)
                IOObjectRelease(last)
            },
            rawCtx, &detectIter
        )

        // Drain initial state — already-connected devices, not new ones
        var svc = IOIteratorNext(detectIter)
        while svc != IO_OBJECT_NULL { IOObjectRelease(svc); svc = IOIteratorNext(detectIter) }

        // 10s timeout
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopDockDetection()
            self.dockDeviceLabel.stringValue = self.configManager.config.dockWatcher.dockName ?? "Not configured"
            self.dockDeviceLabel.textColor   = self.configManager.config.dockWatcher.dockName != nil ? .labelColor : .secondaryLabelColor
            self.resetDetectButton()
        }
        detectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func dockDeviceDetected(_ service: io_object_t) {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict      = props?.takeRetainedValue() as? [String: Any],
              let vendorID  = (dict[kUSBVendorID]  as? NSNumber)?.intValue ?? dict[kUSBVendorID]  as? Int,
              let productID = (dict[kUSBProductID] as? NSNumber)?.intValue ?? dict[kUSBProductID] as? Int
        else {
            stopDockDetection()
            dockDeviceLabel.stringValue = "Could not read device — try again"
            resetDetectButton()
            return
        }

        // Prefer USB product name string; fall back to IORegistry entry name
        var name = dict[kUSBProductString] as? String ?? ""
        if name.isEmpty {
            var buf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &buf)
            name = String(cString: buf)
        }
        if name.isEmpty { name = "USB Device \(vendorID):\(productID)" }

        stopDockDetection()
        log("DockWatcher detect: '\(name)' VID=\(vendorID) PID=\(productID)")
        configManager.setDockDevice(vendorID: vendorID, productID: productID, name: name)
        configManager.onChanged?()

        dockDeviceLabel.stringValue = name
        dockDeviceLabel.textColor   = .labelColor
        resetDetectButton()
    }

    private func stopDockDetection() {
        detectTimeout?.cancel(); detectTimeout = nil
        if let p = detectPort { IONotificationPortDestroy(p); detectPort = nil }
        if detectIter != IO_OBJECT_NULL { IOObjectRelease(detectIter); detectIter = IO_OBJECT_NULL }
        if let ctx = detectCtx {
            Unmanaged<SettingsWindowController>.fromOpaque(ctx).release()
            detectCtx = nil
        }
    }

    private func resetDetectButton() {
        detectDockButton?.isEnabled = true
        detectDockButton?.title     = "Detect Dock…"
    }

    // MARK: - App browse

    @objc private func browseAppTapped() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL          = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes   = [UTType.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories  = false
        panel.canChooseFiles        = true   // .app bundles are packages, treated as files by NSOpenPanel
        panel.message               = "Choose the app to launch when your dock is connected"
        panel.prompt                = "Select"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let bundle    = Bundle(url: url),
                  let bundleID  = bundle.bundleIdentifier
            else {
                let alert = NSAlert()
                alert.messageText     = "Invalid app bundle"
                alert.informativeText = "The selected file does not appear to be a valid app."
                alert.alertStyle      = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            let name = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            self.configManager.setDockApp(bundleID: bundleID, name: name)
            self.configManager.onChanged?()
            self.dockAppLabel.stringValue = name
            self.dockAppLabel.textColor   = .labelColor
        }
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
