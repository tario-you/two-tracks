import AppKit
import CoreGraphics

/// Watches the keyboard through a Quartz event tap (it needs Accessibility): the talk key held on its own, Space while it
/// is held, Esc, and WisprFree's shortcuts. The handler runs on the main thread and returns true to swallow the key.
final class KeyTap {
  static let shared = KeyTap()

  enum Event { case talkDown, talkUp, chord, space, escape, pasteLast, copyLast, meeting }

  var handler: ((Event) -> Bool)?
  var talkKeyCode: Int64 = 63
  private(set) var running = false
  private var tap: CFMachPort?
  private var held = false
  private var swallowedUps = Set<Int64>()

  /// Device-specific modifier bits (IOKit's NX_DEVICE…KEYMASK), so the right and left keys are told apart.
  private static func isDown(_ code: Int64, _ flags: CGEventFlags) -> Bool {
    let raw = flags.rawValue
    switch code {
    case 63: return flags.contains(.maskSecondaryFn)
    case 61: return raw & 0x40 != 0
    case 58: return raw & 0x20 != 0
    case 54: return raw & 0x10 != 0
    case 55: return raw & 0x08 != 0
    case 62: return raw & 0x2000 != 0
    case 59: return raw & 0x01 != 0
    case 60: return raw & 0x04 != 0
    case 56: return raw & 0x02 != 0
    default: return false
    }
  }

  @discardableResult
  func start() -> Bool {
    if running { return true }
    let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask),
      callback: { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        return Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
    self.tap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    running = true
    return true
  }

  private func emit(_ e: Event) -> Bool { handler?(e) ?? false }

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    switch type {
    case .flagsChanged:
      if code == talkKeyCode {
        let down = Self.isDown(code, flags)
        if down && !held { held = true; _ = emit(.talkDown) } else if !down && held { held = false; _ = emit(.talkUp) }
      } else if held {
        _ = emit(.chord)
      }
    case .keyDown:
      if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
        return swallowedUps.contains(code) ? nil : Unmanaged.passUnretained(event)
      }
      var swallow = false
      if held && code == 49 {
        swallow = emit(.space)
      } else if code == 53 {
        swallow = emit(.escape)
      } else {
        let mods = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if mods == [.maskCommand, .maskControl] && code == 9 { swallow = emit(.pasteLast) }
        else if mods == [.maskCommand, .maskControl] && code == 8 { swallow = emit(.copyLast) }
        else if mods == [.maskAlternate] && code == 46 { swallow = emit(.meeting) }
        else if held { _ = emit(.chord) }
      }
      if swallow { swallowedUps.insert(code); return nil }
    case .keyUp:
      if swallowedUps.remove(code) != nil { return nil }
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }
}
