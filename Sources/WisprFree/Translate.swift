import Foundation
import Translation

/// The English track. With Claude Code installed, one long-running `claude` per note translates
/// with the whole conversation as context (on your Claude plan, no API key). Without it, Apple's
/// on-device Translation does it line by line.
@MainActor
final class Translator {
  static let shared = Translator()
  /// Where an English line goes once it is ready: (note id, line id, english).
  var deliver: ((String, String, String) -> Void)?

  private var sessions: [String: ClaudeSession] = [:]

  nonisolated static var claudePath: String? { ClaudePlan.path }

  var engineName: String { Self.claudePath == nil ? "Apple Translation" : "Claude" }

  func translate(note: String, lines: [Line]) {
    let todo = lines.filter { !$0.isEnglish && $0.english == nil }
    guard !todo.isEmpty else { return }
    if let path = Self.claudePath {
      let s = sessions[note] ?? ClaudeSession(path: path) { [weak self] id, en in self?.deliver?(note, id, en) }
      sessions[note] = s
      s.enqueue(todo)
    } else {
      for l in todo { appleTranslate(note: note, line: l) }
    }
  }

  /// Translates only lines not yet sent, so calling this on every change is cheap.
  func close(_ note: String) {
    sessions.removeValue(forKey: note)?.stop()
  }

  private var appleSent = Set<String>()
  private func appleTranslate(note: String, line: Line) {
    guard appleSent.insert(line.id).inserted else { return }
    Task {
      var english = "(Apple Translation needs the \(line.language) language: System Settings › General › Language & Region › Translation Languages)"
      // A session made outside SwiftUI needs the macOS 26 SDK (Swift 6.2 and later).
      #if compiler(>=6.2)
      if #available(macOS 26.0, *) {
        let session = TranslationSession(installedSource: Locale.Language(identifier: line.language), target: Locale.Language(identifier: "en"))
        if let r = try? await session.translate(line.text) { english = r.targetText }
      }
      #endif
      deliver?(note, line.id, english)
    }
  }
}

/// One `claude -p` in stream-json mode. Lines waiting go out together as one numbered batch, so a
/// backlog clears in a few calls; while a batch is out, new lines gather for the next one.
final class ClaudeSession {
  private let process = Process()
  private let stdin = Pipe()
  private let stdout = Pipe()
  private var buffer = Data()
  private var queue: [Line] = []
  private var inFlight: [(n: Int, line: Line)] = []
  private var sent = Set<String>()
  private var counter = 0
  private var retried = Set<String>()
  private let deliver: (String, String) -> Void
  private let lock = DispatchQueue(label: "claude-session")

  init(path: String, deliver: @escaping (String, String) -> Void) {
    self.deliver = deliver
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = [
      "-p", "--model", "claude-haiku-5-5",
      "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--tools", "", "--no-session-persistence",
      "--system-prompt",
      "You translate a live meeting transcript into natural English. Each message holds numbered transcript lines like \"[12] Them: ...\", "
        + "possibly cut off mid-sentence or misheard by speech recognition. Reply with one line per input line, in the same order, "
        + "as \"[12] English\", and nothing else: no speaker labels, quotes, notes or alternatives. Use earlier lines for context. "
        + "Keep a trailing dash if a line breaks off.",
    ]
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
    env["PATH"] = LLM.toolPath
    env.merge(LLM.proxyEnvironment) { _, new in new }
    process.environment = env
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      self?.lock.async { self?.read(data) }
    }
    try? process.run()
  }

  func enqueue(_ lines: [Line]) {
    lock.async {
      for l in lines where self.sent.insert(l.id).inserted { self.queue.append(l) }
      self.next()
    }
  }

  func stop() {
    stdout.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate() }
  }

  private func next() {
    guard inFlight.isEmpty, !queue.isEmpty, process.isRunning else { return }
    // Newest first: a live line, or the end of a long meeting where the view sits, comes back
    // before the backlog. Each batch stays in spoken order.
    let batch = queue.suffix(30)
    queue.removeLast(batch.count)
    inFlight = batch.map { counter += 1; return (counter, $0) }
    let content = "Translate into English:\n" + inFlight.map { "[\($0.n)] \($0.line.speaker.label): \($0.line.text)" }.joined(separator: "\n")
    let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(0x0A)
    stdin.fileHandleForWriting.write(data)
  }

  private func read(_ data: Data) {
    buffer.append(data)
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<nl]
      buffer.removeSubrange(buffer.startIndex...nl)
      guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["type"] as? String == "result" else { continue }
      finish(obj["result"] as? String ?? "")
    }
  }

  private func finish(_ text: String) {
    if ProcessInfo.processInfo.environment["TT_DEBUG"] != nil { FileHandle.standardError.write(Data(("RESULT: " + text + "\n").utf8)) }
    var got: [Int: String] = [:]
    let pattern = try! NSRegularExpression(pattern: #"^\s*\[(\d+)\]\s*(.*)$"#)
    for raw in text.split(separator: "\n") {
      let s = String(raw)
      guard let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let nr = Range(m.range(at: 1), in: s), let tr = Range(m.range(at: 2), in: s), let n = Int(s[nr]) else { continue }
      got[n] = String(s[tr]).trimmingCharacters(in: .whitespaces)
    }
    for (n, line) in inFlight {
      if var en = got[n], !en.isEmpty {
        // The batch labels each line "Who:", and the answer sometimes keeps it.
        let label = "\(line.speaker.label):"
        if en.hasPrefix(label) { en = String(en.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
        let d = deliver, id = line.id, e = en
        DispatchQueue.main.async { d(id, e) }
      } else if retried.insert(line.id).inserted {
        queue.append(line)
      }
    }
    inFlight = []
    next()
  }
}
