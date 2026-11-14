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
                me.proc = nil
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
        do { try p.run(); proc = p; input = inPipe.fileHandleForWriting } catch { log("voice engine did not start: \(error)") }
    }

    func stop() {
        generation = UUID()   // invalidate an already scheduled restart
        let old = proc; proc = nil
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
            if let l = m["loaded"] { loadedAt = Date(); log("voice: loaded \(l) in \(m["s"] ?? "?") s") }
            if let l = m["unloaded"] { log("voice: unloaded \(l) (\(m["why"] ?? "?"))") }
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
    func feed(_ s: [Float]) { frame(0, s) }
    func drop() { frame(254) }
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
    private var mic: MicCapture?
    private var samples = 0
    private var audio: [Float] = []        // the take's sound, kept in History (data/audio, 14 days)
    private var screenNames: [String] = [] // dictionary names seen on screen when the take began
    private var lastVoice = Date()         // last time the draft grew: 45 s without new words ends the take
    private var quietTimer: Timer?
    private var editing: String?           // text selected when the take began: the take replaces or rewrites it
    private var peak: Float = 0
    private var started = Date()
    private var rect: CGRect?
    private var downAt: Date?
    private var testing = false
    // Prepared when a draft arrives, never from the event tap's Return check.
    private var sendDraft = ""
    private var cleanedDraft = ""
    private var lastDraft = "" {
        didSet {
            // Long notes/calls keep their raw transcript; Return never sends it.
            // Do not walk a growing recording through the dictionary every draft.
            guard !long else { cleanedDraft = ""; sendDraft = ""; return }
            cleanedDraft = lastDraft.isEmpty ? "" : Tidy.clean(lastDraft)
            sendDraft = Rules.trailingFillers(cleanedDraft)
        }
    }
    private var sending = false
    private var afterPiece: (() -> Void)?  // the take's end, held while an Enter piece is still going into the field
    // live typing (2026-10-19): settled words go into the field while he talks
    private var live = false
    private var prevWords: [Substring] = []
    /// Enter while talking puts what was said so far into the field on its own line (never sends): only with words heard
    /// Words were heard in this take: Enter then ends it and puts them in (Keys.swift)
    /// Enter puts words in only when they are words: "Yeah." / "Okay." / a quiet "Thank you." heard in the pause after the
    /// last Enter are what the reader makes of room noise, so that Enter goes to the app and sends (2026-10-22: those
    /// swallowed his sending Enter two or three times in a row and the strip cycled through them).
    var canSend: Bool { state == .listening && !sending && Double(samples) / 16000 >= 0.4 && Talk.realCleaned(sendDraft, peak: peak) }

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
    private var spool: Spool?              // a long note or call, written to disk while it runs
    /// The same recording as seen from the microphone's queue, which writes it (and the call's other side) to disk.
    private let tape = Tape()
    private var micReopened = false        // a call's microphone that gave only zeros was opened again once
    private var warning: String?           // what the recording strip says is not heard (CallHealth)
    private var shots: Shots?              // screenshots while a long note or call runs (setting `shots`)
    /// Seconds without new words in this take (a call ends when its app let go of the mic and nobody spoke).
    var quietFor: Double { Date().timeIntervalSince(lastVoice) }
    private var recTimer: Timer?, outlineTimer: Timer?
    private var recStart = Date(), recTitle = "", recOutline: [String] = []

    func key(down: Bool, long longKey: Bool = false, at: Date = Date()) {
        if down {
            // a press within 0.8 s of a take's end does not start a new one (2026-10-22: 0.5-1 s empty takes right after
            // real ones, up to three in a row, and some ran 16-46 s on room noise; none had speech)
            if state == .idle, at.timeIntervalSince(endedAt) < 0.8 { log("voice: press right after a take ignored"); return }
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
            if d.count != self.lastDraft.count { self.lastVoice = Date() }
            if self.clock.words == nil {
                self.clock.drafts += 1
                if !d.trimmingCharacters(in: .whitespaces).isEmpty { self.clock.words = Date(); self.clock.readMs = VoiceEngine.shared.draftMs }
            }
            self.lastDraft = d
            self.spool?.text(d)
            if !self.long { Pill.shared.draft(Talk.realCleaned(self.sendDraft, peak: self.peak) ? self.cleanedDraft : "") }   // noise words never show
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
            self.editing = long ? nil : Focus.selection().flatMap { $0.count >= 2 ? $0 : nil }
            step("selection")
            self.readNames(sp)
            self.startLive(sp)
            step("names")
            report()
        }
    }

    /// The microphone's samples, on its own queue: a long note or call is written to disk right here, then main gets
    /// them (and the other side's) for the live transcript and the levels.
    private lazy var sink: ([Float], Float) -> Void = { [tape] s, pk in
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
    private var timingSaid = false
    private func timingStart() -> String {
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
    }

    static let askWake = try! NSRegularExpression(pattern: #"(?i)^\s*(drafter|драфтер|дрефтер|дрaфтер)[,.:!?]?\s+\S"#)

    private var endedAt = Date.distantPast

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
            if let sp = tape.detach() { sp.close(); try? FileManager.default.removeItem(at: sp.dir) }   // nothing in it
            spool = nil; isCall = false; long = false; stopRecordingBar()
            return
        }
        state = .reading
        Pill.shared.reading()
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
        // nothing showed in the strip, so nothing will be pasted: close at once instead of waiting for a last reading
        // (2026-10-21: those takes held the strip 0.2-1.4 s for nothing)
        if !sawWords, files == nil, editing == nil, !sending {
            VoiceEngine.shared.drop()
            state = .idle
            flushTimer?.invalidate(); flushTimer = nil
            History.take("", audio: takeAudio, app: app, loud: false)
            log(String(format: "take %.1f s, peak %.3f, nothing shown: closed at once", secs, heardPeak))
            if keptNote { keptNote = false; Pill.shared.flash("Field kept as typed · final text copied") }
            else if heardPeak < 0.002 { Pill.shared.flash("No mic signal") } else { Pill.shared.hide() }
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
            // "Drafter, …" / "Драфтер, …": a question to his notes; the answer shows in the strip, nothing is pasted
            if Talk.askWake.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                self.editing = nil
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
                self.edit(original, with: text)
                return
            }
            log(String(format: "take %.1f s, peak %.3f, %d chars (last draft %d, typed live %d), loud %@, read in %.2f s", secs, heardPeak, text.count,
                       self.lastDraft.count, self.live ? (self.doneBefore + self.run).count : 0, "\(loud)", Date().timeIntervalSince(t))
                + (debugLog ? " «\(text)»" : ""))
            // nothing (or only what was never shown) is not pasted; no second reading of noise either: Whisper invents
            // words in it (2026-10-20, Andrii: "I'm just shutting it down after a use")
            if text.isEmpty || !sawWords {
                if heardPeak < 0.002 { Pill.shared.flash("No mic signal") }
                log("take ended: nothing new to paste" + (text.isEmpty ? "" : " (\(text.count) chars heard only at the end, dropped)"))
                return
            }
            if self.live { self.liveFinish(text, tail: " ", piece: false); Entities.dictated(text) } else { self.put(text) }
            if self.keptNote { self.keptNote = false; Pill.shared.flash("Field kept as typed · final text copied") } else { Pill.shared.landed() }
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

    // MARK: long notes and calls

    private func startRecordingBar() {
        recStart = Date(); recTitle = ""; recOutline = []
        recTimer?.invalidate(); outlineTimer?.invalidate()
        recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state == .listening, self.long else { return }
            self.checkSides()
            Pill.shared.recording(call: self.isCall, seconds: Int(Date().timeIntervalSince(self.recStart)), title: self.recTitle, outline: self.recOutline,
                                  event: self.spool?.event ?? "", shots: self.shots?.list.count ?? 0, warning: self.warning)
        }
        // every 75 s the outline is rebuilt from everything said so far (title, points, to-dos)
        outlineTimer = Timer.scheduledTimer(withTimeInterval: 75, repeats: true) { [weak self] _ in
            guard let self, self.state == .listening, self.long, !self.lastDraft.isEmpty else { return }
            Engine.shared.post("/outline", ["text": self.lastDraft, "call": self.isCall], timeout: 60) { j in
                guard let j, self.state == .listening else { return }
                if let t = j["title"] as? String, !t.isEmpty { self.recTitle = t }
                let pts = (j["points"] as? [String] ?? []) + (j["todos"] as? [String] ?? []).map { "→ " + $0 }
                if !pts.isEmpty { self.recOutline = pts }
            }
        }
        Pill.shared.recording(call: isCall, seconds: 0, title: "", outline: [], event: spool?.event ?? "")
        Menu.shared.refresh()
    }

    /// Is each side heard? Said in the strip from the first seconds of the recording (CallHealth), logged when it
    /// changes. A microphone that gives only exact zeros is opened again once (a call app can take or mute it).
    private func checkSides() {
        let st = tape.now()
        if long, st.seconds >= 6, st.meSamples > 0, st.mePeak == 0, !micReopened {
            micReopened = true
            log("recording: the microphone gave only zeros for \(Int(st.seconds)) s, opening it again")
            mic?.stop(); MicCapture.shared?.stopNow(); MicCapture.shared = nil
            mic = MicCapture.take(sink)
            if mic == nil { log("recording: the microphone could not open again") }
        } else if long, micReopened, mic == nil, state == .listening {
            // nothing writes the recording while there is no microphone (the other side waits in memory): keep trying
            // each second; when it opens, what waited goes to disk (Argon 6)
            mic = MicCapture.take(sink)
            if mic != nil { log("recording: the microphone opened again") }
        }
        let w = CallHealth.warning(st)
        if w != warning {
            log("recording: " + (w.map { "warning: \($0)" } ?? "both sides heard again")
                + String(format: " (me %.1f s peak %.3f; them %@ %.1f s peak %.3f)", Double(st.meSamples) / 16000, st.mePeak,
                         "\(st.sysState)", Double(st.themSamples) / 16000, st.themPeak))
            warning = w
        }
    }

    private func stopRecordingBar() { recTimer?.invalidate(); outlineTimer?.invalidate(); recTimer = nil; outlineTimer = nil; DispatchQueue.main.async { Menu.shared.refresh() } }

    /// Screenshots for the recording now on disk (menu "Screenshots in long notes and calls", on by default).
    private func startShots() {
        shots?.stop(); shots = nil
        guard Drafter.shared.settings.shots, let sp = spool else { return }
        let s = Shots(recording: sp.dir) { [weak sp] in Double(sp?.frames ?? 0) / 16000 }
        s.start(); shots = s
    }

    /// One side read again; a reading that came back empty for a side with minutes of sound (the voice engine was
    /// stopped under it) is tried once more when the engine is back.
    private func readSide(_ url: URL, names: [String], lang: String?, retry: Bool = true, _ done: @escaping ([[String: Any]]) -> Void) {
        let go = {
            VoiceEngine.shared.readFile(url.path, names: names, lang: lang) { segs in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if segs.isEmpty, retry, size > 32000 * 20 {
                    log("recording: no text back for \(url.lastPathComponent), trying again")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.readSide(url, names: names, lang: lang, retry: false, done) }
                } else { done(segs) }
            }
        }
        if VoiceEngine.shared.running { go(); return }
        VoiceEngine.shared.preload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { go() }
    }

    /// A finished long note or call (or one recovered after a crash): each side read again with times (Parakeet, else
    /// Whisper), merged as "Я" / "Вони" for calls with his mic's echo of them taken out, then a note. Screenshots
    /// taken meanwhile go into brief.md beside the transcript, and the line to hand it to an agent goes on the
    /// clipboard. The live text is the fallback when the reading gives nothing.
    func transcribe(dir: URL, me: URL, them: URL?, call: Bool, live: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: me.path)[.size] as? Int) ?? 0
        let mins = Double(size) / 32000 / 60
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        let event = meta["event"] as? [String: Any]
        Pill.shared.show(String(format: call ? "Call %.0f min: transcribing both sides…" : "Note %.0f min: transcribing…", mins), seconds: 900)
        log(String(format: "%@ ended: %.1f min, other side %@, in %@", call ? "call" : "long note", mins, them == nil ? "not recorded" : "recorded", dir.lastPathComponent))
        let names = screenNames + ((event?["people"] as? [String]) ?? [])
        let lang = Transcript.language(live)
        // memory budget: with little free memory or a long recording, the text model steps aside while both sides are
        // read (the voice engine may take 3.4 GB then); typing keeps the word finisher meanwhile
        let free = Budget.free()
        let rest = (0..<Budget.low).contains(free) || mins >= 20
        if rest { Budget.rest(secs: max(120, mins * 15), why: "\(free)% free, a \(Int(mins)) min \(call ? "call" : "note") is read") }
        readSide(me, names: names, lang: lang) { a in
            let finish: ([[String: Any]]) -> Void = { b in
                if rest { Budget.wake() }
                let mine = call ? Transcript.echoless(a, b) : a
                if mine.count < a.count { log("call: \(a.count - mine.count) of my lines were the other side's echo") }
                let rows = mine.map { (call ? "Я" : "", $0) } + b.map { ("Вони", $0) }
                let ordered = rows.sorted { ($0.1["start"] as? Double ?? 0) < ($1.1["start"] as? Double ?? 0) }
                var transcript = ordered.map { ($0.0.isEmpty ? "" : "\($0.0): ") + (($0.1["text"] as? String) ?? "") }.joined(separator: call ? "\n" : " ")
                if transcript.trimmingCharacters(in: .whitespaces).isEmpty { transcript = live }
                try? transcript.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
                Spool.markRead(dir)
                // the same lines with their times, for the Recordings view (play from a line, screenshots in place)
                let timed = ordered.map { ["who": $0.0, "start": $0.1["start"] as? Double ?? 0, "text": ($0.1["text"] as? String) ?? ""] as [String: Any] }
                if !timed.isEmpty, let d = try? JSONSerialization.data(withJSONObject: timed) { try? d.write(to: dir.appendingPathComponent("lines.json")) }
                // talk and screen together for an agent: brief.md, and the line to paste on the clipboard
                let shots = Shot.load(dir)
                var handoff: String?
                if !shots.isEmpty {
                    let brief = ordered.map { Brief.Row(who: $0.0, start: $0.1["start"] as? Double ?? 0, text: ($0.1["text"] as? String) ?? "") }
                    let line = Brief.write(dir: dir, rows: brief.isEmpty && !live.isEmpty ? [Brief.Row(who: "", start: 0, text: live)] : brief,
                                           shots: shots, meta: meta, minutes: mins)
                    if shots.count >= 2 { handoff = line; History.copy(line) }   // one shot = a screen that never changed
                    log("brief: \(shots.count) screenshots, \(brief.count) lines")
                }
                guard !transcript.isEmpty else { Pill.shared.flash(call ? "No speech found in the call" : "No speech found"); return }
                if let handoff {
                    Pill.shared.show("Walkthrough with \(shots.count) screenshots copied · ⌘V into Claude or Codex", seconds: 6)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.saveNote(transcript, audio: dir.path, call: call, event: event, handoff: handoff) }
                } else {
                    self.saveNote(transcript, audio: dir.path, call: call, event: event)
                }
            }
            if let them { self.readSide(them, names: names, lang: lang, finish) } else { finish([]) }
        }
    }

    private func saveNote(_ text: String, audio: String, call: Bool = false, event: [String: Any]? = nil, handoff: String? = nil) {
        Pill.shared.show(call ? "Call: preparing a note…" : "Note: processing…", seconds: 90)
        var body: [String: Any] = ["text": text, "audio": audio, "call": call]
        if let event { body["event"] = event }
        Engine.shared.post("/note", body, timeout: 120) { j in
            guard let j, let title = j["title"] as? String else { Pill.shared.flash("Note was not saved"); History.copy(text); return }
            let links = (j["links"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let fu = (j["followups"] as? [String]) ?? []
            var lines = ["✓ \(title)"]
            if !links.isEmpty { lines.append("About: " + links.joined(separator: ", ")) }
            if !fu.isEmpty { lines.append("Follow-ups: " + fu.map { "• " + $0 }.joined(separator: " ")) }
            lines.append("Saved: " + ((j["saved"] as? [String]) ?? []).joined(separator: ", "))
            if handoff != nil { lines.append("Walkthrough for the agent: on the clipboard (also in Drafter › Recordings)") }
            Pill.shared.show(lines.joined(separator: "\n"), seconds: 6)
            log("long note: \(text.count) chars, \(links.count) links, \(fu.count) follow-ups")
            // follow-ups become a chip: Tab adds them to Aleph (each as a follow-up for the next working morning)
            if !fu.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    Offer.show(["Add \(fu.count) follow-up\(fu.count == 1 ? "" : "s") to Aleph?"] + fu.prefix(2).map { "• " + $0 }, kind: "Follow-ups", accept: "Add", seconds: 20) {
                        Engine.shared.post("/followups", ["items": fu], timeout: 30) { j in
                            Pill.shared.flash("Added to Aleph: \(j?["added"] as? Int ?? 0)")
                        }
                    }
                }
            }
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
    private func finish(_ heard: String) -> String {
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
    private var run = ""              // what Drafter typed in the field in this run, exactly
    private var runEl: AXUIElement?   // the field the run is in (nil: read the caret again before the next words)
    private var runPid: pid_t = 0
    private var runBefore: Character? // the character before the caret when the run started
    private var doneBefore = ""       // this piece's words that earlier runs (before his last key) put in
    private var steadyText = ""       // the piece's steady words so far (cleaned draft)
    private var steadyWords = 0, landedWords = 0
    private var still = 0, lastClean = ""
    private var lost = false          // he left the field: nothing more typed in this take
    private var editRev = 0
    private var meter = LiveType.Meter()
    private var fixedChars = 0        // characters fixed while he talked, this piece
    private var keptNote = false      // a piece's end left the field as typed (final text copied): said at the take's end
    private var lastWant = ""         // a target that gave nothing to do (a fix waiting for the end): not planned again
    private var lastSpotTry = Date.distantPast
    private var lastHand = Date.distantPast
    private var flushTimer: Timer?
    private var handsBusy: Bool { Date().timeIntervalSince(lastHand) < 1.2 }
    /// Seconds since the press, for the meter.
    private var now: Double { Date().timeIntervalSince(started) }

    /// A take or an Enter piece starts: a fresh run. `spot` is the field read at the take's start (nil: read later).
    private func startLive(_ spot: Spot? = nil, keepField: Bool = false) {
        live = Drafter.shared.settings.voiceLive && editing == nil && !long   // never over a selection or in a long note
        if !keepField {
            runEl = spot?.el; runPid = spot?.app.processIdentifier ?? 0; runBefore = spot?.before.last
            if testing, let s = spot, !s.value.contains("⟦drafter-test⟧") { runEl = nil }
            lost = false
        }
        run = ""; doneBefore = ""; steadyText = ""; steadyWords = 0; landedWords = 0
        prevWords = []; still = 0; lastClean = ""; fixedChars = 0; lastWant = ""; lastSpotTry = .distantPast
        meter.reset(); lastHand = .distantPast; editRev = Keys.shared.editRevision
        flushTimer?.invalidate(); flushTimer = nil
        if live { flushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.liveStep() } }
    }

    /// A key of his own during a take (from the event tap): voice waits until his hands stop, then goes on where he is.
    func keyDuringTake() {
        guard live else { return }
        lastHand = Date(); handsMoved()
    }

    /// His key or click: the run ends here; the next words start a new one at the caret as it is then.
    private func handsMoved() {
        editRev = Keys.shared.editRevision
        if !run.isEmpty { doneBefore += run }
        run = ""; runEl = nil
    }

    /// A new draft: the strip's steady words, then the field catches up.
    private func liveDraft(_ d: String) {
        // what the strip hides (noise words) never goes in; closing words at the end ("…, okay") wait for more words
        guard live, !long, Talk.realCleaned(sendDraft, peak: peak) else { return }
        let clean = Tidy.clean(d)
        still = clean == lastClean ? still + 1 : 1
        lastClean = clean
        let words = clean.split(separator: " ")
        let n = min(LiveType.steady(prevWords, words, still: still), sendDraft.split(separator: " ").count)
        prevWords = words
        meter.saw(words: words.count, at: now)
        if n > 0 { meter.settled(words: n, at: now) }
        // a word already in the field changed in this draft: wait for drafts that agree again rather than take it out
        guard n >= landedWords, n > 0 else { return }
        steadyText = LiveType.head(clean, words: n); steadyWords = n
        liveStep()
    }

    /// What the current run should hold, from a text of the piece (steady words, or the final).
    private func runTarget(_ text: String) -> String? {
        var want = text
        if !doneBefore.isEmpty {
            guard let j = LiveType.aligned(doneBefore, in: text) else { return nil }
            want = String(text[j...])
        }
        let trimmed = String(want.drop(while: { $0 == " " }))
        return LiveType.spaced(trimmed, after: runBefore)
    }

    private static func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }

    /// The field is still the run's (same app, same field); the first time in a run, read the caret.
    private func fieldOK() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if runEl == nil {
            guard run.isEmpty else { return false }
            let (s, why) = Focus.spot(skip: [])
            guard let s else {
                if !["mid-line", "selection", "no caret rect"].contains(why), runPid != 0, app.processIdentifier != runPid { leftField(why) }
                return false
            }
            if testing, !s.value.contains("⟦drafter-test⟧") { leftField("no test marker"); return false }
            if runPid != 0, s.app.processIdentifier != runPid { leftField("other app"); return false }
            runEl = s.el; runPid = s.app.processIdentifier; runBefore = s.before.last
            return true
        }
        guard app.processIdentifier == runPid else { leftField("other app"); return false }
        guard let el = Focus.focused() else { return false }
        if let r = runEl, CFEqual(el, r) { return true }
        // Chromium can hand out a new element for the same box: the same field when it still ends with the run
        if let s = Focus.spot(skip: []).0, s.app.processIdentifier == runPid, Talk.plain(s.before).hasSuffix(Talk.plain(run)) {
            runEl = s.el; return true
        }
        leftField("focus moved"); return false
    }

    private func leftField(_ why: String) {
        guard !lost else { return }
        lost = true
        log("live typing: left the field (\(why)), the rest waits for the end")
    }

    /// Settled words not yet in the field go in now, unless his hands are busy or he left the field.
    private func liveStep() {
        guard live, !lost, state == .listening, !sending else { return }
        if Keys.shared.editRevision != editRev { lastHand = Date(); handsMoved(); return }   // a click moves the caret too
        guard !handsBusy, !steadyText.isEmpty, let first = runTarget(steadyText), first != run, first != lastWant else { return }
        // a field that could not be read (caret mid-line, a selection) is asked again at most once a second
        if runEl == nil, Date().timeIntervalSince(lastSpotTry) < 1 { return }
        if runEl == nil { lastSpotTry = Date() }
        guard fieldOK(), let want = runTarget(steadyText) else { return }   // again: a run's first words read the caret just now
        let p = LiveType.plan(have: run, want: want, end: false)
        guard !p.lost, !(p.keys.isEmpty && p.append.isEmpty) else { lastWant = want; return }
        press(p.keys)
        if !p.append.isEmpty { Focus.typeText(p.append) }
        run = p.next; fixedChars += p.fixed; lastWant = ""
        if clock.field == nil { clock.field = Date() }
        landedWords = steadyWords
        meter.typed(words: steadyWords, at: now)
    }

    private func press(_ keys: [LiveType.Key]) {
        for k in keys {
            switch k {
            case .left(let n): Fields.left(n)
            case .right(let n): Fields.right(n)
            case .select(let n): Fields.left(n, shift: true)
            case .type(let s): Focus.typeText(s)
            case .erase: Focus.backspace(1)
            }
        }
    }

    enum Landed { case typed, pasted, copied }

    /// The take (or Enter piece) is over: the final reading goes in. What is in the field stays where it already says
    /// the same; what changed is fixed in place when it is small (or only marks), else the field stays as typed and the
    /// final text goes to the clipboard. Returns how it went in (a paste holds his clipboard for a moment).
    @discardableResult
    private func liveFinish(_ final: String, tail: String, piece: Bool) -> Landed {
        flushTimer?.invalidate(); flushTimer = nil
        let what = piece ? "piece" : "take"
        defer { meter.reset() }
        func report(_ end: String) {
            log("live field (\(what)): \(landedWords) words in \(meter.steps) steps while talking, \(meter.summary); "
                + "fixed \(fixedChars) chars while talking; end: \(end)")
        }
        if lost {
            History.copy(final); keptNote = true
            report("field left, \(final.count) chars copied")
            return .copied
        }
        // nothing typed in this piece yet and no earlier run: a plain insert (one paste for a long text)
        if run.isEmpty, doneBefore.isEmpty {
            let (s, why) = Focus.spot(skip: [])
            if testing, !(s?.value.contains("⟦drafter-test⟧") ?? false) { report("no test field"); return .copied }
            guard let s else {
                if !testing, Focus.pasteTarget(why) { Focus.paste(final + tail, restore: false); report("pasted \(final.count) chars (\(why))"); return .pasted }
                History.copy(final); keptNote = true; report("no field (\(why)), copied"); return .copied
            }
            let text = LiveType.spaced(final, after: s.before.last) + tail
            if text.count <= 240 {   // a few words as keys: no clipboard, nothing to wait for
                Focus.typeText(text); runEl = s.el; runPid = s.app.processIdentifier; runBefore = text.last
                report("typed \(text.count) chars"); return Talk.control(text) ? .pasted : .typed
            }
            let how = Focus.insert(text, at: s)
            runEl = nil
            report("\(how) \(text.count) chars"); return how == "paste" ? .pasted : .typed
        }
        // the run must still be the end of the field: the same field with no key or click of his since it started, or
        // the field read back ending with it (Chromium's read can differ in spaces and breaks, 13-14 November)
        let s = Focus.spot(skip: []).0
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let same = runEl != nil && front == runPid && Keys.shared.editRevision == editRev && Focus.focused().map { CFEqual($0, runEl!) } == true
        let reads = s.map { $0.app.processIdentifier == runPid && Talk.plain($0.before).hasSuffix(Talk.plain(run)) } ?? false
        if runEl == nil, let s, reads { runBefore = s.before.last }   // a new run after his key: its first words go here
        guard same || reads, !testing || (s?.value.contains("⟦drafter-test⟧") ?? false),
              let want = runTarget(final) else {
            History.copy(final); keptNote = true; runEl = nil
            report("field changed under the run, \(final.count) chars copied")
            return .copied
        }
        let p = LiveType.plan(have: run, want: want, end: true)
        press(p.keys)
        let add = p.append + tail
        if !add.isEmpty { Focus.typeText(add) }
        runBefore = add.last ?? run.last
        if !p.left.isEmpty, p.marksOnly {
            report("+\(p.append.count) chars, fixed \(p.fixed) chars (\(p.keys.count) key steps), \(LiveType.touched(p.left)) chars of marks far back left as typed")
        } else if !p.left.isEmpty {
            History.copy(final); keptNote = true
            report("+\(p.append.count) chars, fixed \(p.fixed) chars (\(p.keys.count) key steps), left \(LiveType.touched(p.left)) chars as typed, final copied")
        } else {
            report("+\(p.append.count) chars, fixed \(p.fixed) chars (\(p.keys.count) key steps)")
        }
        if p.fixed > 0 { log("live typing: \(p.fixed) characters at the end corrected") }   // the old line, for week-on-week counts
        return Talk.control(add) || p.keys.contains(where: { if case .type(let t) = $0 { return Talk.control(t) }; return false }) ? .pasted : .typed
    }

    /// Focus.typeText pastes a text with a line break or another control character.
    private static func control(_ t: String) -> Bool {
        t.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x85 || $0.value == 0x2028 || $0.value == 0x2029 }
    }

    /// Into the field at the caret; with no text field, onto the clipboard.
    private func put(_ text: String) {
        let (s, why) = Focus.spot(skip: [])
        if testing, !(s?.value.contains("⟦drafter-test⟧") ?? false) {   // a test never writes outside its marked field
            log("voice test: focus moved to \(Focus.lastApp?.bundleIdentifier ?? "?"), not inserted"); return
        }
        if let s {
            let how = Focus.insert(text + " ", at: s)
            log("voice put \(how) \(s.app.bundleIdentifier ?? "?")")
            Entities.dictated(text)                               // names in the take wait for ⌥Tab (app/Entities.swift)
        } else if !testing, Focus.pasteTarget(why) {
            Focus.paste(text + " ", restore: false)
            log("voice put paste (\(why)) \(Focus.lastApp?.bundleIdentifier ?? "?")")
        } else {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
            Pill.shared.flash("Copied to clipboard")
        }
    }
}

extension Focus {
    /// Replace `old`, which sits right before the caret, with `new`. Only when the field still ends with it.
    static func replace(_ old: String, with new: String, done: @escaping (Bool) -> Void) {
        guard !old.isEmpty, !IsSecureEventInputEnabled(),
              let s = spot(skip: []).0, s.before.hasSuffix(old) else { done(false); return }
        if s.viaMarkers || isWeb(s.app) {
            // Rich fields cannot reliably set an AX range. Select with the same
            // marked arrow events as snippet fields, then verify before pasting.
            let revision = Keys.shared.inputRevision
            Fields.left(old.count, shift: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard !IsSecureEventInputEnabled(), Keys.shared.inputRevision == revision,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == s.app.processIdentifier,
                      let el = focused(), CFEqual(el, s.el), selection() == old else {
                    // Undo our Shift+Left selection even on a revision/selection
                    // mismatch. Never send recovery keys into another field.
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == s.app.processIdentifier,
                       let el = focused(), CFEqual(el, s.el), selection() != "" {
                        Fields.right(1)
                    }
                    done(false); return
                }
                paste(new)
                done(true)
            }
            return
        }
        let n = (old as NSString).length
        var r = CFRange(location: s.caret - n, length: n)
        guard let v = AXValueCreate(.cfRange, &r),
              AXUIElementSetAttributeValue(s.el, kAXSelectedTextRangeAttribute as CFString, v) == .success,
              let sel: String = attr(s.el, kAXSelectedTextAttribute), sel == old else { done(false); return }
        if AXUIElementSetAttributeValue(s.el, kAXSelectedTextAttribute as CFString, new as CFString) == .success,
           let now: String = attr(s.el, kAXValueAttribute), now.contains(new) { done(true); return }
        paste(new)   // the old words are selected, so a paste replaces them
        done(true)
    }
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

/// How much memory the Mac has free, as macOS itself counts it (kern.memorystatus_level, %). Under `low` a long
/// reading puts the text model to sleep (2026-11-01, Andrii: "not to overload the Mac").
enum Budget {
    static let low = 35
    /// Readings that want the text model asleep, and one request at a time to the engine: what the engine should
    /// be is the only thing compared, so a fast reading, two readings at once or a sleep right after a wake always
    /// end in the right state (Codex round 4). Main thread only.
    private static var holds = 0, asleep = false, busy = false, secs = 120.0

    /// Idle sleep (2026-11-14): no typing request for `textIdleMin` minutes -> the text model sleeps (~2.2 GB back);
    /// focus arriving in a text field (/prefill, Keys.warmField) or any typing request wakes it, and the field is
    /// prefilled again once it is back, so the first ghost costs what it did before. One-off prompts load it on demand.
    private static var idle = false, lastTyping = Date(), wokeFor: Date?
    static let typingPaths: Set<String> = ["/complete", "/prefill", "/chip", "/pause"]

    /// Engine.post / stream: a typing request is a sign of life; while idle-asleep it wakes the model.
    static func request(_ path: String) {
        guard typingPaths.contains(path) else { return }
        guard Thread.isMainThread else { DispatchQueue.main.async { request(path) }; return }
        lastTyping = Date()
        guard idle else { return }
        idle = false; wokeFor = Date()
        log("memory: text model wakes (\(path))")
        sync()
    }

    /// Every second (the app's 1 s timer): asleep after `textIdleMin` minutes without typing, never mid-take.
    static func idleCheck() {
        let mins = Drafter.shared.settings.textIdleMin
        guard mins > 0, !idle, Talk.shared.state == .idle, Date().timeIntervalSince(lastTyping) > Double(mins) * 60 else { return }
        idle = true
        log("memory: text model idle \(mins) min, sleeps")
        sync()
    }

    static func rest(secs s: Double, why: String) {
        holds += 1; secs = max(secs, s)
        log("memory: text model steps aside (\(why))")
        sync()
    }

    static func wake() { holds = max(0, holds - 1); sync() }

    private static func sync() {
        let want = holds > 0 || idle
        guard !busy, want != asleep else { return }
        busy = true
        // a reading's sleep has a timer in the engine; an idle one has none (only a wake ends it)
        let body: [String: Any] = holds > 0 ? ["secs": secs] : ["idle": true]
        Engine.shared.post(want ? "/sleep" : "/wake", want ? body : [:], timeout: 30) { j in
            busy = false
            if want {
                asleep = j?["slept"] != nil
                log("memory: text model asleep, \(j?["claude_stopped"] as? Int ?? 0) idle Claude helpers stopped")
            } else {
                asleep = false; secs = 120
                let ms = wokeFor.map { Int(Date().timeIntervalSince($0) * 1000) }
                log("memory: text model back (\(j?["woke"] as? Bool == true ? "ok" : "later"))" + (ms.map { ", \($0) ms after the wake sign, load \(j?["load_s"] as? Double ?? 0) s" } ?? ""))
                if wokeFor != nil { wokeFor = nil; Keys.shared.warmField() }   // the field's prefill hit a sleeping model
            }
            if j != nil { sync() }   // the engine down: nothing to put to sleep; its own timer wakes it anyway
        }
    }

    static func free() -> Int {
        var v: Int32 = 0
        var n = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &v, &n, nil, 0) == 0 ? Int(v) : -1
    }
}
