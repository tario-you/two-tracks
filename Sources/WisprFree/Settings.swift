import AVFoundation
import AppKit
import SwiftUI

/// Installs the speech models in the background and reports progress to the sidebar.
@MainActor
final class ModelsSetup: ObservableObject {
  static let shared = ModelsSetup()
  @Published private(set) var busy = false
  @Published private(set) var progress = 0.0
  @Published private(set) var status = ""
  @Published private(set) var problem: String?

  func start() {
    guard !busy, !Models.installed else { return }
    busy = true
    problem = nil
    status = "Downloading speech models (\(Models.missingMegabytes) MB, once)"
    Task {
      do {
        try await Models.install { line, share in
          Task { @MainActor in
            ModelsSetup.shared.progress = share
            ModelsSetup.shared.status = "\(line) · \(Int(share * 100))%"
          }
        }
        busy = false
        if !Dictation.shared.standingBy { Engine.shared.warm() }
      } catch {
        busy = false
        problem = "Speech models: \(error.localizedDescription)"
        Log.line("models failed: \(error.localizedDescription)")
      }
    }
  }
}

struct SettingsPage: View {
  @EnvironmentObject var prefs: Prefs
  @EnvironmentObject var lib: Library
  @State private var mics = AudioDevices.inputs()
  @State private var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  @State private var axAllowed = Inserter.trusted
  @State private var imported: String?
  @State private var check: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        PageHeader(title: "Settings", detail: "") { EmptyView() }
        section("Dictation") {
          row("Hold to dictate", "Double-tap it, or press Space while holding, for hands-free. Esc cancels.") {
            Picker("", selection: $prefs.talkKey) { ForEach(TalkKey.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 150)
          }
          row("Microphone", "") {
            Picker("", selection: $prefs.micUID) {
              Text("System default").tag("")
              ForEach(mics) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(width: 220)
          }
          row("Languages", prefs.languages.isEmpty ? "Detected from \(Engine.served.count) languages each time." : "Detected among the ones you speak.") {
            LanguagePicker()
          }
        }
        section("Formatting") {
          row("AI formatting", "Gemini on your Google Cloud project, signed in with gcloud.") { Toggle("", isOn: $prefs.aiFormatting).toggleStyle(.switch).labelsHidden() }
          row("Google Cloud project", "Empty uses gcloud's own project.") {
            TextField("gcloud's project", text: $prefs.cloudProject).textFieldStyle(.roundedBorder).frame(width: 220)
          }
          HStack {
            Button("Check formatting") {
              check = "Checking…"
              Task {
                let t = Date()
                do {
                  let out = try await Vertex.shared.chat(model: Vertex.quick, system: Formatter.systemPrompt(style: nil),
                                                         user: "<transcript>um so this is uh a test of the the formatting</transcript>", timeout: 15)
                  check = String(format: "Works (%.1f s): %@", Date().timeIntervalSince(t), out)
                } catch { check = error.localizedDescription }
              }
            }.buttonStyle(QuietButton())
            if let check { Text(check).font(Theme.sans(12)).foregroundStyle(Theme.dim).lineLimit(2) }
          }
        }
        section("App") {
          row("Open at login", "") { Toggle("", isOn: $prefs.launchAtLogin).toggleStyle(.switch).labelsHidden() }
          row("Show in Dock", "") { Toggle("", isOn: $prefs.showInDock).toggleStyle(.switch).labelsHidden() }
          row("Show the flow bar", "The small bar at the bottom of the screen while you're not dictating.") { Toggle("", isOn: $prefs.showFlowBar).toggleStyle(.switch).labelsHidden() }
          row("Sounds", "A tick when dictation starts and stops.") { Toggle("", isOn: $prefs.sounds).toggleStyle(.switch).labelsHidden() }
          row("Mute audio while dictating", "Your Mac's sound goes quiet while you talk and comes back after.") { Toggle("", isOn: $prefs.muteWhileDictating).toggleStyle(.switch).labelsHidden() }
          row("Your name", "") { TextField("", text: $prefs.firstName).textFieldStyle(.roundedBorder).frame(width: 220) }
        }
        section("Shortcuts") {
          shortcut("Dictate", "Hold \(prefs.talkKey.label)")
          shortcut("Hands-free", "Double-tap \(prefs.talkKey.label)")
          shortcut("Cancel", "Esc")
          shortcut("Paste last transcript", "⌃⌘V")
          shortcut("Copy last transcript", "⌃⌘C")
          shortcut("Start or stop the notetaker", "⌥M")
        }
        section("Permissions") {
          row("Microphone", micAllowed ? "Allowed" : "Needed to hear you.") {
            if !micAllowed { Button("Allow") { AVCaptureDevice.requestAccess(for: .audio) { ok in Task { @MainActor in micAllowed = ok } } }.buttonStyle(QuietButton()) }
            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
          }
          row("Accessibility", axAllowed ? "Allowed" : "Needed to hear the dictation key and type for you.") {
            if !axAllowed { Button("Open settings") { Inserter.askTrust(); openPane("Privacy_Accessibility") }.buttonStyle(QuietButton()) }
            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
          }
        }
        if FileManager.default.fileExists(atPath: Wispr.root.path) {
          section("Wispr Flow") {
            row("Bring over from Wispr Flow", imported ?? "History, dictionary, snippets and settings. Wispr Flow's own files are only read.") {
              Button("Import") {
                let r = lib.importFromWispr()
                prefs.adoptWisprSettings()
                imported = "Added \(r.history) dictations, \(r.words) words and \(r.snippets) snippets."
              }.buttonStyle(QuietButton())
            }
            row("Run alongside Wispr Flow", "Off: WisprFree stands by while Wispr Flow is running, so the same key never types twice.") {
              Toggle("", isOn: $prefs.alongsideWispr).toggleStyle(.switch).labelsHidden()
            }
            if WisprWatch.running { HStack { Spacer(); Button("Quit Wispr Flow") { WisprWatch.quitWispr() }.buttonStyle(QuietButton()) } }
          }
        }
        section("Speech models") {
          row(Models.installed ? "Installed" : "Not installed", "Parakeet (English), Parakeet v3 (24 European languages), X-ASR (Chinese) and Whisper base (names the language). On this Mac; audio never leaves it.") {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Models.dir]) }.buttonStyle(QuietButton())
          }
        }
      }
      .padding(.horizontal, 40).padding(.vertical, 34)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
      axAllowed = Inserter.trusted
      micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
  }

  private func openPane(_ anchor: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
  }

  private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title.uppercased()).font(Theme.sans(11, .semibold)).foregroundStyle(Theme.faint).kerning(0.6).padding(.bottom, 8)
      VStack(alignment: .leading, spacing: 14) { content() }
        .padding(16)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
  }

  private func row<C: View>(_ title: String, _ detail: String, @ViewBuilder _ control: () -> C) -> some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(Theme.sans(14, .medium))
        if !detail.isEmpty { Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true) }
      }
      Spacer()
      control()
    }
  }

  private func shortcut(_ title: String, _ keys: String) -> some View {
    HStack {
      Text(title).font(Theme.sans(14))
      Spacer()
      Text(keys).font(Theme.sans(12, .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
    }
  }
}

struct LanguagePicker: View {
  @EnvironmentObject var prefs: Prefs
  private let names: [(String, String)] = [("en", "English"), ("zh", "Chinese")] + Engine.europe.sorted().map { code in
    (code, Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code)
  }
  var body: some View {
    Menu(prefs.languages.isEmpty ? "Auto" : prefs.languages.map { Locale(identifier: "en").localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", ")) {
      Button(prefs.languages.isEmpty ? "✓ Auto (all)" : "Auto (all)") { prefs.languages = [] }
      Divider()
      ForEach(names, id: \.0) { code, name in
        Button((prefs.languages.contains(code) ? "✓ " : "") + name) {
          if prefs.languages.contains(code) { prefs.languages.removeAll { $0 == code } } else { prefs.languages.append(code) }
        }
      }
    }
    .frame(width: 220)
  }
}

// MARK: Onboarding

struct Onboarding: View {
  @EnvironmentObject var prefs: Prefs
  @State private var step = 0
  @State private var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  @State private var axAllowed = Inserter.trusted
  @State private var wisprRunning = WisprWatch.running
  @State private var tryText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 10) {
        Logo().frame(width: 26, height: 26)
        Text("WisprFree").font(Theme.serif(26))
        Spacer()
        Text("\(step + 1) of 4").font(Theme.sans(12)).foregroundStyle(Theme.dim)
      }
      switch step {
      case 0:
        title("Dictate anywhere on your Mac")
        Text("Hold \(prefs.talkKey.label), speak, let go. Your words land wherever you're typing, cleaned up and in your style. Speech is turned into text on this Mac.")
          .foregroundStyle(Theme.dim)
        if let r = App.imported, r.history + r.words + r.snippets > 0 {
          Label("Brought over from Wispr Flow: \(r.history.formatted()) dictations, \(r.words) words, \(r.snippets) snippets and your settings.", systemImage: "checkmark.circle")
            .foregroundStyle(Theme.green).font(Theme.sans(13))
        }
      case 1:
        title("Let WisprFree hear you")
        permission("Microphone", "To hear what you say while you hold the key.", micAllowed) {
          AVCaptureDevice.requestAccess(for: .audio) { ok in Task { @MainActor in micAllowed = ok } }
        }
        permission("Accessibility", "To notice the dictation key and type the words for you. Turn WisprFree on in the list that opens.", axAllowed) {
          Inserter.askTrust()
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
      case 2:
        title(wisprRunning ? "Wispr Flow is running" : "One key, one app")
        if wisprRunning {
          Text("It listens to the same key, so both would type. Quit it to use WisprFree, or keep both and WisprFree stays on standby while Wispr Flow runs.")
            .foregroundStyle(Theme.dim)
          HStack {
            Button("Quit Wispr Flow") { WisprWatch.quitWispr(); prefs.alongsideWispr = false }.buttonStyle(PrimaryButton())
            Button("Keep both") { prefs.alongsideWispr = false; step += 1 }.buttonStyle(QuietButton())
          }
        } else {
          Text("Nothing else is listening to \(prefs.talkKey.label). You're set.").foregroundStyle(Theme.dim)
        }
      default:
        title("Try it")
        Text("Click the box, hold \(prefs.talkKey.label) and say something. Let go when you're done.").foregroundStyle(Theme.dim)
        TextEditor(text: $tryText).font(Theme.sans(15)).scrollContentBackground(.hidden).frame(height: 110).padding(10)
          .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
      }
      Spacer(minLength: 0)
      HStack {
        if step > 0 { Button("Back") { step -= 1 }.buttonStyle(QuietButton()) }
        Spacer()
        Button(step == 3 ? "Done" : "Continue") {
          if step == 3 { prefs.onboarded = true } else { step += 1 }
        }.buttonStyle(PrimaryButton())
      }
    }
    .padding(30)
    .frame(width: 560, height: 420)
    .background(Theme.panel)
    .foregroundStyle(Theme.text)
    .font(Theme.sans(14))
    .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
      micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      axAllowed = Inserter.trusted
      wisprRunning = WisprWatch.running
      if axAllowed { App.shared?.startKeys() }
    }
  }

  private func title(_ s: String) -> some View { Text(s).font(Theme.serif(30)) }

  private func permission(_ name: String, _ why: String, _ ok: Bool, _ ask: @escaping () -> Void) -> some View {
    HStack(spacing: 14) {
      Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Theme.green : Theme.dim).font(.system(size: 18))
      VStack(alignment: .leading, spacing: 3) {
        Text(name).font(Theme.sans(14, .semibold))
        Text(why).font(Theme.sans(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      if !ok { Button("Allow", action: ask).buttonStyle(QuietButton()) }
    }
    .padding(14)
    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
  }
}
