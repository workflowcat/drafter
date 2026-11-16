// Zoom for a gallery of cards (native round, 16 November 2026; Andrii: pinch out to see a whole day, or several, at a
// glance; a pattern to copy to other galleries later). Pure rules, tested in tests/gallery_zoom.swift:
// - the ladder, far to near: days (one summary row per day), lines (small cards, one summary line each), then the
//   cards in their three sizes; ⌘- and ⌘+ step along it, a pinch steps once for each `pinchStep` of magnification;
// - the summaries: local and cheap, the first line or the first sentence, trimmed; no model, no network;
// - the anchor: after a step, the card under the pointer stays under the pointer;
// - the card's height from its content, between a floor and a ceiling.
import Foundation

enum GalleryZoom {
    enum Level: Int, CaseIterable, Comparable {
        case days, lines, small, medium, large
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        /// The card size step (JournalLayout) of a card level; nil when zoomed out to summaries.
        var cardSize: Int? { rawValue >= Level.small.rawValue ? rawValue - Level.small.rawValue : nil }
        static func cards(_ size: Int) -> Level { Level(rawValue: Level.small.rawValue + Swift.max(0, Swift.min(2, size))) ?? .medium }
        var name: String { ["Days", "Lines", "Small cards", "Medium cards", "Large cards"][rawValue] }
        /// The short mark in the size control.
        var mark: String { ["Days", "Lines", "S", "M", "L"][rawValue] }
    }

    /// `d` steps nearer (+) or farther (-), held at both ends.
    static func step(_ l: Level, by d: Int) -> Level {
        Level(rawValue: Swift.max(0, Swift.min(Level.allCases.count - 1, l.rawValue + d))) ?? l
    }

    // MARK: the pinch

    /// Magnification over one gesture (NSEvent.magnification sums to it); one level per `pinchStep`.
    static let pinchStep = 0.22
    struct Pinch: Equatable {
        var sum = 0.0
        /// Adds one event's magnification; returns the levels to move now (+ nearer, - farther) and keeps the rest.
        mutating func add(_ m: Double) -> Int {
            sum += m
            let n = Int((sum / GalleryZoom.pinchStep).rounded(.towardZero))
            sum -= Double(n) * GalleryZoom.pinchStep
            return n
        }
    }

    // MARK: summaries

    /// One line for a card: the first line with words, cut at its first sentence end when that comes after a few
    /// words, else at a word before `max` characters, with an ellipsis.
    static func summary(_ text: String, max: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        var s = line
        // the first sentence, when it is not just a word or two ("Hi. ...")
        let ends: [Character] = [".", "!", "?", "…"]
        var i = s.startIndex
        while i < s.endIndex {
            let n = s.index(after: i)
            if ends.contains(s[i]), n == s.endIndex || s[n] == " " {
                let words = s[..<i].split(separator: " ").count
                if words >= 4 { s = String(s[...i]); break }
            }
            i = n
        }
        guard s.count > max else { return s }
        let cut = s.prefix(max)
        let at = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return at.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—")) + "…"
    }

    /// One line for a day: the distinct summaries of its items in order, joined, at most `max` characters.
    static func day(_ texts: [String], max: Int = 160) -> String {
        var seen = Set<String>(), parts: [String] = []
        for t in texts {
            let s = summary(t, max: 48)
            guard !s.isEmpty, seen.insert(s.lowercased()).inserted else { continue }
            parts.append(s)
        }
        var out = ""
        for p in parts {
            let next = out.isEmpty ? p : out + " · " + p
            if next.count > max { return out.isEmpty ? summary(p, max: max) : out + " …" }
            out = next
        }
        return out
    }

    // MARK: the anchor

    /// Where to scroll after a step so the card under the pointer stays under it. `pointer`: the pointer's y in the
    /// page before; `top`: the visible top before; `old`, `new`: the card's top and height before and after;
    /// `page`, `view`: the page's and the visible height after. Returns the new visible top.
    static func anchor(pointer: Double, top: Double, old: (y: Double, h: Double), new: (y: Double, h: Double), page: Double, view: Double) -> Double {
        let frac = old.h > 0 ? Swift.max(0, Swift.min(1, (pointer - old.y) / old.h)) : 0
        let y = new.y + frac * new.h - (pointer - top)
        return Swift.max(0, Swift.min(Swift.max(0, page - view), y))
    }

    // MARK: sizes

    /// The lines level: card width and height, the day rows' height.
    static let lineCardMin = 168.0, lineCardH = 52.0, dayRowH = 58.0

    /// A card as tall as its content: `top` + content + `foot`, the content held between `minContent` and
    /// `maxContent`. Rounded up to whole points.
    static func fit(content: Double, top: Double, foot: Double, minContent: Double, maxContent: Double) -> Double {
        (top + Swift.max(minContent, Swift.min(maxContent, content)) + foot).rounded(.up)
    }
}
