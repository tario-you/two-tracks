import AVFoundation
import AppKit

/// Dictation, Wispr Flow's way: hold the talk key and speak, let go and the words land at the cursor. A double tap (or
/// Space while holding) keeps listening hands-free until the next tap; Esc cancels.
@MainActor
final class Dictation: ObservableObject {
  static let shared = Dictation()

  enum Phase: Equatable {
    case idle
    case listening(handsFree: Bool)
    case working
    case message(String)
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var levels: [Float] = Array(repeating: 0, count: 14)
  @Published private(set) var lastError: String?

  private let mic = DictationMic()
  /// Stretches already cut at pauses, being written down while the speaker goes on.
  private let piecesLock = NSLock()
  nonisolated(unsafe) private var pieces: [Task<Engine.Heard?, Never>] = []
  private var started: Date?
  private var target: Inserter.Target?
  private var meter: Timer?
  private var pendingTap: DispatchWorkItem?
  private var limit: DispatchWorkItem?
  private var job: Task<Void, Never>?
  private var messageTimer: DispatchWorkItem?

  var listening: Bool { if case .listening = phase { return true }; return false }

  /// Wispr Flow hears the same keys; WisprFree waits until Wispr Flow quits or is told to run alongside.
  var standingBy: Bool { WisprWatch.running && !Prefs.shared.alongsideWispr }

  func handle(_ e: KeyTap.Event) -> Bool {
    if standingBy && !listening { return false }
    switch e {
    case .talkDown:
      if case .listening(true) = phase { finish(); return false }
      if pendingTap != nil, listening {
        pendingTap?.cancel(); pendingTap = nil
        phase = .listening(handsFree: true)
        return false
      }
      if listening { return false }
      begin()
    case .talkUp:
      guard case .listening(false) = phase, let started else { return false }
      if Date().timeIntervalSince(started) < 0.3 {
        // A tap: a second one soon after turns on hands-free; otherwise it was nothing.
        let w = DispatchWorkItem { [weak self] in
          guard let self, self.pendingTap != nil else { return }
          self.pendingTap = nil
          self.cancel(quietly: true)
        }
        pendingTap = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
      } else {
        finish()
      }
    case .space:
      if case .listening(false) = phase { phase = .listening(handsFree: true); return true }
    case .chord:
      // The talk key was used as a modifier (⌥ + a letter): not dictation.
      if case .listening(false) = phase, let started, Date().timeIntervalSince(started) < 1.5 { cancel(quietly: true) }
    case .escape:
      if listening || phase == .working { cancel(quietly: false); return true }
    case .pasteLast:
      if let t = Library.shared.last?.text { Inserter.paste(t); return true }
    case .copyLast:
      if let t = Library.shared.last?.text { Inserter.copy(t); show("Copied last transcript"); return true }
    case .meeting:
      App.shared?.toggleNotetaker()
      return true
    }
    return false
  }

  /// Hands-free from the flow bar or the menu.
  func toggleHandsFree() {
    if listening { finish() } else { begin(); phase = .listening(handsFree: true) }
  }

  func begin() {
    guard !listening else { return }
    job?.cancel()
    messageTimer?.cancel()
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { _ in }
      return
    case .denied, .restricted:
      show("Allow the microphone in System Settings")
      return
    default: break
    }
    guard Models.installed else { show(ModelsSetup.shared.busy ? "Speech models are still downloading" : "Speech models aren't installed"); return }
    target = Inserter.target()
    let languages = Prefs.shared.languages
    piecesLock.withLock { pieces = [] }
    mic.onPiece = { [weak self] piece in
      guard let self else { return }
      let t = Task.detached(priority: .userInitiated) { await Engine.shared.transcribe(piece, languages: languages) }
      self.piecesLock.withLock { self.pieces.append(t) }
    }
    do { try mic.start(deviceUID: Prefs.shared.micUID) } catch {
      show("Microphone: \(error.localizedDescription)")
      return
    }
    started = Date()
    phase = .listening(handsFree: false)
    if Prefs.shared.muteWhileDictating { OutputMute.mute() }
    if Prefs.shared.sounds { NSSound(named: "Tink")?.play() }
    if Prefs.shared.aiFormatting { Vertex.shared.warm() }
    Engine.shared.warm()
    meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let l = min(1, sqrt(self.mic.level) * 4)
        self.levels = Array(self.levels.dropFirst()) + [l]
      }
    }
    // Wispr Flow stops a dictation at six minutes; so does this.
    let w = DispatchWorkItem { [weak self] in self?.finish() }
    limit = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 360, execute: w)
  }

  private func stopListening() -> [Float] {
    meter?.invalidate(); meter = nil
    limit?.cancel(); limit = nil
    pendingTap?.cancel(); pendingTap = nil
    levels = Array(repeating: 0, count: levels.count)
    let pcm = mic.stop()
    OutputMute.restore()
    return pcm
  }

  func cancel(quietly: Bool) {
    job?.cancel()
    if listening { _ = stopListening() }
    piecesLock.withLock { pieces.forEach { $0.cancel() }; pieces = [] }
    started = nil
    phase = .idle
    if !quietly { show("Cancelled") }
  }

  func finish() {
    guard listening, let started else { return }
    let tail = stopListening()
    let earlier = piecesLock.withLock { () -> [Task<Engine.Heard?, Never>] in
      let p = pieces
      pieces = []
      return p
    }
    self.started = nil
    if Prefs.shared.sounds { NSSound(named: "Pop")?.play() }
    let seconds = Date().timeIntervalSince(started)
    let target = self.target ?? Inserter.target()
    phase = .working
    let prefs = Prefs.shared, lib = Library.shared
    let settings = Formatter.Settings(ai: prefs.aiFormatting, cleanup: prefs.cleanup, styles: prefs.styles, words: lib.words, snippets: lib.snippets)
    let languages = prefs.languages
    job = Task { [weak self] in
      let t0 = Date()
      var parts: [Engine.Heard] = []
      for t in earlier { if let h = await t.value { parts.append(h) } }
      if let h = await Engine.shared.transcribe(tail, languages: languages) { parts.append(h) }
      guard let longest = parts.max(by: { $0.text.count < $1.text.count }) else {
        await MainActor.run { self?.show("No speech heard") }
        return
      }
      let heard = Engine.Heard(text: Engine.join(parts.map(\.text)), language: longest.language, model: longest.model,
                               lidSeconds: parts.reduce(0) { $0 + $1.lidSeconds }, asrSeconds: Date().timeIntervalSince(t0))
      if Task.isCancelled { return }
      let input = Formatter.Input(raw: heard.text, language: heard.language, bundleID: target.bundleID, appName: target.appName,
                                  windowTitle: target.windowTitle, before: target.before)
      let out = await Formatter.format(input, settings)
      if Task.isCancelled { return }
      await MainActor.run {
        guard let self else { return }
        let text = Inserter.joined(out.text, after: target.before)
        Inserter.paste(text)
        let words = out.text.split(whereSeparator: \.isWhitespace).count + out.text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        lib.add(HistoryItem(id: UUID().uuidString, date: Date(), raw: heard.text, text: out.text, app: target.bundleID,
                            appName: target.appName, words: words, seconds: seconds, language: heard.language, source: "wisprfree"))
        Log.line(String(format: "dictation %.1fs audio, lid %.2fs, asr %.2fs (%@, %@), format %.2fs (%@), total %.2fs", seconds,
                        heard.lidSeconds, heard.asrSeconds, heard.model, heard.language, out.seconds, out.ai ? "ai" : "rules",
                        Date().timeIntervalSince(t0)))
        self.phase = .idle
      }
    }
  }

  func show(_ text: String) {
    phase = .message(text)
    messageTimer?.cancel()
    let w = DispatchWorkItem { [weak self] in
      if case .message = self?.phase { self?.phase = .idle }
    }
    messageTimer = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
  }
}

/// Whether Wispr Flow is running, kept current from workspace notifications.
@MainActor
enum WisprWatch {
  static let bundleID = "com.electron.wispr-flow"
  static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

  static func quitWispr() {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
  }
}

/// A small log at ~/Library/Logs/WisprFree.log: timings and failures, never the words.
enum Log {
  private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WisprFree.log")
  private static let q = DispatchQueue(label: "wisprfree.log")
  static func line(_ s: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    q.async {
      let data = Data("\(stamp) \(s)\n".utf8)
      if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
      } else {
        try? data.write(to: url)
      }
    }
  }
}
