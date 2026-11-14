import Foundation

// swiftc -parse-as-library app/Transcript.swift app/Recording.swift app/CaptureRules.swift tests/recording_docs.swift -o app/build/recording-docs-test && app/build/recording-docs-test
@main
struct RecordingDocChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        // a note as notes.py writes it
        let md = """
        # Дзвінок: Weekly sync

        Про: Mila Synthetic, Sava

        ## Головне
        - Agreed on the plan
        - Demo on Friday

        ## Розшифровка
        Я: - not a bullet
        Вони: ok

        ## Фоловапи
        - Mila: send the act

        Запис: /tmp/calls/x
        """
        guard let (audio, n) = NoteFile.parse(md, path: "/n.md") else { check(false, "note parses"); return }
        check(audio == "/tmp/calls/x", "note points at its recording")
        check(n.title == "Weekly sync" && n.people == ["Mila Synthetic", "Sava"], "title and people")
        check(n.points == ["Agreed on the plan", "Demo on Friday"] && n.followups == ["Mila: send the act"], "summary and follow-ups only from their sections")

        // a folder with timed lines and a screenshot
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["call": true, "app": "Zoom", "started": 1_800_000_000.0, "event": ["title": "Weekly sync", "people": ["alex", "mila"]]]
        try! JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        let rows: [[String: Any]] = [["who": "Я", "start": 1.0, "text": "Привіт."], ["who": "Я", "start": 2.5, "text": "Покажу схему."],
                                     ["who": "Вони", "start": 4.0, "text": "Бачу схему, а де акт?"], ["who": "Я", "start": 9.0, "text": "Акт надішлю ввечері."]]
        try! JSONSerialization.data(withJSONObject: rows).write(to: dir.appendingPathComponent("lines.json"))
        try! Data(count: 44 + 32000 * 90).write(to: dir.appendingPathComponent("me.wav"))
        let d = CallDoc.load(dir, notes: [dir.path: n])
        check(d.title == "Weekly sync" && d.call && d.hasAudio && !d.live, "event title names it")
        check(d.turns.count == 3 && d.turns[0].text == "Привіт. Покажу схему." && d.turns[0].start == 1.0, "same speaker lines run together")
        check(abs(d.secs - 90) < 0.1, "length from the audio")
        check(d.people == ["Mila Synthetic", "Sava"] && d.points.count == 2 && d.todos.count == 1, "summary from the note")
        CallDoc.me = ["alex"]
        check(CallDoc.load(dir, notes: [:]).people == ["mila"], "the user's own key is not a person (local config)")

        // search
        let t = CallDoc.terms("акт схем")
        check(d.matches(t) && !d.matches(CallDoc.terms("бюджет")), "all words somewhere in it")
        check(d.hits(t).first?.id == 1, "the turn with both words first")
        check(CallDoc.snippet(String(repeating: "слово ", count: 40) + "акт тут", ["акт"], width: 40).hasPrefix("…"), "snippet starts near the word")
        let h = CallDoc.handoff(search: "акт", docs: [d])
        check(h.contains("1 recording, 2 matching lines") && h.contains("[00:09] me: Акт надішлю ввечері.") && h.contains("brief.md"), "search handoff: lines with times and where to read more")
        check(d.handoff().contains("Summary and to-dos: /n.md"), "one recording handoff points at the note")

        // transcript.txt without times, and a long note
        let old = CallDoc.turns("Я: Hello.\nВони: Привит.\nВони: Як справи?\n", call: true)
        check(old.count == 2 && old[1].who == "Вони" && old[1].start == nil, "old call transcript reads as turns")
        let note = CallDoc.turns(String(repeating: "Це одне речення про план. ", count: 30), call: false)
        check(note.count >= 2 && note.allSatisfy { $0.who.isEmpty }, "a long note is cut into paragraphs")

        // brief without times shows no 00:00
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("brief.md"))
        Brief.write(dir: dir, rows: old.map { Brief.Row(who: $0.who, start: 0, text: $0.text) }, shots: [], meta: meta, minutes: 1)
        let brief = (try? String(contentsOf: dir.appendingPathComponent("brief.md"), encoding: .utf8)) ?? ""
        check(brief.contains("**Я:** Hello.") && !brief.contains("[00:00]"), "brief without times")
        try? FileManager.default.removeItem(at: dir)

        // a call with audio and no words (3 November: 1.7 s of microphone, 51 min of the other side, never read)
        let empty = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-empty-\(getpid())")
        try? FileManager.default.removeItem(at: empty)
        try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: ["call": true, "app": "Zoom", "started": 1_800_000_000.0]).write(to: empty.appendingPathComponent("meta.json"))
        try! Data(count: 44 + 32000 * 2).write(to: empty.appendingPathComponent("me.wav"))
        try! Data(count: 44 + 32000 * 120).write(to: empty.appendingPathComponent("them.wav"))
        var e = CallDoc.load(empty, notes: [:])
        check(abs(e.secs - 120) < 0.1 && abs(e.meSecs - 2) < 0.1, "length from the longer side, so the recording is listed")
        var why = e.whyEmpty(warnings: ["Your microphone gives only silence (muted or taken by another app?)"]).map(\.text)
        check(why == ["Not read yet", "Your microphone recorded 2 s of 2 min", "Your microphone gives only silence (muted or taken by another app?)"], "why: \(why)")
        try! "1".write(to: empty.appendingPathComponent(Unread.marker), atomically: true, encoding: .utf8)
        try! FileManager.default.removeItem(at: empty.appendingPathComponent("them.wav"))
        e = CallDoc.load(empty, notes: [:])
        why = e.whyEmpty(warnings: []).map(\.text)
        check(e.unread && why.first == "Reading stopped before it finished" && why.contains("Other side not captured, or silent the whole time"), "unread and no other side: \(why)")
        try! "2".write(to: empty.appendingPathComponent(Unread.marker), atomically: true, encoding: .utf8)
        check(CallDoc.load(empty, notes: [:]).whyEmpty(warnings: []).first?.text == "Reading stopped 2 times before it finished", "gave up after two tries")
        try! "".write(to: empty.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try! FileManager.default.removeItem(at: empty.appendingPathComponent(Unread.marker))
        check(CallDoc.load(empty, notes: [:]).whyEmpty(warnings: []).first?.text == "Read, and no words were found", "read and empty")
        check(d.whyEmpty(warnings: ["x"]).isEmpty, "a recording with words has no why")
        try? FileManager.default.removeItem(at: empty)
        print("recording docs: ok")
    }
}
