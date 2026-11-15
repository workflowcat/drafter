// The journal's state and actions (second window round, 14 November 2026): the build off the main thread, the search
// and the filter, the outline of time with its folds, the keys (TapeNav.route decides, this file does), and what he
// does to an item: Insert, Copy, Edit, Pin, Combine, Revert, Delete, Undo. The stored history is never rewritten: his
// changes and drafts go to JournalStore (data/journal.json); Delete goes through the history's own forget, after 8
// seconds in which ⌘Z brings the item back.
import AppKit
import SwiftUI

extension WindowModel {
    // MARK: building

    /// The reader shows: he chose so, or the window is 900 pt or wider.
    /// Docked (JournalLayout.panes), or slid over the cards or the list.
    var readerOn: Bool { panes.reader == .pane || (overOpen && current != nil) }

    /// What the drawn list needs (equal snapshots draw the same).
    var snap: TapeSnap {
        TapeSnap(lines: lines, build: buildTick, chosen: chosen, picked: picked, open: open, gone: goneIds, reader: readerOn,
                 tick: tapeTick, density: settings.tapeDensity, region: nav.region, query: query)
    }

    /// Builds the journal off the main thread (sessions, repeats, tags, chunks); the newest build wins. Then the search
    /// and the filter run on it (`refilter`).
    func rebuildTape() {
        tapeSeq += 1
        let mine = tapeSeq
        let (t, c, ty, d) = (takes, clips, typed, docs)
        let own = journalStore.file.items, changes = journalStore.changes
        let at = preview ? now : Date().timeIntervalSince1970
        if !preview { now = at }
        let store = Entities.store
        let url = preview ? previewTagFile : TapeBuild.diskURL, later = !preview || previewDefer
        let pv = preview, made = previewPastes
        // the paste trail (where clips went): read off the main thread, a week back; the preview has its own
        let work = { TapeBuild.journal(takes: t, clips: c, typed: ty, docs: d, own: own, changes: changes, now: at, store: store, diskURL: url, deferTags: later,
                                       pastes: pv ? made : PasteWatch.read(since: at - 7 * 86400)) }
        let apply: (JournalBuild) -> Void = { [weak self] b in
            guard let self, mine == self.tapeSeq else { return }
            self.journal = b
            var items = b.items
            for i in items.indices where !items[i].ownDraft {
                if let q = items[i].quick, !items[i].text.isEmpty { items[i].pinned = !self.preview && Quick.shared.isPinned(q, items[i].text) }
            }
            if self.preview { for i in items.indices where self.previewPins.contains(items[i].id) { items[i].pinned = true } }
            self.rows = items
            self.buildTick += 1
            self.refilter()
            self.warmSearch()
        }
        // the tags the first paint did not have: worked out after it, then the counts and chips again
        let patch: (JournalBuild) -> Void = { [weak self] f in
            guard let self, mine == self.tapeSeq, self.rows.count == f.items.count else { return }
            var rows = self.rows   // one change of the published list, not one per row
            for i in f.missing { rows[i].tags = f.items[i].tags }
            self.rows = rows
            self.journal.facts = f.facts; self.journal.items = f.items; self.journal.missing = []
            self.buildTick += 1
            self.refilter()
            self.warmSearch()
        }
        if preview {
            let b = work(); apply(b)
            if !b.missing.isEmpty { let t0 = Date(); var f = b; TapeBuild.fillTags(&f, store: store); patch(f); fillMs = Date().timeIntervalSince(t0) * 1000 }
            return
        }
        TapeBuild.queue.async {
            let b = work()
            DispatchQueue.main.async { apply(b) }
            guard !b.missing.isEmpty else { return }
            var f = b; TapeBuild.fillTags(&f, store: store)
            DispatchQueue.main.async { patch(f) }
        }
    }

    /// The search and the filter over the built items, then the outline. The search runs on the index's queue
    /// (JournalSearch.run, JournalEngine): the list keeps what it shows until the answer comes, a newer key drops an
    /// older search, and the same query over the same rows (a filter, a fold) is answered from the last hits at once.
    /// Before the index is built the plain search answers on the main thread, as before.
    func refilter() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            if searchSide.view != JournalSearchView(ready: searchSide.view.ready) { searchSide.view = JournalSearchView(ready: searchSide.view.ready) }
            searchSide.rankedFor = ""
            show(hits: Array(rows.indices), searching: false)
            return
        }
        let v = searchVersion, rv = rowsVersion
        if let c = searchSide.cache, c.query == q, c.version == v { show(hits: c.hits, searching: true); return }
        let eng = searchEngine
        let at: Double? = preview ? now : nil
        let pq = JournalSearch.parse(q, now: at)
        if openedAt != nil, !preview { firstAnswer = (firstAnswer?.from ?? Date(), q) }   // from his first key
        JournalSearch.run(q, rows, version: v, engine: eng, now: at) { [weak self] hits, r in
            guard let self, self.query == q, self.rowsVersion == rv else { return }   // the indices still point at these rows
            // the first answer after an open: from his first key to the hits (the index's, or the plain search's)
            if let fa = self.firstAnswer, fa.query == q, self.openedAt != nil {
                self.openedAt = nil
                log("window: first answer \(Int(Date().timeIntervalSince(fa.from) * 1000)) ms, \(r != nil ? "index" : "plain, index not ready")")
            }
            let idx = hits.map(\.index)
            var view = JournalSearchView(chips: pq.chips, suggestions: pq.offers, ready: r != nil || eng.ready)
            for i in idx where i < self.rows.count && !self.goneIds.contains(self.rows[i].id) {
                view.kindTotals[self.rows[i].kind.word, default: 0] += 1
                view.chunkTotals[self.rows[i].chunk, default: 0] += 1
            }
            if let r {
                view.didYouMean = r.didYouMean; view.didYouMeanWhy = r.didYouMeanWhy; view.ms = r.ms
                self.searchSide.cache = (q, v, idx)
            }
            self.objectWillChange.send()
            self.searchSide.view = view
            // a new query: its best item is the chosen one (the list stays in time order)
            if r != nil, self.searchSide.rankedFor != q, let top = idx.first(where: { !self.goneIds.contains(self.rows[$0].id) }) {
                self.searchSide.rankedFor = q
                self.chosen = self.rows[top].id; self.open = nil
                let id = self.rows[top].id
                if !self.preview { DispatchQueue.main.async { self.listView?.scrollTo(id) } }
            }
            self.show(hits: idx, searching: true)
        }
    }

    /// The index gets the rows as soon as they are built, off the main thread, so the first key after an open is
    /// answered by it (speed round, 15 November 2026: it was made at the first search, a cold build under his key).
    /// Only what changed since the last hand-over is indexed again (JournalEngine.update).
    func warmSearch() {
        guard !preview else { return }
        let rows = self.rows
        searchEngine.update(version: searchVersion, count: rows.count, id: { rows[$0].id }, sig: { rows[$0].searchSig }, doc: { rows[$0].searchDoc })
    }

    /// Changes when the list of rows is rebuilt (row indices move).
    var rowsVersion: Int { buildTick &* 1_000_003 &+ rows.count }
    /// Changes whenever the rows do (a build, a tag patch, a pin, a change): the index re-reads them only then.
    var searchVersion: Int { buildTick &* 1_000_003 &+ tapeTick &* 31 &+ rows.count }

    /// The search's own state for this window (an extension cannot hold stored properties).
    var searchSide: JournalSearchSide {
        let k = ObjectIdentifier(self)
        if let s = JournalSearchSide.all[k] { return s }
        let s = JournalSearchSide()
        JournalSearchSide.all[k] = s
        return s
    }
    /// The index, made at the first search (previews: on the main thread, at once).
    var searchEngine: JournalEngine {
        if let e = searchSide.engine { return e }
        let e = JournalEngine(inline: preview)
        let store = Entities.store
        let names = { NameFormTable(store.surfaces.mapValues { $0.map { ($0.index, $0.how) } },
                                    needsContext: Set(store.surfaceFlags.filter { $0.value.needs_context == true }.keys)) }
        if preview { e.service.index.names = names() } else { e.service.queue.async { e.service.index.names = names() } }
        e.onReady = { [weak self] in
            guard let self else { return }
            log("window: search index built, \(self.rows.count) items, \(Int(e.buildMs)) ms")
            self.refilter()
        }
        searchSide.engine = e
        return e
    }

    /// What the window can draw beside the search field: the query's filters (`searchChips`), date words offered as
    /// filters (`searchSuggestions`), the corrected query (`searchDidYouMean`), counts of the found set per kind word and
    /// per chunk id (`searchTotals`). Plain data; the typed words work without any of it.
    var searchChips: [SearchChip] { searchSide.view.chips }
    var searchSuggestions: [SearchOffer] { searchSide.view.suggestions }
    var searchDidYouMean: (query: String, why: String)? { searchSide.view.didYouMean.map { ($0, searchSide.view.didYouMeanWhy) } }
    var searchTotals: (kinds: [String: Int], chunks: [String: Int]) { (searchSide.view.kindTotals, searchSide.view.chunkTotals) }
    /// A chip's ✕ or a suggestion picked: the query text changes (and the search runs again).
    func dropChip(_ c: SearchChip) { query = JournalSearch.parse(query).removing(c) }
    func takeSuggestion(_ o: SearchOffer) { query = JournalSearch.parse(query).applying(o) }

    /// The filter over the found items (hidden rows, those deleted and still undoable, left out), the side counts, the
    /// outline.
    private func show(hits found: [Int], searching: Bool) {
        let hit = searching ? found.filter { $0 < rows.count && !goneIds.contains(rows[$0].id) }.sorted() : found
        let facets = rows.map(\.facet)
        var vis = [Bool](repeating: false, count: rows.count)
        for i in hit where filter.matches(facets[i]) { vis[i] = true }
        results = vis.reduce(0) { $0 + ($1 ? 1 : 0) }
        // the sidebar counts what the search left
        let found2 = searching ? hit.map { facets[$0] } : facets
        var entries = TapeRules.sidebar(found2, appGlyph: { TapeDraw.appMark($0) ?? "list" })
        let tree = timeTree(vis)
        if group == .time {
            let when = TapeRules.when(tree.map { n in
                (n.key.id, n.key.title, n.totals.items, "\(n.key.title): \(TimeChunks.words(n.totals)) · picking it moves the list there")
            }, olderOpen: olderOpen)
            entries.insert(contentsOf: when, at: 2)
        }
        side = entries
        outline = (tree, vis)
        reflow()
        if firstPaint == nil, !rows.isEmpty { firstPaint = Date().timeIntervalSince1970 }
    }

    /// The outline again from the last search and filter (a fold, an unfold): no search, no counts.
    func reflow() {
        let (tree, vis) = outline
        lines = filter == .pinned && group == .time && query.isEmpty ? pinnedLines()
            : group == .time ? flatten(tree, vis: vis) : flattenGroups(vis, facets: rows.map(\.facet))
        if let c = chosen, lines.contains(where: { $0.id == c }) {} else {
            chosen = lines.first { $0.kind == .row }?.id ?? lines.first { $0.selectable }?.id
            open = nil
        }
        if !picked.isEmpty { let ids = Set(lines.map(\.id)); picked.removeAll { !ids.contains($0) } }
    }

    /// The tree of chunks over the visible items' sessions.
    func timeTree(_ vis: [Bool]) -> [TimeChunks.Node] {
        var ins: [TimeChunks.SessionIn] = []
        for (s, m) in journal.sessions.enumerated() {
            let shown = m.filter { $0 < vis.count && vis[$0] }
            guard !shown.isEmpty else { continue }
            let f = journal.facts[s]
            ins.append(TimeChunks.SessionIn(id: "\(s)", path: journal.paths[s], active: f.took, recordings: shown.filter { rows[$0].doc != nil }.count, items: shown.count))
        }
        return TimeChunks.tree(ins)
    }

    func isOpen(_ id: String, _ k: TimeChunks.Key, chunk: String) -> Bool {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return true }   // search results: everything unfolded
        if gallery, k.level == .session { return true }                             // the gallery: a session is a label, its cards show
        return opens[id] ?? TimeChunks.openByDefault(k, chunk: chunk, fold: settings.journalFold)
    }

    /// The outline as shown: headers, their totals, and only what is unfolded below them.
    func flatten(_ tree: [TimeChunks.Node], vis: [Bool]) -> [JLine] {
        var out: [JLine] = []
        func walk(_ n: TimeChunks.Node, depth: Int, parent: String?, chunk: String) {
            switch n.key.level {
            case .session:
                guard let s = Int(n.key.id) else { return }
                let shown = journal.sessions[s].filter { $0 < vis.count && vis[$0] }
                if shown.count == 1 {
                    out.append(JLine(kind: .row, id: rows[shown[0]].id, item: shown[0], chunk: chunk, parent: parent))
                    return
                }
                let id = "s|" + rows[shown[0]].id
                let o = isOpen(id, n.key, chunk: chunk)
                out.append(JLine(kind: .session, id: id, sub: "\(shown.count) items", open: o, item: shown[0], session: s, chunk: chunk, parent: parent))
                if o { for i in shown { out.append(JLine(kind: .row, id: rows[i].id, item: i, chunk: chunk, parent: id, inSession: true)) } }
            case .part:
                out.append(JLine(kind: .part, id: "p|" + n.key.id, title: n.key.title, chunk: chunk, parent: parent))
                for c in n.children { walk(c, depth: depth, parent: parent, chunk: chunk) }
            default:
                let id = "h|" + n.key.id
                let isChunk = n.key.level == .chunk
                let ch = isChunk ? id : chunk
                let o = isOpen(id, n.key, chunk: ch.replacingOccurrences(of: "h|", with: ""))
                out.append(JLine(kind: isChunk ? .chunk : .head, id: id, depth: depth, title: n.key.title, sub: TimeChunks.words(n.totals), open: o,
                                 chunk: ch.replacingOccurrences(of: "h|", with: ""), parent: parent))
                if o { for c in n.children { walk(c, depth: depth + 1, parent: id, chunk: ch.replacingOccurrences(of: "h|", with: "")) } }
            }
        }
        for n in tree { walk(n, depth: 0, parent: nil, chunk: "") }
        return out
    }

    /// Group by Related to or App: one header per group, the items under it, newest first.
    func flattenGroups(_ vis: [Bool], facets: [TapeFacet]) -> [JLine] {
        let idx = vis.indices.filter { vis[$0] }
        let secs = TapeRules.sections(facets, rows: idx, by: group, day: { _ in (0, "") })
        var out: [JLine] = []
        for s in secs {
            let id = "g|" + s.title
            let o = opens[id] ?? true
            out.append(JLine(kind: .chunk, id: id, title: s.title, sub: TapeRules.summary(facets, rows: s.rows), open: o))
            if o { for i in s.rows { out.append(JLine(kind: .row, id: rows[i].id, item: i, chunk: rows[i].chunk, parent: id)) } }
        }
        return out
    }

    // MARK: the chosen line

    var currentLine: JLine? { chosen.flatMap { c in lines.first { $0.id == c } } }
    /// The chosen item (nil when a header or a session is chosen).
    var current: TapeItem? {
        guard let l = currentLine, l.kind == .row, l.item >= 0, l.item < rows.count else { return nil }
        return rows[l.item]
    }
    func item(_ id: String) -> TapeItem? { rows.first { $0.id == id } }

    func choose(_ id: String) {
        if chosen != id { open = nil; showOriginal = false }
        chosen = id
        if !NSEvent.modifierFlags.contains(.shift) { picked = [] }
        record()
    }

    func move(_ by: Int) {
        guard page == .tape, !commandMode else { return }
        let sel = lines.indices.filter { lines[$0].selectable }
        guard !sel.isEmpty else { return }
        let i = chosen.flatMap { c in sel.firstIndex { lines[$0].id == c } } ?? -1
        let j = max(0, min(sel.count - 1, i < 0 ? 0 : i + by))
        choose(lines[sel[j]].id)
    }

    /// Return: a command runs; a header folds or unfolds; an item opens in place (no reader) or a recording opens
    /// as its page.
    func enter() {
        if commandMode { plan(); return }
        if let l = currentLine, l.foldable { toggleFold(l.id); return }
        guard let it = current else { return }
        if let d = it.doc { openDoc(d); return }
        open = open == it.id ? nil : it.id
    }

    /// Esc, step by step (pages: back). On the list TapeNav decides; this is for the preview and the menu.
    func escape() {
        if page != .tape { back(); return }
        if commandMode { commandMode = false; command = ""; options = []; return }
        if editing != nil { leaveEditor(); return }
        if open != nil { open = nil; return }
        if !query.isEmpty { query = "" }
    }

    func back() { stopPlaying(); page = .tape; focusField += 1 }
    func openDoc(_ d: CallDoc) { doc = d; page = .doc; if d.turns.isEmpty { loadWarnings(d) } }
    func show(_ p: Page) { page = page == p ? .tape : p; if page == .tape { focusField += 1 } }
    func startCommand() { page = .tape; commandMode = true; nav.region = .search; focusField += 1 }

    // MARK: folds

    func setOpen(_ id: String, _ o: Bool) {
        guard let l = lines.first(where: { $0.id == id }), l.foldable, l.open != o else { return }
        opens[id] = o
        reflow()
    }
    func toggleFold(_ id: String) {
        guard let l = lines.first(where: { $0.id == id }), l.foldable else { return }
        setOpen(id, !l.open)
    }
    /// ⌘↑ ⌘↓: the chunk header before or after the chosen line.
    func jumpChunk(_ d: Int) {
        let heads = lines.indices.filter { lines[$0].kind == .chunk }
        guard !heads.isEmpty else { return }
        let i = chosen.flatMap { c in lines.firstIndex { $0.id == c } } ?? 0
        let target: Int?
        if d < 0 { target = heads.last { $0 < i } ?? heads.first } else { target = heads.first { $0 > i } ?? heads.last }
        if let t = target { choose(lines[t].id); DispatchQueue.main.async { self.listView?.scrollTo(self.lines[t].id) } }
    }

    // MARK: several items

    /// ⇧↑ ⇧↓: the next item joins the picked ones (headers are skipped).
    func extend(_ d: Int) {
        let rowsAt = lines.indices.filter { lines[$0].kind == .row }
        guard !rowsAt.isEmpty else { return }
        let i = chosen.flatMap { c in rowsAt.firstIndex { lines[$0].id == c } }
        if picked.isEmpty, let c = current?.id { picked = [c] }
        let j = max(0, min(rowsAt.count - 1, (i ?? -1) + d))
        let id = lines[rowsAt[j]].id
        if picked.contains(id), let c = chosen, picked.count > 1 { picked.removeAll { $0 == c } } else if !picked.contains(id) { picked.append(id) }
        chosen = id; open = nil
        status = picked.count > 1 ? "\(picked.count) items picked · ⌘⇧E Combine" : ""
    }
    /// A ⇧-click: every item between the chosen one and this one.
    func pickTo(_ id: String) {
        let rowsAt = lines.indices.filter { lines[$0].kind == .row }
        guard let a = rowsAt.firstIndex(where: { lines[$0].id == (chosen ?? id) }), let b = rowsAt.firstIndex(where: { lines[$0].id == id }) else { choose(id); return }
        picked = (min(a, b)...max(a, b)).map { lines[rowsAt[$0]].id }
        chosen = id
        status = "\(picked.count) items in the pick · ⌘⇧E Combine"
    }

    // MARK: the sidebar, the panes, the grouping

    func setFilter(_ f: TapeRules.Filter) {
        if case .when(let id) = f {
            if id == TapeRules.olderId { olderOpen.toggle(); refilter(); return }   // Older unfolds to the months and years
            goTo(id); return
        }
        filter = filter == f && f != .all ? .all : f
        page = .tape
        refilter()
    }
    /// A When entry: the chunk opens and comes to the top of the list.
    func goTo(_ chunkId: String) {
        let id = "h|" + chunkId
        if lines.first(where: { $0.id == id })?.open == false { opens[id] = true; reflow() }
        choose(id)
        DispatchQueue.main.async { self.listView?.scrollTo(id) }
    }
    func pickSidebar(_ i: Int) {
        let vis = TapeRules.visible(side, folded: folded)
        guard i >= 0, i < vis.count else { return }
        setFilter(vis[i].filter)
    }
    /// The When group's Older entry is unfolded (kept with the folds).
    var olderOpen: Bool {
        get { folded.contains("open:Older") }
        set { if newValue { folded.insert("open:Older") } else { folded.remove("open:Older") }; savePrefs() }
    }
    func setGroup(_ g: TapeRules.Group) { group = g; savePrefs(); refilter() }
    func nextGroup() { let all = TapeRules.Group.allCases; setGroup(all[((all.firstIndex(of: group) ?? 0) + 1) % all.count]) }
    func toggleSidebar() { sidebarShown.toggle(); if !sidebarShown, nav.region == .sidebar { nav.region = .list }; savePrefs() }
    func toggleReader() {
        if panes.reader != .pane, !(gallery && width >= CGFloat(JournalLayout.wide)) { overOpen ? closeOver() : openOver(); return }
        overOpen = false
        if gallery { galleryReader = panes.reader != .pane } else { readerPref = !readerOn }
        if !readerOn, editing != nil { leaveEditor() }
        if !readerOn, case .reader = nav.region { nav.region = .list }
        savePrefs()
    }
    func fold(_ group: String) { if folded.contains(group) { folded.remove(group) } else { folded.insert(group) }; savePrefs() }

    private static let prefs = UserDefaults.standard
    func loadPrefs() {
        guard !preview else { return }
        let d = Self.prefs
        if d.object(forKey: "journal.sidebar") != nil { sidebarShown = d.bool(forKey: "journal.sidebar") }
        if d.double(forKey: "journal.sidebarWidth") > 0 { sidebarWidth = CGFloat(d.double(forKey: "journal.sidebarWidth")) }
        if d.object(forKey: "journal.reader") != nil { readerPref = d.bool(forKey: "journal.reader") }
        if d.double(forKey: "journal.readerWidth") > 0 { readerWidth = CGFloat(d.double(forKey: "journal.readerWidth")) }
        folded = Set(d.stringArray(forKey: "journal.folded") ?? [])
        group = TapeRules.Group(rawValue: d.string(forKey: "journal.group") ?? "") ?? .time
        pinOrder = d.stringArray(forKey: "journal.pinOrder") ?? []
        if d.object(forKey: "journal.galleryReader") != nil { galleryReader = d.bool(forKey: "journal.galleryReader") }
    }
    func savePrefs() {
        guard !preview else { return }
        let d = Self.prefs
        d.set(sidebarShown, forKey: "journal.sidebar"); d.set(Double(sidebarWidth), forKey: "journal.sidebarWidth")
        if let r = readerPref { d.set(r, forKey: "journal.reader") }
        if let r = galleryReader { d.set(r, forKey: "journal.galleryReader") }
        d.set(Double(readerWidth), forKey: "journal.readerWidth")
        d.set(Array(folded), forKey: "journal.folded"); d.set(group.rawValue, forKey: "journal.group")
    }

    // MARK: what he does to an item

    /// An item's actions, each a verb with its key. inPlace: under the open row (no reader), else the reader's footer
    /// and the right-click menu.
    func actions(_ it: TapeItem, inPlace: Bool) -> [RowAction] {
        var out: [RowAction] = []
        if let d = it.doc {
            if d.hasAudio { out.append(RowAction(key: "⌘L", word: playing == d.id ? "Stop" : "Play", tip: "play both sides from the start") { [weak self] in
                guard let self else { return }; self.playing == d.id ? self.stopPlaying() : self.play(d, from: 0) }) }
            out.append(RowAction(key: "⌘C", word: "Copy", tip: "the notes on the clipboard: title, people, summary, to-dos") { [weak self] in self?.copyNotes(d) })
            if !d.turns.isEmpty { out.append(RowAction(key: "⇧⌘A", word: "For agent", tip: "a line that points Claude or Codex at this recording, on the clipboard") { [weak self] in self?.sendToAgent(d) }) }
            out.append(RowAction(key: "⌘O", word: "Open", tip: "the whole recording as a page, with screenshots") { [weak self] in self?.openDoc(d) })
            return out
        }
        if it.shot != nil { return shotActions(it) }   // a screenshot: send again, mark up again, copy for agent, show file
        out.append(RowAction(key: "E", word: "Edit", tip: "change the text in the reader; the original is kept") { [weak self] in self?.edit() })
        out.append(RowAction(key: "⌘↵", word: "Insert", tip: "into the app you came from" + (origin?.localizedName.map { " (\($0))" } ?? "")) { [weak self] in self?.insert() })
        out.append(RowAction(key: "⌘C", word: "Copy", tip: "on the clipboard") { [weak self] in self?.copyItem() })
        if !formEntries(it, insert: false).isEmpty {   // wire round: the item (or the thing in focus) in its other written forms
            out.append(RowAction(key: "⇧⌘C", word: "Copy as…", tip: "another written form, with a preview each; ⌥ keeps it as a new clip") { [weak self] in self?.showForms(insert: false) })
            out.append(RowAction(key: "⇧⌘↵", word: "Insert as…", tip: "another written form into the app you came from") { [weak self] in self?.showForms(insert: true) })
        }
        out.append(RowAction(key: "⌘E", word: "Pick parts", tip: "keep only the parts you need, as a new clip") { PickPanel.open(it) })
        out.append(RowAction(key: "⌘P", word: it.pinned ? "Unpin" : "Pin", tip: it.pinned ? "take it off the top of the Quick panel" : "keep it on top of the Quick panel") { [weak self] in self?.pin() })
        if it.change != nil {
            out.append(RowAction(key: "⌥⌘O", word: showOriginal ? "Show change" : "Show original", tip: "the text as it was kept") { [weak self] in self?.showOriginal.toggle() })
            out.append(RowAction(key: "⌥⌘R", word: "Revert", tip: "drop your change: the original text again (⌘Z Undo)") { [weak self] in self?.revert() })
        }
        if let e = it.entry, !e.audio.isEmpty {
            out.append(RowAction(key: "⌘L", word: "Play", tip: "the voice note's audio (kept 14 days)") { [weak self] in self?.play(e) })
        }
        out.append(RowAction(key: "⌘⌫", word: "Delete", tip: "out of the journal and the history; ⌘Z Undo within 8 seconds") { [weak self] in self?.delete() })
        return out
    }

    func copyItem() {
        guard let it = current else { return }
        if let d = it.doc { copyNotes(d); return }
        let t = editing == it.id ? draft : it.current
        History.copy(t); status = "On the clipboard · \(t.count) characters"
    }

    func pin() {
        guard let it = current, let i = rows.firstIndex(where: { $0.id == it.id }) else { return }
        if it.ownDraft { journalStore.pin(String(it.id.dropFirst(2)), !it.pinned) }
        else if let q = it.quick, !it.text.isEmpty, !preview { Quick.shared.togglePin(q, it.text, app: it.app, at: it.at) }
        else if preview { if it.pinned { previewPins.remove(it.id) } else { previewPins.insert(it.id) } }
        rows[i].pinned.toggle()
        status = rows[i].pinned ? "Pinned · on top of the Quick panel" : "Not pinned"
        tapeTick += 1; refilter()
    }
    func togglePin(_ it: TapeItem) { choose(it.id); pin() }

    /// ⌘↵: the text (his change, or the editor's) into the app he came from: that app comes to the front and the text
    /// goes in at its caret through the Quick panel's way (Capture.put: never a skipped app, a password field or under
    /// secure input; there it goes on the clipboard).
    func insert() {
        let text: String
        if editing != nil { text = draft } else if let it = current, it.doc == nil { text = it.current } else { return }
        guard !text.isEmpty else { return }
        guard !preview else { status = "In the field · \(text.count) characters"; return }
        guard let o = origin, !o.isTerminated else {
            History.copy(text); status = "On the clipboard · \(text.count) characters · no app to insert into"; return
        }
        if editing != nil { leaveEditor() }
        o.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let how = Capture.put(text: text, origin: o)
            log("window: insert \(text.count) chars, \(how)")
        }
        status = "In the field · \(o.localizedName ?? "the app")"
    }

    // MARK: editing

    func edit() {
        guard let it = current, it.doc == nil else { return }
        if !readerOn { readerPref = true }
        editing = it.id; draft = it.current; showOriginal = false
        nav.region = .editor
    }

    /// ⌘⇧E: the picked items, oldest first, as one new draft in the editor.
    func combine() {
        let its = picked.compactMap(item).filter { $0.doc == nil }
        guard its.count >= 2 else { return }
        if !readerOn { readerPref = true }
        draft = JournalStore.combine(its.map { ($0.at, $0.current) })
        combineSources = its.map(\.id)
        editing = "new"; nav.region = .editor
        status = "Draft ready · \(its.count) items, oldest first · esc keeps it in the journal"
    }

    /// Leaves the editor: a change is kept beside the original (none when the text is the original again); a new
    /// draft goes into the journal.
    func leaveEditor() {
        guard let id = editing else { return }
        editing = nil
        nav.region = .reader(0)
        focusField += 1
        if id == "new" {
            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let d = journalStore.add(kind: "draft", text: t, sources: combineSources, pinned: false)
            picked = []; chosen = "j:" + d.id
            status = "Draft ready · in the journal (⌘P Pin keeps it on top)"
            rebuildTape(); return
        }
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[i].ownDraft { journalStore.update(String(id.dropFirst(2)), text: draft); rebuildTape(); return }
        let before = rows[i].change
        journalStore.change(id, to: draft, original: rows[i].text)
        rows[i].change = journalStore.changed(id)
        if rows[i].change != before {
            status = rows[i].change == nil ? "The original again" : "Changed · the original is kept (⌥⌘O Show original)"
            buildTick += 1; refilter()
        }
    }

    func revert() {
        guard let it = current, let i = rows.firstIndex(where: { $0.id == it.id }), let c = journalStore.revert(it.id) else { return }
        rows[i].change = nil; showOriginal = false
        undos.append(("Revert", { [weak self] in
            guard let self else { return }
            self.journalStore.restore(it.id, c)
            if let j = self.rows.firstIndex(where: { $0.id == it.id }) { self.rows[j].change = c.text }
            self.buildTick += 1; self.refilter(); self.status = "Your change is back"
        }))
        status = "The original again · ⌘Z Undo"
        buildTick += 1; refilter()
    }

    // MARK: delete and undo

    /// ⌘⌫: struck through at once with "⌘Z Undo" beside it; out of the files when the 8 seconds are over (or at the
    /// next delete).
    func delete() {
        guard let it = current else { return }
        if it.ownDraft {
            guard let gone = journalStore.remove(String(it.id.dropFirst(2))) else { return }
            undos.append(("Delete", { [weak self] in self?.journalStore.put(gone); self?.chosen = it.id; self?.rebuildTape() }))
            move(1); status = "Draft out of the journal · ⌘Z Undo"
            rebuildTape(); return
        }
        guard it.quick != nil else { return }
        commitGone()
        let w = DispatchWorkItem { [weak self] in self?.commitGone() }
        gone = (it, w); goneIds.insert(it.id)
        undos.append(("Delete", { [weak self] in self?.undoRemove() }))
        if !preview { DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w) }
        open = nil
        status = "Delete: 8 s to undo · ⌘Z Undo"
    }
    func undoLast() { guard let u = undos.popLast() else { return }; u.run() }
    func undoRemove() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil; goneIds.remove(g.item.id)
        chosen = g.item.id; status = "Back in the journal"
    }
    func commitGone() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil
        let it = g.item
        if let q = it.quick, !preview {
            if Quick.shared.isPinned(q, it.text) { Quick.shared.togglePin(q, it.text, app: it.app, at: it.at) }
            History.forget(q, it.entry?.text.isEmpty == false ? it.entry!.text : it.text, drafts: it.entry?.drafts ?? [])
        }
        switch it.kind {
        case .copied: clips.removeAll { "c:\(Int($0.when.timeIntervalSince1970 * 1000)):\($0.text.count)" == it.id }
        case .typed: typed.removeAll { "t:" + $0.id == it.id }
        case .said: takes.removeAll { "v:" + $0.id == it.id }
        case .call: break
        }
        goneIds.remove(it.id)
        undos.removeAll { $0.name == "Delete" }
        if chosen == it.id { move(1) }
        if status.hasPrefix("Delete") { status = "" }
        rebuildTape()
        log("window: deleted a \(it.kind.word) item")
    }

    // MARK: keys

    /// The facts TapeNav needs, from the window's state.
    func syncNav() { nav = navState() }
    /// The facts TapeNav needs, as a value (the status line's hints read it without changing anything).
    func navState() -> TapeNav.State {
        var nav = self.nav
        let sel = lines.indices.filter { lines[$0].selectable }
        let ci = chosen.flatMap { c in lines.firstIndex { $0.id == c } }
        nav.rows = sel.count
        nav.row = ci.flatMap { sel.firstIndex(of: $0) } ?? 0
        let l = ci.map { lines[$0] }
        nav.head = l?.foldable ?? false
        nav.folded = !(l?.open ?? true)
        nav.parent = l?.parent != nil
        nav.open = open != nil && open == chosen
        nav.picked = max(1, picked.count)
        nav.query = !query.isEmpty
        nav.command = commandMode
        nav.sidebar = sidebarShown
        nav.sidebarCount = TapeRules.visible(side, folded: folded).count
        nav.reader = readerOn
        nav.readerActions = current.map { actions($0, inPlace: false).count } ?? 0
        nav.buttons = (!readerOn && open != nil && open == chosen) ? current.map { actions($0, inPlace: true).count } ?? 0 : 0
        if nav.region == .editor, editing == nil { nav.region = .reader(0) }
        nav.gallery = gallery
        nav.cols = max(1, galleryCols)
        nav.over = panes.reader != .pane
        if gallery { nav.row = onTopRow ? 0 : max(nav.cols, nav.row) }   // the grid: ↑ on the top row goes to the field
        if nav.region == .peek, !peekOn { nav.region = .list }
        if nav.region == .palette, palette == nil { nav.region = .list }
        return nav
    }

    /// One key in the window. true: the window took it; false: it goes on (to the search field or the editor).
    func key(_ e: NSEvent) -> Bool {
        guard page == .tape else { return false }
        syncNav()
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(e.keyCode)
        let inEditor = nav.region == .editor
        let onItem = current != nil && nav.region != .search
        // a thing found in the chosen text (wire round): ⌥↓ ⌥↑, then ↵, its action keys and esc while it has the focus
        if !inEditor, onItem, nav.region != .palette, let r = foundKey(code: code, mods: mods, chars: e.charactersIgnoringModifiers) { return r }
        // the window's own keys
        if !inEditor {
            switch (mods, code) {
            case ([.command], 42): toggleSidebar(); return true                     // ⌘\ the sidebar
            case ([.command, .option], 42): toggleReader(); return true             // ⌥⌘\ the reader
            case ([.command], 5): nextGroup(); return true                          // ⌘G group by
            case ([.command], 8) where onItem && currentShot != nil: copyShotForAgent(); return true   // ⌘C a shot: copy for agent
            case ([.command], 14) where currentShot != nil: markShot(); return true                  // ⌘E a shot: mark up again
            case ([.command], 31) where currentShot != nil: showShotFile(); return true              // ⌘O a shot: show the file
            case ([.command], 8) where onItem: copyItem(); return true              // ⌘C Copy
            case ([.command, .shift], 8) where onItem: showForms(insert: false); return true             // ⇧⌘C Copy as…
            case ([.command, .shift], 36), ([.command, .shift], 76): if onItem { showForms(insert: true); return true }   // ⇧⌘↵ Insert as…
            case ([.command], 35) where current != nil: pin(); return true          // ⌘P Pin
            case ([.command], 14) where current != nil: if let it = current { PickPanel.open(it) }; return true   // ⌘E Pick parts
            case ([.command], 51) where current != nil: delete(); return true       // ⌘⌫ Delete
            case ([.command], 6) where !undos.isEmpty && !(nav.region == .search && !query.isEmpty): undoLast(); return true   // ⌘Z Undo
            case ([.command, .option], 31) where current?.change != nil: showOriginal.toggle(); return true   // ⌥⌘O
            case ([.command, .option], 15) where current?.change != nil: revert(); return true               // ⌥⌘R
            case ([.command], 31) where current?.doc != nil: if let d = current?.doc { openDoc(d) }; return true // ⌘O
            case ([.command, .option], 18): setView("gallery"); return true         // ⌥⌘1 the gallery
            case ([.command, .option], 19): setView("list"); return true            // ⌥⌘2 the list
            case ([.command], 24), ([.command, .shift], 24), ([.command], 69): setCardSize(1); return true   // ⌘+
            case ([.command], 27), ([.command], 78): setCardSize(-1); return true   // ⌘-
            case ([.command], 34) where current != nil: detailsOpen.toggle(); if !readerOn { openOver() }; return true   // ⌘I Details
            default: break
            }
        }
        // ⇥ on a shot in the list: the send-to list again (elsewhere ⇥ moves between the panes)
        if code == 48, mods.isEmpty, ShotJournalRules.tabSends(isShot: currentShot != nil, inList: nav.region == .list, picked: picked.count) {
            sendShot(); return true
        }
        // the search's extras: ⇥ takes the offered date filter, ⌫ at the end of a filter word removes the whole filter
        if nav.region == .search, !commandMode, mods.isEmpty {
            if code == 48, let o = searchSuggestions.first { takeSuggestion(o); return true }
            if code == 51, let c = searchChips.last, NSMaxRange(c.range) == (query as NSString).length { dropChip(c); return true }
        }
        let k: TapeNav.Key
        switch (code, mods) {
        case (125, []): k = .down
        case (126, []): k = .up
        case (125, [.shift]): k = .shiftDown
        case (126, [.shift]): k = .shiftUp
        case (125, [.command]): k = .cmdDown
        case (126, [.command]): k = .cmdUp
        case (123, []): k = .left
        case (124, []): k = .right
        case (116, []): k = .pageUp
        case (121, []): k = .pageDown
        case (48, []): k = .tab
        case (48, [.shift]): k = .backTab
        case (36, []), (76, []): k = .ret
        case (36, [.command]), (76, [.command]): k = .insert
        case (53, []): k = .esc
        case (14, [.command, .shift]): k = .combine
        case (17, [.command]): k = .goTo                                          // ⌘T Go to (⌘O stays Open a recording)
        case (33, [.command]): k = .back                                          // ⌘[
        case (30, [.command]): k = .forward                                       // ⌘]
        case (49, []) where nav.region != .search && nav.region != .editor && nav.region != .palette: k = .space
        case (123, [.shift]): k = .shiftLeft
        case (124, [.shift]): k = .shiftRight
        case (18...23, [.command]), (25, [.command]), (26, [.command]), (28, [.command]):
            let digits: [Int: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            guard let n = digits[code] else { return false }
            k = .digit(n)
        default:
            guard mods.subtracting(.shift).isEmpty, let ch = e.characters, let c = ch.first, !c.isNewline, c.isLetter || c.isNumber || c.isPunctuation || c == " " else { return false }
            k = (c == "e" || c == "E") && mods.isEmpty ? .e : .letter
        }
        let (s, eff) = TapeNav.route(nav, k)
        nav = s
        switch eff {
        case .pass: return false
        case .none: return true
        case .moveRow(let n): move(n)
        case .pickSidebar(let i): pickSidebar(i)
        case .toggleRow: enter()
        case .revealButtons: if let it = current, it.doc == nil { open = it.id; syncNav(); if nav.buttons > 0 { nav.region = .button(0) } }
        case .runButton(let i): if let it = current { let a = actions(it, inPlace: true); if i < a.count { a[i].run() } }
        case .runReader(let i): if let it = current { let a = actions(it, inPlace: false); if i < a.count { a[i].run() } }
        case .runTop(let i): show([.names, .shortcuts, .settings, .help][min(3, i)])
        case .fold: if let c = chosen { setOpen(c, false) }
        case .unfold: if let c = chosen { setOpen(c, true) }
        case .toParent: if let p = currentLine?.parent { choose(p) }
        case .extend(let d): extend(d)
        case .single: picked = []; status = ""
        case .jumpChunk(let d): jumpChunk(d)
        case .closeRow: open = nil
        case .clearSearch: query = ""
        case .endCommand: commandMode = false; command = ""; options = []
        case .plan: plan()
        case .closeWindow: if !preview { NSApp.keyWindow?.performClose(nil) }
        case .typeInSearch: focusField += 1; return false
        case .edit: edit()
        case .leaveEditor: leaveEditor()
        case .combine: combine()
        case .insert: insert()
        case .openPalette: openPalette()
        case .closePalette: closePalette()
        case .palettePick: paletteGo()
        case .paletteMove(let d): paletteIndex = max(0, min(max(0, paletteResults.count - 1), paletteIndex + d))
        case .historyBack: historyStep(true)
        case .historyForward: historyStep(false)
        case .openOver: openOver()
        case .closeOver: closeOver()
        case .peek: openPeek()
        case .closePeek: closePeek()
        case .moveGrid(let d): moveGrid(dx: 0, dy: d)
        case .moveCard(let d): moveGrid(dx: d, dy: 0)
        case .extendGrid(let dx, let dy): moveGrid(dx: dx, dy: dy, extend: true)
        }
        tapeTick += 1
        return true
    }

}
