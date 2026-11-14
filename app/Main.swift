// Drafter: grey ghost text at the caret in any app, from a small model on this Mac. Tab takes it; any other key drops
// it. Task-like lines ("створи зустріч з Савою у вівторок о 15") get a chip instead; Tab runs exactly what it shows.
import AppKit
import Carbon
import ApplicationServices
import EventKit
import IOKit.ps
import ScreenCaptureKit

enum Home {
    static let root: URL = {
        let p = Bundle.main.object(forInfoDictionaryKey: "DrafterHome") as? String ?? NSHomeDirectory() + "/Codius/Drafter"
        return URL(fileURLWithPath: p)
    }()
    static let data = root.appendingPathComponent("data")
    static let settings = data.appendingPathComponent("settings.json")
    /// The live dictionary (his contacts and projects): untracked in data/ since 2026-11-14. Moved once from the old
    /// tracked dictionary/words.json, a link left there for Voice Notes; the engine does the same (engine/dictionary.py).
    static let words: URL = {
        let new = data.appendingPathComponent("words.json"), old = root.appendingPathComponent("dictionary/words.json")
        let fm = FileManager.default
        let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path), !oldIsLink {
            try? fm.createDirectory(at: data, withIntermediateDirectories: true)
            if (try? fm.moveItem(at: old, to: new)) != nil { try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: "../data/words.json") }
        }
        return new
    }()
    static let python = root.appendingPathComponent(".venv/bin/python")
    static let server = root.appendingPathComponent("engine/server.py")
    static let port = 8798
    /// Set at build time from the local config (app/build.sh); test notifications are named after it.
    static let bundleID = Bundle.main.bundleIdentifier ?? "drafter"
}

/// One formatter for every log line (thread safe; making one per line cost ~50 µs of the ~77 µs a line took).
private let logStamp = ISO8601DateFormatter()

func log(_ s: String, file: String = "app.log") {
    let line = logStamp.string(from: Date()) + " " + s + "\n"
    guard let h = appendHandle(Home.data.appendingPathComponent(file)) else { return }
    h.write(line.data(using: .utf8)!); try? h.close()
}

/// A log file opened for appending (O_APPEND, created if missing). The nightly's scripts/rotate_logs.py copies and
/// truncates engine.log and voice-engine.log while the engines hold them; with O_APPEND their next write lands at the
/// new end instead of at the old offset (a hole of zeros). app.log is opened per line, so a rename is safe for it.
func appendHandle(_ url: URL) -> FileHandle? {
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

/// Debug detail (suggestion text) goes to the log only while data/debug exists.
var debugLog: Bool { FileManager.default.fileExists(atPath: Home.data.appendingPathComponent("debug").path) }

/// `open -n -a Drafter --args --type <bundle id> "text"`: types into that app as real key events, for tests.
/// Stops at once if any other app comes to the front, or if the focused field does not contain the test marker
/// ⟦drafter-test⟧ (2026-10-18: a test without it typed into an open note).
/// \t = Tab, ↓ = down arrow, → = one word, ⎋ = Esc, ⌃ = Control+Return, ‖ = wait 1.5 s, ¶ = Return.
/// Fix marks (with data/debug): ← left arrow, ◌ mouse over the last fixed word, ◉ click its chip, ⎙ picture into data/.
/// Rework: ⇤ select to the line start, ⌥ ⌥Tab, Ⓟ picture of the rework list into data/rework-N.png.
enum TestTyper {
    static var shots = 0
    static var lastMark: [Double]?
    static func run(_ s: String, into bundle: String) {
        log("typer start \(bundle)")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { app.activate(); Focus.wake(app) }
        Thread.sleep(forTimeInterval: 1.5)
        log("typer front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") trusted=\(Focus.trusted())")
        func front() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle }
        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down); e?.flags = flags; e?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        for ch in s {
            RunLoop.current.run(until: Date())
            guard front() else { log("typer stopped: other app in front"); print("stopped: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") is in front"); exit(2) }
            guard let el = Focus.focused(), let v: String = Focus.attr(el, kAXValueAttribute), v.contains("⟦drafter-test⟧") else {
                log("typer stopped: no test marker in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") field \((Focus.focused().flatMap { Focus.attr($0, kAXRoleAttribute) as String? }) ?? "none")"); exit(3)
            }
            switch ch {
            case "\t": key(48)
            case "→": key(124)
            case "⎋": key(53)
            case "⌃": key(36, .maskControl)
            case "¶": key(36)
            case "⇟": key(125, .maskCommand)   // to the end of the text
            case "Ⓐ": key(0, .maskCommand)     // select all (to clear a test draft)
            case "⇤": key(123, [.maskCommand, .maskShift])   // select to the line start
            case "⌥": key(48, .maskAlternate)                // ⌥Tab: the rework list on a selection
            case "Ⓔ": key(53, .maskShift)                    // ⇧Esc: no more call offers in that app
            case "Ⓟ": DistributedNotificationCenter.default().postNotificationName(Notification.Name(Home.bundleID + ".reworkshot"), object: nil, userInfo: nil, deliverImmediately: true)
            case "⌫": key(51)
            case "Ⓦ": key(13, .maskCommand)    // close the test tab or window
            case "‖": Thread.sleep(forTimeInterval: 1.5)
            case "←": key(123)
            case "↓": key(125)
            case "Ⓡ": log("typer value «\(v.suffix(120).replacingOccurrences(of: "\n", with: "⏎"))»")   // what the field holds now
            case "◌", "◉", "⎙":
                let j = (try? Data(contentsOf: Home.data.appendingPathComponent("fixmarks.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let mark = (j["marks"] as? [[Double]])?.last ?? TestTyper.lastMark, chip = j["chip"] as? [Double]
                if mark != nil { TestTyper.lastMark = mark }
                if ch == "◌", let r = mark {
                    let p = CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2)
                    CGWarpMouseCursorPosition(p)
                    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                } else if ch == "◉", let r = chip {
                    let p = CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2)
                    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                } else if ch == "⎙", let r = mark {
                    TestTyper.shots += 1
                    let out = Home.data.appendingPathComponent("fixmark-\(TestTyper.shots).png"), done = DispatchSemaphore(value: 0)
                    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
                        guard let d = c?.displays.first else { done.signal(); return }
                        let cfg = SCStreamConfiguration(); cfg.sourceRect = CGRect(x: r[0] - 160, y: r[1] - 50, width: 420, height: 100)
                        cfg.width = 840; cfg.height = 200
                        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                            if let img, let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                            }
                            done.signal()
                        }
                    }
                    _ = done.wait(timeout: .now() + 3)
                } else { log("typer: no fix mark for \(ch)") }
            default:
                var u = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                    e?.flags = []   // never inherit ⌘ from the key before
                    e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); e?.post(tap: .cghidEventTap)
                }
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
        Thread.sleep(forTimeInterval: 0.3)
        log("typer done")
        exit(0)
    }
}

// MARK: settings

struct Settings: Codable {
    var paused = false
    var skip: [String] = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Terminal",
                          "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.dt.Xcode", "com.microsoft.VSCode",
                          "com.todesktop.230313mzl4w4u92", "com.apple.loginwindow", "com.apple.systempreferences",
                          "com.apple.ScreenSharing", Home.bundleID] + LocalConfig.skipApps
    var model: String? = nil
    var lookVariant: String? = nil   // hidden: "a" pixel instrument, "b" places with character; nil = the base look (2026-11-14)
    var actions_off: [String] = []
    var voice = false          // Right Option = voice (menu or /settings)
    var voiceFast: String? = nil     // model ID or local path; read on next voice process start
    var voiceCareful: String? = nil  // preserve model choices when any app setting is saved
    var voiceLive = false      // settled words typed while he talks; off since 2026-10-19 (Andrii: preview on top, paste on Enter)
    var adapter: String? = nil // LoRA trained on his writing (data/adapters), loaded on top of the model
    var fmt: String? = nil     // prompt shape: raw (default) or bare (no examples up front, for the trained model)
    var learn = true           // keep lines he sends (Return) in data/typed.jsonl for the phrase memory, local only
    var screen = true          // read the screen above the caret when the app gives little text (Screen Recording)
    var keepMic = false        // keep the microphone running between takes: the take starts 0.6 s before the press (orange dot stays on)
    var nextMessage = false    // an empty chat or AI box shows his likely next message by itself (Claude Haiku), Tab puts it in
    var shots = true           // screenshots while a long note or call records, for brief.md (Screen Recording, local only)
    var callNotes = false      // a call or long note: Claude Haiku writes the live outline and the call summary from the transcript text; off = the local model (engine/cloud.py)
    var autocorrect = true     // fix typos when a word ends (macOS spellchecker + his own words; Backspace takes it back)
    var autocorrectMode = "offer" // "offer": a fix found at a word end shows as "→ word" and Tab puts it in; "replace": put in at once (before 13 November 2026)
    var autocorrectUk = false  // Ukrainian typos too (off: the Ukrainian dictionary misses many real forms)
    var layoutFix = true       // a word typed in the wrong layout (ghbdsn -> привіт) is fixed and the keyboard switches; double Shift by hand
    var claudeTyping = false   // on a pause Claude writes the rest of the sentence with today's context (his signed-in claude CLI)
    var claudeModel = "sonnet" // sonnet or haiku (haiku answers ~0.5 s sooner)
    var proofread = false      // at a 1.2 s rest Claude proofreads the message; a "Fix N" chip, Tab puts the fixes in (app/Proof.swift)
    var proofreadOff: [String] = ["ai"] // app kinds (AppKind: ai, chat, mail, other) where proofread stays quiet: a prompt to an AI needs no clean spelling
    var rework = false         // ⌥Tab on a selection: shorter, fix, clearer, warmer, formal, list, translate or his own words (app/Rework.swift)
    var fixWord = true         // the word being typed is no word he writes but one is a letter or a layout away: "→ word" at the caret, Tab swaps it (app/Fixer.swift)
    var translate = false      // Ukrainian in an English chat (or back), or ;en / ;uk at the end: the message in the other language as a chip (app/Translate.swift)
    var minGhost = 5           // grey text that adds fewer letters is not shown (2026-11-13: under 5 he took 3%); 0 = all
    var predictKeys = true     // ask for a suggestion at the key itself for the field + that letter (no 35 ms wait, 2026-11-13)
    var streamGhost = true     // two-step ghost: the first sure words at once, the rest grows in place (round two)
    var longGhostsAI = true    // a lighter tail of up to 8 words after the sure words in AI apps (round two)
    var longGhostsChats = false  // the same in chats and everywhere else
    var claudePause = false    // Claude's rest of the sentence on a typing pause (under claudeTyping); round two proposes off
    var facts = false          // a question on screen that his calendar or saved texts answer: the answer as a chip (app/Facts.swift)
    var callOff: [String] = ["notion.id"]   // call apps that never get a record offer (Notion: its own meeting notes hold the mic)
    var calendarsOff: [String] = []         // EventKit calendars left out of call names and free times (other tools' calendars)
    var voiceIdleMin = 30      // Parakeet is dropped after this many minutes without a take (read at voice start; was 4 h until 2026-11-14)
    var textIdleMin = 30       // the text model sleeps after this many minutes without typing, wakes when a field gets focus; 0 = never (2026-11-14)
    var quickKey = QuickRules.defaultKey    // the Quick panel's global key (app/Quick.swift); "" = off; never ⌃⌥Space or ⌘Space (Aleph)
    var quickMax = 1000, quickDays = 30.0   // clipboard history: at most this many rows, none older (0 days = no age limit)
    var quickSecret = QuickRules.defaultSecrets   // patterns of copies never kept: API keys, card numbers, one-time codes
    var switchKey = "⌘⇧V", switchFormat = false   // the paste switcher (app/Quick.swift); false: it puts plain text in
    var clipImageMB = 8, clipTotalMB = 300   // copied pictures kept in data/clips/: each at most, all together at most (0 = none kept)
    var captureKey = "⌃⌥S"                    // quick capture (app/Capture.swift); "" = off
    // keys round (14 November 2026, app/KeyRules.swift)
    var tabBack = true         // Backspace right after Tab takes that Tab's words out and shows the grey text again
    var escPause = true        // Esc twice in a field with a ghost pauses ghosts there for 10 minutes; twice again resumes
    var againKey = "⌃⌥R"       // the last voice take in again at the caret (app/Quick.swift); "" = off
    var switchSwap = true      // ⌘⇧V again within 2 s of a switcher paste swaps it for the next older copy
    var entityClassify = false // a kind for a name no source knows: Claude Haiku gets the name only (engine/entities.py); off = local model or nothing
    var contextPacks = true    // in AI apps a name he types or says gets a quiet mark, ⌥Tab attaches its context pack (app/Entities.swift)
    var contextLevelAI = 2, contextLevelAgent = 3   // default pack level: 1 name, 2 one line, 3 full (chat assistants, coding agents)

    init() {}
    init(from d: Decoder) throws {   // missing keys keep their defaults, so a file written by the engine still loads
        let c = try d.container(keyedBy: CodingKeys.self)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        skip = try c.decodeIfPresent([String].self, forKey: .skip) ?? Settings().skip
        model = try c.decodeIfPresent(String.self, forKey: .model)
        lookVariant = try? c.decodeIfPresent(String.self, forKey: .lookVariant)
        actions_off = try c.decodeIfPresent([String].self, forKey: .actions_off) ?? []
        voice = try c.decodeIfPresent(Bool.self, forKey: .voice) ?? false
        voiceFast = try? c.decodeIfPresent(String.self, forKey: .voiceFast)
        voiceCareful = try? c.decodeIfPresent(String.self, forKey: .voiceCareful)
        voiceLive = try c.decodeIfPresent(Bool.self, forKey: .voiceLive) ?? false
        learn = try c.decodeIfPresent(Bool.self, forKey: .learn) ?? true
        adapter = try c.decodeIfPresent(String.self, forKey: .adapter)
        fmt = try c.decodeIfPresent(String.self, forKey: .fmt)
        screen = try c.decodeIfPresent(Bool.self, forKey: .screen) ?? true
        nextMessage = try c.decodeIfPresent(Bool.self, forKey: .nextMessage) ?? false
        keepMic = try c.decodeIfPresent(Bool.self, forKey: .keepMic) ?? false
        shots = try c.decodeIfPresent(Bool.self, forKey: .shots) ?? true
        callNotes = try c.decodeIfPresent(Bool.self, forKey: .callNotes) ?? false
        autocorrect = try c.decodeIfPresent(Bool.self, forKey: .autocorrect) ?? true
        autocorrectMode = (try? c.decodeIfPresent(String.self, forKey: .autocorrectMode)) == "replace" ? "replace" : "offer"
        layoutFix = try c.decodeIfPresent(Bool.self, forKey: .layoutFix) ?? true
        autocorrectUk = try c.decodeIfPresent(Bool.self, forKey: .autocorrectUk) ?? false
        claudeTyping = try c.decodeIfPresent(Bool.self, forKey: .claudeTyping) ?? false
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? "sonnet"
        proofread = try c.decodeIfPresent(Bool.self, forKey: .proofread) ?? false
        proofreadOff = (try? c.decodeIfPresent([String].self, forKey: .proofreadOff)) ?? Settings().proofreadOff
        facts = try c.decodeIfPresent(Bool.self, forKey: .facts) ?? false
        minGhost = try c.decodeIfPresent(Int.self, forKey: .minGhost) ?? 5
        predictKeys = try c.decodeIfPresent(Bool.self, forKey: .predictKeys) ?? true
        streamGhost = try c.decodeIfPresent(Bool.self, forKey: .streamGhost) ?? true
        longGhostsAI = try c.decodeIfPresent(Bool.self, forKey: .longGhostsAI) ?? true
        longGhostsChats = try c.decodeIfPresent(Bool.self, forKey: .longGhostsChats) ?? false
        claudePause = try c.decodeIfPresent(Bool.self, forKey: .claudePause) ?? false
        translate = try c.decodeIfPresent(Bool.self, forKey: .translate) ?? false
        fixWord = try c.decodeIfPresent(Bool.self, forKey: .fixWord) ?? true
        rework = try c.decodeIfPresent(Bool.self, forKey: .rework) ?? false
        callOff = try c.decodeIfPresent([String].self, forKey: .callOff) ?? Settings().callOff
        calendarsOff = try c.decodeIfPresent([String].self, forKey: .calendarsOff) ?? []
        textIdleMin = (try? c.decodeIfPresent(Int.self, forKey: .textIdleMin)) ?? 30
        voiceIdleMin = (try? c.decodeIfPresent(Int.self, forKey: .voiceIdleMin)) ?? 30
        quickKey = (try? c.decodeIfPresent(String.self, forKey: .quickKey)) ?? QuickRules.defaultKey
        quickMax = (try? c.decodeIfPresent(Int.self, forKey: .quickMax)) ?? 1000
        quickDays = (try? c.decodeIfPresent(Double.self, forKey: .quickDays)) ?? 30
        quickSecret = (try? c.decodeIfPresent([String].self, forKey: .quickSecret)) ?? QuickRules.defaultSecrets
        switchKey = (try? c.decodeIfPresent(String.self, forKey: .switchKey)) ?? "⌘⇧V"
        switchFormat = (try? c.decodeIfPresent(Bool.self, forKey: .switchFormat)) ?? false
        entityClassify = try c.decodeIfPresent(Bool.self, forKey: .entityClassify) ?? false
        contextPacks = (try? c.decodeIfPresent(Bool.self, forKey: .contextPacks)) ?? true
        contextLevelAI = min(3, max(1, (try? c.decodeIfPresent(Int.self, forKey: .contextLevelAI)) ?? 2))
        contextLevelAgent = min(3, max(1, (try? c.decodeIfPresent(Int.self, forKey: .contextLevelAgent)) ?? 3))
        connect = (try? c.decodeIfPresent(Connection.self, forKey: .connect)) ?? Connection()
        clipImageMB = (try? c.decodeIfPresent(Int.self, forKey: .clipImageMB)) ?? 8
        clipTotalMB = (try? c.decodeIfPresent(Int.self, forKey: .clipTotalMB)) ?? 300
        captureKey = (try? c.decodeIfPresent(String.self, forKey: .captureKey)) ?? "⌃⌥S"
        tabBack = (try? c.decodeIfPresent(Bool.self, forKey: .tabBack)) ?? true
        escPause = (try? c.decodeIfPresent(Bool.self, forKey: .escPause)) ?? true
        againKey = (try? c.decodeIfPresent(String.self, forKey: .againKey)) ?? "⌃⌥R"
        switchSwap = (try? c.decodeIfPresent(Bool.self, forKey: .switchSwap)) ?? true
    }
    /// Claude switches (engine/cloud.py) are off for a new install since 2026-11-14. Once, before decoding, a file
    /// written earlier gets today's effective value (on) of each one it does not name, and the mark; cloud.migrate()
    /// in the engine does the same, whichever runs first.
    static let cloudKeys = ["claudeTyping", "claudePause", "proofread", "facts", "translate", "rework", "nextMessage", "callNotes", "entityClassify"]
    static let neverOn: Set<String> = ["entityClassify"]   // new that day, never on before: stays off (engine/cloud.py NEVER_ON)
    var cloudDefaults = "off"
    /// "Connect a model" (app/Connect.swift, engine/provider.py): which way is connected, never a key. Empty = local only.
    struct Connection: Codable, Equatable {
        var provider = ""                       // "", "cli", "anthropic", "openai"
        var fastModel = "claude-haiku-5-5"      // the fast helpers on the Anthropic path
        var carefulModel = "claude-sonnet-5-5"  // proofread and rework on the Anthropic path
        var baseURL = ""                        // an OpenAI-compatible endpoint (or a stand-in Anthropic URL)
        var apiModel = ""                       // the model name at that endpoint
        var connected: Bool { !provider.isEmpty }
        init() {}
        init(from d: Decoder) throws {   // a missing key keeps its default ({"provider": "cli"} from the migration)
            let c = try d.container(keyedBy: CodingKeys.self), z = Connection()
            provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? nil ?? z.provider
            fastModel = (try? c.decodeIfPresent(String.self, forKey: .fastModel)) ?? nil ?? z.fastModel
            carefulModel = (try? c.decodeIfPresent(String.self, forKey: .carefulModel)) ?? nil ?? z.carefulModel
            baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? nil ?? z.baseURL
            apiModel = (try? c.decodeIfPresent(String.self, forKey: .apiModel)) ?? nil ?? z.apiModel
        }
    }
    var connect = Connection()
    static func migrateCloud() {
        guard let d = try? Data(contentsOf: Home.settings),
              var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], j["cloudDefaults"] == nil else { return }
        for k in cloudKeys where j[k] == nil { j[k] = !neverOn.contains(k) }
        if j["connect"] == nil { j["connect"] = ["provider": "cli"] }   // the signed-in CLI was the one way before
        j["cloudDefaults"] = "off"
        if let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: Home.settings, options: .atomic)
        }
    }
    static func load() -> Settings {
        migrateCloud()
        guard let d = try? Data(contentsOf: Home.settings), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Home.settings)
    }
}

// MARK: engine process

final class Engine {
    static let shared = Engine()
    var proc: Process?
    var wanted = false
    var ready = false
    var info = "starting"
    var restarts: [Date] = []
    var clearedLeftovers = false

    func start() {
        wanted = true
        guard proc == nil else { return }
        if !clearedLeftovers {   // an engine left from an earlier app run holds the port; only once, at app start
            clearedLeftovers = true
            let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-f", Home.server.path]
            try? k.run(); k.waitUntilExit()
        }
        let p = Process()
        p.executableURL = Home.python
        p.arguments = [Home.server.path]
        var env = ProcessInfo.processInfo.environment
        env["DRAFTER_CAP_GB"] = env["DRAFTER_CAP_GB"] ?? "3.6"
        let st = Settings.load()
        if let m = st.model { env["DRAFTER_MODEL"] = m }
        if let a = st.adapter { env["DRAFTER_ADAPTER"] = a.hasPrefix("/") ? a : Home.root.appendingPathComponent(a).path }
        if let f = st.fmt { env["DRAFTER_FMT"] = f }
        p.environment = env
        if let h = appendHandle(Home.data.appendingPathComponent("engine.log")) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] t in
            DispatchQueue.main.async {
                // only the engine running now counts: an old one ending after a model switch must not touch the new
                guard let self, self.proc === t else { return }
                self.proc = nil; self.ready = false
                log("engine exited \(t.terminationStatus)")
                guard self.wanted else { self.info = "stopped"; Menu.shared.refresh(); return }
                self.restarts = self.restarts.filter { $0.timeIntervalSinceNow > -300 } + [Date()]
                if self.restarts.count > 4 { self.info = "engine keeps stopping, see data/engine.log"; self.wanted = false; Menu.shared.refresh(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.wanted { self.start() } }
            }
        }
        do { try p.run(); proc = p; info = "loading model"; startedAt = Date() } catch { info = "cannot start engine: \(error)" }
        poll()
    }

    func stop() {
        wanted = false; ready = false
        proc?.terminate(); proc = nil
        info = "stopped"
    }

    private var startedAt: Date?
    func poll(_ tries: Int = 0) {
        get("/health") { j in
            if let j, j["ok"] as? Bool == true {
                self.ready = true
                Connect.handOver()   // an API key from the Keychain into the engine's memory (never a file or argv)
                // launch to ready, for the efficiency notes (polled every 0.5 s, so up to 0.5 s late)
                if let t = self.startedAt { log(String(format: "engine: ready %.1f s after start", Date().timeIntervalSince(t))); self.startedAt = nil }
                let m = (j["model"] as? String ?? "").split(separator: "/").last.map(String.init) ?? ""
                self.info = "\(m) · \(String(format: "%.1f", j["rss_gb"] as? Double ?? 0)) GB · \(j["words"] as? Int ?? 0) words"
                Menu.shared.refresh()
            } else if self.proc != nil, tries < 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.poll(tries + 1) }
            }
        }
    }

    /// Two-step ghost (round two, 2026-11-13): the engine answers one JSON object per line, the first words as soon as
    /// they exist, then the whole answer ("final": true). `each` gets every line before the last on the main thread,
    /// `done` the last one (nil on an error), as `post` does.
    func stream(_ path: String, _ body: [String: Any], timeout: Double = 3, each: @escaping ([String: Any]) -> Void,
                _ done: @escaping ([String: Any]?) -> Void) {
        Budget.request(path)
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(Home.port)\(path)")!)
        r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body.merging(["stream": true]) { _, b in b })
        let req = r
        Task.detached {
            var last: [String: Any]?
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    if j["final"] as? Bool == true { last = j; break }
                    DispatchQueue.main.async { each(j) }
                }
            } catch {}
            let end = last
            DispatchQueue.main.async { done(end) }
        }
    }

    func get(_ path: String, timeout: Double = 2, _ done: @escaping ([String: Any]?) -> Void) {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(Home.port)\(path)")!); r.timeoutInterval = timeout
        URLSession.shared.dataTask(with: r) { d, _, _ in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(j) }
        }.resume()
    }

    func post(_ path: String, _ body: [String: Any], timeout: Double = 3, _ done: @escaping ([String: Any]?) -> Void = { _ in }) {
        Budget.request(path)
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(Home.port)\(path)")!)
        r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(j) }
        }.resume()
    }
}

// MARK: battery

enum Battery {
    /// (on battery, percent)
    static func state() -> (Bool, Int) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, 100) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100, mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return (onBattery, mx > 0 ? cur * 100 / mx : 100)
        }
        return (false, 100)
    }
}

// MARK: app

final class Drafter {
    static let shared = Drafter()
    var settings = Settings.load()
    var lowBattery = false
    var active: Bool { !settings.paused && !lowBattery }

    func apply() {
        if active { Engine.shared.start() } else { Engine.shared.stop(); Ghost.shared.hide() }
        Menu.shared.refresh()
    }

    var settingsStamp: Date? = (try? FileManager.default.attributesOfItem(atPath: Home.settings.path))?[.modificationDate] as? Date

    /// Settings changed from outside are seen by file events, not a 1 s check (2026-11-14): data/ itself (the engine
    /// writes settings.tmp and renames it over settings.json, a new file) and settings.json (an edit in place).
    /// reloadIfChanged still compares the date, so any other file event in data/ costs one stat.
    private var settingsWatch: [DispatchSourceFileSystemObject] = []
    func watchSettings() {
        settingsWatch.forEach { $0.cancel() }; settingsWatch = []
        let watched: [(String, DispatchSource.FileSystemEvent)] = [(Home.data.path, .write),
                                                                   (Home.settings.path, [.write, .extend, .attrib, .delete, .rename])]
        for (path, mask) in watched {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                self.reloadIfChanged()
                // settings.json replaced (a new inode) or removed: watch the file that is there now
                if Self.inode(Home.settings.path) != self.watchedInode { self.watchSettings() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            settingsWatch.append(src)
        }
        watchedInode = Self.inode(Home.settings.path)
    }
    private var watchedInode: UInt64 = 0
    private static func inode(_ path: String) -> UInt64 {
        var st = stat(); return lstat(path, &st) == 0 ? UInt64(st.st_ino) : 0
    }

    /// Settings changed from outside (Aleph through the engine's /settings): take them over.
    func reloadIfChanged() {
        let m = (try? FileManager.default.attributesOfItem(atPath: Home.settings.path))?[.modificationDate] as? Date
        guard m != settingsStamp else { return }
        settingsStamp = m
        let was = settings
        settings = Settings.load()
        if was.keepMic != settings.keepMic || was.voice != settings.voice {
            MicCapture.keepReady = settings.keepMic && settings.voice
            if settings.voice || MicCapture.shared != nil { MicCapture.prepare() }
        }
        if was.voice != settings.voice {
            if settings.voice { VoiceEngine.shared.preload() } else { Talk.shared.cancel(); VoiceEngine.shared.stop() }

        }
        if was.paused != settings.paused || was.model != settings.model || was.adapter != settings.adapter || was.fmt != settings.fmt {
            if was.model != settings.model || was.adapter != settings.adapter || was.fmt != settings.fmt { Engine.shared.stop() }
            apply()
        }
    }

    func checkBattery() {
        let (onBattery, pct) = Battery.state()
        let low = onBattery && pct < 20
        if low != lowBattery { lowBattery = low; log("battery \(pct)% on battery=\(onBattery): auto-pause \(low)"); apply() }
    }
}

final class Menu: NSObject, NSMenuDelegate {
    static let shared = Menu()
    var item: NSStatusItem!
    let menu = NSMenu()

    func setup() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        let t = Drafter.shared
        // a pen on a line = Drafter (2026-10-21, Andrii: the cursor icon was confusing); slashed when paused
        let name = Talk.shared.recording ? "record.circle" : SecureInput.holder != nil ? "lock" : t.active ? (Engine.shared.ready ? "pencil.line" : "hourglass") : "pencil.slash"
        item?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Drafter")
        item?.button?.toolTip = SecureInput.holder.map { "\($0) holds secure input: typed keys are hidden from Drafter (Enter, Tab, suggestions). Click out of its password field or reload it." }
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let t = Drafter.shared
        let state = t.settings.paused ? "Paused" : t.lowBattery ? "Paused: battery below 20%" : Engine.shared.info
        m.addItem(withTitle: state, action: nil, keyEquivalent: "").isEnabled = false
        if Talk.shared.recording {   // first thing in the menu while a call or long note records
            m.addItem(.separator())
            let stop = m.addItem(withTitle: Talk.shared.isCall ? "■ Stop recording the call" : "■ Stop the long note", action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self; stop.toolTip = "Same as ⇧ right ⌥. The transcript and the note follow."
        }
        if !Focus.trusted() { m.addItem(withTitle: "Allow Accessibility…", action: #selector(askTrust), keyEquivalent: "").target = self }
        m.addItem(.separator())
        m.addItem(withTitle: "Open Drafter (recordings, clipboard, settings)", action: #selector(openCommand), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: t.settings.paused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "p").target = self
        m.addItem(withTitle: "Add a word…", action: #selector(addWord), keyEquivalent: "w").target = self
        m.addItem(Learn.menu()); Learn.refresh()   // fresh for the next open
        m.addItem(History.menu(title: "Recent takes", file: History.takesFile, n: 12))
        m.addItem(History.menu(title: "Clipboard history", file: History.clipFile, n: 20))
        m.addItem(withTitle: "Open notes and call recordings", action: #selector(openNotes), keyEquivalent: "").target = self
        let v = m.addItem(withTitle: "Voice on Right Option",
                          action: #selector(toggleVoice), keyEquivalent: "")
        v.target = self; v.state = t.settings.voice ? .on : .off
        if let app = Focus.lastApp, let id = app.bundleIdentifier {
            let skipped = t.settings.skip.contains(id)
            let i = m.addItem(withTitle: (skipped ? "Use in " : "Skip ") + (app.localizedName ?? id), action: #selector(toggleSkip), keyEquivalent: "")
            i.target = self; i.representedObject = id
        }
        let vl = m.addItem(withTitle: "Type into the field while I talk (old mode, off)", action: #selector(toggleLive), keyEquivalent: "")
        vl.target = self; vl.state = t.settings.voiceLive ? .on : .off
        let km = m.addItem(withTitle: "Keep the microphone ready: first word never lost (orange dot stays on)", action: #selector(toggleKeepMic), keyEquivalent: "")
        km.target = self; km.state = t.settings.keepMic ? .on : .off
        let nm = m.addItem(withTitle: "Suggest my next message in empty boxes (sends the chat to Claude)", action: #selector(toggleNext), keyEquivalent: "")
        nm.target = self; nm.state = t.settings.nextMessage ? .on : .off
        let l = m.addItem(withTitle: "Learn from what I send (on this Mac only)", action: #selector(toggleLearn), keyEquivalent: "")
        l.target = self; l.state = t.settings.learn ? .on : .off
        let sc = m.addItem(withTitle: "Read the screen when an app gives no text" + (t.settings.screen && !Screen.allowed ? " (needs Screen Recording)" : ""),
                           action: #selector(toggleScreen), keyEquivalent: "")
        sc.target = self; sc.state = t.settings.screen ? .on : .off
        let sh = m.addItem(withTitle: "Screenshots in long notes and calls (for the agent brief, on this Mac only)", action: #selector(toggleShots), keyEquivalent: "")
        sh.target = self; sh.state = t.settings.shots ? .on : .off
        m.addItem(withTitle: "Open dictionary", action: #selector(openDictionary), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Tab takes the next grey word or runs the chip", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: "Quit Drafter", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func stopRecording() { Talk.shared.stopRecording("the menu bar") }
    @objc func askTrust() { Focus.trusted(prompt: true) }
    @objc func togglePause() { Drafter.shared.settings.paused.toggle(); Drafter.shared.settings.save(); Drafter.shared.apply() }
    @objc func toggleSkip(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        var st = Drafter.shared.settings
        if let i = st.skip.firstIndex(of: id) { st.skip.remove(at: i) } else { st.skip.append(id) }
        Drafter.shared.settings = st; st.save()
    }
    @objc func toggleVoice() {
        var st = Drafter.shared.settings
        st.voice.toggle(); Drafter.shared.settings = st; st.save()
        if st.voice { VoiceEngine.shared.preload() } else { Talk.shared.cancel(); VoiceEngine.shared.stop() }
        log("voice on Right Option: \(st.voice)")
    }
    @objc func toggleLive() { var st = Drafter.shared.settings; st.voiceLive.toggle(); Drafter.shared.settings = st; st.save() }
    @objc func toggleKeepMic() {
        var st = Drafter.shared.settings; st.keepMic.toggle(); Drafter.shared.settings = st; st.save()
        MicCapture.keepReady = st.keepMic && st.voice; MicCapture.prepare()
    }
    @objc func toggleShots() {
        var st = Drafter.shared.settings; st.shots.toggle(); Drafter.shared.settings = st; st.save()
        if st.shots, !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }
    @objc func toggleNext() { var st = Drafter.shared.settings; st.nextMessage.toggle(); Drafter.shared.settings = st; st.save() }
    @objc func toggleLearn() { var st = Drafter.shared.settings; st.learn.toggle(); Drafter.shared.settings = st; st.save() }
    @objc func toggleScreen() {
        var st = Drafter.shared.settings; st.screen.toggle(); Drafter.shared.settings = st; st.save()
        if st.screen, !Screen.allowed { _ = CGRequestScreenCaptureAccess() }
    }
    @objc func openDictionary() { NSWorkspace.shared.open(Home.words) }
    @objc func openCommand() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AppWindow.shared.show() } }
    @objc func openNotes() {
        for d in ["notes", "calls"] { try? FileManager.default.createDirectory(at: Home.data.appendingPathComponent(d), withIntermediateDirectories: true) }
        NSWorkspace.shared.open(Home.data.appendingPathComponent("notes")); NSWorkspace.shared.open(Home.data.appendingPathComponent("calls"))
    }
    /// Quit from the menu. A long note or call that is recording asks first (2026-10-30: the "Ulis+Bp" call stopped at
    /// 29 min with a clean exit and no line in the log; a clean exit is not restarted, so Drafter stayed off for 55 min).
    @objc func quit() {
        if Talk.shared.recording {
            let a = NSAlert()
            a.messageText = Talk.shared.isCall ? "A call is recording" : "A long note is recording"
            a.informativeText = "Stop recording keeps Drafter running and makes the transcript and the note. Quit leaves the audio to be finished on the next start."
            a.addButton(withTitle: "Stop recording"); a.addButton(withTitle: "Keep recording"); a.addButton(withTitle: "Quit anyway")
            NSApp.activate(ignoringOtherApps: true)
            switch a.runModal() {
            case .alertFirstButtonReturn: Talk.shared.stopRecording("the quit question"); return
            case .alertSecondButtonReturn: log("quit: cancelled, a recording is running"); return
            default: break
            }
        }
        log("quit: from the menu")
        Engine.shared.stop(); NSApp.terminate(nil)
    }

    @objc func addWord() {
        let seed = Focus.selectedText() ?? ""
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Add a word"
        a.informativeText = "A name, term or phrase, written the way it should be spelled. Typing and voice both use it."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); f.stringValue = seed
        a.accessoryView = f; a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let w = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        Engine.shared.post("/words", ["text": w, "kind": w.contains(" ") ? "phrase" : "term"], timeout: 30) { j in
            Ghost.shared.flash(j?["ok"] as? Bool == true ? "Added: \(w)" : "Could not add \(w)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var timer: Timer?
    /// A click on the Dock icon (or `open` on a running Drafter) opens the command panel with recent recordings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindow.shared.show(); return false
    }

    static var lockFD: Int32 = -1   // held for the app's life (released by the system when it exits)

    func applicationDidFinishLaunching(_ n: Notification) {
        // one Drafter only (2026-10-21: two copies ran after a restart, so two event taps and two engines): a second
        // copy with no test arguments quits at once; exit 0, so launchd does not start it again
        // (2026-10-21) by a lock that only the real app takes: short test copies (--type, --ghost-preview, --shot) no
        // longer count, so a restart that overlaps a test does not leave Drafter down
        AppDelegate.lockFD = open(Home.data.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o644)
        if CommandLine.arguments.count == 1, AppDelegate.lockFD >= 0, flock(AppDelegate.lockFD, LOCK_EX | LOCK_NB) != 0 {
            log("second copy quit (one is already running)"); exit(0)
        }
        try? FileManager.default.createDirectory(at: Home.data, withIntermediateDirectories: true)
        Brief.me = LocalConfig.shortName
        CallDoc.me = LocalConfig.ownKeys
        Menu.shared.setup()
        Focus.trusted(prompt: true)
        Keys.shared.start()
        Drafter.shared.checkBattery()
        Drafter.shared.apply()
        // the minute timer also re-reads settings in case a file event was missed (the watch is the main path)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Drafter.shared.checkBattery(); Drafter.shared.reloadIfChanged() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in SecureInput.check() }
        if Drafter.shared.settings.voice { VoiceEngine.shared.preload() }   // the first press never waits for a load
        MicCapture.keepReady = Drafter.shared.settings.keepMic && Drafter.shared.settings.voice
        if Drafter.shared.settings.voice { MicCapture.prepare() }           // nor for the microphone to be built
        // test hook: show the voice strip for 4 s with a moving level and some words (bench/strip_shot.sh)
        for name in [Home.bundleID + ".striptest", Home.bundleID + ".rectest"] {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
            guard Talk.shared.state == .idle else { return }
            if note.name.rawValue.hasSuffix("rectest") {   // the recording bar of a long note / call
                var k = 0
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                    k += 1
                    Pill.shared.recording(call: true, seconds: 754 + k, title: "Звіти та демо",
                                          outline: ["Модуль складу в Northwind завершено, звіти ще не готові", "Міла перевірить податкову частину", "→ Сава: зробити звіти до пʼятниці"])
                    if k >= 5 { t.invalidate(); Pill.shared.hide() }
                }
                return
            }
            Pill.shared.listening()
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
                i += 1
                Pill.shared.level(Float(abs(sin(Double(i) / 3))) * 0.2)
                if i == 20 { Pill.shared.draft("хелоу як ти там можем голосом на тижні бо я хотів обговорити нашу тєму") }
                if i >= 80 { t.invalidate(); Pill.shared.hide() }
            }
        }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".ghostshot"), object: nil, queue: .main) { _ in Ghost.shared.shot() }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".reworkshot"), object: nil, queue: .main) { _ in Rework.shared.shot() }
        // the call offer strip without a call (object: a call app's bundle id); Tab only logs
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".offertest"), object: nil, queue: .main) { n in
            CallWatch.offer((n.object as? String) ?? "com.tinyspeck.slackmacgap", test: true)
        }
        // test hook: what an app's focused field looks like through Accessibility, from the background (read only)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".axprobe"), object: nil, queue: .main) { n in
            guard let arg = n.object as? String else { return }
            if arg.hasSuffix(" wait") {   // probe once he brings that app forward himself (up to 2 min)
                let id = arg.replacingOccurrences(of: " wait", with: ""), t0 = Date()
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                    if Date().timeIntervalSince(t0) > 120 { t.invalidate(); log("axprobe \(id): not brought forward"); return }
                    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id else { return }
                    t.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        DistributedNotificationCenter.default().postNotificationName(Notification.Name(Home.bundleID + ".axprobe"), object: id, userInfo: nil, deliverImmediately: true)
                    }
                }
                return
            }
            let front = arg.hasSuffix(" front"), id = arg.replacingOccurrences(of: " front", with: "")
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
            Focus.wake(app)
            if front, NSWorkspace.shared.frontmostApplication != app {   // bring it forward for a second, then back
                let prev = NSWorkspace.shared.frontmostApplication
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    DistributedNotificationCenter.default().postNotificationName(Notification.Name(Home.bundleID + ".axprobe"), object: id, userInfo: nil, deliverImmediately: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { prev?.activate() }
                }
                return
            }
            let a = AXUIElementCreateApplication(app.processIdentifier)
            var f: CFTypeRef?
            let own = AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f) == .success ? f.map { $0 as! AXUIElement } : nil
            guard let el = own ?? (NSWorkspace.shared.frontmostApplication == app ? Focus.focused() : nil) else { log("axprobe \(id): no focus"); return }
            if NSWorkspace.shared.frontmostApplication == app { log("axprobe \(id): spot says \(Focus.spot(skip: []).1)") }
            AXProbe.dump(el, id: id)
        }
        // test hook: a real press with the microphone, dropped after 2.5 s (nothing is pasted): press -> strip, mic, words
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".presstest"), object: nil, queue: .main) { _ in
            guard Talk.shared.state == .idle else { return }
            Talk.shared.key(down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let c = Talk.shared.clock
                log("voice timing (press test): strip \(c.ms(c.strip)) ms, mic \(c.ms(c.mic)) ms, first words \(c.ms(c.words)) ms after the press")
                Talk.shared.cancel()
            }
        }
        // test hook: screenshots as a long note takes them, 10 s into data/shots-test/<time>/ (no microphone, no note);
        // logs the count and whether a calendar event matches now. `object` "N" changes the seconds.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".shotstest"), object: nil, queue: .main) { n in
            let secs = Double(n.object as? String ?? "") ?? 10
            let dir = Home.data.appendingPathComponent("shots-test/" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let t0 = Date()
            let s = Shots(recording: dir) { Date().timeIntervalSince(t0) }
            s.start()
            let ev = Meeting.now()
            log("shots test: started for \(Int(secs)) s; calendar event now: " + (ev == nil ? "none" : "yes, \((ev?["people"] as? [String])?.count ?? 0) people"))
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                let kept = s.stop()
                Brief.write(dir: dir, rows: [Brief.Row(who: "", start: 1, text: "Shots test, no speech.")], shots: kept,
                            meta: ["call": false, "app": "test", "started": t0.timeIntervalSince1970], minutes: secs / 60)
                log("shots test: \(kept.count) kept in \(dir.lastPathComponent)")
            }
        }
        // read a saved recording again and save a new note: `object` = its folder in data/calls (same as Recordings › Read again)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".reread"), object: nil, queue: .main) { n in
            guard let path = n.object as? String, path.hasPrefix(Spool.root.path) else { return }
            Spool.reread(URL(fileURLWithPath: path))
        }
        // test hook: feed a 16 kHz wav through the voice path as if it was spoken (bench/voice_test.sh)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".voicetest"), object: nil, queue: .main) { n in
            guard let path = n.object as? String, path.hasPrefix(Home.root.path) else { return }
            Talk.shared.test(path)
        }
        History.prune()
        Quick.shared.warm()   // the Quick panel's rows, read once off the main thread
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Spool.recover() }   // recordings a quit or crash left open
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { Spool.recover() }   // and one written to just before the crash
        Learn.refresh()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in CallWatch.tick() }
        // words to learn change only after a take he edits; the menu also asks when it opens (2026-11-14: was every 15 s)
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in Learn.refresh() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in History.watchClipboard() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if Engine.shared.ready { Actions.poll(); Budget.idleCheck() }
        }
        Drafter.shared.watchSettings()   // settings changed from outside: file events (was a 1 s check)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            Ghost.shared.hide()
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { Focus.wake(app) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Keys.shared.warmField() }
        }
        log("started")
    }
    func applicationWillTerminate(_ n: Notification) { Engine.shared.stop(); VoiceEngine.shared.stop() }
}

@main
struct Main {
    static var term: DispatchSourceSignal?
    static func main() {
        PK.registerFonts()   // PixelKit's faces from app/art, before anything draws
        if let i = CommandLine.arguments.firstIndex(of: "--ui-preview"), i + 1 < CommandLine.arguments.count {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            do { try UIShots.run(CommandLine.arguments[i + 1], dark: CommandLine.arguments.contains("--dark")) }
            catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--probe") { Focus.probeLoop(); return }
        if CommandLine.arguments.contains("--rules-test") { Rules.selfTest(); return }
        if CommandLine.arguments.contains("--autocorrect-test") { Autocorrect.selfTest(); exit(0) }
        if CommandLine.arguments.contains("--emoji-test") { Emoji.selfTest(); exit(0) }
        if CommandLine.arguments.contains("--snippet-test") { Snippets.selfTest(); exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--ghost-preview"), i + 1 < CommandLine.arguments.count {
            // test: draw the suggestion panels at a fixed spot (no field, nothing typed) and save a picture of each
            let out = CommandLine.arguments[i + 1], dark = CommandLine.arguments.contains("--dark")
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let caret = CGRect(x: 420, y: 300, width: 1, height: 20)
            let shots: [(String, () -> Void)] = [
                ("ghost", { Ghost.shared.unsure = 7; Ghost.shared.show("the slides tonight", action: nil, at: caret) }),
                ("chip", { Ghost.shared.show("", action: ["id": "snippet", "chip": "⇥ alex@example.com"], at: caret) }),
                ("action", { Ghost.shared.show("", action: ["id": "reminder", "chip": "Нагадування · завтра 10:00 · надіслати акт Мілі"], at: caret) }),
                ("card", { Ghost.shared.showDraft([["text": "Thanks, Mila! I'll send the act tonight and we can go over the numbers on Thursday at 11 if that works for you.", "label": "thanks + act tonight"],
                                                   ["text": "b", "label": "b"], ["text": "c", "label": "c"]], field: CGRect(x: 300, y: 340, width: 520, height: 40), caret: caret) }),
            ]
            var k = 0
            func next() {
                guard k < shots.count else { exit(0) }
                let (name, draw) = shots[k]; k += 1
                draw()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
                        guard let d = c?.displays.first else { exit(1) }
                        let cfg = SCStreamConfiguration(); cfg.sourceRect = CGRect(x: 260, y: 220, width: 620, height: 170)
                        cfg.width = 1240; cfg.height = 340
                        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                            if let img, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out + "-\(name).png") as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                            }
                            DispatchQueue.main.async { Ghost.shared.hide(); next() }
                        }
                    }
                }
            }
            DispatchQueue.main.async { next() }
            app.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--shot"), i + 1 < CommandLine.arguments.count {
            // test: picture of the top centre of the main screen into the given file (the voice strip)
            let out = CommandLine.arguments[i + 1]
            let done = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
                guard let d = c?.displays.first else { done.signal(); return }
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = CGRect(x: CGFloat(d.width) / 2 - 360, y: 0, width: 720, height: 190)
                cfg.width = 1440; cfg.height = 380
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                    if let img, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                    }
                    done.signal()
                }
            }
            _ = done.wait(timeout: .now() + 5)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ocr-app"), i + 1 < CommandLine.arguments.count,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first {
            // test: read the lower part of that app's window from behind, as if the caret sat at its bottom
            setbuf(stdout, nil)
            let a = AXUIElementCreateApplication(app.processIdentifier)
            var w: CFTypeRef?; AXUIElementCopyAttributeValue(a, kAXFocusedWindowAttribute as CFString, &w)
            var p = CGPoint.zero, z = CGSize.zero
            if let w {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXPositionAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
                if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXSizeAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgSize, &z) }
            }
            let caret = CGRect(x: p.x + 40, y: p.y + z.height - 30, width: 1, height: 16)
            let t = Date(); let txt = Screen.textAbove(pid: app.processIdentifier, caret: caret)
            print(String(format: "ocr %.0f ms, %d chars:", Date().timeIntervalSince(t) * 1000, txt.count), txt.suffix(400).debugDescription)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--type"), i + 2 < CommandLine.arguments.count {
            TestTyper.run(CommandLine.arguments[i + 2], into: CommandLine.arguments[i + 1]); return
        }
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        // a stop from outside (launchctl, logout) is written down, with whether a recording was cut by it
        signal(SIGTERM, SIG_IGN)
        Main.term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        Main.term?.setEventHandler {
            log("quit: SIGTERM" + (Talk.shared.recording ? ", a recording was running (kept, finished on next start)" : ""))
            Engine.shared.proc?.terminate(); exit(0)
        }
        Main.term?.resume()
        signal(SIGPIPE, SIG_IGN)   // a voice engine that died must not take the app with it on the next write
        app.run()
    }
}


/// "Words to learn": words he changed after dictating (engine/edits.py). Learn puts the pair into the shared
/// dictionary, so the same mishearing is written right next time; Ignore drops it.
final class Learn: NSObject {
    static let shared = Learn()
    static var waiting: [[String: Any]] = []

    static func refresh() {
        Engine.shared.get("/edits") { j in waiting = (j?["edits"] as? [[String: Any]]) ?? [] }
    }

    static func menu() -> NSMenuItem {
        let item = NSMenuItem(title: "Words to learn" + (waiting.isEmpty ? "" : " (\(waiting.count))"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if waiting.isEmpty { sub.addItem(withTitle: "Nothing yet: words you change after dictating show up here", action: nil, keyEquivalent: "").isEnabled = false }
        for e in waiting.sorted(by: { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }).prefix(15) {
            let h = e["heard"] as? String ?? "", f = e["fixed"] as? String ?? "", n = e["count"] as? Int ?? 1
            let row = NSMenuItem(title: "«\(h)» → «\(f)»" + (n > 1 ? "  ×\(n)" : ""), action: nil, keyEquivalent: "")
            let pick = NSMenu()
            for (title, accept) in [("Learn", true), ("Ignore", false)] {
                let i = NSMenuItem(title: title, action: #selector(Learn.choose(_:)), keyEquivalent: "")
                i.target = Learn.shared; i.representedObject = ["heard": h, "fixed": f, "accept": accept]
                pick.addItem(i)
            }
            row.submenu = pick
            sub.addItem(row)
        }
        item.submenu = sub
        return item
    }

    @objc func choose(_ s: NSMenuItem) {
        guard let d = s.representedObject as? [String: Any] else { return }
        Engine.shared.post("/edits", d) { _ in Learn.refresh() }
        if d["accept"] as? Bool == true { Pill.shared.flash("Learned: \(d["fixed"] as? String ?? "")") }
    }
}

/// What a field looks like through Accessibility, into data/app.log (read only): the axprobe hook, and once per app
/// per run when the caret cannot be found there (Keys.ask).
enum AXProbe {
    static var done: Set<String> = []
    static func dump(_ el: AXUIElement, id: String) {
        var names: CFArray?; AXUIElementCopyAttributeNames(el, &names)
        var out: [String] = []
        for k in (names as? [String]) ?? [] where !["AXChildren", "AXChildrenInNavigationOrder", "AXParent", "AXTopLevelUIElement", "AXWindow"].contains(k) {
            var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, k as CFString, &v)
            var t = v.map { "\($0)" } ?? "nil"; if t.count > 90 { t = String(t.prefix(90)) + "…" }
            var settable: DarwinBoolean = false; AXUIElementIsAttributeSettable(el, k as CFString, &settable)
            out.append("\(k)\(settable.boolValue ? "*" : "")=\(t.replacingOccurrences(of: "\n", with: "⏎"))")
        }
        let v: String = Focus.attr(el, kAXValueAttribute) ?? ""
        let r = Focus.range(el)
        let m = Focus.markers(el)
        log("axprobe \(id): " + out.joined(separator: " | "))
        if let r, r.location > 0 {
            let b1 = Focus.bounds(el, r.location - 1, 1), b0 = Focus.bounds(el, r.location, 0), bl = Focus.bounds(el, max(0, r.location - 1), 1)
            log("axprobe \(id): bounds prev \(b1.map { "\($0)" } ?? "nil") at \(b0.map { "\($0)" } ?? "nil") \(bl == nil ? "" : "")")
        }
        log("axprobe \(id): value \(v.count) chars «\(v.suffix(60))», range \(r.map { "\($0.location),\($0.length)" } ?? "nil"), markers \(m.map { "before …\($0.0.suffix(30)) after \($0.1.prefix(30)) rect \($0.2 != nil)" } ?? "nil")")
    }
}


/// Secure input (2026-10-24: Dia held it for hours and Enter during dictation, Tab and suggestions all stopped without a
/// word): while any app has it on, macOS hides typed keys from Drafter's event tap; only modifier keys (Right Option)
/// still arrive. Drafter says who holds it: a lock in the menu bar, and one line in the strip when it has lasted 20 s
/// or when a take starts.
enum SecureInput {
    static var holder: String?
    private static var since: Date?, told = false

    static func check() {
        let on = IsSecureEventInputEnabled()
        if !on {
            if holder != nil { log("secure input: off"); holder = nil; since = nil; told = false; Menu.shared.refresh() }
            return
        }
        if since == nil { since = Date() }
        if holder == nil {
            holder = name() ?? "an app"
            log("secure input: on, held by \(holder!)")
            Menu.shared.refresh()
        }
        if !told, Date().timeIntervalSince(since!) > 20 { told = true; tell() }
    }

    static func tell() {
        guard let h = holder else { return }
        Pill.shared.show("\(h) тримає захищене введення: Enter, ⇥ і підказки не бачать клавіш. Клацни поза полем пароля або онови сторінку.", seconds: 8, lines: 3)
    }

    /// The process macOS names as the holder (ioreg's kCGSSessionSecureInputPID).
    static func name() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-l", "-w", "0", "-d", "4", "-c", "IOConsoleUsers"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let s = String(data: d, encoding: .utf8),
              let r = s.range(of: #""kCGSSessionSecureInputPID"=(\d+)"#, options: .regularExpression),
              let pid = Int32(s[r].split(separator: "=").last ?? "") else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
