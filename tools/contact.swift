// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import AppKit

// Build a contact sheet from frames so a whole transition can be eyeballed at once.
// usage: contact.swift <out.png> <cols> <scale> <frame.png>...

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4, let cols = Int(args[1]), let scale = Double(args[2]) else {
    print("usage: contact.swift <out.png> <cols> <scale> <frames...>")
    exit(2)
}
let out = URL(fileURLWithPath: args[0])
let files = Array(args.dropFirst(3))

var images: [(String, NSImage)] = []
for f in files {
    if let img = NSImage(contentsOfFile: f) {
        images.append(((f as NSString).lastPathComponent, img))
    }
}
guard let first = images.first?.1 else { print("no images loaded"); exit(1) }

let cw = first.size.width * scale
let ch = first.size.height * scale
let rows = Int(ceil(Double(images.count) / Double(cols)))
let sheet = NSImage(size: NSSize(width: cw * CGFloat(cols), height: ch * CGFloat(rows)))

sheet.lockFocus()

// Background behind the tiles. Black is right for a frame sheet (the dark gaps
// separate frames), but wrong for an archived screenshot with a ragged last
// row: the empty cell reads as a hole in the sheet. CONTACT_BG=RRGGBB fixes it.
func colorFromHex(_ hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255,
                   alpha: 1)
}
(colorFromHex(ProcessInfo.processInfo.environment["CONTACT_BG"] ?? "") ?? .black).setFill()
NSRect(x: 0, y: 0, width: sheet.size.width, height: sheet.size.height).fill()

for (i, entry) in images.enumerated() {
    let c = i % cols
    let r = i / cols
    let rect = NSRect(x: CGFloat(c) * cw,
                      y: sheet.size.height - CGFloat(r + 1) * ch,
                      width: cw,
                      height: ch)
    entry.1.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    // Conditional: a contact sheet for debugging wants the filenames, an
    // archived screenshot does not. CONTACT_LABELS=0 turns them off.
    if ProcessInfo.processInfo.environment["CONTACT_LABELS"] != "0" {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
        NSString(string: entry.0).draw(at: NSPoint(x: rect.minX + 8, y: rect.maxY - 30),
                                       withAttributes: attrs)
    }
}
sheet.unlockFocus()

if let tiff = sheet.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: out)
    print("wrote \(out.path) · \(images.count) frames · \(cols)x\(rows)")
} else {
    print("failed to encode")
    exit(1)
}
