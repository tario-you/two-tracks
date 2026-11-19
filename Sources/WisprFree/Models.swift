import Foundation

/// The speech models, kept in ~/Library/Application Support/WisprFree/models. The first launch downloads what is missing
/// (about 1.6 GB, once) from the projects' own releases: sherpa-onnx's for the three transducers and whisper.cpp's for
/// the language detector. A folder named in WISPRFREE_MODEL_CACHE that already holds the same releases is copied instead.
enum Models {
  static let dir = Library.home.appendingPathComponent("models", isDirectory: true)
  static var whisperModel: URL { dir.appendingPathComponent("whisper/ggml-base.bin") }

  struct Pack {
    let key: String            // folder under models/
    let release: String        // sherpa-onnx release folder name, or "" for whisper
    let files: [(from: String, to: String)]
    let megabytes: Int
  }

  static let packs: [Pack] = [
    Pack(key: "parakeet", release: "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming",
         files: [("encoder.int8.onnx", "encoder.int8.onnx"), ("decoder.int8.onnx", "decoder.int8.onnx"),
                 ("joiner.int8.onnx", "joiner.int8.onnx"), ("tokens.txt", "tokens.txt")], megabytes: 630),
    Pack(key: "parakeet-v3", release: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
         files: [("encoder.int8.onnx", "encoder.int8.onnx"), ("decoder.int8.onnx", "decoder.int8.onnx"),
                 ("joiner.int8.onnx", "joiner.int8.onnx"), ("tokens.txt", "tokens.txt")], megabytes: 640),
    Pack(key: "xasr", release: "sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03",
         files: [("encoder-epoch-99-avg-1.int8.onnx", "encoder.int8.onnx"), ("decoder-epoch-99-avg-1.onnx", "decoder.onnx"),
                 ("joiner-epoch-99-avg-1.int8.onnx", "joiner.int8.onnx"), ("tokens.txt", "tokens.txt")], megabytes: 170),
    Pack(key: "whisper", release: "", files: [("ggml-base.bin", "ggml-base.bin")], megabytes: 180),
  ]

  static func complete(_ p: Pack) -> Bool {
    let fm = FileManager.default
    let d = dir.appendingPathComponent(p.key)
    guard p.files.allSatisfy({ fm.fileExists(atPath: d.appendingPathComponent($0.to).path) }) else { return false }
    return p.key != "whisper" || fm.fileExists(atPath: d.appendingPathComponent("ggml-base-encoder.mlmodelc").path)
  }

  static var installed: Bool { packs.allSatisfy(complete) }
  static var missingMegabytes: Int { packs.filter { !complete($0) }.reduce(0) { $0 + $1.megabytes } }

  /// Installs every missing pack. progress gets a line of what is happening and the share done (0...1).
  static func install(progress: @escaping @Sendable (String, Double) -> Void) async throws {
    let todo = packs.filter { !complete($0) }
    let total = Double(todo.reduce(0) { $0 + $1.megabytes })
    var done = 0.0
    for p in todo {
      try await install(p) { share in progress("Downloading speech models", (done + share * Double(p.megabytes)) / max(total, 1)) }
      done += Double(p.megabytes)
    }
    progress("Speech models ready", 1)
  }

  private static func install(_ p: Pack, share: @escaping @Sendable (Double) -> Void) async throws {
    let fm = FileManager.default
    let dest = dir.appendingPathComponent(p.key, isDirectory: true)
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    // A local copy of the same release, when one is named.
    if let cache = ProcessInfo.processInfo.environment["WISPRFREE_MODEL_CACHE"] {
      let src = URL(fileURLWithPath: cache).appendingPathComponent(p.release.isEmpty ? "whisper" : p.release)
      if p.files.allSatisfy({ fm.fileExists(atPath: src.appendingPathComponent($0.from).path) }) {
        for f in p.files { try copy(src.appendingPathComponent(f.from), dest.appendingPathComponent(f.to)) }
        if p.key == "whisper" { try await encoder(into: dest, cache: src) }
        return
      }
    }
    let tmp = fm.temporaryDirectory.appendingPathComponent("wisprfree-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    if p.key == "whisper" {
      let bin = try await download(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!, share: { share($0 * 0.8) })
      try copy(bin, dest.appendingPathComponent("ggml-base.bin"))
      try await encoder(into: dest, cache: nil)
      share(1)
      return
    }
    let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(p.release).tar.bz2")!
    let archive = try await download(url, share: share)
    try run("/usr/bin/tar", ["xjf", archive.path, "-C", tmp.path])
    let src = tmp.appendingPathComponent(p.release)
    for f in p.files { try copy(src.appendingPathComponent(f.from), dest.appendingPathComponent(f.to)) }
  }

  /// whisper.cpp's Core ML encoder for base, beside the model (whisper.cpp loads it by itself).
  private static func encoder(into dest: URL, cache: URL?) async throws {
    let fm = FileManager.default
    let target = dest.appendingPathComponent("ggml-base-encoder.mlmodelc")
    if fm.fileExists(atPath: target.path) { return }
    var zip = cache?.appendingPathComponent("ggml-base-encoder.mlmodelc.zip")
    if zip == nil || !fm.fileExists(atPath: zip!.path) {
      zip = try await download(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-encoder.mlmodelc.zip")!, share: { _ in })
    }
    try run("/usr/bin/ditto", ["-x", "-k", zip!.path, dest.path])
    try? fm.removeItem(at: dest.appendingPathComponent("__MACOSX"))
  }

  private static func copy(_ from: URL, _ to: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
    try fm.copyItem(at: from, to: to) // a clone on APFS: no extra space
  }

  private static func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw ModelError.unpack(args.last ?? tool) }
  }

  private static func download(_ url: URL, share: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let delegate = DownloadProgress(share)
    let (file, response) = try await URLSession.shared.download(from: url, delegate: delegate)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ModelError.download(url.lastPathComponent) }
    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
    try FileManager.default.moveItem(at: file, to: kept)
    return kept
  }

  enum ModelError: LocalizedError {
    case download(String), unpack(String)
    var errorDescription: String? {
      switch self {
      case .download(let f): "Couldn't download \(f)."
      case .unpack(let f): "Couldn't unpack \(f)."
      }
    }
  }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let share: @Sendable (Double) -> Void
  init(_ share: @escaping @Sendable (Double) -> Void) { self.share = share }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    if totalBytesExpectedToWrite > 0 { share(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
  }
}
