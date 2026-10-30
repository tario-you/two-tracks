// Draws the app icon: two tracks, a light one for what was heard and a green one for English.
// swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  let s = CGFloat(px)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let inset = s * 0.1
  NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1).setFill()
  NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: s * 0.18, yRadius: s * 0.18).fill()
  let bars: [(CGFloat, CGFloat, NSColor)] = [(0.56, 0.5, NSColor(white: 0.92, alpha: 1)), (0.32, 0.36, NSColor(red: 0.31, green: 0.82, blue: 0.62, alpha: 1))]
  for (y, w, c) in bars {
    c.setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.25, y: s * y, width: s * w, height: s * 0.12), xRadius: s * 0.06, yRadius: s * 0.06).fill()
  }
  NSGraphicsContext.current = nil
  try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(name).png"))
}
