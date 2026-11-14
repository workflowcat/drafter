// Fact chips (1 November 2026; Superhuman and Gmail answer scheduling questions from the calendar). While he types a
// reply under a question on screen ("коли дзвінок?", "what's your email?", "when are you free?"), a pause of 0.7 s
// asks engine `/facts` (engine/facts.py: his calendar for 14 days, free half hours, saved texts, through Claude; an
// answer is kept only when its times, links and emails are in his data). The answer shows as a blue chip
// "Mon 02 Nov 11:30 · call with Ira"; Tab types it at the caret. Not in AI apps; once per question and line.
import AppKit
import Carbon

enum Facts {
    static let delay = 0.7
    static var timer: Timer?
    static var asked = Set<String>()      // question + line already asked about, so a pause asks Claude once
    static let question = try! NSRegularExpression(pattern: #"(?i)\?|\b(коли|о котрій|котра|скільки|лінк|посиланн|пошт|імейл|мейл|номер|зручно|вільн|when|what time|link|email|e-mail|phone|number|available|free|calendar|календар|дзвін|зустріч|call|meet)"#)

    static func schedule(_ s: Spot, context ctx: String, seq mine: Int) {
        timer?.invalidate()
        let st = Drafter.shared.settings, id = s.app.bundleIdentifier ?? ""
        guard st.claudeTyping, st.facts, !IsSecureEventInputEnabled(), !Keys.aiApps.contains(id),
              Keys.aiTitle.firstMatch(in: s.title, range: NSRange(s.title.startIndex..., in: s.title)) == nil else { return }
        let tail = String(ctx.suffix(400))
        guard !tail.isEmpty, question.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil else { return }
        let line = s.before.components(separatedBy: "\n").last ?? ""
        guard line.count <= 120 else { return }
        let key = String(ctx.suffix(600)) + "\u{1}" + line
        guard !asked.contains(key) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            let k = Keys.shared, g = Ghost.shared
            guard mine == k.seq, Talk.shared.state == .idle, g.action == nil, !g.visible || k.stat?.src == "claude" else { return }
            asked.insert(key)
            if asked.count > 200 { asked.removeAll() }
            let t0 = Date()
            Engine.shared.post("/facts", ["context": String(ctx.suffix(3000)), "before": String(s.before.suffix(1000)), "app": s.app.localizedName ?? ""], timeout: 12) { j in
                let insert = j?["insert"] as? String ?? "", label = j?["label"] as? String ?? ""
                log("facts \(id) \(Int(Date().timeIntervalSince(t0) * 1000))ms engine \(j?["ms"] as? Int ?? 0)ms " + (insert.isEmpty ? "none" : "answer") + (j?["cached"] as? Bool == true ? " cached" : ""))
                guard !insert.isEmpty, mine == k.seq, Ghost.shared.action == nil,
                      let now = Focus.spot(skip: Drafter.shared.settings.skip).0, let r = now.rect,
                      CFEqual(now.el, s.el), now.app.processIdentifier == s.app.processIdentifier, now.before == s.before else { return }
                let b = now.before.replacingOccurrences(of: "\u{A0}", with: " ")
                let new = (b.isEmpty || b.last == " " || b.last == "\n" || insert.first == " " ? "" : " ") + insert
                k.endStat(); k.spot = now
                Ghost.shared.unsure = 0
                Ghost.shared.show("", action: ["id": "fact", "chip": "⇥ " + label, "run": ["kind": "expand", "old": "", "new": new, "key": "fact"]], at: r)
                if debugLog { log("facts chip «\(label)» → «\(insert)»") }
            }
        }
    }

    static func cancel() { timer?.invalidate() }
}
