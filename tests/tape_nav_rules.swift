import Foundation

// swiftc -O -parse-as-library app/TapeNavRules.swift tests/tape_nav_rules.swift -o app/build/tape-nav-test && app/build/tape-nav-test
// The journal window's keys: every place × every key, then the edges (first line, no lines, no sidebar, no reader,
// a button that went, the command line, headers that fold, several items picked, ⌘ digits past the sidebar).
@main
struct TapeNavChecks {
    static var failures = 0, count = 0
    static func check(_ ok: Bool, _ what: String) { count += 1; if !ok { print("FAIL: " + what); failures += 1 } }
    typealias R = TapeNav.Region
    typealias K = TapeNav.Key
    static func st(_ r: R, sidebar: Bool = true, reader: Bool = false, buttons: Int = 3, row: Int = 2, rows: Int = 10, head: Bool = false,
                   folded: Bool = false, parent: Bool = true, open: Bool = false, picked: Int = 1, query: Bool = false, command: Bool = false) -> TapeNav.State {
        TapeNav.State(region: r, sidebar: sidebar, sidebarCount: 9, cursor: 2, reader: reader, readerActions: 4, buttons: buttons, row: row, rows: rows,
                      head: head, folded: folded, parent: parent, open: open, picked: picked, query: query, command: command)
    }
    static func go(_ s: TapeNav.State, _ k: K, _ r: R, _ e: TapeNav.Effect, _ what: String) {
        let (n, eff) = TapeNav.route(s, k)
        check(n.region == r && eff == e, "\(what): got \(n.region) \(eff), want \(r) \(e)")
    }
    static let all: [K] = [.up, .down, .pageUp, .pageDown, .left, .right, .tab, .backTab, .ret, .esc, .letter, .e, .digit(3), .shiftUp, .shiftDown,
                           .cmdUp, .cmdDown, .combine, .insert]

    static func main() {
        // the search field
        let s = st(.search)
        go(s, .up, .search, .none, "search ↑")
        go(s, .down, .list, .none, "search ↓ lands on the chosen line")
        go(s, .pageDown, .list, .moveRow(8), "search page down")
        go(s, .pageUp, .search, .none, "search page up")
        go(s, .left, .search, .pass, "search ← moves the caret")
        go(s, .right, .search, .pass, "search → moves the caret")
        go(s, .tab, .sidebar, .none, "search ⇥ sidebar")
        go(s, .backTab, .top(0), .none, "search ⇧⇥ top")
        go(s, .ret, .search, .toggleRow, "search ↵ opens the chosen item in place")
        go(st(.search, reader: true), .ret, .reader(0), .none, "search ↵ with the reader: the reader")
        go(st(.search, reader: true, head: true), .ret, .search, .toggleRow, "search ↵ on a header folds it")
        go(s, .esc, .list, .none, "search esc, empty: leaves the field")
        go(st(.search, query: true), .esc, .search, .clearSearch, "esc clears the search first")
        go(st(.search, command: true), .esc, .search, .endCommand, "esc leaves the command")
        go(st(.search, command: true), .ret, .search, .plan, "↵ asks the command")
        go(st(.search, command: true), .down, .search, .pass, "↓ in the command")
        go(s, .letter, .search, .pass, "search letter types")
        go(s, .e, .search, .pass, "search E types")
        go(s, .digit(3), .search, .pickSidebar(2), "search ⌘3")
        go(s, .shiftUp, .search, .pass, "search ⇧↑ selects text")
        go(s, .shiftDown, .search, .pass, "search ⇧↓ selects text")
        go(s, .cmdUp, .search, .pass, "search ⌘↑ moves the caret")
        go(s, .cmdDown, .search, .pass, "search ⌘↓ moves the caret")
        go(s, .combine, .search, .none, "search ⌘⇧E with one item")
        go(s, .insert, .search, .insert, "search ⌘↵ inserts the chosen item")
        go(st(.search, rows: 0), .down, .search, .none, "↓ with no lines")
        go(st(.search, rows: 0), .ret, .search, .none, "↵ with no lines")

        // the sidebar
        let b = st(.sidebar)
        go(b, .up, .sidebar, .pickSidebar(1), "sidebar ↑ picks the one above")
        go(b, .down, .sidebar, .pickSidebar(3), "sidebar ↓ picks the one below")
        go(b, .pageDown, .sidebar, .pickSidebar(6), "sidebar page down")
        go(b, .pageUp, .sidebar, .pickSidebar(0), "sidebar page up stops at the top")
        go(b, .left, .sidebar, .none, "sidebar ←")
        go(b, .right, .list, .none, "sidebar → list")
        go(b, .tab, .list, .none, "sidebar ⇥ list")
        go(b, .backTab, .search, .none, "sidebar ⇧⇥ search")
        go(b, .ret, .list, .none, "sidebar ↵ list")
        go(b, .esc, .search, .none, "sidebar esc search")
        go(b, .letter, .search, .typeInSearch, "sidebar letter searches")
        go(b, .e, .search, .typeInSearch, "sidebar E searches")
        go(b, .digit(1), .list, .pickSidebar(0), "sidebar ⌘1")
        go(b, .shiftUp, .sidebar, .none, "sidebar ⇧↑")
        go(b, .cmdDown, .list, .jumpChunk(1), "sidebar ⌘↓ next chunk")
        go(b, .insert, .sidebar, .insert, "sidebar ⌘↵")
        var top = b; top.cursor = 0
        go(top, .up, .sidebar, .none, "sidebar ↑ on the first entry")
        var last = b; last.cursor = 8
        go(last, .down, .sidebar, .none, "sidebar ↓ on the last entry")

        // the list: an item
        let l = st(.list)
        go(l, .up, .list, .moveRow(-1), "list ↑")
        go(l, .down, .list, .moveRow(1), "list ↓")
        go(l, .pageUp, .list, .moveRow(-8), "list page up")
        go(l, .pageDown, .list, .moveRow(8), "list page down")
        go(l, .left, .list, .toParent, "list ← goes up a level")
        go(st(.list, parent: false), .left, .sidebar, .none, "list ← with no level above: sidebar")
        go(st(.list, sidebar: false, parent: false), .left, .list, .none, "list ← with nothing to the left")
        go(l, .right, .button(0), .revealButtons, "list → opens the item, first button")
        go(st(.list, open: true), .right, .button(0), .none, "list → on an open item")
        go(st(.list, buttons: 0), .right, .list, .revealButtons, "list → before the buttons exist")
        go(st(.list, reader: true), .right, .reader(0), .none, "list → with the reader: its actions")
        go(st(.list, rows: 0), .right, .list, .none, "list → with no lines")
        go(l, .tab, .top(0), .none, "list ⇥ top")
        go(st(.list, reader: true), .tab, .reader(0), .none, "list ⇥ reader")
        go(l, .backTab, .sidebar, .none, "list ⇧⇥ sidebar")
        go(l, .ret, .list, .toggleRow, "list ↵ opens in place")
        go(st(.list, reader: true), .ret, .reader(0), .none, "list ↵ with the reader: the reader")
        go(l, .esc, .list, .closeWindow, "list esc, nothing open: close")
        go(st(.list, open: true), .esc, .list, .closeRow, "list esc closes the item")
        go(st(.list, open: true, picked: 3), .esc, .list, .single, "list esc, several picked: back to one")
        go(l, .letter, .search, .typeInSearch, "list letter searches")
        go(l, .e, .search, .typeInSearch, "list E searches")
        go(l, .digit(9), .list, .pickSidebar(8), "list ⌘9")
        go(l, .shiftUp, .list, .extend(-1), "list ⇧↑ picks")
        go(l, .shiftDown, .list, .extend(1), "list ⇧↓ picks")
        go(l, .cmdUp, .list, .jumpChunk(-1), "list ⌘↑")
        go(l, .cmdDown, .list, .jumpChunk(1), "list ⌘↓")
        go(l, .combine, .list, .none, "list ⌘⇧E with one item")
        go(st(.list, picked: 3), .combine, .editor, .combine, "list ⌘⇧E combines")
        go(l, .insert, .list, .insert, "list ⌘↵ inserts")
        go(st(.list, row: 0), .up, .search, .none, "list ↑ on the first line: search")
        go(st(.list, sidebar: false), .tab, .top(0), .none, "list ⇥ with the sidebar hidden")
        go(st(.list, sidebar: false), .backTab, .search, .none, "list ⇧⇥ with the sidebar hidden")

        // the list: a header
        let h = st(.list, head: true)
        go(h, .left, .list, .fold, "open header ← folds")
        go(st(.list, head: true, folded: true), .left, .list, .toParent, "folded header ← up a level")
        go(st(.list, head: true, folded: true, parent: false), .left, .sidebar, .none, "folded top chunk ← sidebar")
        go(st(.list, head: true, folded: true), .right, .list, .unfold, "folded header → unfolds")
        go(h, .right, .list, .moveRow(1), "open header → first line inside")
        go(st(.list, reader: true, head: true), .right, .list, .moveRow(1), "open header → with the reader")
        go(h, .ret, .list, .toggleRow, "header ↵ folds or unfolds")
        go(st(.list, reader: true, head: true), .ret, .list, .toggleRow, "header ↵ with the reader")
        go(h, .insert, .list, .none, "header ⌘↵: nothing to insert")
        go(st(.reader(0), reader: true, head: true), .e, .search, .typeInSearch, "header in the reader: E searches")

        // the buttons
        let n = st(.button(1), open: true)
        go(n, .up, .list, .moveRow(-1), "button ↑ moves the selection")
        go(n, .down, .list, .moveRow(1), "button ↓ moves the selection")
        go(n, .pageDown, .list, .moveRow(8), "button page down")
        go(n, .pageUp, .list, .moveRow(-8), "button page up")
        go(n, .left, .button(0), .none, "button ← previous")
        go(st(.button(0), open: true), .left, .list, .none, "first button ← list")
        go(n, .right, .button(2), .none, "button → next")
        go(st(.button(2), open: true), .right, .button(2), .none, "last button → stays")
        go(n, .tab, .top(0), .none, "button ⇥ top")
        go(n, .backTab, .sidebar, .none, "button ⇧⇥ sidebar")
        go(n, .ret, .button(1), .runButton(1), "button ↵ runs it")
        go(n, .esc, .list, .none, "button esc list")
        go(n, .letter, .search, .typeInSearch, "button letter searches")
        go(n, .e, .search, .typeInSearch, "button E searches")
        go(n, .digit(2), .list, .pickSidebar(1), "button ⌘2")
        go(n, .shiftDown, .list, .extend(1), "button ⇧↓ picks")
        go(n, .cmdUp, .list, .jumpChunk(-1), "button ⌘↑")
        go(n, .insert, .button(1), .insert, "button ⌘↵")
        go(st(.button(5), buttons: 2), .ret, .button(1), .runButton(1), "a button that went: the last one")
        go(st(.button(0), buttons: 0), .ret, .list, .toggleRow, "no buttons left: the list")

        // the reader
        let r = st(.reader(1), reader: true)
        go(r, .up, .reader(0), .moveRow(-1), "reader ↑: the selection moves, the reader follows")
        go(r, .down, .reader(0), .moveRow(1), "reader ↓")
        go(r, .pageDown, .reader(0), .moveRow(8), "reader page down")
        go(r, .left, .reader(0), .none, "reader ← previous action")
        go(st(.reader(0), reader: true), .left, .list, .none, "first action ← list")
        go(r, .right, .reader(2), .none, "reader → next action")
        go(st(.reader(3), reader: true), .right, .reader(3), .none, "last action → stays")
        go(r, .ret, .reader(1), .runReader(1), "reader ↵ runs the action (Edit is the first)")
        go(st(.reader(0), reader: true), .ret, .reader(0), .runReader(0), "reader ↵ on Edit")
        go(r, .e, .editor, .edit, "reader E edits")
        go(r, .letter, .search, .typeInSearch, "reader letter searches")
        go(r, .esc, .list, .none, "reader esc list")
        go(r, .tab, .top(0), .none, "reader ⇥ top")
        go(r, .backTab, .list, .none, "reader ⇧⇥ list")
        go(r, .digit(1), .list, .pickSidebar(0), "reader ⌘1")
        go(r, .shiftUp, .list, .extend(-1), "reader ⇧↑ picks")
        go(r, .cmdDown, .list, .jumpChunk(1), "reader ⌘↓")
        go(r, .insert, .reader(1), .insert, "reader ⌘↵ inserts")
        go(st(.reader(2), reader: false), .ret, .list, .toggleRow, "reader closed while in it: the list")
        go(st(.reader(9), reader: true), .ret, .reader(3), .runReader(3), "an action that went: the last one")

        // the editor: every key but Esc and ⌘↵ is the editor's
        let ed = st(.editor, reader: true)
        for k in all where k != .esc && k != .insert { go(ed, k, .editor, .pass, "editor \(k) is the editor's") }
        go(ed, .esc, .reader(0), .leaveEditor, "editor esc: done")
        go(ed, .insert, .editor, .insert, "editor ⌘↵ inserts the text")

        // the top actions
        let t = st(.top(1))
        go(t, .up, .top(1), .none, "top ↑")
        go(t, .down, .search, .none, "top ↓ search")
        go(t, .pageUp, .top(1), .none, "top page up")
        go(t, .pageDown, .search, .none, "top page down")
        go(t, .left, .top(0), .none, "top ← previous")
        go(st(.top(0)), .left, .top(0), .none, "first top ← stays")
        go(t, .right, .top(2), .none, "top → next")
        go(st(.top(3)), .right, .top(3), .none, "last top → stays")   // Names, Shortcuts, Settings, Help
        go(t, .tab, .search, .none, "top ⇥ search")
        go(t, .backTab, .list, .none, "top ⇧⇥ list")
        go(st(.top(0), reader: true), .backTab, .reader(0), .none, "top ⇧⇥ reader")
        go(t, .ret, .top(1), .runTop(1), "top ↵ runs it")
        go(t, .esc, .search, .none, "top esc search")
        go(t, .letter, .search, .typeInSearch, "top letter searches")
        go(t, .e, .search, .typeInSearch, "top E searches")
        go(t, .digit(4), .list, .pickSidebar(3), "top ⌘4")
        go(t, .shiftUp, .top(1), .none, "top ⇧↑")
        go(t, .cmdUp, .list, .jumpChunk(-1), "top ⌘↑")

        // ⌘ digits past the sidebar, the sidebar hidden while in it
        var few = st(.list); few.sidebarCount = 3
        go(few, .digit(4), .list, .none, "⌘4 with three entries")
        go(st(.list), .digit(0), .list, .none, "⌘0 is not an entry")
        go(st(.sidebar, sidebar: false), .ret, .list, .toggleRow, "sidebar hidden while in it: the list")
        go(st(.list, rows: 0), .cmdDown, .list, .none, "⌘↓ with no lines")
        go(st(.list, rows: 0), .shiftDown, .list, .none, "⇧↓ with no lines")
        check(TapeNav.route(st(.list), .digit(5)).0.cursor == 4, "⌘5 moves the cursor")
        // every place × every key gives an answer, and hints exist for every place
        for reg: R in [.search, .sidebar, .list, .button(0), .reader(0), .editor, .top(0)] {
            for k in all { _ = TapeNav.route(st(reg, reader: true), k) }
            check(!TapeNav.hints(st(reg)).isEmpty, "hints for \(reg)")
        }

        // soft round: Go to, back and forward, the slide-over reader, the gallery grid, the peek
        func gal(_ r: R, row: Int = 5, reader: Bool = false) -> TapeNav.State { var g = st(r, reader: reader, row: row); g.gallery = true; g.cols = 4; return g }
        for r in [R.search, .sidebar, .list, .reader(1), .top(1), .button(0)] { go(st(r), .goTo, .palette, .openPalette, "⌘T from \(r)") }
        go(st(.editor), .goTo, .editor, .pass, "⌘T in the editor types")
        let pal = st(.palette)
        go(pal, .down, .palette, .paletteMove(1), "palette ↓"); go(pal, .up, .palette, .paletteMove(-1), "palette ↑")
        go(pal, .pageDown, .palette, .paletteMove(8), "palette page down")
        go(pal, .ret, .list, .palettePick, "palette ↵ goes"); go(pal, .esc, .list, .closePalette, "palette esc")
        go(pal, .goTo, .list, .closePalette, "⌘T again closes")
        go(pal, .letter, .palette, .pass, "letters filter"); go(pal, .space, .palette, .pass, "space in the palette field")
        go(pal, .tab, .palette, .none, "tab stays"); go(pal, .back, .palette, .none, "no history in the palette")
        for r in [R.search, .list, .sidebar, .reader(0)] {
            go(st(r, reader: true), .back, r, .historyBack, "⌘[ from \(r)"); go(st(r, reader: true), .forward, r, .historyForward, "⌘] from \(r)")
        }
        go(st(.editor), .back, .editor, .pass, "⌘[ in the editor")
        // the slide-over reader (under 900 pt)
        var ov = st(.list); ov.over = true
        go(ov, .ret, .reader(0), .openOver, "↵ opens the slide-over")
        var ovOpen = st(.reader(1), reader: true); ovOpen.over = true
        go(ovOpen, .esc, .list, .closeOver, "esc closes the slide-over")
        var ovList = st(.list, reader: true); ovList.over = true
        go(ovList, .esc, .list, .closeOver, "esc on the list closes it too")
        go(st(.reader(1), reader: true), .esc, .list, .none, "a docked reader stays")
        var ovHead = st(.list, head: true); ovHead.over = true
        go(ovHead, .ret, .list, .toggleRow, "↵ on a header still folds")
        var ovSearch = st(.search); ovSearch.over = true
        go(ovSearch, .ret, .reader(0), .openOver, "↵ from the field opens the slide-over")
        // the gallery grid
        go(gal(.list), .down, .list, .moveGrid(1), "gallery ↓ a row"); go(gal(.list), .up, .list, .moveGrid(-1), "gallery ↑ a row")
        go(gal(.list), .pageDown, .list, .moveGrid(4), "gallery page down")
        go(gal(.list, row: 2), .up, .search, .none, "gallery ↑ on the top row: the field")
        go(gal(.list), .left, .list, .moveCard(-1), "gallery ← a card"); go(gal(.list), .right, .list, .moveCard(1), "gallery → a card")
        go(gal(.search), .down, .list, .none, "gallery: ↓ from the field lands")
        go(gal(.list), .ret, .reader(0), .openOver, "gallery ↵ opens the reader")
        go(gal(.list, reader: true), .ret, .reader(0), .none, "gallery ↵ with a docked reader")
        go(gal(.list), .shiftDown, .list, .extendGrid(0, 1), "gallery ⇧↓ picks a row")
        go(gal(.list), .shiftRight, .list, .extendGrid(1, 0), "gallery ⇧→ picks a card")
        go(st(.list), .shiftRight, .list, .none, "list ⇧→ does nothing")
        go(gal(.list), .cmdDown, .list, .jumpChunk(1), "gallery ⌘↓ the next chunk")
        var gh = gal(.list); gh.head = true; gh.folded = true
        go(gh, .right, .list, .unfold, "gallery: a chosen header still unfolds")
        // the peek
        go(gal(.list), .space, .peek, .peek, "space peeks"); go(st(.list), .space, .peek, .peek, "space peeks in the list too")
        go(st(.list, head: true), .space, .list, .none, "no peek on a header"); go(st(.search), .space, .search, .pass, "space types in the field")
        go(st(.list, rows: 0), .space, .list, .none, "no peek with nothing")
        let pk = gal(.peek)
        go(pk, .space, .list, .closePeek, "space closes the peek"); go(pk, .esc, .list, .closePeek, "esc closes the peek")
        go(pk, .right, .peek, .moveCard(1), "peek → next card"); go(pk, .down, .peek, .moveGrid(1), "peek ↓")
        go(st(.peek), .down, .peek, .moveRow(1), "list peek ↓ next line")
        go(pk, .ret, .list, .openOver, "peek ↵ opens the reader"); go(pk, .insert, .peek, .insert, "peek ⌘↵ inserts")
        go(pk, .letter, .peek, .none, "letters wait in the peek")
        check(TapeNav.hints(pk).contains("space"), "peek hints"); check(TapeNav.hints(pal).contains("go"), "palette hints")
        check(TapeNav.hints(gal(.list)).contains("⌘T"), "gallery hints")

        if failures > 0 { print("\(failures) of \(count) failed"); exit(1) }
        print("tape nav rules: all \(count) passed")
    }
}
