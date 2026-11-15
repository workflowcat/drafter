// swiftc -parse-as-library app/ThemeRules.swift tests/theme_rules.swift -o app/build/theme-test && app/build/theme-test
// Themes: the built-in files pass PixelKit's gates, a weak one is refused with its reasons, the parts parse.
import Foundation

@main
struct ThemeTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL " + what) } }
    static func main() {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("app/art/themes")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        check(Set(files.map { $0.deletingPathExtension().lastPathComponent }) == ["pixel", "coffee", "saggar", "benidorm"], "four built-in themes")
        for f in files {
            let j = (try! JSONSerialization.jsonObject(with: Data(contentsOf: f))) as! [String: Any]
            let s = ThemeRules.parse(id: f.deletingPathExtension().lastPathComponent, j)
            check(s.problems.isEmpty, "\(s.id) passes: \(s.problems)")
            check(Set(s.light.keys) == Set(ThemeRules.jobs) && Set(s.dark.keys) == Set(ThemeRules.jobs), "\(s.id) has every job")
            check(s.corners.count == 4, "\(s.id) four corners")
            check(s.radii["pane"] == 12 && s.radii["row"] == 8 && s.motion["fold"] == 120, "\(s.id) radii and motion")
            for (mode, c) in [("light", s.light), ("dark", s.dark)] {   // the soft surfaces step the right way
                check(c["well"]!.luminance < c["card"]!.luminance || mode == "light" && c["well"]!.luminance < c["paper"]!.luminance + 1e-9, "\(s.id) \(mode) panes stand off the well")
                check(c["hover"] != c["pick"] && RGBA.ratio(c["pick"]!, c["card"]!) > RGBA.ratio(c["hover"]!, c["card"]!), "\(s.id) \(mode) pick a step past hover")
                for k in ["blue", "mint", "violet", "coral"] {   // the kind marks
                    check(RGBA.ratio(c[k]!, c["card"]!) >= 3 && RGBA.ratio(c[k]!, c["pick"]!) >= 3 && RGBA.ratio(c[k]!, c["well"]!) >= 3, "\(s.id) \(mode) \(k) kind mark 3:1 on card, pick and well")
                }
            }
            print(String(format: "%@ ok · body %@ · corners %@ · shadow y %.0f blur %.0f a %.2f", s.id, s.body.first ?? "-",
                         s.corners.map { String(Int($0)) }.joined(separator: "/"), s.shadow.y, s.shadow.blur, s.shadow.alpha))
        }
        // pixel keeps PixelKit's exact values, not derived ones
        let px = ThemeRules.parse(id: "pixel", (try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("pixel.json")))) as! [String: Any])
        check(px.light["violet"] == ThemeRules.color("#8256b8"), "pixel violet exact")
        // a made-up theme with grey text too light and a missing colour
        var weak: [String: Any] = ["name": "Weak", "corners": [0, 2, 4]]
        let base = ["ground": "#ffffff", "raised": "#ffffff", "soft": "#f4f4f5", "ink": "#18181b", "quiet": "#52525b", "faint": "#c8c8c8",
                    "accent": "#2563eb", "good": "#15803d", "bad": "#b91c1c", "waiting": "#a16207", "mix": "#18181b"]
        weak["light"] = base
        var d = base; d.removeValue(forKey: "mix"); weak["dark"] = d
        let w = ThemeRules.parse(id: "weak", weak)
        check(w.problems.contains { $0.hasPrefix("light: faint text on ground") }, "faint text refused")
        check(w.problems.contains { $0 == "dark: needs a #rrggbb value for mix" }, "missing colour refused")
        check(w.problems.contains { $0.hasPrefix("corners") }, "three corners refused")
        print("weak refused: " + w.problems.joined(separator: " | "))
        // parts
        check(ThemeRules.color("rgba(20,22,26,.10)") == RGBA(r: 20.0 / 255, g: 22.0 / 255, b: 26.0 / 255, a: 0.1), "rgba parses")
        check(ThemeRules.color("#abc") == ThemeRules.color("#aabbcc"), "#rgb parses")
        check(ThemeRules.families(#""Fixel Text", -apple-system, sans-serif"#) == ["Fixel Text", "-apple-system", "sans-serif"], "families")
        let sh = ThemeRules.shadow("0 1px 2px rgb(0 0 0 / .06), 0 8px 24px -6px rgb(0 0 0 / .18)")
        // a theme whose pick is too strong for its quiet text is refused
        var loud = weak; loud["light"] = base.merging(["faint": "#6b6b74"]) { _, b in b }; loud["dark"] = loud["light"]
        loud["surface"] = ["light": ["well": 5, "hover": 5, "pick": 60], "dark": ["well": 30, "hover": 5, "pick": 60]]
        loud["corners"] = [0, 4, 8, 12]
        check(ThemeRules.parse(id: "loud", loud).problems.contains { $0.contains("text on pick") }, "a loud pick refused")
        check(sh.y == 8 && sh.blur == 24 && abs(sh.alpha - 0.18) < 1e-9, "shadow last layer")
        check(ThemeRules.shadow("none").alpha == 0, "no shadow")
        print(failed == 0 ? "theme rules: all passed" : "theme rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
