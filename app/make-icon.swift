// Generates FLAC2Watch.icns (the app icon). Re-run after design changes:
//   swift app/make-icon.swift
import AppKit

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    result.unlockFocus()
    return result
}

func symbol(_ name: String, points: CGFloat, weight: NSFont.Weight) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
}

// Draws the icon at an arbitrary pixel size.
func drawIcon(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    // Standard macOS icon: squircle with a small transparent margin.
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    path.addClip()
    NSGradient(starting: NSColor(calibratedRed: 0.44, green: 0.36, blue: 0.96, alpha: 1),
               ending: NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.86, alpha: 1))?
        .draw(in: rect, angle: -70)

    // Watch outline with a music note on the face.
    if let watch = symbol("applewatch", points: size, weight: .medium) {
        let white = tinted(watch, .white)
        let h = rect.height * 0.62
        let w = h * white.size.width / white.size.height
        white.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        if let note = symbol("music.note", points: size, weight: .semibold) {
            let whiteNote = tinted(note, .white)
            let nh = h * 0.30
            let nw = nh * whiteNote.size.width / whiteNote.size.height
            whiteNote.draw(in: NSRect(x: rect.midX - nw / 2, y: rect.midY - nh / 2, width: nw, height: nh))
        }
    }

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let outURL = scriptURL.deletingLastPathComponent().appendingPathComponent("FLAC2Watch.icns")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FLAC2Watch.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(CGFloat(base)), pixels: base,
             to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(drawIcon(CGFloat(base * 2)), pixels: base * 2,
             to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "✓ \(outURL.path)" : "iconutil failed")
exit(iconutil.terminationStatus)
