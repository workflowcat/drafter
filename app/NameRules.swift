// The names reference's pure rules (2026-11-15): his edits on the Names page (spell, merge, hide) and the search.
// The twin of engine/names.py apply_edits; tests/names_cases.json holds the golden cases both sides run
// (tests/name_rules.swift). Entries stay JSON dictionaries so a field this side does not know is kept as it was.
import Foundation

enum NameRules {
    typealias Entry = [String: Any]

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func str(_ e: Entry, _ k: String) -> String { e[k] as? String ?? "" }
    static func list(_ e: Entry, _ k: String) -> [String] { e[k] as? [String] ?? [] }

    /// Canonical names and short forms (engine/names.py labels).
    static func labels(_ e: Entry) -> [String] { ([str(e, "uk"), str(e, "latin")] + list(e, "short")).filter { !$0.isEmpty } }
    static func display(_ e: Entry) -> String { str(e, "uk").isEmpty ? str(e, "latin") : str(e, "uk") }

    static func addUnique(_ into: [String], _ values: [String], folded: Bool = true) -> [String] {
        var out = into
        var seen = Set(out.map { folded ? fold($0) : $0 })
        for v in values where !v.isEmpty {
            let k = folded ? fold(v) : v
            if !seen.contains(k) { out.append(v); seen.insert(k) }
        }
        return out
    }

    /// His edits in order, on entries in store order. spell {op, id, uk?, latin?}: the old spelling becomes a
    /// mishearing; merge {op, id, into}: names, handles, context and links go to `into`, links to `id` move there;
    /// hide {op, id, on}. An edit whose entry is gone does nothing. -> the number applied.
    @discardableResult
    static func apply(_ entries: inout [Entry], _ edits: [Entry]) -> Int {
        var n = 0
        for ed in edits {
            guard let op = ed["op"] as? String, let id = ed["id"] as? String, let i = entries.firstIndex(where: { str($0, "id") == id }) else { continue }
            var e = entries[i]
            switch op {
            case "spell":
                for field in ["uk", "latin"] where ed[field] != nil {
                    let new = (ed[field] as? String ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    let old = str(e, field)
                    guard !new.isEmpty, new != old else { continue }
                    var heard = list(e, "heard")
                    if !old.isEmpty { heard = addUnique(heard, [old]) }
                    e[field] = new
                    e["heard"] = heard.filter { fold($0) != fold(new) }
                    e["auto"] = list(e, "auto").filter { $0 != field }
                }
                e["edited"] = true; e.removeValue(forKey: "formed")
                entries[i] = e; n += 1
            case "hide":
                e["hidden"] = ed["on"] as? Bool ?? true
                entries[i] = e; n += 1
            case "merge":
                guard let into = ed["into"] as? String, into != id, let j = entries.firstIndex(where: { str($0, "id") == into }) else { continue }
                var t = entries[j]
                var short = list(t, "short")
                for x in labels(e) { short = addUnique(short, [x]) }
                let own = Set([fold(str(t, "uk")), fold(str(t, "latin"))])
                t["short"] = short.filter { !own.contains(fold($0)) }
                for f in ["forms", "heard", "phones", "emails", "sources", "links"] { t[f] = addUnique(list(t, f), list(e, f), folded: false) }
                var c = t["context"] as? [String: Any] ?? [:]
                let o = e["context"] as? [String: Any] ?? [:]
                c["lines"] = (c["lines"] as? Int ?? 0) + (o["lines"] as? Int ?? 0)
                let ids = addUnique(c["chat_ids"] as? [String] ?? [], o["chat_ids"] as? [String] ?? [], folded: false)
                c["chat_ids"] = ids
                c["chats"] = max(c["chats"] as? Int ?? 0, o["chats"] as? Int ?? 0, ids.count)
                var apps = c["apps"] as? [String: Int] ?? [:]
                for (a, k) in o["apps"] as? [String: Int] ?? [:] { apps[a, default: 0] += k }
                c["apps"] = apps
                c["last_seen"] = max(c["last_seen"] as? String ?? "", o["last_seen"] as? String ?? "")
                t["context"] = c
                t["links"] = list(t, "links").filter { $0 != into && $0 != id }
                entries[j] = t
                entries.remove(at: i)
                for k in entries.indices {
                    let me = str(entries[k], "id")
                    var seen = Set<String>(), out: [String] = []
                    for l in list(entries[k], "links") {
                        let to = l == id ? into : l
                        if to != me, seen.insert(to).inserted { out.append(to) }
                    }
                    entries[k]["links"] = out
                }
                n += 1
            default: continue
            }
        }
        return n
    }

    /// Kinds in the order the page shows them, with their glyphs.
    static let kinds = ["person", "project", "company", "place", "term"]
    static func glyph(_ kind: String) -> String {
        ["person": "user", "project": "file", "company": "app-window", "place": "map", "term": "hash"][kind] ?? "hash"
    }

    /// Does the entry answer the search? Words of its names, forms, short forms and mishearings start with it, a whole
    /// name holds it, an email holds it, or (3+ digits) a phone holds the digits.
    static func matches(_ e: Entry, _ query: String) -> Bool {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty { return true }
        let names = labels(e) + list(e, "forms") + list(e, "heard")
        if names.contains(where: { fold($0).contains(q) }) { return true }
        if list(e, "emails").contains(where: { fold($0).contains(q) }) { return true }
        let digits = q.filter(\.isNumber)
        if digits.count >= 3, digits.count == q.filter({ !$0.isWhitespace && $0 != "+" && $0 != "-" }).count {
            return list(e, "phones").contains { $0.filter(\.isNumber).contains(digits) }
        }
        return false
    }

    /// The rows the page shows: by kind ("" all, "hidden" the hidden ones), then the search; store order kept.
    static func filter(_ entries: [Entry], kind: String, query: String) -> [Int] {
        entries.indices.filter { i in
            let e = entries[i], hidden = e["hidden"] as? Bool ?? false
            if kind == "hidden" { if !hidden { return false } } else if hidden { return false }
            if !kind.isEmpty, kind != "hidden", str(e, "kind") != kind { return false }
            return matches(e, query)
        }
    }
}
