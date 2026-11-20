import SwiftUI

/// Record, in the sidebar under Hear myself. While a take runs it turns into Stop, with the time so far, and Pause.
struct RecordKey: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if engine.recording {
            HStack(spacing: 8) {
                Button { engine.stopRecording() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            Text(Recording.clock(engine.recordingElapsed)).monospacedDigit()
                        }
                        if engine.recordingPaused { Text("Paused").opacity(0.75) }
                    }
                }
                .buttonStyle(KeyButtonStyle(palette: .red, latched: true, height: 40))
                .help("Stop recording and save it")
                .accessibilityLabel(engine.recordingPaused ? "Recording paused. Stop and save" : "Recording. Stop and save")
                Button { engine.togglePause() } label: {
                    Image(systemName: engine.recordingPaused ? "record.circle" : "pause.fill")
                }
                .buttonStyle(KeyButtonStyle(palette: .graphite(scheme), latched: engine.recordingPaused, height: 40))
                .frame(width: 58)
                .help(engine.recordingPaused ? "Resume recording" : "Pause recording")
                .accessibilityLabel(engine.recordingPaused ? "Resume recording" : "Pause recording")
            }
        } else {
            Button { engine.toggleRecording() } label: {
                HStack(spacing: 9) {
                    Circle().fill(Color.red).frame(width: 11, height: 11)
                    Text("Record")
                }
            }
            .buttonStyle(KeyButtonStyle(palette: .graphite(scheme), height: 40))
            .help("Record a take through your current sound")
        }
    }
}

/// Hear your own voice, with your sound, in your headphones. Lit while on.
struct HearMyselfKey: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            if engine.error?.hasPrefix("Listen back") == true { engine.error = nil }
            engine.listenBack.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                Text("Hear myself")
            }
        }
        .buttonStyle(KeyButtonStyle(palette: engine.listenBack ? .blue : .graphite(scheme), latched: engine.listenBack, height: 40))
        .help(engine.listenBack ? "Stop hearing yourself" : "Hear your voice, with your sound, in your headphones")
        .accessibilityAddTraits(engine.listenBack ? .isSelected : [])
    }
}

/// Shown for a few seconds after a take is saved, with the way to it.
struct SavedChip: View {
    @EnvironmentObject var engine: Engine
    let take: Recording
    let showRecordings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: showRecordings) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(Recording.clock(take.seconds))").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10).padding(.trailing, 4).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open Recordings")
            BarIcon(symbol: engine.auditioning == take.url ? "stop.fill" : "play.fill",
                    label: engine.auditioning == take.url ? "Stop" : "Play the recording") {
                if engine.auditioning == take.url { engine.stopPlaying() } else { engine.play(take) }
            }
            BarIcon(symbol: "xmark", label: "Dismiss") { engine.justSaved = nil }
        }
        .padding(2).frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .transition(.opacity)
    }
}

/// A symbol button sized to sit inside a chip.
struct BarIcon: View {
    let symbol: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(label).accessibilityLabel(label)
    }
}
