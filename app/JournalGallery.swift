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
        // native scrolling: momentum and elastic edges, even when the page is shorter than the window
        s.verticalScrollElasticity = .allowed; s.horizontalScrollElasticity = .none
        let v = GalleryView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v.model = m; v.autoresizingMask = [.width]
        s.documentView = v
        m.galleryView = v
        // the chunk at the top: a floating view of its own, so a scroll moves the drawn page and redraws nothing
        // (native round: every scroll step redrew every card in view)
        let head = GalleryStickyHead(frame: NSRect(x: 0, y: 0, width: 600, height: GalleryView.chunkH))
        head.gallery = v; head.autoresizingMask = [.width]; head.isHidden = true
        s.addFloatingSubview(head, for: .vertical)
        v.sticky = head
        s.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: s.contentView, queue: .main) { [weak v] _ in
            v?.scrolled(); v?.reportChunk()
        }
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        guard let v = s.documentView as? GalleryView else { return }
        m.galleryView = v
        let w = s.contentView.bounds.width
        if v.frame.width != w, w > 0 { v.setFrameSize(NSSize(width: w, height: v.frame.height)) }
        let snap = m.snap, level = m.galleryLevel
        if snap != v.snap || v.level != level || v.laidWidth != v.bounds.width { v.apply(snap, level: level) }
    }
}

/// The chunk header held at the top of the gallery while its cards scroll under it (a floating subview).
final class GalleryStickyHead: NSView {
    weak var gallery: GalleryView?
    var line: Int?
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        guard let g = gallery, let k = line, k < g.snap.lines.count else { return }
        g.drawSticky(g.snap.lines[k], bounds)
    }
    override func mouseDown(with e: NSEvent) {
        guard let g = gallery, let k = line, k < g.snap.lines.count, let m = g.model else { return }
        let id = g.snap.lines[k].id
        m.choose(id); m.toggleFold(id)
    }
}

final class GalleryView: NSView, NSDraggingSource {
    weak var model: WindowModel?
    var snap = TapeSnap()
    var level = GalleryZoom.Level.medium
    var size: Int { level.cardSize ?? 0 }
    var laidWidth: CGFloat = -1
    weak var sticky: GalleryStickyHead?
    /// The page's running lowest edge: blocks share a row top but not a height, so the search for the first block in
    /// view goes by the lowest edge so far, which only grows.
    private var reach: [CGFloat] = []
    /// Days level: each day's start and its items (indices in the model's rows), newest first.
    private(set) var days: [(start: Double, items: [Int])] = []
    private var heights: [Int: CGFloat] = [:]          // measured text heights (text, font, width)
    private var summaries: [String: String] = [:]      // one-line summaries by item or day
    private var pinch = GalleryZoom.Pinch()
    private var pendingZoom: (pointer: NSPoint, top: CGFloat, at: Double?, id: String?, old: NSRect?, image: NSImage?, nearer: Bool)?
    private var pop: NSPopover?
    private var popFor: String?
    private var popWork: DispatchWorkItem?
    override var isFlipped: Bool { true }

    enum Block { case header(Int), label(Int), rule(Int), part(Int), card(Int), day(Int) }
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

    func apply(_ s: TapeSnap, level: GalleryZoom.Level) {
        let zoomed = level != self.level
        let again = s.lines != snap.lines || s.build != snap.build || zoomed || laidWidth != bounds.width
        let oldChosen = snap.chosen
        // no jump when new content comes in: the first card in view keeps its place on the screen
        let keep = again && !zoomed ? firstInView() : nil
        snap = s; self.level = level
        if again { relayout() }
        if zoomed { finishZoom() } else if let k = keep { hold(k) }
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
        let lines = level == .lines
        cols = lines ? Swift.max(1, Swift.min(8, Int(((w - 2 * JournalLayout.pad + JournalLayout.gap) / (GalleryZoom.lineCardMin + JournalLayout.gap)).rounded(.down))))
                     : JournalLayout.columns(width: w, size: size)
        m.galleryCols = cols
        let cw = CGFloat(JournalLayout.cardWidth(width: w, cols: cols))
        let gap = CGFloat(JournalLayout.gap), pad = CGFloat(JournalLayout.pad)
        var out: [Placed] = [], map: [String: Int] = [:]
        out.reserveCapacity(snap.lines.count)
        var y: CGFloat = 6
        if level == .days { layoutDays(m, pad: pad, gap: gap); return }
        // a run: the sessions and single items between two headers, packed into the grid without gaps; a session's
        // label sits in a strip above the grid row where its first card is, as wide as its cards in that row
        var run: [(line: Int, label: Bool)] = []
        func flush() {
            guard !run.isEmpty else { return }
            var cards: [Int] = [], labels: [(line: Int, first: Int, count: Int)] = []
            var open: Int?   // the label whose cards are being counted
            for e in run {
                if e.label { if !lines { labels.append((e.line, cards.count, 0)); open = labels.count - 1 } }
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
                // each card as tall as its content (native round: one height for all left tall empty cards and cut
                // others off); a row's cards share its top
                var rowH: CGFloat = 0
                for k in (r * cols)..<min(cards.count, (r + 1) * cols) {
                    let l = cards[k]
                    let ch = lines ? CGFloat(GalleryZoom.lineCardH) : cardHeight(m, snap.lines[l], width: cw)
                    let rect = NSRect(x: pad + CGFloat(k % cols) * (cw + gap), y: y, width: cw, height: ch)
                    map[snap.lines[l].id] = out.count; out.append(Placed(block: .card(l), rect: rect))
                    rowH = Swift.max(rowH, ch)
                }
                y += rowH + gap
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
        finish(out, map, bottom: y + pad)
    }

    private func finish(_ out: [Placed], _ map: [String: Int], bottom: CGFloat) {
        placed = out; at = map
        var r: [CGFloat] = [], lo: CGFloat = 0
        r.reserveCapacity(out.count)
        for p in out { lo = Swift.max(lo, p.rect.maxY); r.append(lo) }
        reach = r
        let h = max(bottom, enclosingScrollView?.contentView.bounds.height ?? 0)
        if frame.height != h { setFrameSize(NSSize(width: bounds.width, height: h)) }
    }

    /// The days level: one row per day, over every item the search and the filter leave (folded chunks too).
    private func layoutDays(_ m: WindowModel, pad: CGFloat, gap: CGFloat) {
        let cal = TapeBuild.cal
        let vis = m.outline.vis
        var out: [Placed] = [], ds: [(start: Double, items: [Int])] = []
        var y: CGFloat = 6
        for i in m.rows.indices where i < vis.count && vis[i] {
            let start = cal.startOfDay(for: Date(timeIntervalSince1970: m.rows[i].at)).timeIntervalSince1970
            if let l = ds.last, l.start == start { ds[ds.count - 1].items.append(i) } else { ds.append((start, [i])) }
        }
        for k in ds.indices {
            out.append(Placed(block: .day(k), rect: NSRect(x: pad, y: y, width: bounds.width - 2 * pad, height: CGFloat(GalleryZoom.dayRowH))))
            y += CGFloat(GalleryZoom.dayRowH) + gap / 2
        }
        days = ds
        finish(out, [:], bottom: y + pad)
    }

    // MARK: card heights

    /// A text's height at a width, measured once (the same attributes the card draws with).
    private func measure(_ a: NSAttributedString, _ w: CGFloat) -> CGFloat {
        guard a.length > 0 else { return 0 }
        var h = Hasher(); h.combine(a.string); h.combine(Int(w)); h.combine(size)
        if let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { h.combine(f.fontName); h.combine(f.pointSize) }
        let key = h.finalize()
        if let v = heights[key] { return v }
        let v = ceil(a.boundingRect(with: NSSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin]).height)
        if heights.count > 20_000 { heights.removeAll() }
        heights[key] = v
        return v
    }

    /// A card's height from what it shows, between a floor of two text lines and a ceiling per size (5, 8, 12 lines).
    private func cardHeight(_ m: WindowModel, _ l: JLine, width cw: CGFloat) -> CGFloat {
        let s = JournalLayout.step(size)
        let fixed = CGFloat(JournalLayout.cardHeight[s])
        guard l.item >= 0, l.item < m.rows.count else { return fixed }
        let it = m.rows[l.item]
        let top = JournalLayout.cardTop, foot = Double(Self.footH) - 1
        let lh = JournalLayout.lineHeight(s), w = cw - 24
        let floor = lh * 2, ceiling = lh * [5, 8, 12][s]
        func fit(_ c: CGFloat, max: Double = ceiling) -> CGFloat { CGFloat(GalleryZoom.fit(content: Double(c), top: top, foot: foot, minContent: floor, maxContent: max)) }
        if let d = it.doc {
            var c = callTitleH(it, d, w) + 4 + 30
            if d.call, d.meSecs + d.themSecs > 0 { c += 14 }
            if let p = d.points.first { c += Swift.min(measure(NSAttributedString(string: p, attributes: [.font: PK.text(12)]), w), ceil(12 * 1.3 * 2 + 2)) }
            return fit(c, max: ceiling + 40)
        }
        guard let e = it.entry else { return fixed }
        switch e.clip {
        case .image where it.kind == .copied: return fixed
        case .file where it.kind == .copied: return size == 0 ? fixed : fit(46 + 8 + 14 * 2.6 + 20)
        case .link where it.kind == .copied:
            let d: CGFloat = size == 0 ? 26 : 34
            return fit(2 + d + 10 + Swift.min(measure(linkTitle(it, e), w), ceil(linkFont.pointSize * 1.3 * 3)))
        default:
            // a text far longer than the ceiling holds is not measured: it takes the ceiling (and fades at its foot);
            // the chips go under the text when it leaves room, else into the foot (the detector runs only to draw)
            let full = it.shown.isEmpty || it.kind == .typed ? it.current : it.shown
            let perLine = Double(w) / (JournalLayout.textSize[s] * 0.62)
            if Double(full.utf16.count) > perLine * (ceiling / lh) * 1.6 { return fit(CGFloat(ceiling)) }
            let mono = it.kind == .copied && JournalMeta.codeLike(it.current)
            return fit(measure(textAttr(it, mono: mono), w))
        }
    }

    override func setFrameSize(_ s: NSSize) {
        let wChanged = s.width != frame.width
        super.setFrameSize(s)
        if wChanged, model != nil { relayout(); needsDisplay = true }
    }

    /// The first placed block whose bottom is below `y` (binary search: the blocks go down the page in order).
    private func first(below y: CGFloat) -> Int {
        var lo = 0, hi = reach.count
        while lo < hi { let mid = (lo + hi) / 2; if reach[mid] < y { lo = mid + 1 } else { hi = mid } }
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

    /// A scroll step: only the floating header may change (which chunk, pushed up by the next one); the page itself
    /// is moved, not drawn again.
    func scrolled() {
        if pop != nil { closePop() }
        guard let head = sticky else { return }
        let vis = visibleRect
        var line: Int?, y: CGFloat = 0
        if level != .days, let k = chunkAbove(vis.minY), let pi = at[snap.lines[k].id], placed[pi].rect.minY < vis.minY {
            line = k
            if let next = placed[(pi + 1)...].first(where: { if case .header(let j) = $0.block { return snap.lines[j].kind == .chunk }; return false }),
               next.rect.minY < vis.minY + Self.chunkH { y = next.rect.minY - vis.minY - Self.chunkH }   // the next chunk pushes it up
        }
        let frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.chunkH)
        if head.line != line || head.frame != frame || head.isHidden != (line == nil) {
            let redraw = head.line != line
            head.line = line; head.isHidden = line == nil; head.frame = frame
            if redraw { head.needsDisplay = true }
        }
    }

    /// The first card in view and its distance from the top (for `hold`).
    private func firstInView() -> (id: String, dy: CGFloat)? {
        let vis = visibleRect
        guard vis.minY > 0 else { return nil }
        var i = first(below: vis.minY)
        while i < placed.count, placed[i].rect.minY <= vis.maxY {
            if case .card = placed[i].block, placed[i].rect.minY >= vis.minY - 1 { return (lineId(i), placed[i].rect.minY - vis.minY) }
            i += 1
        }
        return nil
    }
    private func hold(_ k: (id: String, dy: CGFloat)) {
        guard let i = at[k.id], let clip = enclosingScrollView?.contentView else { return }
        let y = max(0, min(placed[i].rect.minY - k.dy, frame.height - clip.bounds.height))
        if abs(y - clip.bounds.minY) > 0.5 { clip.scroll(to: NSPoint(x: 0, y: y)); enclosingScrollView?.reflectScrolledClipView(clip) }
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
                case .day(let k): drawDay(k, p.rect, m)
                }
            }
            i += 1
        }
        drawMs = Date().timeIntervalSince(t0) * 1000
    }

    /// The floating header's drawing (GalleryStickyHead), in its own bounds.
    func drawSticky(_ l: JLine, _ r: NSRect) { drawHeader(l, r, sticky: true) }

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
        if level == .lines { drawLineCard(it, r, chosen: chosen, picked: picked, hovered: hovered, gone: gone); return }
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
    private func textNeed(_ it: TapeItem, _ r: NSRect, mono: Bool) -> CGFloat { measure(textAttr(it, mono: mono), r.width) }

    /// A text card's words as drawn (no search marks): the first sentence semibold.
    private func textAttr(_ it: TapeItem, mono: Bool) -> NSAttributedString {
        let full = it.shown.isEmpty || it.kind == .typed ? it.current : it.shown
        var s = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = it.entry?.incomplete == true ? "No final text" : "Empty" }
        let f = mono ? PK.mono(textSize - 1) : PK.text(textSize)
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = mono ? 2 : 3; ps.lineBreakMode = .byWordWrapping
        let a = NSMutableAttributedString(string: s, attributes: [.font: f, .foregroundColor: PK.ink, .paragraphStyle: ps])
        if !mono, let n = JournalMeta.firstSentence(s), n <= a.length { a.addAttribute(.font, value: PK.text(textSize, .semibold), range: NSRange(location: 0, length: n)) }
        return a
    }
    private var linkFont: NSFont { PK.text(size == 2 ? 17 : size == 0 ? 13.5 : 15.5, .semibold) }
    private func linkTitle(_ it: TapeItem, _ e: Entry) -> NSAttributedString {
        let p = ClipRules.parts(e.text)
        let title = e.clipTitle.isEmpty ? (p.last.isEmpty ? p.host : p.last) : e.clipTitle
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 2
        return NSAttributedString(string: title, attributes: [.font: linkFont, .foregroundColor: PK.ink, .paragraphStyle: ps])
    }
    /// A recording card's title: up to two lines.
    private func callTitleH(_ it: TapeItem, _ d: CallDoc, _ w: CGFloat) -> CGFloat {
        let tf = PK.text(size == 0 ? 13.5 : 15, .semibold)
        let title = it.shown.isEmpty ? (d.title.isEmpty ? (d.call ? "Recording" : "Voice note") : d.title) : it.shown
        return Swift.min(measure(NSAttributedString(string: title, attributes: [.font: tf]), w), ceil(tf.pointSize * 2.7))
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
        let need = start > 0 || !marks.isEmpty ? a.boundingRect(with: NSSize(width: r.width, height: 10_000), options: [.usesLineFragmentOrigin]).height
                                               : measure(a, r.width)
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
        let a = linkTitle(it, e)
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
        let titleH = callTitleH(it, d, r.width)
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

    // MARK: zoomed out: lines and days

    private func summary(_ it: TapeItem) -> String {
        let key = it.id + "|\(it.current.count)"
        if let s = summaries[key] { return s }
        var s = GalleryZoom.summary(it.doc.map { d in d.title.isEmpty ? (d.points.first ?? "") : d.title } ?? (it.shown.isEmpty || it.kind == .typed ? it.current : it.shown))
        if s.isEmpty { s = it.noun }
        if summaries.count > 20_000 { summaries.removeAll() }
        summaries[key] = s
        return s
    }

    /// A small card: the kind mark and one line of summary; the app and the time under it.
    private func drawLineCard(_ it: TapeItem, _ r: NSRect, chosen: Bool, picked: Bool, hovered: Bool, gone: Bool) {
        let rad = PK.radius("card")
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: rad, yRadius: rad)
        (picked ? PK.pick : hovered ? PK.hover : PK.card).setFill(); path.fill()
        PK.line.setStroke(); path.lineWidth = 0.5; path.stroke()
        if chosen {
            let sel = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: rad + 1.5, yRadius: rad + 1.5)
            sel.lineWidth = 1.5; PK.blue.setStroke(); sel.stroke()
        }
        let kid = it.kindId
        TapeDraw.glyph(JournalMeta.glyph(kid), NSRect(x: r.minX + 10, y: r.minY + 9, width: 13, height: 13), color: PK.series(JournalMeta.series(kid)))
        let tf = PK.text(12.5, .medium)
        TapeDraw.line(summary(it), NSRect(x: r.minX + 30, y: r.minY + 7, width: r.width - 40, height: 17), TapeDraw.at(tf, PK.ink))
        let qf = PK.num(11), qa = TapeDraw.at(qf, PK.faint)
        let time = TapeDraw.time(it.at), tw = TapeDraw.width(time, qa)
        TapeDraw.line(time, NSRect(x: r.maxX - 10 - tw, y: r.maxY - 21, width: tw + 1, height: 15), qa)
        if !it.app.isEmpty {
            appIcon(it.app, NSRect(x: r.minX + 30, y: r.maxY - 21, width: 14, height: 14))
            TapeDraw.line(it.app, NSRect(x: r.minX + 49, y: r.maxY - 21, width: max(0, r.width - 70 - tw), height: 15), qa)
        }
        if gone { PK.card.withAlphaComponent(0.6).setFill(); path.fill() }
    }

    /// One day: its date and count, a mark per kind with its count, and one line of what happened.
    private func drawDay(_ k: Int, _ r: NSRect, _ m: WindowModel) {
        guard k < days.count else { return }
        let d = days[k], hovered = hover == "day:\(k)"
        let rad = PK.radius("card")
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: rad, yRadius: rad)
        (hovered ? PK.hover : PK.card).setFill(); path.fill()
        PK.line.setStroke(); path.lineWidth = 0.5; path.stroke()
        let title = Self.dayTitle.string(from: Date(timeIntervalSince1970: d.start))
        let tf = PK.text(13, .semibold), ta = TapeDraw.at(tf, PK.ink)
        TapeDraw.line(title, NSRect(x: r.minX + 14, y: r.minY + 9, width: 150, height: 18), ta)
        let n = "\(d.items.count) " + (d.items.count == 1 ? "item" : "items")
        let qf = PK.num(11), qa = TapeDraw.at(qf, PK.faint)
        TapeDraw.line(n, NSRect(x: r.minX + 14, y: r.minY + 31, width: 150, height: 15), qa)
        // the kinds with their counts, then the summary
        var count: [String: Int] = [:], order: [String] = []
        for i in d.items where i < m.rows.count { let id = m.rows[i].kindId; if count[id] == nil { order.append(id) }; count[id, default: 0] += 1 }
        var x = r.minX + 170
        for id in order.prefix(5) {
            TapeDraw.glyph(JournalMeta.glyph(id), NSRect(x: x, y: r.minY + 11, width: 13, height: 13), color: PK.series(JournalMeta.series(id)))
            let s = "\(count[id] ?? 0)", w = TapeDraw.width(s, qa)
            TapeDraw.line(s, NSRect(x: x + 16, y: r.minY + 10, width: w + 1, height: 15), qa)
            x += 16 + w + 12
        }
        let key = "day:\(d.start)|\(d.items.count)"
        let line: String
        if let s = summaries[key] { line = s } else {
            line = GalleryZoom.day(d.items.prefix(40).compactMap { $0 < m.rows.count ? summary(m.rows[$0]) : nil }, max: 220)
            summaries[key] = line
        }
        TapeDraw.line(line, NSRect(x: r.minX + 170, y: r.minY + 31, width: r.width - 184, height: 16), TapeDraw.at(PK.text(12.5), PK.muted))
    }
    static let dayTitle: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy"); return f }()

    // MARK: zoom (GalleryZoom: pinch, ⌘+ ⌘-)

    override func magnify(with e: NSEvent) {
        if e.phase == .began || e.phase == .mayBegin { pinch = GalleryZoom.Pinch() }
        let n = pinch.add(Double(e.magnification))
        if n != 0 { model?.zoomGallery(n, at: convert(e.locationInWindow, from: nil)) }
    }

    /// Before a step: what is under the pointer (or the chosen card, or the first in view), and a picture of the
    /// page as it is, for the cross-fade.
    func prepareZoom(at point: NSPoint?, nearer: Bool) {
        closePop()
        let vis = visibleRect
        let p = point.flatMap { vis.contains($0) ? $0 : nil } ?? NSPoint(x: vis.midX, y: vis.midY)
        var i = placedAt(p)
        if i == nil, let c = snap.chosen, let k = at[c], placed[k].rect.intersects(vis) { i = k }
        if i == nil { var k = first(below: vis.minY); while k < placed.count, placed[k].rect.maxY < vis.minY { k += 1 }; i = k < placed.count ? k : nil }
        var t: Double?, id: String?
        if let i, let m = model {
            switch placed[i].block {
            case .card(let l): let it = snap.lines[l].item; if it >= 0, it < m.rows.count { t = m.rows[it].at; id = snap.lines[l].id }
            case .day(let k): if k < days.count, let f = days[k].items.first, f < m.rows.count { t = m.rows[f].at; id = m.rows[f].id }
            default: id = lineId(i)
            }
        }
        var img: NSImage?
        if window != nil, vis.width > 0, vis.height > 0, let rep = bitmapImageRepForCachingDisplay(in: vis) {
            cacheDisplay(in: vis, to: rep); img = NSImage(size: vis.size); img?.addRepresentation(rep)
        }
        pendingZoom = (p, vis.minY, t, id, i.map { placed[$0].rect }, img, nearer)
    }

    /// After a step: the same thing under the pointer, the old page fading (and growing or shrinking about the
    /// pointer) over the new one; with Reduce Motion, a short fade only.
    private func finishZoom() {
        guard let z = pendingZoom, let sv = enclosingScrollView else { pendingZoom = nil; scrolled(); return }
        pendingZoom = nil
        let clip = sv.contentView
        var target: Int?
        if let id = z.id, let i = at[id] { target = i }
        else if let t = z.at, let m = model {
            if level == .days { target = placed.firstIndex { if case .day(let k) = $0.block { return k < days.count && t >= days[k].start && t < days[k].start + 86_400 }; return false } }
            else {   // the card nearest in time
                var best: (i: Int, dt: Double)?
                for (i, p) in placed.enumerated() {
                    guard case .card(let l) = p.block, snap.lines[l].item >= 0, snap.lines[l].item < m.rows.count else { continue }
                    let dt = abs(m.rows[snap.lines[l].item].at - t)
                    if best == nil || dt < best!.dt { best = (i, dt) }
                }
                target = best?.i
            }
        }
        if let i = target {
            let r = placed[i].rect, old = z.old ?? r
            let y = GalleryZoom.anchor(pointer: Double(z.pointer.y), top: Double(z.top), old: (Double(old.minY), Double(old.height)), new: (Double(r.minY), Double(r.height)),
                                       page: Double(frame.height), view: Double(clip.bounds.height))
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(y))); sv.reflectScrolledClipView(clip)
        }
        scrolled(); reportChunk()
        guard let img = z.image, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cover = NSView(frame: clip.frame); cover.wantsLayer = true
        sv.addSubview(cover, positioned: .above, relativeTo: nil)
        let layer = CALayer(); layer.contents = cg; layer.contentsGravity = .resize
        let w = clip.frame.width, h = clip.frame.height
        let px = z.pointer.x, py = z.pointer.y - z.top   // in the visible page, from its top
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layer.anchorPoint = CGPoint(x: px / max(1, w), y: 1 - py / max(1, h))
        layer.position = CGPoint(x: px, y: h - py)
        cover.layer?.addSublayer(layer)
        CATransaction.begin()
        CATransaction.setAnimationDuration(still ? 0.12 : 0.24)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { cover.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        layer.add(fade, forKey: "fade"); layer.opacity = 0
        if !still {
            let s: CGFloat = z.nearer ? 1.12 : 0.9
            let grow = CABasicAnimation(keyPath: "transform"); grow.fromValue = CATransform3DIdentity; grow.toValue = CATransform3DMakeScale(s, s, 1)
            layer.add(grow, forKey: "grow"); layer.transform = CATransform3DMakeScale(s, s, 1)
        }
        CATransaction.commit()
    }

    // MARK: the summary on hover (zoomed out)

    private func hoverRect(_ id: String?) -> NSRect? {
        guard let id else { return nil }
        if id.hasPrefix("day:"), let k = Int(id.dropFirst(4)) { return placed.first { if case .day(let j) = $0.block { return j == k }; return false }?.rect }
        return at[id].map { placed[$0].rect }
    }
    private func closePop() { popWork?.cancel(); popWork = nil; pop?.close(); pop = nil; popFor = nil }
    /// Zoomed out, a card or a day the pointer rests on shows its summary in a small popover; moving off closes it.
    private func hoverPop(_ id: String?) {
        guard level < .small else { closePop(); return }
        if id == popFor, id != nil { return }
        closePop()
        guard let id, let m = model else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hover == id, let r = self.hoverRect(id), self.visibleRect.intersects(r) else { return }
            let (head, lines) = self.hoverText(id, m)
            let p = NSPopover()
            p.behavior = .applicationDefined
            p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            p.contentViewController = NSHostingController(rootView: HoverSummary(head: head, lines: lines))
            p.show(relativeTo: r, of: self, preferredEdge: .maxY)
            self.pop = p; self.popFor = id
        }
        popWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    /// What the hover summary says: for a day, its first 8 items with their times; for a card, its line.
    func hoverText(_ id: String, _ m: WindowModel) -> (String, [String]) {
        var head = "", lines: [String] = []
        if id.hasPrefix("day:"), let k = Int(id.dropFirst(4)), k < days.count {
            let d = days[k]
            head = Self.dayTitle.string(from: Date(timeIntervalSince1970: d.start)) + " · \(d.items.count) " + (d.items.count == 1 ? "item" : "items")
            for i in d.items.prefix(8) where i < m.rows.count { lines.append(TapeDraw.time(m.rows[i].at) + "  " + summary(m.rows[i])) }
            if d.items.count > 8 { lines.append("and \(d.items.count - 8) more") }
        } else if let it = m.item(id) {
            head = it.noun + " · " + TapeView.exact(it.at) + (it.app.isEmpty ? "" : " · " + it.app)
            lines = [GalleryZoom.summary(it.doc?.points.first ?? (it.shown.isEmpty || it.kind == .typed ? it.current : it.shown), max: 280)]
        }
        return (head, lines)
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
        switch placed[i].block {
        case .card(let k), .header(let k), .label(let k), .rule(let k), .part(let k): return snap.lines[k].id
        case .day(let k): return "day:\(k)"
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        var h: String?, b = -1
        if let i = placedAt(p) { switch placed[i].block { case .card, .day: h = lineId(i); default: break } }
        if let n = hits.firstIndex(where: { $0.0.contains(p) }) { b = n }
        if h != hover || b != hoverButton {
            // only the cards whose look changes are drawn again
            for r in [hoverRect(hover), hoverRect(h)].compactMap({ $0 }) { setNeedsDisplay(r.insetBy(dx: -3, dy: -3)) }
            if h != hover { hoverPop(h) }
            hover = h; hoverButton = b
            if level < .small { toolTip = nil; return }
            toolTip = b >= 0 ? Self.actionTips[min(b, 2)] : h.flatMap { id in model?.item(id).map { "\($0.noun) · \(TapeView.exact($0.at)) · \($0.current.count) characters" } }
        }
    }
    override func mouseExited(with e: NSEvent) {
        if let r = hoverRect(hover) { setNeedsDisplay(r.insetBy(dx: -3, dy: -3)) }
        hover = nil; hoverButton = -1; closePop()
    }

    override func mouseDown(with e: NSEvent) {
        guard let m = model else { return }
        window?.makeFirstResponder(nil)
        closePop()
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
        case .day(let k):   // a day: its cards, the first of them under the pointer
            if k < days.count, let f = days[k].items.first, f < m.rows.count { m.choose(m.rows[f].id) }
            m.zoomGallery(1, at: p)
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

/// The summary a zoomed-out card or day shows on hover: system type, the popover's own material.
struct HoverSummary: View {
    let head: String
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(head).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(width: 320, alignment: .leading)
    }
}
