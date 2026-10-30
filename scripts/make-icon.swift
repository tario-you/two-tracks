// Draws the app icon into build/AppIcon.icns. Given an .icns (scripts/build-app.sh passes Wispr
// Flow's, when it is installed), that icon gets a "中/EN" tag; otherwise two plain tracks.
// The tagged icon is made on the machine that builds the app and is never committed.
// swift scripts/make-icon.swift [base.icns]
import AppKit

let out = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let base = CommandLine.arguments.count > 1 ? NSImage(contentsOfFile: CommandLine.arguments[1]) : nil

func draw(_ s: CGFloat) {
  if let base {
    base.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    // The tag sits over the bottom of the icon, like a label stuck on it.
    let tag = NSRect(x: s * 0.2, y: s * 0.1, width: s * 0.6, height: s * 0.24)
    NSColor(red: 0.31, green: 0.82, blue: 0.62, alpha: 1).setFill()
    NSBezierPath(roundedRect: tag, xRadius: s * 0.07, yRadius: s * 0.07).fill()
    let text = NSAttributedString(string: "中/EN", attributes: [
      .font: NSFont.systemFont(ofSize: s * 0.15, weight: .heavy),
      .foregroundColor: NSColor(red: 0.08, green: 0.07, blue: 0.12, alpha: 1),
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: tag.midX - size.width / 2, y: tag.midY - size.height / 2))
    return
  }
  let inset = s * 0.1
  NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1).setFill()
  NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: s * 0.18, yRadius: s * 0.18).fill()
  for (y, w, c) in [(0.56, 0.5, NSColor(white: 0.92, alpha: 1)), (0.32, 0.36, NSColor(red: 0.31, green: 0.82, blue: 0.62, alpha: 1))] {
    c.setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.25, y: s * y, width: s * w, height: s * 0.12), xRadius: s * 0.06, yRadius: s * 0.06).fill()
  }
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  draw(CGFloat(px))
  NSGraphicsContext.current = nil
  try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
