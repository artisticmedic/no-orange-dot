import SwiftUI

/// Replaces the Record button while a take is running: the time so far, pause, mute and stop.
struct RecordingControls: View {
    @EnvironmentObject var engine: Engine
    @State private var stopHover = false

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(engine.recordingPaused ? Color.secondary : Color.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(Recording.clock(engine.recordingElapsed)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                if engine.recordingPaused { Text("Paused").font(.system(size: 13)).foregroundStyle(.secondary) }
                if engine.listenBack { Text("· Hear myself on").font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .padding(.leading, 10).padding(.trailing, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel((engine.recordingPaused ? "Recording paused" : "Recording") + (engine.listenBack ? ", hearing yourself" : ""))
            BarIcon(symbol: engine.recordingPaused ? "record.circle" : "pause.fill",
                    label: engine.recordingPaused ? "Resume recording" : "Pause recording") { engine.togglePause() }
            BarIcon(symbol: engine.muted ? "mic.slash.fill" : "mic.fill", label: engine.muted ? "Unmute" : "Mute",
                    tint: engine.muted ? .orange : .primary) { engine.muted.toggle() }
            Button { engine.stopRecording() } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.red)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(stopHover ? 0.24 : 0.14)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { stopHover = $0 }
            .accessibilityLabel("Stop recording and save it")
        }
        .padding(2).frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.red.opacity(0.30), lineWidth: 1))
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
                    Text("Saved \(Recording.clock(take.seconds)) to Recordings").font(.system(size: 13, weight: .medium))
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

/// A symbol button sized to sit inside the top bar's chips.
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
