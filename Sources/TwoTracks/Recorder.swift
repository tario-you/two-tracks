import Foundation

/// Runs a note while it records: your mic and the call's audio each go through their own
/// segmenter, every utterance is transcribed in turn, and its English follows.
@MainActor
final class Recorder: ObservableObject {
  @Published private(set) var noteID: String?
  @Published private(set) var started: Date?
  @Published private(set) var level: [Speaker: Float] = [.you: 0, .them: 0]
  @Published private(set) var speaking: Set<Speaker> = []
  @Published var problem: String?
  @Published private(set) var model: Transcriber.State = .idle

  private let store: Store
  private var mic: MicCapture?
  private var system: SystemCapture?
  private var segmenters: [Speaker: Segmenter] = [:]
  private var meter: Timer?
  private var work: AsyncStream<(String, Speaker, Segmenter.Segment)>.Continuation?
  private var worker: Task<Void, Never>?

  init(store: Store) {
    self.store = store
    Task {
      await Transcriber.shared.observe { s in Task { @MainActor in self.model = s } }
    }
  }

  var recording: Bool { noteID != nil }

  func start() {
    guard !recording else { return }
    problem = nil
    let note = store.newNote()
    noteID = note.id
    started = Date()

    let (stream, cont) = AsyncStream<(String, Speaker, Segmenter.Segment)>.makeStream()
    work = cont
    worker = Task.detached { [weak self] in
      for await (id, who, seg) in stream {
        do {
          guard let heard = try await Transcriber.shared.transcribe(seg.samples) else { continue }
          await self?.add(id, who, seg.start, heard)
        } catch {
          await MainActor.run { self?.problem = "Transcription failed: \(error.localizedDescription)" }
        }
      }
    }
    Task { _ = try? await Transcriber.shared.prepare() }

    // Capture callbacks run on audio threads, so they hold their segmenter and the work queue
    // directly instead of reaching into this main-actor object.
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
      problem = (problem.map { $0 + "\n" } ?? "") + "Call audio: \(error.localizedDescription). Allow Two Tracks under System Settings › Privacy & Security › Screen & System Audio Recording."
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
      // Give the last English lines a moment, then title and summarize.
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard let note = store.note(id), let s = await Summarizer.run(note) else { return }
      store.update(id) { n in
        if n.title == "New note" { n.title = s.title }
        n.summary = s.summary
      }
    }
  }

  private func add(_ id: String, _ who: Speaker, _ start: Double, _ heard: Transcriber.Heard) {
    let line = Line(id: UUID().uuidString, speaker: who, start: start, text: heard.text, language: heard.language,
                    english: heard.language == "en" ? heard.text : nil)
    store.update(id) { n in
      n.lines.append(line)
      n.lines.sort { $0.start < $1.start }
    }
    Translator.shared.translate(note: id, lines: [line])
  }
}

/// Follows a Wispr Flow meeting while it is open: new lines as Wispr writes them, English for each.
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
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in tick() } }
  }
}
