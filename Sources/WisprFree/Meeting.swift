import CoreAudio
import Foundation

/// The notetaker: your microphone (You) and whatever the Mac plays (Them) each go through their own segmenter, every
/// utterance through the same speech router as dictation, and its English follows when it was said in another language.
/// When the meeting ends, the transcript is cleaned up into paragraphs with the speakers named, and titled and summarized.
@MainActor
final class Recorder: ObservableObject {
  @Published private(set) var noteID: String?
  @Published private(set) var started: Date?
  @Published private(set) var level: [Speaker: Float] = [.you: 0, .them: 0]
  @Published private(set) var speaking: Set<Speaker> = []
  @Published var problem: String?
  @Published private(set) var improving: Set<String> = []
  @Published private(set) var asking: Set<String> = []

  let store: Store
  private var mic: MicCapture?
  private var system: SystemCapture?
  private var segmenters: [Speaker: Segmenter] = [:]
  private var meter: Timer?
  private var work: AsyncStream<(String, Speaker, Segmenter.Segment)>.Continuation?
  private var worker: Task<Void, Never>?

  init(store: Store) { self.store = store }

  var recording: Bool { noteID != nil }

  func toggle() { recording ? stop() : start() }

  func start() {
    guard !recording else { return }
    problem = nil
    guard Models.installed else { problem = "The speech models are still downloading."; return }
    let note = store.newNote()
    noteID = note.id
    started = Date()
    let languages = Prefs.shared.languages

    let (stream, cont) = AsyncStream<(String, Speaker, Segmenter.Segment)>.makeStream()
    work = cont
    worker = Task.detached { [weak self] in
      for await (id, who, seg) in stream {
        guard let heard = await Engine.shared.transcribe(seg.samples, languages: languages) else { continue }
        await self?.add(id, who, seg.start, heard)
      }
    }
    Engine.shared.warm()

    // Capture callbacks run on audio threads, so they hold their segmenter and the work queue directly.
    for who in [Speaker.you, .them] {
      let s = Segmenter()
      s.onSegment = { @Sendable seg in cont.yield((note.id, who, seg)) }
      s.onSpeaking = { @Sendable [weak self] on in Task { @MainActor in
        if on { self?.speaking.insert(who) } else { self?.speaking.remove(who) }
      } }
      segmenters[who] = s
    }
    let you = segmenters[.you]!, them = segmenters[.them]!
    let mic = MicCapture()
    mic.onSamples = { @Sendable in you.add($0) }
    do { try mic.start(); self.mic = mic } catch { problem = "Microphone: \(error.localizedDescription)" }
    let system = SystemCapture()
    system.onSamples = { @Sendable in them.add($0) }
    do { try system.start(); self.system = system } catch {
      problem = (problem.map { $0 + "\n" } ?? "") + "Call audio: \(error.localizedDescription). Allow WisprFree under System Settings › Privacy & Security › Screen & System Audio Recording."
    }
    meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.level = [.you: self.segmenters[.you]?.level ?? 0, .them: self.segmenters[.them]?.level ?? 0]
      }
    }
  }

  func stop() {
    guard let id = noteID else { return }
    mic?.stop(); system?.stop()
    mic = nil; system = nil
    meter?.invalidate()
    segmenters.values.forEach { $0.flush() }
    segmenters = [:]
    work?.finish()
    let duration = Date().timeIntervalSince(started ?? Date())
    store.update(id) { $0.live = false; $0.duration = duration }
    noteID = nil
    started = nil
    speaking = []
    level = [.you: 0, .them: 0]
    let worker = self.worker
    Task {
      await worker?.value
      try? await Task.sleep(nanoseconds: 3_000_000_000) // the last English lines
      await improve(id)
      await summarize(id)
    }
  }

  private func add(_ id: String, _ who: Speaker, _ start: Double, _ heard: Engine.Heard) {
    let line = Line(id: UUID().uuidString, speaker: who, start: start, text: heard.text, language: heard.language,
                    english: heard.language == "en" ? heard.text : nil)
    store.update(id) { n in
      n.lines.append(line)
      n.lines.sort { $0.start < $1.start }
    }
    Translator.shared.translate(note: id, lines: [line])
  }

  // MARK: After the meeting

  /// Paragraphs instead of fragments: fillers and false starts out, punctuation fixed, misheard words fixed where the
  /// talk makes them obvious, and the speakers named when someone says who they are. Chunks of 120 lines.
  func improve(_ id: String) async {
    guard let note = store.note(id), !note.lines.isEmpty, !improving.contains(id) else { return }
    improving.insert(id)
    defer { improving.remove(id) }
    let me = Prefs.shared.firstName.isEmpty ? "You" : Prefs.shared.firstName
    var out: [Paragraph] = []
    let lines = note.lines
    for chunkStart in stride(from: 0, to: lines.count, by: 120) {
      let chunk = Array(lines[chunkStart..<min(lines.count, chunkStart + 120)])
      let body = chunk.enumerated().map { i, l in "[\(chunkStart + i)] \(l.speaker == .you ? me : "Them"): \(l.text)" }.joined(separator: "\n")
      let system = """
      You turn a raw meeting transcript into a clean one. Lines are "[n] Speaker: words", cut wherever someone paused and \
      written by speech recognition. "\(me)" is the person taking the notes (their microphone); "Them" is everyone heard \
      through the computer.
      Write paragraphs as "[n] Speaker: text", where n is the number of the first line the paragraph comes from, in order.
      - Join a speaker's consecutive lines into paragraphs; start a new paragraph at a change of speaker or of topic, and \
      keep a paragraph under about five sentences.
      - Fix punctuation and capitalization, remove fillers (um, uh, filler "like"), stutters and false starts, and fix words \
      the recognizer clearly misheard. Keep everything else as said, in the language it was said: never summarize, \
      translate or add.
      - Name a speaker in "Them" when the conversation makes it clear who is talking (they introduce themselves or are \
      addressed by name); otherwise keep "Them". Different people in "Them" may get different names.
      Reply with the paragraphs only.
      """
      guard let answer = await Smart.ask(system: system, user: body, timeout: 900) else { break }
      out += parse(answer, lines: lines)
      store.update(id) { $0.paragraphs = out }
    }
  }

  private func parse(_ text: String, lines: [Line]) -> [Paragraph] {
    let pattern = try! NSRegularExpression(pattern: #"^\s*\[(\d+)\]\s*([^:]{1,40}):\s*(.+)$"#)
    return text.split(separator: "\n").compactMap { raw in
      let s = String(raw)
      guard let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s), let c = Range(m.range(at: 3), in: s),
            let n = Int(s[a]) else { return nil }
      let start = n < lines.count ? lines[n].start : (lines.last?.start ?? 0)
      return Paragraph(id: UUID().uuidString, speaker: String(s[b]).trimmingCharacters(in: .whitespaces), start: start,
                       text: String(s[c]).trimmingCharacters(in: .whitespaces))
    }
  }

  func summarize(_ id: String) async {
    guard let note = store.note(id), !note.lines.isEmpty else { return }
    let transcript = transcriptText(note)
    let system = "You write meeting notes. Write in English."
    let user = """
    Here is a meeting transcript (You is the note taker). Write:
    line 1: a title of at most six words, no quotes or punctuation at the end;
    then a blank line, then a summary in Markdown: a few bullet points of what was discussed and decided, \
    then "Action items" with who does what, if any.

    \(transcript)
    """
    guard let text = await Smart.ask(system: system, user: user, timeout: 600)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
    let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
    guard let title = parts.first, !title.isEmpty else { return }
    store.update(id) { n in
      if n.source == .local && n.title == "New note" { n.title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#* ")) }
      n.summary = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
  }

  /// Answers a question about the meeting from its transcript, notes and summary.
  func ask(_ id: String, _ question: String) async {
    guard let note = store.note(id) else { return }
    let turn = ChatTurn(id: UUID().uuidString, question: question, answer: nil)
    store.update(id) { $0.chat = ($0.chat ?? []) + [turn] }
    asking.insert(id)
    defer { asking.remove(id) }
    let system = """
    You answer questions about one meeting from its transcript, the note taker's own notes and the summary. Be brief and \
    concrete; quote short phrases when useful. When the transcript doesn't say, say so. Use Markdown sparingly.
    """
    let earlier = (note.chat ?? []).compactMap { t in t.answer.map { "Q: \(t.question)\nA: \($0)" } }.joined(separator: "\n\n")
    let user = """
    Transcript:
    \(transcriptText(note))

    My notes:
    \(note.notes.isEmpty ? "(none)" : note.notes)

    \(earlier.isEmpty ? "" : "Earlier questions:\n\(earlier)\n\n")Question: \(question)
    """
    var answer = try? await Vertex.shared.chat(model: Vertex.smart, system: system, user: user, maxTokens: 4_000, timeout: 90)
    if answer == nil { answer = await ClaudePlan.ask(user, system: system, timeout: 300) }
    store.update(id) { n in
      if let i = n.chat?.firstIndex(where: { $0.id == turn.id }) { n.chat?[i].answer = answer ?? "Couldn't reach a model. Check AI formatting in Settings." }
    }
  }

  func transcriptText(_ note: Note) -> String {
    if let p = note.paragraphs, !p.isEmpty {
      return p.map { "(\(clock($0.start))) \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
    return note.lines.map { "(\(clock($0.start))) \($0.speaker.label): \($0.text)" }.joined(separator: "\n")
  }
}

func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

/// Follows a Wispr Flow meeting, read-only: its lines from Wispr's live file, English for each.
@MainActor
final class WisprFollower {
  private var id: String?
  private var offset: UInt64 = 0
  private var timer: Timer?
  private let store: Store

  init(store: Store) { self.store = store }

  func follow(_ id: String?) {
    guard id != self.id else { return }
    if let old = self.id { Translator.shared.close(old) }
    timer?.invalidate()
    self.id = id
    offset = 0
    guard let id, store.wispr.contains(where: { $0.id == id }) else { self.id = nil; return }
    let saved = store.savedTranslations(id)
    store.update(id) { $0.lines = [] }
    let tick = { [weak self] in
      guard let self, self.id == id else { return }
      let (new, next) = Wispr.lines(id, from: self.offset)
      self.offset = next
      guard !new.isEmpty else { return }
      let lines = new.map { l -> Line in
        var l = l
        l.english = l.isEnglish ? l.text : saved[l.id]
        return l
      }
      self.store.update(id) { $0.lines += lines }
      Translator.shared.translate(note: id, lines: lines)
    }
    tick()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in tick() } }
  }
}

/// Wispr Flow's automatic meeting notes: when a call app starts using the microphone (Zoom, Meet in a browser, Teams,
/// FaceTime, WeChat, Lark…), the notetaker starts by itself; when no call app has used it for 20 s, it stops.
/// Read from Core Audio's list of which processes are taking microphone input (macOS 14.2+), every 3 s.
@MainActor
final class MeetingWatch {
  static let shared = MeetingWatch()
  private var timer: Timer?
  private var since: Date?
  private var quietSince: Date?
  private(set) var autoStarted = false

  static let callApps = ["us.zoom", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webex", "com.webex", "com.tencent.xinWeChat",
                         "com.tencent.meeting", "com.tencent.qq", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp",
                         "com.electron.lark", "com.bytedance", "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit",
                         "company.thebrowser", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox", "ru.keepcoder.Telegram"]

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in Task { @MainActor in MeetingWatch.shared.tick() } }
  }

  private func tick() {
    let recorder = App.recorder
    let inCall = Prefs.shared.autoMeetings && !Self.micUsers().filter { id in Self.callApps.contains { id.hasPrefix($0) } }.isEmpty
    if inCall {
      quietSince = nil
      if since == nil { since = Date() }
      if !recorder.recording, let s = since, Date().timeIntervalSince(s) >= 6 {
        recorder.start()
        autoStarted = recorder.recording
        if autoStarted { Dictation.shared.show("Notetaker started · ⌥M stops it") }
      }
    } else {
      since = nil
      guard autoStarted, recorder.recording else { autoStarted = false; return }
      if quietSince == nil { quietSince = Date() }
      if let q = quietSince, Date().timeIntervalSince(q) >= 20 {
        recorder.stop()
        autoStarted = false
        Dictation.shared.show("Call ended · notes saved")
      }
    }
  }

  /// Bundle identifiers of the processes taking microphone input right now, WisprFree's own left out.
  static func micUsers() -> [String] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    let mine = Bundle.main.bundleIdentifier ?? ""
    return ids.compactMap { p in
      var run: UInt32 = 0
      var s = UInt32(MemoryLayout<UInt32>.size)
      var r = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      guard AudioObjectGetPropertyData(p, &r, 0, nil, &s, &run) == noErr, run != 0 else { return nil }
      var b = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      var cf: Unmanaged<CFString>?
      var bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard AudioObjectGetPropertyData(p, &b, 0, nil, &bs, &cf) == noErr, let id = cf?.takeRetainedValue() as String?, id != mine else { return nil }
      return id
    }
  }
}
