import CFNetwork
import Foundation

/// The language models WisprFree calls, none with a key of its own:
/// - Gemini on Google Cloud's Vertex AI, with gcloud's own sign-in and the project gcloud is set to (Settings can name
///   another). Fast enough to format dictation as it lands.
/// - Claude through Claude Code on your Claude plan, for the slower meeting work: summaries, the improved transcript,
///   questions about a meeting, and translation.
enum LLM {
  enum Failure: LocalizedError {
    case notSignedIn, http(Int, String), empty, timeout
    var errorDescription: String? {
      switch self {
      case .notSignedIn: "Sign in to Google Cloud (gcloud auth login) to turn on AI formatting."
      case .http(let c, let m): "The model answered \(c): \(m)"
      case .empty: "The model returned nothing."
      case .timeout: "The model took too long."
      }
    }
  }

  /// The Mac's own proxy, for the command-line tools WisprFree starts (URLSession follows it by itself).
  static var proxyEnvironment: [String: String] {
    guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return [:] }
    var env: [String: String] = [:]
    if (s[kCFNetworkProxiesHTTPSEnable as String] as? Int) == 1, let h = s[kCFNetworkProxiesHTTPSProxy as String] as? String,
       let p = s[kCFNetworkProxiesHTTPSPort as String] as? Int {
      env["HTTPS_PROXY"] = "http://\(h):\(p)"; env["https_proxy"] = env["HTTPS_PROXY"]
    }
    if (s[kCFNetworkProxiesHTTPEnable as String] as? Int) == 1, let h = s[kCFNetworkProxiesHTTPProxy as String] as? String,
       let p = s[kCFNetworkProxiesHTTPPort as String] as? Int {
      env["HTTP_PROXY"] = "http://\(h):\(p)"; env["http_proxy"] = env["HTTP_PROXY"]
    }
    return env
  }

  static var toolPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.local/bin:\(home)/google-cloud-sdk/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  }

  /// Runs a tool and returns its standard output, or nil when it fails or runs past the timeout.
  static func capture(_ path: String, _ args: [String], input: String? = nil, timeout: TimeInterval) async -> String? {
    await withCheckedContinuation { c in
      let p = Process()
      p.executableURL = URL(fileURLWithPath: path)
      p.arguments = args
      var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
      env["PATH"] = toolPath
      env.merge(proxyEnvironment) { _, new in new }
      p.environment = env
      p.currentDirectoryURL = FileManager.default.temporaryDirectory
      let out = Pipe(), inp = Pipe()
      p.standardOutput = out
      p.standardError = FileHandle.nullDevice
      if input == nil { p.standardInput = FileHandle.nullDevice } else { p.standardInput = inp }
      let lock = NSLock()
      var done = false
      func finish(_ s: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        c.resume(returning: s)
      }
      do { try p.run() } catch { finish(nil); return }
      // Read while it runs: a reply bigger than the pipe's buffer would otherwise block the tool before it exits.
      DispatchQueue.global().async {
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        finish(p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
      }
      if let input {
        DispatchQueue.global().async {
          inp.fileHandleForWriting.write(Data(input.utf8))
          try? inp.fileHandleForWriting.close()
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
        finish(nil)
      }
    }
  }
}

/// Gemini on Vertex AI through its OpenAI-compatible endpoint, signed in with gcloud's token (refreshed in the background).
final class Vertex: @unchecked Sendable {
  static let shared = Vertex()
  static let quick = "gemini-3.5-flash-lite"
  static let smart = "gemini-3.8-flash"

  private let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 30
    c.httpMaximumConnectionsPerHost = 4
    c.waitsForConnectivity = false
    return URLSession(configuration: c)
  }()
  private let lock = NSLock()
  private var token: String?
  private var tokenAt = Date.distantPast
  private var projectCache: String?
  private var refreshing: Task<String?, Never>?

  static var gcloud: String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/google-cloud-sdk/bin/gcloud", "/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud",
            "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"].first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  var available: Bool { Vertex.gcloud != nil }

  /// The project to bill: Settings' choice, else gcloud's configured project.
  func project() async -> String? {
    let chosen = await MainActor.run { Prefs.shared.cloudProject }
    if !chosen.isEmpty { return chosen }
    if let p = lock.withLock({ projectCache }) { return p }
    guard let g = Vertex.gcloud,
          let out = await LLM.capture(g, ["config", "get-value", "project"], timeout: 20)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !out.isEmpty, !out.contains(" ") else { return nil }
    lock.withLock { projectCache = out }
    return out
  }

  func accessToken(force: Bool = false) async -> String? {
    if !force, let t = lock.withLock({ Date().timeIntervalSince(tokenAt) < 45 * 60 ? token : nil }) { return t }
    if let r = lock.withLock({ refreshing }) { return await r.value }
    let task = Task<String?, Never> {
      guard let g = Vertex.gcloud,
            let out = await LLM.capture(g, ["auth", "print-access-token"], timeout: 30)?.trimmingCharacters(in: .whitespacesAndNewlines),
            out.hasPrefix("ya29.") else { return nil }
      return out
    }
    lock.withLock { refreshing = task }
    let t = await task.value
    lock.withLock {
      refreshing = nil
      if let t { token = t; tokenAt = Date() }
    }
    return t
  }

  /// Opens the connection ahead of a request (TLS through a proxy costs a few round trips), and refreshes the token.
  func warm() {
    Task {
      _ = await accessToken()
      _ = await project()
      var r = URLRequest(url: URL(string: "https://aiplatform.googleapis.com/")!)
      r.httpMethod = "HEAD"
      r.timeoutInterval = 10
      _ = try? await session.data(for: r)
    }
  }

  func chat(model: String, system: String, user: String, maxTokens: Int = 1_024, timeout: TimeInterval = 30) async throws -> String {
    guard let token = await accessToken(), let project = await project() else { throw LLM.Failure.notSignedIn }
    let url = URL(string: "https://aiplatform.googleapis.com/v1/projects/\(project)/locations/global/endpoints/openapi/chat/completions")!
    var r = URLRequest(url: url)
    r.httpMethod = "POST"
    r.timeoutInterval = timeout
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue(project, forHTTPHeaderField: "x-goog-user-project")
    var body: [String: Any] = [
      "model": "google/\(model)", "max_tokens": maxTokens, "temperature": 0,
      "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
    ]
    // Flash-Lite thinks least at "minimal"; Flash's least is "low".
    body["reasoning_effort"] = model.contains("lite") ? "minimal" : "low"
    r.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: r)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { _ = await accessToken(force: true) }
    guard code == 200 else { throw LLM.Failure.http(code, String(decoding: data.prefix(300), as: UTF8.self)) }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let msg = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
          !msg.isEmpty else { throw LLM.Failure.empty }
    return msg
  }
}

/// Claude through Claude Code on the Claude plan. A launcher named claude-plan, when installed beside claude, picks the
/// plan login with room; otherwise claude itself.
enum ClaudePlan {
  static var path: String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/.local/bin/claude-plan", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// One prompt, one answer, no tools and no saved session. Returns nil when Claude Code is missing or fails.
  static func ask(_ prompt: String, system: String? = nil, model: String? = nil, timeout: TimeInterval = 600) async -> String? {
    guard let path else { return nil }
    var args = ["-p", "--tools", "", "--no-session-persistence", "--output-format", "json"]
    if let model { args += ["--model", model] }
    if let system { args += ["--system-prompt", system] }
    guard let out = await LLM.capture(path, args, input: prompt, timeout: timeout),
          let obj = out.split(separator: "\n").reversed().compactMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
            .first(where: { $0["result"] != nil }),
          (obj["is_error"] as? Bool) != true,
          let text = obj["result"] as? String, !text.isEmpty else { return nil }
    return text
  }
}

/// Meeting work goes to Claude on the plan.
enum Smart {
  static func ask(system: String, user: String, timeout: TimeInterval = 600) async -> String? {
    await ClaudePlan.ask(user, system: system, timeout: timeout)
  }
}
