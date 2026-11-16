// The journal's panes around the drawn list (TapeWindow.swift): the slim top bar (the sidebar switch, the search field,
// the reader switch, Shortcuts, Settings, Help with their names and keys), the sidebar (named entries with counts in
// folding groups, Group by at its foot), the reader on the right (the chosen item in full; Edit opens a plain text
// editor in its place), the status line. Every control says what it is and its key in its tooltip; the place in focus
// has the focus ring (the accent), never the selection's colour.
import AppKit
import SwiftUI

// MARK: the top bar

/// The search field: normal height (28 pt); after ⌘K it takes a command.
struct TapeField: View {
    @EnvironmentObject var m: WindowModel
    @FocusState private var focused: Bool
    var body: some View {
        let ring = m.nav.region == .search
        HStack(spacing: 8) {
            Glyph(m.commandMode ? "send" : "search", size: 14).foregroundStyle(m.commandMode ? UIInk.ink : UIInk.muted)
            let prompt = m.commandMode ? "Book 30 min tomorrow · find a free slot · task… · ;snippet" : "Search the journal"
            TextField(m.commandMode ? "Ask Drafter" : "Search", text: m.commandMode ? $m.command : $m.query,
                      prompt: Text(prompt).foregroundColor(UIInk.faint))
                .textFieldStyle(.plain).font(PKFont.text(13.5)).focused($focused)
                .accessibilityLabel(m.commandMode ? "Command" : "Search the journal")
            if m.thinking { ProgressView().controlSize(.mini) }
            else if !m.query.isEmpty, !m.commandMode {
                Text("\(m.results)").font(PKFont.mono(11)).foregroundStyle(UIInk.faint).help("\(m.results) results")
                Button { m.query = "" } label: { Glyph("close", size: 12).foregroundStyle(UIInk.faint) }.buttonStyle(.plain).help("Clear the search (esc)")
            }
            else { KeyChip(m.commandMode ? "esc" : "⌘K").help(m.commandMode ? "Back to search (esc)" : "Ask Drafter to do something: book, find a slot, a task (⌘K)") }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: PK.corner(2)).fill(UIInk.card))
        .overlay { RoundedRectangle(cornerRadius: PK.corner(2)).strokeBorder(ring ? UIInk.blue : UIInk.rule, lineWidth: ring ? 1 : 0.5) }
        .contentShape(Rectangle())
        .onTapGesture { m.nav.region = .search; focused = true }
        .onChange(of: m.focusField, initial: true) { _, _ in if m.editing == nil { focused = true } }
        .help("Search the journal: clips, drafts, voice notes and recordings (⌘F) · ↓ goes into the results")
    }
}

/// One of the three actions at the top: its glyph, its name and its key.
struct TopAction: View {
    @EnvironmentObject var m: WindowModel
    let index: Int
    let glyph: String
    let name: String
    let key: String
    let tip: String
    var on = false
    var short = false
    let act: () -> Void
    @State private var hover = false
    var body: some View {
        let ring = m.nav.region == .top(index)
        Button(action: { act(); m.focusField += 1 }) {
            HStack(spacing: 6) {
                Glyph(glyph, size: 14).foregroundStyle(on ? UIInk.ink : UIInk.muted)
                if !short {
                    Text(name).font(PKFont.text(12.5)).foregroundStyle(on ? UIInk.ink : UIInk.muted)
                    Text(key).font(PKFont.text(11)).foregroundStyle(UIInk.faint)
                }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(Capsule().fill(on ? UIInk.pick : hover ? UIInk.hover : .clear))
            .overlay { if ring { Capsule().strokeBorder(UIInk.blue, lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.accessibilityLabel(name).help("\(name): \(tip) (\(key))")
    }
}

/// The top bar: room for the window's buttons, the sidebar switch, the search field (or the way back on a page), the
/// reader switch, the three actions.
struct TopBar: View {
    @EnvironmentObject var m: WindowModel
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 64, height: 1)
            if m.page == .tape {
                IconButton(glyph: "list", tip: (m.sidebarShown ? "Hide" : "Show") + " the sidebar (⌘\\)", on: m.sidebarShown) { m.toggleSidebar() }
                IconButton(glyph: "arrow-left", tip: "Back: where you were before (⌘[)", enabled: m.canBack) { m.historyStep(true) }
                IconButton(glyph: "arrow-left", tip: "Forward (⌘])", enabled: m.canForward, mirrored: true) { m.historyStep(false) }
                TapeField().frame(maxWidth: 520)
                ViewSwitch()
                if m.gallery, m.width >= 760 { CardSize() }
                IconButton(glyph: "file", tip: (m.readerOn ? "Hide" : "Show") + " the reader: the chosen item in full (⌥⌘\\)", on: m.readerOn) { m.toggleReader() }
            } else {
                BackRow(title: title)
            }
            Spacer(minLength: 8)
            let short = m.width < 1100
            TopAction(index: 0, glyph: "user", name: "Names", key: "⇧⌘N", tip: "people, projects and companies: spellings, forms, phones", on: m.page == .names, short: short) { m.show(.names) }
            TopAction(index: 1, glyph: "bookmark", name: "Shortcuts", key: "⌘J", tip: "your email, calendar link and replacements", on: m.page == .shortcuts, short: short) { m.show(.shortcuts) }
            TopAction(index: 2, glyph: "settings", name: "Settings", key: "⌘,", tip: "every switch", on: m.page == .settings, short: short) { m.show(.settings) }
            TopAction(index: 3, glyph: "help", name: "Help", key: "⌘/", tip: "what each part does and every key", on: m.page == .help, short: short) { m.show(.help) }
        }
        .padding(.horizontal, 12).frame(height: 44)
    }
}

/// Gallery or list (⌥⌘1 ⌥⌘2): two soft segments.
struct ViewSwitch: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        HStack(spacing: 2) {
            seg("image", "Gallery", "gallery", "⌥⌘1")
            seg("list", "List", "list", "⌥⌘2")
        }
        .padding(2).background(Capsule().fill(UIInk.well))
    }
    func seg(_ g: String, _ name: String, _ v: String, _ key: String) -> some View {
        let on = m.settings.journalView == v || (v == "gallery" && m.gallery)
        return Button { m.setView(v); m.focusField += 1 } label: {
            Glyph(g, size: 13).foregroundStyle(on ? UIInk.ink : UIInk.muted).frame(width: 30, height: 22)
                .background(Capsule().fill(on ? UIInk.card : .clear)).contentShape(Capsule())
        }.buttonStyle(.plain).help("\(name) view (\(key))").accessibilityLabel("\(name) view").accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The card size (⌘- ⌘+): small, medium, large.
struct CardSize: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        HStack(spacing: 0) {
            let lv = m.galleryLevel
            Button { m.setCardSize(-1) } label: { Text("−").font(PKFont.text(14)).frame(width: 24, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(m.gallery ? lv == .days : m.settings.cardSize == 0).help("Zoom out: smaller cards, then one line each, then days (⌘- or pinch)").accessibilityLabel("Zoom out")
            Text(m.gallery ? lv.mark : ["S", "M", "L"][JournalLayout.step(m.settings.cardSize)]).font(PKFont.num(11.5)).foregroundStyle(UIInk.muted).frame(minWidth: 14).fixedSize()
            Button { m.setCardSize(1) } label: { Text("+").font(PKFont.text(14)).frame(width: 24, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(m.gallery ? lv == .large : m.settings.cardSize == 2).help("Zoom in (⌘+ or pinch)").accessibilityLabel("Zoom in")
        }
        .foregroundStyle(UIInk.muted).padding(.horizontal, 2).background(Capsule().fill(UIInk.well))
    }
}

struct IconButton: View {
    let glyph: String
    let tip: String
    var on = false
    var enabled = true
    var mirrored = false
    let act: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: act) {
            Glyph(glyph, size: 15).foregroundStyle(!enabled ? UIInk.faint : on ? UIInk.ink : UIInk.muted)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: PK.radius("row")).fill(hover && enabled ? UIInk.hover : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).onHover { hover = $0 }.help(tip).accessibilityLabel(tip)
    }
}

// MARK: the sidebar

/// Named entries with their counts, in folding groups; at its foot, how the list is grouped.
struct TapeSidebar: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        let vis = TapeRules.visible(m.side, folded: m.folded)
        let cursor = m.nav.region == .sidebar ? m.nav.cursor : -1
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(m.side.enumerated()), id: \.offset) { i, e in
                        if e.group != (i > 0 ? m.side[i - 1].group : "") { GroupHead(title: e.group) }
                        if !m.folded.contains(e.group) {
                            let n = vis.firstIndex(of: e) ?? -1
                            SideRow(entry: e, number: n, active: e.filter == m.filter, cursor: n == cursor)
                        }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 8)
            }
            GroupPicker().padding(8)
        }
    }
}

/// Under 640 pt: the sidebar as a strip of glyphs (All, Pinned, the kinds), each with its name in the tooltip.
struct SideStrip: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(m.side.filter { $0.group == "" || $0.group == "Kinds" }.enumerated()), id: \.offset) { _, e in
                let on = e.filter == m.filter
                Button { m.setFilter(e.filter); m.focusField += 1 } label: {
                    Glyph(e.glyph, size: 15).foregroundStyle(on ? UIInk.ink : UIInk.muted).frame(width: 34, height: 30)
                        .background(RoundedRectangle(cornerRadius: PK.radius("row")).fill(on ? UIInk.pick : .clear)).contentShape(Rectangle())
                }.buttonStyle(.plain).help("\(e.title) · \(e.count)").accessibilityLabel("\(e.title), \(e.count)")
                    .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { _ in e.filter == .pinned && !m.dragIds.isEmpty ? { m.pinDropped(m.dragIds); return true }() : false }
            }
            Spacer()
        }.padding(.vertical, 8).frame(width: 46)
    }
}

/// The sidebar's background: the system's sidebar material (vibrancy).
struct SideMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .sidebar; v.blendingMode = .behindWindow; v.state = .followsWindowActiveState; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct GroupHead: View {
    @EnvironmentObject var m: WindowModel
    let title: String
    var body: some View {
        let open = !m.folded.contains(title)
        Button { m.fold(title) } label: {
            HStack(spacing: 4) {
                Text(title).font(PKFont.text(11.5, .semibold))
                Spacer()
                Glyph(open ? "chevron-down" : "chevron-right", size: 11)
            }.foregroundStyle(UIInk.faint).padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).help((open ? "Fold " : "Unfold ") + title).accessibilityLabel(title)
    }
}

struct SideRow: View {
    @EnvironmentObject var m: WindowModel
    let entry: TapeRules.Entry
    let number: Int
    let active: Bool
    let cursor: Bool
    @State private var hover = false
    var body: some View {
        let key = number >= 0 && number < 9 ? "⌘\(number + 1)" : ""
        Button { m.nav.region = .sidebar; m.nav.cursor = max(0, number); m.setFilter(entry.filter); m.focusField += 1 } label: {
            HStack(spacing: 8) {
                let lit = active || cursor || hover   // on the soft lift: quiet, not faint (the contrast gates)
                Glyph(entry.glyph, size: 14).foregroundStyle(active ? UIInk.ink : lit ? UIInk.muted : UIInk.faint)
                    .padding(.leading, CGFloat(entry.depth) * 14)
                Text(entry.title).font(PKFont.text(13, active ? .medium : .regular)).foregroundStyle(entry.count == 0 && !lit ? UIInk.faint : entry.count == 0 ? UIInk.muted : UIInk.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if (hover || cursor) && !key.isEmpty { Text(key).font(PKFont.text(11)).foregroundStyle(UIInk.muted) }
                if entry.group == "Kinds" { Circle().fill(Color(nsColor: PK.series(JournalMeta.series(sideKind(entry.filter))))).frame(width: 6, height: 6) }
                if entry.unfolds { Glyph(entry.open ? "chevron-down" : "chevron-right", size: 11).foregroundStyle(lit ? UIInk.muted : UIInk.faint) }
                Text("\(entry.count)").font(PKFont.num(11.5)).foregroundStyle(lit ? UIInk.muted : UIInk.faint)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: PK.radius("row")).fill(active ? UIInk.pick : hover ? UIInk.hover : .clear))
            .overlay { if cursor { RoundedRectangle(cornerRadius: PK.radius("row")).strokeBorder(UIInk.blue, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { _ in
            guard entry.filter == .pinned, !m.dragIds.isEmpty else { return false }
            m.pinDropped(m.dragIds); return true
        }
        .help(entry.tip + (key.isEmpty ? "" : " (\(key))") + (entry.filter == .pinned ? " · drop items here to pin them" : ""))
        .accessibilityLabel("\(entry.title), \(entry.count)").accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Group the list by: Time, Related to, App.
struct GroupPicker: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Group by").font(PKFont.text(11.5, .semibold)).foregroundStyle(UIInk.faint).padding(.leading, 6)
            HStack(spacing: 2) {
                ForEach(TapeRules.Group.allCases, id: \.self) { g in
                    Button { m.setGroup(g); m.focusField += 1 } label: {
                        Text(g.title).font(PKFont.text(11.5)).foregroundStyle(m.group == g ? UIInk.ink : UIInk.muted).lineLimit(1).fixedSize()
                            .padding(.horizontal, 4).frame(height: 24).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: PK.corner(2)).fill(m.group == g ? UIInk.soft : .clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Group the list by \(g.title.lowercased()) (⌘G the next way)")
                        .accessibilityAddTraits(m.group == g ? .isSelected : [])
                }
            }
            .padding(2).overlay { RoundedRectangle(cornerRadius: PK.corner(2) + 2).strokeBorder(UIInk.line, lineWidth: 0.5) }
        }
    }
}

/// A pane's edge: drag to change its width (kept).
struct PaneEdge: View {
    @EnvironmentObject var m: WindowModel
    let reader: Bool
    @State private var start: CGFloat?
    @State private var hover = false
    @State private var collapsing = false
    var body: some View {
        Color.clear.frame(width: 8)
            .overlay { Capsule().fill(hover ? UIInk.rule : .clear).frame(width: 3, height: 36) }
            .contentShape(Rectangle())
            .onHover { hover = $0; $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .onTapGesture(count: 2) {
                if reader { m.readerWidth = CGFloat(JournalLayout.reset(.reader)) } else { m.sidebarWidth = CGFloat(JournalLayout.reset(.sidebar)) }
                m.savePrefs()
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                let p: JournalLayout.Pane = reader ? .reader : .sidebar
                if start == nil { start = reader ? m.readerWidth : m.sidebarWidth }
                let r = JournalLayout.drag(p, from: Double(start ?? 0), by: Double(reader ? -g.translation.width : g.translation.width))
                collapsing = r.collapsed
                if !r.collapsed { if reader { m.readerWidth = CGFloat(r.width) } else { m.sidebarWidth = CGFloat(r.width) } }
            }.onEnded { _ in
                if collapsing { if reader { m.toggleReader() } else { m.toggleSidebar() } }
                start = nil; collapsing = false; m.savePrefs()
            })
            .help("Drag to change the " + (reader ? "reader's" : "sidebar's") + " width · past its minimum it closes · double-click: the first width")
            .accessibilityLabel((reader ? "Reader" : "Sidebar") + " edge")
    }
}

/// The page's way back: the arrow and esc.
struct BackRow: View {
    @EnvironmentObject var m: WindowModel
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Button { m.back() } label: {
                HStack(spacing: 6) {
                    Glyph("arrow-left", size: 14)
                    Text("Back").font(PKFont.text(13))
                    KeyChip("esc")
                }.foregroundStyle(UIInk.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Back to the journal").help("Back to the journal (esc)")
            Text(title).font(PKFont.text(13)).foregroundStyle(UIInk.faint).lineLimit(1)
        }
    }
}

// MARK: the reader

/// The chosen item in full: what it is, when (exactly, and how long ago), how long, the app; what it is related to
/// and why; the text, readable and wrapped, with the search's matches marked; a recording's people, talk time,
/// summary, to-dos and transcript. Its actions at the foot, each a verb with its key. Edit puts a plain text editor
/// in the text's place (normal undo); Esc leaves it and keeps the change beside the original.
struct JournalReader: View {
    @EnvironmentObject var m: WindowModel
    @FocusState private var editorFocus: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.editing == "new" { combineDraft }
            else if let it = m.current { item(it) }
            else if let l = m.currentLine { header(l) }
            else { Text("Choose an item: ↑ ↓").font(PKFont.text(13)).foregroundStyle(UIInk.faint).padding(20); Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(UIInk.card)
    }

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    /// One quiet line: kind, how long ago, length, where it went (JournalMeta.header). The exact moment is in its
    /// tooltip and in Details.
    func headline(_ it: TapeItem) -> String {
        JournalMeta.header(noun: it.noun, ago: TimeChunks.relative(it.at, now: m.now, cal: TapeBuild.cal),
                           took: it.took.flatMap { $0 >= 1 ? TapeRules.clock($0) : nil }, app: it.app, fate: it.fate)
    }

    /// Details (⌘I): the exact moment, the characters, repeats, a change, an estimate, the other records of the text.
    @ViewBuilder func details(_ it: TapeItem) -> some View {
        let lines = JournalMeta.details(exact: TapeView.exact(it.at), chars: it.current.count, repeats: it.repeats, changed: it.change != nil,
                                        est: it.est, also: it.also, clock: { TapeView.exact($0) })
        VStack(alignment: .leading, spacing: 3) {
            Button { withAnimation(.easeOut(duration: PK.motion("fold"))) { m.detailsOpen.toggle() } } label: {
                HStack(spacing: 4) {
                    Glyph(m.detailsOpen ? "chevron-down" : "chevron-right", size: 11)
                    Text("Details").font(PKFont.text(12))
                    if !it.also.isEmpty { Text("· \(it.also.count + 1) records").font(PKFont.text(12)) }
                    if it.est { Text("≈").font(PKFont.text(12)).help("The start is an estimate") }
                }.foregroundStyle(UIInk.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).help((m.detailsOpen ? "Hide" : "Show") + " the details: exact time, characters, other records (⌘I)")
            if m.detailsOpen {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(PKFont.num(11.5)).foregroundStyle(UIInk.muted).textSelection(.enabled).padding(.leading, 15)
                }
                // wire round: what the detector found, each with its words and what they resolved to
                let things = FoundRules.inThisText(m.found(it))
                if !things.isEmpty {
                    Text("In this text").font(PKFont.text(11.5, .semibold)).foregroundStyle(UIInk.faint).padding(.leading, 15).padding(.top, 4)
                    ForEach(Array(things.enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 6) {
                            Glyph(JournalMeta.foundGlyph(t.kind), size: 11).foregroundStyle(UIInk.muted)
                            Text(t.words).font(PKFont.text(12)).foregroundStyle(UIInk.ink).lineLimit(1)
                            if !t.value.isEmpty { Text("→ " + t.value).font(PKFont.num(11.5)).foregroundStyle(UIInk.muted).lineLimit(1) }
                        }.padding(.leading, 15).textSelection(.enabled)
                    }
                    Text("⌥↓ ⌥↑ go through them · ↵ what to do").font(PKFont.text(11)).foregroundStyle(UIInk.faint).padding(.leading, 15)
                }
            }
        }
    }

    @ViewBuilder func item(_ it: TapeItem) -> some View {
        let editing = m.editing == it.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Glyph(JournalMeta.glyph(it.kindId), size: 15).foregroundStyle(Color(nsColor: PK.series(JournalMeta.series(it.kindId))))
                Text(headline(it)).font(PKFont.text(13.5, .medium)).lineLimit(1)
                    .help(TapeView.exact(it.at) + " · \(it.current.count) characters")
                Spacer(minLength: 0)
                if it.pinned { Glyph("pin", size: 13).foregroundStyle(UIInk.muted).help("Pinned: on top of the Quick panel (⌘P)") }
                if m.overShown {
                    Button { m.closeOver() } label: { Glyph("close", size: 13).foregroundStyle(UIInk.muted).frame(width: 24, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help("Close the reader (esc)").accessibilityLabel("Close the reader")
                }
            }
            if editing {
                Text("Editing · the original is kept beside your change").font(PKFont.text(12)).foregroundStyle(UIInk.muted)
            }
            details(it)
            related(it)
            if it.change != nil, !editing {
                HStack(spacing: 8) {
                    Text(m.showOriginal ? "Original" : "Changed").font(PKFont.text(11.5, .medium)).foregroundStyle(UIInk.ink)
                        .padding(.horizontal, 7).frame(height: 20)
                        .overlay { Capsule().strokeBorder(UIInk.rule, lineWidth: 0.5) }
                        .help(m.showOriginal ? "Original: the text as it was kept" : "Changed: you changed this text; the original is kept")
                    Button(m.showOriginal ? "Show change" : "Show original") { m.showOriginal.toggle() }
                        .buttonStyle(.plain).font(PKFont.text(12)).foregroundStyle(UIInk.muted).help("Show original (⌥⌘O)")
                    Text("⌥⌘O").font(PKFont.mono(10.5)).foregroundStyle(UIInk.faint)
                }.padding(.top, 4)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
        if editing {
            TextEditor(text: $m.draft)
                .font(PKFont.text(15)).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(.horizontal, 15).padding(.vertical, 12)
                .background(UIInk.card)
                .focused($editorFocus)
                .onAppear { editorFocus = true }
                .accessibilityLabel("Edit the text")
            footer([("esc", "Done", "keep the change; the original stays beside it", { m.leaveEditor() }),
                    ("⌘↵", "Insert", "into the app you came from", { m.insert() })], editing: true)
        } else if let d = it.doc {
            ScrollView { call(d).padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading) }
            footer(m.actions(it, inPlace: false).map { a in (a.key, a.word, a.tip, a.run) }, editing: false)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(marked(m.showOriginal ? it.text : it.current, things: m.found(it), focus: m.foundFocusId == it.id ? m.foundFocus.index : nil))
                        .font(PKFont.text(15)).lineSpacing(5)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let f = m.focusedThing(it), m.foundFocus.menu { thingMenu(it, f) }
                    if let e = it.entry, !e.ocr.isEmpty {
                        Text(e.ocr).font(PKFont.text(13)).foregroundStyle(UIInk.muted).textSelection(.enabled)
                    }
                    if let e = it.entry, !e.drafts.isEmpty {
                        Text(e.drafts.count == 1 ? "1 earlier version" : "\(e.drafts.count) earlier versions").font(PKFont.text(12)).foregroundStyle(UIInk.faint).padding(.top, 6)
                        ForEach(Array(e.drafts.suffix(3).reversed().enumerated()), id: \.offset) { _, d in
                            Text(TapeItem.flat(d)).font(PKFont.text(13)).foregroundStyle(UIInk.muted).lineLimit(2)
                                .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(UIInk.rule).frame(width: 1) }
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 14)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)   // about 70 characters a line, centred
            }
            footer(m.actions(it, inPlace: false).map { a in (a.key, a.word, a.tip, a.run) }, editing: false)
        }
    }

    /// Related: a pill per tag (the only place tags are pills), its own line, then what the store says it is related
    /// to and why ("works at", "part of", "similar topics: …"), the item's other tag first.
    @ViewBuilder func related(_ it: TapeItem) -> some View {
        let tags = it.tags.filter { $0.kind != "app" }
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tags, id: \.self) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Button { m.setFilter(.tag(t)) } label: {
                                HStack(spacing: 5) {
                                    Glyph(t.glyph, size: 12).foregroundStyle(UIInk.muted)
                                    Text(t.name).font(PKFont.text(12.5, .medium)).foregroundStyle(UIInk.ink)
                                }
                                .padding(.horizontal, 8).frame(height: 22)
                                .overlay { Capsule().strokeBorder(UIInk.rule, lineWidth: 0.5) }
                                .contentShape(Capsule())
                            }.buttonStyle(.plain).help("Show everything related to \(t.name)")
                            Text(m.reason(t) ?? t.kindWord).font(PKFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(1)
                        }
                        ForEach(Array(m.links(t, others: tags).enumerated()), id: \.offset) { _, l in
                            HStack(spacing: 6) {
                                Text(l.why).font(PKFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(1)
                                Glyph(EntityRules.glyph(l.kind), size: 11).foregroundStyle(UIInk.muted)
                                Text(l.name).font(PKFont.text(12)).foregroundStyle(UIInk.ink).lineLimit(1)
                            }.padding(.leading, 14)
                            .help("\(t.name): \(l.why) \(l.name) (from your notes)")
                        }
                    }
                }
            }.padding(.top, 6)
            .accessibilityLabel("Related: " + tags.map(\.name).joined(separator: ", "))
        }
    }

    /// The text with the search's matches and (wire round) the things found in it: a dotted underline each, the one
    /// in focus (⌥↓ ⌥↑) on a soft ground.
    func marked(_ s: String, things: [Found], focus: Int?) -> AttributedString {
        var a = marked(s)
        let ns = s as NSString
        for (i, f) in things.enumerated() where NSMaxRange(f.range) <= ns.length {
            guard let rr = Range(f.range, in: s), let lo = AttributedString.Index(rr.lowerBound, within: a), let hi = AttributedString.Index(rr.upperBound, within: a) else { continue }
            a[lo..<hi].underlineStyle = Text.LineStyle(pattern: .dot, color: UIInk.muted)
            if i == focus { a[lo..<hi].backgroundColor = UIInk.soft; a[lo..<hi].underlineStyle = Text.LineStyle(pattern: .solid, color: UIInk.blue) }
        }
        return a
    }

    /// The focused thing's actions (↵ on it): each a verb with its key, the one the keys are on lifted; not built
    /// ones greyed.
    @ViewBuilder func thingMenu(_ it: TapeItem, _ f: Found) -> some View {
        let acts = m.thingActions(it, f)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Glyph(JournalMeta.foundGlyph(f.kind.rawValue), size: 12).foregroundStyle(UIInk.muted)
                Text(FoundRules.one(f.display.isEmpty ? f.words : f.display, 48)).font(PKFont.text(12.5, .medium)).foregroundStyle(UIInk.ink)
            }.padding(.bottom, 2)
            ForEach(Array(acts.enumerated()), id: \.offset) { i, a in
                HStack(spacing: 8) {
                    Text(a.key).font(PKFont.mono(11)).foregroundStyle(UIInk.muted).frame(width: 24, alignment: .leading)
                    Text(a.name).font(PKFont.text(13)).foregroundStyle(a.built ? UIInk.ink : UIInk.faint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background { if i == m.foundFocus.row { RoundedRectangle(cornerRadius: 6).fill(UIInk.soft) } }
                .contentShape(Rectangle())
                .onTapGesture { if a.built { m.foundFocus.menu = false; m.runThing(a, f, it) } }
                .help(a.built ? a.name : a.name + " · not ready yet")
            }
        }
        .padding(8)
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(UIInk.rule, lineWidth: 0.5) }
        .accessibilityLabel("What to do with " + f.kind.rawValue)
    }

    func marked(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard !m.query.isEmpty else { return a }
        for r in JournalSearch.ranges(m.query, in: s) {
            guard let rr = Range(r, in: s), let lo = AttributedString.Index(rr.lowerBound, within: a), let hi = AttributedString.Index(rr.upperBound, within: a) else { continue }
            a[lo..<hi].backgroundColor = UIInk.rule
            a[lo..<hi].font = PKFont.text(15, .semibold)
        }
        return a
    }

    /// A recording: the people with their talk time, the summary, the to-dos, the transcript.
    @ViewBuilder func call(_ d: CallDoc) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(TapeBuild.sides(d).enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 8) {
                        Text(s.me ? "You" : s.name).font(PKFont.text(13)).frame(width: 70, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(UIInk.soft)
                                Capsule().fill(s.me ? UIInk.blue : UIInk.coral).frame(width: max(2, g.size.width * CGFloat(s.secs / max(1, d.secs))))
                            }
                        }.frame(height: 4)
                        Text(TapeRules.clock(s.secs)).font(PKFont.mono(11)).foregroundStyle(UIInk.muted).frame(width: 44, alignment: .trailing)
                    }.help("Talk time: \(s.me ? "you" : s.name), \(TapeRules.clock(s.secs)) of \(TapeRules.clock(d.secs))")
                }
            }
            if !d.points.isEmpty {
                section("Summary", d.points)
            }
            if !d.todos.isEmpty { section("To-dos", d.todos) }
            if !d.turns.isEmpty {
                Text("Transcript").font(PKFont.text(12, .semibold)).foregroundStyle(UIInk.faint)
                ForEach(Array(d.turns.prefix(200).enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(t.who == "Вони" ? (d.people.first.map { String($0.split(separator: " ").first ?? "") } ?? "Them") : "You")
                            .font(PKFont.text(12, .medium)).foregroundStyle(UIInk.muted).frame(width: 56, alignment: .leading)
                        Text(marked(t.text)).font(PKFont.text(14)).lineSpacing(3).textSelection(.enabled)
                    }
                }
            } else if d.live {
                Text("Recording now · the transcript comes when it ends").font(PKFont.text(13)).foregroundStyle(UIInk.muted)
            }
        }
    }
    func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(PKFont.text(12, .semibold)).foregroundStyle(UIInk.faint)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(UIInk.muted).frame(width: 4, height: 4).offset(y: -3)
                    Text(p).font(PKFont.text(14)).lineSpacing(3)
                }
            }
        }
    }

    /// A header chosen: its title and totals, and the keys that unfold it.
    @ViewBuilder func header(_ l: JLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l.kind == .session ? "Session" : l.title).font(PKFont.text(15, .medium))
            if l.kind == .session, l.session >= 0, l.session < m.journal.facts.count {
                let f = m.journal.facts[l.session]
                Text("\(f.app) · \(TapeDraw.time(f.from))–\(TapeDraw.time(f.to)) · \(TapeRules.clock(f.took)) · \(l.sub)").font(PKFont.mono(11.5)).foregroundStyle(UIInk.muted)
                if let t = f.tag { Text("Mostly related to \(t.name)").font(PKFont.text(13)).foregroundStyle(UIInk.muted) }
            } else {
                Text(l.sub).font(PKFont.mono(11.5)).foregroundStyle(UIInk.muted)
            }
            Text((l.open ? "← fold it" : "→ unfold it") + " · ↓ the next line · ⌘↑ ⌘↓ the chunk before or after").font(PKFont.text(12)).foregroundStyle(UIInk.faint).padding(.top, 8)
        }.padding(20)
        Spacer()
    }

    /// The draft Combine made: the editor, and what can be done with it.
    @ViewBuilder var combineDraft: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Glyph("keys", size: 15).foregroundStyle(UIInk.muted)
                Text("Draft · \(m.combineSources.count) items, oldest first").font(PKFont.text(13.5, .medium))
            }
            Text("Draft ready: change it, insert it, or esc keeps it in the journal").font(PKFont.text(12)).foregroundStyle(UIInk.faint)
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
        Rectangle().fill(UIInk.line).frame(height: 0.5)
        TextEditor(text: $m.draft)
            .font(PKFont.text(15)).lineSpacing(4).scrollContentBackground(.hidden)
            .padding(.horizontal, 15).padding(.vertical, 12).background(UIInk.card)
            .focused($editorFocus).onAppear { editorFocus = true }
        footer([("esc", "Done", "keep the draft in the journal", { m.leaveEditor() }),
                ("⌘↵", "Insert", "into the app you came from", { m.insert() })], editing: true)
    }

    /// The actions at the foot: each a verb with its key; the one in focus has the ring.
    func footer(_ acts: [(String, String, String, () -> Void)], editing: Bool) -> some View {
        VStack(spacing: 0) {
            FlowRow(spacing: 6) {
                ForEach(Array(acts.enumerated()), id: \.offset) { i, a in
                    let ring = !editing && m.nav.region == .reader(i)
                    let main = a.1 == "Insert"
                    Button(action: a.3) {
                        HStack(spacing: 6) {
                            Text(a.1).font(PKFont.text(12.5, main ? .medium : .regular)).foregroundStyle(main ? UIInk.paper : UIInk.ink)
                            Text(a.0).font(PKFont.text(11)).foregroundStyle(main ? UIInk.paper.opacity(0.75) : UIInk.faint)
                        }
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(main ? UIInk.ink : UIInk.well))
                        .overlay { if ring { Capsule().strokeBorder(UIInk.blue, lineWidth: 1.5).padding(-2) } }
                        .contentShape(Capsule())
                    }.buttonStyle(.plain).help("\(a.1): \(a.2) (\(a.0))").accessibilityLabel(a.1)
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

/// Buttons that wrap to the next line when the pane is narrow.
struct FlowRow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing; row = max(row, z.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX, x + z.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}

/// The kind id a sidebar filter stands for (its colour mark).
func sideKind(_ f: TapeRules.Filter) -> String {
    if case .kind(let k) = f { return ["picture", "link", "file"].contains(k) ? k : JournalMeta.kindId(k, clip: "text") }
    return ""
}

extension WindowModel {
    /// Why a tag is there, from the entity store (its own line), when it has one.
    func reason(_ t: TapeTag) -> String? { JournalTags.reason(t, store: Entities.store) }
    func links(_ t: TapeTag, others: [TapeTag]) -> [JournalTags.Link] { JournalTags.links(t, others: others.filter { $0 != t }, store: Entities.store, max: 3) }
}

// MARK: the status line

/// The foot: a recording that is going (with Stop), what is shown (or what just happened), the keys of the place in
/// focus, the engine when it is not ready.
struct StatusBar: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        HStack(spacing: 8) {
            if let live = m.docs.first(where: \.live), !m.preview {
                Button { m.openDoc(live) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(UIInk.coral).frame(width: 7, height: 7)
                        Text("Recording «\(live.title)»").font(PKFont.text(12)).lineLimit(1)
                    }
                }.buttonStyle(.plain).help("Open it; Stop recording is at the top")
                Button("Stop") { m.stopRecording() }.controlSize(.small)
            }
            if m.options.isEmpty {
                StatusText(live: m.live, font: PKFont.text(12), color: UIInk.muted, fallback: m.page == .tape ? m.softStatus : "")
            }
            Spacer()
            if !m.engine.isEmpty {
                Circle().fill(m.engine.contains("stop") || m.engine.contains("cannot") ? UIInk.coral : UIInk.faint).frame(width: 6, height: 6)
                Text("Engine: " + m.engine + (m.engine == "starting" || m.engine == "loading model" ? "…" : ""))
                    .font(PKFont.mono(11)).foregroundStyle(UIInk.faint).lineLimit(1)
            } else if m.page == .tape {
                Text(TapeNav.hints(m.navState())).font(PKFont.text(11.5)).foregroundStyle(UIInk.faint).lineLimit(1).help("The keys of the place in focus · ⌘/ Help lists every key")
            }
        }.padding(.horizontal, 14).frame(height: 28)
    }
}

/// Every key of the journal, for Help (the same words as the tooltips and the status line).
enum JournalKeys {
    static let all: [(String, String)] = [
        ("↑ ↓", "Move: the line before or after"), ("⇞ ⇟", "Move by eight lines"),
        ("← →", "Fold or unfold a header; ← up a level; → into the reader's actions"),
        ("⌘↑ ⌘↓", "The chunk of time before or after"),
        ("↵", "Open: unfold a header, open the item (in the reader, or in place without it); in the reader, run the action in focus"),
        ("esc", "Step out: the editor, the actions, the picked items, the open item, the search; then close the window"),
        ("⇥ ⇧⇥", "The next or previous place: search, sidebar, list, reader, the top"),
        ("a letter", "Search: it goes to the search field"), ("⌘F", "Search the journal"), ("⌘K", "Ask Drafter (a command)"),
        ("⌘1-9", "The sidebar's entries (When > Older shows the months and years)"), ("⌘\\", "Show or hide the sidebar"), ("⌥⌘\\", "Show or hide the reader"), ("⌘G", "Group by: Time, Related to, App"),
        ("E", "Edit the text (in the reader)"), ("⌘↵", "Insert into the app you came from"), ("⌘C", "Copy"), ("⌘P", "Pin or Unpin"),
        ("⇧↑ ⇧↓", "Pick several items"), ("⌘⇧E", "Combine the picked items into one draft"),
        ("⌥⌘O", "Show original (a changed item)"), ("⌥⌘R", "Revert: the original text again"),
        ("⌘⌫", "Delete"), ("⌘Z", "Undo the last Delete or Revert"), ("⌘L", "Play a voice note or a recording"),
        ("⇧⌘A", "For agent: a recording for Claude or Codex"), ("⌘O", "Open a recording as a page"),
        ("⌥⌘1 ⌥⌘2", "Gallery or list"), ("⌘+ ⌘-", "Larger or smaller cards (the gallery)"),
        ("arrows (gallery)", "Move in the grid: ↑ ↓ keep the column across labels and headers, ← → wrap"),
        ("space", "Peek: the chosen card large; space or esc closes it, the arrows go on to the next card"),
        ("⇧ arrows", "Pick a range of cards"), ("⌘T", "Go to: a day (\"last Tuesday\", \"12 березня\"), a chunk, a kind, an app"),
        ("⌘[ ⌘]", "Back and forward: where you were before or after"), ("⌘I", "Details: exact time, characters, the other records of the same text"),
        ("drag", "Drag a card or row out as text, a picture or a file; onto Pinned to pin it; inside Pinned to change their order"),
        ("⌘,", "Settings > Look: Journal view (Gallery or List), rows (Soft or Grid), card size, rows (Compact or Roomy), sessions start")]
}

extension View {
    /// The pane that has the keys: a thin inset line in the accent (no box around a row inside it).
    func paneFocus(_ on: Bool) -> some View {
        overlay { if on { Rectangle().strokeBorder(UIInk.blue, lineWidth: 1).padding(1).allowsHitTesting(false) } }
    }
}
