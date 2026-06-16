// sidecar-connect — connect/disconnect an iPad via macOS Sidecar from the command line.
//
// Drives Apple's private SidecarCore framework (SidecarDisplayManager), the same one
// Control Center uses. No UI scripting, so it works headlessly — e.g. when the Mac's
// built-in screen is dead and no external display is attached.
//
// SPDX-License-Identifier: MIT

import Foundation

let programVersion = "0.2.0"

// MARK: - Private SidecarCore interfaces (declared here, resolved at runtime via dlopen)

@objc protocol SCDevice {
    func name() -> String?
    // SidecarDevice.identifier returns an NSUUID, not a String — keep it as an object
    // so Swift doesn't try to bridge it to String (which crashes calling -length).
    func identifier() -> AnyObject?
}

@objc protocol SCConfig {
    func showSideBar() -> Bool
    func showTouchBar() -> Bool
    func setShowSideBar(_ value: Bool)
    func setShowTouchBar(_ value: Bool)
}

@objc protocol SCManager {
    func devices() -> [AnyObject]
    func connectedDevices() -> [AnyObject]
    @objc(connectToDevice:completion:)
    func connect(toDevice device: AnyObject, completion: @escaping (NSError?) -> Void)
    @objc(connectToDevice:withConfig:completion:)
    func connect(toDevice device: AnyObject, withConfig config: AnyObject, completion: @escaping (NSError?) -> Void)
    @objc(configForDevice:)
    func config(forDevice device: AnyObject) -> AnyObject?
    @objc(disconnectFromDevice:completion:)
    func disconnect(fromDevice device: AnyObject, completion: @escaping (NSError?) -> Void)
}

let programName = "sidecar-connect"

func warn(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

func die(_ msg: String) -> Never {
    warn("\(programName): \(msg)")
    exit(1)
}

let usage = """
\(programName) — connect/disconnect an iPad via macOS Sidecar from the CLI.

USAGE:
    \(programName) <command> [name] [options]

COMMANDS:
    list                 List nearby/connected Sidecar devices ( ● = connected )
    connect [name]       Connect to a device (name = case-insensitive substring)
    disconnect [name]    Disconnect from a device
    toggle [name]        Connect if not connected, otherwise disconnect
    status [name]        Print connection state; exit 0 if connected, 3 if not
    help, --help, -h     Show this help
    version, --version   Show version

OPTIONS:
    --wait <seconds>     Poll for the device to appear before acting (default 0).
                         Use for login auto-connect, where discovery lags.
    --json               Machine-readable output (list, status).
    --quiet, -q          Suppress progress lines (errors still print).
    --no-sidebar         Connect without the on-screen sidebar.
    --no-touchbar        Connect without the on-screen Touch Bar.

NOTES:
    [name] is optional; with no argument the command acts on the first device found.
    Example:  \(programName) toggle iPad --wait 30
"""

// MARK: - Argument parsing

struct Options {
    var wait: TimeInterval = 0
    var json = false
    var quiet = false
    var noSidebar = false
    var noTouchbar = false
}

var opts = Options()
var positional: [String] = []

do {
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--wait":
            i += 1
            guard i < args.count, let secs = TimeInterval(args[i]), secs >= 0 else {
                die("--wait requires a non-negative number of seconds")
            }
            opts.wait = secs
        case "--json":        opts.json = true
        case "--quiet", "-q": opts.quiet = true
        case "--no-sidebar":  opts.noSidebar = true
        case "--no-touchbar": opts.noTouchbar = true
        default:
            positional.append(a)
        }
        i += 1
    }
}

func say(_ msg: String) {
    if !opts.quiet { print(msg) }
}

// MARK: - Load the private framework

let frameworkPath = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
guard dlopen(frameworkPath, RTLD_NOW) != nil else {
    die("could not load SidecarCore: \(String(cString: dlerror()))")
}

guard let mgrClass = NSClassFromString("SidecarDisplayManager") else {
    die("SidecarDisplayManager class not found (the private API may have changed in this macOS version)")
}

guard let mgrAny = (mgrClass as AnyObject).perform(Selector(("sharedManager")))?.takeUnretainedValue() else {
    die("could not obtain SidecarDisplayManager.sharedManager")
}
let mgr = unsafeBitCast(mgrAny, to: SCManager.self)

// MARK: - Helpers

func deviceName(_ d: AnyObject) -> String { unsafeBitCast(d, to: SCDevice.self).name() ?? "(unknown)" }

/// Stable identity for a device. Falls back to the name if no identifier is exposed.
func deviceID(_ d: AnyObject) -> String {
    guard let id = unsafeBitCast(d, to: SCDevice.self).identifier() else { return deviceName(d) }
    if let uuid = id as? UUID { return uuid.uuidString }
    if let uuid = id as? NSUUID { return uuid.uuidString }
    return String(describing: id)
}

func availableDevices() -> [AnyObject] { mgr.devices() }
func connectedDevices() -> [AnyObject] { mgr.connectedDevices() }

func firstMatch(in devices: [AnyObject], query: String?) -> AnyObject? {
    guard let q = query, !q.isEmpty else { return devices.first }
    let needle = q.lowercased()
    return devices.first { deviceName($0).lowercased().contains(needle) }
}

func isConnected(_ d: AnyObject) -> Bool {
    let id = deviceID(d)
    return connectedDevices().contains { deviceID($0) == id }
}

/// Pump the run loop until `done()` returns true or `seconds` elapse.
func wait(upTo seconds: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// Poll device discovery until `query` matches an available (or, if requested, connected) device.
/// Returns the matched device, or nil if the wait window elapses without a match.
func waitForDevice(query: String?, includeConnected: Bool, timeout: TimeInterval) -> AnyObject? {
    func lookup() -> AnyObject? {
        firstMatch(in: availableDevices(), query: query)
            ?? (includeConnected ? firstMatch(in: connectedDevices(), query: query) : nil)
    }
    if let d = lookup() { return d }
    guard timeout > 0 else { return nil }
    say("Waiting up to \(Int(timeout))s for a Sidecar device…")
    var found: AnyObject?
    wait(upTo: timeout) { found = lookup(); return found != nil }
    return found
}

/// Build a display config for `device`, applying any user overrides. Returns nil if the
/// framework doesn't vend a config (older macOS) so callers fall back to the plain connect.
func makeConfig(for device: AnyObject) -> AnyObject? {
    guard opts.noSidebar || opts.noTouchbar else { return nil }
    guard let cfg = mgr.config(forDevice: device) else { return nil }
    let scfg = unsafeBitCast(cfg, to: SCConfig.self)
    if opts.noSidebar  { scfg.setShowSideBar(false) }
    if opts.noTouchbar { scfg.setShowTouchBar(false) }
    return cfg
}

func performConnect(_ device: AnyObject) {
    var finished = false
    var failure: NSError?
    say("Connecting to \(deviceName(device))…")
    if let cfg = makeConfig(for: device) {
        mgr.connect(toDevice: device, withConfig: cfg) { err in failure = err; finished = true }
    } else {
        mgr.connect(toDevice: device) { err in failure = err; finished = true }
    }
    wait(upTo: 20) { finished }
    if !finished { die("timed out waiting for connection") }
    if let e = failure { die("connect failed: \(e.localizedDescription)") }
    say("Connected.")
}

func performDisconnect(_ device: AnyObject) {
    var finished = false
    var failure: NSError?
    say("Disconnecting from \(deviceName(device))…")
    mgr.disconnect(fromDevice: device) { err in failure = err; finished = true }
    wait(upTo: 20) { finished }
    if !finished { die("timed out waiting for disconnect") }
    if let e = failure { die("disconnect failed: \(e.localizedDescription)") }
    say("Disconnected.")
}

func jsonString(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { return "[]" }
    return s
}

// MARK: - Command dispatch

let command = positional.first ?? "list"
let nameQuery = positional.count > 1 ? positional[1] : nil

switch command {
case "help", "--help", "-h":
    print(usage)

case "version", "--version":
    print("\(programName) \(programVersion)")

case "list":
    let available = availableDevices()
    let connected = connectedDevices()
    let connectedIDs = Set(connected.map(deviceID))

    // Union of discovered + connected devices, keyed by identifier so a connected-only
    // device (not currently in `devices()`) still shows up exactly once.
    var seen = Set<String>()
    var all: [AnyObject] = []
    for d in available + connected where seen.insert(deviceID(d)).inserted { all.append(d) }

    if opts.json {
        let rows = all.map { d -> [String: Any] in
            ["name": deviceName(d), "identifier": deviceID(d), "connected": connectedIDs.contains(deviceID(d))]
        }
        print(jsonString(rows))
        break
    }

    if all.isEmpty {
        print("No Sidecar devices found.")
        break
    }
    for d in all {
        print("  \(connectedIDs.contains(deviceID(d)) ? "●" : "○") \(deviceName(d))")
    }

case "status":
    let target = firstMatch(in: connectedDevices(), query: nameQuery)
        ?? firstMatch(in: availableDevices(), query: nameQuery)
    let connected = target.map(isConnected) ?? false
    if opts.json {
        var row: [String: Any] = ["connected": connected]
        if let t = target {
            row["name"] = deviceName(t)
            row["identifier"] = deviceID(t)
        }
        print(jsonString(row))
    } else if let t = target {
        print("\(connected ? "●" : "○") \(deviceName(t)) — \(connected ? "connected" : "not connected")")
    } else {
        print("No matching Sidecar device.")
    }
    exit(connected ? 0 : 3)

case "connect":
    guard let d = waitForDevice(query: nameQuery, includeConnected: true, timeout: opts.wait) else {
        die("no matching device. Run `\(programName) list`.")
    }
    performConnect(d)

case "disconnect":
    guard let d = firstMatch(in: connectedDevices(), query: nameQuery)
            ?? firstMatch(in: availableDevices(), query: nameQuery) else {
        die("no matching connected device.")
    }
    performDisconnect(d)

case "toggle":
    if let d = firstMatch(in: connectedDevices(), query: nameQuery) {
        performDisconnect(d)
    } else if let d = waitForDevice(query: nameQuery, includeConnected: false, timeout: opts.wait) {
        performConnect(d)
    } else {
        die("no matching device to toggle. Run `\(programName) list`.")
    }

default:
    warn("\(programName): unknown command '\(command)'\n")
    print(usage)
    exit(2)
}
