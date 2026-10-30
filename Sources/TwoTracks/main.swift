import AppKit
import ServiceManagement
import SwiftUI

struct TwoTracksApp: App {
  @StateObject private var store: Store
  @StateObject private var recorder: Recorder

  init() {
    let store = Store()
    _store = StateObject(wrappedValue: store)
    _recorder = StateObject(wrappedValue: Recorder(store: store))
    Translator.shared.deliver = { note, line, english in
      store.update(note) { n in
        if let i = n.lines.firstIndex(where: { $0.id == line }) { n.lines[i].english = english }
      }
    }
    // Opens at login; macOS lists it under Login Items the first time.
    try? SMAppService.mainApp.register()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(store)
        .environmentObject(recorder)
        .frame(minWidth: 860, minHeight: 560)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}

// `TwoTracks --probe file.wav` runs a recording through the same segmenter, Whisper and translator
// without the window, printing each line: a check that needs no microphone or call.
if let i = CommandLine.arguments.firstIndex(of: "--probe"), i + 1 < CommandLine.arguments.count {
  Task { await probe(CommandLine.arguments[i + 1]); exit(0) }
  RunLoop.main.run()
} else {
  TwoTracksApp.main()
}
