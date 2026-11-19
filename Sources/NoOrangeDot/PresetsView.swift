import SwiftUI

/// Saved sounds, above everything they set. Loop a recording in the player, then click down the presets to
/// hear each one on the same words.
struct PresetsCard: View {
    @EnvironmentObject var engine: Engine
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let current = engine.currentPreset
        Card {
            CardHeader(title: "Presets", caption: caption(current)) {
                HStack(spacing: 2) {
                    IconButton(symbol: "plus", label: "Save the current sound as a preset") { name = current?.name ?? suggestedName; naming = true }
                    if !engine.presets.isEmpty { manage(current) }
                }
            }
            ForEach(Array(engine.presets.enumerated()), id: \.element.id) { i, preset in
                row(i, preset, isCurrent: preset.id == current?.id)
            }
            Spacer().frame(height: engine.presets.isEmpty ? 0 : 6)
        }
        .help("Loop a recording in the player, then click presets to hear each on the same words.")
        .alert("Save this sound as a preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { engine.savePreset(named: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(engine.presets.contains { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
                 ? "A preset with this name exists and will be replaced." : "It is added to the end of the list.")
        }
    }

    private func caption(_ current: SoundPreset?) -> String {
        if engine.presets.isEmpty { return "Save the current sound to come back to it." }
        if let current { return "Using \(current.name)" }
        if let last = engine.presets.first(where: { $0.id == engine.lastPreset }) { return "Changed since \(last.name)" }
        return "Not saved as a preset"
    }

    private var suggestedName: String {
        var n = engine.presets.count + 1
        while engine.presets.contains(where: { $0.name == "Preset \(n)" }) { n += 1 }
        return "Preset \(n)"
    }

    private func row(_ i: Int, _ preset: SoundPreset, isCurrent: Bool) -> some View {
        Button { engine.use(preset) } label: {
            HStack(spacing: 10) {
                Text(i < 9 ? "\(i + 1)" : "").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.07)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 13, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                    Text(preset.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityLabel("Use preset \(preset.name)").accessibilityValue(preset.summary)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func manage(_ current: SoundPreset?) -> some View {
        Menu {
            Menu("Replace with Current Sound") {
                ForEach(engine.presets) { p in
                    Button(p.name) { engine.savePreset(named: p.name) }.disabled(p.id == current?.id)
                }
            }
            Menu("Delete") {
                ForEach(engine.presets) { p in Button(p.name) { engine.deletePreset(p) } }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15, weight: .medium)).frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Replace or delete presets").accessibilityLabel("Manage presets")
    }
}
