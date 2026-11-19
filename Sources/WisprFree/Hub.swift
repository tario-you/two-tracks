import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
  case home, notetaker, dictionary, snippets, style, settings
  var id: String { rawValue }
  var title: String {
    switch self {
    case .home: "Home"
    case .notetaker: "Notetaker"
    case .dictionary: "Dictionary"
    case .snippets: "Snippets"
    case .style: "Style"
    case .settings: "Settings"
    }
  }
  var icon: String {
    switch self {
    case .home: "house"
    case .notetaker: "waveform"
    case .dictionary: "book.closed"
    case .snippets: "scissors"
    case .style: "textformat"
    case .settings: "gearshape"
    }
  }
}

@MainActor
final class Navigation: ObservableObject {
  static let shared = Navigation()
  @Published var page: Page = .home
}

/// The main window: Wispr Flow's hub, a sidebar on the left and the page on a raised panel.
struct HubView: View {
  @EnvironmentObject var prefs: Prefs
  @EnvironmentObject var nav: Navigation

  var body: some View {
    HStack(spacing: 0) {
      Sidebar().frame(width: 212)
      Group {
        switch nav.page {
        case .home: HomePage()
        case .notetaker: NotetakerPage()
        case .dictionary: DictionaryPage()
        case .snippets: SnippetsPage()
        case .style: StylePage()
        case .settings: SettingsPage()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Theme.panel)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border))
      .padding(.top, 10).padding(.bottom, 10).padding(.trailing, 10)
    }
    .background(Theme.bg)
    .foregroundStyle(Theme.text)
    .font(Theme.sans(14))
    .sheet(isPresented: Binding(get: { !prefs.onboarded }, set: { _ in })) { Onboarding().environmentObject(prefs) }
  }
}

struct Sidebar: View {
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var prefs: Prefs
  @ObservedObject var setup = ModelsSetup.shared
  @ObservedObject var recorder = App.recorder

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Logo().frame(width: 20, height: 20)
        Text("WisprFree").font(Theme.serif(22))
      }
      .padding(.horizontal, 14).padding(.top, 38).padding(.bottom, 18)
      ForEach([Page.home, .notetaker, .dictionary, .snippets, .style]) { p in item(p) }
      Spacer()
      if setup.busy || setup.problem != nil { ModelBanner().padding(.horizontal, 10).padding(.bottom, 8) }
      if WisprWatch.running && !prefs.alongsideWispr { WisprBanner().padding(.horizontal, 10).padding(.bottom, 8) }
      item(.settings).padding(.bottom, 14)
    }
  }

  private func item(_ p: Page) -> some View {
    Button { nav.page = p } label: {
      HStack(spacing: 10) {
        Image(systemName: p.icon).frame(width: 18).font(.system(size: 13))
        Text(p.title).font(Theme.sans(14, nav.page == p ? .semibold : .regular))
        Spacer()
        if p == .notetaker && recorder.recording { Circle().fill(Theme.green).frame(width: 7, height: 7) }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .foregroundStyle(nav.page == p ? Theme.text : Theme.dim)
      .background(nav.page == p ? Theme.secondary : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
  }
}

/// WisprFree's mark: a pill with a waveform in it.
struct Logo: View {
  var body: some View {
    GeometryReader { g in
      ZStack {
        RoundedRectangle(cornerRadius: g.size.height * 0.28).fill(Theme.text)
        HStack(spacing: g.size.width * 0.08) {
          ForEach([0.35, 0.7, 1.0, 0.6, 0.3], id: \.self) { h in
            Capsule().fill(Theme.bg).frame(width: g.size.width * 0.09, height: g.size.height * 0.62 * h)
          }
        }
      }
    }
  }
}

struct ModelBanner: View {
  @ObservedObject var setup = ModelsSetup.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(setup.problem ?? setup.status).font(Theme.sans(12)).foregroundStyle(setup.problem == nil ? Theme.dim : Theme.orange)
      if setup.busy { ProgressView(value: setup.progress).tint(Theme.green).controlSize(.small) }
      if setup.problem != nil { Button("Try again") { setup.start() }.buttonStyle(QuietButton()) }
    }
    .padding(10)
    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
  }
}

struct WisprBanner: View {
  @EnvironmentObject var prefs: Prefs
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Wispr Flow is running and listens to the same keys. WisprFree is standing by.").font(Theme.sans(12)).foregroundStyle(Theme.dim)
      Button("Quit Wispr Flow") { WisprWatch.quitWispr() }.buttonStyle(PrimaryButton())
      Button("Run both") { prefs.alongsideWispr = true }.buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(Theme.dim)
    }
    .padding(10)
    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
  }
}

// MARK: Home

struct HomePage: View {
  @EnvironmentObject var lib: Library
  @EnvironmentObject var prefs: Prefs
  @State private var query = ""
  @State private var found: [HistoryItem]?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .center) {
          Text(prefs.firstName.isEmpty ? "Welcome back" : "Welcome back, \(prefs.firstName)").font(Theme.serif(34))
          Spacer()
          StatChip(icon: "flame", text: "\(max(lib.stats.weekStreak, 0)) week streak")
          StatChip(icon: "text.word.spacing", text: "\(lib.stats.totalWords.formatted()) words")
          StatChip(icon: "bolt", text: "\(lib.stats.wpm) WPM")
        }
        HowTo()
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
          TextField("Search your history", text: $query).textFieldStyle(.plain)
            .onChange(of: query) { _, q in found = q.isEmpty ? nil : lib.history(limit: 300, matching: q) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        let items = found ?? lib.recent
        if items.isEmpty {
          Text(query.isEmpty ? "Your dictations will show up here." : "Nothing matches.").foregroundStyle(Theme.dim).padding(.top, 20)
        }
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
          ForEach(groups(items), id: \.0) { title, rows in
            Text(title.uppercased()).font(Theme.sans(11, .semibold)).foregroundStyle(Theme.faint).kerning(0.6)
              .padding(.top, 18).padding(.bottom, 8)
            VStack(spacing: 0) {
              ForEach(rows) { h in
                HistoryRow(item: h)
                if h.id != rows.last?.id { Divider().overlay(Theme.border) }
              }
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
          }
        }
      }
      .padding(.horizontal, 40).padding(.vertical, 34)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  private func groups(_ items: [HistoryItem]) -> [(String, [HistoryItem])] {
    let cal = Calendar.current
    var order: [String] = []
    var map: [String: [HistoryItem]] = [:]
    for h in items {
      let key = cal.isDateInToday(h.date) ? "Today" : cal.isDateInYesterday(h.date) ? "Yesterday"
        : h.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
      if map[key] == nil { order.append(key) }
      map[key, default: []].append(h)
    }
    return order.map { ($0, map[$0]!) }
  }
}

struct StatChip: View {
  let icon: String
  let text: String
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.lilac)
      Text(text).font(Theme.sans(12, .medium))
    }
    .padding(.horizontal, 11).padding(.vertical, 6)
    .background(Theme.bg, in: Capsule())
    .overlay(Capsule().stroke(Theme.border))
  }
}

struct HowTo: View {
  @EnvironmentObject var prefs: Prefs
  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Hold \(prefs.talkKey.label) to dictate anywhere").font(Theme.serif(22))
        Text("Speak, let go, and your words land where you're typing, cleaned up. Double-tap for hands-free; Esc cancels. ⌃⌘V pastes your last dictation.")
          .font(Theme.sans(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      KeyCap(text: prefs.talkKey.label)
    }
    .padding(20)
    .background(LinearGradient(colors: [Theme.hex(0x3C2947), Theme.hex(0x202020)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
  }
}

struct KeyCap: View {
  let text: String
  var body: some View {
    Text(text).font(Theme.sans(15, .semibold))
      .padding(.horizontal, 16).padding(.vertical, 10)
      .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.15)))
      .shadow(color: .black.opacity(0.5), radius: 0, y: 2)
  }
}

struct HistoryRow: View {
  @EnvironmentObject var lib: Library
  let item: HistoryItem
  @State private var hover = false
  @State private var copied = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(item.date.formatted(.dateTime.hour().minute())).font(Theme.sans(12)).foregroundStyle(Theme.faint)
        .frame(width: 64, alignment: .leading).monospacedDigit()
      Text(item.text).font(Theme.sans(14)).foregroundStyle(Theme.text2).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 4) {
        if !item.appName.isEmpty { Text(item.appName).font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1) }
        Button {
          Inserter.copy(item.text)
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).foregroundStyle(Theme.dim).frame(width: 24, height: 22)
        }.buttonStyle(.plain).help("Copy")
      }
      .opacity(hover || copied ? 1 : 0)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .contentShape(Rectangle())
    .onHover { hover = $0 }
    .contextMenu {
      Button("Copy") { Inserter.copy(item.text) }
      if item.raw != item.text { Button("Copy what was heard") { Inserter.copy(item.raw) } }
      Divider()
      Button("Delete", role: .destructive) { lib.deleteHistory(item.id) }
    }
  }
}

// MARK: Dictionary

struct PageHeader<Trailing: View>: View {
  let title: String
  let detail: String
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(Theme.serif(34))
        Text(detail).font(Theme.sans(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      trailing
    }
  }
}

struct DictionaryPage: View {
  @EnvironmentObject var lib: Library
  @State private var adding = false
  @State private var filter = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PageHeader(title: "Dictionary", detail: "Names, jargon and spellings WisprFree should get right. Add a replacement to swap what it hears for what you want.") {
          Button("Add new") { adding = true }.buttonStyle(PrimaryButton())
        }
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
          TextField("Search", text: $filter).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        let words = lib.words.filter { filter.isEmpty || $0.phrase.localizedCaseInsensitiveContains(filter) || ($0.replacement ?? "").localizedCaseInsensitiveContains(filter) }
        if words.isEmpty { Text("No words yet.").foregroundStyle(Theme.dim) }
        VStack(spacing: 0) {
          ForEach(words) { w in
            WordRow(entry: w)
            if w.id != words.last?.id { Divider().overlay(Theme.border) }
          }
        }
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
      }
      .padding(.horizontal, 40).padding(.vertical, 34)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .sheet(isPresented: $adding) { AddWord().environmentObject(lib) }
  }
}

struct WordRow: View {
  @EnvironmentObject var lib: Library
  let entry: DictEntry
  @State private var hover = false
  var body: some View {
    HStack(spacing: 10) {
      Text(entry.phrase).font(Theme.sans(14, .medium))
      if let r = entry.replacement {
        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.faint)
        Text(r).font(Theme.sans(14)).foregroundStyle(Theme.text2).lineLimit(1)
      }
      Spacer()
      Button { lib.deleteWord(entry.id) } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.dim) }
        .buttonStyle(.plain).opacity(hover ? 1 : 0).help("Delete")
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .contentShape(Rectangle())
    .onHover { hover = $0 }
  }
}

struct AddWord: View {
  @EnvironmentObject var lib: Library
  @Environment(\.dismiss) var dismiss
  @State private var phrase = ""
  @State private var replace = false
  @State private var replacement = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add to dictionary").font(Theme.serif(26))
      Field(label: replace ? "When I say" : "Word or phrase", text: $phrase)
      Toggle("Replace it with something else", isOn: $replace).toggleStyle(.switch).font(Theme.sans(13))
      if replace { Field(label: "Write", text: $replacement) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
        Button("Add") { lib.addWord(phrase, replacement: replace ? replacement : nil); dismiss() }.buttonStyle(PrimaryButton())
          .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(26).frame(width: 440).background(Theme.panel).foregroundStyle(Theme.text)
  }
}

struct Field: View {
  let label: String
  @Binding var text: String
  var lines = 1
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(Theme.sans(12, .medium)).foregroundStyle(Theme.dim)
      if lines > 1 {
        TextEditor(text: $text).font(Theme.sans(14)).scrollContentBackground(.hidden).frame(height: CGFloat(lines) * 20)
          .padding(8).background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
          .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
      } else {
        TextField("", text: $text).textFieldStyle(.plain).font(Theme.sans(14))
          .padding(.horizontal, 11).padding(.vertical, 9).background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
          .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
      }
    }
  }
}

// MARK: Snippets

struct SnippetsPage: View {
  @EnvironmentObject var lib: Library
  @State private var adding = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PageHeader(title: "Snippets", detail: "Say a short cue and WisprFree writes the whole thing: links, addresses, sign-offs, prompts you use every day.") {
          Button("Add new") { adding = true }.buttonStyle(PrimaryButton())
        }
        if lib.snippets.isEmpty { Text("No snippets yet.").foregroundStyle(Theme.dim) }
        VStack(spacing: 0) {
          ForEach(lib.snippets) { s in
            SnippetRow(snippet: s)
            if s.id != lib.snippets.last?.id { Divider().overlay(Theme.border) }
          }
        }
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
      }
      .padding(.horizontal, 40).padding(.vertical, 34)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .sheet(isPresented: $adding) { AddSnippet().environmentObject(lib) }
  }
}

struct SnippetRow: View {
  @EnvironmentObject var lib: Library
  let snippet: Snippet
  @State private var hover = false
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text("“\(snippet.trigger)”").font(Theme.sans(14, .semibold)).frame(width: 200, alignment: .leading)
      Text(snippet.expansion).font(Theme.sans(13)).foregroundStyle(Theme.dim).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
      Button { lib.deleteSnippet(snippet.id) } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.dim) }
        .buttonStyle(.plain).opacity(hover ? 1 : 0).help("Delete")
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .contentShape(Rectangle())
    .onHover { hover = $0 }
  }
}

struct AddSnippet: View {
  @EnvironmentObject var lib: Library
  @Environment(\.dismiss) var dismiss
  @State private var trigger = ""
  @State private var expansion = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add a snippet").font(Theme.serif(26))
      Field(label: "When I say", text: $trigger)
      Field(label: "Write", text: $expansion, lines: 5)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
        Button("Add") { lib.addSnippet(trigger, expansion); dismiss() }.buttonStyle(PrimaryButton())
          .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
      }
    }
    .padding(26).frame(width: 480).background(Theme.panel).foregroundStyle(Theme.text)
  }
}

// MARK: Style

struct StylePage: View {
  @EnvironmentObject var prefs: Prefs
  @State private var category: Category = .personal

  private let apps: [Category: String] = [
    .personal: "Messages, WhatsApp, WeChat, Telegram, Signal, Discord",
    .work: "Slack, Teams, Lark, DingTalk, Linear",
    .email: "Mail, Outlook, Gmail, Superhuman, Spark",
    .other: "Notes, docs and every other app. AI chats and code editors get plain clean text.",
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(title: "Style", detail: "How your words read in each kind of app.") { EmptyView() }
        HStack(spacing: 22) {
          ForEach(Category.allCases) { c in
            Button { category = c } label: {
              VStack(spacing: 8) {
                Text(c.title).font(Theme.sans(14, category == c ? .semibold : .regular)).foregroundStyle(category == c ? Theme.text : Theme.dim)
                Rectangle().fill(category == c ? Theme.text : .clear).frame(height: 2)
              }.fixedSize()
            }.buttonStyle(.plain)
          }
        }
        Text("Applies in \(apps[category] ?? "")").font(Theme.sans(13)).foregroundStyle(Theme.dim)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
          ForEach(Style.allCases) { s in StyleCard(style: s, category: category, selected: prefs.styles[category] == s) { prefs.styles[category] = s } }
        }
        Toggle(isOn: $prefs.aiFormatting) {
          VStack(alignment: .leading, spacing: 3) {
            Text("AI formatting").font(Theme.sans(14, .medium))
            Text("Cleans up fillers and false starts, applies corrections, writes lists and numbers properly. Off: words as heard, lightly tidied.")
              .font(Theme.sans(12)).foregroundStyle(Theme.dim)
          }
        }.toggleStyle(.switch)
        Toggle(isOn: $prefs.cleanup) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Auto cleanup").font(Theme.sans(14, .medium))
            Text("Takes out filler words (\u{201C}like\u{201D}, \u{201C}you know\u{201D}) and applies your corrections. Off: every word stays as you said it.")
              .font(Theme.sans(12)).foregroundStyle(Theme.dim)
          }
        }.toggleStyle(.switch).disabled(!prefs.aiFormatting)
      }
      .padding(.horizontal, 40).padding(.vertical, 34)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

struct StyleCard: View {
  let style: Style
  let category: Category
  let selected: Bool
  let pick: () -> Void

  private var sample: String {
    switch (category, style) {
    case (.email, .formal): "Hi Alex,\n\nIt was great talking with you today. Looking forward to our next chat.\n\nBest,\nMary"
    case (.email, .casual): "Hi Alex, it was great talking with you today. Looking forward to our next chat.\n\nBest,\nMary"
    case (.email, .veryCasual): "hi alex, it was great talking with you today. looking forward to our next chat\n\nbest,\nmary"
    case (.email, .excited): "Hi Alex! It was so great talking with you today! Looking forward to our next chat.\n\nBest,\nMary"
    case (_, .formal): "Hey, are you free for lunch tomorrow? Let's chat about the great results."
    case (_, .casual): "Hey are you free for lunch tomorrow? Let's chat about the great results"
    case (_, .veryCasual): "hey are you free for lunch tomorrow? let's chat about the great results"
    case (_, .excited): "Hey are you free for lunch tomorrow? Let's chat about the great results!"
    }
  }

  var body: some View {
    Button(action: pick) {
      VStack(alignment: .leading, spacing: 10) {
        Text(style.title).font(Theme.serif(24))
        Text(style.detail).font(Theme.sans(12)).foregroundStyle(Theme.dim)
        Text(sample).font(Theme.sans(13)).foregroundStyle(Theme.text2)
          .padding(12).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
          .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.text : Theme.border, lineWidth: selected ? 1.5 : 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
