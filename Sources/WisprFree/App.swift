import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

/// The app shell: a menu bar item, the flow bar, the hub window, the key tap, and the first-launch work (speech models,
/// what Wispr Flow already knows).
@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
  static var shared: App?
  static let store = Store()
  static let recorder = Recorder(store: store)
  static var imported: Library.Imported?

  private var window: NSWindow?
  private var status: NSStatusItem?
  private var keyTimer: Timer?

  func applicationDidFinishLaunching(_ note: Notification) {
    App.shared = self
    OutputMute.restore() // undoes a mute left by a crash mid-dictation
    Theme.registerFonts()
    let prefs = Prefs.shared
    if !UserDefaults.standard.bool(forKey: "wisprImported"), FileManager.default.fileExists(atPath: Wispr.root.path) {
      prefs.adoptWisprSettings()
      App.imported = Library.shared.importFromWispr()
      UserDefaults.standard.set(true, forKey: "wisprImported")
    }
    Translator.shared.deliver = { note, line, english in
      App.store.update(note) { n in
        if let i = n.lines.firstIndex(where: { $0.id == line }) { n.lines[i].english = english }
      }
    }
    App.applyDock()
    App.applyLogin()
    NSApp.mainMenu = menu()
    makeStatusItem()
    FlowBar.shared.show()
    ModelsSetup.shared.start()
    KeyTap.shared.handler = { e in MainActor.assumeIsolated { Dictation.shared.handle(e) } }
    startKeys()
    // Picks up the key tap as soon as Accessibility is allowed, and the talk key when it changes.
    keyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in App.shared?.startKeys() } }
    if prefs.aiFormatting { Vertex.shared.warm() }
    if Models.installed && !Dictation.shared.standingBy { Engine.shared.warm() }
    if !prefs.onboarded || prefs.showInDock { openHub() }
  }

  func startKeys() {
    KeyTap.shared.talkKeyCode = Prefs.shared.talkKey.keyCode
    if !KeyTap.shared.running && Inserter.trusted { KeyTap.shared.start() }
  }

  func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
    openHub()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ note: Notification) {
    OutputMute.restore()
    if App.recorder.recording { App.recorder.stop() }
    Engine.shared.shutdown()
  }

  static func applyDock() {
    NSApp.setActivationPolicy(Prefs.shared.showInDock ? .regular : .accessory)
  }

  static func applyLogin() {
    if Prefs.shared.launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
  }

  func openHub(_ page: Page? = nil) {
    if let page { Navigation.shared.page = page }
    if window == nil {
      let root = HubView()
        .environmentObject(Prefs.shared)
        .environmentObject(Library.shared)
        .environmentObject(Navigation.shared)
        .environmentObject(App.store)
        .environmentObject(App.recorder)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .tint(Theme.green)
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 800),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.isReleasedWhenClosed = false
      w.appearance = NSAppearance(named: .darkAqua)
      w.backgroundColor = NSColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
      w.contentView = NSHostingView(rootView: root)
      w.setFrameAutosaveName("Hub")
      if !w.setFrameUsingName("Hub") { w.center() }
      w.delegate = self
      window = w
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func toggleNotetaker() {
    App.recorder.toggle()
    if App.recorder.recording { openHub(.notetaker) }
  }

  // MARK: Menu bar

  private func makeStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let b = item.button {
      b.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "WisprFree")
      b.image?.isTemplate = true
    }
    let m = NSMenu()
    m.delegate = self
    item.menu = m
    status = item
  }

  private func menu() -> NSMenu {
    let main = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: "About WisprFree", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    app.addItem(.separator())
    app.addItem(withTitle: "Hide WisprFree", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "Quit WisprFree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenu(title: "Edit")
    for (t, a, k) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
      edit.addItem(withTitle: t, action: Selector(a), keyEquivalent: k)
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

  @objc func openSettings() { openHub(.settings) }
  @objc func openHome() { openHub(.home) }
  @objc func notetaker() { toggleNotetaker() }
  @objc func pasteLast() { if let t = Library.shared.last?.text { Inserter.paste(t) } }
  @objc func quitWispr() { WisprWatch.quitWispr() }
}

extension App: NSMenuDelegate {
  func menuNeedsUpdate(_ m: NSMenu) {
    m.removeAllItems()
    let d = Dictation.shared
    let head = NSMenuItem(title: d.standingBy ? "Standing by while Wispr Flow runs" : "Hold \(Prefs.shared.talkKey.label) to dictate", action: nil, keyEquivalent: "")
    head.isEnabled = false
    m.addItem(head)
    if !Inserter.trusted {
      m.addItem(withTitle: "Allow Accessibility to dictate…", action: #selector(openSettings), keyEquivalent: "").target = self
    }
    if d.standingBy { m.addItem(withTitle: "Quit Wispr Flow", action: #selector(quitWispr), keyEquivalent: "").target = self }
    m.addItem(.separator())
    m.addItem(withTitle: App.recorder.recording ? "Stop notetaker" : "Start notetaker", action: #selector(notetaker), keyEquivalent: "").target = self
    let paste = m.addItem(withTitle: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "v")
    paste.keyEquivalentModifierMask = [.command, .control]
    paste.target = self
    paste.isEnabled = Library.shared.last != nil
    m.addItem(.separator())
    m.addItem(withTitle: "Open WisprFree", action: #selector(openHome), keyEquivalent: "").target = self
    m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
    m.addItem(.separator())
    m.addItem(withTitle: "Quit WisprFree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }
}
