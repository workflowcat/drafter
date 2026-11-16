// The gallery's zoom levels on made-up data (native round, 16 November 2026): a render of each level, the hover
// summary at the zoomed-out levels, and the time of each step. PREVIEW_ONLY=zoom (scripts/look-preview.sh).
import AppKit
import SwiftUI

extension UIShots {
    /// Each step along the ladder, timed by the speed run's clock (model change, update, layout, draw).
    static func zoomTiming(_ m: WindowModel, _ time: (() -> Void) -> Double) -> String {
        guard m.gallery else { return "zoom: the gallery is off" }
        var out: [String] = []
        let start = m.galleryLevel
        for _ in 0..<4 { let from = m.galleryLevel; let t = time { m.zoomGallery(-1) }; out.append(String(format: "%@ → %@ %.0f ms", from.mark, m.galleryLevel.mark, t)) }
        for _ in 0..<4 { let from = m.galleryLevel; let t = time { m.zoomGallery(1) }; out.append(String(format: "%@ → %@ %.0f ms", from.mark, m.galleryLevel.mark, t)) }
        while m.galleryLevel != start { m.zoomGallery(start > m.galleryLevel ? 1 : -1) }
        return "zoom steps: " + out.joined(separator: ", ")
    }

    static func zoomShots(_ folder: String, dark: Bool) throws {
        let cal = TapeBuild.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 45))!.timeIntervalSince1970
        Entities.previewStore = sampleEntities()
        defer { Entities.previewStore = nil }
        TapeBuild.tagCache = [:]
        let model = WindowModel(); model.preview = true; model.now = now
        sampleTape(model, now: now, days: 60, perDay: 8)
        model.docs = try sampleDocs()
        model.settings.journalView = "gallery"
        model.rebuildTape()
        // the week unfolded, so the zoomed-out levels have days to show
        for l in model.lines where l.kind == .chunk || l.kind == .head { model.opens[l.id] = true }
        model.refilter()
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1280, height: 860); model.width = 1280
        func shot(_ name: String, wait: Double = 0.4) throws { RunLoop.current.run(until: Date().addingTimeInterval(wait)); try save(host, folder + "/" + name + ".png") }
        model.setSetting { $0.cardSize = 2 }; model.tapeTick += 1
        try shot("zoom-1-large")
        for (i, name) in ["zoom-2-medium", "zoom-3-small", "zoom-4-lines", "zoom-5-days"].enumerated() {
            model.zoomGallery(-1); try shot(name)
            _ = i
        }
        // the hover summary of a day, and of a card at the lines level (the popover's content, rendered alone)
        func pop(_ id: String, _ name: String) throws {
            guard let g = model.galleryView else { return }
            let (head, lines) = g.hoverText(id, model)
            let v = NSHostingView(rootView: HoverSummary(head: head, lines: lines).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            let z = v.fittingSize
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: z), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = v; v.frame = NSRect(origin: .zero, size: z)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try save(v, folder + "/" + name + ".png")
        }
        try pop("day:2", "zoom-5-days-hover")
        model.zoomGallery(1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        if let id = model.lines.first(where: { $0.kind == .row })?.id { try pop(id, "zoom-4-lines-hover") }
        model.setSetting { $0.cardSize = 1 }; model.galleryFar = nil
    }
}
