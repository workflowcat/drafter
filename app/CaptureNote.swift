// "What is this?" (round three, Part C, 14 November 2026): after a capture a slim strip at the caret holds the picture
// and one line. ↵ puts the picture in (with his line when he typed one: ↵ on an empty line is one instant key),
// ⌘↵ the picture and its read text, ⌘E opens markup (the marked picture replaces the capture, the original stays on
// the tape), esc the picture alone. Delivery (ShotRules.delivery): two pastes in a row, picture first, the text after
// a short wait; where no field takes them, both sit on the clipboard as one item (picture and text types), so the
// text is never lost. Keys come through the event tap (Quick.tap); the strip never becomes key.
import AppKit

final class CaptureNote {
    static let shared = CaptureNote()
    private(set) var isOpen = false
    var line = ""
    private(set) var png = Data()
    private(set) var thumb: NSImage?
    private var row: [String: Any] = [:]
    private var origin: NSRunningApplication?
    private var t0 = Date()
    let panel: NSPanel
    let view = CaptureNoteView()

    init() {
        panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: CaptureNoteView.H), styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.model = self; panel.contentView = view
    }

    func open(png: Data, row: [String: Any], origin: NSRunningApplication?, t0: Date) {
        self.png = png; self.row = row; self.origin = origin; self.t0 = t0; line = ""
        thumb = NSImage(data: png)
        isOpen = true
        place()
        view.needsDisplay = true
        panel.orderFrontRegardless()
        log("capture: note open, \(Int(Date().timeIntervalSince(t0) * 1000)) ms after release")
    }

    func close() { isOpen = false; panel.orderOut(nil) }

    /// Under the caret (or the focused field), else in the upper third of the mouse's screen.
    private func place() {
        let size = view.fit()
        let h = NSScreen.screens.first?.frame.height ?? 0
        var anchor: CGRect?
        if let app = origin, app.processIdentifier != getpid(), let el = Focus.focused() {
            AXUIElementSetMessagingTimeout(el, 0.08)
            anchor = Focus.selectionRect(el) ?? Focus.frame(el)
        }
        if let a = anchor, let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: a.midX, y: h - a.midY)) }) {
            let vis = scr.visibleFrame, p = CaptureNoteView.pad
            var y = h - a.maxY - 6 - size.height + p
            if y + p < vis.minY + 4 { y = h - a.minY + 6 - p }
            let x = min(max(a.minX - p, vis.minX - p + 4), vis.maxX - size.width + p - 4)
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let vis = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: vis.midX - size.width / 2, y: vis.maxY - vis.height / 3, width: size.width, height: size.height), display: false)
    }

    /// A key from the event tap while the strip is open.
    func key(_ code: Int, _ ch: String, cmd: Bool) {
        if cmd, code == 14 { markup(); return }   // ⌘E
        if let n = ShotRules.note(code: code, cmd: cmd, line: line) { send(n); return }
        if code == 51 { if !line.isEmpty { line.removeLast() } }
        else if !cmd, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), line.count < 400 { line += ch }
        view.needsDisplay = true
    }

    private func markup() {
        panel.orderOut(nil)
        let scr = NSScreen.screens.first { $0.frame.intersects(panel.frame) }
        MarkupEditor.shared.open(png, near: scr) { marked in
            if let marked {
                // the marked picture is the one that goes in; the capture stays on the tape as it was
                let size = NSBitmapImageRep(data: marked).map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
                self.row = History.addPicture(marked, width: size.0, height: size.1, app: self.origin?.localizedName ?? "")
                self.png = marked; self.thumb = NSImage(data: marked)
            }
            _ = self.view.fit()
            self.place(); self.view.needsDisplay = true
            self.panel.orderFrontRegardless()
        }
    }

    private func send(_ n: ShotRules.Note) {
        close()
        let pic = row["clip"] as? String ?? ""
        let read = pic.isEmpty ? "" : History.clipText(pic)
        let d = ShotRules.delivery(n, read: read)
        if case .pictureAndText = n, d.text == nil, !pic.isEmpty {
            // not read yet (the read runs once, off the main thread): read it now, then go on
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
        let t1 = Date()
        if !Capture.target(origin) {
            // no field: one clipboard item with both, so ⌘V somewhere gives the picture and the text stays with it
            let png = self.png
            History.copy(d.text ?? "") { pb in Capture.pictureWriter(png)(pb); if let t = d.text { pb.setString(t, forType: .string) } }
            Pill.shared.flash(d.text == nil ? "The field takes no picture · it is on the clipboard" : "Picture and text on the clipboard")
            log("capture: note on the clipboard")
            return
        }
        Focus.paste("", write: Capture.pictureWriter(png))
        let total = Int(t1.timeIntervalSince(t0) * 1000)
        guard let text = d.text else { log("capture: picture pasted, \(total) ms after release"); return }
        let origin = self.origin
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(d.gapMs)) {
            let how = Capture.put(text: text, origin: origin)
            log("capture: picture and \(text.count) chars (\(how)), picture \(total) ms after release")
        }
    }
}

final class CaptureNoteView: NSView {
    weak var model: CaptureNote?
    override var isFlipped: Bool { true }
    static let stripH: CGFloat = 40, pad: CGFloat = 16, lineW: CGFloat = 300
    static var H: CGFloat { stripH + 2 * pad }
    private static let keys: [(String, String)] = [("↵", "put in"), ("⌘↵", "with its text"), ("⌘E", "mark up"), ("esc", "picture")]

    func fit() -> NSSize {
        var w: CGFloat = 8 + 44 + 10 + Self.lineW + 12
        let a = TapeDraw.at(PK.text(13), PK.muted)
        for k in Self.keys { w += TapeDraw.width(k.0, TapeDraw.at(PK.mono(11), PK.ink)) + 14 + 6 + TapeDraw.width(k.1, a) + 12 }
        frame = NSRect(x: 0, y: 0, width: (w + 2 * Self.pad).rounded(), height: Self.H)
        return frame.size
    }

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let strip = NSRect(x: Self.pad, y: Self.pad, width: bounds.width - 2 * Self.pad, height: Self.stripH)
        NSGraphicsContext.saveGraphicsState()
        PK.floatShadow().set(); PK.card.setFill(); NSBezierPath(roundedRect: strip, xRadius: PK.corner(3), yRadius: PK.corner(3)).fill()
        NSGraphicsContext.restoreGraphicsState()
        TapeDraw.surface(strip)
        var x = strip.minX + 8
        if let t = m.thumb { x = TapeDraw.picture(t, in: NSRect(x: x, y: strip.minY + 6, width: 44, height: Self.stripH - 12)).maxX }
        x += 10
        let f = PK.text(14), mid = strip.midY
        let empty = m.line.isEmpty
        let a = TapeDraw.at(f, empty ? PK.faint : PK.ink, cut: .byTruncatingHead)
        let shown = empty ? "What is this?" : m.line
        TapeDraw.line(shown, NSRect(x: x, y: TapeDraw.lineTop(f, mid: mid), width: Self.lineW, height: 20), a)
        PK.blue.setFill()
        NSRect(x: x + (empty ? 0 : min(Self.lineW, TapeDraw.width(m.line, a) + 1)), y: mid - 9, width: 2, height: 18).fill()
        x += Self.lineW + 12
        for k in Self.keys {
            let ka = TapeDraw.at(PK.mono(11), PK.ink), kw = TapeDraw.width(k.0, ka) + 14
            let kr = NSRect(x: x, y: mid - 11, width: kw, height: 22)
            let cap = NSBezierPath(roundedRect: kr, xRadius: TapeDraw.keyRadius, yRadius: TapeDraw.keyRadius)
            PK.card.setFill(); cap.fill(); PK.line.setStroke(); cap.lineWidth = 1; cap.stroke()
            (k.0 as NSString).draw(at: NSPoint(x: kr.minX + 7, y: TapeDraw.lineTop(PK.mono(11), mid: mid)), withAttributes: ka)
            x = kr.maxX + 6
            let wa = TapeDraw.at(PK.text(13), PK.muted)
            (k.1 as NSString).draw(at: NSPoint(x: x, y: TapeDraw.lineTop(PK.text(13), mid: mid)), withAttributes: wa)
            x += TapeDraw.width(k.1, wa) + 12
        }
    }
}
