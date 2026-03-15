import AppKit

// MARK: - Status

enum AutomationStatus {
    case ok(String)       // all good
    case degraded(String) // enabled but something's wrong
    case disabled         // turned off by user
    case error(String)    // critical failure

    var displayString: String {
        switch self {
        case .ok(let msg):       return "● \(msg)"
        case .degraded(let msg): return "⚠ \(msg)"
        case .disabled:          return "○ Disabled"
        case .error(let msg):    return "✕ \(msg)"
        }
    }
}

// MARK: - Protocol

protocol Automation: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var status: AutomationStatus { get }
    var isEnabled: Bool { get }
    var onStatusChanged: (() -> Void)? { get set }

    /// Automation-specific menu items shown below the status line.
    var extraMenuItems: [NSMenuItem] { get }

    func start()
    func stop()
    func reloadConfig(from config: Config)
}

// MARK: - ClosureMenuItem

/// NSMenuItem that invokes a Swift closure — avoids needing @objc on automation classes.
final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, _ closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { closure() }
}
