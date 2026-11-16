import SwiftUI

@MainActor
struct VoiceCheckCard: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var reference = ReferenceVoice.shared
    @ObservedObject private var playback = Playback.shared
    @State private var chosen: URL?

    private var referenceActive: Bool {
        switch reference.state { case .preparing, .playing: return true; default: return false }
    }
    private var referenceLabel: String {
        switch reference.state {
        case .preparing: return "Cancel"
        case .playing: return "Stop Reference"
        default: return "Play Reference"
        }
    }
    private var pick: Recording? {
        engine.recordings.first { $0.url == (engine.auditioning ?? playback.playing ?? chosen) } ?? engine.recordings.first
    }
    private var playing: Bool { engine.auditioning != nil || playback.playing != nil }

    var body: some View {
        Card {
            Row(title: "How loud is my voice?", caption: "Compare at the same headphone or speaker volume.") {
                Button {
                    if referenceActive { reference.stop() }
                    else {
                        engine.stopPlaying()
                        engine.checkingVoice = false
                        reference.toggle()
                    }
                } label: {
                    Label(referenceLabel, systemImage: referenceActive ? "stop.fill" : "speaker.wave.2")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(engine.recording || engine.listenBack)
                .help("Play a spoken sample at a fixed level.")
            }
            Live(engine.meters) { meters in
                let reading = engine.auditioning != nil ? meters.playbackVoice : playback.playing != nil ? playback.voice : meters.voice
                VoiceLevelDisplay(reading: reading, active: playing || (engine.running && !engine.muted),
                                  label: meterLabel, suppressed: referenceActive || (!playing && engine.muted))
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
            RowDivider()
            Row(title: "Check your microphone", caption: engine.checkingVoice
                ? "Speak from your usual distance. This opens the mic without playing it back."
                : "Play the reference, then speak from your usual distance.") {
                Button {
                    reference.stop()
                    engine.stopPlaying()
                    engine.checkingVoice.toggle()
                } label: {
                    Label(engine.checkingVoice ? "Stop Check" : "Check My Voice", systemImage: engine.checkingVoice ? "stop.fill" : "mic")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(engine.muted && !engine.checkingVoice)
            }
            if let pick {
                RowDivider()
                Row(title: "Compare your recording") {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(engine.recordings.prefix(20)) { take in
                                Button {
                                    chosen = take.url
                                    if playing { engine.play(take) }
                                } label: {
                                    let label = "\(Recording.friendly(take.date)) · \(Recording.clock(take.seconds))"
                                    if take.url == pick.url { Label(label, systemImage: "checkmark") } else { Text(label) }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(Recording.friendly(pick.date)).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .menuStyle(.button).buttonStyle(PillButtonStyle())
                        .accessibilityLabel("Recording for the volume comparison")
                        Button {
                            if playing { engine.stopPlaying() }
                            else {
                                reference.stop()
                                engine.checkingVoice = false
                                engine.auditionLoop = false
                                engine.play(pick)
                            }
                        } label: {
                            Label(playing ? "Stop" : "Play Mine", systemImage: playing ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(engine.recording)
                    }
                }
            } else {
                Text("Record a few sentences with the Record button to compare your voice with the reference.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
            }
            RowDivider()
            SliderRow(label: "Output", value: String(format: "%+.1f dB", engine.outputGainDB), binding: $engine.outputGainDB, range: -12...12)
                .padding(.vertical, 4)
            Text("A starting range for speech, measured after EQ and dynamics. Your listening volume stays up to you.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
            if engine.recording || engine.listenBack {
                Text(engine.recording ? "Stop recording before playing the reference." : "Turn off Listen to compare with the reference on its own.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
            }
            if playing, pick?.raw == nil {
                Text("This take plays as saved. Output changes apply to your next recording.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
            }
            if case .failed(let message) = reference.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .onAppear { engine.refreshRecordings() }
        .onDisappear { engine.checkingVoice = false; reference.stop() }
        .onChange(of: engine.auditioning) { _, url in if url != nil { reference.stop() } }
        .onChange(of: engine.recording) { _, recording in if recording { reference.stop() } }
    }

    private var meterLabel: String {
        switch reference.state {
        case .preparing: return "Preparing reference voice…"
        case .playing: return "Listen to the reference"
        default: break
        }
        if playing { return "Your recording" }
        if engine.muted { return "Mic muted · Unmute to check your output" }
        return engine.running ? "Your microphone" : "Ready when you are"
    }
}

struct VoiceLevelDisplay: View {
    let reading: VoiceLevel.Reading
    var active = true
    var label = "Your microphone"
    var suppressed = false

    private var hasSignal: Bool { active && !suppressed && reading.averageDB > VoiceLevel.signalFloorDB }
    private var verdict: String {
        guard active && !suppressed else { return label }
        if reading.peakDB >= VoiceLevel.clippingDB { return "At the limit · Turn it down" }
        if reading.peakDB >= VoiceLevel.nearClippingDB { return "Peaks are high" }
        if !hasSignal { return "Speak a few words" }
        if reading.averageDB < VoiceLevel.speakingRange.lowerBound { return "A little quiet" }
        if reading.averageDB > VoiceLevel.speakingRange.upperBound { return "A little loud" }
        return "In speaking range"
    }
    private var tint: Color {
        guard hasSignal else { return .secondary }
        if reading.peakDB >= VoiceLevel.nearClippingDB { return .red }
        return VoiceLevel.speakingRange.contains(reading.averageDB) ? .green : .orange
    }
    private func fraction(_ db: Double) -> Double { min(max((db + 60) / 60, 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(verdict).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                Spacer(minLength: 8)
                if hasSignal {
                    Text(String(format: "%.0f avg · %.0f peak dBFS", reading.averageDB, reading.peakDB))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Rectangle().fill(Color.green.opacity(0.22))
                        .frame(width: g.size.width * (fraction(-16) - fraction(-24)))
                        .offset(x: g.size.width * fraction(-24))
                    if hasSignal {
                        Capsule().fill(tint.opacity(0.8)).frame(width: g.size.width * fraction(reading.averageDB))
                        Rectangle().fill(Color.primary).frame(width: 2, height: 16)
                            .offset(x: min(g.size.width - 2, g.size.width * fraction(reading.peakDB)))
                    }
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1, height: 18)
                        .offset(x: g.size.width * fraction(VoiceLevel.referenceDB))
                }
            }
            .frame(height: 12).padding(.vertical, 3)
            HStack {
                Text("Quiet")
                Spacer()
                Text("Reference −20 · Speaking range −24 to −16")
                Spacer()
                Text("Loud")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice level. \(label)")
        .accessibilityValue(hasSignal ? "\(verdict). Average \(Int(reading.averageDB)) dBFS. Peak \(Int(reading.peakDB)) dBFS." : verdict)
        .help("Average signal level over about 400 milliseconds, in dBFS. The mark is the reference voice level. The thin moving line shows peaks; 0 dBFS is the digital limit.")
    }
}
