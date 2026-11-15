// The journal as a gallery of cards (soft round, 14 November 2026): the baseline view. Cards sit in an adaptive grid
// inside the chunks of time (columns from the pane's width, JournalLayout.columns); a session is a quiet label; chunk
// headers stay at the top while their cards scroll. Each card shows its content first (text, code, a link with its
// site mark, a picture, a file, a recording) and one foot line: the kind mark, the trail of real app icons (where it
// came from, where it went), time and length. Only the cards in view are drawn. Keys: TapeNav (gallery moves).
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Real app icons by name, cached; nil when the app is not on this Mac (the card draws a neutral glyph).
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]
    static let ids = ["Safari": "com.apple.Safari", "Mail": "com.apple.mail", "Notes": "com.apple.Notes", "Terminal": "com.apple.Terminal",
                      "Finder": "com.apple.finder", "Messages": "com.apple.MobileSMS", "Calendar": "com.apple.iCal", "Preview": "com.apple.Preview",
                      "Xcode": "com.apple.dt.Xcode", "Claude": "com.anthropic.claudefordesktop", "Slack": "com.tinyspeck.slackmacgap",
                      "Telegram": "ru.keepcoder.Telegram", "Google Chrome": "com.google.Chrome", "Beeper": "com.automattic.beeper.desktop"]
    static func icon(_ name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        if let c = cache[name] { return c }
        var url: URL?
        if let id = ids[name] { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
        if url == nil {
            for d in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices",
                      "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"] {
                let u = URL(fileURLWithPath: d).appendingPathComponent(name + ".app")
                if FileManager.default.fileExists(atPath: u.path) { url = u; break }
            }
        }
        let img = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        if cache.count > 300 { cache.removeAll() }
        cache[name] = img
        return img
    }
}

/// A scroll view whose page always takes the visible width (a pane that opens beside it narrows the page at once,
/// not at the next change of the model).
final class FitScroll: NSScrollView {
    override func layout() {
        super.layout()
        let w = contentView.bounds.width
        if let d = documentView, w > 0, d.frame.width != w { d.setFrameSize(NSSize(width: w, height: d.frame.height)); d.needsDisplay = true }
    }
}

struct GalleryList: NSViewRepresentable {
    @ObservedObject var m: WindowModel
    func makeNSView(context: Context) -> NSScrollView {
        let s = FitScroll()
        s.hasVerticalScroller = true; s.autohidesScrollers = true; s.drawsBackground = false; s.borderType = .noBorder
        s.scrollerStyle = .overlay
        let v = GalleryView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v.model = m; v.autoresizingMask = [.width]
        s.documentView = v
        m.galleryView = v
        s.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: s.contentView, queue: .main) { [weak v] _ in
            v?.needsDisplay = true; v?.reportChunk()
        }
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        guard let v = s.documentView as? GalleryView else { return }
        m.galleryView = v
        let w = s.contentView.bounds.width
        if v.frame.width != w, w > 0 { v.setFrameSize(NSSize(width: w, height: v.frame.height)) }
        let snap = m.snap
        if snap != v.snap || v.size != m.settings.cardSize || v.laidWidth != v.bounds.width { v.apply(snap, size: m.settings.cardSize) }
    }
}

final class GalleryView: NSView, NSDraggingSource {
    weak var model: WindowModel?
    var snap = TapeSnap()
    var size = 1
    var laidWidth: CGFloat = -1
    override var isFlipped: Bool { true }

    enum Block { case header(Int), label(Int), rule(Int), part(Int), card(Int) }
    struct Placed { let block: Block; let rect: NSRect }
    private(set) var placed: [Placed] = []
    private var at: [String: Int] = [:]       // line id → placed index
    private(set) var cols = 1
    private var hover: String?
    private var hoverButton = -1
    private var hits: [(NSRect, () -> Void)] = []
    private var glide: (from: NSRect, start: Double)?
    private var glideTimer: Timer?
    private var lastChosenRect: NSRect?
    private var down: (point: NSPoint, id: String)?
    private var faces: [String: NSImage] = [:]
    /// The chips of a text card (wire round): at most 3 things the detector found (Detect.summary), per item and text.
    private var chipCache: [String: (sig: Int, chips: [Found])] = [:]
    var drawMs = 0.0                           // the last draw (the preview's scroll cost)

    static let chunkH = CGFloat(JournalLayout.chunkH), headH: CGFloat = 34, partH = CGFloat(JournalLayout.partH), labelH = CGFloat(JournalLayout.labelH), footH = CGFloat(JournalLayout.cardFoot)

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: layout

    func apply(_ s: TapeSnap, size: Int) {
        let again = s.lines != snap.lines || s.build != snap.build || size != self.size || laidWidth != bounds.width
        let oldChosen = snap.chosen
        snap = s; self.size = size
        if again { relayout() }
        if let c = s.chosen, c != oldChosen, let i = at[c], let from = lastChosenRect, PK.motion("fold") > 0 {
            glide = (from, Date().timeIntervalSince1970)
            glideTimer?.invalidate()
            glideTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] t in
                guard let self, let g = self.glide, Date().timeIntervalSince1970 - g.start < PK.motion("fold") else { self?.glide = nil; self?.needsDisplay = true; t.invalidate(); return }
                self.needsDisplay = true
            }
            _ = i
        }
        needsDisplay = true
    }

    func relayout() {
        laidWidth = bounds.width
        guard let m = model else { return }
        let w = Double(bounds.width)
        cols = JournalLayout.columns(width: w, size: size)
        m.galleryCols = cols
        let cw = CGFloat(JournalLayout.cardWidth(width: w, cols: cols))
        let ch = CGFloat(JournalLayout.cardHeight[JournalLayout.step(size)])
        let gap = CGFloat(JournalLayout.gap), pad = CGFloat(JournalLayout.pad)
        var out: [Placed] = [], map: [String: Int] = [:]
        out.reserveCapacity(snap.lines.count)
        var y: CGFloat = 6
        // a run: the sessions and single items between two headers, packed into the grid without gaps; a session's
        // label sits in a strip above the grid row where its first card is, as wide as its cards in that row
        var run: [(line: Int, label: Bool)] = []
        func flush() {
            guard !run.isEmpty else { return }
            var cards: [Int] = [], labels: [(line: Int, first: Int, count: Int)] = []
            var open: Int?   // the label whose cards are being counted
            for e in run {
                if e.label { labels.append((e.line, cards.count, 0)); open = labels.count - 1 }
                else {
                    if let o = open, snap.lines[e.line].inSession { labels[o].count += 1 } else { open = nil }
                    cards.append(e.line)
                }
            }
            let rows = (cards.count + cols - 1) / max(1, cols)
            // each session's place row by row (JournalLayout.segments): its label above its first row, a quiet rule in
            // the gap above each further row, so the grouping carries across rows without costing a text row
            var segs: [(line: Int, seg: JournalLayout.Segment)] = []
            for lb in labels where lb.count > 0 {
                for sg in JournalLayout.segments(first: lb.first, count: lb.count, cols: cols) { segs.append((lb.line, sg)) }
            }
            for r in 0..<rows {
                let here = segs.filter { $0.seg.row == r }
                let strip: CGFloat = here.contains { $0.seg.label } ? CGFloat(JournalLayout.labelH) : 0
                for s in here {
                    let x = pad + CGFloat(s.seg.col) * (cw + gap) - 2, w = CGFloat(s.seg.span) * (cw + gap) - gap + 4
                    if s.seg.label {
                        let rect = NSRect(x: x, y: y, width: w, height: strip)
                        map[snap.lines[s.line].id] = out.count; out.append(Placed(block: .label(s.line), rect: rect))
                    } else {
                        out.append(Placed(block: .rule(s.line), rect: NSRect(x: x, y: y + strip - gap / 2 - 1, width: w, height: 2)))
                    }
                }
                y += strip
                for k in (r * cols)..<min(cards.count, (r + 1) * cols) {
                    let l = cards[k]
                    let rect = NSRect(x: pad + CGFloat(k % cols) * (cw + gap), y: y, width: cw, height: ch)
                    map[snap.lines[l].id] = out.count; out.append(Placed(block: .card(l), rect: rect))
                }
                y += ch + gap
            }
            run = []
        }
        for (i, l) in snap.lines.enumerated() {
            switch l.kind {
            case .row: run.append((i, false))
            case .session: run.append((i, true))
            case .chunk:
                flush(); if !out.isEmpty { y += 8 }
                map[l.id] = out.count; out.append(Placed(block: .header(i), rect: NSRect(x: 0, y: y, width: bounds.width, height: Self.chunkH))); y += Self.chunkH
            case .head:
                flush()
                map[l.id] = out.count; out.append(Placed(block: .header(i), rect: NSRect(x: 0, y: y, width: bounds.width, height: Self.headH))); y += Self.headH
            case .part:
                flush()
                map[l.id] = out.count; out.append(Placed(block: .part(i), rect: NSRect(x: 0, y: y, width: bounds.width, height: Self.partH))); y += Self.partH
            }
        }
        flush()
        placed = out; at = map
        let h = max(y + pad, enclosingScrollView?.contentView.bounds.height ?? 0)
        if frame.height != h { setFrameSize(NSSize(width: bounds.width, height: h)) }
    }

    override func setFrameSize(_ s: NSSize) {
        let wChanged = s.width != frame.width
        super.setFrameSize(s)
        if wChanged, model != nil { relayout(); needsDisplay = true }
    }

    /// The first placed block whose bottom is below `y` (binary search: the blocks go down the page in order).
    private func first(below y: CGFloat) -> Int {
        var lo = 0, hi = placed.count
        while lo < hi { let mid = (lo + hi) / 2; if placed[mid].rect.maxY < y { lo = mid + 1 } else { hi = mid } }
        return max(0, lo - 2 * cols)   // a row's labels and cards share a top: step back past them
    }

    func scrollTo(_ id: String) {
        guard let i = at[id], let clip = enclosingScrollView?.contentView else { return }
        let r = placed[i].rect
        let vis = clip.bounds
        var y = vis.minY
        let top = Self.chunkH + 6
        if r.minY - top < vis.minY { y = r.minY - top } else if r.maxY + 16 > vis.maxY { y = r.maxY + 16 - vis.height }
        y = max(0, min(y, frame.height - vis.height))
        if y != vis.minY { clip.scroll(to: NSPoint(x: 0, y: y)); enclosingScrollView?.reflectScrolledClipView(clip) }
        reportChunk()
    }

    func reportChunk() {
        guard let m = model else { return }
        let top = enclosingScrollView?.contentView.bounds.minY ?? 0
        var t = "", sub = "", id = ""
        if let k = chunkAbove(top) { let l = snap.lines[k]; t = l.title; sub = l.sub; id = l.id }
        if m.chunkInView != id { DispatchQueue.main.async { m.dayTitle = t; m.daySub = sub; m.chunkInView = id } }
    }
    private func chunkAbove(_ y: CGFloat) -> Int? {
        var best: Int?
        for p in placed[0..<min(placed.count, first(below: y + 1) + cols + 1)] {
            if case .header(let i) = p.block, snap.lines[i].kind == .chunk, p.rect.minY <= y + 1 { best = i }
        }
        return best
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        let t0 = Date()
        guard let m = model else { return }
        hits = []
        let vis = visibleRect
        if placed.isEmpty {   // the same words as the list's empty state
            let w: String
            if !snap.query.isEmpty { w = "Nothing matches «\(snap.query)»" }
            else if m.filter != .all { w = "Nothing " + TapeRules.words(m.filter) + " yet" }
            else { w = "The journal is empty: clips, drafts, voice notes and recordings show here" }
            TapeDraw.line(w, NSRect(x: CGFloat(JournalLayout.pad) + 4, y: vis.minY + 18, width: max(0, bounds.width - 40), height: 22), TapeDraw.at(PK.text(14), PK.muted))
            return
        }
        var i = first(below: vis.minY)
        while i < placed.count, placed[i].rect.minY <= vis.maxY {
            let p = placed[i]
            if p.rect.intersects(dirty) {
                switch p.block {
                case .card(let k): drawCard(snap.lines[k], p.rect, m)
                case .header(let k): drawHeader(snap.lines[k], p.rect, sticky: false)
                case .label(let k): drawLabel(snap.lines[k], p.rect, m)
                case .part(let k): drawPart(snap.lines[k], p.rect)
                case .rule: drawRule(p.rect)
                }
            }
            i += 1
        }
        // the chunk in view stays at the top while its cards scroll under it
        if let k = chunkAbove(vis.minY), let pi = at[snap.lines[k].id], placed[pi].rect.minY < vis.minY {
            var r = NSRect(x: 0, y: vis.minY, width: bounds.width, height: Self.chunkH)
            if let next = placed[(pi + 1)...].first(where: { if case .header(let j) = $0.block { return snap.lines[j].kind == .chunk }; return false }),
               next.rect.minY < r.maxY { r.origin.y = next.rect.minY - r.height }   // the next chunk pushes it up
            drawHeader(snap.lines[k], r, sticky: true)
        }
        drawMs = Date().timeIntervalSince(t0) * 1000
    }

    private func drawHeader(_ l: JLine, _ r: NSRect, sticky: Bool) {
        let chunk = l.kind == .chunk
        if sticky {
            PK.paper.setFill(); r.fill()
            PK.paper.withAlphaComponent(0).setFill()
        }
        let x = CGFloat(JournalLayout.pad) + 2
        let tf = chunk ? PK.text(18, .medium) : PK.text(13.5, .semibold)
        let sf = PK.num(chunk ? 12 : 11.5)
        let mid = r.minY + (chunk ? r.height * 0.58 : r.height / 2)
        TapeDraw.glyph(l.open ? "chevron-down" : "chevron-right", NSRect(x: x - 2, y: mid - 7, width: 14, height: 14), color: PK.faint)
        let ta = TapeDraw.at(tf, chunk ? PK.ink : PK.muted), tw = TapeDraw.width(l.title, ta)
        TapeDraw.line(l.title, NSRect(x: x + 18, y: TapeDraw.lineTop(tf, mid: mid), width: min(tw, r.width - 140), height: tf.ascender - tf.descender + 2), ta)
        TapeDraw.line(l.sub, NSRect(x: x + 18 + tw + 12, y: TapeDraw.lineTop(sf, mid: mid), width: max(0, r.width - tw - 70), height: 18), TapeDraw.at(sf, PK.faint))
        if snap.chosen == l.id { ring(NSRect(x: x - 8, y: mid - 14, width: tw + 34, height: 28)) }
    }

    private func drawPart(_ l: JLine, _ r: NSRect) {
        let f = PK.text(11.5, .medium)
        TapeDraw.line(l.title, NSRect(x: CGFloat(JournalLayout.pad) + 20, y: TapeDraw.lineTop(f, mid: r.midY), width: r.width - 60, height: 16), TapeDraw.at(f, PK.faint))
    }

    /// A session: the app's icon, its name, the time range and how long, quiet.
    private func drawLabel(_ l: JLine, _ r: NSRect, _ m: WindowModel) {
        let x = r.minX + 4, mid = r.maxY - 14   // above the rule (5 pt over the cards)
        guard l.session >= 0, l.session < m.journal.facts.count else { return }
        // a hairless bracket: a soft line from the label to the end of its cards in this row
        drawRule(NSRect(x: r.minX, y: r.maxY - CGFloat(JournalLayout.gap) / 2 - 1, width: r.width, height: 2))
        let f = m.journal.facts[l.session]
        appIcon(f.app, NSRect(x: x, y: mid - 8, width: 16, height: 16))
        let nf = PK.text(12.5, .semibold), qf = PK.num(11.5)
        let name = f.app.isEmpty ? "Session" : f.app
        let na = TapeDraw.at(nf, PK.muted), nw = TapeDraw.width(name, na)
        let nwFit = min(nw, max(0, r.maxX - x - 30))
        TapeDraw.line(name, NSRect(x: x + 23, y: TapeDraw.lineTop(nf, mid: mid), width: nwFit, height: 18), na)
        var rest = TapeDraw.time(f.from) + "–" + TapeDraw.time(f.to)
        if f.took >= 60 { rest += " · " + TapeRules.clock(f.took) }
        TapeDraw.line(rest, NSRect(x: x + 23 + nwFit + 10, y: TapeDraw.lineTop(qf, mid: mid), width: max(0, r.maxX - x - nwFit - 40), height: 18), TapeDraw.at(qf, PK.faint))
        if snap.chosen == l.id { ring(NSRect(x: x - 6, y: mid - 13, width: nw + 40, height: 26)) }
    }

    /// The session's soft line above its cards in a row (the label's row and every further row): the same rule.
    private func drawRule(_ r: NSRect) {
        PK.rule.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 2, y: r.midY - 0.75, width: r.width - 4, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
    }

    private func ring(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r, xRadius: PK.radius("row"), yRadius: PK.radius("row"))
        p.lineWidth = 1.5; PK.blue.setStroke(); p.stroke()
    }

    private func appIcon(_ app: String, _ r: NSRect) {
        if let i = AppIcons.icon(app) { i.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        else { TapeDraw.glyph(TapeDraw.appMark(app) ?? "layers", r.insetBy(dx: 2, dy: 2), color: PK.faint) }
    }

    private func face(_ name: String) -> NSImage? {
        if let i = faces[name] { return i }
        guard let u = PK.art?.appendingPathComponent("people/\(name).png"), let i = NSImage(contentsOf: u) else { return nil }
        faces[name] = i; return i
    }

    private func drawCard(_ l: JLine, _ r: NSRect, _ m: WindowModel) {
        guard l.item >= 0, l.item < m.rows.count else { return }
        let it = m.rows[l.item]
        let chosen = snap.chosen == l.id, picked = snap.picked.contains(l.id), hovered = hover == l.id, gone = snap.gone.contains(l.id)
        let rad = PK.radius("card")
        // the selection glides from the last chosen card to this one
        var box = r
        if chosen, let g = glide {
            let d = PK.motion("fold"), k = d > 0 ? min(1, (Date().timeIntervalSince1970 - g.start) / d) : 1
            let e = CGFloat(1 - pow(1 - k, 3))
            box = NSRect(x: g.from.minX + (r.minX - g.from.minX) * e, y: g.from.minY + (r.minY - g.from.minY) * e,
                         width: g.from.width + (r.width - g.from.width) * e, height: g.from.height + (r.height - g.from.height) * e)
        }
        if chosen { lastChosenRect = r }
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: rad, yRadius: rad)
        (picked ? PK.pick : hovered ? PK.hover : PK.card).setFill(); path.fill()
        PK.line.setStroke(); path.lineWidth = 0.5; path.stroke()
        if chosen {
            let sel = NSBezierPath(roundedRect: box.insetBy(dx: -1.5, dy: -1.5), xRadius: rad + 1.5, yRadius: rad + 1.5)
            let accent = JournalMeta.outline(keys: snap.region == .list || snap.region == .peek, chosen: true).accentItem
            sel.lineWidth = accent ? 1.5 : 1.25
            (accent ? PK.blue : PK.muted.withAlphaComponent(0.55)).setStroke(); sel.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let top = CGFloat(JournalLayout.cardTop)
        let content = NSRect(x: r.minX + 12, y: r.minY + top, width: r.width - 24, height: r.height - top - Self.footH + 1)
        let bg = picked ? PK.pick : hovered ? PK.hover : PK.card
        if let d = it.doc { drawCall(it, d, content) }
        else if let e = it.entry {
            switch e.clip {
            case .image where it.kind == .copied: drawPicture(it, e, r, hovered: hovered)
            case .link where it.kind == .copied: drawLink(it, e, content)
            case .file where it.kind == .copied: drawFile(it, e, content)
            default:
                // the chips of the things in it: under the text when a row is free there, else in the foot's free room
                let chips = self.chips(it)
                let cw = chips.map { chipWidth($0) }
                let cH: CGFloat = 18
                let fit = cw.isEmpty ? (count: 0, under: false)
                    : JournalMeta.chipFit(widths: cw.map(Double.init), textHeight: Double(textNeed(it, content, mono: it.kind == .copied && JournalMeta.codeLike(it.current))),
                                          room: Double(content.height), chipH: Double(cH), rowWidth: Double(content.width), footFree: 0)
                var tr = content
                if fit.under, fit.count > 0 { tr.size.height -= cH + 4 }
                drawText(it, tr, bg: bg, mono: it.kind == .copied && JournalMeta.codeLike(it.current))
                if fit.under, fit.count > 0 { drawChips(Array(chips.prefix(fit.count)), x: content.minX, y: tr.maxY + 4, h: cH) }
                else { pendingChips = chips }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let free = drawFoot(it, NSRect(x: r.minX + 10, y: r.maxY - Self.footH, width: r.width - 20, height: Self.footH - 4), image: it.entry?.clip == .image && it.kind == .copied, hovered: hovered)
        if !pendingChips.isEmpty {   // no row under the text: the foot's free room, chips first, never over its marks
            let n = JournalMeta.chipFit(widths: pendingChips.map { Double(chipWidth($0)) }, textHeight: .infinity, room: 0, chipH: 16, rowWidth: 0,
                                        footFree: Double(free.upperBound - free.lowerBound)).count
            if n > 0 { drawChips(Array(pendingChips.prefix(n)), x: free.lowerBound, y: r.maxY - Self.footH + (Self.footH - 4) / 2 - 8, h: 16) }
            pendingChips = []
        }
        if hovered && !gone { drawActions(it, r, m) }
        if gone { PK.card.withAlphaComponent(0.6).setFill(); path.fill() }
    }

    private var textSize: CGFloat { CGFloat(JournalLayout.textSize[JournalLayout.step(size)]) }

    // MARK: things in a card (wire round): chips from the detector

    private var pendingChips: [Found] = []
    private func chips(_ it: TapeItem) -> [Found] {
        let text = it.shown.isEmpty || it.kind == .typed ? it.current : it.shown
        var h = Hasher(); h.combine(text); let sig = h.finalize()
        if let c = chipCache[it.id], c.sig == sig { return c.chips }
        let ns = text as NSString
        let window = ns.length > 4000 ? NSRange(location: 0, length: 4000) : nil
        // a thing that is most of the text (a copied command, a link) repeats the card: no chip for it
        let whole = Double(ns.length)
        let found = Detect.summary(Detect.scan(text, written: Date(timeIntervalSince1970: it.at), window: window)
            .filter { Double($0.range.length) < whole * 0.8 })
        if chipCache.count > 4000 { chipCache.removeAll() }
        chipCache[it.id] = (sig, found)
        return found
    }
    private static let chipFont = PK.text(11)
    private func chipLabel(_ f: Found) -> String { FoundRules.one(f.display.isEmpty ? f.words : f.display, 22) }
    private func chipWidth(_ f: Found) -> CGFloat { 6 + 11 + 4 + TapeDraw.width(chipLabel(f), TapeDraw.at(Self.chipFont, PK.muted)) + 7 }
    private func drawChips(_ cs: [Found], x x0: CGFloat, y: CGFloat, h: CGFloat) {
        var x = x0
        let a = TapeDraw.at(Self.chipFont, PK.muted)
        for f in cs {
            let w = chipWidth(f), box = NSRect(x: x, y: y, width: w, height: h)
            let p = NSBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), xRadius: h / 2, yRadius: h / 2)
            PK.line.setStroke(); p.lineWidth = 0.5; p.stroke()
            TapeDraw.glyph(JournalMeta.foundGlyph(f.kind.rawValue), NSRect(x: x + 6, y: box.midY - 5.5, width: 11, height: 11), color: PK.muted)
            TapeDraw.line(chipLabel(f), NSRect(x: x + 21, y: TapeDraw.lineTop(Self.chipFont, mid: box.midY), width: w - 24, height: 14), a)
            x += w + 6
        }
    }
    /// The height the card's text wants at this width (for where the chips go).
    private func textNeed(_ it: TapeItem, _ r: NSRect, mono: Bool) -> CGFloat {
        let s = (it.shown.isEmpty || it.kind == .typed ? it.current : it.shown).trimmingCharacters(in: .whitespacesAndNewlines)
        let f = mono ? PK.mono(textSize - 1) : PK.text(textSize)
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = mono ? 2 : 3; ps.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [.font: f, .paragraphStyle: ps])
            .boundingRect(with: NSSize(width: r.width, height: 10_000), options: [.usesLineFragmentOrigin]).height
    }

    private func drawText(_ it: TapeItem, _ r: NSRect, bg: NSColor, mono: Bool) {
        let full = it.shown.isEmpty || it.kind == .typed ? it.current : it.shown
        var s = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = it.entry?.incomplete == true ? "No final text" : "Empty" }
        let f = mono ? PK.mono(textSize - 1) : PK.text(textSize)
        let q = snap.query.trimmingCharacters(in: .whitespaces)
        var marks = q.isEmpty ? [] : JournalSearch.ranges(q, in: s)
        // the text window scrolls to the first match
        let room = Int(r.width / (f.pointSize * 0.5) * max(1, floor(r.height / (f.pointSize * 1.35))) * 0.6)
        let start = JournalMeta.window(s, match: marks.first?.location, room: room)
        if start > 0 {
            s = "…" + (s as NSString).substring(from: start)
            marks = marks.compactMap { $0.location >= start ? NSRange(location: $0.location - start + 1, length: $0.length) : nil }
        }
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = mono ? 2 : 3; ps.lineBreakMode = .byWordWrapping
        let a = NSMutableAttributedString(string: s, attributes: [.font: f, .foregroundColor: PK.ink, .paragraphStyle: ps])
        if !mono, start == 0, let n = JournalMeta.firstSentence(s), n <= a.length { a.addAttribute(.font, value: PK.text(textSize, .semibold), range: NSRange(location: 0, length: n)) }
        let hl = PK.series("blue").withAlphaComponent(PK.dark ? 0.38 : 0.22)
        for mk in marks where NSMaxRange(mk) <= a.length { a.addAttribute(.backgroundColor, value: hl, range: mk) }
        let need = a.boundingRect(with: NSSize(width: r.width, height: 10_000), options: [.usesLineFragmentOrigin]).height
        a.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if need > r.height + 2 {   // the bottom fades instead of cutting a line in half
            let fr = NSRect(x: r.minX - 12, y: r.maxY - 22, width: r.width + 24, height: 24)
            NSGradient(starting: bg.withAlphaComponent(0), ending: bg)?.draw(in: fr, angle: 90)
        }
    }

    private func drawLink(_ it: TapeItem, _ e: Entry, _ r: NSRect) {
        let p = ClipRules.parts(e.text)
        let mark = JournalMeta.siteMark(p.host)
        let d: CGFloat = size == 0 ? 26 : 34
        let c = NSRect(x: r.minX, y: r.minY + 2, width: d, height: d)
        let col = PK.series(["blue", "mint", "violet", "coral"][mark.series])
        col.withAlphaComponent(PK.dark ? 0.30 : 0.18).setFill(); NSBezierPath(ovalIn: c).fill()
        let lf = PK.text(d * 0.46, .semibold), la = TapeDraw.at(lf, col), lw = TapeDraw.width(mark.letter, la)
        TapeDraw.line(mark.letter, NSRect(x: c.midX - lw / 2, y: TapeDraw.lineTop(lf, mid: c.midY), width: lw + 2, height: d), la)
        let hf = PK.text(11.5)
        TapeDraw.line(p.host, NSRect(x: c.maxX + 10, y: TapeDraw.lineTop(hf, mid: c.midY), width: r.width - d - 10, height: 16), TapeDraw.at(hf, PK.muted))
        let title = e.clipTitle.isEmpty ? (p.last.isEmpty ? p.host : p.last) : e.clipTitle
        let tf = PK.text(size == 2 ? 17 : size == 0 ? 13.5 : 15.5, .semibold)
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 2
        let a = NSAttributedString(string: title, attributes: [.font: tf, .foregroundColor: PK.ink, .paragraphStyle: ps])
        a.draw(with: NSRect(x: r.minX, y: c.maxY + 10, width: r.width, height: r.maxY - c.maxY - 10), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawPicture(_ it: TapeItem, _ e: Entry, _ card: NSRect, hovered: Bool) {
        var box = NSRect(x: card.minX, y: card.minY, width: card.width, height: card.height - Self.footH)
        // a shot: its note (the card's line) and the answer's first lines under the picture; the pins are in the picture
        if let p = it.shot { box.size.height -= drawShotText(it, p, below: box) }
        if let p = it.shot, let img = ShotJournal.thumb(p.id) {
            let s = max(box.width / max(1, img.size.width), box.height / max(1, img.size.height))
            let w = img.size.width * s, h = img.size.height * s
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: box).addClip()
            img.draw(in: NSRect(x: box.midX - w / 2, y: h > box.height ? box.minY : box.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else if !e.picture.isEmpty, let img = TapeDraw.thumb(History.clipURL(e.picture), px: 720) {
            let s = max(box.width / max(1, img.size.width), box.height / max(1, img.size.height))   // fills the card
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: NSRect(x: box.midX - w / 2, y: h > box.height ? box.minY : box.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            PK.well.setFill(); box.fill()
            TapeDraw.glyph("image", NSRect(x: box.midX - 14, y: box.midY - 14, width: 28, height: 28), color: PK.faint)
        }
        // the picture's words only on hover (the reader shows them all)
        if hovered, !e.ocr.isEmpty, it.shot == nil {
            let band = NSRect(x: box.minX, y: box.maxY - 44, width: box.width, height: 44)
            NSColor.black.withAlphaComponent(0.55).setFill(); band.fill()
            let words = e.ocr.split(whereSeparator: \.isNewline).joined(separator: " ")
            let a: [NSAttributedString.Key: Any] = [.font: PK.text(11.5), .foregroundColor: NSColor.white]
            NSAttributedString(string: words, attributes: a).draw(with: band.insetBy(dx: 10, dy: 6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// A shot's words under its picture: the note (the card's line, search matches marked), then the answer's first
    /// lines in the muted ink after the sparkle (Claude answered). Draws in the bottom of `box`; returns the height
    /// it took (0 when the shot has neither).
    private func drawShotText(_ it: TapeItem, _ p: ShotPack, below box: NSRect) -> CGFloat {
        let note = ShotJournalRules.flat(p.note), ans = ShotJournalRules.answerLines(p.answer, max: 2)
        guard !note.isEmpty || !ans.isEmpty else { return 0 }
        let w = box.width - 24
        let nf = PK.text(textSize, .semibold), af = PK.text(max(11.5, textSize - 1.5))
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 2; ps.lineBreakMode = .byWordWrapping
        var na: NSMutableAttributedString?
        if !note.isEmpty {
            let a = NSMutableAttributedString(string: note, attributes: [.font: nf, .foregroundColor: PK.ink, .paragraphStyle: ps])
            let q = snap.query.trimmingCharacters(in: .whitespaces)
            let hl = PK.series("blue").withAlphaComponent(PK.dark ? 0.38 : 0.22)
            if !q.isEmpty { for mk in JournalSearch.ranges(q, in: note) where NSMaxRange(mk) <= a.length { a.addAttribute(.backgroundColor, value: hl, range: mk) } }
            na = a
        }
        let aa = ans.isEmpty ? nil : NSAttributedString(string: ans.joined(separator: " "), attributes: [.font: af, .foregroundColor: PK.muted, .paragraphStyle: ps])
        let nh = na.map { min(ceil(nf.pointSize * 1.3) * 2 + 2, ceil($0.boundingRect(with: NSSize(width: w, height: 400), options: [.usesLineFragmentOrigin]).height)) } ?? 0
        let ah = aa.map { min(ceil(af.pointSize * 1.3) * 2 + 2, ceil($0.boundingRect(with: NSSize(width: w - 18, height: 400), options: [.usesLineFragmentOrigin]).height)) } ?? 0
        let gap: CGFloat = na != nil && aa != nil ? 6 : 0
        let h = 10 + nh + gap + ah + 4
        let band = NSRect(x: box.minX, y: box.maxY - h, width: box.width, height: h)
        PK.card.setFill(); band.fill()
        PK.line.setFill(); NSRect(x: band.minX, y: band.minY, width: band.width, height: 0.5).fill()
        var y = band.minY + 10
        if let a = na { a.draw(with: NSRect(x: box.minX + 12, y: y, width: w, height: nh), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]); y += nh + gap }
        if let a = aa {
            TapeDraw.glyph("sparkle", NSRect(x: box.minX + 12, y: y + 1, width: 13, height: 13), color: PK.muted)
            a.draw(with: NSRect(x: box.minX + 30, y: y, width: w - 18, height: ah), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        return h
    }

    private func drawFile(_ it: TapeItem, _ e: Entry, _ r: NSRect) {
        let p = ClipRules.fileParts(e.text)
        let path = e.text.hasPrefix("file://") ? (URL(string: e.text)?.path ?? e.text) : e.text
        let icon: NSImage = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: (p.name as NSString).pathExtension) ?? .data)
        if r.height < 110 {   // a short card: the icon beside the name
            let d: CGFloat = 30
            icon.draw(in: NSRect(x: r.minX - 2, y: r.minY, width: d, height: d), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let nf = PK.text(size == 0 ? 13 : 13.5, .semibold)
            NSAttributedString(string: p.name, attributes: [.font: nf, .foregroundColor: PK.ink])
                .draw(with: NSRect(x: r.minX + d + 8, y: r.minY + 1, width: r.width - d - 8, height: nf.pointSize * 2.6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            let d: CGFloat = 46
            icon.draw(in: NSRect(x: r.minX - 2, y: r.minY, width: d, height: d), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let nf = PK.text(14, .semibold)
            let a = NSAttributedString(string: p.name, attributes: [.font: nf, .foregroundColor: PK.ink])
            a.draw(with: NSRect(x: r.minX, y: r.minY + d + 8, width: r.width, height: nf.pointSize * 2.6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        let rest = [e.bytes > 0 ? ClipRules.bytes(e.bytes) : "", p.folder].filter { !$0.isEmpty }.joined(separator: " · ")
        let qf = PK.num(11.5)
        TapeDraw.line(rest, NSRect(x: r.minX, y: r.maxY - 16, width: r.width, height: 16), TapeDraw.at(qf, PK.muted, cut: .byTruncatingMiddle))
    }

    private func drawCall(_ it: TapeItem, _ d: CallDoc, _ r: NSRect) {
        let tf = PK.text(size == 0 ? 13.5 : 15, .semibold)
        let title = it.shown.isEmpty ? (d.title.isEmpty ? (d.call ? "Recording" : "Voice note") : d.title) : it.shown
        let titleH = tf.pointSize * (r.height < 110 ? 1.4 : 2.7)   // a short card: one line of title
        NSAttributedString(string: title, attributes: [.font: tf, .foregroundColor: PK.ink])
            .draw(with: NSRect(x: r.minX, y: r.minY, width: r.width, height: titleH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        var y = r.minY + titleH + 4
        // the people, each a face
        var x = r.minX
        let names = ["short"] + (d.people.isEmpty ? (d.call ? ["person"] : []) : Array(repeating: "bob", count: min(3, d.people.count)))
        for n in names {
            let c = NSRect(x: x, y: y, width: 22, height: 22)
            PK.well.setFill(); NSBezierPath(ovalIn: c).fill()
            if let f = face(n) { NSGraphicsContext.saveGraphicsState(); NSBezierPath(ovalIn: c).addClip(); f.draw(in: c, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil); NSGraphicsContext.restoreGraphicsState() }
            x += 16
        }
        let lf = PK.num(12)
        let len = d.live ? "recording now" : TapeRules.clock(d.secs)
        TapeDraw.line(len, NSRect(x: x + 14, y: TapeDraw.lineTop(lf, mid: y + 11), width: 120, height: 16), TapeDraw.at(lf, d.live ? PK.coral : PK.muted))
        y += 30
        // two-tone talk bar: his side and theirs
        if d.call, d.meSecs + d.themSecs > 0 {
            let bar = NSRect(x: r.minX, y: y, width: r.width, height: 5)
            let me = CGFloat(d.meSecs / (d.meSecs + d.themSecs))
            PK.series("coral").setFill(); NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * me - 1, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            PK.rule.setFill(); NSBezierPath(roundedRect: NSRect(x: bar.minX + bar.width * me + 1, y: bar.minY, width: bar.width * (1 - me) - 1, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            y += 14
        }
        if let p = d.points.first, y < r.maxY - 14 {
            NSAttributedString(string: p, attributes: [.font: PK.text(12), .foregroundColor: PK.muted])
                .draw(with: NSRect(x: r.minX, y: y, width: r.width, height: r.maxY - y), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The foot: the kind mark, then the trail (source → where it went, or where it was written and "sent"); time
    /// and length at the right, with pinned and changed as small marks.
    /// Draws the foot line; returns its free room in x (between the left marks and the right ones), for the chips.
    @discardableResult
    private func drawFoot(_ it: TapeItem, _ r: NSRect, image: Bool, hovered: Bool = false) -> ClosedRange<CGFloat> {
        let mid = r.midY
        if image { PK.card.setFill(); NSRect(x: r.minX - 10, y: r.minY - 2, width: r.width + 20, height: r.height + 4).fill() }
        let kid = it.kindId
        let kc = PK.series(JournalMeta.series(kid))
        TapeDraw.glyph(JournalMeta.glyph(kid), NSRect(x: r.minX + 2, y: mid - 7, width: 14, height: 14), color: kc)
        var x = r.minX + 24
        let ic: CGFloat = 16
        func icon(_ app: String) { appIcon(app, NSRect(x: x, y: mid - ic / 2, width: ic, height: ic)); x += ic + 4 }
        let qf = PK.num(11), qa = TapeDraw.at(qf, PK.faint)
        // the right side first: it decides the room for the trail
        var right = r.maxX
        var parts: [String] = [TapeDraw.time(it.at)]
        if let t = it.took, t >= 1 { parts.insert(TapeRules.clock(t), at: 0) }
        for s in parts.reversed() {
            let w = TapeDraw.width(s, qa)
            TapeDraw.line(s, NSRect(x: right - w, y: TapeDraw.lineTop(qf, mid: mid), width: w + 1, height: 15), qa)
            right -= w + 8
        }
        if it.pinned { TapeDraw.glyph("pin", NSRect(x: right - 12, y: mid - 6, width: 12, height: 12), color: PK.muted); right -= 18 }
        if it.change != nil { TapeDraw.glyph("edit", NSRect(x: right - 12, y: mid - 6, width: 12, height: 12), color: PK.muted); right -= 18 }
        if it.est { TapeDraw.line("≈", NSRect(x: right - 10, y: TapeDraw.lineTop(qf, mid: mid), width: 10, height: 15), qa); right -= 14 }
        if let p = it.shot {   // a shot: its mark count in a small ring (like its pins), and a sent mark (the target's word on hover)
            if let word = ShotJournalRules.sentWord(p) {
                if hovered {
                    let w = min(140, TapeDraw.width(word, qa))
                    TapeDraw.line(word, NSRect(x: right - w, y: TapeDraw.lineTop(qf, mid: mid), width: w + 1, height: 15), TapeDraw.at(qf, PK.muted, cut: .byTruncatingMiddle)); right -= w + 4
                }
                TapeDraw.glyph("send", NSRect(x: right - 12, y: mid - 6, width: 12, height: 12), color: PK.muted); right -= 18
            }
            let pc = ShotJournalRules.pictureText(p)   // a set: how many pictures, beside an image glyph
            if !pc.isEmpty {
                let nf = PK.num(10), na = TapeDraw.at(nf, PK.muted), tw = TapeDraw.width(pc, na)
                TapeDraw.line(pc, NSRect(x: right - tw, y: TapeDraw.lineTop(nf, mid: mid), width: tw + 1, height: 14), na)
                TapeDraw.glyph("image", NSRect(x: right - tw - 15, y: mid - 6, width: 12, height: 12), color: PK.muted)
                right -= tw + 21
            }
            let n = ShotJournalRules.markText(ShotJournalRules.markCount(p))
            if !n.isEmpty {
                let nf = PK.num(10), na = TapeDraw.at(nf, PK.muted), nw = max(14, TapeDraw.width(n, na) + 7)
                let ring = NSRect(x: right - nw, y: mid - 7, width: nw, height: 14)
                let rp = NSBezierPath(roundedRect: ring, xRadius: 7, yRadius: 7); PK.muted.setStroke(); rp.lineWidth = 1; rp.stroke()
                let tw = TapeDraw.width(n, na)
                TapeDraw.line(n, NSRect(x: ring.midX - tw / 2, y: TapeDraw.lineTop(nf, mid: mid), width: tw + 1, height: 14), na)
                right -= nw + 6
            }
        }
        let room = right - 6
        switch it.kind {
        case .copied:
            if !it.app.isEmpty { icon(it.app) }
            if !it.to.isEmpty, x + 40 < room {
                TapeDraw.line("→", NSRect(x: x, y: TapeDraw.lineTop(qf, mid: mid), width: 12, height: 15), qa); x += 14
                for (n, a) in it.to.enumerated() {
                    if x + ic > room - 20, n < it.to.count - 1 { TapeDraw.line("+\(it.to.count - n)", NSRect(x: x, y: TapeDraw.lineTop(qf, mid: mid), width: 24, height: 15), qa); break }
                    icon(a)
                }
            }
        default:
            if !it.app.isEmpty { icon(it.app) }
            let sent = it.entry?.sent == true || (it.fate ?? "").hasPrefix("sent")
            if sent, x + 40 < room {
                TapeDraw.glyph("check", NSRect(x: x, y: mid - 6, width: 12, height: 12), color: PK.muted); x += 14
                TapeDraw.line("sent", NSRect(x: x, y: TapeDraw.lineTop(qf, mid: mid), width: 30, height: 15), qa); x += 32
            }
            if !it.also.isEmpty, x + 30 < room {   // merged kinds: their marks, quiet
                for a in it.also.prefix(2) {
                    TapeDraw.glyph(JournalMeta.glyph(a.kind), NSRect(x: x, y: mid - 5.5, width: 11, height: 11), color: PK.faint); x += 14
                }
            }
        }
        let lo = x + 6
        return lo <= room ? lo...room : lo...lo
    }

    /// Hover: Insert, Copy, Pin as round buttons at the card's top right.
    private func drawActions(_ it: TapeItem, _ r: NSRect, _ m: WindowModel) {
        let acts: [(String, String, () -> Void)] = [
            it.shot != nil ? ("send", "Send to… (⇥)", { [weak m] in m?.choose(it.id); m?.sendShot() })
                           : ("send", "Insert into the app you came from (⌘↵)", { [weak m] in m?.choose(it.id); m?.insert() }),
            ("copy", "Copy (⌘C)", { [weak m] in m?.choose(it.id); m?.copyItem() }),
            ("pin", it.pinned ? "Unpin (⌘P)" : "Pin (⌘P)", { [weak m] in m?.togglePin(it) }),
        ]
        var x = r.maxX - 8 - CGFloat(acts.count) * 28
        let back = NSBezierPath(roundedRect: NSRect(x: x - 4, y: r.minY + 4, width: CGFloat(acts.count) * 28 + 4, height: 32), xRadius: 16, yRadius: 16)
        PK.card.setFill(); back.fill(); PK.line.setStroke(); back.lineWidth = 0.5; back.stroke()
        for (n, a) in acts.enumerated() {
            let b = NSRect(x: x, y: r.minY + 8, width: 24, height: 24)
            let p = NSBezierPath(ovalIn: b)
            (hoverButton == n ? PK.hover : PK.card).setFill(); p.fill()
            TapeDraw.glyph(a.0, b.insetBy(dx: 5.5, dy: 5.5), color: hoverButton == n ? PK.ink : PK.muted)
            hits.append((b, a.2))
            x += 28
        }
    }
    /// The preview's hover (no mouse in a render).
    func previewHover(_ id: String?) { hover = id; hoverButton = -1; needsDisplay = true }
    static let actionTips = ["Insert into the app you came from (⌘↵)", "Copy (⌘C)", "Pin or unpin (⌘P)"]

    // MARK: mouse

    private func placedAt(_ p: NSPoint) -> Int? {
        var i = first(below: p.y)
        while i < placed.count, placed[i].rect.minY <= p.y {
            if placed[i].rect.contains(p) { return i }
            i += 1
        }
        return nil
    }
    private func lineId(_ i: Int) -> String {
        switch placed[i].block { case .card(let k), .header(let k), .label(let k), .rule(let k), .part(let k): return snap.lines[k].id }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        var h: String?, b = -1
        if let i = placedAt(p), case .card = placed[i].block { h = lineId(i) }
        if let n = hits.firstIndex(where: { $0.0.contains(p) }) { b = n }
        if h != hover || b != hoverButton {
            hover = h; hoverButton = b; needsDisplay = true
            toolTip = b >= 0 ? Self.actionTips[min(b, 2)] : h.flatMap { id in model?.item(id).map { "\($0.noun) · \(TapeView.exact($0.at)) · \($0.current.count) characters" } }
        }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; hoverButton = -1; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        guard let m = model else { return }
        window?.makeFirstResponder(nil)
        let p = convert(e.locationInWindow, from: nil)
        if let h = hits.first(where: { $0.0.contains(p) }) { h.1(); m.tapeTick += 1; return }
        guard let i = placedAt(p) else { return }
        let id = lineId(i)
        m.nav.region = .list
        switch placed[i].block {
        case .card:
            if e.modifierFlags.contains(.shift) { m.pickTo(id) }
            else if e.modifierFlags.contains(.command) {
                if m.picked.isEmpty, let c = m.current?.id { m.picked = [c] }
                if m.picked.contains(id) { m.picked.removeAll { $0 == id } } else { m.picked.append(id) }
                m.chosen = id
            } else { m.choose(id) }
            if e.clickCount == 2 { m.openOver() }
            down = (p, id)
        case .header, .label:
            m.choose(id); m.toggleFold(id)
        case .part, .rule: break
        }
        m.tapeTick += 1
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = down, let m = model, let it = m.item(d.id) else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - d.point.x, p.y - d.point.y) > 5 else { return }
        down = nil
        let ids = m.picked.contains(d.id) && m.picked.count > 1 ? m.picked : [d.id]
        m.dragIds = ids
        let pb = NSPasteboardItem()
        if let e = it.entry, it.kind == .copied, e.clip == .image, !e.picture.isEmpty { pb.setString(History.clipURL(e.picture).absoluteString, forType: .fileURL) }
        else if let e = it.entry, it.kind == .copied, e.clip == .file { pb.setString(e.text.hasPrefix("file://") ? e.text : URL(fileURLWithPath: e.text).absoluteString, forType: .fileURL) }
        pb.setString(ids.compactMap { m.item($0)?.current }.joined(separator: "\n\n"), forType: .string)
        let di = NSDraggingItem(pasteboardWriter: pb)
        let r = at[d.id].map { placed[$0].rect } ?? NSRect(origin: p, size: NSSize(width: 120, height: 60))
        let img = NSImage(size: r.size, flipped: true) { b in
            let path = NSBezierPath(roundedRect: b, xRadius: PK.radius("card"), yRadius: PK.radius("card"))
            PK.card.withAlphaComponent(0.92).setFill(); path.fill(); PK.line.setStroke(); path.stroke()
            let s = ids.count > 1 ? "\(ids.count) items" : String(it.current.prefix(120))
            NSAttributedString(string: s, attributes: [.font: PK.text(12), .foregroundColor: PK.ink]).draw(with: b.insetBy(dx: 12, dy: 10), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        di.setDraggingFrame(r, contents: img)
        beginDraggingSession(with: [di], event: e, source: self)
    }
    override func mouseUp(with e: NSEvent) { down = nil }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { c == .withinApplication ? [.copy, .move] : .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) { DispatchQueue.main.async { self.model?.dragIds = [] } }

    // a drop inside the gallery: the pinned order (display only)
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { dropOK(s) ? .move : [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { dropOK(s) ? .move : [] }
    private func dropOK(_ s: NSDraggingInfo) -> Bool { (s.draggingSource as? GalleryView) === self && model?.filter == .pinned && !(model?.dragIds.isEmpty ?? true) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard dropOK(s), let m = model else { return false }
        let p = convert(s.draggingLocation, from: nil)
        let before = placedAt(p).map(lineId)
        m.reorderPinned(m.dragIds, before: before)
        return true
    }
}
