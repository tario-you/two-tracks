import AppKit
import CoreText
import SwiftUI

/// Wispr Flow's dark theme: warm near-blacks ("vast"), off-white text, and its green for recording.
enum Theme {
  static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
  }
  static let bg = hex(0x1A1A1A)          // background
  static let panel = hex(0x202020)       // background-tertiary
  static let raised = hex(0x2A2A29)
  static let secondary = hex(0x30302F)   // background-secondary, border
  static let border = hex(0x30302F)
  static let text = hex(0xE9E8E1)        // foreground
  static let text2 = hex(0xDEDDD7)
  static let dim = hex(0x9D9C98)         // foreground-tertiary
  static let faint = hex(0x71716E)
  static let primary = hex(0xFCFCFB)     // primary button
  static let onPrimary = hex(0x1A1A1A)
  static let green = hex(0x4FBF78)
  static let lilac = hex(0xD2ACE9)
  static let pink = hex(0xFFBCF2)
  static let red = hex(0xEF4444)
  static let orange = hex(0xF59E0B)

  // Kept for the notetaker views from Two Tracks.
  static let sidebar = bg
  static let bubble = panel
  static let line = border
  static let accent = green

  static func registerFonts() {
    guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
          let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for f in files where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
  }

  /// EB Garamond, Wispr's serif for titles.
  static func serif(_ size: CGFloat) -> Font { .custom("EB Garamond", size: size) }
  /// Figtree, Wispr's sans for everything else.
  static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Figtree", size: size).weight(weight) }
}

struct PrimaryButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.sans(13, .semibold))
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(Theme.primary.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
      .foregroundStyle(Theme.onPrimary)
  }
}

struct QuietButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.sans(13, .medium))
      .padding(.horizontal, 12).padding(.vertical, 7)
      .background(Theme.secondary.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
      .foregroundStyle(Theme.text)
  }
}
