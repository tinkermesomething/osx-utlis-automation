import AppKit
import Carbon.HIToolbox
import IOKit
import IOKit.usb
import UniformTypeIdentifiers

final class WelcomeWindowController: NSWindowController {

    private let configManager:  ConfigManager
    private let moduleRegistry: ModuleRegistry

    var onCompleted: (() -> Void)?

    // MARK: - Step management

    private enum Step { case modules, keyboard, dock }
    private var steps:     [Step] = [.modules]
    private var stepIndex: Int    = 0

    // MARK: - Shared UI

    private var contentContainer: NSView!
    private var backButton:        NSButton!
    private var nextButton:        NSButton!
    private var stepLabel:         NSTextField!

    // MARK: - Module step

    private var checkboxes: [NSButton] = []

    // MARK: - Keyboard step

    private var macPopup:         NSPopUpButton!
    private var pcPopup:          NSPopUpButton!
    private var availableLayouts: [String] = []

    // MARK: - Dock step

    private var dockDeviceLabel:  NSTextField!
    private var dockAppLabel:     NSTextField!
    private var dockDetectButton: NSButton!
    private var detectPort:       IONotificationPortRef?
    private var detectIter:       io_iterator_t = 0
    private var detectCtx:        UnsafeMutableRawPointer?
    private var detectTimeout:    DispatchWorkItem?

    // MARK: - Init

    init(configManager: ConfigManager, moduleRegistry: ModuleRegistry) {
        self.configManager  = configManager
        self.moduleRegistry = moduleRegistry
        super.init(window: nil)
        buildWindow()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Window scaffold

    private func buildWindow() {
        let w = NSWindow(
            contentRect: .zero,
            styleMask:   [.titled],
            backing:     .buffered,
            defer:       false
        )
        w.title                = "Welcome to osx-utils-automation"
        w.isReleasedWhenClosed = false

        let content = w.contentView!

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let divider         = NSBox()
        divider.boxType     = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        stepLabel = makeLabel("", bold: false)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.translatesAutoresizingMaskIntoConstraints = false

        backButton = NSButton(title: "Back", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton = NSButton(title: "Next", target: self, action: #selector(nextTapped))
        nextButton.bezelStyle     = .rounded
        nextButton.keyEquivalent  = "\r"
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        for sub in ([contentContainer, divider, stepLabel, backButton, nextButton] as [NSView]) {
            content.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: content.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            divider.topAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            stepLabel.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            stepLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            backButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            backButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            backButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            nextButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            nextButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])

        self.window = w
        showStep(0)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Step routing

    private func showStep(_ index: Int) {
        stepIndex = index
        let step  = steps[index]

        // Swap content
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let stepView: NSView
        switch step {
        case .modules:  stepView = makeModulesView()
        case .keyboard: stepView = makeKeyboardView()
        case .dock:     stepView = makeDockView()
        }
        stepView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stepView)
        NSLayoutConstraint.activate([
            stepView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            stepView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            stepView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            stepView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        // Nav state
        backButton.isHidden = (index == 0)
        let isLast = (index == steps.count - 1)
        nextButton.title        = isLast ? "Get Started" : "Next"
        nextButton.keyEquivalent = "\r"

        // Step indicator — hidden on step 0 (module selection)
        if steps.count > 1 && index > 0 {
            stepLabel.stringValue = "Step \(index) of \(steps.count - 1)"
        } else {
            stepLabel.stringValue = ""
        }

        // Resize window to fit new content
        window?.contentView?.layoutSubtreeIfNeeded()
        if let size = window?.contentView?.fittingSize {
            window?.setContentSize(size)
        }
        window?.center()
    }

    // MARK: - Navigation

    @objc private func backTapped() {
        stopDockDetection()
        showStep(stepIndex - 1)
    }

    @objc private func nextTapped() {
        stopDockDetection()
        switch steps[stepIndex] {
        case .modules:
            commitModuleSelection()
            buildRemainingSteps()
            if steps.count > 1 {
                showStep(1)
            } else {
                complete()
            }
        case .keyboard:
            commitKeyboardLayouts()
            advance()
        case .dock:
            advance()   // dock config already saved live via configManager mutators
        }
    }

    private func advance() {
        if stepIndex < steps.count - 1 {
            showStep(stepIndex + 1)
        } else {
            complete()
        }
    }

    private func complete() {
        window?.close()
        onCompleted?()
    }

    // MARK: - Module selection

    private func commitModuleSelection() {
        let selected = checkboxes
            .filter { $0.state == .on }
            .map    { ModuleRegistry.available[$0.tag].id }
        configManager.setRegisteredModules(selected)
    }

    private func buildRemainingSteps() {
        let selected = checkboxes.filter { $0.state == .on }.map { ModuleRegistry.available[$0.tag].id }
        steps = [.modules]
        if selected.contains("keyboard-switcher") { steps.append(.keyboard) }
        if selected.contains("dock-watcher")      { steps.append(.dock)     }
    }

    private func makeModulesView() -> NSView {
        let iconView          = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive  = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let titleLabel    = NSTextField(labelWithString: "Welcome!")
        titleLabel.font   = .boldSystemFont(ofSize: 18)
        titleLabel.alignment = .center

        let subtitleLabel      = NSTextField(wrappingLabelWithString:
            "Choose which automations to enable. You can change this any time in Settings."
        )
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        checkboxes.removeAll()
        var moduleRows: [NSView] = []
        for (idx, desc) in ModuleRegistry.available.enumerated() {
            let checkbox   = NSButton(checkboxWithTitle: desc.displayName, target: nil, action: nil)
            checkbox.state = .on
            checkbox.tag   = idx

            let descLabel       = NSTextField(wrappingLabelWithString: desc.description)
            descLabel.textColor = .secondaryLabelColor
            descLabel.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)

            let row         = NSStackView(views: [checkbox, descLabel])
            row.orientation = .vertical
            row.alignment   = .leading
            row.spacing     = 3
            moduleRows.append(row)
            checkboxes.append(checkbox)
        }

        let stack         = NSStackView(views: [iconView, titleLabel, subtitleLabel] + moduleRows)
        stack.orientation = .vertical
        stack.alignment   = .centerX
        stack.spacing     = 12
        stack.edgeInsets  = NSEdgeInsets(top: 32, left: 32, bottom: 28, right: 32)

        // Module rows left-aligned within centred stack
        for row in moduleRows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                       constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                             constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        return stack
    }

    // MARK: - Keyboard setup

    private func makeKeyboardView() -> NSView {
        let header = NSTextField(labelWithString: "Keyboard Layout")
        header.font = .boldSystemFont(ofSize: 15)

        let body = NSTextField(wrappingLabelWithString:
            "The app switches your input layout automatically based on which keyboard is active. " +
            "Confirm the detected layouts below, or choose manually."
        )
        body.textColor = .secondaryLabelColor
        body.font      = .systemFont(ofSize: NSFont.systemFontSize)

        let divider         = NSBox()
        divider.boxType     = .separator

        let macLabel        = makeLabel("Mac / built-in:", bold: false)
        macLabel.alignment  = .right
        macLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

        macPopup        = NSPopUpButton()
        macPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let macRow          = NSStackView(views: [macLabel, macPopup])
        macRow.orientation  = .horizontal
        macRow.spacing      = 8

        let pcLabel         = makeLabel("External keyboard:", bold: false)
        pcLabel.alignment   = .right
        pcLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

        pcPopup        = NSPopUpButton()
        pcPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pcRow          = NSStackView(views: [pcLabel, pcPopup])
        pcRow.orientation  = .horizontal
        pcRow.spacing      = 8

        let permNote = NSTextField(wrappingLabelWithString:
            "After setup completes, macOS will prompt for Input Monitoring permission. " +
            "This is required for keyboard detection — grant it in System Settings > Privacy & Security."
        )
        permNote.textColor = .secondaryLabelColor
        permNote.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack         = NSStackView(views: [header, body, divider, macRow, pcRow, permNote])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 14
        stack.edgeInsets  = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        for v in ([divider, macRow, pcRow, body, permNote] as [NSView]) {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                     constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }

        populateKeyboardPopups()
        return stack
    }

    private func populateKeyboardPopups() {
        guard macPopup != nil else { return }
        availableLayouts = fetchLayouts()
        let short = availableLayouts.map { shortLayoutName($0) }
        for popup in [macPopup!, pcPopup!] {
            popup.removeAllItems()
            popup.addItems(withTitles: short)
        }

        let cfg = configManager.config.keyboardSwitcher
        // Use saved config if present, otherwise auto-detect
        if let mac = cfg.macLayout, let idx = availableLayouts.firstIndex(of: mac) {
            macPopup.selectItem(at: idx)
        }
        if let pc = cfg.pcLayout, let idx = availableLayouts.firstIndex(of: pc) {
            pcPopup.selectItem(at: idx)
        }
        if cfg.macLayout == nil || cfg.pcLayout == nil, let detected = autoDetectLayouts() {
            if let idx = availableLayouts.firstIndex(of: detected.mac) { macPopup.selectItem(at: idx) }
            if let idx = availableLayouts.firstIndex(of: detected.pc)  { pcPopup.selectItem(at: idx) }
        }
    }

    private func commitKeyboardLayouts() {
        let mi = macPopup.indexOfSelectedItem
        let pi = pcPopup.indexOfSelectedItem
        guard mi >= 0, pi >= 0,
              mi < availableLayouts.count, pi < availableLayouts.count else { return }
        configManager.setKeyboardLayouts(mac: availableLayouts[mi], pc: availableLayouts[pi])
    }

    private func fetchLayouts() -> [String] {
        guard let listRef = TISCreateInputSourceList(nil, false) else { return [] }
        let sources = listRef.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap { src -> String? in
            guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
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

    private func shortLayoutName(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    // MARK: - Dock setup

    private func makeDockView() -> NSView {
        let cfg = configManager.config.dockWatcher

        let header = NSTextField(labelWithString: "Dock Watcher")
        header.font = .boldSystemFont(ofSize: 15)

        let body = NSTextField(wrappingLabelWithString:
            "When your dock is connected, the selected app will launch automatically. " +
            "When disconnected, it will quit. You can change this any time in Settings."
        )
        body.textColor = .secondaryLabelColor
        body.font      = .systemFont(ofSize: NSFont.systemFontSize)

        let divider      = NSBox(); divider.boxType = .separator

        // Dock device row
        let deviceLabel   = makeLabel("Dock:", bold: false)
        deviceLabel.alignment = .right
        deviceLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        dockDeviceLabel = NSTextField(labelWithString: cfg.dockName ?? "Not detected yet")
        dockDeviceLabel.textColor = cfg.dockName != nil ? .labelColor : .secondaryLabelColor

        dockDetectButton = NSButton(title: "Detect Dock…", target: self, action: #selector(detectDockTapped))
        dockDetectButton.bezelStyle = .rounded

        let deviceRow         = NSStackView(views: [deviceLabel, dockDeviceLabel, dockDetectButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing     = 8
        deviceRow.alignment   = .centerY

        // App row
        let appLabel   = makeLabel("App:", bold: false)
        appLabel.alignment = .right
        appLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        dockAppLabel = NSTextField(labelWithString: cfg.appName ?? "Not selected yet")
        dockAppLabel.textColor = cfg.appName != nil ? .labelColor : .secondaryLabelColor

        let browseButton = NSButton(title: "Browse App…", target: self, action: #selector(browseAppTapped))
        browseButton.bezelStyle = .rounded

        let appRow         = NSStackView(views: [appLabel, dockAppLabel, browseButton])
        appRow.orientation = .horizontal
        appRow.spacing     = 8
        appRow.alignment   = .centerY

        let skipNote = NSTextField(labelWithString: "You can skip this and configure later in Settings.")
        skipNote.textColor = .secondaryLabelColor
        skipNote.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack         = NSStackView(views: [header, body, divider, deviceRow, appRow, skipNote])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 14
        stack.edgeInsets  = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

        for v in ([divider, deviceRow, appRow, body, skipNote] as [NSView]) {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                     constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        return stack
    }

    // MARK: - Dock detection (mirrors SettingsWindowController)

    @objc private func detectDockTapped() {
        dockDetectButton.isEnabled  = false
        dockDetectButton.title      = "Listening…"
        dockDeviceLabel.stringValue = "Plug in your dock now…"
        dockDeviceLabel.textColor   = .secondaryLabelColor

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            resetDetectButton(); return
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
                    last = svc; svc = IOIteratorNext(iter)
                }
                guard last != IO_OBJECT_NULL, let ctx else { return }
                Unmanaged<WelcomeWindowController>.fromOpaque(ctx)
                    .takeUnretainedValue().dockDeviceDetected(last)
                IOObjectRelease(last)
            },
            rawCtx, &detectIter
        )

        // Drain initial state — already-connected devices, not new
        var svc = IOIteratorNext(detectIter)
        while svc != IO_OBJECT_NULL { IOObjectRelease(svc); svc = IOIteratorNext(detectIter) }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopDockDetection()
            let saved = self.configManager.config.dockWatcher.dockName
            self.dockDeviceLabel.stringValue = saved ?? "Not detected yet"
            self.dockDeviceLabel.textColor   = saved != nil ? .labelColor : .secondaryLabelColor
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
            resetDetectButton(); return
        }

        var name = dict[kUSBProductString] as? String ?? ""
        if name.isEmpty {
            var buf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &buf)
            name = String(cString: buf)
        }
        if name.isEmpty { name = "USB Device \(vendorID):\(productID)" }

        stopDockDetection()
        configManager.setDockDevice(vendorID: vendorID, productID: productID, name: name)

        dockDeviceLabel.stringValue = name
        dockDeviceLabel.textColor   = .labelColor
        resetDetectButton()
    }

    private func stopDockDetection() {
        detectTimeout?.cancel(); detectTimeout = nil
        if let p = detectPort { IONotificationPortDestroy(p); detectPort = nil }
        if detectIter != IO_OBJECT_NULL { IOObjectRelease(detectIter); detectIter = IO_OBJECT_NULL }
        if let ctx = detectCtx {
            Unmanaged<WelcomeWindowController>.fromOpaque(ctx).release()
            detectCtx = nil
        }
    }

    private func resetDetectButton() {
        dockDetectButton?.isEnabled = true
        dockDetectButton?.title     = "Detect Dock…"
    }

    @objc private func browseAppTapped() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL            = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes     = [UTType.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.message                 = "Choose the app to launch when your dock is connected"
        panel.prompt                  = "Select"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let bundle   = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else { return }
            let name = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            self.configManager.setDockApp(bundleID: bundleID, name: name)
            self.dockAppLabel.stringValue = name
            self.dockAppLabel.textColor   = .labelColor
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ s: String, bold: Bool) -> NSTextField {
        let tf  = NSTextField(labelWithString: s)
        tf.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize)
                       : .systemFont(ofSize: NSFont.systemFontSize)
        return tf
    }
}
