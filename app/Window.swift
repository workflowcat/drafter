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
    private var keyMonitor: Any?
    let model = WindowModel()

    func show() {
        if window == nil {
            // no toolbar: the field is the first thing in the window; the title bar is transparent over the content
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Drafter"; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true; w.isReleasedWhenClosed = false
            w.backgroundColor = PK.paper; w.titlebarSeparatorStyle = .none
            w.minSize = NSSize(width: JournalLayout.minWindow.w, height: JournalLayout.minWindow.h)
            w.contentViewController = NSHostingController(rootView: WindowView().environmentObject(model))
            w.center(); w.setFrameAutosaveName("DrafterWindow"); w.delegate = self
            // the frame kept per screen (soft round): a screen of another size gets its own
            if let v = w.screen?.visibleFrame, let f = UserDefaults.standard.string(forKey: "window.frame." + JournalLayout.screenKey(v)) {
                w.setFrame(JournalLayout.restore(NSRectFromString(f), visible: v), display: false)
            }
            window = w
            model.loadPrefs()
            // the journal's keys (TapeNav.route): before the field or the editor sees them
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                return self.model.key(e) ? nil : e
            }
        }
        // the app he came from: Insert puts the text there
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { model.origin = front }
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
        // the window as it was drawn on this pass (the rows it had; fresh ones follow from reload)
        let t0 = Date()
        model.openedAt = t0; model.firstAnswer = nil
        DispatchQueue.main.async { log("window: first draw \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(self.model.rows.count) rows") }
    }

    func toggle() { (window?.isVisible ?? false) && NSApp.isActive ? window?.performClose(nil) : show() }

    func windowDidEndLiveResize(_ n: Notification) { keepFrame() }
    func windowDidMove(_ n: Notification) { keepFrame() }
    private func keepFrame() {
        guard let w = window, let v = w.screen?.visibleFrame else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "window.frame." + JournalLayout.screenKey(v))
    }

    func windowWillClose(_ n: Notification) {
        model.player?.stop(); model.stopPlaying(); tick?.invalidate(); tick = nil
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

final class WindowModel: ObservableObject {
    /// Where the window is: the tape, or a page over it (Esc goes back).
    enum Page { case tape, doc, names, shortcuts, settings, help }
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
    @Published var query = "" { didSet { if query != oldValue { open = nil; refilter() } } }
    // the journal (TapeWindow.swift, JournalModel.swift, JournalPanes.swift)
    @Published var rows: [TapeItem] = []          // every item, built (newest first)
    @Published var lines: [JLine] = []            // the outline as shown: only what is unfolded
    @Published var chosen: String?                // the chosen line (an item, a header, a session)
    @Published var open: String?                  // the item open in place (the reader closed)
    @Published var picked: [String] = []          // items picked with ⇧↑ ⇧↓ (Combine)
    @Published var commandMode = false
    @Published var dayTitle = ""
    @Published var daySub = ""
    @Published var chunkInView = ""
    @Published var tapeTick = 0                   // a redraw without new items (a pin, playback)
    @Published var buildTick = 0
    @Published var filter: TapeRules.Filter = .all
    @Published var group: TapeRules.Group = .time
    @Published var side: [TapeRules.Entry] = []
    @Published var folded: Set<String> = []       // sidebar groups folded away
    @Published var sidebarShown = true
    @Published var sidebarWidth: CGFloat = 210
    @Published var readerPref: Bool?              // nil: open when the window is 900 pt or wider
    @Published var readerWidth: CGFloat = 400
    @Published var width: CGFloat = 1040
    @Published var nav = TapeNav.State()
    @Published var results = 0
    @Published var editing: String?               // the item in the editor; "new": a Combine draft
    @Published var draft = ""
    @Published var showOriginal = false
    // soft round: the gallery, the peek, Go to, the slide-over reader, back and forward, the pinned order
    @Published var peekOn = false
    @Published var palette: String?               // Go to (⌘T) is open with this text
    @Published var paletteIndex = 0
    @Published var overOpen = false               // the reader as a slide-over (narrow window, or the gallery)
    @Published var galleryReader: Bool?           // the gallery's docked reader (nil: closed, his choice kept)
    @Published var pinOrder: [String] = []        // the pinned items in his order (display only)
    @Published var detailsOpen = false            // the reader's Details disclosure (⌘I)
    /// Wire round: the reader's focus on a thing found in the chosen text (⌥↓ ⌥↑), its actions list (↵), for which
    /// item; the things found in the text the reader shows (app/JournalFound.swift).
    @Published var foundFocus = FoundFocus()
    var foundFocusId: String?
    var foundCache: (id: String, sig: Int, found: [Found])?
    var history = JournalLayout.History()
    var historyMuted = false
    var placeFilters: [String: TapeRules.Filter] = [:]
    var dragIds: [String] = []
    var previewPastes: [PasteTrail.Paste] = []      // the preview's made-up paste trail                    // items dragged out of the gallery or the list
    var galleryCols = 1
    weak var galleryView: GalleryView?
    var journal = JournalBuild()
    var opens: [String: Bool] = [:]               // headers he folded or unfolded
    lazy var journalStore = JournalStore(url: preview ? nil : Home.data.appendingPathComponent("journal.json"))
    weak var listView: TapeView?
    var origin: NSRunningApplication?             // the app he came from (Insert puts the text there)
    var now = Date().timeIntervalSince1970
    /// The themes Settings offers (read again each time Settings opens).
    @Published var themes: [ThemeSpec] = []
    var tapeSeq = 0
    var gone: (item: TapeItem, until: DispatchWorkItem)?
    @Published var goneIds: Set<String> = []
    var undos: [(name: String, run: () -> Void)] = []
    var firstPaint: Double?
    var previewPins: Set<String> = []
    var previewTagFile: URL?        // the preview's tags on disk (a temporary file)
    var previewDefer = false        // the preview measures the real path: tags after the first paint
    var fillMs = 0.0                // how long the last fill of missing tags took
    var outline: (tree: [TimeChunks.Node], vis: [Bool]) = ([], [])
    var combineSources: [String] = []
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

    // The history files as the window reads them, followed (QuickRead.swift): an open reads only what was appended
    // since the last one. Touched only on `readQueue`.
    private static let readQueue = DispatchQueue(label: "drafter.window-read", qos: .userInitiated)
    private static let follow = (takes: JSONLFollow(History.takesFile, keep: 500), clips: JSONLFollow(History.clipFile, keep: 300),
                                 typed: JSONLFollow(History.typedFile, keep: 600), drafts: JSONLFollow(History.draftsFile, keep: 600))
    private var reloadSeq = 0
    /// Window opened: when (for the first-draw and first-answer lines in the log).
    var openedAt: Date?
    var firstAnswer: (from: Date, query: String)?

    /// The history and the recordings, read off the main thread (speed round, 15 November 2026: every open read the
    /// three files whole and every recording on the main thread); the window shows what it had meanwhile.
    func reload() {
        settings = Drafter.shared.settings
        reloadSeq += 1
        let mine = reloadSeq, t0 = Date()
        Self.readQueue.async {
            let f = Self.follow
            [f.takes, f.clips, f.typed, f.drafts].forEach { $0.refresh() }
            let hidden = DraftHide.load(History.hiddenFile)
            let takes = f.takes.newest(500).compactMap { Entry.voice($0) }
            let clips = f.clips.newest(300).enumerated().compactMap { i, r in Entry.clip(r, id: "c\(i)") }
            // what he typed: one row per message, its drafts folded into it (TypedList); the files stay as they are
            let typed = TypedList.build(sent: DraftHide.drop(f.typed.newest(600), kind: "sent", hidden: hidden),
                                        drafts: DraftHide.drop(f.drafts.newest(600), kind: "draft", hidden: hidden))
            let docs = WindowModel.readDocs()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async {
                guard mine == self.reloadSeq else { return }
                self.takes = takes; self.clips = clips; self.typed = typed
                self.today = ["typed": typed.filter { $0.title.isEmpty && Calendar.current.isDateInToday($0.when) }.count]
                self.loadStats()
                self.applyDocs(docs)
                log("window: reload \(ms) ms off the main thread")
            }
        }
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

    func copy(_ e: Entry) { History.copy(e.text); status = "On the clipboard · \(e.text.count) characters" }

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
        let st = Drafter.shared.change(change); settings = st
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
            VStack(spacing: 0) {
                TopBar(title: pageTitle)
                Group {
                    switch m.page {
                    case .tape:
                        JournalPanesView(width: g.size.width)
                    case .doc:
                        if let d = m.doc { DocView(d: d).id(d.id).padding(.horizontal, 16) } else { Color.clear }
                    case .settings: SettingsView().padding(.horizontal, 20)
                    case .help: HelpView().padding(.horizontal, 20)
                    case .names: NamesView().padding(.horizontal, 20)
                    case .shortcuts: ShortcutsView().padding(.horizontal, 20)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBar()
            }
            .onAppear { m.width = g.size.width }
            .onChange(of: g.size.width) { _, w in m.width = w }
        }
        .overlay(alignment: .topLeading) {
            if titlebar {
                HStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in Circle().fill(UIInk.rule).frame(width: 12, height: 12) } }.padding(.leading, 14).padding(.top, 14)
            }
        }
        .background { WindowKeys() }
        .font(PKFont.text(13)).foregroundStyle(UIInk.ink).tint(UIInk.blue)
        .background(UIInk.paper)
        .id(themeTick)
        .onReceive(NotificationCenter.default.publisher(for: ThemeStore.changed)) { _ in themeTick += 1; m.tapeTick += 1; m.focusField += 1 }
    }
    var pageTitle: String {
        switch m.page { case .doc: return m.doc?.title ?? ""; case .settings: return "Settings"; case .help: return "Help"; case .names: return "Names"; case .shortcuts: return "Shortcuts"; case .tape: return "" }
    }
}

/// The keys of the window that work from anywhere in it, as hidden buttons. The journal's own keys (arrows, Return,
/// Esc, Tab, ⌘C, ⌘P, ⌘⌫, ⌘Z, ⌘\, ⌘G, ⌘1-9) go through WindowModel.key and TapeNav.route (JournalModel.swift).
struct WindowKeys: View {
    @EnvironmentObject var m: WindowModel
    func k(_ key: KeyEquivalent, _ mods: EventModifiers = .command, enabled: Bool = true, _ act: @escaping () -> Void) -> some View {
        Button("", action: act).keyboardShortcut(key, modifiers: mods).disabled(!enabled).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    var body: some View {
        let it = m.current, tape = m.page == .tape
        ZStack {
            k("k") { m.startCommand() }
            k("f") { m.page = .tape; m.commandMode = false; m.nav.region = .search; m.focusField += 1 }
            k("n", [.command, .shift]) { m.show(.names) }; k("j") { m.show(.shortcuts) }; k(",") { m.show(.settings) }; k("/") { m.show(.help) }
            k(.escape, [], enabled: !tape) { m.back() }
            k("l", enabled: (tape && (it?.entry?.audio.isEmpty == false || it?.doc?.hasAudio == true)) || (m.page == .doc && m.doc?.hasAudio == true)) {
                if m.page == .doc, let d = m.doc { m.playing == d.id ? m.stopPlaying() : m.play(d, from: 0) }
                else if let e = it?.entry { m.play(e) }
                else if let d = it?.doc { m.playing == d.id ? m.stopPlaying() : m.play(d, from: 0) }
            }
            k("a", [.command, .shift], enabled: tape && it?.doc?.turns.isEmpty == false) { if let d = it?.doc { m.sendToAgent(d) } }
        }
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

    /// The voice strip's look (setting `stripStyle`, 14 November 2026): two words, the chosen one on the soft lift, as
    /// the light/dark choice beside the theme. It applies from the next take; a strip on screen is put away.
    var stripRow: some View {
        line {
            HStack(spacing: 0) {
                Glyph("waves", size: 16).foregroundStyle(UIInk.muted).frame(width: G.toggle, alignment: .leading)
                Text("Strip").font(PKFont.text(16))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(StripStyle.allCases, id: \.self) { s in
                        let on = m.settings.stripStyle == s.rawValue
                        Button { m.save { $0.stripStyle = s.rawValue } } label: {
                            Text(s.name).font(PKFont.text(13)).foregroundStyle(on ? UIInk.ink : UIInk.muted)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: PK.corner(2)).fill(on ? UIInk.soft : .clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(2).overlay { RoundedRectangle(cornerRadius: PK.corner(2) + 2).strokeBorder(UIInk.line, lineWidth: 1) }
                .accessibilityLabel("Strip style")
                Color.clear.frame(width: G.cloud + 12, height: 1)
            }
        }
    }
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
                    row("No suggestions after a typo", s.typoHold, typing: true) { $0.typoHold = $1 }
                    row("Suggestions in the middle of a line", s.midLine, typing: true) { $0.midLine = $1 }
                    modelRows
                    parityRows
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
                    row("Offer \"Pick parts\" after a long copy", s.pickOffer, typing: true) { $0.pickOffer = $1 }
                    row("Esc twice pauses suggestions in a field", s.escPause, typing: true) { $0.escPause = $1 }
                    row("Fix the wrong keyboard layout", s.layoutFix, stat: LogStats.layout, typing: true) { $0.layoutFix = $1 }
                    row("Typography as you type", s.typography, typing: true) { $0.typography = $1 }
                    row("Read the messages on screen, on this Mac only", s.screenContext, typing: true, value: s.screenContext && !Screen.allowed ? "no access" : nil) { $0.screenContext = $1 }
                }
                group("Voice") {
                    row("Right Option for voice", s.voice, value: m.stats.map { "\($0["takes"]?.shown ?? 0) today" }) { $0.voice = $1 }
                    row("Keep the microphone ready", s.keepMic) { $0.keepMic = $1 }
                    row("Type into the field while I speak", s.voiceInsert == "live") { $0.voiceInsert = $1 ? "live" : "enter" }
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
                    // the key in use: ⌘⇧5 once macOS lets it go (ShotRules.keys), else ⌃⌥S; while macOS holds ⌘⇧5, the one step
                    let inUse = ShotRules.keys(setting: s.captureKey, systemOn: m.preview ? true : Capture.systemKeyOn, cmdShiftS: s.captureCmdShiftS).first
                    row("Quick capture", !s.captureKey.isEmpty, value: inUse) { $0.captureKey = $1 ? ShotRules.defaultKey : "" }
                    // ⌘⇧S is Save As / Duplicate in many apps and the tap takes it from all of them: off gives it back
                    if !s.captureKey.isEmpty {
                        row("⌘⇧S starts the capture (apps lose Save As on it)", s.captureCmdShiftS) { $0.captureCmdShiftS = $1 }
                    }
                    if ShotRules.showSystemStep(setting: s.captureKey, systemOn: m.preview ? true : Capture.systemKeyOn) {
                        Text("For ⌘⇧5: System Settings › Keyboard › Keyboard Shortcuts › Screenshots, untick ⌘⇧5.")
                            .font(PKFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
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
                     keys: [("⇥", "accept one word"), ("⇧⇥", "accept the whole suggestion"), ("⌃⇥", "accept to the end of the sentence"), ("⌃⇧⇥", "show another idea"), ("⌫", "right after ⇥: take it back"), ("esc esc", "pause suggestions in this field for 10 min"), ("keep typing", "adjust or dismiss")])
                part("Names", "Every person, project, company and place you write or say, with its forms, phone, email and how often it comes up. Typing finishes a name after 2-3 letters; voice reads the ones you use most. A fix here counts for both.",
                     keys: [("⇧⌘N", "open"), ("↵", "fix the spelling"), ("⌘M", "merge into another"), ("⌘⌫", "hide"), ("⌘Z", "undo")])
                part("Shortcuts and replacements", "Your email, calendar link and your own replacements work without the model. AU + Space puts in your email; ;cal + Space your calendar link. Edit them in Shortcuts.", keys: [])
                part("Next message", "In an empty chat, a likely reply. In ChatGPT, Claude or Codex, your likely next instruction. Sends the visible conversation to Claude Haiku.",
                     keys: [("← →", "other options"), ("↓", "the whole text"), ("⇥", "insert")])
                part("Voice", "Words show in the strip first. Ukrainian and English, your dictionary, spoken corrections and lists.",
                     keys: [("Right Option", "start / stop"), ("hold Right Option", "push to talk"), ("Return", "Insert, keeps listening: what you said so far goes in, the note goes on"), ("Return after a stop", "insert the draft"), ("Return, nothing said", "goes to the app"), ("Esc", "stop and drop the voice note (it stays in the journal)"), ("⌃⌥R", "insert the last voice note again"), ("Drafter, …", "ask your notes")],
                     stat: m.stats.map { "today: \($0["takes"]?.shown ?? 0) takes" } ?? "")
                part("Calls and long notes", "Audio goes to disk while it records, with screenshots when the screen changes. At the end: a transcript of both sides, a title from your calendar, people, a summary and to-dos. Calls & notes shows them as notes you can search; For agent hands one to Claude or Codex. A call is recorded only when you say so.",
                     keys: [("⇧ Right Option", "start / finish a recording, or record the call that is on"), ("Tab", "record when the strip offers a call"), ("⇧⌘A", "copy a recording for an agent")])
                part("Actions", "Use the field in the title bar or Aleph's ⌘Space bar: book 30 minutes tomorrow, find a free slot, task: …, ;snippet. Haiku handles requests; the model on this Mac is the fallback. Nothing runs until you click.",
                     keys: [("⌘K", "go to the field"), ("⏎", "suggest options"), ("click", "run one")])
                part("The journal", "Everything Drafter kept, newest first, in chunks of time that grow coarser with age: Today and Yesterday by part of the day, this week and last week by day, this month by week, earlier months and years. Under them, sessions: a stretch in one app with gaps under 10 minutes. Kinds: Clips, Drafts, Voice notes, Recordings, Pictures, Links, Files. The sidebar names each place with its count; the reader on the right shows the chosen item in full. Your changes are kept beside the original; Revert brings the original back. Voice audio is kept for 14 days. Password fields and protected clipboard items are never kept.",
                     keys: JournalKeys.all, stat: "drafts today: \(t["typed"] ?? 0)")
                part("Elsewhere", "", keys: [("⌘,", "Settings"), ("⌘J", "Shortcuts"), ("⌃⌥V", "Quick panel"), ("⌘⇧V", "paste switcher; again within 2 s: the older copy instead")])
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
