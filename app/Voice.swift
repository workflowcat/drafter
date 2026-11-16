// Voice in Drafter (Voice Notes' job, 2026-10-19): Right Option starts a take, a second press or letting go after a
// hold ends it; the words go into the field at the caret. While talking, the draft shows as grey text at the caret.
// Parakeet reads at once; in a loud room Whisper reads again afterwards and its text is offered as a chip (Tab
// replaces). An empty take with sound gets Whisper's text inserted. Esc while talking drops the take.
import AppKit
import Carbon

/// engine/voice.py, kept running while voice is on. Frames on stdin, JSON lines on stdout (see voice.py).
final class VoiceEngine {
    static let shared = VoiceEngine()
    private var proc: Process?
    private var input: FileHandle?
    var onDraft: ((String) -> Void)?
    var draftMs: Int?                    // what the last draft cost the engine (ms)
    /// One per END frame, answered in the order sent (the engine reads them in order): an Enter piece, then the take's end.
    private var waitText: [(String, Bool) -> Void] = []
    private var waitCareful: ((String) -> Void)?
    private var buffer = Data()
    private var stops: [Date] = []
    private var generation = UUID()
    var loadedAt = Date.distantPast   // when Parakeet last loaded: a take whose press came before it was a cold one
    /// Parakeet is in memory now (false from the start, after an idle unload, after the process stopped): a press then
    /// says "Waking" while the audio waits in the engine's queue.
    private(set) var loaded = false
    /// Audio heard while there is no process to take it (starting, or starting again): kept and sent in order.
    private var wake = WakeBuffer()
    /// END frames still waiting for their text: a draft that comes before those answers belongs to a closed segment.
    var endsWaiting: Int { waitText.count }

    func start() {
        guard proc == nil else { return }
        generation = UUID()
        buffer.removeAll()
        let p = Process()
        p.executableURL = Home.python
        p.arguments = [Home.root.appendingPathComponent("engine/voice.py").path]
        var env = ProcessInfo.processInfo.environment
        env["DRAFTER_WORDS"] = Home.words.path
        env["DRAFTER_VOICE_IDLE"] = String(max(1, Drafter.shared.settings.voiceIdleMin) * 60)
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe
        if let h = appendHandle(Home.data.appendingPathComponent("voice-engine.log")) { p.standardError = h }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak p] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, let p, self.proc === p else { return }
                self.got(d)
            }
        }
        p.terminationHandler = { [weak self] t in
            DispatchQueue.main.async {
                guard let me = self, me.proc === t else { return }
                log("voice engine exited \(t.terminationStatus)")
                me.proc = nil; me.loaded = false
                try? me.input?.close(); me.input = nil
                me.buffer.removeAll()
                me.failPending()
                Talk.shared.engineFailed()
                // load again, but give up after 3 stops in 5 minutes (data/voice-engine.log says why)
                if Drafter.shared.settings.voice {
                    me.stops = me.stops.filter { $0.timeIntervalSinceNow > -300 } + [Date()]
                    let generation = me.generation
                    if me.stops.count <= 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        guard me.generation == generation, Drafter.shared.settings.voice else { return }
                        me.preload()
                    } }
                }
            }
        }
        loaded = false
        do {
            try p.run(); proc = p; input = inPipe.fileHandleForWriting
            for s in wake.flush() { frame(0, s) }
        } catch { log("voice engine did not start: \(error)") }
    }

    func stop() {
        generation = UUID()   // invalidate an already scheduled restart
        let old = proc; proc = nil; loaded = false; wake = WakeBuffer()
        try? input?.close(); input = nil
        buffer.removeAll()
        old?.terminate()
        failPending()
    }

    private func failPending() {
        // Clear all queues before invoking callbacks, which may themselves request a file or a new take.
        let text = waitText, careful = waitCareful, files = waitFile
        waitText = []; waitCareful = nil; waitFile = []
        text.forEach { $0("", false) }
        careful?("")
        files.forEach { $0([]) }
    }

    private func got(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let d = m["draft"] as? String { draftMs = m["ms"] as? Int; onDraft?(d) }
            if let t = m["text"] as? String, !waitText.isEmpty { let w = waitText.removeFirst(); w(t, m["loud"] as? Bool ?? false) }
            if let c = m["careful"] as? String { let w = waitCareful; waitCareful = nil; w?(c) }
            if let l = m["loaded"] { loadedAt = Date(); loaded = true; Talk.shared.engineAwake(); log("voice: loaded \(l) in \(m["s"] ?? "?") s") }
            if let l = m["unloaded"] { loaded = false; log("voice: unloaded \(l) (\(m["why"] ?? "?"))") }
            if m["file"] != nil, !waitFile.isEmpty { waitFile.removeFirst()((m["segments"] as? [[String: Any]]) ?? []) }
        }
    }

    private func frame(_ kind: UInt8, _ samples: [Float] = []) {
        guard let input else { return }
        var n = UInt32(samples.count).littleEndian
        var d = Data([kind]); d.append(Data(bytes: &n, count: 4))
        if !samples.isEmpty { samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
        try? input.write(contentsOf: d)
    }

    func warm() { start(); frame(250) }
    func longTake() { frame(252) }   // drafts every 2 s instead of 3 a second
    private var waitFile: [([[String: Any]]) -> Void] = []
    /// A whole recording read by Whisper as timed segments (frame 247).
    func readFile(_ path: String, names: [String], lang: String? = nil, _ done: @escaping ([[String: Any]]) -> Void) {
        var job: [String: Any] = ["path": path, "names": names.joined(separator: ", ")]
        if let lang { job["lang"] = lang }
        guard let input, let b = try? JSONSerialization.data(withJSONObject: job) else { done([]); return }
        waitFile.append(done)
        var n = UInt32(b.count).littleEndian
        var d = Data([247]); d.append(Data(bytes: &n, count: 4)); d.append(b)
        try? input.write(contentsOf: d)
    }
    /// Names seen on screen for this take (Whisper's prompt).
    func hint(_ names: [String]) {
        guard let input, !names.isEmpty else { return }
        let b = Data(names.joined(separator: ", ").utf8)
        var n = UInt32(b.count).littleEndian
        var d = Data([248]); d.append(Data(bytes: &n, count: 4)); d.append(b)
        try? input.write(contentsOf: d)
    }
    /// Load Parakeet now (app start, voice switched on, after the engine restarted), outside any take.
    func preload() { guard Talk.shared.state == .idle else { return }; start(); frame(250) }
    func feed(_ s: [Float]) { for x in wake.add(s, ready: input != nil) { frame(0, x) } }
    func drop() { wake = WakeBuffer(); frame(254) }
    var running: Bool { proc?.isRunning == true }
    func finish(_ done: @escaping (String, Bool) -> Void) {
        guard running else { done("", false); return }
        waitText.append(done); frame(255)      // never in place of one still waiting (2026-10-19: a piece's text went to the end)
    }
    func careful(_ done: @escaping (String) -> Void) {
        guard running else { done(""); return }
        waitCareful = done; frame(249)
    }
}

/// Where the time goes in a take (logged as "voice timing"): key press -> strip on screen, first microphone sound,
/// first words in the strip; key press that ends it -> text from the engine -> pasted.
struct Clock {
    var press = Date(), strip: Date?, mic: Date?, words: Date?, end: Date?
    var sound: Date?              // first 30 ms of speech level (the engine's own gate: rms over -40 dB)
    var field: Date?              // first words typed into the field (live typing)
    var drafts = 0                // drafts read before the first words
    var readMs: Int?              // what the draft with the first words cost the engine
    func ms(_ d: Date?, from: Date? = nil) -> String { d.map { String(Int($0.timeIntervalSince(from ?? press) * 1000)) } ?? "-" }
}

final class Talk {
    static let shared = Talk()
    var clock = Clock()
    private var micSilent = false
    enum State { case idle, listening, reading }
    private(set) var state = State.idle
    var mic: MicCapture?
    var samples = 0
    var audio: [Float] = []        // the take's sound, kept in History (data/audio, 14 days)
    var screenNames: [String] = [] // dictionary names seen on screen when the take began
    private var lastVoice = Date()         // last time the draft grew: 45 s without new words ends the take
    private var quietTimer: Timer?
    var editing: String?           // text selected when the take began: the take replaces or rewrites it
    var peak: Float = 0
    private var started = Date()
    private var rect: CGRect?
    private var downAt: Date?
    var testing = false
    // Prepared when a draft arrives, never from the event tap's Return check.
    var sendDraft = ""
    private var cleanedDraft = ""
    var lastDraft = "" {
        didSet {
            // Long notes/calls keep their raw transcript; Return never sends it.
            // Do not walk a growing recording through the dictionary every draft.
            guard !long else { cleanedDraft = ""; sendDraft = ""; return }
            cleanedDraft = lastDraft.isEmpty ? "" : Tidy.clean(lastDraft)
            sendDraft = Rules.trailingFillers(cleanedDraft)
        }
    }
    var sending = false
    // round three: Return while he speaks puts in the segment so far (closeSegment); inserts go one at a time, in order
    var segmentsSent = 0
    var insertQueue: [(String, Bool)] = []
    var insertBusy = false
    // the voice note's way to the field (app/VoiceFlowRules.swift, 14 November 2026): enter mode keeps the field
    // untouched while he speaks and ↩ puts the whole final text in; live mode types it in as before
    var flow = VoiceFlow()
    var flowTimer: Timer?
    private var afterPiece: (() -> Void)?  // the take's end, held while an Enter piece is still going into the field
    // live typing (2026-10-19): settled words go into the field while he talks
    var live = false
    /// The take started while the shot strip was open (app/CaptureNote.swift): its text goes into the strip's line,
    /// never into the app (screenshot tool, 15 November 2026).
    private(set) var toNote = false
    var prevWords: [Substring] = []
    /// Enter while talking puts what was said so far into the field on its own line (never sends): only with words heard
    /// Words were heard in this take: Enter then ends it and puts them in (Keys.swift)
    /// Enter puts words in only when they are words: "Yeah." / "Okay." / a quiet "Thank you." heard in the pause after the
    /// last Enter are what the reader makes of room noise, so that Enter goes to the app and sends (2026-10-22: those
    /// swallowed his sending Enter two or three times in a row and the strip cycled through them).
    var canSend: Bool { insertMode == .live && state == .listening && !sending && Double(samples) / 16000 >= 0.4 && Talk.realCleaned(sendDraft, peak: peak) }

    static let noiseWords = try! NSRegularExpression(pattern: #"(?i)^\s*(thank you|thanks|thank you for watching|дякую|спасибі|bye)[.!]?\s*$"#)
    static func real(_ draft: String, peak: Float) -> Bool {
        realCleaned(Rules.trailingFillers(Tidy.clean(draft)), peak: peak)
    }

    static func realCleaned(_ t: String, peak: Float) -> Bool {
        if t.isEmpty { return false }
        if peak < 0.08, noiseWords.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return false }
        return true
    }

    /// Right Option, from the event tap. Returns true when the event was ours.
    /// A long note (Shift + Right Option, as in Voice Notes): runs until pressed again, never pasted; it becomes a note
    /// with a title, links to people and projects in Aleph and its follow-ups (engine/notes.py).
    private(set) var long = false
    private(set) var isCall = false
    var spool: Spool?              // a long note or call, written to disk while it runs
    /// The same recording as seen from the microphone's queue, which writes it (and the call's other side) to disk.
    let tape = Tape()
    var micReopened = false        // a call's microphone that gave only zeros was opened again once
    var warning: String?           // what the recording strip says is not heard (CallHealth)
    var shots: Shots?              // screenshots while a long note or call runs (setting `shots`)
    /// Seconds without new words in this take (a call ends when its app let go of the mic and nobody spoke).
    var quietFor: Double { Date().timeIntervalSince(lastVoice) }
    var recTimer: Timer?, outlineTimer: Timer?
    var recStart = Date(), recTitle = "", recOutline: [String] = []

    func key(down: Bool, long longKey: Bool = false, at: Date = Date()) {
        if down {
            // a press within 0.8 s of a take's end does not start a new one (2026-10-22: 0.5-1 s empty takes right after
            // real ones, up to three in a row, and some ran 16-46 s on room noise; none had speech)
            if state == .idle, VoiceFlowRules.pressIgnored(sinceEnd: at.timeIntervalSince(endedAt), lastHadWords: lastHadWords) {
                log("voice: press right after a take ignored"); return
            }
            if state == .idle {
                clock = Clock(press: at)
                // ⇧ right ⌥ while another app holds the mic for a call: both sides (2026-10-29: 60+ call offers since 21
                // October, two recordings; the offer lasted 15 s and only Tab took it)
                if longKey, CallWatch.startIfCall() { downAt = nil; return }
                begin(long: longKey); downAt = longKey ? nil : Date()
            }
            else if state == .listening { downAt = nil; clock.end = at; end() }
        } else if let d = downAt {
            downAt = nil
            if Date().timeIntervalSince(d) > 0.5 { clock.end = at; end() }     // held: push to talk
        }
    }

    /// Tab on the call offer: a long take with the Mac's own sound beside the microphone.
    func beginCall() {
        let title = CallWatch.event?["title"] as? String
        begin(long: true, call: true)
        guard state == .listening else { return }
        // the other side: it keeps trying when it cannot start, and the strip says so while it is missing (CallHealth)
        let a = SysAudio()
        tape.attach(sys: a)
        a.start { ok in if !ok { log("call: the other side is not recorded yet (call audio did not start)") } }
        log("call: recording" + (title.map { " «\($0)»" } ?? ""))
    }

    func begin(long: Bool = false, call: Bool = false) {
        guard state == .idle else { return }
        self.long = long; isCall = long && call; micReopened = false; warning = nil
        testing = false
        toNote = !long && CaptureNote.shared.isOpen
        var steps: [(String, Date)] = [("", Date())]
        func step(_ n: String) { steps.append((n, Date())) }
        func report() {
            let total = steps.last!.1.timeIntervalSince(steps[0].1)
            if total > 0.08 { log("voice: slow press " + zip(steps.dropFirst(), steps).map { "\($0.0) \(Int($0.1.timeIntervalSince($1.1) * 1000))" }.joined(separator: ", ") + " ms") }
        }
        Keys.shared.cancel()
        samples = 0; peak = 0; started = Date(); audio = []
        sending = false; afterPiece = nil; lastDraft = ""   // a piece lost in an earlier take never blocks Enter here
        rect = nil; editing = nil; screenNames = []; live = false; micSilent = false; keptNote = false; lost = false; timingSaid = false
        VoiceEngine.shared.warm()
        if long { VoiceEngine.shared.longTake() }
        VoiceEngine.shared.onDraft = { [weak self] d in
            guard let self, self.state == .listening else { return }
            // a draft read before a closed segment's text came back is that segment's, not the new one's
            if !self.long, VoiceEngine.shared.endsWaiting > 0 { return }
            if d.count != self.lastDraft.count { self.lastVoice = Date() }
            if self.clock.words == nil {
                self.clock.drafts += 1
                if !d.trimmingCharacters(in: .whitespaces).isEmpty { self.clock.words = Date(); self.clock.readMs = VoiceEngine.shared.draftMs }
            }
            self.lastDraft = d
            self.spool?.text(d)
            if !self.long {   // noise words never show; an armed draft he speaks after shows with the new words
                let real = Talk.realCleaned(self.sendDraft, peak: self.peak)
                Pill.shared.draft(real ? VoiceFlowRules.join(self.flowPrefix, self.cleanedDraft) : self.flowPrefix)
                self.flowEvent(.words(VoiceFlowRules.said(self.cleanedDraft, seconds: Double(self.samples) / 16000, noise: !real)))
            }
            self.liveDraft(d)
        }
        lastVoice = Date()
        quietTimer?.invalidate()
        // a take left open by mistake (2026-10-19: 67 and 88 s of room noise) ends itself after 45 s without new words
        quietTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self, self.state == .listening else { t.invalidate(); return }
            guard Date().timeIntervalSince(self.lastVoice) > (self.long ? 300 : 45) else { return }
            // a call where the other side still talks goes on (the live words can stall while their sound is on disk)
            if self.isCall, self.tape.themLoudAgo < 300 { return }
            log("take ended: no new words for a while"); self.end()
        }
        step("start")
        // a long note or call goes to disk from the first sample, on the microphone's queue (Tape), so the files
        // grow even while the main thread is busy or stuck (3 November 2026)
        if long, let sp = Spool(call: isCall, app: isCall ? NSRunningApplication.runningApplications(withBundleIdentifier: CallWatch.callApp ?? "").first?.localizedName ?? ""
                                           : NSWorkspace.shared.frontmostApplication?.localizedName ?? "") {
            spool = sp; tape.attach(sp, call: isCall)
        }
        // the microphone and the strip first (2026-10-21): the screen reads below can take 50-150 ms in Chromium apps
        guard let m = MicCapture.take(sink) else {
            Pill.shared.flash("Microphone could not start")
            if let sp = tape.detach() { sp.close(); try? FileManager.default.removeItem(at: sp.dir) }
            spool = nil; isCall = false; self.long = false
            return
        }
        step("mic")
        mic = m
        state = .listening
        if long { startShots() }
        Pill.shared.listening()
        segmentsSent = 0
        if !VoiceEngine.shared.loaded { Pill.shared.waking(true); log("voice: press while the engine is waking, audio kept") }
        if !long { flowEvent(.start) }
        if SecureInput.holder != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { SecureInput.tell() } }   // Enter will not be seen
        if long { startRecordingBar() }
        step("strip")
        // a muted or wrong microphone says so in the strip after 1.5 s, instead of a silent take that ends after 45 s
        let take = started
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard self.state == .listening, self.started == take, !self.long, self.peak < 0.002 else { return }
            self.micSilent = true
            Pill.shared.note("no mic signal")
            log("take: no sound from \(m.name) after 1.5 s")
        }
        // the field, its selection and the names around it are read on the next turn, once the strip is drawn
        let mine = started
        DispatchQueue.main.async {
            if self.clock.strip == nil { self.clock.strip = Date() }
            guard self.state == .listening, self.started == mine else { return }
            let sp = Focus.spot(skip: []).0
            self.rect = sp?.rect ?? Focus.focused().flatMap { Focus.prevCharRect($0) }
            step("spot")
            self.editing = long || self.toNote ? nil : Focus.selection().flatMap { $0.count >= 2 ? $0 : nil }
            step("selection")
            self.readNames(sp)
            self.startLive(sp)
            step("names")
            report()
        }
    }

    /// The microphone's samples, on its own queue: a long note or call is written to disk right here, then main gets
    /// them (and the other side's) for the live transcript and the levels.
    lazy var sink: ([Float], Float) -> Void = { [tape] s, pk in
        let other = tape.write(s, peak: pk)
        DispatchQueue.main.async { Talk.shared.heard(s, pk, other: other) }
    }

    /// Samples from the microphone (already on disk for a long note or call), or from a test file.
    func heard(_ s: [Float], _ pk: Float, other: [Float]? = nil) {
        guard state == .listening else { return }
        if clock.mic == nil { clock.mic = Date() }
        if clock.sound == nil, pk > 0.01, Talk.speech(s) { clock.sound = Date() }
        samples += s.count; peak = max(peak, pk)
        if micSilent, peak >= 0.002 { micSilent = false; Pill.shared.note(nil) }
        if spool == nil { audio.append(contentsOf: s) }   // long notes and calls go to disk, not memory
        var theirs: Float?
        if let other, other.count == s.count {   // a call: the live transcript hears both sides, the recording keeps them apart
            VoiceEngine.shared.feed(zip(s, other).map { max(-1, min(1, $0 + $1)) })
            theirs = other.reduce(0) { max($0, abs($1)) }
        } else {
            VoiceEngine.shared.feed(s)
        }
        Pill.shared.level(pk, them: theirs)
    }


    /// A 30 ms stretch over -40 dB, the level engine/voice.py's `has_speech` counts as speech.
    static func speech(_ s: [Float]) -> Bool {
        var i = 0
        while i + 480 <= s.count {
            var e: Float = 0
            for x in s[i..<(i + 480)] { e += x * x }
            if (e / 480).squareRoot() > 0.010 { return true }
            i += 480
        }
        return false
    }

    /// A saved take through the same path as the microphone (the test hook in Main.swift).
    func test(_ path: String) {
        // only into a field that carries the test marker (2026-10-19: a test without it pasted into the Claude app)
        guard state == .idle, let f = Focus.spot(skip: []).0, f.value.contains("⟦drafter-test⟧"),
              let d = FileManager.default.contents(atPath: path), d.count > 44 else { log("voice test refused: no test marker in focus"); return }
        let pcm = d.subdata(in: 44..<d.count)
        let all: [Float] = pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        samples = 0; peak = 0; started = Date(); testing = true; audio = []; clock = Clock(); keptNote = false; lost = false; timingSaid = false
        sending = false; afterPiece = nil; lastDraft = ""
        rect = Focus.spot(skip: []).0?.rect ?? Focus.focused().flatMap { Focus.prevCharRect($0) }
        editing = long ? nil : Focus.selection().flatMap { $0.count >= 2 ? $0 : nil }
        VoiceEngine.shared.warm()
        if long { VoiceEngine.shared.longTake() }
        readNames()
        startLive(Focus.spot(skip: []).0)
        VoiceEngine.shared.onDraft = { [weak self] d in
            guard let self, self.state == .listening else { return }
            if self.clock.words == nil, !d.trimmingCharacters(in: .whitespaces).isEmpty { self.clock.words = Date() }
            self.lastDraft = d
            Pill.shared.draft(Tidy.clean(d)); self.liveDraft(d)
        }
        state = .listening
        Pill.shared.listening()
        var i = 0
        func next() {
            guard state == .listening else { return }
            if i >= all.count { end(); return }
            let chunk = Array(all[i..<min(i + 1600, all.count)]); i += 1600
            heard(chunk, chunk.reduce(0) { max($0, abs($1)) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { next() }
        }
        next()
    }

    /// Enter while talking: the words so far go into the field and a new line starts under them (Shift+Return), and
    /// the take goes on with a clean start. Nothing is sent (Andrii, 2026-10-19: paste pieces, review, send himself).
    func send() {
        guard canSend else { return }
        sending = true
        flowEvent(.piece)
        let pieceAudio = audio, app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        samples = 0; peak = 0; lastDraft = ""; audio = []
        Pill.shared.draft("")
        VoiceEngine.shared.finish { heard, _ in
            let text = self.finish(heard)
            log("voice piece: \(text.count) chars" + (debugLog ? " «\(text)»" : ""))
            if !self.timingSaid { log("voice timing" + self.timingStart()) }
            History.take(text, audio: pieceAudio, app: app, loud: false, raw: heard)
            guard !text.isEmpty else { self.pieceDone(); return }
            // live typing: the piece's final goes in as keys after what is already there, a space after it, no waiting
            // for a clipboard to come back unless something had to be pasted
            if self.live {
                let how = self.liveFinish(text, tail: " ", piece: true)
                Entities.dictated(text)                           // names in the piece wait for ⌥Tab (app/Entities.swift)
                if self.state == .listening { self.startLive(keepField: true) }   // the next piece goes on right after it
                self.pieceDone(after: how == .pasted ? Focus.restoreDelay + 0.05 : 0)
                return
            }
            let (spot, why) = Focus.spot(skip: [])
            guard let s = spot else {
                // no clean spot (caret mid-line, a selection, a rich box): paste at the caret anyway; a piece was lost
                // here before without a word (2026-10-21, Codex)
                if !self.testing, Focus.pasteTarget(why) { Focus.paste(text + " ", restore: false); log("voice piece pasted (\(why))") }
                else { History.copy(text); Pill.shared.flash("Copied · ⌘V to paste"); log("voice piece to the clipboard (\(why))") }
                self.pieceDone(after: Focus.restoreDelay + 0.05)
                return
            }
            if self.testing, !s.value.contains("⟦drafter-test⟧") { self.pieceDone(); return }
            log("voice piece \(Focus.insert(text, at: s)) \(s.app.bundleIdentifier ?? "?")")
            Entities.dictated(text)                               // names in the piece wait for ⌥Tab (app/Entities.swift)
            if self.state == .listening { self.startLive(keepField: true) }      // the next piece starts on its new line
            // a new line once the words are in the field (or after 0.6 s when the field cannot be read)
            let t0 = Date()
            func look() {
                let now = Focus.spot(skip: []).0?.before ?? ""
                if now.hasSuffix(text) || Date().timeIntervalSince(t0) > 0.6 {
                    Focus.typeText(" ")   // a space, not a new line: his next Enter sends the message as it is
                    self.pieceDone(after: Focus.restoreDelay + 0.05)   // a paste puts his clipboard back after this: the take's end waits for it
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { look() }
            }
            look()
        }
    }

    /// Press -> strip, microphone, first speech, first words in the strip (and what that read cost), first words in the
    /// field. Said once per take: at its first Enter piece, else at its end.
    var timingSaid = false
    func timingStart() -> String {
        let c = clock
        if timingSaid { return " (said at the first piece)" }
        timingSaid = true
        return (VoiceEngine.shared.loadedAt >= c.press ? " (cold: Parakeet loaded on this press)" : "")
            + ": strip \(c.ms(c.strip)) ms, mic \(c.ms(c.mic)) ms, speech \(c.ms(c.sound)) ms, first words \(c.ms(c.words)) ms "
            + "(\(c.ms(c.words, from: c.sound)) ms after speech, \(c.drafts) drafts, that read \(c.readMs.map(String.init) ?? "-") ms), "
            + "first in field \(c.ms(c.field)) ms after the press"
    }

    /// The Enter piece is in the field: Enter works again, and a take's end that came meanwhile goes in after it
    /// (never two pastes at once, which would paste one text twice and leave the piece on his clipboard).
    private func pieceDone(after delay: Double = 0) {
        sending = false
        flowEvent(.pieceDone)
        guard let next = afterPiece else { return }
        afterPiece = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next() }
    }

    func cancel() {
        guard state == .listening else { return }
        if long { log("long take: stop asked, saving it instead of dropping"); end(); return }
        mic?.stop(); mic = nil
        VoiceEngine.shared.drop()
        state = .idle; audio = []
        stopRecordingBar(); _ = tape.detach(); isCall = false; long = false
        shots?.stop(); shots = nil
        flushTimer?.invalidate(); flushTimer = nil
        Pill.shared.hide()
        flowEvent(.cancel)                 // Esc already dropped it; other ways out: an armed draft he added to waits again
    }

    static let askWake = try! NSRegularExpression(pattern: #"(?i)^\s*(drafter|драфтер|дрефтер|дрaфтер)[,.:!?]?\s+\S"#)

    private var endedAt = Date.distantPast
    private var lastHadWords = false       // the last note showed words (a press right after it is a bounce)

    /// A guard exit must not leave a live microphone feeding a dead process.
    func engineFailed() {
        guard state == .listening else { return }
        if long { end(); return } // close the disk spool; existing recovery uses the saved live text
        mic?.stop(); mic = nil
        History.take("", audio: audio, app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
                     loud: false, raw: lastDraft, outcome: "incomplete")
        state = .idle; endedAt = Date(); audio = []; editing = nil
        flushTimer?.invalidate(); flushTimer = nil
        stopRecordingBar()
        Pill.shared.flash("Voice stopped · take saved in Voice history · press Right Option to retry")
        flowEvent(.cancel)
    }

    /// A long note or call is being recorded now.
    var recording: Bool { state == .listening && long }

    /// Stop a long note or call from the menu bar, the window or the quit question (2026-10-30, Andrii: "I didn't find
    /// how to close it"; the only ways were ⇧ right ⌥ again or the call app letting go of the mic).
    func stopRecording(_ from: String) {
        guard recording else { return }
        log("recording: stopped from \(from)")
        end()
    }

    func end() {
        guard state == .listening else { return }
        endedAt = Date()
        mic?.stop(); mic = nil      // returns once the samples already captured are on disk
        // a long take counts what reached the disk: main may have seen less of it (a busy main thread)
        // a call whose microphone gave nothing still has the other side: never thrown away as empty (Argon 5)
        let secs = Double(max(samples, long ? max(spool?.frames ?? 0, tape.now().themSamples) : 0)) / 16000, heardPeak = peak
        guard secs >= 0.3 else {
            shots?.stop(); shots = nil; VoiceEngine.shared.drop(); state = .idle; Pill.shared.hide()
            if !long { flowEvent(.cancel) }
            if let sp = tape.detach() { sp.close(); try? FileManager.default.removeItem(at: sp.dir) }   // nothing in it
            spool = nil; isCall = false; long = false; stopRecordingBar()
            return
        }
        state = .reading
        if long { Pill.shared.reading() } else { flowEvent(.stop); Pill.shared.finishing(insert: flowInsertPending) }
        let t = Date()
        let mine = started
        let takeAudio = audio, takeDraft = lastDraft, app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        audio = []
        let wasCall = isCall
        shots?.stop(); shots = nil
        // the other side's last samples go after the rest, then both files close: nothing captured is thrown away
        let files = tape.detach().map { sp -> (URL, URL, URL?, String) in let (m, t) = sp.close(); return (sp.dir, m, t, sp.liveText) }
        isCall = false; spool = nil
        stopRecordingBar()
        // only words he saw in the strip are pasted: when he stops on random sounds, a late reading of them is not
        // his text (2026-10-20)
        let sawWords = Talk.real(lastDraft, peak: heardPeak)
        lastHadWords = sawWords || segmentsSent > 0
        // nothing showed in the strip, so nothing will be pasted: close at once instead of waiting for a last reading
        // (2026-10-21: those takes held the strip 0.2-1.4 s for nothing)
        if !sawWords, files == nil, editing == nil, !sending {
            VoiceEngine.shared.drop()
            state = .idle
            flushTimer?.invalidate(); flushTimer = nil
            History.take("", audio: takeAudio, app: app, loud: false)
            log(String(format: "take %.1f s, peak %.3f, nothing shown: closed at once", secs, heardPeak))
            flowEvent(.cancel)
            if keptNote { keptNote = false; Pill.shared.copied("The field changed under the words") }
            else if segmentsSent > 0, flow.queue > 0 || insertBusy || !insertQueue.isEmpty {
                Pill.shared.finishing(insert: true)   // a segment Return closed is still on its way: its receipt shows
            }
            else if heardPeak < 0.002, segmentsSent == 0 { Pill.shared.flash("No mic signal") } else { Pill.shared.hide() }
            return
        }
        // never stay stuck with the mark on screen: no answer in 15 s ends the take
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard self.state == .reading, self.started == mine else { return }
            log("take: no answer from the voice engine in 15 s, kept for review")
            if files == nil {
                History.take("", audio: takeAudio, app: app, loud: false, raw: takeDraft, outcome: "timeout")
            }
            self.state = .idle; self.long = false; self.editing = nil
            self.flushTimer?.invalidate(); self.flushTimer = nil
            if files == nil { self.flowEvent(.cancel) }
            Pill.shared.flash(files == nil ? "Transcription timed out · review in Voice history" : "Transcription timed out · review in Recordings")
        }
        // the take's text into the field; an Enter piece still on its way there goes in first (pieceDone runs this)
        func land(_ heard: String, _ loud: Bool) {
            guard self.state == .reading, self.started == mine else { return }
            let readAt = Date()
            self.state = .idle
            if !self.long, heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sawWords {
                History.take("", audio: takeAudio, app: app, loud: loud, raw: takeDraft, outcome: "incomplete")
                self.editing = nil
                self.flushTimer?.invalidate(); self.flushTimer = nil
                self.flowEvent(.cancel)
                Pill.shared.flash("No final transcript · review in Voice history")
                return
            }
            let text = self.finish(heard)
            if !self.long { History.take(text, audio: takeAudio, app: app, loud: loud, raw: heard); Pill.shared.hide() }
            if self.long {
                self.long = false
                guard let (dir, me, them, kept) = files else { Pill.shared.flash("Recording was not saved"); return }
                // the whole recording is read again (the live text can miss a stretch), as for calls
                self.transcribe(dir: dir, me: me, them: them, call: wasCall, live: kept.count > text.count ? kept : text)
                return
            }
            // the shot strip was open: the words are its note, nothing goes into the app
            if self.toNote {
                self.toNote = false
                self.editing = nil
                self.flushTimer?.invalidate(); self.flushTimer = nil
                self.flowReset("a screenshot note")
                CaptureNote.shared.heard(text)
                return
            }
            // "Drafter, …" / "Драфтер, …": a question to his notes; the answer shows in the strip, nothing is pasted
            if Talk.askWake.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                self.editing = nil
                self.flowReset("a question to the notes")
                Pill.shared.show("Searching your notes…", seconds: 45)
                log("ask: \(text.count) chars")
                Engine.shared.post("/ask", ["text": text], timeout: 60) { j in
                    let a = (j?["answer"] as? String) ?? "Could not find an answer."
                    Pill.shared.show(a, seconds: max(8, min(25, Double(a.count) / 12)), lines: 4)
                    log("ask: answered in \(j?["ms"] as? Int ?? 0) ms from \((j?["sources"] as? [String])?.count ?? 0) sources")
                }
                return
            }
            if let original = self.editing, !text.isEmpty {
                self.editing = nil
                self.flowReset("an edit of the selection")
                self.edit(original, with: text)
                return
            }
            log(String(format: "take %.1f s, peak %.3f, %d chars (last draft %d, typed live %d), loud %@, read in %.2f s", secs, heardPeak, text.count,
                       self.lastDraft.count, self.live ? (self.doneBefore + self.run).count : 0, "\(loud)", Date().timeIntervalSince(t))
                + (debugLog ? " «\(text)»" : ""))
            // nothing (or only what was never shown) is not pasted; no second reading of noise either: Whisper invents
            // words in it (2026-10-20, Andrii: "I'm just shutting it down after a use")
            if text.isEmpty || !sawWords {
                self.flowEvent(.cancel)
                if heardPeak < 0.002, self.segmentsSent == 0 { Pill.shared.flash("No mic signal") }
                log("take ended: nothing new to paste" + (text.isEmpty ? "" : " (\(text.count) chars heard only at the end, dropped)"))
                return
            }
            if self.live {
                self.flowEvent(.final(text))
                self.liveFinish(text, tail: " ", piece: false); Entities.dictated(text)
                if self.keptNote { self.keptNote = false; Pill.shared.copied("The field changed under the words") } else { Pill.shared.landed() }
            } else if self.testing {
                self.flowReset("a voice test"); self.put(text); Pill.shared.landed()   // tests write only into their marked field
            } else {
                self.flowEvent(.final(text))   // enter mode: the draft waits for ↩ (or ↩ came already: it goes in now)
            }
            let c = self.clock, e = c.end ?? t
            log("voice timing\(self.timingStart()); "
                + "end: engine \(Int(readAt.timeIntervalSince(e) * 1000)) ms, pasted \(Int(Date().timeIntervalSince(e) * 1000)) ms after the end")
            self.flushTimer?.invalidate(); self.flushTimer = nil
            if loud {
                VoiceEngine.shared.careful { slow in
                    let c = self.finish(slow)
                    log("careful read: " + (c.isEmpty ? "nothing" : c == text ? "same text" : "text changed"))
                    guard !c.isEmpty, c != text, self.state == .idle, self.started == mine, !Ghost.shared.visible else { return }
                    let revision = Keys.shared.inputRevision
                    DispatchQueue.global(qos: .userInitiated).async {
                        let spot = Focus.spot(skip: []).0
                        DispatchQueue.main.async {
                            guard self.state == .idle, self.started == mine, !Ghost.shared.visible,
                                  Keys.shared.inputRevision == revision,
                                  let s = spot, s.before.hasSuffix(text + " "), let r = s.rect else { return }
                            Keys.shared.spot = s
                            let short = c.count > 60 ? String(c.prefix(57)) + "…" : c
                            Ghost.shared.show("", action: ["id": "voice.better", "chip": "Refined: «\(short)»",
                                                           "run": ["kind": "replace", "old": text + " ", "new": c + " "]], at: r)
                        }
                    }
                }
            }
        }
        VoiceEngine.shared.finish { heard, loud in
            if self.sending { self.afterPiece = { land(heard, loud) } } else { land(heard, loud) }
        }
    }

    // MARK: speak over a selection

    static let instruction = try! NSRegularExpression(pattern:
        #"(?i)^\s*(зроби|перепиши|скороти|коротше|переклади|виправ|додай|прибери|зміни|розбий|спрости|покращ|make|rewrite|shorten|translate|fix|turn|add|remove|change|split|summari[sz]e|simplify|improve|more|less)\b"#)

    /// Spoken words over a selection: a new version replaces it; an instruction rewrites it with the local model and
    /// the result waits as a chip (Tab puts it in). The original stays in the take history.
    private func edit(_ original: String, with spoken: String) {
        let isInstruction = Talk.instruction.firstMatch(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)) != nil
        if !isInstruction {
            replaceSelection(original, with: spoken)
            log("voice over a selection: replaced \(original.count) characters")
            return
        }
        Pill.shared.show("✎ " + spoken + " …", seconds: 20)
        Engine.shared.post("/rewrite", ["text": original, "instruction": spoken], timeout: 30) { j in
            let new = (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !new.isEmpty else { Pill.shared.flash("Could not rewrite the selection"); return }
            History.take("✎ \(spoken)\n- before: \(original)\n- after: \(new)", audio: [], app: "", loud: false)
            Pill.shared.show(new, seconds: 12)
            let r = Focus.spot(skip: []).0?.rect ?? self.rect ?? Focus.focused().flatMap { Focus.prevCharRect($0) }
            if let r {
                Ghost.shared.show("", action: ["id": "voice.rewrite", "chip": "Replace selection (\(new.count) characters)",
                                               "run": ["kind": "replaceSelection", "old": original, "new": new]], at: r)
            } else {
                History.copy(new); Pill.shared.flash("Revised text copied · ⌘V to paste")
            }
            log("voice over a selection: rewrite \(original.count) -> \(new.count) characters in \(j?["ms"] as? Int ?? 0) ms")
        }
    }

    /// Paste over the selection, but only while it is still the same text; else the new text goes to the clipboard.
    func replaceSelection(_ original: String, with new: String) {
        if Focus.selection() == original { Focus.paste(new) }
        else { History.copy(new); Pill.shared.flash("Selection changed; revised text copied") }
    }

    /// The final text of a take: clean-up, spoken corrections and lists, names on screen.
    func finish(_ heard: String) -> String {
        Rules.names(Rules.apply(Tidy.clean(heard)), screenNames)
    }

    /// Dictionary names (Aleph people and projects) that appear in the text on screen around the field.
    private func readNames(_ given: Spot?? = nil) {
        screenNames = []
        guard let s = given ?? Focus.spot(skip: []).0 else { return }
        let el = s.el, pid = s.app.processIdentifier, rect = s.rect
        DispatchQueue.global().async {
            let ctx = Keys.readContext(el, pid: pid, caret: rect).lowercased() + " " + s.before.suffix(600).lowercased()
            let found = NameBook.found(in: ctx)
            DispatchQueue.main.async {
                guard self.state == .listening else { return }
                self.screenNames = Array(found.prefix(30))
                VoiceEngine.shared.hint(self.screenNames)
                if debugLog { log("names on screen: \(self.screenNames.joined(separator: ", "))") }
            }
        }
    }

    // MARK: live typing (voice and hands take turns)

    /// Voice text goes into the field on the strip's beat: each draft, the words the strip shows as steady (LiveType)
    /// go in as key events, a few words at a time, no clipboard. A small fix near the caret (a comma, a capital, the last
    /// word) goes in at once; one further back waits for the end, where only what changed is touched (caret moves, one
    /// selection typed over), never a retype of the tail. When he types or clicks, voice waits until 1.2 s after his
    /// last key and goes on at the new caret as a new run; fixes only ever touch the current run, and only while the
    /// field still ends with it. A field he left never gets a word: the rest waits for the end and goes to the clipboard.
    var run = ""              // what Drafter typed in the field in this run, exactly
    var runEl: AXUIElement?   // the field the run is in (nil: read the caret again before the next words)
    var runPid: pid_t = 0
    var runBefore: Character? // the character before the caret when the run started
    var doneBefore = ""       // this piece's words that earlier runs (before his last key) put in
    var steadyText = ""       // the piece's steady words so far (cleaned draft)
    var steadyWords = 0, landedWords = 0
    var still = 0, lastClean = ""
    var lost = false          // he left the field: nothing more typed in this take
    var editRev = 0
    var meter = LiveType.Meter()
    var fixedChars = 0        // characters fixed while he talked, this piece
    var keptNote = false      // a piece's end left the field as typed (final text copied): said at the take's end
    var lastWant = ""         // a target that gave nothing to do (a fix waiting for the end): not planned again
    var lastSpotTry = Date.distantPast
    var lastHand = Date.distantPast
    var flushTimer: Timer?
    var handsBusy: Bool { Date().timeIntervalSince(lastHand) < 1.2 }
    /// Seconds since the press, for the meter.
    var now: Double { Date().timeIntervalSince(started) }

}

/// Names from the shared dictionary (Aleph people and projects), for the per-take hints.
enum NameBook {
    static var all: [String] = {
        guard let d = try? Data(contentsOf: Home.words),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let w = j["words"] as? [[String: Any]] else { return [] }
        return w.filter { ["name", "project"].contains($0["kind"] as? String ?? "") }.compactMap { $0["text"] as? String }
            .filter { $0.count >= 3 }
    }()

    /// On screen: the whole name, or its first word (4+ letters) with any ending (Савою, Зіні).
    static func seen(_ name: String, in text: String) -> Bool { seen(name, in: text as NSString) }

    /// The names in `text` (lower case), in dictionary order. One NSString for the whole scan: Swift's
    /// String.contains cost ~28 ms for 655 names on a 2500-character screen, NSString's range(of:) ~7 ms.
    static func found(in text: String) -> [String] {
        let ns = text as NSString
        return all.filter { seen($0, in: ns) }
    }

    private static func seen(_ name: String, in text: NSString) -> Bool {
        let n = name.lowercased()
        if text.range(of: n).location != NSNotFound { return true }
        guard let (plain, r) = stem(n), text.range(of: plain).location != NSNotFound else { return false }   // no stem, no match
        return r.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) != nil
    }

    /// The first word's stem and its pattern, compiled once per name (2026-11-14: 655 compiles at every take start).
    private static var stems: [String: (String, NSRegularExpression)?] = [:]
    private static let stemsLock = NSLock()
    private static func stem(_ n: String) -> (String, NSRegularExpression)? {
        stemsLock.lock(); defer { stemsLock.unlock() }
        if let r = stems[n] { return r }
        var r: (String, NSRegularExpression)?
        if let first = n.split(separator: " ").first, first.count >= 4 {
            let stem = String(first.prefix(max(3, first.count - 2)))
            if let rx = try? NSRegularExpression(pattern: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: stem) + #"\p{L}{0,3}(?![\p{L}])"#) { r = (stem, rx) }
        }
        stems[n] = r
        return r
    }
}
