// The voice strip: notch-black, a pixel microphone, and two steady lines of subdued live words with a small waveform
// behind the newest word (14 November 2026, Tape round). No numbers are drawn for levels.
// Clicks go through it.
import AppKit

final class Pill {
    static let shared = Pill()
    static var font: NSFont { PK.body(14) }   // two lines of live words (Tape round); asked each time, a theme can change it
    static let lineH: CGFloat = 20
    private var panel: NSPanel?
    private let box = PillView()
    private let words = NSTextField(labelWithString: "")
    private var hideToken = 0
    private let status = NSTextField(labelWithString: "")   // the notch row's right side: "Нотатка · 12:34"
    private var lines: CGFloat = 5
    private let state = NSTextField(labelWithString: "")
    private var previewing = false
    private var previewNotch: CGFloat?
    private var settledLength = 0
    private var styledDraft = false
    private var layoutGen = 0
    // the last row's buttons (offer keys, Stop & save, Undo); clicks reach them through `hits`, a small clear panel over
    // just that row, so the rest of the strip still lets clicks through (2026-11-01, Codex notch review)
    private var controls: [StripButton] = []
    private var hits: NSPanel?
    private let hitView = HitView()
    private var screenID: NSNumber?          // the display a take or offer started on: it stays there
    private var meSeen = false, themSeen = false

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)   // over the menu bar, like the notch
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Explicit notch treatment: stay black in both macOS appearances.
        box.appearance = NSAppearance(named: .darkAqua)
        p.contentView = box

        words.font = Pill.font
        words.textColor = PK.muted
        words.lineBreakMode = .byWordWrapping
        words.maximumNumberOfLines = 5
        words.cell?.wraps = true
        words.alignment = .left
        box.addSubview(words)
        status.font = PK.mono(10)
        status.textColor = PK.faint; status.alignment = .right
        box.addSubview(status)
        state.font = PK.display(11.5); state.textColor = PK.muted
        box.addSubview(state)
        box.appearanceChanged = { [weak self] in self?.refreshAppearance() }
        return p
    }

    /// Size and place (2026-10-20, Andrii: "jumpy, a bit too big"): a slim island just wider than the notch while there
    /// is no text (dot and meter on the left wing, status on the right), opening downward to a fixed number of lines
    /// when there is. The size changes only when that changes, never per word, and then it slides (0.2 s), pinned to the top.
    private var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID } ?? NSScreen.main
    }
    /// A new take or offer stays on the display it started on (not the one focus moves to); one that is gone re-homes.
    private func pin() {
        guard panel?.isVisible != true || !NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID }) else { return }
        screenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
    private func notchWidth() -> CGFloat {
        if let previewNotch { return previewNotch }
        guard let s = screen, s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 0 }
        return max(120, s.frame.width - l.width - r.width)
    }
    private func openWidth() -> CGFloat { let n = notchWidth(); return n > 0 ? max(n + 2 * 120, 460) : 460 }

    /// Lines a text really takes in the open strip, at most `max` (2026-10-30: a one-word receipt left two empty lines).
    private func fit(_ text: String, max n: Int) -> Int {
        let font = words.font ?? Pill.font
        var total = 0
        for para in text.components(separatedBy: "\n") {
            let r = (para.isEmpty ? " " : para as NSString).boundingRect(with: NSSize(width: openWidth() - 32, height: 1000),
                                                                         options: [.usesLineFragmentOrigin], attributes: [.font: font])
            total += max(1, Int(ceil(r.height / ceil(font.ascender - font.descender + font.leading))))
        }
        return min(n, max(1, total))
    }

    /// One line that fits the open strip, cut with "…" (an event title never wraps into the keys' row).
    private func clip(_ t: String) -> String {
        let a: [NSAttributedString.Key: Any] = [.font: words.font ?? Pill.font], room = openWidth() - 36
        if (t as NSString).size(withAttributes: a).width <= room { return t }
        var lo = 0, hi = t.count
        while lo < hi { let m = (lo + hi + 1) / 2; if ((String(t.prefix(m)) + "…") as NSString).size(withAttributes: a).width <= room { lo = m } else { hi = m - 1 } }
        return String(t.prefix(lo)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func setControls(_ list: [StripButton]) {
        controls.forEach { $0.removeFromSuperview() }
        controls = list; list.forEach { box.addSubview($0) }
        hitView.buttons = list
        if list.isEmpty { hits?.orderOut(nil) }
    }

    private func close() { layoutGen += 1; panel?.ignoresMouseEvents = true; panel?.orderOut(nil); hits?.orderOut(nil) }

    /// The clear panel over the buttons, placed for the strip's final frame.
    private func placeHits(_ frame: NSRect) {
        guard !controls.isEmpty, !previewing, panel?.isVisible == true else { hits?.orderOut(nil); return }
        if hits == nil {
            let h = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            h.isOpaque = false; h.backgroundColor = .clear; h.hasShadow = false; h.ignoresMouseEvents = false
            h.acceptsMouseMovedEvents = true
            h.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
            h.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            h.contentView = hitView
            hits = h
        }
        let u = controls.dropFirst().reduce(controls[0].frame) { $0.union($1.frame) }.insetBy(dx: -4, dy: -3)   // 30 pt targets
        hitView.origin = u.origin
        hits?.setFrame(NSRect(x: frame.minX + u.minX, y: frame.minY + u.minY, width: u.width, height: u.height), display: true)
        hits?.orderFrontRegardless()
        if debugLog { log("strip buttons: " + controls.map { "\($0.label) \(Int(frame.minX + $0.frame.midX)),\(Int(frame.minY + $0.frame.midY))" }.joined(separator: "; ")) }
    }

    private func announce(_ text: String) {
        guard !previewing else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func place() {
        guard let s = screen, let p = panel else { return }
        let bar: CGFloat = previewNotch == 0 ? 28 : (s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : 28)
        let notch = notchWidth()
        let open = !words.stringValue.isEmpty
        let w = open ? openWidth() : (notch > 0 ? notch + 2 * 86 : 260)
        let row: CGFloat = controls.isEmpty ? 0 : 34             // the buttons' row under the text
        let rows = open ? box.levelRowsH : 0                     // a long note or call: one thin level row per side
        let textH = open ? lines * Pill.lineH + 16 + row + rows : 0
        let h = bar + textH
        // no notch (an external screen): a floating pill just under the menu bar instead of a hanging strip
        box.floating = notch == 0
        let topY = notch > 0 ? s.frame.maxY : s.visibleFrame.maxY - 6
        let target = NSRect(x: s.frame.midX - w / 2, y: topY - h, width: w, height: h)
        // children laid out from the top, for the size the window has now; autoresizing keeps them pinned while it slides
        let cur = p.isVisible ? p.frame.size : target.size
        func top(_ fromTop: CGFloat, _ height: CGFloat) -> CGFloat { cur.height - fromTop - height }
        let mid = bar / 2
        box.frame = NSRect(origin: .zero, size: cur)
        box.dotFromTop = mid - 3

        state.autoresizingMask = [.minYMargin]
        state.frame = NSRect(x: 30, y: top(mid - 7, 14), width: notch > 0 ? max(48, (w - notch) / 2 - 36) : 125, height: 14)
        words.autoresizingMask = [.minYMargin]
        words.frame = NSRect(x: 16, y: top(bar + 4, max(1, textH - 8 - row - rows)), width: w - 32, height: max(1, textH - 8 - row - rows))
        box.levelRowsTop = row + rows                             // from the bottom: the level rows sit over the buttons
        placeWave()
        var bx: CGFloat = 16
        for b in controls { b.autoresizingMask = [.maxYMargin]; b.setFrameOrigin(NSPoint(x: bx, y: 8)); bx += b.frame.width + 8 }
        status.autoresizingMask = [.minYMargin, .minXMargin]
        let sx = notch > 0 ? w / 2 + notch / 2 + 6 : w - 130
        status.frame = NSRect(x: sx, y: top(mid - 8, 16), width: max(10, w - sx - 16), height: 16)
        // one layout at a time: a newer one makes an older animation's end do nothing (Codex round 4: stale button spots)
        layoutGen += 1; let gen = layoutGen
        if p.isVisible, p.frame.size != target.size, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hits?.orderOut(nil)
            // while it slides, the strip itself takes clicks (and drops them), so a click meant for a button never
            // falls through to the app under it
            p.ignoresMouseEvents = controls.isEmpty
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; c.timingFunction = CAMediaTimingFunction(name: .easeOut); p.animator().setFrame(target, display: true) },
                                                 completionHandler: { [weak self] in
                                                     guard let self, gen == self.layoutGen else { return }
                                                     p.ignoresMouseEvents = true; self.placeHits(target)
                                                 })
        } else {
            p.ignoresMouseEvents = true
            if p.frame != target { p.setFrame(target, display: true) }
            DispatchQueue.main.async { [weak self] in   // after present() put the strip up
                guard let self, gen == self.layoutGen else { return }
                self.placeHits(target)
            }
        }
        box.needsDisplay = true
    }

    func listening() {
        hideToken += 1
        if panel == nil { panel = make() }
        pin(); setControls([])
        box.long = false; box.done = false; box.countdown = nil; box.levels = nil; meSeen = false
        setState("Listening", glyphOnly: true); status.stringValue = ""; lines = 2; words.maximumNumberOfLines = 2; stayOpen = false; oldText = ""; anchor = 0; prevWords = []
        status.textColor = PK.faint
        words.textColor = PK.muted
        words.stringValue = ""; styledDraft = false; box.wave = []; box.waveRect = nil; box.tick = false
        place()
        box.reading = false
        present()
    }

    private func setState(_ title: String, glyphOnly: Bool = false) {
        state.stringValue = glyphOnly ? "" : title; box.hearing = false
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(title)
    }

    private func present() { if !previewing { panel?.orderFrontRegardless() } }

    /// Sound levels, drawn without numbers (14 November 2026, Tape round). A short take keeps a still microphone and
    /// shows his voice as a small pixel waveform behind the newest word (2 pt bars every 4 pt, scrolling). A long note or
    /// call shows one thin level row per side under the text, lit in the side's colour (2026-10-30: is the other side
    /// being recorded? see it while it runs). Reduce Motion: nothing scrolls; a side lights once it has been heard.
    private var heldMe: Float = 0, heldThem: Float = 0, levelAt = Date.distantPast
    static let waveStep = 0.08
    static func share(_ pk: Float) -> CGFloat {   // -50 dB .. -6 dB as 0 ... 1
        CGFloat(max(0, min(1, (20 * log10(max(pk, 1e-5)) + 50) / 44)))
    }
    func level(_ pk: Float, them: Float? = nil) {
        heldMe = max(heldMe, pk); if let them { heldThem = max(heldThem, them) }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard Date().timeIntervalSince(levelAt) > (box.long ? 0.25 : Pill.waveStep) else { return }
        levelAt = Date()
        meSeen = meSeen || heldMe >= 0.004; themSeen = themSeen || heldThem >= 0.004
        if box.long {
            box.levels = still ? (meSeen ? 0.3 : 0, them == nil ? nil : (themSeen ? 0.3 : 0))
                               : (Pill.share(heldMe), them == nil ? nil : Pill.share(heldThem))
            box.needsDisplay = true
        } else if box.waveRect != nil {
            if still { box.wave = meSeen ? PillView.stillWave : [] }
            else { box.wave.append(Pill.share(heldMe)); if box.wave.count > 96 { box.wave.removeFirst(box.wave.count - 96) } }
            box.setNeedsDisplay(box.waveDrawRect.insetBy(dx: -2, dy: -2))
        }
        heldMe = 0; heldThem = 0
    }

    /// Where the waveform goes: behind the newest word of the live words (none while they are empty or a note shows).
    private func placeWave() {
        guard !box.long, styledDraft, !oldText.isEmpty, words.frame.width > 1 else { box.waveRect = nil; return }
        let text = words.attributedStringValue
        let storage = NSTextStorage(attributedString: text), lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: words.frame.width - 4, height: 1000)); tc.lineFragmentPadding = 0
        lm.addTextContainer(tc); storage.addLayoutManager(lm)
        let ns = text.string as NSString
        var end = ns.length; while end > 0, ns.character(at: end - 1) == 32 { end -= 1 }
        guard end > 0 else { box.waveRect = nil; return }
        let start = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: NSRange(location: 0, length: end)).location
        let from = start == NSNotFound ? 0 : start + 1
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: from, length: end - from), actualCharacterRange: nil)
        let r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        // the field draws its text from the top with a 2 pt inset; the strip's view counts from the bottom
        // kept from the top (y = distance from the strip's top edge), so it stays put while the strip slides open
        let width = max(56, r.width + 20)
        let x = max(words.frame.minX, words.frame.minX + 2 + r.midX - width / 2)
        let fromTop = box.bounds.height - words.frame.maxY + r.minY - 3
        box.waveRect = NSRect(x: x, y: fromTop, width: min(width, box.bounds.width - 16 - x), height: r.height).integral
        box.needsDisplay = true
    }

    private func refreshAppearance() {
        state.textColor = PK.muted; status.textColor = PK.faint
        if styledDraft { renderDraft() } else { words.textColor = PK.muted }
        box.needsDisplay = true
    }

    /// The preview: the words heard so far (latest ~420 characters) in up to five lines under the notch.
    private var stayOpen = false   // opened once in this take: stays open until it ends (no snap shut on Enter)

    func draft(_ text: String) {
        if text.isEmpty, stayOpen {   // Enter put the words in: say so quietly, keep the size
            styledDraft = false; words.textColor = PK.faint; words.stringValue = Pill.insertedNote
            box.waveRect = nil; box.tick = true; box.tickFromTop = box.bounds.height - words.frame.maxY + 2; box.needsDisplay = true
            return
        }
        if !text.isEmpty { stayOpen = true; box.tick = false }
        let was = words.stringValue.isEmpty
        // steady text (2026-10-20, flicker on long takes): the shown part starts at an anchor that only moves forward,
        // a whole sentence at a time, when three lines are full; between those moves the text only grows at the end
        if text.count < anchor { anchor = 0 }
        var shown = String(text.dropFirst(anchor))
        if fit(shown, max: 3) > 2 {
            let cut = shown.index(shown.endIndex, offsetBy: -min(shown.count, 90))
            let head = shown[..<cut]
            let at = head.lastIndex(where: { ".!?…".contains($0) }).map { shown.index(after: $0) } ?? head.lastIndex(of: " ") ?? cut
            anchor += shown.distance(from: shown.startIndex, to: at)
            shown = String(text.dropFirst(anchor)).trimmingCharacters(in: .whitespaces)
            oldText = ""          // a jump: shown at once, no fade
            setPlain(anchor > 0 ? "… " + shown : shown)
            if was != shown.isEmpty { place() } else { placeWave() }
            return
        }
        fadeIn(anchor > 0 ? "… " + shown.trimmingCharacters(in: .whitespaces) : shown)
        if was != shown.isEmpty { place() } else { placeWave() }
    }

    private var anchor = 0
    private func setPlain(_ t: String) {
        styledDraft = true; settledLength = t.count
        oldText = t; prevWords = t.split(separator: " ", omittingEmptySubsequences: false)   // the next draft compares to this
        renderDraft()
    }

    /// A quiet word in the notch row's right side during a take ("no mic signal"); nil clears it.
    func note(_ text: String?) {
        guard panel?.isVisible == true, !box.long else { return }
        status.textColor = PK.faint
        setState(text == nil ? "Listening" : "Quiet", glyphOnly: true)
        status.stringValue = text == nil ? "" : "no mic signal"
    }

    static let insertedNote = "      Inserted · still listening"   // the room at the start holds the drawn pixel tick
    /// The take ended and its last words are being read. A strip that only said "Inserted" closes to the slim bar,
    /// so it never reads "Processing" over "Inserted" (2026-10-30).
    func reading() {
        box.reading = true; box.done = false; setState("Reading"); box.hearing = true; status.stringValue = ""; setControls([])
        if words.stringValue == Pill.insertedNote { words.stringValue = ""; stayOpen = false; box.tick = false; place() }
        box.needsDisplay = true
    }

    // Stability is a reading aid, not confidence. New words are readable immediately.
    private var oldText = "", prevWords: [Substring] = []
    private func fadeIn(_ text: String) {
        let next = text.split(separator: " ", omittingEmptySubsequences: false)
        var agree = 0
        while agree < min(next.count, prevWords.count), next[agree] == prevWords[agree] { agree += 1 }
        if agree == next.count { agree = max(0, agree - 1) }
        prevWords = next; oldText = text
        settledLength = min(text.count, next.prefix(agree).reduce(0) { $0 + $1.count + 1 })
        styledDraft = true; renderDraft()
    }

    private func renderDraft() {
        let split = oldText.index(oldText.startIndex, offsetBy: settledLength)
        let font = words.font ?? Pill.font
        let value = NSMutableAttributedString(string: String(oldText[..<split]), attributes: [.font: font, .foregroundColor: PK.muted])
        value.append(NSAttributedString(string: String(oldText[split...]), attributes: [.font: font, .foregroundColor: PK.faint]))
        words.attributedStringValue = value
    }

    /// The take landed: the island closes back into the notch with a short check mark.
    func landed() {
        guard panel?.isVisible == true || previewing else { return }
        hideToken += 1; let mine = hideToken
        setControls([]); announce("Inserted")
        words.stringValue = ""; oldText = ""; stayOpen = false; box.long = false; box.reading = false
        styledDraft = false; setState("Inserted"); status.stringValue = ""; box.reading = false; box.done = true; box.countdown = nil
        box.levels = nil; box.waveRect = nil; box.tick = false
        if !previewing { box.drawIn() }
        place()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard mine == self.hideToken else { return }
            self.status.textColor = PK.faint
            self.close()
        }
    }

    /// Long recordings keep a named recording state, duration and a fixed four-line outline.
    /// `warning`: a side that is not being heard (`CallHealth`), shown in place of the second row while it lasts, so a
    /// silent microphone or a missing other side shows during the call, not after it (2026-11-10).
    private var warned: String?
    func recording(call: Bool, seconds: Int, title: String, outline: [String], event: String = "", shots: Int = 0, warning: String? = nil) {
        hideToken += 1
        if panel == nil { panel = make() }
        let first = !box.long
        if first {
            box.levels = (0, call ? 0 : nil); meSeen = false; themSeen = false; pin()
            box.waveRect = nil; box.tick = false
            // Stop stays in reach for the whole take (2026-11-01, Codex: the hint went after 20 s, just when it was needed);
            // a click arms it, a second within 3 s stops, so a stray click on the strip never ends a call
            setControls([StripButton("Stop & save", key: "⇧ right ⌥", style: .stop, confirm: "Click again to stop") { Talk.shared.stopRecording("the strip") }])
            announce(call ? "Recording call" : "Recording note")
        }
        styledDraft = false; box.long = true; box.reading = false; box.done = false; box.countdown = nil; setState("Recording", glyphOnly: true); words.textColor = PK.muted
        // the time on the right (and the screenshots taken, small); the kind shows in the levels: a call has "them"
        status.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60) + (shots > 0 ? " · ▣\(shots)" : "")
        let name = !event.isEmpty ? event : !title.isEmpty ? title : (call ? "Recording call" : "Recording note")
        // two lines (1 November 2026, Andrii: "cleaner recording state"): the meeting or the outline's title, bright;
        // then the outline's first point, or what is recorded until there is one
        let point = warning.map { "⚠ " + $0 } ?? outline.first.map { $0.hasPrefix("→") ? $0 : "• " + $0 } ?? (call ? "Both sides, on this Mac" : "Your microphone, on this Mac")
        if warning != warned { warned = warning; if let warning { announce(warning) } }
        let body = [name, point].map(clip)
        setBody(body)
        let changed = lines != CGFloat(body.count) || first
        lines = CGFloat(body.count); words.maximumNumberOfLines = body.count
        if changed || !(panel?.isVisible ?? false) { place() }
        present()
    }

    /// An offer that waits for an answer (a call started: record it?), shown for `seconds`. `kind` names it on the left,
    /// `side` on the right (the app); up to three one-line rows (the question, who or why, what is recorded), then the
    /// keys as buttons that never get cut (2026-11-01, Codex notch review; Andrii: "not sure how to dismiss it"). A thin
    /// line along the bottom runs out with the time left (2026-10-30, Andrii's plan).
    func offer(_ rows: [String], kind: String, side: String = "", controls list: [StripButton], seconds: Double) {
        if panel == nil { panel = make() }
        pin()
        styledDraft = false; box.long = false; box.levels = nil; box.waveRect = nil; box.tick = false; box.reading = true; box.done = false; setState(kind); status.stringValue = side; words.textColor = PK.muted
        let body = rows.prefix(3).map(clip)
        words.maximumNumberOfLines = body.count; setBody(body)
        lines = CGFloat(body.count)
        setControls(list)
        place(); present()
        startCountdown(seconds)
        hide(after: seconds)
        let said: [String] = [kind] + Array(rows.prefix(3)) + list.map { $0.spoken }
        announce(said.joined(separator: ". "))
    }

    /// One row of the offer on screen changed (who the call is likely with, from /prep): same size, same time left.
    func offerRow(_ i: Int, _ text: String) {
        var rows = words.stringValue.components(separatedBy: "\n")
        guard panel?.isVisible == true, i < rows.count, !controls.isEmpty else { return }
        rows[i] = clip(text); setBody(rows)
    }

    /// Rows of an offer or a recording: the first one bright (the question, the meeting), the rest muted.
    private func setBody(_ rows: [String]) {
        let t = NSMutableAttributedString()
        for (i, r) in rows.enumerated() {
            let f = words.font ?? Pill.font
            if i > 0, r.hasPrefix("⚠ ") {   // a side not heard: the mark in the warning colour, the words as they are
                t.append(NSAttributedString(string: "\n⚠ ", attributes: [.font: f, .foregroundColor: PK.warn]))
                t.append(NSAttributedString(string: String(r.dropFirst(2)), attributes: [.font: f, .foregroundColor: PK.ink]))
                continue
            }
            t.append(NSAttributedString(string: (i > 0 ? "\n" : "") + r, attributes: [.font: f, .foregroundColor: i == 0 ? PK.ink : PK.muted]))
        }
        words.attributedStringValue = t
    }

    private var countdownTimer: Timer?
    private func startCountdown(_ seconds: Double) {
        countdownTimer?.invalidate()
        box.countdown = (Date(), seconds)
        let step = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.0 : 0.1
        countdownTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] t in
            guard let self, let c = self.box.countdown, Date().timeIntervalSince(c.0) < c.1 else { t.invalidate(); return }
            self.box.needsDisplay = true
        }
    }

    func hide(after: Double = 0) {
        hideToken += 1; let mine = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { if mine == self.hideToken { self.close() } }
    }

    /// A short line in the strip (no microphone, nothing heard…), then it goes.
    /// A longer text to read (a rewritten selection), shown under the notch for `seconds`.
    func show(_ text: String, seconds: Double, lines n: Int = 2) {
        if panel == nil { panel = make() }
        styledDraft = false; words.textColor = PK.muted; box.long = false; box.levels = nil; box.waveRect = nil; box.tick = false; box.done = false; box.countdown = nil; setState("Drafter"); status.stringValue = ""
        pin(); setControls([])
        let k = fit(text, max: n); lines = CGFloat(k)
        words.maximumNumberOfLines = k
        words.stringValue = text.count > 420 ? String(text.prefix(417)) + "…" : text
        place(); box.reading = true
        present()
        hide(after: seconds)
    }

    /// A short receipt. With a `button` (Undo) it stays 5 s, so the button can be reached.
    func flash(_ text: String, button: StripButton? = nil) {
        if panel == nil { panel = make() }
        styledDraft = false; words.textColor = PK.muted; box.long = false; box.levels = nil; box.waveRect = nil; box.tick = false; box.done = false; box.countdown = nil; setState("Drafter"); status.stringValue = ""
        pin(); setControls(button.map { [$0] } ?? [])
        lines = CGFloat(fit(text, max: 2)); words.maximumNumberOfLines = Int(lines); words.stringValue = text
        place(); box.reading = true
        present()
        hide(after: button == nil ? 1.8 : 5)
    }
    // Isolated renderer: no microphone, engine, real text fields, or screen capture.
    func preview(_ folder: String) throws {
        previewing = true
        previewNotch = 200
        // each state as it hangs from a made-up notch (or floats under a made-up menu bar)
        func shot(_ name: String) throws {
            let n = previewNotch ?? 0, bar = n == 0 ? 28 : (box.dotFromTop + 3) * 2
            try UIShots.strip(box, folder + "/\(name).png", notch: n, bar: bar)
        }
        listening()
        precondition(state.stringValue.isEmpty && status.stringValue.isEmpty)
        try shot("strip-idle")
        let sample = "Давай зробимо цей інтерфейс спокійнішим. Чіткий текст, менше зайвого і все на своєму місці."
        draft(sample); draft(sample + " Ще кілька слів.")
        let height = box.frame.height
        try shot("strip-listening")
        for i in 0..<40 { levelAt = .distantPast; heldMe = 0; level(Float(0.004 + 0.18 * abs(sin(Double(i) * 0.7) * sin(Double(i) * 0.23)))) }
        precondition(box.waveRect != nil && box.wave.count == 40, "A short take shows the waveform behind the newest word")
        try shot("strip-level")
        // speed: opening the strip, and one live words update with its waveform place (both on the main thread)
        var t0 = Date(); for _ in 0..<50 { listening() }; let open = Date().timeIntervalSince(t0) / 50 * 1000
        draft(sample); t0 = Date()
        for i in 0..<200 { draft(sample + " Ще кілька слів" + String(repeating: " і ще", count: i % 7)) }
        print(String(format: "strip: open %.2f ms, words update %.3f ms", open, Date().timeIntervalSince(t0) / 200 * 1000))
        listening(); draft(sample); draft(sample + " Ще кілька слів.")
        for i in 0..<40 { levelAt = .distantPast; heldMe = 0; level(Float(0.004 + 0.18 * abs(sin(Double(i) * 0.7) * sin(Double(i) * 0.23)))) }
        draft("")
        precondition(box.frame.height == height, "Inserting a piece must not collapse the strip")
        try shot("strip-inserted")
        reading()
        precondition(words.stringValue != Pill.insertedNote && state.stringValue == "Reading", "Never Reading over Inserted")
        try shot("strip-reading")
        recording(call: true, seconds: 83, title: "Voice panel design", outline: ["Agree on the voice panel design and the way it opens under the notch on every screen", "Keep the familiar shortcuts", "→ Check both appearances"],
                  event: "Design review: voice strip", shots: 3)
        box.levels = (0.62, 0.3)
        precondition(controls.count == 1 && controls[0].label == "Stop & save", "Stop stays in reach while recording")
        precondition(words.stringValue.components(separatedBy: "\n").count == 2 && box.bounds.contains(controls[0].frame), "Recording: a title line and one point")
        try shot("strip-recording")
        recording(call: true, seconds: 95, title: "Voice panel design", outline: [], event: "Design review: voice strip", shots: 3,
                  warning: "Not hearing the other side yet")
        box.levels = (0.5, 0)
        try shot("strip-warning")
        warned = nil
        Offer.show(CallWatch.ask(name: "Zoom", title: "Design review: voice strip with the whole product and design team", people: ["Mila Synthetic", "Sava Synthetic"]),
                   kind: "Call", side: "Zoom", accept: "Record", seconds: 30, app: "us.zoom.xos") {}
        box.countdown = (Date().addingTimeInterval(-10), 30)
        precondition(controls.map(\.label) == ["Record", "Dismiss", "Turn off offers in Zoom"], "The offer's keys are buttons")
        precondition(controls.allSatisfy { box.bounds.contains($0.frame) }, "Keys never cut")
        try shot("strip-offer")
        Offer.dismiss("preview")
        flash("Offers off in Slack", button: StripButton("Undo", key: "", style: .primary) {})
        try shot("strip-undo")
        landed()
        precondition(box.done && state.stringValue == "Inserted")
        try shot("strip-done")
        flash("Copied · ⌘V to paste")
        precondition(lines == 1, "A one-line receipt takes one line")
        try shot("strip-receipt")
        listening()
        precondition(words.stringValue.isEmpty && !box.reading && !box.long && box.waveRect == nil)
        try shot("strip-reset")
        previewNotch = 0
        listening(); draft("A quieter interface, clear words, and the same familiar keys. This is a sample for a screen without a notch.")
        precondition(box.floating && box.bounds.contains(state.frame) && box.bounds.contains(status.frame))
        try shot("strip-floating")
    }

}

/// A quiet button in the strip's last row: its label, then its key in faint mono ("Record  tab").
final class StripButton: NSButton {
    /// primary: the answer most people pick, filled light; plain: a soft dark capsule; quiet: text only (a setting
    /// change); stop: coral, ends a recording (1 November 2026, Andrii: "nicer buttons").
    enum Style { case primary, plain, quiet, stop }
    let label: String, key: String
    let style: Style
    private let confirm: String?          // the first click arms it ("Click again to stop"), a second within 3 s does it
    private let run: () -> Void
    private var armed = false
    var spoken: String { key.isEmpty ? label : "\(label), \(key)" }
    var hover = false { didSet { if hover != oldValue { render() } } }

    init(_ label: String, key: String, style: Style = .plain, confirm: String? = nil, run: @escaping () -> Void) {
        self.label = label; self.key = key; self.style = style; self.confirm = confirm; self.run = run
        super.init(frame: .zero)
        isBordered = false; setButtonType(.momentaryChange); focusRingType = .none
        target = self; action = #selector(fire)
        wantsLayer = true; layer?.cornerRadius = 6; layer?.cornerCurve = .continuous
        setAccessibilityLabel(spoken)
        // as wide as the longer of its two labels, so arming it never moves the row
        let w = max(title(label, armed: false).size().width, confirm.map { title($0, armed: true).size().width } ?? 0)
        setFrameSize(NSSize(width: ceil(w) + (style == .quiet ? 16 : 26), height: 26))
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var ink: NSColor {
        if armed { return .black }
        switch style {
        case .primary: return .black
        case .plain: return NSColor.white.withAlphaComponent(0.88)
        case .quiet: return hover ? NSColor.white.withAlphaComponent(0.8) : PK.faint
        case .stop: return PK.coral
        }
    }
    private var fill: NSColor? {
        if armed { return PK.coral }
        switch style {
        case .primary: return NSColor.white.withAlphaComponent(hover ? 1 : 0.9)
        case .plain: return NSColor.white.withAlphaComponent(hover ? 0.17 : 0.1)
        case .quiet: return hover ? NSColor.white.withAlphaComponent(0.07) : nil
        case .stop: return PK.coral.withAlphaComponent(hover ? 0.26 : 0.16)
        }
    }
    private func title(_ text: String, armed: Bool) -> NSAttributedString {
        let ink = armed ? NSColor.black : self.ink
        let t = NSMutableAttributedString()
        if style == .stop && !armed { t.append(NSAttributedString(string: "■ ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: ink, .baselineOffset: 1.5])) }
        t.append(NSAttributedString(string: text, attributes: [.font: PK.text(12.5, style == .primary || armed ? .semibold : .medium), .foregroundColor: ink]))
        if !key.isEmpty && !armed { t.append(NSAttributedString(string: "  " + key, attributes: [.font: PK.mono(10), .foregroundColor: ink.withAlphaComponent(0.5)])) }
        return t
    }
    private func render() {
        attributedTitle = title(armed ? confirm ?? label : label, armed: armed)
        layer?.backgroundColor = fill?.cgColor
    }
    @objc func fire() {
        if confirm != nil, !armed {
            armed = true; render()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.armed = false; self?.render() }
            return
        }
        armed = false; render(); run()
    }
}

/// The clear view over the buttons' row: a click or a hover there goes to the button under it.
final class HitView: NSView {
    var buttons: [StripButton] = []
    var origin = NSPoint.zero                     // this view's origin in the strip's coordinates
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func button(_ e: NSEvent) -> StripButton? {
        let p = convert(e.locationInWindow, from: nil), q = NSPoint(x: p.x + origin.x, y: p.y + origin.y)
        return buttons.first { $0.frame.insetBy(dx: -4, dy: -3).contains(q) }
    }
    override func mouseDown(with e: NSEvent) { button(e)?.fire() }
    override func mouseMoved(with e: NSEvent) { let b = button(e); buttons.forEach { $0.hover = $0 === b } }
    override func mouseExited(with e: NSEvent) { buttons.forEach { $0.hover = false } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func draw(_ r: NSRect) { NSColor.black.withAlphaComponent(0.01).setFill(); bounds.fill() }   // clear, yet it takes clicks
}

final class PillView: NSView {
    var dotFromTop: CGFloat = 10
    var floating = false
    var reading = false
    var long = false
    var done = false                              // the text went in: a check instead of the microphone
    var hearing = false                           // the last words are being read: a blue wave instead of the microphone
    var countdown: (Date, Double)?                // an offer's time: a thin line along the bottom that runs out
    var levels: (me: CGFloat, them: CGFloat?)?    // 0 ... 1 each, a long note or call only
    var wave: [CGFloat] = []                       // a short take: his voice, newest last, 0 ... 1
    var waveRect: NSRect?                          // behind the newest word; y counts from the strip's top edge
    var tick = false                               // "Inserted · still listening": the pixel tick before the words
    var tickFromTop: CGFloat = 0
    var levelRowsTop: CGFloat = 0                  // from the bottom: the top of the level rows
    var appearanceChanged: (() -> Void)?

    static let stillWave: [CGFloat] = [0.3, 0.55, 0.4, 0.75, 0.5, 0.35, 0.6, 0.45, 0.3, 0.5, 0.65, 0.4, 0.3, 0.55]
    static let rowH: CGFloat = 14
    var levelRowsH: CGFloat { guard long, let l = levels else { return 0 }; return (l.them == nil ? 1 : 2) * PillView.rowH + 6 }
    var waveDrawRect: NSRect {
        guard let r = waveRect else { return .zero }
        return NSRect(x: r.minX, y: bounds.height - r.minY - r.height, width: r.width, height: r.height)
    }

    /// The waveform: 2 pt bars every 4 pt in blue at 45%, the newest at the right edge, older ones scrolling left.
    private func drawWave() {
        let r = waveDrawRect
        guard r.width > 0, !wave.isEmpty else { return }
        PK.blue.withAlphaComponent(0.45).setFill()
        let n = Int(r.width / 4), mid = r.midY.rounded()
        for i in 0..<min(n, wave.count) {
            let v = wave[wave.count - 1 - i]
            let h = max(2, ((3 + v * (r.height - 3)) / 2).rounded() * 2)      // even heights, so the bar stays centred
            NSRect(x: r.maxX - 2 - CGFloat(i) * 4, y: mid - h / 2, width: 2, height: h).fill()
        }
    }

    /// The level rows of a long note or call: each side's face, then 4 x 6 cells every 6 pt, lit in the side's colour
    /// (me blue, them coral, as in the window) against the key colour. No names, no numbers.
    private var faces: [String: NSImage] = [:]
    private func face(_ name: String) -> NSImage? {
        if let i = faces[name] { return i }
        guard let u = PK.art?.appendingPathComponent("people/\(name).png"), let i = NSImage(contentsOf: u) else { return nil }
        faces[name] = i; return i
    }
    private func drawLevelRows(_ l: (me: CGFloat, them: CGFloat?)) {
        var y = levelRowsTop - 4 - PillView.rowH
        let sides: [(CGFloat, String, NSColor)] = [(l.me, "short", PK.blue)] + (l.them.map { [($0, "bob", PK.coral)] } ?? [])
        for (lvl, name, color) in sides {
            let mid = y + PillView.rowH / 2
            if let img = face(name) {
                NSGraphicsContext.current?.imageInterpolation = .none
                img.draw(in: NSRect(x: 16, y: mid - 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
            let x0: CGFloat = 36, cells = max(1, Int((bounds.width - x0 - 16 + 2) / 6))
            let lit = lvl > 0 ? max(1, Int((lvl * CGFloat(cells)).rounded())) : 0
            for c in 0..<cells {
                (c < lit ? color : PK.key).setFill()
                NSRect(x: x0 + CGFloat(c) * 6, y: (mid - 3).rounded(), width: 4, height: 6).fill()
            }
            y -= PillView.rowH
        }
    }

    static func shape(_ b: NSRect, hanging: Bool) -> NSBezierPath {
        let r: CGFloat = min(12, b.height / 2)
        let p = NSBezierPath(roundedRect: b, xRadius: r, yRadius: r)
        if hanging { p.append(NSBezierPath(rect: NSRect(x: b.minX, y: b.maxY - r, width: b.width, height: r))) }
        return p
    }

    /// The tick: pixel cells in mint on an 8 x 8 grid (a thing that landed is the subject: a sprite, not a glyph).
    static let tickCells: [(Int, Int)] = [(0, 4), (1, 4), (1, 5), (2, 5), (2, 6), (3, 5), (3, 6), (4, 4), (4, 5), (5, 3), (5, 4), (6, 2), (6, 3), (7, 1), (7, 2)]
    static func drawTick(_ r: NSRect, upTo step: CGFloat = 1) {
        PK.mint.setFill()
        let u = r.width / 8
        for (cx, cy) in tickCells where CGFloat(cx) < 8 * step {
            NSRect(x: r.minX + CGFloat(cx) * u, y: r.maxY - CGFloat(cy + 1) * u, width: u, height: u).fill()
        }
    }

    /// The check draws in over three steps when a take lands (none under Reduce Motion).
    private var drawnAt: Date?
    func drawIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { drawnAt = nil; return }
        drawnAt = Date()
        for k in 1...3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(k)) { [weak self] in self?.needsDisplay = true } }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); appearanceChanged?(); needsDisplay = true
    }
    override func draw(_ r: NSRect) {
        // softer than the stepped pixel corner (Tape round): 12 pt at the bottom, square where it hangs from the notch
        let path = PillView.shape(bounds, hanging: !floating)
        NSColor.black.setFill(); path.fill()
        let mid = bounds.height - dotFromTop - 3
        let mark = NSRect(x: 12, y: (mid - 8).rounded(), width: 16, height: 16)   // PixelKit marks: 16 grid, 2 px cells
        if done {
            // the pixel tick in mint, drawn in left to right as the take lands
            let step = drawnAt.map { min(1, CGFloat(Date().timeIntervalSince($0) / 0.135) + 0.34) } ?? 1
            PillView.drawTick(mark, upTo: step)
        } else if reading {
            // reading the last words: the wave in blue; an offer or a note waits: the microphone, not live, in grey
            hearing ? PK.drawMark("waveform", in: mark, tint: PK.blue) : PK.drawMark("mic", in: mark, tint: PK.faint)
        } else {
            // the PixelKit microphone in the live colour; no glow
            PK.drawMark("mic", in: mark, tint: PK.coral)
        }
        if let l = levels, long, !done, !reading { drawLevelRows(l) }
        if !long, !done, !reading, waveRect != nil { drawWave() }
        if tick, !done { PillView.drawTick(NSRect(x: 18, y: bounds.height - tickFromTop - 16, width: 16, height: 16)) }
        if let (from, secs) = countdown {
            let left = max(0, 1 - Date().timeIntervalSince(from) / secs)
            PK.faint.withAlphaComponent(0.6).setFill()
            NSBezierPath(rect: NSRect(x: 16, y: 3, width: ((bounds.width - 32) * left).rounded(), height: 1.5)).fill()
        }
    }
}
