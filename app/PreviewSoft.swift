// The soft round's renders (PREVIEW_ONLY=soft): the gallery at three sizes of window and three card sizes, a search
// with its marks, the peek, a chunk boundary with a session label, the slide-over reader, Details, Go to, hover
// actions, the soft and grid lists; then the scroll cost of the gallery with 10,000 made-up items. Made-up data only.
import AppKit
import SwiftUI

extension UIShots {
    /// Made-up records that show what the soft round adds: one text kept as a voice note and as a draft (merged into
    /// one card), a draft with an estimated start, clips pasted into other apps (the paste trail), a code clip.
    static func softExtras(_ m: WindowModel, now: Double) {
        let cal = TapeBuild.cal
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: now))
        func at(_ h: Int, _ mi: Int) -> Date { cal.date(byAdding: .minute, value: h * 60 + mi, to: today)! }
        let said = "Book the room for the Lantern review on Thursday and send Mila the agenda before noon."
        m.takes.insert(Entry(id: "sv1", when: at(12, 12), app: "Notes", text: said, audio: "/sample/take.wav", secs: 11), at: 0)
        var d = Entry(id: "sd1", when: at(12, 14), app: "Mail", text: said, audio: "", secs: 0)
        d.started = at(12, 13); d.sent = true
        m.typed.append(d)
        var est = Entry(id: "sd2", when: at(11, 51), app: "Notes", text: "Draft for the station page: what changed this week and what waits on the client", audio: "", secs: 0)
        est.started = at(11, 47); est.est = true
        m.typed.append(est)
        var code = Entry(id: "sc1", when: at(11, 44), app: "Terminal", text: "git log --oneline -8 | grep journal; swift test --filter Lantern", audio: "", secs: 0)
        code.clip = .text
        m.clips.append(code)
        var link = Entry(id: "sl1", when: at(11, 40), app: "Safari", text: "https://maps.example.net/kyiv/station-lift-plan", audio: "", secs: 0)
        link.clip = .link; link.clipTitle = "Lift plan for the station, level 2"
        m.clips.append(link)
        var file = Entry(id: "sf1", when: at(11, 39), app: "Finder", text: NSHomeDirectory() + "/Documents/Lantern/order-form-v3.key", audio: "", secs: 0)
        file.clip = .file; file.bytes = 2_840_112
        m.clips.append(file)
        m.clips.sort { $0.when > $1.when }; m.typed.sort { $0.when > $1.when }; m.takes.sort { $0.when > $1.when }
        // where the clips went: pasted into Mail and Notes, the code into Terminal, the link into Notes and Mail
        func paste(_ text: String, _ app: String, _ bundle: String, _ h: Int, _ mi: Int) -> PasteTrail.Paste {
            PasteTrail.Paste(t: at(h, mi).timeIntervalSince1970, bundle: bundle, app: app, hash: PasteTrail.hash(text))
        }
        m.previewPastes = [
            paste(code.text, "Notes", "com.apple.Notes", 11, 45), paste(code.text, "Mail", "com.apple.mail", 11, 49),
            paste(link.text, "Notes", "com.apple.Notes", 11, 41), paste(link.text, "Mail", "com.apple.mail", 11, 52),
            paste("Room 4.12, second floor, the door on the left", "Mail", "com.apple.mail", 12, 6),
            paste("Room 4.12, second floor, the door on the left", "Notes", "com.apple.Notes", 12, 8),
            paste("let share = taken / shown", "Terminal", "com.apple.Terminal", 11, 12)]
    }

    static func softShots(_ folder: String, dark: Bool) throws {
        let cal = TapeBuild.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 45))!.timeIntervalSince1970
        Entities.previewStore = sampleEntities()
        defer { Entities.previewStore = nil }
        TapeBuild.tagCache = [:]
        let m = WindowModel(); m.preview = true; m.now = now
        sampleTape(m, now: now, days: 420, perDay: 5)
        softExtras(m, now: now)
        var docs = try sampleDocs()
        docs[0].started = cal.date(bySettingHour: 11, minute: 48, second: 0, of: Date(timeIntervalSince1970: now))!
        docs[0].secs = 92 * 60 / 10
        docs[1].started = Date(timeIntervalSince1970: now - 86400 + 3600); docs[1].secs = 4 * 60 + 10
        docs[2].started = Date(timeIntervalSince1970: now - 3 * 86400)
        m.docs = docs
        m.previewPins = ["t:t6"]
        m.settings.journalView = "gallery"; m.settings.journalLook = "soft"; m.settings.cardSize = 1
        m.rebuildTape()
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(m).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func size(_ w: CGFloat, _ h: CGFloat) { host.frame = NSRect(x: 0, y: 0, width: w, height: h); m.width = w }
        size(1280, 1000)
        func shot(_ name: String, wait: Double = 0.25) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(wait)); try save(host, folder + "/" + name + ".png")
            if m.gallery, let g = m.galleryView, let clip = g.enclosingScrollView?.contentView {
                let n = g.placed.filter { if case .card = $0.block { return clip.bounds.contains($0.rect) }; return false }.count
                print("soft \(name): \(n) cards whole in view · \(g.cols) columns · draw \(String(format: "%.1f", g.drawMs)) ms")
            } else if let v = m.listView, let clip = v.enclosingScrollView?.contentView {
                let top = clip.bounds.minY, bottom = top + clip.bounds.height
                let n = v.lines.indices.filter { $0 < v.placed.count && v.lines[$0].kind == .row && v.placed[$0].y >= top && v.placed[$0].y + v.placed[$0].h <= bottom }.count
                print("soft \(name): \(n) rows whole in view")
            }
        }
        func pick(_ entry: String) {
            if let id = m.rows.first(where: { $0.entry?.id == entry || $0.id == entry || $0.id.hasSuffix(":" + entry) })?.id { m.choose(id); m.nav.region = .list; m.scrollToChosen(id) }
        }
        // the gallery, medium cards, the merged voice note chosen
        pick("sv1"); try shot("gallery-1280", wait: 0.5)
        m.galleryView?.previewHover(m.chosen); try shot("gallery-hover"); m.galleryView?.previewHover(nil)
        size(900, 700); pick("sv1"); try shot("gallery-900")
        size(560, 640); pick("sv1"); try shot("gallery-560")
        size(1280, 1000)
        m.setCardSize(-1); try shot("gallery-small"); m.setCardSize(2); try shot("gallery-large"); m.setCardSize(-1)
        // a search: matches marked in the cards, the chips and the suggestion row
        m.query = "station yesterday"; try shot("gallery-search", wait: 0.4)
        m.query = "lantern"; try shot("gallery-search-2", wait: 0.4)
        m.query = ""
        // the peek
        pick("c1"); m.openPeek(); try shot("gallery-peek"); m.closePeek()
        // a chunk boundary with a session label: yesterday's chunk at the top, today's last cards above it
        if let y = m.lines.first(where: { $0.kind == .chunk && $0.id != m.lines.first?.id }) {
            m.choose(y.id); m.galleryView?.scrollTo(y.id)
            if let clip = m.galleryView?.enclosingScrollView?.contentView { clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 260))) }
        }
        try shot("gallery-chunk")
        // the reader: docked, Details open (the merged voice note: its other record)
        m.galleryReader = true; pick("sv1"); m.detailsOpen = true; try shot("gallery-reader-details", wait: 0.4)
        m.galleryReader = nil; m.detailsOpen = false
        // the slide-over at 900
        size(900, 700); pick("t1"); m.openOver(); try shot("gallery-over-900", wait: 0.4); m.closeOver(); size(1280, 1000)
        // Go to
        m.openPalette(); m.palette = "last tue"; try shot("goto-palette", wait: 0.3); m.palette = "12 березня"; try shot("goto-palette-uk", wait: 0.3); m.closePalette()
        // the list, soft and grid
        m.setView("list"); pick("sv1"); try shot("list-soft-1280", wait: 0.4)
        m.listView?.previewHover(m.chosen); try shot("list-soft-hover"); m.listView?.previewHover(nil)
        size(620, 640); try shot("list-soft-620"); size(1280, 1000)
        m.settings.journalLook = "grid"; m.tapeTick += 1; try shot("list-grid-1280", wait: 0.4)
        m.settings.journalLook = "soft"; m.setView("gallery")
        try galleryCost(now: now, docs: docs)
    }

    /// The scroll cost: 10,000 made-up items (with pictures), laid out once, then the visible cards drawn at 40 places.
    static func galleryCost(now: Double, docs: [CallDoc]) throws {
        let big = WindowModel(); big.preview = true; big.now = now
        sampleTape(big, now: now, days: 1400, perDay: 15)
        if let p = try? Quick.samplePicture() {   // every fifth clip a picture
            for i in big.clips.indices where i % 5 == 0 { big.clips[i].clip = .image; big.clips[i].picture = p.name; big.clips[i].bytes = p.bytes; big.clips[i].ocr = p.ocr }
        }
        big.docs = docs
        big.settings.journalView = "gallery"; big.settings.journalFold = "none"
        TapeBuild.tagCache = [:]
        big.rebuildTape()
        for _ in 0..<6 {   // every chunk, month and day unfolded: all the cards on one page
            let shut = big.lines.filter { $0.foldable && !$0.open }
            if shut.isEmpty { break }
            for l in shut { big.opens[l.id] = true }
            big.reflow()
        }
        let g = GalleryView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900)); sv.documentView = g; g.model = big; big.galleryView = g
        let t0 = Date(); g.apply(big.snap, size: 1); let lay = Date().timeIntervalSince(t0) * 1000
        var draws: [Double] = []
        let steps = 40
        for k in 0..<steps {
            let y = (g.frame.height - 900) * CGFloat(k) / CGFloat(steps - 1)
            sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            let r = sv.contentView.documentVisibleRect
            guard let rep = g.bitmapImageRepForCachingDisplay(in: r) else { continue }
            let t = Date(); g.cacheDisplay(in: r, to: rep); draws.append(Date().timeIntervalSince(t) * 1000)
        }
        let p95 = draws.sorted()[Int(Double(draws.count) * 0.95)]
        draws.sort()
        let cards = big.lines.filter { $0.kind == .row }.count
        print(String(format: "gallery cost: %d items, %d cards laid out in %.0f ms, page %.0f pt; draw in view median %.1f ms, 95th %.1f ms, slowest %.1f ms (%d places, the first decodes the pictures)",
                     big.rows.count, cards, lay, g.frame.height, draws.isEmpty ? 0 : draws[draws.count / 2], p95, draws.last ?? 0, draws.count))
    }
}
