import AVFoundation
import Foundation

/// Plays a file through the live pipeline as fast as it can: segmenter, then Whisper, then the
/// English track. Prints "start  lang  text  =>  english" for each utterance and the timings.
func probe(_ path: String) async {
  let url = URL(fileURLWithPath: path)
  guard let file = try? AVAudioFile(forReading: url),
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
        (try? file.read(into: buffer)) != nil,
        let resampler = Resampler(from: file.processingFormat) else {
    print("can't read \(path)")
    return
  }
  let samples = resampler.convert(buffer)
  print("audio: \(String(format: "%.1f", Double(samples.count) / sampleRate)) s")

  let t0 = Date()
  _ = try? await Transcriber.shared.prepare()
  print("model ready in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

  var segments: [Segmenter.Segment] = []
  let seg = Segmenter()
  seg.onSegment = { segments.append($0) }
  stride(from: 0, to: samples.count, by: 1600).forEach { seg.add(Array(samples[$0..<min($0 + 1600, samples.count)])) }
  seg.flush()
  print("segments: \(segments.count)")

  var lines: [Line] = []
  let t1 = Date()
  for s in segments {
    guard let heard = try? await Transcriber.shared.transcribe(s.samples) else { continue }
    lines.append(Line(id: UUID().uuidString, speaker: .them, start: s.start, text: heard.text, language: heard.language,
                      english: heard.language == "en" ? heard.text : nil))
  }
  let speech = segments.reduce(0) { $0 + Double($1.samples.count) } / sampleRate
  print("transcribed \(String(format: "%.0f", speech)) s of speech in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")

  let done = DispatchSemaphore(value: 0)
  var english: [String: String] = [:]
  let want = lines.filter { !$0.isEnglish }.count
  await MainActor.run {
    Translator.shared.deliver = { _, id, en in
      english[id] = en
      if english.count == want { done.signal() }
    }
    Translator.shared.translate(note: "probe", lines: lines)
  }
  let t2 = Date()
  if want > 0 {
    await withCheckedContinuation { c in DispatchQueue.global().async { _ = done.wait(timeout: .now() + 180); c.resume() } }
  }
  print("English for \(english.count) of \(want) lines in \(String(format: "%.1f", Date().timeIntervalSince(t2))) s via \(await MainActor.run { Translator.shared.engineName })\n")
  for l in lines {
    print(String(format: "%5.1f", l.start), l.language, l.text, " =>  ", l.english ?? english[l.id] ?? "…")
  }
}
