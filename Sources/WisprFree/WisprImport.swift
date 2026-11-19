import Foundation

/// Brings Wispr Flow's meetings into WisprFree as its own notes: the live transcript, Wispr's cleaned-up transcript with
/// its speaker names, the summary and notes, and the recordings (copied as APFS clones, so they take no new space).
/// Wispr Flow's files are only read. Meetings already brought over are skipped.
enum WisprImport {
  static let recordings = Library.home.appendingPathComponent("recordings", isDirectory: true)

  static func meetings(skipping have: Set<String>) -> [Note] {
    let path = Wispr.root.appendingPathComponent("flow.sqlite").path
    guard let db = SQLiteDB(path: path, readOnly: true) else { return [] }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
    let rows = db.rows("""
      SELECT id, title, createdAt, COALESCE(recordedMs, 0), COALESCE(summary, ''), COALESCE(notes, ''), COALESCE(speakerMap, '')
      FROM Meetings WHERE isDeleted = 0 AND isTourDemo = 0 AND (endedAt IS NOT NULL OR importSource IS NOT NULL)
      """)
    let fm = FileManager.default
    var out: [Note] = []
    for r in rows {
      guard let id = r[0] as? String, !have.contains(id) else { continue }
      let folder = Wispr.root.appendingPathComponent("meetings/\(id)")
      guard fm.fileExists(atPath: folder.path) else { continue }
      var n = Note(id: id, title: (r[1] as? String) ?? "Meeting", created: (r[2] as? String).flatMap(parser.date(from:)) ?? Date())
      n.duration = Double(r[3] as? Int ?? 0) / 1000
      n.lines = Wispr.lines(id, from: 0).0
      n.summary = (r[4] as? String) == "Transcript too short to meaningfully summarize" ? "" : (r[4] as? String ?? "")
      n.notes = r[5] as? String ?? ""
      n.paragraphs = refined(folder.appendingPathComponent("refined.ndjson"), names: speakerNames(r[6] as? String ?? ""))
      if n.duration == 0, let last = n.lines.last { n.duration = last.start }
      // The recordings, beside the note.
      let dest = recordings.appendingPathComponent(id, isDirectory: true)
      try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
      for f in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where !f.lastPathComponent.hasPrefix(".") && !f.lastPathComponent.contains(".partial") {
        let to = dest.appendingPathComponent(f.lastPathComponent)
        if !fm.fileExists(atPath: to.path) { try? fm.copyItem(at: f, to: to) }
      }
      if n.lines.isEmpty && (n.paragraphs ?? []).isEmpty { continue }
      out.append(n)
    }
    return out
  }

  /// Speaker number → name, from Wispr's speaker map.
  private static func speakerNames(_ json: String) -> [Int: String] {
    guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let people = o["people"] as? [String: [String: Any]], let assign = o["assignments"] as? [String: [String: Any]] else { return [:] }
    var out: [Int: String] = [:]
    for (k, v) in assign {
      if let n = Int(k), let who = v["consensus"] as? String, let name = people[who]?["name"] as? String, !name.isEmpty { out[n] = name }
    }
    return out
  }

  /// Wispr's cleaned-up transcript: pieces that continue a sentence join the paragraph before them.
  private static func refined(_ url: URL, names: [Int: String]) -> [Paragraph]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    var seen = Set<String>()
    var out: [Paragraph] = []
    for raw in data.split(separator: 0x0A) {
      guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = o["id"] as? String,
            let text = o["text"] as? String, seen.insert(id).inserted else { continue }
      let sp = (o["speaker"] as? [String: Any])?["id"] as? Int ?? 0
      let name = ((o["speaker"] as? [String: Any])?["name"] as? String) ?? names[sp] ?? "Speaker \(sp)"
      let parts = ((o["timestamp"] as? String) ?? "0").split(separator: ":").compactMap { Double($0) }
      let start = parts.reduce(0) { $0 * 60 + $1 }
      if let last = out.last, last.speaker == name, text.first == " " || text.first?.isLowercase == true {
        out[out.count - 1].text += text
      } else {
        out.append(Paragraph(id: id, speaker: name, start: start, text: text.trimmingCharacters(in: .whitespaces)))
      }
    }
    return out.isEmpty ? nil : out
  }
}
