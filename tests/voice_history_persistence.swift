// Uses a caller-supplied empty scratch directory, never the real Drafter data folder.
import AppKit

enum Home {
    static let data = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
}
final class Pill {
    static let shared = Pill()
    func flash(_ text: String) {}
}

@main struct VoiceHistoryPersistenceChecks {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2, "Supply an empty scratch directory")
        precondition(!FileManager.default.fileExists(atPath: History.takesFile.path), "Use a fresh test directory")
        try FileManager.default.createDirectory(at: Home.data, withIntermediateDirectories: true)
        History.take("", audio: [0, 0.25, -0.25, 0], app: "Synthetic", loud: false,
                     raw: "Незавершений текст", outcome: "timeout")
        History.take("Final text", audio: [], app: "Synthetic", loud: false, raw: "Original text")
        let deadline = Date().addingTimeInterval(3)
        var rows: [[String: Any]] = []
        while Date() < deadline {
            rows = History.read(History.takesFile, last: 10)
            if rows.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(rows.count == 2, "Both asynchronous saves must persist")
        let recovery = rows.first { ($0["outcome"] as? String) == "timeout" }!
        precondition(recovery["text"] as? String == "", "Incomplete words must not be stored as final")
        precondition(recovery["raw"] as? String == "Незавершений текст", "Preserve Unicode preview exactly")
        let path = recovery["audio"] as! String
        precondition(path.hasPrefix(Home.data.path + "/audio/"), "Audio stays in test data")
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        precondition(wav.count == 52 && String(data: wav.prefix(4), encoding: .ascii) == "RIFF", "Persist a playable PCM WAV")
        let entry = Entry.voice(recovery)!
        precondition(entry.incomplete && entry.raw == "Незавершений текст", "Recovery survives save and reload")
        let final = rows.first { ($0["text"] as? String) == "Final text" }!
        precondition(final["raw"] as? String == "Original text", "Keep original and final independently")
        precondition(final["outcome"] == nil, "Normal takes keep backward-compatible storage")
        print("PASS: history persistence, Unicode recovery, PCM audio and normal-take compatibility")
    }
}
