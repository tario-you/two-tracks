// Draws WisprFree's icon into an .iconset folder: a warm near-black tile with an off-white pill holding a waveform.
//   swift scripts/icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ px: Int) -> Data? {
  let s = CGFloat(px)
  guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  // The tile, inset like macOS app icons, with a soft lilac glow.
  let inset = s * 0.1, tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: color(0x000000, 0.45))
  ctx.addPath(path); ctx.setFillColor(color(0x1A1A1A)); ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(path); ctx.clip()
  let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x502B66, 0.9), color(0x1A1A1A, 0)] as CFArray, locations: [0, 1])!
  ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.minY + tile.height * 0.2), startRadius: 0,
                         endCenter: CGPoint(x: tile.midX, y: tile.minY + tile.height * 0.2), endRadius: tile.width * 0.75, options: [])
  ctx.restoreGState()
  // The pill.
  let pw = tile.width * 0.62, ph = tile.width * 0.25
  let pill = CGRect(x: tile.midX - pw / 2, y: tile.midY - ph / 2, width: pw, height: ph)
  ctx.addPath(CGPath(roundedRect: pill, cornerWidth: ph / 2, cornerHeight: ph / 2, transform: nil))
  ctx.setFillColor(color(0xF5F4F0)); ctx.fillPath()
  // The waveform.
  let bars: [CGFloat] = [0.28, 0.5, 0.78, 1.0, 0.7, 0.92, 0.55, 0.32]
  let bw = pw * 0.045, gap = pw * 0.045
  let total = CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap
  var x = pill.midX - total / 2
  for h in bars {
    let bh = ph * 0.62 * h
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: pill.midY - bh / 2, width: bw, height: bh), cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
    ctx.setFillColor(color(0x1A1A1A)); ctx.fillPath()
    x += bw + gap
  }
  guard let image = ctx.makeImage() else { return nil }
  return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  try? draw(px)?.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("icon: \(out.path)")
