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
            Row(title: "Presets", caption: caption(current)) {
                HStack(spacing: 8) {
                    Button { name = current?.name ?? suggestedName; naming = true } label: { Label("Save…", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle())
                        .help("Save the EQ, gate, compressor, de-esser, limiter and output level as a preset")
                    if !engine.presets.isEmpty { manage(current) }
                }
            }
            if !engine.presets.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(engine.presets.enumerated()), id: \.element.id) { i, preset in
                        chip(i, preset, isCurrent: preset.id == current?.id)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
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
        if engine.presets.isEmpty { return "Save the current sound to come back to it, or to compare sounds on the same recording." }
        if let current { return "Using \(current.name). Loop a recording in the player below, then click presets to hear each on the same words." }
        if let last = engine.presets.first(where: { $0.id == engine.lastPreset }) { return "Changed since you chose \(last.name). Save to keep it." }
        return "The current sound isn't saved as a preset."
    }

    private var suggestedName: String {
        var n = engine.presets.count + 1
        while engine.presets.contains(where: { $0.name == "Preset \(n)" }) { n += 1 }
        return "Preset \(n)"
    }

    private func chip(_ i: Int, _ preset: SoundPreset, isCurrent: Bool) -> some View {
        Button { engine.use(preset) } label: {
            HStack(spacing: 7) {
                if i < 9 {
                    Text("\(i + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isCurrent ? Color.white : Color.primary.opacity(0.07)))
                }
                Text(preset.name).font(.system(size: 13, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
            }
            .padding(.leading, i < 9 ? 6 : 12).padding(.trailing, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(preset.summary)
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
            HStack(spacing: 6) {
                Text("Manage")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Manage presets")
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Line { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !lines[lines.count - 1].items.isEmpty, lines[lines.count - 1].width + spacing + size.width > width { lines.append(Line()) }
            var line = lines[lines.count - 1]
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append(i)
            lines[lines.count - 1] = line
        }
        return lines
    }
}
