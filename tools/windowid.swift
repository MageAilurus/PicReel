// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import CoreGraphics
import Foundation

// Print the CGWindowID of the first on-screen window owned by the given app.
//
// Exists so screenshots can be taken with `screencapture -l <id>`, which grabs
// that window no matter what is stacked on top of it. Plain region capture
// (`screencapture -R`) grabs whatever pixels are there — which is somebody
// else's window when the user is doing something else.
//
// usage: swift tools/windowid.swift <owner name>

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PicReel"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for info in list {
    let name = info[kCGWindowOwnerName as String] as? String ?? ""
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    guard name == owner, layer == 0 else { continue }
    // Skip tiny helper windows (tooltips, shadows) — take the biggest one.
    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    guard width > 200, height > 200, let number = info[kCGWindowNumber as String] as? Int else { continue }
    print(number)
    exit(0)
}

FileHandle.standardError.write("no on-screen window found for '\(owner)'\n".data(using: .utf8)!)
exit(1)
