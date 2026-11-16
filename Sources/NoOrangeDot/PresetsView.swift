import SwiftUI

/// Saved sounds in a list. Loop a recording, then click down the list to hear each one on the same words.
struct PresetsCard: View {
    @EnvironmentObject var engine: Engine
    @State private var naming = false
    @State private var name = ""
    @State private var chosen: URL?

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

    /// The take chosen to compare on: the one playing, the one picked, or the newest.
    private var pick: Recording? { playing ?? takes.first { $0.url == chosen } ?? takes.first }

    /// Choose a recording, then loop it while clicking through the presets.
    @ViewBuilder private var compare: some View {
        if takes.isEmpty {
            Row(title: "Compare on a recording", caption: engine.recordings.isEmpty ? "Record a few sentences to compare presets on them."
                : "Make a new recording to use this. The recordings you have were saved without their original audio.") { EmptyView() }
        } else if let pick {
            VStack(spacing: 0) {
                Row(title: playing == nil ? "Compare on a recording" : "Playing on repeat",
                    caption: playing == nil ? "Choose a recording, then play it while you click between presets."
                        : engine.presets.isEmpty ? "Save two or more presets, then click one to switch." : "Click a preset to hear it on the same words.") {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(takes.prefix(20)) { r in
                                Button { choose(r) } label: {
                                    let text = "\(Recording.friendly(r.date))  ·  \(Recording.clock(r.seconds))"
                                    if r.url == pick.url { Label(text, systemImage: "checkmark") } else { Text(text) }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(Recording.friendly(pick.date))  ·  \(Recording.clock(pick.seconds))").lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
                        .accessibilityLabel("Recording to compare on")
                        if playing != nil {
                            Button { engine.stopAudition() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(PillButtonStyle())
                        } else {
                            Button { play(pick) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(PillButtonStyle(prominent: true))
                        }
                    }
                }
                if let playing {
                    Live(engine.meters) { m in
                        HStack(spacing: 10) {
                            ProgressView(value: m.auditionProgress).controlSize(.small)
                            Text("\(Recording.clock(m.auditionProgress * playing.seconds)) / \(Recording.clock(playing.seconds))")
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 11)
                }
            }
        }
    }

    /// Picking another take while one plays switches to it straight away.
    private func choose(_ r: Recording) {
        chosen = r.url
        if playing != nil { play(r) }
    }

    private func play(_ r: Recording) {
        engine.auditionLoop = true
        engine.startAudition(r)
    }
}
