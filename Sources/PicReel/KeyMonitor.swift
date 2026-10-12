// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import AppKit

/// App-wide key monitor.
///
/// Why not SwiftUI's `onKeyPress`, or an NSViewRepresentable + keyDown?
/// Arrow keys get eaten by SwiftUI's focus navigation, and the first-responder
/// dance in SwiftUI is fragile. A local NSEvent monitor sees every keyDown
/// before dispatch, with zero responder-chain games.
///
/// (Also: `@State` is a macro in this SDK and CommandLineTools does not ship
/// the SwiftUIMacros plugin, so no SwiftUI `@State` anywhere in this project.)
final class KeyMonitor {
    static let shared = KeyMonitor()

    private var token: Any?

    var isInstalled: Bool { token != nil }

    /// Trace every key the monitor sees, before any filtering.
    static let trace = CommandLine.arguments.contains("--keyprobe")

    func install(_ handler: @escaping (NSEvent) -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if KeyMonitor.trace {
                PhotoStore.shared.note(
                    "monitor saw code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") "
                    + "firstResponder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
                )
            }
            // Esc always hands control back to the sifter, even from a text field.
            if event.keyCode == 53 {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }
            // Only defer to a text field when the user is actually typing in one.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            return handler(event) ? nil : event
        }
    }

    func uninstall() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
