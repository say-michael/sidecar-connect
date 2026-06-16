// sidecar-connect — connect/disconnect an iPad via macOS Sidecar from the command line.
//
// Drives Apple's private SidecarCore framework (SidecarDisplayManager), the same one
// Control Center uses. No UI scripting, so it works headlessly — e.g. when the Mac's
// built-in screen is dead and no external display is attached.
//
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Private SidecarCore interfaces (declared here, resolved at runtime via dlopen)

@objc protocol SCDevice {
    func name() -> String?
    func identifier() -> String?
}

@objc protocol SCManager {
    func devices() -> [AnyObject]
    func connectedDevices() -> [AnyObject]
    @objc(connectToDevice:completion:)
    func connect(toDevice device: AnyObject, completion: @escaping (NSError?) -> Void)
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
    \(programName) <command> [name]

COMMANDS:
    list                 List nearby/connected Sidecar devices ( ● = connected )
    connect [name]       Connect to a device (name = case-insensitive substring)
    disconnect [name]    Disconnect from a device
    toggle [name]        Connect if not connected, otherwise disconnect
    help, --help, -h     Show this help

NOTES:
    [name] is optional; with no argument the command acts on the first device found.
    Example:  \(programName) toggle iPad
"""

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

func availableDevices() -> [AnyObject] { mgr.devices() }
func connectedDevices() -> [AnyObject] { mgr.connectedDevices() }

func firstMatch(in devices: [AnyObject], query: String?) -> AnyObject? {
    guard let q = query, !q.isEmpty else { return devices.first }
    let needle = q.lowercased()
    return devices.first { deviceName($0).lowercased().contains(needle) }
}

/// Pump the run loop until `done()` returns true or `seconds` elapse.
func wait(upTo seconds: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

func performConnect(_ device: AnyObject) {
    var finished = false
    var failure: NSError?
    print("Connecting to \(deviceName(device))…")
    mgr.connect(toDevice: device) { err in failure = err; finished = true }
    wait(upTo: 20) { finished }
    if !finished { die("timed out waiting for connection") }
    if let e = failure { die("connect failed: \(e.localizedDescription)") }
    print("Connected.")
}

func performDisconnect(_ device: AnyObject) {
    var finished = false
    var failure: NSError?
    print("Disconnecting from \(deviceName(device))…")
    mgr.disconnect(fromDevice: device) { err in failure = err; finished = true }
    wait(upTo: 20) { finished }
    if !finished { die("timed out waiting for disconnect") }
    if let e = failure { die("disconnect failed: \(e.localizedDescription)") }
    print("Disconnected.")
}

// MARK: - Command dispatch

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "list"
let nameQuery = arguments.count > 1 ? arguments[1] : nil

switch command {
case "help", "--help", "-h":
    print(usage)

case "list":
    let available = availableDevices()
    let connected = connectedDevices()
    let connectedNames = Set(connected.map(deviceName))
    if available.isEmpty && connected.isEmpty {
        print("No Sidecar devices found.")
        break
    }
    for d in available {
        let name = deviceName(d)
        print("  \(connectedNames.contains(name) ? "●" : "○") \(name)")
    }
    for d in connected where !available.contains(where: { deviceName($0) == deviceName(d) }) {
        print("  ● \(deviceName(d))  (connected)")
    }

case "connect":
    guard let d = firstMatch(in: availableDevices(), query: nameQuery)
            ?? firstMatch(in: connectedDevices(), query: nameQuery) else {
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
    } else if let d = firstMatch(in: availableDevices(), query: nameQuery) {
        performConnect(d)
    } else {
        die("no matching device to toggle. Run `\(programName) list`.")
    }

default:
    warn("\(programName): unknown command '\(command)'\n")
    print(usage)
    exit(2)
}
