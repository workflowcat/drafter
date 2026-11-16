// The window's speed on made-up data (native round, 16 November 2026): what he feels, timed on the main thread with
// the real WindowView hosted offscreen. Each step is the model change plus SwiftUI's update, layout and the draw of
// what the step marked as changed (displayIfNeeded), as one frame; "no change" is that frame with nothing changed. PREVIEW_ONLY=speed (scripts/look-preview.sh): never reads data/, writes only temp.
import AppKit
import SwiftUI

extension UIShots {
    /// Made-up recordings in `root`: `count` short calls and one long call (900 turns, 40 screenshots).
    static func speedRecordings(_ root: URL, count: Int, now: Double) throws -> URL {
        try? FileManager.default.removeItem(at: root)
        func json(_ o: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: o).write(to: url) }
        let words = ["the strip", "both sides", "the order form", "Thursday", "the station map", "a check mark", "the invoice", "the drawings"]
        for i in 0..<count {
            let d = root.appendingPathComponent(String(format: "2026-10-%02dT%02d-%02d-00Z", 1 + i % 28, i % 24, i % 60))
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try json(["call": i % 3 != 0, "app": "Zoom", "started": now - Double(i + 1) * 7200, "event": ["title": "Sync \(i)", "people": ["mila"]]], d.appendingPathComponent("meta.json"))
            try json((0..<40).map { k in ["who": k % 2 == 0 ? "Я" : "Вони", "start": Double(k * 9), "text": "We look at \(words[k % words.count]) again, line \(k)."] }, d.appendingPathComponent("lines.json"))
        }
        let long = root.appendingPathComponent("2026-11-14T08-00-00Z")
        try FileManager.default.createDirectory(at: long.appendingPathComponent("shots"), withIntermediateDirectories: true)
        try json(["call": true, "app": "Zoom", "started": now - 1800, "event": ["title": "Long review", "people": ["mila", "sava"]]], long.appendingPathComponent("meta.json"))
        try json((0..<900).map { k in ["who": k % 2 == 0 ? "Я" : "Вони", "start": Double(k * 4), "text": "Then \(words[k % words.count]) moves after \(words[(k + 3) % words.count]), so we check it once more on line \(k)."] },
                 long.appendingPathComponent("lines.json"))
        var shots: [[String: Any]] = []
        for i in 0..<40 {
            let img = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { r in
                NSColor(white: 0.9, alpha: 1).setFill(); r.fill(); PK.blue.setFill(); NSRect(x: 80, y: 80 + CGFloat(i % 8) * 90, width: 600, height: 300).fill(); return true
            }
            let file = String(format: "shots/%03d.jpg", i + 1)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try jpg.write(to: long.appendingPathComponent(file))
            }
            shots.append(["t": Double(i * 90), "file": file, "app": "Figma", "title": "Screen \(i + 1)"])
        }
        try json(shots, long.appendingPathComponent("shots.json"))
        return long
    }

    static func speedRun(_ folder: String, dark: Bool) throws {
        let cal = TapeBuild.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 45))!.timeIntervalSince1970
        Entities.previewStore = sampleEntities()
        defer { Entities.previewStore = nil }
        var out: [String] = []
        func say(_ s: String) { print("speed: " + s); out.append(s) }
        func f(_ xs: [Double]) -> String { String(format: "avg %.1f ms, worst %.1f ms", xs.reduce(0, +) / Double(max(xs.count, 1)), xs.max() ?? 0) }

        // the recordings as the window reads them (off the main thread in the app)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drafter-speed-calls-\(getpid())")
        let longDir = try speedRecordings(root, count: 120, now: now)
        var reads: [Double] = []
        var docs: [CallDoc] = []
        for _ in 0..<3 { let t0 = Date(); docs = WindowModel.readDocs(root: root, notes: root.appendingPathComponent("notes")); reads.append(Date().timeIntervalSince(t0) * 1000) }
        say(String(format: "read %d recordings (off the main thread): first %.0f ms, again %.0f ms", docs.count, reads[0], reads[2]))

        let model = WindowModel(); model.preview = true; model.now = now
        sampleTape(model, now: now, days: 730, perDay: 30)
        model.docs = docs
        TapeBuild.tagCache = [:]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        var host: NSHostingView<AnyView>!
        func frame() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        func full() { if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) } }
        // the whole step; `cores` keeps the model's own part of each (before SwiftUI's update, layout and draw)
        var cores: [Double] = []
        func time(_ act: () -> Void) -> Double {
            let t0 = Date(); act(); cores.append(Date().timeIntervalSince(t0) * 1000); frame(); return Date().timeIntervalSince(t0) * 1000
        }
        func core(_ n: Int) -> String { let c = Array(cores.suffix(n)); return String(format: " (model %.1f ms avg)", c.reduce(0, +) / Double(max(c.count, 1))) }

        // 1 first open: build the journal, make the window's views, lay out and draw
        let open = time {
            model.rebuildTape()
            host = NSHostingView(rootView: AnyView(WindowView().environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)))
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1280, height: 900); model.width = 1280
            full()
        }
        var idle: [Double] = []
        for _ in 0..<3 { idle.append(time {}) }
        say("a frame with no change " + f(idle))
        // 2 reopen: the window is kept; show() reloads (the files off the main thread) and the docs come back unchanged
        var reopens: [Double] = []
        for _ in 0..<3 { reopens.append(time { model.applyDocs(docs); model.focusField += 1 }) }
        // the preview builds the journal on the main thread; the app builds it on TapeBuild.queue: left out here
        let build = model.journal.ms
        say(String(format: "first open %.0f ms on the main thread (%d items; the build, %.0f ms, runs off it in the app) · reopen ", open - build, model.rows.count, build) + f(reopens) + core(3))

        // 3 the sidebar: switch places
        var places: [Double] = []
        for p in [TapeRules.Filter.kind("call"), .kind("copied"), .kind("typed"), .kind("spoken"), .pinned, .all, .kind("call"), .all] {
            places.append(time { model.setFilter(p) })
        }
        say("switch a place in the sidebar " + f(places) + core(places.count))

        // 4 open a recording (the long one: 900 turns, 40 screenshots), back, open again
        let long = docs.first { $0.id == longDir.path } ?? docs[0]
        let firstDoc = time { model.openDoc(long) }
        let back = time { model.back() }
        let againDoc = time { model.openDoc(long) }
        // a playhead tick while it plays (every 0.4 s)
        var ticks: [Double] = []
        for k in 0..<5 { ticks.append(time { model.playhead = Double(k * 4) }) }
        var docIdle: [Double] = []
        for _ in 0..<3 { docIdle.append(time {}) }
        _ = time { model.back() }
        say(String(format: "open a recording (900 turns, 40 shots) %.0f ms, back %.0f ms, open again %.0f ms · playhead tick ", firstDoc, back, againDoc) + f(ticks) + core(6) + " · no change on this page " + f(docIdle))

        // 5 typing in the search: each key to the list drawn
        _ = time { model.query = "zq" }; _ = time { model.query = "" }   // the index (built off the main thread in the app)
        var keys: [Double] = []
        for q in ["s", "st", "sta", "stat", "stati", "statio", "station"] { keys.append(time { model.query = q }) }
        _ = time { model.query = "" }
        say("type in the search, per key " + f(keys) + core(8))

        // 6 scroll the list a screen at a time
        var scrolls: [Double] = []
        if let sv = (model.gallery ? model.galleryView?.enclosingScrollView : model.listView?.enclosingScrollView) {
            for k in 1...30 {
                scrolls.append(time { sv.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(k) * 700)); sv.reflectScrolledClipView(sv.contentView) })
            }
        }
        say("scroll the \(model.gallery ? "gallery" : "list") a screen " + f(scrolls))

        // 7 a status line change (each copy, play, and the ticker): what one published change costs the window
        var stat: [Double] = []
        for k in 0..<5 { stat.append(time { model.status = "On the clipboard · \(k) characters" }) }
        say("status line change " + f(stat) + core(5))
        var eng: [Double] = []
        for _ in 0..<3 { eng.append(time { model.engine = model.engine }) }   // the 3 s tick writes the same engine line
        say("engine tick (same value) " + f(eng))
        say(zoomTiming(model, time))   // ZOOM (PreviewZoom.swift; the baseline run drops this line)
        try (out.joined(separator: "\n") + "\n").write(toFile: folder + "/speed.txt", atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: root)
    }
}
