import CSherpaOnnx
import Foundation
import whisper

/// Speech to text on this Mac, through the English-first router: whisper base names the language of each turn, then one
/// transducer writes it. Parakeet writes English and anything it doesn't place, Parakeet v3 the 24 other European languages
/// it knows, X-ASR Chinese (and the English mixed into it).
final class Engine: @unchecked Sendable {
  static let shared = Engine()

  struct Heard: Sendable {
    let text: String
    let language: String
    let model: String
    let lidSeconds: Double
    let asrSeconds: Double
  }

  enum Model: String, CaseIterable, Sendable { case parakeet, parakeetV3 = "parakeet-v3", xasr }

  /// Parakeet v3's languages besides English.
  static let europe: Set<String> = ["bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
                                    "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
  static let served: [String] = ["en", "zh"] + europe.sorted()

  // The speaker is waiting: speech runs at the highest priority, so a busy Mac's background work waits instead.
  private let queue = DispatchQueue(label: "wisprfree.engine", qos: .userInteractive)
  private var lid: OpaquePointer?
  private var recognizers: [Model: OpaquePointer] = [:]
  private var lastUse: [Model: Date] = [:]
  private var lastTurn = Date()
  private let threads: Int32 = Int32(ProcessInfo.processInfo.environment["WISPRFREE_THREADS"].flatMap(Int.init) ?? 6)

  private init() {
    whisper_log_set({ _, _, _ in }, nil)
    // Memory is the Mac's tight resource: after 20 idle minutes every model leaves memory; the next turn loads again.
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.queue.async { self?.unloadIfIdle() } }
  }

  var ready: Bool { Models.installed }

  /// Loads the language detector and English Parakeet ahead of the first turn.
  func warm() {
    queue.async {
      _ = self.detector()
      _ = self.recognizer(.parakeet)
    }
  }

  func transcribe(_ pcm: [Float], languages: [String]) async -> Heard? {
    await withCheckedContinuation { c in queue.async { c.resume(returning: self.run(pcm, languages)) } }
  }

  /// Same as transcribe, for callers already off the main thread that want to wait.
  func transcribeNow(_ pcm: [Float], languages: [String]) -> Heard? {
    queue.sync { run(pcm, languages) }
  }

  // MARK: The router

  private func run(_ pcm: [Float], _ languages: [String]) -> Heard? {
    lastTurn = Date()
    guard pcm.count > 4_800 else { return nil } // under 0.3 s
    let wanted = languages.filter { Self.served.contains($0) }
    let candidates = wanted.isEmpty ? Self.served : wanted
    let t0 = Date()
    var language = candidates.count == 1 ? candidates[0] : (identify(pcm, among: candidates) ?? "en")
    let lidSeconds = Date().timeIntervalSince(t0)

    let t1 = Date()
    let model: Model = language == "zh" ? .xasr : Self.europe.contains(language) ? .parakeetV3 : .parakeet
    var text = decode(model, pcm)
    // X-ASR writes English it hears in a Chinese turn; a turn it wrote no Chinese in was English misnamed.
    if model == .xasr && !Self.hasHan(text) { language = "en" }
    let asrSeconds = Date().timeIntervalSince(t1)
    text = Self.clean(text)
    guard !text.isEmpty else { return nil }
    return Heard(text: text, language: language, model: model.rawValue, lidSeconds: lidSeconds, asrSeconds: asrSeconds)
  }

  static func hasHan(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
  }

  /// Recognizers sometimes return only punctuation or a lone filler for noise.
  private static func clean(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    return letters.isEmpty ? "" : t
  }

  // MARK: Language

  private func detector() -> OpaquePointer? {
    if let lid { return lid }
    let path = Models.whisperModel.path
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    var cp = whisper_context_default_params()
    cp.use_gpu = true
    cp.flash_attn = true
    lid = whisper_init_from_file_with_params(path, cp)
    return lid
  }

  /// Whisper base's own language detection over the first 30 s, the most likely of the candidates.
  private func identify(_ pcm: [Float], among candidates: [String]) -> String? {
    guard let ctx = detector() else { return nil }
    let n = Int32(min(pcm.count, 16_000 * 30))
    var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
    let mel = pcm.withUnsafeBufferPointer { whisper_pcm_to_mel(ctx, $0.baseAddress, n, threads) }
    guard mel == 0, whisper_lang_auto_detect(ctx, 0, threads, &probs) >= 0 else { return nil }
    func p(_ l: String) -> Float {
      let id = Int(whisper_lang_id(l))
      return id >= 0 && id < probs.count ? probs[id] : 0
    }
    return candidates.max { p($0) < p($1) }
  }

  // MARK: Transducers

  private func recognizer(_ m: Model) -> OpaquePointer? {
    if let r = recognizers[m] { return r }
    let dir = Models.dir.appendingPathComponent(m.rawValue).path
    guard FileManager.default.fileExists(atPath: dir + "/tokens.txt") else { return nil }
    // At most two transducers stay loaded; the one used least recently goes first.
    if recognizers.count >= 2,
       let old = recognizers.keys.min(by: { (lastUse[$0] ?? .distantPast) < (lastUse[$1] ?? .distantPast) }) {
      SherpaOnnxDestroyOfflineRecognizer(recognizers[old])
      recognizers[old] = nil
    }
    var owned: [UnsafeMutablePointer<CChar>] = []
    func s(_ v: String) -> UnsafePointer<CChar> {
      let p = strdup(v)!
      owned.append(p)
      return UnsafePointer(p)
    }
    defer { owned.forEach { free($0) } }
    var c = SherpaOnnxOfflineRecognizerConfig()
    c.feat_config.sample_rate = 16_000
    c.feat_config.feature_dim = 80
    c.model_config.transducer.encoder = s("\(dir)/encoder.int8.onnx")
    c.model_config.transducer.decoder = s("\(dir)/" + (m == .xasr ? "decoder.onnx" : "decoder.int8.onnx"))
    c.model_config.transducer.joiner = s("\(dir)/joiner.int8.onnx")
    c.model_config.tokens = s("\(dir)/tokens.txt")
    c.model_config.num_threads = threads
    c.model_config.model_type = s(m == .xasr ? "" : "nemo_transducer")
    c.model_config.provider = s("cpu")
    c.decoding_method = s("greedy_search")
    guard let r = SherpaOnnxCreateOfflineRecognizer(&c) else { return nil }
    recognizers[m] = r
    return r
  }

  private func decode(_ m: Model, _ pcm: [Float]) -> String {
    guard let r = recognizer(m) else { return "" }
    lastUse[m] = Date()
    // X-ASR's decoder stops early on long audio, so it reads pieces of at most 20 s cut at quiet moments; Parakeet reads
    // a whole turn unless it runs past 90 s.
    let most = m == .xasr ? 20.0 : 90.0
    let parts = Self.pieces(pcm, mostSeconds: most).map { text(r, m == .xasr ? Self.xasrPad($0) : $0) }
    return Self.join(parts)
  }

  private func text(_ r: OpaquePointer, _ pcm: [Float]) -> String {
    guard let s = SherpaOnnxCreateOfflineStream(r) else { return "" }
    defer { SherpaOnnxDestroyOfflineStream(s) }
    pcm.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(s, 16_000, $0.baseAddress, Int32($0.count)) }
    SherpaOnnxDecodeOfflineStream(r, s)
    guard let res = SherpaOnnxGetOfflineStreamResult(s) else { return "" }
    defer { SherpaOnnxDestroyOfflineRecognizerResult(res) }
    guard let t = res.pointee.text else { return "" }
    return String(cString: t).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// X-ASR's encoder takes only frame counts its downsampling divides evenly: silence is added until (T - 7) / 2 is a
  /// multiple of 8, T the 10 ms frames, as the model's own test script pads its features.
  static func xasrPad(_ pcm: [Float]) -> [Float] {
    var n = pcm.count
    while ((max(1, (n - 400) / 160 + 1) - 7) / 2) % 8 != 0 { n += 160 }
    return pcm + [Float](repeating: 0, count: n - pcm.count)
  }

  /// Cuts audio longer than mostSeconds into pieces, each ending at the quietest 100 ms of its last third.
  static func pieces(_ pcm: [Float], mostSeconds: Double) -> [[Float]] {
    let most = Int(mostSeconds * 16_000)
    guard pcm.count > most else { return [pcm] }
    var out: [[Float]] = []
    var start = 0
    while pcm.count - start > most {
      let lo = start + most * 2 / 3, hi = start + most
      var best = hi, bestE = Float.greatestFiniteMagnitude
      var i = lo
      while i + 1_600 <= hi {
        var e: Float = 0
        for j in stride(from: i, to: i + 1_600, by: 4) { e += pcm[j] * pcm[j] }
        if e < bestE { bestE = e; best = i + 800 }
        i += 800
      }
      out.append(Array(pcm[start..<best]))
      start = best
    }
    out.append(Array(pcm[start...]))
    return out
  }

  /// Pieces join with a space between Latin words and nothing between Chinese characters.
  static func join(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.reduce("") { acc, p in
      guard let a = acc.last, let b = p.first else { return acc + p }
      let han = { (c: Character) in c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) } }
      return acc + (han(a) || han(b) ? "" : " ") + p
    }
  }

  /// Frees every model. Called before the process exits: ggml's Metal device asserts at exit while a context is alive.
  func shutdown() {
    queue.sync {
      for (_, r) in recognizers { SherpaOnnxDestroyOfflineRecognizer(r) }
      recognizers = [:]
      if let lid { whisper_free(lid) }
      lid = nil
    }
  }

  private func unloadIfIdle() {
    guard Date().timeIntervalSince(lastTurn) > 20 * 60 else { return }
    for (_, r) in recognizers { SherpaOnnxDestroyOfflineRecognizer(r) }
    recognizers = [:]
    if let lid { whisper_free(lid) }
    lid = nil
  }
}
