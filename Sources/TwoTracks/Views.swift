import SwiftUI

enum Theme {
  static let bg = Color(red: 0.106, green: 0.106, blue: 0.106)
  static let sidebar = Color(red: 0.082, green: 0.082, blue: 0.082)
  static let bubble = Color(red: 0.153, green: 0.153, blue: 0.153)
  static let line = Color.white.opacity(0.08)
  static let dim = Color.white.opacity(0.5)
  static let accent = Color(red: 0.31, green: 0.82, blue: 0.62)
}

struct RootView: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var recorder: Recorder
  @State private var selection: String?
  @State private var follower: WisprFollower?

  var body: some View {
    HStack(spacing: 0) {
      Sidebar(selection: $selection)
        .frame(width: 270)
      Divider().overlay(Theme.line)
      Group {
        if let id = selection, store.note(id) != nil {
          NoteView(id: id)
        } else {
          EmptyState()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Theme.bg)
    }
    .background(Theme.sidebar)
    .onAppear {
      follower = WisprFollower(store: store)
      if Wispr.installed { store.wispr = Wispr.meetings() }
      selection = store.notes.first?.id ?? store.wispr.first?.id
    }
    .onChange(of: selection) { _, id in follower?.follow(id) }
    .onChange(of: recorder.noteID) { _, id in if let id { selection = id } }
    .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
      if Wispr.installed {
        let fresh = Wispr.meetings()
        // Keep lines already loaded for the meeting on screen.
        store.wispr = fresh.map { m in
          var m = m
          if let old = store.wispr.first(where: { $0.id == m.id }) { m.lines = old.lines }
          return m
        }
      }
    }
  }
}

// MARK: Sidebar

struct Sidebar: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var recorder: Recorder
  @Binding var selection: String?
  @State private var query = ""
  @State private var showWispr = true

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Two Tracks")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.dim)
        .padding(.top, 34)
        .padding(.horizontal, 16)
      StartButton()
        .padding(.horizontal, 12)
      ModelStatus().padding(.horizontal, 16)
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
        TextField("Search", text: $query).textFieldStyle(.plain)
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal, 12)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(groups(store.notes), id: \.0) { title, notes in
            SectionTitle(title)
            ForEach(notes) { NoteRow(note: $0, selection: $selection) }
          }
          if !store.wispr.isEmpty {
            Button { showWispr.toggle() } label: {
              HStack {
                Text("Wispr Flow")
                Image(systemName: "chevron.right").rotationEffect(.degrees(showWispr ? 90 : 0)).font(.system(size: 9, weight: .bold))
              }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            if showWispr {
              ForEach(filter(store.wispr)) { NoteRow(note: $0, selection: $selection) }
            }
          }
        }
        .padding(.bottom, 16)
      }
      .scrollIndicators(.automatic)
    }
  }

  private func filter(_ notes: [Note]) -> [Note] {
    guard !query.isEmpty else { return notes }
    return notes.filter { n in
      n.title.localizedCaseInsensitiveContains(query) || n.lines.contains { $0.text.localizedCaseInsensitiveContains(query) || ($0.english ?? "").localizedCaseInsensitiveContains(query) }
    }
  }

  private func groups(_ notes: [Note]) -> [(String, [Note])] {
    let cal = Calendar.current
    var order: [String] = []
    var map: [String: [Note]] = [:]
    for n in filter(notes) {
      let key = cal.isDateInToday(n.created) ? "Today" : cal.isDateInYesterday(n.created) ? "Yesterday"
        : n.created.formatted(.dateTime.month(.wide).year())
      if map[key] == nil { order.append(key) }
      map[key, default: []].append(n)
    }
    return order.map { ($0, map[$0]!) }
  }
}

struct SectionTitle: View {
  let text: String
  init(_ t: String) { text = t }
  var body: some View {
    Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
      .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
  }
}

struct NoteRow: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var recorder: Recorder
  let note: Note
  @Binding var selection: String?

  var body: some View {
    Button { selection = note.id } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(note.title).lineLimit(1).font(.system(size: 13))
          Text(note.created.formatted(.dateTime.hour().minute()) + (note.duration > 0 ? " · " + minutes(note.duration) : ""))
            .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        Spacer(minLength: 0)
        if recorder.noteID == note.id || note.live { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selection == note.id ? Theme.bubble : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .contextMenu {
      if note.source == .local && recorder.noteID != note.id {
        Button("Delete", role: .destructive) {
          if selection == note.id { selection = nil }
          store.delete(note.id)
        }
      }
    }
  }
}

func minutes(_ s: Double) -> String {
  let m = Int(s) / 60
  return m < 1 ? "<1 min" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
}

struct StartButton: View {
  @EnvironmentObject var recorder: Recorder
  var body: some View {
    Button { recorder.recording ? recorder.stop() : recorder.start() } label: {
      HStack(spacing: 8) {
        if recorder.recording {
          RoundedRectangle(cornerRadius: 3).fill(Theme.accent).frame(width: 12, height: 12)
          Text("Stop")
          Spacer()
          Clock()
        } else {
          Image(systemName: "waveform")
          Text("Start notetaker")
          Spacer()
        }
      }
      .font(.system(size: 14, weight: .semibold))
      .padding(.horizontal, 14).padding(.vertical, 11)
      .background(recorder.recording ? Theme.bubble : Theme.accent, in: RoundedRectangle(cornerRadius: 12))
      .foregroundStyle(recorder.recording ? Color.white : Color.black)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut("n", modifiers: [.command, .shift])
  }
}

struct Clock: View {
  @EnvironmentObject var recorder: Recorder
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let s = Int(ctx.date.timeIntervalSince(recorder.started ?? ctx.date))
      Text(String(format: "%d:%02d", s / 60, s % 60)).monospacedDigit().foregroundStyle(Theme.dim)
    }
  }
}

struct ModelStatus: View {
  @EnvironmentObject var recorder: Recorder
  var body: some View {
    switch recorder.model {
    case .downloading(let p):
      VStack(alignment: .leading, spacing: 4) {
        Text("Downloading the speech model (632 MB), once").font(.system(size: 11)).foregroundStyle(Theme.dim)
        ProgressView(value: p).tint(Theme.accent)
      }
    case .loading:
      Text("Loading the speech model…").font(.system(size: 11)).foregroundStyle(Theme.dim)
    case .failed(let e):
      Text("Speech model: \(e)").font(.system(size: 11)).foregroundStyle(.red)
    default:
      EmptyView()
    }
  }
}

struct EmptyState: View {
  var body: some View {
    VStack(spacing: 16) {
      Text("Two Tracks").font(.system(size: 34, design: .serif))
      Text("What's said, as heard, with English beside it.").foregroundStyle(Theme.dim)
      StartButton().frame(width: 240)
    }
  }
}

// MARK: Note

struct NoteView: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var recorder: Recorder
  let id: String
  enum Tab: String, CaseIterable { case transcript = "Transcript", notes = "My notes", summary = "Summary" }
  enum Mode: String, CaseIterable { case both = "Both", original = "As heard", english = "English" }
  @State private var tab = Tab.transcript
  @AppStorage("mode") private var mode = Mode.both

  var body: some View {
    let note = store.note(id)!
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        TextField("New note", text: Binding(get: { store.note(id)?.title ?? "" }, set: { t in store.update(id) { $0.title = t } }))
          .textFieldStyle(.plain)
          .font(.system(size: 32, design: .serif))
          .disabled(note.source == .wispr)
        HStack(spacing: 8) {
          Chip(text: note.created.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))
          if note.duration > 0 { Chip(text: minutes(note.duration)) }
          if note.source == .wispr { Chip(text: "From Wispr Flow") }
        }
        HStack(spacing: 22) {
          ForEach(Tab.allCases, id: \.self) { t in
            Button { tab = t } label: {
              VStack(spacing: 8) {
                Text(t.rawValue).font(.system(size: 15, weight: tab == t ? .semibold : .regular))
                  .foregroundStyle(tab == t ? .white : Theme.dim)
                Rectangle().fill(tab == t ? Color.white : .clear).frame(height: 2)
              }.fixedSize()
            }.buttonStyle(.plain)
          }
          Spacer()
          if tab == .transcript {
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
              .pickerStyle(.segmented).frame(width: 230).labelsHidden()
          }
        }
        .padding(.top, 6)
      }
      .padding(.horizontal, 36).padding(.top, 40)
      Divider().overlay(Theme.line)

      switch tab {
      case .transcript: TranscriptView(note: note, mode: mode)
      case .notes:
        TextEditor(text: Binding(get: { store.note(id)?.notes ?? "" }, set: { t in store.update(id) { $0.notes = t } }))
          .scrollContentBackground(.hidden).font(.system(size: 15)).padding(30)
      case .summary: SummaryView(note: note)
      }

      if recorder.noteID == id { RecordingBar() }
      if let p = recorder.problem, recorder.noteID == id {
        Text(p).font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 36).padding(.bottom, 12)
      }
    }
  }
}

struct Chip: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 12)).foregroundStyle(Theme.dim)
      .padding(.horizontal, 10).padding(.vertical, 5)
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
  }
}

struct TranscriptView: View {
  @EnvironmentObject var recorder: Recorder
  let note: Note
  let mode: NoteView.Mode

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if note.lines.isEmpty {
            Text(recorder.noteID == note.id ? "Listening… say something, or let the call speak." : "Nothing was said.")
              .foregroundStyle(Theme.dim).padding(.top, 30)
          }
          ForEach(Array(note.lines.enumerated()), id: \.element.id) { i, line in
            if i == 0 || note.lines[i - 1].speaker != line.speaker {
              Text(line.speaker.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dim)
                .padding(.top, i == 0 ? 0 : 14)
            }
            LineRow(line: line, mode: mode)
          }
          if recorder.noteID == note.id {
            ForEach(Array(recorder.speaking).sorted { $0.rawValue < $1.rawValue }, id: \.self) { who in
              Text("\(who.label) is talking…").font(.system(size: 13)).foregroundStyle(Theme.dim).padding(.top, 8)
            }
          }
          Color.clear.frame(height: 1).id("end")
        }
        .padding(.horizontal, 36).padding(.vertical, 22)
      }
      .onChange(of: note.lines.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
      .onAppear { proxy.scrollTo("end") }
    }
  }
}

struct LineRow: View {
  let line: Line
  let mode: NoteView.Mode

  var body: some View {
    let english = line.english
    HStack(alignment: .top, spacing: 12) {
      if mode != .english { Bubble(text: line.text, time: line.start, dim: false) }
      if mode != .original {
        if line.isEnglish && mode == .both {
          Bubble(text: line.text, time: nil, dim: true)
        } else {
          Bubble(text: english ?? "…", time: mode == .english ? line.start : nil, dim: english == nil)
        }
      }
    }
    .textSelection(.enabled)
  }
}

struct Bubble: View {
  let text: String
  let time: Double?
  let dim: Bool
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let time { Text(String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.dim) }
      Text(text).font(.system(size: 15)).foregroundStyle(dim ? Theme.dim : .white)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct SummaryView: View {
  @EnvironmentObject var store: Store
  let note: Note
  @State private var working = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if !note.summary.isEmpty {
          Text((try? AttributedString(markdown: note.summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(note.summary))
            .font(.system(size: 15)).textSelection(.enabled)
        }
        if Translator.claudePath != nil {
          Button(working ? "Summarizing…" : note.summary.isEmpty ? "Summarize" : "Summarize again") {
            working = true
            Task {
              if let s = await Summarizer.run(note) {
                store.update(note.id) { n in
                  if n.source == .local && n.title == "New note" { n.title = s.title }
                  n.summary = s.summary
                }
              }
              working = false
            }
          }
          .disabled(working || note.lines.isEmpty)
        } else if note.summary.isEmpty {
          Text("Summaries use Claude Code. Install it and sign in, then come back.").foregroundStyle(Theme.dim)
        }
      }
      .padding(36)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct RecordingBar: View {
  @EnvironmentObject var recorder: Recorder
  var body: some View {
    HStack(spacing: 14) {
      Button { recorder.stop() } label: {
        HStack(spacing: 8) {
          RoundedRectangle(cornerRadius: 3).fill(Theme.accent).frame(width: 12, height: 12)
          Text("Stop").font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .overlay(Capsule().stroke(Theme.line))
        .contentShape(Capsule())
      }.buttonStyle(.plain)
      Clock()
      Meter(label: "You", level: recorder.level[.you] ?? 0)
      Meter(label: "Them", level: recorder.level[.them] ?? 0)
      Spacer()
    }
    .padding(.horizontal, 36).padding(.vertical, 14)
  }
}

struct Meter: View {
  let label: String
  let level: Float
  var body: some View {
    HStack(spacing: 6) {
      Text(label).font(.system(size: 12)).foregroundStyle(Theme.dim)
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(Theme.bubble)
          Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(min(1, sqrt(level) * 3)))
        }
      }.frame(width: 60, height: 5)
    }
  }
}
