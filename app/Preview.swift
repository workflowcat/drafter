// Native rendering checks with synthetic data. Never launches the app delegate or either engine.
import AppKit
import SwiftUI

enum UIShots {
    static func save(_ view: NSView, _ path: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "Preview", code: 1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        try data.write(to: URL(fileURLWithPath: path))
    }
    static func run(_ folder: String, dark: Bool) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // PREVIEW_ONLY=quick (or window, settings, strip): one surface, for a quick look while working on it
        let only = ProcessInfo.processInfo.environment["PREVIEW_ONLY"] ?? ""
        if only == "knowledge" { try EntityPreview.run(folder); return }   // the entity card, the mark and the context preview
        if only == "window" || only == "window-themes" {   // the window; window-themes: in every built-in theme too
            try windowShots(folder, dark: dark)
            if only == "window-themes" {
                for t in ThemeStore.all() where t.id != "pixel" {
                    ThemeStore.use(t.id)
                    let sub = folder + "/theme-" + t.id
                    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
                    try windowShots(sub, dark: dark, short: true)
                }
                ThemeStore.use("pixel")
            }
            return
        }
        if only == "strip" { try Pill.shared.preview(folder); return }
        if only == "quick" || only == "themes" {
            try Quick.shared.preview(folder)
            if only == "themes" {   // every built-in theme: folder/theme-<id>/
                for t in ThemeStore.all() where t.id != "pixel" {
                    ThemeStore.use(t.id)
                    let sub = folder + "/theme-" + t.id
                    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
                    try Quick.shared.preview(sub)
                }
                ThemeStore.use("pixel")
            }
            return
        }
        try Pill.shared.preview(folder)
        try Command.shared.preview(folder)
        try Quick.shared.preview(folder)
        try EntityPreview.run(folder)
        try onScreen(folder)
        try windowShots(folder, dark: dark)
        print("Native UI previews passed: " + folder)
    }

    /// Made-up rows for the tape: copied, typed and said through one morning (never his).
    static func sampleTape(_ m: WindowModel, now: Double, filler: Int = 0) {
        func at(_ h: Int, _ min: Int) -> Date {
            Calendar.current.date(bySettingHour: h, minute: min, second: 14, of: Date(timeIntervalSince1970: now))!
        }
        func e(_ id: String, _ h: Int, _ mi: Int, _ app: String, _ text: String, secs: Double = 0) -> Entry {
            Entry(id: id, when: at(h, mi), app: app, text: text, audio: "", secs: secs)
        }
        m.clips = [e("c1", 12, 38, "Safari", "https://example.org/station/review-14#plan"),
                   e("c5", 12, 30, "Preview", "Image · 640 × 400"), e("c6", 12, 27, "Finder", NSHomeDirectory() + "/Desktop/station-drawings-final.pdf"),
                   e("c2", 12, 4, "Mail", "Room 4.12, second floor, the door on the left"),
                   e("c3", 11, 9, "Xcode", "let share = taken / shown"),
                   e("c4", 10, 31, "Mail", "Mila Synthetic, +380 00 000 00 00, Tuesday after 14:00")]
        // round three: a link with its title, a picture with its read text, a file
        m.clips[0].clip = .link; m.clips[0].clipTitle = "Station review 14"
        if let p = try? Quick.samplePicture() { m.clips[1].clip = .image; m.clips[1].picture = p.name; m.clips[1].bytes = p.bytes; m.clips[1].ocr = p.ocr }
        m.clips[2].clip = .file; m.clips[2].bytes = 482_113
        var typed = [e("t1", 12, 41, "Telegram", "Could you send the final drawings by three? I will look before the call."),
                     e("t2", 12, 20, "Claude", "Rewrite this paragraph in plain English, at most 40 words, keep it warm"),
                     e("t3", 11, 22, "Terminal", "git commit -m \"tape: one column, no panes\""),
                     e("t4", 11, 2, "Messages", "See you at the station at nine, I will bring the drawings."),
                     e("t5", 10, 15, "Claude", "Can you check the contrast of the grey text in both themes?"),
                     e("t6", 9, 52, "Slack", "Warm, but not formal - we write the way people talk")]
        typed[3].drafts = ["See you at the", "See you at the station at ten", "See you at the station at nine"]
        m.typed = typed
        var takes = [e("v1", 12, 31, "Notes", "Note after the review: we keep the tape and drop the three panes. Button words should be simpler. Mila does the second round by Tuesday.", secs: 18),
                     e("v2", 11, 36, "Calendar", "Remind me on Monday to send the invoice to the studio", secs: 6),
                     e("v3", 10, 47, "Notes", "Idea: show the grey text only after half a second of pause, not on every letter", secs: 9)]
        takes[0] = Entry(id: "v1", when: takes[0].when, app: "Notes", text: takes[0].text, audio: "/sample/take.wav", secs: 18)
        takes[0].raw = "Note after the review: well, we keep the tape and, um, drop the three panes. Button words should be simpler. Mila does the second round by Tuesday."
        m.takes = takes
        // filler for the speed check: older days, all kinds
        let words = ["plan", "station", "drawings", "budget", "зустріч", "четвер", "report", "звіт", "invoice", "notes", "draft", "review"]
        let apps = ["Notes", "Safari", "Mail", "Telegram", "Slack", "Claude"]
        for i in 0..<filler {
            var w: [String] = []
            for k in 0..<(5 + i % 18) { w.append(words[(k * 7 + i) % words.count]) }
            w.append("\(i)")
            let x = Entry(id: "f\(i)", when: Date(timeIntervalSince1970: now - 86400 - Double(i) * 1100), app: apps[i % apps.count], text: w.joined(separator: " "), audio: "")
            switch i % 3 { case 0: m.clips.append(x); case 1: m.typed.append(x); default: m.takes.append(x) }
        }
    }

    /// The window as one tape: the tape with a row open, a call chosen, a search, one kind, the command, the pages.
    static func windowShots(_ folder: String, dark: Bool, short: Bool = false) throws {
        let now = Calendar.current.date(bySettingHour: 12, minute: 45, second: 0, of: Date())!.timeIntervalSince1970
        let model = WindowModel(); model.preview = true; model.now = now
        // made-up numbers for Settings (the real ones come from data/app.log)
        model.stats = [LogStats.suggest: .init(shown: 8400, taken: 410), LogStats.claude: .init(shown: 96, taken: 9),
                       LogStats.proofread: .init(shown: 29, taken: 2), LogStats.translate: .init(shown: 0, taken: 0),
                       LogStats.facts: .init(shown: 3, taken: 1), LogStats.next: .init(shown: 140, taken: 12),
                       LogStats.rework: .init(shown: 5, taken: 4), LogStats.typo: .init(shown: 380, taken: 130),
                       LogStats.fixWord: .init(shown: 680, taken: 28), LogStats.layout: .init(shown: 18, taken: 18), "takes": .init(shown: 7, taken: 0)]
        sampleTape(model, now: now)
        var docs = try sampleDocs()
        docs[0].started = Date(timeIntervalSince1970: Calendar.current.date(bySettingHour: 11, minute: 58, second: 0, of: Date(timeIntervalSince1970: now))!.timeIntervalSince1970)
        docs[0].secs = 92
        docs[1].started = Date(timeIntervalSince1970: now - 86400 + 3600); docs[1].secs = 4 * 60 + 10
        docs[2].started = Date(timeIntervalSince1970: now - 2 * 86400)
        model.docs = docs
        model.rebuildTape()
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 1000)
        func shot(_ name: String, wait: Double = 0.15) throws { RunLoop.current.run(until: Date().addingTimeInterval(wait)); try save(host, folder + "/" + name + ".png") }
        // a copied link open, as on the concept board
        model.chosen = model.rows.first { $0.entry?.id == "c1" }?.id; model.open = model.chosen
        try shot("window", wait: 0.3)
        model.chosen = model.rows.first { $0.doc != nil }?.id; model.open = nil
        try shot("window-call")
        model.chosen = model.rows.first { $0.entry?.id == "c5" }?.id; model.open = model.chosen
        try shot("window-picture-open")
        model.chosen = model.rows.first { $0.entry?.id == "v1" }?.id; model.open = model.chosen
        try shot("window-said-open")
        if short { model.open = nil; model.show(.settings); try shot("settings"); return }
        model.chosen = model.rows.first { $0.entry?.id == "t4" }?.id; model.open = model.chosen
        try shot("typed")
        model.open = nil; model.query = "station"
        try shot("window-search")
        model.query = ""; model.solo(.said)
        try shot("window-said")
        model.solo(.said)
        var incomplete = Entry(id: "sample-incomplete", when: Date(timeIntervalSince1970: now - 60), app: "Notes", text: "", audio: "", secs: 12)
        incomplete.raw = "The last words heard before transcription stopped."; incomplete.outcome = "timeout"
        model.takes.insert(incomplete, at: 0); model.rebuildTape()
        model.chosen = "v:sample-incomplete"; model.open = model.chosen
        try shot("voice-recovery")
        model.takes.removeFirst(); model.rebuildTape(); model.open = nil
        model.startCommand(); model.command = "book 30 min with Mila tomorrow"
        model.options = [["chip": "Book «Design review» tomorrow 10:00-10:30"], ["chip": "Find a free 30 min slot tomorrow"]]
        model.status = "Haiku · click to run"
        try shot("command-options")
        model.escape(); model.status = ""
        // the pages: a call, its search, a long note, a call with no words
        model.openDoc(model.docs[0]); try shot("recordings", wait: 0.3)
        model.query = "схем"; try shot("recordings-search", wait: 0.3)
        model.query = ""; model.openDoc(model.docs[1]); try shot("recordings-note", wait: 0.2)
        model.warnings[model.docs[2].id] = ["Your microphone gives only silence (muted or taken by another app?)"]
        model.openDoc(model.docs[2]); try shot("recordings-empty", wait: 0.3)
        model.show(.shortcuts); try shot("shortcuts")
        model.show(.settings); try shot("settings")
        // the whole Settings page at once, to see the groups below the fold (calls, calendars)
        let tall = NSHostingView(rootView: SettingsView().environmentObject(model).foregroundStyle(UIInk.ink).tint(UIInk.blue)
            .background(UIInk.paper).environment(\.colorScheme, dark ? .dark : .light))
        let tallWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1152, height: 2300), styleMask: [.borderless], backing: .buffered, defer: false)
        tallWindow.contentView = tall; tall.frame = NSRect(x: 0, y: 0, width: 1152, height: 2300)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try save(tall, folder + "/settings-all.png")
        model.show(.help); try shot("help")
        model.back(); model.query = "no matching recording"
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        try shot("window-small-empty")
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 1000)
        // speed: 1,000 made-up rows: build (merge and filter), lay out and draw what is in view; then scroll
        let big = WindowModel(); big.preview = true; big.now = now
        sampleTape(big, now: now, filler: 990)
        big.docs = docs
        let v = TapeView(frame: NSRect(x: 0, y: 0, width: 1152, height: 800))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1152, height: 800)); sv.documentView = v; v.model = big
        // what AppKit asks for: the rows in the visible rect, drawn into a bitmap of that size
        func drawVisible() {
            let r = sv.contentView.documentVisibleRect
            guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { return }
            v.cacheDisplay(in: r, to: rep)
        }
        var opens: [Double] = [], builds: [Double] = []
        for _ in 0..<5 {
            let t0 = Date()
            big.rebuildTape()
            builds.append(Date().timeIntervalSince(t0) * 1000)
            v.apply(rows: big.rows, chosen: big.rows.first?.id, open: nil, query: "")
            drawVisible()
            opens.append(Date().timeIntervalSince(t0) * 1000)
        }
        let total = big.rows.count
        var scrolls: [Double] = []
        for k in 1...30 {
            let t0 = Date()
            sv.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(k) * 600)); sv.reflectScrolledClipView(sv.contentView)
            drawVisible()
            scrolls.append(Date().timeIntervalSince(t0) * 1000)
        }
        var keys: [Double] = []
        for q in ["s", "st", "sta", "stat", "stati"] {
            let t0 = Date(); big.query = q; v.apply(rows: big.rows, chosen: big.chosen, open: nil, query: q); drawVisible(); keys.append(Date().timeIntervalSince(t0) * 1000)
        }
        print(String(format: "window speed: %d rows · open (build + layout + draw in view) first %.1f ms, then %.1f ms (build alone avg %.1f ms) · scroll a screen avg %.2f ms, worst %.2f ms · search per key avg %.1f ms, worst %.1f ms",
                     total, opens[0], opens.dropFirst().reduce(0, +) / 4, builds.reduce(0, +) / 5, scrolls.reduce(0, +) / Double(scrolls.count), scrolls.max() ?? 0,
                     keys.reduce(0, +) / Double(keys.count), keys.max() ?? 0))
    }

    /// Two fictional recordings in a temporary folder: a call with timed lines, both sides, audio and screenshots, and
    /// a long note without times. Their summaries come in as notes would (no data/notes file is read or written).
    static func sampleDocs() throws -> [CallDoc] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drafter-preview-calls")
        try? FileManager.default.removeItem(at: root)
        let call = root.appendingPathComponent("2026-10-30T09-00-00Z"), note = root.appendingPathComponent("2026-10-29T15-10-00Z")
        for d in [call, note] { try FileManager.default.createDirectory(at: d.appendingPathComponent("shots"), withIntermediateDirectories: true) }
        let now = Date().timeIntervalSince1970
        func json(_ o: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: o).write(to: url) }
        try json(["call": true, "app": "Zoom", "started": now - 3 * 3600, "event": ["title": "Design review: voice strip", "people": ["mila"]]], call.appendingPathComponent("meta.json"))
        try json(["call": false, "app": "Figma", "started": now - 26 * 3600], note.appendingPathComponent("meta.json"))
        let rows: [(String, Double, String)] = [
            ("Я", 2, "Привіт! Покажу нову схему стрічки, вона вже в макеті."), ("Вони", 9, "Бачу. А де тут видно, що запис іде з обох боків?"),
            ("Я", 15, "Ось дві позначки рівня: я і вони. Якщо їхня мовчить хвилину, це видно одразу."), ("Вони", 31, "Добре. Тоді прибери слово Processing, коли текст уже вставлено."),
            ("Я", 44, "Так, там буде галочка замість мікрофона."), ("Вони", 58, "І таймер на пропозиції записати дзвінок, тонка лінія знизу."),
            ("Я", 71, "Домовились. Надішлю оновлену схему ввечері."), ("Вони", 80, "Супер, тоді в четвер подивимось разом.")]
        try json(rows.map { ["who": $0.0, "start": $0.1, "text": $0.2] }, call.appendingPathComponent("lines.json"))
        try "Я думаю, що головна сторінка має бути спокійнішою. Перше: менше рамок. Друге: пошук по всіх розмовах одразу, щоб за хвилину знайти, хто що сказав. Третє: одна кнопка, яка віддає все агенту разом зі скріншотами. Решту можна сховати в меню."
            .write(to: note.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        // 80 seconds of silence on each side, so Play shows as it does for a real call
        var wav = Data("RIFF".utf8); wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + 32000 * 80).littleEndian, Array.init))
        wav.append(Data("WAVEfmt ".utf8)); wav.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0, 2, 0, 16, 0])
        wav.append(Data("data".utf8)); wav.append(contentsOf: withUnsafeBytes(of: UInt32(32000 * 80).littleEndian, Array.init)); wav.append(Data(count: 32000 * 80))
        for n in ["me.wav", "them.wav"] { try wav.write(to: call.appendingPathComponent(n)) }
        // three screens: drawn boxes with a label, as JPEG like Shots writes them
        var shots: [[String: Any]] = []
        for (i, (t, label)) in [(12.0, "Strip · levels"), (40.0, "Strip · done"), (60.0, "Offer · countdown")].enumerated() {
            let img = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { r in
                NSColor(srgbRed: 0.93, green: 0.93, blue: 0.92, alpha: 1).setFill(); r.fill()
                NSColor.black.setFill(); NSRect(x: 170, y: 330, width: 300, height: 46).fill()
                PK.blue.setFill(); NSRect(x: 40, y: 40 + CGFloat(i) * 60, width: 220, height: 120).fill()
                (label as NSString).draw(at: NSPoint(x: 300, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.darkGray])
                return true
            }
            let file = String(format: "shots/%03d-00m%02ds.jpg", i + 1, Int(t))
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try jpg.write(to: call.appendingPathComponent(file))
            }
            shots.append(["t": t, "file": file, "app": "Figma", "title": "Drafter strip · " + label])
        }
        try json(shots, call.appendingPathComponent("shots.json"))
        let notes = [call.path: NoteFile(path: "/sample/notes/design-review.md", title: "Design review: voice strip", people: ["Mila Synthetic", "Sava Synthetic"],
                                         points: ["The strip shows both sides' sound while a call records", "A check replaces the microphone once text is in",
                                                  "The call offer gets a thin 30-second line"],
                                         followups: ["Alex: send the updated strip tonight", "Both: look at it together on Thursday"]),
                     note.path: NoteFile(path: "/sample/notes/home.md", title: "Calmer home screen", people: [], points: [], followups: ["Hide the rest in a menu"])]
        // a call that was never read: 2 s of microphone, 5 minutes of the other side
        let unread = root.appendingPathComponent("2026-10-28T14-04-00Z")
        try FileManager.default.createDirectory(at: unread, withIntermediateDirectories: true)
        try json(["call": true, "app": "Zoom", "started": now - 50 * 3600, "event": ["title": "Sync", "people": [String]()]], unread.appendingPathComponent("meta.json"))
        func silence(_ secs: Int) -> Data {
            var w = Data("RIFF".utf8); w.append(contentsOf: withUnsafeBytes(of: UInt32(36 + 32000 * secs).littleEndian, Array.init))
            w.append(Data("WAVEfmt ".utf8)); w.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0, 2, 0, 16, 0])
            w.append(Data("data".utf8)); w.append(contentsOf: withUnsafeBytes(of: UInt32(32000 * secs).littleEndian, Array.init)); w.append(Data(count: 32000 * secs))
            return w
        }
        try silence(2).write(to: unread.appendingPathComponent("me.wav")); try silence(300).write(to: unread.appendingPathComponent("them.wav"))
        return [CallDoc.load(call, notes: notes), CallDoc.load(note, notes: notes), CallDoc.load(unread, notes: notes)]
    }
}

// MARK: what shows over other apps (look round, 14 November 2026)

extension UIShots {
    /// A view as it draws now, at the screen's scale (offscreen: nothing is put on the screen).
    static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width * scale)), pixelsHigh: Int(ceil(view.bounds.height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // the views alone, over nothing (a panel's clear ground stays clear)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        NSColor.clear.set(); view.bounds.fill(using: .copy)
        NSGraphicsContext.restoreGraphicsState()
        // a layer's own ground (the strip's buttons): drawn first, with its corners
        if let bg = view.layer?.backgroundColor, let c = NSColor(cgColor: bg) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            let r = view.layer?.cornerRadius ?? 0
            c.setFill(); NSBezierPath(roundedRect: view.bounds, xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        // a view with children: its own drawing, then each child put on it one by one
        if !(view is NSTextField), !view.subviews.isEmpty {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
            for sub in view.subviews where !sub.isHidden { bitmap(sub)?.over(sub.frame) }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        // a label draws through its cell (drawn whole, it took the clear window's ground as grey)
        if let tf = view as? NSTextField, let cell = tf.cell {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            view.effectiveAppearance.performAsCurrentDrawingAppearance { cell.draw(withFrame: tf.bounds, in: tf) }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.displayIgnoringOpacity(view.bounds, in: ctx) }
        return rep
    }

    /// A picture drawn in code at 2x, in the app's appearance.
    static func picture(_ size: NSSize, _ path: String, _ draw: (NSRect) -> Void) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "Preview", code: 3) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { draw(NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// The strip as it hangs from the notch (or floats under the menu bar): a made-up menu bar behind it.
    static func strip(_ box: NSView, _ path: String, notch: CGFloat, bar: CGFloat) throws {
        guard let img = bitmap(box) else { return }
        let w = max(760, box.bounds.width + 200), h = max(box.bounds.height + 28, bar + 40)
        try picture(NSSize(width: w, height: h), path) { r in
            let dark = PK.dark
            (dark ? PK.hex(0x2b2b2e) : PK.hex(0xdedfe3)).setFill(); r.fill()   // the desktop
            (dark ? PK.hex(0x1d1d1f, 0.92) : PK.hex(0xf6f6f6, 0.92)).setFill()     // the menu bar
            NSRect(x: 0, y: h - bar, width: w, height: bar).fill()
            let menu: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: dark ? NSColor.white : NSColor.black]
            ("  Notes    File    Edit    View" as NSString).draw(at: NSPoint(x: 8, y: h - bar + (bar - 16) / 2), withAttributes: menu)
            ("12:40" as NSString).draw(at: NSPoint(x: w - 52, y: h - bar + (bar - 16) / 2), withAttributes: menu)
            if notch > 0 {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: (w - notch) / 2, y: h - bar, width: notch, height: bar + 8), xRadius: 8, yRadius: 8).fill()
                NSRect(x: (w - notch) / 2, y: h - 8, width: notch, height: 8).fill()
            }
            img.over(NSRect(x: (w - box.bounds.width) / 2, y: h - box.bounds.height - (notch > 0 ? 0 : bar + 6),
                                width: box.bounds.width, height: box.bounds.height))
        }
    }

    /// One made-up field with what Drafter shows at its caret. The caret sits far above every screen, so the real
    /// panels are laid out as they would be and never appear.
    static func field(_ path: String, typed: String, caret: CGRect, panel: NSPanel, size: NSSize = NSSize(width: 720, height: 150),
                      font: NSFont? = nil, box: CGRect? = nil, placeholder: String = "", extra: ((NSPoint) -> Void)? = nil) throws {
        guard let content = panel.contentView, let img = bitmap(content) else { return }
        let c = Ghost.shared.cocoa(caret)
        let f = font ?? NSFont.systemFont(ofSize: max(11, min(26, c.height * 0.78)))
        // the picture holds the field, the caret and the panel, with room around them
        let around = (box.map { Ghost.shared.cocoa($0) } ?? c).union(panel.frame).union(c).insetBy(dx: -40, dy: -34)
        let size = NSSize(width: max(size.width, around.width), height: max(size.height, around.height))
        var o = NSPoint(x: c.minX - size.width * 0.46, y: c.midY - size.height * 0.55)
        o.x = min(max(o.x, around.maxX - size.width), around.minX); o.y = min(max(o.y, around.maxY - size.height), around.minY)
        try picture(size, path) { r in
            NSColor.windowBackgroundColor.setFill(); r.fill()
            let fieldRect = box.map { Ghost.shared.cocoa($0) }.map { NSRect(x: $0.minX - o.x, y: $0.minY - o.y, width: $0.width, height: $0.height) }
                ?? NSRect(x: 24, y: c.minY - o.y - 10, width: size.width - 48, height: c.height + 20)
            NSColor.textBackgroundColor.setFill()
            let fp = NSBezierPath(roundedRect: fieldRect, xRadius: 8, yRadius: 8); fp.fill()
            NSColor.separatorColor.setStroke(); fp.lineWidth = 1; fp.stroke()
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.labelColor]
            let t = typed as NSString, tw = t.size(withAttributes: a).width
            let lineH = ceil(f.ascender - f.descender + f.leading)
            t.draw(at: NSPoint(x: c.minX - o.x - tw, y: c.minY - o.y + (c.height - lineH) / 2), withAttributes: a)
            if typed.isEmpty, !placeholder.isEmpty {
                (placeholder as NSString).draw(at: NSPoint(x: fieldRect.minX + 12, y: fieldRect.midY - lineH / 2),
                                               withAttributes: [.font: f, .foregroundColor: NSColor.placeholderTextColor])
            }
            NSColor.labelColor.setFill(); NSRect(x: c.minX - o.x, y: c.minY - o.y, width: 1.5, height: c.height).fill()
            extra?(o)
            let p = panel.frame
            img.over(NSRect(x: p.minX - o.x, y: p.minY - o.y, width: content.bounds.width, height: content.bounds.height))
        }
    }

    static func onScreen(_ folder: String) throws {
        let g = Ghost.shared
        let caret = CGRect(x: 600, y: -2600, width: 1, height: 20)   // AX, top-left: above every screen
        func chip(_ name: String, _ typed: String, _ action: [String: Any]) throws {
            g.unsure = 0; g.show("", action: action, at: caret)
            try field(folder + "/chip-\(name).png", typed: typed, caret: caret, panel: g.panel)
            g.hide()
        }
        g.unsure = 7; g.show("the slides tonight", action: nil, at: caret)
        try field(folder + "/ghost.png", typed: "Thanks, Mila. I will send you ", caret: caret, panel: g.panel)
        g.extend(" before nine", unsure: 11)
        try field(folder + "/ghost-two-step.png", typed: "Thanks, Mila. I will send you ", caret: caret, panel: g.panel)
        g.hide()
        g.unsure = 0; g.show("receive", action: nil, at: caret, replace: "recie")
        try field(folder + "/ghost-fix.png", typed: "I did not recie", caret: caret, panel: g.panel)
        g.hide()
        try chip("snippet", "my mail is au", ["id": "snippet", "chip": "⇥ alex@example.com"])
        try chip("action", "нагадай завтра о 10 надіслати акт Мілі", ["id": "reminder", "chip": "Нагадування · завтра 10:00 · надіслати акт Мілі"])
        try chip("translate", "Дякую, надішлю акт сьогодні ввечері ;en", ["id": "translate", "chip": "⇥ EN · Thanks, I will send the act tonight"])
        try chip("proofread", "I recieve it tommorow", ["id": "proofread", "chip": "⇥ Fix 2 · recieve → receive, tommorow → tomorrow"])
        try chip("person", "Mila's number is ", ["id": "person", "chip": "Mila Synthetic · phone · +380 00 000 0000"])
        try chip("fact", "we meet on ", ["id": "fact", "chip": "⇥ Thursday 20 November, 11:00 · Design review"])
        try chip("lookup", ";docs project notes", ["id": "lookup", "chip": "Search Google Drive · project notes"])
        // the next message: a card above an empty box
        let fieldBox = CGRect(x: 300, y: -2580, width: 520, height: 40)
        let inBox = CGRect(x: 312, y: -2570, width: 1, height: 20)
        g.showDraft([["text": "Thanks, Mila! I'll send the act tonight and we can go over the numbers on Thursday at 11 if that works for you.", "label": "thanks + act tonight"],
                     ["text": "b", "label": "b"], ["text": "c", "label": "c"]], field: fieldBox, caret: inBox)
        try field(folder + "/card.png", typed: "", caret: inBox, panel: g.panel, size: NSSize(width: 720, height: 190), box: fieldBox, placeholder: "Message")
        g.expand(true)
        try field(folder + "/card-open.png", typed: "", caret: inBox, panel: g.panel, size: NSSize(width: 720, height: 230), box: fieldBox, placeholder: "Message")
        g.hide()
        // a word Drafter fixed: dots under it, his own word in a chip above
        let word = CGRect(x: 560, y: -2600, width: 58, height: 20)
        let typedFont = NSFont.systemFont(ofSize: 15.6)
        let fixed = FixMarks.shared.previewChip(old: "recieve", word: word)
        try field(folder + "/fixmark.png", typed: "I did not receive", caret: CGRect(x: word.maxX, y: word.minY, width: 1, height: 20), panel: fixed,
                  font: typedFont) { o in
            let c = Ghost.shared.cocoa(word)
            let dots = Dots(frame: NSRect(x: 0, y: 0, width: c.width, height: 2))
            if let d = bitmap(dots) { d.over(NSRect(x: c.minX - o.x, y: c.minY - o.y - 1, width: c.width, height: 2)) }
        }
        FixMarks.shared.hideChip()
    }
}

extension NSImageRep {
    /// Drawn over what is there (`draw(in:)` copies, so a clear pixel cut a hole).
    func over(_ r: NSRect) { draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
}
