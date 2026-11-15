// The journal window's keys (second window round, 14 November 2026; Andrii: "I want to use arrow keys to navigate
// the buttons, right now I can't"). One place has the focus at a time: the search field, the sidebar, the list, the
// chosen item's buttons (when the reader is closed), the reader's actions, the editor, the three actions at the top.
// The search field keeps the text caret while the focus is elsewhere (letters always search), except in the editor.
// The list is an outline: chunks of time, days, weeks, sessions fold and unfold with ← and →. Pure: tested in
// tests/tape_nav_rules.swift, transition by transition, like QuickKeys.route in app/QuickRules.swift.
import Foundation

enum TapeNav {
    enum Region: Equatable { case search, sidebar, list, button(Int), reader(Int), editor, top(Int), palette, peek }
    enum Key: Equatable {
        case up, down, pageUp, pageDown, left, right, tab, backTab, ret, esc
        case letter, e                      // a letter; the letter E (Edit in the reader)
        case digit(Int)                     // ⌘1-⌘9
        case shiftUp, shiftDown             // pick several items
        case cmdUp, cmdDown                 // the chunk header before or after
        case combine                        // ⌘⇧E: the picked items into one new draft
        case insert                         // ⌘↵: into the app he came from
        // soft round (14 November 2026)
        case goTo                           // ⌘T: the Go to palette
        case back, forward                  // ⌘[ ⌘]: what he looked at before or after
        case space                          // a large peek of the chosen card
        case shiftLeft, shiftRight          // pick several cards across the grid
    }
    /// What the window does after a key; `pass` lets the field or the editor have it.
    enum Effect: Equatable {
        case none, pass
        case moveRow(Int)                   // the selection, by lines
        case pickSidebar(Int)               // the n-th visible sidebar entry
        case toggleRow                      // open or close the chosen item in place, fold or unfold a header
        case revealButtons                  // open the chosen item so its buttons show
        case runButton(Int), runReader(Int), runTop(Int)
        case fold, unfold, toParent         // the outline
        case extend(Int), single            // pick several, back to one
        case jumpChunk(Int)                 // the chunk header before (-1) or after (+1)
        case closeRow, clearSearch, endCommand, plan, closeWindow
        case typeInSearch                   // the letter goes to the search field
        case edit, leaveEditor, combine, insert
        // soft round
        case openPalette, closePalette, palettePick, paletteMove(Int)
        case historyBack, historyForward
        case openOver, closeOver            // the reader as a slide-over (under 900 pt, or the gallery with no docked reader)
        case peek, closePeek
        case moveGrid(Int), moveCard(Int)   // the gallery: rows up or down keeping the column; cards back or on
        case extendGrid(Int, Int)           // pick several cards: (cards, rows)
    }

    struct State: Equatable {
        var region: Region = .search
        var sidebar = true           // the sidebar is shown
        var sidebarCount = 0         // entries a key reaches
        var cursor = 0               // the sidebar entry the cursor is on
        var reader = false           // the reader pane is shown
        var readerActions = 0        // the reader's actions for the chosen item
        var buttons = 0              // the chosen item's buttons in place (reader closed)
        var row = 0, rows = 0        // the chosen line's place and how many lines can be chosen
        var head = false             // the chosen line is a header (chunk, day, week, month, year, session)
        var folded = false           // that header is folded
        var parent = false           // the chosen line sits under a header
        var open = false             // the chosen item is open in place
        var picked = 1               // items picked with ⇧↑ ⇧↓
        var query = false            // the search has text
        var command = false          // the field takes a command (⌘K)
        static let tops = 4          // Names, Shortcuts, Settings, Help
        var gallery = false          // the cards, not the list
        var cols = 1                 // cards in a row
        var over = false             // the reader opens as a slide-over (it is not a docked pane)
    }

    /// Tab order of the places.
    static func order(_ s: State) -> [Region] {
        var o: [Region] = [.search]
        if s.sidebar { o.append(.sidebar) }
        o.append(.list)
        if s.reader { o.append(.reader(0)) }
        o.append(.top(0))
        return o
    }

    static func route(_ s0: State, _ k: Key) -> (State, Effect) {
        var s = s0
        // a place that is no longer there: the nearest one
        if case .button(let i) = s.region, i >= s.buttons { s.region = s.buttons > 0 ? .button(s.buttons - 1) : .list }
        if case .reader(let i) = s.region {
            if !s.reader { s.region = .list } else if i >= s.readerActions { s.region = .reader(max(0, s.readerActions - 1)) }
        }
        if !s.sidebar, s.region == .sidebar { s.region = .list }

        // the editor has every key but Esc and ⌘↵
        if s.region == .editor {
            switch k {
            case .esc: s.region = .reader(0); return (s, .leaveEditor)
            case .insert: return (s, .insert)
            default: return (s, .pass)
            }
        }

        // the Go to palette has the keys while it is open: ↑ ↓ move, ↵ goes, esc closes; letters go to its field
        if s.region == .palette {
            switch k {
            case .up, .down: return (s, .paletteMove(k == .up ? -1 : 1))
            case .pageUp, .pageDown: return (s, .paletteMove(k == .pageUp ? -8 : 8))
            case .ret: s.region = .list; return (s, .palettePick)
            case .esc, .goTo: s.region = .list; return (s, .closePalette)
            case .letter, .e, .space, .left, .right, .shiftLeft, .shiftRight: return (s, .pass)
            default: return (s, .none)
            }
        }
        // the peek: Space or esc closes it, the arrows go to the next card under it, ↵ opens the reader
        if s.region == .peek {
            switch k {
            case .space, .esc: s.region = .list; return (s, .closePeek)
            case .up, .down:
                if s.gallery { return (s, .moveGrid(k == .up ? -1 : 1)) }
                return (s, .moveRow(k == .up ? -1 : 1))
            case .left, .right:
                if s.gallery { return (s, .moveCard(k == .left ? -1 : 1)) }
                return (s, .moveRow(k == .left ? -1 : 1))
            case .ret: s.region = s.reader ? .reader(0) : .list; return (s, s.reader ? .closePeek : .openOver)
            case .insert: return (s, .insert)
            default: return (s, .none)
            }
        }

        switch k {
        case .goTo:
            s.region = .palette
            return (s, .openPalette)

        case .back, .forward:
            return (s, k == .back ? .historyBack : .historyForward)

        case .space:
            switch s.region {
            case .list, .button, .reader:
                guard s.rows > 0, !s.head else { return (s, .none) }
                s.region = .peek
                return (s, .peek)
            default: return (s, .pass)
            }

        case .shiftLeft, .shiftRight:
            guard s.gallery, s.rows > 0, s.region == .list || s.region == .reader(0) || s.region == .peek else { return (s, s.region == .search ? .pass : .none) }
            s.region = .list
            return (s, .extendGrid(k == .shiftLeft ? -1 : 1, 0))

        case .digit(let n):
            guard n >= 1, n <= min(9, s.sidebarCount) else { return (s, .none) }
            s.cursor = n - 1
            if s.region != .search { s.region = .list }
            return (s, .pickSidebar(n - 1))

        case .tab, .backTab:
            let o = order(s)
            let here: Region
            switch s.region { case .button: here = .list; case .top: here = .top(0); case .reader: here = .reader(0); default: here = s.region }
            let i = o.firstIndex(of: here) ?? 0
            s.region = o[(i + (k == .tab ? 1 : o.count - 1)) % o.count]
            return (s, .none)

        case .letter, .e:
            switch s.region {
            case .search: return (s, .pass)
            case .reader where k == .e && s.rows > 0 && !s.head: s.region = .editor; return (s, .edit)
            default: s.region = .search; return (s, .typeInSearch)
            }

        case .combine:
            guard s.picked >= 2 else { return (s, .none) }
            s.region = .editor
            return (s, .combine)

        case .insert:
            return (s, s.rows > 0 && !s.head ? .insert : .none)

        case .cmdUp, .cmdDown:
            if s.region == .search { return (s, .pass) }
            guard s.rows > 0 else { return (s, .none) }
            s.region = .list
            return (s, .jumpChunk(k == .cmdUp ? -1 : 1))

        case .shiftUp, .shiftDown:
            switch s.region {
            case .search: return (s, .pass)
            case .list, .button, .reader:
                guard s.rows > 0 else { return (s, .none) }
                s.region = .list
                if s.gallery { return (s, .extendGrid(0, k == .shiftUp ? -1 : 1)) }
                return (s, .extend(k == .shiftUp ? -1 : 1))
            default: return (s, .none)
            }

        case .up, .down, .pageUp, .pageDown:
            if s.gallery, s.region == .list || { if case .button = s.region { return true }; return false }() {   // the grid: rows keep the column
                s.region = .list
                let rows = k == .up ? -1 : k == .down ? 1 : k == .pageUp ? -4 : 4
                if rows < 0, s.row < s.cols { s.region = .search; return (s, .none) }   // ↑ on the top row: the field
                return (s, .moveGrid(rows))
            }
            let by = k == .up ? -1 : k == .down ? 1 : k == .pageUp ? -8 : 8
            switch s.region {
            case .palette, .peek: return (s, .none)
            case .search:
                if s.command { return (s, .pass) }
                guard s.rows > 0 else { return (s, .none) }
                if by > 0 { s.region = .list; return (s, by > 1 ? .moveRow(by) : .none) }   // the first ↓ lands on the chosen line
                return (s, .none)
            case .list, .button:
                s.region = .list
                if by < 0, s.row == 0 { s.region = .search; return (s, .none) }   // ↑ on the first line: back to the field
                return (s, .moveRow(by))
            case .reader:
                s.region = .reader(0)
                return (s, s.rows > 0 ? .moveRow(by) : .none)   // the reader follows the selection
            case .sidebar:
                guard s.sidebarCount > 0 else { return (s, .none) }
                let c = max(0, min(s.sidebarCount - 1, s.cursor + (by > 0 ? 1 : -1) * (abs(by) > 1 ? 4 : 1)))
                if c == s.cursor { return (s, .none) }
                s.cursor = c
                return (s, .pickSidebar(c))
            case .top:
                if by > 0 { s.region = .search }
                return (s, .none)
            case .editor: return (s, .pass)
            }

        case .left:
            switch s.region {
            case .palette, .peek: return (s, .none)
            case .search, .editor: return (s, .pass)
            case .list where s.gallery && !s.head:
                return (s, .moveCard(-1))
            case .list:
                if s.head && !s.folded { return (s, .fold) }
                if s.parent { return (s, .toParent) }
                if s.sidebar { s.region = .sidebar }
                return (s, .none)
            case .button(let i): s.region = i == 0 ? .list : .button(i - 1); return (s, .none)
            case .reader(let i): s.region = i == 0 ? .list : .reader(i - 1); return (s, .none)
            case .sidebar: return (s, .none)
            case .top(let i): s.region = .top(max(0, i - 1)); return (s, .none)
            }

        case .right:
            switch s.region {
            case .palette, .peek: return (s, .none)
            case .search, .editor: return (s, .pass)
            case .sidebar: s.region = .list; return (s, .none)
            case .list where s.gallery && !s.head:
                return (s, s.rows > 0 ? .moveCard(1) : .none)
            case .list:
                guard s.rows > 0 else { return (s, .none) }
                if s.head { return (s, s.folded ? .unfold : .moveRow(1)) }
                if s.reader { s.region = .reader(0); return (s, .none) }
                if s.buttons > 0 { s.region = .button(0); return (s, s.open ? .none : .revealButtons) }
                return (s, .revealButtons)   // the window opens the item; its buttons come with the next state
            case .button(let i): s.region = .button(min(s.buttons - 1, i + 1)); return (s, .none)
            case .reader(let i): s.region = .reader(min(max(0, s.readerActions - 1), i + 1)); return (s, .none)
            case .top(let i): s.region = .top(min(State.tops - 1, i + 1)); return (s, .none)
            }

        case .ret:
            switch s.region {
            case .palette, .peek: return (s, .none)
            case .search:
                if s.command { return (s, .plan) }
                guard s.rows > 0 else { return (s, .none) }
                if !s.head, s.reader { s.region = .reader(0); return (s, .none) }
                if !s.head, s.over || s.gallery { s.region = .reader(0); return (s, .openOver) }
                return (s, .toggleRow)
            case .list:
                guard s.rows > 0 else { return (s, .none) }
                if !s.head, s.reader { s.region = .reader(0); return (s, .none) }
                if !s.head, s.over || s.gallery { s.region = .reader(0); return (s, .openOver) }
                return (s, .toggleRow)
            case .sidebar: s.region = .list; return (s, .none)
            case .button(let i): return (s, .runButton(i))
            case .reader(let i): return (s, s.readerActions > 0 ? .runReader(i) : .none)
            case .top(let i): return (s, .runTop(i))
            case .editor: return (s, .pass)
            }

        case .esc:
            switch s.region {
            case .palette, .peek: s.region = .list; return (s, .none)
            case .button: s.region = .list; return (s, .none)
            case .reader:
                s.region = .list
                return (s, s.over && s.reader ? .closeOver : .none)
            case .list:
                if s.picked > 1 { return (s, .single) }
                if s.over && s.reader { return (s, .closeOver) }
                if s.open { return (s, .closeRow) }
                return (s, .closeWindow)
            case .sidebar, .top: s.region = .search; return (s, .none)
            case .search:
                if s.command { return (s, .endCommand) }
                if s.query { return (s, .clearSearch) }
                s.region = .list
                return (s, .none)                  // the second Esc leaves the field
            case .editor: return (s, .leaveEditor)
            }
        }
    }

    /// The key hints the status line shows for the place in focus.
    static func hints(_ s: State) -> String {
        switch s.region {
        case .search: return s.command ? "↵ ask · esc back" : "↓ results · ⇥ next place · esc " + (s.query ? "clear" : "leave")
        case .sidebar: return "↑↓ pick · → list · ⌘1-9 jump"
        case .list:
            if s.head { return "← → " + (s.folded ? "unfold" : "fold") + " · ↑↓ move · ⌘↑⌘↓ chunks" }
            if s.gallery { return "arrows move · space peek · ↵ reader · ⇧ arrows pick · ⌘[ ⌘] back, forward · ⌘T go to" }
            return "↑↓ move · ⇧↑⇧↓ pick" + (s.picked > 1 ? " · ⌘⇧E combine" : "") + " · ↵ " + (s.reader ? "reader" : s.open ? "close" : "open") + " · ← up a level"
        case .button: return "← → buttons · ↵ run · esc list"
        case .reader: return "← → actions · ↵ run · E edit · ⌘↵ insert · esc list"
        case .editor: return "esc done · ⌘↵ insert · ⌘Z undo"
        case .top: return "← → actions · ↵ open · esc search"
        case .palette: return "↑↓ pick · ↵ go · esc close"
        case .peek: return "space or esc close · arrows next · ↵ reader · ⌘↵ insert"
        }
    }
}
