// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import AppKit

/// Synthetic photos for `--demo` mode.
///
/// Exists so a screenshot or a demo can be taken without a single frame of the
/// user's real library appearing in it.
enum DemoLibrary {

    static let bucketNames = ["保留", "收藏", "修图", "发社交", "存档"]

    /// Albums the onboarding picker offers in `--demo`. Same "must not look like
    /// a real library" rule as the photos: plausible names, made-up counts.
    static let albums: [LibraryAlbum] = [
        LibraryAlbum(id: "demo-01", name: "2025 旅行",   count: 214),
        LibraryAlbum(id: "demo-02", name: "家庭合影",   count: 88),
        LibraryAlbum(id: "demo-03", name: "工作用图",   count: 356),
        LibraryAlbum(id: "demo-04", name: "待修图",     count: 41),
        LibraryAlbum(id: "demo-05", name: "收藏",       count: 130),
        LibraryAlbum(id: "demo-06", name: "数码测评",   count: 512),
        LibraryAlbum(id: "demo-07", name: "猫",         count: 76),
        LibraryAlbum(id: "demo-08", name: "截图待删",   count: 903),
        LibraryAlbum(id: "demo-09", name: "发社交",     count: 57),
        LibraryAlbum(id: "demo-10", name: "存档",       count: 168),
        LibraryAlbum(id: "demo-11", name: "旧手机导出", count: 1240),
        LibraryAlbum(id: "demo-12", name: "保留",       count: 95),
    ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// One thumbnail per demo album, for the guide's rows. Built from the same
    /// synthetic renderer at tile size, so a demo screenshot still contains not a
    /// single frame of a real library.
    static var albumThumbnails: [String: NSImage] {
        var out: [String: NSImage] = [:]
        for (index, album) in albums.enumerated() {
            out[album.id] = render(index: index + 3, size: NSSize(width: 140, height: 140))
        }
        return out
    }

    static func items(count: Int) -> [SiftItem] {
        (0..<count).map { index in
            let size: NSSize
            // Five shapes, not three: the extreme ones are what shake out layout
            // bugs. `1:5` is deliberately narrow — it is the case that forced the
            // info bar out of the card (an inside caption had ~110pt to live in).
            switch index % 5 {
            case 0:  size = NSSize(width: 1200, height: 1600)   // portrait 3:4
            case 1:  size = NSSize(width: 1600, height: 1200)   // landscape 4:3
            case 2:  size = NSSize(width: 1200, height: 1200)   // square
            case 3:  size = NSSize(width: 480, height: 2400)    // tall sliver 1:5
            default: size = NSSize(width: 2400, height: 1000)   // wide panorama 2.4:1
            }
            let date = Calendar.current.date(byAdding: .hour,
                                             value: -(index * 9 + index % 5),
                                             to: Date()) ?? Date()
            let kinds = ["", "", "截屏", "", "实况照片", "", "", "全景"]
            return SiftItem(id: "demo-\(index)",
                            date: date,
                            pixelWidth: Int(size.width),
                            pixelHeight: Int(size.height),
                            kind: kinds[index % kinds.count],
                            hasLocation: index % 3 != 0,
                            asset: nil,
                            demoImage: render(index: index, size: size))
        }
    }

    private static func render(index: Int, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let hue = CGFloat(index % 11) / 11.0
        let top = NSColor(hue: hue, saturation: 0.42, brightness: 0.97, alpha: 1)
        let bottom = NSColor(hue: (hue + 0.10).truncatingRemainder(dividingBy: 1),
                             saturation: 0.68, brightness: 0.60, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: 90)

        // Soft shapes so each tile reads as a scene rather than a flat swatch.
        for shape in 0..<5 {
            let radius = CGFloat(150 + shape * 110)
            let x = CGFloat((index * 137 + shape * 233) % Int(size.width))
            let y = CGFloat((index * 97 + shape * 181) % Int(size.height))
            NSColor.white.withAlphaComponent(0.08 + CGFloat(shape) * 0.025).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - radius / 2, y: y - radius / 2,
                                        width: radius, height: radius)).fill()
        }

        let caption = "示例 \(index + 1)" as NSString
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.width * 0.055, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
        ]
        caption.draw(at: NSPoint(x: size.width * 0.07, y: size.height * 0.055),
                     withAttributes: captionAttributes)

        let mark = "PicReel demo" as NSString
        let markAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.width * 0.028, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        mark.draw(at: NSPoint(x: size.width * 0.07, y: size.height * 0.085),
                  withAttributes: markAttributes)

        return image
    }
}
