// Pure rules for when a ghost answer may still be drawn or taken (2026-11-14, bugs round on the Argon review: a ghost on
// screen that Tab would not insert as drawn, a part drawn after a newer key or after an empty final). Keys.answer and
// Keys.accept ask these; tests/ghost_rules.swift checks them. No AppKit.
import Foundation

enum GhostRules {
    /// What a later line of a streamed answer does to the part of it already on screen.
    enum Next: Equatable { case extend(String), keep, redraw, drop }

    /// `raw`: the part drawn; `stillThis`: the ghost on screen is still (what is left of) that part; `text`: the new line.
    /// A final that does not grow the part replaces it (shorter, or another text: the finisher) or takes it away
    /// (empty) - before 14 November the part stayed on screen (Argon 9).
    static func next(raw: String, stillThis: Bool, text: String, hasAction: Bool, final: Bool) -> Next {
        guard stillThis, !hasAction else { return .keep }
        if text.hasPrefix(raw), text.count > raw.count { return .extend(String(text.dropFirst(raw.count))) }
        if text == raw || !final { return .keep }
        return text.isEmpty ? .drop : .redraw
    }

    /// A part (or its retry) whose answer already ended is never drawn (Argon 10: a part retried 15 ms later came
    /// after an empty final and showed).
    static func lateLine(final: Bool, mine: Int, finished: Int) -> Bool { !final && mine <= finished }

    /// A newer key came since the ask, but the field still reads as it was asked: the app has not put that key in
    /// yet, so the answer would be drawn at the old caret (Argon 11). The ask for the newer key follows.
    static func fieldBehind(revAsked: Int, revNow: Int, asked: String, now: String) -> Bool {
        revNow != revAsked && norm(now) == norm(asked)
    }

    /// Tab's word, read when the key came, is still what the ghost shows when the main queue gets to it: the ghost
    /// was not hidden meanwhile and a second fast Tab does not put the same word in twice (Argon 12).
    static func tabStillValid(visible: Bool, shown: String, isDraft: Bool, given: String) -> Bool {
        visible && !shown.isEmpty && !given.isEmpty && (isDraft || shown.hasPrefix(given))
    }

    /// Tab on a next-message card (2026-11-14, Argon 14). Folded with lines hidden behind the fold (`cut`): the first
    /// Tab opens it and puts nothing in, so he never sends lines he did not see; open, or all of it shows: Tab puts it in.
    enum DraftTab: Equatable { case open, insert }
    static func draftTab(expanded: Bool, cut: Bool) -> DraftTab { !expanded && cut ? .open : .insert }

    /// Round five (2026-11-14): a key may be asked for at once (Keys.predict) when the last field read was made at the
    /// key just before it. Live 7-14 Nov: 41% of ghosts came the slow way (35 ms wait, a field read: 121 ms key to grey
    /// text against 88), because the read was older than 3 s (the first key after a pause) or missing after letters
    /// typed into the ghost or after a Tab. The answer is drawn only once the field holds the asked text, so an old
    /// read costs at most a wasted ask; 20 s keeps a field left for long out.
    static let predictAge = 20.0
    static func predictable(readRev: Int, keyRev: Int, age: Double) -> Bool { readRev == keyRev - 1 && age >= 0 && age < predictAge }

    /// The debounced ask after a key need not go out: the same text was asked at the key itself (Keys.predict), for
    /// this very key, and that answer is on its way or already came (round five: asking again drew the same ghost a
    /// second time and stopped the work the engine had started in the gap).
    static func askedAtKey(before: String, rev: Int, pending: Bool, now: String, keyRev: Int) -> Bool {
        (pending || rev == keyRev) && norm(before) == norm(now)
    }

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }
}
