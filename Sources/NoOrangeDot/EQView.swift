import SwiftUI

struct EQView: View {
    @EnvironmentObject var engine: Engine
    var graphHeight: CGFloat = 150

    private let fMin = 20.0, fMax = 20000.0, dbRange = 18.0

    @AppStorage(Engine.heatMapKey) private var heatMap = true
    private var live: Bool { engine.monitoring || engine.auditioning != nil }

    var body: some View {
        Card {
            CardHeader(title: "Equalizer", caption: engine.original ? "Processing is off." : readout) {
                HStack(spacing: 4) {
                    IconButton(symbol: "arrow.uturn.backward", label: "Undo the last change to the curve") { engine.undoEQ() }
                        .disabled(!engine.canUndoEQ).opacity(engine.canUndoEQ ? 1 : 0.35)
                    curves
                    IconButton(symbol: "plus", label: "Add a band") { addBand() }
                        .disabled(engine.bands.count >= DSPChain.maxBands).opacity(engine.bands.count >= DSPChain.maxBands ? 0.35 : 1)
                    Toggle("Equalizer", isOn: Binding(get: { !engine.bypass }, set: { engine.bypass = !$0 })).labelsHidden().toggleStyle(.switch)
                        .help("Turns the EQ bands on or off. The gate, compressor, de-esser and limiter stay as they are.")
                        .padding(.leading, 6)
                }
            }
            graph.frame(height: graphHeight).padding(.horizontal, 10).opacity(engine.bypass || engine.original ? 0.45 : 1)
                .help("Drag a dot to move a band. Click one to edit it below.")
            viewOptions
            if heatMap, live {
                SpectrogramView().frame(height: 110).padding(.horizontal, 10).padding(.bottom, 10)
            }
            if let i = engine.bands.firstIndex(where: { $0.id == engine.selectedBand }) {
                RowDivider()
                bandEditor(i)
            }
        }
    }

    /// What draws on the graph, in one line under it.
    private var viewOptions: some View {
        HStack(spacing: 16) {
            Toggle("See your voice", isOn: $engine.monitoring).toggleStyle(.switch)
                .help(engine.monitoring ? "The mic is open while this is on." : "Shows your live voice behind the curve. Opens the mic.")
            Toggle("Heat map", isOn: $heatMap).toggleStyle(.switch)
                .help("Your voice over time: pitch runs bottom to top, brighter is louder.")
            Spacer()
            if live {
                legend(.accentColor, "Added")
                legend(.orange, "Cut")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Starting curves and earlier curves, in one menu.
    private var curves: some View {
        Menu {
            Section("Start From") {
                Button("Warm voice") { engine.bands = Presets.warm }
                Button("Flat") { engine.bands = Presets.flat }
            }
            Section("Earlier Curves") {
                if engine.history.isEmpty {
                    Text("Change the EQ and the curve from before is kept here.")
                } else {
                    ForEach(engine.history) { s in
                        Button("\(s.date.formatted(date: .abbreviated, time: .shortened))  ·  \(s.summary)") { engine.restore(s) }
                    }
                    Divider()
                    Button("Clear History") { engine.clearHistory() }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Start from a curve, or go back to an earlier one").accessibilityLabel("Curves")
    }

    /// "Bell · 480 Hz · −3.0 dB · Q 0.50" for the band being dragged or edited.
    private var readout: String? {
        guard let b = engine.bands.first(where: { $0.id == engine.selectedBand }) else { return nil }
        let f = b.freq >= 1000 ? String(format: "%.2f kHz", b.freq / 1000) : String(format: "%.0f Hz", b.freq)
        return [b.type.label, f, b.type.hasGain ? String(format: "%+.1f dB", b.gainDB) : nil, String(format: "Q %.2f", b.q)].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.45)).frame(width: 14, height: 10)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log10(f / fMin) / log10(fMax / fMin)) * w }
    private func freq(_ x: CGFloat, _ w: CGFloat) -> Double { fMin * pow(fMax / fMin, Double(min(max(x / w, 0), 1))) }
    private func y(_ db: Double, _ h: CGFloat) -> CGFloat { CGFloat(0.5 - db / (2 * dbRange)) * h }
    private func gain(_ y: CGFloat, _ h: CGFloat) -> Double { min(max((0.5 - Double(y / h)) * 2 * dbRange, -dbRange), dbRange) }

    private var graph: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Surface.radius - 10, style: .continuous).fill(Surface.plot)
                RoundedRectangle(cornerRadius: Surface.radius - 10, style: .continuous).strokeBorder(Surface.border, lineWidth: 1)
                Live(engine.scope) { m in Canvas { ctx, size in
                    for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                        var p = Path(); p.move(to: CGPoint(x: x(f, w), y: 0)); p.addLine(to: CGPoint(x: x(f, w), y: h))
                        ctx.stroke(p, with: .color(.primary.opacity(0.08)), lineWidth: 1)
                        ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 12)).foregroundStyle(.secondary), at: CGPoint(x: x(f, w) + 4, y: h - 11), anchor: .leading)
                    }
                    for db in [-12.0, -6, 0, 6, 12] {
                        var p = Path(); p.move(to: CGPoint(x: 0, y: y(db, h))); p.addLine(to: CGPoint(x: w, y: y(db, h)))
                        ctx.stroke(p, with: .color(.primary.opacity(db == 0 ? 0.25 : 0.08)), lineWidth: 1)
                        ctx.draw(Text(String(format: "%+.0f", db)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: 6, y: y(db, h) - 9), anchor: .leading)
                    }
                    // The live voice: a filled shape after the EQ, and a faint line for the raw mic.
                    func voice(_ levels: [Float]) -> Path {
                        var p = Path()
                        for (i, v) in levels.enumerated() {
                            let t = CGFloat(min(max((v - Engine.displayFloor) / (Engine.displayCeiling - Engine.displayFloor), 0), 1))
                            let pt = CGPoint(x: x(Engine.displayCentres[i], w), y: h - t * h)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        return p
                    }
                    if m.spectrumPost.count == Engine.displayCentres.count, m.spectrumRaw.count == m.spectrumPost.count {
                        var fill = voice(m.spectrumPost)
                        fill.addLine(to: CGPoint(x: x(Engine.displayCentres.last!, w), y: h)); fill.addLine(to: CGPoint(x: x(Engine.displayCentres[0], w), y: h)); fill.closeSubpath()
                        ctx.fill(fill, with: .color(.primary.opacity(0.10)))
                        // The difference: shade between the raw mic and the result, by whether the EQ adds or takes away.
                        func point(_ i: Int, _ v: Float) -> CGPoint {
                            let t = CGFloat(min(max((v - Engine.displayFloor) / (Engine.displayCeiling - Engine.displayFloor), 0), 1))
                            return CGPoint(x: x(Engine.displayCentres[i], w), y: h - t * h)
                        }
                        var added = Path(), removed = Path()
                        for i in 0..<(m.spectrumPost.count - 1) {
                            let d = (m.spectrumPost[i] - m.spectrumRaw[i] + m.spectrumPost[i + 1] - m.spectrumRaw[i + 1]) / 2
                            guard abs(d) > 0.3 else { continue }
                            var q = Path()
                            q.move(to: point(i, m.spectrumRaw[i])); q.addLine(to: point(i + 1, m.spectrumRaw[i + 1]))
                            q.addLine(to: point(i + 1, m.spectrumPost[i + 1])); q.addLine(to: point(i, m.spectrumPost[i])); q.closeSubpath()
                            if d > 0 { added.addPath(q) } else { removed.addPath(q) }
                        }
                        ctx.fill(added, with: .color(.accentColor.opacity(0.45)))
                        ctx.fill(removed, with: .color(.orange.opacity(0.45)))
                        ctx.stroke(voice(m.spectrumRaw), with: .color(.primary.opacity(0.30)), lineWidth: 1)
                    }
                    var curve = Path()
                    let steps = Int(size.width / 2)
                    for i in 0...steps {
                        let px = CGFloat(i) / CGFloat(steps) * w
                        let pt = CGPoint(x: px, y: y(min(max(engine.responseDB(at: freq(px, w)), -dbRange), dbRange), h))
                        if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                } }
                ForEach(engine.bands) { band in
                    let isSel = band.id == engine.selectedBand
                    Circle()
                        .fill(band.on ? Color.accentColor : Color.secondary)
                        .overlay(Circle().stroke(.white, lineWidth: isSel ? 2 : 1))
                        .frame(width: isSel ? 20 : 15, height: isSel ? 20 : 15)
                        .background(Circle().stroke(Color.accentColor.opacity(isSel ? 0.35 : 0), lineWidth: 5).frame(width: 30, height: 30))
                        .contentShape(Circle().inset(by: -10))
                        .position(x: x(band.freq, w), y: y(band.type.hasGain ? band.gainDB : 0, h))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("eq")).onChanged { v in
                            if engine.selectedBand != band.id { engine.selectedBand = band.id }
                            guard let i = engine.bands.firstIndex(where: { $0.id == band.id }) else { return }
                            var b = engine.bands[i]
                            b.freq = freq(v.location.x, w)
                            if b.type.hasGain { b.gainDB = (gain(v.location.y, h) * 10).rounded() / 10 }
                            engine.bands[i] = b
                        })
                }
            }
            .coordinateSpace(name: "eq")
            .clipShape(RoundedRectangle(cornerRadius: Surface.radius - 10, style: .continuous))
        }
    }

    private func bandEditor(_ i: Int) -> some View {
        // Looked up by ID, not position: the band can be removed while a control still holds this binding.
        let shown = engine.bands[i]
        let b = Binding(get: { engine.bands.first { $0.id == shown.id } ?? shown },
                        set: { new in if let j = engine.bands.firstIndex(where: { $0.id == shown.id }) { engine.bands[j] = new } })
        let f = b.wrappedValue.freq
        return VStack(spacing: 0) {
            Row(title: "Selected band") {
                HStack(spacing: 10) {
                    Picker("Band type", selection: b.type) { ForEach(BandType.allCases) { Text($0.label).tag($0) } }.labelsHidden().fixedSize()
                    Toggle("Band on", isOn: b.on).labelsHidden().toggleStyle(.switch)
                    IconButton(symbol: "trash", label: "Remove this band") { engine.removeSelectedBand() }
                }
            }
            SliderRow(label: "Frequency", value: String(format: f >= 1000 ? "%.2f kHz" : "%.0f Hz", f >= 1000 ? f / 1000 : f),
                      binding: Binding(get: { log10(b.wrappedValue.freq) }, set: { b.wrappedValue.freq = pow(10, $0) }), range: log10(fMin)...log10(fMax))
            if b.wrappedValue.type.hasGain {
                SliderRow(label: "Gain", value: String(format: "%+.1f dB", b.wrappedValue.gainDB), binding: b.gainDB, range: -dbRange...dbRange)
            }
            SliderRow(label: "Width", value: String(format: "Q %.2f", b.wrappedValue.q),
                      binding: Binding(get: { log10(b.wrappedValue.q) }, set: { b.wrappedValue.q = pow(10, $0) }), range: log10(0.2)...log10(10)).padding(.bottom, 6)
        }
    }

    private func addBand() {
        engine.addBand()
    }
}
