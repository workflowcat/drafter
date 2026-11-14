// The grey text at the caret and the action chip under it. A non-activating panel: it never takes focus or clicks.
import AppKit
import ScreenCaptureKit

final class Ghost {
    static let shared = Ghost()
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    let chip = NSTextField(labelWithString: "")
    private(set) var text = ""
    /// How many characters at the end of `text` the model was less sure of: drawn lighter (2026-10-21, Cotypist's few words).
    var unsure = 0
    private var ghostColor = NSColor.secondaryLabelColor
    private(set) var action: [String: Any]? = nil
    /// The letters a fix replaces (Fixer.swift): the ghost reads "→ word" and typing through it does not keep it.
    private(set) var replace = ""
    var visible: Bool { panel.isVisible && (!text.isEmpty || action != nil) }

    let chipBox = Ground()
    let mark = KindMark()
    private var fontCache: (AXUIElement, NSFont, NSColor?)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(); panel.contentView = v
        label.lineBreakMode = .byClipping
        chip.lineBreakMode = .byTruncatingTail
        chipBox.addSubview(mark); chipBox.addSubview(chip)
        v.addSubview(label); v.addSubview(chipBox)
    }

    /// The field's font and text colour at the caret (read once per field), else a size from the caret's height.
    private func fieldFont(_ height: CGFloat) -> (NSFont, NSColor) {
        let grey = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        if let s = Keys.shared.spot {
            if let c = fontCache, CFEqual(c.0, s.el) { return (c.1, (c.2 ?? .labelColor).withAlphaComponent(0.38)) }
            if let (f, col) = Focus.font(s.el, caret: s.caret) { fontCache = (s.el, f, col); return (f, (col ?? .labelColor).withAlphaComponent(0.38)) }
        }
        return (.systemFont(ofSize: max(11, min(26, height * 0.78))), grey)
    }

    /// AX rects are top-left based on the primary screen; Cocoa windows are bottom-left.
    func cocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    func show(_ suggestion: String, action: [String: Any]?, at caret: CGRect, replace: String = "") {
        plain()
        if !self.replace.isEmpty, replace.isEmpty { Fixer.hidden() }   // a fix offer covered by a chip ends here (Argon 22)
        text = suggestion; self.action = action; self.replace = replace
        let c = cocoa(caret)
        // the grey words in the field's own font, as if already typed; no keycap after them since 1 November 2026
        // (Andrii: "I know what tab does, clean it up")
        let (font, color) = fieldFont(c.height)
        label.font = font; label.textColor = color; ghostColor = color
        unsure = min(unsure, suggestion.count)
        paint(suggestion)
        label.sizeToFit()
        let lh = max(c.height, label.frame.height)
        var w: CGFloat = suggestion.isEmpty ? 0 : label.frame.width
        // a chip: a flat row under the caret - kind square, then the offer
        var chipH: CGFloat = 0, chipW: CGFloat = 0
        if let a = action, let t = a["chip"] as? String {
            // a chip: a flat row under the caret - the kind's pixel mark in its colour, then the offer in Fixel
            mark.kind = Kind.of(a["id"] as? String ?? "")
            chip.font = PK.text(13); chip.textColor = PK.ink
            chip.stringValue = t.hasPrefix("⇥ ") ? String(t.dropFirst(2)) : t
            chip.sizeToFit()
            let tw = min(chip.frame.width, 420)
            chipH = max(26, chip.frame.height + 10)
            chipW = 7 + 16 + 7 + tw + 10
            chipBox.frame = NSRect(x: 0, y: 0, width: chipW, height: chipH)
            mark.frame = NSRect(x: 7, y: ((chipH - 16) / 2).rounded(), width: 16, height: 16)
            chip.frame = NSRect(x: 30, y: ((chipH - chip.frame.height) / 2).rounded(), width: tw, height: chip.frame.height)
            chipBox.isHidden = false; chipBox.needsDisplay = true; mark.needsDisplay = true
            w = max(w, chipW)
        } else { chipBox.isHidden = true }
        let gap: CGFloat = chipH > 0 ? 6 : 0
        let frame = NSRect(x: c.maxX, y: c.minY - chipH - gap, width: w + 4, height: lh + chipH + gap)
        panel.setFrame(frame, display: false)
        // baseline: the grey text sits on the caret's line, centred in its height like the text it continues
        label.frame = NSRect(x: 0, y: chipH + gap + (lh - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        appear()
    }

    /// Grey words show at full strength in their first frame (14 November 2026, speed first: a 90 ms fade from zero
    /// made the logged "shown" come before the words could be read). A new chip still fades in over 90 ms (none under
    /// Reduce Motion); one that follows another while he types just changes, so nothing blinks.
    private func appear() {
        if panel.isVisible || action == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1; panel.orderFrontRegardless(); return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.09; panel.animator().alphaValue = 1 }
    }

    /// His next message for an empty box (2026-10-20, like ChatGPT's suggested prompt): a small card just above the
    /// field (the app's placeholder stays uncovered). Several options: "‹ 2/5 · label ›" on top, the message in two
    /// lines under it; ←/→ flip, ↓ opens the whole message, ↑ folds it back, Tab puts the shown one in.
    private(set) var isDraft = false
    private(set) var expanded = false
    private(set) var cut = false   // folded and the message has more lines than the two shown (GhostRules.draftTab)
    let card: Ground = { let g = Ground(); g.radius = 8; return g }()
    let head = NSTextField(labelWithString: "")
    let cardKey = KeyCap()   // ↓ / ↑: the whole message or folded
    let cardMark = KindMark()   // the next message: an item, blue
    private var draftField: CGRect?, draftCaret = CGRect.zero
    private var options: [[String: String]] = [], index = 0

    func showDraft(_ opts: [[String: String]], field: CGRect?, caret: CGRect) {
        options = opts; index = 0; expanded = false; draftField = field; draftCaret = caret
        layoutDraft()
    }

    func flip(_ by: Int) {
        guard isDraft, options.count > 1 else { return }
        index = (index + by + options.count) % options.count
        layoutDraft()
    }

    func expand(_ on: Bool) { guard isDraft, expanded != on else { return }; expanded = on; layoutDraft() }

    private func layoutDraft() {
        guard index < options.count else { return }
        let o = options[index]
        text = o["text"] ?? ""; action = nil; isDraft = true
        let c = cocoa(draftCaret)
        let size = max(11, min(14, c.height * 0.72))
        let width = min(520, max(240, (draftField?.width ?? 440) * 0.8))
        if card.superview == nil {
            panel.contentView?.addSubview(card, positioned: .below, relativeTo: label)
            panel.contentView?.addSubview(head)
            panel.contentView?.addSubview(cardKey)
            panel.contentView?.addSubview(cardMark)
        }
        card.isHidden = false; head.isHidden = false; cardMark.isHidden = false; chipBox.isHidden = true
        card.needsDisplay = true
        // head: the kind's mark, the gist in Fixel, "1/3 ←→" in quiet mono; one keycap on the right says what ↓/↑ do
        cardMark.kind = .next
        let gist = o["label"] ?? ""
        let h1 = NSMutableAttributedString(string: gist, attributes: [.font: PK.text(12, .medium), .foregroundColor: PK.muted])
        if options.count > 1 {
            h1.append(NSAttributedString(string: "   \(index + 1)/\(options.count) ←→", attributes: [.font: PK.mono(10.5), .foregroundColor: PK.faint]))
        }
        head.attributedStringValue = h1
        head.lineBreakMode = .byTruncatingTail
        head.sizeToFit()
        cardKey.label = expanded ? "↑" : "↓"
        cardKey.size = 10; cardKey.faint = false; cardKey.fit(); cardKey.isHidden = false; cardKey.needsDisplay = true
        label.font = PK.text(size + 0.5); label.textColor = PK.ink
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = expanded ? 10 : 2
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = width - 24
        label.stringValue = text
        let fit = label.sizeThatFits(NSSize(width: width - 24, height: 600))
        if !expanded { label.maximumNumberOfLines = 0; cut = label.sizeThatFits(NSSize(width: width - 24, height: 6000)).height > fit.height + 0.5; label.maximumNumberOfLines = 2 } else { cut = false }
        let hh = max(16, head.frame.height, cardKey.frame.height)
        let h = fit.height + hh + 26
        let x = (draftField.map { cocoa($0).minX } ?? c.minX - 8)
        let top = draftField.map { cocoa($0).maxY } ?? c.maxY
        panel.setFrame(NSRect(x: x, y: top + 10, width: width, height: h), display: false)
        card.frame = NSRect(x: 0, y: 0, width: width, height: h)
        let k1 = cardKey.frame.width
        let headY = h - 10 - hh
        cardKey.frame.origin = NSPoint(x: width - 10 - k1, y: (headY + (hh - cardKey.frame.height) / 2).rounded())
        cardMark.frame = NSRect(x: 10, y: (headY + (hh - 16) / 2).rounded(), width: 16, height: 16); cardMark.needsDisplay = true
        head.frame = NSRect(x: 32, y: (headY + (hh - head.frame.height) / 2).rounded(), width: width - 52 - k1, height: head.frame.height)
        label.frame = NSRect(x: 12, y: 10, width: width - 24, height: fit.height)
        panel.orderFrontRegardless()
    }

    private func plain() {
        guard isDraft else { return }
        isDraft = false; expanded = false; card.isHidden = true; head.isHidden = true; cardKey.isHidden = true; cardMark.isHidden = true
        label.lineBreakMode = .byClipping; label.maximumNumberOfLines = 1; label.preferredMaxLayoutWidth = 0
    }

    /// The grey words: the sure part in the ghost colour, the less sure tail at half of it.
    private func paint(_ t: String) {
        let font = label.font ?? .systemFont(ofSize: 13)
        let cut = t.index(t.endIndex, offsetBy: -min(unsure, t.count))
        let m = NSMutableAttributedString()
        // a fix: a coral arrow, then the whole word as it should be
        if !replace.isEmpty { m.append(NSAttributedString(string: " → ", attributes: [.font: font, .foregroundColor: PK.warn])) }
        m.append(NSAttributedString(string: String(t[..<cut]), attributes: [.font: font, .foregroundColor: ghostColor]))
        m.append(NSAttributedString(string: String(t[cut...]), attributes: [.font: font, .foregroundColor: ghostColor.withAlphaComponent(ghostColor.alphaComponent * 0.55)]))
        label.attributedStringValue = m
    }

    /// Two-step ghost (round two, 2026-11-13): more words at the end of the grey text being shown, in place. Nothing
    /// moves and the words already there stay as they were; `unsure` is how many characters at the end are lighter.
    func extend(_ more: String, unsure tail: Int) {
        guard visible, action == nil, !isDraft, replace.isEmpty, !more.isEmpty else { return }
        text += more
        unsure = max(0, min(tail, text.count))
        paint(text)
        label.sizeToFit()
        var f = panel.frame
        f.size.width = max(f.size.width, label.frame.width + 4)
        panel.setFrame(f, display: true)
    }

    /// Typing the same letters as the ghost keeps it and only drops what was typed.
    func consume(_ typed: String) -> Bool {
        guard !text.isEmpty, action == nil, !isDraft, replace.isEmpty, text.hasPrefix(typed) else { return false }
        if text.count == typed.count { hide(); return true }   // typed it all: nothing left to show
        text.removeFirst(typed.count)
        unsure = min(unsure, text.count)
        paint(text)
        label.sizeToFit()
        var f = panel.frame
        // move right by the width of what was typed
        let typedW = (typed as NSString).size(withAttributes: [.font: label.font as Any]).width
        f.origin.x += typedW; f.size.width = label.frame.width + 4
        panel.setFrame(f, display: true)
        return true
    }

    func hide() {
        if !replace.isEmpty { Fixer.hidden() }   // a fix offer went: taken, typed over or expired (log)
        text = ""; action = nil; replace = ""; unsure = 0; plain()
        panel.orderOut(nil)
    }

    func flash(_ s: String) {
        guard let scr = NSScreen.main else { return }
        hide()
        label.font = PK.text(13, .medium); label.textColor = .secondaryLabelColor; label.stringValue = s; label.sizeToFit()
        chipBox.isHidden = true; panel.alphaValue = 1
        let f = scr.visibleFrame
        panel.setFrame(NSRect(x: f.maxX - label.frame.width - 24, y: f.maxY - 34, width: label.frame.width + 8, height: 24), display: false)
        label.frame.origin = NSPoint(x: 4, y: 4)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.text.isEmpty == true && self?.action == nil { self?.panel.orderOut(nil) }
        }
    }
}


/// PixelKit for the suggestion panel (2026-10-21, Andrii: "kind of meh"): Paper or Charcoal by the system look, one
/// ink, square corners (2 px), no shadow; a colour only as a small square for the kind of offer.


/// A keycap: a tint of ink, a darker bottom edge, small cut corners (PixelKit `pk-key`), with a short mono label.
final class KeyCap: NSView {
    var label = "tab" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var size: CGFloat = 10
    var faint = false
    var tint: NSColor?   // the field's text colour, for the keycap after the grey words
    private var ink: NSColor { tint ?? PK.ink }
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: PK.mono(size, .medium), .foregroundColor: ink.withAlphaComponent(faint ? 0.45 : 0.75)]
    }
    override var intrinsicContentSize: NSSize {
        let t = (label as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(t.width) + 10, height: ceil(t.height) + 5)
    }
    func fit() { setFrameSize(intrinsicContentSize) }
    override func draw(_ r: NSRect) {
        let b = bounds, c: CGFloat = 2
        let p = NSBezierPath()   // cut corners, a pixel step instead of a curve
        p.move(to: NSPoint(x: b.minX + c, y: b.minY)); p.line(to: NSPoint(x: b.maxX - c, y: b.minY))
        p.line(to: NSPoint(x: b.maxX, y: b.minY + c)); p.line(to: NSPoint(x: b.maxX, y: b.maxY - c))
        p.line(to: NSPoint(x: b.maxX - c, y: b.maxY)); p.line(to: NSPoint(x: b.minX + c, y: b.maxY))
        p.line(to: NSPoint(x: b.minX, y: b.maxY - c)); p.line(to: NSPoint(x: b.minX, y: b.minY + c)); p.close()
        (tint == nil ? PK.key : ink.withAlphaComponent(faint ? 0.07 : 0.10)).setFill(); p.fill()
        (tint == nil ? PK.keyEdge : ink.withAlphaComponent(faint ? 0.16 : 0.24)).setFill()   // the bottom edge
        NSRect(x: b.minX + c, y: b.minY, width: b.width - 2 * c, height: 2).fill()
        let t = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: (b.width - t.width) / 2, y: (b.height - t.height) / 2 + 1), withAttributes: attrs)
    }
}

/// A flat PixelKit panel ground: card, a one-pixel rule, PixelKit's small corner (4 px for a chip, 8 px for a card).
final class Ground: NSView {
    var radius: CGFloat = 4
    override func draw(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        PK.card.setFill(); p.fill()
        PK.rule.setStroke(); p.lineWidth = 0.5; p.stroke()
    }
}

/// The kind of offer as its PixelKit mark (16 grid at 16 pt), drawn in the kind's colour (`Kind` in Theme.swift).
final class KindMark: NSView {
    var kind: Kind = .action { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) { PK.drawMark(kind.mark, in: bounds, tint: kind.color) }
}


extension Ghost {
    /// Test: a picture of the panel and what is around it into data/ghost.png (post <bundle id>.ghostshot).
    func shot() {
        guard panel.isVisible, let scr = NSScreen.screens.first else { log("ghostshot: nothing shown"); return }
        let f = panel.frame, h = scr.frame.height
        let r = CGRect(x: f.minX - 260, y: h - f.maxY - 60, width: max(560, f.width + 300), height: f.height + 120)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
            guard let d = c?.displays.first else { return }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = r; cfg.width = Int(r.width * 2); cfg.height = Int(r.height * 2)
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                let out = Home.data.appendingPathComponent("ghost.png")
                if let img, let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
                log("ghostshot: \(img == nil ? "failed" : "saved")")
            }
        }
    }
}
