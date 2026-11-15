// Themes (14 November 2026; Andrii: Drafter should "have some themes" and be "available for people to modify as they
// wish"). A theme is a PixelKit skin preset as a small JSON file (docs/themes.md): eleven colours for light and for
// dark, the faces, four corners, how strong the edges are, the shadow on what floats. Every other colour job is derived
// from those the way PixelKit's build derives a skin (scripts/build.py, skin_css), and the theme is held to the same
// contrast gates (skin_problems): text 4.5:1, marks, edges and the focus ring 3:1. A theme that fails is refused with
// the reasons. Pure (Foundation only), so it builds alone in tests/theme_rules.swift.
import Foundation

struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double
    /// `self` at its own alpha over an opaque ground (what the eye sees).
    func over(_ g0: RGBA) -> RGBA { RGBA(r: r * a + g0.r * (1 - a), g: g * a + g0.g * (1 - a), b: b * a + g0.b * (1 - a), a: 1) }
    func alpha(_ x: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: x) }
    var luminance: Double {
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    static func ratio(_ x: RGBA, _ y: RGBA) -> Double {
        let a = x.luminance, b = y.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

struct ThemeSpec {
    let id: String
    let name: String
    let light: [String: RGBA]          // every colour job (ThemeRules.jobs)
    let dark: [String: RGBA]
    let display: [String], body: [String], mono: [String]   // font families, first installed wins
    let tabular: Bool                  // numbers in the body face with even digits when no mono face is named
    let corners: [Double]              // square, keys and tags, controls, floating panels
    let shadow: (y: Double, blur: Double, alpha: Double)
    let problems: [String]             // empty: usable
    /// Soft round (14 November 2026): the radii of a pane, a card and a chosen row, and how long a fold slides and the
    /// reader fades (ms). From the theme's "radii" and "motion"; these are the defaults.
    var radii: [String: Double] = ThemeRules.defaultRadii
    var motion: [String: Double] = ThemeRules.defaultMotion
}

enum ThemeRules {
    static let keys = ["ground", "raised", "soft", "ink", "quiet", "faint", "accent", "good", "bad", "waiting", "mix"]
    /// The colour jobs the app draws with (PixelTokens.swift has one constant for each).
    static let jobs = ["paper", "card", "ink", "muted", "faint", "line", "rule", "controlEdge", "soft", "key", "keyEdge",
                       "primary", "primaryEdge", "onPrimary", "blue", "mint", "violet", "coral", "warn", "selected", "okBg",
                       "warnBg", "critBg", "actionBg", "ok", "crit", "well", "hover", "pick"]
    static let defaultRadii: [String: Double] = ["pane": 12, "card": 10, "row": 8]
    static let defaultMotion: [String: Double] = ["fold": 120, "fade": 80]
    /// The surface steps in % (soft round): `well` the window behind the panes (light: `mix` over ground; dark: black
    /// over ground, so the panes stand lighter), `hover` and `pick` (the chosen row or card) are `mix` over raised.
    static let defaultSurface: [String: [String: Double]] = ["light": ["well": 5, "hover": 4.5, "pick": 8.5], "dark": ["well": 30, "hover": 5, "pick": 9]]

    /// The three surface jobs from the derived ones (`line` carries `mix`): the well, a hover, a pick.
    static func surfaces(_ j: [String: RGBA], mode: String, pct: [String: Double]? = nil) -> [String: RGBA] {
        let p = pct ?? defaultSurface[mode]!
        guard let paper = j["paper"], let card = j["card"], let line = j["line"] else { return [:] }
        let mix = RGBA(r: line.r, g: line.g, b: line.b, a: 1)
        let wellInk = mode == "dark" ? RGBA(r: 0, g: 0, b: 0, a: 1) : mix
        return ["well": wellInk.alpha((p["well"] ?? 5) / 100).over(paper), "hover": mix.alpha((p["hover"] ?? 5) / 100).over(card),
                "pick": mix.alpha((p["pick"] ?? 9) / 100).over(card)]
    }
    /// The soft surfaces' gates: text 4.5:1 on a hover and a pick (ink and quiet), the focus ring 3:1 on a pick, and
    /// faint 4.5:1 on the well (the left pane's counts sit there).
    static func surfaceGates(_ c: [String: RGBA], _ sf: [String: RGBA], mode: String) -> [String] {
        var bad: [String] = []
        func gate(_ fg: RGBA, _ bg: RGBA, _ need: Double, _ what: String) {
            let r = RGBA.ratio(fg, bg)
            if r < need - 0.005 { bad.append(String(format: "%@: %@ %.2f:1, needs %.1f:1", mode, what, r, need)) }
        }
        for t in ["ink", "quiet"] { for g in ["hover", "pick", "well"] { gate(c[t]!, sf[g]!, 4.5, "\(t) text on \(g)") } }
        gate(c["faint"]!, sf["well"]!, 4.5, "faint text on well")
        gate(c["accent"]!, sf["pick"]!, 3, "focus ring on pick")
        return bad
    }
    static let defaultEdge = ["light": 40.0, "dark": 34.0]

    /// "#rrggbb", "#rgb", "rgba(r,g,b,a)", "rgb(r g b / a)".
    static func color(_ s: String) -> RGBA? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") {
            var h = String(t.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
            return RGBA(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255, a: 1)
        }
        guard t.hasPrefix("rgb"), let o = t.firstIndex(of: "("), let c = t.lastIndex(of: ")") else { return nil }
        let parts = t[t.index(after: o)..<c].replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return RGBA(r: parts[0] / 255, g: parts[1] / 255, b: parts[2] / 255, a: parts.count > 3 ? parts[3] : 1)
    }

    /// Every job from the eleven colours (PixelKit build.py skin_css): lines are `mix` at 9 / 18 / edge %, tints are a
    /// state colour at 10-14 %, the series colours fold to accent, quiet and faint (a skin keeps colour for states).
    static func derive(_ c: [String: RGBA], edge: Double) -> [String: RGBA] {
        func k(_ n: String) -> RGBA { c[n] ?? RGBA(r: 1, g: 0, b: 1, a: 1) }
        let m = k("mix")
        return ["paper": k("ground"), "card": k("raised"), "soft": k("soft"), "ink": k("ink"), "muted": k("quiet"), "faint": k("faint"),
                "line": m.alpha(0.09), "rule": m.alpha(0.18), "controlEdge": m.alpha(edge / 100), "key": k("soft"), "keyEdge": m.alpha(edge / 100),
                "primary": k("ink"), "primaryEdge": k("ink"), "onPrimary": k("ground"),
                "blue": k("accent"), "mint": k("quiet"), "violet": k("faint"), "coral": k("ink"), "warn": k("waiting"),
                "ok": k("good"), "crit": k("bad"),
                "selected": k("accent").alpha(0.10), "okBg": k("good").alpha(0.12), "warnBg": k("waiting").alpha(0.14),
                "critBg": k("bad").alpha(0.10), "actionBg": k("accent").alpha(0.10)]
    }

    /// PixelKit's gates (build.py skin_problems), worked out in one mode. Each failure is one line.
    static func gates(_ c: [String: RGBA], edge: Double, mode: String) -> [String] {
        var bad: [String] = []
        func gate(_ fg: RGBA, _ bg: RGBA, _ need: Double, _ what: String) {
            let r = RGBA.ratio(fg, bg)
            if r < need - 0.005 { bad.append(String(format: "%@: %@ %.2f:1, needs %.1f:1", mode, what, r, need)) }
        }
        let grounds = ["ground", "raised"]
        for t in ["ink", "quiet", "faint"] { for g in grounds { gate(c[t]!, c[g]!, 4.5, "\(t) text on \(g)") } }
        for t in ["ink", "quiet"] { gate(c[t]!, c["soft"]!, 4.5, "\(t) text on soft") }
        for (tint, pct) in [("accent", 0.10), ("good", 0.12), ("waiting", 0.14), ("bad", 0.10)] {
            for g in grounds { for t in ["ink", "quiet"] { gate(c[t]!, c[tint]!.alpha(pct).over(c[g]!), 4.5, "\(t) text on the \(tint) tint over \(g)") } }
        }
        gate(c["ground"]!, c["ink"]!, 4.5, "text on the main button")
        for g in grounds {
            gate(c["mix"]!.alpha(edge / 100).over(c[g]!), c[g]!, 3, "edge on \(g)")
            for mk in ["accent", "good", "bad", "waiting", "quiet", "faint"] { gate(c[mk]!, c[g]!, 3, "\(mk) as a mark on \(g)") }
        }
        gate(c["accent"]!, c["soft"]!, 3, "focus ring on soft")
        return bad
    }

    /// CSS font list -> families, quotes off: `"Fixel Text", -apple-system, sans-serif` -> [Fixel Text, -apple-system, sans-serif].
    static func families(_ css: String?) -> [String] {
        (css ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
    }

    /// The last layer of a CSS box shadow: its drop, blur and how dark. "none" or nothing: no shadow.
    static func shadow(_ css: String?) -> (y: Double, blur: Double, alpha: Double) {
        guard let css, css != "none" else { return (0, 0, 0) }
        var depth = 0, last = css.startIndex
        for i in css.indices {
            switch css[i] { case "(": depth += 1; case ")": depth -= 1; case "," where depth == 0: last = css.index(after: i); default: break }
        }
        let layer = String(css[last...])
        let px = layer.components(separatedBy: CharacterSet(charactersIn: " ")).compactMap { w -> Double? in
            w.hasSuffix("px") ? Double(w.dropLast(2)) : (w == "0" ? 0 : nil)
        }
        let col = layer.range(of: "rgb").map { String(layer[$0.lowerBound...]) }.flatMap(color)
        return (px.count > 1 ? px[1] : 0, px.count > 2 ? px[2] : 0, col?.a ?? 0.18)
    }

    /// A theme file read and checked. id: the file's name without .json.
    static func parse(id: String, _ j: [String: Any]) -> ThemeSpec {
        var problems: [String] = []
        var modes: [String: [String: RGBA]] = [:]
        let edges = j["edge"] as? [String: Any] ?? [:]
        let exact = j["tokens"] as? [String: Any] ?? [:]
        for mode in ["light", "dark"] {
            let raw = j[mode] as? [String: Any] ?? [:]
            var c: [String: RGBA] = [:]
            for k in keys {
                if let v = (raw[k] as? String).flatMap(color), v.a == 1 { c[k] = v } else { problems.append("\(mode): needs a #rrggbb value for \(k)") }
            }
            guard c.count == keys.count else { continue }
            let edge = (edges[mode] as? Double) ?? (edges[mode] as? Int).map(Double.init) ?? defaultEdge[mode]!
            problems += gates(c, edge: edge, mode: mode)
            var jobs = derive(c, edge: edge)
            for (k, v) in exact[mode] as? [String: String] ?? [:] { if jobs[k] != nil, let col = color(v) { jobs[k] = col } }   // exact values (pixel)
            let pct = ((j["surface"] as? [String: Any])?[mode] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            let sf = surfaces(jobs, mode: mode, pct: pct)
            problems += surfaceGates(c, sf, mode: mode)
            jobs.merge(sf) { a, _ in a }
            modes[mode] = jobs
        }
        let f = j["fonts"] as? [String: String] ?? [:], one = j["font"] as? String
        let body = families(f["body"] ?? one), display = families(f["display"] ?? one ?? f["body"])
        let tabular = (j["numbers"] as? String) == "tabular"
        let mono = families(f["mono"]).isEmpty ? (tabular ? [] : ["JetBrains Mono", "ui-monospace"]) : families(f["mono"])
        var corners = (j["corners"] as? [Any] ?? []).compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
        if corners.count != 4 { if j["corners"] != nil { problems.append("corners: four radii, from square to the largest") }; corners = [0, 4, 8, 12] }
        func nums(_ k: String, _ d: [String: Double]) -> [String: Double] {
            d.merging(((j[k] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }.filter { d[$0.key] != nil && $0.value >= 0 && $0.value <= 400 }) { _, b in b }
        }
        return ThemeSpec(id: id, name: j["name"] as? String ?? id, light: modes["light"] ?? [:], dark: modes["dark"] ?? [:],
                         display: display, body: body, mono: mono, tabular: tabular, corners: corners,
                         shadow: shadow(j["shadow"] as? String ?? "0 1px 2px rgb(0 0 0 / .06), 0 8px 24px -6px rgb(0 0 0 / .18)"),
                         problems: problems, radii: nums("radii", defaultRadii), motion: nums("motion", defaultMotion))
    }
}
