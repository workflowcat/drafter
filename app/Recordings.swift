// Recordings as notes (2026-10-30, Andrii: "more similar to Granola: the text, search all of the conversation for a
// quick overview, quickly send info to the agents"). Since the look round "Tape" (14 November 2026) every call and long
// note is a block on the tape (TapeWindow.swift), found by the tape's one search; Return opens it as a page here: the
// recording as a document (title, people, summary,
// to-dos, then the conversation with times and the screenshots where they were taken). "For agent" puts the line that
// points an agent at it on the clipboard; on a search it copies the matching lines of every recording found.
import AppKit
import SwiftUI
import AVFoundation

extension WindowModel {
    /// The recordings, read off the main thread (speed round: every open and every tick read them all on it).
    func loadDocs() {
        DispatchQueue.global(qos: .userInitiated).async {
            let d = WindowModel.readDocs()
            DispatchQueue.main.async { self.applyDocs(d) }
        }
    }

    /// Every recording as a document (any thread).
    static func readDocs() -> [CallDoc] {
        let notes = CallDoc.notesIndex(Home.data.appendingPathComponent("notes"))
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: Spool.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        return dirs.map { CallDoc.load($0, notes: notes) }.filter { !$0.turns.isEmpty || $0.live || $0.secs >= 20 }   // not a few seconds of silence
    }

    func applyDocs(_ list: [CallDoc]) {
        docs = list
        if let d = doc { doc = docs.first { $0.id == d.id } }
        // Read again is under way until a transcript newer than the click is written (an hour at most)
        for (id, since) in rereading {
            let t = (try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: id).appendingPathComponent("transcript.txt").path)[.modificationDate] as? Date) ?? .distantPast
            if t > since || Date().timeIntervalSince(since) > 3600 { rereading[id] = nil }
        }
        rebuildTape()
    }

    /// brief.md for a recording that has none yet (no screenshots, or recorded before briefs existed).
    func ensureBrief(_ d: CallDoc) {
        let url = d.dir.appendingPathComponent("brief.md")
        guard !d.live, !FileManager.default.fileExists(atPath: url.path), !d.turns.isEmpty else { return }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        Brief.write(dir: d.dir, rows: d.briefRows, shots: d.shots, meta: meta, minutes: d.secs / 60)
    }

    func sendToAgent(_ d: CallDoc) {
        if !preview { ensureBrief(d) }
        History.copy(d.handoff())
        status = "On the clipboard for an agent: «\(d.title)»" + (d.shots.isEmpty ? "" : " with \(d.shots.count) screenshots") + " · ⌘V into Claude or Codex"
    }

    func stopRecording() {
        guard !preview else { return }
        Talk.shared.stopRecording("the window")
        status = "Stopped · reading both sides, the note follows in a few minutes"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.loadDocs() }
    }

    func copyNotes(_ d: CallDoc) { History.copy(d.notesMarkdown()); status = "On the clipboard · the notes of «\(d.title)»" }
    func copyTranscript(_ d: CallDoc) { History.copy(d.transcriptText()); status = "On the clipboard · the transcript, \(d.turns.count) turns" }

    // MARK: playing both sides from a line

    func play(_ d: CallDoc, from t: Double) {
        stopPlaying()
        let files = ["me.wav", "them.wav"].map { d.dir.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let ps = files.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        guard let lead = ps.first else { status = "This recording has no audio to play"; return }
        let at = lead.deviceCurrentTime + 0.05
        for p in ps { p.currentTime = min(max(0, t - 0.5), p.duration); p.prepareToPlay(); p.play(atTime: at) }
        players = ps; playing = d.id; playhead = t
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, let p = self.players.first else { return }
            if !self.players.contains(where: { $0.isPlaying }) { self.stopPlaying(); return }
            self.playhead = p.currentTime
        }
    }

    func stopPlaying() {
        players.forEach { $0.stop() }; players = []; playTimer?.invalidate(); playTimer = nil; playing = nil
    }
}

private func stamp(_ t: Double) -> String { Brief.stamp(t) }

/// Search words marked in a text.
enum Mark {
    static func text(_ s: String, _ terms: [String]) -> AttributedString {
        var a = AttributedString(s)
        let low = s.lowercased()
        for t in terms where !t.isEmpty {
            var from = low.startIndex
            while let r = low.range(of: t, range: from..<low.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) {
                    a[lo..<hi].backgroundColor = Color(nsColor: PK.blue).opacity(0.22)
                    a[lo..<hi].foregroundColor = UIInk.ink
                }
                from = r.upperBound
            }
        }
        return a
    }
}

struct DocView: View {
    @EnvironmentObject var m: WindowModel
    let d: CallDoc
    var body: some View {
        let terms = CallDoc.terms(m.query)
        let first = d.hits(terms).map(\.id).min()
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if empty { why } else {
                        if !d.points.isEmpty { section("Summary") { ForEach(Array(d.points.enumerated()), id: \.offset) { _, p in bullet(p, terms) } } }
                        if !d.todos.isEmpty { section("To-dos") { ForEach(Array(d.todos.enumerated()), id: \.offset) { _, p in todo(p, terms) } } }
                        if d.points.isEmpty && d.todos.isEmpty && !d.live {
                            Text(d.note.isEmpty ? "No summary yet" : "The note has no summary").font(PKFont.text(12.5)).foregroundStyle(UIInk.muted)
                        }
                        section(d.live ? "Live transcript" : "Transcript") { conversation }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 26).frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if let first { proxy.scrollTo(first, anchor: .center) }; if empty { m.loadWarnings(d) } }
            .onChange(of: m.query) { _, _ in if let first { withAnimation { proxy.scrollTo(first, anchor: .center) } } }
        }
    }

    /// A finished recording with no words: why, and the one thing that helps.
    var empty: Bool { d.turns.isEmpty && !d.live }
    var reading: Bool { m.rereading[d.id] != nil }

    var why: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(d.whyEmpty(warnings: m.warnings[d.id] ?? []).enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Rectangle().fill(w.problem ? UIInk.coral : UIInk.faint).frame(width: 6, height: 6).offset(y: -2)
                        .accessibilityHidden(true)
                    Text(w.text).font(PKFont.text(14)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if d.hasAudio {
                HStack(spacing: 8) {
                    if reading {
                        ProgressView().controlSize(.small)
                        Text("Reading again…").font(PKFont.text(13)).foregroundStyle(UIInk.muted)
                    } else {
                        Button { m.reread(Entry(id: d.id, when: d.started, app: d.app, text: "", audio: d.id)) } label: {
                            Label { Text("Read again") } icon: { Glyph("refresh", size: 14) }
                        }.buttonStyle(.borderedProminent).keyboardShortcut("r", modifiers: .command).help("Read both sides with today's reader (⌘R)")
                    }
                }.padding(.top, 6)
            }
        }
    }

    var forAgent: some View {
        Button { m.sendToAgent(d) } label: { Label { Text("For agent") } icon: { Glyph("external", size: 14) } }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Copy a line that points Claude or Codex at everything said\(d.shots.isEmpty ? "" : " and the screenshots") (⇧⌘A)")
            .disabled(d.turns.isEmpty)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(([d.kind, CallDoc.day.string(from: d.started)] + (d.secs >= 1 ? [CallDoc.length(d.secs)] : []) + (d.app.isEmpty ? [] : [d.app])).joined(separator: " · "))
                .font(PKFont.mono(11)).foregroundStyle(UIInk.faint)
            Text(d.title).font(PKFont.display(24)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !d.people.isEmpty {
                Flow(spacing: 6) {
                    ForEach(d.people, id: \.self) { p in
                        HStack(spacing: 5) {
                            PixelMark(name: Kind.person.mark, tint: UIInk.blue)
                            Text(p).font(PKFont.text(12.5))
                        }.padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(UIInk.soft))
                    }
                }
            }
            HStack(spacing: 8) {
                if d.live {
                    Button { m.stopRecording() } label: { Label("Stop recording", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(UIInk.coral).help("Same as ⇧ Right Option. The transcript and the note follow.")
                }
                // one main button: For agent, unless there are no words yet (then Read again, below, is the main one)
                if empty { forAgent.buttonStyle(.bordered) } else { forAgent.buttonStyle(.borderedProminent) }
                Button { m.copyNotes(d) } label: { Label { Text("Copy notes") } icon: { Glyph("copy", size: 14) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).help("Title, people, summary and to-dos as Markdown (⇧⌘C)")
                if d.hasAudio {
                    Button { m.playing == d.id ? m.stopPlaying() : m.play(d, from: 0) } label: {
                        Label { Text(m.playing == d.id ? "Stop · \(stamp(m.playhead))" : "Play") } icon: { Glyph(m.playing == d.id ? "pause" : "play", size: 14) }
                            .monospacedDigit()
                    }.help(d.call ? "Both sides together" : "Play the recording")
                }
                SwiftUI.Menu {
                    Button("Copy transcript") { m.copyTranscript(d) }
                    if !d.note.isEmpty { Button("Open the note file") { NSWorkspace.shared.open(URL(fileURLWithPath: d.note)) } }
                    if d.hasAudio, !empty { Button("Read again with the current reader") { m.reread(Entry(id: d.id, when: d.started, app: d.app, text: "", audio: d.id)) }.disabled(reading) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([d.dir]) }
                } label: { Glyph("more", size: 16) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More")
            }.padding(.top, 2)
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PKFont.display(13)).foregroundStyle(UIInk.muted)
            content()
        }
    }

    func bullet(_ s: String, _ terms: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Rectangle().fill(UIInk.ink).frame(width: 4, height: 4).offset(y: -3)
            Text(Mark.text(s, terms)).font(PKFont.text(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    func todo(_ s: String, _ terms: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Rectangle().stroke(UIInk.muted, lineWidth: 1).frame(width: 10, height: 10).offset(y: 1)
            Text(Mark.text(s, terms)).font(PKFont.text(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Turns and screenshots on one timeline; without times the screenshots come first, as a strip.
    enum Item: Identifiable { case turn(Turn), shot(Int, Shot)
        var id: String { switch self { case .turn(let t): return "t\(t.id)"; case .shot(let i, _): return "s\(i)" } }
    }
    var items: [Item] {
        guard d.timed else { return d.turns.map { .turn($0) } }
        var out: [Item] = [], k = 0
        let shots = d.shots.enumerated().map { ($0.offset, $0.element) }
        for t in d.turns {
            while k < shots.count, shots[k].1.t <= (t.start ?? 0) { out.append(.shot(shots[k].0, shots[k].1)); k += 1 }
            out.append(.turn(t))
        }
        out += shots[k...].map { .shot($0.0, $0.1) }
        return out
    }

    var conversation: some View {
        let terms = CallDoc.terms(m.query)
        let hits = Set(d.hits(terms).map(\.id))
        let starts = d.turns.compactMap(\.start)
        let now: Int? = m.playing == d.id ? d.turns.last(where: { ($0.start ?? .infinity) <= m.playhead })?.id : nil
        return VStack(alignment: .leading, spacing: 2) {
            if !d.timed, !d.shots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(Array(d.shots.enumerated()), id: \.offset) { i, s in ShotThumb(dir: d.dir, shot: s, width: 150) } }
                }.padding(.bottom, 8)
            }
            if d.turns.isEmpty { Text(d.live ? "Words appear here as they are heard." : "No words in this recording.").font(PKFont.text(13)).foregroundStyle(UIInk.muted) }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    switch item {
                    case .turn(let t):
                        TurnRow(d: d, t: t, terms: terms, hit: hits.contains(t.id), now: now == t.id, playable: d.hasAudio && !starts.isEmpty).id(t.id)
                    case .shot(_, let s):
                        HStack(alignment: .top, spacing: 10) {
                            Text(stamp(s.t)).font(PKFont.mono(11)).foregroundStyle(UIInk.faint).frame(width: 40, alignment: .leading)
                            ShotThumb(dir: d.dir, shot: s, width: 300)
                        }.padding(.vertical, 6).padding(.horizontal, 8)
                    }
                }
            }
        }
    }
}

struct TurnRow: View {
    @EnvironmentObject var m: WindowModel
    let d: CallDoc
    let t: Turn
    let terms: [String]
    let hit: Bool
    let now: Bool
    let playable: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if d.timed {
                Button { if let s = t.start { m.play(d, from: s) } } label: {
                    Text(t.start.map(stamp) ?? "").font(PKFont.mono(11)).foregroundStyle(now ? UIInk.blue : UIInk.faint)
                }.buttonStyle(.plain).disabled(!playable).frame(width: 40, alignment: .leading).help(playable ? "Play from here" : "")
            }
            if !t.who.isEmpty {
                HStack(spacing: 5) {
                    Rectangle().fill(t.who == "Я" ? UIInk.blue : UIInk.coral).frame(width: 6, height: 6)
                    Text(CallDoc.who(t.who)).font(PKFont.mono(11)).foregroundStyle(UIInk.muted)
                }.frame(width: 50, alignment: .leading)
            }
            Text(Mark.text(t.text, terms)).font(PKFont.text(14)).foregroundStyle(t.who == "Вони" || t.who.isEmpty ? UIInk.ink : UIInk.ink.opacity(0.86))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: PK.corner(1)).fill(now || hit ? UIInk.soft : .clear))
    }
}

struct ShotThumb: View {
    let dir: URL
    let shot: Shot
    let width: CGFloat
    static let cache = NSCache<NSString, NSImage>()
    var image: NSImage? {
        let path = dir.appendingPathComponent(shot.file).path as NSString
        if let i = Self.cache.object(forKey: path) { return i }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path as String) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary)
        else { return nil }
        let i = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        Self.cache.setObject(i, forKey: path); return i
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { NSWorkspace.shared.open(dir.appendingPathComponent(shot.file)) } label: {
                Group {
                    if let i = image { Image(nsImage: i).resizable().aspectRatio(contentMode: .fit) }
                    else { Rectangle().fill(UIInk.soft).aspectRatio(16 / 10, contentMode: .fit) }
                }
                .frame(width: width).overlay { Rectangle().stroke(UIInk.line, lineWidth: 1) }
            }.buttonStyle(.plain).help("Open the screenshot")
            Text([shot.app, shot.title].filter { !$0.isEmpty }.joined(separator: " · ")).font(PKFont.mono(11)).foregroundStyle(UIInk.faint)
                .lineLimit(1).frame(width: width, alignment: .leading)
        }
    }
}

/// Chips that wrap onto the next line.
struct Flow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { y += row + spacing; x = 0; row = 0 }
            x += z.width + spacing; row = max(row, z.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(w, widest), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX, x + z.width > b.maxX { y += row + spacing; x = b.minX; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}
