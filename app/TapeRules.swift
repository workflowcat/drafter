// The window's tape, the second window round (14 November 2026, Andrii: "kinda hard to navigate", "we're wasting a lot
// of space", "name stuff", "say how long something took", "classify all the copies by what they're related to").
// Pure rules, display only: nothing here changes or deletes a stored row. Tested in tests/tape_rules.swift with
// made-up rows; compiles with ClipRules.swift and EntityRules.swift only.
//
// - what a row says: a chat export's "[date, time] Name:" head becomes a tag, a copied web page loses its navigation
// - what it is related to: at most 2 tags (a person, project or tool the entity matcher finds; a link's site or a
//   file's folder; the app it came from)
// - repeats: the same text (or a strict prefix of the next one) in a row within a few minutes folds into one, "×3"
// - how long it took: a take's audio, a call's length, a typed message from its first to last stamp
// - the sidebar: named entries with counts; filters; sections by time, by what it is related to, or by app
import Foundation

/// What a row is related to. kind: person, project, tool, site, folder, chat (a name from a chat export), app.
struct TapeTag: Hashable {
    let name: String
    let kind: String
    /// The word a tooltip uses for the kind.
    var kindWord: String {
        switch kind {
        case "person", "chat": return "person"
        case "site": return "website"
        default: return kind
        }
    }
    /// The PixelKit line glyph for the kind.
    var glyph: String {
        switch kind {
        case "person", "chat": return "user"
        case "project", "folder": return "folder"
        case "tool": return "terminal"
        case "site": return "globe"
        default: return "list"
        }
    }
}

/// The facts the filters and the sections need about one row.
struct TapeFacet: Equatable {
    var kind: String          // copied, typed, spoken, call
    var clip: String = "text" // for a copy: text, link, file, image
    var app: String = ""
    var at: Double = 0
    var tags: [TapeTag] = []
    var pinned = false
}

enum TapeRules {
    // MARK: what a row says

    /// "[14.11.26, 12:41] Mila Synthetic: text" (Telegram, WhatsApp and Beeper exports, with or without seconds, the
    /// date in any order): the name and the text after it. nil when the text does not start that way.
    static func chatHeader(_ s0: String) -> (name: String, rest: String)? {
        let s = s0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.first == "[", let close = s.firstIndex(of: "]") else { return nil }
        let stamp = s[s.index(after: s.startIndex)..<close]
        guard stamp.count >= 5, stamp.count <= 32, stamp.contains(where: \.isNumber),
              stamp.allSatisfy({ $0.isNumber || " .,:/-APMapm".contains($0) }) else { return nil }
        let after = s[s.index(after: close)...].drop { $0 == " " }
        guard let colon = after.firstIndex(of: ":") else { return nil }
        let name = after[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, name.split(separator: " ").count <= 4, name.first?.isLetter == true,
              !name.contains("\n") else { return nil }
        let rest = after[after.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        // a second header later is the next message: the row shows the first message's text
        return (name, rest)
    }

    /// Words a site's navigation is made of (English and Ukrainian), folded to lower case.
    static let navWords: Set<String> = [
        "skip", "to", "content", "main", "menu", "navigation", "home", "about", "us", "products", "product", "services",
        "pricing", "blog", "news", "contact", "contacts", "sign", "in", "up", "log", "login", "register", "search",
        "cart", "account", "subscribe", "english", "docs", "help", "support", "careers", "jobs", "shop", "more",
        "features", "solutions", "resources", "company", "toggle", "close", "open", "back", "next", "previous", "share",
        "головна", "про", "нас", "новини", "контакти", "увійти", "вхід", "пошук", "меню", "перейти", "до", "вмісту",
        "послуги", "продукти", "блог", "ціни", "кошик", "підписатися", "українська", "реєстрація", "допомога", "ще"]

    private static func words(_ s: Substring) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
    private static func isNavLine(_ l: Substring) -> Bool {
        let w = words(l)
        guard !w.isEmpty, w.count <= 3 else { return false }
        if w.allSatisfy({ navWords.contains($0) }) { return true }
        // a short menu item: few letters, no sentence mark
        return l.count <= 24 && !l.contains(where: { ".!?,;".contains($0) })
    }
    private static func sentence(_ s: Substring) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for end in [". ", "! ", "? "] {
            if let r = t.range(of: end), t.distance(from: t.startIndex, to: r.lowerBound) >= 20 { t = String(t[..<r.lowerBound]) + String(end.first!); break }
        }
        return t
    }

    /// A copied web page that starts with its site's navigation: the first sentence-like span after it. nil when the
    /// text does not start with navigation (then the row shows the text as it is).
    static func pageLead(_ text: String) -> String? {
        let lines = text.prefix(6000).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count >= 4 {
            var k = 0
            while k < lines.count, isNavLine(Substring(lines[k])) { k += 1 }
            let navHits = lines.prefix(k).filter { words(Substring($0)).contains { navWords.contains($0) } }.count
            if k >= 3, navHits >= 2, k < lines.count,
               let body = lines[k...].first(where: { words(Substring($0)).count >= 5 }) {
                return sentence(Substring(body))
            }
            return nil
        }
        // flattened to one line: four or more navigation words in front
        let parts = text.prefix(2000).split(separator: " ", omittingEmptySubsequences: true)
        var k = 0
        while k < parts.count, let w = words(parts[k]).first, words(parts[k]).count == 1, navWords.contains(w) { k += 1 }
        guard k >= 4, parts.count - k >= 5 else { return nil }
        return sentence(Substring(parts[k...].joined(separator: " ")))
    }

    /// What a row shows on its one line and the chat name it found (a tag). `title`: a page or link title the
    /// pasteboard gave, which wins over the guess.
    static func display(_ text: String, kind: String, clip: String, title: String = "") -> (line: String, chat: String?) {
        // one line (most rows): trimmed; else the lines joined
        let flat = text.contains(where: \.isNewline)
            ? text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            : text.trimmingCharacters(in: .whitespaces)
        guard clip == "text" else { return (flat, nil) }
        if text.first(where: { !$0.isWhitespace }) == "[", let h = chatHeader(text) {
            let rest = h.rest.split(whereSeparator: \.isNewline).first.map(String.init) ?? h.rest
            return (rest.isEmpty ? flat : rest, h.name)
        }
        if kind == "copied", pageLead(text) != nil {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty ? pageLead(text)! : t, nil)
        }
        return (flat, nil)
    }

    // MARK: what a row is related to

    static let entityKinds: Set<String> = ["person", "project", "tool"]

    /// At most `max` tags, most telling first: the chat name; people, projects and tools (`found`: names and kinds the
    /// entity matcher resolved in the text, first seen first); a link's site or a file's folder; the app.
    static func tags(text: String, clip: String, app: String, chat: String? = nil, found: [(name: String, kind: String)], max: Int = 2) -> [TapeTag] {
        var out: [TapeTag] = []
        func add(_ t: TapeTag) {
            guard out.count < max, !t.name.isEmpty, !out.contains(where: { $0.name.lowercased() == t.name.lowercased() }) else { return }
            out.append(t)
        }
        if let chat {   // a chat named after a known person is that person: one sidebar entry, not two
            let who = found.first { $0.kind == "person" && $0.name.lowercased() == chat.lowercased() }
            add(TapeTag(name: who?.name ?? chat, kind: who == nil ? "chat" : "person"))
        }
        for f in found where entityKinds.contains(f.kind) { add(TapeTag(name: f.name, kind: f.kind)) }
        switch clip {
        case "link": add(TapeTag(name: ClipRules.parts(text).host, kind: "site"))
        case "file":
            let folder = ClipRules.fileParts(text).folder
            let last = folder == "~" ? "Home" : folder.split(separator: "/").last.map(String.init) ?? folder
            add(TapeTag(name: last, kind: "folder"))
        default: break
        }
        add(TapeTag(name: app, kind: "app"))
        return out
    }

    // MARK: repeats

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{A0}", with: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Rows newest first (kind, app, time, text): groups of indices, each newest first. A row folds into the group of
    /// the same kind and app before it when it came within `within` seconds of that group's oldest row and says the
    /// same (exactly, after spaces and case) or is a strict start of the group's text. Calls never fold.
    static func collapse(_ rows: [(kind: String, app: String, at: Double, text: String)], within: Double = 300) -> [[Int]] {
        if rows.count == 1 { return [[0]] }
        var groups: [[Int]] = []
        var open: [String: Int] = [:]   // kind|app -> its newest group
        var reps: [String?] = [], first: [Int] = [], oldest: [Double] = []   // the text of a group, worked out when needed
        for (i, r) in rows.enumerated() {
            let key = r.kind + "|" + r.app
            if r.kind != "call", let g = open[key], oldest[g] - r.at <= within, oldest[g] >= r.at {
                let n = norm(r.text)
                if reps[g] == nil { reps[g] = norm(rows[first[g]].text) }
                let rep = reps[g]!
                if !n.isEmpty, rep == n || (rep.hasPrefix(n) && n.count < rep.count) {
                    groups[g].append(i); oldest[g] = r.at
                    continue
                }
                open[key] = groups.count
                groups.append([i]); reps.append(n); first.append(i); oldest.append(r.at)
                continue
            }
            open[key] = groups.count
            groups.append([i]); reps.append(nil); first.append(i); oldest.append(r.at)
        }
        return groups
    }

    // MARK: sessions

    /// Rows newest first (kind, app, time, day key): sessions as groups of indices, newest first, each newest first.
    /// A session is a stretch in one app with gaps under `gap` seconds, inside one day. A recording is a session of
    /// its own. A clip inside the stretch belongs to it, whatever app it came from; a stretch that so far holds only
    /// clips takes the app of the first draft or voice note that joins it.
    static func sessions(_ rows: [(kind: String, app: String, at: Double, day: Int)], gap: Double = 600) -> [[Int]] {
        var out: [[Int]] = []
        var cur: [Int] = [], app: String? = nil, last = -Double.infinity, day = Int.min
        func close() { if !cur.isEmpty { out.append(cur.reversed()) }; cur = []; app = nil }
        for i in rows.indices.reversed() {   // oldest first
            let r = rows[i]
            if r.kind == "call" { close(); out.append([i]); last = -Double.infinity; continue }
            if !cur.isEmpty, r.at - last >= gap || r.day != day { close() }
            if cur.isEmpty { cur = [i]; app = r.kind == "copied" ? nil : r.app }
            else if r.kind == "copied" { cur.append(i) }
            else if app == nil || app == r.app { cur.append(i); app = r.app }
            else { close(); cur = [i]; app = r.app }
            last = r.at; day = r.day
        }
        close()
        return out.reversed()
    }

    /// A session's line: from, to, its app, the related tag most of its rows share, how long it took, its items.
    /// `took`: each row's own length (a voice note's audio: it started that long before it was kept).
    struct SessionFacts: Equatable { let from: Double; let to: Double; let app: String; let tag: TapeTag?; let took: Double; let items: Int; let recordings: Int }
    static func sessionFacts(_ f: [TapeFacet], took: [Double?], rows: [Int]) -> SessionFacts {
        var from = Double.infinity, to = -Double.infinity, n: [TapeTag: Int] = [:], apps: [String: Int] = [:], rec = 0
        for i in rows {
            from = min(from, f[i].at - (took[i] ?? 0)); to = max(to, f[i].at)
            for t in f[i].tags where t.kind != "app" { n[t, default: 0] += 1 }
            if f[i].kind != "copied" || apps.isEmpty { apps[f[i].app, default: 0] += f[i].kind == "copied" ? 0 : 1 }
            if f[i].kind == "call" { rec += 1 }
        }
        let app = apps.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? f[rows.first ?? 0].app
        let tag = n.max { $0.value != $1.value ? $0.value < $1.value : $0.key.name > $1.key.name }?.key
        return SessionFacts(from: from, to: to, app: app, tag: tag, took: max(0, to - from), items: rows.count, recordings: rec)
    }

    // MARK: how long it took

    /// Seconds a row took, or nil (shown as nothing): a spoken take its audio, a call its length (not while it
    /// records), a typed message from its first to its last stamp (1 s to 30 min; longer means he left and came back).
    /// A copy took no time.
    static func took(kind: String, secs: Double, from: Double? = nil, to: Double? = nil, live: Bool = false) -> Double? {
        switch kind {
        case "spoken", "call": return !live && secs >= 1 ? secs : nil
        case "typed":
            guard let a = from, let b = to else { return nil }
            let d = b - a
            return d >= 1 && d <= 1800 ? d : nil
        default: return nil
        }
    }

    /// "0:08", "1:32", "1:02:05".
    static func clock(_ s: Double) -> String {
        let n = Int(s.rounded())
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }

    // MARK: the sidebar

    enum Filter: Hashable {
        case all, pinned, kind(String), tag(TapeTag), app(String)
        case when(String)     // a chunk of time: picking it moves the list there, it filters nothing
        func matches(_ f: TapeFacet) -> Bool {
            switch self {
            case .all, .when: return true
            case .pinned: return f.pinned
            case .kind(let k):
                switch k {
                case "picture": return f.kind == "copied" && f.clip == "image"
                case "link": return f.kind == "copied" && f.clip == "link"
                case "file": return f.kind == "copied" && f.clip == "file"
                default: return f.kind == k
                }
            case .tag(let t): return f.tags.contains { $0.name.lowercased() == t.name.lowercased() }
            case .app(let a): return f.app == a
            }
        }
    }

    struct Entry: Equatable {
        let filter: Filter
        let title: String
        let glyph: String
        let count: Int
        let group: String     // "" for All and Pinned, else Kinds, Related to, Apps
        let tip: String
        var depth = 0         // under Older: one step in
        var unfolds = false   // Older: picking it shows or hides the months and years
        var open = false
    }

    /// The When group: Today, Yesterday, Earlier this week, Last week, Earlier this month as they come, then one
    /// "Older" entry (its count: all of them) that unfolds to the months and years, one step in. `chunks`: the chunks
    /// of time newest first (TimeChunks ids "c:today", "c:m:…", "c:y:…").
    static let recentChunks: Set<String> = ["today", "yesterday", "week", "lastweek", "month"]
    static func when(_ chunks: [(id: String, title: String, count: Int, tip: String)], olderOpen: Bool) -> [Entry] {
        var out: [Entry] = [], older: [Entry] = [], n = 0
        for c in chunks {
            let p = c.id.split(separator: ":"), kind = p.count >= 2 ? String(p[1]) : c.id   // as TimeChunks.chunkKind
            let e = Entry(filter: .when(c.id), title: c.title, glyph: "calendar", count: c.count, group: "When", tip: c.tip)
            if recentChunks.contains(kind) { out.append(e) } else {
                older.append(Entry(filter: e.filter, title: e.title, glyph: e.glyph, count: e.count, group: e.group, tip: e.tip, depth: 1)); n += c.count
            }
        }
        guard !older.isEmpty else { return out }
        out.append(Entry(filter: .when(olderId), title: "Older", glyph: "calendar", count: n, group: "When",
                         tip: (olderOpen ? "Hide" : "Show") + " the months and years before this month", unfolds: true, open: olderOpen))
        if olderOpen { out += older }
        return out
    }
    static let olderId = "older"

    /// The kinds as people read them: nouns (Andrii, 14 November: "why do we have past tense verbs everywhere?").
    /// The stored kind values (copied, typed, spoken, call) do not change.
    static let kindList: [(id: String, title: String, one: String, glyph: String)] = [
        ("copied", "Clips", "Clip", "copy"), ("typed", "Drafts", "Draft", "keys"), ("spoken", "Voice notes", "Voice note", "waves"),
        ("call", "Recordings", "Recording", "phone"), ("picture", "Pictures", "Picture", "image"), ("link", "Links", "Link", "globe"),
        ("file", "Files", "File", "file")]
    static let groups = ["When", "Kinds", "Related to", "Apps"]
    /// A kind's name for one row ("Voice note"); a picture, link or file clip by what it is.
    static func one(_ kind: String, clip: String = "text", call: Bool = true) -> String {
        if kind == "copied", clip != "text" { return clip == "image" ? "Picture" : clip == "link" ? "Link" : "File" }
        if kind == "call", !call { return "Recording" }
        return kindList.first { $0.id == kind }?.one ?? kind
    }

    /// Every sidebar entry with its count over `facets` (the rows the search left): All, Pinned, the kinds, the top
    /// tags (not apps), the top apps. Kinds with no rows stay (a known place); tags and apps only with rows.
    static func sidebar(_ facets: [TapeFacet], top: Int = 8, appGlyph: (String) -> String = { _ in "list" }) -> [Entry] {
        var kindN: [String: Int] = [:], tagN: [TapeTag: Int] = [:], tagLast: [TapeTag: Double] = [:], appN: [String: Int] = [:]
        var pinned = 0
        for f in facets {
            kindN[f.kind, default: 0] += 1
            if f.kind == "copied" { kindN[f.clip == "image" ? "picture" : f.clip, default: 0] += 1 }
            if f.pinned { pinned += 1 }
            for t in f.tags where t.kind != "app" { tagN[t, default: 0] += 1; tagLast[t] = max(tagLast[t] ?? 0, f.at) }
            if !f.app.isEmpty { appN[f.app, default: 0] += 1 }
        }
        var out: [Entry] = [
            Entry(filter: .all, title: "All", glyph: "list", count: facets.count, group: "", tip: "Everything in the journal"),
            Entry(filter: .pinned, title: "Pinned", glyph: "pin", count: pinned, group: "", tip: "Pinned items, also on top of the Quick panel")]
        for k in kindList {
            out.append(Entry(filter: .kind(k.id), title: k.title, glyph: k.glyph, count: kindN[k.id] ?? 0, group: "Kinds", tip: kindTip(k.id)))
        }
        let tags = tagN.sorted { a, b in a.value != b.value ? a.value > b.value : (tagLast[a.key] ?? 0) != (tagLast[b.key] ?? 0) ? (tagLast[a.key] ?? 0) > (tagLast[b.key] ?? 0) : a.key.name < b.key.name }
        for (t, n) in tags.prefix(top) {
            out.append(Entry(filter: .tag(t), title: t.name, glyph: t.glyph, count: n, group: "Related to", tip: "Items related to \(t.name), a \(t.kindWord)"))
        }
        for (a, n) in appN.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(top) {
            out.append(Entry(filter: .app(a), title: a, glyph: appGlyph(a), count: n, group: "Apps", tip: "Items from \(a)"))
        }
        return out
    }
    static func kindTip(_ k: String) -> String {
        switch k {
        case "copied": return "Clips: text, links, files and pictures on the clipboard"
        case "typed": return "Drafts: text you wrote in an app, one item per message"
        case "spoken": return "Voice notes: your dictation takes"
        case "call": return "Recordings: calls and long voice notes"
        case "picture": return "Pictures: picture clips and captures"
        case "link": return "Links: link clips"
        default: return "Files: file clips"
        }
    }
    /// The entries a key reaches, in order: groups he folded away are skipped.
    static func visible(_ entries: [Entry], folded: Set<String>) -> [Entry] { entries.filter { !folded.contains($0.group) } }

    /// The active filter in words, for the status line.
    static func words(_ f: Filter) -> String {
        switch f {
        case .all, .when: return "everything"
        case .pinned: return "pinned"
        case .kind(let k): return (kindList.first { $0.id == k }?.title ?? k).lowercased()
        case .tag(let t): return "related to \(t.name)"
        case .app(let a): return "from \(a)"
        }
    }

    // MARK: sections

    enum Group: String, CaseIterable { case time, related, app
        var title: String { switch self { case .time: return "Time"; case .related: return "Related to"; case .app: return "App" } }
    }
    struct Section: Equatable { let title: String; let rows: [Int] }

    /// The rows (indices into `facets`, newest first) in sections. Time: a section per day (`day` names it). Related to:
    /// by the first tag that is not the app, else the app; App: by app. Those two: the biggest section first, rows
    /// newest first inside.
    static func sections(_ facets: [TapeFacet], rows: [Int], by g: Group, day: (Double) -> (key: Int, title: String)) -> [Section] {
        switch g {
        case .time:
            var out: [Section] = [], cur: [Int] = [], key = Int.min, title = ""
            for i in rows {
                let d = day(facets[i].at)
                if d.key != key, !cur.isEmpty { out.append(Section(title: title, rows: cur)); cur = [] }
                key = d.key; title = d.title; cur.append(i)
            }
            if !cur.isEmpty { out.append(Section(title: title, rows: cur)) }
            return out
        case .related, .app:
            var by: [String: [Int]] = [:], order: [String] = []
            for i in rows {
                let f = facets[i]
                let k: String
                if g == .app { k = f.app.isEmpty ? "No app" : f.app }
                else { k = f.tags.first(where: { $0.kind != "app" })?.name ?? (f.app.isEmpty ? "Nothing found" : f.app) }
                if by[k] == nil { order.append(k) }
                by[k, default: []].append(i)
            }
            return order.enumerated().sorted { a, b in
                let na = by[a.element]!.count, nb = by[b.element]!.count
                return na != nb ? na > nb : a.offset < b.offset
            }.map { Section(title: $0.element, rows: by[$0.element]!) }
        }
    }

    /// A section's counts in words: "4 drafts · 2 clips · 1 voice note · 1 recording".
    static func summary(_ facets: [TapeFacet], rows: [Int]) -> String {
        var n: [String: Int] = [:]
        for i in rows { n[facets[i].kind, default: 0] += 1 }
        return [("typed", "draft", "drafts"), ("copied", "clip", "clips"), ("spoken", "voice note", "voice notes"), ("call", "recording", "recordings")]
            .compactMap { k, one, many in n[k].map { "\($0) \($0 == 1 ? one : many)" } }.joined(separator: " · ")
    }
}
