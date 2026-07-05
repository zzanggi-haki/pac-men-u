// Renders the pixel-art pacman (same 12×12 dot grid as the menu bar icon)
// as a white sprite on a dark rounded tile, into AppIcon.iconset PNGs.
// Run via build.sh, then iconutil turns it into .icns.
import AppKit

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)

    // dark rounded tile (macOS icon style)
    let inset = s * 0.08
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.15, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: tile, xRadius: s * 0.185, yRadius: s * 0.185).fill()

    // white pixel pacman, mouth open, facing left — same grid as the menu bar icon
    let grid = 12
    let art = tile.insetBy(dx: tile.width * 0.16, dy: tile.height * 0.16)
    let cell = art.width / CGFloat(grid)
    let c = CGFloat(grid - 1) / 2
    let mouthAngle: CGFloat = 35
    NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
    for rowTop in 0..<grid {
        for col in 0..<grid {
            let dx = CGFloat(col) - c
            let dy = c - CGFloat(rowTop)
            guard sqrt(dx * dx + dy * dy) <= 6.0 else { continue }      // circle body
            if rowTop == 3 && (col == 3 || col == 4) { continue }       // eye
            let ang = atan2(dy, dx) * 180 / .pi                         // mouth wedge (left)
            if abs(180 - abs(ang)) < mouthAngle { continue }
            let gap = cell * 0.07 // deliberate dot spacing (retro LED look)
            NSRect(x: art.minX + CGFloat(col) * cell,
                   y: art.minY + art.height - CGFloat(rowTop + 1) * cell,
                   width: cell, height: cell).insetBy(dx: gap, dy: gap).fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let data = render(px).representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("iconset written to \(outDir)")
