// The shot strip (round three, Part C, 14 November 2026; screenshot tool, 15 November 2026): after a capture a slim
// strip holds the picture and one line. ↵ puts it in, ⌘E marks it up, ⇥ opens the send-to list, esc puts the picture
// alone (⌘↵ still puts the picture and its read text). Holding Right Option while the strip is open speaks the line:
// the take's text lands here, not in the app (Talk.toNote, app/Voice.swift).
// ↵ by the field's kind (ShotPack.fieldWay): an agent app (Claude, Codex) gets the picture, then the agent text; a
// terminal one line with the paths (never a line break, never Return); any other field the picture, then the line,
// as before (ShotRules.delivery: two pastes in a row; no field: both on the clipboard as one item).
// ⇥: the list (ShotPack.order, the last target first): digits 1-8 or ↑↓ ↵ pick, esc back. Person turns the line into a
// name search (beeper, read only), a digit picks the chat, the picture and the note go in as a draft, never sent.
// Every change to the shot (the note, the marks, a send) is written into its pack off the main thread (ShotStore).
// Keys come through the event tap (Quick.tap); the strip never becomes key.
// Look round (15 November 2026): every key is a glyph button (ShotPill: the key small under it, the word in a tip on
// hover), clickable; the send-to rows carry the app's own icon when the app is on this Mac. The strip opens right under
// the captured region, on its left edge (ShotRules.stripPlace), the list grows down from it. Key and strip round: no room
// under the region means the bottom edge of that screen (beside the picture when it reaches the bottom), never above it. A region capture first
// goes to markup in place (MarkupEditor, region), ↵ there comes here. ⌘N (+) adds another picture to the same hand-off:
// the strip shows the set as thumbnails (⌘← ⌘→ or a click picks one, ⌫ takes it out, ⌘E marks it), one note for the
// set, and every target hands off all of them in order (ShotPack.pictures).
import AppKit

final class CaptureNote {
    static let shared = CaptureNote()
    enum Mode { case note, list, person }
    /// One picture of the set: as it goes (marked), as taken, its marks and where it was on the screen.
    struct Pic {
        var png: Data
        var original: Data? = nil
        var marks: [PicMark] = []
        var shot: ShotPicture
        var region: NSRect? = nil      // AppKit screen points
        var full = false               // a whole screen
        var inPlace = false            // a dragged region: marks go on in place
        var thumb: NSImage?
    }
    private(set) var isOpen = false
    /// The screen is dimmed for another picture of this set (⌘N); the strip comes back after it.
    private(set) var collecting = false
    var mode = Mode.note
    var line = ""                              // the note (in person mode: the name being searched)
    var note = ""                              // the note kept while the line searches a name
    var noteVia = "typed"
    var pics: [Pic] = []
    var picked: Int?                           // a thumbnail picked in a set
    var hover: Int?                            // the button under the mouse (ShotRules.StripButton raw value)
    var pack: ShotPack?
    var list: [ShotTarget] = []
    var chats: [(id: String, title: String)] = []
    var searching = false
    var sel = 0
    private var origin: NSRunningApplication?
    private var t0 = Date()
    private var readDone = true
    private var waiting: [() -> Void] = []
    private var searchGen = 0
    private var card = NSRect.zero              // the strip's card on the screen (AppKit points)
    let panel: NSPanel
    let view = CaptureNoteView()

    /// The first picture (one-picture code paths).
    var png: Data { pics.first?.png ?? Data() }
    var pngs: [Data] { pics.map(\.png) }

    init() {
        panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.model = self; panel.contentView = view
    }

    static func pic(_ png: Data, region: NSRect?, full: Bool, inPlace: Bool) -> Pic {
        let size = NSBitmapImageRep(data: png).map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
        return Pic(png: png, shot: ShotPicture(file: "", width: size.0, height: size.1), region: region, full: full, inPlace: inPlace, thumb: NSImage(data: png))
    }

    /// `pack`: the shot as written at capture (nil in the old previews); its text is read here, once. `region`: where
    /// it was taken (screen points), `full` a whole screen; `inPlace`: a dragged region, marked up in place first.
    func open(png: Data, row: [String: Any], origin: NSRunningApplication?, t0: Date, pack: ShotPack? = nil,
              region: NSRect? = nil, full: Bool = false, inPlace: Bool = false) {
        self.origin = origin; self.t0 = t0; line = ""; note = ""; noteVia = "typed"; collecting = false
        self.pack = pack; mode = .note; chats = []; sel = 0; searching = false; picked = nil; hover = nil
        pics = [Self.pic(png, region: region, full: full, inPlace: inPlace)]
        readDone = pack == nil; waiting = []
        if let id = pack?.id { readPicture(png, id: id, first: true) }
        if inPlace, region != nil { markup(0); return }
        show()
        log("capture: note open, \(Int(Date().timeIntervalSince(t0) * 1000)) ms after release")
    }

    private func readPicture(_ png: Data, id: String, first: Bool) {
        if !first { readDone = false }
        ShotStore.read(png) { text, found in
            guard self.pack?.id == id else { ShotStore.update(id) { $0.read += (first ? "" : "\n") + text; $0.found += found }; return }
            if var p = self.pack {
                p.read = first || p.read.isEmpty ? text : p.read + "\n" + text
                p.found = Array((p.found + found).prefix(20))
                self.pack = p
            }
            self.readDone = true
            self.save()
            let w = self.waiting; self.waiting = []; w.forEach { $0() }
        }
    }

    /// A shot from the journal again: its pack and pictures from data/shots/<id>/, then the send-to list (or markup
    /// over the first picture with the kept marks). Put in (↵) goes to the app that was in front before Drafter's window.
    func reopen(_ p: ShotPack, folder: URL, markup mark: Bool) {
        var loaded: [Pic] = []
        for (i, sp) in p.pics.enumerated() {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent(ShotPack.pictureFile(i))) else { continue }
            var pc = Self.pic(d, region: nil, full: false, inPlace: false)
            pc.shot = sp
            if let o = try? Data(contentsOf: folder.appendingPathComponent(ShotPack.originalFile(i))) {
                pc.original = o; pc.marks = Markup.picMarks(sp.marks, crop: sp.crop)
            }
            loaded.append(pc)
        }
        guard !loaded.isEmpty else { Pill.shared.flash("The shot's picture is gone"); return }
        if isOpen { close() }
        open(png: loaded[0].png, row: ["kind": "image", "shot": p.id], origin: NSWorkspace.shared.frontmostApplication, t0: Date(), pack: p)
        pics = loaded
        line = p.note; noteVia = p.noteVia
        log("shot: again, \(mark ? "markup" : "send to"), \(pics.count) pictures")
        if mark { markup(0); return }
        note = line
        list = ShotPack.order(last: ShotTarget(rawValue: Drafter.shared.settings.shotLast))
        sel = 0; mode = .list; resize()
    }

    func close() { isOpen = false; panel.orderOut(nil) }

    /// The pack written again: the set's pictures (when given) and shot.json / shot.md.
    private func save(pictures: Bool = false) {
        guard var p = pack else { return }
        p.note = mode == .note ? line : note; p.noteVia = noteVia
        p.setPictures(pics.map(\.shot).enumerated().map { i, s in var s = s; s.original = pics[i].original == nil ? nil : "x"; return s })
        pack = p
        if pictures { ShotStore.writeSet(p, pngs: pngs, originals: pics.map(\.original)) }
        else { ShotStore.write(p) }
    }

    /// `f` once the picture's text is read (at most 2 s later; then without it).
    private func withRead(_ f: @escaping () -> Void) {
        if readDone { f(); return }
        var done = false
        let once = { if !done { done = true; f() } }
        waiting.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once() }
    }

    // MARK: where it sits

    /// Shown and placed: under the last picture's region (ShotRules.stripPlace), else under the caret, else in the
    /// upper third of the mouse's screen.
    private func show() {
        isOpen = true
        place()
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    private func setCard(_ c: NSRect) {
        card = c
        panel.setFrame(CaptureNoteView.panelFrame(c), display: true)
        view.needsDisplay = true
    }

    private func place() {
        let size = view.fit()
        if let last = pics.last, let r = last.region,
           let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) }) ?? NSScreen.screens.first(where: { $0.frame.intersects(r) }) {
            setCard(ShotRules.stripPlace(size, region: r, full: last.full, screen: scr.visibleFrame))
            return
        }
        let h = NSScreen.screens.first?.frame.height ?? 0
        var anchor: CGRect?
        if let app = origin, app.processIdentifier != getpid(), let el = Focus.focused() {
            AXUIElementSetMessagingTimeout(el, 0.08)
            anchor = Focus.selectionRect(el) ?? Focus.frame(el)
        }
        if let a = anchor, let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: a.midX, y: h - a.midY)) }) {
            let caret = NSRect(x: a.minX, y: h - a.maxY, width: a.width, height: a.height)
            setCard(ShotRules.caretPlace(size, caret: caret, screen: scr.visibleFrame))
            return
        }
        let mouse = NSEvent.mouseLocation
        let vis = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setCard(NSRect(x: vis.midX - size.width / 2, y: vis.maxY - vis.height / 3, width: size.width, height: size.height))
    }

    /// The list opened or closed. After a capture the card is placed again under the region (ShotRules.stripPlace:
    /// the top edge stays while the list fits under it, else the bottom edge, never over the picture where it can);
    /// at a caret the strip keeps its top edge and the list grows down (pushed up at the screen's foot).
    private func resize() {
        let size = view.fit()
        if let last = pics.last, let r = last.region,
           let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) }) ?? NSScreen.screens.first(where: { $0.frame.intersects(r) }) {
            setCard(ShotRules.stripPlace(size, region: r, full: last.full, screen: scr.visibleFrame))
            return
        }
        let vis = (NSScreen.screens.first { $0.frame.intersects(card) } ?? NSScreen.main)?.visibleFrame ?? card
        setCard(ShotRules.stripGrow(NSRect(x: card.minX, y: card.minY, width: size.width, height: card.height), to: size.height, screen: vis))
    }

    /// A voice take's text (Right Option held while the strip is open).
    func heard(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOpen, !t.isEmpty else { return }
        if mode == .person { line = t; search(); view.needsDisplay = true; return }
        if mode == .list { mode = .note; resize() }
        line = line.isEmpty ? t : line + " " + t
        noteVia = "voice"
        view.needsDisplay = true
        log("shot: note by voice, \(t.count) chars")
    }

    // MARK: keys

    /// A key from the event tap while the strip is open.
    func key(_ code: Int, _ ch: String, cmd: Bool) {
        if Talk.shared.state == .listening, code == 53 { Talk.shared.cancel(); return }   // esc drops the spoken note first
        switch mode {
        case .note: noteKey(code, ch, cmd: cmd)
        case .list: listKey(code)
        case .person: personKey(code, ch, cmd: cmd)
        }
    }

    private func type(_ code: Int, _ ch: String, cmd: Bool) -> Bool {
        if code == 51 { if !line.isEmpty { line.removeLast() }; return true }
        if !cmd, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), line.count < 400 { line += ch; return true }
        return false
    }

    private func noteKey(_ code: Int, _ ch: String, cmd: Bool) {
        if let k = ShotRules.stripPick(code: code, cmd: cmd, picked: picked, count: pics.count) {
            switch k {
            case .pick(let i): picked = i
            case .remove(let i): remove(i)
            }
            view.needsDisplay = true; return
        }
        switch ShotRules.strip(code: code, cmd: cmd, line: line) {
        case .markup: markup(picked ?? pics.count - 1)
        case .addAnother: addAnother()
        case .sendList: openList()
        case .note(let n):
            if code == 53 || cmd { send(n) } else { putIn(n) }
        case .typing:
            if type(code, ch, cmd: cmd), noteVia == "voice", line.isEmpty { noteVia = "typed" }
            view.needsDisplay = true
        }
    }

    private func openList() {
        note = line
        list = ShotPack.order(last: ShotTarget(rawValue: Drafter.shared.settings.shotLast))
        sel = 0; mode = .list; save(); resize()
    }

    /// A strip button clicked: as its key.
    func press(_ b: ShotRules.StripButton) {
        switch b {
        case .putIn: noteKey(36, "", cmd: false)
        case .markup: markup(picked ?? pics.count - 1)
        case .add: addAnother()
        case .send: if mode == .note { openList() } else { mode = .note; line = note; chats = []; resize() }
        case .speak: break                          // held on the keyboard; the tip says so
        case .picture: send(.picture)
        }
    }
    func pickThumb(_ i: Int) { picked = picked == i || pics.count < 2 ? nil : i; view.needsDisplay = true }
    func pickRow(_ i: Int) {
        if mode == .list, list.indices.contains(i) { pick(list[i]) }
        else if mode == .person, chats.indices.contains(i) { draft(chats[i]) }
    }

    private func listKey(_ code: Int) {
        switch ShotPack.listKey(code: code, sel: sel, count: list.count) {
        case .pick(let i): pick(list[i])
        case .move(let i): sel = i; view.needsDisplay = true
        case .back: mode = .note; line = note; resize()
        case .none: break
        }
    }

    private func personKey(_ code: Int, _ ch: String, cmd: Bool) {
        // digits pick a chat only once there are chats; before that they are part of the name
        if !chats.isEmpty || !ShotPack.digitCodes.contains(code) {
            switch ShotPack.listKey(code: code, sel: sel, count: chats.count) {
            case .pick(let i): draft(chats[i]); return
            case .move(let i): sel = i; view.needsDisplay = true; return
            case .back: mode = .list; line = note; chats = []; sel = 0; resize(); return
            case .none: break
            }
        }
        if type(code, ch, cmd: cmd) { search() }
        view.needsDisplay = true
    }

    /// The name search, 0.3 s after the last key, read only.
    private func search() {
        searchGen += 1
        let gen = searchGen, name = line.trimmingCharacters(in: .whitespaces)
        chats = []; sel = 0
        guard name.count >= 2 else { searching = false; resize(); return }
        searching = true; resize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard gen == self.searchGen, self.mode == .person else { return }
            ShotSend.chats(name) { found in
                guard gen == self.searchGen, self.mode == .person else { return }
                self.chats = Array(found.prefix(6)); self.searching = false; self.sel = 0
                log("shot: person search, \(self.chats.count) chats")
                self.resize()
            }
        }
    }

    // MARK: the set: another picture, taking one out

    /// ⌘N: the strip goes, the screen dims again; the next capture joins this set (`append`), esc brings the strip back.
    func addAnother() {
        guard pack != nil else { return }
        if mode != .note { mode = .note; line = note }
        save()
        collecting = true
        close()
        log("shot: add another, \(pics.count) so far")
        DispatchQueue.main.async { Capture.shared.open() }
    }
    /// The capture was dropped while collecting: the strip again, as it was.
    func resume() {
        guard collecting else { return }
        collecting = false
        show()
    }
    /// The next picture of the set.
    func append(png: Data, region: NSRect?, full: Bool, inPlace: Bool) {
        collecting = false
        pics.append(Self.pic(png, region: region, full: full, inPlace: inPlace))
        picked = nil
        save(pictures: true)
        if let id = pack?.id { readPicture(png, id: id, first: false) }
        log("shot: picture \(pics.count) added")
        if inPlace, region != nil { markup(pics.count - 1); return }
        show()
    }
    private func remove(_ i: Int) {
        guard pics.count > 1, pics.indices.contains(i) else { return }
        pics.remove(at: i)
        picked = nil
        save(pictures: true)
        _ = view.fit(); resize()
        log("shot: picture taken out, \(pics.count) left")
    }

    // MARK: markup

    func markup(_ i: Int) {
        guard pics.indices.contains(i) else { return }
        panel.orderOut(nil)
        let pc = pics[i]
        let scr = pc.region.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) }
        // in place only where the picture still is on the screen: a fresh region capture
        let region = pc.inPlace ? pc.region : nil
        MarkupEditor.shared.open(pc.original ?? pc.png, near: scr, marks: pc.marks, region: region) { marked in
            if let marked, self.pics.indices.contains(i) {
                // the marked picture is the one that goes in; the capture stays on the tape as it was
                let m = MarkupEditor.shared.model
                var p = self.pics[i]
                if p.original == nil { p.original = p.png }
                p.marks = m.marks
                let size = NSBitmapImageRep(data: marked).map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
                _ = History.addPicture(marked, width: size.0, height: size.1, app: self.origin?.localizedName ?? "", shot: self.pack?.id)
                p.png = marked; p.thumb = NSImage(data: marked)
                p.shot.marks = m.shotMarks; p.shot.crop = m.shotCrop; p.shot.width = size.0; p.shot.height = size.1
                p.inPlace = false   // marked once: ⌘E again opens the panel over the original
                self.pics[i] = p
                self.save(pictures: true)
                log("shot: marked, \(m.marks.count) marks")
            } else if self.pics.indices.contains(i) {
                self.pics[i].inPlace = false
            }
            if MarkupEditor.shared.addAfter { self.addAnother(); return }
            self.show()
        }
    }

    // MARK: ↵ put in, ⌘↵ and esc as before

    /// ↵: by the field's kind. An ordinary field keeps today's way (`send`).
    private func putIn(_ n: ShotRules.Note) {
        guard let p0 = pack else { send(n); return }
        let bundle = origin?.bundleIdentifier ?? ""
        let way = ShotPack.fieldWay(bundle: bundle, ai: Keys.aiApps)
        if way == .other { send(n); return }
        close(); save()
        let id = p0.id, pngs = self.pngs, origin = self.origin
        withRead {
            guard let p = self.pack, p.id == id else { return }
            let put = p.fieldPut(way, path: ShotStore.pngURL(id).path, md: ShotStore.mdURL(id).path)
            let ok = way == .terminal ? Capture.terminalTarget(origin) : Capture.target(origin)
            if !ok {
                if put.picture { ShotSend.clipboard(pngs, text: put.text ?? "") } else { History.copy(put.text ?? "") }
                Pill.shared.flash(put.picture ? "Picture and text on the clipboard" : "Text on the clipboard · ⌘V to paste")
                log("shot: put in failed, on the clipboard")
                return
            }
            ShotSend.paste(pictures: put.picture ? pngs : [], text: put.text)
            ShotStore.sent(id, .field)
            log("shot: put in (\(way)), \(pngs.count) pictures, \(put.text?.count ?? 0) chars, \(Int(Date().timeIntervalSince(self.t0) * 1000)) ms after release")
        }
    }

    private func send(_ n: ShotRules.Note) {
        close(); save()
        let read = pack?.read ?? ""
        let d = ShotRules.delivery(n, read: read)
        if case .pictureAndText = n, d.text == nil {
            // not read yet: read it now (or wait for the shot's read), then go on
            if pack != nil { withRead { self.deliver(ShotRules.delivery(n, read: self.pack?.read ?? "")) }; return }
            let png = self.png
            DispatchQueue.global(qos: .userInitiated).async {
                let t = CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(Screen.read) ?? ""
                DispatchQueue.main.async { self.deliver(ShotRules.delivery(n, read: t)) }
            }
            return
        }
        deliver(d)
    }

    private func deliver(_ d: ShotRules.Delivery) {
        let t1 = Date(), pngs = self.pngs
        if !Capture.target(origin) {
            // no field: the pictures and the text on the clipboard, so ⌘V somewhere gives the picture and the text stays with it
            if pngs.count > 1 { ShotSend.clipboard(pngs, text: d.text ?? "") }
            else { let png = self.png; History.copy(d.text ?? "") { pb in Capture.pictureWriter(png)(pb); if let t = d.text { pb.setString(t, forType: .string) } } }
            Pill.shared.flash(d.text == nil ? "The field takes no picture · it is on the clipboard" : "Picture and text on the clipboard")
            log("capture: note on the clipboard")
            return
        }
        if let id = pack?.id { ShotStore.sent(id, .field) }
        let total = Int(t1.timeIntervalSince(t0) * 1000)
        if pngs.count > 1 { ShotSend.paste(pictures: pngs, text: d.text); log("capture: \(pngs.count) pictures pasted, \(total) ms after release"); return }
        Focus.paste("", write: Capture.pictureWriter(png))
        guard let text = d.text else { log("capture: picture pasted, \(total) ms after release"); return }
        let origin = self.origin
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(d.gapMs)) {
            let how = Capture.put(text: text, origin: origin)
            log("capture: picture and \(text.count) chars (\(how)), picture \(total) ms after release")
        }
    }

    // MARK: ⇥ the send-to list

    private func pick(_ t: ShotTarget) {
        guard let p0 = pack else { return }
        if t == .person {
            mode = .person; line = ""; chats = []; sel = 0; searching = false; resize(); return
        }
        close(); save()
        let id = p0.id, pngs = self.pngs
        withRead {
            let p = self.pack?.id == id ? self.pack! : p0
            let path = ShotStore.pngURL(id).path, md = ShotStore.mdURL(id).path
            switch t {
            case .clipboard:
                ShotSend.clipboard(pngs, text: p.agentText(path: path, screenText: false))
                Pill.shared.flash(pngs.count > 1 ? "\(pngs.count) pictures and the text on the clipboard" : "Picture and text on the clipboard")
                ShotStore.sent(id, t)
            case .file:
                // the pictures are written on the shots queue: copy after them
                ShotStore.queue.async {
                    DispatchQueue.main.async {
                        guard let name = ShotSend.file(id, t: p.t, count: pngs.count) else { Pill.shared.flash("The file could not be saved"); return }
                        Pill.shared.flash("Saved · " + name)
                        ShotStore.sent(id, t, detail: name)
                    }
                }
            case .claude, .codex, .aleph:
                guard let b = ShotPack.appBundle(t, aleph: ShotSend.alephBundle), NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil else {
                    ShotSend.clipboard(pngs, text: p.agentText(path: path, screenText: false))
                    Pill.shared.flash("\(t.word) is not on this Mac · picture and text on the clipboard")
                    return
                }
                ShotSend.bringForward(b) { ok in
                    guard ok else {
                        ShotSend.clipboard(pngs, text: p.agentText(path: path, screenText: false))
                        Pill.shared.flash("\(t.word) did not come up · picture and text on the clipboard"); return
                    }
                    ShotSend.paste(pictures: pngs, text: p.agentText(path: nil))
                    ShotStore.sent(id, t)
                }
            case .claudeCode:
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let running = [front].compactMap { $0 } + NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                let b = ShotPack.claudeCodeApp(running: running)
                let text = ShotPack.terminals.contains(b) ? p.terminalLine(path: path, md: md) : p.agentText(path: path, screenText: false)
                ShotSend.bringForward(b) { ok in
                    guard ok else { History.copy(text); Pill.shared.flash("Text on the clipboard · ⌘V to paste"); return }
                    ShotSend.paste(picture: nil, text: text)
                    ShotStore.sent(id, t)
                }
            case .ask:
                // shot.md holds the read text once the queue wrote it
                ShotStore.queue.async { DispatchQueue.main.async { ShotSend.ask(id); ShotStore.sent(id, t) } }
            case .field, .person: break
            }
        }
    }

    private func draft(_ chat: (id: String, title: String)) {
        guard let p = pack else { return }
        mode = .note; line = note
        close(); save()
        let id = p.id, more = pics.count > 1
        ShotStore.queue.async {
            DispatchQueue.main.async {
                // `beeper chats draft` takes one --file: a set goes as a draft with its first picture
                ShotSend.draft(chat: chat.id, id: id, note: self.note) { ok in
                    Pill.shared.flash(ok ? "Draft in Beeper → \(chat.title) (not sent)\(more ? " · the first picture only" : "")" : "The Beeper draft did not work")
                    if ok { ShotStore.sent(id, .person, detail: chat.title) } else { log("shot: beeper draft failed") }
                }
            }
        }
    }
}

final class CaptureNoteView: NSView {
    weak var model: CaptureNote?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // key and strip round (15 November 2026, Andrii: bigger): strip 44 → 60, rows 32 → 44, thumbnails 44×30 → 64×42,
    // 42 pt buttons (ShotRules.pillButton), the note at 16 pt
    static let stripH: CGFloat = 60, pad: CGFloat = 16, tipRoom: CGFloat = 40, lineW: CGFloat = 300, rowH: CGFloat = 44
    static let thumbW: CGFloat = 64, thumbH: CGFloat = 42, noteFont: CGFloat = 16, rowFont: CGFloat = 16, rowIcon: CGFloat = 24
    static var H: CGFloat { stripH + 2 * pad + tipRoom }
    static let buttonGroups: [[ShotRules.StripButton]] = [[.putIn, .markup, .add], [.send, .speak], [.picture]]

    /// The panel round a card (AppKit points): the shadow's pad, and room above it for a button's tip.
    static func panelFrame(_ card: NSRect) -> NSRect {
        NSRect(x: card.minX - pad, y: card.minY - pad, width: card.width + 2 * pad, height: card.height + 2 * pad + tipRoom)
    }
    /// The card inside the view (flipped).
    var cardRect: NSRect { NSRect(x: Self.pad, y: Self.pad + Self.tipRoom, width: bounds.width - 2 * Self.pad, height: bounds.height - 2 * Self.pad - Self.tipRoom) }

    /// The rows under the strip: the targets, or the chats found for a name (one muted row while it searches).
    struct Row { var key: String; var word: String; var cloud: Bool; var glyph: String?; var icon: NSImage? }
    private var rows: [Row] {
        guard let m = model else { return [] }
        switch m.mode {
        case .note: return []
        case .list: return m.list.enumerated().map { Row(key: "\($0.offset + 1)", word: $0.element.word, cloud: $0.element.cloud, glyph: $0.element.glyph, icon: ShotIcons.icon($0.element)) }
        case .person:
            if m.chats.isEmpty { return [Row(key: "", word: m.searching ? "…" : m.line.count < 2 ? "" : "No chat", cloud: false, glyph: "user", icon: nil)] }
            return m.chats.enumerated().map { Row(key: "\($0.offset + 1)", word: $0.element.title, cloud: false, glyph: "user", icon: nil) }
        }
    }

    private var thumbsW: CGFloat { let n = CGFloat(model?.pics.count ?? 1); return n * Self.thumbW + (n - 1) * 5 }
    private var buttonsW: CGFloat { ShotRules.pillSize(Self.buttonGroups.map { $0.map { _ in ShotRules.pillButton } }, pad: 0).width }

    /// The card's size; the view's frame follows (pad and tip room round it).
    func fit() -> NSSize {
        let w = 9 + thumbsW + 12 + Self.lineW + 12 + buttonsW + 9
        let n = rows.count
        let h = Self.stripH + (n > 0 ? 6 + CGFloat(n) * Self.rowH + 8 : 0)
        frame = NSRect(x: 0, y: 0, width: (w + 2 * Self.pad).rounded(), height: h + 2 * Self.pad + Self.tipRoom)
        return NSSize(width: w.rounded(), height: h)
    }

    // the parts, in view points
    func thumbRects() -> [NSRect] {
        let c = cardRect
        return (0..<(model?.pics.count ?? 0)).map { NSRect(x: c.minX + 9 + CGFloat($0) * (Self.thumbW + 5), y: c.minY + (Self.stripH - Self.thumbH) / 2, width: Self.thumbW, height: Self.thumbH) }
    }
    func buttonPill() -> ShotRules.Pill {
        let c = cardRect
        return ShotRules.pill(Self.buttonGroups.map { $0.map { _ in ShotRules.pillButton } }, at: CGPoint(x: c.maxX - 9 - buttonsW, y: c.minY + ((Self.stripH - ShotRules.pillButton) / 2).rounded()), pad: 0)
    }
    func rowRects() -> [NSRect] {
        let c = cardRect
        return rows.indices.map { NSRect(x: c.minX + 8, y: c.minY + Self.stripH + 6 + CGFloat($0) * Self.rowH, width: c.width - 16, height: Self.rowH) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h = ShotRules.hitItem(p, buttonPill().items)
        if h != model?.hover { model?.hover = h; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { if model?.hover != nil { model?.hover = nil; needsDisplay = true } }
    override func mouseDown(with e: NSEvent) {
        guard let m = model else { return }
        let p = convert(e.locationInWindow, from: nil)
        if let i = ShotRules.hitItem(p, buttonPill().items), let b = ShotRules.StripButton(rawValue: i) { m.press(b); return }
        if let i = thumbRects().firstIndex(where: { $0.contains(p) }) { m.pickThumb(i); return }
        if let i = rowRects().firstIndex(where: { $0.contains(p) }) { m.pickRow(i); return }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { "Screenshot: " + ShotRules.StripButton.allCases.map(\.word).joined(separator: ", ") }

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let card = cardRect
        NSGraphicsContext.saveGraphicsState()
        PK.floatShadow().set(); PK.card.setFill(); NSBezierPath(roundedRect: card, xRadius: PK.corner(3), yRadius: PK.corner(3)).fill()
        NSGraphicsContext.restoreGraphicsState()
        TapeDraw.surface(card)
        let strip = NSRect(x: card.minX, y: card.minY, width: card.width, height: Self.stripH)
        // the set's pictures; the picked one ringed
        let trs = thumbRects()
        for (i, r) in trs.enumerated() {
            if let t = m.pics[i].thumb { _ = TapeDraw.picture(t, in: r) }
            if m.picked == i {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), xRadius: 5, yRadius: 5)
                PK.blue.setStroke(); ring.lineWidth = 1.5; ring.stroke()
            }
        }
        var x = (trs.last?.maxX ?? card.minX + 9) + 12
        let f = PK.text(Self.noteFont), mid = strip.midY
        let empty = m.line.isEmpty
        let a = TapeDraw.at(f, empty ? PK.faint : (m.mode == .list ? PK.muted : PK.ink), cut: .byTruncatingHead)
        let shown = empty ? (m.mode == .person ? "Who?" : "What is this?") : m.line
        TapeDraw.line(shown, NSRect(x: x, y: TapeDraw.lineTop(f, mid: mid), width: Self.lineW, height: 24), a)
        if m.mode != .list, m.picked == nil {
            PK.blue.setFill()
            NSRect(x: x + (empty ? 0 : min(Self.lineW, TapeDraw.width(m.line, a) + 1)), y: mid - 11, width: 2, height: 22).fill()
        }
        x += Self.lineW + 12
        // the keys as glyph buttons (the key small under each, the word in the tip)
        let bp = buttonPill()
        for d in bp.dividers { PK.line.setFill(); NSRect(x: d.rounded() - 0.5, y: strip.minY + 16, width: 1, height: Self.stripH - 32).fill() }
        let faces = ShotRules.StripButton.allCases.map { b -> PillFace in
            var f = PillFace(glyph: b.glyph, key: b.key, word: b.word)
            f.on = b == .send && m.mode != .note
            f.primary = b == .putIn && m.mode == .note
            return f
        }
        for (i, r) in bp.items.enumerated() { ShotPill.button(faces[i], r, hover: m.hover == i) }
        if let h = m.hover, h < faces.count { ShotPill.tip(faces[h], over: bp.items[h], bar: strip, bounds: bounds) }

        // the list: the target's icon (the app's own when it is on this Mac), its word, the digit, the cloud mark
        let rs = rows
        guard !rs.isEmpty else { return }
        TapeDraw.hairline(x0: card.minX, x1: card.maxX, y: strip.maxY)
        for (i, (r, rr)) in zip(rs, rowRects()).enumerated() {
            if i == m.sel, !r.key.isEmpty {
                TapeDraw.lift.setFill(); NSBezierPath(roundedRect: rr, xRadius: PK.corner(2), yRadius: PK.corner(2)).fill()
            }
            let rmid = rr.midY
            let ir = NSRect(x: rr.minX + 10, y: rmid - Self.rowIcon / 2, width: Self.rowIcon, height: Self.rowIcon)
            if let icon = r.icon { icon.draw(in: ir.insetBy(dx: -1, dy: -1), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]) }
            else if let g = r.glyph { TapeDraw.glyph(g, ir, color: i == m.sel ? PK.ink : PK.muted) }
            let rx = ir.maxX + 12
            let wa = TapeDraw.at(PK.text(Self.rowFont), r.key.isEmpty ? PK.muted : PK.ink)
            TapeDraw.line(r.word, NSRect(x: rx, y: TapeDraw.lineTop(PK.text(Self.rowFont), mid: rmid), width: rr.maxX - rx - 72, height: 24), wa)
            var kx = rr.maxX - 12
            if !r.key.isEmpty {
                let ka = TapeDraw.at(PK.mono(12), PK.faint), kw = TapeDraw.width(r.key, ka)
                (r.key as NSString).draw(at: NSPoint(x: kx - kw, y: TapeDraw.lineTop(PK.mono(12), mid: rmid)), withAttributes: ka)
                kx -= kw + 12
            }
            if r.cloud { TapeDraw.glyph("cloud", NSRect(x: kx - 20, y: rmid - 10, width: 20, height: 20), color: PK.muted) }
        }
    }
}
