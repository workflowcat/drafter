// Quick capture's rules (round three, Part B and C, 14 November 2026): the capture key, what a drag or a key in the
// dimmed screen means, where the region sits on its display, and what goes into the field afterwards. Pure: no AppKit,
// tested in tests/shot_rules.swift. The overlay, ScreenCaptureKit and the paste live in app/Capture.swift.
import Foundation
import CoreGraphics

enum ShotRules {
    /// ⌃⌥S: the same ⌃⌥ hand as the Quick panel (⌃⌥V), S for screen. Leaves ⌘⇧3/4/5 to macOS, ⌘⇧V to the
    /// switcher and ⌘⇧S to apps' Save As; apps rarely bind ⌃⌥ letters.
    static let defaultKey = "⌃⌥S"
    static let taken: Set<String> = ["⌘⇧3", "⌘⇧4", "⌘⇧5", "⌘⇧6", "⌃⌥V", "⌘⇧V", "⌘Space", "⌃⌥Space"]
    /// A capture key he may set: parses, has ⌘ ⌃ or ⌥, and is none of the taken ones.
    static func allowed(_ s: String) -> Bool {
        guard let k = QuickRules.hotkey(s), k.cmd || k.ctrl || k.alt else { return false }
        return !taken.contains { QuickRules.hotkey($0) == k }
    }

    /// What happens on release: put the picture in (default), keep it on the tape only (K), or put its read text in (T).
    enum Mode: String { case paste, keep, text }
    enum Pick { case region, window, screen }

    /// A key while the screen is dimmed.
    enum Action: Equatable { case cancel, screen, windowMode, mode(Mode), none }
    static func key(_ code: Int, dragging: Bool) -> Action {
        switch code {
        case 53: return .cancel
        case 36, 76: return dragging ? .none : .screen
        case 49: return .windowMode
        case 40: return .mode(.keep)     // K
        case 17: return .mode(.text)     // T
        case 35: return .mode(.paste)    // P: back to paste
        default: return .none
        }
    }

    /// The dragged rectangle from two points; nil when it is too small to mean a region (a click).
    static func region(_ a: CGPoint, _ b: CGPoint, min: CGFloat = 6) -> CGRect? {
        let r = CGRect(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return r.width >= min && r.height >= min ? r.integral : nil
    }
    /// A region in AppKit screen points (origin bottom-left of the main screen) as ScreenCaptureKit's source rectangle
    /// on its display (origin top-left of that display), clipped to it.
    static func sourceRect(_ r: CGRect, display: CGRect) -> CGRect {
        let c = r.intersection(display)
        guard !c.isNull else { return .zero }
        return CGRect(x: c.minX - display.minX, y: display.maxY - c.maxY, width: c.width, height: c.height)
    }

    /// The hint line under the dimmed screen's top edge.
    static func hint(_ mode: Mode, pick: Pick) -> String {
        let what = pick == .window ? "click a window" : "drag a region"
        let then: String
        switch mode { case .paste: then = "puts it in"; case .keep: then = "keeps it on the tape"; case .text: then = "puts its text in" }
        return "\(what) · space window · ↵ screen · K keep · T text · esc — release \(then)"
    }

    // MARK: Part C: the picture and a line together

    /// After a capture, the strip "what is this?": what each key sends, in the order it goes in.
    enum Note: Equatable { case picture, pictureAndLine(String), pictureAndText }
    static func note(code: Int, cmd: Bool, line: String) -> Note? {
        switch code {
        case 53: return .picture
        case 36, 76:
            if cmd { return .pictureAndText }
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return l.isEmpty ? .picture : .pictureAndLine(l)
        default: return nil
        }
    }
    /// How the two go in: two pastes in a row, picture first, then the text after a short wait (the app takes the
    /// picture as an attachment or inline, then the text goes into the box). One pasteboard holding both makes most
    /// fields take one type and drop the other, so the text would be lost.
    struct Delivery: Equatable { let picture: Bool; let text: String?; let gapMs: Int }
    static func delivery(_ n: Note, read: String) -> Delivery {
        switch n {
        case .picture: return Delivery(picture: true, text: nil, gapMs: 0)
        case .pictureAndLine(let l): return Delivery(picture: true, text: l, gapMs: 350)
        case .pictureAndText:
            let t = read.trimmingCharacters(in: .whitespacesAndNewlines)
            return Delivery(picture: true, text: t.isEmpty ? nil : t, gapMs: 350)
        }
    }

    /// What each app is known to do with a picture paste followed by a text paste (Part C's table). "known" rows were
    /// read from how the app handles ⌘V of an image; every row needs one live check before it is relied on.
    static let apps: [(app: String, bundle: String, picture: String, status: String)] = [
        ("Claude", "com.anthropic.claudefordesktop", "attachment above the box", "needs a live test"),
        ("Codex", "com.openai.codex", "attachment above the box", "needs a live test"),
        ("Slack", "com.tinyspeck.slackmacgap", "attachment, the text stays in the box", "needs a live test"),
        ("Beeper", "com.automattic.beeper.desktop", "attachment preview, the text in the box", "needs a live test"),
        ("Notes", "com.apple.Notes", "inline picture, the text after it", "known"),
        ("Mail", "com.apple.mail", "inline picture, the text after it", "known"),
    ]
}
