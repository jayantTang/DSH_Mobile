// Renders the DSH.app icon set. Usage: swift make-icon.swift <out.iconset>
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func makePNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let size = CGFloat(pixels)
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.22

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.17, alpha: 1),
    ])
    gradient?.draw(in: path, angle: -90)

    NSColor(calibratedRed: 0.42, green: 0.60, blue: 0.98, alpha: 0.9).setStroke()
    path.lineWidth = max(size * 0.012, 1)
    path.stroke()

    let text = "DSH" as NSString
    let font = NSFont.systemFont(ofSize: size * 0.30, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.98, alpha: 1),
    ]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (size - textSize.width) / 2,
                          y: (size - textSize.height) / 2 + size * 0.01),
              withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in variants {
    guard let data = makePNG(pixels: pixels) else { continue }
    try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(variants.count) icon files to \(outDir)")
