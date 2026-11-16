// Quick capture (round three, Part B, 14 November 2026; Andrii: replace ⌘⇧5). ⌃⌥S (setting `captureKey`; "" = off)
// dims every screen. Drag a region, or Space then click a window, or Return for the screen under the mouse; Esc
// cancels. Before the drag K keeps the picture on the tape only and T puts its read text in instead. On release the
// picture is taken with ScreenCaptureKit (Drafter's own windows left out), stored like a copied picture (data/clips/,
// read by Vision once) and joins the tape as an image row; then it goes into the field he was in, through Focus, which
// gives his clipboard back. A field that takes no picture: it stays on the clipboard and the strip says so.
// The dimmed screen is a non-activating panel that never becomes key: his app keeps the focus and the caret, the
// event tap hands keys here (Quick.tap), the mouse goes to the panel. The panel is left out of screen pictures
// (sharingType none), so the capture runs at once, without waiting for it to hide.
// Key and strip round (15 November 2026): ⌘⇧S too while `captureCmdShiftS` is on (ShotRules.keys).
// Screenshot tool (15 November 2026): ⌘⇧5 too once macOS lets it go (ShotRules.keys; the macOS setting is read, never
// written), a toolbar at the bottom centre of the mouse's screen like macOS's (region · window · screen, K keep, T text,
// the last send-to target, esc; 1 2 3 pick), and every capture becomes a shot pack (data/shots/<id>/, app/ShotStore.swift).
import AppKit
import Carbon
import ScreenCaptureKit

final class Capture {
    static let shared = Capture()
    private(set) var isOpen = false
    var mode = ShotRules.Mode.paste
    var pick = ShotRules.Pick.region
    var from: NSPoint?, to: NSPoint?                 // the drag, in screen points
    var hover: (id: CGWindowID, frame: NSRect)?      // window mode: the window under the mouse (screen points)
    var hoverTool: ShotRules.Tool?                    // the pill button under the mouse (its tip shows)
    private var panels: [NSPanel] = []
    private(set) var origin: NSRunningApplication?
    private var originTitle = ""

    // MARK: the key (⌘⇧5 when macOS lets it go)

    /// macOS's own ⌘⇧5 is on (read every 30 s off the main thread; on until the first read says otherwise).
    private(set) static var systemKeyOn = true
    private static var systemReadAt = Date.distantPast
    static func refreshSystemKey() {
        guard Date().timeIntervalSince(systemReadAt) > 30 else { return }
        systemReadAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let app = "com.apple.symbolichotkeys" as CFString
            CFPreferencesAppSynchronize(app)
            let d = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, app) as? [String: Any]
            let on = ShotRules.systemKeyOn(d)
            DispatchQueue.main.async {
                if on != systemKeyOn { log("capture: macOS ⌘⇧5 is \(on ? "on" : "off")") }
                systemKeyOn = on
            }
        }
    }
    /// The capture keys in use now (Quick.tap matches them; Settings shows the first).
    private static var keysCache: (setting: String, on: Bool, s: Bool, keys: [String]) = ("\u{0}", true, true, [])
    static var keys: [String] {
        refreshSystemKey()
        let st = Drafter.shared.settings.captureKey, cs = Drafter.shared.settings.captureCmdShiftS
        if keysCache.setting != st || keysCache.on != systemKeyOn || keysCache.s != cs {
            keysCache = (st, systemKeyOn, cs, ShotRules.keys(setting: st, systemOn: systemKeyOn, cmdShiftS: cs))
        }
        return keysCache.keys
    }

    // MARK: open and close

    func open() {
        guard !isOpen else { return }
        if IsSecureEventInputEnabled() { Pill.shared.flash("Capture is off while secure input is on"); return }
        origin = NSWorkspace.shared.frontmostApplication
        mode = .paste; pick = .region; from = nil; to = nil; hover = nil; hoverTool = nil; originTitle = ""
        if Quick.shared.isOpen { Quick.shared.close("capture") }
        panels = NSScreen.screens.map { scr in
            let p = CapturePanel(contentRect: scr.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.level = .screenSaver
            p.sharingType = .none                    // never in a screen picture, its own included
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.acceptsMouseMovedEvents = true; p.hidesOnDeactivate = false
            let v = CaptureView(frame: NSRect(origin: .zero, size: scr.frame.size)); v.model = self; v.screen = scr.frame
            p.contentView = v
            p.setFrame(scr.frame, display: false)
            p.orderFrontRegardless()
            return p
        }
        NSCursor.crosshair.push()
        isOpen = true
        log("capture: open")
        // the window title for the shot, once the screen is dimmed (an AX read can take up to 0.25 s)
        let o = origin
        DispatchQueue.main.async { if let o, o.processIdentifier != getpid() { self.originTitle = Focus.windowTitle(o) } }
    }

    func close(_ why: String) {
        guard isOpen else { return }
        isOpen = false
        for p in panels { p.orderOut(nil) }
        panels = []
        NSCursor.pop()
        if why != "taken" {
            log("capture: closed (\(why))")
            if CaptureNote.shared.collecting { DispatchQueue.main.async { CaptureNote.shared.resume() } }   // ⌘N dropped: the strip again
        }
    }

    private func redraw() { for p in panels { p.contentView?.needsDisplay = true } }

    // MARK: keys (from the event tap) and the mouse (from the panel)

    func key(_ code: Int) {
        switch ShotRules.key(code, dragging: from != nil) {
        case .cancel: close("esc")
        case .screen:
            let m = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main { take(s.frame, window: nil, full: true) }
        case .windowMode: pick = pick == .window ? .region : .window; hover = pick == .window ? windowAt(NSEvent.mouseLocation) : nil; redraw()
        case .pick(let p): choose(p)
        case .mode(let m): mode = mode == m ? .paste : m; redraw()
        case .none: break
        }
    }

    /// A toolbar button or its key: region, window, or the screen under the mouse at once.
    func choose(_ p: ShotRules.Pick) {
        switch p {
        case .region: pick = .region; hover = nil; redraw()
        case .window: pick = .window; hover = windowAt(NSEvent.mouseLocation); redraw()
        case .screen:
            let m = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main { take(s.frame, window: nil, full: true) }
        }
    }

    /// The toolbar on a screen (local points, origin bottom-left): its items' rectangles (CaptureView draws the same).
    static func toolbar(on screen: NSSize) -> (bar: NSRect, items: [NSRect]) {
        ShotRules.toolbar(screen: screen)
    }

    func down(_ p: NSPoint) {
        // the toolbar first: it sits on the screen under the mouse
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(p) }) {
            let local = CGPoint(x: p.x - scr.frame.minX, y: p.y - scr.frame.minY)
            let tb = Self.toolbar(on: scr.frame.size)
            if tb.bar.contains(local) {
                switch ShotRules.hit(local, tb.items) {
                case .region: choose(.region)
                case .window: choose(.window)
                case .screen: take(scr.frame, window: nil, full: true)
                case .keep: mode = mode == .keep ? .paste : .keep; redraw()
                case .text: mode = mode == .text ? .paste : .text; redraw()
                case .cancel: close("toolbar")
                case .target, nil: break
                }
                return
            }
        }
        if pick == .window { if let h = hover ?? windowAt(p) { take(h.frame, window: h.id) }; return }
        from = p; to = p; redraw()
    }
    func dragged(_ p: NSPoint) { guard from != nil else { return }; to = p; redraw() }
    func up(_ p: NSPoint) {
        guard let a = from else { return }
        from = nil; to = nil
        if let r = ShotRules.region(a, p) { take(r, window: nil) } else { redraw() }
    }
    func moved(_ p: NSPoint) {
        var tool: ShotRules.Tool?
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(p) }) {
            tool = ShotRules.hit(CGPoint(x: p.x - scr.frame.minX, y: p.y - scr.frame.minY), Self.toolbar(on: scr.frame.size).items)
        }
        if tool != hoverTool { hoverTool = tool; redraw() }
        (tool != nil ? NSCursor.arrow : NSCursor.crosshair).set()
        guard pick == .window else { return }
        let h = windowAt(p)
        if h?.id != hover?.id { hover = h; redraw() }
    }

    /// The topmost normal window under a screen point, not Drafter's.
    private func windowAt(_ p: NSPoint) -> (id: CGWindowID, frame: NSRect)? {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: p.x, y: mainH - p.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.contains(cg) { return (id, NSRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height)) }
        }
        return nil
    }

    // MARK: taking it

    /// Release: the picture, then where it goes. `rect` in screen points; `window` for a whole window.
    private func take(_ rect: NSRect, window: CGWindowID?, full: Bool = false) {
        let t0 = Date(), mode = self.mode, origin = self.origin, originTitle = self.originTitle
        let hide = OwnChrome.ids()   // read on the main thread, before the overlay goes
        let scr = NSScreen.screens.first { $0.frame.intersects(rect) && $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
            ?? NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        close("taken")
        guard let scr else { return }
        let did = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let scale = scr.backingScaleFactor
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content else {
                _ = Screen.failed()
                DispatchQueue.main.async { self.refused(error) }
                return
            }
            let cfg = SCStreamConfiguration(); cfg.showsCursor = false
            let filter: SCContentFilter
            var title = originTitle, app = origin?.localizedName ?? ""
            if let window, let w = content.windows.first(where: { $0.windowID == window }) {
                filter = SCContentFilter(desktopIndependentWindow: w)
                title = w.title ?? ""; app = w.owningApplication?.applicationName ?? app
                cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
            } else if let d = content.displays.first(where: { $0.displayID == did }) ?? content.displays.first {
                filter = OwnChrome.filter(d, content, hide: hide)
                let src = ShotRules.sourceRect(rect, display: scr.frame)
                cfg.sourceRect = src
                cfg.width = max(1, Int(src.width * scale)); cfg.height = max(1, Int(src.height * scale))
            } else { return }
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, err in
                guard let img else { _ = Screen.failed(); DispatchQueue.main.async { self.refused(err) }; return }
                Screen.succeeded()
                let shot = Date()
                guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
                DispatchQueue.main.async {
                    // another picture of a set (⌘N in the strip): it joins that shot, no pack of its own
                    let note = CaptureNote.shared
                    if note.collecting, let id = note.pack?.id {
                        _ = History.addPicture(png, width: img.width, height: img.height, app: origin?.localizedName ?? "", shot: id)
                        note.append(png: png, region: rect, full: full, inPlace: window == nil && !full)
                        log("capture: picture for the set taken in \(Int(shot.timeIntervalSince(t0) * 1000)) ms")
                        return
                    }
                    // the shot pack: written now, its text read once (the strip reads it; keep and text modes too)
                    let now = Date().timeIntervalSince1970
                    let pack = ShotPack(id: ShotPack.makeId(now, random: UInt16.random(in: 0...UInt16.max)), t: now, app: app, window: title,
                                        width: img.width, height: img.height)
                    ShotStore.write(pack, png: png)
                    let row = History.addPicture(png, width: img.width, height: img.height, app: origin?.localizedName ?? "", shot: pack.id)
                    if mode != .paste { ShotStore.read(png) { text, found in ShotStore.update(pack.id) { $0.read = text; $0.found = found } } }
                    self.land(png, row: row, mode: mode, origin: origin, t0: t0, shot: shot, pack: pack, region: rect, full: full, window: window != nil)
                }
            }
        }
    }

    private func refused(_ e: Error?) {
        log("capture: failed \(e.map { SysAudio.describe($0) } ?? "")")
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess(); Pill.shared.flash("Capture needs Screen Recording for Drafter") }
        else { Pill.shared.flash("The screen could not be taken") }
    }

    /// Where the picture goes, by mode: into his field, onto the tape only, or its read text into the field.
    private func land(_ png: Data, row: [String: Any], mode: ShotRules.Mode, origin: NSRunningApplication?, t0: Date, shot: Date, pack: ShotPack? = nil,
                      region: NSRect? = nil, full: Bool = false, window: Bool = false) {
        let ms = { Int(Date().timeIntervalSince(t0) * 1000) }, taken = Int(shot.timeIntervalSince(t0) * 1000)
        switch mode {
        case .keep:
            Pill.shared.flash("Kept on the tape · ⌃⌥V")
            log("capture: kept, picture in \(taken) ms")
        case .text:
            DispatchQueue.global(qos: .userInitiated).async {
                let text = CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(Screen.read) ?? ""
                DispatchQueue.main.async {
                    if text.isEmpty { Pill.shared.flash("No text in that part of the screen"); return }
                    let how = Self.put(text: text, origin: origin)
                    log("capture: text \(text.count) chars \(how), picture in \(taken) ms, landed in \(ms()) ms")
                }
            }
        case .paste:
            // Part C: the strip "what is this?" first; ↵ on it puts the picture in at once (CaptureNote)
            // a dragged region: marks go on in place first (look round), ↵ there brings the strip under it
            CaptureNote.shared.open(png: png, row: row, origin: origin, t0: t0, pack: pack, region: region, full: full, inPlace: !full && !window)
            log("capture: picture taken in \(taken) ms, strip up in \(ms()) ms")
            return
        }
    }

    /// Is his field still the one in front, and can it take a paste?
    static func target(_ origin: NSRunningApplication?) -> Bool {
        let st = Drafter.shared.settings
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == origin?.processIdentifier,
              front.processIdentifier != getpid(), !st.skip.contains(front.bundleIdentifier ?? ""), !IsSecureEventInputEnabled() else { return false }
        let (spot, why) = Focus.spot(skip: st.skip)
        return spot != nil || Focus.pasteTarget(why)
    }
    /// A terminal he was in (it is on the skip list for typing help): still in front, no secure input. Text only.
    static func terminalTarget(_ origin: NSRunningApplication?) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == origin?.processIdentifier,
              ShotPack.mayPaste(bundle: front.bundleIdentifier ?? "", skip: Drafter.shared.settings.skip),
              ShotPack.terminals.contains(front.bundleIdentifier ?? ""), !IsSecureEventInputEnabled() else { return false }
        return true
    }
    static func pictureWriter(_ png: Data) -> (NSPasteboard) -> Void {
        { pb in
            pb.setData(png, forType: .png)
            if let t = NSBitmapImageRep(data: png)?.tiffRepresentation { pb.setData(t, forType: .tiff) }
        }
    }
    /// The picture into his field (his clipboard comes back), else onto the clipboard (and the strip says so).
    @discardableResult
    static func put(picture png: Data, origin: NSRunningApplication?) -> String {
        if target(origin) { Focus.paste("", write: pictureWriter(png)); return "pasted" }
        History.copy("", write: pictureWriter(png))
        Pill.shared.flash("The field takes no picture · it is on the clipboard")
        return "on the clipboard"
    }
    @discardableResult
    static func put(text: String, origin: NSRunningApplication?) -> String {
        let st = Drafter.shared.settings
        if target(origin) {
            let (spot, _) = Focus.spot(skip: st.skip)
            if let spot { return Focus.insert(text, at: spot) }
            Focus.paste(text); return "paste"
        }
        History.copy(text)
        Pill.shared.flash("Text on the clipboard · ⌘V to paste")
        return "on the clipboard"
    }
}

/// Drafter's own windows a screen picture leaves out (native round, 16 November 2026): only the capture's chrome (the
/// dimmed overlay, the capture strip, the markup panel: every CapturePanel) and the voice strip. The main window and
/// Drafter's other windows show in a picture like any app's (before, the whole app was left out and the picture showed
/// the window behind Drafter's). Read on the main thread.
enum OwnChrome {
    static let strip = NSUserInterfaceItemIdentifier("drafter.strip")
    static func ids() -> Set<CGWindowID> {
        Set(NSApp.windows.filter { $0 is CapturePanel || $0.identifier == strip }.map { CGWindowID($0.windowNumber) })
    }
    static func filter(_ d: SCDisplay, _ c: SCShareableContent, hide: Set<CGWindowID>) -> SCContentFilter {
        SCContentFilter(display: d, excludingWindows: c.windows.filter { hide.contains($0.windowID) })
    }
}

/// The dimmed screen never becomes key: keys come through the event tap, his app keeps the caret.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CaptureView: NSView {
    weak var model: Capture?
    var screen = NSRect.zero
    var preview = false
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func at(_ e: NSEvent) -> NSPoint { NSEvent.mouseLocation }
    override func mouseDown(with e: NSEvent) { model?.down(at(e)) }
    override func mouseDragged(with e: NSEvent) { model?.dragged(at(e)) }
    override func mouseUp(with e: NSEvent) { model?.up(at(e)) }
    override func mouseMoved(with e: NSEvent) { model?.moved(at(e)); if model?.pick == .region { needsDisplay = true } }

    /// The dim, the hole (the region or the window under the mouse) with a hairline and its size, the hint line.
    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let local = { (r: NSRect) in r.offsetBy(dx: -self.screen.minX, dy: -self.screen.minY) }
        var hole: NSRect?
        if let a = m.from, let b = m.to { hole = local(NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))) }
        if m.pick == .window, let h = m.hover { hole = local(h.frame) }
        let path = NSBezierPath(rect: bounds)
        if let hole { path.append(NSBezierPath(rect: hole)); path.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.38).setFill(); path.fill()
        if let hole, hole.width > 0 {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let edge = NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5)); edge.lineWidth = 1; edge.stroke()
            if m.pick == .region {
                let s = "\(Int(hole.width)) × \(Int(hole.height))", a = TapeDraw.at(PK.mono(11), .white)
                let w = TapeDraw.width(s, a) + 12
                let r = NSRect(x: hole.maxX - w, y: max(4, hole.minY - 24), width: w, height: 20)
                NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                (s as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: a)
            }
        }
        // the toolbar: bottom centre of the screen under the mouse
        guard preview || screen.contains(NSEvent.mouseLocation) else { return }
        CaptureView.toolbar(m.mode, pick: m.pick, hover: m.hoverTool, in: bounds)
    }

    /// The pill's faces: the picked capture mode and the on options lifted; the send-to button shows the last target's
    /// app icon (or glyph) and its word in the tip.
    static func faces(_ mode: ShotRules.Mode, pick: ShotRules.Pick) -> [PillFace] {
        let last = ShotTarget(rawValue: Drafter.shared.settings.shotLast)
        return ShotRules.Tool.allCases.map { t in
            var f = PillFace(glyph: t.glyph, key: t.key, word: t.word)
            switch t {
            case .region: f.on = pick == .region
            case .window: f.on = pick == .window
            case .keep: f.on = mode == .keep
            case .text: f.on = mode == .text
            case .target:
                if let l = last { f.icon = ShotIcons.icon(l); f.glyph = l.glyph; f.word = "After the shot: ⇥ Send to \(l.word)" }
                else { f.word = "After the shot: ⇥ Send to…" }
            default: break
            }
            return f
        }
    }

    /// The capture pill (ShotRules.toolbarPill), drawn flipped through an image over its area and its tip's room.
    static func toolbar(_ mode: ShotRules.Mode, pick: ShotRules.Pick, hover: ShotRules.Tool? = nil, in b: NSRect) {
        let p = ShotRules.toolbarPill(screen: b.size)
        let area = NSRect(x: 0, y: p.bar.minY - 12, width: b.width, height: p.bar.height + 12 + 44)
        let faces = Self.faces(mode, pick: pick)
        ShotPill.drawUnflipped(area) { box in
            // flipped inside the area: y from its top
            func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: area.maxY - r.maxY, width: r.width, height: r.height) }
            let fp = ShotRules.Pill(bar: flip(p.bar), items: p.items.map(flip), dividers: p.dividers)
            ShotPill.draw(fp, faces: faces, hover: hover?.rawValue, bounds: box)
        }
    }
}

// MARK: previews (made-up screen, nothing captured)

extension Capture {
    /// A made-up desktop: a grey-blue screen with one white window holding an invoice (flipped drawing).
    static func desktop(_ r: NSRect) {
        NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.55, alpha: 1).setFill(); r.fill()
        let win = NSRect(x: 140, y: 110, width: 760, height: 500)
        NSColor.white.setFill(); NSBezierPath(roundedRect: win, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0.92, alpha: 1).setFill(); NSRect(x: win.minX, y: win.minY, width: win.width, height: 40).fill()
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black]
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray]
        ("Invoice 0042" as NSString).draw(at: NSPoint(x: win.minX + 40, y: win.minY + 64), withAttributes: big)
        for (i, l) in ["Station redesign, drawings", "Total due: 1 250 EUR by Friday", "Account: Example Studio, made-up",
                       "Pay to: XX00 0000 0000 0000 (sample)"].enumerated() {
            (l as NSString).draw(at: NSPoint(x: win.minX + 40, y: win.minY + 130 + CGFloat(i) * 40), withAttributes: a)
        }
        NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: win.minX + 40, y: win.minY + 320, width: 200, height: 48), xRadius: 8, yRadius: 8).fill()
        (("Pay now" as NSString)).draw(at: NSPoint(x: win.minX + 100, y: win.minY + 333), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
    }
    static func pngOf(_ size: NSSize, flipped: Bool = true, _ draw: @escaping (NSRect) -> Void) -> Data? {
        let img = NSImage(size: size, flipped: flipped) { r in draw(r); return true }
        guard let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The capture pill over the dimmed made-up screen (a region being dragged, the window button's tip; window mode with
    /// K on); markup in place with every tool, a selected mark and a tip; the editor panel (window and screen captures);
    /// the strip under its region, with the send-to list (app icons where the apps are on this Mac), a person search,
    /// and a set of three pictures (the second picked).
    static func preview(_ folder: String, dark: String) throws {
        let size = NSSize(width: 1200, height: 720)
        let m = Capture()
        func write(_ d: Data?, _ name: String) throws { if let d { try d.write(to: URL(fileURLWithPath: folder + "/\(name)\(dark).png")) } }
        for (name, setup) in [("capture-region", { (m: Capture) in m.from = NSPoint(x: 260, y: 200); m.to = NSPoint(x: 820, y: 520); m.hoverTool = .window }),
                              ("capture-window-keep", { (m: Capture) in m.pick = .window; m.mode = .keep
                                  m.hover = (1, NSRect(x: 140, y: 110, width: 760, height: 500)) })] {
            m.from = nil; m.to = nil; m.hover = nil; m.hoverTool = nil; m.pick = .region; m.mode = .paste
            setup(m)
            let v = CaptureView(frame: NSRect(origin: .zero, size: size)); v.model = m; v.screen = v.frame; v.preview = true
            try write(pngOf(size, flipped: false) { r in
                if let d = pngOf(size, desktop).flatMap(NSImage.init(data:)) { d.draw(in: r) }   // the made-up desktop, upright
                v.draw(r)
            }, name)
        }
        // the region taken from the made-up desktop (flipped: top-left), at 2x like a Retina screen
        let region = NSRect(x: 160, y: 150, width: 560, height: 340)   // flipped, in the desktop
        guard let deskPNG = pngOf(size, desktop), let deskRep = NSBitmapImageRep(data: deskPNG), let deskCG = deskRep.cgImage else { return }
        let sx = CGFloat(deskCG.width) / size.width
        guard let cut = deskCG.cropping(to: CGRect(x: region.minX * sx, y: region.minY * sx, width: region.width * sx, height: region.height * sx)),
              let pic = MarkupDraw.png(cut) else { return }
        let screenFrame = NSRect(origin: .zero, size: size)
        let appKitRegion = NSRect(x: region.minX, y: size.height - region.maxY, width: region.width, height: region.height)
        let ed = MarkupEditor.shared
        ed.open(pic, near: NSScreen.main, region: appKitRegion, screenFrame: screenFrame) { _ in }
        let k = sx   // picture pixels per point
        ed.model.add(PicMark(tool: .highlight, from: CGPoint(x: 16 * k, y: 128 * k), to: CGPoint(x: 290 * k, y: 154 * k), color: 1))
        ed.model.add(PicMark(tool: .pixelate, from: CGPoint(x: 14 * k, y: 206 * k), to: CGPoint(x: 310 * k, y: 234 * k)))
        ed.model.add(PicMark(tool: .box, from: CGPoint(x: 14 * k, y: 245 * k), to: CGPoint(x: 230 * k, y: 312 * k), color: 3))
        ed.model.add(PicMark(tool: .arrow, from: CGPoint(x: 470 * k, y: 70 * k), to: CGPoint(x: 300 * k, y: 140 * k)))
        ed.model.add(PicMark(tool: .label, from: CGPoint(x: 330 * k, y: 290 * k), to: CGPoint(x: 330 * k, y: 290 * k), text: "should be 1 150", color: 4))
        ed.model.add(PicMark(tool: .pin, from: CGPoint(x: 300 * k, y: 40 * k), to: CGPoint(x: 300 * k, y: 40 * k), text: "wrong total"))
        ed.model.add(PicMark(tool: .arrow, from: CGPoint(x: 520 * k, y: 220 * k), to: CGPoint(x: 400 * k, y: 255 * k), color: 2, size: 2))
        ed.model.selected = 2; ed.model.tool = .arrow
        ed.hover = 2   // the highlight button's tip
        func inPlace(_ name: String) throws {
            try write(pngOf(size) { r in desktop(r); ed.view.draw(r) }, name)
        }
        try inPlace("markup-inplace")
        ed.hover = nil; ed.live = PicMark(tool: .box, from: CGPoint(x: 360 * k, y: 150 * k), to: CGPoint(x: 540 * k, y: 230 * k), color: 0, size: 0)
        ed.model.selected = nil
        try inPlace("markup-inplace-drawing")
        ed.live = nil
        let t0 = Date()
        if let b = ed.base, let out = MarkupDraw.render(b, ed.model), let d = MarkupDraw.png(out) {
            print("kinds: markup render \(out.width)x\(out.height) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            try d.write(to: URL(fileURLWithPath: folder + "/markup-result\(dark).png"))
        }
        // key and strip round: a region that reaches the bottom of the screen: the pill on the bottom edge, never above
        // the picture (here over its foot: the pill is wider than the room beside it)
        let lowRegion = NSRect(x: 60, y: 300, width: 520, height: 420)   // flipped, down to the screen's foot
        if let a = deskCG.cropping(to: CGRect(x: lowRegion.minX * sx, y: lowRegion.minY * sx, width: lowRegion.width * sx, height: lowRegion.height * sx)),
           let lowPic = MarkupDraw.png(a) {
            ed.open(lowPic, near: NSScreen.main, region: NSRect(x: lowRegion.minX, y: size.height - lowRegion.maxY, width: lowRegion.width, height: lowRegion.height),
                    screenFrame: screenFrame) { _ in }
            ed.model.add(PicMark(tool: .box, from: CGPoint(x: 70 * k, y: 40 * k), to: CGPoint(x: 330 * k, y: 120 * k), color: 0))
            try inPlace("markup-inplace-bottom")
        }
        ed.close(nil)
        // the editor panel (window and screen captures): the same pill at its foot, three pins, the third being typed
        func save(_ v: NSView, _ name: String) throws {
            v.needsDisplay = true
            guard let rep = UIShots.bitmap(v), let d = rep.representation(using: .png, properties: [:]) else { return }
            try d.write(to: URL(fileURLWithPath: folder + "/\(name)\(dark).png"))
        }
        let (sample, _, _) = try Quick.samplePicture()
        let png = try Data(contentsOf: History.clipURL(sample))
        ed.open(png, near: NSScreen.main, screenFrame: nil) { _ in }
        ed.model.add(PicMark(tool: .pin, from: CGPoint(x: 120, y: 110), to: CGPoint(x: 120, y: 110)))
        ed.model.add(PicMark(tool: .pin, from: CGPoint(x: 380, y: 160), to: CGPoint(x: 380, y: 160), text: "wrong total"))
        ed.model.add(PicMark(tool: .box, from: CGPoint(x: 24, y: 136), to: CGPoint(x: 360, y: 180)))
        ed.model.add(PicMark(tool: .crop, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 620, y: 360)))
        ed.model.tool = .pin
        ed.typing = PicMark(tool: .pin, from: CGPoint(x: 520, y: 300), to: CGPoint(x: 520, y: 300), text: "send", n: ed.model.nextPin)
        try save(ed.view, "markup-editor")
        ed.typing = nil
        print("kinds: shot marks \(ed.model.shotMarks.count), pins \(ed.model.shotMarks.filter { $0.kind == "pin" }.count)")
        ed.close(nil)

        // the strip: alone, with a line, the send-to list, a person search; then under its region on the made-up desktop
        let note = CaptureNote.shared
        note.open(png: pic, row: ["clip": sample], origin: nil, t0: Date()); note.close()
        _ = note.view.fit(); try save(note.view, "capture-note")
        note.line = "the total is wrong, should be 1 150"; note.hover = ShotRules.StripButton.add.rawValue; try save(note.view, "capture-note-line")
        note.hover = nil
        note.note = note.line; note.mode = .list; note.list = ShotPack.order(last: .claude); note.sel = 1
        _ = note.view.fit(); try save(note.view, "capture-note-send")
        /// The strip placed by ShotRules.stripPlace for a region (flipped, in the made-up desktop), over the dimmed desktop.
        func under(_ name: String, _ region: NSRect = region) throws {
            let card = note.view.fit()
            let appKit = NSRect(x: region.minX, y: size.height - region.maxY, width: region.width, height: region.height)
            let place = ShotRules.stripPlace(card, region: appKit, full: false, screen: screenFrame)
            let pf = CaptureNoteView.panelFrame(place)
            note.view.frame = NSRect(origin: .zero, size: pf.size); note.view.needsDisplay = true
            guard let rep = UIShots.bitmap(note.view), let strip = rep.cgImage else { return }
            try write(pngOf(size) { r in
                desktop(r)
                let p = NSBezierPath(rect: r); p.append(NSBezierPath(rect: region)); p.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.12).setFill(); p.fill()
                NSColor.white.setStroke(); NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5)).stroke()
                let at = NSRect(x: pf.minX, y: size.height - pf.maxY, width: pf.width, height: pf.height)
                NSImage(cgImage: strip, size: pf.size).draw(in: at, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }, name)
        }
        try under("capture-note-under-region")
        // key and strip round: the bigger send-to list under the region; a region down to the screen's foot: the strip on
        // the bottom edge beside it (room on the right), or over its foot when the region fills the lower screen
        note.line = "the total is wrong, should be 1 150"; note.note = note.line; note.mode = .list; note.list = ShotPack.order(last: .claude); note.sel = 0
        try under("capture-note-send-under-region", NSRect(x: 160, y: 40, width: 560, height: 220))
        note.mode = .note; note.list = []
        try under("capture-note-beside", NSRect(x: 40, y: 300, width: 400, height: 420))
        try under("capture-note-bottom-edge", NSRect(x: 100, y: 260, width: 1000, height: 460))
        note.mode = .person; note.line = "Ol"; note.chats = [(id: "a", title: "Olena K."), (id: "b", title: "Oleh, design team")]; note.sel = 0
        _ = note.view.fit(); try save(note.view, "capture-note-person")
        // a set of three: one note, the second picture picked
        note.mode = .note; note.chats = []; note.list = []; note.line = "the three screens of the order form"
        note.pics = [CaptureNote.pic(pic, region: appKitRegion, full: false, inPlace: false),
                     CaptureNote.pic(png, region: nil, full: false, inPlace: false),
                     CaptureNote.pic(deskPNG, region: nil, full: true, inPlace: false)]
        note.picked = 1
        _ = note.view.fit(); try save(note.view, "capture-note-set")
        note.picked = nil
        try under("capture-note-set-under-region")
        note.pics = []; note.line = ""; _ = note.view.fit()
    }
}
