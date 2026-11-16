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
    /// Low battery no longer pauses (Andrii, 2026-11-16: "should keep running, just stay under limit"): the engine
    /// already drops look-ahead work under 30 % and the guard keeps its memory cap. `lowBattery` only labels the menu.
    var active: Bool { !settings.paused }

    /// The one way the app changes its settings: in memory, then data/settings.json. Returns the new settings.
    @discardableResult func change(_ edit: (inout Settings) -> Void) -> Settings {
        var st = settings; edit(&st); settings = st; st.save(); return st
    }

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
        if low != lowBattery { lowBattery = low; log("battery \(pct)% on battery=\(onBattery): light \(low)") }
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
        Focus.pasted = { PasteWatch.own($0) }   // the paste trail (soft round)
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
        DevHooks.install()   // notification hooks for tests and benches (app/DevHooks.swift)
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
        if DevHooks.runCommandLine() { return }   // --ui-preview, --type and the other test modes
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
