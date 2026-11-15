// Parity round (15 November 2026): Settings > Typing rows for the personal-style slider and the writing instructions
// (one for every app, one per app). Rules: app/ParityRules.swift. Laid out on the settings grid (TapeSettings.swift):
// SettingsView.parityRows puts these into `line {}` cells.
import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder var parityRows: some View {
        let s = m.settings
        row("Use what I just copied", s.clipContext, typing: true) { $0.clipContext = $1 }
        row("⌥1 ⌥2 ⌥3 pick another suggestion", s.alternatives, typing: true) { $0.alternatives = $1 }
        line(gutter: "\(s.personalStrength)%") { StrengthSlider(initial: s.personalStrength) }
        line(gutter: "All apps") { NoteField(bundle: nil, initial: s.writingNote) }
        ForEach(s.appNotes.keys.sorted(), id: \.self) { id in
            line(gutter: NoteField.name(id)) { NoteField(bundle: id, initial: s.appNotes[id] ?? "") }
        }
        line { AddNoteApp(taken: Set(s.appNotes.keys)) }
    }
}

/// Personal style: 0-100 % of his trained layer. Sent once the slider is let go; the engine merges the layer again
/// (a few seconds, typing answers from his words meanwhile) and the time shows beside it.
struct StrengthSlider: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var cat = ModelCatalog.shared      // model catalog: a model without his layer has no style to scale
    let initial: Int
    @State private var value = 100.0
    @State private var status = ""
    var reason: String? { ModelPick.styleReason(layer: ModelPick.hasLayer(cat.rows, id: m.settings.typingModel)) }
    var body: some View {
        HStack(spacing: 12) {
            Text("Personal style").font(PKFont.text(16)).lineLimit(1).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: 0...100, step: 10) { editing in
                guard !editing else { return }
                let v = Strength.clamp(value)
                guard v != m.settings.personalStrength else { return }
                m.save { $0.personalStrength = v }
                status = "…"
                Engine.shared.post("/strength", ["value": v], timeout: 60) { j in
                    DispatchQueue.main.async {
                        status = (j?["seconds"] as? Double).map { String(format: "%.1f s", $0) } ?? "next start"
                        log("strength \(v)% \(status)")
                    }
                }
            }
            .accessibilityLabel("Personal style").accessibilityValue("\(Int(value)) percent")
            .disabled(reason != nil)
            Text(reason ?? status).font(PKFont.mono(13)).foregroundStyle(UIInk.muted).frame(width: 80, alignment: .trailing)
        }
        .padding(.trailing, SettingsGrid.cloud + 12)
        .onAppear { value = Double(initial) }
    }
}

/// One writing instruction: for every app (bundle nil) or for one app. Saved when he presses Return or leaves the
/// field; an empty app instruction removes its row.
struct NoteField: View {
    @EnvironmentObject var m: WindowModel
    let bundle: String?
    let initial: String
    @State private var value = ""
    @FocusState private var focused: Bool
    static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    func save() {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = bundle {
            guard v != (m.settings.appNotes[id] ?? "") || v.isEmpty else { return }
            m.save { if v.isEmpty { $0.appNotes.removeValue(forKey: id) } else { $0.appNotes[id] = v } }
        } else {
            guard v != m.settings.writingNote else { return }
            m.save { $0.writingNote = v }
        }
    }
    var body: some View {
        TextField(bundle == nil ? "How I write everywhere" : "How I write here", text: $value)
            .textFieldStyle(.roundedBorder).font(PKFont.text(14)).focused($focused).onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .padding(.trailing, SettingsGrid.cloud + 12)
            .onAppear { value = initial.trimmingCharacters(in: .whitespaces) }
    }
}

/// The app picker for a new per-app instruction: the apps open now, by name.
struct AddNoteApp: View {
    @EnvironmentObject var m: WindowModel
    let taken: Set<String>
    var body: some View {
        SwiftUI.Menu("Add an app") {
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { a -> (String, String)? in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
                .filter { !taken.contains($0.0) && $0.0 != Home.bundleID }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            ForEach(apps, id: \.0) { a in
                Button(a.1) { m.save { $0.appNotes[a.0] = " " } }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().font(PKFont.text(14))
    }
}
