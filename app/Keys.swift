// Keys: every keystroke hides or trims the ghost and asks again after a pause. Drafter's keys are three (Andrii,
// 2026-10-18): Tab takes the ghost or runs the chip, Right Option = voice, ⌃⌥Space = command strip. The last two
// still belong to Voice Notes and Capture until they are retired, so Drafter leaves them alone for now.
import AppKit
import EventKit
import Carbon

final class Keys {
    static let shared = Keys()
    var tap: CFMachPort?
    var timer: Timer?
    var seq = 0
    var inputRevision = 0
    /// The same without modifier changes: a take-back "on the very next key" must not be spent by releasing ⇧ after
    /// ⇧Tab, or by the event a layout switch sends (Argon 18).
    var editRevision = 0
    var spot: Spot?
    var shownAt = Date.distantPast
    /// Ask right after each key (only long enough for the app to put the letter in the field); the engine drops an
    /// older request as soon as a newer one arrives, so typing fast costs nothing (2026-10-19, was 200 ms).
    let debounce = 0.035
    // suggestion length (2026-10-21, Cotypist's few words; bench/replay.py): up to 4 words in 10 tokens; past the sure
    // words, words the model gives at least `soft` still show, lighter
    // per app (replay on 30 of his messages): chats get a lighter tail after the sure words (63% of those words right,
    // letters saved the same); AI apps get a lighter first word, at most 3 words (Claude 37% -> 42% letters saved);
    // apps where he almost never takes one (Zoom: 3 of 294) stay strict
    static let tokens = 10
    // Round two (2026-11-13): "soft" only ever reached the old path without the gate; the gated path (live since
    // 31 October) gets the lighter tail as "tail" (each token >= 0.2) and "tail_words" (8 in all). Held set, AI apps:
    // letters saved 30.9% -> 31.6%, ghosts of 15+ letters 10 -> 89 (bench/lengths.py). Settings longGhostsAI (on),
    // longGhostsChats (off).
    // Round five (2026-11-14): the tail bar 0.2 -> 0.3 ("longer only when the model is sure"). Live 7-14 Nov he took
    // none of 11 ghosts of 10+ letters whole; held AI lines with the live selector: ghosts of 10+ letters 96 -> 55,
    // the wholly right ones 5 -> 6, grey words after the first wrong one 699 -> 587, letters saved the same
    // (bench/out/r5_tail.py).
    // Long round (2026-11-14, Andrii: "with cotypist i had this experience of literally full sentences"): setting
    // ghostLength. "sentence" (default) and "phrase": after the gate's first word the ghost runs while the running
    // chance of its words holds (product, floor 0.1), to the sentence end, up to 24 tokens; the less sure end is lighter
    // (engine/gatecore.py run_words). "word" keeps round five's rule below. Zoom stays strict.
    static func length(_ id: String) -> [String: Any] {
        let st = Drafter.shared.settings
        // earlier round (2026-11-16): 3-5 words (ghostWords) and the lower gate's lighter guesses (guessGhosts, guessShade)
        if let run = GhostRules.runBody(mode: st.ghostLength, words: st.ghostWords, minWords: st.ghostMinWords, maxWords: st.ghostMaxWords,
                                        guess: st.guessGhosts, shade: st.guessShade, strict: id == "us.zoom.xos",
                                        early: st.earlyStart) { return run }
        let tail: [String: Any] = ["tail": 0.3, "tail_words": 8]
        if aiApps.contains(id) { return ["max_words": 3, "soft": 0.25, "soft_from": 1].merging(st.longGhostsAI ? tail : [:]) { a, _ in a } }
        if id == "us.zoom.xos" { return ["max_words": 3] }
        return ["max_words": 4, "soft": 0.2, "soft_from": 2].merging(st.longGhostsChats ? tail : [:]) { a, _ in a }
    }
    /// Fewer letters than this and a ghost is not shown (2026-11-13: he took one under 5 letters 3% of the time, and
    /// typed 79% of them by hand). Setting `minGhost` (data/settings.json, 0 = all).
    static var minLetters: Int {
        let st = Drafter.shared.settings
        return GhostRules.minLetters(minGhost: st.minGhost, short: st.shortGhosts, minShort: st.minGhostShort)
    }
    static func letters(_ s: String) -> Int { s.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 } }
    /// keyDown events only (a Shift press does not count) and when the last one came: key-to-ghost in the log
    var keyRevision = 0
    var keyAt = Date.distantPast
    /// The last fresh read of the field and the keyDown count it was made at: the next letter is predictable from it.
    var lastRead: (spot: Spot, rev: Int, at: Date)?
    /// A suggestion asked at the key itself for the predicted text (lastRead + the letter), before the app has the
    /// letter in its field: the 35 ms wait and one Accessibility read are not on the way any more (2026-11-13).
    var predicted: (before: String, seq: Int, pending: Bool, rev: Int)?
    var lastBefore = ""
    /// The field holds the test marker: what is typed there is never learned (test rows had made a typo "his word").
    var lastTest = false
    var lastApp = ""
    /// What became of the grey text shown last (2026-10-31): taken with Tab, typed by hand letter for letter, or
    /// dropped. One "ghost" line in data/app.log when any of it was used; the nightly review counts them.
    struct GhostStat { let app: String; let src: String; var len: Int; let word: Int; var taken = 0; var typed = 0 }
    /// The ghost of a two-step answer as first drawn (round two): the engine's text then, how many characters of its
    /// start were not shown (typed meanwhile, a space), and the whole grey text since; later parts only add to it.
    var painted: (seq: Int, raw: String, drop: Int, full: String)?
    /// The newest request whose final line came back: its parts (and their retries) are never drawn after it.
    var finishedSeq = 0
    var stat: GhostStat?
    /// Typo hold (TypoHold in app/TypoRules.swift): the last line it was worked out for (its spell checks run once per
    /// line text) and the hold last logged, so each hold logs one line.
    var holdMemo: (line: String, at: TypoHold.At, len: Int)?
    var holdLogged: String?
    /// Gaps between typed letters, one histogram line a minute (app/KeyGapRules.swift).
    var gaps = KeyGaps()
    func endStat() {
        guard let s = stat else { return }
        stat = nil
        if s.taken > 0 || s.typed > 0 {
            log("ghost \(s.app) \(s.src) len \(s.len) word \(s.word) taken \(s.taken) typed \(s.typed)")
        }
    }
    func beginStat(_ app: NSRunningApplication, _ src: String, _ text: String) {
        endStat()
        stat = GhostStat(app: app.bundleIdentifier ?? "?", src: src, len: text.count,
                         word: Keys.nextWord(text).trimmingCharacters(in: .whitespaces).count)
    }
    /// The text on screen above the field (the message being answered), read off the main thread and kept per field.
    var context: (el: AXUIElement, text: String, at: Date)?
    /// Goes up on every click and shortcut (a chat may have changed while the field stayed the same): an early Claude
    /// answer is only used under the same number, and the screen is read again (Codex review, 2026-10-31).
    var fieldGen = 0
    /// A click that took a fix chip: its release is swallowed too.
    var swallowUp = false
    var contextReads = 0
    var contextBusy: Bool { contextReads > 0 }
    /// The chat above each screen (app · window), kept for this run only, never on disk (2026-11-01, Andrii: "store more
    /// context from specific screens to help with quick responses"): the first key in a chat he comes back to has it at
    /// once, and the engine still holds that screen's prompt warm (engine/model.py SPARE), so nothing is read again.
    var screens: [String: String] = [:], screenOrder: [String] = []
    static func screenKey(_ s: Spot) -> String { (s.app.bundleIdentifier ?? "") + " · " + s.title }
    func remember(_ key: String, _ text: String) {
        guard !text.isEmpty else { return }
        screens[key] = text; screenOrder.removeAll { $0 == key }; screenOrder.append(key)
        if screenOrder.count > 40 { screens[screenOrder.removeFirst()] = nil }
    }
    let contextQueue = DispatchQueue(label: "drafter.context")

    func start() {
        _ = Snippets.all; _ = Snippets.replacements; PeopleCards.refresh(); Autocorrect.refresh(); Entities.warm()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue) | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, _ in Keys.shared.handle(type, event) }, userInfo: nil)
        guard let tap else {
            log("no event tap: Accessibility not granted yet; retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.start() }
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap on")
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Focus.mark { return pass }
        // fix marks only (2026-11-01): the release of a click that took a chip, and scrolls that move the underlines
        if type == .leftMouseUp { if swallowUp { swallowUp = false; return nil }; return pass }
        if type == .scrollWheel { if !FixMarks.shared.marks.isEmpty { FixMarks.shared.moved(scroll: true) }; return pass }
        inputRevision += 1
        if type != .flagsChanged { editRevision += 1 }
        if type == .keyDown { keyRevision += 1; keyAt = Date() }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // the command panel (Dock click or menu; no key of its own: ⌃⌥Space is Aleph's side panel and ⌘Space Aleph's bar,
        // which is to become the one control center calling /command). While it is open its field takes the keys.
        if Quick.shared.tap(type, event) { return nil }   // the Quick panel (app/Quick.swift): its key, and its keys while open
        if type == .keyDown, ContextPanel.shared.isOpen {                                                    // the context preview (app/Entities.swift)
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            if ContextPanel.shared.key(code, event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]), String(utf16CodeUnits: u, count: n)) { return nil }
        }
        if Command.shared.isOpen {
            if type == .keyDown, code == 6, event.flags.contains(.maskCommand) {   // ⌘Z on a receipt: undo what it made
                if Thread.isMainThread, Command.shared.keyUndo() { return nil }
            }
            if type != .flagsChanged { return pass }
        }
        // Right Option = voice (only once Andrii switched it over from Voice Notes). Works while typing help is paused.
        if type == .flagsChanged {
            // the tap must return at once: starting the microphone here made macOS switch the tap off and lose the
            // press that ends the take (2026-10-19), so the work goes to the main queue
            if code == 61, Drafter.shared.settings.voice {
                let down = event.flags.contains(.maskAlternate), long = event.flags.contains(.maskShift), at = Date()
                DispatchQueue.main.async { Talk.shared.key(down: down, long: long, at: at) }
            }
            if code == 56 || code == 60, Drafter.shared.settings.layoutFix, Drafter.shared.active { shiftTap(event.flags.contains(.maskShift)) }
            return pass
        }
        if type == .keyDown, KeyHooks.voiceKey(code, event.flags) { return nil }   // the voice note's flow (VoiceFlowRules)
        if type == .keyDown, Talk.shared.state == .listening {
            // Esc drops a short take; a long note or call never (2026-10-20: Esc in a meeting lost two calls), Esc is the app's
            if code == 53, !Talk.shared.long { DispatchQueue.main.async { Talk.shared.cancel() }; return nil }
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if code == 36 || code == 76, mods.isEmpty, !Talk.shared.long {
                // Enter ends the take (Andrii, 2026-10-19: a take that went on listening swallowed his next Enter, and he
                // could not send twice in other apps). Words heard: this Enter puts them in and sends nothing; the take is
                // over, so his next Enter sends as usual. No words: the take stops and this Enter goes to the app.
                // (2026-10-19 later) Enter no longer ends the take: words heard since the last Enter go in and listening
                // goes on; with no new words the Enter is his and goes to the app (sends), so a second send never blocks.
                if Talk.shared.canSend { DispatchQueue.main.async { Talk.shared.send() }; return nil }
                return pass
            }
            DispatchQueue.main.async { Talk.shared.keyDuringTake() }   // his own key: live typing steps aside
            return pass
        }
        guard Drafter.shared.active else { return pass }
        if type != .keyDown {
            // a click on a fixed word's chip: his word comes back; the click goes nowhere else
            if type == .leftMouseDown, FixMarks.shared.hitChip(event.location) {
                swallowUp = true
                DispatchQueue.main.async { FixMarks.shared.take("click") }
                return nil
            }
            if !FixMarks.shared.marks.isEmpty { FixMarks.shared.moved(scroll: false) }
            Fields.end("click"); Rework.shared.close("click")
            // a click: the caret may be in a new field or chat; read its screen context and warm the cache before typing
            cancel(); fieldGen += 1; context = nil
            lastRead = nil   // the caret may have moved: warmField reads the field again (round five)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.warmField() }
            return pass
        }

        let f = event.flags
        let mods = f.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let g = Ghost.shared
        if Rework.shared.isOpen {                                                                           // ⌥Tab list on a selection
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            if Rework.shared.key(code, typed: String(utf16CodeUnits: u, count: n), mods: mods) { return nil }
        } else if code == 48, mods == .maskAlternate, Rework.shared.mayStart() || Entities.mayAttach() {
            // the selection is read off the tap (Codex review 2026-11-01); with none, names in this message may attach their
            // context (app/Entities.swift); with neither, the ⌥Tab goes on to the app
            DispatchQueue.main.async {
                if Rework.shared.mayStart(), Rework.shared.start() { return }
                if !Entities.optionTab() { Fields.arrows(48, 1, alt: true) }
            }
            return nil
        }
        if EntityCard.shared.isOpen {                                                                       // the `;` card (app/Entities.swift)
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            if EntityCard.shared.key(code, mods, String(utf16CodeUnits: u, count: n)) { return nil }
        }
        if (code == 36 || code == 76) && mods.isEmpty && (!Entities.tray.isEmpty || !Entities.pending.isEmpty) {
            DispatchQueue.main.async { Entities.sent() }                                                     // sent: this message's names go
        }
        if code == 53, mods.isEmpty { DispatchQueue.main.async { EntityMark.shared.hide() } }
        if Fields.cur != nil {                                                                              // places to fill in a snippet
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            if Fields.key(code, typed: String(utf16CodeUnits: u, count: n), mods: mods) { return nil }
            // while places are open, his keys only fill them: no autocorrect, fixes or suggestions, which would change the
            // text behind Fields' back (Codex review 2026-11-01: a corrected word went into the copies as he typed it)
            if Fields.cur != nil { cancel(); if Ghost.shared.visible { DispatchQueue.main.async { Ghost.shared.hide() } }; return pass }
        }
        if Fixer.mark != nil {                                                                              // the space after a fixed word
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            Fixer.key(String(utf16CodeUnits: u, count: n))
        }
        if !FixMarks.shared.marks.isEmpty {
            if code == 48, mods.isEmpty, !g.visible, FixMarks.shared.tabReady {                             // Tab on a fixed word's chip
                DispatchQueue.main.async { FixMarks.shared.take("tab") }; return nil
            }
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            FixMarks.shared.key(code, typed: String(utf16CodeUnits: u, count: n))
        }
        // Esc, ⇧Esc or another key on an offer, grey words or not (Codex round 4: with a ghost up, typing left the offer
        // armed and the next Tab started a recording); Tab still goes to the ghost when one shows
        if Offer.active, !(code == 48 && mods.isEmpty) {
            if let i = CopyChip.digit(code: Int(code), plain: mods.isEmpty, forms: Offer.picks.isEmpty ? 0 : (Offer.picks.keys.max() ?? 0) + 1) {   // 2 / 3 on the copy chip
                DispatchQueue.main.async { Offer.pick(i) }; return nil
            }
            if code == 53, mods.isEmpty { DispatchQueue.main.async { Offer.dismiss("esc") }; return nil }
            if code == 53, mods == .maskShift, let app = Offer.app { DispatchQueue.main.async { CallWatch.turnOff(app) }; return nil }
            // he types on: the offer steps aside, so a Tab meant for the app never starts a recording; ⇧ right ⌥ still can.
            // ⌘ and ⌃ shortcuts (⌘Tab to the call) leave it
            if mods.subtracting([.maskShift, .maskAlternate]).isEmpty { DispatchQueue.main.async { Offer.dismiss("typed") } }
        }
        if code == 48, mods.isEmpty, !g.visible, Offer.active {                                             // Tab on an offer in the strip
            DispatchQueue.main.async { Offer.accept() }; return nil
        }
        if code == 48, mods.isEmpty, !g.visible, emptyChat {                                                 // Tab in an empty chat box
            emptyChat = false
            DispatchQueue.main.async { self.draftReply() }; return nil
        }
        if g.visible, code == 48, mods.isEmpty || mods == .maskShift, !g.replace.isEmpty {                 // Tab on "→ word": the fix
            DispatchQueue.main.async { Fixer.apply() }; return nil
        }
        if g.visible, code == 48, mods == .maskShift, !g.text.isEmpty, g.action == nil {                       // ⇧Tab: the whole suggestion
            let t = g.text, rev = editRevision; DispatchQueue.main.async { self.accept(t, rev: rev) }; return nil
        }
        // parity round: ⌥1 ⌥2 ⌥3 put that idea in the ghost's place (AltKeys), only on a plain ghost with that many ideas
        if let i = AltKeys.pick(code: Int(code), option: mods.contains(.maskAlternate), control: mods.contains(.maskControl),
                                command: mods.contains(.maskCommand), shift: mods.contains(.maskShift), ghost: g.visible && !g.text.isEmpty,
                                plain: g.action == nil && g.replace.isEmpty && !g.isDraft, on: Drafter.shared.settings.alternatives,
                                count: ideaCount) {
            DispatchQueue.main.async { self.showIdea(i) }; return nil
        }
        // long round: ⌃Tab takes up to the end of the sentence, ⌃⇧Tab shows the next idea; only on a plain ghost
        switch GhostRules.longKey(code: Int(code), control: mods.contains(.maskControl), shift: mods.contains(.maskShift),
                                  option: mods.contains(.maskAlternate), command: mods.contains(.maskCommand),
                                  ghost: g.visible && !g.text.isEmpty, plain: g.action == nil && g.replace.isEmpty && !g.isDraft) {
        case .sentence: let t = GhostRules.sentencePiece(g.text), rev = editRevision; DispatchQueue.main.async { self.accept(t, rev: rev) }; return nil
        case .cycle: DispatchQueue.main.async { self.nextIdea() }; return nil
        case .none: break
        }
        if g.visible, code == 48, mods.isEmpty {                                                            // Tab
            if let a = g.action { DispatchQueue.main.async { self.run(a) }; return nil }
            // a whole next message in an empty box: folded with lines hidden, the first Tab opens it (Argon 14);
            // all of it in sight, Tab puts it all in (he edits it there)
            if g.isDraft, GhostRules.draftTab(expanded: g.expanded, cut: g.cut) == .open {
                DispatchQueue.main.async { g.expand(true); log("next message opened by Tab") }; return nil
            }
            if g.isDraft { let t = g.text; DispatchQueue.main.async { self.accept(t); log("next message taken") }; return nil }
            // word by word (Andrii, 2026-10-19): Tab takes the next word and its space; the rest stays grey
            if !g.text.isEmpty { let t = Keys.nextWord(g.text), rev = editRevision; DispatchQueue.main.async { self.accept(t, rev: rev) }; return nil }
        }
        if g.visible, g.action?["id"] as? String == "person", mods.isEmpty, [123, 124, 125].contains(code) {
            DispatchQueue.main.async { PeopleCards.move(Int(code)) }; return nil
        }
        if g.isDraft, mods.isEmpty, [123, 124, 125, 126].contains(code) {                                  // ← → ↓ ↑ on a next-message card
            DispatchQueue.main.async {
                switch code { case 123: g.flip(-1); case 124: g.flip(1); case 125: g.expand(true); default: g.expand(false) }
            }
            return nil
        }
        if code == 36 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.checkEmpty() } }   // sent: the box is empty again
        else if code != 48 { emptyChat = false; draftSeq += 1; if g.isDraft { DispatchQueue.main.async { Ghost.shared.hide() } } }
        if code == 36, Drafter.shared.settings.learn, !IsSecureEventInputEnabled(), !lastTest {
            // Return: the line he just finished (or the message he sends) goes to the local phrase memory
            let line = lastBefore.components(separatedBy: "\n").last ?? ""
            DispatchQueue.main.async { Snippets.remind(line) }
            // what he wrote, never the page around it, never cut mid-word (app/DraftCaptureRules.swift)
            let sent = DraftCaptureRules.sentLine(start: draftStart, end: lastBefore, keys: draftKeys, inserted: Focus.ownChars - draftOwn, recent: kept, app: lastApp, now: Date().timeIntervalSince1970)
            if sent.split(separator: " ").count >= 3 { Engine.shared.post("/typed", ["text": sent, "app": lastApp, "context": String(ScreenContext.shared.journal(context?.text ?? "").suffix(1500))]) }   // screen context: never picture text to data/
            lastBefore = ""
            if mods.isEmpty { draftOpen = false; draftStart = nil; draftKeys = 0; draftOwn = Focus.ownChars; draftFirstKey = nil; draftLastKey = nil }   // sent: the next message starts here
        }
        if code == 9, mods == .maskCommand { noteDraftInput(0); Focus.wrote(NSPasteboard.general.string(forType: .string)?.count ?? 0); PasteWatch.keyPaste() }   // ⌘V: his paste (soft round: + the paste trail, PasteWatch)
        if code == 53, mods.isEmpty, KeyHooks.escTwice(ghostVisible: g.visible) { return nil }      // Esc twice: ghosts paused here (app/KeyHooks.swift)
        if !mods.subtracting(.maskShift).isEmpty || code == 53 {   // shortcuts and Esc: stay out of the way
            cancel()
            if !mods.subtracting(.maskShift).isEmpty { fieldGen += 1; context = nil }   // ⌘K and the like may open another chat
            return pass
        }
        if code == 51, mods.isEmpty, KeyHooks.tabUndo != nil, KeyHooks.tabBack() { return nil }                  // Backspace right after Tab
        if code == 51, mods.isEmpty, Autocorrect.last != nil, Autocorrect.takeBack() { cancel(); return nil }   // Backspace right after a fix
        if code == 51, mods.isEmpty, Typography.last != nil, Typography.takeBack() { cancel(); return nil }     // ... or a typography swap
        if code == 51, mods.isEmpty, Translate.last != nil, Translate.takeBack() { cancel(); return nil }       // ... or after a translation
        if code == 51, mods.isEmpty, Rework.last != nil, Rework.takeBack() { cancel(); return nil }             // ... or after a rework
        if code == 51, mods.isEmpty, Entities.last != nil, Entities.takeBack() { cancel(); return nil }         // ... or an entity or context block
        // typing into the ghost: keep the rest of it
        var len = 0; var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        let typed = String(utf16CodeUnits: chars, count: len)
        if let u = typed.unicodeScalars.first, u.value >= 0x20, u.value != 0x7F { noteDraftInput(typed.count) }   // his letters (DraftCaptureRules)
        if let l = gaps.key(at: event.timestamp, rev: keyRevision, field: fieldGen, unit: typed.utf16.first, secure: IsSecureEventInputEnabled(), ghost: g.visible) { DispatchQueue.global(qos: .utility).async { log(l) } }   // key gaps, a histogram a minute (app/KeyGapRules.swift)
        if Typography.noteKey(typed, rev: editRevision), typed != " ", Drafter.shared.active { Typography.afterKey(typed, revision: inputRevision, at: Date()) }   // — « » … as he types (app/Typography.swift); space: Snippets.afterSpace
        if typed == " " {
            let revision = inputRevision, field = Focus.focused()
            DispatchQueue.main.async { Snippets.afterSpace(revision: revision, expected: field) }
        }   // ";mail " -> his email
        // typing the same letters as the ghost keeps it as it is (no new suggestion, so nothing jumps); the position is
        // then read back from the real caret
        if g.visible, !typed.isEmpty, g.consume(typed) {
            // the field takes these letters a beat later; until realign() reads it, Tab must not take them off again
            if let s0 = spot { spot = Keys.typed(typed, into: s0) }
            // round five: the next key that leaves the ghost is asked for at once too (it was the slow way)
            if let r = lastRead, r.rev == keyRevision - 1 { lastRead = (Keys.typed(typed, into: r.spot), keyRevision, Date()) }
            stat?.typed += typed.count
            timer?.invalidate()
            if g.visible { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.realign(); self.roll() } } else { schedule() }
            return pass
        }
        let fut = g.visible && mods.subtracting(.maskShift).isEmpty ? futureFor(typed) : nil
        cancel()
        if let fut { showFuture(fut, typed: typed) }
        predict(typed, mods: mods); schedule()
        return pass
    }

    /// Double Shift (2026-10-31): two clean taps of either Shift within 0.45 s, no other key between them.
    private var shiftDown: (at: Date, rev: Int)?
    private var shiftTapEnd: (at: Date, rev: Int)?
    func shiftTap(_ down: Bool) {
        let now = Date()
        if down { shiftDown = (now, inputRevision); return }
        guard let d = shiftDown, inputRevision == d.rev + 1, now.timeIntervalSince(d.at) < 0.3 else { shiftDown = nil; shiftTapEnd = nil; return }
        shiftDown = nil
        if let t = shiftTapEnd, d.rev == t.rev + 1, now.timeIntervalSince(t.at) < 0.45 {
            shiftTapEnd = nil
            DispatchQueue.main.async { if Talk.shared.state == .idle { self.cancel(); Autocorrect.switchLast() } }
        } else { shiftTapEnd = (now, inputRevision) }
    }

    /// Screen context for this field: the cached text when it is the same field, else empty while a fresh read runs
    /// in the background (the next keystroke gets it).
    func contextFor(_ s: Spot, refresh: Bool = true) -> String {
        // >>> screen context (opus/screen, 2026-11-14): a key only notes the time; captures run on their own clock
        // (app/ScreenContext.swift), and the newest picture text kept for this field wins over an older read
        ScreenContext.shared.touch(s)
        if let kept = ScreenContext.shared.kept(s), !contextBusy { return kept }
        // <<< screen context
        let same = context.map { CFEqual($0.el, s.el) } ?? false
        // read again for a new field, or at the start of a new line after 30 s (a new message may have come in);
        // never mid-sentence, where a changed context would make the engine read it all again
        let lineStart = (s.before.components(separatedBy: "\n").last ?? "").count < 3
        if refresh, !contextBusy, !same || (lineStart && Date().timeIntervalSince(context!.at) > 30) {
            contextReads += 1
            let el = s.el, pid = s.app.processIdentifier, rect = s.rect, key = Keys.screenKey(s)
            contextQueue.async {
                let t = Keys.readContext(el, pid: pid, caret: rect)
                DispatchQueue.main.async {
                    self.context = (el, t, Date()); self.contextReads -= 1
                    self.rememberContext(key, t, el: el)
                }
            }
        }
        // a field read just now, else what this screen showed last time while the fresh read runs
        return same ? context!.text : (screens[Keys.screenKey(s)] ?? "")
    }

    /// Both context reads drop grey words from another conversation under an unchanged window title.
    func rememberContext(_ key: String, _ text: String, el: AXUIElement) {
        if let was = screens[key], !was.isEmpty, !text.contains(String(was.suffix(160))), Ghost.shared.visible,
           Ghost.shared.action == nil, spot.map({ CFEqual($0.el, el) }) == true {
            Ghost.shared.hide(); log("context: another conversation under the same title, suggestion dropped")
        }
        remember(key, text)
    }

    /// >>> screen context (opus/screen, 2026-11-14): Accessibility where its text is clean, else the messages on screen
    /// read from a picture (app/ScreenContext.swift: kept per field, used at once, a capture waited for only on a new
    /// field). Background only. <<<
    static func readContext(_ el: AXUIElement, pid: pid_t, caret: CGRect?) -> String {
        ScreenContext.shared.read(el, pid: pid, caret: caret)
    }

    /// The focused field is an empty chat box (Tab then asks for a reply). Set on a click, an app switch, after Return.
    var emptyChat = false
    static let chatApps = ["com.automattic.beeper.desktop", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
                           "com.apple.MobileSMS", "com.hnc.Discord", "com.microsoft.teams2", "org.whispersystems.signal-desktop"]

    /// AI apps: the empty box gets his next instruction to the assistant, not a reply (2026-10-20).
    static let aiApps = ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.perplexity.mac"]
    static let browsers = ["com.google.Chrome", "company.thebrowser.dia", "company.thebrowser.Browser", "com.apple.Safari"]
    static let aiTitle = try! NSRegularExpression(pattern: #"(?i)\b(chatgpt|claude|gemini|perplexity|grok)\b"#)

    /// nil: not a box for a next message; else whether it is an AI assistant's box.
    static func boxKind(_ s: Spot) -> Bool? {
        guard s.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = s.app.bundleIdentifier ?? ""
        if chatApps.contains(id) { return false }
        if aiApps.contains(id) { return true }
        if browsers.contains(id), aiTitle.firstMatch(in: s.title, range: NSRange(s.title.startIndex..., in: s.title)) != nil { return true }
        return nil
    }
    var emptyAI = false
    var draftSeq = 0

    func checkEmpty() {
        guard Drafter.shared.active, let s = Focus.spot(skip: Drafter.shared.settings.skip).0 else { emptyChat = false; return }
        let kind = Keys.boxKind(s)
        emptyChat = kind != nil; emptyAI = kind ?? false
        if emptyChat { scheduleIdle(s, before: s.before, ctx: contextFor(s), mine: seq); autoDraft() }
    }

    /// An empty box: after a short pause his likely next message shows by itself. In an AI app it waits until the
    /// assistant's answer stops changing (read twice, 2.5 s apart), up to a minute. Any key stops it.
    func autoDraft(tries: Int = 0) {
        guard Drafter.shared.settings.nextMessage, Talk.shared.state == .idle else { return }
        draftSeq += 1; let mine = draftSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 0.8 : 2.5)) {
            // the local idle ghost may be up: Claude's draft (nextMessage on) still replaces it, as before step 7
            guard mine == self.draftSeq, !Ghost.shared.visible || self.idleShown, let s = Focus.spot(skip: Drafter.shared.settings.skip).0,
                  let ai = Keys.boxKind(s), !KeyHooks.paused(s) else { return }
            let el = s.el, pid = s.app.processIdentifier, rect = s.rect ?? Focus.fieldStart(s.el)
            self.contextQueue.async {
                let ctx = Keys.readContext(el, pid: pid, caret: rect)
                DispatchQueue.main.async {
                    guard mine == self.draftSeq else { return }
                    if ai, ctx != self.lastDraftContext, tries < 24 {   // the assistant may still be writing
                        self.lastDraftContext = ctx; self.draftSeq -= 1; self.autoDraft(tries: tries + 1); return
                    }
                    self.lastDraftContext = ctx
                    self.draft(ctx, s, ai: ai, auto: true, seq: mine)
                }
            }
        }
    }
    private var lastDraftContext = ""
    private var draftHistory: (el: AXUIElement, opts: [[String: String]])?

    /// Tab in an empty box before anything showed: draft now.
    func draftReply() {
        guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, let ai = Keys.boxKind(s) else { return }
        draftSeq += 1; let mine = draftSeq
        let el = s.el, pid = s.app.processIdentifier, rect = s.rect ?? Focus.fieldStart(s.el)
        Pill.shared.show("✎ Drafting…", seconds: 12)
        contextQueue.async {
            let ctx = Keys.readContext(el, pid: pid, caret: rect)
            DispatchQueue.main.async { self.draft(ctx, s, ai: ai, auto: false, seq: mine) }
        }
    }

    /// His next message for this screen (engine /reply, Claude Haiku; the same screen is answered from the cache),
    /// shown as a card over the empty box; Tab puts it in.
    func draft(_ ctx: String, _ s: Spot, ai: Bool, auto: Bool, seq: Int) {
        let st = Drafter.shared.settings
        Engine.shared.post("/reply", ["context": ctx, "app": s.app.localizedName ?? "", "title": s.title, "ai": ai,
                                      "notes": WritingNotes.forApp(s.app.bundleIdentifier ?? "", global: st.writingNote, perApp: st.appNotes)], timeout: 45) { j in
            if !auto { Pill.shared.hide() }
            var opts = ((j?["options"] as? [[String: Any]]) ?? []).compactMap { o -> [String: String]? in
                guard let t = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                return ["text": t, "label": (o["label"] as? String) ?? ""]
            }
            let text = opts.first?["text"] ?? (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if opts.isEmpty, !text.isEmpty { opts = [["text": text, "label": ""]] }
            guard seq == self.draftSeq, !text.isEmpty, let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, s.el),
                  Keys.boxKind(now) != nil, let r = now.rect ?? Focus.fieldStart(now.el) else {
                if !auto, text.isEmpty { Pill.shared.flash("Could not draft a reply") }
                return
            }
            self.spot = now
            // earlier options for this box stay behind the new ones, so he can flip back to them (at most 9)
            if let prev = self.draftHistory, CFEqual(prev.el, now.el) {
                for o in prev.opts where !opts.contains(where: { $0["text"] == o["text"] }) { opts.append(o) }
            }
            opts = Array(opts.prefix(9))
            self.draftHistory = (now.el, opts)
            Ghost.shared.showDraft(opts, field: Focus.frame(now.el), caret: r)
            log("next message \(ai ? "for the assistant" : "reply") \(auto ? "shown" : "drafted") in \(j?["ms"] as? Int ?? 0) ms\(j?["cached"] != nil ? " (cache)" : "")")
        }
    }

    /// On a click into a field: read what is on screen and put field + context into the engine's cache now.
    /// A text he typed and left without sending (2026-10-21, Andrii: "save my typing history entirely"): when the caret
    /// moves to another field or app, what he had typed there goes to data/drafts.jsonl (local only, same rules as the
    /// sent lines: "Learn from what I send" on, never skipped apps or secure input). Sent lines stay in typed.jsonl.
    /// Since 2026-11-14 (app/DraftCaptureRules.swift): only what he wrote since his first key in the field; past what
    /// his keys, pastes and Drafter's writes explain, an estimate ("est"), never nothing. A draft he goes on with
    /// replaces its row, the same adds nothing.
    func keepDraft() {
        let end = lastBefore, start = draftStart, keys = draftKeys, inserted = Focus.ownChars - draftOwn, now = Date().timeIntervalSince1970
        let first = draftFirstKey, last = draftLastKey
        defer { lastBefore = ""; draftOpen = false; draftStart = nil; draftKeys = 0; draftOwn = Focus.ownChars; draftFirstKey = nil; draftLastKey = nil }
        guard Drafter.shared.settings.learn, !IsSecureEventInputEnabled(), !lastTest else { return }
        let text: String, at: (t0: Double?, t: Double)
        switch DraftCaptureRules.record(start: start, end: end, keys: keys, inserted: inserted, recent: kept, app: lastApp, now: now) {
        case .skip: return
        case .add(let t, let est):
            text = t; at = DraftCaptureRules.stamps(firstKey: first, lastKey: last, now: now)
            History.draft(t, app: lastApp, at: at.t, started: at.t0, est: est)
        case .replace(let t, let was, let est):
            text = t; at = DraftCaptureRules.stamps(firstKey: first, lastKey: last, now: now, continued: kept.first { $0.t == was })
            History.draft(t, app: lastApp, at: at.t, started: at.t0, est: est, replacing: was); kept.removeAll { $0.t == was }
        }
        kept = Array((kept + [.init(text: text, t: at.t, app: lastApp, t0: at.t0)]).suffix(8))
    }
    /// The field's text before the caret at his first key (nil: not read yet), his letters since, Focus.ownChars then,
    /// and the drafts kept this run.
    private var draftOpen = false, draftStart: String?, draftKeys = 0, draftOwn = 0, kept: [DraftCaptureRules.Kept] = []
    private var draftFirstKey: Double?, draftLastKey: Double?   // seconds since 1970, as a row's "t"
    func noteDraftInput(_ n: Int) {
        let now = Date().timeIntervalSince1970
        draftLastKey = now; if draftFirstKey == nil { draftFirstKey = now }
        if !draftOpen {
            draftOpen = true; draftOwn = Focus.ownChars
            draftStart = lastRead.flatMap { $0.rev == keyRevision - 1 ? $0.spot.before : nil }   // read right before this key
        }
        draftKeys += n
    }

    func warmField() {
        keepDraft()
        guard Drafter.shared.active, Engine.shared.ready, Talk.shared.state == .idle,
              let s = Focus.spot(skip: Drafter.shared.settings.skip).0 else { emptyChat = false; return }
        let kind = Keys.boxKind(s)
        emptyChat = kind != nil; emptyAI = kind ?? false
        if emptyChat { scheduleIdle(s, before: s.before, ctx: contextFor(s), mine: seq); autoDraft() }
        lastRead = (s, keyRevision, Date())   // round five: the first key in this field is asked for at once
        let el = s.el, pid = s.app.processIdentifier, rect = s.rect, key = Keys.screenKey(s)
        let warm = { (t: String) in
            // the same clip and notes as the first /complete will carry (requestBody), so the warm prompt is that one
            var b: [String: Any] = ["before": String(s.before.suffix(1500)), "app": s.app.localizedName ?? "", "title": s.title, "context": t]
            for k in ["clip", "notes"] { if let v = self.requestBody(s, before: s.before, ctx: t)[k] { b[k] = v } }
            Engine.shared.post("/prefill", b)
        }
        let known = screens[key]
        if let known { warm(known) }   // a screen seen before: its prompt is (still) warm before the fresh read lands
        contextReads += 1
        contextQueue.async {
            let t = Keys.readContext(el, pid: pid, caret: rect)
            DispatchQueue.main.async {
                self.context = (el, t, Date()); self.contextReads -= 1
                self.rememberContext(key, t, el: el)
                if t != known { warm(t) }
            }
        }
    }

    /// Leading spaces, one word with the punctuation stuck to it, and the space after it when there is one.
    static func nextWord(_ s: String) -> String {
        var out = "", seenWord = false
        for ch in s {
            if ch.isWhitespace {
                if seenWord { if ch == " " { out.append(ch) }; break }
                out.append(ch); continue
            }
            seenWord = true; out.append(ch)
        }
        return out
    }

    /// The spot as it will read once the app has put `t` in at the caret (the rect stays until realign reads it).
    static func typed(_ t: String, into s: Spot) -> Spot {
        let v = s.value as NSString
        let value = s.caret >= 0 && s.caret <= v.length ? v.replacingCharacters(in: NSRange(location: s.caret, length: 0), with: t) : s.value
        return Spot(app: s.app, el: s.el, value: value, caret: s.caret + t.utf16.count, before: s.before + t, title: s.title,
                    rect: s.rect, role: s.role, viaMarkers: s.viaMarkers, lineAfter: s.lineAfter, mid: s.mid)
    }

    /// Put the ghost exactly at the caret again after letters were typed into it.
    func realign() {
        guard Ghost.shared.visible, let s = Focus.spot(skip: Drafter.shared.settings.skip, midLine: Keys.midLine).0, let r = s.rect else { return }
        spot = s
        Ghost.shared.show(Ghost.shared.text, action: Ghost.shared.action, at: r, replace: Ghost.shared.replace, mid: s.mid)
    }

    var chipTimer: Timer?
    var pauseTimer: Timer?
    var shownSeq = 0
    var shownRev: Int?       // keyRevision the grey text on screen was asked at (GhostRules.olderThanShown)

    /// After 0.6 s without a key: is the line a task (event, reminder, draft…)? Asked apart from suggestions, so a chip
    /// read (0.3-1 s) never holds up the next suggestion; any key stops it in the engine too.
    func scheduleChip() {
        chipTimer?.invalidate()
        chipTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            let mine = self.seq
            guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, let r = s.rect,
                  (s.before.components(separatedBy: "\n").last ?? "").split(separator: " ").count >= 3 else { return }
            let before = s.before
            Engine.shared.post("/chip", ["before": String(before.suffix(1500))], timeout: 4) { j in
                guard mine == self.seq, let a = j?["action"] as? [String: Any],
                      let now = Focus.spot(skip: Drafter.shared.settings.skip).0, now.before == before else { return }
                self.spot = now
                Ghost.shared.show("", action: a, at: now.rect ?? r)
                log("chip \(a["id"] as? String ?? "?") \(j?["ms"] as? Int ?? 0)ms")
            }
        }
    }

    func cancel() {
        PeopleCards.clear(); EntityCard.shared.hide()
        endStat()
        timer?.invalidate(); chipTimer?.invalidate(); pauseTimer?.invalidate(); idleTimer?.invalidate(); Proof.cancel(); Facts.cancel(); Translate.cancel(); seq += 1
        ghostAsk = nil; futureList = []; ideaList = []; ideaIndex = 0
        if Ghost.shared.visible { Ghost.shared.hide() }
    }

    var idleTimer: Timer?
    var idleShown = false     // the grey text on screen is an idle ghost (Claude's draft may replace it)

    /// Step 7, the idle ghost: after GhostRules.idleDelay with no key, in a chat or AI box that is empty or ends a
    /// sentence, the local model drafts his next message (one request per rest; any key cancels it). Focus.spot gives
    /// no spot in skipped apps and password fields; secure input is checked again when the timer fires.
    func scheduleIdle(_ s: Spot, before: String, ctx: String, mine: Int) {
        idleTimer?.invalidate()
        let st = Drafter.shared.settings
        guard GhostRules.idleAllowed(on: st.idleGhost, secure: IsSecureEventInputEnabled(), password: false, skipped: false,
                                     chatBox: Keys.boxKind(s) != nil, mid: s.mid, before: before) else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: GhostRules.idleDelay, repeats: false) { _ in
            guard mine == self.seq, Talk.shared.state == .idle, !Ghost.shared.visible, Engine.shared.ready, !IsSecureEventInputEnabled(),
                  let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, s.el), now.before == before,
                  !KeyHooks.paused(now), let r = now.rect ?? Focus.fieldStart(now.el) else { return }
            self.complete(now, before: before, ctx: ctx, mine: mine, rect: r, t0: Date(), idle: true)
        }
    }

    func schedule() {
        timer?.invalidate(); pauseTimer?.invalidate(); idleTimer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { _ in self.ask() }
    }

    func ask() {
        guard Talk.shared.state == .idle else { return }
        seq += 1; let mine = seq
        let tAX = Date()
        let (s, why) = Focus.spot(skip: Drafter.shared.settings.skip, midLine: Keys.midLine)
        if let l = gaps.field(s.map { Entities.kind($0) }, rev: keyRevision) { log(l) }   // nil: skipped app, password, secure input
        let ax = Int(Date().timeIntervalSince(tAX) * 1000)   // the first Accessibility read (logged with "shown", round two)
        if why == "no caret rect", let s0 = s { Caret.note(s0.app, s0.role, ok: false) }
        // no suggestion possible here: one Accessibility reading of the field per app per run says why (data/app.log)
        if why != "ok", !["skipped app", "secure input", "password field", "no app"].contains(why),
           let app = Focus.lastApp, let id = app.bundleIdentifier, !AXProbe.done.contains(id), let el = s?.el ?? Focus.focused() {
            AXProbe.done.insert(id); log("axprobe \(id): quiet because \(why)"); AXProbe.dump(el, id: id)
        }
        if debugLog, why != "ok" { log("quiet \(Focus.lastApp?.bundleIdentifier ?? "?"): \(why)") }
        guard let s, let rect = s.rect, !KeyHooks.paused(s) else { return }   // Esc twice paused this field
        lastRead = (s, keyRevision, Date())
        if s.mid { askMid(s, rect: rect, mine: mine, ax: ax); return }   // mid-line: the plain ghost only
        Entities.wordEnd(s)                                       // a name just typed in an AI app: the quiet mark (app/Entities.swift)
        if let lookup = LookupQuery.parse(s.before), LocalConfig.available("gam") {   // optional integration: off, no chip
            chipTimer?.invalidate(); shownSeq = mine; spot = s
            Ghost.shared.unsure = 0; Ghost.shared.show("", action: lookup.action, at: rect)
            return
        }
        let snippet = Snippets.offer(s.before)
        let typed = SnippetRules.word(s.before).lowercased()
        let exactSnippet = Snippets.all.keys.contains { $0.lowercased() == typed } ? snippet : nil
        // the `;` card for any entity (app/Entities.swift); snippet keys and quick starts keep their prefixes
        if exactSnippet == nil, Snippets.ready, (s.before.components(separatedBy: "\n").last ?? "").contains(";"),
           EntityCard.shared.offer(s, reserved: Set(Snippets.all.keys).union(Presets.all.flatMap { $0.keys })) {
            chipTimer?.invalidate(); shownSeq = mine; spot = s
            return
        }
        if let action = Emoji.offer(s.before) ?? exactSnippet ?? Presets.offer(s.before) ?? PeopleCards.offer(s.before) ?? snippet ?? Clip.offer(s) {
            chipTimer?.invalidate(); shownSeq = mine; spot = s
            Ghost.shared.unsure = 0; Ghost.shared.show("", action: action, at: rect)
            return
        }
        // typo hold: no grey text while the word just typed is a suspected typo; a plain ghost on screen goes
        let held = typoHold(s)
        if held != .none { hidePlainGhost() }
        Snippets.refreshEndings()
        if held == .none, Drafter.shared.settings.learn, let ending = Snippets.endings.suffix(s.before), Keys.letters(ending) >= Keys.minLetters {
            chipTimer?.invalidate(); shownSeq = mine; spot = s
            beginStat(s.app, "ending", ending)
            Ghost.shared.unsure = 0; Ghost.shared.show(ending, action: nil, at: rect)
            return
        }
        guard Engine.shared.ready else { return }
        Caret.note(s.app, s.role, ok: true)
        let before = s.before
        lastBefore = before; lastApp = s.app.localizedName ?? ""; lastTest = s.value.contains("⟦drafter-test⟧")
        if draftOpen, draftStart == nil { draftStart = String(before.dropLast(draftKeys)) }   // no read just before his first key
        let ctx = contextFor(s)
        scheduleIdle(s, before: before, ctx: ctx, mine: mine)   // step 7: a rest after a finished sentence
        guard before.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        let t0 = Date()
        scheduleChip()
        if held == .none { schedulePause(s, before, ctx, mine) }
        if !Translate.schedule(s, context: ctx, seq: mine) { Proof.schedule(s, seq: mine) }
        Facts.schedule(s, context: ctx, seq: mine)
        // held: no ask, except for a word still being typed, whose "→ word" fix comes from the same ask (answer() drops
        // its plain grey text)
        if held != .none, held != .word || !Drafter.shared.settings.fixWord { return }
        // the same text was asked for at the key itself (predict): its answer is on the way, nothing to ask again
        // round five: also once that answer came (it was asked again here, 38 of 90 such asks 13-14 Nov: the same
        // ghost drawn twice, and the newer ask stopped the branches the first answer had started in the gap)
        if let p = predicted, GhostRules.askedAtKey(before: p.before, rev: p.rev, pending: p.pending, now: before, keyRev: keyRevision) { return }
        predicted = nil
        complete(s, before: before, ctx: ctx, mine: mine, rect: rect, t0: t0, ax: ax)
    }

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }

    /// Setting `midLine` (2026-11-15, default off): the ghost paths read a caret mid-line too (Focus.spot).
    static var midLine: Bool { Drafter.shared.settings.midLine }

    /// Mid-line (the caret at a gap with text after it on its line): only the local plain ghost is asked for. No chips,
    /// snippets, endings, lookups, Claude pause, proofread, translate or facts: each of those reads the line as ending
    /// at the caret. The read stands for the field as before (lastBefore and the draft start are left as they were, so
    /// a line sent with Return is never cut at the caret).
    private func askMid(_ s: Spot, rect: CGRect, mine: Int, ax: Int) {
        chipTimer?.invalidate(); pauseTimer?.invalidate()
        guard Engine.shared.ready else { return }
        lastTest = lastTest || s.value.contains("⟦drafter-test⟧")
        let held = typoHold(s)
        if held != .none { hidePlainGhost(); return }
        guard s.before.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        if let p = predicted, GhostRules.askedAtKey(before: p.before, rev: p.rev, pending: p.pending, now: s.before, keyRev: keyRevision) { return }
        predicted = nil
        complete(s, before: s.before, ctx: contextFor(s), mine: mine, rect: rect, t0: Date(), ax: ax)
    }

    /// Typo hold (15 November 2026, Cotypist Pro): where the caret sits relative to a suspected typo (TypoHold) in
    /// `before` (default: the field as read). The typo check is the app's own: his words, names, words he took a fix
    /// back on and words either Mac dictionary knows are never typos; a whole word is one when the ranked fix has a
    /// candidate for it, a word still being typed when no word starts with its letters. Ukrainian words only with
    /// `autocorrectUk`, as the fix. One "ghost hold typo len=N at=…" line per hold, never the word.
    func typoHold(_ s: Spot, before given: String? = nil) -> TypoHold.At {
        let st = Drafter.shared.settings
        let before = Keys.norm(given ?? s.before), id = s.app.bundleIdentifier ?? ""
        guard st.typoHold, !TypoRules.codeApps.contains(id), !TypoRules.inCode(before) else { holdLogged = nil; return .none }
        let line = before.components(separatedBy: "\n").last ?? ""
        let held: (at: TypoHold.At, len: Int)
        if let m = holdMemo, m.line == line { held = (m.at, m.len) } else {
            var kind: String?
            held = TypoHold.at(line) { core, prev, complete in
                let uk = TypoRules.isUkrainian(core)
                guard st.autocorrectUk || !uk else { return false }
                return TypoHold.suspect(core, complete: complete,
                    spared: { Autocorrect.spared.contains($0) || (!Fixer.refused.isEmpty && $0.hasPrefix(Fixer.refused)) },
                    known: Autocorrect.known, spell: Spell.known,
                    starts: { Spell.starts($0, uk ? "uk" : "en") || Autocorrect.nameStarts($0) || TypoEngine.hisStart($0) },
                    hasFix: { w in
                        if kind == nil { kind = AppKind.of(id, title: s.title, ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle) }
                        return TypoEngine.hasFix(w, prev: prev, kind: kind ?? "other")
                    })
            }
            holdMemo = (line, held.at, held.len)
        }
        if let k = TypoHold.key(before, held.at) {
            if k != holdLogged { holdLogged = k; log("ghost hold typo len=\(held.len) at=\(held.at.rawValue)") }
        } else { holdLogged = nil }
        return held.at
    }

    /// The typo hold takes a plain grey ghost away; a fix "→ word", a chip or a next-message card stays.
    func hidePlainGhost() {
        let g = Ghost.shared
        guard g.visible, g.action == nil, g.replace.isEmpty, !g.isDraft else { return }
        g.hide(); painted = nil; endStat()
    }

    /// The engine's own split of its time (round three): " t lock 0 switch 0 fed 3 first 14 part 31 prep 1 queue 0 early 0 all 33"
    static func timing(_ j: [String: Any]) -> String {
        guard let t = j["t"] as? [String: Any] else { return "" }
        let keys = ["lock", "switch", "fed", "first", "part", "prep", "queue", "early", "all"]
        return " t" + keys.compactMap { k in (t[k] as? NSNumber).map { " \(k) \(Int($0.doubleValue.rounded()))" } }.joined()
    }

    /// The letter just typed, on top of the last fresh read of the field (lastRead), asked for at once: the engine
    /// works while the app is still putting the letter in, and the answer is shown when the field holds that text.
    /// Only for one plain letter (or Shift + letter, or a space) right after the read, in the same app and field.
    func predict(_ typed: String, mods: CGEventFlags) {
        predicted = nil
        guard Drafter.shared.settings.predictKeys, Talk.shared.state == .idle, Engine.shared.ready, Fields.cur == nil,
              let r = lastRead, GhostRules.predictable(readRev: r.rev, keyRev: keyRevision, age: Date().timeIntervalSince(r.at)),
              mods.subtracting(.maskShift).isEmpty, typed.unicodeScalars.count == 1, let u = typed.unicodeScalars.first,
              u == " " || !(u.properties.generalCategory == .control || u.properties.generalCategory == .privateUse
                            || u.properties.generalCategory == .format || u.properties.isWhitespace),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == r.spot.app.processIdentifier,
              !IsSecureEventInputEnabled(), let rect = r.spot.rect else { return }
        let s = r.spot, before = s.before + typed
        guard before.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        let held = typoHold(s, before: before)
        if held != .none, held != .word || !Drafter.shared.settings.fixWord { return }
        seq += 1; let mine = seq
        predicted = (before, mine, true, keyRevision)
        complete(s, before: before, ctx: contextFor(s, refresh: false), mine: mine, rect: rect, t0: Date(), predicted: true)
    }

    /// One local suggestion for `before` (engine /complete) and what to do with the answer.
    func complete(_ s: Spot, before: String, ctx: String, mine: Int, rect: CGRect, t0: Date, predicted isPrediction: Bool = false, ax: Int? = nil, idle: Bool = false) {
        let keyAt = self.keyAt, rev = self.keyRevision
        let body = idle ? GhostRules.idleBody(requestBody(s, before: before, ctx: ctx)) : requestBody(s, before: before, ctx: ctx)
        let reply = { (j: [String: Any]?, final: Bool) in
            self.answer(j, s, before: before, ctx: ctx, mine: mine, rect: rect, t0: t0, keyAt: keyAt, predicted: isPrediction, tries: 0, ax: ax, final: final, rev: rev)
        }
        // two-step ghost (round two): the first words are drawn as soon as the engine has them, the rest grows in place
        // mid-line: the whole answer at once, so it is trimmed to one line before the rest (GhostRules.midText) once
        if Drafter.shared.settings.streamGhost, !s.mid {
            Engine.shared.stream("/complete", body, each: { reply($0, false) }) { reply($0, true) }
        } else {
            Engine.shared.post("/complete", body) { reply($0, true) }
        }
    }

    /// The /complete body for `before`. The rolling ghost and /futures send the very same fields, so the engine finds
    /// the answers it prepared for them (engine/server.py ahead_key).
    /// The text above this field read last (its chat), for the engine to find who the chat is with; "" when the cached
    /// text belongs to another field. Only the engine reads it (engine/whom.py); proofread and rework do not send it on.
    func screenText(_ el: AXUIElement) -> String {
        guard let c = context, CFEqual(c.el, el) else { return "" }
        return String(c.text.suffix(1500))
    }

    func requestBody(_ s: Spot, before: String, ctx: String) -> [String: Any] {
        // the same 4000 characters as a pause sends, so an early Claude answer (engine, at a word end) matches it later
        var body: [String: Any] = ["before": String(before.suffix(4000)), "app": s.app.localizedName ?? "", "title": s.title,
                                         "context": ctx, "context_fresh": !contextBusy && (context.map { CFEqual($0.el, s.el) } ?? false), "max_tokens": Keys.tokens, "chips": false, "fix": Drafter.shared.settings.fixWord,
                                         "min_letters": Keys.minLetters,
                                         "early": Drafter.shared.settings.claudeTyping && Drafter.shared.settings.claudePause && !IsSecureEventInputEnabled(), "after": Keys.after(s), "field": fieldGen, "kb": KeyLayout.language].merging(Keys.length(s.app.bundleIdentifier ?? "")) { a, _ in a }
        // parity round: the fresh copy and his writing instructions for this app (sent only when there are some, so the
        // prompt and the engine's look-ahead keys stay as before without them)
        if let clip = Clip.forPrompt(before) { body["clip"] = clip }
        if Drafter.shared.settings.keepTyping { body["keep_on"] = true }   // earlier round: an older ask runs on (engine keep_running)
        body.merge(GhostRules.cadenceBody(combo: Drafter.shared.settings.comboModels, gapMs: gaps.lastMs)) { _, b in b }   // cadence round: two models by his typing speed
        let st = Drafter.shared.settings, notes = WritingNotes.forApp(s.app.bundleIdentifier ?? "", global: st.writingNote, perApp: st.appNotes)
        if !notes.isEmpty { body["notes"] = notes }
        // mid-line (setting midLine): the rest of the caret's line first, at most two lines more; the engine fills the
        // gap between `before` and `after_line` (fields it ignores until engine/ learns them; no early Claude here)
        guard s.mid else { return body }
        return body.merging(["mid": true, "after": GhostRules.midAfter(Keys.after(s)), "after_line": s.lineAfter, "early": false]) { _, b in b }
    }

    func answer(_ j: [String: Any]?, _ s: Spot, before: String, ctx: String, mine: Int, rect: CGRect, t0: Date, keyAt: Date,
                predicted isPrediction: Bool, tries: Int, ax: Int? = nil, final: Bool = true, rev: Int? = nil) {
        let settle = { if final, isPrediction, self.predicted?.seq == mine { self.predicted?.pending = false } }
        if final { finishedSeq = max(finishedSeq, mine) }
        // an answer may come back after he typed on: it still counts when he typed exactly its first letters
        // (then the rest shows), and an older answer never replaces a newer one
        guard mine >= self.shownSeq, !GhostRules.lateLine(final: final, mine: mine, finished: finishedSeq), let j else { settle(); return }
        var text = j["part"] as? String ?? j["text"] as? String ?? ""
        let action = j["action"] as? [String: Any]
        // this answer's ghost is up already (an earlier part): only add the words that came since, in place
        if let p = painted, p.seq == mine, self.shownSeq == mine {
            settle()
            // the engine's split of its time comes with the last line only (round three)
            if final, Keys.timing(j) != "" { log("engine \(s.app.bundleIdentifier ?? "?") \(Int(j["ms"] as? Double ?? 0))ms\(Keys.timing(j))") }
            let stillThis = Ghost.shared.visible && !Ghost.shared.text.isEmpty && Ghost.shared.action == nil && p.full.hasSuffix(Ghost.shared.text)
            switch GhostRules.next(raw: p.raw, stillThis: stillThis, text: text, hasAction: action != nil, final: final) {
            case .keep: return
            case .drop: Ghost.shared.hide(); painted = nil; endStat(); return
            case .redraw: Ghost.shared.hide(); painted = nil; endStat()      // drawn again below, as a first line
            case .extend(let more): extendPart(more, text: text, j: j, p: p, mine: mine, s: s, t0: t0, final: final); return
            }
        }
        guard !text.isEmpty || action != nil else { settle(); return }
        if action == nil, GhostRules.olderThanShown(askedRev: rev, shownRev: shownRev, visible: Ghost.shared.visible && Ghost.shared.action == nil && !Ghost.shared.text.isEmpty) { settle(); return }
        let tAX = Date()
        let (now, _) = Focus.spot(skip: Drafter.shared.settings.skip, midLine: Keys.midLine)
        let ax2 = Int(Date().timeIntervalSince(tAX) * 1000)
        guard let now, CFEqual(now.el, s.el), now.app.processIdentifier == s.app.processIdentifier else { settle(); return }
        if isPrediction, !Keys.norm(now.before).hasPrefix(Keys.norm(before)) {
            // a predicted answer can beat the app's own letter into the field: look again shortly, then let it go
            // (the ordinary ask 35 ms after the key asks itself when this one is no longer pending)
            if tries < 4, Keys.norm(before).hasPrefix(Keys.norm(now.before)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                    self.answer(j, s, before: before, ctx: ctx, mine: mine, rect: rect, t0: t0, keyAt: keyAt, predicted: true, tries: tries + 1, ax: ax, final: final, rev: rev)
                }
                return
            }
            settle(); return
        }
        settle()
        guard isPrediction || now.before.hasPrefix(before) else { return }
        // a newer key the app has not put in yet: this answer belongs to the old caret (Argon 11)
        if let rev, GhostRules.fieldBehind(revAsked: rev, revNow: keyRevision, asked: before, now: now.before) { return }
        // the read stands for the key it was asked at, never for a newer one (predict() trusts lastRead's revision)
        if rev == nil || rev == keyRevision { self.lastRead = (now, self.keyRevision, Date()) }
        // mid-line: a plain ghost only (a fix or a chip reads the line as ending at the caret), on the same rest
        if now.mid, action != nil || j["replace"] != nil || !s.mid || now.lineAfter != s.lineAfter { return }
        if let old = j["replace"] as? String {
            // a fix for the word being typed: only at the very spot it was asked for
            let kind = j["kind"] as? String ?? "typo"
            guard Keys.norm(now.before) == Keys.norm(before), Fixer.check(old: old, new: text, kind: kind, at: now) else { return }
            self.shownSeq = mine; self.spot = now
            self.beginStat(now.app, "fix", text)
            Fixer.show(old: old, new: text, kind: kind, at: now, rect: now.rect ?? rect,
                       shownLog: "shown \(now.app.bundleIdentifier ?? "?") \(Int(Date().timeIntervalSince(t0) * 1000))ms fix \(kind)" + (debugLog ? " «\(old)» → «\(text)»" : ""))
            self.shownAt = Date()
            return
        }
        // typo hold: a plain ghost never shows after a suspected typo (an answer asked before it, a future, a fix-only ask)
        if action == nil, typoHold(now) != .none { return }
        let raw = text
        let typedSince = String(now.before.dropFirst(before.count))
        if !typedSince.isEmpty {
            guard action == nil, text.hasPrefix(typedSince), text.count > typedSince.count else {
                // round five: an answer that came after he had typed on past it (bench/live_ghosts.py counts these)
                if final, action == nil, !text.isEmpty {
                    log("late \(now.app.bundleIdentifier ?? "?") \(Int(Date().timeIntervalSince(t0) * 1000))ms typed \(typedSince.count)\(isPrediction ? " predicted" : "")")
                }
                return
            }
            text = String(text.dropFirst(typedSince.count))
        }
        if now.before.last?.isWhitespace == true { text = String(text.drop(while: { $0 == " " })) }   // never two spaces
        if now.mid { text = GhostRules.midText(text, rest: now.lineAfter) }   // one line, never the rest again
        guard !text.isEmpty || action != nil else { return }
        // too short to be worth a Tab (setting minGhost): the engine already tried to make it longer
        if action == nil, Keys.letters(text) < Keys.minLetters { return }
        self.shownSeq = mine
        self.spot = now
        painted = action == nil ? (mine, raw, raw.count - text.count, text) : nil
        let unsure = (j["unsure"] as? String).map { text.hasSuffix($0) ? $0.count : 0 } ?? 0
        Ghost.shared.unsure = unsure
        self.shownRev = action == nil ? rev : nil    // the key this grey text was asked at
        self.idleShown = action == nil && j["idle"] as? Bool == true
        if action == nil { self.beginStat(now.app, j["src"] as? String ?? "model", text) }
        Ghost.shared.show(text, action: action, at: now.rect ?? rect, mid: now.mid)
        self.shownAt = Date()
        if now.mid { log("ghost mid after=\(now.lineAfter.count) len=\(text.count)") }
        // long round: what this ghost was asked with, for the rolling ghost, its futures and ⌃⇧Tab's other ideas
        ghostAsk = action == nil && typedSince.isEmpty && !now.mid ? (body: requestBody(s, before: before, ctx: ctx), before: before, ctx: ctx) : nil
        futureList = []; ideaList = []; ideaIndex = 0; rollAsked = nil
        if final { fetchFutures() }
        if action == nil, let t = tabAt { tabAt = nil; if Date().timeIntervalSince(t) < 3 { log("tabnext \(now.app.bundleIdentifier ?? "?") \(Int(Date().timeIntervalSince(t) * 1000))ms\(j["ahead"] as? Bool == true ? " ahead" : "")") } }
        Stats.add(ms: Date().timeIntervalSince(t0) * 1000, engineMs: j["ms"] as? Double ?? 0)
        let src = (j["src"] as? String).map { " " + $0 } ?? ""
        let gp = (j["gate"] as? Double).map { String(format: " %.2f", $0) } ?? ""
        // key: from the key itself to the grey text (the ms before it starts at the request; 2026-11-13)
        let key = Date().timeIntervalSince(keyAt) < 5 ? " key \(Int(Date().timeIntervalSince(keyAt) * 1000))ms" : ""
        // round two: "part" = the first words of a two-step answer; ax = the read before the ask (none for a predicted
        // ask), ax2 = the read of the field before drawing
        log("shown \(now.app.bundleIdentifier ?? "?") \(Int(Date().timeIntervalSince(t0) * 1000))ms engine \(Int(j["ms"] as? Double ?? 0))ms\(src)\(gp)\(ctx.isEmpty ? "" : " ctx")\(isPrediction ? " predicted" : "")\(final ? "" : " part")\(key)\(ax.map { " ax \($0)ms" } ?? "") ax2 \(ax2)ms len \(text.count)\(Keys.timing(j))" + (debugLog ? " «\(text)» \((action?["chip"] as? String) ?? "")" : ""))
    }

    /// More words of a streamed answer at the end of its part on screen, in place.
    private func extendPart(_ more: String, text: String, j: [String: Any], p: (seq: Int, raw: String, drop: Int, full: String),
                            mine: Int, s: Spot, t0: Date, final: Bool) {
        let unsure = (j["unsure"] as? String).map { text.hasSuffix($0) ? $0.count : 0 } ?? 0
        Ghost.shared.extend(more, unsure: unsure)
        painted = (mine, text, p.drop, p.full + more)
        stat?.len = p.full.count + more.count
        if final {
            fetchFutures()
            log("grown \(s.app.bundleIdentifier ?? "?") \(Int(Date().timeIntervalSince(t0) * 1000))ms engine \(Int(j["ms"] as? Double ?? 0))ms len \(p.full.count + more.count) lighter \(unsure)")
        }
    }

    /// Claude on a pause (2026-10-31, Andrii: "wire sonnet into it for quick typing, with actual daily context"): when
    /// no key came for `pauseDelay` after a suggestion was asked, Claude writes the rest of the sentence (engine
    /// `/pause`, engine/claude_type.py). It shows only when he still has not typed and the field is the same: where the
    /// local model said nothing, or as more words after the local ones when it starts with them.
    static let pauseDelay = 0.45

    /// What is already written after the caret (the next lines of a document), so Claude's words fit before it.
    static func after(_ s: Spot) -> String {
        let ns = s.value as NSString
        guard s.caret >= 0, s.caret < ns.length else { return "" }
        return String(ns.substring(from: s.caret).prefix(1000))
    }
    func schedulePause(_ s: Spot, _ before: String, _ ctx: String, _ mine: Int) {
        pauseTimer?.invalidate()
        let st = Drafter.shared.settings
        let line = before.components(separatedBy: "\n").last ?? ""
        guard st.claudeTyping, st.claudePause, line.trimmingCharacters(in: .whitespaces).count >= 6, !IsSecureEventInputEnabled() else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: Keys.pauseDelay, repeats: false) { _ in
            guard mine == self.seq, Ghost.shared.action == nil, Talk.shared.state == .idle else { return }
            let t0 = Date()
            Engine.shared.post("/pause", ["before": String(before.suffix(4000)), "app": s.app.localizedName ?? "", "title": s.title,
                                          "context": ctx, "model": st.claudeModel, "after": Keys.after(s), "field": self.fieldGen, "kb": KeyLayout.language,
                                          "notes": WritingNotes.forApp(s.app.bundleIdentifier ?? "", global: st.writingNote, perApp: st.appNotes)], timeout: 8) { j in
                guard mine == self.seq, var text = j?["text"] as? String, !text.isEmpty, Ghost.shared.action == nil else { return }
                let (now, _) = Focus.spot(skip: Drafter.shared.settings.skip)
                guard let now, let r = now.rect, CFEqual(now.el, s.el), now.app.processIdentifier == s.app.processIdentifier, now.before == before else { return }
                if now.before.last?.isWhitespace == true { text = String(text.drop(while: { $0 == " " })) }
                let shown = Ghost.shared.visible ? Ghost.shared.text : ""
                // a local suggestion stays unless Claude's starts with it (bench: at pause spots the local words were
                // right 47% of the times they showed, Claude's first word 13%); Claude fills where the local model is quiet
                guard text.count > shown.count, shown.isEmpty || text.hasPrefix(shown), Keys.letters(text) >= Keys.minLetters else { return }
                self.shownSeq = mine; self.spot = now
                // Claude's words are a guess (its first word was his on 7-17% of pauses, bench 2026-10-31): drawn lighter
                Ghost.shared.unsure = text.count - shown.count
                self.beginStat(now.app, "claude", text)
                Ghost.shared.show(text, action: nil, at: r)
                self.shownAt = Date()
                // not "shown": Claude's 1-2 s were mixed into the local ghosts' latency in the review (round two)
                log("claude-pause \(now.app.bundleIdentifier ?? "?") \(Int(Date().timeIntervalSince(t0) * 1000 + Keys.pauseDelay * 1000))ms engine \(j?["ms"] as? Int ?? 0)ms claude\(j?["early"] as? Bool == true ? " early" : "")\(shown.isEmpty ? "" : (text.hasPrefix(shown) ? " grew" : " replaced"))" + (debugLog ? " «\(text)»" : ""))
            }
        }
    }

    func accept(_ given: String, rev: Int? = nil) {
        // Tab read its word when the key came; the ghost may have gone or moved on since (a second fast Tab)
        guard GhostRules.tabStillValid(visible: Ghost.shared.visible, shown: Ghost.shared.text, isDraft: Ghost.shared.isDraft, given: given),
              var s = spot else { return }
        var piece = given
        let full = Ghost.shared.text
        let tabRev = keyRevision
        lastTab = Date()
        // word by word, the rest of the ghost moves right at once instead of blinking out for 80 ms (Codex review,
        // 2026-10-31, the iPad feel); the real caret puts it in place a beat later, or it goes if the word did not land
        if given.count >= full.count || !Ghost.shared.consume(given) { Ghost.shared.hide() }
        // read the field again: Chromium apps update it a beat late, so letters typed meanwhile (a space) are taken off
        guard let cur = Focus.spot(skip: Drafter.shared.settings.skip, midLine: Keys.midLine).0, CFEqual(cur.el, s.el),
              cur.app.processIdentifier == s.app.processIdentifier, cur.before.hasPrefix(s.before) else { Ghost.shared.hide(); return }
        do {
            let typedSince = String(cur.before.dropFirst(s.before.count))
            if !typedSince.isEmpty, piece.hasPrefix(typedSince) { piece = String(piece.dropFirst(typedSince.count)) }
            if cur.before.last?.isWhitespace == true { piece = String(piece.drop(while: { $0 == " " })) }
            s = cur
        }
        guard !piece.isEmpty else { Ghost.shared.hide(); return }
        let how = Focus.insert(piece, at: s)
        KeyHooks.tabDone(piece: piece, given: given, full: full, rev: rev, at: s)   // the next Backspace may take it back
        stat?.taken += piece.count
        // the ghost's length when it showed and its source: kept letters per length in the weekly page (bench/kept.py)
        Engine.shared.post("/accept", ["text": piece, "before": String(s.before.suffix(200)), "app": s.app.localizedName ?? "",
                                       "ghost_len": stat?.len ?? full.count, "src": stat?.src ?? ""])
        log("accept \(how) \(s.app.bundleIdentifier ?? "?") \(piece.count) chars")
        // the whole grey text taken: ask for the next words at once, so Tab, Tab, Tab keeps going (Cotypist's flow,
        // Andrii 2026-10-21); it waits for nothing he types
        if given.count >= full.count {
            tabAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { if !Ghost.shared.visible { self.ask() } }
        }
        // after a single word, put the rest where the caret really is (a paste can land late: one more look)
        if given.count < full.count {
            let rest = String(full.dropFirst(given.count))
            func place(_ again: Bool) {
                // he typed or it changed meanwhile; a streamed answer's last words may have grown it (Argon 13)
                guard Ghost.shared.visible, Ghost.shared.action == nil, Ghost.shared.text.hasPrefix(rest) else { return }
                let (now, _) = Focus.spot(skip: Drafter.shared.settings.skip, midLine: Keys.midLine)
                if let now, let r = now.rect, now.before.hasSuffix(piece) {
                    self.spot = now; Ghost.shared.show(Ghost.shared.text, action: nil, at: r, mid: now.mid)   // its lighter tail kept
                    if self.keyRevision == tabRev { self.lastRead = (now, tabRev, Date()) }   // round five: the next key at once
                    self.roll()                                                                    // long round: the sentence keeps coming
                } else if again { DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { place(false) } }
                else { Ghost.shared.hide() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { place(true) }
        }
    }

    // MARK: long round (2026-11-14): the rolling ghost, futures, other ideas

    /// The ask behind the plain ghost on screen (nil for a chip, a fix, an ending or a ghost he had typed into).
    var ghostAsk: (body: [String: Any], before: String, ctx: String)?
    /// Answers the engine prepared for other next letters after this ghost (engine /futures), and ⌃⇧Tab's list.
    var futureList: [(letter: String, text: String, unsure: String)] = []
    var ideaList: [(text: String, unsure: Int)] = [], ideaIndex = 0
    var rollAsked: String?
    var lastTab = Date.distantPast
    /// The whole ghost was taken: the time to the next ghost goes to the log ("tabnext").
    var tabAt: Date?

    /// Futures take the gap after the ghost to work out (a sentence is ~0.5-1 s): read what is ready now, and twice later.
    func fetchFutures(_ then: (() -> Void)? = nil) {
        guard let a = ghostAsk else { return }
        let base = a.before
        func read(_ done: (() -> Void)?) {
            Engine.shared.post("/futures", a.body, timeout: 1) { j in
                guard self.ghostAsk?.before == base, let fs = j?["futures"] as? [[String: Any]] else { done?(); return }
                self.futureList = fs.compactMap { f in
                    guard let l = f["letter"] as? String, let t = f["text"] as? String else { return nil }
                    return (l, t, f["unsure"] as? String ?? "")
                }
                if self.ideaIndex == 0 { self.ideaList = [] }
                self.markIdeas()
                done?()
            }
        }
        if let then { read(then); return }
        read(nil)
        for d in [0.3, 0.9] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { if self.ghostAsk?.before == base { read(nil) } } }
    }

    /// The prepared answer for the letter he just typed over the ghost (GhostRules.future), with the ask's screen text.
    func futureFor(_ typed: String) -> (text: String, unsure: String, spot: Spot, ctx: String)? {
        guard let a = ghostAsk, let s = spot,
              let f = GhostRules.future(base: a.before, before: s.before, typed: typed, futures: futureList) else { return nil }
        return (f.text, f.unsure, s, a.ctx)
    }

    /// Shown at once, no request: drawn as soon as the field holds his letter (the predicted path's wait).
    func showFuture(_ f: (text: String, unsure: String, spot: Spot, ctx: String), typed: String) {
        guard let rect = f.spot.rect else { return }
        seq += 1
        let mine = seq, before = f.spot.before + typed, keyAt = self.keyAt, rev = keyRevision
        let j: [String: Any] = ["text": f.text, "unsure": f.unsure, "src": "future", "ms": 0]
        DispatchQueue.main.async {
            self.answer(j, f.spot, before: before, ctx: f.ctx, mine: mine, rect: rect, t0: keyAt, keyAt: keyAt, predicted: true, tries: 0, final: true, rev: rev)
        }
    }

    /// The rolling ghost: two words or fewer left of a final ghost, the words after it are asked for and added at its
    /// end. The engine prepared that answer when the ghost showed (look-ahead "next"), so it mostly comes at once.
    func roll() {
        let g = Ghost.shared
        guard g.visible, let s = spot, let a = ghostAsk else { return }
        let wanted = s.before + g.text
        guard GhostRules.rollWanted(rest: g.text, mode: Drafter.shared.settings.ghostLength, final: finishedSeq >= shownSeq,
                                    plain: g.action == nil && g.replace.isEmpty && !g.isDraft, wanted: wanted, askedFor: rollAsked) else { return }
        rollAsked = wanted
        let t0 = Date(), tab = lastTab
        Engine.shared.post("/complete", requestBody(s, before: wanted, ctx: a.ctx)) { j in
            guard let j, j["action"] == nil, j["replace"] == nil, var more = j["text"] as? String, !more.isEmpty else { return }
            let g = Ghost.shared
            guard g.visible, g.action == nil, let cur = self.spot, GhostRules.rollFits(asked: wanted, now: cur.before + g.text) else { return }
            if wanted.last?.isWhitespace == true { more = String(more.drop(while: { $0 == " " })) }
            guard !more.isEmpty else { return }
            let unsure = (j["unsure"] as? String).map { more.hasSuffix($0) ? $0.count : 0 } ?? 0
            g.extend(more, unsure: GhostRules.rollUnsure(old: g.unsure, more: more.count, moreUnsure: unsure))
            self.stat?.len += more.count
            let ms = Int(Date().timeIntervalSince(t0) * 1000), sinceTab = Int(Date().timeIntervalSince(tab) * 1000)
            log("rolled \(s.app.bundleIdentifier ?? "?") \(ms)ms\(sinceTab < 3000 ? " tab \(sinceTab)ms" : "")\(j["ahead"] as? Bool == true ? " ahead" : "") len \(more.count)")
        }
    }

    /// How many ideas ⌥1-⌥3 can pick now (the shown ghost and the prepared futures, at most 3); 0 without an ask.
    var ideaCount: Int {
        let g = Ghost.shared
        guard ghostAsk != nil, g.visible else { return 0 }
        return min(3, ideaList.isEmpty ? GhostRules.ideas(shown: g.text, futures: futureList).count : ideaList.count)
    }

    /// Parity round: the quiet "1/3" after the grey words once other ideas are ready (setting `alternatives`).
    func markIdeas() {
        let g = Ghost.shared
        guard g.visible, g.action == nil, g.replace.isEmpty, !g.isDraft, ghostAsk != nil else { return }
        g.hint(AltKeys.hint(index: ideaList.isEmpty ? 0 : ideaIndex, count: ideaCount, on: Drafter.shared.settings.alternatives))
    }

    /// ⌥1 ⌥2 ⌥3: that idea in place of the ghost (0 = the one the engine showed first).
    func showIdea(_ i: Int) {
        let g = Ghost.shared
        guard g.visible, g.action == nil, g.replace.isEmpty, !g.isDraft, let a = ghostAsk, let s = spot,
              Keys.norm(s.before) == Keys.norm(a.before) else { return }
        if ideaList.isEmpty { ideaList = GhostRules.ideas(shown: g.text, futures: futureList); ideaList[0].unsure = g.unsure; ideaIndex = 0 }
        guard i < ideaList.count, i != ideaIndex else { return }
        putIdea(i, s)
    }

    /// ⌃⇧Tab: the next prepared idea for this spot in place of the ghost; none ready yet: read them, then try once more.
    func nextIdea(_ again: Bool = true) {
        let g = Ghost.shared
        guard g.visible, g.action == nil, g.replace.isEmpty, !g.isDraft, let a = ghostAsk, let s = spot,
              Keys.norm(s.before) == Keys.norm(a.before) else { return }
        if ideaList.isEmpty { ideaList = GhostRules.ideas(shown: g.text, futures: futureList); ideaList[0].unsure = g.unsure; ideaIndex = 0 }
        guard let i = GhostRules.cycle(index: ideaIndex, count: ideaList.count) else {
            if again { fetchFutures { self.nextIdea(false) } }
            return
        }
        putIdea(i, s)
    }

    private func putIdea(_ i: Int, _ s: Spot) {
        let g = Ghost.shared
        guard let r = s.rect else { return }
        ideaIndex = i
        let idea = ideaList[i]
        painted = nil; rollAsked = nil
        g.unsure = idea.unsure
        g.show(idea.text, action: nil, at: r)
        markIdeas()
        beginStat(s.app, i == 0 ? "model" : "idea", idea.text)
        log("idea \(s.app.bundleIdentifier ?? "?") \(i + 1) of \(ideaList.count)")
    }

    func run(_ a: [String: Any]) {
        Ghost.shared.hide()
        Actions.run(a)
    }
}

/// Where the caret could and could not be found, per app and field role (data/caret.json).
enum Caret {
    static var table: [String: [String: Int]] = {
        guard let d = try? Data(contentsOf: Home.data.appendingPathComponent("caret.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Int]] else { return [:] }
        return j
    }()
    static var dirty = 0
    static func note(_ app: NSRunningApplication, _ role: String, ok: Bool) {
        let k = "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) \(role)"
        table[k, default: [:]][ok ? "ok" : "fail", default: 0] += 1
        dirty += 1
        if dirty >= 10 {
            dirty = 0
            if let d = try? JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: Home.data.appendingPathComponent("caret.json"))
            }
        }
    }
}

/// Keystroke-to-ghost time as Andrii sees it (after the debounce), written every 20 shows to data/latency.json.
enum Stats {
    static var app: [Double] = [], engine: [Double] = [], n = 0
    static func add(ms: Double, engineMs: Double) {
        app.append(ms); engine.append(engineMs); n += 1
        // the newest 2,000 only (Argon 24: both grew for as long as the app ran, sorted whole every 20 ghosts)
        if app.count > 2400 { app.removeFirst(400); engine.removeFirst(400) }
        guard n % 20 == 0 else { return }
        func p(_ a: [Double], _ q: Double) -> Int { let s = a.sorted(); return Int(s[min(s.count - 1, Int(Double(s.count) * q))]) }
        let j: [String: Any] = ["n": app.count, "request_ms_p50": p(app, 0.5), "request_ms_p90": p(app, 0.9),
                                "engine_ms_p50": p(engine, 0.5), "engine_ms_p90": p(engine, 0.9), "debounce_ms": Int(Keys.shared.debounce * 1000)]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: .prettyPrinted) { try? d.write(to: Home.data.appendingPathComponent("latency.json")) }
    }
}

/// Runs what a chip shows. App-side kinds use EventKit; anything else goes back to the engine's action file.
enum Actions {
    static let store = EKEventStore()

    static func run(_ a: [String: Any]) {
        guard let r = a["run"] as? [String: Any], let kind = r["kind"] as? String else { return }
        switch kind {
        case "lookup.search":
            Command.shared.lookup(r["old"] as? String ?? "", expected: Keys.shared.spot)
        case "replaceSelection":
            Talk.shared.replaceSelection(r["old"] as? String ?? "", with: r["new"] as? String ?? "")
        case "replace":
            Focus.replace(r["old"] as? String ?? "", with: r["new"] as? String ?? "") { ok in
                if !ok { Ghost.shared.flash("Text changed; replacement cancelled") }
                log("voice better text " + (ok ? "paste or AX replacement requested" : "not replaced"))
            }
        case "expand":   // a snippet chip (engine/snippets.py)
            Snippets.expand(old: r["old"] as? String ?? "", new: r["new"] as? String ?? "", key: r["key"] as? String ?? "", expected: Keys.shared.spot)
        case "eventkit.event": event(r)
        case "eventkit.reminder": reminder(r)
        case "open": Presets.open(r, expected: Keys.shared.spot)   // a quick start (app/Presets.swift)
        case "proofread": Proof.apply()                              // the Fix chip (app/Proof.swift)
        case "translate": Translate.apply()                          // the message in the chat's language (app/Translate.swift)
        default:
            Engine.shared.post("/act", ["id": a["id"] ?? "", "fields": a["fields"] ?? [:]], timeout: 15) { j in
                Ghost.shared.flash((j?["done"] as? String) ?? (j?["error"] as? String) ?? "Action failed")
            }
        }
    }

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: String(s.prefix(16)))
    }

    /// Jobs other local tools (Aleph's panel) handed to the engine: run them here and report back.
    /// One request at a time, held by the engine up to 25 s until a job comes (2026-11-14: was one every second);
    /// the 1 s timer only starts the next one. Needs the engine of the same build (server.py reads ?wait).
    private static var polling = false
    static func poll() {
        guard !polling else { return }
        polling = true
        Engine.shared.get("/pending?wait=25", timeout: 30) { j in
            polling = false
            for job in (j?["jobs"] as? [[String: Any]]) ?? [] {
                guard let id = job["job"] as? String, let r = job["run"] as? [String: Any] else { continue }
                let report: (String, Bool) -> Void = { text, ok in
                    Engine.shared.post("/done", ["job": id, "result": ok ? ["done": text] : ["error": text]])
                }
                switch r["kind"] as? String {
                case "eventkit.event": event(r, report)
                case "eventkit.reminder": reminder(r, report)
                case "eventkit.free":
                    freeSlots(r) { slots, err in
                        let result: [String: Any] = slots.map { ["done": "\($0.count) free slots", "slots": $0.map { ["start": $0.start, "end": $0.end, "chip": $0.chip] }] }
                            ?? ["error": err ?? "calendar not readable"]
                        Engine.shared.post("/done", ["job": id, "result": result])
                    }
                default: report("unknown kind", false)
                }
            }
        }
    }

    /// Free time in his own calendars (all of them, busy events only), working hours, weekdays, from 15 min from now,
    /// on quarter hours, spread out: up to `count` (default 3) slots of `minutes`. nil + reason when the calendar
    /// cannot be read; never invented slots.
    static func freeSlots(_ r: [String: Any], _ done: @escaping ([(start: String, end: String, chip: String)]?, String?) -> Void) {
        log("free slots: asked, calendar access \(EKEventStore.authorizationStatus(for: .event).rawValue)")
        store.requestFullAccessToEvents { ok, _ in
            DispatchQueue.main.async {
                guard ok else { log("free slots: no calendar access"); done(nil, "Cannot check the calendar: access needed in System Settings › Privacy › Calendars"); return }
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                let cal = Calendar.current
                let d0 = f.date(from: String((r["from"] as? String ?? "").prefix(10))) ?? Date()
                let d1 = f.date(from: String((r["to"] as? String ?? "").prefix(10))) ?? d0
                let minutes = r["minutes"] as? Int ?? 30, want = r["count"] as? Int ?? 3
                func hm(_ s: Any?, _ def: Int) -> Int { let p = (s as? String ?? "").split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : def }
                let early = hm(r["earliest"], 9 * 60), late = hm(r["latest"], 19 * 60)
                let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d1))!
                let chosen = Meeting.calendars()
                let busy = chosen?.isEmpty == true ? [] : store.events(matching: store.predicateForEvents(withStart: cal.startOfDay(for: d0), end: end, calendars: chosen))
                    .filter { !$0.isAllDay && $0.availability != .free }
                var slots: [Date] = []
                var day = cal.startOfDay(for: d0)
                let now = Date().addingTimeInterval(15 * 60)
                while day < end, slots.count < want {
                    if !cal.isDateInWeekend(day) {
                        var t = max(day.addingTimeInterval(Double(early) * 60), now)
                        let q = cal.component(.minute, from: t) % 15; if q != 0 { t = t.addingTimeInterval(Double(15 - q) * 60) }
                        t = cal.date(bySetting: .second, value: 0, of: t) ?? t
                        let stop = day.addingTimeInterval(Double(late) * 60)
                        while t.addingTimeInterval(Double(minutes) * 60) <= stop, slots.count < want {
                            let e = t.addingTimeInterval(Double(minutes) * 60)
                            if let clash = busy.first(where: { $0.startDate < e && $0.endDate > t }) { t = clash.endDate; continue }
                            slots.append(t); t = e.addingTimeInterval(Double(max(60, minutes)) * 60)
                        }
                    }
                    day = cal.date(byAdding: .day, value: 1, to: day)!
                }
                let show = DateFormatter(); show.locale = Locale(identifier: "uk_UA"); show.dateFormat = "EEE d.MM, HH:mm"
                let tf = DateFormatter(); tf.dateFormat = "HH:mm"
                let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.dateFormat = "yyyy-MM-dd'T'HH:mm"
                let title = r["title"] as? String ?? "Meeting"
                done(slots.map { s in
                    let e = s.addingTimeInterval(Double(minutes) * 60)
                    return (out.string(from: s), out.string(from: e), "\(title) · \(show.string(from: s))–\(tf.string(from: e)) (free)")
                }, nil)
            }
        }
    }

    static func event(_ r: [String: Any], _ report: @escaping (String, Bool) -> Void = { _, _ in }) {
        store.requestFullAccessToEvents { ok, err in
            DispatchQueue.main.async {
                guard ok else { Ghost.shared.flash("Calendar access is off (System Settings › Privacy › Calendars)"); report("calendar access off", false); return }
                guard let start = date(r["start"]) else { Ghost.shared.flash("No time in the chip"); report("no time", false); return }
                let e = EKEvent(eventStore: store)
                e.title = r["title"] as? String ?? "Meeting"
                e.startDate = start
                e.endDate = start.addingTimeInterval(Double(r["minutes"] as? Int ?? 60) * 60)
                e.notes = r["notes"] as? String
                e.calendar = store.defaultCalendarForNewEvents
                do { try store.save(e, span: .thisEvent); Ghost.shared.flash("Event created: \(e.title ?? "")"); log("event saved \(start)"); report("Event created: \(e.title ?? "")", true) }
                catch { Ghost.shared.flash("Failed: \(error.localizedDescription)"); report(error.localizedDescription, false) }
            }
        }
    }

    static func reminder(_ r: [String: Any], _ report: @escaping (String, Bool) -> Void = { _, _ in }) {
        store.requestFullAccessToReminders { ok, _ in
            DispatchQueue.main.async {
                guard ok else { Ghost.shared.flash("Reminders access is off (System Settings › Privacy › Reminders)"); report("reminders access off", false); return }
                let x = EKReminder(eventStore: store)
                x.title = r["title"] as? String ?? "Reminder"
                x.calendar = store.defaultCalendarForNewReminders()
                if let d = date(r["due"]) {
                    x.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                    x.addAlarm(EKAlarm(absoluteDate: d))
                }
                do { try store.save(x, commit: true); Ghost.shared.flash("Reminder: \(x.title ?? "")"); report("Reminder: \(x.title ?? "")", true) }
                catch { Ghost.shared.flash("Failed: \(error.localizedDescription)"); report(error.localizedDescription, false) }
            }
        }
    }
}
