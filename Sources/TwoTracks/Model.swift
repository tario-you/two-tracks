import Foundation

enum Speaker: String, Codable { case you, them
  var label: String { self == .you ? "You" : "Them" }
}

struct Line: Codable, Identifiable, Equatable {
  var id: String
  var speaker: Speaker
  var start: Double // seconds from the start of the note
  var text: String
  var language: String
  var english: String?
  var isEnglish: Bool { language == "en" }
}

struct Note: Codable, Identifiable, Equatable {
  enum Source: String, Codable { case local, wispr }
  var id: String
  var title: String
  var created: Date
  var duration: Double = 0
  var source: Source = .local
  var live = false
  var lines: [Line] = []
  var notes = ""
  var summary = ""
}

/// Notes live as one JSON file each in ~/Library/Application Support/Two Tracks/notes.
/// Wispr Flow's meetings show beside them read-only; their translations are kept here too.
@MainActor
final class Store: ObservableObject {
  @Published var notes: [Note] = []
  @Published var wispr: [Note] = []

  nonisolated static let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Two Tracks", isDirectory: true)
  private let dir = Store.home.appendingPathComponent("notes", isDirectory: true)
  private var saveTasks: [String: Task<Void, Never>] = [:]

  init() {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    notes = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "json" }
      .compactMap { try? decoder.decode(Note.self, from: Data(contentsOf: $0)) }
      .filter { $0.source == .local }
      .map { var n = $0; n.live = false; return n }
      .sorted { $0.created > $1.created }
  }

  func note(_ id: String?) -> Note? {
    guard let id else { return nil }
    return notes.first { $0.id == id } ?? wispr.first { $0.id == id }
  }

  func newNote() -> Note {
    let n = Note(id: UUID().uuidString, title: "New note", created: Date(), live: true)
    notes.insert(n, at: 0)
    save(n.id)
    return n
  }

  func update(_ id: String, _ change: (inout Note) -> Void) {
    if let i = notes.firstIndex(where: { $0.id == id }) {
      change(&notes[i])
      save(id)
    } else if let i = wispr.firstIndex(where: { $0.id == id }) {
      change(&wispr[i])
      saveTranslations(wispr[i])
    }
  }

  func delete(_ id: String) {
    notes.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
  }

  /// Writes at most twice a second per note, so a busy transcript doesn't thrash the disk.
  private func save(_ id: String) {
    saveTasks[id]?.cancel()
    saveTasks[id] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard let self, !Task.isCancelled, let n = self.notes.first(where: { $0.id == id }) else { return }
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try? encoder.encode(n).write(to: self.dir.appendingPathComponent("\(id).json"), options: .atomic)
    }
  }

  // MARK: Wispr Flow translations

  private var translationsDir: URL { Store.home.appendingPathComponent("wispr-translations", isDirectory: true) }

  func savedTranslations(_ id: String) -> [String: String] {
    (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: translationsDir.appendingPathComponent("\(id).json")))) ?? [:]
  }

  private func saveTranslations(_ n: Note) {
    try? FileManager.default.createDirectory(at: translationsDir, withIntermediateDirectories: true)
    var map: [String: String] = [:]
    for l in n.lines where !l.isEnglish { if let e = l.english { map[l.id] = e } }
    try? JSONEncoder().encode(map).write(to: translationsDir.appendingPathComponent("\(n.id).json"), options: .atomic)
  }
}
