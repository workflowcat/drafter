// Drafter's settings: data/settings.json, also written by the engine's /settings (Aleph) and engine/cloud.py.
import Foundation

// MARK: settings

struct Settings: Codable {
    var paused = false
    var skip: [String] = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Terminal",
                          "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.dt.Xcode", "com.microsoft.VSCode",
                          "com.todesktop.230313mzl4w4u92", "com.apple.loginwindow", "com.apple.systempreferences",
                          "com.apple.ScreenSharing", Home.bundleID] + LocalConfig.skipApps
    var model: String? = nil
    var stripStyle = "composer"      // the voice strip's look (app/Pill.swift): composer, or classic (the old one row) (2026-11-14)
    var lookVariant: String? = nil   // hidden: "a" pixel instrument, "b" places with character; nil = the base look (2026-11-14)
    var actions_off: [String] = []
    var voice = false          // Right Option = voice (menu or /settings)
    var voiceFast: String? = nil     // model ID or local path; read on next voice process start
    var voiceCareful: String? = nil  // preserve model choices when any app setting is saved
    var voiceLive = false      // the old live-typing switch, kept so old files load; voiceInsert decides now
    /// How a voice note reaches the field (app/VoiceFlowRules.swift, 14 November 2026): "enter" (default) the words show
    /// in the strip and ↩ puts the whole final text in; "live" they are typed into the field while he speaks.
    var voiceInsert = "enter"
    var adapter: String? = nil // LoRA trained on his writing (data/adapters), loaded on top of the model
    var fmt: String? = nil     // prompt shape: raw (default) or bare (no examples up front, for the trained model)
    var learn = true           // keep lines he sends (Return) in data/typed.jsonl for the phrase memory, local only
    var screen = true          // before 14 November 2026: read the screen only when the app gives little text; kept so old files load
    /// The messages on screen above the field as context for suggestions (app/ScreenContext.swift): Accessibility text
    /// where it is clean, else a picture read on this Mac (Screen Recording); never stored, never sent.
    var screenContext = true
    var keepMic = false        // keep the microphone running between takes: the take starts 0.6 s before the press (orange dot stays on)
    var nextMessage = false    // an empty chat or AI box shows his likely next message by itself (Claude Haiku), Tab puts it in
    var shots = true           // screenshots while a long note or call records, for brief.md (Screen Recording, local only)
    var callNotes = false      // a call or long note: Claude Haiku writes the live outline and the call summary from the transcript text; off = the local model (engine/cloud.py)
    var autocorrect = true     // fix typos when a word ends (macOS spellchecker + his own words; Backspace takes it back)
    var autocorrectMode = "offer" // "offer": a fix found at a word end shows as "→ word" and Tab puts it in; "replace": put in at once (before 13 November 2026); "sure": the ranked fix goes in by itself only when its gate is sure, else offered
    var typoEngine = "ranked"  // "ranked" (15 November 2026: his words, a keyboard error model, context and a learned gate, app/TypoEngine.swift) or "system" (macOS's correction only)
    var autocorrectUk = false  // Ukrainian typos too (off: the Ukrainian dictionary misses many real forms)
    var layoutFix = true       // a word typed in the wrong layout (ghbdsn -> привіт) is fixed and the keyboard switches; double Shift by hand
    var claudeTyping = false   // on a pause Claude writes the rest of the sentence with today's context (his signed-in claude CLI)
    var claudeModel = "sonnet" // sonnet or haiku (haiku answers ~0.5 s sooner)
    var proofread = false      // at a 1.2 s rest Claude proofreads the message; a "Fix N" chip, Tab puts the fixes in (app/Proof.swift)
    /// Earlier round step 5 (an experiment, 2026-11-16): when he ends a sentence (. ! ? …) or rests after 6+ words, that
    /// sentence alone goes to the cloud for minimal edits (Haiku races Workers AI, engine/sentence.py); the same "Fix N"
    /// chip as the proofread, Tab puts the fixes in. Under claudeTyping, off by default.
    var sentenceProof = false
    var proofreadOff: [String] = ["ai"] // app kinds (AppKind: ai, chat, mail, other) where proofread stays quiet: a prompt to an AI needs no clean spelling
    var rework = false         // ⌥Tab on a selection: shorter, fix, clearer, warmer, formal, list, translate or his own words (app/Rework.swift)
    var fixWord = true         // the word being typed is no word he writes but one is a letter or a layout away: "→ word" at the caret, Tab swaps it (app/Fixer.swift)
    var translate = false      // Ukrainian in an English chat (or back), or ;en / ;uk at the end: the message in the other language as a chip (app/Translate.swift)
    var typoHold = true        // no grey text while the word just typed is a suspected typo, until it is fixed or he types past the next word (TypoHold, 15 November 2026)
    // parity round (15 November 2026, app/ParityRules.swift)
    var clipContext = true     // a copy from the last 2 minutes goes into the ghost's prompt (never secrets, password managers, skipped apps)
    var writingNote = ""       // his writing instruction for every app (engine prompt "notes"); "" = none
    var appNotes: [String: String] = [:]   // bundle id -> his writing instruction for that app
    var personalStrength = 100 // 0-100 %: how much of his trained layer the ghosts use (engine /strength re-merges it)
    var typingModel = "live"   // Settings > Typing > Model: a catalog id (engine/catalog.json); saved only after the engine switched to it
    var alternatives = true    // ⌥1 ⌥2 ⌥3 on a ghost: the main idea or one of two others, a quiet "1/3" after the grey words
    var minGhost = 5           // grey text that adds fewer letters is not shown (2026-11-13: under 5 he took 3%); 0 = all
    var predictKeys = true     // ask for a suggestion at the key itself for the field + that letter (no 35 ms wait, 2026-11-13)
    var streamGhost = true     // two-step ghost: the first sure words at once, the rest grows in place (round two)
    var longGhostsAI = true    // a lighter tail of up to 8 words after the sure words in AI apps (round two)
    var longGhostsChats = false  // the same in chats and everywhere else
    /// How far a ghost runs after the gate's first word (long round, 14 November 2026): "word" (round five's few words),
    /// "phrase" (to a comma, 6 words), "sentence" (to the sentence end while the running chance holds; default).
    var ghostLength = "sentence"
    /// Earlier round (2026-11-16, Andrii: "lets do 3-5 words and lessen the confidence"): outside "word" length the
    /// ghost shows at least `ghostMinWords` words when the model has them and at most `ghostMaxWords`; only a sentence
    /// end or a line break ends it sooner (engine gatecore "words" run). Off = `ghostLength` as before.
    var ghostWords = true
    var ghostMinWords = 3, ghostMaxWords = 5
    /// The lower gate (earlier round): a first word the gate scores a little under its bar still shows, as a guess;
    /// `guessShade` draws the whole guess lighter. Tab takes either. The bar per model is in engine/server.py GUESS.
    var guessGhosts = true
    var guessShade = true
    /// Earlier round step 2: ghosts of `minGhostShort` letters or more (in place of `minGhost`, which his settings
    /// file holds at 5), and a request still running when he types a few more letters runs on (engine keep_on).
    /// Earlier round step 6: the guesses' bar one notch lower (0.25) and lower still right after a space (0.2),
    /// engine gatecore.early_bar. Only with guessGhosts.
    var earlyStart = true
    /// Step 7, the idle ghost (Andrii: "start predicting and suggesting the next message even when the cursor is just
    /// blinking"): the caret rests in a chat or AI box, empty or after a finished sentence, and the local model drafts
    /// his next message from the screen above the field and his earlier lines there. Nothing leaves the Mac.
    var idleGhost = true
    var shortGhosts = true
    var minGhostShort = 3
    var keepTyping = true
    /// Cadence round (2026-11-17, docs/rounds/2026-11-17-cadence.md): with a bigger typing model picked, the live 1.7B
    /// stays loaded beside it and answers while he types fast (a gap under 120 ms), the bigger one in longer gaps.
    var comboModels = false
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
    var captureKey = "⌃⌥S"                    // quick capture (app/Capture.swift); "" = off; the default also takes ⌘⇧5 once macOS lets it go
    var captureCmdShiftS = true               // ⌘⇧S starts the capture too (apps' Save As / Duplicate then never get it); off gives it back
    var shotLast = ""                         // the last send-to target of a screenshot (ShotTarget raw value), first in the ⇥ list
    var shotFolder = ""                       // "File" saves screenshots here; "" = ~/Desktop
    // keys round (14 November 2026, app/KeyRules.swift)
    var midLine = true         // a ghost with text after the caret on its line, on a small card under the line (2026-11-15; on since the fim round measured it)
    var tabBack = true         // Backspace right after Tab takes that Tab's words out and shows the grey text again
    var pickOffer = true       // after a long copy, the strip offers "Pick parts" (⌃⌥P)
    var escPause = true        // Esc twice in a field with a ghost pauses ghosts there for 10 minutes; twice again resumes
    var againKey = "⌃⌥R"       // the last voice take in again at the caret (app/Quick.swift); "" = off
    var switchSwap = true      // ⌘⇧V again within 2 s of a switcher paste swaps it for the next older copy
    // typography as you type (15 November 2026, app/TypoGraphRules.swift, app/Typography.swift): the master switch, then one per combo
    var typography = true
    var typographyDash = true, typographySpacedDash = true, typographyEllipsis = true, typographyQuotes = true
    var typographyApostrophe = true
    var typographyApostropheMark = "ʼ"   // "ʼ" (U+02BC) or "’" (U+2019)
    var typographyArrows = true, typographyMath = true, typographySymbols = true
    var typographyHryvnia = false, typographyNbsp = false
    var entityClassify = false // a kind for a name no source knows: Claude Haiku gets the name only (engine/entities.py); off = local model or nothing
    var contextPacks = true    // in AI apps a name he types or says gets a quiet mark, ⌥Tab attaches its context pack (app/Entities.swift)
    var contextLevelAI = 2, contextLevelAgent = 3   // default pack level: 1 name, 2 one line, 3 full (chat assistants, coding agents)
    // the journal window (second window round, 14 November 2026, app/TapeWindow.swift)
    var tapeDensity = "compact"   // "compact": 28 pt rows; "comfortable": 36 pt
    var journalFold = "older"     // sessions folded at start: "older" (today's open), "none", "all"
    // soft and gallery round (14 November 2026): cards or rows, the soft or the old look of rows, the card size
    var journalView = "gallery"   // "gallery": cards; "list": rows
    var journalLook = "soft"      // the list's rows: "soft" (three zones) or "grid" (the old columns)
    var cardSize = 1              // 0 small, 1 medium, 2 large (⌘- ⌘+)

    init() {}
    init(from d: Decoder) throws {   // a missing or wrongly typed key keeps its default, so a file written by the engine still loads
        let c = try d.container(keyedBy: CodingKeys.self), z = Settings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        func pick(_ k: CodingKeys, _ allowed: [String], _ fallback: String) -> String { let x = v(k, fallback); return allowed.contains(x) ? x : fallback }
        paused = v(.paused, z.paused); skip = v(.skip, z.skip); model = v(.model, z.model)
        lookVariant = v(.lookVariant, z.lookVariant)
        stripStyle = pick(.stripStyle, ["classic"], "composer")   // as StripStyle.of
        actions_off = v(.actions_off, z.actions_off)
        voice = v(.voice, z.voice); voiceFast = v(.voiceFast, z.voiceFast); voiceCareful = v(.voiceCareful, z.voiceCareful)
        voiceLive = v(.voiceLive, z.voiceLive); voiceInsert = pick(.voiceInsert, ["live"], "enter")
        learn = v(.learn, z.learn); adapter = v(.adapter, z.adapter); fmt = v(.fmt, z.fmt)
        screen = v(.screen, z.screen); screenContext = v(.screenContext, screen)
        nextMessage = v(.nextMessage, z.nextMessage); keepMic = v(.keepMic, z.keepMic); shots = v(.shots, z.shots)
        callNotes = v(.callNotes, z.callNotes)
        autocorrect = v(.autocorrect, z.autocorrect); autocorrectMode = pick(.autocorrectMode, ["replace", "sure"], "offer")
        typoEngine = pick(.typoEngine, ["system"], "ranked")
        layoutFix = v(.layoutFix, z.layoutFix); autocorrectUk = v(.autocorrectUk, z.autocorrectUk)
        claudeTyping = v(.claudeTyping, z.claudeTyping); claudeModel = v(.claudeModel, z.claudeModel)
        proofread = v(.proofread, z.proofread); sentenceProof = v(.sentenceProof, z.sentenceProof); proofreadOff = v(.proofreadOff, z.proofreadOff)
        clipContext = v(.clipContext, z.clipContext); writingNote = v(.writingNote, z.writingNote); appNotes = v(.appNotes, z.appNotes)
        personalStrength = min(100, max(0, v(.personalStrength, z.personalStrength))); alternatives = v(.alternatives, z.alternatives)
        typingModel = v(.typingModel, z.typingModel)
        facts = v(.facts, z.facts); minGhost = v(.minGhost, z.minGhost); typoHold = v(.typoHold, z.typoHold)
        predictKeys = v(.predictKeys, z.predictKeys); streamGhost = v(.streamGhost, z.streamGhost)
        longGhostsAI = v(.longGhostsAI, z.longGhostsAI); longGhostsChats = v(.longGhostsChats, z.longGhostsChats)
        ghostLength = pick(.ghostLength, ["word", "phrase"], "sentence")   // same rule as GhostRules.lengthMode; kept here so Settings decodes alone
        shortGhosts = v(.shortGhosts, z.shortGhosts); minGhostShort = max(0, v(.minGhostShort, z.minGhostShort)); keepTyping = v(.keepTyping, z.keepTyping)
        comboModels = v(.comboModels, z.comboModels)
        ghostWords = v(.ghostWords, z.ghostWords); guessGhosts = v(.guessGhosts, z.guessGhosts); guessShade = v(.guessShade, z.guessShade); earlyStart = v(.earlyStart, z.earlyStart); idleGhost = v(.idleGhost, z.idleGhost)
        ghostMinWords = min(5, max(1, v(.ghostMinWords, z.ghostMinWords))); ghostMaxWords = min(8, max(ghostMinWords, v(.ghostMaxWords, z.ghostMaxWords)))
        claudePause = v(.claudePause, z.claudePause); translate = v(.translate, z.translate)
        fixWord = v(.fixWord, z.fixWord); rework = v(.rework, z.rework)
        callOff = v(.callOff, z.callOff); calendarsOff = v(.calendarsOff, z.calendarsOff)
        textIdleMin = v(.textIdleMin, z.textIdleMin); voiceIdleMin = v(.voiceIdleMin, z.voiceIdleMin)
        quickKey = v(.quickKey, z.quickKey); quickMax = v(.quickMax, z.quickMax); quickDays = v(.quickDays, z.quickDays)
        quickSecret = v(.quickSecret, z.quickSecret)
        switchKey = v(.switchKey, z.switchKey); switchFormat = v(.switchFormat, z.switchFormat)
        entityClassify = v(.entityClassify, z.entityClassify); contextPacks = v(.contextPacks, z.contextPacks)
        contextLevelAI = min(3, max(1, v(.contextLevelAI, z.contextLevelAI)))
        contextLevelAgent = min(3, max(1, v(.contextLevelAgent, z.contextLevelAgent)))
        connect = v(.connect, z.connect)
        clipImageMB = v(.clipImageMB, z.clipImageMB); clipTotalMB = v(.clipTotalMB, z.clipTotalMB)
        captureKey = v(.captureKey, z.captureKey); captureCmdShiftS = v(.captureCmdShiftS, z.captureCmdShiftS); shotLast = v(.shotLast, z.shotLast); shotFolder = v(.shotFolder, z.shotFolder)
        tabBack = v(.tabBack, z.tabBack); midLine = v(.midLine, z.midLine); pickOffer = v(.pickOffer, z.pickOffer)
        escPause = v(.escPause, z.escPause); againKey = v(.againKey, z.againKey); switchSwap = v(.switchSwap, z.switchSwap)
        typography = v(.typography, z.typography)
        typographyDash = v(.typographyDash, z.typographyDash); typographySpacedDash = v(.typographySpacedDash, z.typographySpacedDash)
        typographyEllipsis = v(.typographyEllipsis, z.typographyEllipsis); typographyQuotes = v(.typographyQuotes, z.typographyQuotes)
        typographyApostrophe = v(.typographyApostrophe, z.typographyApostrophe)
        typographyApostropheMark = pick(.typographyApostropheMark, ["’"], "ʼ")
        typographyArrows = v(.typographyArrows, z.typographyArrows); typographyMath = v(.typographyMath, z.typographyMath)
        typographySymbols = v(.typographySymbols, z.typographySymbols)
        typographyHryvnia = v(.typographyHryvnia, z.typographyHryvnia); typographyNbsp = v(.typographyNbsp, z.typographyNbsp)
        tapeDensity = pick(.tapeDensity, ["comfortable"], "compact")
        journalFold = pick(.journalFold, ["none", "all"], "older")
        journalView = pick(.journalView, ["list"], "gallery")
        journalLook = pick(.journalLook, ["grid"], "soft")
        cardSize = max(0, min(2, v(.cardSize, z.cardSize)))
        // cloudDefaults is never read back: the engine's migration mark, always written as "off"
    }
    /// Claude switches (engine/cloud.py) are off for a new install since 2026-11-14. Once, before decoding, a file
    /// written earlier gets today's effective value (on) of each one it does not name, and the mark; cloud.migrate()
    /// in the engine does the same, whichever runs first.
    static let cloudKeys = ["claudeTyping", "claudePause", "proofread", "facts", "translate", "rework", "nextMessage", "callNotes", "entityClassify", "sentenceProof"]
    static let neverOn: Set<String> = ["entityClassify", "sentenceProof"]   // new that day, never on before: stays off (engine/cloud.py NEVER_ON)
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
