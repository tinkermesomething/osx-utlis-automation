import AppKit
import IOBluetooth

// MARK: - UserModuleWizardController

final class UserModuleWizardController: NSWindowController {

    /// Called with the finished config when the user saves. nil = cancelled / deleted.
    var onSave:   ((UserModuleConfig) -> Void)?
    var onDelete: ((String) -> Void)?  // passes module ID

    private let configManager: ConfigManager
    // nil = creating a new module; non-nil = editing an existing one
    private var editing: UserModuleConfig?

    init(configManager: ConfigManager, editing: UserModuleConfig? = nil) {
        self.configManager = configManager
        self.editing       = editing
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window == nil { buildWindow() }
        loadEditingValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        goToStep(0)
    }

    // MARK: - Step management

    private var stepViews: [NSView] = []
    private var currentStep = 0

    private var backButton:  NSButton!
    private var nextButton:  NSButton!
    private var stepLabel:   NSTextField!
    private var contentBox:  NSView!

    // Step 0 — Name
    private var nameField: NSTextField!

    // Step 1 — Event type
    private var usbRadio:       NSButton!
    private var bluetoothRadio: NSButton!
    private var thunderboltRadio: NSButton!

    // Step 2 — Device picker
    private var deviceTable:       NSTableView!
    private var deviceTableScroll: NSScrollView!
    private var anyDeviceRow:      NSTableRowView?
    private var scannedUSBDevices:  [DiscoveredUSBDevice]             = []
    private var scannedBTDevices:   [DiscoveredBluetoothDevice]       = []
    private var selectedDeviceIndex: Int = 0  // 0 = "any device"
    private var devicePickerLabel: NSTextField!
    private var tbNoteLabel: NSTextField!

    // Step 3 — On-connect action
    private var connectActionSegment: NSSegmentedControl!
    private var connectAppField:      NSTextField!
    private var connectAppBrowse:     NSButton!
    private var connectScriptField:   NSTextField!
    private var connectScriptBrowse:  NSButton!
    private var connectAppBundleID:   String?
    private var connectAppName:       String?

    // Step 4 — On-disconnect action
    private var disconnectActionSegment: NSSegmentedControl!
    private var disconnectAppField:      NSTextField!
    private var disconnectAppBrowse:     NSButton!
    private var disconnectScriptField:   NSTextField!
    private var disconnectScriptBrowse:  NSButton!
    private var disconnectAppBundleID:   String?
    private var disconnectAppName:       String?

    // Step 5 — Notifications
    private var notifyConnectCheck:    NSButton!
    private var notifyDisconnectCheck: NSButton!

    // Step 6 — Review
    private var reviewLabel: NSTextField!

    // MARK: - Build

    private func buildWindow() {
        let w = NSWindow(
            contentRect: .zero,
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        w.title = "New Automation"
        w.isReleasedWhenClosed = false

        let content = w.contentView!

        // Step label (e.g. "Step 1 of 7")
        stepLabel = NSTextField(labelWithString: "")
        stepLabel.font = .systemFont(ofSize: 11)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stepLabel)

        // Content area — swapped out per step
        contentBox = NSView()
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentBox)

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        // Navigation buttons
        backButton = NSButton(title: "Back", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backButton)

        nextButton = NSButton(title: "Next", target: self, action: #selector(nextTapped))
        nextButton.bezelStyle    = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nextButton)

        // Delete button — only visible when editing
        if editing != nil {
            let deleteButton = NSButton(title: "Delete Module", target: self, action: #selector(deleteTapped))
            deleteButton.bezelStyle = .rounded
            deleteButton.contentTintColor = .systemRed
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(deleteButton)

            NSLayoutConstraint.activate([
                deleteButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
                deleteButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            ])
        }

        NSLayoutConstraint.activate([
            stepLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stepLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            contentBox.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 8),
            contentBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            contentBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            contentBox.heightAnchor.constraint(equalToConstant: 260),

            divider.topAnchor.constraint(equalTo: contentBox.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            nextButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nextButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            backButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),

            content.widthAnchor.constraint(equalToConstant: 460),
        ])

        stepViews = [
            buildStepName(),
            buildStepEventType(),
            buildStepDevice(),
            buildStepAction(isConnect: true),
            buildStepAction(isConnect: false),
            buildStepNotifications(),
            buildStepReview(),
        ]

        self.window = w
    }

    // MARK: - Step builders

    private func buildStepName() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Name your automation")
        v.addSubview(title)

        let sub = stepSubtitle("Give this module a short, descriptive name.")
        v.addSubview(sub)

        nameField = NSTextField()
        nameField.placeholderString = "e.g. Studio Monitor Launcher"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(nameField)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            nameField.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    private func buildStepEventType() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Choose hardware event type")
        v.addSubview(title)

        let sub = stepSubtitle("What kind of device triggers this automation?")
        v.addSubview(sub)

        usbRadio         = radioButton("USB device",         tag: 0, action: #selector(eventTypeChanged(_:)))
        bluetoothRadio   = radioButton("Bluetooth device",   tag: 1, action: #selector(eventTypeChanged(_:)))
        thunderboltRadio = radioButton("Thunderbolt device", tag: 2, action: #selector(eventTypeChanged(_:)))
        usbRadio.state   = .on

        [usbRadio, bluetoothRadio, thunderboltRadio].forEach { v.addSubview($0!) }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            usbRadio.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            usbRadio.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            bluetoothRadio.topAnchor.constraint(equalTo: usbRadio.bottomAnchor, constant: 8),
            bluetoothRadio.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            thunderboltRadio.topAnchor.constraint(equalTo: bluetoothRadio.bottomAnchor, constant: 8),
            thunderboltRadio.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        ])
        return v
    }

    private func buildStepDevice() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Select device")
        v.addSubview(title)

        devicePickerLabel = stepSubtitle("")
        v.addSubview(devicePickerLabel)

        // Thunderbolt note (shown instead of table)
        tbNoteLabel = NSTextField(wrappingLabelWithString:
            "Thunderbolt triggers fire whenever any Thunderbolt device connects or disconnects. " +
            "Specific device matching is not supported in this release.")
        tbNoteLabel.font = .systemFont(ofSize: 13)
        tbNoteLabel.textColor = .secondaryLabelColor
        tbNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        tbNoteLabel.isHidden = true
        v.addSubview(tbNoteLabel)

        // Device table
        deviceTable = NSTableView()
        deviceTable.headerView = nil
        deviceTable.rowHeight  = 22
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        col.title = "Device"
        deviceTable.addTableColumn(col)
        deviceTable.dataSource = self
        deviceTable.delegate   = self

        deviceTableScroll = NSScrollView()
        deviceTableScroll.documentView         = deviceTable
        deviceTableScroll.hasVerticalScroller  = true
        deviceTableScroll.autohidesScrollers   = true
        deviceTableScroll.borderType           = .bezelBorder
        deviceTableScroll.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(deviceTableScroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            devicePickerLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            devicePickerLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            deviceTableScroll.topAnchor.constraint(equalTo: devicePickerLabel.bottomAnchor, constant: 10),
            deviceTableScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            deviceTableScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            deviceTableScroll.heightAnchor.constraint(equalToConstant: 160),

            tbNoteLabel.topAnchor.constraint(equalTo: devicePickerLabel.bottomAnchor, constant: 12),
            tbNoteLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tbNoteLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    private func buildStepAction(isConnect: Bool) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let event = isConnect ? "connects" : "disconnects"
        let title = stepTitle("Action when device \(event)")
        v.addSubview(title)

        let sub = stepSubtitle("What should latch do when the device \(event)?")
        v.addSubview(sub)

        // Segment: None | Launch App | Quit App | Run Script
        let seg = NSSegmentedControl(
            labels: ["None", "Launch App", "Quit App", "Run Script"],
            trackingMode: .selectOne,
            target: self,
            action: isConnect ? #selector(connectActionChanged) : #selector(disconnectActionChanged)
        )
        seg.selectedSegment = 0
        seg.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(seg)
        if isConnect { connectActionSegment = seg } else { disconnectActionSegment = seg }

        // App row
        let appField = NSTextField()
        appField.isEditable   = false
        appField.isSelectable = false
        appField.placeholderString = "Choose an app…"
        appField.translatesAutoresizingMaskIntoConstraints = false
        appField.isHidden = true
        v.addSubview(appField)

        let appBrowse = NSButton(title: "Browse…", target: self,
                                 action: isConnect ? #selector(browseConnectApp) : #selector(browseDisconnectApp))
        appBrowse.bezelStyle = .rounded
        appBrowse.translatesAutoresizingMaskIntoConstraints = false
        appBrowse.isHidden = true
        v.addSubview(appBrowse)

        // Script row
        let scriptField = NSTextField()
        scriptField.isEditable   = false
        scriptField.isSelectable = true
        scriptField.placeholderString = "Choose a script…"
        scriptField.translatesAutoresizingMaskIntoConstraints = false
        scriptField.isHidden = true
        v.addSubview(scriptField)

        let scriptBrowse = NSButton(title: "Browse…", target: self,
                                    action: isConnect ? #selector(browseConnectScript) : #selector(browseDisconnectScript))
        scriptBrowse.bezelStyle = .rounded
        scriptBrowse.translatesAutoresizingMaskIntoConstraints = false
        scriptBrowse.isHidden = true
        v.addSubview(scriptBrowse)

        if isConnect {
            connectAppField = appField; connectAppBrowse = appBrowse
            connectScriptField = scriptField; connectScriptBrowse = scriptBrowse
        } else {
            disconnectAppField = appField; disconnectAppBrowse = appBrowse
            disconnectScriptField = scriptField; disconnectScriptBrowse = scriptBrowse
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            seg.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            seg.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            appField.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 14),
            appField.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            appField.trailingAnchor.constraint(equalTo: appBrowse.leadingAnchor, constant: -8),

            appBrowse.centerYAnchor.constraint(equalTo: appField.centerYAnchor),
            appBrowse.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            appBrowse.widthAnchor.constraint(equalToConstant: 80),

            scriptField.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 14),
            scriptField.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scriptField.trailingAnchor.constraint(equalTo: scriptBrowse.leadingAnchor, constant: -8),

            scriptBrowse.centerYAnchor.constraint(equalTo: scriptField.centerYAnchor),
            scriptBrowse.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scriptBrowse.widthAnchor.constraint(equalToConstant: 80),
        ])
        return v
    }

    private func buildStepNotifications() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Notifications")
        v.addSubview(title)

        let sub = stepSubtitle("Choose when latch should notify you.")
        v.addSubview(sub)

        notifyConnectCheck    = NSButton(checkboxWithTitle: "Notify when device connects",
                                         target: nil, action: nil)
        notifyDisconnectCheck = NSButton(checkboxWithTitle: "Notify when device disconnects",
                                          target: nil, action: nil)
        notifyConnectCheck.state    = .on
        notifyDisconnectCheck.state = .on
        notifyConnectCheck.translatesAutoresizingMaskIntoConstraints    = false
        notifyDisconnectCheck.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(notifyConnectCheck)
        v.addSubview(notifyDisconnectCheck)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            notifyConnectCheck.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            notifyConnectCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            notifyDisconnectCheck.topAnchor.constraint(equalTo: notifyConnectCheck.bottomAnchor, constant: 10),
            notifyDisconnectCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        ])
        return v
    }

    private func buildStepReview() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Review")
        v.addSubview(title)

        reviewLabel = NSTextField(wrappingLabelWithString: "")
        reviewLabel.font = .systemFont(ofSize: 13)
        reviewLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(reviewLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            reviewLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            reviewLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            reviewLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    // MARK: - Step navigation

    private func goToStep(_ step: Int) {
        currentStep = step

        // Swap content
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        let view = stepViews[step]
        contentBox.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentBox.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
        ])

        stepLabel.stringValue = "Step \(step + 1) of \(stepViews.count)"
        backButton.isHidden   = (step == 0)

        let isLast = step == stepViews.count - 1
        nextButton.title        = isLast ? "Save" : "Next"
        nextButton.keyEquivalent = "\r"

        // Step-specific prep
        if step == 2 { prepareDeviceStep() }
        if step == stepViews.count - 1 { updateReview() }

        window?.title = editing != nil ? "Edit Automation" : "New Automation"
    }

    @objc private func backTapped() {
        guard currentStep > 0 else { return }
        goToStep(currentStep - 1)
    }

    @objc private func nextTapped() {
        guard validate(step: currentStep) else { return }
        if currentStep == stepViews.count - 1 {
            save()
        } else {
            goToStep(currentStep + 1)
        }
    }

    // MARK: - Device step prep

    private func prepareDeviceStep() {
        let eventType = selectedEventType()
        selectedDeviceIndex = 0

        switch eventType {
        case .usb:
            deviceTableScroll.isHidden = false
            tbNoteLabel.isHidden       = true
            devicePickerLabel.stringValue = "Select a connected USB device, or choose \"Any USB device\"."
            scannedUSBDevices = DeviceScanner.connectedUSBDevices()
            scannedBTDevices  = []
            deviceTable.reloadData()
            // Pre-select the previously configured device if it's still connected
            var rowToSelect = 0
            if let vid = editing?.trigger.deviceVendorID,
               let pid = editing?.trigger.deviceProductID,
               let idx = scannedUSBDevices.firstIndex(where: { $0.vendorID == vid && $0.productID == pid }) {
                rowToSelect = idx + 1  // +1 for "Any device" sentinel row
            }
            selectedDeviceIndex = rowToSelect
            deviceTable.selectRowIndexes(IndexSet(integer: rowToSelect), byExtendingSelection: false)

        case .bluetooth:
            deviceTableScroll.isHidden = false
            tbNoteLabel.isHidden       = true
            devicePickerLabel.stringValue = "Select a paired Bluetooth device, or choose \"Any Bluetooth device\"."
            scannedBTDevices  = DeviceScanner.pairedBluetoothDevices()
            scannedUSBDevices = []
            deviceTable.reloadData()
            // Pre-select the previously configured device if it's still paired
            var rowToSelect = 0
            if let addr = editing?.trigger.bluetoothAddress,
               let idx = scannedBTDevices.firstIndex(where: { $0.address == addr }) {
                rowToSelect = idx + 1
            }
            selectedDeviceIndex = rowToSelect
            deviceTable.selectRowIndexes(IndexSet(integer: rowToSelect), byExtendingSelection: false)

        case .thunderbolt:
            deviceTableScroll.isHidden = true
            tbNoteLabel.isHidden       = false
            devicePickerLabel.stringValue = "Thunderbolt trigger"
        }
    }

    // MARK: - Action segment callbacks

    @objc private func connectActionChanged() {
        updateActionVisibility(segment: connectActionSegment,
                                appField: connectAppField, appBrowse: connectAppBrowse,
                                scriptField: connectScriptField, scriptBrowse: connectScriptBrowse)
    }

    @objc private func disconnectActionChanged() {
        updateActionVisibility(segment: disconnectActionSegment,
                                appField: disconnectAppField, appBrowse: disconnectAppBrowse,
                                scriptField: disconnectScriptField, scriptBrowse: disconnectScriptBrowse)
    }

    private func updateActionVisibility(segment: NSSegmentedControl,
                                         appField: NSTextField, appBrowse: NSButton,
                                         scriptField: NSTextField, scriptBrowse: NSButton) {
        let sel = segment.selectedSegment
        // 0=None, 1=Launch App, 2=Quit App, 3=Run Script
        let showApp    = sel == 1 || sel == 2
        let showScript = sel == 3
        appField.isHidden    = !showApp
        appBrowse.isHidden   = !showApp
        scriptField.isHidden = !showScript
        scriptBrowse.isHidden = !showScript
    }

    // MARK: - App / Script browse

    @objc private func browseConnectApp()      { browseApp(isConnect: true) }
    @objc private func browseDisconnectApp()   { browseApp(isConnect: false) }
    @objc private func browseConnectScript()   { browseScript(isConnect: true) }
    @objc private func browseDisconnectScript() { browseScript(isConnect: false) }

    private func browseApp(isConnect: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes  = [.applicationBundle]
        panel.directoryURL         = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let name     = url.deletingPathExtension().lastPathComponent
            let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
            if isConnect {
                self.connectAppBundleID  = bundleID
                self.connectAppName      = name
                self.connectAppField.stringValue = name
            } else {
                self.disconnectAppBundleID  = bundleID
                self.disconnectAppName      = name
                self.disconnectAppField.stringValue = name
            }
        }
    }

    private func browseScript(isConnect: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if isConnect {
                self.connectScriptField.stringValue = url.path
            } else {
                self.disconnectScriptField.stringValue = url.path
            }
        }
    }

    // MARK: - Validation

    private func validate(step: Int) -> Bool {
        switch step {
        case 0:
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                showError("Please enter a name for this automation.")
                return false
            }
            // Unique name check (allow same name when editing the same module)
            let existing = configManager.config.userModules
                .filter { $0.id != editing?.id }
                .map    { $0.name }
            if existing.contains(name) {
                showError("An automation named \"\(name)\" already exists. Choose a different name.")
                return false
            }
            return true

        case 3, 4:
            let isConnect = (step == 3)
            let segment   = isConnect ? connectActionSegment! : disconnectActionSegment!
            let sel       = segment.selectedSegment
            if sel == 1 || sel == 2 {
                let bundleID = isConnect ? connectAppBundleID : disconnectAppBundleID
                guard let bid = bundleID, !bid.isEmpty else {
                    showError("Please select an app.")
                    return false
                }
            } else if sel == 3 {
                let path = isConnect
                    ? connectScriptField.stringValue
                    : disconnectScriptField.stringValue
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                    showError("Script not found at the specified path.")
                    return false
                }
                guard access(path, X_OK) == 0 else {
                    showError("Script is not executable. Run: chmod +x \"\(path)\"")
                    return false
                }
            }
            return true

        default:
            return true
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText     = "Cannot continue"
        alert.informativeText = message
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w) }
    }

    // MARK: - Review text

    private func updateReview() {
        let eventType = selectedEventType()
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)

        let lines: [String] = [
            "Name:        \(name)",
            "Trigger:     \(eventType.rawValue.capitalized) — \(deviceDisplayName())",
            "On connect:  \(actionSummary(isConnect: true))",
            "On disconn:  \(actionSummary(isConnect: false))",
            "Notify:      \(notificationSummary())",
        ]
        reviewLabel.stringValue = lines.joined(separator: "\n")
    }

    private func deviceDisplayName() -> String {
        let eventType = selectedEventType()
        switch eventType {
        case .thunderbolt: return "Any Thunderbolt device"
        case .usb:
            if selectedDeviceIndex == 0 { return "Any USB device" }
            let idx = selectedDeviceIndex - 1
            guard idx < scannedUSBDevices.count else { return "Any USB device" }
            return scannedUSBDevices[idx].name
        case .bluetooth:
            if selectedDeviceIndex == 0 { return "Any Bluetooth device" }
            let idx = selectedDeviceIndex - 1
            guard idx < scannedBTDevices.count else { return "Any Bluetooth device" }
            return scannedBTDevices[idx].name
        }
    }

    private func actionSummary(isConnect: Bool) -> String {
        let seg = isConnect ? connectActionSegment! : disconnectActionSegment!
        switch seg.selectedSegment {
        case 0: return "None"
        case 1:
            let name = isConnect ? connectAppName : disconnectAppName
            return "Launch \(name ?? "app")"
        case 2:
            let name = isConnect ? connectAppName : disconnectAppName
            return "Quit \(name ?? "app")"
        case 3:
            let path = isConnect ? connectScriptField.stringValue : disconnectScriptField.stringValue
            return "Run \(URL(fileURLWithPath: path).lastPathComponent)"
        default: return "None"
        }
    }

    private func notificationSummary() -> String {
        let c = notifyConnectCheck.state == .on
        let d = notifyDisconnectCheck.state == .on
        if c && d  { return "Connect + Disconnect" }
        if c       { return "Connect only" }
        if d       { return "Disconnect only" }
        return "Off"
    }

    // MARK: - Save

    private func save() {
        let id = editing?.id ?? UUID().uuidString
        let eventType = selectedEventType()

        let trigger = buildTrigger(eventType: eventType)
        let onConnect    = buildAction(isConnect: true)
        let onDisconnect = buildAction(isConnect: false)

        let module = UserModuleConfig(
            id:                 id,
            name:               nameField.stringValue.trimmingCharacters(in: .whitespaces),
            enabled:            editing?.enabled ?? true,
            trigger:            trigger,
            onConnect:          onConnect,
            onDisconnect:       onDisconnect,
            notifyOnConnect:    notifyConnectCheck.state == .on,
            notifyOnDisconnect: notifyDisconnectCheck.state == .on
        )

        window?.close()
        onSave?(module)
    }

    private func buildTrigger(eventType: TriggerEventType) -> UserModuleTrigger {
        var vid:     Int?    = nil
        var pid:     Int?    = nil
        var btAddr:  String? = nil
        var devName: String  = "Any \(eventType.rawValue.capitalized) device"

        switch eventType {
        case .usb:
            if selectedDeviceIndex > 0 {
                let idx = selectedDeviceIndex - 1
                if idx < scannedUSBDevices.count {
                    let d = scannedUSBDevices[idx]
                    vid     = d.vendorID
                    pid     = d.productID
                    devName = d.name
                }
            }
        case .bluetooth:
            if selectedDeviceIndex > 0 {
                let idx = selectedDeviceIndex - 1
                if idx < scannedBTDevices.count {
                    let d = scannedBTDevices[idx]
                    btAddr  = d.address
                    devName = d.name
                }
            }
        case .thunderbolt:
            devName = "Any Thunderbolt device"
        }

        return UserModuleTrigger(
            eventType:        eventType,
            deviceVendorID:   vid,
            deviceProductID:  pid,
            bluetoothAddress: btAddr,
            deviceName:       devName
        )
    }

    private func buildAction(isConnect: Bool) -> UserModuleAction {
        let seg = isConnect ? connectActionSegment! : disconnectActionSegment!
        switch seg.selectedSegment {
        case 1:
            return UserModuleAction(
                kind:        .launchApp,
                appBundleID: isConnect ? connectAppBundleID : disconnectAppBundleID,
                appName:     isConnect ? connectAppName     : disconnectAppName
            )
        case 2:
            return UserModuleAction(
                kind:        .quitApp,
                appBundleID: isConnect ? connectAppBundleID : disconnectAppBundleID,
                appName:     isConnect ? connectAppName     : disconnectAppName
            )
        case 3:
            return UserModuleAction(
                kind:       .runScript,
                scriptPath: isConnect ? connectScriptField.stringValue : disconnectScriptField.stringValue
            )
        default:
            return .none
        }
    }

    // MARK: - Delete

    @objc private func deleteTapped() {
        guard let mod = editing else { return }
        let alert = NSAlert()
        alert.messageText     = "Delete \"\(mod.name)\"?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.window?.close()
                self?.onDelete?(mod.id)
            }
        }
    }

    // MARK: - Load editing values

    private func loadEditingValues() {
        guard let mod = editing else { return }

        nameField?.stringValue = mod.name

        switch mod.trigger.eventType {
        case .usb:         usbRadio?.state         = .on
        case .bluetooth:   bluetoothRadio?.state   = .on
        case .thunderbolt: thunderboltRadio?.state  = .on
        }

        loadActionValues(mod.onConnect, isConnect: true)
        loadActionValues(mod.onDisconnect, isConnect: false)

        notifyConnectCheck?.state    = mod.notifyOnConnect    ? .on : .off
        notifyDisconnectCheck?.state = mod.notifyOnDisconnect ? .on : .off
    }

    private func loadActionValues(_ action: UserModuleAction, isConnect: Bool) {
        let seg: NSSegmentedControl? = isConnect ? connectActionSegment : disconnectActionSegment
        switch action.kind {
        case .none:       seg?.selectedSegment = 0
        case .launchApp:
            seg?.selectedSegment = 1
            if isConnect { connectAppBundleID = action.appBundleID; connectAppName = action.appName
                           connectAppField?.stringValue = action.appName ?? "" }
            else         { disconnectAppBundleID = action.appBundleID; disconnectAppName = action.appName
                           disconnectAppField?.stringValue = action.appName ?? "" }
        case .quitApp:
            seg?.selectedSegment = 2
            if isConnect { connectAppBundleID = action.appBundleID; connectAppName = action.appName
                           connectAppField?.stringValue = action.appName ?? "" }
            else         { disconnectAppBundleID = action.appBundleID; disconnectAppName = action.appName
                           disconnectAppField?.stringValue = action.appName ?? "" }
        case .runScript:
            seg?.selectedSegment = 3
            if isConnect { connectScriptField?.stringValue    = action.scriptPath ?? "" }
            else         { disconnectScriptField?.stringValue = action.scriptPath ?? "" }
        }
        if let s = seg { updateActionVisibility(
            segment: s,
            appField:     isConnect ? connectAppField    : disconnectAppField,
            appBrowse:    isConnect ? connectAppBrowse   : disconnectAppBrowse,
            scriptField:  isConnect ? connectScriptField : disconnectScriptField,
            scriptBrowse: isConnect ? connectScriptBrowse : disconnectScriptBrowse
        )}
    }

    // MARK: - Helpers

    private func selectedEventType() -> TriggerEventType {
        if bluetoothRadio.state   == .on { return .bluetooth }
        if thunderboltRadio.state == .on { return .thunderbolt }
        return .usb
    }

    private func stepTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .boldSystemFont(ofSize: 14)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func stepSubtitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    @objc private func eventTypeChanged(_ sender: NSButton) {
        // Enforce mutual exclusion — AppKit doesn't auto-group standalone radio buttons
        usbRadio.state         = (sender === usbRadio)         ? .on : .off
        bluetoothRadio.state   = (sender === bluetoothRadio)   ? .on : .off
        thunderboltRadio.state = (sender === thunderboltRadio) ? .on : .off
    }

    private func radioButton(_ title: String, tag: Int, action: Selector) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: self, action: action)
        b.tag = tag
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension UserModuleWizardController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        let eventType = selectedEventType()
        switch eventType {
        case .usb:       return 1 + scannedUSBDevices.count   // row 0 = "Any USB device"
        case .bluetooth: return 1 + scannedBTDevices.count    // row 0 = "Any BT device"
        case .thunderbolt: return 0
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.translatesAutoresizingMaskIntoConstraints = false

        if row == 0 {
            let eventType = selectedEventType()
            switch eventType {
            case .usb:        cell.stringValue = "Any USB device"
            case .bluetooth:  cell.stringValue = "Any Bluetooth device"
            case .thunderbolt: cell.stringValue = ""
            }
            cell.textColor = .secondaryLabelColor
        } else {
            let eventType = selectedEventType()
            switch eventType {
            case .usb:
                let d = scannedUSBDevices[row - 1]
                cell.stringValue = "\(d.name)  (VID: 0x\(String(d.vendorID, radix: 16, uppercase: true)))"
            case .bluetooth:
                let d = scannedBTDevices[row - 1]
                cell.stringValue = "\(d.name)  (\(d.address))"
            case .thunderbolt:
                break
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedDeviceIndex = deviceTable.selectedRow
    }
}
