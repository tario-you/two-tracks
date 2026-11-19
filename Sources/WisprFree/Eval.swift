import AVFoundation
import Foundation

/// Checks that need no microphone, key or window.
///   WisprFree --dictate FILE [--app BUNDLE_ID] [--languages en,zh]   one recording through speech and formatting
///   WisprFree --eval N [--languages en,zh]   the newest N recordings Wispr Flow kept, through WisprFree, beside Wispr's text
///   WisprFree --probe FILE                   a meeting recording through the notetaker's segmenter and speech
enum CLI {
  static func value(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
  }

  @MainActor static var languages: [String] {
    value("--languages")?.split(separator: ",").map(String.init) ?? Prefs.shared.languages
  }

  static func load(_ url: URL) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil,
          let r = Resampler(from: file.processingFormat) else { return nil }
    return r.convert(buffer)
  }

  @MainActor
  static func settings() -> Formatter.Settings {
    let lib = Library.shared
    if lib.words.isEmpty && lib.snippets.isEmpty { lib.importFromWispr() }
    Prefs.shared.adoptWisprSettings()
    return Formatter.Settings(ai: !CommandLine.arguments.contains("--no-ai"), cleanup: Prefs.shared.cleanup, styles: Prefs.shared.styles,
                              words: lib.words, snippets: lib.snippets, timeout: 6)
  }

  @MainActor
  static func dictate(_ path: String) async {
    guard let pcm = load(URL(fileURLWithPath: path)) else { print("can't read \(path)"); return }
    guard Models.installed else { print("speech models missing in \(Models.dir.path)"); return }
    let s = settings()
    let langs = languages
    let t0 = Date()
    guard let heard = await Engine.shared.transcribe(pcm, languages: langs) else { print("no speech"); return }
    let app = value("--app") ?? ""
    let out = await Formatter.format(Formatter.Input(raw: heard.text, language: heard.language, bundleID: app, appName: AppInfo.name(app),
                                                     windowTitle: "", before: nil), s)
    print(String(format: "audio %.1fs | lid %.2fs | asr %.2fs (%@, %@) | format %.2fs (%@, %@) | total %.2fs", Double(pcm.count) / 16_000,
                 heard.lidSeconds, heard.asrSeconds, heard.model, heard.language, out.seconds, out.ai ? "ai" : "rules", out.category,
                 Date().timeIntervalSince(t0)))
    print("heard:     \(heard.text)")
    print("formatted: \(out.text)")
  }

  /// Wispr Flow keeps the audio of recent dictations. Each goes through WisprFree's router and formatter; the report sets
  /// WisprFree's words beside Wispr's (what Wispr heard, and what it pasted) and the time each step took. Rows go to
  /// ~/Library/Application Support/WisprFree/eval, on this Mac only.
  @MainActor
  static func eval(_ n: Int) async {
    guard Models.installed else { print("speech models missing in \(Models.dir.path)"); return }
    let path = Wispr.root.appendingPathComponent("flow.sqlite").path
    guard let w = SQLiteDB(path: path, readOnly: true) else { print("no Wispr Flow history"); return }
    let rows = w.rows("""
      SELECT transcriptEntityId, COALESCE(app,''), asrText, formattedText, audio FROM History
      WHERE audio IS NOT NULL AND length(audio) > 2000 AND asrText IS NOT NULL AND formattedText IS NOT NULL
      ORDER BY timestamp DESC LIMIT ?
      """, [n])
    let s = settings()
    let langs = languages
    let dir = Library.home.appendingPathComponent("eval", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var tsv = "id\tapp\tlanguage\tmodel\tasr_s\tformat_s\tai\twer_vs_wispr_heard\twer_vs_wispr_pasted\twispr_heard\tours_heard\twispr_pasted\tours_pasted\n"
    var asrT: [Double] = [], fmtT: [Double] = [], werHeard: [Double] = [], werPasted: [Double] = [], afterRelease: [Double] = [], aiCount = 0
    var models: [String: Int] = [:]
    for (i, r) in rows.enumerated() {
      guard let id = r[0] as? String, let audio = r[4] as? Data else { continue }
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wf-eval-\(i).wav")
      try? audio.write(to: tmp)
      defer { try? FileManager.default.removeItem(at: tmp) }
      guard let pcm = load(tmp) else { continue }
      // As in the app: stretches cut at pauses are written while the speaker goes on (their time is not counted);
      // the time after release is the last stretch plus formatting.
      var cutter = PauseCutter(), heardSoFar: [Float] = [], pieces: [[Float]] = []
      for at in stride(from: 0, to: pcm.count, by: 1_024) {
        heardSoFar += pcm[at..<min(pcm.count, at + 1_024)]
        pieces += cutter.cut(heardSoFar)
      }
      var parts: [Engine.Heard] = []
      for p in pieces { if let h = await Engine.shared.transcribe(p, languages: langs) { parts.append(h) } }
      let tStart = Date()
      if let h = await Engine.shared.transcribe(Array(heardSoFar[cutter.start...]), languages: langs) { parts.append(h) }
      let tailSeconds = Date().timeIntervalSince(tStart)
      guard let longest = parts.max(by: { $0.text.count < $1.text.count }) else { continue }
      let heard = Engine.Heard(text: Engine.join(parts.map(\.text)), language: longest.language, model: longest.model,
                               lidSeconds: longest.lidSeconds, asrSeconds: tailSeconds)
      let app = r[1] as? String ?? ""
      let out = await Formatter.format(Formatter.Input(raw: heard.text, language: heard.language, bundleID: app, appName: AppInfo.name(app),
                                                       windowTitle: "", before: nil), s)
      let wHeard = r[2] as? String ?? "", wPasted = r[3] as? String ?? ""
      let e1 = wer(reference: wHeard, hypothesis: heard.text), e2 = wer(reference: wPasted, hypothesis: out.text)
      asrT.append(heard.asrSeconds); fmtT.append(out.seconds); werHeard.append(e1); werPasted.append(e2)
      if out.ai { aiCount += 1 }
      models[heard.model, default: 0] += 1
      let clean = { (x: String) in x.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ⏎ ") }
      tsv += [id, app, heard.language, heard.model, String(format: "%.3f", heard.lidSeconds + heard.asrSeconds), String(format: "%.3f", out.seconds),
              out.ai ? "1" : "0", String(format: "%.3f", e1), String(format: "%.3f", e2), clean(wHeard), clean(heard.text), clean(wPasted), clean(out.text)]
        .joined(separator: "\t") + "\n"
      print(String(format: "%3d/%d  %4.1fs audio in %d pieces  after release: words %.2fs (%@) + format %.2fs %@ = %.2fs  differs from Wispr: heard %3.0f%%  pasted %3.0f%%",
                   i + 1, rows.count, Double(pcm.count) / 16_000, pieces.count + 1, tailSeconds, heard.model, out.seconds,
                   out.ai ? "ai" : "rules", tailSeconds + out.seconds, e1 * 100, e2 * 100))
      afterRelease.append(tailSeconds + out.seconds)
    }
    let file = dir.appendingPathComponent("eval-\(Int(Date().timeIntervalSince1970)).tsv")
    try? tsv.write(to: file, atomically: true, encoding: .utf8)
    func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(Double(a.count) * p))] }
    func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    print("")
    print("clips \(asrT.count) | models \(models.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    print(String(format: "after release: median %.2fs, 90th %.2fs | its words step: median %.2fs, 90th %.2fs | formatting: median %.2fs, 90th %.2fs, model used on %d of %d",
                 pct(afterRelease, 0.5), pct(afterRelease, 0.9), pct(asrT, 0.5), pct(asrT, 0.9), pct(fmtT, 0.5), pct(fmtT, 0.9), aiCount, asrT.count))
    print(String(format: "words differing from Wispr Flow: what it heard %.1f%%, what it pasted %.1f%% (mean per clip)",
                 mean(werHeard) * 100, mean(werPasted) * 100))
    print("rows: \(file.path)")
  }

  /// Word error rate on lowercased words without punctuation; Chinese counts each character as a word.
  static func wer(reference: String, hypothesis: String) -> Double {
    func tokens(_ s: String) -> [String] {
      var out: [String] = []
      var word = ""
      for ch in s.lowercased() {
        if ch.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
          if !word.isEmpty { out.append(word); word = "" }
          out.append(String(ch))
        } else if ch.isLetter || ch.isNumber || ch == "'" {
          word.append(ch)
        } else if !word.isEmpty {
          out.append(word); word = ""
        }
      }
      if !word.isEmpty { out.append(word) }
      return out
    }
    let r = tokens(reference), h = tokens(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
      var cur = [i] + Array(repeating: 0, count: h.count)
      for j in stride(from: 1, through: h.count, by: 1) {
        cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
      }
      prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
  }

  /// The notetaker's path on a recording: segmenter, then the router, each utterance with its language.
  static func probe(_ path: String) async {
    guard let samples = load(URL(fileURLWithPath: path)) else { print("can't read \(path)"); return }
    var segments: [Segmenter.Segment] = []
    let seg = Segmenter()
    seg.onSegment = { segments.append($0) }
    stride(from: 0, to: samples.count, by: 1_600).forEach { seg.add(Array(samples[$0..<min($0 + 1_600, samples.count)])) }
    seg.flush()
    let langs = await MainActor.run { languages }
    let t0 = Date()
    for s in segments {
      guard let heard = await Engine.shared.transcribe(s.samples, languages: langs) else { continue }
      print(String(format: "%6.1f", s.start), heard.language, heard.text)
    }
    print(String(format: "%d segments in %.1f s", segments.count, Date().timeIntervalSince(t0)))
  }
}
