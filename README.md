# osx-utils-automation

macOS has no built-in way to react to hardware events. Connecting a USB keyboard doesn't switch your input layout. Plugging in a dock doesn't launch the software it needs. You end up doing the same manual steps every time — switching layouts, launching DisplayLink, killing it when you unplug.

osx-utils-automation fixes that. It runs silently in the menu bar, watches for hardware changes, and handles the repetitive stuff automatically.

## Roadmap

The current automations are built-in, but the goal is to ship a **custom automation wizard** — a no-code UI that lets you build your own "if this, then that" rules without touching config files. Triggers will include USB device connect/disconnect, app launch, time of day, and network change. Actions will include launching apps, running scripts, and toggling system settings.

## Automations

### Keyboard Layout Switcher
Automatically switches the macOS keyboard input layout when a USB keyboard is connected or disconnected. Uses keypress learning to distinguish real keyboards from phantom HID services (e.g. Logitech Unifying Receiver).

### DisplayLink Dock Watcher
Automatically launches DisplayLink Manager when a Dell D6000 dock is connected and quits it when the dock is disconnected.

## Requirements

- macOS 13 or later
- [DisplayLink Manager](https://www.synaptics.com/products/displaylink-graphics/downloads/macos) installed (for the dock watcher)

## Installation

1. Download `osx-utils-automation-{version}.pkg` from the [latest release](../../releases/latest) and double-click to install.
2. Grant **Input Monitoring** permission when prompted — this is required for the keyboard switcher to detect keystrokes:
   `System Settings → Privacy & Security → Input Monitoring → add the app`

> **Note:** After each reinstall, macOS revokes Input Monitoring permission and you must re-grant it.

## Uninstallation

Download and run `osx-utils-automation-uninstaller-{version}.pkg` from the same release.

Then remove the Input Monitoring entry manually:
`System Settings → Privacy & Security → Input Monitoring`

## Menu bar icon colours

| Colour | Meaning |
|--------|---------|
| Green  | All automations running normally |
| Yellow | One or more automations disabled by user |
| Orange | One or more automations running with an issue |
| Red    | One or more automations in error (e.g. missing permission) |

## Settings

Click the menu bar icon → **Settings** to configure keyboard layouts. By default, layouts are auto-detected from your enabled input sources.

## Security disclaimer

> **This app is not code-signed or notarized.** It is not enrolled in the Apple Developer Program, so macOS Gatekeeper will block it on first launch.
>
> To open it after installing, right-click (or Control-click) the app in `/Applications` and select **Open**, then confirm. You only need to do this once.
>
> If you are not comfortable running unsigned software, do not install this app. The full source code is available in this repository for your review.

## Building from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
# Build installer and uninstaller pkgs into dist/
bash package.sh

# Or install directly for local development
bash install.sh
```

## Configuration

Config is stored at `~/.config/osx-utils-automation/config.json` and is reloaded automatically when changed.

```json
{
  "keyboardSwitcher": {
    "enabled": true,
    "macLayout": "com.apple.keylayout.British",
    "pcLayout": "com.apple.keylayout.British-PC"
  },
  "dockWatcher": {
    "enabled": true
  }
}
```

Set `macLayout` and `pcLayout` to `null` to use auto-detection.

## Logs

`~/Library/Logs/osx-utils-automation.log` — or click **Open Logs** in the menu.
