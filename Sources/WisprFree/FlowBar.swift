import AppKit
import SwiftUI

/// The pill at the bottom of the screen: a small bar at rest (hidden if you turn it off), a live waveform while you
/// talk, controls when hands-free, a shimmer while the words are written, and a short note when something needs saying.
@MainActor
final class FlowBar {
  static let shared = FlowBar()
  private var panel: NSPanel?
  private let size = NSSize(width: 360, height: 76)

  func show() {
    let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    p.isFloatingPanel = true
    p.level = .statusBar
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    let host = NSHostingView(rootView: FlowBarView(dictation: .shared, prefs: .shared))
    host.frame = NSRect(origin: .zero, size: size)
    p.contentView = host
    panel = p
    place()
    p.orderFrontRegardless()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
      Task { @MainActor in FlowBar.shared.place() }
    }
    // Follows the screen with the pointer, as Wispr Flow's bar does.
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in FlowBar.shared.place() } }
  }

  func place() {
    guard let panel else { return }
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let f = screen?.visibleFrame else { return }
    let origin = NSPoint(x: f.midX - size.width / 2, y: f.minY + 4)
    if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
  }

  func setInteractive(_ on: Bool) { panel?.ignoresMouseEvents = !on }
}

struct FlowBarView: View {
  @ObservedObject var dictation: Dictation
  @ObservedObject var prefs: Prefs
  @State private var hovering = false

  var body: some View {
    VStack {
      Spacer(minLength: 0)
      pill
        .padding(.bottom, 10)
    }
    .frame(width: 360, height: 76)
    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: dictation.phase)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onChange(of: dictation.phase) { _, p in FlowBar.shared.setInteractive(interactive(p)) }
    .onAppear { FlowBar.shared.setInteractive(interactive(dictation.phase)) }
  }

  private func interactive(_ p: Dictation.Phase) -> Bool {
    if case .listening(true) = p { return true }
    if case .idle = p { return prefs.showFlowBar }
    return false
  }

  @ViewBuilder private var pill: some View {
    switch dictation.phase {
    case .idle:
      if prefs.showFlowBar { idle } else { Color.clear.frame(width: 1, height: 1) }
    case .listening(let handsFree):
      if handsFree { handsFreePill } else { capsule(Waveform(levels: dictation.levels).frame(width: 70, height: 20), width: 96, height: 32) }
    case .working:
      capsule(Shimmer().frame(width: 70, height: 20), width: 96, height: 32)
    case .message(let text):
      capsule(Text(text).font(Theme.sans(12, .medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 14), width: nil, height: 32)
    }
  }

  private var idle: some View {
    Group {
      if hovering {
        capsule(Text("Hold \(prefs.talkKey.label) to dictate").font(Theme.sans(11, .medium)).foregroundStyle(.white.opacity(0.85))
          .padding(.horizontal, 12), width: nil, height: 26)
          .onTapGesture { dictation.toggleHandsFree() }
      } else {
        Capsule().fill(Color.black.opacity(0.78)).overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
          .frame(width: 44, height: 9)
      }
    }
    .onHover { hovering = $0 }
    .contentShape(Rectangle())
  }

  private var handsFreePill: some View {
    HStack(spacing: 10) {
      Button { dictation.cancel(quietly: true) } label: {
        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.85))
          .frame(width: 22, height: 22).background(Color.white.opacity(0.14), in: Circle())
      }.buttonStyle(.plain)
      Waveform(levels: dictation.levels).frame(width: 70, height: 20)
      Button { dictation.finish() } label: {
        RoundedRectangle(cornerRadius: 2.5).fill(Theme.red).frame(width: 9, height: 9)
          .frame(width: 22, height: 22).background(Theme.red.opacity(0.22), in: Circle())
      }.buttonStyle(.plain)
    }
    .padding(.horizontal, 6)
    .frame(height: 34)
    .background(Capsule().fill(Color.black.opacity(0.92)))
    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
  }

  private func capsule<V: View>(_ content: V, width: CGFloat?, height: CGFloat) -> some View {
    content
      .frame(width: width, height: height)
      .background(Capsule().fill(Color.black.opacity(0.92)))
      .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
      .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
  }
}

/// White bars that follow the voice, newest on the right.
struct Waveform: View {
  let levels: [Float]
  var body: some View {
    HStack(alignment: .center, spacing: 2.5) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
        Capsule().fill(Color.white)
          .frame(width: 2.5, height: max(3, CGFloat(l) * 20))
      }
    }
    .animation(.linear(duration: 0.06), value: levels)
  }
}

/// Bars rippling while the words are written.
struct Shimmer: View {
  var body: some View {
    TimelineView(.animation) { ctx in
      let t = ctx.date.timeIntervalSinceReferenceDate
      HStack(spacing: 2.5) {
        ForEach(0..<14, id: \.self) { i in
          let phase = sin(t * 6 - Double(i) * 0.55)
          Capsule().fill(Color.white.opacity(0.35 + 0.45 * max(0, phase)))
            .frame(width: 2.5, height: 3 + CGFloat(max(0, phase)) * 7)
        }
      }
    }
  }
}
