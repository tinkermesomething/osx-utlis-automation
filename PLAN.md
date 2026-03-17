# osx-utils-automation — Build Plan

## Goal
A macOS menu bar app that hosts multiple automations (keyboard layout switcher, DisplayLink dock watcher) under a single status icon with enable/disable toggles, status display, manual overrides, and settings.

## Status
- [x] Project scaffold
- [x] Info.plist + app bundle build
- [x] Automation protocol
- [x] DockWatcher automation (port from osx-displaylink-watch)
- [x] KeyboardSwitcher automation (port from mac-keyboard-switch)
- [x] MenuBarController (icon, menu, status)
- [x] Config (load/save)
- [x] Install/uninstall scripts
- [x] README
- [x] End-to-end test (all scenarios)
- [x] Replace existing daemons
- [x] Native settings window
- [x] Launch at Login toggle
- [x] pkg installer + uninstaller
- [x] GitHub Actions release workflow
- [x] v1.0.0 released

---

## v1.0.1 — Bug Fix Release

Critical code review surfaced 13 real issues before v1.1.0 work began. Fixed here as a patch release. Each fix tested before the next begins.

### Fix 1 — Memory safety: use-after-free in FSEvents callback (Config.swift)
`Unmanaged.passUnretained(self)` in FSEventStreamCreate context. If ConfigManager is deallocated before the 0.5s debounce fires, callback dereferences dead memory.
**Fix:** Use `passRetained` + `release()` in deinit. Add `deinit` to stop/release the stream.

### Fix 2 — Memory safety: use-after-free in IOKit callbacks (DockWatcher.swift)
Same pattern — `passUnretained` passed as IOKit notification context. Callbacks can fire after DockWatcher is deallocated.
**Fix:** `passRetained` + `release()` in `stop()` / deinit.

### Fix 3 — Memory safety: use-after-free in IOHIDManager callbacks (KeyboardSwitcher.swift)
Same pattern — three IOHIDManager callbacks (connect, disconnect, input) all hold unretained self pointer.
**Fix:** `passRetained` + `release()` in `stop()` / deinit.

### Fix 4 — Resource leak: FSEventStream never stopped on app exit (Config.swift)
No `deinit` on ConfigManager — stream runs forever, never invalidated.
**Fix:** Add `deinit` that calls `FSEventStreamStop`, `FSEventStreamInvalidate`, `FSEventStreamRelease`.

### Fix 5 — Crash: unsafe force cast `as! [TISInputSource]` (KeyboardSwitcher.swift + SettingsWindowController.swift)
If TIS returns an unexpected type, the force cast crashes the app.
**Fix:** Replace with `as? [TISInputSource] ?? []`.

### Fix 6 — Data loss: silent failure on config save (Config.swift)
`try? data.write(to:)` swallows errors silently. User believes settings saved; they weren't.
**Fix:** Log the error on failure and update status to `.degraded` so the icon reflects the problem.

### Fix 7 — Data corruption: non-atomic config write (Config.swift)
Direct write to `config.json` — if interrupted, file is partially written and unreadable.
**Fix:** Write to a temp file first, then `FileManager.moveItem` (atomic rename).

### Fix 8 — Auto Layout: hardcoded pixel frames in About window (AboutWindowController.swift)
All subviews use absolute `NSRect` frames. Breaks immediately under macOS Larger Text accessibility setting — text clips, controls overlap.
**Fix:** Rewrite using NSStackView + Auto Layout constraints. Establish this as the pattern for all future windows.

### Fix 9 — Auto Layout: hardcoded pixel frames in Settings window (SettingsWindowController.swift)
Same issue — fixed 380×210 window, all controls at hardcoded Y positions.
**Fix:** Rewrite using NSStackView + Auto Layout. Window height becomes dynamic.

### Fix 10 — Wrong status after failed layout switch (KeyboardSwitcher.swift)
If `TISSelectInputSource` fails, status remains `.ok` — user sees wrong state.
**Fix:** Check return value; set status to `.degraded("Failed to switch layout")` on error.

### Fix 11 — Stuck dialog: silent return on settings save validation failure (SettingsWindowController.swift)
If popup index is out of bounds, `save()` returns without closing the window or showing feedback.
**Fix:** Show an NSAlert explaining the issue rather than silently failing.

### Fix 12 — Invalid PID: `Int32("")` returns 0 in displayLinkPID() (DockWatcher.swift)
If pgrep output is empty or unparseable, `Int32(...)` returns `nil` (handled) but the trimming logic could pass an empty string — result is ambiguous PID 0.
**Fix:** Explicitly guard against empty string before Int32 conversion.

### Fix 13 — SPM migration: replace raw swiftc with Swift Package Manager
No project file means SourceKit can't resolve cross-file types — LSP errors on every edit. New source files require manual updates to install.sh and package.sh.
**Fix:** Add `Package.swift`. Replace `swiftc` in install.sh and package.sh with `swift build -c release`. Source files auto-discovered.

---

### v1.0.1 fix order
1. Fix 13 (SPM) — do first; all subsequent edits get proper LSP feedback
2. Fixes 1–4 (memory safety + resource leak) — crash prevention
3. Fix 5 (force cast) — crash prevention
4. Fixes 6–7 (config integrity) — data safety
5. Fixes 8–9 (Auto Layout) — foundation for all future windows
6. Fixes 10–12 (error handling) — correctness

**By design / future scope (not fixed in v1.0.1):**
- Hardcoded D6000 vendor/product ID — intentional; configurable via wizard later
- Hardcoded DisplayLink app name — acceptable until settings allow override
- Bluetooth keyboards not supported — known limitation, future scope

---

## v1.1.0 Plan

Four features, tackled in this order — each tested and signed off before the next begins.

### Step 1 — About Window

**Goal:** polished small NSWindow (not NSAlert) with icon, version, one-liner, and repo link.

**New files:**
- `Sources/AboutWindowController.swift`

**Modified files:**
- `Sources/MenuBarController.swift` — add "About" ClosureMenuItem above "Settings"
- `Sources/AppDelegate.swift` — instantiate and hold AboutWindowController
- `install.sh` / `package.sh` — add new source file

**Design:**
- Fixed size ~320×200, titled, closable, not resizable
- App icon (from bundle) top-centre
- App name bold, version below it
- One-liner: "macOS menu bar utility for hardware-triggered automations"
- Hyperlink button opens GitHub repo in browser

---

### Step 2 — Module Registry

**Goal:** modules can be "registered" (appear in menu + settings) or "unregistered" (completely absent). Distinct from enabled/disabled — registered + not running vs not registered at all.

**New files:**
- `Sources/ModuleRegistry.swift`

**Modified files:**
- `Sources/Config.swift` — add `registeredModules: [String]` (default: all); new `setRegistered(moduleId:registered:)` mutator
- `Sources/AppDelegate.swift` — init registry; only instantiate automations listed in config
- `Sources/MenuBarController.swift` — menu built from registry, not hardcoded list

**Design:**
```
ModuleDescriptor {
    id: String
    displayName: String
    description: String
    make: (ConfigManager) -> any Automation
}

ModuleRegistry {
    static let available: [ModuleDescriptor]   // all known modules
    private(set) var active: [any Automation]  // instantiated from config.registeredModules
}
```

Built-in modules:
- `keyboard-switcher` — Keyboard Layout Switcher
- `dock-watcher` — DisplayLink Dock Watcher

Config default: both registered (no breaking change for existing users).
Unregistering: stops automation, removes from active list, saves config — menu rebuilds on next open.

---

### Step 3 — Settings Page Redesign

**Goal:** sidebar + detail panel (macOS-native); replaces current single-panel SettingsWindowController.

**Modified files:**
- `Sources/SettingsWindowController.swift` — full rewrite

**Layout:** NSSplitView (non-resizable sidebar 160px + detail pane)

**Sidebar sections:**
- **General** — Launch at Login toggle, update check frequency
- **Modules** — manage the module registry
- *(per registered module that has settings)* — e.g. "Keyboard Switcher"

**Detail panels:**
- `GeneralPane` — Launch at Login, update frequency (on launch / daily / never)
- `ModulesPane` — table of all available modules; each row: name, description, Add/Remove; registered modules also show Enable/Disable toggle
- `KeyboardSwitcherPane` — layout auto-detect + dropdowns (migrated from old settings)
- `DockWatcherPane` — "No configurable options" placeholder (ready for future)

---

### Step 4 — Update Mechanism

**Goal:** on launch, check GitHub releases API; if newer version(s) exist, surface in menu with version picker + changelog; download and open selected pkg in Installer.app.

**New files:**
- `Sources/UpdateChecker.swift`
- `Sources/UpdateWindowController.swift`

**Modified files:**
- `Sources/MenuBarController.swift` — "Check for Updates" item; badge if update available
- `Sources/AppDelegate.swift` — trigger check on launch (respecting frequency preference)
- `Sources/Config.swift` — add `skippedVersions: [String]`, `updateCheckFrequency: String`

**Design:**

`UpdateChecker`:
- Fetches `https://api.github.com/repos/tinkermesomething/osx-utils-automation/releases`
- Compares semver tags against current bundle version
- Returns `[ReleaseInfo]` for all versions newer than current (newest first)
- Filters skipped versions
- Background thread, callbacks on main

`UpdateWindowController` (~480×360):
- Left pane: NSTableView listing versions newer than current
- Right pane: changelog for selected version (NSScrollView + NSTextView)
- "Download & Install" — downloads selected `.pkg` to temp dir, opens with NSWorkspace (Installer.app handles admin prompt)
- "Skip this version" — adds to `skippedVersions` in config
- "Remind me later" / "Close"

---

## Architecture decisions

### App type
AppKit, `LSUIElement = YES` — menu bar only, no dock icon. Single binary via `swiftc`. LaunchAgent: `com.local.osx-utils-automation`.

### Extensibility
All automations implement the `Automation` protocol. ModuleRegistry drives what appears in the menu — no manual wiring when adding new modules.

### Config
Path: `~/.config/osx-utils-automation/config.json`. Reloaded automatically via FSEvents (500ms debounce).

### Logging
`~/Library/Logs/osx-utils-automation.log` via `NSLog`. "Open Logs" in menu opens Console.app.

---

## File structure

```
GITHUB/osx-utils-automation/
├── Sources/
│   ├── main.swift
│   ├── AppDelegate.swift
│   ├── MenuBarController.swift
│   ├── Config.swift
│   ├── AboutWindowController.swift       (v1.1.0 — step 1)
│   ├── ModuleRegistry.swift              (v1.1.0 — step 2)
│   ├── SettingsWindowController.swift    (v1.1.0 — step 3 rewrite)
│   ├── UpdateChecker.swift               (v1.1.0 — step 4)
│   ├── UpdateWindowController.swift      (v1.1.0 — step 4)
│   └── automations/
│       ├── Automation.swift
│       ├── KeyboardSwitcher.swift
│       └── DockWatcher.swift
├── Resources/
│   └── Info.plist
├── scripts/
│   ├── postinstall
│   └── uninstall
├── .github/workflows/release.yml
├── install.sh
├── package.sh
├── uninstall.sh
├── com.local.osx-utils-automation.plist
├── VERSION
├── .gitignore
├── PLAN.md
└── README.md
```

---

## Known risks

| Risk | Mitigation |
|---|---|
| Input Monitoring revoked on reinstall | Documented in README; shown in postinstall output |
| FSEvents fires before write complete | 500ms debounce |
| `TISSelectInputSource` from background thread | Always dispatch to main |
| GitHub API rate limit on update check | Cache last-checked timestamp; respect frequency preference |
| `.pkg` temp file cleaned up before Installer opens | Keep reference until app quits |

---

## Known decisions and deferred items

| Item | Decision | Action required |
|------|----------|-----------------|
| Unsigned app + Gatekeeper | Acceptable until Apple Developer account obtained. Users must right-click → Open on first install AND on each update pkg download. | Add note to every release changelog and update window UI. |
| v1.1.0 is a breaking change | Requires clean uninstall of v1.0.0 before installing. No migration of config. | Mark as breaking change in v1.1.0 release notes. |
| Repo name typo (`osx-utlis-automation`) | Renamed to `osx-utils-automation` on GitHub. Remote URL and all hardcoded references updated. | Done. |
| `Info.plist` version hardcoded | Update checker compares bundle version — `package.sh` must inject VERSION file value into `Info.plist` at build time. | Handle in Step 4 (Update Mechanism). |

---

## Future (post v1.1.0)

- **Custom automation wizard** — no-code UI for "if this then that" rules: triggers (USB connect, app launch, time, network) + actions (launch app, run script, toggle setting)
- Code signing + notarization

---

## v1.2.0 Plan — Bluetooth Keyboard Support + Active Keyboard Detection

### Background

`IOHIDManager` already receives Bluetooth keyboard events — the only blocker is the explicit `kIOHIDTransportKey == "USB"` filter in `isNonAppleUSBDevice()`. BT keyboards report `"Bluetooth"` or `"BluetoothLowEnergy"` for that key. Everything else (vendorID/productID, connect/disconnect callbacks, keypress learning) works identically.

---

### Feature 1 — Bluetooth keyboard support

**Goal:** opt-in support for Bluetooth keyboards alongside USB.

**Changes:**
- `Config.swift` — add `includeBluetooth: Bool = false` to `KeyboardSwitcherConfig`
- `KeyboardSwitcher.swift` — rename `isNonAppleUSBDevice` → `isTrackedExternalKeyboard`; expand transport check to include `"Bluetooth"` and `"BluetoothLowEnergy"` when `includeBluetooth` is enabled
- `SettingsWindowController.swift` — add "Include Bluetooth keyboards" checkbox to Keyboard Layout panel

**Key challenge — BT keyboards sleep:**
BT keyboards disconnect after inactivity and reconnect on first keypress. Without handling this, every sleep cycle triggers a spurious layout switch back to Mac layout.

**Fix:** add a 4-second debounce timer on disconnect. If the same device reconnects within the window, cancel the timer and treat it as a no-op. Only act on disconnect after the debounce expires.

**Apple BT keyboards (Magic Keyboard):**
Currently all Apple vendor IDs (0x05AC) are excluded. This is correct default behaviour — Magic Keyboard is an Apple device and most users don't want layout switching on it. Keep the Apple exclusion regardless of BT toggle.

**Testing note:** requires a physical BT keyboard to validate connect/disconnect/sleep/wake behaviour.

---

### Feature 2 — Active keyboard detection (smart switching)

**Goal:** instead of switching layout only on connect/disconnect, also switch when the *active typing keyboard* changes — even when both keyboards are connected simultaneously.

**Concept:** `IOHIDManagerRegisterInputValueCallback` already fires per device for every keypress. Track the last device that produced a keypress. When it changes to a different known keyboard type (external vs built-in), switch layout.

**Built-in keyboard:**
Currently excluded by `kIOHIDTransportKey == "USB"` + Apple vendor ID filter. Built-in MacBook keyboard is USB transport + Apple vendor internally. To detect "switched back to built-in", must explicitly track Apple USB keyboard events as a third category (not filtered, not treated as external).

**Config:** `activeDetection: Bool = false` — opt-in. Some users will find layout switching mid-session jarring; others will love it.

**Debounce:** switch only after N consecutive keypresses (suggested: 3) from the same device to avoid single accidental keypresses on the wrong keyboard triggering a switch.

**Interaction with connect/disconnect:**
Active detection is additive — connect/disconnect still switches layout. Active detection adds switching *during* a session when both keyboards are present.

**Settings panel addition:** "Switch layout based on active keyboard" checkbox (requires Bluetooth enabled if using a BT external keyboard).

---

### Implementation order

1. Feature 1 (BT support) — simpler, self-contained, testable with real hardware
2. Feature 2 (active detection) — builds on Feature 1's infrastructure; adds per-keypress tracking logic

---

### Risks

| Risk | Mitigation |
|------|------------|
| BT sleep/wake causing spurious switches | 1-second disconnect debounce with reconnect cancellation |
| Active detection switches on accidental keypresses | 1-keypress threshold (felt too slow at 3; matches USB behaviour) |
| Built-in keyboard tracking — Apple excludes its own keyboards from some HID APIs | Test and verify IOHIDManager visibility of built-in keyboard |
| BT behaviour varies across keyboard vendors | Test with available hardware; document known limitations |

---

## v1.2.0 Implementation Status

### ✅ Feature 1 — Bluetooth keyboard support
- `isTrackedExternalKeyboard` checks BT transport when `includeBluetooth` enabled
- Transport cached at connect time (`deviceTransports[id]`) — readable at disconnect
- 1s debounce on BT disconnect (sleep/wake resilience)
- Tested: connect, disconnect, sleep/wake all working

### ✅ Feature 2 — Active keyboard detection
- `IOHIDManagerRegisterInputValueCallback` per-device tracking
- `lastActiveRegistryID` + `activeKeypressThreshold = 1`
- Tested: switching between built-in and BT keyboard works

### ✅ Config changes
- `includeBluetooth: Bool = false`
- `activeDetection: Bool = false`
- `notifications: Bool = true` (both modules)
- All four settings exposed in SettingsWindowController

### ✅ Toast notifications
- `NotificationManager.swift` — `UNUserNotificationCenter` wrapper
- Per-module `notify()` helpers gated on config toggle
- `requestAuthorizationIfNeeded()` called in `applicationDidFinishLaunching`
- Root cause of denial: app was **unsigned** — `UNError Code=1` (notificationsNotAllowed)
- **Fix:** ad-hoc codesign (`codesign --sign - --force --deep`) added to `install.sh` and `scripts/postinstall`
- Also fixed: `CFBundlePackageType = APPL` added to Info.plist; `launchctl asuser` for proper session context
- Tested: notifications fire on keyboard connect/disconnect and dock events
