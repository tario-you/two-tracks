import AppKit
import ServiceManagement
import SwiftUI

/// An AppKit shell around the SwiftUI views, so the window always opens at launch and comes back
/// when the Dock icon is clicked.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow!
  private var store: Store!
  private var recorder: Recorder!

  @MainActor
  func applicationDidFinishLaunching(_ note: Notification) {
    store = Store()
    recorder = Recorder(store: store)
    let store = store!
    Translator.shared.deliver = { note, line, english in
      store.update(note) { n in
        if let i = n.lines.firstIndex(where: { $0.id == line }) { n.lines[i].english = english }
      }
    }
    let root = RootView()
      .environmentObject(store)
      .environmentObject(recorder)
      .frame(minWidth: 860, minHeight: 560)
      .preferredColorScheme(.dark)
      .tint(Theme.accent)
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = NSHostingView(rootView: root)
    window.setFrameAutosaveName("Main")
    if !window.setFrameUsingName("Main") { window.center() }
    window.makeKeyAndOrderFront(nil)
    NSApp.mainMenu = menu()
    NSApp.activate(ignoringOtherApps: true)
    // Opens at login; macOS lists it under Login Items the first time.
    try? SMAppService.mainApp.register()
  }

  func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
    return true
  }

  private func menu() -> NSMenu {
    let main = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: "Hide Two Tracks", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Two Tracks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenu(title: "Edit")
    for (t, a, k) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
      edit.addItem(withTitle: t, action: Selector(t == "Redo" ? "redo:" : a), keyEquivalent: k)
    }
    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    for m in [app, edit, window] {
      let item = NSMenuItem()
      item.submenu = m
      main.addItem(item)
    }
    return main
  }
}

// `TwoTracks --probe file.wav` runs a recording through the same segmenter, Whisper and translator
// without the window, printing each line: a check that needs no microphone or call.
// `--wispr-start` / `--wispr-stop` drive Wispr Flow's Notetaker the way the Start and Stop buttons do.
if CommandLine.arguments.contains("--wispr-start") || CommandLine.arguments.contains("--wispr-stop") {
  let start = CommandLine.arguments.contains("--wispr-start")
  do {
    let t = Date()
    try start ? WisprControl.pressShortcut() : WisprControl.pressStop()
    if start {
      for _ in 0..<40 { if let m = WisprControl.meeting(since: t) { print("started", m.id); exit(0) }; usleep(250_000) }
      print("no new meeting after 10 s"); exit(1)
    }
    print("stop pressed"); exit(0)
  } catch { print("failed:", error.localizedDescription); exit(1) }
} else if CommandLine.arguments.contains("--translate-test") {
  let s = ClaudeSession(path: Translator.claudePath!) { id, en in print(id, "=>", en) }
  s.enqueue([Line(id: "a", speaker: .them, start: 0, text: "等一下，稍等一下。", language: "zh"),
             Line(id: "b", speaker: .you, start: 1, text: "好的，没问题。", language: "zh")])
  DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("timeout"); exit(1) }
  RunLoop.main.run()
} else if let i = CommandLine.arguments.firstIndex(of: "--probe"), i + 1 < CommandLine.arguments.count {
  Task { await probe(CommandLine.arguments[i + 1]); exit(0) }
  RunLoop.main.run()
} else {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.run()
}
