// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import AVFoundation
import AppKit

// Pull every frame out of a screen recording so a one-frame flash is visible.
// Usage: swift tools/frames.swift <recording.mov> <outdir> [fps]

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: frames.swift <recording.mov> <outdir> [fps]")
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let fps = args.count > 3 ? (Double(args[3]) ?? 30) : 30

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let asset = AVURLAsset(url: url)
let duration = CMTimeGetSeconds(asset.duration)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

var written = 0
var t = 0.0
while t < duration {
    let time = CMTime(seconds: t, preferredTimescale: 60000)
    if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            let name = String(format: "f%05d.png", Int((t * fps).rounded()))
            try? data.write(to: outDir.appendingPathComponent(name))
            written += 1
        }
    }
    t += 1.0 / fps
}
print("duration \(String(format: "%.2f", duration))s -> \(written) frames into \(outDir.path)")
