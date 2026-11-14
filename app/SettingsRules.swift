// How Settings groups his calendars (2026-11-13, window round: rows named "Transferred from xx@…" repeated that phrase
// on every row, and every row carried its account under it). Pure, for a test.
import Foundation

enum CalendarGroups {
    static let transferred = "Transferred from "

    /// Calendars grouped under one heading each: an account (its own calendars, by title), then one "Transferred"
    /// group whose rows are the addresses the calendars came from.
    static func group(_ cals: [(id: String, title: String, source: String)]) -> [(heading: String, rows: [(id: String, name: String)])] {
        var own: [String: [(id: String, name: String)]] = [:], moved: [(id: String, name: String)] = []
        for c in cals {
            if c.title.lowercased().hasPrefix(transferred.lowercased()) {
                let address = String(c.title.dropFirst(transferred.count)).trimmingCharacters(in: .whitespaces)
                moved.append((c.id, address.isEmpty ? c.title : address))
            } else {
                own[c.source.isEmpty ? "Other" : c.source, default: []].append((c.id, c.title))
            }
        }
        var out = own.keys.sorted().map { (heading: $0, rows: own[$0]!.sorted { $0.name.lowercased() < $1.name.lowercased() }) }
        if !moved.isEmpty { out.append((heading: "Transferred", rows: moved.sorted { $0.name.lowercased() < $1.name.lowercased() })) }
        return out
    }
}
