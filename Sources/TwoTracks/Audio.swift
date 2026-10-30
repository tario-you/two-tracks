import AVFoundation
import CoreAudio

/// Everything downstream works on 16 kHz mono floats, the rate Whisper expects.
let sampleRate: Double = 16_000

final class Resampler {
  private let converter: AVAudioConverter
  private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

  init?(from format: AVAudioFormat) {
    guard let c = AVAudioConverter(from: format, to: out) else { return nil }
    converter = c
  }

  func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 64
    guard let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return [] }
    var fed = false
    var error: NSError?
    converter.convert(to: o, error: &error) { _, status in
      if fed { status.pointee = .noDataNow; return nil }
      fed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let ch = o.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(o.frameLength)))
  }
}

/// Your side: the default microphone, with the system's echo cancellation so the other side
/// coming out of the speakers is not heard twice.
final class MicCapture {
  private let engine = AVAudioEngine()
  private let queue = DispatchQueue(label: "mic")
  var onSamples: (([Float]) -> Void)?

  func start() throws {
    let input = engine.inputNode
    try? input.setVoiceProcessingEnabled(true)
    // Echo cancellation would otherwise turn other apps down while recording.
    input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
    let format = input.outputFormat(forBus: 0)
    guard let resampler = Resampler(from: format) else { throw CaptureError.format }
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      let samples = resampler.convert(buffer)
      self?.queue.async { self?.onSamples?(samples) }
    }
    engine.prepare()
    try engine.start()
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }
}

/// Their side: everything the Mac plays, through a Core Audio process tap (macOS 14.2+).
/// It asks once for "System Audio Recording" and never shows a screen-recording indicator.
final class SystemCapture {
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "system-audio")
  var onSamples: (([Float]) -> Void)?

  func start() throws {
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.uuid = UUID()
    description.muteBehavior = .unmuted
    description.isPrivate = true
    description.name = "Two Tracks"
    try check(AudioHardwareCreateProcessTap(description, &tapID))

    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd))
    guard let format = AVAudioFormat(streamDescription: &asbd), let resampler = Resampler(from: format) else { throw CaptureError.format }

    let output = try defaultOutputUID()
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Two Tracks",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: output,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
    ]
    try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
    try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, _, _, _ in
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
      let samples = resampler.convert(buffer)
      self?.queue.async { self?.onSamples?(samples) }
    })
    try check(AudioDeviceStart(aggregateID, procID))
  }

  func stop() {
    if aggregateID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateID, procID)
      if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
      AudioHardwareDestroyAggregateDevice(aggregateID)
    }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    aggregateID = kAudioObjectUnknown
    tapID = kAudioObjectUnknown
    procID = nil
  }

  private func defaultOutputUID() throws -> String {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device))
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    address.mSelector = kAudioDevicePropertyDeviceUID
    try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid))
    guard let uid else { throw CaptureError.noOutput }
    return uid.takeRetainedValue() as String
  }
}

enum CaptureError: LocalizedError {
  case format, noOutput, status(OSStatus)
  var errorDescription: String? {
    switch self {
    case .format: "This audio format isn't supported."
    case .noOutput: "No audio output device."
    case .status(let s): "Core Audio error \(s)."
    }
  }
}

private func check(_ status: OSStatus) throws {
  if status != noErr { throw CaptureError.status(status) }
}

/// Cuts a stream into utterances: speech that ends in a pause becomes one segment, the way a
/// person would break a transcript into bubbles. The speech threshold follows the noise floor,
/// so a quiet room and a loud call both work.
final class Segmenter {
  struct Segment { let samples: [Float]; let start: Double }

  private let frame = 480 // 30 ms
  private var pending: [Float] = []
  private var speech: [Float] = []
  private var consumed = 0 // samples seen since the start, for timestamps
  private var speechStart = 0
  private var silentFrames = 0
  private var floor: Float = 0.002
  private(set) var level: Float = 0
  var onSegment: ((Segment) -> Void)?
  var onSpeaking: ((Bool) -> Void)?
  private var speaking = false { didSet { if speaking != oldValue { onSpeaking?(speaking) } } }

  func add(_ samples: [Float]) {
    pending += samples
    while pending.count >= frame {
      let chunk = Array(pending.prefix(frame))
      pending.removeFirst(frame)
      step(chunk)
      consumed += frame
    }
  }

  func flush() {
    if speaking { emit() }
  }

  private func step(_ chunk: [Float]) {
    let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
    level = rms
    let threshold = max(floor * 3, 0.006)
    let loud = rms > threshold
    if !speaking {
      floor = floor * 0.97 + min(rms, threshold) * 0.03
      if loud {
        speaking = true
        silentFrames = 0
        speechStart = max(0, consumed - frame * 7)
        speech = Array(lastFrames) + chunk // keep ~200 ms before the onset
      } else {
        lastFrames.append(contentsOf: chunk)
        if lastFrames.count > frame * 7 { lastFrames.removeFirst(lastFrames.count - frame * 7) }
      }
      return
    }
    speech += chunk
    silentFrames = loud ? 0 : silentFrames + 1
    let seconds = Double(speech.count) / sampleRate
    // End on a 0.7 s pause; past 12 s take any 0.25 s pause; never run past 25 s.
    if silentFrames >= 23 || (seconds > 12 && silentFrames >= 8) || seconds > 25 {
      emit()
    }
  }

  private var lastFrames: [Float] = []

  private func emit() {
    let samples = speech
    speech = []
    lastFrames = []
    speaking = false
    let voiced = Double(samples.count) / sampleRate - Double(silentFrames) * 0.03
    silentFrames = 0
    guard voiced > 0.35 else { return }
    onSegment?(Segment(samples: samples, start: Double(speechStart) / sampleRate))
  }
}
