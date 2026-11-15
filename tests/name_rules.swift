// swiftc -O -parse-as-library app/NameRules.swift tests/name_rules.swift -o app/build/name-rules-test && app/build/name-rules-test
// Made-up names only. Run from the repo root (reads tests/names_cases.json, the golden cases engine/names.py runs too).
import Foundation

@main struct Checks {
    static func norm(_ v: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["v": v], options: [.sortedKeys]), as: UTF8.self)
    }
    static func main() throws {
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "tests/names_cases.json"))) as! [[String: Any]]
        for c in cases {
            var es = c["entries"] as! [[String: Any]]
            NameRules.apply(&es, c["edits"] as! [[String: Any]])
            let fields = c["fields"] as! [String]
            var got: [String: Any] = [:]
            for e in es { got[e["id"] as! String] = Dictionary(uniqueKeysWithValues: fields.map { ($0, e[$0] ?? NSNull()) }) }
            precondition(norm(got) == norm(c["expect"]!), "case \(c["name"]!):\n\(norm(got))\n\(norm(c["expect"]!))")
        }
        // search: words of names and forms, mishearings, emails, phone digits; hidden ones only under "hidden"
        let es: [[String: Any]] = [
            ["id": "a", "kind": "person", "uk": "Ганна Квітка", "latin": "Hanna Kvitka", "forms": ["Ганною"], "heard": ["hana"], "phones": ["+380 00 000 0001"], "emails": ["hanna@example.test"]],
            ["id": "b", "kind": "project", "uk": "", "latin": "Bramblix", "hidden": true],
            ["id": "c", "kind": "company", "uk": "", "latin": "Larkspur Labs", "short": ["Larkspur"]]]
        precondition(NameRules.filter(es, kind: "", query: "") == [0, 2])
        precondition(NameRules.filter(es, kind: "", query: "ганною") == [0])
        precondition(NameRules.filter(es, kind: "", query: "HANA") == [0])
        precondition(NameRules.filter(es, kind: "", query: "example.test") == [0])
        precondition(NameRules.filter(es, kind: "", query: "000 0001") == [0])
        precondition(NameRules.filter(es, kind: "", query: "lark") == [2])
        precondition(NameRules.filter(es, kind: "company", query: "") == [2])
        precondition(NameRules.filter(es, kind: "hidden", query: "") == [1])
        precondition(NameRules.filter(es, kind: "", query: "zz") == [])
        precondition(NameRules.fold("  Ганна’s   X ") == "ганна's x")
        print("name rules: \(cases.count) golden cases, search ok")
    }
}
