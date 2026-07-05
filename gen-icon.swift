// Renders the open-mouth pacman (same drawing as the menu bar icon) into
// AppIcon.iconset PNGs. Run via build.sh, then iconutil turns it into .icns.
import AppKit

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = s * 0.425
    let mouthAngle: CGFloat = 35

    let path = NSBezierPath()
    path.move(to: center)
    path.appendArc(withCenter: center, radius: radius,
                   startAngle: 180 + mouthAngle, endAngle: 180 - mouthAngle,
                   clockwise: false)
    path.close()
    NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 1.0).setFill()
    path.fill()

    let eyeD = s * 0.13
    let eyeRect = NSRect(x: s * 0.375 - eyeD / 2, y: s * 0.65 - eyeD / 2, width: eyeD, height: eyeD)
    NSColor.black.withAlphaComponent(0.85).setFill()
    NSBezierPath(ovalIn: eyeRect).fill()

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
