import AppKit
import Foundation
import SQLite3

struct HistoryItem: Identifiable, Equatable {
  var id: String
  var date: Date
  var raw: String
  var text: String
  var app: String
  var appName: String
  var words: Int
  var seconds: Double
  var language: String
  var source: String
}

struct DictEntry: Identifiable, Equatable {
  var id: String
  var phrase: String
  var replacement: String?
  var created: Date
}

struct Snippet: Identifiable, Equatable {
  var id: String
  var trigger: String
  var expansion: String
  var created: Date
}

/// Dictation history, the dictionary and snippets, in ~/Library/Application Support/WisprFree/wisprfree.sqlite.
@MainActor
final class Library: ObservableObject {
  static let shared = Library()
  nonisolated static let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("WisprFree", isDirectory: true)

  struct Stats: Equatable {
    var totalWords = 0
    var wpm = 0
    var weekStreak = 0
    var dayStreak = 0
    var weekWords = 0
  }

  @Published private(set) var recent: [HistoryItem] = []
  @Published private(set) var words: [DictEntry] = []
  @Published private(set) var snippets: [Snippet] = []
  @Published private(set) var stats = Stats()

  let db: SQLiteDB

  private init() {
    try? FileManager.default.createDirectory(at: Library.home, withIntermediateDirectories: true)
    db = SQLiteDB(path: Library.home.appendingPathComponent("wisprfree.sqlite").path)!
    db.run("PRAGMA journal_mode=WAL")
    db.run("""
      CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, ts REAL NOT NULL, raw TEXT NOT NULL, text TEXT NOT NULL,
        app TEXT, app_name TEXT, words INTEGER, seconds REAL, language TEXT, source TEXT)
      """)
    db.run("CREATE INDEX IF NOT EXISTS history_ts ON history(ts)")
    db.run("CREATE TABLE IF NOT EXISTS dictionary (id TEXT PRIMARY KEY, phrase TEXT NOT NULL UNIQUE, replacement TEXT, created REAL)")
    db.run("CREATE TABLE IF NOT EXISTS snippets (id TEXT PRIMARY KEY, trigger TEXT NOT NULL UNIQUE, expansion TEXT NOT NULL, created REAL)")
    reload()
  }

  func reload() {
    recent = history(limit: 400)
    words = db.rows("SELECT id, phrase, replacement, created FROM dictionary ORDER BY created DESC").map {
      DictEntry(id: $0[0] as! String, phrase: $0[1] as! String, replacement: $0[2] as? String, created: Date(timeIntervalSince1970: $0[3] as? Double ?? 0))
    }
    snippets = db.rows("SELECT id, trigger, expansion, created FROM snippets ORDER BY created DESC").map {
      Snippet(id: $0[0] as! String, trigger: $0[1] as! String, expansion: $0[2] as! String, created: Date(timeIntervalSince1970: $0[3] as? Double ?? 0))
    }
    stats = computeStats()
  }

  // MARK: History

  func history(limit: Int, matching query: String = "") -> [HistoryItem] {
    let sql = "SELECT id, ts, raw, text, app, app_name, words, seconds, language, source FROM history"
      + (query.isEmpty ? "" : " WHERE text LIKE ? OR raw LIKE ?") + " ORDER BY ts DESC LIMIT \(limit)"
    let args: [Any?] = query.isEmpty ? [] : ["%\(query)%", "%\(query)%"]
    return db.rows(sql, args).map { r in
      HistoryItem(id: r[0] as! String, date: Date(timeIntervalSince1970: r[1] as? Double ?? 0), raw: r[2] as? String ?? "",
                  text: r[3] as? String ?? "", app: r[4] as? String ?? "", appName: r[5] as? String ?? "",
                  words: r[6] as? Int ?? 0, seconds: r[7] as? Double ?? 0, language: r[8] as? String ?? "", source: r[9] as? String ?? "")
    }
  }

  var last: HistoryItem? { recent.first }

  func add(_ h: HistoryItem) {
    insert(h)
    recent.insert(h, at: 0)
    stats = computeStats()
  }

  private func insert(_ h: HistoryItem) {
    db.run("INSERT OR IGNORE INTO history VALUES (?,?,?,?,?,?,?,?,?,?)",
           [h.id, h.date.timeIntervalSince1970, h.raw, h.text, h.app, h.appName, h.words, h.seconds, h.language, h.source])
  }

  func deleteHistory(_ id: String) {
    db.run("DELETE FROM history WHERE id = ?", [id])
    recent.removeAll { $0.id == id }
    stats = computeStats()
  }

  private func computeStats() -> Stats {
    var s = Stats()
    s.totalWords = db.rows("SELECT COALESCE(SUM(words),0) FROM history").first?[0] as? Int ?? 0
    let monthAgo = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970
    if let r = db.rows("SELECT COALESCE(SUM(words),0), COALESCE(SUM(seconds),0) FROM history WHERE ts > ? AND seconds > 1", [monthAgo]).first,
       let w = r[0] as? Int, let sec = r[1] as? Double ?? (r[1] as? Int).map(Double.init), sec > 0 {
      s.wpm = Int((Double(w) / sec * 60).rounded())
    }
    let weekAgo = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
    s.weekWords = db.rows("SELECT COALESCE(SUM(words),0) FROM history WHERE ts > ?", [weekAgo]).first?[0] as? Int ?? 0
    let cal = Calendar.current
    let days = Set(db.rows("SELECT ts FROM history WHERE ts > ?", [Date().addingTimeInterval(-400 * 86_400).timeIntervalSince1970])
      .compactMap { $0[0] as? Double }.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0)) })
    var d = cal.startOfDay(for: Date())
    if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
    while days.contains(d) { s.dayStreak += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
    let weeks = Set(days.map { cal.dateInterval(of: .weekOfYear, for: $0)!.start })
    var w = cal.dateInterval(of: .weekOfYear, for: Date())!.start
    if !weeks.contains(w) { w = cal.date(byAdding: .weekOfYear, value: -1, to: w)! }
    while weeks.contains(w) { s.weekStreak += 1; w = cal.date(byAdding: .weekOfYear, value: -1, to: w)! }
    return s
  }

  // MARK: Dictionary and snippets

  func addWord(_ phrase: String, replacement: String?) {
    let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !p.isEmpty else { return }
    let r = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
    db.run("INSERT OR REPLACE INTO dictionary VALUES (?,?,?,?)",
           [words.first { $0.phrase.lowercased() == p.lowercased() }?.id ?? UUID().uuidString, p, (r?.isEmpty ?? true) ? nil : r, Date().timeIntervalSince1970])
    reload()
  }

  func deleteWord(_ id: String) {
    db.run("DELETE FROM dictionary WHERE id = ?", [id])
    reload()
  }

  func addSnippet(_ trigger: String, _ expansion: String) {
    let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !expansion.isEmpty else { return }
    db.run("INSERT OR REPLACE INTO snippets VALUES (?,?,?,?)",
           [snippets.first { $0.trigger.lowercased() == t.lowercased() }?.id ?? UUID().uuidString, t, expansion, Date().timeIntervalSince1970])
    reload()
  }

  func deleteSnippet(_ id: String) {
    db.run("DELETE FROM snippets WHERE id = ?", [id])
    reload()
  }

  // MARK: Wispr Flow

  struct Imported { var history = 0; var words = 0; var snippets = 0 }

  /// Copies Wispr Flow's dictation history, dictionary and snippets in, read-only on Wispr's side. Running it again adds
  /// only what is new.
  @discardableResult
  func importFromWispr() -> Imported {
    var got = Imported()
    let path = Wispr.root.appendingPathComponent("flow.sqlite").path
    guard FileManager.default.fileExists(atPath: path), let w = SQLiteDB(path: path, readOnly: true) else { return got }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
    let rows = w.rows("""
      SELECT transcriptEntityId, timestamp, COALESCE(asrText,''), COALESCE(formattedText, asrText, ''), COALESCE(app,''),
             COALESCE(numWords,0), COALESCE(duration,0), COALESCE(detectedLanguage, language, '')
      FROM History WHERE isArchived = 0 AND COALESCE(formattedText, asrText, '') != ''
      """)
    var names: [String: String] = [:]
    db.run("BEGIN")
    for r in rows {
      guard let id = r[0] as? String, let ts = (r[1] as? String).flatMap(parser.date(from:)) else { continue }
      let app = r[4] as? String ?? ""
      if names[app] == nil { names[app] = AppInfo.name(app) }
      let before = db.changes
      insert(HistoryItem(id: id, date: ts, raw: r[2] as? String ?? "", text: (r[3] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                         app: app, appName: names[app] ?? "", words: r[5] as? Int ?? 0,
                         seconds: r[6] as? Double ?? Double(r[6] as? Int ?? 0), language: r[7] as? String ?? "", source: "wispr"))
      if db.changes > before { got.history += 1 }
    }
    db.run("COMMIT")
    for r in w.rows("SELECT phrase, replacement, isSnippet, createdAt FROM Dictionary WHERE isDeleted = 0") {
      guard let phrase = r[0] as? String else { continue }
      let created = (r[3] as? String).flatMap(parser.date(from:))?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
      if (r[2] as? Int ?? 0) == 1, let exp = r[1] as? String {
        if db.rows("SELECT 1 FROM snippets WHERE lower(trigger) = lower(?)", [phrase]).isEmpty {
          db.run("INSERT INTO snippets VALUES (?,?,?,?)", [UUID().uuidString, phrase, exp, created]); got.snippets += 1
        }
      } else if db.rows("SELECT 1 FROM dictionary WHERE lower(phrase) = lower(?)", [phrase]).isEmpty {
        db.run("INSERT INTO dictionary VALUES (?,?,?,?)", [UUID().uuidString, phrase, r[1] as? String, created]); got.words += 1
      }
    }
    reload()
    return got
  }
}

enum AppInfo {
  static func name(_ bundleID: String) -> String {
    guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "" }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }
}

/// A small wrapper over SQLite's C API.
final class SQLiteDB: @unchecked Sendable {
  private var db: OpaquePointer?
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init?(path: String, readOnly: Bool = false) {
    let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
    sqlite3_busy_timeout(db, 3_000)
  }

  deinit { sqlite3_close(db) }

  var changes: Int { Int(sqlite3_total_changes(db)) }

  @discardableResult
  func run(_ sql: String, _ args: [Any?] = []) -> Bool {
    guard let st = prepare(sql, args) else { return false }
    defer { sqlite3_finalize(st) }
    let r = sqlite3_step(st)
    return r == SQLITE_DONE || r == SQLITE_ROW
  }

  func rows(_ sql: String, _ args: [Any?] = []) -> [[Any?]] {
    guard let st = prepare(sql, args) else { return [] }
    defer { sqlite3_finalize(st) }
    var out: [[Any?]] = []
    while sqlite3_step(st) == SQLITE_ROW {
      var row: [Any?] = []
      for i in 0..<sqlite3_column_count(st) {
        switch sqlite3_column_type(st, i) {
        case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(st, i)))
        case SQLITE_FLOAT: row.append(sqlite3_column_double(st, i))
        case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(st, i)))
        case SQLITE_BLOB:
          let n = Int(sqlite3_column_bytes(st, i))
          row.append(n > 0 ? Data(bytes: sqlite3_column_blob(st, i), count: n) : Data())
        default: row.append(nil)
        }
      }
      out.append(row)
    }
    return out
  }

  private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
    for (i, a) in args.enumerated() {
      let idx = Int32(i + 1)
      switch a {
      case let v as String: sqlite3_bind_text(st, idx, v, -1, Self.transient)
      case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
      case let v as Double: sqlite3_bind_double(st, idx, v)
      case let v as Bool: sqlite3_bind_int(st, idx, v ? 1 : 0)
      default: sqlite3_bind_null(st, idx)
      }
    }
    return st
  }
}
