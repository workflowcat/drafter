// The journal: the window's list (code names keep "tape"). First round ("Tape", 14 November 2026): one column, newest
// first. Second round (same day; Andrii: "kinda hard to navigate", "wasting a lot of space", "more compact",
// "actually name stuff", "inspired by Obsidian", "say how long something took", "whether something has been done today
// or last week, did like lunch, or very old"): the structure changed.
// - Three panes: a named sidebar (All, Pinned, When, Kinds, Related to, Apps; counts), the list, the reader on the
//   right (JournalPanes.swift). A slim top bar and a status line.
// - The list is an outline of time that grows coarser with age (TimeChunks): Today and Yesterday by part of the day,
//   this week and last week by day, this month by week, earlier months by week, earlier years by month. Under them,
//   sessions: a stretch in one app with gaps under 10 minutes (TapeRules.sessions), one line each. Repeats fold
//   inside a session (×3). Every header folds with ← and →.
// - Rows are 28 pt (compact) or 36 pt (comfortable, `tapeDensity`): the time by its chunk, the kind, one line of
//   text, one related chip, how long it took, the app by name.
// Keys: app/TapeNavRules.swift. Display rules: app/TapeRules.swift, app/TimeChunkRules.swift. Tags: JournalTags.
// Search: JournalSearch. His changes and drafts: JournalStore.
//
// Speed: rows are merged, put in sessions, folded, tagged and given their chunk off the main thread (`TapeBuild.journal`,
// tags cached per row); the outline holds only what is unfolded; the view lays lines out with arithmetic and draws
// only the lines in view. Nothing jumps when the list updates: the chosen line keeps its place on screen.
import AppKit
import SwiftUI

/// One item in the journal.
struct TapeItem: Identifiable, Equatable {
    let id: String
    let kind: TapeKind
    let at: Double
    let app: String
    let line: String           // the text on one line, as stored
    var entry: Entry?
    var doc: CallDoc?
    // set by `TapeBuild.dress` (display only)
    var shown = ""             // what the closed row says (a chat export's message, a web page's lead)
    var tags: [TapeTag] = []   // what it is related to, at most 2
    var repeats = 1            // the same text this many times within a few minutes, folded into this row
    var took: Double?          // how long it took, in seconds
    var pinned = false
    var change: String?        // his own change of the text (JournalStore); the stored row keeps the original
    var chunk = ""             // the chunk of time it sits in (TimeChunks id)
    var hay = ""               // what the search looks in, lower case (set once per build)
    // soft round (display only): the other records of the same text, what happened to it, where it went
    var also: [JournalMeta.Also] = []
    var fate: String?          // "sent in Claude", "in Claude", "copied"
    var to: [String] = []      // the apps a clip was pasted into (PasteTrail), or where a merged text went
    var est = false            // a draft whose start is an estimate
    var shot: ShotPack?        // a capture kept as a shot pack (shot.json, read on the build queue, ShotJournal.pack)
    /// The kind for marks and colours: spoken, typed, copied, call, picture, link, file.
    var kindId: String { doc != nil ? "call" : JournalMeta.kindId(kind.word, clip: entry?.clip.rawValue ?? "text") }
    var quick: QuickKind? { switch kind { case .copied: return .copied; case .typed: return .typed; case .said: return .voice; case .call: return nil } }
    /// The stored text (a take with no final text: its live words).
    var text: String { if let e = entry { return e.text.isEmpty ? e.raw : e.text }; return doc?.title ?? "" }
    /// What Insert and Copy take: his change, else the stored text.
    var current: String { change ?? text }
    /// A journal draft (Combine, kept in JournalStore), not a row of the history files.
    var ownDraft: Bool { id.hasPrefix("j:") }
    static func == (a: TapeItem, b: TapeItem) -> Bool {
        a.id == b.id && a.entry == b.entry && a.doc == b.doc && a.repeats == b.repeats && a.tags == b.tags && a.pinned == b.pinned && a.change == b.change
            && a.also == b.also && a.to == b.to && a.shot == b.shot
    }
    var facet: TapeFacet {
        TapeFacet(kind: kind.word, clip: entry?.clip.rawValue ?? "text", app: app, at: at, tags: tags, pinned: pinned)
    }
    /// The one chip a row shows: the first tag that says more than the app column does.
    var chip: TapeTag? { tags.first { $0.kind != "app" } }
    /// Its kind for people, one: "Voice note", "Clip", "Link", "Recording".
    var noun: String {
        if let d = doc { return d.call ? "Recording" : "Voice note" }
        return TapeRules.one(kind.word, clip: entry?.clip.rawValue ?? "text")
    }
    var glyph: String {
        if let d = doc { return d.call ? "phone" : "waves" }
        return entry.flatMap { TapeDraw.clipMark($0.clip) } ?? kind.mark
    }

    static func flat(_ s: String) -> String {
        if !s.contains(where: \.isNewline) { return s.trimmingCharacters(in: .whitespaces) }   // one line: most rows
        return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// One line of the outline: a chunk of time, a day, week, month or year, a part of the day (a quiet label), a
/// session, an item; or (Group by Related to or App) a group.
struct JLine: Equatable {
    enum Kind: Equatable { case chunk, head, part, session, row }
    let kind: Kind
    let id: String
    var depth = 0
    var title = ""
    var sub = ""
    var open = true
    var item = -1           // row: its index in the items; session: its first item
    var session = -1        // session: its index
    var chunk = ""          // the chunk it sits in
    var parent: String?     // the header above it (← goes there)
    var inSession = false   // a row under a session line
    var foldable: Bool { kind != .row && kind != .part }
    var selectable: Bool { kind != .part }
}

/// What the off-main build hands over: the items (dressed, repeats folded inside sessions, newest first), the sessions
/// (indices into the items, newest first), each session's facts and path in time.
struct JournalBuild {
    var items: [TapeItem] = []
    var sessions: [[Int]] = []
    var facts: [TapeRules.SessionFacts] = []
    var paths: [[TimeChunks.Key]] = []
    var itemSession: [Int] = []
    var now: Double = 0
    var ms: Double = 0
    var missing: [Int] = []     // items whose tags are not known yet (worked out after the first paint, `fillTags`)
}

enum TapeBuild {
    /// His calendar: Monday starts the week.
    static let cal: Calendar = { var c = Calendar.current; c.firstWeekday = 2; c.locale = Locale(identifier: "en_GB"); return c }()
    /// One queue for every build: the tag cache is only touched there.
    static let queue = DispatchQueue(label: "drafter.journal", qos: .userInitiated)

    /// All kinds merged, newest first. Pure: runs off the main thread.
    static func rows(takes: [Entry], clips: [Entry], typed: [Entry], docs: [CallDoc], own: [JournalStore.Item] = []) -> [TapeItem] {
        var out: [TapeItem] = []
        out.reserveCapacity(takes.count + clips.count + typed.count + docs.count + own.count)
        for e in clips {
            out.append(TapeItem(id: "c:\(Int(e.when.timeIntervalSince1970 * 1000)):\(e.text.count)", kind: .copied, at: e.when.timeIntervalSince1970, app: e.app, line: TapeItem.flat(e.text), entry: e))
        }
        for e in typed {
            let t = (e.touched ?? e.when).timeIntervalSince1970
            out.append(TapeItem(id: "t:" + e.id, kind: .typed, at: t, app: e.app, line: TapeItem.flat(e.text.isEmpty ? e.summary : e.text), entry: e))
        }
        for e in takes where !e.audioOnly {
            out.append(TapeItem(id: "v:" + e.id, kind: .said, at: e.when.timeIntervalSince1970, app: e.app, line: TapeItem.flat(e.summary), entry: e))
        }
        for d in docs {
            out.append(TapeItem(id: "d:" + d.id, kind: .call, at: d.started.timeIntervalSince1970, app: d.app, line: d.title, doc: d))
        }
        for o in own {   // his drafts from Combine
            let e = Entry(id: o.id, when: Date(timeIntervalSince1970: o.at), app: "Journal", text: o.text, audio: "")
            var it = TapeItem(id: "j:" + o.id, kind: .typed, at: o.at, app: "Journal", line: TapeItem.flat(o.text), entry: e)
            it.pinned = o.pinned
            out.append(it)
        }
        out.sort { $0.at > $1.at }
        return out
    }

    /// One row for one text kept as several kinds (JournalMeta.merge): the row where it began keeps the others as
    /// `also`, what happened to it as `fate`. Display only: every stored row stays.
    static func mergeKinds(_ rows: [TapeItem]) -> [TapeItem] {
        let mr = rows.map { r in
            JournalMeta.Row(kind: r.ownDraft || r.entry?.clip != nil && r.entry?.clip != .text ? "own" : r.kind.word, at: r.at,
                            text: r.kind == .said ? (r.entry?.summary ?? "") : r.text, app: r.app, sent: r.entry?.sent ?? false)
        }
        let g = JournalMeta.merge(mr)
        guard !g.isEmpty else { return rows }
        var out = rows, drop = Set<Int>()
        for (o, others) in g {
            out[o].also = others.sorted { mr[$0].at < mr[$1].at }.map { JournalMeta.Also(kind: mr[$0].kind, app: mr[$0].app, at: mr[$0].at, sent: mr[$0].sent) }
            out[o].fate = JournalMeta.fate(others.map { mr[$0] })
            var to: [String] = []
            for j in others where mr[j].kind == "typed" && !mr[j].app.isEmpty && !to.contains(mr[j].app) { to.append(mr[j].app) }
            out[o].to = to
            drop.formUnion(others)
        }
        return out.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Where each clip went: the paste trail's apps for the clip's text (PasteTrail.destinations).
    static func trail(_ rows: inout [TapeItem], pastes: [PasteTrail.Paste]) {
        guard !pastes.isEmpty else { return }
        let idx = rows.indices.filter { rows[$0].kind == .copied && rows[$0].entry != nil }
        let d = PasteTrail.destinations(clips: idx.map { (rows[$0].at, PasteTrail.hash(rows[$0].text)) }, pastes: pastes)
        for (k, i) in idx.enumerated() where !d[k].isEmpty { rows[i].to = d[k].filter { $0 != rows[i].app || d[k].count == 1 } }
    }

    /// Tags per row, kept between builds in memory and on disk (`TagDisk`, data/journal-tags.json). Only on `queue`
    /// (or on the main thread in the preview).
    static var tagCache: [String: [TapeTag]] = [:]
    static var disk: TagDisk?
    static var diskURL: URL? { Home.data.appendingPathComponent("journal-tags.json") }

    static func tagKey(_ it: TapeItem) -> String { it.id + "|\(it.doc.map { $0.people.count } ?? it.text.count)" }
    static func cachedTags(_ key: String) -> [TapeTag]? {
        if let t = tagCache[key] { return t }
        if let t = disk?.get(key) { tagCache[key] = t; return t }
        return nil
    }
    /// What an item is related to (JournalTags), worked out now; kept in memory and on disk.
    static func computeTags(_ it: TapeItem, store: EntityStore) -> [TapeTag] {
        let t: [TapeTag]
        if let d = it.doc { t = JournalTags.tags(text: d.title, clip: "text", app: it.app, chat: nil, people: d.people, store: store) }
        else if let e = it.entry {
            let d = TapeRules.display(it.kind == .said ? e.summary : it.text, kind: it.kind.word, clip: e.clip.rawValue, title: e.clipTitle)
            t = JournalTags.tags(text: d.chat != nil ? d.line : it.text, clip: e.clip.rawValue, app: it.app, chat: d.chat, store: store)
        } else { t = [] }
        let k = tagKey(it)
        tagCache[k] = t; disk?.put(k, t)
        return t
    }

    /// The journal, built: merged, in sessions, repeats folded inside each session, dressed, each session's facts
    /// and chunk path. Off the main thread. `deferTags`: tags not in the cache are left for `fillTags`, so the list
    /// paints first.
    static func journal(takes: [Entry], clips: [Entry], typed: [Entry], docs: [CallDoc], own: [JournalStore.Item], changes: [String: String],
                        now: Double, store: EntityStore, diskURL url: URL? = nil, deferTags: Bool = false, pastes: [PasteTrail.Paste] = []) -> JournalBuild {
        let t0 = Date()
        let sign = TagDisk.sign(store)
        if disk == nil || disk?.file.sign != sign || disk?.url != url {
            if disk?.file.sign != sign { tagCache.removeAll() }
            disk = TagDisk(url: url, sign: sign)
        }
        let shotRows = ShotJournalRules.newestPerShot(clips.map { ($0.shot, $0.when.timeIntervalSince1970) }).map { clips[$0] }
        var rows = mergeKinds(rows(takes: takes, clips: shotRows, typed: typed, docs: docs, own: own))
        trail(&rows, pastes: pastes)
        let tz = cal.timeZone
        let raw = TapeRules.sessions(rows.map { r in
            (r.kind.word, r.app, r.at, Int(floor((r.at + Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: r.at)))) / 86400)))
        })
        var b = JournalBuild(); b.now = now
        b.items.reserveCapacity(rows.count)
        let frame = TimeChunks.Frame(now: now, cal: cal)
        for s in raw {
            let sub = s.map { rows[$0] }
            let groups = TapeRules.collapse(sub.map { ($0.kind.word, $0.app, $0.at, $0.kind == .call ? "" : $0.text) })
            var members: [Int] = []
            for g in groups {
                var it = dress(sub[g[0]], store: store)
                if let t = cachedTags(tagKey(it)) { it.tags = t }
                else if deferTags { b.missing.append(b.items.count) }
                else { it.tags = computeTags(it, store: store) }
                it.repeats = g.count
                it.change = changes[it.id]
                if let e = it.entry {
                    it.hay = [e.text, e.raw, e.app, e.title, ClipRules.searchExtra(e.clip, text: e.text, title: e.clipTitle, ocr: e.ocr), it.change ?? "",
                              it.shot.map(ShotJournalRules.searchText) ?? ""].joined(separator: "\n").lowercased()
                }
                members.append(b.items.count)
                b.items.append(it)
                b.itemSession.append(b.sessions.count)
            }
            b.sessions.append(members)
        }
        facts(&b)
        for (si, m) in b.sessions.enumerated() {
            let path = frame.path(b.facts[si].to)
            b.paths.append(path)
            for i in m { b.items[i].chunk = path[0].id }
        }
        if tagCache.count > 40_000 { tagCache.removeAll() }
        if b.missing.isEmpty { keepDisk(b) }
        b.ms = Date().timeIntervalSince(t0) * 1000
        return b
    }

    /// Each session's facts (its tag among them) from its items.
    static func facts(_ b: inout JournalBuild) {
        let facets = b.items.map(\.facet), took = b.items.map(\.took)
        b.facts = b.sessions.map { TapeRules.sessionFacts(facets, took: took, rows: $0) }
    }

    /// The tags the first paint left out, worked out (off the main thread), the session facts again, the disk file
    /// written.
    static func fillTags(_ b: inout JournalBuild, store: EntityStore) {
        for i in b.missing { b.items[i].tags = computeTags(b.items[i], store: store) }
        facts(&b)
        keepDisk(b)
    }
    private static func keepDisk(_ b: JournalBuild) {
        guard let d = disk else { return }
        d.keep(Set(b.items.map(tagKey)))
        d.save()
    }

    /// One row as the window shows it: the line to show, how long it took (tags: `computeTags`). Display only: the
    /// stored row is not changed.
    static func dress(_ r: TapeItem, store: EntityStore) -> TapeItem {
        var it = r
        if let d = it.doc {
            it.shown = d.title.isEmpty ? (d.call ? "Recording" : "Voice note") : d.title
            it.took = TapeRules.took(kind: "call", secs: d.secs, live: d.live)
            return it
        }
        guard let e = it.entry else { return it }
        // a draft cut by the old tail window shows from its first whole word (DraftCaptureRules.shownText)
        let src = it.kind == .said ? e.summary : it.kind == .typed && !it.ownDraft ? DraftCaptureRules.shownText(it.text, sent: e.sent) : it.text
        let d = TapeRules.display(src, kind: it.kind.word, clip: e.clip.rawValue, title: e.clipTitle)
        it.shown = d.line
        it.est = e.est
        if !e.shot.isEmpty, let p = ShotJournal.pack(e.shot) { it.shot = p; it.shown = ShotJournalRules.cardLine(p, fallback: d.line) }
        switch it.kind {
        case .said: it.took = TapeRules.took(kind: "spoken", secs: e.secs)
        case .typed: it.took = TapeRules.took(kind: "typed", secs: 0, from: e.started?.timeIntervalSince1970, to: (e.touched ?? e.when).timeIntervalSince1970)
        default: break
        }
        return it
    }

    /// The two sides of a call (one for a long note): who, the face, the colour and how long each spoke.
    struct Side { let name: String; let face: String; let me: Bool; let secs: Double }
    static func sides(_ d: CallDoc) -> [Side] {
        var me = 0.0, them = 0.0
        if d.timed {
            for (i, t) in d.turns.enumerated() {
                guard let s = t.start else { continue }
                let next = d.turns[(i + 1)...].first { $0.start != nil }?.start ?? max(d.secs, s)
                let len = min(120, max(0, next - s))
                if t.who == "Вони" { them += len } else { me += len }
            }
        } else {
            let a = d.turns.filter { $0.who != "Вони" }.reduce(0) { $0 + $1.text.count }, b = d.turns.filter { $0.who == "Вони" }.reduce(0) { $0 + $1.text.count }
            let all = Double(max(1, a + b))
            me = d.secs * Double(a) / all; them = d.secs * Double(b) / all
            if a + b == 0 { me = d.call ? d.meSecs : d.secs; them = d.call ? d.themSecs : 0 }
        }
        let other = d.people.first.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "them"
        var out = [Side(name: "me", face: "short", me: true, secs: me)]
        if d.call { out.append(Side(name: other, face: d.people.isEmpty ? "person" : "bob", me: false, secs: them)) }
        return out
    }

    static func clock(_ s: Double) -> String { TapeRules.clock(s) }
}

/// Sizes of one density.
struct TapeMetrics {
    let rowH: CGFloat, text: CGFloat, lh: CGFloat, sectionH: CGFloat, sideH: CGFloat, partH: CGFloat
    static func of(_ density: String) -> TapeMetrics {
        density == "comfortable" ? TapeMetrics(rowH: 36, text: 15, lh: 22, sectionH: 36, sideH: 24, partH: 26)
                                 : TapeMetrics(rowH: 28, text: 14, lh: 20, sectionH: 30, sideH: 20, partH: 22)
    }
}

/// One action on an item: its key, its name (a verb), what it does (the tooltip) and the action.
struct RowAction { let key: String; let word: String; let tip: String; let run: () -> Void }

/// What the drawn list needs to know besides the items; equal snapshots draw the same.
struct TapeSnap: Equatable {
    var lines: [JLine] = []
    var build = 0                       // a new build of the items
    var chosen: String?
    var picked: [String] = []
    var open: String?
    var gone: Set<String> = []
    var reader = false
    var tick = 0
    var density = "compact"
    var region: TapeNav.Region = .search
    var query = ""
}

// MARK: the view

/// The journal's list, drawn (AppKit): only the lines in view are drawn; the layout is arithmetic.
final class TapeView: NSView, NSViewToolTipOwner, NSDraggingSource {
    weak var model: WindowModel?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }   // the field keeps the keys (TapeNav routes them)
    // the columns: the time ends at timeR, the kind glyph (or a session's fold mark) at glyphX, the text at textX
    static let timeR: CGFloat = 70, glyphX: CGFloat = 80, textX: CGFloat = 104, durW: CGFloat = 46
    /// One step in: the items of a session sit this far right of the session line, a thin guide under its fold mark.
    static let step: CGFloat = 18, guideX: CGFloat = 86
    var mt = TapeMetrics.of("compact")
    var font: NSFont { PK.text(mt.text) }   // asked each time: a theme can change the face
    var snap = TapeSnap()
    var items: [TapeItem] = []
    var facts: [TapeRules.SessionFacts] = []

    struct Placed { let y: CGFloat; let h: CGFloat }
    private(set) var placed: [Placed] = []
    private var lineIndex: [String: Int] = [:]
    private var hitRects: [(NSRect, () -> Void)] = []
    private var tips: [Int: [(NSRect, String)]] = [:]
    private var faces: [String: NSImage] = [:]
    private var laidWidth: CGFloat = 0

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    var lines: [JLine] { snap.lines }
    /// The app column: the app's name in quiet text with its glyph, or the glyph alone when the list is narrow.
    var appW: CGFloat { bounds.width >= 560 ? 104 : 22 }
    /// The soft look (Settings > Look > Journal list look): rounded rows, no hairlines, no tag column, real app icons,
    /// a colour mark per kind, three actions on hover. The cluster at the right drops the tag, then the app's name,
    /// then the length as the list narrows (JournalMeta.fit).
    var soft: Bool { model?.softLook ?? false }
    var durWs: CGFloat { soft && bounds.width < 440 ? 0 : Self.durW }
    var durX: CGFloat { bounds.width - appW - durWs }
    private var hoverLine: String?
    private var down: (point: NSPoint, id: String)?
    /// The related column: the tag as quiet text with its kind's glyph, at one place on every row; none when narrow.
    var tagW: CGFloat { !soft && bounds.width >= 640 ? 136 : 0 }
    var tagX: CGFloat { durX - 8 - tagW }
    var textW: CGFloat { durX - Self.textX - 12 }

    // MARK: layout

    func height(_ l: JLine) -> CGFloat {
        switch l.kind {
        case .chunk: return mt.sectionH
        case .part: return mt.partH
        case .head, .session: return mt.rowH
        case .row:
            guard l.item >= 0, l.item < items.count else { return mt.rowH }
            let it = items[l.item]
            return rowHeight(it, chosen: it.id == snap.chosen, open: it.id == snap.open && !snap.reader, step: l.inSession ? Self.step : 0)
        }
    }
    func rowHeight(_ it: TapeItem, chosen on: Bool, open: Bool, step: CGFloat = 0) -> CGFloat {
        if let d = it.doc { return callH(d, on: on && !snap.reader) }
        guard open, let e = it.entry else { return mt.rowH }
        let n = TapeDraw.lines(it.current.isEmpty ? e.summary : it.current, width: textW - step, font: font, lh: mt.lh, max: 40)
        var h: CGFloat = (mt.rowH - mt.lh) / 2 + CGFloat(n) * mt.lh + 6 + 16 + 10 + clipExtraH(e, step: step)
        if !e.drafts.isEmpty { h += 20 + CGFloat(min(3, e.drafts.count)) * 20 + 4 }
        return h + TapeDraw.capH + 10
    }
    static let pictureH: CGFloat = 200
    private func picture(_ e: Entry) -> NSImage? {
        e.clip == .image && !e.picture.isEmpty ? TapeDraw.thumb(History.clipURL(e.picture), px: 720) : nil
    }
    private func ocrText(_ e: Entry) -> String { e.ocr.split(whereSeparator: \.isNewline).joined(separator: " ") }
    func clipExtraH(_ e: Entry, step: CGFloat = 0) -> CGFloat {
        var h: CGFloat = 0
        if picture(e) != nil { h += Self.pictureH + 8 }
        let t = ocrText(e)
        if !t.isEmpty { h += CGFloat(TapeDraw.lines(t, width: textW - step, font: PK.text(13), lh: 18, max: 6)) * 18 + 6 }
        return h
    }
    /// A recording: its title line and a line for each side; its outline only when it is chosen with no reader.
    func callH(_ d: CallDoc, on: Bool) -> CGFloat {
        let sides = CGFloat(d.call ? 2 : 1)
        var h = mt.rowH + sides * mt.sideH + 4
        if on { h += CGFloat(outline(d).count) * mt.sideH + TapeDraw.capH + 10 }
        return h
    }
    func outline(_ d: CallDoc) -> [String] {
        if !d.points.isEmpty { return Array(d.points.prefix(3)) }
        if d.live { return ["Recording…"] }
        return d.turns.prefix(3).map { TapeItem.flat($0.text) }
    }

    /// A new snapshot: lays out again and keeps the anchor line where it was on screen; the chosen line comes into
    /// view (below the sticky header) when it changed.
    func apply(_ s: TapeSnap, items newItems: [TapeItem], facts f: [TapeRules.SessionFacts]) {
        let clip = enclosingScrollView?.contentView
        let top = clip?.bounds.minY ?? 0
        let moved = s.chosen != snap.chosen || s.open != snap.open
        var anchor: (id: String, dy: CGFloat)?
        if let c = snap.chosen, let i = lineIndex[c], i < placed.count, placed[i].y + placed[i].h > top, placed[i].y < top + (clip?.bounds.height ?? 0) { anchor = (c, placed[i].y - top) }
        else if let l = firstLine(atOrBelow: top) { anchor = (lines[l].id, placed[l].y - top) }
        snap = s; items = newItems; facts = f
        layout(width: bounds.width)
        if let clip, clip.bounds.height >= 1 {
            var y = top
            if let a = anchor, let i = lineIndex[a.id] { y = placed[i].y - a.dy }
            if moved, let c = s.chosen, let i = lineIndex[c] { y = reveal(i, from: y, height: clip.bounds.height) }
            y = max(0, min(y, frame.height - clip.bounds.height))
            if abs(y - top) > 0.5 { clip.scroll(to: NSPoint(x: 0, y: y)); enclosingScrollView?.reflectScrolledClipView(clip) }
        }
        needsDisplay = true
        reportChunk()
    }
    /// The scroll top that shows line `i` whole below the sticky header, moving as little as it can.
    private func reveal(_ i: Int, from y0: CGFloat, height vh: CGFloat) -> CGFloat {
        var y = y0
        let l = placed[i], head = mt.sectionH
        if l.y < y + head { y = l.y - head }
        else if l.y + l.h > y + vh { y = min(l.y - head, l.y + l.h - vh + 8) }
        return y
    }
    /// Puts line `id` at the top (under the sticky header): the sidebar's When entries, ⌘↑ ⌘↓.
    func scrollTo(_ id: String) {
        guard let i = lineIndex[id], let clip = enclosingScrollView?.contentView else { return }
        let under = lines[i].kind == .chunk ? 0 : mt.sectionH   // below the sticky chunk header, not under it
        let y = max(0, min(placed[i].y - under, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y)); enclosingScrollView?.reflectScrolledClipView(clip)
        reportChunk()
    }

    func layout(width: CGFloat) {
        laidWidth = width
        var out: [Placed] = [], map: [String: Int] = [:]
        out.reserveCapacity(lines.count)
        var y: CGFloat = 0
        for (i, l) in lines.enumerated() {
            let h = height(l)
            out.append(Placed(y: y, h: h)); map[l.id] = i
            y += h
        }
        placed = out; lineIndex = map; tips = [:]
        let vh = enclosingScrollView?.contentView.bounds.height ?? 0
        let h = max(y + 24, vh)
        if abs(frame.height - h) > 0.5 || abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: h)) }
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        if abs(s.width - laidWidth) > 0.5, s.width > 0 { layout(width: s.width); needsDisplay = true }
    }

    /// The first line whose bottom is below `y` (binary search).
    func firstLine(atOrBelow y: CGFloat) -> Int? {
        var lo = 0, hi = placed.count
        while lo < hi { let mid = (lo + hi) / 2; if placed[mid].y + placed[mid].h <= y { lo = mid + 1 } else { hi = mid } }
        return lo < placed.count ? lo : nil
    }

    /// The chunk at the top of the view, for the sticky header and the status line.
    func reportChunk() {
        guard let m = model else { return }
        let top = enclosingScrollView?.contentView.bounds.minY ?? 0
        var t = "", sub = "", id = ""
        if let i = firstLine(atOrBelow: top + 1) {
            if let k = lines[...i].lastIndex(where: { $0.kind == .chunk }) { t = lines[k].title; sub = lines[k].sub; id = lines[k].id }
        }
        if m.dayTitle != t || m.daySub != sub || m.chunkInView != id {
            DispatchQueue.main.async { m.dayTitle = t; m.daySub = sub; m.chunkInView = id }
        }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        hitRects = []
        guard !lines.isEmpty, let first = firstLine(atOrBelow: dirty.minY) else {
            let s: String
            if let q = model?.query, !q.isEmpty { s = "Nothing matches «\(q)»" }
            else if let f = model?.filter, f != .all { s = "Nothing " + TapeRules.words(f) + " yet" }
            else { s = "The journal is empty: clips, drafts, voice notes and recordings show here" }
            TapeDraw.line(s, NSRect(x: 8, y: 12, width: max(0, bounds.width - 16), height: 22), TapeDraw.at(PK.text(14), PK.muted))
            return
        }
        var i = first
        while i < lines.count, placed[i].y < dirty.maxY {
            let l = lines[i], p = placed[i]
            tips[i] = []
            switch l.kind {
            case .chunk: drawChunk(l, line: i, y: p.y, h: p.h)
            case .head: drawHead(l, line: i, y: p.y, h: p.h)
            case .part: drawPart(l, y: p.y, h: p.h)
            case .session: drawSession(l, line: i, y: p.y, h: p.h)
            case .row: if l.item >= 0, l.item < items.count { drawRow(items[l.item], l, line: i, y: p.y, h: p.h) }
            }
            i += 1
        }
        registerTips()
    }

    private func tip(_ line: Int, _ r: NSRect, _ s: String) { tips[line, default: []].append((r, s)) }
    private func registerTips() {
        removeAllToolTips()
        let vis = visibleRect
        for (_, list) in tips { for (r, _) in list where r.intersects(vis) { addToolTip(r, owner: self, userData: nil) } }
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        for (_, list) in tips { if let t = list.first(where: { $0.0.contains(point) }) { return t.1 } }
        return ""
    }

    // the quiet pieces: one grid, one size each
    /// The fold mark of a header: a chevron, right when folded, down when open.
    private func chevron(_ open: Bool, x: CGFloat, mid: CGFloat, color: NSColor = PK.faint) {
        TapeDraw.glyph(open ? "chevron-down" : "chevron-right", NSRect(x: x, y: mid - 6, width: 12, height: 12), color: color)
    }
    /// The chosen line: a quiet lift of the surface and a 2 pt accent bar at its left; picked lines (⇧↑ ⇧↓) the lift
    /// and an ink bar. No box around a row: the focused pane has a thin inset line (`paneFocus`).
    private func lift(_ id: String, y: CGFloat, h: CGFloat) {
        let on = id == snap.chosen, picked = snap.picked.count > 1 && snap.picked.contains(id)
        if soft {   // a rounded shape inset 6 pt; hover one step lighter than the pick; focus a thin ring
            guard on || picked || hoverLine == id else { return }
            let r = NSRect(x: 6, y: y + 1, width: bounds.width - 12, height: h - 2)
            let p = NSBezierPath(roundedRect: r, xRadius: PK.radius("row"), yRadius: PK.radius("row"))
            (on || picked ? PK.pick : PK.hover).setFill(); p.fill()
            if on, JournalMeta.outline(keys: snap.region == .list, chosen: true).accentItem { PK.blue.setStroke(); p.lineWidth = 1; p.stroke() }
            return
        }
        guard on || picked else { return }
        TapeDraw.lift.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: h).fill()
        (on ? PK.blue : PK.muted).setFill(); NSRect(x: 3, y: y, width: TapeDraw.edge, height: h).fill()   // inside the pane's focus line
    }

    /// A chunk of time: its title in 13 semibold, its totals in quiet mono, a hairline under it. The sticky header
    /// draws the same (`StickyHead`).
    private func drawChunk(_ l: JLine, line: Int, y: CGFloat, h: CGFloat) {
        lift(l.id, y: y, h: h)
        let r = NSRect(x: 0, y: y, width: bounds.width, height: h)
        TapeView.drawChunkHead(l.title, l.sub, open: l.open, r, soft: soft)
        tip(line, NSRect(x: 0, y: y, width: 200, height: h), (l.open ? "Fold " : "Unfold ") + l.title + " (← →) · ⌘↑ ⌘↓ the chunk before or after")
    }
    static func drawChunkHead(_ title: String, _ sub: String, open: Bool, _ r: NSRect, soft: Bool = false) {
        if soft {   // lighter and larger, no line under it
            let f = PK.text(17, .medium), a = TapeDraw.at(f, PK.ink), mid = r.midY + 3
            TapeDraw.glyph(open ? "chevron-down" : "chevron-right", NSRect(x: r.minX + 12, y: mid - 6, width: 12, height: 12), color: PK.faint)
            let tw = min(TapeDraw.width(title, a), r.width * 0.6)
            TapeDraw.line(title, NSRect(x: r.minX + 30, y: TapeDraw.lineTop(f, mid: mid), width: tw, height: 24), a)
            let sf = PK.num(11.5)
            TapeDraw.line(sub, NSRect(x: r.minX + 30 + tw + 12, y: TapeDraw.lineTop(sf, mid: mid), width: max(0, r.width - tw - 60), height: 16), TapeDraw.at(sf, PK.faint))
            return
        }
        let f = PK.text(13, .semibold), a = TapeDraw.at(f, PK.ink)
        let mid = r.midY + 1
        TapeDraw.glyph(open ? "chevron-down" : "chevron-right", NSRect(x: r.minX + 8, y: mid - 6, width: 12, height: 12), color: PK.faint)
        let tw = min(TapeDraw.width(title, a), r.width * 0.6)
        TapeDraw.line(title, NSRect(x: r.minX + 26, y: TapeDraw.lineTop(f, mid: mid), width: tw, height: 20), a)
        let sa = TapeDraw.at(PK.mono(11), PK.faint)
        TapeDraw.line(sub, NSRect(x: r.minX + 26 + tw + 12, y: TapeDraw.lineTop(PK.mono(11), mid: mid), width: max(0, r.width - tw - 50), height: 16), sa)
        TapeDraw.hairline(x0: r.minX, x1: r.maxX, y: r.maxY - 1)
    }

    /// A day, a week or a month inside a chunk: one line with its fold mark, title and totals.
    private func drawHead(_ l: JLine, line: Int, y: CGFloat, h: CGFloat) {
        lift(l.id, y: y, h: h)
        let mid = y + h / 2, x = 8 + CGFloat(l.depth) * 16
        chevron(l.open, x: x, mid: mid)
        let f = PK.text(13, .medium), a = TapeDraw.at(f, PK.ink)
        let tw = min(TapeDraw.width(l.title, a), bounds.width * 0.5)
        TapeDraw.line(l.title, NSRect(x: x + 18, y: TapeDraw.lineTop(f, mid: mid), width: tw, height: 20), a)
        TapeDraw.line(l.sub, NSRect(x: x + 18 + tw + 12, y: TapeDraw.lineTop(PK.mono(11), mid: mid), width: max(0, bounds.width - x - tw - 40), height: 16), TapeDraw.at(PK.mono(11), PK.faint))
        tip(line, NSRect(x: 0, y: y, width: x + 18 + tw, height: h), (l.open ? "Fold " : "Unfold ") + l.title + " (← →)")
    }

    /// A part of the day (Morning, Midday): a quiet label, not a line he chooses.
    private func drawPart(_ l: JLine, y: CGFloat, h: CGFloat) {
        let f = PK.text(11.5, .medium)
        TapeDraw.line(l.title, NSRect(x: Self.textX, y: y + h - 18, width: 200, height: 16), TapeDraw.at(f, PK.faint))
    }

    /// A session: its start in the gutter, the fold mark, the app's glyph and name in medium, its length in the
    /// duration column and its item count in the app column (the same columns as an item's), its tag in the related
    /// column. Its items sit one step in, under a thin guide.
    private func drawSession(_ l: JLine, line: Int, y: CGFloat, h: CGFloat) {
        guard l.session >= 0, l.session < facts.count else { return }
        let f = facts[l.session], on = l.id == snap.chosen
        lift(l.id, y: y, h: h)
        let mid = y + h / 2
        let tf = soft ? PK.num(11.5) : PK.mono(11.5)
        let ts = TimeChunks.rowTime(f.from, chunk: l.chunk, cal: TapeBuild.cal)
        let ta = TapeDraw.at(tf, on ? PK.ink : PK.muted), tw = TapeDraw.width(ts, ta)
        (ts as NSString).draw(at: NSPoint(x: Self.timeR - tw, y: TapeDraw.lineTop(tf, mid: mid)), withAttributes: ta)
        let range = TapeDraw.time(f.from) + "–" + TapeDraw.time(f.to)
        tip(line, NSRect(x: Self.timeR - 64, y: y, width: 64, height: h), "Started \(TapeView.exact(f.from)) · a session: \(range), gaps under 10 minutes")
        chevron(l.open, x: Self.glyphX + 1, mid: mid, color: PK.muted)
        tip(line, NSRect(x: Self.glyphX - 4, y: y, width: 22, height: h), (l.open ? "Fold" : "Unfold") + " this session (← →)")
        if l.open, !soft { PK.rule.setFill(); NSRect(x: Self.guideX, y: mid + 8, width: 1, height: y + h - mid - 8).fill() }
        var x = Self.textX
        if soft, AppIcons.icon(f.app) != nil {
            AppIcons.icon(f.app)?.draw(in: NSRect(x: x, y: mid - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil); x += 22
        } else if let g = TapeDraw.appMark(f.app) {
            TapeDraw.glyph(g, NSRect(x: x, y: mid - 7, width: 14, height: 14), color: on ? PK.ink : PK.muted); x += 20
        }
        let nf = PK.text(mt.text, .medium), na = TapeDraw.at(nf, PK.ink)
        let name = f.app.isEmpty ? "Session" : f.app
        let nw = min(TapeDraw.width(name, na), max(0, (tagW > 0 && f.tag != nil ? tagX : durX) - x - 12))
        TapeDraw.line(name, NSRect(x: x, y: TapeDraw.lineTop(nf, mid: mid), width: nw, height: mt.lh), na)
        tip(line, NSRect(x: x, y: y, width: nw, height: h), "A session in \(name): \(range), with gaps under 10 minutes")
        // right: the items in the app column, the length in the duration column, the tag in the related column
        let W = bounds.width
        let count = l.sub.isEmpty ? "\(f.items) items" : l.sub, cf = PK.text(12), ca = TapeDraw.at(cf, on ? PK.muted : PK.faint)
        if appW > 30 {
            TapeDraw.line(count, NSRect(x: W - appW + 20, y: TapeDraw.lineTop(cf, mid: mid), width: appW - 24, height: 16), ca)
            tip(line, NSRect(x: W - appW, y: y, width: appW, height: h), count + " in this session")
        }
        if f.took >= 1 {
            let s = TapeRules.clock(f.took), a = TapeDraw.at(PK.mono(11.5), on ? PK.ink : PK.muted), w = TapeDraw.width(s, a)
            (s as NSString).draw(at: NSPoint(x: W - appW - 10 - w, y: TapeDraw.lineTop(PK.mono(11.5), mid: mid)), withAttributes: a)
            tip(line, NSRect(x: W - appW - 10 - w, y: y, width: w, height: h), "Length \(s): from its first item to its last")
        }
        if let c = f.tag { drawTag(c, mid: mid, line: line, y: y, on: on) }
    }

    /// The related column: the kind's glyph and the name in quiet text, no border, at the same place on every row.
    private func drawTag(_ c: TapeTag, mid: CGFloat, line: Int, y: CGFloat, on: Bool) {
        guard tagW > 0 else { return }
        let f = PK.text(12), a = TapeDraw.at(f, on ? PK.muted : PK.faint)
        TapeDraw.glyph(c.glyph, NSRect(x: tagX, y: mid - 6, width: 12, height: 12), color: on ? PK.muted : PK.faint)
        TapeDraw.line(c.name, NSRect(x: tagX + 17, y: TapeDraw.lineTop(f, mid: mid), width: tagW - 17, height: 16), a)
        tip(line, NSRect(x: tagX, y: y, width: tagW, height: mt.rowH), "Related to \(c.name), a \(c.kindWord) · the sidebar lists everything related to it")
    }

    /// The kind in words, for the tooltip of its glyph.
    static func kindTip(_ it: TapeItem) -> String {
        if it.pinned { return "Pinned \(it.noun.lowercased()) (⌘P Pin)" }
        return it.noun + ": " + TapeRules.kindTip(it.doc != nil ? "call" : it.entry?.clip == .image ? "picture" : it.entry?.clip == .link ? "link" : it.entry?.clip == .file ? "file" : it.kind.word)
    }
    static func tookTip(_ it: TapeItem) -> String {
        guard let t = it.took else { return "" }
        let c = TapeRules.clock(t)
        switch it.kind {
        case .said: return "Length \(c): the voice note's audio"
        case .call: return "Length \(c): the recording"
        default: return "Length \(c): from the first key to the last kept text"
        }
    }

    /// The shared right side of a row: the app by name, how long it took, the chip, the repeats, the change mark.
    /// Returns where the text must end.
    private func drawRight(_ it: TapeItem, line: Int, y: CGFloat, on: Bool, group: String? = nil) -> CGFloat {
        let W = bounds.width, mid = y + mt.rowH / 2
        let ax = W - appW
        if !it.app.isEmpty {
            if soft, let icon = AppIcons.icon(it.app) { icon.draw(in: NSRect(x: ax + 1, y: mid - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            else if let g = TapeDraw.appMark(it.app) { TapeDraw.glyph(g, NSRect(x: ax + 2, y: mid - 6, width: 12, height: 12), color: PK.faint) }
            if appW > 30 {
                let a = TapeDraw.at(PK.text(12), on ? PK.muted : PK.faint)
                TapeDraw.line(it.app, NSRect(x: ax + 20, y: TapeDraw.lineTop(PK.text(12), mid: mid), width: appW - 24, height: 16), a)
            }
            tip(line, NSRect(x: ax, y: y, width: appW, height: mt.rowH), "From \(it.app)")
        }
        if let t = it.took, durWs > 0 {
            let s = TapeRules.clock(t), a = TapeDraw.at(soft ? PK.num(11.5) : PK.mono(11.5), on ? PK.ink : PK.muted)
            let w = TapeDraw.width(s, a)
            (s as NSString).draw(at: NSPoint(x: ax - 10 - w, y: TapeDraw.lineTop(PK.mono(11.5), mid: mid)), withAttributes: a)
            tip(line, NSRect(x: ax - 10 - w, y: y, width: w, height: mt.rowH), Self.tookTip(it))
        }
        var right = durX - 8
        if soft, it.kind == .copied, !it.to.isEmpty {   // where the clip went: → and the apps' icons
            for a in it.to.prefix(3).reversed() {
                if let icon = AppIcons.icon(a) { icon.draw(in: NSRect(x: right - 16, y: mid - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
                else { TapeDraw.glyph("layers", NSRect(x: right - 14, y: mid - 6, width: 12, height: 12), color: PK.faint) }
                right -= 20
            }
            let ar = TapeDraw.at(PK.text(12), PK.faint); TapeDraw.line("→", NSRect(x: right - 12, y: TapeDraw.lineTop(PK.text(12), mid: mid), width: 12, height: 16), ar)
            tip(line, NSRect(x: right - 12, y: y, width: durX - 8 - right + 12, height: mt.rowH), "Pasted into " + it.to.joined(separator: ", "))
            right -= 20
        }
        if soft, (it.entry?.sent == true || (it.fate ?? "").hasPrefix("sent")) {
            TapeDraw.glyph("check", NSRect(x: right - 12, y: mid - 6, width: 12, height: 12), color: PK.muted)
            tip(line, NSRect(x: right - 14, y: y, width: 16, height: mt.rowH), it.fate ?? "Sent"); right -= 20
        }
        // the related column: a row with a tag stops its text before it; a row with none may use the room
        // under a Related to group the group's own name says nothing new: the item's other tag, if any
        let chip = group.map { g in it.tags.first { $0.kind != "app" && $0.name.lowercased() != g.lowercased() } } ?? it.chip
        if tagW > 0, let c = chip { right = tagX - 10; drawTag(c, mid: mid, line: line, y: y, on: on) }
        func word(_ s: String, _ tipText: String, mono: Bool = false) {
            let f = mono ? PK.mono(11) : PK.text(11.5), a = TapeDraw.at(f, PK.muted), w = TapeDraw.width(s, a)
            (s as NSString).draw(at: NSPoint(x: right - w, y: TapeDraw.lineTop(f, mid: mid)), withAttributes: a)
            tip(line, NSRect(x: right - w, y: y, width: w, height: mt.rowH), tipText)
            right -= w + 10
        }
        if it.repeats > 1 { word("×\(it.repeats)", "The same text \(it.repeats) times within 5 minutes, shown once (the history keeps every row)", mono: true) }
        if it.change != nil { word("Changed", "Changed: you changed this text; the original is kept (⌥⌘O Show original, ⌥⌘R Revert)") }
        if it.pinned { word("Pinned", "Pinned: also on top of the Quick panel (⌘P Pin)") }
        return right
    }

    /// One line of text with the search's matches marked (a darker ground and the medium weight).
    private func marked(_ s: String, ranges: [NSRange], base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: base)
        let len = (s as NSString).length
        for r in ranges where r.location + r.length <= len {
            a.addAttribute(.backgroundColor, value: PK.rule, range: r)
            a.addAttribute(.font, value: PK.text(mt.text, .semibold), range: r)
        }
        return a
    }

    private func drawRow(_ it: TapeItem, _ l: JLine, line: Int, y: CGFloat, h: CGFloat) {
        let on = it.id == snap.chosen, isOpen = it.id == snap.open && !snap.reader, gone = snap.gone.contains(it.id)
        lift(it.id, y: y, h: h)
        let step = l.inSession ? Self.step : 0, gx = Self.glyphX + step
        let mid = y + mt.rowH / 2
        // the time: by its chunk (the clock today, weekday and clock this week, the date before)
        let tf = PK.mono(11.5)
        let ts = TimeChunks.rowTime(it.at, chunk: it.chunk.isEmpty ? l.chunk : it.chunk, cal: TapeBuild.cal)
        let ta = TapeDraw.at(soft ? PK.num(11.5) : tf, on ? PK.ink : l.inSession ? PK.faint : PK.muted)
        let tw = TapeDraw.width(ts, ta)
        (ts as NSString).draw(at: NSPoint(x: Self.timeR - tw, y: TapeDraw.lineTop(tf, mid: mid)), withAttributes: ta)
        tip(line, NSRect(x: Self.timeR - 64, y: y, width: 64, height: mt.rowH), TapeView.exact(it.at) + " · " + TimeChunks.relative(it.at, now: model?.now ?? Date().timeIntervalSince1970, cal: TapeBuild.cal))
        if l.inSession, !soft { PK.rule.setFill(); NSRect(x: Self.guideX, y: y, width: 1, height: h).fill() }
        // the kind (soft: its colour mark, JournalMeta.kinds)
        if soft { TapeDraw.glyph(JournalMeta.glyph(it.kindId), NSRect(x: gx, y: mid - 7, width: 14, height: 14), color: PK.series(JournalMeta.series(it.kindId))) }
        else { TapeDraw.glyph(it.glyph, NSRect(x: gx, y: mid - 7, width: 14, height: 14), color: on ? PK.ink : PK.muted) }
        tip(line, NSRect(x: gx - 2, y: y, width: 18, height: mt.rowH), Self.kindTip(it))
        if gone {   // deleted a moment ago: struck through, with the way back next to it
            let s = it.shown.isEmpty ? it.line : it.shown
            let undo = "⌘Z Undo", ua = TapeDraw.at(PK.text(12.5, .medium), PK.ink), uw = TapeDraw.width(undo, ua)
            let ux = durX - 8 - uw
            (undo as NSString).draw(at: NSPoint(x: ux, y: TapeDraw.lineTop(PK.text(12.5), mid: mid)), withAttributes: ua)
            hitRects.append((NSRect(x: ux - 4, y: y, width: uw + 8, height: mt.rowH), { [weak self] in self?.model?.undoLast() }))
            tip(line, NSRect(x: ux - 4, y: y, width: uw + 8, height: mt.rowH), "Undo: bring it back (⌘Z), 8 seconds")
            TapeDraw.line(s, NSRect(x: Self.textX + step, y: TapeDraw.lineTop(font, mid: mid), width: max(0, ux - Self.textX - step - 12), height: mt.lh),
                          TapeDraw.at(font, PK.faint, strike: PK.faint))
            return
        }
        let group = l.parent.flatMap { $0.hasPrefix("g|") ? String($0.dropFirst(2)) : nil }
        var right = drawRight(it, line: line, y: y, on: on, group: group)
        if soft, hoverLine == it.id, !isOpen { right = min(right, hoverActions(it, line: line, mid: mid)) }
        if let d = it.doc { drawCall(it, d, line: line, y: y, h: h, on: on, right: right, x: Self.textX + step); return }
        let x = Self.textX + step, w = max(0, right - x)
        guard isOpen, let e = it.entry else {
            let empty = it.entry.map { $0.text.isEmpty } ?? false
            if let e = it.entry, e.clip != .text, it.change == nil {   // a link, file or picture: the same line as in the Quick panel
                var tx = x, tw = w
                if let img = picture(e) {
                    let r = TapeDraw.picture(img, in: NSRect(x: x, y: y + 4, width: 40, height: mt.rowH - 8)); tx = r.maxX + 10; tw = w - (tx - x)
                }
                TapeDraw.clipLine(e.clip, text: e.text, title: e.clipTitle, bytes: e.bytes, ocr: e.ocr,
                                  NSRect(x: tx, y: TapeDraw.lineTop(font, mid: mid), width: max(0, tw), height: mt.lh), font: font)
            } else {
                let s = it.change.map(TapeItem.flat) ?? (it.shown.isEmpty ? it.line : it.shown)
                let base = TapeDraw.at(font, empty ? PK.muted : PK.ink, cut: s.contains(" ") ? .byTruncatingTail : .byTruncatingMiddle)
                let ranges = snap.query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : JournalSearch.ranges(snap.query, in: s)
                if ranges.isEmpty { TapeDraw.line(s, NSRect(x: x, y: TapeDraw.lineTop(font, mid: mid), width: w, height: mt.lh), base) }
                else {
                    marked(s, ranges: ranges, base: base).draw(with: NSRect(x: x, y: TapeDraw.lineTop(font, mid: mid), width: w, height: mt.lh),
                                                               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
            return
        }
        // open in place (the reader is closed): the whole text, the facts line, the drafts, the actions
        let bw = durX - x - 12
        let body = it.current.isEmpty ? e.summary : it.current
        let n = TapeDraw.lines(body, width: bw, font: font, lh: mt.lh, max: 40)
        var cy = y + (mt.rowH - mt.lh) / 2
        if let img = picture(e) { TapeDraw.picture(img, in: NSRect(x: x, y: cy + 2, width: bw, height: Self.pictureH)); cy += Self.pictureH + 8 }
        TapeDraw.block(body, x: x, y: cy, width: bw, font: font, color: it.current.isEmpty ? PK.muted : PK.ink, lh: mt.lh, max: 40)
        cy += CGFloat(n) * mt.lh + 6
        let read = ocrText(e)
        if !read.isEmpty {
            let k = TapeDraw.lines(read, width: bw, font: PK.text(13), lh: 18, max: 6)
            TapeDraw.block(read, x: x, y: cy, width: bw, font: PK.text(13), color: PK.muted, lh: 18, max: 6)
            cy += CGFloat(k) * 18 + 6
        }
        TapeDraw.line(JournalWords.facts(it), NSRect(x: x, y: cy, width: bw, height: 16), TapeDraw.at(PK.mono(11.5), PK.muted))
        cy += 16 + 10
        if !e.drafts.isEmpty {
            TapeDraw.line(e.drafts.count == 1 ? "1 earlier version" : "\(e.drafts.count) earlier versions", NSRect(x: x, y: cy, width: bw, height: 18), TapeDraw.at(PK.text(12.5), PK.muted))
            cy += 20
            for d in e.drafts.suffix(3).reversed() {
                TapeDraw.line(TapeItem.flat(d), NSRect(x: x + 12, y: cy, width: bw - 12, height: 18), TapeDraw.at(PK.text(13), PK.muted))
                PK.rule.setFill(); NSRect(x: x + 2, y: cy + 2, width: 1, height: 14).fill()
                cy += 20
            }
            cy += 4
        }
        drawButtons(it, x: x, y: cy, line: line)
    }

    private static let exactF: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM yyyy, HH:mm:ss"; return f }()
    static func exact(_ t: Double) -> String { exactF.string(from: Date(timeIntervalSince1970: t)) }

    /// The chosen item's actions in place: keycap and name each; the one in focus has the ring.
    private func drawButtons(_ it: TapeItem, x: CGFloat, y: CGFloat, line: Int) {
        guard let m = model else { return }
        var ax = x
        for (i, a) in m.actions(it, inPlace: true).enumerated() {
            let x1 = TapeDraw.keyWord(a.key, a.word, x: ax, y: y)
            let r = NSRect(x: ax, y: y, width: x1 - ax - 16, height: TapeDraw.capH)
            hitRects.append((r, a.run))
            tip(line, r, "\(a.word): \(a.tip) (\(a.key))")
            if snap.region == .button(i) { focusRing(r.insetBy(dx: -4, dy: -3)) }
            ax = x1
            if ax > bounds.width - 120 { break }
        }
    }

    /// The focus ring: the accent, never the selection's colour.
    private func focusRing(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r, xRadius: PK.corner(2), yRadius: PK.corner(2))
        p.lineWidth = 1; PK.blue.setStroke(); p.stroke()
    }

    private func face(_ name: String) -> NSImage? {
        if let i = faces[name] { return i }
        guard let u = PK.art?.appendingPathComponent("people/\(name).png"), let i = NSImage(contentsOf: u) else { return nil }
        faces[name] = i; return i
    }

    /// A recording: the title on the row line; under it each side with its face, name, a bar of how long it spoke
    /// and the time; its outline and actions when it is chosen and no reader is open.
    private func drawCall(_ it: TapeItem, _ d: CallDoc, line: Int, y: CGFloat, h: CGFloat, on: Bool, right: CGFloat, x: CGFloat) {
        let mid = y + mt.rowH / 2
        let tf = PK.text(mt.text, .medium)
        let title = it.shown.isEmpty ? (d.call ? "Recording" : "Voice note") : it.shown
        TapeDraw.line(title, NSRect(x: x, y: TapeDraw.lineTop(tf, mid: mid), width: max(0, right - x), height: mt.lh), TapeDraw.at(tf, PK.ink))
        if d.live {
            let a = TapeDraw.at(PK.mono(11.5), PK.coral), s = "recording now", w = TapeDraw.width(s, a)
            (s as NSString).draw(at: NSPoint(x: durX - 8 - w, y: TapeDraw.lineTop(PK.mono(11.5), mid: mid)), withAttributes: a)
        }
        var cy = y + mt.rowH
        let total = max(1, d.secs), sh = mt.sideH
        for s in TapeBuild.sides(d) {
            let m2 = cy + sh / 2
            if let img = face(s.face) {
                NSGraphicsContext.current?.imageInterpolation = .none
                img.draw(in: NSRect(x: x, y: m2 - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
            let nf = PK.text(12)
            TapeDraw.line(s.name, NSRect(x: x + 20, y: TapeDraw.lineTop(nf, mid: m2), width: 60, height: 16), TapeDraw.at(nf, PK.muted))
            let cells = 18, lit = s.secs > 0 ? max(1, Int((s.secs / total * Double(cells)).rounded())) : 0
            let bx = x + 84
            for c in 0..<cells { (c < lit ? (s.me ? PK.blue : PK.coral) : on ? PK.rule : PK.soft).setFill(); NSRect(x: bx + CGFloat(c) * 5, y: m2 - 3, width: 3, height: 6).fill() }
            let st = TapeRules.clock(s.secs), sa = TapeDraw.at(PK.mono(11), PK.muted)
            (st as NSString).draw(at: NSPoint(x: bx + CGFloat(cells) * 5 + 8, y: TapeDraw.lineTop(PK.mono(11), mid: m2)), withAttributes: sa)
            tip(line, NSRect(x: x, y: cy, width: 240, height: sh), "Talk time: \(s.me ? "you" : s.name) spoke about \(st) of \(TapeRules.clock(d.secs))")
            cy += sh
        }
        guard on, !snap.reader else { return }
        let of = PK.text(13)
        for p in outline(d) {
            PK.muted.setFill(); NSRect(x: x, y: cy + sh / 2 - 2, width: 4, height: 4).fill()
            TapeDraw.line(p, NSRect(x: x + 12, y: TapeDraw.lineTop(of, mid: cy + sh / 2), width: max(0, durX - x - 24), height: 18), TapeDraw.at(of, d.live ? PK.muted : PK.ink))
            cy += sh
        }
        drawButtons(it, x: x, y: y + h - TapeDraw.capH - 8, line: line)
    }

    // MARK: the mouse: a click chooses a line (on a header: folds or unfolds it); a key word runs; right-click: a menu

    /// Hover (soft): Insert, Copy, Pin as round buttons over the right end of the row. Returns where the text stops.
    private func hoverActions(_ it: TapeItem, line: Int, mid: CGFloat) -> CGFloat {
        guard let m = model else { return bounds.width }
        let acts: [(String, String, () -> Void)] = [
            ("send", "Insert into the app you came from (⌘↵)", { [weak m] in m?.choose(it.id); m?.insert() }),
            ("copy", "Copy (⌘C)", { [weak m] in m?.choose(it.id); m?.copyItem() }),
            ("pin", it.pinned ? "Unpin (⌘P)" : "Pin (⌘P)", { [weak m] in m?.togglePin(it) })]
        let w = CGFloat(acts.count) * 28 + 8
        var x = durX - 8 - w
        (it.id == snap.chosen ? PK.pick : PK.hover).setFill(); NSRect(x: x - 4, y: mid - 13, width: w + 4, height: 26).fill()
        for a in acts {
            let b = NSRect(x: x, y: mid - 12, width: 24, height: 24)
            let p = NSBezierPath(ovalIn: b); PK.card.setFill(); p.fill(); PK.line.setStroke(); p.lineWidth = 0.5; p.stroke()
            TapeDraw.glyph(a.0, b.insetBy(dx: 5.5, dy: 5.5), color: PK.muted)
            hitRects.append((b, a.2)); tip(line, b, a.1)
            x += 28
        }
        return durX - 8 - w - 8
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) {
        guard soft else { return }
        let p = convert(e.locationInWindow, from: nil)
        let id = lineAt(p).flatMap { lines[$0].kind == .row ? lines[$0].id : nil }
        if id != hoverLine { hoverLine = id; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { if hoverLine != nil { hoverLine = nil; needsDisplay = true } }

    /// Drag a row out: its text (a picture or a file as the file); onto Pinned in the sidebar pins it.
    override func mouseDragged(with e: NSEvent) {
        guard let d = down, let m = model, let it = m.item(d.id) else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - d.point.x, p.y - d.point.y) > 5 else { return }
        down = nil
        let ids = m.picked.contains(d.id) && m.picked.count > 1 ? m.picked : [d.id]
        m.dragIds = ids
        let pb = NSPasteboardItem()
        if let en = it.entry, it.kind == .copied, en.clip == .image, !en.picture.isEmpty { pb.setString(History.clipURL(en.picture).absoluteString, forType: .fileURL) }
        else if let en = it.entry, it.kind == .copied, en.clip == .file { pb.setString(en.text.hasPrefix("file://") ? en.text : URL(fileURLWithPath: en.text).absoluteString, forType: .fileURL) }
        pb.setString(ids.compactMap { m.item($0)?.current }.joined(separator: "\n\n"), forType: .string)
        let di = NSDraggingItem(pasteboardWriter: pb)
        let r = NSRect(x: Self.textX, y: p.y - 14, width: min(360, bounds.width - Self.textX), height: 28)
        let img = NSImage(size: r.size, flipped: true) { b in
            let path = NSBezierPath(roundedRect: b, xRadius: PK.radius("row"), yRadius: PK.radius("row"))
            PK.card.withAlphaComponent(0.92).setFill(); path.fill(); PK.line.setStroke(); path.stroke()
            TapeDraw.line(ids.count > 1 ? "\(ids.count) items" : TapeItem.flat(it.current), b.insetBy(dx: 10, dy: 6), TapeDraw.at(PK.text(12), PK.ink))
            return true
        }
        di.setDraggingFrame(r, contents: img)
        beginDraggingSession(with: [di], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) { DispatchQueue.main.async { self.model?.dragIds = [] } }
    override func mouseUp(with e: NSEvent) { down = nil }

    func previewHover(_ id: String?) { hoverLine = id; needsDisplay = true }

    private func lineAt(_ p: NSPoint) -> Int? {
        guard let i = firstLine(atOrBelow: p.y), placed[i].y <= p.y else { return nil }
        return i
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let h = hitRects.first(where: { $0.0.contains(p) }) { h.1(); return }
        guard let i = lineAt(p), let m = model else { return }
        let l = lines[i]
        guard l.selectable else { return }
        m.nav.region = .list
        if e.modifierFlags.contains(.shift), l.kind == .row { m.pickTo(l.id); return }
        if l.foldable { m.choose(l.id); m.toggleFold(l.id); return }
        if l.kind == .row { down = (p, l.id) }
        if e.clickCount >= 2 || (m.chosen == l.id && !soft) { m.chosen = l.id; m.enter() } else { m.choose(l.id) }
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = lineAt(p), lines[i].kind == .row, lines[i].item < items.count, let m = model else { return nil }
        let it = items[lines[i].item]
        m.choose(it.id); m.nav.region = .list
        let menu = NSMenu()
        for a in m.actions(it, inPlace: false) {
            let (k, mods) = MenuRun.parse(a.key)
            let item = NSMenuItem(title: a.word, action: #selector(MenuRun.go(_:)), keyEquivalent: k)
            item.keyEquivalentModifierMask = mods; item.toolTip = a.tip
            MenuRun.attach(item, a.run)
            menu.addItem(item)
        }
        if let c = it.chip {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Show everything related to \(c.name)", action: #selector(MenuRun.go(_:)), keyEquivalent: "")
            MenuRun.attach(item) { m.setFilter(.tag(c)) }
            menu.addItem(item)
        }
        if !it.app.isEmpty {
            let item = NSMenuItem(title: "Show everything from \(it.app)", action: #selector(MenuRun.go(_:)), keyEquivalent: "")
            MenuRun.attach(item) { m.setFilter(.app(it.app)) }
            menu.addItem(item)
        }
        return menu
    }
}

/// A menu item that runs a closure; parses "⇧⌘C" into a key and its modifiers for the menu's key hint.
final class MenuRun: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func go(_ s: NSMenuItem) { run() }
    static func attach(_ item: NSMenuItem, _ run: @escaping () -> Void) { let r = MenuRun(run); item.target = r; item.representedObject = r }
    static func parse(_ key: String) -> (String, NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = [], rest = ""
        for c in key {
            switch c {
            case "⌘": mods.insert(.command); case "⇧": mods.insert(.shift); case "⌥": mods.insert(.option); case "⌃": mods.insert(.control)
            default: rest.append(c)
            }
        }
        switch rest {
        case "↵": return ("\r", mods)
        case "⌫": return (String(UnicodeScalar(8)), mods)
        default: return (rest.lowercased(), mods)
        }
    }
}

/// The list in SwiftUI: an NSScrollView around the drawn view.
struct TapeList: NSViewRepresentable {
    @ObservedObject var m: WindowModel
    func makeNSView(context: Context) -> NSScrollView {
        let s = FitScroll()
        s.hasVerticalScroller = true; s.autohidesScrollers = true; s.drawsBackground = false; s.borderType = .noBorder
        s.scrollerStyle = .overlay
        let v = TapeView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v.model = m; v.autoresizingMask = [.width]
        s.documentView = v
        m.listView = v
        s.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: s.contentView, queue: .main) { [weak v] _ in v?.reportChunk() }
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        guard let v = s.documentView as? TapeView else { return }
        m.listView = v
        if v.frame.width != s.contentView.bounds.width, s.contentView.bounds.width > 0 { v.setFrameSize(NSSize(width: s.contentView.bounds.width, height: v.frame.height)) }
        let snap = m.snap
        if snap != v.snap {
            v.mt = TapeMetrics.of(snap.density)
            v.apply(snap, items: m.rows, facts: m.journal.facts)
        }
    }
}

/// The chunk at the top of the list, held there while its lines scroll under it.
struct StickyHead: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        if !m.dayTitle.isEmpty {
            let h = TapeMetrics.of(m.settings.tapeDensity).sectionH
            HStack(spacing: 12) {
                Glyph("chevron-down", size: 12).foregroundStyle(UIInk.faint)
                Text(m.dayTitle).font(m.softLook ? PKFont.text(17, .medium) : PKFont.text(13, .semibold)).lineLimit(1)
                Text(m.daySub).font(m.softLook ? PKFont.num(11.5) : PKFont.mono(11)).foregroundStyle(UIInk.faint).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8).frame(height: h)
            .background(UIInk.paper)
            .overlay(alignment: .bottom) { if !m.softLook { Rectangle().fill(UIInk.line).frame(height: 1) } }
            .contentShape(Rectangle())
            .onTapGesture { m.choose(m.chunkInView); m.toggleFold(m.chunkInView) }
            .help("\(m.dayTitle): fold it (click, or ← on its line) · ⌘↑ ⌘↓ the chunk before or after")
            .accessibilityElement(children: .combine)
        }
    }
}

/// The journal's words in one place, so the list, the reader, the tooltips and Help say the same thing.
enum JournalWords {
    /// The facts line of an item: "Voice note · 13:19:04 · 0:42 · Claude · 128 characters".
    static func facts(_ it: TapeItem) -> String {
        var out = [it.noun, TapeView.exact(it.at)]
        if let t = it.took { out.append(TapeRules.clock(t)) }
        if !it.app.isEmpty { out.append(it.app) }
        out.append("\(it.current.count) characters")
        if it.repeats > 1 { out.append("×\(it.repeats) within 5 min") }
        if it.change != nil { out.append("Changed") }
        if let e = it.entry, e.incomplete { out.append(e.outcome == "timeout" ? "transcript incomplete" : "no final text") }
        return out.joined(separator: " · ")
    }
}
