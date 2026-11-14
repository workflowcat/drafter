// Markup's model (round three, Part C, 14 November 2026): the marks on a captured picture, the tool keys, undo and
// redo, the crop, and how a point in the editor maps onto the picture. Pure (CoreGraphics types only), tested in
// tests/shot_rules.swift. Drawing and the editor panel: app/Markup.swift. Our own layer, no dependency (the options
// weighed: docs/rounds/2026-11-14-quick.md, Part C).
import Foundation
import CoreGraphics

enum MarkTool: Int, CaseIterable { case arrow = 1, box, highlight, label, pixelate, crop
    var word: String {
        switch self { case .arrow: return "arrow"; case .box: return "box"; case .highlight: return "highlight"
        case .label: return "text"; case .pixelate: return "blur"; case .crop: return "crop" }
    }
}

/// One mark, in picture pixels (origin top-left).
struct PicMark: Equatable {
    var tool: MarkTool
    var from: CGPoint
    var to: CGPoint
    var text = ""
    var rect: CGRect { CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y)) }
}

struct Markup: Equatable {
    let size: CGSize                      // the picture, in pixels
    var tool = MarkTool.arrow
    private(set) var marks: [PicMark] = []
    private(set) var undone: [PicMark] = []

    init(size: CGSize) { self.size = size }

    /// Keys 1-6 pick the tool (key codes 18 19 20 21 23 22 on any layout).
    static let toolCodes: [Int: MarkTool] = [18: .arrow, 19: .box, 20: .highlight, 21: .label, 23: .pixelate, 22: .crop]

    /// A finished drag; a drag shorter than 4 px is a click (only the label takes a click). Crop replaces any older crop.
    mutating func add(_ m: PicMark) {
        let len = hypot(m.to.x - m.from.x, m.to.y - m.from.y)
        guard m.tool == .label ? !m.text.isEmpty : len >= 4 else { return }
        var m = m
        m.from = clamp(m.from); m.to = clamp(m.to)
        if m.tool == .crop { marks.removeAll { $0.tool == .crop } }
        marks.append(m); undone = []
    }
    mutating func undo() { if let m = marks.popLast() { undone.append(m) } }
    mutating func redo() { if let m = undone.popLast() { marks.append(m) } }
    var canUndo: Bool { !marks.isEmpty }

    /// The crop (the last one), else the whole picture.
    var crop: CGRect {
        guard let c = marks.last(where: { $0.tool == .crop })?.rect, c.width >= 4, c.height >= 4 else { return CGRect(origin: .zero, size: size) }
        return c.integral.intersection(CGRect(origin: .zero, size: size))
    }
    private func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height)) }

    /// The picture fitted into `box` (aspect kept, centred): its rectangle there and the scale.
    static func fit(_ size: CGSize, in box: CGRect) -> (rect: CGRect, scale: CGFloat) {
        let s = min(box.width / max(1, size.width), box.height / max(1, size.height), 1)
        let w = (size.width * s).rounded(), h = (size.height * s).rounded()
        return (CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h), s)
    }
    /// A point in the editor (flipped, top-left) to picture pixels.
    static func toPicture(_ p: CGPoint, fitted r: CGRect, scale s: CGFloat) -> CGPoint {
        CGPoint(x: ((p.x - r.minX) / s).rounded(), y: ((p.y - r.minY) / s).rounded())
    }
    /// Line width and label size for a picture this big (readable when it is pasted at its own size).
    static func stroke(_ size: CGSize) -> CGFloat { max(3, (max(size.width, size.height) / 260).rounded()) }
    static func labelSize(_ size: CGSize) -> CGFloat { max(16, (max(size.width, size.height) / 42).rounded()) }
    /// The pixelate block: big enough that text under it cannot be read back.
    static func block(_ r: CGRect) -> Int { max(8, Int(min(r.width, r.height) / 6)) }
}
