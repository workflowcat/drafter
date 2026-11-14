// Shared native adaptation of PixelKit. Palette: generated PixelTokens.swift; marks, glyphs: generated PixelArt.swift;
// fonts: app/art/ (all from app/sync-pixelkit.py). Fixel for words, Fixel Display for the few titles,
// JetBrains Mono for numbers, times and keys; the system fonts stand in if the files are missing. Native controls,
// focus and window chrome stay.
import AppKit
import SwiftUI

enum PK {
    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    static let paper = PKColors.paper, card = PKColors.card, ink = PKColors.ink, muted = PKColors.muted
    static let faint = PKColors.faint, line = PKColors.line, rule = PKColors.rule, soft = PKColors.soft
    static let blue = PKColors.blue, mint = PKColors.mint, violet = PKColors.violet, coral = PKColors.coral, warn = PKColors.warn
    static let selected = PKColors.selected, key = PKColors.key, keyEdge = PKColors.keyEdge

    // MARK: type

    /// The app's own art folder: in the built app's Resources, else beside the sources (a scratch preview build).
    static let art: URL? = {
        let fm = FileManager.default
        for u in [Bundle.main.resourceURL?.appendingPathComponent("art"), Home.root.appendingPathComponent("app/art")].compactMap({ $0 })
        where fm.fileExists(atPath: u.appendingPathComponent("fonts").path) { return u }
        return nil
    }()
    /// Registers the bundled fonts for this process; once, at start (a few ms, before any panel shows).
    static func registerFonts() {
        if let dir = art?.appendingPathComponent("fonts"),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "woff2" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        }
        ThemeStore.start()   // the theme he picked (data/look.json), before anything draws
    }
    private static var faces: [String: NSFont] = [:]
    /// The theme's face for a role at a size: the first family in its list that is bundled or installed; the system
    /// faces stand in for the generic names. Cached until the theme changes.
    private static func face(_ role: String, _ fams: [String], _ size: CGFloat, _ w: NSFont.Weight, tabular: Bool = false) -> NSFont {
        let key = "\(role)|\(size)|\(w.rawValue)"
        if let f = faces[key] { return f }
        var out: NSFont?
        for fam in fams {
            switch fam.lowercased() {
            case "fixel text": out = NSFont(name: w >= .semibold ? "FixelText-SemiBold" : w >= .medium ? "FixelText-Medium" : "FixelText-Regular", size: size)
            case "fixel display": out = NSFont(name: "FixelDisplay-SemiBold", size: size)
            case "jetbrains mono": out = NSFont(name: w >= .medium ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular", size: size)
            case "-apple-system", "blinkmacsystemfont", "system-ui", "ui-sans-serif", "sans-serif", "sf pro text", "sf pro":
                out = .systemFont(ofSize: size, weight: w)
            case "ui-monospace", "sf mono", "menlo", "monospace": out = .monospacedSystemFont(ofSize: size, weight: w)
            case "serif", "ui-serif": out = NSFont(name: "Georgia", size: size)
            default:
                let nsw = w >= .bold ? 9 : w >= .semibold ? 8 : w >= .medium ? 6 : 5
                out = NSFontManager.shared.font(withFamily: fam, traits: [], weight: nsw, size: size)
            }
            if out != nil { break }
        }
        var f = out ?? .systemFont(ofSize: size, weight: w)
        if tabular {   // even digits in the body face
            let d = f.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                          NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
            f = NSFont(descriptor: d, size: size) ?? f
        }
        faces[key] = f
        return f
    }
    static func forgetFaces() { faces = [:] }
    /// Words: the theme's body face (Fixel Text in pixel).
    static func text(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { face("body", ThemeStore.spec.body, size, w) }
    /// A title or a state word: the theme's display face (Fixel Display in pixel).
    static func display(_ size: CGFloat) -> NSFont { face("display", ThemeStore.spec.display, size, .semibold) }
    /// Numbers, times, keys: the theme's mono face (JetBrains Mono in pixel), or its body face with even digits.
    static func mono(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont {
        let s = ThemeStore.spec
        return s.mono.isEmpty ? face("mono", s.body, size, w, tabular: true) : face("mono", s.mono, size, w)
    }
    /// The theme's corners: 1 keys and tags, 2 controls, 3 floating panels.
    static func corner(_ i: Int) -> CGFloat { CGFloat(ThemeStore.spec.corners[min(3, max(0, i))]) }
    /// The one shadow on what floats, from the theme.
    static func floatShadow() -> NSShadow {
        let s = ThemeStore.spec.shadow, sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(CGFloat(s.alpha) * (dark ? 2.2 : 1.2))
        sh.shadowBlurRadius = CGFloat(s.blur) * 0.6; sh.shadowOffset = NSSize(width: 0, height: -CGFloat(s.y))
        return sh
    }
    static func body(_ size: CGFloat) -> NSFont { text(size) }

    // MARK: corners

    // Small stepped corners on custom overlays; window chrome and controls stay native.
    static func outline(_ b: NSRect, hanging: Bool = false) -> NSBezierPath {
        let p = NSBezierPath(), c: CGFloat = 4
        p.move(to: NSPoint(x:b.minX + (hanging ? 0 : c), y:b.maxY))
        p.line(to: NSPoint(x:b.maxX - (hanging ? 0 : c), y:b.maxY))
        if !hanging { p.line(to: NSPoint(x:b.maxX-c,y:b.maxY-c)); p.line(to: NSPoint(x:b.maxX,y:b.maxY-c)) }
        p.line(to: NSPoint(x:b.maxX,y:b.minY+c)); p.line(to: NSPoint(x:b.maxX-c,y:b.minY+c))
        p.line(to: NSPoint(x:b.maxX-c,y:b.minY)); p.line(to: NSPoint(x:b.minX+c,y:b.minY))
        p.line(to: NSPoint(x:b.minX+c,y:b.minY+c)); p.line(to: NSPoint(x:b.minX,y:b.minY+c))
        p.line(to: NSPoint(x:b.minX,y:b.maxY-(hanging ? 0 : c)))
        if !hanging { p.line(to: NSPoint(x:b.minX+c,y:b.maxY-c)) }
        p.close(); return p
    }

    // MARK: pictures

    /// A PixelKit mark (16 grid) drawn into `r` (a whole multiple of 16 pt looks best; 1 pt cells are 2 px on a 2x
    /// screen). `tint`: every part in one colour, the fills lighter, so the kind's colour carries it; nil keeps the
    /// mark's own colours with its lines in `line`.
    static func drawMark(_ name: String, in r: NSRect, tint: NSColor? = nil, line: NSColor = PK.ink) {
        guard let cells = PixelArt.marks[name] else { return }
        draw(cells, grid: 16, in: r) { fill in
            if let tint { return fill == nil ? tint : tint.withAlphaComponent(tint.alphaComponent * 0.45) }
            return fill.flatMap { UInt32($0, radix: 16) }.map { hex($0) } ?? line
        }
    }
    private static func draw(_ cells: PixelArt.Cells, grid: CGFloat, in r: NSRect, color: (String?) -> NSColor) {
        let u = r.width / grid, flipped = NSGraphicsContext.current?.isFlipped ?? false
        for (fill, rects) in cells {
            color(fill).setFill()
            for (x, y, w, h) in rects {   // the grid counts from the top
                let top = flipped ? r.minY + CGFloat(y) * u : r.maxY - CGFloat(y + h) * u
                NSRect(x: r.minX + CGFloat(x) * u, y: top, width: CGFloat(w) * u, height: CGFloat(h) * u).fill()
            }
        }
    }
    /// A mark as an image (for SwiftUI rows).
    static func markImage(_ name: String, size: CGFloat = 16, tint: NSColor? = nil) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in drawMark(name, in: r, tint: tint, line: PK.ink); return true }
    }
    private static var glyphCache: [String: NSImage] = [:]
    /// A PixelKit line glyph as a template image: it takes the colour of the text around it.
    static func glyph(_ name: String) -> NSImage {
        if let i = glyphCache[name] { return i }
        let body = PixelArt.glyphs[name] ?? ""
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"#000\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\(body)</svg>"
        let i = NSImage(data: Data(svg.utf8)) ?? NSImage()
        i.isTemplate = true; i.accessibilityDescription = name
        glyphCache[name] = i
        return i
    }
}

/// What kind an offer or a record is: one mark and one colour, the same at the caret, in the strip and in the window.
/// PixelKit kinds: item blue (a thing put in: a snippet, a person, a fact, words), action violet (it does something or
/// rewrites), number mint (taken, done), state coral (live, recording, a problem); Drafter gives place's colour, warn,
/// to fixes.
enum Kind {
    case snippet, person, fact, voice, link, action, lookup, translate, rework, fix, next
    var mark: String {
        switch self {
        case .snippet: return "bookmark"; case .person: return "idcard"; case .fact: return "calendar"; case .voice: return "mic"
        case .link: return "link"; case .action: return "bolt"; case .lookup: return "search"; case .translate: return "translate"
        case .rework: return "spark"; case .fix: return "pencil"; case .next: return "chat"
        }
    }
    var color: NSColor {
        switch self {
        case .snippet, .person, .fact, .voice, .link, .next: return PK.blue
        case .action, .lookup, .translate, .rework: return PK.violet
        case .fix: return PK.warn
        }
    }
    /// The kind of a chip from its action id.
    static func of(_ id: String) -> Kind {
        switch id {
        case "snippet": return .snippet; case "person": return .person; case "fact": return .fact; case "preset": return .link
        case "lookup": return .lookup; case "translate": return .translate; case "proofread": return .fix
        default: return id.hasPrefix("voice.") ? .voice : .action
        }
    }
}

enum UIInk {
    static let paper = Color(nsColor: PK.paper), ink = Color(nsColor: PK.ink)
    static let muted = Color(nsColor: PK.muted), faint = Color(nsColor: PK.faint)
    static let line = Color(nsColor: PK.line), soft = Color(nsColor: PK.soft)
    static let blue = Color(nsColor: PK.blue), coral = Color(nsColor: PK.coral)
    static let selected = Color(nsColor: PK.selected), key = Color(nsColor: PK.key)
    static let keyEdge = Color(nsColor: PK.keyEdge), rule = Color(nsColor: PK.rule), card = Color(nsColor: PK.card)
    static let mint = Color(nsColor: PK.mint), violet = Color(nsColor: PK.violet), warn = Color(nsColor: PK.warn)
    static let primary = Color(nsColor: PKColors.primary), onPrimary = Color(nsColor: PKColors.onPrimary)
}

/// SwiftUI faces: Fixel for words, Fixel Display for titles, JetBrains Mono for numbers.
enum PKFont {
    static func text(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> Font { Font(PK.text(size, w)) }
    static func display(_ size: CGFloat) -> Font { Font(PK.display(size)) }
    static func mono(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> Font { Font(PK.mono(size, w)) }
}

/// A PixelKit line glyph in SwiftUI, in the colour of the text around it.
struct Glyph: View {
    let name: String
    var size: CGFloat = 16
    init(_ name: String, size: CGFloat = 16) { self.name = name; self.size = size }
    var body: some View { Image(nsImage: PK.glyph(name)).resizable().renderingMode(.template).frame(width: size, height: size).accessibilityHidden(true) }
}

/// A PixelKit mark in SwiftUI (16 pt: one cell is two screen pixels).
struct PixelMark: View {
    let name: String
    var tint: Color? = nil
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { ctx, s in
            guard let cells = PixelArt.marks[name] else { return }
            let u = s.width / 16
            for (fill, rects) in cells {
                let c: Color = tint.map { fill == nil ? $0 : $0.opacity(0.45) }
                    ?? fill.flatMap { UInt32($0, radix: 16) }.map { Color(nsColor: PK.hex($0)) } ?? UIInk.ink
                for (x, y, w, h) in rects { ctx.fill(Path(CGRect(x: CGFloat(x) * u, y: CGFloat(y) * u, width: CGFloat(w) * u, height: CGFloat(h) * u)), with: .color(c)) }
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
        .id(scheme)
    }
}


// MARK: themes

/// The theme in use and the ones he can pick. Built in: art/themes/*.json (pixel, PixelKit's own look, the default;
/// PixelKit's skins coffee, saggar, benidorm). His own: data/themes/*.json, the same format (docs/themes.md). A theme
/// that fails PixelKit's contrast gates is refused: the reasons go to the log and to Settings. The pick and the mode
/// (follow the system, light, dark) live in data/look.json and apply at once, no restart.
enum ThemeStore {
    struct Built { let spec: ThemeSpec; let light: [String: NSColor]; let dark: [String: NSColor] }
    static let changed = Notification.Name("DrafterThemeChanged")
    private static var built = make(fallback())
    static var spec: ThemeSpec { built.spec }
    private(set) static var mode = "system"
    /// Themes refused at the last load: id -> reasons.
    private(set) static var refused: [String: [String]] = [:]

    static func color(_ job: String) -> NSColor {
        NSColor(name: "Drafter.\(job)") { ap in
            let b = built
            return (ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? b.dark[job] : b.light[job]) ?? .magenta
        }
    }

    private static func ns(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
    private static func make(_ s: ThemeSpec) -> Built {
        Built(spec: s, light: s.light.mapValues(ns), dark: s.dark.mapValues(ns))
    }
    /// PixelKit's own values, compiled in: what draws when no theme file loads.
    private static func fallback() -> ThemeSpec {
        func m(_ d: [String: (UInt32, CGFloat)]) -> [String: RGBA] {
            d.mapValues { v in RGBA(r: Double((v.0 >> 16) & 255) / 255, g: Double((v.0 >> 8) & 255) / 255, b: Double(v.0 & 255) / 255, a: Double(v.1)) }
        }
        return ThemeSpec(id: "pixel", name: "Pixel", light: m(PKColors.pixelLight), dark: m(PKColors.pixelDark),
                         display: ["Fixel Display", "Fixel Text"], body: ["Fixel Text"], mono: ["JetBrains Mono"], tabular: false,
                         corners: [0, 4, 8, 12], shadow: (8, 24, 0.18), problems: [])
    }

    static var builtInDir: URL? { PK.art?.appendingPathComponent("themes") }
    static let userDir = Home.data.appendingPathComponent("themes")
    static let choiceFile = Home.data.appendingPathComponent("look.json")

    /// Every theme, built in first (pixel at the top), then his. Refused ones are left out and listed in `refused`.
    static func all() -> [ThemeSpec] {
        var out: [ThemeSpec] = [], bad: [String: [String]] = [:]
        for (dir, mine) in [(builtInDir, false), (userDir, true)] {
            guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = (mine ? "my-" : "") + f.deletingPathExtension().lastPathComponent
                guard let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                    bad[id] = ["not a JSON object"]; continue
                }
                let s = ThemeRules.parse(id: id, j)
                if s.problems.isEmpty { out.append(s) } else { bad[id] = s.problems }
            }
        }
        for (id, why) in bad.sorted(by: { $0.key < $1.key }) where refused[id] != why { log("theme: \(id) refused: " + why.prefix(3).joined(separator: "; ")) }
        refused = bad
        if let i = out.firstIndex(where: { $0.id == "pixel" }) { out.insert(out.remove(at: i), at: 0) }
        return out
    }

    /// At start: his pick from data/look.json.
    static func start() {
        let j = (try? Data(contentsOf: choiceFile)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        mode = j["mode"] as? String ?? "system"
        let id = j["theme"] as? String ?? "pixel"
        if id != "pixel" || builtInDir != nil, let s = all().first(where: { $0.id == id }) { built = make(s) }
        applyMode()
    }

    /// Picks a theme and a mode, saves them and redraws everything that is open.
    static func pick(_ id: String? = nil, mode m: String? = nil, save: Bool = true) {
        if let id, let s = all().first(where: { $0.id == id }) { built = make(s) }
        if let m { mode = m }
        PK.forgetFaces()
        applyMode()
        if save, let d = try? JSONSerialization.data(withJSONObject: ["theme": built.spec.id, "mode": mode], options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(at: Home.data, withIntermediateDirectories: true)
            try? d.write(to: choiceFile, options: .atomic)
        }
        NotificationCenter.default.post(name: changed, object: nil)
        for w in NSApp.windows { w.contentView?.needsDisplay = true; w.contentView?.subviews.forEach { $0.needsDisplay = true }; w.invalidateShadow() }
        log("theme: \(built.spec.id), \(mode)")
    }
    private static func applyMode() {
        guard NSApp != nil else { DispatchQueue.main.async { applyMode() }; return }   // at start: once the app exists
        NSApp.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
    /// For the previews: a theme by id, without saving.
    static func use(_ id: String) { if let s = all().first(where: { $0.id == id }) { built = make(s); PK.forgetFaces() } }
}
