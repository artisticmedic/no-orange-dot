import SwiftUI

/// The card that measures a voice and suggests an EQ for it.
struct AutoEQView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var playback = Playback()

    static let passage = """
    The quiet morning light moved slowly across the kitchen floor. Peter boiled water for tea while his \
    sister sorted through a box of old photographs. Each picture showed a different summer: the lake \
    house, a blue bicycle, grandfather laughing by the garden gate. They talked for an hour about where \
    everyone had gone, and what they hoped to do when the weather turned warm again.
    """

    var body: some View {
        Card {
            if let progress = engine.measureProgress {
                Row(title: "Listening…", caption: "Read this aloud at your normal level and distance. Keep going until the bar fills.") {
                    Button("Cancel") { engine.cancelMeasure() }.controlSize(.small)
                }
                Text(Self.passage).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                ProgressView(value: progress).padding(.horizontal, 12).padding(.bottom, 12)
                    .accessibilityLabel("Measuring").accessibilityValue("\(Int(progress * 100)) percent")
            } else if let r = engine.autoResult {
                result(r)
            } else {
                Row(title: "Automatic EQ", caption: engine.autoProblem ?? "Listens to you read for 20 seconds, then suggests an EQ for your voice on this mic.") {
                    Button("Measure…") { engine.startMeasure() }.controlSize(.small)
                }
            }
        }
        .onDisappear { playback.stop() }
    }

    @ViewBuilder private func result(_ r: AutoEQ.Result) -> some View {
        Row(title: "Suggested EQ", caption: summary(r)) {
            HStack(spacing: 8) {
                Button("Discard") { playback.stop(); engine.discardAutoEQ() }
                Button("Use This EQ") { playback.stop(); engine.useAutoEQ() }.keyboardShortcut(.defaultAction)
            }.controlSize(.small)
        }
        FitChart(result: r).frame(height: 110).padding(.horizontal, 8).padding(.bottom, 8)
        RowDivider()
        Row(title: "Sound", caption: "What the suggestion aims for.") {
            Picker("Sound", selection: $engine.autoTarget) {
                ForEach(AutoEQ.Target.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        SliderRow(label: "Strength", value: "\(Int(engine.autoStrength * 100))%", binding: $engine.autoStrength, range: 0...1.5).padding(.bottom, 5)
        RowDivider()
        Row(title: "Listen", caption: "Your reading, before and after the suggestion.") {
            HStack(spacing: 8) {
                listen("Before", processed: false)
                listen("After", processed: true)
            }.controlSize(.small)
        }
    }

    private func listen(_ label: String, processed: Bool) -> some View {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(processed ? "nod-after.wav" : "nod-before.wav")
        let on = playback.playing == url
        return Button {
            if on { playback.stop() } else if let u = engine.audition(processed: processed) { playback.toggle(u) }
        } label: { Label(on ? "Stop" : label, systemImage: on ? "stop.fill" : "play.fill") }
    }

    private func summary(_ r: AutoEQ.Result) -> String {
        let changes = r.bands.filter { $0.type.hasGain && abs($0.gainDB) >= 0.5 }.count
        if changes == 0 { return "Your voice already matches this sound closely. No changes suggested." }
        return String(format: "%d changes from %.0f seconds of speech. Your voice was about %.1f dB off this sound; with them, about %.1f dB.",
                      changes, r.secondsOfSpeech, r.offBeforeDB, r.offAfterDB)
    }
}

/// The measured voice against the target, and the EQ that closes the gap.
struct FitChart: View {
    let result: AutoEQ.Result

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            guard !result.centres.isEmpty else { return }
            let all = result.measured + result.wanted
            let top = (all.max() ?? 0) + 3, bottom = (all.min() ?? -1) - 3
            func point(_ i: Int, _ v: Double) -> CGPoint {
                CGPoint(x: CGFloat(log(result.centres[i] / 80) / log(12500.0 / 80)) * w, y: CGFloat((top - v) / (top - bottom)) * h)
            }
            func path(_ values: [Double]) -> Path {
                var p = Path()
                for i in values.indices { if i == 0 { p.move(to: point(i, values[i])) } else { p.addLine(to: point(i, values[i])) } }
                return p
            }
            ctx.stroke(path(result.wanted), with: .color(.primary.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            ctx.stroke(path(result.measured), with: .color(.primary.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            ctx.draw(Text("Solid: your voice").font(.system(size: 9)).foregroundStyle(.primary), at: CGPoint(x: 6, y: h - 20), anchor: .leading)
            ctx.draw(Text("Dashed: the target").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 6, y: h - 8), anchor: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        .accessibilityLabel("Your voice compared with the target sound")
    }
}

/// A scrolling picture of the voice: time runs left to right, pitch bottom to top, brightness is loudness.
struct SpectrogramView: View {
    @EnvironmentObject var engine: Engine
    var body: some View { Live(engine.scope) { picture($0) } }

    private func picture(_ meters: Scope) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(red: 0.05, green: 0.05, blue: 0.09))
            if let image = meters.spectrogram {
                GeometryReader { g in
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        .frame(width: g.size.width * CGFloat(image.width) / 180, height: g.size.height)
                }
            }
            Text("15k").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).padding(4)
            Text("40 Hz").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).padding(4).frame(maxHeight: .infinity, alignment: .bottomLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("Spectrogram of your voice over time")
    }
}
