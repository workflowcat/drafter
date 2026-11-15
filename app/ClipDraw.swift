// How a link, file or picture row looks on a tape (round three, 14 November 2026): the Quick panel and the window's
// tape both draw a copied row through these, so the kinds read the same in both. Pure drawing, no state but the
// thumbnail cache. Kinds and keys: app/ClipRules.swift.
import AppKit
import ImageIO

extension TapeDraw {
    /// The glyph a copied row shows for what it is (nil: the source's own glyph).
    static func clipMark(_ k: ClipKind) -> String? {
        switch k { case .link: return "globe"; case .file: return "file"; case .image: return "image"; case .text: return nil }
    }

    /// One line for a link, file or picture row: the main part in ink, the rest muted. nil for plain text.
    static func clipParts(_ k: ClipKind, text: String, title: String, bytes: Int, ocr: String) -> (main: String, rest: String)? {
        switch k {
        case .link:
            let p = ClipRules.parts(text)
            let rest = title.isEmpty ? p.last : title   // the page's title when the copy carried one, else the path's last part
            return (p.host, rest)
        case .file:
            let p = ClipRules.fileParts(text)
            return (p.name, ([bytes > 0 ? ClipRules.bytes(bytes) : ""] + [p.folder]).filter { !$0.isEmpty }.joined(separator: " · "))
        case .image:
            let size = text.replacingOccurrences(of: "Image · ", with: "")
            let words = ocr.split(whereSeparator: \.isNewline).joined(separator: " ")
            return (size, [bytes > 0 ? ClipRules.bytes(bytes) : "", String(words.prefix(160))].filter { !$0.isEmpty }.joined(separator: " · "))
        case .text: return nil
        }
    }

    /// Main part then the rest on one line inside `r`, cut at the end; returns false for plain text (nothing drawn).
    @discardableResult
    static func clipLine(_ k: ClipKind, text: String, title: String, bytes: Int, ocr: String, _ r: NSRect, font: NSFont, ink: NSColor = PK.ink) -> Bool {
        guard let (main, rest) = clipParts(k, text: text, title: title, bytes: bytes, ocr: ocr) else { return false }
        let a = at(font, ink, cut: .byTruncatingMiddle), b = at(font, PK.muted)
        let mw = min(r.width, width(main, a))
        line(main, NSRect(x: r.minX, y: r.minY, width: mw, height: r.height), a)
        if !rest.isEmpty, r.width - mw > 40 { line(rest, NSRect(x: r.minX + mw + 10, y: r.minY, width: r.width - mw - 10, height: r.height), b) }
        return true
    }

    // MARK: thumbnails

    private static var thumbs: [String: NSImage] = [:]
    /// A stored picture scaled down once (longest side `px` pixels) and kept in memory; nil when it is gone.
    static func thumb(_ url: URL, px: Int = 360) -> NSImage? {
        let k = url.lastPathComponent + "@\(px)"
        if let i = thumbs[k] { return i }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: px,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        if thumbs.count > 200 { thumbs.removeAll() }
        let i = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[k] = i
        return i
    }
    /// The picture fitted into `box` (aspect kept, top-left), with the theme's control corner and a hairline. Returns
    /// the rectangle it took.
    @discardableResult
    static func picture(_ img: NSImage, in box: NSRect) -> NSRect {
        let s = min(box.width / max(1, img.size.width), box.height / max(1, img.size.height))
        let r = NSRect(x: box.minX, y: box.minY, width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        let path = NSBezierPath(roundedRect: r, xRadius: PK.corner(1), yRadius: PK.corner(1))
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        PK.line.setStroke(); path.lineWidth = 1; path.stroke()
        return r
    }
}

extension Entry {
    /// A clipboard.jsonl row (round three: kind, title, size, stored picture and its read text).
    static func clip(_ r: [String: Any], id: String) -> Entry? {
        guard let t = r["text"] as? String else { return nil }
        var e = Entry(id: id, when: Date(timeIntervalSince1970: r["t"] as? Double ?? 0), app: r["app"] as? String ?? "", text: t, audio: "")
        e.clip = (r["kind"] as? String).flatMap(ClipKind.init(rawValue:)) ?? (r["image"] != nil ? .image : .text)
        e.clipTitle = r["title"] as? String ?? ""; e.bytes = r["bytes"] as? Int ?? 0; e.picture = r["clip"] as? String ?? ""
        if !e.picture.isEmpty { e.ocr = History.clipText(e.picture) }
        if let id = r["shot"] as? String, ShotJournalRules.validId(id) { e.shot = id }
        return e
    }
}
