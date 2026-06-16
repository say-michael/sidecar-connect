# sidecar-connect

> Connect or disconnect your iPad as a **Sidecar** display from the macOS command line — no menus, no clicking, **works even when the Mac's own screen is dead**.

[![Platform: macOS](https://img.shields.io/badge/platform-macOS-blue)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

`sidecar-connect` is a tiny Swift CLI that drives Apple's private `SidecarCore`
framework — the exact same code path Control Center uses when you pick a device under
**Screen Mirroring**. Because it talks to the framework directly (instead of scripting the
UI), it works **headlessly**: you can connect your iPad with a single keyboard shortcut even
when you can't see the Mac's built-in display at all.

---

## Why this exists

If your MacBook's built-in screen dies, you're stuck in a catch-22: Sidecar would give you a
working display on your iPad, but **turning Sidecar on normally requires you to see the screen**
to click through Control Center. The usual workaround is to plug into an external monitor every
time just to enable mirroring.

`sidecar-connect` breaks that loop. Bind it to a keyboard shortcut and you can bring up your
iPad display blind — the hardware keyboard still works fine without a screen.

It's also just a convenient way to script Sidecar for anyone who wants a hotkey instead of a
menu.

## Features

- **`connect` / `disconnect` / `toggle`** a Sidecar device by name (or the first one found).
- **`list`** nearby and currently-connected devices.
- **Headless** — no UI scripting, no Accessibility permissions, no screen required.
- Single self-contained binary, no dependencies beyond the Swift toolchain to build.

## Requirements

- **macOS** with Sidecar support (Catalina 10.15 or later; built and tested on macOS 26).
- A Sidecar-capable iPad already paired to the same Apple Account / set up for Sidecar.
- **Xcode Command Line Tools** to build (`xcode-select --install`) — provides `swiftc`.

> ⚠️ This tool relies on a **private, undocumented Apple framework** (`SidecarCore`).
> See [Caveats](#caveats--how-it-works).

## Install

### From source

```sh
git clone https://github.com/say-michael/sidecar-connect.git
cd sidecar-connect
make            # builds ./sidecar-connect
sudo make install   # installs to /usr/local/bin
```

Prefer a user-local install with no `sudo`:

```sh
make install PREFIX="$HOME/.local"   # installs to ~/.local/bin (make sure it's on $PATH)
```

To remove it later: `make uninstall` (use the same `PREFIX` you installed with).

### Manual one-liner

```sh
swiftc -O src/main.swift -o sidecar-connect && cp sidecar-connect /usr/local/bin/
```

## Usage

```text
sidecar-connect <command> [name]

Commands:
  list                 List nearby/connected Sidecar devices ( ● = connected )
  connect [name]       Connect to a device (name = case-insensitive substring)
  disconnect [name]    Disconnect from a device
  toggle [name]        Connect if not connected, otherwise disconnect
  help, --help, -h     Show help
```

`name` is an optional, case-insensitive substring of the device name. With no `name`, the
command acts on the first device it finds.

```sh
$ sidecar-connect list
  ○ Michael’s iPad

$ sidecar-connect connect iPad
Connecting to Michael’s iPad…
Connected.

$ sidecar-connect toggle iPad      # now connected → this disconnects
Disconnecting from Michael’s iPad…
Disconnected.
```

## Bind it to a keyboard shortcut (the killer use case)

Use **Shortcuts.app** (built into macOS) to fire `sidecar-connect` from a global hotkey:

1. Open **Shortcuts.app** → click **+** to create a new shortcut → name it e.g. *Sidecar Toggle*.
2. Add the **Run Shell Script** action.
3. Set **Shell** to `zsh` and enter the script (use the full install path):
   ```sh
   /usr/local/bin/sidecar-connect toggle iPad
   ```
4. Open the shortcut's **details** panel (ⓘ) → **Add Keyboard Shortcut** → press your key combo
   (e.g. ⌃⌥⌘S).

Now that combo connects Sidecar when it's off and disconnects when it's on — **even with the
lid screen dead**, as long as you're logged in.

> **Tip:** Trigger it once while you *can* see the screen (e.g. connected to a monitor) so you
> can approve any first-run permission prompt. After that it runs silently.

## Optional: auto-reconnect on login

Want Sidecar to come up automatically every time you log in? Create a LaunchAgent at
`~/Library/LaunchAgents/com.user.sidecar-connect.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>          <string>com.user.sidecar-connect</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/sidecar-connect</string>
        <string>connect</string>
        <string>iPad</string>
    </array>
    <key>RunAtLoad</key>      <true/>
</dict>
</plist>
```

Load it with:

```sh
launchctl load ~/Library/LaunchAgents/com.user.sidecar-connect.plist
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `No Sidecar devices found` | Ensure the iPad is awake, nearby, on the same Apple Account, and Sidecar is enabled in System Settings → Displays. |
| `connect failed` / timeout | The iPad may be locked or already in use by another Mac. Unlock it and retry. |
| `SidecarDisplayManager class not found` | The private API changed in your macOS version — see [Caveats](#caveats--how-it-works) and re-run the API dumper. |
| A `NSForwarding … __NSGenericDeallocHandler` line prints to stderr | Harmless noise emitted when the private framework loads. Ignore it. |

### Re-discovering the API after a macOS update

If a future macOS renames the private classes/selectors, rebuild your knowledge of the API:

```sh
make dump-api
./dump-api | less
```

This prints every `Sidecar*` Objective-C class and its methods so you can spot the new names
for `SidecarDisplayManager`, `connectToDevice:completion:`, etc., and update `src/main.swift`.

## Caveats & how it works

`sidecar-connect` `dlopen`s `/System/Library/PrivateFrameworks/SidecarCore.framework`, grabs
`SidecarDisplayManager.sharedManager`, and calls its `-devices`, `-connectedDevices`,
`-connectToDevice:completion:` and `-disconnectFromDevice:completion:` methods via the
Objective-C runtime. The private interfaces are declared as `@objc` protocols in `src/main.swift`
and resolved at runtime — nothing is linked against the private framework at build time.

Because `SidecarCore` is **private and undocumented**:

- Apple can change or remove it in any macOS update. It has been stable for years, but there's
  no guarantee. The `dump-api` helper exists precisely so you can adapt quickly if it breaks.
- This is not endorsed by or affiliated with Apple. Use at your own risk.

## Contributing

Issues and PRs welcome — especially confirmations of which macOS versions work, and selector
updates if Apple changes the API. Please keep the tool dependency-free and single-file.

## License

[MIT](LICENSE) © say-michael

## Disclaimer

This project uses a private Apple framework for personal/interoperability purposes. "Sidecar",
"iPad", and "macOS" are trademarks of Apple Inc. This project is not affiliated with, endorsed
by, or supported by Apple.
