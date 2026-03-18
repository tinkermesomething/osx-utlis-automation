# osx-utils-automation

<p align="center">
  <img src="Resources/AppIcon.iconset/icon_512x512.png" alt="osx-utils-automation icon" width="128">
</p>

Most tools that react to USB devices only see plug/unplug events — they can't tell which keyboard you're *actually typing on*. osx-utils-automation monitors the live HID input stream, so it knows the moment you switch keyboards and reacts instantly, even when multiple are connected at the same time.

It runs silently in the menu bar, watches for both hardware events and active input, and handles the repetitive stuff automatically.

## Automations

### Keyboard Layout Switcher
Switches your macOS input layout automatically — not just when a keyboard connects, but the moment you start typing on it. Both USB and Bluetooth keyboards supported. Uses keypress detection to filter phantom HID services (e.g. Logitech Unifying Receiver) that other tools misidentify as keyboards.

Configure your Mac (built-in) and external keyboard layouts in Settings, or let the app auto-detect them from your enabled input sources.

### Dock Watcher
Launches an app of your choice when a USB dock is connected and quits it when the dock is disconnected. Works with any dock — detect it with one click during setup and browse to the app you want to control.

## First run

A welcome wizard walks you through setup on first launch — module selection, keyboard layout confirmation, and dock configuration — before starting any automations or requesting permissions.

## Requirements

- macOS 13 or later

## Installation

1. Download `osx-utils-automation-{version}.pkg` from the [latest release](../../releases/latest) and double-click to install.
2. After the wizard completes, grant **Input Monitoring** permission when prompted (required for the keyboard switcher):
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
| Orange | One or more automations running with an issue (e.g. dock not configured) |
| Red    | One or more automations in error (e.g. missing permission) |

## Settings

Click the menu bar icon → **Settings** to configure:

- **General** — launch at login, check for updates
- **Modules** — enable or disable individual automations
- **Keyboard Layout** — Mac and external keyboard layouts, Bluetooth support, active detection
- **Dock Watcher** — detect your dock device, choose the app to control
- **Notifications** — per-module notification toggles (USB, Bluetooth, dock events)

Module tabs only appear in the sidebar when that module is enabled.

## Alternatives

[Stecker](https://apps.apple.com/us/app/stecker/id6447288587) (free, App Store) triggers macOS Shortcuts on device connect/disconnect — great if you want to plug into the Shortcuts ecosystem. It doesn't monitor live input, so it can't switch layouts based on which keyboard you're actively typing on.

[autokbisw](https://github.com/ohueter/autokbisw) handles per-keyboard input source switching and is solid if you're comfortable with a headless daemon and no GUI. [Hammerspoon](https://www.hammerspoon.org) can do both automations with Lua scripting. [Keyboard Maestro](https://www.keyboardmaestro.com) ($36) covers both via USB triggers.

osx-utils-automation targets non-technical users — no config files, no scripting, one-click installer, guided setup wizard, menu bar UI — and combines keyboard switching and dock automation in a single lightweight app.

## Roadmap

The current automations are built-in, but the goal is to ship a **custom automation wizard** — a no-code UI for building your own "if this, then that" rules without touching config files. Triggers will include USB device connect/disconnect, active input device, app launch, time of day, and network change.

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

## Logs

`~/Library/Logs/osx-utils-automation.log` — or click **Open Logs** in the menu.

## Security disclaimer

> **This app is not code-signed or notarized.** It is not enrolled in the Apple Developer Program, so macOS Gatekeeper will block it on first launch.
>
> To open it after installing, right-click (or Control-click) the app in `/Applications` and select **Open**, then confirm. You only need to do this once.
>
> If you are not comfortable running unsigned software, do not install this app. The full source code is available in this repository for your review.

## AI assistance disclaimer

This project was designed, architected, and driven by a human developer. [Claude](https://claude.ai) (Anthropic) was used as a development assistant throughout — writing and reviewing code, debugging, and suggesting approaches — in the same way a senior developer might pair-program with a colleague. Every decision was reviewed, tested, and approved by the project owner.

This is not vibe-coded. There is a distinction.
