import AppKit
import ApplicationServices

/// Starts and stops Wispr Flow's Notetaker from Two Tracks. Wispr has no URL for this, so Start
/// presses Wispr's own notetaker shortcut (read from its settings, so a rebound key still works),
/// which starts a new recording when none is running, and Stop presses the Stop button in Wispr's
/// recorder. Both need Two Tracks to be allowed under Privacy & Security › Accessibility.
enum WisprControl {
  static let bundleID = "com.electron.wispr-flow"

  static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

  /// Asks macOS once; returns whether the permission is already there.
  @discardableResult
  static func trusted(prompt: Bool) -> Bool {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
  }

  /// Wispr stores shortcuts as "keycode+keycode" → action, with macOS virtual key codes.
  static func notetakerShortcut() -> [CGKeyCode]? {
    let url = Wispr.root.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let user = (root["prefs"] as? [String: Any])?["user"] as? [String: Any],
          let shortcuts = user["shortcuts"] as? [String: String],
          let combo = shortcuts.first(where: { $0.value == "open_meeting_recorder" })?.key else { return nil }
    let codes = combo.split(separator: "+").compactMap { CGKeyCode($0) }
    return codes.isEmpty ? nil : codes
  }

  private static let modifierFlags: [CGKeyCode: CGEventFlags] = [
    54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift,
    58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn,
  ]

  enum Failure: LocalizedError {
    case notInstalled, noShortcut, notTrusted, noStopButton
    var errorDescription: String? {
      switch self {
      case .notInstalled: "Wispr Flow isn't running."
      case .noShortcut: "Wispr Flow has no Notetaker shortcut set. Add one in Wispr Flow › Settings › Shortcuts."
      case .notTrusted: "Allow Two Tracks under System Settings › Privacy & Security › Accessibility, then press Start again."
      case .noStopButton: "Couldn't find Wispr's Stop button. Stop the recording in Wispr Flow."
      }
    }
  }

  static func pressShortcut() throws {
    guard running else { throw Failure.notInstalled }
    guard let keys = notetakerShortcut() else { throw Failure.noShortcut }
    guard trusted(prompt: true) else { throw Failure.notTrusted }
    let source = CGEventSource(stateID: .hidSystemState)
    let mods = keys.filter { modifierFlags[$0] != nil }
    let flags = mods.reduce(CGEventFlags()) { $0.union(modifierFlags[$1]!) }
    func post(_ key: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
      let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
      e?.flags = f
      e?.post(tap: .cghidEventTap)
      usleep(20_000)
    }
    var held = CGEventFlags()
    for m in mods { held.formUnion(modifierFlags[m]!); post(m, true, held) }
    for k in keys where modifierFlags[k] == nil { post(k, true, flags); post(k, false, flags) }
    for m in mods.reversed() { held.subtract(modifierFlags[m]!); post(m, false, held) }
  }

  /// Presses the button in Wispr's recorder whose label starts with "Stop" ("Stop listening").
  static func pressStop() throws {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Failure.notInstalled }
    guard trusted(prompt: true) else { throw Failure.notTrusted }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    // Electron apps build their accessibility tree only when asked.
    AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows)
    for w in (windows as? [AXUIElement]) ?? [] {
      if let b = find(w, depth: 0) {
        AXUIElementPerformAction(b, kAXPressAction as CFString)
        return
      }
    }
    throw Failure.noStopButton
  }

  private static func isStop(_ v: CFTypeRef?) -> Bool {
    (v as? String)?.trimmingCharacters(in: .whitespaces).hasPrefix("Stop") ?? false
  }

  private static func find(_ e: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < 30 else { return nil }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
    if role as? String == kAXButtonRole as String {
      for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        if isStop(v) { return e }
      }
      // An Electron button's label is often its child's text.
      var kids: CFTypeRef?
      AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
      for k in (kids as? [AXUIElement]) ?? [] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(k, kAXValueAttribute as CFString, &v)
        if isStop(v) { return e }
      }
    }
    var kids: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
    for k in (kids as? [AXUIElement]) ?? [] {
      if let f = find(k, depth: depth + 1) { return f }
    }
    return nil
  }

  /// The meeting Wispr started at or after `since`, once its row appears.
  static func meeting(since: Date) -> Note? {
    Wispr.meetings().first { $0.created >= since.addingTimeInterval(-5) }
  }
}
