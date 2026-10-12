// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import SwiftUI
import AppKit

@main
struct PicReelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless check path: no window, no photo library, no screen needed.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
    }

    var body: some Scene {
        WindowGroup("PicReel") {
            ContentView(store: PhotoStore.shared)
        }
        // Drop the system title bar so our own bar can run edge to edge; the
        // traffic lights stay, floating over the leading inset we reserve.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            // 「重新运行引导」放在 App 菜单里、紧跟「关于」下面 ——
            // 菜单栏一拉开就能看到，不用翻二级菜单。
            CommandGroup(after: .appInfo) {
                Button("重新运行引导…") {
                    PhotoStore.shared.startGuide(force: true)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        KeyMonitor.shared.install { PhotoStore.shared.handleKey($0) }
        PhotoStore.shared.bootstrap()
        NSApp.activate(ignoringOtherApps: true)

        // With the title bar hidden, the window has to be draggable by its
        // background or it can barely be moved at all.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.isMovableByWindowBackground = true
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
        }

        // SwiftUI hands first-responder to a TextField shortly after launch,
        // which would swallow every sift key. Take it back once the window has
        // settled -- onAppear alone fires too early. Also re-apply the saved
        // light/dark choice now that a window actually exists.
        for delay in [0.25, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PhotoStore.shared.applyAppearance()
                PhotoStore.shared.refocus()
            }
        }

        runWindowDiagnostics()
    }

    /// Diagnostic: is there actually a key-able window? (No screen capture in
    /// some environments, so the event path has to be traceable from the log.)
    private func runWindowDiagnostics() {
        guard CommandLine.arguments.contains("--keyprobe") else { return }
        for delay in [1.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let windows = NSApp.windows
                PhotoStore.shared.note(
                    "diag[\(Int(delay))s] windows=\(windows.count) key=\(NSApp.keyWindow?.title ?? "-") "
                    + "main=\(NSApp.mainWindow?.title ?? "-") active=\(NSApp.isActive) "
                    + "firstResponder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") "
                    + "monitorsInstalled=\(KeyMonitor.shared.isInstalled)"
                )
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
