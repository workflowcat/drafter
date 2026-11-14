// Markup on a captured picture (round three, Part C, 14 November 2026): arrow, box, highlight, text label, pixelate,
// crop; 1-6 pick the tool, ⌘Z and ⌘⇧Z undo and redo, ↵ accepts, esc goes back. Our own small layer (no dependency;
// the options weighed in docs/rounds/2026-11-14-quick.md). The model is MarkupRules.swift; this file draws marks onto a
// picture (full size on accept, view size while editing) and holds the editor panel. Like the capture, the panel is
// non-activating and never key: his app keeps the caret, keys come through the event tap, the mouse comes here.
import AppKit

enum MarkupDraw {
    static let red = NSColor(srgbRed: 0.90, green: 0.28, blue: 0.30, alpha: 1)
    static let yellow = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 0.42)

    /// The picture with its marks, cropped. `scale`: picture pixels to output pixels (1 on accept; the view's scale
    /// while editing, drawn over an already scaled base). `live`: a mark being dragged, drawn as well.
    static func render(_ base: CGImage, _ m: Markup, scale s: CGFloat = 1, live: PicMark? = nil, cropped: Bool = true) -> CGImage? {
        let W = base.width, H = base.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)   // top-left from here on, as the marks are
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let lw = Markup.stroke(m.size) * s
        for mark in m.marks + (live.map { [$0] } ?? []) where mark.tool != .crop {
            let r = CGRect(x: mark.rect.minX * s, y: mark.rect.minY * s, width: mark.rect.width * s, height: mark.rect.height * s)
            let a = CGPoint(x: mark.from.x * s, y: mark.from.y * s), b = CGPoint(x: mark.to.x * s, y: mark.to.y * s)
            switch mark.tool {
            case .arrow: arrow(a, b, width: lw)
            case .box:
                red.setStroke(); let p = NSBezierPath(roundedRect: r, xRadius: lw, yRadius: lw); p.lineWidth = lw; p.stroke()
            case .highlight:
                ctx.saveGState(); ctx.setBlendMode(.multiply); yellow.setFill(); NSBezierPath(rect: r).fill(); ctx.restoreGState()
            case .label: label(mark.text, at: a, size: Markup.labelSize(m.size) * s)
            case .pixelate: pixelate(ctx, r, block: max(2, Int(CGFloat(Markup.block(mark.rect)) * s)))
            case .crop: break
            }
        }
        if !cropped, let c = m.marks.last(where: { $0.tool == .crop }) ?? (live?.tool == .crop ? live : nil) {
            // while editing: outside the crop goes dark, the picture stays whole
            let r = CGRect(x: c.rect.minX * s, y: c.rect.minY * s, width: c.rect.width * s, height: c.rect.height * s)
            let p = NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H)); p.append(NSBezierPath(rect: r)); p.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill(); p.fill()
            NSColor.white.setStroke(); let e = NSBezierPath(rect: r); e.lineWidth = 1; e.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let out = ctx.makeImage() else { return nil }
        guard cropped else { return out }
        let c = m.crop
        return c.size == m.size ? out : out.cropping(to: CGRect(x: c.minX * s, y: c.minY * s, width: c.width * s, height: c.height * s).integral)
    }

    private static func arrow(_ a: CGPoint, _ b: CGPoint, width lw: CGFloat) {
        let ang = atan2(b.y - a.y, b.x - a.x), head = lw * 4.5, spread: CGFloat = 0.5
        let back = CGPoint(x: b.x - cos(ang) * head * 0.8, y: b.y - sin(ang) * head * 0.8)
        red.setStroke(); red.setFill()
        let shaft = NSBezierPath(); shaft.move(to: a); shaft.line(to: back); shaft.lineWidth = lw; shaft.lineCapStyle = .round; shaft.stroke()
        let tip = NSBezierPath()
        tip.move(to: b)
        tip.line(to: CGPoint(x: b.x - cos(ang - spread) * head, y: b.y - sin(ang - spread) * head))
        tip.line(to: CGPoint(x: b.x - cos(ang + spread) * head, y: b.y - sin(ang + spread) * head))
        tip.close(); tip.fill()
    }

    private static func label(_ text: String, at p: CGPoint, size: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = (text as NSString).size(withAttributes: a), pad = size * 0.35
        let r = CGRect(x: p.x, y: p.y - sz.height / 2 - pad / 2, width: sz.width + 2 * pad, height: sz.height + pad)
        red.setFill(); NSBezierPath(roundedRect: r, xRadius: pad, yRadius: pad).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + pad, y: r.minY + pad / 2), withAttributes: a)
    }

    /// The part under `r` drawn back in blocks: what was there cannot be read back.
    private static func pixelate(_ ctx: CGContext, _ r: CGRect, block: Int) {
        let r = r.integral
        guard r.width >= 2, r.height >= 2, let now = ctx.makeImage(), let part = now.cropping(to: r) else { return }
        let w = max(1, Int(r.width) / block), h = max(1, Int(r.height) / block)
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let tiny = small.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)   // CGImages draw bottom-up
        ctx.draw(tiny, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    static func png(_ img: CGImage) -> Data? { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) }
}

/// The editor: the picture fitted into most of the screen, a slim tool line under it.
final class MarkupEditor {
    static let shared = MarkupEditor()
    private(set) var isOpen = false
    var model = Markup(size: .zero)
    var live: PicMark?
    var typing: PicMark?                         // a text label being typed
    private(set) var base: CGImage?           // the full picture
    private(set) var shown: CGImage?          // the picture at view size
    private(set) var fitted = CGRect.zero, scale: CGFloat = 1
    private var done: ((Data?) -> Void)?
    private var panel: NSPanel?
    let view = MarkupView()
    static let toolH: CGFloat = 52

    func open(_ png: Data, near: NSScreen?, done: @escaping (Data?) -> Void) {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { done(nil); return }
        base = img; model = Markup(size: CGSize(width: img.width, height: img.height)); live = nil; typing = nil
        self.done = done
        let scr = near ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = scr.visibleFrame
        let backing = scr.backingScaleFactor
        // the picture in points is its pixels over the backing scale; at most 80 % of the screen
        let pts = CGSize(width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing)
        let box = CGRect(x: 0, y: 0, width: min(vis.width * 0.8, max(420, pts.width)), height: min(vis.height * 0.8 - Self.toolH, max(240, pts.height)))
        let fit = Markup.fit(model.size, in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
        let size = NSSize(width: max(780, fit.rect.width) + 32, height: fit.rect.height + 32 + Self.toolH)
        fitted = CGRect(x: ((size.width - fit.rect.width) / 2).rounded(), y: 16, width: fit.rect.width, height: fit.rect.height)
        scale = fit.scale
        shown = Self.scaled(img, to: CGSize(width: fit.rect.width * backing, height: fit.rect.height * backing))
        let p = panel ?? {
            let p = CapturePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .popUpMenu; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = view; view.model = self
            return p
        }()
        panel = p
        p.setFrame(NSRect(x: (vis.midX - size.width / 2).rounded(), y: (vis.midY - size.height / 2).rounded(), width: size.width, height: size.height), display: false)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
        p.orderFrontRegardless()
        isOpen = true
        log("markup: open \(img.width)x\(img.height)")
    }

    private static func scaled(_ img: CGImage, to s: CGSize) -> CGImage? {
        let w = max(1, Int(s.width)), h = max(1, Int(s.height))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }

    /// The shown picture's pixels per picture pixel.
    var shownScale: CGFloat { CGFloat(shown?.width ?? 1) / max(1, model.size.width) }

    func close(_ png: Data?) {
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
        log("markup: \(png == nil ? "back" : "accepted, \(model.marks.count) marks")")
        let d = done; done = nil
        d?(png)
    }

    func accept() {
        if typing != nil { commitLabel() }
        guard let b = base, !model.marks.isEmpty, let out = MarkupDraw.render(b, model), let png = MarkupDraw.png(out) else { close(nil); return }
        close(png)
    }

    private func commitLabel() { if let t = typing { model.add(t) }; typing = nil }

    /// A key from the event tap while the editor is open.
    func key(_ code: Int, _ ch: String, cmd: Bool, shift: Bool) {
        if var t = typing {   // a label: letters go into it, ↵ ends it, esc drops it
            switch code {
            case 36, 76: commitLabel()
            case 53: typing = nil
            case 51: if !t.text.isEmpty { t.text.removeLast() }; typing = t
            default:
                if !cmd, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), t.text.count < 120 { t.text += ch; typing = t }
            }
            view.needsDisplay = true; return
        }
        switch code {
        case 53: close(nil)
        case 36, 76: accept()
        case 6 where cmd: shift ? model.redo() : model.undo()
        default: if !cmd, let t = Markup.toolCodes[code] { model.tool = t }
        }
        view.needsDisplay = true
    }

    // the mouse, in view points (flipped)
    func down(_ p: CGPoint) {
        if typing != nil { commitLabel() }
        let q = Markup.toPicture(p, fitted: fitted, scale: scale)
        if model.tool == .label { typing = PicMark(tool: .label, from: q, to: q); view.needsDisplay = true; return }
        live = PicMark(tool: model.tool, from: q, to: q)
    }
    func dragged(_ p: CGPoint) { guard live != nil else { return }; live?.to = Markup.toPicture(p, fitted: fitted, scale: scale); view.needsDisplay = true }
    func up(_ p: CGPoint) { if let l = live { model.add(l) }; live = nil; view.needsDisplay = true }
}

final class MarkupView: NSView {
    weak var model: MarkupEditor?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { model?.down(convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { model?.dragged(convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { model?.up(convert(e.locationInWindow, from: nil)) }
    override func resetCursorRects() { if let m = model { addCursorRect(m.fitted, cursor: .crosshair) } }

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        TapeDraw.surface(bounds)
        if let shown = m.shown {
            let marks = m.typing.map { [$0] } ?? []
            var mk = m.model
            for t in marks where !t.text.isEmpty { mk.add(t) }
            if let img = MarkupDraw.render(shown, mk, scale: m.shownScale, live: m.live, cropped: false) {
                NSImage(cgImage: img, size: m.fitted.size).draw(in: m.fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            PK.line.setStroke(); let e = NSBezierPath(rect: m.fitted.insetBy(dx: -0.5, dy: -0.5)); e.lineWidth = 1; e.stroke()
            if let t = m.typing {   // the caret after the label being typed
                let size = Markup.labelSize(m.model.size) * m.scale
                let w = (t.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width
                PK.blue.setFill()
                NSRect(x: m.fitted.minX + t.from.x * m.scale + w + size * 0.35 + 2, y: m.fitted.minY + t.from.y * m.scale - size * 0.6, width: 2, height: size * 1.2).fill()
            }
        }
        // the tool line: 1-6 with their words (the chosen one lifted), then undo and the two ends
        let y = bounds.height - MarkupEditor.toolH + (MarkupEditor.toolH - TapeDraw.capH) / 2 - 6
        TapeDraw.hairline(x0: 0, x1: bounds.width, y: bounds.height - MarkupEditor.toolH - 6)
        var x: CGFloat = 16
        for t in MarkTool.allCases {
            x = TapeDraw.keyWord("\(t.rawValue)", t.word, x: x, y: y, on: m.model.tool == t, color: m.model.tool == t ? PK.ink : PK.muted, gap: 10)
        }
        let ends: [(String, String)] = [("⌘Z", "undo"), ("↵", "done"), ("esc", "back")]
        var w: CGFloat = 0
        let a = TapeDraw.at(PK.text(13), PK.muted)
        for e in ends { w += 30 + 8 + TapeDraw.width(e.1, a) + 12 }
        var ex = bounds.width - 16 - w + 12
        for e in ends { ex = TapeDraw.keyWord(e.0, e.1, x: ex, y: y, gap: 12) }
    }
}
