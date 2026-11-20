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
            CardHeader(title: "Presets", caption: engine.presets.isEmpty ? "Save the current sound to come back to it." : nil) {
                HStack(spacing: 2) {
                    IconButton(symbol: "plus", label: "Save the current sound as a preset") { name = current?.name ?? suggestedName; naming = true }
                    if !engine.presets.isEmpty { manage(current) }
                }
            }
            ForEach(Array(engine.presets.enumerated()), id: \.element.id) { i, preset in
                row(i, preset, isCurrent: preset.id == current?.id)
            }
            Spacer().frame(height: engine.presets.isEmpty ? 0 : 8)
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

    private var suggestedName: String {
        var n = engine.presets.count + 1
        while engine.presets.contains(where: { $0.name == "Preset \(n)" }) { n += 1 }
        return "Preset \(n)"
    }

    private func shortcut(_ i: Int) -> String? { i < 9 ? Shortcut(engine.shortcut(for: "preset-\(i + 1)"))?.display : nil }

    /// The preset in use is lit. The last one used, changed since, says Edited.
    private func row(_ i: Int, _ preset: SoundPreset, isCurrent: Bool) -> some View {
        let edited = engine.currentPreset == nil && preset.id == engine.lastPreset
        return Button { engine.use(preset) } label: {
            HStack(spacing: 10) {
                Text(preset.name).font(.system(size: 15, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                if edited { Text("Edited").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if let key = shortcut(i) { Text(key).font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Surface.radius - 6, style: .continuous).fill(isCurrent ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .help(preset.summary)
        .accessibilityLabel("Use preset \(preset.name)").accessibilityValue(edited ? "Edited. \(preset.summary)" : preset.summary)
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
            Image(systemName: "ellipsis.circle").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Replace or delete presets").accessibilityLabel("Manage presets")
    }
}
