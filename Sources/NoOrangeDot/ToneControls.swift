import SwiftUI

/// A plain-language control over one region of the EQ. Moving it edits the band already covering that region,
/// or adds one there, so the curve, the band editor and presets stay a single EQ.
struct ToneControl: Identifiable, Equatable {
    let id: String
    let title: String
    let less: String
    let more: String
    let type: BandType
    let freq: Double
    let q: Double
    /// A band of `type` whose frequency falls in here counts as this control's band.
    let covers: ClosedRange<Double>
    /// Slider range, running from `less` to `more`.
    let range: ClosedRange<Double>
    /// −1 where "more" means a cut: Open turns the boxy region down.
    var sign = 1.0

    static let all: [ToneControl] = [
        ToneControl(id: "rumble", title: "Rumble", less: "Off", more: "Strong", type: .highPass, freq: 60, q: 0.71, covers: 10...200, range: 20...120),
        ToneControl(id: "weight", title: "Weight", less: "Lighter", more: "Deeper", type: .lowShelf, freq: 120, q: 0.71, covers: 50...250, range: -6...6),
        ToneControl(id: "body", title: "Body", less: "Leaner", more: "Fuller", type: .bell, freq: 220, q: 0.8, covers: 150...319, range: -4...4),
        ToneControl(id: "box", title: "Box", less: "Boxy", more: "Open", type: .bell, freq: 480, q: 0.7, covers: 320...800, range: -3...6, sign: -1),
        ToneControl(id: "words", title: "Words", less: "Softer", more: "Clearer", type: .bell, freq: 2200, q: 0.8, covers: 1500...3500, range: -4...4),
        ToneControl(id: "edge", title: "Edge", less: "Darker", more: "Brighter", type: .highShelf, freq: 4500, q: 0.71, covers: 2500...10000, range: -6...6),
    ]

    /// Rumble is a filter: its value is the cutoff frequency, and the bottom of its range turns it off.
    var isFilter: Bool { type == .highPass }

    /// A narrow bell is a notch aimed at one resonance, not this control's broad region, so it is left alone.
    func index(in bands: [Band]) -> Int? {
        bands.firstIndex { $0.type == type && covers.contains($0.freq) && ($0.type != .bell || $0.q <= 2.5) }
    }

    func value(in bands: [Band]) -> Double {
        guard let i = index(in: bands), bands[i].on else { return isFilter ? range.lowerBound : 0 }
        return isFilter ? min(max(bands[i].freq, range.lowerBound), range.upperBound) : min(max(bands[i].gainDB * sign, range.lowerBound), range.upperBound)
    }

    /// The bands with this control set to `value`, or nil when it would need a new band and the EQ is full.
    func setting(_ value: Double, in bands: [Band]) -> [Band]? {
        var bands = bands
        let v = min(max(value, range.lowerBound), range.upperBound)
        let off = isFilter ? v <= range.lowerBound : false
        let freq = v.rounded(), gain = (v * sign * 10).rounded() / 10
        if let i = index(in: bands) {
            bands[i].on = !off
            if isFilter { if !off { bands[i].freq = freq } } else { bands[i].gainDB = gain }
            return bands
        }
        if off || (!isFilter && gain == 0) { return bands }
        guard bands.count < DSPChain.maxBands else { return nil }
        bands.append(Band(type: type, freq: isFilter ? freq : self.freq, gainDB: isFilter ? 0 : gain, q: q))
        return bands
    }

    func label(_ value: Double) -> String {
        if isFilter { return value <= range.lowerBound ? "Off" : String(format: "%.0f Hz", value) }
        let db = value * sign
        return abs(db) < 0.05 ? "0 dB" : String(format: "%+.1f dB", db)
    }
}

struct ToneCard: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Card {
            Row(title: "Tone", caption: "Shape your sound in plain words. Each slider moves a band in the equalizer.") { EmptyView() }
            ForEach(ToneControl.all) { ToneRow(control: $0) }
            Spacer().frame(height: 8)
        }
        .opacity(engine.bypass || engine.original ? 0.45 : 1)
    }
}

private struct ToneRow: View {
    @EnvironmentObject var engine: Engine
    let control: ToneControl

    var body: some View {
        let value = control.value(in: engine.bands)
        let full = control.index(in: engine.bands) == nil && engine.bands.count >= DSPChain.maxBands
        HStack(spacing: 10) {
            Text(control.title).font(.system(size: 13)).frame(width: 60, alignment: .leading)
            Text(control.less).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
            Slider(value: Binding(get: { value }, set: { if let bands = control.setting($0, in: engine.bands) { engine.bands = bands } }), in: control.range)
                .accessibilityLabel("\(control.title), \(control.less) to \(control.more)")
                .accessibilityValue(control.label(value))
            Text(control.more).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Text(control.label(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .disabled(full)
        .help(full ? "The EQ already has \(DSPChain.maxBands) bands. Remove one to use \(control.title)." : "")
    }
}
