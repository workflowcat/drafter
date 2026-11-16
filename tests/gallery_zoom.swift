import Foundation

// swiftc -O -parse-as-library app/GalleryZoom.swift tests/gallery_zoom.swift -o app/build/gallery-zoom-test && app/build/gallery-zoom-test
// The zoom ladder, the pinch, the summaries (made-up lines), the anchor, the card fit.
@main
struct GalleryZoomTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL " + what) } }
    static func main() {
        typealias Z = GalleryZoom
        // the ladder
        check(Z.step(.medium, by: -1) == .small, "⌘- from medium: small")
        check(Z.step(.small, by: -1) == .lines, "⌘- from small: lines")
        check(Z.step(.lines, by: -1) == .days, "⌘- from lines: days")
        check(Z.step(.days, by: -1) == .days, "held at days")
        check(Z.step(.large, by: 1) == .large, "held at large")
        check(Z.step(.days, by: 3) == .medium, "three nearer from days")
        check(Z.Level.cards(0) == .small && Z.Level.cards(2) == .large && Z.Level.cards(9) == .large, "card sizes map")
        check(Z.Level.lines.cardSize == nil && Z.Level.medium.cardSize == 1, "card size of a level")
        // the pinch: small events add up; one level per step; the rest is kept; out is negative
        var p = Z.Pinch()
        check(p.add(0.1) == 0 && p.add(0.1) == 0 && p.add(0.05) == 1, "pinch in adds up to one step")
        check(abs(p.sum - 0.03) < 1e-9, "the rest is kept")
        var q = Z.Pinch()
        check(q.add(-0.5) == -2, "a fast pinch out: two steps")
        // summaries (made-up lines)
        check(Z.summary("  Plan for the week:   form, map,\ninvoice") == "Plan for the week: form, map,", "first line, spaces folded")
        check(Z.summary("\n\nSee you at the station at nine. Bring the drawings.") == "See you at the station at nine.", "first sentence")
        check(Z.summary("Hi. See you at the station at nine") == "Hi. See you at the station at nine", "a one-word sentence is not cut")
        let long = Z.summary(String(repeating: "lantern order ", count: 20), max: 40)
        check(long.count <= 41 && long.hasSuffix("…") && !long.contains("  "), "long line cut at a word: \(long)")
        check(Z.summary("") == "" && Z.summary(" \n ") == "", "empty")
        check(Z.summary("https://example.org/station/review-14#plan") == "https://example.org/station/review-14#plan", "a link stays whole")
        let d = Z.day(["Plan for the week: form, map", "plan for the week: form, map", "Room 4.12, second floor", "Call Mila"], max: 80)
        check(d == "Plan for the week: form, map · Room 4.12, second floor · Call Mila", "day: distinct, joined: \(d)")
        let short = Z.day(["Alpha beta gamma delta", "Epsilon zeta eta theta", "Iota kappa lambda mu"], max: 50)
        check(short == "Alpha beta gamma delta · Epsilon zeta eta theta …", "day: held under max: \(short)")
        // the anchor: the pointer at the middle of a card stays at the card's middle
        let a = Z.anchor(pointer: 500, top: 300, old: (450, 100), new: (900, 40), page: 5000, view: 800)
        check(a == 900 + 20 - 200, "anchor keeps the pointer on the card: \(a)")
        check(Z.anchor(pointer: 100, top: 0, old: (50, 100), new: (10, 50), page: 2000, view: 800) == 0, "anchor held at the top")
        check(Z.anchor(pointer: 100, top: 0, old: (50, 100), new: (1900, 50), page: 2000, view: 800) == 1200, "anchor held at the bottom")
        // the fit: floor and ceiling
        check(Z.fit(content: 10, top: 9, foot: 28, minContent: 40, maxContent: 200) == 77, "short text: the floor")
        check(Z.fit(content: 120.2, top: 9, foot: 28, minContent: 40, maxContent: 200) == 158, "fits its text")
        check(Z.fit(content: 900, top: 9, foot: 28, minContent: 40, maxContent: 200) == 237, "long text: the ceiling")
        print(failed == 0 ? "gallery zoom: all passed" : "gallery zoom: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
