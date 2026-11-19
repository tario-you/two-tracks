import SwiftUI

/// Meetings: the list on the left, the open note on the right, the way Wispr Flow's notetaker lays them out.
struct NotetakerPage: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var recorder: Recorder
  @State private var selection: String?
  @State private var follower: WisprFollower?
  @State private var query = ""

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        StartButton().padding(.horizontal, 12).padding(.top, 18)
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
          TextField("Search notes", text: $query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(groups(), id: \.0) { title, notes in
              Text(title.uppercased()).font(Theme.sans(11, .semibold)).foregroundStyle(Theme.faint).kerning(0.6)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
              ForEach(notes) { NoteRow(note: $0, selection: $selection) }
            }
          }
          .padding(.bottom, 16)
        }
      }
      .frame(width: 260)
      .background(Theme.bg.opacity(0.6))
      Divider().overlay(Theme.border)
      Group {
        if let id = selection, store.note(id) != nil {
          NoteView(id: id)
        } else {
          VStack(spacing: 14) {
            Text("Notetaker").font(Theme.serif(34))
            Text("Your side and theirs, transcribed on this Mac, cleaned up and summarized when you stop.").foregroundStyle(Theme.dim)
            StartButton().frame(width: 240)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear {
      if follower == nil { follower = WisprFollower(store: store) }
      if Wispr.installed { store.wispr = Wispr.meetings() }
      if selection == nil { selection = recorder.noteID ?? store.notes.first?.id ?? store.wispr.first?.id }
    }
    .onChange(of: selection) { _, id in follower?.follow(id) }
    .onChange(of: recorder.noteID) { _, id in if let id { selection = id } }
  }

  private func groups() -> [(String, [Note])] {
    let mine = Set(store.notes.map(\.id))
    let all = (store.notes + store.wispr.filter { !mine.contains($0.id) }).sorted { $0.created > $1.created }.filter { n in
      query.isEmpty || n.title.localizedCaseInsensitiveContains(query) || n.lines.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }
    let cal = Calendar.current
    var order: [String] = []
    var map: [String: [Note]] = [:]
    for n in all {
      let key = cal.isDateInToday(n.created) ? "Today" : cal.isDateInYesterday(n.created) ? "Yesterday" : n.created.formatted(.dateTime.month(.wide).year())
      if map[key] == nil { order.append(key) }
      map[key, default: []].append(n)
    }
    return order.map { ($0, map[$0]!) }
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
          Text(note.title).lineLimit(1).font(Theme.sans(13, .medium))
          Text(note.created.formatted(.dateTime.hour().minute()) + (note.duration > 0 ? " · " + minutes(note.duration) : "")
               + (note.source == .wispr ? " · Wispr Flow" : ""))
            .font(Theme.sans(11)).foregroundStyle(Theme.dim)
        }
        Spacer(minLength: 0)
        if recorder.noteID == note.id { Circle().fill(Theme.green).frame(width: 7, height: 7) }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selection == note.id ? Theme.secondary : .clear, in: RoundedRectangle(cornerRadius: 8))
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
    Button { recorder.toggle() } label: {
      HStack(spacing: 8) {
        if recorder.recording {
          RoundedRectangle(cornerRadius: 3).fill(Theme.green).frame(width: 12, height: 12)
          Text("Stop")
          Spacer()
          Clock()
        } else {
          Image(systemName: "waveform")
          Text("Start notetaker")
          Spacer()
          Text("⌥M").font(Theme.sans(11)).opacity(0.6)
        }
      }
      .font(Theme.sans(14, .semibold))
      .padding(.horizontal, 14).padding(.vertical, 10)
      .background(recorder.recording ? Theme.secondary : Theme.primary, in: RoundedRectangle(cornerRadius: 12))
      .foregroundStyle(recorder.recording ? Theme.text : Theme.onPrimary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct Clock: View {
  @EnvironmentObject var recorder: Recorder
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      Text(clock(ctx.date.timeIntervalSince(recorder.started ?? ctx.date))).monospacedDigit().foregroundStyle(Theme.dim)
    }
  }
}

struct NoteView: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var recorder: Recorder
  let id: String
  enum Tab: String, CaseIterable { case notes = "My thoughts", transcript = "Transcript", summary = "Summary" }
  enum Mode: String, CaseIterable { case cleaned = "Cleaned up", original = "As heard", both = "Both", english = "English" }
  @State private var tab = Tab.transcript
  @AppStorage("transcriptMode") private var mode = Mode.cleaned
  @AppStorage("improveHintDismissed") private var hintDismissed = false
  @State private var question = ""

  var body: some View {
    let note = store.note(id)!
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Group {
          if note.source == .wispr {
            Text(note.title)
          } else {
            TextField("New note", text: Binding(get: { store.note(id)?.title ?? "" }, set: { t in store.update(id) { $0.title = t } }))
              .textFieldStyle(.plain)
          }
        }
        .font(Theme.serif(36))
        HStack(spacing: 8) {
          Chip(text: Calendar.current.isDateInToday(note.created) ? "Today" : note.created.formatted(.dateTime.weekday(.abbreviated).month().day()))
          if note.duration > 0 { Chip(text: minutes(note.duration)) }
          if note.source == .wispr { Chip(text: "Wispr Flow") }
        }
        HStack(spacing: 26) {
          ForEach(Tab.allCases, id: \.self) { t in
            Button { tab = t } label: {
              VStack(spacing: 8) {
                HStack(spacing: 6) {
                  if t == .transcript && recorder.noteID == id { Image(systemName: "waveform").foregroundStyle(Theme.green).font(.system(size: 11)) }
                  if t == .summary { Image(systemName: "plus").font(.system(size: 11)) }
                  Text(t.rawValue).font(Theme.sans(15, tab == t ? .semibold : .regular))
                }
                .foregroundStyle(tab == t ? Theme.text : Theme.dim)
                Rectangle().fill(tab == t ? Theme.text : .clear).frame(height: 2)
              }.fixedSize()
            }.buttonStyle(.plain)
          }
          Spacer()
        }
        .padding(.top, 8)
      }
      .padding(.horizontal, 40).padding(.top, 34)
      Divider().overlay(Theme.border)

      switch tab {
      case .transcript: transcript(note)
      case .notes:
        TextEditor(text: Binding(get: { store.note(id)?.notes ?? "" }, set: { t in store.update(id) { $0.notes = t } }))
          .scrollContentBackground(.hidden).font(Theme.sans(15)).padding(30)
      case .summary: SummaryView(note: note)
      }

      if let p = recorder.problem, recorder.noteID == id {
        Text(p).font(Theme.sans(12)).foregroundStyle(Theme.orange).padding(.horizontal, 40).padding(.bottom, 6)
      }
      bottomBar(note)
    }
  }

  @ViewBuilder private func transcript(_ note: Note) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 14) {
        Image(systemName: "clock").foregroundStyle(Theme.dim)
        Text(recorder.noteID == id ? clock(Date().timeIntervalSince(recorder.started ?? Date())) : clock(note.duration))
          .font(Theme.sans(13, .medium)).monospacedDigit().foregroundStyle(Theme.dim)
        if recorder.improving.contains(id) { ProgressView().controlSize(.small); Text("Cleaning up…").font(Theme.sans(12)).foregroundStyle(Theme.dim) }
        Spacer()
        Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
          .onChange(of: mode) { _, m in if m == .both || m == .english { Translator.shared.translate(note: id, lines: note.lines) } }
          .onAppear { if mode == .both || mode == .english { Translator.shared.translate(note: id, lines: note.lines) } }
        Button { Inserter.copy(recorder.transcriptText(note)) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).foregroundStyle(Theme.dim).help("Copy transcript")
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      if !hintDismissed && (note.paragraphs ?? []).isEmpty && note.source == .local {
        HStack {
          Text("After the meeting, WisprFree cleans up the transcript and names the speakers.").font(Theme.sans(12)).foregroundStyle(Theme.dim)
          Spacer()
          Button { hintDismissed = true } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.secondary)
      }
    }
    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal, 40).padding(.top, 18)

    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          if let paragraphs = note.paragraphs, !paragraphs.isEmpty, mode == .cleaned {
            ForEach(Array(paragraphs.enumerated()), id: \.element.id) { i, p in
              if i == 0 || paragraphs[i - 1].speaker != p.speaker {
                Text(p.speaker).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.lilac).padding(.top, i == 0 ? 0 : 10)
              }
              Bubble(text: p.text, time: p.start, dim: false)
            }
          } else {
            if note.lines.isEmpty {
              Text(recorder.noteID == note.id ? "Listening… say something, or let the call speak." : "Nothing was said.")
                .foregroundStyle(Theme.dim).padding(.top, 20)
            }
            ForEach(Array(note.lines.enumerated()), id: \.element.id) { i, line in
              if i == 0 || note.lines[i - 1].speaker != line.speaker {
                Text(line.speaker.label).font(Theme.sans(12, .semibold)).foregroundStyle(line.speaker == .you ? Theme.lilac : Theme.dim)
                  .padding(.top, i == 0 ? 0 : 10)
              }
              if mode == .both && !line.isEnglish {
                HStack(alignment: .top, spacing: 10) {
                  Bubble(text: line.text, time: line.start, dim: false)
                  Bubble(text: line.english ?? "…", time: nil, dim: line.english == nil)
                }
              } else {
                let english = mode == .english && !line.isEnglish
                Bubble(text: english ? (line.english ?? "…") : line.text, time: line.start, dim: english && line.english == nil)
              }
            }
          }
          if recorder.noteID == note.id {
            ForEach(Array(recorder.speaking).sorted { $0.rawValue < $1.rawValue }, id: \.self) { who in
              Text("\(who.label) is talking…").font(Theme.sans(13)).foregroundStyle(Theme.dim).padding(.top, 6)
            }
          }
          Color.clear.frame(height: 1).id("end")
        }
        .padding(.horizontal, 40).padding(.vertical, 18)
        .textSelection(.enabled)
      }
      .onChange(of: note.lines.count) { _, _ in if recorder.noteID == id { withAnimation { proxy.scrollTo("end") } } }
    }
  }

  private func bottomBar(_ note: Note) -> some View {
    VStack(spacing: 8) {
      if let chat = note.chat, !chat.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(chat.suffix(4)) { t in
              Text(t.question).font(Theme.sans(13, .semibold))
              if let a = t.answer {
                Text((try? AttributedString(markdown: a, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(a))
                  .font(Theme.sans(13)).foregroundStyle(Theme.text2).textSelection(.enabled)
              } else {
                ProgressView().controlSize(.small)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
        }
        .frame(maxHeight: 200)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
      }
      HStack(spacing: 10) {
        if recorder.noteID == id {
          Button { recorder.stop() } label: {
            HStack(spacing: 8) {
              RoundedRectangle(cornerRadius: 3).fill(Theme.green).frame(width: 12, height: 12)
              Text("Stop").font(Theme.sans(15, .semibold))
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .overlay(Capsule().stroke(Theme.border))
            .contentShape(Capsule())
          }.buttonStyle(.plain)
        }
        HStack {
          TextField("Ask anything", text: $question).textFieldStyle(.plain).font(Theme.sans(14))
            .onSubmit { send(question) }
          Button("What did I miss?") { send("What did I miss? Catch me up on the last few minutes.") }
            .buttonStyle(QuietButton())
        }
        .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 6)
        .overlay(Capsule().stroke(Theme.border))
        .disabled(note.lines.isEmpty || recorder.asking.contains(id))
      }
    }
    .padding(.horizontal, 40).padding(.vertical, 16)
  }

  private func send(_ q: String) {
    let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return }
    question = ""
    Task { await recorder.ask(id, q) }
  }
}

struct Chip: View {
  let text: String
  var body: some View {
    Text(text).font(Theme.sans(12)).foregroundStyle(Theme.dim)
      .padding(.horizontal, 10).padding(.vertical, 5)
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
  }
}

struct Bubble: View {
  let text: String
  let time: Double?
  let dim: Bool
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(text).font(Theme.sans(15)).foregroundStyle(dim ? Theme.dim : Theme.text).frame(maxWidth: .infinity, alignment: .leading)
      if let time { Text(clock(time)).font(Theme.sans(11)).monospacedDigit().foregroundStyle(Theme.faint) }
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct SummaryView: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var recorder: Recorder
  let note: Note
  @State private var working = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if !note.summary.isEmpty {
          Text((try? AttributedString(markdown: note.summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(note.summary))
            .font(Theme.sans(15)).textSelection(.enabled)
        }
        HStack {
          Button(working ? "Summarizing…" : note.summary.isEmpty ? "Summarize" : "Summarize again") {
            working = true
            Task { await recorder.summarize(note.id); working = false }
          }
          .buttonStyle(QuietButton())
          .disabled(working || note.lines.isEmpty)
          if note.source == .local {
            Button(recorder.improving.contains(note.id) ? "Cleaning up…" : "Clean up transcript") {
              Task { await recorder.improve(note.id) }
            }
            .buttonStyle(QuietButton())
            .disabled(recorder.improving.contains(note.id) || note.lines.isEmpty)
          }
        }
      }
      .padding(40)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
