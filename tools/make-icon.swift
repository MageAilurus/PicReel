// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import AppKit

// Draws the PicReel app icon and writes a single 1024x1024 PNG.
// tools/make-icon.sh turns that into AppIcon.icns.
//
// Motif: a stack of cards (the deck you sift through) on a squircle, with a
// reel ring on the front card. Kept to two shapes and one gradient so it still
// reads at 16pt.

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let artRect = NSRect(x: inset, y: inset,
                     width: canvas - inset * 2,
                     height: canvas - inset * 2)
let corner = artRect.width * 0.225

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

// Soft drop shadow under the squircle (macOS icons carry one).
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14),
                  blur: 34,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
let squircle = NSBezierPath(roundedRect: artRect, xRadius: corner, yRadius: corner)
NSColor.black.setFill()
squircle.fill()
context.restoreGState()

// Body gradient.
let top = NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.95, alpha: 1)
let bottom = NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.80, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: squircle, angle: -90)

// A highlight sheen across the top half.
context.saveGState()
squircle.addClip()
NSGradient(starting: NSColor.white.withAlphaComponent(0.22),
           ending: NSColor.white.withAlphaComponent(0.0))?
    .draw(in: NSRect(x: artRect.minX, y: artRect.midY,
                     width: artRect.width, height: artRect.height / 2),
          angle: -90)
context.restoreGState()

// Two cards peeking out behind the front one.
func card(_ rect: NSRect, radius: CGFloat, rotation: CGFloat, alpha: CGFloat) {
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: rotation * .pi / 180)
    context.translateBy(x: -rect.midX, y: -rect.midY)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.white.withAlphaComponent(alpha).setFill()
    path.fill()
    context.restoreGState()
}

let cardW: CGFloat = 470
let cardH: CGFloat = 570
let cx = artRect.midX
let cy = artRect.midY

card(NSRect(x: cx - cardW / 2 - 30, y: cy - cardH / 2 - 4, width: cardW, height: cardH),
     radius: 46, rotation: -11, alpha: 0.45)
card(NSRect(x: cx - cardW / 2 + 22, y: cy - cardH / 2 + 6, width: cardW, height: cardH),
     radius: 46, rotation: 9, alpha: 0.65)
card(NSRect(x: cx - cardW / 2, y: cy - cardH / 2, width: cardW, height: cardH),
     radius: 46, rotation: 0, alpha: 0.97)

// Reel ring on the front card.
let ringCentre = NSPoint(x: cx, y: cy + 10)
let ringRadius: CGFloat = 132
let ring = NSBezierPath()
ring.appendArc(withCenter: ringCentre, radius: ringRadius, startAngle: 0, endAngle: 360)
ring.lineWidth = 46
NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.86, alpha: 1).setStroke()
ring.stroke()

// Sprocket holes.
let holeRadius: CGFloat = 40
for index in 0..<4 {
    let angle = CGFloat(index) * .pi / 2 + .pi / 4
    let centre = NSPoint(x: ringCentre.x + cos(angle) * ringRadius,
                         y: ringCentre.y + sin(angle) * ringRadius)
    let hole = NSBezierPath(ovalIn: NSRect(x: centre.x - holeRadius, y: centre.y - holeRadius,
                                           width: holeRadius * 2, height: holeRadius * 2))
    NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.86, alpha: 1).setFill()
    hole.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try? png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
