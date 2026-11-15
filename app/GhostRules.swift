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

    // MARK: long round (2026-11-14): sentence-length ghosts, the rolling ghost, futures and other ideas

    /// Setting `ghostLength`: "word" (round five's short ghost), "phrase", "sentence" (default). Anything else reads as
    /// the default.
    static func lengthMode(_ s: String) -> String { ["word", "phrase", "sentence"].contains(s) ? s : "sentence" }

    /// ⌃Tab: the ghost up to the end of its first sentence (. ! ? … with closing quotes and the space after), or all of
    /// it when it has no sentence end. ⇧Tab still takes all of it, which after a roll can run past the sentence.
    static func sentencePiece(_ ghost: String) -> String {
        let chars = Array(ghost)
        var i = 0
        while i < chars.count {
            if ".!?…".contains(chars[i]) {
                var j = i + 1
                while j < chars.count, ".!?…\"'»”)]".contains(chars[j]) { j += 1 }
                // "e.g" or "3.5": a stop with a letter right after it is not a sentence end
                if j < chars.count, !chars[j].isWhitespace { i = j; continue }
                if j < chars.count, chars[j] == " " { j += 1 }
                return String(chars[..<j])
            }
            if chars[i] == "\n" { return String(chars[..<i]) }
            i += 1
        }
        return ghost
    }

    /// Words still grey: what is left of the ghost after Tab or letters typed into it.
    static func wordsLeft(_ rest: String) -> Int { rest.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    /// The rolling ghost: once two words or fewer are left of a final ghost, the words after it are asked for (from the
    /// engine's prepared answer for the whole ghost, so mostly at once) and added at its end, so a sentence keeps
    /// coming while he Tabs. Once per ghost text (`askedFor` is the text the last roll asked for); never in "word"
    /// mode, never for a chip, a fix or a next-message card.
    static func rollWanted(rest: String, mode: String, final: Bool, plain: Bool, wanted: String, askedFor: String?) -> Bool {
        guard lengthMode(mode) != "word", final, plain, !rest.trimmingCharacters(in: .whitespaces).isEmpty, !rest.hasSuffix("\n") else { return false }
        return wordsLeft(rest) <= 2 && norm(wanted) != norm(askedFor ?? "")
    }

    /// The roll's answer goes on only while the field and the ghost still read as when it was asked.
    static func rollFits(asked: String, now: String) -> Bool { norm(asked) == norm(now) }

    /// The lighter tail after a roll: words added after a lighter part stay lighter; after a sure part they bring their
    /// own split.
    static func rollUnsure(old: Int, more: Int, moreUnsure: Int) -> Int { old > 0 ? old + more : min(more, moreUnsure) }

    /// The answer prepared for the letter just typed (engine /futures, fetched once the ghost was final): shown at once,
    /// no request, when the field before that letter is the base the futures were made for.
    static func future(base: String, before: String, typed: String, futures: [(letter: String, text: String, unsure: String)]) -> (text: String, unsure: String)? {
        guard !typed.isEmpty, norm(base) == norm(before) else { return nil }
        return futures.first(where: { $0.letter == typed }).map { ($0.text, $0.unsure) }
    }

    /// Other ideas for the same spot (⌃⇧Tab): the shown ghost first, then each prepared future as its letter and its
    /// words, none twice, none that only repeats the shown one.
    static func ideas(shown: String, futures: [(letter: String, text: String, unsure: String)]) -> [(text: String, unsure: Int)] {
        var out: [(text: String, unsure: Int)] = [(shown, 0)]
        for f in futures {
            let t = f.letter + f.text
            guard !f.text.isEmpty, !out.contains(where: { $0.text == t }), !shown.hasPrefix(t) else { continue }
            out.append((t, t.hasSuffix(f.unsure) ? f.unsure.count : 0))
        }
        return out
    }

    /// The next idea, wrapping back to the first; nil when there is no other idea to show.
    static func cycle(index: Int, count: Int) -> Int? { count > 1 ? (index + 1) % count : nil }

    // MARK: mid-line round (2026-11-15): a ghost with text after the caret on the same line (setting `midLine`)

    /// The rest of the caret's line: what follows the caret up to the next line break.
    static func lineRest(_ after: String) -> String {
        String(after.prefix(while: { $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" }))
    }

    /// A mid-line rest longer than this keeps Drafter quiet: the caret is deep inside a paragraph, not at a gap.
    static let midRestMax = 120

    /// A ghost may show with text after the caret on its line only at a gap between words: the rest starts with a space
    /// or a punctuation mark (never a letter or digit, never an apostrophe or hyphen joining two letters, so never inside
    /// a word), it is at most `midRestMax` characters, and the caret's line has a letter or digit before it.
    /// `before`: the text before the caret; `rest`: the rest of its line (`lineRest`), not blank.
    static func midLineOK(before: String, rest: String) -> Bool {
        guard let first = rest.first, !rest.trimmingCharacters(in: .whitespaces).isEmpty, rest.count <= midRestMax else { return false }
        if first.isLetter || first.isNumber || first == "_" || first.isNewline { return false }
        // "don|'t", "well|-known": a joiner between two letters is inside a word
        if "'’‘-‐".contains(first), before.last?.isLetter == true, rest.dropFirst().first?.isLetter == true { return false }
        let line = before.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? before
        return line.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// The text after the caret sent to the engine mid-line: the rest of the line first, then at most `midLines` more
    /// lines, at most `midAfterMax` characters.
    static let midLines = 2, midAfterMax = 400
    static func midAfter(_ after: String) -> String {
        let lines = after.split(separator: "\n", maxSplits: midLines + 1, omittingEmptySubsequences: false)
        return String(lines.prefix(midLines + 1).joined(separator: "\n").prefix(midAfterMax))
    }

    /// A mid-line ghost as it may be drawn and put in: one line only (cut at a line break), never repeating the start of
    /// the rest at its end (the model wrote past the gap), no trailing space when the rest starts with one. "" = none.
    static func midText(_ ghost: String, rest: String) -> String {
        var g = String(ghost.prefix(while: { $0 != "\n" && $0 != "\r" }))
        let r = Array(rest)
        var k = min(g.count, r.count, 40)
        while k >= 2 {
            if g.hasSuffix(String(r[..<k])) { g = String(g.dropLast(k)); break }
            k -= 1
        }
        if rest.first?.isWhitespace == true { while g.last?.isWhitespace == true { g.removeLast() } }
        return g
    }

    /// The long round's two keys, only while a plain ghost shows (never a chip, a fix or a card): ⌃Tab takes up to the
    /// end of the sentence, ⌃⇧Tab shows the next idea. Without a ghost both go to the app (a browser's tab switch).
    enum LongKey: Equatable { case sentence, cycle, none }
    static func longKey(code: Int, control: Bool, shift: Bool, option: Bool, command: Bool, ghost: Bool, plain: Bool) -> LongKey {
        guard code == 48, control, !option, !command, ghost, plain else { return .none }
        return shift ? .cycle : .sentence
    }
}
