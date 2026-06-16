// dump-api.swift — developer helper that prints every `Sidecar*` Objective-C class in the
// private SidecarCore framework along with its instance/class methods.
//
// Use this to (re)discover the private API after a macOS update if `sidecar-connect`
// stops working — e.g. to confirm `SidecarDisplayManager` and its selectors still exist.
//
//     swiftc tools/dump-api.swift -o dump-api && ./dump-api
//
// SPDX-License-Identifier: MIT

import Foundation
import ObjectiveC.runtime
import MachO

let frameworkPath = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
guard dlopen(frameworkPath, RTLD_NOW) != nil else {
    FileHandle.standardError.write("dlopen failed: \(String(cString: dlerror()))\n".data(using: .utf8)!)
    exit(1)
}

// The runtime knows the image by its resolved (versioned) path, not the symlink above.
var imageName: String?
for i in 0..<_dyld_image_count() {
    let n = String(cString: _dyld_get_image_name(i))
    if n.contains("SidecarCore") { imageName = n }
}
guard let image = imageName else {
    FileHandle.standardError.write("SidecarCore image not found among loaded images\n".data(using: .utf8)!)
    exit(1)
}

func methods(of cls: AnyClass) -> [String] {
    var count: UInt32 = 0
    var out: [String] = []
    if let list = class_copyMethodList(cls, &count) {
        for i in 0..<Int(count) { out.append("-" + NSStringFromSelector(method_getName(list[i]))) }
        free(list)
    }
    if let meta = object_getClass(cls), let list = class_copyMethodList(meta, &count) {
        for i in 0..<Int(count) { out.append("+" + NSStringFromSelector(method_getName(list[i]))) }
        free(list)
    }
    return out
}

var classCount: UInt32 = 0
guard let names = image.withCString({ objc_copyClassNamesForImage($0, &classCount) }) else {
    print("no class names for image"); exit(1)
}
for i in 0..<Int(classCount) {
    let name = String(cString: names[i])
    guard let cls = NSClassFromString(name) else { continue }
    print("==== \(name) ====")
    for m in methods(of: cls).sorted() { print("  \(m)") }
}
