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
    private var playing: Bool { engine.auditioning != nil }

    private var noMicrophone: Bool { !engine.driverInstalled || engine.inputUID.isEmpty }

    /// What the meter is measuring, and a line of help only when something needs doing.
    private var source: (title: String, detail: String?) {
        switch reference.state {
        case .preparing: return ("Preparing the reference…", nil)
        case .playing: return ("Reference voice", "Match this level when you speak.")
        default: break
        }
        if playing { return ("Your recording", nil) }
        if noMicrophone { return ("No microphone", "Choose one in the sidebar.") }
        if engine.muted { return ("Mic muted", nil) }
        if engine.running { return (engine.checkingVoice ? "Checking your voice" : "Mic open", nil) }
        if let app = engine.directUsers.first, let mic = engine.inputs.first(where: { $0.uid == engine.inputUID })?.name {
            return ("\(app) is reading \(mic) directly", "Choose \(engine.micDisplayName) in \(app) to hear your sound and see its level here.")
        }
        return ("Mic off", nil)
    }

    var body: some View {
        Card {
            CardHeader(title: "Voice level")
            Live(engine.meters) { meters in
                let reading = playing ? meters.playbackVoice : meters.voice
                let active = playing || (engine.running && !engine.muted)
                VoiceLevelDisplay(reading: reading, active: active, label: source.title, detail: source.detail,
                                  suppressed: referenceActive || (!playing && engine.muted))
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
            HStack(spacing: 8) {
                Button {
                    reference.stop()
                    engine.stopPlaying()
                    engine.checkingVoice.toggle()
                } label: {
                    Label(engine.checkingVoice ? "Stop Check" : "Check My Voice", systemImage: engine.checkingVoice ? "stop.fill" : "mic")
                        .lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: !engine.running && !engine.checkingVoice && !playing))
                .disabled((engine.muted || noMicrophone) && !engine.checkingVoice)
                .help("Opens the mic to show your level. Nothing is played back.")
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
                .help(engine.recording ? "Stop recording to play the reference."
                      : engine.listenBack ? "Turn off Hear myself to play the reference."
                      : "Play a spoken sample at a fixed level. Compare at the same listening volume.")
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
            RowDivider()
            SliderRow(label: "Output", value: String(format: "%+.1f dB", engine.outputGainDB), binding: $engine.outputGainDB, range: -12...12)
                .padding(.vertical, 6)
                .help("Applied after the EQ and dynamics. Your listening volume stays up to you.")
            if case .failed(let message) = reference.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verdict).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                Spacer(minLength: 8)
                if hasSignal {
                    Text(String(format: "%.0f avg · %.0f peak", reading.averageDB, reading.peakDB))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Rectangle().fill(Color.green.opacity(active && !suppressed ? 0.22 : 0.07))
                        .frame(width: g.size.width * (fraction(-16) - fraction(-24)))
                        .offset(x: g.size.width * fraction(-24))
                    if hasSignal {
                        Capsule().fill(tint.opacity(0.8)).frame(width: g.size.width * fraction(reading.averageDB))
                        Rectangle().fill(Color.primary).frame(width: 2, height: 18)
                            .offset(x: min(g.size.width - 2, g.size.width * fraction(reading.peakDB)))
                    }
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1, height: 20)
                        .offset(x: g.size.width * fraction(VoiceLevel.referenceDB))
                }
            }
            .frame(height: 14).padding(.vertical, 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice level. \(label)")
        .accessibilityValue(hasSignal ? "\(verdict). Average \(Int(reading.averageDB)) dBFS. Peak \(Int(reading.peakDB)) dBFS." : verdict)
        .help("Average level over about 400 ms, in dBFS. The shaded band is the speaking range, −24 to −16. The fixed line is the reference voice, −20. The moving line shows peaks; 0 is the digital limit.")
    }
}
