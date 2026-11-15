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
        // long round: sentence-length ghosts, rolling ghost, futures, other ideas, the two keys
        check(R.lengthMode("phrase") == "phrase" && R.lengthMode("word") == "word" && R.lengthMode("") == "sentence", "length setting reads, default sentence")
        check(R.sentencePiece("we can go. Then more") == "we can go. ", "⌃Tab: up to the sentence end and its space")
        check(R.sentencePiece("see you soon!\" ok") == "see you soon!\" ", "closing quote stays with the sentence")
        check(R.sentencePiece("version 3.5 is out") == "version 3.5 is out", "a dot inside a number is no sentence end")
        check(R.sentencePiece("no end here") == "no end here", "no sentence end: all of it")
        check(R.sentencePiece("line one\nline two") == "line one", "a line break ends it")
        check(R.wordsLeft("go home ") == 2 && R.wordsLeft("") == 0, "words left")
        check(R.rollWanted(rest: "go home", mode: "sentence", final: true, plain: true, wanted: "a go home", askedFor: nil), "two words left: roll")
        check(!R.rollWanted(rest: "we can go home", mode: "sentence", final: true, plain: true, wanted: "a we can go home", askedFor: nil), "four left: not yet")
        check(!R.rollWanted(rest: "home", mode: "word", final: true, plain: true, wanted: "a home", askedFor: nil), "word mode never rolls")
        check(!R.rollWanted(rest: "home", mode: "sentence", final: false, plain: true, wanted: "a home", askedFor: nil), "a ghost still streaming does not roll")
        check(!R.rollWanted(rest: "home", mode: "sentence", final: true, plain: false, wanted: "a home", askedFor: nil), "a chip or fix does not roll")
        check(!R.rollWanted(rest: "home", mode: "sentence", final: true, plain: true, wanted: "a home", askedFor: "a\u{A0}home"), "asked once per text")
        check(R.rollFits(asked: "a go home", now: "a go home") && !R.rollFits(asked: "a go home", now: "a go hime"), "roll answer only while it still fits")
        check(R.rollUnsure(old: 4, more: 6, moreUnsure: 2) == 10, "after a lighter tail, all added words are lighter")
        check(R.rollUnsure(old: 0, more: 6, moreUnsure: 2) == 2, "after a sure part, the roll brings its own split")
        let fs: [(letter: String, text: String, unsure: String)] = [("b", "ook it", " it"), ("p", "lan", "")]
        check(R.future(base: "see the ", before: "see the ", typed: "b", futures: fs)?.text == "ook it", "his letter matches a prepared future")
        check(R.future(base: "see the ", before: "see the x", typed: "b", futures: fs) == nil, "another base: none")
        check(R.future(base: "see the ", before: "see the ", typed: "z", futures: fs) == nil, "no future for that letter")
        let ideas = R.ideas(shown: "car", futures: fs + [("c", "ar", "")])
        check(ideas.map { $0.text } == ["car", "book it", "plan"], "ideas: shown first, then futures, no repeat of the shown")
        check(ideas[1].unsure == 3, "a future keeps its lighter tail")
        check(R.cycle(index: 0, count: 3) == 1 && R.cycle(index: 2, count: 3) == 0 && R.cycle(index: 0, count: 1) == nil, "cycle wraps; one idea: nothing")
        check(R.longKey(code: 48, control: true, shift: false, option: false, command: false, ghost: true, plain: true) == .sentence, "⌃Tab on a ghost")
        check(R.longKey(code: 48, control: true, shift: true, option: false, command: false, ghost: true, plain: true) == .cycle, "⌃⇧Tab on a ghost")
        check(R.longKey(code: 48, control: true, shift: true, option: false, command: false, ghost: false, plain: true) == .none, "no ghost: the app gets ⌃⇧Tab")
        check(R.longKey(code: 48, control: true, shift: false, option: false, command: false, ghost: true, plain: false) == .none, "a chip: not ours")
        check(R.longKey(code: 48, control: false, shift: true, option: false, command: false, ghost: true, plain: true) == .none, "⇧Tab stays the whole ghost")
        check(R.longKey(code: 48, control: true, shift: false, option: true, command: false, ghost: true, plain: true) == .none, "⌃⌥Tab is not ours")
        // mid-line round (2026-11-15): when a ghost may show with text after the caret on its line
        check(R.lineRest(" the park.\nnext line") == " the park.", "the rest of the line stops at the break")
        check(R.lineRest("") == "", "nothing after the caret")
        check(R.midLineOK(before: "we walked to", rest: " the park."), "a gap before a word: shows")
        check(R.midLineOK(before: "see you at noon", rest: ", thanks"), "before a comma: shows")
        check(R.midLineOK(before: "(call me", rest: ")"), "before a closing bracket: shows")
        check(!R.midLineOK(before: "we wal", rest: "ked home"), "a letter after the caret: inside a word, quiet")
        check(!R.midLineOK(before: "room ", rest: "42 is free"), "a digit after the caret: quiet")
        check(!R.midLineOK(before: "we don", rest: "'t know"), "an apostrophe between letters: inside a word, quiet")
        check(!R.midLineOK(before: "a well", rest: "-known spot"), "a hyphen between letters: inside a word, quiet")
        check(R.midLineOK(before: "she said ", rest: "'hello'"), "a quote after a space: a gap, shows")
        check(!R.midLineOK(before: "abc", rest: "   "), "only spaces after the caret: not mid-line (the plain path)")
        check(!R.midLineOK(before: "abc", rest: ""), "nothing after the caret: not mid-line")
        check(!R.midLineOK(before: "first line\n", rest: " rest"), "nothing typed on the caret's line: quiet")
        check(!R.midLineOK(before: "word", rest: " " + String(repeating: "x", count: R.midRestMax)), "a long rest: quiet")
        check(R.midLineOK(before: "word", rest: " " + String(repeating: "x", count: R.midRestMax - 1)), "a rest at the cap: shows")
        check(R.midAfter(" end of line\nsecond\nthird\nfourth") == " end of line\nsecond\nthird", "after: the line and two more")
        check(R.midAfter(String(repeating: "y", count: 900)).count == R.midAfterMax, "after: capped")
        check(R.midText("the big park", rest: " park.") == "the big", "the ghost never repeats the rest at its end")
        check(R.midText("the big ", rest: " park.") == "the big", "no trailing space before a rest that starts with one")
        check(R.midText("one line\nanother", rest: ", ok") == "one line", "one line only")
        check(R.midText("p", rest: " p") == "p", "a single letter is no overlap")
        check(R.midText("for the help, thanks", rest: ", thanks") == "for the help", "the overlap with the punctuation goes too")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("ghost rules: all passed")
    }
}
