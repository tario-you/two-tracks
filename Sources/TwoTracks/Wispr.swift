import Foundation
import SQLite3

/// Reads Wispr Flow's Notetaker meetings, if Wispr Flow is installed: titles from its database,
/// lines from each meeting's live.ndjson. Nothing of Wispr's is ever written.
enum Wispr {
  static let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Wispr Flow", isDirectory: true)

  static var installed: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("flow.sqlite").path) }

  static func meetings() -> [Note] {
    var db: OpaquePointer?
    let path = root.appendingPathComponent("flow.sqlite").path
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "select id, title, createdAt, endedAt, recordedMs from Meetings where isDeleted = 0 order by createdAt desc limit 200"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
    var out: [Note] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
      guard let id = text(0) else { continue }
      let file = root.appendingPathComponent("meetings/\(id)/live.ndjson")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      var n = Note(id: id, title: text(1) ?? "Untitled", created: text(2).flatMap(parser.date(from:)) ?? Date(), source: .wispr)
      n.live = sqlite3_column_type(stmt, 3) == SQLITE_NULL
      n.duration = Double(sqlite3_column_int64(stmt, 4)) / 1000
      out.append(n)
    }
    return out
  }

  /// Reads lines past `offset` bytes; returns the new lines and the new offset.
  static func lines(_ id: String, from offset: UInt64) -> ([Line], UInt64) {
    let url = root.appendingPathComponent("meetings/\(id)/live.ndjson")
    guard let h = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
    defer { try? h.close() }
    try? h.seek(toOffset: offset)
    let data = h.readDataToEndOfFile()
    guard let lastNL = data.lastIndex(of: 0x0A) else { return ([], offset) }
    var out: [Line] = []
    for raw in data[..<lastNL].split(separator: 0x0A) {
      guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let id = o["id"] as? String,
            let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
            let speaker = o["speaker"] as? [String: Any] else { continue }
      let counts = ((o["nativeLanguageEvidence"] as? [String: Any])?["counts"] as? [[String: Any]]) ?? []
      let ranked = counts.sorted { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
      var lang = ranked.first?["language"] as? String ?? ""
      // A line counts as English only if every word Wispr heard was English.
      if lang == "en", counts.contains(where: { $0["language"] as? String != "en" }) { lang = "mixed" }
      out.append(Line(
        id: id, speaker: speaker["source"] as? String == "mic" ? .you : .them,
        start: (o["startRecordingMs"] as? Double ?? 0) / 1000, text: text, language: lang
      ))
    }
    return (out, offset + UInt64(lastNL) + 1)
  }
}
