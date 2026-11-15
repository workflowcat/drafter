import Foundation

// swiftc -parse-as-library app/JournalStore.swift tests/journal_store.swift -o app/build/journal-store-test && app/build/journal-store-test
// The journal's own store in a temporary folder (never data/): a change beside the original, back to the original,
// Revert and its undo, a draft from Combine kept and read again, the time order of Combine.
@main
struct JournalStoreChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("journal-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.json")
        let s = JournalStore(url: url)
        check(s.changed("t:1") == nil, "nothing changed yet")
        s.change("t:1", to: "See you at the station at nine.", original: "see you at the station at 9")
        check(s.changed("t:1") == "See you at the station at nine.", "a change is kept")
        check(FileManager.default.fileExists(atPath: url.path), "written to the sidecar file")
        let again = JournalStore(url: url)
        check(again.changed("t:1") == "See you at the station at nine.", "read back from the file")
        s.change("t:1", to: "see you at the station at 9", original: "see you at the station at 9")
        check(s.changed("t:1") == nil, "back to the original: no change kept")
        s.change("t:1", to: "Changed text", original: "x")
        let gone = s.revert("t:1")
        check(gone?.text == "Changed text" && s.changed("t:1") == nil, "Revert drops the change and hands it back")
        if let gone { s.restore("t:1", gone) }
        check(s.changed("t:1") == "Changed text", "Undo of Revert puts the change back")
        check(s.revert("nothing") == nil, "Revert with no change: nothing")
        let text = JournalStore.combine([(300, "third"), (100, " first "), (200, "second"), (250, "  ")])
        check(text == "first\n\nsecond\n\nthird", "Combine: time order, blank lines, empty parts out: \(text)")
        let d = s.add(kind: "draft", text: text, sources: ["t:1", "c:2"], pinned: true)
        s.update(d.id, text: text + "\n\nfourth")
        let read = JournalStore(url: url)
        check(read.file.items.count == 1 && read.file.items[0].kind == "draft" && read.file.items[0].sources == ["t:1", "c:2"] && read.file.items[0].pinned, "a draft is kept with its sources")
        check(read.file.items[0].text.hasSuffix("fourth"), "a draft's later text is kept")
        read.pin(d.id, false)
        check(JournalStore(url: url).file.items[0].pinned == false, "Pin off is kept")
        if let gone = read.remove(d.id) {
            check(JournalStore(url: url).file.items.isEmpty, "Delete takes a draft out")
            read.put(gone)
            check(JournalStore(url: url).file.items.count == 1, "Undo of Delete puts it back")
        } else { check(false, "Delete finds the draft") }
        let mem = JournalStore(url: nil)
        mem.change("x", to: "y", original: "z")
        check(mem.changed("x") == "y", "in memory for the preview")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("journal store: all passed")
    }
}
