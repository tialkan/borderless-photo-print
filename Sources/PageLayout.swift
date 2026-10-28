import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Full-size image with its EXIF orientation applied.
func orientedImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)] as CFDictionary)
}

/// Rotates clockwise by whole quarter turns, keeping the colour profile.
func rotated(_ img: CGImage, turns: Int) -> CGImage? {
    let t = ((turns % 4) + 4) % 4
    if t == 0 { return img }
    let w = img.width, h = img.height
    let (ow, oh) = t % 2 == 1 ? (h, w) : (w, h)
    let space = img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
    ctx.rotate(by: -CGFloat(t) * .pi / 2)
    ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
    return ctx.makeImage()
}

/// Quarter turns (0 or 1) that waste the least paper: tries the photo upright and sideways on the
/// portrait 4x6 sheet and keeps the one that prints larger without cropping.
func bestTurns(for url: URL) -> Int {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          var w = p[kCGImagePropertyPixelWidth] as? Int, var h = p[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0 else { return 0 }
    if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }   // EXIF 5-8 are sideways
    let upright = min(2 / Double(w), 3 / Double(h)), sideways = min(2 / Double(h), 3 / Double(w))
    return sideways > upright ? 1 : 0
}

/// One 4x6 portrait sheet (2:3). `fill == false` keeps the whole photo and leaves white margins;
/// `fill == true` covers the sheet and crops the overflow. The layout is done here because the
/// printer's CUPS filter ignores print-scaling.
func composePage(_ img: CGImage, turns: Int, fill: Bool, width: Int) -> CGImage? {
    guard let src = rotated(img, turns: turns) else { return nil }
    let w = width, h = width * 3 / 2
    let space = src.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    let sx = CGFloat(w) / CGFloat(src.width), sy = CGFloat(h) / CGFloat(src.height)
    let s = fill ? max(sx, sy) : min(sx, sy)
    let dw = CGFloat(src.width) * s, dh = CGFloat(src.height) * s
    ctx.draw(src, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
    return ctx.makeImage()
}

/// Renders the finished sheet (600 dpi) to a temporary PNG for CUPS. PNG on purpose: CUPS hands JPEG
/// files straight to the printer, and the HP Smart Tank answered Send-Document for them with
/// client-error-document-unprintable-error. A PNG is rasterised by CUPS itself (image/urf) instead.
func printableURL(for url: URL, tempDir: URL, turns: Int, fill: Bool) -> URL? {
    guard let base = orientedImage(url), let page = composePage(base, turns: turns, fill: fill, width: 2400) else { return nil }
    let out = tempDir.appendingPathComponent(UUID().uuidString + ".png")
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, page, nil)
    return CGImageDestinationFinalize(dest) ? out : nil
}
