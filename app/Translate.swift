// Translate as you type (1 November 2026; Gboard's translate bar). Two ways in:
// - he writes Ukrainian in a chat whose conversation is in English (or English in a Ukrainian one): after a 1 s rest
//   the message goes to engine `/translate` (Claude, engine/translate.py) and comes back as a chip "⇥ EN · hi, can we…";
// - he ends the line with ;en or ;uk (;ua): that line, at once, in any app, AI apps too.
// Tab selects what he typed (shift + arrows, so native and Chromium fields work alike) and types the translation over
// it; Backspace as the very next key puts his own text back. Once per text; not in AI apps unless he asks with ;en.
import AppKit
import Carbon

enum Translate {
    static var timer: Timer?
    static var asked = Set<String>()
    struct Pending { let el: AXUIElement; let pid: pid_t; let before: String; let body: String; let new: String; let target: String }
    static var pending: Pending?
    struct Done { let el: AXUIElement; let old: String; let new: String; let revision: Int; let at: Date }
    static var last: Done?

    static func letters(_ t: String) -> (lat: Int, cyr: Int) {
        var lat = 0, cyr = 0
        for u in t.unicodeScalars {
            if (65...90).contains(u.value) || (97...122).contains(u.value) { lat += 1 }
            else if (0x410...0x44F).contains(u.value) || [0x404, 0x406, 0x407, 0x454, 0x456, 0x457, 0x490, 0x491].contains(u.value) { cyr += 1 }
        }
        return (lat, cyr)
    }
    /// "uk", "en" or nil: which letters most of the text is in (12+ letters; Russian is never "uk").
    static func lang(_ t: String, share: Double = 0.8) -> String? {
        let (lat, cyr) = letters(t), n = lat + cyr
        guard n >= 12 else { return nil }
        if Double(cyr) / Double(n) >= share { return t.unicodeScalars.filter { Autocorrect.russian.contains($0) }.count > 2 ? nil : "uk" }
        if Double(lat) / Double(n) >= share { return "en" }
        return nil
    }
    /// ";en", ";uk" or ";ua" at the end of the line: (target, its length).
    static func trigger(_ before: String) -> (target: String, cut: Int)? {
        let b = before.replacingOccurrences(of: "\u{A0}", with: " ").lowercased()
        for (k, t) in [(";en", "en"), (";uk", "uk"), (";ua", "uk")] where b.hasSuffix(k) {
            let pre = b.dropLast(k.count)
            if pre.isEmpty || pre.last == " " || pre.last == "\n" { return (t, k.count) }
        }
        return nil
    }

    /// From Keys.ask. true when a translation is on its way (the proofread then stays quiet).
    @discardableResult
    static func schedule(_ s: Spot, context ctx: String, seq mine: Int) -> Bool {
        timer?.invalidate()
        let st = Drafter.shared.settings, id = s.app.bundleIdentifier ?? ""
        guard st.claudeTyping, st.translate, !IsSecureEventInputEnabled() else { return false }
        // ;en at the end: that line only (2026-11-01, TextEdit: the whole paragraph went, other lines too). Without it:
        // the whole field, and only a small one (a message box, not a document)
        let explicit = trigger(s.before) != nil
        guard explicit || (s.before as NSString).length <= 600 else { return false }
        let span = explicit ? (s.before.components(separatedBy: "\n").last ?? "") : Proof.span(s.before)
        let lead = span.prefix(while: { $0.isWhitespace }).count
        let body = String(span.dropFirst(lead))                     // what gets replaced: the message without its leading blanks
        var text = body, target: String, asked1 = false
        if let t = trigger(body) {
            target = t.target; asked1 = true
            text = String(body.dropLast(t.cut)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, lang(text, share: 0.6) != target else { return false }
        } else {
            guard !Keys.aiApps.contains(id), Keys.aiTitle.firstMatch(in: s.title, range: NSRange(s.title.startIndex..., in: s.title)) == nil,
                  text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count >= 3,
                  let his = lang(text), let conv = lang(String(ctx.suffix(800)), share: 0.85), his != conv else { return false }
            target = conv
        }
        guard (text as NSString).length <= 600 else { return false }
        let key = target + "\u{1}" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.contains(key) else { return false }
        timer = Timer.scheduledTimer(withTimeInterval: asked1 ? 0.25 : 1.0, repeats: false) { _ in
            let k = Keys.shared, g = Ghost.shared
            guard mine == k.seq, Talk.shared.state == .idle, g.action == nil, !g.visible || k.stat?.src == "claude" else { return }
            asked.insert(key)
            if asked.count > 200 { asked.removeAll() }
            let t0 = Date()
            Engine.shared.post("/translate", ["text": text, "target": target, "context": String(ctx.suffix(1500)), "app": s.app.localizedName ?? ""], timeout: 14) { j in
                let out = (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                log("translate \(id) \(target) \(Int(Date().timeIntervalSince(t0) * 1000))ms engine \(j?["ms"] as? Int ?? 0)ms " + (out.isEmpty ? "none" : "\(out.count) chars") + (j?["cached"] as? Bool == true ? " cached" : ""))
                guard !out.isEmpty, mine == k.seq, Ghost.shared.action == nil,
                      let now = Focus.spot(skip: Drafter.shared.settings.skip).0, let r = now.rect,
                      CFEqual(now.el, s.el), now.app.processIdentifier == s.app.processIdentifier, now.before == s.before else { return }
                // a space he typed after the message stays after the translation (not after ;en)
                let tail = !asked1 && (body.last == " " || body.last == "\u{A0}") ? " " : ""
                pending = Pending(el: now.el, pid: now.app.processIdentifier, before: now.before, body: body, new: out + tail, target: target)
                var label = "⇥ \(target.uppercased()) · " + out.replacingOccurrences(of: "\n", with: " ")
                if label.count > 70 { label = String(label.prefix(68)) + "…" }
                k.endStat(); k.spot = now
                Ghost.shared.unsure = 0
                Ghost.shared.show("", action: ["id": "translate", "chip": label, "run": ["kind": "translate"]], at: r)
            }
        }
        return true
    }

    static func cancel() { timer?.invalidate() }

    /// Tab on the chip: his message, selected from the caret back, typed over with the translation.
    static func apply() {
        guard let p = pending else { return }
        pending = nil
        guard let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, p.el), now.app.processIdentifier == p.pid,
              now.before == p.before else { Ghost.shared.flash("Text has changed"); return }
        Keys.shared.cancel()
        Fields.left(p.body.count, shift: true)
        Focus.typeText(p.new)
        last = Done(el: p.el, old: p.body, new: p.new, revision: Keys.shared.inputRevision, at: Date())
        log("translate applied \(p.target), \(p.body.count) → \(p.new.count) chars")
    }

    /// Backspace as the next key after a translation: his own text comes back.
    static func takeBack() -> Bool {
        guard let d = last, Keys.shared.inputRevision == d.revision + 1, Date().timeIntervalSince(d.at) < 60 else { last = nil; return false }
        last = nil
        DispatchQueue.main.async {
            guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(s.el, d.el),
                  s.before.replacingOccurrences(of: "\u{A0}", with: " ").hasSuffix(d.new.replacingOccurrences(of: "\u{A0}", with: " ")) else { return }
            Fields.left(d.new.count, shift: true)
            Focus.typeText(d.old)
            log("translate taken back")
        }
        return true
    }
}
