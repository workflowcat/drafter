import Foundation

// swiftc -O -parse-as-library app/JournalLayout.swift tests/journal_layout.swift -o app/build/journal-layout-test && app/build/journal-layout-test
// Breakpoints, the split, the gallery grid and its keys, back and forward, pinned order, the window frame.
@main
struct JournalLayoutTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL " + what) } }
    static func main() {
        typealias L = JournalLayout
        // breakpoints
        check(L.panes(width: 1280, sidebar: true, reader: nil, gallery: false) == (.full, .pane), "wide list: three panes")
        check(L.panes(width: 1280, sidebar: true, reader: nil, gallery: true) == (.full, .closed), "wide gallery: reader closed")
        check(L.panes(width: 1280, sidebar: true, reader: true, gallery: true) == (.full, .pane), "gallery reader docked")
        check(L.panes(width: 899, sidebar: true, reader: true, gallery: false) == (.full, .over), "under 900: slide-over")
        check(L.panes(width: 639, sidebar: true, reader: nil, gallery: true) == (.strip, .over), "under 640: a strip")
        check(L.panes(width: 560, sidebar: false, reader: nil, gallery: false) == (.hidden, .over), "hidden stays hidden")
        // the split
        let p = L.Pane.sidebar
        check(L.drag(p, from: 214, by: 40) == (254, false), "drag wider")
        check(L.drag(p, from: 214, by: 400) == (340, false), "max")
        check(L.drag(p, from: 214, by: -60) == (170, false), "min holds")
        check(L.drag(p, from: 214, by: -100) == (214, true), "under the minimum: collapsed, width kept")
        check(L.reset(p) == 214 && L.kept(p, 999) == 340 && L.kept(p, nil) == 214, "reset and kept")
        // gallery columns and cards
        check(L.columns(width: 300, size: 1) == 1, "narrow: one column")
        check(L.columns(width: 560, size: 1) == 2, "560: two")
        check(L.columns(width: 1060, size: 1) == 4, "1060 medium: four")
        check(L.columns(width: 1060, size: 0) == 5, "small: five")
        check(L.columns(width: 1060, size: 2) == 3, "large: three")
        check(L.columns(width: 4000, size: 0) == 6, "at most six")
        let w = L.cardWidth(width: 1060, cols: 4)
        check(abs(w * 4 + L.gap * 3 + 32 - 1060) < 0.01 && w >= L.cardMin[1], "cards fill the row")
        check(L.cardHeight[0] < L.cardHeight[1] && L.cardHeight[1] < L.cardHeight[2], "three steps")
        // wire round: medium holds about four lines, large about seven, small as it was
        check(L.cardHeight[0] == 112, "small as it was")
        check(L.linesIn(1) == 4, "medium: four lines (\(L.linesIn(1)))")
        check(L.linesIn(2) == 7, "large: seven lines (\(L.linesIn(2)))")
        check(L.cardHeight[1] <= 120 && L.cardHeight[2] <= 190, "no room for lines nobody wrote: \(L.cardHeight)")
        // a first screen at 1280 x 1000 (gallery pane about 1042 x 788 pt): a chunk header, two parts, three label
        // strips, then rows of cards; medium holds at least 20 whole cards
        func perScreen(_ s: Int, width: Double = 1042, height: Double = 788, strips: Int = 3) -> Int {
            let cols = L.columns(width: width, size: s)
            var y = 6 + L.chunkH + 2 * L.partH + Double(strips) * L.labelH, rows = 0
            while y + L.cardHeight[s] <= height { y += L.cardHeight[s] + L.gap; rows += 1 }
            return rows * cols
        }
        check(perScreen(1) >= 20, "medium: 20 whole cards or more (\(perScreen(1)))")
        check(perScreen(0) >= 20 && perScreen(2) >= 9, "small \(perScreen(0)), large \(perScreen(2))")
        // a session across rows: the label once, a rule on each further row
        check(L.segments(first: 2, count: 10, cols: 4) == [.init(row: 0, col: 2, span: 2, label: true), .init(row: 1, col: 0, span: 4, label: false),
                                                          .init(row: 2, col: 0, span: 4, label: false)], "a session over three rows")
        check(L.segments(first: 0, count: 3, cols: 4) == [.init(row: 0, col: 0, span: 3, label: true)], "one row: the label only")
        check(L.segments(first: 3, count: 1, cols: 4) == [.init(row: 0, col: 3, span: 1, label: true)], "at the row end")
        check(L.segments(first: 0, count: 0, cols: 4).isEmpty && L.segments(first: 0, count: 4, cols: 0).isEmpty, "nothing to place")
        // the grid keys: groups of 5, 2, 7 cards in 3 columns
        let c = [5, 2, 7]
        check(L.move(.init(group: 0, index: 1), dy: 1, counts: c, cols: 3) == .init(group: 0, index: 4), "down keeps the column")
        check(L.move(.init(group: 0, index: 2), dy: 1, counts: c, cols: 3) == .init(group: 0, index: 4), "down to a short row: its last")
        check(L.move(.init(group: 0, index: 4), dy: 1, counts: c, cols: 3) == .init(group: 1, index: 1), "down crosses a group label")
        check(L.move(.init(group: 1, index: 1), dy: 1, counts: c, cols: 3) == .init(group: 2, index: 1), "and the next")
        check(L.move(.init(group: 2, index: 1), dy: -1, counts: c, cols: 3) == .init(group: 1, index: 1), "up crosses back")
        check(L.move(.init(group: 1, index: 0), dy: -1, counts: c, cols: 3) == .init(group: 0, index: 3), "up to the last row, same column")
        check(L.move(.init(group: 0, index: 1), dy: -1, counts: c, cols: 3) == .init(group: 0, index: 1), "top stays")
        check(L.move(.init(group: 2, index: 6), dy: 1, counts: c, cols: 3) == .init(group: 2, index: 6), "bottom stays")
        check(L.move(.init(group: 0, index: 4), dx: 1, counts: c, cols: 3) == .init(group: 1, index: 0), "right wraps to the next group")
        check(L.move(.init(group: 1, index: 0), dx: -1, counts: c, cols: 3) == .init(group: 0, index: 4), "left wraps back")
        check(L.move(.init(group: 0, index: 0), dx: -1, counts: c, cols: 3) == .init(group: 0, index: 0), "first stays")
        check(L.move(.init(group: 0, index: 0), dy: 3, counts: c, cols: 3) == .init(group: 2, index: 0), "page down by rows")
        check(L.move(.init(group: 0, index: 0), dy: 1, counts: [1, 0, 2], cols: 3) == .init(group: 2, index: 0), "empty groups skipped")
        check(L.topRow(.init(group: 0, index: 2), counts: c, cols: 3) && !L.topRow(.init(group: 0, index: 3), counts: c, cols: 3), "top row")
        // back and forward
        func pl(_ c: String?, _ f: String = "all", q: String = "") -> L.Place { L.Place(chosen: c, filter: f, group: "time", query: q, view: "gallery") }
        var h = L.History()
        h = L.record(h, pl("a"), at: 0)
        h = L.record(h, pl("b"), at: 0.5)          // arrows: one step
        h = L.record(h, pl("c"), at: 1.0)
        check(h.back.isEmpty && h.current == pl("c"), "arrowing coalesces")
        h = L.record(h, pl("c", "pinned"), at: 1.2) // a filter is always a step
        h = L.record(h, pl("d", "pinned"), at: 5)   // a later selection is a step
        check(h.back == [pl("c"), pl("c", "pinned")], "steps kept: \(h.back)")
        var (h2, to) = L.goBack(h)
        check(to == pl("c", "pinned") && h2.canForward, "back")
        (h2, to) = L.goBack(h2)
        check(to == pl("c") && !h2.canBack, "back again")
        (h2, to) = L.goForward(h2)
        check(to == pl("c", "pinned"), "forward")
        h2 = L.record(h2, pl("x", q: "map"), at: 9)
        check(!h2.canForward, "a new place clears forward")
        check(L.record(h2, pl("x", q: "map"), at: 10) == h2, "the same place is no step")
        // pinned order
        check(L.pinned(["b", "a"], pins: ["c", "a", "b"]) == ["c", "b", "a"], "new pins first, then his order")
        check(L.move(["a", "b", "c", "d"], ["d"], before: "b") == ["a", "d", "b", "c"], "move one")
        check(L.move(["a", "b", "c", "d"], ["a", "c"], before: nil) == ["b", "d", "a", "c"], "move two to the end")
        // the frame
        let v = CGRect(x: 0, y: 0, width: 1440, height: 900)
        check(L.restore(CGRect(x: 1300, y: -50, width: 400, height: 300), visible: v) == CGRect(x: 920, y: 0, width: 520, height: 380), "inside and at least the minimum")
        check(L.restore(CGRect(x: 100, y: 100, width: 3000, height: 2000), visible: v) == v, "never larger than the screen")
        check(L.screenKey(v) == "1440x900", "screen key")
        print(failed == 0 ? "journal layout: all passed" : "journal layout: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
