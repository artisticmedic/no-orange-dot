import SwiftUI

/// Saved sounds in a list. Loop a recording, then click down the list to hear each one on the same words.
struct PresetsCard: View {
    @EnvironmentObject var engine: Engine
    @State private var naming = false
    @State private var name = ""

    private var takes: [Recording] { engine.recordings.filter { $0.raw != nil } }
    private var playing: Recording? { engine.recordings.first { $0.url == engine.auditioning } }

    var body: some View {
        Card {
            Row(title: "Presets", caption: "A preset saves the EQ, gate, compressor, limiter and output level.") {
                Button { name = suggestedName; naming = true } label: { Label("Save Current…", systemImage: "plus") }.buttonStyle(PillButtonStyle())
            }
            let current = engine.currentPreset
            ForEach(Array(engine.presets.enumerated()), id: \.element.id) { i, preset in
                RowDivider()
                row(i, preset, isCurrent: preset.id == current?.id)
            }
            RowDivider()
            compare
        }
        .onAppear { engine.refreshRecordings() }
        .alert("Save this sound as a preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { engine.savePreset(named: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(engine.presets.contains { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
                 ? "A preset with this name exists and will be replaced." : "It is added to the end of the list.")
        }
    }

    private var suggestedName: String {
        var n = engine.presets.count + 1
        while engine.presets.contains(where: { $0.name == "Preset \(n)" }) { n += 1 }
        return "Preset \(n)"
    }

    private func row(_ i: Int, _ preset: SoundPreset, isCurrent: Bool) -> some View {
        HStack(spacing: 0) {
            Button { engine.use(preset) } label: {
                HStack(spacing: 12) {
                    Text(i < 9 ? "\(i + 1)" : "").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.07)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.name).font(.system(size: 15, weight: isCurrent ? .medium : .regular))
                        Text(preset.summary).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 14).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use preset \(preset.name)").accessibilityAddTraits(isCurrent ? .isSelected : [])
            IconButton(symbol: "arrow.down.doc", label: "Replace \(preset.name) with the current sound") { engine.savePreset(named: preset.name) }
                .disabled(isCurrent).opacity(isCurrent ? 0.35 : 1)
            IconButton(symbol: "trash", label: "Delete \(preset.name)") { engine.deletePreset(preset) }.padding(.trailing, 8)
        }
        .background(isCurrent ? Color.primary.opacity(0.05) : .clear)
    }

    /// Starts or stops the looping take the presets are heard on.
    @ViewBuilder private var compare: some View {
        if let playing {
            Row(title: "Comparing on \(Recording.friendly(playing.date))",
                caption: engine.presets.isEmpty ? "Save two or more presets, then click one to switch."
                    : "Click a preset to switch.") {
                Button { engine.stopAudition() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(PillButtonStyle())
            }
        } else if takes.isEmpty {
            Row(title: "Compare on a recording", caption: engine.recordings.isEmpty ? "Record a few sentences to compare presets on them."
                : "Make a new recording to use this. The recordings you have were saved without their original audio.") { EmptyView() }
        } else {
            Row(title: "Compare on a recording", caption: "Plays one recording on repeat while you switch presets.") {
                Menu {
                    ForEach(takes.prefix(12)) { r in
                        Button("\(Recording.friendly(r.date))  ·  \(Recording.clock(r.seconds))") { play(r) }
                    }
                } label: { Label("Play", systemImage: "play.fill") } primaryAction: { if let first = takes.first { play(first) } }
                .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
            }
        }
    }

    private func play(_ r: Recording) {
        engine.auditionLoop = true
        engine.startAudition(r)
    }
}
