import Foundation
import WhisperKit

/// On-device speech to text with Whisper large-v3 turbo. Each utterance gets its own language,
/// so a call that moves between Chinese and English is written down in whichever was spoken.
actor Transcriber {
  static let shared = Transcriber()
  static let model = "openai_whisper-large-v3-v20240930_turbo_632MB"

  enum State: Equatable { case idle, downloading(Double), loading, ready, failed(String) }

  private var whisper: WhisperKit?
  private var loading: Task<WhisperKit, Error>?
  private var onState: (@Sendable (State) -> Void)?

  func observe(_ f: @escaping @Sendable (State) -> Void) { onState = f }

  private var modelsDir: URL { Store.home.appendingPathComponent("models", isDirectory: true) }

  func prepare() async throws -> WhisperKit {
    if let whisper { return whisper }
    if let loading { return try await loading.value }
    let task = Task<WhisperKit, Error> {
      let report = self.onState
      let folder = try await WhisperKit.download(variant: Self.model, downloadBase: modelsDir) { p in
        report?(.downloading(p.fractionCompleted))
      }
      report?(.loading)
      let w = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error, prewarm: false, load: true, download: false))
      report?(.ready)
      return w
    }
    loading = task
    do {
      let w = try await task.value
      whisper = w
      return w
    } catch {
      loading = nil
      onState?(.failed(error.localizedDescription))
      throw error
    }
  }

  struct Heard { let text: String; let language: String }

  /// nil when Whisper itself judges the clip to be no speech.
  func transcribe(_ samples: [Float]) async throws -> Heard? {
    let w = try await prepare()
    let options = DecodingOptions(
      task: .transcribe, language: nil, temperature: 0, usePrefillPrompt: false, detectLanguage: true,
      skipSpecialTokens: true, withoutTimestamps: true, noSpeechThreshold: 0.6
    )
    let results = try await w.transcribe(audioArray: samples, decodeOptions: options)
    guard let r = results.first else { return nil }
    let segments = r.segments.filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1) }
    let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : Heard(text: text, language: r.language)
  }
}
