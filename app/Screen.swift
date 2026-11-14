// Screen reading, the fallback for screen context (Andrii, 2026-10-19; Cotypist does the same): when the app gives
// little text through Accessibility (Google Docs, Figma, some native chats), Drafter takes a picture of the window
// above the caret and reads it on this Mac with Vision (Ukrainian + English). The picture is never stored; only the
// text goes to the local engine. Needs Screen Recording permission for Drafter (asked once).
import AppKit
import ScreenCaptureKit
import Vision

enum Screen {
    /// false only after a capture was refused (the preflight call lags behind the switch in System Settings).
    /// Written in ScreenCaptureKit's callbacks, read on main: under `lock` (Argon 23).
    static var allowed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowed }
        set { lock.lock(); _allowed = newValue; lock.unlock() }
    }
    private static var _allowed = true
    private static var asked = false
    /// After a failed capture no capture is tried for 30 s, then longer up to 10 min (2026-11-13: one failure per
    /// context read was logged 1,231 times since 24 October, 80 times on 9 November while he typed in the Claude app).
    private static var backoff = Backoff(first: 30, most: 600)
    private static let lock = NSLock()
    private static var skipped = 0

    /// Text of the window part above the caret, read on-device. Blocks the calling (background) thread up to `wait`.
    static func textAbove(pid: pid_t, caret: CGRect, height: CGFloat = 700, wait: Double = 1.5) -> String {
        if pid == getpid() { return "" }   // Drafter's own window: nothing to read there
        lock.lock(); let go = backoff.allowed(); if !go { skipped += 1 }; lock.unlock()
        guard go else { return "" }
        // try first: the preflight answer can lag behind the switch in System Settings
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
        var winFrame = CGRect.zero
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            if let error {
                if failed() { log("screen: \(SysAudio.describe(error))") }
                lock.lock(); _allowed = false; let ask = !asked; asked = true; lock.unlock()
                if ask { DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() } }
            }
            // the app's window that holds the caret
            guard let w = content?.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0
                                                         && $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY)) }) else { done.signal(); return }
            winFrame = w.frame
            let top = max(w.frame.minY, caret.minY - height)
            let local = CGRect(x: 0, y: top - w.frame.minY, width: w.frame.width, height: max(1, caret.minY - top))
            guard local.height > 20 else { done.signal(); return }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = local
            let scale = NSScreen.screens.first(where: { $0.frame.width > 0 })?.backingScaleFactor ?? 2
            cfg.width = Int(local.width * scale); cfg.height = Int(local.height * scale)
            cfg.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) { img, err in
                image = img; if img != nil { allowed = true; succeeded() }
                // what was asked when it failed, to find out why (the error alone never said): the error's domain and
                // code, the window (layer, on screen, size), the part asked for, whether the display sleeps, the screen is
                // locked, and how many system-audio streams for calls run now
                if let err, failed() {
                    log("screen capture: \(SysAudio.describe(err)) · window \(w.windowID) layer \(w.windowLayer) onScreen \(w.isOnScreen) "
                        + "\(Int(w.frame.width))x\(Int(w.frame.height)) part \(Int(local.width))x\(Int(local.height)) · "
                        + "display asleep \(CGDisplayIsAsleep(CGMainDisplayID()) != 0) · locked \(Screen.locked) · "
                        + "call audio \(Talk.shared.recording)")
                }
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + wait) == .success, let image else { return "" }
        _ = winFrame
        return read(image)
    }

    /// A capture failed: the next one waits. -> true when this failure starts a new wait (log it then, once).
    static func failed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let (wait, tell) = backoff.failed()
        if tell {
            let n = backoff.failures, s = skipped; skipped = 0
            log("screen capture: failure \(n) in a row, no screen reading for \(Int(wait)) s" + (s > 0 ? " (\(s) reads skipped while waiting)" : ""))
        }
        return tell
    }

    static func succeeded() {
        lock.lock(); let back = backoff.succeeded(); lock.unlock()
        if back { log("screen capture: working again") }
    }

    /// The login screen is up (screen locked).
    static var locked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Vision text reading, top to bottom.
    static func read(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["uk-UA", "en-US"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([req])
        let lines = (req.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }     // Vision's y goes up
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
