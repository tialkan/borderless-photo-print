// Renders docs/layout.png: how the app lays out photos of different shapes on a 4x6 sheet.
// Uses the app's own PageLayout.swift on synthetic images, so the figure is real output.
//
//   swiftc -O tools/demo/main.swift Sources/PageLayout.swift -o build/demo && build/demo docs/layout.png

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Synthetic "photo": gradient, grid, a circle and a TOP marker, so rotation and cropping are visible.
func makePhoto(_ w: Int, _ h: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.16, green: 0.38, blue: 0.80, alpha: 1), CGColor(red: 0.96, green: 0.55, blue: 0.20, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
    ctx.setLineWidth(CGFloat(max(w, h)) / 400)
    let step = CGFloat(min(w, h)) / 6
    var x: CGFloat = 0
    while x <= CGFloat(w) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: CGFloat(h))); x += step }
    var y: CGFloat = 0
    while y <= CGFloat(h) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: CGFloat(w), y: y)); y += step }
    ctx.strokePath()
    let r = CGFloat(min(w, h)) * 0.28
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
    ctx.fillEllipse(in: CGRect(x: CGFloat(w) / 2 - r, y: CGFloat(h) / 2 - r, width: 2 * r, height: 2 * r))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let font = NSFont.boldSystemFont(ofSize: CGFloat(min(w, h)) / 7)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let text = NSAttributedString(string: "TOP", attributes: attrs)
    text.draw(at: NSPoint(x: CGFloat(w) / 2 - text.size().width / 2, y: CGFloat(h) - text.size().height - CGFloat(min(w, h)) / 14))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func writeJPEG(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let shapes: [(String, Int, Int)] = [
    ("Landscape 4:3", 1600, 1200), ("Portrait 3:4", 1200, 1600), ("Square 1:1", 1400, 1400), ("Panorama 8:3", 2000, 750),
]
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("layout-demo")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let scale: CGFloat = 2, cellW: CGFloat = 150, cellH: CGFloat = 225, gap: CGFloat = 14, labelW: CGFloat = 112, headH: CGFloat = 34
let width = labelW + 3 * (cellW + gap) + gap, height = headH + CGFloat(shapes.count) * (cellH + gap) + gap
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
NSColor(white: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func label(_ s: String, at p: NSPoint, size: CGFloat = 12, bold: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)]).draw(at: p)
}

for (i, title) in ["Original photo", "Lossless fit (default)", "Full bleed (per photo)"].enumerated() {
    label(title, at: NSPoint(x: labelW + gap + CGFloat(i) * (cellW + gap), y: height - 24), bold: true)
}

for (row, (name, w, h)) in shapes.enumerated() {
    let top = height - headH - CGFloat(row) * (cellH + gap) - gap
    let y = top - cellH
    label(name, at: NSPoint(x: 10, y: y + cellH / 2 - 7), bold: true)
    let photo = makePhoto(w, h)
    let file = tmp.appendingPathComponent("shape\(row).jpg")
    writeJPEG(photo, to: file)
    let turns = bestTurns(for: file)   // the same decision the app makes on import

    // Original, drawn in its own aspect inside the cell
    let k = min(cellW / CGFloat(w), cellH / CGFloat(h))
    let ow = CGFloat(w) * k, oh = CGFloat(h) * k
    NSImage(cgImage: photo, size: .zero).draw(in: NSRect(x: labelW + gap + (cellW - ow) / 2, y: y + (cellH - oh) / 2, width: ow, height: oh))

    for (col, fill) in [false, true].enumerated() {
        let page = composePage(photo, turns: turns, fill: fill, width: Int(cellW * scale))!
        let rect = NSRect(x: labelW + gap + CGFloat(col + 1) * (cellW + gap), y: y, width: cellW, height: cellH)
        NSColor.white.setFill(); rect.fill()
        NSImage(cgImage: page, size: .zero).draw(in: rect)
        NSColor(white: 0.55, alpha: 1).setStroke(); NSBezierPath(rect: rect).stroke()
    }
}
NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "layout.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
