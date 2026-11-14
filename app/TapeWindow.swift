// The window as one tape (look round "Tape", 14 November 2026; Andrii chose the concept, then asked for "less
// blocky, less pixelated, not as blue"). The three panes (Voice, Calls & notes, Typed, Clipboard) are one column,
// newest first, all kinds together: what he copied, typed and said, and his calls and long notes. Hour dividers are
// hairlines with the hour in mono, a new day is a heading in the display face. The big field on top searches the tape;
// after ⌘K it takes a command (the command line, `plan()`). A row opens in place with its keys; a call or a long note
// is a taller block (title, the two sides with their faces and talk time, the outline) and opens as a page.
//
// Speed: rows are merged and filtered off the main thread (`rebuildTape`), the view lays rows out with arithmetic
// (fixed heights, only the open row is measured) and draws only the rows in view. Nothing jumps when the tape updates:
// the chosen row (or the first row in view) keeps its place on screen (the scroll anchor).
import AppKit
import SwiftUI

/// One row on the tape.
struct TapeItem: Identifiable, Equatable {
    let id: String
    let kind: TapeKind
    let at: Double
    let app: String
    let line: String           // the text on one line (what a closed row shows)
    var entry: Entry?
    var doc: CallDoc?
    var quick: QuickKind? { switch kind { case .copied: return .copied; case .typed: return .typed; case .said: return .voice; case .call: return nil } }
    /// What a copy takes: the final text (a take with no final text: its live words).
    var text: String { if let e = entry { return e.text.isEmpty ? e.raw : e.text }; return doc?.title ?? "" }
    static func == (a: TapeItem, b: TapeItem) -> Bool { a.id == b.id && a.entry == b.entry && a.doc == b.doc }

    static func flat(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum TapeBuild {
    /// All kinds merged, newest first, after the search and the kind filter. Pure: runs off the main thread.
    static func rows(takes: [Entry], clips: [Entry], typed: [Entry], docs: [CallDoc], query: String, kinds: Set<TapeKind>, gone: Set<String>) -> [TapeItem] {
        var out: [TapeItem] = []
        out.reserveCapacity(takes.count + clips.count + typed.count + docs.count)
        let q = query.trimmingCharacters(in: .whitespaces), terms = CallDoc.terms(q)
        if kinds.contains(.copied) {
            for e in clips where q.isEmpty || e.matches(q) {
                out.append(TapeItem(id: "c:\(Int(e.when.timeIntervalSince1970 * 1000)):\(e.text.count)", kind: .copied, at: e.when.timeIntervalSince1970, app: e.app, line: TapeItem.flat(e.text), entry: e))
            }
        }
        if kinds.contains(.typed) {
            for e in typed where q.isEmpty || e.matches(q) {
                let t = (e.touched ?? e.when).timeIntervalSince1970
                out.append(TapeItem(id: "t:" + e.id, kind: .typed, at: t, app: e.app, line: TapeItem.flat(e.text.isEmpty ? e.summary : e.text), entry: e))
            }
        }
        if kinds.contains(.said) {
            let only = kinds == [.said]   // audio-only takes show when he looks at said alone
            for e in takes where (only || !e.audioOnly) && (q.isEmpty || e.matches(q)) {
                out.append(TapeItem(id: "v:" + e.id, kind: .said, at: e.when.timeIntervalSince1970, app: e.app, line: TapeItem.flat(e.summary), entry: e))
            }
        }
        if kinds.contains(.call) {
            for d in docs where terms.isEmpty || d.matches(terms) {
                out.append(TapeItem(id: "d:" + d.id, kind: .call, at: d.started.timeIntervalSince1970, app: d.app, line: d.title, doc: d))
            }
        }
        if !gone.isEmpty { out.removeAll { gone.contains($0.id) } }
        out.sort { $0.at > $1.at }
        return out
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

    static func clock(_ s: Double) -> String { let n = Int(s.rounded()); return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60) }
}

// MARK: the view

/// The tape, drawn (AppKit): only the lines in view are drawn; the layout is arithmetic.
final class TapeView: NSView {
    weak var model: WindowModel?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }   // the field keeps the keys; a click chooses a row
    static let G: CGFloat = 132, gap: CGFloat = 20, side: CGFloat = 24, rowH: CGFloat = 44, hourH: CGFloat = 36, dayH: CGFloat = 76
    static var font: NSFont { PK.text(16) }   // asked each time: a theme can change the face
    static let lh: CGFloat = 24

    enum LineKind { case day(String), hour(String), row(Int) }
    struct Line { let kind: LineKind; let y: CGFloat; let h: CGFloat }
    private(set) var lines: [Line] = []
    private(set) var rows: [TapeItem] = []
    private var rowLine: [String: Int] = [:]     // row id -> line index
    var chosen: String?, open: String?
    var query = ""
    var now = Date().timeIntervalSince1970
    private var hits: [(NSRect, () -> Void)] = []
    private var faces: [String: NSImage] = [:]
    private var laidWidth: CGFloat = 0

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    var textX: CGFloat { Self.G + Self.gap }
    var textW: CGFloat { bounds.width - textX - Self.gap - Self.side }

    // MARK: layout

    private static let dayName: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE, d MMMM"; return f }()
    static func day(_ t: Double, now: Double) -> String {
        let off = Double(TimeZone.current.secondsFromGMT()), d = Int(floor((t + off) / 86400)), today = Int(floor((now + off) / 86400))
        let name = dayName.string(from: Date(timeIntervalSince1970: t))
        return d == today ? "Today · " + name : d == today - 1 ? "Yesterday · " + name : name
    }

    func height(_ it: TapeItem, chosen on: Bool, open: Bool) -> CGFloat {
        if let d = it.doc { return callH(d) + (on ? TapeDraw.capH + 16 : 0) }
        guard open, let e = it.entry else { return Self.rowH }
        let n = TapeDraw.lines(it.text.isEmpty ? e.summary : it.text, width: textW, font: Self.font, lh: Self.lh, max: 40)
        var h: CGFloat = 10 + CGFloat(n) * Self.lh + 8 + 16 + 14 + clipExtraH(e)
        if !e.drafts.isEmpty { h += 22 + CGFloat(min(3, e.drafts.count)) * 22 + 6 }
        return h + TapeDraw.capH + 16
    }
    // round three: a copied picture opens with the picture and its read text above the meta line
    static let pictureH: CGFloat = 220
    private func picture(_ e: Entry) -> NSImage? {
        e.clip == .image && !e.picture.isEmpty ? TapeDraw.thumb(History.clipURL(e.picture), px: 720) : nil
    }
    private func ocrText(_ e: Entry) -> String { e.ocr.split(whereSeparator: \.isNewline).joined(separator: " ") }
    func clipExtraH(_ e: Entry) -> CGFloat {
        var h: CGFloat = 0
        if picture(e) != nil { h += Self.pictureH + 10 }
        let t = ocrText(e)
        if !t.isEmpty { h += CGFloat(TapeDraw.lines(t, width: textW, font: PK.text(14), lh: 20, max: 6)) * 20 + 8 }
        return h
    }
    func callH(_ d: CallDoc) -> CGFloat {
        let sides: CGFloat = d.call ? 2 : 1
        let left = 14 + 24 + 8 + sides * 32 + 12
        let right = 14 + CGFloat(min(3, max(1, outline(d).count))) * 26 + 14
        return max(left, right)
    }
    func outline(_ d: CallDoc) -> [String] {
        if !d.points.isEmpty { return Array(d.points.prefix(3)) }
        if d.live { return ["Recording…"] }
        return d.turns.prefix(3).map { TapeItem.flat($0.text) }
    }

    /// New rows, chosen and open: lays out again and keeps the anchor row where it was on screen.
    func apply(rows newRows: [TapeItem], chosen c: String?, open o: String?, query q: String) {
        let clip = enclosingScrollView?.contentView
        let top = clip?.bounds.minY ?? 0
        let moved = c != chosen || o != open
        // the anchor: the chosen row when it is in view, else the first row in view
        var anchor: (id: String, dy: CGFloat)?
        if let c = chosen, let i = rowLine[c], lines[i].y + lines[i].h > top, lines[i].y < top + (clip?.bounds.height ?? 0) { anchor = (c, lines[i].y - top) }
        else if let l = firstLine(atOrBelow: top), case .row(let r) = lines[l].kind, r < rows.count { anchor = (rows[r].id, lines[l].y - top) }
        rows = newRows; chosen = c; open = o; query = q
        layout(width: bounds.width)
        if let clip, clip.bounds.height >= 1 {
            var y = top
            if let a = anchor, let i = rowLine[a.id] { y = lines[i].y - a.dy }
            if moved, let c, let i = rowLine[c] {   // the chosen row whole in view, moving as little as it can
                let l = lines[i], vh = clip.bounds.height
                if l.y < y { y = l.y - (i > 0 ? lines[i - 1].h : 0) }
                else if l.y + l.h > y + vh { y = min(l.y, l.y + l.h - vh + 12) }
            }
            y = max(0, min(y, frame.height - clip.bounds.height))
            if abs(y - top) > 0.5 { clip.scroll(to: NSPoint(x: 0, y: y)); enclosingScrollView?.reflectScrolledClipView(clip) }
        }
        needsDisplay = true
        reportDay()
    }

    func layout(width: CGFloat) {
        laidWidth = width
        var out: [Line] = [], map: [String: Int] = [:]
        out.reserveCapacity(rows.count + rows.count / 4)
        let off = Double(TimeZone.current.secondsFromGMT())
        var y: CGFloat = 0, lastDay = Int.min, lastHour = Int.min
        let hours = query.isEmpty
        for (i, it) in rows.enumerated() {
            let d = Int(floor((it.at + off) / 86400)), h = Int(floor((it.at + off) / 3600))
            if d != lastDay {
                if lastDay != Int.min { out.append(Line(kind: .day(Self.day(it.at, now: now)), y: y, h: Self.dayH)); y += Self.dayH }
                lastDay = d; lastHour = Int.min
            }
            if hours, h != lastHour {
                out.append(Line(kind: .hour(String(format: "%02d:00", ((h % 24) + 24) % 24)), y: y, h: Self.hourH)); y += Self.hourH
            }
            lastHour = h
            let rh = height(it, chosen: it.id == chosen, open: it.id == open)
            map[it.id] = out.count
            out.append(Line(kind: .row(i), y: y, h: rh)); y += rh
        }
        lines = out; rowLine = map
        let vh = enclosingScrollView?.contentView.bounds.height ?? 0
        let h = max(y + 24, vh)
        if abs(frame.height - h) > 0.5 || abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: h)) }
    }

    override func resizeSubviews(withOldSize old: NSSize) { super.resizeSubviews(withOldSize: old) }
    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        if abs(s.width - laidWidth) > 0.5, s.width > 0 { layout(width: s.width); needsDisplay = true }
    }

    /// The first line whose bottom is below `y` (binary search).
    func firstLine(atOrBelow y: CGFloat) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi { let mid = (lo + hi) / 2; if lines[mid].y + lines[mid].h <= y { lo = mid + 1 } else { hi = mid } }
        return lo < lines.count ? lo : nil
    }

    /// The day of the first row in view, for the heading above the tape.
    func reportDay() {
        guard let m = model else { return }
        let top = enclosingScrollView?.contentView.bounds.minY ?? 0
        var t = rows.first?.at
        if let i = firstLine(atOrBelow: top) {
            for l in lines[i...] { if case .row(let r) = l.kind { t = rows[r].at; break } }
        }
        let s = t.map { Self.day($0, now: now) } ?? Self.day(now, now: now)
        if m.dayTitle != s { DispatchQueue.main.async { if m.dayTitle != s { m.dayTitle = s } } }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        hits = []
        guard !rows.isEmpty, let first = firstLine(atOrBelow: dirty.minY) else {
            let s = model?.query.isEmpty == false ? "Nothing matches «\(model?.query ?? "")»" : "Nothing copied, typed, said or recorded yet"
            TapeDraw.line(s, NSRect(x: textX, y: 14, width: max(0, textW), height: 24), TapeDraw.at(PK.text(15), PK.muted))
            PK.line.setFill(); NSRect(x: Self.G - 1, y: 0, width: 1, height: 52).fill()
            return
        }
        var i = first
        while i < lines.count, lines[i].y < dirty.maxY {
            let l = lines[i]
            switch l.kind {
            case .day(let s): drawDay(s, y: l.y)
            case .hour(let s): drawHour(s, y: l.y, h: l.h)
            case .row(let r): drawRow(rows[r], y: l.y, h: l.h)
            }
            i += 1
        }
    }

    private func drawDay(_ s: String, y: CGFloat) {
        let f = PK.display(22)
        TapeDraw.line(s, NSRect(x: 0, y: y + Self.dayH - 22 - f.ascender + f.descender, width: bounds.width, height: 30), TapeDraw.at(f, PK.ink))
        TapeDraw.hairline(x0: 0, x1: bounds.width, y: y + Self.dayH - 1, color: PK.rule)
    }

    private func drawHour(_ s: String, y: CGFloat, h: CGFloat) {
        PK.line.setFill(); NSRect(x: Self.G - 1, y: y, width: 1, height: h).fill()
        let f = PK.mono(12), a = TapeDraw.at(f, PK.faint)
        (s as NSString).draw(at: NSPoint(x: Self.G - 14 - TapeDraw.width(s, a), y: TapeDraw.lineTop(f, mid: y + h / 2)), withAttributes: a)
        TapeDraw.hairline(x0: textX, x1: bounds.width, y: (y + h / 2).rounded())
    }

    private func drawRow(_ it: TapeItem, y: CGFloat, h: CGFloat) {
        let W = bounds.width, on = it.id == chosen, isOpen = it.id == open
        if on { TapeDraw.lift.setFill(); NSRect(x: 0, y: y, width: W, height: h).fill() }
        let tall = it.doc != nil || isOpen
        let pinned = it.quick.map { Quick.shared.isPinned($0, it.text) } ?? false
        TapeDraw.gutter(NSRect(x: 0, y: y, width: Self.G, height: h), kind: it.kind, time: TapeDraw.time(it.at),
                        mark: it.doc.map { $0.call ? "phone" : "file" } ?? (pinned ? "bookmark" : it.entry.flatMap { TapeDraw.clipMark($0.clip) }), chosen: on,
                        top: tall ? 12 : nil, size: 13, gap: 12, pad: 14)
        TapeDraw.hairline(x0: 0, x1: W, y: y + h - 1)
        if let a = TapeDraw.appMark(it.app) { TapeDraw.glyph(a, NSRect(x: W - 20, y: tall ? y + 12 : y + h / 2 - 9, width: 18, height: 18), color: on ? PK.muted : PK.faint) }
        if let d = it.doc { drawCall(it, d, y: y, h: h, on: on); return }
        let x = textX, w = textW
        guard isOpen, let e = it.entry else {
            let empty = it.entry.map { $0.text.isEmpty } ?? false
            if let e = it.entry, e.clip != .text {   // a link, file or picture: the same line as in the Quick panel
                var tx = x, tw = w
                if let img = picture(e) {
                    let r = TapeDraw.picture(img, in: NSRect(x: x, y: y + 5, width: 56, height: h - 10)); tx = r.maxX + 12; tw = w - (tx - x)
                }
                TapeDraw.clipLine(e.clip, text: e.text, title: e.clipTitle, bytes: e.bytes, ocr: e.ocr,
                                  NSRect(x: tx, y: TapeDraw.lineTop(Self.font, mid: y + h / 2), width: tw, height: Self.lh), font: Self.font)
                return
            }
            TapeDraw.line(it.line, NSRect(x: x, y: TapeDraw.lineTop(Self.font, mid: y + h / 2), width: w, height: Self.lh),
                          TapeDraw.at(Self.font, empty ? PK.muted : PK.ink, cut: it.line.contains(" ") ? .byTruncatingTail : .byTruncatingMiddle))
            return
        }
        let body = it.text.isEmpty ? e.summary : it.text
        let n = TapeDraw.lines(body, width: w, font: Self.font, lh: Self.lh, max: 40)
        var cy = y + 10
        if let img = picture(e) { TapeDraw.picture(img, in: NSRect(x: x, y: cy, width: w, height: Self.pictureH)); cy += Self.pictureH + 10 }
        TapeDraw.block(body, x: x, y: cy, width: w, font: Self.font, color: it.text.isEmpty ? PK.muted : PK.ink, lh: Self.lh, max: 40)
        cy += CGFloat(n) * Self.lh + 8
        let read = ocrText(e)
        if !read.isEmpty {
            let k = TapeDraw.lines(read, width: w, font: PK.text(14), lh: 20, max: 6)
            TapeDraw.block(read, x: x, y: cy, width: w, font: PK.text(14), color: PK.muted, lh: 20, max: 6)
            cy += CGFloat(k) * 20 + 8
        }
        // the meta line: the second it came, the app, the length (and a take's seconds)
        var meta = [Self.seconds.string(from: Date(timeIntervalSince1970: it.at))]
        if !it.app.isEmpty { meta.append(it.app) }
        if e.secs >= 1 { meta.append(TapeBuild.clock(e.secs)) }
        meta.append("\(it.text.count) chars")
        if e.incomplete { meta.append(e.outcome == "timeout" ? "timed out" : "no final text") }
        TapeDraw.line(meta.joined(separator: " · "), NSRect(x: x, y: cy, width: w, height: 16), TapeDraw.at(PK.mono(12), PK.muted))
        cy += 16 + 14
        if !e.drafts.isEmpty {
            let a = TapeDraw.at(PK.text(13), PK.muted)
            TapeDraw.line(e.drafts.count == 1 ? "1 draft before" : "\(e.drafts.count) drafts before", NSRect(x: x, y: cy, width: w, height: 18), a)
            cy += 22
            for d in e.drafts.suffix(3).reversed() {
                TapeDraw.line(TapeItem.flat(d), NSRect(x: x + 14, y: cy, width: w - 14, height: 20), TapeDraw.at(PK.text(14), PK.muted))
                PK.rule.setFill(); NSRect(x: x + 2, y: cy + 3, width: 1, height: 14).fill()
                cy += 22
            }
            cy += 6
        }
        // the keys
        guard let m = model else { return }
        var ax = x
        func key(_ k: String, _ word: String, _ act: @escaping () -> Void) {
            let x1 = TapeDraw.keyWord(k, word, x: ax, y: cy)
            hits.append((NSRect(x: ax, y: cy, width: x1 - ax - 16, height: TapeDraw.capH), act)); ax = x1
        }
        if e.clip == .text || e.clip == .link, !it.text.isEmpty { key("⇧⌘C", "copy") { m.copy(e) } }
        // a link, file or picture (or a text holding one): its own keys, as in the Quick panel (clicked here)
        let q = e.quickItem
        for a in Quick.shared.actions(q) where a.id != "paste" { key(a.key, a.word) { Quick.shared.act(a.id, q) } }
        if let q = it.quick, !it.text.isEmpty { key("⌘P", Quick.shared.isPinned(q, it.text) ? "unpin" : "pin") { m.togglePin(it) } }
        if !e.audio.isEmpty { key("⌘L", "play") { m.play(e) } }
        if !e.raw.isEmpty, e.raw != e.text { key("⌥⌘C", e.incomplete ? "live words" : "before cleanup") { m.copyOriginal(e) } }
        key("⌘⌫", "delete") { m.remove(it) }
    }
    private static let seconds: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    private func face(_ name: String) -> NSImage? {
        if let i = faces[name] { return i }
        guard let u = PK.art?.appendingPathComponent("people/\(name).png"), let i = NSImage(contentsOf: u) else { return nil }
        faces[name] = i; return i
    }

    /// A call or a long note: title and length, each side's face, a level bar of how long it spoke and the time; the
    /// outline on the right (three lines at most).
    private func drawCall(_ it: TapeItem, _ d: CallDoc, y: CGFloat, h: CGFloat, on: Bool) {
        let x = textX, leftW: CGFloat = 300, ox = x + leftW + 32, ow = textW - leftW - 32
        var cy = y + 14
        let tf = PK.text(17, .semibold), ta = TapeDraw.at(tf, PK.ink)
        let len = d.live ? "recording" : TapeBuild.clock(d.secs), la = TapeDraw.at(PK.mono(13), d.live ? PK.coral : PK.muted)
        let lw = TapeDraw.width(len, la)
        let title = d.title.isEmpty ? (d.call ? "Call" : "Long note") : d.title
        let tw = min(TapeDraw.width(title, ta), leftW - lw - 12)
        TapeDraw.line(title, NSRect(x: x, y: TapeDraw.lineTop(tf, mid: cy + 12), width: tw, height: 24), ta)
        (len as NSString).draw(at: NSPoint(x: x + tw + 12, y: TapeDraw.lineTop(PK.mono(13), mid: cy + 12)), withAttributes: la)
        cy += 24 + 8
        let total = max(1, d.secs)
        for s in TapeBuild.sides(d) {
            let mid = cy + 14
            if let img = face(s.face) {
                NSGraphicsContext.current?.imageInterpolation = .none
                img.draw(in: NSRect(x: x, y: mid - 12, width: 24, height: 24), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
            let na = TapeDraw.at(PK.text(14), PK.ink)
            TapeDraw.line(s.name, NSRect(x: x + 34, y: TapeDraw.lineTop(PK.text(14), mid: mid), width: 64, height: 20), na)
            // the level: 18 cells 6 x 12 every 8, the side's colour for its share of the length
            let cells = 18, lit = s.secs > 0 ? max(1, Int((s.secs / total * Double(cells)).rounded())) : 0
            let bx = x + 100
            for c in 0..<cells { (c < lit ? (s.me ? PK.blue : PK.coral) : on ? PK.rule : PK.soft).setFill(); NSRect(x: bx + CGFloat(c) * 8, y: mid - 6, width: 6, height: 12).fill() }
            let st = TapeBuild.clock(s.secs), sa = TapeDraw.at(PK.mono(12), PK.muted)
            (st as NSString).draw(at: NSPoint(x: x + leftW - TapeDraw.width(st, sa), y: TapeDraw.lineTop(PK.mono(12), mid: mid)), withAttributes: sa)
            cy += 32
        }
        // the outline
        var oy = y + 14
        let of = PK.text(15)
        for p in outline(d) where ow > 60 {
            PK.ink.setFill(); NSRect(x: ox, y: oy + 13 - 3, width: 6, height: 6).fill()
            TapeDraw.line(p, NSRect(x: ox + 16, y: TapeDraw.lineTop(of, mid: oy + 13), width: ow - 16, height: 22), TapeDraw.at(of, d.live ? PK.muted : PK.ink))
            oy += 26
        }
        guard on, let m = model else { return }
        let ky = y + h - TapeDraw.capH - 14
        var ax = x
        func key(_ k: String, _ word: String, _ act: @escaping () -> Void) {
            let x1 = TapeDraw.keyWord(k, word, x: ax, y: ky)
            hits.append((NSRect(x: ax, y: ky, width: x1 - ax - 16, height: TapeDraw.capH), act)); ax = x1
        }
        key("↵", "open") { m.openDoc(d) }
        if !d.turns.isEmpty { key("⇧⌘A", "for agent") { m.sendToAgent(d) } }
        key("⇧⌘C", "copy notes") { m.copyNotes(d) }
        if d.hasAudio { key("⌘L", m.playing == d.id ? "stop" : "play") { m.playing == d.id ? m.stopPlaying() : m.play(d, from: 0) } }
    }

    // MARK: the mouse: a click chooses a row; a click on the chosen row opens it; a key word runs

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let h = hits.first(where: { $0.0.contains(p) }) { h.1(); return }
        guard let i = firstLine(atOrBelow: p.y), lines[i].y <= p.y, case .row(let r) = lines[i].kind, let m = model else { return }
        let id = rows[r].id
        if e.clickCount >= 2 || m.chosen == id { m.chosen = id; m.enter() } else { m.choose(id) }
    }
}

/// The tape in SwiftUI: an NSScrollView around the drawn view.
struct TapeList: NSViewRepresentable {
    @ObservedObject var m: WindowModel
    func makeNSView(context: Context) -> NSScrollView {
        let s = NSScrollView()
        s.hasVerticalScroller = true; s.autohidesScrollers = true; s.drawsBackground = false; s.borderType = .noBorder
        s.scrollerStyle = .overlay
        let v = TapeView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v.model = m; v.autoresizingMask = [.width]
        s.documentView = v
        s.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: s.contentView, queue: .main) { [weak v] _ in v?.reportDay() }
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        guard let v = s.documentView as? TapeView else { return }
        if v.frame.width != s.contentView.bounds.width, s.contentView.bounds.width > 0 { v.setFrameSize(NSSize(width: s.contentView.bounds.width, height: v.frame.height)) }
        if v.rows != m.rows || v.chosen != m.chosen || v.open != m.open || v.query != m.query || m.tapeTick != context.coordinator.tick {
            context.coordinator.tick = m.tapeTick
            v.now = m.now
            v.apply(rows: m.rows, chosen: m.chosen, open: m.open, query: m.query)
        }
    }
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var tick = -1 }
}

// MARK: the field, the heading, the corner marks

/// The one main thing: it searches the tape; after ⌘K it takes a command.
struct TapeField: View {
    @EnvironmentObject var m: WindowModel
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 14) {
            Glyph(m.commandMode ? "send" : "search", size: 24).foregroundStyle(m.commandMode ? UIInk.ink : UIInk.muted)
            let prompt = m.commandMode ? "Book 30 min tomorrow · find a free slot · task… · ;snippet" : "Search the tape"
            TextField(m.commandMode ? "Ask Drafter" : "Search", text: m.commandMode ? $m.command : $m.query,
                      prompt: Text(prompt).foregroundColor(UIInk.faint))
                .textFieldStyle(.plain).font(PKFont.text(24)).focused($focused)
                .onSubmit { m.enter() }
                .onExitCommand { m.escape() }
                .onKeyPress(.upArrow) { m.move(-1); return .handled }
                .onKeyPress(.downArrow) { m.move(1); return .handled }
                .onKeyPress(.pageUp) { m.move(-8); return .handled }
                .onKeyPress(.pageDown) { m.move(8); return .handled }
                .accessibilityLabel(m.commandMode ? "Command" : "Search the tape")
            if m.thinking { ProgressView().controlSize(.small) }
            else { KeyChip(m.commandMode ? "esc" : "⌘K") }
        }
        .padding(.horizontal, 20).frame(height: 64)
        .background(RoundedRectangle(cornerRadius: PK.corner(3)).fill(UIInk.card))
        .overlay { RoundedRectangle(cornerRadius: PK.corner(3)).strokeBorder(focused ? UIInk.blue.opacity(0.7) : Color(nsColor: PKColors.controlEdge), lineWidth: focused ? 1.5 : 1) }
        .onChange(of: m.focusField, initial: true) { _, _ in focused = true }
    }
}

/// A borderless glyph button with its key beside it and a soft hover.
struct CornerMark: View {
    let glyph: String
    let key: String
    let label: String
    var on = false
    let act: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Glyph(glyph, size: 18).foregroundStyle(on ? UIInk.ink : UIInk.muted)
                Text(key).font(PKFont.mono(11)).foregroundStyle(UIInk.faint)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: PK.corner(2)).fill(hover || on ? UIInk.soft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.accessibilityLabel(label).help("\(label) (\(key))")
    }
}

/// The kind filter: four glyphs, borderless; pressed is ink, the rest faint.
struct KindMarks: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(TapeKind.allCases.enumerated()), id: \.offset) { i, k in
                KindButton(kind: k, on: m.kinds.contains(k), key: "⌘\(i + 1)") { m.solo(k) }
            }
        }
    }
}

struct KindButton: View {
    let kind: TapeKind
    let on: Bool
    let key: String
    let act: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: act) {
            Glyph(kind.mark, size: 18).foregroundStyle(on ? UIInk.ink : UIInk.faint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: PK.corner(2)).fill(hover ? UIInk.soft : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.accessibilityLabel(kind.name).help("\(kind.name) (\(key))")
    }
}

/// The page's way back: the arrow and esc.
struct BackRow: View {
    @EnvironmentObject var m: WindowModel
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Button { m.back() } label: {
                HStack(spacing: 8) {
                    Glyph("arrow-left", size: 18)
                    Text("Tape").font(PKFont.text(14))
                    KeyChip("esc")
                }.foregroundStyle(UIInk.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Back to the tape")
            Text(title).font(PKFont.text(14)).foregroundStyle(UIInk.faint).lineLimit(1)
            Spacer()
        }
    }
}
