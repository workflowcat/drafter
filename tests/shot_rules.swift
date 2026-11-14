import Foundation
import CoreGraphics

// swiftc -parse-as-library app/QuickRules.swift app/ClipRules.swift app/ShotRules.swift app/MarkupRules.swift tests/shot_rules.swift -o app/build/shot-rules-test && app/build/shot-rules-test
// Quick capture's rules: the key, the dimmed screen's keys, the region on its display, the picture-and-text strip.
@main
struct ShotRulesTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func markup() {
        var m = Markup(size: CGSize(width: 1000, height: 600))
        check(Markup.toolCodes[18] == .arrow && Markup.toolCodes[22] == .crop && Markup.toolCodes.count == 6, "1-6 pick the tool")
        m.add(PicMark(tool: .arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 11)))
        check(m.marks.isEmpty, "a click is no arrow")
        m.add(PicMark(tool: .label, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)))
        check(m.marks.isEmpty, "an empty label is dropped")
        m.add(PicMark(tool: .box, from: CGPoint(x: 900, y: 500), to: CGPoint(x: 1200, y: -40)))
        check(m.marks.first?.rect == CGRect(x: 900, y: 0, width: 100, height: 500), "clamped to the picture")
        m.add(PicMark(tool: .crop, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400)))
        m.add(PicMark(tool: .crop, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 450, y: 350)))
        check(m.marks.filter { $0.tool == .crop }.count == 1 && m.crop == CGRect(x: 50, y: 50, width: 400, height: 300), "one crop, the last")
        m.undo(); check(m.crop.size == CGSize(width: 1000, height: 600), "undo the crop: whole picture")
        m.redo(); check(m.crop.width == 400, "redo")
        m.undo(); m.add(PicMark(tool: .highlight, from: .zero, to: CGPoint(x: 40, y: 40))); m.redo()
        check(m.marks.last?.tool == .highlight, "a new mark clears redo")
        let f = Markup.fit(CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 800, height: 800))
        check(f.scale == 0.4 && f.rect == CGRect(x: 0, y: 200, width: 800, height: 400), "fit: \(f)")
        check(Markup.toPicture(CGPoint(x: 400, y: 400), fitted: f.rect, scale: f.scale) == CGPoint(x: 1000, y: 500), "editor point to pixels")
        check(Markup.fit(CGSize(width: 100, height: 50), in: CGRect(x: 0, y: 0, width: 800, height: 800)).scale == 1, "never scaled up")
        check(Markup.stroke(CGSize(width: 2600, height: 1600)) == 10 && Markup.stroke(CGSize(width: 300, height: 200)) == 3, "stroke width")
        check(Markup.block(CGRect(x: 0, y: 0, width: 300, height: 30)) == 8, "pixel block at least 8")
    }

    static func main() {
        check(ShotRules.allowed(ShotRules.defaultKey), "⌃⌥S is allowed")
        for k in ["⌘⇧3", "⌘⇧4", "⌘⇧5", "⌃⌥V", "⌘⇧V", "S", "⇧S"] { check(!ShotRules.allowed(k), "\(k) refused") }
        check(ShotRules.allowed("⌃⌥⇧S"), "another chord is fine")

        check(ShotRules.key(53, dragging: false) == .cancel, "esc cancels")
        check(ShotRules.key(36, dragging: false) == .screen, "return takes the screen")
        check(ShotRules.key(36, dragging: true) == .none, "return during a drag does nothing")
        check(ShotRules.key(49, dragging: false) == .windowMode, "space picks a window")
        check(ShotRules.key(40, dragging: false) == .mode(.keep) && ShotRules.key(17, dragging: false) == .mode(.text), "K and T")

        check(ShotRules.region(CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 300)) == nil, "too thin is a click")
        check(ShotRules.region(CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 50)) == CGRect(x: 100, y: 50, width: 200, height: 150), "any drag direction")
        // a 1440 × 900 main display, a second one above it
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900), top = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        check(ShotRules.sourceRect(CGRect(x: 100, y: 700, width: 200, height: 100), display: main) == CGRect(x: 100, y: 100, width: 200, height: 100), "flipped to the display's top-left")
        check(ShotRules.sourceRect(CGRect(x: 0, y: 1880, width: 100, height: 100), display: top) == CGRect(x: 0, y: 0, width: 100, height: 100), "second display")
        check(ShotRules.sourceRect(CGRect(x: 1400, y: 0, width: 100, height: 50), display: main).width == 40, "clipped to the display")
        check(ShotRules.sourceRect(CGRect(x: 2000, y: 0, width: 10, height: 10), display: main) == .zero, "off the display")
        check(ShotRules.hint(.text, pick: .region).hasSuffix("puts its text in"), "hint says the mode")

        // Part C: the strip after a capture
        check(ShotRules.note(code: 36, cmd: false, line: "") == .picture, "return on an empty line: the picture at once")
        check(ShotRules.note(code: 36, cmd: false, line: "  the error on step 3 ") == .pictureAndLine("the error on step 3"), "his line")
        check(ShotRules.note(code: 36, cmd: true, line: "x") == .pictureAndText, "⌘return: the read text")
        check(ShotRules.note(code: 53, cmd: false, line: "half typed") == .picture, "esc: the picture alone")
        check(ShotRules.note(code: 0, cmd: false, line: "") == nil, "a letter is typing")
        let d = ShotRules.delivery(.pictureAndLine("see the total"), read: "")
        check(d.picture && d.text == "see the total" && d.gapMs > 0, "picture first, then the line")
        check(ShotRules.delivery(.pictureAndText, read: "  ").text == nil, "no read text: the picture alone")
        check(ShotRules.apps.count == 6 && ShotRules.apps.allSatisfy { $0.status == "known" || $0.status == "needs a live test" }, "app table")
        markup()
        print(failures == 0 ? "shot rules: all passed" : "shot rules: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
