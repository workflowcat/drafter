// Quick capture (round three, Part B, 14 November 2026; Andrii: replace ⌘⇧5). ⌃⌥S (setting `captureKey`; "" = off)
// dims every screen. Drag a region, or Space then click a window, or Return for the screen under the mouse; Esc
// cancels. Before the drag K keeps the picture on the tape only and T puts its read text in instead. On release the
// picture is taken with ScreenCaptureKit (Drafter's own windows left out), stored like a copied picture (data/clips/,
// read by Vision once) and joins the tape as an image row; then it goes into the field he was in, through Focus, which
// gives his clipboard back. A field that takes no picture: it stays on the clipboard and the strip says so.
// The dimmed screen is a non-activating panel that never becomes key: his app keeps the focus and the caret, the
// event tap hands keys here (Quick.tap), the mouse goes to the panel. The panel is left out of screen pictures
// (sharingType none), so the capture runs at once, without waiting for it to hide.
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
    private var panels: [NSPanel] = []
    private(set) var origin: NSRunningApplication?

    // MARK: open and close

    func open() {
        guard !isOpen else { return }
        if IsSecureEventInputEnabled() { Pill.shared.flash("Capture is off while secure input is on"); return }
        origin = NSWorkspace.shared.frontmostApplication
        mode = .paste; pick = .region; from = nil; to = nil; hover = nil
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
    }

    func close(_ why: String) {
        guard isOpen else { return }
        isOpen = false
        for p in panels { p.orderOut(nil) }
        panels = []
        NSCursor.pop()
        if why != "taken" { log("capture: closed (\(why))") }
    }

    private func redraw() { for p in panels { p.contentView?.needsDisplay = true } }

    // MARK: keys (from the event tap) and the mouse (from the panel)

    func key(_ code: Int) {
        switch ShotRules.key(code, dragging: from != nil) {
        case .cancel: close("esc")
        case .screen:
            let m = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main { take(s.frame, window: nil) }
        case .windowMode: pick = pick == .window ? .region : .window; hover = pick == .window ? windowAt(NSEvent.mouseLocation) : nil; redraw()
        case .mode(let m): mode = mode == m ? .paste : m; redraw()
        case .none: break
        }
    }

    func down(_ p: NSPoint) {
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
    private func take(_ rect: NSRect, window: CGWindowID?) {
        let t0 = Date(), mode = self.mode, origin = self.origin
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
            if let window, let w = content.windows.first(where: { $0.windowID == window }) {
                filter = SCContentFilter(desktopIndependentWindow: w)
                cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
            } else if let d = content.displays.first(where: { $0.displayID == did }) ?? content.displays.first {
                let own = content.applications.filter { $0.processID == getpid() }
                filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
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
                    let row = History.addPicture(png, width: img.width, height: img.height, app: origin?.localizedName ?? "")
                    self.land(png, row: row, mode: mode, origin: origin, t0: t0, shot: shot)
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
    private func land(_ png: Data, row: [String: Any], mode: ShotRules.Mode, origin: NSRunningApplication?, t0: Date, shot: Date) {
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
            CaptureNote.shared.open(png: png, row: row, origin: origin, t0: t0)
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
        // the hint: one slim line at the top of the screen under the mouse
        guard preview || screen.contains(NSEvent.mouseLocation) else { return }
        CaptureView.hint(m.mode, pick: m.pick, in: bounds)
    }

    static func hint(_ mode: ShotRules.Mode, pick: ShotRules.Pick, in b: NSRect) {
        let f = PK.text(13), a = TapeDraw.at(f, PK.ink)
        let keys: [(String, String, Bool)] = [("␣", "window", pick == .window), ("↵", "screen", false), ("K", "keep", mode == .keep),
                                              ("T", "text", mode == .text), ("esc", "cancel", false)]
        let lead = pick == .window ? "Click a window" : "Drag a region"
        var w = TapeDraw.width(lead, a) + 32
        for k in keys { w += TapeDraw.width(k.0, TapeDraw.at(PK.mono(11), PK.ink)) + 14 + 6 + TapeDraw.width(k.1, TapeDraw.at(f, PK.muted)) + 16 }
        let r = NSRect(x: (b.midX - w / 2).rounded(), y: b.maxY - 48 - 36, width: w.rounded(), height: 36)
        NSGraphicsContext.saveGraphicsState()
        PK.floatShadow().set(); PK.card.setFill(); NSBezierPath(roundedRect: r, xRadius: PK.corner(3), yRadius: PK.corner(3)).fill()
        NSGraphicsContext.restoreGraphicsState()
        // drawn flipped inside the strip, as the tapes are
        let img = NSImage(size: r.size, flipped: true) { box in
            TapeDraw.surface(box)
            var x: CGFloat = 16
            (lead as NSString).draw(at: NSPoint(x: x, y: TapeDraw.lineTop(f, mid: box.midY)), withAttributes: a)
            x += TapeDraw.width(lead, a) + 16
            for k in keys {
                let ka = TapeDraw.at(PK.mono(11), PK.ink), kw = TapeDraw.width(k.0, ka) + 14
                let kr = NSRect(x: x, y: box.midY - 11, width: kw, height: 22)
                let cap = NSBezierPath(roundedRect: kr, xRadius: TapeDraw.keyRadius, yRadius: TapeDraw.keyRadius)
                (k.2 ? TapeDraw.lift : PK.card).setFill(); cap.fill(); (k.2 ? PKColors.controlEdge : PK.line).setStroke(); cap.lineWidth = 1; cap.stroke()
                (k.0 as NSString).draw(at: NSPoint(x: kr.minX + 7, y: TapeDraw.lineTop(PK.mono(11), mid: kr.midY)), withAttributes: ka)
                x = kr.maxX + 6
                let wa = TapeDraw.at(f, k.2 ? PK.ink : PK.muted)
                (k.1 as NSString).draw(at: NSPoint(x: x, y: TapeDraw.lineTop(f, mid: box.midY)), withAttributes: wa)
                x += TapeDraw.width(k.1, wa) + 16
            }
            return true
        }
        img.draw(in: r)
    }
}

// MARK: previews (made-up screen, nothing captured)

extension Capture {
    /// The dimmed screen over a made-up window: a region being dragged (paste), and window mode with K on.
    static func preview(_ folder: String, dark: String) throws {
        let size = NSSize(width: 1200, height: 720)
        let m = Capture()
        for (name, setup) in [("capture-region", { (m: Capture) in m.from = NSPoint(x: 260, y: 200); m.to = NSPoint(x: 820, y: 520) }),
                              ("capture-window-keep", { (m: Capture) in m.pick = .window; m.mode = .keep
                                  m.hover = (1, NSRect(x: 140, y: 90, width: 760, height: 500)) })] {
            m.from = nil; m.to = nil; m.hover = nil; m.pick = .region; m.mode = .paste
            setup(m)
            let v = CaptureView(frame: NSRect(origin: .zero, size: size)); v.model = m; v.screen = v.frame; v.preview = true
            let img = NSImage(size: size, flipped: false) { r in
                NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.55, alpha: 1).setFill(); r.fill()
                let win = NSRect(x: 140, y: 90, width: 760, height: 500)
                NSColor.white.setFill(); NSBezierPath(roundedRect: win, xRadius: 10, yRadius: 10).fill()
                NSColor(white: 0.92, alpha: 1).setFill(); NSRect(x: win.minX, y: win.maxY - 40, width: win.width, height: 40).fill()
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray]
                for (i, l) in ["Invoice 0042", "Station redesign, drawings", "Total due: 1 250 EUR by Friday"].enumerated() {
                    (l as NSString).draw(at: NSPoint(x: win.minX + 40, y: win.maxY - 100 - CGFloat(i) * 44), withAttributes: a)
                }
                v.draw(r)
                return true
            }
            guard let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let d = rep.representation(using: .png, properties: [:]) else { continue }
            try d.write(to: URL(fileURLWithPath: folder + "/\(name)\(dark).png"))
        }
        // Part C: the strip after a capture (empty, then with a line), the markup editor, and a marked picture at full size
        let (pic, _, _) = try Quick.samplePicture()
        let png = try Data(contentsOf: History.clipURL(pic))
        let note = CaptureNote.shared
        note.open(png: png, row: ["clip": pic], origin: nil, t0: Date()); note.close()
        func save(_ v: NSView, _ name: String) throws {
            v.needsDisplay = true
            guard let rep = UIShots.bitmap(v), let d = rep.representation(using: .png, properties: [:]) else { return }
            try d.write(to: URL(fileURLWithPath: folder + "/\(name)\(dark).png"))
        }
        _ = note.view.fit(); try save(note.view, "capture-note")
        note.line = "the total is wrong, should be 1 150"; try save(note.view, "capture-note-line")
        let ed = MarkupEditor.shared
        ed.open(png, near: NSScreen.main) { _ in }
        ed.model.add(PicMark(tool: .arrow, from: CGPoint(x: 560, y: 330), to: CGPoint(x: 330, y: 170)))
        ed.model.add(PicMark(tool: .box, from: CGPoint(x: 24, y: 136), to: CGPoint(x: 360, y: 180)))
        ed.model.add(PicMark(tool: .highlight, from: CGPoint(x: 24, y: 90), to: CGPoint(x: 300, y: 128)))
        ed.model.add(PicMark(tool: .pixelate, from: CGPoint(x: 24, y: 2), to: CGPoint(x: 240, y: 52)))
        ed.model.add(PicMark(tool: .label, from: CGPoint(x: 400, y: 260), to: CGPoint(x: 400, y: 260), text: "should be 1 150"))
        ed.model.tool = .box
        try save(ed.view, "markup-editor")
        ed.model.add(PicMark(tool: .crop, from: CGPoint(x: 0, y: 60), to: CGPoint(x: 620, y: 360)))
        try save(ed.view, "markup-crop")
        let t0 = Date()
        if let b = ed.base, let out = MarkupDraw.render(b, ed.model), let d = MarkupDraw.png(out) {
            print("kinds: markup render \(out.width)x\(out.height) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            try d.write(to: URL(fileURLWithPath: folder + "/markup-result\(dark).png"))
        }
        ed.close(nil)
    }
}
