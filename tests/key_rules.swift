import Foundation

// swiftc -parse-as-library app/KeyRules.swift app/QuickRules.swift app/ClipRules.swift tests/key_rules.swift -o app/build/key-rules-test && app/build/key-rules-test
// The keys round (14 November 2026) with made-up lines and event sequences: Backspace takes back the last Tab, Esc
// twice pauses one field, the last voice take again (⌃⌥R), and ⌘⇧V again swapping a switcher paste.
@main
struct KeyRuleChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        tabBack(); escPause(); lastTake(); swapRows(); keySequences()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("key rules: all passed")
    }

    static func tabBack() {
        // Tab took one word of "meeting tomorrow at ten"
        let u = KeyRules.tabUndo(piece: "meeting ", given: "meeting ", full: "meeting tomorrow at ten", rev: 40, at: 100)
        check(u?.ghost == "meeting tomorrow at ten", "the ghost comes back whole: \(String(describing: u?.ghost))")
        check(KeyRules.tabBack(u, rev: 41, now: 100.5, on: true), "the very next key is Backspace: take it back")
        check(!KeyRules.tabBack(u, rev: 42, now: 100.5, on: true), "a key in between: Backspace is normal")
        check(!KeyRules.tabBack(u, rev: 41, now: 100.5, on: false), "switch off")
        check(!KeyRules.tabBack(u, rev: 41, now: 100 + KeyRules.tabBackSeconds + 1, on: true), "too late")
        check(!KeyRules.tabBack(nil, rev: 41, now: 100.5, on: true), "no Tab")
        // ⇧Tab took the whole ghost
        let w = KeyRules.tabUndo(piece: "see you there", given: "see you there", full: "see you there", rev: 7, at: 5)
        check(w?.ghost == "see you there" && KeyRules.tabBack(w, rev: 8, now: 6, on: true), "⇧Tab whole ghost")
        // a space typed meanwhile was taken off the piece: the ghost shown again starts where the caret is then
        let v = KeyRules.tabUndo(piece: "plan ", given: " plan ", full: " plan for friday", rev: 3, at: 1)
        check(v?.ghost == "plan for friday", "letters typed meanwhile stay his: \(String(describing: v?.ghost))")
        check(KeyRules.tabUndo(piece: "", given: "x", full: "x", rev: 1, at: 1) == nil, "nothing went in")
        check(KeyRules.tabUndo(piece: "a", given: "b", full: "c", rev: 1, at: 1) == nil, "ghost moved on")
        check(KeyRules.stillEnds(before: "Let us move the meeting ", piece: "meeting "), "field ends with it")
        check(KeyRules.stillEnds(before: "Let us move the meeting\u{A0}", piece: "meeting "), "no-break space reads as space")
        check(!KeyRules.stillEnds(before: "Let us move the meetings", piece: "meeting "), "field changed")
        check(!KeyRules.stillEnds(before: "abc", piece: ""), "empty piece")
    }

    static func escPause() {
        var p = EscPause()
        let f = "com.example.chat#42", g = "com.example.chat#43"
        check(p.esc(key: f, now: 10, rev: 1, ghostRecent: true) == .none, "one Esc: nothing")
        check(p.esc(key: f, now: 10.3, rev: 2, ghostRecent: false) == .paused, "two within 400 ms after a ghost: paused")
        check(p.paused(f, now: 11) && !p.paused(g, now: 11), "only this field")
        check(p.paused(f, now: 10.3 + 599) && !p.paused(f, now: 10.3 + 601), "for 10 minutes")
        check(p.esc(key: f, now: 20, rev: 3, ghostRecent: false) == .none, "a third Esc after the pair starts a new pair")
        check(p.esc(key: f, now: 20.2, rev: 4, ghostRecent: false) == .resumed && !p.paused(f, now: 21), "the same pair again resumes")
        // no ghost anywhere: a double Esc is the app's
        var q = EscPause()
        _ = q.esc(key: f, now: 1, rev: 1, ghostRecent: false)
        check(q.esc(key: f, now: 1.2, rev: 2, ghostRecent: false) == .none && !q.paused(f, now: 2), "no ghost: no pause")
        // too slow, a key between, another field
        var r = EscPause()
        _ = r.esc(key: f, now: 1, rev: 1, ghostRecent: true)
        check(r.esc(key: f, now: 1.5, rev: 2, ghostRecent: false) == .none, "500 ms apart: not a pair")
        _ = r.esc(key: f, now: 5, rev: 10, ghostRecent: true)
        check(r.esc(key: f, now: 5.1, rev: 12, ghostRecent: false) == .none, "a key between the two")
        _ = r.esc(key: f, now: 8, rev: 20, ghostRecent: true)
        check(r.esc(key: g, now: 8.1, rev: 21, ghostRecent: false) == .none, "another field")
        check(!r.paused(f, now: 9) && !r.paused(g, now: 9), "nothing paused")
        // a ghost shown at the second press is enough (it was hidden by nothing yet)
        var s = EscPause()
        _ = s.esc(key: f, now: 1, rev: 1, ghostRecent: false)
        check(s.esc(key: f, now: 1.1, rev: 2, ghostRecent: true) == .paused, "ghost at the second press")
        check(KeyRules.fieldKey(app: "com.example.chat", element: 42) == f, "field key")
    }

    static func lastTake() {
        check(KeyRules.lastTake([("Call the plumber about the kitchen tap", ""), ("older take", "")]) == "Call the plumber about the kitchen tap", "newest take")
        check(KeyRules.lastTake([("", "timeout"), ("  ", ""), ("✎ make it shorter\n- before: a\n- after: b", ""), ("Buy paper and pens", "")]) == "Buy paper and pens",
              "failed, empty and spoken-rule rows skipped")
        check(KeyRules.lastTake([("half a sentence", "incomplete"), ("⟦drafter-test⟧ hello", "")]) == nil, "only test or failed rows: none")
        check(KeyRules.lastTake([]) == nil, "no takes")
        check(KeyRules.lastTake([("  Send the drawings today \n", "")]) == "Send the drawings today", "trimmed")
    }

    static func swapRows() {
        check(KeyRules.swapNext([true, true, true], after: 0) == 1, "next older")
        check(KeyRules.swapNext([true, true, true], after: 2) == nil, "the oldest: nothing older")
        check(KeyRules.swapNext([true, false, true], after: 0) == nil, "a file or picture next: the switcher opens instead")
        check(KeyRules.swapNext([], after: 0) == nil && KeyRules.swapNext([true], after: -1) == nil, "edges")
    }

    static func keySequences() {
        let V = 9, R = 15, A = 0
        func machine() -> QuickKeys {
            var k = QuickKeys(panelKey: QuickRules.hotkey("⌃⌥V"), switchKey: QuickRules.hotkey("⌘⇧V"))
            k.againKey = QuickRules.hotkey("⌃⌥R")
            return k
        }
        func run(_ k: inout QuickKeys, _ es: [QuickKeyEvent]) -> [QuickKeyAction] { es.flatMap { k.route($0) } }
        func at(_ e: QuickKeyEvent, _ t: Double) -> QuickKeyEvent { var e = e; e.at = t; return e }

        var k = machine()
        check(run(&k, [.down(R, "⌃⌥")]) == [.voiceAgain], "⌃⌥R: the last take again")
        check(run(&k, [.down(R, "⌃⌥", repeat: true)]) == [.swallow], "a held ⌃⌥R does not paste again and again")
        check(run(&k, [.down(R, "⌃"), .down(R, "")]) == [.pass, .pass], "other chords with R are the app's")
        k.againKey = nil
        check(run(&k, [.down(R, "⌃⌥")]) == [.pass], "off: the app gets it")

        // a missed release of the switcher never swallows ⌃⌥R: put first, then the take
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(R, "⌃⌥")]) == [.openSwitch, .put, .voiceAgain], "missed release, then ⌃⌥R")

        // the swap: tap ⌘⇧V and let go (put), the app arms the swap, ⌘⇧V again within 2 s swaps
        k = machine()
        check(run(&k, [at(.down(V, "⌘⇧"), 100), at(.flags(""), 100.2)]) == [.openSwitch, .put], "first paste")
        k.armSwap(until: 100.2 + KeyRules.swapSeconds)
        check(run(&k, [at(.flags("⌘"), 100.8), at(.flags("⌘⇧"), 100.9), at(.down(V, "⌘⇧"), 101)]) == [.pass, .pass, .swap] && !k.switching,
              "⌘⇧V again within 2 s: swap, no switcher held")
        check(run(&k, [at(.flags(""), 101.1)]) == [.pass], "letting go after a swap puts nothing")
        k.armSwap(until: 101 + KeyRules.swapSeconds)
        check(run(&k, [at(.down(V, "⌘⇧"), 102)]) == [.swap], "each press within 2 s steps one older")
        check(run(&k, [at(.down(V, "⌘⇧", repeat: true), 102.1)]) == [.swallow], "a held V after a swap neither swaps nor opens")
        // too late: the switcher opens as usual
        k = machine()
        k.armSwap(until: 50)
        check(run(&k, [at(.down(V, "⌘⇧"), 51), at(.flags(""), 51.2)]) == [.openSwitch, .put], "after 2 s: the switcher")
        // any other key ends the window
        k = machine()
        k.armSwap(until: 50)
        check(run(&k, [at(.down(A, ""), 49), at(.down(V, "⌘⇧"), 49.5)]) == [.pass, .openSwitch], "a key between: the switcher")
        // a missed release after the swap's own press cannot hang: the swap holds nothing
        k = machine()
        k.armSwap(until: 50)
        check(run(&k, [at(.down(V, "⌘⇧"), 49), at(.down(A, ""), 49.2)]) == [.swap, .pass], "a plain letter after a swap goes to the app")
        check(!k.switching && k.swapUntil == 0, "nothing held")
        // not while the panel is open; disarm by hand (a click)
        k = machine(); k.panelOpen = true; k.armSwap(until: 50)
        check(run(&k, [at(.down(V, "⌘⇧"), 49)]) == [.pass], "panel open: no swap, no switcher")
        k = machine(); k.armSwap(until: 50); k.disarmSwap()
        check(run(&k, [at(.down(V, "⌘⇧"), 49)]) == [.openSwitch], "disarmed by a click")
    }
}
