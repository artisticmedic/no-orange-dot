import SwiftUI

@MainActor
struct VoiceCheckCard: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var reference = ReferenceVoice.shared

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
    private var pick: Recording? { engine.recordings.first { $0.url == engine.auditioning } }
    private var playing: Bool { engine.auditioning != nil }

    private var noMicrophone: Bool { !engine.driverInstalled || engine.inputUID.isEmpty }

    /// What the meter is measuring, and what to do when it is measuring nothing.
    private var source: (title: String, detail: String) {
        switch reference.state {
        case .preparing: return ("Preparing the reference voice…", "It plays at a fixed level.")
        case .playing: return ("Reference voice", "Speak at about this level, at the same listening volume.")
        default: break
        }
        if playing { return ("Your recording", pick?.raw != nil ? "Playing through your current sound." : "Playing as saved. Output changes apply to your next recording.") }
        if noMicrophone { return ("No microphone available", "Choose a microphone in the sidebar.") }
        if engine.muted { return ("Mic muted", "Unmute to see your level.") }
        if engine.checkingVoice, engine.running { return ("Mic open for voice check", "Speak from your usual distance. Nothing is played back.") }
        if engine.running { return ("Mic open", "Measured after EQ and dynamics.") }
        if let app = engine.directUsers.first, let mic = engine.inputs.first(where: { $0.uid == engine.inputUID })?.name {
            return ("\(app) is reading \(mic) directly", "So \(app) hears it without your sound, and nothing shows here. Choose \(engine.micDisplayName) as the microphone in \(app), or start Check My Voice.")
        }
        return ("Mic off — start Check My Voice to see your level.", "The mic stays closed until something uses it.")
    }

    var body: some View {
        Card {
            CardHeader(title: "Voice level")
            Live(engine.meters) { meters in
                let reading = playing ? meters.playbackVoice : meters.voice
                let active = playing || (engine.running && !engine.muted)
                VoiceLevelDisplay(reading: reading, active: active, label: source.title,
                                  detail: active && !referenceActive ? source.title + " · " + source.detail : source.detail,
                                  suppressed: referenceActive || (!playing && engine.muted))
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
            HStack(spacing: 8) {
                Button {
                    reference.stop()
                    engine.stopPlaying()
                    engine.checkingVoice.toggle()
                } label: {
                    Label(engine.checkingVoice ? "Stop Check" : "Check My Voice", systemImage: engine.checkingVoice ? "stop.fill" : "mic")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: !engine.running && !engine.checkingVoice && !playing))
                .disabled((engine.muted || noMicrophone) && !engine.checkingVoice)
                Button {
                    if referenceActive { reference.stop() }
                    else {
                        engine.stopPlaying()
                        engine.checkingVoice = false
                        reference.toggle()
                    }
                } label: {
                    Label(referenceActive ? "Stop" : "Reference", systemImage: referenceActive ? "stop.fill" : "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(engine.recording || engine.listenBack)
                .help("Play a spoken sample at a fixed level. Compare at the same headphone or speaker volume.")
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
            RowDivider()
            SliderRow(label: "Output", value: String(format: "%+.1f dB", engine.outputGainDB), binding: $engine.outputGainDB, range: -12...12)
                .padding(.vertical, 6)
                .help("Applied after the EQ and dynamics. Your listening volume stays up to you.")
            if engine.recording || engine.listenBack {
                Text(engine.recording ? "Stop recording before playing the reference." : "Turn off Hear myself to compare with the reference on its own.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
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
}

struct VoiceLevelDisplay: View {
    let reading: VoiceLevel.Reading
    var active = true
    var label = "Your microphone"
    var detail: String?
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
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Rectangle().fill(Color.green.opacity(active && !suppressed ? 0.22 : 0.07))
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
                Text("Loud")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Shaded: speaking range, −24 to −16 dBFS. Line: the reference voice, −20.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice level. \(label)")
        .accessibilityValue(hasSignal ? "\(verdict). Average \(Int(reading.averageDB)) dBFS. Peak \(Int(reading.peakDB)) dBFS." : verdict)
        .help("Average signal level over about 400 milliseconds, in dBFS. The mark is the reference voice level. The thin moving line shows peaks; 0 dBFS is the digital limit.")
    }
}
