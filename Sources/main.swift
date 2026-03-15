import AppKit

// Global log function — all output goes to NSLog (captured by LaunchAgent stdout → log file)
func log(_ msg: String) { NSLog("osx-utils-automation: %@", msg) }

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no dock icon
app.run()
