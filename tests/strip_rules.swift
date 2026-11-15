// swiftc -parse-as-library app/StripRules.swift app/ThemeRules.swift tests/strip_rules.swift -o app/build/strip-rules-test && app/build/strip-rules-test
// The composer strip's layout (app/StripRules.swift): nothing readable behind the camera housing, the words below the
// band, the level never over text, 1-4 lines then scrolling, a capsule with no empty band, and the colours on black.
import Foundation
import CoreGraphics

@main
struct StripRulesTest {
    static var failed = 0, checks = 0
    static func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { failed += 1; print("FAIL " + what) } }
    static func main() {
        var modes: [StripMode] = [.long(call: true), .long(call: false), .offer(rows: 1), .offer(rows: 2)]
        for k in 0...4 { modes += [.take(lines: k, level: true), .take(lines: k, level: false), .take(lines: k, level: false, buttons: true)] }
        for k in 1...4 { modes += [.message(lines: k, button: false), .message(lines: k, button: true)] }
        modes += [.message(lines: 1, button: false, inBand: true), .message(lines: 1, button: true, inBand: true)]
        for n: CGFloat in [0, 160, 185, 200, 230] {
            for bar: CGFloat in [24, 28, 32, 37, 38] {
                for screen: CGFloat in [1280, 1512, 1728, 3008] {
                    for m in modes {
                        let bw: CGFloat = { if case .long = m { return 120 }; if case .offer = m { return 300 }; if case .message(_, true, _) = m { return 70 }; if case .take(_, _, true) = m { return 170 }; return 0 }()
                        let l = StripRules.layout(m, notch: n, bar: bar, screen: screen, buttons: bw)
                        let bad = StripRules.problems(l, m)
                        check(bad.isEmpty, "notch \(n) bar \(bar) screen \(screen) \(m): \(bad)")
                        check(l.size.width <= screen - 40, "fits the screen")
                        if n > 0 { check(abs(l.notch.midX - l.centre) < 0.5 && l.hangs, "centred on the housing") }
                        else { check(!l.hangs && l.notch == .zero && l.top > bar, "a capsule under the menu bar") }
                    }
                }
            }
        }
        // the band beside the housing: the state on the left, level and keys on the right
        let t = StripRules.layout(.take(lines: 2, level: true), notch: 200, bar: 38)
        check(t.state!.maxX <= t.notch.minX - StripRules.gap && t.level!.minX >= t.notch.maxX + StripRules.gap && t.hints!.minX > t.level!.maxX, "left: state, right: level then keys")
        check(t.text!.minY >= t.band && t.size.height == 38 + 4 + 40 + 12, "two lines under the band")
        let t4 = StripRules.layout(.take(lines: 4, level: true), notch: 200, bar: 38), t9 = StripRules.layout(.take(lines: 9, level: true), notch: 200, bar: 38)
        check(t4.size == t9.size, "it grows to 4 lines, then holds")
        check(StripRules.layout(.take(lines: 0, level: true), notch: 200, bar: 38).size.height == 38, "no words yet: the band only")
        let f0 = StripRules.layout(.take(lines: 0, level: true), notch: 0, bar: 24)
        check(f0.size.height == 32 && f0.state != nil && f0.hints != nil, "the capsule's first row holds the band's content")
        // the draft's keys: a row under the words, at its right end, never over them
        let d = StripRules.layout(.take(lines: 2, level: false, buttons: true), notch: 200, bar: 38, buttons: 170)
        check(d.buttons!.minY >= d.text!.maxY && abs(d.buttons!.maxX - (d.size.width - 12)) < 0.5, "the draft's buttons under the words, right")
        // a short receipt in the band, beside the mark; its button right of the housing
        let rb = StripRules.layout(.message(lines: 1, button: true, inBand: true), notch: 200, bar: 38, buttons: 70)
        check(rb.size.height == 38 && rb.text!.minY == 0 && rb.buttons!.minX >= rb.notch.maxX && rb.text!.maxX <= rb.notch.minX, "a receipt in the band: \(rb.size.height)")
        // keys: words where there is room, glyphs where tight, one way everywhere
        check(StripRules.key(.shiftRightOption) == "⇧ Right Option" && StripRules.key(.shiftRightOption, tight: true) == "⇧⌥", "⇧ Right Option")
        check(StripRules.key(.rightOption) == "Right Option" && StripRules.key(.ret, tight: true) == "↩", "Right Option, ↩")
        for k in StripRules.Key.allCases { check(!StripRules.key(k).contains("right ⌥"), "never «right ⌥»") }
        // negative checks: the rules catch what they are for
        var bad = t; bad.state = CGRect(x: 180, y: 0, width: 60, height: 38)
        check(!StripRules.problems(bad, .take(lines: 2, level: true)).isEmpty, "catches text behind the housing")
        bad = t; bad.text = CGRect(x: 18, y: 10, width: 100, height: 24)
        check(StripRules.problems(bad, .take(lines: 2, level: true)).contains("words in the band"), "catches words in the band")
        bad = t; bad.level = bad.hints
        check(!StripRules.problems(bad, .take(lines: 2, level: true)).isEmpty, "catches the level over the keys")
        bad = t; bad.text = CGRect(x: 18, y: 42, width: 500, height: 24)
        check(StripRules.problems(bad, .take(lines: 2, level: true)).contains("no room for 2 lines"), "catches lines without room")
        // the lines: wrap, newest last, at most 4, "… " when older ones scroll away
        let m: (String) -> CGFloat = { CGFloat($0.count) * 8 }
        check(StripRules.lines("", room: 100, measure: m).isEmpty, "no words")
        check(StripRules.lines("one two", room: 100, measure: m) == ["one two"], "one line")
        let words = (1...40).map { "w\($0)" }.joined(separator: " ")
        let ls = StripRules.lines(words, room: 100, measure: m)
        check(ls.count == 4 && ls.last!.hasSuffix("w40") && ls[0].hasPrefix("… "), "scrolls: \(ls)")
        check(ls.allSatisfy { m($0) <= 100 }, "every line fits")
        let long = StripRules.lines(String(repeating: "x", count: 40) + "END", room: 80, measure: m)
        check(long.count == 1 && long[0].hasSuffix("END") && m(long[0]) <= 80, "a long word keeps its newest letters")
        check(StripRules.newestFrom("a bb ccc dddd", words: 3) == 2 && StripRules.newestFrom("a bb", words: 3) == 0, "newest words")
        // styles: two, old values read as composer
        check(StripStyle.of(nil) == .composer && StripStyle.of("a") == .composer && StripStyle.of("two") == .composer && StripStyle.of("classic") == .classic, "old values")
        // the colours: every built-in theme. The strip is drawn in the dark tokens in both appearances (it merges with
        // the black housing), so the dark jobs must pass on black: words 4.5:1, the faintest hint 3:1.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("app/art/themes")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        check(files.count >= 4, "the built-in themes are there")
        let black = RGBA(r: 0, g: 0, b: 0, a: 1)
        for f in files where f.pathExtension == "json" {
            let j = (try! JSONSerialization.jsonObject(with: Data(contentsOf: f))) as! [String: Any]
            let s = ThemeRules.parse(id: f.deletingPathExtension().lastPathComponent, j)
            for job in StripRules.textJobs {
                guard let c = s.dark[job] else { check(false, "\(s.id) has \(job)"); continue }
                let r = RGBA.ratio(c.over(black), black)
                check(r >= (job == "faint" ? 3 : 4.5), "\(s.id) \(job) on black: \(String(format: "%.2f", r))")
            }
        }
        print(failed == 0 ? "strip rules: all \(checks) checks pass" : "strip rules: \(failed) of \(checks) checks failed")
        exit(failed == 0 ? 0 : 1)
    }
}
