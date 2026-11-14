// Settings on the tape's grid (look round "Tape", 14 November 2026). Each switch is a row: the gutter holds what it
// earned in the last 7 days (the take rate in mono) or a value ("⌃⌥V", "7 today"), then the switch, the name, a
// ten-cell meter coloured by the take rate (under 30 % bad, 30-50 % waiting, 50 % and up good), taken / shown in mono,
// and the cloud glyph when text leaves the Mac. Group headings with a hairline after them. The grid columns are
// 132 · 48 · name · 78 · 112 · 24, as on the concept board.
//
// Rows stay data: SettingsView's body (Window.swift) says `row(name, on, sends:, stat:) { set }` and `group(name) { }`;
// this file is only how they look, so new rows (another track adds some) take the look with no change here.
// Second pass (same day): no sprocket holes, a rounded switch in ink (blue is only focus), hairlines.
import AppKit
import SwiftUI

enum SettingsGrid {
    static let gutter: CGFloat = 132, gap: CGFloat = 20, toggle: CGFloat = 48, meter: CGFloat = 78, numbers: CGFloat = 112, cloud: CGFloat = 24
    static let rowH: CGFloat = 44
    /// 1 470 / 2 410: thousands apart by a thin space, as the concept.
    static func n(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "\u{202F}"; f.groupingSize = 3
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func rateColor(_ r: Double) -> Color { Color(nsColor: r < 0.3 ? PKColors.crit : r < 0.5 ? PKColors.warn : PKColors.ok) }
}

/// The switch: a rounded track, ink when on with the card-coloured knob at the right; off, an outline with a faint
/// knob at the left. Ink in any window state (the system switch turned grey in a window in the back).
struct PKSwitch: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        Button { c.isOn.toggle() } label: {
            ZStack(alignment: c.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 9).fill(c.isOn ? UIInk.ink : Color.clear).frame(width: 32, height: 18)
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(c.isOn ? Color.clear : Color(nsColor: PKColors.controlEdge), lineWidth: 1) }
                Circle().fill(c.isOn ? UIInk.card : UIInk.faint).frame(width: 12, height: 12).padding(3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: c.$isOn) { c.label } }
    }
}

extension SettingsView {
    typealias G = SettingsGrid

    /// One line of the grid: the gutter (with its hairline), then the content; a hairline under it.
    func line<C: View>(gutter: String = "", tall: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            Text(gutter).font(PKFont.mono(13)).foregroundStyle(UIInk.muted).lineLimit(1)
                .frame(width: G.gutter - 14, alignment: .trailing).padding(.trailing, 14)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { Rectangle().fill(UIInk.line).frame(width: 1) }
            content().padding(.leading, G.gap).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: tall ? 56 : G.rowH)
        .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 1) }
    }

    /// One switch: the take rate (or `value`) in the gutter, the switch, its name, the meter and taken / shown when it
    /// has numbers, the cloud when it sends text to Claude. No explanation under it (13 November).
    func row(_ title: String, _ on: Bool, sends: Bool = false, stat: String? = nil, typing: Bool = false, value: String? = nil,
             _ set: @escaping (inout Settings, Bool) -> Void) -> some View {
        let c: LogStats.Count? = stat.flatMap { k in m.stats.map { $0[k] ?? LogStats.Count() } }
        let rate: Double? = c.flatMap { $0.shown > 0 ? min(1, Double($0.taken) / Double($0.shown)) : nil }
        let gutter = rate.map { "\(Int(($0 * 100).rounded()))%" } ?? value ?? ""
        return line(gutter: gutter) {
            HStack(spacing: 0) {
                Toggle(title, isOn: Binding(get: { on && (!sends || m.settings.connect.connected) }, set: { v in m.save { set(&$0, v) } })).toggleStyle(PKSwitch()).labelsHidden()
                    .disabled(sends && !m.settings.connect.connected && !m.preview)   // nothing connected: shown, off, disabled (app/Connect.swift)
                    .frame(width: G.toggle, alignment: .leading)
                Text(title).font(PKFont.text(16)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let c, c.shown > 0 { Meter(share: rate ?? 0, lit: c.taken > 0) } else { Color.clear }
                }.frame(width: G.meter, alignment: .leading)
                Text(c.map { $0.shown > 0 ? "\(G.n($0.taken)) / \(G.n($0.shown))" : "0 / 0" } ?? "")
                    .font(PKFont.mono(13)).foregroundStyle(c?.shown == 0 ? UIInk.faint : UIInk.muted).lineLimit(1)
                    .frame(width: G.numbers, alignment: .trailing)
                Group {
                    if sends { Glyph("cloud", size: 16).foregroundStyle(UIInk.muted).help("Sends text to Claude").accessibilityLabel("Sends text to Claude") }
                    else { Color.clear }
                }.frame(width: G.cloud + 12, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(c.map { "Last 7 days: \($0.taken) taken of \($0.shown) shown" } ?? "")
        }
    }

    /// A group: its heading (18 semibold) with a hairline after it. `column` non-empty: the column heads over the rows
    /// ("7 days" in the gutter, "taken / shown" over the numbers).
    func group<C: View>(_ title: String, column: String = "", @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            line(gutter: column.isEmpty ? "" : "7 days", tall: true) {
                HStack(spacing: 14) {
                    Text(title).font(PKFont.text(18, .semibold)).lineLimit(1).fixedSize()
                    Rectangle().fill(UIInk.line).frame(height: 1)
                    if !column.isEmpty {
                        Text("taken / shown").font(PKFont.text(13)).foregroundStyle(UIInk.faint)
                            .frame(width: G.numbers, alignment: .trailing)
                        Color.clear.frame(width: G.cloud - 2, height: 1)
                    }
                }
            }
            rows()
        }
    }

    /// A heading inside a group (an account, "Offer to record"), said once instead of on every row.
    func sub(_ title: String) -> some View {
        line {
            Text(title).font(PKFont.text(13, .medium)).foregroundStyle(UIInk.muted).padding(.leading, G.toggle)
        }
    }

    // MARK: the look: the theme and light or dark

    var look: some View {
        let themes = m.themes.isEmpty ? ThemeStore.all() : m.themes
        let cur = ThemeStore.spec
        return group("Look") {
            line {
                HStack(spacing: 0) {
                    Swatch(spec: cur).frame(width: G.toggle, alignment: .leading)
                    SwiftUI.Menu {
                        ForEach(themes, id: \.id) { t in
                            Button { ThemeStore.pick(t.id) } label: {
                                Label { Text(t.name + (t.id == cur.id ? "  ✓" : "")) } icon: { Image(nsImage: Swatch.image(t)) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Theme").font(PKFont.text(16))
                            Text(cur.name).font(PKFont.text(16)).foregroundStyle(UIInk.muted)
                            Glyph("chevron-down", size: 14).foregroundStyle(UIInk.faint)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Theme: \(cur.name)")
                    Spacer()
                    ModePicker()
                    Color.clear.frame(width: G.cloud + 12, height: 1)
                }
            }
            ForEach(Array(ThemeStore.refused.sorted { $0.key < $1.key }), id: \.key) { id, reasons in
                line {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: PKColors.crit)).frame(width: 6, height: 6)
                            Text("\(id) is not used: it fails the contrast check").font(PKFont.text(14))
                        }
                        ForEach(Array(reasons.prefix(3).enumerated()), id: \.offset) { _, r in
                            Text(r).font(PKFont.mono(12)).foregroundStyle(UIInk.muted).lineLimit(1)
                        }
                    }.padding(.leading, G.toggle).padding(.vertical, 8)
                }
            }
        }
    }
}

/// Follow the system, light or dark: three words, the chosen one on the soft lift.
struct ModePicker: View {
    @State private var mode = ThemeStore.mode
    var body: some View {
        HStack(spacing: 2) {
            ForEach([("system", "System"), ("light", "Light"), ("dark", "Dark")], id: \.0) { id, name in
                Button { mode = id; ThemeStore.pick(mode: id) } label: {
                    Text(name).font(PKFont.text(13)).foregroundStyle(mode == id ? UIInk.ink : UIInk.muted)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: PK.corner(2)).fill(mode == id ? UIInk.soft : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(mode == id ? .isSelected : [])
            }
        }
        .padding(2).overlay { RoundedRectangle(cornerRadius: PK.corner(2) + 2).strokeBorder(UIInk.line, lineWidth: 1) }
    }
}

/// A theme in small: its ground, its ink and its accent side by side, in the mode in use.
struct Swatch: View {
    let spec: ThemeSpec
    var body: some View { Image(nsImage: Self.image(spec)).accessibilityHidden(true) }
    static func image(_ t: ThemeSpec) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 18), flipped: false) { r in
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = dark ? t.dark : t.light
            func ns(_ k: String) -> NSColor { c[k].map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? .gray }
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSGraphicsContext.saveGraphicsState(); box.addClip()
            ns("paper").setFill(); r.fill()
            ns("ink").setFill(); NSRect(x: 12, y: 0, width: 10, height: r.height).fill()
            ns("blue").setFill(); NSRect(x: 22, y: 0, width: 10, height: r.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.gray.withAlphaComponent(0.4).setStroke(); box.lineWidth = 1; box.stroke()
            return true
        }
    }
}

/// What a typing feature earned, for other places that show it: the meter, then taken / shown.
struct Earned: View {
    let count: LogStats.Count?
    let has: Bool
    var body: some View {
        HStack(spacing: 8) {
            if has, let c = count, c.shown > 0 {
                Meter(share: min(1, Double(c.taken) / Double(c.shown)), lit: c.taken > 0)
                Text("\(SettingsGrid.n(c.taken)) / \(SettingsGrid.n(c.shown))").font(PKFont.mono(12)).foregroundStyle(UIInk.muted)
            }
        }
    }
}

/// The meter: ten cells 5 x 12, 2 pt apart, rounded a little, lit for the share taken in the take rate's colour.
struct Meter: View {
    let share: Double
    let lit: Bool
    static let cells = 10
    var body: some View {
        let on = lit ? max(1, Int((share * Double(Self.cells)).rounded())) : 0
        let col = SettingsGrid.rateColor(share)
        HStack(spacing: 2) {
            ForEach(0..<Self.cells, id: \.self) { i in RoundedRectangle(cornerRadius: 1.5).fill(i < on ? col : UIInk.soft).frame(width: 5, height: 12) }
        }
    }
}
