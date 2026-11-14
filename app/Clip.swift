// What he just copied, offered where it fits (1 November 2026; Raycast and Pretype do it). A link or a short text he
// copied in another app in the last 3 minutes shows as a chip when the line asks for it: a link after "link", "here",
// "лінк", "посилання", "ось", "тримай"… or a colon; a short text (one line, ≤120 characters) after a colon. Tab types
// it in. Offered once per copy, never Drafter's own pastes or concealed items (History.watchClipboard decides that).
import AppKit

enum Clip {
    private static var last: (text: String, app: String, at: Date, used: Bool)?
    static let cues: Set<String> = ["link", "links", "url", "here", "here's", "heres", "лінк", "лінка", "лінку", "посилання",
                                    "ось", "от", "тут", "тримай", "тримайте", "лови", "ловіть", "глянь", "гляньте", "дивись"]

    static func copied(_ text: String, from app: String) { last = (text, app, Date(), false) }
    static func used() { last?.used = true }

    static func offer(_ s: Spot) -> [String: Any]? {
        guard let c = last, !c.used, Date().timeIntervalSince(c.at) < 180, c.app != (s.app.bundleIdentifier ?? "") else { return nil }
        let line = (s.before.components(separatedBy: "\n").last ?? "").replacingOccurrences(of: "\u{A0}", with: " ")
        let t = c.text
        let isLink = t.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil
        guard isLink || (t.count <= 120 && !t.contains("\n")) else { return nil }
        // the line must end with a space or a colon, after a cue word or a colon
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard line.last == " " || line.last == ":", !trimmed.isEmpty else { return nil }
        let colon = trimmed.hasSuffix(":")
        let lastWord = trimmed.split(separator: " ").last.map { String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":,.-—")) } ?? ""
        guard colon || (isLink && cues.contains(lastWord)) else { return nil }
        let new = (line.last == " " ? "" : " ") + t
        var short = isLink ? t.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression) : t
        if short.count > 46 { short = String(short.prefix(45)) + "…" }
        return ["id": "snippet", "chip": "⇥ \(isLink ? "Copied link" : "Copied") · \(short)",
                "run": ["kind": "expand", "old": "", "new": new, "key": "clip"]]
    }
}
