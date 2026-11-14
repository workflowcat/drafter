// Drafter as a proper app (2026-10-21, Andrii: "make it like a proper app; things are overlapping and confusing"):
// one window, opened from the Dock or the menu. Since the look round "Tape" (14 November 2026) it is one tape: what he
// copied, typed and said, and his calls and long notes, newest first, with the big field on top that searches it and,
// after ⌘K, takes a command (engine /command). Shortcuts, Settings and Help open as pages in the same window, Esc goes
// back. The tape itself is drawn in TapeWindow.swift. The app shows in the Dock and ⌘-Tab only while the window is
// open; closing it leaves Drafter running in the menu bar as before.
import AppKit
import SwiftUI
import AVFoundation
import EventKit

final class AppWindow: NSObject, NSWindowDelegate {
    static let shared = AppWindow()
    private var window: NSWindow?
    private var tick: Timer?
    let model = WindowModel()

    func show() {
        if window == nil {
            // no toolbar: the field is the first thing in the window; the title bar is transparent over the content
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Drafter"; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true; w.isReleasedWhenClosed = false
            w.backgroundColor = PK.paper; w.titlebarSeparatorStyle = .none
            w.minSize = NSSize(width: 760, height: 520)
            w.contentViewController = NSHostingController(rootView: WindowView().environmentObject(model))
            w.center(); w.setFrameAutosaveName("DrafterWindow"); w.delegate = self
            window = w
        }
        model.reload()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.focusField += 1
        // engine state and a recording that is still going are kept fresh while the window is open
        var n = 0
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            // closed: the tick stops (show() starts it again) instead of waking the app every 3 s for good;
            // minimised it waits, as before
            guard let self, let w = self.window, w.isVisible || w.isMiniaturized else { t.invalidate(); self?.tick = nil; return }
            guard w.isVisible else { return }
            self.model.engine = Engine.shared.ready ? "" : Engine.shared.info
            n += 1
            if self.model.docs.contains(where: \.live) || (self.model.page == .doc && n % 3 == 0) || n % 10 == 0 { self.model.loadDocs() }
        }
        model.engine = Engine.shared.ready ? "" : Engine.shared.info
        log("window: opened")
    }

    func toggle() { (window?.isVisible ?? false) && NSApp.isActive ? window?.performClose(nil) : show() }

    func windowWillClose(_ n: Notification) {
        model.player?.stop(); model.stopPlaying(); tick?.invalidate(); tick = nil
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

final class WindowModel: ObservableObject {
    /// Where the window is: the tape, or a page over it (Esc goes back).
    enum Page { case tape, doc, shortcuts, settings, help }
    var preview = false
    @Published var page: Page = .tape
    // calls and long notes as documents (Recordings.swift)
    @Published var docs: [CallDoc] = []
    @Published var doc: CallDoc?
    @Published var playing: String?
    @Published var playhead: Double = 0
    @Published var engine = ""
    @Published var focusField = 0
    var players: [AVAudioPlayer] = []
    var playTimer: Timer?
    @Published var query = "" { didSet { if query != oldValue { open = nil; rebuildTape() } } }
    // the tape (TapeWindow.swift)
    @Published var kinds: Set<TapeKind> = Set(TapeKind.allCases) { didSet { if kinds != oldValue { rebuildTape() } } }
    @Published var rows: [TapeItem] = []
    @Published var chosen: String?
    @Published var open: String?
    @Published var commandMode = false
    @Published var dayTitle = ""
    @Published var tapeTick = 0          // a redraw without new rows (a pin, playback)
    var now = Date().timeIntervalSince1970
    /// The themes Settings offers (read again each time Settings opens).
    @Published var themes: [ThemeSpec] = []
    private var tapeSeq = 0
    private var gone: (item: TapeItem, until: DispatchWorkItem)?
    private var goneIds: Set<String> = []
    @Published var takes: [Entry] = []
    @Published var clips: [Entry] = []
    @Published var typed: [Entry] = []
    @Published var today: [String: Int] = [:]
    /// What each typing feature earned in the last 7 days, and today's voice takes ("takes"), from data/app.log;
    /// nil until the first read is done (off the main thread, `loadStats`).
    @Published var stats: [String: LogStats.Count]?
    /// Side warnings a recording logged while it ran, by recording, for Calls & notes (`loadWarnings`).
    @Published var warnings: [String: [String]] = [:]
    /// Recordings sent to Read again from this window, until their transcript shows.
    @Published var rereading: [String: Date] = [:]
    @Published var settings = Drafter.shared.settings
    /// The status line. It clears itself after a few seconds, unless it says something still running: playback (until
    /// it ends), a line ending in "…", or the command options it sits under (13 November: "Playing · 6 s" stayed for
    /// minutes after the clip ended).
    @Published var status = "" { didSet { if status != oldValue { settleStatus() } } }
    private var statusSeq = 0
    // the line at the top
    @Published var command = "" { didSet { seq += 1; options = []; thinking = false } }
    @Published var options: [[String: Any]] = []
    @Published var thinking = false
    var player: AVAudioPlayer?
    private var seq = 0

    func reload() {
        settings = Drafter.shared.settings
        takes = History.read(History.takesFile, last: 500).compactMap { Entry.voice($0) }
        clips = History.read(History.clipFile, last: 300).enumerated().compactMap { i, r in Entry.clip(r, id: "c\(i)") }
        // what he typed: one row per message, its drafts folded into it (TypedList); the files stay as they are
        typed = TypedList.build(sent: History.read(History.typedFile, last: 600), drafts: History.read(History.draftsFile, last: 600))
        today = ["typed": typed.filter { $0.title.isEmpty && Calendar.current.isDateInToday($0.when) }.count]
        loadStats()
        loadDocs()
    }

    // MARK: numbers from the log, off the main thread

    private static var statsCache: (at: Date, value: [String: LogStats.Count])?
    private static var statsBusy = false
    /// Reads data/app.log on a utility queue at most every 5 minutes; the window shows the last numbers meanwhile.
    func loadStats() {
        guard !preview else { return }
        if let c = Self.statsCache { stats = c.value; if Date().timeIntervalSince(c.at) < 300 { return } }
        guard !Self.statsBusy else { return }
        Self.statsBusy = true
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let lines = WindowModel.logTail()
            let value = LogStats.count(lines, since: LogStats.stamp(now.addingTimeInterval(-7 * 86_400)), today: String(LogStats.stamp(now).prefix(10)))
            DispatchQueue.main.async {
                Self.statsCache = (now, value); Self.statsBusy = false
                self.stats = value
            }
        }
    }

    /// The end of data/app.log as lines (the last 12 MB: more than a week).
    static func logTail() -> [Substring] {
        guard let h = FileHandle(forReadingAtPath: Home.data.appendingPathComponent("app.log").path) else { return [] }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 12_000_000 ? size - 12_000_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self); try? h.close()
        return text.split(separator: "\n")
    }

    /// The side warnings logged while a recording ran, read once per recording off the main thread.
    func loadWarnings(_ d: CallDoc) {
        guard !preview, warnings[d.id] == nil, !d.live else { return }
        warnings[d.id] = []
        let from = LogStats.stamp(d.started), to = LogStats.stamp(d.started.addingTimeInterval(max(d.secs, 60) + 120))
        DispatchQueue.global(qos: .utility).async {
            let w = LogStats.warnings(WindowModel.logTail(), from: from, to: to)
            DispatchQueue.main.async { self.warnings[d.id] = w }
        }
    }

    // MARK: selection and the status line

    // MARK: the tape

    /// Merges and filters the rows off the main thread; the newest result wins. The chosen row stays chosen (by id);
    /// one that left the tape (a search, a filter) hands over to the first row.
    func rebuildTape() {
        tapeSeq += 1
        let mine = tapeSeq
        let (t, c, ty, d, q, k, g) = (takes, clips, typed, docs, query, kinds, goneIds)
        let work = { TapeBuild.rows(takes: t, clips: c, typed: ty, docs: d, query: q, kinds: k, gone: g) }
        func apply(_ r: [TapeItem]) {
            guard mine == tapeSeq else { return }
            rows = r
            if let c = chosen, r.contains(where: { $0.id == c }) {} else { chosen = r.first?.id; open = nil }
            if let o = open, !r.contains(where: { $0.id == o }) { open = nil }
            if let o = open, let it = r.first(where: { $0.id == o }), it.doc != nil { open = nil }
        }
        if preview { apply(work()); return }
        DispatchQueue.global(qos: .userInitiated).async { let r = work(); DispatchQueue.main.async { apply(r) } }
    }

    var current: TapeItem? { chosen.flatMap { c in rows.first { $0.id == c } } }

    func choose(_ id: String) { if chosen != id { open = nil }; chosen = id }

    func move(_ by: Int) {
        guard page == .tape, !commandMode, !rows.isEmpty else { return }
        let i = chosen.flatMap { c in rows.firstIndex { $0.id == c } } ?? -1
        let j = max(0, min(rows.count - 1, i < 0 ? 0 : i + by))
        if rows[j].id != chosen { open = nil; chosen = rows[j].id }
    }

    /// Return: a command runs; on the tape the chosen row opens or closes; a call or a long note opens as a page.
    func enter() {
        if commandMode { plan(); return }
        guard let it = current else { return }
        if let d = it.doc { openDoc(d); return }
        open = open == it.id ? nil : it.id
    }

    /// Esc, step by step: the command, the open row, the search; on a page, back to the tape.
    func escape() {
        if page != .tape { back(); return }
        if commandMode { commandMode = false; command = ""; options = []; return }
        if open != nil { open = nil; return }
        if !query.isEmpty { query = "" }
    }

    func back() { stopPlaying(); page = .tape; focusField += 1 }

    func openDoc(_ d: CallDoc) { doc = d; page = .doc; if d.turns.isEmpty { loadWarnings(d) } }

    func show(_ p: Page) { page = page == p ? .tape : p; if page == .tape { focusField += 1 } }

    /// ⌘1-⌘4: that kind alone; the same key again, all of them.
    func solo(_ k: TapeKind) { kinds = kinds == [k] ? Set(TapeKind.allCases) : [k]; page = .tape }

    func startCommand() { page = .tape; commandMode = true; focusField += 1 }

    func togglePin(_ it: TapeItem) {
        guard let q = it.quick, !it.text.isEmpty else { return }
        let was = Quick.shared.isPinned(q, it.text)
        Quick.shared.togglePin(q, it.text, app: it.app, at: it.at)
        status = was ? "Unpinned" : "Pinned · on top of the Quick panel"
        tapeTick += 1
    }

    /// ⌘⌫: off the tape at once, out of the files when the undo line is gone (8 s, or the next removal).
    func remove(_ it: TapeItem) {
        guard it.quick != nil else { return }
        commitGone()
        let w = DispatchWorkItem { [weak self] in self?.commitGone() }
        gone = (it, w); goneIds.insert(it.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        if let i = rows.firstIndex(where: { $0.id == it.id }) { chosen = rows.indices.contains(i + 1) ? rows[i + 1].id : i > 0 ? rows[i - 1].id : nil }
        open = nil
        status = "Removed from history · ⌘Z brings it back"
        rebuildTape()
    }
    var canUndoRemove: Bool { gone != nil }
    func undoRemove() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil; goneIds.remove(g.item.id)
        chosen = g.item.id; status = "Back"
        rebuildTape()
    }
    private func commitGone() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil
        let it = g.item
        if let q = it.quick, !preview {
            if Quick.shared.isPinned(q, it.text) { Quick.shared.togglePin(q, it.text, app: it.app, at: it.at) }
            History.forget(q, it.entry?.text.isEmpty == false ? it.entry!.text : it.text, drafts: it.entry?.drafts ?? [])
        }
        switch it.kind {
        case .copied: clips.removeAll { "c:\(Int($0.when.timeIntervalSince1970 * 1000)):\($0.text.count)" == it.id }
        case .typed: typed.removeAll { "t:" + $0.id == it.id }
        case .said: takes.removeAll { "v:" + $0.id == it.id }
        case .call: break
        }
        goneIds.remove(it.id)
        if status.hasPrefix("Removed") { status = "" }
        rebuildTape()
        log("window: removed a \(it.kind.name.lowercased()) row")
    }

    private func settleStatus() {
        statusSeq += 1
        let mine = statusSeq
        guard !status.isEmpty, !preview else { return }
        func check() {
            guard mine == statusSeq, !status.isEmpty else { return }
            if status.hasPrefix("▶") {
                if player?.isPlaying == true { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check) } else { status = "" }
                return
            }
            if status.hasSuffix("…") || thinking || !options.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: check); return }
            status = ""
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (status.hasPrefix("▶") ? 0.5 : 5), execute: check)
    }

    func copy(_ e: Entry) { History.copy(e.text); status = "Copied: \(e.text.count) characters" }

    func copyOriginal(_ e: Entry) {
        guard !e.raw.isEmpty else { return }
        History.copy(e.raw); status = "Copied \(e.originalLabel.lowercased()): \(e.raw.count) characters"
    }

    func play(_ e: Entry) {
        player?.stop()
        let url = e.audio.hasSuffix(".wav") ? URL(fileURLWithPath: e.audio) : URL(fileURLWithPath: e.audio).appendingPathComponent("me.wav")
        guard FileManager.default.fileExists(atPath: url.path), let p = try? AVAudioPlayer(contentsOf: url) else { status = "Audio is no longer available (voice clips are kept for 14 days)"; return }
        player = p; p.play(); status = "▶ Playing · \(Int(p.duration)) s"; tapeTick += 1
    }

    func reread(_ e: Entry) {
        guard !preview else { return }
        Spool.reread(URL(fileURLWithPath: e.audio))
        rereading[e.audio] = Date()
        status = "Reading the recording again · a new note follows (the old transcript is kept beside it)"
    }

    func reveal(_ e: Entry) {
        let path = e.audio.isEmpty ? Home.data.path : e.audio
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func save(_ change: (inout Settings) -> Void) {
        var st = Drafter.shared.settings; change(&st)
        Drafter.shared.settings = st; st.save(); settings = st
        MicCapture.keepReady = st.keepMic && st.voice; MicCapture.prepare()
        Drafter.shared.apply(); Menu.shared.refresh()
    }

    // MARK: the line at the top

    func plan() {
        let t = command.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { seq += 1; options = []; thinking = false; return }
        seq += 1; let mine = seq; thinking = true; status = ""; options = []
        Engine.shared.post("/command", ["text": t], timeout: t.hasPrefix(";accounts") ? 60 : 30) { j in
            guard mine == self.seq else { return }
            self.thinking = false
            self.options = (j?["options"] as? [[String: Any]]) ?? []
            self.status = self.options.isEmpty ? "No suggestions. Try rephrasing." : "\((j?["by"] as? String) == "haiku" ? "Haiku" : "on this Mac") · click to run"
            if LookupQuery.parse(t) != nil || (j?["by"] as? String) == "lookup" {
                if j == nil { self.status = "Search service is unavailable. Press Return to retry."; return }
                self.status = (j?["error"] as? String) ?? ((j?["source"] as? String ?? "") + " · " + (self.options.isEmpty ? (j?["status"] as? String ?? "No matches") : "choose a result to copy"))
            }
        }
    }

    func run(_ a: [String: Any]) {
        guard let r = a["run"] as? [String: Any], let kind = r["kind"] as? String else { return }
        let report: (String, Bool) -> Void = { text, ok in DispatchQueue.main.async { self.status = (ok ? "✓ " : "") + text; if ok { self.options = [] } } }
        switch kind {
        case "copy", "insert", "lookup.insert": History.copy(r["text"] as? String ?? ""); report("Copied · ⌘V to paste", true)
        case "snippet.save": Engine.shared.post("/snippet", ["key": r["key"] ?? "", "text": r["text"] ?? ""]) { j in report((j?["done"] as? String) ?? "Not saved", j != nil) }
        case "eventkit.event": Actions.event(r, report)
        case "eventkit.reminder": Actions.reminder(r, report)
        case "eventkit.free":
            Actions.freeSlots(r) { slots, err in
                guard let slots else { report(err ?? "Cannot check the calendar", false); return }
                if slots.isEmpty { report("No free slots", false); return }
                self.options = slots.map { ["chip": $0.chip, "run": ["kind": "eventkit.event", "title": r["title"] as? String ?? "Meeting",
                                                                    "start": $0.start, "minutes": r["minutes"] as? Int ?? 30] as [String: Any]] }
                self.status = "from your calendars · click to book"
            }
        case "none": status = a["chip"] as? String ?? ""
        default:
            status = "Working…"
            Engine.shared.post("/act", ["id": a["id"] ?? "", "fields": a["fields"] ?? [:]], timeout: 30) { j in
                report((j?["done"] as? String) ?? (j?["error"] as? String) ?? "Could not complete this", j?["done"] != nil)
            }
        }
    }
}


struct WindowView: View {
    @EnvironmentObject var m: WindowModel
    var titlebar = false   // the preview draws the window's three dots (a borderless window has none)
    @State private var themeTick = 0   // a new theme: every view is made again with its colours and faces
    var body: some View {
        GeometryReader { g in
            let side: CGFloat = g.size.width >= 900 ? 64 : 32
            VStack(spacing: 0) {
                // the top: the big field (on the tape) or the way back (on a page), the three corner marks
                HStack(spacing: 16) {
                    if m.page == .tape { TapeField() } else { BackRow(title: pageTitle) }
                    HStack(spacing: 2) {
                        CornerMark(glyph: "bookmark", key: "⌘J", label: "Shortcuts", on: m.page == .shortcuts) { m.show(.shortcuts) }
                        CornerMark(glyph: "settings", key: "⌘,", label: "Settings", on: m.page == .settings) { m.show(.settings) }
                        CornerMark(glyph: "help", key: "⌘/", label: "Help", on: m.page == .help) { m.show(.help) }
                    }
                }
                .padding(.horizontal, side).padding(.top, 40).frame(height: m.page == .tape ? 104 : 80, alignment: .bottom)
                Group {
                    switch m.page {
                    case .tape:
                        VStack(spacing: 0) {
                            HStack(alignment: .lastTextBaseline) {
                                Text(m.dayTitle).font(PKFont.display(28)).lineLimit(1)
                                Spacer()
                                KindMarks()
                            }.padding(.top, 28).padding(.bottom, 12).padding(.horizontal, side)
                            Rectangle().fill(UIInk.rule).frame(height: 1).padding(.horizontal, side)
                            TapeList(m: m).padding(.leading, side).padding(.trailing, side - 16).padding(.trailing, 16)
                        }
                        .overlay(alignment: .top) { CommandOptions().padding(.top, 6).padding(.horizontal, side) }
                    case .doc:
                        if let d = m.doc { DocView(d: d).id(d.id).padding(.horizontal, side - 32) } else { Color.clear }
                    case .settings: SettingsView().padding(.horizontal, side - 28)
                    case .help: HelpView().padding(.horizontal, side - 28)
                    case .shortcuts: ShortcutsView().padding(.horizontal, side - 28)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBar().padding(.horizontal, side)
            }
        }
        .overlay(alignment: .topLeading) {
            if titlebar {
                HStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in Circle().fill(UIInk.rule).frame(width: 12, height: 12) } }.padding(.leading, 20).padding(.top, 18)
            }
        }
        .background { WindowKeys() }
        .font(PKFont.text(13)).foregroundStyle(UIInk.ink).tint(UIInk.blue)
        .background(UIInk.paper)
        .id(themeTick)
        .onReceive(NotificationCenter.default.publisher(for: ThemeStore.changed)) { _ in themeTick += 1; m.tapeTick += 1; m.focusField += 1 }
    }
    var pageTitle: String {
        switch m.page { case .doc: return m.doc?.title ?? ""; case .settings: return "Settings"; case .help: return "Help"; case .shortcuts: return "Shortcuts"; case .tape: return "" }
    }
}

/// The keys of the window, as hidden buttons (they work while the field has the caret).
struct WindowKeys: View {
    @EnvironmentObject var m: WindowModel
    func k(_ key: KeyEquivalent, _ mods: EventModifiers = .command, enabled: Bool = true, _ act: @escaping () -> Void) -> some View {
        Button("", action: act).keyboardShortcut(key, modifiers: mods).disabled(!enabled).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    var body: some View {
        let it = m.current, tape = m.page == .tape
        ZStack {
            k("k") { m.startCommand() }
            k("f") { m.page = .tape; m.commandMode = false; m.focusField += 1 }
            k("1") { m.solo(.copied) }; k("2") { m.solo(.typed) }; k("3") { m.solo(.said) }; k("4") { m.solo(.call) }
            k("j") { m.show(.shortcuts) }; k(",") { m.show(.settings) }; k("/") { m.show(.help) }
            k(.escape, [], enabled: !tape) { m.back() }
            // the chosen row's keys (a call's: on its page too)
            k("c", [.command, .shift], enabled: tape && it != nil) {
                if let e = it?.entry { m.copy(e) } else if let d = it?.doc { m.copyNotes(d) }
            }
            k("c", [.command, .option], enabled: tape && it?.entry?.raw.isEmpty == false) { if let e = it?.entry { m.copyOriginal(e) } }
            k("p", enabled: tape && it?.quick != nil) { if let it { m.togglePin(it) } }
            k("l", enabled: (tape && (it?.entry?.audio.isEmpty == false || it?.doc?.hasAudio == true)) || (m.page == .doc && m.doc?.hasAudio == true)) {
                if m.page == .doc, let d = m.doc { m.playing == d.id ? m.stopPlaying() : m.play(d, from: 0) }
                else if let e = it?.entry { m.play(e) }
                else if let d = it?.doc { m.playing == d.id ? m.stopPlaying() : m.play(d, from: 0) }
            }
            k(.delete, enabled: tape && m.open != nil && it?.quick != nil) { if let it { m.remove(it) } }
            k("z", enabled: m.canUndoRemove) { m.undoRemove() }
            k("a", [.command, .shift], enabled: tape && it?.doc?.turns.isEmpty == false) { if let d = it?.doc { m.sendToAgent(d) } }
        }
    }
}

/// The foot: a recording that is going (with Stop), the status line, the engine when it is not ready.
struct StatusBar: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        HStack(spacing: 8) {
            if let live = m.docs.first(where: \.live), !m.preview {
                Button { m.openDoc(live) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(UIInk.coral).frame(width: 7, height: 7)
                        Text("Recording «\(live.title)»").font(PKFont.text(12)).lineLimit(1)
                    }
                }.buttonStyle(.plain).help("Open it; Stop recording is at the top")
                Button("Stop") { m.stopRecording() }.controlSize(.small)
            }
            if m.options.isEmpty { Text(m.status).font(PKFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(1) }   // else it is under the options
            Spacer()
            if !m.engine.isEmpty {
                Circle().fill(m.engine.contains("stop") || m.engine.contains("cannot") ? UIInk.coral : UIInk.faint).frame(width: 6, height: 6)
                Text("Engine: " + m.engine + (m.engine == "starting" || m.engine == "loading model" ? "…" : ""))
                    .font(PKFont.mono(11)).foregroundStyle(UIInk.faint).lineLimit(1)
            }
        }.frame(height: 36)
    }
}

/// What the command line offers, under the field; a click runs one, or its number.
struct CommandOptions: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        if !m.options.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(m.options.enumerated()), id: \.offset) { i, o in
                    Button { m.run(o) } label: {
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(PKFont.mono(12)).foregroundStyle(UIInk.faint)
                            Text(o["chip"] as? String ?? "").font(PKFont.text(15)).lineLimit(1)
                            Spacer()
                        }.padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if i < m.options.count - 1 { Rectangle().fill(UIInk.line).frame(height: 1) }
                }
                HStack {
                    Text(m.status).font(PKFont.mono(11)).foregroundStyle(UIInk.faint)
                    Spacer()
                    Button("Close") { m.options = [] }.buttonStyle(.plain).font(PKFont.text(12)).foregroundStyle(UIInk.muted)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(UIInk.soft)
            }
            .background(UIInk.card).clipShape(RoundedRectangle(cornerRadius: PK.corner(3)))
            .overlay { RoundedRectangle(cornerRadius: PK.corner(3)).strokeBorder(UIInk.line, lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
    }
}

struct KeyChip: View {
    let k: String
    init(_ k: String) { self.k = k }
    var body: some View {
        // the keycap: the key's face over a darker bottom edge, the tape's 6 pt corners
        let r = TapeDraw.keyRadius
        Text(k).font(PKFont.mono(11, .medium)).foregroundStyle(UIInk.muted)
            .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
            .background {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: r).fill(UIInk.keyEdge)
                    RoundedRectangle(cornerRadius: r).fill(UIInk.key).padding(.bottom, 2)
                }
            }
    }
}

/// The switches (⌘,), on the tape's grid: row(), group() and sub() draw them (TapeSettings.swift), so a new row is one
/// line here and takes the look by itself. What each part does and its keys are in Help.
struct SettingsView: View {
    @EnvironmentObject var m: WindowModel

    /// The call apps on this Mac, by name.
    static var callApps: [(id: String, name: String)] {
        CallWatch.apps.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }
    /// Made-up calendars for the preview.
    static let sampleCalendars: [(id: String, title: String, source: String)] = [
        ("c1", "Work", "alex@example.com"), ("c2", "Family", "alex@example.com"),
        ("c3", "Transferred from sam@example.org", "alex@example.com"), ("c4", "Transferred from kim@example.net", "alex@example.com")]
    /// His EventKit calendars, account by account.
    static func calendars() -> [(id: String, title: String, source: String)] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return Actions.store.calendars(for: .event)
            .map { ($0.calendarIdentifier, $0.title, $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    var body: some View {
        let s = m.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(PKFont.display(28)).padding(.bottom, 20)
                look
                ConnectSection(m: m)
                group("Typing", column: "7 days · taken / shown") {
                    row("Suggestions while typing", !s.paused, stat: LogStats.suggest, typing: true) { $0.paused = !$1 }
                    row("Longer suggestions in AI apps", s.longGhostsAI, typing: true) { $0.longGhostsAI = $1 }
                    row("Longer suggestions in chats", s.longGhostsChats, typing: true) { $0.longGhostsChats = $1 }
                    row("Claude finishes the sentence when I pause", s.claudeTyping, sends: true, typing: true) { $0.claudeTyping = $1 }
                    row("Claude writes the rest when I stop", s.claudePause, sends: true, stat: LogStats.claude, typing: true) { $0.claudePause = $1 }
                    row("Proofread the message when I rest", s.proofread, sends: true, stat: LogStats.proofread, typing: true) { $0.proofread = $1 }
                    row("Offer my message in the chat's language", s.translate, sends: true, stat: LogStats.translate, typing: true) { $0.translate = $1 }
                    row("Answer questions from my calendar", s.facts, sends: true, stat: LogStats.facts, typing: true) { $0.facts = $1 }
                    row("Suggest the next message", s.nextMessage, sends: true, stat: LogStats.next, typing: true) { $0.nextMessage = $1 }
                    row("⌥Tab reworks the selected text", s.rework, sends: true, stat: LogStats.rework, typing: true) { $0.rework = $1 }
                    row("Fix typos", s.autocorrect, stat: LogStats.typo, typing: true) { $0.autocorrect = $1 }
                    row("Put typo fixes in by themselves", s.autocorrectMode == "replace", typing: true) { $0.autocorrectMode = $1 ? "replace" : "offer" }
                    row("Fix Ukrainian typos too", s.autocorrectUk, typing: true) { $0.autocorrectUk = $1 }
                    row("Fix the word while I type it", s.fixWord, stat: LogStats.fixWord, typing: true) { $0.fixWord = $1 }
                    row("Backspace takes back the last Tab", s.tabBack, typing: true) { $0.tabBack = $1 }
                    row("Esc twice pauses suggestions in a field", s.escPause, typing: true) { $0.escPause = $1 }
                    row("Fix the wrong keyboard layout", s.layoutFix, stat: LogStats.layout, typing: true) { $0.layoutFix = $1 }
                    row("Read the screen when an app shows no text", s.screen, typing: true) { $0.screen = $1 }
                }
                group("Voice") {
                    row("Right Option for voice", s.voice, value: m.stats.map { "\($0["takes"]?.shown ?? 0) today" }) { $0.voice = $1 }
                    row("Keep the microphone ready", s.keepMic) { $0.keepMic = $1 }
                    row("Insert words while I speak", s.voiceLive) { $0.voiceLive = $1 }
                    row("Paste the last take again", !s.againKey.isEmpty, value: s.againKey.isEmpty ? nil : s.againKey) { $0.againKey = $1 ? "⌃⌥R" : "" }
                }
                group("Calls and long notes") {
                    row("Screenshots while recording", s.shots) { $0.shots = $1 }
                    row("Claude writes the outline and summary", s.callNotes, sends: true) { $0.callNotes = $1 }
                    let apps = SettingsView.callApps
                    if !apps.isEmpty { sub("Offer to record") }
                    ForEach(apps, id: \.id) { a in
                        row(a.name, !s.callOff.contains(a.id)) { st, on in
                            st.callOff.removeAll { $0 == a.id }; if !on { st.callOff.append(a.id) }
                        }
                    }
                }
                group("Calendars") {
                    let groups = CalendarGroups.group(m.preview ? SettingsView.sampleCalendars : SettingsView.calendars())
                    if groups.isEmpty {
                        Text("No calendar access: System Settings › Privacy › Calendars › Drafter.")
                            .font(PKFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                    ForEach(groups, id: \.heading) { g in
                        sub(g.heading)
                        ForEach(g.rows, id: \.id) { c in
                            row(c.name, !s.calendarsOff.contains(c.id)) { st, on in
                                st.calendarsOff.removeAll { $0 == c.id }; if !on { st.calendarsOff.append(c.id) }
                            }
                        }
                    }
                }
                group("History") {
                    row("Keep typed history and learn from it", s.learn) { $0.learn = $1 }
                    // the Quick panel (app/Quick.swift): its global keys in the gutter; off = no key
                    row("Quick panel", !s.quickKey.isEmpty, value: s.quickKey) { $0.quickKey = $1 ? QuickRules.defaultKey : ""; $0.switchKey = $1 ? "⌘⇧V" : "" }
                    // copied pictures kept in data/clips/ (round three): off = only their size, as before
                    // quick capture (app/Capture.swift): its key in the gutter; off = no key
                    row("⌘⇧V again swaps the paste for an older copy", s.switchSwap) { $0.switchSwap = $1 }
                    row("Quick capture", !s.captureKey.isEmpty, value: s.captureKey.isEmpty ? nil : s.captureKey) { $0.captureKey = $1 ? ShotRules.defaultKey : "" }
                    row("Keep copied pictures", s.clipTotalMB > 0, value: s.clipTotalMB > 0 ? "\(s.clipTotalMB) MB" : nil) { $0.clipTotalMB = $1 ? 300 : 0 }
                    line {
                        HStack(spacing: 16) {
                            Button("Data folder") { NSWorkspace.shared.open(Home.data) }
                            Button("Dictionary") { NSWorkspace.shared.open(Home.words) }
                        }.buttonStyle(.plain).font(PKFont.text(15)).foregroundStyle(UIInk.muted)
                    }
                }
            }.padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { m.loadStats(); m.themes = ThemeStore.all() }
    }
}

/// What each part of Drafter does, its keys, and what it did today.
struct HelpView: View {
    @EnvironmentObject var m: WindowModel

    func part(_ title: String, _ what: String, keys: [(String, String)], stat: String = "") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(PKFont.display(15))
                Spacer()
                if !stat.isEmpty { Text(stat).font(PKFont.mono(11)).foregroundStyle(UIInk.muted) }
            }
            Text(what).font(PKFont.text(13)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
            if !keys.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(keys, id: \.0) { k, v in GridRow { KeyChip(k); Text(v).font(PKFont.text(12.5)).foregroundStyle(UIInk.muted) } }
                }.padding(.top, 2)
            }
        }
        .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(UIInk.line).frame(height: 1) }
    }

    var body: some View {
        let t = m.today
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Help").font(PKFont.display(22))
                Text("Drafter helps you write in any app: suggestions, dictation, notes, calls and small actions. History stays on this Mac. Parts that use Claude say so.")
                    .font(PKFont.text(13)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                part("Typing suggestions", "Words and endings from your own writing, then the model on this Mac. Ukrainian and English stay in the language you type. A suggestion never changes a word by itself.",
                     keys: [("⇥", "accept one word"), ("⇧⇥", "accept the whole suggestion"), ("⌫", "right after ⇥: take it back"), ("esc esc", "pause suggestions in this field for 10 min"), ("keep typing", "adjust or dismiss")])
                part("Shortcuts and replacements", "Your email, calendar link and your own replacements work without the model. AU + Space puts in your email; ;cal + Space your calendar link. Edit them in Shortcuts.", keys: [])
                part("Next message", "In an empty chat, a likely reply. In ChatGPT, Claude or Codex, your likely next instruction. Sends the visible conversation to Claude Haiku.",
                     keys: [("← →", "other options"), ("↓", "the whole text"), ("⇥", "insert")])
                part("Voice", "Words show in the strip first. Ukrainian and English, your dictionary, spoken corrections and lists.",
                     keys: [("right ⌥", "start / finish"), ("hold right ⌥", "push to talk"), ("⏎", "insert this piece, keep listening"), ("esc", "cancel a short take"), ("⌃⌥R", "paste the last take again"), ("Drafter, …", "ask your notes")],
                     stat: m.stats.map { "today: \($0["takes"]?.shown ?? 0) takes" } ?? "")
                part("Calls and long notes", "Audio goes to disk while it records, with screenshots when the screen changes. At the end: a transcript of both sides, a title from your calendar, people, a summary and to-dos. Calls & notes shows them as notes you can search; For agent hands one to Claude or Codex. A call is recorded only when you say so.",
                     keys: [("⇧ right ⌥", "start / finish a note, or record the call that is on"), ("⇥", "record when the strip offers a call"), ("⇧⌘A", "copy a recording for an agent")])
                part("Actions", "Use the field in the title bar or Aleph's ⌘Space bar: book 30 minutes tomorrow, find a free slot, task: …, ;snippet. Haiku handles requests; the model on this Mac is the fallback. Nothing runs until you click.",
                     keys: [("⌘K", "go to the field"), ("⏎", "suggest options"), ("click", "run one")])
                part("History", "Voice takes, calls and notes, typed lines and drafts you left, and the clipboard. Voice clips are kept for 14 days. Password fields and protected clipboard items are never kept.",
                     keys: [("⌘1-4", "the lists"), ("⌘F", "search"), ("⌘,", "settings"), ("⌃⌥V", "Quick panel"), ("⌘⇧V", "paste switcher; again within 2 s: the older copy instead")], stat: "typed today: \(t["typed"] ?? 0)")
            }.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One saved value: it saves on ⏎ or when the field is left, and the last change can be undone (no Save button).
/// One phrase he types often: its text, how often, a key to make it a shortcut, and Hide.
struct IdeaRow: View {
    let idea: Snippets.Idea
    let add: (String) -> Void
    let hide: () -> Void
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(idea.text).font(PKFont.text(13)).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 8) {
                Text("\(idea.count) times").font(PKFont.mono(11)).foregroundStyle(UIInk.muted)
                Spacer()
                TextField("Shortcut", text: $key).textFieldStyle(.roundedBorder).frame(width: 110)
                Button("Add") { let k = key.trimmingCharacters(in: .whitespaces); add(k.hasPrefix(";") ? k : ";" + k) }
                    .disabled(key.trimmingCharacters(in: .whitespaces).count < 2 || key.contains(" "))
                Button("Hide", action: hide).buttonStyle(.plain).font(PKFont.text(11)).foregroundStyle(UIInk.muted)
            }
        }.padding(.vertical, 4).onAppear { if key.isEmpty { key = Snippets.keyFor(idea.text) } }
    }
}

struct ShortcutEditor: View {
    let label: String
    let hint: String
    let key: String
    let file: String
    let initial: String
    var preview = false
    @State private var value = ""
    @State private var saved = ""
    @State private var before: String?
    @State private var status = ""
    @FocusState private var focused: Bool
    func save() {
        guard !preview, value != saved else { return }
        do { try Snippets.save(key, value, file: file); before = saved; saved = value; status = "Saved" }
        catch { status = "Could not save: \(error.localizedDescription)" }
    }
    func undo() {
        guard let b = before else { return }
        do { try Snippets.save(key, b, file: file); value = b; saved = b; before = nil; status = "Undone" }
        catch { status = "Could not undo: \(error.localizedDescription)" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label).font(PKFont.text(13, .semibold))
                Spacer()
                if !status.isEmpty { Text(status).font(PKFont.mono(11)).foregroundStyle(UIInk.muted) }
                if before != nil { Button("Undo", action: undo).buttonStyle(.plain).font(PKFont.text(11)).foregroundStyle(UIInk.blue) }
            }
            TextField(label, text: $value).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
                .onChange(of: focused) { _, now in if !now { save() } }
            if !hint.isEmpty { Text(hint).font(PKFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true) }
        }.padding(.vertical, 10)
        .onAppear { value = initial; saved = initial }
    }
}

struct ShortcutsView: View {
    @EnvironmentObject var m: WindowModel
    @State private var rows: [String: String] = [:]
    @State private var snippets: [String: String] = [:]
    @State private var trigger = ""
    @State private var replacement = ""
    @State private var accountStatus = "Not checked this session"
    @State private var checkingAccount = false
    @State private var workspaceAccount = ""
    @State private var status = ""
    @State private var ideas: [Snippets.Idea] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts").font(PKFont.display(22))
                Text("Space expands an exact shortcut. Tab accepts a suggestion. Replacements stay local; searches use your connected account.")
                    .font(PKFont.text(13)).foregroundStyle(UIInk.muted)
                Text("In a shortcut's text: {name} a place to fill (Tab goes to the next) · {day:Mon|Tue} a choice (↑↓) · {name=Ira} with a default · {cursor} · {date+2d} · {time} · {clipboard} · {;other} another shortcut. ;Mail starts with a capital.")
                    .font(PKFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                if !m.preview, !Fields.summary().isEmpty { Text(Fields.summary()).font(PKFont.mono(12)).foregroundStyle(UIInk.muted) }
                ShortcutEditor(label: "Email", hint: "AU + Space or ;mail + Space. Type the first letters of your address, then Tab, to complete it.", key: ";mail", file: "snippets.json", initial: snippets[";mail"] ?? "", preview: m.preview)
                    .id("email-" + (snippets[";mail"] ?? ""))
                ShortcutEditor(label: "Calendar link", hint: ";cal + Space. “My calendar link” or “лінк на календар” offers the link with Tab.", key: ";cal", file: "snippets.json", initial: snippets[";cal"] ?? "", preview: m.preview)
                    .id("calendar-" + (snippets[";cal"] ?? ""))
                if m.preview || LocalConfig.available("gam") {   // the Google lookups are an optional integration
                Divider()
                Text("Search and insert").font(PKFont.display(15)).padding(.top, 8)
                Text("Type a shortcut in your text, then Tab to search. Choose a result with ↑↓ and Return to replace the shortcut. If the field changed, the result is copied instead.")
                    .font(PKFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                Text(";docs project notes · ;links cal · ;meetings tomorrow · ;free 30 tomorrow")
                    .font(PKFont.mono(12)).textSelection(.enabled)
                ShortcutEditor(label: "Google account", hint: "Uses the existing Google connection on this Mac. Drive searches include files shared with you. Meeting and free-time searches use this account's primary calendar only, in Europe/Kyiv. Availability: weekdays, 09:00–18:00.", key: "account", file: "workspace.json", initial: workspaceAccount, preview: m.preview)
                    .id("workspace-" + workspaceAccount)
                VStack(alignment: .leading, spacing: 6) {
                    Button(checkingAccount ? "Checking…" : "Check connection") {
                        checkingAccount = true
                        Engine.shared.post("/lookup", ["kind": "accounts"], timeout: 60) { reply in
                            checkingAccount = false
                            accountStatus = (reply?["error"] as? String) ?? (reply?["status"] as? String) ?? "Search service is unavailable"
                        }
                    }.disabled(checkingAccount || m.preview)
                    Text(accountStatus).font(PKFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                }
                }
                Divider()
                Text("Your replacements").font(PKFont.display(15)).padding(.top, 8)
                Text("Exact, case-sensitive words in Ukrainian or English. Use a rare trigger such as ;дякую. Ordinary word endings remain suggestions; they are never changed automatically. An empty value disables a replacement.")
                    .font(PKFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(rows.keys.sorted(), id: \.self) { key in
                    ShortcutEditor(label: key + " + Space", hint: "", key: key, file: "replacements.json", initial: rows[key] ?? "", preview: m.preview)
                }
                HStack {
                    TextField("Shortcut", text: $trigger).frame(width: 120)
                    TextField("Replace with", text: $replacement)
                    Button("Add") {
                        let key = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }), key != "AU", !LookupQuery.reserved.contains(key), !snippets.keys.contains(key) else { status = "Use one word, without spaces, that is not a built-in shortcut."; return }
                        do {
                            try Snippets.save(key, replacement, file: "replacements.json")
                            rows = Snippets.replacements; trigger = ""; replacement = ""; status = "Saved"
                        } catch { status = "Could not save: \(error.localizedDescription)" }
                    }.disabled(trigger.isEmpty || replacement.isEmpty || m.preview)
                }.textFieldStyle(.roundedBorder).padding(.top, 8)
                Text(status).font(PKFont.text(12)).foregroundStyle(UIInk.muted)
                if !ideas.isEmpty {
                    Divider()
                    Text("Phrases you type often").font(PKFont.display(15)).padding(.top, 8)
                    Text("Sent three or more times. Make one a shortcut, or hide it.").font(PKFont.text(12)).foregroundStyle(UIInk.muted)
                    ForEach(ideas) { idea in
                        IdeaRow(idea: idea) { key in
                            do { try Snippets.save(key, idea.text, file: "snippets.json"); snippets = Snippets.all; status = "Saved \(key)" }
                            catch { status = "Could not save: \(error.localizedDescription)" }
                            ideas.removeAll { $0.id == idea.id }
                        } hide: { Snippets.hideIdea(idea.text); ideas.removeAll { $0.id == idea.id } }
                    }
                }
                ForEach(snippets.keys.filter { ![";mail", ";cal"].contains($0) }.sorted(), id: \.self) { key in
                    ShortcutEditor(label: key + " + Space", hint: "Tab also completes a partial shortcut." + (m.preview || Fields.uses(key) == 0 ? "" : " Used \(Fields.uses(key)) times."), key: key, file: "snippets.json", initial: snippets[key] ?? "", preview: m.preview)
                }
            }.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear {
            snippets = m.preview ? [";mail": "alex@example.com", ";cal": "https://example.com/meet/alex"] : Snippets.all
            rows = m.preview ? [";дякую": "Дякую, отримав."] : Snippets.replacements
            workspaceAccount = m.preview ? "alex@example.com" : Snippets.read("workspace.json")["account"] ?? ""
            if m.preview { ideas = [Snippets.Idea(text: "Thanks, got it. I will look today and come back.", count: 4)] }
            else if Drafter.shared.settings.learn { DispatchQueue.global(qos: .utility).async { let i = Snippets.ideas(); DispatchQueue.main.async { ideas = i } } }
        }
    }
}
