// Small keys (keys round, 14 November 2026), pure: no AppKit, no files. Backspace takes back the last Tab, Esc twice
// pauses ghosts in one field, which voice take ⌃⌥R puts in again, and which copy ⌘⇧V steps to when pressed again
// right after a switcher paste (the key itself is read by QuickKeys.route in QuickRules.swift). Keys.swift and
// Quick.swift ask these. Tested by tests/key_rules.swift.
import Foundation

/// What one Tab put in, so the very next Backspace can take it out and show the grey text again.
struct TabUndo: Equatable {
    let piece: String     // what Tab (or ⇧Tab) put in the field
    let ghost: String     // the grey text to show again: the piece and what stayed grey after it
    let rev: Int          // Keys.editRevision at the Tab key (a ⇧ release does not count, any other key does)
    let at: Double        // seconds since 1970
}

/// Esc twice in one field pauses ghosts there for a while; the same again resumes them.
struct EscPause {
    static let window = 0.4          // seconds between the two Esc presses
    static let minutes = 10.0
    enum Result: Equatable { case none, paused, resumed }

    private(set) var first: (at: Double, rev: Int, key: String, armed: Bool)?
    private(set) var until: [String: Double] = [:]

    /// One Esc (no modifiers) in field `key`. `rev`: Keys.editRevision at this Esc (another key between the two Esc
    /// presses breaks the pair). `ghostRecent`: a ghost is up, or was shown a moment ago. A pair pauses only when a
    /// ghost was there at either press; in a paused field any pair resumes.
    mutating func esc(key: String, now: Double, rev: Int, ghostRecent: Bool) -> Result {
        if let f = first, f.key == key, rev == f.rev + 1, now - f.at >= 0, now - f.at <= Self.window,
           f.armed || ghostRecent || paused(key, now: now) {
            first = nil
            if paused(key, now: now) { until[key] = nil; return .resumed }
            until = until.filter { $0.value > now }
            until[key] = now + Self.minutes * 60
            return .paused
        }
        first = (now, rev, key, ghostRecent)
        return .none
    }

    func paused(_ key: String, now: Double) -> Bool { (until[key] ?? 0) > now }
}

enum KeyRules {
    // MARK: 1. Backspace takes back the last Tab

    /// How long after the Tab its Backspace still takes it back (the next key decides anyway).
    static let tabBackSeconds = 10.0

    /// `given`: the word (or whole ghost) Tab read; `piece`: what really went in (letters typed meanwhile taken off);
    /// `full`: the grey text when Tab came. nil: nothing to take back.
    static func tabUndo(piece: String, given: String, full: String, rev: Int, at: Double) -> TabUndo? {
        guard !piece.isEmpty, !given.isEmpty, full.hasPrefix(given) else { return nil }
        return TabUndo(piece: piece, ghost: piece + String(full.dropFirst(given.count)), rev: rev, at: at)
    }

    /// This Backspace is the very next key after the Tab, soon enough, and the switch is on.
    static func tabBack(_ u: TabUndo?, rev: Int, now: Double, on: Bool) -> Bool {
        guard on, let u else { return false }
        return rev == u.rev + 1 && now >= u.at && now - u.at < tabBackSeconds
    }

    /// The field still ends with what Tab put in (a no-break space reads as a space; a field may drop a trailing one).
    static func stillEnds(before: String, piece: String) -> Bool {
        let b = norm(before), p = norm(piece)
        guard !p.isEmpty else { return false }
        return b.hasSuffix(p)
    }

    // MARK: 2. Esc twice

    /// One field: the app and its focused element's hash.
    static func fieldKey(app: String, element: UInt) -> String { app + "#" + String(element) }

    /// A ghost counts as "just shown" for this long after it went.
    static let ghostRecent = 1.5

    // MARK: 3. The last voice take again

    /// The newest take worth putting in again: rows newest first as (text, outcome); empty, failed, spoken-rule rows
    /// ("✎ …") and test rows are skipped.
    static func lastTake(_ rows: [(text: String, outcome: String)]) -> String? {
        for r in rows {
            let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || !r.outcome.isEmpty || t.hasPrefix("✎") || t.contains("⟦drafter-test⟧") { continue }
            return t
        }
        return nil
    }

    // MARK: 4. Swap on the switcher

    /// How long after a switcher paste ⌘⇧V swaps it.
    static let swapSeconds = 2.0

    /// The next older copy after row `i` when it can go in as text (a picture or a file: nil, the switcher opens).
    static func swapNext(_ isText: [Bool], after i: Int) -> Int? {
        let j = i + 1
        guard i >= 0, j < isText.count, isText[j] else { return nil }
        return j
    }

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }
}
