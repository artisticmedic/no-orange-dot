import SwiftUI

/// Saved sounds in a list. Loop a recording, then click down the list to hear each one on the same words.
struct PresetsCard: View {
    @EnvironmentObject var engine: Engine
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Card {
            Row(title: "Presets", caption: "A preset saves the EQ, gate, compressor, de-esser, limiter and output level. Loop a recording in the player below, then click presets to hear each on the same words.") {
                Button { name = suggestedName; naming = true } label: { Label("Save Current…", systemImage: "plus") }.buttonStyle(PillButtonStyle())
            }
            let current = engine.currentPreset
            ForEach(Array(engine.presets.enumerated()), id: \.element.id) { i, preset in
                RowDivider()
                row(i, preset, isCurrent: preset.id == current?.id)
            }
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
}
