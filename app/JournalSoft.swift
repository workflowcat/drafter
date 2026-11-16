// The journal's soft round (14 November 2026): the gallery of cards beside the list, the panes by width
// (JournalLayout), the slide-over reader, the peek, Go to (⌘T), back and forward (⌘[ ⌘]), the card size, the pinned
// order. The rules are pure and tested (JournalLayout, GoTo, TapeNav); this file only applies them to the window.
import AppKit
import SwiftUI

extension WindowModel {
    // MARK: views and panes

    /// The cards (the default), or the list.
    var gallery: Bool { settings.journalView != "list" }
    var softLook: Bool { gallery || settings.journalLook != "grid" }
    /// What the width allows: the sidebar full, a glyph strip or hidden; the reader docked, a slide-over or closed.
    var panes: (side: JournalLayout.Side, reader: JournalLayout.Reader) {
        JournalLayout.panes(width: Double(width), sidebar: sidebarShown, reader: gallery ? galleryReader : readerPref, gallery: gallery)
    }
    /// The reader slides over the cards or the list (it is not docked) and is open.
    var overShown: Bool { panes.reader != .pane && overOpen && current != nil }

    func setView(_ v: String) {
        guard settings.journalView != v else { return }
        setSetting { $0.journalView = v }
        overOpen = false; peekOn = false
        if nav.region == .peek { nav.region = .list }
        record()
        tapeTick += 1
        DispatchQueue.main.async { if let c = self.chosen { self.scrollToChosen(c) } }
        status = v == "gallery" ? "Gallery · ⌥⌘2 the list" : "List · ⌥⌘1 the gallery"
    }
    /// The gallery's place on the zoom ladder (GalleryZoom): days and lines are held here for the session, the card
    /// sizes are the setting.
    var galleryLevel: GalleryZoom.Level { galleryFar ?? .cards(settings.cardSize) }
    /// A step along the ladder: a pinch (at the pointer) or ⌘+ ⌘-. The card sizes keep their setting.
    func zoomGallery(_ d: Int, at point: NSPoint? = nil) {
        let now = galleryLevel, next = GalleryZoom.step(now, by: d)
        guard next != now else { return }
        galleryView?.prepareZoom(at: point, nearer: next > now)
        if let s = next.cardSize {
            galleryFar = nil
            if s != settings.cardSize { setSetting { $0.cardSize = s } }
        } else { galleryFar = next }
        tapeTick += 1
        status = next.name + " · pinch, or ⌘+ ⌘-"
    }
    func setCardSize(_ d: Int) {
        if gallery { zoomGallery(d); return }
        let n = JournalLayout.step(settings.cardSize + d)
        guard n != settings.cardSize else { return }
        setSetting { $0.cardSize = n }
        tapeTick += 1
        status = ["Small cards", "Medium cards", "Large cards"][n] + " · ⌘+ ⌘-"
        DispatchQueue.main.async { if let c = self.chosen { self.scrollToChosen(c) } }
    }
    /// A look setting: kept on disk (the preview keeps it in memory).
    func setSetting(_ change: (inout Settings) -> Void) {
        if preview { change(&settings) } else { settings = Drafter.shared.change(change) }
    }

    /// After the views took the new state (the layout first, then the scroll).
    func scrollToChosen(_ id: String) {
        DispatchQueue.main.async { if self.gallery { self.galleryView?.scrollTo(id) } else { self.listView?.scrollTo(id) } }
    }

    // MARK: the gallery's grid

    /// The runs of cards between labels and headers: line indices, in order.
    var cardGroups: [[Int]] {
        var out: [[Int]] = [], cur: [Int] = []
        for (i, l) in lines.enumerated() {
            if l.kind == .row { cur.append(i) }
            else if l.kind == .session { continue }        // a session's label sits inside the run (the same runs as the layout)
            else if !cur.isEmpty { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
    func spot(_ groups: [[Int]]) -> JournalLayout.Spot? {
        guard let c = chosen else { return nil }
        for (g, run) in groups.enumerated() { if let k = run.firstIndex(where: { lines[$0].id == c }) { return .init(group: g, index: k) } }
        return nil
    }
    func moveGrid(dx: Int, dy: Int, extend: Bool = false) {
        let groups = cardGroups
        guard !groups.isEmpty else { return }
        let s = spot(groups) ?? .init(group: 0, index: 0)
        let t = spot(groups) == nil ? s : JournalLayout.move(s, dx: dx, dy: dy, counts: groups.map(\.count), cols: max(1, galleryCols))
        let id = lines[groups[t.group][t.index]].id
        if extend {
            if picked.isEmpty, let c = current?.id { picked = [c] }
            if !picked.contains(id) { picked.append(id) }
            chosen = id; open = nil
            status = picked.count > 1 ? "\(picked.count) items picked · ⌘⇧E Combine" : ""
        } else { choose(id) }
        scrollToChosen(id)
    }
    /// The chosen card sits in the top row of the first run (↑ goes to the field from there).
    var onTopRow: Bool {
        let g = cardGroups
        guard let s = spot(g) else { return true }
        return JournalLayout.topRow(s, counts: g.map(\.count), cols: max(1, galleryCols))
    }

    // MARK: the readers

    func openOver() {
        guard current != nil else { return }
        if panes.reader == .pane { nav.region = .reader(0); return }
        overOpen = true; peekOn = false
    }
    func closeOver() { overOpen = false; if case .reader = nav.region { nav.region = .list }; if editing != nil { leaveEditor() } }
    func openPeek() { guard current != nil else { return }; peekOn = true; nav.region = .peek }
    func closePeek() { peekOn = false; if nav.region == .peek { nav.region = .list } }

    // MARK: back and forward

    var place: JournalLayout.Place {
        .init(chosen: chosen, filter: String(describing: filter), group: group.rawValue, query: query, view: settings.journalView)
    }
    /// Keeps where he is (a pick within 1.5 s replaces the last one).
    func record() {
        guard !historyMuted else { return }
        history = JournalLayout.record(history, place, at: Date().timeIntervalSince1970)
        placeFilters[String(describing: filter)] = filter
    }
    func historyStep(_ back: Bool) {
        record()
        let (h, p) = back ? JournalLayout.goBack(history) : JournalLayout.goForward(history)
        guard let p else { status = back ? "Nothing before this" : "Nothing after this"; return }
        history = h
        historyMuted = true
        defer { historyMuted = false }
        if settings.journalView != p.view { setSetting { $0.journalView = p.view } }
        if let f = placeFilters[p.filter], f != filter { filter = f }
        if let g = TapeRules.Group(rawValue: p.group), g != group { group = g }
        if query != p.query { query = p.query } else { refilter() }
        if let c = p.chosen, lines.contains(where: { $0.id == c }) { choose(c); DispatchQueue.main.async { self.scrollToChosen(c) } }
        tapeTick += 1
    }
    var canBack: Bool { history.canBack || (history.current != nil && history.current != place) }
    var canForward: Bool { history.canForward }

    // MARK: Go to (⌘T)

    func openPalette() { palette = ""; paletteIndex = 0; peekOn = false; nav.region = .palette }
    func closePalette() { palette = nil; if nav.region == .palette { nav.region = .list }; focusField += 0 }
    /// What Go to offers for its text: a date first (English or Ukrainian), then the chunks, kinds and apps.
    var paletteResults: [GoTo.Candidate] {
        let q = palette ?? ""
        var out: [GoTo.Candidate] = []
        if let s = GoTo.date(q, now: Date().timeIntervalSince1970, cal: .current) {
            out.append(.init(kind: "date", title: s.title, id: "d|\(s.from)|\(s.to)", glyph: "calendar"))
        }
        var all: [GoTo.Candidate] = []
        for l in lines where l.kind == .chunk || l.kind == .head { all.append(.init(kind: "time", title: l.title, id: l.id, glyph: "clock")) }
        for e in side where e.group != "" && e.group != "When" {
            all.append(.init(kind: e.group, title: e.title, id: "f|" + String(describing: e.filter), glyph: e.glyph))
            placeFilters["f|" + String(describing: e.filter)] = e.filter
        }
        all.append(.init(kind: "", title: "Pinned", id: "f|" + String(describing: TapeRules.Filter.pinned), glyph: "pin"))
        placeFilters["f|" + String(describing: TapeRules.Filter.pinned)] = .pinned
        out += GoTo.rank(q, all)
        return out
    }
    func paletteGo(_ c: GoTo.Candidate? = nil) {
        let list = paletteResults
        guard let c = c ?? (paletteIndex < list.count ? list[paletteIndex] : nil) else { closePalette(); return }
        closePalette()
        record()
        if c.id.hasPrefix("d|") {
            let p = c.id.split(separator: "|"); let from = Double(p[1]) ?? 0, to = Double(p[2]) ?? 0
            goToTime(from: from, to: to, title: c.title)
        } else if c.id.hasPrefix("f|"), let f = placeFilters[c.id] {
            filter = f; refilter()
        } else {
            if lines.first(where: { $0.id == c.id })?.open == false { opens[c.id] = true; reflow() }
            choose(c.id); DispatchQueue.main.async { self.scrollToChosen(c.id) }
        }
        record()
    }
    /// The newest item inside the span (its chunk unfolds), else the nearest older one.
    func goToTime(from: Double, to: Double, title: String) {
        let hit = rows.indices.filter { rows[$0].at >= from && rows[$0].at < to }.first
            ?? rows.indices.filter { rows[$0].at < from }.first
        guard let i = hit else { status = "Nothing from \(title)"; return }
        let id = rows[i].id
        if !lines.contains(where: { $0.id == id }) {
            if filter != .all { filter = .all }
            let ch = "h|" + rows[i].chunk
            opens[ch] = true
            for l in lines where l.kind == .head && l.chunk == rows[i].chunk { opens[l.id] = true }
            refilter()
        }
        if lines.contains(where: { $0.id == id }) { choose(id); DispatchQueue.main.async { self.scrollToChosen(id) } }
        status = "\(title) · " + TapeView.exact(rows[i].at)
    }

    // MARK: the pinned order

    /// Pinned, in his order (newest pins he has not moved come first).
    func pinnedOrder() -> [String] {
        let pins = rows.filter(\.pinned).map(\.id)
        return JournalLayout.pinned(pinOrder, pins: pins)
    }
    /// A drop on the pinned list: the dragged items before `before` (display order only, nothing stored changes).
    func reorderPinned(_ ids: [String], before: String?) {
        pinOrder = JournalLayout.move(pinnedOrder(), ids, before: before)
        if !preview { UserDefaults.standard.set(pinOrder, forKey: "journal.pinOrder") }
        reflow(); tapeTick += 1
    }
    /// A drop on Pinned in the sidebar: the items become pinned.
    func pinDropped(_ ids: [String]) {
        var n = 0
        for id in ids { if let it = item(id), !it.pinned { choose(id); pin(); n += 1 } }
        status = n == 0 ? "Already pinned" : "\(n) pinned"
    }
    /// Pinned shown flat in his order (the reflow calls it when the filter is Pinned).
    func pinnedLines() -> [JLine] {
        let at = Dictionary(rows.indices.map { (rows[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        return pinnedOrder().compactMap { id in at[id].map { JLine(kind: .row, id: id, item: $0, chunk: rows[$0].chunk) } }
    }

    /// The status line (JournalMeta.status): never what the sticky chunk header already says.
    var softStatus: String {
        let f: String? = filter == .all ? nil : TapeRules.visible(side, folded: []).first { $0.filter == filter }?.title
        let w = JournalMeta.status(query: query, results: results, filter: f, sidebarShows: panes.side == .full,
                                   group: group == .time ? nil : group.title.lowercased(), picked: picked.count)
        return w.isEmpty ? "\(results) item\(results == 1 ? "" : "s")" : w
    }
}

// MARK: the panes

/// The journal's panes, soft: rounded panes on the window's well with 8 pt between them; the sidebar on the system's
/// sidebar material (a glyph strip under 640 pt); the gallery or the list; the reader docked, or slid over under
/// 900 pt (and in the gallery when it is not docked); the peek and Go to above them.
struct JournalPanesView: View {
    @EnvironmentObject var m: WindowModel
    let width: CGFloat
    var body: some View {
        let p = m.panes, r = PK.radius("pane"), gap: CGFloat = 8
        VStack(spacing: 0) {
        SearchExtras().padding(.leading, p.side == .full ? m.sidebarWidth + 8 : p.side == .strip ? 54 : 0)
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                switch p.side {
                case .full:
                    TapeSidebar().frame(width: m.sidebarWidth)
                        .background(SideMaterial()).clipShape(RoundedRectangle(cornerRadius: r))
                        .overlay { if JournalMeta.outline(keys: m.nav.region == .sidebar, chosen: m.nav.cursor >= 0).pane { RoundedRectangle(cornerRadius: r).strokeBorder(UIInk.blue, lineWidth: 1) } }
                    PaneEdge(reader: false)
                case .strip:
                    SideStrip().background(SideMaterial()).clipShape(RoundedRectangle(cornerRadius: r)).padding(.trailing, gap)
                case .hidden: EmptyView()
                }
                ZStack(alignment: .top) {
                    if m.gallery { GalleryList(m: m) } else { TapeList(m: m); StickyHead() }
                }
                .background(UIInk.paper)
                .clipShape(RoundedRectangle(cornerRadius: r))
                // one outline at a time: the pane's line only while nothing in it is chosen (JournalMeta.outline)
                .overlay { let o = JournalMeta.outline(keys: m.nav.region == .list, chosen: m.chosen != nil).pane
                    RoundedRectangle(cornerRadius: r).strokeBorder(o ? UIInk.blue : UIInk.line, lineWidth: o ? 1 : 0.5) }
                .overlay(alignment: .top) { CommandOptions().padding(.top, 6).padding(.horizontal, 16) }
                .frame(minWidth: 240)
                if p.reader == .pane, m.readerOn {
                    PaneEdge(reader: true)
                    JournalReader().frame(width: min(m.readerWidth, max(280, width * 0.45)))
                        .clipShape(RoundedRectangle(cornerRadius: r))
                        .overlay { RoundedRectangle(cornerRadius: r).strokeBorder(UIInk.line, lineWidth: 0.5) }
                }
            }
            if m.overShown {
                JournalReader().frame(width: min(m.readerWidth + 40, width - 48))
                    .clipShape(RoundedRectangle(cornerRadius: r))
                    .overlay { RoundedRectangle(cornerRadius: r).strokeBorder(UIInk.line, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.18), radius: 18, x: -4, y: 6)
                    .padding(.vertical, 4)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        }
        .animation(PK.motion("fade") > 0 ? .easeOut(duration: PK.motion("fold")) : nil, value: m.overShown)
        .padding(.horizontal, gap).padding(.bottom, 2)
        .background(UIInk.well)
        .overlay { if m.peekOn, let it = m.current { PeekView(it: it) } }
        .overlay(alignment: .top) { if m.palette != nil { PaletteView().padding(.top, 40) } }
    }
}

/// Space: the chosen card large, above everything; space or esc closes it, the arrows go to the next card.
struct PeekView: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { m.closePeek() }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Glyph(JournalMeta.glyph(it.kindId), size: 15).foregroundStyle(Color(nsColor: PK.series(JournalMeta.series(it.kindId))))
                    Text(JournalMeta.header(noun: it.noun, ago: TimeChunks.relative(it.at, now: m.now, cal: TapeBuild.cal),
                                            took: it.took.flatMap { $0 >= 1 ? TapeRules.clock($0) : nil }, app: it.app, fate: it.fate))
                        .font(PKFont.text(13.5, .medium)).foregroundStyle(UIInk.muted).help(TapeView.exact(it.at))
                    Spacer()
                    Text("space or esc closes · ↵ reader").font(PKFont.text(11.5)).foregroundStyle(UIInk.faint)
                }
                if let e = it.entry, e.clip == .image, it.kind == .copied, !e.picture.isEmpty, let img = TapeDraw.thumb(History.clipURL(e.picture), px: 1400) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: PK.radius("card")))
                    if !e.ocr.isEmpty { Text(e.ocr).font(PKFont.text(13)).foregroundStyle(UIInk.muted).lineLimit(4) }
                } else if let d = it.doc {
                    Text(d.title.isEmpty ? "Recording" : d.title).font(PKFont.text(20, .semibold))
                    ForEach(Array(d.points.prefix(6).enumerated()), id: \.offset) { _, p in Text("· " + p).font(PKFont.text(15)) }
                } else {
                    ScrollView {
                        Text(it.current).font(it.kind == .copied && JournalMeta.codeLike(it.current) ? PKFont.mono(14) : PKFont.text(17))
                            .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24).frame(maxWidth: 720, maxHeight: 560)
            .background(RoundedRectangle(cornerRadius: PK.radius("pane")).fill(UIInk.card))
            .overlay { RoundedRectangle(cornerRadius: PK.radius("pane")).strokeBorder(UIInk.line, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            .padding(40)
        }
        .accessibilityLabel("Peek: " + it.noun)
    }
}

/// Go to (⌘T): a day in words (English or Ukrainian), a chunk, a kind, an app; type to filter, ↑ ↓, ↵ goes.
struct PaletteView: View {
    @EnvironmentObject var m: WindowModel
    @FocusState private var focused: Bool
    var body: some View {
        let list = m.paletteResults
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Glyph("map", size: 15).foregroundStyle(UIInk.muted)
                TextField("Go to", text: Binding(get: { m.palette ?? "" }, set: { m.palette = $0; m.paletteIndex = 0 }),
                          prompt: Text("Go to: last Tuesday, 12 березня, this week, a kind, an app").foregroundColor(UIInk.faint))
                    .textFieldStyle(.plain).font(PKFont.text(15)).focused($focused)
                    .onSubmit { m.paletteGo() }
                    .accessibilityLabel("Go to")
                Text("⌘T").font(PKFont.text(11)).foregroundStyle(UIInk.faint)
            }.padding(.horizontal, 14).frame(height: 44)
            if !list.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                        Button { m.paletteGo(c) } label: {
                            HStack(spacing: 10) {
                                Glyph(c.glyph, size: 14).foregroundStyle(UIInk.muted)
                                Text(c.title).font(PKFont.text(13.5)).foregroundStyle(UIInk.ink).lineLimit(1)
                                Spacer()
                                Text(c.kind == "date" ? "day" : c.kind.lowercased()).font(PKFont.text(11.5)).foregroundStyle(UIInk.faint)
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: PK.radius("row")).fill(i == m.paletteIndex ? UIInk.pick : .clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(6)
            }
        }
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: PK.radius("pane")).fill(UIInk.card))
        .overlay { RoundedRectangle(cornerRadius: PK.radius("pane")).strokeBorder(UIInk.line, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .onAppear { focused = true }
    }
}

/// Under the search field: the query's filters as soft chips (a click or ⌫ at the end removes one), one suggestion
/// line (⇥ or a click takes it), and a quiet "did you mean". Nothing shows while the search is empty.
struct SearchExtras: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        let chips = m.searchChips, offers = m.searchSuggestions, dym = m.searchDidYouMean
        if !m.query.isEmpty, !chips.isEmpty || !offers.isEmpty || dym != nil {
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                    Button { m.dropChip(c) } label: {
                        HStack(spacing: 4) {
                            Text(c.label).font(PKFont.text(12)).foregroundStyle(UIInk.ink)
                            Glyph("close", size: 9).foregroundStyle(UIInk.muted)
                        }.padding(.horizontal, 9).frame(height: 22).background(Capsule().fill(UIInk.pick)).contentShape(Capsule())
                    }.buttonStyle(.plain).help("Filter \(c.label): click or ⌫ at the end of the search removes it").accessibilityLabel("Filter \(c.label), remove")
                }
                if let o = offers.first {
                    Button { m.takeSuggestion(o) } label: {
                        HStack(spacing: 5) {
                            Text("in: \(o.label)?").font(PKFont.text(12)).foregroundStyle(UIInk.muted)
                            Text("⇥").font(PKFont.text(11)).foregroundStyle(UIInk.faint)
                        }.padding(.horizontal, 9).frame(height: 22).overlay { Capsule().strokeBorder(UIInk.rule, style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])) }.contentShape(Capsule())
                    }.buttonStyle(.plain).help("Only items from \(o.label) (⇥ or click)").accessibilityLabel("Filter to \(o.label)")
                }
                if let d = dym {
                    Button { m.query = d.query } label: {
                        (Text("Did you mean ").foregroundColor(UIInk.faint) + Text(d.query).foregroundColor(UIInk.muted)).font(PKFont.text(12))
                    }.buttonStyle(.plain).help(d.why.isEmpty ? "Search for \(d.query)" : d.why)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.bottom, 6)
        }
    }
}
