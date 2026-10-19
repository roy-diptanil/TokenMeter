import AppKit
import UsageCore

/// Lucide `gauge` (ISC), drawn from the SVG's path data: `m12 14 4-4` and `M3.34 19a10 10 0 1 1 17.32 0`.
/// Assumes a flipped (y-down) graphics context, matching SVG coordinates.
enum GaugeIcon {
    static func draw(origin: NSPoint, size: CGFloat, color: NSColor) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: size / 24, y: size / 24)
        let needle = NSBezierPath(); needle.move(to: NSPoint(x: 12, y: 14)); needle.line(to: NSPoint(x: 16, y: 10))
        // arc: centre (12,14), r 10, from 150deg through the top (270deg) to 30deg (390deg), y-down
        let arc = NSBezierPath()
        let steps = 72
        for i in 0...steps {
            let a = (150.0 + 240.0 * Double(i) / Double(steps)) * .pi / 180
            let p = NSPoint(x: 12 + 10 * cos(a), y: 14 + 10 * sin(a))
            if i == 0 { arc.move(to: p) } else { arc.line(to: p) }
        }
        color.setStroke()
        for p in [needle, arc] { p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke() }
        cg.restoreGState()
    }

    static func templateImage(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            draw(origin: .zero, size: size, color: .black); return true
        }
        img.isTemplate = true
        return img
    }

    /// App icon: white gauge on a dark rounded-square gradient.
    static func appIconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let s = CGFloat(pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.translateBy(x: 0, y: s); cg.scaleBy(x: 1, y: -1)   // y-down
        let rect = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
        let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.30, alpha: 1),
                   ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1))?.draw(in: bg, angle: 90)
        let g = s * 0.56
        draw(origin: NSPoint(x: (s - g) / 2, y: (s - g) / 2 + s * 0.02), size: g, color: .white)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? appIconPNG(pixels: base * scale)?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
        }
    }
}

enum MenuBarImage {
    static func image(_ segs: [LabelSegment]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let colored = segs.contains { $0.level != .normal }
        // Colored labels cannot be template images; labelColor resolves against the real menu bar at draw time.
        let base: NSColor = colored ? .labelColor : .black
        func color(_ l: LabelSegment.Level) -> NSColor { l == .red ? .systemRed : (l == .amber ? .systemOrange : base) }
        let iconSize: CGFloat = 16, gap: CGFloat = 4
        let parts: [NSAttributedString] = segs.enumerated().map { i, s in
            let str = NSMutableAttributedString(string: (i > 0 ? (s.isAlert ? " " : " · ") : "") , attributes: [.font: font, .foregroundColor: base])
            str.append(NSAttributedString(string: s.text, attributes: [.font: s.isAlert ? NSFont.systemFont(ofSize: 12, weight: .bold) : font, .foregroundColor: color(s.level)]))
            return str
        }
        let textW = parts.reduce(0) { $0 + $1.size().width }
        let w = iconSize + (segs.isEmpty ? 0 : gap + ceil(textW))
        let img = NSImage(size: NSSize(width: w, height: 18), flipped: true) { _ in
            GaugeIcon.draw(origin: NSPoint(x: 0, y: 1), size: iconSize, color: base)
            var x = iconSize + gap
            for p in parts { let sz = p.size(); p.draw(at: NSPoint(x: x, y: (18 - sz.height) / 2)); x += sz.width }
            return true
        }
        img.isTemplate = !colored
        return img
    }
}

enum LabelPreview {
    static func tinted(_ img: NSImage, _ c: NSColor) -> NSImage {
        let out = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r); c.set(); r.fill(using: .sourceIn); return true
        }
        return out
    }
    static func render(to path: String) {
        func seg(_ t: String, _ rem: Double) -> LabelSegment { .init(text: t, remaining: rem, level: MenuLabelLogic.level(remaining: rem)) }
        let rows: [[LabelSegment]] = [[seg("C 41%", 41), seg("X 91%", 91)], [seg("C 21%", 21), seg("X 91%", 91)], [seg("C 6%", 6), seg("X 18%", 18)]]
        let scale: CGFloat = 2, cellW: CGFloat = 170, cellH: CGFloat = 30
        let px = Int(cellW * 2 * scale), py = Int(cellH * 3 * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        for (col, dark) in [false, true].enumerated() {
            for (row, segs) in rows.enumerated() {
                let r = NSRect(x: CGFloat(col) * cellW, y: CGFloat(2 - row) * cellH, width: cellW, height: cellH)
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill(); r.fill()
                var img = MenuBarImage.image(segs)
                if img.isTemplate { img = tinted(img, dark ? .white : .black) }
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    img.draw(at: NSPoint(x: r.minX + 12, y: r.minY + (cellH - img.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
