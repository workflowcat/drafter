import Foundation

// swiftc -parse-as-library app/GhostRules.swift tests/ghost_rules.swift -o app/build/ghost-rules-test && app/build/ghost-rules-test
// Argon review 2026-11-14, findings 9-12: when a streamed ghost's later lines, a retried part or a queued Tab may
// still draw or insert. Made-up words only.
@main
struct GhostRulesChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        typealias R = GhostRules
        // 9: the final line after a drawn part
        check(R.next(raw: "hello world,", stillThis: true, text: "hello world, again", hasAction: false, final: true) == .extend(" again"), "a longer final grows the part")
        check(R.next(raw: "hello world,", stillThis: true, text: "hello world,", hasAction: false, final: true) == .keep, "the same final keeps it")
        check(R.next(raw: "hello world,", stillThis: true, text: "", hasAction: false, final: true) == .drop, "an empty final takes the part away")
        check(R.next(raw: "hello world,", stillThis: true, text: "hello", hasAction: false, final: true) == .redraw, "a shorter final redraws")
        check(R.next(raw: "hello world,", stillThis: true, text: "help", hasAction: false, final: true) == .redraw, "another final (the finisher) redraws")
        check(R.next(raw: "hello world,", stillThis: false, text: "", hasAction: false, final: true) == .keep, "a ghost already gone or typed over is left alone")
        check(R.next(raw: "hello", stillThis: true, text: "hel", hasAction: false, final: false) == .keep, "a non-final line never takes words away")
        // 10: a part's retry after its final
        check(R.lateLine(final: false, mine: 10, finished: 10), "a part after its own final is late")
        check(!R.lateLine(final: false, mine: 11, finished: 10), "a newer request's part is not")
        check(!R.lateLine(final: true, mine: 10, finished: 10), "a final (and its retry) still goes on")
        // 11: a newer key the field has not taken yet
        check(R.fieldBehind(revAsked: 5, revNow: 6, asked: "hello ", now: "hello "), "newer key, field unchanged: behind")
        check(!R.fieldBehind(revAsked: 5, revNow: 6, asked: "hello ", now: "hello w"), "he typed its first letters: drawn as before")
        check(!R.fieldBehind(revAsked: 6, revNow: 6, asked: "hello ", now: "hello "), "no newer key: drawn")
        check(R.fieldBehind(revAsked: 5, revNow: 6, asked: "a\u{A0}b", now: "a b"), "no-break space counts as a space")
        // 12: a queued Tab
        check(R.tabStillValid(visible: true, shown: "there friend", isDraft: false, given: "there "), "the word still shows")
        check(!R.tabStillValid(visible: false, shown: "", isDraft: false, given: "there "), "the ghost went before the Tab ran")
        check(!R.tabStillValid(visible: true, shown: "friend", isDraft: false, given: "there "), "a second fast Tab with the same word")
        check(R.tabStillValid(visible: true, shown: "a whole message", isDraft: true, given: "a whole message"), "a next-message card")
        // 14: Tab on a folded next-message card
        check(R.draftTab(expanded: false, cut: true) == .open, "folded with hidden lines: the first Tab opens it")
        check(R.draftTab(expanded: true, cut: false) == .insert, "opened: the next Tab puts it in")
        check(R.draftTab(expanded: false, cut: false) == .insert, "all of it in two lines: Tab puts it in at once")
        // round five: which keys are asked for at once (Keys.predict)
        check(R.predictable(readRev: 9, keyRev: 10, age: 0.2), "a read at the key before: at once")
        check(R.predictable(readRev: 9, keyRev: 10, age: 12), "the first key after a pause of 12 s: at once (was 3 s)")
        check(!R.predictable(readRev: 9, keyRev: 10, age: 25), "a read older than 20 s: the slow way")
        check(!R.predictable(readRev: 8, keyRev: 10, age: 0.1), "a key came between the read and this one: the slow way")
        check(!R.predictable(readRev: 10, keyRev: 10, age: 0.1), "no key since the read: nothing to predict")
        check(!R.predictable(readRev: 9, keyRev: 10, age: -1), "a clock step back: the slow way")
        // round five: the debounced ask after a predicted one
        check(R.askedAtKey(before: "see you", rev: 4, pending: true, now: "see you", keyRev: 4), "still on its way: not asked again")
        check(R.askedAtKey(before: "see you", rev: 4, pending: false, now: "see you", keyRev: 4), "already came for this key: not asked again")
        check(!R.askedAtKey(before: "see you", rev: 3, pending: false, now: "see you", keyRev: 4), "came for an older key: asked")
        check(!R.askedAtKey(before: "see yuo", rev: 4, pending: false, now: "see you", keyRev: 4), "the field holds other text (the guess was wrong): asked")
        check(R.askedAtKey(before: "see\u{A0}you", rev: 4, pending: false, now: "see you", keyRev: 4), "no-break space counts as a space")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("ghost rules: all passed")
    }
}
