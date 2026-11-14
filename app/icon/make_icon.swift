// Renders Drafter's app icon: a graphite rounded square, a white pen line (writing) and a coral dot (voice).
// swift make_icon.swift && iconutil -c icns Drafter.iconset
import AppKit
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let inset = s * 0.09, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(red: 0.19, green: 0.19, blue: 0.21, alpha: 1), ending: NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor.white.withAlphaComponent(0.08).setStroke(); bg.lineWidth = max(1, s * 0.006); bg.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.92)]))
    if let sym = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let z = sym.size
        sym.draw(in: NSRect(x: s / 2 - z.width / 2 - s * 0.03, y: s / 2 - z.height / 2 - s * 0.02, width: z.width, height: z.height))
    }
    let d = s * 0.14
    NSColor(red: 0.95, green: 0.42, blue: 0.38, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: r.maxX - d - s * 0.1, y: r.maxY - d - s * 0.1, width: d, height: d)).fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
try? FileManager.default.createDirectory(atPath: "Drafter.iconset", withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "Drafter.iconset/icon_\(name).png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "preview.png"))
