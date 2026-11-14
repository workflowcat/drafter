// swiftc -O -parse-as-library app/EntityRules.swift app/RefRules.swift tests/entity_rules.swift -o app/build/entity-rules-test && app/build/entity-rules-test
// Made-up entities only. Run from the repo root (reads tests/entity_cases.json, the golden text engine/entities.py makes too).
import Foundation

@main struct Checks {
    static func main() throws {
        // --- the golden cases: the same strings as the Python side
        let g = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "tests/entity_cases.json"))) as! [String: Any]
        let today = g["today"] as! String
        let recs = try JSONDecoder().decode([Entity].self, from: JSONSerialization.data(withJSONObject: g["records"]!))
        let byId = Dictionary(uniqueKeysWithValues: recs.map { ($0.id, $0) })
        for c in g["lines"] as! [[String: Any]] {
            let got = EntityRules.render(byId[c["id"] as! String]!, level: c["level"] as! Int, today: today)
            precondition(got == c["expect"] as! String, "line \(c["id"]!) \(c["level"]!):\n\(got)\n\(c["expect"]!)")
        }
        for c in g["blocks"] as! [[String: Any]] {
            let items = (c["items"] as! [[Any]]).map { EntityRules.Item(entity: byId[$0[0] as! String]!, level: $0[1] as! Int, mentions: $0[2] as! Int) }
            let got = EntityRules.block(items, today: today, limit: c["limit"] as? Int ?? EntityRules.blockMax)
            precondition(got == c["expect"] as! String, "block \(c["name"]!):\n\(got)\n---\n\(c["expect"]!)")
        }
        for c in g["cut"] as! [[String: Any]] { precondition(EntityRules.cut(c["s"] as! String, c["n"] as! Int) == c["expect"] as! String, "cut") }
        for c in g["fold"] as! [[String: Any]] { precondition(EntityRules.fold(c["s"] as! String) == c["expect"] as! String, "fold \(c["s"]!)") }
        print("PASS: packs render the same text as engine/entities.py (\((g["lines"] as! [Any]).count) lines, \((g["blocks"] as! [Any]).count) blocks)")

        // --- a small store with surfaces as the builder writes them
        func ent(_ id: String, _ kind: String, _ name: String, related: [String] = [], heat: Double = 1, cards: Bool = false, targets: [String: String] = [:], handles: [String: [String]] = [:]) -> Entity {
            Entity(id: id, kind: kind, name: name, aliases: [], who: "made-up " + kind, targets: targets, handles: handles, related: related,
                   pack: EntityPack(facts: [], pointers: [EntityPointer(label: "Note", value: "/tmp/\(name).md", path: true)], newest: ""), heat: heat, cards_only: cards)
        }
        var store = EntityStore(records: [
            ent("p:hanna", "person", "Ганна Ткач", related: ["o:lantern"], heat: 6, targets: ["obsidian": "Entities/People/Hanna Tkach"], handles: ["email": ["hanna@example.test"], "tg": ["hanna_x"]]),
            ent("p:hanna2", "person", "Ганна Інша", related: ["o:other"]),
            ent("o:lantern", "org", "Lantern Labs"),
            ent("x:lantern", "project", "Lantern", heat: 3),
            ent("t:gate", "tool", "lantern-gate"),
            ent("o:other", "org", "Other Org"),
            ent("c:card", "person", "Card Only", cards: true, handles: ["email": ["card@example.test"]]),
        ])
        store.surfaces = ["ганна ткач": [EntityHit(index: 0, how: "name")], "ганні": [EntityHit(index: 0, how: "form"), EntityHit(index: 1, how: "form")],
                          "ганна": [EntityHit(index: 0, how: "first"), EntityHit(index: 1, how: "first")], "ткач": [EntityHit(index: 0, how: "part")],
                          "hanna tkach": [EntityHit(index: 0, how: "alias")], "lantern labs": [EntityHit(index: 2, how: "name")],
                          "lantern": [EntityHit(index: 3, how: "name")], "lantern-gate": [EntityHit(index: 4, how: "name")],
                          "card only": [EntityHit(index: 6, how: "name")]]

        // a full name resolves; a case form shared by two does not, unless the context or a pick decides
        var m = EntityRules.mention(before: "напиши Ганна Ткач ", store: store)!
        precondition(m.index == 0 && m.resolved && m.text == "Ганна Ткач" && m.back == 11 && m.length == 10, "\(m)")
        m = EntityRules.mention(before: "дай Ганні", store: store)!
        precondition(m.candidates.count == 2 && !m.resolved, "\(m)")
        // a related name on screen puts her first, but only twice the next score resolves (proposal 2.2): the chooser asks
        let plain = EntityRules.mention(before: "про Lantern Labs і Ганні", store: store)!
        m = EntityRules.mention(before: "про Lantern Labs і Ганні", store: store, context: EntityRules.fold("про Lantern Labs і"))!
        precondition(m.index == 0 && m.score == plain.score + 1 && !m.resolved, "context ranks: \(m)")
        m = EntityRules.mention(before: "дай Ганні", store: store, picks: ["ганні": "p:hanna2"])!
        precondition(m.index == 1 && m.resolved, "a pick decides")
        // the longest name wins over its last word
        m = EntityRules.mention(before: "we pitched Lantern Labs.", store: store)!
        precondition(m.index == 2 && m.text == "Lantern Labs" && m.back == 13, "\(m)")
        // lower case: only a lower-case slug; a person never; a contact-only card never
        precondition(EntityRules.mention(before: "deploy lantern-gate ", store: store)?.index == 4)
        precondition(EntityRules.mention(before: "a lantern ", store: store) == nil)
        precondition(EntityRules.mention(before: "ганна ткач ", store: store) == nil)
        precondition(EntityRules.mention(before: "Card Only ", store: store) == nil)
        precondition(EntityRules.mention(before: "", store: store) == nil)
        let ms = EntityRules.mentions(in: "Ганна Ткач and Lantern Labs, then Lantern.", store: store); precondition(ms == [0, 2, 3], "\(ms)")
        print("PASS: mentions resolve by the longest name, context and picks; lower case and cards stay plain")

        // the `;` card search
        precondition(EntityRules.find(";лан", in: store).isEmpty)
        precondition(EntityRules.find(";lant", in: store) == [3, 2, 4] || EntityRules.find(";lant", in: store).first == 3, "\(EntityRules.find(";lant", in: store))")
        precondition(EntityRules.find(";ганна ткач", in: store) == [0])
        precondition(EntityRules.find("@card", in: store) == [6])
        precondition(EntityRules.find(";h", in: store).isEmpty)
        // the forms for each place
        let h = store.records[0]
        precondition(RefRules.forms(h, dest: "obsidian").first == RefRules.Form(label: "link", text: "[[Entities/People/Hanna Tkach|Ганна Ткач]]"))
        precondition(RefRules.forms(h, dest: "mail").map { $0.label } == ["name", "address", "email", "Telegram", "link"])
        precondition(RefRules.forms(h, dest: "mail")[1].text == "Ганна Ткач <hanna@example.test>")
        precondition(RefRules.forms(h, dest: "ai").first?.label == "context")
        precondition(RefRules.forms(store.records[6], dest: "obsidian").map { $0.label } == ["email"])
        precondition(RefRules.dest(id: "com.googlecode.iterm2", title: "claude ~/Codius", kind: "other") == "agent")
        precondition(RefRules.dest(id: "com.googlecode.iterm2", title: "zsh", kind: "other") == "plain")
        precondition(RefRules.level("agent") == 3 && RefRules.level("ai") == 2 && RefRules.level("chat") == 1)
        print("PASS: the card finds any kind; forms per place; agent apps")

        // --- cost per word end with 5,000 made-up entities and their surfaces
        var big: [Entity] = [], surf: [String: [EntityHit]] = [:]
        let syll = ["ка", "ло", "ри", "на", "те", "ва", "мо", "ди", "ус", "ен", "ko", "ra", "li", "mo", "sa", "te"]
        func word(_ n: Int, _ k: Int) -> String { var s = ""; var x = n &* 2654435761 &+ k; for _ in 0..<3 { s += syll[abs(x) % syll.count]; x /= syll.count }; return s.prefix(1).uppercased() + s.dropFirst() }
        for i in 0..<5000 {
            let name = word(i, 1) + " " + word(i, 7)
            big.append(ent("e:\(i)", EntityRules.kinds[i % 6], name, related: ["e:\((i + 1) % 5000)"], heat: Double(i % 9)))
            for (k, how) in [(name, "name"), (name.components(separatedBy: " ")[0], "first"), (name.components(separatedBy: " ")[1], "part"),
                             (name.components(separatedBy: " ")[0] + "і", "form"), (name.components(separatedBy: " ")[0] + "у", "form")] {
                surf[EntityRules.fold(k), default: []].append(EntityHit(index: i, how: how))
            }
        }
        let bigStore = EntityStore(records: big, surfaces: surf)
        let lines = (0..<2000).map { i -> String in "Сьогодні говорили з " + big[(i * 37) % 5000].name + (i % 3 == 0 ? " про щось " : " ") }
        let ctx = EntityRules.fold(String(lines.joined().suffix(400)))
        var times: [Double] = []
        var found = 0
        for line in lines {
            let t0 = DispatchTime.now().uptimeNanoseconds
            if EntityRules.mention(before: line, store: bigStore, context: ctx) != nil { found += 1 }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        }
        times.sort()
        let p50 = times[times.count / 2], p99 = times[Int(Double(times.count) * 0.99)]
        print(String(format: "cost per word end, 5,000 entities, %d surfaces: p50 %.1f µs, p99 %.1f µs, max %.1f µs (%d of %d lines had a name)",
                     surf.count, p50, p99, times.last!, found, lines.count))
        precondition(p99 < 200, "p99 over 0.2 ms")
        print("PASS: under 0.2 ms per word end at p99")
    }
}
