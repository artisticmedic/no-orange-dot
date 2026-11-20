import SwiftUI

struct MicOrderCard: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Card {
            if engine.micOrder.isEmpty {
                Row(title: "No microphones included", caption: "Include one below to give it priority.") { EmptyView() }
            }
            ForEach(Array(engine.micOrder.enumerated()), id: \.element) { i, uid in
                if i > 0 { RowDivider() }
                micRow(uid, position: i)
            }
            if !engine.otherMicUIDs.isEmpty {
                Text("Other microphones, used only when none above are connected")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                ForEach(Array(engine.otherMicUIDs.enumerated()), id: \.element) { i, uid in
                    if i > 0 { RowDivider() }
                    micRow(uid, position: nil)
                }
            }
        }
        .help("The first connected microphone in the list is used. New microphones stay out of the list until you include them. When none are connected, the app keeps the current one or picks another, and returns to the list when an included one reconnects.")
    }

    private func micRow(_ uid: String, position: Int?) -> some View {
        let name = engine.micName(for: uid) ?? uid
        return Row(title: position.map { "\($0 + 1). \(name)" } ?? name, caption: caption(uid)) {
            HStack(spacing: 12) {
                if let i = position {
                    HStack(spacing: 6) {
                        move("chevron.up", "Move \(name) up", uid, past: i > 0 ? engine.micOrder[i - 1] : nil)
                        move("chevron.down", "Move \(name) down", uid, past: i + 1 < engine.micOrder.count ? engine.micOrder[i + 1] : nil)
                    }
                }
                Toggle("Include", isOn: Binding(get: { engine.micOrder.contains(uid) }, set: { engine.includeMic(uid, included: $0) }))
                    .toggleStyle(.switch)
                    .accessibilityLabel("Include \(name) in microphone priority")
            }
        }
    }

    /// Other microphones are always connected, so only the one in use says anything.
    private func caption(_ uid: String) -> String? {
        if uid == engine.inputUID { return engine.manualInputUID == uid ? "In use · selected manually" : "In use" }
        guard engine.micOrder.contains(uid) else { return nil }
        return engine.inputs.contains { $0.uid == uid } ? "Connected" : "Not plugged in"
    }

    private func move(_ symbol: String, _ label: String, _ uid: String, past other: String?) -> some View {
        Button { if let other { engine.moveMic(uid, past: other) } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(PillButtonStyle()).disabled(other == nil)
        .accessibilityLabel(label).help(label)
    }
}
