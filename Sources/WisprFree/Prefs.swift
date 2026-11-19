import AppKit
import Foundation

/// The key held to dictate: a modifier pressed on its own.
enum TalkKey: String, CaseIterable, Identifiable {
  case fn, rightOption, leftOption, rightCommand, rightControl, rightShift
  var id: String { rawValue }
  var keyCode: Int64 {
    switch self {
    case .fn: 63
    case .rightOption: 61
    case .leftOption: 58
    case .rightCommand: 54
    case .rightControl: 62
    case .rightShift: 60
    }
  }
  var label: String {
    switch self {
    case .fn: "fn"
    case .rightOption: "Right ⌥"
    case .leftOption: "Left ⌥"
    case .rightCommand: "Right ⌘"
    case .rightControl: "Right ⌃"
    case .rightShift: "Right ⇧"
    }
  }
  static func from(keyCode: Int) -> TalkKey? { allCases.first { $0.keyCode == Int64(keyCode) } }
}

/// How dictated text reads in each kind of app.
enum Style: String, CaseIterable, Identifiable {
  case formal, casual, veryCasual, excited
  var id: String { rawValue }
  var title: String {
    switch self {
    case .formal: "Formal."
    case .casual: "Casual"
    case .veryCasual: "very casual"
    case .excited: "Excited!"
    }
  }
  var detail: String {
    switch self {
    case .formal: "Caps + Punctuation"
    case .casual: "Caps + Less punctuation"
    case .veryCasual: "No caps + Less punctuation"
    case .excited: "Caps + More exclamations"
    }
  }
  /// Wispr Flow's names for the same styles.
  static func fromWispr(_ s: String) -> Style? {
    switch s.lowercased() {
    case "formal": .formal
    case "casual": .casual
    case "very_casual", "verycasual", "very casual": .veryCasual
    case "excited": .excited
    default: nil
    }
  }
}

enum Category: String, CaseIterable, Identifiable {
  case personal, work, email, other
  var id: String { rawValue }
  var title: String {
    switch self {
    case .personal: "Personal messages"
    case .work: "Work messages"
    case .email: "Email"
    case .other: "Other"
    }
  }
}

@MainActor
final class Prefs: ObservableObject {
  static let shared = Prefs()
  private let d = UserDefaults.standard

  @Published var talkKey: TalkKey { didSet { d.set(talkKey.rawValue, forKey: "talkKey") } }
  @Published var aiFormatting: Bool { didSet { d.set(aiFormatting, forKey: "aiFormatting") } }
  /// Wispr Flow's Auto Cleanup: off keeps every word as spoken ("like", "you know") and only fixes how it's written.
  @Published var cleanup: Bool { didSet { d.set(cleanup, forKey: "cleanup") } }
  /// Starts the notetaker by itself when a call app starts using the microphone, and stops it after the call.
  @Published var autoMeetings: Bool { didSet { d.set(autoMeetings, forKey: "autoMeetings") } }
  @Published var styles: [Category: Style] { didSet { for (c, s) in styles { d.set(s.rawValue, forKey: "style.\(c.rawValue)") } } }
  @Published var languages: [String] { didSet { d.set(languages, forKey: "languages") } }
  @Published var muteWhileDictating: Bool { didSet { d.set(muteWhileDictating, forKey: "muteWhileDictating") } }
  @Published var sounds: Bool { didSet { d.set(sounds, forKey: "sounds") } }
  @Published var showFlowBar: Bool { didSet { d.set(showFlowBar, forKey: "showFlowBar") } }
  @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock"); if App.shared != nil { App.applyDock() } } }
  @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin"); if App.shared != nil { App.applyLogin() } } }
  @Published var micUID: String { didSet { d.set(micUID, forKey: "micUID") } }
  @Published var firstName: String { didSet { d.set(firstName, forKey: "firstName") } }
  @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
  @Published var cloudProject: String { didSet { d.set(cloudProject, forKey: "cloudProject") } }
  /// While Wispr Flow runs it hears the same keys; WisprFree stays quiet until told to take over.
  @Published var alongsideWispr: Bool { didSet { d.set(alongsideWispr, forKey: "alongsideWispr") } }

  private init() {
    talkKey = TalkKey(rawValue: d.string(forKey: "talkKey") ?? "") ?? .fn
    aiFormatting = d.object(forKey: "aiFormatting") as? Bool ?? true
    cleanup = d.object(forKey: "cleanup") as? Bool ?? true
    autoMeetings = d.object(forKey: "autoMeetings") as? Bool ?? true
    var s: [Category: Style] = [:]
    for c in Category.allCases { s[c] = Style(rawValue: d.string(forKey: "style.\(c.rawValue)") ?? "") ?? (c == .email ? .formal : .casual) }
    styles = s
    languages = d.stringArray(forKey: "languages") ?? []
    muteWhileDictating = d.object(forKey: "muteWhileDictating") as? Bool ?? false
    sounds = d.object(forKey: "sounds") as? Bool ?? true
    showFlowBar = d.object(forKey: "showFlowBar") as? Bool ?? true
    showInDock = d.object(forKey: "showInDock") as? Bool ?? true
    launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? true
    micUID = d.string(forKey: "micUID") ?? ""
    firstName = d.string(forKey: "firstName") ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    onboarded = d.bool(forKey: "onboarded")
    cloudProject = d.string(forKey: "cloudProject") ?? ""
    alongsideWispr = d.bool(forKey: "alongsideWispr")
  }

  /// Takes Wispr Flow's settings where it has them: the talk key, styles, languages, sounds, the flow bar, the Dock
  /// icon, muting and the first name. Runs once, on the first launch next to an installed Wispr Flow.
  func adoptWisprSettings() {
    let url = Wispr.root.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let user = (root["prefs"] as? [String: Any])?["user"] as? [String: Any] else { return }
    if let shortcuts = user["shortcuts"] as? [String: String],
       let combo = shortcuts.first(where: { $0.value == "ptt" })?.key, !combo.contains("+"),
       let code = Int(combo), let key = TalkKey.from(keyCode: code) {
      talkKey = key
    }
    if let st = user["personalizationStyles"] as? [String: String] {
      var s = styles
      for c in Category.allCases { if let v = st[c.rawValue].flatMap(Style.fromWispr) { s[c] = v } }
      styles = s
    }
    if let used = user["usedLanguages"] as? [String] {
      let mapped = used.map { $0.lowercased().hasPrefix("zh") ? "zh" : String($0.prefix(2)).lowercased() }
        .filter { Engine.served.contains($0) }
      if !mapped.isEmpty { languages = Array(NSOrderedSet(array: mapped)) as? [String] ?? mapped }
    }
    if let v = user["enableSounds"] as? Bool { sounds = v }
    if let v = user["hideFlowBarPermanently"] as? Bool { showFlowBar = !v }
    if let v = user["hideAppInDock"] as? Bool { showInDock = !v }
    if let v = user["shouldMuteAudio"] as? Bool { muteWhileDictating = v }
    if let v = user["aiFormatting"] as? Bool { aiFormatting = v }
    if let v = user["autoDetectMeetingsEnabled"] as? Bool { autoMeetings = v }
    if let level = (user["autoCleanup"] as? [String: Any])?["level"] as? String { cleanup = level != "none" }
    if let v = user["openAtLogin"] as? Bool { launchAtLogin = v }
    if let v = user["firstName"] as? String, !v.isEmpty { firstName = v }
  }
}
