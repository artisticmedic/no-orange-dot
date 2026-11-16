import SwiftUI

struct MicOrderCard: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Card {
            Row(title: "Choose your preferred microphones",
                caption: "Include the mics you want, then put your favourite first. New microphones stay out of the list until you include them.") { EmptyView() }
            if engine.micOrder.isEmpty {
                RowDivider()
                Row(title: "No microphones included", caption: "The app uses an available microphone. Include your favourites below to choose which ones take priority.") { EmptyView() }
            }
            ForEach(Array(engine.micOrder.enumerated()), id: \.element) { i, uid in
                RowDivider()
                micRow(uid, position: i)
            }
            if !engine.otherMicUIDs.isEmpty {
                RowDivider()
                Row(title: "Other microphones", caption: "Used as a fallback when none of your included mics are connected. Turn on Include to give one a place in the list.") { EmptyView() }
                ForEach(engine.otherMicUIDs, id: \.self) { uid in
                    RowDivider()
                    micRow(uid, position: nil)
                }
            }
            RowDivider()
            Row(title: "When none are connected",
                caption: "The app keeps the current microphone if it is available, or picks another. It returns to your priority list when an included mic reconnects.") { EmptyView() }
        }
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

    private func caption(_ uid: String) -> String {
        if uid == engine.inputUID { return engine.manualInputUID == uid ? "In use · selected manually" : "In use" }
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
