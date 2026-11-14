// The Quick panel (14 November 2026; Andrii: "a quicker interaction over the last typed words… a clipboard history…
// have Drafter read it and rewrite it… so that you can quickly copy stuff where it needs to go"). ⌃⌥V (setting
// `quickKey`; ⌃⌥Space and ⌘Space are Aleph's) opens a small panel on the caret's screen, centred in the upper third,
// over any app. It lists what he copied, typed (TypedList: one row per message) and said (voice takes), newest first,
// pins on top. The panel never becomes key: the app he is in stays in front with its caret, and the event tap hands
// the panel its keys while it is open (Keys.handle calls `tap`), as the ⌥Tab rework list does.
//
// Keys: type to narrow (ranked by match, freshness and what he put in before: QuickRules.score, data/quick-stats.json)
// · ↑ ↓ · ⏎ put it at his caret and close · ⌘⏎ put it and stay · ⌘C copy · esc close · ⌘1 all ⌘2 copied ⌘3 typed
// ⌘4 voice · ⌘P pin / unpin · ⌘⌫ remove from history (⌘Z brings it back while the line says so) · ⇥ rewrite: three
// instant ones on this Mac (plain text, one line, as a quote) and the rework list (engine /rework: Claude only when he
// picks one and `rework` is on, else the local model). The result shows below; ⏎ puts it, ⌫ goes back to his text.
// One tape (look round "Tape", 14 November): the chosen row unfolds in place to its text and its keys; rewrite unfolds
// under it. Drawing in QuickView below and app/TapeDraw.swift.
// The paste switcher (⌘⇧V, QuickSwitch below) is the lighter way in: copies only, hold and tap, let go to put.
//
// Putting text: AX insert or paste through Focus (the paste puts his clipboard back and is never kept as a copy).
// Never into skipped apps, password fields or under secure input: there the text goes to the clipboard instead.
// Rows live in memory, read once off the main thread at start and again when a history file changed.
import AppKit
import Carbon

final class Quick {
    static let shared = Quick()
    enum Mode { case list, rework }
    enum Run { case menu, working, result, failed }
    struct Cmd { let id: String; let name: String; var hint: String; let cloud: Bool }

    static let visibleRows = 8

    // rows
    private(set) var items: [QuickItem] = []      // merged: pins, then newest first
    private(set) var shown: [Int] = []            // indices into items after the query and the kind
    private var raw: [QuickItem] = []             // from the files
    private var drafts: [String: [String]] = [:]  // typed row text -> the drafts folded into it (removed with it)
    private var pins: [QuickPin] = []
    private(set) var uses = QuickUses()           // data/quick-stats.json: when he put which item in (ids and times)
    private var stamps: [String] = []
    private var loading = false, reloadAgain = false
    private var gone: (item: QuickItem, until: DispatchWorkItem)?   // removed, still undoable

    // what he sees
    private(set) var isOpen = false
    var held = false                              // opened by the switcher while ⌘⇧ are still down
    var query = ""
    var kind: QuickKind?
    var sel = 0, top = 0
    var mode = Mode.list
    var notice = ""
    // rewrite
    var cmds: [Cmd] = []
    var rsel = 0
    var custom = ""
    var run = Run.menu
    var result = "", resultName = "", resultBy = "", ms = 0
    private var seq = 0
    private var origin: NSRunningApplication?
    var now = Date().timeIntervalSince1970

    let panel: NSPanel
    let view = QuickView()

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: QuickView.size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.frame = NSRect(origin: .zero, size: QuickView.size)
        view.model = self
        panel.contentView = view
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close("app changed")
        }
    }

    var current: QuickItem? { sel < shown.count ? items[shown[sel]] : nil }

    // MARK: the event tap

    /// Both keys as one state (QuickRules.QuickKeys, tested with made-up event sequences).
    var keys = QuickKeys()
    private var keyNames = ("", "", "")
    private var captureName = "\u{0}", captureKey: QuickHotkey?

    /// From Keys.handle, for every event before anything else looks at it. true = swallowed.
    func tap(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let st = Drafter.shared.settings
        if keyNames != (st.quickKey, st.switchKey, st.againKey) {
            keyNames = (st.quickKey, st.switchKey, st.againKey)
            keys.panelKey = QuickRules.hotkey(st.quickKey); keys.switchKey = QuickRules.hotkey(st.switchKey)
            // never the same chord as another of Drafter's keys
            let again = QuickRules.hotkey(st.againKey)
            keys.againKey = [keys.panelKey, keys.switchKey, QuickRules.hotkey(st.captureKey)].contains { $0 != nil && $0 == again } ? nil : again
        }
        if type == .leftMouseDown || type == .rightMouseDown { keys.disarmSwap() }   // a click: the caret may have moved
        keys.panelOpen = isOpen
        // quick capture (app/Capture.swift): its key, and every key while the screen is dimmed
        if type == .keyDown, MarkupEditor.shared.isOpen || CaptureNote.shared.isOpen {   // markup, then the strip after a capture
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode)), fl = event.flags
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            let ch = String(utf16CodeUnits: u, count: n), cmd = fl.contains(.maskCommand), shift = fl.contains(.maskShift)
            DispatchQueue.main.async {
                if MarkupEditor.shared.isOpen { MarkupEditor.shared.key(code, ch, cmd: cmd, shift: shift) }
                else if CaptureNote.shared.isOpen { CaptureNote.shared.key(code, ch, cmd: cmd) }
            }
            return true
        }
        if type == .keyDown, Capture.shared.isOpen {
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            DispatchQueue.main.async { Capture.shared.key(code) }
            return true
        }
        if type == .keyDown {
            if captureName != st.captureKey { captureName = st.captureKey; captureKey = ShotRules.allowed(st.captureKey) ? QuickRules.hotkey(st.captureKey) : nil }
            let f = event.flags
            var c = QuickKeyEvent(kind: .down); c.code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            c.ctrl = f.contains(.maskControl); c.alt = f.contains(.maskAlternate); c.cmd = f.contains(.maskCommand); c.shift = f.contains(.maskShift)
            if QuickKeys.exact(c, captureKey) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { Capture.shared.open() } }
                return true
            }
        }
        if held, type == .flagsChanged, !event.flags.contains(.maskCommand) { held = false }
        let f = event.flags
        var e = QuickKeyEvent(kind: type == .keyDown ? .down : type == .flagsChanged ? .flags : .up)
        e.code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        e.ctrl = f.contains(.maskControl); e.alt = f.contains(.maskAlternate); e.cmd = f.contains(.maskCommand); e.shift = f.contains(.maskShift)
        e.autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        e.at = Date().timeIntervalSince1970
        if type == .keyDown || type == .flagsChanged {
            var swallowed = false, passOn = false
            for a in keys.route(e) {
                switch a {
                case .pass: passOn = true
                case .swallow: swallowed = true
                case .togglePanel: swallowed = true; DispatchQueue.main.async { self.toggle() }
                case .openSwitch: swallowed = true; DispatchQueue.main.async { QuickSwitch.shared.open() }
                case .step(let n): swallowed = true; DispatchQueue.main.async { QuickSwitch.shared.step(n) }
                case .put: DispatchQueue.main.async { QuickSwitch.shared.finish() }
                case .cancel: swallowed = true; DispatchQueue.main.async { QuickSwitch.shared.close("esc") }
                case .voiceAgain: swallowed = true; DispatchQueue.main.async { self.voiceAgain() }
                case .swap: swallowed = true; DispatchQueue.main.async { QuickSwitch.shared.swap() }
                case .toPanel(let code):
                    swallowed = true
                    var n = 0; var u = [UniChar](repeating: 0, count: 4)
                    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
                    var ch = String(utf16CodeUnits: u, count: n).lowercased()
                    if ch.unicodeScalars.first.map({ CharacterSet.controlCharacters.contains($0) }) ?? true {
                        ch = QuickRules.codes.first { $0.value == code }?.key.lowercased() ?? ""
                    }
                    DispatchQueue.main.async { QuickSwitch.shared.intoPanel(ch) }
                }
            }
            if swallowed && !passOn { return true }
            if type == .flagsChanged { return false }
        }
        guard isOpen else { return false }
        if type == .leftMouseDown || type == .rightMouseDown { DispatchQueue.main.async { self.close("click") }; return false }
        guard type == .keyDown else { return false }
        var n = 0; var u = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        return key(event.getIntegerValueField(.keyboardEventKeycode), String(utf16CodeUnits: u, count: n), mods)
    }

    // MARK: open and close

    func toggle() { isOpen ? close("key") : open() }

    func open(typed: String = "", held: Bool = false, choose: QuickItem? = nil, near: NSRect? = nil) {
        guard !isOpen else { return }
        self.held = held
        if IsSecureEventInputEnabled() { Pill.shared.flash("Quick panel is off while secure input is on"); return }
        let t0 = Date()
        origin = NSWorkspace.shared.frontmostApplication
        query = typed; kind = nil; sel = 0; top = 0; mode = .list; notice = ""; custom = ""; run = .menu; seq += 1
        now = Date().timeIntervalSince1970
        refilter()
        if let c = choose, let i = shown.firstIndex(where: { items[$0].same(c) }) { sel = i }
        Ghost.shared.hide(); Rework.shared.close("quick")
        place(near: near)
        view.needsDisplay = true
        panel.orderFrontRegardless()
        isOpen = true
        refresh()
        log("quick: open, \(items.count) rows, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    func close(_ why: String) {
        guard isOpen else { return }
        isOpen = false; seq += 1
        panel.orderOut(nil)
        commitGone()
        log("quick: closed (\(why))")
    }

    /// The caret's screen (the focused element's, else the mouse's), centred, in the upper third.
    private func place(near: NSRect? = nil) {
        if let near, let scr = NSScreen.screens.first(where: { $0.frame.intersects(near) }) {
            // in place of the switcher's strip: the same top-left corner, kept on its screen
            let vis = scr.visibleFrame, size = QuickView.size
            let x = min(max(near.minX, vis.minX + 8), vis.maxX - size.width - 8)
            let y = min(max(near.maxY - size.height, vis.minY + 8), vis.maxY - size.height - 8)
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
            return
        }
        var scr: NSScreen?
        if let app = origin, app.processIdentifier != getpid(), let el = Focus.focused() {
            AXUIElementSetMessagingTimeout(el, 0.08)
            if let r = Focus.frame(el) {
                let h = NSScreen.screens.first?.frame.height ?? 0
                let p = NSPoint(x: r.midX, y: h - r.midY)
                scr = NSScreen.screens.first { $0.frame.contains(p) }
            }
        }
        let mouse = NSEvent.mouseLocation
        let s = scr ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vis = s?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = QuickView.size
        let midY = vis.maxY - vis.height / 3
        let y = min(max(midY - size.height / 2, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrame(NSRect(x: vis.midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
    }

    // MARK: rows

    /// At start: pins and rows, off the main thread.
    func warm() {
        _ = QuickSwitch.shared   // its panel made now, not on his first ⌘⇧V
        DispatchQueue.global(qos: .utility).async {
            let p = Self.loadPins()
            let u = (try? Data(contentsOf: Self.statsFile)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.map(QuickUses.init) ?? QuickUses()
            DispatchQueue.main.async { self.pins = p; self.uses = u; self.refresh() }
        }
    }

    private static let pinsFile = Home.data.appendingPathComponent("quick-pins.json")
    private static let statsFile = Home.data.appendingPathComponent("quick-stats.json")
    /// He put `it` in: counted for the ranking (item and app ids, times; never the text).
    func used(_ it: QuickItem) {
        QuickRules.used(&uses, it, at: Date().timeIntervalSince1970)
        guard stamps != ["preview"] else { return }
        let j = uses.json
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: Self.statsFile, options: .atomic) }
        }
    }
    private static func loadPins() -> [QuickPin] {
        guard let d = try? Data(contentsOf: pinsFile), let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return a.compactMap(QuickPin.init)
    }
    private func savePins() {
        let rows = pins.map(\.json)
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? d.write(to: Self.pinsFile, options: .atomic) }
        }
    }

    /// Reads the history files again when one changed (size, time); the panel keeps showing the rows it has meanwhile.
    func refresh() {
        if loading { reloadAgain = true; return }
        loading = true
        let st = Drafter.shared.settings
        let have = stamps
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let fresh = Self.sources.map { files in files.map { u -> String in
                guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return "-" }
                return "\(a[.modificationDate] ?? "")/\(a[.size] ?? "")"
            }.joined(separator: "|") }
            var changed: [Int] = []
            for i in fresh.indices where have.count != fresh.count || have[i] != fresh[i] {
                self.readPart(i, max: st.quickMax, days: st.quickDays, secrets: QuickRules.secretRules(st.quickSecret))
                changed.append(i)
            }
            let rows = self.parts.flatMap { $0 }, folded = self.folded
            if !changed.isEmpty {
                log("quick: read \(changed.map { ["copied", "typed", "voice"][$0] }.joined(separator: "+")), \(rows.count) rows in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            }
            DispatchQueue.main.async {
                self.loading = false
                if !changed.isEmpty { self.raw = rows; self.drafts = folded; self.stamps = fresh; self.rebuild() }
                if self.reloadAgain { self.reloadAgain = false; self.refresh() }
            }
        }
    }

    // Touched only on the loading queue (one read at a time): each source's rows, and rows already built (folding the
    // text for search is most of the cost), so a new copy re-reads the clipboard file only and builds one new row.
    private static let sources = [[History.clipFile, History.clipsDir], [History.typedFile, History.draftsFile], [History.takesFile]]
    private var parts: [[QuickItem]] = [[], [], []]
    private var folded: [String: [String]] = [:]
    private var built: [String: QuickItem] = [:]
    private func item(_ kind: QuickKind, _ text: String, _ app: String, _ at: Double, image: Bool = false) -> QuickItem {
        let k = "\(kind.rawValue)|\(at)|\(app)|\(text)"
        if let it = built[k] { return it }
        let it = QuickItem(kind: kind, text: text, app: app, at: at, image: image)
        built[k] = it
        return it
    }

    /// Clipboard (trimmed as History keeps it), typed messages (drafts folded in), voice takes with words.
    private func readPart(_ i: Int, max: Int, days: Double, secrets: [NSRegularExpression]) {
        if built.count > 4 * max { built.removeAll() }
        switch i {
        case 0:
            let clipRows = History.read(History.clipFile, last: max)
            let pairs: [(t: Double, text: String)] = clipRows.reversed().map {
                ($0["t"] as? Double ?? 0, ClipRules.dedupeKey(text: $0["text"] as? String ?? "", clip: $0["clip"] as? String))
            }
            let keep = QuickRules.keepClips(pairs, now: Date().timeIntervalSince1970, max: max, days: days) { QuickRules.isSecret($0, secrets) }
            parts[0] = keep.map { k in clipItem(clipRows[clipRows.count - 1 - k]) }
        case 1:
            var f: [String: [String]] = [:]
            parts[1] = TypedList.build(sent: History.read(History.typedFile, last: max), drafts: History.read(History.draftsFile, last: max / 2))
                .filter { !$0.text.contains("⟦drafter-test⟧") }
                .map { e in
                    if !e.drafts.isEmpty { f[e.text] = e.drafts }
                    return item(.typed, e.text, e.app, (e.touched ?? e.when).timeIntervalSince1970)
                }
            folded = f
        default:
            parts[2] = History.read(History.takesFile, last: max).compactMap { r in
                guard let t = r["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return item(.voice, t, r["app"] as? String ?? "", r["t"] as? Double ?? 0)
            }
        }
    }

    /// One clipboard.jsonl row as a row on the tape (kind, title, size, the stored picture and its read text).
    /// Off the main thread, except for a new copy (no read text yet then).
    private func clipItem(_ r: [String: Any], read: Bool = true) -> QuickItem {
        let text = r["text"] as? String ?? "", app = r["app"] as? String ?? "", at = r["t"] as? Double ?? 0
        let pic = r["clip"] as? String ?? ""
        let ocr = read && !pic.isEmpty ? History.clipText(pic) : ""
        let k = "c|\(at)|\(app)|\(pic)|\(ocr.count)|\(text)"
        if let it = built[k] { return it }
        let it = QuickItem(kind: .copied, text: text, app: app, at: at, image: r["image"] != nil,
                           clip: (r["kind"] as? String).flatMap(ClipKind.init(rawValue:)), title: r["title"] as? String ?? "",
                           bytes: r["bytes"] as? Int ?? 0, picture: pic, ocr: ocr, rich: r["rich"] as? Bool ?? false)
        built[k] = it
        return it
    }

    /// A new copy (its clipboard.jsonl row), straight from History.watchClipboard: on the list at once, no file read.
    func copied(_ row: [String: Any]) {
        guard stamps != ["preview"] else { return }
        let r = row
        raw.insert(QuickItem(kind: .copied, text: r["text"] as? String ?? "", app: r["app"] as? String ?? "", at: r["t"] as? Double ?? 0,
                             image: r["image"] != nil, clip: (r["kind"] as? String).flatMap(ClipKind.init(rawValue:)),
                             title: r["title"] as? String ?? "", bytes: r["bytes"] as? Int ?? 0, picture: r["clip"] as? String ?? "",
                             rich: r["rich"] as? Bool ?? false), at: 0)
        rebuild()
    }

    /// Made-up rows (previews and the speed check): never his.
    func load(_ rows: [QuickItem], pins: [QuickPin] = []) { raw = rows; self.pins = pins; stamps = ["preview"]; rebuild() }

    private func rebuild() {
        let keep = current
        var rows = raw
        if let g = gone?.item { rows.removeAll { $0.same(g) } }
        items = QuickRules.merge(rows, pins: pins.filter { p in gone.map { !($0.item.kind == p.kind && $0.item.text == p.text) } ?? true })
        refilter(keep: keep)
    }

    func refilter(keep: QuickItem? = nil) {
        shown = QuickRules.filter(items, query: query, kind: kind, uses: uses, now: Date().timeIntervalSince1970)
        if let keep, let i = shown.firstIndex(where: { items[$0].same(keep) }) { sel = i } else { sel = min(sel, max(0, shown.count - 1)) }
        if keep == nil { sel = 0 }
        scroll()
        if isOpen { view.needsDisplay = true }
    }

    /// The rows in view: the chosen row (it unfolds in place) stays whole in view, the rest stay put when they can.
    private func scroll() { top = view.fitTop(self) }

    // MARK: keys

    /// A key while the panel is open (on the tap). true = swallowed; false = it goes on to the app (the panel closed).
    func key(_ code: Int64, _ ch: String, _ mods0: CGEventFlags) -> Bool {
        // opened from the paste switcher with ⌘⇧ still held: those keys are typing until he lets go
        let mods = held ? mods0.subtracting([.maskCommand, .maskShift]) : mods0
        let cmd = mods.contains(.maskCommand), plain = mods.subtracting(.maskShift).isEmpty
        // round three: the chosen row's own keys (⌘O open, ⌘M markdown, ⌘T no tracking / copy text, ⌘R reveal, ⌘S save,
        // ⌘C copy path for a file)
        if cmd, mode == .list, !mods.contains(.maskControl), let it = current,
           let a = actions(it).first(where: { Self.keyCodes[$0.key] == code }) {
            DispatchQueue.main.async { self.act(a.id, it) }
            return true
        }
        if mods.contains(.maskControl) || (cmd && ![36, 76, 8, 6, 35, 51, 18, 19, 20, 21].contains(code)) {
            DispatchQueue.main.async { self.close("shortcut") }; return false
        }
        if mode == .rework { reworkKey(code, ch, cmd: cmd, plain: plain); scroll(); view.needsDisplay = true; return true }
        // "@name" or "context for name": ⏎ puts the entity's context in, ⌘C copies it (app/Entities.swift)
        if [36, 76].contains(code) || (code == 8 && cmd), !query.isEmpty, let d = Entities.door(query) {
            let put = code != 8
            DispatchQueue.main.async { self.close("context"); Entities.doorTake(d.text, what: d.what, put: put) }
            return true
        }
        switch code {
        case 53: DispatchQueue.main.async { self.close("esc") }
        case 126: move(-1)
        case 125: move(1)
        case 116: move(-Self.visibleRows)
        case 121: move(Self.visibleRows)
        case 36, 76 where mods.contains(.maskShift) && current?.clip == .image:   // ⇧↵ a picture with its read text
            if let it = current { DispatchQueue.main.async { self.act("withText", it) } }
        case 36, 76: if let it = current { let keep = cmd; DispatchQueue.main.async { self.put(it, it.text, keep: keep) } }
        case 48: if plain, let it = current { openRework(it) }
        case 51:
            if cmd { remove() }
            else if mods.contains(.maskAlternate) { dropWord() }
            else if !query.isEmpty { query.removeLast(); refilter() }
        case 6 where cmd: undo()
        case 8 where cmd: if let it = current { copy(it, it.text) }
        case 35 where cmd: pin()
        case 18, 19, 20, 21 where cmd:
            kind = [nil, .copied, .typed, .voice][Int(code - 18)]; sel = 0; top = 0; refilter()
        case 123, 124, 115, 119: break
        default:
            if !cmd, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), query.count < 200 {
                query += ch; sel = 0; top = 0; refilter()
                if let h = Entities.doorHint(query) { notice = h }
            }
        }
        view.needsDisplay = true
        return true
    }

    private func move(_ by: Int) {
        guard !shown.isEmpty else { return }
        sel = max(0, min(shown.count - 1, sel + by)); scroll()
    }

    private func dropWord() {
        while query.last == " " { query.removeLast() }
        while let l = query.last, l != " " { query.removeLast() }
        refilter()
    }

    // MARK: kinds (round three: links, files, pictures)

    static let keyCodes: [String: Int64] = ["⌘O": 31, "⌘M": 46, "⌘T": 17, "⌘R": 15, "⌘S": 1, "⌘C": 8]
    /// What the row points at: itself, or the first link or path in a text.
    func target(_ it: QuickItem) -> (kind: ClipKind, value: String)? {
        switch it.clip {
        case .text: return ClipRules.firstTarget(in: it.text)
        case .image: return it.picture.isEmpty ? nil : (.image, History.clipURL(it.picture).path)
        default: return (it.clip, it.text)
        }
    }
    func actions(_ it: QuickItem) -> [ClipRules.Action] {
        if it.clip == .image && it.picture.isEmpty { return [] }
        return it.clip == .text ? ClipRules.actions(.text, target: target(it)?.kind) : ClipRules.actions(it.clip)
    }
    private func fileURL(_ v: String) -> URL { URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }

    /// The pasteboard writer for a file or a picture (nil: the row goes in as text).
    func writer(_ it: QuickItem) -> ((NSPasteboard) -> Void)? {
        switch it.clip {
        case .file:
            let paths = it.text.split(separator: "\n").map { fileURL(String($0)) } as [NSURL]
            return { pb in pb.writeObjects(paths) }
        case .image where !it.picture.isEmpty:
            let u = History.clipURL(it.picture)
            guard let d = try? Data(contentsOf: u) else { return nil }
            return { pb in
                pb.setData(d, forType: .png)
                if let rep = NSBitmapImageRep(data: d), let t = rep.tiffRepresentation { pb.setData(t, forType: .tiff) }   // apps that take only TIFF
            }
        default: return nil
        }
    }

    func act(_ id: String, _ it: QuickItem) {
        guard let (k, v) = target(it) else { return }
        func copied(_ s: String, _ what: String) { close("copy"); History.copy(s); Pill.shared.flash("\(what) copied · ⌘V to paste") }
        switch id {
        case "open":
            close("open")
            if k == .link, let u = URL(string: v) { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.open(fileURL(v)) }
        case "markdown": copied(ClipRules.markdown(v, title: it.clip == .link ? it.title : ""), "Markdown link")
        case "untracked": copied(ClipRules.untracked(v), "Link without tracking")
        case "reveal": close("reveal"); NSWorkspace.shared.activateFileViewerSelecting([fileURL(v)])
        case "path": copied(v, "Path")
        case "text":
            let t = it.ocr.isEmpty ? History.clipText(it.picture) : it.ocr
            if t.isEmpty { notice = "No text read in this picture yet"; view.needsDisplay = true } else { copied(t, "Text") }
        case "withText":
            let t = it.ocr.isEmpty ? History.clipText(it.picture) : it.ocr
            let from = origin
            put(it, it.text, keep: false)
            if !t.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { Capture.put(text: t, origin: from) } }
        case "save":
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let to = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Drafter \(f.string(from: Date(timeIntervalSince1970: it.at))).png")
            do { try FileManager.default.copyItem(at: fileURL(v), to: to); close("save"); Pill.shared.flash("Saved to Desktop") }
            catch { notice = "Could not save to Desktop"; view.needsDisplay = true }
        default: break
        }
        log("quick: \(id) on a \(it.clip.rawValue) row")
    }

    // MARK: actions

    /// Puts `text` where his caret was. keep: the panel stays for the next one (the panel never took the focus, so the
    /// paste reaches his app either way).
    /// asIs (the switcher keeping formatting): the app gets a plain ⌘V of what is on the clipboard already.
    /// Returns how it went in; nil: it went to the clipboard instead (or nowhere).
    @discardableResult
    func put(_ it: QuickItem, _ text: String, keep: Bool, from: NSRunningApplication? = nil, asIs: Bool = false) -> String? {
        if it.image && it.picture.isEmpty { notice = "Only the size of this image was kept"; view.needsDisplay = true; return nil }
        let object = writer(it)
        if !keep { close("put") }
        let st = Drafter.shared.settings
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == (from ?? origin)?.processIdentifier,
              front.processIdentifier != getpid(), !st.skip.contains(front.bundleIdentifier ?? ""), !IsSecureEventInputEnabled() else {
            copy(it, text); return nil
        }
        let (spot, why) = Focus.spot(skip: st.skip)
        let how: String
        if let object, spot != nil || Focus.pasteTarget(why) { Focus.paste("", write: object); how = "paste \(it.clip.rawValue)" }
        else if object != nil { copy(it, text); return nil }
        else if asIs, spot != nil || Focus.pasteTarget(why) { Self.commandV(); how = "⌘V" }
        else if let spot { how = Focus.insert(text, at: spot) }
        else if Focus.pasteTarget(why) { Focus.paste(text); how = "paste" }
        else { copy(it, text); return nil }
        used(it)
        if keep, isOpen { notice = "Put in · \(text.count) characters"; view.needsDisplay = true }
        log("quick: put \(it.kind.rawValue), \(text.count) chars, \(how) in \(front.bundleIdentifier ?? "?")")
        return how
    }

    /// ⌃⌥R (setting `againKey`, keys round): the newest voice take goes in again at the caret, through `put` (never
    /// into skipped apps, password fields or under secure input: there it goes to the clipboard).
    func voiceAgain() {
        let from = NSWorkspace.shared.frontmostApplication
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = History.read(History.takesFile, last: 20).map { (text: $0["text"] as? String ?? "", outcome: $0["outcome"] as? String ?? "") }
            let text = KeyRules.lastTake(rows)
            DispatchQueue.main.async {
                guard let text else { Pill.shared.flash("No voice take yet"); log("voice again: no take"); return }
                let how = self.put(QuickItem(kind: .voice, text: text, app: "", at: 0), text, keep: true, from: from)
                log("voice again: \(text.count) chars, \(how ?? "copied")")
            }
        }
    }

    /// ⌘V into the front app, marked as Drafter's own so the tap lets it through.
    static func commandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand; e?.setIntegerValueField(.eventSourceUserData, value: Focus.mark); e?.post(tap: .cghidEventTap)
        }
    }

    private func copy(_ it: QuickItem, _ text: String) {
        if it.image && it.picture.isEmpty { notice = "Only the size of this image was kept"; view.needsDisplay = true; return }
        close("copy")
        History.copy(text, write: writer(it))
        Pill.shared.flash("Copied · ⌘V to paste")
        log("quick: copied \(it.kind.rawValue), \(text.count) chars")
    }

    private func pin() {
        guard let it = current else { return }
        if it.pinned { pins.removeAll { $0.kind == it.kind && $0.text == it.text }; notice = "Unpinned" }
        else { pins.insert(QuickPin(kind: it.kind, text: it.text, app: it.app, at: it.at), at: 0); notice = "Pinned" }
        savePins(); rebuild()
    }

    /// The window's ⌘P on a row (Window.swift): the same pins as the panel's.
    func isPinned(_ kind: QuickKind, _ text: String) -> Bool { pins.contains { $0.kind == kind && $0.text == text } }
    func togglePin(_ kind: QuickKind, _ text: String, app: String, at: Double) {
        if isPinned(kind, text) { pins.removeAll { $0.kind == kind && $0.text == text } }
        else { pins.insert(QuickPin(kind: kind, text: text, app: app, at: at), at: 0) }
        if stamps != ["preview"] { savePins() }
        rebuild()
    }

    /// ⌘⌫: off the list at once; out of the files when the undo line is gone (8 s, the next removal, or the panel closing).
    private func remove() {
        guard let it = current else { return }
        commitGone()
        let w = DispatchWorkItem { [weak self] in self?.commitGone(); self?.notice = ""; self?.view.needsDisplay = true }
        gone = (it, w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        notice = "Removed from history · ⌘Z brings it back"
        rebuild()
    }

    private func undo() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil
        notice = "Back"
        rebuild()
        if let i = shown.firstIndex(where: { items[$0].same(g.item) }) { sel = i; scroll() }
    }

    private func commitGone() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil
        let it = g.item
        if pins.contains(where: { $0.kind == it.kind && $0.text == it.text }) { pins.removeAll { $0.kind == it.kind && $0.text == it.text }; savePins() }
        raw.removeAll { $0.same(it) }
        if stamps != ["preview"] { History.forget(it.kind, it.text, drafts: it.kind == .typed ? drafts[it.text] ?? [] : [], picture: it.picture) }
        rebuild()
        log("quick: removed a \(it.kind.rawValue) row")
    }

    // MARK: rewrite

    static let localCmds = [Cmd(id: "plain", name: "Plain text", hint: "no formatting, links without tracking", cloud: false),
                            Cmd(id: "oneline", name: "One line", hint: "the lines joined", cloud: false),
                            Cmd(id: "quote", name: "As a quote", hint: "> before each line", cloud: false)]

    private(set) var source: QuickItem?

    func openRework(_ it: QuickItem) {
        guard !it.image else { notice = "Only the size of an image is kept"; return }
        let cloud = Drafter.shared.settings.rework
        source = it
        cmds = Self.localCmds + Rework.shared.cmds.map { Cmd(id: $0.id, name: $0.name, hint: $0.hint, cloud: cloud) }
        if let i = cmds.firstIndex(where: { $0.id == "translate" }) {
            cmds[i].hint = Translate.lang(it.text, share: 0.6) == "uk" ? "→ English" : "→ Українська"
        }
        mode = .rework; rsel = 0; custom = ""; run = .menu; result = ""
        if cloud { Engine.shared.post("/rework", ["warm": true, "from": "quick"]) }
    }

    /// Too long for the rework list (engine/rework.py MAX_CHARS): only the instant ones.
    func usable(_ c: Cmd) -> Bool { QuickRules.local(c.id, "") != nil || (source?.text.count ?? 0) <= 3000 }

    private func reworkKey(_ code: Int64, _ ch: String, cmd: Bool, plain: Bool) {
        // 1-9, 0: that verb at once (while his own words are empty)
        if !cmd, custom.isEmpty, run != .working, ch.count == 1, let d = Int(ch), d < cmds.count + 1 || d == 0 {
            let i = d == 0 ? 9 : d - 1
            if i < cmds.count, usable(cmds[i]) { rsel = i; start(cmds[i].id) }
            return
        }
        switch code {
        case 53: mode = .list; seq += 1
        case 126, 123: rsel = max(0, rsel - 1)
        case 125, 124: rsel = min(cmds.count - 1, rsel + 1)
        case 115, 119, 116, 121: break
        case 36, 76, 48:
            if run == .result, code != 48, let it = source { let text = result, keep = cmd; DispatchQueue.main.async { self.put(it, text, keep: keep) } }
            else if run != .result, !custom.trimmingCharacters(in: .whitespaces).isEmpty { start("custom") }
            else if run != .result, rsel < cmds.count, usable(cmds[rsel]) { start(cmds[rsel].id) }
        case 51:
            if run != .menu { run = .menu; result = ""; seq += 1 }
            else if !custom.isEmpty { custom.removeLast() }
        case 8 where cmd: if run == .result, let it = source { copy(it, result) }
        default:
            if !cmd, run != .working, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), custom.count < 200 {
                custom += ch; if run == .result || run == .failed { run = .menu; result = "" }
            }
        }
    }

    private func start(_ id: String) {
        guard let it = source else { return }
        let name = id == "custom" ? "Your words" : cmds.first { $0.id == id }?.name ?? id
        resultName = name; seq += 1
        if let out = QuickRules.local(id, it.text) {
            result = out; resultBy = "this Mac"; ms = 0; run = out == it.text ? .failed : .result
            log("quick: rewrite \(id) local, \(it.text.count) → \(out.count) chars")
            return
        }
        run = .working
        let mine = seq, t0 = Date()
        // the text leaves the Mac only here, after he picked; engine: Claude through claude_on("rework"), else local
        Engine.shared.post("/rework", ["text": it.text, "cmd": id, "custom": id == "custom" ? custom : "", "app": it.app, "from": "quick"], timeout: 45) { j in
            guard mine == self.seq, self.isOpen, self.mode == .rework else { return }
            let out = (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.ms = Int(Date().timeIntervalSince(t0) * 1000)
            self.resultBy = (j?["by"] as? String).map { $0 == "local" ? "this Mac" : $0 } ?? ""
            if out.isEmpty { self.run = .failed } else { self.result = out; self.run = .result }
            log("quick: rewrite \(id) \(self.ms)ms by \(j?["by"] as? String ?? "-") " + (out.isEmpty ? "none" : "\(it.text.count) → \(out.count) chars"))
            self.view.needsDisplay = true
        }
    }
}

// MARK: the paste switcher

/// ⌘⇧V (setting `switchKey`), like ⌘Tab for the clipboard: the first tap shows a slim strip near the caret with the
/// five newest copies, the newest chosen; each further V (⌘⇧ still down) or → moves on (wrapping), ← goes back;
/// letting go of ⌘ puts the chosen one in, as plain text (QuickRules.plain, so a tap-and-release does what the apps' own
/// ⌘⇧V "paste and match style" did; setting `switchFormat` keeps the newest copy's formatting by sending the app a
/// plain ⌘V). Esc, still holding, puts nothing in. Any other letter turns it into the Quick panel with that letter
/// typed. Plain ⌘V is never touched. Copies only: typed and voice rows stay in the panel.
final class QuickSwitch {
    static let shared = QuickSwitch()
    static let count = 5
    private(set) var isOpen = false
    private(set) var rows: [QuickItem] = []
    var sel = 0
    private var origin: NSRunningApplication?
    let panel: NSPanel
    let view = SwitchView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: SwitchView.H), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false   // the chosen card draws the one shadow
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.model = self
        panel.contentView = view
    }

    var chosen: QuickItem? { sel < rows.count ? rows[sel] : nil }

    func open() {
        guard !isOpen else { return }
        let t0 = Date()
        if IsSecureEventInputEnabled() { Quick.shared.keys.cancelSwitch(); return }
        rows = Array(Quick.shared.items.filter { $0.kind == .copied && !$0.image && !$0.pinned }.prefix(Self.count))
        guard !rows.isEmpty else { Quick.shared.keys.cancelSwitch(); Pill.shared.flash("Nothing copied yet"); return }
        origin = NSWorkspace.shared.frontmostApplication
        sel = 0
        isOpen = true
        place()
        view.needsDisplay = true
        panel.orderFrontRegardless()
        Ghost.shared.hide()
        log("switch: open, \(rows.count) copies, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    func step(_ by: Int) {
        guard isOpen, !rows.isEmpty else { return }
        sel = (sel + by + rows.count) % rows.count
        // the chosen chip is the wide one: the strip refits, its left and top stay
        let top = panel.frame.maxY, size = view.fit()
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: false)
        view.needsDisplay = true
    }

    func close(_ why: String) {
        guard isOpen else { return }
        isOpen = false
        panel.orderOut(nil)
        log("switch: closed (\(why))")
    }

    /// He typed a letter while holding: the panel opens with it, the same copy chosen, where the strip was.
    func intoPanel(_ ch: String) {
        let it = chosen, at = panel.frame.insetBy(dx: SwitchView.pad, dy: SwitchView.pad)   // the strip itself
        close("to panel")
        Quick.shared.open(typed: ch, held: true, choose: it, near: at)
    }

    /// ⌘ let go: the chosen copy goes in.
    func finish() {
        guard isOpen, let it = chosen else { close("empty"); return }
        close("put")
        let keepFormat = Drafter.shared.settings.switchFormat && sel == 0
            && NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == it.text
        let text = keepFormat ? it.text : QuickRules.plain(it.text)
        let how = Quick.shared.put(it, text, keep: true, from: origin, asIs: keepFormat)
        lastPut = nil
        if how != nil { arm(sel, text) }
    }

    // MARK: swap (keys round, 14 November): ⌘⇧V again within 2 s puts the next older copy in place of this one

    /// The row just put in, what went in, and the app.
    private var lastPut: (row: Int, text: String, pid: pid_t)?

    private var textRows: [Bool] { rows.map { Quick.shared.writer($0) == nil && !$0.image } }

    private func arm(_ row: Int, _ text: String) {
        guard Drafter.shared.settings.switchSwap, let pid = origin?.processIdentifier, !text.isEmpty,
              KeyRules.swapNext(textRows, after: row) != nil else { Quick.shared.keys.disarmSwap(); return }
        lastPut = (row, text, pid)
        Quick.shared.keys.armSwap(until: Date().timeIntervalSince1970 + KeyRules.swapSeconds)
    }

    /// The text just put is selected back (the caret is right after it) and the next older copy is pasted over it.
    /// Only when the field still ends with that text, in the same app, never in skipped apps, password fields or
    /// under secure input.
    func swap() {
        Quick.shared.keys.disarmSwap()
        guard let p = lastPut, let i = KeyRules.swapNext(textRows, after: p.row) else { lastPut = nil; return }
        lastPut = nil
        let st = Drafter.shared.settings
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == p.pid,
              !st.skip.contains(front.bundleIdentifier ?? ""), !IsSecureEventInputEnabled() else { log("switch: swap skipped, app changed"); return }
        let (spot, why) = Focus.spot(skip: st.skip)
        guard spot != nil || Focus.pasteTarget(why), let el = Focus.focused(),
              KeyRules.stillEnds(before: spot?.before ?? Focus.before(el) ?? "", piece: p.text) else {
            log("switch: swap skipped, text changed"); return
        }
        let it = rows[i], text = QuickRules.plain(it.text)
        sel = i
        Fields.left(p.text.count, shift: true)
        Focus.paste(text)
        Quick.shared.used(it)
        log("switch: swap to copy \(i + 1), \(p.text.count) → \(text.count) chars in \(front.bundleIdentifier ?? "?")")
        arm(i, text)
    }

    /// Under the caret (or the focused field), else in the upper third of the mouse's screen.
    private func place() {
        let h = NSScreen.screens.first?.frame.height ?? 0, p = SwitchView.pad
        view.maxW = (NSScreen.main?.visibleFrame.width ?? 1400) - 16
        let size = view.fit()
        var anchor: CGRect?
        if let app = origin, app.processIdentifier != getpid(), let el = Focus.focused() {
            AXUIElementSetMessagingTimeout(el, 0.08)
            anchor = Focus.selectionRect(el) ?? Focus.frame(el)
        }
        if let a = anchor, let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: a.midX, y: h - a.midY)) }) {
            let vis = scr.visibleFrame
            // the strip itself (inside the shadow's room `p`) sits 6 pt under the caret line, or above it near the bottom
            var y = h - a.maxY - 6 - size.height + p
            if y + p < vis.minY + 4 { y = h - a.minY + 6 - p }
            let x = min(max(a.minX - p, vis.minX - p + 4), vis.maxX - size.width + p - 4)
            panel.setFrame(NSRect(x: x, y: min(max(y, vis.minY - p + 4), vis.maxY - size.height + p - 4), width: size.width, height: size.height), display: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let vis = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: vis.midX - size.width / 2, y: vis.maxY - vis.height / 3, width: size.width, height: size.height), display: false)
    }
}

// MARK: drawing: the tape (look round "Tape", 14 November 2026; shared pieces in TapeDraw.swift). All of it here, so a
// design round can replace these two views.

final class QuickView: NSView {
    weak var model: Quick?
    override var isFlipped: Bool { true }
    static let W: CGFloat = 480, G: CGFloat = 88, H: CGFloat = 438
    static let headH: CGFloat = 36, footH: CGFloat = 8, rowH: CGFloat = 32, divH: CGFloat = 24, noticeH: CGFloat = 40
    static var listY: CGFloat { headH + 1 }
    static var listH: CGFloat { H - listY - footH }
    static var size: NSSize { NSSize(width: W, height: H) }
    static let side: CGFloat = 16
    static var textX: CGFloat { G + side }
    static var textW: CGFloat { W - G - side - side - 16 - 12 }
    static var textFont: NSFont { PK.text(14) }   // asked each time: a theme can change the face

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    /// Whole rows in view at the last draw (the fix round measures the head with it).
    var drawnRows = 0

    // MARK: layout (only the rows in view are measured)

    private func avail(_ m: Quick) -> CGFloat { Self.listH - (m.notice.isEmpty ? 0 : Self.noticeH) }

    /// The hour (or day) divider above row i: only in time order (no query), never among the pins.
    func divider(_ m: Quick, _ i: Int) -> String? {
        guard m.query.isEmpty, i > 0, i < m.shown.count else { return nil }
        let it = m.items[m.shown[i]], prev = m.items[m.shown[i - 1]]
        if it.pinned { return nil }
        return prev.pinned || TapeDraw.bucket(prev.at, now: m.now) != TapeDraw.bucket(it.at, now: m.now) ? TapeDraw.label(it.at, now: m.now) : nil
    }
    private func chosenH(_ m: Quick, _ it: QuickItem) -> CGFloat {
        if m.mode == .rework { return rework(m, it, y: 0, draw: false) }
        if it.clip != .text { return kindRow(m, it, y: 0, draw: false) }
        let n = TapeDraw.lines(it.text, width: Self.textW, font: Self.textFont, lh: 20, max: 3)
        return 8 + CGFloat(n) * 20 + 10 + (it.image ? 0 : TapeDraw.capH + 12)
    }
    static let pictureH: CGFloat = 96

    /// The chosen link, file or picture row, unfolded: its line, the full address or path (a picture: the picture and
    /// its read text), then its keys (ClipRules.actions, at most four). Returns the height.
    @discardableResult
    func kindRow(_ m: Quick, _ it: QuickItem, y y0: CGFloat, draw: Bool) -> CGFloat {
        let x = Self.textX, w = Self.textW, f = Self.textFont
        var y = y0 + 8
        if it.clip == .image, !it.picture.isEmpty, let img = TapeDraw.thumb(History.clipURL(it.picture)) {
            if draw { TapeDraw.picture(img, in: NSRect(x: x, y: y + 2, width: w, height: Self.pictureH)) }
            y += 2 + Self.pictureH + 8
        }
        if draw { TapeDraw.clipLine(it.clip, text: it.text, title: it.title, bytes: it.bytes, ocr: "", NSRect(x: x, y: TapeDraw.lineTop(f, mid: y + 10), width: w, height: 20), font: f) }
        y += 20
        let more = it.clip == .image ? it.ocr.split(whereSeparator: \.isNewline).joined(separator: " ") : it.clip == .link ? it.text : (it.text as NSString).abbreviatingWithTildeInPath
        if !more.isEmpty {
            let f2 = PK.text(13), n = TapeDraw.lines(more, width: w, font: f2, lh: 18, max: 2)
            if draw { TapeDraw.block(more, x: x, y: y + 2, width: w, font: f2, color: PK.muted, lh: 18, max: 2) }
            y += 2 + CGFloat(n) * 18
        }
        let keys = m.actions(it)
        if !keys.isEmpty {
            y += 10
            if draw { var ax = x; for a in keys.prefix(4) { ax = TapeDraw.keyWord(a.key, a.word, x: ax, y: y) } }
            y += TapeDraw.capH + 12
        } else { y += 10 }
        return y - y0
    }
    private var chosenCache: (key: String, h: CGFloat)?
    private func height(_ m: Quick, _ i: Int) -> CGFloat {
        var h = Self.rowH
        if i == m.sel {   // measured once per state of the chosen row
            let it = m.items[m.shown[i]]
            let key = "\(it.id)|\(m.mode)|\(m.run)|\(m.result.count)|\(m.cmds.count)|\(it.pinned)|\(it.ocr.count)"
            if let c = chosenCache, c.key == key { h = c.h } else { h = chosenH(m, it); chosenCache = (key, h) }
        }
        return (divider(m, i) != nil ? Self.divH : 0) + h
    }
    /// The first row in view: the chosen row stays fully in view, and the view moves only when it has to (the scroll
    /// anchor), so nothing jumps when the list changes; no empty tail at the end of the list.
    func fitTop(_ m: Quick) -> Int {
        let n = m.shown.count
        guard n > 0 else { return 0 }
        let room = avail(m)
        var top = max(0, min(m.top, m.sel, n - 1))
        func span(_ a: Int, _ b: Int) -> CGFloat {
            var h: CGFloat = 0
            for i in a...b { h += height(m, i); if h > room { break } }
            return h
        }
        while top < m.sel, span(top, m.sel) > room { top += 1 }
        while top > 0 {
            var h = height(m, top - 1), i = top
            while i < n, h <= room { h += height(m, i); i += 1 }
            if h <= room { top -= 1 } else { break }
        }
        return top
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let W = Self.W, G = Self.G, H = Self.H
        TapeDraw.surface(bounds)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: max(0, PK.corner(3) - 1), yRadius: max(0, PK.corner(3) - 1)).addClip()

        // head: the search glyph in the gutter, what he types, the four kind glyphs
        PK.line.setFill(); NSRect(x: G - 1, y: 0, width: 1, height: H).fill()
        TapeDraw.glyph("search", NSRect(x: G - 12 - 16, y: Self.headH / 2 - 8, width: 16, height: 16), color: PK.muted)
        let kx = TapeDraw.kinds(right: W - 10, y: (Self.headH - 28) / 2) { k in m.kind.map { TapeKind($0) == k } ?? (k != .call) }
        let qf = PK.text(14), qa = TapeDraw.at(qf, PK.ink, cut: .byTruncatingHead)
        let qx = Self.textX, qw = kx - 10 - qx, qy = TapeDraw.lineTop(qf, mid: Self.headH / 2)
        TapeDraw.line(m.query, NSRect(x: qx, y: qy, width: qw, height: 22), qa)
        if m.mode == .list {
            PK.blue.setFill()
            NSRect(x: qx + min(qw, m.query.isEmpty ? 0 : TapeDraw.width(m.query, qa) + 1), y: Self.headH / 2 - 9, width: 2, height: 18).fill()
        }
        TapeDraw.hairline(x0: 0, x1: W, y: Self.headH)

        // the tape
        let y0 = Self.listY, room = avail(m)
        m.top = fitTop(m)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: y0, width: W, height: room).clip()
        if m.shown.isEmpty {
            let t = m.items.isEmpty ? "Nothing copied, typed or said yet" : "Nothing matches"
            TapeDraw.line(t, NSRect(x: Self.textX, y: y0 + 10, width: Self.textW, height: 20), TapeDraw.at(PK.text(14), PK.muted))
        }
        var y = y0, i = m.top
        drawnRows = 0
        while i < m.shown.count, y < y0 + room {
            if let l = divider(m, i) { drawDivider(l, y: y); y += Self.divH }
            let it = m.items[m.shown[i]], on = i == m.sel
            let h = on ? chosenH(m, it) : Self.rowH
            drawRow(m, it, y: y, h: h, on: on)
            y += h; i += 1
            if y <= y0 + room { drawnRows += 1 }
        }
        if m.shown.count > i - m.top, m.shown.count > 0 {   // where the view is when the list runs longer
            let n = CGFloat(m.shown.count), vis = CGFloat(i - m.top)
            let th = max(18, (room - 8) * vis / n), ty = y0 + 4 + (room - 8 - th) * CGFloat(m.top) / max(1, n - vis)
            PK.rule.setFill(); NSBezierPath(roundedRect: NSRect(x: W - 5, y: ty, width: 3, height: th), xRadius: 1.5, yRadius: 1.5).fill()
        }
        PK.line.setFill(); NSRect(x: G - 1, y: y0, width: 1, height: room).fill()   // the gutter's hairline, unbroken by dividers
        NSGraphicsContext.restoreGraphicsState()
        if !m.notice.isEmpty { drawNotice(m.notice, y: y0 + room) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDivider(_ label: String, y: CGFloat) {
        let a = TapeDraw.at(PK.mono(11), PK.faint), f = PK.mono(11)
        (label as NSString).draw(at: NSPoint(x: Self.G - 12 - TapeDraw.width(label, a), y: TapeDraw.lineTop(f, mid: y + Self.divH / 2)), withAttributes: a)
        TapeDraw.hairline(x0: Self.textX, x1: Self.W - Self.side, y: y + Self.divH / 2)
    }

    private func drawRow(_ m: Quick, _ it: QuickItem, y: CGFloat, h: CGFloat, on: Bool) {
        let W = Self.W, G = Self.G
        if on { TapeDraw.lift.setFill(); NSRect(x: 0, y: y, width: W, height: h).fill() }
        let gy: CGFloat = on ? 10 : (Self.rowH - 16) / 2   // the glyphs sit on the first line of text
        TapeDraw.gutter(NSRect(x: 0, y: y, width: G, height: h), kind: TapeKind(it.kind), time: it.pinned ? nil : TapeDraw.time(it.at),
                        mark: TapeDraw.clipMark(it.clip), chosen: on, top: gy)
        if it.pinned { TapeDraw.glyph("bookmark", NSRect(x: G - 12 - 16 - 8 - 16, y: y + gy, width: 16, height: 16), color: on ? PK.ink : PK.muted) }
        if let a = TapeDraw.appMark(it.app) { TapeDraw.glyph(a, NSRect(x: W - Self.side - 16, y: y + gy, width: 16, height: 16), color: on ? PK.muted : PK.faint) }
        let x = Self.textX, w = Self.textW
        guard on else {
            let f = Self.textFont
            var tx = x, tw = w
            if it.clip == .image, !it.picture.isEmpty, let img = TapeDraw.thumb(History.clipURL(it.picture)) {
                let r = TapeDraw.picture(img, in: NSRect(x: x, y: y + 4, width: 48, height: Self.rowH - 8))
                tx = r.maxX + 10; tw = w - (tx - x)
            }
            if TapeDraw.clipLine(it.clip, text: it.text, title: it.title, bytes: it.bytes, ocr: it.ocr,
                                 NSRect(x: tx, y: TapeDraw.lineTop(f, mid: y + Self.rowH / 2), width: tw, height: 20), font: f) { return }
            TapeDraw.line(it.first, NSRect(x: x, y: TapeDraw.lineTop(f, mid: y + Self.rowH / 2), width: w, height: 20),
                      TapeDraw.at(f, it.image ? PK.muted : PK.ink, cut: it.single ? .byTruncatingMiddle : .byTruncatingTail))
            return
        }
        if m.mode == .rework { _ = rework(m, it, y: y, draw: true); return }
        if it.clip != .text { kindRow(m, it, y: y, draw: true); return }
        let n = TapeDraw.lines(it.text, width: w, font: Self.textFont, lh: 20, max: 3)
        TapeDraw.block(it.text, x: x, y: y + 8, width: w, font: Self.textFont, color: it.image ? PK.muted : PK.ink, lh: 20, max: 3)
        guard !it.image else { return }
        let ay = y + 8 + CGFloat(n) * 20 + 10
        var ax = TapeDraw.keyWord("↵", "paste", x: x, y: ay)
        ax = TapeDraw.keyWord("⇥", "rewrite", x: ax, y: ay)
        let extra = m.actions(it)   // a text holding a link or a path: that one's keys (four keycaps at most)
        if extra.isEmpty { TapeDraw.keyWord("⌘P", it.pinned ? "unpin" : "pin", x: ax, y: ay) }
        else { for a in extra.prefix(2) { ax = TapeDraw.keyWord(a.key, a.word, x: ax, y: ay) } }
    }

    private static func verb(_ c: Quick.Cmd) -> String {
        switch c.id {
        case "plain": return "plain"
        case "oneline": return "one line"
        case "quote": return "quote"
        case "translate": return c.hint.contains("English") ? "→ EN" : c.hint.contains("Україн") ? "→ UA" : "translate"
        default: return c.name.lowercased()
        }
    }

    /// Rewrite, unfolded under the chosen row: his text (struck lightly above the result once one came back), the
    /// verbs as numbered keycaps (1-3 on this Mac; below the hairline the rework list, with the cloud glyph when it
    /// goes to Claude), the field for his own words, and what ⏎ and ⌫ do with the length change. Returns the height.
    @discardableResult
    func rework(_ m: Quick, _ it: QuickItem, y y0: CGFloat, draw: Bool) -> CGFloat {
        let x = Self.textX, w = Self.textW
        var y = y0 + 8
        if m.run == .result {
            let f1 = PK.text(13), n1 = TapeDraw.lines(it.text, width: w, font: f1, lh: 18, max: 2)
            if draw { TapeDraw.block(it.text, x: x, y: y + 2, width: w, font: f1, color: PK.muted, lh: 18, max: 2, strike: PK.faint) }
            y += 2 + CGFloat(n1) * 18 + 6
            let f2 = PK.text(15), n2 = TapeDraw.lines(m.result, width: w, font: f2, lh: 22, max: 4)
            if draw { TapeDraw.block(m.result, x: x, y: y, width: w, font: f2, color: PK.ink, lh: 22, max: 4) }
            y += CGFloat(n2) * 22 + 10
        } else {
            let n = TapeDraw.lines(it.text, width: w, font: Self.textFont, lh: 20, max: 3)
            if draw { TapeDraw.block(it.text, x: x, y: y, width: w, font: Self.textFont, color: PK.ink, lh: 20, max: 3) }
            y += CGFloat(n) * 20 + 8
            if m.run == .working || m.run == .failed {
                let s = m.resultName.lowercased() + (m.run == .working ? " · writing…" : " · nothing new came back")
                if draw { TapeDraw.line(s, NSRect(x: x, y: y, width: w, height: 18), TapeDraw.at(PK.text(13), PK.muted)) }
                y += 24
            }
        }
        // the verbs: four to a line, "/ own" closes the first line (the three on this Mac)
        if draw { TapeDraw.hairline(x0: x, x1: x + w, y: y) }
        y += 2 + 10
        let gap: CGFloat = 8, colW = (w - 3 * gap) / 4, rowStep = TapeDraw.capH + 8
        let cloud = m.cmds.contains { $0.cloud }
        func cell(_ c: Int) -> (CGFloat, CGFloat) {
            let r = c / 4
            return (x + CGFloat(c % 4) * (colW + gap), y + CGFloat(r) * rowStep + (r > 0 ? 12 : 0))
        }
        let cells = m.cmds.count + 1
        if draw {
            for (i, c) in m.cmds.enumerated() {
                let (cx, cy) = cell(i < 3 ? i : i + 1)
                let ok = m.usable(c)
                let key = i < 10 ? "\((i + 1) % 10)" : "·"
                let kw = TapeDraw.keycap(key, x: cx, y: cy, on: i == m.rsel && m.custom.isEmpty)
                TapeDraw.line(Self.verb(c), NSRect(x: cx + kw + 7, y: cy + 4, width: colW + gap - kw - 9, height: 18), TapeDraw.at(PK.text(13), ok ? PK.ink : PK.faint))
            }
            let (ox, oy) = cell(min(3, cells - 1))
            let kw = TapeDraw.keycap("/", x: ox, y: oy, on: !m.custom.isEmpty)
            TapeDraw.line("own", NSRect(x: ox + kw + 7, y: oy + 4, width: colW - kw - 7, height: 18), TapeDraw.at(PK.text(13), PK.ink))
            if m.cmds.count > 3 {
                let ry = y + rowStep + 2
                TapeDraw.hairline(x0: x, x1: x + w - (cloud ? 24 : 0), y: ry)
                if cloud { TapeDraw.glyph("cloud", NSRect(x: x + w - 16, y: ry - 8, width: 16, height: 16), color: PK.muted) }
            }
        }
        let rows = (cells + 3) / 4
        y += CGFloat(rows) * rowStep + (rows > 1 ? 12 : 0) - 8 + 12
        // his own words
        if draw {
            let r = NSRect(x: x, y: y, width: w, height: 32)
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: PK.corner(2), yRadius: PK.corner(2))
            PK.card.setFill(); b.fill(); PKColors.controlEdge.setStroke(); b.lineWidth = 1; b.stroke()
            let sa = TapeDraw.at(PK.mono(13), PK.faint), f = PK.text(14)
            ("/" as NSString).draw(at: NSPoint(x: r.minX + 10, y: TapeDraw.lineTop(PK.mono(13), mid: r.midY)), withAttributes: sa)
            let ta = TapeDraw.at(f, m.custom.isEmpty ? PK.faint : PK.ink, cut: .byTruncatingHead)
            let tx = r.minX + 26, tw = r.width - 36
            TapeDraw.line(m.custom.isEmpty ? "your own words" : m.custom, NSRect(x: tx, y: TapeDraw.lineTop(f, mid: r.midY), width: tw, height: 20), ta)
            if m.run != .working {
                PK.blue.setFill()
                NSRect(x: tx + (m.custom.isEmpty ? -3 : min(tw, TapeDraw.width(m.custom, ta) + 1)), y: r.midY - 9, width: 2, height: 18).fill()
            }
        }
        y += 32
        if m.run == .result {
            y += 10
            if draw {
                var ax = TapeDraw.keyWord("↵", "paste new", x: x, y: y)
                ax = TapeDraw.keyWord("⌫", "back to old", x: ax, y: y)
                let s = "\(it.text.count) → \(m.result.count)", a = TapeDraw.at(PK.mono(12), PK.muted)
                (s as NSString).draw(at: NSPoint(x: x + w - TapeDraw.width(s, a), y: TapeDraw.lineTop(PK.mono(12), mid: y + 12)), withAttributes: a)
            }
            y += TapeDraw.capH
        }
        return y + 12 - y0
    }

    /// The one line that says what just happened and how to take it back.
    private func drawNotice(_ s: String, y: CGFloat) {
        let W = Self.W, G = Self.G, h = Self.noticeH
        PK.card.setFill(); NSRect(x: G, y: y, width: W - G, height: h).fill()
        TapeDraw.hairline(x0: 0, x1: W, y: y)
        let a = TapeDraw.at(PK.text(13), PK.muted), f = PK.text(13)
        let parts = s.components(separatedBy: " · ⌘Z ")
        var x = Self.textX
        let ty = TapeDraw.lineTop(f, mid: y + h / 2)
        (parts[0] as NSString).draw(at: NSPoint(x: x, y: parts.count > 1 ? y + (h - TapeDraw.capH) / 2 + 4 : ty), withAttributes: a)
        if parts.count > 1 {
            x += TapeDraw.width(parts[0], a) + 12
            TapeDraw.keyWord("⌘Z", parts[1], x: x, y: y + (h - TapeDraw.capH) / 2)
        }
    }
}

/// The paste switcher: five short cards in a row: the kind's glyph, the app and the time on top, the text on two lines;
/// the chosen card is raised with the one shadow and a 2 pt edge in the kind's colour along its top.
final class SwitchView: NSView {
    weak var model: QuickSwitch?
    override var isFlipped: Bool { true }
    /// One slim strip: `stripH` high, chips of text only. The chosen chip shows up to `chosenW` of text (about 100
    /// characters), the others about 28 characters (`otherW`). `pad` leaves room for the one float shadow.
    static let stripH: CGFloat = 36, chipH: CGFloat = 28, inset: CGFloat = 4, gap: CGFloat = 2, side: CGFloat = 10, mark: CGFloat = 12
    static let chosenW: CGFloat = 600, otherW: CGFloat = 172, pad: CGFloat = 16
    static var H: CGFloat { stripH + 2 * pad }
    static var font: NSFont { PK.text(13) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    /// The chips that fit on the screen (at least three), from the first, each with its width.
    private(set) var chips: [(i: Int, w: CGFloat)] = []
    var maxW: CGFloat = 1400

    /// The whole text on one line (its lines joined), so a list shows more than its first item.
    static func flat(_ it: QuickItem) -> String {
        it.single ? it.first : it.text.prefix(600).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func textW(_ it: QuickItem, on: Bool) -> CGFloat {
        min(on ? Self.chosenW : Self.otherW, TapeDraw.width(Self.flat(it), TapeDraw.at(Self.font, PK.ink)))
    }
    private func chipW(_ it: QuickItem, on: Bool) -> CGFloat {
        2 * Self.side + textW(it, on: on) + (on ? Self.mark + 6 : 0)
    }

    func fit() -> NSSize {
        guard let m = model else { return .zero }
        chips = []
        var w = 2 * Self.pad + 2 * Self.inset - Self.gap
        for (i, it) in m.rows.enumerated() {
            let cw = chipW(it, on: i == m.sel)
            if chips.count >= 3, w + cw + Self.gap > maxW, i > m.sel { break }
            chips.append((i, cw)); w += cw + Self.gap
        }
        frame = NSRect(x: 0, y: 0, width: ceil(w), height: Self.H)
        return frame.size
    }

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let strip = NSRect(x: Self.pad, y: Self.pad, width: bounds.width - 2 * Self.pad, height: Self.stripH)
        NSGraphicsContext.saveGraphicsState()
        PK.floatShadow().set()
        PK.card.setFill(); NSBezierPath(roundedRect: strip, xRadius: PK.corner(3), yRadius: PK.corner(3)).fill()
        NSGraphicsContext.restoreGraphicsState()
        TapeDraw.surface(strip)
        var x = strip.minX + Self.inset
        for c in chips {
            let it = m.rows[c.i], on = c.i == m.sel
            let r = NSRect(x: x, y: strip.minY + Self.inset, width: c.w, height: Self.chipH)
            var tx = r.minX + Self.side
            if on {
                let box = NSBezierPath(roundedRect: r, xRadius: PK.corner(2), yRadius: PK.corner(2))
                NSGraphicsContext.saveGraphicsState(); box.addClip()
                TapeDraw.lift.setFill(); box.fill()
                TapeKind(it.kind).color.setFill(); NSRect(x: r.minX, y: r.minY, width: TapeDraw.edge, height: r.height).fill()
                NSGraphicsContext.restoreGraphicsState()
                TapeDraw.glyph(it.single && it.first.contains("://") ? "globe" : TapeKind(it.kind).mark,
                               NSRect(x: tx, y: r.midY - Self.mark / 2, width: Self.mark, height: Self.mark), color: PK.ink)
                tx += Self.mark + 6
            }
            let a = TapeDraw.at(Self.font, on ? PK.ink : PK.muted, cut: it.single ? .byTruncatingMiddle : .byTruncatingTail)
            let tw = textW(it, on: on)
            TapeDraw.line(Self.flat(it), NSRect(x: tx, y: TapeDraw.lineTop(Self.font, mid: r.midY), width: tw, height: 20), a)
            x += c.w + Self.gap
        }
    }
}

// MARK: previews and the speed check (made-up rows only; nothing is put on screen)

extension Quick {
    /// Round three: link, file and picture rows (made-up; the picture is drawn here and read by Vision like a real one).
    /// A made-up picture in data/clips/ of the scratch home (previews only), read by Vision like a real copy.
    static func samplePicture() throws -> (name: String, bytes: Int, ocr: String) {
        let name = "c-preview.png", u = History.clipURL(name)
        try FileManager.default.createDirectory(at: History.clipsDir, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 640, height: 400), flipped: true) { r in
            NSColor.white.setFill(); r.fill()
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 640, height: 56).fill()
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray]
            ("Invoice 0042" as NSString).draw(at: NSPoint(x: 32, y: 10), withAttributes: big)
            ("Station redesign, drawings" as NSString).draw(at: NSPoint(x: 32, y: 100), withAttributes: body)
            ("Total due: 1 250 EUR by Friday" as NSString).draw(at: NSPoint(x: 32, y: 150), withAttributes: body)
            NSColor.systemBlue.setFill(); NSRect(x: 32, y: 230, width: 220, height: 56).fill()
            return true
        }
        if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: u)
        }
        let t0 = Date()
        let ocr = CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(Screen.read) ?? ""
        try ocr.write(to: History.clipURL(name + ".txt"), atomically: true, encoding: .utf8)
        print("kinds: picture read in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(ocr.split(whereSeparator: \.isNewline).count) lines")
        return (name, (try? Data(contentsOf: u).count) ?? 0, ocr)
    }

    /// Round three: link, file and picture rows (made-up; the picture is drawn here and read by Vision like a real one).
    func kindsPreview(now: Double, shot: (String) throws -> Void, reset: () -> Void) throws {
        let (name, bytes, ocr) = try Self.samplePicture()
        let rows = [
            QuickItem(kind: .copied, text: "https://example.com/projects/station-redesign/drawings?utm_source=newsletter&id=48213", app: "Safari", at: now - 40,
                      clip: .link, title: "Station redesign · drawings"),
            QuickItem(kind: .copied, text: "Image · 640 × 400", app: "Preview", at: now - 3 * 60, image: true, clip: .image, bytes: bytes, picture: name, ocr: ocr),
            QuickItem(kind: .copied, text: NSHomeDirectory() + "/Desktop/station-drawings-final.pdf", app: "Finder", at: now - 9 * 60, clip: .file, bytes: 482_113),
            QuickItem(kind: .copied, text: "The plan is at https://example.com/plans/station, see the second page", app: "Mail", at: now - 20 * 60),
            QuickItem(kind: .typed, text: "See you at the station at nine, I will bring the drawings.", app: "Messages", at: now - 30 * 60),
            QuickItem(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60, rich: true),
        ]
        load(rows); reset(); refilter()
        try shot("kinds-link")
        sel = 1; try shot("kinds-image")
        sel = 2; try shot("kinds-file")
        sel = 3; try shot("kinds-text-link")
        reset(); query = "1 250"; refilter()
        print("kinds: search \"1 250\" finds \(shown.count) row(s), first \(shown.first.map { items[$0].clip.rawValue } ?? "-")")
        try shot("kinds-ocr-search")
        reset(); query = "desktop"; refilter()
        print("kinds: search \"desktop\" finds \(shown.first.map { items[$0].clip.rawValue } ?? "-")")
    }

    static func sampleRows(_ n: Int, now: Double) -> [QuickItem] {
        let hand: [QuickItem] = [
            QuickItem(kind: .copied, text: "https://example.com/projects/station-redesign/drawings/final-review?utm_source=newsletter&utm_medium=email&id=48213", app: "Safari", at: now - 40),
            QuickItem(kind: .typed, text: "See you at the station at nine, I will bring the drawings.", app: "Messages", at: now - 4 * 60),
            QuickItem(kind: .voice, text: "Нагадати про зустріч у четвер о десятій і взяти з собою креслення.\nПотім обговорити бюджет.", app: "Notes", at: now - 22 * 60),
            QuickItem(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60),
            QuickItem(kind: .copied, text: "Image · 1280 × 800", app: "Preview", at: now - 2 * 3600, image: true),
            QuickItem(kind: .typed, text: "Дякую! Надішлю акт сьогодні ввечері, а в четвер пройдемось по цифрах.", app: "Telegram", at: now - 3 * 3600),
            QuickItem(kind: .voice, text: "Draft for the newsletter: three short points, the launch date, and a thank-you to the team.", app: "Notes", at: now - 26 * 3600),
            QuickItem(kind: .copied, text: "**Agenda**\n- budget\n- drawings\n- next steps", app: "Notion", at: now - 2 * 86400),
            QuickItem(kind: .typed, text: "Could you send the updated plan by Friday?", app: "Slack", at: now - 3 * 86400),
            QuickItem(kind: .copied, text: "Kyiv, Khreshchatyk 22", app: "Maps", at: now - 5 * 86400),
        ]
        let words = ["plan", "station", "drawings", "budget", "зустріч", "четвер", "кава", "report", "звіт", "invoice", "notes", "draft"]
        let apps = ["Notes", "Safari", "Mail", "Telegram", "Slack"]
        var filler: [QuickItem] = []
        for i in 0..<max(0, n - hand.count) {
            var w: [String] = []
            for k in 0..<(6 + i % 30) { w.append(words[(k * 7 + i) % words.count]) }
            let at: Double = now - 6 * 86400 - Double(i) * 1500
            w.append("\(i)")
            filler.append(QuickItem(kind: QuickKind.allCases[i % 3], text: w.joined(separator: " "), app: apps[i % apps.count], at: at))
        }
        return hand + filler
    }

    func preview(_ folder: String) throws {
        // a fixed time of day, so the tape's hours read the same in every render
        let now = Calendar.current.date(bySettingHour: 12, minute: 45, second: 0, of: Date())!.timeIntervalSince1970
        self.now = now
        let dark = PK.dark ? "-dark" : ""
        func shot(_ name: String) throws {
            view.needsDisplay = true
            guard let rep = UIShots.bitmap(view), let d = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Quick", code: 1) }
            try d.write(to: URL(fileURLWithPath: folder + "/quick-\(name)\(dark).png"))
        }
        func reset() { query = ""; kind = nil; sel = 0; top = 0; mode = .list; notice = ""; custom = ""; run = .menu }
        let rows = Self.sampleRows(1000, now: now)
        load(rows, pins: [QuickPin(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60)])
        isOpen = true
        // speed: what the key does before the panel shows (state, filter, one full draw), with 1,000 rows in memory
        var opens: [Double] = []
        for _ in 0..<5 {
            let t0 = Date()
            reset(); refilter(); _ = UIShots.bitmap(view)
            opens.append(Date().timeIntervalSince(t0) * 1000)
        }
        var keys: [Double] = []
        for ch in "зустріч четв" { let t0 = Date(); query.append(ch); refilter(); keys.append(Date().timeIntervalSince(t0) * 1000) }
        print(String(format: "quick speed: %d rows · open (filter + draw) first %.1f ms, then %.1f ms · filter per key avg %.2f ms, worst %.2f ms",
                     items.count, opens[0], opens.dropFirst().reduce(0, +) / 4, keys.reduce(0, +) / Double(keys.count), keys.max() ?? 0))
        reset(); refilter(); try shot("list")
        print("quick rows in view: \(view.drawnRows) at \(Int(QuickView.H)) pt, head \(Int(QuickView.headH)) pt, row \(Int(QuickView.rowH)) pt")
        sel = 3; try shot("preview")
        reset(); query = "station"; refilter(); try shot("filtered")
        reset(); kind = .voice; refilter(); try shot("voice")
        reset(); refilter(); sel = 2; openRework(items[shown[2]]); rsel = 6; try shot("rework")
        run = .result; resultName = "Warmer"; resultBy = "sonnet"; ms = 1400
        result = "See you at the station at nine! I'll bring the drawings with me."
        try shot("rework-result")
        reset(); refilter(); sel = 2; remove(); try shot("removed"); undo()
        reset(); query = "nothing like this"; refilter(); try shot("no-match")
        try kindsPreview(now: now, shot: shot, reset: reset)
        try Capture.preview(folder, dark: dark)
        load(rows, pins: [QuickPin(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60)])
        // the paste switcher: just opened, the third chosen, turned into the panel by typing "r"
        reset(); refilter()
        try QuickSwitch.shared.preview(folder, dark: dark, from: items)
        reset(); query = "r"; refilter(); try shot("from-switch")
        load([]); reset(); refilter(); try shot("empty")
        isOpen = false; raw = []; items = []; shown = []; stamps = []
    }
}

extension QuickSwitch {
    func preview(_ folder: String, dark: String, from items: [QuickItem]) throws {
        rows = Array(items.filter { $0.kind == .copied && !$0.image && !$0.pinned }.prefix(Self.count))
        for (name, i) in [("switch-open", 0), ("switch-third", 2)] {
            sel = i; _ = view.fit(); view.needsDisplay = true
            guard let rep = UIShots.bitmap(view), let d = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Quick", code: 2) }
            try d.write(to: URL(fileURLWithPath: folder + "/quick-\(name)\(dark).png"))
        }
        rows = []
    }
}
